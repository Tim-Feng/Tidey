import XCTest
@testable import RemoteBridge

final class BridgeInputActionHandlerTests: XCTestCase {
    func testTerminalInputForwardsRawSendInputRequest() throws {
        let sender = MockTideyRequestSender()
        let resolver = MockSessionResolver()
        let handler = BridgeInputActionHandler(socketSender: sender, sessionResolver: resolver)

        let response = try handler.handle(BridgeRequest(id: "request-1",
                                                        action: "terminal_input",
                                                        params: [
                                                            "panel_id": .string("panel-1"),
                                                            "input": .string("ls\r"),
                                                        ]))

        XCTAssertEqual(response?.ok, true)
        XCTAssertEqual(sender.sentRequests.count, 1)
        XCTAssertEqual(sender.sentRequests.first?.action, "send_input")
        XCTAssertEqual(sender.sentRequests.first?.params?["panel_id"]?.stringValue, "panel-1")
        XCTAssertEqual(sender.sentRequests.first?.params?["input"]?.stringValue, "ls\r")
    }

    func testTerminalInputRoutesOrdinaryTmuxPanelWithoutMacSocketForward() throws {
        let sender = MockTideyRequestSender()
        let resolver = MockSessionResolver()
        let router = MockOrdinaryTmuxInputRouter(routedPanelIDs: ["ordinary-panel"])
        let handler = BridgeInputActionHandler(socketSender: sender,
                                               sessionResolver: resolver,
                                               ordinaryTmuxInputRouter: router)

        let response = try handler.handle(BridgeRequest(id: "request-1",
                                                        action: "terminal_input",
                                                        params: [
                                                            "panel_id": .string("ordinary-panel"),
                                                            "input": .string("ls\r"),
                                                        ]))

        XCTAssertEqual(response?.ok, true)
        XCTAssertTrue(sender.sentRequests.isEmpty)
        XCTAssertEqual(router.sentInputs.map(\.panelID), ["ordinary-panel"])
        XCTAssertEqual(router.sentInputs.map(\.input), ["ls\r"])
        XCTAssertEqual(router.sentInputs.map(\.mode), [.rawTerminalInput],
                       "terminal_input keeps raw key semantics")
    }

    func testTerminalInputFallsBackToMacSocketWhenCarrierOrdinaryTmuxTimesOut() throws {
        let sender = MockTideyRequestSender()
        let resolver = MockSessionResolver()
        let router = MockOrdinaryTmuxInputRouter(routedPanelIDs: ["carrier-panel"],
                                                 errorsByPanelID: ["carrier-panel": tmuxTimeoutError()])
        let handler = BridgeInputActionHandler(socketSender: sender,
                                               sessionResolver: resolver,
                                               ordinaryTmuxInputRouter: router)

        let response = try handler.handle(BridgeRequest(id: "request-1",
                                                        action: "terminal_input",
                                                        params: [
                                                            "panel_id": .string("carrier-panel"),
                                                            "input": .string("ls\r"),
                                                        ]))

        XCTAssertEqual(response?.ok, true)
        XCTAssertEqual(sender.sentRequests.count, 1)
        XCTAssertEqual(sender.sentRequests.first?.action, "send_input")
        XCTAssertEqual(sender.sentRequests.first?.params?["panel_id"]?.stringValue, "carrier-panel")
        XCTAssertEqual(sender.sentRequests.first?.params?["input"]?.stringValue, "ls\r")
    }

    func testTerminalInputDoesNotFallbackForRemoteOnlyLogicalPanelTimeout() {
        let sender = MockTideyRequestSender()
        let resolver = MockSessionResolver()
        let logicalPanelID = "ordinary-tmux:/tmp/tmux-501/default:$7:@4"
        let router = MockOrdinaryTmuxInputRouter(routedPanelIDs: [logicalPanelID],
                                                 errorsByPanelID: [logicalPanelID: tmuxTimeoutError()])
        let handler = BridgeInputActionHandler(socketSender: sender,
                                               sessionResolver: resolver,
                                               ordinaryTmuxInputRouter: router)

        XCTAssertThrowsError(
            try handler.handle(BridgeRequest(id: "request-1",
                                             action: "terminal_input",
                                             params: [
                                                "panel_id": .string(logicalPanelID),
                                                "input": .string("ls\r"),
                                             ]))
        )
        XCTAssertTrue(sender.sentRequests.isEmpty)
    }

