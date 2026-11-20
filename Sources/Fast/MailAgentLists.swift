import AppKit
import MailCore
import SyncKit

// The agent's mail tools past reading and writing one thread (docs/mail.md,
// Mail for agents): any of mail's lists as the column has them (mail_list),
// a kept draft whole and whether it went (mail_read's `draft`), a mail taken
// back while it waits (mail_send's `undo`), a list left (mail_act's
// `unsubscribe`), a reminder on the person's own mail (mail_act's `remind`),
// and the accounts themselves (mail_accounts). Each does what the page does,
// through the same code, so nothing here is the agent's own way.

extension MailAgent {
    // MARK: - lists

    /// The lists an agent may name, beyond the column's own and the splits:
    /// what each holds, in words for its description.
    static let otherLists: [(id: String, said: String)] = [
        ("kept", "Kept (drafts and sends set for later)"), ("reminders", "Reminders (your mail that comes back if nobody answers)"),
        ("starred", "Starred"), ("sent", "Sent"), ("done", "Done"),
        ("muted", "Muted"), ("spam", "Spam"), ("trash", "Trash"), ("all", "All Mail"), (MailSplits.skipped, "Archived Today"),
    ]

    /// A list as the person or an agent names it: its id ("needs"), its
    /// name ("Needs you", a split's title), or a label's name; nil for none.
    static func listID(_ said: String, labels: [String]) -> String? {
        let words = said.trimmingCharacters(in: .whitespaces)
        let key = words.lowercased()
        guard !key.isEmpty else { return nil }
        if key == "drafts" || key == "scheduled" { return "kept" }
        if key == "snoozed" { return "later" }
        if key == "archive" { return "older" }
        if let base = MailList.base.first(where: { $0.id == key || $0.name.lowercased() == key }) { return base.id }
        if let other = otherLists.first(where: { $0.id == key || $0.said.lowercased().hasPrefix(key) }) { return other.id }
        if let view = MailGo.views.first(where: { $0.key == key || $0.value.lowercased() == key }) { return view.key }
        if let split = MailList.shared.splits.first(where: { $0.on && ($0.id.lowercased() == key || $0.title.lowercased() == key) }) { return split.id }
        let label = key.hasPrefix(MailViews.prefix) ? String(words.dropFirst(MailViews.prefix.count)) : words
        if let name = labels.first(where: { $0.lowercased() == label.lowercased() }) { return MailViews.prefix + name }
        return nil
    }

