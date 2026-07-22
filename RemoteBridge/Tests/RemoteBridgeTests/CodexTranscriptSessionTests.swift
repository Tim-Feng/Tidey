import XCTest
@testable import RemoteBridge

final class CodexTranscriptSessionTests: XCTestCase {
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

        let oldMaxSeq = hub.fetch(workspaceID: "workspace", sessionID: "instance-session", limit: 50)
            .events.map(\.seq).max() ?? 0
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
        // A full source-epoch reset revokes the OLD source's live events too
        // (not just its historical/backfilled ones) — an already-subscribed
        // client must not keep showing anything derived from the old thread.
        XCTAssertFalse(result.events.contains { $0.text == "old thread" },
                       "the old source's live event must be revoked by the epoch reset, got \(result.events.map { ($0.type, $0.text ?? "") })")
        let boundaryEvent = try XCTUnwrap(result.events.first { $0.type == .sessionStarted && $0.eventID.hasPrefix("source-epoch:") })
        let newEvent = try XCTUnwrap(result.events.first { $0.text == "new live thread" })
        XCTAssertGreaterThan(boundaryEvent.seq, oldMaxSeq,
                             "the new source's live boundary must rebase strictly above the old source's high-water")
        XCTAssertGreaterThan(newEvent.seq, boundaryEvent.seq,
                             "the new source's own events must land strictly above its own boundary marker")
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

    // Lock-protected collector for events delivered from `AgentEventHub`'s
    // OWN background `deliveryQueue` — see ClaudeTranscriptSessionTests'
    // equivalent helper for the full rationale.
    private final class LockedEventCollector {
        private let lock = NSLock()
        private var storage = [AgentEvent]()
        func append(_ event: AgentEvent) {
            lock.lock()
            storage.append(event)
            lock.unlock()
        }
        func snapshot() -> [AgentEvent] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
        func removeAll() {
            lock.lock()
            storage.removeAll()
            lock.unlock()
        }
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

    private func makeCodexAgentMessageLine(text: String,
                                           phase: String = "final_answer",
                                           timestamp: String = "2026-05-15T00:02:00Z") -> String {
        let object: [String: Any] = [
            "type": "event_msg",
            "timestamp": timestamp,
            "payload": ["type": "agent_message", "message": text, "phase": phase],
        ]
        return String(data: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), encoding: .utf8)!
    }

