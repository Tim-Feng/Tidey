import XCTest
@testable import RemoteBridge

final class BridgeObservabilityCenterTests: XCTestCase {
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
}
