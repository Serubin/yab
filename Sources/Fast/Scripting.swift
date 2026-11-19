import AppKit

// AppleScript (Resources/Yab.sdef, docs/applescript.md). Arc's shape, so a
// tab switcher or a launcher written for Arc or Chrome works with the name
// changed: the application's windows, a window's tabs and spaces, a tab's
// title and URL, `select` and `focus`; and Yab's own words for a Raycast
// extension: a Small Window, ⌘J's ask, a Mail thread. Every tab of the window is listed,
// the other spaces' too, as ⌃Tab walks them; private tabs, the bench's and
// Yab's own quiet work are not.
//
// The objects here are made fresh for each question and found again by id:
// Cocoa scripting holds on to an object specifier, never to these.

extension Links {
    func application(_ sender: NSApplication, delegateHandlesKey key: String) -> Bool {
        key == "scriptWindows" || key == "scriptNewTabs"
    }

    /// The browser windows on screen or in the Dock, front to back.
    @objc var scriptWindows: [YabScriptWindow] {
        MainActor.assumeIsolated { YabScriptWindow.all() }
    }

    @objc(valueInScriptWindowsWithUniqueID:)
    func valueInScriptWindows(withUniqueID id: String) -> YabScriptWindow? {
        MainActor.assumeIsolated { YabScriptWindow.all().first { $0.uniqueID == id } }
    }

    /// `make new window`: a new window, as ⌘N. A private one, `with
    /// properties {incognito:true}`, Arc's word, is YabCreateCommand's.
    @objc(insertInScriptWindows:)
    func insertInScriptWindows(_ window: YabScriptWindow) {
        MainActor.assumeIsolated {
            let windows = BrowserWindows.shared
            window.browser = window.pendingIncognito ? windows.newPrivateWindow(from: windows.activeBrowser) : windows.newWindow()
        }
    }

    @objc(insertInScriptWindows:atIndex:)
    func insertInScriptWindows(_ window: YabScriptWindow, at index: Int) { insertInScriptWindows(window) }

    /// `make new tab` told to the application: in the front window.
    @objc var scriptNewTabs: [YabScriptTab] { [] }

    @objc(insertInScriptNewTabs:)
    func insertInScriptNewTabs(_ tab: YabScriptTab) {
        MainActor.assumeIsolated {
            guard let window = YabScriptWindow.all().first else {
                YabScriptWindow.scriptError(YabScriptWindow.cantAssign, "There is no window to open the tab in.")
                return
            }
            window.insertInScriptTabs(tab)
        }
    }

    @objc(insertInScriptNewTabs:atIndex:)
    func insertInScriptNewTabs(_ tab: YabScriptTab, at index: Int) { insertInScriptNewTabs(tab) }
}

@MainActor
@objc(YabScriptWindow)
final class YabScriptWindow: NSObject {
    var browser: Browser?
    /// `incognito` given to `make`, before the window is.
    var pendingIncognito = false

    nonisolated override init() { super.init() }
    init(_ browser: Browser) {
        self.browser = browser
        super.init()
    }

    static func all() -> [YabScriptWindow] {
        let windows = BrowserWindows.shared
        let ours = windows.browsers.compactMap { browser -> (Browser, NSWindow)? in
            guard let window = windows.window(for: browser), window.isVisible || window.isMiniaturized else { return nil }
            return (browser, window)
        }
        // NSApp's own order is front to back, minimized windows last.
        let order = NSApp.orderedWindows
        return ours
            .sorted { (order.firstIndex(of: $0.1) ?? .max) < (order.firstIndex(of: $1.1) ?? .max) }
            .map { YabScriptWindow($0.0) }
    }

    /// errOSACantAssign: what a script is told for a value it can't set.
    static let cantAssign = -10006

    static func scriptError(_ number: Int, _ message: String) {
        guard let command = NSScriptCommand.current() else { return }
        command.scriptErrorNumber = number
        command.scriptErrorString = message
    }

    var window: NSWindow? { browser.flatMap { BrowserWindows.shared.window(for: $0) } }

