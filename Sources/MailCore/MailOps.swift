import Foundation

// What you do to mail, done here at once and told to Gmail after
// (docs/mail.md, Ops). The store changes first, so the list answers in the
// same frame; the op waits in the journal and goes out with the next
// flush, again a little later when Gmail doesn't take it. Undo takes back
// an op that hasn't gone. Until it has, whatever the sync brings back is
// laid under it: an archived thread doesn't come back to the inbox because
// Gmail hadn't heard yet.
//
// An act on many threads at once (a selection, a bulk act) is one entry in
// the journal for up to a thousand of their messages, a pack, which Gmail
// hears as one messages/batchModify; one ⌘Z takes all of it back. An op can
// be on messages by their ids too (a Bulk Actions entry taken back, mail
// from a blocked sender): exactly those, a thousand a call.

public enum MailOps {
    /// What an op does to a thread's labels.
    static func effect(_ op: MailOp.Kind, label: String) -> (add: Set<String>, remove: Set<String>) {
        switch op {
        case .archive: return ([], ["INBOX"])
        case .unarchive: return (["INBOX"], [])
        case .read: return ([], ["UNREAD"])
        case .unread: return (["UNREAD"], [])
        // A label by its name (name:yab/Snoozed) waits for its id: here the
        // snoozes table says what is put away, not the labels.
        case .label: return label.hasPrefix("name:") ? ([], []) : ([label], [])
        case .unlabel: return label.hasPrefix("name:") ? ([], []) : ([], [label])
        case .trash: return (["TRASH"], ["INBOX"])
        // Out of Trash or spam as Gmail takes it out: not back in the inbox
        // by itself, which is an unarchive of its own.
        case .untrash: return ([], ["TRASH"])
        case .star: return (["STARRED"], [])
        case .unstar: return ([], ["STARRED"])
        case .spam: return (["SPAM"], ["INBOX"])
        case .unspam: return ([], ["SPAM"])
        // Muted: out of the inbox under yab/Muted, its id waiting like
        // Snoozed's; the muted table says what is muted here.
        case .mute: return ([], ["INBOX"])
        case .unmute: return ([], [])
        // A send reads its acknowledged message back before refreshing lists.
        case .send: return ([], [])
        }
    }

    /// The op that takes another back once Gmail has heard it.
    static func inverse(_ kind: MailOp.Kind) -> MailOp.Kind? {
        switch kind {
        case .archive: return .unarchive
        case .unarchive: return .archive
        case .read: return .unread
        case .unread: return .read
        case .label: return .unlabel
        case .unlabel: return .label
        case .trash: return .untrash
        case .untrash: return .trash
        case .star: return .unstar
        case .unstar: return .star
        case .spam: return .unspam
        case .unspam: return .spam
        case .mute: return .unmute
        case .unmute: return .mute
        case .send: return nil
        }
    }

    /// Done here now, told to Gmail with the next flush. `after`: held that
    /// long first, for an undo.
    @discardableResult
    public static func act(_ kind: MailOp.Kind, thread: String, label: String = "", after: TimeInterval = 0, in store: MailStore) -> Int64 {
        let change = effect(kind, label: label)
        store.relabel(thread: thread, add: change.add, remove: change.remove)
        return store.queueOp(kind, thread: thread, label: label, after: after)
    }

    /// The most messages one messages/batchModify takes.
    static let packSize = 1000

    /// One op's entry in the journal and the threads it is on.
    public struct Part: Equatable {
        public var seq: Int64
        public var threads: [String]
    }

    /// One op on many threads: here at once, and to Gmail in packs of up to
    /// a thousand messages, one entry in the journal each. One thread is an
    /// op of its own, as ever.
    @discardableResult
    public static func bulk(_ kind: MailOp.Kind, threads: [String], label: String = "", after: TimeInterval = 0, in store: MailStore) -> [Part] {
        if threads.count == 1 { return [Part(seq: act(kind, thread: threads[0], label: label, after: after, in: store), threads: threads)] }
        let change = effect(kind, label: label)
        store.relabel(threads: threads, add: change.add, remove: change.remove)
        return packs(threads, in: store).map { Part(seq: store.queuePack(kind, threads: $0, label: label, after: after), threads: $0) }
    }

