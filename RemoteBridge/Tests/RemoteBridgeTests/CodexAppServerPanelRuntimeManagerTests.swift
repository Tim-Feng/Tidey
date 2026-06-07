import XCTest
@testable import RemoteBridge

final class CodexAppServerPanelRuntimeManagerTests: XCTestCase {
    func testSyncAttachesRegisteredCodexAppServerPanelAndSubmitsQueuedTurn() throws {
        let connector = PanelRuntimeFakeTransportConnector()
        let runner = PanelRuntimeFailingProcessRunner()
        let eventHub = AgentEventHub()
        let manager = CodexAppServerPanelRuntimeManager(
            sessionFactory: CodexAppServerRuntimeSessionFactory(processRunner: runner,
                                                                transportConnector: connector),
            eventHub: eventHub,
            timestampProvider: { "2026-06-07T00:00:00.000Z" }
        )

        manager.sync(records: [Self.appServerRecord()])

        XCTAssertTrue(runner.startedConfigurations.isEmpty)
        XCTAssertEqual(connector.connectedModes, [.unixSocket(path: "/private/tmp/tidey-codex/app.sock")])
        let transport = try XCTUnwrap(connector.transport)
        try Self.acknowledgeInitialize(from: transport)

        let response = try manager.handleChatSubmit(BridgeRequest(
            id: "chat-1",
            action: "chat_submit",
            params: [
                "workspace_id": .string("workspace-1"),
                "panel_id": .string("panel-1"),
                "vendor": .string("codex"),
                "session_id": .string("session-1"),
                "message": .string("Say hello."),
            ]))

        XCTAssertEqual(response?.ok, true)
        let loadedList = try Self.object(from: transport.sentLines().last ?? "")
        XCTAssertEqual(loadedList["method"]?.stringValue, "thread/loaded/list")
        try Self.respond(on: transport, request: loadedList, result: .object([
            "data": .array([]),
        ]))

        let threadStart = try Self.object(from: transport.sentLines().last ?? "")
        XCTAssertEqual(threadStart["method"]?.stringValue, "thread/start")
        try Self.respondToLastRequest(on: transport, result: .object([
            "thread": .object(["id": .string("thread-1")]),
        ]))

        let turnStart = try Self.object(from: transport.sentLines().last ?? "")
        XCTAssertEqual(turnStart["method"]?.stringValue, "turn/start")
        XCTAssertEqual(turnStart["params"]?.objectValue?["threadId"]?.stringValue, "thread-1")
        let input = turnStart["params"]?.objectValue?["input"]?.arrayValue?.first?.objectValue
        XCTAssertEqual(input?["text"]?.stringValue, "Say hello.")
    }

    func testAdoptsLoadedMacThreadBeforeSubmittingQueuedTurn() throws {
        let connector = PanelRuntimeFakeTransportConnector()
        let runner = PanelRuntimeFailingProcessRunner()
        let eventHub = AgentEventHub()
        let manager = CodexAppServerPanelRuntimeManager(
            sessionFactory: CodexAppServerRuntimeSessionFactory(processRunner: runner,
                                                                transportConnector: connector),
            eventHub: eventHub,
            timestampProvider: { "2026-06-07T00:00:00.000Z" }
        )

        manager.sync(records: [Self.appServerRecord()])
        let transport = try XCTUnwrap(connector.transport)
        try Self.acknowledgeInitialize(from: transport)

        let response = try manager.handleChatSubmit(BridgeRequest(
            id: "chat-1",
            action: "chat_submit",
            params: [
                "workspace_id": .string("workspace-1"),
                "panel_id": .string("panel-1"),
                "vendor": .string("codex"),
                "session_id": .string("session-1"),
                "message": .string("Say hello from Remote."),
            ]))

        XCTAssertEqual(response?.ok, true)
        let loadedList = try Self.object(from: transport.sentLines().last ?? "")
        XCTAssertEqual(loadedList["method"]?.stringValue, "thread/loaded/list")
        try Self.respond(on: transport, request: loadedList, result: .object([
            "data": .array([.string("mac-thread-1")]),
        ]))

        let resumeThread = try Self.object(from: transport.sentLines().last ?? "")
        XCTAssertEqual(resumeThread["method"]?.stringValue, "thread/resume")
        XCTAssertEqual(resumeThread["params"]?.objectValue?["threadId"]?.stringValue, "mac-thread-1")
        try Self.respond(on: transport, request: resumeThread, result: .object([
            "thread": .object(["id": .string("mac-thread-1")]),
        ]))

        let turnStart = try Self.object(from: transport.sentLines().last ?? "")
        XCTAssertEqual(turnStart["method"]?.stringValue, "turn/start")
        XCTAssertEqual(turnStart["params"]?.objectValue?["threadId"]?.stringValue, "mac-thread-1")
        XCTAssertFalse(transport.sentLines().contains { line in
            (try? Self.object(from: line))?["method"]?.stringValue == "thread/start"
        })
    }

