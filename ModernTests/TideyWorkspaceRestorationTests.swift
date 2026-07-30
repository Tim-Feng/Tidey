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
}
