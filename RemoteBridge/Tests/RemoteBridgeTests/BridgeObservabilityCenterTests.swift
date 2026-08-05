import XCTest
@testable import RemoteBridge

final class BridgeObservabilityCenterTests: XCTestCase {
    func testConnectionEventRingIsBounded() {
        let center = BridgeObservabilityCenter(maxConnectionEvents: 2)

        center.recordConnectionEvent(BridgeConnectionEventSnapshot(connectionID: "connection-1",
                                                                    kind: .connected))
        center.recordConnectionEvent(BridgeConnectionEventSnapshot(connectionID: "connection-1",
                                                                    kind: .peerClose,
                                                                    closeCode: 1001,
                                                                    reasonByteCount: 4))
        center.recordConnectionEvent(BridgeConnectionEventSnapshot(connectionID: "connection-1",
                                                                    kind: .disconnected,
                                                                    durationMs: 125))

        let snapshot = center.snapshot(activeSessions: [])
        XCTAssertEqual(snapshot.connectionEvents.map(\.kind), [.peerClose, .disconnected])
        XCTAssertEqual(snapshot.connectionEvents.first?.closeCode, 1001)
        XCTAssertEqual(snapshot.connectionEvents.first?.reasonByteCount, 4)
    }

    func testActiveTerminalStreamSubscriptionCountAggregatesConnections() {
        let center = BridgeObservabilityCenter()

        center.setActiveTerminalStreamSubscriptionCount(2, forConnectionID: "connection-1")
        center.setActiveTerminalStreamSubscriptionCount(1, forConnectionID: "connection-2")
        XCTAssertEqual(center.snapshot(activeSessions: []).activeTerminalStreamSubscriptionCount, 3)

        center.clearActiveTerminalStreamSubscriptionCount(forConnectionID: "connection-1")
        XCTAssertEqual(center.snapshot(activeSessions: []).activeTerminalStreamSubscriptionCount, 1)
    }

    func testRecordFetchUpdatesSnapshotAndBackfillCounts() {
        let center = BridgeObservabilityCenter(slowFetchThresholdMs: 9999)

        center.recordFetch(workspaceID: "workspace-1",
                           sessionID: "session-1",
                           limit: 60,
                           beforeSeq: nil,
                           afterSeq: 120,
                           returnedCount: 18,
                           didBackfill: true,
                           durationMs: 42)

        let snapshot = center.snapshot(activeSessions: [
            BridgeActiveSessionStatus(vendor: "codex",
                                      workspaceID: "workspace-1",
                                      sessionID: "session-1",
                                      panelID: "panel-1",
                                      bufferedEventCount: 18,
                                      oldestSeq: 121,
                                      newestSeq: 138,
                                      isActive: true)
        ])

        XCTAssertEqual(snapshot.fetchStats.totalFetches, 1)
        XCTAssertEqual(snapshot.fetchStats.fetchesWithBackfill, 1)
        XCTAssertEqual(snapshot.fetchStats.lastFetch?.afterSeq, 120)
        XCTAssertEqual(snapshot.fetchStats.lastFetch?.returnedCount, 18)
        XCTAssertEqual(snapshot.activeSessions.first?.sessionID, "session-1")
        XCTAssertEqual(snapshot.activeSessions.first?.restoreSessionID, "session-1")
    }

    func testActiveSessionStatusEncodesRestoreSessionID() throws {
        let status = BridgeActiveSessionStatus(vendor: "codex",
                                               workspaceID: "workspace-1",
                                               sessionID: "instance-1",
                                               panelID: "panel-1",
                                               restoreSessionID: "thread-1",
                                               bufferedEventCount: 0,
                                               oldestSeq: nil,
                                               newestSeq: nil,
                                               isActive: true)

        let data = try JSONEncoder().encode(status)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["session_id"] as? String, "instance-1")
        XCTAssertEqual(object["restore_session_id"] as? String, "thread-1")
    }

    func testSlowFetchIsRecordedAsSlowOperation() {
        let center = BridgeObservabilityCenter(slowFetchThresholdMs: 10)

        center.recordFetch(workspaceID: "workspace-1",
                           sessionID: "session-1",
                           limit: 200,
                           beforeSeq: 500,
                           afterSeq: nil,
                           returnedCount: 200,
                           didBackfill: false,
                           durationMs: 33)

        let snapshot = center.snapshot(activeSessions: [])
        XCTAssertEqual(snapshot.slowOperations.count, 1)
        XCTAssertEqual(snapshot.slowOperations.first?.name, "fetch_agent_events")
        XCTAssertEqual(snapshot.slowOperations.first?.sessionID, "session-1")
    }

    func testRecordPayloadGroupsByDirectionAndMessageType() {
        let center = BridgeObservabilityCenter()

        center.recordPayload(direction: .inbound,
                             messageType: "request.fetch_agent_events",
                             byteCount: 100,
                             durationMs: 2)
        center.recordPayload(direction: .inbound,
                             messageType: "request.fetch_agent_events",
                             byteCount: 300,
                             durationMs: 6)
        center.recordPayload(direction: .outbound,
                             messageType: "agent_event",
                             byteCount: 50,
                             durationMs: 1)

        let snapshot = center.snapshot(activeSessions: [])
        let fetchStats = snapshot.payloadStats.first {
            $0.direction == .inbound && $0.messageType == "request.fetch_agent_events"
        }
        let eventStats = snapshot.payloadStats.first {
            $0.direction == .outbound && $0.messageType == "agent_event"
        }

        XCTAssertEqual(fetchStats?.count, 2)
        XCTAssertEqual(fetchStats?.totalBytes, 400)
        XCTAssertEqual(fetchStats?.maxBytes, 300)
        XCTAssertEqual(fetchStats?.averageBytes, 200)
        XCTAssertEqual(fetchStats?.averageDurationMs, 4)
        XCTAssertEqual(fetchStats?.maxDurationMs, 6)
        XCTAssertEqual(fetchStats?.lastBytes, 300)
        XCTAssertEqual(eventStats?.count, 1)
        XCTAssertEqual(eventStats?.totalBytes, 50)
    }
}
