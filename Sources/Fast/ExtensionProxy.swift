import Foundation
import JavaScriptCore
import Network
import WebKit

// chrome.proxy, routed for real (docs/extension-apis-plan.md, B3).
//
// What an extension sets with proxy.settings.set is kept per extension as
// before (ExtensionShims.setting); the one in control, the last to set it,
// as in Chrome, is applied to every store sites load in:
// WKWebsiteDataStore.proxyConfigurations, Network's HTTP CONNECT (TLS to the
// proxy for an https one) and SOCKS5.
//
// - fixed_servers: singleProxy, or the https, http or fallback one (Network
//   sends everything through one proxy); bypassList as excluded domains.
// - pac_script: the script is run in a JSContext with PAC's helpers. Network
//   takes no script, so its answer for an ordinary site is the default, and a
//   page's own host (a main-frame navigation, `consider`) gets its own answer
//   when it differs. Chrome asks per request; per host is what Network allows.
//   A script named by address (pacScript.url: the extension's own file, as
//   FoxyProxy and others give it, a data: one or the web) is read first,
//   and the proxies in force stay until it is: a VPN's sites don't go
//   direct while it loads.
// - direct and system: nothing of ours, the Mac's own settings.
//
// A proxy asking for a password is answered from what the extension's
// webRequest.onAuthRequired gives for it (the shim asks it when the proxy
// is set and every few minutes, `credentials`).
//
// privacy.network.webRTCIPHandlingPolicy disable_non_proxied_udp (and the
// public-interface ones) make pages' RTCPeerConnection relay-only with no
// STUN servers, so no address reaches a site outside the proxy
// (PageScripts.webrtcRelay, while set).

@MainActor
enum ExtensionProxy {
    static let settingName = "proxy.settings"
    static let webRTCName = "privacy.network.webRTCIPHandlingPolicy"

    /// The extension in control: the last one to set the proxy.
    private static var controller: String? {
        get { Store.settings.string(forKey: "extensions.proxy.controller") }
        set { Store.settings.set(newValue, forKey: "extensions.proxy.controller") }
    }
    /// Passwords for proxies, by "host:port", as the extension gave them.
    private static var passwords: [String: (String, String)] = [:]
    /// The configurations now applied; empty for the Mac's own.
    private(set) static var applied: [ProxyConfiguration] = []
    /// What the controller set, for the bench and the docs' checks.
    private(set) static var value: [String: Any]?
    /// The PAC script's context and its answers by host.
    private static var pac: JSContext?
    private static var pacDefault = "DIRECT"
    private static var pacHosts: [String: String] = [:]
    /// PAC scripts named by address, as read ("" when they couldn't be),
    /// and the ones being read.
    private static var pacRead: [String: String] = [:]
    private static var pacReading: Set<String> = []
    private static var lastSaid = ""
    private(set) static var authenticationRevision = 0
    /// Pages' WebRTC kept to relays (PageScripts.webrtcRelay).
    private(set) static var relayOnly = Store.settings.bool(forKey: "extensions.webrtc.relayOnly")

    // MARK: - told

    /// A proxy setting set or cleared by `id`.
    static func set(by id: String, cleared: Bool) {
        authenticationRevision += 1
        if !cleared { controller = id } else if controller == id { controller = nil }
        // Set again: a script named by address is read again, as Chrome does.
        if !cleared { pacRead = [:] }
        refresh()
    }

    /// The extension's answer to its onAuthRequired, for a proxy.
    static func credentials(host: String, port: Int, username: String, password: String) {
        let key = "\(host.lowercased()):\(port)"
        guard passwords[key]?.0 != username || passwords[key]?.1 != password else { return }
        passwords[key] = (username, password)
        refresh()
    }

