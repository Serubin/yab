import Foundation
import dnssd

// Where an address's mail lives, found without anyone typing a server
// (docs/mail-providers.md, M3, What finds the server): the providers Yab
// knows, the domain's own autoconfig, Mozilla's ISPDB, the domain's MX run
// through the same again, and a guess, tried before it is shown. New Gmail
// accounts use app passwords; Microsoft is routed to its API.

/// How a mail server is signed in to with a password: SASL PLAIN
/// (AUTHENTICATE PLAIN, AUTH PLAIN) or LOGIN (IMAP's LOGIN, SMTP's AUTH LOGIN).
public enum MailPasswordWay: String, Codable, Sendable, Equatable {
    case plain, login

    public var other: MailPasswordWay { self == .plain ? .login : .plain }
}

/// An account's servers: what is kept per account in the settings, never a secret.
public struct MailServerSetup: Codable, Equatable, Sendable {
    public var address: String
    public var name: String = ""
    public var imapHost: String
    public var imapPort: Int = 993
    public var imapSecurity: MailSecurity = .tls
    public var imapUser: String
    public var smtpHost: String
    public var smtpPort: Int = 465
    public var smtpSecurity: MailSecurity = .tls
    public var smtpUser: String
    /// The known provider it came from ("icloud"), or how it was found.
    public var provider: String = ""
    public var foundBy: String = ""
    /// The server keeps a copy of what SMTP sends: nothing appended to Sent.
    public var savesSent = false
    /// How each server is signed in to (#441): nil for PLAIN where offered,
    /// else LOGIN; `.login` for LOGIN first. The way that worked at setup is
    /// kept, so the sync signs in as the setup did.
    public var imapAuth: MailPasswordWay?
    public var smtpAuth: MailPasswordWay?

    public init(address: String, name: String = "", imapHost: String, imapPort: Int = 993, imapSecurity: MailSecurity = .tls, imapUser: String? = nil,
                smtpHost: String, smtpPort: Int = 465, smtpSecurity: MailSecurity = .tls, smtpUser: String? = nil, provider: String = "", foundBy: String = "",
                savesSent: Bool = false) {
        self.address = address
        self.name = name
        self.imapHost = imapHost
        self.imapPort = imapPort
        self.imapSecurity = imapSecurity
        self.imapUser = imapUser ?? address
        self.smtpHost = smtpHost
        self.smtpPort = smtpPort
        self.smtpSecurity = smtpSecurity
        self.smtpUser = smtpUser ?? address
        self.provider = provider
        self.foundBy = foundBy
        self.savesSent = savesSent
    }

    /// Kept per account, as JSON in the settings.
    public static func key(_ account: String) -> String { "mail.imap.\(account.lowercased())" }

    public func saved(in defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(String(decoding: data, as: UTF8.self), forKey: Self.key(address))
    }

    public static func kept(_ account: String, in defaults: UserDefaults) -> MailServerSetup? {
        guard let text = defaults.string(forKey: key(account)) else { return nil }
        return try? JSONDecoder().decode(MailServerSetup.self, from: Data(text.utf8))
    }
}

/// A provider Yab knows by its domains.
public struct MailKnownProvider: Sendable, Equatable {
    public enum Route: String, Sendable { case imap, gmail, microsoft }

    public var id: String
    public var name: String
    public var domains: [String]
    /// The suffixes of MX hosts that say a custom domain is theirs.
    public var mx: [String] = []
    public var route: Route = .imap
    public var imap: (host: String, port: Int, security: MailSecurity) = ("", 993, .tls)
    public var smtp: (host: String, port: Int, security: MailSecurity) = ("", 465, .tls)
    /// What the sign-in names: the whole address, or the part before @.
    public var imapUser: User = .address
    public var smtpUser: User = .address
    /// It needs an app password where the account has two-step sign-in
    /// (for iCloud, always).
    public var appPassword = true
    /// Where the person makes one, opened in a Yab tab.
    public var appPasswordPage: String = ""
    /// Where IMAP is turned on, for a mailbox that has it off.
    public var imapSettingPage: String = ""
    public var savesSent = false
    /// The provider's own folders that are no mail of the person's, never
    /// synced: iCloud's Notes (old Notes kept over IMAP), Zoho's Outbox,
    /// Templates and Snoozed (Zoho brings snoozed mail back itself).
    public var unkept: [String] = []
    /// The way both servers are signed in to first, where PLAIN is known
    /// to fail (#441: iCloud's has closed the line on real accounts).
    public var auth: MailPasswordWay?

