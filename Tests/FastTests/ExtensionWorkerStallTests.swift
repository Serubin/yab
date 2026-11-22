import Foundation
import Testing
import WebKit
@testable import Fast

/// A main thread held for seconds (stalls.log showed 30-389 s) is not a
/// dead worker: checkWorker's wait must not run out on a stall alone.
@MainActor
@Suite(.serialized)
struct ExtensionWorkerStallTests {
    @MainActor final class Said { var failed = false }

    private func loaded(worker: String) async throws -> (WKWebExtensionContext, WKWebExtensionController, URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("yab-stall-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try #"{"manifest_version":3,"name":"Stall test","version":"1.0","background":{"service_worker":"sw.js"}}"#
            .write(to: folder.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        try worker.write(to: folder.appendingPathComponent("sw.js"), atomically: true, encoding: .utf8)
        let controller = WKWebExtensionController(configuration: .nonPersistent())
        let context = WKWebExtensionContext(for: try await WKWebExtension(resourceBaseURL: folder))
        try controller.load(context)
        return (context, controller, folder)
    }

    private static func hold(_ seconds: TimeInterval) {
        let until = Date().addingTimeInterval(seconds)
        while Date() < until { _ = sqrt(Double.random(in: 0...1)) }
    }

    @Test func aStallIsNotADeadWorker() async throws {
        let (context, controller, folder) = try await loaded(worker: "self.started = true;")
        defer { try? controller.unload(context); try? FileManager.default.removeItem(at: folder) }
        let said = Said()
        Extensions.checkWorker(context, within: .seconds(2)) { said.failed = true }
        Self.hold(3)
        for _ in 0..<60 where !said.failed { try? await Task.sleep(for: .milliseconds(100)) }
        #expect(said.failed == false)
    }

    @Test func aWorkerThatNeverStartsStillFailsAfterAStall() async throws {
        let (context, controller, folder) = try await loaded(worker: "this is not ( a script")
        defer { try? controller.unload(context); try? FileManager.default.removeItem(at: folder) }
        let said = Said()
        Extensions.checkWorker(context, within: .seconds(2)) { said.failed = true }
        Self.hold(3)
        for _ in 0..<80 where !said.failed { try? await Task.sleep(for: .milliseconds(100)) }
        #expect(said.failed)
    }
}
