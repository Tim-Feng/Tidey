import Foundation

/// Reconciles pane-scoped Tidey identity after an ordinary tmux carrier is
/// discovered through the workspace-event stream. Remote clients can receive
/// `panel_created` / `panel_updated` without issuing another `list_panels`, so
/// the event path must independently fetch the authoritative complete list.
final class OrdinaryTmuxPaneIdentityReconciler: @unchecked Sendable {
    typealias RequestSender = @Sendable (BridgeRequest) throws -> BridgeResponse
    typealias PanelListProjector = @Sendable ([String: JSONValue], Bool, @escaping @Sendable (Bool) -> Void) -> Void
    typealias CarrierOwnershipLookup = @Sendable (String, String) -> Bool
    typealias WorkspaceOwnershipLookup = @Sendable (String) -> Bool
    typealias CarrierRoutesCleaner = @Sendable (String, String) -> Void
    typealias WorkspaceRoutesCleaner = @Sendable (String) -> Void
    static let defaultRetryDelays = Array(repeating: OrdinaryTmuxPanelProjector.projectionCooldownInterval + 0.25,
                                          count: 3)

    private struct WorkspaceState {
        var generation = 0
        var isScheduled = false
        var isInFlight = false
        var needsFollowUp = false
        var allowsNoCarriers = false
        var carrierPanelIDsToClear = Set<String>()
        var workspaceClosed = false
    }

    private let requestSender: RequestSender
    private let projectPanelList: PanelListProjector
    private let hasCarrierOwnership: CarrierOwnershipLookup
    private let hasWorkspaceOwnership: WorkspaceOwnershipLookup
    private let removeCarrierRoutes: CarrierRoutesCleaner
    private let removeWorkspaceRoutes: WorkspaceRoutesCleaner
    private let debounceInterval: TimeInterval
    private let retryDelays: [TimeInterval]
    private let stateQueue = DispatchQueue(label: "com.tidey.remote-bridge.tmux-pane-identity-reconciler-state")
    private let workerQueue = DispatchQueue(label: "com.tidey.remote-bridge.tmux-pane-identity-reconciler-worker",
                                            qos: .utility,
                                            attributes: .concurrent)
    private var states = [String: WorkspaceState]()

    convenience init(socketClient: TideySocketClient,
                     projectionContext: OrdinaryTmuxProjectionContext,
                     debounceInterval: TimeInterval = 0.15,
                     retryDelays: [TimeInterval] = OrdinaryTmuxPaneIdentityReconciler.defaultRetryDelays) {
        self.init(requestSender: { request in
            try socketClient.send(request)
        }, projectPanelList: { result, allowsNoCarriers, completion in
            projectionContext.projector.reconcilePaneIdentities(inPanelListResult: result,
                                                                 allowsNoCarriers: allowsNoCarriers,
                                                                 completion: completion)
        }, hasCarrierOwnership: { workspaceID, carrierPanelID in
            projectionContext.registry.hasCarrierOwnership(workspaceID: workspaceID,
                                                           carrierPanelID: carrierPanelID)
        }, hasWorkspaceOwnership: { workspaceID in
            projectionContext.registry.hasWorkspaceOwnership(workspaceID: workspaceID)
        }, removeCarrierRoutes: { workspaceID, carrierPanelID in
            projectionContext.registry.replaceRoutes(workspaceID: workspaceID,
                                                      carrierPanelID: carrierPanelID,
                                                      routes: [])
        }, removeWorkspaceRoutes: { workspaceID in
            projectionContext.registry.replaceRoutesAuthoritatively(workspaceID: workspaceID, routes: [])
        }, debounceInterval: debounceInterval,
           retryDelays: retryDelays)
    }

