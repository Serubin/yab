import Foundation

// The person's yes before an agent's mail call (docs/casa.md, Consent).
// Google's Workspace policy asks for each agentic call on mail to be
// confirmed; asked as often as the call weighs, so nobody learns to press
// yes unread:
//
// - What the person gave the chat (D on a mail, ⌘J in it, an `m:` chip,
//   picked rows) is read with no card: giving it was the yes.
// - Anything else (triage, search, a list, the memory, another thread or
//   its files) asks once a chat, the card saying what it looks for. For
//   another app's agent, once its session: every `yab mcp` connection that
//   names the same client session (Claude Code's CLAUDE_CODE_SESSION_ID,
//   its own server and the ones its shell starts) shares the yes
//   (Agents.mailGrants); a new session asks again.
// - A change (mail_act's acts, label changes) asks once a chat for each kind
//   of change, in Ask and Auto; Bypass is the person's own choice to be
//   asked nothing, and every change has its ⌘Z.
// - Sending asks every time, in every mode (Agents.sendMail).
// - Another app's agent (`yab mcp` in Cursor, Zed) gets mail only once
//   Settings › Mail › Agents' Mail tools in other apps is on.

extension Bench {
    /// Whether the call was answered here: refused, or waiting on the
    /// person's card. False to go on with it.
    func mailAsks(_ c: AgentCall) -> Bool {
        let agents = c.agents
        let asker = c.session.flatMap { agents.session($0) }
        // A caller Yab didn't start: another app's agent through `yab mcp`.
        if asker == nil || asker?.cli == "external" {
            guard MailConsent.others || Store.testing else {
                c.answer(["error": "the person hasn't given mail to other apps: Settings › Mail › Agents › Mail tools in other apps"])
                return true
            }
            guard asker != nil else { return false }
        }
        guard let session = c.session, let asker else { return false }
        let root = agents.session(agents.root(of: session)) ?? asker
        let request = c.request
        // Mail you hand to Claude off: nothing of the mail goes to the AI
        // until the person says yes for this chat, whatever the call, the
        // consent's words on the question (docs/casa.md, Consent). The
        // switch in Settings stays as it is: only the person turns it on.
        if !MailCenter.agentsAllowed, !root.mailReading {
            let reads = ["agent-mail-triage", "agent-mail-search", "agent-mail-list", "agent-mail-recall", "agent-mail-read", "agent-mail-file",
                         "agent-files-search", "agent-files-read", "agent-purchases"]
            let what = reads.contains(c.verb) ? looking(c.verb, request) : "Works on your mail"
            let terms = "\(root.planName) reads what it finds on your plan, under \(MailConsent.company(root.planName))’s terms. \(Brand.name) keeps no copy."
            let permit = AgentPermit(kind: .mailRead, session: session, detail: what + ". " + terms)
            ApprovalDetails.shared.searching[ApprovalDetails.changeKey(session: session, permit: permit)] = what + "\n" + terms
            return ask(c, permit, session: session) {
                agents.grantMail(root)
            }
        }
        switch c.verb {
        case "agent-mail-triage", "agent-mail-search", "agent-mail-list", "agent-mail-recall", "agent-mail-read", "agent-mail-file",
             "agent-files-search", "agent-files-read", "agent-purchases":
            // Another app's agent said yes in an earlier connection of the
            // same session (its shell's `yab mcp` too): no card again.
            if agents.mailGranted(root) { root.mailReading = true; return false }
            if root.mailReading || given(c.verb, request, root: root, asker: asker) { return false }
            var permit = AgentPermit(kind: .mailRead, session: session, detail: looking(c.verb, request))
            permit.forSession = root.agent == .external
            ApprovalDetails.shared.searching[ApprovalDetails.changeKey(session: session, permit: permit)] = permit.detail
            return ask(c, permit, session: session) { agents.grantMail(root) }
        case "agent-mail-act", "agent-mail-labels":
            let change = c.verb == "agent-mail-act"
                ? request["act"] as? String ?? ""
                : "labels." + (request["act"] as? String ?? "list")
            guard change != "labels.list", !change.isEmpty else { return false }
            if root.mailChanges.contains(change) || c.browser.prefs.asking(session) == .bypass { return false }
            let permit = AgentPermit(kind: .mailChange(label: Self.changeWords(change).yes, act: change), session: session,
                                     detail: subject(request["thread"] as? String) ?? "")
            // The mail it would change, for a device that reads it first.
            let threads = ((request["threads"] as? [String]) ?? []) + [request["thread"] as? String].compactMap { $0 }
            ApprovalDetails.shared.changing[ApprovalDetails.changeKey(session: session, permit: permit)] = threads.filter { !$0.isEmpty }
            return ask(c, permit, session: session) { root.mailChanges.insert(change) }
        default:
            return false
        }
    }

    /// The card asked, or its answer taken: true while it waits or after a
    /// no, false once the person said yes (`yes` then keeps it for the chat).
    private func ask(_ c: AgentCall, _ permit: AgentPermit, session: String, yes: () -> Void) -> Bool {
        Self.askOnce(permit, session: session, browser: c.browser, answer: c.answer, yes: yes)
    }

