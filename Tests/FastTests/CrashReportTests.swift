import Foundation
import XCTest
@testable import Fast

final class CrashReportTests: XCTestCase {
    private let bundle = "net.serubin.pane"

    func testAcceptsCrashMetadataWithJSONWhitespace() {
        XCTAssertTrue(Crashes.isCrashReport(
            #"{"bundleID" : "net.serubin.pane", "bug_type" : "309"}"# + "\n{}", bundle: bundle
        ))
    }

    /// Crash #9: a 0.0.3 crash sent by 0.0.8 goes as 0.0.3's.
    func testAReportSaysWhichYabCrashed() {
        let made = Crashes.madeBy(#"{"app_name":"yab","app_version":"0.0.3","build_version":"202609302000","bug_type":"309"}"# + "\n{}")
        XCTAssertEqual(made?.version, "0.0.3")
        XCTAssertEqual(made?.build, "202609302000")
        XCTAssertNil(Crashes.madeBy(#"{"app_name":"yab","bug_type":"309"}"# + "\n{}"))
        XCTAssertNil(Crashes.madeBy("not json\n{}"))
    }

    func testUnversionedHelperNeverInheritsUploadingAppsBuild() {
        let helper = #"{"app_name":"PaneCore","app_version":"","build_version":"","slice_uuid":"8234e9fd-bf9a-38c0-a3be-446ada8ac4f9"}"# + "\n{}"
        let unknown = Crashes.uploadIdentity(helper)
        XCTAssertEqual(unknown.version, "unknown")
        XCTAssertEqual(unknown.build, "0")
        let known = Crashes.uploadIdentity(#"{"app_name":"yab","app_version":"0.46.17","build_version":"202611041455"}"# + "\n{}")
        XCTAssertEqual(known.version, "0.46.17")
        XCTAssertEqual(known.build, "202611041455")
        XCTAssertEqual(Crashes.uploadIdentity("invalid\n{}").version, "unknown")
    }

    func testDiagnosticsAndInvalidHeadersDoNotBecomeCrashReports() {
        for header in [
            #"{"bundleID":"net.serubin.pane","bug_type":"288"}"#,
            #"{"bundleID":"net.serubin.pane","bug_type":"298"}"#,
            #"{"bundleID":"net.serubin.pane"}"#,
            #"{"bundleID":"net.serubin.pane.dev","bug_type":"309"}"#,
            #"{"bundleID":"","bug_type":"309"}"#,
            #"{"bundleID":"net.serubin.pane","bug_type":"309""#,
            "{}\n" + #"{"bundleID":"net.serubin.pane","bug_type":"309"}"#,
        ] {
            XCTAssertFalse(Crashes.isCrashReport(header, bundle: bundle), header)
        }
        XCTAssertFalse(Crashes.isCrashReport(#"{"bundleID":"","bug_type":"309"}"#, bundle: ""))
    }

    func testDiscoveryIncludesEarlierBuildCrashesButNotOtherDiagnosticsOrProcessedReports() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let cutoff = Date(timeIntervalSince1970: 100)
        let fixtures: [(String, String, TimeInterval)] = [
            ("pane-old.ips", #"{"bundleID":"net.serubin.pane","bug_type":"309"}"#, 100),
            ("pane-diagnostic.ips", #"{"bundleID":"net.serubin.pane","bug_type":"288"}"#, 110),
            ("pane-dev.ips", #"{"bundleID":"net.serubin.pane.dev","bug_type":"309"}"#, 120),
            ("pane-new.ips", #"{"bundleID":"net.serubin.pane","bug_type":"309","app_version":"0.0.5"}"#, 140),
            ("pane-previous.ips", #"{"bundleID":"net.serubin.pane","bug_type":"309","app_version":"0.0.4"}"#, 130),
            ("pane-page-load.ips", #"{"app_name":"Pane","kind":"page-load"}"# + "\n" +
                #"{"exception":{"type":"PageLoadFailure/chromium/ERR_CONNECTION_RESET"},"loadFailure":{"code":-101}}"#, 160),
            ("load-failures.jsonl", #"{"engine":"webKit","domain":"NSURLErrorDomain","code":-1009}"#, 170),
        ]
        for (name, header, seconds) in fixtures {
            let file = folder.appendingPathComponent(name)
            try (header + "\n{}").write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: seconds)], ofItemAtPath: file.path)
        }
        let found = Crashes.reports(after: cutoff, bundle: bundle, folder: folder)
        XCTAssertEqual(found.map { $0.0.lastPathComponent }, ["pane-previous.ips", "pane-new.ips"])
        XCTAssertEqual(found.map { $0.1 }, [Date(timeIntervalSince1970: 130), Date(timeIntervalSince1970: 140)])
    }

    func testDiscoveryFindsTheChromiumHelper() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let fixtures: [(String, String, TimeInterval)] = [
            ("YabCore-1.ips", #"{"app_name":"PaneCore","app_version":"","bug_type":"309"}"#, 120),
            ("PaneCore Helper (Renderer)-1.ips", #"{"bundleID":"net.serubin.pane.helper.renderer","bug_type":"309"}"#, 130),
            ("PaneCore Helper (GPU)-1.ips", #"{"bundleID":"net.serubin.pane.helper.gpu","bug_type":"288"}"#, 140),
            ("PaneCore Helper-2.ips", #"{"bundleID":"net.serubin.pane.helperish.other","bug_type":"288"}"#, 150),
        ]
        for (name, header, seconds) in fixtures {
            let file = folder.appendingPathComponent(name)
            try (header + "\n{}").write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: seconds)], ofItemAtPath: file.path)
        }
        let found = Crashes.reports(after: Date(timeIntervalSince1970: 100), bundle: bundle, folder: folder)
        XCTAssertEqual(found.map { $0.0.lastPathComponent }, ["YabCore-1.ips", "PaneCore Helper (Renderer)-1.ips"])
    }

    func testDiscoveryLooksInRetiredToo() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let retired = folder.appendingPathComponent("Retired")
        try FileManager.default.createDirectory(at: retired, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let header = #"{"bundleID":"net.serubin.pane","bug_type":"309"}"#
        for (file, seconds) in [(folder.appendingPathComponent("pane-a.ips"), 150.0), (retired.appendingPathComponent("pane-b.ips"), 120),
                                (retired.appendingPathComponent("pane-a.ips"), 150)] {
            try (header + "\n{}").write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: seconds)], ofItemAtPath: file.path)
        }
        let found = Crashes.reports(after: Date(timeIntervalSince1970: 100), bundle: bundle, folder: folder)
        let places = found.map { $0.0.deletingLastPathComponent().lastPathComponent + "/" + $0.0.lastPathComponent }
        XCTAssertEqual(places, ["Retired/pane-b.ips", "\(folder.lastPathComponent)/pane-a.ips"])
    }
}
