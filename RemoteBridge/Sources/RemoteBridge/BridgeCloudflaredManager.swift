import Foundation
import Darwin

struct BridgeCloudflaredCommand: Equatable, Sendable {
    let executablePath: String
    let arguments: [String]
}

enum BridgeCloudflaredState: String, Codable, Equatable, Sendable {
    case off
    case starting
    case online
    case error
}

struct BridgeCloudflaredStatus: Codable, Equatable, Sendable {
    let state: BridgeCloudflaredState
    let endpoint: BridgePairEndpoint?
    let errorMessage: String?
    let updatedAt: Date?
    let processID: Int32?

    init(state: BridgeCloudflaredState,
         endpoint: BridgePairEndpoint?,
         errorMessage: String?,
         updatedAt: Date? = nil,
         processID: Int32? = nil) {
        self.state = state
        self.endpoint = endpoint
        self.errorMessage = errorMessage
        self.updatedAt = updatedAt
        self.processID = processID
    }

    enum CodingKeys: String, CodingKey {
        case state
        case endpoint
        case errorMessage = "error_message"
        case updatedAt = "updated_at"
        case processID = "process_id"
    }
}

final class BridgeCloudflaredStatusStore {
    private let fileURL: URL
    private let fileManager: FileManager
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(fileURL: URL = BridgePaths().cloudflaredStateFileURL,
         fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        decoder.dateDecodingStrategy = .iso8601
    }

    func readStatus() throws -> BridgeCloudflaredStatus {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return BridgeCloudflaredStatus(state: .off, endpoint: nil, errorMessage: nil)
        }
        let data = try Data(contentsOf: fileURL)
        return try decoder.decode(BridgeCloudflaredStatus.self, from: data)
    }

    func writeStatus(_ status: BridgeCloudflaredStatus) throws {
        try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
        let data = try encoder.encode(status)
        try data.write(to: fileURL, options: [.atomic])
    }
}

protocol BridgeCloudflaredSupervisorControlling {
    func ensureRunning()
}

struct BridgeCloudflaredNoopSupervisorController: BridgeCloudflaredSupervisorControlling {
    func ensureRunning() {}
}

protocol BridgeCloudflaredManagedProcess: AnyObject {
    var processID: Int32? { get }
    func terminate()
}

protocol BridgeCloudflaredProcessRunning {
    func start(command: BridgeCloudflaredCommand,
               onOutput: @escaping @Sendable (String) -> Void,
               onExit: @escaping @Sendable (Int32) -> Void) throws -> BridgeCloudflaredManagedProcess
}

enum BridgeCloudflaredOutputParser {
    static func firstTunnelEndpoint(in output: String) -> BridgePairEndpoint? {
        guard let range = output.range(of: #"https://[A-Za-z0-9-]+\.trycloudflare\.com"#,
                                       options: .regularExpression),
              let url = URL(string: String(output[range])),
              let host = url.host,
              host.hasSuffix(".trycloudflare.com") else {
            return nil
        }
        return BridgePairEndpoint(scheme: "wss",
                                  host: host,
                                  port: url.port,
                                  path: url.path.isEmpty ? "/" : url.path)
    }
}

final class BridgeCloudflaredManager {
    private let binaryResolver: () -> String?
    private let processRunner: BridgeCloudflaredProcessRunning
    private let statusStore: BridgeCloudflaredStatusStore?
    private let supervisorController: BridgeCloudflaredSupervisorControlling
    private let lock = NSLock()
    private var managedProcess: BridgeCloudflaredManagedProcess?
    private var status = BridgeCloudflaredStatus(state: .off,
                                                endpoint: nil,
                                                errorMessage: nil)
    private var endpointReadySemaphore: DispatchSemaphore?

    init(binaryResolver: @escaping () -> String? = BridgeCloudflaredBinaryResolver.resolve,
         processRunner: BridgeCloudflaredProcessRunning = BridgeCloudflaredProcessRunner(),
         statusStore: BridgeCloudflaredStatusStore? = nil,
         supervisorController: BridgeCloudflaredSupervisorControlling = BridgeCloudflaredNoopSupervisorController()) {
        self.binaryResolver = binaryResolver
        self.processRunner = processRunner
        self.statusStore = statusStore
        self.supervisorController = supervisorController
    }

