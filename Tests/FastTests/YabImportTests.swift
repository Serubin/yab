import Foundation
import Testing
@testable import Fast

// An upstream Yab folder, made here with Pane's own encoders, and read back.
// Never a real install.
@MainActor
struct YabImportTests {
    static let added = Date(timeIntervalSince1970: 1_780_000_000)
    static let last = Date(timeIntervalSince1970: 1_790_000_000)

    func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("yab-import-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func source(_ root: URL) -> YabBrowser.Source {
        var source = YabBrowser.known[0]
        source.dataRoot = root
        return source
    }

    func writeFixture(in root: URL) throws {
        let marks: [Bookmark] = [
            .site("Fold", URL(string: "https://fold.studio")!, added: Self.added),
            .folder("Work", [
                .site("Docs", URL(string: "https://docs.example.com/a")!, added: Self.added),
                Bookmark(title: "Bad", url: "javascript:alert(1)", children: nil, added: Self.added),
            ], added: Self.added),
        ]
        try JSONEncoder().encode(marks).write(to: root.appendingPathComponent("bookmarks.json"))
        let visits = [
            Visit(url: "https://fold.studio/", key: "fold.studio/", title: "Fold", count: 4, last: Self.last, typed: 2),
            Visit(url: "https://example.com/old", key: "example.com/old", title: "Old", count: 1, last: Self.added, typed: nil),
            Visit(url: "javascript:alert(1)", key: "javascript:alert(1)", title: "Bad", count: 9, last: Self.last, typed: 0),
        ]
        try JSONEncoder().encode(visits).write(to: root.appendingPathComponent("history.json"))
    }

    @Test func readsBookmarksAndHistoryAndDropsScripts() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeFixture(in: root)

        let marks = try #require(YabBrowser.bookmarks(in: source(root)))
        #expect(marks.map(\.title) == ["Fold", "Work"])
        #expect(marks[0].url == "https://fold.studio" && marks[0].added == Self.added)
        #expect(marks[1].children?.map(\.title) == ["Docs"])

        let places = try #require(YabBrowser.places(in: source(root)))
        #expect(places.map(\.title) == ["Fold", "Old"])
        #expect(places[0].count == 4 && places[0].typed == 2 && places[0].last == Self.last)
    }

    @Test func leavesYabsFilesAsTheyWere() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeFixture(in: root)
        let files = ["bookmarks.json", "history.json"].map { root.appendingPathComponent($0) }
        let before = try files.map { (try Data(contentsOf: $0), try FileManager.default.attributesOfItem(atPath: $0.path)[.modificationDate] as? Date) }

        _ = YabBrowser.bookmarks(in: source(root))
        _ = YabBrowser.places(in: source(root))

        let after = try files.map { (try Data(contentsOf: $0), try FileManager.default.attributesOfItem(atPath: $0.path)[.modificationDate] as? Date) }
        #expect(before.map(\.0) == after.map(\.0))
        #expect(before.map(\.1) == after.map(\.1))
        let left = try FileManager.default.contentsOfDirectory(atPath: root.path)
        #expect(left.sorted() == ["bookmarks.json", "history.json"])
    }

    @Test func refusesALinkOutOfTheFolder() throws {
        let root = try folder(), outside = try folder()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
        try writeFixture(in: outside)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("bookmarks.json"),
                                                   withDestinationURL: outside.appendingPathComponent("bookmarks.json"))
        #expect(YabBrowser.bookmarks(in: source(root)) == nil)
    }

    @Test func malformedOrStrangeFilesAreNil() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("{not json".utf8).write(to: root.appendingPathComponent("bookmarks.json"))
        try Data(#"{"version":9,"visits":[]}"#.utf8).write(to: root.appendingPathComponent("history.json"))
        #expect(YabBrowser.bookmarks(in: source(root)) == nil)
        #expect(YabBrowser.places(in: source(root)) == nil)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("bookmarks.json").path))
    }

    @Test func missingFilesAreEmpty() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(YabBrowser.bookmarks(in: source(root)) == [])
        #expect(YabBrowser.places(in: source(root))?.isEmpty == true)
    }

    @Test func installedFindsTheFastFolder() throws {
        let support = try folder()
        defer { try? FileManager.default.removeItem(at: support) }
        let fast = support.appendingPathComponent("Fast")
        try FileManager.default.createDirectory(at: fast, withIntermediateDirectories: true)
        try writeFixture(in: fast)
        var standIn = YabBrowser.known[0]
        standIn.support = support
        YabBrowser.standIns = [standIn]
        defer { YabBrowser.standIns = [] }

        let found = YabBrowser.installed()
        #expect(found.map(\.name) == ["Yab"])
        #expect(found.first?.root.standardizedFileURL == fast.standardizedFileURL)
    }

    @Test func settingsHasTheRow() {
        #expect(SettingsItem.all.contains { $0.id == "import-yab" && $0.page == .bringIn })
    }
}
