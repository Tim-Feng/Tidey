import Foundation

private final class OrdinaryTmuxPaneIdentityReconciliationBatch: @unchecked Sendable {
    typealias Completion = @Sendable (Bool) -> Void

    private let lock = NSLock()
    private let allowsNoCarriers: Bool
    private let completion: Completion
    private var carrierCount = 0
    private var pendingTaskCount = 0
    private var failed = false
    private var sealed = false
    private var resolved = false

    init(allowsNoCarriers: Bool,
         completion: @escaping Completion) {
        self.allowsNoCarriers = allowsNoCarriers
        self.completion = completion
    }

    func recordCarrier() {
        lock.lock()
        carrierCount += 1
        lock.unlock()
    }

    func recordFailure() {
        lock.lock()
        failed = true
        let resolution = resolveIfReadyLocked()
        lock.unlock()
        resolve(resolution)
    }

    func registerTask() {
        lock.lock()
        pendingTaskCount += 1
        lock.unlock()
    }

    func completeTask(succeeded: Bool) {
        lock.lock()
        if succeeded == false {
            failed = true
        }
        pendingTaskCount = max(0, pendingTaskCount - 1)
        let resolution = resolveIfReadyLocked()
        lock.unlock()
        resolve(resolution)
    }

    func seal() {
        lock.lock()
        sealed = true
        if carrierCount == 0, allowsNoCarriers == false {
            failed = true
        }
        let resolution = resolveIfReadyLocked()
        lock.unlock()
        resolve(resolution)
    }

    private func resolveIfReadyLocked() -> Bool? {
        guard sealed, pendingTaskCount == 0, resolved == false else {
            return nil
        }
        resolved = true
        return failed == false
    }

    private func resolve(_ result: Bool?) {
        if let result {
            completion(result)
        }
    }
}

final class OrdinaryTmuxProjectionContext: @unchecked Sendable {
    let registry: OrdinaryTmuxPanelRegistry
    let projector: OrdinaryTmuxPanelProjector

    init(registry: OrdinaryTmuxPanelRegistry = OrdinaryTmuxPanelRegistry()) {
        self.registry = registry
        self.projector = OrdinaryTmuxPanelProjector(registry: registry)
    }
}

final class OrdinaryTmuxPanelProjector {
    static let projectionCooldownInterval: TimeInterval = 10

    private struct CacheEntry {
        let panels: [OrdinaryTmuxProjectedPanel]
        let loadedAt: Date
    }

    private struct ProjectionDisplayState {
        let status: String
        let reason: String
    }

    private struct ProjectedPanelsLoad {
        let panels: [OrdinaryTmuxProjectedPanel]
        let canSetPaneIdentity: Bool
        let canReplaceRegistry: Bool
        let timedOutWithoutCache: Bool
        let displayState: ProjectionDisplayState?
        let unavailableReason: String?
    }

    private let adapter: OrdinaryTmuxWindowProjecting
    private let registry: OrdinaryTmuxPanelRegistry?
    private let cacheTTL: TimeInterval
    private let staleTTL: TimeInterval
    private let registryStaleTTL: TimeInterval
    private let now: @Sendable () -> Date
    private let cacheQueue = DispatchQueue(label: "com.tidey.remote-bridge.ordinary-tmux-panel-projector-cache")
    private let identitySyncQueue = DispatchQueue(label: "com.tidey.remote-bridge.ordinary-tmux-panel-projector-identity",
                                                  qos: .utility)
    private var cache = [String: CacheEntry]()
    private var identityCache = [String: String]()
    private var identityInFlightBatches = [String: [OrdinaryTmuxPaneIdentityReconciliationBatch]]()
    private var projectionCooldownUntilByKey = [String: Date]()

