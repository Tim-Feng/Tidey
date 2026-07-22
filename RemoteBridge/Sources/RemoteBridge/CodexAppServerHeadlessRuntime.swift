import Foundation

enum CodexAppServerTransportMode: Equatable, Sendable {
    case stdio
    case unixSocket(path: String)

    var listenArgument: String? {
        switch self {
        case .stdio:
            return nil
        case .unixSocket(let path):
            return "unix://\(path)"
        }
    }

    var remoteAddress: String? {
        listenArgument
    }
}

enum CodexAppServerProcessOwnership: Equatable, Sendable {
    case owned
    case external
}

struct CodexAppServerLaunchConfiguration: Equatable, Sendable {
    let executablePath: String
    let arguments: [String]
    let workingDirectory: String
    let environment: [String: String]
    let transport: CodexAppServerTransportMode

    init(executablePath: String,
         arguments: [String],
         workingDirectory: String,
         environment: [String: String],
         transport: CodexAppServerTransportMode = .stdio) {
        self.executablePath = executablePath
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.transport = transport
    }

    static func direct(codexExecutablePath: String = "codex",
                       workingDirectory: String,
                       environment: [String: String] = [:]) -> CodexAppServerLaunchConfiguration {
        CodexAppServerLaunchConfiguration(executablePath: codexExecutablePath,
                                          arguments: ["app-server"],
                                          workingDirectory: workingDirectory,
                                          environment: environment,
                                          transport: .stdio)
    }

