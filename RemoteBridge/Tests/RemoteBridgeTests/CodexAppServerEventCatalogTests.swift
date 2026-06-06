import XCTest
@testable import RemoteBridge

final class CodexAppServerEventCatalogTests: XCTestCase {
    func testConversationFixtureMapsToAgentEventContract() {
        let events = EventSink()
        let runtime = Self.runtime(events: events)
        let connection = CodexAppServerConnection(sendLine: { _ in },
                                                  onNotification: runtime.handleNotification)

        for fixture in CodexAppServerEventFixture.conversation {
            connection.receiveLine(fixture.jsonLine)
        }

        let emitted = events.events()
        XCTAssertEqual(emitted.map(\.type), [
            .sessionStarted,
            .thinking,
            .userMessage,
            .assistantMessage,
            .assistantFinal,
        ])
        XCTAssertEqual(emitted.map { $0.payload?.objectValue?["kind"]?.stringValue }, [
            "thread_started",
            "turn_started",
            "user_message",
            "assistant_message",
            "turn_completed",
        ])
        XCTAssertEqual(emitted[0].text, "Headless Codex")
        XCTAssertEqual(emitted[0].metadata?["thread_id"], "thread-1")
        XCTAssertEqual(emitted[2].text, "Say hello.")
        XCTAssertEqual(emitted[2].toolCallID, "user-1")
        XCTAssertEqual(emitted[3].text, "Hello.")
        XCTAssertEqual(emitted[3].toolCallID, "msg-1")
    }

    func testAgentMessageDeltaFixtureDoesNotCreateChatBubble() {
        let events = EventSink()
        let runtime = Self.runtime(events: events)
        let connection = CodexAppServerConnection(sendLine: { _ in },
                                                  onNotification: runtime.handleNotification)

        connection.receiveLine(CodexAppServerEventFixture.agentMessageDelta.jsonLine)

        XCTAssertTrue(events.events().isEmpty)
    }

    func testCommandExecutionFixtureMapsToTerminalEventContract() {
        let events = EventSink()
        let runtime = Self.runtime(events: events)
        let connection = CodexAppServerConnection(sendLine: { _ in },
                                                  onNotification: runtime.handleNotification)

        for fixture in CodexAppServerEventFixture.commandExecution {
            connection.receiveLine(fixture.jsonLine)
        }

        let emitted = events.events()
        XCTAssertEqual(emitted.map(\.type), [.toolCall, .toolResult, .toolResult])
        XCTAssertEqual(emitted.map(\.name), ["command_execution", "terminal_stream", "command_execution"])
        XCTAssertEqual(emitted.map(\.toolCallID), ["cmd-1", "cmd-1", "cmd-1"])
        XCTAssertEqual(emitted[0].input, "pwd")
        XCTAssertEqual(emitted[0].payload?.objectValue?["kind"]?.stringValue, "command_execution_started")
        XCTAssertEqual(emitted[1].output, "/private/tmp/tidey-headless-codex-work-auth-test\n")
        XCTAssertEqual(emitted[1].payload?.objectValue?["kind"]?.stringValue, "terminal_stream")
        XCTAssertEqual(emitted[2].output, "/private/tmp/tidey-headless-codex-work-auth-test\n")
        XCTAssertEqual(emitted[2].payload?.objectValue?["kind"]?.stringValue, "command_execution_completed")
        XCTAssertEqual(emitted[2].metadata?["process_id"], "proc-1")
    }

    func testFileChangeFixtureMapsToPatchEventContract() {
        let events = EventSink()
        let runtime = Self.runtime(events: events)
        let connection = CodexAppServerConnection(sendLine: { _ in },
                                                  onNotification: runtime.handleNotification)

        for fixture in CodexAppServerEventFixture.fileChange {
            connection.receiveLine(fixture.jsonLine)
        }

        let emitted = events.events()
        XCTAssertEqual(emitted.map(\.type), [.toolCall, .toolCall, .toolResult])
        XCTAssertEqual(emitted.map(\.name), ["file_change", "file_change_patch", "file_change"])
        XCTAssertEqual(emitted.map(\.toolCallID), ["patch-1", "patch-1", "patch-1"])
        XCTAssertEqual(emitted[0].payload?.objectValue?["kind"]?.stringValue, "file_change_started")
        XCTAssertEqual(emitted[1].payload?.objectValue?["kind"]?.stringValue, "file_change_patch")
        XCTAssertEqual(emitted[2].payload?.objectValue?["kind"]?.stringValue, "file_change_completed")
    }

