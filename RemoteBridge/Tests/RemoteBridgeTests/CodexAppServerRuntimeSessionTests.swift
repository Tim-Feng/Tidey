import NIOCore
import NIOEmbedded
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

    // P0: `factory.start` (an OWNED stdio process, not `.attach`'s socket)
    // must thread `onWorkingControl` through exactly the same as `.attach`
    // does. Raw stdout notifications — not a custom injected Syncer-style
    // capture — prove the full Connection -> Headless -> onWorkingControl
    // wiring actually exists on the `.start` path too.
    func testFactoryStartRawStdoutNotificationsReachOnWorkingControl() throws {
        let runner = FakeCodexAppServerProcessRunner()
        let factory = CodexAppServerRuntimeSessionFactory(processRunner: runner)
        var controls = [CodexAppServerWorkingControlEvent]()
        let controlsLock = NSLock()
        var seq = 10
        _ = try factory.start(configuration: CodexAppServerLaunchConfiguration(
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
                                onAgentEvent: { _ in },
                                onInteractivePrompt: { _ in },
                                onInteractivePromptResolved: { _ in },
                                onWorkingControl: { control in
                                    controlsLock.lock()
                                    controls.append(control)
                                    controlsLock.unlock()
                                })
        try Self.acknowledgeInitialize(from: runner.process)
        let process = try XCTUnwrap(runner.process)

        // Root turn/started — raw stdout, exactly as an owned app-server
        // process would write it.
        process.emitStdout(#"{"method":"turn/started","params":{"threadId":"thread-1","turn":{"id":"turn-1"}}}"#)
        // Allowlisted internal activity.
        process.emitStdout(#"""
        {"method":"item/started","params":{"threadId":"thread-1","turnId":"turn-1","startedAtMs":1,"item":{"type":"collabAgentToolCall","id":"item-1","tool":"wait","status":"inProgress","senderThreadId":"thread-1","receiverThreadIds":["thread-2"],"agentsStates":{}}}}
        """#)
        // Terminal.
        process.emitStdout(#"{"method":"turn/completed","params":{"threadId":"thread-1","turn":{"id":"turn-1","status":"completed"}}}"#)

        controlsLock.lock()
        let captured = controls
        controlsLock.unlock()
        guard captured.count == 3 else {
            return XCTFail("expected exactly [turnStarted, internalActivityStarted, turnTerminal], got \(captured)")
        }
        guard case .turnStarted(let threadID, let turnID, _) = captured[0] else {
            return XCTFail("expected turnStarted first, got \(captured[0])")
        }
        XCTAssertEqual(threadID, "thread-1")
        XCTAssertEqual(turnID, "turn-1")
        guard case .internalActivityStarted(_, _, let itemID, let kind, _) = captured[1] else {
            return XCTFail("expected internalActivityStarted second, got \(captured[1])")
        }
        XCTAssertEqual(itemID, "item-1")
        XCTAssertEqual(kind, .collabAgentToolCall)
        guard case .turnTerminal(_, _, let rawStatus, _) = captured[2] else {
            return XCTFail("expected turnTerminal third, got \(captured[2])")
        }
        XCTAssertEqual(rawStatus, "completed")
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

        let turnStart = try awaitSubmitMessage(session, text: "hello from remote", transport: transport)
        XCTAssertEqual(turnStart["method"]?.stringValue, "turn/start")
        let turnParams = try XCTUnwrap(turnStart["params"]?.objectValue)
        XCTAssertEqual(turnParams["threadId"]?.stringValue, "thread-live")
        XCTAssertEqual(turnParams["input"]?.arrayValue?.first?.objectValue?["text"]?.stringValue, "hello from remote")
    }

    // Required test: a thread/resume response naming exactly one
    // inProgress turn must seed that turn as the known active turn —
    // otherwise a Bridge attach/re-attach while the thread is already
    // working (e.g. immediately after a deploy or a new app-server PID)
    // can never learn the turn id, and every remote submit routes to
    // .busyWithoutTurnID until the turn happens to complete on its own.
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

    func testActiveThreadStoreObservedThreadOnlyFillsEmptyBinding() {
        var changes = [String]()
        let store = CodexAppServerActiveThreadStore(onChange: { changes.append($0) })

        XCTAssertTrue(store.noteObservedThreadID("thread-root"))
        XCTAssertFalse(store.noteObservedThreadID("thread-subagent"))
        XCTAssertEqual(store.currentThreadID(), "thread-root")

        XCTAssertTrue(store.setThreadID("thread-rotated"))
        XCTAssertEqual(store.currentThreadID(), "thread-rotated")
        XCTAssertEqual(changes, ["thread-root", "thread-rotated"])
    }

    func testRootThreadStartedObservationExcludesChildThreads() {
        func notification(method: String, thread: [String: JSONValue], extraParams: [String: JSONValue] = [:]) -> CodexAppServerNotification {
            var params = extraParams
            params["thread"] = .object(thread)
            return CodexAppServerNotification(method: method, params: params)
        }

        // Plain root thread (null parent) is accepted.
        XCTAssertEqual(CodexAppServerHeadlessRuntime.rootThreadStartedThreadID(
            from: notification(method: "thread/started",
                               thread: ["id": .string("thread-root"), "parentThreadId": .null])),
            "thread-root")
        // Parent linkage marks a child thread.
        XCTAssertNil(CodexAppServerHeadlessRuntime.rootThreadStartedThreadID(
            from: notification(method: "thread/started",
                               thread: ["id": .string("thread-child"), "parentThreadId": .string("thread-root")])))
        // Agent nickname/role mark subagent threads.
        XCTAssertNil(CodexAppServerHeadlessRuntime.rootThreadStartedThreadID(
            from: notification(method: "thread/started",
                               thread: ["id": .string("thread-child"), "agentNickname": .string("explorer")])))
        XCTAssertNil(CodexAppServerHeadlessRuntime.rootThreadStartedThreadID(
            from: notification(method: "thread/started",
                               thread: ["id": .string("thread-child"), "role": .string("subagent")])))
        // Non-thread/started notifications never seed the binding.
        XCTAssertNil(CodexAppServerHeadlessRuntime.rootThreadStartedThreadID(
            from: CodexAppServerNotification(method: "turn/started",
                                             params: ["threadId": .string("thread-child")])))
    }

    func testChildThreadNotificationsBeforeAuthoritativeRootDoNotBind() throws {
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
                                         timestampProvider: { "2026-07-15T00:00:00.000Z" },
                                         onAgentEvent: { _ in },
                                         onInteractivePrompt: { _ in },
                                         onInteractivePromptResolved: { _ in },
                                         onActiveThreadID: { activeThreadIDs.append($0) })

        let transport = try XCTUnwrap(connector.transport)
        try Self.acknowledgeInitialize(from: transport)

        // Child/subagent activity arrives BEFORE any authoritative root
        // identity. None of it may seed the binding, or a Remote submit
        // would target the child thread.
        transport.emitLine(#"{"method":"thread/started","params":{"thread":{"id":"thread-subagent","parentThreadId":"thread-root"}}}"#)
        transport.emitLine(#"{"method":"turn/started","params":{"threadId":"thread-subagent","turnId":"turn-sub"}}"#)
        transport.emitLine(#"{"method":"item/started","params":{"threadId":"thread-subagent","turnId":"turn-sub","item":{"id":"item-sub","type":"commandExecution","command":"ls"}}}"#)
        XCTAssertTrue(activeThreadIDs.isEmpty)

        // Authoritative root identity arrives afterwards and wins.
        let listLoaded = try Self.object(from: try XCTUnwrap(transport.sentLines().dropFirst(2).first))
        XCTAssertEqual(listLoaded["method"]?.stringValue, "thread/loaded/list")
        let listLoadedID = try XCTUnwrap(listLoaded["id"])
        let listLoadedIDData = try JSONEncoder().encode(listLoadedID)
        let listLoadedIDText = String(decoding: listLoadedIDData, as: UTF8.self)
        transport.emitLine("""
        {"id":\(listLoadedIDText),"result":{"threads":[{"id":"thread-root","preview":"Mac TUI Codex","updatedAt":"2026-07-15T00:00:00.000Z"}]}}
        """)
        XCTAssertTrue(Self.waitForSentLineCount(4, transport: transport))
        XCTAssertEqual(activeThreadIDs, ["thread-root"])

        let turnStart = try awaitSubmitMessage(session, text: "hello root thread", transport: transport)
        XCTAssertEqual(turnStart["method"]?.stringValue, "turn/start")
        XCTAssertEqual(turnStart["params"]?.objectValue?["threadId"]?.stringValue, "thread-root")
    }

    func testWebSocketTransportConfirmedWriteFailsClosedOnItsOwnEventLoop() throws {
        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }
        let transport = CodexAppServerWebSocketTransport(channel: channel)

        // EmbeddedChannel's event loop reports inEventLoop == true from the
        // test thread: a confirmed write cannot be awaited there and must
        // fail closed rather than report a best-effort enqueue as success.
        XCTAssertThrowsError(try transport.sendLineAwaitingWrite("{\"id\":1,\"result\":{}}\n")) { error in
            guard case CodexAppServerTransportError.confirmationUnavailable = error else {
                return XCTFail("expected confirmationUnavailable, got \(error)")
            }
        }
        // The best-effort path is still allowed for non-confirmed traffic.
        XCTAssertNoThrow(try transport.sendLine("{\"method\":\"initialized\"}\n"))
    }

    func testWebSocketFrameHandlerDeliversCloseExactlyOnce() throws {
        final class CloseCounter: @unchecked Sendable {
            private let lock = NSLock()
            private var count = 0
            func increment() {
                lock.lock()
                count += 1
                lock.unlock()
            }
            var value: Int {
                lock.lock()
                defer { lock.unlock() }
                return count
            }
        }
        struct ChannelFailure: Error {}
        let counter = CloseCounter()
        let handler = CodexAppServerWebSocketFrameHandler(onText: { _ in },
                                                          onClose: { _ in counter.increment() })
        let channel = EmbeddedChannel(handler: handler)

        // Error, close frame handling, and inactive can all fire for the same
        // dying channel; the session teardown must be delivered exactly once.
        channel.pipeline.fireErrorCaught(ChannelFailure())
        channel.pipeline.fireChannelInactive()
        _ = try? channel.finish()

        XCTAssertEqual(counter.value, 1)
    }

    func testTransportCloseTearsDownSessionExpiresPendingAndAllowsReattach() throws {
        let runner = FakeCodexAppServerProcessRunner()
        let connector = FakeCodexAppServerTransportConnector()
        let factory = CodexAppServerRuntimeSessionFactory(processRunner: runner,
                                                          transportConnector: connector)
        var promptEnvelopes = [CodexAppServerInteractivePromptEnvelope]()
        var resolvedEvents = [AgentEvent]()
        let session = try factory.attach(socketPath: "/tmp/tidey-real-panel/app.sock",
                                         processID: 9001,
                                         context: CodexAppServerRuntimeContext(workspaceID: "workspace-1",
                                                                               panelID: "panel-1",
                                                                               sessionID: "session-1"),
                                         epoch: "pid:9001|sock:/tmp/tidey-real-panel/app.sock",
                                         nextSequence: { _ in 1 },
                                         timestampProvider: { "2026-07-15T00:00:00.000Z" },
                                         onAgentEvent: { _ in },
                                         onInteractivePrompt: { promptEnvelopes.append($0) },
                                         onInteractivePromptResolved: { resolvedEvents.append($0) },
                                         onActiveThreadID: { _ in })

        let transport = try XCTUnwrap(connector.transport)
        try Self.acknowledgeInitialize(from: transport)

        transport.emitLine("""
        {"id":"approval-1","method":"item/commandExecution/requestApproval","params":{"threadId":"thread-1","turnId":"turn-1","itemId":"item-1","startedAtMs":1786000000000,"command":"ls"}}
        """)
        XCTAssertEqual(promptEnvelopes.count, 1)
        XCTAssertFalse(session.isStopped())

        // The client channel dies while the app-server (same epoch) stays
        // alive: the session must tear down, the pending approval becomes a
        // visible expired terminal, and the syncer can re-attach.
        transport.emitClose(nil)

        XCTAssertTrue(session.isStopped())
        XCTAssertEqual(resolvedEvents.map { $0.metadata?["reason"] }, ["expired"])
        XCTAssertTrue(session.pendingApprovalPromptEvents().isEmpty)

        // Duplicate close callbacks stay exactly-once.
        transport.emitClose(nil)
        XCTAssertEqual(resolvedEvents.count, 1)
    }

    func testSubagentNotificationDoesNotRebindActiveThread() throws {
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
                                         timestampProvider: { "2026-07-15T00:00:00.000Z" },
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
        {"id":\(listLoadedIDText),"result":{"threads":[{"id":"thread-root","preview":"Mac TUI Codex","updatedAt":"2026-07-15T00:00:00.000Z"}]}}
        """)
        XCTAssertTrue(Self.waitForSentLineCount(4, transport: transport))
        XCTAssertEqual(activeThreadIDs, ["thread-root"])

        transport.emitLine(#"{"method":"item/started","params":{"threadId":"thread-subagent","turnId":"turn-sub","item":{"id":"item-sub","type":"commandExecution","command":"ls"}}}"#)
        transport.emitLine(#"{"method":"turn/started","params":{"threadId":"thread-subagent","turnId":"turn-sub"}}"#)

        XCTAssertEqual(activeThreadIDs, ["thread-root"])

        let turnStart = try awaitSubmitMessage(session, text: "hello root thread", transport: transport)
        XCTAssertEqual(turnStart["method"]?.stringValue, "turn/start")
        XCTAssertEqual(turnStart["params"]?.objectValue?["threadId"]?.stringValue, "thread-root")
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

    // R13 root-thread fallback: the registry already holds the authoritative
    // root thread; an EMPTY thread/loaded/list must fall back to resuming it
    // instead of parking on loaded_thread_missing forever.
    func testRegistryRootFallbackResumesWhenLoadedListIsEmpty() throws {
        let runner = FakeCodexAppServerProcessRunner()
        let connector = FakeCodexAppServerTransportConnector()
        let factory = CodexAppServerRuntimeSessionFactory(processRunner: runner,
                                                          transportConnector: connector)
        let prompts = PromptSink()
        let session = try factory.attach(socketPath: "/tmp/tidey-real-panel/app.sock",
                                         processID: 9001,
                                         context: CodexAppServerRuntimeContext(workspaceID: "workspace-1",
                                                                               panelID: "panel-1",
                                                                               sessionID: "session-1"),
                                         nextSequence: { _ in 1 },
                                         timestampProvider: { "2026-06-07T00:00:00.000Z" },
                                         onAgentEvent: { _ in },
                                         onInteractivePrompt: { prompts.append($0) },
                                         onInteractivePromptResolved: { _ in })
        prompts.session = session
        session.setRegistryRootThreadID("019f5c3e-dafc-7102-80c5-d905869a66ef")

        let transport = try XCTUnwrap(connector.transport)
        try Self.acknowledgeInitialize(from: transport)

        let listLoaded = try Self.object(from: try XCTUnwrap(transport.sentLines().dropFirst(2).first))
        XCTAssertEqual(listLoaded["method"]?.stringValue, "thread/loaded/list")
        transport.emitLine(try Self.responseText(id: try XCTUnwrap(listLoaded["id"]), result: .object([
            "threads": .array([]),
        ])))

        // Fallback: the registry root is resumed instead of loaded_thread_missing.
        XCTAssertTrue(Self.waitForSentLineCount(4, transport: transport))
        let resume = try Self.object(from: try XCTUnwrap(transport.sentLines().dropFirst(3).first))
        XCTAssertEqual(resume["method"]?.stringValue, "thread/resume")
        let resumeParams = try XCTUnwrap(resume["params"]?.objectValue)
        XCTAssertEqual(resumeParams["threadId"]?.stringValue, "019f5c3e-dafc-7102-80c5-d905869a66ef")
        XCTAssertEqual(resumeParams["excludeTurns"]?.boolValue, false)
        XCTAssertNil(resumeParams["approvalsReviewer"])
        transport.emitLine(try Self.responseText(id: try XCTUnwrap(resume["id"]), result: .object([
            "thread": .object(["id": .string("019f5c3e-dafc-7102-80c5-d905869a66ef")]),
        ])))

        // Subscribed: no further subscription traffic.
        session.ensureThreadSubscription()
        XCTAssertEqual(transport.sentLines().count, 4)

        // The native approval server request on the resumed root thread
        // reaches the prompt handler and the pending snapshot.
        transport.emitLine("""
        {"id":"approval-1","method":"item/commandExecution/requestApproval","params":{"threadId":"019f5c3e-dafc-7102-80c5-d905869a66ef","turnId":"turn-1","itemId":"cmd-1","startedAtMs":1786000000000,"command":"rm -rf build","reason":"Needs escalation."}}
        """)
        let envelope = try XCTUnwrap(prompts.envelopes().first, "approval request must reach the prompt handler")
        XCTAssertEqual(envelope.prompt.source, "codex_command_approval")
        let pending = try XCTUnwrap(session.pendingApprovalPromptEvents().first,
                                    "the pending snapshot exposes the card event for Remote fetch")
        // Identity: the event carries THIS session's context, the right
        // channel/source and a live lifecycle token.
        XCTAssertEqual(pending.workspaceID, "workspace-1")
        XCTAssertEqual(pending.sessionID, "session-1")
        XCTAssertEqual(pending.metadata?["panel_id"], "panel-1")
        let payload = pending.payload?.objectValue
        XCTAssertEqual(payload?["source"]?.stringValue, "codex_command_approval")
        XCTAssertEqual(payload?["submit_channel"]?.stringValue, "codex_app_server")
        // The lifecycle token is carried INSIDE the prompt payload (the card
        // itself holds the capability) and equals the delivery event ID.
        let token = payload?["lifecycle_token"]?.stringValue ?? ""
        XCTAssertFalse(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       "a live approval carries a non-blank lifecycle token")
        XCTAssertEqual(token, pending.eventID)
    }

    // Ambiguous loaded list (multiple candidates, none current): the registry
    // root must not be lost.
    func testRegistryRootFallbackResumesWhenLoadedListIsAmbiguous() throws {
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
        session.setRegistryRootThreadID("thread-root")

        let transport = try XCTUnwrap(connector.transport)
        try Self.acknowledgeInitialize(from: transport)
        let listLoaded = try Self.object(from: try XCTUnwrap(transport.sentLines().dropFirst(2).first))
        transport.emitLine(try Self.responseText(id: try XCTUnwrap(listLoaded["id"]), result: .object([
            "threads": .array([
                .object(["id": .string("thread-a")]),
                .object(["id": .string("thread-b")]),
            ]),
        ])))

        XCTAssertTrue(Self.waitForSentLineCount(4, transport: transport))
        let resume = try Self.object(from: try XCTUnwrap(transport.sentLines().dropFirst(3).first))
        XCTAssertEqual(resume["method"]?.stringValue, "thread/resume")
        XCTAssertEqual(resume["params"]?.objectValue?["threadId"]?.stringValue, "thread-root")
    }

    // Fail closed: no valid registry root (blank) + unresolvable loaded list
    // keeps the safe no-loaded-thread behavior — never a made-up resume.
    func testBlankRegistryRootKeepsSafeNoLoadedThreadBehavior() throws {
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
        session.setRegistryRootThreadID("   \n")

        let transport = try XCTUnwrap(connector.transport)
        try Self.acknowledgeInitialize(from: transport)
        let listLoaded = try Self.object(from: try XCTUnwrap(transport.sentLines().dropFirst(2).first))
        transport.emitLine(try Self.responseText(id: try XCTUnwrap(listLoaded["id"]), result: .object([
            "threads": .array([]),
        ])))
        XCTAssertEqual(transport.sentLines().count, 3, "no resume without a valid root")

        // The retry loop keeps polling loaded/list, not resuming blindly.
        XCTAssertTrue(Self.waitForSentLineCount(4, transport: transport, poll: {
            session.ensureThreadSubscription()
        }))
        let retry = try Self.object(from: try XCTUnwrap(transport.sentLines().dropFirst(3).first))
        XCTAssertEqual(retry["method"]?.stringValue, "thread/loaded/list")
    }

    // A subagent thread notification after the fallback subscribe must not
    // rebind the root: submits still target the registry root thread.
    func testSubagentNotificationDoesNotRebindFallbackRoot() throws {
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
        session.setRegistryRootThreadID("thread-root")

        let transport = try XCTUnwrap(connector.transport)
        try Self.acknowledgeInitialize(from: transport)
        let listLoaded = try Self.object(from: try XCTUnwrap(transport.sentLines().dropFirst(2).first))
        transport.emitLine(try Self.responseText(id: try XCTUnwrap(listLoaded["id"]), result: .object([
            "threads": .array([]),
        ])))
        XCTAssertTrue(Self.waitForSentLineCount(4, transport: transport))
        let resume = try Self.object(from: try XCTUnwrap(transport.sentLines().dropFirst(3).first))
        transport.emitLine(try Self.responseText(id: try XCTUnwrap(resume["id"]), result: .object([
            "thread": .object(["id": .string("thread-root")]),
        ])))
        session.ensureThreadSubscription()
        XCTAssertEqual(transport.sentLines().count, 4)

        transport.emitLine(#"{"method":"thread/started","params":{"thread":{"id":"thread-subagent","parentThreadId":"thread-root"}}}"#)
        session.ensureThreadSubscription()
        XCTAssertEqual(transport.sentLines().count, 4, "no rebind/resubscribe from a subagent notification")

        let turnStart = try awaitSubmitMessage(session, text: "hello", transport: transport)
        XCTAssertEqual(turnStart["params"]?.objectValue?["threadId"]?.stringValue, "thread-root",
                       "submits still target the ROOT thread")
    }

    // Fallback resume hitting "no rollout found" keeps the bounded backoff —
    // no tight resume storm.
    func testRegistryRootFallbackNoRolloutKeepsBoundedBackoff() throws {
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
        session.setRegistryRootThreadID("thread-root")

        let transport = try XCTUnwrap(connector.transport)
        try Self.acknowledgeInitialize(from: transport)
        let listLoaded = try Self.object(from: try XCTUnwrap(transport.sentLines().dropFirst(2).first))
        transport.emitLine(try Self.responseText(id: try XCTUnwrap(listLoaded["id"]), result: .object([
            "threads": .array([]),
        ])))
        XCTAssertTrue(Self.waitForSentLineCount(4, transport: transport))
        let resume = try Self.object(from: try XCTUnwrap(transport.sentLines().dropFirst(3).first))
        transport.emitLine(try Self.errorResponseText(id: try XCTUnwrap(resume["id"]),
                                                      code: -32600,
                                                      message: "no rollout found for thread id thread-root"))

        // Inside the backoff window: NOTHING is re-sent (no tight loop).
        session.ensureThreadSubscription()
        session.ensureThreadSubscription()
        XCTAssertEqual(transport.sentLines().count, 4)

        // After the bounded backoff, the cycle resumes once.
        Thread.sleep(forTimeInterval: 1.1)
        XCTAssertTrue(Self.waitForSentLineCount(5, transport: transport, poll: {
            session.ensureThreadSubscription()
        }))
        let retryList = try Self.object(from: try XCTUnwrap(transport.sentLines().dropFirst(4).first))
        XCTAssertEqual(retryList["method"]?.stringValue, "thread/loaded/list")
        transport.emitLine(try Self.responseText(id: try XCTUnwrap(retryList["id"]), result: .object([
            "threads": .array([]),
        ])))
        XCTAssertTrue(Self.waitForSentLineCount(6, transport: transport))
        let retryResume = try Self.object(from: try XCTUnwrap(transport.sentLines().dropFirst(5).first))
        XCTAssertEqual(retryResume["method"]?.stringValue, "thread/resume")
        XCTAssertEqual(retryResume["params"]?.objectValue?["threadId"]?.stringValue, "thread-root")
    }

    // Follow-up 2: the registry root can arrive AFTER the attach-time
    // loaded/list already came back empty. The late delivery itself must
    // re-arm the subscription — no waiting for the next external sync.
    func testLateRegistryRootDeliveryTriggersResumeWithoutExternalSync() throws {
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
        transport.emitLine(try Self.responseText(id: try XCTUnwrap(listLoaded["id"]), result: .object([
            "threads": .array([]),
        ])))
        XCTAssertEqual(transport.sentLines().count, 3, "precondition: parked with NO resume and no root yet")

        // Late root delivery — with NO external ensure call afterwards.
        session.setRegistryRootThreadID("thread-root")

        XCTAssertTrue(Self.waitForSentLineCount(4, transport: transport),
                      "the late delivery re-arms the subscription by itself")
        let resume = try Self.object(from: try XCTUnwrap(transport.sentLines().last))
        XCTAssertEqual(resume["method"]?.stringValue, "thread/resume")
        XCTAssertEqual(resume["params"]?.objectValue?["threadId"]?.stringValue, "thread-root")

        // Resume success establishes the ACTIVE binding too: Remote messages
        // must reach the root thread, not "thread not ready".
        transport.emitLine(try Self.responseText(id: try XCTUnwrap(resume["id"]), result: .object([
            "thread": .object(["id": .string("thread-root")]),
        ])))
        let turnStart = try awaitSubmitMessage(session, text: "hello root", transport: transport)
        XCTAssertEqual(turnStart["params"]?.objectValue?["threadId"]?.stringValue, "thread-root",
                       "submits target the fallback ROOT thread")
    }

    // Final review 3: a PAGINATED loaded list (nextCursor set) cannot vouch
    // for a unique root — the registry fallback applies.
    func testPaginatedLoadedListUsesRegistryRootFallback() throws {
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
        session.setRegistryRootThreadID("thread-root")

        let transport = try XCTUnwrap(connector.transport)
        try Self.acknowledgeInitialize(from: transport)
        let listLoaded = try Self.object(from: try XCTUnwrap(transport.sentLines().dropFirst(2).first))
        transport.emitLine(try Self.responseText(id: try XCTUnwrap(listLoaded["id"]), result: .object([
            "threads": .array([
                .object(["id": .string("thread-page-1")]),
            ]),
            "nextCursor": .string("cursor-2"),
        ])))

        XCTAssertTrue(Self.waitForSentLineCount(4, transport: transport))
        let resume = try Self.object(from: try XCTUnwrap(transport.sentLines().dropFirst(3).first))
        XCTAssertEqual(resume["method"]?.stringValue, "thread/resume")
        XCTAssertEqual(resume["params"]?.objectValue?["threadId"]?.stringValue, "thread-root",
                       "a paginated page never vouches for a unique root — the registry root wins")
    }

    // P1: thread/resume is ADDITIVE — a refresh that resolves a DIFFERENT
    // unique root B while this connection is subscribed to A must never send
    // resume(B) on the same connection (A+B double subscription). Fail
    // closed: stop the runtime so the syncer's isStopped() replacement path
    // attaches a fresh generation that subscribes only B.
    func testRefreshNeverAdditivelyResumesDifferentRootOnSubscribedConnection() throws {
        let runner = FakeCodexAppServerProcessRunner()
        let connector = FakeCodexAppServerTransportConnector()
        let factory = CodexAppServerRuntimeSessionFactory(processRunner: runner,
                                                          transportConnector: connector)
        var observedThreadIDs = [String]()
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
                                         onActiveThreadID: { observedThreadIDs.append($0) })

        let transport = try XCTUnwrap(connector.transport)
        try Self.acknowledgeInitialize(from: transport)
        let listLoaded = try Self.object(from: try XCTUnwrap(transport.sentLines().dropFirst(2).first))
        transport.emitLine(try Self.responseText(id: try XCTUnwrap(listLoaded["id"]), result: .object([
            "threads": .array([.object(["id": .string("thread-A")])]),
        ])))
        XCTAssertTrue(Self.waitForSentLineCount(4, transport: transport))
        let resumeA = try Self.object(from: try XCTUnwrap(transport.sentLines().dropFirst(3).first))
        XCTAssertEqual(resumeA["params"]?.objectValue?["threadId"]?.stringValue, "thread-A")
        transport.emitLine(try Self.responseText(id: try XCTUnwrap(resumeA["id"]), result: .object([
            "thread": .object(["id": .string("thread-A")]),
        ])))

        // Subscribed(A). The refresh now resolves a DIFFERENT unique root B.
        session.refreshActiveThread()
        XCTAssertTrue(Self.waitForSentLineCount(5, transport: transport))
        let refreshList = try Self.object(from: try XCTUnwrap(transport.sentLines().dropFirst(4).first))
        XCTAssertEqual(refreshList["method"]?.stringValue, "thread/loaded/list")
        transport.emitLine(try Self.responseText(id: try XCTUnwrap(refreshList["id"]), result: .object([
            "threads": .array([.object(["id": .string("thread-B")])]),
        ])))

        // Deterministic settle: the callback queue processed the result.
        XCTAssertTrue(Self.waitFor { session.isStopped() },
                      "fail closed: the old runtime is STOPPED so the syncer replaces the generation")
        let resumeBLines = transport.sentLines().compactMap { line -> String? in
            guard let object = try? Self.object(from: line),
                  object["method"]?.stringValue == "thread/resume" else {
                return nil
            }
            return object["params"]?.objectValue?["threadId"]?.stringValue
        }
        XCTAssertEqual(resumeBLines, ["thread-A"],
                       "NO additive resume(B) on the connection that already subscribed A")
        XCTAssertGreaterThan(transport.closeCallCount, 0, "the old connection is closed")
        XCTAssertEqual(observedThreadIDs.last, "thread-B",
                       "B is still recorded via the existing active-thread callback for the registry")
    }

    // P2: the LATE setter must not be lost when it interleaves with an
    // unresolved loaded-list callback that has not committed its state
    // transition yet — any interleaving ends with EXACTLY ONE resume(root).
    func testLateSetterDuringUnresolvedListCallbackStillResumesExactlyOnce() throws {
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
        // The setter lands EXACTLY while the callback is processing the
        // unresolved list, before the state transition commits.
        session.loadedThreadUnresolvedHook = { [weak session] in
            session?.loadedThreadUnresolvedHook = nil
            session?.setRegistryRootThreadID("thread-root")
        }

        let transport = try XCTUnwrap(connector.transport)
        try Self.acknowledgeInitialize(from: transport)
        let listLoaded = try Self.object(from: try XCTUnwrap(transport.sentLines().dropFirst(2).first))
        transport.emitLine(try Self.responseText(id: try XCTUnwrap(listLoaded["id"]), result: .object([
            "threads": .array([]),
        ])))

        // NO external ensure: the interleaving itself must produce the resume.
        XCTAssertTrue(Self.waitForSentLineCount(4, transport: transport),
                      "the late setter is not lost")
        let resumes = transport.sentLines().compactMap { line -> String? in
            guard let object = try? Self.object(from: line),
                  object["method"]?.stringValue == "thread/resume" else {
                return nil
            }
            return object["params"]?.objectValue?["threadId"]?.stringValue
        }
        XCTAssertEqual(resumes, ["thread-root"], "exactly ONE resume, no duplicates")
    }

    // Codex production review follow-up: a bare-string loaded-list child-
    // first race binds and CONFIRMS a subscription to the wrong (child)
    // thread before the authoritative registry root arrives. The late
    // registry root must CORRECT the confirmed binding, not leave it.
    // Follow-up 3: loaded-list authoritative precedence — a uniquely
    // resolved loaded root B WINS over an existing fallback A.
    func testLoadedListUniqueRootTakesPrecedenceOverFallback() throws {
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
        session.setRegistryRootThreadID("thread-A")

        let transport = try XCTUnwrap(connector.transport)
        try Self.acknowledgeInitialize(from: transport)
        let listLoaded = try Self.object(from: try XCTUnwrap(transport.sentLines().dropFirst(2).first))
        transport.emitLine(try Self.responseText(id: try XCTUnwrap(listLoaded["id"]), result: .object([
            "threads": .array([
                .object(["id": .string("thread-B")]),
            ]),
        ])))

        XCTAssertTrue(Self.waitForSentLineCount(4, transport: transport))
        let resume = try Self.object(from: try XCTUnwrap(transport.sentLines().dropFirst(3).first))
        XCTAssertEqual(resume["method"]?.stringValue, "thread/resume")
        XCTAssertEqual(resume["params"]?.objectValue?["threadId"]?.stringValue, "thread-B",
                       "the app-server's uniquely resolved root is authoritative over the fallback")
    }

    // Follow-up 1 semantics: a later nil/blank update never CLEARS a valid
    // fallback — fail closed keeps the last known-good root.
    func testBlankRootUpdateKeepsExistingValidFallback() throws {
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
        session.setRegistryRootThreadID("thread-root")
        session.setRegistryRootThreadID("   ")
        session.setRegistryRootThreadID(nil)

        let transport = try XCTUnwrap(connector.transport)
        try Self.acknowledgeInitialize(from: transport)
        let listLoaded = try Self.object(from: try XCTUnwrap(transport.sentLines().dropFirst(2).first))
        transport.emitLine(try Self.responseText(id: try XCTUnwrap(listLoaded["id"]), result: .object([
            "threads": .array([]),
        ])))

        XCTAssertTrue(Self.waitForSentLineCount(4, transport: transport))
        let resume = try Self.object(from: try XCTUnwrap(transport.sentLines().dropFirst(3).first))
        XCTAssertEqual(resume["params"]?.objectValue?["threadId"]?.stringValue, "thread-root",
                       "blank updates never clear the last valid fallback")
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
        // Thread-not-ready happens strictly before any turn/start or
        // turn/steer request frame is built — zero effect by construction,
        // so this is the typed unavailableBeforeSend case (fail-closed
        // conflict at the handler, never a terminal fallback, and a
        // same-id retry can genuinely re-attempt once the thread resolves).
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

        XCTAssertEqual(transport.sentLines().count, 3)
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

        // A weak idle edge must not discard a turn recovered on behalf of
        // the still-pending remote submit.
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

        // The turn-state store must not be corrupted by the rejection: a
        // further submit still steers into turn A (the last-known active
        // turn), never starting a spurious new turn, until a real
        // turn/started or turn/completed notification says otherwise.
        let secondSteer = try awaitSubmitMessage(session,
                                                 text: "steer into A again",
                                                 transport: transport,
                                                 respondWithResult: .object(["turnId": .string("turn-A")]))
        XCTAssertEqual(secondSteer["method"]?.stringValue, "turn/steer")
        XCTAssertEqual(secondSteer["params"]?.objectValue?["expectedTurnId"]?.stringValue, "turn-A")
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

    func testMatchingTurnCompletedReleasesThreadStatusActiveWithoutIdleNotification() throws {
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

        let transport = try XCTUnwrap(connector.transport)
        try Self.acknowledgeInitialize(from: transport)
        try Self.loadThread("thread-live", on: transport)

        // Protocol-defense ordering: if active + started + completed are
        // delivered without a trailing idle edge, the matching terminal
        // must still release all state for that turn. Automation's actual
        // incident took the resume-seed path covered separately below.
        transport.emitLine(#"{"method":"thread/status/changed","params":{"threadId":"thread-live","status":{"type":"active","activeFlags":["turn"]}}}"#)
        transport.emitLine(#"{"method":"turn/started","params":{"threadId":"thread-live","turn":{"id":"turn-current"}}}"#)
        transport.emitLine(#"{"method":"turn/completed","params":{"threadId":"thread-live","turn":{"id":"turn-current","status":"completed"}}}"#)

        let turnStart = try awaitSubmitMessage(session,
                                               text: "remote after completed turn",
                                               transport: transport)
        XCTAssertEqual(turnStart["method"]?.stringValue, "turn/start")
    }

    func testTurnStateStoreExpiresStuckActiveTurn() throws {
        var now = Date(timeIntervalSince1970: 100)
        let store = CodexAppServerTurnStateStore(timeout: 1) {
            now
        }
        store.markThreadActive(threadID: "thread-live")

        XCTAssertEqual(store.routeSubmit(threadID: "thread-live"), .busyWithoutTurnID)

        now = now.addingTimeInterval(2)
        XCTAssertEqual(store.routeSubmit(threadID: "thread-live"), .start)
    }

    // Followup fix: pruneExpiredLocked must bump the revision fence when it
    // actually mutates a thread's state (a timeout expiry is a real state
    // change, exactly like any other mutation) — otherwise a stale
    // thread/resume response captured BEFORE the expiry could still pass
    // the (unchanged) barrier and resurrect turn state the store already
    // gave up on as stale.
    func testTurnStateStorePruneExpiryInvalidatesAStaleResumeBarrier() throws {
        var now = Date(timeIntervalSince1970: 100)
        let store = CodexAppServerTurnStateStore(timeout: 1) {
            now
        }

        // A pending claim (routeSubmit's .start branch) starts the clock on
        // this thread's state.
        XCTAssertEqual(store.routeSubmit(threadID: "thread-live"), .start)
        // The resume request's barrier is captured AFTER the claim, while
        // the state is still fresh.
        let barrier = store.revisionBarrier(threadID: "thread-live")

        // Time passes well past the timeout with no other activity — the
        // claim goes stale. Any store call (here, a peek via isBusy on an
        // UNRELATED thread id still triggers pruneExpiredLocked, which
        // scans every thread's state) causes the expiry to be pruned.
        now = now.addingTimeInterval(2)
        _ = store.isBusy(threadID: "some-other-thread")
        XCTAssertFalse(store.isBusy(threadID: "thread-live"), "the stale pending claim was pruned")

        // The (now-stale) resume response arrives, naming a turn that was
        // "inProgress" back when the barrier was captured. Because prune
        // bumped the revision, this must be rejected — never resurrect
        // turn state the store already gave up on as expired.
        let applied = store.seedActiveTurnFromResumeIfUnchanged(threadID: "thread-live", turnID: "turn-stale", barrier: barrier)
        XCTAssertFalse(applied, "a resume response racing a timeout-based prune must be invalidated, not applied")
        XCTAssertFalse(store.isBusy(threadID: "thread-live"), "the thread must remain idle — no resurrected turn")
    }

    func testTurnStateStoreStaleTurnCompletedDoesNotClearThreadStatusActive() throws {
        let store = CodexAppServerTurnStateStore()
        store.markThreadActive(threadID: "thread-live")
        store.markCompleted(threadID: "thread-live", turnID: "stale-remote-turn")

        XCTAssertEqual(store.routeSubmit(threadID: "thread-live"), .busyWithoutTurnID)

        store.markThreadIdle(threadID: "thread-live")
        XCTAssertEqual(store.routeSubmit(threadID: "thread-live"), .start)
    }

    // Defensive lifecycle case: if active + started + completed arrive but
    // no following idle notification does, the matching turn terminal is
    // authoritative for that turn and must clear compatible thread-level
    // active evidence too. The Automation production incident itself had
    // no turn/started and is covered by the resume-seed regression below.
    func testTurnStateStoreMatchingTurnCompletedClearsThreadStatusActive() throws {
        let store = CodexAppServerTurnStateStore()
        store.markThreadActive(threadID: "thread-live")
        store.markStarted(threadID: "thread-live", turnID: "turn-current")

        XCTAssertEqual(store.routeSubmit(threadID: "thread-live"), .steer(turnID: "turn-current"))

        store.markCompleted(threadID: "thread-live", turnID: "turn-current")

        XCTAssertEqual(store.routeSubmit(threadID: "thread-live"), .start)
    }

    // Exact production regression (Automation, 2026-07-21): the remote
    // submit claimed the thread, but this Bridge attachment missed the
    // corresponding turn/started notification. A later thread/resume
    // snapshot recovered the exact turn id, and turn/completed eventually
    // arrived for that same turn. The recovered identity must take
    // ownership of (and clear) the pending remote-submit claim; otherwise
    // completion removes the turn but leaves the thread stuck forever as
    // busyWithoutTurnID.
    func testTurnStateStoreResumeSeedOwnsPendingRemoteSubmitThroughCompletion() throws {
        let store = CodexAppServerTurnStateStore()

        XCTAssertEqual(store.routeSubmit(threadID: "thread-live"), .start)
        let resumeBarrier = store.revisionBarrier(threadID: "thread-live")
        store.markThreadActive(threadID: "thread-live")

        XCTAssertTrue(store.seedActiveTurnFromResumeIfUnchanged(threadID: "thread-live",
                                                                 turnID: "turn-current",
                                                                 barrier: resumeBarrier))
        XCTAssertEqual(store.routeSubmit(threadID: "thread-live"), .steer(turnID: "turn-current"))

        // Because the snapshot recovered the turn claimed by the remote
        // submit, a weak/early idle status must not discard it as though it
        // were an unrelated app-server-origin TUI turn.
        store.markThreadIdle(threadID: "thread-live")
        XCTAssertEqual(store.routeSubmit(threadID: "thread-live"), .steer(turnID: "turn-current"))
        store.markThreadActive(threadID: "thread-live")

        store.markCompleted(threadID: "thread-live", turnID: "turn-current")

        XCTAssertEqual(store.routeSubmit(threadID: "thread-live"), .start)
    }

    func testTurnStateStoreThreadStatusIdleDoesNotClearRemotePendingOrTurnActive() throws {
        let store = CodexAppServerTurnStateStore()
        XCTAssertEqual(store.routeSubmit(threadID: "thread-live"), .start)
        store.markThreadIdle(threadID: "thread-live")

        XCTAssertEqual(store.routeSubmit(threadID: "thread-live"), .busyWithoutTurnID)

        store.markStarted(threadID: "thread-live", turnID: "remote-turn")
        store.markThreadIdle(threadID: "thread-live")

        // A known turn id takes priority over any other busy flag: routeSubmit
        // steers into it rather than reporting a bare busyWithoutTurnID.
        XCTAssertEqual(store.routeSubmit(threadID: "thread-live"), .steer(turnID: "remote-turn"))

        store.markCompleted(threadID: "thread-live", turnID: "remote-turn")
        XCTAssertEqual(store.routeSubmit(threadID: "thread-live"), .start)
    }

    func testTurnStateStoreThreadStatusIdleClearsAppServerOriginTurnActive() throws {
        let store = CodexAppServerTurnStateStore()
        store.markStarted(threadID: "thread-live", turnID: "tui-turn")

        XCTAssertEqual(store.routeSubmit(threadID: "thread-live"), .steer(turnID: "tui-turn"))

        store.markThreadIdle(threadID: "thread-live")

        XCTAssertEqual(store.routeSubmit(threadID: "thread-live"), .start)
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

        let outcome = try prompts.session?.submitApproval(promptID: envelope.prompt.promptID,
                                                          targetIndex: 0,
                                                          clientRequestID: nil,
                                                          lifecycleToken: nil)
        guard case .pendingConfirmation = outcome else {
            return XCTFail("expected pendingConfirmation, got \(String(describing: outcome))")
        }

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

    func testAttachInitializeSendFailureClosesTransportExactlyOnce() throws {
        // The attach handler built transport/connection/session, then the
        // initialize send throws: the factory must roll the transport back
        // (close exactly once) instead of leaking a half-built session.
        let runner = FakeCodexAppServerProcessRunner()
        let connector = FakeCodexAppServerTransportConnector()
        connector.configureTransport = { $0.sendLineError = CodexAppServerTransportError.closed }
        let factory = CodexAppServerRuntimeSessionFactory(processRunner: runner,
                                                          transportConnector: connector)
        XCTAssertThrowsError(try factory.attach(socketPath: "/tmp/tidey-real-panel/app.sock",
                                                processID: 9001,
                                                context: CodexAppServerRuntimeContext(workspaceID: "workspace-1",
                                                                                     panelID: "panel-1",
                                                                                     sessionID: "session-1"),
                                                nextSequence: { _ in 1 },
                                                timestampProvider: { "2026-06-07T00:00:00.000Z" },
                                                onAgentEvent: { _ in },
                                                onInteractivePrompt: { _ in },
                                                onInteractivePromptResolved: { _ in }))
        let transport = try XCTUnwrap(connector.transport)
        XCTAssertEqual(transport.closeCallCount, 1,
                       "a failed attach initialize must close the transport exactly once")
    }

    func testStartInitializeSendFailureTerminatesOwnedProcessExactlyOnce() throws {
        let runner = FakeCodexAppServerProcessRunner()
        runner.configureProcess = { $0.sendLineError = CodexAppServerProcessError.closed }
        let connector = FakeCodexAppServerTransportConnector()
        let factory = CodexAppServerRuntimeSessionFactory(processRunner: runner,
                                                          transportConnector: connector)
        XCTAssertThrowsError(try factory.start(configuration: CodexAppServerLaunchConfiguration(
                                                    executablePath: "/tmp/disposable-codex",
                                                    arguments: ["app-server"],
                                                    workingDirectory: "/tmp/tidey-codex-disposable",
                                                    environment: [:]),
                                               context: CodexAppServerRuntimeContext(workspaceID: "workspace-1",
                                                                                    panelID: "panel-1",
                                                                                    sessionID: "session-1"),
                                               nextSequence: { _ in 1 },
                                               timestampProvider: { "2026-06-07T00:00:00.000Z" },
                                               onAgentEvent: { _ in },
                                               onInteractivePrompt: { _ in },
                                               onInteractivePromptResolved: { _ in }))
        let process = try XCTUnwrap(runner.process)
        XCTAssertEqual(process.terminateCallCount, 1,
                       "a failed start initialize must terminate the owned process exactly once")
    }

    private static let violationApprovalLine = """
    {"id":"approval-1","method":"item/commandExecution/requestApproval","params":{"threadId":"thread-1","turnId":"turn-1","itemId":"item-1","startedAtMs":1786000000000,"command":"ls","cwd":"/tmp"}}
    """
    private static let violationChangedLine = """
    {"id":"approval-1","method":"item/commandExecution/requestApproval","params":{"threadId":"thread-1","turnId":"turn-1","itemId":"item-1","startedAtMs":1786000000000,"command":"rm -rf /","cwd":"/tmp"}}
    """

    func testStdioProtocolViolationTerminatesOwnedProcessOnce() throws {
        // A protocol violation on a factory-STARTED stdio runtime must
        // actually stop the runtime generation: the owned process is
        // terminated (stdio has no separately closable channel) and the
        // session is unusable afterwards.
        let runner = FakeCodexAppServerProcessRunner()
        let prompts = PromptSink()
        let session = try Self.makeSession(runner: runner, prompts: prompts)
        try Self.acknowledgeInitialize(from: runner.process)
        let process = try XCTUnwrap(runner.process)

        process.emitStdout(Self.violationApprovalLine)
        let envelope = try XCTUnwrap(prompts.envelopes().first)
        guard case .pendingConfirmation = try session.submitApproval(promptID: envelope.prompt.promptID,
                                                                      targetIndex: 0,
                                                                      clientRequestID: "client-1",
                                                                      lifecycleToken: envelope.event.eventID) else {
            return XCTFail("expected pendingConfirmation")
        }
        let framesBeforeViolation = process.stdinLines().count

        // Changed payload under the same id: protocol violation.
        process.emitStdout(Self.violationChangedLine)
        process.emitStdout(Self.violationChangedLine)

        XCTAssertEqual(process.terminateCallCount, 1,
                       "the owned stdio process must be terminated exactly once")
        XCTAssertTrue(session.isStopped())
        XCTAssertEqual(process.stdinLines().count, framesBeforeViolation,
                       "no further bytes may reach the poisoned transport")
        XCTAssertThrowsError(try session.submitMessage(text: "after violation", clientRequestID: nil)) { _ in }
    }

    func testUnixSocketAttachProtocolViolationClosesTransportWithoutKillingExternalProcess() throws {
        // For an ATTACHED external app-server the violation must abort the
        // client transport exactly once; the external process is not ours to
        // kill (CodexAppServerExternalProcess.terminate() is a no-op by
        // construction).
        let runner = FakeCodexAppServerProcessRunner()
        let connector = FakeCodexAppServerTransportConnector()
        let factory = CodexAppServerRuntimeSessionFactory(processRunner: runner,
                                                          transportConnector: connector)
        let prompts = PromptSink()
        let session = try factory.attach(socketPath: "/tmp/tidey-real-panel/app.sock",
                                         processID: 9001,
                                         context: CodexAppServerRuntimeContext(workspaceID: "workspace-1",
                                                                              panelID: "panel-1",
                                                                              sessionID: "session-1"),
                                         nextSequence: { _ in 1 },
                                         timestampProvider: { "2026-06-07T00:00:00.000Z" },
                                         onAgentEvent: { _ in },
                                         onInteractivePrompt: { prompts.append($0) },
                                         onInteractivePromptResolved: { _ in })
        let transport = try XCTUnwrap(connector.transport)
        try Self.acknowledgeInitialize(from: transport)

        transport.emitLine(Self.violationApprovalLine)
        let envelope = try XCTUnwrap(prompts.envelopes().first)
        _ = try session.submitApproval(promptID: envelope.prompt.promptID,
                                       targetIndex: 0,
                                       clientRequestID: "client-1",
                                       lifecycleToken: envelope.event.eventID)

        transport.emitLine(Self.violationChangedLine)
        transport.emitLine(Self.violationChangedLine)

        XCTAssertEqual(transport.closeCallCount, 1,
                       "the attached transport must be aborted exactly once")
        XCTAssertTrue(session.isStopped())
        XCTAssertTrue(runner.startedConfigurations.isEmpty, "attach must not have started (or killed) any owned process")
    }

    // MARK: - Finish/resume-control linearization barrier (Section 5)

    // Attaches a session wired for the finish-barrier tests below: drives
    // the auto-subscription flow through a single loaded thread so a
    // `thread/resume` request is already in flight, and returns the
    // request id plus a thread-safe collector for every
    // `onWorkingControl` observation this session produces.
    private final class ControlCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [CodexAppServerWorkingControlEvent] = []
        var onAppend: ((CodexAppServerWorkingControlEvent) -> Void)?

        func append(_ event: CodexAppServerWorkingControlEvent) {
            lock.lock()
            events.append(event)
            lock.unlock()
            onAppend?(event)
        }

        func snapshot() -> [CodexAppServerWorkingControlEvent] {
            lock.lock()
            defer { lock.unlock() }
            return events
        }
    }

    private static func attachSessionWithPendingResume(controls: ControlCollector) throws -> (session: CodexAppServerRuntimeSession, transport: FakeCodexAppServerConnectionTransport, resumeID: JSONValue) {
        let runner = FakeCodexAppServerProcessRunner()
        let connector = FakeCodexAppServerTransportConnector()
        let factory = CodexAppServerRuntimeSessionFactory(processRunner: runner, transportConnector: connector)
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
                                         onActiveThreadID: { _ in },
                                         onWorkingControl: { controls.append($0) })
        let transport = try XCTUnwrap(connector.transport)
        try Self.acknowledgeInitialize(from: transport)

        let listLoaded = try Self.object(from: try XCTUnwrap(transport.sentLines().dropFirst(2).first))
        let listLoadedID = try XCTUnwrap(listLoaded["id"])
        transport.emitLine(try Self.responseText(id: listLoadedID, result: .object([
            "threads": .array([
                .object(["id": .string("thread-a"), "preview": .string("p"), "updatedAt": .string("2026-06-07T00:00:00.000Z")]),
            ]),
        ])))

        XCTAssertTrue(Self.waitForSentLineCount(4, transport: transport))
        let resume = try Self.object(from: try XCTUnwrap(transport.sentLines().dropFirst(3).first))
        XCTAssertEqual(resume["method"]?.stringValue, "thread/resume")
        let resumeID = try XCTUnwrap(resume["id"])
        return (session, transport, resumeID)
    }

    // A minimal attached session (no forced subscription drive) plus its
    // fake transport, for tests that only care about the finish/reason
    // wiring rather than an in-flight resume.
    private static func attachPlainSession(controls: ControlCollector) throws -> (session: CodexAppServerRuntimeSession, transport: FakeCodexAppServerConnectionTransport) {
        let runner = FakeCodexAppServerProcessRunner()
        let connector = FakeCodexAppServerTransportConnector()
        let factory = CodexAppServerRuntimeSessionFactory(processRunner: runner, transportConnector: connector)
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
                                         onActiveThreadID: { _ in },
                                         onWorkingControl: { controls.append($0) })
        let transport = try XCTUnwrap(connector.transport)
        try Self.acknowledgeInitialize(from: transport)
        return (session, transport)
    }

    // P0: termination reason matrix — each row uses a FRESH session/
    // collector and the REAL trigger, asserting `ownerDisconnected` fires
    // with the correct reason exactly once, and that a duplicate/competing
    // trigger afterward adds nothing.
    func testTerminationReasonMatrix() throws {
        let fixedTimestamp = "2026-06-07T00:00:00.000Z"

        // Row 1: explicit public stop() -> sessionRetired.
        do {
            let controls = ControlCollector()
            let (session, _) = try Self.attachPlainSession(controls: controls)
            session.stop()
            let captured = controls.snapshot()
            guard captured.count == 1, case .ownerDisconnected(let reason, let time) = captured[0] else {
                return XCTFail("row 1: expected exactly one ownerDisconnected, got \(captured)")
            }
            XCTAssertEqual(reason, .sessionRetired)
            XCTAssertEqual(time, fixedTimestamp)
            // Duplicate/competing trigger: must not add another.
            session.stop()
            session.handleProcessExit(exitCode: 1)
            XCTAssertEqual(controls.snapshot().count, 1, "row 1: a duplicate/competing trigger must not fire a second ownerDisconnected")
        }

        // Row 2: process exit -> processExited, via the REAL
        // `CodexAppServerRuntimeSessionExitRouter` on a `factory.start`-owned
        // process (not calling `handleProcessExit` directly) — proves the
        // router wiring itself, not just the reason-mapping switch.
        do {
            let runner = FakeCodexAppServerProcessRunner()
            let controls = ControlCollector()
            var seq = 10
            _ = try CodexAppServerRuntimeSessionFactory(processRunner: runner)
                .start(configuration: CodexAppServerLaunchConfiguration(executablePath: "/tmp/disposable-codex",
                                                                        arguments: ["app-server"],
                                                                        workingDirectory: "/tmp/tidey-codex-disposable",
                                                                        environment: [:]),
                       context: CodexAppServerRuntimeContext(workspaceID: "workspace-1", panelID: "panel-1", sessionID: "session-1"),
                       nextSequence: { _ in
                           seq += 1
                           return seq
                       },
                       timestampProvider: { fixedTimestamp },
                       onAgentEvent: { _ in },
                       onInteractivePrompt: { _ in },
                       onInteractivePromptResolved: { _ in },
                       onWorkingControl: { controls.append($0) })
            try Self.acknowledgeInitialize(from: runner.process)
            let process = try XCTUnwrap(runner.process)
            process.emitExit(1)
            let captured = controls.snapshot()
            guard captured.count == 1, case .ownerDisconnected(let reason, let time) = captured[0] else {
                return XCTFail("row 2: expected exactly one ownerDisconnected, got \(captured)")
            }
            XCTAssertEqual(reason, .processExited)
            XCTAssertEqual(time, fixedTimestamp)
            // Duplicate exit via the SAME real router.
            process.emitExit(1)
            XCTAssertEqual(controls.snapshot().count, 1, "row 2: a duplicate exit via the real ExitRouter must not fire a second ownerDisconnected")
        }

        // Row 3: transport close (a real internal trigger — the fake
        // transport's own `close()`/`emitClose()`, not public stop()) ->
        // transportClosed.
        do {
            let controls = ControlCollector()
            let (session, transport) = try Self.attachPlainSession(controls: controls)
            transport.emitClose(nil)
            let captured = controls.snapshot()
            guard captured.count == 1, case .ownerDisconnected(let reason, let time) = captured[0] else {
                return XCTFail("row 3: expected exactly one ownerDisconnected, got \(captured)")
            }
            XCTAssertEqual(reason, .transportClosed)
            XCTAssertEqual(time, fixedTimestamp)
            transport.emitClose(nil)
            session.stop()
            XCTAssertEqual(controls.snapshot().count, 1, "row 3: a duplicate/competing trigger must not fire a second ownerDisconnected")
        }

        // Row 4: protocol violation -> transportClosed (per the locked
        // reason mapping: transport/protocol both map to transportClosed).
        // Driven through the REAL `CodexAppServerConnection` violation
        // detector — NOT a direct call to `handleProtocolViolation()`. The
        // detector only fires once a RESPONSE for the original request is
        // already on the wire (`submitApproval` must actually complete
        // first); a bare "approval, then changed redelivery" pair with no
        // response in between is legitimate superseded-payload handling,
        // not a violation.
        do {
            let runner = FakeCodexAppServerProcessRunner()
            let connector = FakeCodexAppServerTransportConnector()
            let factory = CodexAppServerRuntimeSessionFactory(processRunner: runner, transportConnector: connector)
            let controls = ControlCollector()
            let prompts = PromptSink()
            let session = try factory.attach(socketPath: "/tmp/tidey-real-panel/app.sock",
                                             processID: 9001,
                                             context: CodexAppServerRuntimeContext(workspaceID: "workspace-1",
                                                                                  panelID: "panel-1",
                                                                                  sessionID: "session-1"),
                                             nextSequence: { _ in 1 },
                                             timestampProvider: { fixedTimestamp },
                                             onAgentEvent: { _ in },
                                             onInteractivePrompt: { prompts.append($0) },
                                             onInteractivePromptResolved: { _ in },
                                             onWorkingControl: { controls.append($0) })
            prompts.session = session
            let transport = try XCTUnwrap(connector.transport)
            try Self.acknowledgeInitialize(from: transport)

            transport.emitLine(Self.violationApprovalLine)
            let envelope = try XCTUnwrap(prompts.envelopes().first)
            let outcome = try session.submitApproval(promptID: envelope.prompt.promptID,
                                                      targetIndex: 0,
                                                      clientRequestID: "client-1",
                                                      lifecycleToken: envelope.event.eventID)
            guard case .pendingConfirmation = outcome else {
                return XCTFail("row 4: submitApproval must put a response on the wire (pendingConfirmation) before the changed redelivery can be detected as a violation, got \(outcome)")
            }

            // NOW a changed request under the SAME id is a poisoned
            // request / genuine protocol violation.
            transport.emitLine(Self.violationChangedLine)

            let captured = controls.snapshot()
            guard captured.count == 1, case .ownerDisconnected(let reason, let time) = captured[0] else {
                return XCTFail("row 4: expected exactly one ownerDisconnected, got \(captured)")
            }
            XCTAssertEqual(reason, .transportClosed)
            XCTAssertEqual(time, fixedTimestamp)
            // Duplicate changed-line redelivery via the SAME real detector.
            transport.emitLine(Self.violationChangedLine)
            XCTAssertEqual(controls.snapshot().count, 1, "row 4: a duplicate changed-line trigger must not fire a second ownerDisconnected")
        }
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

    // P0: resume typed-control outcome matrix — 5 rows, each a fresh
    // session/collector, each response fed through the REAL pending
    // `thread/resume` response parser (not a direct call into
    // `seedActiveTurnFromResumeSnapshot`). `resumeSnapshotSeedAppliedHook`
    // independently proves whether the revision-fenced turn-state seed
    // itself applied, separate from the typed control outcome.
    func testResumeTypedControlOutcomeMatrix() throws {
        let fixedTimestamp = "2026-06-07T00:00:00.000Z"

        // Row 1: exact — requested thread, exactly one inProgress turn.
        do {
            let controls = ControlCollector()
            let (session, transport, resumeID) = try Self.attachSessionWithPendingResume(controls: controls)
            var seedApplied = false
            session.resumeSnapshotSeedAppliedHook = { seedApplied = true }

            transport.emitLine(try Self.responseText(id: resumeID,
                                                      result: Self.inProgressResumeResult(threadID: "thread-a", turnID: "turn-1")))

            XCTAssertTrue(seedApplied, "row 1 (exact): the revision-fenced seed must apply")
            XCTAssertEqual(controls.snapshot(), [.resumeSnapshot(threadID: "thread-a", turnID: "turn-1", time: fixedTimestamp)])
        }

        // Row 2: thread mismatch — response names a DIFFERENT thread than
        // requested, even though it carries an inProgress turn.
        do {
            let controls = ControlCollector()
            let (session, transport, resumeID) = try Self.attachSessionWithPendingResume(controls: controls)
            var seedApplied = false
            session.resumeSnapshotSeedAppliedHook = { seedApplied = true }

            transport.emitLine(try Self.responseText(id: resumeID,
                                                      result: Self.inProgressResumeResult(threadID: "thread-b", turnID: "turn-1")))

            XCTAssertFalse(seedApplied, "row 2 (thread mismatch): the seed must not apply")
            XCTAssertTrue(controls.snapshot().isEmpty, "row 2 (thread mismatch): 0 typed control")
        }

        // Row 3: zero inProgress turns — the thread is merely reported
        // "active" (may legitimately mark busy-without-turn-id at the
        // turn-state-store level), but must never GUESS a turn to open.
        do {
            let controls = ControlCollector()
            let (session, transport, resumeID) = try Self.attachSessionWithPendingResume(controls: controls)
            var seedApplied = false
            session.resumeSnapshotSeedAppliedHook = { seedApplied = true }

            transport.emitLine(try Self.responseText(id: resumeID, result: .object([
                "thread": .object([
                    "id": .string("thread-a"),
                    "status": .object(["type": .string("active"), "activeFlags": .array([.string("turn")])]),
                    "turns": .array([]),
                ]),
            ])))

            XCTAssertFalse(seedApplied, "row 3 (zero inProgress): the seed must not apply")
            XCTAssertTrue(controls.snapshot().isEmpty, "row 3 (zero inProgress): 0 typed control")
        }

        // Row 4: ambiguous — two distinct nonblank inProgress turns.
        do {
            let controls = ControlCollector()
            let (session, transport, resumeID) = try Self.attachSessionWithPendingResume(controls: controls)
            var seedApplied = false
            session.resumeSnapshotSeedAppliedHook = { seedApplied = true }

            transport.emitLine(try Self.responseText(id: resumeID, result: .object([
                "thread": .object([
                    "id": .string("thread-a"),
                    "status": .object(["type": .string("active"), "activeFlags": .array([.string("turn")])]),
                    "turns": .array([
                        .object(["id": .string("turn-x"), "status": .string("inProgress")]),
                        .object(["id": .string("turn-y"), "status": .string("inProgress")]),
                    ]),
                ]),
            ])))

            XCTAssertFalse(seedApplied, "row 4 (ambiguous): the seed must not apply")
            XCTAssertTrue(controls.snapshot().isEmpty, "row 4 (ambiguous): 0 typed control")
        }

        // Row 5: revision stale — a LIVE turn/started notification for the
        // SAME thread mutates the turn-state store (bumping the revision)
        // AFTER the resume request's barrier was captured but BEFORE the
        // response arrives; the response then names a DIFFERENT
        // ("turn-stale") turn as inProgress. The seed must reject it
        // (barrier invalidated) — but the LIVE turnStarted control (a
        // wholly separate, legitimate observation) must still have been
        // admitted. Filtering for `.resumeSnapshot` specifically — not
        // just checking "controls is empty" — is what actually
        // distinguishes this row from row 2-4's true zero-control cases.
        do {
            let controls = ControlCollector()
            let (session, transport, resumeID) = try Self.attachSessionWithPendingResume(controls: controls)
            var seedApplied = false
            session.resumeSnapshotSeedAppliedHook = { seedApplied = true }

            transport.emitLine(#"{"method":"turn/started","params":{"threadId":"thread-a","turn":{"id":"turn-live"}}}"#)
            transport.emitLine(try Self.responseText(id: resumeID,
                                                      result: Self.inProgressResumeResult(threadID: "thread-a", turnID: "turn-stale")))

            XCTAssertFalse(seedApplied, "row 5 (revision stale): the seed must not apply — the live turn/started already advanced the barrier")
            let captured = controls.snapshot()
            let resumeSnapshots = captured.filter {
                if case .resumeSnapshot = $0 { return true }
                return false
            }
            XCTAssertTrue(resumeSnapshots.isEmpty, "row 5 (revision stale): 0 .resumeSnapshot specifically")
            XCTAssertEqual(captured, [.turnStarted(threadID: "thread-a", turnID: "turn-live", time: fixedTimestamp)],
                           "row 5 (revision stale): the live turnStarted must still be present — an empty `captured` would wrongly conflate this row with a true zero-control case")
        }
    }

    // P0 regression: fresh Codex panel permanently stuck as `.busyWithoutTurnID`.
    //
    // Reproduced ordering: the wrapper/app-server starts before the root
    // rollout exists, so the registry-root `thread/resume` initially fails
    // with "no rollout found" (bounded backoff/retry). After that retry, a
    // LIVE `thread/status/changed(active)` notification for the SAME root
    // can race in BEFORE the retried resume's own success response —
    // arriving strictly between the resume's revision barrier being
    // captured and its response being processed. The resume response then
    // reports exactly one unambiguous in-progress turn (the already-running
    // turn the panel is resuming into), but the racing "active" notification
    // must NOT invalidate that snapshot: "active" is weak/compatible
    // evidence, not a genuine state advance like idle, turn started/
    // completed, or a submit's own claim.
    //
    // Three rows exercise the exact fixed code path
    // (`CodexAppServerTurnStateStore.markThreadActive`'s revision-fence
    // behavior) together with the safety it must NOT weaken:
    //   A. the combined bug ordering — a racing "active" notification must
    //      not block the resume's exact-one-inProgress snapshot from
    //      seeding, and the next submit must steer into that exact turn id.
    //   B. a racing LIVE turn/started for a DIFFERENT turn id still
    //      genuinely invalidates the resume's snapshot (a real state
    //      advance, unaffected by this fix) — the next submit must steer
    //      into the NEW live turn, never the stale resumed one.
    //   C. a zero-in-progress resume snapshot with the thread reported
    //      active, racing an "active" notification, still correctly leaves
    //      the thread busy-without-turn-id (never guesses a turn, never
    //      falls back to turn/start) — the "active" race does not turn a
    //      genuinely ambiguous snapshot into a false steer either.
    func testActiveStatusNotificationRacingResumeDoesNotInvalidateExactSnapshot() throws {
        // Row A: the bug's exact reproduced ordering.
        do {
            let controls = ControlCollector()
            let runner = FakeCodexAppServerProcessRunner()
            let connector = FakeCodexAppServerTransportConnector()
            let factory = CodexAppServerRuntimeSessionFactory(processRunner: runner, transportConnector: connector)
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
                                             onActiveThreadID: { _ in },
                                             onWorkingControl: { controls.append($0) })
            // Registry root learned before the loaded-list/rollout exists —
            // matches "Bridge learns the registry root and repeatedly sends
            // thread/resume" from the real reproduction.
            session.setRegistryRootThreadID("thread-root")

            let transport = try XCTUnwrap(connector.transport)
            try Self.acknowledgeInitialize(from: transport)

            // 1. Empty loaded/list (rollout not visible yet) -> registry-root
            // fallback resume — the FIRST `thread/resume` attempt.
            let firstListLoaded = try Self.object(from: try XCTUnwrap(transport.sentLines().dropFirst(2).first))
            XCTAssertEqual(firstListLoaded["method"]?.stringValue, "thread/loaded/list")
            transport.emitLine(try Self.responseText(id: try XCTUnwrap(firstListLoaded["id"]), result: .object(["threads": .array([])])))
            XCTAssertTrue(Self.waitForSentLineCount(4, transport: transport))
            let firstResume = try Self.object(from: try XCTUnwrap(transport.sentLines().dropFirst(3).first))
            XCTAssertEqual(firstResume["method"]?.stringValue, "thread/resume")
            XCTAssertEqual(firstResume["params"]?.objectValue?["threadId"]?.stringValue, "thread-root")

            // 2. "no rollout found" -> bounded backoff, matching the real
            // 10:18:38–10:18:46 retry window.
            transport.emitLine(try Self.errorResponseText(id: try XCTUnwrap(firstResume["id"]),
                                                          code: -32600,
                                                          message: "no rollout found for thread id thread-root"))

            // 3. After the bounded retry, resume is attempted again.
            Thread.sleep(forTimeInterval: 1.1)
            session.ensureThreadSubscription()
            XCTAssertTrue(Self.waitForSentLineCount(5, transport: transport))
            let retryListLoaded = try Self.object(from: try XCTUnwrap(transport.sentLines().dropFirst(4).first))
            XCTAssertEqual(retryListLoaded["method"]?.stringValue, "thread/loaded/list")
            transport.emitLine(try Self.responseText(id: try XCTUnwrap(retryListLoaded["id"]), result: .object(["threads": .array([])])))
            XCTAssertTrue(Self.waitForSentLineCount(6, transport: transport))
            let retryResume = try Self.object(from: try XCTUnwrap(transport.sentLines().dropFirst(5).first))
            XCTAssertEqual(retryResume["method"]?.stringValue, "thread/resume")
            XCTAssertEqual(retryResume["params"]?.objectValue?["threadId"]?.stringValue, "thread-root")

            // 4. BEFORE this resume's success response, a live
            // thread/status/changed(active) notification races in for the
            // SAME root — the exact ordering that permanently wedges the
            // panel pre-fix.
            transport.emitLine(#"""
            {"method":"thread/status/changed","params":{"threadId":"thread-root","status":{"type":"active"}}}
            """#)

            // 5. Resume success: exactly one unambiguous in-progress turn.
            let retryResumeID = try XCTUnwrap(retryResume["id"])
            transport.emitLine(try Self.responseText(id: retryResumeID,
                                                      result: Self.inProgressResumeResult(threadID: "thread-root", turnID: "turn-live-1")))

            XCTAssertEqual(controls.snapshot(), [.resumeSnapshot(threadID: "thread-root", turnID: "turn-live-1", time: "2026-06-07T00:00:00.000Z")],
                           "row A: the racing 'active' notification must not block the resume's exact-one-inProgress snapshot from seeding")

            // 6. The next submit must issue exactly one turn/steer with the
            // exact expected turn id — never busyWithoutTurnID, never
            // turn/start, never a terminal fallback.
            let requestObject = try awaitSubmitMessage(session,
                                                       text: "看到嗎",
                                                       transport: transport,
                                                       respondWithResult: .object(["turnId": .string("turn-live-1")]))
            XCTAssertEqual(requestObject["method"]?.stringValue, "turn/steer",
                           "row A: the submit must steer into the known live turn, never start a new turn or fail closed")
            XCTAssertEqual(requestObject["params"]?.objectValue?["expectedTurnId"]?.stringValue, "turn-live-1")
        }

        // Row B: a racing LIVE turn/started for a DIFFERENT turn id is a
        // genuine state advance — it must still invalidate the resume's
        // stale snapshot exactly as before this fix (this fix touches ONLY
        // the "active" notification's revision-fence behavior).
        do {
            let controls = ControlCollector()
            let (session, transport, resumeID) = try Self.attachSessionWithPendingResume(controls: controls)
            var seedApplied = false
            session.resumeSnapshotSeedAppliedHook = { seedApplied = true }

            // A genuinely NEW turn starts live on the same thread before the
            // pending resume's response arrives.
            transport.emitLine(#"""
            {"method":"turn/started","params":{"threadId":"thread-a","turn":{"id":"turn-new-live"}}}
            """#)

            // The resume response now names a DIFFERENT (stale) turn.
            transport.emitLine(try Self.responseText(id: resumeID,
                                                      result: Self.inProgressResumeResult(threadID: "thread-a", turnID: "turn-stale")))

            XCTAssertFalse(seedApplied, "row B: a live turn/started must still invalidate a racing resume snapshot")

            // The next submit steers into the NEW live turn, never the stale
            // resumed one.
            let requestObject = try awaitSubmitMessage(session,
                                                       text: "steer into live turn",
                                                       transport: transport,
                                                       respondWithResult: .object(["turnId": .string("turn-new-live")]))
            XCTAssertEqual(requestObject["method"]?.stringValue, "turn/steer")
            XCTAssertEqual(requestObject["params"]?.objectValue?["expectedTurnId"]?.stringValue, "turn-new-live",
                           "row B: must steer into the genuinely live turn, not any stale resumed turn id")
        }

        // Row C: zero in-progress turns with the thread reported active,
        // racing an "active" notification — must still correctly leave the
        // thread busy-without-turn-id (never guess a turn, never fall back
        // to turn/start). Proves the fix does not turn a genuinely ambiguous
        // snapshot into a false steer either.
        do {
            let controls = ControlCollector()
            let (session, transport, resumeID) = try Self.attachSessionWithPendingResume(controls: controls)
            var seedApplied = false
            session.resumeSnapshotSeedAppliedHook = { seedApplied = true }

            transport.emitLine(#"""
            {"method":"thread/status/changed","params":{"threadId":"thread-a","status":{"type":"active"}}}
            """#)

            transport.emitLine(try Self.responseText(id: resumeID, result: .object([
                "thread": .object([
                    "id": .string("thread-a"),
                    "status": .object(["type": .string("active"), "activeFlags": .array([.string("turn")])]),
                    "turns": .array([]),
                ]),
            ])))

            XCTAssertFalse(seedApplied, "row C: zero in-progress turns must never guess a turn id to seed")
            XCTAssertTrue(controls.snapshot().isEmpty, "row C: 0 typed control for an ambiguous (turn-less) active snapshot")

            let completion = expectation(description: "submitMessage rejects busyWithoutTurnID")
            var thrown: Error?
            DispatchQueue.global().async {
                do {
                    try session.submitMessage(text: "must not start or steer", clientRequestID: nil)
                } catch {
                    thrown = error
                }
                completion.fulfill()
            }
            wait(for: [completion], timeout: 5)
            guard let thrown, case CodexAppServerSubmitFailure.busyWithoutTurnID = thrown else {
                return XCTFail("row C: expected .busyWithoutTurnID, got \(String(describing: thrown))")
            }
            XCTAssertEqual(transport.sentLines().count, 4,
                           "row C: busyWithoutTurnID must be zero wire — no turn/start, no turn/steer")
        }
    }

    // Attaches a session and, immediately after acknowledging initialize but
    // BEFORE the auto-sent `thread/loaded/list` response arrives, emits a
    // live `thread/status/changed(active)` notification for `threadID` —
    // i.e. establishes active evidence GENUINELY PRE-EXISTING, before the
    // pending resume request's own revision barrier is ever captured (the
    // barrier is captured only once the loaded-list response resolves and
    // the resume is sent). Returns the resume request id once sent.
    private static func attachSessionWithPreExistingActiveEvidenceThenPendingResume(threadID: String,
                                                                                    controls: ControlCollector) throws -> (session: CodexAppServerRuntimeSession, transport: FakeCodexAppServerConnectionTransport, resumeID: JSONValue) {
        let runner = FakeCodexAppServerProcessRunner()
        let connector = FakeCodexAppServerTransportConnector()
        let factory = CodexAppServerRuntimeSessionFactory(processRunner: runner, transportConnector: connector)
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
                                         onActiveThreadID: { _ in },
                                         onWorkingControl: { controls.append($0) })
        let transport = try XCTUnwrap(connector.transport)
        try Self.acknowledgeInitialize(from: transport)

        transport.emitLine(#"""
        {"method":"thread/status/changed","params":{"threadId":"\#(threadID)","status":{"type":"active"}}}
        """#)

        let listLoaded = try Self.object(from: try XCTUnwrap(transport.sentLines().dropFirst(2).first))
        let listLoadedID = try XCTUnwrap(listLoaded["id"])
        transport.emitLine(try Self.responseText(id: listLoadedID, result: .object([
            "threads": .array([
                .object(["id": .string(threadID), "preview": .string("p"), "updatedAt": .string("2026-06-07T00:00:00.000Z")]),
            ]),
        ])))

        XCTAssertTrue(Self.waitForSentLineCount(4, transport: transport))
        let resume = try Self.object(from: try XCTUnwrap(transport.sentLines().dropFirst(3).first))
        XCTAssertEqual(resume["method"]?.stringValue, "thread/resume")
        let resumeID = try XCTUnwrap(resume["id"])
        return (session, transport, resumeID)
    }

    // P0 regression (second deterministic path to the same permanent
    // `busyWithoutTurnID` wedge): a racing "active" notification is now
    // correctly weak/non-invalidating (see the previous test), but if the
    // thread becomes idle again entirely BEFORE its own resume response
    // arrives, the resume snapshot reports zero in-progress turns and
    // `status.type == "idle"`. Pre-this-fix, `seedActiveTurnFromResumeSnapshot`
    // silently returned without ever clearing the compatible-but-now-
    // obsolete `threadStatusActiveStartedAt` the racing "active" notification
    // left behind — `.subscribed` had already committed (no further
    // loaded-list/resume retry), so the thread was left permanently
    // reporting busy-without-turn-id until a FUTURE live idle notification
    // happened to arrive or the 15-minute expiry fired.
    //
    // P0 follow-up (root review): idle clearing has NO downstream identity
    // protection (unlike the exact-one seed, where a wrong turn id is still
    // caught server-side by `turn/steer(expectedTurnId:)`), so it must NOT
    // clear active evidence that arrives AFTER the resume's own barrier was
    // captured — only evidence that PRE-DATES the barrier is safe to clear.
    // This requires a SECOND revision dimension (`activeEvidence`, checked
    // only by `markThreadIdleIfUnchanged`) alongside the original `state`
    // dimension (checked by the exact-one seed and both bookkeeping
    // branches) — see `CodexAppServerTurnStateStore.RevisionBarrier`.
    func testIdleResumeSnapshotReconcilesStaleActiveEvidence() throws {
        // Row A (the safe case): active evidence is PRE-EXISTING — already
        // present BEFORE the resume's own barrier was captured. The resume
        // then returns idle + zero turns and MAY clear it. The next submit
        // must issue exactly one turn/start, never a busy conflict.
        do {
            let controls = ControlCollector()
            let (session, transport, resumeID) = try Self.attachSessionWithPreExistingActiveEvidenceThenPendingResume(threadID: "thread-a", controls: controls)

            transport.emitLine(try Self.responseText(id: resumeID, result: .object([
                "thread": .object([
                    "id": .string("thread-a"),
                    "status": .object(["type": .string("idle")]),
                    "turns": .array([]),
                ]),
            ])))

            XCTAssertTrue(controls.snapshot().isEmpty, "row A: 0 typed control for an idle reconciliation — this is bookkeeping, not a turn open")

            let requestObject = try awaitSubmitMessage(session,
                                                       text: "row A submit",
                                                       transport: transport,
                                                       respondWithResult: .object(["turn": .object(["id": .string("turn-row-a")])]))
            XCTAssertEqual(requestObject["method"]?.stringValue, "turn/start",
                           "row A: pre-existing (pre-barrier) 'active' evidence must be cleared by the idle resume snapshot — the thread must route to a fresh turn/start, never busyWithoutTurnID")
        }

        // Row A2 (the UNSAFE ordering — must stay busy): the resume's
        // barrier is captured FIRST, and only THEN does a fresh "active"
        // notification arrive — evidence that is NEWER than the snapshot
        // the later idle response was built from. The stale idle+zero-turns
        // response must NOT clear it; the next submit must remain
        // `.busyWithoutTurnID` with ZERO wire.
        do {
            let controls = ControlCollector()
            let (session, transport, resumeID) = try Self.attachSessionWithPendingResume(controls: controls)

            // Active-only arrives AFTER the barrier was already captured
            // (the barrier was captured when the pending resume request was
            // built, inside the helper above).
            transport.emitLine(#"""
            {"method":"thread/status/changed","params":{"threadId":"thread-a","status":{"type":"active"}}}
            """#)

            // Stale: this resume response predates the "active" notification
            // above, but arrives reporting idle/zero turns.
            transport.emitLine(try Self.responseText(id: resumeID, result: .object([
                "thread": .object([
                    "id": .string("thread-a"),
                    "status": .object(["type": .string("idle")]),
                    "turns": .array([]),
                ]),
            ])))

            let sentCountBeforeSubmit = transport.sentLines().count
            let completion = expectation(description: "submitMessage rejects busyWithoutTurnID")
            var thrown: Error?
            DispatchQueue.global().async {
                do {
                    try session.submitMessage(text: "row A2 submit", clientRequestID: nil)
                } catch {
                    thrown = error
                }
                completion.fulfill()
            }
            wait(for: [completion], timeout: 5)
            guard let thrown, case CodexAppServerSubmitFailure.busyWithoutTurnID = thrown else {
                return XCTFail("row A2: expected .busyWithoutTurnID, got \(String(describing: thrown))")
            }
            XCTAssertEqual(transport.sentLines().count, sentCountBeforeSubmit,
                           "row A2: the stale idle snapshot must not have cleared the newer active evidence — zero wire, no turn/start")
        }

        // Row B (safety): a GENUINE live turn/started after the resume
        // barrier must still invalidate a later, now-stale idle snapshot —
        // the idle response must never clear newer, genuinely active state.
        // The next submit must steer into that live turn.
        do {
            let controls = ControlCollector()
            let (session, transport, resumeID) = try Self.attachSessionWithPendingResume(controls: controls)

            transport.emitLine(#"""
            {"method":"turn/started","params":{"threadId":"thread-a","turn":{"id":"turn-live-b"}}}
            """#)

            // Stale: the resume response was in flight before the live turn
            // started, but arrives reporting idle/zero turns.
            transport.emitLine(try Self.responseText(id: resumeID, result: .object([
                "thread": .object([
                    "id": .string("thread-a"),
                    "status": .object(["type": .string("idle")]),
                    "turns": .array([]),
                ]),
            ])))

            let requestObject = try awaitSubmitMessage(session,
                                                       text: "row B submit",
                                                       transport: transport,
                                                       respondWithResult: .object(["turnId": .string("turn-live-b")]))
            XCTAssertEqual(requestObject["method"]?.stringValue, "turn/steer",
                           "row B: the stale idle snapshot must not clear the genuinely live turn — the submit must still steer into it")
            XCTAssertEqual(requestObject["params"]?.objectValue?["expectedTurnId"]?.stringValue, "turn-live-b")
        }

        // Row C (retained): active notification races the resume, but the
        // resume response itself reports zero/ambiguous in-progress turns
        // with `status.type == "active"` (not idle) — must still correctly
        // fail closed to busyWithoutTurnID, never guess, never start.
        do {
            let controls = ControlCollector()
            let (session, transport, resumeID) = try Self.attachSessionWithPendingResume(controls: controls)

            transport.emitLine(#"""
            {"method":"thread/status/changed","params":{"threadId":"thread-a","status":{"type":"active"}}}
            """#)

            transport.emitLine(try Self.responseText(id: resumeID, result: .object([
                "thread": .object([
                    "id": .string("thread-a"),
                    "status": .object(["type": .string("active"), "activeFlags": .array([.string("turn")])]),
                    "turns": .array([]),
                ]),
            ])))

            XCTAssertTrue(controls.snapshot().isEmpty, "row C: 0 typed control for an ambiguous (turn-less) active snapshot")

            let completion = expectation(description: "submitMessage rejects busyWithoutTurnID")
            var thrown: Error?
            DispatchQueue.global().async {
                do {
                    try session.submitMessage(text: "row C submit", clientRequestID: nil)
                } catch {
                    thrown = error
                }
                completion.fulfill()
            }
            wait(for: [completion], timeout: 5)
            guard let thrown, case CodexAppServerSubmitFailure.busyWithoutTurnID = thrown else {
                return XCTFail("row C: expected .busyWithoutTurnID, got \(String(describing: thrown))")
            }
            XCTAssertEqual(transport.sentLines().count, 4,
                           "row C: busyWithoutTurnID must be zero wire — no turn/start, no turn/steer")
        }
    }

    // P0 (root review): fail closed on malformed/ambiguous in-progress
    // shapes. The RAW in-progress turn count/shape must be evaluated
    // separately from valid-ID extraction — `compactMap`-ing only valid
    // nonblank IDs and then counting THOSE would let `[valid A, blank-ID
    // inProgress]` masquerade as a false unique `A` (seeding it), and would
    // let a lone blank-ID inProgress turn masquerade as "zero turns" for
    // idle reconciliation (wrongly clearing busy state).
    func testMalformedInProgressShapesFailClosed() throws {
        // Row 1: active snapshot with [valid A, blank-ID inProgress] — RAW
        // count is 2 (ambiguous), never a false unique A. Must never
        // seed/steer-guess; must still fail closed to busyWithoutTurnID
        // (status active), zero submit wire.
        do {
            let controls = ControlCollector()
            let (session, transport, resumeID) = try Self.attachSessionWithPendingResume(controls: controls)
            var seedApplied = false
            session.resumeSnapshotSeedAppliedHook = { seedApplied = true }

            transport.emitLine(try Self.responseText(id: resumeID, result: .object([
                "thread": .object([
                    "id": .string("thread-a"),
                    "status": .object(["type": .string("active"), "activeFlags": .array([.string("turn")])]),
                    "turns": .array([
                        .object(["id": .string("turn-A"), "status": .string("inProgress")]),
                        .object(["id": .string(""), "status": .string("inProgress")]),
                    ]),
                ]),
            ])))

            XCTAssertFalse(seedApplied, "row 1: a raw count of 2 (one valid, one blank-ID) must never be misread as a false unique seed")
            XCTAssertTrue(controls.snapshot().isEmpty, "row 1: 0 typed control")

            let sentCountBeforeSubmit = transport.sentLines().count
            let completion = expectation(description: "submitMessage rejects busyWithoutTurnID")
            var thrown: Error?
            DispatchQueue.global().async {
                do {
                    try session.submitMessage(text: "row 1 submit", clientRequestID: nil)
                } catch {
                    thrown = error
                }
                completion.fulfill()
            }
            wait(for: [completion], timeout: 5)
            guard let thrown, case CodexAppServerSubmitFailure.busyWithoutTurnID = thrown else {
                return XCTFail("row 1: expected .busyWithoutTurnID, got \(String(describing: thrown))")
            }
            XCTAssertEqual(transport.sentLines().count, sentCountBeforeSubmit,
                           "row 1: busyWithoutTurnID must be zero wire — no turn/start, no turn/steer")
        }

        // Row 2: idle snapshot with a lone blank-ID inProgress turn — RAW
        // count is 1 (not zero), so idle reconciliation must NOT run at
        // all. Pre-existing (pre-barrier) active evidence must survive
        // untouched — the next submit must remain busyWithoutTurnID.
        do {
            let controls = ControlCollector()
            let (session, transport, resumeID) = try Self.attachSessionWithPreExistingActiveEvidenceThenPendingResume(threadID: "thread-a", controls: controls)

            transport.emitLine(try Self.responseText(id: resumeID, result: .object([
                "thread": .object([
                    "id": .string("thread-a"),
                    "status": .object(["type": .string("idle")]),
                    "turns": .array([
                        .object(["id": .string(""), "status": .string("inProgress")]),
                    ]),
                ]),
            ])))

            let sentCountBeforeSubmit = transport.sentLines().count
            let completion = expectation(description: "submitMessage rejects busyWithoutTurnID")
            var thrown: Error?
            DispatchQueue.global().async {
                do {
                    try session.submitMessage(text: "row 2 submit", clientRequestID: nil)
                } catch {
                    thrown = error
                }
                completion.fulfill()
            }
            wait(for: [completion], timeout: 5)
            guard let thrown, case CodexAppServerSubmitFailure.busyWithoutTurnID = thrown else {
                return XCTFail("row 2: expected .busyWithoutTurnID, got \(String(describing: thrown))")
            }
            XCTAssertEqual(transport.sentLines().count, sentCountBeforeSubmit,
                           "row 2: a lone blank-ID inProgress turn must never be misread as zero turns — the pre-existing active evidence must survive uncleared")
        }

        // Row 3: idle snapshot with a MISSING `turns` field — must never be
        // treated as zero turns either. Pre-existing (pre-barrier) active
        // evidence must survive untouched.
        do {
            let controls = ControlCollector()
            let (session, transport, resumeID) = try Self.attachSessionWithPreExistingActiveEvidenceThenPendingResume(threadID: "thread-a", controls: controls)

            transport.emitLine(try Self.responseText(id: resumeID, result: .object([
                "thread": .object([
                    "id": .string("thread-a"),
                    "status": .object(["type": .string("idle")]),
                ]),
            ])))

            let sentCountBeforeSubmit = transport.sentLines().count
            let completion = expectation(description: "submitMessage rejects busyWithoutTurnID")
            var thrown: Error?
            DispatchQueue.global().async {
                do {
                    try session.submitMessage(text: "row 3 submit", clientRequestID: nil)
                } catch {
                    thrown = error
                }
                completion.fulfill()
            }
            wait(for: [completion], timeout: 5)
            guard let thrown, case CodexAppServerSubmitFailure.busyWithoutTurnID = thrown else {
                return XCTFail("row 3: expected .busyWithoutTurnID, got \(String(describing: thrown))")
            }
            XCTAssertEqual(transport.sentLines().count, sentCountBeforeSubmit,
                           "row 3: a missing (non-array) turns field must never be treated as zero turns — the pre-existing active evidence must survive uncleared")
        }
    }

    // P0 (root review): the finish/stopped gate must cover EVERY
    // resume-snapshot turn-store mutation — not just the exact-one seed.
    // Proven via a PAIR of hooks, not `resumeSnapshotReservationAcquiredHook`
    // alone (a mutation probe caught this: narrowing the reservation to
    // wrap only the exact-one branch left the active/idle branches running
    // fully unguarded, yet the reservation hook still never fired for them
    // — indistinguishable from a correct rejection unless something else
    // also proves those branches touched nothing):
    //   - `resumeSnapshotReservationAcquiredHook` fires the instant the
    //     finish-linearization reservation is acquired, BEFORE any of the
    //     three branches run — not firing shows the response never reached
    //     a gated branch;
    //   - `resumeSnapshotSeedAppliedHook`/`resumeSnapshotBookkeepingAppliedHook`
    //     fire only when a branch's own store mutation actually applied —
    //     not firing shows that branch (if it ran at all) mutated nothing.
    // Together, both hooks staying silent proves zero mutation occurred for
    // ANY branch; the reservation hook alone does not.
    //
    // Also PROVES (not merely documents) why the `.subscribed` state
    // transition (set by the response handler BEFORE this reconciliation
    // runs) is harmless on a dead generation: this test asserts, via
    // `subscriptionDiagnosticSnapshotForTesting()`, that the dead
    // generation really was left at `.subscribed(threadID: "thread-a")` —
    // then shows `ensureThreadSubscription()`/`refreshActiveThread()` still
    // send zero wire from that exact state, because both check `stopped`
    // FIRST (via `beginSubscriptionAttempt`/`canRefreshActiveThread`).
    // Without the snapshot assertion, the zero-wire check would ALSO pass
    // if the `.subscribed` transition had simply never happened.
    func testFinishFirstLateIdleAndActiveAmbiguousResponsesEmitZeroMutation() throws {
        // Row 1: late idle + zero in-progress turns.
        do {
            let controls = ControlCollector()
            let (session, transport, resumeID) = try Self.attachSessionWithPendingResume(controls: controls)

            var reservationAcquired = false
            session.resumeSnapshotReservationAcquiredHook = { reservationAcquired = true }
            // The active/idle branches have no OTHER externally observable
            // success signal (no typed control is ever emitted for them, by
            // design). Paired with `reservationAcquired` above: this hook
            // NOT firing shows `markThreadIdleIfUnchanged` applied no
            // mutation (it only fires on a `true` return) — together with
            // the reservation hook also not firing, this is what actually
            // proves zero mutation, since either hook alone leaves a gap
            // (see the function's own doc comment).
            var bookkeepingApplied = false
            session.resumeSnapshotBookkeepingAppliedHook = { bookkeepingApplied = true }

            let pauseReached = DispatchSemaphore(value: 0)
            let releasePause = DispatchSemaphore(value: 0)
            // Safety net: an early failure below must not leave the winner
            // permanently parked mid-teardown.
            defer { releasePause.signal() }
            session.finishTeardownPauseHook = {
                pauseReached.signal()
                releasePause.wait()
            }

            let finishDone = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                session.stop()
                finishDone.signal()
            }
            XCTAssertEqual(pauseReached.wait(timeout: .now() + 5), .success,
                           "row 1: finish must reach the pause point: stopped claimed, teardown not yet run")

            transport.emitLine(try Self.responseText(id: resumeID, result: .object([
                "thread": .object([
                    "id": .string("thread-a"),
                    "status": .object(["type": .string("idle")]),
                    "turns": .array([]),
                ]),
            ])))

            XCTAssertFalse(reservationAcquired, "row 1: a finish-first late response must be rejected by the stopped gate BEFORE any branch (exact-one/active/idle) ever runs")
            XCTAssertFalse(bookkeepingApplied, "row 1: markThreadIdleIfUnchanged must not have applied any mutation for a finish-first late response")
            XCTAssertEqual(controls.snapshot().count, 0, "row 1: no resumeSnapshot control while finish is mid-teardown")

            // Proves the `.subscribed` transition genuinely committed on
            // this dead generation (set by the response handler before this
            // reconciliation ran) — without this, the zero-wire assertion
            // below would ALSO pass if the transition had simply never
            // happened, making it no proof of the documented tradeoff at
            // all.
            let subscriptionSnapshot = session.subscriptionDiagnosticSnapshotForTesting()
            XCTAssertEqual(subscriptionSnapshot.state, .subscribed(threadID: "thread-a"),
                           "row 1: the dead generation must genuinely be left .subscribed — this is the state the zero-wire check below is proving is inert")
            XCTAssertNil(subscriptionSnapshot.nextRetryAt, "row 1: no backoff/retry is armed for this dead generation")

            session.ensureThreadSubscription()
            session.refreshActiveThread()
            XCTAssertEqual(transport.sentLines().count, 4,
                           "row 1: a dead, already-`.subscribed` generation must never send further subscription wire traffic")

            releasePause.signal()
            XCTAssertEqual(finishDone.wait(timeout: .now() + 5), .success)

            let captured = controls.snapshot()
            guard captured.count == 1, case .ownerDisconnected(let reason, _) = captured[0] else {
                return XCTFail("row 1: expected exactly one ownerDisconnected, got \(captured)")
            }
            XCTAssertEqual(reason, .sessionRetired)
        }

        // Row 2: late active + ambiguous (multiple) in-progress turns.
        do {
            let controls = ControlCollector()
            let (session, transport, resumeID) = try Self.attachSessionWithPendingResume(controls: controls)

            var reservationAcquired = false
            session.resumeSnapshotReservationAcquiredHook = { reservationAcquired = true }
            var bookkeepingApplied = false
            session.resumeSnapshotBookkeepingAppliedHook = { bookkeepingApplied = true }

            let pauseReached = DispatchSemaphore(value: 0)
            let releasePause = DispatchSemaphore(value: 0)
            defer { releasePause.signal() }
            session.finishTeardownPauseHook = {
                pauseReached.signal()
                releasePause.wait()
            }

            let finishDone = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                session.stop()
                finishDone.signal()
            }
            XCTAssertEqual(pauseReached.wait(timeout: .now() + 5), .success,
                           "row 2: finish must reach the pause point: stopped claimed, teardown not yet run")

            transport.emitLine(try Self.responseText(id: resumeID, result: .object([
                "thread": .object([
                    "id": .string("thread-a"),
                    "status": .object(["type": .string("active"), "activeFlags": .array([.string("turn")])]),
                    "turns": .array([
                        .object(["id": .string("turn-X"), "status": .string("inProgress")]),
                        .object(["id": .string("turn-Y"), "status": .string("inProgress")]),
                    ]),
                ]),
            ])))

            XCTAssertFalse(reservationAcquired, "row 2: a finish-first late response must be rejected by the stopped gate BEFORE any branch ever runs")
            XCTAssertFalse(bookkeepingApplied, "row 2: markThreadActiveIfUnchanged must not have applied any mutation for a finish-first late response")
            XCTAssertEqual(controls.snapshot().count, 0, "row 2: no resumeSnapshot control while finish is mid-teardown")

            // Proves the `.subscribed` transition genuinely committed on
            // this dead generation — without this, the zero-wire assertion
            // below would ALSO pass if the transition had simply never
            // happened.
            let subscriptionSnapshot = session.subscriptionDiagnosticSnapshotForTesting()
            XCTAssertEqual(subscriptionSnapshot.state, .subscribed(threadID: "thread-a"),
                           "row 2: the dead generation must genuinely be left .subscribed — this is the state the zero-wire check below is proving is inert")
            XCTAssertNil(subscriptionSnapshot.nextRetryAt, "row 2: no backoff/retry is armed for this dead generation")

            session.ensureThreadSubscription()
            session.refreshActiveThread()
            XCTAssertEqual(transport.sentLines().count, 4,
                           "row 2: a dead, already-`.subscribed` generation must never send further subscription wire traffic")

            releasePause.signal()
            XCTAssertEqual(finishDone.wait(timeout: .now() + 5), .success)

            let captured = controls.snapshot()
            guard captured.count == 1, case .ownerDisconnected(let reason, _) = captured[0] else {
                return XCTFail("row 2: expected exactly one ownerDisconnected, got \(captured)")
            }
            XCTAssertEqual(reason, .sessionRetired)
        }
    }

    // P0: if finish() claims the session BEFORE a resume response even
    // arrives, the late response must produce ZERO Working control — only
    // the finish winner's own single `ownerDisconnected`. Deterministic via
    // `finishTeardownPauseHook`: pauses the winner AFTER `stopped` is
    // claimed but BEFORE `connection.close()` runs, so the pending
    // response handler is still registered when the late response arrives
    // — proving `reserveResumeControlEmission`'s `stopped` check (not an
    // incidental connection-close side effect that already removed the
    // handler) is what rejects it. Also asserts the turn-state seed itself
    // never applied, via `resumeSnapshotSeedAppliedHook`.
    func testFinishFirstThenLateResumeResponseEmitsZeroControl() throws {
        let controls = ControlCollector()
        let (session, transport, resumeID) = try Self.attachSessionWithPendingResume(controls: controls)

        var seedApplied = false
        session.resumeSnapshotSeedAppliedHook = { seedApplied = true }

        let pauseReached = DispatchSemaphore(value: 0)
        let releasePause = DispatchSemaphore(value: 0)
        session.finishTeardownPauseHook = {
            pauseReached.signal()
            releasePause.wait()
        }

        let finishDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            session.stop()
            finishDone.signal()
        }

        XCTAssertEqual(pauseReached.wait(timeout: .now() + 5), .success,
                       "finish must reach the pause point: stopped claimed, teardown not yet run")

        transport.emitLine(try Self.responseText(id: resumeID,
                                                  result: Self.inProgressResumeResult(threadID: "thread-a", turnID: "turn-1")))

        XCTAssertFalse(seedApplied, "the turn-state seed must not apply once finish has claimed the session")
        XCTAssertEqual(controls.snapshot().count, 0, "no resumeSnapshot may be appended while finish is mid-teardown, still paused before its own ownerDisconnected")

        releasePause.signal()
        XCTAssertEqual(finishDone.wait(timeout: .now() + 5), .success)

        let captured = controls.snapshot()
        XCTAssertEqual(captured.count, 1, "the late resume response must add nothing after finish already claimed the session")
        guard case .ownerDisconnected = captured.first else {
            return XCTFail("expected exactly one ownerDisconnected, got \(captured)")
        }
        XCTAssertTrue(session.isStopped())
    }

    // P0: a resume reservation that wins the race (its response is already
    // being processed when a DIFFERENT thread calls finish) must complete
    // its `.resumeSnapshot` emission BEFORE the finish winner's
    // `.ownerDisconnected` — the winner blocks on the reservation, never
    // races ahead of it. Deterministic via semaphores (no sleep/timing
    // heuristics): finish's completion semaphore is asserted to TIME OUT
    // while the reservation is deliberately held open, proving finish is
    // genuinely blocked rather than merely finishing "late enough" by luck.
    func testResumeReservationWinsThenDifferentThreadFinishWaitsAndEmitsOwnerTerminalAfter() throws {
        let controls = ControlCollector()
        let (session, transport, resumeID) = try Self.attachSessionWithPendingResume(controls: controls)

        let reservationHeld = DispatchSemaphore(value: 0)
        let releaseReservation = DispatchSemaphore(value: 0)
        controls.onAppend = { event in
            if case .resumeSnapshot = event {
                reservationHeld.signal()
                releaseReservation.wait()
            }
        }

        let emitDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            // `onWorkingControl(.resumeSnapshot)` runs synchronously inside
            // this response handling, blocking on `releaseReservation`
            // while holding the reservation open.
            transport.emitLine((try? Self.responseText(id: resumeID,
                                                        result: Self.inProgressResumeResult(threadID: "thread-a", turnID: "turn-1"))) ?? "")
            emitDone.signal()
        }
        XCTAssertEqual(reservationHeld.wait(timeout: .now() + 5), .success)

        let finishStarted = DispatchSemaphore(value: 0)
        let finishDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            finishStarted.signal()
            session.stop()
            finishDone.signal()
        }

        // Wait for the finish task to actually START before asserting it
        // hasn't finished yet — otherwise a merely-not-yet-scheduled task
        // (global queue contention, not a genuine block on the
        // reservation) would make the negative wait below pass for the
        // wrong reason. `isStopped()` becoming true confirms `finish()` has
        // entered its body (claimed `stopped`) and is now genuinely
        // waiting on the reservation drain, not still waiting to be
        // scheduled.
        XCTAssertEqual(finishStarted.wait(timeout: .now() + 5), .success)
        let stoppedDeadline = Date().addingTimeInterval(5)
        while session.isStopped() == false, Date() < stoppedDeadline {
            Thread.sleep(forTimeInterval: 0.005)
        }
        XCTAssertTrue(session.isStopped(), "finish() must have entered its body and claimed stopped")

        // While the reservation is deliberately still held, finish() must
        // be genuinely blocked — not just racing and happening to finish
        // after. A short bounded wait that TIMES OUT is the proof; a
        // buggy implementation that doesn't wait for the reservation would
        // complete here instead.
        XCTAssertEqual(finishDone.wait(timeout: .now() + 0.3), .timedOut,
                       "finish must still be blocked on the in-flight resume reservation")
        XCTAssertTrue(controls.snapshot().allSatisfy { if case .ownerDisconnected = $0 { return false } else { return true } },
                      "ownerDisconnected must not appear while finish is still blocked")

        releaseReservation.signal()
        XCTAssertEqual(emitDone.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(finishDone.wait(timeout: .now() + 5), .success,
                       "the finish winner must complete once the reservation releases")

        let captured = controls.snapshot()
        guard captured.count == 2 else {
            return XCTFail("expected exactly [resumeSnapshot, ownerDisconnected], got \(captured)")
        }
        guard case .resumeSnapshot(let threadID, let turnID, _) = captured[0] else {
            return XCTFail("expected resumeSnapshot first, got \(captured)")
        }
        XCTAssertEqual(threadID, "thread-a")
        XCTAssertEqual(turnID, "turn-1")
        guard case .ownerDisconnected = captured[1] else {
            return XCTFail("expected ownerDisconnected strictly after resumeSnapshot, got \(captured)")
        }
    }

    // P0 (the mutation-killer for the original sticky-Working bug): a REAL
    // INTERNAL trigger (transport close, not public `stop()`) wins the
    // finish race while a real Working turn is open AND a real approval
    // prompt is pending. A Syncer-style public `stop()` loser on an
    // UNRELATED thread must remain blocked through the ENTIRE control
    // teardown — not just the owner-disconnect callback, but also
    // `connection.close()`'s own synchronous pending-prompt expiry — and
    // only return once both have genuinely completed. Every step is
    // proven via entered/release/done semaphores, never elapsed-time
    // heuristics.
    func testInternalWinnerPublicStopLoserWaitsThroughOwnerDisconnectAndPromptResolvedBarrier() throws {
        enum Recorded: Equatable {
            case turnStartedOpen(String, String)
            case ownerDisconnected(String)
            case promptResolved(String)
        }
        let orderLock = NSLock()
        var order: [Recorded] = []
        func record(_ item: Recorded) {
            orderLock.lock()
            order.append(item)
            orderLock.unlock()
        }

        let ownerPauseEntered = DispatchSemaphore(value: 0)
        let ownerPauseRelease = DispatchSemaphore(value: 0)
        let promptPauseEntered = DispatchSemaphore(value: 0)
        let promptPauseRelease = DispatchSemaphore(value: 0)

        let runner = FakeCodexAppServerProcessRunner()
        let connector = FakeCodexAppServerTransportConnector()
        let factory = CodexAppServerRuntimeSessionFactory(processRunner: runner, transportConnector: connector)
        let prompts = PromptSink()
        let session = try factory.attach(socketPath: "/tmp/tidey-real-panel/app.sock",
                                         processID: 9001,
                                         context: CodexAppServerRuntimeContext(workspaceID: "workspace-1",
                                                                              panelID: "panel-1",
                                                                              sessionID: "session-1"),
                                         nextSequence: { _ in 1 },
                                         timestampProvider: { "2026-06-07T00:00:00.000Z" },
                                         onAgentEvent: { _ in },
                                         onInteractivePrompt: { prompts.append($0) },
                                         onInteractivePromptResolved: { event in
                                             record(.promptResolved(event.metadata?["reason"] ?? "?"))
                                             promptPauseEntered.signal()
                                             promptPauseRelease.wait()
                                         },
                                         onActiveThreadID: { _ in },
                                         onWorkingControl: { control in
                                             switch control {
                                             case let .turnStarted(threadID, turnID, _):
                                                 record(.turnStartedOpen(threadID, turnID))
                                             case .ownerDisconnected(let reason, _):
                                                 record(.ownerDisconnected(reason.rawValue))
                                                 ownerPauseEntered.signal()
                                                 ownerPauseRelease.wait()
                                             default:
                                                 break
                                             }
                                         })
        let transport = try XCTUnwrap(connector.transport)
        try Self.acknowledgeInitialize(from: transport)

        // A real open Working turn.
        transport.emitLine(#"{"method":"turn/started","params":{"threadId":"thread-1","turn":{"id":"turn-1"}}}"#)
        // A real pending approval prompt.
        transport.emitLine(Self.violationApprovalLine)
        XCTAssertFalse(prompts.envelopes().isEmpty, "the approval prompt must actually be pending before finish runs")

        // WINNER: a genuine internal trigger — the transport itself closing
        // (e.g. a dropped socket) — NOT public `stop()`.
        let winnerDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            transport.emitClose(nil)
            winnerDone.signal()
        }
        XCTAssertEqual(ownerPauseEntered.wait(timeout: .now() + 5), .success,
                       "the internal winner must reach its ownerDisconnected callback")

        // LOSER: the Syncer's own public `stop()`, on an unrelated thread.
        let loserStarted = DispatchSemaphore(value: 0)
        let loserDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            loserStarted.signal()
            session.stop()
            loserDone.signal()
        }
        XCTAssertEqual(loserStarted.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(loserDone.wait(timeout: .now() + 0.3), .timedOut,
                       "the loser must still be blocked while the winner is paused inside its OWN ownerDisconnected callback")

        // Release the owner callback: finish proceeds into
        // `connection.close()`, which synchronously expires the pending
        // prompt — the loser must STILL be blocked through that.
        ownerPauseRelease.signal()
        XCTAssertEqual(promptPauseEntered.wait(timeout: .now() + 5), .success,
                       "connection.close() must synchronously reach the pending prompt's resolution")
        XCTAssertEqual(loserDone.wait(timeout: .now() + 0.3), .timedOut,
                       "the loser must still be blocked while the pending prompt's resolution is paused")

        // Only now may the loser return.
        promptPauseRelease.signal()
        XCTAssertEqual(winnerDone.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(loserDone.wait(timeout: .now() + 5), .success,
                       "the loser must return once the full control teardown — owner terminal AND prompt resolution — has genuinely completed")

        orderLock.lock()
        let finalOrder = order
        orderLock.unlock()
        guard finalOrder.count == 3 else {
            return XCTFail("expected exactly [turnStartedOpen, ownerDisconnected, promptResolved], got \(finalOrder)")
        }
        XCTAssertEqual(finalOrder[0], .turnStartedOpen("thread-1", "turn-1"),
                       "the turn must have genuinely been open (observed) before anything else in this sequence")
        XCTAssertEqual(finalOrder[1], .ownerDisconnected("transport_closed"),
                       "the winner's own reason (transport close, not the loser's sessionRetired) must be recorded")
        XCTAssertEqual(finalOrder[2], .promptResolved("expired"),
                       "connection.close() expires pending prompts with reason \"expired\" specifically")
    }

    // P0: an internal termination trigger that re-enters ANOTHER internal
    // handler synchronously (transport.close() -> onClose ->
    // handleTransportClosed, exercised naturally by the fake transport)
    // must not self-wait or double-deliver — exactly one ownerDisconnected,
    // exactly one transport close, no hang.
    func testInternalTerminationReentryDeliversExactlyOnceWithoutHanging() throws {
        let controls = ControlCollector()
        let (session, transport, _) = try Self.attachSessionWithPendingResume(controls: controls)

        session.stop()

        XCTAssertEqual(transport.closeCallCount, 1, "transport.close() must run exactly once even though it synchronously reenters handleTransportClosed")
        XCTAssertEqual(controls.snapshot().count, 1)
        guard case .ownerDisconnected = controls.snapshot().first else {
            return XCTFail("expected exactly one ownerDisconnected")
        }

        // A second, fully independent stop() call (simulating a stray
        // internal trigger arriving after the session already finished)
        // must also be a clean no-op — no additional ownerDisconnected, no
        // hang.
        session.stop()
        XCTAssertEqual(controls.snapshot().count, 1)
    }

    // P0 (mutation-killer for the `finishWinnerThread` same-thread
    // exemption): `connection.close()`'s pending-prompt expiry
    // synchronously calls `onInteractivePromptResolved` — arbitrary
    // application code, which here calls public `stop()` reentrantly, on
    // the EXACT SAME thread as the finish winner, BEFORE
    // `controlTeardownComplete` is ever signaled. If `finishWinnerThread`
    // didn't exempt this thread, the reentrant `stop()` would wait forever
    // for a signal only this same (now-recursively-blocked) call could
    // ever send — deadlock.
    func testSameWinnerThreadPublicStopReentersFromPromptResolvedCallbackBeforeTeardownSignal() throws {
        let runner = FakeCodexAppServerProcessRunner()
        let connector = FakeCodexAppServerTransportConnector()
        let factory = CodexAppServerRuntimeSessionFactory(processRunner: runner, transportConnector: connector)
        let controls = ControlCollector()
        let prompts = PromptSink()

        let resolvedEntered = DispatchSemaphore(value: 0)
        let reentrantStopReturned = DispatchSemaphore(value: 0)
        let resolvedLock = NSLock()
        var resolvedEvents: [AgentEvent] = []

        let session = try factory.attach(socketPath: "/tmp/tidey-real-panel/app.sock",
                                         processID: 9001,
                                         context: CodexAppServerRuntimeContext(workspaceID: "workspace-1",
                                                                              panelID: "panel-1",
                                                                              sessionID: "session-1"),
                                         nextSequence: { _ in 1 },
                                         timestampProvider: { "2026-06-07T00:00:00.000Z" },
                                         onAgentEvent: { _ in },
                                         onInteractivePrompt: { prompts.append($0) },
                                         onInteractivePromptResolved: { event in
                                             resolvedLock.lock()
                                             resolvedEvents.append(event)
                                             resolvedLock.unlock()
                                             resolvedEntered.signal()
                                             // Reentrant, on the WINNER's own thread — this is the
                                             // exact hazard `finishWinnerThread` exists to handle.
                                             prompts.session?.stop()
                                             reentrantStopReturned.signal()
                                         },
                                         onWorkingControl: { controls.append($0) })
        prompts.session = session
        let transport = try XCTUnwrap(connector.transport)
        try Self.acknowledgeInitialize(from: transport)

        transport.emitLine(Self.violationApprovalLine)
        XCTAssertFalse(prompts.envelopes().isEmpty, "the pending prompt must exist before finish runs — connection.close() will expire it")

        // WINNER: a real internal trigger (transport close), not public
        // stop() — matches the locked race (internal winner, public stop
        // reenters from inside its own teardown).
        let winnerDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            transport.emitClose(nil)
            winnerDone.signal()
        }

        XCTAssertEqual(resolvedEntered.wait(timeout: .now() + 5), .success,
                       "connection.close() must synchronously reach the pending prompt's resolution")
        XCTAssertEqual(reentrantStopReturned.wait(timeout: .now() + 5), .success,
                       "the reentrant stop() on the winner's own thread must return immediately, not deadlock")
        XCTAssertEqual(winnerDone.wait(timeout: .now() + 5), .success)

        let captured = controls.snapshot()
        guard captured.count == 1, case .ownerDisconnected(let reason, let time) = captured[0] else {
            return XCTFail("expected exactly one ownerDisconnected, got \(captured)")
        }
        XCTAssertEqual(reason, .transportClosed)
        XCTAssertEqual(time, "2026-06-07T00:00:00.000Z")

        resolvedLock.lock()
        let finalResolved = resolvedEvents
        resolvedLock.unlock()
        guard finalResolved.count == 1 else {
            return XCTFail("expected exactly one prompt resolved, got \(finalResolved)")
        }
        XCTAssertEqual(finalResolved[0].metadata?["reason"], "expired")
        XCTAssertEqual(transport.closeCallCount, 1)
    }

    // P0: an INTERNAL termination trigger (process exit / transport /
    // protocol) on a DIFFERENT thread than the current finish winner must
    // return IMMEDIATELY, without waiting for the winner's still-pending
    // teardown-complete signal — proven by pausing the winner BEFORE that
    // signal (via `finishTeardownPauseHook`) and bounding the loser's
    // completion to a short window. If an internal loser were ever changed
    // to wait like the public `stop()` loser does, this test would time
    // out and fail — a same-winner-thread exemption alone would NOT catch
    // that regression, since this loser runs on a genuinely different
    // thread.
    func testDifferentThreadInternalLoserNeverWaitsBeforeTeardownSignal() throws {
        let controls = ControlCollector()
        let (session, transport) = try Self.attachPlainSession(controls: controls)

        let winnerPaused = DispatchSemaphore(value: 0)
        let releaseWinner = DispatchSemaphore(value: 0)
        // Safety net: release the paused winner even if an assertion below
        // fails early, so this test can never hang the suite. A duplicate
        // signal alongside the explicit one further down is harmless.
        defer { releaseWinner.signal() }
        session.finishTeardownPauseHook = {
            winnerPaused.signal()
            releaseWinner.wait()
        }

        // WINNER: a real internal trigger (transport close).
        let winnerDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            transport.emitClose(nil)
            winnerDone.signal()
        }
        XCTAssertEqual(winnerPaused.wait(timeout: .now() + 5), .success,
                       "the winner must reach the pause point: stopped claimed, teardown-complete not yet signaled")

        // LOSER: a DIFFERENT internal trigger, on a DIFFERENT thread.
        let loserStarted = DispatchSemaphore(value: 0)
        let loserDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            loserStarted.signal()
            session.handleProcessExit(exitCode: 1)
            loserDone.signal()
        }
        XCTAssertEqual(loserStarted.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(loserDone.wait(timeout: .now() + 0.5), .success,
                       "an internal loser on a DIFFERENT thread must return immediately, before the winner's teardown-complete signal — it must never wait like the public stop() loser does")

        releaseWinner.signal()
        XCTAssertEqual(winnerDone.wait(timeout: .now() + 5), .success)

        let captured = controls.snapshot()
        guard captured.count == 1, case .ownerDisconnected(let reason, let time) = captured[0] else {
            return XCTFail("expected exactly one ownerDisconnected, got \(captured)")
        }
        XCTAssertEqual(reason, .transportClosed, "the WINNER's reason (transport close) must be recorded — the loser (process exit) must not have raced ahead or contributed its own")
        XCTAssertEqual(time, "2026-06-07T00:00:00.000Z")
    }

    // P0: Runtime D — stopped-first subscription fence. All three
    // subscription entry points (`ensureThreadSubscription`/
    // `setRegistryRootThreadID` behind the shared `beginSubscriptionAttempt`
    // stopped check; `refreshActiveThread` behind `canRefreshActiveThread`;
    // and the late `thread/loaded/list` handler behind
    // `sendThreadResumeForSubscriptionIfNeeded`) must send ZERO wire
    // traffic once `stopped` has been claimed — even though `connection` is
    // still open at that point (`finishTeardownPauseHook` fires strictly
    // before `initialization.fail`/`connection.close()`). Each row uses a
    // fresh session/collector, a REAL background internal winner
    // (`transport.emitClose(nil)`) paused mid-teardown via the hook, and a
    // `defer` safety release so an early assertion failure can never hang
    // the suite.
    func testStoppedFirstSubscriptionFenceMatrix() throws {
        // D1: starting from `.failed` (a GENERIC resume failure, not the
        // -32600/"no rollout found" pair, so no backoff is scheduled) —
        // `ensureThreadSubscription()` and `setRegistryRootThreadID()` must
        // both send 0 wire traffic once stopped. Deliberately NOT starting
        // from `.resumePending`: removing the stopped gate wouldn't send
        // from `.resumePending` either (a request is already in flight, so
        // `beginSubscriptionAttempt`'s `shouldRetry` check alone would
        // already decline) — that starting state would false-green even a
        // fully-removed stopped fence. `.failed` genuinely passes every
        // other `beginSubscriptionAttempt` guard, isolating the stopped
        // check as the only thing standing in the way.
        do {
            let controls = ControlCollector()
            let (session, transport, resumeID) = try Self.attachSessionWithPendingResume(controls: controls)

            transport.emitLine(try Self.errorResponseText(id: resumeID, code: -32000, message: "boom"))

            // Precondition, observed (not assumed from comments): the
            // generic failure genuinely landed in `.failed` with no
            // backoff — NOT left in `.resumePending` (which would already
            // send nothing regardless of the stopped fence) and NOT
            // carrying a `nextSubscriptionRetryAt` (which would also
            // suppress the send for an unrelated reason).
            let precondition = session.subscriptionDiagnosticSnapshotForTesting()
            XCTAssertEqual(precondition.state, .failed("thread_resume_failed"),
                           "D1 precondition: the generic resume failure must land in .failed, not .resumePending or any other state")
            XCTAssertNil(precondition.nextRetryAt, "D1 precondition: a generic failure must not schedule a no-rollout backoff")

            let winnerPaused = DispatchSemaphore(value: 0)
            let releaseWinner = DispatchSemaphore(value: 0)
            defer { releaseWinner.signal() }
            session.finishTeardownPauseHook = {
                winnerPaused.signal()
                releaseWinner.wait()
            }
            let winnerDone = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                transport.emitClose(nil)
                winnerDone.signal()
            }
            XCTAssertEqual(winnerPaused.wait(timeout: .now() + 5), .success,
                           "D1: winner must reach the pause point: stopped claimed, connection still open")

            let baseline = transport.sentLines()
            session.ensureThreadSubscription()
            XCTAssertEqual(transport.sentLines(), baseline, "D1: ensureThreadSubscription() must send 0 wire traffic once stopped")

            session.setRegistryRootThreadID("thread-late")
            XCTAssertEqual(transport.sentLines(), baseline, "D1: setRegistryRootThreadID() must send 0 wire traffic once stopped")
            session.setRegistryRootThreadID("thread-late")
            XCTAssertEqual(transport.sentLines(), baseline, "D1: setRegistryRootThreadID() must remain 0 wire traffic across repeated calls")

            releaseWinner.signal()
            XCTAssertEqual(winnerDone.wait(timeout: .now() + 5), .success)
        }

        // D2: starting from `.subscribed(thread-a)` (an exact SUCCESS
        // response, so production genuinely reaches `.subscribed`) —
        // `refreshActiveThread()` must send 0 wire traffic once stopped.
        // Must first genuinely reach `.subscribed`: a refresh attempted from
        // `.failed`/`.noLoadedThread` already sends nothing regardless of
        // the stopped fence, which would false-green a removed fence here.
        do {
            let controls = ControlCollector()
            let (session, transport, resumeID) = try Self.attachSessionWithPendingResume(controls: controls)

            transport.emitLine(try Self.responseText(id: resumeID,
                                                      result: Self.inProgressResumeResult(threadID: "thread-a", turnID: "turn-1")))

            // Precondition, observed: the exact success response genuinely
            // reached `.subscribed(thread-a)` — a refresh attempted from
            // `.failed`/`.noLoadedThread`/`.resumePending` already sends
            // nothing regardless of the stopped fence, which would
            // false-green a removed fence here.
            let precondition = session.subscriptionDiagnosticSnapshotForTesting()
            XCTAssertEqual(precondition.state, .subscribed(threadID: "thread-a"),
                           "D2 precondition: the exact success response must land in .subscribed(thread-a)")
            XCTAssertNil(precondition.nextRetryAt, "D2 precondition: a successful subscribe must not carry a stale backoff")

            let winnerPaused = DispatchSemaphore(value: 0)
            let releaseWinner = DispatchSemaphore(value: 0)
            defer { releaseWinner.signal() }
            session.finishTeardownPauseHook = {
                winnerPaused.signal()
                releaseWinner.wait()
            }
            let winnerDone = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                transport.emitClose(nil)
                winnerDone.signal()
            }
            XCTAssertEqual(winnerPaused.wait(timeout: .now() + 5), .success,
                           "D2: winner must reach the pause point: stopped claimed, connection still open")

            let baseline = transport.sentLines()
            session.refreshActiveThread()
            XCTAssertEqual(transport.sentLines(), baseline, "D2: refreshActiveThread() must send 0 wire traffic once stopped")

            releaseWinner.signal()
            XCTAssertEqual(winnerDone.wait(timeout: .now() + 5), .success)
        }

        // D3: a late `thread/loaded/list` response arrives AFTER stopped is
        // claimed. The handler must still run to genuine completion
        // (forwarding `onActiveThreadID`, per `activeThreadStore.setThreadID`'s
        // synchronous callback) while sending 0 late `thread/resume` wire
        // traffic. `loadedThreadSubscriptionResultProcessedHook` fires on
        // `callbackQueue`, holding no lock, strictly AFTER
        // `handleLoadedThreadSubscriptionResult` returns — proving the
        // WHOLE handler (including any resume send it would otherwise
        // issue) has genuinely finished. Snapshotting right after
        // `onActiveThreadID` alone would be a false-green window: that
        // callback fires synchronously mid-handler, BEFORE
        // `sendThreadResumeForSubscriptionIfNeeded` is even called.
        do {
            let controls = ControlCollector()
            let runner = FakeCodexAppServerProcessRunner()
            let connector = FakeCodexAppServerTransportConnector()
            let factory = CodexAppServerRuntimeSessionFactory(processRunner: runner, transportConnector: connector)
            let observedThreadIDsLock = NSLock()
            var observedThreadIDs: [String] = []
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
                                             onActiveThreadID: { threadID in
                                                 observedThreadIDsLock.lock()
                                                 observedThreadIDs.append(threadID)
                                                 observedThreadIDsLock.unlock()
                                             },
                                             onWorkingControl: { controls.append($0) })
            let transport = try XCTUnwrap(connector.transport)
            try Self.acknowledgeInitialize(from: transport)

            // The auto-sent `thread/loaded/list` request stays pending — no
            // response yet.
            let listLoaded = try Self.object(from: try XCTUnwrap(transport.sentLines().dropFirst(2).first))
            XCTAssertEqual(listLoaded["method"]?.stringValue, "thread/loaded/list")
            let listLoadedID = try XCTUnwrap(listLoaded["id"])

            let winnerPaused = DispatchSemaphore(value: 0)
            let releaseWinner = DispatchSemaphore(value: 0)
            defer { releaseWinner.signal() }
            session.finishTeardownPauseHook = {
                winnerPaused.signal()
                releaseWinner.wait()
            }
            let winnerDone = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                transport.emitClose(nil)
                winnerDone.signal()
            }
            XCTAssertEqual(winnerPaused.wait(timeout: .now() + 5), .success,
                           "D3: winner must reach the pause point: stopped claimed, connection still open")

            let baseline = transport.sentLines()

            let processed = DispatchSemaphore(value: 0)
            session.setLoadedThreadSubscriptionResultProcessedHookForTesting {
                processed.signal()
            }
            transport.emitLine(try Self.responseText(id: listLoadedID, result: .object([
                "threads": .array([
                    .object(["id": .string("thread-late"), "preview": .string("p"), "updatedAt": .string("2026-06-07T00:00:00.000Z")]),
                ]),
            ])))

            XCTAssertEqual(processed.wait(timeout: .now() + 5), .success,
                           "D3: the late loaded/list handler must genuinely run to completion")

            observedThreadIDsLock.lock()
            let finalObserved = observedThreadIDs
            observedThreadIDsLock.unlock()
            XCTAssertEqual(finalObserved, ["thread-late"], "D3: onActiveThreadID must still forward the resolved thread")

            XCTAssertEqual(transport.sentLines(), baseline, "D3: 0 late thread/resume must be sent once stopped — the handler completing is not license to send")

            releaseWinner.signal()
            XCTAssertEqual(winnerDone.wait(timeout: .now() + 5), .success)
        }
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

    private static func waitFor(timeout: TimeInterval = 2.0,
                                _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return true
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return condition()
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

final class FakeCodexAppServerTransportConnector: CodexAppServerTransportConnecting {
    private(set) var connectedModes: [CodexAppServerTransportMode] = []
    private(set) var transport: FakeCodexAppServerConnectionTransport?
    var configureTransport: ((FakeCodexAppServerConnectionTransport) -> Void)?

    func connect(mode: CodexAppServerTransportMode,
                 onLine: @escaping @Sendable (String) -> Void,
                 onClose: @escaping @Sendable (Error?) -> Void) throws -> CodexAppServerConnectionTransport {
        connectedModes.append(mode)
        let transport = FakeCodexAppServerConnectionTransport(onLine: onLine,
                                                              onClose: onClose)
        configureTransport?(transport)
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

    var sendLineError: Error?

    func sendLine(_ line: String) throws {
        if let sendLineError {
            throw sendLineError
        }
        lock.lock()
        lines.append(line)
        lock.unlock()
    }

    private(set) var closeCallCount = 0

    func close() {
        lock.lock()
        closed = true
        closeCallCount += 1
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
    var configureProcess: ((FakeCodexAppServerManagedProcess) -> Void)?

    func start(configuration: CodexAppServerLaunchConfiguration,
               onStdoutLine: @escaping @Sendable (String) -> Void,
               onStderrLine: @escaping @Sendable (String) -> Void,
               onExit: @escaping @Sendable (Int32) -> Void) throws -> CodexAppServerManagedProcess {
        startedConfigurations.append(configuration)
        let process = FakeCodexAppServerManagedProcess(onStdoutLine: onStdoutLine,
                                                       onStderrLine: onStderrLine,
                                                       onExit: onExit)
        configureProcess?(process)
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
    private(set) var terminateCallCount = 0

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

    var sendLineError: Error?

    func sendLine(_ line: String) throws {
        if let sendLineError {
            throw sendLineError
        }
        lock.lock()
        lines.append(line)
        lock.unlock()
    }

    func terminate() {
        didTerminate = true
        terminateCallCount += 1
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
