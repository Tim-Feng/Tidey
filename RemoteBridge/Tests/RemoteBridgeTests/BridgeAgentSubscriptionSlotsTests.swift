import XCTest
@testable import RemoteBridge

final class BridgeAgentSubscriptionSlotsTests: XCTestCase {
    func testSessionSubscriptionReplacesWorkspaceWideSubscriptionForSameWorkspace() {
        let slots = BridgeAgentSubscriptionSlots()
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
        let slots = BridgeAgentSubscriptionSlots()
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
        let slots = BridgeAgentSubscriptionSlots()
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

    func testConcurrentInstallAndRemoveAllDoesNotCorruptSlots() {
        let slots = BridgeAgentSubscriptionSlots()
        let iterations = 100
        let group = DispatchGroup()

        for index in 0..<iterations {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                _ = slots.install(workspaceID: "workspace-\(index % 5)",
                                  sessionID: index.isMultiple(of: 2) ? "session-\(index)" : nil,
                                  id: UUID())
                if index.isMultiple(of: 7) {
                    _ = slots.removeAll()
                }
                group.leave()
            }
        }

        XCTAssertEqual(group.wait(timeout: .now() + 2.0), .success)
        _ = slots.removeAll()
        XCTAssertFalse(slots.contains(workspaceID: "workspace-1", sessionID: "session-1"))
    }
}
