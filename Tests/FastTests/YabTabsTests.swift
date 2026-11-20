import Foundation
import Testing
@testable import Fast

// An upstream Yab folder's spaces and sessions, written with Pane's own types, read back as places.
@MainActor
struct YabTabsTests {
    func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("yab-tabs-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func source(_ root: URL) -> YabBrowser.Source {
        var source = YabBrowser.known[0]
        source.dataRoot = root
        return source
    }

    func write(_ tabs: [Session.Entry], to name: String, in root: URL) throws {
        try JSONEncoder().encode(Session.Shape(tabs: tabs, active: 0)).write(to: root.appendingPathComponent(name))
    }

    @Test func readsEachSpaceWithItsPinsFoldersAndOpenTabs() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let work = UUID()
        var painted = Space(id: work, name: "Work", icon: "briefcase", ownSignIns: true)
        painted.paint = try JSONDecoder().decode(SpacePaint.self, from: Data(##"{"swatch":"custom","color":"#2463EB","grain":true,"grainAmount":0.2,"transparency":0}"##.utf8))
        let spaces = [Space(id: Space.firstID, name: "Personal", icon: "🏠", ownSignIns: false), painted]
        try JSONEncoder().encode(spaces).write(to: root.appendingPathComponent("spaces.json"))
        try write([
            Session.Entry(url: "https://mail.example.com/", title: "Mail", pin: "mail"),
            Session.Entry(url: "https://docs.example.com/", title: "Docs", kept: true, folder: "f2", folderName: "Specs",
                          folderPath: [Session.Step(id: "f1", name: "Projects")]),
            Session.Entry(url: "https://news.example.com/", title: "News"),
            Session.Entry(url: "about:blank", title: ""),
        ], to: "session.json", in: root)
        try write([Session.Entry(url: "https://tracker.example.com/", title: "Tracker", name: "My tracker"),
                   Session.Entry(url: "https://mail.example.com/work", title: "Work mail", pin: "W")],
                  to: "session-\(work.uuidString).json", in: root)
        try write([Session.Entry(url: "https://calendar.example.com/", title: "Calendar", pin: "cal")],
                  to: "session-00000000-0000-0000-0000-000000000A11.json", in: root)

        let places = try #require(YabBrowser.tabPlaces(in: source(root)))
        #expect(places.map(\.name) == ["Personal", "Work"])
        #expect(places[0].pinned.map(\.title) == ["Calendar", "Mail"])
        #expect(places[0].kept.map(\.folder) == ["Projects › Specs"])
        #expect(places[0].kept.first?.path == ["Projects", "Specs"])
        #expect(places[0].open.map(\.title) == ["News"])
        #expect(places[0].left == 1)
        #expect(places[0].emoji == "🏠")
        #expect(places[1].open.first?.name == "My tracker")
        #expect(places[1].color?.uppercased().hasSuffix("2463EB") == true && places[1].grain == 0.2)
        #expect(places[1].pinned.map(\.title) == ["Work mail"])
        #expect(places[0].shared && !places[1].shared)
        #expect(places.allSatisfy { $0.id.hasPrefix("Yab:") })
    }

    @Test func withoutSpacesTheOneRowComesUnnamed() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        try write([Session.Entry(url: "https://example.com/", title: "Example")], to: "session.json", in: root)

        #expect(YabBrowser.holdsData(root))
        let places = try #require(YabBrowser.tabPlaces(in: source(root)))
        #expect(places.count == 1 && places[0].name.isEmpty)
        #expect(places[0].open.map(\.title) == ["Example"])
    }

    @Test func aLinkedSessionIsRefused() throws {
        let root = try folder()
        let elsewhere = try folder()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: elsewhere)
        }
        try write([Session.Entry(url: "https://example.com/", title: "Example")], to: "session.json", in: elsewhere)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("session.json"),
                                                   withDestinationURL: elsewhere.appendingPathComponent("session.json"))

        #expect(YabBrowser.tabPlaces(in: source(root)) == nil)
    }
}
