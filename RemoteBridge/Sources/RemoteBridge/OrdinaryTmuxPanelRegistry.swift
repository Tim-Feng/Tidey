import Foundation

struct OrdinaryTmuxPanelRoute: Equatable, Sendable {
    let workspaceID: String
    let panelID: String
    let carrierPanelID: String
    let socket: OrdinaryTmuxSocketSelector
    let sessionID: String
    let sessionName: String
    let windowID: String
    let windowIndex: Int
    let activePaneID: String
}

final class OrdinaryTmuxPanelRegistry: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.tidey.remote-bridge.ordinary-tmux-panel-registry")
    private var routesByPanelID = [String: OrdinaryTmuxPanelRoute]()

    func replaceRoutes(workspaceID: String, routes: [OrdinaryTmuxPanelRoute]) {
        queue.sync {
            routesByPanelID = routesByPanelID.filter { $0.value.workspaceID != workspaceID }
            for route in routes {
                routesByPanelID[route.panelID] = route
            }
        }
    }

    func route(forPanelID panelID: String) -> OrdinaryTmuxPanelRoute? {
        queue.sync {
            routesByPanelID[panelID]
        }
    }
}

protocol OrdinaryTmuxInputRouting: Sendable {
    func sendInput(_ input: String, toPanelID panelID: String) throws -> Bool
}

final class OrdinaryTmuxInputRouter: OrdinaryTmuxInputRouting {
    private let registry: OrdinaryTmuxPanelRegistry
    private let adapter: OrdinaryTmuxCLIAdapter

    init(registry: OrdinaryTmuxPanelRegistry,
         adapter: OrdinaryTmuxCLIAdapter = OrdinaryTmuxCLIAdapter()) {
        self.registry = registry
        self.adapter = adapter
    }

    func sendInput(_ input: String, toPanelID panelID: String) throws -> Bool {
        guard let route = registry.route(forPanelID: panelID) else {
            return false
        }
        try adapter.sendInput(input, route: route)
        return true
    }
}
