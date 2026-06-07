import Foundation

protocol AgentSessionRuntimeSyncing: AnyObject {
    func sync(records: [AgentSessionRegistryRecord])
}

final class CodexAppServerPanelRuntimeManager: HeadlessCodexRuntimeControlling, AgentSessionRuntimeSyncing {
    private final class RuntimeState {
        var record: AgentSessionRegistryRecord
        var session: CodexAppServerRuntimeSession?
        var threadID: String?
        var isStartingThread = false
        var queuedTurns: [QueuedTurn] = []
        var didPublishSessionStarted = false

        init(record: AgentSessionRegistryRecord) {
            self.record = record
        }
    }

    private struct QueuedTurn {
        let text: String
        let clientRequestID: String?
    }

    private let sessionFactory: CodexAppServerRuntimeSessionFactory
    private let eventHub: AgentEventHub
    private let timestampProvider: CodexAppServerConnection.TimestampProvider
    private let lock = NSLock()
    private var states = [String: RuntimeState]()

    init(sessionFactory: CodexAppServerRuntimeSessionFactory = CodexAppServerRuntimeSessionFactory(),
         eventHub: AgentEventHub,
         timestampProvider: @escaping CodexAppServerConnection.TimestampProvider = CodexAppServerPanelRuntimeManager.iso8601Now) {
        self.sessionFactory = sessionFactory
        self.eventHub = eventHub
        self.timestampProvider = timestampProvider
    }

    func sync(records: [AgentSessionRegistryRecord]) {
        let appServerRecords = records.filter(Self.isCodexAppServerRecord)
        let activeSessionIDs = Set(appServerRecords.map(\.sessionID))

        lock.lock()
        for sessionID in states.keys where !activeSessionIDs.contains(sessionID) {
            let state = states.removeValue(forKey: sessionID)
            state?.session?.stop()
        }
        for record in appServerRecords {
            if let state = states[record.sessionID] {
                state.record = record
            } else {
                states[record.sessionID] = RuntimeState(record: record)
            }
        }
        let statesToAttach = appServerRecords.compactMap { record -> RuntimeState? in
            guard let state = states[record.sessionID],
                  state.session == nil else {
                return nil
            }
            return state
        }
        lock.unlock()

        for state in statesToAttach {
            do {
                _ = try ensureSession(for: state.record.sessionID)
            } catch {
                BridgeLogger.server.error("codex app-server panel attach failed session_id=\(state.record.sessionID, privacy: .public) panel_id=\(state.record.panelID ?? "-", privacy: .public) error=\(String(describing: error), privacy: .public)")
            }
        }
    }

    func mergeWorkspaceListResult(_ result: [String: JSONValue]) -> [String: JSONValue] {
        result
    }

    func panelListResult(workspaceID: String) -> [String: JSONValue]? {
        nil
    }

    func handleCreatePanel(_ request: BridgeRequest, socketSender: TideyRequestSending) throws -> BridgeResponse? {
        nil
    }

    func handleChatSubmit(_ request: BridgeRequest) throws -> BridgeResponse? {
        guard let params = request.params,
              let workspaceID = params["workspace_id"]?.stringValue,
              let panelID = params["panel_id"]?.stringValue,
              let message = params["message"]?.stringValue,
              !message.isEmpty,
              let state = stateFor(workspaceID: workspaceID, panelID: panelID) else {
            return nil
        }

        BridgeLogger.input.info("route action=chat_submit request_id=\(request.id, privacy: .public) workspace_id=\(workspaceID, privacy: .public) panel_id=\(panelID, privacy: .public) session_id=\(state.record.sessionID, privacy: .public) transport=codex_app_server length=\(message.count)")

        if let requestedSessionID = params["session_id"]?.stringValue,
           requestedSessionID != state.record.sessionID {
            throw BridgeInternalError.invalidRequest("chat_submit session_id does not match the active panel session")
        }
        if let requestedVendor = params["vendor"]?.stringValue,
           requestedVendor != "codex" {
            throw BridgeInternalError.invalidRequest("chat_submit vendor does not match the active panel session")
        }

        let runtimeSession = try ensureSession(for: state.record.sessionID)
        let turn = QueuedTurn(text: message, clientRequestID: params["client_request_id"]?.stringValue)
        let thread = threadID(for: state.record.sessionID)
        if let thread {
            try startTurn(turn, threadID: thread, session: runtimeSession)
        } else {
            enqueue(turn, sessionID: state.record.sessionID)
            try startThreadIfNeeded(sessionID: state.record.sessionID, session: runtimeSession)
        }

        return BridgeResponse(id: request.id,
                              ok: true,
                              result: [
                                "submitted": .bool(true),
                                "vendor": .string("codex"),
                                "session_id": .string(state.record.sessionID),
                                "deduplicated": .bool(false),
                                "runtime": .string("codex_app_server"),
                              ],
                              error: nil)
    }

