import Foundation

enum AgentPanelProcessSnapshotExtractor {
    static func snapshots(fromPanelListResult result: [String: JSONValue]) -> (workspaceID: String, snapshots: [AgentPanelProcessSnapshot])? {
        guard let workspaceID = result["workspace_id"]?.stringValue,
              let panels = result["panels"]?.arrayValue else {
            return nil
        }

        let snapshots = panels.compactMap { snapshot(from: $0, defaultWorkspaceID: workspaceID) }
        return (workspaceID, snapshots)
    }

    static func snapshot(from panelValue: JSONValue, defaultWorkspaceID: String) -> AgentPanelProcessSnapshot? {
        guard let panel = panelValue.objectValue,
              let panelID = panel["panel_id"]?.stringValue else {
            return nil
        }

        let workspaceID = panel["workspace_id"]?.stringValue ?? defaultWorkspaceID
        let effectiveShellPID = panel["effective_shell_pid"]?.intValue.flatMap(Int32.init)
        let ordinaryTmux = panel["ordinary_tmux_logical"]?.objectValue
        let tmuxPaneID = ordinaryTmux?["active_pane_id"]?.stringValue
        let tmuxSocketPath = ordinaryTmux?["socket_path"]?.stringValue
        let cwd = panel["cwd"]?.stringValue
        return AgentPanelProcessSnapshot(workspaceID: workspaceID,
                                         panelID: panelID,
                                         effectiveShellPID: effectiveShellPID,
                                         tmuxPaneID: tmuxPaneID,
                                         tmuxSocketPath: tmuxSocketPath,
                                         cwd: cwd)
    }
}
