import Foundation

@objc(TideyRestorationSavedStateKind)
enum TideyRestorationSavedStateKind: Int {
    case absent
    case invalid
    case untagged
    case taggedSupported
    case taggedUnsupported
}

@objc(TideyRestorationPreviousExit)
enum TideyRestorationPreviousExit: Int {
    case cleanOrFirstLaunch
    case unclean
}

@objc(TideyRestorationLaunchDecision)
enum TideyRestorationLaunchDecision: Int {
    case restore
    case startBlank
    case promptAfterUncleanExit
}

@objc(TideyRestorationSaveDecision)
enum TideyRestorationSaveDecision: Int {
    case persistTaggedState
    case eraseState
}

@objc(TideyRestorationLaunchMarker)
@objcMembers
final class TideyRestorationLaunchMarker: NSObject {
    private static let cleanExitKey = "TideyRestorationLastExitWasClean"

    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults) {
        self.userDefaults = userDefaults
    }

    func beginLaunch() -> TideyRestorationPreviousExit {
        let previousValue = userDefaults.object(
            forKey: Self.cleanExitKey
        ) as? NSNumber
        userDefaults.set(false, forKey: Self.cleanExitKey)
        userDefaults.synchronize()
        guard let previousValue else {
            return .cleanOrFirstLaunch
        }
        return previousValue.boolValue ? .cleanOrFirstLaunch : .unclean
    }

    func markCleanExit() {
        userDefaults.set(true, forKey: Self.cleanExitKey)
        userDefaults.synchronize()
    }
}

@objc(TideyRestorationPolicyInput)
@objcMembers
final class TideyRestorationPolicyInput: NSObject {
    let savedStateKind: TideyRestorationSavedStateKind
    let hasRestorableWindows: Bool
    let tideyPreferenceEnabled: Bool
    let legacyRestoreRequested: Bool
    let previousExit: TideyRestorationPreviousExit

    init(
        savedStateKind: TideyRestorationSavedStateKind,
        hasRestorableWindows: Bool,
        tideyPreferenceEnabled: Bool,
        legacyRestoreRequested: Bool,
        previousExit: TideyRestorationPreviousExit
    ) {
        self.savedStateKind = savedStateKind
        self.hasRestorableWindows = hasRestorableWindows
        self.tideyPreferenceEnabled = tideyPreferenceEnabled
        self.legacyRestoreRequested = legacyRestoreRequested
        self.previousExit = previousExit
    }
}

@objc(TideyRestorationPolicyEvaluating)
protocol TideyRestorationPolicyEvaluating: NSObjectProtocol {
    @objc(launchDecisionForInput:)
    func launchDecision(
        for input: TideyRestorationPolicyInput
    ) -> TideyRestorationLaunchDecision

    @objc(saveDecisionWithTideyPreferenceEnabled:)
    func saveDecision(
        tideyPreferenceEnabled: Bool
    ) -> TideyRestorationSaveDecision
}

@objc(TideyRestorationPolicyEvaluator)
@objcMembers
final class TideyRestorationPolicyEvaluator:
    NSObject,
    TideyRestorationPolicyEvaluating {
    func launchDecision(
        for input: TideyRestorationPolicyInput
    ) -> TideyRestorationLaunchDecision {
        guard input.hasRestorableWindows else {
            return .startBlank
        }

        switch input.savedStateKind {
        case .absent, .invalid, .taggedUnsupported:
            return .startBlank
        case .untagged:
            return input.legacyRestoreRequested ? .restore : .startBlank
        case .taggedSupported:
            guard input.tideyPreferenceEnabled else {
                return .startBlank
            }
            switch input.previousExit {
            case .cleanOrFirstLaunch:
                return .restore
            case .unclean:
                return .promptAfterUncleanExit
            }
        }
    }

    func saveDecision(
        tideyPreferenceEnabled: Bool
    ) -> TideyRestorationSaveDecision {
        tideyPreferenceEnabled ? .persistTaggedState : .eraseState
    }
}
