struct TmuxInteractiveWindowSizePolicySnapshot: Equatable, Sendable {
    let windowID: String
    let currentPolicy: String?
    let tideyPreviousPolicyMarker: String?
    let hasLaterPolicyChangeEvidence: Bool
}

struct TmuxInteractiveWindowSizeMigration: Equatable, Sendable {
    let windowID: String
    let expectedCurrentPolicy: String
    let restoredPolicy: String
    let markerOption: String
    let expectedMarkerValue: String
}

enum TmuxInteractiveWindowSizeMigrationNoOpReason: Equatable, Sendable {
    case invalidWindowID(String)
    case laterPolicyChangeEvidence
    case currentPolicyNotOwned(String?)
    case markerNotOwned(String?)
}

enum TmuxInteractiveWindowSizeMigrationDecision: Equatable, Sendable {
    case migrate(TmuxInteractiveWindowSizeMigration)
    case noOp(TmuxInteractiveWindowSizeMigrationNoOpReason)
}

enum TmuxInteractiveWindowSizeMigrationClassifier {
    static let markerOption = "@tidey_window_size_before_multi_client"

    static func classify(
        _ snapshot: TmuxInteractiveWindowSizePolicySnapshot
    ) -> TmuxInteractiveWindowSizeMigrationDecision {
        guard isValidWindowID(snapshot.windowID) else {
            return .noOp(.invalidWindowID(snapshot.windowID))
        }
        guard snapshot.hasLaterPolicyChangeEvidence == false else {
            return .noOp(.laterPolicyChangeEvidence)
        }
        guard snapshot.currentPolicy == "largest" else {
            return .noOp(.currentPolicyNotOwned(snapshot.currentPolicy))
        }
        guard snapshot.tideyPreviousPolicyMarker == "latest" else {
            return .noOp(.markerNotOwned(snapshot.tideyPreviousPolicyMarker))
        }
        return .migrate(
            TmuxInteractiveWindowSizeMigration(
                windowID: snapshot.windowID,
                expectedCurrentPolicy: "largest",
                restoredPolicy: "latest",
                markerOption: markerOption,
                expectedMarkerValue: "latest"
            )
        )
    }

    private static func isValidWindowID(_ value: String) -> Bool {
        value.count > 1 && value.first == "@" && value.dropFirst().allSatisfy(\.isNumber)
    }
}
