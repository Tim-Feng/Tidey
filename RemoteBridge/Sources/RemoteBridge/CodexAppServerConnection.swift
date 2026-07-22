import Foundation

enum CodexAppServerConnectionError: Error {
    case closed
    case invalidJSONLine(String)
    case initializationTimedOut
    case requestFailed(CodexAppServerJSONRPCError)
    case unknownPrompt(String)
    case responseTimedOut
    case protocolViolation
}

extension CodexAppServerConnectionError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .closed:
            return "Codex app-server connection is closed."
        case .invalidJSONLine(let line):
            return "Codex app-server sent invalid JSON: \(line)"
        case .initializationTimedOut:
            return "Codex app-server did not finish initialization in time."
        case .requestFailed(let error):
            return "Codex app-server request failed: \(error.message)"
        case .unknownPrompt(let promptID):
            return "Codex app-server prompt is unknown: \(promptID)"
        case .responseTimedOut:
            return "Codex app-server did not respond in time."
        case .protocolViolation:
            return "Codex app-server violated JSON-RPC request identity."
        }
    }
}

struct CodexAppServerJSONRPCError: Codable, Error, Sendable {
    let code: Int
    let message: String
    let data: JSONValue?

    init(code: Int, message: String, data: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }
}

struct CodexAppServerNotification: Sendable {
    let method: String
    let params: [String: JSONValue]
}

struct CodexAppServerApprovalContext: Sendable {
    let workspaceID: String
    let panelID: String
    let sessionID: String
    let epoch: String

    init(workspaceID: String,
         panelID: String,
         sessionID: String,
         epoch: String = "") {
        self.workspaceID = workspaceID
        self.panelID = panelID
        self.sessionID = sessionID
        self.epoch = epoch
    }
}

struct CodexAppServerInteractivePromptEnvelope: Sendable {
    let request: CodexAppServerApprovalRequest
    let prompt: InteractivePrompt
    let event: AgentEvent
}

// A response write is not an authoritative approval resolution. The prompt
// remains pending until the app-server emits a lifecycle terminal.
enum CodexAppServerApprovalSubmitOutcome: Sendable {
    case pendingConfirmation(promptID: String)
    case alreadyResolved(AgentEvent)
}

private struct CodexAppServerResolvedApproval: Sendable {
    let prompt: InteractivePrompt
    let response: JSONValue
}

final class CodexAppServerConnection {
    typealias SendLine = @Sendable (String) throws -> Void
    typealias ClientResponseHandler = (Result<JSONValue, CodexAppServerConnectionError>) -> Void
    typealias NotificationHandler = (CodexAppServerNotification) -> Void
    typealias SequenceProvider = (String) -> Int
    typealias TimestampProvider = () -> String
    typealias InteractivePromptHandler = (CodexAppServerInteractivePromptEnvelope) -> Void
    typealias InteractivePromptResolvedHandler = (AgentEvent) -> Void

    private let stateLock = NSRecursiveLock()
    private var nextRequestID = 1
    private var pendingClientResponses: [String: ClientResponseHandler] = [:]
    private var closed = false
    private let sendLine: SendLine
    private let sendLineConfirmed: SendLine?
    private let onNotification: NotificationHandler
    private let approvalContext: CodexAppServerApprovalContext?
    private let approvalStore: CodexAppServerApprovalPromptStore
    private let nextSequence: SequenceProvider
    private let timestampProvider: TimestampProvider
    private let onInteractivePrompt: InteractivePromptHandler
    private let onInteractivePromptResolved: InteractivePromptResolvedHandler
    private let onProtocolViolation: () -> Void
    // Serializes admission/publication with lifecycle terminals so observers
    // never receive a terminal before the pending event it terminates.
    private let publicationLock = NSRecursiveLock()
    private let resolvedApprovalLock = NSLock()
    private var resolvedApprovalsByPromptID: [String: CodexAppServerResolvedApproval] = [:]
    private let generationID = UUID().uuidString

    private func withPublicationLock<T>(_ body: () throws -> T) rethrows -> T {
        publicationLock.lock()
        defer { publicationLock.unlock() }
        return try body()
    }