    public enum User: String, Sendable { case address, local }

    public static func == (a: MailKnownProvider, b: MailKnownProvider) -> Bool { a.id == b.id }

    public func setup(for address: String, name: String = "") -> MailServerSetup {
        let local = String(address.split(separator: "@").first ?? "")
        var setup = MailServerSetup(address: address, name: name, imapHost: imap.host, imapPort: imap.port, imapSecurity: imap.security,
                               imapUser: imapUser == .local ? local : address, smtpHost: smtp.host, smtpPort: smtp.port,
                               smtpSecurity: smtp.security, smtpUser: smtpUser == .local ? local : address, provider: id,
                               foundBy: "known", savesSent: savesSent)
        setup.imapAuth = auth
        setup.smtpAuth = auth
        return setup
    }
}

public enum MailKnownProviders {
    /// Zoho's data centers: a mailbox lives in one, and its servers are
    /// that one's (zoho.com, .eu, .in, .com.au, .jp, .ca's zohocloud.ca,
    /// .sa, .com.cn). Personal mailboxes sign in at imap.zoho.*, a
    /// company's own domain at imappro.zoho.* (Zoho's own help, 2026).
    static let zohoRegions: [(tld: String, imap: String, smtp: String, pro: (String, String))] = [
        ("com", "imap.zoho.com", "smtp.zoho.com", ("imappro.zoho.com", "smtppro.zoho.com")),
        ("eu", "imap.zoho.eu", "smtp.zoho.eu", ("imappro.zoho.eu", "smtppro.zoho.eu")),
        ("in", "imap.zoho.in", "smtp.zoho.in", ("imappro.zoho.in", "smtppro.zoho.in")),
        ("com.au", "imap.zoho.com.au", "smtp.zoho.com.au", ("imappro.zoho.com.au", "smtppro.zoho.com.au")),
        ("jp", "imap.zoho.jp", "smtp.zoho.jp", ("imappro.zoho.jp", "smtppro.zoho.jp")),
        ("ca", "imap.zohocloud.ca", "smtp.zohocloud.ca", ("imappro.zohocloud.ca", "smtppro.zohocloud.ca")),
        ("sa", "imap.zoho.sa", "smtp.zoho.sa", ("imappro.zoho.sa", "smtppro.zoho.sa")),
        ("com.cn", "imap.zoho.com.cn", "smtp.zoho.com.cn", ("imappro.zoho.com.cn", "smtppro.zoho.com.cn")),
    ]

