import Foundation

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

    enum CodingKeys: String, CodingKey {
        case state
        case endpoint
        case errorMessage = "error_message"
    }
}

protocol BridgeCloudflaredManagedProcess: AnyObject {
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
    private let lock = NSLock()
    private var managedProcess: BridgeCloudflaredManagedProcess?
    private var status = BridgeCloudflaredStatus(state: .off,
                                                endpoint: nil,
                                                errorMessage: nil)
    private var endpointReadySemaphore: DispatchSemaphore?

    init(binaryResolver: @escaping () -> String? = BridgeCloudflaredBinaryResolver.resolve,
         processRunner: BridgeCloudflaredProcessRunning = BridgeCloudflaredProcessRunner()) {
        self.binaryResolver = binaryResolver
        self.processRunner = processRunner
    }

    func startAndWaitForEndpoint(timeout: TimeInterval) -> BridgeCloudflaredStatus {
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
        lock.lock()
        let current = status
        lock.unlock()
        return current
    }

    func stop() {
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

enum BridgeCloudflaredBinaryResolver {
    static func resolve() -> String? {
        resolve(environment: ProcessInfo.processInfo.environment)
    }

    static func resolve(environment: [String: String]) -> String? {
        let path = environment["PATH"] ?? "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        return resolve(searchDirectories: path.split(separator: ":").map(String.init))
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

    func terminate() {
        guard process.isRunning else {
            return
        }
        process.terminate()
    }
}