    @objc var uniqueID: String { (browser?.windowID ?? BrowserWindows.primaryID).uuidString }
    @objc var title: String { window?.title ?? "" }
    @objc var orderedIndex: Int { (Self.all().firstIndex { $0.uniqueID == uniqueID } ?? 0) + 1 }
    @objc var isVisible: Bool { window?.isVisible ?? false }
    @objc var isMiniaturized: Bool {
        get { window?.isMiniaturized ?? false }
        set { newValue ? window?.miniaturize(nil) : window?.deminiaturize(nil) }
    }
    @objc var mode: String { incognito ? "incognito" : "normal" }
    @objc var incognito: Bool {
        get { browser.map { $0.windowPurpose == .privateOnly } ?? pendingIncognito }
        set {
            guard browser == nil else {
                if newValue == incognito { return }
                Self.scriptError(Self.cantAssign, "A window stays as it was made: make a new one.")
                return
            }
            pendingIncognito = newValue
        }
    }

    /// The tabs a script sees, each with the space it is in.
    func listed() -> [(tab: Tab, space: UUID)] {
        guard let browser else { return [] }
        var seen = Set<Tab.ID>()
        var out: [(tab: Tab, space: UUID)] = []
        func take(_ tab: Tab, _ space: UUID) {
            guard !tab.shy, !tab.bench, tab.guest == nil, !Agents.shared.sealed(tab), seen.insert(tab.id).inserted else { return }
            out.append((tab: tab, space: space))
        }
        browser.tabs.forEach { take($0, browser.spaceID) }
        // With spaces off, the others' rows are out of reach, as for ⌃Tab.
        for space in browser.spaces where browser.prefs.usesSpaces && space.id != browser.spaceID {
            browser.parked[space.id]?.tabs.forEach { take($0, space.id) }
        }
        return out
    }

    @objc var scriptTabs: [YabScriptTab] { listed().map { YabScriptTab($0.tab, space: $0.space, in: self) } }

    @objc(valueInScriptTabsWithUniqueID:)
    func valueInScriptTabs(withUniqueID id: String) -> YabScriptTab? {
        listed().first { $0.tab.id.uuidString == id }.map { YabScriptTab($0.tab, space: $0.space, in: self) }
    }

    /// `make new tab with properties {URL: …}`: a tab in front, at the
    /// place a new tab takes. With no URL, the field asks, as ⌘T does.
    @objc(insertInScriptTabs:)
    func insertInScriptTabs(_ made: YabScriptTab) {
        guard let browser else { return }
        guard let given = made.pendingURL else {
            browser.newTab()
            made.tab = browser.active
            made.window = self
            made.spaceID = browser.spaceID
            return
        }
        guard let url = Address.url(from: given) else {
            Self.scriptError(Self.cantAssign, "Not an address: \(given)")
            return
        }
        let tab = browser.open(url, foreground: true)
        made.tab = tab
        made.window = self
        made.spaceID = browser.spaceID
        // A new tab joins the row and comes to the front once its page has
        // drawn, 0.3 s at most (Browser.open): the script's next line asks
        // for it, so the answer waits until it is there.
        let until = Date().addingTimeInterval(1.5)
        while Date() < until, !(browser.tabs.contains { $0 === tab } && browser.activeID == tab.id) {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
    }

    @objc(insertInScriptTabs:atIndex:)
    func insertInScriptTabs(_ made: YabScriptTab, at index: Int) { insertInScriptTabs(made) }

    @objc var activeTab: YabScriptTab? {
        guard let browser, let tab = browser.active, !tab.shy else { return nil }
        return YabScriptTab(tab, space: browser.spaceID, in: self)
    }

    /// Chrome's: one-based, among `scriptTabs`.
    @objc var activeTabIndex: Int {
        get {
            guard let id = browser?.activeID else { return 0 }
            return (listed().firstIndex { $0.tab.id == id } ?? -1) + 1
        }
        set {
            let tabs = listed()
            guard tabs.indices.contains(newValue - 1) else {
                Self.scriptError(Self.cantAssign, "There is no tab \(newValue).")
                return
            }
            YabScriptTab(tabs[newValue - 1].tab, space: tabs[newValue - 1].space, in: self).select()
        }
    }

    @objc var scriptSpaces: [YabScriptSpace] {
        guard let browser else { return [] }
        return browser.spaces.map { YabScriptSpace($0, in: self) }
    }

    @objc(valueInScriptSpacesWithUniqueID:)
    func valueInScriptSpaces(withUniqueID id: String) -> YabScriptSpace? {
        scriptSpaces.first { $0.uniqueID == id }
    }

    @objc var activeSpace: YabScriptSpace? {
        guard let browser else { return nil }
        return YabScriptSpace(browser.space, in: self)
    }

    @objc func handleCloseScriptCommand(_ command: NSScriptCommand) -> Any? {
        window?.performClose(nil)
        return nil
    }

    /// Where Cocoa scripting finds this window again: by id, among the
    /// application's.
    nonisolated override var objectSpecifier: NSScriptObjectSpecifier? { MainActor.assumeIsolated { specifier } }

    private var specifier: NSScriptObjectSpecifier? {
        // 'capp', the application class, the dictionary's: NSApp's own
        // classDescription is none.
        guard let app = NSScriptSuiteRegistry.shared().classDescription(withAppleEventCode: 0x6361_7070) else { return nil }
        return NSUniqueIDSpecifier(containerClassDescription: app, containerSpecifier: nil,
                                   key: "scriptWindows", uniqueID: uniqueID)
    }
}

@MainActor
@objc(YabScriptTab)
final class YabScriptTab: NSObject {
    var tab: Tab?
    var spaceID: UUID?
    var window: YabScriptWindow?
    /// The URL given to `make`, before the tab is.
    var pendingURL: String?

