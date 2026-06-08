import NIOCore
import NIOHTTP1
import NIOPosix
import NIOWebSocket
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
        let capabilities = initialize["params"]?.objectValue?["capabilities"]?.objectValue
        XCTAssertEqual(capabilities?["experimentalApi"]?.boolValue, true)
        XCTAssertEqual(capabilities?["requestAttestation"]?.boolValue, false)
        XCTAssertEqual(capabilities?["optOutNotificationMethods"]?.arrayValue?.count, 0)
        XCTAssertEqual(runner.process?.stdinLines().count, 1)
        try Self.acknowledgeInitialize(from: runner.process)
        let initialized = try Self.object(from: try XCTUnwrap(runner.process?.stdinLines().dropFirst().first))
        XCTAssertEqual(initialized["method"]?.stringValue, "initialized")
    }

    func testSessionRoutesThreadRequestsToAppServerStdin() throws {
        let runner = FakeCodexAppServerProcessRunner()
        let session = try Self.makeSession(runner: runner)
        try Self.acknowledgeInitialize(from: runner.process)

        try session.startThread(cwd: "/Users/timfeng/GitHub/Tidey",
                                model: "gpt-5",
                                approvalPolicy: "on-request",
                                sandbox: .string("workspace-write"))

        let process = try XCTUnwrap(runner.process)
        let request = try Self.object(from: process.stdinLines()[2])
        XCTAssertEqual(request["method"]?.stringValue, "thread/start")
        let params = try XCTUnwrap(request["params"]?.objectValue)
        XCTAssertEqual(params["cwd"]?.stringValue, "/Users/timfeng/GitHub/Tidey")
        XCTAssertEqual(params["model"]?.stringValue, "gpt-5")
        XCTAssertEqual(params["approvalPolicy"]?.stringValue, "on-request")
        XCTAssertEqual(params["sandbox"]?.stringValue, "workspace-write")
    }

    func testFactoryUsesUnixSocketTransportForSidecarAppServer() throws {
        let runner = FakeCodexAppServerProcessRunner()
        let connector = FakeCodexAppServerTransportConnector()
        let events = EventSink()
        let session = try Self.makeSession(
            configuration: .unixSocket(codexExecutablePath: "/tmp/disposable-codex",
                                       socketPath: "/tmp/tidey-codex-sidecar/app.sock",
                                       workingDirectory: "/tmp/tidey-codex-disposable",
                                       environment: ["CODEX_HOME": "/tmp/tidey-codex-home"]),
            runner: runner,
            connector: connector,
            events: events
        )

        XCTAssertEqual(runner.startedConfigurations.first?.arguments, [
            "app-server",
            "--listen",
            "unix:///tmp/tidey-codex-sidecar/app.sock",
        ])
        XCTAssertEqual(connector.connectedModes, [.unixSocket(path: "/tmp/tidey-codex-sidecar/app.sock")])
        XCTAssertTrue(runner.process?.stdinLines().isEmpty ?? false)

        let transport = try XCTUnwrap(connector.transport)
        let initialize = try Self.object(from: try XCTUnwrap(transport.sentLines().first))
        XCTAssertEqual(initialize["method"]?.stringValue, "initialize")
        XCTAssertEqual(transport.sentLines().count, 1)
        try Self.acknowledgeInitialize(from: transport)
        let initialized = try Self.object(from: try XCTUnwrap(transport.sentLines().dropFirst().first))
        XCTAssertEqual(initialized["method"]?.stringValue, "initialized")

        try session.startThread(cwd: "/Users/timfeng/GitHub/Tidey")
        let request = try Self.object(from: transport.sentLines().last ?? "")
        XCTAssertEqual(request["method"]?.stringValue, "thread/start")

        transport.emitLine("""
        {"method":"thread/started","params":{"thread":{"id":"thread-1","preview":"Remote TUI Codex","name":null}}}
        """)
        XCTAssertEqual(events.events().first?.text, "Remote TUI Codex")
    }

    func testFactoryAttachesExistingUnixSocketWithoutStartingProcess() throws {
        let runner = FakeCodexAppServerProcessRunner()
        let connector = FakeCodexAppServerTransportConnector()
        let factory = CodexAppServerRuntimeSessionFactory(processRunner: runner,
                                                          transportConnector: connector)
        var seq = 20
        let session = try factory.attach(socketPath: "/tmp/tidey-real-panel/app.sock",
                                         processID: 9001,
                                         context: CodexAppServerRuntimeContext(workspaceID: "workspace-1",
                                                                              panelID: "panel-1",
                                                                              sessionID: "session-1"),
                                         nextSequence: { _ in
                                             seq += 1
                                             return seq
                                         },
                                         timestampProvider: { "2026-06-07T00:00:00.000Z" },
                                         onAgentEvent: { _ in },
                                         onInteractivePrompt: { _ in },
                                         onInteractivePromptResolved: { _ in })

        XCTAssertTrue(runner.startedConfigurations.isEmpty)
        XCTAssertEqual(session.processID, 9001)
        XCTAssertEqual(connector.connectedModes, [.unixSocket(path: "/tmp/tidey-real-panel/app.sock")])

        let transport = try XCTUnwrap(connector.transport)
        let initialize = try Self.object(from: try XCTUnwrap(transport.sentLines().first))
        XCTAssertEqual(initialize["method"]?.stringValue, "initialize")
        try Self.acknowledgeInitialize(from: transport)
        try session.startThread(cwd: "/Users/timfeng/GitHub/Tidey")
        let startThread = try Self.object(from: transport.sentLines().last ?? "")
        XCTAssertEqual(startThread["method"]?.stringValue, "thread/start")
    }

    func testFactoryAttachesExistingUnixSocketResumesLoadedThread() throws {
        let runner = FakeCodexAppServerProcessRunner()
        let connector = FakeCodexAppServerTransportConnector()
        let factory = CodexAppServerRuntimeSessionFactory(processRunner: runner,
                                                          transportConnector: connector)
        let session = try factory.attach(socketPath: "/tmp/tidey-real-panel/app.sock",
                                         processID: 9001,
                                         context: CodexAppServerRuntimeContext(workspaceID: "workspace-1",
                                                                               panelID: "panel-1",
                                                                               sessionID: "session-1"),
                                         nextSequence: { _ in 1 },
                                         timestampProvider: { "2026-06-07T00:00:00.000Z" },
                                         onAgentEvent: { _ in },
                                         onInteractivePrompt: { _ in },
                                         onInteractivePromptResolved: { _ in })

        let transport = try XCTUnwrap(connector.transport)
        try Self.acknowledgeInitialize(from: transport)

        let listLoaded = try Self.object(from: try XCTUnwrap(transport.sentLines().dropFirst(2).first))
        XCTAssertEqual(listLoaded["method"]?.stringValue, "thread/loaded/list")
        let listLoadedID = try XCTUnwrap(listLoaded["id"])
        let listLoadedIDData = try JSONEncoder().encode(listLoadedID)
        let listLoadedIDText = String(decoding: listLoadedIDData, as: UTF8.self)
        transport.emitLine("""
        {"id":\(listLoadedIDText),"result":{"threads":[{"id":"thread-live","preview":"Mac TUI Codex","updatedAt":"2026-06-07T00:00:00.000Z"}]}}
        """)

        let resume = try Self.object(from: try XCTUnwrap(transport.sentLines().dropFirst(3).first))
        XCTAssertEqual(resume["method"]?.stringValue, "thread/resume")
        let resumeParams = try XCTUnwrap(resume["params"]?.objectValue)
        XCTAssertEqual(resumeParams["threadId"]?.stringValue, "thread-live")
        XCTAssertEqual(resumeParams["excludeTurns"]?.boolValue, false)

        try session.submitMessage(text: "hello from remote")
        let turnStart = try Self.object(from: try XCTUnwrap(transport.sentLines().last))
        XCTAssertEqual(turnStart["method"]?.stringValue, "turn/start")
        let turnParams = try XCTUnwrap(turnStart["params"]?.objectValue)
        XCTAssertEqual(turnParams["threadId"]?.stringValue, "thread-live")
        XCTAssertEqual(turnParams["input"]?.arrayValue?.first?.objectValue?["text"]?.stringValue, "hello from remote")
    }

    func testSubmitMessageLoadsThreadWhenAttachedRuntimeWasNotReady() throws {
        let runner = FakeCodexAppServerProcessRunner()
        let connector = FakeCodexAppServerTransportConnector()
        let factory = CodexAppServerRuntimeSessionFactory(processRunner: runner,
                                                          transportConnector: connector)
        let session = try factory.attach(socketPath: "/tmp/tidey-real-panel/app.sock",
                                         processID: 9001,
                                         context: CodexAppServerRuntimeContext(workspaceID: "workspace-1",
                                                                               panelID: "panel-1",
                                                                               sessionID: "session-1"),
                                         nextSequence: { _ in 1 },
                                         timestampProvider: { "2026-06-07T00:00:00.000Z" },
                                         onAgentEvent: { _ in },
                                         onInteractivePrompt: { _ in },
                                         onInteractivePromptResolved: { _ in })

        let transport = try XCTUnwrap(connector.transport)
        try Self.acknowledgeInitialize(from: transport)

        let initialListLoaded = try Self.object(from: try XCTUnwrap(transport.sentLines().dropFirst(2).first))
        XCTAssertEqual(initialListLoaded["method"]?.stringValue, "thread/loaded/list")
        let initialListLoadedID = try XCTUnwrap(initialListLoaded["id"])
        transport.emitLine(try Self.responseText(id: initialListLoadedID, result: .object(["threads": .array([])])))

        let submitCompleted = expectation(description: "submitMessage completes after loading thread")
        var submitError: Error?
        DispatchQueue.global().async {
            do {
                try session.submitMessage(text: "hello after delayed thread")
            } catch {
                submitError = error
            }
            submitCompleted.fulfill()
        }

        XCTAssertTrue(Self.waitForSentLineCount(4, transport: transport))
        let retryListLoaded = try Self.object(from: try XCTUnwrap(transport.sentLines().dropFirst(3).first))
        XCTAssertEqual(retryListLoaded["method"]?.stringValue, "thread/loaded/list")
        let retryListLoadedID = try XCTUnwrap(retryListLoaded["id"])
        transport.emitLine(try Self.responseText(id: retryListLoadedID, result: .object([
            "threads": .array([
                .object([
                    "id": .string("thread-live"),
                    "preview": .string("Mac TUI Codex"),
                    "updatedAt": .string("2026-06-07T00:00:00.000Z"),
                ]),
            ]),
        ])))

        wait(for: [submitCompleted], timeout: 2.0)
        XCTAssertNil(submitError)

        let turnStart = try Self.object(from: try XCTUnwrap(transport.sentLines().last))
        XCTAssertEqual(turnStart["method"]?.stringValue, "turn/start")
        let turnParams = try XCTUnwrap(turnStart["params"]?.objectValue)
        XCTAssertEqual(turnParams["threadId"]?.stringValue, "thread-live")
        XCTAssertEqual(turnParams["input"]?.arrayValue?.first?.objectValue?["text"]?.stringValue, "hello after delayed thread")
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
        try Self.acknowledgeInitialize(from: runner.process)

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
        try Self.acknowledgeInitialize(from: runner.process)
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

    func testUnixWebSocketConnectorWaitsForUpgradeBeforeReturningTransport() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        let socketDirectory = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("tcw-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: socketDirectory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: socketDirectory)
        }
        let socketPath = socketDirectory.appendingPathComponent("app.sock").path
        let receivedMessage = expectation(description: "server receives websocket text after upgrade")
        let receivedEventLoopMessage = expectation(description: "server receives websocket text sent from event loop")
        let requestURI = RequestURIBox()
        let clientFrameMask = ClientFrameMaskBox()

        let upgrader = NIOWebSocketServerUpgrader(
            maxFrameSize: 1 << 20,
            shouldUpgrade: { channel, request in
                requestURI.set(request.uri)
                let promise = channel.eventLoop.makePromise(of: HTTPHeaders?.self)
                channel.eventLoop.scheduleTask(in: .milliseconds(200)) {
                    promise.succeed(HTTPHeaders())
                }
                return promise.futureResult
            },
            upgradePipelineHandler: { channel, _ in
                channel.pipeline.addHandler(ServerTextFrameHandler { text in
                    clientFrameMask.setObservedMaskedFrame()
                    if text == "{\"jsonrpc\":\"2.0\"}" {
                        receivedMessage.fulfill()
                    }
                    if text == "{\"fromEventLoop\":true}" {
                        receivedEventLoopMessage.fulfill()
                    }
                })
            }
        )
        let configuration: NIOHTTPServerUpgradeConfiguration = (
            upgraders: [upgrader],
            completionHandler: { _ in }
        )
        let server = try ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline(withServerUpgrade: configuration)
            }
            .bind(unixDomainSocketPath: socketPath)
            .wait()
        defer {
            XCTAssertNoThrow(try server.close().wait())
        }

        let connector = CodexAppServerWebSocketTransportConnector(group: group)
        let transport = try connector.connect(mode: .unixSocket(path: socketPath),
                                              onLine: { _ in },
                                              onClose: { _ in })

        XCTAssertNoThrow(try transport.sendLine("{\"jsonrpc\":\"2.0\"}"))
        XCTAssertNoThrow(try group.next().submit {
            try transport.sendLine("{\"fromEventLoop\":true}")
        }.wait())
        wait(for: [receivedMessage, receivedEventLoopMessage], timeout: 2.0)
        XCTAssertEqual(requestURI.get(), "/")
        XCTAssertEqual(clientFrameMask.didObserveMaskedFrame(), true)
    }

    private static func makeSession(configuration: CodexAppServerLaunchConfiguration = CodexAppServerLaunchConfiguration(
                                        executablePath: "/tmp/disposable-codex",
                                        arguments: ["app-server"],
                                        workingDirectory: "/tmp/tidey-codex-disposable",
                                        environment: ["CODEX_HOME": "/tmp/tidey-codex-home"]),
                                    runner: FakeCodexAppServerProcessRunner,
                                    connector: FakeCodexAppServerTransportConnector = FakeCodexAppServerTransportConnector(),
                                    events: EventSink = EventSink(),
                                    prompts: PromptSink = PromptSink()) throws -> CodexAppServerRuntimeSession {
        var seq = 10
        let factory = CodexAppServerRuntimeSessionFactory(processRunner: runner,
                                                          transportConnector: connector)
        let session = try factory.start(configuration: configuration,
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

    private static func acknowledgeInitialize(from process: FakeCodexAppServerManagedProcess?,
                                              file: StaticString = #filePath,
                                              line sourceLine: UInt = #line) throws {
        let process = try XCTUnwrap(process, file: file, line: sourceLine)
        let initialize = try object(from: try XCTUnwrap(process.stdinLines().first,
                                                        file: file,
                                                        line: sourceLine),
                                    file: file,
                                    line: sourceLine)
        let response = try initializeResponse(for: try XCTUnwrap(initialize["id"], file: file, line: sourceLine))
        process.emitStdout(response)
    }

    private static func acknowledgeInitialize(from transport: FakeCodexAppServerConnectionTransport,
                                              file: StaticString = #filePath,
                                              line sourceLine: UInt = #line) throws {
        let initialize = try object(from: try XCTUnwrap(transport.sentLines().first,
                                                        file: file,
                                                        line: sourceLine),
                                    file: file,
                                    line: sourceLine)
        let response = try initializeResponse(for: try XCTUnwrap(initialize["id"], file: file, line: sourceLine))
        transport.emitLine(response)
    }

    private static func initializeResponse(for id: JSONValue) throws -> String {
        try responseText(id: id, result: .object([
            "serverInfo": .object([
                "name": .string("codex"),
                "version": .string("test"),
            ]),
            "capabilities": .object([:]),
        ]))
    }

    private static func responseText(id: JSONValue, result: JSONValue) throws -> String {
        let idData = try JSONEncoder().encode(id)
        let idText = String(decoding: idData, as: UTF8.self)
        let resultData = try JSONEncoder().encode(result)
        let resultText = String(decoding: resultData, as: UTF8.self)
        return #"{"id":\#(idText),"result":\#(resultText)}"#
    }

    private static func waitForSentLineCount(_ count: Int,
                                             transport: FakeCodexAppServerConnectionTransport,
                                             timeout: TimeInterval = 2.0) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if transport.sentLines().count >= count {
                return true
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return transport.sentLines().count >= count
    }
}

private final class ServerTextFrameHandler: ChannelInboundHandler {
    typealias InboundIn = WebSocketFrame

    private let onText: (String) -> Void

    init(onText: @escaping (String) -> Void) {
        self.onText = onText
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)
        guard frame.opcode == .text else {
            return
        }
        guard frame.maskKey != nil else {
            return
        }
        var payload = frame.unmaskedData
        if let text = payload.readString(length: payload.readableBytes) {
            onText(text)
        }
    }
}

