import Foundation

struct TmuxInteractivePTYSessionStartRequest: Equatable, Sendable {
    let subscribe: TmuxInteractiveSubscribe
    let route: OrdinaryTmuxPanelRoute
    let tmuxExecutablePath: String
}

enum TmuxInteractivePTYSessionLifecycleState: Equatable, Sendable {
    case idle
    case reserving
    case spawning
    case proving
    case redrawing
    case settling
    case live
    case closing
    case closed
}

enum TmuxInteractivePTYSessionOwnerError: Error, Equatable {
    case invalidRequest
    case admissionConflict
    case invalidState(TmuxInteractivePTYSessionLifecycleState)
    case inputNotEnabled(TmuxInteractivePTYSessionLifecycleState)
    case terminalReplyNotEnabled(TmuxInteractivePTYSessionLifecycleState)
    case bindingMismatch
    case unexpectedEndBeforeProof
    case preProofBufferOverflow(limit: Int)
    case attachProofMismatch
    case unexpectedEndBeforeAuthoritativeStart
    case authoritativeStartBufferOverflow(limit: Int)
    case authoritativeStartTimedOut
    case outputSequenceExhausted
    case childDidNotExit
}

enum TmuxInteractivePTYSessionLivePollResult: Equatable, Sendable {
    case output(TmuxInteractiveOutputChunk)
    case wouldBlock
    case terminal(TmuxInteractiveStateChange)
}

enum TmuxInteractivePTYSessionStartupPollResult: Equatable, Sendable {
    case attached(TmuxInteractiveAttached)
    case output(TmuxInteractiveOutputChunk)
    case ready(TmuxInteractiveReady)
    case wouldBlock
}

final class TmuxInteractivePTYSessionOwner: @unchecked Sendable {
    static let productionAuthoritativeStartQuiescenceNanoseconds: UInt64 =
        150_000_000
    static let productionPostRefreshQuiescenceNanoseconds: UInt64 =
        500_000_000
    static let productionClientRefreshTimeoutNanoseconds: UInt64 =
        2_000_000_000
    static let productionStreamingStartupDeadlineNanoseconds: UInt64 =
        2_000_000_000

    private final class ActiveResources {
        let handle: TmuxInteractivePTYHandle
        let sessionKey: OrdinaryTmuxSessionKey
        let leaseToken: OrdinaryTmuxInteractiveLeaseToken
        let request: TmuxInteractivePTYSessionStartRequest
        let initialSize: TmuxInteractivePTYSize
        var preProofBytes = Data()
        var verifiedAttach: TmuxInteractiveVerifiedAttach?
        var authoritativeStartCollectionBeganAtUptimeNanoseconds: UInt64?
        var didRequestClientRefresh = false
        var didObserveOutputAfterRefreshRequest = false
        var clientRefreshRequestedAtUptimeNanoseconds: UInt64?
        var authoritativeStartBytes = Data()
        var streamingStartupByteCount = 0
        var didPublishStreamingAttached = false
        var shouldPublishStreamingReady = false
        var lastAuthoritativeOutputUptimeNanoseconds: UInt64?
        var resizeGate: TmuxInteractivePTYResizeGate?
        var nextOutputSequence: UInt64 = 1
        var didCloseMaster = false

        init(
            handle: TmuxInteractivePTYHandle,
            sessionKey: OrdinaryTmuxSessionKey,
            leaseToken: OrdinaryTmuxInteractiveLeaseToken,
            request: TmuxInteractivePTYSessionStartRequest,
            initialSize: TmuxInteractivePTYSize
        ) {
            self.handle = handle
            self.sessionKey = sessionKey
            self.leaseToken = leaseToken
            self.request = request
            self.initialSize = initialSize
        }
    }