    func ensureSupervisorRunning() {
        supervisorController.ensureRunning()
    }

    func startAndWaitForEndpoint(timeout: TimeInterval) -> BridgeCloudflaredStatus {
        if statusStore != nil {
            ensureSupervisorRunning()
            let deadline = Date().addingTimeInterval(timeout)
            repeat {
                let current = currentStatus()
                switch current.state {
                case .online, .error:
                    return current
                case .off, .starting:
                    Thread.sleep(forTimeInterval: 0.05)
                }
            } while Date() < deadline
            return currentStatus()
        }

        let semaphore: DispatchSemaphore
        lock.lock()
        switch status.state {
        case .online:
            let current = status
            lock.unlock()
            return current
        case .starting:
            semaphore = endpointReadySemaphore ?? DispatchSemaphore(value: 0)
            endpointReadySemaphore = semaphore
            lock.unlock()
        case .off, .error:
            guard let executablePath = binaryResolver() else {
                status = BridgeCloudflaredStatus(state: .error,
                                                endpoint: nil,
                                                errorMessage: "cloudflared not found in PATH")
                let current = status
                lock.unlock()
                return current
            }
            status = BridgeCloudflaredStatus(state: .starting,
                                            endpoint: nil,
                                            errorMessage: nil)
            semaphore = DispatchSemaphore(value: 0)
            endpointReadySemaphore = semaphore
            lock.unlock()

            let command = BridgeCloudflaredCommand(executablePath: executablePath,
                                                  arguments: [
                                                    "tunnel",
                                                    "--no-autoupdate",
                                                    "--url",
                                                    "http://localhost:4817",
                                                  ])
            do {
                let process = try processRunner.start(command: command,
                                                      onOutput: { [weak self] output in
                                                          self?.handleOutput(output)
                                                      },
                                                      onExit: { [weak self] exitCode in
                                                          self?.handleExit(exitCode)
                                                      })
                lock.lock()
                managedProcess = process
                lock.unlock()
            } catch {
                setStatus(BridgeCloudflaredStatus(state: .error,
                                                  endpoint: nil,
                                                  errorMessage: error.localizedDescription),
                          signalWaiters: true)
            }
        }

        _ = semaphore.wait(timeout: .now() + timeout)
        lock.lock()
        let current = status
        lock.unlock()
        return current
    }

    func currentStatus() -> BridgeCloudflaredStatus {
        if let statusStore {
            do {
                return try statusStore.readStatus()
            } catch {
                return BridgeCloudflaredStatus(state: .error,
                                              endpoint: nil,
                                              errorMessage: "cloudflared state read failed: \(error.localizedDescription)")
            }
        }

        lock.lock()
        let current = status
        lock.unlock()
        return current
    }

    func stop() {
        guard statusStore == nil else {
            return
        }

        lock.lock()
        let process = managedProcess
        managedProcess = nil
        status = BridgeCloudflaredStatus(state: .off,
                                        endpoint: nil,
                                        errorMessage: nil)
        let semaphore = endpointReadySemaphore
        endpointReadySemaphore = nil
        lock.unlock()

        process?.terminate()
        semaphore?.signal()
    }

    private func handleOutput(_ output: String) {
        guard let endpoint = BridgeCloudflaredOutputParser.firstTunnelEndpoint(in: output) else {
            return
        }
        setStatus(BridgeCloudflaredStatus(state: .online,
                                          endpoint: endpoint,
                                          errorMessage: nil),
                  signalWaiters: true)
    }

    private func handleExit(_ exitCode: Int32) {
        lock.lock()
        let shouldSetError = status.state != .online
        lock.unlock()
        guard shouldSetError else {
            return;
        }
        setStatus(BridgeCloudflaredStatus(state: .error,
                                          endpoint: nil,
                                          errorMessage: "cloudflared exited with status \(exitCode)"),
                  signalWaiters: true)
    }

    private func setStatus(_ newStatus: BridgeCloudflaredStatus, signalWaiters: Bool) {
        lock.lock()
        status = newStatus
        let semaphore = signalWaiters ? endpointReadySemaphore : nil
        if signalWaiters {
            endpointReadySemaphore = nil
        }
        lock.unlock()
        semaphore?.signal()
    }
}