    nonisolated override init() { super.init() }
    init(_ tab: Tab, space: UUID, in window: YabScriptWindow) {
        self.tab = tab
        self.spaceID = space
        self.window = window
        super.init()
    }

    @objc var uniqueID: String { tab?.id.uuidString ?? "" }
    @objc var title: String { tab?.label ?? "" }
    @objc(URL) var address: String {
        get { tab.flatMap { ($0.pending ?? $0.address ?? $0.builtPage?.url)?.absoluteString } ?? pendingURL ?? "" }
        set {
            guard let tab else { pendingURL = newValue; return }
            guard let url = Address.url(from: newValue) else {
                YabScriptWindow.scriptError(YabScriptWindow.cantAssign, "Not an address: \(newValue)")
                return
            }
            tab.go(to: url)
        }
    }
    @objc var loading: Bool { tab?.loading ?? false }
    @objc var location: String {
        guard let tab else { return "unpinned" }
        return tab.pin != nil ? "topApp" : tab.kept ? "pinned" : "unpinned"
    }
    @objc var space: YabScriptSpace? {
        guard let window, let browser = window.browser, let spaceID,
              let space = browser.spaces.first(where: { $0.id == spaceID }) else { return nil }
        return YabScriptSpace(space, in: window)
    }

    /// In front of its window, its space brought first if it is another,
    /// and the window in front of Yab's others. The app itself comes
    /// forward only on `activate`, as with Arc and Chrome.
    func select() {
        guard let tab, let browser = window?.browser else { return }
        if browser.tabs.contains(where: { $0.id == tab.id }) {
            browser.select(tab)
        } else if let home = spaceID, browser.parked[home]?.tabs.contains(where: { $0.id == tab.id }) == true {
            // As ⌃Tab lands on another space's tab (Switcher.swift).
            browser.parked[home]?.active = tab.id
            browser.switchSpace(to: home)
            if browser.activeID != tab.id, browser.tabs.contains(where: { $0.id == tab.id }) { browser.select(tab) }
        }
        window?.window?.makeKeyAndOrderFront(nil)
    }

    @objc func handleSelectCommand(_ command: NSScriptCommand) -> Any? { select(); return nil }
    @objc func handleBackCommand(_ command: NSScriptCommand) -> Any? { tab?.back(); return nil }
    @objc func handleForwardCommand(_ command: NSScriptCommand) -> Any? { tab?.forward(); return nil }
    /// On the tab where it is, not brought to the front as a half's own
    /// reload is: Chrome's and Arc's don't select it.
    @objc func handleReloadCommand(_ command: NSScriptCommand) -> Any? { tab?.reload(); return nil }
    @objc func handleStopCommand(_ command: NSScriptCommand) -> Any? {
        if let tab { window?.browser?.stop(tab) }
        return nil
    }

