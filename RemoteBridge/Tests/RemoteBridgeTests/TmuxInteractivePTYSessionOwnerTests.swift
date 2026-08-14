import Foundation
import XCTest

@testable import RemoteBridge

final class TmuxInteractivePTYSessionOwnerTests: XCTestCase {
    private final class ControllerProbe: TmuxInteractivePTYControlling, @unchecked Sendable {
        private(set) var spawnCommands = [TmuxInteractivePTYAttachCommand]()
        private(set) var closedFileDescriptors = [Int32]()
        private(set) var reapCalls = [(processID: Int32, blocking: Bool)]()
        private(set) var writtenBytes = [Data]()
        private(set) var resizedSizes = [TmuxInteractivePTYSize]()
        var spawnError: Error?
        var onSpawn: (() -> Void)?
        var reapResult: TmuxInteractivePTYChildExit? = TmuxInteractivePTYChildExit(
            rawStatus: 0
        )
        var readResults = [TmuxInteractivePTYReadResult]()

        func spawn(_ command: TmuxInteractivePTYAttachCommand) throws -> TmuxInteractivePTYHandle {
            spawnCommands.append(command)
            onSpawn?()
            if let spawnError {
                throw spawnError
            }
            return TmuxInteractivePTYHandle(masterFileDescriptor: 17, childProcessID: 23)
        }

        func resize(masterFileDescriptor: Int32, to size: TmuxInteractivePTYSize) throws {
            XCTAssertEqual(masterFileDescriptor, 17)
            resizedSizes.append(size)
        }

        func close(masterFileDescriptor: Int32) throws {
            closedFileDescriptors.append(masterFileDescriptor)
        }

        func reap(
            childProcessID: Int32,
            blocking: Bool
        ) throws -> TmuxInteractivePTYChildExit? {
            reapCalls.append((childProcessID, blocking))
            return reapResult
        }

        func read(
            masterFileDescriptor: Int32,
            maximumBytes: Int
        ) throws -> TmuxInteractivePTYReadResult {
            guard readResults.isEmpty == false else {
                return .wouldBlock
            }
            return readResults.removeFirst()
        }

        func write(
            _ bytes: Data,
            masterFileDescriptor: Int32
        ) throws -> TmuxInteractivePTYWriteResult {
            writtenBytes.append(bytes)
            return .written(bytes.count)
        }
    }

    private final class ProverProbe: TmuxInteractiveAttachProving, @unchecked Sendable {
        private(set) var claims = [TmuxInteractiveAttachClaim]()
        var results = [TmuxInteractiveVerifiedAttach?]()

        func prove(
            _ claim: TmuxInteractiveAttachClaim
        ) throws -> TmuxInteractiveVerifiedAttach? {
            claims.append(claim)
            guard results.isEmpty == false else {
                return nil
            }
            return results.removeFirst()
        }
    }

