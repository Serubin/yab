import AppKit
import SwiftUI

// Mail in yab's own field, never a menu of its own (docs/mail.md, The mail
// space): ⌘K in mail is the field in its Mail place, the chosen
// thread's actions first (or, with rows picked, what is done to all of
// them), then threads that answer the words, then where to go. Remind Me
// keeps the field and replaces its rows with times; so do Send Later and
// Remind Me If No Reply (⇧⌘H, a mail that comes back unanswered). New
// Split's rows are who you write with most, or the words typed, kept as a
// split; Rewrite's (⌘J in a reply) how to write it again; ?'s every key mail
// takes, as Settings › Shortcuts says them. Get Me To Zero's rows are how old
// and what to leave; Bulk Actions' what was done to many threads this week,
// to take back; after ⌘U or Block Sender, the rest of their mail, to clear;
// ⇧⌘F's the addresses a draft can go from; ⌘; in a draft, the snippets to
// put in it, by their names (MailSnippets); Save as Snippet, the name to
// keep a mail's words or the draft's under. Typed from anywhere, "mail"
// and Tab is the same place, to find a thread without the page in front.
// Summarize, with rows picked or a long thread open, asks Claude in the
// chat column, as ⌘J's line does.

/// What the Mail place is open over: the page's chosen thread, and which
/// of its lists the rows are.
struct MailFieldContext: Equatable {
    enum Mode: Equatable { case commands, remind, send, list, rewrite, page, keys, followup, zero, bulk, sender, label, move, goLabel, from, snippets, saveSnippet, slots, splitTo, splitRule, library }
    var mode: Mode = .commands
    var account = ""
    var thread = ""
    var subject = ""
    /// Rows picked in the list (MailDesk.selection), when more than one:
    /// the commands are for all of them.
    var picked = 0
    /// A reminder if nobody answers is set on what it is open over (the
    /// draft, or the thread's mail): its times begin with Don't Remind Me.
    var reminding = false
    /// "list", "thread" or "compose": what the page shows.
    var view = "list"
    var tab: Tab.ID?
    /// Times reached from the commands: ⌫ or Escape goes back to them.
    var stepped = false
    /// A split of yours being added to (a rule, a page), by its id; in
    /// Add to Split, the one chosen (nil: New Split from This Mail).
    var editing: String?
    /// The split Claude made of the words, to keep or not.
    var proposal: MailList.Split?
    /// Claude is making it.
    var thinking = false
    /// Whose mail the rest is, after ⌘U or Block Sender (`sender`): their
    /// address and name, and Trash first, for a sender blocked.
    var sender = ""
    var senderName = ""
    var trashFirst = false
    /// L and V (MailLabels): the accounts of what it is open over, whose
    /// labels it offers; the labels all of it carries, by name, ticked;
    /// and the label of the list in front, which V moves out of.
    var accounts: [String] = []
    var applied: Set<String> = []
    var here = ""
    /// Free slots picked (⇧⌘A), by when each begins; the suggested ones
    /// put in once the calendar was read (`seeded`).
    var slots: [Double] = []
    var seeded = false
}

/// A row of the Mail place.
enum MailRow {
    case command(id: String, title: String)
    case time(label: String, detail: String, at: Double)
    /// H on a thread you wrote last in: the time, only if nobody answers.
    case noReply(at: Double)
    case thread(account: String, id: String)
    case list(title: String, q: String)
    case rewrite(how: String)
    /// Ask Claude to make a list of these words.
    case ask(words: String)
    /// Claude's list, to keep.
    case proposal
    /// A rule for the list being added to.
    case rule(MailRule)
    /// A page kept with the list being added to.
    case page(url: String, title: String)
    /// Add to Split: a split to add to, by its id; then what of the
    /// thread goes into it, or makes a new one, said by `name`.
    case split(id: String)
    case fromMail(rule: MailRule, name: String)
    /// New Split's: "build", "describe", or a ready split by its id
    /// (MailSplitLibrary).
    case library(id: String)
    /// Said, not done: Claude is reading.
    case note
    /// A key of mail's, as ? lists them: its Settings › Shortcuts row.
    case key(id: String)
    /// Get Me To Zero, this old; and what it leaves, turned with ↩.
    case zero(MailZero.Age)
    case leave(String)
    /// A Bulk Actions entry, to take back: one act's, by account.
    case bulk([String: Int64])
    /// The rest of a sender's mail, done or into Trash.
    case sweep(trash: Bool)
    /// A label of the person's, by its name (L, V, G then L); one to make.
    case label(name: String)
    case newLabel(name: String)
    /// An address the draft can go from (⇧⌘F).
    case from(address: String)
    /// A snippet, to put into the draft (⌘;).
    case snippet(id: String)
    /// The words in front kept as a snippet of this name.
    case saveSnippet(name: String)
    /// A free slot, by when it begins, picked or left out with ↩; and the
    /// words of those picked, to put into the draft.
    case slot(at: Double)
    case slots(text: String)
    /// An account, "all" for every one: its mail in the column, as the
    /// chooser picks it.
    case account(String)

    /// Its end is keys pressed, a plate each: a command's, a key's.
    var keyed: Bool {
        switch self {
        case .command, .key: return true
        default: return false
        }
    }
}

extension Browser {
    /// The field in its Mail place, over the mail page's thread or list.
    func openMailField(_ context: MailFieldContext) {
        openPlace(.mail)
        query.stock.mail = context
        query.stock.version += 1
        replaceTyped("")
    }

    /// The rows of the Mail place as the field's own rows, ⌘J's kind: a
    /// mark, the words, a key or a time at the end. What each is kept by
    /// its id for the row's end and for ↩. A quiet one is shown, dimmed,
    /// but never chosen: nothing to do there (Get Me To Zero's age with no
    /// thread in it, a sender with no more mail).
    @MainActor static var mailRows: [String: (row: MailRow, section: String, end: String, symbol: String, quiet: Bool)] = [:]

