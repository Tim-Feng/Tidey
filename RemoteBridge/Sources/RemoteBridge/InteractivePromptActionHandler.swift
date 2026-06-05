import Foundation

struct InteractivePromptActionHandler {
    private let routeResolver: OrdinaryTmuxRouteResolving
    private let adapter: OrdinaryTmuxRouteRefreshing
    private let sessionResolver: ActiveAgentSessionResolving
    private let eventHub: AgentEventHub
    private let inputActionHandler: BridgeInputActionHandler
    private let detector: WorkflowConfirmPromptDetector
    private let captureLineLimit = 120

    init(routeResolver: OrdinaryTmuxRouteResolving,
         adapter: OrdinaryTmuxRouteRefreshing = OrdinaryTmuxCLIAdapter(),
         sessionResolver: ActiveAgentSessionResolving,
         eventHub: AgentEventHub,
         inputActionHandler: BridgeInputActionHandler,
         detector: WorkflowConfirmPromptDetector = WorkflowConfirmPromptDetector()) {
        self.routeResolver = routeResolver
        self.adapter = adapter
        self.sessionResolver = sessionResolver
        self.eventHub = eventHub
        self.inputActionHandler = inputActionHandler
        self.detector = detector
    }

    func handle(_ request: BridgeRequest) throws -> BridgeResponse? {
        switch request.action {
        case "probe_interactive_prompt":
            return try probe(request)
        case "submit_interactive_prompt":
            return try submit(request)
        default:
            return nil
        }
    }

    private func probe(_ request: BridgeRequest) throws -> BridgeResponse {
        guard let context = try promptContext(from: request, requiresPromptID: false) else {
            return BridgeResponse(id: request.id,
                                  ok: true,
                                  result: ["prompt": .null],
                                  error: nil)
        }
        guard context.vendor == "claude" else {
            return BridgeResponse(id: request.id,
                                  ok: true,
                                  result: ["prompt": .null],
                                  error: nil)
        }

        let captured = try adapter.captureANSIOutput(route: context.route, maxLines: captureLineLimit)
        guard let prompt = detector.parse(ansiOutput: captured.output,
                                          workspaceID: context.workspaceID,
                                          panelID: context.panelID,
                                          sessionID: context.sessionID,
                                          vendor: context.vendor) else {
            return BridgeResponse(id: request.id,
                                  ok: true,
                                  result: ["prompt": .null],
                                  error: nil)
        }

        let seq = eventHub.nextSyntheticSeq(sessionID: context.sessionID)
        let eventID = "interactive-prompt:\(prompt.promptID):selected:\(prompt.selectedIndex)"
        let event = AgentEvent(eventID: eventID,
                               seq: seq,
                               vendor: context.vendor,
                               workspaceID: context.workspaceID,
                               sessionID: context.sessionID,
                               timestamp: Self.iso8601Now(),
                               type: .interactivePrompt,
                               role: nil,
                               text: prompt.title,
                               name: nil,
                               input: nil,
                               output: nil,
                               toolCallID: nil,
                               metadata: [
                                "panel_id": context.panelID,
                                "source": prompt.source,
                                "prompt_id": prompt.promptID,
                               ],
                               payload: prompt.jsonValue)
        eventHub.publish(event)
        BridgeLogger.server.info("interactive prompt detected workspace_id=\(context.workspaceID, privacy: .public) panel_id=\(context.panelID, privacy: .public) session_id=\(context.sessionID, privacy: .public) source=\(prompt.source, privacy: .public) selected_index=\(prompt.selectedIndex, privacy: .public)")
        return BridgeResponse(id: request.id,
                              ok: true,
                              result: [
                                "prompt": prompt.jsonValue,
                                "event": Self.jsonValue(for: event),
                                "published": .bool(true),
                              ],
                              error: nil)
    }