    func testSubsequentRemoteTurnsReuseAdoptedMacThread() throws {
        let connector = PanelRuntimeFakeTransportConnector()
        let runner = PanelRuntimeFailingProcessRunner()
        let eventHub = AgentEventHub()
        let manager = CodexAppServerPanelRuntimeManager(
            sessionFactory: CodexAppServerRuntimeSessionFactory(processRunner: runner,
                                                                transportConnector: connector),
            eventHub: eventHub,
            timestampProvider: { "2026-06-07T00:00:00.000Z" }
        )

        manager.sync(records: [Self.appServerRecord()])
        let transport = try XCTUnwrap(connector.transport)
        try Self.acknowledgeInitialize(from: transport)

        _ = try manager.handleChatSubmit(Self.chatSubmitRequest(id: "chat-1", message: "First Remote message."))
        let loadedList = try Self.object(from: transport.sentLines().last ?? "")
        XCTAssertEqual(loadedList["method"]?.stringValue, "thread/loaded/list")
        try Self.respond(on: transport, request: loadedList, result: .object([
            "data": .array([.string("mac-thread-1")]),
        ]))

        let resumeThread = try Self.object(from: transport.sentLines().last ?? "")
        XCTAssertEqual(resumeThread["method"]?.stringValue, "thread/resume")
        XCTAssertEqual(resumeThread["params"]?.objectValue?["threadId"]?.stringValue, "mac-thread-1")
        try Self.respond(on: transport, request: resumeThread, result: .object([
            "thread": .object(["id": .string("mac-thread-1")]),
        ]))

        let firstTurnStart = try Self.object(from: transport.sentLines().last ?? "")
        XCTAssertEqual(firstTurnStart["method"]?.stringValue, "turn/start")
        XCTAssertEqual(firstTurnStart["params"]?.objectValue?["threadId"]?.stringValue, "mac-thread-1")

        _ = try manager.handleChatSubmit(Self.chatSubmitRequest(id: "chat-2", message: "Second Remote message."))
        let secondTurnStart = try Self.object(from: transport.sentLines().last ?? "")
        XCTAssertEqual(secondTurnStart["method"]?.stringValue, "turn/start")
        XCTAssertEqual(secondTurnStart["params"]?.objectValue?["threadId"]?.stringValue, "mac-thread-1")
        let input = secondTurnStart["params"]?.objectValue?["input"]?.arrayValue?.first?.objectValue
        XCTAssertEqual(input?["text"]?.stringValue, "Second Remote message.")

        let sentMethods = transport.sentLines().compactMap { line in
            (try? Self.object(from: line))?["method"]?.stringValue
        }
        XCTAssertEqual(sentMethods.filter { $0 == "thread/loaded/list" }.count, 1)
        XCTAssertFalse(sentMethods.contains("thread/start"))
    }

    func testSyncResumesLoadedMacThreadBeforeRemoteSubmit() throws {
        let connector = PanelRuntimeFakeTransportConnector()
        let runner = PanelRuntimeFailingProcessRunner()
        let eventHub = AgentEventHub()
        let manager = CodexAppServerPanelRuntimeManager(
            sessionFactory: CodexAppServerRuntimeSessionFactory(processRunner: runner,
                                                                transportConnector: connector),
            eventHub: eventHub,
            timestampProvider: { "2026-06-07T00:00:00.000Z" }
        )

        manager.sync(records: [Self.appServerRecord()])
        let transport = try XCTUnwrap(connector.transport)
        try Self.acknowledgeInitialize(from: transport)

        let loadedList = try Self.object(from: transport.sentLines().last ?? "")
        XCTAssertEqual(loadedList["method"]?.stringValue, "thread/loaded/list")
        try Self.respond(on: transport, request: loadedList, result: .object([
            "data": .array([.string("mac-thread-1")]),
        ]))

        let resumeThread = try Self.object(from: transport.sentLines().last ?? "")
        XCTAssertEqual(resumeThread["method"]?.stringValue, "thread/resume")
        XCTAssertEqual(resumeThread["params"]?.objectValue?["threadId"]?.stringValue, "mac-thread-1")
        try Self.respond(on: transport, request: resumeThread, result: .object([
            "thread": .object(["id": .string("mac-thread-1")]),
        ]))

        transport.emitLine("""
        {"method":"turn/started","params":{"threadId":"mac-thread-1","turn":{"id":"mac-turn-1","items":[],"itemsView":{"type":"all"},"status":"running","error":null,"startedAt":1,"completedAt":null,"durationMs":null}}}
        """)
        let events = eventHub.fetch(workspaceID: "workspace-1", limit: 10).events
        XCTAssertTrue(events.contains { event in
            event.type == .thinking && event.sessionID == "session-1"
        })
    }

