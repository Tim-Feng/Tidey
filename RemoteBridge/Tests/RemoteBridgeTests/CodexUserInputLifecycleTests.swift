import XCTest
@testable import RemoteBridge

// Root-gated three-state lifecycle wiring from fake app-server transport
// through RuntimeSessionFactory into AgentSessionLifecycleStore.
final class CodexUserInputLifecycleTests: XCTestCase {
    func testAttachedRuntimeAppliesResumeSnapshotToLifecycleStore() throws {
        let harness = try WiringHarness(sessionID: "session-wire-snapshot")
        try harness.bindRoot()

        harness.respondToResume(status: #"{"type":"active","activeFlags":["waitingOnApproval"]}"#)

        let snapshot = try XCTUnwrap(AgentSessionLifecycle.store.snapshot(harness.identity))
        XCTAssertEqual(snapshot.state, .needsInput)

        harness.emitRootStatus(#"{"type":"idle"}"#)
        XCTAssertEqual(AgentSessionLifecycle.store.snapshot(harness.identity)?.state, .idle)
    }

    func testChildStatusNotificationCannotChangeRootLifecycle() throws {
        let harness = try WiringHarness(sessionID: "session-wire-child")
        try harness.bindRoot()
        harness.respondToResume(status: #"{"type":"idle"}"#)
        XCTAssertEqual(AgentSessionLifecycle.store.snapshot(harness.identity)?.state, .idle)

        harness.transport.emitLine(#"{"method":"thread/status/changed","params":{"threadId":"thread-child","status":{"type":"active","activeFlags":["waitingOnApproval"]}}}"#)
        XCTAssertEqual(AgentSessionLifecycle.store.snapshot(harness.identity)?.state, .idle)

        harness.emitRootStatus(#"{"type":"active","activeFlags":[]}"#)
        XCTAssertEqual(AgentSessionLifecycle.store.snapshot(harness.identity)?.state, .working)

        harness.emitRootStatus(#"{"type":"active"}"#)
        XCTAssertEqual(AgentSessionLifecycle.store.snapshot(harness.identity)?.state, .working)
    }

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

        let finalState = AgentSessionLifecycle.store.snapshot(harness.identity)?.state
        XCTAssertTrue(finalState == .idle || finalState == .needsInput,
                      "race produced an impossible state: \(String(describing: finalState))")
    }

    func testStaleResumeResponseCannotRegressNewerStatusNotification() throws {
        let harness = try WiringHarness(sessionID: "session-wire-fence")
        try harness.bindRoot()

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

    func testStopRetiresLifecycleIdentity() throws {
        let harness = try WiringHarness(sessionID: "session-wire-stop")
        try harness.bindRoot()
        harness.respondToResume(status: #"{"type":"active","activeFlags":["waitingOnUserInput"]}"#)
        XCTAssertEqual(AgentSessionLifecycle.store.snapshot(harness.identity)?.state, .needsInput)

        harness.session.stop()

        let snapshot = try XCTUnwrap(AgentSessionLifecycle.store.snapshot(harness.identity))
        XCTAssertEqual(snapshot.state, .idle)
        XCTAssertTrue(snapshot.ended)
        XCTAssertNil(AgentSessionLifecycle.store.panelAggregate(workspaceID: harness.identity.workspaceID,
                                                                panelID: harness.identity.panelID))

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
        XCTAssertEqual(loadedThreadID([root, child]), "thread-root")
        XCTAssertNil(loadedThreadID([child]))
        let sourceChild = JSONValue.object([
            "id": .string("thread-child-2"),
            "source": .object(["subAgent": .object(["thread_spawn": .object([:])])]),
        ])
        XCTAssertNil(loadedThreadID([sourceChild]))
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
