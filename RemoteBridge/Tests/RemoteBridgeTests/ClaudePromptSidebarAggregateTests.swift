import XCTest
@testable import RemoteBridge

// Regression for the sidebar staying "Running" after a Claude turn that asked
// an AskUserQuestion ended (workspace MV, 2026-09-30): the Bridge wrote an
// OWNER-LESS "running" when the question resolved, and Tidey's aggregate
// ranks that above the session's own Idle. Drives the production path: the
// transcript tail of a ClaudeTranscriptSession (which publishes the prompt
// sidebar messages) plus the AgentLifecycleSidebarSyncer that mirrors the
// session lifecycle, both writing to one recorded Tidey socket.
final class ClaudePromptSidebarAggregateTests: XCTestCase {
    private var directory: URL!
    private var transcriptURL: URL!
    private var hub: AgentEventHub!
    private var store: AgentSessionLifecycleStore!
    private var socket: RecordingTideySocket!
    private var session: ClaudeTranscriptSession!
    private var syncer: AgentLifecycleSidebarSyncer!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudePromptSidebarAggregateTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        transcriptURL = directory.appendingPathComponent("session.jsonl", isDirectory: false)
        let hookJournalURL = directory.appendingPathComponent("claude-hooks-session.jsonl", isDirectory: false)
        try Data().write(to: transcriptURL)
        try Data().write(to: hookJournalURL)

