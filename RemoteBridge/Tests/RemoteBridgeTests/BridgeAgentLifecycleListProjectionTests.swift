import XCTest
@testable import RemoteBridge

final class BridgeAgentLifecycleListProjectionTests: XCTestCase {
    func testBridgeListProjectionUsesAuthoritativeAgentLifecycleState() throws {
        let supportDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BridgeLifecycleList-\(UUID().uuidString)", isDirectory: true)
        let paths = BridgePaths(supportDirectory: supportDirectory)
        try paths.ensureSupportDirectoriesExist(fileManager: .default)
        defer { try? FileManager.default.removeItem(at: supportDirectory) }

        let transcriptURL = supportDirectory.appendingPathComponent("session.jsonl")
        try Data().write(to: transcriptURL)
        let record = AgentSessionRegistryRecord(version: 1,
                                                vendor: "codex",
                                                workspaceID: "workspace-1",
                                                sessionID: "session-1",
                                                panelID: "panel-1",
                                                pid: ProcessInfo.processInfo.processIdentifier,
                                                cwd: "/tmp",
                                                createdAt: "2026-07-22T12:00:00.000Z",
                                                transcriptPath: transcriptURL.path)
        let recordData = try JSONEncoder().encode(record)
        try recordData.write(to: paths.codexAgentSessionsDirectory.appendingPathComponent("codex-session-1.json"))

        let monitor = AgentSessionRegistryMonitor(paths: paths,
                                                  fileManager: .default,
                                                  hub: AgentEventHub(),
                                                  tmuxResolver: TmuxStateResolver(ttl: 60) { _, _ in "" },
                                                  parentPIDLookup: { _ in nil })
        monitor.scanRegistryForTesting()
        let store = AgentSessionLifecycleStore()
        let identity = AgentSessionLifecycleIdentity(workspaceID: "workspace-1",
                                                     panelID: "panel-1",
                                                     sessionID: "session-1")
        store.beginTurn(identity, vendor: "codex", generation: 1, turnID: "turn-1")

        let handler = WebSocketFrameHandler(socketClient: TideySocketClient(locator: TideySocketLocator()),
                                            eventHub: AgentEventHub(),
                                            workspaceEventHub: WorkspaceEventHub(),
                                            registryMonitor: monitor,
                                            observability: BridgeObservabilityCenter(),
                                            bridgePort: 0,
                                            cloudflaredManager: BridgeCloudflaredManager(binaryResolver: { nil }),
                                            lifecycleStore: store)
        let panelResult = handler.augmentPanelListResult([
            "workspace_id": .string("workspace-1"),
            "panels": .array([
                .object([
                    "panel_id": .string("panel-1"),
                    "state": .string("running"),
                ]),
                .object([
                    "panel_id": .string("terminal-1"),
                    "state": .string("running"),
                ]),
            ]),
        ])
        let panels = try XCTUnwrap(panelResult["panels"]?.arrayValue)
        let agentPanel = try XCTUnwrap(panels[0].objectValue)
        let terminalPanel = try XCTUnwrap(panels[1].objectValue)

        XCTAssertEqual(agentPanel["agent_session"]?.objectValue?["session_id"]?.stringValue,
                       "session-1")
        XCTAssertEqual(agentPanel["state"]?.stringValue, "working")
        XCTAssertGreaterThan(agentPanel["state_revision"]?.intValue ?? 0, 0)
        XCTAssertEqual(terminalPanel["state"]?.stringValue, "running")
        XCTAssertNil(terminalPanel["state_revision"])

        let workspaceResult = handler.augmentWorkspaceListResult([
            "workspaces": .array([
                .object([
                    "workspace_id": .string("workspace-1"),
                    "state": .string("idle"),
                ]),
            ]),
        ])
        let workspace = try XCTUnwrap(workspaceResult["workspaces"]?.arrayValue?.first?.objectValue)
        XCTAssertEqual(workspace["has_agent_session"]?.boolValue, true)
        XCTAssertEqual(workspace["state"]?.stringValue, "working")
        XCTAssertGreaterThan(workspace["state_revision"]?.intValue ?? 0, 0)
    }
}