    func mailSuggestions() -> [Suggestion] {
        var out: [Suggestion] = []
        var rows: [String: (row: MailRow, section: String, end: String, symbol: String, quiet: Bool)] = [:]
        func add(_ id: String, _ title: String, _ detail: String, _ row: MailRow, section: String, end: String, symbol: String,
                 quiet: Bool = false) {
            rows[id] = (row, section, end, symbol, quiet)
            out.append(Suggestion(key: title, title: detail, url: nil, kind: .page("mail:" + id)))
        }
        let context = query.stock.mail ?? MailFieldContext()
        let words = typed.trimmingCharacters(in: .whitespaces)
        let lower = words.lowercased()
        let threads = { (n: Int) in n == 1 ? "1 thread" : "\(n.formatted()) threads" }
        switch context.mode {
        case .remind, .send, .followup:
            let choices: [MailLater.Choice]
            if context.mode == .send {
                choices = MailLater.sends()
            } else if context.mode == .followup {
                choices = MailLater.followups()
            } else {
                let person = MailCenter.shared.engines[context.account]?.store.thread(context.thread)?.people.first
                choices = MailLater.snoozes(for: person, meetings: Meetings.shared.allowed ? Meetings.shared.list : [])
            }
            let section = context.mode == .send ? "Send" : context.mode == .followup ? "Remind Me If No Reply" : "Remind Me"
            // What was typed, as soon as it reads as a time, said as the
            // time it is: first, for ↩. A place named, its clock, and this
            // Mac's under it.
            var first: (label: String, detail: String, at: Date)?
            if !words.isEmpty, let typed = MailLater.typed(words, now: MailClock.now) {
                let said = MailLater.said(typed)
                add("time.typed", said.title, said.here ?? "", .time(label: said.title, detail: "", at: typed.at.timeIntervalSince1970),
                    section: section, end: "", symbol: "clock")
                first = (said.title, "", typed.at)
            }
            // One set already: taken off first, as the field's way to say none.
            if context.mode == .followup, context.reminding, lower.isEmpty || "don't remind me".contains(lower) {
                add("time.none", "Don\u{2019}t Remind Me", "", .time(label: "", detail: "", at: -1), section: section, end: "",
                    symbol: "clock.badge.xmark")
            }
            for (n, choice) in choices.enumerated() where lower.isEmpty || choice.label.lowercased().contains(lower) {
                add("time.\(n)", choice.label, "", .time(label: choice.label, detail: choice.detail, at: choice.at?.timeIntervalSince1970 ?? 0),
                    section: section, end: choice.detail, symbol: choice.reply ? "arrow.uturn.backward" : "clock")
                if first == nil, let at = choice.at { first = (choice.label, choice.detail, at) }
            }
            // H on a thread you wrote last in: the time ↩ takes, as ⇧⌘H's,
            // back only if nobody answers by then.
            if context.mode == .remind, !context.thread.isEmpty, context.picked < 2, let first,
               MailDesk.shared.remindable(MailDesk.shared.chosen) {
                add("time.noreply", first.label, "", .noReply(at: first.at.timeIntervalSince1970), section: "Only If Nobody Answers",
                    end: first.detail, symbol: "bell")
            }
        case .list:
            let desk = MailDesk.shared
            let editing = context.editing.flatMap { id in MailList.shared.splits.first { $0.id == id } }
            let section = editing.map { "Add to " + $0.title } ?? "New Split"
            // What it would gather of the inbox now.
            let count = { (q: String) -> Int in MailDesk.ruleCount(q) }
            let threads = { (n: Int) in n == 1 ? "1 thread" : "\(n) threads" }
            if context.thinking {
                add("list.thinking", "\(PlanText.writer) is reading it…", "", .note, section: section, end: "", symbol: "agent.face")
            }
            // Claude's list: its title, its rules, what it gathers.
            if let made = context.proposal, editing == nil {
                let said = made.rules.map { $0.said.kind + " " + $0.said.value }.joined(separator: " · ")
                add("list.proposal", made.title, said, .proposal, section: "\(PlanText.writer)\u{2019}s Split", end: threads(count(made.q)),
                    symbol: made.icon ?? "sparkles")
            }
            if !words.isEmpty {
                if editing == nil, PlanText.any {
                    add("list.ask", "Ask \(PlanText.writer): \u{201C}\(words)\u{201D}", "", .ask(words: words), section: section, end: "", symbol: "agent.face")
                    let line = MailDesk.splitLine(words)
                    add("list.typed", "Keep \u{201C}\(words)\u{201D} as a split", "", .list(title: words, q: line),
                        section: section, end: threads(count(line)), symbol: "plus")
                } else {
                    add("list.words", "Words \u{201C}\(words)\u{201D}", "", .rule(MailRule(kind: "words", value: words)),
                        section: section, end: "", symbol: "magnifyingglass")
                }
                // A domain typed as it is: everything from it.
                if !words.contains(" "), words.contains("."), !words.contains("@") {
                    let rule = MailRule(kind: "from", value: lower)
                    add("list.domain", "From " + lower, "", editing == nil ? .list(title: lower, q: MailRule.line([rule])) : .rule(rule),
                        section: section, end: threads(count(MailRule.line([rule]))), symbol: "globe")
                }
            }
            // The people you write with most, or those the words name.
            let taken = Set(editing?.rules.map(\.value) ?? [])
            let people = words.isEmpty ? desk.topContacts(4, leaving: taken) : desk.people(matching: words, limit: 4, leaving: taken)
            for contact in people {
                let rule = MailRule(kind: "with", value: contact.address)
                add("list.\(contact.address)", contact.said, contact.name.isEmpty ? "" : contact.address,
                    editing == nil ? .list(title: contact.said, q: MailRule.line([rule])) : .rule(rule),
                    section: words.isEmpty ? "Suggested" : "People", end: threads(contact.threads), symbol: "person")
            }
        case .library:
            // New Split as Passwords and History are: these rows, the chosen
            // one beside them (MailLibraryPreview). Your own first, then
            // the splits mail has ready, with what each holds now.
            let library = MailSplitLibrary.shared
            var made: [(String, String, String)] = [("build", "Build Your Own", "plus")]
            if MailCenter.agentsAllowed, PlanText.any { made.append(("describe", "Describe to \(PlanText.writer)", "sparkles")) }
            for (id, title, symbol) in made where lower.isEmpty || title.lowercased().contains(lower) {
                add("library." + id, title, "", .library(id: id), section: "New Split", end: "", symbol: symbol)
            }
            for card in MailSplitLibrary.cards where lower.isEmpty || card.title.lowercased().contains(lower) {
                let n = library.previews[card.id]?.count
                let end = library.added(card) ? "Added" : n.map { $0 == 0 ? "" : threads($0) } ?? ""
                add("library." + card.id, card.title, "", .library(id: card.id), section: "Ready Splits", end: end, symbol: card.icon)
            }
        case .splitTo:
            // Your own splits first, in the column's order; then VIP, which
            // Add turns on, and the built-in ones that are on.
            let list = MailList.shared
            let ordered = list.ordered.filter { !$0.builtIn } + list.ordered.filter { $0.id == "vip" }
                + list.ordered.filter { $0.builtIn && $0.id != "vip" && $0.on }
            // Only those the thread can add to: a split asks all of its kinds
            // and words, so a person widens one of people, or one with none.
            let offered = MailDesk.fromMail(account: context.account, thread: context.thread).map(\.rule)
            for one in ordered where (one.on || one.id == "vip") && (lower.isEmpty || one.title.lowercased().contains(lower))
                && offered.contains(where: { MailDesk.widens(one, with: $0) }) {
                let n = one.on ? list.counts[one.id] ?? 0 : 0
                add("split." + one.id, one.title, one.rules.isEmpty ? "nobody yet" : MailSplits.gathers(one), .split(id: one.id),
                    section: "Add to Split", end: n > 0 ? threads(n) : "", symbol: one.icon ?? "magnifyingglass")
            }
        case .splitRule:
            // What of the thread: who wrote it, everyone at their domain, its
            // subject; with what each brings the split, or would gather.
            let editing = context.editing.flatMap { id in MailList.shared.splits.first { $0.id == id } }
            let section = editing.map { "Add to " + $0.title } ?? "New Split from This Mail"
            let choices = MailDesk.fromMail(account: context.account, thread: context.thread).filter { choice in
                editing.map { MailDesk.widens($0, with: choice.rule) } ?? true
            }
            let base = editing?.q ?? ""
            let lines = choices.map { MailRule.line((editing?.rules ?? []) + [$0.rule]) }
            let account = MailList.shared.account
            let counts = MailFilterCounts.shared
            counts.ask(lines, base: base, account: account)
            for (n, choice) in choices.enumerated() where lower.isEmpty || choice.title.lowercased().contains(lower) {
                let count = counts.count(lines[n], base: base, account: account)
                let end = count.map { editing == nil ? threads($0.all) : $0.added > 0 ? "+" + threads($0.added) : "" } ?? ""
                add("rule." + choice.rule.kind + "." + choice.rule.value, choice.title, choice.detail, .fromMail(rule: choice.rule, name: choice.name),
                    section: section, end: end, symbol: choice.symbol)
            }
        case .page:
            // Pages to keep with the split: what is open, in any space.
            let open = (tabs + parkedTabs).filter { tab in
                guard let url = tab.address, ["http", "https"].contains(url.scheme ?? ""), !MailPage.isMail(url) else { return false }
                return lower.isEmpty || tab.title.lowercased().contains(lower) || url.absoluteString.lowercased().contains(lower)
            }
            var seen = Set<String>()
            for tab in open.prefix(24) {
                guard let url = tab.address?.absoluteString, seen.insert(url).inserted else { continue }
                add("page.\(url)", tab.title.isEmpty ? url : tab.title, Address.pretty(tab.address!), .page(url: url, title: tab.title.isEmpty ? url : tab.title),
                    section: "Keep with the Split", end: "", symbol: "globe")
            }
        case .label, .move, .goLabel:
            // The labels of the accounts it is open over, as Gmail sorts
            // them, those the words are in; L ticks what all of it carries.
            let labels = MailLabels.shared
            // An IMAP account files mail in folders: a label put on is a move
            // there (docs/mail-providers.md, M1), and the list says so.
            let folders = !context.accounts.isEmpty && context.accounts.allSatisfy { MailCenter.kind(of: $0) == .imap }
            let section = context.mode == .goLabel ? (folders ? "Go to a Folder" : "Go to a Label") : context.mode == .move || folders ? "Move To"
                : context.picked > 1 ? "Label \(context.picked) Selected" : "Label"
            let names = labels.names(accounts: context.accounts)
            for name in names where (lower.isEmpty || name.lowercased().contains(lower)) && !(context.mode == .move && name == context.here) {
                let on = context.mode == .label && context.applied.contains(name)
                let unread = context.mode == .goLabel ? labels.unread(name) : 0
                add("label." + name, name, "", .label(name: name), section: section, end: unread > 0 ? "\(unread) unread" : "",
                    symbol: on ? "checkmark" : "tag")
            }
            // Words that name no label: one made of them, after those they are in.
            if context.mode != .goLabel, !words.isEmpty, !names.contains(where: { $0.lowercased() == lower }) {
                add("label.new", "Create \u{201C}\(words)\u{201D}", "", .newLabel(name: words), section: section, end: "", symbol: "plus")
            }
        case .rewrite:
            if !words.isEmpty {
                add("rewrite.typed", words.prefix(1).uppercased() + words.dropFirst(), "", .rewrite(how: words),
                    section: "Rewrite", end: "", symbol: "agent.face")
            }
            for (n, how) in ["Shorter", "Warmer", "More Formal", "Fix Spelling and Grammar"].enumerated()
            where lower.isEmpty || how.lowercased().contains(lower) {
                add("rewrite.\(n)", how, "", .rewrite(how: how.lowercased()), section: "Rewrite", end: "", symbol: "agent.face")
            }
        case .commands:
            let key = { (action: Shortcut.Action) in Keymap.shared.text(action) }
            var commands: [(String, String, String, String)] = []
            // Y: in a label's list, its label off what it is open over.
            let unlabel: [(String, String, String, String)] = MailViews.label(MailList.shared.split).map {
                [("unlabel", "Remove \u{201C}\($0)\u{201D}", key(.mailUnlabel), "tag")]
            } ?? []
            // Who wrote it into VIP, or out of it when all of them are in it.
            let inVIP = MailDesk.inVIP(MailDesk.shared.targets)
            let vip = ("vip", inVIP ? (context.picked > 1 ? "Remove Senders from VIP" : "Remove Sender from VIP")
                                    : (context.picked > 1 ? "Add Senders to VIP" : "Add to VIP"), key(.mailVIP), "star")
            let drafts = MailDesk.shared.keptTargets.count
            if drafts > 0, MailDesk.shared.targets.isEmpty {
                // Kept's drafts alone: nothing a thread's commands could do to them.
                commands += [("trash", drafts > 1 ? "Delete \(drafts) Drafts" : "Delete Draft", key(.mailTrash), "trash")]
                    + (context.picked > 1 ? [("unselect", "Let the Selection Go", "esc", "xmark")] : [])
            } else if context.picked > 1 {
                // Rows picked: what is done to all of them at once.
                commands += [("done", "Mark Done", key(.mailDone), "yab.check"),
                             ("remind", "Remind Me", key(.mailRemind), "yab.clock"),
                             ("star", "Star", key(.mailStar), "yab.star"),
                             ("trash", "Move to Trash", key(.mailTrash), "trash"),
                             ("spam", "Mark as Spam", key(.mailSpam), "exclamationmark.shield"),
                             ("mute", "Mute", key(.mailMute), "yab.bell.slash"),
                             ("unsubscribe", "Unsubscribe", key(.mailUnsubscribe), "yab.mail.minus"),
                             ("block", "Block Senders", key(.mailBlock), "yab.person.x"),
                             ("label", "Label\u{2026}", key(.mailLabel), "yab.label"),
                             ("move", "Move To\u{2026}", key(.mailMove), "yab.folder.right")]
                    + unlabel
                    + [vip]
                    + [("unread", "Mark Unread", key(.mailUnread), "yab.mail.dot"),
                       ("notdone", "Mark Not Done", key(.mailNotDone), "yab.inbox.left")]
                    // Claude reads them all and says them in the column.
                    + (MailCenter.agentsAllowed && Agents.ready ? [("summarize", "Summarize", key(.mailSummarize), "yab.doc.spark")] : [])
                    + [("unselect", "Let the Selection Go", "esc", "xmark")]
            } else if !context.thread.isEmpty, context.view != "compose" {
                let store = MailCenter.shared.engines[context.account]?.store
                let thread = store?.thread(context.thread)
                let writer = store.flatMap { MailDesk.writer(of: context.thread, in: $0) }
                let labels = thread?.labels ?? []
                // An invitation over the thread: its answers first (MailCalendar).
                if context.view == "thread", MailDesk.shared.answerable != nil {
                    commands += [("accept", "Accept Invitation", key(.mailAccept), "yab.calendar.check"),
                                 ("maybe", "Answer Maybe", key(.mailMaybe), "yab.calendar.question"),
                                 ("decline", "Decline Invitation", key(.mailDecline), "yab.calendar.x")]
                }
                commands += [("done", "Mark Done", key(.mailDone), "yab.check"),
                             ("remind", "Remind Me", key(.mailRemind), "yab.clock"),
                             ("reply", "Reply", key(.mailReply), "yab.reply"),
                             ("replyall", "Reply All", key(.mailReplyAll), "yab.replyall"),
                             ("forward", "Forward", key(.mailForwardMail), "yab.fwdmail"),
                             ("keep", "Keep", key(.mailKeep), "bookmark")]
                    + (MailCenter.agentsAllowed && Agents.ready ? [("doit", "Do It", key(.mailDoIt), "agent.face")] : [])
                    // A long thread open, as the line under ⌘J offers it.
                    + (MailCenter.agentsAllowed && Agents.ready && context.view == "thread" && MailDesk.shared.messages.count >= 3
                       ? [("summarize", "Summarize", key(.mailSummarize), "yab.doc.spark")] : [])
                    + [("unread", "Mark Unread", key(.mailUnread), "yab.mail.dot"),
                       ("star", labels.contains("STARRED") ? "Unstar" : "Star", key(.mailStar), "yab.star"),
                       ("trash", labels.contains("TRASH") ? "Move Out of Trash" : "Move to Trash", key(.mailTrash), "trash"),
                       ("spam", labels.contains("SPAM") ? "Not Spam" : "Mark as Spam", key(.mailSpam), "exclamationmark.shield"),
                       ("mute", thread?.muted == true ? "Unmute" : "Mute", key(.mailMute), thread?.muted == true ? "speaker.wave.2" : "yab.bell.slash"),
                       ("label", "Label\u{2026}", key(.mailLabel), "yab.label"),
                       ("move", "Move To\u{2026}", key(.mailMove), "yab.folder.right")]
                    + unlabel
                    + [vip]
                    // Who wrote it, their domain or its subject, into a split (MailFilters).
                    + [("addsplit", "Add to Split\u{2026}", "", "yab.inbox.right"),
                       ("splitfrom", "New Split from This Mail\u{2026}", "", "yab.inbox.plus")]
                    + (thread.map { !$0.labels.contains("INBOX") } == true
                       ? [("notdone", "Mark Not Done", key(.mailNotDone), "yab.inbox.left")] : [])
                    // A list's mail leaves the list; whoever wrote is kept out, the
                    // address, or everyone at a domain that isn't everyone's.
                    + (thread?.bulk == true ? [("unsubscribe", "Unsubscribe", key(.mailUnsubscribe), "yab.mail.minus")] : [])
                    + (writer.map { [("block", "Block " + $0.address, key(.mailBlock), "yab.person.x")] } ?? [])
                    + (writer.flatMap { MailBlock.domain(of: $0.address, me: store?.me ?? "") }
                        .map { [("blockdomain", "Block Everyone at " + $0, "", "yab.globe.x")] } ?? [])
                    // Its words kept to write again (MailSnippets).
                    + [("savesnippet", "Save as Snippet", "", "yab.doc.plus")]
                // A thread open: its files and links; a chip chosen, what its keys do.
                if context.view == "thread" {
                    if let chip = MailDesk.shared.chip,
                       let file = MailDesk.shared.messages.first(where: { $0.id == chip.message })?.files.first(where: { $0.part == chip.part }) {
                        commands += [("lookfile", "Quick Look \u{201C}\(file.name)\u{201D}", "Space", "eye"),
                                     ("openinapp", "Open \u{201C}\(file.name)\u{201D}", "↩", "yab.doc.right"),
                                     ("savefile", "Save \u{201C}\(file.name)\u{201D} to Downloads", key(.mailSaveFile), "yab.doc.dl")]
                    }
                    commands.append(("openfile", "Open the First Attachment or Link", key(.mailOpenFile), "yab.clip"))
                    // A date in its words: an event of it (MailEvents).
                    if MailEvents.shared.first(in: MailDesk.shared.messages) != nil {
                        commands.append(("newevent", "New Event", "", "yab.calendar.plus"))
                    }
                }
            }
            if context.view == "compose" {
                commands += [("send", "Send", key(.mailSend), "yab.send"),
                             ("sendlater", "Send Later", key(.mailSendLater), "yab.send.clock"),
                             ("followup", "Remind Me If No Reply", key(.mailRemindNoReply), "bell"),
                             ("bcc", "Add Bcc", key(.mailBcc), "yab.person.plus"),
                             ("subject", "Change Subject", key(.mailSubject), "character.cursor.ibeam"),
                             ("attach", "Attach Files", key(.mailAttach), "yab.clip"),
                             ("snippet", "Insert Snippet", key(.mailSnippet), "yab.doc.right"),
                             ("slots", "Insert Free Slots", key(.mailSlots), "yab.calendar.right"),
                             ("savesnippet", "Save as Snippet", "", "yab.doc.plus")]
                // The address it goes from, when there is another to choose; its signature on or off.
                if MailDesk.shared.senders.count > 1 { commands.append(("from", "Change From Address", key(.mailFrom), "yab.at")) }
                if let signature = MailDesk.shared.signatureCommand { commands.append(("signature", signature, "", "signature")) }
                // The words' marks, on what is chosen in them.
                commands += MailRich.Mark.allCases.map { ($0.rawValue, $0.title, key($0.action), $0.symbol) }
                // A reply's way to the files of the mail it answers.
                if let originals = MailDesk.shared.originalsCommand { commands.append(("originals", originals, "", "paperclip")) }
                if context.reminding { commands.append(("nofollowup", "Don\u{2019}t Remind Me", "", "yab.clock.x")) }
            } else if !context.thread.isEmpty, context.picked < 2, MailDesk.shared.remindable(MailDesk.shared.chosen) {
                // A thread you wrote last in: it can come back if nobody answers.
                commands.append(("followup", "Remind Me If No Reply", key(.mailRemindNoReply), "bell"))
                if context.reminding { commands.append(("nofollowup", "Don\u{2019}t Remind Me", "", "yab.clock.x")) }
            }
            if context.view == "list" {
                let desk = MailDesk.shared
                if context.picked < 2 {
                    commands += [("selectall", "Select All", key(.mailSelectAll), "yab.checklist"),
                                 ("selectbelow", "Select From Here Down", key(.mailSelectBelow), "checklist")]
                }
                // What the list is narrowed to, and the way back to all of it.
                let marks: [MailDesk.Only: String] = [.unread: "yab.mail.dot", .starred: "star"]
                for only in MailDesk.Only.allCases {
                    let on = desk.only == only
                    commands.append(("only:" + only.rawValue, on ? "Show the Whole List" : only.command,
                                     key(only.action), on ? "line.3.horizontal.decrease" : marks[only] ?? "line.3.horizontal.decrease"))
                }
            }
            commands += [("new", "New Mail", key(.mailNew), "yab.mail.plus"), ("newlist", "New Split", "", "plus"),
                         ("zero", "Get Me To Zero", key(.mailZero), "yab.inbox.check"), ("bulk", "Bulk Actions…", key(.mailBulk), "clock.arrow.circlepath"),
                         ("keys", "Mail Keys", key(.mailKeys), "yab.keyboard")]
            // A search over the list: asked of Gmail, the whole mailbox (⇥ in the search).
            if MailDesk.shared.searchAsked != nil { commands.append(("searchall", "Search All Mail", "", "yab.mail.search")) }
            if let split = MailList.shared.split(MailList.shared.split) {
                if context.view == "list" { commands.append(("keeppage", "Keep a Page with This Split\u{2026}", "", "globe")) }
                commands.append(("unlist", split.builtIn ? "Turn Off \(split.title)" : "Remove This Split", "", "trash"))
            }
            commands.append(("pin", MailCenter.shared.pinWanted ? "Unpin Mail" : "Pin Mail", "", "pin"))
            let here = context.picked > 1 ? "\(context.picked) Selected"
                : context.view == "thread" ? "This Thread" : context.view == "compose" ? "This Mail" : context.thread.isEmpty ? "Mail" : "Chosen Thread"
            for (id, title, keys, symbol) in commands where lower.isEmpty || title.lowercased().contains(lower) {
                add("cmd." + id, title, "", .command(id: id, title: title), section: here, end: keys, symbol: symbol)
            }
            // Threads that answer the words, from every account's store.
            if !words.isEmpty {
                let found = MailCenter.shared.engines.values.flatMap { engine in
                    engine.store.search(words, limit: 8).map { (engine.account, $0) }
                }.sorted { $0.1.last > $1.1.last }.prefix(8)
                for (account, thread) in found {
                    let who = thread.people.first?.said ?? ""
                    add("thread.\(account).\(thread.id)", thread.subject.isEmpty ? "(no subject)" : thread.subject, who,
                        .thread(account: account, id: thread.id), section: "Threads",
                        end: MailLater.said(thread.last, now: Date()), symbol: "envelope")
                }
            }
            // The column's lists and splits in its order, then the rest (G
            // then a key, MailGo), and what Skip the inbox archived today.
            let column = MailList.shared.column.map { ($0.id, $0.title) }
            let lists = column + MailGo.places.compactMap { place in MailGo.views[place.id].map { (place.id, $0) } }
                + (MailList.shared.splits.contains { $0.on && $0.mode == .skip } ? [(MailSplits.skipped, "Archived Today")] : [])
            for (id, name) in lists where lower.isEmpty || ("go to " + name).lowercased().contains(lower) {
                let keys = MailGo.places.first { $0.id == id }.map(MailGo.said) ?? ""
                add("go." + id, name, "", .command(id: "go:" + id, title: name), section: "Go To", end: keys, symbol: "tray")
            }
            // A label's list, picked from the labels (G then L).
            if !MailLabels.shared.names.isEmpty, lower.isEmpty || "go to a label".contains(lower) {
                let keys = MailGo.places.first { $0.id == "label" }.map(MailGo.said) ?? ""
                add("go.label", "A Label\u{2026}", "", .command(id: "golabel", title: "A Label"), section: "Go To", end: keys, symbol: "tag")
            }
            // The labels themselves, by the words.
            if !lower.isEmpty {
                for name in MailLabels.shared.names where name.lowercased().contains(lower) {
                    add("go.label." + name, name, "", .command(id: "go:" + MailViews.prefix + name, title: name), section: "Labels",
                        end: "", symbol: "tag")
                }
            }
            // The accounts, as the column's chooser has them, with its keys.
            let accounts = MailCenter.shared.accounts
            if accounts.count > 1 {
                // All Accounts only while it gathers more than one.
                let all = MailCenter.shared.together.count > 1 ? ["all"] : []
                for account in all + accounts {
                    let name = MailAccountMark.name(account, accounts: accounts)
                    guard lower.isEmpty || name.lowercased().contains(lower) || "accounts".hasPrefix(lower) else { continue }
                    let n = (accounts.firstIndex(of: account) ?? -1) + 1
                    let action: Shortcut.Action? = n == 0 ? .mailAccountAll : Shortcut.numbered("mailAccount", n)
                    add("account." + account, name, Self.needing(account), .account(account), section: "Accounts",
                        end: action.map(key) ?? "", symbol: "person.crop.circle")
                }
            }
        case .zero:
            // How old, with how many threads each takes; then what it
            // leaves, ↩ turning each, the counts following.
            let leave = MailZero.Leave.chosen
            let now = Date()
            let inbox = MailCenter.shared.showing(MailList.shared.account)
                .map { $0.store.inboxThreads() }
            let section = "Get Me To Zero"
            for age in MailZero.Age.allCases where lower.isEmpty || age.name.lowercased().contains(lower) {
                let n = inbox.reduce(0) { $0 + MailZero.threads(age, leave: leave, of: $1, now: now).count }
                add("zero." + age.rawValue, age.name, "", .zero(age), section: section, end: n == 0 ? "None" : threads(n), symbol: "broom",
                    quiet: n == 0)
            }
            for (id, name, on, symbol) in [("unread", "Unread Threads", leave.unread, "envelope"), ("starred", "Starred Threads", leave.starred, "star")]
            where lower.isEmpty || name.lowercased().contains(lower) {
                add("zero.leave." + id, name, on ? "left in the inbox" : "marked done too", .leave(id), section: section, end: "", symbol: symbol)
            }
        case .bulk:
            // This week's acts on many threads, newest first, to take back.
            let since = Date().addingTimeInterval(-MailOps.bulkKept)
            // One act over several accounts (Get Me To Zero on all of them) is
            // one row: its entries share their words and their moment.
            var acts: [(said: String, at: Date, threads: Int, ids: [String: Int64])] = []
            for engine in MailCenter.shared.showing(MailList.shared.account) {
                for entry in engine.store.bulks(since: since) where entry.back == nil {
                    if let at = acts.firstIndex(where: { $0.said == entry.said && $0.at == entry.at }) {
                        acts[at].threads += entry.threads
                        acts[at].ids[engine.account] = entry.id
                    } else {
                        acts.append((entry.said, entry.at, entry.threads, [engine.account: entry.id]))
                    }
                }
            }
            for act in acts.sorted(by: { $0.at > $1.at }) where lower.isEmpty || act.said.lowercased().contains(lower) {
                let id = act.ids.sorted { $0.key < $1.key }.map { "\($0.key).\($0.value)" }.joined(separator: ".")
                add("bulk." + id, act.said, threads(act.threads), .bulk(act.ids),
                    section: "Bulk Actions", end: MailLater.said(act.at, now: Date()), symbol: "clock.arrow.circlepath")
            }
        case .sender:
            // The rest of their mail in the inbox: done, or into Trash.
            let n = MailCenter.shared.engines[context.account]?.store.inboxThreads(from: context.sender).count ?? 0
            let ways: [(Bool, String, String)] = [(false, "Mark Done", "checkmark"), (true, "Move to Trash", "trash")]
            for (trash, title, symbol) in context.trashFirst ? ways.reversed() : ways where lower.isEmpty || title.lowercased().contains(lower) {
                add("sweep." + (trash ? "trash" : "done"), title, "", .sweep(trash: trash), section: "Also From " + context.senderName,
                    end: n == 0 ? "None" : threads(n), symbol: symbol, quiet: n == 0)
            }
        case .from:
            // The addresses the draft can go from (⇧⌘F): the one it goes from marked.
            let desk = MailDesk.shared
            for sender in desk.senders {
                let said = sender.name.isEmpty ? sender.address : sender.name + " <" + sender.address + ">"
                guard lower.isEmpty || said.lowercased().contains(lower) else { continue }
                let chosen = sender.address == desk.sending
                add("from." + sender.address, said, "", .from(address: sender.address), section: "Send From",
                    end: chosen ? "Now" : sender.isDefault ? "Default" : "", symbol: chosen ? "checkmark" : "at")
            }
        case .snippets:
            // By their names, the most used first; what each says after.
            for snippet in MailSnippets.shared.matching(words) {
                add("snippet." + snippet.id, snippet.name, snippet.gist, .snippet(id: snippet.id), section: "Snippets",
                    end: snippet.filesSaid, symbol: "doc")
            }
        case .saveSnippet:
            // The name typed, or one made of the subject or the first words;
            // a snippet of that name already is replaced, and says so.
            let desk = MailDesk.shared
            if let source = desk.snippetSource(account: context.account, thread: context.thread) {
                let name = words.isEmpty ? MailSnippets.suggestedName(subject: source.subject, body: source.body) : words
                if !name.isEmpty {
                    let taken = MailSnippets.shared.named(name) != nil
                    add("savesnippet." + name, (taken ? "Replace \u{201C}" : "Save as \u{201C}") + name + "\u{201D}",
                        String(source.body.split(whereSeparator: \.isNewline).first ?? ""), .saveSnippet(name: name),
                        section: "Save as Snippet", end: source.files.isEmpty ? "" : source.files.count == 1 ? "1 file" : "\(source.files.count) files",
                        symbol: taken ? "arrow.clockwise" : "plus")
                }
            }
        case .slots:
            // Free slots of the next working days (MailSlots): what to put
            // in first, with its words, then each day's slots.
            guard let kept = MailSlots.kept else {
                add("slots.reading", "Reading your calendar…", "", .note, section: "Free Slots", end: "", symbol: "calendar")
                break
            }
            let now = Date()
            let slots = MailSlots.free(busy: kept.busy ?? [], from: now)
            if !context.seeded {
                query.stock.mail?.seeded = true
                query.stock.mail?.slots = MailSlots.suggested(slots, now: now).map(\.start.timeIntervalSince1970)
            }
            let picked = Set(query.stock.mail?.slots ?? [])
            let chosen = slots.filter { picked.contains($0.start.timeIntervalSince1970) }
            let text = MailSlots.text(chosen, booking: MailSlots.booking, now: now)
            if kept.busy == nil {
                add("slots.nocalendar", "\(Brand.name) can\u{2019}t see your calendar", "These are your working hours", .note, section: "Free Slots", end: "",
                    symbol: "calendar")
            }
            if !text.isEmpty {
                let title = chosen.isEmpty ? "Insert Your Booking Link" : chosen.count == 1 ? "Insert 1 Slot" : "Insert \(chosen.count) Slots"
                add("slots.insert", title, text.replacingOccurrences(of: "\n", with: " · "), .slots(text: text), section: "Free Slots", end: "", symbol: "calendar")
            }
            let day = MailICS.format("EEEE, MMM d", .current), weekday = MailICS.format("EEEE", .current), hour = MailICS.format("H:mm", .current)
            for slot in slots {
                let said = hour.string(from: slot.start) + "–" + hour.string(from: slot.end)
                guard lower.isEmpty || weekday.string(from: slot.start).lowercased().hasPrefix(lower) || said.hasPrefix(lower) else { continue }
                let at = slot.start.timeIntervalSince1970
                add("slot.\(Int(at))", said, "", .slot(at: at), section: day.string(from: slot.start), end: picked.contains(at) ? "Picked" : "",
                    symbol: picked.contains(at) ? "checkmark" : "clock")
            }
            if slots.isEmpty {
                add("slots.none", "No free time in your working hours", "Settings \u{203A} Mail keeps them", .note, section: "Free Slots", end: "",
                    symbol: "calendar")
            }
        case .keys:
            // Every key mail takes, as Settings › Shortcuts lists them and
            // with the keys chosen there: the same words, never a copy.
            for item in Shortcut.all.filter({ $0.title == "Mail" || $0.title == "Mail Formatting" }).flatMap(\.items) {
                let keys = Browser.keys(item)
                guard lower.isEmpty || item.does.lowercased().contains(lower) || keys.lowercased() == lower else { continue }
                add("key." + item.id, item.does, "", .key(id: item.id), section: "Mail Keys", end: keys, symbol: "keyboard")
            }
        }
        Browser.mailRows = rows
        return out
    }