    func testChatSubmitForClaudeSplitsMultilineTextAndEnterWithDelay() throws {
        let sender = MockTideyRequestSender()
        let resolver = MockSessionResolver(session: ActiveAgentSessionSnapshot(vendor: "claude",
                                                                              workspaceID: "workspace-1",
                                                                              sessionID: "session-1",
                                                                              panelID: "panel-1"))
        let delayRecorder = DelayRecorder()
        let handler = BridgeInputActionHandler(socketSender: sender,
                                               sessionResolver: resolver,
                                               sleep: { delayRecorder.record($0) })
        let message = "@/Users/timfeng/Downloads/Tidey-Remote/a.jpg\n\n拍照ok"

        let response = try handler.handle(BridgeRequest(id: "request-1",
                                                        action: "chat_submit",
                                                        params: [
                                                            "workspace_id": .string("workspace-1"),
                                                            "panel_id": .string("panel-1"),
                                                            "message": .string(message),
                                                            "session_id": .string("session-1"),
                                                            "vendor": .string("claude"),
                                                        ]))

        XCTAssertEqual(response?.ok, true)
        XCTAssertEqual(sender.sentRequests.map(\.action), ["send_input", "send_key"])
        XCTAssertEqual(sender.sentRequests[0].params?["input"]?.stringValue, message)
        XCTAssertEqual(sender.sentRequests[1].params?["key"]?.stringValue, "enter")
        XCTAssertEqual(delayRecorder.recordedDelays, [chatSubmitEnterDelayNanoseconds])
    }

    func testChatSubmitForCodexSplitsTextAndEnterWithDelay() throws {
        let sender = MockTideyRequestSender()
        let resolver = MockSessionResolver(session: ActiveAgentSessionSnapshot(vendor: "codex",
                                                                              workspaceID: "workspace-1",
                                                                              sessionID: "session-1",
                                                                              panelID: "panel-1"))
        let delayRecorder = DelayRecorder()
        let handler = BridgeInputActionHandler(socketSender: sender,
                                               sessionResolver: resolver,
                                               sleep: { delayRecorder.record($0) })

        let response = try handler.handle(BridgeRequest(id: "request-1",
                                                        action: "chat_submit",
                                                        params: [
                                                            "workspace_id": .string("workspace-1"),
                                                            "panel_id": .string("panel-1"),
                                                            "message": .string("hello"),
                                                            "session_id": .string("session-1"),
                                                            "vendor": .string("codex"),
                                                        ]))

        XCTAssertEqual(response?.ok, true)
        XCTAssertEqual(sender.sentRequests.map(\.action), ["send_input", "send_key"])
        XCTAssertEqual(sender.sentRequests[0].params?["input"]?.stringValue, "hello")
        XCTAssertEqual(sender.sentRequests[1].params?["key"]?.stringValue, "enter")
        XCTAssertEqual(delayRecorder.recordedDelays, [chatSubmitEnterDelayNanoseconds])
    }

