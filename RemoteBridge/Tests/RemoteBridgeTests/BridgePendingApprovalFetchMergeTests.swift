import XCTest
@testable import RemoteBridge

final class BridgePendingApprovalFetchMergeTests: XCTestCase {
    func testPendingSnapshotOutsidePageDoesNotAdvanceRetainedBounds() {
        let page = [assistant(id: "assistant-20", seq: 20),
                    assistant(id: "assistant-21", seq: 21)]
        let pending = prompt(id: "prompt-5", seq: 5, submitState: "pending")

        let merged = BridgePendingApprovalFetchMerge.merge(pageEvents: page,
                                                           pageOldestSeq: 20,
                                                           pageNewestSeq: 21,
                                                           pendingEvents: [pending])

        XCTAssertEqual(Set(merged.events.map(\.eventID)),
                       Set(["prompt-5", "assistant-20", "assistant-21"]))
        XCTAssertEqual(merged.oldestSeq, 20)
        XCTAssertEqual(merged.newestSeq, 21)
    }

    func testPendingSnapshotOverlaysDynamicMetadataForRetainedEventIdentity() {
        let retained = prompt(id: "prompt-5", seq: 5, submitState: "pending")
        let snapshot = prompt(id: "prompt-5",
                              seq: 5,
                              submitState: "submitting",
                              clientRequestID: "client-1")

        let merged = BridgePendingApprovalFetchMerge.merge(pageEvents: [retained],
                                                           pageOldestSeq: 5,
                                                           pageNewestSeq: 5,
                                                           pendingEvents: [snapshot])

        XCTAssertEqual(merged.events.count, 1)
        XCTAssertEqual(merged.events[0].metadata?["submit_state"], "submitting")
        XCTAssertEqual(merged.events[0].metadata?["client_request_id"], "client-1")
        XCTAssertEqual(merged.events[0].seq, 5)
    }

    func testEmptyPageDoesNotMoveCursorBelowRequestedAfterSequence() {
        let pending = prompt(id: "prompt-5", seq: 5, submitState: "pending")

        let merged = BridgePendingApprovalFetchMerge.merge(pageEvents: [],
                                                           pageOldestSeq: 0,
                                                           pageNewestSeq: 0,
                                                           requestedAfterSeq: 14,
                                                           pendingEvents: [pending])

        XCTAssertEqual(merged.events.map(\.eventID), ["prompt-5"])
        XCTAssertEqual(merged.newestSeq, 14)
    }

    func testEmptyBeforePagePendingSnapshotDoesNotReplaceStoredBounds() {
        let pending = prompt(id: "prompt-500", seq: 500, submitState: "pending")

        let merged = BridgePendingApprovalFetchMerge.merge(pageEvents: [],
                                                           pageOldestSeq: 0,
                                                           pageNewestSeq: 0,
                                                           requestedBeforeSeq: 100,
                                                           pendingEvents: [pending])

        // Before-direction paging: the pending snapshot rides the payload,
        // but the stored-page bounds are the client's paging authority — a
        // pending approval's 500/500 would corrupt the backward cursor.
        XCTAssertEqual(merged.events.map(\.eventID), ["prompt-500"])
        XCTAssertEqual(merged.oldestSeq, 0)
        XCTAssertEqual(merged.newestSeq, 0)
    }

    func testEmptyAfterPagePendingAboveCursorDoesNotAdvanceNewestSeq() {
        let pending = prompt(id: "prompt-100", seq: 100, submitState: "pending")

        let merged = BridgePendingApprovalFetchMerge.merge(pageEvents: [],
                                                           pageOldestSeq: 0,
                                                           pageNewestSeq: 0,
                                                           requestedAfterSeq: 14,
                                                           pendingEvents: [pending])

        // The pending snapshot still rides the page, but the CURSOR must not
        // move past events the client has never seen: seq 15...99 would be
        // skipped forever if newest_seq jumped to the pending approval's 100.
        XCTAssertEqual(merged.events.map(\.eventID), ["prompt-100"])
        XCTAssertEqual(merged.newestSeq, 14)
    }

