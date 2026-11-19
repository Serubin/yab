import Foundation

// The app's side of AI in Yab (AIUse, in YabStore): what each surface asks
// before it shows or runs. AIUse.allows is the switch; what follows adds the
// one thing the switch can't know, whether there is a model to ask at all.
//
// - Off: Agents.ready and FormModel.ready are false, so every surface that
//   already stood down without an agent or the Mac's model (the field's
//   rows, site buttons, Ask About This, Summarize in mail) stands down,
//   and the entry points below hide.
// - When Asked: `.field` and `.background` are refused; ⌘J, selected text,
//   the chat column and a task asked for stay.
// - Not connected (no plan, no Apple Intelligence): the entry points below
//   hide as the field's rows already did; Set up Yab's Connect row and
//   Settings › AI stay the way in.

extension AIUse {
    /// Something to ask: a connected plan, or the Mac's model. A plan
    /// connected in Yab counts before discovery finds its CLI after a
    /// relaunch, so ⌘J still opens the saved chat column (TaskLine.open).
    @MainActor static var reachable: Bool { Agents.ready || Agents.connected || FormModel.ready }

    /// ⌘J, Ask About This on a selection, Ask About Tab and Image, the
    /// selection's commands: shown only with the switch past Off and a
    /// model to ask.
    @MainActor static var offers: Bool { allows(.asked) && reachable }

    /// The chat column, from Show Chat and its key: once there is an agent,
    /// or a chat already to go back to, and never with AI off.
    @MainActor static var chats: Bool { allows(.asked) && (Agents.ready || !Chats.shared.all.isEmpty) }

    /// The empty field's Set up Yab row that connects a plan: nothing to ask
    /// yet, and AI not turned off.
    @MainActor static var connectOffered: Bool { level() != .off && !reachable }

    /// What the detail line under the switch says.
    static func detail(_ level: Level) -> String {
        switch level {
        case .on: return "Everywhere in \(Brand.name)."
        case .asked: return "Only ⌘J and selected text."
        case .off: return "No AI anywhere in \(Brand.name)."
        }
    }
}

extension Browser {
    /// AI in Yab set from ⌘T (Turn Off AI, Turn On AI, AI Only When Asked):
    /// said in the corner, since the field that asked is gone.
    func useAI(_ level: AIUse.Level) {
        prefs.aiUse = level
        let words: String
        switch level {
        case .on: words = "AI is on"
        case .asked: words = "AI only when asked"
        case .off: words = "AI is off"
        }
        announceSetting(words, mark: "sparkles")
    }

    /// Hide AI Rows in Field, or Show: Ask and Task under the words and ⇥
    /// asking, the switch left as it is.
    func hideAIRows(_ hide: Bool) {
        prefs.aiRowsHidden = hide
        announceSetting(hide ? "AI rows hidden in the field" : "AI rows shown in the field", mark: "sparkles")
    }

    /// Turn Off AI… on an Ask or Task row: Settings › AI, the switch in view.
    func openAISwitch() {
        close()
        SettingsWindow.shared.show(.ai, for: self)
        guard let item = SettingsItem.all.first(where: { $0.id == "ai-use" }) else { return }
        // Once the page is laid out, as showCommands waits.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { SettingsWindow.shared.model?.take(.item(item)) }
    }
}