    func testChatSubmitForCodexAppServerRuntimeSubmitsToRuntime() throws {
        let sender = MockTideyRequestSender()
        let resolver = MockSessionResolver(
            session: ActiveAgentSessionSnapshot(vendor: "codex",
                                                workspaceID: "workspace-1",
                                                sessionID: "session-1",
                                                panelID: "panel-1"),
            recordsBySessionID: [
                "session-1": AgentSessionRegistryRecord(version: 1,
                                                        vendor: "codex",
                                                        workspaceID: "workspace-1",
                                                        sessionID: "session-1",
                                                        panelID: "panel-1",
                                                        pid: 123,
                                                        cwd: "/tmp",
                                                        createdAt: "2026-06-08T00:00:00Z",
                                                        transcriptPath: nil,
                                                        runtime: "codex_app_server",
                                                        appServerSocket: "/tmp/app.sock",
                                                        appServerPID: 456),
            ])
        let appServerSubmitter = MockCodexAppServerChatSubmitter()
        let handler = BridgeInputActionHandler(socketSender: sender,
                                               sessionResolver: resolver,
                                               codexAppServerChatSubmitter: appServerSubmitter)

        let response = try handler.handle(BridgeRequest(id: "request-1",
                                                        action: "chat_submit",
                                                        params: [
                                                            "workspace_id": .string("workspace-1"),
                                                            "panel_id": .string("panel-1"),
                                                            "message": .string("hello from remote"),
                                                            "session_id": .string("session-1"),
                                                            "vendor": .string("codex"),
                                                        ]))

        XCTAssertEqual(response?.ok, true)
        XCTAssertTrue(sender.sentRequests.isEmpty)
        XCTAssertEqual(appServerSubmitter.submissions, [
            MockCodexAppServerChatSubmitter.Submission(sessionID: "session-1",
                                                       text: "hello from remote"),
        ])
    }

    func testChatSubmitForCodexAppServerRuntimeFallsBackWhenRuntimeCannotSubmit() throws {
        let sender = MockTideyRequestSender()
        let resolver = MockSessionResolver(
            session: ActiveAgentSessionSnapshot(vendor: "codex",
                                                workspaceID: "workspace-1",
                                                sessionID: "session-1",
                                                panelID: "panel-1"),
            recordsBySessionID: [
                "session-1": AgentSessionRegistryRecord(version: 1,
                                                        vendor: "codex",
                                                        workspaceID: "workspace-1",
                                                        sessionID: "session-1",
                                                        panelID: "panel-1",
                                                        pid: 123,
                                                        cwd: "/tmp",
                                                        createdAt: "2026-06-08T00:00:00Z",
                                                        transcriptPath: nil,
                                                        runtime: "codex_app_server",
                                                        appServerSocket: "/tmp/app.sock",
                                                        appServerPID: 456),
            ])
        let appServerSubmitter = MockCodexAppServerChatSubmitter()
        appServerSubmitter.canSubmit = false
        let handler = BridgeInputActionHandler(socketSender: sender,
                                               sessionResolver: resolver,
                                               codexAppServerChatSubmitter: appServerSubmitter)

        let response = try handler.handle(BridgeRequest(id: "request-1",
                                                        action: "chat_submit",
                                                        params: [
                                                            "workspace_id": .string("workspace-1"),
                                                            "panel_id": .string("panel-1"),
                                                            "message": .string("hello from terminal fallback"),
                                                            "session_id": .string("session-1"),
                                                            "vendor": .string("codex"),
                                                        ]))

        XCTAssertEqual(response?.ok, true)
        XCTAssertTrue(appServerSubmitter.submissions.isEmpty)
        XCTAssertEqual(sender.sentRequests.map(\.action), ["send_input", "send_key"])
        XCTAssertEqual(sender.sentRequests[0].params?["input"]?.stringValue, "hello from terminal fallback")
        XCTAssertEqual(sender.sentRequests[1].params?["key"]?.stringValue, "enter")
    }

