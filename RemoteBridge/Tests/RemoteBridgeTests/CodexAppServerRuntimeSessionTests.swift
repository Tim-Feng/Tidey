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

    func testFactoryCarriesExplicitAppServerEpochIntoApprovalContext() throws {
        let connector = FakeCodexAppServerTransportConnector()
        let factory = CodexAppServerRuntimeSessionFactory(
            processRunner: FakeCodexAppServerProcessRunner(),
            transportConnector: connector)
        let prompts = PromptSink()
        let epoch = "pid:9001|sock:/tmp/tidey-real-panel/app.sock"
        let session = try factory.attach(
            socketPath: "/tmp/tidey-real-panel/app.sock",
            processID: 9001,
            context: CodexAppServerRuntimeContext(workspaceID: "workspace-1",
                                                  panelID: "panel-1",
                                                  sessionID: "session-1"),
            epoch: epoch,
            nextSequence: { _ in 1 },
            timestampProvider: { "2026-06-07T00:00:00.000Z" },
            onAgentEvent: { _ in },
            onInteractivePrompt: { prompts.append($0) },
            onInteractivePromptResolved: { _ in })

        let transport = try XCTUnwrap(connector.transport)
        transport.emitLine("""
        {"id":"approval-epoch","method":"item/commandExecution/requestApproval","params":{"threadId":"thread-1","turnId":"turn-1","itemId":"cmd-1","startedAtMs":1786000000000,"command":"ls"}}
        """)

        let envelope = try XCTUnwrap(prompts.envelopes().first)
        XCTAssertEqual(envelope.event.metadata?["app_server_epoch"], epoch)
        XCTAssertEqual(envelope.prompt.promptID,
                       envelope.request.makePrompt(epoch: epoch).promptID)
        XCTAssertNotEqual(envelope.prompt.promptID,
                          envelope.request.makePrompt().promptID)
        withExtendedLifetime(session) {}
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

        let turnStart = try awaitSubmitMessage(session, text: "hello from remote", transport: transport)
        XCTAssertEqual(turnStart["method"]?.stringValue, "turn/start")
        let turnParams = try XCTUnwrap(turnStart["params"]?.objectValue)
        XCTAssertEqual(turnParams["threadId"]?.stringValue, "thread-live")
        XCTAssertEqual(turnParams["input"]?.arrayValue?.first?.objectValue?["text"]?.stringValue, "hello from remote")
    }

    func testThreadResumeWithUnambiguousInProgressTurnSeedsSteerTarget() throws {
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
                .object(["id": .string("thread-live"), "preview": .string("Mac TUI Codex"), "updatedAt": .string("2026-06-07T00:00:00.000Z")]),
            ]),
        ])))

        XCTAssertTrue(Self.waitForSentLineCount(4, transport: transport))
        let resume = try Self.object(from: try XCTUnwrap(transport.sentLines().dropFirst(3).first))
        XCTAssertEqual(resume["method"]?.stringValue, "thread/resume")
        let resumeID = try XCTUnwrap(resume["id"])

        // A live, already-working thread: status active plus one inProgress
        // turn — exactly the shape thread/resume returns when Bridge
        // (re)attaches mid-turn.
        transport.emitLine(try Self.responseText(id: resumeID, result: .object([
            "thread": .object([
                "id": .string("thread-live"),
                "status": .object(["type": .string("active"), "activeFlags": .array([.string("turn")])]),
                "turns": .array([
                    .object(["id": .string("turn-A"), "status": .string("inProgress")]),
                ]),
            ]),
        ])))

        // The next submit must go straight to turn/steer(expectedTurnId:
        // "turn-A") — never turn/start, never a busyWithoutTurnID conflict.
        let steerRequest = try awaitSubmitMessage(session,
                                                  text: "steer into the already-running turn",
                                                  transport: transport,
                                                  respondWithResult: .object(["turnId": .string("turn-A")]))
        XCTAssertEqual(steerRequest["method"]?.stringValue, "turn/steer")
        let steerParams = try XCTUnwrap(steerRequest["params"]?.objectValue)
        XCTAssertEqual(steerParams["threadId"]?.stringValue, "thread-live")
        XCTAssertEqual(steerParams["expectedTurnId"]?.stringValue, "turn-A")
    }

    // Required test: a stale thread/resume response naming an inProgress
    // turn must never resurrect that turn if a LIVE notification (a
    // completion, or a newer turn/started) landed after the resume request
    // was sent — the revision barrier must invalidate it.
    func testStaleThreadResumeCannotResurrectATurnSupersededByALiveNotification() throws {
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
                .object(["id": .string("thread-live"), "preview": .string("Mac TUI Codex"), "updatedAt": .string("2026-06-07T00:00:00.000Z")]),
            ]),
        ])))

        XCTAssertTrue(Self.waitForSentLineCount(4, transport: transport))
        let resume = try Self.object(from: try XCTUnwrap(transport.sentLines().dropFirst(3).first))
        let resumeID = try XCTUnwrap(resume["id"])

        // A LIVE turn/started for a DIFFERENT turn (B) lands BEFORE the
        // resume response — the resume's barrier was captured before this,
        // so it is now stale relative to turn B.
        transport.emitLine("""
        {"method":"turn/started","params":{"threadId":"thread-live","turn":{"id":"turn-B","items":[],"itemsView":{"type":"all"},"status":"running","error":null,"startedAt":1,"completedAt":null,"durationMs":null}}}
        """)

        // The stale resume response now arrives, naming the OLD turn A as
        // inProgress — this must be discarded, not applied over turn B.
        transport.emitLine(try Self.responseText(id: resumeID, result: .object([
            "thread": .object([
                "id": .string("thread-live"),
                "status": .object(["type": .string("active"), "activeFlags": .array([.string("turn")])]),
                "turns": .array([
                    .object(["id": .string("turn-A"), "status": .string("inProgress")]),
                ]),
            ]),
        ])))

        // The next submit must steer into B (the live turn), never A (the
        // stale/superseded one the resume response tried to resurrect).
        let steerRequest = try awaitSubmitMessage(session,
                                                  text: "steer into the live turn",
                                                  transport: transport,
                                                  respondWithResult: .object(["turnId": .string("turn-B")]))
        XCTAssertEqual(steerRequest["method"]?.stringValue, "turn/steer")
        XCTAssertEqual(steerRequest["params"]?.objectValue?["expectedTurnId"]?.stringValue, "turn-B")

        // Turn B completes — the thread goes idle again.
        transport.emitLine("""
        {"method":"turn/completed","params":{"threadId":"thread-live","turn":{"id":"turn-B","items":[],"itemsView":{"type":"all"},"status":"completed","error":null,"startedAt":1,"completedAt":2,"durationMs":1000}}}
        """)
        let turnStart = try awaitSubmitMessage(session, text: "fresh turn after B completes", transport: transport)
        XCTAssertEqual(turnStart["method"]?.stringValue, "turn/start")
    }

    // Required test: an active-thread snapshot with zero or ambiguous
    // inProgress turns must still fail closed as busyWithoutTurnID — never
    // guess which turn to steer into, and zero submit transport either way.
    func testThreadResumeWithAmbiguousInProgressTurnsStaysFailClosed() throws {
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
                .object(["id": .string("thread-live"), "preview": .string("Mac TUI Codex"), "updatedAt": .string("2026-06-07T00:00:00.000Z")]),
            ]),
        ])))

        XCTAssertTrue(Self.waitForSentLineCount(4, transport: transport))
        let resume = try Self.object(from: try XCTUnwrap(transport.sentLines().dropFirst(3).first))
        let resumeID = try XCTUnwrap(resume["id"])

        // TWO inProgress turns — ambiguous, must never guess which one to
        // steer into.
        transport.emitLine(try Self.responseText(id: resumeID, result: .object([
            "thread": .object([
                "id": .string("thread-live"),
                "status": .object(["type": .string("active"), "activeFlags": .array([.string("turn")])]),
                "turns": .array([
                    .object(["id": .string("turn-A"), "status": .string("inProgress")]),
                    .object(["id": .string("turn-B"), "status": .string("inProgress")]),
                ]),
            ]),
        ])))

        let sentCountBeforeSubmit = transport.sentLines().count
        XCTAssertThrowsError(try session.submitMessage(text: "ambiguous", clientRequestID: nil)) { error in
            guard case CodexAppServerSubmitFailure.busyWithoutTurnID = error else {
                return XCTFail("expected busyWithoutTurnID, got \(error)")
            }
        }
        XCTAssertEqual(transport.sentLines().count, sentCountBeforeSubmit,
                       "zero submit transport for an ambiguous snapshot — never guess, never terminal-fallback")
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

        let turnStart = try awaitSubmitMessage(session, text: "hello current", transport: transport)
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
                try session.submitMessage(text: "must not guess", clientRequestID: nil)
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
        guard let submitError, case CodexAppServerSubmitFailure.unavailableBeforeSend = submitError else {
            return XCTFail("expected unavailableBeforeSend, got \(String(describing: submitError))")
        }
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
                try session.submitMessage(text: "hello after delayed thread", clientRequestID: nil)
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

        // Thread resolution unblocked the .start route, which now bounded-
        // waits for the app-server's authoritative turn/start response
        // before submitMessage() returns.
        XCTAssertTrue(Self.waitForSentLineCount(5, transport: transport))
        let turnStart = try Self.object(from: try XCTUnwrap(transport.sentLines().last))
        XCTAssertEqual(turnStart["method"]?.stringValue, "turn/start")
        let turnParams = try XCTUnwrap(turnStart["params"]?.objectValue)
        XCTAssertEqual(turnParams["threadId"]?.stringValue, "thread-live")
        XCTAssertEqual(turnParams["input"]?.arrayValue?.first?.objectValue?["text"]?.stringValue, "hello after delayed thread")
        transport.emitLine(try Self.responseText(id: try XCTUnwrap(turnStart["id"]),
                                                 result: .object(["turn": .object(["id": .string("turn-delayed")])])) )

        wait(for: [submitCompleted], timeout: 2.0)
        XCTAssertNil(submitError)
    }

    // Production regression (Automation, 2026-07-21): Codex can accept a
    // turn/start and return its authoritative `turn.id` without ever replaying
    // turn/started to this Bridge attachment. The response alone must
    // promote the pending claim into a steerable remote-origin turn.
    func testTurnStartSuccessResponseAloneSeedsSteerTarget() throws {
        let (session, transport) = try makeLoadedAttachedSession()

        let first = try beginSubmitMessage(session, text: "first", transport: transport)
        transport.emitLine(try Self.responseText(id: try XCTUnwrap(first.request["id"]),
                                                 result: .object(["turn": .object(["id": .string("turn-response")])])) )
        wait(for: [first.completion], timeout: 5)
        XCTAssertNil(first.error.get())

        let steer = try awaitSubmitMessage(session,
                                           text: "second",
                                           transport: transport,
                                           respondWithResult: .object(["turnId": .string("turn-response")]))
        XCTAssertEqual(steer["method"]?.stringValue, "turn/steer")
        XCTAssertEqual(steer["params"]?.objectValue?["expectedTurnId"]?.stringValue, "turn-response")
    }

    func testTurnStartSuccessResponseThenMatchingCompletionReturnsToStart() throws {
        let (session, transport) = try makeLoadedAttachedSession()

        let first = try awaitSubmitMessage(session,
                                           text: "first",
                                           transport: transport,
                                           respondWithResult: .object(["turn": .object(["id": .string("turn-response")])]))
        XCTAssertEqual(first["method"]?.stringValue, "turn/start")

        transport.emitLine(#"{"method":"turn/completed","params":{"threadId":"thread-live","turn":{"id":"turn-response","status":"completed"}}}"#)

        let next = try awaitSubmitMessage(session,
                                          text: "after completion",
                                          transport: transport,
                                          respondWithResult: .object(["turn": .object(["id": .string("turn-next")])]))
        XCTAssertEqual(next["method"]?.stringValue, "turn/start")
    }

    func testTurnStartedBeforeTurnStartResponseIsIdempotent() throws {
        let (session, transport) = try makeLoadedAttachedSession()

        let first = try beginSubmitMessage(session, text: "first", transport: transport)
        transport.emitLine(#"{"method":"turn/started","params":{"threadId":"thread-live","turn":{"id":"turn-live"}}}"#)
        transport.emitLine(try Self.responseText(id: try XCTUnwrap(first.request["id"]),
                                                 result: .object(["turn": .object(["id": .string("turn-live")])])) )
        wait(for: [first.completion], timeout: 5)
        XCTAssertNil(first.error.get())

        let steer = try awaitSubmitMessage(session,
                                           text: "second",
                                           transport: transport,
                                           respondWithResult: .object(["turnId": .string("turn-live")]))
        XCTAssertEqual(steer["method"]?.stringValue, "turn/steer")
        XCTAssertEqual(steer["params"]?.objectValue?["expectedTurnId"]?.stringValue, "turn-live")
    }

    func testResumeSnapshotBeforeTurnStartResponseIsIdempotentAndPreservesRemoteOrigin() throws {
        let (session, transport) = try makeLoadedAttachedSession()

        let first = try beginSubmitMessage(session, text: "first", transport: transport)
        let resumeID = try session.resumeThread(threadID: "thread-live", cwd: nil)
        transport.emitLine(try Self.responseText(id: .number(Double(resumeID)),
                                                 result: Self.inProgressResumeResult(threadID: "thread-live",
                                                                                     turnID: "turn-resumed")))
        transport.emitLine(try Self.responseText(id: try XCTUnwrap(first.request["id"]),
                                                 result: .object(["turn": .object(["id": .string("turn-resumed")])])) )
        wait(for: [first.completion], timeout: 5)
        XCTAssertNil(first.error.get())

        transport.emitLine(#"{"method":"thread/status/changed","params":{"threadId":"thread-live","status":{"type":"idle"}}}"#)
        let steer = try awaitSubmitMessage(session,
                                           text: "second",
                                           transport: transport,
                                           respondWithResult: .object(["turnId": .string("turn-resumed")]))
        XCTAssertEqual(steer["method"]?.stringValue, "turn/steer")
        XCTAssertEqual(steer["params"]?.objectValue?["expectedTurnId"]?.stringValue, "turn-resumed")
    }

    func testMatchingCompletionBeforeTurnStartResponseDoesNotResurrectCompletedTurn() throws {
        let (session, transport) = try makeLoadedAttachedSession()

        let first = try beginSubmitMessage(session, text: "first", transport: transport)
        transport.emitLine(#"{"method":"turn/completed","params":{"threadId":"thread-live","turn":{"id":"turn-fast","status":"completed"}}}"#)
        transport.emitLine(try Self.responseText(id: try XCTUnwrap(first.request["id"]),
                                                 result: .object(["turn": .object(["id": .string("turn-fast")])])) )
        wait(for: [first.completion], timeout: 5)
        XCTAssertNil(first.error.get())

        let next = try awaitSubmitMessage(session,
                                          text: "after fast completion",
                                          transport: transport,
                                          respondWithResult: .object(["turn": .object(["id": .string("turn-next")])]))
        XCTAssertEqual(next["method"]?.stringValue, "turn/start",
                       "the late success response must retire its claim, never resurrect the already-completed turn")
    }

    func testLateFirstClaimResponseCannotOverwriteSecondClaimAfterExpiry() throws {
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
        XCTAssertEqual(store.routeSubmit(threadID: "thread-live"), .busyWithoutTurnID,
                       "P1's late response must not consume or replace P2's pending claim")

        store.reconcileAcceptedStart(threadID: "thread-live",
                                     claimID: secondClaimID,
                                     turnID: "turn-current")
        XCTAssertEqual(store.routeSubmit(threadID: "thread-live"), .steer(turnID: "turn-current"))
    }

    func testTurnStartSuccessWithoutNonblankTurnIDFailsClosed() throws {
        let malformedResults: [JSONValue] = [
            .object([:]),
            .object(["turn": .object([:])]),
            .object(["turn": .object(["id": .string("  \n")])]),
            .object(["turnId": .string("turn-steer-response-shape")]),
            .object(["turnId": .string("  \n")]),
        ]

        for (index, malformedResult) in malformedResults.enumerated() {
            let (session, transport) = try makeLoadedAttachedSession()
            let first = try beginSubmitMessage(session,
                                               text: "malformed-\(index)",
                                               transport: transport)
            transport.emitLine(try Self.responseText(id: try XCTUnwrap(first.request["id"]),
                                                     result: malformedResult))
            wait(for: [first.completion], timeout: 5)

            guard let error = first.error.get() else {
                XCTFail("row \(index): missing/blank turn.id must be indeterminate, never success")
                continue
            }
            XCTAssertTrue(error is CodexAppServerInvalidTurnStartResponseError,
                          "row \(index): expected invalid turn/start response, got \(error)")

            let sentCount = transport.sentLines().count
            XCTAssertThrowsError(try session.submitMessage(text: "must stay blocked", clientRequestID: nil)) { error in
                guard case CodexAppServerSubmitFailure.busyWithoutTurnID = error else {
                    return XCTFail("row \(index): expected fail-closed pending claim, got \(error)")
                }
            }
            XCTAssertEqual(transport.sentLines().count, sentCount,
                           "row \(index): malformed success must never permit a second wire request")
        }
    }

    // Required test: idle with no known active turn — a submit while
    // pending (claimed but no turn/started observed yet) has no turn id to
    // steer into, so it must route to .busyWithoutTurnID, a typed conflict.
    // Once turn/started lands with a known turn id, a further submit must
    // route to a native turn/steer INTO that turn — never a new turn/start,
    // never a rejection — and after the turn completes, a submit goes back
    // to exactly one fresh turn/start.
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

        let first = try beginSubmitMessage(session, text: "first", transport: transport)
        let sentCountAfterFirstSubmit = transport.sentLines().count

        // Pending submit claimed, but turn/started has not arrived yet — no
        // known turn id to steer into. Typed conflict, zero transport
        // attempt (no turn/start, no turn/steer).
        XCTAssertThrowsError(try session.submitMessage(text: "second", clientRequestID: nil)) { error in
            guard case CodexAppServerSubmitFailure.busyWithoutTurnID = error else {
                return XCTFail("expected busyWithoutTurnID, got \(error)")
            }
        }
        XCTAssertEqual(transport.sentLines().count, sentCountAfterFirstSubmit)

        // The authoritative response supplies the exact turn identity even
        // if turn/started is delayed or omitted.
        transport.emitLine(try Self.responseText(id: try XCTUnwrap(first.request["id"]),
                                                 result: .object(["turn": .object(["id": .string("turn-1")])])) )
        wait(for: [first.completion], timeout: 5)
        XCTAssertNil(first.error.get())

        // A matching later notification is idempotent and preserves the
        // response-established remote turn.
        transport.emitLine("""
        {"method":"turn/started","params":{"threadId":"thread-live","turn":{"id":"turn-1","items":[],"itemsView":{"type":"all"},"status":"running","error":null,"startedAt":1,"completedAt":null,"durationMs":null}}}
        """)

        // Now a known active turn id exists — the submit must go out as a
        // native turn/steer into that exact turn, never a new turn/start.
        let steerRequest = try awaitSubmitMessage(session,
                                                  text: "still busy",
                                                  transport: transport,
                                                  respondWithResult: .object(["turnId": .string("turn-1")]))
        XCTAssertEqual(transport.sentLines().count, sentCountAfterFirstSubmit + 1)
        XCTAssertEqual(steerRequest["method"]?.stringValue, "turn/steer")
        let steerParams = try XCTUnwrap(steerRequest["params"]?.objectValue)
        XCTAssertEqual(steerParams["threadId"]?.stringValue, "thread-live")
        XCTAssertEqual(steerParams["expectedTurnId"]?.stringValue, "turn-1")
        XCTAssertEqual(steerParams["input"]?.arrayValue?.first?.objectValue?["type"]?.stringValue, "text")
        XCTAssertEqual(steerParams["input"]?.arrayValue?.first?.objectValue?["text"]?.stringValue, "still busy")

        transport.emitLine("""
        {"method":"turn/completed","params":{"threadId":"thread-live","turn":{"id":"turn-1","items":[],"itemsView":{"type":"all"},"status":"completed","error":null,"startedAt":1,"completedAt":2,"durationMs":1000}}}
        """)

        let turnStart = try awaitSubmitMessage(session, text: "after completion", transport: transport)
        XCTAssertEqual(turnStart["method"]?.stringValue, "turn/start")
        let turnParams = try XCTUnwrap(turnStart["params"]?.objectValue)
        XCTAssertEqual(turnParams["input"]?.arrayValue?.first?.objectValue?["text"]?.stringValue, "after completion")
    }

    // Required test: a known active turn (A) completes/is replaced before
    // the steer request lands, so expectedTurnId no longer matches — the
    // app-server sends a DEFINITE JSON-RPC rejection. This is a typed,
    // zero-semantic-effect rejection (CodexAppServerSubmitFailure.rejected)
    // — never a terminal fallback trigger, never a false success.
    func testSubmitMessageSteerRejectionForCompletedTurnDoesNotFallbackOrSucceed() throws {
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

        try awaitSubmitMessage(session, text: "first", transport: transport)
        transport.emitLine("""
        {"method":"turn/started","params":{"threadId":"thread-live","turn":{"id":"turn-A","items":[],"itemsView":{"type":"all"},"status":"running","error":null,"startedAt":1,"completedAt":null,"durationMs":null}}}
        """)

        let sentCountBeforeSteer = transport.sentLines().count
        let steerCompleted = expectation(description: "steer rejection surfaces")
        var steerError: Error?
        DispatchQueue.global().async {
            do {
                try session.submitMessage(text: "steer into A", clientRequestID: nil)
            } catch {
                steerError = error
            }
            steerCompleted.fulfill()
        }
        XCTAssertTrue(Self.waitForSentLineCount(sentCountBeforeSteer + 1, transport: transport))
        let steerRequest = try Self.object(from: try XCTUnwrap(transport.sentLines().last))
        XCTAssertEqual(steerRequest["method"]?.stringValue, "turn/steer")
        let steerRequestID = try XCTUnwrap(steerRequest["id"])

        // The app-server rejects the steer: turn A already completed/was
        // replaced, so expectedTurnId no longer matches.
        transport.emitLine(try Self.errorResponseText(id: steerRequestID,
                                                      code: -32000,
                                                      message: "expectedTurnId does not match the active turn"))
        wait(for: [steerCompleted], timeout: 5)

        guard let steerError, case CodexAppServerSubmitFailure.rejected = steerError else {
            return XCTFail("expected a typed rejection, got \(String(describing: steerError))")
        }
        let sentCountAfterRejection = transport.sentLines().count

        // A rejected steer must never trigger an automatic retry, a new
        // turn/start, or any terminal-input transport — the caller
        // (BridgeInputActionHandler) is responsible for treating this as a
        // conflict, never as a fallback trigger or a false success.
        XCTAssertEqual(sentCountAfterRejection, sentCountBeforeSteer + 1,
                       "no automatic retry or fallback transport attempt follows a steer rejection")

        // The turn-state store must not be corrupted by the rejection — it
        // still reflects turn A as the last-known active turn until a real
        // turn/started or turn/completed notification says otherwise.
        XCTAssertFalse(session.canSubmitMessage(), "turn A's busy state is unaffected by an out-of-band steer rejection")
    }

    // Required test (round 4 correction): a SUCCESSFUL turn/steer response
    // whose turnId doesn't match expectedTurnId is NOT a definite rejection
    // — the server said success, so it may have accepted the input into
    // turn-B. This must surface as an indeterminate error (never
    // CodexAppServerSubmitFailure.rejected), so the handler marks the
    // reservation indeterminate rather than cancelling/allowing a retry.
    func testSubmitMessageSteerSuccessWithMismatchedTurnIDIsIndeterminateNotRejected() throws {
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

        try awaitSubmitMessage(session, text: "first", transport: transport)
        transport.emitLine("""
        {"method":"turn/started","params":{"threadId":"thread-live","turn":{"id":"turn-A","items":[],"itemsView":{"type":"all"},"status":"running","error":null,"startedAt":1,"completedAt":null,"durationMs":null}}}
        """)

        // Steer succeeds, but the response names turn-B, not the expected
        // turn-A — a protocol violation / unknown semantic destination.
        XCTAssertThrowsError(try awaitSubmitMessage(session,
                                                    text: "steer into A but landed on B",
                                                    transport: transport,
                                                    respondWithResult: .object(["turnId": .string("turn-B")]))) { error in
            if case CodexAppServerSubmitFailure.rejected = error {
                XCTFail("a mismatched-but-successful turnId must never be classified as a definite rejection")
            }
            if case CodexAppServerSubmitFailure.busyWithoutTurnID = error {
                XCTFail("a mismatched-but-successful turnId must never be classified as the zero-effect busyWithoutTurnID case")
            }
            guard error is CodexAppServerTurnIDMismatchError else {
                return XCTFail("expected CodexAppServerTurnIDMismatchError, got \(error)")
            }
        }
    }

    // The diagnostic reflects pending and active work. It is not the submit
    // authority; submitMessage() still owns the atomic start/steer/busy route.
    func testCanSubmitMessageIsFalseWhileTurnIsBusy() throws {
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

        XCTAssertTrue(session.canSubmitMessage(), "idle thread with no in-flight turn can submit")

        // submitMessage() now bounded-waits for the turn/start response, so
        // dispatch it in the background to observe the busy state WHILE it
        // is still in flight (claimed but not yet answered).
        let firstSentCount = transport.sentLines().count
        let firstCompleted = expectation(description: "first submit completes")
        var firstError: Error?
        DispatchQueue.global().async {
            do {
                try session.submitMessage(text: "first", clientRequestID: nil)
            } catch {
                firstError = error
            }
            firstCompleted.fulfill()
        }
        XCTAssertTrue(Self.waitForSentLineCount(firstSentCount + 1, transport: transport))
        XCTAssertFalse(session.canSubmitMessage(), "a pending submit (claimed, turn/started not yet observed) is busy")

        transport.emitLine("""
        {"method":"turn/started","params":{"threadId":"thread-live","turn":{"id":"turn-1","items":[],"itemsView":{"type":"all"},"status":"running","error":null,"startedAt":1,"completedAt":null,"durationMs":null}}}
        """)
        XCTAssertFalse(session.canSubmitMessage(), "an actively running turn is busy")

        // Unblock the still-pending first submitMessage() bounded wait.
        let firstRequest = try Self.object(from: try XCTUnwrap(transport.sentLines()[firstSentCount]))
        transport.emitLine(try Self.responseText(id: try XCTUnwrap(firstRequest["id"]),
                                                 result: .object(["turn": .object(["id": .string("turn-1")])])) )
        wait(for: [firstCompleted], timeout: 5)
        XCTAssertNil(firstError)

        transport.emitLine("""
        {"method":"turn/completed","params":{"threadId":"thread-live","turn":{"id":"turn-1","items":[],"itemsView":{"type":"all"},"status":"completed","error":null,"startedAt":1,"completedAt":2,"durationMs":1000}}}
        """)
        XCTAssertTrue(session.canSubmitMessage(), "idle again after the turn completes")
        try awaitSubmitMessage(session, text: "after completion", transport: transport)
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

        // thread/status/changed reports the thread active, but no
        // turn/started has been observed — there is no known turn id to
        // steer into. Required behavior: typed conflict, zero transport
        // attempt (never a new turn/start, never a turn/steer).
        XCTAssertThrowsError(try session.submitMessage(text: "remote while TUI active", clientRequestID: nil)) { error in
            guard case CodexAppServerSubmitFailure.busyWithoutTurnID = error else {
                return XCTFail("expected busyWithoutTurnID, got \(error)")
            }
        }
        XCTAssertEqual(transport.sentLines().count, sentCountAfterActive)

        transport.emitLine("""
        {"method":"thread/status/changed","params":{"threadId":"thread-live","status":{"type":"idle"}}}
        """)

        let turnStart = try awaitSubmitMessage(session, text: "remote after TUI idle", transport: transport)
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

        let firstSentCount = transport.sentLines().count
        let firstCompleted = expectation(description: "first submit fails")
        var firstError: Error?
        DispatchQueue.global().async {
            do {
                try session.submitMessage(text: "first", clientRequestID: nil)
            } catch {
                firstError = error
            }
            firstCompleted.fulfill()
        }
        XCTAssertTrue(Self.waitForSentLineCount(firstSentCount + 1, transport: transport))
        let firstTurnStart = try Self.object(from: try XCTUnwrap(transport.sentLines().last))
        let firstTurnStartID = try XCTUnwrap(firstTurnStart["id"])
        transport.emitLine(try Self.errorResponseText(id: firstTurnStartID,
                                                      code: -32000,
                                                      message: "turn start failed"))
        wait(for: [firstCompleted], timeout: 5)
        guard let firstError, case CodexAppServerSubmitFailure.rejected = firstError else {
            return XCTFail("expected a typed rejection, got \(String(describing: firstError))")
        }

        // The definite rejection released the pending claim — a genuine
        // retry can proceed straight to a fresh turn/start.
        let turnStart = try awaitSubmitMessage(session, text: "retry after failure", transport: transport)
        let turnParams = try XCTUnwrap(turnStart["params"]?.objectValue)
        XCTAssertEqual(turnParams["input"]?.arrayValue?.first?.objectValue?["text"]?.stringValue, "retry after failure")
    }

    // Required test: submitMessage() forwards the caller's client_request_id
    // as clientUserMessageId on both the turn/start and turn/steer requests
    // — this preserves client identity through the app-server.
    func testSubmitMessagePassesClientRequestIDAsClientUserMessageID() throws {
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

        let turnStart = try awaitSubmitMessage(session,
                                               text: "first",
                                               clientRequestID: "client-a",
                                               transport: transport)
        XCTAssertEqual(turnStart["params"]?.objectValue?["clientUserMessageId"]?.stringValue, "client-a")

        transport.emitLine("""
        {"method":"turn/started","params":{"threadId":"thread-live","turn":{"id":"turn-1","items":[],"itemsView":{"type":"all"},"status":"running","error":null,"startedAt":1,"completedAt":null,"durationMs":null}}}
        """)

        let steerRequest = try awaitSubmitMessage(session,
                                                  text: "steer",
                                                  clientRequestID: "client-b",
                                                  transport: transport,
                                                  respondWithResult: .object(["turnId": .string("turn-1")]))
        XCTAssertEqual(steerRequest["method"]?.stringValue, "turn/steer")
        XCTAssertEqual(steerRequest["params"]?.objectValue?["clientUserMessageId"]?.stringValue, "client-b")
    }

    // Required test: a transport close or bounded-wait timeout before an
    // authoritative response is indeterminate, never zero-effect — the
    // pending claim must stay held so a DIFFERENT client_request_id cannot
    // issue a second turn/start while the first may still be in flight.
    func testSubmitMessageTransportCloseIsIndeterminateAndKeepsClaimHeld() throws {
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

        let sentCountBeforeFirst = transport.sentLines().count
        let firstCompleted = expectation(description: "first submit resolves to the transport closing")
        var firstError: Error?
        DispatchQueue.global().async {
            do {
                try session.submitMessage(text: "first", clientRequestID: "client-a")
            } catch {
                firstError = error
            }
            firstCompleted.fulfill()
        }
        XCTAssertTrue(Self.waitForSentLineCount(sentCountBeforeFirst + 1, transport: transport))

        // WHILE the first request is still in flight (no response yet), the
        // claim must remain held: a DIFFERENT client_request_id must not be
        // able to issue a second turn/start.
        XCTAssertThrowsError(try session.submitMessage(text: "second", clientRequestID: "client-b")) { error in
            guard case CodexAppServerSubmitFailure.busyWithoutTurnID = error else {
                return XCTFail("expected busyWithoutTurnID while the first submit's outcome is still unknown, got \(error)")
            }
        }
        XCTAssertEqual(transport.sentLines().count, sentCountBeforeFirst + 1,
                       "the second submit must never reach the transport while the first is unresolved")

        // The transport closes before any authoritative response arrives —
        // outcome unknown, not zero-effect. This must NOT be classified as
        // either zero-effect case (.busyWithoutTurnID or .rejected).
        transport.close()
        wait(for: [firstCompleted], timeout: 5)
        guard let firstError else {
            return XCTFail("expected the transport close to surface as an error")
        }
        if case CodexAppServerSubmitFailure.rejected = firstError {
            XCTFail("a transport close must not be classified as a definite JSON-RPC rejection")
        }
        if case CodexAppServerSubmitFailure.busyWithoutTurnID = firstError {
            XCTFail("a transport close must not be classified as the zero-effect busyWithoutTurnID case")
        }
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

    func testSessionLifecycleApprovalForwardsCapabilityAndClientRequestIdentity() throws {
        let runner = FakeCodexAppServerProcessRunner()
        let prompts = PromptSink()
        let session = try Self.makeSession(runner: runner, prompts: prompts)
        runner.process?.emitStdout("""
        {"id":"approval-lifecycle","method":"item/commandExecution/requestApproval","params":{"threadId":"thread-1","turnId":"turn-1","itemId":"cmd-lifecycle","startedAtMs":1786000000000,"command":"ls"}}
        """)
        let envelope = try XCTUnwrap(prompts.envelopes().first)

        let outcome = try session.submitApproval(promptID: envelope.prompt.promptID,
                                                 targetIndex: 0,
                                                 clientRequestID: "client-lifecycle",
                                                 lifecycleToken: envelope.event.eventID)

        guard case .pendingConfirmation(let promptID) = outcome else {
            return XCTFail("expected pendingConfirmation, got \(outcome)")
        }
        XCTAssertEqual(promptID, envelope.prompt.promptID)
        let pending = try XCTUnwrap(session.pendingApprovalPromptEvents().first)
        XCTAssertEqual(pending.metadata?["submit_state"], "submitting")
        XCTAssertEqual(pending.metadata?["client_request_id"], "client-lifecycle")
        XCTAssertEqual(AgentInteractivePromptSidebarMessages.lifecycleToken(from: pending),
                       envelope.event.eventID)
        let process = try XCTUnwrap(runner.process)
        let response = try Self.object(from: process.stdinLines().last ?? "")
        XCTAssertEqual(response["id"]?.stringValue, "approval-lifecycle")
        XCTAssertEqual(response["result"]?.objectValue?["decision"]?.stringValue, "accept")
    }

    func testFactoryStartedSocketSessionRoutesLifecycleApprovalThroughConfirmedTransportWrite() throws {
        let runner = FakeCodexAppServerProcessRunner()
        let connector = FakeCodexAppServerTransportConnector()
        let prompts = PromptSink()
        let session = try Self.makeSession(
            configuration: .unixSocket(codexExecutablePath: "/tmp/disposable-codex",
                                       socketPath: "/tmp/tidey-codex-sidecar/app.sock",
                                       workingDirectory: "/tmp/tidey-codex-disposable",
                                       environment: [:]),
            runner: runner,
            connector: connector,
            prompts: prompts
        )
        let transport = try XCTUnwrap(connector.transport)
        transport.emitLine(Self.approvalRequestLine(id: "approval-start"))
        let envelope = try XCTUnwrap(prompts.envelopes().first)

        _ = try session.submitApproval(promptID: envelope.prompt.promptID,
                                       targetIndex: 0,
                                       clientRequestID: "client-start",
                                       lifecycleToken: envelope.event.eventID)

        let response = try Self.object(from: try XCTUnwrap(transport.confirmedSentLines().last))
        XCTAssertEqual(response["id"]?.stringValue, "approval-start")
        XCTAssertFalse(transport.sentLines().contains { line in
            (try? Self.object(from: line)["id"]?.stringValue) == "approval-start"
        })
    }

    func testFactoryAttachedSessionRoutesLifecycleApprovalThroughConfirmedTransportWrite() throws {
        let connector = FakeCodexAppServerTransportConnector()
        let prompts = PromptSink()
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
                                         onInteractivePrompt: { prompts.append($0) },
                                         onInteractivePromptResolved: { prompts.appendResolved($0) })
        let transport = try XCTUnwrap(connector.transport)
        transport.emitLine(Self.approvalRequestLine(id: "approval-attach"))
        let envelope = try XCTUnwrap(prompts.envelopes().first)

        _ = try session.submitApproval(promptID: envelope.prompt.promptID,
                                       targetIndex: 0,
                                       clientRequestID: "client-attach",
                                       lifecycleToken: envelope.event.eventID)

        let response = try Self.object(from: try XCTUnwrap(transport.confirmedSentLines().last))
        XCTAssertEqual(response["id"]?.stringValue, "approval-attach")
        XCTAssertFalse(transport.sentLines().contains { line in
            (try? Self.object(from: line)["id"]?.stringValue) == "approval-attach"
        })
    }

    func testStartedStdioSessionDoesNotConfirmApprovalBeforeProcessWriteCompletes() throws {
        let runner = FakeCodexAppServerProcessRunner()
        let prompts = PromptSink()
        let session = try Self.makeSession(runner: runner, prompts: prompts)
        let process = try XCTUnwrap(runner.process)
        process.emitStdout(Self.approvalRequestLine(id: "approval-stdio-blocked"))
        let envelope = try XCTUnwrap(prompts.envelopes().first)
        let writeEntered = DispatchSemaphore(value: 0)
        let releaseWrite = DispatchSemaphore(value: 0)
        process.setSendLineHook { _ in
            writeEntered.signal()
            releaseWrite.wait()
        }
        let submit = DispatchGroup()
        let submitError = ThreadSafeErrorBox()
        submit.enter()
        DispatchQueue.global().async {
            defer { submit.leave() }
            do {
                _ = try session.submitApproval(promptID: envelope.prompt.promptID,
                                               targetIndex: 0,
                                               clientRequestID: "client-stdio-blocked",
                                               lifecycleToken: envelope.event.eventID)
            } catch {
                submitError.set(error)
            }
        }

        XCTAssertEqual(writeEntered.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(submit.wait(timeout: .now() + 0.05), .timedOut,
                       "stdio confirmation returned before the process write completed")
        releaseWrite.signal()
        XCTAssertEqual(submit.wait(timeout: .now() + 1), .success)
        XCTAssertNil(submitError.get())
    }

    func testStartedStdioSessionPropagatesConfirmedProcessWriteFailure() throws {
        let runner = FakeCodexAppServerProcessRunner()
        let prompts = PromptSink()
        let session = try Self.makeSession(runner: runner, prompts: prompts)
        let process = try XCTUnwrap(runner.process)
        process.emitStdout(Self.approvalRequestLine(id: "approval-stdio-failure"))
        let envelope = try XCTUnwrap(prompts.envelopes().first)
        process.setSendLineHook { _ in
            throw CodexAppServerProcessError.closed
        }

        XCTAssertThrowsError(try session.submitApproval(promptID: envelope.prompt.promptID,
                                                         targetIndex: 0,
                                                         clientRequestID: "client-stdio-failure",
                                                         lifecycleToken: envelope.event.eventID)) { error in
            guard case CodexAppServerProcessError.closed = error else {
                return XCTFail("expected process write failure, got \(error)")
            }
        }
    }

    func testSessionLifecycleUserInputForwardsStrictStructuredWireShape() throws {
        let runner = FakeCodexAppServerProcessRunner()
        let prompts = PromptSink()
        let session = try Self.makeSession(runner: runner, prompts: prompts)
        runner.process?.emitStdout("""
        {"id":"input-lifecycle","method":"item/tool/requestUserInput","params":{"threadId":"thread-1","turnId":"turn-1","itemId":"input-1","questions":[{"id":"format","header":"Output","question":"Which format?","options":[{"label":"PNG","description":"Lossless"}]},{"id":"notes","header":"Notes","question":"Any notes?"}]}}
        """)
        let envelope = try XCTUnwrap(prompts.envelopes().first)
        let answers = [
            "format": ["PNG"],
            "notes": ["keep alpha", "lossless"],
        ]

        let outcome = try session.submitUserInput(promptID: envelope.prompt.promptID,
                                                  answers: answers,
                                                  clientRequestID: "client-input",
                                                  lifecycleToken: envelope.event.eventID)

        guard case .pendingConfirmation(let promptID) = outcome else {
            return XCTFail("expected pendingConfirmation, got \(outcome)")
        }
        XCTAssertEqual(promptID, envelope.prompt.promptID)
        let pending = try XCTUnwrap(session.pendingApprovalPromptEvents().first)
        XCTAssertEqual(pending.metadata?["client_request_id"], "client-input")
        let process = try XCTUnwrap(runner.process)
        let response = try Self.object(from: process.stdinLines().last ?? "")
        let wireAnswers = try XCTUnwrap(response["result"]?.objectValue?["answers"]?.objectValue)
        XCTAssertEqual(wireAnswers["format"]?.objectValue?["answers"]?.arrayValue,
                       [.string("PNG")])
        XCTAssertEqual(wireAnswers["notes"]?.objectValue?["answers"]?.arrayValue,
                       [.string("keep alpha"), .string("lossless")])
        XCTAssertEqual(Set(wireAnswers.keys), Set(answers.keys),
                       "the userInput response must not invent or flatten answer fields")
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

    func testAttachedProtocolViolationClosesChannelWithoutTerminatingExternalProcessAndCanReattach() throws {
        let runner = FakeCodexAppServerProcessRunner()
        let connector = FakeCodexAppServerTransportConnector()
        let externalProcess = FakeCodexAppServerExternalProcess(processID: 9001)
        let factory = CodexAppServerRuntimeSessionFactory(
            processRunner: runner,
            transportConnector: connector,
            externalProcessFactory: { _ in externalProcess })
        let session = try Self.attachSession(factory: factory)
        let firstTransport = try XCTUnwrap(connector.transport)

        firstTransport.emitLine(Self.protocolOwnerLine)
        firstTransport.emitLine(Self.protocolCollisionLine)

        XCTAssertTrue(Self.waitFor { session.isStopped() })
        XCTAssertEqual(firstTransport.closeCallCount, 1)
        XCTAssertEqual(externalProcess.terminateCallCount, 0)
        XCTAssertTrue(runner.startedConfigurations.isEmpty)

        let replacement = try Self.attachSession(factory: factory)
        let replacementTransport = try XCTUnwrap(connector.transport)
        XCTAssertFalse(firstTransport === replacementTransport)
        XCTAssertEqual(replacementTransport.sentLines().count, 1)
        XCTAssertFalse(replacement.isStopped())

        replacement.stop()
        XCTAssertEqual(externalProcess.terminateCallCount, 0)
    }

    func testOwnedStdioProtocolViolationTerminatesProcessExactlyOnce() throws {
        let runner = FakeCodexAppServerProcessRunner()
        let session = try Self.makeSession(runner: runner)
        let process = try XCTUnwrap(runner.process)

        process.emitStdout(Self.protocolOwnerLine)
        process.emitStdout(Self.protocolCollisionLine)
        process.emitStdout(Self.protocolCollisionLine)
        session.stop()

        XCTAssertTrue(session.isStopped())
        XCTAssertEqual(process.terminateCallCount, 1)
    }

    func testProtocolViolationAndStopExpireApprovalsAndPendingClientHandlersExactlyOnce() throws {
        let connector = FakeCodexAppServerTransportConnector()
        let prompts = PromptSink()
        let factory = CodexAppServerRuntimeSessionFactory(
            processRunner: FakeCodexAppServerProcessRunner(),
            transportConnector: connector)
        let session = try factory.attach(
            socketPath: "/tmp/tidey-real-panel/app.sock",
            processID: 9001,
            context: CodexAppServerRuntimeContext(workspaceID: "workspace-1",
                                                  panelID: "panel-1",
                                                  sessionID: "session-1"),
            nextSequence: { _ in 1 },
            timestampProvider: { "2026-07-22T00:00:00.000Z" },
            onAgentEvent: { _ in },
            onInteractivePrompt: { prompts.append($0) },
            onInteractivePromptResolved: { prompts.appendResolved($0) })
        let transport = try XCTUnwrap(connector.transport)
        try Self.acknowledgeInitialize(from: transport)
        transport.emitLine(Self.pendingApprovalLine)
        XCTAssertEqual(session.pendingApprovalPromptEvents().count, 1)

        var clientResponses = [Result<JSONValue, CodexAppServerConnectionError>]()
        try session.startThread(cwd: nil) { clientResponses.append($0) }

        transport.emitLine(Self.protocolOwnerLine)
        transport.emitLine(Self.protocolCollisionLine)
        session.stop()
        transport.emitClose(CodexAppServerTransportError.closed)
        transport.emitLine(Self.protocolCollisionLine)

        let protocolTerminals = prompts.resolvedEvents().filter {
            $0.metadata?["reason"] == "protocol_violation"
        }
        XCTAssertEqual(protocolTerminals.count, 1)
        XCTAssertTrue(session.pendingApprovalPromptEvents().isEmpty)
        XCTAssertEqual(clientResponses.count, 1)
        guard case .failure(.protocolViolation) = clientResponses[0] else {
            return XCTFail("pending client handler must receive protocolViolation exactly once")
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

    private static let protocolOwnerLine =
        #"{"id":"collision-1","method":"unknown/method","params":{"value":1}}"#
    private static let protocolCollisionLine =
        #"{"id":"collision-1","method":"unknown/method","params":{"value":2}}"#
    private static let pendingApprovalLine =
        #"{"id":"approval-pending","method":"item/commandExecution/requestApproval","params":{"threadId":"thread-1","turnId":"turn-1","itemId":"item-1","startedAtMs":1786000000000,"command":"ls"}}"#

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
        let receivedConfirmedMessage = expectation(description: "server receives confirmed websocket text")
        let requestURI = RequestURIBox()
        let clientFrameMask = ClientFrameMaskBox()
        let serverChildChannel = ChannelBox()

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
                serverChildChannel.set(channel)
                return channel.pipeline.addHandler(ServerTextFrameHandler { text in
                    clientFrameMask.setObservedMaskedFrame()
                    if text == "{\"jsonrpc\":\"2.0\"}" {
                        receivedMessage.fulfill()
                    }
                    if text == "{\"fromEventLoop\":true}" {
                        receivedEventLoopMessage.fulfill()
                    }
                    if text == "{\"confirmed\":true}" {
                        receivedConfirmedMessage.fulfill()
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
        XCTAssertNoThrow(try transport.sendLineAwaitingWrite("{\"confirmed\":true}"))
        wait(for: [receivedMessage, receivedEventLoopMessage, receivedConfirmedMessage], timeout: 2.0)
        XCTAssertEqual(requestURI.get(), "/")
        XCTAssertEqual(clientFrameMask.didObserveMaskedFrame(), true)

        XCTAssertThrowsError(try group.next().submit {
            try transport.sendLineAwaitingWrite("{\"confirmedOnEventLoop\":true}")
        }.wait(), "a confirmed write must fail closed rather than block its own event loop") { error in
            guard case CodexAppServerTransportError.confirmationUnavailable = error else {
                return XCTFail("expected confirmationUnavailable, got \(error)")
            }
        }

        try XCTUnwrap(serverChildChannel.get()).close().wait()
        let deadline = Date().addingTimeInterval(2)
        var closedChannelWriteError: Error?
        repeat {
            do {
                try transport.sendLineAwaitingWrite("{\"afterPeerClose\":true}")
            } catch {
                closedChannelWriteError = error
                break
            }
            Thread.sleep(forTimeInterval: 0.02)
        } while Date() < deadline
        XCTAssertNotNil(closedChannelWriteError,
                        "a confirmed write must surface the channel write failure")
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

    private static func approvalRequestLine(id: String) -> String {
        """
        {"id":"\(id)","method":"item/commandExecution/requestApproval","params":{"threadId":"thread-1","turnId":"turn-1","itemId":"cmd-1","startedAtMs":1786000000000,"command":"ls"}}
        """
    }

    private static func makeAttachedSession() throws -> (CodexAppServerRuntimeSession, FakeCodexAppServerConnectionTransport) {
        let connector = FakeCodexAppServerTransportConnector()
        let factory = CodexAppServerRuntimeSessionFactory(processRunner: FakeCodexAppServerProcessRunner(),
                                                          transportConnector: connector)
        let session = try attachSession(factory: factory)
        return (session, try XCTUnwrap(connector.transport))
    }

    private static func attachSession(
        factory: CodexAppServerRuntimeSessionFactory
    ) throws -> CodexAppServerRuntimeSession {
        try factory.attach(socketPath: "/tmp/tidey-real-panel/app.sock",
                           processID: 9001,
                           context: CodexAppServerRuntimeContext(workspaceID: "workspace-1",
                                                                 panelID: "panel-1",
                                                                 sessionID: "session-1"),
                           nextSequence: { _ in 1 },
                           timestampProvider: { "2026-06-07T00:00:00.000Z" },
                           onAgentEvent: { _ in },
                           onInteractivePrompt: { _ in },
                           onInteractivePromptResolved: { _ in })
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

    private static func inProgressResumeResult(threadID: String, turnID: String) -> JSONValue {
        .object([
            "thread": .object([
                "id": .string(threadID),
                "status": .object(["type": .string("active"), "activeFlags": .array([.string("turn")])]),
                "turns": .array([.object(["id": .string(turnID), "status": .string("inProgress")])]),
            ]),
        ])
    }

    private func makeLoadedAttachedSession(threadID: String = "thread-live",
                                           file: StaticString = #filePath,
                                           line: UInt = #line) throws -> (CodexAppServerRuntimeSession, FakeCodexAppServerConnectionTransport) {
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
                                         timestampProvider: { "2026-07-21T07:38:54.274Z" },
                                         onAgentEvent: { _ in },
                                         onInteractivePrompt: { _ in },
                                         onInteractivePromptResolved: { _ in })
        let transport = try XCTUnwrap(connector.transport, file: file, line: line)
        try Self.acknowledgeInitialize(from: transport, file: file, line: line)
        try Self.loadThread(threadID, on: transport, file: file, line: line)
        return (session, transport)
    }

    private func beginSubmitMessage(_ session: CodexAppServerRuntimeSession,
                                    text: String,
                                    clientRequestID: String? = nil,
                                    transport: FakeCodexAppServerConnectionTransport,
                                    file: StaticString = #filePath,
                                    line: UInt = #line) throws -> (request: [String: JSONValue], completion: XCTestExpectation, error: ThreadSafeErrorBox) {
        let startCount = transport.sentLines().count
        let completion = expectation(description: "submitMessage completes: \(text)")
        let error = ThreadSafeErrorBox()
        DispatchQueue.global().async {
            do {
                try session.submitMessage(text: text, clientRequestID: clientRequestID)
            } catch let caught {
                error.set(caught)
            }
            completion.fulfill()
        }
        XCTAssertTrue(Self.waitForSentLineCount(startCount + 1, transport: transport), file: file, line: line)
        let request = try Self.object(from: try XCTUnwrap(transport.sentLines()[startCount], file: file, line: line),
                                      file: file,
                                      line: line)
        return (request, completion, error)
    }

    // submitMessage() is now a bounded wait for the app-server's
    // authoritative response (not a fire-and-forget write) — a direct
    // synchronous call would deadlock a single-threaded test that also
    // needs to emit that response. This helper dispatches the call to a
    // background queue, waits for the new outbound request line, emits a
    // SUCCESS response for it (unless the caller wants to inspect/emit
    // something different), then waits for submitMessage() to return and
    // rethrows anything it threw. Returns the outbound request object so
    // callers can assert on its shape.
    @discardableResult
    private func awaitSubmitMessage(_ session: CodexAppServerRuntimeSession,
                                    text: String,
                                    clientRequestID: String? = nil,
                                    transport: FakeCodexAppServerConnectionTransport,
                                    respondWithResult: JSONValue? = nil,
                                    file: StaticString = #filePath,
                                    line: UInt = #line) throws -> [String: JSONValue] {
        let startCount = transport.sentLines().count
        let completion = expectation(description: "submitMessage completes")
        var thrown: Error?
        DispatchQueue.global().async {
            do {
                try session.submitMessage(text: text, clientRequestID: clientRequestID)
            } catch {
                thrown = error
            }
            completion.fulfill()
        }
        XCTAssertTrue(Self.waitForSentLineCount(startCount + 1, transport: transport), file: file, line: line)
        let requestObject = try Self.object(from: try XCTUnwrap(transport.sentLines()[startCount], file: file, line: line),
                                            file: file,
                                            line: line)
        let effectiveResult: JSONValue
        if let respondWithResult {
            effectiveResult = respondWithResult
        } else {
            switch requestObject["method"]?.stringValue {
            case "turn/start":
                effectiveResult = .object(["turn": .object(["id": .string("turn-1")])])
            case "turn/steer":
                effectiveResult = .object(["turnId": .string("turn-1")])
            default:
                XCTFail("unexpected submit method \(requestObject["method"]?.stringValue ?? "nil")",
                        file: file,
                        line: line)
                effectiveResult = .object([:])
            }
        }
        transport.emitLine(try Self.responseText(id: try XCTUnwrap(requestObject["id"], file: file, line: line),
                                                 result: effectiveResult))
        wait(for: [completion], timeout: 5)
        if let thrown {
            throw thrown
        }
        return requestObject
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

private final class ThreadSafeErrorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var error: Error?

    func set(_ error: Error) {
        lock.lock()
        self.error = error
        lock.unlock()
    }

    func get() -> Error? {
        lock.lock()
        defer { lock.unlock() }
        return error
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

private final class ChannelBox: @unchecked Sendable {
    private let lock = NSLock()
    private var channel: Channel?

    func set(_ channel: Channel) {
        lock.lock()
        self.channel = channel
        lock.unlock()
    }

    func get() -> Channel? {
        lock.lock()
        defer { lock.unlock() }
        return channel
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
    private var confirmedLines: [String] = []
    private var closed = false
    private var closeCount = 0
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

    func sendLineAwaitingWrite(_ line: String) throws {
        lock.lock()
        confirmedLines.append(line)
        lock.unlock()
    }

    func close() {
        lock.lock()
        closed = true
        closeCount += 1
        lock.unlock()
        onClose(nil)
    }

    var closeCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return closeCount
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

    func confirmedSentLines() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return confirmedLines
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
    private var sendLineHook: ((String) throws -> Void)?
    private let onStdoutLine: @Sendable (String) -> Void
    private let onStderrLine: @Sendable (String) -> Void
    private let onExit: @Sendable (Int32) -> Void
    private var terminationCount = 0

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
        let hook = sendLineHook
        lock.unlock()
        try hook?(line)
        lock.lock()
        lines.append(line)
        lock.unlock()
    }

    func setSendLineHook(_ hook: @escaping (String) throws -> Void) {
        lock.lock()
        sendLineHook = hook
        lock.unlock()
    }

    func terminate() {
        lock.lock()
        terminationCount += 1
        lock.unlock()
    }

    var didTerminate: Bool {
        terminateCallCount > 0
    }

    var terminateCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return terminationCount
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

final class FakeCodexAppServerExternalProcess: CodexAppServerManagedProcess {
    let processID: Int32?
    private let lock = NSLock()
    private var terminationCount = 0

    init(processID: Int32?) {
        self.processID = processID
    }

    func sendLine(_ line: String) throws {
        throw CodexAppServerProcessError.closed
    }

    func terminate() {
        lock.lock()
        terminationCount += 1
        lock.unlock()
    }

    var terminateCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return terminationCount
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
