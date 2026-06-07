import Foundation

struct BridgeAgentSubscriptionSlotKey: Hashable {
    let workspaceID: String?
    let sessionID: String?
}

struct BridgeAgentSubscriptionSlots {
    struct InstallResult {
        let accepted: Bool
        let unsubscribeIDs: [UUID]
    }

    private var subscriptions = [BridgeAgentSubscriptionSlotKey: UUID]()

    mutating func install(workspaceID: String?, sessionID: String?, id: UUID) -> InstallResult {
        let key = BridgeAgentSubscriptionSlotKey(workspaceID: workspaceID, sessionID: sessionID)
        var unsubscribeIDs = [UUID]()

        if sessionID == nil,
           subscriptions.keys.contains(where: { $0.workspaceID == workspaceID && $0.sessionID != nil }) {
            return InstallResult(accepted: false, unsubscribeIDs: [id])
        }

        if let replacedID = subscriptions.updateValue(id, forKey: key) {
            unsubscribeIDs.append(replacedID)
        }

        if sessionID != nil {
            let workspaceKey = BridgeAgentSubscriptionSlotKey(workspaceID: workspaceID, sessionID: nil)
            if let workspaceSubscriptionID = subscriptions.removeValue(forKey: workspaceKey) {
                unsubscribeIDs.append(workspaceSubscriptionID)
            }
        }

        return InstallResult(accepted: true, unsubscribeIDs: unsubscribeIDs)
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
