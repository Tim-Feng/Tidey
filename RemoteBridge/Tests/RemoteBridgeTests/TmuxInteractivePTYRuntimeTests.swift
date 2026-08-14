import XCTest

@testable import RemoteBridge

final class TmuxInteractivePTYRuntimeTests: XCTestCase {
    private final class ControllerProbe:
        TmuxInteractivePTYControlling,
        @unchecked Sendable
    {
        private let lock = NSLock()
        private var _spawnCount = 0

        var spawnCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return _spawnCount
        }

        func spawn(
            _ command: TmuxInteractivePTYAttachCommand
        ) throws -> TmuxInteractivePTYHandle {
            lock.lock()
            _spawnCount += 1
            lock.unlock()
            return TmuxInteractivePTYHandle(
                masterFileDescriptor: 17,
                childProcessID: 23
            )
        }

        func resize(
            masterFileDescriptor: Int32,
            to size: TmuxInteractivePTYSize
        ) throws {}

        func close(masterFileDescriptor: Int32) throws {}

        func reap(
            childProcessID: Int32,
            blocking: Bool
        ) throws -> TmuxInteractivePTYChildExit? {
            TmuxInteractivePTYChildExit(rawStatus: 0)
        }

        func read(
            masterFileDescriptor: Int32,
            maximumBytes: Int
        ) throws -> TmuxInteractivePTYReadResult {
            .wouldBlock
        }

        func write(
            _ bytes: Data,
            masterFileDescriptor: Int32
        ) throws -> TmuxInteractivePTYWriteResult {
            .written(bytes.count)
        }
    }

    private struct ProverStub: TmuxInteractiveAttachProving {
        func prove(
            _ claim: TmuxInteractiveAttachClaim
        ) throws -> TmuxInteractiveVerifiedAttach? {
            nil
        }
    }

    func testDisabledRuntimeOwnsActivationAndProjectionContextTogether() {
        let runtime = TmuxInteractivePTYRuntime.disabled()

        XCTAssertNil(runtime.activation.candidateBuilder)
        XCTAssertTrue(runtime.activation.protocolCapabilities.isEmpty)
        XCTAssertTrue(
            runtime.ordinaryTmuxProjectionContext.registry ===
                runtime.ordinaryTmuxProjectionContext.registry
        )
        XCTAssertTrue(
            runtime.ordinaryTmuxProjectionContext.inputSubmissionStore ===
                runtime.ordinaryTmuxProjectionContext.inputSubmissionStore
        )
    }

    func testEnabledRuntimeBindsPreservedSizingRoutingCapabilityAndAdmissionStore() throws {
        let controller = ControllerProbe()
        let runtime = TmuxInteractivePTYRuntime.enabled(
            tmuxExecutablePath: "/opt/homebrew/bin/tmux",
            controller: controller,
            attachProver: ProverStub(),
            migrateWindow: { _, _ in
                .notEligible(.currentPolicyNotOwned("latest"))
            }
        )
        XCTAssertEqual(
            runtime.ordinaryTmuxProjectionContext
                .windowSizePolicyReconciliationMode,
            .preserveForInteractiveSizing
        )
        XCTAssertEqual(
            runtime.activation.protocolCapabilities,
            [TmuxInteractiveProtocolV1.capability]
        )
        let candidateBuilder = try XCTUnwrap(
            runtime.activation.candidateBuilder
        )

        let route = OrdinaryTmuxPanelRoute(
            workspaceID: "workspace-1",
            panelID: "ordinary-tmux:path:$1:@2",
            carrierPanelID: "carrier-1",
            socket: .path("/private/tmp/tmux-501/default"),
            sessionID: "$1",
            sessionName: "session-1",
            windowID: "@2",
            windowIndex: 1,
            activePaneID: "%3",
            cwd: nil,
            currentCommand: "zsh"
        )
        runtime.ordinaryTmuxProjectionContext.registry.replaceRoutes(
            workspaceID: route.workspaceID,
            routes: [route]
        )
        let sessionKey = OrdinaryTmuxSessionKey(
            socket: route.socket,
            sessionID: route.sessionID
        )
        let reservationStore =
            runtime.ordinaryTmuxProjectionContext.inputSubmissionStore
        XCTAssertTrue(
            reservationStore.reserve(
                submissionID: "chat-1",
                routeKey: route.panelID,
                sessionKey: sessionKey
            )
        )
        defer {
            reservationStore.release(
                submissionID: "chat-1",
                routeKey: route.panelID
            )
        }

        let subscribe = TmuxInteractiveSubscribe(
            workspaceID: route.workspaceID,
            panelID: route.panelID,
            binding: TmuxInteractiveSubscriptionBinding(
                subscriptionID: "interactive-1",
                generation: 1
            ),
            viewport: TmuxInteractiveViewport(columns: 80, rows: 24)
        )
        XCTAssertThrowsError(try candidateBuilder.build(subscribe)) { error in
            XCTAssertEqual(
                error as? TmuxInteractivePTYSessionOwnerError,
                .admissionConflict
            )
        }
        XCTAssertEqual(controller.spawnCount, 0)
    }
}
