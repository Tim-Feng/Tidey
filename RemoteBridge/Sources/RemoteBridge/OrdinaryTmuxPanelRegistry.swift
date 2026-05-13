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
    let cwd: String?
    let currentCommand: String?
}

struct OrdinaryTmuxLogicalPanelID: Equatable, Sendable {
    static let prefix = "ordinary-tmux"

    let rawValue: String
    let socketComponent: String
    let sessionID: String
    let windowID: String

    init?(rawValue: String) {
        let parts = rawValue.split(separator: ":", maxSplits: 3, omittingEmptySubsequences: false)
        guard parts.count == 4,
              parts[0] == Self.prefix else {
            return nil
        }
        let socketComponent = String(parts[1])
        let sessionID = String(parts[2])
        let windowID = String(parts[3])
        guard Self.isSafeSocketComponent(socketComponent),
              Self.isValidSessionID(sessionID),
              Self.isValidWindowID(windowID) else {
            return nil
        }
        self.rawValue = rawValue
        self.socketComponent = socketComponent
        self.sessionID = sessionID
        self.windowID = windowID
    }

    private static func isValidSessionID(_ value: String) -> Bool {
        value.first == "$" && value.dropFirst().allSatisfy(\.isNumber)
    }

    private static func isValidWindowID(_ value: String) -> Bool {
        value.first == "@" && value.dropFirst().allSatisfy(\.isNumber)
    }

    private static func isSafeSocketComponent(_ value: String) -> Bool {
        guard value.isEmpty == false,
              value.contains("..") == false else {
            return false
        }
        if value == "runtime-default" {
            return true
        }
        guard value.hasPrefix("/") else {
            return false
        }
        let uid = getuid()
        return value.hasPrefix("/tmp/tmux-\(uid)/") ||
            value.hasPrefix("/private/tmp/tmux-\(uid)/")
    }
}

struct OrdinaryTmuxAuthorizedTarget: Equatable, Sendable {
    let workspaceID: String
    let carrierPanelID: String
    let socket: OrdinaryTmuxSocketSelector
    let sessionID: String
    let sessionName: String
    let authorizedAt: Date

    var socketComponent: String {
        socket.stablePanelIDComponent
    }
}

final class OrdinaryTmuxPanelRegistry: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.tidey.remote-bridge.ordinary-tmux-panel-registry")
    private var routesByPanelID = [String: OrdinaryTmuxPanelRoute]()
    private var authorizedTargets = [String: OrdinaryTmuxAuthorizedTarget]()
    private let authorizationTTL: TimeInterval

    init(authorizationTTL: TimeInterval = 600) {
        self.authorizationTTL = authorizationTTL
    }

    func replaceRoutes(workspaceID: String, routes: [OrdinaryTmuxPanelRoute], observedAt: Date = Date()) {
        queue.sync {
            routesByPanelID = routesByPanelID.filter { $0.value.workspaceID != workspaceID }
            for route in routes {
                routesByPanelID[route.panelID] = route
                let target = OrdinaryTmuxAuthorizedTarget(workspaceID: route.workspaceID,
                                                          carrierPanelID: route.carrierPanelID,
                                                          socket: route.socket,
                                                          sessionID: route.sessionID,
                                                          sessionName: route.sessionName,
                                                          authorizedAt: observedAt)
                authorizedTargets[Self.authorizedTargetKey(workspaceID: route.workspaceID,
                                                           socketComponent: route.socket.stablePanelIDComponent,
                                                           sessionID: route.sessionID)] = target
            }
        }
    }

    func storeRoute(_ route: OrdinaryTmuxPanelRoute, observedAt: Date = Date()) {
        queue.sync {
            routesByPanelID[route.panelID] = route
            let target = OrdinaryTmuxAuthorizedTarget(workspaceID: route.workspaceID,
                                                      carrierPanelID: route.carrierPanelID,
                                                      socket: route.socket,
                                                      sessionID: route.sessionID,
                                                      sessionName: route.sessionName,
                                                      authorizedAt: observedAt)
            authorizedTargets[Self.authorizedTargetKey(workspaceID: route.workspaceID,
                                                       socketComponent: route.socket.stablePanelIDComponent,
                                                       sessionID: route.sessionID)] = target
        }
    }

    func route(forPanelID panelID: String) -> OrdinaryTmuxPanelRoute? {
        queue.sync {
            routesByPanelID[panelID]
        }
    }

    func authorizedTarget(for logicalID: OrdinaryTmuxLogicalPanelID,
                          workspaceID: String?,
                          now: Date = Date()) -> OrdinaryTmuxAuthorizedTarget? {
        queue.sync {
            let candidates = authorizedTargets.values.filter { target in
                guard target.socketComponent == logicalID.socketComponent,
                      target.sessionID == logicalID.sessionID,
                      now.timeIntervalSince(target.authorizedAt) <= authorizationTTL else {
                    return false
                }
                if let workspaceID {
                    return target.workspaceID == workspaceID
                }
                return true
            }
            return candidates.sorted { $0.authorizedAt > $1.authorizedAt }.first
        }
    }

    private static func authorizedTargetKey(workspaceID: String,
                                            socketComponent: String,
                                            sessionID: String) -> String {
        [workspaceID, socketComponent, sessionID].joined(separator: "|")
    }
}

