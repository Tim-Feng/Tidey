import Foundation

final class OrdinaryTmuxPanelProjector {
    private let adapter: OrdinaryTmuxWindowProjecting
    private let registry: OrdinaryTmuxPanelRegistry?

    init(adapter: OrdinaryTmuxWindowProjecting = OrdinaryTmuxCLIAdapter(),
         registry: OrdinaryTmuxPanelRegistry? = nil) {
        self.adapter = adapter
        self.registry = registry
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
            guard let carrierPanel = panelValue.objectValue,
                  let ordinaryTmuxMetadata = carrierPanel["ordinary_tmux"]?.objectValue,
                  let metadata = OrdinaryTmuxAttachMetadata(json: ordinaryTmuxMetadata),
                  let carrierPanelID = carrierPanel["panel_id"]?.stringValue else {
                nextPanels.append(panelValue)
                continue
            }

            let projectedPanels: [OrdinaryTmuxProjectedPanel]
            do {
                projectedPanels = try adapter.projectedPanels(for: metadata)
            } catch {
                BridgeLogger.server.error("ordinary tmux projection failed workspace_id=\(workspaceID, privacy: .public) carrier_panel_id=\(carrierPanelID, privacy: .public) error=\(String(describing: error), privacy: .public)")
                nextPanels.append(panelValue)
                continue
            }

            guard projectedPanels.count > 1 else {
                nextPanels.append(panelValue)
                continue
            }

            didProjectCarrier = true
            routes.append(contentsOf: projectedPanels.map {
                Self.route(for: $0,
                           workspaceID: workspaceID,
                           carrierPanelID: carrierPanelID,
                           metadata: metadata)
            })
            nextPanels.append(contentsOf: projectedPanels.map {
                Self.panelValue(for: $0,
                                carrierPanel: carrierPanel,
                                workspaceID: workspaceID,
                                carrierPanelID: carrierPanelID)
            })
        }

        guard didProjectCarrier else {
            registry?.replaceRoutes(workspaceID: workspaceID, routes: [])
            return result
        }

        registry?.replaceRoutes(workspaceID: workspaceID, routes: routes)

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

        if let windowGUID = carrierPanel["window_guid"] {
            panel["window_guid"] = windowGUID
        }
        if let cwd = projectedPanel.cwd {
            panel["cwd"] = .string(cwd)
        }
        if let currentCommand = projectedPanel.currentCommand {
            panel["current_command"] = .string(currentCommand)
        }
        return .object(panel)
    }

    private static func route(for projectedPanel: OrdinaryTmuxProjectedPanel,
                              workspaceID: String,
                              carrierPanelID: String,
                              metadata: OrdinaryTmuxAttachMetadata) -> OrdinaryTmuxPanelRoute {
        OrdinaryTmuxPanelRoute(
            workspaceID: workspaceID,
            panelID: projectedPanel.panelID,
            carrierPanelID: carrierPanelID,
            socket: projectedPanel.socketPath.map(OrdinaryTmuxSocketSelector.path) ?? metadata.preferredSocketSelector,
            sessionID: projectedPanel.sessionID,
            sessionName: projectedPanel.sessionName,
            windowID: projectedPanel.windowID,
            windowIndex: projectedPanel.windowIndex,
            activePaneID: projectedPanel.activePaneID
        )
    }
}
