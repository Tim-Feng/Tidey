import Foundation

final class TideyOrdinaryTmuxWorkspaceResolver {
    private let socketClient: TideySocketClient
    private let tmuxResolver: TmuxStateResolver

    init(socketClient: TideySocketClient,
         tmuxResolver: TmuxStateResolver = TmuxStateResolver()) {
        self.socketClient = socketClient
        self.tmuxResolver = tmuxResolver
    }

    func workspaceID(for record: AgentSessionRegistryRecord) -> String? {
        guard let paneID = record.tmuxPaneID,
              paneID.isEmpty == false,
              let socketPath = record.tmuxSocketPath,
              socketPath.isEmpty == false,
              let sessionName = tmuxResolver.sessionName(forPaneID: paneID, socketPath: socketPath) else {
            return nil
        }

        do {
            let response = try socketClient.send(BridgeRequest(id: UUID().uuidString,
                                                               action: "list_workspaces",
                                                               params: nil))
            guard response.ok,
                  let workspaces = response.result?["workspaces"]?.arrayValue else {
                return nil
            }
            for workspaceValue in workspaces {
                guard let workspace = workspaceValue.objectValue,
                      let workspaceID = workspace["workspace_id"]?.stringValue,
                      let ordinaryTmux = workspace["ordinary_tmux"]?.objectValue else {
                    continue
                }
                let targetSession = ordinaryTmux["target_session"]?.stringValue
                if targetSession == sessionName {
                    return workspaceID
                }
            }
        } catch {
            BridgeLogger.server.debug("ordinary tmux workspace resolve failed session_id=\(record.sessionID, privacy: .public) pane_id=\(paneID, privacy: .public) error=\(String(describing: error), privacy: .public)")
        }

        return nil
    }
}