    init(sendLine: @escaping SendLine,
         sendLineConfirmed: SendLine? = nil,
         onNotification: @escaping NotificationHandler = { _ in },
         approvalContext: CodexAppServerApprovalContext? = nil,
         approvalStore: CodexAppServerApprovalPromptStore = CodexAppServerApprovalPromptStore(),
         nextSequence: @escaping SequenceProvider = { _ in 0 },
         timestampProvider: @escaping TimestampProvider = { CodexAppServerConnection.iso8601Now() },
         onInteractivePrompt: @escaping InteractivePromptHandler = { _ in },
         onInteractivePromptResolved: @escaping InteractivePromptResolvedHandler = { _ in },
         onProtocolViolation: @escaping () -> Void = {}) {
        self.sendLine = sendLine
        self.sendLineConfirmed = sendLineConfirmed
        self.onNotification = onNotification
        self.approvalContext = approvalContext
        self.approvalStore = approvalStore
        self.nextSequence = nextSequence
        self.timestampProvider = timestampProvider
        self.onInteractivePrompt = onInteractivePrompt
        self.onInteractivePromptResolved = onInteractivePromptResolved
        self.onProtocolViolation = onProtocolViolation
    }

    @discardableResult
    func sendClientRequest(method: String,
                           params: [String: JSONValue] = [:],
                           onResponse: @escaping ClientResponseHandler) throws -> Int {
        stateLock.lock()
        guard !closed else {
            stateLock.unlock()
            throw CodexAppServerConnectionError.closed
        }
        let id = nextRequestID
        nextRequestID += 1
        pendingClientResponses[String(id)] = onResponse
        stateLock.unlock()

        do {
            try sendUnlocked(.object([
                "id": .number(Double(id)),
                "method": .string(method),
                "params": .object(params),
            ]))
        } catch {
            stateLock.lock()
            pendingClientResponses.removeValue(forKey: String(id))
            stateLock.unlock()
            throw error
        }
        return id
    }

    func sendClientNotification(method: String,
                                params: [String: JSONValue]? = nil) throws {
        var payload: [String: JSONValue] = [
            "method": .string(method),
        ]
        if let params {
            payload["params"] = .object(params)
        }
        try sendIfOpen(.object(payload))
    }

    func receiveLine(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }
        guard let data = trimmed.data(using: .utf8),
              let message = try? JSONDecoder().decode(JSONValue.self, from: data),
              let object = message.objectValue else {
            BridgeLogger.server.error("codex app-server ignored non-json stdout line=\(line, privacy: .public)")
            return
        }

