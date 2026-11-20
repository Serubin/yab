import AppKit
import WebKit

// chrome.contentSettings, as Yab's own per-site answers: the ones Site
// Controls lists and a page's question reads (Asks.swift, SiteNotices,
// WindowGate). Camera, microphone, location and notifications are allow,
// block or ask (never said); popups allow or block, Yab's windows rule;
// automaticDownloads allow, block or ask, Site Controls' Automatic
// downloads (more files than a click asked for, SiteDownloads).
// A setting is for one site, its pattern naming it ("https://example.com/*",
// any port, "*://example.com/*"); a pattern for many sites is refused, since
// Yab keeps these per site. What Yab has no per-site switch for (JavaScript,
// images, cookies, sound, the clipboard, plugins) is
// answered "allow" as before, and setting it says that Yab has no such
// switch. clear() takes back what this extension set, and only that, as
// Chrome's does.

@available(macOS 15.4, *)
@MainActor
enum ExtensionContentSettings {
    /// What each extension set, by setting, so clear() takes back its own.
    private static func setKey(_ id: String) -> String { "extensions.contentSettings.\(id)" }

    static func run(_ api: String, _ args: [Any], extensionID id: String) throws -> Any? {
        // "contentSettings.camera.get" and the like.
        let parts = api.split(separator: ".").map(String.init)
        guard parts.count == 3 else { throw ExtensionShims.Unsupported(what: "\(api) isn't available in \(Brand.name)") }
        let name = parts[1], verb = parts[2]
        let spec = args.first as? [String: Any] ?? [:]
        switch verb {
        case "get":
            guard let raw = spec["primaryUrl"] as? String, let url = URL(string: raw), url.host() != nil else {
                throw ExtensionShims.Unsupported(what: "The URL \(spec["primaryUrl"] ?? "") is invalid.")
            }
            return ["setting": value(name, for: url)]
        case "set":
            let setting = spec["setting"] as? String ?? ""
            let allowed = name == "popups" ? ["allow", "block"] : ["allow", "ask", "block"]
            guard allowed.contains(setting) else {
                throw ExtensionShims.Unsupported(what: "Invalid invocation: Error at property 'setting': Value must be one of \(allowed.joined(separator: ", ")).")
            }
            guard ["camera", "microphone", "location", "notifications", "popups", "automaticDownloads"].contains(name) else {
                throw ExtensionShims.Unsupported(what: "\(Brand.name) has no per-site switch for \(name): it stays allowed")
            }
            guard let site = site(spec["primaryPattern"] as? String ?? "") else {
                throw ExtensionShims.Unsupported(what: "\(Brand.name) sets \(name) for one site: a pattern like https://example.com/*")
            }
            write(name, site: site, setting: setting)
            var kept = Store.settings.dictionary(forKey: setKey(id)) as? [String: [String]] ?? [:]
            kept[name, default: []].append(site.origin)
            kept[name] = Array(Set(kept[name] ?? [])).sorted()
            Store.settings.set(kept, forKey: setKey(id))
            return nil
        case "clear":
            var kept = Store.settings.dictionary(forKey: setKey(id)) as? [String: [String]] ?? [:]
            for origin in kept[name] ?? [] {
                if let url = URL(string: origin), let site = site(origin + "/*") ?? Site(url: url) { write(name, site: site, setting: "ask") }
            }
            kept[name] = nil
            Store.settings.set(kept, forKey: setKey(id))
            return nil
        case "getResourceIdentifiers":
            return [Any]()
        default:
            throw ExtensionShims.Unsupported(what: "\(api) isn't available in \(Brand.name)")
        }
    }

    /// A site as each of Yab's stores names it.
    @MainActor struct Site {
        let origin: String
        let host: String
        init?(url: URL) {
            guard let origin = Browser.origin(of: url), let host = url.host()?.lowercased() else { return nil }
            self.origin = origin
            self.host = host
        }
        init(origin: String, host: String) {
            self.origin = origin
            self.host = host
        }
        /// Site Controls' name for it: no www.
        var bare: String { host.hasPrefix("www.") ? String(host.dropFirst(4)) : host }
    }

    /// The one site a pattern names, or nil for a pattern of many.
    static func site(_ pattern: String) -> Site? {
        guard let range = pattern.range(of: "://") else { return nil }
        let scheme = String(pattern[..<range.lowerBound])
        var rest = String(pattern[range.upperBound...])
        if let slash = rest.firstIndex(of: "/") { rest = String(rest[..<slash]) }
        var host = rest, port = 0
        if let colon = rest.lastIndex(of: ":") {
            host = String(rest[..<colon])
            let after = String(rest[rest.index(after: colon)...])
            port = after == "*" ? 0 : Int(after) ?? 0
        }
        guard !host.isEmpty, !host.contains("*"), ["http", "https", "*"].contains(scheme) else { return nil }
        let real = scheme == "*" ? "https" : scheme
        return Site(origin: Browser.origin(scheme: real, host: host, port: port), host: host.lowercased())
    }

    static func value(_ name: String, for url: URL) -> String {
        guard let site = Site(url: url) else { return "allow" }
        func word(_ said: Bool?) -> String { said.map { $0 ? "allow" : "block" } ?? "ask" }
        switch name {
        case "camera": return word(Store.settings.object(forKey: Browser.captureKey(site.origin, .camera)) as? Bool)
        case "microphone": return word(Store.settings.object(forKey: Browser.captureKey(site.origin, .microphone)) as? Bool)
        case "location": return word(Store.settings.object(forKey: "location.\(site.host)") as? Bool)
        case "notifications": return word(SiteNotices.said(site.origin))
        case "popups": return WindowGate.allows(site.bare) ? "allow" : "block"
        case "automaticDownloads": return word(SiteDownloads.many(for: site.host))
        default: return "allow"
        }
    }

    private static func write(_ name: String, site: Site, setting: String) {
        let said: Bool? = setting == "allow" ? true : setting == "block" ? false : nil
        func put(_ key: String) {
            if let said { Store.settings.set(said, forKey: key) } else { Store.settings.removeObject(forKey: key) }
        }
        switch name {
        case "camera": put(Browser.captureKey(site.origin, .camera))
        case "microphone": put(Browser.captureKey(site.origin, .microphone))
        case "location": put("location.\(site.host)")
        case "notifications":
            if let said { SiteNotices.remember(site.origin, said) } else { SiteNotices.forget(site.origin) }
        case "popups":
            if said == true { WindowGate.allow(site.bare) } else { WindowGate.forget(site.bare) }
        case "automaticDownloads":
            if let said { SiteDownloads.rememberMany(site.host, said, origin: site.origin) } else { SiteDownloads.forgetMany(site.host) }
        default: break
        }
    }
}
