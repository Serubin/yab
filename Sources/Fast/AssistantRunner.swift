import Foundation

// Each assistant's calls answered by `yab mcp --assistant ID`, this app's own
// binary, as any agent's are (docs/assistants.md, "The Mac"): the server's
// JSON-RPC line in, the answer out. A few children per assistant, so a long
// wait in one (approval_status, task_status) doesn't hold the rest.

@MainActor
final class AssistantRunner {
    static let shared = AssistantRunner()

    /// At most this many at once for one assistant; more calls wait.
    static let width = 3

    private final class Child {
        let process: Process
        let input: FileHandle
        var partial = Data()
        /// The calls it has been given and not yet answered, by our id.
        var waiting: [Int: (original: Any, done: ([String: Any]?) -> Void)] = [:]
        init(process: Process, input: FileHandle) {
            self.process = process
            self.input = input
        }
        var busy: Int { waiting.count }
    }

    private var children: [String: [Child]] = [:]
    private var sessions: [String: String] = [:]
    private var next = 1

    private init() {}

    /// The attached session the assistant's calls speak for: its tabs, its
    /// folder, its face on them.
    func session(for assistant: String) -> String? {
        guard let grant = Assistants.shared.grant(assistant) else { return nil }
        if let id = sessions[assistant], let known = Agents.shared.session(id), known.state.live {
            known.name = grant.name
            return id
        }
        let made = Agents.shared.attach(name: grant.name)
        made.name = grant.name
        made.assistant = assistant
        sessions[assistant] = made.id
        return made.id
    }

    /// One JSON-RPC message from the assistant; `done` gets the response,
    /// or nil for a notification.
    func call(_ assistant: String, _ body: [String: Any], _ done: @escaping ([String: Any]?) -> Void) {
        let original = body["id"]
        guard let grant = Assistants.shared.grant(assistant) else {
            done(original.map { ["jsonrpc": "2.0", "id": $0, "error": ["code": -32003, "message": "This assistant isn't linked to \(Brand.name) on this Mac any more."]] })
            return
        }
        if grant.paused, body["method"] as? String == "tools/call" {
            let says = "status: paused\nThe user paused \(grant.name) in \(Brand.name) on their Mac, so nothing was done. Ask them to resume it in \(Brand.name) › Settings › AI › Assistants."
            done(original.map { ["jsonrpc": "2.0", "id": $0, "result": Mcp.text(says, error: true)] })
            return
        }
        guard let child = pick(assistant) else {
            done(original.map { ["jsonrpc": "2.0", "id": $0, "error": ["code": -32002, "message": "\(Brand.name) couldn't start its MCP server on the Mac."]] })
            return
        }
        var message = body
        guard let original, !(original is NSNull) else {
            write(message, to: child)
            done(nil)
            return
        }
        let ours = next
        next += 1
        message["id"] = ours
        child.waiting[ours] = (original, done)
        write(message, to: child)
    }

    /// What tools/list and initialize say for this assistant, for the
    /// server to answer with while the Mac is away.
    func listing(_ assistant: String, _ done: @escaping ([[String: Any]], String) -> Void) {
        call(assistant, ["jsonrpc": "2.0", "id": "init", "method": "initialize",
                         "params": ["protocolVersion": "2025-06-18", "clientInfo": ["name": "yab-assist"]]]) { [weak self] begun in
            let instructions = (begun?["result"] as? [String: Any])?["instructions"] as? String ?? ""
            self?.call(assistant, ["jsonrpc": "2.0", "id": "list", "method": "tools/list"]) { listed in
                let tools = (listed?["result"] as? [String: Any])?["tools"] as? [[String: Any]] ?? []
                done(tools, instructions)
            }
        }
    }

    /// Unlinked or paused for good: its children go, its session ends.
    func stop(_ assistant: String) {
        for child in children[assistant] ?? [] { child.process.terminate() }
        children[assistant] = nil
        if let id = sessions.removeValue(forKey: assistant) { Agents.shared.detach(id) }
    }

    // MARK: - children

    private func pick(_ assistant: String) -> Child? {
        var mine = (children[assistant] ?? []).filter(\.process.isRunning)
        children[assistant] = mine
        if let idle = mine.first(where: { $0.busy == 0 }) { return idle }
        if mine.count < Self.width, let made = spawn(assistant) {
            mine.append(made)
            children[assistant] = mine
            return made
        }
        return mine.min { $0.busy < $1.busy }
    }

    private func spawn(_ assistant: String) -> Child? {
        guard let session = session(for: assistant), let binary = Bundle.main.executablePath else { return nil }
        let process = Process()
        process.executableURL = ProcessLaunch.executableURL(binary)
        process.arguments = ["mcp", "--assistant", assistant, "--session", session, "--socket", Store.file("bench.sock").path]
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let child = Child(process: process, input: input.fileHandleForWriting)
        output.fileHandleForReading.readabilityHandler = { [weak self, weak child] handle in
            let data = handle.availableData
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, let child else { return }
                    if data.isEmpty { handle.readabilityHandler = nil; self.ended(child); return }
                    self.heard(data, from: child)
                }
            }
        }
        process.terminationHandler = { [weak self, weak child] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, let child else { return }
                    self.ended(child)
                }
            }
        }
        do { try process.runValidated() } catch { return nil }
        return child
    }

    private func write(_ message: [String: Any], to child: Child) {
        guard var data = try? JSONSerialization.data(withJSONObject: message) else { return }
        data.append(0x0A)
        do { try child.input.write(contentsOf: data) } catch { ended(child) }
    }

    private func heard(_ data: Data, from child: Child) {
        child.partial.append(data)
        while let end = child.partial.firstIndex(of: 0x0A) {
            let line = child.partial[child.partial.startIndex..<end]
            child.partial.removeSubrange(child.partial.startIndex...end)
            guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            if let ours = message["id"] as? Int, let entry = child.waiting.removeValue(forKey: ours) {
                var out = message
                out["id"] = entry.original
                entry.done(out)
            }
            // Its own notifications (tools/list_changed) are for a client
            // that keeps a line open; the server answers each request alone.
        }
    }

    /// A child gone mid-call: what it held is answered as an error.
    private func ended(_ child: Child) {
        for entry in child.waiting.values {
            entry.done(["jsonrpc": "2.0", "id": entry.original, "error": ["code": -32002, "message": "\(Brand.name)'s MCP server on the Mac stopped mid-call. Try again."]])
        }
        child.waiting = [:]
        for (key, list) in children { children[key] = list.filter { $0 !== child } }
    }
}