    private let queue = DispatchQueue(
        label: "com.tidey.remote-bridge.tmux-interactive-pty-session-owner"
    )
    private let admissionStore: OrdinaryTmuxInputSubmissionStore
    private let controller: TmuxInteractivePTYControlling
    private let attachProver: TmuxInteractiveAttachProving
    private let clientRefreshRequester: TmuxInteractiveClientRefreshRequesting
    private let maximumPreProofBytes: Int
    private let maximumAuthoritativeStartBytes: Int
    private let authoritativeStartQuiescenceNanoseconds: UInt64
    private let streamingStartupDeadlineNanoseconds: UInt64
    private let clientRefreshTimeoutNanoseconds: UInt64
    private let requiresPostRefreshObservation: Bool
    private let postRefreshQuiescenceNanoseconds: UInt64
    private let uptimeNanoseconds: @Sendable () -> UInt64
    private var state = TmuxInteractivePTYSessionLifecycleState.idle
    private var activeResources: ActiveResources?

    init(
        admissionStore: OrdinaryTmuxInputSubmissionStore,
        controller: TmuxInteractivePTYControlling,
        attachProver: TmuxInteractiveAttachProving = TmuxInteractiveAttachProver(),
        clientRefreshRequester: TmuxInteractiveClientRefreshRequesting =
            DisabledTmuxInteractiveClientRefreshRequester(),
        maximumPreProofBytes: Int = 1_024 * 1_024,
        maximumAuthoritativeStartBytes: Int = 1_024 * 1_024,
        authoritativeStartQuiescenceNanoseconds: UInt64 = 0,
        streamingStartupDeadlineNanoseconds: UInt64 = .max,
        clientRefreshTimeoutNanoseconds: UInt64 = .max,
        requiresPostRefreshObservation: Bool = false,
        postRefreshQuiescenceNanoseconds: UInt64? = nil,
        uptimeNanoseconds: @escaping @Sendable () -> UInt64 = {
            DispatchTime.now().uptimeNanoseconds
        }
    ) {
        self.admissionStore = admissionStore
        self.controller = controller
        self.attachProver = attachProver
        self.clientRefreshRequester = clientRefreshRequester
        self.maximumPreProofBytes = max(1, maximumPreProofBytes)
        self.maximumAuthoritativeStartBytes = max(1, maximumAuthoritativeStartBytes)
        self.authoritativeStartQuiescenceNanoseconds =
            authoritativeStartQuiescenceNanoseconds
        self.streamingStartupDeadlineNanoseconds =
            streamingStartupDeadlineNanoseconds
        self.clientRefreshTimeoutNanoseconds = clientRefreshTimeoutNanoseconds
        self.requiresPostRefreshObservation =
            requiresPostRefreshObservation
        self.postRefreshQuiescenceNanoseconds =
            postRefreshQuiescenceNanoseconds
                ?? authoritativeStartQuiescenceNanoseconds
        self.uptimeNanoseconds = uptimeNanoseconds
    }

    var lifecycleState: TmuxInteractivePTYSessionLifecycleState {
        queue.sync { state }
    }

    func begin(_ request: TmuxInteractivePTYSessionStartRequest) throws {
        try queue.sync {
            guard state == .idle else {
                throw TmuxInteractivePTYSessionOwnerError.invalidState(state)
            }
            guard let initialSize = Self.validatedInitialSize(request) else {
                throw TmuxInteractivePTYSessionOwnerError.invalidRequest
            }

            let sessionKey = OrdinaryTmuxSessionKey(
                socket: request.route.socket,
                sessionID: request.route.sessionID
            )
            let leaseToken = OrdinaryTmuxInteractiveLeaseToken(
                rawValue: UUID().uuidString
            )
            state = .reserving
            guard admissionStore.acquireInteractiveLease(
                token: leaseToken,
                sessionKey: sessionKey
            ) else {
                state = .idle
                throw TmuxInteractivePTYSessionOwnerError.admissionConflict
            }

            state = .spawning
            do {
                let handle = try controller.spawn(
                    TmuxInteractivePTYAttachCommand(
                        tmuxExecutablePath: request.tmuxExecutablePath,
                        socket: request.route.socket,
                        sessionID: request.route.sessionID,
                        windowID: request.route.windowID,
                        initialSize: initialSize
                    )
                )
                activeResources = ActiveResources(
                    handle: handle,
                    sessionKey: sessionKey,
                    leaseToken: leaseToken,
                    request: request,
                    initialSize: initialSize
                )
                state = .proving
            } catch {
                admissionStore.releaseInteractiveLease(
                    token: leaseToken,
                    sessionKey: sessionKey
                )
                state = .idle
                throw error
            }
        }
    }

