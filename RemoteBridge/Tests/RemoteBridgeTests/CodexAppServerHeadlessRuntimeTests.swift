import XCTest
@testable import RemoteBridge

final class CodexAppServerHeadlessRuntimeTests: XCTestCase {
    func testLaunchConfigurationUsesDirectAppServerCommandOnly() {
        let config = CodexAppServerLaunchConfiguration.direct(workingDirectory: "/tmp/tidey-codex-test",
                                                              environment: ["CODEX_HOME": "/tmp/codex-home"])

        XCTAssertEqual(config.executablePath, "codex")
        XCTAssertEqual(config.arguments, ["app-server"])
        XCTAssertEqual(config.workingDirectory, "/tmp/tidey-codex-test")
        XCTAssertEqual(config.environment["CODEX_HOME"], "/tmp/codex-home")
        XCTAssertEqual(config.transport, .stdio)
        XCTAssertFalse(config.executablePath.contains("/Applications/Tidey.app"))
    }

    func testLaunchConfigurationCanUseUnixSocketSidecar() {
        let config = CodexAppServerLaunchConfiguration.unixSocket(codexExecutablePath: "/tmp/codex bin",
                                                                  socketPath: "/tmp/tidey codex/app.sock",
                                                                  workingDirectory: "/tmp/tidey work",
                                                                  environment: ["CODEX_HOME": "/tmp/codex home"])

        XCTAssertEqual(config.executablePath, "/tmp/codex bin")
        XCTAssertEqual(config.arguments, ["app-server", "--listen", "unix:///tmp/tidey codex/app.sock"])
        XCTAssertEqual(config.workingDirectory, "/tmp/tidey work")
        XCTAssertEqual(config.environment["CODEX_HOME"], "/tmp/codex home")
        XCTAssertEqual(config.transport, .unixSocket(path: "/tmp/tidey codex/app.sock"))
    }

    func testStartThreadAndTurnSendCodexAppServerRequests() throws {
        let outbound = LineSink()
        let runtime = Self.runtime()
        let connection = CodexAppServerConnection(sendLine: { outbound.append($0) })

        try runtime.startThread(on: connection,
                                cwd: "/Users/timfeng/GitHub/Tidey",
                                model: "gpt-5",
                                approvalPolicy: "on-request",
                                sandbox: .string("workspace-write"))
        try runtime.startTurn(on: connection,
                              threadID: "thread-1",
                              text: "fix the bridge",
                              cwd: "/Users/timfeng/GitHub/Tidey")

        let lines = outbound.lines()
        XCTAssertEqual(lines.count, 2)

        let startThread = try Self.object(from: lines[0])
        XCTAssertEqual(startThread["id"]?.intValue, 1)
        XCTAssertEqual(startThread["method"]?.stringValue, "thread/start")
        let threadParams = try XCTUnwrap(startThread["params"]?.objectValue)
        XCTAssertEqual(threadParams["cwd"]?.stringValue, "/Users/timfeng/GitHub/Tidey")
        XCTAssertEqual(threadParams["model"]?.stringValue, "gpt-5")
        XCTAssertEqual(threadParams["approvalPolicy"]?.stringValue, "on-request")
        XCTAssertEqual(threadParams["sandbox"]?.stringValue, "workspace-write")
        XCTAssertEqual(threadParams["ephemeral"]?.boolValue, true)

        let startTurn = try Self.object(from: lines[1])
        XCTAssertEqual(startTurn["id"]?.intValue, 2)
        XCTAssertEqual(startTurn["method"]?.stringValue, "turn/start")
        let turnParams = try XCTUnwrap(startTurn["params"]?.objectValue)
        XCTAssertEqual(turnParams["threadId"]?.stringValue, "thread-1")
        XCTAssertEqual(turnParams["cwd"]?.stringValue, "/Users/timfeng/GitHub/Tidey")
        let input = try XCTUnwrap(turnParams["input"]?.arrayValue?.first?.objectValue)
        XCTAssertEqual(input["type"]?.stringValue, "text")
        XCTAssertEqual(input["text"]?.stringValue, "fix the bridge")
        XCTAssertEqual(input["text_elements"]?.arrayValue?.count, 0)
    }