    func testOwnerAcquiresLeaseBeforeSpawnAndReleasesOnlyAfterCloseAndReap() throws {
        let store = OrdinaryTmuxInputSubmissionStore()
        let route = makeRoute()
        let sessionKey = OrdinaryTmuxSessionKey(
            socket: route.socket,
            sessionID: route.sessionID
        )
        let request = makeRequest(route: route)
        let controller = ControllerProbe()
        let owner = TmuxInteractivePTYSessionOwner(
            admissionStore: store,
            controller: controller
        )

        XCTAssertTrue(
            store.reserve(
                submissionID: "chat-owner",
                routeKey: "chat-route",
                sessionKey: sessionKey
            )
        )
        XCTAssertThrowsError(try owner.begin(request)) { error in
            XCTAssertEqual(error as? TmuxInteractivePTYSessionOwnerError, .admissionConflict)
        }
        XCTAssertTrue(controller.spawnCommands.isEmpty)
        store.release(submissionID: "chat-owner", routeKey: "chat-route")

        controller.onSpawn = {
            XCTAssertFalse(
                store.reserve(
                    submissionID: "racing-chat",
                    routeKey: "racing-route",
                    sessionKey: sessionKey
                )
            )
        }
        try owner.begin(request)
        XCTAssertEqual(owner.lifecycleState, .proving)
        XCTAssertEqual(
            controller.spawnCommands,
            [
                TmuxInteractivePTYAttachCommand(
                    tmuxExecutablePath: "/opt/homebrew/bin/tmux",
                    socket: route.socket,
                    sessionID: route.sessionID,
                    windowID: route.windowID,
                    initialSize: TmuxInteractivePTYSize(columns: 80, rows: 24)
                ),
            ]
        )
        XCTAssertFalse(
            store.reserve(
                submissionID: "blocked-chat",
                routeKey: "blocked-route",
                sessionKey: sessionKey
            )
        )

        try owner.close()
        XCTAssertEqual(owner.lifecycleState, .closed)
        XCTAssertEqual(controller.closedFileDescriptors, [17])
        XCTAssertEqual(controller.reapCalls.count, 1)
        XCTAssertEqual(controller.reapCalls.first?.processID, 23)
        XCTAssertEqual(controller.reapCalls.first?.blocking, true)
        XCTAssertTrue(
            store.reserve(
                submissionID: "after-close",
                routeKey: "after-close-route",
                sessionKey: sessionKey
            )
        )
        store.release(submissionID: "after-close", routeKey: "after-close-route")

        let failingController = ControllerProbe()
        failingController.spawnError = TmuxInteractivePTYControllerError.operationFailed(
            operation: "spawn",
            code: EIO
        )
        let failingOwner = TmuxInteractivePTYSessionOwner(
            admissionStore: store,
            controller: failingController
        )
        XCTAssertThrowsError(try failingOwner.begin(request))
        XCTAssertEqual(failingOwner.lifecycleState, .idle)
        XCTAssertTrue(
            store.reserve(
                submissionID: "after-spawn-failure",
                routeKey: "after-spawn-failure-route",
                sessionKey: sessionKey
            )
        )
    }

    func testOwnerRetainsLeaseUntilCleanupCanReapChild() throws {
        let store = OrdinaryTmuxInputSubmissionStore()
        let route = makeRoute()
        let sessionKey = OrdinaryTmuxSessionKey(
            socket: route.socket,
            sessionID: route.sessionID
        )
        let controller = ControllerProbe()
        controller.reapResult = nil
        let owner = TmuxInteractivePTYSessionOwner(
            admissionStore: store,
            controller: controller
        )
        try owner.begin(makeRequest(route: route))

        XCTAssertThrowsError(try owner.close()) { error in
            XCTAssertEqual(
                error as? TmuxInteractivePTYSessionOwnerError,
                .childDidNotExit
            )
        }
        XCTAssertEqual(owner.lifecycleState, .closing)
        XCTAssertEqual(controller.closedFileDescriptors, [17])
        XCTAssertFalse(
            store.reserve(
                submissionID: "cleanup-still-owned",
                routeKey: "cleanup-still-owned-route",
                sessionKey: sessionKey
            )
        )

        controller.reapResult = TmuxInteractivePTYChildExit(rawStatus: 0)
        try owner.close()
        XCTAssertEqual(owner.lifecycleState, .closed)
        XCTAssertEqual(controller.closedFileDescriptors, [17])
        XCTAssertEqual(controller.reapCalls.count, 2)
        XCTAssertTrue(
            store.reserve(
                submissionID: "cleanup-complete",
                routeKey: "cleanup-complete-route",
                sessionKey: sessionKey
            )
        )
    }