    init(adapter: OrdinaryTmuxWindowProjecting = OrdinaryTmuxCLIAdapter(),
         registry: OrdinaryTmuxPanelRegistry? = nil,
         cacheTTL: TimeInterval = 2,
         staleTTL: TimeInterval = 30,
         registryStaleTTL: TimeInterval = 600,
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.adapter = adapter
        self.registry = registry
        self.cacheTTL = cacheTTL
        self.staleTTL = staleTTL
        self.registryStaleTTL = registryStaleTTL
        self.now = now
    }

    func projectPanelListResult(_ result: [String: JSONValue]) -> [String: JSONValue] {
        projectPanelListResult(result, reconciliationBatch: nil)
    }

    @discardableResult
    func reconcilePaneIdentities(inPanelListResult result: [String: JSONValue],
                                 allowsNoCarriers: Bool = false,
                                 completion: @escaping @Sendable (Bool) -> Void) -> [String: JSONValue] {
        let batch = OrdinaryTmuxPaneIdentityReconciliationBatch(allowsNoCarriers: allowsNoCarriers,
                                                                completion: completion)
        let projectedResult = projectPanelListResult(result, reconciliationBatch: batch)
        batch.seal()
        return projectedResult
    }

    private func projectPanelListResult(_ result: [String: JSONValue],
                                        reconciliationBatch: OrdinaryTmuxPaneIdentityReconciliationBatch?) -> [String: JSONValue] {
        guard let workspaceID = result["workspace_id"]?.stringValue,
              let panels = result["panels"]?.arrayValue else {
            reconciliationBatch?.recordFailure()
            return result
        }

        var didProjectCarrier = false
        var nextPanels = [JSONValue]()
        var registryRoutes = [OrdinaryTmuxPanelRoute]()
        var authoritativeRoutesByCarrier = [String: [OrdinaryTmuxPanelRoute]]()
        var didObserveFreshProjection = false
        var ordinaryCarrierCount = 0
        var everyCarrierProjectionIsAuthoritative = true
        var timedOutSocketKeys = Set<String>()

        for panelValue in panels {
            guard let carrierPanel = panelValue.objectValue else {
                nextPanels.append(panelValue)
                continue
            }
            guard let ordinaryTmuxMetadata = carrierPanel["ordinary_tmux"]?.objectValue else {
                nextPanels.append(panelValue)
                continue
            }
            ordinaryCarrierCount += 1
            reconciliationBatch?.recordCarrier()
            guard let carrierPanelID = carrierPanel["panel_id"]?.stringValue else {
                everyCarrierProjectionIsAuthoritative = false
                reconciliationBatch?.recordFailure()
                BridgeLogger.server.debug("ordinary tmux projection skipped workspace_id=\(workspaceID, privacy: .public) fallback_reason=missing_carrier_panel_id")
                nextPanels.append(panelValue)
                continue
            }
            guard let metadata = OrdinaryTmuxAttachMetadata(json: ordinaryTmuxMetadata) else {
                everyCarrierProjectionIsAuthoritative = false
                reconciliationBatch?.recordFailure()
                BridgeLogger.server.debug("ordinary tmux projection skipped workspace_id=\(workspaceID, privacy: .public) carrier_panel_id=\(carrierPanelID, privacy: .public) fallback_reason=invalid_metadata")
                nextPanels.append(panelValue)
                continue
            }

            BridgeLogger.server.debug("ordinary tmux projection metadata workspace_id=\(workspaceID, privacy: .public) carrier_panel_id=\(carrierPanelID, privacy: .public) tty=\(metadata.clientTTY, privacy: .public) target=\(metadata.targetSession ?? "<default>", privacy: .public)")
            let socketKey = metadata.preferredSocketSelector.cacheKey
            if timedOutSocketKeys.contains(socketKey) {
                everyCarrierProjectionIsAuthoritative = false
                reconciliationBatch?.recordFailure()
                BridgeLogger.server.info("ordinary tmux projection skipped workspace_id=\(workspaceID, privacy: .public) carrier_panel_id=\(carrierPanelID, privacy: .public) socket=\(metadata.preferredSocketSelector.logDescription, privacy: .public) reason=socket_timeout_in_request")
                didProjectCarrier = true
                nextPanels.append(Self.carrierPanelValue(carrierPanel,
                                                         projectionStatus: "unavailable",
                                                         reason: "socket_timeout_in_request"))
                continue
            }

            let projectedLoad: ProjectedPanelsLoad
            do {
                projectedLoad = try cachedProjectedPanels(for: metadata,
                                                          workspaceID: workspaceID,
                                                          carrierPanelID: carrierPanelID)
            } catch {
                everyCarrierProjectionIsAuthoritative = false
                reconciliationBatch?.recordFailure()
                BridgeLogger.server.error("ordinary tmux projection failed workspace_id=\(workspaceID, privacy: .public) carrier_panel_id=\(carrierPanelID, privacy: .public) tty=\(metadata.clientTTY, privacy: .public) target=\(metadata.targetSession ?? "<default>", privacy: .public) fallback_reason=adapter_error error=\(String(describing: error), privacy: .public)")
                nextPanels.append(panelValue)
                continue
            }
            let projectedPanels = projectedLoad.panels
            if projectedLoad.canReplaceRegistry == false {
                everyCarrierProjectionIsAuthoritative = false
            }
            if projectedLoad.timedOutWithoutCache {
                timedOutSocketKeys.insert(socketKey)
            }

            BridgeLogger.server.info("ordinary tmux projection result workspace_id=\(workspaceID, privacy: .public) carrier_panel_id=\(carrierPanelID, privacy: .public) tty=\(metadata.clientTTY, privacy: .public) target=\(metadata.targetSession ?? "<default>", privacy: .public) projected_count=\(projectedPanels.count, privacy: .public)")

            guard projectedPanels.count > 1 else {
                if let projectedPanel = projectedPanels.first {
                    didProjectCarrier = true
                    let route = Self.route(for: projectedPanel,
                                           workspaceID: workspaceID,
                                           carrierPanelID: carrierPanelID,
                                           metadata: metadata,
                                           panelID: carrierPanelID)
                    if projectedLoad.canSetPaneIdentity {
                        schedulePaneIdentitiesIfNeeded(routes: [route],
                                                       reconciliationBatch: reconciliationBatch)
                    } else {
                        reconciliationBatch?.recordFailure()
                        BridgeLogger.server.info("ordinary tmux pane identity sync skipped workspace_id=\(workspaceID, privacy: .public) carrier_panel_id=\(carrierPanelID, privacy: .public) reason=stale_single_window_projection")
                    }
                    BridgeLogger.server.info("ordinary tmux single-window carrier enriched workspace_id=\(workspaceID, privacy: .public) carrier_panel_id=\(carrierPanelID, privacy: .public) pane_id=\(projectedPanel.activePaneID, privacy: .public) pane_pid=\(projectedPanel.activePanePID.map(String.init) ?? "-", privacy: .public) current_command=\(projectedPanel.currentCommand ?? "-", privacy: .public) socket_path=\(projectedPanel.socketPath ?? "-", privacy: .public)")
                    if projectedLoad.canReplaceRegistry {
                        didObserveFreshProjection = true
                        registryRoutes.append(route)
                        authoritativeRoutesByCarrier[carrierPanelID] = [route]
                    }
                    nextPanels.append(Self.carrierPanelValue(for: projectedPanel,
                                                             carrierPanel: carrierPanel,
                                                             workspaceID: workspaceID,
                                                             carrierPanelID: carrierPanelID,
                                                             displayState: projectedLoad.displayState))
                } else if let unavailableReason = projectedLoad.unavailableReason {
                    reconciliationBatch?.recordFailure()
                    didProjectCarrier = true
                    BridgeLogger.server.info("ordinary tmux projection unavailable workspace_id=\(workspaceID, privacy: .public) carrier_panel_id=\(carrierPanelID, privacy: .public) reason=\(unavailableReason, privacy: .public)")
                    nextPanels.append(Self.carrierPanelValue(carrierPanel,
                                                             projectionStatus: "unavailable",
                                                             reason: unavailableReason))
                } else {
                    reconciliationBatch?.recordFailure()
                    BridgeLogger.server.debug("ordinary tmux projection skipped workspace_id=\(workspaceID, privacy: .public) carrier_panel_id=\(carrierPanelID, privacy: .public) projected_count=0 fallback_reason=no_windows")
                    if projectedLoad.canReplaceRegistry {
                        didObserveFreshProjection = true
                        authoritativeRoutesByCarrier[carrierPanelID] = []
                    }
                    nextPanels.append(panelValue)
                }
                continue
            }

            didProjectCarrier = true
            let projectedRoutes = projectedPanels.map {
                Self.route(for: $0,
                           workspaceID: workspaceID,
                           carrierPanelID: carrierPanelID,
                           metadata: metadata)
            }
            if projectedLoad.canSetPaneIdentity {
                schedulePaneIdentitiesIfNeeded(routes: projectedRoutes,
                                               reconciliationBatch: reconciliationBatch)
            } else {
                reconciliationBatch?.recordFailure()
                BridgeLogger.server.info("ordinary tmux pane identity sync skipped workspace_id=\(workspaceID, privacy: .public) carrier_panel_id=\(carrierPanelID, privacy: .public) reason=stale_projection")
            }
            if projectedLoad.canReplaceRegistry {
                didObserveFreshProjection = true
                registryRoutes.append(contentsOf: projectedRoutes)
                authoritativeRoutesByCarrier[carrierPanelID] = projectedRoutes
            }
            nextPanels.append(contentsOf: projectedPanels.map {
                Self.panelValue(for: $0,
                                carrierPanel: carrierPanel,
                                workspaceID: workspaceID,
                                carrierPanelID: carrierPanelID,
                                displayState: projectedLoad.displayState)
            })
        }

        if ordinaryCarrierCount == 0 {
            registry?.replaceRoutesAuthoritatively(workspaceID: workspaceID, routes: [], observedAt: now())
        } else if everyCarrierProjectionIsAuthoritative, didObserveFreshProjection {
            registry?.replaceRoutesAuthoritatively(workspaceID: workspaceID,
                                                   routes: registryRoutes,
                                                   observedAt: now())
        } else {
            let observedAt = now()
            for (carrierPanelID, routes) in authoritativeRoutesByCarrier {
                registry?.replaceRoutes(workspaceID: workspaceID,
                                        carrierPanelID: carrierPanelID,
                                        routes: routes,
                                        observedAt: observedAt)
            }
        }

        guard didProjectCarrier else {
            return result
        }

        let indexedPanels = nextPanels.enumerated().map { index, panelValue -> JSONValue in
            guard var panel = panelValue.objectValue else {
                return panelValue
            }
            panel["panel_index"] = .number(Double(index))
            return .object(panel)
        }

        var projectedResult = result
        projectedResult["panels"] = .array(indexedPanels)
        projectedResult["selected_panel_id"] = selectedPanelID(from: indexedPanels) ?? result["selected_panel_id"]
        return projectedResult
    }

