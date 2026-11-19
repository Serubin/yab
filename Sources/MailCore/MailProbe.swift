import Foundation

// mail_probe (docs/mail-providers.md, M3): an account's servers tried step
// by step, found, named, reached, TLS, the password, for an agent and for
// Settings › Mail's own check to read. It never returns a password and
// never takes one: it tries what the keychain holds for the address.

/// An IMAP account's password, kept in the keychain under `Fast Mail` as
/// Gmail's refresh token is, its value a JSON of what the kind needs
/// ({"kind":"imap","password":…}). A test world's fake account keeps its
/// fake one in the world's settings, never in the keychain.
public enum MailSecret {
    static func fakeKey(_ account: String) -> String { "mail.fake.password." + account.lowercased() }

    @discardableResult
    public static func save(password: String, for account: String) -> Bool {
        if Store.testing, Store.settings.string(forKey: "mail.fake.imap." + account.lowercased()) != nil {
            Store.settings.set(password, forKey: fakeKey(account))
            return true
        }
        guard let data = try? JSONSerialization.data(withJSONObject: ["kind": "imap", "password": password]) else { return false }
        return MailKeychain.save(String(decoding: data, as: UTF8.self), for: account)
    }

    public static func password(for account: String) -> String? {
        if Store.testing, let fake = Store.settings.string(forKey: fakeKey(account)) { return fake }
        guard let kept = MailKeychain.token(for: account), let data = kept.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], json["kind"] as? String == "imap" else { return nil }
        return json["password"] as? String
    }

    /// A password as pasted (#441): copied off a provider's page it comes
    /// with the line's end, a space after it, or in groups with spaces
    /// between (Google's), and the server refused it. An app password has
    /// no space in it; any other loses only what is around it, line ends
    /// and all, never a space inside.
    public static func cleaned(_ typed: String, appPassword: Bool) -> String {
        let around = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        return appPassword ? around.filter { !$0.isWhitespace } : around
    }

    public static func forget(_ account: String) {
        Store.settings.removeObject(forKey: fakeKey(account))
        MailKeychain.forget(account)
    }
}

public enum MailProbe {
    /// One server's steps, as an agent reads them.
    public struct Server: Sendable, Equatable {
        public var host: String
        public var port: Int
        public var security: MailSecurity
        public var dns = "not tried"
        public var tcp = "not tried"
        public var tls = "not tried"
        public var auth = "not tried"
        public var said = ""
        public var hint = ""
        /// The sign-in way the last try used: nil PLAIN where offered.
        public var way: MailPasswordWay?

        public var json: [String: Any] {
            var out: [String: Any] = ["host": host, "port": port, "security": security.rawValue, "dns": dns, "tcp": tcp, "tls": tls, "auth": auth]
            if !auth.hasPrefix("not tried") { out["auth_way"] = (way ?? .plain).rawValue }
            if !said.isEmpty { out["server_said"] = said }
            if !hint.isEmpty { out["hint"] = hint }
            return out
        }

        public var ok: Bool { auth == "ok" }
    }

    public struct Result: Sendable {
        public var address: String
        public var provider = ""
        public var foundBy = ""
        public var route = "imap"
        public var setup: MailServerSetup?
        public var imap: Server?
        public var smtp: Server?
        public var appPasswordPage = ""
        public var imapSettingPage = ""

        public var json: [String: Any] {
            var out: [String: Any] = ["address": address, "provider": provider, "found_by": foundBy, "route": route]
            if let imap { out["imap"] = imap.json }
            if let smtp { out["smtp"] = smtp.json }
            if !appPasswordPage.isEmpty { out["app_password_page"] = appPasswordPage }
            if !imapSettingPage.isEmpty { out["imap_setting_page"] = imapSettingPage }
            if route != "imap" { out["note"] = route == "gmail" ? "Gmail connects with Google's sign-in, not a password." : "Outlook and Microsoft 365 wait for \(Brand.name)'s Microsoft sign-in." }
            return out
        }

        public var ok: Bool { (imap?.ok ?? false) && (smtp?.ok ?? false) }
    }

