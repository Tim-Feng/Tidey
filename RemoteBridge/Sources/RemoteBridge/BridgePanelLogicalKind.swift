enum BridgePanelLogicalKind: String, Sendable {
    case nativeSession = "native_session"
    case ordinaryTmuxWindow = "ordinary_tmux_window"
}

enum BridgeNativeSplitProtocolV1 {
    static let capability = "native_split_sessions_v1"
}