    func pollAttachProof() throws -> TmuxInteractiveVerifiedAttach? {
        try queue.sync {
            guard state == .proving,
                  let resources = activeResources else {
                throw TmuxInteractivePTYSessionOwnerError.invalidState(state)
            }
            do {
                try drainPreProofBytes(resources)
                let route = resources.request.route
                let subscribe = resources.request.subscribe
                guard let verified = try attachProver.prove(
                    TmuxInteractiveAttachClaim(
                        socket: route.socket,
                        childProcessID: resources.handle.childProcessID,
                        workspaceID: subscribe.workspaceID,
                        panelID: subscribe.panelID,
                        sessionID: route.sessionID,
                        windowID: route.windowID
                    )
                ) else {
                    return nil
                }
                guard verified.childProcessID == resources.handle.childProcessID,
                      verified.attachProof.workspaceID == subscribe.workspaceID,
                      verified.attachProof.panelID == subscribe.panelID,
                      verified.attachProof.sessionID == route.sessionID,
                      verified.attachProof.windowID == route.windowID else {
                    throw TmuxInteractivePTYSessionOwnerError.attachProofMismatch
                }
                try drainPreProofBytes(resources)
                guard resources.preProofBytes.count <= maximumAuthoritativeStartBytes else {
                    throw TmuxInteractivePTYSessionOwnerError
                        .authoritativeStartBufferOverflow(
                            limit: maximumAuthoritativeStartBytes
                        )
                }
                let provedAtUptimeNanoseconds = uptimeNanoseconds()
                if resources.preProofBytes.isEmpty == false {
                    resources.authoritativeStartBytes.append(resources.preProofBytes)
                    resources.lastAuthoritativeOutputUptimeNanoseconds =
                        provedAtUptimeNanoseconds
                }
                resources.preProofBytes.removeAll(keepingCapacity: false)
                resources.verifiedAttach = verified
                resources.authoritativeStartCollectionBeganAtUptimeNanoseconds =
                    provedAtUptimeNanoseconds
                resources.streamingStartupByteCount =
                    resources.authoritativeStartBytes.count
                state = subscribe.startupMode == .streamingReplies
                    ? .settling
                    : .redrawing
                return verified
            } catch {
                try closeActiveResources(resources)
                throw error
            }
        }
    }

    func sendInput(
        _ input: TmuxInteractiveInput
    ) throws -> TmuxInteractivePTYWriteResult {
        try queue.sync {
            guard state == .live,
                  let resources = activeResources else {
                throw TmuxInteractivePTYSessionOwnerError.inputNotEnabled(state)
            }
            return try writeCurrentPTYBytes(
                input.bytes,
                binding: input.binding,
                resources: resources
            )
        }
    }

    func sendTerminalReply(
        _ reply: TmuxInteractiveTerminalReply
    ) throws -> TmuxInteractivePTYWriteResult {
        try queue.sync {
            guard state == .settling || state == .live,
                  let resources = activeResources else {
                throw TmuxInteractivePTYSessionOwnerError
                    .terminalReplyNotEnabled(state)
            }
            return try writeCurrentPTYBytes(
                reply.bytes,
                binding: reply.binding,
                resources: resources
            )
        }
    }

