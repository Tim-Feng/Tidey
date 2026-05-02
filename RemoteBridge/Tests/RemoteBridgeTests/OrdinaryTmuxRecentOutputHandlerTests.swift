import XCTest
@testable import RemoteBridge

final class OrdinaryTmuxRecentOutputHandlerTests: XCTestCase {
    private struct StubResolver: OrdinaryTmuxRouteResolving {
        let route: OrdinaryTmuxPanelRoute?

        func route(forPanelID panelID: String, workspaceID: String?) throws -> OrdinaryTmuxPanelRoute? {
            route
        }
    }

    private struct StubAdapter: OrdinaryTmuxRouteRefreshing {
        func refreshedRoute(_ route: OrdinaryTmuxPanelRoute) throws -> OrdinaryTmuxPanelRoute {
            route
        }

        func route(for logicalID: OrdinaryTmuxLogicalPanelID,
                   authorizedTarget: OrdinaryTmuxAuthorizedTarget) throws -> OrdinaryTmuxPanelRoute {
            throw BridgeInternalError.notFound("unused")
        }

        func captureOutput(route: OrdinaryTmuxPanelRoute, maxLines: Int) throws -> OrdinaryTmuxCapturedOutput {
            XCTAssertEqual(maxLines, 50)
            return OrdinaryTmuxCapturedOutput(output: "hello\nworld", cursorRow: nil, cursorColumn: nil)
        }
    }

    func testWrapsCapturedOutputInIOSRecentOutputShape() throws {
        let route = ordinaryRoute()
        let handler = OrdinaryTmuxRecentOutputHandler(routeResolver: StubResolver(route: route),
                                                      adapter: StubAdapter())

        let response = try XCTUnwrap(handler.handle(BridgeRequest(id: "request-1",
                                                                  action: "get_recent_output",
                                                                  params: [
                                                                    "panel_id": .string(route.panelID),
                                                                    "max_lines": .number(50),
                                                                  ])))

        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.result?["output"]?.stringValue, "hello\nworld")
        XCTAssertNil(response.result?["cursor_row"]?.intValue)
        XCTAssertNil(response.result?["cursor_col"]?.intValue)
        XCTAssertEqual(response.result?["panel_id"]?.stringValue, route.panelID)
        XCTAssertEqual(response.result?["workspace_id"]?.stringValue, route.workspaceID)
    }

    func testIgnoresNativePanelIDs() throws {
        let handler = OrdinaryTmuxRecentOutputHandler(routeResolver: StubResolver(route: nil),
                                                      adapter: StubAdapter())

        let response = try handler.handle(BridgeRequest(id: "request-1",
                                                        action: "get_recent_output",
                                                        params: ["panel_id": .string("native-panel")]))

        XCTAssertNil(response)
    }

    private func ordinaryRoute() -> OrdinaryTmuxPanelRoute {
        OrdinaryTmuxPanelRoute(workspaceID: "workspace-1",
                               panelID: "ordinary-tmux:/tmp/tmux-\(getuid())/default:$7:@16",
                               carrierPanelID: "carrier-panel",
                               socket: .path("/tmp/tmux-\(getuid())/default"),
                               sessionID: "$7",
                               sessionName: "genesis-extraction",
                               windowID: "@16",
                               windowIndex: 1,
                               activePaneID: "%16",
                               cwd: "/Users/timfeng/GitHub/mother_nature",
                               currentCommand: "codex")
    }
}
