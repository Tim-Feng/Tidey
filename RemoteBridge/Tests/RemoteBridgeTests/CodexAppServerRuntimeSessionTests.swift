import XCTest
@testable import RemoteBridge

final class CodexAppServerRuntimeSessionTests: XCTestCase {
    func testFactoryStartsConfiguredAppServerProcess() throws {
        let runner = FakeCodexAppServerProcessRunner()
        let session = try Self.makeSession(runner: runner)

        XCTAssertEqual(runner.startedConfigurations.count, 1)
        XCTAssertEqual(runner.startedConfigurations.first?.executablePath, "/tmp/disposable-codex")
        XCTAssertEqual(runner.startedConfigurations.first?.arguments, ["app-server"])
        XCTAssertEqual(runner.startedConfigurations.first?.workingDirectory, "/tmp/tidey-codex-disposable")
        XCTAssertEqual(runner.startedConfigurations.first?.environment["CODEX_HOME"], "/tmp/tidey-codex-home")
        XCTAssertFalse(runner.startedConfigurations.first?.executablePath.contains("/Applications/Tidey.app") ?? true)
        XCTAssertEqual(session.processID, 4242)
        let initialize = try Self.object(from: try XCTUnwrap(runner.process?.stdinLines().first))
        XCTAssertEqual(initialize["method"]?.stringValue, "initialize")
        XCTAssertEqual(initialize["params"]?.objectValue?["clientInfo"]?.objectValue?["name"]?.stringValue, "tidey-bridge")
        XCTAssertEqual(initialize["params"]?.objectValue?["capabilities"]?.objectValue?["experimentalApi"]?.boolValue, true)
    }

    func testSessionRoutesThreadRequestsToAppServerStdin() throws {
        let runner = FakeCodexAppServerProcessRunner()
        let session = try Self.makeSession(runner: runner)

        try session.startThread(cwd: "/Users/timfeng/GitHub/Tidey",
                                model: "gpt-5",
                                approvalPolicy: "on-request",
                                sandbox: .string("workspace-write"))

        let process = try XCTUnwrap(runner.process)
        let request = try Self.object(from: process.stdinLines()[1])
        XCTAssertEqual(request["method"]?.stringValue, "thread/start")
        let params = try XCTUnwrap(request["params"]?.objectValue)
        XCTAssertEqual(params["cwd"]?.stringValue, "/Users/timfeng/GitHub/Tidey")
        XCTAssertEqual(params["model"]?.stringValue, "gpt-5")
        XCTAssertEqual(params["approvalPolicy"]?.stringValue, "on-request")
        XCTAssertEqual(params["sandbox"]?.stringValue, "workspace-write")
    }

    func testSessionConvertsStdoutNotificationsToAgentEvents() throws {
        let runner = FakeCodexAppServerProcessRunner()
        let events = EventSink()
        _ = try Self.makeSession(runner: runner, events: events)

        runner.process?.emitStdout("""
        {"method":"thread/started","params":{"thread":{"id":"thread-1","preview":"Headless Codex","name":null}}}
        """)
        runner.process?.emitStdout("""
        {"method":"item/commandExecution/outputDelta","params":{"threadId":"thread-1","turnId":"turn-1","itemId":"cmd-1","delta":"ok\\n"}}
        """)

        let emitted = events.events()
        XCTAssertEqual(emitted.map(\.type), [.sessionStarted, .toolResult])
        XCTAssertEqual(emitted[0].text, "Headless Codex")
        XCTAssertEqual(emitted[1].name, "terminal_stream")
        XCTAssertEqual(emitted[1].output, "ok\n")
    }

    func testSessionPublishesApprovalAndSubmitRepliesToAppServer() throws {
        let runner = FakeCodexAppServerProcessRunner()
        let prompts = PromptSink()
        _ = try Self.makeSession(runner: runner, prompts: prompts)

        runner.process?.emitStdout("""
        {"id":"approval-1","method":"item/commandExecution/requestApproval","params":{"threadId":"thread-1","turnId":"turn-1","itemId":"cmd-1","startedAtMs":1786000000000,"command":"curl https://example.com","reason":"Needs network."}}
        """)

        let envelope = try XCTUnwrap(prompts.envelopes().first)
        XCTAssertEqual(envelope.prompt.source, "codex_command_approval")

        let resolved = try prompts.session?.submitApproval(promptID: envelope.prompt.promptID, targetIndex: 0)
        XCTAssertEqual(resolved?.type, .interactivePromptResolved)

        let process = try XCTUnwrap(runner.process)
        let response = try Self.object(from: process.stdinLines().last ?? "")
        XCTAssertEqual(response["id"]?.stringValue, "approval-1")
        XCTAssertEqual(response["result"]?.objectValue?["decision"]?.stringValue, "accept")
    }