    /// Threads gathered into packs of up to `packSize` messages, in order;
    /// a thread longer than that is a pack of its own.
    static func packs(_ threads: [String], in store: MailStore) -> [[String]] {
        let counts = store.messageCounts(threads)
        var out: [[String]] = [], pack: [String] = [], held = 0
        for thread in threads {
            let n = max(1, counts[thread] ?? 1)
            if !pack.isEmpty, held + n > packSize {
                out.append(pack)
                pack = []
                held = 0
            }
            pack.append(thread)
            held += n
        }
        if !pack.isEmpty { out.append(pack) }
        return out
    }

    /// One op on messages by their ids, whatever threads they are in: here
    /// at once, to Gmail as messages/batchModify, a journal entry for each
    /// thousand of them.
    @discardableResult
    public static func bulk(_ kind: MailOp.Kind, messages ids: [String], after: TimeInterval = 0, in store: MailStore) -> [Int64] {
        guard !ids.isEmpty else { return [] }
        let change = effect(kind, label: "")
        store.relabel(messages: ids, add: change.add, remove: change.remove)
        return stride(from: 0, to: ids.count, by: packSize).map { start in
            store.queueMessages(kind, ids: Array(ids[start..<min(ids.count, start + packSize)]), after: after)
        }
    }

    /// An op's change here: on its messages, or on every message of its threads.
    private static func apply(_ op: MailOp, add: Set<String>, remove: Set<String>, in store: MailStore) {
        if op.onMessages { store.relabel(messages: op.messages, add: add, remove: remove) } else { store.relabel(threads: op.threads, add: add, remove: remove) }
    }

    /// Takes back an op Gmail hasn't heard yet. False when it already went.
    public static func undo(_ seq: Int64, in store: MailStore) -> Bool {
        guard let op = store.op(seq), store.dropOp(seq) else { return false }
        let change = effect(op.kind, label: op.label)
        apply(op, add: change.remove, remove: change.add, in: store)
        return true
    }

    /// The ops not yet sent, laid again over what the sync just stored.
    static func layOver(_ store: MailStore) {
        for op in store.allOps() {
            let change = effect(op.kind, label: op.label)
            apply(op, add: change.add, remove: change.remove, in: store)
        }
    }

    /// A mail written and held for its undo, out now, with its files.
    /// Gmail not answering isn't Gmail not sending: before it goes again,
    /// Sent is asked whether it is already there, so it is never sent
    /// twice. Gone, its reminder if nobody answers is kept against it
    /// (MailFollowups), and its draft goes, the copies of its files with it.
    private static func send(_ op: MailOp, store: MailStore, provider: any MailProvider, now: () -> Date) async throws {
        guard let draft = store.draft(op.thread) else { return store.doneOp(op.seq) }
        // From the address it was written from (an alias's name with it), its signature under the words.
        let (me, going) = MailCompose.going(draft, store: store)
        let extras = going
        // Gone in a thread, at a time: when it went, on mail's clock (a test
        // world's moved on).
        let sent = { (thread: String, at: Date) in
            MailFollowups.sent(draft, thread: thread, at: at, in: store)
            store.dropDraft(draft.id)
            MailAttach.drop(draft: draft.id, store: store)
            store.doneOp(op.seq)
        }
        do {
            if op.tries > 0, !draft.messageID.isEmpty, let found = (try? await provider.sentThread(messageID: draft.messageID)) ?? nil {
                let thread = draft.thread.isEmpty ? found : draft.thread
                sent(thread, now().addingTimeInterval(MailClock.shift))
                await readSent(thread, message: nil, store: store, provider: provider)
                return
            }
            // More than Gmail takes (refused at ⌘↩ already): never tried,
            // the draft kept to be sent again with less.
            guard MailAttach.tooBig(draft.files) == nil else { return store.doneOp(op.seq) }
            let files = try await MailAttach.parts(of: draft, store: store, provider: provider)
            let receipt = try await provider.send(raw: MailCompose.raw(draft, from: me, files: files, extras: extras), thread: draft.thread)
            sent(receipt.thread, now().addingTimeInterval(MailClock.shift))
            await readSent(receipt.thread, message: receipt.message, store: store, provider: provider)
        } catch MailTrouble.signedOut {
            throw MailTrouble.signedOut
        } catch MailTrouble.limited {
            store.retryOp(op.seq, at: now().addingTimeInterval(limitedWait), counted: false)
            throw MailTrouble.limited
        } catch {
            if op.tries + 1 >= tries {
                // Given up; the draft stays, to be sent again by hand.
                store.doneOp(op.seq)
            } else {
                store.retryOp(op.seq, at: now().addingTimeInterval(min(600, 5 * pow(2, Double(op.tries)))))
            }
        }
    }

