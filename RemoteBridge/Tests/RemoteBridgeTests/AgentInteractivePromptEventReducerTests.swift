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

    private static func prompt(sessionID: String, promptID: String, seq: Int) -> AgentEvent {
        event(type: .interactivePrompt,
              eventID: "prompt-\(promptID)",
              sessionID: sessionID,
              promptID: promptID,
              seq: seq)
    }

    private static func resolved(sessionID: String, promptID: String, seq: Int) -> AgentEvent {
        event(type: .interactivePromptResolved,
              eventID: "resolved-\(promptID)",
              sessionID: sessionID,
              promptID: promptID,
              seq: seq)
    }

    private static func event(type: AgentEventKind,
                              eventID: String,
                              sessionID: String,
                              promptID: String,
                              seq: Int) -> AgentEvent {
        AgentEvent(eventID: eventID,
                   seq: seq,
                   vendor: "codex",
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
                   metadata: [
                    "prompt_id": promptID,
                    "panel_id": "panel-1",
                   ])
    }
}
