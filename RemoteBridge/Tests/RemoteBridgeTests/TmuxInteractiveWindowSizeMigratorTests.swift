import Foundation
import XCTest

@testable import RemoteBridge

final class TmuxInteractiveWindowSizeMigratorTests: XCTestCase {
    private final class RunnerState: @unchecked Sendable {
        struct Call: Equatable {
            let socket: OrdinaryTmuxSocketSelector
            let arguments: [String]
        }

        var currentPolicy: String
        var marker: String?
        var policyAfterSetBeforeVerification: String?
        private var didSetPolicy = false
        private(set) var calls = [Call]()

        init(currentPolicy: String, marker: String?) {
            self.currentPolicy = currentPolicy
            self.marker = marker
        }

        func run(
            socket: OrdinaryTmuxSocketSelector,
            arguments: [String],
            stdin: String?
        ) throws -> String {
            XCTAssertNil(stdin)
            calls.append(Call(socket: socket, arguments: arguments))
            if arguments.first == "display-message" {
                if didSetPolicy, let policyAfterSetBeforeVerification {
                    currentPolicy = policyAfterSetBeforeVerification
                    self.policyAfterSetBeforeVerification = nil
                }
                return "TIDEYv1|\(currentPolicy)|\(marker ?? "")|END"
            }
            if arguments == [
                "set-option", "-w", "-t", "@15", "window-size", "latest",
            ] {
                currentPolicy = "latest"
                didSetPolicy = true
                return ""
            }
            if arguments == [
                "set-option", "-u", "-w", "-t", "@15",
                TmuxInteractiveWindowSizeMigrationClassifier.markerOption,
            ] {
                marker = nil
                return ""
            }
            XCTFail("Unexpected tmux arguments: \(arguments)")
            return ""
        }
    }

    func testMigratorVerifiesLatestBeforeClearingExactMarker() throws {
        let socket = OrdinaryTmuxSocketSelector.path("/private/tmp/tmux-501/isolated")
        let eligibleState = RunnerState(currentPolicy: "largest", marker: "latest")
        let eligibleMigrator = TmuxInteractiveWindowSizeMigrator(
            commandRunner: { @Sendable [eligibleState] socket, arguments, stdin in
                try eligibleState.run(socket: socket, arguments: arguments, stdin: stdin)
            }
        )

        XCTAssertEqual(
            try eligibleMigrator.migrateIfEligible(
                socket: socket,
                windowID: "@15",
                hasLaterPolicyChangeEvidence: false
            ),
            .migrated(
                TmuxInteractiveWindowSizeMigration(
                    windowID: "@15",
                    expectedCurrentPolicy: "largest",
                    restoredPolicy: "latest",
                    markerOption: "@tidey_window_size_before_multi_client",
                    expectedMarkerValue: "latest"
                )
            )
        )
        XCTAssertEqual(eligibleState.currentPolicy, "latest")
        XCTAssertNil(eligibleState.marker)
        XCTAssertEqual(
            eligibleState.calls.map(\.arguments),
            [
                snapshotArguments,
                ["set-option", "-w", "-t", "@15", "window-size", "latest"],
                snapshotArguments,
                [
                    "set-option", "-u", "-w", "-t", "@15",
                    "@tidey_window_size_before_multi_client",
                ],
                snapshotArguments,
            ]
        )
        XCTAssertTrue(eligibleState.calls.allSatisfy { $0.socket == socket })

        let interferedState = RunnerState(currentPolicy: "largest", marker: "latest")
        interferedState.policyAfterSetBeforeVerification = "manual"
        let interferedMigrator = TmuxInteractiveWindowSizeMigrator(
            commandRunner: { @Sendable [interferedState] socket, arguments, stdin in
                try interferedState.run(socket: socket, arguments: arguments, stdin: stdin)
            }
        )
        XCTAssertThrowsError(
            try interferedMigrator.migrateIfEligible(
                socket: socket,
                windowID: "@15",
                hasLaterPolicyChangeEvidence: false
            )
        ) { error in
            XCTAssertEqual(
                error as? TmuxInteractiveWindowSizeMigratorError,
                .verificationFailed(
                    expectedPolicy: "latest",
                    expectedMarker: "latest",
                    actualPolicy: "manual",
                    actualMarker: "latest"
                )
            )
        }
        XCTAssertEqual(interferedState.marker, "latest")
        XCTAssertFalse(
            interferedState.calls.contains {
                $0.arguments.contains("-u")
            }
        )

        let customState = RunnerState(currentPolicy: "manual", marker: "latest ")
        let customMigrator = TmuxInteractiveWindowSizeMigrator(
            commandRunner: { @Sendable [customState] socket, arguments, stdin in
                try customState.run(socket: socket, arguments: arguments, stdin: stdin)
            }
        )
        XCTAssertEqual(
            try customMigrator.migrateIfEligible(
                socket: socket,
                windowID: "@15",
                hasLaterPolicyChangeEvidence: false
            ),
            .notEligible(.currentPolicyNotOwned("manual"))
        )
        XCTAssertEqual(customState.calls.map(\.arguments), [snapshotArguments])
        XCTAssertEqual(customState.marker, "latest ")
    }

    private var snapshotArguments: [String] {
        [
            "display-message", "-p", "-t", "@15",
            "TIDEYv1|#{window-size}|#{@tidey_window_size_before_multi_client}|END",
        ]
    }
}