    func testChatSubmitRegistersClientRequestIDForTranscriptEchoMatching() throws {
        let sender = MockTideyRequestSender()
        let resolver = MockSessionResolver(session: ActiveAgentSessionSnapshot(vendor: "codex",
                                                                              workspaceID: "workspace-1",
                                                                              sessionID: "session-1",
                                                                              panelID: "panel-1"))
        let registry = ChatSubmitEchoRegistry()
        let handler = BridgeInputActionHandler(socketSender: sender,
                                               sessionResolver: resolver,
                                               chatSubmitEchoRegistry: registry)

        let response = try handler.handle(BridgeRequest(id: "request-1",
                                                        action: "chat_submit",
                                                        params: [
                                                            "workspace_id": .string("workspace-1"),
                                                            "panel_id": .string("panel-1"),
                                                            "message": .string("hello"),
                                                            "session_id": .string("session-1"),
                                                            "vendor": .string("codex"),
                                                            "client_request_id": .string("local-1"),
                                                        ]))

        XCTAssertEqual(response?.ok, true)
        XCTAssertEqual(registry.consumeClientRequestID(workspaceID: "workspace-1",
                                                       panelID: "panel-1",
                                                       sessionID: "session-1",
                                                       vendor: "codex",
                                                       text: "hello"),
                       "local-1")
    }

    func testChatSubmitRoutesOrdinaryTmuxPanelStepsWithoutMacSocketForward() throws {
        let sender = MockTideyRequestSender()
        let resolver = MockSessionResolver(session: ActiveAgentSessionSnapshot(vendor: "codex",
                                                                              workspaceID: "workspace-1",
                                                                              sessionID: "session-1",
                                                                              panelID: "ordinary-panel"))
        let router = MockOrdinaryTmuxInputRouter(routedPanelIDs: ["ordinary-panel"])
        let delayRecorder = DelayRecorder()
        let handler = BridgeInputActionHandler(socketSender: sender,
                                               sessionResolver: resolver,
                                               ordinaryTmuxInputRouter: router,
                                               sleep: { delayRecorder.record($0) })

        let response = try handler.handle(BridgeRequest(id: "request-1",
                                                        action: "chat_submit",
                                                        params: [
                                                            "workspace_id": .string("workspace-1"),
                                                            "panel_id": .string("ordinary-panel"),
                                                            "message": .string("hello"),
                                                            "session_id": .string("session-1"),
                                                            "vendor": .string("codex"),
                                                        ]))

        XCTAssertEqual(response?.ok, true)
        XCTAssertTrue(sender.sentRequests.isEmpty)
        XCTAssertEqual(router.sentInputs.map(\.panelID), ["ordinary-panel", "ordinary-panel"])
        XCTAssertEqual(router.sentInputs.map(\.input), ["hello", "\r"])
        XCTAssertEqual(router.sentInputs.map(\.mode), [.literalChatText, .rawTerminalInput],
                       "the MESSAGE step is literal chat text; only the Enter step keeps raw key semantics")
        XCTAssertEqual(router.sentInputs.map(\.allowAmbiguousPasteTimeout), [true, true])
        XCTAssertEqual(delayRecorder.recordedDelays, [
            ordinaryTmuxChatSubmitEnterDelayNanoseconds,
        ])
    }

    // R26 edge: a blank-line message stays ONE literal chat-text step end to
    // end — the mode is not dropped between the handler and the router.
    func testChatSubmitBlankLineMessagePreservesLiteralModeThroughRouter() throws {
        let sender = MockTideyRequestSender()
        let resolver = MockSessionResolver(session: ActiveAgentSessionSnapshot(vendor: "claude",
                                                                              workspaceID: "workspace-1",
                                                                              sessionID: "session-1",
                                                                              panelID: "ordinary-panel"))
        let router = MockOrdinaryTmuxInputRouter(routedPanelIDs: ["ordinary-panel"])
        let delayRecorder = DelayRecorder()
        let handler = BridgeInputActionHandler(socketSender: sender,
                                               sessionResolver: resolver,
                                               ordinaryTmuxInputRouter: router,
                                               sleep: { delayRecorder.record($0) })

        let response = try handler.handle(BridgeRequest(id: "request-1",
                                                        action: "chat_submit",
                                                        params: [
                                                            "workspace_id": .string("workspace-1"),
                                                            "panel_id": .string("ordinary-panel"),
                                                            "message": .string("LIVE-6\n\nLIVE-7"),
                                                            "session_id": .string("session-1"),
                                                            "vendor": .string("claude"),
                                                        ]))

        XCTAssertEqual(response?.ok, true)
        XCTAssertEqual(router.sentInputs.map(\.input), ["LIVE-6\n\nLIVE-7", "\r"],
                       "the blank-line message stays one verbatim step")
        XCTAssertEqual(router.sentInputs.map(\.mode), [.literalChatText, .rawTerminalInput])
    }

