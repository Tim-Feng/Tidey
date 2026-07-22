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

    func testCapabilityTokenRotationKeepsCurrentAttemptUntilMatchingTerminal() {
        let deduper = AgentInteractivePromptNotificationDeduper()
        let promptA = Self.lifecycleEvent(eventID: "prompt-a",
                                          seq: 1,
                                          type: .interactivePrompt,
                                          vendor: "codex",
                                          lifecycleToken: "token-a")
        let promptB = Self.lifecycleEvent(eventID: "prompt-b",
                                          seq: 2,
                                          type: .interactivePrompt,
                                          vendor: "codex",
                                          lifecycleToken: "token-b")
        let resolvedA = Self.lifecycleEvent(eventID: "resolved-a",
                                            seq: 3,
                                            type: .interactivePromptResolved,
                                            vendor: "codex",
                                            lifecycleToken: "token-a")
        let resolvedB = Self.lifecycleEvent(eventID: "resolved-b",
                                            seq: 4,
                                            type: .interactivePromptResolved,
                                            vendor: "codex",
                                            lifecycleToken: "token-b")

        XCTAssertTrue(deduper.shouldNotify(promptA, sessionID: "session-1"))
        XCTAssertFalse(deduper.shouldNotify(promptA, sessionID: "session-1"))
        XCTAssertTrue(deduper.shouldNotify(promptB, sessionID: "session-1"),
                      "a new capability token is a new attempt even when prompt_id is unchanged")
        XCTAssertEqual(deduper.markResolved(resolvedA, sessionID: "session-1"), .staleMismatch)
        XCTAssertFalse(deduper.shouldNotify(promptB, sessionID: "session-1"),
                       "a stale terminal must not clear the current attempt")
        XCTAssertEqual(deduper.markResolved(resolvedB, sessionID: "session-1"), .clearedNotified)
        XCTAssertEqual(deduper.markResolved(resolvedB, sessionID: "session-1"), .noneNotified)
    }

    func testCapabilityTokenlessLifecycleFailsClosed() {
        let deduper = AgentInteractivePromptNotificationDeduper()
        let tokenPrompt = Self.lifecycleEvent(eventID: "prompt-token",
                                              seq: 1,
                                              type: .interactivePrompt,
                                              vendor: "codex",
                                              lifecycleToken: "token-a")
        let tokenlessPrompt = Self.lifecycleEvent(eventID: "prompt-tokenless",
                                                  seq: 2,
                                                  type: .interactivePrompt,
                                                  vendor: "codex")
        let tokenlessTerminal = Self.lifecycleEvent(eventID: "resolved-tokenless",
                                                    seq: 3,
                                                    type: .interactivePromptResolved,
                                                    vendor: "codex")
        let matchingTerminal = Self.lifecycleEvent(eventID: "resolved-token",
                                                   seq: 4,
                                                   type: .interactivePromptResolved,
                                                   vendor: "codex",
                                                   lifecycleToken: "token-a")

        XCTAssertTrue(deduper.shouldNotify(tokenPrompt, sessionID: "session-1"))
        XCTAssertFalse(deduper.shouldNotify(tokenlessPrompt, sessionID: "session-1"),
                       "a malformed capability delivery must not replace a token-bound attempt")
        XCTAssertEqual(deduper.markResolved(tokenlessTerminal, sessionID: "session-1"), .staleMismatch)
        XCTAssertFalse(deduper.shouldNotify(tokenPrompt, sessionID: "session-1"))
        XCTAssertEqual(deduper.markResolved(matchingTerminal, sessionID: "session-1"), .clearedNotified)

        XCTAssertTrue(deduper.shouldNotify(tokenlessPrompt, sessionID: "session-1"))
        XCTAssertEqual(deduper.markResolved(tokenlessTerminal, sessionID: "session-1"), .staleMismatch,
                       "a capability lifecycle without proof cannot be terminalized by prompt_id alone")
        XCTAssertFalse(deduper.shouldNotify(tokenlessPrompt, sessionID: "session-1"))
    }

    func testLegacyLifecycleIgnoresUnknownAndDuplicateTerminals() {
        let deduper = AgentInteractivePromptNotificationDeduper()
        let prompt1 = Self.lifecycleEvent(eventID: "legacy-prompt-1",
                                          seq: 1,
                                          type: .interactivePrompt,
                                          vendor: "claude")
        let prompt2 = Self.lifecycleEvent(eventID: "legacy-prompt-2",
                                          seq: 2,
                                          type: .interactivePrompt,
                                          vendor: "claude")
        let unknown = Self.lifecycleEvent(eventID: "legacy-unknown",
                                          seq: 3,
                                          type: .interactivePromptResolved,
                                          vendor: "claude",
                                          promptID: "other-prompt")
        let resolved = Self.lifecycleEvent(eventID: "legacy-resolved",
                                           seq: 4,
                                           type: .interactivePromptResolved,
                                           vendor: "claude")

        XCTAssertTrue(deduper.shouldNotify(prompt1, sessionID: "session-1"))
        XCTAssertFalse(deduper.shouldNotify(prompt2, sessionID: "session-1"),
                       "legacy delivery identity remains session + prompt_id")
        XCTAssertEqual(deduper.markResolved(unknown, sessionID: "session-1"), .noneNotified)
        XCTAssertEqual(deduper.markResolved(resolved, sessionID: "session-1"), .clearedNotified)
        XCTAssertEqual(deduper.markResolved(resolved, sessionID: "session-1"), .noneNotified)
        XCTAssertTrue(deduper.shouldNotify(prompt2, sessionID: "session-1"),
                      "a delivery after the terminal starts a new legacy lifecycle")
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

    private static func lifecycleEvent(eventID: String,
                                       seq: Int,
                                       type: AgentEventKind,
                                       vendor: String,
                                       lifecycleToken: String? = nil,
                                       promptID: String = "prompt-1") -> AgentEvent {
        var metadata = ["prompt_id": promptID]
        if let lifecycleToken {
            metadata["lifecycle_token"] = lifecycleToken
        }
        return AgentEvent(eventID: eventID,
                          seq: seq,
                          vendor: vendor,
                          workspaceID: "workspace-1",
                          sessionID: "session-1",
                          timestamp: "2026-06-20T00:00:00.000Z",
                          type: type,
                          role: nil,
                          text: nil,
                          name: nil,
                          input: nil,
                          output: nil,
                          toolCallID: nil,
                          metadata: metadata)
    }
}