    /// Both servers tried with a password, as Add Account does. iCloud's
    /// IMAP takes the name before @ or the whole address: the other is tried
    /// when the first is refused or its line closes (#441; Apple's help: "if
    /// it can't connect, use the full address"). Answers the setup that
    /// worked, with the sign-in ways that worked kept for the sync.
    public static func connect(_ setup: MailServerSetup, password: String) async -> (Result, MailServerSetup) {
        var setup = setup
        let account = setup.address.lowercased()
        var result = await run(account, setup: setup, password: password)
        if ["authRejected", "appPasswordRequired", "closed"].contains(result.imap?.hint ?? ""), setup.imapUser != account {
            var whole = setup
            whole.imapUser = account
            let again = await run(account, step: "imap", setup: whole, password: password)
            if again.imap?.ok == true || result.imap?.hint == "closed" {
                // Worked, or at least said why where the first said nothing.
                if again.imap?.ok == true { setup = whole }
                result.imap = again.imap
            }
        }
        if let imap = result.imap, imap.ok { setup.imapAuth = imap.way }
        if let smtp = result.smtp, smtp.ok { setup.smtpAuth = smtp.way }
        result.setup = setup
        return (result, setup)
    }

    /// A host's name looked up: "ok", or "not found".
    static func resolves(_ host: String) async -> Bool {
        await Task.detached(priority: .userInitiated) { () -> Bool in
            var hints = addrinfo(ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM, ai_protocol: 0, ai_addrlen: 0,
                                 ai_canonname: nil, ai_addr: nil, ai_next: nil)
            var result: UnsafeMutablePointer<addrinfo>?
            let status = getaddrinfo(host, nil, &hints, &result)
            if let result { freeaddrinfo(result) }
            return status == 0
        }.value
    }

    /// The steps for an address: `step` "find", "imap", "smtp" or "all".
    /// `setup` the account's own when it has one, else found now;
    /// `password` what the keychain holds, nil to stop before signing in.
    public static func run(_ address: String, step: String = "all", setup kept: MailServerSetup? = nil, password: String? = nil,
                           find: (String) async -> MailFinding.Found = { await MailFinding.find($0) }) async -> Result {
        var out = Result(address: address.lowercased())
        var setup = kept
        var known: MailKnownProvider?
        if setup == nil {
            switch await find(address) {
            case .imap(let found, let provider):
                setup = found
                known = provider
            case .gmail:
                out.route = "gmail"
                out.provider = "gmail"
                out.foundBy = "known"
                return out
            case .microsoft:
                out.route = "microsoft"
                out.provider = "microsoft"
                out.foundBy = "known"
                return out
            case .none:
                out.foundBy = "nothing"
                return out
            }
        } else {
            known = MailKnownProviders.by(id: kept?.provider ?? "")
        }
        guard let setup else { return out }
        out.setup = setup
        out.provider = setup.provider.isEmpty ? (known?.id ?? "") : setup.provider
        out.foundBy = kept != nil ? "account" : setup.foundBy
        out.appPasswordPage = known?.appPasswordPage ?? ""
        out.imapSettingPage = known?.imapSettingPage ?? ""
        if step == "find" { return out }
        if step == "all" || step == "imap" { out.imap = await imap(setup, password: password, known: known) }
        if step == "all" || step == "smtp" { out.smtp = await smtp(setup, password: password, known: known) }
        return out
    }

    /// How long before a line closed at the sign-in is tried again, the
    /// other way: a moment, so a server counting fast reconnects doesn't.
    static let again: UInt64 = 800_000_000

    /// IMAP's steps; a line closed at the sign-in with nothing said is tried
    /// once more on a new line the other way (#441: iCloud's PLAIN closed
    /// the line on real accounts where LOGIN takes the same password).
    static func imap(_ setup: MailServerSetup, password: String?, known: MailKnownProvider?) async -> Server {
        let first = await imap(setup, password: password, known: known, auth: setup.imapAuth)
        guard first.auth == "closed" else { return first }
        try? await Task.sleep(nanoseconds: again)
        return await imap(setup, password: password, known: known, auth: (setup.imapAuth ?? .plain).other)
    }