    /// mail_list: with no list, every account and every list with how many
    /// threads it holds; with one, its threads as the page lists them, a
    /// line each with its id and what its row says (when it comes back or
    /// goes, a reminder).
    static func list(_ center: MailCenter, _ request: [String: Any], now: Date = MailClock.now) -> [String: Any] {
        let said = (request["list"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        let limit = max(1, min((request["limit"] as? Double).map { Int($0) } ?? request["limit"] as? Int ?? 20, 50))
        let account = accountNamed(center, request["account"] as? String)
        if case .failure(let why) = account { return ["error": why.text] }
        let only = (try? account.get()) ?? "all"
        let engines = center.engines.values.filter { only == "all" || $0.account == only }.sorted { $0.account < $1.account }
        let labels = Array(Set(engines.flatMap { labelNames($0.store).values })).sorted()
        guard !said.isEmpty else { return ["text": overview(center, engines: engines, labels: labels)] }
        guard let id = listID(said, labels: labels) else {
            return ["error": "no list \"\(said)\": mail_list with no list names them all"]
        }
        let name = MailList.name(id)
        switch id {
        case "reminders": return ["text": reminders(engines, now: now, limit: limit)]
        case "kept": return ["text": kept(engines, now: now, limit: limit)]
        default: break
        }
        let got = MailDesk.read(split: id, query: "", account: only, limit: limit)
        guard !got.rows.isEmpty else { return ["text": "\(name): nothing."] }
        var lines: [String] = []
        for row in got.rows {
            guard let engine = center.engines[row.account], let thread = engine.store.thread(row.thread) else { continue }
            var line = describe(thread, account: row.account, now: now, labels: labelNames(engine.store))
            if !row.when.isEmpty { line += " · " + row.when }
            if let remind = engine.store.followup(row.thread), remind.fired == nil { line += " · back " + MailFollowups.said(remind.until, now: now) + " if no reply" }
            lines.append(line)
        }
        let more = got.total > lines.count ? "\n\(got.total - lines.count) more; mail_search narrows them." : ""
        return ["text": "\(name) (\(got.total)):\n" + lines.joined(separator: "\n") + more]
    }

    /// Every account and list, with counts: what mail_list can be asked for.
    private static func overview(_ center: MailCenter, engines: [MailCenter.Engine], labels: [String]) -> String {
        let shared = MailList.shared
        var out = "Accounts: " + (engines.isEmpty ? "none" : engines.map(\.account).joined(separator: ", ")) + " (mail_accounts says more)\n\nLists:\n"
        let inbox = MailList.base.map { (id: $0.id, name: $0.name) } + shared.splits.filter(\.on).map { (id: $0.id, name: $0.title) }
        for list in inbox {
            let count = shared.counts[list.id].map { " (\($0))" } ?? ""
            let split = shared.split(list.id).map { " · split, gathers " + MailSplits.gathers($0) } ?? ""
            out += "- \(list.name)\(count)\(split)\n"
        }
        out += "- " + otherLists.map { $0.said }.joined(separator: "\n- ") + "\n"
        if !labels.isEmpty { out += "\nLabels: " + labels.joined(separator: ", ") + "\n" }
        return out + "\nName one as `list` (its name, or a label's)."
    }

    /// Kept: the person's drafts and what is set to go, each with the id
    /// mail_read's `draft`, mail_draft and mail_send take.
    private static func kept(_ engines: [MailCenter.Engine], now: Date, limit: Int) -> String {
        var lines: [(Date, String)] = []
        for engine in engines {
            let store = engine.store
            let going = Dictionary(store.allOps().filter { $0.kind == .send }.map { ($0.thread, $0) }, uniquingKeysWith: { $1 })
            for draft in store.drafts() where !draft.id.hasPrefix("unsubscribe:") {
                let state = going[draft.id].map { " · " + goes($0, now: now) } ?? " · draft"
                let words = draft.body.split(whereSeparator: \.isNewline).first.map { String($0.prefix(80)) } ?? ""
                let place = draft.thread.isEmpty ? "" : " · in thread \(engine.account)|\(draft.thread)"
                lines.append((going[draft.id]?.notBefore ?? .distantPast,
                              "[draft \(engine.account)|\(draft.id)] \(said(draft)) · \(draft.subject.isEmpty ? "(no subject)" : draft.subject) · \(words)\(place)\(state)"))
            }
        }
        guard !lines.isEmpty else { return "Kept: nothing." }
        let sorted = lines.sorted { $0.0 > $1.0 }.prefix(limit).map { $0.1 }
        return "Kept (\(lines.count)):\n" + sorted.joined(separator: "\n") + "\n\nmail_read with draft reads one whole; mail_send undo takes back one that goes."
    }

    /// When a send waiting in the journal goes, in words.
    static func goes(_ op: MailOp, now: Date) -> String {
        let left = op.notBefore.timeIntervalSince(now)
        if left <= 0 { return "going now (Gmail hasn't taken it yet)" }
        if left < 90 { return "sending in \(Int(left.rounded(.up)))s" }
        return "set to go " + MailLater.said(op.notBefore, now: now)
    }

    /// Threads whose mail of the person's comes back if nobody answers.
    private static func reminders(_ engines: [MailCenter.Engine], now: Date, limit: Int) -> String {
        var lines: [(Date, String)] = []
        for engine in engines {
            let names = labelNames(engine.store)
            for followup in engine.store.followups() where followup.fired == nil {
                guard let thread = engine.store.thread(followup.thread) else { continue }
                lines.append((followup.until, describe(thread, account: engine.account, now: now, labels: names)
                    + " · back " + MailFollowups.said(followup.until, now: now) + " if no reply"))
            }
        }
        guard !lines.isEmpty else { return "Reminders: none. mail_act remind sets one on a thread whose last mail is the person's." }
        return "Reminders (\(lines.count)):\n" + lines.sorted { $0.0 < $1.0 }.prefix(limit).map { $0.1 }.joined(separator: "\n")
    }

    /// An account as a request names it, or every one ("all") with none.
    static func accountNamed(_ center: MailCenter, _ said: String?) -> Result<String, AgentCalendar.Failure> {
        let asked = (said ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        guard !asked.isEmpty, asked != "all" else { return .success("all") }
        guard center.engines[asked] != nil else {
            return .failure(AgentCalendar.Failure(text: "no account \(asked) in yab's mail; its accounts: " + center.engines.keys.sorted().joined(separator: ", ")))
        }
        return .success(asked)
    }

    // MARK: - a draft whole

    /// mail_read's `draft`: a kept draft whole (whom, from, subject, files,
    /// its words) and whether it goes; one no longer kept went or was
    /// thrown away, which Sent tells.
    static func draftWhole(_ center: MailCenter, _ given: String, now: Date = MailClock.now) -> [String: Any] {
        guard let hit = kept(center.engines.values, given) else {
            return ["text": "Draft \(given) isn't kept: it went or was thrown away. mail_search in:sent finds what went."]
        }
        let store = hit.engine.store, draft = hit.draft
        let going = store.allOps().filter { $0.kind == .send && $0.thread == draft.id }.max { $0.seq < $1.seq }
        var lines = ["Draft \(hit.engine.account)|\(draft.id)", "State: " + (going.map { goes($0, now: now) } ?? "kept, not set to go")]
        lines.append("From: " + (draft.from.isEmpty ? store.me : draft.from))
        lines.append("To: " + draft.to.map(\.said).joined(separator: ", "))
        if !draft.cc.isEmpty { lines.append("Cc: " + draft.cc.map(\.said).joined(separator: ", ")) }
        if !draft.bcc.isEmpty { lines.append("Bcc: " + draft.bcc.map(\.said).joined(separator: ", ")) }
        lines.append("Subject: " + draft.subject)
        if !draft.thread.isEmpty { lines.append("Thread: \(hit.engine.account)|\(draft.thread)") }
        if !draft.files.isEmpty { lines.append("Files: " + draft.files.map { "\($0.name) (\($0.said))" }.joined(separator: ", ")) }
        if let remind = draft.remind { lines.append("Reminder: back " + MailFollowups.said(remind, now: now) + " if no reply") }
        // The person's own words, or an agent's: data either way.
        return ["text": lines.joined(separator: "\n") + "\n\n" + fenced(draft.body, "draft")]
    }

    // MARK: - taking a send back

    /// mail_send's `undo`: a mail that waits to go (its undo window, or a
    /// send set for later) taken back, as ⌘Z takes one: it stays in Kept as
    /// a draft, by the id the answer gives. One Gmail took already is gone.
    static func takeBack(_ center: MailCenter, _ request: [String: Any], now: Date = MailClock.now) -> [String: Any] {
        let given = (request["draft"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        let key = request["thread"] as? String ?? ""
        let thread = key.split(separator: "|").last.map(String.init) ?? ""
        let forward = request["forward"] as? Bool == true
        let named = (given.isEmpty ? key : given).split(separator: "|", maxSplits: 1).map(String.init)
        let accountAsked = named.count == 2 ? named[0].lowercased() : nil
        guard !given.isEmpty || !thread.isEmpty else { return ["error": "undo needs the thread its reply or forward went in, or the draft"] }
        var found: (engine: MailCenter.Engine, op: MailOp, draft: MailDraft)?
        for engine in center.engines.values where accountAsked == nil || engine.account.lowercased() == accountAsked {
            for op in engine.store.allOps() where op.kind == .send {
                guard let draft = engine.store.draft(op.thread) else { continue }
                let fits: Bool
                if !given.isEmpty {
                    fits = draft.id == (named.last ?? given)
                } else if forward {
                    fits = draft.thread == thread && draft.id.hasPrefix("forward:")
                } else {
                    // A reply in it, or an answer to its invitation.
                    let answering = engine.store.rsvp(draft: draft.id).flatMap { engine.store.message($0.message) }?.thread
                    fits = draft.thread == thread && draft.id.hasPrefix("reply:") || answering == thread
                }
                if fits, found.map({ $0.op.seq < op.seq }) ?? true { found = (engine, op, draft) }
            }
        }
        guard let found else {
            return ["error": "nothing of that waits to go: it went already (Gmail has it, past taking back), or never was sent"]
        }
        let store = found.engine.store
        guard center.undo(found.op.seq, account: found.engine.account) else {
            return ["error": "it went already: Gmail has it, past taking back"]
        }
        // An answer to an invitation: gone with its card's record, as the
        // page's ⌘Z takes one back; the card asks again.
        if store.rsvp(draft: found.draft.id) != nil {
            store.dropRSVP(draft: found.draft.id)
            store.dropDraft(found.draft.id)
            return ["text": "Took back the answer to the invitation in thread \(found.engine.account)|\(found.draft.thread): nothing went."]
        }
        if !found.draft.thread.isEmpty { MailList.shared.agentDid(account: found.engine.account, thread: found.draft.thread) }
        let what = found.op.notBefore.timeIntervalSince(now) > MailCenter.undoSend + 1 ? "a send set for later" : "the mail"
        return ["text": "Took back \(what) to \(found.draft.to.map(\.said).joined(separator: ", ")): nothing went. It is kept as draft \(found.engine.account)|\(found.draft.id) in the mail page's Kept; mail_draft changes it, mail_send sends it again.",
                "draft": found.engine.account + "|" + found.draft.id]
    }

    // MARK: - leaving a list

    /// mail_act's `unsubscribe`: off the thread's mailing list by its first
    /// way that works, as ⌘U leaves one (one click, else a mail to its
    /// address through the send path, else its page, which the agent may
    /// open to finish), and the thread out of the inbox.
    static func unsubscribe(_ center: MailCenter, _ request: [String: Any]) async -> [String: Any] {
        let key = request["thread"] as? String ?? ""
        let thread = key.split(separator: "|").last.map(String.init) ?? ""
        guard let engine = MailAgent.engine(holding: key, in: center.engines.values)?.engine else { return ["error": "no thread \(thread)"] }
        let store = engine.store
        var messages = store.messages(thread: thread)
        if messages.contains(where: { $0.listUnsubscribe && $0.unsubscribe == nil }) {
            try? await engine.sync.open(thread: thread)
            messages = store.messages(thread: thread)
        }
        guard let found = MailUnsubscribe.all(messages, me: store.me) else {
            return ["error": "thread \(thread) isn't from a mailing list that names a way out (no List-Unsubscribe); block the sender or archive it instead, as the user wants"]
        }
        var gone: MailUnsubscribe.Way?
        var page: URL?
        for way in found.ways {
            switch way {
            case .oneClick(let url): if await MailUnsubscribe.post(url) { gone = way }
            case .mail(let mail): if MailDesk.mailOut(mail, account: engine.account) { gone = way }
            case .page(let url):
                page = url
                gone = way
            }
            if gone != nil { break }
        }
        guard let gone else { return ["error": "couldn't unsubscribe from \(found.sender.said): its list didn't take it"] }
        store.unsubscribed(found.sender.address, how: gone.name)
        // Done, as ⌘U leaves its threads.
        if store.thread(thread)?.labels.contains("INBOX") == true {
            _ = MailOps.done([thread], in: store)
            center.acted(engine.account, after: 0)
        }
        MailList.shared.settled(account: engine.account, thread: thread)
        if gone.isPage, let page {
            return ["text": "\(found.sender.said) is left only on its own page: \(page.absoluteString). Open it in a tab of yours and finish there (its Unsubscribe or Confirm); the thread is archived.",
                    "page": page.absoluteString]
        }
        let rest = store.threads(with: found.sender.address, limit: 200)
            .filter { $0.id != thread && $0.labels.contains("INBOX") && $0.people.contains { $0.address.lowercased() == found.sender.address.lowercased() } }.count
        let more = rest > 0 ? " \(rest) more of their threads are in the inbox: mail_search from:\(found.sender.address) finds them to archive or trash, if the user wants." : ""
        return ["text": "Unsubscribed from \(found.sender.said)\(gone.name == "mail" ? " by mail" : ""), and archived the thread.\(more)"]
    }

    // MARK: - reminders

    /// mail_act's `remind`: the thread comes back if nobody answers the
    /// person's own last mail in it, as ⇧⌘H on a thread waited on sets it.
    static func remind(_ center: MailCenter, engine: MailCenter.Engine, thread: String, until said: Any?) -> [String: Any] {
        let store = engine.store
        guard let mine = MailFollowups.last(mineIn: thread, in: store) else {
            return ["error": "the last mail in thread \(thread) isn't the person's: a reminder brings back their own mail nobody answered. For a reply not sent yet, mail_draft's remind_in"]
        }
        guard let until = MailFollowups.remindIn(said ?? "3") else {
            return ["error": "until is days (\"3\") or words (\"in 3 days\", \"friday 10am\"), ahead of now"]
        }
        store.follow(MailFollowup(thread: thread, message: mine.rfcID, until: until, sent: mine.date))
        center.touch()
        // Its card in the chat says the promise, whose answer it waits on.
        let card = ResultCard(kind: .promise, title: mine.to.first.map(firstName) ?? "", at: until.timeIntervalSince1970,
                              ref: engine.account + "|" + thread)
        return ["text": "Back \(MailFollowups.said(until)) if nobody answers: \(engine.account)|\(thread).\n" + card.line]
    }

    /// "Tim" of Tim Cook, or the address's name before the @.
    static func firstName(_ person: MailPerson) -> String {
        let name = person.name.trimmingCharacters(in: .whitespaces)
        if let first = name.split(separator: " ").first { return String(first) }
        return String(person.address.split(separator: "@").first ?? "")
    }

    static func unremind(_ center: MailCenter, engine: MailCenter.Engine, thread: String) -> [String: Any] {
        guard engine.store.followup(thread) != nil else { return ["text": "No reminder on \(engine.account)|\(thread)."] }
        engine.store.unfollow(thread)
        center.touch()
        return ["text": "No reminder on \(engine.account)|\(thread) now."]
    }

    // MARK: - accounts

    /// mail_accounts: the accounts in Yab's mail (provider, how its sync
    /// is, the addresses it sends as), or one added: Gmail (Google Workspace
    /// too) by Google's own sign-in in another browser, where the person
    /// chooses and allows, as an agent never drives its own consent page;
    /// another provider by the agent way Settings › Mail's Set It Up hands
    /// out, the password kept by Yab, never seen by the agent.
    static func accounts(_ center: MailCenter, _ request: [String: Any], session: String?, browser: Browser) async -> [String: Any] {
        let act = (request["act"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "list"
        guard act == "add" else {
            guard act == "list" else { return ["error": "do is list or add"] }
            return ["text": accountsSaid(center)]
        }
        let address = (request["address"] as? String ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        guard MailDesk.address(address) else { return ["error": "add needs the address to connect, as the user said it"] }
        if center.accounts.contains(address), center.status[address]?.signedOut != true {
            return ["text": "\(address) is in \(Brand.name)'s mail already."]
        }
        let found: MailFinding.Found = center.accounts.contains(address) && MailCenter.kind(of: address) == .gmail
            ? .gmail : await MailFinding.find(address)
        switch found {
        case .gmail:
            if let problem = center.gmailConnectionProblem(expectedAccount: address) { return ["error": problem] }
            guard MailClient.configured != nil else { return ["error": "this build of \(Brand.name) has no Google client for Mail"] }
            guard !center.connecting else { return ["error": "another Gmail connection is under way: the person finishes or closes it first"] }
            browser.prefs.usesMail = true
            guard center.connect(in: browser, hint: address, outside: true, expectedAccount: address) else {
                return ["error": "Gmail wasn’t connected"]
            }
            return ["text": "Google's sign-in opened in the person's other browser for \(address): they choose the account and allow \(Brand.name) there (you can't, and never type their password). It is in once they have; mail_accounts says so, and its mail keeps coming in after. Tell them in a line."]
        case .microsoft:
            return ["error": "Outlook and other Microsoft accounts can't be added to \(Brand.name) yet; say so"]
        case .none:
            return ["error": "\(address) isn't an address mail can be set up for"]
        case .imap(let setup, let provider):
            guard provider?.id == "gmail" || MailExperiment.otherAccounts() else {
                return ["error": "Mail is off: the person turns on Settings › Experimental › Mail, then ask again"]
            }
            if let provider, MailSetup.available(provider), let session {
                guard MailSetup.shared.adopt(setup, provider: provider, session: session) else {
                    return ["error": "another mail setup is under way; finish or stop it first"]
                }
                return ["text": MailSetup.words(address, provider: provider, asked: true)]
            }
            await MainActor.run { SettingsWindow.shared.show(.mail, for: browser) }
            let page = provider.map { $0.appPasswordPage.isEmpty ? "" : " Its app passwords are made at \($0.appPasswordPage)." } ?? ""
            return ["text": "\(address) (\(provider?.name ?? setup.imapHost)) takes a password only the person types: Settings › Mail is open; they choose Add Account, then the provider, and put an app password in \(Brand.name)'s own field.\(page) Never ask for it in the chat."]
        }
    }

    /// Every account, a line each: provider, sync, what it sends as.
    static func accountsSaid(_ center: MailCenter, now: Date = Date()) -> String {
        let accounts = center.accounts.sorted()
        guard !accounts.isEmpty else {
            return "No mail account in \(Brand.name) yet. mail_accounts add connects one the user names (Gmail and Google Workspace with an app password; iCloud, Zoho, Yahoo, Fastmail and other IMAP accounts while Settings › Experimental › Mail is on)."
        }
        let lines = accounts.map { account -> String in
            let kind = MailCenter.kind(of: account) == .gmail ? "Gmail" : MailServerSetup.kept(account, in: Store.settings).flatMap { MailKnownProviders.by(id: $0.provider)?.name } ?? "IMAP"
            var line = "\(account) · \(kind)"
            let status = center.status[account]
            if status?.signedOut == true { line += " · signed out: mail_accounts add \(account) signs in again" }
            else if let trouble = status?.trouble { line += " · trouble: " + trouble }
            else if status?.syncing == true { line += " · syncing" }
            else if let synced = status?.synced { line += " · synced \(max(0, Int(now.timeIntervalSince(synced) / 60)))m ago" }
            if let store = center.engines[account]?.store {
                let others = store.sendAs().filter { !$0.primary }.map { $0.address + ($0.isDefault ? " (default)" : "") }
                if !others.isEmpty { line += " · also sends as " + others.joined(separator: ", ") }
            }
            return line
        }
        return lines.joined(separator: "\n")
    }
}