    /// Sent and the thread show the reply without waiting for the next sync.
    /// The send is already completed in the journal: a failed read must never
    /// retry it. Normal sync will recover the message if this read fails.
    private static func readSent(_ thread: String, message: String?, store: MailStore, provider: any MailProvider) async {
        do {
            let messages: [MailMessage]
            if let message {
                messages = try await provider.message(message, full: false).map { [$0] } ?? []
            } else if !thread.isEmpty {
                // Recovery after a lost send response only knows the thread.
                messages = try await provider.thread(thread, full: false)
            } else {
                return
            }
            store.put(messages)
            layOver(store)
        } catch {
            // Gmail accepted the send; only the local cache is still behind.
        }
    }

    // MARK: - snoozing

    public static let snoozed = "name:yab/Snoozed"

    /// Away until a time, or until someone writes: here at once, in Gmail
    /// as an archive and a label.
    public static func snooze(_ thread: String, until: Date?, why: String, in store: MailStore) {
        store.snooze(MailSnooze(thread: thread, until: until, why: why, message: store.lastFromOthers(thread) ?? ""))
        act(.archive, thread: thread, in: store)
        act(.label, thread: thread, label: snoozed, in: store)
    }

    /// A snooze taken back (⌘Z): in the inbox as it was, read or not.
    static func unsnooze(_ thread: String, in store: MailStore) {
        store.unsnooze(thread)
        act(.unarchive, thread: thread, in: store)
        act(.unlabel, thread: thread, label: snoozed, in: store)
    }

    /// A wake taken back (⌘Z): put away again as it was, until the same
    /// time or the same reply, read or not as it was.
    public static func resnooze(_ snooze: MailSnooze, unread: Bool, in store: MailStore) {
        store.snooze(snooze)
        act(.archive, thread: snooze.thread, in: store)
        if !unread { act(.read, thread: snooze.thread, in: store) }
        act(.label, thread: snooze.thread, label: snoozed, in: store)
    }

    /// Back in the inbox, unread, as new.
    public static func wake(_ thread: String, in store: MailStore) {
        store.unsnooze(thread)
        act(.unarchive, thread: thread, in: store)
        act(.unread, thread: thread, in: store)
        act(.unlabel, thread: thread, label: snoozed, in: store)
    }

    /// The threads due back now: their time came, or someone wrote.
    public static func due(_ store: MailStore, now: Date = MailClock.now) -> [String] {
        store.snoozes().filter { snooze in
            if let until = snooze.until, until <= now { return true }
            let last = store.lastFromOthers(snooze.thread) ?? ""
            return !last.isEmpty && last != snooze.message
        }.map(\.thread)
    }

    /// Every thread due back, back: by the app or `yab mail flush`, each
    /// woken by the one that takes its snooze first (MailStore.takeSnooze),
    /// so never twice.
    @discardableResult
    public static func wakeDue(_ store: MailStore, now: Date = MailClock.now) -> [String] {
        due(store, now: now).filter { thread in
            guard store.takeSnooze(thread) != nil else { return false }
            act(.unarchive, thread: thread, in: store)
            act(.unread, thread: thread, in: store)
            act(.unlabel, thread: thread, label: snoozed, in: store)
            return true
        }
    }

    // MARK: - done waiting

    /// E on a thread in Waiting: done waiting on it, here only, as Gmail
    /// has no Waiting. Archived, it would come back through Sent; so it is
    /// out until a new message comes in it: theirs brings it to Needs you,
    /// another of yours back to Waiting. False when it wasn't waiting.
    @discardableResult
    static func stopWaiting(_ thread: String, in store: MailStore, now: Date = MailClock.now) -> Bool {
        guard let found = store.thread(thread), MailSplit.of(found, sensed: store.sensed(thread), now: now) == .waiting else { return false }
        store.stopWaiting(thread)
        return true
    }

    /// Done with a thread you wait on, or one its reminder brought back
    /// (MailFollowups): done waiting on it, its reminder gone with it. A
    /// reminder still waiting on a thread done from Needs you (a reply
    /// sent, then E) stays: that is what it is for. What it ended, for ⌘Z.
    public static func doneWaiting(_ thread: String, in store: MailStore, now: Date = MailClock.now) -> (stopped: Bool, reminder: MailFollowup?) {
        var stopped = stopWaiting(thread, in: store, now: now)
        guard let reminder = store.followup(thread) else { return (stopped, nil) }
        if reminder.fired != nil, !stopped {
            store.stopWaiting(thread)
            stopped = true
        }
        guard stopped else { return (false, nil) }
        store.unfollow(thread)
        return (true, reminder)
    }

