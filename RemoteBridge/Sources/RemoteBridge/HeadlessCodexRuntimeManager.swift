import Foundation

protocol HeadlessCodexRuntimeControlling: AnyObject {
    func mergeWorkspaceListResult(_ result: [String: JSONValue]) -> [String: JSONValue]
    func panelListResult(workspaceID: String) -> [String: JSONValue]?
    func handleCreatePanel(_ request: BridgeRequest, socketSender: TideyRequestSending) throws -> BridgeResponse?
    func handleChatSubmit(_ request: BridgeRequest) throws -> BridgeResponse?
    func handleSubmitInteractivePrompt(_ request: BridgeRequest) throws -> BridgeResponse?
}

struct HeadlessCodexRuntimeConfiguration: Sendable {
    let workspaceID: String
    let panelID: String
    let sessionID: String
    let title: String
    let subtitle: String
    let cwd: String
    let model: String?
    let approvalPolicy: String?
    let sandbox: JSONValue?
    let launchConfiguration: CodexAppServerLaunchConfiguration
    let remoteTUILaunchConfiguration: CodexRemoteTUILaunchConfiguration?

    init(workspaceID: String,
         panelID: String,
         sessionID: String,
         title: String,
         subtitle: String,
         cwd: String,
         model: String?,
         approvalPolicy: String?,
         sandbox: JSONValue?,
         launchConfiguration: CodexAppServerLaunchConfiguration,
         remoteTUILaunchConfiguration: CodexRemoteTUILaunchConfiguration? = nil) {
        self.workspaceID = workspaceID
        self.panelID = panelID
        self.sessionID = sessionID
        self.title = title
        self.subtitle = subtitle
        self.cwd = cwd
        self.model = model
        self.approvalPolicy = approvalPolicy
        self.sandbox = sandbox
        self.launchConfiguration = launchConfiguration
        self.remoteTUILaunchConfiguration = remoteTUILaunchConfiguration
    }

    static func devFromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> HeadlessCodexRuntimeConfiguration? {
        guard environment["TIDEY_HEADLESS_CODEX_DEV"]?.lowercased() == "1" else {
            return nil
        }
        guard let executablePath = environment["TIDEY_HEADLESS_CODEX_EXECUTABLE"],
              executablePath.hasPrefix("/") else {
            BridgeLogger.server.error("headless codex dev disabled reason=missing_absolute_TIDEY_HEADLESS_CODEX_EXECUTABLE")
            return nil
        }
        let cwd = environment["TIDEY_HEADLESS_CODEX_CWD"] ?? "/tmp/tidey-headless-codex-work"
        let codexHome = environment["TIDEY_HEADLESS_CODEX_HOME"] ?? "/tmp/tidey-headless-codex-home"
        let workspaceID = environment["TIDEY_HEADLESS_CODEX_WORKSPACE_ID"] ?? "headless-codex-dev"
        let panelID = environment["TIDEY_HEADLESS_CODEX_PANEL_ID"] ?? "headless-codex-dev-panel"
        let sessionID = environment["TIDEY_HEADLESS_CODEX_SESSION_ID"] ?? "headless-codex-dev-session"
        let appServerSocketPath = environment["TIDEY_HEADLESS_CODEX_APP_SERVER_SOCKET"]
        if let appServerSocketPath,
           appServerSocketPath.hasPrefix("/") == false {
            BridgeLogger.server.error("headless codex dev disabled reason=non_absolute_TIDEY_HEADLESS_CODEX_APP_SERVER_SOCKET")
            return nil
        }
        let launchConfiguration: CodexAppServerLaunchConfiguration
        let remoteTUIConfiguration: CodexRemoteTUILaunchConfiguration?
        if let appServerSocketPath,
           appServerSocketPath.isEmpty == false {
            launchConfiguration = .unixSocket(codexExecutablePath: executablePath,
                                              socketPath: appServerSocketPath,
                                              workingDirectory: cwd,
                                              environment: ["CODEX_HOME": codexHome])
            remoteTUIConfiguration = .unixSocket(codexExecutablePath: executablePath,
                                                 socketPath: appServerSocketPath,
                                                 workingDirectory: cwd,
                                                 environment: ["CODEX_HOME": codexHome])
        } else {
            launchConfiguration = CodexAppServerLaunchConfiguration(
                executablePath: executablePath,
                arguments: ["app-server"],
                workingDirectory: cwd,
                environment: ["CODEX_HOME": codexHome])
            remoteTUIConfiguration = nil
        }
        return HeadlessCodexRuntimeConfiguration(
            workspaceID: workspaceID,
            panelID: panelID,
            sessionID: sessionID,
            title: environment["TIDEY_HEADLESS_CODEX_TITLE"] ?? "Headless Codex Dev",
            subtitle: remoteTUIConfiguration == nil ? "Codex app-server" : "Codex app-server sidecar",
            cwd: cwd,
            model: environment["TIDEY_HEADLESS_CODEX_MODEL"],
            approvalPolicy: environment["TIDEY_HEADLESS_CODEX_APPROVAL_POLICY"] ?? "on-request",
            sandbox: .string(environment["TIDEY_HEADLESS_CODEX_SANDBOX"] ?? "workspace-write"),
            launchConfiguration: launchConfiguration,
            remoteTUILaunchConfiguration: remoteTUIConfiguration
        )
    }
}

