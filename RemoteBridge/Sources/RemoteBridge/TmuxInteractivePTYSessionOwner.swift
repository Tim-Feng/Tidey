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
    case live
    case closing
    case closed
}

enum TmuxInteractivePTYSessionOwnerError: Error, Equatable {
    case invalidRequest
    case admissionConflict
    case invalidState(TmuxInteractivePTYSessionLifecycleState)
    case childDidNotExit
}

final class TmuxInteractivePTYSessionOwner: @unchecked Sendable {
    private final class ActiveResources {
        let handle: TmuxInteractivePTYHandle
        let sessionKey: OrdinaryTmuxSessionKey
        let leaseToken: OrdinaryTmuxInteractiveLeaseToken
        var didCloseMaster = false

        init(
            handle: TmuxInteractivePTYHandle,
            sessionKey: OrdinaryTmuxSessionKey,
            leaseToken: OrdinaryTmuxInteractiveLeaseToken
        ) {
            self.handle = handle
            self.sessionKey = sessionKey
            self.leaseToken = leaseToken
        }
    }

    private let queue = DispatchQueue(
        label: "com.tidey.remote-bridge.tmux-interactive-pty-session-owner"
    )
    private let admissionStore: OrdinaryTmuxInputSubmissionStore
    private let controller: TmuxInteractivePTYControlling
    private var state = TmuxInteractivePTYSessionLifecycleState.idle
    private var activeResources: ActiveResources?

    init(
        admissionStore: OrdinaryTmuxInputSubmissionStore,
        controller: TmuxInteractivePTYControlling
    ) {
        self.admissionStore = admissionStore
        self.controller = controller
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
                    leaseToken: leaseToken
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

            state = .closing
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