    private func makeCodexFunctionCallLine(callID: String, name: String, arguments: String, timestamp: String) -> String {
        let object: [String: Any] = [
            "type": "response_item",
            "timestamp": timestamp,
            "payload": ["type": "function_call", "call_id": callID, "name": name, "arguments": arguments],
        ]
        return String(data: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), encoding: .utf8)!
    }

    private func makeCodexCustomToolCallLine(callID: String, name: String, input: [String: Any], timestamp: String) -> String {
        let object: [String: Any] = [
            "type": "response_item",
            "timestamp": timestamp,
            "payload": ["type": "custom_tool_call", "call_id": callID, "name": name, "input": input],
        ]
        return String(data: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), encoding: .utf8)!
    }

    // The real rollout's `custom_tool_call.input` is a String (JavaScript
    // source), not a JSON object.
    private func makeCodexCustomToolCallStringInputLine(callID: String, name: String, input: String, timestamp: String) -> String {
        let object: [String: Any] = [
            "type": "response_item",
            "timestamp": timestamp,
            "payload": ["type": "custom_tool_call", "call_id": callID, "name": name, "input": input],
        ]
        return String(data: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), encoding: .utf8)!
    }

    private func makeCodexCustomToolCallOutputArrayLine(callID: String, texts: [String], timestamp: String) -> String {
        let object: [String: Any] = [
            "type": "response_item",
            "timestamp": timestamp,
            "payload": [
                "type": "custom_tool_call_output",
                "call_id": callID,
                "output": texts.map { ["type": "input_text", "text": $0] },
            ],
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

        let liveDeliveredCollector = LockedEventCollector()
        let (subscriptionID, _) = hub.subscribe(workspaceID: "workspace", sessionID: "session") { envelope in
            liveDeliveredCollector.append(envelope.event)
        }
        defer { hub.unsubscribe(subscriptionID) }
        let sidebarBaseline = sender.commands().count

        XCTAssertTrue(session.backfill(beforeSeq: boundary, limit: 600))
        XCTAssertTrue(waitUntil {
            hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 5000, beforeSeq: boundary).events.isEmpty == false
        })
        hub.drainDeliveriesForTesting()
        let liveDelivered = liveDeliveredCollector.snapshot().map(\.eventID)
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
            // Page anchors advance on file-backed events only — the
            // synthetic session-start (now minted from the Hub's own
            // reserved sequence, not a fixed seq-0 sentinel) is not itself
            // a transcript line.
            cursor = history.filter { $0.type != .sessionStarted }.map(\.seq).min() ?? cursor
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
            guard let next = page.events.filter { $0.type != .sessionStarted }.map(\.seq).min(), next < cursorA else {
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
        var cursorB = pageB.events.filter { $0.type != .sessionStarted }.map(\.seq).min() ?? boundary
        for _ in 0..<30 {
            let page = serverFetch(limit: 3, beforeSeq: cursorB)
            let texts = page.events.compactMap(\.text)
            guard texts.isEmpty == false,
                  let next = page.events.filter { $0.type != .sessionStarted }.map(\.seq).min(), next < cursorB else {
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
            guard let next = page.filter { $0.type != .sessionStarted }.map(\.seq).min(), next < cursor else {
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
            let nextCursor = page.filter { $0.type != .sessionStarted }.map(\.seq).min() ?? cursor
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

    // MARK: - Working-indicator lifecycle translation

    // Replays the COMPLETE real rollout order Tim reported live:
    // task_started -> BUSY-1 -> commentary -> custom_tool_call (array output)
    // -> BUSY-2 (same turn, no new task_started) -> commentary -> a regular
    // function_call/output pair -> final_answer -> task_complete. At every
    // checkpoint before the terminal, the emitted ordering must leave the
    // client's Working indicator anchored: every clearing assistant/tool
    // event is immediately followed by a continuation `.thinking` for the
    // SAME turn; only task_complete ends it.
    func testCompleteLiveSequenceKeepsWorkingUntilTaskComplete() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexTranscriptSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcriptURL = directory.appendingPathComponent("rollout-session.jsonl", isDirectory: false)

        let lines = [
            makeCodexTaskLine(type: "task_started", turnID: "turn-A"),
            makeCodexMessageLine(role: "user", content: "BUSY-1"),
            makeCodexAgentMessageLine(text: "thinking about it", phase: "commentary", timestamp: "2026-05-15T00:01:00Z"),
            makeCodexCustomToolCallStringInputLine(callID: "call_1", name: "exec_js",
                                                   input: "console.log(\"ls\")", timestamp: "2026-05-15T00:01:30Z"),
            makeCodexCustomToolCallOutputArrayLine(callID: "call_1", texts: ["file1", "file2"], timestamp: "2026-05-15T00:01:45Z"),
            makeCodexMessageLine(role: "user", content: "BUSY-2"),
            makeCodexAgentMessageLine(text: "still working", phase: "commentary", timestamp: "2026-05-15T00:02:15Z"),
            makeCodexFunctionCallLine(callID: "call_2", name: "read_file", arguments: "{\"path\":\"foo\"}",
                                      timestamp: "2026-05-15T00:02:30Z"),
            makeCodexFunctionCallOutputLine(callID: "call_2", output: "contents of foo"),
            makeCodexAgentMessageLine(text: "done", phase: "final_answer", timestamp: "2026-05-15T00:03:00Z"),
            makeCodexTaskLine(type: "task_complete", turnID: "turn-A", message: "done"),
        ].joined(separator: "\n") + "\n"
        try lines.write(to: transcriptURL, atomically: true, encoding: .utf8)

        let hub = AgentEventHub()
        let session = CodexTranscriptSession(record: makeRecord(transcriptPath: transcriptURL.path),
                                             fileManager: .default,
                                             hub: hub)
        session.start()
        defer { session.stop() }

        XCTAssertTrue(waitUntil {
            hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 5000).events.contains {
                $0.metadata?["reason"] == "turn_terminal"
            }
        })

        let events = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 5000).events
            .sorted { $0.seq < $1.seq }
        let kinds = events.map(\.type)

        XCTAssertEqual(kinds, [
            .sessionStarted,
            .thinking,        // task_started anchors Working for turn-A
            .userMessage,      // BUSY-1
            .assistantMessage, // commentary — clears Working...
            .thinking,         // ...continuation immediately re-anchors it
            .toolCall,         // custom_tool_call — clears Working...
            .thinking,         // ...continuation re-anchors it
            .toolResult,       // custom_tool_call_output — restores via the pre-existing fallback, no continuation needed
            .userMessage,      // BUSY-2 — same turn, no new task_started
            .assistantMessage, // commentary again — clears...
            .thinking,         // ...continuation
            .toolCall,         // regular function_call — clears...
            .thinking,         // ...continuation
            .toolResult,       // function_call_output
            .assistantFinal,   // final_answer — clears...
            .thinking,         // ...continuation: the turn is NOT authoritatively done yet
            .assistantFinal,   // task_complete's terminal: THIS is what finally ends Working
        ], "got kinds=\(kinds)")

        let terminal = try XCTUnwrap(events.last)
        XCTAssertEqual(terminal.metadata?["reason"], "turn_terminal")
        XCTAssertNil(terminal.text, "the terminal event carries no text — it is a pure lifecycle signal")

        // No duplicate tool call/result rows.
        let toolCallIDs = events.filter { $0.type == .toolCall }.map(\.toolCallID)
        let toolResultIDs = events.filter { $0.type == .toolResult }.map(\.toolCallID)
        XCTAssertEqual(toolCallIDs, ["call_1", "call_2"])
        XCTAssertEqual(toolResultIDs, ["call_1", "call_2"])

        // custom_tool_call.input is a String in the real rollout (JavaScript
        // source) — it must be preserved verbatim, not re-serialized.
        let call1Call = try XCTUnwrap(events.first { $0.type == .toolCall && $0.toolCallID == "call_1" })
        XCTAssertEqual(call1Call.input, "console.log(\"ls\")")

        // custom_tool_call_output.output is an array of MULTIPLE input_text
        // blocks — they must all be extracted and joined, not just the first.
        let call1Result = try XCTUnwrap(events.first { $0.type == .toolResult && $0.toolCallID == "call_1" })
        XCTAssertEqual(call1Result.output, "file1\n\nfile2")
    }

    // Secondary coverage: custom_tool_call.input as a JSON object is ALSO
    // accepted (some tool calls may still use structured input) — kept as a
    // separate compact test since the primary fixture above now matches the
    // real rollout's String-input shape.
    func testCustomToolCallObjectInputIsStillAccepted() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexTranscriptSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcriptURL = directory.appendingPathComponent("rollout-session.jsonl", isDirectory: false)

        let lines = [
            makeCodexCustomToolCallLine(callID: "call_obj", name: "exec_command",
                                        input: ["command": ["ls"]], timestamp: "2026-05-15T00:01:00Z"),
        ].joined(separator: "\n") + "\n"
        try lines.write(to: transcriptURL, atomically: true, encoding: .utf8)

        let hub = AgentEventHub()
        let session = CodexTranscriptSession(record: makeRecord(transcriptPath: transcriptURL.path),
                                             fileManager: .default,
                                             hub: hub)
        session.start()
        defer { session.stop() }

        XCTAssertTrue(waitUntil {
            hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 50).events.contains { $0.type == .toolCall }
        })
        let call = try XCTUnwrap(hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 50).events.first { $0.type == .toolCall })
        XCTAssertEqual(call.input, "{\"command\":[\"ls\"]}")
    }

    // MARK: - Round 3 item 4: canonical source identity

    // Two non-standardized spellings of the EXACT SAME file (./  and  ../dir/)
    // must never be treated as a source switch — raw string comparison would
    // see two different paths; canonicalization must see one.
    func testEquivalentPathSpellingsDoNotResetSource() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexTranscriptSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcriptURL = directory.appendingPathComponent("rollout-session.jsonl", isDirectory: false)
        try (makeCodexTaskLine(type: "task_started", turnID: "turn-stable") + "\n")
            .write(to: transcriptURL, atomically: true, encoding: .utf8)

        let hub = AgentEventHub()
        let session = CodexTranscriptSession(record: makeRecord(transcriptPath: transcriptURL.path),
                                             fileManager: .default,
                                             hub: hub)
        session.start()
        defer { session.stop() }

        XCTAssertTrue(waitUntil {
            hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 50).events.contains { $0.type == .thinking }
        })
        let before = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 50).events.map(\.eventID)

        let directoryPath = transcriptURL.deletingLastPathComponent().path
        let directoryName = transcriptURL.deletingLastPathComponent().lastPathComponent
        let dotSlashSpelling = directoryPath + "/./" + transcriptURL.lastPathComponent
        session.update(record: makeRecord(transcriptPath: dotSlashSpelling))
        let dotDotSpelling = directoryPath + "/../" + directoryName + "/" + transcriptURL.lastPathComponent
        session.update(record: makeRecord(transcriptPath: dotDotSpelling))
        // Deterministic barrier.
        _ = session.backfill(beforeSeq: 1, limit: 1)

        let after = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 50).events.map(\.eventID)
        XCTAssertEqual(after, before, "equivalent path spellings of the SAME file must never reset the source epoch, got \(after) vs \(before)")
        XCTAssertFalse(after.contains { $0.hasPrefix("source-epoch:") })
    }

    // Adding thread metadata (threadID/resumeThreadID) while the EXPLICIT
    // transcriptPath stays the same and still resolves to the same file must
    // never reset — resolveTranscriptURL() short-circuits on the explicit
    // path before any thread-based fallback matching even runs.
    func testThreadMetadataOnlyAdditionDoesNotResetSource() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexTranscriptSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcriptURL = directory.appendingPathComponent("rollout-session.jsonl", isDirectory: false)
        try (makeCodexTaskLine(type: "task_started", turnID: "turn-stable") + "\n")
            .write(to: transcriptURL, atomically: true, encoding: .utf8)

        let hub = AgentEventHub()
        let session = CodexTranscriptSession(record: makeRecord(transcriptPath: transcriptURL.path),
                                             fileManager: .default,
                                             hub: hub)
        session.start()
        defer { session.stop() }

        XCTAssertTrue(waitUntil {
            hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 50).events.contains { $0.type == .thinking }
        })
        let before = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 50).events.map(\.eventID)

        session.update(record: makeRecord(transcriptPath: transcriptURL.path,
                                          threadID: "newly-known-thread-id",
                                          resumeThreadID: "newly-known-resume-id"))
        _ = session.backfill(beforeSeq: 1, limit: 1)

        let after = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 50).events.map(\.eventID)
        XCTAssertEqual(after, before, "adding thread metadata that still resolves to the SAME file must never reset the source epoch")
        XCTAssertFalse(after.contains { $0.hasPrefix("source-epoch:") })
    }

    // Round 4/5 P0: a whitespace-only transcriptPath must be treated the
    // SAME as nil/absent (never an explicit path) in EVERY place that
    // decides "is this a real transcript identity" — detectsSourceSwitch,
    // resolveTranscriptURL, and performUpdate's own check — via one shared
    // trimmed explicitTranscriptPath helper. Canonicalizing "   " resolves
    // against the CURRENT WORKING DIRECTORY (never a meaningful transcript
    // identity), which would otherwise almost always differ from the
    // currently-tailed file and wrongly trigger a stop/drain + Hub epoch
    // reset. With no threadID/resumeThreadID present either, this must
    // fall through to "no switch at all."
    func testWhitespaceOnlyTranscriptPathIsNotASourceSwitch() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexTranscriptSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcriptURL = directory.appendingPathComponent("rollout-session.jsonl", isDirectory: false)
        try (makeCodexTaskLine(type: "task_started", turnID: "turn-stable") + "\n")
            .write(to: transcriptURL, atomically: true, encoding: .utf8)

        let hub = AgentEventHub()
        let session = CodexTranscriptSession(record: makeRecord(transcriptPath: transcriptURL.path),
                                             fileManager: .default,
                                             hub: hub)
        session.start()
        defer { session.stop() }

        XCTAssertTrue(waitUntil {
            hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 50).events.contains { $0.type == .thinking }
        })
        let before = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 50).events.map(\.eventID)

        var beforeStopHookFired = false
        session.beforeOldTailerStopForTesting = { beforeStopHookFired = true }
        session.update(record: makeRecord(transcriptPath: "   "))
        _ = session.backfill(beforeSeq: 1, limit: 1)
        XCTAssertFalse(beforeStopHookFired, "a whitespace-only transcriptPath must never be treated as a source switch")
        session.beforeOldTailerStopForTesting = nil

        let afterWhitespaceUpdate = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 50).events.map(\.eventID)
        XCTAssertEqual(afterWhitespaceUpdate, before, "a whitespace-only transcriptPath update must not reset the Hub source epoch")

        // The OLD tailer must still be the live one: a fresh append is
        // still picked up normally, proving it was never stopped/replaced.
        let appendHandle = try FileHandle(forWritingTo: transcriptURL)
        appendHandle.seekToEndOfFile()
        appendHandle.write((makeCodexTaskLine(type: "task_complete", turnID: "turn-stable", message: "still-live") + "\n").data(using: .utf8)!)
        try appendHandle.close()
        XCTAssertTrue(waitUntil {
            hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 50)
                .events.contains { $0.metadata?["reason"] == "turn_terminal" }
        }, "the OLD tailer must still be receiving live appends after a whitespace-only transcriptPath update")

        let after = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 50).events.map(\.eventID)
        XCTAssertTrue(after.contains { $0.hasPrefix("turn-terminal:") },
                     "the new live append must be present, got \(after)")
        XCTAssertTrue(before.allSatisfy(after.contains),
                      "a whitespace-only transcriptPath update must not reset the source epoch, got \(after) vs before \(before)")
    }

    // A genuinely DIFFERENT canonical file must reset exactly once (not
    // zero, not twice) even when the update also touches thread metadata.
    func testDifferentCanonicalFileResetsExactlyOnce() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexTranscriptSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcriptA = directory.appendingPathComponent("rollout-a.jsonl", isDirectory: false)
        let transcriptB = directory.appendingPathComponent("rollout-b.jsonl", isDirectory: false)
        try (makeCodexMessageLine(role: "assistant", content: "a") + "\n").write(to: transcriptA, atomically: true, encoding: .utf8)
        try (makeCodexMessageLine(role: "assistant", content: "b") + "\n").write(to: transcriptB, atomically: true, encoding: .utf8)

        let hub = AgentEventHub()
        let session = CodexTranscriptSession(record: makeRecord(transcriptPath: transcriptA.path),
                                             fileManager: .default,
                                             hub: hub)
        session.start()
        defer { session.stop() }
        XCTAssertTrue(waitUntil {
            hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 50).events.contains { $0.text == "a" }
        })

        session.update(record: makeRecord(transcriptPath: transcriptB.path, threadID: "t", resumeThreadID: "t"))
        XCTAssertTrue(waitUntil {
            hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 50).events.contains { $0.text == "b" }
        })
        // A second update carrying the SAME (now-current) canonical path must
        // NOT reset again.
        session.update(record: makeRecord(transcriptPath: transcriptB.path, threadID: "t2", resumeThreadID: "t2"))
        _ = session.backfill(beforeSeq: 1, limit: 1)

        let boundaries = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 50).events
            .filter { $0.eventID.hasPrefix("source-epoch:") }
        XCTAssertEqual(boundaries.count, 1, "exactly one reset for the one genuine file switch, got \(boundaries.map(\.eventID))")
    }

    // MARK: - Round 3 Blocker 1: full source-epoch reset

    // A minimal reproduction of the iOS client's Working fold (reducerIsThinking),
    // over the events as actually LIVE-DELIVERED to a subscriber, in order.
    private static func equivalentWorkingStates(for events: [AgentEvent]) -> [Bool] {
        var isThinking = false
        var states = [Bool]()
        for event in events {
            switch event.type {
            case .thinking:
                isThinking = true
            case .assistantMessage, .assistantFinal, .interactivePrompt, .interactivePromptResolved,
                 .toolCall, .sessionStarted, .sessionEnded:
                isThinking = false
            default:
                break
            }
            states.append(isThinking)
        }
        return states
    }

    // A is mid an active, unterminated turn (Working on); the registry then
    // points at a BLANK/idle B (zero transcript lines). A store-only reset
    // is not enough — an already-subscribed client's local reducer would
    // keep showing Working with no new clearing event ever arriving from a
    // blank B. The epoch reset must LIVE-DELIVER a boundary that turns
    // Working off immediately, even though B never produces a single event.
    // Round 7G P0 (reviewer-caught false positive): the PREVIOUS form of
    // this test subscribed only AFTER waiting for A's `.thinking` to
    // already be live-stored — the subscriber's `delivered` array then
    // NEVER contained A's `.thinking` at all, so `equivalentWorkingStates`
    // never observed a genuine true→false transition; it only ever saw an
    // implicit-false-baseline array ending in `false`, which would pass
    // even if the boundary fix were completely absent (as long as SOME
    // sessionStarted-shaped event merely showed up). This version
    // subscribes BEFORE `session.start()` so the collector genuinely
    // captures A's live `.thinking` anchor, proves the equivalent state is
    // true, THEN proves the switch flips it to false — a real
    // true→false transition, not a static ending value.
    func testRegistrySwitchToBlankSourceEndsWorkingImmediately() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexTranscriptSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcriptA = directory.appendingPathComponent("rollout-a.jsonl", isDirectory: false)
        let transcriptB = directory.appendingPathComponent("rollout-b.jsonl", isDirectory: false)
        try (makeCodexTaskLine(type: "task_started", turnID: "turn-A") + "\n")
            .write(to: transcriptA, atomically: true, encoding: .utf8)
        try "".write(to: transcriptB, atomically: true, encoding: .utf8)

        let hub = AgentEventHub()
        let session = CodexTranscriptSession(record: makeRecord(transcriptPath: transcriptA.path, sessionID: "instance-session"),
                                             fileManager: .default,
                                             hub: hub)
        defer { session.stop() }

        let collector = LockedEventCollector()
        let (subscriptionID, _) = hub.subscribe(workspaceID: "workspace", sessionID: "instance-session") { envelope in
            collector.append(envelope.event)
        }
        defer { hub.unsubscribe(subscriptionID) }

        // Subscribed BEFORE start(): A's own `.thinking` anchor must be
        // genuinely LIVE-DELIVERED to this collector, not merely stored.
        session.start()
        XCTAssertTrue(waitUntil {
            hub.drainDeliveriesForTesting()
            return collector.snapshot().contains { $0.type == .thinking }
        })
        hub.drainDeliveriesForTesting()

        let statesAfterA = Self.equivalentWorkingStates(for: collector.snapshot())
        XCTAssertEqual(statesAfterA.last, true,
                       "A's live thinking anchor must actually flip the equivalent Working state to true — this is the PRE-boundary baseline the true→false transition below must move away from, got states=\(statesAfterA) events=\(collector.snapshot().map { ($0.type, $0.eventID) })")

        let aMaxSeq = hub.fetch(workspaceID: "workspace", sessionID: "instance-session", limit: 50).events.map(\.seq).max() ?? 0

        session.update(record: makeRecord(transcriptPath: transcriptB.path, sessionID: "instance-session"))

        XCTAssertTrue(waitUntil {
            hub.drainDeliveriesForTesting()
            return collector.snapshot().contains { $0.eventID.hasPrefix("source-epoch:") }
        })
        hub.drainDeliveriesForTesting()

        let states = Self.equivalentWorkingStates(for: collector.snapshot())
        XCTAssertEqual(states.last, false,
                       "the equivalent Working state must transition from the earlier-proven true to false immediately after the source-epoch boundary, even with zero B transcript events, got states=\(states) events=\(collector.snapshot().map { ($0.type, $0.eventID) })")

        let boundaryEvent = try XCTUnwrap(collector.snapshot().first { $0.eventID.hasPrefix("source-epoch:") })
        XCTAssertGreaterThan(boundaryEvent.seq, aMaxSeq,
                             "the boundary must rebase strictly above A's seq high-water")

        let after = hub.fetch(workspaceID: "workspace", sessionID: "instance-session", limit: 5000).events
        XCTAssertFalse(after.contains { $0.type == .thinking },
                       "no trace of A's Working anchor may remain visible after the switch, got \(after.map { ($0.type, $0.text ?? "") })")
    }

    // Round 7G TOCTOU addendum: `start()`'s boundary/start seq is RESERVED
    // then PUBLISHED — a competing producer racing between those two calls
    // could force publish()'s own rebase-on-collision to fire. Mirrors
    // ClaudeTranscriptSessionTests' equivalent test exactly (see there for
    // why: (a) the gap must be a large, deliberately arbitrary multiple of
    // transcriptLineSequenceMultiplier, since it's a BYTE-offset stride,
    // not a line-index stride; (b) externally-observed seqs are NOT
    // reliable proof by themselves — the Hub's own rebase-on-collision
    // silently launders even a wrong local base into a still-monotonic
    // sequence for anything that flows back through `hub.publish`, so
    // `transcriptSequenceBaseForTesting` is asserted directly).
    func testCodexStartCompetingProducerRaceSeedsBaseFromActualPublishedSeq() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexTranscriptSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcriptURL = directory.appendingPathComponent("rollout-session.jsonl", isDirectory: false)

        let totalLines = transcriptBootstrapLineLimit + 5
        var lines = [String]()
        for index in 0..<totalLines {
            lines.append(makeCodexMessageLine(role: "assistant", content: "line-\(index)"))
        }
        try (lines.joined(separator: "\n") + "\n").write(to: transcriptURL, atomically: true, encoding: .utf8)

        let hub = AgentEventHub()
        let session = CodexTranscriptSession(record: makeRecord(transcriptPath: transcriptURL.path),
                                             fileManager: .default,
                                             hub: hub)
        defer { session.stop() }

        let collector = LockedEventCollector()
        let (subscriptionID, _) = hub.subscribe(workspaceID: "workspace", sessionID: "session") { envelope in
            collector.append(envelope.event)
        }
        defer { hub.unsubscribe(subscriptionID) }

        session.setAfterBoundaryReservationBeforePublishHookForTesting {
            let reserved = hub.nextSyntheticSeq(sessionID: "session")
            let competingSeq = reserved + transcriptLineSequenceMultiplier * 10_000
            hub.publish(AgentEvent(eventID: "competing-native-start",
                                   seq: competingSeq,
                                   vendor: "codex",
                                   workspaceID: "workspace",
                                   sessionID: "session",
                                   timestamp: "2026-01-01T00:00:00Z",
                                   type: .assistantMessage,
                                   role: "assistant",
                                   text: "competing",
                                   name: nil,
                                   input: nil,
                                   output: nil,
                                   toolCallID: nil,
                                   metadata: nil))
        }

        session.start()

        XCTAssertTrue(waitUntil {
            hub.drainDeliveriesForTesting()
            return collector.snapshot().contains { $0.type == .sessionStarted }
        })

        let delivered = collector.snapshot()
        let boundaryEvent = try XCTUnwrap(delivered.first { $0.type == .sessionStarted && $0.eventID == "session-start:session" })
        let competingEvent = try XCTUnwrap(delivered.first { $0.eventID == "competing-native-start" })
        XCTAssertGreaterThan(boundaryEvent.seq, competingEvent.seq,
                            "the boundary marker's ACTUAL stored seq must land above the competing producer it raced against")

        let fetchedBoundary = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 5000)
            .events.first(where: { $0.type == .sessionStarted && $0.eventID == "session-start:session" })
        XCTAssertEqual(fetchedBoundary?.seq, boundaryEvent.seq,
                       "subscriber envelope and Hub fetch must agree on the SAME actual stored seq")

        XCTAssertEqual(session.transcriptSequenceBaseForTesting, boundaryEvent.seq,
                       "transcriptSequenceBase must be seeded from the ACTUAL published boundary seq, never the stale pre-publish reservation")

        XCTAssertTrue(waitUntil {
            hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 5)
                .events.contains { $0.text == "line-\(totalLines - 1)" }
        })

        let contentEvents = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 5000)
            .events.filter { ($0.text ?? "").hasPrefix("line-") }
        let contentSeqs = contentEvents.map(\.seq)
        XCTAssertEqual(Set(contentSeqs).count, contentSeqs.count, "every content event must own a distinct seq")
        XCTAssertEqual(contentSeqs.sorted(), contentSeqs, "content events must already be strictly seq-ordered")
        let minContentSeq = try XCTUnwrap(contentSeqs.min())
        XCTAssertGreaterThan(minContentSeq, boundaryEvent.seq,
                            "EVERY new-source content event must land strictly above the ACTUAL boundary seq")

        // Exact earliest live line: totalLines (505) minus the bootstrap
        // tail window (500) = "line-5"; "line-4" is the exact
        // nearest-preceding historical line.
        let firstLiveFileEvent = try XCTUnwrap(contentEvents.first { $0.text == "line-5" }?.seq)
        XCTAssertTrue(session.backfill(beforeSeq: firstLiveFileEvent, limit: 600))
        XCTAssertTrue(waitUntil {
            hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 5000, beforeSeq: firstLiveFileEvent)
                .events.contains { $0.text == "line-4" }
        }, "backfill after a competing-producer race must resolve to the EXACT nearest-preceding line using the ACTUAL boundary-derived sequence base")
        let historicalPage = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 5000, beforeSeq: firstLiveFileEvent)
        XCTAssertTrue(historicalPage.events.allSatisfy { $0.seq < firstLiveFileEvent })
        XCTAssertFalse(historicalPage.events.contains { $0.text == "line-5" },
                       "the already-live line-5 must not also appear as historical")
    }

    // Round 7G TOCTOU addendum: the SAME race, but for beginNewSourceEpoch
    // (a source-identity SWITCH via publishSynthetic, not the initial
    // start) — both call sites share the reserve→publish pattern.
    func testCodexSourceSwitchCompetingProducerRaceSeedsBaseFromActualPublishedSeq() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexTranscriptSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcriptA = directory.appendingPathComponent("rollout-a.jsonl", isDirectory: false)
        try (makeCodexTaskLine(type: "task_started", turnID: "turn-a") + "\n")
            .write(to: transcriptA, atomically: true, encoding: .utf8)

        let hub = AgentEventHub()
        let session = CodexTranscriptSession(record: makeRecord(transcriptPath: transcriptA.path),
                                             fileManager: .default,
                                             hub: hub)
        session.start()
        defer { session.stop() }

        XCTAssertTrue(waitUntil {
            hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 50).events.contains { $0.type == .thinking }
        })

        let collector = LockedEventCollector()
        let (subscriptionID, _) = hub.subscribe(workspaceID: "workspace", sessionID: "session") { envelope in
            collector.append(envelope.event)
        }
        defer { hub.unsubscribe(subscriptionID) }

        session.setAfterBoundaryReservationBeforePublishHookForTesting {
            let reserved = hub.nextSyntheticSeq(sessionID: "session")
            let competingSeq = reserved + transcriptLineSequenceMultiplier * 10_000
            hub.publish(AgentEvent(eventID: "competing-native-switch",
                                   seq: competingSeq,
                                   vendor: "codex",
                                   workspaceID: "workspace",
                                   sessionID: "session",
                                   timestamp: "2026-01-01T00:00:00Z",
                                   type: .assistantMessage,
                                   role: "assistant",
                                   text: "competing",
                                   name: nil,
                                   input: nil,
                                   output: nil,
                                   toolCallID: nil,
                                   metadata: nil))
        }

        let totalLines = transcriptBootstrapLineLimit + 5
        var newLines = [String]()
        for index in 0..<totalLines {
            newLines.append(makeCodexMessageLine(role: "assistant", content: "new-line-\(index)"))
        }
        let newURL = directory.appendingPathComponent("rollout-b.jsonl", isDirectory: false)
        try (newLines.joined(separator: "\n") + "\n").write(to: newURL, atomically: true, encoding: .utf8)

        session.update(record: makeRecord(transcriptPath: newURL.path))

        XCTAssertTrue(waitUntil {
            hub.drainDeliveriesForTesting()
            return collector.snapshot().contains { $0.eventID.hasPrefix("source-epoch:") }
        })

        let delivered = collector.snapshot()
        let boundaryEvent = try XCTUnwrap(delivered.first { $0.eventID.hasPrefix("source-epoch:") })
        let competingEvent = try XCTUnwrap(delivered.first { $0.eventID == "competing-native-switch" })
        XCTAssertGreaterThan(boundaryEvent.seq, competingEvent.seq,
                            "the switch boundary's ACTUAL stored seq must land above the competing producer it raced against")

        let fetchedBoundary = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 5000)
            .events.first(where: { $0.eventID.hasPrefix("source-epoch:") })
        XCTAssertEqual(fetchedBoundary?.seq, boundaryEvent.seq,
                       "subscriber envelope and Hub fetch must agree on the SAME actual stored seq")

        XCTAssertEqual(session.transcriptSequenceBaseForTesting, boundaryEvent.seq,
                       "transcriptSequenceBase must be seeded from the ACTUAL published switch-boundary seq, never the stale pre-publish reservation")

        XCTAssertTrue(waitUntil {
            hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 5)
                .events.contains { $0.text == "new-line-\(totalLines - 1)" }
        })

        let contentEvents = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 5000)
            .events.filter { ($0.text ?? "").hasPrefix("new-line-") }
        let contentSeqs = contentEvents.map(\.seq)
        XCTAssertEqual(Set(contentSeqs).count, contentSeqs.count, "every content event must own a distinct seq")
        XCTAssertEqual(contentSeqs.sorted(), contentSeqs, "content events must already be strictly seq-ordered")
        let minContentSeq = try XCTUnwrap(contentSeqs.min())
        XCTAssertGreaterThan(minContentSeq, boundaryEvent.seq,
                            "EVERY new-source content event must land strictly above the ACTUAL boundary seq")

        let firstLiveFileEvent = try XCTUnwrap(contentEvents.first { $0.text == "new-line-5" }?.seq)
        XCTAssertTrue(session.backfill(beforeSeq: firstLiveFileEvent, limit: 600))
        XCTAssertTrue(waitUntil {
            hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 5000, beforeSeq: firstLiveFileEvent)
                .events.contains { $0.text == "new-line-4" }
        }, "backfill after a competing-producer race must resolve to the EXACT nearest-preceding line using the ACTUAL boundary-derived sequence base")
        let historicalPage = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 5000, beforeSeq: firstLiveFileEvent)
        XCTAssertTrue(historicalPage.events.allSatisfy { $0.seq < firstLiveFileEvent })
        XCTAssertFalse(historicalPage.events.contains { $0.text == "new-line-5" },
                       "the already-live new-line-5 must not also appear as historical")
    }

    // Round 7G P0 (independent reviewer): an EXPLICIT B that does not yet
    // exist on disk must be EXCLUSIVE authority — resolveTranscriptURL must
    // return nil and NEVER fall back to the process-tree/directory scan
    // (which, for a plain CLI record with no authoritative threadID, could
    // silently re-match and reattach the OLD, already-switched-away-from
    // source A). The resolver's own periodic retry timer must auto-attach
    // B once it genuinely appears, with NO further update()/backfill()
    // call — mirrors ClaudeTranscriptSession's already-fixed contract.
    // Uses `afterResolveAttemptForTesting` to deterministically observe
    // genuine resolve-attempt ticks (the REAL production timer still
    // drives them) instead of a blind fixed-duration sleep.
    func testDelayedExplicitBNeverFallsBackToAAndResolverAutoAttachesOnceBAppears() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexTranscriptSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        // A's own filename embeds its sessionID — the ordinary shape of a
        // real rollout file — so a reintroduced fallback bug would find it
        // AGAIN via the directory-enumeration fallback's identity match
        // (sessionID, since this plain CLI record carries no authoritative
        // threadID at all): "fallback identity 還匹配 A" from the reviewer's
        // reproduction. `sessionsDirectoryOverrideForTesting` points the
        // fallback's directory scan at THIS test directory so that path is
        // genuinely reachable (not merely bypassed by an unrelated real
        // ~/.codex/sessions).
        let transcriptA = directory.appendingPathComponent("rollout-instance-session-a.jsonl", isDirectory: false)
        let transcriptB = directory.appendingPathComponent("rollout-instance-session-b.jsonl", isDirectory: false)
        try (makeCodexTaskLine(type: "task_started", turnID: "turn-A") + "\n")
            .write(to: transcriptA, atomically: true, encoding: .utf8)
        // B is named in the record but does NOT exist on disk yet.

        let hub = AgentEventHub()
        let session = CodexTranscriptSession(record: makeRecord(transcriptPath: transcriptA.path, sessionID: "instance-session"),
                                             fileManager: .default,
                                             hub: hub,
                                             sessionsDirectoryOverrideForTesting: directory)
        session.start()
        defer { session.stop() }

        XCTAssertTrue(waitUntil {
            hub.fetch(workspaceID: "workspace", sessionID: "instance-session", limit: 50).events.contains { $0.type == .thinking }
        })
        let aMaxSeq = hub.fetch(workspaceID: "workspace", sessionID: "instance-session", limit: 50).events.map(\.seq).max() ?? 0

        let collector = LockedEventCollector()
        let (subscriptionID, _) = hub.subscribe(workspaceID: "workspace", sessionID: "instance-session") { envelope in
            collector.append(envelope.event)
        }
        defer { hub.unsubscribe(subscriptionID) }

        session.update(record: makeRecord(transcriptPath: transcriptB.path, sessionID: "instance-session"))

        XCTAssertTrue(waitUntil {
            hub.drainDeliveriesForTesting()
            return collector.snapshot().contains { $0.eventID.hasPrefix("source-epoch:") }
        })
        let boundaryEvent = try XCTUnwrap(collector.snapshot().first { $0.eventID.hasPrefix("source-epoch:") })
        XCTAssertGreaterThan(boundaryEvent.seq, aMaxSeq, "the boundary must rebase strictly above A's seq high-water")
        collector.removeAll()

        // A late append to the OLD (revoked, tailer-stopped) file must
        // never enter the Hub — proving the resolver did NOT fall back and
        // reattach A while B is merely missing.
        let handleA = try FileHandle(forWritingTo: transcriptA)
        handleA.seekToEndOfFile()
        handleA.write((makeCodexTaskLine(type: "task_started", turnID: "turn-A-late") + "\n").data(using: .utf8)!)
        try handleA.close()

        // Deterministically wait for several REAL resolver ticks (the
        // production 1s timer still drives them) using the test hook —
        // never a blind fixed-duration sleep as the synchronization
        // mechanism itself.
        let ticksExpectation = XCTestExpectation(description: "resolver ticks while B is missing")
        ticksExpectation.expectedFulfillmentCount = 3
        session.setAfterResolveAttemptHookForTesting { ticksExpectation.fulfill() }
        wait(for: [ticksExpectation], timeout: 5)
        session.setAfterResolveAttemptHookForTesting(nil)

        hub.drainDeliveriesForTesting()
        XCTAssertFalse(collector.snapshot().contains { $0.type == .thinking },
                       "resolveTranscriptURL must never fall back to A while B is merely missing — no reattachment/injection from A")
        // "turn-A-late" is a METADATA turn_id, not the eventID (a
        // task_started line publishes as eventID "thinking:<session>:<seq>")
        // — `eventID.contains(...)` would be vacuously true/false regardless
        // of whether A's late append actually leaked through.
        XCTAssertFalse(hub.fetch(workspaceID: "workspace", sessionID: "instance-session", limit: 5000)
            .events.contains { $0.type == .thinking && $0.metadata?["turn_id"] == "turn-A-late" },
                       "A's late append must never reach the Hub after the boundary")

        // No further update()/backfill() call — B appears on disk with
        // enough content to require real pagination, and the
        // ALREADY-RUNNING resolver timer must auto-attach it.
        var bLines = [makeCodexTaskLine(type: "task_started", turnID: "turn-B")]
        for index in 0..<(transcriptBootstrapLineLimit + 10) {
            bLines.append(makeCodexMessageLine(role: "assistant", content: "b-line-\(index)"))
        }
        try (bLines.joined(separator: "\n") + "\n").write(to: transcriptB, atomically: true, encoding: .utf8)

        // Working-continuation `.thinking` markers interleave with the
        // assistant messages inside an active turn, so the single most
        // RECENT event is not reliably the last content line itself —
        // `contains` on the tail window is the same idiom other Codex
        // backfill tests use.
        XCTAssertTrue(waitUntil(timeout: 8) {
            hub.fetch(workspaceID: "workspace", sessionID: "instance-session", limit: 5)
                .events.contains { $0.text == "b-line-\(transcriptBootstrapLineLimit + 9)" }
        }, "the resolver's periodic retry must auto-attach B once it exists, with no further update()/backfill() call")

        let bootstrapped = hub.fetch(workspaceID: "workspace", sessionID: "instance-session", limit: 5000)
        XCTAssertFalse(bootstrapped.events.contains { $0.text == "b-line-0" },
                       "only the tail should be bootstrapped live")

        // ALL of B's OWN live content events (excluding the boundary marker
        // itself and A's earlier session-start) — not just the max — must
        // sit strictly above the ACTUAL boundary seq, with no
        // duplicate/non-monotonic seq anywhere in the bootstrapped set.
        let bContentSeqs = bootstrapped.events.filter { $0.type != .sessionStarted }.map(\.seq)
        XCTAssertEqual(Set(bContentSeqs).count, bContentSeqs.count, "every bootstrapped B content event must own a distinct seq")
        XCTAssertEqual(bContentSeqs.sorted(), bContentSeqs, "bootstrapped B content events must already be strictly seq-ordered")
        let bMinSeq = try XCTUnwrap(bContentSeqs.min())
        XCTAssertGreaterThan(bMinSeq, boundaryEvent.seq,
                            "EVERY B content event — not merely the newest — must land strictly above the ACTUAL boundary seq")

        // The exact tail window: total B lines = 1 (task_started) +
        // (transcriptBootstrapLineLimit + 10) b-lines. Bootstrap keeps only
        // the last transcriptBootstrapLineLimit RAW lines, so the first 11
        // lines (task_started + b-line-0..b-line-9) are excluded — the
        // live window must be EXACTLY b-line-10...b-line-(limit+9), in
        // order, not merely "contains some b-line content."
        let expectedLiveBLines = (10..<(transcriptBootstrapLineLimit + 10)).map { "b-line-\($0)" }
        let actualLiveBLines = bootstrapped.events
            .filter { ($0.text ?? "").hasPrefix("b-line-") }
            .sorted { $0.seq < $1.seq }
            .map { $0.text ?? "" }
        XCTAssertEqual(actualLiveBLines, expectedLiveBLines,
                       "the live-bootstrapped tail window must be EXACTLY the expected b-line range, in order")

        // Inverse backfill mapping in the newly-attached B source: the
        // EXACT nearest-preceding row (b-line-9, immediately before the
        // live window's oldest b-line-10) must resolve — not merely "some
        // earlier b-line" — proving the offset arithmetic derived from THIS
        // auto-attach's actual sequence base is exact, not merely
        // approximately in the right neighborhood.
        let oldestLoadedSeq = try XCTUnwrap(bootstrapped.events.first { $0.text == "b-line-10" }?.seq)
        XCTAssertTrue(session.backfill(beforeSeq: oldestLoadedSeq, limit: 50))
        XCTAssertTrue(waitUntil {
            hub.fetch(workspaceID: "workspace", sessionID: "instance-session", limit: 5000, beforeSeq: oldestLoadedSeq)
                .events.contains { $0.text == "b-line-9" }
        }, "backfill in the auto-attached B source must correctly locate the EXACT nearest-preceding line using the actual post-attach sequence base")
        let historicalPage = hub.fetch(workspaceID: "workspace", sessionID: "instance-session", limit: 5000, beforeSeq: oldestLoadedSeq)
        XCTAssertTrue(historicalPage.events.allSatisfy { $0.seq < oldestLoadedSeq })

        // Exact ordered historical set: b-line-0...b-line-9 (the task_started
        // turn-B anchor is index 0 in the file but not itself a "b-line"),
        // no overlap with the already-live b-line-10 onward — not merely
        // "b-line-9 is somewhere in there."
        let expectedHistoricalBLines = (0..<10).map { "b-line-\($0)" }
        let actualHistoricalBLines = historicalPage.events
            .filter { ($0.text ?? "").hasPrefix("b-line-") }
            .sorted { $0.seq < $1.seq }
            .map { $0.text ?? "" }
        XCTAssertEqual(actualHistoricalBLines, expectedHistoricalBLines,
                       "the backfilled historical page must be EXACTLY b-line-0...b-line-9, in order, got \(actualHistoricalBLines)")
        XCTAssertFalse(historicalPage.events.contains { $0.text == "b-line-10" },
                       "the already-live b-line-10 must not also appear as historical (no overlap/off-by-one)")
    }

    // Delete-and-recreate at the SAME path (same-path invalidation): B
    // reuses A's turn_id AND call_id from offset 0. Every one of B's events
    // must still be accepted (not dropped as duplicates of A's, since the
    // Hub's seen/idempotency sets must have been cleared), no event loss,
    // and B's own tracking must not be falsely continued from A's turn.
    func testSamePathDeleteRecreateAcceptsReusedOffsetsAndEventIDs() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexTranscriptSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcriptURL = directory.appendingPathComponent("rollout-session.jsonl", isDirectory: false)

        let aLines = [
            makeCodexTaskLine(type: "task_started", turnID: "turn-A"),
            makeCodexFunctionCallLine(callID: "call_shared", name: "run", arguments: "{}", timestamp: "2026-05-15T00:00:01Z"),
        ].joined(separator: "\n") + "\n"
        try aLines.write(to: transcriptURL, atomically: true, encoding: .utf8)

        let hub = AgentEventHub()
        let session = CodexTranscriptSession(record: makeRecord(transcriptPath: transcriptURL.path),
                                             fileManager: .default,
                                             hub: hub)
        session.start()
        defer { session.stop() }

        XCTAssertTrue(waitUntil {
            hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 50).events.contains { $0.type == .toolCall && $0.toolCallID == "call_shared" }
        })
        let aMaxSeq = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 50).events.map(\.seq).max() ?? 0

        let deliveredCollector = LockedEventCollector()
        let (subscriptionID, _) = hub.subscribe(workspaceID: "workspace", sessionID: "session") { envelope in
            deliveredCollector.append(envelope.event)
        }
        defer { hub.unsubscribe(subscriptionID) }

        try FileManager.default.removeItem(at: transcriptURL)
        XCTAssertTrue(waitUntil(timeout: 10) {
            hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 5000).events.contains { $0.type == .thinking } == false
        }, "the invalidation must revoke A's live Working anchor")

        let bLines = [
            makeCodexTaskLine(type: "task_started", turnID: "turn-A"),
            makeCodexAgentMessageLine(text: "b commentary", phase: "commentary", timestamp: "2026-05-15T00:00:02Z"),
            makeCodexFunctionCallLine(callID: "call_shared", name: "run", arguments: "{}", timestamp: "2026-05-15T00:00:03Z"),
            makeCodexFunctionCallOutputLine(callID: "call_shared", output: "b result"),
            makeCodexTaskLine(type: "task_complete", turnID: "turn-A", message: "b done"),
        ].joined(separator: "\n") + "\n"
        try bLines.write(to: transcriptURL, atomically: true, encoding: .utf8)

        XCTAssertTrue(waitUntil(timeout: 10) {
            hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 5000).events.contains { $0.metadata?["reason"] == "turn_terminal" }
        }, "B's own terminal (reusing turn-A's turn_id) must be accepted, not dropped as a duplicate")
        hub.drainDeliveriesForTesting()

        let bEvents = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 5000).events
        XCTAssertTrue(bEvents.contains { $0.text == "b commentary" },
                      "B's commentary must publish despite reusing A's turn id")
        XCTAssertTrue(bEvents.contains { $0.type == .toolCall && $0.toolCallID == "call_shared" },
                      "B's tool call (reused call_id) must be accepted, not dropped as a duplicate, got \(bEvents.map { ($0.type, $0.toolCallID ?? "-") })")
        XCTAssertTrue(bEvents.contains { $0.type == .toolResult && $0.toolCallID == "call_shared" && $0.output == "b result" },
                      "B's tool result (reused call_id) must be accepted")

        // No event loss: B's own turn produces the exact expected shape
        // (anchor, commentary continuation, tool call/result, terminal) —
        // not a truncated/short-circuited replay because of A's reused IDs.
        let bOwnEvents = bEvents.filter { $0.seq > aMaxSeq }.sorted { $0.seq < $1.seq }
        let bOwnKindsExcludingBoundary = bOwnEvents.filter { $0.eventID.hasPrefix("source-epoch:") == false }.map(\.type)
        XCTAssertEqual(bOwnKindsExcludingBoundary,
                       [.thinking, .assistantMessage, .thinking, .toolCall, .thinking, .toolResult, .assistantFinal],
                       "got \(bOwnKindsExcludingBoundary)")

        // Subscriber-cursor monotonicity across the WHOLE transition — every
        // seq delivered to the live subscriber strictly increases, no
        // reused-offset collision or rebase drift.
        let deliveredSeqs = deliveredCollector.snapshot().map(\.seq)
        XCTAssertEqual(deliveredSeqs, deliveredSeqs.sorted(), "delivered seqs must already arrive in increasing order")
        XCTAssertEqual(Set(deliveredSeqs).count, deliveredSeqs.count, "no duplicate/colliding seq across the epoch switch, got \(deliveredSeqs)")
        let bMinSeq = bOwnEvents.map(\.seq).min() ?? 0
        XCTAssertGreaterThan(bMinSeq, aMaxSeq,
                             "B's events must land strictly above A's seq high-water — no reused-offset collision")
    }

    // MARK: - Round 3 items 2 & 5: migration/identity-switch coordination, sidebar latch

    // A SAME-source workspace/panel migration is a re-tag (hub.migrateSession
    // rewrites stored events in place), never a source-epoch reset — an
    // active turn's Working must survive it untouched, with no extra
    // lifecycle-reset sessionStarted layered on top.
    func testSameSourceActiveMigrationLeavesWorkingIntact() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexTranscriptSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcriptURL = directory.appendingPathComponent("rollout-session.jsonl", isDirectory: false)
        try (makeCodexTaskLine(type: "task_started", turnID: "turn-migrate") + "\n")
            .write(to: transcriptURL, atomically: true, encoding: .utf8)

        let hub = AgentEventHub()
        let session = CodexTranscriptSession(record: makeRecord(transcriptPath: transcriptURL.path, workspaceID: "workspace-old"),
                                             fileManager: .default,
                                             hub: hub)
        session.start()
        defer { session.stop() }

        XCTAssertTrue(waitUntil {
            hub.fetch(workspaceID: "workspace-old", sessionID: "session", limit: 50).events.contains { $0.type == .thinking }
        })

        // SAME transcript path — only the workspace changes.
        session.update(record: makeRecord(transcriptPath: transcriptURL.path, workspaceID: "workspace-new"))

        XCTAssertTrue(waitUntil {
            hub.fetch(workspaceID: "workspace-new", sessionID: "session", limit: 50).events.contains { $0.type == .thinking }
        }, "migrateSession must rewrite the existing events' workspace_id in place")
        let afterMigration = hub.fetch(workspaceID: "workspace-new", sessionID: "session", limit: 50).events.sorted { $0.seq < $1.seq }
        XCTAssertEqual(Self.equivalentWorkingStates(for: afterMigration).last, true,
                       "a same-source migration must never clear Working, got \(afterMigration.map { ($0.type, $0.text ?? "") })")
        XCTAssertFalse(afterMigration.contains { $0.eventID.hasPrefix("source-epoch:") },
                       "a same-source migration must not publish a source-epoch boundary")
        XCTAssertTrue(hub.fetch(workspaceID: "workspace-old", sessionID: "session", limit: 50).events.isEmpty,
                      "the OLD workspace must no longer see this session's events after migration")
    }

    // A registry update that BOTH switches the transcript source AND
    // migrates workspace/panel must publish exactly ONE lifecycle-reset
    // signal (the source-epoch boundary, already carrying the NEW
    // workspace/panel since self.record is updated before it publishes) —
    // never a second "migrated" sessionStarted that would re-clear
    // whatever Working the new source's own bootstrap already established.
    func testSourceSwitchWithSimultaneousMigrationPublishesOnlyOneBoundaryAndKeepsBActive() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexTranscriptSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcriptA = directory.appendingPathComponent("rollout-a.jsonl", isDirectory: false)
        let transcriptB = directory.appendingPathComponent("rollout-b.jsonl", isDirectory: false)
        try (makeCodexMessageLine(role: "assistant", content: "a idle") + "\n")
            .write(to: transcriptA, atomically: true, encoding: .utf8)
        try (makeCodexTaskLine(type: "task_started", turnID: "turn-B-active") + "\n")
            .write(to: transcriptB, atomically: true, encoding: .utf8)

        let hub = AgentEventHub()
        let session = CodexTranscriptSession(record: makeRecord(transcriptPath: transcriptA.path, workspaceID: "workspace-old"),
                                             fileManager: .default,
                                             hub: hub)
        session.start()
        defer { session.stop() }

        XCTAssertTrue(waitUntil {
            hub.fetch(workspaceID: "workspace-old", sessionID: "session", limit: 50).events.contains { $0.text == "a idle" }
        })

        session.update(record: makeRecord(transcriptPath: transcriptB.path, workspaceID: "workspace-new"))

        XCTAssertTrue(waitUntil {
            hub.fetch(workspaceID: "workspace-new", sessionID: "session", limit: 50).events.contains { $0.type == .thinking }
        })
        let afterSwitch = hub.fetch(workspaceID: "workspace-new", sessionID: "session", limit: 50).events.sorted { $0.seq < $1.seq }

        let boundaries = afterSwitch.filter { $0.eventID.hasPrefix("source-epoch:") }
        XCTAssertEqual(boundaries.count, 1, "exactly one source-epoch boundary, got \(boundaries.map(\.eventID))")
        XCTAssertFalse(afterSwitch.contains { $0.eventID.contains(":migrated:") },
                       "no second migrated-sessionStarted may be published alongside a source switch")
        XCTAssertEqual(Self.equivalentWorkingStates(for: afterSwitch).last, true,
                       "B's active turn must still be Working after the combined switch+migration, got \(afterSwitch.map { ($0.type, $0.text ?? "") })")
    }

    // Sidebar activation ownership must also transfer per-source: A was
    // running; B is blank/idle — B's bootstrap must send its OWN derived
    // shellState (prompt) exactly once, not silently skip because the OLD
    // source already consumed the one-shot activation latch.
    func testSourceSwitchFromRunningAToBlankBSendsPromptSidebar() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexTranscriptSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcriptA = directory.appendingPathComponent("rollout-a.jsonl", isDirectory: false)
        let transcriptB = directory.appendingPathComponent("rollout-b.jsonl", isDirectory: false)
        try (makeCodexTaskLine(type: "task_started", turnID: "turn-A-running") + "\n")
            .write(to: transcriptA, atomically: true, encoding: .utf8)
        try "".write(to: transcriptB, atomically: true, encoding: .utf8)

        let hub = AgentEventHub()
        let sender = RecordingCommandSender()
        let session = CodexTranscriptSession(record: makeRecord(transcriptPath: transcriptA.path),
                                             fileManager: .default,
                                             hub: hub,
                                             socketClient: sender)
        session.start()
        defer { session.stop() }

        XCTAssertTrue(waitUntil {
            sender.commands().contains("report_shell_state running --workspace_id=workspace")
        })
        let commandsBeforeSwitch = sender.commands()

        session.update(record: makeRecord(transcriptPath: transcriptB.path))

        XCTAssertTrue(waitUntil {
            sender.commands().dropFirst(commandsBeforeSwitch.count).contains("report_shell_state prompt --workspace_id=workspace")
        }, "B's bootstrap must send its own derived (prompt) shellState, got new: \(sender.commands().dropFirst(commandsBeforeSwitch.count))")
    }

    // The mirror case: A was idle; B is immediately active — B's bootstrap
    // must send `running`, not silently skip.
    func testSourceSwitchFromIdleAToActiveBSendsRunningSidebar() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexTranscriptSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcriptA = directory.appendingPathComponent("rollout-a.jsonl", isDirectory: false)
        let transcriptB = directory.appendingPathComponent("rollout-b.jsonl", isDirectory: false)
        try (makeCodexMessageLine(role: "assistant", content: "a idle") + "\n")
            .write(to: transcriptA, atomically: true, encoding: .utf8)
        try (makeCodexTaskLine(type: "task_started", turnID: "turn-B-running") + "\n")
            .write(to: transcriptB, atomically: true, encoding: .utf8)

        let hub = AgentEventHub()
        let sender = RecordingCommandSender()
        let session = CodexTranscriptSession(record: makeRecord(transcriptPath: transcriptA.path),
                                             fileManager: .default,
                                             hub: hub,
                                             socketClient: sender)
        session.start()
        defer { session.stop() }

        XCTAssertTrue(waitUntil {
            hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 50).events.contains { $0.text == "a idle" }
        })
        let commandsBeforeSwitch = sender.commands()

        session.update(record: makeRecord(transcriptPath: transcriptB.path))

        XCTAssertTrue(waitUntil {
            sender.commands().dropFirst(commandsBeforeSwitch.count).contains("report_shell_state running --workspace_id=workspace")
        }, "B's bootstrap must send its own derived (running) shellState, got new: \(sender.commands().dropFirst(commandsBeforeSwitch.count))")
    }

    // MARK: - Round 3 Blocker 2: stale terminal must not touch the sidebar either

    func testStaleTerminalAddsNoSidebarCommandWhileGenuineTerminalDoes() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexTranscriptSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcriptURL = directory.appendingPathComponent("rollout-session.jsonl", isDirectory: false)

        let lines = [
            makeCodexTaskLine(type: "task_started", turnID: "turn-A"),
            makeCodexTaskLine(type: "turn_aborted", turnID: "turn-A"),
            makeCodexTaskLine(type: "task_started", turnID: "turn-B"),
        ].joined(separator: "\n") + "\n"
        try lines.write(to: transcriptURL, atomically: true, encoding: .utf8)

        let hub = AgentEventHub()
        let sender = RecordingCommandSender()
        let session = CodexTranscriptSession(record: makeRecord(transcriptPath: transcriptURL.path),
                                             fileManager: .default,
                                             hub: hub,
                                             socketClient: sender)
        session.start()
        defer { session.stop() }

        XCTAssertTrue(waitUntil {
            hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 50).events.contains {
                $0.metadata?["turn_id"] == "turn-B" && $0.type == .thinking
            }
        })
        let commandsBeforeStaleTerminal = sender.commands()

        // A LATE task_complete for A arrives while B is the tracked active
        // turn — must add ZERO new sidebar commands (no prompt, no
        // completed notification), not just skip the chat terminal. B's
        // own genuine terminal is appended immediately after, in the SAME
        // file, so it lands strictly later in the tailer's read order —
        // waiting for B's positive signal below is itself the proof that
        // A's stale line was already processed by then; no sleep needed.
        let handle = try FileHandle(forWritingTo: transcriptURL)
        handle.seekToEndOfFile()
        handle.write((makeCodexTaskLine(type: "task_complete", turnID: "turn-A", message: "late") + "\n").data(using: .utf8)!)
        try handle.close()

        // B's own genuine terminal DOES still change the sidebar normally.
        let handle2 = try FileHandle(forWritingTo: transcriptURL)
        handle2.seekToEndOfFile()
        handle2.write((makeCodexTaskLine(type: "task_complete", turnID: "turn-B", message: "b done") + "\n").data(using: .utf8)!)
        try handle2.close()
        // `CodexSidebarMessages.completed` is a MULTI-command batch — a
        // count-crosses-baseline-by-1 wait would race ahead of the second
        // command still being sent. Wait for the FULL expected count
        // before comparing, not just "some new command arrived."
        let expectedBCompleted = CodexSidebarMessages.completed(workspaceID: "workspace", body: "b done")
        XCTAssertTrue(waitUntil {
            sender.commands().count >= commandsBeforeStaleTerminal.count + expectedBCompleted.count
        }, "B's own genuine terminal must add its FULL expected completion batch")
        // The delta since baseline must be EXACTLY B's own expected
        // completion batch — not merely "contains" the expected command —
        // proving A's earlier stale terminal contributed NOTHING extra.
        let newCommands = Array(sender.commands().dropFirst(commandsBeforeStaleTerminal.count))
        XCTAssertEqual(newCommands, expectedBCompleted,
                      "the delta since baseline must be EXACTLY B's own completion batch — a stale A terminal must add zero commands, got \(newCommands)")
    }

    // MARK: - Round 3 Blocker 3: active-turn opener beyond the bootstrap window

    // task_started(A) falls OUTSIDE the 500-line bootstrap tail; the tail
    // itself has only non-lifecycle records plus trailing commentary/tool
    // activity for the SAME still-open turn. Attach must still end up
    // Working — recovered via the deep, lifecycle-only reverse scan.
    func testActiveTaskOpenerBeyondBootstrapWindowIsRecovered() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexTranscriptSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcriptURL = directory.appendingPathComponent("rollout-session.jsonl", isDirectory: false)

        var lines = [String]()
        lines.append(makeCodexTaskLine(type: "task_started", turnID: "turn-deep"))
        // >500 non-lifecycle filler lines, pushing task_started outside the
        // bootstrap tail window.
        for index in 0..<(transcriptBootstrapLineLimit + 50) {
            lines.append(makeCodexMessageLine(role: "assistant", content: "filler-\(index)"))
        }
        // Trailing commentary/tool activity for the SAME still-open turn,
        // within the tail window.
        lines.append(makeCodexAgentMessageLine(text: "deep tail commentary", phase: "commentary", timestamp: "2026-05-15T00:10:00Z"))
        try (lines.joined(separator: "\n") + "\n").write(to: transcriptURL, atomically: true, encoding: .utf8)

        let hub = AgentEventHub()
        let session = CodexTranscriptSession(record: makeRecord(transcriptPath: transcriptURL.path),
                                             fileManager: .default,
                                             hub: hub)
        session.start()
        defer { session.stop() }

        XCTAssertTrue(waitUntil {
            hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 5000).events.contains { $0.text == "deep tail commentary" }
        })
        let afterAttach = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 5000).events.sorted { $0.seq < $1.seq }
        XCTAssertTrue(afterAttach.contains { $0.metadata?["reason"] == "bootstrap_recovered_task_started" },
                      "the deep opener must be recovered via the lifecycle-only scan")
        // The LAST event overall must be the recovery anchor's continuation
        // (from the tail commentary) — i.e. the final derived state is
        // Working ON, despite task_started itself being outside the window.
        XCTAssertEqual(afterAttach.last?.type, .thinking,
                       "the final state after attach must be Working ON, got \(afterAttach.map { ($0.type, $0.text ?? "") })")

        // Appending the matching task_complete now correctly ends it.
        let handle = try FileHandle(forWritingTo: transcriptURL)
        handle.seekToEndOfFile()
        handle.write((makeCodexTaskLine(type: "task_complete", turnID: "turn-deep", message: "done") + "\n").data(using: .utf8)!)
        try handle.close()
        XCTAssertTrue(waitUntil {
            hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 5000).events.contains { $0.metadata?["reason"] == "turn_terminal" }
        }, "the matching real terminal must still close the recovered turn")
    }

    // Mitigation for the deep-recovery operational contract (see round 3
    // result notes): the recovery is based on rollout-terminal + registry
    // liveness, not a cross-validated app-server generation snapshot. If the
    // record/process disappears (crash, removal) while a deep-recovered
    // Working is showing, `stop()` must still end it — a subscriber must
    // never be left with a permanent spinner. `stop()` already publishes
    // `sessionEnded` unconditionally, which the client treats as a Working-
    // clearing event exactly like `.assistantMessage`/`.toolCall`/etc.
    func testStopAfterDeepRecoveryDeliversSessionEndedAndEndsWorking() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexTranscriptSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcriptURL = directory.appendingPathComponent("rollout-session.jsonl", isDirectory: false)

        var lines = [String]()
        lines.append(makeCodexTaskLine(type: "task_started", turnID: "turn-deep-stop"))
        for index in 0..<(transcriptBootstrapLineLimit + 50) {
            lines.append(makeCodexMessageLine(role: "assistant", content: "filler-\(index)"))
        }
        try (lines.joined(separator: "\n") + "\n").write(to: transcriptURL, atomically: true, encoding: .utf8)

        let hub = AgentEventHub()
        let session = CodexTranscriptSession(record: makeRecord(transcriptPath: transcriptURL.path),
                                             fileManager: .default,
                                             hub: hub)
        session.start()
        defer { session.stop() }

        XCTAssertTrue(waitUntil {
            hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 5000).events.contains {
                $0.metadata?["reason"] == "bootstrap_recovered_task_started"
            }
        })
        let beforeStop = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 5000).events.sorted { $0.seq < $1.seq }
        XCTAssertEqual(beforeStop.last?.type, .thinking, "precondition: Working is ON before stop()")

        // Simulate the record/process disappearing (crash, removal): the
        // registry monitor calls stop() on the transcript session.
        session.stop()

        let afterStop = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 5000).events.sorted { $0.seq < $1.seq }
        XCTAssertEqual(afterStop.last?.type, .sessionEnded,
                       "stop() must deliver sessionEnded as the final event, got \(afterStop.map { ($0.type, $0.text ?? "") })")
        let equivalentWorking = Self.equivalentWorkingStates(for: afterStop).last
        XCTAssertEqual(equivalentWorking, false,
                       "the equivalent Working state must be OFF after stop() — no permanent spinner survives a crash/removal cleanup")
    }

    // The nearest lifecycle in the deep scan is ALREADY terminal (a properly
    // closed turn), just also beyond the bootstrap window — attach must
    // never synthesize a `.thinking` anchor in this case.
    func testDeepIdleTranscriptWithTerminalLifecycleNeverAnchorsThinking() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexTranscriptSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcriptURL = directory.appendingPathComponent("rollout-session.jsonl", isDirectory: false)

        var lines = [String]()
        lines.append(makeCodexTaskLine(type: "task_started", turnID: "turn-deep-idle"))
        lines.append(makeCodexTaskLine(type: "task_complete", turnID: "turn-deep-idle", message: "done long ago"))
        for index in 0..<(transcriptBootstrapLineLimit + 50) {
            lines.append(makeCodexMessageLine(role: "assistant", content: "filler-\(index)"))
        }
        try (lines.joined(separator: "\n") + "\n").write(to: transcriptURL, atomically: true, encoding: .utf8)

        let hub = AgentEventHub()
        let session = CodexTranscriptSession(record: makeRecord(transcriptPath: transcriptURL.path),
                                             fileManager: .default,
                                             hub: hub)
        session.start()
        defer { session.stop() }

        XCTAssertTrue(waitUntil {
            hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 5000).events.contains {
                $0.text == "filler-\(transcriptBootstrapLineLimit + 49)"
            }
        })
        // No sleep needed: `session.start()` synchronously completes the
        // deep-recovery scan (part of the same synchronous startResolver()
        // attach path) before returning — by the time the bootstrap
        // tail's last filler line is observed above, any recovery-scan
        // anchor it was going to synthesize would already be present.
        let events = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 5000).events
        XCTAssertFalse(events.contains { $0.type == .thinking },
                       "a deep-idle transcript (nearest lifecycle already terminal) must never anchor Working, got \(events.map { ($0.type, $0.text ?? "") })")
        XCTAssertFalse(events.contains { $0.metadata?["reason"] == "bootstrap_recovered_task_started" })
    }

    // Round 6 P0: the deep scan must use the SAME turn-identity matching
    // semantics as the live path (consumeTaskComplete/consumeTurnAborted's
    // activeWorkingTurnID check) — a terminal for turn A must never be
    // mistaken for evidence that a LATER, still-open turn B has ended.
    // task_started(B) opens; a late/stale task_complete for an EARLIER,
    // unrelated turn A then arrives; both are pushed outside the 500-line
    // bootstrap window by >500 filler lines. B was never actually closed —
    // attach must still end up Working, not idle.
    func testDeepScanIgnoresStaleTerminalForUnrelatedEarlierTurnAndRecoversLaterOpener() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexTranscriptSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcriptURL = directory.appendingPathComponent("rollout-session.jsonl", isDirectory: false)

        var lines = [String]()
        // Turn A opens and, chronologically later, its terminal arrives late —
        // but turn B opens in between and is never closed. Both A's terminal
        // and B's opener are pushed outside the bootstrap window below.
        lines.append(makeCodexTaskLine(type: "task_started", turnID: "turn-A-earlier"))
        lines.append(makeCodexTaskLine(type: "task_started", turnID: "turn-B-later"))
        lines.append(makeCodexTaskLine(type: "task_complete", turnID: "turn-A-earlier", message: "late stale completion"))
        // >500 non-lifecycle filler lines, pushing every lifecycle line above
        // outside the bootstrap tail window.
        for index in 0..<(transcriptBootstrapLineLimit + 50) {
            lines.append(makeCodexMessageLine(role: "assistant", content: "filler-\(index)"))
        }
        try (lines.joined(separator: "\n") + "\n").write(to: transcriptURL, atomically: true, encoding: .utf8)

        let hub = AgentEventHub()
        let session = CodexTranscriptSession(record: makeRecord(transcriptPath: transcriptURL.path),
                                             fileManager: .default,
                                             hub: hub)
        session.start()
        defer { session.stop() }

        XCTAssertTrue(waitUntil {
            hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 5000).events.contains {
                $0.text == "filler-\(transcriptBootstrapLineLimit + 49)"
            }
        })
        let afterAttach = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 5000).events.sorted { $0.seq < $1.seq }
        XCTAssertTrue(afterAttach.contains { $0.metadata?["turn_id"] == "turn-B-later" && $0.metadata?["reason"] == "bootstrap_recovered_task_started" },
                      "the later, still-open turn B must be recovered, got \(afterAttach.map { ($0.type, $0.metadata ?? [:]) })")
        XCTAssertEqual(afterAttach.last?.type, .thinking,
                       "the final state after attach must be Working ON for the still-open later turn, got \(afterAttach.map { ($0.type, $0.text ?? "") })")

        // The matching terminal for B now correctly ends it.
        let handle = try FileHandle(forWritingTo: transcriptURL)
        handle.seekToEndOfFile()
        handle.write((makeCodexTaskLine(type: "task_complete", turnID: "turn-B-later", message: "b done") + "\n").data(using: .utf8)!)
        try handle.close()
        XCTAssertTrue(waitUntil {
            hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 5000).events.contains { $0.metadata?["reason"] == "turn_terminal" }
        }, "the matching real terminal for B must still close the recovered turn")
    }

    // Round 6 P0: a stale terminal for an EARLIER, unrelated turn landing
    // INSIDE the bootstrap window must not, by itself, suppress the deep
    // scan — only lastStartedTurnID == nil (the window never saw the true
    // most-recent task_started at all) is a safe trigger. Here turn_started
    // B falls outside the window (pushed out by filler), but a stale
    // task_complete for an earlier, different turn A lands INSIDE the
    // window. The old shortcut ("skip deep scan if ANY terminal seen in
    // window") would treat A's in-window terminal as proof of idle and never
    // discover that B is still open.
    func testStaleInWindowTerminalForUnrelatedEarlierTurnDoesNotSuppressDeepScan() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexTranscriptSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcriptURL = directory.appendingPathComponent("rollout-session.jsonl", isDirectory: false)

        var lines = [String]()
        // turn-B-window-later opens; everything below pushes it outside the
        // 500-line bootstrap window.
        lines.append(makeCodexTaskLine(type: "task_started", turnID: "turn-B-window-later"))
        for index in 0..<(transcriptBootstrapLineLimit + 50) {
            lines.append(makeCodexMessageLine(role: "assistant", content: "filler-\(index)"))
        }
        // A stale terminal for an EARLIER, unrelated turn — arrives late,
        // lands INSIDE the window (near the tail).
        lines.append(makeCodexTaskLine(type: "task_complete", turnID: "turn-A-window-stale", message: "late stale completion"))
        for index in 0..<10 {
            lines.append(makeCodexMessageLine(role: "assistant", content: "tail-filler-\(index)"))
        }
        try (lines.joined(separator: "\n") + "\n").write(to: transcriptURL, atomically: true, encoding: .utf8)

        let hub = AgentEventHub()
        let session = CodexTranscriptSession(record: makeRecord(transcriptPath: transcriptURL.path),
                                             fileManager: .default,
                                             hub: hub)
        session.start()
        defer { session.stop() }

        XCTAssertTrue(waitUntil {
            hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 5000).events.contains { $0.text == "tail-filler-9" }
        })
        let afterAttach = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 5000).events.sorted { $0.seq < $1.seq }
        XCTAssertTrue(afterAttach.contains { $0.metadata?["turn_id"] == "turn-B-window-later" && $0.metadata?["reason"] == "bootstrap_recovered_task_started" },
                      "the still-open later turn B must be recovered despite an unrelated stale terminal inside the window, got \(afterAttach.map { ($0.type, $0.metadata ?? [:]) })")
        XCTAssertEqual(afterAttach.last?.type, .thinking,
                       "the final state after attach must be Working ON, got \(afterAttach.map { ($0.type, $0.text ?? "") })")
    }

    // Round 6 counterexample (second independent reviewer): seeding the deep
    // scan's matched-terminal set from ONLY the single-slot lastCompletedTurnID/
    // lastAbortedTurnID loses an EARLIER, genuinely-matching in-window
    // terminal when a LATER, unrelated stale terminal also lands in the same
    // window — the single slot ends up holding only the stale one. Here
    // task_started(B) falls outside the window; the window itself contains,
    // in order, a matching task_complete(B) followed by a stale
    // task_complete(A) for a different, unrelated turn. The true chronology
    // is: B opened, B completed, A's stale completion changes nothing — the
    // correct outcome is idle. A single-slot seed would end up with only "A"
    // in the matched set, fail to match B's opener against it, and wrongly
    // resurrect B as Working.
    func testInWindowMatchingTerminalSurvivesLaterUnrelatedStaleTerminalInSameWindow() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexTranscriptSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcriptURL = directory.appendingPathComponent("rollout-session.jsonl", isDirectory: false)

        var lines = [String]()
        // turn-B-matched opens; pushed outside the window by filler below.
        lines.append(makeCodexTaskLine(type: "task_started", turnID: "turn-B-matched"))
        for index in 0..<(transcriptBootstrapLineLimit + 50) {
            lines.append(makeCodexMessageLine(role: "assistant", content: "filler-\(index)"))
        }
        // The MATCHING terminal for B — lands INSIDE the window.
        lines.append(makeCodexTaskLine(type: "task_complete", turnID: "turn-B-matched", message: "b done"))
        for index in 0..<5 {
            lines.append(makeCodexMessageLine(role: "assistant", content: "mid-filler-\(index)"))
        }
        // A LATER, unrelated stale terminal — also lands INSIDE the window.
        lines.append(makeCodexTaskLine(type: "task_complete", turnID: "turn-A-stale-after", message: "unrelated late completion"))
        for index in 0..<5 {
            lines.append(makeCodexMessageLine(role: "assistant", content: "tail-filler-\(index)"))
        }
        try (lines.joined(separator: "\n") + "\n").write(to: transcriptURL, atomically: true, encoding: .utf8)

        let hub = AgentEventHub()
        let session = CodexTranscriptSession(record: makeRecord(transcriptPath: transcriptURL.path),
                                             fileManager: .default,
                                             hub: hub)
        session.start()
        defer { session.stop() }

        XCTAssertTrue(waitUntil {
            hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 5000).events.contains { $0.text == "tail-filler-4" }
        })
        // No sleep needed — see testDeepIdleTranscriptWithTerminalLifecycleNeverAnchorsThinking
        // for why start()'s synchronous recovery scan has already had its
        // chance to (wrongly) fire by the time the tail is observed.
        let events = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 5000).events
        XCTAssertFalse(events.contains { $0.type == .thinking },
                       "B was already matched-closed in-window by its own terminal; an unrelated later stale terminal in the same window must not resurrect it as Working, got \(events.map { ($0.type, $0.text ?? "") })")
        XCTAssertFalse(events.contains { $0.metadata?["reason"] == "bootstrap_recovered_task_started" })
    }

    // An ordinary turn with no steer — a single long-running tool call —
    // must ALSO keep Working alive via the continuation mechanism, not just
    // the steer-adjacent case.
    func testOrdinaryTurnWithLongToolCallRemainsWorkingUntilCompletion() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexTranscriptSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcriptURL = directory.appendingPathComponent("rollout-session.jsonl", isDirectory: false)

        let lines = [
            makeCodexTaskLine(type: "task_started", turnID: "turn-solo"),
            makeCodexFunctionCallLine(callID: "call_solo", name: "run_tests", arguments: "{}",
                                      timestamp: "2026-05-15T00:01:00Z"),
        ].joined(separator: "\n") + "\n"
        try lines.write(to: transcriptURL, atomically: true, encoding: .utf8)

        let hub = AgentEventHub()
        let session = CodexTranscriptSession(record: makeRecord(transcriptPath: transcriptURL.path),
                                             fileManager: .default,
                                             hub: hub)
        session.start()
        defer { session.stop() }

        XCTAssertTrue(waitUntil {
            hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 5000).events.contains { $0.type == .toolCall }
        })
        let midFlight = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 5000).events
            .sorted { $0.seq < $1.seq }
        XCTAssertEqual(midFlight.map(\.type), [.sessionStarted, .thinking, .toolCall, .thinking],
                       "the long-running tool call must be immediately followed by a continuation thinking event, got \(midFlight.map(\.type))")

        // Now the tool finally returns and the turn completes.
        let handle = try FileHandle(forWritingTo: transcriptURL)
        handle.seekToEndOfFile()
        handle.write((makeCodexFunctionCallOutputLine(callID: "call_solo", output: "all green") + "\n").data(using: .utf8)!)
        handle.write((makeCodexTaskLine(type: "task_complete", turnID: "turn-solo", message: "all green") + "\n").data(using: .utf8)!)
        try handle.close()

        XCTAssertTrue(waitUntil {
            hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 5000).events.contains {
                $0.metadata?["reason"] == "turn_terminal"
            }
        })
        let final = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 5000).events
            .sorted { $0.seq < $1.seq }
        XCTAssertEqual(final.map(\.type),
                       [.sessionStarted, .thinking, .toolCall, .thinking, .toolResult, .assistantFinal])
    }

    // A stale/late terminal for an OLDER turn must not clear the CURRENTLY
    // active turn's Working state. Turn A ends via turn_aborted (so
    // lastCompletedTurnID is never set to A); turn B then starts and becomes
    // the tracked active turn; a LATE task_complete for A finally arrives
    // while B is active. It must be ignored for Working purposes, and B's
    // own eventual genuine completion must still work normally afterward.
    func testStaleTerminalForAnotherTurnDoesNotClearActiveTurn() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexTranscriptSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcriptURL = directory.appendingPathComponent("rollout-session.jsonl", isDirectory: false)

        let lines = [
            makeCodexTaskLine(type: "task_started", turnID: "turn-A"),
            makeCodexTaskLine(type: "turn_aborted", turnID: "turn-A"),
            makeCodexTaskLine(type: "task_started", turnID: "turn-B"),
        ].joined(separator: "\n") + "\n"
        try lines.write(to: transcriptURL, atomically: true, encoding: .utf8)

        let hub = AgentEventHub()
        let session = CodexTranscriptSession(record: makeRecord(transcriptPath: transcriptURL.path),
                                             fileManager: .default,
                                             hub: hub)
        session.start()
        defer { session.stop() }

        XCTAssertTrue(waitUntil {
            hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 5000).events.contains {
                $0.metadata?["turn_id"] == "turn-B" && $0.type == .thinking
            }
        })
        XCTAssertTrue(hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 5000).events.contains {
            $0.metadata?["turn_id"] == "turn-A" && $0.metadata?["reason"] == "turn_terminal"
        }, "turn A's own abort must have published its terminal normally while A was active")

        // A LATE task_complete for A arrives while B is the tracked active
        // turn. It passes the pre-existing per-turn dedup (A was never
        // marked completed via task_complete, only aborted), so it must be
        // caught by the NEW active-turn staleness gate instead. B's own
        // genuine completion is appended immediately after, in the SAME
        // file — waiting for B's terminal below is itself the proof that
        // A's stale line was already processed by then; no sleep needed.
        let handle = try FileHandle(forWritingTo: transcriptURL)
        handle.seekToEndOfFile()
        handle.write((makeCodexTaskLine(type: "task_complete", turnID: "turn-A", message: "late") + "\n").data(using: .utf8)!)
        try handle.close()

        let handle2 = try FileHandle(forWritingTo: transcriptURL)
        handle2.seekToEndOfFile()
        handle2.write((makeCodexTaskLine(type: "task_complete", turnID: "turn-B", message: "done B") + "\n").data(using: .utf8)!)
        try handle2.close()
        XCTAssertTrue(waitUntil {
            hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 5000).events.contains {
                $0.metadata?["turn_id"] == "turn-B" && $0.metadata?["reason"] == "turn_terminal"
            }
        }, "turn B's own genuine terminal must still publish after the stale A event was ignored")

        // Exactly TWO terminals total — A's own abort-terminal (published
        // while A was active) and B's own genuine completion — proves the
        // late/stale A task_complete contributed ZERO: a THIRD terminal
        // here would mean it wrongly counted.
        let afterBoth = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 5000).events
        XCTAssertEqual(afterBoth.filter { $0.metadata?["reason"] == "turn_terminal" }.count, 2,
                       "the late task_complete for A must not add a THIRD terminal event while B is active, got \(afterBoth.filter { $0.metadata?["reason"] == "turn_terminal" }.map { ($0.metadata?["turn_id"], $0.text) })")
    }

    // Historical backfill must never leak a stale Working state (a
    // `.thinking` with no visible terminal) from an old/incomplete
    // historical turn into the live panel.
    func testHistoricalBackfillNeverSurfacesThinkingFromOldTaskLifecycle() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexTranscriptSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcriptURL = directory.appendingPathComponent("rollout-session.jsonl", isDirectory: false)

        var lines = [String]()
        // OLD region (outside the bootstrap tail): a full historical
        // turn AND a historical turn that never completed (incomplete
        // lifecycle) — both must never surface a `.thinking` event once
        // backfilled.
        lines.append(makeCodexTaskLine(type: "task_started", turnID: "old-turn-complete"))
        lines.append(makeCodexAgentMessageLine(text: "old commentary", phase: "commentary", timestamp: "2026-05-15T00:00:01Z"))
        lines.append(makeCodexTaskLine(type: "task_complete", turnID: "old-turn-complete", message: "old done"))
        lines.append(makeCodexTaskLine(type: "task_started", turnID: "old-turn-incomplete"))
        lines.append(makeCodexAgentMessageLine(text: "old dangling commentary", phase: "commentary", timestamp: "2026-05-15T00:00:02Z"))
        // NOTE: no task_complete for old-turn-incomplete — its lifecycle is
        // truncated, exactly the "incomplete historical turn" risk case.
        for index in 0..<transcriptBootstrapLineLimit {
            lines.append(makeCodexMessageLine(role: "assistant", content: "line-\(index)"))
        }
        // A genuine in-window (tail) lifecycle pair: the ACTUAL current state
        // is idle, via a properly closed later turn — this is what keeps the
        // bootstrap-window-outage recovery scan (a SEPARATE feature, tested
        // on its own) from firing here at all, isolating this test to purely
        // the backfill-non-leak property for the ancient/incomplete turns.
        lines.append(makeCodexTaskLine(type: "task_started", turnID: "tail-lifecycle-anchor"))
        lines.append(makeCodexTaskLine(type: "task_complete", turnID: "tail-lifecycle-anchor", message: "tail done"))
        try (lines.joined(separator: "\n") + "\n").write(to: transcriptURL, atomically: true, encoding: .utf8)

        let hub = AgentEventHub()
        let session = CodexTranscriptSession(record: makeRecord(transcriptPath: transcriptURL.path),
                                             fileManager: .default,
                                             hub: hub)
        session.start()
        defer { session.stop() }
        XCTAssertTrue(waitUntil {
            hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 5000).events.contains { $0.text == "line-\(transcriptBootstrapLineLimit - 1)" }
        })
        let boundary = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 5000)
            .events.filter { ($0.text ?? "").hasPrefix("line-") }.map(\.seq).min() ?? 0

        XCTAssertTrue(session.backfill(beforeSeq: boundary, limit: 600))
        XCTAssertTrue(waitUntil {
            hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 5000, beforeSeq: boundary).events.isEmpty == false
        })

        // The tail's OWN in-window lifecycle is a genuinely closed turn, so
        // the bootstrap-window-outage recovery scan never fires for this
        // fixture — confirmed directly, not just inferred.
        XCTAssertFalse(hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 5000).events.contains {
            $0.metadata?["reason"] == "bootstrap_recovered_task_started"
        }, "an in-window lifecycle must suppress the deep-scan recovery entirely")

        let history = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 5000, beforeSeq: boundary).events
        XCTAssertFalse(history.contains { $0.type == .thinking },
                       "backfilled history must never surface a Working-indicator thinking event, got \(history.map { ($0.type, $0.text ?? "") })")
        XCTAssertFalse(history.contains { $0.metadata?["reason"] == "turn_terminal" },
                       "backfilled history must never surface the synthetic turn-terminal event either")
        // The ordinary commentary text itself must still be visible in history.
        XCTAssertTrue(history.contains { $0.text == "old commentary" })
        XCTAssertTrue(history.contains { $0.text == "old dangling commentary" })
    }

    // MARK: - Round 4: prepareUpdate/finishUpdate gated workspace-migration transaction

    // Deterministic (no sleep/stress) proof of the two-phase transaction:
    // prepareUpdate() atomically switches the record to workspace-B AND
    // holds all sidebar publication; a REAL task_complete line is then
    // injected and its Hub-level effect (not gated) is awaited as a
    // reliable synchronization checkpoint proving the line was fully
    // processed WHILE the sidebar was still held; only finishUpdate()
    // flushes the held batch — in order, undropped, addressed to B.
    func testPrepareUpdateHoldsSidebarUntilFinishUpdateFlushesEveryBatchInOrder() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexTranscriptSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcriptURL = directory.appendingPathComponent("rollout.jsonl", isDirectory: false)
        try (makeCodexTaskLine(type: "task_started", turnID: "turn-gate") + "\n")
            .write(to: transcriptURL, atomically: true, encoding: .utf8)

        let hub = AgentEventHub()
        let sender = RecordingCommandSender()
        let recordA = makeRecord(transcriptPath: transcriptURL.path, workspaceID: "workspace-A")
        let session = CodexTranscriptSession(record: recordA, fileManager: .default, hub: hub, socketClient: sender)
        session.start()
        defer { session.stop() }

        XCTAssertTrue(waitUntil {
            sender.commands().contains("report_shell_state running --workspace_id=workspace-A")
        })
        let commandsBeforePrepare = sender.commands()

        let recordB = makeRecord(transcriptPath: transcriptURL.path, workspaceID: "workspace-B")
        session.prepareUpdate(record: recordB)
        XCTAssertEqual(sender.commands(), commandsBeforePrepare,
                       "prepareUpdate itself must not publish anything for the new workspace yet")

        // Inject REAL content while held: a task_complete for turn-gate.
        let handle = try FileHandle(forWritingTo: transcriptURL)
        handle.seekToEndOfFile()
        handle.write((makeCodexTaskLine(type: "task_complete", turnID: "turn-gate", message: "done") + "\n").data(using: .utf8)!)
        try handle.close()

        // Hub-level effects are NEVER gated by the sidebar hold — waiting
        // for this is a reliable, deterministic proof that the line was
        // fully processed (and its sidebar effect already attempted/buffered)
        // WHILE still held, with no reliance on sleep/timing luck.
        XCTAssertTrue(waitUntil {
            hub.fetch(workspaceID: "workspace-B", sessionID: "session", limit: 50).events.contains { $0.metadata?["reason"] == "turn_terminal" }
        }, "the task_complete's Hub effect must land even while sidebar publication is held")

        XCTAssertEqual(sender.commands(), commandsBeforePrepare,
                       "no sidebar output may escape while prepared, even for real content processed under the NEW workspace")

        session.finishUpdate()

        let newCommands = Array(sender.commands().dropFirst(commandsBeforePrepare.count))
        // Two buffered batches are legitimately held during the prepared
        // window: the migration's own activation (workspace changed, source
        // did not) fires first, then the injected task_complete's
        // completed+prompt pair. finishUpdate must flush both, in order,
        // undropped — never coalesced to just the final state.
        let expectedActivation = CodexSidebarMessages.sessionActive(workspaceID: "workspace-B", shellState: .running)
        let expectedCompleted = CodexSidebarMessages.completed(workspaceID: "workspace-B", body: "done")
        XCTAssertEqual(newCommands, expectedActivation + expectedCompleted,
                       "finishUpdate must flush every held batch, in order, addressed to the NEW workspace — never dropped/coalesced, got \(newCommands)")
    }

    // Round 4 P0: a genuine source-identity switch (different transcript
    // path, not just a workspace re-tag) must stop/drain the OLD tailer
    // under the OLD record/workspace — and BEFORE the migration hold is
    // even enabled — so a legitimate final A line (already sitting in A's
    // fd when the switch begins) is attributed to and sent for workspace A
    // IMMEDIATELY, normally, never buried inside B's held batches (which
    // only flush after finishUpdate, by which point the phone would have
    // already seen A's cleanup).
    func testOldTailerDrainsAndAttributesToAWorkspaceBeforeMigrationHoldBeginsOnSourceSwitch() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexTranscriptSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcriptA = directory.appendingPathComponent("rollout-a.jsonl", isDirectory: false)
        let transcriptB = directory.appendingPathComponent("rollout-b.jsonl", isDirectory: false)
        try (makeCodexTaskLine(type: "task_started", turnID: "turn-a") + "\n")
            .write(to: transcriptA, atomically: true, encoding: .utf8)
        try (makeCodexTaskLine(type: "task_started", turnID: "turn-b") + "\n")
            .write(to: transcriptB, atomically: true, encoding: .utf8)

        let hub = AgentEventHub()
        let sender = RecordingCommandSender()
        let recordA = makeRecord(transcriptPath: transcriptA.path, workspaceID: "workspace-A")
        let session = CodexTranscriptSession(record: recordA, fileManager: .default, hub: hub, socketClient: sender)
        session.start()
        defer { session.stop() }

        XCTAssertTrue(waitUntil {
            sender.commands().contains("report_shell_state running --workspace_id=workspace-A")
        })
        let commandsBeforeSwitch = sender.commands()

        // Deterministic by construction, not by timing: this fires
        // synchronously, ON the session's own serial queue, AFTER
        // prepareUpdate has confirmed a genuine switch but BEFORE
        // tailer.stop() actually runs. Since we are already occupying that
        // queue, no pre-existing async file-event dispatch can possibly
        // have consumed this line first — it can ONLY be picked up by the
        // stop() call that runs immediately after this hook returns.
        session.beforeOldTailerStopForTesting = {
            let handle = try! FileHandle(forWritingTo: transcriptA)
            handle.seekToEndOfFile()
            handle.write((self.makeCodexTaskLine(type: "task_complete", turnID: "turn-a", message: "done-a") + "\n").data(using: .utf8)!)
            try! handle.close()
        }

        // Genuine source switch: DIFFERENT transcript path AND workspace,
        // via the SAME prepareUpdate/finishUpdate migration transaction.
        let recordB = makeRecord(transcriptPath: transcriptB.path, workspaceID: "workspace-B")
        session.prepareUpdate(record: recordB)

        // The A terminal must already be sent — normally, immediately, for
        // workspace A — BEFORE finishUpdate ever runs. If the drain instead
        // ran AFTER the hold was enabled, this would still be empty here
        // (buried in B's held batches) and only appear misattributed to
        // workspace B after finishUpdate.
        XCTAssertTrue(sender.commands().dropFirst(commandsBeforeSwitch.count).contains { $0.contains("workspace_id=workspace-A") },
                     "the OLD tailer's drained final A line must be sent immediately for workspace A, before finishUpdate, got \(sender.commands())")
        let expectedACompleted = CodexSidebarMessages.completed(workspaceID: "workspace-A", body: "done-a")
        XCTAssertEqual(Array(sender.commands().dropFirst(commandsBeforeSwitch.count).prefix(expectedACompleted.count)),
                       expectedACompleted,
                       "the drained A terminal's exact completed batch must be sent for workspace A, got \(sender.commands())")

        XCTAssertTrue(waitUntil {
            hub.fetch(workspaceID: "workspace-B", sessionID: "session", limit: 50).events.contains { $0.type == .thinking }
        }, "B's own bootstrap must establish Working from its OWN file")

        session.finishUpdate()

        let commandsAfterFinish = sender.commands()
        XCTAssertFalse(commandsAfterFinish.dropFirst(commandsBeforeSwitch.count + expectedACompleted.count).contains { $0.contains("workspace_id=workspace-A") },
                       "no A-addressed command may appear after the drained terminal, got \(commandsAfterFinish)")
        XCTAssertTrue(commandsAfterFinish.contains("report_shell_state running --workspace_id=workspace-B"),
                     "B's own genuine running state must still be reached, got \(commandsAfterFinish)")
    }

    // Round 4 P0: an authoritative A→B thread-identity change (e.g. an
    // app-server active-thread update) whose new rollout file does not
    // exist YET must still stop/drain A and keep retrying for B — never
    // silently keep tailing A forever because resolveTranscriptURL()'s
    // fallback chain (process tree / directory enumeration / a lingering
    // resumeThreadID=A) wrongly re-resolves back to A's own file. Uses an
    // ISOLATED sessions-directory injection (never the user's real
    // ~/.codex/sessions) so the enumeration fallback — and its threadID
    // gating — is genuinely exercised, not vacuously passing because A/B
    // simply aren't where the enumerator looks. B's own resolver TIMER
    // (never a second explicit update()) is what must attach it.
    func testDelayedRolloutIdentitySwitchStopsAAndRetriesUntilBAppearsWithNoALeak() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexTranscriptSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcriptA = directory.appendingPathComponent("rollout-thread-a.jsonl", isDirectory: false)
        try (makeCodexTaskLine(type: "task_started", turnID: "turn-a") + "\n")
            .write(to: transcriptA, atomically: true, encoding: .utf8)

        let hub = AgentEventHub()
        let recordA = makeRecord(transcriptPath: transcriptA.path, threadID: "thread-a", resumeThreadID: "thread-a", workspaceID: "workspace")
        let session = CodexTranscriptSession(record: recordA,
                                             fileManager: .default,
                                             hub: hub,
                                             sessionsDirectoryOverrideForTesting: directory)
        session.start()
        defer { session.stop() }

        XCTAssertTrue(waitUntil {
            hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 50).events.contains { $0.type == .thinking }
        })

        // The authoritative thread changed to B, but B's own rollout does
        // not exist yet — transcriptPath comes back nil (exactly the
        // updateAppServerActiveThread shape), while resumeThreadID still
        // names the OLD thread A. A's own rollout stays sitting right in
        // the enumerator's search directory the whole time.
        let recordBDelayed = AgentSessionRegistryRecord(version: 1,
                                                        vendor: "codex",
                                                        workspaceID: "workspace",
                                                        sessionID: "session",
                                                        panelID: "panel",
                                                        pid: Int32(ProcessInfo.processInfo.processIdentifier),
                                                        cwd: "/tmp",
                                                        createdAt: "2026-05-15T00:00:00Z",
                                                        transcriptPath: nil,
                                                        threadID: "thread-b",
                                                        resumeThreadID: "thread-a")
        session.update(record: recordBDelayed)

        // The switch (A stopped, new epoch, resolver armed) must have taken
        // effect: beginNewSourceEpoch WIPES the old epoch's buffered
        // history (that's the point — a genuinely new source starts with
        // a clean slate), so the only observable proof is the new
        // source-epoch boundary event itself, not an accumulating count.
        XCTAssertTrue(waitUntil {
            hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 200).events
                .contains { $0.eventID.hasPrefix("source-epoch:") }
        }, "the authoritative thread-identity change must reset the source epoch even though B's file does not exist yet")
        let snapshotAfterSwitch = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 200).events.map(\.eventID)

        // Real content appended to the OLD file A — must NEVER be
        // published. Checked across MORE than one resolver retry interval
        // (armed every second) — not just the instant after the switch —
        // so a delayed wrong-reattach via the enumerator (A's own file is
        // sitting right there, in-scope) is not missed either. The FULL
        // event-ID snapshot (not a count — the epoch reset already wiped
        // the old epoch, so there is nothing to "accumulate" against) must
        // be byte-for-byte unchanged.
        let handle = try FileHandle(forWritingTo: transcriptA)
        handle.seekToEndOfFile()
        handle.write((makeCodexTaskLine(type: "task_complete", turnID: "turn-a", message: "late-a") + "\n").data(using: .utf8)!)
        try handle.close()
        // Deterministic negative proof, no sleep: wait for at least 2 REAL
        // production resolver ticks (the same 1s timer, driven for real)
        // via the lock-protected test hook, then compare the FULL eventID
        // snapshot — never a blind fixed-duration guess.
        let ticksExpectation = XCTestExpectation(description: "resolver ticks while re-scanning for B")
        ticksExpectation.expectedFulfillmentCount = 2
        session.setAfterResolveAttemptHookForTesting { ticksExpectation.fulfill() }
        wait(for: [ticksExpectation], timeout: 5)
        session.setAfterResolveAttemptHookForTesting(nil)

        let snapshotAfterWait = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 200).events.map(\.eventID)
        XCTAssertEqual(snapshotAfterWait, snapshotAfterSwitch,
                      "content appended to the OLD file A must never be published once an authoritative B identity is known, got \(hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 200).events.map { ($0.type, $0.text) })")

        // B's rollout appears in the SAME isolated directory the
        // enumerator scans — no second update() call. The existing
        // resolver retry TIMER (armed by the switch above) must discover
        // and attach it on its own.
        let transcriptB = directory.appendingPathComponent("rollout-thread-b.jsonl", isDirectory: false)
        try (makeCodexTaskLine(type: "task_started", turnID: "turn-b") + "\n")
            .write(to: transcriptB, atomically: true, encoding: .utf8)

        XCTAssertTrue(waitUntil(timeout: 5) {
            hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 200).events.contains {
                $0.type == .thinking && $0.metadata?["turn_id"] == "turn-b"
            }
        }, "the resolver's own retry timer must discover and attach B once its rollout is created")

        // `$0.text == "late-a"` would be vacuous — a task_complete event
        // never carries its `message` argument as `.text` at all (and for
        // an untracked turn, publishWorkingTerminal may not even publish
        // anything), so that check could never fail regardless of a real
        // leak. The non-vacuous guarantee: NOTHING referencing A's
        // turn_id ("turn-a") may appear anywhere AFTER the switch
        // boundary, in ANY field, even after B successfully attaches.
        let eventsAfterBAttach = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 200).events
        let boundarySeq = try XCTUnwrap(eventsAfterBAttach.first { $0.eventID.hasPrefix("source-epoch:") }?.seq)
        XCTAssertFalse(eventsAfterBAttach.contains { $0.seq > boundarySeq && $0.metadata?["turn_id"] == "turn-a" },
                      "no A-turn content may appear anywhere after the boundary, even after B successfully attaches, got \(eventsAfterBAttach.map { ($0.type, $0.eventID, $0.metadata?["turn_id"]) })")
    }

    // The ORDINARY async update() path calls its own pre-stop helper
    // independently of prepareUpdate — not a shared, unbypassable core —
    // so it needs its OWN deterministic proof, not just an inference from
    // the prepareUpdate test above.
    func testOrdinaryUpdateAlsoDrainsAndAttributesToAWorkspaceBeforeSourceSwitch() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexTranscriptSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcriptA = directory.appendingPathComponent("rollout-a.jsonl", isDirectory: false)
        let transcriptB = directory.appendingPathComponent("rollout-b.jsonl", isDirectory: false)
        try (makeCodexTaskLine(type: "task_started", turnID: "turn-a") + "\n")
            .write(to: transcriptA, atomically: true, encoding: .utf8)
        try (makeCodexTaskLine(type: "task_started", turnID: "turn-b") + "\n")
            .write(to: transcriptB, atomically: true, encoding: .utf8)

        let hub = AgentEventHub()
        let sender = RecordingCommandSender()
        let recordA = makeRecord(transcriptPath: transcriptA.path, workspaceID: "workspace-A")
        let session = CodexTranscriptSession(record: recordA, fileManager: .default, hub: hub, socketClient: sender)
        session.start()
        defer { session.stop() }

        XCTAssertTrue(waitUntil {
            sender.commands().contains("report_shell_state running --workspace_id=workspace-A")
        })
        let commandsBeforeSwitch = sender.commands()

        session.beforeOldTailerStopForTesting = {
            let handle = try! FileHandle(forWritingTo: transcriptA)
            handle.seekToEndOfFile()
            handle.write((self.makeCodexTaskLine(type: "task_complete", turnID: "turn-a", message: "done-a") + "\n").data(using: .utf8)!)
            try! handle.close()
        }

        let recordB = makeRecord(transcriptPath: transcriptB.path, workspaceID: "workspace-B")
        session.update(record: recordB)

        let expectedACompleted = CodexSidebarMessages.completed(workspaceID: "workspace-A", body: "done-a")
        XCTAssertTrue(waitUntil {
            sender.commands().dropFirst(commandsBeforeSwitch.count).contains { $0.contains("workspace_id=workspace-A") }
        }, "the OLD tailer's drained final A line must be sent for workspace A, got \(sender.commands())")
        XCTAssertEqual(Array(sender.commands().dropFirst(commandsBeforeSwitch.count).prefix(expectedACompleted.count)),
                       expectedACompleted,
                       "the drained A terminal's exact completed batch must be sent for workspace A, got \(sender.commands())")

        XCTAssertTrue(waitUntil {
            hub.fetch(workspaceID: "workspace-B", sessionID: "session", limit: 50).events.contains { $0.type == .thinking }
        }, "B's own bootstrap must establish Working from its OWN file")
        XCTAssertFalse(sender.commands().dropFirst(commandsBeforeSwitch.count + expectedACompleted.count).contains { $0.contains("workspace_id=workspace-A") },
                       "no A-addressed command may appear after the drained terminal, got \(sender.commands())")
    }

    private func makeRecord(transcriptPath: String,
                            sessionID: String = "session",
                            threadID: String? = nil,
                            resumeThreadID: String? = nil,
                            workspaceID: String = "workspace") -> AgentSessionRegistryRecord {
        AgentSessionRegistryRecord(version: 1,
                                   vendor: "codex",
                                   workspaceID: workspaceID,
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
