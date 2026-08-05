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
    private var ownedByPanel = [String: OrdinaryTmuxTerminalStreamLease]()

    var count: Int {
        ownedByPanel.count
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

    mutating func releaseInstalledIdentifiedLease(id: String) -> ReleaseDecision {
        guard isRetired == false else {
            return .rejected
        }
        let matchingPanelID = ownedByPanel.first(where: { _, lease in
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
