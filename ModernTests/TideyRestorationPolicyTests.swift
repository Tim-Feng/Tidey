import XCTest
@testable import iTerm2SharedARC

final class TideyRestorationPolicyTests: XCTestCase {
    func testPolicyAndLaunchDecisionSeamsCompile() {
        let input = TideyRestorationPolicyInput(
            savedStateKind: .taggedSupported,
            hasRestorableWindows: true,
            tideyPreferenceEnabled: true,
            legacyRestoreRequested: false,
            previousExit: .cleanOrFirstLaunch
        )
        let evaluator: TideyRestorationPolicyEvaluating =
            TideyRestorationPolicyEvaluatorSpy(
                launchDecision: .restore,
                saveDecision: .persistTaggedState
            )

        XCTAssertEqual(evaluator.launchDecision(for: input), .restore)
        XCTAssertEqual(
            evaluator.saveDecision(tideyPreferenceEnabled: true),
            .persistTaggedState
        )
    }
}

private final class TideyRestorationPolicyEvaluatorSpy: NSObject,
                                                        TideyRestorationPolicyEvaluating {
    private let launchDecisionValue: TideyRestorationLaunchDecision
    private let saveDecisionValue: TideyRestorationSaveDecision

    init(
        launchDecision: TideyRestorationLaunchDecision,
        saveDecision: TideyRestorationSaveDecision
    ) {
        launchDecisionValue = launchDecision
        saveDecisionValue = saveDecision
    }

    func launchDecision(
        for input: TideyRestorationPolicyInput
    ) -> TideyRestorationLaunchDecision {
        launchDecisionValue
    }

    func saveDecision(
        tideyPreferenceEnabled: Bool
    ) -> TideyRestorationSaveDecision {
        saveDecisionValue
    }
}
