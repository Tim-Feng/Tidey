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

    func testTideyDefaultOnDoesNotForceRestoreUntaggedLegacyState() {
        let evaluator = TideyRestorationPolicyEvaluator()

        let defaultPreference = iTermPreferences.defaultObject(
            forKey: kPreferenceKeyTideyRestorePreviousWorkspaces
        ) as? NSNumber
        XCTAssertEqual(defaultPreference?.boolValue, true)

        XCTAssertEqual(
            evaluator.launchDecision(
                for: input(
                    savedStateKind: .untagged,
                    tideyPreferenceEnabled: true,
                    legacyRestoreRequested: false
                )
            ),
            .startBlank
        )
        XCTAssertEqual(
            evaluator.launchDecision(
                for: input(
                    savedStateKind: .untagged,
                    tideyPreferenceEnabled: true,
                    legacyRestoreRequested: true
                )
            ),
            .restore
        )
        XCTAssertEqual(
            evaluator.launchDecision(
                for: input(
                    savedStateKind: .taggedSupported,
                    tideyPreferenceEnabled: true,
                    legacyRestoreRequested: false
                )
            ),
            .restore
        )
        XCTAssertEqual(
            evaluator.launchDecision(
                for: input(
                    savedStateKind: .taggedSupported,
                    tideyPreferenceEnabled: false,
                    legacyRestoreRequested: true
                )
            ),
            .startBlank
        )
        XCTAssertEqual(
            evaluator.launchDecision(
                for: input(
                    savedStateKind: .taggedUnsupported,
                    tideyPreferenceEnabled: true,
                    legacyRestoreRequested: true
                )
            ),
            .startBlank
        )

        XCTAssertEqual(
            evaluator.saveDecision(tideyPreferenceEnabled: true),
            .persistTaggedState
        )
        XCTAssertEqual(
            evaluator.saveDecision(tideyPreferenceEnabled: false),
            .eraseState
        )
    }

    private func input(
        savedStateKind: TideyRestorationSavedStateKind,
        tideyPreferenceEnabled: Bool,
        legacyRestoreRequested: Bool
    ) -> TideyRestorationPolicyInput {
        TideyRestorationPolicyInput(
            savedStateKind: savedStateKind,
            hasRestorableWindows: true,
            tideyPreferenceEnabled: tideyPreferenceEnabled,
            legacyRestoreRequested: legacyRestoreRequested,
            previousExit: .cleanOrFirstLaunch
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
