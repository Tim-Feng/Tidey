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
                                                                              panelID: "panel-1"),
                                           recordsBySessionID: [
                                            "session-1": ordinaryCodexRecord(workspaceID: "workspace-1", panelID: "panel-1", sessionID: "session-1"),
                                           ])
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
                                                       text: "hello from remote",
                                                       clientRequestID: nil),
        ])
    }

    // Missing/not-ready app-server submitter for a headless codex_app_server
    // record must fail closed (typed conflict) rather than ever falling
    // through to the terminal loop: that pane is Tidey's headless Codex
    // viewer, which re-submits anything it reads back as a BRAND NEW
    // chat_submit — terminal fallback for this runtime is a recursive
    // resubmit loop, not a safe degraded path.
    func testChatSubmitForCodexAppServerRuntimeFailsClosedWhenSubmitterMissing() throws {
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
        let handler = BridgeInputActionHandler(socketSender: sender,
                                               sessionResolver: resolver,
                                               codexAppServerChatSubmitter: nil)

        let response = try handler.handle(BridgeRequest(id: "request-1",
                                                        action: "chat_submit",
                                                        params: [
                                                            "workspace_id": .string("workspace-1"),
                                                            "panel_id": .string("panel-1"),
                                                            "message": .string("hello with no submitter"),
                                                            "session_id": .string("session-1"),
                                                            "vendor": .string("codex"),
                                                        ]))

        XCTAssertEqual(response?.ok, false, "a missing app-server submitter for a headless record must fail closed")
        XCTAssertEqual(response?.error?.code, "conflict")
        XCTAssertTrue(sender.sentRequests.isEmpty, "no terminal input for a codex_app_server record — that pane recursively resubmits")
    }

    // Required test: busy but NO known active turn id (routeSubmit returned
    // .busyWithoutTurnID) must return a typed conflict/retryable failure and
    // must NEVER terminal-fallback — the headless viewer pane would
    // re-submit anything injected into it as a brand new chat_submit.
    func testChatSubmitBusyWithoutTurnIDReturnsConflictWithZeroTerminalInput() throws {
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
        appServerSubmitter.submitError = CodexAppServerSubmitFailure.busyWithoutTurnID
        let registry = ChatSubmitEchoRegistry()
        let handler = BridgeInputActionHandler(socketSender: sender,
                                               sessionResolver: resolver,
                                               codexAppServerChatSubmitter: appServerSubmitter,
                                               chatSubmitEchoRegistry: registry)

        let response = try handler.handle(BridgeRequest(id: "request-1",
                                                        action: "chat_submit",
                                                        params: [
                                                            "workspace_id": .string("workspace-1"),
                                                            "panel_id": .string("panel-1"),
                                                            "message": .string("hello while busy"),
                                                            "session_id": .string("session-1"),
                                                            "vendor": .string("codex"),
                                                            "client_request_id": .string("client-busy"),
                                                        ]))

        XCTAssertEqual(response?.ok, false, "busy-without-turn-id is a typed conflict, never a fallback success")
        XCTAssertEqual(response?.error?.code, "conflict")
        XCTAssertTrue(appServerSubmitter.submissions.isEmpty)
        XCTAssertTrue(sender.sentRequests.isEmpty, "must never fall back to terminal input for a codex_app_server record")

        // The reservation must be released (zero side effect) so a genuine
        // retry with the SAME client_request_id can actually re-attempt —
        // not be dedup-suppressed as if something had been delivered.
        let retryResponse = try handler.handle(BridgeRequest(id: "request-2",
                                                             action: "chat_submit",
                                                             params: [
                                                                "workspace_id": .string("workspace-1"),
                                                                "panel_id": .string("panel-1"),
                                                                "message": .string("hello while busy"),
                                                                "session_id": .string("session-1"),
                                                                "vendor": .string("codex"),
                                                                "client_request_id": .string("client-busy"),
                                                             ]))
        XCTAssertEqual(retryResponse?.ok, false)
        XCTAssertEqual(retryResponse?.error?.code, "conflict")
        XCTAssertNotEqual(retryResponse?.result?["deduplicated"]?.boolValue, true,
                          "a retry while still busy is a fresh conflict, not a dedup success")
        XCTAssertTrue(sender.sentRequests.isEmpty)
    }

    // Required test: the record lookup must not require activeSession — if
    // the panel snapshot is briefly missing but the request carries a
    // valid session_id, a codex_app_server record must still be resolved
    // and routed natively (or fail closed), never fall through to terminal
    // injection (the recursive HeadlessCodexTerminal path).
    func testChatSubmitResolvesAppServerRecordWithoutActiveSessionViaRequestedSessionID() throws {
        let sender = MockTideyRequestSender()
        let resolver = MockSessionResolver(
            session: nil,
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
                                                            "message": .string("hello with no active session snapshot"),
                                                            "session_id": .string("session-1"),
                                                            "vendor": .string("codex"),
                                                        ]))

        XCTAssertEqual(response?.ok, true, "the codex_app_server record was found via requested session_id alone")
        XCTAssertTrue(sender.sentRequests.isEmpty, "zero terminal input — the record was routed natively")
        XCTAssertEqual(appServerSubmitter.submissions, [
            MockCodexAppServerChatSubmitter.Submission(sessionID: "session-1",
                                                       text: "hello with no active session snapshot",
                                                       clientRequestID: nil),
        ])
    }

    // Required test: the app-server sending a DEFINITE JSON-RPC rejection
    // (turn/start raced into a newly active turn, or turn/steer's
    // expectedTurnId no longer matched) is zero semantic effect — the
    // reservation is released so a same-ID retry genuinely re-attempts, and
    // it must never touch the terminal transport.
    func testChatSubmitDefiniteRejectionCancelsReservationWithZeroTerminalInput() throws {
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
        appServerSubmitter.submitError = CodexAppServerSubmitFailure.rejected("expectedTurnId does not match")
        let registry = ChatSubmitEchoRegistry()
        let handler = BridgeInputActionHandler(socketSender: sender,
                                               sessionResolver: resolver,
                                               codexAppServerChatSubmitter: appServerSubmitter,
                                               chatSubmitEchoRegistry: registry)

        let response = try handler.handle(BridgeRequest(id: "request-1",
                                                        action: "chat_submit",
                                                        params: [
                                                            "workspace_id": .string("workspace-1"),
                                                            "panel_id": .string("panel-1"),
                                                            "message": .string("hello rejected"),
                                                            "session_id": .string("session-1"),
                                                            "vendor": .string("codex"),
                                                            "client_request_id": .string("client-rejected"),
                                                        ]))

        XCTAssertEqual(response?.ok, false, "a definite JSON-RPC rejection is never a fallback success")
        XCTAssertEqual(response?.error?.code, "conflict")
        XCTAssertTrue(sender.sentRequests.isEmpty, "must never fall back to terminal input for a codex_app_server record")

        // Zero semantic effect: the reservation was cancelled, so a genuine
        // retry with the SAME client_request_id re-attempts the submit.
        appServerSubmitter.submitError = nil
        let retryResponse = try handler.handle(BridgeRequest(id: "request-2",
                                                             action: "chat_submit",
                                                             params: [
                                                                "workspace_id": .string("workspace-1"),
                                                                "panel_id": .string("panel-1"),
                                                                "message": .string("hello rejected"),
                                                                "session_id": .string("session-1"),
                                                                "vendor": .string("codex"),
                                                                "client_request_id": .string("client-rejected"),
                                                             ]))
        XCTAssertEqual(retryResponse?.ok, true)
        XCTAssertNotEqual(retryResponse?.result?["deduplicated"]?.boolValue, true,
                          "a rejected-then-retried submit is a genuinely fresh attempt, not a dedup")
        XCTAssertEqual(appServerSubmitter.submissions.count, 1)
        XCTAssertTrue(sender.sentRequests.isEmpty)
    }

    // Required test (round 4 correction): a turn/steer SUCCESS response
    // whose turnId doesn't match expectedTurnId must not be reported as
    // success, must never fall back to the terminal, and — because it was
    // a success response, not a definite rejection — the reservation must
    // NOT be cancelled: a same-ID retry is a conflict, never a fresh dedupe
    // and never a resend.
    func testChatSubmitSteerTurnIDMismatchIsIndeterminateNotCancelled() throws {
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
        appServerSubmitter.submitError = CodexAppServerTurnIDMismatchError(expectedTurnID: "turn-A", observedTurnID: "turn-B")
        let registry = ChatSubmitEchoRegistry()
        let handler = BridgeInputActionHandler(socketSender: sender,
                                               sessionResolver: resolver,
                                               codexAppServerChatSubmitter: appServerSubmitter,
                                               chatSubmitEchoRegistry: registry)

        // A turnId mismatch is an indeterminate submitMessage() failure —
        // like every other non-typed error, the handler rethrows it (never
        // swallows it into a success response).
        XCTAssertThrowsError(try handler.handle(BridgeRequest(id: "request-1",
                                                              action: "chat_submit",
                                                              params: [
                                                                "workspace_id": .string("workspace-1"),
                                                                "panel_id": .string("panel-1"),
                                                                "message": .string("steer landed elsewhere"),
                                                                "session_id": .string("session-1"),
                                                                "vendor": .string("codex"),
                                                                "client_request_id": .string("client-mismatch"),
                                                              ])))
        XCTAssertTrue(sender.sentRequests.isEmpty, "must never fall back to terminal input for a codex_app_server record")

        // Unlike .rejected/.busyWithoutTurnID, this is NOT zero-effect — the
        // reservation stays indeterminate, so a same-ID retry is a
        // conflict (returned directly by the echo registry, without even
        // reaching the submitter again), never a dedup success and never a
        // resend.
        let retryResponse = try handler.handle(BridgeRequest(id: "request-2",
                                                             action: "chat_submit",
                                                             params: [
                                                                "workspace_id": .string("workspace-1"),
                                                                "panel_id": .string("panel-1"),
                                                                "message": .string("steer landed elsewhere"),
                                                                "session_id": .string("session-1"),
                                                                "vendor": .string("codex"),
                                                                "client_request_id": .string("client-mismatch"),
                                                             ]))
        XCTAssertEqual(retryResponse?.ok, false)
        XCTAssertNotEqual(retryResponse?.result?["deduplicated"]?.boolValue, true)
        XCTAssertEqual(appServerSubmitter.submissions.count, 0, "the reservation must stay indeterminate, not allow a resend")
        XCTAssertTrue(sender.sentRequests.isEmpty)
    }

    // Required test (round 4 correction): the record lookup must validate
    // that the resolved record actually belongs to the request's
    // workspace/panel/vendor — a session id that happens to resolve to a
    // DIFFERENT workspace/panel/vendor's record must fail closed with zero
    // native submit and zero terminal input, never silently submit into the
    // wrong panel's Codex thread.
    func testChatSubmitRejectsSessionIDBelongingToADifferentWorkspace() throws {
        let sender = MockTideyRequestSender()
        let resolver = MockSessionResolver(
            session: nil,
            recordsBySessionID: [
                "session-1": AgentSessionRegistryRecord(version: 1,
                                                        vendor: "codex",
                                                        workspaceID: "workspace-OTHER",
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

        XCTAssertThrowsError(
            try handler.handle(BridgeRequest(id: "request-1",
                                             action: "chat_submit",
                                             params: [
                                                "workspace_id": .string("workspace-1"),
                                                "panel_id": .string("panel-1"),
                                                "message": .string("hello wrong workspace"),
                                                "session_id": .string("session-1"),
                                                "vendor": .string("codex"),
                                             ]))
        ) { error in
            guard case BridgeInternalError.invalidRequest = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertTrue(appServerSubmitter.submissions.isEmpty, "must never submit natively into a mismatched record")
        XCTAssertTrue(sender.sentRequests.isEmpty, "must never fall back to terminal input either")
    }

    func testChatSubmitRejectsSessionIDBelongingToADifferentPanel() throws {
        let sender = MockTideyRequestSender()
        let resolver = MockSessionResolver(
            session: nil,
            recordsBySessionID: [
                "session-1": AgentSessionRegistryRecord(version: 1,
                                                        vendor: "codex",
                                                        workspaceID: "workspace-1",
                                                        sessionID: "session-1",
                                                        panelID: "panel-OTHER",
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

        XCTAssertThrowsError(
            try handler.handle(BridgeRequest(id: "request-1",
                                             action: "chat_submit",
                                             params: [
                                                "workspace_id": .string("workspace-1"),
                                                "panel_id": .string("panel-1"),
                                                "message": .string("hello wrong panel"),
                                                "session_id": .string("session-1"),
                                                "vendor": .string("codex"),
                                             ]))
        ) { error in
            guard case BridgeInternalError.invalidRequest = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertTrue(appServerSubmitter.submissions.isEmpty)
        XCTAssertTrue(sender.sentRequests.isEmpty)
    }

    func testChatSubmitRejectsSessionIDBelongingToADifferentVendor() throws {
        let sender = MockTideyRequestSender()
        let resolver = MockSessionResolver(
            session: nil,
            recordsBySessionID: [
                "session-1": AgentSessionRegistryRecord(version: 1,
                                                        vendor: "claude",
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

        XCTAssertThrowsError(
            try handler.handle(BridgeRequest(id: "request-1",
                                             action: "chat_submit",
                                             params: [
                                                "workspace_id": .string("workspace-1"),
                                                "panel_id": .string("panel-1"),
                                                "message": .string("hello wrong vendor"),
                                                "session_id": .string("session-1"),
                                                "vendor": .string("codex"),
                                             ]))
        ) { error in
            guard case BridgeInternalError.invalidRequest = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertTrue(appServerSubmitter.submissions.isEmpty)
        XCTAssertTrue(sender.sentRequests.isEmpty)
    }

    // Followup required test #1: activeSession == nil, a KNOWN codex
    // session_id is requested, but the registry record for it is not yet
    // resolvable (e.g. Bridge just restarted, registry hasn't loaded). We
    // cannot prove this ISN'T a codex_app_server record — and terminal
    // fallback for that runtime is a recursive resubmit loop — so this
    // must fail closed (conflict) rather than fall through to the ordinary
    // terminal plan. Zero effect: once the record resolves, the SAME
    // client_request_id genuinely retries and succeeds.
    func testChatSubmitFailsClosedWhenRequestedCodexSessionRecordIsUnresolvedAndRetriesAfterItResolves() throws {
        let sender = MockTideyRequestSender()
        let resolver = MockSessionResolver(session: nil, recordsBySessionID: [:])
        // A REAL registry (not the default nil) — so the retry-succeeds
        // assertion below actually proves the zero-effect fail-closed path
        // released the client_request_id reservation, rather than merely
        // observing that no reservation gate existed to begin with.
        let registry = ChatSubmitEchoRegistry()
        let handler = BridgeInputActionHandler(socketSender: sender,
                                               sessionResolver: resolver,
                                               chatSubmitEchoRegistry: registry)

        let response = try handler.handle(BridgeRequest(id: "request-1",
                                                        action: "chat_submit",
                                                        params: [
                                                            "workspace_id": .string("workspace-1"),
                                                            "panel_id": .string("panel-1"),
                                                            "message": .string("hello unresolved record"),
                                                            "session_id": .string("session-1"),
                                                            "vendor": .string("codex"),
                                                            "client_request_id": .string("client-unresolved"),
                                                        ]))
        XCTAssertEqual(response?.ok, false, "an unresolved record for a codex session must fail closed")
        XCTAssertEqual(response?.error?.code, "conflict")
        XCTAssertTrue(sender.sentRequests.isEmpty, "zero terminal input while the record is unresolved")

        // A duplicate with the SAME client_request_id, sent BEFORE the
        // record resolves, must ALSO conflict if the reservation were still
        // held — proving the first attempt genuinely released it (not
        // left it dangling as pending/indeterminate) requires this to
        // still fail closed for the SAME reason (record still unresolved),
        // not because of a lingering reservation.
        let stillUnresolvedResponse = try handler.handle(BridgeRequest(id: "request-1b",
                                                                       action: "chat_submit",
                                                                       params: [
                                                                        "workspace_id": .string("workspace-1"),
                                                                        "panel_id": .string("panel-1"),
                                                                        "message": .string("hello unresolved record"),
                                                                        "session_id": .string("session-1"),
                                                                        "vendor": .string("codex"),
                                                                        "client_request_id": .string("client-unresolved"),
                                                                       ]))
        XCTAssertEqual(stillUnresolvedResponse?.ok, false)
        XCTAssertNotEqual(stillUnresolvedResponse?.result?["deduplicated"]?.boolValue, true,
                          "still a fresh fail-closed attempt, not a dedup of anything")

        // The registry catches up: the record resolves to an ordinary
        // (non-app-server) tmux session.
        resolver.recordsBySessionID["session-1"] = ordinaryCodexRecord(workspaceID: "workspace-1",
                                                                       panelID: "panel-1",
                                                                       sessionID: "session-1")
        let retryResponse = try handler.handle(BridgeRequest(id: "request-2",
                                                             action: "chat_submit",
                                                             params: [
                                                                "workspace_id": .string("workspace-1"),
                                                                "panel_id": .string("panel-1"),
                                                                "message": .string("hello unresolved record"),
                                                                "session_id": .string("session-1"),
                                                                "vendor": .string("codex"),
                                                                "client_request_id": .string("client-unresolved"),
                                                             ]))
        XCTAssertEqual(retryResponse?.ok, true, "a genuine retry succeeds once the record resolves")
        XCTAssertNotEqual(retryResponse?.result?["deduplicated"]?.boolValue, true,
                          "this is a fresh attempt, not a dedup of a fake success")
        XCTAssertEqual(sender.sentRequests.map(\.action), ["send_input", "send_key"])

        // With the registry now genuinely tracking this client_request_id
        // as delivered, an EXACT repeat after the real success dedupes —
        // proving the registry was live and meaningful the whole time, not
        // a bystander.
        let finalRetryResponse = try handler.handle(BridgeRequest(id: "request-3",
                                                                   action: "chat_submit",
                                                                   params: [
                                                                    "workspace_id": .string("workspace-1"),
                                                                    "panel_id": .string("panel-1"),
                                                                    "message": .string("hello unresolved record"),
                                                                    "session_id": .string("session-1"),
                                                                    "vendor": .string("codex"),
                                                                    "client_request_id": .string("client-unresolved"),
                                                                   ]))
        XCTAssertEqual(finalRetryResponse?.ok, true)
        XCTAssertEqual(finalRetryResponse?.result?["deduplicated"]?.boolValue, true,
                       "the real delivery is now dedup-protected")
        XCTAssertEqual(sender.sentRequests.count, 2, "no additional send for the deduplicated repeat")
    }

    // Followup required test #2: activeSession == nil, the request claims
    // vendor=claude, but the requested session_id actually resolves to a
    // codex_app_server record. Routing must be decided by the RECORD, not
    // the claimed vendor — otherwise a stale/forged session_id could route
    // a "claude" request into a Codex app-server thread (or, worse, its
    // recursive HeadlessCodexTerminal fallback).
    func testChatSubmitRejectsClaimedClaudeVendorWhenSessionIDResolvesToCodexAppServerRecord() throws {
        let sender = MockTideyRequestSender()
        let resolver = MockSessionResolver(
            session: nil,
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
        // A REAL registry — the retry-with-the-corrected-vendor assertion
        // below actually proves the throw path released the
        // client_request_id reservation, not merely that no gate existed.
        let registry = ChatSubmitEchoRegistry()
        let handler = BridgeInputActionHandler(socketSender: sender,
                                               sessionResolver: resolver,
                                               codexAppServerChatSubmitter: appServerSubmitter,
                                               chatSubmitEchoRegistry: registry)

        XCTAssertThrowsError(
            try handler.handle(BridgeRequest(id: "request-1",
                                             action: "chat_submit",
                                             params: [
                                                "workspace_id": .string("workspace-1"),
                                                "panel_id": .string("panel-1"),
                                                "message": .string("hello claimed claude"),
                                                "session_id": .string("session-1"),
                                                "vendor": .string("claude"),
                                                "client_request_id": .string("client-wrong-vendor"),
                                             ]))
        ) { error in
            guard case BridgeInternalError.invalidRequest = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertTrue(appServerSubmitter.submissions.isEmpty, "must never submit natively despite the record being codex_app_server")
        XCTAssertTrue(sender.sentRequests.isEmpty, "must never fall back to terminal input either")

        // The registry key includes vendor, so retrying with vendor=codex
        // would land on a DIFFERENT reservation key and prove nothing about
        // whether the original (vendor=claude) reservation was released.
        // To actually prove release, keep EVERY param identical — same
        // vendor=claude, same client_request_id — and instead fix the
        // CONDITION that caused the failure: the record now resolves to an
        // ordinary (non-app-server, vendor=claude) session at the same
        // workspace/panel.
        resolver.recordsBySessionID["session-1"] = AgentSessionRegistryRecord(version: 1,
                                                                              vendor: "claude",
                                                                              workspaceID: "workspace-1",
                                                                              sessionID: "session-1",
                                                                              panelID: "panel-1",
                                                                              pid: 123,
                                                                              cwd: "/tmp",
                                                                              createdAt: "2026-06-08T00:00:00Z",
                                                                              transcriptPath: nil)
        let retryResponse = try handler.handle(BridgeRequest(id: "request-2",
                                                             action: "chat_submit",
                                                             params: [
                                                                "workspace_id": .string("workspace-1"),
                                                                "panel_id": .string("panel-1"),
                                                                "message": .string("hello claimed claude"),
                                                                "session_id": .string("session-1"),
                                                                "vendor": .string("claude"),
                                                                "client_request_id": .string("client-wrong-vendor"),
                                                             ]))
        XCTAssertEqual(retryResponse?.ok, true, "a genuine retry with the SAME vendor/session/client_request_id succeeds once the record resolves to an ordinary session")
        XCTAssertNotEqual(retryResponse?.result?["deduplicated"]?.boolValue, true,
                          "this is a fresh attempt, not a dedup of a fake success")
        XCTAssertTrue(appServerSubmitter.submissions.isEmpty, "claude never routes natively")
        XCTAssertEqual(sender.sentRequests.map(\.action), ["send_input", "send_key"],
                       "the retry reached the ordinary terminal plan, proving the original reservation was released")

        // An EXACT repeat (same everything) after this real success now
        // dedupes — proving the registry was live and tracking this
        // client_request_id the whole time, not a bystander.
        let sentCountAfterRetry = sender.sentRequests.count
        let finalRepeatResponse = try handler.handle(BridgeRequest(id: "request-3",
                                                                   action: "chat_submit",
                                                                   params: [
                                                                    "workspace_id": .string("workspace-1"),
                                                                    "panel_id": .string("panel-1"),
                                                                    "message": .string("hello claimed claude"),
                                                                    "session_id": .string("session-1"),
                                                                    "vendor": .string("claude"),
                                                                    "client_request_id": .string("client-wrong-vendor"),
                                                                   ]))
        XCTAssertEqual(finalRepeatResponse?.ok, true)
        XCTAssertEqual(finalRepeatResponse?.result?["deduplicated"]?.boolValue, true,
                       "the real delivery is now dedup-protected")
        XCTAssertEqual(sender.sentRequests.count, sentCountAfterRetry, "no additional send for the deduplicated repeat")
    }

    // Followup required test #3: the active PANEL session (not just a
    // requested one) is codex, but the registry record is unresolved —
    // same fail-closed contract as test #1, this time with activeSession
    // present.
    func testChatSubmitFailsClosedWhenActiveCodexSessionRecordIsUnresolved() throws {
        let sender = MockTideyRequestSender()
        let resolver = MockSessionResolver(session: ActiveAgentSessionSnapshot(vendor: "codex",
                                                                              workspaceID: "workspace-1",
                                                                              sessionID: "session-1",
                                                                              panelID: "panel-1"),
                                           recordsBySessionID: [:])
        let handler = BridgeInputActionHandler(socketSender: sender, sessionResolver: resolver)

        let response = try handler.handle(BridgeRequest(id: "request-1",
                                                        action: "chat_submit",
                                                        params: [
                                                            "workspace_id": .string("workspace-1"),
                                                            "panel_id": .string("panel-1"),
                                                            "message": .string("hello active but unresolved"),
                                                            "session_id": .string("session-1"),
                                                            "vendor": .string("codex"),
                                                        ]))
        XCTAssertEqual(response?.ok, false, "an active codex session with an unresolved record must fail closed")
        XCTAssertEqual(response?.error?.code, "conflict")
        XCTAssertTrue(sender.sentRequests.isEmpty, "zero terminal input while the record is unresolved")
    }

    // Reviewer identity/runtime gate #1: a RESOLVED, confirmed non-app-
    // server record exists for this session id, but it belongs to a
    // DIFFERENT panel than the one in this request — never trust a
    // session id whose record identity doesn't match the request, even
    // when the record's runtime is a confirmed-safe `nil`. Must fail
    // closed with zero transport, never bypass the gate onto the
    // (headless) target panel's terminal.
    func testChatSubmitFailsClosedWhenOrdinaryRecordBelongsToADifferentPanelThanTheHeadlessTarget() throws {
        let sender = MockTideyRequestSender()
        let router = MockOrdinaryTmuxInputRouter(routedPanelIDs: ["headless-panel"])
        let resolver = MockSessionResolver(
            session: nil,
            recordsBySessionID: [
                // Resolved, confirmed-ordinary (runtime nil) — but for
                // "other-panel", not the "headless-panel" this request
                // targets.
                "session-1": ordinaryCodexRecord(workspaceID: "workspace-1", panelID: "other-panel", sessionID: "session-1"),
            ])
        let handler = BridgeInputActionHandler(socketSender: sender,
                                               sessionResolver: resolver,
                                               ordinaryTmuxInputRouter: router)

        let response = try handler.handle(BridgeRequest(id: "request-1",
                                                        action: "chat_submit",
                                                        params: [
                                                            "workspace_id": .string("workspace-1"),
                                                            "panel_id": .string("headless-panel"),
                                                            "message": .string("hello mismatched panel"),
                                                            "session_id": .string("session-1"),
                                                            "vendor": .string("codex"),
                                                        ]))

        XCTAssertEqual(response?.ok, false, "a record belonging to a different panel must fail closed")
        XCTAssertEqual(response?.error?.code, "conflict")
        XCTAssertTrue(sender.sentRequests.isEmpty, "zero socket sends")
        XCTAssertTrue(router.sentInputs.isEmpty, "zero ordinary-tmux routes onto the target panel")
    }

    // Reviewer identity/runtime gate #2: a resolved record whose identity
    // matches, but whose runtime is a non-nil value OTHER than
    // "codex_app_server" (e.g. a transitional "starting" state, or an
    // unrecognized value) is not a CONFIRMED ordinary shape — only `nil`
    // is. Must fail closed rather than guess, for the same
    // recursive-resubmit reason as an actual codex_app_server record.
    func testChatSubmitFailsClosedForUnconfirmedNonNilRuntime() throws {
        let sender = MockTideyRequestSender()
        let router = MockOrdinaryTmuxInputRouter(routedPanelIDs: ["panel-1"])
        let resolver = MockSessionResolver(
            session: nil,
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
                                                        runtime: "starting"),
            ])
        let handler = BridgeInputActionHandler(socketSender: sender,
                                               sessionResolver: resolver,
                                               ordinaryTmuxInputRouter: router)

        let response = try handler.handle(BridgeRequest(id: "request-1",
                                                        action: "chat_submit",
                                                        params: [
                                                            "workspace_id": .string("workspace-1"),
                                                            "panel_id": .string("panel-1"),
                                                            "message": .string("hello unconfirmed runtime"),
                                                            "session_id": .string("session-1"),
                                                            "vendor": .string("codex"),
                                                        ]))

        XCTAssertEqual(response?.ok, false, "an unconfirmed non-nil runtime must fail closed")
        XCTAssertEqual(response?.error?.code, "conflict")
        XCTAssertTrue(sender.sentRequests.isEmpty, "zero socket sends")
        XCTAssertTrue(router.sentInputs.isEmpty, "zero ordinary-tmux routes")
    }

    // Reviewer identity/runtime gate #3 (regression): correct identity
    // (workspace/panel/vendor all match) PLUS a confirmed-ordinary `nil`
    // runtime must still reach the terminal plan normally.
    func testChatSubmitStillReachesTerminalWithMatchingIdentityAndNilRuntime() throws {
        let sender = MockTideyRequestSender()
        let resolver = MockSessionResolver(
            session: nil,
            recordsBySessionID: [
                "session-1": ordinaryCodexRecord(workspaceID: "workspace-1", panelID: "panel-1", sessionID: "session-1"),
            ])
        let handler = BridgeInputActionHandler(socketSender: sender, sessionResolver: resolver)

        let response = try handler.handle(BridgeRequest(id: "request-1",
                                                        action: "chat_submit",
                                                        params: [
                                                            "workspace_id": .string("workspace-1"),
                                                            "panel_id": .string("panel-1"),
                                                            "message": .string("hello matching identity"),
                                                            "session_id": .string("session-1"),
                                                            "vendor": .string("codex"),
                                                        ]))

        XCTAssertEqual(response?.ok, true, "matching identity plus a confirmed-ordinary nil runtime still reaches the terminal")
        XCTAssertEqual(sender.sentRequests.map(\.action), ["send_input", "send_key"])
    }

    // Followup required test #4 (regression): a non-app-server Claude
    // session's ordinary terminal path is unaffected by the new
    // record-availability gate — Claude never routes through the
    // codex_app_server branch at all, record or no record.
    func testChatSubmitClaudeOrdinaryTerminalPathStillSendsWithoutAnyRecord() throws {
        let sender = MockTideyRequestSender()
        let resolver = MockSessionResolver(session: ActiveAgentSessionSnapshot(vendor: "claude",
                                                                              workspaceID: "workspace-1",
                                                                              sessionID: "session-1",
                                                                              panelID: "panel-1"),
                                           recordsBySessionID: [:])
        let handler = BridgeInputActionHandler(socketSender: sender, sessionResolver: resolver)

        let response = try handler.handle(BridgeRequest(id: "request-1",
                                                        action: "chat_submit",
                                                        params: [
                                                            "workspace_id": .string("workspace-1"),
                                                            "panel_id": .string("panel-1"),
                                                            "message": .string("hello claude no record"),
                                                            "session_id": .string("session-1"),
                                                            "vendor": .string("claude"),
                                                        ]))
        XCTAssertEqual(response?.ok, true)
        XCTAssertEqual(sender.sentRequests.map(\.action), ["send_input", "send_key"])
    }

    // Nil-session follow-up: vendor=codex with activeSession == nil AND no
    // requested session_id at all — appServerSessionID is nil, so the
    // record lookup can never resolve anything. This is just as unsafe as
    // an unresolved-but-known session id: we cannot prove there ISN'T a
    // codex_app_server record involved, so it must fail closed with zero
    // transport across the board (no socket send, no ordinary-tmux route,
    // no native app-server submit) — never silently fall through to the
    // terminal plan for lack of a session id to look up.
    func testChatSubmitFailsClosedForCodexVendorWithNoSessionIDAtAll() throws {
        let sender = MockTideyRequestSender()
        let router = MockOrdinaryTmuxInputRouter(routedPanelIDs: ["panel-1"])
        let appServerSubmitter = MockCodexAppServerChatSubmitter()
        let resolver = MockSessionResolver(session: nil, recordsBySessionID: [:])
        let handler = BridgeInputActionHandler(socketSender: sender,
                                               sessionResolver: resolver,
                                               codexAppServerChatSubmitter: appServerSubmitter,
                                               ordinaryTmuxInputRouter: router)

        let response = try handler.handle(BridgeRequest(id: "request-1",
                                                        action: "chat_submit",
                                                        params: [
                                                            "workspace_id": .string("workspace-1"),
                                                            "panel_id": .string("panel-1"),
                                                            "message": .string("hello no session id at all"),
                                                            "vendor": .string("codex"),
                                                        ]))

        XCTAssertEqual(response?.ok, false, "vendor=codex with no resolvable session id must fail closed")
        XCTAssertEqual(response?.error?.code, "conflict")
        XCTAssertTrue(sender.sentRequests.isEmpty, "zero socket sends")
        XCTAssertTrue(router.sentInputs.isEmpty, "zero ordinary-tmux routes")
        XCTAssertTrue(appServerSubmitter.submissions.isEmpty, "zero native app-server submits")
    }

    // Regression companion: the SAME no-session-id-at-all shape for
    // vendor=claude must be entirely unaffected — Claude never enters the
    // codex-only branches, record or no record, session id or not.
    func testChatSubmitClaudeStillSendsWithNoSessionIDAtAll() throws {
        let sender = MockTideyRequestSender()
        let resolver = MockSessionResolver(session: nil, recordsBySessionID: [:])
        let handler = BridgeInputActionHandler(socketSender: sender, sessionResolver: resolver)

        let response = try handler.handle(BridgeRequest(id: "request-1",
                                                        action: "chat_submit",
                                                        params: [
                                                            "workspace_id": .string("workspace-1"),
                                                            "panel_id": .string("panel-1"),
                                                            "message": .string("hello claude no session id"),
                                                            "vendor": .string("claude"),
                                                        ]))

        XCTAssertEqual(response?.ok, true)
        XCTAssertEqual(sender.sentRequests.map(\.action), ["send_input", "send_key"])
    }

    // Reviewer follow-up: the FIRST terminal step's write THROWS (a
    // generic Swift error, not a clean ok:false response) before any step
    // is confirmed sent. A thrown error's side-effect status is
    // unprovable (unlike a clean ok:false), so this must stay
    // indeterminate — never cancellable — and a same-ID retry must get a
    // conflict, never a resend and never a false success.
    func testChatSubmitTerminalFirstSendThrowsGenericErrorStaysIndeterminateAndRetryConflicts() throws {
        let sender = MockTideyRequestSender()
        struct GenericTransportError: Error {}
        sender.failure = GenericTransportError()
        let resolver = MockSessionResolver(session: ActiveAgentSessionSnapshot(vendor: "codex",
                                                                              workspaceID: "workspace-1",
                                                                              sessionID: "session-1",
                                                                              panelID: "panel-1"),
                                           recordsBySessionID: [
                                            "session-1": ordinaryCodexRecord(workspaceID: "workspace-1", panelID: "panel-1", sessionID: "session-1"),
                                           ])
        let registry = ChatSubmitEchoRegistry()
        let handler = BridgeInputActionHandler(socketSender: sender,
                                               sessionResolver: resolver,
                                               chatSubmitEchoRegistry: registry)
        let params: [String: JSONValue] = [
            "workspace_id": .string("workspace-1"),
            "panel_id": .string("panel-1"),
            "message": .string("hello throws before any step confirmed"),
            "session_id": .string("session-1"),
            "vendor": .string("codex"),
            "client_request_id": .string("client-throws-first"),
        ]

        XCTAssertThrowsError(try handler.handle(BridgeRequest(id: "request-1", action: "chat_submit", params: params)))
        let sentCountAfterFirst = sender.sentRequests.count
        XCTAssertGreaterThan(sentCountAfterFirst, 0, "the write was attempted before throwing")

        // Retry with the SAME client_request_id: must be a conflict, never
        // a resend and never a false success — the first attempt's
        // outcome is indeterminate (unprovable), not zero-effect.
        let retryResponse = try handler.handle(BridgeRequest(id: "request-2", action: "chat_submit", params: params))
        XCTAssertEqual(retryResponse?.ok, false)
        XCTAssertEqual(retryResponse?.error?.code, "conflict")
        XCTAssertNil(retryResponse?.result?["deduplicated"])
        XCTAssertEqual(sender.sentRequests.count, sentCountAfterFirst, "no resend for an indeterminate duplicate")
    }

    // Required test (round 4 correction): a definite pre-send unavailable
    // outcome (missing runtime/thread-not-ready) must fail closed with zero
    // terminal/native write, and — because it is zero-effect — the SAME
    // client_request_id can genuinely retry once the runtime is restored.
    func testChatSubmitUnavailableBeforeSendAllowsRetryOnceRuntimeRestored() throws {
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
        appServerSubmitter.submitError = CodexAppServerSubmitFailure.unavailableBeforeSend("Codex app-server thread is not ready.")
        let registry = ChatSubmitEchoRegistry()
        let handler = BridgeInputActionHandler(socketSender: sender,
                                               sessionResolver: resolver,
                                               codexAppServerChatSubmitter: appServerSubmitter,
                                               chatSubmitEchoRegistry: registry)
        let params: [String: JSONValue] = [
            "workspace_id": .string("workspace-1"),
            "panel_id": .string("panel-1"),
            "message": .string("hello while runtime unavailable"),
            "session_id": .string("session-1"),
            "vendor": .string("codex"),
            "client_request_id": .string("client-unavailable"),
        ]

        let firstResponse = try handler.handle(BridgeRequest(id: "request-1", action: "chat_submit", params: params))
        XCTAssertEqual(firstResponse?.ok, false)
        XCTAssertEqual(firstResponse?.error?.code, "conflict")
        XCTAssertTrue(sender.sentRequests.isEmpty, "no terminal fallback while the runtime is unavailable")

        // The runtime recovers — a genuine retry with the SAME client id
        // must actually re-attempt, not be dedup-suppressed.
        appServerSubmitter.submitError = nil
        let retryResponse = try handler.handle(BridgeRequest(id: "request-2", action: "chat_submit", params: params))
        XCTAssertEqual(retryResponse?.ok, true)
        XCTAssertNotEqual(retryResponse?.result?["deduplicated"]?.boolValue, true,
                          "a retry after the zero-effect unavailable outcome is a genuinely fresh attempt")
        XCTAssertEqual(appServerSubmitter.submissions.count, 1)
        XCTAssertTrue(sender.sentRequests.isEmpty)
    }

    // Round 2 test #3: the terminal message-text step succeeds, but the
    // Enter step fails. That text step had a REAL externally observable
    // effect — the reservation must become indeterminate: a same-ID retry
    // must NOT resend the text, and must NOT be told "submitted: true".
    func testChatSubmitTerminalTextSucceedsEnterFailsRetrySameIDReturnsConflictNotSuccess() throws {
        let sender = MockTideyRequestSender()
        let resolver = MockSessionResolver(session: ActiveAgentSessionSnapshot(vendor: "codex",
                                                                              workspaceID: "workspace-1",
                                                                              sessionID: "session-1",
                                                                              panelID: "panel-1"),
                                           recordsBySessionID: [
                                            "session-1": ordinaryCodexRecord(workspaceID: "workspace-1", panelID: "panel-1", sessionID: "session-1"),
                                           ])
        let registry = ChatSubmitEchoRegistry()
        let handler = BridgeInputActionHandler(socketSender: sender,
                                               sessionResolver: resolver,
                                               chatSubmitEchoRegistry: registry)
        let params: [String: JSONValue] = [
            "workspace_id": .string("workspace-1"),
            "panel_id": .string("panel-1"),
            "message": .string("partial delivery"),
            "session_id": .string("session-1"),
            "vendor": .string("codex"),
            "client_request_id": .string("client-partial"),
        ]

        // The first send_input (text) call succeeds (default mock
        // behavior); make ONLY the second call (send_key / Enter) fail.
        sender.failFromCallIndex = 1

        let firstResponse = try handler.handle(BridgeRequest(id: "request-1", action: "chat_submit", params: params))
        XCTAssertEqual(firstResponse?.ok, false, "the Enter step failed")
        XCTAssertEqual(sender.sentRequests.map(\.action), ["send_input", "send_key"],
                       "the text step DID reach the transport before Enter failed")

        let sentCountAfterFirst = sender.sentRequests.count
        let retryResponse = try handler.handle(BridgeRequest(id: "request-2", action: "chat_submit", params: params))
        XCTAssertEqual(retryResponse?.ok, false)
        XCTAssertNotEqual(retryResponse?.result?["submitted"]?.boolValue, true,
                          "an indeterminate (partial) prior attempt must never be reported as submitted success")
        XCTAssertNil(retryResponse?.result?["deduplicated"])
        XCTAssertEqual(sender.sentRequests.count, sentCountAfterFirst,
                       "the already-sent text must NEVER be resent for an indeterminate duplicate")
    }

    // Round 2 test #4: a generic direct-submit error (NOT the typed
    // busy-before-send) must never fall back to the terminal — the
    // transport attempt may have partially reached the app-server — and
    // the client_request_id must never be reported as a false success.
    func testChatSubmitDirectSubmitGenericErrorDoesNotFallBackAndDoesNotFalselySucceed() throws {
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
        struct GenericTransportError: Error {}
        appServerSubmitter.submitError = GenericTransportError()
        let registry = ChatSubmitEchoRegistry()
        let handler = BridgeInputActionHandler(socketSender: sender,
                                               sessionResolver: resolver,
                                               codexAppServerChatSubmitter: appServerSubmitter,
                                               chatSubmitEchoRegistry: registry)

        XCTAssertThrowsError(try handler.handle(BridgeRequest(id: "request-1",
                                                              action: "chat_submit",
                                                              params: [
                                                                "workspace_id": .string("workspace-1"),
                                                                "panel_id": .string("panel-1"),
                                                                "message": .string("hello indeterminate"),
                                                                "session_id": .string("session-1"),
                                                                "vendor": .string("codex"),
                                                                "client_request_id": .string("client-generic"),
                                                              ])))
        XCTAssertTrue(sender.sentRequests.isEmpty, "a generic direct-submit error must never fall back to the terminal")

        // Retry with the SAME id: must not be reported as a deduplicated
        // success — the outcome of the first attempt is indeterminate.
        let retryResponse = try handler.handle(BridgeRequest(id: "request-2",
                                                             action: "chat_submit",
                                                             params: [
                                                                "workspace_id": .string("workspace-1"),
                                                                "panel_id": .string("panel-1"),
                                                                "message": .string("hello indeterminate"),
                                                                "session_id": .string("session-1"),
                                                                "vendor": .string("codex"),
                                                                "client_request_id": .string("client-generic"),
                                                             ]))
        XCTAssertNotEqual(retryResponse?.result?["submitted"]?.boolValue, true)
        XCTAssertNotEqual(retryResponse?.result?["deduplicated"]?.boolValue, true)
    }

    // Round 2 test #5: a duplicate client_request_id arriving while the
    // ORIGINAL submission is still in flight (pending) must never be told
    // "submitted: true" — that could be a false success if the original
    // never actually completes.
    func testChatSubmitDuplicateWhileFirstSubmissionStillInFlightReturnsConflictNotSuccess() throws {
        let sender = MockTideyRequestSender()
        let resolver = MockSessionResolver(session: ActiveAgentSessionSnapshot(vendor: "codex",
                                                                              workspaceID: "workspace-1",
                                                                              sessionID: "session-1",
                                                                              panelID: "panel-1"),
                                           recordsBySessionID: [
                                            "session-1": ordinaryCodexRecord(workspaceID: "workspace-1", panelID: "panel-1", sessionID: "session-1"),
                                           ])
        let registry = ChatSubmitEchoRegistry()
        let handler = BridgeInputActionHandler(socketSender: sender,
                                               sessionResolver: resolver,
                                               chatSubmitEchoRegistry: registry)

        // Simulate an in-flight ORIGINAL submission directly on the shared
        // registry (a concurrent request that has not yet resolved).
        XCTAssertEqual(registry.beginSubmission(workspaceID: "workspace-1",
                                                panelID: "panel-1",
                                                sessionID: "session-1",
                                                vendor: "codex",
                                                clientRequestID: "client-inflight"), .started)

        let duplicateResponse = try handler.handle(BridgeRequest(id: "request-2",
                                                                  action: "chat_submit",
                                                                  params: [
                                                                    "workspace_id": .string("workspace-1"),
                                                                    "panel_id": .string("panel-1"),
                                                                    "message": .string("hello duplicate"),
                                                                    "session_id": .string("session-1"),
                                                                    "vendor": .string("codex"),
                                                                    "client_request_id": .string("client-inflight"),
                                                                  ]))
        XCTAssertNotEqual(duplicateResponse?.result?["submitted"]?.boolValue, true,
                          "an in-flight duplicate must never be told a false success")
        XCTAssertTrue(sender.sentRequests.isEmpty, "the duplicate must not trigger a second delivery attempt")
    }

    // Round 2 test #6: both a REAL app-server success and a REAL terminal
    // success dedupe a same-ID retry to exactly one delivery each.
    func testChatSubmitRealAppServerSuccessThenSameIDRetryStillSendsOnlyOnce() throws {
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
        let registry = ChatSubmitEchoRegistry()
        let handler = BridgeInputActionHandler(socketSender: sender,
                                               sessionResolver: resolver,
                                               codexAppServerChatSubmitter: appServerSubmitter,
                                               chatSubmitEchoRegistry: registry)
        let params: [String: JSONValue] = [
            "workspace_id": .string("workspace-1"),
            "panel_id": .string("panel-1"),
            "message": .string("hello once"),
            "session_id": .string("session-1"),
            "vendor": .string("codex"),
            "client_request_id": .string("client-appserver-once"),
        ]

        let firstResponse = try handler.handle(BridgeRequest(id: "request-1", action: "chat_submit", params: params))
        XCTAssertEqual(firstResponse?.ok, true)
        XCTAssertEqual(appServerSubmitter.submissions.count, 1)

        let retryResponse = try handler.handle(BridgeRequest(id: "request-2", action: "chat_submit", params: params))
        XCTAssertEqual(retryResponse?.ok, true)
        XCTAssertEqual(retryResponse?.result?["deduplicated"]?.boolValue, true)
        XCTAssertEqual(appServerSubmitter.submissions.count, 1, "no second app-server submit for the deduplicated retry")
    }

    // P0 fix regression: when BOTH the direct app-server submit path and
    // the terminal fallback fail, the FIRST attempt must return an error —
    // and, critically, a network retry with the SAME client_request_id
    // must actually be attempted again (not dedup-suppressed as if the
    // first attempt had succeeded), because nothing was ever delivered.
    func testChatSubmitFirstAttemptFailsAndSameClientRequestIDRetryIsNotDeduplicated() throws {
        let sender = MockTideyRequestSender()
        sender.failAsNotOk = true
        let resolver = MockSessionResolver(session: ActiveAgentSessionSnapshot(vendor: "codex",
                                                                              workspaceID: "workspace-1",
                                                                              sessionID: "session-1",
                                                                              panelID: "panel-1"),
                                           recordsBySessionID: [
                                            "session-1": ordinaryCodexRecord(workspaceID: "workspace-1", panelID: "panel-1", sessionID: "session-1"),
                                           ])
        let registry = ChatSubmitEchoRegistry()
        let handler = BridgeInputActionHandler(socketSender: sender,
                                               sessionResolver: resolver,
                                               chatSubmitEchoRegistry: registry)
        let params: [String: JSONValue] = [
            "workspace_id": .string("workspace-1"),
            "panel_id": .string("panel-1"),
            "message": .string("hello never delivered"),
            "session_id": .string("session-1"),
            "vendor": .string("codex"),
            "client_request_id": .string("client-retry"),
        ]

        let firstResponse = try handler.handle(BridgeRequest(id: "request-1", action: "chat_submit", params: params))
        XCTAssertEqual(firstResponse?.ok, false, "nothing was delivered — the first attempt is an error")
        let firstCallCount = sender.sentRequests.count
        XCTAssertGreaterThan(firstCallCount, 0)

        // Retry with the EXACT SAME client_request_id: must NOT be
        // dedup-suppressed — the reservation was rolled back because
        // delivery never happened.
        let secondResponse = try handler.handle(BridgeRequest(id: "request-2", action: "chat_submit", params: params))
        XCTAssertEqual(secondResponse?.ok, false)
        XCTAssertNil(secondResponse?.result?["deduplicated"], "a failed attempt is not the 'deduplicated' success shape at all")
        XCTAssertGreaterThan(sender.sentRequests.count, firstCallCount,
                             "the retry actually re-attempted delivery — it was not silently swallowed as a duplicate")
    }

    // A retry with the SAME client_request_id AFTER a genuinely successful
    // submit must still be deduplicated — the rollback-on-failure fix must
    // not weaken the existing success-path dedupe contract.
    func testChatSubmitSameClientRequestIDRetryAfterSuccessIsStillDeduplicated() throws {
        let sender = MockTideyRequestSender()
        let resolver = MockSessionResolver(session: ActiveAgentSessionSnapshot(vendor: "codex",
                                                                              workspaceID: "workspace-1",
                                                                              sessionID: "session-1",
                                                                              panelID: "panel-1"),
                                           recordsBySessionID: [
                                            "session-1": ordinaryCodexRecord(workspaceID: "workspace-1", panelID: "panel-1", sessionID: "session-1"),
                                           ])
        let registry = ChatSubmitEchoRegistry()
        let handler = BridgeInputActionHandler(socketSender: sender,
                                               sessionResolver: resolver,
                                               chatSubmitEchoRegistry: registry)
        let params: [String: JSONValue] = [
            "workspace_id": .string("workspace-1"),
            "panel_id": .string("panel-1"),
            "message": .string("hello delivered once"),
            "session_id": .string("session-1"),
            "vendor": .string("codex"),
            "client_request_id": .string("client-success"),
        ]

        let firstResponse = try handler.handle(BridgeRequest(id: "request-1", action: "chat_submit", params: params))
        XCTAssertEqual(firstResponse?.ok, true)
        XCTAssertEqual(firstResponse?.result?["deduplicated"]?.boolValue, false)
        let firstCallCount = sender.sentRequests.count
        XCTAssertGreaterThan(firstCallCount, 0)

        let secondResponse = try handler.handle(BridgeRequest(id: "request-2", action: "chat_submit", params: params))
        XCTAssertEqual(secondResponse?.ok, true)
        XCTAssertEqual(secondResponse?.result?["deduplicated"]?.boolValue, true,
                       "the same id after a REAL success is still deduplicated")
        XCTAssertEqual(sender.sentRequests.count, firstCallCount, "no re-send for the deduplicated retry")
    }

    func testChatSubmitRegistersClientRequestIDForTranscriptEchoMatching() throws {
        let sender = MockTideyRequestSender()
        let resolver = MockSessionResolver(session: ActiveAgentSessionSnapshot(vendor: "codex",
                                                                              workspaceID: "workspace-1",
                                                                              sessionID: "session-1",
                                                                              panelID: "panel-1"),
                                           recordsBySessionID: [
                                            "session-1": ordinaryCodexRecord(workspaceID: "workspace-1", panelID: "panel-1", sessionID: "session-1"),
                                           ])
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
                                                                              panelID: "ordinary-panel"),
                                           recordsBySessionID: [
                                            "session-1": ordinaryCodexRecord(workspaceID: "workspace-1", panelID: "ordinary-panel", sessionID: "session-1"),
                                           ])
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
                                                                              panelID: "ordinary-panel"),
                                           recordsBySessionID: [
                                            "session-1": ordinaryCodexRecord(workspaceID: "workspace-1", panelID: "ordinary-panel", sessionID: "session-1"),
                                           ])
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
                                                                              panelID: "carrier-panel"),
                                           recordsBySessionID: [
                                            "session-1": ordinaryCodexRecord(workspaceID: "workspace-1", panelID: "carrier-panel", sessionID: "session-1"),
                                           ])
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
                                                                              panelID: "ordinary-panel"),
                                           recordsBySessionID: [
                                            "session-1": ordinaryCodexRecord(workspaceID: "workspace-1", panelID: "ordinary-panel", sessionID: "session-1"),
                                           ])
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
    // var (not let): a few regression tests simulate the registry record
    // becoming resolvable AFTER an initial fail-closed attempt (e.g. Bridge
    // just restarted and the registry catches up), by mutating this between
    // two handler.handle(...) calls with the SAME resolver instance.
    var recordsBySessionID: [String: AgentSessionRegistryRecord]

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
    // When set, EVERY send() fails this way (throw, or an ok:false
    // response) instead of succeeding — used to simulate "both direct
    // submit and terminal fallback fail" races.
    var failure: Error?
    var failAsNotOk = false
    // When set, only the call at this zero-based index (across the whole
    // mock's lifetime) fails — used to prove a LATER step failing after an
    // EARLIER one already succeeded (partial delivery).
    var failFromCallIndex: Int?

    func send(_ request: BridgeRequest) throws -> BridgeResponse {
        let callIndex = sentRequests.count
        sentRequests.append(request)
        if let failure {
            throw failure
        }
        if failAsNotOk || failFromCallIndex == callIndex {
            return BridgeResponse(id: request.id, ok: false, result: nil,
                                  error: BridgeErrorPayload(code: "SEND_FAILED", message: "simulated terminal failure"))
        }
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
        let clientRequestID: String?
    }

    private(set) var submissions = [Submission]()
    // Simulates a submitMessage() call racing into a busy error (a
    // concurrent app-server turn/started landed before the claim).
    var submitError: Error?

    func submitMessage(sessionID: String, text: String, clientRequestID: String?) throws {
        if let submitError {
            throw submitError
        }
        submissions.append(Submission(sessionID: sessionID, text: text, clientRequestID: clientRequestID))
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

// A RESOLVED registry record for an ordinary (non-app-server) Codex tmux
// session — `runtime` is nil, exactly like production's synthesized record
// for a plain tmux Codex panel. Used by ordinary-tmux-routing tests so they
// exercise "the record resolved to a confirmed non-app-server session",
// never the unresolved (activeRecord == nil) case, which now fails closed
// for vendor=codex regardless of whether the session is really app-server-
// backed — the recursion risk from HeadlessCodexTerminal means an
// unresolved record can never be assumed safe to terminal-fallback.
private func ordinaryCodexRecord(workspaceID: String, panelID: String, sessionID: String) -> AgentSessionRegistryRecord {
    AgentSessionRegistryRecord(version: 1,
                               vendor: "codex",
                               workspaceID: workspaceID,
                               sessionID: sessionID,
                               panelID: panelID,
                               pid: 123,
                               cwd: "/tmp",
                               createdAt: "2026-06-08T00:00:00Z",
                               transcriptPath: nil)
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
