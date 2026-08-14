import RemoteBridgePTYShim

struct TmuxInteractivePTYSize: Equatable, Sendable {
    let columns: UInt16
    let rows: UInt16
}

struct TmuxInteractivePTYAttachCommand: Equatable, Sendable {
    let tmuxExecutablePath: String
    let socket: OrdinaryTmuxSocketSelector
    let sessionID: String
    let windowID: String
    let initialSize: TmuxInteractivePTYSize
}

struct TmuxInteractivePTYHandle: Equatable, Sendable {
    let masterFileDescriptor: Int32
    let childProcessID: Int32
}

struct TmuxInteractivePTYChildExit: Equatable, Sendable {
    let rawStatus: Int32
}

protocol TmuxInteractivePTYControlling: Sendable {
    func spawn(_ command: TmuxInteractivePTYAttachCommand) throws -> TmuxInteractivePTYHandle
    func resize(masterFileDescriptor: Int32, to size: TmuxInteractivePTYSize) throws
    func close(masterFileDescriptor: Int32) throws
    func reap(childProcessID: Int32, blocking: Bool) throws -> TmuxInteractivePTYChildExit?
}

enum TmuxInteractivePTYShimABI {
    static var version: Int32 {
        tidey_tmux_pty_shim_abi_version()
    }
}
