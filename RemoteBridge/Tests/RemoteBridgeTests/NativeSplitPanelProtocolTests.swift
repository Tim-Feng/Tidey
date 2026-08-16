import XCTest
@testable import RemoteBridge

final class NativeSplitPanelProtocolTests: XCTestCase {
    func testProtocolCapabilityIsStable() {
        XCTAssertEqual(BridgeNativeSplitProtocolV1.capability, "native_split_sessions_v1")
    }

    func testSnapshotExtractorCarriesNativeSessionIdentity() throws {
        let snapshot = try XCTUnwrap(AgentPanelProcessSnapshotExtractor.snapshot(
            from: .object([
                "workspace_id": .string("workspace-1"),
                "panel_id": .string("native-session:carrier-1:session-1"),
                "logical_kind": .string("native_session"),
                "carrier_panel_id": .string("carrier-1"),
                "native_session_id": .string("session-1"),
                "effective_shell_pid": .number(41_001),
            ]),
            defaultWorkspaceID: "fallback-workspace"
        ))

        XCTAssertEqual(snapshot.logicalKind, .nativeSession)
        XCTAssertEqual(snapshot.carrierPanelID, "carrier-1")
        XCTAssertEqual(snapshot.nativeSessionID, "session-1")
        XCTAssertEqual(snapshot.effectiveShellPID, 41_001)
    }

    func testSnapshotExtractorLeavesLegacyPanelsUnannotated() throws {
        let snapshot = try XCTUnwrap(AgentPanelProcessSnapshotExtractor.snapshot(
            from: .object([
                "panel_id": .string("legacy-panel"),
            ]),
            defaultWorkspaceID: "workspace-1"
        ))

        XCTAssertNil(snapshot.logicalKind)
        XCTAssertNil(snapshot.carrierPanelID)
        XCTAssertNil(snapshot.nativeSessionID)
    }

    func testNativeLeavesBindToTheirOwnAgentProcessTreesAndFailClosedOnAmbiguity() throws {
        let fileManager = FileManager.default
        let supportDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("tidey-native-split-binding-\(UUID().uuidString)", isDirectory: true)
        let paths = BridgePaths(supportDirectory: supportDirectory)
        try paths.ensureSupportDirectoriesExist(fileManager: fileManager)
        defer { try? fileManager.removeItem(at: supportDirectory) }

        let firstAgentPID = getpid()
        let secondAgentPID = getppid()
        try writeRegistryRecord(sessionID: "agent-1", pid: firstAgentPID, paths: paths)
        try writeRegistryRecord(sessionID: "agent-2", pid: secondAgentPID, paths: paths)
        let parents: [Int32: Int32] = [firstAgentPID: 100, secondAgentPID: 200]
        let monitor = AgentSessionRegistryMonitor(
            paths: paths,
            fileManager: fileManager,
            hub: AgentEventHub(),
            tmuxResolver: TmuxStateResolver(ttl: 60) { _, _ in "" },
            parentPIDLookup: { parents[$0] }
        )
        monitor.scanRegistryForTesting()

        let first = monitor.activeSessionForPanel(
            workspaceID: "workspace-1",
            panelID: "native-session:carrier-1:leaf-1",
            effectiveShellPID: 100,
            logicalKind: .nativeSession,
            carrierPanelID: "carrier-1",
            nativeSessionID: "leaf-1"
        )
        let second = monitor.activeSessionForPanel(
            workspaceID: "workspace-1",
            panelID: "native-session:carrier-1:leaf-2",
            effectiveShellPID: 200,
            logicalKind: .nativeSession,
            carrierPanelID: "carrier-1",
            nativeSessionID: "leaf-2"
        )
        XCTAssertEqual(first?.sessionID, "agent-1")
        XCTAssertEqual(second?.sessionID, "agent-2")

        try writeRegistryRecord(sessionID: "agent-ambiguous", pid: firstAgentPID, paths: paths)
        monitor.scanRegistryForTesting()
        let ambiguous = monitor.activeSessionForPanel(
            workspaceID: "workspace-1",
            panelID: "native-session:carrier-1:leaf-unbound",
            effectiveShellPID: 100,
            logicalKind: .nativeSession,
            carrierPanelID: "carrier-1",
            nativeSessionID: "leaf-unbound"
        )
        XCTAssertNil(ambiguous)
    }

    private func writeRegistryRecord(sessionID: String,
                                     pid: Int32,
                                     paths: BridgePaths) throws {
        let record = AgentSessionRegistryRecord(
            version: 1,
            vendor: "claude",
            workspaceID: "workspace-1",
            sessionID: sessionID,
            panelID: "carrier-1",
            pid: pid,
            cwd: "/tmp",
            createdAt: "2026-08-16T00:00:00Z",
            transcriptPath: nil
        )
        let url = paths.claudeAgentSessionsDirectory
            .appendingPathComponent("\(sessionID).json", isDirectory: false)
        try JSONEncoder().encode(record).write(to: url, options: [.atomic])
    }
}
