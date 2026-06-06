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
        XCTAssertEqual(config?.launchConfiguration.transport, .stdio)
        XCTAssertNil(config?.remoteTUILaunchConfiguration)
    }

    func testDevConfigurationCanUseSidecarSocketForOriginalCodexTUI() {
        XCTAssertNil(HeadlessCodexRuntimeConfiguration.devFromEnvironment([
            "TIDEY_HEADLESS_CODEX_DEV": "1",
            "TIDEY_HEADLESS_CODEX_EXECUTABLE": "/tmp/disposable-codex",
            "TIDEY_HEADLESS_CODEX_APP_SERVER_SOCKET": "relative.sock",
        ]))

        let config = HeadlessCodexRuntimeConfiguration.devFromEnvironment([
            "TIDEY_HEADLESS_CODEX_DEV": "1",
            "TIDEY_HEADLESS_CODEX_EXECUTABLE": "/tmp/codex bin",
            "TIDEY_HEADLESS_CODEX_CWD": "/tmp/headless cwd",
            "TIDEY_HEADLESS_CODEX_HOME": "/tmp/headless home",
            "TIDEY_HEADLESS_CODEX_APP_SERVER_SOCKET": "/tmp/tidey codex/app.sock",
        ])

        XCTAssertEqual(config?.subtitle, "Codex app-server sidecar")
        XCTAssertEqual(config?.launchConfiguration.arguments, [
            "app-server",
            "--listen",
            "unix:///tmp/tidey codex/app.sock",
        ])
        XCTAssertEqual(config?.launchConfiguration.transport, .unixSocket(path: "/tmp/tidey codex/app.sock"))
        XCTAssertEqual(config?.remoteTUILaunchConfiguration?.arguments, ["--remote", "unix:///tmp/tidey codex/app.sock"])
        XCTAssertEqual(
            config?.remoteTUILaunchConfiguration?.shellCommand(),
            "cd '/tmp/headless cwd' && CODEX_HOME='/tmp/headless home' '/tmp/codex bin' --remote 'unix:///tmp/tidey codex/app.sock'"
        )
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

    func testPanelOverlayExposesRemoteTUICommandWhenSidecarIsConfigured() throws {
        let manager = Self.manager(configuration: HeadlessCodexRuntimeConfiguration(
            workspaceID: "headless-workspace",
            panelID: "headless-panel",
            sessionID: "headless-session",
            title: "Headless Codex",
            subtitle: "Codex app-server sidecar",
            cwd: "/tmp/headless cwd",
            model: "gpt-5",
            approvalPolicy: "on-request",
            sandbox: .string("workspace-write"),
            launchConfiguration: .unixSocket(codexExecutablePath: "/tmp/codex bin",
                                             socketPath: "/tmp/tidey codex/app.sock",
                                             workingDirectory: "/tmp/headless cwd",
                                             environment: ["CODEX_HOME": "/tmp/headless home"]),
            remoteTUILaunchConfiguration: .unixSocket(codexExecutablePath: "/tmp/codex bin",
                                                      socketPath: "/tmp/tidey codex/app.sock",
                                                      workingDirectory: "/tmp/headless cwd",
                                                      environment: ["CODEX_HOME": "/tmp/headless home"])
        ))

        let panelResult = try XCTUnwrap(manager.panelListResult(workspaceID: "headless-workspace"))
        let panel = try XCTUnwrap(panelResult["panels"]?.arrayValue?.first?.objectValue)
        XCTAssertEqual(panel["codex_app_server_remote"]?.stringValue, "unix:///tmp/tidey codex/app.sock")
        let remoteTUI = try XCTUnwrap(panel["codex_remote_tui"]?.objectValue)
        XCTAssertEqual(remoteTUI["executable_path"]?.stringValue, "/tmp/codex bin")
        XCTAssertEqual(remoteTUI["arguments"]?.arrayValue?.map(\.stringValue), ["--remote", "unix:///tmp/tidey codex/app.sock"])
        XCTAssertEqual(remoteTUI["working_directory"]?.stringValue, "/tmp/headless cwd")
        XCTAssertEqual(remoteTUI["environment"]?.objectValue?["CODEX_HOME"]?.stringValue, "/tmp/headless home")
        XCTAssertEqual(remoteTUI["remote_address"]?.stringValue, "unix:///tmp/tidey codex/app.sock")
        XCTAssertEqual(
            panel["codex_remote_tui_command"]?.stringValue,
            "cd '/tmp/headless cwd' && CODEX_HOME='/tmp/headless home' '/tmp/codex bin' --remote 'unix:///tmp/tidey codex/app.sock'"
        )
    }

    func testCreatePanelForHeadlessWorkspaceCreatesMacWorkspaceAndRemoteTUIPanel() throws {
        let manager = Self.manager(configuration: Self.sidecarConfiguration())
        let sender = FakeTideyRequestSender(responses: [
            BridgeResponse(id: "create-panel.workspace",
                           ok: true,
                           result: [
                            "workspace": .object([
                                "workspace_id": .string("mac-workspace"),
                                "title": .string("Headless Codex"),
                            ]),
                           ],
                           error: nil),
            BridgeResponse(id: "create-panel",
                           ok: true,
                           result: [
                            "panel": .object([
                                "workspace_id": .string("mac-workspace"),
                                "panel_id": .string("mac-panel"),
                            ]),
                           ],
                           error: nil),
        ])

        let response = try manager.handleCreatePanel(BridgeRequest(id: "create-panel",
                                                                   action: "create_panel",
                                                                   params: [
                                                                    "workspace_id": .string("headless-workspace"),
                                                                    "command": .string("malicious-or-stale-command"),
                                                                    "working_directory": .string("/tmp/wrong-cwd"),
                                                                   ]),
                                                     socketSender: sender)

        XCTAssertEqual(response?.ok, true)
        XCTAssertEqual(response?.result?["created_workspace"]?.boolValue, true)
        XCTAssertEqual(response?.result?["headless_remote_tui"]?.boolValue, true)
        XCTAssertEqual(response?.result?["workspace"]?.objectValue?["workspace_id"]?.stringValue, "mac-workspace")
        XCTAssertEqual(response?.result?["panel"]?.objectValue?["panel_id"]?.stringValue, "mac-panel")
        XCTAssertEqual(sender.requests.count, 2)
        XCTAssertEqual(sender.requests[0].action, "create_workspace")
        XCTAssertEqual(sender.requests[0].params?["title"]?.stringValue, "Headless Codex")
        XCTAssertEqual(sender.requests[1].action, "create_panel")
        XCTAssertEqual(sender.requests[1].params?["workspace_id"]?.stringValue, "mac-workspace")
        XCTAssertEqual(sender.requests[1].params?["command"]?.stringValue, "'/tmp/codex bin' --remote 'unix:///tmp/tidey codex/app.sock'")
        XCTAssertEqual(sender.requests[1].params?["working_directory"]?.stringValue, "/tmp/headless cwd")
        XCTAssertEqual(sender.requests[1].params?["environment"]?.objectValue?["CODEX_HOME"]?.stringValue, "/tmp/headless home")
    }

    func testCreatePanelForHeadlessWorkspaceRequiresRemoteTUIConfiguration() throws {
        let manager = Self.manager()
        let sender = FakeTideyRequestSender(responses: [])

        XCTAssertThrowsError(try manager.handleCreatePanel(BridgeRequest(id: "create-panel",
                                                                         action: "create_panel",
                                                                         params: [
                                                                            "workspace_id": .string("headless-workspace"),
                                                                         ]),
                                                           socketSender: sender)) { error in
            XCTAssertEqual((error as? BridgeInternalError)?.payload.code, "conflict")
        }
        XCTAssertTrue(sender.requests.isEmpty)
    }

    func testCreatePanelForNativeWorkspaceFallsBackToMacSocketPath() throws {
        let manager = Self.manager(configuration: Self.sidecarConfiguration())
        let sender = FakeTideyRequestSender(responses: [])

        let response = try manager.handleCreatePanel(BridgeRequest(id: "create-panel",
                                                                   action: "create_panel",
                                                                   params: [
                                                                    "workspace_id": .string("native-workspace"),
                                                                   ]),
                                                     socketSender: sender)

        XCTAssertNil(response)
        XCTAssertTrue(sender.requests.isEmpty)
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
        XCTAssertEqual(process.stdinLines().count, 3)
        XCTAssertEqual(try Self.object(from: process.stdinLines()[0])["method"]?.stringValue, "initialize")
        XCTAssertEqual(try Self.object(from: process.stdinLines()[1])["method"]?.stringValue, "initialized")
        XCTAssertEqual(try Self.object(from: process.stdinLines()[2])["method"]?.stringValue, "thread/start")

        let beforeThreadStarted = hub.fetch(workspaceID: "headless-workspace",
                                            sessionID: "headless-session",
                                            limit: 10)
        XCTAssertTrue(beforeThreadStarted.events.contains {
            $0.type == .status
                && $0.payload?.objectValue?["kind"]?.stringValue == "headless_starting"
                && $0.text == "Starting Codex app-server"
        })

        process.emitStdout(#"{"id":2,"result":{"thread":{"id":"thread-1"}}}"#)

        let lines = process.stdinLines()
        XCTAssertEqual(lines.count, 4)
        let turn = try Self.object(from: lines[3])
        XCTAssertEqual(turn["method"]?.stringValue, "turn/start")
        XCTAssertEqual(turn["params"]?.objectValue?["threadId"]?.stringValue, "thread-1")
        XCTAssertEqual(turn["params"]?.objectValue?["input"]?.arrayValue?.first?.objectValue?["text"]?.stringValue, "run tests")

        let fetched = hub.fetch(workspaceID: "headless-workspace",
                                sessionID: "headless-session",
                                limit: 10)
        XCTAssertTrue(fetched.events.contains { $0.type == .sessionStarted })
        XCTAssertFalse(fetched.events.contains { $0.type == .userMessage })

        process.emitStdout("""
        {"method":"item/started","params":{"threadId":"thread-1","turnId":"turn-1","item":{"type":"userMessage","id":"user-1","content":[{"type":"text","text":"run tests","text_elements":[]}]}}}
        """)

        let afterUserEcho = hub.fetch(workspaceID: "headless-workspace",
                                      sessionID: "headless-session",
                                      limit: 10)
        let userEvents = afterUserEcho.events.filter { $0.type == .userMessage }
        XCTAssertEqual(userEvents.count, 1)
        XCTAssertEqual(userEvents.first?.text, "run tests")
    }

    func testSecondChatSubmitUsesExistingThreadWithoutStartingAnotherThread() throws {
        let runner = FakeCodexAppServerProcessRunner()
        let manager = Self.manager(runner: runner)
        _ = try Self.submit(manager, text: "first")
        let process = try XCTUnwrap(runner.process)
        process.emitStdout(#"{"id":2,"result":{"thread":{"id":"thread-1"}}}"#)

        _ = try Self.submit(manager, text: "second")

        let methods = try process.stdinLines().map { try Self.object(from: $0)["method"]?.stringValue }
        XCTAssertEqual(methods, ["initialize", "initialized", "thread/start", "turn/start", "turn/start"])
        let secondTurn = try Self.object(from: process.stdinLines()[4])
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
        XCTAssertEqual(methods, ["initialize", "initialized", "thread/start", "thread/start"])
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

    func testProcessExitWhileThreadStartPendingPublishesQueuedTurnFailure() throws {
        let runner = FakeCodexAppServerProcessRunner()
        let hub = AgentEventHub()
        let manager = Self.manager(runner: runner, eventHub: hub)
        _ = try Self.submit(manager, text: "first")
        let process = try XCTUnwrap(runner.process)

        process.emitExit(9)

        let fetched = hub.fetch(workspaceID: "headless-workspace",
                                sessionID: "headless-session",
                                limit: 20)
        XCTAssertTrue(fetched.events.contains {
            $0.type == .assistantMessage && $0.payload?.objectValue?["kind"]?.stringValue == "bridge_error"
                && ($0.text ?? "").contains("failed to start thread")
        })
        XCTAssertTrue(fetched.events.contains {
            $0.type == .assistantMessage && $0.text == "Failed to submit queued Codex message: first"
        })
        XCTAssertTrue(fetched.events.contains {
            $0.type == .assistantMessage && ($0.text ?? "").contains("exited with status 9")
        })
    }

    func testProcessExitAllowsNextSubmitToStartFreshAppServerSession() throws {
        let runner = FakeCodexAppServerProcessRunner()
        let manager = Self.manager(runner: runner)
        _ = try Self.submit(manager, text: "first")
        let firstProcess = try XCTUnwrap(runner.process)
        firstProcess.emitStdout(#"{"id":2,"result":{"thread":{"id":"thread-1"}}}"#)
        firstProcess.emitExit(9)

        _ = try Self.submit(manager, text: "second")

        let secondProcess = try XCTUnwrap(runner.process)
        XCTAssertFalse(firstProcess === secondProcess)
        XCTAssertEqual(runner.startCount, 2)
        let methods = try secondProcess.stdinLines().map { try Self.object(from: $0)["method"]?.stringValue }
        XCTAssertEqual(methods, ["initialize", "initialized", "thread/start"])
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

    func testApprovalResolvedPublishesBeforeImmediateAppServerFollowUpNotification() throws {
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
        process.onSendLine = { line in
            guard line.contains(#""id":"approval-1""#) else {
                return
            }
            process.emitStdout("""
            {"method":"item/completed","params":{"threadId":"thread-1","turnId":"turn-1","item":{"type":"commandExecution","id":"cmd-1","command":"curl https://example.com","cwd":"/tmp/headless-cwd","processId":"proc-1","source":"agent","status":"completed","commandActions":[],"aggregatedOutput":"","exitCode":1,"durationMs":1}}}
            """)
        }

        _ = try manager.handleSubmitInteractivePrompt(BridgeRequest(id: "submit-approval",
                                                                    action: "submit_interactive_prompt",
                                                                    params: [
                                                                        "workspace_id": .string("headless-workspace"),
                                                                        "panel_id": .string("headless-panel"),
                                                                        "prompt_id": .string(promptID),
                                                                        "target_index": .number(2),
                                                                    ]))

        let fetched = hub.fetch(workspaceID: "headless-workspace",
                                sessionID: "headless-session",
                                limit: 20)
        let resolved = try XCTUnwrap(fetched.events.first { $0.type == .interactivePromptResolved })
        let completion = try XCTUnwrap(fetched.events.first {
            $0.type == .toolResult
                && $0.payload?.objectValue?["kind"]?.stringValue == "command_execution_completed"
        })
        XCTAssertGreaterThan(completion.seq, resolved.seq)
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

    private static func manager(configuration: HeadlessCodexRuntimeConfiguration? = nil,
                                runner: FakeCodexAppServerProcessRunner = FakeCodexAppServerProcessRunner(),
                                eventHub: AgentEventHub = AgentEventHub()) -> HeadlessCodexRuntimeManager {
        let runtimeConfiguration = configuration ?? HeadlessCodexRuntimeConfiguration(
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
                environment: ["CODEX_HOME": "/tmp/headless-home"]))
        return HeadlessCodexRuntimeManager(configuration: runtimeConfiguration,
                                      sessionFactory: CodexAppServerRuntimeSessionFactory(processRunner: runner),
                                      eventHub: eventHub,
                                      timestampProvider: { "2026-06-06T00:00:00.000Z" })
    }

    private static func sidecarConfiguration() -> HeadlessCodexRuntimeConfiguration {
        HeadlessCodexRuntimeConfiguration(
            workspaceID: "headless-workspace",
            panelID: "headless-panel",
            sessionID: "headless-session",
            title: "Headless Codex",
            subtitle: "Codex app-server sidecar",
            cwd: "/tmp/headless cwd",
            model: "gpt-5",
            approvalPolicy: "on-request",
            sandbox: .string("workspace-write"),
            launchConfiguration: .unixSocket(codexExecutablePath: "/tmp/codex bin",
                                             socketPath: "/tmp/tidey codex/app.sock",
                                             workingDirectory: "/tmp/headless cwd",
                                             environment: ["CODEX_HOME": "/tmp/headless home"]),
            remoteTUILaunchConfiguration: .unixSocket(codexExecutablePath: "/tmp/codex bin",
                                                      socketPath: "/tmp/tidey codex/app.sock",
                                                      workingDirectory: "/tmp/headless cwd",
                                                      environment: ["CODEX_HOME": "/tmp/headless home"]))
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
    private(set) var startCount = 0

    func start(configuration: CodexAppServerLaunchConfiguration,
               onStdoutLine: @escaping @Sendable (String) -> Void,
               onStderrLine: @escaping @Sendable (String) -> Void,
               onExit: @escaping @Sendable (Int32) -> Void) throws -> CodexAppServerManagedProcess {
        startCount += 1
        let process = FakeCodexAppServerManagedProcess(onStdoutLine: onStdoutLine,
                                                       onExit: onExit)
        self.process = process
        return process
    }
}

private final class FakeTideyRequestSender: TideyRequestSending {
    private(set) var requests: [BridgeRequest] = []
    private var responses: [BridgeResponse]

    init(responses: [BridgeResponse]) {
        self.responses = responses
    }

    func send(_ request: BridgeRequest) throws -> BridgeResponse {
        requests.append(request)
        guard responses.isEmpty == false else {
            throw BridgeInternalError.invalidResponse
        }
        return responses.removeFirst()
    }
}

private final class FakeCodexAppServerManagedProcess: CodexAppServerManagedProcess {
    private let lock = NSLock()
    private var lines: [String] = []
    private let onStdoutLine: @Sendable (String) -> Void
    private let onExit: @Sendable (Int32) -> Void
    var onSendLine: ((String) -> Void)?

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
        if let initializeResponse = Self.initializeResponse(for: line) {
            onStdoutLine(initializeResponse)
        }
        onSendLine?(line)
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

    private static func initializeResponse(for line: String) -> String? {
        guard let data = line.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data),
              let object = value.objectValue,
              object["method"]?.stringValue == "initialize",
              let id = object["id"],
              let idData = try? JSONEncoder().encode(id) else {
            return nil
        }
        let idText = String(decoding: idData, as: UTF8.self)
        return #"{"id":\#(idText),"result":{"serverInfo":{"name":"codex","version":"test"},"capabilities":{}}}"#
    }
}
