import Foundation
import AppKit
import LocalAuthentication
import SyncKit
import SwiftUI
import UserNotifications

// The Mac that owns an assistant's pending permit writes its question to
// sealed Sync. Only a known second device can answer, and only that live
// permit can consume the answer. The relay has no approval endpoint.
extension SyncCenter {
    private static func accessLines(_ request: AssistantRequest) -> [String] {
        [request.site.map { "Site: \($0)" }, "Reason: \(request.reason)"].compactMap { $0 }
    }

    func foreignAssistantApprovals() -> [AssistantApprovalRecords.Request] {
        guard state == .live, let journal, let client else { return [] }
        let known = Set(devices.filter { !$0.revoked && $0.id != thisDevice }.map(\.id))
        return journal.all(AssistantApprovalRecords.requestCollection).compactMap { record in
            guard let writer = record.stamps["body"]?.device, known.contains(writer),
                  let request = try? AssistantApprovalRecords.Request.read(record, account: client.seal.account, mac: writer),
                  request.mac != thisDevice, (try? request.validate(at: Date())) != nil,
                  journal.record(.init(collection: AssistantApprovalRecords.answerCollection, id: request.id))?.alive() != true
            else { return nil }
            return request
        }.sorted { $0.issued < $1.issued }
    }

    func takeForeignAssistantApprovals() {
        ForeignAssistantApprovalCard.shared.update(foreignAssistantApprovals())
    }

    /// What another Mac's question is about, whole, when it wrote that.
    func foreignAssistantDetail(_ request: AssistantApprovalRecords.Request) -> AssistantApprovalRecords.Detail? {
        journal?.record(.init(collection: AssistantApprovalRecords.detailCollection, id: request.id))
            .flatMap { try? AssistantApprovalRecords.Detail.read($0, request: request) }
    }

    /// A yes or a no here; a payment's yes may pick a card and an address,
    /// the detail's or one just kept here (`added`, AssistantWallet).
    func answerForeignAssistantApproval(_ id: String, yes: Bool, choice: String? = nil, proved: Bool = false,
                                        card: String? = nil, place: String? = nil, added: [String] = []) throws {
        guard let journal, let client,
              let request = foreignAssistantApprovals().first(where: { $0.id == id }),
              let original = journal.record(.init(collection: AssistantApprovalRecords.requestCollection, id: id)),
              let fresh = try? AssistantApprovalRecords.Request.read(original, account: client.seal.account, mac: request.mac),
              fresh == request else { throw AssistantApprovalRecords.Failure.changed }
        let answer = try AssistantApprovalRecords.Answer(request: request, device: thisDevice, yes: yes, choice: yes ? choice : nil, proved: proved,
                                                         detail: foreignAssistantDetail(request), card: card, place: place, added: added)
        try journal.change(.init(collection: AssistantApprovalRecords.answerCollection, id: id), answer.fields())
        client.kick()
        takeForeignAssistantApprovals()
    }

    /// The other devices that pick a sign-in's account and prove a yes.
    var assistantChoosers: [SyncClient.Listed] {
        guard on, let journal else { return [] }
        return assistantAnswerers.filter {
            AssistantApprovalRecords.chooses(journal.record(.init(collection: OpenOnMac.capability, id: $0.id)), device: $0.id)
        }
    }

    /// `quiet`: you are at the Mac (AskPresence), so it goes up opened:
    /// the iPhone has it in its tray, answerable, but doesn't ring until
    /// `ringAssistantApproval` once you are away.
    func publishAssistantApproval(_ record: AssistantApprovals.Record, choices: [String]? = nil, quiet: Bool = false) {
        guard on, journal != nil, let client, record.kind == .yes, let permit = record.key,
              var request = try? AssistantApprovalRecords.Request(
                id: record.id, account: client.seal.account, mac: thisDevice,
                assistant: record.assistant, session: record.session,
                tab: record.place.wire, permit: permit,
                title: record.title, lines: record.lines, expires: record.expires, choices: choices) else { return }
        let saying: AssistantApprovalRecords.Saying = record.seen ? .opened : quiet ? .quiet : .ringing
        if saying != .ringing { request.seen = .init(device: thisDevice) }
        guard (try? request.fields()) != nil else { return }
        // What it is about, whole, beside it and before it: a device that
        // reads details finds the detail when the question comes.
        ApprovalDetails.shared.publish(record, request: request)
        do {
            try AssistantApprovalRecords.publish(request, saying, by: client)
        } catch {
            NSLog("assistant approval: couldn't publish: %@", String(describing: error))
        }
    }

    func publishAssistantAccess(_ access: AssistantRequest) {
        guard on, let journal, let client, let grant = Assistants.shared.grant(access.assistant),
              let request = try? AssistantApprovalRecords.Request(
                id: access.id, account: client.seal.account, mac: thisDevice,
                assistant: access.assistant, session: "access", tab: access.id,
                permit: access.what, title: "\(grant.name): allow \(access.what)?",
                lines: Self.accessLines(access), issued: access.at,
                expires: access.at.addingTimeInterval(15 * 60)),
              let fields = try? request.fields() else { return }
        do {
            try journal.change(.init(collection: AssistantApprovalRecords.requestCollection, id: request.id), fields)
            client.kick()
        } catch {
            NSLog("assistant access: couldn't publish: %@", String(describing: error))
        }
    }