    // R26 final: a message whose PAYLOAD is an enter-only sequence is still
    // the MESSAGE step — role, not content, decides. The first step stays
    // literal chat text; only the submit step is raw.
    func testChatSubmitEnterOnlyMessagePayloadStaysLiteralMessageStep() throws {
        let sender = MockTideyRequestSender()
        let resolver = MockSessionResolver(session: ActiveAgentSessionSnapshot(vendor: "codex",
                                                                              workspaceID: "workspace-1",
                                                                              sessionID: "session-1",
                                                                              panelID: "ordinary-panel"))
        let router = MockOrdinaryTmuxInputRouter(routedPanelIDs: ["ordinary-panel"])
        let delayRecorder = DelayRecorder()
        let handler = BridgeInputActionHandler(socketSender: sender,
                                               sessionResolver: resolver,
                                               ordinaryTmuxInputRouter: router,
                                               sleep: { delayRecorder.record($0) })

        let response = try handler.handle(BridgeRequest(id: "request-1",
                                                        action: "chat_submit",
                                                        params: [
                                                            "workspace_id": .string("workspace-1"),
                                                            "panel_id": .string("ordinary-panel"),
                                                            "message": .string("\r"),
                                                            "session_id": .string("session-1"),
                                                            "vendor": .string("codex"),
                                                        ]))

        XCTAssertEqual(response?.ok, true)
        XCTAssertEqual(router.sentInputs.map(\.input), ["\r", "\r"])
        XCTAssertEqual(router.sentInputs.map(\.mode), [.literalChatText, .rawTerminalInput],
                       "the enter-only PAYLOAD is still the literal message step; only the submit step is raw")
    }

    func testChatSubmitRoutesClaudeOrdinaryTmuxEnterAfterPasteWithSettleDelay() throws {
        let sender = MockTideyRequestSender()
        let resolver = MockSessionResolver(session: ActiveAgentSessionSnapshot(vendor: "claude",
                                                                              workspaceID: "workspace-1",
                                                                              sessionID: "session-1",
                                                                              panelID: "ordinary-panel"))
        let router = MockOrdinaryTmuxInputRouter(routedPanelIDs: ["ordinary-panel"])
        let delayRecorder = DelayRecorder()
        let handler = BridgeInputActionHandler(socketSender: sender,
                                               sessionResolver: resolver,
                                               ordinaryTmuxInputRouter: router,
                                               sleep: { delayRecorder.record($0) })

        let response = try handler.handle(BridgeRequest(id: "request-1",
                                                        action: "chat_submit",
                                                        params: [
                                                            "workspace_id": .string("workspace-1"),
                                                            "panel_id": .string("ordinary-panel"),
                                                            "message": .string("hello"),
                                                            "session_id": .string("session-1"),
                                                            "vendor": .string("claude"),
                                                        ]))

        XCTAssertEqual(response?.ok, true)
        XCTAssertTrue(sender.sentRequests.isEmpty)
        XCTAssertEqual(router.sentInputs.map(\.input), ["hello", "\r"])
        XCTAssertEqual(router.sentInputs.map(\.allowAmbiguousPasteTimeout), [true, true])
        XCTAssertEqual(delayRecorder.recordedDelays, [
            ordinaryTmuxChatSubmitEnterDelayNanoseconds,
        ])
    }

