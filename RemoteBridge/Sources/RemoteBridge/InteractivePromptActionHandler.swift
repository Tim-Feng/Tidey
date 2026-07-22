import Foundation

struct InteractivePromptSubmitScope: Hashable, Sendable {
    let workspaceID: String
    let panelID: String
    let sessionID: String
    let vendor: String
}

final class InteractivePromptSubmitDeduper: @unchecked Sendable {
    enum Check: Sendable {
        case new
        case duplicate([String: JSONValue])
        case conflict
    }

    private struct CachedSubmit {
        let promptID: String
        let decision: String
        let result: [String: JSONValue]
    }

    private enum CacheKey: Hashable {
        case legacy(clientRequestID: String)
        case scoped(InteractivePromptSubmitScope, clientRequestID: String)
    }

    private let lock = NSLock()
    private let capacity: Int
    private var order: [CacheKey] = []
    private var cacheByKey: [CacheKey: CachedSubmit] = [:]

    init(capacity: Int = 128) {
        self.capacity = max(1, capacity)
    }

    func check(clientRequestID: String, promptID: String, decision: String) -> Check {
        check(key: .legacy(clientRequestID: clientRequestID),
              promptID: promptID,
              decision: decision)
    }

    func check(scope: InteractivePromptSubmitScope,
               clientRequestID: String,
               promptID: String,
               decision: String) -> Check {
        check(key: .scoped(scope, clientRequestID: clientRequestID),
              promptID: promptID,
              decision: decision)
    }

    private func check(key: CacheKey, promptID: String, decision: String) -> Check {
        lock.lock()
        defer { lock.unlock() }
        guard let cached = cacheByKey[key] else {
            return .new
        }
        guard cached.promptID == promptID, cached.decision == decision else {
            return .conflict
        }
        if cached.result["status"]?.stringValue == "pending_confirmation" {
            return .new
        }
        return .duplicate(cached.result)
    }

    func store(clientRequestID: String,
               promptID: String,
               decision: String,
               result: [String: JSONValue]) {
        store(key: .legacy(clientRequestID: clientRequestID),
              promptID: promptID,
              decision: decision,
              result: result)
    }

    func store(scope: InteractivePromptSubmitScope,
               clientRequestID: String,
               promptID: String,
               decision: String,
               result: [String: JSONValue]) {
        store(key: .scoped(scope, clientRequestID: clientRequestID),
              promptID: promptID,
              decision: decision,
              result: result)
    }

    private func store(key: CacheKey,
                       promptID: String,
                       decision: String,
                       result: [String: JSONValue]) {
        lock.lock()
        defer { lock.unlock() }
        if cacheByKey[key] == nil {
            order.append(key)
        }
        cacheByKey[key] = CachedSubmit(promptID: promptID,
                                       decision: decision,
                                       result: result)
        while order.count > capacity {
            cacheByKey.removeValue(forKey: order.removeFirst())
        }
    }
}

struct InteractivePromptActionHandler {
    private let routeResolver: OrdinaryTmuxRouteResolving
    private let adapter: OrdinaryTmuxRouteRefreshing
    private let sessionResolver: ActiveAgentSessionResolving
    private let eventHub: AgentEventHub
    private let inputActionHandler: BridgeInputActionHandler
    private let codexApprovalSubmitter: CodexAppServerApprovalSubmitting?
    private let detector: WorkflowConfirmPromptDetector
    private let stateStore: InteractivePromptStateStore
    private let submitDeduper: InteractivePromptSubmitDeduper
    private let captureLineLimit = 0
    private let resolvedAbsentThreshold = 3