private final class ClientFrameMaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var masked = false

    func setObservedMaskedFrame() {
        lock.lock()
        masked = true
        lock.unlock()
    }

    func didObserveMaskedFrame() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return masked
    }
}

private final class RequestURIBox: @unchecked Sendable {
    private let lock = NSLock()
    private var uri: String?

    func set(_ value: String) {
        lock.lock()
        uri = value
        lock.unlock()
    }

    func get() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return uri
    }
}

private final class FakeCodexAppServerTransportConnector: CodexAppServerTransportConnecting {
    private(set) var connectedModes: [CodexAppServerTransportMode] = []
    private(set) var transport: FakeCodexAppServerConnectionTransport?

    func connect(mode: CodexAppServerTransportMode,
                 onLine: @escaping @Sendable (String) -> Void,
                 onClose: @escaping @Sendable (Error?) -> Void) throws -> CodexAppServerConnectionTransport {
        connectedModes.append(mode)
        let transport = FakeCodexAppServerConnectionTransport(onLine: onLine,
                                                              onClose: onClose)
        self.transport = transport
        return transport
    }
}

private final class FakeCodexAppServerConnectionTransport: CodexAppServerConnectionTransport {
    private let lock = NSLock()
    private var lines: [String] = []
    private var closed = false
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
        lock.lock()
        closed = true
        lock.unlock()
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
