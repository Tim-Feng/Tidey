import XCTest
@testable import RemoteBridge

final class InteractivePromptActionHandlerTests: XCTestCase {
    func testProbePublishesWorkflowConfirmPromptEvent() throws {
        let route = ordinaryRoute()
        let eventHub = AgentEventHub()
        let adapter = StubPromptAdapter(outputs: [Self.workflowConfirmOutput(selectedOption: 1)])
        let handler = makeHandler(route: route,
                                  adapter: adapter,
                                  eventHub: eventHub)

        let response = try XCTUnwrap(handler.handle(BridgeRequest(id: "request-1",
                                                                  action: "probe_interactive_prompt",
                                                                  params: [
                                                                    "workspace_id": .string(route.workspaceID),
                                                                    "panel_id": .string(route.panelID),
                                                                  ])))

        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.result?["prompt"]?.objectValue?["title"]?.stringValue, "Run a dynamic workflow?")
        XCTAssertEqual(response.result?["event"]?.objectValue?["type"]?.stringValue, "interactive_prompt")

        let fetched = eventHub.fetch(workspaceID: route.workspaceID,
                                     sessionID: route.sessionID,
                                     limit: 10)
        XCTAssertEqual(fetched.events.count, 1)
        XCTAssertEqual(fetched.events.first?.type, .interactivePrompt)
        XCTAssertEqual(fetched.events.first?.metadata?["panel_id"], route.panelID)
        XCTAssertEqual(fetched.events.first?.payload?.objectValue?["selected_index"]?.intValue, 0)
        XCTAssertEqual(response.result?["status"]?.stringValue, "active")
        XCTAssertEqual(response.result?["stale"]?.boolValue, false)
        XCTAssertEqual(adapter.maxLines, [0])
    }

    func testProbeKeepsLastKnownPromptDuringUncertainFrameWithoutRepublishing() throws {
        let route = ordinaryRoute()
        let eventHub = AgentEventHub()
        let adapter = StubPromptAdapter(outputs: [
            Self.workflowConfirmOutput(selectedOption: 1),
            Self.uncertainWorkflowConfirmOutput(),
        ])
        let handler = makeHandler(route: route,
                                  adapter: adapter,
                                  eventHub: eventHub)

        _ = try XCTUnwrap(handler.handle(BridgeRequest(id: "request-1",
                                                       action: "probe_interactive_prompt",
                                                       params: [
                                                        "workspace_id": .string(route.workspaceID),
                                                        "panel_id": .string(route.panelID),
                                                       ])))
        let staleResponse = try XCTUnwrap(handler.handle(BridgeRequest(id: "request-2",
                                                                       action: "probe_interactive_prompt",
                                                                       params: [
                                                                        "workspace_id": .string(route.workspaceID),
                                                                        "panel_id": .string(route.panelID),
                                                                       ])))

        XCTAssertEqual(staleResponse.result?["status"]?.stringValue, "active")
        XCTAssertEqual(staleResponse.result?["stale"]?.boolValue, true)
        XCTAssertEqual(staleResponse.result?["prompt"]?.objectValue?["title"]?.stringValue, "Run a dynamic workflow?")
        XCTAssertEqual(eventHub.fetch(workspaceID: route.workspaceID,
                                      sessionID: route.sessionID,
                                      limit: 10).events.count, 1)
    }

    func testProbePublishesResolvedAfterThreeConfidentAbsentFrames() throws {
        let route = ordinaryRoute()
        let eventHub = AgentEventHub()
        let adapter = StubPromptAdapter(outputs: [
            Self.workflowConfirmOutput(selectedOption: 1),
            "regular shell output",
            "regular shell output",
            "regular shell output",
        ])
        let handler = makeHandler(route: route,
                                  adapter: adapter,
                                  eventHub: eventHub)

        _ = try XCTUnwrap(handler.handle(BridgeRequest(id: "request-1",
                                                       action: "probe_interactive_prompt",
                                                       params: [
                                                        "workspace_id": .string(route.workspaceID),
                                                        "panel_id": .string(route.panelID),
                                                       ])))
        let firstAbsent = try XCTUnwrap(handler.handle(BridgeRequest(id: "request-2",
                                                                     action: "probe_interactive_prompt",
                                                                     params: [
                                                                        "workspace_id": .string(route.workspaceID),
                                                                        "panel_id": .string(route.panelID),
                                                                     ])))
        let secondAbsent = try XCTUnwrap(handler.handle(BridgeRequest(id: "request-3",
                                                                      action: "probe_interactive_prompt",
                                                                      params: [
                                                                        "workspace_id": .string(route.workspaceID),
                                                                        "panel_id": .string(route.panelID),
                                                                      ])))
        let resolved = try XCTUnwrap(handler.handle(BridgeRequest(id: "request-4",
                                                                  action: "probe_interactive_prompt",
                                                                  params: [
                                                                    "workspace_id": .string(route.workspaceID),
                                                                    "panel_id": .string(route.panelID),
                                                                  ])))

        XCTAssertEqual(firstAbsent.result?["status"]?.stringValue, "active")
        XCTAssertEqual(firstAbsent.result?["stale"]?.boolValue, true)
        XCTAssertEqual(secondAbsent.result?["status"]?.stringValue, "active")
        XCTAssertEqual(secondAbsent.result?["stale"]?.boolValue, true)
        XCTAssertEqual(resolved.result?["status"]?.stringValue, "resolved")
        XCTAssertEqual(resolved.result?["resolved_event"]?.objectValue?["type"]?.stringValue, "interactive_prompt_resolved")
        XCTAssertEqual(resolved.result?["resolved_event"]?.objectValue?["metadata"]?.objectValue?["reason"]?.stringValue, "absent")
    }

    func testSubmitValidatesPromptBeforeSendingTargetOption() throws {
        let route = ordinaryRoute()
        let router = StubPromptInputRouter(routedPanelIDs: [route.panelID])
        let handler = makeHandler(route: route,
                                  adapter: StubPromptAdapter(outputs: [Self.workflowConfirmOutput(selectedOption: 1)]),
                                  router: router)
        let promptID = try promptID(for: route)

        let response = try XCTUnwrap(handler.handle(BridgeRequest(id: "request-1",
                                                                  action: "submit_interactive_prompt",
                                                                  params: [
                                                                    "workspace_id": .string(route.workspaceID),
                                                                    "panel_id": .string(route.panelID),
                                                                    "prompt_id": .string(promptID),
                                                                    "target_index": .number(2),
                                                                  ])))

        XCTAssertTrue(response.ok)
        XCTAssertEqual(router.sentInputs.map(\.panelID), [route.panelID])
        XCTAssertEqual(router.sentInputs.map(\.input), ["\u{1b}[B\u{1b}[B\r"])
        XCTAssertEqual(response.result?["resolved_event"]?.objectValue?["type"]?.stringValue, "interactive_prompt_resolved")
        XCTAssertEqual(response.result?["resolved_event"]?.objectValue?["metadata"]?.objectValue?["reason"]?.stringValue, "submit")
    }

    func testSubmitRejectsWhenPromptNoLongerActive() {
        let route = ordinaryRoute()
        let router = StubPromptInputRouter(routedPanelIDs: [route.panelID])
        let handler = makeHandler(route: route,
                                  adapter: StubPromptAdapter(outputs: ["regular terminal output"]),
                                  router: router)

        XCTAssertThrowsError(
            try handler.handle(BridgeRequest(id: "request-1",
                                             action: "submit_interactive_prompt",
                                             params: [
                                                "workspace_id": .string(route.workspaceID),
                                                "panel_id": .string(route.panelID),
                                                "prompt_id": .string("workflow-confirm:missing"),
                                                "target_index": .number(0),
                                             ]))
        ) { error in
            guard case BridgeInternalError.conflict(let message) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertTrue(message.contains("no longer active"))
        }
        XCTAssertTrue(router.sentInputs.isEmpty)
    }

    func testSubmitCodexApprovalRoutesToAppServerSubmitter() throws {
        let route = ordinaryRoute()
        let submitter = StubCodexApprovalSubmitter()
        let resolved = AgentEvent(eventID: "resolved-prompt-1",
                                  seq: 10,
                                  vendor: "codex",
                                  workspaceID: route.workspaceID,
                                  sessionID: route.sessionID,
                                  timestamp: "2026-06-07T00:00:00.000Z",
                                  type: .interactivePromptResolved,
                                  role: nil,
                                  text: nil,
                                  name: nil,
                                  input: nil,
                                  output: nil,
                                  toolCallID: nil,
                                  metadata: [
                                    "panel_id": route.panelID,
                                    "prompt_id": "prompt-1",
                                    "source": "codex_command_approval",
                                  ])
        submitter.resolvedEvent = resolved
        submitter.pendingConfirmation = true
        let handler = makeHandler(route: route,
                                  adapter: StubPromptAdapter(outputs: []),
                                  activeVendor: "codex",
                                  codexApprovalSubmitter: submitter)

        let response = try XCTUnwrap(handler.handle(BridgeRequest(id: "request-1",
                                                                  action: "submit_interactive_prompt",
                                                                  params: [
                                                                    "workspace_id": .string(route.workspaceID),
                                                                    "panel_id": .string(route.panelID),
                                                                    "prompt_id": .string("prompt-1"),
                                                                    "lifecycle_token": .string("token-1"),
                                                                    "target_index": .number(1),
                                                                    "client_request_id": .string("client-1"),
                                                                  ])))

        XCTAssertTrue(response.ok)
        XCTAssertEqual(submitter.submissions.map(\.promptID), ["prompt-1"])
        XCTAssertEqual(submitter.submissions.map(\.targetIndex), [1])
        XCTAssertEqual(submitter.submissions.map(\.clientRequestID), ["client-1"])
        XCTAssertEqual(submitter.submissions.map(\.lifecycleToken), ["token-1"])
        XCTAssertEqual(submitter.submissions.map(\.workspaceID), [route.workspaceID])
        XCTAssertEqual(submitter.submissions.map(\.panelID), [route.panelID])
        XCTAssertEqual(submitter.submissions.map(\.sessionID), [route.sessionID])
        // A flushed response is only pending confirmation: submitted, no
        // resolved_event, card stays visible.
        XCTAssertEqual(response.result?["submitted"]?.boolValue, true)
        XCTAssertEqual(response.result?["status"]?.stringValue, "pending_confirmation")
        XCTAssertNil(response.result?["resolved_event"])
        XCTAssertEqual(response.result?["client_request_id"]?.stringValue, "client-1")
        // The pending echo must include the lifecycle capability the client
        // presented, so strict clients can verify the transaction identity.
        XCTAssertEqual(response.result?["lifecycle_token"]?.stringValue, "token-1")
    }

    func testChannelOnlyCodexSubmitRoutesToNativeFailClosedPath() {
        // ONLY submit_channel signals Codex (no vendor param, no Codex
        // source, no active session): still the native fail-closed path.
        let route = ordinaryRoute()
        let submitter = StubCodexApprovalSubmitter()
        submitter.pendingConfirmation = true
        let handler = makeHandler(route: route,
                                  adapter: StubPromptAdapter(outputs: []),
                                  codexApprovalSubmitter: submitter)

        XCTAssertThrowsError(try handler.handle(BridgeRequest(id: "request-1",
                                                              action: "submit_interactive_prompt",
                                                              params: [
                                                                "workspace_id": .string(route.workspaceID),
                                                                "panel_id": .string(route.panelID),
                                                                "prompt_id": .string("prompt-1"),
                                                                "submit_channel": .string("codex_app_server"),
                                                                "target_index": .number(0),
                                                              ]))) { error in
            guard case BridgeInternalError.invalidRequest(let message) = error,
                  message.contains("lifecycle_token") else {
                return XCTFail("expected the Codex native lifecycle_token rejection, got \(error)")
            }
        }
        XCTAssertTrue(submitter.submissions.isEmpty)
    }

    func testSourceOnlyCodexSubmitRoutesToNativeFailClosedPath() {
        // ONLY the source signals Codex (no vendor param, no submit_channel,
        // no active session): the submit must still take the Codex native
        // fail-closed path and be rejected for the missing lifecycle token —
        // never the Claude/terminal-input path.
        let route = ordinaryRoute()
        let submitter = StubCodexApprovalSubmitter()
        submitter.pendingConfirmation = true
        let handler = makeHandler(route: route,
                                  adapter: StubPromptAdapter(outputs: []),
                                  codexApprovalSubmitter: submitter)

        XCTAssertThrowsError(try handler.handle(BridgeRequest(id: "request-1",
                                                              action: "submit_interactive_prompt",
                                                              params: [
                                                                "workspace_id": .string(route.workspaceID),
                                                                "panel_id": .string(route.panelID),
                                                                "prompt_id": .string("prompt-1"),
                                                                "source": .string("codex_command_approval"),
                                                                "target_index": .number(0),
                                                              ]))) { error in
            guard case BridgeInternalError.invalidRequest(let message) = error,
                  message.contains("lifecycle_token") else {
                return XCTFail("expected the Codex native lifecycle_token rejection, got \(error)")
            }
        }
        XCTAssertTrue(submitter.submissions.isEmpty)
    }

    func testSubmitCodexApprovalWithoutLifecycleTokenIsRejectedNotFallback() {
        // A submit that cannot present the server-issued lifecycle capability
        // must not fall back to whatever lifecycle is currently active.
        let route = ordinaryRoute()
        let submitter = StubCodexApprovalSubmitter()
        submitter.pendingConfirmation = true
        let handler = makeHandler(route: route,
                                  adapter: StubPromptAdapter(outputs: []),
                                  activeVendor: "codex",
                                  codexApprovalSubmitter: submitter)

        XCTAssertThrowsError(try handler.handle(BridgeRequest(id: "request-1",
                                                              action: "submit_interactive_prompt",
                                                              params: [
                                                                "workspace_id": .string(route.workspaceID),
                                                                "panel_id": .string(route.panelID),
                                                                "prompt_id": .string("prompt-1"),
                                                                "target_index": .number(1),
                                                                "client_request_id": .string("client-1"),
                                                              ]))) { error in
            guard case BridgeInternalError.invalidRequest = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertTrue(submitter.submissions.isEmpty)
    }

    func testSubmitCodexApprovalDuplicateClientRequestIDReconcilesAgainstLiveState() throws {
        let route = ordinaryRoute()
        let submitter = StubCodexApprovalSubmitter()
        submitter.pendingConfirmation = true
        let handler = makeHandler(route: route,
                                  adapter: StubPromptAdapter(outputs: []),
                                  activeVendor: "codex",
                                  codexApprovalSubmitter: submitter)
        let params: [String: JSONValue] = [
            "workspace_id": .string(route.workspaceID),
            "panel_id": .string(route.panelID),
            "prompt_id": .string("prompt-1"),
            "lifecycle_token": .string("token-1"),
            "target_index": .number(1),
            "client_request_id": .string("client-1"),
        ]

        let first = try XCTUnwrap(handler.handle(BridgeRequest(id: "request-1",
                                                               action: "submit_interactive_prompt",
                                                               params: params)))
        XCTAssertEqual(first.result?["status"]?.stringValue, "pending_confirmation")

        // A retry with the same client request identity while the request is
        // still pending is passed through to the live state (the connection
        // store deduplicates the in-flight attempt) instead of being answered
        // from a stale cache forever.
        let second = try XCTUnwrap(handler.handle(BridgeRequest(id: "request-2",
                                                                action: "submit_interactive_prompt",
                                                                params: params)))
        XCTAssertEqual(second.result?["status"]?.stringValue, "pending_confirmation")
        XCTAssertEqual(submitter.submissions.count, 2)
        XCTAssertEqual(submitter.submissions.map(\.clientRequestID), ["client-1", "client-1"])

        // Same client request identity with a conflicting decision fails
        // closed without reaching the submitter.
        var conflicting = params
        conflicting["target_index"] = .number(0)
        XCTAssertThrowsError(try handler.handle(BridgeRequest(id: "request-3",
                                                              action: "submit_interactive_prompt",
                                                              params: conflicting))) { error in
            guard case BridgeInternalError.conflict = error else {
                return XCTFail("expected conflict, got \(error)")
            }
        }
        XCTAssertEqual(submitter.submissions.count, 2)
    }

    func testSubmitCodexApprovalRetryAfterServerResolutionReturnsAuthoritativeTerminal() throws {
        let route = ordinaryRoute()
        let submitter = StubCodexApprovalSubmitter()
        submitter.pendingConfirmation = true
        let handler = makeHandler(route: route,
                                  adapter: StubPromptAdapter(outputs: []),
                                  activeVendor: "codex",
                                  codexApprovalSubmitter: submitter)
        let params: [String: JSONValue] = [
            "workspace_id": .string(route.workspaceID),
            "panel_id": .string(route.panelID),
            "prompt_id": .string("prompt-1"),
            "lifecycle_token": .string("token-1"),
            "target_index": .number(1),
            "client_request_id": .string("client-1"),
        ]

        let first = try XCTUnwrap(handler.handle(BridgeRequest(id: "request-1",
                                                               action: "submit_interactive_prompt",
                                                               params: params)))
        XCTAssertEqual(first.result?["status"]?.stringValue, "pending_confirmation")

        // serverRequest/resolved lands: the live state now has the terminal.
        submitter.pendingConfirmation = false
        submitter.resolvedEvent = AgentEvent(eventID: "resolved-prompt-1",
                                             seq: 10,
                                             vendor: "codex",
                                             workspaceID: route.workspaceID,
                                             sessionID: route.sessionID,
                                             timestamp: "2026-07-15T00:00:00.000Z",
                                             type: .interactivePromptResolved,
                                             role: nil,
                                             text: nil,
                                             name: nil,
                                             input: nil,
                                             output: nil,
                                             toolCallID: nil,
                                             metadata: [
                                                "panel_id": route.panelID,
                                                "prompt_id": "prompt-1",
                                                "source": "codex_command_approval",
                                                "reason": "server_resolved",
                                             ])

        // The same client request identity now reconciles to the
        // authoritative terminal instead of a stale pending answer.
        let retry = try XCTUnwrap(handler.handle(BridgeRequest(id: "request-2",
                                                               action: "submit_interactive_prompt",
                                                               params: params)))
        XCTAssertEqual(retry.result?["status"]?.stringValue, "already_resolved")
        XCTAssertEqual(retry.result?["resolved_event"]?.objectValue?["metadata"]?.objectValue?["reason"]?.stringValue,
                       "server_resolved")
    }

    func testSubmitClaudePromptDuplicateClientRequestIDDoesNotResendInput() throws {
        let route = ordinaryRoute()
        let eventHub = AgentEventHub()
        let router = StubPromptInputRouter(routedPanelIDs: [route.panelID])
        let handler = makeHandler(route: route,
                                  adapter: StubPromptAdapter(outputs: [
                                      Self.workflowConfirmOutput(selectedOption: 1),
                                      Self.workflowConfirmOutput(selectedOption: 1),
                                  ]),
                                  eventHub: eventHub,
                                  router: router)
        let promptID = try promptID(for: route)
        let params: [String: JSONValue] = [
            "workspace_id": .string(route.workspaceID),
            "panel_id": .string(route.panelID),
            "prompt_id": .string(promptID),
            "target_index": .number(0),
            "client_request_id": .string("client-1"),
        ]

        let first = try XCTUnwrap(handler.handle(BridgeRequest(id: "request-1",
                                                               action: "submit_interactive_prompt",
                                                               params: params)))
        XCTAssertTrue(first.ok)
        XCTAssertEqual(router.sentInputs.count, 1)

        // Retry after an ambiguous failure/reconnect with the same identity:
        // same recorded status, no second terminal input.
        let second = try XCTUnwrap(handler.handle(BridgeRequest(id: "request-2",
                                                                action: "submit_interactive_prompt",
                                                                params: params)))
        XCTAssertTrue(second.ok)
        XCTAssertEqual(second.result?["status"]?.stringValue, first.result?["status"]?.stringValue)
        XCTAssertEqual(router.sentInputs.count, 1)
    }

    func testSubmitCodexApprovalPendingResultEchoesFullTransactionContext() throws {
        let route = ordinaryRoute()
        let submitter = StubCodexApprovalSubmitter()
        submitter.pendingConfirmation = true
        let handler = makeHandler(route: route,
                                  adapter: StubPromptAdapter(outputs: []),
                                  activeVendor: "codex",
                                  codexApprovalSubmitter: submitter)

        let response = try XCTUnwrap(handler.handle(BridgeRequest(id: "request-1",
                                                                  action: "submit_interactive_prompt",
                                                                  params: [
                                                                    "workspace_id": .string(route.workspaceID),
                                                                    "panel_id": .string(route.panelID),
                                                                    "prompt_id": .string("prompt-1"),
                                                                    "lifecycle_token": .string("token-1"),
                                                                    "target_index": .number(1),
                                                                    "client_request_id": .string("client-1"),
                                                                  ])))

        let result = try XCTUnwrap(response.result)
        XCTAssertEqual(result["submitted"]?.boolValue, true)
        XCTAssertEqual(result["status"]?.stringValue, "pending_confirmation")
        XCTAssertEqual(result["prompt_id"]?.stringValue, "prompt-1")
        XCTAssertEqual(result["workspace_id"]?.stringValue, route.workspaceID)
        XCTAssertEqual(result["panel_id"]?.stringValue, route.panelID)
        XCTAssertEqual(result["session_id"]?.stringValue, route.sessionID)
        XCTAssertEqual(result["client_request_id"]?.stringValue, "client-1")
    }

    func testSubmitFailsClosedOnSessionOrVendorMismatchWithActiveContext() throws {
        let route = ordinaryRoute()
        let submitter = StubCodexApprovalSubmitter()
        submitter.pendingConfirmation = true
        let handler = makeHandler(route: route,
                                  adapter: StubPromptAdapter(outputs: []),
                                  activeVendor: "codex",
                                  codexApprovalSubmitter: submitter)

        // A client naming a stale session must be rejected, not silently
        // retargeted at the active session.
        XCTAssertThrowsError(try handler.handle(BridgeRequest(id: "request-1",
                                                              action: "submit_interactive_prompt",
                                                              params: [
                                                                "workspace_id": .string(route.workspaceID),
                                                                "panel_id": .string(route.panelID),
                                                                "session_id": .string("stale-session"),
                                                                "prompt_id": .string("prompt-1"),
                                                                "lifecycle_token": .string("token-1"),
                                                                "target_index": .number(1),
                                                              ]))) { error in
            guard case BridgeInternalError.conflict = error else {
                return XCTFail("expected conflict, got \(error)")
            }
        }
        // Same for a mismatched vendor.
        XCTAssertThrowsError(try handler.handle(BridgeRequest(id: "request-2",
                                                              action: "submit_interactive_prompt",
                                                              params: [
                                                                "workspace_id": .string(route.workspaceID),
                                                                "panel_id": .string(route.panelID),
                                                                "vendor": .string("claude"),
                                                                "prompt_id": .string("prompt-1"),
                                                                "lifecycle_token": .string("token-1"),
                                                                "target_index": .number(1),
                                                              ]))) { error in
            guard case BridgeInternalError.conflict = error else {
                return XCTFail("expected conflict, got \(error)")
            }
        }
        XCTAssertTrue(submitter.submissions.isEmpty)

        // Matching context still goes through.
        let matching = try XCTUnwrap(handler.handle(BridgeRequest(id: "request-3",
                                                                  action: "submit_interactive_prompt",
                                                                  params: [
                                                                    "workspace_id": .string(route.workspaceID),
                                                                    "panel_id": .string(route.panelID),
                                                                    "session_id": .string(route.sessionID),
                                                                    "vendor": .string("codex"),
                                                                    "prompt_id": .string("prompt-1"),
                                                                    "lifecycle_token": .string("token-1"),
                                                                    "target_index": .number(1),
                                                                  ])))
        XCTAssertTrue(matching.ok)
    }

    func testSubmitCodexApprovalCachedTerminalDoesNotMaskReactivatedLifecycle() throws {
        let route = ordinaryRoute()
        let submitter = StubCodexApprovalSubmitter()
        // First lifecycle ends expired; the handler caches the terminal for
        // this client request identity.
        submitter.resolvedEvent = AgentEvent(eventID: "resolved-prompt-1-expired",
                                             seq: 10,
                                             vendor: "codex",
                                             workspaceID: route.workspaceID,
                                             sessionID: route.sessionID,
                                             timestamp: "2026-07-15T00:00:00.000Z",
                                             type: .interactivePromptResolved,
                                             role: nil,
                                             text: nil,
                                             name: nil,
                                             input: nil,
                                             output: nil,
                                             toolCallID: nil,
                                             metadata: [
                                                "panel_id": route.panelID,
                                                "prompt_id": "prompt-1",
                                                "source": "codex_command_approval",
                                                "reason": "expired",
                                             ])
        let handler = makeHandler(route: route,
                                  adapter: StubPromptAdapter(outputs: []),
                                  activeVendor: "codex",
                                  codexApprovalSubmitter: submitter)
        let params: [String: JSONValue] = [
            "workspace_id": .string(route.workspaceID),
            "panel_id": .string(route.panelID),
            "prompt_id": .string("prompt-1"),
            "lifecycle_token": .string("token-1"),
            "target_index": .number(1),
            "client_request_id": .string("client-1"),
        ]

        let first = try XCTUnwrap(handler.handle(BridgeRequest(id: "request-1",
                                                               action: "submit_interactive_prompt",
                                                               params: params)))
        XCTAssertEqual(first.result?["status"]?.stringValue, "already_resolved")

        // The same app-server process re-delivers (reactivates) the logical
        // prompt: the live store is pending again. The cached old terminal
        // must not answer for the new attempt.
        submitter.resolvedEvent = nil
        submitter.pendingConfirmation = true
        let retry = try XCTUnwrap(handler.handle(BridgeRequest(id: "request-2",
                                                               action: "submit_interactive_prompt",
                                                               params: params)))
        XCTAssertEqual(retry.result?["status"]?.stringValue, "pending_confirmation")
        XCTAssertNil(retry.result?["resolved_event"])
        XCTAssertEqual(submitter.submissions.count, 2)
    }

    func testSubmitCodexApprovalReturnsAlreadyResolvedStatus() throws {
        let route = ordinaryRoute()
        let submitter = StubCodexApprovalSubmitter()
        submitter.resolvedEvent = AgentEvent(eventID: "resolved-prompt-1",
                                             seq: 10,
                                             vendor: "codex",
                                             workspaceID: route.workspaceID,
                                             sessionID: route.sessionID,
                                             timestamp: "2026-06-07T00:00:00.000Z",
                                             type: .interactivePromptResolved,
                                             role: nil,
                                             text: nil,
                                             name: nil,
                                             input: nil,
                                             output: nil,
                                             toolCallID: nil,
                                             metadata: [
                                                "panel_id": route.panelID,
                                                "prompt_id": "prompt-1",
                                                "source": "codex_command_approval",
                                                "reason": "already_resolved",
                                             ])
        let handler = makeHandler(route: route,
                                  adapter: StubPromptAdapter(outputs: []),
                                  activeVendor: "codex",
                                  codexApprovalSubmitter: submitter)

        let response = try XCTUnwrap(handler.handle(BridgeRequest(id: "request-1",
                                                                  action: "submit_interactive_prompt",
                                                                  params: [
                                                                    "workspace_id": .string(route.workspaceID),
                                                                    "panel_id": .string(route.panelID),
                                                                    "prompt_id": .string("prompt-1"),
                                                                    "lifecycle_token": .string("token-1"),
                                                                    "target_index": .number(1),
                                                                  ])))

        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.result?["status"]?.stringValue, "already_resolved")
        XCTAssertEqual(response.result?["resolved_event"]?.objectValue?["metadata"]?.objectValue?["reason"]?.stringValue,
                       "already_resolved")
    }

    func testSubmitCodexApprovalDoesNotRequireOrdinaryTmuxRoute() throws {
        let route = ordinaryRoute()
        let submitter = StubCodexApprovalSubmitter()
        let resolved = AgentEvent(eventID: "resolved-prompt-1",
                                  seq: 10,
                                  vendor: "codex",
                                  workspaceID: route.workspaceID,
                                  sessionID: route.sessionID,
                                  timestamp: "2026-06-07T00:00:00.000Z",
                                  type: .interactivePromptResolved,
                                  role: nil,
                                  text: nil,
                                  name: nil,
                                  input: nil,
                                  output: nil,
                                  toolCallID: nil,
                                  metadata: [
                                    "panel_id": route.panelID,
                                    "prompt_id": "prompt-1",
                                    "source": "codex_command_approval",
                                  ])
        submitter.resolvedEvent = resolved
        submitter.pendingConfirmation = true
        let handler = makeHandler(route: nil,
                                  adapter: StubPromptAdapter(outputs: []),
                                  activeSessionOverride: activeSession(route: route, vendor: "codex"),
                                  codexApprovalSubmitter: submitter)

        let response = try XCTUnwrap(handler.handle(BridgeRequest(id: "request-1",
                                                                  action: "submit_interactive_prompt",
                                                                  params: [
                                                                    "workspace_id": .string(route.workspaceID),
                                                                    "panel_id": .string(route.panelID),
                                                                    "session_id": .string(route.sessionID),
                                                                    "vendor": .string("codex"),
                                                                    "prompt_id": .string("prompt-1"),
                                                                    "lifecycle_token": .string("token-1"),
                                                                    "submit_channel": .string("codex_app_server"),
                                                                    "target_index": .number(1),
                                                                  ])))

        XCTAssertTrue(response.ok)
        XCTAssertEqual(submitter.submissions.map(\.promptID), ["prompt-1"])
        XCTAssertEqual(submitter.submissions.map(\.targetIndex), [1])
        XCTAssertEqual(response.result?["status"]?.stringValue, "pending_confirmation")
    }

    func testSubmitClaudeAskUserQuestionUsesActiveTranscriptPrompt() throws {
        let route = ordinaryRoute()
        let eventHub = AgentEventHub()
        let router = StubPromptInputRouter(routedPanelIDs: [route.panelID])
        eventHub.publish(Self.claudeAskUserQuestionEvent(route: route, promptID: "toolu_question_1"))
        let handler = makeHandler(route: route,
                                  adapter: StubPromptAdapter(outputs: ["regular terminal output"]),
                                  eventHub: eventHub,
                                  router: router)

        let response = try XCTUnwrap(handler.handle(BridgeRequest(id: "request-1",
                                                                  action: "submit_interactive_prompt",
                                                                  params: [
                                                                    "workspace_id": .string(route.workspaceID),
                                                                    "panel_id": .string(route.panelID),
                                                                    "prompt_id": .string("toolu_question_1"),
                                                                    "target_index": .number(1),
                                                                  ])))

        XCTAssertTrue(response.ok)
        XCTAssertEqual(router.sentInputs.map(\.panelID), [route.panelID])
        XCTAssertEqual(router.sentInputs.map(\.input), ["\u{1b}[B\r"])
        XCTAssertEqual(response.result?["status"]?.stringValue, "resolved")
        let resolvedEvent = try XCTUnwrap(response.result?["resolved_event"]?.objectValue)
        XCTAssertEqual(resolvedEvent["type"]?.stringValue, "interactive_prompt_resolved")
        XCTAssertEqual(resolvedEvent["metadata"]?.objectValue?["prompt_id"]?.stringValue, "toolu_question_1")
        XCTAssertNil(eventHub.activeInteractivePrompt(workspaceID: route.workspaceID,
                                                      sessionID: route.sessionID,
                                                      promptID: "toolu_question_1"))
    }

    func testSubmitClaudeAskUserQuestionRejectsResolvedTranscriptPrompt() throws {
        let route = ordinaryRoute()
        let eventHub = AgentEventHub()
        let router = StubPromptInputRouter(routedPanelIDs: [route.panelID])
        eventHub.publish(Self.claudeAskUserQuestionEvent(route: route, promptID: "toolu_question_1"))
        eventHub.publish(Self.claudeAskUserQuestionResolvedEvent(route: route, promptID: "toolu_question_1"))
        let handler = makeHandler(route: route,
                                  adapter: StubPromptAdapter(outputs: ["regular terminal output"]),
                                  eventHub: eventHub,
                                  router: router)

        XCTAssertThrowsError(
            try handler.handle(BridgeRequest(id: "request-1",
                                             action: "submit_interactive_prompt",
                                             params: [
                                                "workspace_id": .string(route.workspaceID),
                                                "panel_id": .string(route.panelID),
                                                "prompt_id": .string("toolu_question_1"),
                                                "target_index": .number(1),
                                             ]))
        ) { error in
            guard case BridgeInternalError.conflict(let message) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertTrue(message.contains("no longer active"))
        }
        XCTAssertTrue(router.sentInputs.isEmpty)
    }

    private func makeHandler(route: OrdinaryTmuxPanelRoute?,
                             adapter: StubPromptAdapter,
                             eventHub: AgentEventHub = AgentEventHub(),
                             router: StubPromptInputRouter = StubPromptInputRouter(routedPanelIDs: []),
                             activeVendor: String = "claude",
                             activeSessionOverride: ActiveAgentSessionSnapshot? = nil,
                             codexApprovalSubmitter: CodexAppServerApprovalSubmitting? = nil) -> InteractivePromptActionHandler {
        let sessionResolver = StubPromptSessionResolver(session: activeSessionOverride ?? route.map { activeSession(route: $0, vendor: activeVendor) })
        let inputHandler = BridgeInputActionHandler(socketSender: StubPromptRequestSender(),
                                                    sessionResolver: sessionResolver,
                                                    ordinaryTmuxInputRouter: router)
        return InteractivePromptActionHandler(routeResolver: StubPromptRouteResolver(route: route),
                                              adapter: adapter,
                                              sessionResolver: sessionResolver,
                                              eventHub: eventHub,
                                              inputActionHandler: inputHandler,
                                              codexApprovalSubmitter: codexApprovalSubmitter)
    }

    private func activeSession(route: OrdinaryTmuxPanelRoute, vendor: String = "claude") -> ActiveAgentSessionSnapshot {
        ActiveAgentSessionSnapshot(vendor: vendor,
                                   workspaceID: route.workspaceID,
                                   sessionID: route.sessionID,
                                   panelID: route.panelID)
    }

    private func ordinaryRoute() -> OrdinaryTmuxPanelRoute {
        let socketPath = "/tmp/tmux-\(getuid())/default"
        return OrdinaryTmuxPanelRoute(workspaceID: "workspace-1",
                                      panelID: "ordinary-tmux:\(socketPath):$7:@16",
                                      carrierPanelID: "carrier-panel",
                                      socket: .path(socketPath),
                                      sessionID: "$7",
                                      sessionName: "adbrewer-cc",
                                      windowID: "@16",
                                      windowIndex: 1,
                                      activePaneID: "%16",
                                      cwd: "/Users/timfeng/GitHub/adbrewer",
                                      currentCommand: "claude")
    }

    private func promptID(for route: OrdinaryTmuxPanelRoute) throws -> String {
        let prompt = try XCTUnwrap(WorkflowConfirmPromptDetector().parse(ansiOutput: Self.workflowConfirmOutput(selectedOption: 1),
                                                                         workspaceID: route.workspaceID,
                                                                         panelID: route.panelID,
                                                                         sessionID: route.sessionID,
                                                                         vendor: "claude"))
        return prompt.promptID
    }

    private static func workflowConfirmOutput(selectedOption: Int) -> String {
        let marker1 = selectedOption == 1 ? "❯ " : "  "
        let marker2 = selectedOption == 2 ? "❯ " : "  "
        let marker3 = selectedOption == 3 ? "❯ " : "  "
        return """
         Run a dynamic workflow?
          CC granular per-chunk craft-concept extraction for book 10
          This dynamic workflow will spin up multiple subagents across the following phases:
            1. Extract - one agent per chunk
          Dynamic workflows can use a lot of tokens quickly.

          \(marker1)1. Yes, run it
            \(marker2)2. View raw script
            \(marker3)3. No

          Esc to cancel · Tab to amend
        """
    }

    private static func uncertainWorkflowConfirmOutput() -> String {
        """
         Run a dynamic workflow?

           ❯ 1. Yes, run it
        """
    }

    private static func claudeAskUserQuestionEvent(route: OrdinaryTmuxPanelRoute,
                                                   promptID: String) -> AgentEvent {
        let prompt = InteractivePrompt(promptID: promptID,
                                       vendor: "claude",
                                       source: "claude_ask_user_question",
                                       title: "Choose a path",
                                       body: "Which path should Claude use?",
                                       options: [
                                        InteractivePromptOption(index: 0,
                                                                label: "Use current file",
                                                                description: "Open the current file.",
                                                                inputSequence: "\r"),
                                        InteractivePromptOption(index: 1,
                                                                label: "Cancel",
                                                                description: "Do not change files.",
                                                                inputSequence: "\u{1b}[B\r"),
                                       ],
                                       selectedIndex: 0,
                                       submitChannel: InteractivePromptSubmitChannel.terminalInput)
        return AgentEvent(eventID: "ask-user-question:\(promptID)",
                          seq: 10,
                          vendor: "claude",
                          workspaceID: route.workspaceID,
                          sessionID: route.sessionID,
                          timestamp: "2026-06-20T00:00:00.000Z",
                          type: .interactivePrompt,
                          role: "assistant",
                          text: prompt.title,
                          name: "AskUserQuestion",
                          input: nil,
                          output: nil,
                          toolCallID: promptID,
                          metadata: [
                            "panel_id": route.panelID,
                            "prompt_id": promptID,
                            "source": "claude_ask_user_question",
                            "submit_channel": InteractivePromptSubmitChannel.terminalInput,
                          ],
                          payload: prompt.jsonValue)
    }

    private static func claudeAskUserQuestionResolvedEvent(route: OrdinaryTmuxPanelRoute,
                                                           promptID: String) -> AgentEvent {
        AgentEvent(eventID: "ask-user-question-resolved:\(promptID)",
                   seq: 11,
                   vendor: "claude",
                   workspaceID: route.workspaceID,
                   sessionID: route.sessionID,
                   timestamp: "2026-06-20T00:00:01.000Z",
                   type: .interactivePromptResolved,
                   role: "tool",
                   text: nil,
                   name: "AskUserQuestion",
                   input: nil,
                   output: nil,
                   toolCallID: promptID,
                   metadata: [
                    "panel_id": route.panelID,
                    "prompt_id": promptID,
                    "source": "claude_ask_user_question",
                    "reason": "tool_result",
                   ],
                   payload: .object([
                    "prompt_id": .string(promptID),
                    "reason": .string("tool_result"),
                   ]))
    }
}

