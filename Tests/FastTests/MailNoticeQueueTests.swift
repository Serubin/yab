import Dispatch
import Foundation
import Testing
@testable import Fast
@testable import MailCore

// The address field reads these notices on the main actor. A mail writer
// held elsewhere must not hold that read too. These are queue-order checks,
// not a measurement of how quickly the field paints.
@MainActor
struct MailNoticeQueueTests {
    private static let now = Date(timeIntervalSince1970: 1_790_000_000)
    private static let me = MailPerson(name: "Me", address: "me@example.test")
    private static let tim = MailPerson(name: "Tim Okafor", address: "tim@example.test")
    private static let ana = MailPerson(name: "Ana Ruiz", address: "ana@example.test")

    private func seed(_ store: MailStore) {
        store.set("me", Self.me.address)
        store.put([
            message("waiting-in", thread: "waiting", from: Self.tim, days: 6, labels: ["INBOX"]),
            message("waiting-out", thread: "waiting", from: Self.me, days: 5, labels: ["SENT"]),
            message("reply-out", thread: "reply", from: Self.me, days: 3, labels: ["SENT"]),
            message("reply-in", thread: "reply", from: Self.tim, days: 1, labels: ["INBOX", "UNREAD"]),
            message("due-in", thread: "due", from: Self.ana, days: 2, labels: ["INBOX", "UNREAD"]),
        ])
        store.keep([
            MailSensed(thread: "waiting", message: "waiting-in", needs: false, gist: "Waiting for the files", kind: .person, byModel: true),
            MailSensed(thread: "reply", message: "reply-in", needs: true, gist: "Asks for the files", kind: .person, byModel: true),
            MailSensed(thread: "due", message: "due-in", needs: true, gist: "Review due soon", due: Self.now.addingTimeInterval(3600), kind: .person, byModel: true),
        ])
    }

    private func message(_ id: String, thread: String, from: MailPerson, days: Double, labels: Set<String>) -> MailMessage {
        MailMessage(id: id, thread: thread, from: from, to: [from == Self.me ? Self.tim : Self.me],
                    subject: "Files for \(thread)", snippet: "Could you send the files?",
                    date: Self.now.addingTimeInterval(-days * 86_400), labels: labels, text: "Could you send the files?")
    }

    private func notices(_ store: MailStore) -> [Noticing.MailNotice] {
        MailCenter.noticed(in: store, account: Self.me.address, now: Self.now).sorted { $0.thread < $1.thread }
    }

    private var expected: [Noticing.MailNotice] {
        [
            .init(account: Self.me.address, thread: "due", who: "Ana", host: "example.test", subject: "Files for due",
                  gist: "Review due soon", last: Self.now.addingTimeInterval(-2 * 86_400), due: Self.now.addingTimeInterval(3600),
                  why: .due, address: Self.ana.address),
            .init(account: Self.me.address, thread: "reply", who: "Tim", host: "example.test", subject: "Files for reply",
                  gist: "Asks for the files", last: Self.now.addingTimeInterval(-86_400), due: nil,
                  why: .waitingOnYou, address: Self.tim.address, conversation: true),
            .init(account: Self.me.address, thread: "waiting", who: "Tim", host: "example.test", subject: "Files for waiting",
                  gist: "Waiting for the files", last: Self.now.addingTimeInterval(-5 * 86_400), due: nil,
                  why: .noAnswer, address: Self.tim.address),
        ]
    }

    @Test func noticesReturnBeforeTheWriterIsReleased() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mail-notice-queue-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = MailStore(file: folder.appendingPathComponent("mail.sqlite"))
        seed(store)
        #expect(store.off !== store)
        #expect(notices(store) == expected)

        let entered = DispatchSemaphore(value: 0)
        let releaseWriter = DispatchSemaphore(value: 0)
        let writerDone = DispatchGroup()
        let writerTimedOut = DispatchSemaphore(value: 0)
        let readStarted = DispatchSemaphore(value: 0)
        let readReturned = DispatchSemaphore(value: 0)
        let writerReleased = DispatchSemaphore(value: 0)
        let watchdogDone = DispatchSemaphore(value: 0)
        writerDone.enter()
        defer {
            releaseWriter.signal()
            #expect(writerDone.wait(timeout: .now() + 10) == .success)
        }
        DispatchQueue(label: "test.mail-notice.writer").async {
            // Runs inside the writer's queue; holding it changes no seeded mail or notice values.
            store.holdWriter(0) {
                entered.signal()
                if releaseWriter.wait(timeout: .now() + 15) == .timedOut { writerTimedOut.signal() }
            }
            writerDone.leave()
        }
        let writerEntered = entered.wait(timeout: .now() + 5)
        try #require(writerEntered == .success)

