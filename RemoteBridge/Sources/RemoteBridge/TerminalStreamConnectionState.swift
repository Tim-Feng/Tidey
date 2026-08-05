import Foundation

struct TerminalStreamConnectionState {
    enum SubscribeDecision {
        case accepted(displacedLease: OrdinaryTmuxTerminalStreamLease?)
        case rejected
    }

    enum ReleaseDecision {
        case accepted([OrdinaryTmuxTerminalStreamLease])
        case rejected
    }

    struct Retirement {
        let preRetireCount: Int
        let leases: [OrdinaryTmuxTerminalStreamLease]
    }

    private(set) var isRetired = false
    private var unsubscribeAllHighWater: UInt64 = 0
    private var panelHighWater = [String: UInt64]()
    private var ownedByPanel = [String: OrdinaryTmuxTerminalStreamLease]()

    var count: Int {
        ownedByPanel.count
    }

    mutating func commitSubscribe(sequence: UInt64,
                                  panelID: String,
                                  lease: OrdinaryTmuxTerminalStreamLease,
                                  onInvalidated: @escaping @Sendable () -> Void) -> SubscribeDecision {
        guard isRetired == false,
              lease.route.panelID == panelID,
              sequence > max(unsubscribeAllHighWater, panelHighWater[panelID] ?? 0) else {
            return .rejected
        }
        panelHighWater[panelID] = sequence
        guard lease.deliveryGate.accept(onInvalidated: onInvalidated) else {
            return .rejected
        }
        let displacedLease = ownedByPanel.updateValue(lease, forKey: panelID)
        return .accepted(displacedLease: displacedLease)
    }

    mutating func commitUnsubscribe(sequence: UInt64,
                                    panelID: String) -> ReleaseDecision {
        guard isRetired == false,
              sequence > max(unsubscribeAllHighWater, panelHighWater[panelID] ?? 0) else {
            return .rejected
        }
        panelHighWater[panelID] = sequence
        let leases = ownedByPanel.removeValue(forKey: panelID).map { [$0] } ?? []
        return .accepted(leases)
    }

    mutating func commitUnsubscribeAll(sequence: UInt64) -> ReleaseDecision {
        guard isRetired == false,
              sequence > unsubscribeAllHighWater else {
            return .rejected
        }
        unsubscribeAllHighWater = sequence
        let panelIDsToRelease = ownedByPanel.keys.filter { panelID in
            sequence > (panelHighWater[panelID] ?? 0)
        }
        let leases = panelIDsToRelease.compactMap { panelID in
            ownedByPanel.removeValue(forKey: panelID)
        }
        return .accepted(leases)
    }

    @discardableResult
    mutating func removeIfOwned(panelID: String, token: UInt64) -> Bool {
        guard ownedByPanel[panelID]?.token == token else {
            return false
        }
        ownedByPanel.removeValue(forKey: panelID)
        return true
    }

    mutating func retire() -> Retirement {
        isRetired = true
        let retirement = Retirement(preRetireCount: ownedByPanel.count,
                                    leases: Array(ownedByPanel.values))
        ownedByPanel.removeAll()
        return retirement
    }
}