    @objc func handleCloseScriptCommand(_ command: NSScriptCommand) -> Any? {
        guard let tab, let browser = window?.browser else { return nil }
        if browser.tabs.contains(where: { $0.id == tab.id }) {
            browser.close(tab)
        } else if let home = spaceID {
            browser.closeParked(tab, in: home)
        }
        return nil
    }

    nonisolated override var objectSpecifier: NSScriptObjectSpecifier? { MainActor.assumeIsolated { specifier } }

    private var specifier: NSScriptObjectSpecifier? {
        guard let container = window?.objectSpecifier,
              let description = NSScriptClassDescription(for: YabScriptWindow.self) else { return nil }
        return NSUniqueIDSpecifier(containerClassDescription: description, containerSpecifier: container,
                                   key: "scriptTabs", uniqueID: uniqueID)
    }
}

@MainActor
@objc(YabScriptSpace)
final class YabScriptSpace: NSObject {
    let space: Space
    let window: YabScriptWindow

    init(_ space: Space, in window: YabScriptWindow) {
        self.space = space
        self.window = window
        super.init()
    }

    @objc var uniqueID: String { space.id.uuidString }
    @objc var title: String { space.name }
    @objc var icon: String { space.icon }
    /// The light look's, a swatch's or your own; the window's while the
    /// space has none of its own yet.
    @objc var color: String {
        (space.paint ?? window.browser.map { SpacePaint($0.prefs) })?.color(dark: false).hex ?? ""
    }

    @objc var scriptTabs: [YabScriptTab] {
        window.listed().filter { $0.space == space.id }.map { YabScriptTab($0.tab, space: $0.space, in: window) }
    }

    @objc(valueInScriptTabsWithUniqueID:)
    func valueInScriptTabs(withUniqueID id: String) -> YabScriptTab? {
        scriptTabs.first { $0.uniqueID == id }
    }

    /// `tell space X to make new tab`: the space comes on screen, and the
    /// tab opens there as the window's own `make` opens it.
    @objc(insertInScriptTabs:)
    func insertInScriptTabs(_ made: YabScriptTab) {
        guard let browser = window.browser else { return }
        if browser.spaceID != space.id { browser.switchSpace(to: space.id) }
        window.insertInScriptTabs(made)
    }

    @objc(insertInScriptTabs:atIndex:)
    func insertInScriptTabs(_ made: YabScriptTab, at index: Int) { insertInScriptTabs(made) }

    @objc func handleFocusCommand(_ command: NSScriptCommand) -> Any? {
        window.browser?.switchSpace(to: space.id)
        window.window?.makeKeyAndOrderFront(nil)
        return nil
    }

    nonisolated override var objectSpecifier: NSScriptObjectSpecifier? { MainActor.assumeIsolated { specifier } }

    private var specifier: NSScriptObjectSpecifier? {
        guard let container = window.objectSpecifier,
              let description = NSScriptClassDescription(for: YabScriptWindow.self) else { return nil }
        return NSUniqueIDSpecifier(containerClassDescription: description, containerSpecifier: container,
                                   key: "scriptSpaces", uniqueID: uniqueID)
    }
}

/// `make`, as Cocoa's, but for a private window: Cocoa sets the properties
/// given only after the window is made, on the one it finds again, and a
/// window can't turn private then.
@objc(YabCreateCommand)
final class YabCreateCommand: NSCreateCommand {
    override func performDefaultImplementation() -> Any? {
        // 'cwin', the window class's code.
        guard createClassDescription.appleEventCode == 0x6377_696E,
              (resolvedKeyDictionary["incognito"] as? NSNumber)?.boolValue == true else {
            return super.performDefaultImplementation()
        }
        return MainActor.assumeIsolated {
            let windows = BrowserWindows.shared
            return YabScriptWindow(windows.newPrivateWindow(from: windows.activeBrowser)).objectSpecifier
        }
    }
}

// The application's own commands, Yab's and not Arc's: what a launcher asks
// of the browser besides its tabs (docs/raycast.md).

/// `open small window "https://…"`: the page in a Small Window, whatever
/// Settings › Links say; with nothing, an empty one, as ⌥⌘N opens it.
@objc(YabSmallWindowCommand)
final class YabSmallWindowCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        MainActor.assumeIsolated {
            let given = (directParameter as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard let browser = Links.browser else {
                YabScriptWindow.scriptError(YabScriptWindow.cantAssign, "\(Brand.name) has no window yet.")
                return nil
            }
            guard !given.isEmpty else {
                LinkWindow.blank()
                return nil
            }
            guard let url = Address.url(from: given) else {
                YabScriptWindow.scriptError(YabScriptWindow.cantAssign, "Not an address: \(given)")
                return nil
            }
            LinkWindow.show(url, for: browser)
            return nil
        }
    }
}

