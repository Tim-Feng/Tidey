import Darwin
import Foundation
import XCTest

@testable import RemoteBridge

final class OrdinaryTmuxWindowSizeIntegrationTests: XCTestCase {
    func testDisposableHarnessPinsEveryServerCommandToItsIsolatedSocket() throws {
        guard let tmuxPath = TmuxStateResolver.discoverTmuxBinaryPath() else {
            throw XCTSkip("tmux is unavailable")
        }
        let version = try IsolatedTmuxHarness.version(at: tmuxPath)
        guard version == "tmux 3.6a" else {
            throw XCTSkip("isolated sizing regression requires tmux 3.6a; found \(version)")
        }

        let harness = try IsolatedTmuxHarness(tmuxPath: tmuxPath)
        defer { harness.shutdown() }

        try harness.startDetachedSession(name: "socket-proof", columns: 132, rows: 37)

        XCTAssertEqual(
            try harness.windowGeometry(sessionName: "socket-proof"),
            "socket-proof|132|37|latest"
        )
        XCTAssertTrue(harness.serverArguments.isEmpty == false)
        XCTAssertTrue(harness.serverArguments.allSatisfy {
            Array($0.prefix(2)) == ["-S", harness.socketPath]
        })

        harness.shutdown()
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.rootURL.path))
    }

    func testControlModeSizingClientReportsReadyAndDetachesWithinBoundedTime() throws {
        guard let tmuxPath = TmuxStateResolver.discoverTmuxBinaryPath() else {
            throw XCTSkip("tmux is unavailable")
        }
        let version = try IsolatedTmuxHarness.version(at: tmuxPath)
        guard version == "tmux 3.6a" else {
            throw XCTSkip("isolated sizing regression requires tmux 3.6a; found \(version)")
        }

        let harness = try IsolatedTmuxHarness(tmuxPath: tmuxPath)
        defer { harness.shutdown() }
        try harness.startDetachedSession(name: "client-proof", columns: 132, rows: 37)

        let client = try harness.attachControlModeSizingClient(
            sessionName: "client-proof",
            columns: 100,
            rows: 30
        )

        XCTAssertTrue(
            harness.waitForWindowGeometry(
                sessionName: "client-proof",
                expected: "client-proof|100|30|latest",
                timeout: 2
            )
        )
        XCTAssertEqual(try harness.clientCount(), 1)
        XCTAssertEqual(try client.detachAndWait(timeout: 2), 0)
        XCTAssertTrue(harness.waitForClientCount(0, timeout: 2))
    }
}

private final class IsolatedTmuxControlClient: @unchecked Sendable {
    enum ClientError: Error {
        case unavailable
        case exitTimedOut
        case outputDrainTimedOut
    }

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
    }

    private let process = Process()
    private let inputPipe = Pipe()
    private let outputPipe = Pipe()
    private let errorPipe = Pipe()
    private let writeQueue = DispatchQueue(label: "com.tidey.tests.tmux-sizing-client-input")
    private let terminationGroup = DispatchGroup()
    private let readerGroup = DispatchGroup()
    private let output = DataAccumulator()
    private let errorOutput = DataAccumulator()

    init(tmuxPath: String, arguments: [String]) throws {
        process.executableURL = URL(fileURLWithPath: tmuxPath)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["LC_CTYPE"] = "UTF-8"
        environment["LANG"] = "en_US.UTF-8"
        process.environment = environment
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        terminationGroup.enter()
        process.terminationHandler = { [terminationGroup] _ in
            terminationGroup.leave()
        }
        do {
            try process.run()
        } catch {
            terminationGroup.leave()
            throw error
        }

        try? inputPipe.fileHandleForReading.close()
        try? outputPipe.fileHandleForWriting.close()
        try? errorPipe.fileHandleForWriting.close()

        readerGroup.enter()
        DispatchQueue.global(qos: .utility).async { [outputPipe, output, readerGroup] in
            output.append((try? outputPipe.fileHandleForReading.readToEnd()) ?? Data())
            readerGroup.leave()
        }
        readerGroup.enter()
        DispatchQueue.global(qos: .utility).async { [errorPipe, errorOutput, readerGroup] in
            errorOutput.append((try? errorPipe.fileHandleForReading.readToEnd()) ?? Data())
            readerGroup.leave()
        }
    }

    func writeLine(_ line: String) throws {
        try writeQueue.sync {
            guard process.isRunning else {
                throw ClientError.unavailable
            }
            try inputPipe.fileHandleForWriting.write(contentsOf: Data((line + "\n").utf8))
        }
    }

    func detachAndWait(timeout: TimeInterval) throws -> Int32 {
        try writeLine("detach-client")
        guard terminationGroup.wait(timeout: .now() + timeout) == .success else {
            throw ClientError.exitTimedOut
        }
        guard readerGroup.wait(timeout: .now() + 1) == .success else {
            throw ClientError.outputDrainTimedOut
        }
        return process.terminationStatus
    }

    func shutdown() {
        if process.isRunning {
            try? writeLine("detach-client")
        }
        if terminationGroup.wait(timeout: .now() + 0.5) != .success,
           process.isRunning {
            process.terminate()
            _ = terminationGroup.wait(timeout: .now() + 0.5)
        }
        try? inputPipe.fileHandleForWriting.close()
        _ = readerGroup.wait(timeout: .now() + 0.5)
    }
}

