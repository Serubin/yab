import Foundation

// One tool of `yab mcp`, whole: its name, what it does to the world, its
// words and arguments, who it is listed for, who it refuses, and what a
// call does. Mcp.registry holds them all, and tools/list, the annotations,
// the refusals and the calls are all read from it, so a tool is said once.

struct McpTool {
    typealias Handler = (_ name: String, _ input: [String: Any], _ tab: String?) -> [String: Any]

    let name: String
    let hint: Mcp.Hint
    let description: String
    /// Words after the description that depend on the audience.
    let more: ((Mcp.Audience) -> String)?
    let properties: [String: Any]
    let required: [String]
    /// Hidden from a context_explorer, and refused if it calls it anyway.
    let acts: Bool
    /// One of the few an iPhone task may call.
    let phone: Bool
    /// Listed for a subagent.
    let subs: Bool
    /// Listed only when this holds.
    let when: (Mcp.Audience) -> Bool
    /// Why a call is refused, past what `acts` and `phone` say.
    let refuse: ((Mcp.Audience, [String: Any]) -> String?)?
    let handler: Handler

    init(_ name: String, _ hint: Mcp.Hint, _ description: String, _ properties: [String: Any] = [:], required: [String] = [],
         more: ((Mcp.Audience) -> String)? = nil,
         acts: Bool = false, phone: Bool = false, subs: Bool = true,
         when: @escaping (Mcp.Audience) -> Bool = { _ in true },
         refuse: ((Mcp.Audience, [String: Any]) -> String?)? = nil,
         call handler: @escaping Handler) {
        self.name = name
        self.hint = hint
        self.description = description
        self.more = more
        self.properties = properties
        self.required = required
        self.acts = acts
        self.phone = phone
        self.subs = subs
        self.when = when
        self.refuse = refuse
        self.handler = handler
    }

    /// Offered to `a` only when a call from it would not be refused: a
    /// tool listed and then refused is a tool an agent wastes a turn on.
    func listed(for a: Mcp.Audience) -> Bool {
        guard when(a), subs || !a.sub else { return false }
        return Mcp.phoneRefusal(name, a) == nil && Mcp.refusal(name, [:], a) == nil
    }

    /// As tools/list says it.
    func definition(for a: Mcp.Audience) -> [String: Any] {
        Mcp.tool(name, description + (more?(a) ?? ""), properties, required: required)
    }

    /// Why a call is refused for what it was given: an argument this tool
    /// doesn't take (`file` for mail_file's `name`), said with the ones it
    /// does, so the next call gets them right instead of failing on what
    /// was never read. `tab` may go to any tool, and a client's own
    /// `_meta`-like keys are let be. Nil when every one is known.
    func strangers(_ input: [String: Any]) -> String? {
        let odd = input.keys.filter { properties[$0] == nil && $0 != "tab" && !$0.hasPrefix("_") }.sorted()
        guard !odd.isEmpty else { return nil }
        let names = odd.map { "`\($0)`" }.joined(separator: ", ")
        let what = odd.count == 1 ? "no argument \(names)" : "no arguments \(names)"
        guard !properties.isEmpty else { return "\(name) has \(what): it takes none." }
        let ordered = required.filter { properties[$0] != nil } + properties.keys.filter { !required.contains($0) }.sorted()
        let takes = ordered.map { required.contains($0) ? "\($0) (required)" : $0 }.joined(separator: ", ")
        return "\(name) has \(what); it takes \(takes)."
    }

    // MARK: - refusals said once

    static func subagentsCantAsk(_ a: Mcp.Audience, _ input: [String: Any]) -> String? {
        a.sub ? "a subagent can't ask the user; report it to the parent" : nil
    }

    static func subagentsCantSend(_ a: Mcp.Audience, _ input: [String: Any]) -> String? {
        a.sub ? "a subagent can't send in the person's name; report what to send to the parent" : nil
    }

    static func subagentsCantChange(_ a: Mcp.Audience, _ input: [String: Any]) -> String? {
        a.sub ? "A subagent cannot change native \(Brand.name) state; report the proposed change to its parent" : nil
    }

    static func explorers(_ name: String) -> String {
        "A context_explorer only reads: \(name) isn't yours to use. Say what needs doing in your report."
    }
}
