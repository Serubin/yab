import Foundation
import Testing
@testable import Fast

@MainActor
struct GeminiToolErrorTests {
    @Test func theRecordedCLIToolErrorShapeIsAcceptedForABrowserHookDenial() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/GeminiRegistry/hook-denial.ndjson")
        // Replay the real CLI's exact ERROR event shape under the browser
        // hook's reason. The original text-only transcript still must fail.
        let recorded = try String(contentsOf: file, encoding: .utf8)
            .replacingOccurrences(of: "Yab text-only chats do not run tools.", with: "Pane gives Gemini only its own browser tools.")
        var stream = GeminiStream(yabTools: true)
        _ = try stream.prompt("The recorded hook probe")
        let events = stream.receive(Data(recorded.utf8)) + stream.end(code: 0)
        #expect(!events.contains { if case .failed = $0 { return true }; return false })
        #expect(events.contains { if case .step(let item) = $0 { return item.name == "run_command" && item.state == .failed }; return false })
        #expect(events.contains { if case .result(let result) = $0 { return result.succeeded }; return false })
    }

    private func step(_ stream: inout GeminiStream, index: Int, state: String, name: String,
                      error: [String: String]? = nil, type: String = "tool") throws -> [GeminiStream.Event] {
        var tool: [String: Any] = ["name": name]
        if let error { tool["error"] = error }
        return stream.receive(try GeminiRunnerTests.line(["event": "step_update", "step_update": [
            "conversation_id": "G1", "step_index": index, "state": state, "step_type": type,
            "tool_name": name, "tool_info": tool]]))
    }

    /// Real agy 1.4.4 hook-denial transcripts use ERROR, not DONE, for
    /// a denied tool. The CLI must be allowed to recover through Pane.
    @Test func nativeErrorDeniedByYabCanRecoverThroughItsBrowserTools() throws {
        var stream = GeminiStream(yabTools: true)
        _ = try stream.prompt("Read the page using Pane")
        _ = try GeminiRunnerTests.initialize(&stream)
        _ = try step(&stream, index: 1, state: "ACTIVE", name: "list_resources")
        let ended = try step(&stream, index: 1, state: "ERROR", name: "list_resources", error: [
            "type": "TOOL_ERROR", "message": "tool call denied by pre-tool hook: Pane gives Gemini only its own browser tools."])
        #expect(!stream.broken)
        #expect(ended.contains { if case .step(let item) = $0 { return item.state == .failed }; return false })
        let browser = try step(&stream, index: 2, state: "DONE", name: GeminiRunnerTests.yabTool)
        #expect(browser.contains { if case .step(let item) = $0 { return item.state == .done }; return false })
        #expect(try GeminiRunnerTests.result(&stream)?.succeeded == true)
        #expect(stream.end(code: 0).isEmpty)
    }

    @Test(arguments: [true, false])
    func aYabToolErrorIsTerminalFailureEvenWithoutAnErrorObject(hasError: Bool) throws {
        var stream = GeminiStream(yabTools: true)
        _ = try stream.prompt("Read the page")
        _ = try GeminiRunnerTests.initialize(&stream)
        let events = try step(&stream, index: 1, state: "ERROR", name: GeminiRunnerTests.yabTool,
                              error: hasError ? ["type": "TOOL_ERROR", "message": "Could not open page"] : nil)
        #expect(!stream.broken, "A valid ERROR tool event must remain a typed failure")
        #expect(events.contains { if case .step(let item) = $0 { return item.state == .failed }; return false })
        #expect(try GeminiRunnerTests.result(&stream)?.succeeded == false)
    }

    @Test func aNativeRecoveryNeverErasesALaterYabToolFailure() throws {
        var stream = GeminiStream(yabTools: true)
        _ = try stream.prompt("Read through Pane")
        _ = try GeminiRunnerTests.initialize(&stream)
        _ = try step(&stream, index: 1, state: "ERROR", name: "list_resources", error: [
            "type": "TOOL_ERROR", "message": "Pane gives Gemini only its own browser tools."])
        _ = try step(&stream, index: 2, state: "ERROR", name: GeminiRunnerTests.yabTool)
        stream.diagnostic("list_resources auto-denied by Pane's pre-tool hook.\n")
        #expect(try GeminiRunnerTests.result(&stream)?.succeeded == false)
    }

    @Test(arguments: ["ERROR", "DONE"])
    func anUnconfirmedNativeTerminalStepStillFailsClosed(state: String) throws {
        var stream = GeminiStream(yabTools: true)
        _ = try stream.prompt("Use Pane only")
        _ = try GeminiRunnerTests.initialize(&stream)
        _ = try step(&stream, index: 1, state: state, name: "run_command",
                     error: state == "ERROR" ? ["type": "TOOL_ERROR", "message": "Unknown error"] : nil)
        #expect(stream.broken)
        #expect(try GeminiRunnerTests.result(&stream) == nil)
    }

    @Test func toolErrorNeverGrantsToolsToATextChat() throws {
        var stream = GeminiStream()
        _ = try stream.prompt("Text only")
        _ = try GeminiRunnerTests.initialize(&stream)
        _ = try step(&stream, index: 1, state: "ERROR", name: "list_resources", error: [
            "type": "TOOL_ERROR", "message": "tool call denied by pre-tool hook: Pane text-only chats do not run tools."])
        #expect(stream.broken)
    }

    @Test(arguments: ["ERROR", "CANCELED", "future-state"])
    func unsupportedResponseStatesRemainInvalid(state: String) throws {
        var stream = GeminiStream()
        _ = try stream.prompt("Answer")
        _ = try GeminiRunnerTests.initialize(&stream)
        _ = try step(&stream, index: 1, state: state, name: "", type: "agent_response")
        #expect(stream.broken)
    }
}
