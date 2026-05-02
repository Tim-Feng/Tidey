import XCTest
@testable import RemoteBridge

final class OrdinaryTmuxPanelProjectorTests: XCTestCase {
    private struct StubAdapter: OrdinaryTmuxWindowProjecting {
        let panels: [OrdinaryTmuxProjectedPanel]

        func projectedPanels(for metadata: OrdinaryTmuxAttachMetadata) throws -> [OrdinaryTmuxProjectedPanel] {
            panels
        }
    }

    private struct ThrowingAdapter: OrdinaryTmuxWindowProjecting {
        func projectedPanels(for metadata: OrdinaryTmuxAttachMetadata) throws -> [OrdinaryTmuxProjectedPanel] {
            throw NSError(domain: "OrdinaryTmuxPanelProjectorTests", code: 1)
        }
    }

    func testProjectsMultiWindowCarrierIntoRemoteOnlyPanels() {
        let projector = OrdinaryTmuxPanelProjector(adapter: StubAdapter(panels: [
            projectedPanel(windowID: "@15", index: 0, name: "priest", paneID: "%15", current: true),
            projectedPanel(windowID: "@16", index: 1, name: "mother_nature", paneID: "%16", current: false),
            projectedPanel(windowID: "@17", index: 2, name: "peon_001", paneID: "%17", current: false),
        ]))

        let result = projector.projectPanelListResult(panelListResult())

        let panels = result["panels"]?.arrayValue?.compactMap(\.objectValue)
        XCTAssertEqual(panels?.map { $0["title"]?.stringValue }, ["priest", "mother_nature", "peon_001"])
        XCTAssertEqual(panels?.map { $0["panel_id"]?.stringValue }, [
            "ordinary-tmux:/tmp/tmux-501/default:$7:@15",
            "ordinary-tmux:/tmp/tmux-501/default:$7:@16",
            "ordinary-tmux:/tmp/tmux-501/default:$7:@17",
        ])
        XCTAssertEqual(result["selected_panel_id"]?.stringValue, "ordinary-tmux:/tmp/tmux-501/default:$7:@15")
        XCTAssertEqual(panels?.map { $0["panel_index"]?.intValue }, [0, 1, 2])
        XCTAssertEqual(panels?.first?["ordinary_tmux_logical"]?.objectValue?["carrier_panel_id"]?.stringValue, "carrier-panel")
        XCTAssertEqual(panels?.first?["ordinary_tmux_logical"]?.objectValue?["active_pane_id"]?.stringValue, "%15")
    }

    func testProjectionPreservesNonTmuxPanelsAndReindexes() {
        var result = panelListResult()
        result["panels"] = .array([
            result["panels"]!.arrayValue![0],
            .object([
                "panel_id": .string("native-panel"),
                "workspace_id": .string("workspace-1"),
                "title": .string("native shell"),
                "subtitle": .string("zsh"),
                "state": .string("idle"),
                "selected": .bool(false),
                "is_browser": .bool(false),
                "panel_index": .number(1),
                "workspace_index": .number(0),
            ]),
        ])
        let projector = OrdinaryTmuxPanelProjector(adapter: StubAdapter(panels: [
            projectedPanel(windowID: "@15", index: 0, name: "priest", paneID: "%15", current: false),
            projectedPanel(windowID: "@16", index: 1, name: "mother_nature", paneID: "%16", current: true),
        ]))

        let projected = projector.projectPanelListResult(result)

        let panels = projected["panels"]?.arrayValue?.compactMap(\.objectValue)
        XCTAssertEqual(panels?.map { $0["title"]?.stringValue }, ["priest", "mother_nature", "native shell"])
        XCTAssertEqual(panels?.map { $0["panel_index"]?.intValue }, [0, 1, 2])
        XCTAssertEqual(projected["selected_panel_id"]?.stringValue, "ordinary-tmux:/tmp/tmux-501/default:$7:@16")
    }

    func testSingleWindowCarrierFallsBackToOriginalPanel() {
        let projector = OrdinaryTmuxPanelProjector(adapter: StubAdapter(panels: [
            projectedPanel(windowID: "@15", index: 0, name: "priest", paneID: "%15", current: true),
        ]))

        let result = projector.projectPanelListResult(panelListResult())

        let panels = result["panels"]?.arrayValue?.compactMap(\.objectValue)
        XCTAssertEqual(panels?.count, 1)
        XCTAssertEqual(panels?.first?["panel_id"]?.stringValue, "carrier-panel")
        XCTAssertEqual(result["selected_panel_id"]?.stringValue, "carrier-panel")
    }

    func testProjectionFailureFallsBackToOriginalPanel() {
        let projector = OrdinaryTmuxPanelProjector(adapter: ThrowingAdapter())

        let result = projector.projectPanelListResult(panelListResult())

        let panels = result["panels"]?.arrayValue?.compactMap(\.objectValue)
        XCTAssertEqual(panels?.count, 1)
        XCTAssertEqual(panels?.first?["panel_id"]?.stringValue, "carrier-panel")
    }

    private func panelListResult() -> [String: JSONValue] {
        [
            "workspace_id": .string("workspace-1"),
            "selected_panel_id": .string("carrier-panel"),
            "panels": .array([
                .object([
                    "panel_id": .string("carrier-panel"),
                    "workspace_id": .string("workspace-1"),
                    "window_guid": .string("window-guid"),
                    "title": .string("tmux"),
                    "subtitle": .string("genesis-extraction"),
                    "state": .string("idle"),
                    "selected": .bool(true),
                    "is_browser": .bool(false),
                    "panel_index": .number(0),
                    "workspace_index": .number(0),
                    "ordinary_tmux": .object([
                        "client_tty": .string("/dev/ttys010"),
                        "target_session": .string("genesis-extraction"),
                    ]),
                ]),
            ]),
        ]
    }

    private func projectedPanel(windowID: String,
                                index: Int,
                                name: String,
                                paneID: String,
                                current: Bool) -> OrdinaryTmuxProjectedPanel {
        OrdinaryTmuxProjectedPanel(
            panelID: OrdinaryTmuxCLIAdapter.stablePanelID(socketComponent: "/tmp/tmux-501/default",
                                                          sessionID: "$7",
                                                          windowID: windowID),
            socketPath: "/tmp/tmux-501/default",
            sessionID: "$7",
            sessionName: "genesis-extraction",
            windowID: windowID,
            windowIndex: index,
            windowName: name,
            isCurrentWindow: current,
            activePaneID: paneID,
            cwd: "/Users/timfeng/GitHub/\(name)",
            currentCommand: "zsh",
            title: name,
            subtitle: "/Users/timfeng/GitHub/\(name)"
        )
    }
}
