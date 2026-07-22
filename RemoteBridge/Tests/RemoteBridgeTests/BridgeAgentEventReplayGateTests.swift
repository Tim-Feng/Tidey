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

    func testOpenSuppressesBufferedEventsAlreadyInjectedByReplay() {
        let gate = BridgeAgentEventReplayGate()
        XCTAssertNil(gate.receive(Self.envelope(id: "replayed", seq: 1)))
        XCTAssertNil(gate.receive(Self.envelope(id: "live-only", seq: 2)))

        let flushed = gate.open(suppressing: ["replayed"])

        XCTAssertEqual(flushed.map(\.event.eventID), ["live-only"])
    }

    func testOpenSuppressesOneLateLiveDeliveryAlreadyInjectedByReplay() {
        let gate = BridgeAgentEventReplayGate()

        XCTAssertTrue(gate.open(suppressing: ["replayed"]).isEmpty)
        XCTAssertNil(gate.receive(Self.envelope(id: "replayed", seq: 1)))
        XCTAssertEqual(gate.receive(Self.envelope(id: "live-only", seq: 2))?.event.eventID,
                       "live-only")
    }

    private static func envelope(id: String, seq: Int) -> AgentEventEnvelope {
        AgentEventEnvelope(replay: false,
                           event: AgentEvent(eventID: id,
                                             seq: seq,
                                             vendor: "codex",
                                             workspaceID: "workspace-1",
                                             sessionID: "session-1",
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
