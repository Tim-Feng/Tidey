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
    case live
    case closing
    case closed
}

enum TmuxInteractivePTYSessionOwnerError: Error, Equatable {
    case invalidRequest
    case admissionConflict
    case invalidState(TmuxInteractivePTYSessionLifecycleState)
    case inputNotEnabled(TmuxInteractivePTYSessionLifecycleState)
    case bindingMismatch
    case unexpectedEndBeforeProof
    case preProofBufferOverflow(limit: Int)
    case attachProofMismatch
    case unexpectedEndBeforeAuthoritativeStart
    case authoritativeStartBufferOverflow(limit: Int)
    case outputSequenceExhausted
    case childDidNotExit
}

enum TmuxInteractivePTYSessionLivePollResult: Equatable, Sendable {
    case output(TmuxInteractiveOutputChunk)
    case wouldBlock
    case terminal(TmuxInteractiveStateChange)
}

final class TmuxInteractivePTYSessionOwner: @unchecked Sendable {
    static let productionAuthoritativeStartQuiescenceNanoseconds: UInt64 =
        150_000_000
    static let productionPostProofRedrawDelayNanoseconds: UInt64 =
        150_000_000

    private final class ActiveResources {
        let handle: TmuxInteractivePTYHandle
        let sessionKey: OrdinaryTmuxSessionKey
        let leaseToken: OrdinaryTmuxInteractiveLeaseToken
        let request: TmuxInteractivePTYSessionStartRequest
        let initialSize: TmuxInteractivePTYSize
        var preProofBytes = Data()
        var verifiedAttach: TmuxInteractiveVerifiedAttach?
        var provedAtUptimeNanoseconds: UInt64?
        var didCaptureProvedAttachPrefix = false
        var didRequestRedraw = false
        var didRequestVerificationRedraw = false
        var didReceiveVerificationRedrawOutput = false
        var authoritativeStartBytes = Data()
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
    private let paneRedrawRequester: TmuxInteractivePaneRedrawRequesting
    private let maximumPreProofBytes: Int
    private let maximumAuthoritativeStartBytes: Int
    private let postProofRedrawDelayNanoseconds: UInt64
    private let authoritativeStartQuiescenceNanoseconds: UInt64
    private let requiresVerificationRedraw: Bool
    private let uptimeNanoseconds: @Sendable () -> UInt64
    private var state = TmuxInteractivePTYSessionLifecycleState.idle
    private var activeResources: ActiveResources?