    func handleSubmitInteractivePrompt(_ request: BridgeRequest) throws -> BridgeResponse? {
        guard let params = request.params,
              let workspaceID = params["workspace_id"]?.stringValue,
              let panelID = params["panel_id"]?.stringValue,
              let state = stateFor(workspaceID: workspaceID, panelID: panelID) else {
            return nil
        }
        guard let promptID = params["prompt_id"]?.stringValue else {
            throw BridgeInternalError.invalidRequest("submit_interactive_prompt requires prompt_id")
        }
        guard let targetIndex = params["target_index"]?.intValue else {
            throw BridgeInternalError.invalidRequest("submit_interactive_prompt requires target_index")
        }
        let runtimeSession = try ensureSession(for: state.record.sessionID)
        let event = try runtimeSession.submitApproval(promptID: promptID, targetIndex: targetIndex)
        return BridgeResponse(id: request.id,
                              ok: true,
                              result: [
                                "status": .string("resolved"),
                                "prompt": .null,
                                "resolved_event": Self.jsonValue(for: event),
                                "runtime": .string("codex_app_server"),
                              ],
                              error: nil)
    }

    private func stateFor(workspaceID: String, panelID: String) -> RuntimeState? {
        lock.lock()
        defer { lock.unlock() }
        return states.values.first { state in
            state.record.workspaceID == workspaceID && state.record.panelID == panelID
        }
    }

    private func ensureSession(for sessionID: String) throws -> CodexAppServerRuntimeSession {
        lock.lock()
        guard let state = states[sessionID] else {
            lock.unlock()
            throw BridgeInternalError.notFound("Codex app-server panel is not registered")
        }
        if let session = state.session {
            lock.unlock()
            return session
        }
        guard let socketPath = state.record.appServerSocket,
              socketPath.isEmpty == false else {
            lock.unlock()
            throw BridgeInternalError.conflict("Codex app-server panel has no socket")
        }
        let record = state.record
        lock.unlock()

        let created = try sessionFactory.attach(socketPath: socketPath,
                                                processID: record.appServerPID,
                                                context: CodexAppServerRuntimeContext(workspaceID: record.workspaceID,
                                                                                     panelID: record.panelID ?? "",
                                                                                     sessionID: record.sessionID),
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
                                                })

        BridgeLogger.server.info("codex app-server panel attached workspace_id=\(record.workspaceID, privacy: .public) panel_id=\(record.panelID ?? "-", privacy: .public) session_id=\(record.sessionID, privacy: .public) socket=\(socketPath, privacy: .public) app_server_pid=\(record.appServerPID.map(String.init) ?? "-", privacy: .public)")