    /// What the Mail place says when it has no row to show (PlaceEmpty):
    /// words nothing answers, words that are no time, no page open to keep.
    var mailEmpty: PlaceEmpty? {
        guard query.place == .mail, query.offers.isEmpty else { return nil }
        let context = query.stock.mail ?? MailFieldContext()
        let words = typed.trimmingCharacters(in: .whitespaces)
        switch context.mode {
        case .remind, .send, .followup:
            return PlaceEmpty(place: .mail, searching: true, title: "“\(words)” isn’t a time",
                              detail: "Say a day, an hour or both: tomorrow 9am, Friday, in 2 hours.")
        case .page:
            if !words.isEmpty {
                return PlaceEmpty(place: .mail, searching: true, title: "No open page says “\(words)”",
                                  detail: "Pages are found by their title and address, in every space.")
            }
            return PlaceEmpty(place: .mail, searching: false, title: "No pages open",
                              detail: "Open the page in a tab, in any space, and it comes here to keep with the split.")
        case .library:
            return PlaceEmpty(place: .mail, searching: true, title: "No split called “\(words)”",
                              detail: "Build Your Own makes one of any name.")
        case .splitTo:
            return PlaceEmpty(place: .mail, searching: true, title: "No split called “\(words)”",
                              detail: "Splits are found by their names. New Split from This Mail makes one.")
        case .splitRule:
            return PlaceEmpty(place: .mail, searching: !words.isEmpty, title: words.isEmpty ? "Nothing to add from this mail" : "Nothing for “\(words)”",
                              detail: "Its sender, their domain and its subject are offered here.")
        case .list:
            return PlaceEmpty(place: .mail, searching: false, title: "What should the split gather?",
                              detail: "Type a name, an address, a site like github.com or any words, and \(PlanText.writer) can make the split of them.")
        case .commands, .rewrite:
            return PlaceEmpty(place: .mail, searching: true, title: "Nothing for “\(words)”",
                              detail: "Commands are found by their name, threads by their subject, people and words.")
        case .keys:
            return PlaceEmpty(place: .mail, searching: true, title: "No key for “\(words)”",
                              detail: "Keys are found by what they do, or by the key itself.")
        case .bulk where words.isEmpty:
            return PlaceEmpty(place: .mail, searching: false, title: "Nothing done in bulk this week",
                              detail: "Get Me To Zero and a sender’s mail cleared out stay here for seven days, to take back.")
        case .zero, .bulk, .sender:
            return PlaceEmpty(place: .mail, searching: true, title: "Nothing for “\(words)”",
                              detail: "Rows are found by their names.")
        case .label, .move:
            return PlaceEmpty(place: .mail, searching: false, title: "No labels yet",
                              detail: "Type a name to make one: Work, Receipts, or Work/Clients under Work.")
        case .goLabel:
            if !words.isEmpty {
                return PlaceEmpty(place: .mail, searching: true, title: "No label “\(words)”",
                                  detail: "Labels are found by any part of their name.")
            }
            return PlaceEmpty(place: .mail, searching: false, title: "No labels yet",
                              detail: "Label a thread with L to make one; it shows here and in the column.")
        case .from:
            return PlaceEmpty(place: .mail, searching: true, title: "No address says “\(words)”",
                              detail: "Addresses are the ones Gmail lets this account send as, found by name and address.")
        case .snippets where MailSnippets.shared.all.isEmpty:
            return PlaceEmpty(place: .mail, searching: false, title: "No snippets yet",
                              detail: "Keep a mail’s words, or a draft’s, with Save as Snippet among mail’s commands, or make one in Settings › Mail.")
        case .snippets:
            return PlaceEmpty(place: .mail, searching: true, title: "No snippet named “\(words)”",
                              detail: "Snippets are found by their names.")
        case .saveSnippet:
            return PlaceEmpty(place: .mail, searching: false, title: "No words to keep",
                              detail: "Write the mail first, or open one whose words you want again.")
        case .slots:
            return PlaceEmpty(place: .mail, searching: true, title: "No free slot for “\(words)”",
                              detail: "Slots are found by their day and hour: tue, 14.")
        }
    }