    func seeAssistantApproval(_ id: String) {
        guard let journal, let client else { return }
        let key = SyncKit.Record.Key(collection: AssistantApprovalRecords.requestCollection, id: id)
        guard let original = journal.record(key),
              var request = try? AssistantApprovalRecords.Request.read(original, account: client.seal.account, mac: thisDevice),
              request.seen == nil else { return }
        request.seen = .init(device: thisDevice)
        do {
            try journal.change(key, request.fields())
            client.kick(alerting: key, withdraw: true)
        } catch { NSLog("assistant approval: couldn't mark opened: %@", String(describing: error)) }
    }

    /// A question that went up quiet, now said: its `seen` taken off, so
    /// the other devices ring. The facts and their digest stay the same,
    /// so an answer given to the quiet one still holds. False when it isn't
    /// in Sync to ring.
    @discardableResult
    func ringAssistantApproval(_ id: String) -> Bool {
        guard journal != nil, let client else { return false }
        do {
            return try AssistantApprovalRecords.ring(id, by: client, mac: thisDevice)
        } catch {
            NSLog("assistant approval: couldn't ring: %@", String(describing: error))
            return false
        }
    }

    /// The question over: its record goes, and its detail, pages and
    /// result with it. One answered on another device stays until what
    /// came of the yes is said there (ApprovalDetails.holds), unless `now`.
    func closeAssistantApproval(_ id: String, now: Bool = false) {
        if !now, ApprovalDetails.shared.holds(id) { return }
        ApprovalDetails.shared.forget(id)
        guard let journal, let client else { return }
        let key = SyncKit.Record.Key(collection: AssistantApprovalRecords.requestCollection, id: id)
        let beside = [SyncKit.Record.Key(collection: AssistantApprovalRecords.detailCollection, id: id),
                      SyncKit.Record.Key(collection: AssistantApprovalRecords.resultCollection, id: id)]
            + journal.all(AssistantApprovalRecords.previewCollection).filter { $0.id.hasPrefix(id.lowercased() + ".") }.map(\.key)
        do {
            try journal.remove(key)
            for other in beside where journal.record(other)?.alive() == true { try journal.remove(other) }
            client.kick(alerting: key, withdraw: true)
        }
        catch { NSLog("assistant approval: couldn't close: %@", String(describing: error)) }
    }

    func takeAssistantAnswers() {
        guard let journal, let client, state == .live else { return }
        AssistantApprovals.shared.publishWaiting()
        let known = Set(devices.filter { !$0.revoked && $0.id != thisDevice }.map(\.id))
        for record in AssistantApprovals.shared.records.values where record.kind == .yes && record.state == .open {
            let key = SyncKit.Record.Key(collection: AssistantApprovalRecords.requestCollection, id: record.id)
            let answerKey = SyncKit.Record.Key(collection: AssistantApprovalRecords.answerCollection, id: record.id)
            guard let original = journal.record(key), let answerRecord = journal.record(answerKey),
                  let writer = answerRecord.stamps["body"]?.device, known.contains(writer),
                  let request = try? AssistantApprovalRecords.Request.read(original, account: client.seal.account, mac: thisDevice),
                  let answer = try? AssistantApprovalRecords.Answer.read(answerRecord, request: request, device: writer) else { continue }
            // The detail the yes read, and its picks among it: a detail
            // changed since, or a pick it doesn't offer, and the yes is
            // refused, said back as a result.
            let detail = journal.record(.init(collection: AssistantApprovalRecords.detailCollection, id: request.id))
                .flatMap { try? AssistantApprovalRecords.Detail.read($0, request: request) }
            guard (try? AssistantApprovalRecords.validatePicks(answer, detail: detail)) != nil else {
                ApprovalDetails.shared.refuse(answer, words: "This changed on your Mac. Look again.")
                continue
            }
            AssistantApprovals.shared.answerFromSync(request, yes: answer.yes, choice: answer.choice, proved: answer.proved == true,
                                                     picks: .init(answer))
        }
        for access in Assistants.shared.requests {
            let key = SyncKit.Record.Key(collection: AssistantApprovalRecords.requestCollection, id: access.id)
            let answerKey = SyncKit.Record.Key(collection: AssistantApprovalRecords.answerCollection, id: access.id)
            guard let original = journal.record(key), let answerRecord = journal.record(answerKey),
                  let writer = answerRecord.stamps["body"]?.device, known.contains(writer),
                  let request = try? AssistantApprovalRecords.Request.read(original, account: client.seal.account, mac: thisDevice),
                  request.session == "access", request.id == access.id, request.assistant == access.assistant,
                  request.tab == access.id, request.permit == access.what,
                  request.issued == access.at.timeIntervalSince1970,
                  request.lines == Self.accessLines(access),
                  let answer = try? AssistantApprovalRecords.Answer.read(answerRecord, request: request, device: writer)
            else { continue }
            Assistants.shared.answer(access, yes: answer.yes)
        }
    }
}

