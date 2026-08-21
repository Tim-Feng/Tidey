import XCTest
@testable import RemoteBridge

final class AgentSessionRuntimeSyncGroupTests: XCTestCase {
    func testSyncForwardsTheSameRegistrySnapshotToEveryConsumer() {
        let first = CapturingAgentSessionRuntimeSyncer()
        let second = CapturingAgentSessionRuntimeSyncer()
        let group = AgentSessionRuntimeSyncGroup(syncers: [first, second])
        let records = [
            AgentSessionRegistryRecord(version: 1,
                                       vendor: "claude",
                                       workspaceID: "workspace-1",
                                       sessionID: "session-1",
                                       panelID: "panel-1",
                                       pid: 123,
                                       cwd: "/tmp",
                                       createdAt: "2026-08-21T00:00:00Z",
                                       transcriptPath: nil),
        ]

        group.sync(records: records)

        XCTAssertEqual(first.sessionIDs, ["session-1"])
        XCTAssertEqual(second.sessionIDs, ["session-1"])
    }
}

private final class CapturingAgentSessionRuntimeSyncer: AgentSessionRuntimeSyncing {
    private(set) var sessionIDs = [String]()

    func sync(records: [AgentSessionRegistryRecord]) {
        sessionIDs = records.map(\.sessionID)
    }
}
