import Foundation
import Testing
@testable import Fast

/// The person's consent for their mail and agents (docs/casa.md, Consent):
/// every switch off until turned on, no agent able to turn one on, and a
/// card before an agent reads, changes or carries mail, as often as the
/// call weighs.
@MainActor
@Suite(.serialized)
struct MailConsentTests {
    private let keys = [MailConsent.agentsKey, MailConsent.aheadKey, MailConsent.summariesKey, MailConsent.othersKey, MailConsent.askedKey]

    private func keeping(_ body: () throws -> Void) rethrows {
        let kept = keys.map { Store.settings.object(forKey: $0) }
        defer { for (key, value) in zip(keys, kept) { Store.settings.set(value, forKey: key) } }
        for key in keys { Store.settings.removeObject(forKey: key) }
        try body()
    }

    @Test func everySwitchIsOffUntilTurnedOn() {
        keeping {
            #expect(!MailCenter.agentsAllowed)
            #expect(!MailDrafts.on)
            #expect(!MailDrafts.summarizes)
            #expect(!MailConsent.others)
            #expect(!MailConsent.asked)
            Store.settings.set(true, forKey: MailConsent.agentsKey)
            #expect(MailCenter.agentsAllowed)
            MailConsent.answered()
            #expect(MailConsent.asked)
        }
    }

    @Test func noAgentCanTurnConsentOn() {
        for id in ["mail-agents", "mail-ahead", "mail-summaries", "mail-agents-others"] {
            #expect(NativeActions.controlled.contains(id), "\(id)")
        }
    }

    @Test func theCardsSayWhatTheyAreFor() {
        let read = AgentPermit(kind: .mailRead, session: "s", detail: "Looks for “invoice”")
        #expect(read.question == "Search your mail?")
        #expect(read.answers.map(\.title) == ["Search"])
        #expect(read.key == "mail.read")
        #expect(!read.weighty)
        let archive = AgentPermit(kind: .mailChange(label: "Archive", act: "archive"), session: "s", detail: "")
        #expect(archive.question == "Archive mail in this chat?")
        #expect(archive.answers.map(\.title) == ["Archive"])
        #expect(archive.key == "mail.change:archive")
        let site = AgentPermit(kind: .mailSite(host: "trip-share.io"), session: "s", detail: "")
        #expect(site.question == "Go to trip-share.io?")
        #expect(site.key == "mail.site:trip-share.io")
        let many = AgentPermit(kind: .sendMails(count: 3, mail: "k"), session: "s", detail: "", draft: "1. To a@b.c")
        #expect(many.question == "Send these 3 mails?")
        #expect(many.answers.map(\.title) == ["Send All"])
        #expect(many.key == "mails:k")
        #expect(many.weighty && many.sends)
        // Mail's own questions carry no mail, only what they ask: on the phone too.
        for kind: AgentPermit.Kind in [.mailRead, .mailChange(label: "Archive", act: "archive"), .mailSite(host: "a.io")] {
            #expect(AssistantApprovals.travels(kind))
        }
    }

    // MARK: - the gate

    @MainActor private struct World {
        let browser: Browser
        let tab: Tab
        let session: Agents.Session

        /// Mail you hand to Claude as it was: on for these, put back after.
        let consent: Any?

        init(mode: AgentAsking = .auto) {
            consent = Store.settings.object(forKey: MailConsent.agentsKey)
            Store.settings.set(true, forKey: MailConsent.agentsKey)
            browser = Browser(windowID: UUID())
            tab = Tab(bench: true)
            tab.restore(url: URL(string: "https://mail.example.test/")!, title: "Mail")
            browser.lay([tab])
            browser.activeID = tab.id
            browser.prefs.agentsAsking = mode
            let id = "mail-consent-" + UUID().uuidString
            Agents.shared.benchTask(id, state: .running)
            session = Agents.shared.session(id)!
            session.cli = "claude"
        }

        func call(_ verb: String, _ request: [String: Any] = [:]) -> (handled: Bool, said: [String: Any]) {
            var said: [String: Any] = [:]
            var full = request
            full["session"] = session.id
            let handled = Bench().mailAsks(AgentCall(bench: Bench(), verb: verb, request: full, browser: browser) { said = $0 })
            return (handled, said)
        }

        func dispose() {
            session.permit = nil
            Store.settings.set(consent, forKey: MailConsent.agentsKey)
            tab.permit = nil
            tab.handoff = nil
            for tab in browser.everyTab { tab.close() }
        }
    }

    @Test func searchingAsksOnceAChat() {
        let w = World(); defer { w.dispose() }
        let first = w.call("agent-mail-search", ["query": "invoice"])
        #expect(first.handled && first.said["asking"] as? Bool == true)
        // Asked of the chat, not of the tab in front.
        #expect(first.said["chat"] as? String == w.session.id)
        #expect(w.session.permit?.kind == .mailRead)
        #expect(w.session.permit?.detail == "Looks for “invoice”")
        #expect(w.tab.permit == nil && w.tab.guest == nil)
        Agents.shared.answer(chat: w.session.id, yes: true)
        #expect(!w.call("agent-mail-search", ["query": "invoice"]).handled)
        #expect(w.session.mailReading)
        // The rest of the chat goes on without a card.
        #expect(!w.call("agent-mail-triage").handled)
        #expect(!w.call("agent-mail-read", ["thread": "me@example.com|t9"]).handled)
        #expect(w.tab.permit == nil)
    }