private struct StubPromptRouteResolver: OrdinaryTmuxRouteResolving {
    let route: OrdinaryTmuxPanelRoute?

    func route(forPanelID panelID: String, workspaceID: String?) throws -> OrdinaryTmuxPanelRoute? {
        route
    }
}

private final class StubPromptAdapter: OrdinaryTmuxRouteRefreshing, @unchecked Sendable {
    private var outputs: [String]
    private(set) var maxLines = [Int]()

    init(outputs: [String]) {
        self.outputs = outputs
    }

    func refreshedRoute(_ route: OrdinaryTmuxPanelRoute) throws -> OrdinaryTmuxPanelRoute {
        route
    }

    func route(for logicalID: OrdinaryTmuxLogicalPanelID,
               authorizedTarget: OrdinaryTmuxAuthorizedTarget) throws -> OrdinaryTmuxPanelRoute {
        throw BridgeInternalError.notFound("unused")
    }

    func captureOutput(route: OrdinaryTmuxPanelRoute, maxLines: Int) throws -> OrdinaryTmuxCapturedOutput {
        throw BridgeInternalError.notFound("unused")
    }

    func captureANSIOutput(route: OrdinaryTmuxPanelRoute, maxLines: Int) throws -> OrdinaryTmuxCapturedOutput {
        self.maxLines.append(maxLines)
        let output = outputs.isEmpty ? "" : outputs.removeFirst()
        return OrdinaryTmuxCapturedOutput(output: output, cursorRow: nil, cursorColumn: nil)
    }
}

