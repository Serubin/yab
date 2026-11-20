import AppKit
import Testing
@testable import Fast

/// Command parity only. Every route supplies metadata and a recording action;
/// no fixture may pair, open a real vault, prove ownership or import a password.
@MainActor
@Suite(.serialized)
struct ApplePasswordImportCommandTests {
    private let command = Command.importYabPasswords
    private let names = ["Import Yab Passwords…", "Import Yab Passwords...", "import passwords",
                         "import Yab passwords", "import to Apple Passwords", "importpasswords"]

    @Test func routeConstructionIsLazyAndInstancesDoNotShareState() {
        var reads = 0, starts = 0
        var connected = true
        let route = PasswordsToApple.CommandRoute(state: {
            reads += 1
            return .init(appleConnected: connected, savedCount: 2)
        }, start: { starts += 1 })
        let other = PasswordsToApple.CommandRoute(state: { .init(appleConnected: false, savedCount: 2) }, start: { Issue.record("Other route ran") })
        #expect(reads == 0 && starts == 0)
        #expect(!other.available)
        #expect(!route.available(for: "unrelated-manager"))
        #expect(reads == 0, "An unrelated Settings row must not even read Apple metadata")
        #expect(route.available(for: PasswordManagers.apple))
        #expect(reads == 1 && starts == 0)
        route.run()
        #expect(reads == 2 && starts == 1)
        connected = false
        route.run()
        #expect(reads == 3 && starts == 1, "A retained Settings action must recheck metadata too")
    }

    @Test(arguments: [false, true], [0, 2])
    func availabilityAndExecutionUseCurrentMetadata(_ connected: Bool, _ count: Int) throws {
        try world { f in
            f.connected = connected; f.count = count
            #expect(command.available(in: f.browser) == (connected && count > 0))
            #expect(f.browser.passwordImportRoute.available(for: PasswordManagers.apple) == command.available(in: f.browser))
            #expect(!f.browser.passwordImportRoute.available(for: "other-manager"))
            command.run(in: f.browser)
            #expect(f.starts == (connected && count > 0 ? 1 : 0))
            #expect(command.keys.isEmpty && !command.opens(in: f.browser))
        }
    }