struct BridgeCloudflaredLaunchAgentController: BridgeCloudflaredSupervisorControlling {
    let label: String
    let plistURL: URL
    let processRunner: ([String]) -> Bool

    init(label: String = "com.tidey.remote-bridge.cloudflared",
         plistURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/com.tidey.remote-bridge.cloudflared.plist"),
         processRunner: @escaping ([String]) -> Bool = BridgeCloudflaredLaunchAgentController.runLaunchctl(arguments:)) {
        self.label = label
        self.plistURL = plistURL
        self.processRunner = processRunner
    }

    func ensureRunning() {
        let domain = "gui/\(getuid())"
        let serviceTarget = "\(domain)/\(label)"
        if processRunner(["print", serviceTarget]) {
            _ = processRunner(["kickstart", serviceTarget])
            return
        }
        guard FileManager.default.fileExists(atPath: plistURL.path) else {
            return
        }
        _ = processRunner(["bootstrap", domain, plistURL.path])
    }

    private static func runLaunchctl(arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}

final class BridgeCloudflaredSupervisor {
    private let binaryResolver: () -> String?
    private let processRunner: BridgeCloudflaredProcessRunning
    private let statusStore: BridgeCloudflaredStatusStore
    private let retryDelay: TimeInterval
    private let lock = NSLock()
    private let terminationSemaphore = DispatchSemaphore(value: 0)
    private var currentProcess: BridgeCloudflaredManagedProcess?
    private var isTerminating = false
    private var signalSources = [DispatchSourceSignal]()

    init(binaryResolver: @escaping () -> String? = BridgeCloudflaredBinaryResolver.resolve,
         processRunner: BridgeCloudflaredProcessRunning = BridgeCloudflaredProcessRunner(),
         statusStore: BridgeCloudflaredStatusStore = BridgeCloudflaredStatusStore(),
         retryDelay: TimeInterval = 5) {
        self.binaryResolver = binaryResolver
        self.processRunner = processRunner
        self.statusStore = statusStore
        self.retryDelay = retryDelay
    }

    func run() -> Never {
        installSignalHandlers()
        while true {
            if shouldTerminate() {
                writeStatus(BridgeCloudflaredStatus(state: .off,
                                                    endpoint: nil,
                                                    errorMessage: nil,
                                                    updatedAt: Date()))
                exit(0)
            }

            guard let executablePath = binaryResolver() else {
                writeStatus(BridgeCloudflaredStatus(state: .error,
                                                    endpoint: nil,
                                                    errorMessage: "cloudflared not found in PATH",
                                                    updatedAt: Date()))
                waitBeforeRestart()
                continue
            }

            writeStatus(BridgeCloudflaredStatus(state: .starting,
                                                endpoint: nil,
                                                errorMessage: nil,
                                                updatedAt: Date()))

            let exitSemaphore = DispatchSemaphore(value: 0)
            let exitCodeBox = BridgeCloudflaredExitCodeBox()
            do {
                let command = BridgeCloudflaredCommand(executablePath: executablePath,
                                                      arguments: [
                                                        "tunnel",
                                                        "--no-autoupdate",
                                                        "--url",
                                                        "http://localhost:4817",
                                                      ])
                let process = try processRunner.start(command: command,
                                                      onOutput: { [weak self] output in
                                                          self?.handleOutput(output)
                                                      },
                                                      onExit: { code in
                                                          exitCodeBox.exitCode = code
                                                          exitSemaphore.signal()
                                                      })
                setCurrentProcess(process)
                _ = exitSemaphore.wait(timeout: .distantFuture)
                clearCurrentProcess(process)
                if shouldTerminate() {
                    continue
                }
                writeStatus(BridgeCloudflaredStatus(state: .error,
                                                    endpoint: nil,
                                                    errorMessage: "cloudflared exited with status \(exitCodeBox.exitCode ?? -1)",
                                                    updatedAt: Date()))
            } catch {
                writeStatus(BridgeCloudflaredStatus(state: .error,
                                                    endpoint: nil,
                                                    errorMessage: error.localizedDescription,
                                                    updatedAt: Date()))
            }

            waitBeforeRestart()
        }
    }

