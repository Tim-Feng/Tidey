import XCTest
@testable import RemoteBridge

final class TerminalHistoryPagingTests: XCTestCase {
    private struct StubResolver: OrdinaryTmuxRouteResolving {
        let route: OrdinaryTmuxPanelRoute?

        func route(forPanelID panelID: String, workspaceID: String?) throws -> OrdinaryTmuxPanelRoute? {
            guard route?.panelID == panelID,
                  workspaceID == nil || route?.workspaceID == workspaceID else {
                return nil
            }
            return route
        }
    }

    private struct StubPageServer: OrdinaryTmuxHistoryPageServing {
        let expectedRoute: OrdinaryTmuxPanelRoute

        func page(
            route: OrdinaryTmuxPanelRoute,
            offset: Int,
            pageLines: Int,
            anchor: TerminalHistoryAnchorV1?
        ) throws -> OrdinaryTmuxHistoryPage {
            XCTAssertEqual(route, expectedRoute)
            XCTAssertEqual(offset, 0)
            XCTAssertEqual(pageLines, 2)
            XCTAssertNil(anchor)
            let rows = [Data("OLDER".utf8), Data("OLD".utf8)]
            return OrdinaryTmuxHistoryPage(
                route: route,
                evaluation: OrdinaryTmuxHistoryPageEvaluation(
                    rows: rows,
                    nextOffset: 2,
                    anchor: TerminalHistoryAnchorV1(
                        offset: 2,
                        sha16: OrdinaryTmuxHistoryPagePolicy.sha16(rows[0])
                    ),
                    invalidated: false,
                    oldestReached: false
                )
            )
        }
    }

    func testTmuxCapturePlanUsesFixedBoundsAndInvalidatesMismatchedOverlap() throws {
        let firstPlan = try OrdinaryTmuxHistoryPagePolicy.capturePlan(
            offset: 0,
            pageLines: 2,
            anchor: nil,
            paneID: "%7"
        )
        XCTAssertEqual(
            firstPlan.arguments,
            ["capture-pane", "-e", "-p", "-S", "-2", "-E", "-1", "-t", "%7"]
        )

        let first = OrdinaryTmuxHistoryPagePolicy.evaluate(
            rows: [Data("OLDER".utf8), Data("OLD".utf8)],
            plan: firstPlan
        )
        XCTAssertFalse(first.invalidated)
        XCTAssertEqual(first.rows.map { String(decoding: $0, as: UTF8.self) }, ["OLDER", "OLD"])
        XCTAssertEqual(first.nextOffset, 2)
        XCTAssertEqual(first.anchor?.offset, 2)
        XCTAssertEqual(first.anchor?.sha16.count, 16)
        XCTAssertFalse(first.oldestReached)

        let anchor = try XCTUnwrap(first.anchor)
        let olderPlan = try OrdinaryTmuxHistoryPagePolicy.capturePlan(
            offset: first.nextOffset,
            pageLines: 2,
            anchor: anchor,
            paneID: "%7"
        )
        XCTAssertEqual(
            olderPlan.arguments,
            ["capture-pane", "-e", "-p", "-S", "-4", "-E", "-2", "-t", "%7"]
        )

        let valid = OrdinaryTmuxHistoryPagePolicy.evaluate(
            rows: [Data("EARLIEST".utf8), Data("EARLIER".utf8), Data("OLDER".utf8)],
            plan: olderPlan
        )
        XCTAssertFalse(valid.invalidated)
        XCTAssertEqual(valid.rows.map { String(decoding: $0, as: UTF8.self) }, ["EARLIEST", "EARLIER"])
        XCTAssertEqual(valid.nextOffset, 4)

        let invalidated = OrdinaryTmuxHistoryPagePolicy.evaluate(
            rows: [Data("EARLIEST".utf8), Data("EARLIER".utf8), Data("SHIFTED".utf8)],
            plan: olderPlan
        )
        XCTAssertTrue(invalidated.invalidated)
        XCTAssertTrue(invalidated.rows.isEmpty)
        XCTAssertEqual(invalidated.nextOffset, 2)
        XCTAssertNil(invalidated.anchor)
    }

    func testBridgeHistoryPageActionPagesValidatedTmuxAndForwardsNativeRoutes() throws {
        let route = ordinaryRoute()
        let handler = TerminalHistoryPageActionHandler(
            routeResolver: StubResolver(route: route),
            tmuxPageServer: StubPageServer(expectedRoute: route)
        )
        let response = try XCTUnwrap(handler.handle(BridgeRequest(
            id: "history-1",
            action: "get_terminal_history_page",
            params: [
                "source": .string("tmux"),
                "workspace_id": .string(route.workspaceID),
                "panel_id": .string(route.panelID),
                "route_generation": .number(9),
                "page_lines": .number(2),
                "cursor": .object(["offset": .number(0)]),
            ]
        )))

        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.result?["source"]?.stringValue, "tmux")
        XCTAssertEqual(response.result?["workspace_id"]?.stringValue, route.workspaceID)
        XCTAssertEqual(response.result?["panel_id"]?.stringValue, route.panelID)
        XCTAssertEqual(response.result?["route_generation"]?.intValue, 9)
        XCTAssertEqual(
            response.result?["rows"]?.arrayValue?.compactMap(\.stringValue),
            [Data("OLDER".utf8).base64EncodedString(), Data("OLD".utf8).base64EncodedString()]
        )
        let cursor = try XCTUnwrap(response.result?["cursor"]?.objectValue)
        XCTAssertEqual(cursor["offset"]?.intValue, 2)
        XCTAssertEqual(cursor["anchor"]?.objectValue?["offset"]?.intValue, 2)
        XCTAssertEqual(cursor["anchor"]?.objectValue?["sha16"]?.stringValue?.count, 16)
        XCTAssertEqual(response.result?["invalidated"]?.boolValue, false)
        XCTAssertEqual(response.result?["oldest_reached"]?.boolValue, false)

        let native = try handler.handle(BridgeRequest(
            id: "history-native",
            action: "get_terminal_history_page",
            params: [
                "source": .string("native"),
                "workspace_id": .string("workspace-native"),
                "panel_id": .string("panel-native"),
                "route_generation": .number(4),
                "page_lines": .number(200),
            ]
        ))
        XCTAssertNil(native, "native history requests must continue to the Tidey socket")
    }

    private func ordinaryRoute() -> OrdinaryTmuxPanelRoute {
        OrdinaryTmuxPanelRoute(
            workspaceID: "workspace-1",
            panelID: "ordinary-tmux:/tmp/tmux-\(getuid())/default:$7:@16",
            carrierPanelID: "carrier-panel",
            socket: .path("/tmp/tmux-\(getuid())/default"),
            sessionID: "$7",
            sessionName: "genesis-extraction",
            windowID: "@16",
            windowIndex: 1,
            activePaneID: "%16",
            cwd: "/Users/timfeng/GitHub/mother_nature",
            currentCommand: "codex"
        )
    }
}