    /// An item's keys as a row's end says them, each keystroke apart:
    /// "⇧⌘A", "G S", nothing for one given no key.
    static func keys(_ item: Shortcut.Item) -> String {
        if let action = item.action { return Keymap.shared.text(action) }
        return item.fixed.map { $0.joined() }.joined(separator: " ")
    }

    /// What ↩ on one of ?'s rows does: the command it is, where mail has
    /// one to run.
    static func command(forKey id: String) -> String? {
        if let action = Shortcut.Action(rawValue: id) {
            let commands: [Shortcut.Action: String] = [
                .mailDone: "done", .mailNotDone: "notdone", .mailStar: "star", .mailTrash: "trash", .mailSpam: "spam",
                .mailMute: "mute", .mailUnsubscribe: "unsubscribe", .mailBlock: "block", .mailZero: "zero", .mailBulk: "bulk",
                .mailKeep: "keep", .mailUnread: "unread", .mailDoIt: "doit", .mailSummarize: "summarize", .mailReply: "reply",
                .mailNew: "new", .mailSelect: "select", .mailSelectBelow: "selectbelow", .mailSelectAll: "selectall",
                .mailRemindNoReply: "followup",
                .mailOnlyUnread: "only:unread", .mailOnlyStarred: "only:starred", .mailOnlyUnanswered: "only:unanswered",
                .mailOpenFile: "openfile", .mailSaveFile: "savefile",
                .mailLabel: "label", .mailMove: "move", .mailUnlabel: "unlabel", .mailVIP: "vip", .mailFrom: "from",
                .mailBold: "bold", .mailItalic: "italic", .mailUnderline: "underline", .mailBullets: "bullets",
                .mailNumbers: "numbers", .mailQuote: "quote",
                .mailSnippet: "snippet",
                .mailAccept: "accept", .mailMaybe: "maybe", .mailDecline: "decline", .mailSlots: "slots",
            ]
            return commands[action]
        }
        // A chosen file's fixed keys, Space and ↩ (MailFileChips).
        let files = ["Look at the chosen attachment with Quick Look": "lookfile", "Open the chosen attachment in its app": "openinapp"]
        if let command = files[id] { return command }
        return MailGo.places.first { "Go to " + $0.name == id }.map { "go:" + $0.id }
    }

