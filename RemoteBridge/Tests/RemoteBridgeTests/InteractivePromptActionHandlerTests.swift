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
                                                                    "target_index": .number(1),
                                                                  ])))

        XCTAssertTrue(response.ok)
        XCTAssertEqual(submitter.submissions.map(\.promptID), ["prompt-1"])
        XCTAssertEqual(submitter.submissions.map(\.targetIndex), [1])
        XCTAssertEqual(submitter.submissions.map(\.workspaceID), [route.workspaceID])
        XCTAssertEqual(submitter.submissions.map(\.panelID), [route.panelID])
        XCTAssertEqual(submitter.submissions.map(\.sessionID), [route.sessionID])
        XCTAssertEqual(response.result?["status"]?.stringValue, "resolved")
        XCTAssertEqual(response.result?["resolved_event"]?.objectValue?["type"]?.stringValue, "interactive_prompt_resolved")
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
                                                                    "submit_channel": .string("codex_app_server"),
                                                                    "target_index": .number(1),
                                                                  ])))

        XCTAssertTrue(response.ok)
        XCTAssertEqual(submitter.submissions.map(\.promptID), ["prompt-1"])
        XCTAssertEqual(submitter.submissions.map(\.targetIndex), [1])
        XCTAssertEqual(response.result?["status"]?.stringValue, "resolved")
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
    private(set) var submissions = [(promptID: String, targetIndex: Int, workspaceID: String?, panelID: String?, sessionID: String?)]()

    func submitApproval(promptID: String, targetIndex: Int) throws -> AgentEvent {
        submissions.append((promptID: promptID, targetIndex: targetIndex, workspaceID: nil, panelID: nil, sessionID: nil))
        guard let resolvedEvent else {
            throw BridgeInternalError.notFound("Unknown Codex approval prompt.")
        }
        return resolvedEvent
    }

    func submitApproval(promptID: String,
                        targetIndex: Int,
                        workspaceID: String,
                        panelID: String,
                        sessionID: String?) throws -> AgentEvent {
        submissions.append((promptID: promptID,
                            targetIndex: targetIndex,
                            workspaceID: workspaceID,
                            panelID: panelID,
                            sessionID: sessionID))
        guard let resolvedEvent else {
            throw BridgeInternalError.notFound("Unknown Codex approval prompt.")
        }
        return resolvedEvent
    }
}