        lock.lock()
        guard let current = states[sessionID] else {
            lock.unlock()
            created.stop()
            throw BridgeInternalError.notFound("Codex app-server panel is not registered")
        }
        if let existing = current.session {
            lock.unlock()
            created.stop()
            return existing
        }
        current.session = created
        lock.unlock()
        publishSyntheticSessionStartedIfNeeded(sessionID: sessionID)
        created.whenInitialized { [weak self, weak created] result in
            guard case .success = result,
                  let created else {
                return
            }
            self?.subscribeToLoadedThreadIfNeeded(sessionID: sessionID, session: created)
        }
        return created
    }

    private func threadID(for sessionID: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return states[sessionID]?.threadID
    }

    private func enqueue(_ turn: QueuedTurn, sessionID: String) {
        lock.lock()
        states[sessionID]?.queuedTurns.append(turn)
        lock.unlock()
    }

    private func startThreadIfNeeded(sessionID: String, session: CodexAppServerRuntimeSession) throws {
        try resolveThreadIfNeeded(sessionID: sessionID, session: session, startNewThreadIfMissing: true)
    }

    private func subscribeToLoadedThreadIfNeeded(sessionID: String, session: CodexAppServerRuntimeSession) {
        do {
            try resolveThreadIfNeeded(sessionID: sessionID, session: session, startNewThreadIfMissing: false)
        } catch {
            finishThreadResolutionWithoutStarting(sessionID: sessionID)
            BridgeLogger.server.error("codex app-server panel loaded thread subscription failed session_id=\(sessionID, privacy: .public) error=\(String(describing: error), privacy: .public)")
        }
    }

    private func resolveThreadIfNeeded(sessionID: String,
                                       session: CodexAppServerRuntimeSession,
                                       startNewThreadIfMissing: Bool) throws {
        lock.lock()
        guard let state = states[sessionID],
              state.threadID == nil,
              state.isStartingThread == false else {
            lock.unlock()
            return
        }
        state.isStartingThread = true
        let record = state.record
        lock.unlock()

        try session.listLoadedThreads { [weak self, weak session] result in
            self?.handleLoadedThreadsResponse(result,
                                              sessionID: sessionID,
                                              session: session,
                                              cwd: record.cwd,
                                              startNewThreadIfMissing: startNewThreadIfMissing)
        }
    }

    private func handleLoadedThreadsResponse(_ result: Result<JSONValue, CodexAppServerConnectionError>,
                                             sessionID: String,
                                             session: CodexAppServerRuntimeSession?,
                                             cwd: String?,
                                             startNewThreadIfMissing: Bool) {
        switch result {
        case .success(let value):
            let loadedThreadIDs = Self.loadedThreadIDs(from: value)
            if loadedThreadIDs.count == 1,
               let threadID = loadedThreadIDs.first,
               let session {
                resumeLoadedThread(threadID, sessionID: sessionID, session: session, cwd: cwd)
                return
            }
            if shouldStartNewThread(sessionID: sessionID, startNewThreadIfMissing: startNewThreadIfMissing) {
                startNewThread(sessionID: sessionID, session: session, cwd: cwd)
            } else {
                finishThreadResolutionWithoutStarting(sessionID: sessionID)
            }
        case .failure:
            if shouldStartNewThread(sessionID: sessionID, startNewThreadIfMissing: startNewThreadIfMissing) {
                startNewThread(sessionID: sessionID, session: session, cwd: cwd)
            } else {
                finishThreadResolutionWithoutStarting(sessionID: sessionID)
            }
        }
    }

    private func resumeLoadedThread(_ threadID: String,
                                    sessionID: String,
                                    session: CodexAppServerRuntimeSession,
                                    cwd: String?) {
        do {
            try session.resumeThread(threadID: threadID, cwd: cwd) { [weak self, weak session] result in
                self?.handleResumeThreadResponse(result,
                                                 requestedThreadID: threadID,
                                                 sessionID: sessionID,
                                                 session: session)
            }
        } catch {
            let turns = clearStartingState(sessionID: sessionID)
            publishBridgeError("Codex app-server failed to resume Mac thread: \(error.localizedDescription)", sessionID: sessionID)
            for turn in turns {
                publishAssistantMessage("Failed to submit queued Codex message: \(turn.text)", sessionID: sessionID)
            }
        }
    }

    private func handleResumeThreadResponse(_ result: Result<JSONValue, CodexAppServerConnectionError>,
                                            requestedThreadID: String,
                                            sessionID: String,
                                            session: CodexAppServerRuntimeSession?) {
        switch result {
        case .success(let value):
            guard let session else {
                let turns = clearStartingState(sessionID: sessionID)
                publishBridgeError("Codex app-server connection disappeared while resuming Mac thread.", sessionID: sessionID)
                for turn in turns {
                    publishAssistantMessage("Failed to submit queued Codex message: \(turn.text)", sessionID: sessionID)
                }
                return
            }
            activateThread(Self.threadID(from: value) ?? requestedThreadID,
                           sessionID: sessionID,
                           session: session,
                           logMessage: "codex app-server panel resumed loaded thread")
        case .failure(let error):
            let turns = clearStartingState(sessionID: sessionID)
            publishBridgeError("Codex app-server failed to resume Mac thread: \(error.localizedDescription)", sessionID: sessionID)
            for turn in turns {
                publishAssistantMessage("Failed to submit queued Codex message: \(turn.text)", sessionID: sessionID)
            }
        }
    }

    private func activateThread(_ threadID: String,
                                sessionID: String,
                                session: CodexAppServerRuntimeSession,
                                logMessage: StaticString? = nil) {
        lock.lock()
        guard let state = states[sessionID] else {
            lock.unlock()
            return
        }
        state.threadID = threadID
        state.isStartingThread = false
        let turns = state.queuedTurns
        state.queuedTurns.removeAll()
        lock.unlock()
        if let logMessage {
            BridgeLogger.server.info("\(logMessage, privacy: .public) session_id=\(sessionID, privacy: .public) thread_id=\(threadID, privacy: .public)")
        }
        for turn in turns {
            do {
                try startTurn(turn, threadID: threadID, session: session)
            } catch {
                publishBridgeError("Codex app-server failed to start turn: \(error.localizedDescription)", sessionID: sessionID)
            }
        }
    }

    private func startNewThread(sessionID: String,
                                session: CodexAppServerRuntimeSession?,
                                cwd: String?) {
        guard let session else {
            let turns = clearStartingState(sessionID: sessionID)
            publishBridgeError("Codex app-server connection disappeared while resolving thread.", sessionID: sessionID)
            for turn in turns {
                publishAssistantMessage("Failed to submit queued Codex message: \(turn.text)", sessionID: sessionID)
            }
            return
        }
        do {
            try session.startThread(cwd: cwd) { [weak self, weak session] result in
                self?.handleStartThreadResponse(result, sessionID: sessionID, session: session)
            }
        } catch {
            let turns = clearStartingState(sessionID: sessionID)
            publishBridgeError("Codex app-server failed to start thread: \(error.localizedDescription)", sessionID: sessionID)
            for turn in turns {
                publishAssistantMessage("Failed to submit queued Codex message: \(turn.text)", sessionID: sessionID)
            }
        }
    }

    private func handleStartThreadResponse(_ result: Result<JSONValue, CodexAppServerConnectionError>,
                                           sessionID: String,
                                           session: CodexAppServerRuntimeSession?) {
        switch result {
        case .success(let value):
            guard let threadID = Self.threadID(from: value),
                  let session else {
                let turns = clearStartingState(sessionID: sessionID)
                publishBridgeError("Codex app-server did not return a thread id.", sessionID: sessionID)
                for turn in turns {
                    publishAssistantMessage("Failed to submit queued Codex message: \(turn.text)", sessionID: sessionID)
                }
                return
            }
            lock.lock()
            let hasState = states[sessionID] != nil
            lock.unlock()
            guard hasState else { return }
            activateThread(threadID, sessionID: sessionID, session: session)

        case .failure(let error):
            let turns = clearStartingState(sessionID: sessionID)
            publishBridgeError("Codex app-server failed to start thread: \(error.localizedDescription)", sessionID: sessionID)
            for turn in turns {
                publishAssistantMessage("Failed to submit queued Codex message: \(turn.text)", sessionID: sessionID)
            }
        }
    }

    private func shouldStartNewThread(sessionID: String, startNewThreadIfMissing: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let hasQueuedTurns = states[sessionID]?.queuedTurns.isEmpty == false
        return startNewThreadIfMissing || hasQueuedTurns
    }

    private func finishThreadResolutionWithoutStarting(sessionID: String) {
        lock.lock()
        states[sessionID]?.isStartingThread = false
        lock.unlock()
    }

    @discardableResult
    private func clearStartingState(sessionID: String) -> [QueuedTurn] {
        lock.lock()
        defer { lock.unlock() }
        guard let state = states[sessionID] else {
            return []
        }
        state.isStartingThread = false
        let turns = state.queuedTurns
        state.queuedTurns.removeAll()
        return turns
    }

    private func startTurn(_ turn: QueuedTurn,
                           threadID: String,
                           session: CodexAppServerRuntimeSession) throws {
        try session.startTurn(threadID: threadID,
                              text: turn.text)
    }

    private func publishSyntheticSessionStartedIfNeeded(sessionID: String) {
        lock.lock()
        guard let state = states[sessionID],
              state.didPublishSessionStarted == false else {
            lock.unlock()
            return
        }
        state.didPublishSessionStarted = true
        let record = state.record
        lock.unlock()

        let seq = eventHub.nextSyntheticSeq(sessionID: record.sessionID)
        let event = AgentEvent(eventID: "codex-app-server-panel-session-started:\(record.sessionID)",
                               seq: seq,
                               vendor: "codex",
                               workspaceID: record.workspaceID,
                               sessionID: record.sessionID,
                               timestamp: timestampProvider(),
                               type: .sessionStarted,
                               role: nil,
                               text: "Codex",
                               name: nil,
                               input: nil,
                               output: nil,
                               toolCallID: nil,
                               metadata: [
                                "panel_id": record.panelID ?? "",
                                "source": "codex_app_server",
                                "runtime": "codex_app_server",
                               ],
                               payload: .object([
                                "kind": .string("codex_app_server_session_started"),
                                "source": .string("codex_app_server"),
                               ]))
        eventHub.publish(event)
    }

    private func publishBridgeError(_ message: String, sessionID: String) {
        publishAssistantMessage(message, payloadKind: "bridge_error", sessionID: sessionID)
    }

    private func publishAssistantMessage(_ message: String,
                                         payloadKind: String = "assistant_message",
                                         sessionID: String) {
        lock.lock()
        guard let record = states[sessionID]?.record else {
            lock.unlock()
            return
        }
        lock.unlock()
        let seq = eventHub.nextSyntheticSeq(sessionID: record.sessionID)
        let event = AgentEvent(eventID: "codex-app-server-panel:\(payloadKind):\(seq)",
                               seq: seq,
                               vendor: "codex",
                               workspaceID: record.workspaceID,
                               sessionID: record.sessionID,
                               timestamp: timestampProvider(),
                               type: .assistantMessage,
                               role: nil,
                               text: message,
                               name: nil,
                               input: nil,
                               output: nil,
                               toolCallID: nil,
                               metadata: [
                                "panel_id": record.panelID ?? "",
                                "source": "codex_app_server",
                                "runtime": "codex_app_server",
                               ],
                               payload: .object([
                                "kind": .string(payloadKind),
                                "source": .string("codex_app_server"),
                               ]))
        eventHub.publish(event)
    }

    private static func isCodexAppServerRecord(_ record: AgentSessionRegistryRecord) -> Bool {
        record.vendor == "codex" &&
        record.runtime == "codex_app_server" &&
        record.panelID?.isEmpty == false &&
        record.appServerSocket?.isEmpty == false
    }

    private static func threadID(from value: JSONValue) -> String? {
        value.objectValue?["threadId"]?.stringValue
            ?? value.objectValue?["thread"]?.objectValue?["id"]?.stringValue
            ?? value.objectValue?["id"]?.stringValue
    }

    private static func loadedThreadIDs(from value: JSONValue) -> [String] {
        value.objectValue?["data"]?.arrayValue?.compactMap(\.stringValue) ?? []
    }

    private static func jsonValue(for event: AgentEvent) -> JSONValue {
        let data = try? JSONEncoder().encode(event)
        let object = data
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            .map(jsonValue(from:)) ?? [:]
        return .object(object)
    }

    private static func jsonValue(from dictionary: [String: Any]) -> [String: JSONValue] {
        dictionary.reduce(into: [String: JSONValue]()) { result, pair in
            result[pair.key] = jsonValue(from: pair.value)
        }
    }

    private static func jsonValue(from value: Any) -> JSONValue {
        switch value {
        case let string as String:
            return .string(string)
        case let bool as Bool:
            return .bool(bool)
        case let int as Int:
            return .number(Double(int))
        case let double as Double:
            return .number(double)
        case let dictionary as [String: Any]:
            return .object(jsonValue(from: dictionary))
        case let array as [Any]:
            return .array(array.map(jsonValue(from:)))
        default:
            return .null
        }
    }

    private static func iso8601Now() -> String {
        ISO8601DateFormatter().string(from: Date())
    }
}