    func applyResize(_ resize: TmuxInteractiveResize) throws -> Bool {
        try queue.sync {
            guard state == .live,
                  let resizeGate = activeResources?.resizeGate else {
                throw TmuxInteractivePTYSessionOwnerError.invalidState(state)
            }
            return try resizeGate.apply(resize)
        }
    }

    func pollAuthoritativeStart() throws -> TmuxInteractiveAuthoritativeStart? {
        try queue.sync {
            guard state == .redrawing,
                  let resources = activeResources,
                  let verifiedAttach = resources.verifiedAttach else {
                throw TmuxInteractivePTYSessionOwnerError.invalidState(state)
            }
            do {
                var receivedBytesThisPoll = false
                while true {
                    switch try controller.read(
                        masterFileDescriptor: resources.handle.masterFileDescriptor,
                        maximumBytes: 64 * 1_024
                    ) {
                    case .bytes(let bytes):
                        guard bytes.isEmpty == false else {
                            throw TmuxInteractivePTYSessionOwnerError
                                .unexpectedEndBeforeAuthoritativeStart
                        }
                        guard bytes.count <= maximumAuthoritativeStartBytes -
                                resources.authoritativeStartBytes.count else {
                            throw TmuxInteractivePTYSessionOwnerError
                                .authoritativeStartBufferOverflow(
                                    limit: maximumAuthoritativeStartBytes
                                )
                        }
                        resources.authoritativeStartBytes.append(bytes)
                        if resources.didRequestClientRefresh {
                            resources.didObserveOutputAfterRefreshRequest = true
                        }
                        resources.lastAuthoritativeOutputUptimeNanoseconds =
                            uptimeNanoseconds()
                        receivedBytesThisPoll = true
                    case .wouldBlock:
                        guard receivedBytesThisPoll == false else {
                            return nil
                        }
                        if resources.authoritativeStartBytes.isEmpty {
                            if resources.didRequestClientRefresh == false {
                                guard let collectionBeganAtUptimeNanoseconds =
                                        resources
                                            .authoritativeStartCollectionBeganAtUptimeNanoseconds else {
                                    return nil
                                }
                                let currentUptimeNanoseconds = uptimeNanoseconds()
                                guard currentUptimeNanoseconds >=
                                        collectionBeganAtUptimeNanoseconds,
                                      currentUptimeNanoseconds -
                                        collectionBeganAtUptimeNanoseconds >=
                                        authoritativeStartQuiescenceNanoseconds else {
                                    return nil
                                }
                                try clientRefreshRequester.requestRefresh(
                                    TmuxInteractiveClientRefreshRequest(
                                        socket: resources.request.route.socket,
                                        clientTTY: verifiedAttach.clientTTY
                                    )
                                )
                                resources.didRequestClientRefresh = true
                                resources.clientRefreshRequestedAtUptimeNanoseconds =
                                    currentUptimeNanoseconds
                                return nil
                            }
                            guard let requestedAtUptimeNanoseconds =
                                    resources.clientRefreshRequestedAtUptimeNanoseconds else {
                                return nil
                            }
                            let currentUptimeNanoseconds = uptimeNanoseconds()
                            guard currentUptimeNanoseconds >=
                                    requestedAtUptimeNanoseconds,
                                  currentUptimeNanoseconds -
                                    requestedAtUptimeNanoseconds >=
                                    clientRefreshTimeoutNanoseconds else {
                                return nil
                            }
                            throw TmuxInteractivePTYSessionOwnerError
                                .authoritativeStartTimedOut
                        }
                        guard let lastOutputUptimeNanoseconds =
                                resources.lastAuthoritativeOutputUptimeNanoseconds else {
                            return nil
                        }
                        let currentUptimeNanoseconds = uptimeNanoseconds()
                        let requiredQuiescenceNanoseconds =
                            resources.didRequestClientRefresh
                                ? postRefreshQuiescenceNanoseconds
                                : authoritativeStartQuiescenceNanoseconds
                        guard currentUptimeNanoseconds >= lastOutputUptimeNanoseconds,
                              currentUptimeNanoseconds - lastOutputUptimeNanoseconds >=
                                requiredQuiescenceNanoseconds else {
                            return nil
                        }
                        if requiresPostRefreshObservation,
                           resources.didRequestClientRefresh == false {
                            try clientRefreshRequester.requestRefresh(
                                TmuxInteractiveClientRefreshRequest(
                                    socket: resources.request.route.socket,
                                    clientTTY: verifiedAttach.clientTTY
                                )
                            )
                            resources.didRequestClientRefresh = true
                            resources.clientRefreshRequestedAtUptimeNanoseconds =
                                currentUptimeNanoseconds
                            return nil
                        }
                        if requiresPostRefreshObservation,
                           resources.didObserveOutputAfterRefreshRequest == false {
                            guard let requestedAtUptimeNanoseconds =
                                    resources.clientRefreshRequestedAtUptimeNanoseconds else {
                                return nil
                            }
                            guard currentUptimeNanoseconds >=
                                    requestedAtUptimeNanoseconds,
                                  currentUptimeNanoseconds -
                                    requestedAtUptimeNanoseconds >=
                                    clientRefreshTimeoutNanoseconds else {
                                return nil
                            }
                            throw TmuxInteractivePTYSessionOwnerError
                                .authoritativeStartTimedOut
                        }
                        let subscribe = resources.request.subscribe
                        let start = TmuxInteractiveAuthoritativeStart(
                            binding: subscribe.binding,
                            attachProof: verifiedAttach.attachProof,
                            viewport: subscribe.viewport,
                            initialBytes: resources.authoritativeStartBytes
                        )
                        resources.authoritativeStartBytes.removeAll(keepingCapacity: false)
                        transitionToLive(resources)
                        return start
                    case .endOfFile:
                        throw TmuxInteractivePTYSessionOwnerError
                            .unexpectedEndBeforeAuthoritativeStart
                    }
                }
            } catch {
                try closeActiveResources(resources)
                throw error
            }
        }
    }