    func testSyncRetriesLoadedMacThreadSubscriptionAfterInitialEmptyList() throws {
        let connector = PanelRuntimeFakeTransportConnector()
        let runner = PanelRuntimeFailingProcessRunner()
        let eventHub = AgentEventHub()
        let manager = CodexAppServerPanelRuntimeManager(
            sessionFactory: CodexAppServerRuntimeSessionFactory(processRunner: runner,
                                                                transportConnector: connector),
            eventHub: eventHub,
            timestampProvider: { "2026-06-07T00:00:00.000Z" }
        )

        manager.sync(records: [Self.appServerRecord()])
        let transport = try XCTUnwrap(connector.transport)
        try Self.acknowledgeInitialize(from: transport)

        let initialLoadedList = try Self.object(from: transport.sentLines().last ?? "")
        XCTAssertEqual(initialLoadedList["method"]?.stringValue, "thread/loaded/list")
        try Self.respond(on: transport, request: initialLoadedList, result: .object([
            "data": .array([]),
        ]))

        let sentLineCountBeforeRetry = transport.sentLines().count
        manager.sync(records: [Self.appServerRecord()])

        let retriedLoadedList = try Self.object(from: transport.sentLines().last ?? "")
        XCTAssertGreaterThan(transport.sentLines().count, sentLineCountBeforeRetry)
        XCTAssertEqual(retriedLoadedList["method"]?.stringValue, "thread/loaded/list")
        try Self.respond(on: transport, request: retriedLoadedList, result: .object([
            "data": .array([.string("mac-thread-1")]),
        ]))

        let resumeThread = try Self.object(from: transport.sentLines().last ?? "")
        XCTAssertEqual(resumeThread["method"]?.stringValue, "thread/resume")
        XCTAssertEqual(resumeThread["params"]?.objectValue?["threadId"]?.stringValue, "mac-thread-1")
    }

    func testBackgroundLoadedMacThreadResumeFailureDoesNotPublishOrRetrySameThread() throws {
        let connector = PanelRuntimeFakeTransportConnector()
        let runner = PanelRuntimeFailingProcessRunner()
        let eventHub = AgentEventHub()
        let manager = CodexAppServerPanelRuntimeManager(
            sessionFactory: CodexAppServerRuntimeSessionFactory(processRunner: runner,
                                                                transportConnector: connector),
            eventHub: eventHub,
            timestampProvider: { "2026-06-07T00:00:00.000Z" }
        )

        manager.sync(records: [Self.appServerRecord()])
        let transport = try XCTUnwrap(connector.transport)
        try Self.acknowledgeInitialize(from: transport)

        let loadedList = try Self.object(from: transport.sentLines().last ?? "")
        XCTAssertEqual(loadedList["method"]?.stringValue, "thread/loaded/list")
        try Self.respond(on: transport, request: loadedList, result: .object([
            "data": .array([.string("mac-thread-no-rollout")]),
        ]))

        let resumeThread = try Self.object(from: transport.sentLines().last ?? "")
        XCTAssertEqual(resumeThread["method"]?.stringValue, "thread/resume")
        XCTAssertEqual(resumeThread["params"]?.objectValue?["threadId"]?.stringValue, "mac-thread-no-rollout")
        try Self.respondError(on: transport,
                              request: resumeThread,
                              code: -32000,
                              message: "no rollout found for thread id mac-thread-no-rollout")

        let eventsAfterFailure = eventHub.fetch(workspaceID: "workspace-1", limit: 20).events
        XCTAssertFalse(eventsAfterFailure.contains { event in
            event.payload?.objectValue?["kind"]?.stringValue == "bridge_error" ||
            event.text?.contains("failed to resume Mac thread") == true
        })

        manager.sync(records: [Self.appServerRecord()])
        let retriedLoadedList = try Self.object(from: transport.sentLines().last ?? "")
        XCTAssertEqual(retriedLoadedList["method"]?.stringValue, "thread/loaded/list")
        try Self.respond(on: transport, request: retriedLoadedList, result: .object([
            "data": .array([.string("mac-thread-no-rollout")]),
        ]))

        let sentMethods = transport.sentLines().compactMap { line in
            (try? Self.object(from: line))?["method"]?.stringValue
        }
        XCTAssertEqual(sentMethods.filter { $0 == "thread/resume" }.count, 1)
        XCTAssertEqual(sentMethods.filter { $0 == "thread/start" }.count, 0)
    }

