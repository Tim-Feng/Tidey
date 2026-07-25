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
                       "exactly the official conversion: nonblank input_text only, joined with a single newline")
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
            ("agent-message-phase-missing", [eventMsg("{\"type\":\"agent_message\",\"message\":\"hi\"}")]),
            ("agent-message-phase-wrong-type", [eventMsg("{\"type\":\"agent_message\",\"message\":\"hi\",\"phase\":7}")]),
            ("agent-message-phase-unknown", [eventMsg("{\"type\":\"agent_message\",\"message\":\"hi\",\"phase\":\"draft\"}")]),
            ("exec-end-call-id-missing", [eventMsg("{\"type\":\"exec_command_end\",\"stdout\":\"ok\"}")]),
            ("exec-end-call-id-wrong-type", [eventMsg("{\"type\":\"exec_command_end\",\"call_id\":7,\"stdout\":\"ok\"}")]),
            ("exec-end-call-id-empty", [eventMsg("{\"type\":\"exec_command_end\",\"call_id\":\"\",\"stdout\":\"ok\"}")]),
            ("exec-end-nonstring-candidate-not-hidden", [eventMsg("{\"type\":\"exec_command_end\",\"call_id\":\"e1\",\"aggregated_output\":5,\"stdout\":\"ok\"}")]),
            ("patch-end-call-id-empty", [eventMsg("{\"type\":\"patch_apply_end\",\"call_id\":\"\",\"stdout\":\"ok\"}")]),
            ("patch-end-nonstring-candidate-not-hidden", [eventMsg("{\"type\":\"patch_apply_end\",\"call_id\":\"p1\",\"stdout\":3,\"stderr\":\"ok\"}")]),
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
             [eventMsg("{\"type\":\"exec_command_end\",\"call_id\":\"exec-dup\",\"stdout\":\"legal first\"}"),
              eventMsg("{\"type\":\"exec_command_end\",\"call_id\":\"exec-dup\",\"stdout\":7}")]),
            ("patch-nonstring-candidate-after-resolved",
             [eventMsg("{\"type\":\"patch_apply_end\",\"call_id\":\"patch-dup\",\"stderr\":\"legal first\"}"),
              eventMsg("{\"type\":\"patch_apply_end\",\"call_id\":\"patch-dup\",\"stderr\":7}")]),
            ("patch-end-call-id-missing", [eventMsg("{\"type\":\"patch_apply_end\",\"stdout\":\"ok\"}")]),
            ("patch-end-call-id-wrong-type", [eventMsg("{\"type\":\"patch_apply_end\",\"call_id\":7,\"stdout\":\"ok\"}")]),
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
            "{\"type\":\"event_msg\",\"timestamp\":\"2026-05-15T00:00:06Z\",\"payload\":{\"type\":\"exec_command_end\",\"call_id\":\"no-candidates\"}}",
            "{\"type\":\"event_msg\",\"timestamp\":\"2026-05-15T00:00:07Z\",\"payload\":{\"type\":\"exec_command_end\",\"call_id\":\"empty-candidates\",\"aggregated_output\":\"\",\"stdout\":\"\"}}",
            "{\"type\":\"event_msg\",\"timestamp\":\"2026-05-15T00:00:08Z\",\"payload\":{\"type\":\"patch_apply_end\",\"call_id\":\"empty-patch\",\"stdout\":\"\",\"stderr\":\"\"}}",
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
    // BOTH content contexts; anything else is malformed. And since the
    // official enums do not set deny_unknown_fields, extra keys on legal
    // records and blocks must be ignored, never poisoned.
    func testCodexOptionalNullDetailAndExtraKeysStayLegal() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexTranscriptSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcriptURL = directory.appendingPathComponent("rollout.jsonl", isDirectory: false)
        let lines = [
            "{\"type\":\"response_item\",\"timestamp\":\"2026-05-15T00:00:00Z\",\"payload\":{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"null-detail-msg\"},{\"type\":\"input_image\",\"detail\":null,\"image_url\":\"data:image/png;base64,AA==\"}]}}",
            "{\"type\":\"response_item\",\"timestamp\":\"2026-05-15T00:00:01Z\",\"payload\":{\"type\":\"function_call_output\",\"call_id\":\"null-detail-fco\",\"output\":[{\"type\":\"input_text\",\"text\":\"null-detail-out\"},{\"type\":\"input_image\",\"detail\":null,\"image_url\":\"data:image/png;base64,AA==\"}]}}",
            "{\"type\":\"response_item\",\"timestamp\":\"2026-05-15T00:00:02Z\",\"payload\":{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"extra-keys-msg\",\"annotations\":[],\"future_field\":1}],\"unknown_top_field\":true}}",
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
        XCTAssertTrue(events.contains { $0.text == "extra-keys-msg" },
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
            ("exec-exit-code-string", [eventMsg("{\"type\":\"exec_command_end\",\"call_id\":\"e1\",\"exit_code\":\"0\",\"stdout\":\"ok\"}")]),
            ("exec-exit-code-bool", [eventMsg("{\"type\":\"exec_command_end\",\"call_id\":\"e1\",\"exit_code\":true,\"stdout\":\"ok\"}")]),
            ("exec-status-non-string", [eventMsg("{\"type\":\"exec_command_end\",\"call_id\":\"e1\",\"status\":7,\"stdout\":\"ok\"}")]),
            ("patch-success-non-bool-number", [eventMsg("{\"type\":\"patch_apply_end\",\"call_id\":\"p1\",\"success\":1,\"stdout\":\"ok\"}")]),
            ("patch-success-non-bool-string", [eventMsg("{\"type\":\"patch_apply_end\",\"call_id\":\"p1\",\"success\":\"yes\",\"stdout\":\"ok\"}")]),
            ("patch-status-non-string", [eventMsg("{\"type\":\"patch_apply_end\",\"call_id\":\"p1\",\"status\":7,\"stdout\":\"ok\"}")]),
            ("exec-malformed-metadata-after-resolved",
             [eventMsg("{\"type\":\"exec_command_end\",\"call_id\":\"em-dup\",\"exit_code\":0,\"status\":\"completed\",\"stdout\":\"legal first\"}"),
              eventMsg("{\"type\":\"exec_command_end\",\"call_id\":\"em-dup\",\"exit_code\":\"0\",\"stdout\":\"dup\"}")]),
            ("patch-malformed-metadata-after-resolved",
             [eventMsg("{\"type\":\"patch_apply_end\",\"call_id\":\"pm-dup\",\"success\":true,\"stdout\":\"legal first\"}"),
              eventMsg("{\"type\":\"patch_apply_end\",\"call_id\":\"pm-dup\",\"success\":1,\"stdout\":\"dup\"}")]),
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
            eventMsg("{\"type\":\"exec_command_end\",\"call_id\":\"legal-exec\",\"exit_code\":0,\"status\":\"completed\",\"stdout\":\"exec-out\"}"),
            eventMsg("{\"type\":\"patch_apply_end\",\"call_id\":\"legal-patch\",\"success\":true,\"status\":\"completed\",\"stdout\":\"patch-out\"}"),
            eventMsg("{\"type\":\"exec_command_end\",\"call_id\":\"absent-meta\",\"stdout\":\"bare-out\"}"),
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
                      "absent metadata fields stay legal")
        XCTAssertTrue(session.validateHistoryEpoch(hub.currentHistoryEpoch(sessionID: "session")))
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