/// A sealed request from another Mac appears as a card while Yab is active,
/// and as a local notification otherwise. The person answers on this Mac,
/// a yes only after Touch ID or the Mac's password.
@MainActor
private final class ForeignAssistantApprovalCard: NSObject, NSWindowDelegate {
    static let shared = ForeignAssistantApprovalCard()
    private var requests: [AssistantApprovalRecords.Request] = []
    private var window: NSWindow?
    private var showing: String?
    private var alerted = Set<String>()
    private var expiryTimer: Timer?

    override init() {
        super.init()
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { Self.shared.show() }
        }
    }

    func update(_ next: [AssistantApprovalRecords.Request]) {
        // Quiet (seen: asked while the person is at its Mac, or opened
        // there): its card here, no notification.
        let current = Set(next.filter { $0.seen == nil }.map(\.id))
        let closed = alerted.subtracting(current)
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: Array(closed))
        alerted.subtract(closed)
        requests = next
        expiryTimer?.invalidate()
        if let first = next.map(\.expires).min() {
            expiryTimer = Timer.scheduledTimer(withTimeInterval: max(1, first - Date().timeIntervalSince1970 + 1), repeats: false) { _ in
                MainActor.assumeIsolated { SyncCenter.shared.takeForeignAssistantApprovals() }
            }
        }
        if let showing, !next.contains(where: { $0.id == showing }) { window?.close(); window = nil; self.showing = nil }
        for request in next where request.seen == nil && alerted.insert(request.id).inserted {
            let content = UNMutableNotificationContent()
            content.title = request.title
            content.body = request.summary
            content.sound = .default
            content.userInfo = ["approval": request.id]
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: request.id, content: content, trigger: nil))
        }
        show()
    }

    private func show() {
        guard NSApp.isActive, window == nil, let request = requests.first else { return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 450, height: 270),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        // Held by `window` here, never let go by AppKit as well when it
        // closes: that extra release freed the card while the run loop's
        // autorelease pool still held it (EXC_BAD_ACCESS in objc_release
        // as the pool drained, as BrowserWindows' window once did).
        window.isReleasedWhenClosed = false
        window.title = "Approval"
        window.opensOnActiveSpace()
        window.delegate = self
        window.center()
        let mac = SyncCenter.shared.devices.first { $0.id == request.mac }?.name ?? "your other Mac"
        window.contentView = WindowHosting.content(ForeignAssistantApprovalView(request: request, mac: mac) { [weak self] yes, choice in
            let send = { (proved: Bool) in
                do { try SyncCenter.shared.answerForeignAssistantApproval(request.id, yes: yes, choice: choice, proved: proved) }
                catch { NSSound.beep() }
                self?.window?.close()
                self?.window = nil
                self?.showing = nil
                SyncCenter.shared.takeForeignAssistantApprovals()
            }
            // A yes is the person's: Touch ID or the password first. A no
            // needs nobody proven.
            guard yes else { send(false); return }
            Self.prove("approve \(request.title)") { ok in if ok { send(true) } }
        })
        self.window = window
        showing = request.id
        window.makeKeyAndOrderFront(nil)
    }

    /// Touch ID or the Mac's password; a test world has nobody to ask.
    static func prove(_ reason: String, _ done: @escaping (Bool) -> Void) {
        if Store.testing { done(true); return }
        let context = LAContext()
        var trouble: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &trouble) else {
            done(trouble?.code == LAError.passcodeNotSet.rawValue)
            return
        }
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { ok, _ in
            DispatchQueue.main.async { done(ok) }
        }
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        showing = nil
    }
}

private struct ForeignAssistantApprovalView: View {
    let request: AssistantApprovalRecords.Request
    let mac: String
    let answer: (Bool, String?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(request.title).font(.headline)
            Text("From \(Brand.name) on \(mac)").font(.caption).foregroundStyle(.secondary)
            ThreadScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(request.lines.indices, id: \.self) { index in Text(request.lines[index]).textSelection(.enabled) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Spacer()
                Button("Don’t Allow") { answer(false, nil) }
                    .buttonStyle(.yab(.secondary, .regular))
                // A sign-in: one button an account, as the Mac's own card.
                if let choices = request.choices {
                    ForEach(choices, id: \.self) { user in
                        Button(choices.count == 1 ? "Sign In as \(user)" : user) { answer(true, user) }
                            .buttonStyle(.yab(.primary, .regular))
                    }
                } else {
                    Button("Approve") { answer(true, nil) }
                        .buttonStyle(.yab(.primary, .regular))
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 450, height: 270)
        .accessibilityIdentifier("assistant.approval")
    }
}
