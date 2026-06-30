import Foundation

struct TideyOrdinaryTmuxCarrierIdentity: Equatable, Sendable {
    let workspaceID: String
    let panelID: String
    let socketPath: String
    let targetSession: String
}

final class TideyOrdinaryTmuxCarrierResolver {
    typealias RequestSender = (BridgeRequest) throws -> BridgeResponse

    private let tmuxResolver: TmuxStateResolver
    private let requestSender: RequestSender

    init(socketClient: TideySocketClient,
         tmuxResolver: TmuxStateResolver = TmuxStateResolver()) {
        self.tmuxResolver = tmuxResolver
        self.requestSender = { request in
            try socketClient.send(request)
        }
    }

    init(requestSender: @escaping RequestSender,
         tmuxResolver: TmuxStateResolver = TmuxStateResolver()) {
        self.tmuxResolver = tmuxResolver
        self.requestSender = requestSender
    }

    func carrierIdentity(for record: AgentSessionRegistryRecord) -> TideyOrdinaryTmuxCarrierIdentity? {
        guard let context = tmuxContext(for: record) else {
            return nil
        }

        do {
            guard let workspaces = try listWorkspaces(),
                  let workspaceID = workspaceID(in: workspaces, targetSession: context.sessionName),
                  let panelID = try carrierPanelID(workspaceID: workspaceID,
                                                   targetSession: context.sessionName) else {
                return nil
            }
            return TideyOrdinaryTmuxCarrierIdentity(workspaceID: workspaceID,
                                                    panelID: panelID,
                                                    socketPath: context.socketPath,
                                                    targetSession: context.sessionName)
        } catch {
            BridgeLogger.server.debug("ordinary tmux carrier identity resolve failed session_id=\(record.sessionID, privacy: .public) pane_id=\(context.paneID, privacy: .public) error=\(String(describing: error), privacy: .public)")
            return nil
        }
    }

    private func tmuxContext(for record: AgentSessionRegistryRecord) -> (paneID: String, socketPath: String, sessionName: String)? {
        guard let paneID = record.tmuxPaneID,
              paneID.isEmpty == false,
              let socketPath = record.tmuxSocketPath,
              socketPath.isEmpty == false,
              let sessionName = tmuxResolver.sessionName(forPaneID: paneID, socketPath: Self.normalizeSocketPath(socketPath)) else {
            return nil
        }
        return (paneID, Self.normalizeSocketPath(socketPath), sessionName)
    }

    private func listWorkspaces() throws -> [JSONValue]? {
        let response = try requestSender(BridgeRequest(id: UUID().uuidString,
                                                       action: "list_workspaces",
                                                       params: nil))
        guard response.ok else {
            return nil
        }
        return response.result?["workspaces"]?.arrayValue
    }

    private func workspaceID(in workspaces: [JSONValue], targetSession: String) -> String? {
        for workspaceValue in workspaces {
            guard let workspace = workspaceValue.objectValue,
                  let workspaceID = workspace["workspace_id"]?.stringValue,
                  workspaceID.isEmpty == false,
                  let ordinaryTmux = workspace["ordinary_tmux"]?.objectValue else {
                continue
            }
            if ordinaryTmux["target_session"]?.stringValue == targetSession {
                return workspaceID
            }
        }
        return nil
    }

    private func carrierPanelID(workspaceID: String, targetSession: String) throws -> String? {
        let response = try requestSender(BridgeRequest(id: UUID().uuidString,
                                                       action: "list_panels",
                                                       params: ["workspace_id": .string(workspaceID)]))
        guard response.ok,
              let panels = response.result?["panels"]?.arrayValue else {
            return nil
        }
        for panelValue in panels {
            guard let panel = panelValue.objectValue,
                  let panelID = panel["panel_id"]?.stringValue,
                  panelID.isEmpty == false,
                  let ordinaryTmux = panel["ordinary_tmux"]?.objectValue,
                  ordinaryTmux["target_session"]?.stringValue == targetSession else {
                continue
            }
            return panelID
        }
        return nil
    }

    private static func normalizeSocketPath(_ path: String) -> String {
        path.replacingOccurrences(of: "/private/tmp/", with: "/tmp/")
    }
}
