import XCTest
@testable import RemoteBridge

final class BridgeAgentEventReplayGateTests: XCTestCase {
    func testBuffersLiveEventsUntilReplayFlushOpensGate() {
        let gate = BridgeAgentEventReplayGate()
        let first = Self.envelope(id: "live-1", seq: 1)
        let second = Self.envelope(id: "live-2", seq: 2)

        XCTAssertNil(gate.receive(first))
        XCTAssertNil(gate.receive(second))

        XCTAssertEqual(gate.open().map(\.event.eventID), ["live-1", "live-2"])
        XCTAssertEqual(gate.open().map(\.event.eventID), [])

        let third = Self.envelope(id: "live-3", seq: 3)
        XCTAssertEqual(gate.receive(third)?.event.eventID, "live-3")
    }

    // MARK: - Round 3 item 3: suppression identity is (sessionID, eventID, seq)

    // The SAME stored event (identical eventID AND seq) racing between the
    // replay snapshot and a live delivery must still dedupe to exactly one
    // copy — the core contract the gate exists for.
    func testSameEventSameIDAndSeqStillSuppresses() {
        let gate = BridgeAgentEventReplayGate()
        let live = Self.envelope(id: "call_shared", seq: 5, sessionID: "session-1")

        XCTAssertNil(gate.receive(live), "buffered while the replay snapshot is still being sent")

        let replayedKeys: Set<BridgeAgentEventSuppressionKey> = [
            BridgeAgentEventSuppressionKey(sessionID: "session-1", eventID: "call_shared", seq: 5),
        ]
        XCTAssertEqual(gate.open(suppressing: replayedKeys).map(\.event.eventID), [],
                       "the identical (session, eventID, seq) must be suppressed — it was already delivered via replay")
    }

    // A same-path transcript delete+recreate (source B) can reuse the SAME
    // raw call_id/eventID string as source A, but a genuine new source
    // epoch always rebases B's seq strictly ABOVE A's high-water (see
    // AgentEventHub.nextSyntheticSeq / CodexTranscriptSession.beginNewSourceEpoch).
    // A's replay entry (lower seq) must never suppress B's live event
    // (same eventID, HIGHER seq) — they are genuinely different stored events.
    func testSameSessionSameEventIDButHigherSeqIsNotSuppressed() {
        let gate = BridgeAgentEventReplayGate()
        let bLive = Self.envelope(id: "call_shared", seq: 42, sessionID: "session-1")

        XCTAssertNil(gate.receive(bLive))

        // A's replay entry used the SAME literal eventID but a LOWER seq.
        let aReplayedKeys: Set<BridgeAgentEventSuppressionKey> = [
            BridgeAgentEventSuppressionKey(sessionID: "session-1", eventID: "call_shared", seq: 5),
        ]
        let flushed = gate.open(suppressing: aReplayedKeys)
        XCTAssertEqual(flushed.map { $0.event.seq }, [42],
                       "B's reused-eventID live event (higher seq) must NOT be suppressed by A's lower-seq replay entry")
    }

    // Two DIFFERENT sessions must never suppress each other, even with the
    // identical eventID and seq by coincidence.
    func testDifferentSessionsWithSameEventIDAndSeqDoNotSuppressEachOther() {
        let gate = BridgeAgentEventReplayGate()
        let otherSessionLive = Self.envelope(id: "call_shared", seq: 5, sessionID: "session-2")

        XCTAssertNil(gate.receive(otherSessionLive))

        let session1ReplayedKeys: Set<BridgeAgentEventSuppressionKey> = [
            BridgeAgentEventSuppressionKey(sessionID: "session-1", eventID: "call_shared", seq: 5),
        ]
        let flushed = gate.open(suppressing: session1ReplayedKeys)
        XCTAssertEqual(flushed.map { $0.event.sessionID }, ["session-2"],
                       "session-1's replayed key must never suppress session-2's live event with the same eventID/seq")
    }

    // The buffered-path test above covers suppression BEFORE open(); this
    // covers the OTHER half — a late live envelope racing in AFTER open()
    // has already run (the ordered drain may still be flushing the replay
    // set) must ALSO be suppressed by the same (session, eventID, seq) key,
    // and exactly once (a second identical late arrival is not suppressed
    // again, matching "at most once").
    func testLateLiveEnvelopeAfterOpenIsAlsoSuppressedExactlyOnce() {
        let gate = BridgeAgentEventReplayGate()
        let replayedKeys: Set<BridgeAgentEventSuppressionKey> = [
            BridgeAgentEventSuppressionKey(sessionID: "session-1", eventID: "call_shared", seq: 5),
        ]
        XCTAssertEqual(gate.open(suppressing: replayedKeys).map(\.event.eventID), [])

        let lateDuplicate = Self.envelope(id: "call_shared", seq: 5, sessionID: "session-1")
        XCTAssertNil(gate.receive(lateDuplicate), "the late live envelope matching an already-replayed key must be suppressed")

        // A SECOND identical late arrival (e.g. a redundant native publish)
        // is no longer in the suppression set — it must pass through.
        let secondDuplicate = Self.envelope(id: "call_shared", seq: 5, sessionID: "session-1")
        XCTAssertEqual(gate.receive(secondDuplicate)?.event.eventID, "call_shared",
                       "each suppressed key fires at most once — a second identical arrival passes through")
    }

    private static func envelope(id: String, seq: Int, sessionID: String = "session-1") -> AgentEventEnvelope {
        AgentEventEnvelope(replay: false,
                           event: AgentEvent(eventID: id,
                                             seq: seq,
                                             vendor: "codex",
                                             workspaceID: "workspace-1",
                                             sessionID: sessionID,
                                             timestamp: "2026-06-08T00:00:00.000Z",
                                             type: .assistantMessage,
                                             role: "assistant",
                                             text: id,
                                             name: nil,
                                             input: nil,
                                             output: nil,
                                             toolCallID: nil,
                                             metadata: nil))
    }
}