    /// ↩ on a Mail row; nothing on a quiet one.
    func takeMail(_ id: String) {
        guard let shown = Browser.mailRows[id], !shown.quiet else { return }
        mailActions(shown.row).first?.run()
    }

    /// A row of the field shown but not to be taken (MailField's quiet
    /// rows): dimmed, passed by the arrows and the pointer, never what ↩
    /// takes.
    func inert(_ index: Int) -> Bool {
        offers.indices.contains(index) && Browser.inert(offers[index])
    }

    static func inert(_ offer: Suggestion) -> Bool {
        guard case .page(let what) = offer.kind, what.hasPrefix("mail:") else { return false }
        return mailRows[String(what.dropFirst(5))]?.quiet == true
    }

    /// What ↩ does to a Mail row: one action, said as a verb.
    func mailActions(_ row: MailRow) -> [FieldAction] {
        let context = query.stock.mail ?? MailFieldContext()
        switch row {
        case .command(let id, let title):
            if id == "newlist" {
                // The same field: one of your own, and the splits mail has ready.
                return [FieldAction(id: "open", title: title, symbol: "plus") {
                    MailSplitLibrary.shared.read()
                    self.query.stock.mail?.mode = .library
                    self.query.stock.mail?.stepped = true
                    self.query.stock.version += 1
                    self.query.focusRequest += 1
                    self.replaceTyped("")
                }]
            }
            if id == "addsplit" || id == "splitfrom" || id == "keeppage" {
                // The same field: the splits, what of the thread, or the pages open.
                return [FieldAction(id: "open", title: title, symbol: id == "keeppage" ? "globe" : "plus") {
                    self.query.stock.mail?.mode = id == "addsplit" ? .splitTo : id == "splitfrom" ? .splitRule : .page
                    self.query.stock.mail?.editing = id == "keeppage" ? MailList.shared.split : nil
                    self.query.stock.mail?.stepped = true
                    self.query.stock.version += 1
                    self.query.focusRequest += 1
                    self.replaceTyped("")
                }]
            }
            let modes: [String: MailFieldContext.Mode] = ["remind": .remind, "sendlater": .send, "keys": .keys, "followup": .followup,
                                                         "zero": .zero, "bulk": .bulk, "from": .from,
                                                         "snippet": .snippets, "savesnippet": .saveSnippet]
            if let mode = modes[id] {
                // The same field, its rows now the times, mail's keys, Get
                // Me To Zero's or the Bulk Actions log.
                let symbols: [String: String] = ["keys": "keyboard", "zero": "broom", "bulk": "clock.arrow.circlepath", "from": "at",
                                                 "snippet": "doc", "savesnippet": "doc"]
                return [FieldAction(id: "open", title: title, symbol: symbols[id] ?? "clock") {
                    self.query.stock.mail?.mode = mode
                    self.query.stock.mail?.stepped = true
                    self.query.stock.version += 1
                    self.query.focusRequest += 1
                    self.replaceTyped("")
                }]
            }
            if id == "label" || id == "move" || id == "golabel" {
                // The same field, its rows now the labels: of what it is open
                // over, those all of it carries ticked (MailDesk.field's).
                return [FieldAction(id: "open", title: title, symbol: id == "move" ? "folder" : "tag") {
                    let picked = MailDesk.shared.targets
                    self.query.stock.mail?.mode = id == "label" ? .label : id == "move" ? .move : .goLabel
                    self.query.stock.mail?.accounts = id == "golabel" ? [] : Array(Set(picked.map(\.account))).sorted()
                    self.query.stock.mail?.applied = id == "label" ? MailDesk.applied(picked) : []
                    self.query.stock.mail?.here = MailViews.label(MailList.shared.split) ?? ""
                    self.query.stock.mail?.stepped = true
                    self.query.stock.version += 1
                    self.query.focusRequest += 1
                    self.replaceTyped("")
                }]
            }
            let verb = id.hasPrefix("go:") ? "Go to \(title)" : title
            return [FieldAction(id: "open", title: verb, symbol: "arrow.up.right") {
                self.closeMailField()
                self.onMail(context) { $0.command(id) }
            }]
        case .time(let label, let detail, let at):
            let send = context.mode == .send
            if context.mode == .followup {
                // A mail that comes back if nobody answers by then; none, at -1.
                return [FieldAction(id: "open", title: at < 0 ? "Don\u{2019}t Remind Me" : "Remind Me Then", symbol: at < 0 ? "clock.badge.xmark" : "bell") {
                    self.closeMailField()
                    self.onMail(context) { $0.remindNoReply(at: at > 0 ? Date(timeIntervalSince1970: at) : nil) }
                }]
            }
            return [FieldAction(id: "open", title: send ? "Send Then" : "Remind Me Then", symbol: "clock") {
                self.closeMailField()
                let why = detail.isEmpty ? label : label + ", " + detail
                let when = at > 0 ? Date(timeIntervalSince1970: at) : nil
                self.onMail(context) { desk in
                    if send { desk.send(at: when ?? Date()) } else { desk.snooze(at: when, why: why) }
                }
            }]
        case .noReply(let at):
            return [FieldAction(id: "open", title: "Remind Me Then", symbol: "bell") {
                self.closeMailField()
                self.onMail(context) { $0.remindNoReply(at: Date(timeIntervalSince1970: at)) }
            }]
        case .list(let title, let q):
            return [FieldAction(id: "open", title: "Keep as a Split", symbol: "plus") {
                self.closeMailField()
                self.onMail(context) { _ in MailList.shared.saveList(title: title, q: q) }
            }]
        case .ask(let words):
            return [FieldAction(id: "open", title: "Ask \(PlanText.writer)", symbol: "agent.face") {
                self.query.stock.mail?.thinking = true
                self.query.stock.mail?.proposal = nil
                self.query.stock.version += 1
                self.replaceTyped(self.typed)
                let senders = MailDesk.shared.topContacts(60).map { ($0.name, $0.address, $0.threads) }
                MailDrafts.list(words, senders: senders) { made in
                    guard self.query.place == .mail, self.query.stock.mail?.mode == .list else { return }
                    self.query.stock.mail?.thinking = false
                    self.query.stock.mail?.proposal = made
                    self.query.stock.version += 1
                    self.replaceTyped(self.typed)
                    if made == nil { self.toaster.pop("\(PlanText.writer) couldn\u{2019}t make it", mark: "agent.face") }
                }
            }]
        case .proposal:
            return [FieldAction(id: "open", title: "Keep as a Split", symbol: "plus") {
                guard let made = context.proposal else { return }
                self.closeMailField()
                self.onMail(context) { _ in MailList.shared.saveList(title: made.title, q: made.q, icon: made.icon, why: made.why) }
            }]
        case .rule(let rule):
            return [FieldAction(id: "open", title: "Add to the Split", symbol: "plus") {
                guard let id = context.editing else { return }
                self.closeMailField()
                self.onMail(context) { _ in MailList.shared.change(id) { $0.q = MailRule.line($0.rules + [rule]) } }
            }]
        case .page(let url, let title):
            return [FieldAction(id: "open", title: "Keep with the Split", symbol: "plus") {
                guard let id = context.editing else { return }
                self.closeMailField()
                self.onMail(context) { _ in
                    MailList.shared.change(id) { list in
                        var pages = list.pages ?? []
                        if !pages.contains(where: { $0.url == url }) { pages.append(MailList.Page(url: url, title: title)) }
                        list.pages = pages
                    }
                }
            }]
        case .split(let id):
            return [FieldAction(id: "open", title: "Choose", symbol: "rectangle.split.3x1") {
                self.query.stock.mail?.mode = .splitRule
                self.query.stock.mail?.editing = id
                self.query.stock.version += 1
                self.query.focusRequest += 1
                self.replaceTyped("")
            }]
        case .fromMail(let rule, let name):
            guard let id = context.editing else {
                return [FieldAction(id: "open", title: "Make the Split", symbol: "plus") {
                    self.closeMailField()
                    self.onMail(context) { _ in MailList.shared.saveList(title: name, q: MailRule.line([rule])) }
                }]
            }
            return [FieldAction(id: "open", title: "Add to " + MailList.name(id), symbol: "plus") {
                self.closeMailField()
                self.onMail(context) { $0.addToSplit(id, rule: rule, said: name) }
            }]
        case .library(let id):
            let library = MailSplitLibrary.shared
            if id == "build" || id == "describe" {
                return [FieldAction(id: "open", title: id == "build" ? "Build Your Own" : "Describe to \(PlanText.writer)", symbol: id == "build" ? "plus" : "sparkles") {
                    self.closeMailField()
                    self.onMail(context, focusPage: false) { _ in if id == "build" { library.build() } else { library.describe() } }
                }]
            }
            guard let card = MailSplitLibrary.cards.first(where: { $0.id == id }) else { return [] }
            let added = library.added(card)
            return [FieldAction(id: "open", title: added ? "Go to " + card.title : "Add " + card.title, symbol: added ? "arrow.up.right" : "plus") {
                self.closeMailField()
                self.onMail(context) { _ in if added { library.open(card) } else { library.add(card) } }
            }]
        case .note:
            return []
        case .label(let name):
            switch context.mode {
            case .goLabel:
                return [FieldAction(id: "open", title: "Go to \u{201C}\(name)\u{201D}", symbol: "tag") {
                    self.closeMailField()
                    self.onMail(context) { $0.go(MailViews.prefix + name) }
                }]
            case .move:
                return [FieldAction(id: "open", title: "Move to \u{201C}\(name)\u{201D}", symbol: "folder") {
                    self.closeMailField()
                    self.onMail(context) { $0.move(to: name) }
                }]
            default:
                let on = context.applied.contains(name)
                return [FieldAction(id: "open", title: on ? "Remove \u{201C}\(name)\u{201D}" : "Add \u{201C}\(name)\u{201D}", symbol: "tag") {
                    self.closeMailField()
                    self.onMail(context) { $0.label(named: name) }
                }]
            }
        case .newLabel(let name):
            let move = context.mode == .move
            return [FieldAction(id: "open", title: move ? "Create and Move" : "Create Label", symbol: "plus") {
                self.closeMailField()
                self.onMail(context) { move ? $0.move(to: name) : $0.label(named: name) }
            }]
        case .key(let id):
            guard let command = Browser.command(forKey: id) else { return [] }
            let does = Shortcut.items.first { $0.id == id }?.does ?? "Do It"
            return [FieldAction(id: "open", title: does, symbol: "arrow.up.right") {
                self.closeMailField()
                self.onMail(context) { $0.command(command) }
            }]
        case .rewrite(let how):
            return [FieldAction(id: "open", title: "Rewrite", symbol: "agent.face") {
                self.closeMailField()
                self.onMail(context) { $0.rewrite(how) }
            }]
        case .zero(let age):
            return [FieldAction(id: "open", title: "Mark Done", symbol: "broom") {
                self.closeMailField()
                self.onMail(context) { $0.zero(age) }
            }]
        case .leave(let what):
            // Turned in place: the field stays, its counts follow.
            let left = what == "starred" ? MailZero.Leave.chosen.starred : MailZero.Leave.chosen.unread
            return [FieldAction(id: "open", title: left ? "Mark Done Too" : "Leave in the Inbox", symbol: what == "starred" ? "star" : "envelope") {
                var leave = MailZero.Leave.chosen
                if what == "starred" { leave.starred.toggle() } else { leave.unread.toggle() }
                MailZero.Leave.chosen = leave
                self.query.stock.version += 1
                self.replaceTyped(self.typed)
            }]
        case .bulk(let ids):
            return [FieldAction(id: "open", title: "Take Back", symbol: "arrow.uturn.backward") {
                self.closeMailField()
                self.onMail(context) { $0.takeBack(bulks: ids) }
            }]
        case .from(let address):
            return [FieldAction(id: "open", title: "Send From Here", symbol: "at") {
                self.closeMailField()
                self.onMail(context) { $0.choose(from: address) }
            }]
        case .slot(let at):
            // Picked or left out in place: the field stays, on the same row.
            let on = context.slots.contains(at)
            return [FieldAction(id: "open", title: on ? "Leave Out" : "Pick", symbol: on ? "xmark" : "checkmark") {
                var slots = self.query.stock.mail?.slots ?? []
                if let found = slots.firstIndex(of: at) { slots.remove(at: found) } else { slots.append(at) }
                self.query.stock.mail?.slots = slots
                self.query.stock.version += 1
                self.replaceTyped(self.typed)
                self.picked = self.query.offers.firstIndex { $0.kind == .page("mail:slot.\(Int(at))") }
            }]
        case .slots(let text):
            return [FieldAction(id: "open", title: "Insert", symbol: "calendar") {
                self.closeMailField()
                self.onMail(context) { $0.insertSlots(text) }
            }]
        case .sweep(let trash):
            return [FieldAction(id: "open", title: trash ? "Move to Trash" : "Mark Done", symbol: trash ? "trash" : "checkmark") {
                self.closeMailField()
                self.onMail(context) { $0.sweep(account: context.account, sender: context.sender, name: context.senderName, trash: trash) }
            }]
        case .snippet(let id):
            return [FieldAction(id: "open", title: "Insert Snippet", symbol: "doc") {
                self.closeMailField()
                self.onMail(context) { desk in MailSnippets.shared.snippet(id).map { desk.insert($0) } }
            }]
        case .saveSnippet(let name):
            return [FieldAction(id: "open", title: "Save as Snippet", symbol: "doc") {
                self.closeMailField()
                self.onMail(context) { $0.saveSnippet(named: name, account: context.account, thread: context.thread) }
            }]
        case .thread(let account, let id):
            return [FieldAction(id: "open", title: "Open Thread", symbol: "arrow.up.right") {
                self.closeMailField()
                // In mail's space, the thread in the tab in front.
                var parts = URLComponents(string: "yab://mail")!
                parts.fragment = "thread=" + account + "|" + id
                self.enterMail(parts.url)
            }]
        case .account(let account):
            return [FieldAction(id: "open", title: "Go to Account", symbol: "arrow.up.right") {
                self.closeMailField()
                self.showMail(account: account)
            }]
        }
    }

