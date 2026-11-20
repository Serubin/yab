import Foundation
import Testing
@testable import Fast

// Settings › Agents' Connect: the PATH line it puts in a shell's file and
// takes back, how an agent's last use is said, what each state of Connect
// says and offers (docs/agents.md, Connect, state by state), and that a
// second press is nothing.
struct AgentConnectTests {
    @Test func pathLineGoesAndComesBackOut() throws {
        let before = "export PATH=/opt/homebrew/bin:$PATH\nalias g=git\n"
        let added = try #require(AgentSetup.withPathLine(before))
        #expect(added.hasPrefix(before + "\n"))
        #expect(added.hasSuffix(AgentSetup.pathLine + "\n"))
        #expect(AgentSetup.withPathLine(added) == nil)
        #expect(AgentSetup.withoutPathLine(added) == before)
    }

    @Test func pathLineInAnEmptyOrUnendedFile() throws {
        let empty = try #require(AgentSetup.withPathLine(""))
        #expect(empty == AgentSetup.pathLine + "\n")
        #expect(AgentSetup.withoutPathLine(empty) == "\n" || AgentSetup.withoutPathLine(empty).isEmpty)
        let unended = try #require(AgentSetup.withPathLine("alias g=git"))
        #expect(AgentSetup.withoutPathLine(unended) == "alias g=git\n")
    }

    @Test func aFileWithoutOurLineIsLeftAlone() {
        let text = "export PATH=\"$HOME/.local/bin:$PATH\"\n"
        #expect(AgentSetup.withoutPathLine(text) == text)
    }

