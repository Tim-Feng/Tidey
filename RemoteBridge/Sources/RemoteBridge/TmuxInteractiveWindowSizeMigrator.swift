import Foundation

enum TmuxInteractiveWindowSizeMigrationOutcome: Equatable, Sendable {
    case migrated(TmuxInteractiveWindowSizeMigration)
    case notEligible(TmuxInteractiveWindowSizeMigrationNoOpReason)
}

enum TmuxInteractiveWindowSizeMigratorError: Error, Equatable {
    case malformedSnapshot
    case verificationFailed(
        expectedPolicy: String,
        expectedMarker: String?,
        actualPolicy: String?,
        actualMarker: String?
    )
}

struct TmuxInteractiveWindowSizeMigrator: Sendable {
    typealias CommandRunner = OrdinaryTmuxCLIAdapter.CommandRunner

    private static let snapshotFormat =
        "TIDEYv1|#{window-size}|#{@tidey_window_size_before_multi_client}|END"

    private let commandRunner: CommandRunner

    init(
        tmuxExecutablePath: String? = TmuxStateResolver.discoverTmuxBinaryPath()
    ) {
        commandRunner = OrdinaryTmuxCLIAdapter.processCommandRunner(
            executablePath: tmuxExecutablePath,
            timeoutSeconds: 3
        )
    }

    init(commandRunner: @escaping CommandRunner) {
        self.commandRunner = commandRunner
    }

    func migrateIfEligible(
        socket: OrdinaryTmuxSocketSelector,
        windowID: String,
        hasLaterPolicyChangeEvidence: Bool
    ) throws -> TmuxInteractiveWindowSizeMigrationOutcome {
        let preflight = TmuxInteractiveWindowSizeMigrationClassifier.classify(
            TmuxInteractiveWindowSizePolicySnapshot(
                windowID: windowID,
                currentPolicy: nil,
                tideyPreviousPolicyMarker: nil,
                hasLaterPolicyChangeEvidence: hasLaterPolicyChangeEvidence
            )
        )
        switch preflight {
        case .noOp(.invalidWindowID(let invalidWindowID)):
            return .notEligible(.invalidWindowID(invalidWindowID))
        case .noOp(.laterPolicyChangeEvidence):
            return .notEligible(.laterPolicyChangeEvidence)
        case .migrate,
             .noOp(.currentPolicyNotOwned),
             .noOp(.markerNotOwned):
            break
        }

        let initialSnapshot = try readSnapshot(socket: socket, windowID: windowID)
        let decision = TmuxInteractiveWindowSizeMigrationClassifier.classify(
            TmuxInteractiveWindowSizePolicySnapshot(
                windowID: windowID,
                currentPolicy: initialSnapshot.policy,
                tideyPreviousPolicyMarker: initialSnapshot.marker,
                hasLaterPolicyChangeEvidence: false
            )
        )
        let migration: TmuxInteractiveWindowSizeMigration
        switch decision {
        case .migrate(let approvedMigration):
            migration = approvedMigration
        case .noOp(let reason):
            return .notEligible(reason)
        }

        _ = try commandRunner(
            socket,
            [
                "set-option", "-w", "-t", migration.windowID,
                "window-size", migration.restoredPolicy,
            ],
            nil
        )
        let restoredSnapshot = try readSnapshot(socket: socket, windowID: windowID)
        try verify(
            restoredSnapshot,
            expectedPolicy: migration.restoredPolicy,
            expectedMarker: migration.expectedMarkerValue
        )

        _ = try commandRunner(
            socket,
            [
                "set-option", "-u", "-w", "-t", migration.windowID,
                migration.markerOption,
            ],
            nil
        )
        let clearedSnapshot = try readSnapshot(socket: socket, windowID: windowID)
        try verify(
            clearedSnapshot,
            expectedPolicy: migration.restoredPolicy,
            expectedMarker: nil
        )
        return .migrated(migration)
    }

    private func readSnapshot(
        socket: OrdinaryTmuxSocketSelector,
        windowID: String
    ) throws -> (policy: String?, marker: String?) {
        let output = try commandRunner(
            socket,
            ["display-message", "-p", "-t", windowID, Self.snapshotFormat],
            nil
        )
        let prefix = "TIDEYv1|"
        let suffix = "|END"
        guard output.hasPrefix(prefix),
              output.hasSuffix(suffix) else {
            throw TmuxInteractiveWindowSizeMigratorError.malformedSnapshot
        }
        let start = output.index(output.startIndex, offsetBy: prefix.count)
        let end = output.index(output.endIndex, offsetBy: -suffix.count)
        let fields = output[start..<end].split(
            separator: "|",
            omittingEmptySubsequences: false
        )
        guard fields.count == 2 else {
            throw TmuxInteractiveWindowSizeMigratorError.malformedSnapshot
        }
        let policy = fields[0].isEmpty ? nil : String(fields[0])
        let marker = fields[1].isEmpty ? nil : String(fields[1])
        return (policy, marker)
    }

    private func verify(
        _ snapshot: (policy: String?, marker: String?),
        expectedPolicy: String,
        expectedMarker: String?
    ) throws {
        guard snapshot.policy == expectedPolicy,
              snapshot.marker == expectedMarker else {
            throw TmuxInteractiveWindowSizeMigratorError.verificationFailed(
                expectedPolicy: expectedPolicy,
                expectedMarker: expectedMarker,
                actualPolicy: snapshot.policy,
                actualMarker: snapshot.marker
            )
        }
    }
}
