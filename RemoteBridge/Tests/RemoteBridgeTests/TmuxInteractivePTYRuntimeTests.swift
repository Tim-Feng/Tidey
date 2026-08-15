import XCTest

@testable import RemoteBridge

final class TmuxInteractivePTYRuntimeTests: XCTestCase {
    private final class ControllerProbe:
        TmuxInteractivePTYControlling,
        @unchecked Sendable
    {
        private let lock = NSLock()
        private var _spawnCount = 0
        private var readResults: [TmuxInteractivePTYReadResult] = []

        var spawnCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return _spawnCount
        }

        func setReadResults(_ results: [TmuxInteractivePTYReadResult]) {
            lock.lock()
            readResults = results
            lock.unlock()
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
            lock.lock()
            defer { lock.unlock() }
            guard readResults.isEmpty == false else {
                return .wouldBlock
            }
            return readResults.removeFirst()
        }

        func write(
            _ bytes: Data,
            masterFileDescriptor: Int32
        ) throws -> TmuxInteractivePTYWriteResult {
            .written(bytes.count)
        }
    }

    private struct ProverStub: TmuxInteractiveAttachProving {
        let verifiedAttach: TmuxInteractiveVerifiedAttach?

        init(verifiedAttach: TmuxInteractiveVerifiedAttach? = nil) {
            self.verifiedAttach = verifiedAttach
        }

        func prove(
            _ claim: TmuxInteractiveAttachClaim
        ) throws -> TmuxInteractiveVerifiedAttach? {
            verifiedAttach
        }
    }

    private final class ClientRefreshRequesterProbe:
        TmuxInteractiveClientRefreshRequesting,
        @unchecked Sendable
    {
        private let lock = NSLock()
        private var _requests: [TmuxInteractiveClientRefreshRequest] = []

        var requests: [TmuxInteractiveClientRefreshRequest] {
            lock.lock()
            defer { lock.unlock() }
            return _requests
        }

        func requestRefresh(
            _ request: TmuxInteractiveClientRefreshRequest
        ) throws {
            lock.lock()
            _requests.append(request)
            lock.unlock()
        }
    }

    private final class UptimeProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var value: UInt64 = 0

        func now() -> UInt64 {
            lock.lock()
            defer { lock.unlock() }
            return value
        }

        func advance(by nanoseconds: UInt64) {
            lock.lock()
            value += nanoseconds
            lock.unlock()
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

    func testEnabledRuntimeRequiresPostRefreshObservationForNonemptyPrefix() throws {
        let controller = ControllerProbe()
        controller.setReadResults([
            .bytes(Data("cached direct-attach prefix".utf8)),
            .wouldBlock,
            .wouldBlock,
            .wouldBlock,
        ])
        let route = OrdinaryTmuxPanelRoute(
            workspaceID: "workspace-runtime-refresh",
            panelID: "ordinary-tmux:path:$1:@2",
            carrierPanelID: "carrier-runtime-refresh",
            socket: .path("/private/tmp/tmux-501/default"),
            sessionID: "$1",
            sessionName: "session-runtime-refresh",
            windowID: "@2",
            windowIndex: 1,
            activePaneID: "%3",
            cwd: nil,
            currentCommand: "zsh"
        )
        let verifiedAttach = TmuxInteractiveVerifiedAttach(
            attachProof: TmuxInteractiveAttachProof(
                workspaceID: route.workspaceID,
                panelID: route.panelID,
                sessionID: route.sessionID,
                windowID: route.windowID,
                paneID: route.activePaneID
            ),
            childProcessID: 23,
            clientTTY: "/dev/ttys001"
        )
        let clientRefreshRequester = ClientRefreshRequesterProbe()
        let uptime = UptimeProbe()
        let runtime = TmuxInteractivePTYRuntime.enabled(
            tmuxExecutablePath: "/opt/homebrew/bin/tmux",
            controller: controller,
            attachProver: ProverStub(verifiedAttach: verifiedAttach),
            clientRefreshRequester: clientRefreshRequester,
            uptimeNanoseconds: { uptime.now() },
            migrateWindow: { _, _ in
                .notEligible(.currentPolicyNotOwned("latest"))
            }
        )
        runtime.ordinaryTmuxProjectionContext.registry.replaceRoutes(
            workspaceID: route.workspaceID,
            routes: [route]
        )
        let subscribe = TmuxInteractiveSubscribe(
            workspaceID: route.workspaceID,
            panelID: route.panelID,
            binding: TmuxInteractiveSubscriptionBinding(
                subscriptionID: "interactive-runtime-refresh",
                generation: 1
            ),
            viewport: TmuxInteractiveViewport(columns: 50, rows: 45)
        )
        let session = try XCTUnwrap(
            runtime.activation.candidateBuilder?.build(subscribe)
        )
        defer { try? session.close() }

        XCTAssertEqual(try session.poll(), .wouldBlock)
        XCTAssertEqual(try session.poll(), .wouldBlock)
        XCTAssertTrue(clientRefreshRequester.requests.isEmpty)

        uptime.advance(
            by: TmuxInteractivePTYSessionOwner
                .productionAuthoritativeStartQuiescenceNanoseconds
        )

        XCTAssertEqual(try session.poll(), .wouldBlock)
        XCTAssertEqual(
            clientRefreshRequester.requests,
            [
                TmuxInteractiveClientRefreshRequest(
                    socket: route.socket,
                    clientTTY: verifiedAttach.clientTTY
                ),
            ]
        )
    }

    func testProductionRuntimeEnablesOnlyWithDiscoveredTmuxPath() {
        let enabled = TmuxInteractivePTYRuntime.production(
            tmuxExecutablePath: "/opt/homebrew/bin/tmux"
        )
        XCTAssertEqual(
            enabled.activation.protocolCapabilities,
            [TmuxInteractiveProtocolV1.capability]
        )
        XCTAssertNotNil(enabled.activation.candidateBuilder)
        XCTAssertEqual(
            enabled.ordinaryTmuxProjectionContext
                .windowSizePolicyReconciliationMode,
            .preserveForInteractiveSizing
        )

        let unavailable = TmuxInteractivePTYRuntime.production(
            tmuxExecutablePath: nil
        )
        XCTAssertTrue(unavailable.activation.protocolCapabilities.isEmpty)
        XCTAssertNil(unavailable.activation.candidateBuilder)
        XCTAssertEqual(
            unavailable.ordinaryTmuxProjectionContext
                .windowSizePolicyReconciliationMode,
            .stabilizeLargest
        )
    }
}
