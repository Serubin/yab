import Foundation

// `./bench forms …`, test runs only: whole forms, the way evals/forms drives
// them. "seed" keeps a profile and answers ({"profile": {...}, "answers":
// [{"question", "answer", "site"}]}), "clear" forgets them and what the
// Mac's model learned; "plan" says what each box of the form the caret is
// in would get; "fill" takes the list's row (or the form in front, as ⌥↩
// does) and says how long it took and what is left; "undo" is ⌘Z;
// "decline" is Escape on the list. With
// nothing asked, the answer says what the list under the box offers.

extension Bench {
    func formsCommand(_ request: [String: Any], browser: Browser, _ answer: @escaping ([String: Any]) -> Void) {
        guard Store.testing else { return answer(["error": "forms only works on a --test run"]) }
        if request["forgetMemory"] as? Bool == true { Memory.forgetEverything() }
        if request["clear"] as? Bool == true {
            Profile.forget()
            FormAnswers.forget()
            FormModel.forget()
            browser.tabs.forEach { $0.wallet.form = FormWatch() }
        }
        if let given = request["profile"] as? [String: Any] {
            var profile = Profile.load()
            for (key, value) in given { if let v = value as? String { profile[key] = v } }
            profile.source = "bench"
            Profile.save(profile)
        }
        if let said = request["answers"] as? [[String: Any]] {
            var bySite: [String: [(question: String, answer: String)]] = [:]
            for one in said {
                guard let q = one["question"] as? String, let a = one["answer"] as? String else { continue }
                bySite[one["site"] as? String ?? "", default: []].append((q, a))
            }
            for (site, pairs) in bySite { FormAnswers.keep(pairs, site: site) }
        }
        if let learned = request["learned"] as? [String: String] {
            for (label, key) in learned { FormModel.known[FormAnswers.normal(label)] = key }
        }
        if let on = request["on"] as? Bool { FormFill.on = on }
        if let drafts = request["drafts"] as? Bool { FormDraft.on = drafts }
        let tab = find(request, in: browser) ?? browser.active
        switch request["act"] as? String ?? "" {
        case "plan":
            guard let tab else { return answer(["error": "no tab"]) }
            tab.formPlan { plan in answer(["steps": plan.map(FormBench.steps) ?? [], "offer": plan.map { FormOffer($0, drafts: tab.wallet.form.drafts).detail } ?? ""]) }
            return
        case "fill":
            guard let tab else { return answer(["error": "no tab"]) }
            let started = Date()
            let fill = { browser.fillForm(tab) { filled, left in
                answer(["filled": filled, "ms": Int(Date().timeIntervalSince(started) * 1000),
                        "js_ms": Int((tab.wallet.form.took ?? 0) * 1000),
                        "left": left.map { ["label": $0.field.label, "why": FormBench.name($0.source)] }])
            } }
            // A fresh plan unless the list's is there to take, as a person would.
            if request["fresh"] as? Bool == true { tab.wallet.form.plan = nil }
            fill()
            return
        case "undo":
            answer(["undone": browser.undoFormFill()])
            return
        case "decline":
            // Escape on the list: no for the page.
            browser.dropWallet()
            answer(["declined": tab?.wallet.declined ?? ""])
            return
        case "knowme":
            // Getting to know the person, as the new tab's row starts it,
            // or from memory alone ("memory": true); the answer is its session.
            let session = request["memory"] as? Bool == true ? Agents.shared.profileFromMemory() : Agents.shared.setUpMemory()
            answer(["session": session.id])
            return
        case "session":
            // A task's state and its last answer, for a check that waits on it.
            guard let known = Agents.shared.session(request["session"] as? String) else { return answer(["error": "no such session"]) }
            answer(["state": known.state.rawValue, "live": known.state.live, "result": known.result, "now": known.now,
                    "knowing": known.knowing, "seconds": Int(Date().timeIntervalSince(known.began))])
            return
        case "settings":
            // Settings › Passwords, where the form switches are, for a picture.
            SettingsWindow.shared.show(.passwords, for: browser)
            answer(["ok": true])
            return
        case "drafts":
            // Waits up to `seconds` for every draft of the plan to be written.
            guard let tab else { return answer(["error": "no tab"]) }
            let limit = Date().addingTimeInterval(request["seconds"] as? Double ?? 30)
            let started = Date()
            func look() {
                let asked = tab.wallet.form.plan?.drafts ?? []
                let done = asked.allSatisfy { tab.wallet.form.drafts[FormAnswers.normal($0.field.label)] != nil }
                let lost = tab.wallet.form.plan?.steps.contains { $0.source == .yours("words") } ?? false
                if done || lost || Date() > limit {
                    return answer(["ready": done && !asked.isEmpty, "lost": lost, "ms": Int(Date().timeIntervalSince(started) * 1000),
                                   "drafts": tab.wallet.form.drafts])
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { look() }
            }
            look()
            return
        default:
            break
        }
        var out: [String: Any] = [
            "profile": Profile.load().said,
            "answers": FormAnswers.load().said.map { ["question": $0.question, "answer": $0.answer, "site": $0.site] },
            "model": FormModel.ready,
            "modelSaid": FormModel.last,
            "drafter": ["said": FormDraft.shared.said, "running": FormDraft.shared.running, "asked": FormDraft.shared.asked,
                        "usable": FormDraft.shared.usable],
            "learned": FormModel.known,
        ]
        out["ghost"] = (tab ?? browser.active)?.wallet.form.ghost ?? ""
        if let list = browser.walletList {
            out["list"] = ["group": list.group.rawValue, "count": list.count, "form": list.form?.detail ?? "",
                           "addresses": list.addresses.count, "dark": list.dark.map { $0 ? "dark" : "light" } ?? ""]
        }
        answer(out)
    }
}

enum FormBench {
    static func name(_ source: FormSource) -> String {
        switch source {
        case .wallet: return "wallet"
        case .profile(let key): return "profile:" + key
        case .answer: return "answer"
        case .draft: return "draft"
        case .untick: return "untick"
        case .yours(let why): return "yours:" + why
        case .skip: return "skip"
        }
    }