    // MARK: - muted

    /// yab/Muted, by its name until Gmail gives its id.
    public static let muted = "name:yab/Muted"

    /// New mail in a muted thread, put away as it comes: archived here and
    /// in Gmail, left unread, the mute kept against it. A muted thread
    /// moved to the inbox with nothing new in it stays where it was put.
    /// First the mutes as Gmail keeps them (yab/Muted), so one made on
    /// another Mac, or before Yab was put on this one again, holds here too.
    static func keepMuted(_ store: MailStore) {
        if let label = store.labelID(exactly: "yab/Muted") { store.readMutes(label: label) }
        for thread in store.mutedArrivals() {
            act(.archive, thread: thread, in: store)
            store.mute(thread)
        }
    }

    // MARK: - answers to invitations

    /// An answer of yours to an invitation (an iCalendar REPLY, from here
    /// or from your phone) is the last word of a thread nobody owes you a
    /// reply in: done waiting on, so Waiting never lists it.
    static func keepAnswered(_ store: MailStore) {
        store.settleAnswers()
    }

    // MARK: - blocked

    /// New mail from a sender you blocked, into Trash as it comes: here and
    /// in Gmail, by the message, as Gmail's own block goes, so a thread
    /// others write in too keeps their mail where it is.
    static func keepBlocked(_ store: MailStore) {
        bulk(.trash, messages: store.blockedArrivals(), in: store)
    }

    // MARK: - acts on threads, and ⌘Z

    /// What an act did to threads of one account, for ⌘Z to take back: the
    /// ops it queued, in order, and how its threads stood before.
    public struct Acted: Equatable {
        public struct Entry: Equatable {
            public var kind: MailOp.Kind
            public var label = ""
            public var parts: [Part]
            public var threads: [String] { parts.flatMap(\.threads) }
        }
        public var entries: [Entry] = []
        /// Every thread it was on, as asked.
        public var threads: [String] = []
        /// In the inbox before: what it took out goes back there, and only there.
        public var inbox: Set<String> = []
        /// Done waiting on by it (E in Waiting), and waited on again (⇧E).
        var stoppedWaiting: Set<String> = []
        var waitedAgain: Set<String> = []
        public var muted: Set<String> = []
        public var unmuted: Set<String> = []
        /// Put away for later by it (H), and no longer (E on one in Later).
        public var snoozed: [MailSnooze] = []
        var unsnoozed: [MailSnooze] = []
        /// Reminders if nobody answers it ended (E on a thread waited on,
        /// or one a reminder brought back), as they were.
        var unfollowed: [MailFollowup] = []
        /// Senders it kept out (Block Sender), as the store keeps them.
        public var blocked: [String] = []

        /// The kinds of op it queued, in order.
        public var kinds: [MailOp.Kind] { entries.map(\.kind) }
        public var isEmpty: Bool {
            entries.isEmpty && stoppedWaiting.isEmpty && waitedAgain.isEmpty && muted.isEmpty && unmuted.isEmpty
                && snoozed.isEmpty && unsnoozed.isEmpty && unfollowed.isEmpty && blocked.isEmpty
        }
    }

    /// The threads as they stand before an act.
    private static func before(_ threads: [String], in store: MailStore) -> (Acted, [String: MailThread]) {
        var acted = Acted()
        acted.threads = threads
        var found: [String: MailThread] = [:]
        for id in threads {
            guard let thread = store.thread(id) else { continue }
            found[id] = thread
            if thread.labels.contains("INBOX") { acted.inbox.insert(id) }
        }
        return (acted, found)
    }

    /// An op on threads, queued and kept in the act.
    private static func record(_ kind: MailOp.Kind, _ threads: [String], label: String = "", after: TimeInterval,
                               into acted: inout Acted, in store: MailStore) {
        guard !threads.isEmpty else { return }
        acted.entries.append(Acted.Entry(kind: kind, label: label, parts: bulk(kind, threads: threads, label: label, after: after, in: store)))
        // By hand, a few at a time: what offers are made of (MailOffers); a
        // sweep of thousands says nothing about one sender.
        if threads.count <= 50, kind == .archive || kind == .label { store.logActs(kind.rawValue, threads: threads, label: label) }
    }

