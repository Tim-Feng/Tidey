import XCTest
@testable import RemoteBridge

final class CodexTranscriptSessionTests: XCTestCase {
    func testProcessTreeResolutionUsesBoundedCommandTimeouts() throws {
        let rootDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexTranscriptSessionTests-\(UUID().uuidString)", isDirectory: true)
        let directory = rootDirectory
            .appendingPathComponent(".codex/sessions/2026/07/22", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootDirectory) }

        let rolloutURL = directory.appendingPathComponent("rollout-child.jsonl", isDirectory: false)
        try (makeCodexMessageLine(role: "assistant", content: "resolved through child process") + "\n")
            .write(to: rolloutURL, atomically: true, encoding: .utf8)

        let rootPID: Int32 = 41_001
        let childPID: Int32 = 41_002
        let recorder = CodexTranscriptProcessCallRecorder()
        let processRunner: CodexTranscriptProcessRunner = { executablePath, arguments, timeout in
            recorder.append(executablePath: executablePath,
                            arguments: arguments,
                            timeout: timeout)
            switch (executablePath, arguments) {
            case ("/usr/sbin/lsof", ["-Fn", "-p", String(rootPID)]):
                return BoundedProcessResult(terminationStatus: 0,
                                            standardOutput: Data(),
                                            standardError: Data())
            case ("/usr/bin/pgrep", ["-P", String(rootPID)]):
                return BoundedProcessResult(terminationStatus: 0,
                                            standardOutput: Data("\(childPID)\n".utf8),
                                            standardError: Data())
            case ("/usr/sbin/lsof", ["-Fn", "-p", String(childPID)]):
                return BoundedProcessResult(terminationStatus: 0,
                                            standardOutput: Data("n\(rolloutURL.path)\n".utf8),
                                            standardError: Data())
            default:
                return nil
            }
        }
        let record = AgentSessionRegistryRecord(version: 1,
                                                vendor: "codex",
                                                workspaceID: "workspace",
                                                sessionID: "session",
                                                panelID: "panel",
                                                pid: rootPID,
                                                cwd: "/tmp",
                                                createdAt: "2026-05-15T00:00:00Z",
                                                transcriptPath: nil)
        let hub = AgentEventHub()
        let session = CodexTranscriptSession(record: record,
                                             fileManager: .default,
                                             hub: hub,
                                             processRunner: processRunner)
        session.start()
        defer { session.stop() }