    public static let all: [MailKnownProvider] = {
        var out: [MailKnownProvider] = [
            MailKnownProvider(id: "gmail", name: "Gmail", domains: ["gmail.com", "googlemail.com"], mx: ["google.com", "googlemail.com"],
                              imap: ("imap.gmail.com", 993, .tls), smtp: ("smtp.gmail.com", 465, .tls),
                              appPasswordPage: "https://myaccount.google.com/apppasswords", savesSent: true),
            MailKnownProvider(id: "microsoft", name: "Outlook", domains: ["outlook.com", "hotmail.com", "live.com", "msn.com", "hotmail.co.uk", "outlook.de",
                                                                          "hotmail.fr", "live.co.uk", "windowslive.com", "passport.com"],
                              mx: ["outlook.com", "protection.outlook.com"], route: .microsoft),
            // iCloud: the IMAP sign-in is the name before @ (Apple's help:
            // "usually the name part"), SMTP's the whole address; an app
            // password always; Sent kept by the server. LOGIN, not PLAIN:
            // iCloud's PLAIN has refused real accounts' right passwords and
            // closed the line after (#441; MailKit #295, Thunderbird 694753).
            MailKnownProvider(id: "icloud", name: "iCloud", domains: ["icloud.com", "me.com", "mac.com"], mx: ["mail.icloud.com"],
                              imap: ("imap.mail.me.com", 993, .tls), smtp: ("smtp.mail.me.com", 587, .starttls), imapUser: .local, smtpUser: .address,
                              appPassword: true, appPasswordPage: "https://account.apple.com/account/manage/section/security", savesSent: true,
                              unkept: ["notes"], auth: .login),
            MailKnownProvider(id: "yahoo", name: "Yahoo", domains: ["yahoo.com", "ymail.com", "rocketmail.com", "yahoo.co.uk", "yahoo.fr", "yahoo.de",
                                                                    "yahoo.es", "yahoo.it", "yahoo.ca", "yahoo.com.au", "yahoo.co.jp", "yahoo.co.in"],
                              mx: ["yahoodns.net"], imap: ("imap.mail.yahoo.com", 993, .tls), smtp: ("smtp.mail.yahoo.com", 465, .tls),
                              appPasswordPage: "https://login.yahoo.com/myaccount/security/app-password", savesSent: true),
            MailKnownProvider(id: "aol", name: "AOL", domains: ["aol.com", "aim.com"], mx: ["mx.aol.com"],
                              imap: ("imap.aol.com", 993, .tls), smtp: ("smtp.aol.com", 465, .tls),
                              appPasswordPage: "https://login.aol.com/myaccount/security/app-password", savesSent: true),
            MailKnownProvider(id: "fastmail", name: "Fastmail", domains: ["fastmail.com", "fastmail.fm", "fastmail.cn", "fastmail.co.uk", "fastmail.com.au",
                                                                          "fastmail.de", "fastmail.es", "fastmail.in", "fastmail.jp", "fastmail.net",
                                                                          "fastmail.nl", "fastmail.se", "fastmail.to", "fastmail.us", "messagingengine.com"],
                              mx: ["messagingengine.com"], imap: ("imap.fastmail.com", 993, .tls), smtp: ("smtp.fastmail.com", 465, .tls),
                              appPasswordPage: "https://app.fastmail.com/settings/security/apppasswords"),
            MailKnownProvider(id: "gmx", name: "GMX", domains: ["gmx.com", "gmx.net", "gmx.de", "gmx.at", "gmx.ch", "gmx.us"], mx: ["gmx.net", "gmx.com"],
                              imap: ("imap.gmx.com", 993, .tls), smtp: ("mail.gmx.com", 587, .starttls), appPassword: false,
                              imapSettingPage: "https://www.gmx.com/mail/settings/"),
            MailKnownProvider(id: "yandex", name: "Yandex", domains: ["yandex.ru", "yandex.com", "ya.ru", "yandex.by", "yandex.kz", "yandex.ua"],
                              mx: ["yandex.net", "yandex.ru"], imap: ("imap.yandex.com", 993, .tls), smtp: ("smtp.yandex.com", 465, .tls),
                              appPasswordPage: "https://id.yandex.com/security/app-passwords"),
            // Proton's own servers speak no IMAP; its Bridge on this Mac does.
            MailKnownProvider(id: "proton", name: "Proton Mail Bridge", domains: ["proton.me", "protonmail.com", "pm.me", "protonmail.ch"],
                              mx: ["protonmail.ch"], imap: ("127.0.0.1", 1143, .starttls), smtp: ("127.0.0.1", 1025, .starttls), appPassword: true),
        ]
        for region in zohoRegions {
            let personal = region.tld == "com" ? ["zoho.com", "zohomail.com"] : ["zoho." + region.tld, "zohomail." + region.tld]
            out.append(MailKnownProvider(id: region.tld == "com" ? "zoho" : "zoho-" + region.tld.replacingOccurrences(of: ".", with: "-"), name: "Zoho Mail",
                                         domains: personal, mx: [region.tld == "ca" ? "zohocloud.ca" : "zoho." + region.tld],
                                         imap: (region.imap, 993, .tls), smtp: (region.smtp, 465, .tls),
                                         appPasswordPage: "https://accounts.zoho.\(region.tld == "ca" ? "com" : region.tld)/home#security/app_password",
                                         imapSettingPage: "https://mail.zoho.\(region.tld == "ca" ? "com" : region.tld)/zm/#settings/all/mailaccounts",
                                         unkept: ["outbox", "templates", "snoozed"]))
        }
        return out
    }()

