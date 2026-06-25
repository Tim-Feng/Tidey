import Foundation

enum CodexAppServerConnectionError: Error {
    case closed
    case invalidJSONLine(String)
    case initializationTimedOut
    case requestFailed(CodexAppServerJSONRPCError)
    case unknownPrompt(String)
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
}

struct CodexAppServerInteractivePromptEnvelope: Sendable {
    let request: CodexAppServerApprovalRequest
    let prompt: InteractivePrompt
    let event: AgentEvent
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
    private let onNotification: NotificationHandler
    private let approvalContext: CodexAppServerApprovalContext?
    private let approvalStore: CodexAppServerApprovalPromptStore
    private let nextSequence: SequenceProvider
    private let timestampProvider: TimestampProvider
    private let onInteractivePrompt: InteractivePromptHandler
    private let onInteractivePromptResolved: InteractivePromptResolvedHandler
    private let resolvedApprovalLock = NSLock()
    private var resolvedApprovalsByPromptID: [String: CodexAppServerResolvedApproval] = [:]

    init(sendLine: @escaping SendLine,
         onNotification: @escaping NotificationHandler = { _ in },
         approvalContext: CodexAppServerApprovalContext? = nil,
         approvalStore: CodexAppServerApprovalPromptStore = CodexAppServerApprovalPromptStore(),
         nextSequence: @escaping SequenceProvider = { _ in 0 },
         timestampProvider: @escaping TimestampProvider = { CodexAppServerConnection.iso8601Now() },
         onInteractivePrompt: @escaping InteractivePromptHandler = { _ in },
         onInteractivePromptResolved: @escaping InteractivePromptResolvedHandler = { _ in }) {
        self.sendLine = sendLine
        self.onNotification = onNotification
        self.approvalContext = approvalContext
        self.approvalStore = approvalStore
        self.nextSequence = nextSequence
        self.timestampProvider = timestampProvider
        self.onInteractivePrompt = onInteractivePrompt
        self.onInteractivePromptResolved = onInteractivePromptResolved
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
            if CodexAppServerApprovalMethod(rawValue: method) != nil {
                BridgeLogger.server.info("codex app-server server request received method=\(method, privacy: .public) id=\(Self.idKey(from: id) ?? "-", privacy: .public)")
            } else {
                BridgeLogger.server.debug("codex app-server server request received method=\(method, privacy: .public) id=\(Self.idKey(from: id) ?? "-", privacy: .public)")
            }
            handleServerRequest(id: id, method: method, params: object["params"]?.objectValue ?? [:])
            return
        }
        if let id {
            handleClientResponse(id: id, result: object["result"], error: object["error"])
            return
        }
        if let method {
            onNotification(CodexAppServerNotification(method: method,
                                                      params: object["params"]?.objectValue ?? [:]))
        }
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
        for handler in pending.values {
            handler(.failure(failure))
        }
    }

    func pendingApprovalPromptEvents() -> [AgentEvent] {
        approvalStore.entries().map { entry in
            makePromptEvent(prompt: entry.prompt)
        }
    }

    func handleServerRequest(id: JSONValue, method: String, params: [String: JSONValue]) {
        if let request = CodexAppServerApprovalRequest(method: method, requestID: id, params: params) {
            handleApprovalRequest(request)
            return
        }
        if CodexAppServerApprovalMethod(rawValue: method) != nil {
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
            if let resolvedApproval = resolvedApproval(promptID: promptID) {
                let event = makeResolvedEvent(prompt: resolvedApproval.prompt, reason: "already_resolved")
                onInteractivePromptResolved(event)
                return event
            }
            throw BridgeInternalError.notFound("Unknown Codex approval prompt.")
        }
        rememberResolvedApproval(prompt: entry.prompt, response: response)
        let event = makeResolvedEvent(prompt: entry.prompt, reason: "submit")
        onInteractivePromptResolved(event)
        sendResult(id: entry.request.requestIDValue, result: response)
        return event
    }

    func sendResult(id: JSONValue, result: JSONValue) {
        try? sendIfOpen(.object([
            "id": id,
            "result": result,
        ]))
    }

    func sendError(id: JSONValue, code: Int, message: String, data: JSONValue? = nil) {
        var error: [String: JSONValue] = [
            "code": .number(Double(code)),
            "message": .string(message),
        ]
        if let data {
            error["data"] = data
        }
        try? sendIfOpen(.object([
            "id": id,
            "error": .object(error),
        ]))
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
        let incomingPrompt = request.makePrompt()
        if let resolvedApproval = resolvedApproval(promptID: incomingPrompt.promptID) {
            let event = makeResolvedEvent(prompt: resolvedApproval.prompt, reason: "already_resolved")
            onInteractivePromptResolved(event)
            sendResult(id: request.requestIDValue, result: resolvedApproval.response)
            return
        }
        guard approvalContext != nil else {
            sendError(id: request.requestIDValue,
                      code: -32000,
                      message: "Codex approval context is unavailable.")
            return
        }
        let prompt = approvalStore.record(request)
        let event = makePromptEvent(prompt: prompt)
        BridgeLogger.server.info("codex app-server approval prompt publishing method=\(request.method.rawValue, privacy: .public) prompt_id=\(prompt.promptID, privacy: .public) source=\(prompt.source, privacy: .public)")
        onInteractivePrompt(CodexAppServerInteractivePromptEnvelope(request: request,
                                                                    prompt: prompt,
                                                                    event: event))
    }

    private func makePromptEvent(prompt: InteractivePrompt) -> AgentEvent {
        guard let approvalContext else {
            preconditionFailure("approvalContext must exist before creating prompt events")
        }
        var metadata = [
            "panel_id": approvalContext.panelID,
            "source": prompt.source,
            "prompt_id": prompt.promptID,
        ]
        if let submitChannel = prompt.submitChannel {
            metadata["submit_channel"] = submitChannel
        }
        return AgentEvent(eventID: "codex-app-server-prompt:\(prompt.promptID)",
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
                          payload: prompt.jsonValue)
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

    private static func iso8601Now() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
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
