import Foundation

final class OrdinaryTmuxPanelProjector {
    private struct CacheEntry {
        let panels: [OrdinaryTmuxProjectedPanel]
        let loadedAt: Date
    }

    private struct ProjectedPanelsLoad {
        let panels: [OrdinaryTmuxProjectedPanel]
        let canSetPaneIdentity: Bool
        let canReplaceRegistry: Bool
    }

    private let adapter: OrdinaryTmuxWindowProjecting
    private let registry: OrdinaryTmuxPanelRegistry?
    private let cacheTTL: TimeInterval
    private let staleTTL: TimeInterval
    private let now: @Sendable () -> Date
    private let cacheQueue = DispatchQueue(label: "com.tidey.remote-bridge.ordinary-tmux-panel-projector-cache")
    private var cache = [String: CacheEntry]()
    private var identityCache = [String: String]()
    private var projectionCooldownUntilByKey = [String: Date]()

    init(adapter: OrdinaryTmuxWindowProjecting = OrdinaryTmuxCLIAdapter(),
         registry: OrdinaryTmuxPanelRegistry? = nil,
         cacheTTL: TimeInterval = 2,
         staleTTL: TimeInterval = 30,
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.adapter = adapter
        self.registry = registry
        self.cacheTTL = cacheTTL
        self.staleTTL = staleTTL
        self.now = now
    }

    func projectPanelListResult(_ result: [String: JSONValue]) -> [String: JSONValue] {
        guard let workspaceID = result["workspace_id"]?.stringValue,
              let panels = result["panels"]?.arrayValue else {
            return result
        }

        var didProjectCarrier = false
        var nextPanels = [JSONValue]()
        var routes = [OrdinaryTmuxPanelRoute]()

        for panelValue in panels {
            guard let carrierPanel = panelValue.objectValue else {
                nextPanels.append(panelValue)
                continue
            }
            guard let ordinaryTmuxMetadata = carrierPanel["ordinary_tmux"]?.objectValue else {
                nextPanels.append(panelValue)
                continue
            }
            guard let carrierPanelID = carrierPanel["panel_id"]?.stringValue else {
                BridgeLogger.server.debug("ordinary tmux projection skipped workspace_id=\(workspaceID, privacy: .public) fallback_reason=missing_carrier_panel_id")
                nextPanels.append(panelValue)
                continue
            }
            guard let metadata = OrdinaryTmuxAttachMetadata(json: ordinaryTmuxMetadata) else {
                BridgeLogger.server.debug("ordinary tmux projection skipped workspace_id=\(workspaceID, privacy: .public) carrier_panel_id=\(carrierPanelID, privacy: .public) fallback_reason=invalid_metadata")
                nextPanels.append(panelValue)
                continue
            }

            BridgeLogger.server.debug("ordinary tmux projection metadata workspace_id=\(workspaceID, privacy: .public) carrier_panel_id=\(carrierPanelID, privacy: .public) tty=\(metadata.clientTTY, privacy: .public) target=\(metadata.targetSession ?? "<default>", privacy: .public)")

            let projectedLoad: ProjectedPanelsLoad
            do {
                projectedLoad = try cachedProjectedPanels(for: metadata,
                                                          workspaceID: workspaceID,
                                                          carrierPanelID: carrierPanelID)
            } catch {
                BridgeLogger.server.error("ordinary tmux projection failed workspace_id=\(workspaceID, privacy: .public) carrier_panel_id=\(carrierPanelID, privacy: .public) tty=\(metadata.clientTTY, privacy: .public) target=\(metadata.targetSession ?? "<default>", privacy: .public) fallback_reason=adapter_error error=\(String(describing: error), privacy: .public)")
                nextPanels.append(panelValue)
                continue
            }
            let projectedPanels = projectedLoad.panels

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
                        syncPaneIdentitiesIfNeeded(routes: [route])
                    } else {
                        BridgeLogger.server.info("ordinary tmux pane identity sync skipped workspace_id=\(workspaceID, privacy: .public) carrier_panel_id=\(carrierPanelID, privacy: .public) reason=stale_single_window_projection")
                    }
                    BridgeLogger.server.info("ordinary tmux single-window carrier enriched workspace_id=\(workspaceID, privacy: .public) carrier_panel_id=\(carrierPanelID, privacy: .public) pane_id=\(projectedPanel.activePaneID, privacy: .public) pane_pid=\(projectedPanel.activePanePID.map(String.init) ?? "-", privacy: .public) current_command=\(projectedPanel.currentCommand ?? "-", privacy: .public) socket_path=\(projectedPanel.socketPath ?? "-", privacy: .public)")
                    routes.append(route)
                    nextPanels.append(Self.carrierPanelValue(for: projectedPanel,
                                                             carrierPanel: carrierPanel,
                                                             workspaceID: workspaceID,
                                                             carrierPanelID: carrierPanelID))
                } else {
                    BridgeLogger.server.debug("ordinary tmux projection skipped workspace_id=\(workspaceID, privacy: .public) carrier_panel_id=\(carrierPanelID, privacy: .public) projected_count=0 fallback_reason=no_windows")
                    if projectedLoad.canReplaceRegistry {
                        registry?.replaceRoutes(workspaceID: workspaceID, routes: [], observedAt: now())
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
                syncPaneIdentitiesIfNeeded(routes: projectedRoutes)
            } else {
                BridgeLogger.server.info("ordinary tmux pane identity sync skipped workspace_id=\(workspaceID, privacy: .public) carrier_panel_id=\(carrierPanelID, privacy: .public) reason=stale_projection")
            }
            routes.append(contentsOf: projectedRoutes)
            nextPanels.append(contentsOf: projectedPanels.map {
                Self.panelValue(for: $0,
                                carrierPanel: carrierPanel,
                                workspaceID: workspaceID,
                                carrierPanelID: carrierPanelID)
            })
        }