    private func cachedProjectedPanels(for metadata: OrdinaryTmuxAttachMetadata,
                                       workspaceID: String,
                                       carrierPanelID: String) throws -> ProjectedPanelsLoad {
        let key = Self.cacheKey(metadata: metadata, workspaceID: workspaceID, carrierPanelID: carrierPanelID)
        let currentDate = now()

        if let entry = cacheQueue.sync(execute: { cache[key] }),
           currentDate.timeIntervalSince(entry.loadedAt) < cacheTTL {
            return ProjectedPanelsLoad(panels: entry.panels,
                                       canSetPaneIdentity: true,
                                       canReplaceRegistry: true,
                                       timedOutWithoutCache: false,
                                       displayState: nil,
                                       unavailableReason: nil)
        }

        if isProjectionInCooldown(for: key, at: currentDate) {
            if let staleLoad = staleProjectedPanelsLoad(for: key,
                                                        currentDate: currentDate,
                                                        workspaceID: workspaceID,
                                                        carrierPanelID: carrierPanelID,
                                                        reason: "cooldown") {
                return staleLoad
            }
            BridgeLogger.server.info("ordinary tmux projection skipped workspace_id=\(workspaceID, privacy: .public) carrier_panel_id=\(carrierPanelID, privacy: .public) reason=timeout_cooldown_no_cache")
            return ProjectedPanelsLoad(panels: [],
                                       canSetPaneIdentity: false,
                                       canReplaceRegistry: false,
                                       timedOutWithoutCache: false,
                                       displayState: nil,
                                       unavailableReason: "cooldown_no_cache")
        }

        let recoveredFromCooldown = consumeExpiredProjectionCooldown(for: key, at: currentDate)
        do {
            let panels = try adapter.projectedPanels(for: metadata)
            cacheQueue.sync {
                cache[key] = CacheEntry(panels: panels, loadedAt: currentDate)
            }
            registry?.storeProjectionSnapshot(key: key,
                                              panels: panels,
                                              observedAt: currentDate)
            if recoveredFromCooldown {
                BridgeLogger.server.info("ordinary tmux projection recovered from timeout cooldown workspace_id=\(workspaceID, privacy: .public) carrier_panel_id=\(carrierPanelID, privacy: .public) projected_count=\(panels.count, privacy: .public)")
            }
            return ProjectedPanelsLoad(panels: panels,
                                       canSetPaneIdentity: true,
                                       canReplaceRegistry: true,
                                       timedOutWithoutCache: false,
                                       displayState: nil,
                                       unavailableReason: nil)
        } catch {
            if Self.isTmuxCommandTimeout(error) {
                enterProjectionCooldown(for: key, at: currentDate)
                if let staleLoad = staleProjectedPanelsLoad(for: key,
                                                            currentDate: currentDate,
                                                            workspaceID: workspaceID,
                                                            carrierPanelID: carrierPanelID,
                                                            reason: "timeout") {
                    return staleLoad
                }
                BridgeLogger.server.error("ordinary tmux projection timed out without cache workspace_id=\(workspaceID, privacy: .public) carrier_panel_id=\(carrierPanelID, privacy: .public) cooldown_seconds=\(Self.projectionCooldownInterval, privacy: .public)")
                return ProjectedPanelsLoad(panels: [],
                                           canSetPaneIdentity: false,
                                           canReplaceRegistry: false,
                                           timedOutWithoutCache: true,
                                           displayState: nil,
                                           unavailableReason: "timeout_no_cache")
            }
            if let staleLoad = staleProjectedPanelsLoad(for: key,
                                                        currentDate: currentDate,
                                                        workspaceID: workspaceID,
                                                        carrierPanelID: carrierPanelID,
                                                        reason: "error") {
                return staleLoad
            }
            BridgeLogger.server.error("ordinary tmux projection failed without cache workspace_id=\(workspaceID, privacy: .public) carrier_panel_id=\(carrierPanelID, privacy: .public) fallback_reason=adapter_error_no_cache error=\(String(describing: error), privacy: .public)")
            return ProjectedPanelsLoad(panels: [],
                                       canSetPaneIdentity: false,
                                       canReplaceRegistry: false,
                                       timedOutWithoutCache: false,
                                       displayState: nil,
                                       unavailableReason: "error_no_cache")
        }
    }