        let id = object["id"]
        let method = object["method"]?.stringValue
        if let id, let method {
            let rawObject = Self.rawJSONObject(from: trimmed)
            guard let typedID = CodexAppServerRequestID(rawJSONObjectValue: rawObject?["id"])
                    ?? CodexAppServerRequestID(jsonValue: id) else {
                BridgeLogger.server.error("codex app-server server request with unsupported id shape method=\(method, privacy: .public)")
                return
            }
            if CodexAppServerApprovalRequestMethod(rawValue: method) != nil {
                BridgeLogger.server.info("codex app-server server request received method=\(method, privacy: .public) id=\(typedID.storageKey, privacy: .public)")
            } else {
                BridgeLogger.server.debug("codex app-server server request received method=\(method, privacy: .public) id=\(typedID.storageKey, privacy: .public)")
            }
            handleServerRequest(id: typedID,
                                method: method,
                                params: object["params"]?.objectValue ?? [:])
            return
        }
        if let id {
            handleClientResponse(id: id, result: object["result"], error: object["error"])
            return
        }
        if let method {
            let params = object["params"]?.objectValue ?? [:]
            let rawObject = method == "serverRequest/resolved"
                ? Self.rawJSONObject(from: trimmed)
                : nil
            handleApprovalLifecycleNotification(method: method,
                                                params: params,
                                                rawObject: rawObject)
            onNotification(CodexAppServerNotification(method: method,
                                                      params: params))
        }
    }

    private static func rawJSONObject(from line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }

    private func isClosedNow() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return closed
    }

    func close(error: CodexAppServerConnectionError? = nil) {
        let pending: [String: ClientResponseHandler]
        stateLock.lock()
        guard !closed else {
            stateLock.unlock()
            return
        }
        closed = true
        let failure = error ?? .closed
        pending = pendingClientResponses
        pendingClientResponses.removeAll()
        stateLock.unlock()
        expirePendingApprovals()
        for handler in pending.values {
            handler(.failure(failure))
        }
    }

    private func expirePendingApprovals() {
        guard approvalContext != nil else {
            return
        }
        withPublicationLock {
            let records = approvalStore.retireAndResolveAll(reason: "expired") {
                entry, reason, attempt in
                makeLifecycleResolvedEvent(entry, reason, attempt)
            }
            publishTerminalRecords(records)
        }
    }

    func pendingApprovalPromptEvents() -> [AgentEvent] {
        approvalStore.pendingStates().compactMap { state in
            guard let published = state.publishedEvent else {
                return nil
            }
            var extraMetadata: [String: String] = [:]
            switch state.phase {
            case .pending:
                extraMetadata["submit_state"] = "pending"
            case .submitting(let attempt):
                extraMetadata["submit_state"] = "submitting"
                if let clientRequestID = attempt.clientRequestID {
                    extraMetadata["client_request_id"] = clientRequestID
                }
            }
            return Self.overlayMetadata(published,
                                        extraMetadata: extraMetadata)
        }
    }

    private static func overlayMetadata(
        _ event: AgentEvent,
        extraMetadata: [String: String]
    ) -> AgentEvent {
        var metadata = event.metadata ?? [:]
        metadata.merge(extraMetadata) { _, override in override }
        return AgentEvent(eventID: event.eventID,
                          seq: event.seq,
                          vendor: event.vendor,
                          workspaceID: event.workspaceID,
                          sessionID: event.sessionID,
                          timestamp: event.timestamp,
                          type: event.type,
                          role: event.role,
                          text: event.text,
                          name: event.name,
                          input: event.input,
                          output: event.output,
                          toolCallID: event.toolCallID,
                          metadata: metadata,
                          payload: event.payload)
    }

    func handleServerRequest(id: CodexAppServerRequestID,
                             method: String,
                             params: [String: JSONValue]) {
        if let request = CodexAppServerApprovalRequest(method: method,
                                                       typedRequestID: id,
                                                       params: params) {
            handleApprovalRequest(request)
            return
        }
        if CodexAppServerApprovalRequestMethod(rawValue: method) != nil {
            sendError(id: id,
                      code: -32602,
                      message: "Invalid Codex approval request: \(method)")
            return
        }
        sendError(id: id,
                  code: -32601,
                  message: "Unsupported server request: \(method)")
    }

    @discardableResult
    func submitApproval(promptID: String, targetIndex: Int) throws -> AgentEvent {
        let entry: CodexAppServerApprovalPromptEntry
        let response: JSONValue
        do {
            (entry, response) = try approvalStore.resolveEntry(promptID: promptID,
                                                               targetIndex: targetIndex)
        } catch BridgeInternalError.notFound {
            return try alreadyResolvedEvent(promptID: promptID)
        }
        return completeSubmit(entry: entry, response: response)
    }

    @discardableResult
    func submitUserInput(promptID: String,
                         answers: [String: [String]]) throws -> AgentEvent {
        guard let pendingEntry = approvalStore.entry(promptID: promptID) else {
            return try alreadyResolvedEvent(promptID: promptID)
        }
        let response = try pendingEntry.request.userInputResponse(answers: answers)
        guard let entry = approvalStore.remove(promptID: promptID) else {
            return try alreadyResolvedEvent(promptID: promptID)
        }
        return completeSubmit(entry: entry, response: response)
    }

    // Transitional lifecycle submit seam. Registry/Bridge still call the
    // two-argument compatibility API above; callers that carry the published
    // lifecycle capability use this overload and await an app-server terminal.
    @discardableResult
    func submitApproval(promptID: String,
                        targetIndex: Int,
                        clientRequestID: String?,
                        lifecycleToken: String?) throws -> CodexAppServerApprovalSubmitOutcome {
        // Store admission is atomic. Do not hold publicationLock across the
        // confirmed transport write: close or an app-server lifecycle signal
        // must be able to publish the authoritative terminal while it blocks.
        try completeLifecycleSubmit(
            promptID: promptID,
            outcome: approvalStore.beginSubmit(promptID: promptID,
                                               targetIndex: targetIndex,
                                               clientRequestID: clientRequestID,
                                               lifecycleToken: lifecycleToken))
    }

    @discardableResult
    func submitUserInput(promptID: String,
                         answers: [String: [String]],
                         clientRequestID: String?,
                         lifecycleToken: String?) throws -> CodexAppServerApprovalSubmitOutcome {
        // See submitApproval: authoritative terminals must not wait for I/O.
        try completeLifecycleSubmit(
            promptID: promptID,
            outcome: approvalStore.beginSubmitUserInput(
                promptID: promptID,
                answers: answers,
                clientRequestID: clientRequestID,
                lifecycleToken: lifecycleToken))
    }

    private func completeLifecycleSubmit(
        promptID: String,
        outcome: CodexAppServerApprovalPromptStore.BeginSubmitOutcome
    ) throws -> CodexAppServerApprovalSubmitOutcome {
        switch outcome {
        case .terminal(let record):
            return .alreadyResolved(record.event)
        case .unknown:
            throw BridgeInternalError.notFound("Unknown Codex approval prompt.")
        case .duplicateInFlight:
            return .pendingConfirmation(promptID: promptID)
        case .inFlightConflict:
            throw BridgeInternalError.conflict("Codex approval submit is already in flight.")
        case .optionConflict:
            throw BridgeInternalError.conflict("A different decision was already submitted for this approval.")
        case .lifecycleTokenMismatch:
            throw BridgeInternalError.conflict("The approval card is from an older delivery of this request; refresh and decide again.")
        case .begin(let entry, let response, let lifecycleAttempt):
            do {
                try sendResponseLine(id: entry.request.requestID,
                                     bodyKey: "result",
                                     value: response,
                                     preferConfirmed: true)
            } catch {
                switch approvalStore.failSubmit(
                    promptID: promptID,
                    lifecycleAttempt: lifecycleAttempt
                ) {
                case .terminal(let record):
                    return .alreadyResolved(record.event)
                case .awaitingConfirmation, .supersededLifecycle:
                    throw error
                }
            }
            switch approvalStore.completeSubmitFlush(
                promptID: promptID,
                lifecycleAttempt: lifecycleAttempt
            ) {
            case .terminal(let record):
                return .alreadyResolved(record.event)
            case .awaitingConfirmation, .supersededLifecycle:
                return .pendingConfirmation(promptID: promptID)
            }
        }
    }

    private func alreadyResolvedEvent(promptID: String) throws -> AgentEvent {
        guard let resolvedApproval = resolvedApproval(promptID: promptID) else {
            throw BridgeInternalError.notFound("Unknown Codex approval prompt.")
        }
        let event = makeResolvedEvent(prompt: resolvedApproval.prompt, reason: "already_resolved")
        onInteractivePromptResolved(event)
        return event
    }

    private func completeSubmit(entry: CodexAppServerApprovalPromptEntry,
                                response: JSONValue) -> AgentEvent {
        rememberResolvedApproval(prompt: entry.prompt, response: response)
        let event = makeResolvedEvent(prompt: entry.prompt, reason: "submit")
        onInteractivePromptResolved(event)
        sendResult(id: entry.request.requestID, result: response)
        return event
    }

    private func handleApprovalLifecycleNotification(
        method: String,
        params: [String: JSONValue],
        rawObject: [String: Any]?
    ) {
        guard approvalContext != nil else {
            return
        }
        withPublicationLock {
            let records: [CodexAppServerApprovalTerminalRecord]
            switch method {
            case "serverRequest/resolved":
                guard let threadID = Self.notificationThreadID(from: params) else {
                    return
                }
                let rawParams = rawObject?["params"] as? [String: Any]
                let requestID = CodexAppServerRequestID(
                    rawJSONObjectValue: rawParams?["requestId"])
                    ?? CodexAppServerRequestID(jsonValue: params["requestId"])
                guard let requestIDKey = requestID?.storageKey else {
                    return
                }
                records = approvalStore.resolveExternally(
                    reason: "server_resolved",
                    where: {
                        $0.threadID == threadID
                            && $0.requestIDKey == requestIDKey
                    },
                    makeEvent: makeLifecycleResolvedEvent)
            case "turn/completed", "turn/aborted":
                guard let threadID = Self.notificationThreadID(from: params),
                      let turnID = Self.notificationTurnID(from: params) else {
                    return
                }
                records = approvalStore.resolveExternally(
                    reason: "turn_completed",
                    where: {
                        $0.threadID == threadID && $0.turnID == turnID
                    },
                    makeEvent: makeLifecycleResolvedEvent)
            default:
                return
            }
            publishTerminalRecords(records)
        }
    }

    private func publishTerminalRecords(
        _ records: [CodexAppServerApprovalTerminalRecord]
    ) {
        for record in records {
            BridgeLogger.server.info("codex app-server approval prompt resolved prompt_id=\(record.entry.prompt.promptID, privacy: .public) reason=\(record.reason, privacy: .public)")
            onInteractivePromptResolved(record.event)
        }
    }

    private static func notificationThreadID(
        from params: [String: JSONValue]
    ) -> String? {
        params["threadId"]?.stringValue
            ?? params["thread"]?.objectValue?["id"]?.stringValue
    }

    private static func notificationTurnID(
        from params: [String: JSONValue]
    ) -> String? {
        params["turnId"]?.stringValue
            ?? params["turn"]?.objectValue?["id"]?.stringValue
    }

    func sendResult(id: CodexAppServerRequestID, result: JSONValue) {
        try? sendResponseLine(id: id,
                              bodyKey: "result",
                              value: result,
                              preferConfirmed: false)
    }

    func sendError(id: CodexAppServerRequestID,
                   code: Int,
                   message: String,
                   data: JSONValue? = nil) {
        var error: [String: JSONValue] = [
            "code": .number(Double(code)),
            "message": .string(message),
        ]
        if let data {
            error["data"] = data
        }
        try? sendResponseLine(id: id,
                              bodyKey: "error",
                              value: .object(error),
                              preferConfirmed: false)
    }

    private func sendResponseLine(id: CodexAppServerRequestID,
                                  bodyKey: String,
                                  value: JSONValue,
                                  preferConfirmed: Bool) throws {
        stateLock.lock()
        let isClosed = closed
        stateLock.unlock()
        guard !isClosed else {
            throw CodexAppServerConnectionError.closed
        }
        let data = try JSONEncoder().encode(value)
        let valueJSON = String(decoding: data, as: UTF8.self)
        let line = "{\"id\":\(id.jsonToken),\"\(bodyKey)\":\(valueJSON)}\n"
        if preferConfirmed, let sendLineConfirmed {
            try sendLineConfirmed(line)
            return
        }
        try sendLine(line)
    }

    private func handleClientResponse(id: JSONValue, result: JSONValue?, error: JSONValue?) {
        guard let key = Self.idKey(from: id) else {
            return
        }
        stateLock.lock()
        let handler = pendingClientResponses.removeValue(forKey: key)
        stateLock.unlock()
        guard let handler else {
            return
        }
        if let errorObject = error?.objectValue {
            let code = errorObject["code"]?.intValue ?? -32000
            let message = errorObject["message"]?.stringValue ?? "Codex app-server request failed."
            handler(.failure(.requestFailed(CodexAppServerJSONRPCError(code: code,
                                                                        message: message,
                                                                        data: errorObject["data"]))))
            return
        }
        handler(.success(result ?? .object([:])))
    }

    private func sendIfOpen(_ value: JSONValue) throws {
        stateLock.lock()
        let isClosed = closed
        stateLock.unlock()
        guard isClosed == false else {
            throw CodexAppServerConnectionError.closed
        }
        try sendUnlocked(value)
    }

    private func sendUnlocked(_ value: JSONValue) throws {
        let data = try JSONEncoder().encode(value)
        guard let line = String(data: data, encoding: .utf8) else {
            throw CodexAppServerConnectionError.invalidJSONLine("<encoding failed>")
        }
        try sendLine(line + "\n")
    }

    static func idKey(from id: JSONValue) -> String? {
        switch id {
        case .string(let value):
            return value
        case .number(let value):
            if value.isFinite,
               value.rounded(.towardZero) == value,
               let exact = Int(exactly: value) {
                return String(exact)
            }
            return String(value)
        default:
            return nil
        }
    }

    private func handleApprovalRequest(_ request: CodexAppServerApprovalRequest) {
        guard let approvalContext else {
            sendError(id: request.requestID,
                      code: -32000,
                      message: "Codex approval context is unavailable.")
            return
        }
        withPublicationLock {
            guard !isClosedNow() else {
                return
            }
            let prompt = approvalContext.epoch.isEmpty
                ? request.makePrompt()
                : request.makePrompt(epoch: approvalContext.epoch)

            // Retain compatibility for the old two-argument submit path until
            // Registry/Bridge switch to lifecycle outcomes in their own slice.
            if let resolvedApproval = resolvedApproval(promptID: prompt.promptID) {
                let event = makeResolvedEvent(prompt: resolvedApproval.prompt,
                                              reason: "already_resolved")
                onInteractivePromptResolved(event)
                sendResult(id: request.requestID,
                           result: resolvedApproval.response)
                return
            }

            let entry = CodexAppServerApprovalPromptEntry(request: request,
                                                          prompt: prompt)
            let outcome = approvalStore.register(entry: entry) {
                entry, reason, attempt in
                makeLifecycleResolvedEvent(entry, reason, attempt)
            }
            let attempt: Int
            switch outcome {
            case .rejectedRetired:
                return
            case .recorded(_, let recordedAttempt):
                attempt = recordedAttempt
                BridgeLogger.server.info("codex app-server approval prompt publishing method=\(request.method.rawValue, privacy: .public) prompt_id=\(prompt.promptID, privacy: .public) source=\(prompt.source, privacy: .public)")
            case .reactivated(_, let reactivatedAttempt):
                attempt = reactivatedAttempt
                BridgeLogger.server.info("codex app-server approval prompt redelivered method=\(request.method.rawValue, privacy: .public) prompt_id=\(prompt.promptID, privacy: .public)")
            case .supersededPayloadChanged(let terminal, _, let replacementAttempt):
                attempt = replacementAttempt
                publishTerminalRecords([terminal])
            }
            let event = makePromptEvent(prompt: prompt,
                                        request: request,
                                        attempt: attempt)
            approvalStore.recordPublishedPromptEvent(promptID: prompt.promptID,
                                                     event: event)
            onInteractivePrompt(CodexAppServerInteractivePromptEnvelope(
                request: request,
                prompt: prompt,
                event: event))
        }
    }

    private func makePromptEvent(prompt: InteractivePrompt,
                                 request: CodexAppServerApprovalRequest,
                                 attempt: Int) -> AgentEvent {
        guard let approvalContext else {
            preconditionFailure("approvalContext must exist before creating prompt events")
        }
        var metadata = [
            "panel_id": approvalContext.panelID,
            "source": prompt.source,
            "prompt_id": prompt.promptID,
            "attempt": String(attempt),
            "connection_generation": generationID,
        ]
        if !approvalContext.epoch.isEmpty {
            metadata["app_server_epoch"] = approvalContext.epoch
        }
        if let submitChannel = prompt.submitChannel {
            metadata["submit_channel"] = submitChannel
        }
        applyRequestIdentity(request, to: &metadata)
        let lifecycleToken = "codex-app-server-prompt:\(prompt.promptID):\(deliveryToken(attempt: attempt))"
        var payload = prompt.jsonValue.objectValue ?? [:]
        payload["lifecycle_token"] = .string(lifecycleToken)
        return AgentEvent(eventID: lifecycleToken,
                          seq: nextSequence(approvalContext.sessionID),
                          vendor: "codex",
                          workspaceID: approvalContext.workspaceID,
                          sessionID: approvalContext.sessionID,
                          timestamp: timestampProvider(),
                          type: .interactivePrompt,
                          role: nil,
                          text: prompt.title,
                          name: nil,
                          input: nil,
                          output: nil,
                          toolCallID: nil,
                          metadata: metadata,
                          payload: .object(payload))
    }

    private func makeResolvedEvent(prompt: InteractivePrompt, reason: String) -> AgentEvent {
        guard let approvalContext else {
            preconditionFailure("approvalContext must exist before creating resolved events")
        }
        var metadata = [
            "panel_id": approvalContext.panelID,
            "source": prompt.source,
            "prompt_id": prompt.promptID,
            "reason": reason,
        ]
        if let submitChannel = prompt.submitChannel {
            metadata["submit_channel"] = submitChannel
        }
        return AgentEvent(eventID: "codex-app-server-prompt-resolved:\(prompt.promptID):\(reason)",
                          seq: nextSequence(approvalContext.sessionID),
                          vendor: "codex",
                          workspaceID: approvalContext.workspaceID,
                          sessionID: approvalContext.sessionID,
                          timestamp: timestampProvider(),
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

    private func makeLifecycleResolvedEvent(
        _ entry: CodexAppServerApprovalPromptEntry,
        _ reason: String,
        _ attempt: Int
    ) -> AgentEvent {
        guard let approvalContext else {
            preconditionFailure("approvalContext must exist before creating resolved events")
        }
        let prompt = entry.prompt
        let lifecycleToken = "codex-app-server-prompt:\(prompt.promptID):\(deliveryToken(attempt: attempt))"
        var metadata = [
            "panel_id": approvalContext.panelID,
            "source": prompt.source,
            "prompt_id": prompt.promptID,
            "reason": reason,
            "attempt": String(attempt),
            "connection_generation": generationID,
            "lifecycle_token": lifecycleToken,
        ]
        if !approvalContext.epoch.isEmpty {
            metadata["app_server_epoch"] = approvalContext.epoch
        }
        if let submitChannel = prompt.submitChannel {
            metadata["submit_channel"] = submitChannel
        }
        applyRequestIdentity(entry.request, to: &metadata)
        var payload = prompt.jsonValue.objectValue ?? [:]
        payload["lifecycle_token"] = .string(lifecycleToken)
        return AgentEvent(
            eventID: "codex-app-server-prompt-resolved:\(prompt.promptID):\(reason):\(deliveryToken(attempt: attempt))",
            seq: nextSequence(approvalContext.sessionID),
            vendor: "codex",
            workspaceID: approvalContext.workspaceID,
            sessionID: approvalContext.sessionID,
            timestamp: timestampProvider(),
            type: .interactivePromptResolved,
            role: nil,
            text: prompt.title,
            name: nil,
            input: nil,
            output: nil,
            toolCallID: nil,
            metadata: metadata,
            payload: .object(payload))
    }

    private static func iso8601Now() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }

    private func deliveryToken(attempt: Int) -> String {
        "g\(generationID)a\(attempt)"
    }

    private func applyRequestIdentity(
        _ request: CodexAppServerApprovalRequest,
        to metadata: inout [String: String]
    ) {
        metadata["thread_id"] = request.threadID
        metadata["turn_id"] = request.turnID
        metadata["item_id"] = request.itemID
        metadata["request_id"] = request.requestIDKey
    }

    private func rememberResolvedApproval(prompt: InteractivePrompt, response: JSONValue) {
        resolvedApprovalLock.withCodexResolvedApprovalLock {
            resolvedApprovalsByPromptID[prompt.promptID] = CodexAppServerResolvedApproval(prompt: prompt,
                                                                                          response: response)
        }
    }

    private func resolvedApproval(promptID: String) -> CodexAppServerResolvedApproval? {
        resolvedApprovalLock.withCodexResolvedApprovalLock {
            resolvedApprovalsByPromptID[promptID]
        }
    }
}

private extension NSLock {
    func withCodexResolvedApprovalLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