    func testServerNotificationsBecomeAgentEvents() throws {
        let events = EventSink()
        let runtime = Self.runtime(events: events)
        let connection = CodexAppServerConnection(sendLine: { _ in },
                                                  onNotification: runtime.handleNotification)

        connection.receiveLine("""
        {"method":"thread/started","params":{"thread":{"id":"thread-1","preview":"Build app-server runtime","name":null}}}
        """)
        connection.receiveLine("""
        {"method":"turn/started","params":{"threadId":"thread-1","turn":{"id":"turn-1","items":[],"itemsView":{"type":"all"},"status":"running","error":null,"startedAt":1,"completedAt":null,"durationMs":null}}}
        """)
        connection.receiveLine("""
        {"method":"item/agentMessage/delta","params":{"threadId":"thread-1","turnId":"turn-1","itemId":"msg-1","delta":"hello"}}
        """)
        connection.receiveLine("""
        {"method":"item/completed","params":{"threadId":"thread-1","turnId":"turn-1","item":{"type":"agentMessage","id":"msg-1","text":"hello"}}}
        """)
        connection.receiveLine("""
        {"method":"item/commandExecution/outputDelta","params":{"threadId":"thread-1","turnId":"turn-1","itemId":"cmd-1","delta":"stdout line\\n"}}
        """)
        connection.receiveLine("""
        {"method":"item/commandExecution/terminalInteraction","params":{"threadId":"thread-1","turnId":"turn-1","itemId":"cmd-1","processId":"proc-1","stdin":"y\\n"}}
        """)
        connection.receiveLine("""
        {"method":"item/fileChange/patchUpdated","params":{"threadId":"thread-1","turnId":"turn-1","itemId":"patch-1","changes":[]}}
        """)
        connection.receiveLine("""
        {"method":"turn/completed","params":{"threadId":"thread-1","turn":{"id":"turn-1","items":[],"itemsView":{"type":"all"},"status":"completed","error":null,"startedAt":1,"completedAt":2,"durationMs":1000}}}
        """)

        let emitted = events.events()
        XCTAssertEqual(emitted.map(\.type), [
            .sessionStarted,
            .thinking,
            .assistantMessage,
            .toolResult,
            .toolCall,
            .toolResult,
            .assistantFinal,
        ])
        XCTAssertEqual(emitted[0].text, "Build app-server runtime")
        XCTAssertEqual(emitted[0].metadata?["thread_id"], "thread-1")
        XCTAssertEqual(emitted[2].text, "hello")
        XCTAssertEqual(emitted[2].toolCallID, "msg-1")
        XCTAssertEqual(emitted[3].name, "terminal_stream")
        XCTAssertEqual(emitted[3].output, "stdout line\n")
        XCTAssertEqual(emitted[3].payload?.objectValue?["kind"]?.stringValue, "terminal_stream")
        XCTAssertEqual(emitted[4].name, "terminal_interaction")
        XCTAssertEqual(emitted[4].input, "y\n")
        XCTAssertEqual(emitted[4].metadata?["process_id"], "proc-1")
        XCTAssertEqual(emitted[5].name, "file_change_patch")
        XCTAssertEqual(emitted[6].type, .assistantFinal)
    }

    func testAgentMessageDeltasAreNotPublishedAsChatBubbles() throws {
        let events = EventSink()
        let runtime = Self.runtime(events: events)
        let connection = CodexAppServerConnection(sendLine: { _ in },
                                                  onNotification: runtime.handleNotification)

        connection.receiveLine("""
        {"method":"item/agentMessage/delta","params":{"threadId":"thread-1","turnId":"turn-1","itemId":"msg-1","delta":"partial"}}
        """)

        XCTAssertTrue(events.events().isEmpty)
    }

    func testServerWarningsAndFinalErrorsBecomeVisibleMessages() throws {
        let events = EventSink()
        let runtime = Self.runtime(events: events)
        let connection = CodexAppServerConnection(sendLine: { _ in },
                                                  onNotification: runtime.handleNotification)

        connection.receiveLine("""
        {"method":"warning","params":{"threadId":"thread-1","message":"Falling back from WebSockets to HTTPS transport."}}
        """)
        connection.receiveLine("""
        {"method":"error","params":{"error":{"message":"Reconnecting... 2/5","additionalDetails":"temporary network issue"},"willRetry":true,"threadId":"thread-1","turnId":"turn-1"}}
        """)
        connection.receiveLine("""
        {"method":"error","params":{"error":{"message":"unexpected status 401 Unauthorized","additionalDetails":"Missing bearer authentication"},"willRetry":false,"threadId":"thread-1","turnId":"turn-1"}}
        """)
        connection.receiveLine("""
        {"method":"turn/completed","params":{"threadId":"thread-1","turn":{"id":"turn-1","items":[],"itemsView":"notLoaded","status":"failed","error":{"message":"turn failed","additionalDetails":"request id: req-1"},"startedAt":1,"completedAt":2,"durationMs":1000}}}
        """)

        let emitted = events.events()
        XCTAssertEqual(emitted.map(\.type), [.assistantMessage, .assistantMessage, .assistantMessage])
        XCTAssertEqual(emitted.map { $0.payload?.objectValue?["kind"]?.stringValue }, ["warning", "error", "turn_failed"])
        XCTAssertEqual(emitted[0].text, "Falling back from WebSockets to HTTPS transport.")
        XCTAssertEqual(emitted[1].text, "unexpected status 401 Unauthorized\nMissing bearer authentication")
        XCTAssertEqual(emitted[2].text, "turn failed\nrequest id: req-1")
    }

