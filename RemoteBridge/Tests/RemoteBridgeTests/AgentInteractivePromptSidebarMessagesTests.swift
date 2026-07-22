import XCTest
@testable import RemoteBridge

final class AgentInteractivePromptSidebarMessagesTests: XCTestCase {
    func testInteractivePromptCreatesNotificationAndPromptShellState() {
        let event = Self.promptEvent(vendor: "claude",
                                     title: "Choose deployment target",
                                     body: "Pick the environment to deploy.")

        let messages = AgentInteractivePromptSidebarMessages.messages(for: event,
                                                                      workspaceID: "workspace-1")

        XCTAssertEqual(messages.count, 2)
        XCTAssertTrue(messages[0].contains(#""action":"notification.create""#))
        XCTAssertTrue(messages[0].contains(#""workspace_id":"workspace-1""#))
        XCTAssertTrue(messages[0].contains(#""title":"Claude Code""#))
        XCTAssertTrue(messages[0].contains("Choose deployment target: Pick the environment to deploy."))
        XCTAssertEqual(messages[1], "report_shell_state needs_input --workspace_id=workspace-1")
    }

    func testResolvedPromptClearsPromptShellState() {
        let event = AgentEvent(eventID: "resolved-prompt-1",
                               seq: 1,
                               vendor: "codex",
                               workspaceID: "workspace-1",
                               sessionID: "session-1",
                               timestamp: "2026-06-20T00:00:00.000Z",
                               type: .interactivePromptResolved,
                               role: nil,
                               text: "Approve command?",
                               name: nil,
                               input: nil,
                               output: nil,
                               toolCallID: nil,
                               metadata: [
                                "prompt_id": "prompt-1",
                               ])

        XCTAssertEqual(AgentInteractivePromptSidebarMessages.messages(for: event,
                                                                      workspaceID: "workspace-1"),
                       ["report_shell_state running --workspace_id=workspace-1"])
    }

    func testPromptIDCanComeFromMetadataOrPayload() {
        let metadataEvent = Self.promptEvent(promptID: "metadata-prompt")
        XCTAssertEqual(AgentInteractivePromptSidebarMessages.promptID(from: metadataEvent),
                       "metadata-prompt")

        let payloadEvent = Self.promptEvent(promptID: nil,
                                            payloadPromptID: "payload-prompt")
        XCTAssertEqual(AgentInteractivePromptSidebarMessages.promptID(from: payloadEvent),
                       "payload-prompt")
    }

    private static func promptEvent(promptID: String? = "prompt-1",
                                    payloadPromptID: String? = "prompt-1",
                                    vendor: String = "codex",
                                    title: String = "Approve command?",
                                    body: String = "Command: make test") -> AgentEvent {
        var metadata = [String: String]()
        if let promptID {
            metadata["prompt_id"] = promptID
        }
        var payload: [String: JSONValue] = [
            "title": .string(title),
            "body": .string(body),
        ]
        if let payloadPromptID {
            payload["prompt_id"] = .string(payloadPromptID)
        }
        return AgentEvent(eventID: "prompt-\(promptID ?? payloadPromptID ?? "unknown")",
                          seq: 1,
                          vendor: vendor,
                          workspaceID: "workspace-1",
                          sessionID: "session-1",
                          timestamp: "2026-06-20T00:00:00.000Z",
                          type: .interactivePrompt,
                          role: nil,
                          text: title,
                          name: nil,
                          input: nil,
                          output: nil,
                          toolCallID: nil,
                          metadata: metadata,
                          payload: .object(payload))
    }
}