protocol OrdinaryTmuxRouteRefreshing: Sendable {
    func refreshedRoute(_ route: OrdinaryTmuxPanelRoute) throws -> OrdinaryTmuxPanelRoute
    func route(for logicalID: OrdinaryTmuxLogicalPanelID,
               authorizedTarget: OrdinaryTmuxAuthorizedTarget) throws -> OrdinaryTmuxPanelRoute
    func captureOutput(route: OrdinaryTmuxPanelRoute, maxLines: Int) throws -> OrdinaryTmuxCapturedOutput
}

struct OrdinaryTmuxCapturedOutput: Equatable, Sendable {
    let output: String
    let cursorRow: Int?
    let cursorColumn: Int?
}

protocol OrdinaryTmuxRouteResolving: Sendable {
    func route(forPanelID panelID: String, workspaceID: String?) throws -> OrdinaryTmuxPanelRoute?
}

final class OrdinaryTmuxRouteResolver: OrdinaryTmuxRouteResolving, @unchecked Sendable {
    private let registry: OrdinaryTmuxPanelRegistry
    private let adapter: OrdinaryTmuxRouteRefreshing
    private let now: @Sendable () -> Date

    init(registry: OrdinaryTmuxPanelRegistry,
         adapter: OrdinaryTmuxRouteRefreshing = OrdinaryTmuxCLIAdapter(),
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.registry = registry
        self.adapter = adapter
        self.now = now
    }

    func route(forPanelID panelID: String, workspaceID: String? = nil) throws -> OrdinaryTmuxPanelRoute? {
        if let route = registry.route(forPanelID: panelID) {
            guard workspaceID == nil || workspaceID == route.workspaceID else {
                return nil
            }
            return route
        }

        guard let logicalID = OrdinaryTmuxLogicalPanelID(rawValue: panelID),
              let target = registry.authorizedTarget(for: logicalID, workspaceID: workspaceID, now: now()) else {
            return nil
        }

        let route = try adapter.route(for: logicalID, authorizedTarget: target)
        registry.storeRoute(route, observedAt: now())
        return route
    }
}

protocol OrdinaryTmuxInputRouting: Sendable {
    func sendInput(_ input: String, toPanelID panelID: String) throws -> Bool
}

final class OrdinaryTmuxInputRouter: OrdinaryTmuxInputRouting {
    private let routeResolver: OrdinaryTmuxRouteResolving
    private let adapter: OrdinaryTmuxCLIAdapter
    private let lastPastePaneStore = OrdinaryTmuxLastPastePaneStore()

    init(registry: OrdinaryTmuxPanelRegistry,
         adapter: OrdinaryTmuxCLIAdapter = OrdinaryTmuxCLIAdapter()) {
        self.routeResolver = OrdinaryTmuxRouteResolver(registry: registry, adapter: adapter)
        self.adapter = adapter
    }

    init(routeResolver: OrdinaryTmuxRouteResolving,
         adapter: OrdinaryTmuxCLIAdapter = OrdinaryTmuxCLIAdapter()) {
        self.routeResolver = routeResolver
        self.adapter = adapter
    }

    func sendInput(_ input: String, toPanelID panelID: String) throws -> Bool {
        guard let route = try routeResolver.route(forPanelID: panelID, workspaceID: nil) else {
            return false
        }
        let routeKey = Self.lastPastePaneKey(for: route)
        let fallbackEnterPaneID = lastPastePaneStore.paneID(for: routeKey)
        let delivery = try adapter.sendInput(input,
                                             route: route,
                                             fallbackEnterPaneID: fallbackEnterPaneID)
        lastPastePaneStore.record(delivery: delivery, routeKey: routeKey)
        return true
    }

    private static func lastPastePaneKey(for route: OrdinaryTmuxPanelRoute) -> String {
        [
            route.panelID,
            route.socket.cacheKey,
            route.sessionID,
            route.windowID,
        ].joined(separator: "|")
    }
}

private final class OrdinaryTmuxLastPastePaneStore: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.tidey.remote-bridge.ordinary-tmux-input-router.last-paste-pane")
    private var paneByRouteKey = [String: String]()

    func paneID(for routeKey: String) -> String? {
        queue.sync {
            paneByRouteKey[routeKey]
        }
    }

    func record(delivery: OrdinaryTmuxInputDelivery, routeKey: String) {
        queue.sync {
            if delivery.pastedText && !delivery.sentEnter {
                paneByRouteKey[routeKey] = delivery.paneID
            } else if delivery.sentEnter {
                paneByRouteKey.removeValue(forKey: routeKey)
            }
        }
    }
}

private extension OrdinaryTmuxSocketSelector {
    var stablePanelIDComponent: String {
        switch self {
        case .defaultSocket:
            return "runtime-default"
        case .path(let path):
            return path
        case .name(let name):
            return "name:\(name)"
        }
    }
}