    public static func by(id: String) -> MailKnownProvider? { all.first { $0.id == id } }

    /// The provider an address's own domain names.
    public static func by(domain: String) -> MailKnownProvider? {
        let d = domain.lowercased()
        return all.first { $0.domains.contains(d) }
    }

    /// The provider an MX host belongs to: a company's domain on iCloud,
    /// Zoho, Fastmail, Google or Microsoft. A company on Zoho signs in at
    /// imappro.zoho.*.
    public static func by(mx host: String) -> MailKnownProvider? {
        let h = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard let found = all.first(where: { $0.mx.contains { h == $0 || h.hasSuffix("." + $0) } }) else { return nil }
        guard found.id.hasPrefix("zoho"), let region = zohoRegions.first(where: { found.mx.contains($0.tld == "ca" ? "zohocloud.ca" : "zoho." + $0.tld) }) else {
            return found
        }
        var pro = found
        pro.imap.host = region.pro.0
        pro.smtp.host = region.pro.1
        return pro
    }
}

// MARK: - autoconfig

/// Thunderbird's config-v1.1 (autoconfig.<domain>, .well-known, ISPDB):
/// its first IMAP server and its first SMTP one.
public enum MailAutoconfig {
    public static func read(_ xml: Data, address: String) -> MailServerSetup? {
        let reader = Reader()
        let parser = XMLParser(data: xml)
        parser.delegate = reader
        guard parser.parse() || reader.imap != nil else { return nil }
        guard let imap = reader.imap, let smtp = reader.smtp, !imap.host.isEmpty, !smtp.host.isEmpty else { return nil }
        let local = String(address.split(separator: "@").first ?? "")
        let domain = String(address.split(separator: "@").last ?? "")
        func user(_ said: String) -> String {
            said.replacingOccurrences(of: "%EMAILADDRESS%", with: address).replacingOccurrences(of: "%EMAILLOCALPART%", with: local)
                .replacingOccurrences(of: "%EMAILDOMAIN%", with: domain)
        }
        func security(_ said: String, port: Int) -> MailSecurity {
            switch said.uppercased() {
            case "SSL", "TLS": return .tls
            case "STARTTLS": return .starttls
            default: return port == 993 || port == 465 ? .tls : .starttls
            }
        }
        func host(_ said: String) -> String { said.replacingOccurrences(of: "%EMAILDOMAIN%", with: domain) }
        return MailServerSetup(address: address, imapHost: host(imap.host), imapPort: imap.port ?? 993, imapSecurity: security(imap.socket, port: imap.port ?? 993),
                               imapUser: user(imap.user.isEmpty ? "%EMAILADDRESS%" : imap.user), smtpHost: host(smtp.host), smtpPort: smtp.port ?? 465,
                               smtpSecurity: security(smtp.socket, port: smtp.port ?? 465), smtpUser: user(smtp.user.isEmpty ? "%EMAILADDRESS%" : smtp.user),
                               provider: reader.id, foundBy: "autoconfig")
    }

    final class Reader: NSObject, XMLParserDelegate {
        struct Server { var host = "", port: Int?, socket = "", user = "" }
        var imap: Server?
        var smtp: Server?
        var id = ""
        private var current: Server?
        private var kind = ""
        private var text = ""

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            text = ""
            switch name {
            case "emailProvider": id = attributes["id"] ?? ""
            case "incomingServer", "outgoingServer":
                kind = attributes["type"]?.lowercased() ?? ""
                current = Server()
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch name {
            case "hostname": current?.host = value
            case "port": current?.port = Int(value)
            case "socketType": current?.socket = value
            case "username": current?.user = value
            case "incomingServer":
                if kind == "imap", imap == nil, let current { imap = current }
                current = nil
            case "outgoingServer":
                if kind == "smtp", smtp == nil, let current { smtp = current }
                current = nil
            default: break
            }
            text = ""
        }
    }

