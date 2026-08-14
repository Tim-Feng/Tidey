import Darwin
import Foundation
import XCTest

@testable import RemoteBridge

final class TmuxInteractivePTYIntegrationTests: XCTestCase {
    func testRealPTYAttachesExactSessionWindowWithInitialSizeAndReapsAfterMasterClose() throws {
        guard let tmuxPath = TmuxStateResolver.discoverTmuxBinaryPath() else {
            throw XCTSkip("tmux is unavailable")
        }

        let fixture = try InteractivePTYTmuxFixture(tmuxPath: tmuxPath)
        defer { fixture.shutdown() }
        let target = try fixture.startWithNonCurrentTargetWindow()
        let controller = TmuxInteractivePTYController()
        let handle = try controller.spawn(
            TmuxInteractivePTYAttachCommand(
                tmuxExecutablePath: tmuxPath,
                socket: .path(fixture.socketPath),
                sessionID: target.sessionID,
                windowID: target.windowID,
                initialSize: TmuxInteractivePTYSize(columns: 80, rows: 24)
            )
        )
        var didCloseMaster = false
        var didReapChild = false
        defer {
            if didCloseMaster == false {
                try? controller.close(masterFileDescriptor: handle.masterFileDescriptor)
            }
            if didReapChild == false {
                reapForCleanup(controller: controller, childProcessID: handle.childProcessID)
            }
        }

        XCTAssertEqual(isatty(handle.masterFileDescriptor), 1)
        XCTAssertNotEqual(fcntl(handle.masterFileDescriptor, F_GETFL) & O_NONBLOCK, 0)
        XCTAssertNotEqual(fcntl(handle.masterFileDescriptor, F_GETFD) & FD_CLOEXEC, 0)

        let client = try XCTUnwrap(
            fixture.waitForClient(processID: handle.childProcessID, timeout: 3)
        )
        XCTAssertTrue(client.tty.hasPrefix("/dev/ttys"))
        XCTAssertEqual(client.sessionID, target.sessionID)
        XCTAssertEqual(client.windowID, target.windowID)
        XCTAssertEqual(client.columns, 80)
        XCTAssertEqual(client.rows, 24)
        XCTAssertTrue(
            fixture.waitForWindowGeometry(
                windowID: target.windowID,
                expected: "80|23",
                timeout: 2
            )
        )

        try controller.close(masterFileDescriptor: handle.masterFileDescriptor)
        didCloseMaster = true
        let childExit = try waitForChildExit(
            controller: controller,
            childProcessID: handle.childProcessID,
            timeout: 3
        )
        XCTAssertNotNil(childExit)
        didReapChild = childExit != nil
        XCTAssertTrue(fixture.waitForClientCount(0, timeout: 2))
    }

    private func waitForChildExit(
        controller: TmuxInteractivePTYControlling,
        childProcessID: Int32,
        timeout: TimeInterval
    ) throws -> TmuxInteractivePTYChildExit? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let childExit = try controller.reap(
                childProcessID: childProcessID,
                blocking: false
            ) {
                return childExit
            }
            usleep(20_000)
        } while Date() < deadline
        return try controller.reap(childProcessID: childProcessID, blocking: false)
    }

    private func reapForCleanup(
        controller: TmuxInteractivePTYControlling,
        childProcessID: Int32
    ) {
        do {
            if try waitForChildExit(
                controller: controller,
                childProcessID: childProcessID,
                timeout: 1
            ) != nil {
                return
            }
        } catch let error as TmuxInteractivePTYControllerError {
            if case .operationFailed(let operation, let code) = error,
               operation == "reap",
               code == ECHILD {
                return
            }
        } catch {
            // Continue with bounded cleanup of the exact spawned child.
        }
        _ = kill(childProcessID, SIGHUP)
        _ = try? controller.reap(childProcessID: childProcessID, blocking: true)
    }
}

private struct InteractivePTYTmuxTarget {
    let sessionID: String
    let windowID: String
}

private struct InteractivePTYTmuxClientRecord {
    enum ParsingError: Error {
        case invalidRecord(String)
    }

    let processID: Int32
    let tty: String
    let sessionID: String
    let windowID: String
    let columns: Int
    let rows: Int

    init(record: Substring) throws {
        let fields = record.split(separator: "|", omittingEmptySubsequences: false)
        guard fields.count == 6,
              let processID = Int32(fields[0]),
              let columns = Int(fields[4]),
              let rows = Int(fields[5]) else {
            throw ParsingError.invalidRecord(String(record))
        }
        self.processID = processID
        tty = String(fields[1])
        sessionID = String(fields[2])
        windowID = String(fields[3])
        self.columns = columns
        self.rows = rows
    }
}