    static func imap(_ setup: MailServerSetup, password: String?, known: MailKnownProvider?, auth: MailPasswordWay?) async -> Server {
        var server = Server(host: setup.imapHost, port: setup.imapPort, security: setup.imapSecurity)
        let found = MailSocket.local(setup.imapHost) || MailStandIn.covers(setup.imapHost) ? true : await resolves(setup.imapHost)
        guard found else {
            server.dns = "not found"
            server.hint = MailServerTrouble.dnsNotFound.hint
            return server
        }
        server.dns = "ok"
        let socket: MailSocket
        do {
            socket = try MailSocket(host: setup.imapHost, port: setup.imapPort, security: setup.imapSecurity)
        } catch {
            return failed(server, MailServerTrouble.from(error, step: "connect"))
        }
        let client = IMAPClient(socket: socket)
        defer { Task { await socket.close() } }
        do {
            try await client.greet(security: setup.imapSecurity)
            server.tcp = "ok"
            server.tls = setup.imapSecurity == .none || socket.standIn ? "none (this Mac)" : "ok"
        } catch {
            return failed(server, MailServerTrouble.from(error, step: "greeting"))
        }
        guard let password else {
            server.auth = "not tried (no password in the keychain)"
            if known?.appPassword == true { server.hint = "appPasswordRequired" }
            return server
        }
        server.way = auth
        do {
            try await client.login(user: setup.imapUser, password: password, auth: auth)
            server.auth = "ok"
        } catch {
            var trouble = MailServerTrouble.from(error, step: "login")
            // A known provider that wants an app password says so plainly.
            if case .authRejected(let said) = trouble, known?.appPassword == true { trouble = .appPasswordRequired(said) }
            server.auth = trouble == .closed ? "closed" : "rejected"
            server.said = trouble.said
            server.hint = trouble.hint
            return server
        }
        await client.logout()
        return server
    }

    /// SMTP's steps, a line closed at AUTH tried again the other way as IMAP's is.
    static func smtp(_ setup: MailServerSetup, password: String?, known: MailKnownProvider?) async -> Server {
        let first = await smtp(setup, password: password, known: known, auth: setup.smtpAuth)
        guard first.auth == "closed" else { return first }
        try? await Task.sleep(nanoseconds: again)
        return await smtp(setup, password: password, known: known, auth: (setup.smtpAuth ?? .plain).other)
    }

    static func smtp(_ setup: MailServerSetup, password: String?, known: MailKnownProvider?, auth: MailPasswordWay?) async -> Server {
        var server = Server(host: setup.smtpHost, port: setup.smtpPort, security: setup.smtpSecurity)
        let found = MailSocket.local(setup.smtpHost) || MailStandIn.covers(setup.smtpHost) ? true : await resolves(setup.smtpHost)
        guard found else {
            server.dns = "not found"
            server.hint = MailServerTrouble.dnsNotFound.hint
            return server
        }
        server.dns = "ok"
        var smtp = MailSMTP(host: setup.smtpHost, port: setup.smtpPort, security: setup.smtpSecurity, user: setup.smtpUser, password: password ?? "")
        smtp.hello = "yab.local"
        smtp.auth = auth
        do {
            let (socket, _) = try await smtp.open(authenticate: false)
            server.tcp = "ok"
            server.tls = setup.smtpSecurity == .none || socket.standIn ? "none (this Mac)" : "ok"
            await socket.close()
        } catch {
            return failed(server, MailServerTrouble.from(error, step: "greeting"))
        }
        guard password != nil else {
            server.auth = "not tried (no password in the keychain)"
            return server
        }
        server.way = auth
        do {
            _ = try await smtp.check()
            server.auth = "ok"
        } catch {
            var trouble = MailServerTrouble.from(error, step: "login")
            if case .authRejected(let said) = trouble, known?.appPassword == true { trouble = .appPasswordRequired(said) }
            server.auth = trouble == .closed ? "closed" : "rejected"
            server.said = trouble.said
            server.hint = trouble.hint
        }
        return server
    }

    static func failed(_ server: Server, _ trouble: MailServerTrouble) -> Server {
        var server = server
        switch trouble {
        case .tcpRefused, .timedOut, .offline, .closed:
            server.tcp = trouble.hint
        case .tlsFailed:
            server.tcp = "ok"
            server.tls = "failed"
        default:
            server.tcp = "ok"
        }
        server.said = trouble.said
        server.hint = trouble.hint
        return server
    }
}