    func pollLiveOutput() throws -> TmuxInteractivePTYSessionLivePollResult {
        try queue.sync {
            guard state == .live,
                  let resources = activeResources else {
                throw TmuxInteractivePTYSessionOwnerError.invalidState(state)
            }
            let readResult: TmuxInteractivePTYReadResult
            do {
                readResult = try controller.read(
                    masterFileDescriptor: resources.handle.masterFileDescriptor,
                    maximumBytes: 64 * 1_024
                )
            } catch {
                try closeActiveResources(resources)
                throw error
            }

            switch readResult {
            case .bytes(let bytes):
                guard bytes.isEmpty == false else {
                    return .wouldBlock
                }
                let chunk = TmuxInteractiveOutputChunk(
                    binding: resources.request.subscribe.binding,
                    sequence: try takeNextOutputSequence(resources),
                    bytes: bytes
                )
                return .output(chunk)
            case .wouldBlock:
                return .wouldBlock
            case .endOfFile:
                let binding = resources.request.subscribe.binding
                try closeActiveResources(resources)
                return .terminal(
                    TmuxInteractiveStateChange(
                        binding: binding,
                        state: .detached,
                        message: nil
                    )
                )
            }
        }
    }

    func pollStreamingStartup() throws -> TmuxInteractivePTYSessionStartupPollResult {
        try queue.sync {
            guard state == .settling,
                  let resources = activeResources,
                  let verifiedAttach = resources.verifiedAttach else {
                throw TmuxInteractivePTYSessionOwnerError.invalidState(state)
            }

            if resources.didPublishStreamingAttached == false {
                let attached = TmuxInteractiveAttached(
                    binding: resources.request.subscribe.binding,
                    attachProof: verifiedAttach.attachProof,
                    viewport: resources.request.subscribe.viewport,
                    initialBytes: resources.authoritativeStartBytes,
                    sequence: try takeNextOutputSequence(resources)
                )
                resources.authoritativeStartBytes.removeAll(keepingCapacity: false)
                resources.didPublishStreamingAttached = true
                return .attached(attached)
            }

            if resources.shouldPublishStreamingReady {
                return try publishStreamingReady(resources)
            }

            let readResult: TmuxInteractivePTYReadResult
            do {
                readResult = try controller.read(
                    masterFileDescriptor: resources.handle.masterFileDescriptor,
                    maximumBytes: 64 * 1_024
                )
            } catch {
                try closeActiveResources(resources)
                throw error
            }

            switch readResult {
            case .bytes(let bytes):
                guard bytes.isEmpty == false else {
                    try closeActiveResources(resources)
                    throw TmuxInteractivePTYSessionOwnerError
                        .unexpectedEndBeforeAuthoritativeStart
                }
                guard bytes.count <= maximumAuthoritativeStartBytes -
                        resources.streamingStartupByteCount else {
                    try closeActiveResources(resources)
                    throw TmuxInteractivePTYSessionOwnerError
                        .authoritativeStartBufferOverflow(
                            limit: maximumAuthoritativeStartBytes
                        )
                }
                resources.streamingStartupByteCount += bytes.count
                resources.lastAuthoritativeOutputUptimeNanoseconds =
                    uptimeNanoseconds()
                if hasReachedStreamingStartupDeadline(resources) {
                    resources.shouldPublishStreamingReady = true
                }
                return .output(
                    TmuxInteractiveOutputChunk(
                        binding: resources.request.subscribe.binding,
                        sequence: try takeNextOutputSequence(resources),
                        bytes: bytes
                    )
                )
            case .wouldBlock:
                let quietBeganAtUptimeNanoseconds =
                    resources.lastAuthoritativeOutputUptimeNanoseconds
                    ?? resources.authoritativeStartCollectionBeganAtUptimeNanoseconds
                guard let quietBeganAtUptimeNanoseconds else {
                    return .wouldBlock
                }
                let currentUptimeNanoseconds = uptimeNanoseconds()
                let isQuiet = currentUptimeNanoseconds >=
                    quietBeganAtUptimeNanoseconds &&
                    currentUptimeNanoseconds - quietBeganAtUptimeNanoseconds >=
                        authoritativeStartQuiescenceNanoseconds
                guard isQuiet || hasReachedStreamingStartupDeadline(
                    resources,
                    currentUptimeNanoseconds: currentUptimeNanoseconds
                ) else {
                    return .wouldBlock
                }
                return try publishStreamingReady(resources)
            case .endOfFile:
                try closeActiveResources(resources)
                throw TmuxInteractivePTYSessionOwnerError
                    .unexpectedEndBeforeAuthoritativeStart
            }
        }
    }

