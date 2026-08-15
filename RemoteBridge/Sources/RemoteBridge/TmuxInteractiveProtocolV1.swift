import Foundation

enum TmuxInteractiveProtocolV1 {
    static let capability = "tmux_interactive_v1"
    static let subscribeAction = "subscribe_tmux_interactive"
    static let inputAction = "tmux_interactive_input"
    static let replyAction = "tmux_interactive_reply"
    static let resizeAction = "tmux_interactive_resize"
    static let unsubscribeAction = "unsubscribe_tmux_interactive"
    static let startEventType = "tmux_interactive_start"
    static let attachedEventType = "tmux_interactive_attached"
    static let outputEventType = "tmux_interactive_output"
    static let readyEventType = "tmux_interactive_ready"
    static let stateEventType = "tmux_interactive_state"
}

enum TmuxInteractiveStartupMode: String, Equatable, Sendable {
    case legacy
    case streamingReplies = "streaming_replies_v1"
}

struct TmuxInteractiveSubscriptionBinding: Equatable, Sendable {
    let subscriptionID: String
    let generation: UInt64
}

struct TmuxInteractiveViewport: Equatable, Sendable {
    let columns: Int
    let rows: Int
}

struct TmuxInteractiveSubscribe: Equatable, Sendable {
    let workspaceID: String
    let panelID: String
    let binding: TmuxInteractiveSubscriptionBinding
    let viewport: TmuxInteractiveViewport
    let startupMode: TmuxInteractiveStartupMode

    init(
        workspaceID: String,
        panelID: String,
        binding: TmuxInteractiveSubscriptionBinding,
        viewport: TmuxInteractiveViewport,
        startupMode: TmuxInteractiveStartupMode = .legacy
    ) {
        self.workspaceID = workspaceID
        self.panelID = panelID
        self.binding = binding
        self.viewport = viewport
        self.startupMode = startupMode
    }
}

struct TmuxInteractiveInput: Equatable, Sendable {
    let binding: TmuxInteractiveSubscriptionBinding
    let bytes: Data
}

struct TmuxInteractiveTerminalReply: Equatable, Sendable {
    let binding: TmuxInteractiveSubscriptionBinding
    let bytes: Data
}

struct TmuxInteractiveResize: Equatable, Sendable {
    let binding: TmuxInteractiveSubscriptionBinding
    let viewport: TmuxInteractiveViewport
}

struct TmuxInteractiveUnsubscribe: Equatable, Sendable {
    let binding: TmuxInteractiveSubscriptionBinding
}

struct TmuxInteractiveAttachProof: Equatable, Sendable {
    let workspaceID: String
    let panelID: String
    let sessionID: String
    let windowID: String
    let paneID: String
}

struct TmuxInteractiveBootstrapPhase: Equatable, Sendable {
    let viewport: TmuxInteractiveViewport
    let bytes: Data
}

struct TmuxInteractiveAuthoritativeStart: Equatable, Sendable {
    let binding: TmuxInteractiveSubscriptionBinding
    let attachProof: TmuxInteractiveAttachProof
    let bootstrapPhase: TmuxInteractiveBootstrapPhase?
    let viewport: TmuxInteractiveViewport
    let initialBytes: Data

    init(
        binding: TmuxInteractiveSubscriptionBinding,
        attachProof: TmuxInteractiveAttachProof,
        bootstrapPhase: TmuxInteractiveBootstrapPhase? = nil,
        viewport: TmuxInteractiveViewport,
        initialBytes: Data
    ) {
        self.binding = binding
        self.attachProof = attachProof
        self.bootstrapPhase = bootstrapPhase
        self.viewport = viewport
        self.initialBytes = initialBytes
    }
}

struct TmuxInteractiveAttached: Equatable, Sendable {
    let binding: TmuxInteractiveSubscriptionBinding
    let attachProof: TmuxInteractiveAttachProof
    let viewport: TmuxInteractiveViewport
    let initialBytes: Data
    let sequence: UInt64
}

struct TmuxInteractiveOutputChunk: Equatable, Sendable {
    let binding: TmuxInteractiveSubscriptionBinding
    let sequence: UInt64
    let bytes: Data
}

struct TmuxInteractiveReady: Equatable, Sendable {
    let binding: TmuxInteractiveSubscriptionBinding
    let sequence: UInt64
}

enum TmuxInteractiveTerminalState: String, Equatable, Sendable {
    case detached
    case failed
    case closed
}

struct TmuxInteractiveStateChange: Equatable, Sendable {
    let binding: TmuxInteractiveSubscriptionBinding
    let state: TmuxInteractiveTerminalState
    let message: String?
}