    static func unixSocket(codexExecutablePath: String = "codex",
                           socketPath: String,
                           workingDirectory: String,
                           environment: [String: String] = [:]) -> CodexAppServerLaunchConfiguration {
        let transport = CodexAppServerTransportMode.unixSocket(path: socketPath)
        return CodexAppServerLaunchConfiguration(executablePath: codexExecutablePath,
                                                 arguments: ["app-server", "--listen", transport.listenArgument ?? "stdio://"],
                                                 workingDirectory: workingDirectory,
                                                 environment: environment,
                                                 transport: transport)
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
    typealias ThreadIDHandler = (String) -> Void
    typealias TurnLifecycleHandler = (_ threadID: String, _ turnID: String) -> Void
    typealias ThreadStatusHandler = (_ threadID: String) -> Void
    typealias ThreadStatusLifecycleHandler = (_ threadID: String, _ statusType: String, _ activeFlags: [String]?) -> Void

    private let context: CodexAppServerRuntimeContext
    private let nextSequence: SequenceProvider
    private let timestampProvider: TimestampProvider
    private let onAgentEvent: AgentEventHandler
    private let onThreadID: ThreadIDHandler
    private let onTurnStarted: TurnLifecycleHandler
    private let onTurnCompleted: TurnLifecycleHandler
    private let onThreadActive: ThreadStatusHandler
    private let onThreadIdle: ThreadStatusHandler
    private let onThreadStatusLifecycle: ThreadStatusLifecycleHandler

    var contextSessionID: String {
        context.sessionID
    }

    init(context: CodexAppServerRuntimeContext,
         nextSequence: @escaping SequenceProvider,
         timestampProvider: @escaping TimestampProvider,
         onAgentEvent: @escaping AgentEventHandler,
         onThreadID: @escaping ThreadIDHandler = { _ in },
         onTurnStarted: @escaping TurnLifecycleHandler = { _, _ in },
         onTurnCompleted: @escaping TurnLifecycleHandler = { _, _ in },
         onThreadActive: @escaping ThreadStatusHandler = { _ in },
         onThreadIdle: @escaping ThreadStatusHandler = { _ in },
         onThreadStatusLifecycle: @escaping ThreadStatusLifecycleHandler = { _, _, _ in }) {
        self.context = context
        self.nextSequence = nextSequence
        self.timestampProvider = timestampProvider
        self.onAgentEvent = onAgentEvent
        self.onThreadID = onThreadID
        self.onTurnStarted = onTurnStarted
        self.onTurnCompleted = onTurnCompleted
        self.onThreadActive = onThreadActive
        self.onThreadIdle = onThreadIdle
        self.onThreadStatusLifecycle = onThreadStatusLifecycle
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
    func listLoadedThreads(on connection: CodexAppServerConnection,
                           onResponse: @escaping CodexAppServerConnection.ClientResponseHandler = { _ in }) throws -> Int {
        try connection.sendClientRequest(method: "thread/loaded/list",
                                         onResponse: onResponse)
    }

    @discardableResult
    func resumeThread(on connection: CodexAppServerConnection,
                      threadID: String,
                      cwd: String?,
                      onResponse: @escaping CodexAppServerConnection.ClientResponseHandler = { _ in }) throws -> Int {
        var params: [String: JSONValue] = [
            "threadId": .string(threadID),
            "excludeTurns": .bool(true),
        ]
        if let cwd {
            params["cwd"] = .string(cwd)
        }
        BridgeLogger.server.debug("codex app-server diagnostic resume request session_id=\(self.context.sessionID, privacy: .public) thread_id=\(threadID, privacy: .public) request_has_approvalsReviewer=\((params["approvalsReviewer"] != nil), privacy: .public) cwd=\(cwd ?? "-", privacy: .public)")
        return try connection.sendClientRequest(method: "thread/resume",
                                                params: params,
                                                onResponse: { response in
                                                    Self.logThreadResumeResponse(response,
                                                                                 sessionID: self.context.sessionID,
                                                                                 threadID: threadID,
                                                                                 requestHasApprovalsReviewer: params["approvalsReviewer"] != nil)
                                                    onResponse(response)
                                                })
    }

    @discardableResult
    func startTurn(on connection: CodexAppServerConnection,
                   threadID: String,
                   text: String,
                   cwd: String? = nil,
                   approvalPolicy: String? = nil,
                   sandboxPolicy: JSONValue? = nil,
                   clientUserMessageID: String? = nil,
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
        if let clientUserMessageID = Self.nonEmptyString(clientUserMessageID) {
            params["clientUserMessageId"] = .string(clientUserMessageID)
        }
        BridgeLogger.server.debug("codex app-server diagnostic turn_start request session_id=\(self.context.sessionID, privacy: .public) thread_id=\(threadID, privacy: .public) request_has_approvalsReviewer=\((params["approvalsReviewer"] != nil), privacy: .public) approvalPolicy=\(approvalPolicy ?? "-", privacy: .public) cwd=\(cwd ?? "-", privacy: .public)")
        return try connection.sendClientRequest(method: "turn/start",
                                                params: params,
                                                onResponse: { response in
                                                    Self.logTurnStartResponse(response,
                                                                              sessionID: self.context.sessionID,
                                                                              threadID: threadID,
                                                                              requestHasApprovalsReviewer: params["approvalsReviewer"] != nil)
                                                    onResponse(response)
                                                })
    }

    @discardableResult
    func steerTurn(on connection: CodexAppServerConnection,
                   threadID: String,
                   expectedTurnID: String,
                   text: String,
                   clientUserMessageID: String? = nil,
                   onResponse: @escaping CodexAppServerConnection.ClientResponseHandler = { _ in }) throws -> Int {
        var params: [String: JSONValue] = [
            "threadId": .string(threadID),
            "expectedTurnId": .string(expectedTurnID),
            "input": .array([
                .object([
                    "type": .string("text"),
                    "text": .string(text),
                    "text_elements": .array([]),
                ]),
            ]),
        ]
        if let clientUserMessageID = Self.nonEmptyString(clientUserMessageID) {
            params["clientUserMessageId"] = .string(clientUserMessageID)
        }
        BridgeLogger.server.debug("codex app-server diagnostic turn_steer request session_id=\(self.context.sessionID, privacy: .public) thread_id=\(threadID, privacy: .public) expected_turn_id=\(expectedTurnID, privacy: .public)")
        return try connection.sendClientRequest(method: "turn/steer",
                                                params: params,
                                                onResponse: { response in
                                                    Self.logTurnSteerResponse(response,
                                                                              sessionID: self.context.sessionID,
                                                                              threadID: threadID,
                                                                              expectedTurnID: expectedTurnID)
                                                    onResponse(response)
                                                })
    }

    func handleNotification(_ notification: CodexAppServerNotification) {
        // Bare threadId notifications also come from subagents. Only a
        // positively identified root thread/started may establish the root
        // binding; loaded-list/resume remain authoritative thereafter.
        if let threadID = Self.rootThreadStartedThreadID(from: notification) {
            onThreadID(threadID)
        }
        if notification.method == "turn/started",
           let threadID = Self.threadID(from: notification.params),
           let turnID = Self.turnID(from: notification.params) {
            onTurnStarted(threadID, turnID)
        }
        if notification.method == "turn/completed",
           let threadID = Self.threadID(from: notification.params),
           let turnID = Self.turnID(from: notification.params) {
            onTurnCompleted(threadID, turnID)
        }
        if notification.method == "thread/status/changed",
           let threadID = Self.threadID(from: notification.params),
           let status = notification.params["status"]?.objectValue?["type"]?.stringValue {
            switch status {
            case "active":
                onThreadActive(threadID)
            case "idle":
                onThreadIdle(threadID)
            default:
                break
            }
            let activeFlags: [String]? = notification.params["status"]?.objectValue?["activeFlags"]?.arrayValue
                .map { $0.compactMap(\.stringValue) }
            onThreadStatusLifecycle(threadID, status, activeFlags)
        }
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
                             type: .toolResult,
                             text: nil,
                             name: "file_change_patch",
                             input: Self.fileChangeSummary(from: notification.params),
                             output: Self.fileChangeOutput(from: notification.params),
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
            var additionalMetadata: [String: String] = [:]
            if let clientRequestID = Self.nonEmptyString(item["clientId"]) {
                additionalMetadata["client_request_id"] = clientRequestID
            }
            return makeEvent(method: notification.method,
                             type: .userMessage,
                             text: Self.userMessageText(from: item),
                             name: nil,
                             input: nil,
                             output: nil,
                             toolCallID: item["id"]?.stringValue,
                             payloadKind: "user_message",
                             params: notification.params,
                             additionalMetadata: additionalMetadata)
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
                             name: "file_change_patch",
                             input: Self.fileChangeSummary(from: notification.params),
                             output: nil,
                             toolCallID: item["id"]?.stringValue,
                             payloadKind: "file_change_patch",
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
                             name: "file_change_patch",
                             input: nil,
                             output: Self.fileChangeOutput(from: notification.params)
                                ?? Self.status(from: notification.params),
                             toolCallID: item["id"]?.stringValue,
                             payloadKind: "file_change_patch",
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
                           params: [String: JSONValue],
                           additionalMetadata: [String: String] = [:]) -> AgentEvent {
        let seq = nextSequence(context.sessionID)
        var metadata = metadata(method: method, params: params)
        for (key, value) in additionalMetadata {
            metadata[key] = value
        }
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
        if let command = Self.command(from: params) {
            metadata["command"] = command
        }
        if let cwd = Self.cwd(from: params) {
            metadata["cwd"] = cwd
        }
        if let status = Self.status(from: params) {
            metadata["status"] = status
        }
        if let exitCode = Self.exitCode(from: params) {
            metadata["exit_code"] = String(exitCode)
        }
        if let durationMs = Self.durationMs(from: params) {
            metadata["duration_ms"] = String(durationMs)
        }
        let files = Self.fileChangeFiles(from: params)
        if !files.isEmpty {
            metadata["files"] = files.joined(separator: ",")
        }
        return metadata
    }

    private static func threadID(from params: [String: JSONValue]) -> String? {
        params["threadId"]?.stringValue
            ?? params["thread"]?.objectValue?["id"]?.stringValue
    }

    static func rootThreadStartedThreadID(from notification: CodexAppServerNotification) -> String? {
        guard notification.method == "thread/started",
              let thread = notification.params["thread"]?.objectValue,
              let threadID = thread["id"]?.stringValue else {
            return nil
        }
        let parentKeys = ["parentThreadId", "parent_thread_id", "parentId", "parent_id"]
        for key in parentKeys {
            guard let value = thread[key] ?? notification.params[key] else {
                continue
            }
            if case .null = value {
                continue
            }
            return nil
        }
        let agentKeys = ["agentRole", "agent_role", "agentNickname", "agent_nickname"]
        for key in agentKeys where thread[key]?.stringValue?.isEmpty == false {
            return nil
        }
        if thread["role"]?.stringValue == "subagent" {
            return nil
        }
        return threadID
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

    private static func command(from params: [String: JSONValue]) -> String? {
        params["command"]?.stringValue
            ?? params["item"]?.objectValue?["command"]?.stringValue
    }

    private static func cwd(from params: [String: JSONValue]) -> String? {
        params["cwd"]?.stringValue
            ?? params["item"]?.objectValue?["cwd"]?.stringValue
    }

    private static func status(from params: [String: JSONValue]) -> String? {
        params["status"]?.stringValue
            ?? params["item"]?.objectValue?["status"]?.stringValue
    }

    private static func exitCode(from params: [String: JSONValue]) -> Int? {
        params["exitCode"]?.intValue
            ?? params["item"]?.objectValue?["exitCode"]?.intValue
    }

    private static func durationMs(from params: [String: JSONValue]) -> Int? {
        params["durationMs"]?.intValue
            ?? params["item"]?.objectValue?["durationMs"]?.intValue
    }

    private static func fileChangeOutput(from params: [String: JSONValue]) -> String? {
        if let diff = fileChangeDiff(from: params) {
            return diff
        }
        return fileChangeSummary(from: params)
    }

    private static func fileChangeSummary(from params: [String: JSONValue]) -> String? {
        let summaries = fileChangeObjects(from: params).compactMap { change -> String? in
            let path = firstNonEmptyString(in: change, keys: ["path", "file_path", "target_file", "filename"])
            let kind = firstNonEmptyString(in: change, keys: ["kind", "type", "status"])
            switch (path, kind) {
            case let (.some(path), .some(kind)):
                return "\(path) \(kind)"
            case let (.some(path), nil):
                return path
            case let (nil, .some(kind)):
                return kind
            default:
                return nil
            }
        }
        guard !summaries.isEmpty else {
            return nil
        }
        return summaries.joined(separator: "\n")
    }

    private static func fileChangeDiff(from params: [String: JSONValue]) -> String? {
        for change in fileChangeObjects(from: params) {
            if let diff = firstNonEmptyString(in: change, keys: ["diff", "patch", "unified_diff", "output"]) {
                return diff
            }
        }
        return nil
    }

    private static func fileChangeFiles(from params: [String: JSONValue]) -> [String] {
        var seen = Set<String>()
        return fileChangeObjects(from: params).compactMap { change -> String? in
            guard let path = firstNonEmptyString(in: change, keys: ["path", "file_path", "target_file", "filename"]),
                  seen.insert(path).inserted else {
                return nil
            }
            return path
        }
    }

    private static func fileChangeObjects(from params: [String: JSONValue]) -> [[String: JSONValue]] {
        let changes = params["changes"]?.arrayValue
            ?? params["item"]?.objectValue?["changes"]?.arrayValue
            ?? []
        return changes.compactMap(\.objectValue)
    }

    private static func firstNonEmptyString(in object: [String: JSONValue],
                                            keys: [String]) -> String? {
        for key in keys {
            if let value = nonEmptyString(object[key]) {
                return value
            }
        }
        return nil
    }

    private static func nonEmptyString(_ value: JSONValue?) -> String? {
        guard case .string(let text) = value else {
            return nil
        }
        return nonEmptyString(text)
    }

    private static func nonEmptyString(_ text: String?) -> String? {
        guard let text else {
            return nil
        }
        // Client ids are opaque. Trim only to reject an all-whitespace value;
        // preserve every byte of a usable id on both request and event paths.
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

    static func logThreadResumeResponse(_ response: Result<JSONValue, CodexAppServerConnectionError>,
                                        sessionID: String,
                                        threadID: String,
                                        requestHasApprovalsReviewer: Bool) {
        switch response {
        case .success(let value):
            let object = value.objectValue
            BridgeLogger.server.debug("codex app-server diagnostic resume response status=success session_id=\(sessionID, privacy: .public) thread_id=\(threadID, privacy: .public) request_has_approvalsReviewer=\(requestHasApprovalsReviewer, privacy: .public) approvalsReviewer=\(diagnosticField(object, keys: ["approvalsReviewer", "approvals_reviewer"]), privacy: .public) approvalPolicy=\(diagnosticField(object, keys: ["approvalPolicy", "approval_policy"]), privacy: .public) subscribed=\(diagnosticField(object, keys: ["subscribed", "isSubscribed", "listener", "listenerAttached", "connectionId", "connection_id", "subscribedConnectionIds", "subscribed_connection_ids"]), privacy: .public) response_keys=\(diagnosticKeys(object), privacy: .public)")
        case .failure(let error):
            BridgeLogger.server.error("codex app-server diagnostic resume response status=failure session_id=\(sessionID, privacy: .public) thread_id=\(threadID, privacy: .public) request_has_approvalsReviewer=\(requestHasApprovalsReviewer, privacy: .public) error=\(String(describing: error), privacy: .public)")
        }
    }

    static func logTurnStartResponse(_ response: Result<JSONValue, CodexAppServerConnectionError>,
                                     sessionID: String,
                                     threadID: String,
                                     requestHasApprovalsReviewer: Bool) {
        switch response {
        case .success(let value):
            let object = value.objectValue
            BridgeLogger.server.debug("codex app-server diagnostic turn_start response status=success session_id=\(sessionID, privacy: .public) thread_id=\(threadID, privacy: .public) request_has_approvalsReviewer=\(requestHasApprovalsReviewer, privacy: .public) approvalsReviewer=\(diagnosticField(object, keys: ["approvalsReviewer", "approvals_reviewer"]), privacy: .public) approvalPolicy=\(diagnosticField(object, keys: ["approvalPolicy", "approval_policy"]), privacy: .public) response_keys=\(diagnosticKeys(object), privacy: .public)")
        case .failure(let error):
            BridgeLogger.server.error("codex app-server diagnostic turn_start response status=failure session_id=\(sessionID, privacy: .public) thread_id=\(threadID, privacy: .public) request_has_approvalsReviewer=\(requestHasApprovalsReviewer, privacy: .public) error=\(String(describing: error), privacy: .public)")
        }
    }

    static func logTurnSteerResponse(_ response: Result<JSONValue, CodexAppServerConnectionError>,
                                     sessionID: String,
                                     threadID: String,
                                     expectedTurnID: String) {
        switch response {
        case .success(let value):
            let object = value.objectValue
            BridgeLogger.server.debug("codex app-server diagnostic turn_steer response status=success session_id=\(sessionID, privacy: .public) thread_id=\(threadID, privacy: .public) expected_turn_id=\(expectedTurnID, privacy: .public) response_keys=\(diagnosticKeys(object), privacy: .public)")
        case .failure(let error):
            BridgeLogger.server.error("codex app-server diagnostic turn_steer response status=failure session_id=\(sessionID, privacy: .public) thread_id=\(threadID, privacy: .public) expected_turn_id=\(expectedTurnID, privacy: .public) error=\(String(describing: error), privacy: .public)")
        }
    }

    private static func diagnosticField(_ object: [String: JSONValue]?, keys: [String]) -> String {
        guard let object else {
            return "-"
        }
        for key in keys {
            if let value = object[key] {
                return diagnosticDescription(value)
            }
        }
        return "-"
    }

    private static func diagnosticKeys(_ object: [String: JSONValue]?) -> String {
        guard let object else {
            return "-"
        }
        return object.keys.sorted().joined(separator: ",")
    }

    private static func diagnosticDescription(_ value: JSONValue) -> String {
        switch value {
        case .string(let string):
            return string
        case .number(let number):
            if number.isFinite,
               number.rounded(.towardZero) == number,
               let intValue = Int(exactly: number) {
                return String(intValue)
            }
            return String(number)
        case .bool(let bool):
            return String(bool)
        case .null:
            return "null"
        case .array(let array):
            return "array[count=\(array.count)]"
        case .object(let object):
            return "object[keys=\(object.keys.sorted().joined(separator: ","))]"
        }
    }
}
