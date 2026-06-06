import Foundation

struct CodexAppServerLaunchConfiguration: Equatable, Sendable {
    let executablePath: String
    let arguments: [String]
    let workingDirectory: String
    let environment: [String: String]

    static func direct(codexExecutablePath: String = "codex",
                       workingDirectory: String,
                       environment: [String: String] = [:]) -> CodexAppServerLaunchConfiguration {
        CodexAppServerLaunchConfiguration(executablePath: codexExecutablePath,
                                          arguments: ["app-server"],
                                          workingDirectory: workingDirectory,
                                          environment: environment)
    }
}

struct CodexAppServerRuntimeContext: Equatable, Sendable {
    let workspaceID: String
    let panelID: String
    let sessionID: String
}

final class CodexAppServerHeadlessRuntime {
    typealias SequenceProvider = (String) -> Int
    typealias TimestampProvider = () -> String
    typealias AgentEventHandler = (AgentEvent) -> Void

    private let context: CodexAppServerRuntimeContext
    private let nextSequence: SequenceProvider
    private let timestampProvider: TimestampProvider
    private let onAgentEvent: AgentEventHandler

    init(context: CodexAppServerRuntimeContext,
         nextSequence: @escaping SequenceProvider,
         timestampProvider: @escaping TimestampProvider,
         onAgentEvent: @escaping AgentEventHandler) {
        self.context = context
        self.nextSequence = nextSequence
        self.timestampProvider = timestampProvider
        self.onAgentEvent = onAgentEvent
    }

    @discardableResult
    func startThread(on connection: CodexAppServerConnection,
                     cwd: String?,
                     model: String? = nil,
                     approvalPolicy: String? = nil,
                     sandbox: JSONValue? = nil,
                     ephemeral: Bool = true,
                     onResponse: @escaping CodexAppServerConnection.ClientResponseHandler = { _ in }) throws -> Int {
        var params: [String: JSONValue] = [
            "ephemeral": .bool(ephemeral),
        ]
        if let cwd {
            params["cwd"] = .string(cwd)
        }
        if let model {
            params["model"] = .string(model)
        }
        if let approvalPolicy {
            params["approvalPolicy"] = .string(approvalPolicy)
        }
        if let sandbox {
            params["sandbox"] = sandbox
        }
        return try connection.sendClientRequest(method: "thread/start",
                                                params: params,
                                                onResponse: onResponse)
    }

    @discardableResult
    func startTurn(on connection: CodexAppServerConnection,
                   threadID: String,
                   text: String,
                   cwd: String? = nil,
                   approvalPolicy: String? = nil,
                   sandboxPolicy: JSONValue? = nil,
                   onResponse: @escaping CodexAppServerConnection.ClientResponseHandler = { _ in }) throws -> Int {
        var params: [String: JSONValue] = [
            "threadId": .string(threadID),
            "input": .array([
                .object([
                    "type": .string("text"),
                    "text": .string(text),
                    "text_elements": .array([]),
                ]),
            ]),
        ]
        if let cwd {
            params["cwd"] = .string(cwd)
        }
        if let approvalPolicy {
            params["approvalPolicy"] = .string(approvalPolicy)
        }
        if let sandboxPolicy {
            params["sandboxPolicy"] = sandboxPolicy
        }
        return try connection.sendClientRequest(method: "turn/start",
                                                params: params,
                                                onResponse: onResponse)
    }

    func handleNotification(_ notification: CodexAppServerNotification) {
        guard let event = makeEvent(from: notification) else {
            return
        }
        onAgentEvent(event)
    }

    private func makeEvent(from notification: CodexAppServerNotification) -> AgentEvent? {
        switch notification.method {
        case "thread/started":
            return makeThreadStartedEvent(notification)
        case "turn/started":
            return makeTurnLifecycleEvent(notification, type: .thinking, text: "Codex turn started")
        case "turn/completed":
            return makeTurnCompletedEvent(notification)
        case "warning":
            return makeWarningEvent(notification)
        case "error":
            return makeErrorEvent(notification)
        case "item/started":
            return makeItemStartedEvent(notification)
        case "item/completed":
            return makeItemCompletedEvent(notification)
        case "item/agentMessage/delta":
            return nil
        case "command/exec/outputDelta",
             "process/outputDelta",
             "item/commandExecution/outputDelta":
            guard let delta = notification.params["delta"]?.stringValue else {
                return nil
            }
            return makeEvent(method: notification.method,
                             type: .toolResult,
                             text: nil,
                             name: "terminal_stream",
                             input: nil,
                             output: delta,
                             toolCallID: Self.itemID(from: notification.params),
                             payloadKind: "terminal_stream",
                             params: notification.params)
        case "item/commandExecution/terminalInteraction":
            guard let stdin = notification.params["stdin"]?.stringValue else {
                return nil
            }
            return makeEvent(method: notification.method,
                             type: .toolCall,
                             text: nil,
                             name: "terminal_interaction",
                             input: stdin,
                             output: nil,
                             toolCallID: Self.itemID(from: notification.params),
                             payloadKind: "terminal_input",
                             params: notification.params)
        case "item/fileChange/patchUpdated":
            return makeEvent(method: notification.method,
                             type: .toolCall,
                             text: nil,
                             name: "file_change_patch",
                             input: nil,
                             output: nil,
                             toolCallID: Self.itemID(from: notification.params),
                             payloadKind: "file_change_patch",
                             params: notification.params)
        default:
            return nil
        }
    }

