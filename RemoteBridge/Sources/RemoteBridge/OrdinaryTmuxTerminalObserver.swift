import Foundation

protocol OrdinaryTmuxControlModeProcessManaging: AnyObject, Sendable {
    func addSubscription(name: String, paneID: String) throws
    func removeSubscription(name: String) throws
    func detachAndWait()
}

typealias OrdinaryTmuxControlModeProcessFactory = @Sendable (
    _ socket: OrdinaryTmuxSocketSelector,
    _ sessionID: String,
    _ onOutput: @escaping @Sendable (Data) -> Void,
    _ onExit: @escaping @Sendable (Error?) -> Void
) throws -> OrdinaryTmuxControlModeProcessManaging

final class OrdinaryTmuxManagedControlModeProcess: OrdinaryTmuxControlModeProcessManaging, @unchecked Sendable {
    typealias LineWriter = @Sendable (String) throws -> Void
    typealias ExitWaiter = @Sendable () -> Void

    private let writeLine: LineWriter
    private let waitForExit: ExitWaiter
    private let lock = NSLock()
    private var didDetach = false

    init(writeLine: @escaping LineWriter,
         waitForExit: @escaping ExitWaiter) {
        self.writeLine = writeLine
        self.waitForExit = waitForExit
    }

    static func launchArguments(
        socket: OrdinaryTmuxSocketSelector,
        sessionID: String
    ) -> [String] {
        OrdinaryTmuxCLIAdapter.arguments(
            for: socket,
            commandArguments: [
                "-f", "/dev/null",
                "-C", "attach-session",
                "-t", sessionID,
                "-f", "read-only,ignore-size,no-output",
            ]
        )
    }

    func addSubscription(name: String, paneID: String) throws {
        guard Self.isSafeName(name), Self.isExactPaneID(paneID) else {
            throw BridgeInternalError.invalidRequest("invalid tmux observer subscription")
        }
        try writeLine(
            "refresh-client -B '\(name):\(paneID):#{pane_id},pane=#{pane_width}x#{pane_height},window=#{window_width}x#{window_height},alternate=#{alternate_on}'"
        )
    }

    func removeSubscription(name: String) throws {
        guard Self.isSafeName(name) else {
            throw BridgeInternalError.invalidRequest("invalid tmux observer subscription")
        }
        try writeLine("refresh-client -B '\(name)'")
    }

    func detachAndWait() {
        lock.lock()
        guard didDetach == false else {
            lock.unlock()
            return
        }
        didDetach = true
        lock.unlock()
        try? writeLine("detach-client")
        waitForExit()
    }

    private static func isSafeName(_ value: String) -> Bool {
        value.isEmpty == false && value.utf8.allSatisfy { byte in
            (byte >= 48 && byte <= 57) ||
                (byte >= 65 && byte <= 90) ||
                (byte >= 97 && byte <= 122) ||
                byte == 45 || byte == 95
        }
    }

    private static func isExactPaneID(_ value: String) -> Bool {
        value.first == "%" &&
            value.dropFirst().isEmpty == false &&
            value.dropFirst().allSatisfy(\.isNumber)
    }
}

struct OrdinaryTmuxTerminalObservationRequest: Sendable {
    let route: OrdinaryTmuxPanelRoute
    let subscriptionID: String
    let expectedFingerprint: OrdinaryTmuxTerminalFingerprintV1
    let onRebootstrapRequired: @Sendable (OrdinaryTmuxTerminalFingerprintV1?) -> Void
}

protocol OrdinaryTmuxTerminalObserverLeasing: AnyObject, Sendable {
    func stop()
}

protocol OrdinaryTmuxTerminalObserving: Sendable {
    func observe(
        _ request: OrdinaryTmuxTerminalObservationRequest
    ) throws -> OrdinaryTmuxTerminalObserverLeasing
}
