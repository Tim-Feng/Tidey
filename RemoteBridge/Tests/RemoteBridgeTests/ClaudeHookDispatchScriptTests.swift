import XCTest
@testable import RemoteBridge

// Executes the REAL wrapper dispatch script (Resources/bin/claude-hook-dispatch)
// and validates the journal contract: one compact JSONL envelope per event,
// multiline payloads never break framing, concurrent hook processes never
// interleave partial lines.
final class ClaudeHookDispatchScriptTests: XCTestCase {
    private var directory: URL!
    private var scriptURL: URL!
    private var journalURL: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeHookDispatchScriptTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        journalURL = directory.appendingPathComponent("journal.jsonl", isDirectory: false)

        let repoScript = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // RemoteBridgeTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // RemoteBridge
            .deletingLastPathComponent()  // repo root
            .appendingPathComponent("Resources/bin/claude-hook-dispatch", isDirectory: false)
        scriptURL = directory.appendingPathComponent("claude-hook-dispatch", isDirectory: false)
        try FileManager.default.copyItem(at: repoScript, to: scriptURL)
        let repoLifecycleHelper = repoScript.deletingLastPathComponent()
            .appendingPathComponent("claude-hook-journal-lifecycle", isDirectory: false)
        let lifecycleHelperURL = directory
            .appendingPathComponent("claude-hook-journal-lifecycle", isDirectory: false)
        try FileManager.default.copyItem(at: repoLifecycleHelper, to: lifecycleHelperURL)
        // Stub tidey CLI so dispatch has a forwarding target.
        let stubTidey = directory.appendingPathComponent("tidey", isDirectory: false)
        try "#!/bin/sh\ncat > /dev/null\nexit 0\n".write(to: stubTidey, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stubTidey.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    @discardableResult
    private func runDispatch(event: String, stdin: String, epoch: String = "42-1000") throws -> Int32 {
        let process = Process()
        process.executableURL = scriptURL
        process.arguments = [event, journalURL.path, epoch]
        let stdinPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        stdinPipe.fileHandleForWriting.write(Data(stdin.utf8))
        try stdinPipe.fileHandleForWriting.close()
        process.waitUntilExit()
        return process.terminationStatus
    }

    private func journalLines() throws -> [String] {
        let content = (try? String(contentsOf: journalURL, encoding: .utf8)) ?? ""
        return content.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    func testMultilinePrettyPrintedPayloadStaysOneJournalLine() throws {
        let prettyPayload = """
        {
          "session_id": "session-1",
          "tool_name": "Bash",
          "tool_input": {
            "command": "echo \\"hi\\"\\nls"
          }
        }
        """
        XCTAssertEqual(try runDispatch(event: "permission-request", stdin: prettyPayload), 0)

        let lines = try journalLines()
        XCTAssertEqual(lines.count, 1, "multiline payload must not break line framing")
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any])
        XCTAssertEqual(object["v"] as? Int, 3)
        XCTAssertEqual(object["event"] as? String, "permission-request")
        XCTAssertEqual(object["epoch"] as? String, "42-1000")
        XCTAssertNotNil(object["event_id"] as? String)
        XCTAssertNotNil(object["ts"] as? String)
        // Round-trip: the base64 payload decodes back to the exact stdin JSON.
        let b64 = try XCTUnwrap(object["payload_b64"] as? String)
        let decoded = try XCTUnwrap(Data(base64Encoded: b64))
        XCTAssertEqual(String(decoding: decoded, as: UTF8.self), prettyPayload)
        let payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: decoded) as? [String: Any])
        XCTAssertEqual(payload["session_id"] as? String, "session-1")
    }

    func testConcurrentDispatchersProduceWholeValidLines() throws {
        let writers = 16
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "dispatch-writers", attributes: .concurrent)
        let statusLock = NSLock()
        var statuses = [Int32]()
        for index in 0..<writers {
            group.enter()
            queue.async {
                defer { group.leave() }
                let status = (try? self.runDispatch(
                    event: "permission-request",
                    stdin: #"{"session_id":"session-1","index":\#(index)}"#)) ?? -1
                statusLock.lock()
                statuses.append(status)
                statusLock.unlock()
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 20), .success)
        XCTAssertEqual(statuses.count, writers)
        XCTAssertTrue(statuses.allSatisfy { $0 == 0 }, "dispatch statuses: \(statuses)")

        let lines = try journalLines()
        XCTAssertEqual(lines.count, writers)
        var eventIDs = Set<String>()
        var indices = Set<Int>()
        for line in lines {
            let object = try XCTUnwrap(
                try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                "interleaved/partial journal line: \(line)")
            if let eventID = object["event_id"] as? String {
                eventIDs.insert(eventID)
            }
            if let b64 = object["payload_b64"] as? String,
               let data = Data(base64Encoded: b64),
               let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let index = payload["index"] as? Int {
                indices.insert(index)
            }
        }
        XCTAssertEqual(eventIDs.count, writers, "event ids must be unique per delivery")
        XCTAssertEqual(indices.count, writers, "every writer's payload must survive intact")
    }

    // seq and append order must be IDENTICAL for every writer — allocating
    // seq outside the append's critical section would let writer B's
    // append land before writer A's even though A allocated a smaller seq.
    func testConcurrentWritersSeqOrderMatchesFileAppendOrder() throws {
        let writers = 24
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "dispatch-seq-writers", attributes: .concurrent)
        let statusLock = NSLock()
        var statuses = [Int32]()
        for index in 0..<writers {
            group.enter()
            queue.async {
                defer { group.leave() }
                let status = (try? self.runDispatch(
                    event: "permission-request",
                    stdin: #"{"session_id":"session-1","index":\#(index)}"#)) ?? -1
                statusLock.lock()
                statuses.append(status)
                statusLock.unlock()
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 20), .success)
        XCTAssertEqual(statuses.count, writers)
        XCTAssertTrue(statuses.allSatisfy { $0 == 0 }, "dispatch statuses: \(statuses)")

        let lines = try journalLines()
        XCTAssertEqual(lines.count, writers)
        let seqs = try lines.map { line -> Int in
            let object = try XCTUnwrap(
                try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            return try XCTUnwrap(object["seq"] as? Int)
        }
        XCTAssertEqual(seqs, seqs.sorted(),
                       "file append order diverged from allocated seq order: \(seqs)")
        XCTAssertEqual(Set(seqs).count, writers, "seq must be unique per writer, no gaps skipped as duplicates")
        XCTAssertEqual(Set(seqs), Set(1...writers), "seq must be a dense 1...N sequence")
    }

    func testEmptyStdinProducesNullishPayloadEnvelope() throws {
        XCTAssertEqual(try runDispatch(event: "notification-idle", stdin: ""), 0)
        let lines = try journalLines()
        XCTAssertEqual(lines.count, 1)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any])
        XCTAssertEqual(object["event"] as? String, "notification-idle")
        XCTAssertEqual(object["payload_b64"] as? String, "")
    }

    // MARK: - Implicit resume: lazy discovery of session id + registry file

    private func runDispatchDiscovery(event: String,
                                      stdin: String,
                                      epoch: String,
                                      registryRoot: URL,
                                      workspaceID: String? = "workspace-1") throws -> Int32 {
        let process = Process()
        process.executableURL = scriptURL
        process.arguments = [event, "", epoch, registryRoot.path]
        var environment = ProcessInfo.processInfo.environment
        if let workspaceID {
            environment["TIDEY_WORKSPACE_ID"] = workspaceID
        }
        environment["TIDEY_CLAUDE_WRAPPER_PID"] = "4242"
        process.environment = environment
        let stdinPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        stdinPipe.fileHandleForWriting.write(Data(stdin.utf8))
        try stdinPipe.fileHandleForWriting.close()
        process.waitUntilExit()
        return process.terminationStatus
    }

    func testImplicitResumeDiscoversSessionIDFromPayloadAndCreatesJournalAndRegistry() throws {
        let registryRoot = directory.appendingPathComponent("registry", isDirectory: true)
        try FileManager.default.createDirectory(at: registryRoot, withIntermediateDirectories: true)

        XCTAssertEqual(
            try runDispatchDiscovery(event: "session-start",
                                     stdin: #"{"session_id":"discovered-session-1","cwd":"/tmp/proj"}"#,
                                     epoch: "77-5000",
                                     registryRoot: registryRoot),
            0)

        let journalURL = registryRoot.appendingPathComponent("claude-hooks-discovered-session-1.jsonl")
        let markerURL = registryRoot.appendingPathComponent("claude-hooks-discovered-session-1.epoch")
        let registryURL = registryRoot.appendingPathComponent("claude-discovered-session-1.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: journalURL.path),
                      "journal must be created at the DISCOVERED session id path")
        XCTAssertTrue(FileManager.default.fileExists(atPath: registryURL.path),
                      "registry file must be created once the real session id is known")
        XCTAssertEqual(try String(contentsOf: markerURL, encoding: .utf8), "77-5000",
                       "lazy discovery must claim the journal through the production lifecycle helper")

        let journalLine = try XCTUnwrap(
            try String(contentsOf: journalURL, encoding: .utf8)
                .split(separator: "\n", omittingEmptySubsequences: true).first)
        let envelope = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(journalLine.utf8)) as? [String: Any])
        XCTAssertEqual(envelope["event"] as? String, "session-start")
        XCTAssertEqual(envelope["epoch"] as? String, "77-5000")

        let registry = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: Data(contentsOf: registryURL)) as? [String: Any])
        XCTAssertEqual(registry["session_id"] as? String, "discovered-session-1")
        XCTAssertEqual(registry["workspace_id"] as? String, "workspace-1")
        XCTAssertEqual(registry["cwd"] as? String, "/tmp/proj")

        // A SECOND hook event for the SAME (now-known) session appends to
        // the SAME journal, still claimed by the same epoch.
        XCTAssertEqual(
            try runDispatchDiscovery(event: "notification-permission",
                                     stdin: #"{"session_id":"discovered-session-1"}"#,
                                     epoch: "77-5000",
                                     registryRoot: registryRoot),
            0)
        let allLines = try String(contentsOf: journalURL, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertEqual(allLines.count, 2)
    }

    func testOldWrapperCleanupAfterNewWrapperStartsDoesNotDeleteNewJournal() throws {
        // Mirrors the EXACT production claim/cleanup functions (sourced by
        // both the wrapper and this test) — not a duplicated reimplementation.
        let lifecycleScript = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/bin/claude-hook-journal-lifecycle", isDirectory: false)
        let journal = directory.appendingPathComponent("claude-hooks-session-x.jsonl", isDirectory: false)
        let marker = directory.appendingPathComponent("claude-hooks-session-x.epoch", isDirectory: false)
        try "old-line\n".write(to: journal, atomically: true, encoding: .utf8)

        func run(_ command: String) throws -> Int32 {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = ["-c", command]
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        }

        // Old wrapper (epoch 100) claims, then a NEW wrapper (epoch 200)
        // resumes the same session and re-claims the marker.
        XCTAssertEqual(
            try run("source \(shellQuote(lifecycleScript.path)); claude_hook_journal_claim \(shellQuote(marker.path)) '100-1000'"),
            0)
        XCTAssertEqual(
            try run("source \(shellQuote(lifecycleScript.path)); claude_hook_journal_claim \(shellQuote(marker.path)) '200-2000'"),
            0)
        try "new-line\n".write(to: journal, atomically: false, encoding: .utf8)

        // Old wrapper's DELAYED cleanup (its own epoch, now stale) must not
        // remove the new wrapper's journal or marker.
        let cleanupStatus = try run(
            "source \(shellQuote(lifecycleScript.path)); claude_hook_journal_cleanup \(shellQuote(journal.path)) \(shellQuote(marker.path)) '100-1000'")
        XCTAssertNotEqual(cleanupStatus, 0, "old epoch's cleanup must decline (marker moved on)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: journal.path),
                      "old wrapper's cleanup deleted the NEW wrapper's journal")
        XCTAssertEqual(try? String(contentsOf: journal, encoding: .utf8), "new-line\n")
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))

        // The NEW wrapper's own cleanup (matching epoch) succeeds.
        let newCleanupStatus = try run(
            "source \(shellQuote(lifecycleScript.path)); claude_hook_journal_cleanup \(shellQuote(journal.path)) \(shellQuote(marker.path)) '200-2000'")
        XCTAssertEqual(newCleanupStatus, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: journal.path))
    }

    private func shellQuote(_ string: String) -> String {
        "'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
