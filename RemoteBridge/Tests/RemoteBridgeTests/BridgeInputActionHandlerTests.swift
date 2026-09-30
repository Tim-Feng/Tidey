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

    func testTUICommandSubmitForCodexUsesStandaloneEnterAfterDelay() throws {
        let sender = MockTideyRequestSender()
        let resolver = MockSessionResolver(
            session: ActiveAgentSessionSnapshot(vendor: "codex",
                                                workspaceID: "workspace-1",
                                                sessionID: "session-1",
                                                panelID: "panel-1"),
            recordsBySessionID: ["session-1": appServerRecord()]
        )
        let appServerSubmitter = MockCodexAppServerChatSubmitter()
        let delayRecorder = DelayRecorder()
        let handler = BridgeInputActionHandler(socketSender: sender,
                                               sessionResolver: resolver,
                                               codexAppServerChatSubmitter: appServerSubmitter,
                                               sleep: { delayRecorder.record($0) })

        let response = try handler.handle(BridgeRequest(id: "request-1",
                                                        action: "tui_command_submit",
                                                        params: [
                                                            "workspace_id": .string("workspace-1"),
                                                            "panel_id": .string("panel-1"),
                                                            "command": .string("/status"),
                                                            "session_id": .string("session-1"),
                                                            "vendor": .string("codex"),
                                                        ]))

        XCTAssertEqual(response?.ok, true)
        XCTAssertEqual(sender.sentRequests.map(\.action), ["send_input", "send_key"])
        XCTAssertEqual(sender.sentRequests.first?.params?["input"]?.stringValue, "/status")
        XCTAssertEqual(sender.sentRequests.last?.params?["key"]?.stringValue, "enter")
        XCTAssertEqual(delayRecorder.recordedDelays, [chatSubmitEnterDelayNanoseconds])
        XCTAssertTrue(appServerSubmitter.submissions.isEmpty,
                      "a TUI command must execute in the terminal even for an app-server-backed Codex session")
    }

    func testTUICommandSubmitWaitsForOrdinaryTmuxPastePresentationBeforeEnter() throws {
        let sender = MockTideyRequestSender()
        let resolver = MockSessionResolver(session: ActiveAgentSessionSnapshot(vendor: "codex",
                                                                              workspaceID: "workspace-1",
                                                                              sessionID: "session-1",
                                                                              panelID: "ordinary-panel"))
        let router = MockOrdinaryTmuxInputRouter(
            routedPanelIDs: ["ordinary-panel"],
            pastePresentationResults: [true]
        )
        let delayRecorder = DelayRecorder()
        let handler = BridgeInputActionHandler(socketSender: sender,
                                               sessionResolver: resolver,
                                               ordinaryTmuxInputRouter: router,
                                               sleep: { delayRecorder.record($0) })

        let response = try handler.handle(BridgeRequest(id: "request-1",
                                                        action: "tui_command_submit",
                                                        params: [
                                                            "workspace_id": .string("workspace-1"),
                                                            "panel_id": .string("ordinary-panel"),
                                                            "command": .string("/status"),
                                                            "session_id": .string("session-1"),
                                                            "vendor": .string("codex"),
                                                        ]))

        XCTAssertEqual(response?.ok, true)
        XCTAssertTrue(sender.sentRequests.isEmpty)
        XCTAssertEqual(router.presentationWaitPanelIDs, ["ordinary-panel"])
        XCTAssertEqual(router.sentInputs.map(\.input), ["/status", "\r"])
        XCTAssertEqual(Set(router.sentInputs.compactMap(\.submissionID)).count, 1)
        XCTAssertNotNil(router.sentInputs.first?.submissionID)
        XCTAssertEqual(
            router.presentationWaitSubmissionIDs,
            [router.sentInputs.first?.submissionID]
        )
        XCTAssertEqual(router.sentInputs.map(\.mode), [.literalChatText, .rawTerminalInput])
        XCTAssertEqual(router.sentInputs.map(\.allowAmbiguousPasteTimeout), [true, true])
        XCTAssertEqual(delayRecorder.recordedDelays, [chatSubmitEnterDelayNanoseconds])
    }

    func testTUICommandSubmitWithoutPastePresentationProofSendsNoEnter() throws {
        let sender = MockTideyRequestSender()
        let resolver = MockSessionResolver(
            session: ActiveAgentSessionSnapshot(
                vendor: "claude",
                workspaceID: "workspace-1",
                sessionID: "session-1",
                panelID: "ordinary-panel"
            )
        )
        let router = MockOrdinaryTmuxInputRouter(
            routedPanelIDs: ["ordinary-panel"],
            pastePresentationResults: [false]
        )
        let handler = BridgeInputActionHandler(
            socketSender: sender,
            sessionResolver: resolver,
            ordinaryTmuxInputRouter: router,
            sleep: { _ in }
        )

        XCTAssertThrowsError(
            try handler.handle(
                BridgeRequest(
                    id: "request-1",
                    action: "tui_command_submit",
                    params: [
                        "workspace_id": .string("workspace-1"),
                        "panel_id": .string("ordinary-panel"),
                        "command": .string("/model"),
                        "session_id": .string("session-1"),
                        "vendor": .string("claude"),
                    ]
                )
            )
        )
        XCTAssertEqual(router.presentationWaitPanelIDs, ["ordinary-panel"])
        XCTAssertEqual(router.sentInputs.map(\.input), ["/model"])
        XCTAssertTrue(sender.sentRequests.isEmpty)
    }

    func testTUICommandSubmitFailsWhenStandaloneEnterDispatchFails() throws {
        let sender = MockTideyRequestSender()
        sender.failFromCallIndex = 1
        let resolver = MockSessionResolver(session: ActiveAgentSessionSnapshot(vendor: "claude",
                                                                              workspaceID: "workspace-1",
                                                                              sessionID: "session-1",
                                                                              panelID: "panel-1"))
        let handler = BridgeInputActionHandler(socketSender: sender,
                                               sessionResolver: resolver,
                                               sleep: { _ in })

        let response = try handler.handle(BridgeRequest(id: "request-1",
                                                        action: "tui_command_submit",
                                                        params: [
                                                            "workspace_id": .string("workspace-1"),
                                                            "panel_id": .string("panel-1"),
                                                            "command": .string("/context"),
                                                            "session_id": .string("session-1"),
                                                            "vendor": .string("claude"),
                                                        ]))

        XCTAssertEqual(response?.ok, false)
        XCTAssertEqual(response?.error?.code, "SEND_FAILED")
        XCTAssertEqual(sender.sentRequests.map(\.action), ["send_input", "send_key"])
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

    func testChatSubmitStopsBeforeEnterWhenRouteChangesDuringDelay() throws {
        let sender = MockTideyRequestSender()
        let resolver = MockSessionResolver(session: ActiveAgentSessionSnapshot(vendor: "claude",
                                                                              workspaceID: "workspace-1",
                                                                              sessionID: "session-A",
                                                                              panelID: "panel-1"))
        let handler = BridgeInputActionHandler(
            socketSender: sender,
            sessionResolver: resolver,
            sleep: { _ in
                resolver.session = ActiveAgentSessionSnapshot(vendor: "claude",
                                                              workspaceID: "workspace-1",
                                                              sessionID: "session-B",
                                                              panelID: "panel-1")
            }
        )

        XCTAssertThrowsError(
            try handler.handle(BridgeRequest(id: "request-handoff",
                                             action: "chat_submit",
                                             params: [
                                                "workspace_id": .string("workspace-1"),
                                                "panel_id": .string("panel-1"),
                                                "message": .string("handoff race"),
                                                "session_id": .string("session-A"),
                                                "vendor": .string("claude"),
                                             ]))
        )
        XCTAssertEqual(sender.sentRequests.map(\.action), ["send_input"],
                       "the stale A submission must not send Enter into replacement session B")
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
        let registry = ChatSubmitEchoRegistry()
        let handler = BridgeInputActionHandler(socketSender: sender,
                                               sessionResolver: resolver,
                                               codexAppServerChatSubmitter: appServerSubmitter,
                                               chatSubmitEchoRegistry: registry)

        let params: [String: JSONValue] = [
            "workspace_id": .string("workspace-1"),
            "panel_id": .string("panel-1"),
            "message": .string("hello from remote"),
            "session_id": .string("session-1"),
            "vendor": .string("codex"),
            "client_request_id": .string("client-1"),
        ]
        let response = try handler.handle(BridgeRequest(id: "request-1",
                                                        action: "chat_submit",
                                                        params: params))
        let duplicate = try handler.handle(BridgeRequest(id: "request-2",
                                                         action: "chat_submit",
                                                         params: params))

        XCTAssertEqual(response?.ok, true)
        XCTAssertEqual(duplicate?.result?["deduplicated"]?.boolValue, true)
        XCTAssertTrue(sender.sentRequests.isEmpty)
        XCTAssertEqual(appServerSubmitter.submissions, [
            MockCodexAppServerChatSubmitter.Submission(sessionID: "session-1",
                                                       text: "hello from remote",
                                                       clientRequestID: "client-1"),
        ])
    }

    func testCodexAppServerSubmitRejectsRouteThatChangesBeforeDispatch() throws {
        let sender = MockTideyRequestSender()
        let resolver = MockSessionResolver(
            session: ActiveAgentSessionSnapshot(vendor: "codex",
                                                workspaceID: "workspace-1",
                                                sessionID: "session-1",
                                                panelID: "panel-1"),
            recordsBySessionID: ["session-1": appServerRecord()]
        )
        resolver.onActiveRecord = {
            resolver.session = ActiveAgentSessionSnapshot(vendor: "codex",
                                                          workspaceID: "workspace-1",
                                                          sessionID: "session-B",
                                                          panelID: "panel-1")
        }
        let appServerSubmitter = MockCodexAppServerChatSubmitter()
        let handler = BridgeInputActionHandler(socketSender: sender,
                                               sessionResolver: resolver,
                                               codexAppServerChatSubmitter: appServerSubmitter)

        XCTAssertThrowsError(
            try handler.handle(BridgeRequest(id: "request-handoff",
                                             action: "chat_submit",
                                             params: [
                                                "workspace_id": .string("workspace-1"),
                                                "panel_id": .string("panel-1"),
                                                "message": .string("handoff race"),
                                                "session_id": .string("session-1"),
                                                "vendor": .string("codex"),
                                             ]))
        )
        XCTAssertTrue(appServerSubmitter.attempts.isEmpty)
        XCTAssertTrue(sender.sentRequests.isEmpty)
    }

    func testChatSubmitForCodexAppServerRuntimeSkipsCanSubmitPrecheck() throws {
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
                                                            "message": .string("hello via atomic submit"),
                                                            "session_id": .string("session-1"),
                                                            "vendor": .string("codex"),
                                                        ]))

        XCTAssertEqual(response?.ok, true)
        XCTAssertEqual(appServerSubmitter.canSubmitCallCount, 0,
                       "the diagnostic pre-check is a TOCTOU race and must not route submissions")
        XCTAssertEqual(appServerSubmitter.submissions, [
            MockCodexAppServerChatSubmitter.Submission(sessionID: "session-1",
                                                       text: "hello via atomic submit",
                                                       clientRequestID: nil),
        ])
        XCTAssertTrue(sender.sentRequests.isEmpty)
    }

    func testChatSubmitForCodexAppServerRuntimeFailsClosedWhenSubmitterMissing() throws {
        let sender = MockTideyRequestSender()
        let resolver = MockSessionResolver(
            session: ActiveAgentSessionSnapshot(vendor: "codex",
                                                workspaceID: "workspace-1",
                                                sessionID: "session-1",
                                                panelID: "panel-1"),
            recordsBySessionID: ["session-1": appServerRecord()])
        let handler = BridgeInputActionHandler(socketSender: sender,
                                               sessionResolver: resolver)

        let response = try handler.handle(BridgeRequest(id: "request-1",
                                                        action: "chat_submit",
                                                        params: chatSubmitParams(message: "no submitter",
                                                                                 clientRequestID: "client-missing")))

        XCTAssertEqual(response?.ok, false)
        XCTAssertEqual(response?.error?.code, "CONFLICT")
        XCTAssertTrue(sender.sentRequests.isEmpty,
                      "a headless app-server pane must never receive terminal fallback input")
    }

    func testChatSubmitMapsZeroEffectAppServerFailuresToRetryableConflict() throws {
        let failures: [(CodexAppServerSubmitFailure, String)] = [
            (.busyWithoutTurnID, "busy"),
            (.rejected("turn rejected"), "rejected"),
            (.unavailableBeforeSend("runtime unavailable"), "unavailable"),
        ]

        for (failure, suffix) in failures {
            let sender = MockTideyRequestSender()
            let resolver = MockSessionResolver(
                session: ActiveAgentSessionSnapshot(vendor: "codex",
                                                    workspaceID: "workspace-1",
                                                    sessionID: "session-1",
                                                    panelID: "panel-1"),
                recordsBySessionID: ["session-1": appServerRecord()])
            let submitter = MockCodexAppServerChatSubmitter()
            submitter.submitError = failure
            let handler = BridgeInputActionHandler(socketSender: sender,
                                                   sessionResolver: resolver,
                                                   codexAppServerChatSubmitter: submitter,
                                                   chatSubmitEchoRegistry: ChatSubmitEchoRegistry())
            let params = chatSubmitParams(message: "message-\(suffix)",
                                          clientRequestID: "client-\(suffix)")

            let response = try handler.handle(BridgeRequest(id: "first-\(suffix)",
                                                            action: "chat_submit",
                                                            params: params))

            XCTAssertEqual(response?.ok, false, suffix)
            XCTAssertEqual(response?.error?.code, "CONFLICT", suffix)
            XCTAssertTrue(sender.sentRequests.isEmpty, suffix)
            XCTAssertEqual(submitter.attempts.count, 1, suffix)

            submitter.submitError = nil
            let retry = try handler.handle(BridgeRequest(id: "retry-\(suffix)",
                                                         action: "chat_submit",
                                                         params: params))
            XCTAssertEqual(retry?.ok, true, suffix)
            XCTAssertEqual(submitter.attempts.count, 2,
                           "a proven zero-effect outcome releases the request ID: \(suffix)")
        }
    }

    func testChatSubmitResolvesAppServerRecordFromRequestedSessionID() throws {
        let sender = MockTideyRequestSender()
        let resolver = MockSessionResolver(
            session: nil,
            recordsBySessionID: ["session-1": appServerRecord()])
        let submitter = MockCodexAppServerChatSubmitter()
        let handler = BridgeInputActionHandler(socketSender: sender,
                                               sessionResolver: resolver,
                                               codexAppServerChatSubmitter: submitter)

        let response = try handler.handle(BridgeRequest(id: "request-1",
                                                        action: "chat_submit",
                                                        params: chatSubmitParams(message: "requested-session route",
                                                                                 clientRequestID: "client-requested")))

        XCTAssertEqual(response?.ok, true)
        XCTAssertEqual(submitter.submissions.count, 1)
        XCTAssertTrue(sender.sentRequests.isEmpty)
    }

    func testChatSubmitRejectsRequestedSessionRecordOutsideRequestScope() {
        let records = [
            appServerRecord(workspaceID: "other-workspace"),
            appServerRecord(panelID: "other-panel"),
            appServerRecord(vendor: "claude"),
        ]

        for record in records {
            let sender = MockTideyRequestSender()
            let resolver = MockSessionResolver(session: nil,
                                               recordsBySessionID: ["session-1": record])
            let submitter = MockCodexAppServerChatSubmitter()
            let handler = BridgeInputActionHandler(socketSender: sender,
                                                   sessionResolver: resolver,
                                                   codexAppServerChatSubmitter: submitter)

            XCTAssertThrowsError(try handler.handle(BridgeRequest(
                id: "request-1",
                action: "chat_submit",
                params: chatSubmitParams(message: "wrong scope",
                                         clientRequestID: "client-scope"))))
            XCTAssertTrue(submitter.attempts.isEmpty)
            XCTAssertTrue(sender.sentRequests.isEmpty)
        }
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

    func testChatSubmitDuplicateWhileOriginalIsPendingReturnsConflict() throws {
        let sender = MockTideyRequestSender()
        let resolver = MockSessionResolver(session: ActiveAgentSessionSnapshot(vendor: "codex",
                                                                              workspaceID: "workspace-1",
                                                                              sessionID: "session-1",
                                                                              panelID: "panel-1"))
        let registry = ChatSubmitEchoRegistry()
        let handler = BridgeInputActionHandler(socketSender: sender,
                                               sessionResolver: resolver,
                                               chatSubmitEchoRegistry: registry)
        _ = registry.beginSubmission(workspaceID: "workspace-1",
                                     panelID: "panel-1",
                                     sessionID: "session-1",
                                     vendor: "codex",
                                     clientRequestID: "client-pending")

        let response = try handler.handle(BridgeRequest(id: "request-1",
                                                        action: "chat_submit",
                                                        params: chatSubmitParams(message: "pending duplicate",
                                                                                 clientRequestID: "client-pending")))

        XCTAssertEqual(response?.ok, false)
        XCTAssertEqual(response?.error?.code, "CONFLICT")
        XCTAssertTrue(sender.sentRequests.isEmpty)
    }

    func testChatSubmitPartialTerminalDeliveryMakesRetryIndeterminate() throws {
        let sender = MockTideyRequestSender()
        sender.failFromCallIndex = 1
        let resolver = MockSessionResolver(session: ActiveAgentSessionSnapshot(vendor: "codex",
                                                                              workspaceID: "workspace-1",
                                                                              sessionID: "session-1",
                                                                              panelID: "panel-1"))
        let registry = ChatSubmitEchoRegistry()
        let handler = BridgeInputActionHandler(socketSender: sender,
                                               sessionResolver: resolver,
                                               chatSubmitEchoRegistry: registry)
        let params = chatSubmitParams(message: "partial delivery",
                                      clientRequestID: "client-partial")

        let first = try handler.handle(BridgeRequest(id: "request-1", action: "chat_submit", params: params))
        XCTAssertEqual(first?.ok, false)
        XCTAssertEqual(sender.sentRequests.map(\.action), ["send_input", "send_key"])

        let sentCountAfterFirst = sender.sentRequests.count
        let retry = try handler.handle(BridgeRequest(id: "request-2", action: "chat_submit", params: params))

        XCTAssertEqual(retry?.ok, false)
        XCTAssertEqual(retry?.error?.code, "CONFLICT")
        XCTAssertEqual(sender.sentRequests.count, sentCountAfterFirst,
                       "an indeterminate duplicate must not resend text that may already be visible")
    }

    func testChatSubmitZeroEffectFailureCancelsReservationForRetry() throws {
        let sender = MockTideyRequestSender()
        sender.failAsNotOk = true
        let resolver = MockSessionResolver(session: ActiveAgentSessionSnapshot(vendor: "codex",
                                                                              workspaceID: "workspace-1",
                                                                              sessionID: "session-1",
                                                                              panelID: "panel-1"))
        let registry = ChatSubmitEchoRegistry()
        let handler = BridgeInputActionHandler(socketSender: sender,
                                               sessionResolver: resolver,
                                               chatSubmitEchoRegistry: registry)
        let params = chatSubmitParams(message: "not delivered",
                                      clientRequestID: "client-retry")

        let first = try handler.handle(BridgeRequest(id: "request-1", action: "chat_submit", params: params))
        XCTAssertEqual(first?.ok, false)
        let firstCallCount = sender.sentRequests.count

        let retry = try handler.handle(BridgeRequest(id: "request-2", action: "chat_submit", params: params))

        XCTAssertEqual(retry?.ok, false)
        XCTAssertGreaterThan(sender.sentRequests.count, firstCallCount,
                             "a provably zero-effect failure must release the request id for a real retry")
    }

    func testChatSubmitAppServerTransportFailureMakesRetryIndeterminate() throws {
        struct TransportError: Error {}

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
        let submitter = MockCodexAppServerChatSubmitter()
        submitter.submitError = TransportError()
        let registry = ChatSubmitEchoRegistry()
        let handler = BridgeInputActionHandler(socketSender: sender,
                                               sessionResolver: resolver,
                                               codexAppServerChatSubmitter: submitter,
                                               chatSubmitEchoRegistry: registry)
        let params = chatSubmitParams(message: "unknown outcome",
                                      clientRequestID: "client-app-server")

        XCTAssertThrowsError(try handler.handle(BridgeRequest(id: "request-1",
                                                              action: "chat_submit",
                                                              params: params)))
        let retry = try handler.handle(BridgeRequest(id: "request-2", action: "chat_submit", params: params))

        XCTAssertEqual(retry?.ok, false)
        XCTAssertEqual(retry?.error?.code, "CONFLICT")
        XCTAssertTrue(sender.sentRequests.isEmpty)
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

    // MARK: - Post-submit composer check (swallowed Enter safety net)

    private struct ComposerHarness {
        let handler: BridgeInputActionHandler
        let router: MockOrdinaryTmuxInputRouter
        let sender: MockTideyRequestSender
        let executor: DeferredComposerCheckExecutor
        let checkDelays: DelayRecorder
    }

    private func makeComposerHarness(vendor: String = "claude",
                                     screens: [OrdinaryTmuxComposerScreen?],
                                     routed: Bool = true,
                                     pastePresentationResults: [Bool] = []) -> ComposerHarness {
        let sender = MockTideyRequestSender()
        let resolver = MockSessionResolver(session: ActiveAgentSessionSnapshot(vendor: vendor,
                                                                              workspaceID: "workspace-1",
                                                                              sessionID: "session-1",
                                                                              panelID: "ordinary-panel"))
        let router = MockOrdinaryTmuxInputRouter(routedPanelIDs: routed ? ["ordinary-panel"] : [],
                                                 pastePresentationResults: pastePresentationResults)
        router.composerScreens = screens.map { .success($0) }
        let executor = DeferredComposerCheckExecutor()
        let checkDelays = DelayRecorder()
        let composerRetry = ChatSubmitComposerRetry(router: router,
                                                    sleep: { checkDelays.record($0) },
                                                    executor: executor.executor)
        let handler = BridgeInputActionHandler(socketSender: sender,
                                               sessionResolver: resolver,
                                               ordinaryTmuxInputRouter: router,
                                               composerRetry: composerRetry,
                                               sleep: { _ in })
        return ComposerHarness(handler: handler, router: router, sender: sender,
                               executor: executor, checkDelays: checkDelays)
    }

    @discardableResult
    private func submit(_ harness: ComposerHarness,
                        message: String,
                        vendor: String = "claude",
                        id: String = "request-1",
                        action: String = "chat_submit") throws -> BridgeResponse? {
        var params: [String: JSONValue] = [
            "workspace_id": .string("workspace-1"),
            "panel_id": .string("ordinary-panel"),
            "session_id": .string("session-1"),
            "vendor": .string(vendor),
        ]
        params[action == "chat_submit" ? "message" : "command"] = .string(message)
        return try harness.handler.handle(BridgeRequest(id: id, action: action, params: params))
    }

    private func claudeScreen(_ box: String, pane: String = "%7") -> OrdinaryTmuxComposerScreen {
        OrdinaryTmuxComposerScreen(paneID: pane, screen: ComposerScreenBuilder.claude(box: [box]))
    }

    private func enterCount(_ router: MockOrdinaryTmuxInputRouter) -> Int {
        router.sentInputs.filter { $0.input == "\r" }.count
    }

    func testComposerCheckRunsAfterTheChatSubmitResponse() throws {
        let harness = makeComposerHarness(screens: [claudeScreen("❯\u{a0}")])
        let response = try submit(harness, message: "hello")

        XCTAssertEqual(response?.ok, true)
        XCTAssertEqual(harness.executor.pendingCount, 1, "the check is queued, not run inline")
        XCTAssertTrue(harness.router.composerCapturePanelIDs.isEmpty,
                      "no capture may happen before the response is returned")
        harness.executor.runAll()
        XCTAssertEqual(harness.router.composerCapturePanelIDs, ["ordinary-panel"])
        XCTAssertEqual(harness.checkDelays.recordedDelays, [ChatSubmitComposerRetry.checkDelayNanoseconds])
    }

    func testEmptyComposerNeedsNoRetry() throws {
        let harness = makeComposerHarness(screens: [claudeScreen("❯\u{a0}")])
        try submit(harness, message: "hello")
        harness.executor.runAll()
        XCTAssertTrue(harness.router.retryEnters.isEmpty)
        XCTAssertEqual(enterCount(harness.router), 1)
    }

    func testMessageStillInTheComposerTwiceGetsExactlyOneRetryEnterIntoTheCheckedPane() throws {
        let stuck = claudeScreen("❯\u{a0}這是測試訊息第三行", pane: "%7")
        let harness = makeComposerHarness(screens: [stuck, stuck, claudeScreen("❯\u{a0}", pane: "%7")])
        try submit(harness, message: "這是測試訊息第一行\n這是測試訊息第三行")
        harness.executor.runAll()

        XCTAssertEqual(harness.router.retryEnters.map(\.paneID), ["%7"])
        XCTAssertEqual(harness.router.composerCapturePanelIDs.count, 3, "two checks, one confirmation")
        XCTAssertEqual(harness.checkDelays.recordedDelays.count, 3)
    }

    func testComposerThatClearsOnTheSecondCheckIsNotRetried() throws {
        // Busy Claude: Enter queued the message; the redraw lagged one check.
        let harness = makeComposerHarness(screens: [claudeScreen("❯\u{a0}hello"), claudeScreen("❯\u{a0}")])
        try submit(harness, message: "hello")
        harness.executor.runAll()
        XCTAssertTrue(harness.router.retryEnters.isEmpty)
    }

    func testStillStuckAfterTheRetryIsNeverRetriedAgain() throws {
        let stuck = claudeScreen("❯\u{a0}hello")
        let harness = makeComposerHarness(screens: [stuck, stuck, stuck, stuck])
        try submit(harness, message: "hello")
        harness.executor.runAll()
        XCTAssertEqual(harness.router.retryEnters.count, 1)
        XCTAssertEqual(harness.router.composerCapturePanelIDs.count, 3)
    }

    func testDialogUnknownAndOtherTextAreNeverRetried() throws {
        let cases: [(String, OrdinaryTmuxComposerScreen?)] = [
            ("dialog", claudeScreen("❯\u{a0}1. Yes")),
            ("unknown", OrdinaryTmuxComposerScreen(paneID: "%7", screen: "plain shell output")),
            ("no route", nil),
            ("other text", claudeScreen("❯\u{a0}好了我再看")),
        ]
        for (label, screen) in cases {
            let harness = makeComposerHarness(screens: [screen, screen])
            try submit(harness, message: "好")
            harness.executor.runAll()
            XCTAssertTrue(harness.router.retryEnters.isEmpty, label)
            XCTAssertEqual(harness.router.composerCapturePanelIDs.count, 1, label)
        }
    }

    func testCaptureErrorIsNeverRetried() throws {
        let harness = makeComposerHarness(screens: [])
        harness.router.composerScreens = [.failure(tmuxTimeoutError())]
        try submit(harness, message: "hello")
        harness.executor.runAll()
        XCTAssertTrue(harness.router.retryEnters.isEmpty)
    }

    func testQuestionInTheConversationDoesNotDisableTheCheck() throws {
        let stuck = OrdinaryTmuxComposerScreen(paneID: "%7",
                                               screen: ComposerScreenBuilder.claude(history: ["⏺ Do you want to deploy?"],
                                                                                    box: ["❯\u{a0}好"]))
        let harness = makeComposerHarness(screens: [stuck, stuck, claudeScreen("❯\u{a0}")])
        try submit(harness, message: "好")
        harness.executor.runAll()
        XCTAssertEqual(harness.router.retryEnters.count, 1)
    }

    func testRetryIsSkippedWhileAnotherSubmissionOwnsThePanelOrThePaneChanged() throws {
        for outcome in [OrdinaryTmuxComposerRetryOutcome.busy, .paneChanged] {
            let stuck = claudeScreen("❯\u{a0}hello")
            let harness = makeComposerHarness(screens: [stuck, stuck, stuck])
            harness.router.retryOutcomes = [outcome]
            try submit(harness, message: "hello")
            harness.executor.runAll()
            XCTAssertEqual(harness.router.retryEnters.count, 1, outcome.rawValue)
            XCTAssertEqual(harness.router.composerCapturePanelIDs.count, 2,
                           "\(outcome.rawValue): no confirmation check after a skipped retry")
        }
        // The pane moved between the two checks: no retry is attempted at all.
        let harness = makeComposerHarness(screens: [claudeScreen("❯\u{a0}hello", pane: "%7"),
                                                    claudeScreen("❯\u{a0}hello", pane: "%8")])
        try submit(harness, message: "hello")
        harness.executor.runAll()
        XCTAssertTrue(harness.router.retryEnters.isEmpty)
    }

    func testANewChatSubmitOnThePanelCancelsThePendingCheck() throws {
        let stuck = claudeScreen("❯\u{a0}second")
        let harness = makeComposerHarness(screens: [stuck, stuck, claudeScreen("❯\u{a0}")])
        try submit(harness, message: "first", id: "request-1")
        try submit(harness, message: "second", id: "request-2")
        XCTAssertEqual(harness.executor.pendingCount, 2)
        harness.executor.runAll()

        // The first check is stale: it sleeps once and stops without capturing.
        XCTAssertEqual(harness.router.composerCapturePanelIDs.count, 3,
                       "only the second submission's check (2 checks + confirmation) captures")
        XCTAssertEqual(harness.router.retryEnters.count, 1)
        XCTAssertEqual(enterCount(harness.router), 2, "one Enter per chat_submit")
    }

    func testCodexChatSubmitIsCheckedWithTheCodexComposerRules() throws {
        let stuck = OrdinaryTmuxComposerScreen(paneID: "%24",
                                               screen: ComposerScreenBuilder.codex(composer: ["› hello codex"]))
        let empty = OrdinaryTmuxComposerScreen(paneID: "%24", screen: RealComposerScreens.codexIdle)
        let harness = makeComposerHarness(vendor: "codex", screens: [stuck, stuck, empty])
        try submit(harness, message: "hello codex", vendor: "codex")
        harness.executor.runAll()
        XCTAssertEqual(harness.router.retryEnters.map(\.paneID), ["%24"])
    }

    func testTUICommandsAndMacSocketFallbackAreNotChecked() throws {
        let stuck = claudeScreen("❯\u{a0}/status")
        let tui = makeComposerHarness(vendor: "codex", screens: [stuck, stuck], pastePresentationResults: [true])
        XCTAssertEqual(try submit(tui, message: "/status", vendor: "codex", action: "tui_command_submit")?.ok, true)
        XCTAssertEqual(enterCount(tui.router), 1)
        XCTAssertEqual(tui.executor.pendingCount, 0)

        let fallback = makeComposerHarness(screens: [stuck, stuck], routed: false)
        try submit(fallback, message: "hello")
        XCTAssertEqual(fallback.sender.sentRequests.map(\.action), ["send_input", "send_key"])
        XCTAssertEqual(fallback.executor.pendingCount, 0)
    }
}

private final class MockSessionResolver: ActiveAgentSessionResolving {
    var session: ActiveAgentSessionSnapshot?
    var onActiveRecord: (() -> Void)?
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
        let record = recordsBySessionID[sessionID]
        onActiveRecord?()
        return record
    }
}

