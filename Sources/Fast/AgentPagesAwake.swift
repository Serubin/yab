import Foundation

// How many of the agents' own pages are awake at once.
//
// Every `open` an agent makes is a tab of its own, drawn as if on screen
// (Bench.house), and an agent rarely closes one. Three agents at once
// (evals/agent-swarm: three `yab mcp`s, four minutes) left 138 tabs awake
// and 13.8 GB in their pages; one person's three subagents reached 39 GB
// and froze Yab (2026-10-22). So past a few, opening one more puts the
// longest unused of them to sleep, as any tab sleeps: its picture kept,
// loaded again at the same address when the agent reads it next, and the
// agent told then (StuckWatch.notices, said with its next look).

extension Browser {
    /// A quarter of the Mac's memory in GB, between 6 and 16 tabs, or
    /// `agents.awake` for the bench.
    static var agentPagesAwake: Int {
        let set = Store.settings.integer(forKey: "agents.awake")
        if set > 0 { return set }
        let gb = Int(ProcessInfo.processInfo.physicalMemory >> 30)
        return min(max(gb / 4, 6), 16)
    }

    /// Worked in this lately, never put to sleep: an agent between two
    /// calls on it.
    nonisolated static let agentPageBusy: TimeInterval = 20

    /// After `opened`, the agents' pages past `agentPagesAwake` to sleep,
    /// the longest unused first.
    func keepAgentPagesFew(opened: Tab) {
        let now = Date()
        let awake = everyTab.filter { $0.bench && $0 !== opened && $0.builtPage != nil && !$0.asleep && !$0.gone }
        let over = awake.count + 1 - Self.agentPagesAwake
        guard over > 0 else { return }
        let idle = awake
            .filter { now.timeIntervalSince($0.touched) > Self.agentPageBusy }
            .sorted { $0.touched < $1.touched }
        for tab in idle.prefix(over) {
            // A bench tab and one still loading go too: a page that never
            // finishes loading is exactly one that grows.
            sleep(tab, waiving: ["a bench tab", "still loading"]) { said in
                guard said == "asleep" else { return }
                StuckWatch.notices[tab.id] = "\(Brand.name) put this tab to sleep to save memory while more agent tabs were open, and loaded it again at the same address: what you did on it before is gone, read it again. Close tabs you are done with."
            }
        }
    }
}