private final class StubPromptSessionResolver: ActiveAgentSessionResolving {
    private let session: ActiveAgentSessionSnapshot?

    init(session: ActiveAgentSessionSnapshot?) {
        self.session = session
    }

    func activeSessionForPanel(workspaceID: String, panelID: String) -> ActiveAgentSessionSnapshot? {
        session
    }

    func activeRecord(sessionID: String) -> AgentSessionRegistryRecord? {
        nil
    }
}

private final class StubPromptRequestSender: TideyRequestSending {
    private(set) var sentRequests = [BridgeRequest]()

    func send(_ request: BridgeRequest) throws -> BridgeResponse {
        sentRequests.append(request)
        return BridgeResponse(id: request.id,
                              ok: true,
                              result: ["sent": .bool(true)],
                              error: nil)
    }
}

private final class StubPromptInputRouter: OrdinaryTmuxInputRouting, @unchecked Sendable {
    private let routedPanelIDs: Set<String>
    private(set) var sentInputs = [(panelID: String, input: String)]()

    init(routedPanelIDs: Set<String>) {
        self.routedPanelIDs = routedPanelIDs
    }

    func sendInput(_ input: String,
                   toPanelID panelID: String,
                   mode: OrdinaryTmuxInputMode,
                   allowAmbiguousPasteTimeout: Bool) throws -> Bool {
        guard routedPanelIDs.contains(panelID) else {
            return false
        }
        sentInputs.append((panelID, input))
        return true
    }
}