    private func isProjectionInCooldown(for key: String, at currentDate: Date) -> Bool {
        cacheQueue.sync {
            guard let projectionCooldownUntil = projectionCooldownUntilByKey[key] else {
                return false
            }
            return currentDate < projectionCooldownUntil
        }
    }

    private func consumeExpiredProjectionCooldown(for key: String, at currentDate: Date) -> Bool {
        cacheQueue.sync {
            guard let projectionCooldownUntil = projectionCooldownUntilByKey[key],
                  currentDate >= projectionCooldownUntil else {
                return false
            }
            self.projectionCooldownUntilByKey[key] = nil
            return true
        }
    }

    private func enterProjectionCooldown(for key: String, at currentDate: Date) {
        cacheQueue.sync {
            projectionCooldownUntilByKey[key] = currentDate.addingTimeInterval(Self.projectionCooldownInterval)
        }
    }

    private func staleProjectedPanelsLoad(for key: String,
                                          currentDate: Date,
                                          workspaceID: String,
                                          carrierPanelID: String,
                                          reason: String) -> ProjectedPanelsLoad? {
        let displayState = ProjectionDisplayState(status: "stale", reason: reason)
        if let entry = cacheQueue.sync(execute: { cache[key] }),
           currentDate.timeIntervalSince(entry.loadedAt) < staleTTL {
            BridgeLogger.server.error("ordinary tmux projection using stale cache workspace_id=\(workspaceID, privacy: .public) carrier_panel_id=\(carrierPanelID, privacy: .public) reason=\(reason, privacy: .public)")
            return ProjectedPanelsLoad(panels: entry.panels,
                                       canSetPaneIdentity: false,
                                       canReplaceRegistry: false,
                                       timedOutWithoutCache: false,
                                       displayState: displayState,
                                       unavailableReason: nil)
        }
        if let snapshot = registry?.projectionSnapshot(key: key,
                                                       maxAge: registryStaleTTL,
                                                       now: currentDate) {
            BridgeLogger.server.error("ordinary tmux projection using registry stale snapshot workspace_id=\(workspaceID, privacy: .public) carrier_panel_id=\(carrierPanelID, privacy: .public) reason=\(reason, privacy: .public)")
            return ProjectedPanelsLoad(panels: snapshot.panels,
                                       canSetPaneIdentity: false,
                                       canReplaceRegistry: false,
                                       timedOutWithoutCache: false,
                                       displayState: displayState,
                                       unavailableReason: nil)
        }
        return nil
    }