    /// Read again from what each extension set: at launch, and when one is
    /// set, cleared, turned off or removed.
    static func refresh(_ list: [Installed]? = nil) {
        let enabled = Set((list ?? Extensions.shared.installed).filter(\.enabled).map(\.id))
        var chosen: [String: Any]?
        if let id = controller, enabled.contains(id), let mine = Extensions.settings(for: id)[settingName] as? [String: Any] {
            chosen = mine
        } else {
            for id in enabled.sorted() {
                if let mine = Extensions.settings(for: id)[settingName] as? [String: Any] { chosen = mine; controller = id; break }
            }
        }
        value = chosen
        if let chosen, let id = controller, let address = unread(chosen) {
            read(address, for: id)
        } else {
            applyIfChanged(chosen)
        }
        var relay = false
        for id in enabled {
            if let policy = Extensions.settings(for: id)[webRTCName] as? String, policy != "default" { relay = true }
        }
        if relay != relayOnly {
            relayOnly = relay
            Store.settings.set(relay, forKey: "extensions.webrtc.relayOnly")
        }
    }

    private static func applyIfChanged(_ chosen: [String: Any]?) {
        // Only a change goes to the stores: setting them again drops
        // their connections.
        let words = (chosen.flatMap { try? JSONSerialization.data(withJSONObject: $0, options: .sortedKeys) })
            .map { String(decoding: $0, as: UTF8.self) } ?? ""
        let said = words + passwords.keys.sorted().map { "\($0)=\(passwords[$0]!.0):\(passwords[$0]!.1.hashValue)" }.joined(separator: ",")
        if said != lastSaid {
            lastSaid = said
            authenticationRevision += 1
            apply(configurations(for: chosen ?? [:]))
        }
    }

    /// A PAC script's address not read yet, for a pac_script with no data.
    private static func unread(_ value: [String: Any]) -> String? {
        guard value["mode"] as? String == "pac_script", let script = value["pacScript"] as? [String: Any],
              script["data"] as? String == nil, let address = script["url"] as? String, pacRead[address] == nil
        else { return nil }
        return address
    }

    private static func read(_ address: String, for id: String) {
        guard !pacReading.contains(address) else { return }
        pacReading.insert(address)
        let folder = Extensions.folder(for: id)
        Task {
            let script = await load(address, id: id, folder: folder)
            pacReading.remove(address)
            pacRead[address] = script ?? ""
            // The setting's words are the same: what they name changed.
            lastSaid = ""
            refresh()
        }
    }

    /// The script at a pacScript.url: the extension's own file (its id's
    /// chrome-extension:// address, inside its folder), a data: address,
    /// or http(s), as Chrome takes them.
    nonisolated static func load(_ address: String, id: String, folder: URL) async -> String? {
        guard let url = URL(string: address) else { return nil }
        switch url.scheme?.lowercased() {
        case "chrome-extension": // Extensions.scheme
            guard url.host()?.lowercased() == id.lowercased() else { return nil }
            let file = folder.appendingPathComponent(url.path(percentEncoded: false)).standardizedFileURL
            guard file.path.hasPrefix(folder.standardizedFileURL.path + "/"),
                  let data = try? Data(contentsOf: file) else { return nil }
            return String(decoding: data, as: UTF8.self)
        case "data":
            return ExtensionRuleMends.decode(address).map { String(decoding: $0.data, as: UTF8.self) }
        case "http", "https":
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
            request.httpShouldHandleCookies = false
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? false else { return nil }
            return String(decoding: data, as: UTF8.self)
        default:
            return nil
        }
    }

    /// A new store (a space's own) gets what the others have.
    static func dress(_ store: WKWebsiteDataStore) {
        if !applied.isEmpty { store.proxyConfigurations = applied }
    }

    private static func apply(_ configurations: [ProxyConfiguration]) {
        let had = !applied.isEmpty
        applied = configurations
        var stores = [Store.websites]
        stores += Spaces.madeStores.values
        var given = configurations
        // macOS 26's WebKit keeps the last proxies when handed none
        // (adhd, 26.4: the fixture's site still loaded through its proxy
        // after the extension cleared it); one that matches only a name
        // nothing has takes their place. macOS 27 takes none as none.
        if given.isEmpty, had, !emptyClears, let nowhere = make(["scheme": "http", "host": "127.0.0.1", "port": 9]) {
            var only = nowhere
            only.matchDomains = ["proxy-cleared.yab.invalid"]
            given = [only]
        }
        for store in stores { store.proxyConfigurations = given }
    }

