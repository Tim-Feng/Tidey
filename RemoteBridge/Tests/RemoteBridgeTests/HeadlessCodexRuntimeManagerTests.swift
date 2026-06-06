import XCTest
@testable import RemoteBridge

final class HeadlessCodexRuntimeManagerTests: XCTestCase {
    func testDevConfigurationRequiresExplicitAbsoluteCodexExecutable() {
        XCTAssertNil(HeadlessCodexRuntimeConfiguration.devFromEnvironment([
            "TIDEY_HEADLESS_CODEX_DEV": "1",
        ]))
        XCTAssertNil(HeadlessCodexRuntimeConfiguration.devFromEnvironment([
            "TIDEY_HEADLESS_CODEX_DEV": "1",
            "TIDEY_HEADLESS_CODEX_EXECUTABLE": "codex",
        ]))

        let config = HeadlessCodexRuntimeConfiguration.devFromEnvironment([
            "TIDEY_HEADLESS_CODEX_DEV": "1",
            "TIDEY_HEADLESS_CODEX_EXECUTABLE": "/tmp/disposable-codex",
            "TIDEY_HEADLESS_CODEX_CWD": "/tmp/headless-cwd",
            "TIDEY_HEADLESS_CODEX_HOME": "/tmp/headless-home",
        ])

        XCTAssertEqual(config?.launchConfiguration.executablePath, "/tmp/disposable-codex")
        XCTAssertEqual(config?.launchConfiguration.workingDirectory, "/tmp/headless-cwd")
        XCTAssertEqual(config?.launchConfiguration.environment["CODEX_HOME"], "/tmp/headless-home")
    }

    func testWorkspaceAndPanelOverlayExposeHeadlessCodexAgentSession() throws {
        let manager = Self.manager()
        let merged = manager.mergeWorkspaceListResult([
            "workspaces": .array([
                .object(["workspace_id": .string("native"), "title": .string("Native")]),
            ]),
        ])

        let workspaces = try XCTUnwrap(merged["workspaces"]?.arrayValue)
        XCTAssertEqual(workspaces.count, 2)
        let headlessWorkspace = try XCTUnwrap(workspaces.last?.objectValue)
        XCTAssertEqual(headlessWorkspace["workspace_id"]?.stringValue, "headless-workspace")
        XCTAssertEqual(headlessWorkspace["has_agent_session"]?.boolValue, true)
        XCTAssertEqual(headlessWorkspace["agent_panel_id"]?.stringValue, "headless-panel")
        XCTAssertEqual(headlessWorkspace["headless_codex"]?.boolValue, true)

        let panelResult = try XCTUnwrap(manager.panelListResult(workspaceID: "headless-workspace"))
        XCTAssertEqual(panelResult["selected_panel_id"]?.stringValue, "headless-panel")
        let panel = try XCTUnwrap(panelResult["panels"]?.arrayValue?.first?.objectValue)
        XCTAssertEqual(panel["panel_id"]?.stringValue, "headless-panel")
        XCTAssertEqual(panel["agent_session"]?.objectValue?["vendor"]?.stringValue, "codex")
        XCTAssertEqual(panel["agent_session"]?.objectValue?["session_id"]?.stringValue, "headless-session")
    }