    private func handleOutput(_ output: String) {
        guard let endpoint = BridgeCloudflaredOutputParser.firstTunnelEndpoint(in: output) else {
            return
        }
        writeStatus(BridgeCloudflaredStatus(state: .online,
                                            endpoint: endpoint,
                                            errorMessage: nil,
                                            updatedAt: Date(),
                                            processID: currentProcessID()))
    }

    private func installSignalHandlers() {
        for signalNumber in [SIGTERM, SIGINT] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .global())
            source.setEventHandler { [weak self] in
                self?.requestTermination()
            }
            source.resume()
            signalSources.append(source)
        }
    }

    private func requestTermination() {
        let process: BridgeCloudflaredManagedProcess?
        lock.lock()
        isTerminating = true
        process = currentProcess
        lock.unlock()

        process?.terminate()
        terminationSemaphore.signal()
    }

    private func shouldTerminate() -> Bool {
        lock.lock()
        let value = isTerminating
        lock.unlock()
        return value
    }

    private func setCurrentProcess(_ process: BridgeCloudflaredManagedProcess) {
        lock.lock()
        currentProcess = process
        lock.unlock()
    }

    private func clearCurrentProcess(_ process: BridgeCloudflaredManagedProcess) {
        lock.lock()
        if currentProcess === process {
            currentProcess = nil
        }
        lock.unlock()
    }

    private func currentProcessID() -> Int32? {
        lock.lock()
        let processID = currentProcess?.processID
        lock.unlock()
        return processID
    }

    private func waitBeforeRestart() {
        _ = terminationSemaphore.wait(timeout: .now() + retryDelay)
    }

    private func writeStatus(_ status: BridgeCloudflaredStatus) {
        do {
            try statusStore.writeStatus(status)
        } catch {
            BridgeLogger.server.error("cloudflared supervisor failed to write state error=\(error.localizedDescription, privacy: .public)")
        }
    }
}

private final class BridgeCloudflaredExitCodeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int32?

    var exitCode: Int32? {
        get {
            lock.lock()
            let current = value
            lock.unlock()
            return current
        }
        set {
            lock.lock()
            value = newValue
            lock.unlock()
        }
    }
}

enum BridgeCloudflaredBinaryResolver {
    private static let fallbackSearchDirectories = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/usr/bin",
        "/bin",
    ]

    static func resolve() -> String? {
        resolve(environment: ProcessInfo.processInfo.environment)
    }

    static func resolve(environment: [String: String],
                        additionalSearchDirectories: [String] = fallbackSearchDirectories) -> String? {
        let pathDirectories = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        return resolve(searchDirectories: orderedUnique(pathDirectories + additionalSearchDirectories))
    }

    private static func resolve(searchDirectories: [String]) -> String? {
        for directory in searchDirectories {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent("cloudflared").path
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    private static func orderedUnique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { value in
            guard seen.contains(value) == false else {
                return false
            }
            seen.insert(value)
            return true
        }
    }
}

final class BridgeCloudflaredProcessRunner: BridgeCloudflaredProcessRunning {
    func start(command: BridgeCloudflaredCommand,
               onOutput: @escaping @Sendable (String) -> Void,
               onExit: @escaping @Sendable (Int32) -> Void) throws -> BridgeCloudflaredManagedProcess {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command.executablePath)
        process.arguments = command.arguments

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let outputHandler: @Sendable (FileHandle) -> Void = { handle in
            let data = handle.availableData
            guard data.isEmpty == false,
                  let text = String(data: data, encoding: .utf8) else {
                return
            }
            onOutput(text)
        }
        outputPipe.fileHandleForReading.readabilityHandler = outputHandler
        errorPipe.fileHandleForReading.readabilityHandler = outputHandler

        process.terminationHandler = { process in
            outputPipe.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil
            onExit(process.terminationStatus)
        }

        try process.run()
        return BridgeCloudflaredProcess(process: process)
    }
}

private final class BridgeCloudflaredProcess: BridgeCloudflaredManagedProcess {
    private let process: Process

    init(process: Process) {
        self.process = process
    }

    var processID: Int32? {
        process.processIdentifier
    }

    func terminate() {
        guard process.isRunning else {
            return
        }
        process.terminate()
    }
}