/// `ask "…" [send true]`: ⌘J in the front window with the words typed in.
@objc(YabAskCommand)
final class YabAskCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        MainActor.assumeIsolated {
            // No words: ⌘J opens empty, as its key does, and nothing is sent.
            let words = (directParameter as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard let browser = BrowserWindows.shared.activeBrowser ?? Links.browser else {
                YabScriptWindow.scriptError(YabScriptWindow.cantAssign, "There is no window to ask in.")
                return nil
            }
            Links.showBrowser(browser)
            NSApp.activate()
            browser.scriptAsk(words, send: !words.isEmpty && evaluatedArguments?["send"] as? Bool ?? false)
            return nil
        }
    }
}

/// `show mail "account|thread"`: the thread on Mail's page, in its space,
/// as a yab://mail#thread= link opens it.
@objc(YabShowMailCommand)
final class YabShowMailCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        MainActor.assumeIsolated {
            let given = (directParameter as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !given.isEmpty, var parts = URLComponents(url: MailPage.url, resolvingAgainstBaseURL: false) else {
                YabScriptWindow.scriptError(YabScriptWindow.cantAssign, "No thread given: 'account|thread id'.")
                return nil
            }
            parts.fragment = "thread=" + given
            guard let url = parts.url, MailSpaceState.thread(in: url) != nil else {
                YabScriptWindow.scriptError(YabScriptWindow.cantAssign, "No such thread: \(given)")
                return nil
            }
            let windows = BrowserWindows.shared
            guard let browser = windows.activeBrowser.flatMap({ $0.windowPurpose == .normal ? $0 : nil })
                    ?? windows.normalBrowsers.first, browser.prefs.usesMail else {
                YabScriptWindow.scriptError(YabScriptWindow.cantAssign, "Mail is off in Settings.")
                return nil
            }
            Links.showBrowser(browser)
            NSApp.activate()
            browser.enterMail(url)
            return nil
        }
    }
}

extension Browser {
    /// ⌘J on the page in front, the words typed in and sent when `send`:
    /// the line at the page's foot or a chat, as Settings › AI › Agents
    /// say; with no page, a chat about nothing but the words.
    func scriptAsk(_ words: String, send: Bool) {
        let page = active.flatMap { $0.isBlank ? nil : $0 }
        let line = TaskLine.shared
        if let page, !Agents.ready || prefs.askOpens == .line {
            if line.tab != page.id { line.open(on: page) }
            guard line.tab == page.id else { return }
            line.words = words
            line.focusRequest += 1
            if send { line.run(on: page) }
            return
        }
        guard Agents.ready else { TaskLine.connect(); return }
        line.close()
        let mail = page.map { MailPage.isMail($0.address) } ?? false
        if let page, !mail, !send {
            askInChat(about: page, words: words)
            return
        }
        let items: [ChatAttachment] = mail ? MailChat.now(lines: true).map { [.mail($0)] } ?? []
            : page.map { $0.shy ? [] : [.tab($0.id)] } ?? []
        if send {
            if let session = ChatComposer.begin(words, with: items, in: self) { showChat(session.id) }
            return
        }
        newChat()
        chatAttach.set(items)
        chatDraft = words
        if !chatOpen { moveChat(open: true) }
    }
}