    func testChatSubmitFallsBackToMacSocketWhenCarrierOrdinaryTmuxTimesOut() throws {
        let sender = MockTideyRequestSender()
        let resolver = MockSessionResolver(session: ActiveAgentSessionSnapshot(vendor: "codex",
                                                                              workspaceID: "workspace-1",
                                                                              sessionID: "session-1",
                                                                              panelID: "carrier-panel"))
        let router = MockOrdinaryTmuxInputRouter(routedPanelIDs: ["carrier-panel"],
                                                 errorsByPanelID: ["carrier-panel": tmuxTimeoutError()])
        let delayRecorder = DelayRecorder()
        let handler = BridgeInputActionHandler(socketSender: sender,
                                               sessionResolver: resolver,
                                               ordinaryTmuxInputRouter: router,
                                               sleep: { delayRecorder.record($0) })

        let response = try handler.handle(BridgeRequest(id: "request-1",
                                                        action: "chat_submit",
                                                        params: [
                                                            "workspace_id": .string("workspace-1"),
                                                            "panel_id": .string("carrier-panel"),
                                                            "message": .string("hello"),
                                                            "session_id": .string("session-1"),
                                                            "vendor": .string("codex"),
                                                        ]))

        XCTAssertEqual(response?.ok, true)
        XCTAssertEqual(router.sentInputs.map(\.input), ["hello"])
        XCTAssertEqual(sender.sentRequests.map(\.action), ["send_input", "send_key"])
        XCTAssertEqual(sender.sentRequests[0].params?["input"]?.stringValue, "hello")
        XCTAssertEqual(sender.sentRequests[1].params?["key"]?.stringValue, "enter")
        XCTAssertEqual(delayRecorder.recordedDelays, [chatSubmitEnterDelayNanoseconds])
    }

    func testChatSubmitDeduplicatesRepeatedClientRequestIDBeforeSendingInput() throws {
        let sender = MockTideyRequestSender()
        let resolver = MockSessionResolver(session: ActiveAgentSessionSnapshot(vendor: "codex",
                                                                              workspaceID: "workspace-1",
                                                                              sessionID: "session-1",
                                                                              panelID: "ordinary-panel"))
        let router = MockOrdinaryTmuxInputRouter(routedPanelIDs: ["ordinary-panel"])
        let registry = ChatSubmitEchoRegistry()
        let handler = BridgeInputActionHandler(socketSender: sender,
                                               sessionResolver: resolver,
                                               ordinaryTmuxInputRouter: router,
                                               chatSubmitEchoRegistry: registry)
        let params: [String: JSONValue] = [
            "workspace_id": .string("workspace-1"),
            "panel_id": .string("ordinary-panel"),
            "message": .string("hello"),
            "session_id": .string("session-1"),
            "vendor": .string("codex"),
            "client_request_id": .string("local-1"),
        ]

        let first = try handler.handle(BridgeRequest(id: "request-1",
                                                     action: "chat_submit",
                                                     params: params))
        let duplicate = try handler.handle(BridgeRequest(id: "request-2",
                                                         action: "chat_submit",
                                                         params: params))

        XCTAssertEqual(first?.ok, true)
        XCTAssertEqual(duplicate?.ok, true)
        XCTAssertEqual(duplicate?.result?["deduplicated"]?.boolValue, true)
        XCTAssertTrue(sender.sentRequests.isEmpty)
        XCTAssertEqual(router.sentInputs.map(\.input), ["hello", "\r"])
    }

    func testChatSubmitRejectsMismatchedSession() throws {
        let sender = MockTideyRequestSender()
        let resolver = MockSessionResolver(session: ActiveAgentSessionSnapshot(vendor: "codex",
                                                                              workspaceID: "workspace-1",
                                                                              sessionID: "session-1",
                                                                              panelID: "panel-1"))
        let handler = BridgeInputActionHandler(socketSender: sender, sessionResolver: resolver)

        XCTAssertThrowsError(
            try handler.handle(BridgeRequest(id: "request-1",
                                             action: "chat_submit",
                                             params: [
                                                "workspace_id": .string("workspace-1"),
                                                "panel_id": .string("panel-1"),
                                                "message": .string("hello"),
                                                "session_id": .string("session-2"),
                                                "vendor": .string("codex"),
                                             ]))
        ) { error in
            guard case BridgeInternalError.invalidRequest(let message) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(message.contains("session_id"))
        }
        XCTAssertTrue(sender.sentRequests.isEmpty)
    }

