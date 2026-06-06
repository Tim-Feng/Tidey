import Foundation

enum CodexAppServerConnectionError: Error {
    case closed
    case invalidJSONLine(String)
    case requestFailed(CodexAppServerJSONRPCError)
    case unknownPrompt(String)
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

final class CodexAppServerConnection {
    typealias SendLine = @Sendable (String) throws -> Void
    typealias ClientResponseHandler = (Result<JSONValue, CodexAppServerConnectionError>) -> Void
    typealias NotificationHandler = (CodexAppServerNotification) -> Void
    typealias SequenceProvider = (String) -> Int
    typealias TimestampProvider = () -> String
    typealias InteractivePromptHandler = (CodexAppServerInteractivePromptEnvelope) -> Void
    typealias InteractivePromptResolvedHandler = (AgentEvent) -> Void

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
        guard !closed else {
            throw CodexAppServerConnectionError.closed
        }
        let id = nextRequestID
        nextRequestID += 1
        pendingClientResponses[String(id)] = onResponse
        try send(.object([
            "id": .number(Double(id)),
            "method": .string(method),
            "params": .object(params),
        ]))
        return id
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
        guard !closed else {
            return
        }
        closed = true
        let failure = error ?? .closed
        let pending = pendingClientResponses
        pendingClientResponses.removeAll()
        for handler in pending.values {
            handler(.failure(failure))
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
        let (entry, response) = try approvalStore.resolveEntry(promptID: promptID,
                                                               targetIndex: targetIndex)
        sendResult(id: entry.request.requestIDValue, result: response)
        let event = makeResolvedEvent(prompt: entry.prompt, reason: "submit")
        onInteractivePromptResolved(event)
        return event
    }

    func sendResult(id: JSONValue, result: JSONValue) {
        try? send(.object([
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
        try? send(.object([
            "id": id,
            "error": .object(error),
        ]))
    }

    private func handleClientResponse(id: JSONValue, result: JSONValue?, error: JSONValue?) {
        guard let key = Self.idKey(from: id),
              let handler = pendingClientResponses.removeValue(forKey: key) else {
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

    private func send(_ value: JSONValue) throws {
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
        guard approvalContext != nil else {
            sendError(id: request.requestIDValue,
                      code: -32000,
                      message: "Codex approval context is unavailable.")
            return
        }
        let prompt = approvalStore.record(request)
        let event = makePromptEvent(prompt: prompt)
        onInteractivePrompt(CodexAppServerInteractivePromptEnvelope(request: request,
                                                                    prompt: prompt,
                                                                    event: event))
    }

    private func makePromptEvent(prompt: InteractivePrompt) -> AgentEvent {
        guard let approvalContext else {
            preconditionFailure("approvalContext must exist before creating prompt events")
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
                          metadata: [
                            "panel_id": approvalContext.panelID,
                            "source": prompt.source,
                            "prompt_id": prompt.promptID,
                          ],
                          payload: prompt.jsonValue)
    }

    private func makeResolvedEvent(prompt: InteractivePrompt, reason: String) -> AgentEvent {
        guard let approvalContext else {
            preconditionFailure("approvalContext must exist before creating resolved events")
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
                          metadata: [
                            "panel_id": approvalContext.panelID,
                            "source": prompt.source,
                            "prompt_id": prompt.promptID,
                            "reason": reason,
                          ],
                          payload: prompt.jsonValue)
    }

    private static func iso8601Now() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }
}