    /// The places autoconfig is asked, in order (Thunderbird's own).
    public static func urls(domain: String, address: String) -> [URL] {
        let q = address.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? address
        return [
            "https://autoconfig.\(domain)/mail/config-v1.1.xml?emailaddress=\(q)",
            "https://\(domain)/.well-known/autoconfig/mail/config-v1.1.xml?emailaddress=\(q)",
            "https://autoconfig.thunderbird.net/v1.1/\(domain)",
        ].compactMap(URL.init(string:))
    }
}

// MARK: - DNS

/// MX and SRV records, by the system's resolver (dnssd).
public enum MailDNS {
    final class Box: @unchecked Sendable {
        var records: [(priority: Int, host: String, port: Int)] = []
    }

    /// The domain's mail exchangers, best first.
    public static func mx(_ domain: String, timeout: TimeInterval = 4) async -> [String] {
        await query(domain, type: UInt16(kDNSServiceType_MX), timeout: timeout).sorted { $0.priority < $1.priority }.map(\.host)
    }

    /// RFC 6186's SRV: `_imaps._tcp.<domain>`, `_submission._tcp.<domain>`.
    public static func srv(_ name: String, timeout: TimeInterval = 4) async -> [(host: String, port: Int)] {
        await query(name, type: UInt16(kDNSServiceType_SRV), timeout: timeout).sorted { $0.priority < $1.priority }
            .filter { $0.host != "." && !$0.host.isEmpty }.map { ($0.host, $0.port) }
    }

    static func query(_ name: String, type: UInt16, timeout: TimeInterval) async -> [(priority: Int, host: String, port: Int)] {
        await Task.detached(priority: .userInitiated) { () -> [(priority: Int, host: String, port: Int)] in
            let box = Box()
            var ref: DNSServiceRef?
            let context = Unmanaged.passRetained(box)
            let callback: DNSServiceQueryRecordReply = { _, flags, _, error, _, _, rrtype, rdlen, rdata, _, ctx in
                guard Int(error) == kDNSServiceErr_NoError, let rdata, let ctx else { return }
                let box = Unmanaged<Box>.fromOpaque(ctx).takeUnretainedValue()
                let bytes = [UInt8](UnsafeRawBufferPointer(start: rdata, count: Int(rdlen)))
                if rrtype == UInt16(kDNSServiceType_MX), bytes.count > 2 {
                    box.records.append((Int(bytes[0]) << 8 | Int(bytes[1]), MailDNS.name(bytes, from: 2), 0))
                } else if rrtype == UInt16(kDNSServiceType_SRV), bytes.count > 6 {
                    let priority = Int(bytes[0]) << 8 | Int(bytes[1])
                    let port = Int(bytes[4]) << 8 | Int(bytes[5])
                    box.records.append((priority, MailDNS.name(bytes, from: 6), port))
                }
                _ = flags
            }
            let status = DNSServiceQueryRecord(&ref, 0, 0, name, type, UInt16(kDNSServiceClass_IN), callback, context.toOpaque())
            defer {
                if let ref { DNSServiceRefDeallocate(ref) }
                context.release()
            }
            guard Int(status) == kDNSServiceErr_NoError, let ref else { return [] }
            let fd = DNSServiceRefSockFD(ref)
            let until = Date().addingTimeInterval(timeout)
            // Answers come while the socket has something; a short quiet after the first means all came.
            while Date() < until {
                let wait = box.records.isEmpty ? min(1, until.timeIntervalSinceNow) : 0.25
                var one = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let ready = poll(&one, 1, Int32(max(0, wait) * 1000))
                if ready > 0 {
                    if Int(DNSServiceProcessResult(ref)) != kDNSServiceErr_NoError { break }
                } else if !box.records.isEmpty || ready < 0 {
                    break
                }
            }
            return box.records
        }.value
    }