final class HeadlessCodexRuntimeManager: HeadlessCodexRuntimeControlling {
    private let configuration: HeadlessCodexRuntimeConfiguration
    private let sessionFactory: CodexAppServerRuntimeSessionFactory
    private let eventHub: AgentEventHub
    private let timestampProvider: CodexAppServerConnection.TimestampProvider
    private let lock = NSLock()
    private var session: CodexAppServerRuntimeSession?
    private var threadID: String?
    private var isStartingThread = false
    private var queuedTurns: [QueuedTurn] = []
    private var didPublishSessionStarted = false

    init(configuration: HeadlessCodexRuntimeConfiguration,
         sessionFactory: CodexAppServerRuntimeSessionFactory = CodexAppServerRuntimeSessionFactory(),
         eventHub: AgentEventHub,
         timestampProvider: @escaping CodexAppServerConnection.TimestampProvider = HeadlessCodexRuntimeManager.iso8601Now) {
        self.configuration = configuration
        self.sessionFactory = sessionFactory
        self.eventHub = eventHub
        self.timestampProvider = timestampProvider
    }

    func mergeWorkspaceListResult(_ result: [String: JSONValue]) -> [String: JSONValue] {
        var merged = result
        var workspaces = merged["workspaces"]?.arrayValue ?? []
        workspaces.removeAll { $0.objectValue?["workspace_id"]?.stringValue == configuration.workspaceID }
        let hasMacWorkspaceWithSameTitle = workspaces.contains { value in
            guard let workspace = value.objectValue else {
                return false
            }
            return workspace["title"]?.stringValue == configuration.title
        }
        if hasMacWorkspaceWithSameTitle == false {
            workspaces.append(.object(workspaceValue()))
        }
        merged["workspaces"] = .array(workspaces)
        return merged
    }

    func panelListResult(workspaceID: String) -> [String: JSONValue]? {
        guard workspaceID == configuration.workspaceID else {
            return nil
        }
        return [
            "workspace_id": .string(configuration.workspaceID),
            "selected_panel_id": .string(configuration.panelID),
            "panels": .array([.object(panelValue())]),
        ]
    }

    func handleCreatePanel(_ request: BridgeRequest, socketSender: TideyRequestSending) throws -> BridgeResponse? {
        guard request.action == "create_panel",
              request.params?["workspace_id"]?.stringValue == configuration.workspaceID else {
            return nil
        }
        guard let remoteTUILaunchConfiguration = configuration.remoteTUILaunchConfiguration else {
            throw BridgeInternalError.conflict("Headless Codex has no remote TUI app-server endpoint.")
        }

        let createWorkspaceResponse = try socketSender.send(BridgeRequest(
            id: "\(request.id).workspace",
            action: "create_workspace",
            params: [
                "title": .string(configuration.title),
                "make_selected": .bool(true),
            ]))
        guard createWorkspaceResponse.ok else {
            throw BridgeInternalError.invalidResponse
        }
        let macWorkspace = Self.workspaceObject(from: createWorkspaceResponse.result)
        guard let macWorkspaceID = macWorkspace?["workspace_id"]?.stringValue,
              macWorkspaceID.isEmpty == false else {
            throw BridgeInternalError.invalidResponse
        }

        let createPanelResponse = try socketSender.send(BridgeRequest(
            id: request.id,
            action: "create_panel",
            params: [
                "workspace_id": .string(macWorkspaceID),
                "make_selected": .bool(true),
            ]))
        guard createPanelResponse.ok else {
            return createPanelResponse
        }
        let macPanel = Self.panelObject(from: createPanelResponse.result)
        guard let macPanelID = macPanel?["panel_id"]?.stringValue,
              macPanelID.isEmpty == false else {
            throw BridgeInternalError.invalidResponse
        }

        let launchInput = remoteTUILaunchConfiguration.shellCommand() + "\r"
        let sendInputResponse = try socketSender.send(BridgeRequest(
            id: "\(request.id).launch",
            action: "send_input",
            params: [
                "workspace_id": .string(macWorkspaceID),
                "panel_id": .string(macPanelID),
                "input": .string(launchInput),
            ]))
        guard sendInputResponse.ok else {
            return sendInputResponse
        }

        var result = createPanelResponse.result ?? [:]
        if let macWorkspace {
            result["workspace"] = .object(macWorkspace)
        }
        result["created_workspace"] = .bool(true)
        result["headless_remote_tui"] = .bool(true)
        result["headless_remote_tui_input_sent"] = .bool(true)
        return BridgeResponse(id: request.id,
                              ok: true,
                              result: result,
                              error: nil)
    }