    func testApprovalFixturePublishesPromptAndDecisionReply() throws {
        let outbound = LineSink()
        var promptEnvelope: CodexAppServerInteractivePromptEnvelope?
        var resolvedEvent: AgentEvent?
        let connection = CodexAppServerConnection(
            sendLine: { outbound.append($0) },
            approvalContext: CodexAppServerApprovalContext(workspaceID: "workspace-1",
                                                           panelID: "panel-1",
                                                           sessionID: "session-1"),
            nextSequence: Self.sequenceProvider(),
            timestampProvider: { "2026-06-06T12:00:00.000Z" },
            onInteractivePrompt: { promptEnvelope = $0 },
            onInteractivePromptResolved: { resolvedEvent = $0 })

        connection.receiveLine(CodexAppServerEventFixture.commandApproval.jsonLine)

        let envelope = try XCTUnwrap(promptEnvelope)
        XCTAssertEqual(envelope.event.type, .interactivePrompt)
        XCTAssertEqual(envelope.prompt.vendor, "codex")
        XCTAssertEqual(envelope.prompt.source, "codex_command_approval")
        XCTAssertEqual(envelope.prompt.options.map(\.inputSequence), ["accept", "acceptForSession", "decline", "cancel"])

        let resolved = try connection.submitApproval(promptID: envelope.prompt.promptID,
                                                     targetIndex: 1)
        XCTAssertEqual(resolved.type, .interactivePromptResolved)
        XCTAssertEqual(resolvedEvent?.eventID, resolved.eventID)

        let response = try Self.object(from: outbound.lines()[0])
        XCTAssertEqual(response["id"]?.stringValue, "approval-1")
        XCTAssertEqual(response["result"]?.objectValue?["decision"]?.stringValue, "acceptForSession")
    }

    func testFailureFixtureMapsToVisibleAssistantMessage() {
        let events = EventSink()
        let runtime = Self.runtime(events: events)
        let connection = CodexAppServerConnection(sendLine: { _ in },
                                                  onNotification: runtime.handleNotification)

        for fixture in CodexAppServerEventFixture.failure {
            connection.receiveLine(fixture.jsonLine)
        }

        let emitted = events.events()
        XCTAssertEqual(emitted.map(\.type), [.assistantMessage, .assistantMessage])
        XCTAssertEqual(emitted.map { $0.payload?.objectValue?["kind"]?.stringValue }, ["error", "turn_failed"])
        XCTAssertEqual(emitted[0].text, "unexpected status 401 Unauthorized\nMissing bearer authentication")
        XCTAssertEqual(emitted[1].text, "turn failed\nrequest id: req-1")
    }

    private static func runtime(events: EventSink) -> CodexAppServerHeadlessRuntime {
        CodexAppServerHeadlessRuntime(
            context: CodexAppServerRuntimeContext(workspaceID: "workspace-1",
                                                  panelID: "panel-1",
                                                  sessionID: "session-1"),
            nextSequence: sequenceProvider(),
            timestampProvider: { "2026-06-06T12:00:00.000Z" },
            onAgentEvent: { events.append($0) })
    }

