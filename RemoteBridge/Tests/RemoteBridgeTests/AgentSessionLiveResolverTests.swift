import XCTest
@testable import RemoteBridge

final class AgentSessionLiveResolverTests: XCTestCase {
    func testResolveMatchesDescendantProcessToCurrentPanel() {
        let resolved = AgentSessionLiveResolver.resolve(
            recordsBySessionID: [
                "session-1": makeRecord(workspaceID: "stale-workspace",
                                        sessionID: "session-1",
                                        panelID: "stale-panel",
                                        pid: 50201,
                                        createdAt: "2026-04-15T00:19:00Z"),
            ],
            panelsByWorkspaceID: [
                "live-workspace": [
                    AgentPanelProcessSnapshot(workspaceID: "live-workspace",
                                              panelID: "live-panel",
                                              effectiveShellPID: 49621),
                ],
            ],
            processParentPIDMap: [
                50201: 50186,
                50186: 49621,
                49621: 41000,
            ]
        )

        XCTAssertEqual(resolved.resolvedLocationsBySessionID["session-1"],
                       AgentSessionResolvedLocation(workspaceID: "live-workspace",
                                                    panelID: "live-panel"))
        XCTAssertEqual(resolved.sessionIDByResolvedPanelKey[ResolvedPanelKey(workspaceID: "live-workspace",
                                                                             panelID: "live-panel")],
                       "session-1")
    }

    func testResolveSkipsPanelsWithoutEffectiveShellPID() {
        let resolved = AgentSessionLiveResolver.resolve(
            recordsBySessionID: [
                "session-1": makeRecord(workspaceID: "stale-workspace",
                                        sessionID: "session-1",
                                        panelID: "stale-panel",
                                        pid: 50201,
                                        createdAt: "2026-04-15T00:19:00Z"),
            ],
            panelsByWorkspaceID: [
                "live-workspace": [
                    AgentPanelProcessSnapshot(workspaceID: "live-workspace",
                                              panelID: "live-panel",
                                              effectiveShellPID: nil),
                ],
            ],
            processParentPIDMap: [
                50201: 50186,
                50186: 49621,
            ]
        )

        XCTAssertTrue(resolved.resolvedLocationsBySessionID.isEmpty)
        XCTAssertTrue(resolved.sessionIDByResolvedPanelKey.isEmpty)
    }

    func testResolveKeepsNewestSessionForPanelLookup() {
        let resolved = AgentSessionLiveResolver.resolve(
            recordsBySessionID: [
                "session-older": makeRecord(workspaceID: "stale-workspace",
                                            sessionID: "session-older",
                                            panelID: "stale-panel-a",
                                            pid: 1111,
                                            createdAt: "2026-04-15T00:18:00Z"),
                "session-newer": makeRecord(workspaceID: "stale-workspace",
                                            sessionID: "session-newer",
                                            panelID: "stale-panel-b",
                                            pid: 2222,
                                            createdAt: "2026-04-15T00:19:00Z"),
            ],
            panelsByWorkspaceID: [
                "live-workspace": [
                    AgentPanelProcessSnapshot(workspaceID: "live-workspace",
                                              panelID: "live-panel",
                                              effectiveShellPID: 9000),
                ],
            ],
            processParentPIDMap: [
                1111: 9000,
                2222: 9000,
            ]
        )

        XCTAssertEqual(resolved.sessionIDByResolvedPanelKey[ResolvedPanelKey(workspaceID: "live-workspace",
                                                                             panelID: "live-panel")],
                       "session-newer")
        XCTAssertEqual(resolved.resolvedLocationsBySessionID["session-older"],
                       AgentSessionResolvedLocation(workspaceID: "live-workspace",
                                                    panelID: "live-panel"))
        XCTAssertEqual(resolved.resolvedLocationsBySessionID["session-newer"],
                       AgentSessionResolvedLocation(workspaceID: "live-workspace",
                                                    panelID: "live-panel"))
    }

    private func makeRecord(workspaceID: String,
                            sessionID: String,
                            panelID: String,
                            pid: Int32,
                            createdAt: String) -> AgentSessionRegistryRecord {
        AgentSessionRegistryRecord(version: 1,
                                   vendor: "claude",
                                   workspaceID: workspaceID,
                                   sessionID: sessionID,
                                   panelID: panelID,
                                   pid: pid,
                                   cwd: "/tmp",
                                   createdAt: createdAt,
                                   transcriptPath: nil)
    }
}