    private func schedulePaneIdentitiesIfNeeded(routes: [OrdinaryTmuxPanelRoute],
                                                reconciliationBatch: OrdinaryTmuxPaneIdentityReconciliationBatch? = nil) {
        var routesToSync = [(route: OrdinaryTmuxPanelRoute, operationKey: String)]()
        for route in routes {
            let key = Self.identityCacheKey(route: route)
            let operationKey = Self.identityOperationKey(route: route)
            let decision = cacheQueue.sync { () -> Int in
                if identityInFlightBatches[operationKey] != nil {
                    if let reconciliationBatch {
                        reconciliationBatch.registerTask()
                        identityInFlightBatches[operationKey, default: []].append(reconciliationBatch)
                    }
                    return 1
                }
                if identityCache[key] == route.panelID, reconciliationBatch == nil {
                    return 0
                }
                if let reconciliationBatch {
                    reconciliationBatch.registerTask()
                    identityInFlightBatches[operationKey] = [reconciliationBatch]
                } else {
                    identityInFlightBatches[operationKey] = []
                }
                return 2
            }

            if decision == 0 {
                BridgeLogger.server.info("ordinary tmux pane identity sync skipped workspace_id=\(route.workspaceID, privacy: .public) panel_id=\(route.panelID, privacy: .public) window_id=\(route.windowID, privacy: .public) pane_id=\(route.activePaneID, privacy: .public) reason=already_set")
                continue
            }
            if decision == 1 {
                BridgeLogger.server.info("ordinary tmux pane identity sync joined workspace_id=\(route.workspaceID, privacy: .public) panel_id=\(route.panelID, privacy: .public) window_id=\(route.windowID, privacy: .public) pane_id=\(route.activePaneID, privacy: .public) reason=write_in_flight")
                continue
            }
            routesToSync.append((route, operationKey))
        }

        guard routesToSync.isEmpty == false else {
            return
        }

        identitySyncQueue.async { [self] in
            for item in routesToSync {
                let route = item.route
                let key = Self.identityCacheKey(route: route)
                let succeeded: Bool
                do {
                    try adapter.setPaneIdentity(route: route)
                    succeeded = true
                    BridgeLogger.server.info("ordinary tmux pane identity sync set workspace_id=\(route.workspaceID, privacy: .public) panel_id=\(route.panelID, privacy: .public) window_id=\(route.windowID, privacy: .public) pane_id=\(route.activePaneID, privacy: .public)")
                } catch {
                    succeeded = false
                    BridgeLogger.server.error("ordinary tmux pane identity sync failed workspace_id=\(route.workspaceID, privacy: .public) panel_id=\(route.panelID, privacy: .public) window_id=\(route.windowID, privacy: .public) pane_id=\(route.activePaneID, privacy: .public) error=\(String(describing: error), privacy: .public)")
                }
                let batches = cacheQueue.sync { () -> [OrdinaryTmuxPaneIdentityReconciliationBatch] in
                    let batches = identityInFlightBatches.removeValue(forKey: item.operationKey) ?? []
                    if succeeded {
                        identityCache[key] = route.panelID
                    }
                    return batches
                }
                for batch in batches {
                    batch.completeTask(succeeded: succeeded)
                }
            }
        }
    }

