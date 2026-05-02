import XCTest
@testable import RemoteBridge

final class OrdinaryTmuxRouteResolverTests: XCTestCase {
    private struct StubAdapter: OrdinaryTmuxRouteRefreshing {
        let rebuiltRoute: OrdinaryTmuxPanelRoute?

        func refreshedRoute(_ route: OrdinaryTmuxPanelRoute) throws -> OrdinaryTmuxPanelRoute {
            route
        }

        func route(for logicalID: OrdinaryTmuxLogicalPanelID,
                   authorizedTarget: OrdinaryTmuxAuthorizedTarget) throws -> OrdinaryTmuxPanelRoute {
            if let rebuiltRoute {
                return rebuiltRoute
            }
            throw BridgeInternalError.notFound("missing")
        }

        func captureOutput(route: OrdinaryTmuxPanelRoute, maxLines: Int) throws -> OrdinaryTmuxCapturedOutput {
            OrdinaryTmuxCapturedOutput(output: "", cursorRow: nil, cursorColumn: nil)
        }
    }

    func testRebuildsRouteFromAuthorizedLogicalPanelIDWhenRegistryRouteIsMissing() throws {
        let registry = OrdinaryTmuxPanelRegistry()
        let route = ordinaryRoute()
        registry.replaceRoutes(workspaceID: route.workspaceID, routes: [route], observedAt: Date(timeIntervalSince1970: 0))
        registry.replaceRoutes(workspaceID: route.workspaceID, routes: [], observedAt: Date(timeIntervalSince1970: 1))
        let resolver = OrdinaryTmuxRouteResolver(registry: registry,
                                                 adapter: StubAdapter(rebuiltRoute: route),
                                                 now: { Date(timeIntervalSince1970: 2) })

        let rebuilt = try resolver.route(forPanelID: route.panelID, workspaceID: route.workspaceID)

        XCTAssertEqual(rebuilt, route)
        XCTAssertEqual(registry.route(forPanelID: route.panelID), route)
    }

    func testRejectsLogicalPanelIDOutsideAuthorizedWorkspace() throws {
        let registry = OrdinaryTmuxPanelRegistry()
        let route = ordinaryRoute()
        registry.replaceRoutes(workspaceID: route.workspaceID, routes: [route], observedAt: Date(timeIntervalSince1970: 0))
        registry.replaceRoutes(workspaceID: route.workspaceID, routes: [], observedAt: Date(timeIntervalSince1970: 1))
        let resolver = OrdinaryTmuxRouteResolver(registry: registry,
                                                 adapter: StubAdapter(rebuiltRoute: route),
                                                 now: { Date(timeIntervalSince1970: 2) })

        let resolved = try resolver.route(forPanelID: route.panelID, workspaceID: "other-workspace")

        XCTAssertNil(resolved)
    }

    func testRejectsForgedSocketPathWithoutAuthorization() throws {
        let registry = OrdinaryTmuxPanelRegistry()
        let resolver = OrdinaryTmuxRouteResolver(registry: registry,
                                                 adapter: StubAdapter(rebuiltRoute: nil),
                                                 now: { Date(timeIntervalSince1970: 0) })

        let resolved = try resolver.route(forPanelID: "ordinary-tmux:/tmp/evil:$7:@16", workspaceID: nil)

        XCTAssertNil(resolved)
    }

    func testExpiredAuthorizationDoesNotRebuildRoute() throws {
        let registry = OrdinaryTmuxPanelRegistry(authorizationTTL: 10)
        let route = ordinaryRoute()
        registry.replaceRoutes(workspaceID: route.workspaceID, routes: [route], observedAt: Date(timeIntervalSince1970: 0))
        registry.replaceRoutes(workspaceID: route.workspaceID, routes: [], observedAt: Date(timeIntervalSince1970: 1))
        let resolver = OrdinaryTmuxRouteResolver(registry: registry,
                                                 adapter: StubAdapter(rebuiltRoute: route),
                                                 now: { Date(timeIntervalSince1970: 20) })

        let resolved = try resolver.route(forPanelID: route.panelID, workspaceID: route.workspaceID)

        XCTAssertNil(resolved)
    }

    private func ordinaryRoute() -> OrdinaryTmuxPanelRoute {
        let socketPath = "/tmp/tmux-\(getuid())/default"
        return OrdinaryTmuxPanelRoute(workspaceID: "workspace-1",
                                      panelID: "ordinary-tmux:\(socketPath):$7:@16",
                                      carrierPanelID: "carrier-panel",
                                      socket: .path(socketPath),
                                      sessionID: "$7",
                                      sessionName: "genesis-extraction",
                                      windowID: "@16",
                                      windowIndex: 1,
                                      activePaneID: "%16",
                                      cwd: "/Users/timfeng/GitHub/mother_nature",
                                      currentCommand: "codex")
    }
}