    private static var emptyClears: Bool {
        if #available(macOS 27, *) { return true }
        return false
    }

    // MARK: - from Chrome's words

    /// Do not acknowledge a mode that this implementation would turn into
    /// an empty configuration (direct traffic). Called before any setting
    /// is persisted or the active proxy is changed.
    static func settingError(_ value: Any?) -> String? {
        guard let value = value as? [String: Any], let mode = value["mode"] as? String else {
            return "Proxy settings require a mode"
        }
        switch mode {
        case "direct", "system", "fixed_servers", "pac_script": return nil
        default: return "This proxy mode is not available in \(Brand.name)"
        }
    }

    static func configurations(for value: [String: Any]) -> [ProxyConfiguration] {
        pac = nil
        pacHosts = [:]
        switch value["mode"] as? String {
        case "fixed_servers":
            let rules = value["rules"] as? [String: Any] ?? [:]
            let server = (rules["singleProxy"] ?? rules["proxyForHttps"] ?? rules["proxyForHttp"] ?? rules["fallbackProxy"]) as? [String: Any]
            guard let server, var proxy = make(server) else { return [] }
            proxy.excludedDomains = bypass(rules["bypassList"] as? [String] ?? [])
            return [proxy]
        case "pac_script":
            let script = value["pacScript"] as? [String: Any] ?? [:]
            let data = script["data"] as? String ?? (script["url"] as? String).flatMap { pacRead[$0] }
            guard let data, !data.isEmpty, let context = pacContext(data) else { return [] }
            pac = context
            pacDefault = run(context, url: "https://www.example.com/", host: "www.example.com") ?? "DIRECT"
            return pacConfigurations()
        default:
            return []
        }
    }

    /// A main-frame navigation's host under a PAC script: its own answer
    /// when it differs from the default.
    static func consider(_ url: URL?) {
        guard let pac, let url, let host = url.host()?.lowercased(), pacHosts[host] == nil else { return }
        let said = run(pac, url: url.absoluteString, host: host) ?? pacDefault
        pacHosts[host] = said
        if pacHosts.count > 300 { pacHosts.removeAll() }
        guard said != pacDefault else { return }
        apply(pacConfigurations())
    }

    private static func pacConfigurations() -> [ProxyConfiguration] {
        var out: [ProxyConfiguration] = []
        let differing = pacHosts.filter { $0.value != pacDefault }
        for (host, said) in differing {
            guard var own = proxy(fromPAC: said) else { continue }
            own.matchDomains = [host]
            out.append(own)
        }
        if var main = proxy(fromPAC: pacDefault) {
            // Hosts the script sends direct stay off it.
            main.excludedDomains = differing.filter { proxy(fromPAC: $0.value) == nil }.map(\.key)
            out.append(main)
        }
        return out
    }

