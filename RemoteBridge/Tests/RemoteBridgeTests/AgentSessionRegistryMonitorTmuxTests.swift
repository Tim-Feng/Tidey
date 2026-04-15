import XCTest
@testable import RemoteBridge

final class AgentSessionRegistryMonitorTmuxTests: XCTestCase {
    func testActiveSessionForPanelFallsBackToTmuxPaneMatchWhenPanelIDsChanged() throws {
        let fileManager = FileManager.default
        let supportDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("tidey-remote-bridge-monitor-\(UUID().uuidString)", isDirectory: true)
        let paths = BridgePaths(supportDirectory: supportDirectory)
        try paths.ensureSupportDirectoriesExist(fileManager: fileManager)
        defer { try? fileManager.removeItem(at: supportDirectory) }

        let registryURL = paths.claudeAgentSessionsDirectory.appendingPathComponent("claude-session-1.json")
        let recordData = Data("""
        {
          "version": 1,
          "vendor": "claude",
          "workspace_id": "stale-workspace",
          "session_id": "session-1",
          "panel_id": "stale-panel",
          "pid": \(getpid()),
          "cwd": "/tmp",
          "created_at": "2026-04-15T00:00:00Z",
          "tmux_pane_id": "%42",
          "tmux_socket_path": "/tmp/tmux.sock"
        }
        """.utf8)
        try recordData.write(to: registryURL)

        let tmuxResolver = TmuxStateResolver(ttl: 60) { socketPath, arguments in
            XCTAssertEqual(socketPath, "/tmp/tmux.sock")
            if arguments.first == "list-panes" {
                return "%42\tcc\n"
            }
            return "12345\tcc\n"
        }
        let monitor = AgentSessionRegistryMonitor(paths: paths,
                                                  fileManager: fileManager,
                                                  hub: AgentEventHub(),
                                                  tmuxResolver: tmuxResolver)
        try monitor.start()

        let session = monitor.activeSessionForPanel(workspaceID: "new-workspace",
                                                    panelID: "new-panel",
                                                    effectiveShellPID: 12345)
        XCTAssertEqual(session?.vendor, "claude")
        XCTAssertEqual(session?.sessionID, "session-1")
        XCTAssertEqual(session?.workspaceID, "new-workspace")
        XCTAssertEqual(session?.panelID, "new-panel")
    }
}
