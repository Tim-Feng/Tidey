import XCTest
@testable import RemoteBridge

final class AgentEventHubTests: XCTestCase {
    func testSessionStartedStickyReplayUsesReservedSequenceOnlyForFullReplay() {
        let hub = AgentEventHub()
        hub.publish(AgentEvent(eventID: "session-start:test",
                               seq: transcriptSessionStartedSequence,
                               vendor: "claude",
                               workspaceID: "workspace",
                               sessionID: "session",
                               timestamp: "2026-01-01T00:00:00Z",
                               type: .sessionStarted,
                               role: nil,
                               text: nil,
                               name: nil,
                               input: nil,
                               output: nil,
                               toolCallID: nil,
                               metadata: nil))
        hub.publish(AgentEvent(eventID: "assistant:test:1",
                               seq: transcriptEventSequence(lineOffset: 100, ordinal: 0),
                               vendor: "claude",
                               workspaceID: "workspace",
                               sessionID: "session",
                               timestamp: "2026-01-01T00:00:01Z",
                               type: .assistantMessage,
                               role: "assistant",
                               text: "hello",
                               name: nil,
                               input: nil,
                               output: nil,
                               toolCallID: nil,
                               metadata: nil))

        let (_, fullReplay) = hub.subscribe(workspaceID: "workspace", sessionID: "session", sinceSeq: nil) { _ in }
        XCTAssertEqual(fullReplay.map(\.event.type), [.sessionStarted, .assistantMessage])

        let (_, incrementalReplay) = hub.subscribe(workspaceID: "workspace",
                                                   sessionID: "session",
                                                   sinceSeq: 50) { _ in }
        XCTAssertEqual(incrementalReplay.map(\.event.type), [.assistantMessage])
    }

    func testFetchAfterSeqReturnsEarliestMissingEventsInAscendingOrder() {
        let hub = AgentEventHub()
        for seq in 1...5 {
            hub.publish(makeAssistantEvent(id: "assistant-\(seq)", seq: seq))
        }

        let result = hub.fetch(workspaceID: "workspace",
                               sessionID: "session",
                               limit: 2,
                               beforeSeq: nil,
                               afterSeq: 2)

        XCTAssertEqual(result.events.map(\.seq), [3, 4])
        XCTAssertEqual(result.oldestSeq, 3)
        XCTAssertEqual(result.newestSeq, 4)
        XCTAssertTrue(result.hasMore)
    }

    func testFetchAfterSeqUsesSessionBufferOrderForCatchUpCursor() {
        let hub = AgentEventHub()
        for seq in [10, 12, 11] {
            hub.publish(makeAssistantEvent(id: "assistant-\(seq)", seq: seq))
        }

        let result = hub.fetch(workspaceID: "workspace",
                               sessionID: "session",
                               limit: 10,
                               beforeSeq: nil,
                               afterSeq: 10)

        XCTAssertEqual(result.events.map(\.seq), [11, 12])
        XCTAssertEqual(result.oldestSeq, 11)
        XCTAssertEqual(result.newestSeq, 12)
        XCTAssertFalse(result.hasMore)
    }

    func testReplayUsesMigratedWorkspaceIDAfterSessionBindingChanges() {
        let hub = AgentEventHub()
        hub.publish(makeAssistantEvent(id: "assistant-1", seq: 1))
        _ = hub.migrateSession(sessionID: "session", toWorkspaceID: "current-workspace", panelID: "current-panel")

        let (_, replay) = hub.subscribe(workspaceID: "current-workspace", sessionID: "session", sinceSeq: nil) { _ in }

        XCTAssertEqual(replay.map(\.event.workspaceID), ["current-workspace"])
        XCTAssertEqual(replay.first?.event.metadata?["panel_id"], "current-panel")
    }

    func testFetchUsesMigratedWorkspaceIDAfterSessionBindingChanges() {
        let hub = AgentEventHub()
        hub.publish(makeAssistantEvent(id: "assistant-1", seq: 1))
        _ = hub.migrateSession(sessionID: "session", toWorkspaceID: "current-workspace", panelID: "current-panel")

        let result = hub.fetch(workspaceID: "current-workspace",
                               sessionID: "session",
                               limit: 10,
                               beforeSeq: nil,
                               afterSeq: nil)

        XCTAssertEqual(result.events.map(\.workspaceID), ["current-workspace"])
        XCTAssertEqual(result.events.first?.metadata?["panel_id"], "current-panel")
    }

    private func makeAssistantEvent(id: String, seq: Int) -> AgentEvent {
        AgentEvent(eventID: id,
                   seq: seq,
                   vendor: "claude",
                   workspaceID: "workspace",
                   sessionID: "session",
                   timestamp: String(format: "2026-01-01T00:00:%02dZ", seq),
                   type: .assistantMessage,
                   role: "assistant",
                   text: id,
                   name: nil,
                   input: nil,
                   output: nil,
                   toolCallID: nil,
                   metadata: nil)
    }
}