    /// E: done. Out of the inbox; a thread in Waiting is done waiting on
    /// too, and one out of the inbox already, found through Sent, only that;
    /// one put away for later no longer comes back; one its reminder
    /// brought back is done waiting on, the reminder ended.
    public static func done(_ threads: [String], after: TimeInterval = 0, in store: MailStore, now: Date = MailClock.now) -> Acted {
        var (acted, found) = before(threads, in: store)
        for id in threads {
            let (stopped, reminder) = doneWaiting(id, in: store, now: now)
            if stopped { acted.stoppedWaiting.insert(id) }
            if let reminder { acted.unfollowed.append(reminder) }
        }
        let asked = Set(threads)
        acted.unsnoozed = store.snoozes().filter { asked.contains($0.thread) }
        for snooze in acted.unsnoozed { store.unsnooze(snooze.thread) }
        record(.archive, threads.filter { found[$0]?.labels.contains("INBOX") == true }, after: after, into: &acted, in: store)
        record(.unlabel, acted.unsnoozed.map(\.thread), label: snoozed, after: after, into: &acted, in: store)
        return acted
    }

    /// S: starred; all of them starred already, not.
    public static func star(_ threads: [String], after: TimeInterval = 0, in store: MailStore) -> Acted {
        var (acted, found) = before(threads, in: store)
        let plain = threads.filter { found[$0]?.labels.contains("STARRED") == false }
        if plain.isEmpty {
            record(.unstar, threads.filter { found[$0] != nil }, after: after, into: &acted, in: store)
        } else {
            record(.star, plain, after: after, into: &acted, in: store)
        }
        return acted
    }

    /// #: into Trash; all of them there already, out of it, back in the inbox.
    public static func trash(_ threads: [String], after: TimeInterval = 0, in store: MailStore) -> Acted {
        var (acted, found) = before(threads, in: store)
        let rest = threads.filter { found[$0]?.labels.contains("TRASH") == false }
        if rest.isEmpty {
            let all = threads.filter { found[$0] != nil }
            record(.untrash, all, after: after, into: &acted, in: store)
            record(.unarchive, all, after: after, into: &acted, in: store)
        } else {
            record(.trash, rest, after: after, into: &acted, in: store)
        }
        return acted
    }

    /// !: spam; all of them spam already, not spam, back in the inbox.
    public static func spam(_ threads: [String], after: TimeInterval = 0, in store: MailStore) -> Acted {
        var (acted, found) = before(threads, in: store)
        let rest = threads.filter { found[$0]?.labels.contains("SPAM") == false }
        if rest.isEmpty {
            let all = threads.filter { found[$0] != nil }
            record(.unspam, all, after: after, into: &acted, in: store)
            record(.unarchive, all, after: after, into: &acted, in: store)
        } else {
            record(.spam, rest, after: after, into: &acted, in: store)
        }
        return acted
    }

    /// ⇧M: muted, out of the inbox and kept out of it; all of them muted
    /// already, unmuted, back in the inbox.
    public static func mute(_ threads: [String], after: TimeInterval = 0, in store: MailStore) -> Acted {
        var (acted, found) = before(threads, in: store)
        let loud = threads.filter { found[$0]?.muted == false }
        if loud.isEmpty {
            let all = threads.filter { found[$0] != nil }
            for id in all { store.unmute(id) }
            acted.unmuted = Set(all)
            record(.unmute, all, label: muted, after: after, into: &acted, in: store)
            record(.unarchive, all.filter { !acted.inbox.contains($0) }, after: after, into: &acted, in: store)
        } else {
            for id in loud { store.mute(id) }
            acted.muted = Set(loud)
            record(.mute, loud, label: muted, after: after, into: &acted, in: store)
        }
        return acted
    }

    /// ⇧E: not done, back in the inbox: waited on again if you were done
    /// waiting on it, no longer muted. Snoozed threads wake with W instead.
    public static func notDone(_ threads: [String], after: TimeInterval = 0, in store: MailStore) -> Acted {
        var (acted, found) = before(threads, in: store)
        let snoozed = Set(store.snoozes().map(\.thread))
        let out = threads.filter { found[$0].map { !$0.labels.contains("INBOX") } == true && !snoozed.contains($0) }
        for id in out where found[id]?.doneWaiting == true {
            store.waitAgain(id)
            acted.waitedAgain.insert(id)
        }
        for id in out where found[id]?.muted == true {
            store.unmute(id)
            acted.unmuted.insert(id)
        }
        record(.unmute, out.filter { acted.unmuted.contains($0) }, label: muted, after: after, into: &acted, in: store)
        record(.unarchive, out, after: after, into: &acted, in: store)
        return acted
    }

