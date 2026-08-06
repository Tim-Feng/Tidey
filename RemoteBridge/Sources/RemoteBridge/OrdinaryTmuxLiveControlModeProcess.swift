import Foundation

final class OrdinaryTmuxLiveControlModeProcess: OrdinaryTmuxControlModeProcessManaging, @unchecked Sendable {
    private let runtime: Runtime
    private let commands: OrdinaryTmuxManagedControlModeProcess

    private init(runtime: Runtime) {
        self.runtime = runtime
        self.commands = OrdinaryTmuxManagedControlModeProcess(
            writeLine: { try runtime.writeLine($0) },
            waitForExit: { runtime.waitForExitOrTerminate() }
        )
    }

    static func factory(
        executablePath: String? = TmuxStateResolver.discoverTmuxBinaryPath(),
        subscriptionActivationTimeout: TimeInterval = 2,
        detachTimeout: TimeInterval = 2
    ) -> OrdinaryTmuxControlModeProcessFactory {
        { socket, sessionID, onOutput, onExit in
            guard let executablePath else {
                throw NSError(
                    domain: "OrdinaryTmuxLiveControlModeProcess",
                    code: 127,
                    userInfo: [NSLocalizedDescriptionKey: "tmux not found"]
                )
            }
            let runtime = Runtime(
                executablePath: executablePath,
                arguments: OrdinaryTmuxManagedControlModeProcess.launchArguments(
                    socket: socket,
                    sessionID: sessionID
                ),
                subscriptionActivationTimeout: subscriptionActivationTimeout,
                detachTimeout: detachTimeout,
                onOutput: onOutput,
                onExit: onExit
            )
            try runtime.launch()
            return OrdinaryTmuxLiveControlModeProcess(runtime: runtime)
        }
    }

    func addSubscription(name: String, paneID: String) throws {
        try runtime.prepareSubscriptionActivation(name: name)
        do {
            try commands.addSubscription(name: name, paneID: paneID)
            try runtime.waitForSubscriptionActivation(name: name)
        } catch {
            runtime.cancelSubscriptionActivation(name: name)
            throw error
        }
    }

    func removeSubscription(name: String) throws {
        try commands.removeSubscription(name: name)
    }

    func detachAndWait() {
        commands.detachAndWait()
    }

    private final class Runtime: @unchecked Sendable {
        private final class DataAccumulator: @unchecked Sendable {
            private let lock = NSLock()
            private var storage = Data()

            func append(_ data: Data) {
                lock.lock()
                if storage.count < 64 * 1024 {
                    storage.append(data.prefix(64 * 1024 - storage.count))
                }
                lock.unlock()
            }

            var value: Data {
                lock.lock()
                defer { lock.unlock() }
                return storage
            }
        }

        private let process = Process()
        private let inputPipe = Pipe()
        private let outputPipe = Pipe()
        private let errorPipe = Pipe()
        private let writeQueue = DispatchQueue(
            label: "com.tidey.remote-bridge.tmux-control-process-input"
        )
        private let readerGroup = DispatchGroup()
        private let terminationGroup = DispatchGroup()
        private let stateLock = NSLock()
        private let subscriptionActivationTimeout: TimeInterval
        private let detachTimeout: TimeInterval
        private let onOutput: @Sendable (Data) -> Void
        private let onExit: @Sendable (Error?) -> Void
        private let errorOutput = DataAccumulator()
        private let acknowledgementParser = OrdinaryTmuxControlModeEventParser()
        private var pendingActivations = [String: DispatchSemaphore]()
        private var activatedNames = Set<String>()
        private var isTerminated = false
        private var didFinishTermination = false

        init(
            executablePath: String,
            arguments: [String],
            subscriptionActivationTimeout: TimeInterval,
            detachTimeout: TimeInterval,
            onOutput: @escaping @Sendable (Data) -> Void,
            onExit: @escaping @Sendable (Error?) -> Void
        ) {
            process.executableURL = URL(fileURLWithPath: executablePath)
            process.arguments = arguments
            var environment = ProcessInfo.processInfo.environment
            environment["LC_CTYPE"] = "UTF-8"
            environment["LANG"] = "en_US.UTF-8"
            process.environment = environment
            process.standardInput = inputPipe
            process.standardOutput = outputPipe
            process.standardError = errorPipe
            self.subscriptionActivationTimeout = subscriptionActivationTimeout
            self.detachTimeout = detachTimeout
            self.onOutput = onOutput
            self.onExit = onExit
            terminationGroup.enter()
        }

