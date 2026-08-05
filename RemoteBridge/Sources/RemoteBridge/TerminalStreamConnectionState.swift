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
        return installSubscribe(panelID: panelID,
                                owner: owner,
                                lease: lease,
                                onInvalidated: onInvalidated)
    }

    mutating func commitUnsubscribe(sequence: UInt64,
                                    panelID: String) -> ReleaseDecision {
        guard isRetired == false,
              sequence > max(unsubscribeAllHighWater, latestSubscribeHighWater[panelID] ?? 0) else {
            return .rejected
        }
        latestSubscribeHighWater[panelID] = sequence
        return releaseInstalledLease(panelID: panelID)
    }

    mutating func commitLegacyUnsubscribe(sequence: UInt64,
                                          panelID: String) -> ReleaseDecision {
        guard isRetired == false,
              sequence > (legacyOwnerHighWater[panelID] ?? 0) else {
            return .rejected
        }
        legacyOwnerHighWater[panelID] = sequence
        return releaseInstalledLegacyLease(panelID: panelID)
    }

    mutating func commitIdentifiedUnsubscribe(panelID: String,
                                              id: String) -> ReleaseDecision {
        guard isRetired == false else {
            return .rejected
        }
        consumedIdentifiedOwnerIDs.insert(id)
        return releaseInstalledIdentifiedLease(panelID: panelID, id: id)
    }

    mutating func commitUnsubscribeAll(sequence: UInt64) -> ReleaseDecision {
        guard isRetired == false,
              sequence > unsubscribeAllHighWater else {
            return .rejected
        }
        unsubscribeAllHighWater = sequence
        return releaseInstalledLeases(olderThan: sequence)
    }

    mutating func installSubscribe(panelID: String,
                                   owner: TerminalStreamSubscriptionOwner,
                                   lease: OrdinaryTmuxTerminalStreamLease,
                                   onInvalidated: @escaping @Sendable () -> Void) -> SubscribeDecision {
        guard isRetired == false,
              lease.route.panelID == panelID,
              lease.owner == owner,
              lease.deliveryGate.accept(onInvalidated: onInvalidated) else {
            return .rejected
        }
        let displacedLease = ownedByPanel.updateValue(lease, forKey: panelID)
        return .accepted(displacedLease: displacedLease)
    }

    mutating func releaseInstalledIdentifiedLease(panelID: String?,
                                                  id: String) -> ReleaseDecision {
        guard isRetired == false else {
            return .rejected
        }
        let matchingPanelID = panelID ?? ownedByPanel.first(where: { _, lease in
            lease.owner == .identified(id)
        })?.key
        guard let matchingPanelID,
              let lease = ownedByPanel[matchingPanelID],
              lease.owner == .identified(id) else {
            return .accepted([])
        }
        ownedByPanel.removeValue(forKey: matchingPanelID)
        return .accepted([lease])
    }

    mutating func releaseInstalledLegacyLease(panelID: String) -> ReleaseDecision {
        guard isRetired == false else {
            return .rejected
        }
        guard let lease = ownedByPanel[panelID],
              lease.owner == .legacy else {
            return .accepted([])
        }
        ownedByPanel.removeValue(forKey: panelID)
        return .accepted([lease])
    }

    mutating func releaseInstalledLeases(olderThan sequence: UInt64) -> ReleaseDecision {
        guard isRetired == false else {
            return .rejected
        }
        let panelIDsToRelease = ownedByPanel.compactMap { panelID, lease in
            lease.token < sequence ? panelID : nil
        }
        let leases = panelIDsToRelease.compactMap { panelID in
            ownedByPanel.removeValue(forKey: panelID)
        }
        return .accepted(leases)
    }

    private mutating func releaseInstalledLease(panelID: String) -> ReleaseDecision {
        let leases = ownedByPanel.removeValue(forKey: panelID).map { [$0] } ?? []
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