    func testSessionStopTerminatesProcessAndClosesConnection() throws {
        let runner = FakeCodexAppServerProcessRunner()
        let session = try Self.makeSession(runner: runner)

        session.stop()

        XCTAssertEqual(runner.process?.didTerminate, true)
        XCTAssertThrowsError(try session.startThread(cwd: nil)) { error in
            guard case CodexAppServerConnectionError.closed = error else {
                return XCTFail("expected closed error, got \(error)")
            }
        }
    }

    func testProcessExitClosesPendingClientRequests() throws {
        let runner = FakeCodexAppServerProcessRunner()
        let session = try Self.makeSession(runner: runner)
        var failure: CodexAppServerConnectionError?

        try session.startThread(cwd: nil) { result in
            if case .failure(let error) = result {
                failure = error
            }
        }
        runner.process?.emitExit(9)

        guard case .closed = failure else {
            return XCTFail("expected closed failure")
        }
    }

    private static func makeSession(runner: FakeCodexAppServerProcessRunner,
                                    events: EventSink = EventSink(),
                                    prompts: PromptSink = PromptSink()) throws -> CodexAppServerRuntimeSession {
        var seq = 10
        let factory = CodexAppServerRuntimeSessionFactory(processRunner: runner)
        let session = try factory.start(configuration: CodexAppServerLaunchConfiguration(
            executablePath: "/tmp/disposable-codex",
            arguments: ["app-server"],
            workingDirectory: "/tmp/tidey-codex-disposable",
            environment: ["CODEX_HOME": "/tmp/tidey-codex-home"]),
                                        context: CodexAppServerRuntimeContext(workspaceID: "workspace-1",
                                                                               panelID: "panel-1",
                                                                               sessionID: "session-1"),
                                        nextSequence: { _ in
                                            seq += 1
                                            return seq
                                        },
                                        timestampProvider: { "2026-06-05T12:00:00.000Z" },
                                        onAgentEvent: { events.append($0) },
                                        onInteractivePrompt: { prompts.append($0) },
                                        onInteractivePromptResolved: { prompts.appendResolved($0) })
        prompts.session = session
        return session
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
    private(set) var startedConfigurations: [CodexAppServerLaunchConfiguration] = []
    private(set) var process: FakeCodexAppServerManagedProcess?

    func start(configuration: CodexAppServerLaunchConfiguration,
               onStdoutLine: @escaping @Sendable (String) -> Void,
               onStderrLine: @escaping @Sendable (String) -> Void,
               onExit: @escaping @Sendable (Int32) -> Void) throws -> CodexAppServerManagedProcess {
        startedConfigurations.append(configuration)
        let process = FakeCodexAppServerManagedProcess(onStdoutLine: onStdoutLine,
                                                       onStderrLine: onStderrLine,
                                                       onExit: onExit)
        self.process = process
        return process
    }
}

private final class FakeCodexAppServerManagedProcess: CodexAppServerManagedProcess {
    private let lock = NSLock()
    private var lines: [String] = []
    private let onStdoutLine: @Sendable (String) -> Void
    private let onStderrLine: @Sendable (String) -> Void
    private let onExit: @Sendable (Int32) -> Void
    private(set) var didTerminate = false

    init(onStdoutLine: @escaping @Sendable (String) -> Void,
         onStderrLine: @escaping @Sendable (String) -> Void,
         onExit: @escaping @Sendable (Int32) -> Void) {
        self.onStdoutLine = onStdoutLine
        self.onStderrLine = onStderrLine
        self.onExit = onExit
    }

    var processID: Int32? {
        4242
    }

    func sendLine(_ line: String) throws {
        lock.lock()
        lines.append(line)
        lock.unlock()
    }

    func terminate() {
        didTerminate = true
    }

    func emitStdout(_ line: String) {
        onStdoutLine(line)
    }

    func emitStderr(_ line: String) {
        onStderrLine(line)
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

private final class PromptSink: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [CodexAppServerInteractivePromptEnvelope] = []
    private var resolvedStorage: [AgentEvent] = []
    var session: CodexAppServerRuntimeSession?

    func append(_ envelope: CodexAppServerInteractivePromptEnvelope) {
        lock.lock()
        storage.append(envelope)
        lock.unlock()
    }

    func appendResolved(_ event: AgentEvent) {
        lock.lock()
        resolvedStorage.append(event)
        lock.unlock()
    }

    func envelopes() -> [CodexAppServerInteractivePromptEnvelope] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func resolvedEvents() -> [AgentEvent] {
        lock.lock()
        defer { lock.unlock() }
        return resolvedStorage
    }
}
