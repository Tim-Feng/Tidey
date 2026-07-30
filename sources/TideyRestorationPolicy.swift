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