    static func askOnce(_ permit: AgentPermit, session: String, browser: Browser,
                        answer: ([String: Any]) -> Void, yes: () -> Void) -> Bool {
        let agents = Agents.shared
        // A question for the whole chat waits in the chat, not on whatever
        // tab is in front (Agents.askChat). The yes is kept on the chat, so
        // the call that comes again finds it before reaching here.
        if permit.place == .chat, let asker = agents.session(session) {
            return agents.askChat(permit, root: agents.session(agents.root(of: session)) ?? asker, browser: browser, answer: answer)
        }
        guard let tab = agents.askTab(for: session, in: browser) else {
            answer(["error": "no tab to ask the person in"]); return true
        }
        if let approved = tab.approved, approved.session == session, approved.ref == permit.key,
           Date().timeIntervalSince(approved.at) < 120 {
            tab.approved = nil
            yes()
            return false
        }
        if tab.declined.remove(session) != nil {
            answer(["error": declinedWords(permit.kind)])
            return true
        }
        agents.ask(tab, permit)
        agents.showAsk(tab, session: session, in: browser)
        answer(["error": "this waits for the person's yes; asking them now", "asking": true, "tab": Bench.short(tab)])
        return true
    }

    /// What the agent hears after the person's Not Now to its question.
    static func declinedWords(_ kind: AgentPermit.Kind) -> String {
        switch kind {
        case .mailRead: return "the person said not now to searching their mail: work with the mail they gave you, or say in your answer what you would look for"
        case .mailSite(let host): return "the person said not now to going to \(host) after this chat read their mail: don't reach it another way; say so in your answer"
        default: return "the person said not now to that change: don't make it another way; say in your answer what you would change"
        }
    }

    /// A chat that read mail, going to a site the person has never been
    /// to: asked first, once a site, in every mode, since a mail that talks
    /// the agent round would send what it read out this way (docs/casa.md,
    /// open item 15). True when answered here.
    static func mailLeaves(_ url: URL?, session: String?, browser: Browser, answer: ([String: Any]) -> Void) -> Bool {
        guard let url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""), let host = url.host()?.lowercased(),
              let session, let asker = Agents.shared.session(session) else { return false }
        let agents = Agents.shared
        let root = agents.session(agents.root(of: session)) ?? asker
        guard root.mail || asker.mail else { return false }
        let site = Vault.registrable(host)
        if root.mailSites.contains(site) || History.shared.knows(site: site) { return false }
        let permit = AgentPermit(kind: .mailSite(host: site), session: session,
                                 detail: "This chat read your mail, and you haven’t been to this site")
        return askOnce(permit, session: session, browser: browser, answer: answer) { root.mailSites.insert(site) }
    }

    /// Mail the person gave the chat: a thread (or its files) they gave,
    /// or the list they gave, read whole.
    private func given(_ verb: String, _ request: [String: Any], root: Agents.Session, asker: Agents.Session) -> Bool {
        let gave = root.mailGiven.union(asker.mailGiven)
        switch verb {
        case "agent-mail-read":
            if let draft = request["draft"] as? String, !draft.isEmpty { return true }
            return gave.contains(request["thread"] as? String ?? "")
        case "agent-mail-file":
            return gave.contains(request["thread"] as? String ?? "")
        default:
            return false
        }
    }

    /// The card's line: what the call looks for.
    private func looking(_ verb: String, _ request: [String: Any]) -> String {
        let words = (request["query"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        switch verb {
        case "agent-mail-triage": return "Looks at what needs you"
        case "agent-mail-list": return "Looks through a list of your mail"
        case "agent-mail-read", "agent-mail-file": return subject(request["thread"] as? String).map { "Opens “\($0)”" } ?? "Opens a mail"
        case "agent-files-search": return words.isEmpty ? "Looks through the files your mail brought" : "Looks for “\(String(words.prefix(60)))” in your files"
        case "agent-files-read": return "Reads a file your mail brought"
        case "agent-purchases": return "Looks through your receipts and orders"
        default: return words.isEmpty ? "Searches your mail" : "Looks for “\(String(words.prefix(60)))”"
        }
    }

    /// A thread's subject on this Mac, for the card.
    private func subject(_ key: String?) -> String? {
        guard let key, !key.isEmpty else { return nil }
        let id = key.split(separator: "|").last.map(String.init) ?? key
        guard let engine = MailAgent.engine(holding: key, in: MailCenter.shared.engines.values)?.engine,
              let words = engine.store.thread(id)?.subject, !words.isEmpty else { return nil }
        return String(words.prefix(60))
    }

    /// A change's card: its question and the yes's word.
    nonisolated static func changeWords(_ change: String) -> (question: String, yes: String) {
        switch change {
        case "archive": return ("Archive mail in this chat?", "Archive")
        case "inbox": return ("Move mail back to the inbox in this chat?", "Move")
        case "star": return ("Star mail in this chat?", "Star")
        case "unstar": return ("Unstar mail in this chat?", "Unstar")
        case "spam": return ("Mark mail as spam in this chat?", "Mark as Spam")
        case "trash": return ("Move mail to Trash in this chat?", "Move to Trash")
        case "read": return ("Mark mail as read in this chat?", "Mark as Read")
        case "unread": return ("Mark mail as unread in this chat?", "Mark as Unread")
        case "mute", "unmute": return ("Mute or unmute threads in this chat?", "Allow")
        case "important", "unimportant": return ("Mark mail as important or not in this chat?", "Allow")
        case "label", "unlabel": return ("Label mail in this chat?", "Label")
        case "snooze", "remind", "unremind": return ("Snooze mail in this chat?", "Snooze")
        case "unsubscribe": return ("Unsubscribe from lists in this chat?", "Unsubscribe")
        case "labels.create": return ("Make labels in this chat?", "Make Labels")
        case "labels.rename": return ("Rename labels in this chat?", "Rename")
        case "labels.delete": return ("Delete labels in this chat?", "Delete")
        default: return ("Change mail in this chat?", "Allow")
        }
    }
}