    /// U: unread; all of them unread already, read.
    public static func unread(_ threads: [String], after: TimeInterval = 0, in store: MailStore) -> Acted {
        var (acted, found) = before(threads, in: store)
        let read = threads.filter { found[$0]?.unread == false }
        if read.isEmpty {
            record(.read, threads.filter { found[$0] != nil }, after: after, into: &acted, in: store)
        } else {
            record(.unread, read, after: after, into: &acted, in: store)
        }
        return acted
    }

    /// Mark All as Read on a label: read, the threads that are unread.
    public static func read(_ threads: [String], after: TimeInterval = 0, in store: MailStore) -> Acted {
        var (acted, found) = before(threads, in: store)
        record(.read, threads.filter { found[$0]?.unread == true }, after: after, into: &acted, in: store)
        return acted
    }

    /// L: a label of the person's (its id) on the threads; on all of them
    /// already, off them.
    public static func label(_ threads: [String], id: String, after: TimeInterval = 0, in store: MailStore) -> Acted {
        var (acted, found) = before(threads, in: store)
        let without = threads.filter { found[$0]?.labels.contains(id) == false }
        if without.isEmpty {
            record(.unlabel, threads.filter { found[$0] != nil }, label: id, after: after, into: &acted, in: store)
        } else {
            record(.label, without, label: id, after: after, into: &acted, in: store)
        }
        return acted
    }

    /// Y in a label's list: that label off the threads that carry it.
    public static func unlabel(_ threads: [String], id: String, after: TimeInterval = 0, in store: MailStore) -> Acted {
        var (acted, found) = before(threads, in: store)
        record(.unlabel, threads.filter { found[$0]?.labels.contains(id) == true }, label: id, after: after, into: &acted, in: store)
        return acted
    }

    /// V: moved under a label, as Gmail's Move to moves: the label on, out
    /// of the inbox, and out of the label of the list it was moved from
    /// (`from`), when that is another.
    public static func move(_ threads: [String], to id: String, from: String? = nil, after: TimeInterval = 0, in store: MailStore) -> Acted {
        var (acted, found) = before(threads, in: store)
        let here = threads.filter { found[$0] != nil }
        record(.label, here.filter { found[$0]?.labels.contains(id) == false }, label: id, after: after, into: &acted, in: store)
        record(.archive, here.filter { acted.inbox.contains($0) }, after: after, into: &acted, in: store)
        if let from, from != id {
            record(.unlabel, here.filter { found[$0]?.labels.contains(from) == true }, label: from, after: after, into: &acted, in: store)
        }
        return acted
    }

    /// H: away until a time, or until someone writes, out of the inbox
    /// under yab/Snoozed.
    public static func snooze(_ threads: [String], until: Date?, why: String, after: TimeInterval = 0, in store: MailStore) -> Acted {
        var (acted, found) = before(threads, in: store)
        let here = threads.filter { found[$0] != nil }
        for id in here {
            let snooze = MailSnooze(thread: id, until: until, why: why, message: store.lastFromOthers(id) ?? "")
            store.snooze(snooze)
            acted.snoozed.append(snooze)
        }
        record(.archive, here.filter { acted.inbox.contains($0) }, after: after, into: &acted, in: store)
        record(.label, here, label: snoozed, after: after, into: &acted, in: store)
        return acted
    }

    /// Out of the inbox and nothing more, however they stand otherwise:
    /// Get Me To Zero, and everything from a sender after ⌘U. Waiting and
    /// Later aren't the inbox's, so they keep what they hold. `inbox`: all
    /// of them are in it, known already, so none is looked up (thousands).
    public static func archive(_ threads: [String], inbox: Bool = false, after: TimeInterval = 0, in store: MailStore) -> Acted {
        guard !inbox else {
            var acted = Acted(threads: threads, inbox: Set(threads))
            record(.archive, threads, after: after, into: &acted, in: store)
            return acted
        }
        var (acted, found) = before(threads, in: store)
        record(.archive, threads.filter { found[$0]?.labels.contains("INBOX") == true }, after: after, into: &acted, in: store)
        return acted
    }

