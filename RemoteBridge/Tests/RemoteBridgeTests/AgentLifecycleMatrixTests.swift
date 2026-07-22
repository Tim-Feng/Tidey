import XCTest
@testable import RemoteBridge

final class AgentLifecycleMatrixTests: XCTestCase {
    private func identity(_ panel: String, session: String) -> AgentSessionLifecycleIdentity {
        AgentSessionLifecycleIdentity(workspaceID: "ws", panelID: panel, sessionID: session)
    }

    func testAugmenterEmitsSameAggregateStateAndRevisionAsStore() {
        let store = AgentSessionLifecycleStore()
        let id = identity("panel-1", session: "s1")
        store.beginTurn(id, vendor: "codex", generation: 1)
        store.openBlocker(id, vendor: "codex", generation: 1, blockerID: "b", kind: .permission)
        store.waitForDeliveriesForTesting()

        let panelAggregate = store.panelAggregate(workspaceID: "ws", panelID: "panel-1")
        let augmentedPanel = AgentLifecycleListAugmenter.augmentPanel([
            "panel_id": .string("panel-1"),
            "title": .string("build"),
            "state": .string("running"),
        ], workspaceID: "ws", panelID: "panel-1", hasAgentSession: true, store: store)
        XCTAssertEqual(augmentedPanel["state"]?.stringValue, panelAggregate?.state.rawValue)
        XCTAssertEqual(augmentedPanel["state_revision"]?.intValue, panelAggregate?.revision)
        XCTAssertEqual(augmentedPanel["title"]?.stringValue, "build", "augmentation must not drop fields")

        let workspaceAggregate = store.workspaceAggregate(workspaceID: "ws")
        let augmentedWorkspace = AgentLifecycleListAugmenter.augmentWorkspace([
            "workspace_id": .string("ws"),
            "state": .string("idle"),
        ], workspaceID: "ws", store: store)
        XCTAssertEqual(augmentedWorkspace["state"]?.stringValue, workspaceAggregate?.state.rawValue)
        XCTAssertEqual(augmentedWorkspace["state_revision"]?.intValue, workspaceAggregate?.revision)

        let unknownPanel = AgentLifecycleListAugmenter.augmentPanel([
            "panel_id": .string("panel-x"),
            "state": .string("running"),
        ], workspaceID: "ws", panelID: "panel-x", hasAgentSession: true, store: store)
        XCTAssertEqual(unknownPanel["state"]?.stringValue, "idle")
        XCTAssertEqual(unknownPanel["state_revision"]?.intValue, 0)

        let plainPanel = AgentLifecycleListAugmenter.augmentPanel([
            "panel_id": .string("panel-t"),
            "state": .string("running"),
        ], workspaceID: "ws", panelID: "panel-t", hasAgentSession: false, store: store)
        XCTAssertEqual(plainPanel["state"]?.stringValue, "running")
    }
}
