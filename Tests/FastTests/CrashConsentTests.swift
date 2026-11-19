import AppKit
import XCTest
@testable import Fast

@MainActor
final class CrashConsentTests: XCTestCase {
    private func withDefaults(_ body: (UserDefaults) async throws -> Void) async rethrows {
        let name = "CrashConsentTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        try await body(defaults)
    }

    func testExistingOffSettingStillAsksForFirstCrash() async {
        await withDefaults { defaults in
            defaults.set(false, forKey: Crashes.key)
            let previous = Date(timeIntervalSince1970: 100)
            let crash = Date(timeIntervalSince1970: 200)
            defaults.set(previous, forKey: "crash.since")
            var asked = false
            let allowed = await Crashes.consent(through: crash, defaults: defaults) {
                asked = true
                return true
            }
            XCTAssertTrue(asked)
            XCTAssertTrue(allowed)
            XCTAssertFalse(defaults.bool(forKey: Crashes.key))
            // Only successful upload may mark an accepted report as sent.
            XCTAssertEqual(defaults.object(forKey: "crash.since") as? Date, previous)
        }
    }

    func testFirstCrashQueuesDialogEvenWithStoredFalse() async throws {
        _ = NSApplication.shared
        try await withDefaults { defaults in
            defaults.set(false, forKey: Crashes.key)
            let questions = Questions()
            let task = Task {
                await Crashes.consent(through: Date(), defaults: defaults) {
                    await Crashes.ask(using: questions)
                }
            }
            for _ in 0..<100 {
                if questions.current != nil { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            guard let question = questions.current else {
                task.cancel()
                XCTFail("A stored false must not suppress the first crash dialog")
                return
            }
            XCTAssertEqual(question.title, "Share saved crash reports?")
            XCTAssertTrue(question.detail.contains("an earlier Pane session"))
            XCTAssertEqual(question.yes, "Send")
            XCTAssertEqual(question.no, "Don’t Send")
            questions.answer(false)
            let allowed = await task.value
            XCTAssertFalse(allowed)
            XCTAssertNil(questions.current)
        }
    }

    func testDecliningSkipsCurrentReportsAndAsksAfterNextCrash() async {
        await withDefaults { defaults in
            let crash = Date(timeIntervalSince1970: 200)
            let nextCrash = Date(timeIntervalSince1970: 300)
            var asks = 0
            let declined = await Crashes.consent(through: crash, defaults: defaults) {
                asks += 1
                return false
            }
            XCTAssertFalse(declined)
            XCTAssertEqual(defaults.object(forKey: "crash.since") as? Date, crash)
            XCTAssertNil(defaults.object(forKey: Crashes.key))
            let accepted = await Crashes.consent(through: nextCrash, defaults: defaults) {
                asks += 1
                return true
            }
            XCTAssertTrue(accepted)
            XCTAssertEqual(asks, 2)
            XCTAssertNil(defaults.object(forKey: Crashes.key))
            XCTAssertEqual(defaults.object(forKey: "crash.since") as? Date, crash)
        }
    }

    func testAutomaticSendingDoesNotAskOrMarkUnsentReportsAsSent() async {
        await withDefaults { defaults in
            defaults.set(true, forKey: Crashes.key)
            let allowed = await Crashes.consent(through: Date(), defaults: defaults) {
                XCTFail("Automatic sending should not ask again")
                return false
            }
            XCTAssertTrue(allowed)
            XCTAssertTrue(defaults.bool(forKey: Crashes.key))
            XCTAssertNil(defaults.object(forKey: "crash.since"))
        }
    }

    func testDecliningCannotMoveProcessedDateBackwards() async {
        await withDefaults { defaults in
            let latest = Date(timeIntervalSince1970: 300)
            defaults.set(latest, forKey: "crash.since")
            _ = await Crashes.consent(through: Date(timeIntervalSince1970: 200), defaults: defaults) { false }
            XCTAssertEqual(defaults.object(forKey: "crash.since") as? Date, latest)
        }
    }
}