    init(routeResolver: OrdinaryTmuxRouteResolving,
         adapter: OrdinaryTmuxRouteRefreshing = OrdinaryTmuxCLIAdapter(),
         sessionResolver: ActiveAgentSessionResolving,
         eventHub: AgentEventHub,
         inputActionHandler: BridgeInputActionHandler,
         codexApprovalSubmitter: CodexAppServerApprovalSubmitting? = nil,
         detector: WorkflowConfirmPromptDetector = WorkflowConfirmPromptDetector(),
         stateStore: InteractivePromptStateStore = InteractivePromptStateStore(),
         submitDeduper: InteractivePromptSubmitDeduper = InteractivePromptSubmitDeduper()) {
        self.routeResolver = routeResolver
        self.adapter = adapter
        self.sessionResolver = sessionResolver
        self.eventHub = eventHub
        self.inputActionHandler = inputActionHandler
        self.codexApprovalSubmitter = codexApprovalSubmitter
        self.detector = detector
        self.stateStore = stateStore
        self.submitDeduper = submitDeduper
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
            return Self.inactiveResponse(id: request.id, status: "absent")
        }
        guard context.vendor == "claude" else {
            return Self.inactiveResponse(id: request.id, status: "absent")
        }

        let captured = try adapter.captureANSIOutput(route: context.route, maxLines: captureLineLimit)
        let detection = detector.detect(ansiOutput: captured.output,
                                        workspaceID: context.workspaceID,
                                        panelID: context.panelID,
                                        sessionID: context.sessionID,
                                        vendor: context.vendor)
        switch detection {
        case .present(let prompt):
            let result = stateStore.recordPresent(key: context.stateKey, prompt: prompt) {
                makePromptEvent(context: context, prompt: prompt)
            }
            if result.shouldPublish {
                eventHub.publish(result.event)
                BridgeLogger.server.info("interactive prompt detected workspace_id=\(context.workspaceID, privacy: .public) panel_id=\(context.panelID, privacy: .public) session_id=\(context.sessionID, privacy: .public) source=\(prompt.source, privacy: .public) selected_index=\(prompt.selectedIndex, privacy: .public)")
            }
            return BridgeResponse(id: request.id,
                                  ok: true,
                                  result: Self.activeResult(prompt: prompt,
                                                            event: result.event,
                                                            stale: false,
                                                            published: result.shouldPublish),
                                  error: nil)

        case .uncertain:
            guard let active = stateStore.recordUncertain(key: context.stateKey) else {
                return Self.inactiveResponse(id: request.id, status: "uncertain")
            }
            return BridgeResponse(id: request.id,
                                  ok: true,
                                  result: Self.activeResult(prompt: active.prompt,
                                                            event: active.event,
                                                            stale: true,
                                                            published: false),
                                  error: nil)

        case .absent:
            let result = stateStore.recordAbsent(key: context.stateKey,
                                                 threshold: resolvedAbsentThreshold) { prompt in
                makeResolvedEvent(context: context, prompt: prompt, reason: "absent")
            }
            switch result {
            case .inactive:
                return Self.inactiveResponse(id: request.id, status: "absent")
            case .stillActive(let active):
                return BridgeResponse(id: request.id,
                                      ok: true,
                                      result: Self.activeResult(prompt: active.prompt,
                                                                event: active.event,
                                                                stale: true,
                                                                published: false),
                                      error: nil)
            case .resolved(let event):
                eventHub.publish(event)
                BridgeLogger.server.info("interactive prompt resolved workspace_id=\(context.workspaceID, privacy: .public) panel_id=\(context.panelID, privacy: .public) session_id=\(context.sessionID, privacy: .public) reason=absent")
                return BridgeResponse(id: request.id,
                                      ok: true,
                                      result: Self.resolvedResult(event: event),
                                      error: nil)
            }
        }
    }

    private func submit(_ request: BridgeRequest) throws -> BridgeResponse {
        let submitContext = try submitPromptContext(from: request)
        if submitContext.submitChannel == InteractivePromptSubmitChannel.codexAppServer ||
            submitContext.vendor == "codex" {
            return try submitCodexApproval(request, context: submitContext)
        }

        guard let context = try promptContext(from: request, requiresPromptID: true) else {
            throw BridgeInternalError.invalidRequest("submit_interactive_prompt requires workspace_id and panel_id")
        }
        if context.vendor == "codex" {
            return try submitCodexApproval(request, context: context)
        }
        guard context.vendor == "claude" else {
            throw BridgeInternalError.invalidRequest("submit_interactive_prompt only supports Claude workflow prompts")
        }
        guard let requestedPromptID = request.params?["prompt_id"]?.stringValue else {
            throw BridgeInternalError.invalidRequest("submit_interactive_prompt requires prompt_id")
        }

        let decision: String
        if let targetIndex = request.params?["target_index"]?.intValue {
            decision = "index:\(targetIndex)"
        } else if let inputSequence = request.params?["input_sequence"]?.stringValue {
            decision = "input:\(inputSequence)"
        } else {
            throw BridgeInternalError.invalidRequest("submit_interactive_prompt requires target_index or input_sequence")
        }
        let clientRequestID = request.params?["client_request_id"]?.stringValue
        if let clientRequestID {
            switch submitDeduper.check(clientRequestID: clientRequestID,
                                       promptID: requestedPromptID,
                                       decision: decision) {
            case .duplicate(let result):
                return BridgeResponse(id: request.id, ok: true, result: result, error: nil)
            case .conflict:
                throw BridgeInternalError.conflict("client_request_id was already used for a different decision")
            case .new:
                break
            }
        }

        let prompt = try activePromptForSubmit(context: context, requestedPromptID: requestedPromptID)
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
        guard response.ok else {
            return response
        }

        let resolvedEvent = resolveStoredPromptIfNeeded(context: context,
                                                        prompt: prompt,
                                                        reason: "submit")
        eventHub.publish(resolvedEvent)
        var result = response.result ?? [:]
        result["status"] = .string("resolved")
        result["prompt"] = .null
        result["resolved_event"] = Self.jsonValue(for: resolvedEvent)
        if let clientRequestID {
            result["client_request_id"] = .string(clientRequestID)
            submitDeduper.store(clientRequestID: clientRequestID,
                                promptID: requestedPromptID,
                                decision: decision,
                                result: result)
        }
        return BridgeResponse(id: request.id, ok: true, result: result, error: nil)
    }

    private func submitCodexApproval(_ request: BridgeRequest, context: SubmitPromptContext) throws -> BridgeResponse {
        guard let codexApprovalSubmitter else {
            throw BridgeInternalError.invalidRequest("submit_interactive_prompt requires Codex app-server runtime")
        }
        guard let promptID = request.params?["prompt_id"]?.stringValue else {
            throw BridgeInternalError.invalidRequest("submit_interactive_prompt requires prompt_id")
        }
        let answers = try Self.userInputAnswers(from: request.params?["answers"])
        let targetIndex = request.params?["target_index"]?.intValue
        guard answers != nil || targetIndex != nil else {
            throw BridgeInternalError.invalidRequest("submit_interactive_prompt requires target_index or answers for Codex approval prompts")
        }
        guard let lifecycleToken = request.params?["lifecycle_token"]?.stringValue else {
            throw BridgeInternalError.invalidRequest("submit_interactive_prompt requires lifecycle_token for Codex approval prompts")
        }
        let clientRequestID = request.params?["client_request_id"]?.stringValue
        let decision = answers.map { "answers:" + Self.canonicalAnswersDescription($0) }
            ?? "index:\(targetIndex ?? -1)"
        if let clientRequestID {
            switch submitDeduper.check(clientRequestID: clientRequestID,
                                       promptID: promptID,
                                       decision: decision) {
            case .conflict:
                throw BridgeInternalError.conflict("client_request_id was already used for a different decision")
            case .duplicate, .new:
                break
            }
        }

        let outcome: CodexAppServerApprovalSubmitOutcome
        if let answers {
            outcome = try codexApprovalSubmitter.submitUserInput(promptID: promptID,
                                                                 answers: answers,
                                                                 clientRequestID: clientRequestID,
                                                                 lifecycleToken: lifecycleToken,
                                                                 workspaceID: context.workspaceID,
                                                                 panelID: context.panelID,
                                                                 sessionID: context.sessionID)
        } else {
            outcome = try codexApprovalSubmitter.submitApproval(promptID: promptID,
                                                                targetIndex: targetIndex ?? -1,
                                                                clientRequestID: clientRequestID,
                                                                lifecycleToken: lifecycleToken,
                                                                workspaceID: context.workspaceID,
                                                                panelID: context.panelID,
                                                                sessionID: context.sessionID)
        }

        var result: [String: JSONValue] = [
            "submitted": .bool(true),
            "prompt_id": .string(promptID),
            "workspace_id": .string(context.workspaceID),
            "panel_id": .string(context.panelID),
            "session_id": .string(context.sessionID),
            "lifecycle_token": .string(lifecycleToken),
        ]
        switch outcome {
        case .pendingConfirmation:
            result["status"] = .string("pending_confirmation")
        case .alreadyResolved(let resolvedEvent):
            result["status"] = .string("already_resolved")
            result["prompt"] = .null
            result["resolved_event"] = Self.jsonValue(for: resolvedEvent)
            if let panelID = resolvedEvent.metadata?["panel_id"] {
                result["panel_id"] = .string(panelID)
            }
        }
        if let clientRequestID {
            result["client_request_id"] = .string(clientRequestID)
            submitDeduper.store(clientRequestID: clientRequestID,
                                promptID: promptID,
                                decision: decision,
                                result: result)
        }
        return BridgeResponse(id: request.id, ok: true, result: result, error: nil)
    }

    private func submitCodexApproval(_ request: BridgeRequest, context: PromptContext) throws -> BridgeResponse {
        try submitCodexApproval(request, context: SubmitPromptContext(workspaceID: context.workspaceID,
                                                                      panelID: context.panelID,
                                                                      sessionID: context.sessionID,
                                                                      vendor: context.vendor,
                                                                      submitChannel: nil))
    }

    private func activePromptForSubmit(context: PromptContext,
                                       requestedPromptID: String) throws -> InteractivePrompt {
        if let prompt = eventHub.activeInteractivePrompt(workspaceID: context.workspaceID,
                                                         sessionID: context.sessionID,
                                                         promptID: requestedPromptID),
           prompt.source == "claude_ask_user_question" {
            return prompt
        }

        let captured = try adapter.captureANSIOutput(route: context.route, maxLines: captureLineLimit)
        let detection = detector.detect(ansiOutput: captured.output,
                                        workspaceID: context.workspaceID,
                                        panelID: context.panelID,
                                        sessionID: context.sessionID,
                                        vendor: context.vendor)
        switch detection {
        case .present(let prompt):
            guard prompt.promptID == requestedPromptID else {
                throw BridgeInternalError.conflict("interactive prompt is no longer active")
            }
            _ = stateStore.recordPresent(key: context.stateKey, prompt: prompt) {
                makePromptEvent(context: context, prompt: prompt)
            }
            return prompt
        case .uncertain:
            guard let active = stateStore.activePrompt(key: context.stateKey),
                  active.promptID == requestedPromptID else {
                throw BridgeInternalError.conflict("interactive prompt is no longer active")
            }
            return active
        case .absent:
            throw BridgeInternalError.conflict("interactive prompt is no longer active")
        }
    }

    private func resolveStoredPromptIfNeeded(context: PromptContext,
                                             prompt: InteractivePrompt,
                                             reason: String) -> AgentEvent {
        if let event = stateStore.resolve(key: context.stateKey, reason: reason, makeEvent: { prompt in
            makeResolvedEvent(context: context, prompt: prompt, reason: reason)
        }) {
            return event
        }
        return makeResolvedEvent(context: context, prompt: prompt, reason: reason)
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

    private func submitPromptContext(from request: BridgeRequest) throws -> SubmitPromptContext {
        guard let params = request.params,
              let workspaceID = params["workspace_id"]?.stringValue,
              let panelID = params["panel_id"]?.stringValue else {
            throw BridgeInternalError.invalidRequest("\(request.action) requires workspace_id and panel_id")
        }
        let activeSession = sessionResolver.activeSessionForPanel(workspaceID: workspaceID, panelID: panelID)
        let submitChannel = params["submit_channel"]?.stringValue
        let vendor = activeSession?.vendor
            ?? params["vendor"]?.stringValue
            ?? (submitChannel == InteractivePromptSubmitChannel.codexAppServer ? "codex" : "claude")
        let sessionID = activeSession?.sessionID
            ?? params["session_id"]?.stringValue
            ?? "-"
        return SubmitPromptContext(workspaceID: workspaceID,
                                   panelID: panelID,
                                   sessionID: sessionID,
                                   vendor: vendor,
                                   submitChannel: submitChannel)
    }

    private func makePromptEvent(context: PromptContext, prompt: InteractivePrompt) -> AgentEvent {
        let seq = eventHub.nextSyntheticSeq(sessionID: context.sessionID)
        let eventID = "interactive-prompt:\(prompt.promptID):selected:\(prompt.selectedIndex)"
        var metadata = [
            "panel_id": context.panelID,
            "source": prompt.source,
            "prompt_id": prompt.promptID,
        ]
        if let submitChannel = prompt.submitChannel {
            metadata["submit_channel"] = submitChannel
        }
        return AgentEvent(eventID: eventID,
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
                          metadata: metadata,
                          payload: prompt.jsonValue)
    }

    private func makeResolvedEvent(context: PromptContext,
                                   prompt: InteractivePrompt,
                                   reason: String) -> AgentEvent {
        let seq = eventHub.nextSyntheticSeq(sessionID: context.sessionID)
        var metadata = [
            "panel_id": context.panelID,
            "source": prompt.source,
            "prompt_id": prompt.promptID,
            "reason": reason,
        ]
        if let submitChannel = prompt.submitChannel {
            metadata["submit_channel"] = submitChannel
        }
        return AgentEvent(eventID: "interactive-prompt-resolved:\(prompt.promptID):\(reason)",
                          seq: seq,
                          vendor: context.vendor,
                          workspaceID: context.workspaceID,
                          sessionID: context.sessionID,
                          timestamp: Self.iso8601Now(),
                          type: .interactivePromptResolved,
                          role: nil,
                          text: prompt.title,
                          name: nil,
                          input: nil,
                          output: nil,
                          toolCallID: nil,
                          metadata: metadata,
                          payload: prompt.jsonValue)
    }

    private static func userInputAnswers(from value: JSONValue?) throws -> [String: [String]]? {
        guard let value else {
            return nil
        }
        guard let object = value.objectValue else {
            throw BridgeInternalError.invalidRequest("submit_interactive_prompt answers must map question ids to answer arrays")
        }
        var answers: [String: [String]] = [:]
        for (questionID, entry) in object {
            guard let array = entry.arrayValue else {
                throw BridgeInternalError.invalidRequest("submit_interactive_prompt answers must map question ids to answer arrays")
            }
            let strings = array.compactMap(\.stringValue)
            guard strings.count == array.count else {
                throw BridgeInternalError.invalidRequest("submit_interactive_prompt answers must contain string values only")
            }
            answers[questionID] = strings
        }
        return answers
    }

    private static func canonicalAnswersDescription(_ answers: [String: [String]]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: answers, options: [.sortedKeys]) else {
            return "unencodable:\(UUID().uuidString)"
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func activeResult(prompt: InteractivePrompt,
                                     event: AgentEvent,
                                     stale: Bool,
                                     published: Bool) -> [String: JSONValue] {
        [
            "status": .string("active"),
            "prompt": prompt.jsonValue,
            "event": jsonValue(for: event),
            "stale": .bool(stale),
            "published": .bool(published),
        ]
    }

    private static func resolvedResult(event: AgentEvent) -> [String: JSONValue] {
        [
            "status": .string("resolved"),
            "prompt": .null,
            "resolved_event": jsonValue(for: event),
        ]
    }

    private static func inactiveResponse(id: String?, status: String) -> BridgeResponse {
        BridgeResponse(id: id,
                       ok: true,
                       result: [
                        "status": .string(status),
                        "prompt": .null,
                       ],
                       error: nil)
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

        var stateKey: InteractivePromptStateKey {
            InteractivePromptStateKey(workspaceID: workspaceID,
                                      panelID: panelID,
                                      sessionID: sessionID)
        }
    }

    private struct SubmitPromptContext {
        let workspaceID: String
        let panelID: String
        let sessionID: String
        let vendor: String
        let submitChannel: String?
    }
}

struct InteractivePromptStateKey: Hashable, Sendable {
    let workspaceID: String
    let panelID: String
    let sessionID: String
}

struct ActiveInteractivePromptSnapshot: Sendable {
    let prompt: InteractivePrompt
    let event: AgentEvent
}

final class InteractivePromptStateStore: @unchecked Sendable {
    struct RecordPresentResult: Sendable {
        let event: AgentEvent
        let shouldPublish: Bool
    }

    enum AbsentResult: Sendable {
        case inactive
        case stillActive(ActiveInteractivePromptSnapshot)
        case resolved(AgentEvent)
    }

    private struct Entry {
        var prompt: InteractivePrompt
        var event: AgentEvent
        var absentCount: Int
    }

    private let queue = DispatchQueue(label: "com.tidey.remote-bridge.interactive-prompt-state")
    private var entries = [InteractivePromptStateKey: Entry]()

    func recordPresent(key: InteractivePromptStateKey,
                       prompt: InteractivePrompt,
                       makeEvent: () -> AgentEvent) -> RecordPresentResult {
        queue.sync {
            if var entry = entries[key], entry.prompt == prompt {
                entry.absentCount = 0
                entries[key] = entry
                return RecordPresentResult(event: entry.event, shouldPublish: false)
            }
            let event = makeEvent()
            entries[key] = Entry(prompt: prompt, event: event, absentCount: 0)
            return RecordPresentResult(event: event, shouldPublish: true)
        }
    }

    func recordUncertain(key: InteractivePromptStateKey) -> ActiveInteractivePromptSnapshot? {
        queue.sync {
            guard let entry = entries[key] else {
                return nil
            }
            return ActiveInteractivePromptSnapshot(prompt: entry.prompt, event: entry.event)
        }
    }

    func recordAbsent(key: InteractivePromptStateKey,
                      threshold: Int,
                      makeEvent: (InteractivePrompt) -> AgentEvent) -> AbsentResult {
        queue.sync {
            guard var entry = entries[key] else {
                return .inactive
            }
            entry.absentCount += 1
            if entry.absentCount >= threshold {
                entries.removeValue(forKey: key)
                return .resolved(makeEvent(entry.prompt))
            }
            entries[key] = entry
            return .stillActive(ActiveInteractivePromptSnapshot(prompt: entry.prompt, event: entry.event))
        }
    }

    func activePrompt(key: InteractivePromptStateKey) -> InteractivePrompt? {
        queue.sync {
            entries[key]?.prompt
        }
    }

    func resolve(key: InteractivePromptStateKey,
                 reason: String,
                 makeEvent: (InteractivePrompt) -> AgentEvent) -> AgentEvent? {
        queue.sync {
            guard let entry = entries.removeValue(forKey: key) else {
                return nil
            }
            _ = reason
            return makeEvent(entry.prompt)
        }
    }
}
