import AppKit

// Yab's own passwords, put into Apple Passwords through the helper Yab
// already pairs with (ApplePasswords.swift), one save a login. Offered once,
// right after Apple Passwords is first connected, and again whenever asked
// from its row's ⋯ menu in Settings › Passwords. A login Passwords already
// has for the site and name is left as it is. Yab keeps its copies.

@MainActor
enum PasswordsToApple {
    /// Metadata and the existing confirmation route, read only when asked.
    /// Each field owns its route so tests never need a live vault or helper.
    @MainActor
    struct CommandRoute {
        struct State {
            let appleConnected: Bool
            let savedCount: Int
            var available: Bool { appleConnected && savedCount > 0 }
        }

        var state: @MainActor () -> State
        var start: @MainActor () -> Void

        var available: Bool { state().available }
        func run() {
            guard available else { return }
            start()
        }
        func available(for provider: String) -> Bool {
            provider == PasswordManagers.apple && available
        }

        static var live: CommandRoute {
            CommandRoute(state: {
                guard PasswordManagers.Connections.shared.connection(PasswordManagers.apple) != nil else {
                    return State(appleConnected: false, savedCount: 0)
                }
                return State(appleConnected: true, savedCount: PasswordsToApple.savedCount)
            }, start: { PasswordsToApple.start() })
        }
    }

    /// How many logins Yab holds, for the field's command list, which asks on
    /// every key. Read there, the keychain held each key 400 ms behind its lock:
    /// the count is taken off the main thread, again only when the Vault changed.
    private static var counted: (changes: Int, count: Int)?
    private static var counting = false
    private static var savedCount: Int {
        let changes = Vault.changes
        if counted?.changes != changes, !counting {
            counting = true
            Task.detached(priority: .utility) {
                let count = Vault.entries().count
                await MainActor.run {
                    counted = (changes, count)
                    counting = false
                }
            }
        }
        return counted?.count ?? 0
    }

    /// The offer after connecting was made: never again on its own.
    private static let offeredKey = "applePasswordsImportOffered"
    private static var running = false

    /// After a pairing that worked: the question once, if Yab has any.
    static func offerOnce() async {
        guard !UserDefaults.standard.bool(forKey: offeredKey) else { return }
        UserDefaults.standard.set(true, forKey: offeredKey)
        await ask()
    }

    /// The ⋯ menu's Import: pairs first when this launch hasn't.
    static func start() {
        Task { @MainActor in
            if !(await ApplePasswords.shared.isPaired) {
                // The pairing itself would offer: this asks instead.
                UserDefaults.standard.set(true, forKey: offeredKey)
                await ApplePasswordsPairing.pair()
                guard await ApplePasswords.shared.isPaired else { return }
            }
            await ask()
        }
    }

    private static func ask() async {
        let count = Vault.entries().count
        guard count > 0, !running, let browser = Extensions.here.browser else { return }
        let yes = await Questions.shared.ask(question(count: count))
        guard yes else { return }
        browser.proveOwner("import your passwords into Apple Passwords") {
            Task { @MainActor in await run(browser) }
        }
    }

    /// The same card in the live offer and the isolated keyboard/visual checks.
    static func question(count: Int) -> Question {
        Question(
            title: "Import your \(Brand.name) passwords into Apple Passwords?",
            detail: "\(count) password\(count == 1 ? "" : "s") saved in \(Brand.name), on this Mac and your iPhone too. \(Brand.name) keeps its own.",
            icon: PasswordManagers.icon(PasswordManagers.apple),
            ownIcon: true,
            yes: "Import",
            no: "Not Now",
            place: .plain
        )
    }

    private static func run(_ browser: Browser) async {
        guard !running else { return }
        running = true
        defer { running = false }
        let logins = await Task.detached(priority: .userInitiated) { Vault.all() }.value
        var added = 0, kept = 0
        var known: [String: Set<String>] = [:]
        for login in logins {
            do {
                if known[login.host] == nil {
                    known[login.host] = Set(try await ApplePasswords.shared.logins(for: login.host).map(\.user))
                }
                if known[login.host]?.contains(login.user) == true { kept += 1; continue }
                try await ApplePasswords.shared.save(host: login.host, user: login.user, password: login.password)
                known[login.host, default: []].insert(login.user)
                added += 1
            } catch {
                ApplePasswords.log.error("import stopped: \(String(describing: error), privacy: .public)")
                say("Apple Passwords stopped after \(added) of \(logins.count - kept). Import again from its ⋯ menu", mark: "exclamationmark.triangle", browser)
                return
            }
        }
        if added == 0 {
            say("Apple Passwords already has every \(Brand.name) password", mark: "key", browser)
        } else {
            say("Imported \(added) password\(added == 1 ? "" : "s") into Apple Passwords", mark: "key", browser)
        }
    }

    /// In Settings' corner when Settings is in front, else the window's.
    private static func say(_ text: String, mark: String, _ browser: Browser) {
        let settings = SettingsWindow.shared.window?.isKeyWindow == true
        browser.announce(text, mark: mark, on: settings ? SettingsWindow.shared.toaster : nil)
    }
}