    init(requestSender: @escaping RequestSender,
         projectPanelList: @escaping PanelListProjector,
         hasCarrierOwnership: @escaping CarrierOwnershipLookup = { _, _ in false },
         hasWorkspaceOwnership: @escaping WorkspaceOwnershipLookup = { _ in false },
         removeCarrierRoutes: @escaping CarrierRoutesCleaner = { _, _ in },
         removeWorkspaceRoutes: @escaping WorkspaceRoutesCleaner = { _ in },
         debounceInterval: TimeInterval = 0.15,
         retryDelays: [TimeInterval] = OrdinaryTmuxPaneIdentityReconciler.defaultRetryDelays) {
        self.requestSender = requestSender
        self.projectPanelList = projectPanelList
        self.hasCarrierOwnership = hasCarrierOwnership
        self.hasWorkspaceOwnership = hasWorkspaceOwnership
        self.removeCarrierRoutes = removeCarrierRoutes
        self.removeWorkspaceRoutes = removeWorkspaceRoutes
        self.debounceInterval = max(0, debounceInterval)
        self.retryDelays = retryDelays.map { max(0, $0) }
    }

    func observe(_ event: WorkspaceEvent) {
        guard let workspaceID = Self.nonEmpty(event.workspaceID
            ?? event.panel?["workspace_id"]?.stringValue
            ?? event.workspace?["workspace_id"]?.stringValue) else {
            return
        }
        let hasOrdinaryTmuxMetadata = Self.hasValidOrdinaryTmuxMetadata(event.panel)

        if event.kind == .workspaceClosed {
            let hadRegistryOwnership = hasWorkspaceOwnership(workspaceID)
            stateQueue.async {
                guard hasOrdinaryTmuxMetadata
                        || hadRegistryOwnership
                        || self.states[workspaceID] != nil
                        || self.hasWorkspaceOwnership(workspaceID) else {
                    return
                }
                var state = self.states[workspaceID] ?? WorkspaceState()
                state.generation += 1
                state.isScheduled = false
                state.needsFollowUp = false
                state.workspaceClosed = true
                self.removeWorkspaceRoutes(workspaceID)
                if state.isInFlight {
                    self.states[workspaceID] = state
                } else {
                    self.states.removeValue(forKey: workspaceID)
                }
            }
            return
        }

        guard let panelID = Self.nonEmpty(event.panelID ?? event.panel?["panel_id"]?.stringValue) else {
            return
        }
        let shouldClearCarrier: Bool
        let allowsNoCarriers: Bool
        switch event.kind {
        case .panelCreated:
            guard hasOrdinaryTmuxMetadata else {
                return
            }
            shouldClearCarrier = false
            allowsNoCarriers = false
        case .panelUpdated:
            guard hasOrdinaryTmuxMetadata
                    || hasCarrierOwnership(workspaceID, panelID) else {
                return
            }
            shouldClearCarrier = false
            allowsNoCarriers = hasOrdinaryTmuxMetadata == false
        case .panelClosed:
            guard hasOrdinaryTmuxMetadata
                    || hasCarrierOwnership(workspaceID, panelID) else {
                return
            }
            shouldClearCarrier = true
            allowsNoCarriers = true
        default:
            return
        }

        stateQueue.async {
            var state = self.states[workspaceID] ?? WorkspaceState()
            state.workspaceClosed = false
            state.allowsNoCarriers = state.allowsNoCarriers || allowsNoCarriers
            if shouldClearCarrier {
                self.removeCarrierRoutes(workspaceID, panelID)
                state.carrierPanelIDsToClear.insert(panelID)
            } else {
                state.carrierPanelIDsToClear.remove(panelID)
            }
            if state.isInFlight {
                state.needsFollowUp = true
                self.states[workspaceID] = state
                return
            }
            self.states[workspaceID] = state
            self.scheduleLocked(workspaceID: workspaceID,
                                attempt: 0,
                                delay: self.debounceInterval)
        }
    }

