import XCTest
@testable import RemoteBridge

final class BridgeAgentSubscriptionSlotsTests: XCTestCase {
    func testSessionSubscriptionReplacesWorkspaceWideSubscriptionForSameWorkspace() {
        var slots = BridgeAgentSubscriptionSlots()
        let workspaceID = UUID()
        let sessionID = UUID()

        let workspaceResult = slots.install(workspaceID: "workspace-1", sessionID: nil, id: workspaceID)
        XCTAssertTrue(workspaceResult.accepted)
        XCTAssertEqual(workspaceResult.unsubscribeIDs, [])

        let sessionResult = slots.install(workspaceID: "workspace-1", sessionID: "session-1", id: sessionID)
        XCTAssertTrue(sessionResult.accepted)
        XCTAssertEqual(sessionResult.unsubscribeIDs, [workspaceID])

        XCTAssertFalse(slots.contains(workspaceID: "workspace-1", sessionID: nil))
        XCTAssertTrue(slots.contains(workspaceID: "workspace-1", sessionID: "session-1"))

        let removed = Set(slots.removeAll())
        XCTAssertEqual(removed, [sessionID])
    }

    func testWorkspaceWideSubscriptionIsRejectedWhenSessionSubscriptionExistsForWorkspace() {
        var slots = BridgeAgentSubscriptionSlots()
        let sessionID = UUID()
        let workspaceID = UUID()

        let sessionResult = slots.install(workspaceID: "workspace-1", sessionID: "session-1", id: sessionID)
        XCTAssertTrue(sessionResult.accepted)
        XCTAssertEqual(sessionResult.unsubscribeIDs, [])

        let workspaceResult = slots.install(workspaceID: "workspace-1", sessionID: nil, id: workspaceID)
        XCTAssertFalse(workspaceResult.accepted)
        XCTAssertEqual(workspaceResult.unsubscribeIDs, [workspaceID])

        XCTAssertFalse(slots.contains(workspaceID: "workspace-1", sessionID: nil))
        XCTAssertTrue(slots.contains(workspaceID: "workspace-1", sessionID: "session-1"))
    }

    func testReplacingSameSubscriptionKeyReturnsOnlyPreviousID() {
        var slots = BridgeAgentSubscriptionSlots()
        let monitorID = UUID()
        let oldChatID = UUID()
        let newChatID = UUID()

        let monitorResult = slots.install(workspaceID: "workspace-2", sessionID: nil, id: monitorID)
        XCTAssertTrue(monitorResult.accepted)
        XCTAssertEqual(monitorResult.unsubscribeIDs, [])

        let oldChatResult = slots.install(workspaceID: "workspace-1", sessionID: "session-1", id: oldChatID)
        XCTAssertTrue(oldChatResult.accepted)
        XCTAssertEqual(oldChatResult.unsubscribeIDs, [])

        let newChatResult = slots.install(workspaceID: "workspace-1", sessionID: "session-1", id: newChatID)
        XCTAssertTrue(newChatResult.accepted)
        XCTAssertEqual(newChatResult.unsubscribeIDs, [oldChatID])

        let removed = Set(slots.removeAll())
        XCTAssertEqual(removed, [monitorID, newChatID])
    }
}
