import Darwin
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

        let oldSeq = try XCTUnwrap(
            hub.fetch(workspaceID: "workspace", sessionID: "instance-session", limit: 10)
                .events.first { $0.text == "old thread" }?.seq)

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
        // Reframed for the unified source-reset contract: an identity switch
        // advances the Hub epoch and revokes the retired thread's events —
        // while cursor authority survives, so the replacement thread still
        // sequences strictly above the old one.
        XCTAssertFalse(result.events.contains { $0.text == "old thread" },
                       "the retired thread's events are revoked by the epoch reset")
        let newEvent = try XCTUnwrap(result.events.first { $0.text == "new live thread" })
        XCTAssertGreaterThan(newEvent.seq, oldSeq)
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
            "payload": ["type": "exec_command_end", "call_id": callID, "aggregated_output": output,
                        "stdout": "", "stderr": "", "formatted_output": "",
                        "exit_code": 0, "status": "completed"],
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
        // Historical page: user echo, assistant K, function_call_output X,
        // task states. After the backfill, LIVE
        // events with colliding parser keys (same dedupe key/new line, same
        // call id, task states) must all still publish; the
        // live echo still consumes the registry; backfill itself delivers
        // nothing live and sends no sidebar commands.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexTranscriptSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcriptURL = directory.appendingPathComponent("rollout-session.jsonl", isDirectory: false)

        var lines = [String]()
        lines.append(makeCodexMessageLine(role: "user", content: "repeat me"))
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
        XCTAssertTrue(history.contains { $0.type == .toolResult && $0.eventID.contains("call_X") })

        // LIVE follow-ups with colliding parser keys must all still publish.
        let handle = try FileHandle(forWritingTo: transcriptURL)
        handle.seekToEndOfFile()
        handle.write((makeCodexMessageLine(role: "user", content: "repeat me") + "\n").data(using: .utf8)!)
        handle.write((makeCodexAgentMessageLine(text: "K") + "\n").data(using: .utf8)!)
        handle.write((makeCodexExecCommandEndLine(callID: "call_X", output: "live output") + "\n").data(using: .utf8)!)
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
                                          backfill: backfill).fetchResult
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

    func testCodexBeforeCursorWireLoopRetreatsAcrossSyntheticMigrationMarker() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexTranscriptSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcriptURL = directory.appendingPathComponent("rollout-session.jsonl", isDirectory: false)
        let fileRowCount = transcriptBootstrapLineLimit + 20
        let lines = (0..<fileRowCount).map {
            makeCodexMessageLine(role: "assistant", content: "file-\($0)")
        }
        try (lines.joined(separator: "\n") + "\n")
            .write(to: transcriptURL, atomically: true, encoding: .utf8)

        let hub = AgentEventHub(maxBufferedEvents: 2)
        let session = CodexTranscriptSession(record: makeRecord(transcriptPath: transcriptURL.path),
                                             fileManager: .default,
                                             hub: hub,
                                             historicalReplayWindowCapacity: 1)
        session.start()
        defer { session.stop() }
        let lastFileText = "file-\(fileRowCount - 1)"
        XCTAssertTrue(waitUntil {
            hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 5)
                .events.contains { $0.text == lastFileText }
        })

        let migratedWorkspaceID = "workspace-migrated"
        let migratedRecord = AgentSessionRegistryRecord(
            version: 1,
            vendor: "codex",
            workspaceID: migratedWorkspaceID,
            sessionID: "session",
            panelID: "panel-migrated",
            pid: Int32(ProcessInfo.processInfo.processIdentifier),
            cwd: "/tmp",
            createdAt: "2026-05-15T00:00:00Z",
            transcriptPath: transcriptURL.path
        )
        session.update(record: migratedRecord)
        XCTAssertTrue(waitUntil {
            hub.fetch(workspaceID: migratedWorkspaceID, sessionID: "session", limit: 5)
                .events.contains {
                    $0.type == .sessionStarted
                        && $0.seq > transcriptSessionStartedSequence
                }
        }, "same-source workspace migration publishes a positive-sequence synthetic marker")

        let handle = try FileHandle(forWritingTo: transcriptURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(
            (makeCodexMessageLine(role: "assistant", content: "cursor") + "\n").utf8
        ))
        try handle.close()
        XCTAssertTrue(waitUntil {
            hub.fetch(workspaceID: migratedWorkspaceID, sessionID: "session", limit: 5)
                .events.contains { $0.text == "cursor" }
        })
        let cursorSeq = try XCTUnwrap(
            hub.fetch(workspaceID: migratedWorkspaceID, sessionID: "session", limit: 5)
                .events
                .first { $0.text == "cursor" }?
                .seq
        )

        func wirePage(beforeSeq: Int) -> BridgeAgentEventFetchFlow.Output {
            BridgeAgentEventFetchFlow.run(
                eventHub: hub,
                workspaceID: migratedWorkspaceID,
                sessionID: "session",
                limit: 1,
                beforeSeq: beforeSeq,
                afterSeq: nil,
                beforeCursorBackfill: { _, beforeSeq, limit in
                    session.beforeCursorBackfill(beforeSeq: beforeSeq, limit: limit)
                }
            )
        }

        let first = wirePage(beforeSeq: cursorSeq)
        XCTAssertFalse(first.beforeCursorUnavailable)
        XCTAssertTrue(first.fetchResult.hasMore,
                      "the bounded raw page still has older source bytes")
        XCTAssertEqual(first.fetchResult.events.count, 1)
        let migrationMarker = try XCTUnwrap(first.fetchResult.events.first)
        XCTAssertEqual(migrationMarker.type, .sessionStarted)
        XCTAssertGreaterThan(migrationMarker.seq, transcriptSessionStartedSequence)
        XCTAssertEqual(first.fetchResult.oldestSeq, migrationMarker.seq,
                       "the count-limited page exposes the positive synthetic as a virtual cursor")
        let second = wirePage(beforeSeq: first.fetchResult.oldestSeq)
        XCTAssertFalse(second.beforeCursorUnavailable)
        XCTAssertLessThan(second.fetchResult.oldestSeq, migrationMarker.seq)
        XCTAssertTrue(second.fetchResult.events.contains { $0.text == lastFileText },
                      "the virtual cursor must conservatively replay its adjacent raw line")
    }

    func testCodexBeforeCursorVirtualCursorAtOffsetZeroReplaysAnchorLine() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexTranscriptSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcriptURL = directory.appendingPathComponent("rollout-session.jsonl", isDirectory: false)
        try (makeCodexMessageLine(role: "assistant", content: "raw-zero") + "\n")
            .write(to: transcriptURL, atomically: true, encoding: .utf8)

        let hub = AgentEventHub(maxBufferedEvents: 1)
        let session = CodexTranscriptSession(record: makeRecord(transcriptPath: transcriptURL.path),
                                             fileManager: .default,
                                             hub: hub)
        session.start()
        defer { session.stop() }
        XCTAssertTrue(waitUntil {
            hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 5)
                .events.contains { $0.text == "raw-zero" }
        })
        let rawZero = try XCTUnwrap(
            hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 5)
                .events
                .first { $0.text == "raw-zero" }
        )
        let synthetic = try XCTUnwrap(
            hub.publish(AgentEvent(
                eventID: "external-synthetic",
                seq: hub.nextSyntheticSeq(sessionID: "session"),
                vendor: "codex",
                workspaceID: "workspace",
                sessionID: "session",
                timestamp: "2026-05-15T00:00:01Z",
                type: .assistantMessage,
                role: "assistant",
                text: "external-synthetic",
                name: nil,
                input: nil,
                output: nil,
                toolCallID: nil,
                metadata: ["source": "external"]
            ),
            deliverToSubscribers: false
        ))
        XCTAssertEqual(synthetic.seq, rawZero.seq + 1,
                       "the external event is a virtual ordinal after offset-zero raw")
        XCTAssertEqual(
            hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 5)
                .events
                .map(\.eventID),
            ["external-synthetic"],
            "precondition: capacity pressure evicted the only raw event"
        )

        let page = BridgeAgentEventFetchFlow.run(
            eventHub: hub,
            workspaceID: "workspace",
            sessionID: "session",
            limit: 1,
            beforeSeq: synthetic.seq,
            afterSeq: nil,
            beforeCursorBackfill: { _, beforeSeq, limit in
                session.beforeCursorBackfill(beforeSeq: beforeSeq, limit: limit)
            }
        )

        XCTAssertFalse(page.beforeCursorUnavailable)
        XCTAssertTrue(page.didBackfill,
                      "a virtual ordinal at offset zero must replay its anchor line")
        XCTAssertEqual(page.fetchResult.events.compactMap(\.text), ["raw-zero"])
        XCTAssertEqual(page.fetchResult.oldestSeq, rawZero.seq)
        XCTAssertFalse(page.fetchResult.hasMore,
                       "the replayed offset-zero line is source-proven BOF")
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

    func testCodexSourceResetHasOneAtomicHubVisibilityPoint() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexTranscriptSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcriptA = directory.appendingPathComponent("rollout-a.jsonl", isDirectory: false)
        let transcriptB = directory.appendingPathComponent("rollout-b.jsonl", isDirectory: false)
        let recent = (0..<transcriptBootstrapLineLimit).map {
            makeCodexMessageLine(role: "assistant", content: "a-recent-\($0)")
        }
        try (([makeCodexMessageLine(role: "assistant", content: "a-history")] + recent)
            .joined(separator: "\n") + "\n")
            .write(to: transcriptA, atomically: true, encoding: .utf8)
        try (makeCodexMessageLine(role: "assistant", content: "b-sentinel") + "\n")
            .write(to: transcriptB, atomically: true, encoding: .utf8)

        let hub = AgentEventHub()
        let session = CodexTranscriptSession(record: makeRecord(transcriptPath: transcriptA.path),
                                             fileManager: .default,
                                             hub: hub)
        session.start()
        defer { session.stop() }
        XCTAssertTrue(waitUntil {
            hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 5)
                .events.contains { $0.text == "a-recent-\(transcriptBootstrapLineLimit - 1)" }
        })
        let boundaryA = try XCTUnwrap(
            hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 2000)
                .events
                .filter { $0.text?.hasPrefix("a-recent-") == true }
                .map(\.seq)
                .min()
        )
        let oldEpoch = hub.currentHistoryEpoch(sessionID: "session")
        let savedResult = session.beforeCursorBackfill(beforeSeq: boundaryA, limit: 500)
        XCTAssertTrue(savedResult.didBackfill)
        XCTAssertEqual(savedResult.rawContinuation, .end)
        XCTAssertEqual(savedResult.authorityEpoch, oldEpoch)
        XCTAssertTrue(
            hub.fetch(workspaceID: "workspace",
                      sessionID: "session",
                      limit: 500,
                      beforeSeq: boundaryA)
                .events
                .contains { $0.text == "a-history" },
            "precondition: source A's proven BOF page is visible"
        )

        var epochAtResetSeam: AgentHistoryEpoch?
        var flowAtResetSeam: BridgeAgentEventFetchFlow.Output?
        session.resetTranscriptSourceBeforeHubEpochAdvanceForTesting = {
            epochAtResetSeam = hub.currentHistoryEpoch(sessionID: "session")
            flowAtResetSeam = BridgeAgentEventFetchFlow.run(
                eventHub: hub,
                workspaceID: "workspace",
                sessionID: "session",
                limit: 500,
                beforeSeq: boundaryA,
                afterSeq: nil,
                beforeCursorBackfill: { _, _, _ in savedResult }
            )
        }
        defer { session.resetTranscriptSourceBeforeHubEpochAdvanceForTesting = nil }

        session.update(record: makeRecord(transcriptPath: transcriptB.path))

        XCTAssertTrue(waitUntil { flowAtResetSeam != nil })
        XCTAssertEqual(epochAtResetSeam, oldEpoch,
                       "the Hub has not linearized the source reset at the seam")
        let seamFlow = try XCTUnwrap(flowAtResetSeam)
        XCTAssertFalse(seamFlow.beforeCursorUnavailable,
                       "the still-current old epoch remains a coherent snapshot")
        XCTAssertFalse(seamFlow.fetchResult.hasMore,
                       "source A had already proven true BOF")
        XCTAssertTrue(seamFlow.fetchResult.events.contains { $0.text == "a-history" },
                      "old-epoch history must remain visible until the atomic epoch reset")

        XCTAssertTrue(waitUntil(timeout: 4) {
            hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 50)
                .events.contains { $0.text == "b-sentinel" }
        }, "the resolver reattaches source B after the reset")
        XCTAssertEqual(hub.currentHistoryEpoch(sessionID: "session").generation,
                       oldEpoch.generation + 1,
                       "the Hub reset has exactly one linearization point")
        let replacementEvents = hub.fetch(workspaceID: "workspace",
                                          sessionID: "session",
                                          limit: 2000)
            .events
        XCTAssertFalse(replacementEvents.contains { $0.text?.hasPrefix("a-") == true },
                       "all source A products are revoked after the epoch advances")
        XCTAssertEqual(replacementEvents.filter { $0.text == "b-sentinel" }.count, 1)
    }

    // MARK: G4 B17 typed after-cursor walk + invalidation revoke

    private func makeCacheSentinel(seq: Int) -> AgentEvent {
        AgentEvent(eventID: "cache-sentinel",
                   seq: seq,
                   vendor: "codex",
                   workspaceID: "workspace",
                   sessionID: "session",
                   timestamp: "2026-05-15T00:00:00Z",
                   type: .assistantMessage,
                   role: "assistant",
                   text: "cache-sentinel",
                   name: nil,
                   input: nil,
                   output: nil,
                   toolCallID: nil,
                   metadata: nil)
    }

    func testCodexAfterCursorPlanAndStepWalkBelowBootstrapFloor() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexTranscriptSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcriptURL = directory.appendingPathComponent("rollout.jsonl", isDirectory: false)
        let lineCount = transcriptBootstrapLineLimit + 20
        let lines = (0..<lineCount).map {
            makeCodexMessageLine(role: "assistant",
                                 content: "walk-\($0)-" + String(repeating: "x", count: 160))
        }
        try (lines.joined(separator: "\n") + "\n").write(to: transcriptURL, atomically: true, encoding: .utf8)
        let hub = AgentEventHub()
        let session = CodexTranscriptSession(record: makeRecord(transcriptPath: transcriptURL.path),
                                             fileManager: .default,
                                             hub: hub)
        session.start()
        defer { session.stop() }
        XCTAssertTrue(waitUntil {
            hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 5)
                .events.contains { $0.text?.hasPrefix("walk-\(lineCount - 1)-") == true }
        })
        hub.replaceHistoricalEvents(sessionID: "session", events: [makeCacheSentinel(seq: 1)])
        let firstLiveSeq = try XCTUnwrap(
            hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 2000)
                .events.filter { $0.text?.hasPrefix("walk-") == true }.map(\.seq).min())
        let epoch = hub.currentHistoryEpoch(sessionID: "session")
        let eof = try Int(XCTUnwrap((FileManager.default.attributesOfItem(atPath: transcriptURL.path)[.size] as? NSNumber)?.intValue))

        let plan = session.afterCursorPlan(afterSeq: 0, expectedEpoch: epoch)
        guard case .scan(let startAnchor) = plan.mode else {
            return XCTFail("a cursor below the bootstrap floor must SCAN, got \(plan.mode)")
        }
        XCTAssertEqual(startAnchor.position, TranscriptEventPosition(lineOffset: eof, ordinal: 0),
                       "the scan anchor is the fixed validated EOF")
        let secondPlan = session.afterCursorPlan(afterSeq: 0, expectedEpoch: epoch)
        guard case .scan(let secondAnchor) = secondPlan.mode else {
            return XCTFail("the second plan scans too, got \(secondPlan.mode)")
        }
        XCTAssertEqual(secondAnchor.position, startAnchor.position,
                       "the starting anchor is stable across plans")

        var anchor = startAnchor
        var steps = [AgentAfterCursorStep]()
        var events = [AgentEvent]()
        walk: for _ in 0..<64 {
            let step = session.afterCursorStep(from: anchor, afterSeq: 0, limit: 40)
            steps.append(step)
            events.append(contentsOf: step.events)
            XCTAssertFalse(step.events.contains { $0.eventID == "cache-sentinel" },
                           "the disjoint shared cache never enters a step payload")
            switch step.outcome {
            case .advanced(let next):
                XCTAssertLessThan(next.position, anchor.position,
                                  "every advanced anchor is strictly lower")
                anchor = next
            case .complete:
                break walk
            case .sourceChanged, .unavailable:
                return XCTFail("the walk must stay available, got \(step.outcome)")
            }
        }
        guard case .complete = steps.last?.outcome else {
            return XCTFail("the walk completes at BOF, got \(String(describing: steps.last?.outcome))")
        }
        let ids = events.map(\.eventID)
        XCTAssertEqual(Set(ids).count, ids.count, "no duplicate across step intervals")
        let expectedTexts = Set((0..<lineCount).map { "walk-\($0)-" + String(repeating: "x", count: 160) })
        XCTAssertEqual(events.count, lineCount,
                       "the union yields exactly one product per fixture line — no extra, no gap")
        XCTAssertEqual(Set(events.compactMap(\.text)), expectedTexts,
                       "the union is EXACTLY the expected text set — nothing beyond the fixture")
        let cacheAfterWalk = hub.fetch(workspaceID: "workspace",
                                       sessionID: "session",
                                       limit: 2000,
                                       beforeSeq: firstLiveSeq)
        XCTAssertFalse(cacheAfterWalk.events.contains { $0.text?.hasPrefix("walk-") == true },
                       "typed steps never write request pages into the shared historical cache")
        XCTAssertTrue(cacheAfterWalk.events.contains { $0.eventID == "cache-sentinel" },
                      "the pre-seeded cache sentinel is untouched")
    }

    func testCodexAfterCursorPlanFailsClosedForInvalidUTF8InBootstrapCoverage() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexTranscriptSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcriptURL = directory.appendingPathComponent("rollout.jsonl", isDirectory: false)
        var data = Data((makeCodexMessageLine(role: "assistant", content: "a-0") + "\n").utf8)
        data.append(contentsOf: [0xff, 0x0a])          // invalid UTF-8 complete record
        data.append(Data((makeCodexMessageLine(role: "assistant", content: "a-1") + "\n").utf8))
        try data.write(to: transcriptURL)
        let hub = AgentEventHub()
        let session = CodexTranscriptSession(record: makeRecord(transcriptPath: transcriptURL.path),
                                             fileManager: .default,
                                             hub: hub)
        session.start()
        defer { session.stop() }
        XCTAssertTrue(waitUntil {
            hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 10)
                .events.contains { $0.text == "a-1" }
        })
        let epoch = hub.currentHistoryEpoch(sessionID: "session")

        let plan = session.afterCursorPlan(afterSeq: 0, expectedEpoch: epoch)
        guard case .unavailable = plan.mode else {
            return XCTFail("invalid UTF-8 inside bootstrap coverage must fail closed — minimumRawOffset == 0 is not trust, got \(plan.mode)")
        }
        XCTAssertFalse(session.validateHistoryEpoch(epoch),
                       "a semantically poisoned source must not validate")
    }

    func testCodexAfterCursorMalformedRawPageFailsClosedWithoutAdvancing() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexTranscriptSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcriptURL = directory.appendingPathComponent("rollout.jsonl", isDirectory: false)
        let lineCount = transcriptBootstrapLineLimit + 20
        var lines = (0..<lineCount).map {
            makeCodexMessageLine(role: "assistant",
                                 content: "deep-\($0)-" + String(repeating: "x", count: 160))
        }
        // Valid UTF-8 but malformed JSON, BELOW the bootstrap floor.
        lines[3] = "{\"this-is\": \"not-a-codex-record\""
        try (lines.joined(separator: "\n") + "\n").write(to: transcriptURL, atomically: true, encoding: .utf8)
        let hub = AgentEventHub()
        let session = CodexTranscriptSession(record: makeRecord(transcriptPath: transcriptURL.path),
                                             fileManager: .default,
                                             hub: hub)
        session.start()
        defer { session.stop() }
        XCTAssertTrue(waitUntil {
            hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 5)
                .events.contains { $0.text?.hasPrefix("deep-\(lineCount - 1)-") == true }
        })
        let epoch = hub.currentHistoryEpoch(sessionID: "session")
        let plan = session.afterCursorPlan(afterSeq: 0, expectedEpoch: epoch)
        guard case .scan(let startAnchor) = plan.mode else {
            return XCTFail("precondition: the clean bootstrap plans a scan, got \(plan.mode)")
        }

        var anchor = startAnchor
        var sawUnavailable = false
        walk: for _ in 0..<64 {
            let step = session.afterCursorStep(from: anchor, afterSeq: 0, limit: 40)
            switch step.outcome {
            case .advanced(let next):
                anchor = next
            case .unavailable:
                XCTAssertTrue(step.events.isEmpty,
                              "a poisoned page discards the WHOLE step — no partial events")
                sawUnavailable = true
                break walk
            case .complete:
                return XCTFail("the walk must not complete past a malformed record")
            case .sourceChanged:
                return XCTFail("a malformed record is not a source change, got \(step.outcome)")
            }
        }
        XCTAssertTrue(sawUnavailable, "the malformed page fails the step closed")

        let poisonedPlan = session.afterCursorPlan(afterSeq: 0, expectedEpoch: epoch)
        guard case .unavailable = poisonedPlan.mode else {
            return XCTFail("the poison persists until a source reset — a lowered tailer floor must not restore rawCovered, got \(poisonedPlan.mode)")
        }
    }

    func testCodexBeforeCursorSemanticPoisonFailsUnavailableWithoutPublishingPartialHistory() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexTranscriptSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcriptURL = directory.appendingPathComponent("rollout.jsonl", isDirectory: false)
        let recent = (0..<transcriptBootstrapLineLimit).map {
            makeCodexMessageLine(role: "assistant", content: "recent-\($0)")
        }
        let lines = [
            makeCodexMessageLine(role: "assistant", content: "must-not-publish"),
            "{\"type\":\"future_unknown_record\",\"payload\":{}}",
        ] + recent
        try (lines.joined(separator: "\n") + "\n")
            .write(to: transcriptURL, atomically: true, encoding: .utf8)

        let hub = AgentEventHub()
        let session = CodexTranscriptSession(record: makeRecord(transcriptPath: transcriptURL.path),
                                             fileManager: .default,
                                             hub: hub)
        session.start()
        defer { session.stop() }
        XCTAssertTrue(waitUntil {
            hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 5)
                .events.contains { $0.text == "recent-\(transcriptBootstrapLineLimit - 1)" }
        })
        let beforeSeq = try XCTUnwrap(
            hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 2000)
                .events
                .filter { $0.text?.hasPrefix("recent-") == true }
                .map(\.seq)
                .min()
        )

        let result = session.beforeCursorBackfill(beforeSeq: beforeSeq, limit: 500)

        XCTAssertFalse(result.didBackfill)
        XCTAssertEqual(result.rawContinuation, .unavailable,
                       "an unsupported deep record invalidates the entire before page")
        XCTAssertFalse(
            hub.fetch(workspaceID: "workspace",
                      sessionID: "session",
                      limit: 2000,
                      beforeSeq: beforeSeq)
                .events
                .contains { $0.text == "must-not-publish" },
            "valid siblings from a poisoned replay must not leak into shared history"
        )
    }

    private func makeStartedCodexSession(_ transcriptURL: URL,
                                         hub: AgentEventHub,
                                         readySentinel: String) -> CodexTranscriptSession {
        let session = CodexTranscriptSession(record: makeRecord(transcriptPath: transcriptURL.path),
                                             fileManager: .default,
                                             hub: hub)
        session.start()
        XCTAssertTrue(waitUntil {
            hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 10)
                .events.contains { $0.text == readySentinel }
        }, "the session must bootstrap")
        return session
    }

    func testCodexUnknownTopLevelRecordPoisonsCoverage() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexTranscriptSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcriptURL = directory.appendingPathComponent("rollout.jsonl", isDirectory: false)
        let lineCount = transcriptBootstrapLineLimit + 20
        var lines = (0..<lineCount).map {
            makeCodexMessageLine(role: "assistant",
                                 content: "deep-\($0)-" + String(repeating: "x", count: 160))
        }
        // A well-formed record of an ARBITRARY unknown top-level type,
        // below the bootstrap floor: future schema, not known-ignored.
        lines[3] = "{\"type\":\"totally_unknown_record\",\"timestamp\":\"2026-05-15T00:00:00Z\",\"payload\":{\"type\":\"x\"}}"
        try (lines.joined(separator: "\n") + "\n").write(to: transcriptURL, atomically: true, encoding: .utf8)
        let hub = AgentEventHub()
        let session = makeStartedCodexSession(transcriptURL, hub: hub,
                                              readySentinel: "deep-\(lineCount - 1)-" + String(repeating: "x", count: 160))
        defer { session.stop() }
        let epoch = hub.currentHistoryEpoch(sessionID: "session")
        let plan = session.afterCursorPlan(afterSeq: 0, expectedEpoch: epoch)
        guard case .scan(let startAnchor) = plan.mode else {
            return XCTFail("precondition: the clean bootstrap plans a scan, got \(plan.mode)")
        }

        var anchor = startAnchor
        var sawUnavailable = false
        walk: for _ in 0..<64 {
            let step = session.afterCursorStep(from: anchor, afterSeq: 0, limit: 40)
            switch step.outcome {
            case .advanced(let next):
                anchor = next
            case .unavailable:
                XCTAssertTrue(step.events.isEmpty)
                sawUnavailable = true
                break walk
            case .complete:
                return XCTFail("the walk must not complete past an unknown record")
            case .sourceChanged:
                return XCTFail("an unknown record is not a source change")
            }
        }
        XCTAssertTrue(sawUnavailable, "the unknown-record page fails the step closed")
        guard case .unavailable = session.afterCursorPlan(afterSeq: 0, expectedEpoch: epoch).mode else {
            return XCTFail("the poison persists for the same source")
        }
    }

    // Guard: the known-ignored catalog must NOT poison — these appear in
    // real rollouts and are legal eventless raw progress.
    func testCodexKnownIgnoredTopLevelRecordsAdvanceWithoutPoison() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexTranscriptSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcriptURL = directory.appendingPathComponent("rollout.jsonl", isDirectory: false)
        let lineCount = transcriptBootstrapLineLimit + 20
        var lines = (0..<lineCount).map {
            makeCodexMessageLine(role: "assistant",
                                 content: "deep-\($0)-" + String(repeating: "x", count: 160))
        }
        for (index, ignoredType) in ["turn_context", "compacted", "world_state",
                                     "inter_agent_communication_metadata"].enumerated() {
            lines[3 + index] = "{\"type\":\"\(ignoredType)\",\"timestamp\":\"2026-05-15T00:00:00Z\",\"payload\":{}}"
        }
        try (lines.joined(separator: "\n") + "\n").write(to: transcriptURL, atomically: true, encoding: .utf8)
        let hub = AgentEventHub()
        let session = makeStartedCodexSession(transcriptURL, hub: hub,
                                              readySentinel: "deep-\(lineCount - 1)-" + String(repeating: "x", count: 160))
        defer { session.stop() }
        let epoch = hub.currentHistoryEpoch(sessionID: "session")
        let plan = session.afterCursorPlan(afterSeq: 0, expectedEpoch: epoch)
        guard case .scan(let startAnchor) = plan.mode else {
            return XCTFail("precondition: a scan plan, got \(plan.mode)")
        }
        var anchor = startAnchor
        var completed = false
        walk: for _ in 0..<64 {
            let step = session.afterCursorStep(from: anchor, afterSeq: 0, limit: 40)
            switch step.outcome {
            case .advanced(let next):
                XCTAssertLessThan(next.position, anchor.position)
                anchor = next
            case .complete:
                completed = true
                break walk
            case .unavailable, .sourceChanged:
                return XCTFail("known-ignored records must not poison, got \(step.outcome)")
            }
        }
        XCTAssertTrue(completed)
        XCTAssertTrue(session.validateHistoryEpoch(epoch),
                      "known-ignored records keep the source trusted")
    }

    func testCodexSchemaViolationsPoisonPlanAndValidation() throws {
        let violations: [(name: String, line: String)] = [
            ("response_item-missing-payload-type",
             "{\"type\":\"response_item\",\"timestamp\":\"2026-05-15T00:00:00Z\",\"payload\":{\"role\":\"assistant\"}}"),
            ("response_item-unknown-payload-type",
             "{\"type\":\"response_item\",\"timestamp\":\"2026-05-15T00:00:00Z\",\"payload\":{\"type\":\"future_item\"}}"),
            ("event_msg-unknown-payload-type",
             "{\"type\":\"event_msg\",\"timestamp\":\"2026-05-15T00:00:00Z\",\"payload\":{\"type\":\"quantum_event\"}}"),
            ("session_meta-non-string-cli-version",
             "{\"type\":\"session_meta\",\"timestamp\":\"2026-05-15T00:00:00Z\",\"payload\":{\"id\":\"session\",\"cli_version\":123}}"),
            ("session_meta-foreign-id",
             "{\"type\":\"session_meta\",\"timestamp\":\"2026-05-15T00:00:00Z\",\"payload\":{\"id\":\"someone-else\"}}"),
        ]
        for violation in violations {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("CodexTranscriptSessionTests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let transcriptURL = directory.appendingPathComponent("rollout.jsonl", isDirectory: false)
            let lines = [makeCodexMessageLine(role: "assistant", content: "a-0"),
                         violation.line,
                         makeCodexMessageLine(role: "assistant", content: "a-1")]
            try (lines.joined(separator: "\n") + "\n").write(to: transcriptURL, atomically: true, encoding: .utf8)
            let hub = AgentEventHub()
            let session = makeStartedCodexSession(transcriptURL, hub: hub, readySentinel: "a-1")
            defer { session.stop() }
            let epoch = hub.currentHistoryEpoch(sessionID: "session")
            if case .unavailable = session.afterCursorPlan(afterSeq: 0, expectedEpoch: epoch).mode {
            } else {
                XCTFail("\(violation.name): a schema violation must poison the plan")
            }
            XCTAssertFalse(session.validateHistoryEpoch(epoch),
                           "\(violation.name): a schema violation must poison validation")
        }
    }

    // Guard: a supported session_meta plus known-ignored NESTED records must
    // stay trusted — the poison rules must not over-reach.
    func testCodexSupportedSessionMetaWithKnownIgnoredNestedRecordsStaysTrusted() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexTranscriptSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcriptURL = directory.appendingPathComponent("rollout.jsonl", isDirectory: false)
        let lines = [
            "{\"type\":\"session_meta\",\"timestamp\":\"2026-05-15T00:00:00Z\",\"payload\":{\"id\":\"session\",\"cli_version\":\"0.42.0\"}}",
            "{\"type\":\"response_item\",\"timestamp\":\"2026-05-15T00:00:00Z\",\"payload\":{\"type\":\"reasoning\",\"summary\":[]}}",
            "{\"type\":\"event_msg\",\"timestamp\":\"2026-05-15T00:00:00Z\",\"payload\":{\"type\":\"token_count\",\"info\":{}}}",
            makeCodexMessageLine(role: "assistant", content: "a-0"),
        ]
        try (lines.joined(separator: "\n") + "\n").write(to: transcriptURL, atomically: true, encoding: .utf8)
        let hub = AgentEventHub()
        let session = makeStartedCodexSession(transcriptURL, hub: hub, readySentinel: "a-0")
        defer { session.stop() }
        let epoch = hub.currentHistoryEpoch(sessionID: "session")
        switch session.afterCursorPlan(afterSeq: 0, expectedEpoch: epoch).mode {
        case .rawCovered, .scan:
            break
        case .hubOnly, .unavailable:
            XCTFail("legal records must keep the source plannable")
        }
        XCTAssertTrue(session.validateHistoryEpoch(epoch))
    }

    // The CURRENT real Codex rollout catalog (read-only inventory over the
    // 500 most recent ~/.codex/sessions files, 2026-07-26): every legal
    // subtype Tidey does not parse into an event must be explicitly
    // known-ignored — a normal current rollout must never poison. Rows also
    // keep legacy catalog entries already supported by the parser history.
    func testCodexCurrentRolloutCatalogIgnoredSubtypesStayTrusted() throws {
        let observedIgnoredResponseItemTypes = [
            "reasoning", "web_search_call", "custom_tool_call",
            "custom_tool_call_output", "agent_message", "image_generation_call",
            "tool_search_call", "tool_search_output",
            // legacy catalog entries retained from parser history
            "local_shell_call", "ghost_commit",
        ]
        let observedIgnoredEventMessageTypes = [
            "agent_reasoning", "collab_agent_spawn_end", "collab_close_end",
            "collab_waiting_end", "context_compacted", "image_generation_end",
            "mcp_tool_call_end", "sub_agent_activity", "thread_name_updated",
            "thread_settings_applied", "token_count", "user_message",
            "view_image_tool_call", "web_search_end",
            // legacy catalog entries retained from parser history
            "agent_reasoning_delta", "agent_message_delta",
            "agent_reasoning_section_break", "exec_command_begin",
            "exec_command_output_delta", "patch_apply_begin",
            "mcp_tool_call_begin", "web_search_begin", "turn_diff",
            "background_event", "stream_error", "plan_update",
            "session_configured",
        ]
        var rows = observedIgnoredResponseItemTypes.map {
            (name: "response_item/\($0)",
             line: "{\"type\":\"response_item\",\"timestamp\":\"2026-05-15T00:00:00Z\",\"payload\":{\"type\":\"\($0)\"}}")
        }
        rows += observedIgnoredEventMessageTypes.map {
            (name: "event_msg/\($0)",
             line: "{\"type\":\"event_msg\",\"timestamp\":\"2026-05-15T00:00:00Z\",\"payload\":{\"type\":\"\($0)\"}}")
        }
        for row in rows {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("CodexTranscriptSessionTests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let transcriptURL = directory.appendingPathComponent("rollout.jsonl", isDirectory: false)
            let lines = [makeCodexMessageLine(role: "assistant", content: "a-0"),
                         row.line,
                         makeCodexMessageLine(role: "assistant", content: "a-1")]
            try (lines.joined(separator: "\n") + "\n").write(to: transcriptURL, atomically: true, encoding: .utf8)
            let hub = AgentEventHub()
            let session = makeStartedCodexSession(transcriptURL, hub: hub, readySentinel: "a-1")
            defer { session.stop() }
            let epoch = hub.currentHistoryEpoch(sessionID: "session")
            switch session.afterCursorPlan(afterSeq: 0, expectedEpoch: epoch).mode {
            case .rawCovered, .scan:
                break
            case .hubOnly, .unavailable:
                XCTFail("\(row.name): a current legal ignored subtype must not poison the plan")
            }
            XCTAssertTrue(session.validateHistoryEpoch(epoch),
                          "\(row.name): a current legal ignored subtype must stay trusted")
        }

        // Guard: an ARBITRARY unknown subtype outside the catalog stays
        // poisoned — expanding the allowlist must not reopen the default.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexTranscriptSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcriptURL = directory.appendingPathComponent("rollout.jsonl", isDirectory: false)
        let lines = [makeCodexMessageLine(role: "assistant", content: "a-0"),
                     "{\"type\":\"response_item\",\"timestamp\":\"2026-05-15T00:00:00Z\",\"payload\":{\"type\":\"subtype_from_the_future\"}}",
                     makeCodexMessageLine(role: "assistant", content: "a-1")]
        try (lines.joined(separator: "\n") + "\n").write(to: transcriptURL, atomically: true, encoding: .utf8)
        let hub = AgentEventHub()
        let session = makeStartedCodexSession(transcriptURL, hub: hub, readySentinel: "a-1")
        defer { session.stop() }
        let epoch = hub.currentHistoryEpoch(sessionID: "session")
        if case .unavailable = session.afterCursorPlan(afterSeq: 0, expectedEpoch: epoch).mode {
        } else {
            XCTFail("an arbitrary unknown subtype must still poison the plan")
        }
        XCTAssertFalse(session.validateHistoryEpoch(epoch),
                       "an arbitrary unknown subtype must still poison validation")
    }

    // Guard: session_meta with the matching id and an ABSENT cli_version is
    // legacy-compatible — only an explicit non-string value poisons.
    func testCodexSessionMetaAbsentCliVersionStaysLegacyCompatible() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexTranscriptSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcriptURL = directory.appendingPathComponent("rollout.jsonl", isDirectory: false)
        let lines = [
            "{\"type\":\"session_meta\",\"timestamp\":\"2026-05-15T00:00:00Z\",\"payload\":{\"id\":\"session\"}}",
            makeCodexMessageLine(role: "assistant", content: "a-0"),
        ]
        try (lines.joined(separator: "\n") + "\n").write(to: transcriptURL, atomically: true, encoding: .utf8)
        let hub = AgentEventHub()
        let session = makeStartedCodexSession(transcriptURL, hub: hub, readySentinel: "a-0")
        defer { session.stop() }
        let epoch = hub.currentHistoryEpoch(sessionID: "session")
        switch session.afterCursorPlan(afterSeq: 0, expectedEpoch: epoch).mode {
        case .rawCovered, .scan:
            break
        case .hubOnly, .unavailable:
            XCTFail("an absent cli_version is legacy-compatible, not a violation")
        }
        XCTAssertTrue(session.validateHistoryEpoch(epoch))
    }

    // Official FunctionCallOutput.output schema (codex-rs models.rs @
    // rust-v0.145.0, 25af12f7): String or Array of input_text /
    // input_image / input_audio / encrypted_content. The human-readable
    // conversion keeps ONLY nonblank input_text, joined with a single
    // "\n"; media/encrypted blocks are legal but contribute no text (the
    // text on both sides keeps its order — the media itself never enters
    // the String output).
    func testCodexStructuredFunctionOutputPreservesTextBlocks() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexTranscriptSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcriptURL = directory.appendingPathComponent("rollout.jsonl", isDirectory: false)
        let outputBlocks = "[{\"type\":\"input_text\",\"text\":\"part-1\"},{\"type\":\"input_text\",\"text\":\"   \"},{\"type\":\"input_image\",\"detail\":\"original\",\"image_url\":\"data:image/png;base64,AA==\"},{\"type\":\"input_audio\",\"audio_url\":\"data:audio/wav;base64,AA==\"},{\"type\":\"encrypted_content\",\"encrypted_content\":\"AAAA\"},{\"type\":\"input_text\",\"text\":\"part-2\"}]"
        let lines = [
            "{\"type\":\"response_item\",\"timestamp\":\"2026-05-15T00:00:00Z\",\"payload\":{\"type\":\"function_call\",\"call_id\":\"call-1\",\"name\":\"shell\",\"arguments\":\"{}\"}}",
            "{\"type\":\"response_item\",\"timestamp\":\"2026-05-15T00:00:01Z\",\"payload\":{\"type\":\"function_call_output\",\"call_id\":\"call-1\",\"output\":\(outputBlocks)}}",
            "{\"type\":\"response_item\",\"timestamp\":\"2026-05-15T00:00:02Z\",\"payload\":{\"type\":\"function_call_output\",\"call_id\":\"call-1\",\"output\":[{\"type\":\"input_text\",\"text\":\"late-duplicate\"}]}}",
            makeCodexMessageLine(role: "assistant", content: "a-0"),
        ]
        try (lines.joined(separator: "\n") + "\n").write(to: transcriptURL, atomically: true, encoding: .utf8)
        let hub = AgentEventHub()
        let session = makeStartedCodexSession(transcriptURL, hub: hub, readySentinel: "a-0")
        defer { session.stop() }
        let results = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 50)
            .events.filter { $0.eventID == "call-1:function-output" }
        XCTAssertEqual(results.count, 1,
                       "the structured output resolves the call EXACTLY once — the resolved-ID dedupe holds")
        XCTAssertEqual(results.first?.output, "part-1\npart-2",
                       "official nonblank-input_text filtering + single-\"\\n\" join, then Tidey's existing outer trim normalization")
        XCTAssertEqual(results.first?.toolCallID, "call-1")
        let epoch = hub.currentHistoryEpoch(sessionID: "session")
        XCTAssertTrue(session.validateHistoryEpoch(epoch),
                      "legal media/encrypted blocks keep the source trusted")
    }

    // Guard: media/encrypted-only Array, empty String, and empty Array
    // outputs are legal no-text products — no event, no poison.
    func testCodexEventlessFunctionOutputsStayLegal() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexTranscriptSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcriptURL = directory.appendingPathComponent("rollout.jsonl", isDirectory: false)
        let lines = [
            "{\"type\":\"response_item\",\"timestamp\":\"2026-05-15T00:00:00Z\",\"payload\":{\"type\":\"function_call_output\",\"call_id\":\"img-only\",\"output\":[{\"type\":\"input_image\",\"detail\":\"auto\",\"image_url\":\"data:image/png;base64,AA==\"}]}}",
            "{\"type\":\"response_item\",\"timestamp\":\"2026-05-15T00:00:01Z\",\"payload\":{\"type\":\"function_call_output\",\"call_id\":\"empty-str\",\"output\":\"\"}}",
            "{\"type\":\"response_item\",\"timestamp\":\"2026-05-15T00:00:02Z\",\"payload\":{\"type\":\"function_call_output\",\"call_id\":\"empty-arr\",\"output\":[]}}",
            "{\"type\":\"response_item\",\"timestamp\":\"2026-05-15T00:00:03Z\",\"payload\":{\"type\":\"function_call_output\",\"call_id\":\"media-enc-only\",\"output\":[{\"type\":\"input_audio\",\"audio_url\":\"data:audio/wav;base64,AA==\"},{\"type\":\"encrypted_content\",\"encrypted_content\":\"AAAA\"}]}}",
            makeCodexMessageLine(role: "assistant", content: "a-0"),
        ]
        try (lines.joined(separator: "\n") + "\n").write(to: transcriptURL, atomically: true, encoding: .utf8)
        let hub = AgentEventHub()
        let session = makeStartedCodexSession(transcriptURL, hub: hub, readySentinel: "a-0")
        defer { session.stop() }
        XCTAssertFalse(hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 50)
                        .events.contains { $0.type == .toolResult },
                       "eventless legal outputs publish nothing")
        let epoch = hub.currentHistoryEpoch(sessionID: "session")
        switch session.afterCursorPlan(afterSeq: 0, expectedEpoch: epoch).mode {
        case .rawCovered, .scan:
            break
        case .hubOnly, .unavailable:
            XCTFail("eventless legal outputs must not poison the plan")
        }
        XCTAssertTrue(session.validateHistoryEpoch(epoch))
    }

    // A record whose type is KNOWN to produce history events but whose
    // required fields are missing or mistyped is un-understandable data.
    // Silently returning while raw coverage advances would fake complete
    // cross-page history — every such row must fail closed. Each row sits
    // BELOW the bootstrap floor so the initial plan is a scan and the walk
    // must poison mid-replay without leaking same-page partial products.
    func testCodexMalformedProducerPayloadsFailClosed() throws {
        func responseItem(_ payload: String) -> String {
            "{\"type\":\"response_item\",\"timestamp\":\"2026-05-15T00:00:00Z\",\"payload\":\(payload)}"
        }
        func eventMsg(_ payload: String) -> String {
            "{\"type\":\"event_msg\",\"timestamp\":\"2026-05-15T00:00:00Z\",\"payload\":\(payload)}"
        }
        let rows: [(name: String, lines: [String])] = [
            ("message-role-missing", [responseItem("{\"type\":\"message\",\"content\":[{\"type\":\"input_text\",\"text\":\"hi\"}]}")]),
            ("message-role-wrong-type", [responseItem("{\"type\":\"message\",\"role\":7,\"content\":[{\"type\":\"input_text\",\"text\":\"hi\"}]}")]),
            ("message-role-empty", [responseItem("{\"type\":\"message\",\"role\":\"\",\"content\":[{\"type\":\"input_text\",\"text\":\"hi\"}]}")]),
            ("message-role-unknown", [responseItem("{\"type\":\"message\",\"role\":\"narrator\",\"content\":[{\"type\":\"input_text\",\"text\":\"hi\"}]}")]),
            ("message-content-missing", [responseItem("{\"type\":\"message\",\"role\":\"user\"}")]),
            ("message-content-wrong-type", [responseItem("{\"type\":\"message\",\"role\":\"user\",\"content\":42}")]),
            ("message-content-block-nondict", [responseItem("{\"type\":\"message\",\"role\":\"user\",\"content\":[\"oops\"]}")]),
            ("message-content-block-missing-type", [responseItem("{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"text\":\"x\"}]}")]),
            ("message-content-block-unknown-type", [responseItem("{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"video\"}]}")]),
            ("message-text-block-nonstring-text", [responseItem("{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":5}]}")]),
            ("message-text-block-missing-text", [responseItem("{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"output_text\"}]}")]),
            ("message-input-image-missing-url", [responseItem("{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_image\",\"detail\":\"high\"}]}")]),
            ("message-input-image-nonstring-url", [responseItem("{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_image\",\"image_url\":9}]}")]),
            ("message-phase-nonstring", [responseItem("{\"type\":\"message\",\"role\":\"assistant\",\"phase\":7,\"content\":[{\"type\":\"input_text\",\"text\":\"hi\"}]}")]),
            ("function-call-call-id-missing", [responseItem("{\"type\":\"function_call\",\"name\":\"shell\",\"arguments\":\"{}\"}")]),
            ("function-call-call-id-wrong-type", [responseItem("{\"type\":\"function_call\",\"call_id\":7,\"name\":\"shell\",\"arguments\":\"{}\"}")]),
            ("function-call-call-id-empty", [responseItem("{\"type\":\"function_call\",\"call_id\":\"\",\"name\":\"shell\",\"arguments\":\"{}\"}")]),
            ("function-call-name-missing", [responseItem("{\"type\":\"function_call\",\"call_id\":\"c1\",\"arguments\":\"{}\"}")]),
            ("function-call-name-wrong-type", [responseItem("{\"type\":\"function_call\",\"call_id\":\"c1\",\"name\":4,\"arguments\":\"{}\"}")]),
            ("function-call-name-empty", [responseItem("{\"type\":\"function_call\",\"call_id\":\"c1\",\"name\":\"\",\"arguments\":\"{}\"}")]),
            ("function-call-arguments-missing", [responseItem("{\"type\":\"function_call\",\"call_id\":\"c1\",\"name\":\"shell\"}")]),
            ("function-call-arguments-wrong-type", [responseItem("{\"type\":\"function_call\",\"call_id\":\"c1\",\"name\":\"shell\",\"arguments\":7}")]),
            ("function-output-call-id-missing", [responseItem("{\"type\":\"function_call_output\",\"output\":\"x\"}")]),
            ("function-output-call-id-wrong-type", [responseItem("{\"type\":\"function_call_output\",\"call_id\":7,\"output\":\"x\"}")]),
            ("function-output-call-id-empty", [responseItem("{\"type\":\"function_call_output\",\"call_id\":\"\",\"output\":\"x\"}")]),
            ("function-output-output-missing", [responseItem("{\"type\":\"function_call_output\",\"call_id\":\"c1\"}")]),
            ("function-output-output-wrong-type", [responseItem("{\"type\":\"function_call_output\",\"call_id\":\"c1\",\"output\":7}")]),
            ("function-output-block-malformed", [responseItem("{\"type\":\"function_call_output\",\"call_id\":\"c1\",\"output\":[{\"type\":\"input_text\",\"text\":3}]}")]),
            ("function-output-block-unknown", [responseItem("{\"type\":\"function_call_output\",\"call_id\":\"c1\",\"output\":[{\"type\":\"mystery\"}]}")]),
            ("function-output-malformed-duplicate-after-legal",
             [responseItem("{\"type\":\"function_call_output\",\"call_id\":\"dup-1\",\"output\":\"legal first\"}"),
              responseItem("{\"type\":\"function_call_output\",\"call_id\":\"dup-1\",\"output\":7}")]),
            ("agent-message-message-missing", [eventMsg("{\"type\":\"agent_message\",\"phase\":\"commentary\"}")]),
            ("agent-message-message-wrong-type", [eventMsg("{\"type\":\"agent_message\",\"message\":7,\"phase\":\"commentary\"}")]),
            // phase-missing removed: phase is Option<MessagePhase>
            // (protocol.rs @ 25af12f7 L2153-2160) — absent is legal; see
            // testCodexAgentMessagePhaseOptionPairing.
            ("agent-message-phase-wrong-type", [eventMsg("{\"type\":\"agent_message\",\"message\":\"hi\",\"phase\":7}")]),
            ("agent-message-phase-unknown", [eventMsg("{\"type\":\"agent_message\",\"message\":\"hi\",\"phase\":\"draft\"}")]),
            ("exec-end-call-id-missing", [eventMsg("{\"type\":\"exec_command_end\",\"stdout\":\"ok\",\"stderr\":\"\",\"formatted_output\":\"\",\"aggregated_output\":\"\",\"exit_code\":0,\"status\":\"completed\"}")]),
            ("exec-end-call-id-wrong-type", [eventMsg("{\"type\":\"exec_command_end\",\"call_id\":7,\"stdout\":\"ok\",\"stderr\":\"\",\"formatted_output\":\"\",\"aggregated_output\":\"\",\"exit_code\":0,\"status\":\"completed\"}")]),
            ("exec-end-call-id-empty", [eventMsg("{\"type\":\"exec_command_end\",\"call_id\":\"\",\"stdout\":\"ok\",\"stderr\":\"\",\"formatted_output\":\"\",\"aggregated_output\":\"\",\"exit_code\":0,\"status\":\"completed\"}")]),
            ("exec-end-nonstring-candidate-not-hidden", [eventMsg("{\"type\":\"exec_command_end\",\"call_id\":\"e1\",\"aggregated_output\":5,\"stdout\":\"ok\",\"stderr\":\"\",\"formatted_output\":\"\",\"exit_code\":0,\"status\":\"completed\"}")]),
            ("patch-end-call-id-empty", [eventMsg("{\"type\":\"patch_apply_end\",\"call_id\":\"\",\"stdout\":\"ok\",\"stderr\":\"\",\"success\":true,\"status\":\"completed\"}")]),
            ("patch-end-nonstring-candidate-not-hidden", [eventMsg("{\"type\":\"patch_apply_end\",\"call_id\":\"p1\",\"stdout\":3,\"stderr\":\"ok\",\"success\":true,\"status\":\"completed\"}")]),
        ]
        for row in rows {
            // Each row runs in its own function scope so the session and
            // its file watcher stop before the next row, on failure too.
            try assertDeepRowFailsClosed(name: row.name, rowLines: row.lines)
        }
    }

    // Guards for already-correct contracts (recorded as retrospective
    // pre-green unless a run shows otherwise):
    // an eventless output leaves the call unresolved, so a LATER legal
    // text output for the same call still yields exactly one tool result.
    func testCodexLaterTextOutputAfterEventlessOutputResolvesOnce() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexTranscriptSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcriptURL = directory.appendingPathComponent("rollout.jsonl", isDirectory: false)
        let lines = [
            "{\"type\":\"response_item\",\"timestamp\":\"2026-05-15T00:00:00Z\",\"payload\":{\"type\":\"function_call_output\",\"call_id\":\"late-text\",\"output\":[{\"type\":\"input_image\",\"detail\":\"high\",\"image_url\":\"data:image/png;base64,AA==\"}]}}",
            "{\"type\":\"response_item\",\"timestamp\":\"2026-05-15T00:00:01Z\",\"payload\":{\"type\":\"function_call_output\",\"call_id\":\"late-text\",\"output\":\"\"}}",
            "{\"type\":\"response_item\",\"timestamp\":\"2026-05-15T00:00:02Z\",\"payload\":{\"type\":\"function_call_output\",\"call_id\":\"late-text\",\"output\":[{\"type\":\"input_text\",\"text\":\"the real text\"}]}}",
            makeCodexMessageLine(role: "assistant", content: "a-0"),
        ]
        try (lines.joined(separator: "\n") + "\n").write(to: transcriptURL, atomically: true, encoding: .utf8)
        let hub = AgentEventHub()
        let session = makeStartedCodexSession(transcriptURL, hub: hub, readySentinel: "a-0")
        defer { session.stop() }
        let results = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 50)
            .events.filter { $0.eventID == "late-text:function-output" }
        XCTAssertEqual(results.count, 1, "exactly one tool result after eventless predecessors")
        XCTAssertEqual(results.first?.output, "the real text")
        XCTAssertTrue(session.validateHistoryEpoch(hub.currentHistoryEpoch(sessionID: "session")))
    }

    // Guards: a non-string output candidate arriving AFTER the call ID was
    // legally resolved must still poison — validation runs before the
    // resolved-ID dedupe for exec_command_end and patch_apply_end too.
    // Plus the patch call_id missing/wrong-type rows the original table
    // lacked (it only had the empty-string variant).
    func testCodexExecAndPatchValidationStaysAheadOfDedupe() throws {
        func eventMsg(_ payload: String) -> String {
            "{\"type\":\"event_msg\",\"timestamp\":\"2026-05-15T00:00:00Z\",\"payload\":\(payload)}"
        }
        let rows: [(name: String, lines: [String])] = [
            ("exec-nonstring-candidate-after-resolved",
             [eventMsg("{\"type\":\"exec_command_end\",\"call_id\":\"exec-dup\",\"stdout\":\"legal first\",\"stderr\":\"\",\"formatted_output\":\"\",\"aggregated_output\":\"\",\"exit_code\":0,\"status\":\"completed\"}"),
              eventMsg("{\"type\":\"exec_command_end\",\"call_id\":\"exec-dup\",\"stdout\":7,\"stderr\":\"\",\"formatted_output\":\"\",\"aggregated_output\":\"\",\"exit_code\":0,\"status\":\"completed\"}")]),
            ("patch-nonstring-candidate-after-resolved",
             [eventMsg("{\"type\":\"patch_apply_end\",\"call_id\":\"patch-dup\",\"stdout\":\"\",\"stderr\":\"legal first\",\"success\":true,\"status\":\"completed\"}"),
              eventMsg("{\"type\":\"patch_apply_end\",\"call_id\":\"patch-dup\",\"stdout\":\"\",\"stderr\":7,\"success\":true,\"status\":\"completed\"}")]),
            ("patch-end-call-id-missing", [eventMsg("{\"type\":\"patch_apply_end\",\"stdout\":\"ok\",\"stderr\":\"\",\"success\":true,\"status\":\"completed\"}")]),
            ("patch-end-call-id-wrong-type", [eventMsg("{\"type\":\"patch_apply_end\",\"call_id\":7,\"stdout\":\"ok\",\"stderr\":\"\",\"success\":true,\"status\":\"completed\"}")]),
        ]
        for row in rows {
            try assertDeepRowFailsClosed(name: row.name, rowLines: row.lines)
        }
    }

    // Guard: legal records that yield no product — empty text, image-only
    // content, role/phase product policy, JSON-null phase (23,916 observed
    // real records), absent/empty output candidates — must NOT poison.
    func testCodexLegalNoProductProducerRecordsStayTrusted() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexTranscriptSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcriptURL = directory.appendingPathComponent("rollout.jsonl", isDirectory: false)
        let lines = [
            "{\"type\":\"response_item\",\"timestamp\":\"2026-05-15T00:00:00Z\",\"payload\":{\"type\":\"message\",\"role\":\"developer\",\"content\":[{\"type\":\"input_text\",\"text\":\"policy text\"}]}}",
            "{\"type\":\"response_item\",\"timestamp\":\"2026-05-15T00:00:01Z\",\"payload\":{\"type\":\"message\",\"role\":\"assistant\",\"phase\":\"commentary\",\"content\":[{\"type\":\"output_text\",\"text\":\"covered by event_msg\"}]}}",
            "{\"type\":\"response_item\",\"timestamp\":\"2026-05-15T00:00:02Z\",\"payload\":{\"type\":\"message\",\"role\":\"user\",\"content\":[]}}",
            "{\"type\":\"response_item\",\"timestamp\":\"2026-05-15T00:00:03Z\",\"payload\":{\"type\":\"message\",\"role\":\"user\",\"phase\":null,\"content\":[{\"type\":\"input_image\",\"detail\":\"auto\",\"image_url\":\"data:image/png;base64,AA==\"}]}}",
            "{\"type\":\"event_msg\",\"timestamp\":\"2026-05-15T00:00:04Z\",\"payload\":{\"type\":\"agent_message\",\"message\":\"\",\"phase\":\"commentary\"}}",
            "{\"type\":\"response_item\",\"timestamp\":\"2026-05-15T00:00:05Z\",\"payload\":{\"type\":\"function_call\",\"call_id\":\"empty-args\",\"name\":\"noop\",\"arguments\":\"\"}}",
            "{\"type\":\"event_msg\",\"timestamp\":\"2026-05-15T00:00:07Z\",\"payload\":{\"type\":\"exec_command_end\",\"call_id\":\"empty-candidates\",\"aggregated_output\":\"\",\"formatted_output\":\"\",\"stdout\":\"\",\"stderr\":\"\",\"exit_code\":0,\"status\":\"completed\"}}",
            "{\"type\":\"event_msg\",\"timestamp\":\"2026-05-15T00:00:08Z\",\"payload\":{\"type\":\"patch_apply_end\",\"call_id\":\"empty-patch\",\"stdout\":\"\",\"stderr\":\"\",\"success\":true,\"status\":\"completed\"}}",
            makeCodexMessageLine(role: "assistant", content: "a-0"),
        ]
        try (lines.joined(separator: "\n") + "\n").write(to: transcriptURL, atomically: true, encoding: .utf8)
        let hub = AgentEventHub()
        let session = makeStartedCodexSession(transcriptURL, hub: hub, readySentinel: "a-0")
        defer { session.stop() }
        let epoch = hub.currentHistoryEpoch(sessionID: "session")
        switch session.afterCursorPlan(afterSeq: 0, expectedEpoch: epoch).mode {
        case .rawCovered, .scan:
            break
        case .hubOnly, .unavailable:
            XCTFail("legal no-product records must keep the source plannable")
        }
        XCTAssertTrue(session.validateHistoryEpoch(epoch),
                      "legal no-product records keep the source trusted")
    }

    // One deep-page fail-closed check per call: the row's record(s) sit
    // below the bootstrap floor, the initial plan must scan, and the walk
    // must poison without leaking same-page partial products. Running each
    // row in its own function scope guarantees the session and its file
    // watcher stop before the next row starts, on failure paths too.
    private func assertDeepRowFailsClosed(name: String,
                                          rowLines: [String],
                                          file: StaticString = #filePath,
                                          line: UInt = #line) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexTranscriptSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcriptURL = directory.appendingPathComponent("rollout.jsonl", isDirectory: false)
        let lineCount = transcriptBootstrapLineLimit + 20
        var lines = (0..<lineCount).map {
            makeCodexMessageLine(role: "assistant",
                                 content: "deep-\($0)-" + String(repeating: "x", count: 40))
        }
        for (offset, rowLine) in rowLines.enumerated() {
            lines[3 + offset] = rowLine
        }
        try (lines.joined(separator: "\n") + "\n").write(to: transcriptURL, atomically: true, encoding: .utf8)
        let hub = AgentEventHub()
        let session = makeStartedCodexSession(transcriptURL, hub: hub,
                                              readySentinel: "deep-\(lineCount - 1)-" + String(repeating: "x", count: 40))
        defer { session.stop() }
        let epoch = hub.currentHistoryEpoch(sessionID: "session")
        let plan = session.afterCursorPlan(afterSeq: 0, expectedEpoch: epoch)
        guard case .scan(let startAnchor) = plan.mode else {
            XCTFail("\(name): precondition — a below-floor cursor plans a scan, got \(plan.mode)",
                    file: file, line: line)
            return
        }
        var anchor = startAnchor
        var sawUnavailable = false
        walk: for _ in 0..<4 {
            let step = session.afterCursorStep(from: anchor, afterSeq: 0, limit: lineCount + 100)
            switch step.outcome {
            case .advanced(let next):
                anchor = next
            case .unavailable:
                XCTAssertTrue(step.events.isEmpty,
                              "\(name): a poisoned step must not leak same-page partial products",
                              file: file, line: line)
                sawUnavailable = true
                break walk
            case .complete:
                XCTFail("\(name): the walk must not complete past a malformed record",
                        file: file, line: line)
                break walk
            case .sourceChanged:
                XCTFail("\(name): a malformed record is not a source change", file: file, line: line)
                break walk
            }
        }
        XCTAssertTrue(sawUnavailable, "\(name): the malformed page fails the step closed",
                      file: file, line: line)
        if case .unavailable = session.afterCursorPlan(afterSeq: 0, expectedEpoch: epoch).mode {
        } else {
            XCTFail("\(name): the poison persists for later plans", file: file, line: line)
        }
        XCTAssertFalse(session.validateHistoryEpoch(epoch),
                       "\(name): the poison persists for validation", file: file, line: line)
    }

    // Official FunctionCallOutput.output block allowlist (models.rs @
    // rust-v0.145.0): input_text / input_image / input_audio /
    // encrypted_content. output_text, text, and summary_text are NOT in
    // the function-output schema and have zero evidence in the full local
    // corpus — fail closed. Required fields and the ImageDetail enum
    // (auto/low/high/original) are enforced.
    func testCodexFunctionOutputProfileViolationsFailClosed() throws {
        func fco(_ output: String) -> String {
            "{\"type\":\"response_item\",\"timestamp\":\"2026-05-15T00:00:00Z\",\"payload\":{\"type\":\"function_call_output\",\"call_id\":\"c1\",\"output\":\(output)}}"
        }
        let rows: [(name: String, output: String)] = [
            ("fco-output-text-block", "[{\"type\":\"output_text\",\"text\":\"x\"}]"),
            ("fco-text-block", "[{\"type\":\"text\",\"text\":\"x\"}]"),
            ("fco-summary-text-block", "[{\"type\":\"summary_text\",\"text\":\"x\"}]"),
            ("fco-audio-missing-url", "[{\"type\":\"input_audio\"}]"),
            ("fco-audio-nonstring-url", "[{\"type\":\"input_audio\",\"audio_url\":7}]"),
            ("fco-encrypted-missing-field", "[{\"type\":\"encrypted_content\"}]"),
            ("fco-encrypted-nonstring-field", "[{\"type\":\"encrypted_content\",\"encrypted_content\":7}]"),
            ("fco-image-illegal-detail", "[{\"type\":\"input_image\",\"image_url\":\"u\",\"detail\":\"giant\"}]"),
            ("fco-image-nonstring-detail", "[{\"type\":\"input_image\",\"image_url\":\"u\",\"detail\":7}]"),
        ]
        for row in rows {
            try assertDeepRowFailsClosed(name: row.name, rowLines: [fco(row.output)])
        }
    }

    // Official ResponseItem::Message.content schema (models.rs @
    // rust-v0.145.0): an ARRAY of input_text / output_text / input_image /
    // input_audio. A top-level String and the text / summary_text /
    // encrypted_content blocks are not in the schema and have zero
    // evidence across ALL 1,164 local rollout files (inventory v2,
    // 2026-07-25) — fail closed, no legacy catalog. phase is
    // Option<MessagePhase>: absent, JSON null, commentary, and
    // final_answer are legal; an unknown String is not.
    func testCodexMessageProfileMatchesOfficialSchema() throws {
        func message(_ payloadTail: String) -> String {
            "{\"type\":\"response_item\",\"timestamp\":\"2026-05-15T00:00:00Z\",\"payload\":{\"type\":\"message\",\(payloadTail)}}"
        }
        let poisonRows: [(name: String, payloadTail: String)] = [
            ("message-string-content", "\"role\":\"user\",\"content\":\"legacy string\""),
            ("message-text-block", "\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"x\"}]"),
            ("message-summary-text-block", "\"role\":\"user\",\"content\":[{\"type\":\"summary_text\",\"text\":\"x\"}]"),
            ("message-unknown-phase-string", "\"role\":\"assistant\",\"phase\":\"draft\",\"content\":[{\"type\":\"input_text\",\"text\":\"hi\"}]"),
            ("message-image-illegal-detail", "\"role\":\"user\",\"content\":[{\"type\":\"input_image\",\"image_url\":\"u\",\"detail\":\"giant\"}]"),
            ("message-audio-nonstring-url", "\"role\":\"user\",\"content\":[{\"type\":\"input_audio\",\"audio_url\":7}]"),
            ("message-encrypted-content-block", "\"role\":\"user\",\"content\":[{\"type\":\"encrypted_content\",\"encrypted_content\":\"AAAA\"}]"),
        ]
        for row in poisonRows {
            try assertDeepRowFailsClosed(name: row.name, rowLines: [message(row.payloadTail)])
        }

        // Legal side: input_audio is a legal message no-text block,
        // output_text is legal text, and phase absent / JSON null /
        // commentary / final_answer are all legal.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexTranscriptSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcriptURL = directory.appendingPathComponent("rollout.jsonl", isDirectory: false)
        let lines = [
            message("\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"legal-audio-msg\"},{\"type\":\"input_audio\",\"audio_url\":\"data:audio/wav;base64,AA==\"}]"),
            message("\"role\":\"assistant\",\"phase\":null,\"content\":[{\"type\":\"output_text\",\"text\":\"null-phase-msg\"}]"),
            message("\"role\":\"assistant\",\"phase\":\"commentary\",\"content\":[{\"type\":\"output_text\",\"text\":\"policy no-product\"}]"),
            makeCodexMessageLine(role: "assistant", content: "a-0"),
        ]
        try (lines.joined(separator: "\n") + "\n").write(to: transcriptURL, atomically: true, encoding: .utf8)
        let hub = AgentEventHub()
        let session = makeStartedCodexSession(transcriptURL, hub: hub, readySentinel: "a-0")
        defer { session.stop() }
        let events = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 50).events
        XCTAssertTrue(events.contains { $0.text == "legal-audio-msg" },
                      "a legal input_audio block must not poison the user message around it")
        XCTAssertTrue(events.contains { $0.text == "null-phase-msg" },
                      "JSON-null phase is legal (Option<MessagePhase>)")
        let epoch = hub.currentHistoryEpoch(sessionID: "session")
        XCTAssertTrue(session.validateHistoryEpoch(epoch))
    }

    // input_image.detail is Option<ImageDetail> in the official schema:
    // absent, explicit JSON null, and the four enum values are legal in
    // BOTH content contexts; anything else is malformed.
    func testCodexOptionalNullDetailStaysLegal() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexTranscriptSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcriptURL = directory.appendingPathComponent("rollout.jsonl", isDirectory: false)
        let lines = [
            "{\"type\":\"response_item\",\"timestamp\":\"2026-05-15T00:00:00Z\",\"payload\":{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"null-detail-msg\"},{\"type\":\"input_image\",\"detail\":null,\"image_url\":\"data:image/png;base64,AA==\"}]}}",
            "{\"type\":\"response_item\",\"timestamp\":\"2026-05-15T00:00:01Z\",\"payload\":{\"type\":\"function_call_output\",\"call_id\":\"null-detail-fco\",\"output\":[{\"type\":\"input_text\",\"text\":\"null-detail-out\"},{\"type\":\"input_image\",\"detail\":null,\"image_url\":\"data:image/png;base64,AA==\"}]}}",
            makeCodexMessageLine(role: "assistant", content: "a-0"),
        ]
        try (lines.joined(separator: "\n") + "\n").write(to: transcriptURL, atomically: true, encoding: .utf8)
        let hub = AgentEventHub()
        let session = makeStartedCodexSession(transcriptURL, hub: hub, readySentinel: "a-0")
        defer { session.stop() }
        let events = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 50).events
        XCTAssertTrue(events.contains { $0.text == "null-detail-msg" },
                      "explicit null detail is legal in the message context")
        XCTAssertTrue(events.contains { $0.output == "null-detail-out" },
                      "explicit null detail is legal in the function-output context")
        XCTAssertTrue(session.validateHistoryEpoch(hub.currentHistoryEpoch(sessionID: "session")))
    }

    // Standalone guard in its own file: a poison from another same-file
    // row can no longer fail it collaterally. The official enums set no
    // deny_unknown_fields, so extra keys on legal records and blocks are
    // ignored, never poisoned.
    func testCodexExtraKeysOnLegalRecordsStayLegal() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexTranscriptSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcriptURL = directory.appendingPathComponent("rollout.jsonl", isDirectory: false)
        let lines = [
            "{\"type\":\"response_item\",\"timestamp\":\"2026-05-15T00:00:00Z\",\"payload\":{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"extra-keys-msg\",\"annotations\":[],\"future_field\":1}],\"unknown_top_field\":true}}",
            makeCodexMessageLine(role: "assistant", content: "a-0"),
        ]
        try (lines.joined(separator: "\n") + "\n").write(to: transcriptURL, atomically: true, encoding: .utf8)
        let hub = AgentEventHub()
        let session = makeStartedCodexSession(transcriptURL, hub: hub, readySentinel: "a-0")
        defer { session.stop() }
        XCTAssertTrue(hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 50)
                        .events.contains { $0.text == "extra-keys-msg" },
                      "extra keys on legal records/blocks are ignored, not poisoned")
        XCTAssertTrue(session.validateHistoryEpoch(hub.currentHistoryEpoch(sessionID: "session")))
    }

    // exec/patch metadata is producer contract too (inventory over all
    // local rollouts: exec exit_code always a JSON Number, status always a
    // String; patch success always a Boolean, status always a String).
    // Fields stay optional for legacy fixtures, but an explicit
    // wrong-typed value must poison — silently rendering it to nil while
    // raw coverage advances is the same silent-gap bug. The Bool rows pin
    // that an NSNumber Bool bridge (CFBoolean) cannot pass as a Number.
    func testCodexExecPatchMetadataSchemaFailsClosed() throws {
        func eventMsg(_ payload: String) -> String {
            "{\"type\":\"event_msg\",\"timestamp\":\"2026-05-15T00:00:00Z\",\"payload\":\(payload)}"
        }
        let rows: [(name: String, lines: [String])] = [
            ("exec-exit-code-string", [eventMsg("{\"type\":\"exec_command_end\",\"call_id\":\"e1\",\"exit_code\":\"0\",\"stdout\":\"ok\",\"stderr\":\"\",\"formatted_output\":\"\",\"aggregated_output\":\"\",\"status\":\"completed\"}")]),
            ("exec-exit-code-bool", [eventMsg("{\"type\":\"exec_command_end\",\"call_id\":\"e1\",\"exit_code\":true,\"stdout\":\"ok\",\"stderr\":\"\",\"formatted_output\":\"\",\"aggregated_output\":\"\",\"status\":\"completed\"}")]),
            ("exec-status-non-string", [eventMsg("{\"type\":\"exec_command_end\",\"call_id\":\"e1\",\"status\":7,\"stdout\":\"ok\",\"stderr\":\"\",\"formatted_output\":\"\",\"aggregated_output\":\"\",\"exit_code\":0}")]),
            ("patch-success-non-bool-number", [eventMsg("{\"type\":\"patch_apply_end\",\"call_id\":\"p1\",\"success\":1,\"stdout\":\"ok\",\"stderr\":\"\",\"status\":\"completed\"}")]),
            ("patch-success-non-bool-string", [eventMsg("{\"type\":\"patch_apply_end\",\"call_id\":\"p1\",\"success\":\"yes\",\"stdout\":\"ok\",\"stderr\":\"\",\"status\":\"completed\"}")]),
            ("patch-status-non-string", [eventMsg("{\"type\":\"patch_apply_end\",\"call_id\":\"p1\",\"status\":7,\"stdout\":\"ok\",\"stderr\":\"\",\"success\":true}")]),
            ("exec-malformed-metadata-after-resolved",
             [eventMsg("{\"type\":\"exec_command_end\",\"call_id\":\"em-dup\",\"exit_code\":0,\"status\":\"completed\",\"stdout\":\"legal first\",\"stderr\":\"\",\"formatted_output\":\"\",\"aggregated_output\":\"\"}"),
              eventMsg("{\"type\":\"exec_command_end\",\"call_id\":\"em-dup\",\"exit_code\":\"0\",\"status\":\"completed\",\"stdout\":\"dup\",\"stderr\":\"\",\"formatted_output\":\"\",\"aggregated_output\":\"\"}")]),
            ("patch-malformed-metadata-after-resolved",
             [eventMsg("{\"type\":\"patch_apply_end\",\"call_id\":\"pm-dup\",\"success\":true,\"status\":\"completed\",\"stdout\":\"legal first\",\"stderr\":\"\"}"),
              eventMsg("{\"type\":\"patch_apply_end\",\"call_id\":\"pm-dup\",\"success\":1,\"status\":\"completed\",\"stdout\":\"dup\",\"stderr\":\"\"}")]),
        ]
        for row in rows {
            try assertDeepRowFailsClosed(name: row.name, rowLines: row.lines)
        }

        // Legal side: well-typed metadata (Number exit code, Boolean
        // success, String status) keeps the source trusted and reaches the
        // product; absent fields stay legal.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexTranscriptSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcriptURL = directory.appendingPathComponent("rollout.jsonl", isDirectory: false)
        let lines = [
            eventMsg("{\"type\":\"exec_command_end\",\"call_id\":\"legal-exec\",\"exit_code\":0,\"status\":\"completed\",\"stdout\":\"exec-out\",\"stderr\":\"\",\"formatted_output\":\"\",\"aggregated_output\":\"\"}"),
            eventMsg("{\"type\":\"patch_apply_end\",\"call_id\":\"legal-patch\",\"success\":true,\"status\":\"completed\",\"stdout\":\"patch-out\",\"stderr\":\"\"}"),
            eventMsg("{\"type\":\"exec_command_end\",\"call_id\":\"absent-meta\",\"exit_code\":0,\"status\":\"completed\",\"stdout\":\"bare-out\",\"stderr\":\"\",\"formatted_output\":\"\"}"),
            makeCodexMessageLine(role: "assistant", content: "a-0"),
        ]
        try (lines.joined(separator: "\n") + "\n").write(to: transcriptURL, atomically: true, encoding: .utf8)
        let hub = AgentEventHub()
        let session = makeStartedCodexSession(transcriptURL, hub: hub, readySentinel: "a-0")
        defer { session.stop() }
        let events = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 50).events
        let execResult = events.first { $0.eventID == "legal-exec:exec-end" }
        XCTAssertEqual(execResult?.output, "exec-out")
        XCTAssertEqual(execResult?.metadata?["exit_code"], "0")
        let patchResult = events.first { $0.eventID == "legal-patch:patch-end" }
        XCTAssertEqual(patchResult?.output, "patch-out")
        XCTAssertTrue(events.contains { $0.eventID == "absent-meta:exec-end" },
                      "absent aggregated_output stays legal — the official serde default")
        XCTAssertTrue(session.validateHistoryEpoch(hub.currentHistoryEpoch(sessionID: "session")))
    }

    // Tidey's history PROJECTION of the official 0.145 exec/patch events
    // (audited at the same 25af12f7 commit; the projection covers only
    // the fields Tidey consumes — turn_id/command/cwd/parsed_cmd/duration
    // etc. remain unvalidated producer-schema debt): exec_command_end's
    // projection requires call_id/stdout/stderr/formatted_output Strings,
    // exit_code i32, status enum; only aggregated_output has a serde
    // default (absent → ""). patch_apply_end's projection requires
    // call_id/stdout/stderr Strings, success Bool, status enum. status is
    // exactly {completed, failed, declined}. The full local corpus (1,167
    // files: exec 8,734 / patch 76,687) has ZERO absent or null
    // projection fields — so absence fails closed, no legacy exception.
    func testCodexExecPatchProjectionSchemaFailsClosed() throws {
        func eventMsg(_ payload: String) -> String {
            "{\"type\":\"event_msg\",\"timestamp\":\"2026-05-15T00:00:00Z\",\"payload\":\(payload)}"
        }
        let rows: [(name: String, lines: [String])] = [
            ("exec-stdout-missing", [eventMsg("{\"type\":\"exec_command_end\",\"call_id\":\"e1\",\"stderr\":\"\",\"formatted_output\":\"\",\"aggregated_output\":\"x\",\"exit_code\":0,\"status\":\"completed\"}")]),
            ("exec-stderr-missing", [eventMsg("{\"type\":\"exec_command_end\",\"call_id\":\"e1\",\"stdout\":\"ok\",\"formatted_output\":\"\",\"aggregated_output\":\"\",\"exit_code\":0,\"status\":\"completed\"}")]),
            ("exec-formatted-output-missing", [eventMsg("{\"type\":\"exec_command_end\",\"call_id\":\"e1\",\"stdout\":\"ok\",\"stderr\":\"\",\"aggregated_output\":\"\",\"exit_code\":0,\"status\":\"completed\"}")]),
            ("exec-exit-code-missing", [eventMsg("{\"type\":\"exec_command_end\",\"call_id\":\"e1\",\"stdout\":\"ok\",\"stderr\":\"\",\"formatted_output\":\"\",\"aggregated_output\":\"\",\"status\":\"completed\"}")]),
            ("exec-status-missing", [eventMsg("{\"type\":\"exec_command_end\",\"call_id\":\"e1\",\"stdout\":\"ok\",\"stderr\":\"\",\"formatted_output\":\"\",\"aggregated_output\":\"\",\"exit_code\":0}")]),
            ("exec-status-unknown-enum", [eventMsg("{\"type\":\"exec_command_end\",\"call_id\":\"e1\",\"stdout\":\"ok\",\"stderr\":\"\",\"formatted_output\":\"\",\"aggregated_output\":\"\",\"exit_code\":0,\"status\":\"running\"}")]),
            ("exec-status-null", [eventMsg("{\"type\":\"exec_command_end\",\"call_id\":\"e1\",\"stdout\":\"ok\",\"stderr\":\"\",\"formatted_output\":\"\",\"aggregated_output\":\"\",\"exit_code\":0,\"status\":null}")]),
            ("exec-exit-code-float", [eventMsg("{\"type\":\"exec_command_end\",\"call_id\":\"e1\",\"stdout\":\"ok\",\"stderr\":\"\",\"formatted_output\":\"\",\"aggregated_output\":\"\",\"exit_code\":1.5,\"status\":\"completed\"}")]),
            ("exec-exit-code-i32-overflow", [eventMsg("{\"type\":\"exec_command_end\",\"call_id\":\"e1\",\"stdout\":\"ok\",\"stderr\":\"\",\"formatted_output\":\"\",\"aggregated_output\":\"\",\"exit_code\":3000000000,\"status\":\"completed\"}")]),
            ("patch-stdout-missing", [eventMsg("{\"type\":\"patch_apply_end\",\"call_id\":\"p1\",\"stderr\":\"ok\",\"success\":true,\"status\":\"completed\"}")]),
            ("patch-stderr-missing", [eventMsg("{\"type\":\"patch_apply_end\",\"call_id\":\"p1\",\"stdout\":\"ok\",\"success\":true,\"status\":\"completed\"}")]),
            ("patch-success-missing", [eventMsg("{\"type\":\"patch_apply_end\",\"call_id\":\"p1\",\"stdout\":\"ok\",\"stderr\":\"\",\"status\":\"completed\"}")]),
            ("patch-status-missing", [eventMsg("{\"type\":\"patch_apply_end\",\"call_id\":\"p1\",\"stdout\":\"ok\",\"stderr\":\"\",\"success\":true}")]),
            ("patch-status-unknown-enum", [eventMsg("{\"type\":\"patch_apply_end\",\"call_id\":\"p1\",\"stdout\":\"ok\",\"stderr\":\"\",\"success\":true,\"status\":\"partial\"}")]),
        ]
        for row in rows {
            try assertDeepRowFailsClosed(name: row.name, rowLines: row.lines)
        }
    }

    // Output selection contract, pinned by corpus evidence: 297 real patch
    // records carry a blank stdout with real stderr text — "first PRESENT
    // candidate" silently drops them. The contract is the first NON-BLANK
    // candidate in producer precedence order (exec: aggregated_output →
    // formatted_output → stdout → stderr; patch: stdout → stderr); all
    // candidates blank stays a legal no-text product.
    func testCodexExecPatchOutputSelectionSkipsBlankCandidates() throws {
        func eventMsg(_ timestamp: String, _ payload: String) -> String {
            "{\"type\":\"event_msg\",\"timestamp\":\"\(timestamp)\",\"payload\":\(payload)}"
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexTranscriptSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcriptURL = directory.appendingPathComponent("rollout.jsonl", isDirectory: false)
        let lines = [
            eventMsg("2026-05-15T00:00:00Z", "{\"type\":\"exec_command_end\",\"call_id\":\"blank-first-exec\",\"aggregated_output\":\"\",\"formatted_output\":\"\",\"stdout\":\"exec-std-text\",\"stderr\":\"\",\"exit_code\":0,\"status\":\"completed\"}"),
            eventMsg("2026-05-15T00:00:01Z", "{\"type\":\"patch_apply_end\",\"call_id\":\"blank-first-patch\",\"stdout\":\"   \",\"stderr\":\"patch-err-text\",\"success\":false,\"status\":\"failed\"}"),
            eventMsg("2026-05-15T00:00:02Z", "{\"type\":\"exec_command_end\",\"call_id\":\"all-blank\",\"aggregated_output\":\"\",\"formatted_output\":\"\",\"stdout\":\"\",\"stderr\":\"  \",\"exit_code\":0,\"status\":\"completed\"}"),
            makeCodexMessageLine(role: "assistant", content: "a-0"),
        ]
        try (lines.joined(separator: "\n") + "\n").write(to: transcriptURL, atomically: true, encoding: .utf8)
        let hub = AgentEventHub()
        let session = makeStartedCodexSession(transcriptURL, hub: hub, readySentinel: "a-0")
        defer { session.stop() }
        let events = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 50).events
        XCTAssertEqual(events.first { $0.eventID == "blank-first-exec:exec-end" }?.output,
                       "exec-std-text",
                       "a blank aggregated/formatted output must not shadow real stdout text")
        XCTAssertEqual(events.first { $0.eventID == "blank-first-patch:patch-end" }?.output,
                       "patch-err-text",
                       "a blank stdout must not shadow real stderr text (297 corpus records)")
        XCTAssertFalse(events.contains { $0.eventID == "all-blank:exec-end" },
                       "all-blank candidates stay a legal no-text product")
        XCTAssertTrue(session.validateHistoryEpoch(hub.currentHistoryEpoch(sessionID: "session")))
    }

    // JSONSerialization stores JSON integers above Int64.max as UNSIGNED
    // NSNumbers, whose int64Value wraps (18446744073709551615 → -1,
    // 18446744071562067968 → Int32.min) — an int64Value-based range check
    // silently accepts them. The bounds must be checked with
    // NSNumber.compare, which handles unsigned numbers numerically.
    func testCodexExitCodeUnsignedWrapFailsClosed() throws {
        func execEnd(_ exitCode: String) -> String {
            "{\"type\":\"event_msg\",\"timestamp\":\"2026-05-15T00:00:00Z\",\"payload\":{\"type\":\"exec_command_end\",\"call_id\":\"e1\",\"stdout\":\"ok\",\"stderr\":\"\",\"formatted_output\":\"\",\"aggregated_output\":\"\",\"exit_code\":\(exitCode),\"status\":\"completed\"}}"
        }
        let poisonRows: [(name: String, exitCode: String)] = [
            ("exec-exit-code-uint64-max", "18446744073709551615"),
            ("exec-exit-code-uint64-wrap-to-i32-range", "18446744071562067968"),
            ("exec-exit-code-negative-overflow", "-2147483649"),
        ]
        for row in poisonRows {
            try assertDeepRowFailsClosed(name: row.name, rowLines: [execEnd(row.exitCode)])
        }

        // Boundary guards: the exact i32 bounds are legal exit codes.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexTranscriptSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcriptURL = directory.appendingPathComponent("rollout.jsonl", isDirectory: false)
        let lines = [
            "{\"type\":\"event_msg\",\"timestamp\":\"2026-05-15T00:00:00Z\",\"payload\":{\"type\":\"exec_command_end\",\"call_id\":\"min-bound\",\"stdout\":\"min-out\",\"stderr\":\"\",\"formatted_output\":\"\",\"aggregated_output\":\"\",\"exit_code\":-2147483648,\"status\":\"failed\"}}",
            "{\"type\":\"event_msg\",\"timestamp\":\"2026-05-15T00:00:01Z\",\"payload\":{\"type\":\"exec_command_end\",\"call_id\":\"max-bound\",\"stdout\":\"max-out\",\"stderr\":\"\",\"formatted_output\":\"\",\"aggregated_output\":\"\",\"exit_code\":2147483647,\"status\":\"failed\"}}",
            makeCodexMessageLine(role: "assistant", content: "a-0"),
        ]
        try (lines.joined(separator: "\n") + "\n").write(to: transcriptURL, atomically: true, encoding: .utf8)
        let hub = AgentEventHub()
        let session = makeStartedCodexSession(transcriptURL, hub: hub, readySentinel: "a-0")
        defer { session.stop() }
        let events = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 50).events
        XCTAssertTrue(events.contains { $0.eventID == "min-bound:exec-end" }, "Int32.min is a legal exit code")
        XCTAssertTrue(events.contains { $0.eventID == "max-bound:exec-end" }, "Int32.max is a legal exit code")
        XCTAssertTrue(session.validateHistoryEpoch(hub.currentHistoryEpoch(sessionID: "session")))
    }

    // agent_message.phase is Option<MessagePhase> (protocol.rs @ 25af12f7
    // L2153-2160): absent and explicit null are LEGAL — the paired
    // response_item/message produces the assistant text instead. Corpus
    // evidence: 8 legacy absent-phase records (2026-02-14) all carry a
    // same-text paired response_item; of 36,298 phaseful response_items,
    // 20,900 pair with an identical timestamp and 15,391 pair with a
    // timestamp differing by ≤2s — so exactly-once holds via a
    // (kind|phase|text) dedupe, NOT a timestamp-keyed one.
    func testCodexAgentMessagePhaseOptionPairing() throws {
        func agentMessage(_ ts: String, _ payloadTail: String) -> String {
            "{\"type\":\"event_msg\",\"timestamp\":\"\(ts)\",\"payload\":{\"type\":\"agent_message\",\(payloadTail)}}"
        }
        func assistantItem(_ ts: String, phase: String, text: String) -> String {
            "{\"type\":\"response_item\",\"timestamp\":\"\(ts)\",\"payload\":{\"type\":\"message\",\"role\":\"assistant\",\"phase\":\"\(phase)\",\"content\":[{\"type\":\"output_text\",\"text\":\"\(text)\"}]}}"
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexTranscriptSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcriptURL = directory.appendingPathComponent("rollout.jsonl", isDirectory: false)
        let lines = [
            // Legacy absent-phase pairs (timestamps differ by 1s — the real
            // corpus shape): the response_item produces, exactly once.
            agentMessage("2026-05-15T00:00:00Z", "\"message\":\"legacy-commentary-text\""),
            assistantItem("2026-05-15T00:00:01Z", phase: "commentary", text: "legacy-commentary-text"),
            agentMessage("2026-05-15T00:00:02Z", "\"message\":\"legacy-final-text\""),
            assistantItem("2026-05-15T00:00:03Z", phase: "final_answer", text: "legacy-final-text"),
            // Explicit-null phase is equally legal.
            agentMessage("2026-05-15T00:00:04Z", "\"message\":\"null-phase-text\",\"phase\":null"),
            assistantItem("2026-05-15T00:00:05Z", phase: "commentary", text: "null-phase-text"),
            // Modern phaseful pair with differing timestamps: exactly once.
            agentMessage("2026-05-15T00:00:06Z", "\"message\":\"modern-pair-text\",\"phase\":\"commentary\""),
            assistantItem("2026-05-15T00:00:07Z", phase: "commentary", text: "modern-pair-text"),
            agentMessage("2026-05-15T00:00:08Z", "\"message\":\"modern-final-text\",\"phase\":\"final_answer\""),
            assistantItem("2026-05-15T00:00:09Z", phase: "final_answer", text: "modern-final-text"),
            // A response_item-only source must not lose the message.
            assistantItem("2026-05-15T00:00:10Z", phase: "commentary", text: "item-only-text"),
            makeCodexMessageLine(role: "assistant", content: "a-0"),
        ]
        try (lines.joined(separator: "\n") + "\n").write(to: transcriptURL, atomically: true, encoding: .utf8)
        let hub = AgentEventHub()
        let session = makeStartedCodexSession(transcriptURL, hub: hub, readySentinel: "a-0")
        defer { session.stop() }
        let events = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 50).events
        func count(_ type: AgentEventKind, _ text: String) -> Int {
            events.filter { $0.type == type && $0.text == text }.count
        }
        XCTAssertEqual(count(.assistantMessage, "legacy-commentary-text"), 1,
                       "absent-phase pair yields exactly one commentary product")
        XCTAssertEqual(count(.assistantFinal, "legacy-final-text"), 1,
                       "absent-phase pair yields exactly one final product")
        XCTAssertEqual(count(.assistantMessage, "null-phase-text"), 1,
                       "explicit-null phase is legal and pairs the same way")
        XCTAssertEqual(count(.assistantMessage, "modern-pair-text"), 1,
                       "a phaseful pair with differing timestamps still yields exactly one")
        XCTAssertEqual(count(.assistantFinal, "modern-final-text"), 1)
        XCTAssertEqual(count(.assistantMessage, "item-only-text"), 1,
                       "a response_item-only source must not lose the message")
        XCTAssertTrue(session.validateHistoryEpoch(hub.currentHistoryEpoch(sessionID: "session")),
                      "absent/null phases are legal — the source stays trusted")
    }

    // Dedupe ruling: only the ADJACENT producer twin is suppressed — a
    // phaseful event_msg leaves a pair key for exactly the next raw
    // record (corpus line-distance inventory: all 36,294 pairable twins
    // are distance 1). Legitimate same-text assistant messages in
    // different turns must BOTH survive; the protocol gives no
    // session-wide kind/phase/text uniqueness guarantee.
    func testCodexOnlyAdjacentAgentMessageTwinIsSuppressed() throws {
        func agentMessage(_ ts: String, phase: String, text: String) -> String {
            "{\"type\":\"event_msg\",\"timestamp\":\"\(ts)\",\"payload\":{\"type\":\"agent_message\",\"message\":\"\(text)\",\"phase\":\"\(phase)\"}}"
        }
        func assistantItem(_ ts: String, phase: String, text: String) -> String {
            "{\"type\":\"response_item\",\"timestamp\":\"\(ts)\",\"payload\":{\"type\":\"message\",\"role\":\"assistant\",\"phase\":\"\(phase)\",\"content\":[{\"type\":\"output_text\",\"text\":\"\(text)\"}]}}"
        }
        let separator = "{\"type\":\"response_item\",\"timestamp\":\"2026-05-15T00:00:50Z\",\"payload\":{\"type\":\"reasoning\",\"summary\":[]}}"
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexTranscriptSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcriptURL = directory.appendingPathComponent("rollout.jsonl", isDirectory: false)
        let lines = [
            // Repeated identical event_msg messages in different turns:
            // both survive.
            agentMessage("2026-05-15T00:00:00Z", phase: "commentary", text: "repeat-event-text"),
            separator,
            agentMessage("2026-05-15T00:00:02Z", phase: "commentary", text: "repeat-event-text"),
            // Repeated identical response_item-only messages: both survive.
            assistantItem("2026-05-15T00:00:03Z", phase: "commentary", text: "repeat-item-text"),
            separator,
            assistantItem("2026-05-15T00:00:05Z", phase: "commentary", text: "repeat-item-text"),
            // Adjacent twins (same and differing timestamps): exactly once.
            agentMessage("2026-05-15T00:00:06Z", phase: "commentary", text: "same-ts-twin"),
            assistantItem("2026-05-15T00:00:06Z", phase: "commentary", text: "same-ts-twin"),
            agentMessage("2026-05-15T00:00:07Z", phase: "final_answer", text: "diff-ts-twin"),
            assistantItem("2026-05-15T00:00:08Z", phase: "final_answer", text: "diff-ts-twin"),
            // An interposed record consumes adjacency: a later same-text
            // response_item is a REAL message, not a twin.
            agentMessage("2026-05-15T00:00:09Z", phase: "commentary", text: "stale-key-text"),
            separator,
            assistantItem("2026-05-15T00:00:11Z", phase: "commentary", text: "stale-key-text"),
            makeCodexMessageLine(role: "assistant", content: "a-0"),
        ]
        try (lines.joined(separator: "\n") + "\n").write(to: transcriptURL, atomically: true, encoding: .utf8)
        let hub = AgentEventHub()
        let session = makeStartedCodexSession(transcriptURL, hub: hub, readySentinel: "a-0")
        defer { session.stop() }
        let events = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 100).events
        func count(_ text: String) -> Int {
            events.filter { $0.text == text }.count
        }
        XCTAssertEqual(count("repeat-event-text"), 2,
                       "legitimate same-text messages in different turns must both survive")
        XCTAssertEqual(count("repeat-item-text"), 2,
                       "repeated response_item-only messages must both survive")
        XCTAssertEqual(count("same-ts-twin"), 1, "an adjacent twin publishes exactly once")
        XCTAssertEqual(count("diff-ts-twin"), 1,
                       "an adjacent twin with differing timestamps publishes exactly once")
        XCTAssertEqual(count("stale-key-text"), 2,
                       "an interposed record consumes adjacency — no stale-key suppression")
        XCTAssertTrue(session.validateHistoryEpoch(hub.currentHistoryEpoch(sessionID: "session")))
    }

    // An adjacent producer twin split across an after-cursor raw page
    // boundary (event_msg last record of the older page, response_item
    // first record of the newer page) must still publish exactly once
    // through the REAL flow: the production step limit is
    // max(limit + 1, 500), so any twin at a 500-record boundary — or at
    // the live bootstrap floor, which sits at the same distance — would
    // otherwise appear twice with distinct eventIDs that no union dedupe
    // catches.
    func testCodexAdjacentTwinAcrossRawPageBoundaryPublishesOnce() throws {
        func agentMessage(_ ts: String, phase: String, text: String) -> String {
            "{\"type\":\"event_msg\",\"timestamp\":\"\(ts)\",\"payload\":{\"type\":\"agent_message\",\"message\":\"\(text)\",\"phase\":\"\(phase)\"}}"
        }
        func assistantItem(_ ts: String, phase: String, text: String) -> String {
            "{\"type\":\"response_item\",\"timestamp\":\"\(ts)\",\"payload\":{\"type\":\"message\",\"role\":\"assistant\",\"phase\":\"\(phase)\",\"content\":[{\"type\":\"output_text\",\"text\":\"\(text)\"}]}}"
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexTranscriptSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcriptURL = directory.appendingPathComponent("rollout.jsonl", isDirectory: false)
        let lineCount = transcriptBootstrapLineLimit * 2 + 40      // 1040
        var lines = (0..<lineCount).map {
            makeCodexMessageLine(role: "assistant", content: "deep-\($0)")
        }
        // Two legitimate same-text messages in different turns (page 3).
        lines[10] = agentMessage("2026-05-15T00:00:10Z", phase: "commentary", text: "dup-legal-text")
        lines[12] = agentMessage("2026-05-15T00:00:12Z", phase: "commentary", text: "dup-legal-text")
        // event_msg-only near the boundary (its own message, no twin).
        lines[38] = agentMessage("2026-05-15T00:00:38Z", phase: "commentary", text: "event-only-text")
        // The cross-page twin: last record of page 3 / first record of
        // page 2 for a limit-499 walk (boundary at lineCount - 1000).
        lines[39] = agentMessage("2026-05-15T00:00:39Z", phase: "commentary", text: "cross-page-twin")
        lines[40] = assistantItem("2026-05-15T00:00:40Z", phase: "commentary", text: "cross-page-twin")
        // response_item-only right after the boundary.
        lines[41] = assistantItem("2026-05-15T00:00:41Z", phase: "commentary", text: "item-only-text")
        // A second twin exactly at the live BOOTSTRAP floor
        // (lineCount - transcriptBootstrapLineLimit): the floor cuts
        // between the twins, so live sees only the response_item.
        lines[lineCount - transcriptBootstrapLineLimit - 1] =
            agentMessage("2026-05-15T00:05:39Z", phase: "commentary", text: "bootstrap-floor-twin")
        lines[lineCount - transcriptBootstrapLineLimit] =
            assistantItem("2026-05-15T00:05:40Z", phase: "commentary", text: "bootstrap-floor-twin")
        try (lines.joined(separator: "\n") + "\n").write(to: transcriptURL, atomically: true, encoding: .utf8)
        let hub = AgentEventHub()
        let session = makeStartedCodexSession(transcriptURL, hub: hub,
                                              readySentinel: "deep-\(lineCount - 1)")
        defer { session.stop() }

        // Live/latest BEFORE any depth walk: the response_item half of the
        // bootstrap-floor twin sits INSIDE the owned bootstrap window and
        // must not be silently swallowed — live carries the twin exactly
        // once, under the predecessor's canonical identity.
        let liveTwinIDs = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 2000)
            .events.filter { $0.text == "bootstrap-floor-twin" }.map(\.eventID)
        XCTAssertEqual(liveTwinIDs.count, 1,
                       "the bootstrap-floor twin is live exactly once before any walk")

        var stepOutcomes = [String]()
        func fetchOnce(limit: Int, recordSteps: Bool = false) -> BridgeAgentEventFetchFlow.Output {
            BridgeAgentEventFetchFlow.run(
                eventHub: hub,
                workspaceID: "workspace",
                sessionID: "session",
                limit: limit,
                beforeSeq: nil,
                afterSeq: 0,
                afterCursorSeams: .init(
                    plan: { _, afterSeq, expected in
                        session.afterCursorPlan(afterSeq: afterSeq, expectedEpoch: expected)
                    },
                    step: { _, anchor, afterSeq, stepLimit in
                        let step = session.afterCursorStep(from: anchor, afterSeq: afterSeq, limit: stepLimit)
                        if recordSteps {
                            switch step.outcome {
                            case .advanced: stepOutcomes.append("advanced")
                            case .complete: stepOutcomes.append("complete")
                            case .sourceChanged: stepOutcomes.append("sourceChanged")
                            case .unavailable: stepOutcomes.append("unavailable")
                            }
                        }
                        return step
                    },
                    validateEpoch: { _, epoch in
                        session.validateHistoryEpoch(epoch)
                    })) { _, _, _ in
                XCTFail("the legacy backfill closure must not serve the typed after path")
                return false
            }
        }

        // Request 1 (limit 499 → 500-record steps): the deep boundary at
        // lineCount-1000 splits the cross-page twin between two steps.
        let first = fetchOnce(limit: 499, recordSteps: true)
        XCTAssertTrue(first.didBackfill, "the walk really ran")
        XCTAssertGreaterThanOrEqual(stepOutcomes.filter { $0 == "advanced" }.count, 1,
                                    "the walk advanced across at least one page boundary")
        XCTAssertEqual(stepOutcomes.last, "complete", "the walk completed — no fail-closed masking")
        func texts(_ output: BridgeAgentEventFetchFlow.Output, _ text: String) -> Int {
            output.fetchResult.events.filter { $0.text == text }.count
        }
        XCTAssertEqual(texts(first, "cross-page-twin"), 1,
                       "the twin split across two raw steps publishes exactly once")
        XCTAssertEqual(texts(first, "dup-legal-text"), 2,
                       "non-adjacent same-text messages in different turns both survive")
        XCTAssertEqual(texts(first, "event-only-text"), 1, "event_msg-only near the boundary is kept")
        XCTAssertEqual(texts(first, "item-only-text"), 1, "response_item-only after the boundary is kept")
        XCTAssertTrue(session.validateHistoryEpoch(hub.currentHistoryEpoch(sessionID: "session")),
                      "the source stays trusted through the boundary walk")

        // The same request again: byte-identical page.
        let second = fetchOnce(limit: 499)
        func triples(_ output: BridgeAgentEventFetchFlow.Output) -> [String] {
            output.fetchResult.events.map { "\($0.eventID)#\($0.seq)#\($0.text ?? "")" }
        }
        XCTAssertEqual(triples(second), triples(first),
                       "the repeated request serves the identical page")

        // Request 2 (limit 2000 → single-step walk over the full depth):
        // the twin at the live bootstrap floor publishes exactly once —
        // the union of live bootstrap products and walk products must not
        // carry both twin representations.
        let wide = fetchOnce(limit: 2000)
        XCTAssertTrue(wide.didBackfill)
        XCTAssertEqual(texts(wide, "bootstrap-floor-twin"), 1,
                       "the bootstrap-floor twin publishes exactly once across live + walk")
        XCTAssertEqual(texts(wide, "cross-page-twin"), 1)
        XCTAssertEqual(texts(wide, "dup-legal-text"), 2)

        // Canonical identity is the PREDECESSOR event_msg's and must not
        // change with the API limit / step boundary layout.
        func twinIDs(_ output: BridgeAgentEventFetchFlow.Output) -> Set<String> {
            Set(output.fetchResult.events.filter { $0.text == "bootstrap-floor-twin" }.map(\.eventID))
        }
        XCTAssertEqual(twinIDs(wide), Set(liveTwinIDs),
                       "live and the walk agree on ONE canonical twin identity")
        let mid = fetchOnce(limit: 600)
        XCTAssertEqual(texts(mid, "bootstrap-floor-twin"), 1)
        XCTAssertEqual(twinIDs(mid), Set(liveTwinIDs),
                       "the canonical identity survives a different step-boundary layout")

        // The cross-page twin too: (eventID, seq) must be IDENTICAL when
        // the pair is split across raw steps (limit 499) and when it sits
        // inside a single step (wide/mid) — canonical identity never
        // follows the raw page layout.
        func crossPageIdentity(_ output: BridgeAgentEventFetchFlow.Output) -> Set<String> {
            Set(output.fetchResult.events.filter { $0.text == "cross-page-twin" }
                    .map { "\($0.eventID)#\($0.seq)" })
        }
        XCTAssertEqual(crossPageIdentity(first).count, 1)
        XCTAssertEqual(crossPageIdentity(first), crossPageIdentity(wide),
                       "split-across-steps and single-step layouts share one (eventID, seq)")
        XCTAssertEqual(crossPageIdentity(first), crossPageIdentity(mid),
                       "the identity also survives the 600-limit layout")
    }

    // The legacy before path replays a rolling historical window into the
    // shared Hub cache. When that window starts on the response_item half of
    // an adjacent producer twin, the first client page must already use the
    // predecessor event_msg's canonical identity. Otherwise the next older
    // page replaces the Hub entry with the canonical identity after the
    // client retained the response identity, leaving a duplicate in the
    // client's page union.
    func testCodexBeforeCursorReplayWindowFloorTwinKeepsCanonicalIdentity() throws {
        let fixture = try makeCodexBeforeContextTwinFixture(prefix: "before")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let transcriptURL = fixture.transcriptURL
        let lineCount = fixture.lineCount
        let predecessorIndex = fixture.predecessorIndex
        let responseIndex = fixture.responseIndex
        let itemOnlyIndex = fixture.itemOnlyIndex
        let twinText = fixture.twinText
        let itemOnlyText = fixture.itemOnlyText
        let lineOffsets = fixture.lineOffsets

        let hub = AgentEventHub()
        let session = makeStartedCodexSession(
            transcriptURL,
            hub: hub,
            readySentinel: "before-deep-\(lineCount - 1)"
        )
        defer { session.stop() }

        // The iOS client bootstraps with 24 retained events. Its first older
        // request starts at raw index 1016, so the production 500-record
        // before read owns indices 516...1015: response half at the replay
        // floor, predecessor exactly one record outside.
        let bootstrap = hub.fetch(workspaceID: "workspace",
                                  sessionID: "session",
                                  limit: 24)
        let bootstrapEvents = bootstrap.events.filter {
            $0.seq > transcriptSessionStartedSequence
        }
        XCTAssertEqual(bootstrapEvents.count, 24)
        XCTAssertEqual(bootstrapEvents.map(\.text).first ?? nil,
                       "before-deep-\(lineCount - 24)")
        XCTAssertEqual(bootstrap.oldestSeq,
                       try XCTUnwrap(bootstrapEvents.map(\.seq).min()))
        var cursor = bootstrap.oldestSeq
        var clientEventsByID = Dictionary(
            uniqueKeysWithValues: bootstrapEvents.map { ($0.eventID, $0) }
        )

        func wirePage(beforeSeq: Int) -> BridgeAgentEventFetchFlow.Output {
            BridgeAgentEventFetchFlow.run(
                eventHub: hub,
                workspaceID: "workspace",
                sessionID: "session",
                limit: 500,
                beforeSeq: beforeSeq,
                afterSeq: nil,
                beforeCursorBackfill: { _, beforeSeq, limit in
                    session.beforeCursorBackfill(beforeSeq: beforeSeq, limit: limit)
                }
            )
        }

        let canonicalTwinSeq = transcriptEventSequence(
            lineOffset: lineOffsets[predecessorIndex],
            ordinal: 0
        )
        let responseTwinSeq = transcriptEventSequence(
            lineOffset: lineOffsets[responseIndex],
            ordinal: 0
        )
        let itemOnlySeq = transcriptEventSequence(
            lineOffset: lineOffsets[itemOnlyIndex],
            ordinal: 0
        )
        let canonicalTwinID = "commentary:session:\(canonicalTwinSeq)"
        let responseTwinID = "commentary:session:\(responseTwinSeq)"
        let itemOnlyID = "commentary:session:\(itemOnlySeq)"

        var didReachBOF = false
        for pageIndex in 0..<5 {
            let page = wirePage(beforeSeq: cursor)
            XCTAssertFalse(page.beforeCursorUnavailable,
                           "page \(pageIndex) remains source-authoritative")
            let pageableEvents = page.fetchResult.events.filter {
                $0.seq > transcriptSessionStartedSequence
            }
            XCTAssertFalse(pageableEvents.isEmpty,
                           "page \(pageIndex) makes visible progress")
            if pageIndex == 0 {
                XCTAssertTrue(page.fetchResult.hasMore)
                XCTAssertEqual(
                    pageableEvents.filter { $0.text == twinText }.map(\.eventID),
                    [canonicalTwinID],
                    "the first page uses the predecessor identity before the predecessor's own page"
                )
                XCTAssertEqual(
                    pageableEvents.filter { $0.text == itemOnlyText }.map(\.eventID),
                    [itemOnlyID],
                    "a response_item-only canary keeps its own identity"
                )
            }
            for event in pageableEvents {
                clientEventsByID[event.eventID] = event
            }
            if page.fetchResult.hasMore == false {
                didReachBOF = true
                break
            }
            let nextCursor = try XCTUnwrap(pageableEvents.map(\.seq).min())
            XCTAssertEqual(page.fetchResult.oldestSeq, nextCursor,
                           "page \(pageIndex) exposes its wire cursor")
            XCTAssertLessThan(nextCursor, cursor,
                              "page \(pageIndex) strictly retreats")
            cursor = page.fetchResult.oldestSeq
        }
        XCTAssertTrue(didReachBOF, "the real before flow reaches source BOF")

        let clientEvents = Array(clientEventsByID.values)
        let clientTwinEvents = clientEvents.filter { $0.text == twinText }
        XCTAssertEqual(clientTwinEvents.map(\.eventID), [canonicalTwinID])
        XCTAssertFalse(clientEventsByID.keys.contains(responseTwinID),
                       "the response-half identity never leaks into the client union")

        var expectedTexts = Set((0..<lineCount).compactMap { index -> String? in
            guard index != predecessorIndex,
                  index != responseIndex,
                  index != itemOnlyIndex else {
                return nil
            }
            return "before-deep-\(index)"
        })
        expectedTexts.insert(twinText)
        expectedTexts.insert(itemOnlyText)
        XCTAssertEqual(Set(clientEvents.compactMap(\.text)), expectedTexts,
                       "the fix preserves every independently producing record")
        XCTAssertEqual(clientEvents.count, expectedTexts.count,
                       "the complete client union has no duplicate identity")
    }

    func testCodexBeforeCursorSourceBOFSkipsNonexistentAdjacencyContext() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexTranscriptSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcriptURL = directory.appendingPathComponent("rollout.jsonl", isDirectory: false)
        let recentLines = (0..<transcriptBootstrapLineLimit).map {
            makeCodexMessageLine(role: "assistant", content: "bof-recent-\($0)")
        }
        let lines = [makeCodexMessageLine(role: "assistant", content: "bof-old")] + recentLines
        try ("\n" + lines.joined(separator: "\n") + "\n")
            .write(to: transcriptURL, atomically: true, encoding: .utf8)

        let hub = AgentEventHub()
        let session = makeStartedCodexSession(
            transcriptURL,
            hub: hub,
            readySentinel: "bof-recent-\(transcriptBootstrapLineLimit - 1)"
        )
        defer { session.stop() }
        let liveEvents = hub.fetch(workspaceID: "workspace",
                                   sessionID: "session",
                                   limit: transcriptBootstrapLineLimit)
            .events.filter { $0.seq > transcriptSessionStartedSequence }
        XCTAssertEqual(liveEvents.count, transcriptBootstrapLineLimit)
        let beforeSeq = try XCTUnwrap(liveEvents.map(\.seq).min())

        var backfillReadCount = 0
        session.tailerBackfillBeforeReadForTesting = {
            backfillReadCount += 1
        }
        defer { session.tailerBackfillBeforeReadForTesting = nil }
        let result = session.beforeCursorBackfill(beforeSeq: beforeSeq, limit: 500)

        XCTAssertTrue(result.didBackfill)
        XCTAssertEqual(result.rawContinuation, .end,
                       "the owned page reached byte-zero source BOF")
        XCTAssertEqual(result.authorityEpoch,
                       hub.currentHistoryEpoch(sessionID: "session"))
        XCTAssertEqual(backfillReadCount, 1,
                       "source-proven BOF has no predecessor context to read")
        XCTAssertTrue(
            hub.fetch(workspaceID: "workspace",
                      sessionID: "session",
                      limit: 10,
                      beforeSeq: beforeSeq)
                .events.contains { $0.text == "bof-old" }
        )
    }

    func testCodexBeforeCursorContextInvalidationRevokesStaleWindowAndReattaches() throws {
        let fixture = try makeCodexBeforeContextTwinFixture(prefix: "context-a")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let hub = AgentEventHub()
        let session = makeStartedCodexSession(
            fixture.transcriptURL,
            hub: hub,
            readySentinel: "context-a-deep-\(fixture.lineCount - 1)"
        )
        defer { session.stop() }
        let bootstrap = hub.fetch(workspaceID: "workspace",
                                  sessionID: "session",
                                  limit: 24)
        let beforeSeq = bootstrap.oldestSeq
        XCTAssertGreaterThan(beforeSeq, transcriptSessionStartedSequence)
        let sourceAEpoch = hub.currentHistoryEpoch(sessionID: "session")

        var backfillReadCount = 0
        var replacementWriteError: Error?
        session.tailerBackfillBeforeReadForTesting = {
            backfillReadCount += 1
            guard backfillReadCount == 2 else { return }
            do {
                try Data((self.makeCodexMessageLine(
                    role: "assistant",
                    content: "context-b-sentinel"
                ) + "\n").utf8).write(to: fixture.transcriptURL, options: .atomic)
            } catch {
                replacementWriteError = error
            }
        }
        let result = session.beforeCursorBackfill(beforeSeq: beforeSeq, limit: 500)
        session.tailerBackfillBeforeReadForTesting = nil

        XCTAssertNil(replacementWriteError)
        XCTAssertEqual(backfillReadCount, 2,
                       "the replacement lands during the context read")
        XCTAssertFalse(result.didBackfill)
        XCTAssertEqual(result.rawContinuation, .unavailable)
        XCTAssertNil(result.authorityEpoch)
        XCTAssertEqual(
            hub.currentHistoryEpoch(sessionID: "session").generation,
            sourceAEpoch.generation + 1,
            "source replacement advances the Hub epoch exactly once"
        )
        XCTAssertFalse(
            hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 2000)
                .events.contains {
                    $0.text?.hasPrefix("context-a-") == true
                },
            "neither source A's live window nor its uncommitted historical replay survives"
        )
        XCTAssertTrue(waitUntil(timeout: 4) {
            hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 50)
                .events.contains { $0.text == "context-b-sentinel" }
        }, "the resolver reattaches source B")
        let sourceBEpoch = hub.currentHistoryEpoch(sessionID: "session")
        XCTAssertTrue(session.validateHistoryEpoch(sourceBEpoch))
        XCTAssertEqual(sourceBEpoch.generation, sourceAEpoch.generation + 1,
                       "reattaching source B does not reset the epoch again")
        XCTAssertEqual(
            hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 50)
                .events.filter { $0.text == "context-b-sentinel" }.count,
            1
        )
    }

    func testCodexBeforeCursorContextTransientReadFailurePreservesEpochAndRetries() throws {
        let fixture = try makeCodexBeforeContextTwinFixture(prefix: "context-transient")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                   ofItemAtPath: fixture.directory.path)
            try? FileManager.default.removeItem(at: fixture.directory)
        }
        let hub = AgentEventHub()
        let session = makeStartedCodexSession(
            fixture.transcriptURL,
            hub: hub,
            readySentinel: "context-transient-deep-\(fixture.lineCount - 1)"
        )
        defer { session.stop() }
        let bootstrap = hub.fetch(workspaceID: "workspace",
                                  sessionID: "session",
                                  limit: 24)
        let beforeSeq = bootstrap.oldestSeq
        XCTAssertGreaterThan(beforeSeq, transcriptSessionStartedSequence)
        let epoch = hub.currentHistoryEpoch(sessionID: "session")

        var backfillReadCount = 0
        var permissionChangeError: Error?
        session.tailerBackfillBeforeReadForTesting = {
            backfillReadCount += 1
            guard backfillReadCount == 2 else { return }
            do {
                try FileManager.default.setAttributes([.posixPermissions: 0o000],
                                                      ofItemAtPath: fixture.directory.path)
            } catch {
                permissionChangeError = error
            }
        }
        let failed = session.beforeCursorBackfill(beforeSeq: beforeSeq, limit: 500)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: fixture.directory.path)
        session.tailerBackfillBeforeReadForTesting = nil

        XCTAssertNil(permissionChangeError)
        XCTAssertEqual(backfillReadCount, 2,
                       "the I/O fault lands during the context read")
        XCTAssertFalse(failed.didBackfill)
        XCTAssertEqual(failed.rawContinuation, .unavailable)
        XCTAssertNil(failed.authorityEpoch)
        XCTAssertEqual(hub.currentHistoryEpoch(sessionID: "session"), epoch,
                       "a transient read failure does not reset the source")
        XCTAssertTrue(
            hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 50)
                .events.contains {
                    $0.text == "context-transient-deep-\(fixture.lineCount - 1)"
                },
            "the retained live window survives"
        )
        XCTAssertFalse(
            hub.fetch(workspaceID: "workspace",
                      sessionID: "session",
                      limit: 2000,
                      beforeSeq: beforeSeq)
                .events.contains { $0.text == fixture.twinText },
            "the owned page merged locally but did not publish a partial replay"
        )
        XCTAssertTrue(session.validateHistoryEpoch(epoch),
                      "the same source remains valid once I/O recovers")

        let retried = session.beforeCursorBackfill(beforeSeq: beforeSeq, limit: 500)
        XCTAssertTrue(retried.didBackfill)
        XCTAssertEqual(retried.rawContinuation, .more)
        XCTAssertEqual(retried.authorityEpoch, epoch)
        let canonicalTwinSeq = transcriptEventSequence(
            lineOffset: fixture.lineOffsets[fixture.predecessorIndex],
            ordinal: 0
        )
        let responseTwinSeq = transcriptEventSequence(
            lineOffset: fixture.lineOffsets[fixture.responseIndex],
            ordinal: 0
        )
        let canonicalTwinID = "commentary:session:\(canonicalTwinSeq)"
        let responseTwinID = "commentary:session:\(responseTwinSeq)"
        let historyTwinIDs = hub.fetch(workspaceID: "workspace",
                                      sessionID: "session",
                                      limit: 500,
                                      beforeSeq: beforeSeq)
            .events.filter { $0.text == fixture.twinText }.map(\.eventID)
        XCTAssertEqual(historyTwinIDs, [canonicalTwinID])
        XCTAssertFalse(historyTwinIDs.contains(responseTwinID))
    }

    // Context records live OUTSIDE the owned window and carry NO coverage
    // or semantic-trust authority: a malformed (or non-agent-message)
    // predecessor just means "no adjacency context". Its own page judges
    // it — the depth walk that actually covers it still fails closed.
    func testCodexMalformedContextRecordIsNotCoverageAuthority() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexTranscriptSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcriptURL = directory.appendingPathComponent("rollout.jsonl", isDirectory: false)
        let lineCount = transcriptBootstrapLineLimit + 20
        var lines = (0..<lineCount).map {
            makeCodexMessageLine(role: "assistant", content: "deep-\($0)")
        }
        // The record immediately BELOW the bootstrap floor is garbage.
        lines[lineCount - transcriptBootstrapLineLimit - 1] = "this-is-not-json"
        // The window-head record is a phaseful response_item: with a
        // malformed predecessor there is no context, so it publishes.
        lines[lineCount - transcriptBootstrapLineLimit] =
            "{\"type\":\"response_item\",\"timestamp\":\"2026-05-15T00:00:00Z\",\"payload\":{\"type\":\"message\",\"role\":\"assistant\",\"phase\":\"commentary\",\"content\":[{\"type\":\"output_text\",\"text\":\"head-item-text\"}]}}"
        try (lines.joined(separator: "\n") + "\n").write(to: transcriptURL, atomically: true, encoding: .utf8)
        let hub = AgentEventHub()
        let session = makeStartedCodexSession(transcriptURL, hub: hub,
                                              readySentinel: "deep-\(lineCount - 1)")
        defer { session.stop() }
        let epoch = hub.currentHistoryEpoch(sessionID: "session")
        XCTAssertTrue(session.validateHistoryEpoch(epoch),
                      "a malformed CONTEXT record must not poison — it is outside the owned window")
        XCTAssertTrue(hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 2000)
                        .events.contains { $0.text == "head-item-text" },
                      "the window-head item publishes — no stale suppression from a garbage predecessor")
        switch session.afterCursorPlan(afterSeq: 0, expectedEpoch: epoch).mode {
        case .rawCovered, .scan:
            break
        case .hubOnly, .unavailable:
            XCTFail("the source stays plannable until its OWN coverage reaches the garbage")
        }
        // A depth walk that actually covers the garbage record fails
        // closed — the authority belongs to the owned page, not the
        // context peek.
        let output = BridgeAgentEventFetchFlow.run(
            eventHub: hub,
            workspaceID: "workspace",
            sessionID: "session",
            limit: 499,
            beforeSeq: nil,
            afterSeq: 0,
            afterCursorSeams: .init(
                plan: { _, afterSeq, expected in
                    session.afterCursorPlan(afterSeq: afterSeq, expectedEpoch: expected)
                },
                step: { _, anchor, afterSeq, limit in
                    session.afterCursorStep(from: anchor, afterSeq: afterSeq, limit: limit)
                },
                validateEpoch: { _, epoch in
                    session.validateHistoryEpoch(epoch)
                })) { _, _, _ in
            XCTFail("the legacy backfill closure must not serve the typed after path")
            return false
        }
        XCTAssertTrue(output.fetchResult.events.isEmpty,
                      "covering the garbage fails the request closed — no partial page")
        XCTAssertTrue(output.fetchResult.hasMore)
        XCTAssertFalse(session.validateHistoryEpoch(epoch),
                       "once the OWNED walk covered the garbage, the poison is real")
    }

    // Bootstrap context read error classification: a source replaced
    // between tailer.start() and the context read must NOT attach the
    // stale window — no publish of the collected lines, no retained old
    // tailer, exactly one reset, and the replacement re-attaches.
    func testBootstrapContextInvalidationDropsStaleWindowAndReattaches() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexTranscriptSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcriptURL = directory.appendingPathComponent("rollout.jsonl", isDirectory: false)
        let lineCount = transcriptBootstrapLineLimit + 20
        let aLines = (0..<lineCount).map { makeCodexMessageLine(role: "assistant", content: "a-deep-\($0)") }
        try (aLines.joined(separator: "\n") + "\n").write(to: transcriptURL, atomically: true, encoding: .utf8)
        let hub = AgentEventHub()
        let baseGeneration = hub.currentHistoryEpoch(sessionID: "session").generation
        let session = CodexTranscriptSession(record: makeRecord(transcriptPath: transcriptURL.path),
                                             fileManager: .default,
                                             hub: hub)
        var replacementWriteError: Error?
        session.bootstrapContextBeforeReadForTesting = {
            // Atomically replace the source between the window collection
            // and the context read: the context backfill's fence must see
            // the invalidation.
            do {
                try Data((self.makeCodexMessageLine(role: "assistant", content: "b-sentinel") + "\n").utf8)
                    .write(to: transcriptURL, options: .atomic)
            } catch {
                replacementWriteError = error
            }
            session.bootstrapContextBeforeReadForTesting = nil
        }
        session.start()
        defer { session.stop() }
        XCTAssertTrue(waitUntil(timeout: 4) {
            hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 50)
                .events.contains { $0.text == "b-sentinel" }
        }, "the replacement source re-attaches")
        XCTAssertNil(replacementWriteError)
        XCTAssertFalse(hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 2000)
                        .events.contains { $0.text?.hasPrefix("a-deep-") == true },
                       "no stale products after the replacement attach")
        XCTAssertEqual(hub.currentHistoryEpoch(sessionID: "session").generation,
                       baseGeneration + 1,
                       "the reset happened exactly once")
        // Deterministic no-stale-publish proof, immune to watcher-timing:
        // a CONTROL session that only ever saw the replacement file yields
        // the identical b-sentinel sequence. If the stale window had been
        // published (and revoked) first, its consumed sequences would have
        // shifted the reset base and the sequences would differ.
        let controlHub = AgentEventHub()
        let controlSession = makeStartedCodexSession(transcriptURL, hub: controlHub,
                                                     readySentinel: "b-sentinel")
        defer { controlSession.stop() }
        let mainSeq = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 50)
            .events.first { $0.text == "b-sentinel" }?.seq
        let controlSeq = controlHub.fetch(workspaceID: "workspace", sessionID: "session", limit: 50)
            .events.first { $0.text == "b-sentinel" }?.seq
        XCTAssertNotNil(mainSeq)
        XCTAssertEqual(mainSeq, controlSeq,
                       "the stale window never consumed sequences — it was never published")
    }

    // A transient context read error must not silently claim
    // adjacency-complete: the attach fails closed (nothing published, no
    // tailer kept) and the resolver's retry attaches with REAL context —
    // the twin keeps its canonical predecessor identity.
    func testBootstrapContextTransientFaultFailsAttachClosedThenRetries() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexTranscriptSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcriptURL = directory.appendingPathComponent("rollout.jsonl", isDirectory: false)
        let lineCount = transcriptBootstrapLineLimit + 20
        var lines = (0..<lineCount).map { makeCodexMessageLine(role: "assistant", content: "deep-\($0)") }
        lines[lineCount - transcriptBootstrapLineLimit - 1] =
            "{\"type\":\"event_msg\",\"timestamp\":\"2026-05-15T00:05:39Z\",\"payload\":{\"type\":\"agent_message\",\"message\":\"floor-twin\",\"phase\":\"commentary\"}}"
        lines[lineCount - transcriptBootstrapLineLimit] =
            "{\"type\":\"response_item\",\"timestamp\":\"2026-05-15T00:05:40Z\",\"payload\":{\"type\":\"message\",\"role\":\"assistant\",\"phase\":\"commentary\",\"content\":[{\"type\":\"output_text\",\"text\":\"floor-twin\"}]}}"
        try (lines.joined(separator: "\n") + "\n").write(to: transcriptURL, atomically: true, encoding: .utf8)
        let hub = AgentEventHub()
        let session = CodexTranscriptSession(record: makeRecord(transcriptPath: transcriptURL.path),
                                             fileManager: .default,
                                             hub: hub)
        // The fault stays CLOSED (every context read fails) until the
        // no-publish assertion completes — a one-shot fault would race the
        // resolver's 1s retry against the assertion.
        let faultLock = NSLock()
        var faultGateOpen = false
        var faultAttempts = 0
        session.bootstrapContextReadFaultForTesting = {
            faultLock.lock()
            defer { faultLock.unlock() }
            guard faultGateOpen == false else { return nil }
            faultAttempts += 1
            return POSIXError(.EIO)
        }
        session.start()
        defer { session.stop() }
        // Synchronous checkpoint: at least one faulted attach ran and
        // published NOTHING — deterministic while the gate stays closed.
        _ = session.validateHistoryEpoch(hub.currentHistoryEpoch(sessionID: "session"))
        faultLock.lock()
        let attemptsAtCheckpoint = faultAttempts
        faultLock.unlock()
        XCTAssertGreaterThanOrEqual(attemptsAtCheckpoint, 1)
        XCTAssertFalse(hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 2000)
                        .events.contains { $0.text?.hasPrefix("deep-") == true || $0.text == "floor-twin" },
                       "a transient context fault fails the attach closed — no window product publishes")
        faultLock.lock()
        faultGateOpen = true
        faultLock.unlock()
        // The resolver retries and attaches with REAL adjacency context.
        XCTAssertTrue(waitUntil(timeout: 6) {
            hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 50)
                .events.contains { $0.text == "deep-\(lineCount - 1)" }
        }, "the retry attaches")
        let liveTwinIDs = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 2000)
            .events.filter { $0.text == "floor-twin" }.map(\.eventID)
        XCTAssertEqual(liveTwinIDs.count, 1)
        // Identity consistency proves the retry seeded real context: a
        // wide walk's product carries the SAME canonical identity.
        let wide = BridgeAgentEventFetchFlow.run(
            eventHub: hub,
            workspaceID: "workspace",
            sessionID: "session",
            limit: 2000,
            beforeSeq: nil,
            afterSeq: 0,
            afterCursorSeams: .init(
                plan: { _, afterSeq, expected in
                    session.afterCursorPlan(afterSeq: afterSeq, expectedEpoch: expected)
                },
                step: { _, anchor, afterSeq, limit in
                    session.afterCursorStep(from: anchor, afterSeq: afterSeq, limit: limit)
                },
                validateEpoch: { _, epoch in
                    session.validateHistoryEpoch(epoch)
                })) { _, _, _ in
            XCTFail("the legacy backfill closure must not serve the typed after path")
            return false
        }
        let wideTwinIDs = wide.fetchResult.events.filter { $0.text == "floor-twin" }.map(\.eventID)
        XCTAssertEqual(wideTwinIDs.count, 1,
                       "the twin stays exactly-once across live + walk")
        XCTAssertEqual(Set(wideTwinIDs), Set(liveTwinIDs),
                       "the retry seeded real context — live and walk share ONE canonical identity")
    }

    // A transient candidate abort must RETIRE the aborted candidate's
    // invalidation token: a queued vnode callback from candidate A,
    // arriving after candidate B attached, must not reset the healthy B.
    func testStaleCallbackFromAbortedCandidateCannotResetReplacement() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexTranscriptSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcriptURL = directory.appendingPathComponent("rollout.jsonl", isDirectory: false)
        let lineCount = transcriptBootstrapLineLimit + 20
        let lines = (0..<lineCount).map { makeCodexMessageLine(role: "assistant", content: "deep-\($0)") }
        try (lines.joined(separator: "\n") + "\n").write(to: transcriptURL, atomically: true, encoding: .utf8)
        let hub = AgentEventHub()
        let session = CodexTranscriptSession(record: makeRecord(transcriptPath: transcriptURL.path),
                                             fileManager: .default,
                                             hub: hub)
        let candidateAGeneration = session.currentSourceGenerationForTesting
        let faultLock = NSLock()
        var faultGateOpen = false
        session.bootstrapContextReadFaultForTesting = {
            faultLock.lock()
            defer { faultLock.unlock() }
            return faultGateOpen ? nil : POSIXError(.EIO)
        }
        session.start()
        defer { session.stop() }
        // Candidate A aborts on the transient fault (queue drains here).
        _ = session.validateHistoryEpoch(hub.currentHistoryEpoch(sessionID: "session"))
        faultLock.lock()
        faultGateOpen = true
        faultLock.unlock()
        // Candidate B attaches on the resolver retry.
        XCTAssertTrue(waitUntil(timeout: 6) {
            hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 50)
                .events.contains { $0.text == "deep-\(lineCount - 1)" }
        }, "the replacement candidate attaches")
        let epochBefore = hub.currentHistoryEpoch(sessionID: "session")
        // The aborted candidate A's queued vnode callback finally runs.
        session.fireTailerInvalidationForTesting(generation: candidateAGeneration)
        XCTAssertEqual(hub.currentHistoryEpoch(sessionID: "session"), epochBefore,
                       "a stale callback from the ABORTED candidate must not move the epoch")
        XCTAssertTrue(hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 50)
                        .events.contains { $0.text == "deep-\(lineCount - 1)" },
                      "the healthy replacement's products survive the stale callback")
        XCTAssertTrue(session.validateHistoryEpoch(epochBefore),
                      "the healthy replacement stays attached and trusted")
    }

    // Guard (end-state; the recursion removal itself is structural):
    // three consecutive source replacements during attach leave exactly
    // the FINAL source attached, with one reset per replacement and no
    // stale products.
    func testConsecutiveBootstrapInvalidationsSettleOnFinalSource() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexTranscriptSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcriptURL = directory.appendingPathComponent("rollout.jsonl", isDirectory: false)
        let lineCount = transcriptBootstrapLineLimit + 20
        func writeFile(prefix: String) throws {
            let lines = (0..<lineCount).map { makeCodexMessageLine(role: "assistant", content: "\(prefix)-\($0)") }
            try (lines.joined(separator: "\n") + "\n").write(to: transcriptURL, atomically: true, encoding: .utf8)
        }
        try writeFile(prefix: "gen0")
        let hub = AgentEventHub()
        let baseGeneration = hub.currentHistoryEpoch(sessionID: "session").generation
        let session = CodexTranscriptSession(record: makeRecord(transcriptPath: transcriptURL.path),
                                             fileManager: .default,
                                             hub: hub)
        let replaceLock = NSLock()
        var replacements = 0
        var replacementWriteError: Error?
        session.bootstrapContextBeforeReadForTesting = {
            replaceLock.lock()
            defer { replaceLock.unlock() }
            guard replacements < 3 else { return }
            replacements += 1
            do {
                try writeFile(prefix: replacements == 3 ? "final" : "gen\(replacements)")
            } catch {
                replacementWriteError = error
            }
        }
        session.start()
        defer { session.stop() }
        XCTAssertTrue(waitUntil(timeout: 8) {
            hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 50)
                .events.contains { $0.text == "final-\(lineCount - 1)" }
        }, "the FINAL source attaches after three consecutive replacements")
        XCTAssertNil(replacementWriteError)
        let allEvents = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 3000).events
        XCTAssertFalse(allEvents.contains { text in
            guard let text = text.text else { return false }
            return text.hasPrefix("gen0-") || text.hasPrefix("gen1-") || text.hasPrefix("gen2-")
        }, "no stale source's products survive")
        XCTAssertEqual(hub.currentHistoryEpoch(sessionID: "session").generation,
                       baseGeneration + 3,
                       "exactly one reset per replacement")
        XCTAssertTrue(session.validateHistoryEpoch(hub.currentHistoryEpoch(sessionID: "session")))
    }

    // A deferred resolver restart that runs AFTER stop() must be a no-op:
    // an ended session never re-attaches, never re-publishes its window,
    // and never leaves a live tailer behind.
    func testDeferredResolverRestartAfterStopDoesNotReattach() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexTranscriptSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcriptURL = directory.appendingPathComponent("rollout.jsonl", isDirectory: false)
        let lines = (0..<8).map { makeCodexMessageLine(role: "assistant", content: "a-\($0)") }
        try (lines.joined(separator: "\n") + "\n").write(to: transcriptURL, atomically: true, encoding: .utf8)
        let hub = AgentEventHub()
        let session = makeStartedCodexSession(transcriptURL, hub: hub, readySentinel: "a-7")
        session.stop()
        let endedEventCount = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 200).events.count
        // The queued restart from an earlier attach frame finally runs —
        // strictly after stop() in queue order.
        session.enqueueDeferredResolverRestartForTesting()
        // Drain the queue through the sync getters.
        XCTAssertFalse(session.hasActiveTailerForTesting,
                       "an ended session must not re-attach from a deferred restart")
        XCTAssertEqual(hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 200).events.count,
                       endedEventCount,
                       "nothing publishes after sessionEnded")
    }

    // startResolver must be idempotent per unattached session: repeated
    // same-generation calls with a failing resolve keep exactly ONE
    // fallback timer.
    func testRepeatedStartResolverKeepsSingleFallbackTimer() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexTranscriptSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let missingURL = directory.appendingPathComponent("never-written.jsonl", isDirectory: false)
        let hub = AgentEventHub()
        let session = CodexTranscriptSession(record: makeRecord(transcriptPath: missingURL.path),
                                             fileManager: .default,
                                             hub: hub)
        session.start()
        defer { session.stop() }
        XCTAssertFalse(session.hasActiveTailerForTesting, "precondition: the resolve keeps failing")
        let installsAfterStart = session.resolverTimerInstallCountSnapshotForTesting
        XCTAssertGreaterThanOrEqual(installsAfterStart, 1, "the fallback timer exists")
        session.enqueueDeferredResolverRestartForTesting()
        session.enqueueDeferredResolverRestartForTesting()
        XCTAssertFalse(session.hasActiveTailerForTesting)
        XCTAssertEqual(session.resolverTimerInstallCountSnapshotForTesting, installsAfterStart,
                       "repeated restarts reuse the existing fallback timer — no stacking/replacement")
    }

    // Guard: invalidation → transient → success settles on exactly the
    // final source; the Hub epoch advances only per invalidation, the
    // transient abort stays internal, and no stale products survive.
    func testInvalidationThenTransientThenSuccessSettlesOnce() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexTranscriptSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcriptURL = directory.appendingPathComponent("rollout.jsonl", isDirectory: false)
        let lineCount = transcriptBootstrapLineLimit + 20
        func writeFile(prefix: String) throws {
            let lines = (0..<lineCount).map { makeCodexMessageLine(role: "assistant", content: "\(prefix)-\($0)") }
            try (lines.joined(separator: "\n") + "\n").write(to: transcriptURL, atomically: true, encoding: .utf8)
        }
        try writeFile(prefix: "gen0")
        let hub = AgentEventHub()
        let baseGeneration = hub.currentHistoryEpoch(sessionID: "session").generation
        let session = CodexTranscriptSession(record: makeRecord(transcriptPath: transcriptURL.path),
                                             fileManager: .default,
                                             hub: hub)
        let lock = NSLock()
        var replaced = false
        var replacementWriteError: Error?
        session.bootstrapContextBeforeReadForTesting = {
            lock.lock()
            defer { lock.unlock() }
            guard replaced == false else { return }
            replaced = true
            do { try writeFile(prefix: "final") } catch { replacementWriteError = error }
        }
        var faultConsults = 0
        session.bootstrapContextReadFaultForTesting = {
            lock.lock()
            defer { lock.unlock() }
            faultConsults += 1
            // Attach 1 reaches the REAL read (invalidation); attach 2 hits
            // the transient fault; attach 3 succeeds.
            return faultConsults == 2 ? POSIXError(.EIO) : nil
        }
        session.start()
        defer { session.stop() }
        XCTAssertTrue(waitUntil(timeout: 8) {
            hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 50)
                .events.contains { $0.text == "final-\(lineCount - 1)" }
        }, "the final source attaches after invalidation → transient → success")
        XCTAssertNil(replacementWriteError)
        XCTAssertFalse(hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 3000)
                        .events.contains { $0.text?.hasPrefix("gen0-") == true },
                       "no stale products survive")
        XCTAssertEqual(hub.currentHistoryEpoch(sessionID: "session").generation,
                       baseGeneration + 1,
                       "the Hub epoch advances only for the invalidation — the transient abort stays internal")
        XCTAssertTrue(session.validateHistoryEpoch(hub.currentHistoryEpoch(sessionID: "session")))
        XCTAssertTrue(session.hasActiveTailerForTesting)
    }

    // B18: the source-reset base must adopt the Hub sequence high-water —
    // external synthetic/status publishes are cursor authority that
    // survives epochs. The replacement source's public sequences must be
    // EXACTLY highWater + raw layout (not merely "> high"), unique,
    // strictly increasing by raw position, and fixed for the whole source
    // epoch.
    func testEpochResetBaseAdoptsSyntheticHighWaterAndPreservesRawSequenceLayout() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexTranscriptSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let threadA = "019d70fe-fd27-7a12-a3f7-9c89ae5048b6"
        let threadB = "019ec8cb-fd27-7a12-a3f7-9c89ae5048b6"
        let transcriptA = directory.appendingPathComponent("rollout-a-\(threadA).jsonl", isDirectory: false)
        let transcriptB = directory.appendingPathComponent("rollout-b-\(threadB).jsonl", isDirectory: false)
        try (makeCodexMessageLine(role: "assistant", content: "a-old") + "\n")
            .write(to: transcriptA, atomically: true, encoding: .utf8)
        let bLines = (0..<3).map { makeCodexMessageLine(role: "assistant", content: "b-\($0)") }
        try (bLines.joined(separator: "\n") + "\n").write(to: transcriptB, atomically: true, encoding: .utf8)
        // Raw byte offsets of B's lines — the raw sequence layout.
        var bOffsets = [Int]()
        var runningOffset = 0
        for line in bLines {
            bOffsets.append(runningOffset)
            runningOffset += line.utf8.count + 1
        }

        let hub = AgentEventHub(maxBufferedEvents: 1)
        let session = CodexTranscriptSession(record: makeRecord(transcriptPath: transcriptA.path,
                                                                sessionID: "instance-session",
                                                                threadID: threadA,
                                                                resumeThreadID: threadA),
                                             fileManager: .default,
                                             hub: hub)
        session.start()
        defer { session.stop() }
        XCTAssertTrue(waitUntil {
            hub.fetch(workspaceID: "workspace", sessionID: "instance-session", limit: 5)
                .events.contains { $0.text == "a-old" }
        })
        hub.publish(AgentEvent(eventID: "external-synthetic",
                               seq: 1_000_000_000,
                               vendor: "codex",
                               workspaceID: "workspace",
                               sessionID: "instance-session",
                               timestamp: "2026-05-15T00:00:00Z",
                               type: .status,
                               role: nil, text: nil, name: nil, input: nil,
                               output: nil, toolCallID: nil, metadata: nil))
        let highWater = hub.sequenceHighWater(sessionID: "instance-session")
        XCTAssertGreaterThanOrEqual(highWater, 1_000_000_000)

        let deliveryLock = NSLock()
        var deliveredEvents = [AgentEvent]()
        let (subscriptionID, _) = hub.subscribe(workspaceID: "workspace", sessionID: "instance-session") { envelope in
            deliveryLock.lock()
            deliveredEvents.append(envelope.event)
            deliveryLock.unlock()
        }
        defer { hub.unsubscribe(subscriptionID) }

        session.update(record: makeRecord(transcriptPath: transcriptB.path,
                                          sessionID: "instance-session",
                                          threadID: threadB,
                                          resumeThreadID: threadA))
        XCTAssertTrue(waitUntil(timeout: 6) {
            deliveryLock.lock()
            defer { deliveryLock.unlock() }
            return (0..<3).allSatisfy { i in deliveredEvents.contains { $0.text == "b-\(i)" } }
        }, "the replacement source attaches and publishes")
        deliveryLock.lock()
        let accepted = (0..<3).compactMap { i in deliveredEvents.first { $0.text == "b-\(i)" } }
        deliveryLock.unlock()
        XCTAssertEqual(accepted.count, 3)
        for (index, event) in accepted.enumerated() {
            XCTAssertEqual(event.seq,
                           highWater + transcriptEventSequence(lineOffset: bOffsets[index], ordinal: 0),
                           "b-\(index): the public seq is EXACTLY highWater + raw layout, not a drifting rebase")
        }
        XCTAssertEqual(Set(accepted.map(\.seq)).count, 3, "all sequences unique")
        XCTAssertEqual(accepted.map(\.seq), accepted.map(\.seq).sorted(),
                       "sequences strictly follow raw position order")
        XCTAssertEqual(Set(accepted.map(\.eventID)).count, 3, "eventIDs unique and layout-stable")

        // No leakage of source A's exact/eventID maps into B: a before
        // fetch on b-1's ACCEPTED cursor returns exactly b-0 and excludes
        // the cursor event.
        let beforeMiddle = BridgeAgentEventFetchFlow.run(eventHub: hub,
                                                         workspaceID: "workspace",
                                                         sessionID: "instance-session",
                                                         limit: 10,
                                                         beforeSeq: accepted[1].seq,
                                                         afterSeq: nil) { _, beforeSeq, limit in
            session.backfill(beforeSeq: beforeSeq, limit: limit)
        }
        XCTAssertEqual(beforeMiddle.fetchResult.events.compactMap(\.text).filter { $0.hasPrefix("b-") },
                       ["b-0"],
                       "the accepted cursor inverts to EXACTLY the preceding row — nothing extra, cursor excluded")
    }

    // B18: mid-source Hub rebase — the accepted sequences (not the
    // proposed arithmetic) are the ONLY public cursor authority, for both
    // the legacy before inverse and the typed after-cursor replay.
    func testFileBackedCursorsUseAcceptedHubSequenceAfterMidSourceRebase() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexTranscriptSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcriptURL = directory.appendingPathComponent("rollout.jsonl", isDirectory: false)
        try (makeCodexMessageLine(role: "assistant", content: "initial") + "\n")
            .write(to: transcriptURL, atomically: true, encoding: .utf8)
        let hub = AgentEventHub(maxBufferedEvents: 1)
        let session = CodexTranscriptSession(record: makeRecord(transcriptPath: transcriptURL.path),
                                             fileManager: .default,
                                             hub: hub)
        session.start()
        defer { session.stop() }
        XCTAssertTrue(waitUntil {
            hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 5)
                .events.contains { $0.text == "initial" }
        })
        hub.publish(AgentEvent(eventID: "mid-source-synthetic",
                               seq: 20_000_000,
                               vendor: "codex",
                               workspaceID: "workspace",
                               sessionID: "session",
                               timestamp: "2026-05-15T00:00:00Z",
                               type: .status,
                               role: nil, text: nil, name: nil, input: nil,
                               output: nil, toolCallID: nil, metadata: nil))
        let deliveryLock = NSLock()
        var deliveredEvents = [AgentEvent]()
        let (subscriptionID, _) = hub.subscribe(workspaceID: "workspace", sessionID: "session") { envelope in
            deliveryLock.lock()
            deliveredEvents.append(envelope.event)
            deliveryLock.unlock()
        }
        defer { hub.unsubscribe(subscriptionID) }
        let appended = (0..<3).map { makeCodexMessageLine(role: "assistant", content: "r-\($0)") }
        let handle = try FileHandle(forWritingTo: transcriptURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((appended.joined(separator: "\n") + "\n").utf8))
        try handle.close()
        XCTAssertTrue(waitUntil {
            deliveryLock.lock()
            defer { deliveryLock.unlock() }
            return (0..<3).allSatisfy { i in deliveredEvents.contains { $0.text == "r-\(i)" } }
        })
        deliveryLock.lock()
        let acceptedRows = (0..<3).compactMap { i in deliveredEvents.first { $0.text == "r-\(i)" } }
        deliveryLock.unlock()
        XCTAssertEqual(acceptedRows.count, 3)
        XCTAssertTrue(acceptedRows.allSatisfy { $0.seq > 20_000_000 }, "precondition: Hub rebased the rows")
        XCTAssertFalse(hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 5)
                        .events.contains { $0.text == "r-0" },
                       "precondition: capacity one evicted the early rows")

        // A. Legacy before inverse on the ACCEPTED #2 cursor: exactly #1,
        // never the cursor event, no proposed-arithmetic misread.
        let beforeSecond = BridgeAgentEventFetchFlow.run(eventHub: hub,
                                                         workspaceID: "workspace",
                                                         sessionID: "session",
                                                         limit: 10,
                                                         beforeSeq: acceptedRows[1].seq,
                                                         afterSeq: nil) { _, beforeSeq, limit in
            session.backfill(beforeSeq: beforeSeq, limit: limit)
        }
        XCTAssertEqual(beforeSecond.fetchResult.events.compactMap(\.text).filter { $0.hasPrefix("r-") },
                       ["r-0"],
                       "the before inverse lands on EXACTLY the preceding row — nothing extra, cursor excluded")

        // B. Typed after flow from the ACCEPTED #1 cursor: exactly #2 and
        // #3, once each, ordered by accepted seq, identity-equal to the
        // live accepted events, and reproducible.
        func afterFetch() -> BridgeAgentEventFetchFlow.Output {
            BridgeAgentEventFetchFlow.run(
                eventHub: hub,
                workspaceID: "workspace",
                sessionID: "session",
                limit: 10,
                beforeSeq: nil,
                afterSeq: acceptedRows[0].seq,
                afterCursorSeams: .init(
                    plan: { _, afterSeq, expected in
                        session.afterCursorPlan(afterSeq: afterSeq, expectedEpoch: expected)
                    },
                    step: { _, anchor, afterSeq, limit in
                        session.afterCursorStep(from: anchor, afterSeq: afterSeq, limit: limit)
                    },
                    validateEpoch: { _, epoch in
                        session.validateHistoryEpoch(epoch)
                    })) { _, _, _ in
                XCTFail("the legacy backfill closure must not serve the typed after path")
                return false
            }
        }
        let after = afterFetch()
        let afterTriples = after.fetchResult.events
            .filter { ($0.text ?? "").hasPrefix("r-") }
            .map { "\($0.eventID)#\($0.seq)#\($0.text ?? "")" }
        let expectedTriples = [acceptedRows[1], acceptedRows[2]]
            .map { "\($0.eventID)#\($0.seq)#\($0.text ?? "")" }
        XCTAssertEqual(afterTriples, expectedTriples,
                       "the typed after replay serves EXACTLY the live accepted identities, in accepted order")
        let rerun = afterFetch()
        XCTAssertEqual(rerun.fetchResult.events.map { "\($0.eventID)#\($0.seq)#\($0.text ?? "")" },
                       after.fetchResult.events.map { "\($0.eventID)#\($0.seq)#\($0.text ?? "")" },
                       "the same fetch reruns byte-identically")
    }

    // Contract guard: after a Hub rebase, the never-published PROPOSED
    // sequence must not survive as exact raw authority. If an
    // implementation kept the old proposed-seq exact-map write and merely
    // ADDED the accepted mapping, a plan on the proposed cursor would
    // wrongly classify rawCovered. (Production was fixed in 208a56ad8;
    // this is the test-only closure pinning it.)
    func testRebasedProposedSequenceIsNotRetainedAsExactRawAuthority() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexTranscriptSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcriptURL = directory.appendingPathComponent("rollout.jsonl", isDirectory: false)
        let lineCount = transcriptBootstrapLineLimit + 1
        let lines = (0..<lineCount).map { makeCodexMessageLine(role: "assistant", content: "row-\($0)") }
        try (lines.joined(separator: "\n") + "\n").write(to: transcriptURL, atomically: true, encoding: .utf8)
        var offsets = [Int]()
        var runningOffset = 0
        for line in lines {
            offsets.append(runningOffset)
            runningOffset += line.utf8.count + 1
        }
        let appendOffset = runningOffset
        let hub = AgentEventHub()
        let session = makeStartedCodexSession(transcriptURL, hub: hub,
                                              readySentinel: "row-\(lineCount - 1)")
        defer { session.stop() }
        // Nonzero retained floor, PROVEN behaviorally: a cursor below the
        // bootstrap floor must plan a scan (floor == 0 would rawCover it).
        let epochAtFloorProbe = hub.currentHistoryEpoch(sessionID: "session")
        guard case .scan = session.afterCursorPlan(afterSeq: 0, expectedEpoch: epochAtFloorProbe).mode else {
            return XCTFail("precondition: the retained floor is nonzero — afterSeq 0 must scan")
        }
        // Derive the session's sequence base from an observed accepted row
        // (nothing has been rebased yet), then the append row's proposal.
        let lastRow = try XCTUnwrap(hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 5)
            .events.first { $0.text == "row-\(lineCount - 1)" })
        let base = lastRow.seq - transcriptEventSequence(lineOffset: offsets[lineCount - 1], ordinal: 0)
        let proposedSeq = base + transcriptEventSequence(lineOffset: appendOffset, ordinal: 0)
        hub.publish(AgentEvent(eventID: "external-high-synthetic",
                               seq: 1_000_000_000,
                               vendor: "codex",
                               workspaceID: "workspace",
                               sessionID: "session",
                               timestamp: "2026-05-15T00:00:00Z",
                               type: .status,
                               role: nil, text: nil, name: nil, input: nil,
                               output: nil, toolCallID: nil, metadata: nil))
        let highWater = hub.sequenceHighWater(sessionID: "session")
        XCTAssertGreaterThan(highWater, proposedSeq,
                             "precondition: the high-water sits above the append row's proposal")
        let deliveryLock = NSLock()
        var acceptedAppend: AgentEvent?
        let (subscriptionID, _) = hub.subscribe(workspaceID: "workspace", sessionID: "session") { envelope in
            deliveryLock.lock()
            if envelope.event.text == "appended-row" {
                acceptedAppend = envelope.event
            }
            deliveryLock.unlock()
        }
        defer { hub.unsubscribe(subscriptionID) }
        let handle = try FileHandle(forWritingTo: transcriptURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((makeCodexMessageLine(role: "assistant", content: "appended-row") + "\n").utf8))
        try handle.close()
        XCTAssertTrue(waitUntil {
            deliveryLock.lock()
            defer { deliveryLock.unlock() }
            return acceptedAppend != nil
        })
        deliveryLock.lock()
        let accepted = acceptedAppend
        deliveryLock.unlock()
        let acceptedSeq = try XCTUnwrap(accepted?.seq)
        XCTAssertGreaterThan(acceptedSeq, highWater, "precondition: the Hub rebased the append")
        XCTAssertNotEqual(acceptedSeq, proposedSeq)

        // The NEVER-PUBLISHED proposed cursor must scan: with a nonzero
        // retained floor and proposed < accepted max, only a leftover
        // proposed-seq exact mapping could claim rawCovered.
        let epoch = hub.currentHistoryEpoch(sessionID: "session")
        switch session.afterCursorPlan(afterSeq: proposedSeq, expectedEpoch: epoch).mode {
        case .scan:
            break
        case .rawCovered:
            XCTFail("the rebased row's proposed seq must NOT survive as exact raw authority")
        case .hubOnly, .unavailable:
            XCTFail("the source stays plannable")
        }
        // Guard: the ACCEPTED cursor still classifies through the exact
        // map — fixing the proposed authority must not drop the accepted
        // mapping.
        switch session.afterCursorPlan(afterSeq: acceptedSeq, expectedEpoch: epoch).mode {
        case .rawCovered:
            break
        case .scan, .hubOnly, .unavailable:
            XCTFail("the accepted cursor keeps its exact raw classification")
        }
    }

    // B19: a replacement epoch must not reuse the retired source's scan
    // frontier. A full real-flow walk lowers A's scan floor to BOF; after
    // switching to a different-path, different-size B, the fresh plan must
    // be EXACTLY a scan anchored at B's OWN EOF, and a real typed fetch
    // must serve the complete B depth.
    func testReplacementEpochDoesNotReuseOldScanFrontier() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexTranscriptSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let lineCount = transcriptBootstrapLineLimit + 20
        let threadA = "019d70fe-fd27-7a12-a3f7-9c89ae5048b6"
        let threadB = "019ec8cb-fd27-7a12-a3f7-9c89ae5048b6"
        let transcriptA = directory.appendingPathComponent("rollout-a-\(threadA).jsonl", isDirectory: false)
        let transcriptB = directory.appendingPathComponent("rollout-b-\(threadB).jsonl", isDirectory: false)
        let aTexts = (0..<lineCount).map { "a-\($0)" }
        // Deliberately different byte size for B.
        let bTexts = (0..<lineCount).map { "b-\($0)-" + String(repeating: "y", count: 23) }
        let aLines = aTexts.map { makeCodexMessageLine(role: "assistant", content: $0) }
        let bLines = bTexts.map { makeCodexMessageLine(role: "assistant", content: $0) }
        try (aLines.joined(separator: "\n") + "\n").write(to: transcriptA, atomically: true, encoding: .utf8)
        try (bLines.joined(separator: "\n") + "\n").write(to: transcriptB, atomically: true, encoding: .utf8)
        let bEOF = bLines.reduce(0) { $0 + $1.utf8.count + 1 }
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
            hub.fetch(workspaceID: "workspace", sessionID: "instance-session", limit: 5)
                .events.contains { $0.text == aTexts[lineCount - 1] }
        })

        func fetchOnce() -> BridgeAgentEventFetchFlow.Output {
            BridgeAgentEventFetchFlow.run(
                eventHub: hub,
                workspaceID: "workspace",
                sessionID: "instance-session",
                limit: lineCount + 10,
                beforeSeq: nil,
                afterSeq: 0,
                afterCursorSeams: .init(
                    plan: { _, afterSeq, expected in
                        session.afterCursorPlan(afterSeq: afterSeq, expectedEpoch: expected)
                    },
                    step: { _, anchor, afterSeq, limit in
                        session.afterCursorStep(from: anchor, afterSeq: afterSeq, limit: limit)
                    },
                    validateEpoch: { _, epoch in
                        session.validateHistoryEpoch(epoch)
                    })) { _, _, _ in
                XCTFail("the legacy backfill closure must not serve the typed after path")
                return false
            }
        }

        // A's scan floor really reaches BOF: the full real-flow walk
        // covers EVERY A row, in raw order, with no more pages.
        let aWalk = fetchOnce()
        XCTAssertTrue(aWalk.didBackfill, "the A walk really ran")
        XCTAssertEqual(aWalk.fetchResult.events.compactMap(\.text).filter { $0.hasPrefix("a-") },
                       aTexts, "the A walk covers the exact ordered A depth")
        XCTAssertFalse(aWalk.fetchResult.hasMore)

        let oldEpoch = hub.currentHistoryEpoch(sessionID: "instance-session")
        session.update(record: makeRecord(transcriptPath: transcriptB.path,
                                          sessionID: "instance-session",
                                          threadID: threadB,
                                          resumeThreadID: threadA))
        XCTAssertTrue(waitUntil(timeout: 6) {
            hub.fetch(workspaceID: "workspace", sessionID: "instance-session", limit: 5)
                .events.contains { $0.text == bTexts[lineCount - 1] }
        }, "the replacement source attaches")
        let newEpoch = hub.currentHistoryEpoch(sessionID: "instance-session")
        XCTAssertEqual(newEpoch.generation, oldEpoch.generation + 1, "exactly one reset")
        XCTAssertFalse(hub.fetch(workspaceID: "workspace", sessionID: "instance-session", limit: 2000)
                        .events.contains { $0.text?.hasPrefix("a-") == true },
                       "A's products are revoked")
        // The retired epoch fails closed under the existing typed contract.
        if case .unavailable = session.afterCursorPlan(afterSeq: 0, expectedEpoch: oldEpoch).mode {
        } else {
            XCTFail("a plan against the retired epoch is unavailable")
        }
        let staleStep = session.afterCursorStep(
            from: AgentHistoryAnchor(epoch: oldEpoch,
                                     position: TranscriptEventPosition(lineOffset: 64, ordinal: 0)),
            afterSeq: 0, limit: 10)
        guard case .sourceChanged = staleStep.outcome else {
            return XCTFail("a step against the retired epoch reports sourceChanged, got \(staleStep.outcome)")
        }
        XCTAssertFalse(session.validateHistoryEpoch(oldEpoch), "the retired epoch never validates")

        // The fresh B plan is EXACTLY a scan anchored at B's own EOF.
        let freshPlan = session.afterCursorPlan(afterSeq: 0, expectedEpoch: newEpoch)
        guard case .scan(let anchor) = freshPlan.mode else {
            return XCTFail("the fresh plan must SCAN — never rawCovered/hubOnly/unavailable from a stale frontier, got \(freshPlan.mode)")
        }
        XCTAssertEqual(anchor.epoch, newEpoch, "the anchor belongs to the B epoch")
        XCTAssertEqual(anchor.position, TranscriptEventPosition(lineOffset: bEOF, ordinal: 0),
                       "the anchor is B's OWN EOF, not anything inherited from A")

        // The real typed fetch serves the complete B depth, three times
        // identically.
        var runs = [[String]]()
        for _ in 0..<3 {
            let output = fetchOnce()
            XCTAssertEqual(output.fetchResult.events.compactMap(\.text).filter { $0.hasPrefix("b-") },
                           bTexts, "the B walk serves the exact ordered B depth")
            for index in 0..<20 {
                XCTAssertTrue(output.fetchResult.events.contains { $0.text == bTexts[index] },
                              "b-\(index) below the bootstrap window is served")
            }
            XCTAssertFalse(output.fetchResult.events.contains { $0.text?.hasPrefix("a-") == true })
            let ids = output.fetchResult.events.map(\.eventID)
            XCTAssertEqual(Set(ids).count, ids.count, "no duplicate eventIDs")
            let seqs = output.fetchResult.events.map(\.seq)
            XCTAssertEqual(seqs, seqs.sorted(), "sequences strictly increase")
            XCTAssertEqual(Set(seqs).count, seqs.count)
            XCTAssertFalse(output.fetchResult.hasMore)
            runs.append(output.fetchResult.events.map { "\($0.eventID)#\($0.seq)#\($0.text ?? "")" })
        }
        XCTAssertEqual(runs[0], runs[1])
        XCTAssertEqual(runs[1], runs[2], "three reruns are triple-identical")
    }

    func testValidationSourceFenceRunsBeforeSemanticTrustGate() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexTranscriptSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcriptURL = directory.appendingPathComponent("rollout.jsonl", isDirectory: false)
        let lines = (0..<4).map { makeCodexMessageLine(role: "assistant", content: "a-\($0)") }
        try (lines.joined(separator: "\n") + "\n").write(to: transcriptURL, atomically: true, encoding: .utf8)
        let hub = AgentEventHub()
        let session = makeStartedCodexSession(transcriptURL, hub: hub, readySentinel: "a-3")
        defer { session.stop() }
        let oldEpoch = hub.currentHistoryEpoch(sessionID: "session")

        // Poison source A via a live malformed append.
        let handle = try FileHandle(forWritingTo: transcriptURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("this-is-not-json\n".utf8))
        try handle.close()
        XCTAssertTrue(waitUntil { session.validateHistoryEpoch(oldEpoch) == false },
                      "precondition: source A is poisoned")

        // The poisoned A is then atomically replaced by a CLEAN B: the
        // source fence must detect it BEFORE the trust gate short-circuits.
        var replacementWriteError: Error?
        session.validateHistoryEpochBeforeSourceValidationForTesting = {
            do {
                try Data((self.makeCodexMessageLine(role: "assistant", content: "b-sentinel") + "\n").utf8)
                    .write(to: transcriptURL, options: .atomic)
            } catch {
                replacementWriteError = error
            }
        }
        defer { session.validateHistoryEpochBeforeSourceValidationForTesting = nil }

        XCTAssertFalse(session.validateHistoryEpoch(oldEpoch))
        XCTAssertNil(replacementWriteError)
        XCTAssertEqual(hub.currentHistoryEpoch(sessionID: "session").generation,
                       oldEpoch.generation + 1,
                       "the fence ran before the trust gate: the replacement was detected and reset exactly once")
        XCTAssertFalse(hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 50)
                        .events.contains { $0.text?.hasPrefix("a-") == true })
        XCTAssertTrue(waitUntil(timeout: 4) {
            hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 50)
                .events.contains { $0.text == "b-sentinel" }
        }, "the clean replacement reattaches")
        let freshEpoch = hub.currentHistoryEpoch(sessionID: "session")
        switch session.afterCursorPlan(afterSeq: 0, expectedEpoch: freshEpoch).mode {
        case .rawCovered, .scan:
            break
        case .hubOnly, .unavailable:
            XCTFail("the clean replacement source plans normally")
        }
    }

    func testPlanSourceFenceRunsBeforeSemanticTrustGate() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexTranscriptSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcriptURL = directory.appendingPathComponent("rollout.jsonl", isDirectory: false)
        let lines = (0..<4).map { makeCodexMessageLine(role: "assistant", content: "a-\($0)") }
        try (lines.joined(separator: "\n") + "\n").write(to: transcriptURL, atomically: true, encoding: .utf8)
        let hub = AgentEventHub()
        let session = makeStartedCodexSession(transcriptURL, hub: hub, readySentinel: "a-3")
        defer { session.stop() }
        let oldEpoch = hub.currentHistoryEpoch(sessionID: "session")

        let handle = try FileHandle(forWritingTo: transcriptURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("this-is-not-json\n".utf8))
        try handle.close()
        XCTAssertTrue(waitUntil { session.validateHistoryEpoch(oldEpoch) == false },
                      "precondition: source A is poisoned")

        var replacementWriteError: Error?
        session.afterCursorPlanBeforeSourceValidationForTesting = {
            do {
                try Data((self.makeCodexMessageLine(role: "assistant", content: "b-sentinel") + "\n").utf8)
                    .write(to: transcriptURL, options: .atomic)
            } catch {
                replacementWriteError = error
            }
        }
        defer { session.afterCursorPlanBeforeSourceValidationForTesting = nil }

        let plan = session.afterCursorPlan(afterSeq: 0, expectedEpoch: oldEpoch)
        guard case .unavailable = plan.mode else {
            return XCTFail("the stale-epoch plan is unavailable, got \(plan.mode)")
        }
        XCTAssertNil(replacementWriteError)
        XCTAssertEqual(hub.currentHistoryEpoch(sessionID: "session").generation,
                       oldEpoch.generation + 1,
                       "the plan's fence ran before the trust gate and reset exactly once")
        XCTAssertTrue(waitUntil(timeout: 4) {
            hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 50)
                .events.contains { $0.text == "b-sentinel" }
        }, "the clean replacement reattaches")
        // Unhook before the fresh plan: re-firing the atomic replace would
        // legitimately invalidate B and mask the assertion under test.
        session.afterCursorPlanBeforeSourceValidationForTesting = nil
        let freshEpoch = hub.currentHistoryEpoch(sessionID: "session")
        switch session.afterCursorPlan(afterSeq: 0, expectedEpoch: freshEpoch).mode {
        case .rawCovered, .scan:
            break
        case .hubOnly, .unavailable:
            XCTFail("the clean replacement source plans normally")
        }
    }

    func testCodexRepeatedAfterCursorFetchRescansRequestOwnedDepth() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexTranscriptSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcriptURL = directory.appendingPathComponent("rollout.jsonl", isDirectory: false)
        let lineCount = transcriptBootstrapLineLimit + 20
        let contents = (0..<lineCount).map { "depth-\($0)-" + String(repeating: "x", count: 160) }
        try (contents.map { makeCodexMessageLine(role: "assistant", content: $0) }
                .joined(separator: "\n") + "\n")
            .write(to: transcriptURL, atomically: true, encoding: .utf8)
        let hub = AgentEventHub()
        let session = CodexTranscriptSession(record: makeRecord(transcriptPath: transcriptURL.path),
                                             fileManager: .default,
                                             hub: hub)
        session.start()
        defer { session.stop() }
        XCTAssertTrue(waitUntil {
            hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 5)
                .events.contains { $0.text == contents[lineCount - 1] }
        })
        func fetchOnce() -> BridgeAgentEventFetchFlow.Output {
            BridgeAgentEventFetchFlow.run(
                eventHub: hub,
                workspaceID: "workspace",
                sessionID: "session",
                limit: 2000,
                beforeSeq: nil,
                afterSeq: 0,
                afterCursorSeams: .init(
                    plan: { _, afterSeq, expected in
                        session.afterCursorPlan(afterSeq: afterSeq, expectedEpoch: expected)
                    },
                    step: { _, anchor, afterSeq, limit in
                        session.afterCursorStep(from: anchor, afterSeq: afterSeq, limit: limit)
                    },
                    validateEpoch: { _, epoch in
                        session.validateHistoryEpoch(epoch)
                    })) { _, _, _ in
                XCTFail("the legacy backfill closure must not serve the typed after path")
                return false
            }
        }

        let first = fetchOnce()
        XCTAssertTrue(first.didBackfill)
        let expected = Set(contents)
        let firstFixtureTexts = first.fetchResult.events.compactMap(\.text)
            .filter { $0.hasPrefix("depth-") }
        XCTAssertEqual(firstFixtureTexts.count, lineCount,
                       "exactly one product per fixture line — no duplicate, no gap")
        XCTAssertEqual(Set(firstFixtureTexts), expected,
                       "the fixture-filtered page is EXACTLY the expected text set")

        // A request-owned scan must NOT promote the eligibility floor: the
        // deep pages exist only in that request's response, not in any
        // retained window.
        let planAfterFirst = session.afterCursorPlan(
            afterSeq: 0,
            expectedEpoch: hub.currentHistoryEpoch(sessionID: "session"))
        guard case .scan = planAfterFirst.mode else {
            return XCTFail("a repeated fetch must re-scan; request-owned depth is not retained coverage, got \(planAfterFirst.mode)")
        }

        let second = fetchOnce()
        XCTAssertTrue(second.didBackfill,
                      "the second identical fetch re-walks the raw depth")
        func triples(_ output: BridgeAgentEventFetchFlow.Output) -> [String] {
            output.fetchResult.events.map { "\($0.eventID)#\($0.seq)#\($0.text ?? "")" }
        }
        XCTAssertEqual(triples(second), triples(first),
                       "the second fetch serves the IDENTICAL complete page — no gap, no duplicate")
    }

    func testValidationSourceInvalidationRevokesEpochBeforeReturningFalse() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexTranscriptSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcriptURL = directory.appendingPathComponent("rollout.jsonl", isDirectory: false)
        let lines = (0..<8).map { makeCodexMessageLine(role: "assistant", content: "a-\($0)") }
        try (lines.joined(separator: "\n") + "\n").write(to: transcriptURL, atomically: true, encoding: .utf8)
        let hub = AgentEventHub()
        let session = CodexTranscriptSession(record: makeRecord(transcriptPath: transcriptURL.path),
                                             fileManager: .default,
                                             hub: hub)
        session.start()
        defer { session.stop() }
        XCTAssertTrue(waitUntil {
            hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 10)
                .events.contains { $0.text == "a-7" }
        })
        let oldEpoch = hub.currentHistoryEpoch(sessionID: "session")
        var replacementWriteError: Error?
        session.validateHistoryEpochBeforeSourceValidationForTesting = {
            do {
                try Data((self.makeCodexMessageLine(role: "assistant", content: "b-sentinel") + "\n").utf8)
                    .write(to: transcriptURL, options: .atomic)
            } catch {
                replacementWriteError = error
            }
        }
        defer { session.validateHistoryEpochBeforeSourceValidationForTesting = nil }

        let validated = session.validateHistoryEpoch(oldEpoch)

        XCTAssertNil(replacementWriteError)
        XCTAssertFalse(validated)
        // AT RETURN the epoch has already advanced exactly once and A's
        // products are revoked — the G3c retry signal reads a CHANGED Hub
        // epoch, never an unchanged-epoch terminal false.
        XCTAssertEqual(hub.currentHistoryEpoch(sessionID: "session").generation,
                       oldEpoch.generation + 1)
        XCTAssertFalse(hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 50)
                        .events.contains { $0.text?.hasPrefix("a-") == true })
        XCTAssertTrue(waitUntil(timeout: 4) {
            hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 50)
                .events.contains { $0.text == "b-sentinel" }
        }, "the resolver reattaches source B")
        XCTAssertEqual(hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 50)
                        .events.filter { $0.text == "b-sentinel" }.count, 1)
        XCTAssertEqual(hub.currentHistoryEpoch(sessionID: "session").generation,
                       oldEpoch.generation + 1,
                       "no stale tailer callback bumps the generation a second time")
    }

    func testCodexBeforeCursorDoesNotClaimBOFAfterOffsetZeroSourceReplacement() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexTranscriptSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcriptURL = directory.appendingPathComponent("rollout.jsonl", isDirectory: false)
        let replacementURL = directory.appendingPathComponent("replacement.jsonl", isDirectory: false)
        try (makeCodexMessageLine(role: "assistant", content: "old-offset-zero") + "\n")
            .write(to: transcriptURL, atomically: true, encoding: .utf8)
        try (makeCodexMessageLine(role: "assistant", content: "replacement") + "\n")
            .write(to: replacementURL, atomically: true, encoding: .utf8)

        let hub = AgentEventHub()
        let session = CodexTranscriptSession(record: makeRecord(transcriptPath: transcriptURL.path),
                                             fileManager: .default,
                                             hub: hub)
        session.start()
        defer { session.stop() }
        XCTAssertTrue(waitUntil {
            hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 10)
                .events.contains { $0.text == "old-offset-zero" }
        })
        let acceptedCursor = try XCTUnwrap(
            hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 10)
                .events.first { $0.text == "old-offset-zero" }?.seq
        )

        var replacementResult: Int32?
        session.beforeCursorBackfillBeforeSourceValidationForTesting = {
            replacementResult = Darwin.rename(replacementURL.path, transcriptURL.path)
        }

        let result = session.beforeCursorBackfill(beforeSeq: acceptedCursor, limit: 500)

        XCTAssertEqual(replacementResult, 0)
        XCTAssertFalse(result.didBackfill)
        XCTAssertEqual(result.rawContinuation, .unavailable,
                       "a stale offset-zero cursor must not claim source-proven BOF")
    }

    func testCodexBeforeCursorSourceReplacementAfterReplayRevokesStaleProducts() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexTranscriptSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcriptURL = directory.appendingPathComponent("rollout.jsonl", isDirectory: false)
        let replacementURL = directory.appendingPathComponent("replacement.jsonl", isDirectory: false)
        let recent = (0..<transcriptBootstrapLineLimit).map {
            makeCodexMessageLine(role: "assistant", content: "a-recent-\($0)")
        }
        try (([makeCodexMessageLine(role: "assistant", content: "a-stale-history")] + recent)
            .joined(separator: "\n") + "\n")
            .write(to: transcriptURL, atomically: true, encoding: .utf8)
        try (makeCodexMessageLine(role: "assistant", content: "b-sentinel") + "\n")
            .write(to: replacementURL, atomically: true, encoding: .utf8)

        let hub = AgentEventHub()
        let session = CodexTranscriptSession(record: makeRecord(transcriptPath: transcriptURL.path),
                                             fileManager: .default,
                                             hub: hub)
        session.start()
        defer { session.stop() }
        XCTAssertTrue(waitUntil {
            hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 5)
                .events.contains { $0.text == "a-recent-\(transcriptBootstrapLineLimit - 1)" }
        })
        let beforeSeq = try XCTUnwrap(
            hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 2000)
                .events
                .filter { $0.text?.hasPrefix("a-recent-") == true }
                .map(\.seq)
                .min()
        )
        let oldEpoch = hub.currentHistoryEpoch(sessionID: "session")
        var replacementResult: Int32?
        session.beforeCursorBackfillBeforeFinalSourceValidationForTesting = {
            replacementResult = Darwin.rename(replacementURL.path, transcriptURL.path)
        }
        defer { session.beforeCursorBackfillBeforeFinalSourceValidationForTesting = nil }

        let result = session.beforeCursorBackfill(beforeSeq: beforeSeq, limit: 500)

        XCTAssertEqual(replacementResult, 0)
        XCTAssertFalse(result.didBackfill)
        XCTAssertEqual(result.rawContinuation, .unavailable,
                       "products derived from a replaced source have no continuation authority")
        XCTAssertEqual(hub.currentHistoryEpoch(sessionID: "session").generation,
                       oldEpoch.generation + 1,
                       "the stale source is synchronously revoked before the request returns")
        XCTAssertFalse(
            hub.fetch(workspaceID: "workspace",
                      sessionID: "session",
                      limit: 2000,
                      beforeSeq: beforeSeq)
                .events
                .contains { $0.text == "a-stale-history" },
            "stale replay products must never enter shared history"
        )
        XCTAssertTrue(waitUntil(timeout: 4) {
            hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 50)
                .events.contains { $0.text == "b-sentinel" }
        }, "the resolver reattaches the replacement source")
        XCTAssertEqual(hub.currentHistoryEpoch(sessionID: "session").generation,
                       oldEpoch.generation + 1,
                       "the retired tailer's queued callback cannot reset the replacement twice")
    }

    func testCodexBeforeCursorHubEpochChangeAfterReplayDoesNotPublishIntoReplacementEpoch() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexTranscriptSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcriptURL = directory.appendingPathComponent("rollout.jsonl", isDirectory: false)
        let recent = (0..<transcriptBootstrapLineLimit).map {
            makeCodexMessageLine(role: "assistant", content: "epoch-recent-\($0)")
        }
        try (([makeCodexMessageLine(role: "assistant", content: "epoch-stale-history")] + recent)
            .joined(separator: "\n") + "\n")
            .write(to: transcriptURL, atomically: true, encoding: .utf8)

        let hub = AgentEventHub()
        let session = CodexTranscriptSession(record: makeRecord(transcriptPath: transcriptURL.path),
                                             fileManager: .default,
                                             hub: hub)
        session.start()
        defer { session.stop() }
        XCTAssertTrue(waitUntil {
            hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 5)
                .events.contains { $0.text == "epoch-recent-\(transcriptBootstrapLineLimit - 1)" }
        })
        let beforeSeq = try XCTUnwrap(
            hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 2000)
                .events
                .filter { $0.text?.hasPrefix("epoch-recent-") == true }
                .map(\.seq)
                .min()
        )
        let oldEpoch = hub.currentHistoryEpoch(sessionID: "session")
        session.beforeCursorBackfillBeforeFinalSourceValidationForTesting = {
            hub.beginNewSourceEpoch(sessionID: "session")
        }
        defer { session.beforeCursorBackfillBeforeFinalSourceValidationForTesting = nil }

        let result = session.beforeCursorBackfill(beforeSeq: beforeSeq, limit: 500)

        XCTAssertFalse(result.didBackfill)
        XCTAssertEqual(result.rawContinuation, .unavailable)
        XCTAssertEqual(hub.currentHistoryEpoch(sessionID: "session").generation,
                       oldEpoch.generation + 1)
        XCTAssertFalse(
            hub.fetch(workspaceID: "workspace",
                      sessionID: "session",
                      limit: 2000,
                      beforeSeq: beforeSeq)
                .events
                .contains { $0.text == "epoch-stale-history" },
            "source A replay products must not be written into the replacement Hub epoch"
        )
    }

    func testAfterCursorReadErrorDoesNotRevokeValidSource() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexTranscriptSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
            try? FileManager.default.removeItem(at: directory)
        }
        let transcriptURL = directory.appendingPathComponent("rollout.jsonl", isDirectory: false)
        let lines = (0..<8).map { makeCodexMessageLine(role: "assistant", content: "a-\($0)") }
        try (lines.joined(separator: "\n") + "\n").write(to: transcriptURL, atomically: true, encoding: .utf8)
        let hub = AgentEventHub()
        let session = CodexTranscriptSession(record: makeRecord(transcriptPath: transcriptURL.path),
                                             fileManager: .default,
                                             hub: hub)
        session.start()
        defer { session.stop() }
        XCTAssertTrue(waitUntil {
            hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 10)
                .events.contains { $0.text == "a-7" }
        })
        let epoch = hub.currentHistoryEpoch(sessionID: "session")
        let plan = session.afterCursorPlan(afterSeq: 0, expectedEpoch: epoch)
        let startAnchor: AgentHistoryAnchor
        switch plan.mode {
        case .rawCovered(let anchor), .scan(let anchor):
            startAnchor = anchor
        case .hubOnly, .unavailable:
            return XCTFail("precondition: a typed anchor exists, got \(plan.mode)")
        }
        // A transient path-read I/O failure (unreadable directory) is NOT a
        // source invalidation.
        session.tailerBackfillBeforeReadForTesting = {
            try? FileManager.default.setAttributes([.posixPermissions: 0o000],
                                                   ofItemAtPath: directory.path)
        }

        let step = session.afterCursorStep(from: startAnchor, afterSeq: 0, limit: 5)

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        session.tailerBackfillBeforeReadForTesting = nil
        guard case .unavailable = step.outcome else {
            return XCTFail("a plain read error is unavailable, got \(step.outcome)")
        }
        XCTAssertTrue(step.events.isEmpty)
        XCTAssertEqual(hub.currentHistoryEpoch(sessionID: "session"), epoch,
                       "a read error must not bump the epoch")
        XCTAssertTrue(hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 50)
                        .events.contains { $0.text == "a-7" },
                      "existing events survive a read error")
        let retryPlan = session.afterCursorPlan(afterSeq: 0, expectedEpoch: epoch)
        switch retryPlan.mode {
        case .rawCovered, .scan:
            break
        case .hubOnly, .unavailable:
            XCTFail("the same epoch plans again once the read error clears, got \(retryPlan.mode)")
        }
    }

    func testEquivalentTranscriptPathMetadataUpdateDoesNotResetEpoch() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexTranscriptSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("nested", isDirectory: true),
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcriptURL = directory.appendingPathComponent("rollout.jsonl", isDirectory: false)
        let lines = (0..<8).map { makeCodexMessageLine(role: "assistant", content: "a-\($0)") }
        try (lines.joined(separator: "\n") + "\n").write(to: transcriptURL, atomically: true, encoding: .utf8)
        let equivalentPath = directory
            .appendingPathComponent("nested", isDirectory: true).path + "/../rollout.jsonl"
        let hub = AgentEventHub()
        let session = CodexTranscriptSession(record: makeRecord(transcriptPath: equivalentPath),
                                             fileManager: .default,
                                             hub: hub)
        session.start()
        defer { session.stop() }
        XCTAssertTrue(waitUntil {
            hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 10)
                .events.contains { $0.text == "a-7" }
        })
        let epoch = hub.currentHistoryEpoch(sessionID: "session")

        // The SAME file under its standardized path: registry metadata
        // enrichment, not a source switch.
        session.update(record: makeRecord(transcriptPath: transcriptURL.standardizedFileURL.path))
        _ = session.validateHistoryEpoch(epoch)   // flush the session queue

        XCTAssertEqual(hub.currentHistoryEpoch(sessionID: "session"), epoch,
                       "an equivalent-path metadata update must not reset the epoch")
        XCTAssertTrue(hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 50)
                        .events.contains { $0.text == "a-7" },
                      "the original events survive")
        XCTAssertTrue(session.validateHistoryEpoch(epoch),
                      "the tailer keeps running across the metadata update")
    }

    func testAfterCursorStepInvalidationRevokesOldEpochAndResolverReattaches() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexTranscriptSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcriptURL = directory.appendingPathComponent("rollout.jsonl", isDirectory: false)
        let lines = (0..<8).map { makeCodexMessageLine(role: "assistant", content: "a-\($0)") }
        try (lines.joined(separator: "\n") + "\n").write(to: transcriptURL, atomically: true, encoding: .utf8)
        let hub = AgentEventHub()
        let session = CodexTranscriptSession(record: makeRecord(transcriptPath: transcriptURL.path),
                                             fileManager: .default,
                                             hub: hub)
        session.start()
        defer { session.stop() }
        XCTAssertTrue(waitUntil {
            hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 10)
                .events.contains { $0.text == "a-7" }
        })
        let oldEpoch = hub.currentHistoryEpoch(sessionID: "session")
        hub.replaceHistoricalEvents(sessionID: "session", events: [makeCacheSentinel(seq: 1)])
        let plan = session.afterCursorPlan(afterSeq: 0, expectedEpoch: oldEpoch)
        let startAnchor: AgentHistoryAnchor
        switch plan.mode {
        case .rawCovered(let anchor), .scan(let anchor):
            startAnchor = anchor
        case .hubOnly, .unavailable:
            return XCTFail("precondition: source A yields a typed anchor, got \(plan.mode)")
        }
        var replacementWriteError: Error?
        session.afterCursorStepAfterRawReadForTesting = {
            do {
                try Data((self.makeCodexMessageLine(role: "assistant", content: "b-sentinel") + "\n").utf8)
                    .write(to: transcriptURL, options: .atomic)
            } catch {
                replacementWriteError = error
            }
        }
        defer { session.afterCursorStepAfterRawReadForTesting = nil }

        let step = session.afterCursorStep(from: startAnchor, afterSeq: 0, limit: 5)

        XCTAssertNil(replacementWriteError)
        guard case .sourceChanged = step.outcome else {
            return XCTFail("a replaced source is sourceChanged, got \(step.outcome)")
        }
        XCTAssertTrue(step.events.isEmpty)
        XCTAssertEqual(hub.currentHistoryEpoch(sessionID: "session").generation,
                       oldEpoch.generation + 1,
                       "the Hub generation advances EXACTLY once")
        XCTAssertFalse(hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 50)
                        .events.contains { $0.text?.hasPrefix("a-") == true },
                       "source A's LIVE events are revoked immediately")
        XCTAssertFalse(hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 50, beforeSeq: 5)
                        .events.contains { $0.eventID == "cache-sentinel" },
                       "source A's HISTORICAL events are revoked immediately")
        XCTAssertFalse(session.validateHistoryEpoch(oldEpoch))

        XCTAssertTrue(waitUntil(timeout: 4) {
            hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 50)
                .events.contains { $0.text == "b-sentinel" }
        }, "the resolver reattaches AFTER cleanup and bootstraps source B")
        XCTAssertEqual(hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 50)
                        .events.filter { $0.text == "b-sentinel" }.count, 1,
                       "the replacement sentinel appears exactly once")
        XCTAssertEqual(hub.currentHistoryEpoch(sessionID: "session").generation,
                       oldEpoch.generation + 1,
                       "no stale tailer callback bumps the generation a second time")

        let freshEpoch = hub.currentHistoryEpoch(sessionID: "session")
        let freshPlan = session.afterCursorPlan(afterSeq: 0, expectedEpoch: freshEpoch)
        switch freshPlan.mode {
        case .rawCovered(let anchor), .scan(let anchor):
            XCTAssertEqual(anchor.epoch, freshEpoch,
                           "a fresh plan uses the NEW Hub epoch, never the old anchor")
        case .hubOnly, .unavailable:
            XCTFail("the replacement source plans normally, got \(freshPlan.mode)")
        }
        XCTAssertEqual(hub.currentHistoryEpoch(sessionID: "session").generation,
                       oldEpoch.generation + 1,
                       "after the fresh plan drained the session queue, stale callbacks still caused no second bump")
    }

    private struct CodexBeforeContextTwinFixture {
        let directory: URL
        let transcriptURL: URL
        let lineCount: Int
        let predecessorIndex: Int
        let responseIndex: Int
        let itemOnlyIndex: Int
        let twinText: String
        let itemOnlyText: String
        let lineOffsets: [Int]
    }

    private func makeCodexBeforeContextTwinFixture(
        prefix: String
    ) throws -> CodexBeforeContextTwinFixture {
        func agentMessage(_ ts: String, phase: String, text: String) -> String {
            "{\"type\":\"event_msg\",\"timestamp\":\"\(ts)\",\"payload\":{\"type\":\"agent_message\",\"message\":\"\(text)\",\"phase\":\"\(phase)\"}}"
        }
        func assistantItem(_ ts: String, phase: String, text: String) -> String {
            "{\"type\":\"response_item\",\"timestamp\":\"\(ts)\",\"payload\":{\"type\":\"message\",\"role\":\"assistant\",\"phase\":\"\(phase)\",\"content\":[{\"type\":\"output_text\",\"text\":\"\(text)\"}]}}"
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexTranscriptSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let transcriptURL = directory.appendingPathComponent("rollout.jsonl", isDirectory: false)
        let lineCount = transcriptBootstrapLineLimit * 2 + 40
        let predecessorIndex = 515
        let responseIndex = predecessorIndex + 1
        let itemOnlyIndex = responseIndex + 1
        let twinText = "\(prefix)-window-floor-twin"
        let itemOnlyText = "\(prefix)-window-item-only"
        var lines = (0..<lineCount).map {
            makeCodexMessageLine(role: "assistant", content: "\(prefix)-deep-\($0)")
        }
        lines[predecessorIndex] =
            agentMessage("2026-05-15T00:08:35.000Z", phase: "commentary", text: twinText)
        lines[responseIndex] =
            assistantItem("2026-05-15T00:08:35.001Z", phase: "commentary", text: twinText)
        lines[itemOnlyIndex] =
            assistantItem("2026-05-15T00:08:35.002Z", phase: "commentary", text: itemOnlyText)
        var lineOffsets = [Int]()
        var nextLineOffset = 0
        for line in lines {
            lineOffsets.append(nextLineOffset)
            nextLineOffset += line.utf8.count + 1
        }
        try (lines.joined(separator: "\n") + "\n")
            .write(to: transcriptURL, atomically: true, encoding: .utf8)
        return CodexBeforeContextTwinFixture(
            directory: directory,
            transcriptURL: transcriptURL,
            lineCount: lineCount,
            predecessorIndex: predecessorIndex,
            responseIndex: responseIndex,
            itemOnlyIndex: itemOnlyIndex,
            twinText: twinText,
            itemOnlyText: itemOnlyText,
            lineOffsets: lineOffsets
        )
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
