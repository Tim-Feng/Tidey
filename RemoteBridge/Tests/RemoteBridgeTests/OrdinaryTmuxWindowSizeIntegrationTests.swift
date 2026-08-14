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

    func shutdown() {
        lock.lock()
        guard isShutDown == false else {
            lock.unlock()
            return
        }
        isShutDown = true
        let shouldKillServer = hasStartedServer
        lock.unlock()

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
}
