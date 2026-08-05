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
    private var latestSubscribeHighWater = [String: UInt64]()
    private var legacyOwnerHighWater = [String: UInt64]()
    private var consumedIdentifiedOwnerIDs = Set<String>()
    private var ownedByPanel = [String: OrdinaryTmuxTerminalStreamLease]()

    var count: Int {
        ownedByPanel.count
    }

    mutating func commitSubscribe(sequence: UInt64,
                                  panelID: String,
                                  owner: TerminalStreamSubscriptionOwner = .legacy,
                                  lease: OrdinaryTmuxTerminalStreamLease,
                                  onInvalidated: @escaping @Sendable () -> Void) -> SubscribeDecision {
        guard isRetired == false,
              lease.route.panelID == panelID,
              lease.owner == owner else {
            return .rejected
        }
        switch owner {
        case .identified(let id):
            guard consumedIdentifiedOwnerIDs.contains(id) == false else {
                return .rejected
            }
            consumedIdentifiedOwnerIDs.insert(id)
        case .legacy:
            guard sequence > (legacyOwnerHighWater[panelID] ?? 0) else {
                return .rejected
            }
        }
        guard sequence > max(unsubscribeAllHighWater,
                             latestSubscribeHighWater[panelID] ?? 0) else {
            return .rejected
        }
        latestSubscribeHighWater[panelID] = sequence
        if case .legacy = owner {
            legacyOwnerHighWater[panelID] = sequence
        }
        guard lease.deliveryGate.accept(onInvalidated: onInvalidated) else {
            return .rejected
        }
        let displacedLease = ownedByPanel.updateValue(lease, forKey: panelID)
        return .accepted(displacedLease: displacedLease)
    }

    mutating func commitUnsubscribe(sequence: UInt64,
                                    panelID: String) -> ReleaseDecision {
        guard isRetired == false,
              sequence > max(unsubscribeAllHighWater, latestSubscribeHighWater[panelID] ?? 0) else {
            return .rejected
        }
        latestSubscribeHighWater[panelID] = sequence
        let leases = ownedByPanel.removeValue(forKey: panelID).map { [$0] } ?? []
        return .accepted(leases)
    }

    mutating func commitLegacyUnsubscribe(sequence: UInt64,
                                          panelID: String) -> ReleaseDecision {
        guard isRetired == false,
              sequence > (legacyOwnerHighWater[panelID] ?? 0) else {
            return .rejected
        }
        legacyOwnerHighWater[panelID] = sequence
        guard let lease = ownedByPanel[panelID],
              lease.owner == .legacy else {
            return .accepted([])
        }
        ownedByPanel.removeValue(forKey: panelID)
        return .accepted([lease])
    }

    mutating func commitIdentifiedUnsubscribe(panelID: String,
                                              id: String) -> ReleaseDecision {
        guard isRetired == false else {
            return .rejected
        }
        consumedIdentifiedOwnerIDs.insert(id)
        guard let lease = ownedByPanel[panelID],
              lease.owner == .identified(id) else {
            return .accepted([])
        }
        ownedByPanel.removeValue(forKey: panelID)
        return .accepted([lease])
    }

    mutating func commitUnsubscribeAll(sequence: UInt64) -> ReleaseDecision {
        guard isRetired == false,
              sequence > unsubscribeAllHighWater else {
            return .rejected
        }
        unsubscribeAllHighWater = sequence
        let panelIDsToRelease = ownedByPanel.compactMap { panelID, lease in
            lease.token < sequence ? panelID : nil
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