        hub = AgentEventHub()
        store = AgentSessionLifecycleStore()
        socket = RecordingTideySocket()
        session = ClaudeTranscriptSession(record: record, fileManager: .default, hub: hub, socketClient: socket)
        session.lifecycleStoreForTesting = store
        session.hookJournalURLOverrideForTesting = hookJournalURL
        syncer = AgentLifecycleSidebarSyncer(store: store,
                                             socketIdentityProvider: { "tidey-socket-1" },
                                             commandSender: { [socket] command in try socket!.send(command: command) })
        syncer.attach()
    }

    override func tearDown() {
        session?.stop()
        session = nil
        syncer = nil
        try? FileManager.default.removeItem(at: directory)
    }

    private var record: AgentSessionRegistryRecord {
        AgentSessionRegistryRecord(version: 1,
                                   vendor: "claude",
                                   workspaceID: "workspace",
                                   sessionID: "session",
                                   panelID: "panel",
                                   pid: Int32(ProcessInfo.processInfo.processIdentifier),
                                   cwd: "/tmp",
                                   createdAt: "2026-09-30T00:00:00Z",
                                   transcriptPath: transcriptURL?.path)
    }

    func testAnsweredQuestionThenTurnEndAggregatesToIdleWithNoOwnerlessShellStateWrite() throws {
        try startSessionAndWaitForTail()
        syncer.sync(records: [record])

        try append(#"{"type":"user","uuid":"u1","sessionId":"session","version":"2.1.0","message":{"role":"user","content":"make the MV"}}"#)
        waitForState(.working)

        try append(askLine(uuid: "a1", toolCallID: "ask-1", parentUuid: "u1"))
        waitForState(.needsInput)
        XCTAssertTrue(waitUntil { self.socket.commands().contains { $0.contains("notification.create") } },
                      "the question still raises its notification")
        XCTAssertEqual(aggregate(), "Needs input")

        try append(#"{"type":"user","uuid":"u2","parentUuid":"a1","sessionId":"session","version":"2.1.0","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"ask-1","content":"Use current file"}]}}"#)
        waitForState(.working)
        XCTAssertTrue(waitUntil {
            self.hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 50)
                .events.contains { $0.type == .interactivePromptResolved }
        })
        XCTAssertEqual(aggregate(), "Running")

        try append(#"{"type":"system","subtype":"turn_duration","uuid":"s1","parentUuid":"u2","sessionId":"session","version":"2.1.0","durationMs":1200}"#)
        waitForState(.idle)
        store.waitForDeliveriesForTesting()

        let ownerless = socket.commands().filter(Self.isOwnerlessShellStateWrite)
        XCTAssertEqual(ownerless, [], "Claude must never write the owner-less shell_state cell")
        XCTAssertEqual(aggregate(), "Idle", "commands: \(socket.commands())")
    }

    // MARK: - Harness

    private func startSessionAndWaitForTail() throws {
        session.start()
        for attempt in 1...10 {
            try append(#"{"type":"user","uuid":"probe-\#(attempt)","sessionId":"session","version":"2.1.0","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"probe-\#(attempt)","content":"probe"}]}}"#)
            if waitUntil(timeout: 0.5, {
                self.hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 500)
                    .events.contains { $0.toolCallID == "probe-\(attempt)" }
            }) {
                return
            }
        }
        XCTFail("transcript tailer never became active")
    }

    private func append(_ line: String) throws {
        let handle = try FileHandle(forWritingTo: transcriptURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((line + "\n").utf8))
        try handle.close()
    }

    private func askLine(uuid: String, toolCallID: String, parentUuid: String) -> String {
        let object: [String: Any] = [
            "type": "assistant",
            "uuid": uuid,
            "parentUuid": parentUuid,
            "sessionId": "session",
            "version": "2.1.0",
            "message": [
                "role": "assistant",
                "stop_reason": "tool_use",
                "content": [[
                    "type": "tool_use",
                    "id": toolCallID,
                    "name": "AskUserQuestion",
                    "input": ["questions": [[
                        "question": "Which path should Claude use?",
                        "header": "Choose a path",
                        "multiSelect": false,
                        "options": [["label": "Use current file"], ["label": "Cancel"]],
                    ]]],
                ]],
            ],
        ]
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private func waitForState(_ expected: AgentSessionDisplayState,
                              file: StaticString = #filePath,
                              line: UInt = #line) {
        let identity = AgentSessionLifecycleIdentity(workspaceID: "workspace", panelID: "panel", sessionID: "session")
        XCTAssertTrue(waitUntil { self.store.snapshot(identity)?.state == expected },
                      "expected \(expected)", file: file, line: line)
        store.waitForDeliveriesForTesting()
    }

    private func waitUntil(timeout: TimeInterval = 3, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return true
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return condition()
    }

    // MARK: - Tidey status aggregate

    /// Replays the recorded socket commands through Tidey's shell_state model
    /// (sources/TideyNotificationStore.m: one cell per owner, "" for the
    /// owner-less writer; an owner-less clear removes every cell; the shown
    /// value is the highest rank, Needs input > Running > Idle).
    private func aggregate() -> String? {
        var cells = [String: String]()
        for command in socket.commands() {
            if let object = Self.jsonObject(command) {
                guard object["workspace_id"] == "workspace" else { continue }
                let owner = object["session_id"] ?? object["panel_id"] ?? ""
                switch object["action"] {
                case "report_shell_state":
                    cells[owner] = Self.display(object["state"] ?? "")
                case "set_status" where object["key"] == "shell_state":
                    cells[owner] = object["value"]
                case "clear_status" where object["key"] == "shell_state":
                    if owner.isEmpty { cells.removeAll() } else { cells.removeValue(forKey: owner) }
                default:
                    break
                }
            } else if command.hasPrefix("report_shell_state ") {
                let parts = command.split(separator: " ").map(String.init)
                guard parts.contains("--workspace_id=workspace") else { continue }
                let owner = parts.first { $0.hasPrefix("--session_id=") }.map { String($0.dropFirst(13)) } ?? ""
                cells[owner] = Self.display(parts[1])
            }
        }
        let rank = ["Needs input": 3, "Running": 2]
        return cells.values.max { (rank[$0] ?? 1) < (rank[$1] ?? 1) }
    }

    private static func display(_ state: String) -> String {
        switch state {
        case "running": return "Running"
        case "needs_input": return "Needs input"
        default: return "Idle"
        }
    }

    private static func jsonObject(_ command: String) -> [String: String]? {
        guard command.hasPrefix("{"),
              let object = try? JSONSerialization.jsonObject(with: Data(command.utf8)) as? [String: Any] else {
            return nil
        }
        return object.compactMapValues { $0 as? String }
    }

    private static func isOwnerlessShellStateWrite(_ command: String) -> Bool {
        if let object = jsonObject(command) {
            let isWrite = object["action"] == "report_shell_state"
                || (object["action"] == "set_status" && object["key"] == "shell_state")
            return isWrite && object["session_id"] == nil && object["panel_id"] == nil
        }
        return command.hasPrefix("report_shell_state ")
            && !command.contains("--session_id=") && !command.contains("--panel_id=")
    }
}

private final class RecordingTideySocket: TideyCommandSending {
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
