import Foundation

enum BoostCLI {
    private static var attached: (socket: String, id: String)?
    private static func detach() { if let attached { _ = Wire.ask(attached.socket, ["do": "agent-detach", "session": attached.id]); self.attached = nil } }
    private static func fail(_ text: String, code: Int32 = 1) -> Never {
        detach()
        FileHandle.standardError.write(Data((text + "\n").utf8)); exit(code)
    }
    static func run(_ args: [String]) -> Never {
        let socket = Wire.socket(args)
        var words = args
        if let i = words.firstIndex(of: "--socket") { words.removeSubrange(i..<min(i + 2, words.count)) }
        guard let plugin = words.first else { fail("usage: \(AgentSetup.command) PLUGIN [TOOL] [JSON or --argument VALUE] [--json] [--socket PATH]", code: 2) }
        guard Wire.allowed else { fail(Wire.offline()) }
        let attached = Wire.ask(socket, ["do": "agent-attach", "name": "Plugin CLI"])
        guard let session = attached["session"] as? String else { fail(attached["error"] as? String ?? "Could not attach.") }
        self.attached = (socket, session)
        let catalog = Wire.ask(socket, ["do": "agent-boosts", "session": session])["boosts"] as? [[String: Any]] ?? []
        guard let record = catalog.first(where: { $0["name"] as? String == plugin && $0["enabled"] as? Bool == true }),
              let host = (record["sites"] as? [String])?.first else { fail("No enabled plugin named \(plugin).") }
        let opened = Wire.ask(socket, ["do": "agent-browse", "url": "https://" + host + "/", "session": session])
        if let error = opened["error"] as? String { fail(error) }
        guard words.count >= 2 else {
            let result = Wire.ask(socket, ["do": "agent-plugin-tools", "session": session])
            print(BoostScript.json(result)); detach(); exit(0)
        }
        let toolName = plugin + "." + words[1].replacingOccurrences(of: "-", with: "_")
        let tools = Wire.ask(socket, ["do": "agent-plugin-tools", "session": session])["tools"] as? [[String: Any]] ?? []
        guard let tool = tools.first(where: { $0["name"] as? String == toolName }), let schema = tool["inputSchema"] as? [String: Any] else { fail("No available tool named " + toolName) }
        let arguments: [String: Any]
        do { arguments = try parse(Array(words.dropFirst(2)), schema: schema) }
        catch { fail(error.localizedDescription, code: 2) }
        let request: [String: Any] = ["do": "agent-plugin-call", "session": session, "name": toolName,
                                    "arguments": arguments, "requestID": UUID().uuidString]
        let deadline = Date().addingTimeInterval(600)
        repeat {
            let result = Wire.ask(socket, request)
            if result["asking"] as? Bool == true {
                fputs("Waiting for approval in \(Brand.name).\n", stderr); Thread.sleep(forTimeInterval: 1); continue
            }
            print(BoostScript.json(result)); detach(); exit(result["error"] == nil ? 0 : 1)
        } while Date() < deadline
        fail("Approval timed out; the tool was not run.", code: 3)
    }
    static func parse(_ words: [String], schema: [String: Any]) throws -> [String: Any] {
        let tokens = words.filter { $0 != "--json" }
        if tokens.count == 1, tokens[0].hasPrefix("{") {
            guard let object = try JSONSerialization.jsonObject(with: Data(tokens[0].utf8)) as? [String: Any] else { throw BoostPackage.Invalid("Arguments must be a JSON object.") }
            return object
        }
        let properties = schema["properties"] as? [String: [String: Any]] ?? [:]
        var arguments: [String: Any] = [:], index = 0
        while index < tokens.count {
            let flag = tokens[index]
            guard flag.hasPrefix("--") else { throw BoostPackage.Invalid("Expected --argument VALUE or one JSON object.") }
            let key = String(flag.dropFirst(2)).replacingOccurrences(of: "-", with: "_")
            guard arguments[key] == nil, let type = properties[key]?["type"] as? String else { throw BoostPackage.Invalid("Unknown or repeated argument: " + key) }
            index += 1
            if type == "boolean", index == tokens.count || tokens[index].hasPrefix("--") { arguments[key] = true; continue }
            guard index < tokens.count else { throw BoostPackage.Invalid("Missing value for " + key) }
            let value = tokens[index]; index += 1
            if type == "string" { arguments[key] = value }
            else {
                guard let parsed = try? JSONSerialization.jsonObject(with: Data(value.utf8), options: [.fragmentsAllowed]) else { throw BoostPackage.Invalid("Supply a JSON " + type + " for " + key) }
                arguments[key] = parsed
            }
        }
        return arguments
    }

}
