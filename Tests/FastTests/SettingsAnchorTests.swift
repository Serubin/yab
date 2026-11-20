import Foundation
import Testing
@testable import Fast

/// Settings' anchors are plain strings: a row says `.settingsAnchor("x")`,
/// the search index names it `SettingsItem(id: "x")`, and NativeActions
/// keeps a set of the ones only the user may change. A row renamed on one
/// side and not the other scrolls nowhere, so every name the index and
/// NativeActions use must be an anchor some row in the sources sets.
struct SettingsAnchorTests {
    /// Every anchor the sources set, and the starts of the ones made as
    /// they are drawn ("key:" + a shortcut's id, "skill-" + a skill's name).
    private static func anchors() throws -> (whole: Set<String>, starts: Set<String>) {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/Fast")
        let files = try FileManager.default.contentsOfDirectory(at: sources, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        try #require(files.count > 100)
        let literal = try Regex(#""([^"\\]*)"(\s*\+)?"#)
        // The bringers take their anchor from the page that shows them.
        let handed = try Regex(#"Bringer\(browser: \w+, anchor: "([^"\\]+)""#)
        var whole: Set<String> = []
        var starts: Set<String> = []
        for file in files {
            for line in try String(contentsOf: file, encoding: .utf8).split(separator: "\n") {
                if let match = line.firstMatch(of: handed), let name = match.output[1].substring {
                    whole.insert(String(name))
                }
                // The Shortcuts page builds its rows' ids in one list.
                if line.contains("(\"key:\" + ") { starts.insert("key:") }
                guard let at = line.range(of: ".settingsAnchor(") else { continue }
                for match in line[at.upperBound...].matches(of: literal) {
                    guard let name = match.output[1].substring.map(String.init), !name.isEmpty else { continue }
                    if match.output[2].substring == nil { whole.insert(name) } else { starts.insert(name) }
                }
            }
        }
        // Settings › Shortcuts anchors each row by its id ("key:" + a shortcut's).
        starts.insert("key:")
        return (whole, starts)
    }

    @Test func sourcesSetAnchors() throws {
        let found = try Self.anchors()
        #expect(found.whole.count > 100)
        #expect(found.whole.contains("updates"))
        #expect(found.starts.contains("key:"))
    }

    /// One setting, one name: the switch at the top of Agents and the row
    /// on Developers both say Let agents use Pane, and it left AI's own page.
    @MainActor @Test func letAgentsUseYabLivesOnAgentsAndDevelopers() {
        let items = SettingsItem.all.filter { $0.title == "Let agents use Pane" }
        #expect(Set(items.map(\.page)) == [.agents, .developers])
        #expect(!SettingsItem.all.contains { $0.id == "ai-outside-agents" })
        #expect(SettingsPage.agents.master?.title == "Let agents use Pane")
    }

    /// Settings search finds "Allow in private tabs" on Extensions, so
    /// both engines' Extensions pages draw its row: the Chromium page
    /// once had none, and the result scrolled nowhere (feedback #1894).
    @MainActor @Test func privateTabsRowOnBothEnginePages() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/Fast")
        let webKit = try String(contentsOf: sources.appendingPathComponent("ExtensionsUI.swift"), encoding: .utf8)
        let chromium = try String(contentsOf: sources.appendingPathComponent("ChromiumExtensionsUI.swift"), encoding: .utf8)
        #expect(webKit.contains("PrivateTabs(prefs: browser.prefs)"))
        #expect(chromium.contains("ExtensionsPage.PrivateTabs(prefs: browser.prefs)"))
        #expect(webKit.contains(".settingsAnchor(\"extensions-private\")"))
        #expect(SettingsItem.all.contains { $0.id == "extensions-private" && $0.page == .extensions })
    }

    @MainActor @Test func everyIndexedRowHasItsAnchor() throws {
        let found = try Self.anchors()
        func anchored(_ id: String) -> Bool {
            found.whole.contains(id) || found.starts.contains { id.hasPrefix($0) && id.count > $0.count }
        }
        let items = SettingsItem.all
        try #require(items.count > 100)
        for item in items {
            if let within = item.within {
                #expect(anchored(within), "\(item.id) waits within \(within), which no row anchors")
            }
            // A page's own switch is in the toolbar, not a row on the page.
            let toolbar = item.page.master?.title == item.title
            // Found, a row that only shows inside another brings that one into view.
            let inside = item.within.map(anchored) == true
            #expect(anchored(item.id) || inside || toolbar, "Settings search finds \(item.id), but no row anchors it")
        }
    }

    @MainActor @Test func everyUserOnlySettingHasItsAnchor() throws {
        let found = try Self.anchors()
        let toolbar = Set(SettingsItem.all.filter { $0.page.master?.title == $0.title }.map(\.id))
        for id in NativeActions.controlled where !toolbar.contains(id) {
            #expect(found.whole.contains(id), "NativeActions.controlled names \(id), but no row anchors it")
        }
    }
}