private final class StubCodexApprovalSubmitter: CodexAppServerApprovalSubmitting {
    var resolvedEvent: AgentEvent?
    var pendingConfirmation = false
    private(set) var submissions = [(promptID: String, targetIndex: Int, clientRequestID: String?, lifecycleToken: String?, workspaceID: String?, panelID: String?, sessionID: String?)]()

    func submitApproval(promptID: String,
                        targetIndex: Int,
                        clientRequestID: String?,
                        lifecycleToken: String?) throws -> CodexAppServerApprovalSubmitOutcome {
        submissions.append((promptID: promptID,
                            targetIndex: targetIndex,
                            clientRequestID: clientRequestID,
                            lifecycleToken: lifecycleToken,
                            workspaceID: nil,
                            panelID: nil,
                            sessionID: nil))
        return try outcome(promptID: promptID)
    }

    func submitApproval(promptID: String,
                        targetIndex: Int,
                        clientRequestID: String?,
                        lifecycleToken: String?,
                        workspaceID: String,
                        panelID: String,
                        sessionID: String?) throws -> CodexAppServerApprovalSubmitOutcome {
        submissions.append((promptID: promptID,
                            targetIndex: targetIndex,
                            clientRequestID: clientRequestID,
                            lifecycleToken: lifecycleToken,
                            workspaceID: workspaceID,
                            panelID: panelID,
                            sessionID: sessionID))
        return try outcome(promptID: promptID)
    }

    private func outcome(promptID: String) throws -> CodexAppServerApprovalSubmitOutcome {
        if pendingConfirmation {
            return .pendingConfirmation(promptID: promptID)
        }
        guard let resolvedEvent else {
            throw BridgeInternalError.notFound("Unknown Codex approval prompt.")
        }
        return .alreadyResolved(resolvedEvent)
    }
}
