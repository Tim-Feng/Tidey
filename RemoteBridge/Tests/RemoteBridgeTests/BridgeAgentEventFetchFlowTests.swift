import XCTest
@testable import RemoteBridge

final class BridgeAgentEventFetchFlowTests: XCTestCase {
    func testBeforeCursorBackfillsRequestedAnchorEvenWhenDeepCacheHasMore() {
        let hub = AgentEventHub(maxBufferedEvents: 20, maxSeenEventIDs: 100)
        for seq in 100...105 {
            hub.publish(makeEvent(seq: seq, text: "live-\(seq)"))
        }
        hub.replaceHistoricalEvents(sessionID: "session",
                                    events: (1...10).map { makeEvent(seq: $0, text: "deep-\($0)") })

        let cached = hub.fetch(workspaceID: "workspace",
                               sessionID: "session",
                               limit: 3,
                               beforeSeq: 100)
        XCTAssertTrue(cached.hasMore)
        XCTAssertEqual(cached.events.compactMap(\.text), ["deep-8", "deep-9", "deep-10"])

        var backfillCalls = [(beforeSeq: Int, limit: Int)]()
        let output = BridgeAgentEventFetchFlow.run(eventHub: hub,
                                                   workspaceID: "workspace",
                                                   sessionID: "session",
                                                   limit: 3,
                                                   beforeSeq: 100,
                                                   afterSeq: nil) { _, beforeSeq, limit in
            backfillCalls.append((beforeSeq, limit))
            hub.replaceHistoricalEvents(sessionID: "session",
                                        events: (97...99).map { self.makeEvent(seq: $0, text: "near-\($0)") },
                                        anchorSeq: beforeSeq)
            return true
        }

        XCTAssertEqual(backfillCalls.count, 1)
        XCTAssertEqual(backfillCalls.first?.beforeSeq, 100)
        XCTAssertGreaterThanOrEqual(backfillCalls.first?.limit ?? 0, 3)
        XCTAssertTrue(output.didBackfill)
        XCTAssertEqual(output.fetchResult.events.compactMap(\.text), ["near-97", "near-98", "near-99"])
    }

    func testBeforeCursorRefetchesWhenBackfillInvalidatesOldSourceWithoutLoading() {
        let hub = AgentEventHub()
        for seq in 100...105 {
            hub.publish(makeEvent(seq: seq, text: "old-\(seq)"))
        }

        let output = BridgeAgentEventFetchFlow.run(eventHub: hub,
                                                   workspaceID: "workspace",
                                                   sessionID: "session",
                                                   limit: 3,
                                                   beforeSeq: 106,
                                                   afterSeq: nil) { sessionID, _, _ in
            hub.beginNewSourceEpoch(sessionID: sessionID)
            return false
        }

        XCTAssertFalse(output.didBackfill)
        XCTAssertTrue(output.fetchResult.events.isEmpty,
                      "a fetch transaction must not return its pre-reset source snapshot")
    }

    func testAfterCursorRefetchesBeforeStoppingWhenBackfillInvalidatesOldSource() {
        let hub = AgentEventHub()
        for seq in 100...105 {
            hub.publish(makeEvent(seq: seq, text: "old-\(seq)"))
        }

        let output = BridgeAgentEventFetchFlow.run(eventHub: hub,
                                                   workspaceID: "workspace",
                                                   sessionID: "session",
                                                   limit: 3,
                                                   beforeSeq: nil,
                                                   afterSeq: 1) { sessionID, _, _ in
            hub.beginNewSourceEpoch(sessionID: sessionID)
            return false
        }

        XCTAssertFalse(output.didBackfill)
        XCTAssertTrue(output.fetchResult.events.isEmpty,
                      "the final result must be refetched after a failed coverage attempt")
    }

    func testAfterCursorStopsWhenBackfillDoesNotAdvanceCoverage() {
        let hub = AgentEventHub()
        for seq in 100...105 {
            hub.publish(makeEvent(seq: seq, text: "live-\(seq)"))
        }
        var backfillCalls = 0

        let output = BridgeAgentEventFetchFlow.run(eventHub: hub,
                                                   workspaceID: "workspace",
                                                   sessionID: "session",
                                                   limit: 3,
                                                   beforeSeq: nil,
                                                   afterSeq: 1) { _, _, _ in
            backfillCalls += 1
            return backfillCalls < 3
        }

        XCTAssertEqual(backfillCalls, 1,
                       "a successful read that publishes no older event cannot justify retrying the same anchor")
        XCTAssertTrue(output.didBackfill)
    }

    private func makeEvent(seq: Int, text: String) -> AgentEvent {
        AgentEvent(eventID: "event-\(seq)",
                   seq: seq,
                   vendor: "codex",
                   workspaceID: "workspace",
                   sessionID: "session",
                   timestamp: "2026-07-22T12:00:00Z",
                   type: .assistantMessage,
                   role: "assistant",
                   text: text,
                   name: nil,
                   input: nil,
                   output: nil,
                   toolCallID: nil,
                   metadata: nil)
    }
}