    private func makeThreadStartedEvent(_ notification: CodexAppServerNotification) -> AgentEvent? {
        guard let thread = notification.params["thread"]?.objectValue,
              let threadID = thread["id"]?.stringValue else {
            return nil
        }
        let text = Self.nonEmptyString(thread["name"]) ?? Self.nonEmptyString(thread["preview"]) ?? threadID
        return makeEvent(method: notification.method,
                         type: .sessionStarted,
                         text: text,
                         name: nil,
                         input: nil,
                         output: nil,
                         toolCallID: nil,
                         payloadKind: "thread_started",
                         params: notification.params)
    }

    private func makeTurnLifecycleEvent(_ notification: CodexAppServerNotification,
                                        type: AgentEventKind,
                                        text: String?) -> AgentEvent? {
        guard Self.threadID(from: notification.params) != nil,
              Self.turnID(from: notification.params) != nil else {
            return nil
        }
        return makeEvent(method: notification.method,
                         type: type,
                         text: text,
                         name: nil,
                         input: nil,
                         output: nil,
                         toolCallID: nil,
                         payloadKind: type == .thinking ? "turn_started" : "turn_completed",
                         params: notification.params)
    }

    private func makeTurnCompletedEvent(_ notification: CodexAppServerNotification) -> AgentEvent? {
        guard let turn = notification.params["turn"]?.objectValue else {
            return makeTurnLifecycleEvent(notification, type: .assistantFinal, text: nil)
        }
        if turn["status"]?.stringValue == "failed" {
            let message = Self.errorMessage(from: turn["error"]?.objectValue)
                ?? "Codex turn failed."
            return makeEvent(method: notification.method,
                             type: .assistantMessage,
                             text: message,
                             name: nil,
                             input: nil,
                             output: nil,
                             toolCallID: nil,
                             payloadKind: "turn_failed",
                             params: notification.params)
        }
        return makeTurnLifecycleEvent(notification, type: .assistantFinal, text: nil)
    }

    private func makeWarningEvent(_ notification: CodexAppServerNotification) -> AgentEvent? {
        guard let message = Self.nonEmptyString(notification.params["message"]) else {
            return nil
        }
        return makeEvent(method: notification.method,
                         type: .assistantMessage,
                         text: message,
                         name: nil,
                         input: nil,
                         output: nil,
                         toolCallID: nil,
                         payloadKind: "warning",
                         params: notification.params)
    }

    private func makeErrorEvent(_ notification: CodexAppServerNotification) -> AgentEvent? {
        if notification.params["willRetry"]?.boolValue == true {
            return nil
        }
        let message = Self.errorMessage(from: notification.params["error"]?.objectValue)
            ?? "Codex app-server error."
        return makeEvent(method: notification.method,
                         type: .assistantMessage,
                         text: message,
                         name: nil,
                         input: nil,
                         output: nil,
                         toolCallID: nil,
                         payloadKind: "error",
                         params: notification.params)
    }

    private func makeItemStartedEvent(_ notification: CodexAppServerNotification) -> AgentEvent? {
        guard let item = notification.params["item"]?.objectValue,
              let itemType = item["type"]?.stringValue else {
            return nil
        }
        switch itemType {
        case "userMessage":
            return makeEvent(method: notification.method,
                             type: .userMessage,
                             text: Self.userMessageText(from: item),
                             name: nil,
                             input: nil,
                             output: nil,
                             toolCallID: item["id"]?.stringValue,
                             payloadKind: "user_message",
                             params: notification.params)
        case "commandExecution":
            let command = Self.nonEmptyString(item["command"])
            return makeEvent(method: notification.method,
                             type: .toolCall,
                             text: command,
                             name: "command_execution",
                             input: command,
                             output: nil,
                             toolCallID: item["id"]?.stringValue,
                             payloadKind: "command_execution_started",
                             params: notification.params)
        case "fileChange":
            return makeEvent(method: notification.method,
                             type: .toolCall,
                             text: nil,
                             name: "file_change",
                             input: nil,
                             output: nil,
                             toolCallID: item["id"]?.stringValue,
                             payloadKind: "file_change_started",
                             params: notification.params)
        default:
            return nil
        }
    }

