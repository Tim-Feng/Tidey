import XCTest
@testable import RemoteBridge

final class BridgeAgentSubscriptionSlotsTests: XCTestCase {
    func testWorkspaceAndSessionSubscriptionsCanCoexist() {
        var slots = BridgeAgentSubscriptionSlots()
        let workspaceID = UUID()
        let sessionID = UUID()

        XCTAssertNil(slots.replace(workspaceID: "workspace-1", sessionID: nil, with: workspaceID))
        XCTAssertNil(slots.replace(workspaceID: "workspace-1", sessionID: "session-1", with: sessionID))

        XCTAssertTrue(slots.contains(workspaceID: "workspace-1", sessionID: nil))
        XCTAssertTrue(slots.contains(workspaceID: "workspace-1", sessionID: "session-1"))

        let removed = Set(slots.removeAll())
        XCTAssertEqual(removed, [workspaceID, sessionID])
    }

    func testReplacingSameSubscriptionKeyReturnsOnlyPreviousID() {
        var slots = BridgeAgentSubscriptionSlots()
        let monitorID = UUID()
        let oldChatID = UUID()
        let newChatID = UUID()

        XCTAssertNil(slots.replace(workspaceID: "workspace-1", sessionID: nil, with: monitorID))
        XCTAssertNil(slots.replace(workspaceID: "workspace-1", sessionID: "session-1", with: oldChatID))
        XCTAssertEqual(slots.replace(workspaceID: "workspace-1", sessionID: "session-1", with: newChatID), oldChatID)

        let removed = Set(slots.removeAll())
        XCTAssertEqual(removed, [monitorID, newChatID])
    }
}