private final class IsolatedTmuxHarness {
    enum HarnessError: Error, CustomStringConvertible {
        case commandFailed(arguments: [String], status: Int32, stderr: String)
        case commandTimedOut(arguments: [String])

        var description: String {
            switch self {
            case .commandFailed(let arguments, let status, let stderr):
                return "tmux command failed (\(status)): \(arguments.joined(separator: " ")): \(stderr)"
            case .commandTimedOut(let arguments):
                return "tmux command timed out: \(arguments.joined(separator: " "))"
            }
        }
    }

    let rootURL: URL
    let socketPath: String

    private let tmuxPath: String
    private let lock = NSLock()
    private var recordedServerArguments = [[String]]()
    private var controlClients = [IsolatedTmuxControlClient]()
    private var hasStartedServer = false
    private var isShutDown = false

    init(tmuxPath: String) throws {
        self.tmuxPath = tmuxPath
        let shortTemporaryRoot = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .standardizedFileURL
        rootURL = shortTemporaryRoot
            .appendingPathComponent("tidey-tmux-size-\(UUID().uuidString.prefix(12))", isDirectory: true)
            .standardizedFileURL
        guard rootURL.path.hasPrefix(shortTemporaryRoot.path + "/"),
              rootURL.appendingPathComponent("socket", isDirectory: false).path.utf8.count < 100 else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        try FileManager.default.createDirectory(at: rootURL,
                                                withIntermediateDirectories: false)
        socketPath = rootURL.appendingPathComponent("socket", isDirectory: false).path
    }

    static func version(at tmuxPath: String) throws -> String {
        let arguments = ["-V"]
        guard let result = BoundedProcessRunner.run(executablePath: tmuxPath,
                                                    arguments: arguments,
                                                    timeout: 2,
                                                    circuitBreakerCooldown: 0) else {
            throw HarnessError.commandTimedOut(arguments: arguments)
        }
        guard result.terminationStatus == 0 else {
            throw HarnessError.commandFailed(
                arguments: arguments,
                status: result.terminationStatus,
                stderr: String(decoding: result.standardError, as: UTF8.self)
            )
        }
        return String(decoding: result.standardOutput, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var serverArguments: [[String]] {
        lock.lock()
        defer { lock.unlock() }
        return recordedServerArguments
    }

    func startDetachedSession(name: String, columns: Int, rows: Int) throws {
        _ = try runServerCommand([
            "-f", "/dev/null",
            "new-session", "-d",
            "-s", name,
            "-x", String(columns),
            "-y", String(rows),
        ])
        lock.lock()
        hasStartedServer = true
        lock.unlock()
    }

    func windowGeometry(sessionName: String) throws -> String {
        try runServerCommand([
            "list-windows",
            "-t", "=\(sessionName)",
            "-F", "#{session_name}|#{window_width}|#{window_height}|#{window-size}",
        ])
    }

    func attachControlModeSizingClient(
        sessionName: String,
        columns: Int,
        rows: Int
    ) throws -> IsolatedTmuxControlClient {
        let client = try IsolatedTmuxControlClient(
            tmuxPath: tmuxPath,
            arguments: [
                "-S", socketPath,
                "-f", "/dev/null",
                "-C", "attach-session",
                "-t", "=\(sessionName)",
            ]
        )
        lock.lock()
        controlClients.append(client)
        lock.unlock()
        try client.writeLine("refresh-client -C \(columns),\(rows)")
        return client
    }

    func clientCount() throws -> Int {
        let output = try runServerCommand([
            "list-clients",
            "-F", "#{client_pid}|#{client_flags}",
        ])
        return output.split(whereSeparator: \.isNewline).count
    }

    func waitForWindowGeometry(
        sessionName: String,
        expected: String,
        timeout: TimeInterval
    ) -> Bool {
        waitUntil(timeout: timeout) {
            (try? self.windowGeometry(sessionName: sessionName)) == expected
        }
    }

    func waitForClientCount(_ expected: Int, timeout: TimeInterval) -> Bool {
        waitUntil(timeout: timeout) {
            (try? self.clientCount()) == expected
        }
    }

    func shutdown() {
        lock.lock()
        guard isShutDown == false else {
            lock.unlock()
            return
        }
        isShutDown = true
        let shouldKillServer = hasStartedServer
        let clients = controlClients
        controlClients.removeAll()
        lock.unlock()

        clients.forEach { $0.shutdown() }
        if shouldKillServer {
            _ = try? runServerCommand(["kill-server"])
        }
        try? FileManager.default.removeItem(at: rootURL)
    }

    @discardableResult
    private func runServerCommand(_ commandArguments: [String]) throws -> String {
        let arguments = ["-S", socketPath] + commandArguments
        lock.lock()
        recordedServerArguments.append(arguments)
        lock.unlock()

        guard let result = BoundedProcessRunner.run(executablePath: tmuxPath,
                                                    arguments: arguments,
                                                    timeout: 3,
                                                    circuitBreakerCooldown: 0) else {
            throw HarnessError.commandTimedOut(arguments: arguments)
        }
        guard result.terminationStatus == 0 else {
            throw HarnessError.commandFailed(
                arguments: arguments,
                status: result.terminationStatus,
                stderr: String(decoding: result.standardError, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return String(decoding: result.standardOutput, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func waitUntil(
        timeout: TimeInterval,
        predicate: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if predicate() {
                return true
            }
            usleep(20_000)
        } while Date() < deadline
        return predicate()
    }
}