    func handleChatSubmit(_ request: BridgeRequest) throws -> BridgeResponse? {
        guard let params = request.params,
              params["workspace_id"]?.stringValue == configuration.workspaceID,
              params["panel_id"]?.stringValue == configuration.panelID else {
            return nil
        }
        guard let message = params["message"]?.stringValue,
              !message.isEmpty else {
            throw BridgeInternalError.invalidRequest("chat_submit requires workspace_id, panel_id, and message")
        }
        if let requestedSessionID = params["session_id"]?.stringValue,
           requestedSessionID != configuration.sessionID {
            throw BridgeInternalError.invalidRequest("chat_submit session_id does not match the active panel session")
        }
        if let requestedVendor = params["vendor"]?.stringValue,
           requestedVendor != "codex" {
            throw BridgeInternalError.invalidRequest("chat_submit vendor does not match the active panel session")
        }

        let clientRequestID = params["client_request_id"]?.stringValue
        let turn = QueuedTurn(text: message, clientRequestID: clientRequestID)
        let runtimeSession = try ensureSession()
        let thread = currentThreadID()
        if let thread {
            try startTurn(turn, threadID: thread, session: runtimeSession)
        } else {
            enqueue(turn)
            try startThreadIfNeeded(session: runtimeSession)
        }
        return BridgeResponse(id: request.id,
                              ok: true,
                              result: [
                                "submitted": .bool(true),
                                "vendor": .string("codex"),
                                "session_id": .string(configuration.sessionID),
                                "deduplicated": .bool(false),
                                "headless": .bool(true),
                              ],
                              error: nil)
    }

    func handleSubmitInteractivePrompt(_ request: BridgeRequest) throws -> BridgeResponse? {
        guard let params = request.params,
              params["workspace_id"]?.stringValue == configuration.workspaceID,
              params["panel_id"]?.stringValue == configuration.panelID else {
            return nil
        }
        guard let promptID = params["prompt_id"]?.stringValue else {
            throw BridgeInternalError.invalidRequest("submit_interactive_prompt requires prompt_id")
        }
        guard let targetIndex = params["target_index"]?.intValue else {
            throw BridgeInternalError.invalidRequest("submit_interactive_prompt requires target_index")
        }
        guard let runtimeSession = currentSession() else {
            throw BridgeInternalError.conflict("Codex app-server session is not active")
        }
        let event = try runtimeSession.submitApproval(promptID: promptID, targetIndex: targetIndex)
        return BridgeResponse(id: request.id,
                              ok: true,
                              result: [
                                "status": .string("resolved"),
                                "prompt": .null,
                                "resolved_event": Self.jsonValue(for: event),
                                "headless": .bool(true),
                              ],
                              error: nil)
    }

    private func workspaceValue() -> [String: JSONValue] {
        [
            "workspace_id": .string(configuration.workspaceID),
            "title": .string(configuration.title),
            "subtitle": .string(configuration.subtitle),
            "state": .string("active"),
            "selected": .bool(false),
            "panel_count": .number(1),
            "selected_panel_id": .string(configuration.panelID),
            "has_agent_session": .bool(true),
            "agent_panel_id": .string(configuration.panelID),
            "cwd": .string(configuration.cwd),
            "headless_codex": .bool(true),
        ]
    }

    private static func workspaceObject(from result: [String: JSONValue]?) -> [String: JSONValue]? {
        if let workspace = result?["workspace"]?.objectValue {
            return workspace
        }
        if let workspaceID = result?["workspace_id"]?.stringValue {
            return ["workspace_id": .string(workspaceID)]
        }
        return nil
    }

    private static func panelObject(from result: [String: JSONValue]?) -> [String: JSONValue]? {
        if let panel = result?["panel"]?.objectValue {
            return panel
        }
        if let panelID = result?["panel_id"]?.stringValue {
            return ["panel_id": .string(panelID)]
        }
        return nil
    }