    /// The first proxy in a PAC answer, "PROXY host:port; DIRECT"; nil for
    /// DIRECT.
    private static func proxy(fromPAC answer: String) -> ProxyConfiguration? {
        for part in answer.split(separator: ";") {
            let words = part.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1).map(String.init)
            guard let kind = words.first?.uppercased() else { continue }
            if kind == "DIRECT" { return nil }
            guard words.count == 2 else { continue }
            let address = words[1].trimmingCharacters(in: .whitespaces)
            guard let colon = address.lastIndex(of: ":"), let port = Int(address[address.index(after: colon)...]) else { continue }
            let host = String(address[..<colon])
            let scheme = kind == "HTTPS" ? "https" : kind.hasPrefix("SOCKS") ? "socks5" : "http"
            if let made = make(["scheme": scheme, "host": host, "port": port]) { return made }
        }
        return nil
    }

    private static func make(_ server: [String: Any]) -> ProxyConfiguration? {
        guard let host = server["host"] as? String, !host.isEmpty else { return nil }
        let scheme = (server["scheme"] as? String ?? "http").lowercased()
        let port = server["port"] as? Int ?? (scheme == "https" ? 443 : scheme.hasPrefix("socks") ? 1080 : 80)
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { return nil }
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: nwPort)
        var made: ProxyConfiguration
        switch scheme {
        case "socks5", "socks4", "socks": made = ProxyConfiguration(socksv5Proxy: endpoint)
        case "https": made = ProxyConfiguration(httpCONNECTProxy: endpoint, tlsOptions: NWProtocolTLS.Options())
        default: made = ProxyConfiguration(httpCONNECTProxy: endpoint, tlsOptions: nil)
        }
        if let (user, password) = passwords["\(host.lowercased()):\(port)"] {
            made.applyCredential(username: user, password: password)
        }
        return made
    }

    /// Chrome's bypass list as Network's domains: "<local>" is the local
    /// names and loopback, "*.example.com" and ".example.com" the domain.
    static func bypass(_ list: [String]) -> [String] {
        var out: [String] = []
        for item in list {
            var rule = item.trimmingCharacters(in: .whitespaces).lowercased()
            if rule == "<local>" { out += ["localhost", "127.0.0.1", "::1", "local"]; continue }
            if let scheme = rule.range(of: "://") { rule = String(rule[scheme.upperBound...]) }
            if rule.hasPrefix("*.") { rule.removeFirst(2) } else if rule.hasPrefix(".") { rule.removeFirst() }
            if let colon = rule.lastIndex(of: ":"), !rule.contains("]"), rule.filter({ $0 == ":" }).count == 1 { rule = String(rule[..<colon]) }
            if !rule.isEmpty, !rule.contains("*"), !rule.contains("/") { out.append(rule) }
        }
        return out
    }

    // MARK: - PAC

    private static func pacContext(_ script: String) -> JSContext? {
        guard let context = JSContext() else { return nil }
        context.evaluateScript(pacHelpers)
        context.evaluateScript(script)
        guard context.exception == nil, context.objectForKeyedSubscript("FindProxyForURL")?.isObject == true else { return nil }
        return context
    }

    private static func run(_ context: JSContext, url: String, host: String) -> String? {
        let answer = context.objectForKeyedSubscript("FindProxyForURL")?.call(withArguments: [url, host])
        guard context.exception == nil, let text = answer?.toString(), !text.isEmpty, text != "undefined" else {
            context.exception = nil
            return nil
        }
        return text
    }

    /// PAC's own functions, as Chrome gives them, without DNS: a name that
    /// isn't an address is not looked up (dnsResolve gives null).
    static let pacHelpers = #"""
    function isPlainHostName(h) { return h.indexOf('.') < 0; }
    function dnsDomainIs(h, d) { return h.length >= d.length && h.substring(h.length - d.length) === d; }
    function localHostOrDomainIs(h, d) { return h === d || d.indexOf(h + '.') === 0; }
    function isResolvable(h) { return /^\d+(\.\d+){3}$/.test(h); }
    function dnsResolve(h) { return /^\d+(\.\d+){3}$/.test(h) ? h : null; }
    function myIpAddress() { return '127.0.0.1'; }
    function dnsDomainLevels(h) { return h.split('.').length - 1; }
    function convert_addr(ip) { var b = ip.split('.'); return ((b[0] << 24) | (b[1] << 16) | (b[2] << 8) | b[3]) >>> 0; }
    function isInNet(h, pat, mask) {
      var ip = dnsResolve(h); if (!ip) return false;
      return (convert_addr(ip) & convert_addr(mask)) >>> 0 === (convert_addr(pat) & convert_addr(mask)) >>> 0;
    }
    function shExpMatch(s, p) {
      var r = p.replace(/[.+^${}()|[\]\\]/g, '\\$&').replace(/\*/g, '.*').replace(/\?/g, '.');
      return new RegExp('^' + r + '$').test(s);
    }
    function weekdayRange() { return true; }
    function dateRange() { return true; }
    function timeRange() { return true; }
    function alert() {}
    """#
}