    func testSubmitInteractivePromptRepliesToPanelAppServerApprovalRequest() throws {
        let connector = PanelRuntimeFakeTransportConnector()
        let eventHub = AgentEventHub()
        let manager = CodexAppServerPanelRuntimeManager(
            sessionFactory: CodexAppServerRuntimeSessionFactory(processRunner: PanelRuntimeFailingProcessRunner(),
                                                                transportConnector: connector),
            eventHub: eventHub,
            timestampProvider: { "2026-06-07T00:00:00.000Z" }
        )
        manager.sync(records: [Self.appServerRecord()])
        let transport = try XCTUnwrap(connector.transport)
        try Self.acknowledgeInitialize(from: transport)

        transport.emitLine("""
        {"id":"approval-1","method":"item/commandExecution/requestApproval","params":{"threadId":"thread-1","turnId":"turn-1","itemId":"cmd-1","command":"curl https://example.com","reason":"Needs network."}}
        """)
        let promptEvent = try XCTUnwrap(eventHub.fetch(workspaceID: "workspace-1", limit: 10).events.first {
            $0.type == .interactivePrompt
        })
        let promptID = try XCTUnwrap(promptEvent.payload?.objectValue?["prompt_id"]?.stringValue)

        let response = try manager.handleSubmitInteractivePrompt(BridgeRequest(
            id: "submit-approval",
            action: "submit_interactive_prompt",
            params: [
                "workspace_id": .string("workspace-1"),
                "panel_id": .string("panel-1"),
                "prompt_id": .string(promptID),
                "target_index": .number(1),
            ]))

        XCTAssertEqual(response?.ok, true)
        let reply = try Self.object(from: transport.sentLines().last ?? "")
        XCTAssertEqual(reply["id"]?.stringValue, "approval-1")
        XCTAssertEqual(reply["result"]?.objectValue?["decision"]?.stringValue, "decline")
    }

    private static func appServerRecord() -> AgentSessionRegistryRecord {
        AgentSessionRegistryRecord(version: 1,
                                   vendor: "codex",
                                   workspaceID: "workspace-1",
                                   sessionID: "session-1",
                                   panelID: "panel-1",
                                   pid: 1234,
                                   cwd: "/Users/timfeng/GitHub/Tidey",
                                   createdAt: "2026-06-07T00:00:00Z",
                                   transcriptPath: nil,
                                   tmuxPaneID: "%1",
                                   tmuxSocketPath: "/private/tmp/tmux-501/default",
                                   runtime: "codex_app_server",
                                   appServerSocket: "/private/tmp/tidey-codex/app.sock",
                                   appServerPID: 2345,
                                   remoteTUIPID: 3456)
    }

    private static func chatSubmitRequest(id: String, message: String) -> BridgeRequest {
        BridgeRequest(
            id: id,
            action: "chat_submit",
            params: [
                "workspace_id": .string("workspace-1"),
                "panel_id": .string("panel-1"),
                "vendor": .string("codex"),
                "session_id": .string("session-1"),
                "message": .string(message),
            ])
    }

    private static func acknowledgeInitialize(from transport: PanelRuntimeFakeTransport,
                                              file: StaticString = #filePath,
                                              line sourceLine: UInt = #line) throws {
        let initialize = try object(from: try XCTUnwrap(transport.sentLines().first,
                                                        file: file,
                                                        line: sourceLine),
                                    file: file,
                                    line: sourceLine)
        try respond(on: transport,
                    request: initialize,
                    result: .object([
                        "serverInfo": .object([
                            "name": .string("codex"),
                            "version": .string("test"),
                        ]),
                        "capabilities": .object([:]),
                    ]),
                    file: file,
                    line: sourceLine)
    }