    init(
        admissionStore: OrdinaryTmuxInputSubmissionStore,
        controller: TmuxInteractivePTYControlling,
        attachProver: TmuxInteractiveAttachProving = TmuxInteractiveAttachProver(),
        clientRefreshRequester: TmuxInteractiveClientRefreshRequesting =
            DisabledTmuxInteractiveClientRefreshRequester(),
        paneRedrawRequester: TmuxInteractivePaneRedrawRequesting =
            DisabledTmuxInteractivePaneRedrawRequester(),
        maximumPreProofBytes: Int = 1_024 * 1_024,
        maximumAuthoritativeStartBytes: Int = 1_024 * 1_024,
        postProofRedrawDelayNanoseconds: UInt64 = 0,
        authoritativeStartQuiescenceNanoseconds: UInt64 = 0,
        requiresVerificationRedraw: Bool = false,
        uptimeNanoseconds: @escaping @Sendable () -> UInt64 = {
            DispatchTime.now().uptimeNanoseconds
        }
    ) {
        self.admissionStore = admissionStore
        self.controller = controller
        self.attachProver = attachProver
        self.clientRefreshRequester = clientRefreshRequester
        self.paneRedrawRequester = paneRedrawRequester
        self.maximumPreProofBytes = max(1, maximumPreProofBytes)
        self.maximumAuthoritativeStartBytes = max(1, maximumAuthoritativeStartBytes)
        self.postProofRedrawDelayNanoseconds = postProofRedrawDelayNanoseconds
        self.authoritativeStartQuiescenceNanoseconds =
            authoritativeStartQuiescenceNanoseconds
        self.requiresVerificationRedraw = requiresVerificationRedraw
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
                guard resources.preProofBytes.count <=
                        maximumAuthoritativeStartBytes else {
                    throw TmuxInteractivePTYSessionOwnerError
                        .authoritativeStartBufferOverflow(
                            limit: maximumAuthoritativeStartBytes
                        )
                }
                resources.authoritativeStartBytes.append(resources.preProofBytes)
                resources.preProofBytes.removeAll(keepingCapacity: false)
                resources.verifiedAttach = verified
                let provedAtUptimeNanoseconds = uptimeNanoseconds()
                resources.provedAtUptimeNanoseconds = provedAtUptimeNanoseconds
                if resources.authoritativeStartBytes.isEmpty == false {
                    resources.didCaptureProvedAttachPrefix = true
                    resources.lastAuthoritativeOutputUptimeNanoseconds =
                        provedAtUptimeNanoseconds
                }
                state = .redrawing
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
            guard input.binding == resources.request.subscribe.binding else {
                throw TmuxInteractivePTYSessionOwnerError.bindingMismatch
            }
            return try controller.write(
                input.bytes,
                masterFileDescriptor: resources.handle.masterFileDescriptor
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
                if resources.didCaptureProvedAttachPrefix == false,
                   resources.didRequestRedraw == false {
                    guard let provedAtUptimeNanoseconds =
                            resources.provedAtUptimeNanoseconds else {
                        return nil
                    }
                    let currentUptimeNanoseconds = uptimeNanoseconds()
                    guard currentUptimeNanoseconds >= provedAtUptimeNanoseconds,
                          currentUptimeNanoseconds - provedAtUptimeNanoseconds >=
                            postProofRedrawDelayNanoseconds else {
                        return nil
                    }
                    try controller.resize(
                        masterFileDescriptor: resources.handle.masterFileDescriptor,
                        to: resources.initialSize
                    )
                    try paneRedrawRequester.requestRedraw(
                        TmuxInteractivePaneRedrawRequest(
                            socket: resources.request.route.socket,
                            paneID: verifiedAttach.attachProof.paneID
                        )
                    )
                    resources.didRequestRedraw = true
                }

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
                        if resources.didRequestVerificationRedraw {
                            resources.didReceiveVerificationRedrawOutput = true
                        }
                        resources.lastAuthoritativeOutputUptimeNanoseconds =
                            uptimeNanoseconds()
                        receivedBytesThisPoll = true
                    case .wouldBlock:
                        guard receivedBytesThisPoll == false,
                              resources.authoritativeStartBytes.isEmpty == false else {
                            return nil
                        }
                        guard let lastOutputUptimeNanoseconds =
                                resources.lastAuthoritativeOutputUptimeNanoseconds else {
                            return nil
                        }
                        let currentUptimeNanoseconds = uptimeNanoseconds()
                        guard currentUptimeNanoseconds >= lastOutputUptimeNanoseconds,
                              currentUptimeNanoseconds - lastOutputUptimeNanoseconds >=
                                authoritativeStartQuiescenceNanoseconds else {
                            return nil
                        }
                        if requiresVerificationRedraw,
                           resources.didCaptureProvedAttachPrefix == false,
                           resources.didRequestVerificationRedraw == false {
                            try paneRedrawRequester.requestRedraw(
                                TmuxInteractivePaneRedrawRequest(
                                    socket: resources.request.route.socket,
                                    paneID: verifiedAttach.attachProof.paneID
                                )
                            )
                            resources.didRequestVerificationRedraw = true
                            resources.lastAuthoritativeOutputUptimeNanoseconds = nil
                            return nil
                        }
                        guard resources.didCaptureProvedAttachPrefix
                                || requiresVerificationRedraw == false
                                || resources.didReceiveVerificationRedrawOutput else {
                            return nil
                        }
                        let subscribe = resources.request.subscribe
                        let start = TmuxInteractiveAuthoritativeStart(
                            binding: subscribe.binding,
                            attachProof: verifiedAttach.attachProof,
                            viewport: subscribe.viewport,
                            initialBytes: resources.authoritativeStartBytes
                        )
                        resources.authoritativeStartBytes.removeAll(keepingCapacity: false)
                        resources.resizeGate = TmuxInteractivePTYResizeGate(
                            binding: subscribe.binding,
                            masterFileDescriptor: resources.handle.masterFileDescriptor,
                            initialSize: resources.initialSize,
                            controller: controller
                        )
                        state = .live
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
                guard resources.nextOutputSequence < UInt64.max else {
                    try closeActiveResources(resources)
                    throw TmuxInteractivePTYSessionOwnerError.outputSequenceExhausted
                }
                let chunk = TmuxInteractiveOutputChunk(
                    binding: resources.request.subscribe.binding,
                    sequence: resources.nextOutputSequence,
                    bytes: bytes
                )
                resources.nextOutputSequence += 1
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