    func testChatSubmitStartsThreadThenQueuedTurnAndPublishesEvents() throws {
        let runner = FakeCodexAppServerProcessRunner()
        let hub = AgentEventHub()
        let manager = Self.manager(runner: runner, eventHub: hub)

        let response = try manager.handleChatSubmit(BridgeRequest(id: "request-1",
                                                                  action: "chat_submit",
                                                                  params: [
                                                                    "workspace_id": .string("headless-workspace"),
                                                                    "panel_id": .string("headless-panel"),
                                                                    "vendor": .string("codex"),
                                                                    "session_id": .string("headless-session"),
                                                                    "message": .string("run tests"),
                                                                    "client_request_id": .string("client-1"),
                                                                  ]))

        XCTAssertEqual(response?.ok, true)
        XCTAssertEqual(response?.result?["headless"]?.boolValue, true)
        let process = try XCTUnwrap(runner.process)
        XCTAssertEqual(process.stdinLines().count, 2)
        XCTAssertEqual(try Self.object(from: process.stdinLines()[0])["method"]?.stringValue, "initialize")
        XCTAssertEqual(try Self.object(from: process.stdinLines()[1])["method"]?.stringValue, "thread/start")

        process.emitStdout(#"{"id":2,"result":{"thread":{"id":"thread-1"}}}"#)

        let lines = process.stdinLines()
        XCTAssertEqual(lines.count, 3)
        let turn = try Self.object(from: lines[2])
        XCTAssertEqual(turn["method"]?.stringValue, "turn/start")
        XCTAssertEqual(turn["params"]?.objectValue?["threadId"]?.stringValue, "thread-1")
        XCTAssertEqual(turn["params"]?.objectValue?["input"]?.arrayValue?.first?.objectValue?["text"]?.stringValue, "run tests")

        let fetched = hub.fetch(workspaceID: "headless-workspace",
                                sessionID: "headless-session",
                                limit: 10)
        XCTAssertTrue(fetched.events.contains { $0.type == .sessionStarted })
        XCTAssertTrue(fetched.events.contains { $0.type == .userMessage && $0.text == "run tests" })
    }

    func testSecondChatSubmitUsesExistingThreadWithoutStartingAnotherThread() throws {
        let runner = FakeCodexAppServerProcessRunner()
        let manager = Self.manager(runner: runner)
        _ = try Self.submit(manager, text: "first")
        let process = try XCTUnwrap(runner.process)
        process.emitStdout(#"{"id":2,"result":{"thread":{"id":"thread-1"}}}"#)

        _ = try Self.submit(manager, text: "second")

        let methods = try process.stdinLines().map { try Self.object(from: $0)["method"]?.stringValue }
        XCTAssertEqual(methods, ["initialize", "thread/start", "turn/start", "turn/start"])
        let secondTurn = try Self.object(from: process.stdinLines()[3])
        XCTAssertEqual(secondTurn["params"]?.objectValue?["input"]?.arrayValue?.first?.objectValue?["text"]?.stringValue, "second")
    }

    func testThreadStartMissingThreadIDFailsQueuedTurnAndAllowsRetry() throws {
        let runner = FakeCodexAppServerProcessRunner()
        let hub = AgentEventHub()
        let manager = Self.manager(runner: runner, eventHub: hub)
        _ = try Self.submit(manager, text: "first")
        let process = try XCTUnwrap(runner.process)

        process.emitStdout(#"{"id":2,"result":{}}"#)
        _ = try Self.submit(manager, text: "second")

        let methods = try process.stdinLines().map { try Self.object(from: $0)["method"]?.stringValue }
        XCTAssertEqual(methods, ["initialize", "thread/start", "thread/start"])
        let fetched = hub.fetch(workspaceID: "headless-workspace",
                                sessionID: "headless-session",
                                limit: 20)
        XCTAssertTrue(fetched.events.contains {
            $0.type == .assistantMessage && $0.payload?.objectValue?["kind"]?.stringValue == "bridge_error"
        })
        XCTAssertTrue(fetched.events.contains {
            $0.type == .assistantMessage && $0.text == "Failed to submit queued Codex message: first"
        })
    }

    func testStdoutNotificationsArePublishedToAgentEventHub() throws {
        let runner = FakeCodexAppServerProcessRunner()
        let hub = AgentEventHub()
        let manager = Self.manager(runner: runner, eventHub: hub)
        _ = try Self.submit(manager, text: "run")
        let process = try XCTUnwrap(runner.process)

        process.emitStdout(#"{"method":"item/commandExecution/outputDelta","params":{"threadId":"thread-1","turnId":"turn-1","itemId":"cmd-1","delta":"ok\n"}}"#)

        let fetched = hub.fetch(workspaceID: "headless-workspace",
                                sessionID: "headless-session",
                                limit: 10)
        XCTAssertTrue(fetched.events.contains {
            $0.type == .toolResult && $0.name == "terminal_stream" && $0.output == "ok\n"
        })
    }

    func testApprovalPromptSubmitRepliesToAppServer() throws {
        let runner = FakeCodexAppServerProcessRunner()
        let hub = AgentEventHub()
        let manager = Self.manager(runner: runner, eventHub: hub)
        _ = try Self.submit(manager, text: "needs approval")
        let process = try XCTUnwrap(runner.process)
        process.emitStdout(#"{"id":2,"result":{"thread":{"id":"thread-1"}}}"#)
        process.emitStdout("""
        {"id":"approval-1","method":"item/commandExecution/requestApproval","params":{"threadId":"thread-1","turnId":"turn-1","itemId":"cmd-1","startedAtMs":1786000000000,"command":"curl https://example.com","reason":"Needs network."}}
        """)
        let promptID = try XCTUnwrap(hub.fetch(workspaceID: "headless-workspace",
                                               sessionID: "headless-session",
                                               limit: 20)
            .events
            .first(where: { $0.type == .interactivePrompt })?
            .metadata?["prompt_id"])

        let response = try manager.handleSubmitInteractivePrompt(BridgeRequest(id: "submit-approval",
                                                                               action: "submit_interactive_prompt",
                                                                               params: [
                                                                                "workspace_id": .string("headless-workspace"),
                                                                                "panel_id": .string("headless-panel"),
                                                                                "prompt_id": .string(promptID),
                                                                                "target_index": .number(1),
                                                                               ]))

        XCTAssertEqual(response?.ok, true)
        XCTAssertEqual(response?.result?["headless"]?.boolValue, true)
        let approvalResponse = try Self.object(from: process.stdinLines().last ?? "")
        XCTAssertEqual(approvalResponse["id"]?.stringValue, "approval-1")
        XCTAssertEqual(approvalResponse["result"]?.objectValue?["decision"]?.stringValue, "acceptForSession")
    }

    func testNonHeadlessRequestsAreIgnored() throws {
        let manager = Self.manager()

        let response = try manager.handleChatSubmit(BridgeRequest(id: "request-1",
                                                                  action: "chat_submit",
                                                                  params: [
                                                                    "workspace_id": .string("native"),
                                                                    "panel_id": .string("native-panel"),
                                                                    "message": .string("hello"),
                                                                  ]))

        XCTAssertNil(response)
        XCTAssertNil(manager.panelListResult(workspaceID: "native"))
    }

    @discardableResult
    private static func submit(_ manager: HeadlessCodexRuntimeManager,
                               text: String) throws -> BridgeResponse? {
        try manager.handleChatSubmit(BridgeRequest(id: UUID().uuidString,
                                                   action: "chat_submit",
                                                   params: [
                                                    "workspace_id": .string("headless-workspace"),
                                                    "panel_id": .string("headless-panel"),
                                                    "message": .string(text),
                                                   ]))
    }

    private static func manager(runner: FakeCodexAppServerProcessRunner = FakeCodexAppServerProcessRunner(),
                                eventHub: AgentEventHub = AgentEventHub()) -> HeadlessCodexRuntimeManager {
        HeadlessCodexRuntimeManager(configuration: HeadlessCodexRuntimeConfiguration(
            workspaceID: "headless-workspace",
            panelID: "headless-panel",
            sessionID: "headless-session",
            title: "Headless Codex",
            subtitle: "Codex app-server",
            cwd: "/tmp/headless-cwd",
            model: "gpt-5",
            approvalPolicy: "on-request",
            sandbox: .string("workspace-write"),
            launchConfiguration: CodexAppServerLaunchConfiguration(
                executablePath: "/tmp/disposable-codex",
                arguments: ["app-server"],
                workingDirectory: "/tmp/headless-cwd",
                environment: ["CODEX_HOME": "/tmp/headless-home"])),
                                      sessionFactory: CodexAppServerRuntimeSessionFactory(processRunner: runner),
                                      eventHub: eventHub,
                                      timestampProvider: { "2026-06-06T00:00:00.000Z" })
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

private final class FakeCodexAppServerProcessRunner: CodexAppServerProcessRunning {
    private(set) var process: FakeCodexAppServerManagedProcess?

    func start(configuration: CodexAppServerLaunchConfiguration,
               onStdoutLine: @escaping @Sendable (String) -> Void,
               onStderrLine: @escaping @Sendable (String) -> Void,
               onExit: @escaping @Sendable (Int32) -> Void) throws -> CodexAppServerManagedProcess {
        let process = FakeCodexAppServerManagedProcess(onStdoutLine: onStdoutLine,
                                                       onExit: onExit)
        self.process = process
        return process
    }
}

private final class FakeCodexAppServerManagedProcess: CodexAppServerManagedProcess {
    private let lock = NSLock()
    private var lines: [String] = []
    private let onStdoutLine: @Sendable (String) -> Void
    private let onExit: @Sendable (Int32) -> Void

    init(onStdoutLine: @escaping @Sendable (String) -> Void,
         onExit: @escaping @Sendable (Int32) -> Void) {
        self.onStdoutLine = onStdoutLine
        self.onExit = onExit
    }

    var processID: Int32? { 1234 }

    func sendLine(_ line: String) throws {
        lock.lock()
        lines.append(line)
        lock.unlock()
    }

    func terminate() {}

    func emitStdout(_ line: String) {
        onStdoutLine(line)
    }

    func emitExit(_ exitCode: Int32) {
        onExit(exitCode)
    }

    func stdinLines() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return lines
    }
}