    func testItemLifecycleNotificationsBecomeConversationAndToolEvents() {
        let events = EventSink()
        let runtime = Self.runtime(events: events)
        let connection = CodexAppServerConnection(sendLine: { _ in },
                                                  onNotification: runtime.handleNotification)

        connection.receiveLine("""
        {"method":"item/started","params":{"threadId":"thread-1","turnId":"turn-1","item":{"type":"userMessage","id":"user-1","content":[{"type":"text","text":"run tests","text_elements":[]}]}}}
        """)
        connection.receiveLine("""
        {"method":"item/started","params":{"threadId":"thread-1","turnId":"turn-1","item":{"type":"commandExecution","id":"cmd-1","command":"swift test","cwd":"/Users/timfeng/GitHub/Tidey","processId":"proc-1","source":"agent","status":"running","commandActions":[],"aggregatedOutput":null,"exitCode":null,"durationMs":null}}}
        """)
        connection.receiveLine("""
        {"method":"item/completed","params":{"threadId":"thread-1","turnId":"turn-1","item":{"type":"commandExecution","id":"cmd-1","command":"swift test","cwd":"/Users/timfeng/GitHub/Tidey","processId":"proc-1","source":"agent","status":"completed","commandActions":[],"aggregatedOutput":"ok","exitCode":0,"durationMs":42}}}
        """)

        let emitted = events.events()
        XCTAssertEqual(emitted.map(\.type), [.userMessage, .toolCall, .toolResult])
        XCTAssertEqual(emitted[0].text, "run tests")
        XCTAssertEqual(emitted[1].name, "command_execution")
        XCTAssertEqual(emitted[1].input, "swift test")
        XCTAssertEqual(emitted[1].toolCallID, "cmd-1")
        XCTAssertEqual(emitted[2].output, "ok")
        XCTAssertEqual(emitted[2].metadata?["process_id"], "proc-1")
    }

    private static func runtime() -> CodexAppServerHeadlessRuntime {
        var seq = 100
        return CodexAppServerHeadlessRuntime(
            context: CodexAppServerRuntimeContext(workspaceID: "workspace-1",
                                                  panelID: "panel-1",
                                                  sessionID: "session-1"),
            nextSequence: { _ in
                seq += 1
                return seq
            },
            timestampProvider: { "2026-06-05T12:00:00.000Z" },
            onAgentEvent: { _ in })
    }

    private static func runtime(events: EventSink) -> CodexAppServerHeadlessRuntime {
        var seq = 100
        return CodexAppServerHeadlessRuntime(
            context: CodexAppServerRuntimeContext(workspaceID: "workspace-1",
                                                  panelID: "panel-1",
                                                  sessionID: "session-1"),
            nextSequence: { _ in
                seq += 1
                return seq
            },
            timestampProvider: { "2026-06-05T12:00:00.000Z" },
            onAgentEvent: { events.append($0) })
    }

    private static func object(from line: String,
                               file: StaticString = #filePath,
                               line sourceLine: UInt = #line) throws -> [String: JSONValue] {
        let data = try XCTUnwrap(line.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
                                 file: file,
                                 line: sourceLine)
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        return try XCTUnwrap(value.objectValue, file: file, line: sourceLine)
    }
}

private final class EventSink: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [AgentEvent] = []

    func append(_ event: AgentEvent) {
        lock.lock()
        storage.append(event)
        lock.unlock()
    }

    func events() -> [AgentEvent] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private final class LineSink: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func append(_ line: String) {
        lock.lock()
        storage.append(line)
        lock.unlock()
    }

    func lines() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
