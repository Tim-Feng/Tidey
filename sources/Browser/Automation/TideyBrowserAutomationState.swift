import Foundation

enum TideyBrowserAutomationTabMark: String, Equatable {
    case none
    case deliverable
    case handoff
}

struct TideyBrowserAutomationPrivateTab: Equatable {
    let tabID: String
    let workspaceID: String
    var ownerSessionID: String?
    var mark: TideyBrowserAutomationTabMark
    var handoffExpiresAt: Date?
}

struct TideyBrowserAutomationUserClaim: Equatable {
    let tabID: String
    let workspaceID: String
    let ownerSessionID: String
}

struct TideyBrowserAutomationSessionCleanupPlan: Equatable {
    var privateTabIDsToClose: [String] = []
    var privateTabIDsToAdopt: [String] = []
    var privateTabIDsRetainedForHandoff: [String] = []
    var userTabIDsToRelease: [String] = []
}

enum TideyBrowserAutomationStateError: Error, Equatable {
    case tabLimitReached
    case targetGone
    case ownershipConflict
    case workspaceMismatch
    case invalidTransition
}

struct TideyBrowserAutomationState {
    let maxPrivateTabs: Int
    let handoffTTL: TimeInterval

    private(set) var privateTabsByID: [String: TideyBrowserAutomationPrivateTab] = [:]
    private(set) var userClaimsByTabID: [String: TideyBrowserAutomationUserClaim] = [:]

    init(maxPrivateTabs: Int = 8,
         handoffTTL: TimeInterval = 30 * 60) {
        self.maxPrivateTabs = maxPrivateTabs
        self.handoffTTL = handoffTTL
    }

    mutating func registerPrivateTab(tabID: String,
                                     workspaceID: String,
                                     ownerSessionID: String) throws {
        if let existing = privateTabsByID[tabID] {
            guard existing.workspaceID == workspaceID else {
                throw TideyBrowserAutomationStateError.workspaceMismatch
            }
            guard existing.ownerSessionID == ownerSessionID else {
                throw TideyBrowserAutomationStateError.ownershipConflict
            }
            throw TideyBrowserAutomationStateError.invalidTransition
        }
        guard privateTabsByID.count < maxPrivateTabs else {
            throw TideyBrowserAutomationStateError.tabLimitReached
        }
        privateTabsByID[tabID] = TideyBrowserAutomationPrivateTab(
            tabID: tabID,
            workspaceID: workspaceID,
            ownerSessionID: ownerSessionID,
            mark: .none,
            handoffExpiresAt: nil
        )
    }

    mutating func markPrivateTab(tabID: String,
                                 workspaceID: String,
                                 ownerSessionID: String,
                                 mark: TideyBrowserAutomationTabMark) throws {
        guard var tab = privateTabsByID[tabID] else {
            throw TideyBrowserAutomationStateError.targetGone
        }
        guard tab.workspaceID == workspaceID else {
            throw TideyBrowserAutomationStateError.workspaceMismatch
        }
        guard tab.ownerSessionID == ownerSessionID else {
            throw TideyBrowserAutomationStateError.ownershipConflict
        }
        tab.mark = mark
        tab.handoffExpiresAt = nil
        privateTabsByID[tabID] = tab
    }

    mutating func claimUserTab(tabID: String,
                               workspaceID: String,
                               ownerSessionID: String) throws {
        if let claim = userClaimsByTabID[tabID] {
            guard claim.workspaceID == workspaceID else {
                throw TideyBrowserAutomationStateError.workspaceMismatch
            }
            guard claim.ownerSessionID == ownerSessionID else {
                throw TideyBrowserAutomationStateError.ownershipConflict
            }
            return
        }
        userClaimsByTabID[tabID] = TideyBrowserAutomationUserClaim(
            tabID: tabID,
            workspaceID: workspaceID,
            ownerSessionID: ownerSessionID
        )
    }

    mutating func takePrivateTabForPresentation(tabID: String,
                                                workspaceID: String,
                                                ownerSessionID: String) throws -> TideyBrowserAutomationPrivateTab {
        let tab = try ownedPrivateTab(
            tabID: tabID,
            workspaceID: workspaceID,
            ownerSessionID: ownerSessionID
        )
        privateTabsByID.removeValue(forKey: tabID)
        return tab
    }

    func ownedPrivateTab(tabID: String,
                         workspaceID: String,
                         ownerSessionID: String) throws -> TideyBrowserAutomationPrivateTab {
        guard let tab = privateTabsByID[tabID] else {
            throw TideyBrowserAutomationStateError.targetGone
        }
        guard tab.workspaceID == workspaceID else {
            throw TideyBrowserAutomationStateError.workspaceMismatch
        }
        guard tab.ownerSessionID == ownerSessionID else {
            throw TideyBrowserAutomationStateError.ownershipConflict
        }
        return tab
    }

    mutating func reclaimHandoff(tabID: String,
                                 workspaceID: String,
                                 ownerSessionID: String,
                                 now: Date) throws {
        guard var tab = privateTabsByID[tabID] else {
            throw TideyBrowserAutomationStateError.targetGone
        }
        guard tab.workspaceID == workspaceID else {
            throw TideyBrowserAutomationStateError.workspaceMismatch
        }
        guard tab.mark == .handoff,
              tab.ownerSessionID == nil,
              let expiresAt = tab.handoffExpiresAt else {
            throw TideyBrowserAutomationStateError.invalidTransition
        }
        guard expiresAt > now else {
            privateTabsByID.removeValue(forKey: tabID)
            throw TideyBrowserAutomationStateError.targetGone
        }
        tab.ownerSessionID = ownerSessionID
        tab.handoffExpiresAt = nil
        privateTabsByID[tabID] = tab
    }

    mutating func expireHandoffs(now: Date) -> [String] {
        let expiredIDs = privateTabsByID.values
            .filter { tab in
                tab.mark == .handoff &&
                    tab.ownerSessionID == nil &&
                    (tab.handoffExpiresAt.map { $0 <= now } ?? false)
            }
            .map(\.tabID)
            .sorted()
        for tabID in expiredIDs {
            privateTabsByID.removeValue(forKey: tabID)
        }
        return expiredIDs
    }

    mutating func cleanupSession(ownerSessionID: String,
                                 now: Date) -> TideyBrowserAutomationSessionCleanupPlan {
        var plan = TideyBrowserAutomationSessionCleanupPlan()
        let ownedPrivateTabIDs = privateTabsByID.values
            .filter { $0.ownerSessionID == ownerSessionID }
            .map(\.tabID)
            .sorted()

        for tabID in ownedPrivateTabIDs {
            guard var tab = privateTabsByID[tabID] else {
                continue
            }
            switch tab.mark {
            case .none:
                privateTabsByID.removeValue(forKey: tabID)
                plan.privateTabIDsToClose.append(tabID)
            case .deliverable:
                privateTabsByID.removeValue(forKey: tabID)
                plan.privateTabIDsToAdopt.append(tabID)
            case .handoff:
                tab.ownerSessionID = nil
                tab.handoffExpiresAt = now.addingTimeInterval(handoffTTL)
                privateTabsByID[tabID] = tab
                plan.privateTabIDsRetainedForHandoff.append(tabID)
            }
        }

        let claimedUserTabIDs = userClaimsByTabID.values
            .filter { $0.ownerSessionID == ownerSessionID }
            .map(\.tabID)
            .sorted()
        for tabID in claimedUserTabIDs {
            userClaimsByTabID.removeValue(forKey: tabID)
            plan.userTabIDsToRelease.append(tabID)
        }
        return plan
    }
}
