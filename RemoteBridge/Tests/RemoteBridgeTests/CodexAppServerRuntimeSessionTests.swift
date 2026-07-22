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
        var activeThreadIDs = [String]()
        let session = try factory.attach(socketPath: "/tmp/tidey-real-panel/app.sock",
                                         processID: 9001,
                                         context: CodexAppServerRuntimeContext(workspaceID: "workspace-1",
                                                                               panelID: "panel-1",
                                                                               sessionID: "session-1"),
                                         nextSequence: { _ in 1 },
                                         timestampProvider: { "2026-06-07T00:00:00.000Z" },
                                         onAgentEvent: { _ in },
                                         onInteractivePrompt: { _ in },
                                         onInteractivePromptResolved: { _ in },
                                         onActiveThreadID: { activeThreadIDs.append($0) })

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

        XCTAssertTrue(Self.waitForSentLineCount(4, transport: transport))
        let resume = try Self.object(from: try XCTUnwrap(transport.sentLines().dropFirst(3).first))
        XCTAssertEqual(resume["method"]?.stringValue, "thread/resume")
        let resumeParams = try XCTUnwrap(resume["params"]?.objectValue)
        XCTAssertEqual(resumeParams["threadId"]?.stringValue, "thread-live")
        XCTAssertEqual(resumeParams["excludeTurns"]?.boolValue, false)
        XCTAssertEqual(activeThreadIDs, ["thread-live"])

        try session.submitMessage(text: "hello from remote")
        let turnStart = try Self.object(from: try XCTUnwrap(transport.sentLines().last))
        XCTAssertEqual(turnStart["method"]?.stringValue, "turn/start")
        let turnParams = try XCTUnwrap(turnStart["params"]?.objectValue)
        XCTAssertEqual(turnParams["threadId"]?.stringValue, "thread-live")
        XCTAssertEqual(turnParams["input"]?.arrayValue?.first?.objectValue?["text"]?.stringValue, "hello from remote")
    }

    func testLoadedThreadSubscriptionDoesNotBlockInboundLineHandler() throws {
        let runner = FakeCodexAppServerProcessRunner()
        let connector = FakeCodexAppServerTransportConnector()
        let factory = CodexAppServerRuntimeSessionFactory(processRunner: runner,
                                                          transportConnector: connector)
        let activeThreadEntered = expectation(description: "active thread handler entered")
        let releaseActiveThreadHandler = DispatchSemaphore(value: 0)
        let session = try factory.attach(socketPath: "/tmp/tidey-real-panel/app.sock",
                                         processID: 9001,
                                         context: CodexAppServerRuntimeContext(workspaceID: "workspace-1",
                                                                               panelID: "panel-1",
                                                                               sessionID: "session-1"),
                                         nextSequence: { _ in 1 },
                                         timestampProvider: { "2026-06-07T00:00:00.000Z" },
                                         onAgentEvent: { _ in },
                                         onInteractivePrompt: { _ in },
                                         onInteractivePromptResolved: { _ in },
                                         onActiveThreadID: { _ in
                                             activeThreadEntered.fulfill()
                                             releaseActiveThreadHandler.wait()
                                         })
        _ = session

        let transport = try XCTUnwrap(connector.transport)
        try Self.acknowledgeInitialize(from: transport)

        let listLoaded = try Self.object(from: try XCTUnwrap(transport.sentLines().dropFirst(2).first))
        XCTAssertEqual(listLoaded["method"]?.stringValue, "thread/loaded/list")
        let listLoadedID = try XCTUnwrap(listLoaded["id"])
        let listLoadedResponse = try Self.responseText(id: listLoadedID, result: .object([
            "threads": .array([
                .object([
                    "id": .string("thread-live"),
                    "preview": .string("Mac TUI Codex"),
                    "updatedAt": .string("2026-06-07T00:00:00.000Z"),
                ]),
            ]),
        ]))
        let inboundReturned = expectation(description: "inbound line handler returned")

        DispatchQueue.global().async {
            transport.emitLine(listLoadedResponse)
            inboundReturned.fulfill()
        }

        XCTAssertEqual(XCTWaiter.wait(for: [inboundReturned], timeout: 0.2), .completed)
        XCTAssertEqual(XCTWaiter.wait(for: [activeThreadEntered], timeout: 1.0), .completed)
        releaseActiveThreadHandler.signal()
        XCTAssertTrue(Self.waitForSentLineCount(4, transport: transport))

        let resume = try Self.object(from: try XCTUnwrap(transport.sentLines().dropFirst(3).first))
        XCTAssertEqual(resume["method"]?.stringValue, "thread/resume")
        XCTAssertEqual(resume["params"]?.objectValue?["threadId"]?.stringValue, "thread-live")
    }

    func testLoadedThreadRefreshDoesNotReportUnchangedActiveThreadAgain() throws {
        let runner = FakeCodexAppServerProcessRunner()
        let connector = FakeCodexAppServerTransportConnector()
        let factory = CodexAppServerRuntimeSessionFactory(processRunner: runner,
                                                          transportConnector: connector)
        var activeThreadIDs = [String]()
        let session = try factory.attach(socketPath: "/tmp/tidey-real-panel/app.sock",
                                         processID: 9001,
                                         context: CodexAppServerRuntimeContext(workspaceID: "workspace-1",
                                                                               panelID: "panel-1",
                                                                               sessionID: "session-1"),
                                         nextSequence: { _ in 1 },
                                         timestampProvider: { "2026-06-07T00:00:00.000Z" },
                                         onAgentEvent: { _ in },
                                         onInteractivePrompt: { _ in },
                                         onInteractivePromptResolved: { _ in },
                                         onActiveThreadID: { activeThreadIDs.append($0) })

        let transport = try XCTUnwrap(connector.transport)
        try Self.acknowledgeInitialize(from: transport)
        try Self.loadThread("thread-live", on: transport)
        let resume = try Self.object(from: try XCTUnwrap(transport.sentLines().dropFirst(3).first))
        let resumeID = try XCTUnwrap(resume["id"])
        transport.emitLine(try Self.responseText(id: resumeID, result: .object([
            "thread": .object([
                "id": .string("thread-live"),
            ]),
        ])))
        XCTAssertEqual(activeThreadIDs, ["thread-live"])

        session.refreshActiveThread()

        XCTAssertTrue(Self.waitForSentLineCount(5, transport: transport))
        let refreshListLoaded = try Self.object(from: try XCTUnwrap(transport.sentLines().dropFirst(4).first))
        XCTAssertEqual(refreshListLoaded["method"]?.stringValue, "thread/loaded/list")
        let refreshListLoadedID = try XCTUnwrap(refreshListLoaded["id"])
        transport.emitLine(try Self.responseText(id: refreshListLoadedID, result: .object([
            "threads": .array([
                .object([
                    "id": .string("thread-live"),
                    "preview": .string("Mac TUI Codex"),
                    "updatedAt": .string("2026-06-07T00:00:01.000Z"),
                ]),
            ]),
        ])))

        XCTAssertEqual(activeThreadIDs, ["thread-live"])
        XCTAssertEqual(transport.sentLines().count, 5)
    }

    func testAttachedRuntimeRetriesThreadSubscriptionWhenThreadLoadsLater() throws {
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
        transport.emitLine(try Self.responseText(id: initialListLoadedID, result: .object([
            "threads": .array([]),
        ])))
        XCTAssertEqual(transport.sentLines().count, 3)

        XCTAssertTrue(Self.waitForSentLineCount(4, transport: transport, poll: {
            session.ensureThreadSubscription()
        }))
        let retryListLoaded = try Self.object(from: try XCTUnwrap(transport.sentLines().dropFirst(3).first))
        XCTAssertEqual(retryListLoaded["method"]?.stringValue, "thread/loaded/list")
        let retryListLoadedID = try XCTUnwrap(retryListLoaded["id"])
        transport.emitLine(try Self.responseText(id: retryListLoadedID, result: .object([
            "threads": .array([
                .object([
                    "id": .string("thread-late"),
                    "preview": .string("Late loaded thread"),
                    "updatedAt": .string("2026-06-07T00:00:01.000Z"),
                ]),
            ]),
        ])))

        XCTAssertTrue(Self.waitForSentLineCount(5, transport: transport))
        let resume = try Self.object(from: try XCTUnwrap(transport.sentLines().dropFirst(4).first))
        XCTAssertEqual(resume["method"]?.stringValue, "thread/resume")
        let resumeParams = try XCTUnwrap(resume["params"]?.objectValue)
        XCTAssertEqual(resumeParams["threadId"]?.stringValue, "thread-late")
        XCTAssertEqual(resumeParams["excludeTurns"]?.boolValue, false)
        XCTAssertNil(resumeParams["approvalsReviewer"])

        let resumeID = try XCTUnwrap(resume["id"])
        transport.emitLine(try Self.responseText(id: resumeID, result: .object([
            "thread": .object([
                "id": .string("thread-late"),
            ]),
            "approvalsReviewer": .string("user"),
            "approvalPolicy": .string("on-request"),
        ])))

        session.ensureThreadSubscription()
        XCTAssertEqual(transport.sentLines().count, 5)
    }

    func testAttachedRuntimeTreatsNoRolloutResumeFailureAsThreadNotReady() throws {
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
        transport.emitLine(try Self.responseText(id: initialListLoadedID, result: .object([
            "threads": .array([
                .object([
                    "id": .string("thread-without-rollout"),
                    "preview": .string("Visible before rollout"),
                    "updatedAt": .string("2026-06-07T00:00:00.000Z"),
                ]),
            ]),
        ])))

        XCTAssertTrue(Self.waitForSentLineCount(4, transport: transport))
        let firstResume = try Self.object(from: try XCTUnwrap(transport.sentLines().dropFirst(3).first))
        XCTAssertEqual(firstResume["method"]?.stringValue, "thread/resume")
        XCTAssertEqual(firstResume["params"]?.objectValue?["threadId"]?.stringValue, "thread-without-rollout")
        let firstResumeID = try XCTUnwrap(firstResume["id"])
        transport.emitLine(try Self.errorResponseText(id: firstResumeID,
                                                      code: -32600,
                                                      message: "no rollout found for thread id thread-without-rollout"))

        XCTAssertFalse(session.canSubmitMessage())
        session.ensureThreadSubscription()
        XCTAssertEqual(transport.sentLines().count, 4)

        Thread.sleep(forTimeInterval: 1.1)
        session.ensureThreadSubscription()

        XCTAssertTrue(Self.waitForSentLineCount(5, transport: transport))
        let retryListLoaded = try Self.object(from: try XCTUnwrap(transport.sentLines().dropFirst(4).first))
        XCTAssertEqual(retryListLoaded["method"]?.stringValue, "thread/loaded/list")
        let retryListLoadedID = try XCTUnwrap(retryListLoaded["id"])
        transport.emitLine(try Self.responseText(id: retryListLoadedID, result: .object([
            "threads": .array([
                .object([
                    "id": .string("thread-without-rollout"),
                    "preview": .string("Visible after rollout"),
                    "updatedAt": .string("2026-06-07T00:00:01.000Z"),
                ]),
            ]),
        ])))

        XCTAssertTrue(Self.waitForSentLineCount(6, transport: transport))
        let retryResume = try Self.object(from: try XCTUnwrap(transport.sentLines().dropFirst(5).first))
        XCTAssertEqual(retryResume["method"]?.stringValue, "thread/resume")
        XCTAssertEqual(retryResume["params"]?.objectValue?["threadId"]?.stringValue, "thread-without-rollout")
        let retryResumeID = try XCTUnwrap(retryResume["id"])
        transport.emitLine(try Self.responseText(id: retryResumeID, result: .object([
            "thread": .object([
                "id": .string("thread-without-rollout"),
            ]),
            "approvalsReviewer": .string("user"),
            "approvalPolicy": .string("on-request"),
        ])))

        session.ensureThreadSubscription()
        XCTAssertEqual(transport.sentLines().count, 6)
    }

    func testFactoryAttachesExplicitCurrentLoadedThread() throws {
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
        let listLoadedID = try XCTUnwrap(listLoaded["id"])
        transport.emitLine(try Self.responseText(id: listLoadedID, result: .object([
            "threads": .array([
                .object([
                    "id": .string("thread-old"),
                    "preview": .string("Old thread"),
                ]),
                .object([
                    "id": .string("thread-current"),
                    "preview": .string("Current thread"),
                    "isCurrent": .bool(true),
                ]),
            ]),
        ])))

        XCTAssertTrue(Self.waitForSentLineCount(4, transport: transport))
        let resume = try Self.object(from: try XCTUnwrap(transport.sentLines().dropFirst(3).first))
        XCTAssertEqual(resume["method"]?.stringValue, "thread/resume")
        XCTAssertEqual(resume["params"]?.objectValue?["threadId"]?.stringValue, "thread-current")

        try session.submitMessage(text: "hello current")
        let turnStart = try Self.object(from: try XCTUnwrap(transport.sentLines().last))
        XCTAssertEqual(turnStart["params"]?.objectValue?["threadId"]?.stringValue, "thread-current")
    }

    func testFactoryDoesNotGuessAmbiguousLoadedThread() throws {
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
        let initialListLoadedID = try XCTUnwrap(initialListLoaded["id"])
        transport.emitLine(try Self.responseText(id: initialListLoadedID, result: Self.ambiguousLoadedThreadsResult()))
        XCTAssertEqual(transport.sentLines().count, 3)

        let submitCompleted = expectation(description: "ambiguous submit fails")
        var submitError: Error?
        DispatchQueue.global().async {
            do {
                try session.submitMessage(text: "must not guess")
            } catch {
                submitError = error
            }
            submitCompleted.fulfill()
        }

        XCTAssertTrue(Self.waitForSentLineCount(4, transport: transport))
        let retryListLoaded = try Self.object(from: try XCTUnwrap(transport.sentLines().dropFirst(3).first))
        XCTAssertEqual(retryListLoaded["method"]?.stringValue, "thread/loaded/list")
        let retryListLoadedID = try XCTUnwrap(retryListLoaded["id"])
        transport.emitLine(try Self.responseText(id: retryListLoadedID, result: Self.ambiguousLoadedThreadsResult()))

        wait(for: [submitCompleted], timeout: 2.0)
        guard case BridgeInternalError.invalidRequest(let message)? = submitError else {
            return XCTFail("expected invalid request, got \(String(describing: submitError))")
        }
        XCTAssertEqual(message, "Codex app-server thread is not ready.")
        XCTAssertEqual(transport.sentLines().count, 4)
    }

    func testFactoryDoesNotUsePaginatedSingleLoadedThread() throws {
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
        let initialListLoadedID = try XCTUnwrap(initialListLoaded["id"])
        transport.emitLine(try Self.responseText(id: initialListLoadedID, result: .object([
            "data": .array([
                .string("thread-first-page"),
            ]),
            "nextCursor": .string("next-page"),
        ])))

        XCTAssertFalse(session.canSubmitMessage())
        XCTAssertEqual(transport.sentLines().count, 3)
    }

    func testRegistryRootFallbackResumesWhenLoadedListIsEmpty() throws {
        let (session, transport) = try Self.makeAttachedSession()
        session.setRegistryRootThreadID("  thread-root  ")
        try Self.acknowledgeInitialize(from: transport)

        let listLoaded = try Self.object(from: try XCTUnwrap(transport.sentLines().dropFirst(2).first))
        transport.emitLine(try Self.responseText(id: try XCTUnwrap(listLoaded["id"]), result: .object([
            "threads": .array([]),
        ])))

        XCTAssertTrue(Self.waitForSentLineCount(4, transport: transport))
        let resume = try Self.object(from: try XCTUnwrap(transport.sentLines().dropFirst(3).first))
        XCTAssertEqual(resume["method"]?.stringValue, "thread/resume")
        XCTAssertEqual(resume["params"]?.objectValue?["threadId"]?.stringValue, "thread-root")
    }

    func testRegistryRootFallbackHandlesAmbiguousPaginatedAndChildOnlyLists() throws {
        let unresolvedResults: [JSONValue] = [
            .object([
                "threads": .array([
                    .object(["id": .string("thread-a")]),
                    .object(["id": .string("thread-b")]),
                ]),
            ]),
            .object([
                "threads": .array([.object(["id": .string("thread-page-1")])]),
                "nextCursor": .string("cursor-2"),
            ]),
            .object([
                "threads": .array([
                    .object([
                        "id": .string("thread-child"),
                        "parentThreadId": .string("thread-root"),
                    ]),
                ]),
            ]),
        ]

        for result in unresolvedResults {
            let (session, transport) = try Self.makeAttachedSession()
            session.setRegistryRootThreadID("thread-root")
            try Self.acknowledgeInitialize(from: transport)
            let listLoaded = try Self.object(from: try XCTUnwrap(transport.sentLines().dropFirst(2).first))
            transport.emitLine(try Self.responseText(id: try XCTUnwrap(listLoaded["id"]), result: result))

            XCTAssertTrue(Self.waitForSentLineCount(4, transport: transport))
            let resume = try Self.object(from: try XCTUnwrap(transport.sentLines().dropFirst(3).first))
            XCTAssertEqual(resume["method"]?.stringValue, "thread/resume")
            XCTAssertEqual(resume["params"]?.objectValue?["threadId"]?.stringValue, "thread-root")
        }
    }

    func testKnownRegistryRootOutranksUnclassifiableBareLoadedThread() throws {
        let (session, transport) = try Self.makeAttachedSession()
        session.setRegistryRootThreadID("thread-root")
        try Self.acknowledgeInitialize(from: transport)
        let listLoaded = try Self.object(from: try XCTUnwrap(transport.sentLines().dropFirst(2).first))
        transport.emitLine(try Self.responseText(id: try XCTUnwrap(listLoaded["id"]), result: .object([
            "data": .array([.string("thread-maybe-child")]),
        ])))

        XCTAssertTrue(Self.waitForSentLineCount(4, transport: transport))
        let resume = try Self.object(from: try XCTUnwrap(transport.sentLines().dropFirst(3).first))
        XCTAssertEqual(resume["params"]?.objectValue?["threadId"]?.stringValue, "thread-root",
                       "a metadata-free loaded id cannot replace the authoritative registry root")
    }

    func testBlankRegistryRootFailsClosedAndDoesNotResume() throws {
        let (session, transport) = try Self.makeAttachedSession()
        session.setRegistryRootThreadID("  \n ")
        try Self.acknowledgeInitialize(from: transport)
        let listLoaded = try Self.object(from: try XCTUnwrap(transport.sentLines().dropFirst(2).first))
        transport.emitLine(try Self.responseText(id: try XCTUnwrap(listLoaded["id"]), result: .object([
            "threads": .array([]),
        ])))

        XCTAssertEqual(transport.sentLines().count, 3)
        XCTAssertFalse(session.canSubmitMessage())
    }

    func testLateRegistryRootDeliveryRearmsParkedSubscription() throws {
        let (session, transport) = try Self.makeAttachedSession()
        try Self.acknowledgeInitialize(from: transport)
        let listLoaded = try Self.object(from: try XCTUnwrap(transport.sentLines().dropFirst(2).first))
        transport.emitLine(try Self.responseText(id: try XCTUnwrap(listLoaded["id"]), result: .object([
            "threads": .array([]),
        ])))
        XCTAssertEqual(transport.sentLines().count, 3)

        session.setRegistryRootThreadID("thread-root")

        XCTAssertTrue(Self.waitForSentLineCount(4, transport: transport))
        let resume = try Self.object(from: try XCTUnwrap(transport.sentLines().dropFirst(3).first))
        XCTAssertEqual(resume["method"]?.stringValue, "thread/resume")
        XCTAssertEqual(resume["params"]?.objectValue?["threadId"]?.stringValue, "thread-root")
    }

    func testLateRootSetterDuringUnresolvedCallbackResumesExactlyOnce() throws {
        let (session, transport) = try Self.makeAttachedSession()
        session.loadedThreadUnresolvedHook = { [weak session] in
            session?.loadedThreadUnresolvedHook = nil
            session?.setRegistryRootThreadID("thread-root")
        }
        try Self.acknowledgeInitialize(from: transport)
        let listLoaded = try Self.object(from: try XCTUnwrap(transport.sentLines().dropFirst(2).first))
        transport.emitLine(try Self.responseText(id: try XCTUnwrap(listLoaded["id"]), result: .object([
            "threads": .array([]),
        ])))

        XCTAssertTrue(Self.waitForSentLineCount(4, transport: transport))
        let resumedThreadIDs = transport.sentLines().compactMap { line -> String? in
            guard let object = try? Self.object(from: line),
                  object["method"]?.stringValue == "thread/resume" else {
                return nil
            }
            return object["params"]?.objectValue?["threadId"]?.stringValue
        }
        XCTAssertEqual(resumedThreadIDs, ["thread-root"])
    }

    func testLateAuthoritativeRootStopsConfirmedWrongSubscription() throws {
        let (session, transport) = try Self.makeAttachedSession()
        try Self.acknowledgeInitialize(from: transport)
        let listLoaded = try Self.object(from: try XCTUnwrap(transport.sentLines().dropFirst(2).first))
        transport.emitLine(try Self.responseText(id: try XCTUnwrap(listLoaded["id"]), result: .object([
            "data": .array([.string("thread-maybe-child")]),
        ])))
        XCTAssertTrue(Self.waitForSentLineCount(4, transport: transport))
        let childResume = try Self.object(from: try XCTUnwrap(transport.sentLines().dropFirst(3).first))

        session.setRegistryRootThreadID("thread-root")
        transport.emitLine(try Self.responseText(id: try XCTUnwrap(childResume["id"]), result: .object([
            "thread": .object(["id": .string("thread-maybe-child")]),
        ])))

        XCTAssertTrue(Self.waitFor { session.isStopped() })
    }

    func testRefreshStopsInsteadOfAdditivelyResumingDifferentRoot() throws {
        let (session, transport) = try Self.makeAttachedSession()
        try Self.acknowledgeInitialize(from: transport)
        let listLoaded = try Self.object(from: try XCTUnwrap(transport.sentLines().dropFirst(2).first))
        transport.emitLine(try Self.responseText(id: try XCTUnwrap(listLoaded["id"]), result: .object([
            "threads": .array([.object(["id": .string("thread-a")])]),
        ])))
        XCTAssertTrue(Self.waitForSentLineCount(4, transport: transport))
        let resumeA = try Self.object(from: try XCTUnwrap(transport.sentLines().dropFirst(3).first))
        transport.emitLine(try Self.responseText(id: try XCTUnwrap(resumeA["id"]), result: .object([
            "thread": .object(["id": .string("thread-a")]),
        ])))

        session.refreshActiveThread()
        XCTAssertTrue(Self.waitForSentLineCount(5, transport: transport))
        let refresh = try Self.object(from: try XCTUnwrap(transport.sentLines().dropFirst(4).first))
        transport.emitLine(try Self.responseText(id: try XCTUnwrap(refresh["id"]), result: .object([
            "threads": .array([.object(["id": .string("thread-b")])]),
        ])))

        XCTAssertTrue(Self.waitFor { session.isStopped() })
        let resumedThreadIDs = transport.sentLines().compactMap { line -> String? in
            guard let object = try? Self.object(from: line),
                  object["method"]?.stringValue == "thread/resume" else {
                return nil
            }
            return object["params"]?.objectValue?["threadId"]?.stringValue
        }
        XCTAssertEqual(resumedThreadIDs, ["thread-a"],
                       "the old connection must never subscribe to both roots")
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
            "data": .array([
                .string("thread-live"),
            ]),
            "nextCursor": .null,
        ])))

        wait(for: [submitCompleted], timeout: 2.0)
        XCTAssertNil(submitError)

        let turnStart = try Self.object(from: try XCTUnwrap(transport.sentLines().last))
        XCTAssertEqual(turnStart["method"]?.stringValue, "turn/start")
        let turnParams = try XCTUnwrap(turnStart["params"]?.objectValue)
        XCTAssertEqual(turnParams["threadId"]?.stringValue, "thread-live")
        XCTAssertEqual(turnParams["input"]?.arrayValue?.first?.objectValue?["text"]?.stringValue, "hello after delayed thread")
    }

    func testSubmitMessageRejectsSecondTurnWhileThreadIsBusy() throws {
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
        try Self.loadThread("thread-live", on: transport)

        try session.submitMessage(text: "first")
        let sentCountAfterFirstSubmit = transport.sentLines().count

        XCTAssertThrowsError(try session.submitMessage(text: "second")) { error in
            guard case BridgeInternalError.invalidRequest(let message) = error else {
                return XCTFail("expected invalid request, got \(error)")
            }
            XCTAssertEqual(message, "Codex app-server turn is already running.")
        }
        XCTAssertEqual(transport.sentLines().count, sentCountAfterFirstSubmit)

        transport.emitLine("""
        {"method":"turn/started","params":{"threadId":"thread-live","turn":{"id":"turn-1","items":[],"itemsView":{"type":"all"},"status":"running","error":null,"startedAt":1,"completedAt":null,"durationMs":null}}}
        """)
        XCTAssertThrowsError(try session.submitMessage(text: "still busy")) { error in
            guard case BridgeInternalError.invalidRequest = error else {
                return XCTFail("expected invalid request, got \(error)")
            }
        }
        XCTAssertEqual(transport.sentLines().count, sentCountAfterFirstSubmit)

        transport.emitLine("""
        {"method":"turn/completed","params":{"threadId":"thread-live","turn":{"id":"turn-1","items":[],"itemsView":{"type":"all"},"status":"completed","error":null,"startedAt":1,"completedAt":2,"durationMs":1000}}}
        """)

        try session.submitMessage(text: "after completion")
        XCTAssertEqual(transport.sentLines().count, sentCountAfterFirstSubmit + 1)
        let turnStart = try Self.object(from: try XCTUnwrap(transport.sentLines().last))
        XCTAssertEqual(turnStart["method"]?.stringValue, "turn/start")
        let turnParams = try XCTUnwrap(turnStart["params"]?.objectValue)
        XCTAssertEqual(turnParams["input"]?.arrayValue?.first?.objectValue?["text"]?.stringValue, "after completion")
    }

    func testTUIThreadStatusActiveBlocksRemoteSubmitUntilIdle() throws {
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
        try Self.loadThread("thread-live", on: transport)

        transport.emitLine("""
        {"method":"thread/status/changed","params":{"threadId":"thread-live","status":{"type":"active","activeFlags":[]}}}
        """)
        let sentCountAfterActive = transport.sentLines().count

        XCTAssertThrowsError(try session.submitMessage(text: "remote while TUI active")) { error in
            guard case BridgeInternalError.invalidRequest(let message) = error else {
                return XCTFail("expected invalid request, got \(error)")
            }
            XCTAssertEqual(message, "Codex app-server turn is already running.")
        }
        XCTAssertEqual(transport.sentLines().count, sentCountAfterActive)

        transport.emitLine("""
        {"method":"thread/status/changed","params":{"threadId":"thread-live","status":{"type":"idle"}}}
        """)

        try session.submitMessage(text: "remote after TUI idle")
        let turnStart = try Self.object(from: try XCTUnwrap(transport.sentLines().last))
        XCTAssertEqual(turnStart["method"]?.stringValue, "turn/start")
        XCTAssertEqual(turnStart["params"]?.objectValue?["input"]?.arrayValue?.first?.objectValue?["text"]?.stringValue,
                       "remote after TUI idle")
    }

    func testTurnStateStoreRoutesIdlePendingAndKnownTurnAtomically() {
        let store = CodexAppServerTurnStateStore()
        let claimID = UUID()

        XCTAssertEqual(store.routeSubmit(threadID: "thread-live", claimID: claimID), .start)
        XCTAssertEqual(store.routeSubmit(threadID: "thread-live"), .busyWithoutTurnID)

        store.reconcileAcceptedStart(threadID: "thread-live",
                                     claimID: claimID,
                                     turnID: "turn-1")
        XCTAssertEqual(store.routeSubmit(threadID: "thread-live"), .steer(turnID: "turn-1"))
    }

    func testTurnStateStoreDuplicateStartPreservesRemoteOriginAcrossIdleStatus() {
        let store = CodexAppServerTurnStateStore()
        let claimID = UUID()

        XCTAssertEqual(store.routeSubmit(threadID: "thread-live", claimID: claimID), .start)
        store.markStarted(threadID: "thread-live", turnID: "turn-1")
        store.markStarted(threadID: "thread-live", turnID: "turn-1")
        store.markThreadIdle(threadID: "thread-live")

        XCTAssertEqual(store.routeSubmit(threadID: "thread-live"), .steer(turnID: "turn-1"),
                       "an idempotent duplicate turn/started must not relabel a remote turn as app-server-owned")
    }

    func testTurnStateStoreCompletionBeforeResponseDoesNotResurrectTurn() {
        let store = CodexAppServerTurnStateStore()
        let claimID = UUID()

        XCTAssertEqual(store.routeSubmit(threadID: "thread-live", claimID: claimID), .start)
        store.markCompleted(threadID: "thread-live", turnID: "turn-fast")
        store.reconcileAcceptedStart(threadID: "thread-live",
                                     claimID: claimID,
                                     turnID: "turn-fast")

        XCTAssertEqual(store.routeSubmit(threadID: "thread-live"), .start)
    }

    func testTurnStateStoreLateExpiredClaimCannotOverwriteReplacement() {
        var now = Date(timeIntervalSince1970: 100)
        let store = CodexAppServerTurnStateStore(timeout: 1) { now }
        let firstClaimID = UUID()
        let secondClaimID = UUID()

        XCTAssertEqual(store.routeSubmit(threadID: "thread-live", claimID: firstClaimID), .start)
        now = now.addingTimeInterval(2)
        XCTAssertEqual(store.routeSubmit(threadID: "thread-live", claimID: secondClaimID), .start)

        store.reconcileAcceptedStart(threadID: "thread-live",
                                     claimID: firstClaimID,
                                     turnID: "turn-stale")
        XCTAssertEqual(store.routeSubmit(threadID: "thread-live"), .busyWithoutTurnID)

        store.reconcileAcceptedStart(threadID: "thread-live",
                                     claimID: secondClaimID,
                                     turnID: "turn-current")
        XCTAssertEqual(store.routeSubmit(threadID: "thread-live"), .steer(turnID: "turn-current"))
    }

    func testTurnStateStoreExpiresStuckActiveTurn() throws {
        var now = Date(timeIntervalSince1970: 100)
        let store = CodexAppServerTurnStateStore(timeout: 1) {
            now
        }
        store.markThreadActive(threadID: "thread-live")

        XCTAssertThrowsError(try store.claimForSubmit(threadID: "thread-live")) { error in
            guard case BridgeInternalError.invalidRequest(let message) = error else {
                return XCTFail("expected invalid request, got \(error)")
            }
            XCTAssertEqual(message, "Codex app-server turn is already running.")
        }

        now = now.addingTimeInterval(2)
        XCTAssertNoThrow(try store.claimForSubmit(threadID: "thread-live"))
    }

    func testTurnStateStoreStaleTurnCompletedDoesNotClearThreadStatusActive() throws {
        let store = CodexAppServerTurnStateStore()
        store.markThreadActive(threadID: "thread-live")
        store.markCompleted(threadID: "thread-live", turnID: "stale-remote-turn")

        XCTAssertThrowsError(try store.claimForSubmit(threadID: "thread-live")) { error in
            guard case BridgeInternalError.invalidRequest(let message) = error else {
                return XCTFail("expected invalid request, got \(error)")
            }
            XCTAssertEqual(message, "Codex app-server turn is already running.")
        }

        store.markThreadIdle(threadID: "thread-live")
        XCTAssertNoThrow(try store.claimForSubmit(threadID: "thread-live"))
    }

    func testTurnStateStoreThreadStatusIdleDoesNotClearRemotePendingOrTurnActive() throws {
        let store = CodexAppServerTurnStateStore()
        try store.claimForSubmit(threadID: "thread-live")
        store.markThreadIdle(threadID: "thread-live")

        XCTAssertThrowsError(try store.claimForSubmit(threadID: "thread-live")) { error in
            guard case BridgeInternalError.invalidRequest(let message) = error else {
                return XCTFail("expected invalid request, got \(error)")
            }
            XCTAssertEqual(message, "Codex app-server turn is already running.")
        }

        store.markStarted(threadID: "thread-live", turnID: "remote-turn")
        store.markThreadIdle(threadID: "thread-live")

        XCTAssertThrowsError(try store.claimForSubmit(threadID: "thread-live")) { error in
            guard case BridgeInternalError.invalidRequest(let message) = error else {
                return XCTFail("expected invalid request, got \(error)")
            }
            XCTAssertEqual(message, "Codex app-server turn is already running.")
        }

        store.markCompleted(threadID: "thread-live", turnID: "remote-turn")
        XCTAssertNoThrow(try store.claimForSubmit(threadID: "thread-live"))
    }

    func testTurnStateStoreThreadStatusIdleClearsAppServerOriginTurnActive() throws {
        let store = CodexAppServerTurnStateStore()
        store.markStarted(threadID: "thread-live", turnID: "tui-turn")

        XCTAssertThrowsError(try store.claimForSubmit(threadID: "thread-live")) { error in
            guard case BridgeInternalError.invalidRequest(let message) = error else {
                return XCTFail("expected invalid request, got \(error)")
            }
            XCTAssertEqual(message, "Codex app-server turn is already running.")
        }

        store.markThreadIdle(threadID: "thread-live")

        XCTAssertNoThrow(try store.claimForSubmit(threadID: "thread-live"))
    }

    func testSubmitMessageReleasesBusyGuardWhenTurnStartRequestFails() throws {
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
        try Self.loadThread("thread-live", on: transport)

        try session.submitMessage(text: "first")
        let firstTurnStart = try Self.object(from: try XCTUnwrap(transport.sentLines().last))
        let firstTurnStartID = try XCTUnwrap(firstTurnStart["id"])
        transport.emitLine(try Self.errorResponseText(id: firstTurnStartID,
                                                      code: -32000,
                                                      message: "turn start failed"))

        try session.submitMessage(text: "retry after failure")
        let turnStart = try Self.object(from: try XCTUnwrap(transport.sentLines().last))
        let turnParams = try XCTUnwrap(turnStart["params"]?.objectValue)
        XCTAssertEqual(turnParams["input"]?.arrayValue?.first?.objectValue?["text"]?.stringValue, "retry after failure")
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

    func testTransportCloseMarksAttachedRuntimeStopped() throws {
        let (session, transport) = try Self.makeAttachedSession()
        try Self.acknowledgeInitialize(from: transport)
        XCTAssertFalse(session.isStopped())

        transport.emitClose(CodexAppServerTransportError.closed)

        XCTAssertTrue(Self.waitFor { session.isStopped() })
        XCTAssertFalse(session.canSubmitMessage())
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

    func testUnixWebSocketConnectorAcceptsLargeReplayFrames() throws {
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
        let replayPayload = String(repeating: "x", count: 17 * 1024 * 1024)
        let receivedReplay = expectation(description: "client receives app-server replay frame larger than 16 MB")

        let upgrader = NIOWebSocketServerUpgrader(
            maxFrameSize: 1 << 20,
            shouldUpgrade: { _, _ in
                let promise = group.next().makePromise(of: HTTPHeaders?.self)
                promise.succeed(HTTPHeaders())
                return promise.futureResult
            },
            upgradePipelineHandler: { channel, _ in
                var buffer = channel.allocator.buffer(capacity: replayPayload.utf8.count)
                buffer.writeString(replayPayload)
                let frame = WebSocketFrame(fin: true, opcode: .text, data: buffer)
                channel.eventLoop.scheduleTask(in: .milliseconds(10)) {
                    channel.writeAndFlush(frame, promise: nil)
                }
                return channel.eventLoop.makeSucceededFuture(())
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
        _ = try connector.connect(mode: .unixSocket(path: socketPath),
                                  onLine: { text in
                                      if text.count == replayPayload.count {
                                          receivedReplay.fulfill()
                                      }
                                  },
                                  onClose: { _ in })

        wait(for: [receivedReplay], timeout: 5.0)
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

    private static func makeAttachedSession() throws -> (CodexAppServerRuntimeSession, FakeCodexAppServerConnectionTransport) {
        let connector = FakeCodexAppServerTransportConnector()
        let factory = CodexAppServerRuntimeSessionFactory(processRunner: FakeCodexAppServerProcessRunner(),
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
        return (session, try XCTUnwrap(connector.transport))
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

    private static func ambiguousLoadedThreadsResult() -> JSONValue {
        .object([
            "threads": .array([
                .object([
                    "id": .string("thread-a"),
                    "preview": .string("Thread A"),
                ]),
                .object([
                    "id": .string("thread-b"),
                    "preview": .string("Thread B"),
                ]),
            ]),
        ])
    }

    private static func errorResponseText(id: JSONValue, code: Int, message: String) throws -> String {
        let idData = try JSONEncoder().encode(id)
        let idText = String(decoding: idData, as: UTF8.self)
        let errorData = try JSONEncoder().encode(JSONValue.object([
            "code": .number(Double(code)),
            "message": .string(message),
        ]))
        let errorText = String(decoding: errorData, as: UTF8.self)
        return #"{"id":\#(idText),"error":\#(errorText)}"#
    }

    private static func loadThread(_ threadID: String,
                                   on transport: FakeCodexAppServerConnectionTransport,
                                   file: StaticString = #filePath,
                                   line sourceLine: UInt = #line) throws {
        let listLoaded = try object(from: try XCTUnwrap(transport.sentLines().dropFirst(2).first,
                                                        file: file,
                                                        line: sourceLine),
                                    file: file,
                                    line: sourceLine)
        XCTAssertEqual(listLoaded["method"]?.stringValue, "thread/loaded/list", file: file, line: sourceLine)
        let listLoadedID = try XCTUnwrap(listLoaded["id"], file: file, line: sourceLine)
        transport.emitLine(try responseText(id: listLoadedID, result: .object([
            "threads": .array([
                .object([
                    "id": .string(threadID),
                    "preview": .string("Mac TUI Codex"),
                    "updatedAt": .string("2026-06-07T00:00:00.000Z"),
                ]),
            ]),
        ])))
        XCTAssertTrue(waitForSentLineCount(4, transport: transport), file: file, line: sourceLine)
    }

    private static func waitForSentLineCount(_ count: Int,
                                             transport: FakeCodexAppServerConnectionTransport,
                                             timeout: TimeInterval = 2.0,
                                             poll: (() -> Void)? = nil) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if transport.sentLines().count >= count {
                return true
            }
            poll?()
            Thread.sleep(forTimeInterval: 0.01)
        }
        return transport.sentLines().count >= count
    }

    private static func waitFor(timeout: TimeInterval = 2,
                                condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return true
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return condition()
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

final class FakeCodexAppServerTransportConnector: CodexAppServerTransportConnecting {
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

final class FakeCodexAppServerConnectionTransport: CodexAppServerConnectionTransport {
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

    func emitClose(_ error: Error? = nil) {
        onClose(error)
    }

    func sentLines() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return lines
    }
}

final class FakeCodexAppServerProcessRunner: CodexAppServerProcessRunning {
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

final class FakeCodexAppServerManagedProcess: CodexAppServerManagedProcess {
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