        DispatchQueue(label: "test.mail-notice.watchdog").async {
            _ = readStarted.wait(timeout: .now() + 5)
            // Only a liveness fallback: the old implementation waits for
            // this release, then fails the ordering assertion below.
            _ = readReturned.wait(timeout: .now() + 5)
            writerReleased.signal()
            releaseWriter.signal()
            watchdogDone.signal()
        }
        readStarted.signal()
        let rows = notices(store)
        let returnedBeforeRelease = writerReleased.wait(timeout: .now()) == .timedOut
        readReturned.signal()
        let watchdogFinished = watchdogDone.wait(timeout: .now() + 5)
        #expect(watchdogFinished == .success)
        #expect(returnedBeforeRelease, "Notice reads must return while the writer is still held")
        #expect(rows == expected)
        let writerFinished = writerDone.wait(timeout: .now() + 5)
        try #require(writerFinished == .success)
        #expect(writerTimedOut.wait(timeout: .now()) == .timedOut)

        // The reader must see commits made after an earlier notice read,
        // including both the Waiting mark and its undo.
        #expect(MailOps.stopWaiting("waiting", in: store, now: Self.now))
        #expect(notices(store).map(\.thread) == ["due", "reply"])
        store.waitAgain("waiting")
        #expect(notices(store) == expected)
        let past = Self.now.addingTimeInterval(-1800)
        store.keep(MailSensed(thread: "due", message: "due-in", needs: true, gist: "Invoice now overdue", due: past, kind: .invoice, byModel: true))
        let changed = notices(store)
        var fresh = expected
        fresh[0].gist = "Invoice now overdue"
        fresh[0].due = past
        fresh[0].why = .pastDue
        #expect(changed == fresh)
    }

    @Test func remainingFieldMailReadsReturnWhileWriterIsHeld() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("field-mail-reads-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = MailStore(file: folder.appendingPathComponent("mail.sqlite"))
        seed(store)
        store.put([message("archived-in", thread: "archived", from: Self.tim, days: 0, labels: [])])
        store.skip([(thread: "archived", message: "archived-in", split: "other")], at: Self.now)
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let returned = DispatchSemaphore(value: 0), released = DispatchSemaphore(value: 0)
        let writerDone = DispatchGroup(), watchdogDone = DispatchGroup()
        writerDone.enter()
        DispatchQueue(label: "test.field-mail.writer").async {
            store.holdWriter(0) {
                entered.signal()
                _ = release.wait(timeout: .now() + 15)
            }
            writerDone.leave()
        }
        defer { release.signal(); _ = writerDone.wait(timeout: .now() + 10) }
        try #require(entered.wait(timeout: .now() + 5) == .success)
        watchdogDone.enter()
        DispatchQueue(label: "test.field-mail.watchdog").async {
            _ = returned.wait(timeout: .now() + 5)
            released.signal(); release.signal(); watchdogDone.leave()
        }
        let archived = MailCenter.archivedToday(in: [store], since: Self.now.addingTimeInterval(-1))
        let done = MailCenter.settled("waiting", in: store)
        let unread = MailCenter.settled("reply", in: store)
        let absent = MailCenter.settled("missing", in: store)
        let beforeRelease = released.wait(timeout: .now()) == .timedOut
        returned.signal()
        #expect(watchdogDone.wait(timeout: .now() + 5) == .success)
        #expect(writerDone.wait(timeout: .now() + 5) == .success)
        #expect(beforeRelease, "Skip and settled reads must return while the writer is held")
        #expect(archived.count == 1 && archived.splits == ["other"])
        #expect(done && !unread && !absent)
        let memory = MailStore(file: MailStore.memory)
        seed(memory)
        #expect(memory.off === memory)
        #expect(MailCenter.settled("waiting", in: memory))
        #expect(!MailCenter.settled("reply", in: memory))
    }

    @Test func memoryStoresKeepTheSameNoticeSemantics() {
        let store = MailStore(file: MailStore.memory)
        seed(store)
        #expect(store.off === store)
        #expect(notices(store) == expected)
    }
}
