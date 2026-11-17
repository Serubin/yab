import AppKit
import Testing
import WebKit
@testable import Fast

/// A small window's page is the one tab of an extension window of its own,
/// active there, so an extension pressed in it acts on that page. In the
/// handoff suite, serialized with it: each opens a real small window.
extension LinkWindowHandoffTests {
    private static func extensionPage(_ name: String) -> URL {
        URL(string: "data:text/html,%3Ctitle%3E\(name)%3C/title%3E")!
    }

    private static func blankExtension() async throws -> WKWebExtensionContext {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("yab-link-ext-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try #"{"manifest_version": 3, "name": "Blank", "version": "1.0"}"#
            .write(to: folder.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        return WKWebExtensionContext(for: try await WKWebExtension(resourceBaseURL: folder))
    }

    @Test func aSmallWindowIsAnExtensionWindowOfItsOwn() async throws {
        _ = NSApplication.shared
        try #require(!NSScreen.screens.isEmpty)
        let owner = Extensions.shared
        let browser = Browser(windowID: UUID())
        owner.follow(browser)
        var mini: LinkWindow?
        defer {
            mini?.window.close()
            mini?.window.contentView = nil
            owner.unfollow(browser)
            browser.letGo()
            try? FileManager.default.removeItem(at: Store.file("session-window-\(browser.windowID!.uuidString).json"))
        }
        let front = browser.open(Self.extensionPage("Front"), foreground: true)
        let tab = browser.blankTab()
        browser.prepare(tab)
        browser.outside.append(tab)
        tab.go(to: Self.extensionPage("Small"))
        let page = tab.page
        LinkWindow.present(tab, for: browser)
        let link = try #require(LinkWindow.owning(page: page))
        mini = link
        link.window.setFrameOrigin(NSPoint(x: -30000, y: 0))
        try await Task.sleep(for: .milliseconds(250))

        #expect(owner.told(tab) == link.extensionKey)
        #expect(owner.told(front) == browser.windowID)
        let context = try await Self.blankExtension()
        let own = try #require(owner.window(of: tab))
        #expect(own.link === link)
        #expect(own.windowType(for: context) == .popup)
        #expect(own.tabs(for: context).count == 1)
        #expect((own.activeTab(for: context) as? ExtensionTab)?.tab === tab)
        #expect(owner.adapter(for: tab).isSelected(for: context))
        #expect(owner.adapter(for: tab).indexInWindow(for: context) == 0)
        // The browser's window keeps its own tab in front, and doesn't list the small window's page.
        let row = try #require(owner.window(of: front))
        #expect((row.activeTab(for: context) as? ExtensionTab)?.tab === front)
        #expect(!row.tabs(for: context).contains { ($0 as? ExtensionTab)?.tab === tab })

        // Closed: its page and its window are gone to WebKit.
        link.window.close()
        link.window.contentView = nil
        mini = nil
        try await Task.sleep(for: .milliseconds(250))
        #expect(owner.told(tab) == nil)
        #expect(!owner.webExtensionController(owner.controller, openWindowsFor: context)
            .contains { ($0 as? ExtensionWindow)?.isLink == true })
    }
}
