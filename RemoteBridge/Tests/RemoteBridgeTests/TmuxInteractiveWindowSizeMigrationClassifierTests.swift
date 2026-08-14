import XCTest

@testable import RemoteBridge

final class TmuxInteractiveWindowSizeMigrationClassifierTests: XCTestCase {
    func testOnlyExactOwnedLargestLatestStateIsEligible() {
        let eligible = TmuxInteractiveWindowSizeMigrationClassifier.classify(
            TmuxInteractiveWindowSizePolicySnapshot(
                windowID: "@15",
                currentPolicy: "largest",
                tideyPreviousPolicyMarker: "latest",
                hasLaterPolicyChangeEvidence: false
            )
        )
        XCTAssertEqual(
            eligible,
            .migrate(
                TmuxInteractiveWindowSizeMigration(
                    windowID: "@15",
                    expectedCurrentPolicy: "largest",
                    restoredPolicy: "latest",
                    markerOption: "@tidey_window_size_before_multi_client",
                    expectedMarkerValue: "latest"
                )
            )
        )

        for windowID in ["15", "@", "@abc"] {
            XCTAssertEqual(
                classify(windowID: windowID),
                .noOp(.invalidWindowID(windowID))
            )
        }
        for currentPolicy in [nil, "latest", "manual", " largest "] as [String?] {
            XCTAssertEqual(
                classify(currentPolicy: currentPolicy),
                .noOp(.currentPolicyNotOwned(currentPolicy))
            )
        }
        for marker in [nil, "", "manual", " latest ", "LATEST"] as [String?] {
            XCTAssertEqual(
                classify(marker: marker),
                .noOp(.markerNotOwned(marker))
            )
        }
        XCTAssertEqual(
            classify(hasLaterPolicyChangeEvidence: true),
            .noOp(.laterPolicyChangeEvidence)
        )
    }

    private func classify(
        windowID: String = "@15",
        currentPolicy: String? = "largest",
        marker: String? = "latest",
        hasLaterPolicyChangeEvidence: Bool = false
    ) -> TmuxInteractiveWindowSizeMigrationDecision {
        TmuxInteractiveWindowSizeMigrationClassifier.classify(
            TmuxInteractiveWindowSizePolicySnapshot(
                windowID: windowID,
                currentPolicy: currentPolicy,
                tideyPreviousPolicyMarker: marker,
                hasLaterPolicyChangeEvidence: hasLaterPolicyChangeEvidence
            )
        )
    }
}