    private static func hasValidOrdinaryTmuxMetadata(_ panel: [String: JSONValue]?) -> Bool {
        guard let metadata = panel?["ordinary_tmux"]?.objectValue else {
            return false
        }
        return OrdinaryTmuxAttachMetadata(json: metadata) != nil
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Must only be called on `stateQueue`.
    private func scheduleLocked(workspaceID: String,
                                attempt: Int,
                                delay: TimeInterval) {
        var state = states[workspaceID] ?? WorkspaceState()
        state.generation += 1
        state.isScheduled = true
        let generation = state.generation
        states[workspaceID] = state

        stateQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.beginLocked(workspaceID: workspaceID,
                              generation: generation,
                              attempt: attempt)
        }
    }

    /// Must only be called on `stateQueue`.
    private func beginLocked(workspaceID: String,
                             generation: Int,
                             attempt: Int) {
        guard var state = states[workspaceID],
              state.generation == generation,
              state.isScheduled,
              state.isInFlight == false else {
            return
        }
        state.isScheduled = false
        state.isInFlight = true
        states[workspaceID] = state
        let allowsNoCarriers = state.allowsNoCarriers

        workerQueue.async { [weak self] in
            guard let self else {
                return
            }
            self.reconcile(workspaceID: workspaceID,
                           allowsNoCarriers: allowsNoCarriers) { [weak self] succeeded, didProject in
                self?.stateQueue.async {
                    self?.finishLocked(workspaceID: workspaceID,
                                       attempt: attempt,
                                       succeeded: succeeded,
                                       didProject: didProject)
                }
            }
        }
    }

    private func reconcile(workspaceID: String,
                           allowsNoCarriers: Bool,
                           completion: @escaping @Sendable (Bool, Bool) -> Void) {
        do {
            let request = BridgeRequest(id: "tmux-pane-identity-\(UUID().uuidString)",
                                        action: "list_panels",
                                        params: ["workspace_id": .string(workspaceID)])
            let response = try requestSender(request)
            if response.ok == false,
               allowsNoCarriers,
               response.error?.code == "workspace_not_found" {
                removeWorkspaceRoutes(workspaceID)
                BridgeLogger.server.info("ordinary tmux close reconciliation observed removed workspace workspace_id=\(workspaceID, privacy: .public)")
                completion(true, false)
                return
            }
            guard response.ok,
                  let result = response.result,
                  result["workspace_id"]?.stringValue == workspaceID,
                  result["panels"]?.arrayValue != nil else {
                throw BridgeInternalError.invalidResponse
            }
            projectPanelList(result, allowsNoCarriers) { succeeded in
                if succeeded {
                    BridgeLogger.server.info("ordinary tmux event reconciliation projected workspace_id=\(workspaceID, privacy: .public)")
                } else {
                    BridgeLogger.server.error("ordinary tmux event reconciliation projection incomplete workspace_id=\(workspaceID, privacy: .public)")
                }
                completion(succeeded, true)
            }
        } catch {
            BridgeLogger.server.error("ordinary tmux event reconciliation failed workspace_id=\(workspaceID, privacy: .public) error=\(String(describing: error), privacy: .public)")
            completion(false, false)
        }
    }

    /// Must only be called on `stateQueue`.
    private func finishLocked(workspaceID: String,
                              attempt: Int,
                              succeeded: Bool,
                              didProject: Bool) {
        guard var state = states[workspaceID] else {
            return
        }
        state.isInFlight = false

        if didProject {
            for carrierPanelID in state.carrierPanelIDsToClear {
                removeCarrierRoutes(workspaceID, carrierPanelID)
            }
        }
        if state.workspaceClosed {
            removeWorkspaceRoutes(workspaceID)
            states.removeValue(forKey: workspaceID)
            return
        }

        if state.needsFollowUp {
            state.needsFollowUp = false
            states[workspaceID] = state
            scheduleLocked(workspaceID: workspaceID,
                           attempt: 0,
                           delay: debounceInterval)
            return
        }

        if succeeded == false, attempt < retryDelays.count {
            states[workspaceID] = state
            scheduleLocked(workspaceID: workspaceID,
                           attempt: attempt + 1,
                           delay: retryDelays[attempt])
            return
        }

        states.removeValue(forKey: workspaceID)
    }
}