    private func panelValue() -> [String: JSONValue] {
        var value: [String: JSONValue] = [
            "workspace_id": .string(configuration.workspaceID),
            "panel_id": .string(configuration.panelID),
            "window_guid": .string("headless-codex-dev-window"),
            "title": .string("Codex app-server"),
            "subtitle": .string(configuration.cwd),
            "state": .string("active"),
            "selected": .bool(true),
            "is_browser": .bool(false),
            "cwd": .string(configuration.cwd),
            "panel_index": .number(0),
            "workspace_index": .number(9999),
            "headless_codex": .bool(true),
            "agent_session": .object([
                "vendor": .string("codex"),
                "session_id": .string(configuration.sessionID),
            ]),
        ]
        if let remoteTUILaunchConfiguration = configuration.remoteTUILaunchConfiguration {
            value["codex_app_server_remote"] = .string(remoteTUILaunchConfiguration.remoteAddress)
            value["codex_remote_tui"] = .object(remoteTUILaunchConfiguration.jsonValue())
            value["codex_remote_tui_command"] = .string(remoteTUILaunchConfiguration.shellCommand())
        }
        return value
    }

    private func ensureSession() throws -> CodexAppServerRuntimeSession {
        lock.lock()
        if let session {
            lock.unlock()
            return session
        }
        lock.unlock()

        let created = try sessionFactory.start(configuration: configuration.launchConfiguration,
                                               context: CodexAppServerRuntimeContext(workspaceID: configuration.workspaceID,
                                                                                    panelID: configuration.panelID,
                                                                                    sessionID: configuration.sessionID),
                                               nextSequence: { [eventHub] sessionID in
                                                   eventHub.nextSyntheticSeq(sessionID: sessionID)
                                               },
                                               timestampProvider: timestampProvider,
                                               onAgentEvent: { [eventHub] event in
                                                   eventHub.publish(event)
                                               },
                                               onInteractivePrompt: { [eventHub] envelope in
                                                   eventHub.publish(envelope.event)
                                               },
                                               onInteractivePromptResolved: { [eventHub] event in
                                                   eventHub.publish(event)
                                               },
                                               onStderrLine: { line in
                                                   BridgeLogger.server.info("headless codex stderr line=\(line, privacy: .public)")
                                               },
                                               onExit: { [weak self] exitCode in
                                                   self?.handleExit(exitCode)
                                               })
        lock.lock()
        if let existing = session {
            lock.unlock()
            created.stop()
            return existing
        }
        session = created
        lock.unlock()
        publishSyntheticSessionStartedIfNeeded()
        return created
    }

    private func currentSession() -> CodexAppServerRuntimeSession? {
        lock.lock()
        defer { lock.unlock() }
        return session
    }