    func testOwnerKeepsInputDisabledAndPreProofBytesHiddenUntilExactAttachProof() throws {
        let store = OrdinaryTmuxInputSubmissionStore()
        let route = makeRoute()
        let request = makeRequest(route: route)
        let controller = ControllerProbe()
        controller.readResults = [
            .bytes(Data([0x1b, 0x5b, 0x48])),
            .wouldBlock,
            .wouldBlock,
        ]
        let expectedAttach = TmuxInteractiveVerifiedAttach(
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
        let prover = ProverProbe()
        prover.results = [nil, expectedAttach]
        let owner = TmuxInteractivePTYSessionOwner(
            admissionStore: store,
            controller: controller,
            attachProver: prover
        )
        try owner.begin(request)
        let input = TmuxInteractiveInput(
            binding: request.subscribe.binding,
            bytes: Data([0x02, 0x63])
        )

        XCTAssertThrowsError(try owner.sendInput(input)) { error in
            XCTAssertEqual(
                error as? TmuxInteractivePTYSessionOwnerError,
                .inputNotEnabled(.proving)
            )
        }
        XCTAssertNil(try owner.pollAttachProof())
        XCTAssertEqual(owner.lifecycleState, .proving)
        XCTAssertTrue(controller.writtenBytes.isEmpty)

        XCTAssertEqual(try owner.pollAttachProof(), expectedAttach)
        XCTAssertEqual(owner.lifecycleState, .redrawing)
        XCTAssertThrowsError(try owner.sendInput(input)) { error in
            XCTAssertEqual(
                error as? TmuxInteractivePTYSessionOwnerError,
                .inputNotEnabled(.redrawing)
            )
        }
        XCTAssertTrue(controller.writtenBytes.isEmpty)
        XCTAssertEqual(
            prover.claims,
            [
                TmuxInteractiveAttachClaim(
                    socket: route.socket,
                    childProcessID: 23,
                    workspaceID: route.workspaceID,
                    panelID: route.panelID,
                    sessionID: route.sessionID,
                    windowID: route.windowID
                ),
                TmuxInteractiveAttachClaim(
                    socket: route.socket,
                    childProcessID: 23,
                    workspaceID: route.workspaceID,
                    panelID: route.panelID,
                    sessionID: route.sessionID,
                    windowID: route.windowID
                ),
            ]
        )
        try owner.close()
    }

    func testOwnerClosesAndReleasesLeaseWhenPreProofBufferOverflows() throws {
        let store = OrdinaryTmuxInputSubmissionStore()
        let route = makeRoute()
        let controller = ControllerProbe()
        controller.readResults = [.bytes(Data([0x01, 0x02, 0x03]))]
        let owner = TmuxInteractivePTYSessionOwner(
            admissionStore: store,
            controller: controller,
            attachProver: ProverProbe(),
            maximumPreProofBytes: 2
        )
        try owner.begin(makeRequest(route: route))

        XCTAssertThrowsError(try owner.pollAttachProof()) { error in
            XCTAssertEqual(
                error as? TmuxInteractivePTYSessionOwnerError,
                .preProofBufferOverflow(limit: 2)
            )
        }
        XCTAssertEqual(owner.lifecycleState, .closed)
        XCTAssertEqual(controller.closedFileDescriptors, [17])
        XCTAssertEqual(controller.reapCalls.count, 1)
        let sessionKey = OrdinaryTmuxSessionKey(
            socket: route.socket,
            sessionID: route.sessionID
        )
        let token = OrdinaryTmuxInteractiveLeaseToken(rawValue: "after-overflow")
        XCTAssertTrue(store.acquireInteractiveLease(token: token, sessionKey: sessionKey))
        store.releaseInteractiveLease(token: token, sessionKey: sessionKey)
    }

    func testOwnerPublishesOnlyPostSizeQuietFrameBeforeEnablingInput() throws {
        let store = OrdinaryTmuxInputSubmissionStore()
        let route = makeRoute()
        let request = makeRequest(route: route)
        let controller = ControllerProbe()
        let preProofBytes = Data([0x70, 0x72, 0x65])
        let redrawBytes = Data([0x1b, 0x5b, 0x32, 0x4a])
        controller.readResults = [
            .bytes(preProofBytes),
            .wouldBlock,
            .bytes(redrawBytes),
            .wouldBlock,
            .wouldBlock,
        ]
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
        let prover = ProverProbe()
        prover.results = [verifiedAttach]
        let owner = TmuxInteractivePTYSessionOwner(
            admissionStore: store,
            controller: controller,
            attachProver: prover
        )
        try owner.begin(request)
        XCTAssertEqual(try owner.pollAttachProof(), verifiedAttach)
        let input = TmuxInteractiveInput(
            binding: request.subscribe.binding,
            bytes: Data([0x02, 0x63])
        )

        XCTAssertNil(try owner.pollAuthoritativeStart())
        XCTAssertEqual(
            controller.resizedSizes,
            [TmuxInteractivePTYSize(columns: 80, rows: 24)]
        )
        XCTAssertThrowsError(try owner.sendInput(input)) { error in
            XCTAssertEqual(
                error as? TmuxInteractivePTYSessionOwnerError,
                .inputNotEnabled(.redrawing)
            )
        }

        let start = try XCTUnwrap(owner.pollAuthoritativeStart())
        XCTAssertEqual(
            start,
            TmuxInteractiveAuthoritativeStart(
                binding: request.subscribe.binding,
                attachProof: verifiedAttach.attachProof,
                viewport: request.subscribe.viewport,
                initialBytes: redrawBytes
            )
        )
        XCTAssertEqual(owner.lifecycleState, .live)
        XCTAssertEqual(try owner.sendInput(input), .written(2))
        XCTAssertEqual(controller.writtenBytes, [input.bytes])

        let staleInput = TmuxInteractiveInput(
            binding: TmuxInteractiveSubscriptionBinding(
                subscriptionID: input.binding.subscriptionID,
                generation: input.binding.generation - 1
            ),
            bytes: Data([0x04])
        )
        XCTAssertThrowsError(try owner.sendInput(staleInput)) { error in
            XCTAssertEqual(
                error as? TmuxInteractivePTYSessionOwnerError,
                .bindingMismatch
            )
        }
        XCTAssertEqual(controller.writtenBytes, [input.bytes])
        try owner.close()
    }

    func testOwnerClosesWhenAuthoritativeStartFrameOverflows() throws {
        let store = OrdinaryTmuxInputSubmissionStore()
        let route = makeRoute()
        let controller = ControllerProbe()
        controller.readResults = [
            .wouldBlock,
            .bytes(Data([0x01, 0x02, 0x03])),
        ]
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
        let prover = ProverProbe()
        prover.results = [verifiedAttach]
        let owner = TmuxInteractivePTYSessionOwner(
            admissionStore: store,
            controller: controller,
            attachProver: prover,
            maximumAuthoritativeStartBytes: 2
        )
        try owner.begin(makeRequest(route: route))
        XCTAssertEqual(try owner.pollAttachProof(), verifiedAttach)

        XCTAssertThrowsError(try owner.pollAuthoritativeStart()) { error in
            XCTAssertEqual(
                error as? TmuxInteractivePTYSessionOwnerError,
                .authoritativeStartBufferOverflow(limit: 2)
            )
        }
        XCTAssertEqual(owner.lifecycleState, .closed)
        XCTAssertEqual(
            controller.resizedSizes,
            [TmuxInteractivePTYSize(columns: 80, rows: 24)]
        )
        XCTAssertEqual(controller.closedFileDescriptors, [17])
        XCTAssertEqual(controller.reapCalls.count, 1)
    }

    func testOwnerEmitsOrderedLiveOutputAndTreatsEOFAsNormalDetach() throws {
        let store = OrdinaryTmuxInputSubmissionStore()
        let route = makeRoute()
        let request = makeRequest(route: route)
        let controller = ControllerProbe()
        let firstOutput = Data([0x66, 0x69, 0x72, 0x73, 0x74])
        let secondOutput = Data([0x73, 0x65, 0x63, 0x6f, 0x6e, 0x64])
        controller.readResults = [
            .wouldBlock,
            .bytes(Data([0x1b, 0x5b, 0x48])),
            .wouldBlock,
            .wouldBlock,
            .bytes(firstOutput),
            .bytes(secondOutput),
            .endOfFile,
        ]
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
        let prover = ProverProbe()
        prover.results = [verifiedAttach]
        let owner = TmuxInteractivePTYSessionOwner(
            admissionStore: store,
            controller: controller,
            attachProver: prover
        )
        try owner.begin(request)
        XCTAssertEqual(try owner.pollAttachProof(), verifiedAttach)
        XCTAssertNil(try owner.pollAuthoritativeStart())
        _ = try XCTUnwrap(owner.pollAuthoritativeStart())

        XCTAssertEqual(
            try owner.pollLiveOutput(),
            .output(
                TmuxInteractiveOutputChunk(
                    binding: request.subscribe.binding,
                    sequence: 1,
                    bytes: firstOutput
                )
            )
        )
        XCTAssertEqual(
            try owner.pollLiveOutput(),
            .output(
                TmuxInteractiveOutputChunk(
                    binding: request.subscribe.binding,
                    sequence: 2,
                    bytes: secondOutput
                )
            )
        )
        XCTAssertEqual(
            try owner.pollLiveOutput(),
            .terminal(
                TmuxInteractiveStateChange(
                    binding: request.subscribe.binding,
                    state: .detached,
                    message: nil
                )
            )
        )
        XCTAssertEqual(owner.lifecycleState, .closed)
        XCTAssertEqual(controller.closedFileDescriptors, [17])
        XCTAssertEqual(controller.reapCalls.count, 1)
        XCTAssertEqual(controller.spawnCommands.count, 1)
        XCTAssertThrowsError(try owner.pollLiveOutput()) { error in
            XCTAssertEqual(
                error as? TmuxInteractivePTYSessionOwnerError,
                .invalidState(.closed)
            )
        }

        let sessionKey = OrdinaryTmuxSessionKey(
            socket: route.socket,
            sessionID: route.sessionID
        )
        let token = OrdinaryTmuxInteractiveLeaseToken(rawValue: "after-detach")
        XCTAssertTrue(store.acquireInteractiveLease(token: token, sessionKey: sessionKey))
        store.releaseInteractiveLease(token: token, sessionKey: sessionKey)
    }

    func testOwnerRejectsUnresolvedTargetBeforeAdmissionOrSpawn() throws {
        let store = OrdinaryTmuxInputSubmissionStore()
        let route = makeRoute()
        let controller = ControllerProbe()
        let owner = TmuxInteractivePTYSessionOwner(
            admissionStore: store,
            controller: controller
        )
        let validRequest = makeRequest(route: route)
        let invalidRequest = TmuxInteractivePTYSessionStartRequest(
            subscribe: TmuxInteractiveSubscribe(
                workspaceID: "different-workspace",
                panelID: validRequest.subscribe.panelID,
                binding: validRequest.subscribe.binding,
                viewport: validRequest.subscribe.viewport
            ),
            route: route,
            tmuxExecutablePath: validRequest.tmuxExecutablePath
        )

        XCTAssertThrowsError(try owner.begin(invalidRequest)) { error in
            XCTAssertEqual(error as? TmuxInteractivePTYSessionOwnerError, .invalidRequest)
        }
        XCTAssertEqual(owner.lifecycleState, .idle)
        XCTAssertTrue(controller.spawnCommands.isEmpty)
        let sessionKey = OrdinaryTmuxSessionKey(
            socket: route.socket,
            sessionID: route.sessionID
        )
        let token = OrdinaryTmuxInteractiveLeaseToken(rawValue: "validation-check")
        XCTAssertTrue(store.acquireInteractiveLease(token: token, sessionKey: sessionKey))
        store.releaseInteractiveLease(token: token, sessionKey: sessionKey)
    }

    private func makeRequest(
        route: OrdinaryTmuxPanelRoute
    ) -> TmuxInteractivePTYSessionStartRequest {
        TmuxInteractivePTYSessionStartRequest(
            subscribe: TmuxInteractiveSubscribe(
                workspaceID: route.workspaceID,
                panelID: route.panelID,
                binding: TmuxInteractiveSubscriptionBinding(
                    subscriptionID: "interactive-1",
                    generation: 9
                ),
                viewport: TmuxInteractiveViewport(columns: 80, rows: 24)
            ),
            route: route,
            tmuxExecutablePath: "/opt/homebrew/bin/tmux"
        )
    }

    private func makeRoute() -> OrdinaryTmuxPanelRoute {
        OrdinaryTmuxPanelRoute(
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
    }
}