    private func selectedPanelID(from panels: [JSONValue]) -> JSONValue? {
        let selectedPanelID = panels
            .compactMap(\.objectValue)
            .first { $0["selected"]?.boolLikeValue == true }?["panel_id"]?.stringValue
        if let selectedPanelID {
            return .string(selectedPanelID)
        }
        return panels.first?.objectValue?["panel_id"]?.stringValue.map(JSONValue.string)
    }

    private static func panelValue(for projectedPanel: OrdinaryTmuxProjectedPanel,
                                   carrierPanel: [String: JSONValue],
                                   workspaceID: String,
                                   carrierPanelID: String,
                                   displayState: ProjectionDisplayState?) -> JSONValue {
        var panel: [String: JSONValue] = [
            "panel_id": .string(projectedPanel.panelID),
            "workspace_id": .string(workspaceID),
            "title": .string(projectedPanel.title),
            "subtitle": .string(projectedPanel.subtitle),
            "state": carrierPanel["state"] ?? .string("idle"),
            "selected": .bool(projectedPanel.isCurrentWindow),
            "is_browser": .bool(false),
            "workspace_index": carrierPanel["workspace_index"] ?? .number(0),
            "ordinary_tmux_logical": .object([
                "carrier_panel_id": .string(carrierPanelID),
                "session_id": .string(projectedPanel.sessionID),
                "session_name": .string(projectedPanel.sessionName),
                "window_id": .string(projectedPanel.windowID),
                "window_index": .number(Double(projectedPanel.windowIndex)),
                "window_name": .string(projectedPanel.windowName),
                "active_pane_id": .string(projectedPanel.activePaneID),
            ]),
        ]

        if let activePanePID = projectedPanel.activePanePID {
            panel["effective_shell_pid"] = .number(Double(activePanePID))
        }
        if let windowGUID = carrierPanel["window_guid"] {
            panel["window_guid"] = windowGUID
        }
        if let cwd = projectedPanel.cwd {
            panel["cwd"] = .string(cwd)
        }
        if let currentCommand = projectedPanel.currentCommand {
            panel["current_command"] = .string(currentCommand)
        }
        if let socketPath = projectedPanel.socketPath {
            var logical = panel["ordinary_tmux_logical"]?.objectValue ?? [:]
            logical["socket_path"] = .string(socketPath)
            panel["ordinary_tmux_logical"] = .object(logical)
        }
        applyProjectionDisplayState(displayState, to: &panel)
        return .object(panel)
    }