    private static func respondToLastRequest(on transport: PanelRuntimeFakeTransport,
                                             result: JSONValue,
                                             file: StaticString = #filePath,
                                             line sourceLine: UInt = #line) throws {
        let request = try object(from: try XCTUnwrap(transport.sentLines().last,
                                                     file: file,
                                                     line: sourceLine),
                                 file: file,
                                 line: sourceLine)
        try respond(on: transport,
                    request: request,
                    result: result,
                    file: file,
                    line: sourceLine)
    }

    private static func respond(on transport: PanelRuntimeFakeTransport,
                                request: [String: JSONValue],
                                result: JSONValue,
                                file: StaticString = #filePath,
                                line sourceLine: UInt = #line) throws {
        let id = try XCTUnwrap(request["id"], file: file, line: sourceLine)
        let encodedID = String(decoding: try JSONEncoder().encode(id), as: UTF8.self)
        let encodedResult = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
        transport.emitLine(#"{"id":\#(encodedID),"result":\#(encodedResult)}"#)
    }

    private static func respondError(on transport: PanelRuntimeFakeTransport,
                                     request: [String: JSONValue],
                                     code: Int,
                                     message: String,
                                     file: StaticString = #filePath,
                                     line sourceLine: UInt = #line) throws {
        let id = try XCTUnwrap(request["id"], file: file, line: sourceLine)
        let encodedID = String(decoding: try JSONEncoder().encode(id), as: UTF8.self)
        let encodedMessage = String(decoding: try JSONEncoder().encode(JSONValue.string(message)), as: UTF8.self)
        transport.emitLine(#"{"id":\#(encodedID),"error":{"code":\#(code),"message":\#(encodedMessage)}}"#)
    }

    private static func object(from line: String,
                               file: StaticString = #filePath,
                               line sourceLine: UInt = #line) throws -> [String: JSONValue] {
        let data = try XCTUnwrap(line.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
                                 file: file,
                                 line: sourceLine)
        return try XCTUnwrap(try JSONDecoder().decode(JSONValue.self, from: data).objectValue,
                             file: file,
                             line: sourceLine)
    }
}

private final class PanelRuntimeFakeTransportConnector: CodexAppServerTransportConnecting {
    private(set) var connectedModes: [CodexAppServerTransportMode] = []
    private(set) var transport: PanelRuntimeFakeTransport?

    func connect(mode: CodexAppServerTransportMode,
                 onLine: @escaping @Sendable (String) -> Void,
                 onClose: @escaping @Sendable (Error?) -> Void) throws -> CodexAppServerConnectionTransport {
        connectedModes.append(mode)
        let transport = PanelRuntimeFakeTransport(onLine: onLine, onClose: onClose)
        self.transport = transport
        return transport
    }
}

private final class PanelRuntimeFakeTransport: CodexAppServerConnectionTransport {
    private let lock = NSLock()
    private var lines: [String] = []
    private let onLine: @Sendable (String) -> Void
    private let onClose: @Sendable (Error?) -> Void

    init(onLine: @escaping @Sendable (String) -> Void,
         onClose: @escaping @Sendable (Error?) -> Void) {
        self.onLine = onLine
        self.onClose = onClose
    }

    func sendLine(_ line: String) throws {
        lock.lock()
        lines.append(line)
        lock.unlock()
    }

    func close() {
        onClose(nil)
    }

    func emitLine(_ line: String) {
        onLine(line)
    }

    func sentLines() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return lines
    }
}

private final class PanelRuntimeFailingProcessRunner: CodexAppServerProcessRunning {
    private(set) var startedConfigurations: [CodexAppServerLaunchConfiguration] = []

    func start(configuration: CodexAppServerLaunchConfiguration,
               onStdoutLine: @escaping @Sendable (String) -> Void,
               onStderrLine: @escaping @Sendable (String) -> Void,
               onExit: @escaping @Sendable (Int32) -> Void) throws -> CodexAppServerManagedProcess {
        startedConfigurations.append(configuration)
        throw BridgeInternalError.conflict("panel runtime should attach, not launch")
    }
}