    /// New Split's chosen row (MailLibraryPreview): "build", "describe" or
    /// a ready split's id.
    var mailLibraryChosen: String? {
        guard let at = query.current, query.offers.indices.contains(at), case .page(let what) = query.offers[at].kind,
              what.hasPrefix("mail:"), case .library(let id)? = Browser.mailRows[String(what.dropFirst(5))]?.row else { return nil }
        return id
    }

    /// ⌫ in the empty field or Escape, on times reached from the commands:
    /// the commands again, the field kept. On the commands, when the page
    /// raised the field: the field goes, the page has the keyboard again.
    func mailStepBack() -> Bool {
        guard query.place == .mail, let context = query.stock.mail else { return false }
        if !context.stepped {
            guard let id = context.tab, let tab = tabs.first(where: { $0.id == id }) else { return false }
            closeMailField()
            handBack(to: tab)
            return true
        }
        query.stock.mail?.mode = .commands
        query.stock.mail?.stepped = false
        query.stock.version += 1
        replaceTyped("")
        return true
    }

    /// The field gone, not only its place: the page under it in front.
    func closeMailField() {
        close()
        if active?.isBlank == false { dismiss() }
    }

    /// Something for mail's page to do (MailDesk), with it in front.
    private func onMail(_ context: MailFieldContext, focusPage: Bool = true, _ run: @escaping @MainActor (MailDesk) -> Void) {
        guard inMail, let tab = context.tab.flatMap({ id in tabs.first { $0.id == id } }) ?? mailPageTab else {
            showMail()
            return
        }
        if active?.id != tab.id { select(tab) }
        // Split creation focuses its own native input. A delayed handoff to
        // the background page would take the keyboard away again.
        if focusPage { handBack(to: tab) }
        run(MailDesk.shared)
    }