    /// Block Sender: the senders kept out from now on, their new mail into
    /// Trash as it comes (keepBlocked), and these threads into Trash now.
    public static func block(_ senders: [String], threads: [String], after: TimeInterval = 0, in store: MailStore) -> Acted {
        let kept = Set(store.blocked().map(\.who))
        // Into Trash, never out of it: one there already stays.
        let rest = threads.filter { store.thread($0).map { !$0.labels.contains("TRASH") } ?? false }
        var acted = rest.isEmpty ? Acted() : trash(rest, after: after, in: store)
        for who in senders where !kept.contains(who) && !acted.blocked.contains(who) {
            store.block(who)
            acted.blocked.append(who)
        }
        return acted
    }

    /// An act taken back (⌘Z), its last op first: an op Gmail hasn't heard
    /// is dropped, its change undone here; one it has gets its inverse. What
    /// it took out of the inbox goes back only where it was.
    public static func takeBack(_ acted: Acted, in store: MailStore) {
        for entry in acted.entries.reversed() {
            let tookOut = effect(entry.kind, label: entry.label).remove.contains("INBOX")
            var heard: [String] = []
            for part in entry.parts {
                if undo(part.seq, in: store) {
                    if tookOut { store.relabel(threads: part.threads.filter { !acted.inbox.contains($0) }, add: [], remove: ["INBOX"]) }
                } else {
                    heard += part.threads
                }
            }
            guard !heard.isEmpty, let back = inverse(entry.kind) else { continue }
            if effect(back, label: entry.label).add.contains("INBOX") {
                bulk(back, threads: heard.filter { acted.inbox.contains($0) }, label: entry.label, in: store)
            } else {
                bulk(back, threads: heard, label: entry.label, in: store)
                let inbox = heard.filter { acted.inbox.contains($0) }
                if tookOut, !inbox.isEmpty { bulk(.unarchive, threads: inbox, in: store) }
            }
        }
        for id in acted.stoppedWaiting { store.waitAgain(id) }
        for id in acted.waitedAgain { store.stopWaiting(id) }
        for id in acted.muted { store.unmute(id) }
        for id in acted.unmuted { store.mute(id) }
        for snooze in acted.snoozed { store.unsnooze(snooze.thread) }
        for snooze in acted.unsnoozed { store.snooze(snooze) }
        for reminder in acted.unfollowed { store.follow(reminder) }
        for who in acted.blocked { store.unblock(who) }
    }

    // MARK: - the Bulk Actions log

    /// How long the log keeps an entry to be taken back.
    public static let bulkKept: TimeInterval = 7 * 86_400

    /// An act on many threads, kept in the log: the messages it moved,
    /// before it moves them. Its id, for ⌘Z to mark it taken back.
    @discardableResult
    public static func log(_ kind: MailBulk.Kind, said: String, threads: [String], in store: MailStore, now: Date = Date()) -> Int64 {
        store.forgetBulks(before: now.addingTimeInterval(-bulkKept))
        let moved = store.messages(of: threads).filter { kind == .trash || $0.inbox }
        return store.logBulk(kind.rawValue, said: said, threads: threads.count, messages: moved, at: now)
    }

    /// An entry of the log taken back: its mail back in the inbox, here at
    /// once and in Gmail by its messages' ids, exactly those it took out;
    /// out of Trash first, for what it put there. Mail moved since (into
    /// spam, into Trash after it was done) stays where it was put. The
    /// threads back in the inbox; nil once it was taken back, or too old.
    @discardableResult
    public static func restore(_ id: Int64, in store: MailStore, now: Date = Date()) -> [String]? {
        guard let entry = store.bulk(id), entry.back == nil, now.timeIntervalSince(entry.at) < bulkKept else { return nil }
        let moved = store.bulkMessages(id)
        let labels = store.labels(of: moved.map(\.id))
        // Not here any more (a reset, Gmail deleted it): Gmail is told all the same.
        let away: (String) -> Bool = { id in
            guard let now = labels[id] else { return false }
            return entry.kind == .trash ? !now.contains("TRASH") || now.contains("SPAM") : !now.isDisjoint(with: ["TRASH", "SPAM"])
        }
        let back = moved.filter { !away($0.id) }
        if entry.kind == .trash { bulk(.untrash, messages: back.map(\.id), in: store) }
        bulk(.unarchive, messages: back.filter(\.inbox).map(\.id), in: store)
        store.bulkBack(id, at: now)
        var seen = Set<String>()
        return back.filter(\.inbox).map(\.thread).filter { seen.insert($0).inserted }
    }

    // MARK: - to Gmail