    private func hasReachedStreamingStartupDeadline(
        _ resources: ActiveResources,
        currentUptimeNanoseconds: UInt64? = nil
    ) -> Bool {
        guard let beganAt = resources
            .authoritativeStartCollectionBeganAtUptimeNanoseconds else {
            return false
        }
        let current = currentUptimeNanoseconds ?? uptimeNanoseconds()
        return current >= beganAt &&
            current - beganAt >= streamingStartupDeadlineNanoseconds
    }

    private func publishStreamingReady(
        _ resources: ActiveResources
    ) throws -> TmuxInteractivePTYSessionStartupPollResult {
        let ready = TmuxInteractiveReady(
            binding: resources.request.subscribe.binding,
            sequence: try takeNextOutputSequence(resources)
        )
        transitionToLive(resources)
        return .ready(ready)
    }

    func close() throws {
        try queue.sync {
            if state == .closed {
                return
            }
            guard let resources = activeResources else {
                guard state == .idle else {
                    throw TmuxInteractivePTYSessionOwnerError.invalidState(state)
                }
                state = .closed
                return
            }

            try closeActiveResources(resources)
        }
    }

    private func drainPreProofBytes(_ resources: ActiveResources) throws {
        while true {
            switch try controller.read(
                masterFileDescriptor: resources.handle.masterFileDescriptor,
                maximumBytes: 64 * 1_024
            ) {
            case .bytes(let bytes):
                guard bytes.isEmpty == false else {
                    throw TmuxInteractivePTYSessionOwnerError.unexpectedEndBeforeProof
                }
                guard bytes.count <= maximumPreProofBytes - resources.preProofBytes.count else {
                    throw TmuxInteractivePTYSessionOwnerError.preProofBufferOverflow(
                        limit: maximumPreProofBytes
                    )
                }
                resources.preProofBytes.append(bytes)
            case .wouldBlock:
                return
            case .endOfFile:
                throw TmuxInteractivePTYSessionOwnerError.unexpectedEndBeforeProof
            }
        }
    }