    func testEmptyCursorlessPageKeepsLatestSnapshotBounds() {
        let pending = prompt(id: "prompt-100", seq: 100, submitState: "pending")

        let merged = BridgePendingApprovalFetchMerge.merge(pageEvents: [],
                                                           pageOldestSeq: 0,
                                                           pageNewestSeq: 0,
                                                           pendingEvents: [pending])

        // Cursorless latest-snapshot fetch keeps the historical semantics:
        // bounds follow the injected snapshot, never an inverted 100/0 pair.
        XCTAssertEqual(merged.events.map(\.eventID), ["prompt-100"])
        XCTAssertEqual(merged.oldestSeq, 100)
        XCTAssertEqual(merged.newestSeq, 100)
    }

    func testEmptyBeforePageKeepsStoredBoundsWhenInjectingPendingSnapshot() {
        let pending = prompt(id: "prompt-500", seq: 500, submitState: "pending")

        let merged = BridgePendingApprovalFetchMerge.merge(pageEvents: [],
                                                           pageOldestSeq: 0,
                                                           pageNewestSeq: 0,
                                                           requestedBeforeSeq: 100,
                                                           pendingEvents: [pending])

        XCTAssertEqual(merged.events.map(\.eventID), ["prompt-500"])
        XCTAssertEqual(merged.oldestSeq, 0)
        XCTAssertEqual(merged.newestSeq, 0)
    }

    func testReplaySnapshotMetadataWinsAndLiveDuplicateIsSuppressed() {
        let retained = prompt(id: "prompt-5", seq: 5, submitState: "pending")
        let snapshot = prompt(id: "prompt-5",
                              seq: 5,
                              submitState: "submitting",
                              clientRequestID: "client-1")
        let replay = BridgePendingApprovalFetchMerge.mergeReplayEnvelopes(
            [AgentEventEnvelope(replay: true, event: retained)],
            pendingEvents: [snapshot])
        let gate = BridgeAgentEventReplayGate()
        XCTAssertNil(gate.receive(AgentEventEnvelope(replay: false, event: retained)))
        let liveOnly = assistant(id: "assistant-6", seq: 6)
        XCTAssertNil(gate.receive(AgentEventEnvelope(replay: false, event: liveOnly)))

        let flushed = BridgePendingApprovalFetchMerge.openLiveGate(gate,
                                                                   afterReplaying: replay)

        XCTAssertEqual(replay.count, 1)
        XCTAssertEqual(replay[0].event.metadata?["submit_state"], "submitting")
        XCTAssertEqual(replay[0].event.metadata?["client_request_id"], "client-1")
        XCTAssertEqual(flushed.map(\.event.eventID), ["assistant-6"])
    }

    private func assistant(id: String, seq: Int) -> AgentEvent {
        AgentEvent(eventID: id,
                   seq: seq,
                   vendor: "codex",
                   workspaceID: "workspace-1",
                   sessionID: "session-1",
                   timestamp: "2026-07-22T12:00:\(String(format: "%02d", seq)).000Z",
                   type: .assistantMessage,
                   role: "assistant",
                   text: id,
                   name: nil,
                   input: nil,
                   output: nil,
                   toolCallID: nil,
                   metadata: nil)
    }

    private func prompt(id: String,
                        seq: Int,
                        submitState: String,
                        clientRequestID: String? = nil) -> AgentEvent {
        var metadata = [
            "panel_id": "panel-1",
            "prompt_id": "approval-1",
            "source": "codex_command_approval",
            "lifecycle_token": "token-1",
            "submit_state": submitState,
        ]
        if let clientRequestID {
            metadata["client_request_id"] = clientRequestID
        }
        return AgentEvent(eventID: id,
                          seq: seq,
                          vendor: "codex",
                          workspaceID: "workspace-1",
                          sessionID: "session-1",
                          timestamp: "2026-07-22T12:00:\(String(format: "%02d", seq)).000Z",
                          type: .interactivePrompt,
                          role: nil,
                          text: "Approve?",
                          name: nil,
                          input: nil,
                          output: nil,
                          toolCallID: nil,
                          metadata: metadata,
                          payload: .object([
                            "prompt_id": .string("approval-1"),
                            "vendor": .string("codex"),
                            "source": .string("codex_command_approval"),
                            "submit_channel": .string("codex_app_server"),
                            "lifecycle_token": .string("token-1"),
                          ]))
    }
}