    private static func sequenceProvider() -> (String) -> Int {
        var seq = 100
        return { _ in
            seq += 1
            return seq
        }
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

private enum CodexAppServerEventFixture {
    case threadStarted
    case turnStarted
    case userMessageStarted
    case agentMessageDelta
    case agentMessageCompleted
    case commandStarted
    case commandOutputDelta
    case commandCompleted
    case fileChangeStarted
    case fileChangePatchUpdated
    case fileChangeCompleted
    case commandApproval
    case finalError
    case failedTurnCompleted
    case successfulTurnCompleted

    static let conversation: [Self] = [
        .threadStarted,
        .turnStarted,
        .userMessageStarted,
        .agentMessageDelta,
        .agentMessageCompleted,
        .successfulTurnCompleted,
    ]

    static let commandExecution: [Self] = [
        .commandStarted,
        .commandOutputDelta,
        .commandCompleted,
    ]

    static let fileChange: [Self] = [
        .fileChangeStarted,
        .fileChangePatchUpdated,
        .fileChangeCompleted,
    ]

    static let failure: [Self] = [
        .finalError,
        .failedTurnCompleted,
    ]

    var jsonLine: String {
        switch self {
        case .threadStarted:
            return #"{"method":"thread/started","params":{"thread":{"id":"thread-1","preview":"Headless Codex","name":null}}}"#
        case .turnStarted:
            return #"{"method":"turn/started","params":{"threadId":"thread-1","turn":{"id":"turn-1","items":[],"itemsView":{"type":"all"},"status":"running","error":null,"startedAt":1,"completedAt":null,"durationMs":null}}}"#
        case .userMessageStarted:
            return #"{"method":"item/started","params":{"threadId":"thread-1","turnId":"turn-1","item":{"type":"userMessage","id":"user-1","content":[{"type":"text","text":"Say hello.","text_elements":[]}]}}}"#
        case .agentMessageDelta:
            return #"{"method":"item/agentMessage/delta","params":{"threadId":"thread-1","turnId":"turn-1","itemId":"msg-1","delta":"Hello"}}"#
        case .agentMessageCompleted:
            return #"{"method":"item/completed","params":{"threadId":"thread-1","turnId":"turn-1","item":{"type":"agentMessage","id":"msg-1","text":"Hello."}}}"#
        case .commandStarted:
            return #"{"method":"item/started","params":{"threadId":"thread-1","turnId":"turn-1","item":{"type":"commandExecution","id":"cmd-1","command":"pwd","cwd":"/private/tmp/tidey-headless-codex-work-auth-test","processId":"proc-1","source":"agent","status":"running","commandActions":[],"aggregatedOutput":null,"exitCode":null,"durationMs":null}}}"#
        case .commandOutputDelta:
            return #"{"method":"item/commandExecution/outputDelta","params":{"threadId":"thread-1","turnId":"turn-1","itemId":"cmd-1","processId":"proc-1","delta":"/private/tmp/tidey-headless-codex-work-auth-test\n"}}"#
        case .commandCompleted:
            return #"{"method":"item/completed","params":{"threadId":"thread-1","turnId":"turn-1","item":{"type":"commandExecution","id":"cmd-1","command":"pwd","cwd":"/private/tmp/tidey-headless-codex-work-auth-test","processId":"proc-1","source":"agent","status":"completed","commandActions":[],"aggregatedOutput":"/private/tmp/tidey-headless-codex-work-auth-test\n","exitCode":0,"durationMs":42}}}"#
        case .fileChangeStarted:
            return #"{"method":"item/started","params":{"threadId":"thread-1","turnId":"turn-1","item":{"type":"fileChange","id":"patch-1","status":"running"}}}"#
        case .fileChangePatchUpdated:
            return #"{"method":"item/fileChange/patchUpdated","params":{"threadId":"thread-1","turnId":"turn-1","itemId":"patch-1","changes":[{"path":"README.md","kind":"update"}]}}"#
        case .fileChangeCompleted:
            return #"{"method":"item/completed","params":{"threadId":"thread-1","turnId":"turn-1","item":{"type":"fileChange","id":"patch-1","status":"completed","changes":[{"path":"README.md","kind":"update"}]}}}"#
        case .commandApproval:
            return #"{"id":"approval-1","method":"item/commandExecution/requestApproval","params":{"threadId":"thread-1","turnId":"turn-1","itemId":"cmd-1","startedAtMs":1786000000000,"approvalId":"approval-1","command":"curl https://example.com","cwd":"/Users/timfeng/GitHub/Tidey","reason":"Needs network.","networkApprovalContext":{"host":"example.com","protocol":"https"}}}"#
        case .finalError:
            return #"{"method":"error","params":{"error":{"message":"unexpected status 401 Unauthorized","additionalDetails":"Missing bearer authentication"},"willRetry":false,"threadId":"thread-1","turnId":"turn-1"}}"#
        case .failedTurnCompleted:
            return #"{"method":"turn/completed","params":{"threadId":"thread-1","turn":{"id":"turn-1","items":[],"itemsView":"notLoaded","status":"failed","error":{"message":"turn failed","additionalDetails":"request id: req-1"},"startedAt":1,"completedAt":2,"durationMs":1000}}}"#
        case .successfulTurnCompleted:
            return #"{"method":"turn/completed","params":{"threadId":"thread-1","turn":{"id":"turn-1","items":[],"itemsView":{"type":"all"},"status":"completed","error":null,"startedAt":1,"completedAt":2,"durationMs":1000}}}"#
        }
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