private final class MockTideyRequestSender: TideyRequestSending {
    private(set) var sentRequests = [BridgeRequest]()
    var failAsNotOk = false
    var failFromCallIndex: Int?

    func send(_ request: BridgeRequest) throws -> BridgeResponse {
        let callIndex = sentRequests.count
        sentRequests.append(request)
        if failAsNotOk || failFromCallIndex == callIndex {
            return BridgeResponse(id: request.id,
                                  ok: false,
                                  result: nil,
                                  error: BridgeErrorPayload(code: "SEND_FAILED", message: "simulated failure"))
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
    private(set) var attempts = [Submission]()
    private(set) var canSubmitCallCount = 0
    var canSubmit = true
    var submitError: Error?

    func canSubmitMessage(sessionID: String) -> Bool {
        canSubmitCallCount += 1
        return canSubmit
    }

    func submitMessage(sessionID: String, text: String) throws {
        try submitMessage(sessionID: sessionID, text: text, clientRequestID: nil)
    }

    func submitMessage(sessionID: String, text: String, clientRequestID: String?) throws {
        let submission = Submission(sessionID: sessionID,
                                    text: text,
                                    clientRequestID: clientRequestID)
        attempts.append(submission)
        if let submitError {
            throw submitError
        }
        submissions.append(submission)
    }
}

private func appServerRecord(workspaceID: String = "workspace-1",
                             panelID: String = "panel-1",
                             vendor: String = "codex") -> AgentSessionRegistryRecord {
    AgentSessionRegistryRecord(version: 1,
                               vendor: vendor,
                               workspaceID: workspaceID,
                               sessionID: "session-1",
                               panelID: panelID,
                               pid: 123,
                               cwd: "/tmp",
                               createdAt: "2026-06-08T00:00:00Z",
                               transcriptPath: nil,
                               runtime: "codex_app_server",
                               appServerSocket: "/tmp/app.sock",
                               appServerPID: 456)
}

private func chatSubmitParams(message: String,
                              clientRequestID: String) -> [String: JSONValue] {
    [
        "workspace_id": .string("workspace-1"),
        "panel_id": .string("panel-1"),
        "message": .string(message),
        "session_id": .string("session-1"),
        "vendor": .string("codex"),
        "client_request_id": .string(clientRequestID),
    ]
}

private final class MockOrdinaryTmuxInputRouter: OrdinaryTmuxInputRouting, @unchecked Sendable {
    private let routedPanelIDs: Set<String>
    private let errorsByPanelID: [String: Error]
    private var pastePresentationResults: [Bool]
    private(set) var sentInputs = [(panelID: String, input: String, mode: OrdinaryTmuxInputMode, allowAmbiguousPasteTimeout: Bool, submissionID: String?)]()
    private(set) var presentationWaitPanelIDs = [String]()
    private(set) var presentationWaitSubmissionIDs = [String?]()

    init(routedPanelIDs: Set<String>,
         errorsByPanelID: [String: Error] = [:],
         pastePresentationResults: [Bool] = []) {
        self.routedPanelIDs = routedPanelIDs
        self.errorsByPanelID = errorsByPanelID
        self.pastePresentationResults = pastePresentationResults
    }

    func sendInput(_ input: String,
                   toPanelID panelID: String,
                   mode: OrdinaryTmuxInputMode,
                   allowAmbiguousPasteTimeout: Bool) throws -> Bool {
        try sendInput(
            input,
            toPanelID: panelID,
            mode: mode,
            allowAmbiguousPasteTimeout: allowAmbiguousPasteTimeout,
            submissionID: nil
        )
    }

    func sendInput(_ input: String,
                   toPanelID panelID: String,
                   mode: OrdinaryTmuxInputMode,
                   allowAmbiguousPasteTimeout: Bool,
                   submissionID: String?) throws -> Bool {
        guard routedPanelIDs.contains(panelID) else {
            return false
        }
        sentInputs.append((panelID, input, mode, allowAmbiguousPasteTimeout, submissionID))
        if let error = errorsByPanelID[panelID] {
            throw error
        }
        return true
    }

    func waitForLastPastePresentation(toPanelID panelID: String) throws -> Bool {
        presentationWaitPanelIDs.append(panelID)
        presentationWaitSubmissionIDs.append(nil)
        guard pastePresentationResults.isEmpty == false else { return false }
        return pastePresentationResults.removeFirst()
    }

    func waitForLastPastePresentation(toPanelID panelID: String,
                                      submissionID: String) throws -> Bool {
        presentationWaitPanelIDs.append(panelID)
        presentationWaitSubmissionIDs.append(submissionID)
        guard pastePresentationResults.isEmpty == false else { return false }
        return pastePresentationResults.removeFirst()
    }

    // Post-submit composer check: screens are served in order; an exhausted
    // queue means "no route" (nil).
    var composerScreens = [Result<OrdinaryTmuxComposerScreen?, Error>]()
    private(set) var composerCapturePanelIDs = [String]()
    var retryOutcomes = [OrdinaryTmuxComposerRetryOutcome]()
    private(set) var retryEnters = [(panelID: String, paneID: String)]()

    func captureComposerScreen(toPanelID panelID: String) throws -> OrdinaryTmuxComposerScreen? {
        composerCapturePanelIDs.append(panelID)
        guard composerScreens.isEmpty == false else { return nil }
        return try composerScreens.removeFirst().get()
    }

    func sendComposerRetryEnter(toPanelID panelID: String,
                                expectedPaneID: String) throws -> OrdinaryTmuxComposerRetryOutcome {
        retryEnters.append((panelID, expectedPaneID))
        return retryOutcomes.isEmpty ? .sent : retryOutcomes.removeFirst()
    }
}

/// Holds the background composer check until the test releases it, so a
/// test can assert on the chat_submit response BEFORE the check runs.
private final class DeferredComposerCheckExecutor: @unchecked Sendable {
    private var pending = [() -> Void]()

    var executor: ChatSubmitComposerRetry.Executor {
        { [self] work in pending.append(work) }
    }

    var pendingCount: Int { pending.count }

    func runAll() {
        while pending.isEmpty == false {
            pending.removeFirst()()
        }
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
