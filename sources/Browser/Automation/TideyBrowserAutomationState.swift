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
}