    @Test(arguments: [false, true])
    func exactNamesLeadRealHistoryAndMergedSuggestionsWithoutTakingReturn(_ experimental: Bool) throws {
        // The same typed History/command path, with answer()'s public favicon
        // lookups suppressed by the existing private-window policy.
        try world(purpose: .privateOnly) { f in
            let browser = f.browser
            browser.prefs.menuCommands = experimental
            for words in names {
                let url = URL(string: "https://importpasswords.example.test/reference")!
                browser.history = History([Visit(url: url.absoluteString, key: Address.pretty(url),
                    title: words, count: 500, last: Date(), typed: 100)])
                let found = browser.history.suggestions(for: words, limit: 5)
                // A punctuated name ("Passwords…") never matches a title:
                // titles keep only letters and numbers, and since cfb496b50
                // (#1165) such words skip title matching. Those names have
                // no History competitor; every other one must have a real one.
                let competes = words.allSatisfy { $0.isLetter || $0.isNumber || $0.isWhitespace }
                try #require(found.isEmpty != competes, "History competitor must actually match \(words)")
                if words == "importpasswords" {
                    try #require(browser.history.completion(for: words, among: found) != nil,
                                 "Compact alias must have a real competing address completion")
                }
                browser.query.actionsPage = false
                browser.replaceTyped(words)
                #expect(browser.ending == nil)
                let offers = browser.offers
                #expect(offers.first?.kind == .command(command), "\(words), experimental=\(experimental)")
                #expect(offers.filter { $0.kind == .command(command) }.count == 1)
                #expect(offers.contains { $0.url == url } == competes)
                let lead = try #require(browser.query.lead)
                #expect(offers[lead].kind != .command(command))
                let suggested = (1...4).map { Suggestion(key: words + " web \($0)", title: "", url: nil, kind: .suggested) }
                let merged = SearchSuggestions.merge(suggested, into: offers, lead: lead)
                #expect(merged.list.first?.kind == .command(command))
                #expect(merged.list.contains { $0.kind == .suggested })
                #expect(merged.lead.map { merged.list[$0].id } == offers[lead].id)
                #expect(merged.lead.map { merged.list[$0].kind } != .command(command))
                #expect(f.starts == 0)
            }
        }
    }

    @Test(arguments: [false, true])
    func actionsNamesStayDiscoverableWithoutAnAutomaticImport(_ experimental: Bool) throws {
        try world { f in
            f.browser.prefs.menuCommands = experimental
            f.browser.query.actionsPage = true
            for words in names {
                f.browser.replaceTyped(words)
                #expect(f.browser.offers.first?.kind == .command(command))
                #expect(f.browser.offers.filter { $0.kind == .command(command) }.count == 1)
                #expect(f.browser.query.current.map { f.browser.offers[$0].kind } != .command(command))
                #expect(f.starts == 0)
            }
            f.browser.replaceTyped("importpasswords")
            try #require(f.browser.offers.count == 1, "This must exercise the real only-Import Actions result")
            #expect(f.browser.query.lead == nil && f.browser.query.current == nil)
        }
    }

    @Test(arguments: [false, true])
    func actualReturnUsesSafeFallbackAndNeverImports(_ actions: Bool) throws {
        try world { f in
            guard #available(macOS 15.4, *) else { throw FixtureError.extensionRouteUnavailable }
            let browser = f.browser
            // The existing cross-extension route intercepts the safe search
            // before Tab.go builds WebKit or makes any network request.
            let guest = Tab(bench: true)
            let origin = URL(string: "\(Extensions.scheme)://import-command-fixture/page")!
            try #require(Browser.extensionHost(of: origin) != nil)
            guest.customMark = "key"
            guest.restore(url: origin, title: "Owned nonnetwork Return receiver")
            var navigations: [URL] = []
            guest.onCross = { _, url in navigations.append(url) }
            browser.fieldGuest = guest
            defer { browser.fieldGuest = nil; guest.close() }
            browser.query.actionsPage = actions
            for words in actions ? ["importpasswords"] : names {
                browser.editing = true
                browser.fieldGuest = guest
                browser.replaceTyped(words)
                try #require(browser.offers.first?.kind == .command(command))
                #expect(browser.query.current.map { browser.offers[$0].kind } != .command(command))
                let before = navigations.count
                browser.submit()
                #expect(f.starts == 0)
                #expect(navigations.count == before + 1, "Actual Return must reach the safe fallback")
                #expect(guest.built == nil, "The receiver may not construct a real page")
            }
        }
    }

    @Test(arguments: [false, true])
    func explicitGenericActionsRunOnceAndStaleRowsRecheckAvailability(_ actions: Bool) throws {
        try world { f in
            let browser = f.browser
            browser.query.actionsPage = actions
            browser.replaceTyped(command.title)
            let index = try #require(browser.offers.firstIndex { $0.kind == .command(command) })
            let row = browser.offers[index]
            browser.query.picked = index
            let action = try #require(browser.fieldActions.first { $0.id == "run" })
            #expect(action.title == "Run Command" && action.keys.isEmpty)
            action.run()
            #expect(f.starts == 1)
            f.count = 0
            browser.take(row)
            #expect(f.starts == 1, "A stale explicit row must recheck the current state")
            f.count = 2; f.connected = false
            command.run(in: browser)
            #expect(f.starts == 1)
        }
    }

    @Test func commandFlagHidesOrdinaryMatchesAndUnrelatedReturnPolicyRemains() throws {
        try world { f in
            let browser = f.browser
            FieldUnder.shared.commands = false
            browser.replaceTyped(command.title)
            #expect(!browser.offers.contains { $0.kind == .command(command) })
            FieldUnder.shared.commands = true
            let page = Tab(bench: true)
            page.customMark = "key"
            page.restore(url: URL(string: "import-command-control:page")!, title: "Control")
            browser.lay([page]); browser.activeID = page.id
            browser.replaceTyped("Close Tab")
            let pageLead = try #require(browser.query.lead)
            #expect(browser.offers[pageLead].kind == .command(.closeTab))
            browser.lay([]); browser.activeID = nil; page.close()
            browser.replaceTyped("Close Tab")
            let emptyLead = try #require(browser.query.lead)
            #expect(browser.offers.first?.kind == .command(.closeTab))
            #expect(browser.offers[emptyLead].kind != .command(.closeTab))
        }
    }

    private enum FixtureError: Error { case extensionRouteUnavailable }

    @MainActor private final class Fixture {
        let browser: Browser
        var connected = true
        var count = 2
        var starts = 0
        init(_ browser: Browser) {
            self.browser = browser
            browser.passwordImportRoute = .init(state: { [unowned self] in
                .init(appleConnected: self.connected, savedCount: self.count)
            }, start: { [unowned self] in self.starts += 1 })
        }
    }

    private func world(purpose: BrowserWindowPurpose = .normal, _ check: (Fixture) throws -> Void) throws {
        try #require(Store.testing && Store.unitTests && Store.world != nil && Store.settings !== UserDefaults.standard,
                     "Isolated serial AppKit unit-test world required before any fixture mutation")
        let world = try #require(Store.world)
        _ = NSApplication.shared
        Session.settle()
        let domain = world == "test" ? "net.serubin.pane.test" : "net.serubin.pane.test.\(world)"
        let settings = Store.settings.persistentDomain(forName: domain)
        let field = FieldUnder.shared
        let oldField = (field.commands, field.pages, field.rows, field.firstRow)
        let folders = Folders.shared.browser
        let sharing = Spaces.sharing
        let passkeys = FormRelay.passkeysOffered
        Store.settings.set(false, forKey: "mail")
        Store.settings.set(false, forKey: "search.suggest")
        Store.settings.set([[String: String]](), forKey: FieldFavorites.key)
        let browser = Browser(windowID: UUID(), purpose: purpose)
        browser.lookForMailSignInLink = {}
        browser.dropSpare(); browser.tabs.forEach { $0.customMark = "key"; $0.close() }
        browser.lay([]); browser.activeID = nil
        browser.prefs.searchSuggest = false; browser.prefs.fieldRequests = false
        browser.prefs.menuCommands = true
        browser.history = History([])
        field.commands = true; field.pages = true; field.rows = [FieldUnder.search]; field.firstRow = false
        let f = Fixture(browser)
        defer {
            browser.dismiss(); browser.letGo(); browser.dropSpare()
            browser.dozing?.invalidate(); browser.stuck.timer?.invalidate(); browser.pressure?.cancel()
            browser.passwordImportRoute = .init(state: { .init(appleConnected: false, savedCount: 0) }, start: {})
            field.commands = oldField.0; field.pages = oldField.1; field.rows = oldField.2; field.firstRow = oldField.3
            Folders.shared.browser = folders; Spaces.sharing = sharing; FormRelay.passkeysOffered = passkeys
            Session.settle()
            do {
                let files = try FileManager.default.contentsOfDirectory(atPath: Store.folder.path)
                for name in files where browser.windowID.map({ name.contains($0.uuidString) }) == true {
                    try FileManager.default.removeItem(at: Store.folder.appendingPathComponent(name))
                }
            } catch { Issue.record(error) }
            if let settings { Store.settings.setPersistentDomain(settings, forName: domain) }
            else { Store.settings.removePersistentDomain(forName: domain) }
        }
        try check(f)
    }
}