    private func writeCurrentPTYBytes(
        _ bytes: Data,
        binding: TmuxInteractiveSubscriptionBinding,
        resources: ActiveResources
    ) throws -> TmuxInteractivePTYWriteResult {
        guard binding == resources.request.subscribe.binding else {
            throw TmuxInteractivePTYSessionOwnerError.bindingMismatch
        }
        return try controller.write(
            bytes,
            masterFileDescriptor: resources.handle.masterFileDescriptor
        )
    }

    private func transitionToLive(_ resources: ActiveResources) {
        resources.resizeGate = TmuxInteractivePTYResizeGate(
            binding: resources.request.subscribe.binding,
            masterFileDescriptor: resources.handle.masterFileDescriptor,
            initialSize: resources.initialSize,
            controller: controller
        )
        state = .live
    }

    private func takeNextOutputSequence(
        _ resources: ActiveResources
    ) throws -> UInt64 {
        guard resources.nextOutputSequence < UInt64.max else {
            try closeActiveResources(resources)
            throw TmuxInteractivePTYSessionOwnerError.outputSequenceExhausted
        }
        let sequence = resources.nextOutputSequence
        resources.nextOutputSequence += 1
        return sequence
    }

    private func closeActiveResources(_ resources: ActiveResources) throws {
        state = .closing
        resources.resizeGate?.retire()
        if resources.didCloseMaster == false {
            try controller.close(
                masterFileDescriptor: resources.handle.masterFileDescriptor
            )
            resources.didCloseMaster = true
        }
        guard try controller.reap(
            childProcessID: resources.handle.childProcessID,
            blocking: true
        ) != nil else {
            throw TmuxInteractivePTYSessionOwnerError.childDidNotExit
        }
        admissionStore.releaseInteractiveLease(
            token: resources.leaseToken,
            sessionKey: resources.sessionKey
        )
        activeResources = nil
        state = .closed
    }

    private static func validatedInitialSize(
        _ request: TmuxInteractivePTYSessionStartRequest
    ) -> TmuxInteractivePTYSize? {
        let subscribe = request.subscribe
        let route = request.route
        guard subscribe.workspaceID.isEmpty == false,
              subscribe.panelID.isEmpty == false,
              subscribe.binding.subscriptionID.isEmpty == false,
              subscribe.workspaceID == route.workspaceID,
              subscribe.panelID == route.panelID,
              request.tmuxExecutablePath.first == "/",
              subscribe.viewport.columns > 0,
              subscribe.viewport.rows > 0,
              subscribe.viewport.columns <= Int(UInt16.max),
              subscribe.viewport.rows <= Int(UInt16.max) else {
            return nil
        }
        return TmuxInteractivePTYSize(
            columns: UInt16(subscribe.viewport.columns),
            rows: UInt16(subscribe.viewport.rows)
        )
    }
}