    /// How many times an op goes before it is given up.
    public static let tries = 8
    /// How long an op waits when Gmail said slow down; that isn't a try.
    static let limitedWait: TimeInterval = 60

    /// Every op that is due, to Gmail, oldest first. Stops at a refused
    /// token, or at Gmail saying slow down: nothing else would go either.
    public static func flush(_ store: MailStore, gmail: MailGmail, now: @escaping () -> Date = Date.init) async throws {
        try await flush(store, provider: gmail, now: now)
    }

    /// Every op that is due, to the account's server, oldest first.
    public static func flush(_ store: MailStore, provider: any MailProvider, now: @escaping () -> Date = Date.init) async throws {
        let due = store.dueOps(now: now())
        var folded = Set<Int64>()
        for op in due where !folded.contains(op.seq) {
            guard store.take(op.seq, now: now()) else { continue }
            let change = effect(op.kind, label: op.label)
            if op.kind == .send {
                try await send(op, store: store, provider: provider, now: now)
                continue
            }
            // Out of Trash or spam and back in the inbox (# or ! again, ⇧E, a
            // Bulk Actions entry taken back): one call where Gmail would hear
            // two, the unarchive of the same threads put into its modify
            // (TRASH and SPAM are labels a modify may take off).
            var both: MailOp?
            if op.kind == .untrash || op.kind == .unspam,
               let next = due.first(where: { $0.seq > op.seq && $0.kind == .unarchive && !folded.contains($0.seq) && same(op, $0) }),
               store.take(next.seq, now: now()) {
                both = next
                folded.insert(next.seq)
            }
            let taken = [op] + (both.map { [$0] } ?? [])
            do {
                var add = change.add, remove = change.remove
                if both != nil { add.insert("INBOX") }
                if op.label.hasPrefix("name:") {
                    let id = try await label(String(op.label.dropFirst(5)), store: store, provider: provider)
                    if op.kind == .label || op.kind == .mute { add.insert(id) } else { remove.insert(id) }
                }
                if op.onMessages {
                    try await provider.apply(MailEdit(.messages(op.messages), add: add, remove: remove), in: store)
                } else if op.isPack {
                    try await provider.apply(MailEdit(.threads(op.threads), add: add, remove: remove), in: store)
                } else if op.kind == .trash {
                    try await provider.apply(MailEdit(.thread(op.thread), add: add, remove: remove, way: .trash), in: store)
                } else if op.kind == .untrash, both == nil {
                    try await provider.apply(MailEdit(.thread(op.thread), add: add, remove: remove, way: .untrash), in: store)
                } else {
                    try await provider.apply(MailEdit(.thread(op.thread), add: add, remove: remove), in: store)
                }
                for one in taken { store.doneOp(one.seq) }
                // The labels it changed count otherwise now (MailLabels).
                store.staleLabels(add.union(remove))
            } catch MailTrouble.signedOut {
                throw MailTrouble.signedOut
            } catch MailTrouble.limited {
                for one in taken { store.retryOp(one.seq, at: now().addingTimeInterval(limitedWait), counted: false) }
                throw MailTrouble.limited
            } catch MailTrouble.status(404) {
                // The thread is gone from Gmail: nothing left to do.
                for one in taken { store.doneOp(one.seq) }
            } catch {
                for one in taken {
                    if one.tries + 1 >= tries {
                        // Given up: what Gmail has is what stands.
                        store.doneOp(one.seq)
                        let made = effect(one.kind, label: one.label)
                        apply(one, add: made.remove, remove: made.add, in: store)
                    } else {
                        let wait = min(600, 5 * pow(2, Double(one.tries)))
                        store.retryOp(one.seq, at: now().addingTimeInterval(wait))
                    }
                }
            }
        }
    }

    /// Two ops on the same mail: one thread, the same pack's threads, or
    /// the same messages.
    private static func same(_ one: MailOp, _ other: MailOp) -> Bool {
        if one.onMessages || other.onMessages { return one.onMessages && other.onMessages && one.messages == other.messages }
        if one.isPack || other.isPack { return one.isPack && other.isPack && one.threads == other.threads }
        return one.thread == other.thread
    }

    /// A label's id by its name (yab/Snoozed, yab/Muted), asked of the server once.
    private static func label(_ name: String, store: MailStore, provider: any MailProvider) async throws -> String {
        if let known = store.labelID(exactly: name) { return known }
        let id = try await provider.label(named: name)
        store.keep(label: MailLabel(id: id, name: name))
        return id
    }
}
