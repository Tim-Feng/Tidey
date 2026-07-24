import XCTest
@testable import RemoteBridge

// Codex 0.144.1 `item/tool/requestUserInput` contract + root-gated
// three-state lifecycle wiring (thread/resume snapshot, child filtering,
// order fence, blocker open/resolve) — production path from fake transport
// through CodexAppServerConnection / HeadlessRuntime / RuntimeSessionFactory
// into AgentSessionLifecycleStore.
final class CodexUserInputLifecycleTests: XCTestCase {

    // MARK: - requestUserInput connection contract

    func testRequestUserInputPublishesCardAndAnswersSubmitMatchesContractWire() throws {
        let harness = ConnectionHarness()

        harness.connection.receiveLine("""
        {"id":"ask-17","method":"item/tool/requestUserInput","params":{"threadId":"thread-root","turnId":"turn-9","itemId":"item-ask-1","autoResolutionMs":null,"questions":[{"id":"deploy_target","header":"Deploy","question":"要部署哪個環境？","isOther":false,"isSecret":false,"options":[{"label":"Staging","description":"部署測試環境。"},{"label":"Production","description":"部署正式環境。"}]},{"id":"note","header":"Note","question":"補充說明","isOther":true,"isSecret":false,"options":null}]}}
        """)

        let envelope = try XCTUnwrap(harness.prompts.last)
        XCTAssertEqual(envelope.prompt.source, "codex_user_input_request")
        XCTAssertEqual(envelope.request.method, .requestUserInput)
        XCTAssertEqual(envelope.prompt.questions?.arrayValue?.count, 2)
        // Multi-question card: no index options, answers-map submit only.
        XCTAssertTrue(envelope.prompt.options.isEmpty)
        // No error frame was written for the supported request.
        XCTAssertTrue(harness.outbound.lines().isEmpty)

        let outcome = try harness.connection.submitUserInput(promptID: envelope.prompt.promptID,
                                                             answers: [
                                                                "deploy_target": ["Staging"],
                                                                "note": ["先驗證 migration"],
                                                             ],
                                                             clientRequestID: "client-1",
                                                             lifecycleToken: envelope.event.eventID)
        guard case .pendingConfirmation = outcome else {
            return XCTFail("answers flush must stay pending until serverRequest/resolved")
        }

        // Exact contract wire shape, string id kept quoted.
        let line = try XCTUnwrap(harness.outbound.lines().last)
        XCTAssertTrue(line.contains(#""id":"ask-17""#))
        let response = try Self.object(from: line)
        let answers = try XCTUnwrap(response["result"]?.objectValue?["answers"]?.objectValue)
        XCTAssertEqual(answers.count, 2)
        XCTAssertEqual(answers["deploy_target"]?.objectValue?["answers"]?.arrayValue?.compactMap(\.stringValue),
                       ["Staging"])
        XCTAssertEqual(answers["note"]?.objectValue?["answers"]?.arrayValue?.compactMap(\.stringValue),
                       ["先驗證 migration"])
        // Flush is NOT a resolution.
        XCTAssertTrue(harness.resolved.isEmpty)

        harness.connection.receiveLine(#"{"method":"serverRequest/resolved","params":{"threadId":"thread-root","requestId":"ask-17"}}"#)
        XCTAssertEqual(harness.resolved.count, 1)
        XCTAssertEqual(harness.resolved.first?.type, .interactivePromptResolved)
    }

    // Official 0.144.1 semantics (submit_answers in the Rust TUI): EVERY
    // question gets an entry in the response, even an empty array for a
    // question the user explicitly left unanswered — only an UNKNOWN
    // question id is rejected, never a present-but-empty one.
    func testRequestUserInputSubmitIncludesEmptyArrayForUnansweredQuestionRatherThanRejecting() throws {
        let harness = ConnectionHarness()

        harness.connection.receiveLine("""
        {"id":"ask-18","method":"item/tool/requestUserInput","params":{"threadId":"thread-root","turnId":"turn-9","itemId":"item-ask-2","questions":[{"id":"q1","header":"Q1","question":"first"},{"id":"q2","header":"Q2","question":"second"}]}}
        """)
        let envelope = try XCTUnwrap(harness.prompts.last)

        let outcome = try harness.connection.submitUserInput(promptID: envelope.prompt.promptID,
                                                             answers: ["q1": ["answered"]],
                                                             clientRequestID: "client-unanswered",
                                                             lifecycleToken: envelope.event.eventID)
        guard case .pendingConfirmation = outcome else {
            return XCTFail("a present-but-partial answers map must flush, not be rejected")
        }

        let line = try XCTUnwrap(harness.outbound.lines().last)
        let response = try Self.object(from: line)
        let answers = try XCTUnwrap(response["result"]?.objectValue?["answers"]?.objectValue)
        XCTAssertEqual(answers.count, 2, "every question must have an entry, even an unanswered one")
        XCTAssertEqual(answers["q1"]?.objectValue?["answers"]?.arrayValue?.compactMap(\.stringValue), ["answered"])
        XCTAssertEqual(answers["q2"]?.objectValue?["answers"]?.arrayValue, [],
                       "an unanswered question gets an explicit empty array, not a rejection")
    }

    func testRequestUserInputSingleOptionQuestionSubmitsByIndexWithContractShape() throws {
        let harness = ConnectionHarness()

        harness.connection.receiveLine("""
        {"id":7,"method":"item/tool/requestUserInput","params":{"threadId":"thread-root","turnId":"turn-9","itemId":"item-ask-2","questions":[{"id":"deploy_target","header":"Deploy","question":"要部署哪個環境？","options":[{"label":"Staging","description":"部署測試環境。"},{"label":"Production","description":"部署正式環境。"}]}]}}
        """)

        let envelope = try XCTUnwrap(harness.prompts.last)
        XCTAssertEqual(envelope.prompt.options.map(\.label), ["Staging", "Production"])

        _ = try harness.connection.submitApproval(promptID: envelope.prompt.promptID,
                                                  targetIndex: 1,
                                                  clientRequestID: "client-2",
                                                  lifecycleToken: envelope.event.eventID)

        let line = try XCTUnwrap(harness.outbound.lines().last)
        // Integer id echoed as an integer token.
        XCTAssertTrue(line.contains(#""id":7,"#) || line.hasPrefix(#"{"id":7"#))
        let response = try Self.object(from: line)
        let answers = try XCTUnwrap(response["result"]?.objectValue?["answers"]?.objectValue)
        XCTAssertEqual(answers["deploy_target"]?.objectValue?["answers"]?.arrayValue?.compactMap(\.stringValue),
                       ["Production"])
    }

    func testRequestUserInputInt64RequestIDEchoedBitExact() throws {
        let harness = ConnectionHarness()

        harness.connection.receiveLine("""
        {"id":9223372036854775807,"method":"item/tool/requestUserInput","params":{"threadId":"thread-root","turnId":"turn-9","itemId":"item-ask-3","questions":[{"id":"note","header":"Note","question":"補充說明","isOther":true,"options":null}]}}
        """)

        let envelope = try XCTUnwrap(harness.prompts.last)
        _ = try harness.connection.submitUserInput(promptID: envelope.prompt.promptID,
                                                   answers: ["note": ["ok"]],
                                                   clientRequestID: nil,
                                                   lifecycleToken: envelope.event.eventID)

        let line = try XCTUnwrap(harness.outbound.lines().last)
        XCTAssertTrue(line.contains(#""id":9223372036854775807"#),
                      "int64 RequestId must be echoed bit-exact, got: \(line)")
    }

    func testTypedRequestIDsStayDistinctAndResolveIndividually() throws {
        let harness = ConnectionHarness()

        // Integer 1 and string "1" on the same thread are DIFFERENT requests.
        harness.connection.receiveLine("""
        {"id":1,"method":"item/tool/requestUserInput","params":{"threadId":"thread-root","turnId":"turn-9","itemId":"item-int","questions":[{"id":"q1","header":"Q1","question":"int-id question"}]}}
        """)
        harness.connection.receiveLine("""
        {"id":"1","method":"item/tool/requestUserInput","params":{"threadId":"thread-root","turnId":"turn-9","itemId":"item-str","questions":[{"id":"q2","header":"Q2","question":"string-id question"}]}}
        """)
        XCTAssertEqual(harness.prompts.count, 2)
        XCTAssertEqual(harness.connection.pendingApprovalPromptEvents().count, 2)

        // Same requestId on a DIFFERENT thread must not resolve anything.
        harness.connection.receiveLine(#"{"method":"serverRequest/resolved","params":{"threadId":"thread-other","requestId":1}}"#)
        XCTAssertTrue(harness.resolved.isEmpty)

        // Integer 1 resolves only the integer request.
        harness.connection.receiveLine(#"{"method":"serverRequest/resolved","params":{"threadId":"thread-root","requestId":1}}"#)
        XCTAssertEqual(harness.resolved.count, 1)
        XCTAssertEqual(harness.resolved.first?.metadata?["item_id"], "item-int")
        XCTAssertEqual(harness.connection.pendingApprovalPromptEvents().count, 1)

        // String "1" resolves the remaining request.
        harness.connection.receiveLine(#"{"method":"serverRequest/resolved","params":{"threadId":"thread-root","requestId":"1"}}"#)
        XCTAssertEqual(harness.resolved.count, 2)
        XCTAssertEqual(harness.connection.pendingApprovalPromptEvents().count, 0)
    }

    func testLateSubmitAfterServerResolvedReturnsTerminalWithoutSecondResponse() throws {
        let harness = ConnectionHarness()

        harness.connection.receiveLine("""
        {"id":"ask-auto","method":"item/tool/requestUserInput","params":{"threadId":"thread-root","turnId":"turn-9","itemId":"item-auto","autoResolutionMs":50,"questions":[{"id":"note","header":"Note","question":"補充說明","isOther":true}]}}
        """)
        let envelope = try XCTUnwrap(harness.prompts.last)

        // autoResolution fired server-side: resolved arrives with no submit.
        harness.connection.receiveLine(#"{"method":"serverRequest/resolved","params":{"threadId":"thread-root","requestId":"ask-auto"}}"#)
        XCTAssertEqual(harness.resolved.count, 1)

        let linesBefore = harness.outbound.lines().count
        let outcome = try harness.connection.submitUserInput(promptID: envelope.prompt.promptID,
                                                             answers: ["note": ["late"]],
                                                             clientRequestID: nil,
                                                             lifecycleToken: envelope.event.eventID)
        guard case .alreadyResolved = outcome else {
            return XCTFail("late submit after resolution must return the terminal record")
        }
        // Zero additional bytes: no second response for the request id.
        XCTAssertEqual(harness.outbound.lines().count, linesBefore)
    }

    // MARK: - Production wiring: resume snapshot, root gate, order fence

    func testAttachedRuntimeAppliesResumeSnapshotToLifecycleStore() throws {
        let harness = try WiringHarness(sessionID: "session-wire-snapshot")
        try harness.bindRoot()

        // Contract: status lives at result.thread.status; excludeTurns does
        // not affect it. No follow-up notification is needed.
        harness.respondToResume(status: #"{"type":"active","activeFlags":["waitingOnApproval"]}"#)

        let snapshot = try XCTUnwrap(AgentSessionLifecycle.store.snapshot(harness.identity))
        XCTAssertEqual(snapshot.state, .needsInput)

        // A later read-style snapshot mapping to idle applies too.
        harness.emitRootStatus(#"{"type":"idle"}"#)
        XCTAssertEqual(AgentSessionLifecycle.store.snapshot(harness.identity)?.state, .idle)
    }

    func testChildStatusNotificationCannotChangeRootLifecycle() throws {
        let harness = try WiringHarness(sessionID: "session-wire-child")
        try harness.bindRoot()
        harness.respondToResume(status: #"{"type":"idle"}"#)
        XCTAssertEqual(AgentSessionLifecycle.store.snapshot(harness.identity)?.state, .idle)

        // Child thread shares the sessionId world but must never modify the
        // root panel (thread/status/changed carries no parent metadata; the
        // authoritative root binding is the only filter).
        harness.transport.emitLine(#"{"method":"thread/status/changed","params":{"threadId":"thread-child","status":{"type":"active","activeFlags":["waitingOnApproval"]}}}"#)
        XCTAssertEqual(AgentSessionLifecycle.store.snapshot(harness.identity)?.state, .idle)

        // Root status still flows.
        harness.emitRootStatus(#"{"type":"active","activeFlags":[]}"#)
        XCTAssertEqual(AgentSessionLifecycle.store.snapshot(harness.identity)?.state, .working)

        // Malformed active (missing activeFlags) must not clear anything.
        harness.emitRootStatus(#"{"type":"active"}"#)
        XCTAssertEqual(AgentSessionLifecycle.store.snapshot(harness.identity)?.state, .working)
    }

    // Round2c P0-2: barrier-check + counter-increment + store-apply are ONE
    // atomic critical section now (a prior two-lock version left a TOCTOU
    // window between the barrier check and the store mutation). Heavy
    // concurrent contention between "live notifications" (unconditional)
    // and "stale snapshot responses" (barrier-gated) must never crash and
    // must always leave the store in a state some ACTUAL call produced —
    // never a corrupted/interleaved half-application.
    func testConcurrentSnapshotAndNotificationRaceNeverCorruptsState() throws {
        let harness = try WiringHarness(sessionID: "session-wire-race")
        try harness.bindRoot()
        harness.respondToResume(status: #"{"type":"idle"}"#)

        let group = DispatchGroup()
        let queue = DispatchQueue(label: "codex-race", attributes: .concurrent)
        for round in 0..<200 {
            group.enter()
            queue.async {
                defer { group.leave() }
                if round % 2 == 0 {
                    harness.emitRootStatus(#"{"type":"active","activeFlags":["waitingOnApproval"]}"#)
                } else {
                    harness.emitRootStatus(#"{"type":"idle"}"#)
                }
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 20), .success)

        // Final state must be one of the two ACTUAL values applied — never
        // an impossible third state, and the store must not have crashed.
        let finalState = AgentSessionLifecycle.store.snapshot(harness.identity)?.state
        XCTAssertTrue(finalState == .idle || finalState == .needsInput,
                      "race produced an impossible state: \(String(describing: finalState))")
    }

    func testStaleResumeResponseCannotRegressNewerStatusNotification() throws {
        let harness = try WiringHarness(sessionID: "session-wire-fence")
        try harness.bindRoot()

        // The resume request is on the wire; a NEWER live notification lands
        // before the (older) response snapshot.
        harness.emitRootStatus(#"{"type":"active","activeFlags":[]}"#)
        XCTAssertEqual(AgentSessionLifecycle.store.snapshot(harness.identity)?.state, .working)

        harness.respondToResume(status: #"{"type":"idle"}"#)
        XCTAssertEqual(AgentSessionLifecycle.store.snapshot(harness.identity)?.state, .working,
                       "an older resume snapshot must not roll back a newer live status")
    }

    func testSystemErrorSnapshotMapsToIdleButKeepsDetail() throws {
        let harness = try WiringHarness(sessionID: "session-wire-syserr")
        try harness.bindRoot()
        harness.respondToResume(status: #"{"type":"systemError"}"#)

        let snapshot = try XCTUnwrap(AgentSessionLifecycle.store.snapshot(harness.identity))
        XCTAssertEqual(snapshot.state, .idle)
        XCTAssertEqual(snapshot.detail, "systemError")
    }

    func testRootTurnStartedAndCompletedDriveLifecycle() throws {
        let harness = try WiringHarness(sessionID: "session-wire-turn")
        try harness.bindRoot()
        harness.respondToResume(status: #"{"type":"idle"}"#)

        harness.transport.emitLine(#"{"method":"turn/started","params":{"threadId":"thread-child","turn":{"id":"turn-child"}}}"#)
        XCTAssertEqual(AgentSessionLifecycle.store.snapshot(harness.identity)?.state, .idle)

        harness.transport.emitLine(#"{"method":"turn/started","params":{"threadId":"thread-root","turn":{"id":"turn-root"}}}"#)
        XCTAssertEqual(AgentSessionLifecycle.store.snapshot(harness.identity)?.state, .working)

        harness.transport.emitLine(#"{"method":"turn/completed","params":{"threadId":"thread-root","turn":{"id":"turn-root"}}}"#)
        XCTAssertEqual(AgentSessionLifecycle.store.snapshot(harness.identity)?.state, .idle)
    }

    func testRequestUserInputThroughWiringOpensAndResolvesNeedsInputBlocker() throws {
        let harness = try WiringHarness(sessionID: "session-wire-uinput")
        try harness.bindRoot()
        harness.respondToResume(status: #"{"type":"active","activeFlags":[]}"#)
        XCTAssertEqual(AgentSessionLifecycle.store.snapshot(harness.identity)?.state, .working)

        harness.transport.emitLine("""
        {"id":"ask-wire","method":"item/tool/requestUserInput","params":{"threadId":"thread-root","turnId":"turn-9","itemId":"item-wire","questions":[{"id":"note","header":"Note","question":"補充說明","isOther":true}]}}
        """)
        XCTAssertEqual(AgentSessionLifecycle.store.snapshot(harness.identity)?.state, .needsInput)

        // Resolution closes only the blocker; the still-active turn keeps
        // the session in working, not idle.
        harness.transport.emitLine(#"{"method":"serverRequest/resolved","params":{"threadId":"thread-root","requestId":"ask-wire"}}"#)
        XCTAssertEqual(AgentSessionLifecycle.store.snapshot(harness.identity)?.state, .working)

        harness.emitRootStatus(#"{"type":"idle"}"#)
        XCTAssertEqual(AgentSessionLifecycle.store.snapshot(harness.identity)?.state, .idle)
    }

    // Codex production review P0-3: a provider-level "fully idle" (or ANY
    // stale/late status) must NEVER clear an explicit requestUserInput/
    // approval blocker — that lifecycle belongs to its own namespace and is
    // resolved ONLY by serverRequest/resolved, a turn terminal, or expiry.
    func testProviderIdleCannotClearAPendingExplicitPromptBlocker() throws {
        let harness = try WiringHarness(sessionID: "session-wire-prompt-vs-idle")
        try harness.bindRoot()
        harness.respondToResume(status: #"{"type":"active","activeFlags":[]}"#)
        XCTAssertEqual(AgentSessionLifecycle.store.snapshot(harness.identity)?.state, .working)

        harness.transport.emitLine("""
        {"id":"ask-persist","method":"item/tool/requestUserInput","params":{"threadId":"thread-root","turnId":"turn-9","itemId":"item-persist","questions":[{"id":"note","header":"Note","question":"補充說明","isOther":true}]}}
        """)
        XCTAssertEqual(AgentSessionLifecycle.store.snapshot(harness.identity)?.state, .needsInput)

        // A provider "idle" status arrives WHILE the card is still pending
        // (no serverRequest/resolved yet) — this must NOT clear the
        // explicit blocker; the card is still legitimately open.
        harness.emitRootStatus(#"{"type":"idle"}"#)
        XCTAssertEqual(AgentSessionLifecycle.store.snapshot(harness.identity)?.state, .needsInput,
                       "provider idle cleared a pending explicit prompt blocker")
        let survivingBlockers = AgentSessionLifecycle.store.snapshot(harness.identity)?.blockerIDs ?? []
        XCTAssertEqual(survivingBlockers.count, 1)
        XCTAssertTrue(survivingBlockers.first?.hasPrefix("codex-prompt:") == true)

        // Only the authoritative resolution actually closes it.
        harness.transport.emitLine(#"{"method":"serverRequest/resolved","params":{"threadId":"thread-root","requestId":"ask-persist"}}"#)
        XCTAssertEqual(AgentSessionLifecycle.store.snapshot(harness.identity)?.state, .idle)
    }

    func testStopRetiresLifecycleIdentity() throws {
        let harness = try WiringHarness(sessionID: "session-wire-stop")
        try harness.bindRoot()
        harness.respondToResume(status: #"{"type":"active","activeFlags":["waitingOnUserInput"]}"#)
        XCTAssertEqual(AgentSessionLifecycle.store.snapshot(harness.identity)?.state, .needsInput)

        harness.session.stop()

        let snapshot = try XCTUnwrap(AgentSessionLifecycle.store.snapshot(harness.identity))
        XCTAssertEqual(snapshot.state, .idle)
        XCTAssertTrue(snapshot.ended)
        // Retired identities vanish from the aggregate (no ghost state).
        XCTAssertNil(AgentSessionLifecycle.store.panelAggregate(workspaceID: harness.identity.workspaceID,
                                                                panelID: harness.identity.panelID))

        // Late events of the retired generation cannot revive it.
        harness.emitRootStatus(#"{"type":"active","activeFlags":[]}"#)
        XCTAssertEqual(AgentSessionLifecycle.store.snapshot(harness.identity)?.state, .idle)
    }

    func testLoadedListSelectsRootAndNeverBindsChildOnly() throws {
        func loadedThreadID(_ threads: [JSONValue]) -> String? {
            codexAppServerLoadedThreadID(from: .object(["threads": .array(threads)]))
        }

        let root = JSONValue.object(["id": .string("thread-root"), "parentThreadId": .null])
        let child = JSONValue.object([
            "id": .string("thread-child"),
            "parentThreadId": .string("thread-root"),
            "agentNickname": .string("reviewer"),
        ])
        // root + child selects the root (same sessionId world).
        XCTAssertEqual(loadedThreadID([root, child]), "thread-root")
        // child-only never binds a root.
        XCTAssertNil(loadedThreadID([child]))
        // subAgent source shape marks a child too.
        let sourceChild = JSONValue.object([
            "id": .string("thread-child-2"),
            "source": .object(["subAgent": .object(["thread_spawn": .object([:])])]),
        ])
        XCTAssertNil(loadedThreadID([sourceChild]))
    }

    // MARK: - Harnesses

    private final class ConnectionHarness {
        let outbound = TestLineSink()
        private(set) var prompts: [CodexAppServerInteractivePromptEnvelope] = []
        private(set) var resolved: [AgentEvent] = []
        private(set) var connection: CodexAppServerConnection!

        init() {
            var seq = 0
            connection = CodexAppServerConnection(
                sendLine: { [outbound] in outbound.append($0) },
                approvalContext: CodexAppServerApprovalContext(workspaceID: "workspace-uinput",
                                                               panelID: "panel-uinput",
                                                               sessionID: "session-uinput",
                                                               epoch: "pid:1|sock:/tmp/uinput.sock"),
                nextSequence: { _ in
                    seq += 1
                    return seq
                },
                timestampProvider: { "2026-07-18T00:00:00.000Z" },
                onInteractivePrompt: { [weak self] in self?.prompts.append($0) },
                onInteractivePromptResolved: { [weak self] in self?.resolved.append($0) })
        }
    }

    private final class WiringHarness {
        let identity: AgentSessionLifecycleIdentity
        let session: CodexAppServerRuntimeSession
        let transport: FakeCodexAppServerConnectionTransport
        private var resumeResponseID: JSONValue?

        init(sessionID: String) throws {
            let runner = FakeCodexAppServerProcessRunner()
            let connector = FakeCodexAppServerTransportConnector()
            let factory = CodexAppServerRuntimeSessionFactory(processRunner: runner,
                                                              transportConnector: connector)
            identity = AgentSessionLifecycleIdentity(workspaceID: "workspace-\(sessionID)",
                                                     panelID: "panel-\(sessionID)",
                                                     sessionID: sessionID)
            var seq = 0
            session = try factory.attach(socketPath: "/tmp/tidey-\(sessionID)/app.sock",
                                         processID: 9001,
                                         context: CodexAppServerRuntimeContext(workspaceID: identity.workspaceID,
                                                                               panelID: identity.panelID,
                                                                               sessionID: sessionID),
                                         nextSequence: { _ in
                                             seq += 1
                                             return seq
                                         },
                                         timestampProvider: { "2026-07-18T00:00:00.000Z" },
                                         onAgentEvent: { _ in },
                                         onInteractivePrompt: { _ in },
                                         onInteractivePromptResolved: { _ in })
            transport = try XCTUnwrap(connector.transport)
        }

        // initialize -> initialized -> loaded/list(thread-root) -> resume
        // request on the wire (response NOT yet delivered).
        func bindRoot() throws {
            let initialize = try CodexUserInputLifecycleTests.object(from: try XCTUnwrap(transport.sentLines().first))
            let initializeID = try XCTUnwrap(initialize["id"])
            transport.emitLine(try Self.responseText(id: initializeID, result: .object([
                "serverInfo": .object(["name": .string("codex"), "version": .string("test")]),
                "capabilities": .object([:]),
            ])))
            XCTAssertTrue(Self.waitForSentLineCount(3, transport: transport))
            let listLoaded = try CodexUserInputLifecycleTests.object(from: try XCTUnwrap(transport.sentLines().dropFirst(2).first))
            XCTAssertEqual(listLoaded["method"]?.stringValue, "thread/loaded/list")
            transport.emitLine(try Self.responseText(id: try XCTUnwrap(listLoaded["id"]), result: .object([
                "threads": .array([
                    .object(["id": .string("thread-root"), "preview": .string("root")]),
                ]),
            ])))
            XCTAssertTrue(Self.waitForSentLineCount(4, transport: transport))
            let resume = try CodexUserInputLifecycleTests.object(from: try XCTUnwrap(transport.sentLines().dropFirst(3).first))
            XCTAssertEqual(resume["method"]?.stringValue, "thread/resume")
            resumeResponseID = resume["id"]
        }

        func respondToResume(status: String) {
            guard let resumeResponseID,
                  let idData = try? JSONEncoder().encode(resumeResponseID) else {
                return XCTFail("resume request id missing")
            }
            let idText = String(decoding: idData, as: UTF8.self)
            transport.emitLine("""
            {"id":\(idText),"result":{"thread":{"id":"thread-root","sessionId":"session-tree-1","parentThreadId":null,"status":\(status),"turns":[]},"model":"gpt-5.4","modelProvider":"openai"}}
            """)
        }

        func emitRootStatus(_ status: String) {
            transport.emitLine(#"{"method":"thread/status/changed","params":{"threadId":"thread-root","status":\#(status)}}"#)
        }

        private static func responseText(id: JSONValue, result: JSONValue) throws -> String {
            let idData = try JSONEncoder().encode(id)
            let resultData = try JSONEncoder().encode(result)
            return #"{"id":\#(String(decoding: idData, as: UTF8.self)),"result":\#(String(decoding: resultData, as: UTF8.self))}"#
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

private final class TestLineSink: @unchecked Sendable {
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