    private func currentThreadID() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return threadID
    }

    private func enqueue(_ turn: QueuedTurn) {
        lock.lock()
        queuedTurns.append(turn)
        lock.unlock()
    }

    private func startThreadIfNeeded(session: CodexAppServerRuntimeSession) throws {
        lock.lock()
        guard isStartingThread == false else {
            lock.unlock()
            return
        }
        isStartingThread = true
        lock.unlock()

        try session.startThread(cwd: configuration.cwd,
                                model: configuration.model,
                                approvalPolicy: configuration.approvalPolicy,
                                sandbox: configuration.sandbox) { [weak self, weak session] result in
            self?.handleStartThreadResponse(result, session: session)
        }
        publishHeadlessStartingStatus()
    }

    private func handleStartThreadResponse(_ result: Result<JSONValue, CodexAppServerConnectionError>,
                                           session: CodexAppServerRuntimeSession?) {
        switch result {
        case .success(let value):
            guard let threadID = Self.threadID(from: value),
                  let session else {
                lock.lock()
                isStartingThread = false
                let turns = queuedTurns
                queuedTurns.removeAll()
                lock.unlock()
                publishBridgeError("Codex app-server did not return a thread id.")
                for turn in turns {
                    publishAssistantMessage("Failed to submit queued Codex message: \(turn.text)")
                }
                return
            }
            lock.lock()
            self.threadID = threadID
            isStartingThread = false
            let turns = queuedTurns
            queuedTurns.removeAll()
            lock.unlock()
            for turn in turns {
                do {
                    try startTurn(turn, threadID: threadID, session: session)
                } catch {
                    publishBridgeError("Codex app-server failed to start turn: \(error.localizedDescription)")
                }
            }
        case .failure(let error):
            lock.lock()
            isStartingThread = false
            let turns = queuedTurns
            queuedTurns.removeAll()
            lock.unlock()
            publishBridgeError("Codex app-server failed to start thread: \(error.localizedDescription)")
            for turn in turns {
                publishAssistantMessage("Failed to submit queued Codex message: \(turn.text)")
            }
        }
    }

    private func startTurn(_ turn: QueuedTurn,
                           threadID: String,
                           session: CodexAppServerRuntimeSession) throws {
        try session.startTurn(threadID: threadID,
                              text: turn.text,
                              cwd: configuration.cwd,
                              approvalPolicy: configuration.approvalPolicy)
    }

    private func publishSyntheticSessionStartedIfNeeded() {
        lock.lock()
        guard didPublishSessionStarted == false else {
            lock.unlock()
            return
        }
        didPublishSessionStarted = true
        lock.unlock()

        let seq = eventHub.nextSyntheticSeq(sessionID: configuration.sessionID)
        let event = AgentEvent(eventID: "headless-codex-session-started:\(configuration.sessionID)",
                               seq: seq,
                               vendor: "codex",
                               workspaceID: configuration.workspaceID,
                               sessionID: configuration.sessionID,
                               timestamp: timestampProvider(),
                               type: .sessionStarted,
                               role: nil,
                               text: configuration.title,
                               name: nil,
                               input: nil,
                               output: nil,
                               toolCallID: nil,
                               metadata: [
                                "panel_id": configuration.panelID,
                                "source": "codex_app_server",
                                "headless": "true",
                               ],
                               payload: .object([
                                "kind": .string("headless_session_started"),
                                "source": .string("codex_app_server"),
                               ]))
        eventHub.publish(event)
    }

    private func publishBridgeError(_ message: String) {
        publishAssistantMessage(message, payloadKind: "bridge_error")
    }

    private func publishHeadlessStartingStatus() {
        let seq = eventHub.nextSyntheticSeq(sessionID: configuration.sessionID)
        let event = AgentEvent(eventID: "headless-codex-starting:\(configuration.sessionID):\(seq)",
                               seq: seq,
                               vendor: "codex",
                               workspaceID: configuration.workspaceID,
                               sessionID: configuration.sessionID,
                               timestamp: timestampProvider(),
                               type: .status,
                               role: nil,
                               text: "Starting Codex app-server",
                               name: nil,
                               input: nil,
                               output: nil,
                               toolCallID: nil,
                               metadata: [
                                "panel_id": configuration.panelID,
                                "source": "codex_app_server",
                                "headless": "true",
                               ],
                               payload: .object([
                                "kind": .string("headless_starting"),
                                "source": .string("codex_app_server"),
                               ]))
        eventHub.publish(event)
    }

    private func publishAssistantMessage(_ message: String, payloadKind: String = "assistant_message") {
        let seq = eventHub.nextSyntheticSeq(sessionID: configuration.sessionID)
        let event = AgentEvent(eventID: "headless-codex-message:\(configuration.sessionID):\(seq)",
                               seq: seq,
                               vendor: "codex",
                               workspaceID: configuration.workspaceID,
                               sessionID: configuration.sessionID,
                               timestamp: timestampProvider(),
                               type: .assistantMessage,
                               role: "assistant",
                               text: message,
                               name: nil,
                               input: nil,
                               output: nil,
                               toolCallID: nil,
                               metadata: [
                                "panel_id": configuration.panelID,
                                "source": "codex_app_server",
                               ],
                               payload: .object([
                                "kind": .string(payloadKind),
                                "source": .string("codex_app_server"),
                               ]))
        eventHub.publish(event)
    }

    private func handleExit(_ exitCode: Int32) {
        lock.lock()
        session = nil
        threadID = nil
        isStartingThread = false
        queuedTurns.removeAll()
        lock.unlock()
        publishBridgeError("Codex app-server exited with status \(exitCode).")
    }

    private static func threadID(from value: JSONValue) -> String? {
        guard let object = value.objectValue else {
            return nil
        }
        return object["threadId"]?.stringValue
            ?? object["thread_id"]?.stringValue
            ?? object["thread"]?.objectValue?["id"]?.stringValue
            ?? object["id"]?.stringValue
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
        if let metadata = event.metadata {
            object["metadata"] = .object(metadata.mapValues(JSONValue.string))
        }
        if let payload = event.payload {
            object["payload"] = payload
        }
        return .object(object)
    }

    private static func iso8601Now() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }

    private struct QueuedTurn {
        let text: String
        let clientRequestID: String?
    }
}
