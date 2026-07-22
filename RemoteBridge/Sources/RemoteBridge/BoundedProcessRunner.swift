import Darwin
import Foundation

struct BoundedProcessResult: Sendable {
    let terminationStatus: Int32
    let standardOutput: Data
    let standardError: Data
}
private final class BoundedProcessDataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    func store(_ data: Data) {
        lock.lock()
        storage = data
        lock.unlock()
    }

    var value: Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

/// Runs a short-lived local helper without allowing it to monopolize its
/// caller forever. Process discovery happens on the agent-registry serial
/// queue, so an unbounded `waitUntilExit()` here would stall every Remote
/// request that needs agent state.
enum BoundedProcessRunner {
    private static let circuitQueue = DispatchQueue(label: "com.tidey.remote-bridge.bounded-process-circuit")
    private static var unavailableUntil = [String: UInt64]()

    static func run(executablePath: String,
                    arguments: [String],
                    environment: [String: String]? = nil,
                    timeout: TimeInterval,
                    terminationGrace: TimeInterval = 0.2,
                    circuitBreakerCooldown: TimeInterval = 5) -> BoundedProcessResult? {
        guard circuitAllowsLaunch(executablePath: executablePath) else {
            return nil
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.environment = environment

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let outputBox = BoundedProcessDataBox()
        let errorBox = BoundedProcessDataBox()
        let readers = DispatchGroup()

        let terminated = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            terminated.signal()
        }

        do {
            try process.run()
        } catch {
            BridgeLogger.server.error("bounded process launch failed executable=\(executablePath, privacy: .public) error=\(String(describing: error), privacy: .public)")
            return nil
        }

        try? outputPipe.fileHandleForWriting.close()
        try? errorPipe.fileHandleForWriting.close()
        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            outputBox.store((try? outputPipe.fileHandleForReading.readToEnd()) ?? Data())
            readers.leave()
        }
        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            errorBox.store((try? errorPipe.fileHandleForReading.readToEnd()) ?? Data())
            readers.leave()
        }

        let boundedTimeout = max(0, timeout)
        let boundedGrace = max(0, terminationGrace)
        if terminated.wait(timeout: .now() + boundedTimeout) == .timedOut {
            openCircuit(executablePath: executablePath, cooldown: circuitBreakerCooldown)
            let pid = process.processIdentifier
            _ = Darwin.kill(pid, SIGTERM)
            if terminated.wait(timeout: .now() + boundedGrace) == .timedOut {
                _ = Darwin.kill(pid, SIGKILL)
                _ = terminated.wait(timeout: .now() + boundedGrace)
            }
            _ = readers.wait(timeout: .now() + boundedGrace)
            BridgeLogger.server.error("bounded process timed out executable=\(executablePath, privacy: .public) argv=\(arguments.joined(separator: " "), privacy: .public) timeout_seconds=\(boundedTimeout, privacy: .public)")
            return nil
        }

        guard readers.wait(timeout: .now() + boundedGrace) == .success else {
            openCircuit(executablePath: executablePath, cooldown: circuitBreakerCooldown)
            BridgeLogger.server.error("bounded process output drain timed out executable=\(executablePath, privacy: .public) argv=\(arguments.joined(separator: " "), privacy: .public)")
            return nil
        }

        return BoundedProcessResult(terminationStatus: process.terminationStatus,
                                    standardOutput: outputBox.value,
                                    standardError: errorBox.value)
    }

    private static func circuitAllowsLaunch(executablePath: String) -> Bool {
        let now = DispatchTime.now().uptimeNanoseconds
        return circuitQueue.sync {
            guard let deadline = unavailableUntil[executablePath] else {
                return true
            }
            guard deadline > now else {
                unavailableUntil.removeValue(forKey: executablePath)
                return true
            }
            return false
        }
    }

    private static func openCircuit(executablePath: String, cooldown: TimeInterval) {
        let boundedCooldown = max(0, cooldown)
        guard boundedCooldown > 0 else {
            return
        }
        let nanoseconds = UInt64(min(boundedCooldown, 3_600) * 1_000_000_000)
        let deadline = DispatchTime.now().uptimeNanoseconds &+ nanoseconds
        circuitQueue.sync {
            unavailableUntil[executablePath] = deadline
        }
    }
}
