import Darwin
import Foundation
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

enum TmuxInteractivePTYReadResult: Equatable, Sendable {
    case bytes(Data)
    case wouldBlock
    case endOfFile
}

enum TmuxInteractivePTYWriteResult: Equatable, Sendable {
    case written(Int)
    case wouldBlock
}

protocol TmuxInteractivePTYControlling: Sendable {
    func spawn(_ command: TmuxInteractivePTYAttachCommand) throws -> TmuxInteractivePTYHandle
    func resize(masterFileDescriptor: Int32, to size: TmuxInteractivePTYSize) throws
    func close(masterFileDescriptor: Int32) throws
    func reap(childProcessID: Int32, blocking: Bool) throws -> TmuxInteractivePTYChildExit?
    func read(
        masterFileDescriptor: Int32,
        maximumBytes: Int
    ) throws -> TmuxInteractivePTYReadResult
    func write(
        _ bytes: Data,
        masterFileDescriptor: Int32
    ) throws -> TmuxInteractivePTYWriteResult
}

enum TmuxInteractivePTYControllerError: Error, Equatable {
    case operationFailed(operation: String, code: Int32)
}

struct TmuxInteractivePTYController: TmuxInteractivePTYControlling {
    func spawn(_ command: TmuxInteractivePTYAttachCommand) throws -> TmuxInteractivePTYHandle {
        try command.tmuxExecutablePath.withCString { executablePath in
            try command.sessionID.withCString { sessionID in
                try command.windowID.withCString { windowID in
                    try withSocket(command.socket) { socketKind, socketValue in
                        var request = tidey_tmux_pty_spawn_request(
                            tmux_executable_path: executablePath,
                            socket_kind: socketKind,
                            socket_value: socketValue,
                            session_id: sessionID,
                            window_id: windowID,
                            columns: command.initialSize.columns,
                            rows: command.initialSize.rows
                        )
                        var handle = tidey_tmux_pty_handle(
                            master_file_descriptor: -1,
                            child_process_id: -1
                        )
                        let result = tidey_tmux_pty_spawn(&request, &handle)
                        try requireSuccess(result, operation: "spawn")
                        return TmuxInteractivePTYHandle(
                            masterFileDescriptor: handle.master_file_descriptor,
                            childProcessID: handle.child_process_id
                        )
                    }
                }
            }
        }
    }

    func resize(masterFileDescriptor: Int32, to size: TmuxInteractivePTYSize) throws {
        try requireSuccess(
            tidey_tmux_pty_resize(masterFileDescriptor, size.columns, size.rows),
            operation: "resize"
        )
    }

    func close(masterFileDescriptor: Int32) throws {
        try requireSuccess(
            tidey_tmux_pty_close(masterFileDescriptor),
            operation: "close"
        )
    }

    func reap(childProcessID: Int32, blocking: Bool) throws -> TmuxInteractivePTYChildExit? {
        var rawStatus: Int32 = 0
        var didExit: Int32 = 0
        try requireSuccess(
            tidey_tmux_pty_reap(
                childProcessID,
                blocking ? 1 : 0,
                &rawStatus,
                &didExit
            ),
            operation: "reap"
        )
        guard didExit != 0 else { return nil }
        return TmuxInteractivePTYChildExit(rawStatus: rawStatus)
    }

    func read(
        masterFileDescriptor: Int32,
        maximumBytes: Int
    ) throws -> TmuxInteractivePTYReadResult {
        throw TmuxInteractivePTYControllerError.operationFailed(
            operation: "read",
            code: ENOTSUP
        )
    }

    func write(
        _ bytes: Data,
        masterFileDescriptor: Int32
    ) throws -> TmuxInteractivePTYWriteResult {
        throw TmuxInteractivePTYControllerError.operationFailed(
            operation: "write",
            code: ENOTSUP
        )
    }

    private func withSocket<Result>(
        _ socket: OrdinaryTmuxSocketSelector,
        body: (tidey_tmux_socket_kind, UnsafePointer<CChar>?) throws -> Result
    ) rethrows -> Result {
        switch socket {
        case .defaultSocket:
            return try body(TIDEY_TMUX_SOCKET_DEFAULT, nil)
        case .path(let path):
            return try path.withCString {
                try body(TIDEY_TMUX_SOCKET_PATH, $0)
            }
        case .name(let name):
            return try name.withCString {
                try body(TIDEY_TMUX_SOCKET_NAME, $0)
            }
        }
    }

    private func requireSuccess(_ result: Int32, operation: String) throws {
        guard result == 0 else {
            throw TmuxInteractivePTYControllerError.operationFailed(
                operation: operation,
                code: result
            )
        }
    }
}

enum TmuxInteractivePTYShimABI {
    static var version: Int32 {
        tidey_tmux_pty_shim_abi_version()
    }
}
