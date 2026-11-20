import Foundation
import Darwin
import Testing
@testable import YabCoreClient

/// Actual metadata/POSIX journal tests authored NOT_RUN. Their fixtures carry
/// diagnostic source data, never native ownership, approval or effects.
struct ChromiumNativeSwitchJournalTests {
    private func intent(id: UUID = UUID(), privacy: NativeSwitchJournal.Privacy = .persistentVerified) -> NativeSwitchJournal.Intent {
        .init(id: id, peer: .init(pid: 123, parent: 122, uid: getuid(), startSec: 1000, startUsec: 1,
                executable: "/fixture/Task.app/Contents/MacOS/PaneCore", argvSHA256: String(repeating: "a", count: 64),
                bootSession: "01234567-89AB-4CDE-8123-456789ABCDEF", auditSHA256: String(repeating: "b", count: 64),
                codeIdentifier: "fixture.helper", codeUnique: String(repeating: "c", count: 40)),
              connection: "original-connection", members: [.init(tab: "original-tab", profile: "verified-profile", document: "original-native-doc", browser: 11)],
              target: .chromium, settingsBaselineSHA256: String(repeating: "d", count: 64), privacy: privacy)
    }
    private func world() throws -> (URL, NativeSwitchJournal) {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("journal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return (parent, try NativeSwitchJournal(directory: parent.appendingPathComponent("owned")))
    }
    private func stored(_ result: NativeSwitchJournal.Result) throws -> NativeSwitchJournal.Snapshot {
        guard case .stored(let snapshot) = result else { Issue.record("Controlled metadata journal did not store"); throw Failure.fixture }
        return snapshot
    }
    private enum Failure: Error { case fixture }
    @Test func immutableWriteAheadRevisionsCASAndReload() async throws {
        let (parent, journal) = try world(); defer { try? FileManager.default.removeItem(at: parent) }
        let original = intent(), initial = try stored(await journal.create(original))
        #expect(initial.phase == .intent && initial.cursor.revision == 1)
        let pending = try stored(await journal.writeAhead(.reserve, command: "original-reserve", expected: initial.cursor))
        #expect(pending.phase == .reserveDispatchPending && pending.cursor.revision == 2)
        #expect(await journal.writeAhead(.cancel, command: "cancel-stale", expected: initial.cursor) == .conflict)
        let cancel = try stored(await journal.writeAhead(.cancel, command: "original-cancel", expected: pending.cursor))
        #expect(cancel.phase == .cancelDispatchPending && cancel.pending.map(\.command) == ["original-reserve", "original-cancel"])
        let reloaded = try NativeSwitchJournal(directory: parent.appendingPathComponent("owned"))
        #expect(await reloaded.load(original.id) == .stored(cancel))
        let files = try FileManager.default.contentsOfDirectory(atPath: parent.appendingPathComponent("owned").path)
        #expect(files.filter { $0.hasSuffix(".json") }.count == 3) // Old revisions retained.
        #expect(!files.contains(".pending"))
    }
    @Test func helperLossIsUnknownAndCannotResumeOrDispatchAgain() async throws {
        let (parent, journal) = try world(); defer { try? FileManager.default.removeItem(at: parent) }
        let original = intent(), initial = try stored(await journal.create(original))
        let pending = try stored(await journal.writeAhead(.reserve, command: "original", expected: initial.cursor))
        let unknown = try stored(await journal.sourceLost(.helperEOF, expected: pending.cursor))
        #expect(unknown.phase == .unknown && unknown.loss == .helperEOF && unknown.pending == pending.pending && unknown.intent == original)
        #expect(await journal.writeAhead(.cancel, command: "automatic-cancel", expected: unknown.cursor) == .invalid)
        #expect(await journal.sourceLost(.sourceProcessLost, expected: initial.cursor) == .unknown)
        let same = try stored(await journal.sourceLost(.helperParentDeath, expected: unknown.cursor))
        #expect(same == unknown) // No rewrite/retire or invented recovery.
        let reloaded = try NativeSwitchJournal(directory: parent.appendingPathComponent("owned"))
        #expect(await reloaded.load(original.id) == .stored(unknown))
    }
    @Test func crashStagingEvidenceStopsNewWriterWithoutDeletion() async throws {
        let (parent, journal) = try world(); defer { try? FileManager.default.removeItem(at: parent) }
        let original = intent(), initial = try stored(await journal.create(original))
        let staging = parent.appendingPathComponent("owned/.pending")
        #expect(FileManager.default.createFile(atPath: staging.path, contents: Data("original-staging-evidence".utf8), attributes: [.posixPermissions: 0o600]))
        #expect(await journal.writeAhead(.reserve, command: "do-not-dispatch", expected: initial.cursor) == .unknown)
        #expect(await journal.load(original.id) == .unknown)
        #expect(try Data(contentsOf: staging) == Data("original-staging-evidence".utf8))
        let reloaded = try NativeSwitchJournal(directory: parent.appendingPathComponent("owned"))
        #expect(await reloaded.load(original.id) == .unknown)
    }
    @Test func corruptionOrSymlinkIsUnknownWithoutReplacingTarget() async throws {
        let (parent, journal) = try world(); defer { try? FileManager.default.removeItem(at: parent) }
        let original = intent(); _ = try stored(await journal.create(original))
        let owned = parent.appendingPathComponent("owned"), files = try FileManager.default.contentsOfDirectory(atPath: owned.path)
        let name = try #require(files.first { $0.hasSuffix("-r1.json") }), record = owned.appendingPathComponent(name)
        try Data("not-an-envelope".utf8).write(to: record)
        #expect(await journal.load(original.id) == .unknown)
        // A new writer also sees the corrupt evidence instead of overwriting.
        let reloaded = try NativeSwitchJournal(directory: owned)
        #expect(await reloaded.create(original) == .unknown)
        let other = parent.appendingPathComponent("untouched")
        try Data("untouched".utf8).write(to: other)
        let link = parent.appendingPathComponent("linked-directory")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: owned)
        var rejected = false
        do { _ = try NativeSwitchJournal(directory: link) } catch { rejected = true }
        let untouchedBytes = try Data(contentsOf: other)
        #expect(rejected && untouchedBytes == Data("untouched".utf8))
    }
    @Test func privateUnknownDuplicateAndRepeatedCommandsAreRefused() async throws {
        let (parent, journal) = try world(); defer { try? FileManager.default.removeItem(at: parent) }
        #expect(await journal.create(intent(privacy: .private)) == .invalid)
        #expect(await journal.create(intent(privacy: .unknown)) == .invalid)
        let original = intent(), first = try stored(await journal.create(original))
        #expect(await journal.create(original) == .conflict)
        #expect(await journal.writeAhead(.cancel, command: "cancel-before-reserve", expected: first.cursor) == .invalid)
        let pending = try stored(await journal.writeAhead(.reserve, command: "same-command", expected: first.cursor))
        #expect(await journal.writeAhead(.cancel, command: "same-command", expected: pending.cursor) == .invalid)
        #expect(await journal.writeAhead(.reserve, command: "retry-reserve", expected: pending.cursor) == .invalid)
    }
    @Test func sourceWriteAheadKeepsActualWireFrameAndLossAcrossV2Reopen() async throws {
        let (parent, journal) = try world(); defer { try? FileManager.default.removeItem(at: parent) }
        let original = intent(), initial = try stored(await journal.create(original))
        #expect(await journal.writeAhead(.reserve, command: "wire", expected: initial.cursor,
                                         frameSHA256: String(repeating: "e", count: 64), frameBytes: nil) == .invalid)
        let reserve = try stored(await journal.writeAhead(.reserve, command: "native:original:1", expected: initial.cursor,
                                                          frameSHA256: String(repeating: "e", count: 64), frameBytes: 123))
        #expect(reserve.pending.last?.frameSHA256 == String(repeating: "e", count: 64))
        let pending = try stored(await journal.writeAhead(.sources, command: "native:original:2", expected: reserve.cursor,
                                                          frameSHA256: String(repeating: "f", count: 64), frameBytes: 456))
        #expect(pending.phase == .sourcesDispatchPending && pending.cursor.revision == 3 && pending.sources == nil)
        #expect(pending.pending.last?.frameBytes == 456 && pending.pending.last?.command == "native:original:2")
        #expect(await journal.writeAhead(.sources, command: "retry", expected: pending.cursor) == .invalid)
        let unknown = try stored(await journal.sourceLostLatest(.sourceProcessLost, original: original))
        #expect(unknown.phase == .unknown && unknown.pending == pending.pending && unknown.sources == nil)
        let reopened = try NativeSwitchJournal(directory: parent.appendingPathComponent("owned"))
        #expect(await reopened.load(original.id) == .stored(unknown))
        #expect(await reopened.writeAhead(.cancel, command: "no-native-replay", expected: unknown.cursor) == .invalid)
    }
    @Test func latestOriginalLossCoversBothOrdersOfConcurrentMetadataWrite() async throws {
        let (parent, journal) = try world(); defer { try? FileManager.default.removeItem(at: parent) }
        let original = intent(), initial = try stored(await journal.create(original))
        let pending = try stored(await journal.writeAhead(.reserve, command: "first", expected: initial.cursor))
        async let mutation = journal.writeAhead(.cancel, command: "concurrent", expected: pending.cursor)
        async let loss = journal.sourceLostLatest(.sourceProcessLost, original: original)
        let (mutationResult, lossResult) = await (mutation, loss)
        let unknown = try stored(lossResult), final = try stored(await journal.load(original.id))
        #expect(unknown.phase == .unknown && final == unknown && final.intent == original)
        #expect(final.pending.first?.command == "first")
        if case .stored(let advanced) = mutationResult {
            #expect(advanced.phase == .cancelDispatchPending)
            #expect(final.pending == advanced.pending && final.cursor.revision == advanced.cursor.revision + 1)
        } else { #expect(mutationResult == .invalid || mutationResult == .conflict) }
        #expect(await journal.writeAhead(.cancel, command: "after-loss", expected: final.cursor) == .invalid)
    }
    @Test func latestLossNeverTouchesAnotherImmutableIntentOrSlot() async throws {
        let (parent, journal) = try world(); defer { try? FileManager.default.removeItem(at: parent) }
        let original = intent(), initial = try stored(await journal.create(original))
        let other = NativeSwitchJournal.Intent(id: original.id, peer: original.peer, connection: "another-original-connection",
            members: original.members, target: original.target, settingsBaselineSHA256: original.settingsBaselineSHA256, privacy: original.privacy)
        #expect(await journal.sourceLostLatest(.helperEOF, original: other) == .unknown)
        #expect(await journal.load(original.id) == .stored(initial))
        #expect(await journal.sourceLostLatest(.helperEOF, original: intent()) == .unknown)
        #expect(await journal.load(original.id) == .stored(initial))
    }
    @Test func latestLossAfterAdvancedCursorRetainsAllEvidenceAndIsIdempotent() async throws {
        let (parent, journal) = try world(); defer { try? FileManager.default.removeItem(at: parent) }
        let original = intent(), initial = try stored(await journal.create(original))
        let reserve = try stored(await journal.writeAhead(.reserve, command: "original", expected: initial.cursor))
        let newer = try stored(await journal.writeAhead(.cancel, command: "explicit-cancel", expected: reserve.cursor))
        let lost = try stored(await journal.sourceLostLatest(.helperParentDeath, original: original))
        #expect(lost.phase == .unknown && lost.pending == newer.pending && lost.cursor.revision == newer.cursor.revision + 1)
        let same = try stored(await journal.sourceLostLatest(.unreadableIdentity, original: original))
        #expect(same == lost)
        let reopened = try NativeSwitchJournal(directory: parent.appendingPathComponent("owned"))
        #expect(await reopened.load(original.id) == .stored(lost))
    }

}
