import XCTest
@testable import HeadlessCodexTerminalSupport

final class HeadlessCodexTerminalRendererTests: XCTestCase {
    func testRendersUserAndAssistantMessagesOnce() throws {
        let renderer = HeadlessCodexTerminalRenderer()
        let user = try envelope(eventID: "u1", type: "user_message", text: "hello")
        let assistant = try envelope(eventID: "a1", type: "assistant_message", text: "Hi.")

        XCTAssertEqual(renderer.render(envelope: user), [.line("> hello")])
        XCTAssertEqual(renderer.render(envelope: assistant), [.line("Hi.")])
        XCTAssertEqual(renderer.render(envelope: assistant), [])
    }

    func testRendersTerminalStreamAsRawOutput() throws {
        let renderer = HeadlessCodexTerminalRenderer()
        let stream = try envelope(eventID: "t1",
                                  type: "tool_result",
                                  name: "terminal_stream",
                                  output: "line 1\n")

        XCTAssertEqual(renderer.render(envelope: stream), [.raw("line 1\n")])
    }

    func testRendersApprovalPromptAndResolvedState() throws {
        let renderer = HeadlessCodexTerminalRenderer()
        let prompt = try envelope(eventID: "p1",
                                  type: "interactive_prompt",
                                  text: "Approve command?")
        let resolved = try envelope(eventID: "p2",
                                    type: "interactive_prompt_resolved",
                                    metadata: ["decision": "decline"])

        XCTAssertEqual(renderer.render(envelope: prompt), [
            .line("[approval requested]"),
            .line("Approve command?"),
        ])
        XCTAssertEqual(renderer.render(envelope: resolved), [.line("[approval decline]")])
    }

    private func envelope(eventID: String,
                          type: String,
                          text: String? = nil,
                          name: String? = nil,
                          input: String? = nil,
                          output: String? = nil,
                          metadata: [String: String]? = nil) throws -> HeadlessCodexTerminalEventEnvelope {
        var event: [String: Any] = [
            "event_id": eventID,
            "seq": 1,
            "vendor": "codex",
            "workspace_id": "headless-workspace",
            "session_id": "headless-session",
            "timestamp": "2026-06-06T00:00:00Z",
            "type": type,
        ]
        if let text {
            event["text"] = text
        }
        if let name {
            event["name"] = name
        }
        if let input {
            event["input"] = input
        }
        if let output {
            event["output"] = output
        }
        if let metadata {
            event["metadata"] = metadata
        }
        let object: [String: Any] = [
            "type": "agent_event",
            "v": 1,
            "replay": false,
            "event": event,
        ]
        let data = try JSONSerialization.data(withJSONObject: object)
        return try JSONDecoder().decode(HeadlessCodexTerminalEventEnvelope.self, from: data)
    }
}