    @Test func lastUseInWords() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(AgentSetupModel.ago(now.addingTimeInterval(-20), now: now) == "just now")
        #expect(AgentSetupModel.ago(now.addingTimeInterval(-12 * 60), now: now) == "12m ago")
        #expect(AgentSetupModel.ago(now.addingTimeInterval(-3 * 3600), now: now) == "3h ago")
        #expect(AgentSetupModel.ago(now.addingTimeInterval(-30 * 3600), now: now) == "yesterday")
        #expect(AgentSetupModel.ago(now.addingTimeInterval(-4 * 86_400), now: now) == "4d ago")
    }

    /// People read the plan they pay for; a terminal, the tool it runs.
    @MainActor @Test func peopleReadThePlanAndTheTerminalTheTool() {
        #expect(AgentSetupModel.name("claude") == "Claude" && AgentSetupModel.name("codex") == "ChatGPT")
        #expect(AgentSetupModel.names(["claude", "codex"]) == "Claude and ChatGPT")
        #expect(AgentSetupModel.names(["claude", "codex", "cursor"]) == "Claude, ChatGPT, and Cursor")
        // Cursor runs inside Yab: no skill to name, so no How to Ask.
        #expect(AgentSetupModel.skilled("claude") && AgentSetupModel.skilled("codex") && !AgentSetupModel.skilled("cursor"))
        #expect(FieldAnswer.mark("cursor") == "brand.cursor")
        #expect(WelcomeConnect.needs("cursor").hasPrefix("Cursor"))
        #expect(AgentSetupModel.tool("claude") == "Claude Code" && AgentSetupModel.tool("codex") == "Codex")
        #expect(AgentModels.agentName("codex") == "ChatGPT")
        #expect(WelcomeConnect.needs("claude") == "Claude needs Pro, Max, Team or Enterprise.")
        #expect(WelcomeConnect.needs("codex").hasPrefix("ChatGPT works on Plus, Pro, Business, Enterprise and Edu."))
        let quiet = Agents.Session(id: "q", cli: "claude", name: "Selection command", prompt: "", state: .starting)
        #expect(quiet.planName == "Claude")
        let theirs = Agents.Session(id: "t", cli: "external", name: "Cursor", prompt: "", state: .attached)
        #expect(theirs.planName == "Cursor")
    }

    /// Auto is the one plan connected, and the rows name it: Claude Code
    /// installed for other work and only ChatGPT connected said "Task for
    /// Claude" (feedback #69). Both or neither keeps Claude, unless only
    /// Codex is here.
    @MainActor @Test func autoIsTheOnePlanConnected() {
        let both = Shell.Found(claude: "/opt/homebrew/bin/claude", codex: "/opt/homebrew/bin/codex", env: [:])
        let codexOnly = Shell.Found(claude: nil, codex: "/opt/homebrew/bin/codex", env: [:])
        let claudeOnly = Shell.Found(claude: "/opt/homebrew/bin/claude", codex: nil, env: [:])
        #expect(Agents.preferred(connected: ["codex"], found: both) == "codex")
        #expect(AgentSetupModel.name(Agents.preferred(connected: ["codex"], found: both)) == "ChatGPT")
        #expect(Agents.preferred(connected: ["claude"], found: both) == "claude")
        #expect(Agents.preferred(connected: ["claude", "codex"], found: both) == "claude")
        #expect(Agents.preferred(connected: [], found: both) == "claude")
        #expect(Agents.preferred(connected: [], found: codexOnly) == "codex")
        #expect(Agents.preferred(connected: ["claude", "codex"], found: codexOnly) == "codex")
        // Connected, then taken off this Mac: as if it never was.
        #expect(Agents.preferred(connected: ["claude"], found: codexOnly) == "codex")
        #expect(Agents.preferred(connected: ["codex"], found: claudeOnly) == "claude")
        // Not looked for yet: what is connected still counts.
        #expect(Agents.preferred(connected: ["codex"], found: nil) == "codex")
        #expect(Agents.preferred(connected: [], found: nil) == "claude")
        // A test world standing in for a Mac with only Codex on it.
        #expect(Agents.preferred(connected: ["claude"], found: both, codexFirst: true) == "codex")
        #expect(Agents.preferred(connected: [], found: claudeOnly, codexFirst: true) == "claude")
    }

    /// Get to Know's line lowers a step's first letter, never a name's.
    @MainActor @Test func gettingToKnowYouKeepsTheNamesCapital() {
        let session = Agents.Session(id: "k", cli: "claude", name: "Claude", prompt: "", state: .running)
        #expect(MemoryKnowing.line(session) == "Getting to know you: Claude is working")
        session.now = "open \u{00B7} linkedin.com"
        #expect(MemoryKnowing.line(session) == "Getting to know you: opening linkedin.com")
    }

    @MainActor @Test func eachStateSaysWhatItIsDoing() {
        let looking = AgentsIntro.words(flow: nil, ready: false, anyInstalled: false, chosen: [])
        #expect(looking.detail == "Checking this Mac…")
        #expect(looking.button == "Connect" && !looking.enabled && !looking.ring)

        let idle = AgentsIntro.words(flow: nil)
        #expect(idle.title == "Choose your AI provider")
        #expect(idle.button == "Connect Claude" && idle.enabled && !idle.cancel && !idle.ring)

        let preparing = AgentsIntro.words(flow: .preparing(["claude"]))
        #expect(preparing.title == "Connecting Claude")
        #expect(preparing.detail == "Checking it on this Mac…")
        #expect(preparing.button == "Connecting…" && !preparing.enabled && preparing.cancel && preparing.ring)
        #expect(AgentsIntro.words(flow: .preparing(["claude", "codex"])).title == "Connecting Claude and ChatGPT")

        let installing = AgentsIntro.words(flow: .installing("claude"))
        #expect(installing.title == "Setting up Claude")
        #expect(installing.button == "Setting Up…" && !installing.enabled && installing.cancel && installing.ring)
        #expect(AgentsIntro.words(flow: .installing("claude"), slow: true).detail
                == "Still downloading. A slow connection can take a few minutes.")
        let byHand = AgentsIntro.words(flow: .installing("claude"), byHand: true)
        #expect(byHand.title == "Set up Claude in Terminal")
        #expect(byHand.button == "Waiting for Terminal…" && !byHand.enabled && byHand.cancel)

        let opening = AgentsIntro.words(flow: .signingIn("claude"), page: .opening)
        #expect(opening.title == "Sign in to Claude" && opening.detail == "Opening the sign-in…")
        #expect(opening.button == "Opening Sign-In…" && !opening.enabled && opening.cancel && opening.ring)

        let inYab = AgentsIntro.words(flow: .signingIn("claude"), page: .yab)
        #expect(inYab.detail == "The sign-in is in a Pane tab. Pane closes it and carries on once you say yes there.")
        #expect(inYab.button == "Show Sign-In" && inYab.enabled && inYab.shows && inYab.cancel)

        let chrome = AgentsIntro.words(flow: .signingIn("codex"), page: .browser("Chrome"))
        #expect(chrome.title == "Sign in to ChatGPT in Chrome")
        #expect(chrome.detail == "ChatGPT opened its sign-in in Chrome. Say yes there, then come back; Pane carries on by itself.")
        #expect(chrome.button == "Open Sign-In Again" && chrome.enabled && chrome.shows && chrome.cancel)
        #expect(AgentsIntro.words(flow: .signingIn("codex"), page: .browser(nil)).title == "Sign in to ChatGPT in your browser")

        let finishing = AgentsIntro.words(flow: .finishing(["claude"]))
        #expect(finishing.title == "Connecting Claude")
        #expect(finishing.detail == "Signed in. Adding Pane's skill and tools…")
        #expect(finishing.button == "Connecting…" && !finishing.enabled && !finishing.cancel && finishing.ring)

        let landed = AgentsIntro.words(flow: .landed(["claude"]))
        #expect(landed.title == "Claude is connected" && landed.button == nil && landed.tick && !landed.ring)
        #expect(AgentsIntro.words(flow: .landed(["claude", "codex"])).title == "Claude and ChatGPT are connected")
    }

    @MainActor @Test func aTroubleOffersTheSameAgain() {
        let trouble = AgentSetupModel.Trouble(clis: ["claude"], words: AgentSetupModel.closed)
        let again = AgentsIntro.words(flow: nil, trouble: trouble)
        #expect(again.title == "Choose your AI provider")
        #expect(again.button == "Try Again" && again.enabled && !again.ring && !again.cancel)
        // Another agent picked since: its own Connect.
        #expect(AgentsIntro.words(flow: nil, chosen: ["codex"], trouble: trouble).button == "Connect ChatGPT")
        // Gone from this Mac since: Connect, which sets it up again.
        #expect(AgentsIntro.words(flow: nil, anyInstalled: false, chosen: [], trouble: trouble).button == "Choose a Provider")
        #expect(AgentSetupModel.gone("claude") == "Claude isn't set up on this Mac anymore.")
        #expect(AgentSetupModel.refused("codex") == "ChatGPT wasn't signed in.")
        #expect(AgentSetupModel.untaken(["claude", "codex"]) == "Pane couldn't add its tools for Claude and ChatGPT.")
    }

    @MainActor @Test func aRenewSaysItsStepsInItsRow() {
        #expect(Renewal.of(.preparing(["claude"]), page: nil) == Renewal(detail: "Checking the sign-in…", wheel: true))
        #expect(Renewal.of(.signingIn("claude"), page: .opening) == Renewal(detail: "Opening the sign-in…", wheel: true, cancel: true))
        #expect(Renewal.of(.signingIn("claude"), page: .yab) == Renewal(detail: "Sign in to Claude in the Pane tab", show: "Show", cancel: true))
        #expect(Renewal.of(.signingIn("codex"), page: .browser("Chrome"))
                == Renewal(detail: "Sign in to ChatGPT in Chrome", show: "Open Again", cancel: true))
        #expect(Renewal.of(.finishing(["claude"]), page: nil) == Renewal(detail: "Signed in. Reconnecting…", wheel: true))
        #expect(Renewal.of(nil, page: nil) == nil)
        #expect(Renewal.of(.landed(["claude"]), page: nil) == nil)
    }

    @MainActor @Test func theSignInTabSaysWhoseItIs() {
        let connect = AgentDock.signInWords("claude", privately: false)
        #expect(connect.title == "Sign in to connect Claude")
        #expect(connect.detail == "Say yes to Claude Code, which Pane runs for you. Pane then closes this tab.")
        let another = AgentDock.signInWords("claude", privately: true)
        #expect(another.title == "Sign in to your other Claude account")
        #expect(another.detail == "A private tab, so your usual account doesn't answer")
    }

    @MainActor @Test func getToKnowSaysWhatItDoesBeforeThePress() {
        #expect(KnowStep.detail == "It reads the sites you're signed in to, once, out of sight.")
        #expect(KnowStep.foot == "About ten minutes, in a shut folder at the end of your tabs. Nothing is sent or bought.")
    }

    /// The state is set before anything runs, so a second press, Return
    /// again or Models' Sign In, finds Connect busy and does nothing.
    @MainActor @Test func aSecondPressWhilePreparingIsNothing() {
        let setup = AgentSetupModel.shared
        let id = UUID()
        defer { try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json")) }
        let browser = Browser(windowID: id)
        setup.cancel()
        setup.connect(["claude"], browser)
        #expect(setup.flow == .preparing(["claude"]))
        #expect(setup.busy && setup.trouble == nil)
        setup.connect(["codex"], browser)
        setup.install("codex", browser)
        #expect(setup.flow == .preparing(["claude"]))
        // Canceled before its first step ran: nothing runs at all.
        setup.cancel()
        #expect(setup.flow == nil && setup.page == nil && setup.renewing == nil && !setup.slow)
    }
}
