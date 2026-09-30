import Darwin
import XCTest
@testable import RemoteBridge

// Executes the REAL Resources/bin/claude-hook-dispatch under /bin/bash (the
// only bash on the production Macs, 3.2) and pins the journal lock contract:
// the lock is a kernel flock that a killed holder cannot leave behind, it is
// released before forwarding to the tidey CLI, and a writer killed between
// the seq update and the append leaves a gap, never a duplicate seq.
final class ClaudeHookDispatchLockTests: XCTestCase {
    private var directory: URL!
    private var scriptURL: URL!
    private var lifecycleURL: URL!
    private var journalURL: URL!
    private var cliMarkerURL: URL!
    private var cliFDLeakURL: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeHookDispatchLockTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        journalURL = directory.appendingPathComponent("claude-hooks-session-1.jsonl", isDirectory: false)
        cliMarkerURL = directory.appendingPathComponent("cli-started", isDirectory: false)
        cliFDLeakURL = directory.appendingPathComponent("cli-saw-fd9", isDirectory: false)

        let binDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // RemoteBridgeTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // RemoteBridge
            .deletingLastPathComponent()  // repo root
            .appendingPathComponent("Resources/bin", isDirectory: true)
        scriptURL = directory.appendingPathComponent("claude-hook-dispatch", isDirectory: false)
        lifecycleURL = directory.appendingPathComponent("claude-hook-journal-lifecycle", isDirectory: false)
        try FileManager.default.copyItem(at: binDirectory.appendingPathComponent("claude-hook-dispatch"),
                                         to: scriptURL)
        try FileManager.default.copyItem(at: binDirectory.appendingPathComponent("claude-hook-journal-lifecycle"),
                                         to: lifecycleURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        try writeStubCLI(sleepSeconds: 0)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Harness

    /// Stub tidey CLI: records that it ran, records whether it inherited the
    /// journal lock fd (fd 9), then optionally sleeps.
    private func writeStubCLI(sleepSeconds: Int) throws {
        let stub = directory.appendingPathComponent("tidey", isDirectory: false)
        let script = """
        #!/bin/sh
        cat > /dev/null
        if [ -e /dev/fd/9 ]; then : > \(shellQuote(cliFDLeakURL.path)); fi
        : > \(shellQuote(cliMarkerURL.path))
        sleep \(sleepSeconds)
        exit 0

        """
        try script.write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
    }

    private func startDispatch(event: String = "post-tool-use",
                               stdin: String = #"{"session_id":"session-1"}"#,
                               interpreter: String = "/bin/bash",
                               environment extra: [String: String] = [:]) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: interpreter)
        process.arguments = interpreter.hasSuffix("/env")
            ? ["bash", scriptURL.path, event, journalURL.path, "42-1000"]
            : [scriptURL.path, event, journalURL.path, "42-1000"]
        var environment = ProcessInfo.processInfo.environment
        extra.forEach { environment[$0.key] = $0.value }
        process.environment = environment
        let stdinPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        stdinPipe.fileHandleForWriting.write(Data(stdin.utf8))
        try stdinPipe.fileHandleForWriting.close()
        return process
    }

    @discardableResult
    private func runDispatch(event: String = "post-tool-use",
                             interpreter: String = "/bin/bash",
                             environment: [String: String] = [:]) throws -> Int32 {
        let process = try startDispatch(event: event, interpreter: interpreter, environment: environment)
        process.waitUntilExit()
        return process.terminationStatus
    }

    private func runShell(_ command: String) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", command]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return (process.terminationStatus,
                String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }

    private func journalSeqs() throws -> [Int] {
        let content = (try? String(contentsOf: journalURL, encoding: .utf8)) ?? ""
        return try content.split(separator: "\n").map { line in
            let object = try XCTUnwrap(
                try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                "torn journal line: \(line)")
            return try XCTUnwrap(object["seq"] as? Int)
        }
    }

    private func waitForFile(_ url: URL, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: url.path) {
                return true
            }
            usleep(10_000)
        }
        return false
    }

    /// Non-blocking probe of the journal lock from a separate process.
    private func lockIsFree() throws -> Bool {
        let lockPath = shellQuote(journalURL.path + ".lock")
        return try runShell("exec 9>>\(lockPath); /usr/bin/lockf -s -t 0 9").status == 0
    }

    private func makePauseFIFO() throws -> URL {
        let fifo = directory.appendingPathComponent("pause.fifo", isDirectory: false)
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        return fifo
    }

    private func diagnosticsLines() -> [String] {
        let url = directory.appendingPathComponent("claude-hook-diagnostics.log", isDirectory: false)
        let content = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        return content.split(separator: "\n").map(String.init)
    }

    private func shellQuote(_ string: String) -> String {
        "'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - Tests

    func testSingleWriteStartsAtOneMatchesSeqFileAndPrintsNothing() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptURL.path, "stop", journalURL.path, "42-1000"]
        let stdinPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderrPipe
        try process.run()
        stdinPipe.fileHandleForWriting.write(Data(#"{"session_id":"session-1"}"#.utf8))
        try stdinPipe.fileHandleForWriting.close()
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(try journalSeqs(), [1])
        XCTAssertEqual(try String(contentsOf: URL(fileURLWithPath: journalURL.path + ".seq"), encoding: .utf8), "1")
        let stderr = String(decoding: stderrPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertEqual(stderr, "", "a hook must not print to Claude Code's terminal on a first write")
    }

    func testEnvResolvedBashRunsTheSameContract() throws {
        // Hooks exec the script through its `#!/usr/bin/env bash` shebang;
        // on the production Macs that resolves to /bin/bash 3.2.
        let versions = try runShell("/usr/bin/env bash -c 'echo ${BASH_VERSINFO[0]}'; /bin/bash -c 'echo ${BASH_VERSINFO[0]}'")
        XCTAssertEqual(versions.status, 0)
        XCTAssertEqual(try runDispatch(interpreter: "/usr/bin/env"), 0)
        XCTAssertEqual(try runDispatch(interpreter: "/bin/bash"), 0)
        XCTAssertEqual(try journalSeqs(), [1, 2])
    }

    func testFiftyConcurrentWritersProduceDenseOrderedSeqs() throws {
        let writers = 50
        var processes = [Process]()
        for index in 0..<writers {
            processes.append(try startDispatch(stdin: #"{"session_id":"session-1","index":\#(index)}"#))
        }
        processes.forEach { $0.waitUntilExit() }
        XCTAssertTrue(processes.allSatisfy { $0.terminationStatus == 0 })

        let seqs = try journalSeqs()
        XCTAssertEqual(seqs.count, writers, "a writer skipped its journal line")
        XCTAssertEqual(seqs, Array(1...writers), "seq must be dense and match append order")
        XCTAssertFalse(FileManager.default.fileExists(atPath: journalURL.path + ".seqlock"))
    }

    func testLockfLockOutlivesTheLockfProcess() throws {
        // The dispatcher relies on lockf(1) locking the open file named by
        // fd 9 and exiting while the SHELL keeps the lock.
        let lockPath = shellQuote(directory.appendingPathComponent("probe.lock").path)
        let result = try runShell("""
        exec 9>>\(lockPath); /usr/bin/lockf -s -t 1 9 || exit 10
        ( exec 8>>\(lockPath); /usr/bin/lockf -s -t 0 8 ) && exit 11
        exec 9>&-
        ( exec 8>>\(lockPath); /usr/bin/lockf -s -t 0 8 ) || exit 12
        exit 0
        """)
        XCTAssertEqual(result.status, 0, "10: no lock, 11: lock not held after lockf exited, 12: close did not release")
    }

    func testKilledLockHolderDoesNotBlockTheNextWriter() throws {
        let fifo = try makePauseFIFO()
        let marker = directory.appendingPathComponent("holder-in-lock", isDirectory: false)
        let holder = try startDispatch(environment: [
            "TIDEY_HOOK_TEST_PAUSE_AT": "in_lock",
            "TIDEY_HOOK_TEST_PAUSE_FIFO": fifo.path,
            "TIDEY_HOOK_TEST_PAUSE_MARKER": marker.path,
            "TIDEY_HOOK_TEST_PAUSE_SECONDS": "30",
        ])
        XCTAssertTrue(waitForFile(marker), "holder never reached the critical section")
        XCTAssertFalse(try lockIsFree(), "holder should own the journal lock")

        kill(holder.processIdentifier, SIGKILL)
        holder.waitUntilExit()

        let started = Date()
        XCTAssertEqual(try runDispatch(), 0)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2.5)
        XCTAssertEqual(try journalSeqs(), [1], "the next writer must get the lock and write")

        // Diagnostics: the killed pid has a start and no end, whatever the signal.
        let holderPID = String(holder.processIdentifier)
        let holderLines = diagnosticsLines().filter { $0.split(separator: " ").dropFirst(3).first.map(String.init) == holderPID }
        XCTAssertTrue(holderLines.contains { $0.contains(" start ") })
        XCTAssertFalse(holderLines.contains { $0.contains(" end ") })
    }

    func testLockIsReleasedBeforeForwardingToTheCLI() throws {
        try writeStubCLI(sleepSeconds: 5)
        let forwarder = try startDispatch()
        XCTAssertTrue(waitForFile(cliMarkerURL), "dispatcher never forwarded to the CLI")

        XCTAssertTrue(try lockIsFree(), "the CLI (or the dispatcher) still holds the journal lock")
        XCTAssertFalse(FileManager.default.fileExists(atPath: cliFDLeakURL.path),
                       "the CLI inherited the lock fd")

        try writeStubCLI(sleepSeconds: 0)
        let started = Date()
        XCTAssertEqual(try runDispatch(), 0)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        XCTAssertEqual(try journalSeqs(), [1, 2])

        forwarder.terminate()
        forwarder.waitUntilExit()
    }

    func testLockTimeoutSkipsTheWriteButStillForwardsWithoutTheLockFD() throws {
        let lockPath = shellQuote(journalURL.path + ".lock")
        let holder = Process()
        holder.executableURL = URL(fileURLWithPath: "/bin/bash")
        holder.arguments = ["-c", "exec 9>>\(lockPath); /usr/bin/lockf -s -t 1 9; exec sleep 10"]
        try holder.run()
        defer {
            holder.terminate()
            holder.waitUntilExit()
        }
        let deadline = Date().addingTimeInterval(5)
        while try lockIsFree(), Date() < deadline {
            usleep(20_000)
        }
        XCTAssertFalse(try lockIsFree())

        let started = Date()
        XCTAssertEqual(try runDispatch(), 0, "a skipped journal write must not fail the hook")
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertGreaterThanOrEqual(elapsed, 1.5)
        XCTAssertLessThan(elapsed, 4)
        XCTAssertEqual(try journalSeqs(), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: cliMarkerURL.path), "the CLI must still be called")
        XCTAssertFalse(FileManager.default.fileExists(atPath: cliFDLeakURL.path),
                       "the timeout path leaked the lock fd into the CLI")
        XCTAssertTrue(diagnosticsLines().contains { $0.contains("result=lock_timeout") })
    }

    func testWriterKilledAfterSeqUpdateLeavesAGapNotADuplicate() throws {
        XCTAssertEqual(try runDispatch(), 0)  // seq 1
        let fifo = try makePauseFIFO()
        let marker = directory.appendingPathComponent("holder-after-seq", isDirectory: false)
        let victim = try startDispatch(environment: [
            "TIDEY_HOOK_TEST_PAUSE_AT": "after_seq",
            "TIDEY_HOOK_TEST_PAUSE_FIFO": fifo.path,
            "TIDEY_HOOK_TEST_PAUSE_MARKER": marker.path,
            "TIDEY_HOOK_TEST_PAUSE_SECONDS": "30",
        ])
        XCTAssertTrue(waitForFile(marker))
        kill(victim.processIdentifier, SIGKILL)
        victim.waitUntilExit()

        XCTAssertEqual(try runDispatch(), 0)
        XCTAssertEqual(try journalSeqs(), [1, 3], "the killed writer's seq 2 must be skipped, not reused")
    }

    func testStaleTempSeqFileAndLegacySeqlockDirectoryDoNotBlockWrites() throws {
        try "7".write(to: URL(fileURLWithPath: journalURL.path + ".seq.tmp.99999"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(atPath: journalURL.path + ".seqlock",
                                                withIntermediateDirectories: false)
        XCTAssertEqual(try runDispatch(), 0)
        XCTAssertEqual(try journalSeqs(), [1])
    }

    func testDiagnosticsRecordStartJournalAndEndForACompletedHook() throws {
        XCTAssertEqual(try runDispatch(event: "stop"), 0)
        let lines = diagnosticsLines()
        guard lines.count == 3 else {
            return XCTFail("expected start/journal/end diagnostics, got \(lines)")
        }
        XCTAssertTrue(lines[0].contains(" start stop "))
        XCTAssertTrue(lines[1].contains(" journal stop ") && lines[1].hasSuffix("result=ok"))
        XCTAssertTrue(lines[2].contains(" end stop ") && lines[2].hasSuffix("cli=0"))
    }

    func testLifecycleCleanupRemovesLockSeqAndTempFiles() throws {
        XCTAssertEqual(try runDispatch(), 0)
        let marker = directory.appendingPathComponent("claude-hooks-session-1.epoch", isDirectory: false)
        try "42-1000".write(to: marker, atomically: true, encoding: .utf8)
        try "3".write(to: URL(fileURLWithPath: journalURL.path + ".seq.tmp.4242"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(atPath: journalURL.path + ".seqlock",
                                                withIntermediateDirectories: false)

        let result = try runShell(
            "source \(shellQuote(lifecycleURL.path)); claude_hook_journal_cleanup \(shellQuote(journalURL.path)) \(shellQuote(marker.path)) '42-1000'")
        XCTAssertEqual(result.status, 0)
        for suffix in ["", ".seq", ".lock", ".seq.tmp.4242", ".seqlock"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: journalURL.path + suffix),
                           "cleanup left \(suffix.isEmpty ? "the journal" : suffix)")
        }
    }
}