    private static func carrierPanelValue(for projectedPanel: OrdinaryTmuxProjectedPanel,
                                          carrierPanel: [String: JSONValue],
                                          workspaceID: String,
                                          carrierPanelID: String,
                                          displayState: ProjectionDisplayState?) -> JSONValue {
        var panel = carrierPanel
        panel["panel_id"] = .string(carrierPanelID)
        panel["workspace_id"] = .string(workspaceID)

        var logical = panel["ordinary_tmux_logical"]?.objectValue ?? [:]
        logical["carrier_panel_id"] = .string(carrierPanelID)
        logical["session_id"] = .string(projectedPanel.sessionID)
        logical["session_name"] = .string(projectedPanel.sessionName)
        logical["window_id"] = .string(projectedPanel.windowID)
        logical["window_index"] = .number(Double(projectedPanel.windowIndex))
        logical["window_name"] = .string(projectedPanel.windowName)
        logical["active_pane_id"] = .string(projectedPanel.activePaneID)

        if let activePanePID = projectedPanel.activePanePID {
            panel["effective_shell_pid"] = .number(Double(activePanePID))
        }
        if let cwd = projectedPanel.cwd {
            panel["cwd"] = .string(cwd)
        }
        if let currentCommand = projectedPanel.currentCommand {
            panel["current_command"] = .string(currentCommand)
        }
        if let socketPath = projectedPanel.socketPath {
            logical["socket_path"] = .string(socketPath)
        }
        panel["ordinary_tmux_logical"] = .object(logical)
        applyProjectionDisplayState(displayState, to: &panel)
        return .object(panel)
    }