    @Test func notNowIsAnAnswerTheAgentHears() {
        let w = World(); defer { w.dispose() }
        _ = w.call("agent-mail-triage")
        Agents.shared.answer(chat: w.session.id, yes: false)
        let refused = w.call("agent-mail-triage")
        #expect(refused.handled)
        #expect((refused.said["error"] as? String)?.contains("not now") == true)
        #expect(!w.session.mailReading)
    }

    @Test func mailThePersonGaveIsReadWithoutACard() {
        let w = World(); defer { w.dispose() }
        w.session.mailGiven.insert("me@example.com|t1")
        #expect(!w.call("agent-mail-read", ["thread": "me@example.com|t1"]).handled)
        #expect(!w.call("agent-mail-file", ["thread": "me@example.com|t1", "index": 0]).handled)
        #expect(w.session.permit == nil)
        // Another thread is not given.
        #expect(w.call("agent-mail-read", ["thread": "me@example.com|t2"]).handled)
        #expect(w.session.permit?.kind == .mailRead)
    }

    @Test(arguments: [AgentAsking.ask, .auto])
    func aChangeAsksOnceForItsKind(_ mode: AgentAsking) {
        let w = World(mode: mode); defer { w.dispose() }
        #expect(w.call("agent-mail-act", ["act": "archive", "thread": "me@example.com|t1"]).handled)
        #expect(w.session.permit?.kind == .mailChange(label: "Archive", act: "archive"))
        Agents.shared.answer(chat: w.session.id, yes: true)
        #expect(!w.call("agent-mail-act", ["act": "archive", "thread": "me@example.com|t1"]).handled)
        #expect(!w.call("agent-mail-act", ["act": "archive", "thread": "me@example.com|t2"]).handled)
        // Another kind of change asks for itself.
        #expect(w.call("agent-mail-act", ["act": "spam", "thread": "me@example.com|t3"]).handled)
        // Listing labels changes nothing.
        w.session.permit = nil
        #expect(!w.call("agent-mail-labels", ["act": "list"]).handled)
    }

    @Test func bypassChangesWithoutACardButStillAsksToRead() {
        let w = World(mode: .bypass); defer { w.dispose() }
        #expect(!w.call("agent-mail-act", ["act": "archive", "thread": "me@example.com|t1"]).handled)
        #expect(w.call("agent-mail-search", ["query": "x"]).handled)
        #expect(w.session.permit?.kind == .mailRead)
    }

    @Test func withMailYouHandOffTheChatAsksWithTheConsentsWords() {
        let w = World(); defer { w.dispose() }
        Store.settings.set(false, forKey: MailConsent.agentsKey)
        // Any call, a change too, asks to read first, saying who reads it under whose terms.
        #expect(w.call("agent-mail-act", ["act": "archive", "thread": "me@example.com|t1"]).handled)
        #expect(w.session.permit?.kind == .mailRead)
        #expect(w.session.permit?.detail.contains("Anthropic’s terms. Pane keeps no copy.") == true)
        Agents.shared.answer(chat: w.session.id, yes: true)
        // A yes for this chat, not the switch: only the person turns that on.
        #expect(!MailCenter.agentsAllowed)
        #expect(!w.call("agent-mail-search", ["query": "invoice"]).handled)
        // A change still asks for itself.
        #expect(w.call("agent-mail-act", ["act": "archive", "thread": "me@example.com|t1"]).handled)
        #expect(w.session.permit?.kind == .mailChange(label: "Archive", act: "archive"))
    }

    @Test func aChatThatReadMailAsksBeforeANewSite() {
        let w = World(); defer { w.dispose() }
        var said: [String: Any] = [:]
        let away = URL(string: "https://never-visited-\(UUID().uuidString.prefix(8)).example/collect?b=4417")
        // Before any mail, nothing to ask.
        #expect(!Bench.mailLeaves(away, session: w.session.id, browser: w.browser) { said = $0 })
        w.session.mail = true
        #expect(Bench.mailLeaves(away, session: w.session.id, browser: w.browser) { said = $0 })
        #expect(said["asking"] as? Bool == true)
        guard case .mailSite = w.session.permit?.kind else { Issue.record("no site card"); return }
        Agents.shared.answer(chat: w.session.id, yes: true)
        #expect(!Bench.mailLeaves(away, session: w.session.id, browser: w.browser) { said = $0 })
        // Once allowed, the same site goes on without a card.
        #expect(!Bench.mailLeaves(away, session: w.session.id, browser: w.browser) { said = $0 })
    }
}
