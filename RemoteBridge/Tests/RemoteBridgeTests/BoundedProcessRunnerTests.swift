import Darwin
import Foundation
import XCTest

@testable import RemoteBridge

final class BoundedProcessRunnerTests: XCTestCase {
    func testCompletedCommandReturnsStatusAndOutput() throws {
        let result = BoundedProcessRunner.run(executablePath: "/bin/sh",
                                              arguments: ["-c", "printf stdout; printf stderr >&2; exit 7"],
                                              timeout: 1)

        let completed = try XCTUnwrap(result)
        XCTAssertEqual(completed.terminationStatus, 7)
        XCTAssertEqual(String(data: completed.standardOutput, encoding: .utf8), "stdout")
        XCTAssertEqual(String(data: completed.standardError, encoding: .utf8), "stderr")
    }

    func testTimedOutCommandIsKilledWithoutBlockingCaller() throws {
        let pidURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("tidey-bounded-process-\(UUID().uuidString).pid")
        defer { try? FileManager.default.removeItem(at: pidURL) }

        let command = "printf $$ > \"$1\"; trap '' TERM; exec /bin/sleep 30"
        let startedAt = Date()
        let result = BoundedProcessRunner.run(executablePath: "/bin/sh",
                                              arguments: ["-c", command, "bounded-process", pidURL.path],
                                              timeout: 0.1,
                                              terminationGrace: 0.1,
                                              circuitBreakerCooldown: 0)
        let elapsed = Date().timeIntervalSince(startedAt)

        XCTAssertNil(result)
        XCTAssertLessThan(elapsed, 1.0)

        let pidText = try String(contentsOf: pidURL, encoding: .utf8)
        let pid = try XCTUnwrap(Int32(pidText.trimmingCharacters(in: .whitespacesAndNewlines)))
        defer { _ = Darwin.kill(pid, SIGKILL) }

        let deadline = Date().addingTimeInterval(1)
        while Darwin.kill(pid, 0) == 0 && Date() < deadline {
            usleep(10_000)
        }
        XCTAssertNotEqual(Darwin.kill(pid, 0), 0)
        XCTAssertEqual(errno, ESRCH)
    }

    func testLargeOutputIsDrainedWhileCommandRuns() throws {
        let result = BoundedProcessRunner.run(executablePath: "/bin/sh",
                                              arguments: ["-c", "/usr/bin/yes x | /usr/bin/head -c 262144"],
                                              timeout: 2,
                                              circuitBreakerCooldown: 0)

        let completed = try XCTUnwrap(result)
        XCTAssertEqual(completed.terminationStatus, 0)
        XCTAssertEqual(completed.standardOutput.count, 262_144)
    }

    func testTimeoutOpensShortCircuitForSameExecutable() {
        let first = BoundedProcessRunner.run(executablePath: "/usr/bin/yes",
                                             arguments: [],
                                             timeout: 0.05,
                                             terminationGrace: 0.05,
                                             circuitBreakerCooldown: 2)
        XCTAssertNil(first)

        let startedAt = Date()
        let second = BoundedProcessRunner.run(executablePath: "/usr/bin/yes",
                                              arguments: [],
                                              timeout: 1,
                                              terminationGrace: 0.05,
                                              circuitBreakerCooldown: 2)
        XCTAssertNil(second)
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 0.2)
    }
}