    func testChatSubmitRejectsUnsupportedVendor() {
        let sender = MockTideyRequestSender()
        let resolver = MockSessionResolver()
        let handler = BridgeInputActionHandler(socketSender: sender, sessionResolver: resolver)

        XCTAssertThrowsError(
            try handler.handle(BridgeRequest(id: "request-1",
                                             action: "chat_submit",
                                             params: [
                                                "workspace_id": .string("workspace-1"),
                                                "panel_id": .string("panel-1"),
                                                "message": .string("hello"),
                                                "vendor": .string("unknown-agent"),
                                             ]))
        ) { error in
            guard case BridgeInternalError.invalidRequest(let message) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(message.contains("not supported"))
        }
        XCTAssertTrue(sender.sentRequests.isEmpty)
    }
}

private final class MockSessionResolver: ActiveAgentSessionResolving {
    private let session: ActiveAgentSessionSnapshot?
    private let recordsBySessionID: [String: AgentSessionRegistryRecord]

    init(session: ActiveAgentSessionSnapshot? = nil,
         recordsBySessionID: [String: AgentSessionRegistryRecord] = [:]) {
        self.session = session
        self.recordsBySessionID = recordsBySessionID
    }

    func activeSessionForPanel(workspaceID: String, panelID: String) -> ActiveAgentSessionSnapshot? {
        session
    }

    func activeRecord(sessionID: String) -> AgentSessionRegistryRecord? {
        recordsBySessionID[sessionID]
    }
}

private final class MockTideyRequestSender: TideyRequestSending {
    private(set) var sentRequests = [BridgeRequest]()

    func send(_ request: BridgeRequest) throws -> BridgeResponse {
        sentRequests.append(request)
        return BridgeResponse(id: request.id,
                              ok: true,
                              result: ["ok": .bool(true)],
                              error: nil)
    }
}

private final class MockCodexAppServerChatSubmitter: CodexAppServerChatSubmitting {
    struct Submission: Equatable {
        let sessionID: String
        let text: String
    }

    private(set) var submissions = [Submission]()
    var canSubmit = true

    func canSubmitMessage(sessionID: String) -> Bool {
        canSubmit
    }

    func submitMessage(sessionID: String, text: String) throws {
        submissions.append(Submission(sessionID: sessionID, text: text))
    }
}

private final class MockOrdinaryTmuxInputRouter: OrdinaryTmuxInputRouting, @unchecked Sendable {
    private let routedPanelIDs: Set<String>
    private let errorsByPanelID: [String: Error]
    private(set) var sentInputs = [(panelID: String, input: String, mode: OrdinaryTmuxInputMode, allowAmbiguousPasteTimeout: Bool)]()

    init(routedPanelIDs: Set<String>, errorsByPanelID: [String: Error] = [:]) {
        self.routedPanelIDs = routedPanelIDs
        self.errorsByPanelID = errorsByPanelID
    }

    func sendInput(_ input: String,
                   toPanelID panelID: String,
                   mode: OrdinaryTmuxInputMode,
                   allowAmbiguousPasteTimeout: Bool) throws -> Bool {
        guard routedPanelIDs.contains(panelID) else {
            return false
        }
        sentInputs.append((panelID, input, mode, allowAmbiguousPasteTimeout))
        if let error = errorsByPanelID[panelID] {
            throw error
        }
        return true
    }
}

private func tmuxTimeoutError() -> NSError {
    NSError(domain: "OrdinaryTmuxCLIAdapter",
            code: 124,
            userInfo: [NSLocalizedDescriptionKey: "tmux command timed out"])
}

private final class DelayRecorder: @unchecked Sendable {
    private var storage = [UInt64]()
    private let lock = NSLock()

    var recordedDelays: [UInt64] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func record(_ delay: UInt64) {
        lock.lock()
        storage.append(delay)
        lock.unlock()
    }
}
