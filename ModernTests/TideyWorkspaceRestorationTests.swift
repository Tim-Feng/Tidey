import XCTest
@testable import iTerm2SharedARC

final class TideyWorkspaceRestorationTests: XCTestCase {
    func testModelSeamCompiles() {
        let workspace = TideyWorkspaceState(
            workspaceID: "workspace-1",
            title: "Build",
            pinned: true,
            panelIDs: ["panel-1", "panel-2"],
            selectedPanelID: "panel-2"
        )
        let state = TideyWorkspaceRestorationState(
            schemaVersion: TideyWorkspaceRestorationState.currentSchemaVersion,
            selectedWorkspaceID: workspace.workspaceID,
            workspaces: [workspace]
        )

        XCTAssertEqual(state.schemaVersion, 1)
        XCTAssertEqual(state.selectedWorkspaceID, "workspace-1")
        XCTAssertEqual(state.workspaces.first?.panelIDs, ["panel-1", "panel-2"])
    }

    func testPanelFlatteningAndHydrationSeamsCompile() {
        let panel = TideyWorkspaceRestorationPanelInput(
            panelID: "panel-1",
            hasSessions: true,
            isNativeTmux: false
        )
        let workspace = TideyWorkspaceRestorationWorkspaceInput(
            workspaceID: "workspace-1",
            title: "Build",
            pinned: true,
            panels: [panel],
            selectedPanelID: panel.panelID
        )
        let state = TideyWorkspaceRestorationState(
            schemaVersion: TideyWorkspaceRestorationState.currentSchemaVersion,
            selectedWorkspaceID: workspace.workspaceID,
            workspaces: []
        )
        let planner: TideyWorkspaceRestorationPlanning = WorkspaceRestorationPlanningSpy(state: state)

        let capturePlan = planner.capturePlan(
            workspaces: [workspace],
            visiblePanels: [panel],
            selectedWorkspaceID: workspace.workspaceID
        )
        let hydrationState = planner.hydrationState(
            savedState: state,
            availablePanelIDs: [panel.panelID],
            panelIDRemap: [:]
        )

        XCTAssertEqual(capturePlan.flattenedNativePanelIDs, [panel.panelID])
        XCTAssertTrue(hydrationState === state)
    }

    func testWorkspaceStateRoundTripsStableIdentitiesAndSelections() throws {
        let codec = TideyWorkspaceRestorationStateDictionaryCodec()
        let build = TideyWorkspaceState(
            workspaceID: "workspace-build",
            title: "Build",
            pinned: true,
            panelIDs: ["panel-editor", "panel-tests"],
            selectedPanelID: "panel-tests"
        )
        let review = TideyWorkspaceState(
            workspaceID: "workspace-review",
            title: nil,
            pinned: false,
            panelIDs: ["panel-review"],
            selectedPanelID: "panel-review"
        )
        let original = TideyWorkspaceRestorationState(
            schemaVersion: TideyWorkspaceRestorationState.currentSchemaVersion,
            selectedWorkspaceID: review.workspaceID,
            workspaces: [build, review]
        )

        var encoded = try codec.encode(original)
        encoded["future_root_field"] = ["ignored": true]
        var encodedWorkspaces = try XCTUnwrap(encoded["workspaces"] as? [[String: Any]])
        encodedWorkspaces[0]["future_workspace_field"] = 42
        encoded["workspaces"] = encodedWorkspaces

        let decoded = try codec.decode(encoded)

        XCTAssertEqual(decoded.schemaVersion, 1)
        XCTAssertEqual(decoded.selectedWorkspaceID, "workspace-review")
        XCTAssertEqual(decoded.workspaces.map(\.workspaceID), ["workspace-build", "workspace-review"])
        XCTAssertEqual(decoded.workspaces.map(\.title), ["Build", nil])
        XCTAssertEqual(decoded.workspaces.map(\.pinned), [true, false])
        XCTAssertEqual(decoded.workspaces.map(\.panelIDs), [
            ["panel-editor", "panel-tests"],
            ["panel-review"]
        ])
        XCTAssertEqual(decoded.workspaces.map(\.selectedPanelID), ["panel-tests", "panel-review"])
    }

    func testWorkspaceStateDecodeRejectsDuplicateWorkspaceIDs() {
        let dictionary: [String: Any] = [
            "schema_version": 1,
            "workspaces": [
                workspaceDictionary(id: "workspace-1", panelIDs: ["panel-1"]),
                workspaceDictionary(id: "workspace-1", panelIDs: ["panel-2"])
            ]
        ]

        XCTAssertThrowsError(try TideyWorkspaceRestorationStateDictionaryCodec().decode(dictionary)) { error in
            XCTAssertEqual(error as? TideyWorkspaceRestorationStateCodecError,
                           .duplicateWorkspaceID("workspace-1"))
        }
    }

    func testWorkspaceStateDecodeRejectsDuplicatePanelMembership() {
        let dictionary: [String: Any] = [
            "schema_version": 1,
            "workspaces": [
                workspaceDictionary(id: "workspace-1", panelIDs: ["panel-shared"]),
                workspaceDictionary(id: "workspace-2", panelIDs: ["panel-shared"])
            ]
        ]

        XCTAssertThrowsError(try TideyWorkspaceRestorationStateDictionaryCodec().decode(dictionary)) { error in
            XCTAssertEqual(error as? TideyWorkspaceRestorationStateCodecError,
                           .duplicatePanelID("panel-shared"))
        }
    }

    func testWorkspaceStateDecodeRejectsMalformedIdentitiesAndUnsupportedVersion() {
        let codec = TideyWorkspaceRestorationStateDictionaryCodec()
        let malformed: [String: Any] = [
            "schema_version": 1,
            "workspaces": [
                workspaceDictionary(id: "", panelIDs: ["panel-1"])
            ]
        ]
        let futureVersion: [String: Any] = [
            "schema_version": 2,
            "workspaces": []
        ]

        XCTAssertThrowsError(try codec.decode(malformed)) { error in
            XCTAssertEqual(error as? TideyWorkspaceRestorationStateCodecError,
                           .malformedField("workspace_id"))
        }
        XCTAssertThrowsError(try codec.decode(futureVersion)) { error in
            XCTAssertEqual(error as? TideyWorkspaceRestorationStateCodecError,
                           .unsupportedSchemaVersion(2))
        }
    }

    private func workspaceDictionary(id: String, panelIDs: [String]) -> [String: Any] {
        [
            "workspace_id": id,
            "pinned": false,
            "panel_ids": panelIDs
        ]
    }
}

private final class WorkspaceRestorationPlanningSpy: NSObject, TideyWorkspaceRestorationPlanning {
    private let state: TideyWorkspaceRestorationState

    init(state: TideyWorkspaceRestorationState) {
        self.state = state
    }

    func capturePlan(
        workspaces: [TideyWorkspaceRestorationWorkspaceInput],
        visiblePanels: [TideyWorkspaceRestorationPanelInput],
        selectedWorkspaceID: String?
    ) -> TideyWorkspaceRestorationCapturePlan {
        TideyWorkspaceRestorationCapturePlan(
            state: state,
            flattenedNativePanelIDs: visiblePanels.map(\.panelID)
        )
    }

    func hydrationState(
        savedState: TideyWorkspaceRestorationState,
        availablePanelIDs: [String],
        panelIDRemap: [String: String]
    ) -> TideyWorkspaceRestorationState {
        savedState
    }
}