    private func makeItemCompletedEvent(_ notification: CodexAppServerNotification) -> AgentEvent? {
        guard let item = notification.params["item"]?.objectValue,
              let itemType = item["type"]?.stringValue else {
            return nil
        }
        switch itemType {
        case "commandExecution":
            return makeEvent(method: notification.method,
                             type: .toolResult,
                             text: nil,
                             name: "command_execution",
                             input: nil,
                             output: Self.nonEmptyString(item["aggregatedOutput"]),
                             toolCallID: item["id"]?.stringValue,
                             payloadKind: "command_execution_completed",
                             params: notification.params)
        case "fileChange":
            return makeEvent(method: notification.method,
                             type: .toolResult,
                             text: nil,
                             name: "file_change",
                             input: nil,
                             output: nil,
                             toolCallID: item["id"]?.stringValue,
                             payloadKind: "file_change_completed",
                             params: notification.params)
        case "agentMessage":
            guard let text = Self.nonEmptyString(item["text"]) else {
                return nil
            }
            return makeEvent(method: notification.method,
                             type: .assistantMessage,
                             text: text,
                             name: nil,
                             input: nil,
                             output: nil,
                             toolCallID: item["id"]?.stringValue,
                             payloadKind: "assistant_message",
                             params: notification.params)
        default:
            return nil
        }
    }

    private func makeEvent(method: String,
                           type: AgentEventKind,
                           text: String?,
                           name: String?,
                           input: String?,
                           output: String?,
                           toolCallID: String?,
                           payloadKind: String,
                           params: [String: JSONValue]) -> AgentEvent {
        let seq = nextSequence(context.sessionID)
        let metadata = metadata(method: method, params: params)
        var payload: [String: JSONValue] = [
            "kind": .string(payloadKind),
            "source": .string("codex_app_server"),
            "method": .string(method),
            "params": .object(params),
        ]
        if let threadID = Self.threadID(from: params) {
            payload["thread_id"] = .string(threadID)
        }
        if let turnID = Self.turnID(from: params) {
            payload["turn_id"] = .string(turnID)
        }
        if let itemID = toolCallID ?? Self.itemID(from: params) {
            payload["item_id"] = .string(itemID)
        }
        if let processID = Self.processID(from: params) {
            payload["process_id"] = .string(processID)
        }
        return AgentEvent(eventID: "codex-app-server:\(method):\(seq)",
                          seq: seq,
                          vendor: "codex",
                          workspaceID: context.workspaceID,
                          sessionID: context.sessionID,
                          timestamp: timestampProvider(),
                          type: type,
                          role: nil,
                          text: text,
                          name: name,
                          input: input,
                          output: output,
                          toolCallID: toolCallID ?? Self.itemID(from: params),
                          metadata: metadata,
                          payload: .object(payload))
    }

    private func metadata(method: String, params: [String: JSONValue]) -> [String: String] {
        var metadata: [String: String] = [
            "panel_id": context.panelID,
            "source": "codex_app_server",
            "app_server_method": method,
        ]
        if let threadID = Self.threadID(from: params) {
            metadata["thread_id"] = threadID
        }
        if let turnID = Self.turnID(from: params) {
            metadata["turn_id"] = turnID
        }
        if let itemID = Self.itemID(from: params) {
            metadata["item_id"] = itemID
        }
        if let processID = Self.processID(from: params) {
            metadata["process_id"] = processID
        }
        return metadata
    }

    private static func threadID(from params: [String: JSONValue]) -> String? {
        params["threadId"]?.stringValue
            ?? params["thread"]?.objectValue?["id"]?.stringValue
    }

    private static func turnID(from params: [String: JSONValue]) -> String? {
        params["turnId"]?.stringValue
            ?? params["turn"]?.objectValue?["id"]?.stringValue
    }

    private static func itemID(from params: [String: JSONValue]) -> String? {
        params["itemId"]?.stringValue
            ?? params["item"]?.objectValue?["id"]?.stringValue
    }

    private static func processID(from params: [String: JSONValue]) -> String? {
        params["processId"]?.stringValue
            ?? params["item"]?.objectValue?["processId"]?.stringValue
    }

    private static func nonEmptyString(_ value: JSONValue?) -> String? {
        guard case .string(let text) = value else {
            return nil
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : text
    }

    private static func errorMessage(from error: [String: JSONValue]?) -> String? {
        guard let error else {
            return nil
        }
        let message = nonEmptyString(error["message"])
        let details = nonEmptyString(error["additionalDetails"])
        switch (message, details) {
        case let (.some(message), .some(details)) where message != details:
            return "\(message)\n\(details)"
        case let (.some(message), _):
            return message
        case let (_, .some(details)):
            return details
        default:
            return nil
        }
    }

    private static func userMessageText(from item: [String: JSONValue]) -> String? {
        guard let content = item["content"]?.arrayValue else {
            return nil
        }
        let parts = content.compactMap { value -> String? in
            guard let object = value.objectValue,
                  object["type"]?.stringValue == "text" else {
                return nil
            }
            return nonEmptyString(object["text"])
        }
        guard !parts.isEmpty else {
            return nil
        }
        return parts.joined(separator: "\n")
    }
}