private final class InteractivePTYTmuxFixture {
    enum FixtureError: Error, CustomStringConvertible {
        case invalidRecord(String)
        case commandFailed(arguments: [String], status: Int32, stderr: String)
        case commandTimedOut(arguments: [String])

        var description: String {
            switch self {
            case .invalidRecord(let record):
                return "invalid tmux record: \(record)"
            case .commandFailed(let arguments, let status, let stderr):
                return "tmux command failed (\(status)): \(arguments.joined(separator: " ")): \(stderr)"
            case .commandTimedOut(let arguments):
                return "tmux command timed out: \(arguments.joined(separator: " "))"
            }
        }
    }

    let socketPath: String

    private let tmuxPath: String
    private let rootURL: URL
    private var hasStartedServer = false
    private var isShutDown = false

    init(tmuxPath: String) throws {
        self.tmuxPath = tmuxPath
        let temporaryRoot = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .standardizedFileURL
        rootURL = temporaryRoot
            .appendingPathComponent("tidey-tmux-pty-\(UUID().uuidString.prefix(12))", isDirectory: true)
            .standardizedFileURL
        let candidateSocketPath = rootURL.appendingPathComponent("socket").path
        guard rootURL.path.hasPrefix(temporaryRoot.path + "/"),
              candidateSocketPath.utf8.count < 100 else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: false
        )
        socketPath = candidateSocketPath
    }

    func startWithNonCurrentTargetWindow() throws -> InteractivePTYTmuxTarget {
        let first = try run([
            "-f", "/dev/null",
            "new-session", "-d",
            "-P", "-F", "#{session_id}|#{window_id}",
            "-s", "pty-exact",
            "-x", "132",
            "-y", "37",
        ])
        hasStartedServer = true
        let firstFields = first.split(separator: "|", omittingEmptySubsequences: false)
        guard firstFields.count == 2 else {
            throw FixtureError.invalidRecord(first)
        }
        let sessionID = String(firstFields[0])
        let target = try run([
            "new-window", "-d",
            "-P", "-F", "#{session_id}|#{window_id}",
            "-t", sessionID,
            "-n", "phone-target",
        ])
        let targetFields = target.split(separator: "|", omittingEmptySubsequences: false)
        guard targetFields.count == 2,
              targetFields[0] == Substring(sessionID) else {
            throw FixtureError.invalidRecord(target)
        }
        return InteractivePTYTmuxTarget(
            sessionID: sessionID,
            windowID: String(targetFields[1])
        )
    }

    func waitForClient(
        processID: Int32,
        timeout: TimeInterval
    ) -> InteractivePTYTmuxClientRecord? {
        var matched: InteractivePTYTmuxClientRecord?
        _ = waitUntil(timeout: timeout) {
            matched = try? self.clientRecords().first { $0.processID == processID }
            return matched != nil
        }
        return matched
    }

    func waitForClientCount(_ expected: Int, timeout: TimeInterval) -> Bool {
        waitUntil(timeout: timeout) {
            (try? self.clientRecords().count) == expected
        }
    }

    func waitForWindowGeometry(
        windowID: String,
        expected: String,
        timeout: TimeInterval
    ) -> Bool {
        waitUntil(timeout: timeout) {
            (try? self.run([
                "display-message", "-p",
                "-t", windowID,
                "#{window_width}|#{window_height}",
            ])) == expected
        }
    }

    func shutdown() {
        guard isShutDown == false else { return }
        isShutDown = true
        if hasStartedServer {
            _ = try? run(["kill-server"])
        }
        try? FileManager.default.removeItem(at: rootURL)
    }

    private func clientRecords() throws -> [InteractivePTYTmuxClientRecord] {
        let output = try run([
            "list-clients",
            "-F", "#{client_pid}|#{client_tty}|#{session_id}|#{window_id}|#{client_width}|#{client_height}",
        ])
        return try output.split(whereSeparator: \.isNewline).map {
            try InteractivePTYTmuxClientRecord(record: $0)
        }
    }

    private func run(_ commandArguments: [String]) throws -> String {
        let arguments = ["-S", socketPath] + commandArguments
        guard let result = BoundedProcessRunner.run(
            executablePath: tmuxPath,
            arguments: arguments,
            timeout: 3,
            circuitBreakerCooldown: 0
        ) else {
            throw FixtureError.commandTimedOut(arguments: arguments)
        }
        guard result.terminationStatus == 0 else {
            throw FixtureError.commandFailed(
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
