import Foundation

struct BridgeAgentSubscriptionSlotKey: Hashable {
    let workspaceID: String?
    let sessionID: String?
}

struct BridgeAgentSubscriptionSlots {
    private var subscriptions = [BridgeAgentSubscriptionSlotKey: UUID]()

    mutating func replace(workspaceID: String?, sessionID: String?, with id: UUID) -> UUID? {
        let key = BridgeAgentSubscriptionSlotKey(workspaceID: workspaceID, sessionID: sessionID)
        return subscriptions.updateValue(id, forKey: key)
    }

    mutating func removeAll() -> [UUID] {
        let ids = Array(subscriptions.values)
        subscriptions.removeAll()
        return ids
    }

    func contains(workspaceID: String?, sessionID: String?) -> Bool {
        subscriptions[BridgeAgentSubscriptionSlotKey(workspaceID: workspaceID, sessionID: sessionID)] != nil
    }
}