    /// Mail's space on one account, "all" for every one, as the column's
    /// chooser (⌘1) picks it: from ⌘T's list, or mail's ⌘K.
    func showMail(account: String) {
        MailList.shared.account = account
        enterMail()
    }

    /// The mail accounts the words name, for ⌘T's list, where the mail
    /// tab's own row only went to mail: Mail by one of its names (the
    /// field's place's), every one, All Accounts first when there are
    /// several; other words, the accounts whose address or domain they
    /// begin, so "42nd" is sam@42nd.dev and "dev" is nobody's. Four at
    /// most, in the chooser's order. `meant`: the words single one account
    /// out by its address, and Return goes there.
    func mailAccountRows(for text: String) -> (rows: [Suggestion], meant: Bool) {
        let accounts = MailCenter.shared.accounts
        guard prefs.usesMail, !accounts.isEmpty else { return ([], false) }
        let words = text.lowercased().split(separator: " ").map(String.init)
        // Begun far enough to be meant, as the place is (FieldPlace.named).
        let naming = words.filter { word in word.count >= 3 && FieldPlace.mail.names.contains { $0.hasPrefix(word) } }
        let rest = words.filter { !naming.contains($0) }
        guard !naming.isEmpty || rest.joined().count >= 3 else { return ([], false) }
        var found = accounts.filter { account in
            let address = account.lowercased()
            let domain = address.split(separator: "@").last.map(String.init) ?? address
            return rest.allSatisfy { address.hasPrefix($0) || domain.hasPrefix($0) }
        }
        let meant = !rest.isEmpty && found.count == 1
        if rest.isEmpty, MailCenter.shared.together.count > 1 { found.insert("all", at: 0) }
        let rows = found.prefix(4).map { account in
            Suggestion(key: MailAccountMark.name(account, accounts: accounts), title: Self.needing(account), url: nil, kind: .mailAccount(account))
        }
        return (rows, meant)
    }

    /// How many threads need you there, in words; nothing when none do.
    static func needing(_ account: String) -> String {
        let needs = MailList.shared.needs
        let center = MailCenter.shared
        let n = account == "all" ? MailAllAccounts.total(needs, accounts: center.accounts, apart: center.apart) : needs[account] ?? 0
        return n == 0 ? "" : n == 1 ? "1 needs you" : "\(n) need you"
    }
}