    private static func carrierPanelValue(_ carrierPanel: [String: JSONValue],
                                          projectionStatus: String,
                                          reason: String) -> JSONValue {
        var panel = carrierPanel
        panel["ordinary_tmux_projection"] = .object([
            "status": .string(projectionStatus),
            "reason": .string(reason),
        ])
        return .object(panel)
    }

    private static func applyProjectionDisplayState(_ displayState: ProjectionDisplayState?,
                                                    to panel: inout [String: JSONValue]) {
        guard let displayState else {
            return
        }
        panel["ordinary_tmux_projection"] = .object([
            "status": .string(displayState.status),
            "reason": .string(displayState.reason),
        ])
    }

    private static func route(for projectedPanel: OrdinaryTmuxProjectedPanel,
                              workspaceID: String,
                              carrierPanelID: String,
                              metadata: OrdinaryTmuxAttachMetadata,
                              panelID: String? = nil) -> OrdinaryTmuxPanelRoute {
        OrdinaryTmuxPanelRoute(
            workspaceID: workspaceID,
            panelID: panelID ?? projectedPanel.panelID,
            carrierPanelID: carrierPanelID,
            socket: projectedPanel.socketPath.map(OrdinaryTmuxSocketSelector.path) ?? metadata.preferredSocketSelector,
            sessionID: projectedPanel.sessionID,
            sessionName: projectedPanel.sessionName,
            windowID: projectedPanel.windowID,
            windowIndex: projectedPanel.windowIndex,
            activePaneID: projectedPanel.activePaneID,
            cwd: projectedPanel.cwd,
            currentCommand: projectedPanel.currentCommand
        )
    }

    private static func cacheKey(metadata: OrdinaryTmuxAttachMetadata,
                                 workspaceID: String,
                                 carrierPanelID: String) -> String {
        [
            workspaceID,
            carrierPanelID,
            metadata.preferredSocketSelector.cacheKey,
            metadata.clientTTY,
            metadata.targetSession ?? "-",
        ].joined(separator: "|")
    }

    private static func identityCacheKey(route: OrdinaryTmuxPanelRoute) -> String {
        [
            route.workspaceID,
            route.socket.cacheKey,
            route.sessionID,
            route.windowID,
            route.activePaneID,
        ].joined(separator: "|")
    }

    private static func identityOperationKey(route: OrdinaryTmuxPanelRoute) -> String {
        [identityCacheKey(route: route), route.panelID].joined(separator: "|")
    }

    private static func isTmuxCommandTimeout(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == "OrdinaryTmuxCLIAdapter" && nsError.code == 124
    }
}
