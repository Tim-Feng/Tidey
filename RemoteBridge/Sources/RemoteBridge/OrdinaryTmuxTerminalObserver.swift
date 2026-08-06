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

final class OrdinaryTmuxTerminalObserverRegistry: OrdinaryTmuxTerminalObserving, @unchecked Sendable {
    private struct SessionKey: Hashable {
        let socketKey: String
        let sessionID: String
    }

    private struct Consumer {
        let request: OrdinaryTmuxTerminalObservationRequest
    }

    private final class PaneObservation {
        let name: String
        let paneID: String
        let windowID: String
        var consumers = [UUID: Consumer]()

        init(name: String, paneID: String, windowID: String) {
            self.name = name
            self.paneID = paneID
            self.windowID = windowID
        }
    }

    private final class SessionObservation {
        let token: UUID
        let process: OrdinaryTmuxControlModeProcessManaging
        var panes = [String: PaneObservation]()
        var outputBuffer = Data()

        init(token: UUID, process: OrdinaryTmuxControlModeProcessManaging) {
            self.token = token
            self.process = process
        }
    }

    private final class Lease: OrdinaryTmuxTerminalObserverLeasing, @unchecked Sendable {
        private weak var registry: OrdinaryTmuxTerminalObserverRegistry?
        private let key: SessionKey
        private let sessionToken: UUID
        private let paneID: String
        private let consumerID: UUID
        private let lock = NSLock()
        private var didStop = false

        init(registry: OrdinaryTmuxTerminalObserverRegistry,
             key: SessionKey,
             sessionToken: UUID,
             paneID: String,
             consumerID: UUID) {
            self.registry = registry
            self.key = key
            self.sessionToken = sessionToken
            self.paneID = paneID
            self.consumerID = consumerID
        }

        func stop() {
            lock.lock()
            guard didStop == false else {
                lock.unlock()
                return
            }
            didStop = true
            lock.unlock()
            registry?.release(
                key: key,
                sessionToken: sessionToken,
                paneID: paneID,
                consumerID: consumerID
            )
        }
    }

    private let queue: DispatchQueue
    private let callbackQueue: DispatchQueue
    private let makeProcess: OrdinaryTmuxControlModeProcessFactory
    private var sessions = [SessionKey: SessionObservation]()

    init(
        queue: DispatchQueue = DispatchQueue(
            label: "com.tidey.remote-bridge.strict-terminal-observer-registry"
        ),
        callbackQueue: DispatchQueue = DispatchQueue(
            label: "com.tidey.remote-bridge.strict-terminal-observer-callbacks"
        ),
        makeProcess: @escaping OrdinaryTmuxControlModeProcessFactory
    ) {
        self.queue = queue
        self.callbackQueue = callbackQueue
        self.makeProcess = makeProcess
    }

    func observe(
        _ request: OrdinaryTmuxTerminalObservationRequest
    ) throws -> OrdinaryTmuxTerminalObserverLeasing {
        guard request.route.activePaneID == request.expectedFingerprint.paneID else {
            throw BridgeInternalError.invalidResponse
        }

        return try queue.sync {
            let key = SessionKey(
                socketKey: request.route.socket.cacheKey,
                sessionID: request.route.sessionID
            )
            let session: SessionObservation
            if let existing = sessions[key] {
                session = existing
            } else {
                let token = UUID()
                let process = try makeProcess(
                    request.route.socket,
                    request.route.sessionID,
                    { [weak self] data in
                        self?.receiveOutput(data, key: key, sessionToken: token)
                    },
                    { [weak self] error in
                        self?.processExited(error, key: key, sessionToken: token)
                    }
                )
                let created = SessionObservation(token: token, process: process)
                sessions[key] = created
                session = created
            }

            let pane: PaneObservation
            if let existing = session.panes[request.route.activePaneID] {
                guard existing.windowID == request.route.windowID else {
                    throw BridgeInternalError.invalidResponse
                }
                pane = existing
            } else {
                let name = Self.makeSubscriptionName()
                let created = PaneObservation(
                    name: name,
                    paneID: request.route.activePaneID,
                    windowID: request.route.windowID
                )
                session.panes[request.route.activePaneID] = created
                do {
                    try session.process.addSubscription(
                        name: name,
                        paneID: request.route.activePaneID
                    )
                } catch {
                    session.panes.removeValue(forKey: request.route.activePaneID)
                    if session.panes.isEmpty {
                        sessions.removeValue(forKey: key)
                        session.process.detachAndWait()
                    }
                    throw error
                }
                pane = created
            }

            let consumerID = UUID()
            pane.consumers[consumerID] = Consumer(request: request)
            return Lease(
                registry: self,
                key: key,
                sessionToken: session.token,
                paneID: pane.paneID,
                consumerID: consumerID
            )
        }
    }

    private func release(
        key: SessionKey,
        sessionToken: UUID,
        paneID: String,
        consumerID: UUID
    ) {
        var processToDetach: OrdinaryTmuxControlModeProcessManaging?
        queue.sync {
            guard let session = sessions[key],
                  session.token == sessionToken,
                  let pane = session.panes[paneID],
                  pane.consumers.removeValue(forKey: consumerID) != nil else {
                return
            }
            if pane.consumers.isEmpty {
                try? session.process.removeSubscription(name: pane.name)
                session.panes.removeValue(forKey: paneID)
            }
            if session.panes.isEmpty {
                sessions.removeValue(forKey: key)
                processToDetach = session.process
            }
        }
        processToDetach?.detachAndWait()
    }

    private func receiveOutput(
        _ data: Data,
        key: SessionKey,
        sessionToken: UUID
    ) {
        queue.async {
            guard let session = self.sessions[key],
                  session.token == sessionToken else {
                return
            }
            session.outputBuffer.append(data)
        }
    }

    private func processExited(
        _ error: Error?,
        key: SessionKey,
        sessionToken: UUID
    ) {
        queue.async {
            guard let session = self.sessions[key],
                  session.token == sessionToken else {
                return
            }
            self.sessions.removeValue(forKey: key)
            let callbacks = session.panes.values.flatMap { pane in
                pane.consumers.values.map { $0.request.onRebootstrapRequired }
            }
            self.callbackQueue.async {
                for callback in callbacks {
                    callback(nil)
                }
            }
        }
    }

    private static func makeSubscriptionName() -> String {
        "tidey-" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
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
