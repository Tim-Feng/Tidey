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
        var onResize: (() -> Void)?
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
            onResize?()
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
        var onProve: (() -> Void)?

        func prove(
            _ claim: TmuxInteractiveAttachClaim
        ) throws -> TmuxInteractiveVerifiedAttach? {
            claims.append(claim)
            onProve?()
            guard results.isEmpty == false else {
                return nil
            }
            return results.removeFirst()
        }
    }

    private final class ClientRefreshRequesterProbe:
        TmuxInteractiveClientRefreshRequesting,
        @unchecked Sendable
    {
        private(set) var requests = [TmuxInteractiveClientRefreshRequest]()

        func requestRefresh(
            _ request: TmuxInteractiveClientRefreshRequest
        ) throws {
            requests.append(request)
        }
    }

    private final class UptimeProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var value: UInt64 = 1_000

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

    func testOwnerClientRefreshInjectionSeamCompiles() throws {
        let requester = ClientRefreshRequesterProbe()
        let owner = TmuxInteractivePTYSessionOwner(
            admissionStore: OrdinaryTmuxInputSubmissionStore(),
            controller: ControllerProbe(),
            clientRefreshRequester: requester
        )

        try owner.close()

        XCTAssertTrue(requester.requests.isEmpty)
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

    func testOwnerAcceptsTypedTerminalReplyOnlyAfterProofAndRejectsUserInputUntilReady() throws {
        let route = makeRoute()
        let request = makeRequest(route: route, startupMode: .streamingReplies)
        let controller = ControllerProbe()
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
            admissionStore: OrdinaryTmuxInputSubmissionStore(),
            controller: controller,
            attachProver: prover
        )
        let reply = TmuxInteractiveTerminalReply(
            binding: request.subscribe.binding,
            bytes: Data([0x1b, 0x5b, 0x3e, 0x36, 0x35, 0x3b, 0x63])
        )
        let input = TmuxInteractiveInput(
            binding: request.subscribe.binding,
            bytes: Data([0x02, 0x64])
        )

        try owner.begin(request)
        XCTAssertThrowsError(try owner.sendTerminalReply(reply)) { error in
            XCTAssertEqual(
                error as? TmuxInteractivePTYSessionOwnerError,
                .terminalReplyNotEnabled(.proving)
            )
        }
        XCTAssertTrue(controller.writtenBytes.isEmpty)

        XCTAssertEqual(try owner.pollAttachProof(), verifiedAttach)
        XCTAssertEqual(owner.lifecycleState, .settling)
        XCTAssertEqual(try owner.sendTerminalReply(reply), .written(reply.bytes.count))
        XCTAssertEqual(controller.writtenBytes, [reply.bytes])
        XCTAssertThrowsError(try owner.sendInput(input)) { error in
            XCTAssertEqual(
                error as? TmuxInteractivePTYSessionOwnerError,
                .inputNotEnabled(.settling)
            )
        }

        let staleReply = TmuxInteractiveTerminalReply(
            binding: TmuxInteractiveSubscriptionBinding(
                subscriptionID: reply.binding.subscriptionID,
                generation: reply.binding.generation - 1
            ),
            bytes: Data([0x1b, 0x5b, 0x63])
        )
        XCTAssertThrowsError(try owner.sendTerminalReply(staleReply)) { error in
            XCTAssertEqual(
                error as? TmuxInteractivePTYSessionOwnerError,
                .bindingMismatch
            )
        }
        XCTAssertEqual(controller.writtenBytes, [reply.bytes])
        try owner.close()
    }

    func testOwnerStreamsAttachedOutputAndReadyBeforeLiveWithOneSequence() throws {
        let route = makeRoute()
        let request = makeRequest(route: route, startupMode: .streamingReplies)
        let controller = ControllerProbe()
        let provedPrefix = Data([0x1b, 0x5b, 0x3e, 0x63])
        controller.readResults = [.bytes(provedPrefix), .wouldBlock]
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
        let clientRefreshRequester = ClientRefreshRequesterProbe()
        let uptime = UptimeProbe()
        let quietNanoseconds: UInt64 = 100
        let owner = TmuxInteractivePTYSessionOwner(
            admissionStore: OrdinaryTmuxInputSubmissionStore(),
            controller: controller,
            attachProver: prover,
            clientRefreshRequester: clientRefreshRequester,
            authoritativeStartQuiescenceNanoseconds: quietNanoseconds,
            uptimeNanoseconds: { uptime.now() }
        )

        try owner.begin(request)
        XCTAssertEqual(try owner.pollAttachProof(), verifiedAttach)
        XCTAssertEqual(
            try owner.pollStreamingStartup(),
            .attached(
                TmuxInteractiveAttached(
                    binding: request.subscribe.binding,
                    attachProof: verifiedAttach.attachProof,
                    viewport: request.subscribe.viewport,
                    initialBytes: provedPrefix,
                    sequence: 1
                )
            )
        )

        let negotiatedOutput = Data([0x1b, 0x5b, 0x32, 0x4a])
        controller.readResults.append(.bytes(negotiatedOutput))
        XCTAssertEqual(
            try owner.pollStreamingStartup(),
            .output(
                TmuxInteractiveOutputChunk(
                    binding: request.subscribe.binding,
                    sequence: 2,
                    bytes: negotiatedOutput
                )
            )
        )
        XCTAssertEqual(try owner.pollStreamingStartup(), .wouldBlock)
        uptime.advance(by: quietNanoseconds)
        XCTAssertEqual(
            try owner.pollStreamingStartup(),
            .ready(
                TmuxInteractiveReady(
                    binding: request.subscribe.binding,
                    sequence: 3
                )
            )
        )
        XCTAssertEqual(owner.lifecycleState, .live)
        XCTAssertTrue(clientRefreshRequester.requests.isEmpty)

        let liveBytes = Data([0x00, 0xff])
        controller.readResults.append(.bytes(liveBytes))
        XCTAssertEqual(
            try owner.pollLiveOutput(),
            .output(
                TmuxInteractiveOutputChunk(
                    binding: request.subscribe.binding,
                    sequence: 4,
                    bytes: liveBytes
                )
            )
        )
        try owner.close()
    }

    func testOwnerKeepsCumulativeStartupBoundAfterStreamingAttachedPrefix() throws {
        let route = makeRoute()
        let request = makeRequest(route: route, startupMode: .streamingReplies)
        let controller = ControllerProbe()
        controller.readResults = [.bytes(Data([0x01, 0x02, 0x03, 0x04])), .wouldBlock]
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
            admissionStore: OrdinaryTmuxInputSubmissionStore(),
            controller: controller,
            attachProver: prover,
            maximumAuthoritativeStartBytes: 5
        )

        try owner.begin(request)
        XCTAssertEqual(try owner.pollAttachProof(), verifiedAttach)
        guard case .attached = try owner.pollStreamingStartup() else {
            return XCTFail("Expected the bounded proved prefix")
        }
        controller.readResults.append(.bytes(Data([0x05, 0x06])))

        XCTAssertThrowsError(try owner.pollStreamingStartup()) { error in
            XCTAssertEqual(
                error as? TmuxInteractivePTYSessionOwnerError,
                .authoritativeStartBufferOverflow(limit: 5)
            )
        }
        XCTAssertEqual(owner.lifecycleState, .closed)
        XCTAssertEqual(controller.closedFileDescriptors, [17])
        XCTAssertEqual(controller.reapCalls.count, 1)
    }

    func testOwnerPublishesProvedDirectAttachStreamAtExactViewport() throws {
        let route = makeRoute()
        let request = makeRequest(route: route)
        let controller = ControllerProbe()
        let attachBytes = Data("exact-final-grid".utf8)
        controller.readResults = [
            .bytes(attachBytes),
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
        let clientRefreshRequester = ClientRefreshRequesterProbe()
        let owner = TmuxInteractivePTYSessionOwner(
            admissionStore: OrdinaryTmuxInputSubmissionStore(),
            controller: controller,
            attachProver: prover,
            clientRefreshRequester: clientRefreshRequester
        )

        try owner.begin(request)

        XCTAssertEqual(
            controller.spawnCommands.map(\.initialSize),
            [TmuxInteractivePTYSize(columns: 80, rows: 24)]
        )
        XCTAssertTrue(controller.resizedSizes.isEmpty)
        XCTAssertEqual(try owner.pollAttachProof(), verifiedAttach)
        XCTAssertTrue(controller.resizedSizes.isEmpty)
        XCTAssertEqual(owner.lifecycleState, .redrawing)

        let start = try XCTUnwrap(owner.pollAuthoritativeStart())
        XCTAssertEqual(start.viewport, request.subscribe.viewport)
        XCTAssertNil(start.bootstrapPhase)
        XCTAssertEqual(start.initialBytes, attachBytes)
        XCTAssertTrue(clientRefreshRequester.requests.isEmpty)
        XCTAssertEqual(owner.lifecycleState, .live)

        try owner.close()
    }

    func testOwnerKeepsProofDurationBytesInSameDirectAttachStream() throws {
        let route = makeRoute()
        let request = makeRequest(route: route)
        let controller = ControllerProbe()
        let attachBytesBeforeProof = Data("initial-attach-grid".utf8)
        let attachBytesDuringProof = Data("late-attach-grid".utf8)
        controller.readResults = [
            .bytes(attachBytesBeforeProof),
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
        prover.onProve = {
            controller.readResults.append(.bytes(attachBytesDuringProof))
            controller.readResults.append(.wouldBlock)
        }
        let owner = TmuxInteractivePTYSessionOwner(
            admissionStore: OrdinaryTmuxInputSubmissionStore(),
            controller: controller,
            attachProver: prover
        )

        try owner.begin(request)
        XCTAssertEqual(try owner.pollAttachProof(), verifiedAttach)
        var observedStart: TmuxInteractiveAuthoritativeStart?
        for _ in 0..<4 where observedStart == nil {
            observedStart = try owner.pollAuthoritativeStart()
        }
        let start = try XCTUnwrap(observedStart)

        XCTAssertNil(start.bootstrapPhase)
        XCTAssertEqual(
            start.initialBytes,
            attachBytesBeforeProof + attachBytesDuringProof
        )
        XCTAssertTrue(controller.resizedSizes.isEmpty)
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

    func testOwnerPublishesOnlyProvedSameEpochQuietStreamBeforeEnablingInput() throws {
        let store = OrdinaryTmuxInputSubmissionStore()
        let route = makeRoute()
        let request = makeRequest(route: route)
        let controller = ControllerProbe()
        let preProofBytes = Data([0x70, 0x72, 0x65])
        let provedAttachBytes = Data([0x1b, 0x5b, 0x32, 0x4a])
        controller.readResults = [
            .bytes(preProofBytes),
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
        prover.onProve = {
            controller.readResults.append(.bytes(provedAttachBytes))
            controller.readResults.append(.wouldBlock)
        }
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

        XCTAssertTrue(controller.resizedSizes.isEmpty)
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
                initialBytes: preProofBytes + provedAttachBytes
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

    func testOwnerRequiresExactClientRefreshAfterQuietDirectAttachPrefix() throws {
        let store = OrdinaryTmuxInputSubmissionStore()
        let route = makeRoute()
        let request = makeRequest(route: route)
        let controller = ControllerProbe()
        let attachPrefix = Data(
            "\u{1B}[?1049h\u{1B}[21;1H> Summarize recent commits\u{1B}[23;1Hgpt-5.6-sol xhigh"
                .utf8
        )
        let postRefreshOutput = Data(
            "\u{1B}[2J\u{1B}[Hverified exact-client screen".utf8
        )
        controller.readResults = [
            .bytes(attachPrefix),
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
        let clientRefreshRequester = ClientRefreshRequesterProbe()
        let uptime = UptimeProbe()
        let quiescenceNanoseconds =
            TmuxInteractivePTYSessionOwner
                .productionAuthoritativeStartQuiescenceNanoseconds
        let postRefreshQuiescenceNanoseconds = quiescenceNanoseconds * 2
        let owner = TmuxInteractivePTYSessionOwner(
            admissionStore: store,
            controller: controller,
            attachProver: prover,
            clientRefreshRequester: clientRefreshRequester,
            authoritativeStartQuiescenceNanoseconds: quiescenceNanoseconds,
            clientRefreshTimeoutNanoseconds: 1_000_000_000,
            requiresPostRefreshObservation: true,
            postRefreshQuiescenceNanoseconds:
                postRefreshQuiescenceNanoseconds,
            uptimeNanoseconds: { uptime.now() }
        )
        try owner.begin(request)

        XCTAssertEqual(try owner.pollAttachProof(), verifiedAttach)
        XCTAssertNil(try owner.pollAuthoritativeStart())
        uptime.advance(by: quiescenceNanoseconds)

        XCTAssertNil(try owner.pollAuthoritativeStart())
        XCTAssertEqual(
            clientRefreshRequester.requests,
            [
                TmuxInteractiveClientRefreshRequest(
                    socket: route.socket,
                    clientTTY: verifiedAttach.clientTTY
                ),
            ]
        )
        XCTAssertEqual(owner.lifecycleState, .redrawing)

        controller.readResults.append(.bytes(postRefreshOutput))
        controller.readResults.append(.wouldBlock)
        XCTAssertNil(try owner.pollAuthoritativeStart())
        uptime.advance(by: postRefreshQuiescenceNanoseconds - 1)
        XCTAssertNil(try owner.pollAuthoritativeStart())
        uptime.advance(by: 1)

        let start = try XCTUnwrap(owner.pollAuthoritativeStart())
        XCTAssertNil(start.bootstrapPhase)
        XCTAssertEqual(start.initialBytes, attachPrefix + postRefreshOutput)
        XCTAssertEqual(clientRefreshRequester.requests.count, 1)
        XCTAssertEqual(owner.lifecycleState, .live)
        XCTAssertTrue(controller.resizedSizes.isEmpty)
        try owner.close()
    }

    func testOwnerPublishesProofDurationDirectAttachOutputWithoutRedundantClientRefresh() throws {
        let store = OrdinaryTmuxInputSubmissionStore()
        let route = makeRoute()
        let request = makeRequest(route: route)
        let controller = ControllerProbe()
        let authoritativeScreen = Data(
            "\u{1B}[2J\u{1B}[Hproved tmux client screen".utf8
        )
        controller.readResults = [.wouldBlock]
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
        prover.onProve = {
            controller.readResults.append(.bytes(authoritativeScreen))
            controller.readResults.append(.wouldBlock)
        }
        let clientRefreshRequester = ClientRefreshRequesterProbe()
        let uptime = UptimeProbe()
        let quiescenceNanoseconds =
            TmuxInteractivePTYSessionOwner
                .productionAuthoritativeStartQuiescenceNanoseconds
        let owner = TmuxInteractivePTYSessionOwner(
            admissionStore: store,
            controller: controller,
            attachProver: prover,
            clientRefreshRequester: clientRefreshRequester,
            authoritativeStartQuiescenceNanoseconds: quiescenceNanoseconds,
            clientRefreshTimeoutNanoseconds: 1_000_000_000,
            uptimeNanoseconds: { uptime.now() }
        )
        try owner.begin(request)
        XCTAssertEqual(try owner.pollAttachProof(), verifiedAttach)

        XCTAssertTrue(clientRefreshRequester.requests.isEmpty)
        XCTAssertTrue(controller.resizedSizes.isEmpty)
        uptime.advance(by: quiescenceNanoseconds)
        let start = try XCTUnwrap(owner.pollAuthoritativeStart())
        XCTAssertEqual(start.initialBytes, authoritativeScreen)
        XCTAssertTrue(clientRefreshRequester.requests.isEmpty)
        XCTAssertEqual(owner.lifecycleState, .live)
        try owner.close()
    }

    func testOwnerClosesWhenProvedClientRefreshProducesNoScreenByDeadline() throws {
        let store = OrdinaryTmuxInputSubmissionStore()
        let route = makeRoute()
        let controller = ControllerProbe()
        controller.readResults = [.wouldBlock, .wouldBlock, .wouldBlock]
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
        let clientRefreshRequester = ClientRefreshRequesterProbe()
        let uptime = UptimeProbe()
        let timeoutNanoseconds: UInt64 = 2_000_000_000
        let owner = TmuxInteractivePTYSessionOwner(
            admissionStore: store,
            controller: controller,
            attachProver: prover,
            clientRefreshRequester: clientRefreshRequester,
            clientRefreshTimeoutNanoseconds: timeoutNanoseconds,
            uptimeNanoseconds: { uptime.now() }
        )
        try owner.begin(makeRequest(route: route))
        XCTAssertEqual(try owner.pollAttachProof(), verifiedAttach)

        XCTAssertNil(try owner.pollAuthoritativeStart())
        uptime.advance(by: timeoutNanoseconds)
        XCTAssertThrowsError(try owner.pollAuthoritativeStart()) { error in
            XCTAssertEqual(
                error as? TmuxInteractivePTYSessionOwnerError,
                .authoritativeStartTimedOut
            )
        }
        XCTAssertEqual(clientRefreshRequester.requests.count, 1)
        XCTAssertEqual(owner.lifecycleState, .closed)
        XCTAssertEqual(controller.closedFileDescriptors, [17])
    }

    func testOwnerClosesWhenRequiredVerificationRefreshIsSilentAfterAttachPrefix() throws {
        let store = OrdinaryTmuxInputSubmissionStore()
        let route = makeRoute()
        let controller = ControllerProbe()
        controller.readResults = [
            .bytes(Data("cached attach prefix".utf8)),
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
        let clientRefreshRequester = ClientRefreshRequesterProbe()
        let uptime = UptimeProbe()
        let quiescenceNanoseconds: UInt64 = 100
        let timeoutNanoseconds: UInt64 = 200
        let owner = TmuxInteractivePTYSessionOwner(
            admissionStore: store,
            controller: controller,
            attachProver: prover,
            clientRefreshRequester: clientRefreshRequester,
            authoritativeStartQuiescenceNanoseconds: quiescenceNanoseconds,
            clientRefreshTimeoutNanoseconds: timeoutNanoseconds,
            requiresPostRefreshObservation: true,
            postRefreshQuiescenceNanoseconds:
                quiescenceNanoseconds,
            uptimeNanoseconds: { uptime.now() }
        )
        try owner.begin(makeRequest(route: route))
        XCTAssertEqual(try owner.pollAttachProof(), verifiedAttach)

        XCTAssertNil(try owner.pollAuthoritativeStart())
        uptime.advance(by: quiescenceNanoseconds)
        XCTAssertNil(try owner.pollAuthoritativeStart())
        XCTAssertEqual(clientRefreshRequester.requests.count, 1)

        uptime.advance(by: timeoutNanoseconds)
        XCTAssertThrowsError(try owner.pollAuthoritativeStart()) { error in
            XCTAssertEqual(
                error as? TmuxInteractivePTYSessionOwnerError,
                .authoritativeStartTimedOut
            )
        }
        XCTAssertEqual(owner.lifecycleState, .closed)
        XCTAssertEqual(controller.closedFileDescriptors, [17])
        XCTAssertEqual(controller.reapCalls.count, 1)
    }

    func testOwnerWaitsForContinuousAuthoritativeRedrawQuiescenceBeforePublishingStart() throws {
        let store = OrdinaryTmuxInputSubmissionStore()
        let route = makeRoute()
        let request = makeRequest(route: route)
        let controller = ControllerProbe()
        let tmuxCachedRedraw = Data([0x1b, 0x5b, 0x32, 0x4a])
        let paneTUIRedraw = Data([0x1b, 0x5b, 0x48, 0x66])
        controller.readResults = [
            .bytes(tmuxCachedRedraw),
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
        let uptime = UptimeProbe()
        let quiescenceNanoseconds =
            TmuxInteractivePTYSessionOwner
                .productionAuthoritativeStartQuiescenceNanoseconds
        let owner = TmuxInteractivePTYSessionOwner(
            admissionStore: store,
            controller: controller,
            attachProver: prover,
            authoritativeStartQuiescenceNanoseconds: quiescenceNanoseconds,
            uptimeNanoseconds: { uptime.now() }
        )
        try owner.begin(request)
        XCTAssertEqual(try owner.pollAttachProof(), verifiedAttach)

        XCTAssertNil(try owner.pollAuthoritativeStart())
        uptime.advance(by: 40_000_000)
        controller.readResults.append(.bytes(paneTUIRedraw))
        controller.readResults.append(.wouldBlock)
        XCTAssertNil(try owner.pollAuthoritativeStart())
        uptime.advance(by: quiescenceNanoseconds - 1)
        XCTAssertNil(try owner.pollAuthoritativeStart())
        XCTAssertEqual(owner.lifecycleState, .redrawing)

        uptime.advance(by: 1)
        let start = try XCTUnwrap(owner.pollAuthoritativeStart())
        XCTAssertEqual(start.initialBytes, tmuxCachedRedraw + paneTUIRedraw)
        XCTAssertEqual(owner.lifecycleState, .live)
        try owner.close()
    }

    func testOwnerClosesWhenCombinedAuthoritativeStartPhasesOverflow() throws {
        let store = OrdinaryTmuxInputSubmissionStore()
        let route = makeRoute()
        let controller = ControllerProbe()
        controller.readResults = [
            .bytes(Data([0x01])),
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
        prover.onProve = {
            controller.readResults.append(.bytes(Data([0x02, 0x03])))
        }
        let owner = TmuxInteractivePTYSessionOwner(
            admissionStore: store,
            controller: controller,
            attachProver: prover,
            maximumAuthoritativeStartBytes: 2
        )
        try owner.begin(makeRequest(route: route))
        XCTAssertThrowsError(try owner.pollAttachProof()) { error in
            XCTAssertEqual(
                error as? TmuxInteractivePTYSessionOwnerError,
                .authoritativeStartBufferOverflow(limit: 2)
            )
        }
        XCTAssertEqual(owner.lifecycleState, .closed)
        XCTAssertTrue(controller.resizedSizes.isEmpty)
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
            .bytes(Data([0x1b, 0x5b, 0x48])),
            .wouldBlock,
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

    func testOwnerAppliesOnlyLiveCurrentGenerationResizes() throws {
        let store = OrdinaryTmuxInputSubmissionStore()
        let route = makeRoute()
        let request = makeRequest(route: route)
        let controller = ControllerProbe()
        controller.readResults = [
            .bytes(Data([0x1b, 0x5b, 0x48])),
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
        let liveViewport = TmuxInteractiveViewport(columns: 100, rows: 30)
        let liveResize = TmuxInteractiveResize(
            binding: request.subscribe.binding,
            viewport: liveViewport
        )

        XCTAssertThrowsError(try owner.applyResize(liveResize)) { error in
            XCTAssertEqual(
                error as? TmuxInteractivePTYSessionOwnerError,
                .invalidState(.proving)
            )
        }
        XCTAssertEqual(try owner.pollAttachProof(), verifiedAttach)
        _ = try XCTUnwrap(owner.pollAuthoritativeStart())

        let staleResize = TmuxInteractiveResize(
            binding: TmuxInteractiveSubscriptionBinding(
                subscriptionID: request.subscribe.binding.subscriptionID,
                generation: request.subscribe.binding.generation - 1
            ),
            viewport: TmuxInteractiveViewport(columns: 0, rows: 0)
        )
        XCTAssertFalse(try owner.applyResize(staleResize))
        XCTAssertFalse(
            try owner.applyResize(
                TmuxInteractiveResize(
                    binding: request.subscribe.binding,
                    viewport: request.subscribe.viewport
                )
            )
        )
        XCTAssertTrue(try owner.applyResize(liveResize))
        XCTAssertFalse(try owner.applyResize(liveResize))
        let invalidViewport = TmuxInteractiveViewport(columns: -1, rows: 30)
        XCTAssertThrowsError(
            try owner.applyResize(
                TmuxInteractiveResize(
                    binding: request.subscribe.binding,
                    viewport: invalidViewport
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? TmuxInteractivePTYResizeGateError,
                .invalidViewport(invalidViewport)
            )
        }
        XCTAssertEqual(
            controller.resizedSizes,
            [
                TmuxInteractivePTYSize(columns: 100, rows: 30),
            ]
        )

        try owner.close()
        XCTAssertThrowsError(try owner.applyResize(liveResize)) { error in
            XCTAssertEqual(
                error as? TmuxInteractivePTYSessionOwnerError,
                .invalidState(.closed)
            )
        }
        XCTAssertEqual(controller.resizedSizes.count, 1)
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
        route: OrdinaryTmuxPanelRoute,
        startupMode: TmuxInteractiveStartupMode = .legacy
    ) -> TmuxInteractivePTYSessionStartRequest {
        TmuxInteractivePTYSessionStartRequest(
            subscribe: TmuxInteractiveSubscribe(
                workspaceID: route.workspaceID,
                panelID: route.panelID,
                binding: TmuxInteractiveSubscriptionBinding(
                    subscriptionID: "interactive-1",
                    generation: 9
                ),
                viewport: TmuxInteractiveViewport(columns: 80, rows: 24),
                startupMode: startupMode
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