        func launch() throws {
            readerGroup.enter()
            readerGroup.enter()
            process.terminationHandler = { [weak self] process in
                self?.processDidTerminate(process)
            }
            do {
                try process.run()
            } catch {
                readerGroup.leave()
                readerGroup.leave()
                terminationGroup.leave()
                throw error
            }

            try? inputPipe.fileHandleForReading.close()
            try? outputPipe.fileHandleForWriting.close()
            try? errorPipe.fileHandleForWriting.close()

            DispatchQueue.global(qos: .utility).async { [self] in
                defer { readerGroup.leave() }
                while true {
                    let data = outputPipe.fileHandleForReading.availableData
                    guard data.isEmpty == false else {
                        return
                    }
                    consumeOutput(data)
                }
            }
            DispatchQueue.global(qos: .utility).async { [self] in
                defer { readerGroup.leave() }
                while true {
                    let data = errorPipe.fileHandleForReading.availableData
                    guard data.isEmpty == false else {
                        return
                    }
                    errorOutput.append(data)
                }
            }
        }

        func writeLine(_ line: String) throws {
            try writeQueue.sync {
                guard process.isRunning else {
                    throw Self.processUnavailableError("tmux observer is not running")
                }
                try inputPipe.fileHandleForWriting.write(
                    contentsOf: Data((line + "\n").utf8)
                )
            }
        }

        func prepareSubscriptionActivation(name: String) throws {
            stateLock.lock()
            defer { stateLock.unlock() }
            guard isTerminated == false,
                  pendingActivations[name] == nil else {
                throw Self.processUnavailableError("tmux observer subscription unavailable")
            }
            pendingActivations[name] = DispatchSemaphore(value: 0)
        }

        func waitForSubscriptionActivation(name: String) throws {
            stateLock.lock()
            guard let semaphore = pendingActivations[name] else {
                stateLock.unlock()
                throw Self.processUnavailableError("tmux observer subscription was not prepared")
            }
            stateLock.unlock()

            let result = semaphore.wait(
                timeout: .now() + subscriptionActivationTimeout
            )
            stateLock.lock()
            pendingActivations.removeValue(forKey: name)
            let activated = activatedNames.remove(name) != nil
            let terminated = isTerminated
            stateLock.unlock()
            guard result == .success, activated, terminated == false else {
                throw Self.processUnavailableError("tmux observer subscription activation timed out")
            }
        }

        func cancelSubscriptionActivation(name: String) {
            stateLock.lock()
            pendingActivations.removeValue(forKey: name)
            activatedNames.remove(name)
            stateLock.unlock()
        }

        func waitForExitOrTerminate() {
            if terminationGroup.wait(timeout: .now() + detachTimeout) == .success {
                return
            }
            if process.isRunning {
                process.terminate()
            }
            _ = terminationGroup.wait(timeout: .now() + 1)
        }

        private func consumeOutput(_ data: Data) {
            onOutput(data)
            let events = acknowledgementParser.feed(data)
            for event in events {
                guard case .subscriptionChanged(let name, _, _, _, _) = event else {
                    continue
                }
                stateLock.lock()
                activatedNames.insert(name)
                let semaphore = pendingActivations[name]
                stateLock.unlock()
                semaphore?.signal()
            }
        }

        private func processDidTerminate(_ process: Process) {
            let pending: [DispatchSemaphore]
            stateLock.lock()
            guard didFinishTermination == false else {
                stateLock.unlock()
                return
            }
            didFinishTermination = true
            isTerminated = true
            pending = Array(pendingActivations.values)
            stateLock.unlock()

            try? inputPipe.fileHandleForWriting.close()
            for semaphore in pending {
                semaphore.signal()
            }
            terminationGroup.leave()

            DispatchQueue.global(qos: .utility).async { [self] in
                readerGroup.wait()
                let error: Error?
                if process.terminationStatus == 0 {
                    error = nil
                } else {
                    let stderr = String(data: errorOutput.value, encoding: .utf8) ?? ""
                    error = Self.processUnavailableError(
                        stderr.isEmpty
                            ? "tmux observer exited with status \(process.terminationStatus)"
                            : stderr
                    )
                }
                onExit(error)
            }
        }

        private static func processUnavailableError(_ message: String) -> Error {
            NSError(
                domain: "OrdinaryTmuxLiveControlModeProcess",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }
    }
}

