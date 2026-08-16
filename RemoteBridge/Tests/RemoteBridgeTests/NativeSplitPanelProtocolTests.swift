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
}