        guard didProjectCarrier else {
            return result
        }

        if routes.isEmpty == false {
            registry?.replaceRoutes(workspaceID: workspaceID, routes: routes, observedAt: now())
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
                                       canReplaceRegistry: true)
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
                                       canReplaceRegistry: false)
        }

        let recoveredFromCooldown = consumeExpiredProjectionCooldown(for: key, at: currentDate)
        do {
            let panels = try adapter.projectedPanels(for: metadata)
            cacheQueue.sync {
                cache[key] = CacheEntry(panels: panels, loadedAt: currentDate)
            }
            if recoveredFromCooldown {
                BridgeLogger.server.info("ordinary tmux projection recovered from timeout cooldown workspace_id=\(workspaceID, privacy: .public) carrier_panel_id=\(carrierPanelID, privacy: .public) projected_count=\(panels.count, privacy: .public)")
            }
            return ProjectedPanelsLoad(panels: panels,
                                       canSetPaneIdentity: true,
                                       canReplaceRegistry: true)
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
                BridgeLogger.server.error("ordinary tmux projection timed out without cache workspace_id=\(workspaceID, privacy: .public) carrier_panel_id=\(carrierPanelID, privacy: .public) cooldown_seconds=10")
                return ProjectedPanelsLoad(panels: [],
                                           canSetPaneIdentity: false,
                                           canReplaceRegistry: false)
            }
            if let staleLoad = staleProjectedPanelsLoad(for: key,
                                                        currentDate: currentDate,
                                                        workspaceID: workspaceID,
                                                        carrierPanelID: carrierPanelID,
                                                        reason: "error") {
                return staleLoad
            }
            throw error
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
            projectionCooldownUntilByKey[key] = currentDate.addingTimeInterval(10)
        }
    }

    private func staleProjectedPanelsLoad(for key: String,
                                          currentDate: Date,
                                          workspaceID: String,
                                          carrierPanelID: String,
                                          reason: String) -> ProjectedPanelsLoad? {
        guard let entry = cacheQueue.sync(execute: { cache[key] }),
              currentDate.timeIntervalSince(entry.loadedAt) < staleTTL else {
            return nil
        }
        BridgeLogger.server.error("ordinary tmux projection using stale cache workspace_id=\(workspaceID, privacy: .public) carrier_panel_id=\(carrierPanelID, privacy: .public) reason=\(reason, privacy: .public)")
        return ProjectedPanelsLoad(panels: entry.panels,
                                   canSetPaneIdentity: false,
                                   canReplaceRegistry: false)
    }

    private func syncPaneIdentitiesIfNeeded(routes: [OrdinaryTmuxPanelRoute]) {
        for route in routes {
            let key = Self.identityCacheKey(route: route)
            let shouldSet = cacheQueue.sync { identityCache[key] != route.panelID }
            guard shouldSet else {
                BridgeLogger.server.info("ordinary tmux pane identity sync skipped workspace_id=\(route.workspaceID, privacy: .public) panel_id=\(route.panelID, privacy: .public) window_id=\(route.windowID, privacy: .public) pane_id=\(route.activePaneID, privacy: .public) reason=already_set")
                continue
            }

            do {
                try adapter.setPaneIdentity(route: route)
                cacheQueue.sync {
                    identityCache[key] = route.panelID
                }
                BridgeLogger.server.info("ordinary tmux pane identity sync set workspace_id=\(route.workspaceID, privacy: .public) panel_id=\(route.panelID, privacy: .public) window_id=\(route.windowID, privacy: .public) pane_id=\(route.activePaneID, privacy: .public)")
            } catch {
                BridgeLogger.server.error("ordinary tmux pane identity sync failed workspace_id=\(route.workspaceID, privacy: .public) panel_id=\(route.panelID, privacy: .public) window_id=\(route.windowID, privacy: .public) pane_id=\(route.activePaneID, privacy: .public) error=\(String(describing: error), privacy: .public)")
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
                                   carrierPanelID: String) -> JSONValue {
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
        return .object(panel)
    }

    private static func carrierPanelValue(for projectedPanel: OrdinaryTmuxProjectedPanel,
                                          carrierPanel: [String: JSONValue],
                                          workspaceID: String,
                                          carrierPanelID: String) -> JSONValue {
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
        return .object(panel)
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

    private static func isTmuxCommandTimeout(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == "OrdinaryTmuxCLIAdapter" && nsError.code == 124
    }
}