        XCTAssertTrue(waitUntil {
            hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 10)
                .events.contains { $0.text == "resolved through child process" }
        })
        XCTAssertEqual(recorder.calls, [
            CodexTranscriptProcessCall(executablePath: "/usr/sbin/lsof",
                                       arguments: ["-Fn", "-p", String(rootPID)],
                                       timeout: 2),
            CodexTranscriptProcessCall(executablePath: "/usr/bin/pgrep",
                                       arguments: ["-P", String(rootPID)],
                                       timeout: 1),
            CodexTranscriptProcessCall(executablePath: "/usr/sbin/lsof",
                                       arguments: ["-Fn", "-p", String(childPID)],
                                       timeout: 2),
        ])
    }

    func testCodexBootstrapContextUserMessagesAreAlwaysFiltered() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexTranscriptSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let transcriptURL = directory.appendingPathComponent("rollout-session.jsonl", isDirectory: false)
        let context = """
        # AGENTS.md instructions for /Users/timfeng

        <INSTRUCTIONS>
        # 全域語氣規則

        全域回覆必須遵守：

        - `/Users/timfeng/GitHub/life-system/.agents/voice-and-usage.md`
        </INSTRUCTIONS>

        <environment_context>
          <cwd>/Users/timfeng</cwd>
          <shell>zsh</shell>
        </environment_context>
        """
        let lines = [
            makeCodexMessageLine(role: "assistant", content: "Ready."),
            makeCodexMessageLine(role: "user", content: context),
            makeCodexMessageLine(role: "user", content: "Test from remote"),
        ].joined(separator: "\n") + "\n"
        try lines.write(to: transcriptURL, atomically: true, encoding: .utf8)

        let hub = AgentEventHub()
        let session = CodexTranscriptSession(record: makeRecord(transcriptPath: transcriptURL.path),
                                             fileManager: .default,
                                             hub: hub)
        session.start()
        defer { session.stop() }

        XCTAssertTrue(waitUntil {
            let result = hub.fetch(workspaceID: "workspace",
                                   sessionID: "session",
                                   limit: 10,
                                   beforeSeq: nil,
                                   afterSeq: nil)
            return result.events.contains { $0.text == "Test from remote" }
        })

        let result = hub.fetch(workspaceID: "workspace",
                               sessionID: "session",
                               limit: 10,
                               beforeSeq: nil,
                               afterSeq: nil)
        let userTexts = result.events
            .filter { $0.type == .userMessage }
            .compactMap(\.text)
        XCTAssertEqual(userTexts, ["Test from remote"])
        XCTAssertFalse(result.events.contains { ($0.text ?? "").contains("AGENTS.md instructions") })
        XCTAssertFalse(result.events.contains { ($0.text ?? "").contains("<environment_context>") })
    }

    func testCodexStandaloneEnvironmentContextUserMessagesAreAlwaysFiltered() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexTranscriptSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let transcriptURL = directory.appendingPathComponent("rollout-session.jsonl", isDirectory: false)
        let firstContext = """
        <environment_context>
          <shell>zsh</shell>
          <current_date>2026-05-01</current_date>
          <timezone>Asia/Taipei</timezone>
        </environment_context>
        """
        let secondContext = """
        <environment_context>
          <shell>zsh</shell>
          <current_date>2026-05-03</current_date>
          <timezone>Asia/Taipei</timezone>
        </environment_context>
        """
        let lines = [
            makeCodexMessageLine(role: "assistant", content: "Ready."),
            makeCodexMessageLine(role: "user", content: firstContext),
            makeCodexMessageLine(role: "user", content: "Actual user message"),
            makeCodexMessageLine(role: "user", content: secondContext),
        ].joined(separator: "\n") + "\n"
        try lines.write(to: transcriptURL, atomically: true, encoding: .utf8)

        let hub = AgentEventHub()
        let session = CodexTranscriptSession(record: makeRecord(transcriptPath: transcriptURL.path),
                                             fileManager: .default,
                                             hub: hub)
        session.start()
        defer { session.stop() }

        XCTAssertTrue(waitUntil {
            let result = hub.fetch(workspaceID: "workspace",
                                   sessionID: "session",
                                   limit: 10,
                                   beforeSeq: nil,
                                   afterSeq: nil)
            return result.events.contains { $0.text == "Actual user message" }
        })

        let result = hub.fetch(workspaceID: "workspace",
                               sessionID: "session",
                               limit: 10,
                               beforeSeq: nil,
                               afterSeq: nil)
        let userTexts = result.events
            .filter { $0.type == .userMessage }
            .compactMap(\.text)
        XCTAssertEqual(userTexts, ["Actual user message"])
        XCTAssertFalse(result.events.contains { ($0.text ?? "").contains("<current_date>2026-05-01</current_date>") })
        XCTAssertFalse(result.events.contains { ($0.text ?? "").contains("<current_date>2026-05-03</current_date>") })
    }

    func testAppServerResumeThreadMetadataPublishesUnderInstanceSession() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexTranscriptSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let transcriptURL = directory.appendingPathComponent("rollout-thread-session.jsonl", isDirectory: false)
        let lines = [
            makeCodexSessionMetaLine(sessionID: "thread-session", cliVersion: "999.0.0"),
        ].joined(separator: "\n") + "\n"
        try lines.write(to: transcriptURL, atomically: true, encoding: .utf8)

        let hub = AgentEventHub()
        let session = CodexTranscriptSession(record: makeRecord(transcriptPath: transcriptURL.path,
                                                                sessionID: "instance-session",
                                                                threadID: "thread-session",
                                                                resumeThreadID: "thread-session"),
                                             fileManager: .default,
                                             hub: hub)
        session.start()
        defer { session.stop() }

        XCTAssertTrue(waitUntil {
            let result = hub.fetch(workspaceID: "workspace",
                                   sessionID: "instance-session",
                                   limit: 10,
                                   beforeSeq: nil,
                                   afterSeq: nil)
            return result.events.contains { $0.type == .status }
        })

        let result = hub.fetch(workspaceID: "workspace",
                               sessionID: "instance-session",
                               limit: 10,
                               beforeSeq: nil,
                               afterSeq: nil)
        let status = try XCTUnwrap(result.events.first { $0.type == .status })
        XCTAssertEqual(status.sessionID, "instance-session")
        XCTAssertEqual(status.eventID, "status:instance-session:\(status.seq):unsupported-version:999.0.0")
    }

    func testAppServerTranscriptIdentityUpdateTailsNewRollout() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexTranscriptSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let threadA = "019d70fe-fd27-7a12-a3f7-9c89ae5048b6"
        let threadB = "019ec8cb-fd27-7a12-a3f7-9c89ae5048b6"
        let transcriptA = directory.appendingPathComponent("rollout-a-\(threadA).jsonl", isDirectory: false)
        let transcriptB = directory.appendingPathComponent("rollout-b-\(threadB).jsonl", isDirectory: false)
        try ([
            makeCodexSessionMetaLine(sessionID: threadA, cliVersion: "0.1.0"),
            makeCodexMessageLine(role: "assistant", content: "old thread"),
        ].joined(separator: "\n") + "\n").write(to: transcriptA, atomically: true, encoding: .utf8)
        try ([
            makeCodexSessionMetaLine(sessionID: threadB, cliVersion: "0.1.0"),
            makeCodexMessageLine(role: "assistant", content: "new live thread"),
        ].joined(separator: "\n") + "\n").write(to: transcriptB, atomically: true, encoding: .utf8)

        let hub = AgentEventHub()
        let session = CodexTranscriptSession(record: makeRecord(transcriptPath: transcriptA.path,
                                                                sessionID: "instance-session",
                                                                threadID: threadA,
                                                                resumeThreadID: threadA),
                                             fileManager: .default,
                                             hub: hub)
        session.start()
        defer { session.stop() }

        XCTAssertTrue(waitUntil {
            let result = hub.fetch(workspaceID: "workspace",
                                   sessionID: "instance-session",
                                   limit: 10)
            return result.events.contains { $0.text == "old thread" }
        })

        session.update(record: makeRecord(transcriptPath: transcriptB.path,
                                          sessionID: "instance-session",
                                          threadID: threadB,
                                          resumeThreadID: threadA))

        XCTAssertTrue(waitUntil {
            let result = hub.fetch(workspaceID: "workspace",
                                   sessionID: "instance-session",
                                   limit: 10)
            return result.events.contains { $0.text == "new live thread" }
        })
        let result = hub.fetch(workspaceID: "workspace",
                               sessionID: "instance-session",
                               limit: 10)
        let oldEvent = try XCTUnwrap(result.events.first { $0.text == "old thread" })
        let newEvent = try XCTUnwrap(result.events.first { $0.text == "new live thread" })
        XCTAssertGreaterThan(newEvent.seq, oldEvent.seq)
    }

    func testCodexBackfillOlderLinesKeepOriginalCursorPositions() throws {
        // More lines than the bootstrap tail limit: the initial load skips
        // the oldest lines; backfill must store them at their ORIGINAL
        // cursor positions (reachable via before_seq, invisible to an
        // already-advanced after_seq).
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexTranscriptSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcriptURL = directory.appendingPathComponent("rollout-session.jsonl", isDirectory: false)

        let totalLines = transcriptBootstrapLineLimit + 20
        var lines = [String]()
        for index in 0..<totalLines {
            lines.append(makeCodexMessageLine(role: "assistant", content: "line-\(index)"))
        }
        try (lines.joined(separator: "\n") + "\n").write(to: transcriptURL, atomically: true, encoding: .utf8)

        let hub = AgentEventHub()
        let session = CodexTranscriptSession(record: makeRecord(transcriptPath: transcriptURL.path),
                                             fileManager: .default,
                                             hub: hub)
        session.start()
        defer { session.stop() }

        XCTAssertTrue(waitUntil {
            hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 1).events.first?.text == "line-\(totalLines - 1)"
        }, "newest=\(String(describing: hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 3).events.map { ($0.eventID, $0.seq, $0.text ?? "-") }))")
        let initial = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 5000)
        XCTAssertFalse(initial.events.contains { $0.text == "line-0" },
                       "the oldest lines must be outside the bootstrap window; count=\(initial.events.count) oldest=\(String(describing: initial.events.first?.text))")
        let lineEvents = initial.events.filter { ($0.text ?? "").hasPrefix("line-") }
        let oldestLoadedSeq = lineEvents.map(\.seq).min() ?? 0
        let newestSeq = initial.events.map(\.seq).max() ?? 0

        XCTAssertTrue(session.backfill(beforeSeq: oldestLoadedSeq, limit: 50))
        XCTAssertTrue(waitUntil {
            hub.fetch(workspaceID: "workspace",
                      sessionID: "session",
                      limit: 5000,
                      beforeSeq: oldestLoadedSeq).events.isEmpty == false
        })

        let older = hub.fetch(workspaceID: "workspace",
                              sessionID: "session",
                              limit: 5000,
                              beforeSeq: oldestLoadedSeq)
        XCTAssertTrue(older.events.allSatisfy { $0.seq < oldestLoadedSeq },
                      "backfilled history must keep seqs below the requested before_seq")
        XCTAssertTrue(older.events.contains { ($0.text ?? "").hasPrefix("line-") })

        let catchUp = hub.fetch(workspaceID: "workspace",
                                sessionID: "session",
                                limit: 5000,
                                afterSeq: newestSeq)
        XCTAssertTrue(catchUp.events.isEmpty,
                      "backfilled history must not appear as new live events, got \(catchUp.events.map { ($0.eventID, $0.seq) })")
    }

    private final class RecordingCommandSender: TideyCommandSending {
        private let lock = NSLock()
        private var storage = [String]()
        func send(command: String) throws {
            lock.lock()
            storage.append(command)
            lock.unlock()
        }
        func commands() -> [String] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }

    private func makeCodexTaskLine(type: String, turnID: String, message: String? = nil) -> String {
        var payload: [String: Any] = ["type": type, "turn_id": turnID]
        if let message {
            payload["last_agent_message"] = message
        }
        let object: [String: Any] = [
            "type": "event_msg",
            "timestamp": "2026-05-15T00:00:00Z",
            "payload": payload,
        ]
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(data: data, encoding: .utf8)!
    }

    func testCodexBackfillDoesNotRunSidebarOrShellStateSideEffects() throws {
        // Historical task_started/task_complete lines loaded by backfill may
        // only fill history: no shell-state change, no sidebar messages, no
        // notifications.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexTranscriptSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcriptURL = directory.appendingPathComponent("rollout-session.jsonl", isDirectory: false)

        var lines = [String]()
        // OLD region (outside the bootstrap tail): historical turn activity.
        for index in 0..<20 {
            lines.append(makeCodexTaskLine(type: "task_started", turnID: "old-turn-\(index)"))
            lines.append(makeCodexTaskLine(type: "task_complete", turnID: "old-turn-\(index)", message: "done \(index)"))
        }
        // Filler so the old region is beyond the bootstrap window.
        for index in 0..<transcriptBootstrapLineLimit {
            lines.append(makeCodexMessageLine(role: "assistant", content: "line-\(index)"))
        }
        try (lines.joined(separator: "\n") + "\n").write(to: transcriptURL, atomically: true, encoding: .utf8)

        let hub = AgentEventHub()
        let sender = RecordingCommandSender()
        let session = CodexTranscriptSession(record: makeRecord(transcriptPath: transcriptURL.path),
                                             fileManager: .default,
                                             hub: hub,
                                             socketClient: sender)
        session.start()
        defer { session.stop() }
        XCTAssertTrue(waitUntil {
            hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 1).events.first?.text == "line-\(transcriptBootstrapLineLimit - 1)"
        })
        let commandsBeforeBackfill = sender.commands()

        let initial = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 5000)
        let lineEvents = initial.events.filter { ($0.text ?? "").hasPrefix("line-") }
        let oldestLoadedSeq = lineEvents.map(\.seq).min() ?? 0
        XCTAssertTrue(session.backfill(beforeSeq: oldestLoadedSeq, limit: 100))
        XCTAssertTrue(waitUntil {
            hub.fetch(workspaceID: "workspace",
                      sessionID: "session",
                      limit: 5000,
                      beforeSeq: oldestLoadedSeq).events.isEmpty == false
        })

        XCTAssertEqual(sender.commands(), commandsBeforeBackfill,
                       "backfill must not send ANY sidebar/notification command, got new: \(sender.commands().dropFirst(commandsBeforeBackfill.count))")
    }

    func testCodexBackfillDoesNotConsumeLiveSubmitEchoRegistry() throws {
        // A live submit is registered; a backfilled OLD user message with the
        // same normalized text must not consume it — the true live echo must
        // still get its client_request_id.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexTranscriptSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcriptURL = directory.appendingPathComponent("rollout-session.jsonl", isDirectory: false)

        var lines = [String]()
        lines.append(makeCodexMessageLine(role: "user", content: "repeat me"))
        for index in 0..<transcriptBootstrapLineLimit {
            lines.append(makeCodexMessageLine(role: "assistant", content: "line-\(index)"))
        }
        try (lines.joined(separator: "\n") + "\n").write(to: transcriptURL, atomically: true, encoding: .utf8)

        let hub = AgentEventHub()
        let registry = ChatSubmitEchoRegistry()
        registry.register(workspaceID: "workspace",
                          panelID: "panel",
                          sessionID: "session",
                          vendor: "codex",
                          text: "repeat me",
                          clientRequestID: "client-live")
        let session = CodexTranscriptSession(record: makeRecord(transcriptPath: transcriptURL.path),
                                             fileManager: .default,
                                             hub: hub,
                                             chatSubmitEchoRegistry: registry)
        session.start()
        defer { session.stop() }
        XCTAssertTrue(waitUntil {
            hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 1).events.first?.text == "line-\(transcriptBootstrapLineLimit - 1)"
        })
        let initial = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 5000)
        let oldestLoadedSeq = initial.events.filter { ($0.text ?? "").hasPrefix("line-") }.map(\.seq).min() ?? 0
        XCTAssertTrue(session.backfill(beforeSeq: oldestLoadedSeq, limit: 50))
        XCTAssertTrue(waitUntil {
            hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 5000, beforeSeq: oldestLoadedSeq).events.isEmpty == false
        })

        // The backfilled history must NOT have consumed the live record...
        XCTAssertEqual(registry.snapshot().map(\.clientRequestID), ["client-live"],
                       "backfill must not consume the live echo registry")
        let historicalEcho = hub.fetch(workspaceID: "workspace",
                                       sessionID: "session",
                                       limit: 5000,
                                       beforeSeq: oldestLoadedSeq).events.first { $0.text == "repeat me" }
        XCTAssertNil(historicalEcho?.metadata?["client_request_id"],
                     "historical storage carries no live submit correlation")

        // ...and the TRUE live echo still resolves it.
        let handle = try FileHandle(forWritingTo: transcriptURL)
        handle.seekToEndOfFile()
        handle.write((makeCodexMessageLine(role: "user", content: "repeat me") + "\n").data(using: .utf8)!)
        try handle.close()
        XCTAssertTrue(waitUntil {
            hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 10).events.contains {
                $0.text == "repeat me" && $0.metadata?["client_request_id"] == "client-live"
            }
        }, "the live echo must still receive its client_request_id after a backfill of the same text")
    }

    private func makeCodexFunctionCallOutputLine(callID: String, output: String) -> String {
        let object: [String: Any] = [
            "type": "response_item",
            "timestamp": "2026-05-15T00:00:00Z",
            "payload": ["type": "function_call_output", "call_id": callID, "output": output],
        ]
        return String(data: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), encoding: .utf8)!
    }

    private func makeCodexExecCommandEndLine(callID: String, output: String) -> String {
        let object: [String: Any] = [
            "type": "event_msg",
            "timestamp": "2026-05-15T00:05:00Z",
            "payload": ["type": "exec_command_end", "call_id": callID, "aggregated_output": output],
        ]
        return String(data: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), encoding: .utf8)!
    }

    private func makeCodexSessionMetaVersionLine(version: String) -> String {
        let object: [String: Any] = [
            "type": "session_meta",
            "timestamp": "2026-05-15T00:06:00Z",
            "payload": ["id": "session", "cli_version": version],
        ]
        return String(data: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), encoding: .utf8)!
    }

    private func makeCodexAgentMessageLine(text: String, timestamp: String = "2026-05-15T00:02:00Z") -> String {
        let object: [String: Any] = [
            "type": "event_msg",
            "timestamp": timestamp,
            "payload": ["type": "agent_message", "message": text, "phase": "final_answer"],
        ]
        return String(data: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), encoding: .utf8)!
    }

    func testCodexBackfillIsIsolatedParserTransaction() throws {
        // Historical page: user echo, unsupported V, assistant K,
        // function_call_output X, task states. After the backfill, LIVE
        // events with colliding parser keys (same dedupe key/new line, same
        // call id, same version, task states) must all still publish; the
        // live echo still consumes the registry; backfill itself delivers
        // nothing live and sends no sidebar commands.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexTranscriptSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcriptURL = directory.appendingPathComponent("rollout-session.jsonl", isDirectory: false)

        var lines = [String]()
        lines.append(makeCodexMessageLine(role: "user", content: "repeat me"))
        lines.append(makeCodexSessionMetaVersionLine(version: "9.9.9"))
        lines.append(makeCodexAgentMessageLine(text: "K"))
        lines.append(makeCodexFunctionCallOutputLine(callID: "call_X", output: "historical output"))
        lines.append(makeCodexTaskLine(type: "task_started", turnID: "old-turn"))
        lines.append(makeCodexTaskLine(type: "task_complete", turnID: "old-turn", message: "done"))
        for index in 0..<transcriptBootstrapLineLimit {
            lines.append(makeCodexMessageLine(role: "assistant", content: "line-\(index)"))
        }
        try (lines.joined(separator: "\n") + "\n").write(to: transcriptURL, atomically: true, encoding: .utf8)

        let hub = AgentEventHub()
        let sender = RecordingCommandSender()
        let registry = ChatSubmitEchoRegistry()
        registry.register(workspaceID: "workspace", panelID: "panel", sessionID: "session",
                          vendor: "codex", text: "repeat me", clientRequestID: "client-live")
        let session = CodexTranscriptSession(record: makeRecord(transcriptPath: transcriptURL.path),
                                             fileManager: .default,
                                             hub: hub,
                                             socketClient: sender,
                                             chatSubmitEchoRegistry: registry)
        session.start()
        defer { session.stop() }
        XCTAssertTrue(waitUntil {
            hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 1).events.first?.text == "line-\(transcriptBootstrapLineLimit - 1)"
        })
        let boundary = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 5000)
            .events.filter { ($0.text ?? "").hasPrefix("line-") }.map(\.seq).min() ?? 0

        var liveDelivered = [String]()
        let (subscriptionID, _) = hub.subscribe(workspaceID: "workspace", sessionID: "session") { envelope in
            liveDelivered.append(envelope.event.eventID)
        }
        defer { hub.unsubscribe(subscriptionID) }
        let sidebarBaseline = sender.commands().count

        XCTAssertTrue(session.backfill(beforeSeq: boundary, limit: 600))
        XCTAssertTrue(waitUntil {
            hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 5000, beforeSeq: boundary).events.isEmpty == false
        })
        hub.drainDeliveriesForTesting()
        XCTAssertTrue(liveDelivered.isEmpty, "backfill delivers nothing live, got \(liveDelivered)")
        XCTAssertEqual(sender.commands().count, sidebarBaseline, "backfill sends no sidebar commands")

        let history = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 5000, beforeSeq: boundary).events
        XCTAssertNil(history.first { $0.text == "repeat me" }?.metadata?["client_request_id"],
                     "the historical echo carries no live submit correlation")
        XCTAssertEqual(registry.snapshot().map(\.clientRequestID), ["client-live"])
        XCTAssertTrue(history.contains { $0.metadata?["reason"] == "unsupported_version" },
                      "history derives its own unsupported-version status")
        XCTAssertTrue(history.contains { $0.type == .toolResult && $0.eventID.contains("call_X") })

        // LIVE follow-ups with colliding parser keys must all still publish.
        let handle = try FileHandle(forWritingTo: transcriptURL)
        handle.seekToEndOfFile()
        handle.write((makeCodexMessageLine(role: "user", content: "repeat me") + "\n").data(using: .utf8)!)
        handle.write((makeCodexAgentMessageLine(text: "K") + "\n").data(using: .utf8)!)
        handle.write((makeCodexExecCommandEndLine(callID: "call_X", output: "live output") + "\n").data(using: .utf8)!)
        handle.write((makeCodexSessionMetaVersionLine(version: "9.9.9") + "\n").data(using: .utf8)!)
        handle.write((makeCodexTaskLine(type: "task_started", turnID: "live-turn") + "\n").data(using: .utf8)!)
        try handle.close()

        XCTAssertTrue(waitUntil {
            hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 5000, afterSeq: boundary).events.contains {
                $0.text == "repeat me" && $0.metadata?["client_request_id"] == "client-live"
            }
        }, "the true live echo still consumes the registry")
        let liveEvents = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 5000, afterSeq: boundary).events
        XCTAssertTrue(waitUntil {
            hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 5000, afterSeq: boundary).events.contains {
                $0.type == .assistantFinal && $0.text == "K"
            }
        }, "the live assistant with the same dedupe key/new line identity still publishes, got \(liveEvents.map(\.eventID))")
        XCTAssertTrue(waitUntil {
            hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 5000, afterSeq: boundary).events.contains {
                $0.type == .toolResult && $0.eventID.contains("exec-end")
            }
        }, "the live tool result for the historical call id still publishes")
        XCTAssertTrue(waitUntil {
            hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 5000, afterSeq: boundary).events.contains {
                $0.metadata?["reason"] == "unsupported_version" && $0.seq > boundary
            }
        }, "the live first observation of version V still publishes its status")
        XCTAssertTrue(waitUntil {
            sender.commands().dropFirst(sidebarBaseline).contains { $0.contains("report_shell_state running") }
        }, "the live task state still drives the sidebar")
    }

    func testCodexHistoricalParserStateStillAppliesDedupeWithinHistory() throws {
        // History-only contrast: TWO historical lines with the same assistant
        // dedupe key must produce ONE historical event — the historical
        // parser state runs, it is not a blanket mutation kill-switch.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexTranscriptSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcriptURL = directory.appendingPathComponent("rollout-session.jsonl", isDirectory: false)

        var lines = [String]()
        lines.append(makeCodexAgentMessageLine(text: "same K", timestamp: "2026-05-15T00:01:00Z"))
        lines.append(makeCodexAgentMessageLine(text: "same K", timestamp: "2026-05-15T00:01:00Z"))
        for index in 0..<transcriptBootstrapLineLimit {
            lines.append(makeCodexMessageLine(role: "assistant", content: "line-\(index)"))
        }
        try (lines.joined(separator: "\n") + "\n").write(to: transcriptURL, atomically: true, encoding: .utf8)

        let hub = AgentEventHub()
        let session = CodexTranscriptSession(record: makeRecord(transcriptPath: transcriptURL.path),
                                             fileManager: .default,
                                             hub: hub)
        session.start()
        defer { session.stop() }
        XCTAssertTrue(waitUntil {
            hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 1).events.first?.text == "line-\(transcriptBootstrapLineLimit - 1)"
        })
        let boundary = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 5000)
            .events.filter { ($0.text ?? "").hasPrefix("line-") }.map(\.seq).min() ?? 0
        XCTAssertTrue(session.backfill(beforeSeq: boundary, limit: 600))
        XCTAssertTrue(waitUntil {
            hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 5000, beforeSeq: boundary).events.isEmpty == false
        })
        let history = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 5000, beforeSeq: boundary).events
        XCTAssertEqual(history.filter { $0.type == .assistantFinal && $0.text == "same K" }.count, 1,
                       "the historical parser state still applies the assistant dedupe within history")
    }

    func testBackfillWindowEvictionKeepsNewlyReadOldestPages() throws {
        // With a small replay window, paging deeper into history must keep
        // surfacing each newly read OLDEST page — eviction may only drop the
        // NEWEST end of the historical window, in lockstep with the Hub's
        // historical replacement scope.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexTranscriptSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcriptURL = directory.appendingPathComponent("rollout-session.jsonl", isDirectory: false)
        var lines = [String]()
        for index in 0..<20 {
            lines.append(makeCodexMessageLine(role: "assistant", content: "old-\(index)"))
        }
        for index in 0..<transcriptBootstrapLineLimit {
            lines.append(makeCodexMessageLine(role: "assistant", content: "line-\(index)"))
        }
        try (lines.joined(separator: "\n") + "\n").write(to: transcriptURL, atomically: true, encoding: .utf8)

        let hub = AgentEventHub()
        let session = CodexTranscriptSession(record: makeRecord(transcriptPath: transcriptURL.path),
                                             fileManager: .default,
                                             hub: hub,
                                             historicalReplayWindowCapacity: 8)
        session.start()
        defer { session.stop() }
        XCTAssertTrue(waitUntil {
            hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 1).events.first?.text == "line-\(transcriptBootstrapLineLimit - 1)"
        })
        let boundary = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 5000)
            .events.filter { ($0.text ?? "").hasPrefix("line-") }.map(\.seq).min() ?? 0

        // Page backwards one line at a time like a production client: each
        // request anchors before the oldest event already fetched (newest
        // history first: old-19, old-18, ...). EVERY newly read page must
        // actually appear — eviction keeps the just-requested older end.
        var cursor = boundary
        for step in 0..<20 {
            let expectedText = "old-\(19 - step)"
            XCTAssertTrue(session.backfill(beforeSeq: cursor, limit: 1),
                          "page \(step) must load")
            let history = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 5000, beforeSeq: boundary).events
            XCTAssertTrue(history.contains { $0.text == expectedText },
                          "the newly read oldest page (\(expectedText)) must be parsed and stored, got \(history.compactMap(\.text))")
            // Page anchors advance on file-backed events only — the seq-0
            // synthetic session-start is not a transcript line.
            cursor = history.map(\.seq).filter { $0 > 0 }.min() ?? cursor
        }
    }

    func testCrossPageDuplicateDedupeKeyRetractsNewerDerivation() throws {
        // Two identical assistant dedupe keys on separate limit=1 pages: the
        // NEWER copy loads first (single page: it derives); when the OLDER
        // copy loads, the fresh replay suppresses the newer one — and the
        // Hub's historical state must be RECONCILED to exactly one event.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexTranscriptSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcriptURL = directory.appendingPathComponent("rollout-session.jsonl", isDirectory: false)
        var lines = [String]()
        lines.append(makeCodexAgentMessageLine(text: "same K", timestamp: "2026-05-15T00:01:00Z"))
        lines.append(makeCodexAgentMessageLine(text: "same K", timestamp: "2026-05-15T00:01:00Z"))
        for index in 0..<transcriptBootstrapLineLimit {
            lines.append(makeCodexMessageLine(role: "assistant", content: "line-\(index)"))
        }
        try (lines.joined(separator: "\n") + "\n").write(to: transcriptURL, atomically: true, encoding: .utf8)

        let hub = AgentEventHub()
        let session = CodexTranscriptSession(record: makeRecord(transcriptPath: transcriptURL.path),
                                             fileManager: .default,
                                             hub: hub)
        session.start()
        defer { session.stop() }
        XCTAssertTrue(waitUntil {
            hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 1).events.first?.text == "line-\(transcriptBootstrapLineLimit - 1)"
        })
        let boundary = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 5000)
            .events.filter { ($0.text ?? "").hasPrefix("line-") }.map(\.seq).min() ?? 0

        XCTAssertTrue(session.backfill(beforeSeq: boundary, limit: 1))  // newer K first
        XCTAssertTrue(session.backfill(beforeSeq: boundary, limit: 1))  // older K second
        let history = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 5000, beforeSeq: boundary).events
        XCTAssertEqual(history.filter { $0.type == .assistantFinal && $0.text == "same K" }.count, 1,
                       "the historical replacement must retract the previously stored newer derivation, got \(history.map { ($0.eventID, $0.seq) })")
    }

    func testRepeatedReplayAfterSeenIDTrimDoesNotDuplicateHistory() throws {
        // A tiny Hub seen-ID capacity forces trims; repeated window replays
        // must still fetch UNIQUE events (the seen lifecycle must cover all
        // currently stored IDs).
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexTranscriptSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcriptURL = directory.appendingPathComponent("rollout-session.jsonl", isDirectory: false)
        var lines = [String]()
        for index in 0..<12 {
            lines.append(makeCodexMessageLine(role: "assistant", content: "old-\(index)"))
        }
        for index in 0..<transcriptBootstrapLineLimit {
            lines.append(makeCodexMessageLine(role: "assistant", content: "line-\(index)"))
        }
        try (lines.joined(separator: "\n") + "\n").write(to: transcriptURL, atomically: true, encoding: .utf8)

        let hub = AgentEventHub(maxBufferedEvents: 2000, maxSeenEventIDs: 16)
        let session = CodexTranscriptSession(record: makeRecord(transcriptPath: transcriptURL.path),
                                             fileManager: .default,
                                             hub: hub)
        session.start()
        defer { session.stop() }
        XCTAssertTrue(waitUntil {
            hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 1).events.first?.text == "line-\(transcriptBootstrapLineLimit - 1)"
        })
        let boundary = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 5000)
            .events.filter { ($0.text ?? "").hasPrefix("line-") }.map(\.seq).min() ?? 0

        for _ in 0..<6 {
            _ = session.backfill(beforeSeq: boundary, limit: 2)
        }
        let history = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 5000, beforeSeq: boundary).events
        let ids = history.map(\.eventID)
        XCTAssertEqual(ids.count, Set(ids).count,
                       "repeated replays after seen-ID trims must not duplicate stored history, got \(ids)")
    }

    func testTranscriptIdentitySwitchIsolatesHistoricalState() throws {
        // Backfill under identity A, switch to transcript B, backfill again:
        // B's history must not contain A's lines.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexTranscriptSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcriptA = directory.appendingPathComponent("rollout-a.jsonl", isDirectory: false)
        let transcriptB = directory.appendingPathComponent("rollout-b.jsonl", isDirectory: false)

        var linesA = [String]()
        linesA.append(makeCodexMessageLine(role: "assistant", content: "A-old"))
        for index in 0..<transcriptBootstrapLineLimit {
            linesA.append(makeCodexMessageLine(role: "assistant", content: "line-\(index)"))
        }
        try (linesA.joined(separator: "\n") + "\n").write(to: transcriptA, atomically: true, encoding: .utf8)
        var linesB = [String]()
        linesB.append(makeCodexMessageLine(role: "assistant", content: "B-old"))
        for index in 0..<transcriptBootstrapLineLimit {
            linesB.append(makeCodexMessageLine(role: "assistant", content: "B-line-\(index)"))
        }
        try (linesB.joined(separator: "\n") + "\n").write(to: transcriptB, atomically: true, encoding: .utf8)

        let hub = AgentEventHub()
        let session = CodexTranscriptSession(record: makeRecord(transcriptPath: transcriptA.path),
                                             fileManager: .default,
                                             hub: hub)
        session.start()
        defer { session.stop() }
        XCTAssertTrue(waitUntil {
            hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 1).events.first?.text == "line-\(transcriptBootstrapLineLimit - 1)"
        })
        let boundaryA = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 5000)
            .events.filter { ($0.text ?? "").hasPrefix("line-") }.map(\.seq).min() ?? 0
        XCTAssertTrue(session.backfill(beforeSeq: boundaryA, limit: 50))
        XCTAssertTrue(waitUntil {
            hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 5000, beforeSeq: boundaryA).events.contains { $0.text == "A-old" }
        })

        // Switch the transcript identity to B.
        session.update(record: makeRecord(transcriptPath: transcriptB.path))
        XCTAssertTrue(waitUntil {
            hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 1).events.first?.text == "B-line-\(transcriptBootstrapLineLimit - 1)"
        })
        let all = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 8000)
        let boundaryB = all.events.filter { ($0.text ?? "").hasPrefix("B-line-") }.map(\.seq).min() ?? 0
        XCTAssertTrue(session.backfill(beforeSeq: boundaryB, limit: 50))
        XCTAssertTrue(waitUntil {
            hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 5000, beforeSeq: boundaryB).events.contains { $0.text == "B-old" }
        })
        let historyB = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 5000, beforeSeq: boundaryB).events
        XCTAssertFalse(historyB.contains { $0.text == "A-old" },
                       "identity B's history must not contain identity A's lines, got \(historyB.compactMap(\.text))")
    }

    func testHistoricalReplayWritesNoLogFileSideEffects() throws {
        // Historical mode's ONLY side effect is historical storage: the
        // /tmp Codex log file must not grow during a backfill containing
        // task-state lines.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexTranscriptSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcriptURL = directory.appendingPathComponent("rollout-session.jsonl", isDirectory: false)
        var lines = [String]()
        for index in 0..<5 {
            lines.append(makeCodexTaskLine(type: "task_started", turnID: "old-\(index)"))
            lines.append(makeCodexTaskLine(type: "task_complete", turnID: "old-\(index)", message: "done"))
        }
        for index in 0..<transcriptBootstrapLineLimit {
            lines.append(makeCodexMessageLine(role: "assistant", content: "line-\(index)"))
        }
        try (lines.joined(separator: "\n") + "\n").write(to: transcriptURL, atomically: true, encoding: .utf8)

        let hub = AgentEventHub()
        let session = CodexTranscriptSession(record: makeRecord(transcriptPath: transcriptURL.path),
                                             fileManager: .default,
                                             hub: hub)
        session.start()
        defer { session.stop() }
        XCTAssertTrue(waitUntil {
            hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 1).events.first?.text == "line-\(transcriptBootstrapLineLimit - 1)"
        })
        let boundary = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 5000)
            .events.filter { ($0.text ?? "").hasPrefix("line-") }.map(\.seq).min() ?? 0

        let logPath = "/tmp/tidey-bridge-codex.log"
        let sizeBefore = (try? FileManager.default.attributesOfItem(atPath: logPath)[.size] as? Int) ?? 0
        XCTAssertTrue(session.backfill(beforeSeq: boundary, limit: 100))
        XCTAssertTrue(waitUntil {
            hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 5000, beforeSeq: boundary).events.isEmpty == false
        })
        let sizeAfter = (try? FileManager.default.attributesOfItem(atPath: logPath)[.size] as? Int) ?? 0
        XCTAssertEqual(sizeAfter, sizeBefore,
                       "historical replay must not write log-file side effects")
    }

    // MARK: - Round 11 P0-2 second review

    func testFreshClientCanReloadEvictedNewerHistoricalRange() throws {
        // Client A pages deep enough to evict newer historical pages from the
        // bounded window; a fresh client B then requests a NEWER beforeSeq.
        // The tailer must honor B's anchor (re-reading the evicted range)
        // and the eviction/replacement must keep the requested page — no
        // permanent gap.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexTranscriptSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcriptURL = directory.appendingPathComponent("rollout-session.jsonl", isDirectory: false)
        var lines = [String]()
        for index in 0..<30 {
            lines.append(makeCodexMessageLine(role: "assistant", content: "old-\(index)"))
        }
        for index in 0..<transcriptBootstrapLineLimit {
            lines.append(makeCodexMessageLine(role: "assistant", content: "line-\(index)"))
        }
        try (lines.joined(separator: "\n") + "\n").write(to: transcriptURL, atomically: true, encoding: .utf8)

        let hub = AgentEventHub()
        let session = CodexTranscriptSession(record: makeRecord(transcriptPath: transcriptURL.path),
                                             fileManager: .default,
                                             hub: hub,
                                             historicalReplayWindowCapacity: 6)
        session.start()
        defer { session.stop() }
        XCTAssertTrue(waitUntil {
            hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 1).events.first?.text == "line-\(transcriptBootstrapLineLimit - 1)"
        })
        let boundary = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 5000)
            .events.filter { ($0.text ?? "").hasPrefix("line-") }.map(\.seq).min() ?? 0

        // Client A pages deep: far beyond the window capacity, evicting the
        // newer historical pages (old-29, old-28, ...).
        for _ in 0..<25 {
            _ = session.backfill(beforeSeq: boundary, limit: 1)
        }
        // Fresh client B: requests the NEWER historical range again (just
        // below the live boundary).
        XCTAssertTrue(session.backfill(beforeSeq: boundary, limit: 3),
                      "a fresh client's newer-range request must be honored after deep paging")
        let history = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 5000, beforeSeq: boundary).events
        for expected in ["old-29", "old-28", "old-27"] {
            XCTAssertTrue(history.contains { $0.text == expected },
                          "the requested newer page (\(expected)) must be reloadable after eviction, got \(history.compactMap(\.text))")
        }
    }

    // R12 B1: a fresh client's requested anchor must be served by the REAL
    // fetch_agent_events flow even when a deep page cache could satisfy the
    // limit — the server must not let cache hasMore stand in for requested-
    // range coverage.
    func testServerFetchServesRequestedAnchorDespiteDeepCache() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexTranscriptSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcriptURL = directory.appendingPathComponent("rollout-session.jsonl", isDirectory: false)
        var lines = [String]()
        for index in 0..<30 {
            lines.append(makeCodexMessageLine(role: "assistant", content: "old-\(index)"))
        }
        for index in 0..<transcriptBootstrapLineLimit {
            lines.append(makeCodexMessageLine(role: "assistant", content: "line-\(index)"))
        }
        try (lines.joined(separator: "\n") + "\n").write(to: transcriptURL, atomically: true, encoding: .utf8)

        let hub = AgentEventHub()
        let session = CodexTranscriptSession(record: makeRecord(transcriptPath: transcriptURL.path),
                                             fileManager: .default,
                                             hub: hub,
                                             historicalReplayWindowCapacity: 6)
        session.start()
        defer { session.stop() }
        XCTAssertTrue(waitUntil {
            hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 2000).events.contains { $0.text == "line-\(transcriptBootstrapLineLimit - 1)" }
        })
        let boundary = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 5000)
            .events.filter { ($0.text ?? "").hasPrefix("line-") }.map(\.seq).min() ?? 0
        let backfill: (String, Int, Int) -> Bool = { _, beforeSeq, limit in
            session.backfill(beforeSeq: beforeSeq, limit: limit)
        }
        func serverFetch(limit: Int, beforeSeq: Int) -> AgentEventHub.FetchResult {
            BridgeAgentEventFetchFlow.run(eventHub: hub,
                                          workspaceID: "workspace",
                                          sessionID: "session",
                                          limit: limit,
                                          beforeSeq: beforeSeq,
                                          afterSeq: nil,
                                          backfill: backfill,
                                          afterSeed: { _, _ in .unavailable },
                                          afterStep: { _, _, _, _ in
                                              AgentAfterCursorBackfillStep(outcome: .unavailable,
                                                                           nextBeforeSeq: nil,
                                                                           events: [])
                                          }).fetchResult
        }

        // Client A pages deep through the REAL flow, advancing by the
        // returned oldest_seq, until the cache window sits at the deep end.
        var cursorA = boundary
        for _ in 0..<12 {
            let page = serverFetch(limit: 4, beforeSeq: cursorA)
            guard let next = page.events.map(\.seq).filter({ $0 > 0 }).min(), next < cursorA else {
                break
            }
            cursorA = next
        }

        // Client B starts fresh at the ORIGINAL newer anchor with a small
        // limit: the response must be the page adjacent to B's anchor.
        let pageB = serverFetch(limit: 3, beforeSeq: boundary)
        let textsB = pageB.events.compactMap(\.text)
        for expected in ["old-29", "old-28", "old-27"] {
            XCTAssertTrue(textsB.contains(expected),
                          "the requested anchor-adjacent page must be served (\(expected)), got \(textsB)")
        }

        // B pages on: the union must be contiguous, exactly once each.
        var union = textsB
        var cursorB = pageB.events.map(\.seq).filter { $0 > 0 }.min() ?? boundary
        for _ in 0..<30 {
            let page = serverFetch(limit: 3, beforeSeq: cursorB)
            let texts = page.events.compactMap(\.text)
            guard texts.isEmpty == false,
                  let next = page.events.map(\.seq).filter({ $0 > 0 }).min(), next < cursorB else {
                break
            }
            union.append(contentsOf: texts)
            cursorB = next
        }
        let expectedUnion = (0..<30).map { "old-\($0)" }
        XCTAssertEqual(Set(union), Set(expectedUnion), "no gap in B's union")
        XCTAssertEqual(union.count, expectedUnion.count, "no duplicate in B's union")
    }

    // R12 B2: a single request whose limit exceeds the raw window capacity
    // must not skip lines before their FIRST parse — every returned page is
    // adjacent to the request anchor and the union is exact and ordered.
    func testLimitLargerThanRawCapacityNeverSkipsLines() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexTranscriptSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcriptURL = directory.appendingPathComponent("rollout-session.jsonl", isDirectory: false)
        var lines = [String]()
        for index in 0..<8 {
            lines.append(makeCodexMessageLine(role: "assistant", content: "old-\(index)"))
        }
        for index in 0..<transcriptBootstrapLineLimit {
            lines.append(makeCodexMessageLine(role: "assistant", content: "line-\(index)"))
        }
        try (lines.joined(separator: "\n") + "\n").write(to: transcriptURL, atomically: true, encoding: .utf8)

        let hub = AgentEventHub()
        let session = CodexTranscriptSession(record: makeRecord(transcriptPath: transcriptURL.path),
                                             fileManager: .default,
                                             hub: hub,
                                             historicalReplayWindowCapacity: 2)
        session.start()
        defer { session.stop() }
        XCTAssertTrue(waitUntil {
            hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 2000).events.contains { $0.text == "line-\(transcriptBootstrapLineLimit - 1)" }
        })
        let boundary = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 5000)
            .events.filter { ($0.text ?? "").hasPrefix("line-") }.map(\.seq).min() ?? 0

        // Production paging with requested limit 5 > raw capacity 2: each
        // returned page must be ADJACENT to the anchor (no silent skip), and
        // the final union exact, ordered and complete.
        var cursor = boundary
        var union = [String]()
        for _ in 0..<20 {
            XCTAssertTrue(session.backfill(beforeSeq: cursor, limit: 5) || union.count == 8)
            let page = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 5000, beforeSeq: cursor).events
            let texts = page.compactMap(\.text)
            guard texts.isEmpty == false else {
                break
            }
            // Adjacency: the NEWEST returned event must be the line
            // immediately below the anchor.
            let newestReturned = page.map(\.seq).max() ?? 0
            let expectedAdjacentIndex = 8 - union.count - 1
            XCTAssertEqual(texts.last, "old-\(expectedAdjacentIndex)",
                           "the page must start immediately below the anchor, got \(texts)")
            union.append(contentsOf: texts.reversed())
            _ = newestReturned
            guard let next = page.map(\.seq).filter({ $0 > 0 }).min(), next < cursor else {
                break
            }
            cursor = next
            if union.count >= 8 {
                break
            }
        }
        XCTAssertEqual(union, (0..<8).reversed().map { "old-\($0)" },
                       "the union must be exact, in order, no gap, no duplicate, got \(union)")
    }

    func testHistoricalReplacementRespectsHubCapacityWithoutDroppingRequestedPage() throws {
        // A small Hub historical bound: any replacement stays within it AND
        // the just-requested page survives the trim.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexTranscriptSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcriptURL = directory.appendingPathComponent("rollout-session.jsonl", isDirectory: false)
        var lines = [String]()
        for index in 0..<10 {
            lines.append(makeCodexMessageLine(role: "assistant", content: "old-\(index)"))
        }
        for index in 0..<transcriptBootstrapLineLimit {
            lines.append(makeCodexMessageLine(role: "assistant", content: "line-\(index)"))
        }
        try (lines.joined(separator: "\n") + "\n").write(to: transcriptURL, atomically: true, encoding: .utf8)

        let hub = AgentEventHub(maxBufferedEvents: 3, maxSeenEventIDs: 100)
        let session = CodexTranscriptSession(record: makeRecord(transcriptPath: transcriptURL.path),
                                             fileManager: .default,
                                             hub: hub)
        session.start()
        defer { session.stop() }
        XCTAssertTrue(waitUntil {
            hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 2000).events.contains { $0.text == "line-\(transcriptBootstrapLineLimit - 1)" }
        })
        let boundary = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 5000)
            .events.filter { ($0.text ?? "").hasPrefix("line-") }.map(\.seq).min() ?? 0

        // Page deep like a production client: each request anchors before the
        // oldest event already fetched. Every page derives more events than
        // the Hub bound — the bound must hold after EVERY replacement while
        // the just-requested page keeps surviving the trim (otherwise the
        // cursor could never advance and paging would stall).
        var cursor = boundary
        var reachedOldest = false
        // Gapless contract: the client pages through EVERY line below the
        // live buffer (bound 3 per page) before reaching the oldest — no
        // silent skipping.
        for _ in 0..<400 {
            guard session.backfill(beforeSeq: cursor, limit: 50) else {
                break
            }
            let page = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 5000, beforeSeq: boundary).events
            XCTAssertLessThanOrEqual(page.count, 3,
                                     "the Hub historical bound must hold across replacements, got \(page.count)")
            let nextCursor = page.map(\.seq).filter { $0 > 0 }.min() ?? cursor
            XCTAssertLessThan(nextCursor, cursor,
                              "the just-requested page must survive the bound trim so paging advances, got \(page.compactMap(\.text))")
            cursor = nextCursor
            if page.contains(where: { $0.text == "old-0" }) {
                reachedOldest = true
                break
            }
        }
        XCTAssertTrue(reachedOldest,
                      "bounded replacements must still let a client page all the way to the oldest line")
    }

    func testEvictedSeenIDsDoNotSuppressLegitimateReplacement() {
        // Precise trace from the review: tiny hub, h1 then h2 historical;
        // eviction keeps only h2 but the stale seen-ID for h1 must not
        // suppress a later replacement that legitimately re-derives h1.
        let hub = AgentEventHub(maxBufferedEvents: 1, maxSeenEventIDs: 3)
        func live(_ id: String, seq: Int) -> AgentEvent {
            AgentEvent(eventID: id, seq: seq, vendor: "codex", workspaceID: "workspace-1",
                       sessionID: "session-1", timestamp: "2026-07-15T12:00:00.000Z",
                       type: .assistantMessage, role: nil, text: id, name: nil, input: nil,
                       output: nil, toolCallID: nil, metadata: nil)
        }
        hub.publish(live("live-100", seq: 100))
        hub.publish(live("h1", seq: 10), deliverToSubscribers: false, storage: .historicalBackfill)
        hub.publish(live("h2", seq: 20), deliverToSubscribers: false, storage: .historicalBackfill)
        // Legitimate reconcile back to [h1].
        hub.replaceHistoricalEvents(sessionID: "session-1", events: [live("h1", seq: 10)], anchorSeq: 10)
        let history = hub.fetch(workspaceID: "workspace-1", sessionID: "session-1", limit: 10, beforeSeq: 100).events
        XCTAssertEqual(history.map(\.eventID), ["h1"],
                       "an evicted historical ID must not block a legitimate replacement, got \(history.map(\.eventID))")
    }

    func testIdentitySwitchImmediatelyRevokesOldHistoryEvenWithoutNewPages() throws {
        // Identity A has backfilled history; the switch to B (whose file has
        // NO older pages) must immediately revoke A's history from the Hub —
        // not wait for a future successful backfill.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexTranscriptSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcriptA = directory.appendingPathComponent("rollout-a.jsonl", isDirectory: false)
        let transcriptB = directory.appendingPathComponent("rollout-b.jsonl", isDirectory: false)
        var linesA = [String]()
        linesA.append(makeCodexMessageLine(role: "assistant", content: "A-old"))
        for index in 0..<transcriptBootstrapLineLimit {
            linesA.append(makeCodexMessageLine(role: "assistant", content: "line-\(index)"))
        }
        try (linesA.joined(separator: "\n") + "\n").write(to: transcriptA, atomically: true, encoding: .utf8)
        // B is SMALL: everything fits the bootstrap, no older pages at all.
        try (makeCodexMessageLine(role: "assistant", content: "B-only") + "\n").write(to: transcriptB, atomically: true, encoding: .utf8)

        let hub = AgentEventHub()
        let session = CodexTranscriptSession(record: makeRecord(transcriptPath: transcriptA.path),
                                             fileManager: .default,
                                             hub: hub)
        session.start()
        defer { session.stop() }
        XCTAssertTrue(waitUntil {
            hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 1).events.first?.text == "line-\(transcriptBootstrapLineLimit - 1)"
        })
        let boundaryA = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 5000)
            .events.filter { ($0.text ?? "").hasPrefix("line-") }.map(\.seq).min() ?? 0
        XCTAssertTrue(session.backfill(beforeSeq: boundaryA, limit: 50))
        XCTAssertTrue(waitUntil {
            hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 5000, beforeSeq: boundaryA).events.contains { $0.text == "A-old" }
        })

        session.update(record: makeRecord(transcriptPath: transcriptB.path))
        XCTAssertTrue(waitUntil {
            hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 8000).events.contains { $0.text == "B-only" }
        })
        // NO backfill for B: A's history must already be gone.
        let all = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 8000).events
        XCTAssertFalse(all.contains { $0.text == "A-old" },
                       "the identity switch must revoke A's history immediately, got \(all.compactMap(\.text).prefix(5))")
    }

    private func makeRecord(transcriptPath: String,
                            sessionID: String = "session",
                            threadID: String? = nil,
                            resumeThreadID: String? = nil) -> AgentSessionRegistryRecord {
        AgentSessionRegistryRecord(version: 1,
                                   vendor: "codex",
                                   workspaceID: "workspace",
                                   sessionID: sessionID,
                                   panelID: "panel",
                                   pid: Int32(ProcessInfo.processInfo.processIdentifier),
                                   cwd: "/tmp",
                                   createdAt: "2026-05-15T00:00:00Z",
                                   transcriptPath: transcriptPath,
                                   threadID: threadID,
                                   resumeThreadID: resumeThreadID)
    }

    private func makeCodexMessageLine(role: String, content: String) -> String {
        let object: [String: Any] = [
            "type": "response_item",
            "timestamp": "2026-05-15T00:00:00Z",
            "payload": [
                "type": "message",
                "role": role,
                "content": [
                    [
                        "type": role == "user" ? "input_text" : "output_text",
                        "text": content,
                    ],
                ],
            ],
        ]
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(data: data, encoding: .utf8)!
    }

    private func makeCodexSessionMetaLine(sessionID: String, cliVersion: String) -> String {
        let object: [String: Any] = [
            "type": "session_meta",
            "timestamp": "2026-05-15T00:00:00Z",
            "payload": [
                "id": sessionID,
                "cli_version": cliVersion,
            ],
        ]
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(data: data, encoding: .utf8)!
    }

    func testAfterCursorStepInvalidationRevokesOldEpochAndResolverReattaches() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexTranscriptSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcriptURL = directory.appendingPathComponent("rollout-session.jsonl", isDirectory: false)
        let lines = (1...5).map { makeCodexMessageLine(role: "user", content: "msg-\($0)") }
            .joined(separator: "\n") + "\n"
        try lines.write(to: transcriptURL, atomically: true, encoding: .utf8)

        let hub = AgentEventHub()
        let session = CodexTranscriptSession(record: makeRecord(transcriptPath: transcriptURL.path),
                                             fileManager: .default,
                                             hub: hub)
        session.start()
        defer { session.stop() }

        XCTAssertTrue(waitUntil {
            hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 20,
                      beforeSeq: nil, afterSeq: nil).events.contains { $0.text == "msg-5" }
        })
        let seededEvents = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 20,
                                     beforeSeq: nil, afterSeq: nil).events
        let anchor = try XCTUnwrap(seededEvents.last?.seq)

        // Deterministic invalidation: mutate the source between the step's
        // raw read and its post-read fence.
        session.tailerForTesting?.backfillAfterReadForTesting = {
            guard let handle = try? FileHandle(forWritingTo: transcriptURL) else { return }
            try? handle.truncate(atOffset: 3)
            try? handle.close()
        }

        let step = session.afterCursorBackfillStep(beforeSeq: anchor, afterSeq: 0, limit: 10)

        XCTAssertEqual(step.outcome, .sourceInvalidated)
        XCTAssertTrue(step.events.isEmpty)
        let postFetch = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 20,
                                  beforeSeq: nil, afterSeq: nil)
        XCTAssertTrue(postFetch.events.isEmpty,
                      "the revoked epoch's live and historical events must be gone from the Hub")

        // The resolver must be able to attach a replacement source.
        let fresh = makeCodexMessageLine(role: "user", content: "fresh-1") + "\n"
        try fresh.write(to: transcriptURL, atomically: true, encoding: .utf8)
        XCTAssertTrue(waitUntil(timeout: 4) {
            hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 20,
                      beforeSeq: nil, afterSeq: nil).events.contains { $0.text == "fresh-1" }
        }, "the resolver must re-attach the replacement source after the epoch revoke")
    }

    private func waitUntil(timeout: TimeInterval = 2,
                           condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return true
            }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        return condition()
    }
}

private struct CodexTranscriptProcessCall: Equatable {
    let executablePath: String
    let arguments: [String]
    let timeout: TimeInterval
}

private final class CodexTranscriptProcessCallRecorder {
    private let lock = NSLock()
    private var storage = [CodexTranscriptProcessCall]()

    func append(executablePath: String,
                arguments: [String],
                timeout: TimeInterval) {
        lock.lock()
        storage.append(CodexTranscriptProcessCall(executablePath: executablePath,
                                                  arguments: arguments,
                                                  timeout: timeout))
        lock.unlock()
    }

    var calls: [CodexTranscriptProcessCall] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
