import Foundation
import Testing
@testable import YabUpdate

struct PreparedUpdateTests {
    private func bundle(_ url: URL, build: Int) throws {
        try FileManager.default.createDirectory(at: url.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "test.yab", "CFBundleVersion": String(build)],
                                          format: .xml, options: 0).write(to: url.appendingPathComponent("Contents/Info.plist"))
    }

    private func build(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url.appendingPathComponent("Contents/Info.plist"))
        return (try PropertyListSerialization.propertyList(from: data, format: nil) as! [String: String])["CFBundleVersion"]!
    }

    private func release(_ build: Int) -> Update.Release {
        Update.Release(version: "test-\(build)", build: build, archive: URL(string: "https://test.invalid/new.zip")!,
                       dmg: URL(string: "https://test.invalid/new.dmg")!, sha256: "fixture", notes: nil, minimumSystemVersion: nil)
    }

    @Test func preparingAndSupersedingNeverMovesTheRunningBundle() throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? files.removeItem(at: root) }
        let place = root.appendingPathComponent("Yab.app"), scratch = root.appendingPathComponent("scratch")
        let first = scratch.appendingPathComponent("first.app"), second = scratch.appendingPathComponent("second.app")
        try bundle(place, build: 100)
        let resource = place.appendingPathComponent("Contents/resource")
        try Data("running engine's resources".utf8).write(to: resource)
        try bundle(first, build: 200)
        try bundle(second, build: 300)
        try Swap.prepare(first, release: release(200), allowDowngrade: false, replacing: nil,
                         scratch: scratch, at: place, identifier: "test.yab")
        #expect(try build(place) == "100")
        #expect(try build(Swap.preparedApp(at: place)) == "200")
        try Swap.prepare(second, release: release(300), allowDowngrade: false, replacing: 200,
                         scratch: scratch, at: place, identifier: "test.yab")
        #expect(try build(place) == "100")
        #expect(try build(Swap.preparedApp(at: place)) == "300")
        #expect(try String(contentsOf: resource, encoding: .utf8) == "running engine's resources")
        #expect(!files.fileExists(atPath: place.path + ".old"))
        let record = try JSONDecoder().decode(Swap.Prepared.self,
            from: Data(contentsOf: Swap.preparationRoot(at: place).appendingPathComponent("release.json")))
        #expect(record.release.build == 300 && !record.allowDowngrade)
    }

    @Test func aFailedReplacementKeepsThePreparedAndRunningBuilds() throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? files.removeItem(at: root) }
        let place = root.appendingPathComponent("Yab.app"), scratch = root.appendingPathComponent("scratch")
        let fresh = scratch.appendingPathComponent("first.app")
        try bundle(place, build: 100)
        try bundle(fresh, build: 200)
        try Swap.prepare(fresh, release: release(200), allowDowngrade: false, replacing: nil,
                         scratch: scratch, at: place, identifier: "test.yab")
        #expect(throws: (any Error).self) {
            try Swap.prepare(scratch.appendingPathComponent("missing.app"), release: release(300), allowDowngrade: false,
                             replacing: 200, scratch: scratch, at: place, identifier: "test.yab")
        }
        #expect(try build(place) == "100")
        #expect(try build(Swap.preparedApp(at: place)) == "200")
        let record = try JSONDecoder().decode(Swap.Prepared.self,
            from: Data(contentsOf: Swap.preparationRoot(at: place).appendingPathComponent("release.json")))
        #expect(record.release.build == 200)
    }

    @Test func preparationRefusesASymlinkAndAnUnexpectedStagedBuild() throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? files.removeItem(at: root) }
        let place = root.appendingPathComponent("Yab.app"), scratch = root.appendingPathComponent("scratch")
        let fresh = scratch.appendingPathComponent("first.app"), other = root.appendingPathComponent("other")
        try bundle(place, build: 100)
        try bundle(fresh, build: 200)
        try files.createDirectory(at: other, withIntermediateDirectories: true)
        try files.createSymbolicLink(at: Swap.preparationRoot(at: place), withDestinationURL: other)
        #expect(throws: (any Error).self) {
            try Swap.prepare(fresh, release: release(200), allowDowngrade: false, replacing: nil,
                             scratch: scratch, at: place, identifier: "test.yab")
        }
        #expect(try build(place) == "100")
        #expect(try build(fresh) == "200")
        #expect(try files.contentsOfDirectory(atPath: other.path).isEmpty)
        try files.removeItem(at: Swap.preparationRoot(at: place))
        #expect(throws: (any Error).self) {
            try Swap.prepare(fresh, release: release(200), allowDowngrade: false, replacing: 199,
                             scratch: scratch, at: place, identifier: "test.yab")
        }
        #expect(try build(fresh) == "200")
    }

    @Test func metadataFailureCannotReplaceAnAlreadyReadyDownload() throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? files.removeItem(at: root) }
        let place = root.appendingPathComponent("Yab.app"), scratch = root.appendingPathComponent("scratch")
        let first = scratch.appendingPathComponent("first.app"), second = scratch.appendingPathComponent("second.app")
        try bundle(place, build: 100)
        try bundle(first, build: 200)
        try bundle(second, build: 300)
        try Swap.prepare(first, release: release(200), allowDowngrade: false, replacing: nil,
                         scratch: scratch, at: place, identifier: "test.yab")
        try files.createDirectory(at: scratch.appendingPathComponent("preparing/release.json"), withIntermediateDirectories: true)
        #expect(throws: (any Error).self) {
            try Swap.prepare(second, release: release(300), allowDowngrade: false, replacing: 200,
                             scratch: scratch, at: place, identifier: "test.yab")
        }
        #expect(try build(place) == "100")
        #expect(try build(Swap.preparedApp(at: place)) == "200")
        #expect(try build(second) == "300")
        let record = try JSONDecoder().decode(Swap.Prepared.self,
            from: Data(contentsOf: Swap.preparationRoot(at: place).appendingPathComponent("release.json")))
        #expect(record.release.build == 200)
    }

    @Test func installerRequestsAcceptOnlyTheFixedPreparedBuild() throws {
        let normal = try #require(Relaunch.Request(arguments: [Relaunch.installFlag, "42", "200"]))
        #expect(normal.installing == 200 && !normal.reopens && !normal.behind)
        let restart = try #require(Relaunch.Request(arguments: [Relaunch.installFlag, "42", "200", "--reopen", "--background"]))
        #expect(restart.installing == 200 && restart.reopens && restart.behind)
        for options in [["--background"], ["--reopen", "--reopen"], ["/tmp/other.app"], ["-c", "whoami"]] {
            #expect(Relaunch.Request(arguments: [Relaunch.installFlag, "42", "200"] + options) == nil)
        }
        #expect(Relaunch.Request(arguments: [Relaunch.installFlag, "42", "0"]) == nil)
        #expect(Relaunch.Request(arguments: [Relaunch.installFlag, "0", "200"]) == nil)
    }

    @Test func installerWaitsForTheIndependentlyIdentifiedNestedEngine() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Yab.app", isDirectory: true)
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/Frameworks/PaneCore.app/Contents/Frameworks/PaneCore Helper.app"), withIntermediateDirectories: true)
        #expect(Relaunch.containsApplication([app], app.appendingPathComponent("Contents/Frameworks/PaneCore.app")))
        #expect(Relaunch.containsApplication([app], app.appendingPathComponent("Contents/Frameworks/PaneCore.app/Contents/Frameworks/PaneCore Helper.app")))
        #expect(!Relaunch.containsApplication([app], root.appendingPathComponent("Yab.app.other/Contents/Frameworks/PaneCore.app")))
        #expect(!Relaunch.containsApplication([app], root.appendingPathComponent("Other Yab.app")))
    }
}