    /// A name in DNS's wire form (length-prefixed labels).
    static func name(_ bytes: [UInt8], from start: Int) -> String {
        var labels: [String] = []
        var at = start
        while at < bytes.count {
            let n = Int(bytes[at])
            if n == 0 || n & 0xC0 != 0 { break }
            at += 1
            guard at + n <= bytes.count else { break }
            labels.append(String(decoding: bytes[at..<(at + n)], as: UTF8.self))
            at += n
        }
        return labels.joined(separator: ".")
    }
}

// MARK: - finding

public enum MailFinding {
    /// What was found for an address: an IMAP setup, or a provider Yab
    /// reaches by its API (Gmail, Microsoft), or nothing.
    public enum Found: Sendable, Equatable {
        case imap(MailServerSetup, MailKnownProvider?)
        case gmail
        case microsoft
        case none
    }

    /// The chain, stopping at the first answer: known, autoconfig, ISPDB,
    /// MX (and the MX's domain through autoconfig again), SRV, a guess.
    /// `fetch` is the web, a test's own in tests.
    public static func find(_ address: String, fetch: @Sendable (URL) async -> Data? = MailFinding.get,
                            mx: @Sendable (String) async -> [String] = { await MailDNS.mx($0) },
                            srv: @Sendable (String) async -> [(host: String, port: Int)] = { await MailDNS.srv($0) }) async -> Found {
        let address = address.trimmingCharacters(in: .whitespaces).lowercased()
        guard let domain = address.split(separator: "@").last.map(String.init), address.contains("@"), domain.contains(".") else { return .none }
        if let known = MailKnownProviders.by(domain: domain) { return route(known, address) }
        for url in MailAutoconfig.urls(domain: domain, address: address) {
            if let data = await fetch(url), var setup = MailAutoconfig.read(data, address: address) {
                if url.host == "autoconfig.thunderbird.net" { setup.foundBy = "ispdb" }
                if let known = MailKnownProviders.by(mx: setup.imapHost) { setup.provider = known.id; setup.savesSent = known.savesSent }
                return .imap(setup, MailKnownProviders.by(id: setup.provider))
            }
        }
        let exchangers = await mx(domain)
        if let first = exchangers.first {
            if let known = MailKnownProviders.by(mx: first) {
                if known.route != .imap { return route(known, address) }
                var setup = known.setup(for: address)
                setup.foundBy = "mx"
                return .imap(setup, known)
            }
            // The MX's own domain (mx1.hostingco.net: hostingco.net) through ISPDB.
            let parts = first.split(separator: ".")
            if parts.count >= 2 {
                let mxDomain = parts.suffix(2).joined(separator: ".")
                if mxDomain != domain, let data = await fetch(URL(string: "https://autoconfig.thunderbird.net/v1.1/\(mxDomain)")!),
                   var setup = MailAutoconfig.read(data, address: address) {
                    setup.foundBy = "mx-ispdb"
                    return .imap(setup, nil)
                }
            }
        }
        let imaps = await srv("_imaps._tcp." + domain), submission = await srv("_submission._tcp." + domain)
        if let imap = imaps.first {
            let smtp = submission.first
            return .imap(MailServerSetup(address: address, imapHost: imap.host, imapPort: imap.port, imapSecurity: .tls,
                                         smtpHost: smtp?.host ?? imap.host, smtpPort: smtp?.port ?? 587,
                                         smtpSecurity: (smtp?.port ?? 587) == 465 ? .tls : .starttls, foundBy: "srv"), nil)
        }
        return .imap(MailServerSetup(address: address, imapHost: "imap." + domain, smtpHost: "smtp." + domain, smtpPort: 587,
                                     smtpSecurity: .starttls, foundBy: "guess"), nil)
    }

    static func route(_ known: MailKnownProvider, _ address: String) -> Found {
        switch known.route {
        case .gmail: return .gmail
        case .microsoft: return .microsoft
        case .imap: return .imap(known.setup(for: address), known)
        }
    }

    /// One GET with a short wait; nil for anything but a 200.
    @Sendable public static func get(_ url: URL) async -> Data? {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 6)
        request.setValue("\(Brand.name)", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await MailGmail.uncached.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }
}
