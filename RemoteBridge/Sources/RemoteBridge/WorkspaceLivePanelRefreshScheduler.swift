import Foundation

protocol LivePanelRegistryUpdating: AnyObject {
    func replaceLivePanels(workspaceID: String, panels: [AgentPanelProcessSnapshot])
    func pruneLivePanels(toWorkspaceIDs workspaceIDs: Set<String>)
}

extension AgentSessionRegistryMonitor: LivePanelRegistryUpdating {}

protocol PanelListResultProjecting {
    func projectPanelListResult(_ result: [String: JSONValue]) -> [String: JSONValue]
}

extension OrdinaryTmuxPanelProjector: PanelListResultProjecting {}

final class WorkspaceLivePanelRefreshScheduler {
    private let socketSender: TideyRequestSending
    private weak var registry: LivePanelRegistryUpdating?
    private let projector: PanelListResultProjecting
    private let stateQueue = DispatchQueue(label: "com.tidey.remote-bridge.workspace-live-panel-refresh.state")
    private let refreshQueue = DispatchQueue(label: "com.tidey.remote-bridge.workspace-live-panel-refresh.worker",
                                             qos: .utility)
    private var pendingWorkspaceIDs = Set<String>()
    private var isRunning = false

    init(socketSender: TideyRequestSending,
         registry: LivePanelRegistryUpdating,
         projector: PanelListResultProjecting) {
        self.socketSender = socketSender
        self.registry = registry
        self.projector = projector
    }

    func scheduleRefresh(forListedWorkspaces result: [String: JSONValue]) {
        guard let workspaces = result["workspaces"]?.arrayValue else {
            return
        }

        let workspaceIDs = Set(workspaces.compactMap { $0.objectValue?["workspace_id"]?.stringValue })
        registry?.pruneLivePanels(toWorkspaceIDs: workspaceIDs)
        guard workspaceIDs.isEmpty == false else {
            return
        }

        let shouldStartWorker = stateQueue.sync { () -> Bool in
            pendingWorkspaceIDs.formUnion(workspaceIDs)
            guard isRunning == false else {
                return false
            }
            isRunning = true
            return true
        }

        if shouldStartWorker {
            BridgeLogger.server.debug("workspace live panel refresh scheduled workspace_count=\(workspaceIDs.count, privacy: .public)")
            refreshQueue.async { [weak self] in
                self?.runRefreshLoop()
            }
        } else {
            BridgeLogger.server.debug("workspace live panel refresh coalesced workspace_count=\(workspaceIDs.count, privacy: .public)")
        }
    }

    private func runRefreshLoop() {
        while true {
            let workspaceIDs = stateQueue.sync { () -> Set<String>? in
                guard pendingWorkspaceIDs.isEmpty == false else {
                    isRunning = false
                    return nil
                }
                let workspaceIDs = pendingWorkspaceIDs
                pendingWorkspaceIDs.removeAll()
                return workspaceIDs
            }

            guard let workspaceIDs else {
                BridgeLogger.server.debug("workspace live panel refresh idle")
                return
            }

            refresh(workspaceIDs: workspaceIDs)
        }
    }

    private func refresh(workspaceIDs: Set<String>) {
        BridgeLogger.server.debug("workspace live panel refresh start workspace_count=\(workspaceIDs.count, privacy: .public)")
        var refreshedCount = 0
        var failedCount = 0

        for workspaceID in workspaceIDs.sorted() {
            let request = BridgeRequest(id: UUID().uuidString,
                                        action: "list_panels",
                                        params: ["workspace_id": .string(workspaceID)])
            do {
                let panelResponse = try socketSender.send(request)
                guard panelResponse.ok, let panelResult = panelResponse.result else {
                    failedCount += 1
                    BridgeLogger.server.debug("workspace live panel refresh skipped workspace_id=\(workspaceID, privacy: .public) reason=panel_response_not_ok")
                    continue
                }

                let projectedResult = projector.projectPanelListResult(panelResult)
                guard let extracted = AgentPanelProcessSnapshotExtractor.snapshots(fromPanelListResult: projectedResult) else {
                    failedCount += 1
                    BridgeLogger.server.debug("workspace live panel refresh skipped workspace_id=\(workspaceID, privacy: .public) reason=invalid_panel_result")
                    continue
                }

                registry?.replaceLivePanels(workspaceID: extracted.workspaceID, panels: extracted.snapshots)
                refreshedCount += 1
            } catch {
                failedCount += 1
                BridgeLogger.server.debug("workspace live panel refresh failed workspace_id=\(workspaceID, privacy: .public) error=\(String(describing: error), privacy: .public)")
            }
        }

        BridgeLogger.server.debug("workspace live panel refresh finish refreshed_count=\(refreshedCount, privacy: .public) failed_count=\(failedCount, privacy: .public)")
    }
}