    private func submit(_ request: BridgeRequest) throws -> BridgeResponse {
        guard let context = try promptContext(from: request, requiresPromptID: true) else {
            throw BridgeInternalError.invalidRequest("submit_interactive_prompt requires workspace_id and panel_id")
        }
        guard context.vendor == "claude" else {
            throw BridgeInternalError.invalidRequest("submit_interactive_prompt only supports Claude workflow prompts")
        }
        guard let requestedPromptID = request.params?["prompt_id"]?.stringValue else {
            throw BridgeInternalError.invalidRequest("submit_interactive_prompt requires prompt_id")
        }

        let captured = try adapter.captureANSIOutput(route: context.route, maxLines: captureLineLimit)
        guard let prompt = detector.parse(ansiOutput: captured.output,
                                          workspaceID: context.workspaceID,
                                          panelID: context.panelID,
                                          sessionID: context.sessionID,
                                          vendor: context.vendor),
              prompt.promptID == requestedPromptID else {
            throw BridgeInternalError.conflict("interactive prompt is no longer active")
        }

        let input: String
        if let targetIndex = request.params?["target_index"]?.intValue {
            guard targetIndex >= 0 && targetIndex < prompt.options.count else {
                throw BridgeInternalError.invalidRequest("submit_interactive_prompt target_index is out of range")
            }
            input = prompt.inputSequence(targetIndex: targetIndex)
        } else if let inputSequence = request.params?["input_sequence"]?.stringValue {
            input = inputSequence
        } else {
            throw BridgeInternalError.invalidRequest("submit_interactive_prompt requires target_index or input_sequence")
        }

        let forwarded = BridgeRequest(id: request.id,
                                      action: "terminal_input",
                                      params: [
                                        "panel_id": .string(context.panelID),
                                        "input": .string(input),
                                      ])
        guard let response = try inputActionHandler.handle(forwarded) else {
            throw BridgeInternalError.invalidResponse
        }
        return response
    }

    private func promptContext(from request: BridgeRequest,
                               requiresPromptID: Bool) throws -> PromptContext? {
        guard let params = request.params,
              let workspaceID = params["workspace_id"]?.stringValue,
              let panelID = params["panel_id"]?.stringValue else {
            if requiresPromptID {
                throw BridgeInternalError.invalidRequest("\(request.action) requires workspace_id and panel_id")
            }
            return nil
        }
        guard let route = try routeResolver.route(forPanelID: panelID, workspaceID: workspaceID) else {
            return nil
        }
        let activeSession = sessionResolver.activeSessionForPanel(workspaceID: workspaceID, panelID: panelID)
        let sessionID = activeSession?.sessionID
            ?? params["session_id"]?.stringValue
            ?? route.sessionID
        let vendor = activeSession?.vendor
            ?? params["vendor"]?.stringValue
            ?? "claude"
        return PromptContext(workspaceID: workspaceID,
                             panelID: panelID,
                             sessionID: sessionID,
                             vendor: vendor,
                             route: route)
    }

    private static func iso8601Now() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }

    private static func jsonValue(for event: AgentEvent) -> JSONValue {
        var object: [String: JSONValue] = [
            "event_id": .string(event.eventID),
            "seq": .number(Double(event.seq)),
            "vendor": .string(event.vendor),
            "workspace_id": .string(event.workspaceID),
            "session_id": .string(event.sessionID),
            "timestamp": .string(event.timestamp),
            "type": .string(event.type.rawValue),
        ]
        if let role = event.role {
            object["role"] = .string(role)
        }
        if let text = event.text {
            object["text"] = .string(text)
        }
        if let name = event.name {
            object["name"] = .string(name)
        }
        if let input = event.input {
            object["input"] = .string(input)
        }
        if let output = event.output {
            object["output"] = .string(output)
        }
        if let toolCallID = event.toolCallID {
            object["tool_call_id"] = .string(toolCallID)
        }
        if let metadata = event.metadata {
            object["metadata"] = .object(metadata.mapValues(JSONValue.string))
        }
        if let payload = event.payload {
            object["payload"] = payload
        }
        return .object(object)
    }

    private struct PromptContext {
        let workspaceID: String
        let panelID: String
        let sessionID: String
        let vendor: String
        let route: OrdinaryTmuxPanelRoute
    }
}
