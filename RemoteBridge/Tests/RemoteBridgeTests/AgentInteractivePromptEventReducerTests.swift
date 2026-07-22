import XCTest
@testable import RemoteBridge

final class AgentInteractivePromptEventReducerTests: XCTestCase {
    func testPendingPromptIsFilteredWhenReplayContainsResolvedForSamePrompt() {
        let pending = Self.prompt(sessionID: "session-1", promptID: "prompt-1", seq: 1)
        let resolved = Self.resolved(sessionID: "session-1", promptID: "prompt-1", seq: 2)

        let filtered = AgentInteractivePromptEventReducer.pendingEvents([pending],
                                                                        excludingResolvedIn: [resolved])

        XCTAssertTrue(filtered.isEmpty)
    }

    func testPendingPromptForDifferentSessionSurvivesResolvedReplay() {
        let pending = Self.prompt(sessionID: "session-2", promptID: "prompt-1", seq: 1)
        let resolved = Self.resolved(sessionID: "session-1", promptID: "prompt-1", seq: 2)

        let filtered = AgentInteractivePromptEventReducer.pendingEvents([pending],
                                                                        excludingResolvedIn: [resolved])

        XCTAssertEqual(filtered.map(\.eventID), [pending.eventID])
    }

    func testMergedEventsDedupesByEventIDAndSorts() {
        let first = Self.prompt(sessionID: "session-1", promptID: "prompt-1", seq: 2)
        let duplicate = Self.prompt(sessionID: "session-1", promptID: "prompt-1", seq: 3)
        let second = Self.prompt(sessionID: "session-1", promptID: "prompt-2", seq: 1)

        let merged = AgentInteractivePromptEventReducer.mergedEvents([first, second], [duplicate])

        XCTAssertEqual(merged.map(\.eventID), [second.eventID, first.eventID])
    }

    func testResolvedLifecycleOnlyFiltersPendingEventWithMatchingToken() {
        let pendingA = Self.prompt(sessionID: "session-1", promptID: "prompt-1", seq: 1,
                                   token: "token-A", eventID: "pending-A")
        let pendingB = Self.prompt(sessionID: "session-1", promptID: "prompt-1", seq: 2,
                                   token: "token-B", eventID: "pending-B")
        let resolvedA = Self.resolved(sessionID: "session-1", promptID: "prompt-1", seq: 3, token: "token-A")

        let filtered = AgentInteractivePromptEventReducer.pendingEvents([pendingA, pendingB],
                                                                        excludingResolvedIn: [resolvedA])

        XCTAssertEqual(filtered.map(\.eventID), [pendingB.eventID])
    }

    func testCapabilityTokenlessTerminalDoesNotSuppressPendingPrompt() {
        let pending = Self.prompt(sessionID: "session-1", promptID: "prompt-1", seq: 1, token: nil)
        let resolved = Self.resolved(sessionID: "session-1", promptID: "prompt-1", seq: 2, token: nil)

        let filtered = AgentInteractivePromptEventReducer.pendingEvents([pending],
                                                                        excludingResolvedIn: [resolved])

        XCTAssertEqual(filtered.map(\.eventID), [pending.eventID])
    }

    func testLegacyResolvedEventOnlySuppressesOlderPendingLifecycle() {
        let oldPending = Self.prompt(sessionID: "session-1", promptID: "prompt-1", seq: 1,
                                     token: nil, vendor: "claude", eventID: "legacy-old")
        let resolved = Self.resolved(sessionID: "session-1", promptID: "prompt-1", seq: 2,
                                     token: nil, vendor: "claude")
        let newPending = Self.prompt(sessionID: "session-1", promptID: "prompt-1", seq: 3,
                                     token: nil, vendor: "claude", eventID: "legacy-new")

        let filtered = AgentInteractivePromptEventReducer.pendingEvents([oldPending, newPending],
                                                                        excludingResolvedIn: [resolved])

        XCTAssertEqual(filtered.map(\.eventID), [newPending.eventID])
    }

    private static func prompt(sessionID: String,
                               promptID: String,
                               seq: Int,
                               token: String? = "token-prompt",
                               vendor: String = "codex",
                               eventID: String? = nil) -> AgentEvent {
        event(type: .interactivePrompt,
              eventID: eventID ?? "prompt-\(promptID)",
              sessionID: sessionID,
              promptID: promptID,
              seq: seq,
              token: token,
              vendor: vendor)
    }

    private static func resolved(sessionID: String,
                                 promptID: String,
                                 seq: Int,
                                 token: String? = "token-prompt",
                                 vendor: String = "codex") -> AgentEvent {
        event(type: .interactivePromptResolved,
              eventID: "resolved-\(promptID)",
              sessionID: sessionID,
              promptID: promptID,
              seq: seq,
              token: token,
              vendor: vendor)
    }

    private static func event(type: AgentEventKind,
                              eventID: String,
                              sessionID: String,
                              promptID: String,
                              seq: Int,
                              token: String?,
                              vendor: String = "codex") -> AgentEvent {
        var metadata = [
            "prompt_id": promptID,
            "panel_id": "panel-1",
        ]
        if let token {
            metadata["lifecycle_token"] = token
        }
        return AgentEvent(eventID: eventID,
                   seq: seq,
                   vendor: vendor,
                   workspaceID: "workspace-1",
                   sessionID: sessionID,
                   timestamp: "2026-06-07T00:00:00.000Z",
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