    static func steps(_ plan: FormPlan) -> [[String: Any]] {
        plan.steps.map { ["label": $0.field.label, "type": $0.field.type.isEmpty ? $0.field.tag : $0.field.type, "source": name($0.source), "value": $0.value ?? ""] }
    }
}

extension Bench {
    /// `autofill` with what: form. yab fills what it has at once; the
    /// agent hears what went in, what is left for it to write, and what is
    /// the person's alone. The address's parts wait for the person's yes,
    /// as an address alone does, unless they said never to be asked.
    func agentFillForm(_ tab: Tab, session: String, browser: Browser, _ answer: @escaping ([String: Any]) -> Void) {
        guard FormFill.on else {
            answer(["error": "filling whole forms is off (Settings › Passwords): type the boxes in, or call handoff"])
            return
        }
        let agents = Agents.shared
        let site = Browser.site(tab.address?.host() ?? "")
        // The agent works on the page's own form; what the person's caret
        // had (its frame, its plan) is put back once the agent's is read, so
        // their ⌥↩ still fills the form they are in.
        let persons = tab.wallet.form
        let giveBack = { [weak tab] in
            tab?.wallet.form.frame = persons.frame
            tab?.wallet.form.plan = persons.plan
            tab?.wallet.form.planned = persons.planned
        }
        tab.wallet.form.frame = nil
        tab.formPlan { read in
            defer { giveBack() }
            guard var plan = read, plan.steps.contains(where: { $0.field.type != "checkbox" }) else {
                answer(["error": "no form here that \(Brand.name) could read: take a snapshot and type the boxes in"])
                return
            }
            // An address is the person's to give to a site (as autofill address).
            if plan.address, browser.prefs.asking(session) != .bypass {
                let key = "address:" + site
                let yes = tab.approved.flatMap { $0.session == session && $0.ref == key && Date().timeIntervalSince($0.at) < 120 ? $0 : nil }
                if yes == nil {
                    if tab.declined.remove(session) != nil {
                        // Said no: the rest goes in, the address's boxes stay theirs.
                        for n in plan.steps.indices where plan.steps[n].source == .wallet { plan.steps[n].source = .yours("address") }
                    } else if let address = Wallet.preferredAddress() {
                        agents.ask(tab, AgentPermit(kind: .address(host: site), session: session,
                                                    detail: [address.title, address.place].filter { !$0.isEmpty }.joined(separator: ", ")))
                        answer(["error": "the form holds the user's address, which waits for their yes; asking them now. Call autofill again once they answered.", "asking": true])
                        return
                    }
                } else {
                    tab.approved = nil
                }
            }
            // The agent writes the drafts itself: they are left for it.
            for n in plan.steps.indices where plan.steps[n].source == .draft { plan.steps[n].value = nil }
            agents.touch(session, "autofill · \(site)")
            AgentFeed.shared.did(tab, .type)
            let address = plan.address ? Wallet.preferredAddress() : nil
            tab.formFill(plan, address: address) { filled, _ in
                if filled > 0, let address { DispatchQueue.global(qos: .utility).async { Wallet.touch(address: address.id, on: site) } }
                answer(["ok": true, "said": FormBench.said(plan, filled: filled)])
            }
        }
    }
}

extension FormBench {
    /// What an agent hears after a form was filled: what went in and from
    /// where, what is left for it, what is the person's, and the profile it
    /// writes the rest from.
    static func said(_ plan: FormPlan, filled: Int) -> String {
        var lines = ["Filled \(filled) boxes at once."]
        let went = plan.steps.compactMap { step -> String? in
            switch step.source {
            case .wallet: return nil
            case .profile(let key): return "\"\(step.field.label)\" from the profile (\(key))"
            case .answer: return "\"\(step.field.label)\" as the user answered it before"
            case .untick: return "\"\(step.field.label)\" unticked (the page had ticked it)"
            default: return nil
            }
        }
        if plan.address { lines.append("The address's boxes from the user's kept address.") }
        if !went.isEmpty { lines.append(went.joined(separator: "; ") + ".") }
        let write = plan.steps.filter { $0.source == .draft }.map { "\"\($0.field.label)\"" }
        if !write.isEmpty {
            lines.append("Left for you to write, in the user's voice from the profile below, with type: \(write.joined(separator: ", ")).")
        }
        let theirs = plan.steps.compactMap { step -> String? in
            guard case .yours(let why) = step.source, !step.field.label.isEmpty else { return nil }
            return "\"\(step.field.label)\" (\(why))"
        }
        if !theirs.isEmpty {
            lines.append("The user's alone, don't fill unless the task gives the answer: \(theirs.joined(separator: ", ")). Never tick a consent box or submit unless the task says so.")
        }
        let profile = Profile.load().said
        if !profile.isEmpty {
            lines.append("Profile: " + Profile.keys.compactMap { key in profile[key].map { "\(key): \($0)" } }.joined(separator: "; "))
        }
        return lines.joined(separator: "\n")
    }
}
