import Foundation

enum TmuxInteractivePTYConnectionSessionPollResult: Equatable, Sendable {
    case wouldBlock
    case start(TmuxInteractiveAuthoritativeStart)
    case output(TmuxInteractiveOutputChunk)
    case terminal(TmuxInteractiveStateChange)
    case finished
}

enum TmuxInteractivePTYConnectionSessionError: Error, Equatable {
    case invalidOwnerState(TmuxInteractivePTYSessionLifecycleState)
}

final class TmuxInteractivePTYConnectionSession: @unchecked Sendable {
    let binding: TmuxInteractiveSubscriptionBinding

    private let queue = DispatchQueue(
        label: "com.tidey.remote-bridge.tmux-interactive-pty-connection-session"
    )
    private let owner: TmuxInteractivePTYSessionOwner
    private var didFinish = false

    init(
        binding: TmuxInteractiveSubscriptionBinding,
        owner: TmuxInteractivePTYSessionOwner
    ) {
        self.binding = binding
        self.owner = owner
    }

    func poll() throws -> TmuxInteractivePTYConnectionSessionPollResult {
        try queue.sync {
            guard didFinish == false else {
                return .finished
            }
            switch owner.lifecycleState {
            case .proving:
                _ = try owner.pollAttachProof()
                return .wouldBlock
            case .redrawing:
                guard let start = try owner.pollAuthoritativeStart() else {
                    return .wouldBlock
                }
                return .start(start)
            case .settling:
                return .wouldBlock
            case .live:
                switch try owner.pollLiveOutput() {
                case .output(let output):
                    return .output(output)
                case .wouldBlock:
                    return .wouldBlock
                case .terminal(let state):
                    didFinish = true
                    return .terminal(state)
                }
            case .closed:
                didFinish = true
                return .terminal(
                    TmuxInteractiveStateChange(
                        binding: binding,
                        state: .closed,
                        message: nil
                    )
                )
            case .closing:
                return .wouldBlock
            case .idle, .reserving, .spawning:
                throw TmuxInteractivePTYConnectionSessionError.invalidOwnerState(
                    owner.lifecycleState
                )
            }
        }
    }

    func sendInput(
        _ input: TmuxInteractiveInput
    ) throws -> TmuxInteractivePTYWriteResult {
        try owner.sendInput(input)
    }

    func applyResize(_ resize: TmuxInteractiveResize) throws -> Bool {
        try owner.applyResize(resize)
    }

    func close() throws {
        try queue.sync {
            try owner.close()
            didFinish = true
        }
    }
}
