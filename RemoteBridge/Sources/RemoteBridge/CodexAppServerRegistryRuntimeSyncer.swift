import Foundation

protocol CodexAppServerApprovalSubmitting: AnyObject {
    func submitApproval(promptID: String, targetIndex: Int) throws -> AgentEvent
}

protocol CodexAppServerApprovalPromptProviding: CodexAppServerApprovalSubmitting {
    func pendingApprovalPromptEvents(workspaceID: String, sessionID: String?) -> [AgentEvent]
}

protocol CodexAppServerRuntimeSessionControlling: AnyObject {
    func canSubmitMessage() -> Bool
    func ensureThreadSubscription()
    func pendingApprovalPromptEvents() -> [AgentEvent]
    func submitApproval(promptID: String, targetIndex: Int) throws -> AgentEvent
    func submitMessage(text: String) throws
    func stop()
}

extension CodexAppServerRuntimeSession: CodexAppServerRuntimeSessionControlling {}

final class CodexAppServerRegistryRuntimeSyncer: AgentSessionRuntimeSyncing, CodexAppServerApprovalPromptProviding, CodexAppServerChatSubmitting {
    typealias SidebarMessageSender = (String) throws -> Void
    typealias SidebarWorkspaceIDResolver = (AgentSessionRegistryRecord) -> String?
    typealias ActiveThreadHandler = (_ sessionID: String, _ threadID: String) -> Void
    typealias AttachHandler = (_ record: AgentSessionRegistryRecord,
                               _ nextSequence: @escaping CodexAppServerConnection.SequenceProvider,
                               _ timestampProvider: @escaping CodexAppServerConnection.TimestampProvider,
                               _ onAgentEvent: @escaping CodexAppServerHeadlessRuntime.AgentEventHandler,
                               _ onInteractivePrompt: @escaping CodexAppServerConnection.InteractivePromptHandler,
                               _ onInteractivePromptResolved: @escaping CodexAppServerConnection.InteractivePromptResolvedHandler,
                               _ onActiveThreadID: @escaping CodexAppServerHeadlessRuntime.ThreadIDHandler) throws -> CodexAppServerRuntimeSessionControlling

    private struct RuntimeEntry {
        let record: AgentSessionRegistryRecord
        let session: CodexAppServerRuntimeSessionControlling
    }

    private let eventHub: AgentEventHub
    private let sidebarMessageSender: SidebarMessageSender
    private let sidebarWorkspaceIDResolver: SidebarWorkspaceIDResolver
    private let sidebarQueue = DispatchQueue(label: "com.tidey.remote-bridge.codex-app-server-sidebar")
    private let timestampProvider: CodexAppServerConnection.TimestampProvider
    private let attachHandler: AttachHandler
    private let lock = NSLock()
    private var entriesBySessionID = [String: RuntimeEntry]()
    private var lastAssistantTextBySessionID = [String: String]()
    var activeThreadHandler: ActiveThreadHandler?

    init(eventHub: AgentEventHub,
         factory: CodexAppServerRuntimeSessionFactory = CodexAppServerRuntimeSessionFactory(),
         sidebarMessageSender: @escaping SidebarMessageSender = { _ in },
         sidebarWorkspaceIDResolver: @escaping SidebarWorkspaceIDResolver = { _ in nil },
         timestampProvider: @escaping CodexAppServerConnection.TimestampProvider = CodexAppServerRegistryRuntimeSyncer.iso8601Now,
         attachHandler: AttachHandler? = nil) {
        self.eventHub = eventHub
        self.sidebarMessageSender = sidebarMessageSender
        self.sidebarWorkspaceIDResolver = sidebarWorkspaceIDResolver
        self.timestampProvider = timestampProvider
        if let attachHandler {
            self.attachHandler = attachHandler
        } else {
            self.attachHandler = { record, nextSequence, timestampProvider, onAgentEvent, onInteractivePrompt, onInteractivePromptResolved, onActiveThreadID in
                guard let socketPath = record.appServerSocket,
                      let panelID = record.panelID,
                      !socketPath.isEmpty,
                      !panelID.isEmpty else {
                    throw BridgeInternalError.invalidRequest("Codex app-server registry record is missing socket or panel identity.")
                }
                return try factory.attach(socketPath: socketPath,
                                          processID: record.appServerPID,
                                          context: CodexAppServerRuntimeContext(workspaceID: record.workspaceID,
                                                                               panelID: panelID,
                                                                               sessionID: record.sessionID),
                                          nextSequence: nextSequence,
                                          timestampProvider: timestampProvider,
                                          onAgentEvent: onAgentEvent,
                                          onInteractivePrompt: onInteractivePrompt,
                                          onInteractivePromptResolved: onInteractivePromptResolved,
                                          onActiveThreadID: onActiveThreadID)
            }
        }
    }

    func sync(records: [AgentSessionRegistryRecord]) {
        let runtimeRecords = records.filter(Self.isAttachableCodexAppServerRecord(_:))
        let activeSessionIDs = Set(runtimeRecords.map(\.sessionID))

        lock.lock()
        let staleSessionIDs = entriesBySessionID.keys.filter { !activeSessionIDs.contains($0) }
        let staleEntries = staleSessionIDs.compactMap { entriesBySessionID.removeValue(forKey: $0) }
        let recordsToAttach = runtimeRecords.filter { record in
            guard let existing = entriesBySessionID[record.sessionID] else {
                return true
            }
            return existing.record.appServerSocket != record.appServerSocket ||
                existing.record.appServerPID != record.appServerPID ||
                existing.record.workspaceID != record.workspaceID ||
                existing.record.panelID != record.panelID
        }
        let replacedEntries = recordsToAttach.compactMap { entriesBySessionID.removeValue(forKey: $0.sessionID) }
        let reusedRecords = runtimeRecords.filter { record in
            entriesBySessionID[record.sessionID] != nil &&
                recordsToAttach.contains(where: { $0.sessionID == record.sessionID }) == false
        }
        lock.unlock()

        if recordsToAttach.isEmpty == false || staleEntries.isEmpty == false || replacedEntries.isEmpty == false {
            BridgeLogger.server.info("codex app-server diagnostic sync changed runtime_count=\(runtimeRecords.count, privacy: .public) attach_count=\(recordsToAttach.count, privacy: .public) reuse_count=\(reusedRecords.count, privacy: .public) stale_count=\(staleEntries.count, privacy: .public) replace_count=\(replacedEntries.count, privacy: .public) session_ids=\(runtimeRecords.map(\.sessionID).joined(separator: ","), privacy: .public)")
        }

        for entry in staleEntries + replacedEntries {
            entry.session.stop()
        }
        lock.withCodexRuntimeSyncerLock {
            for entry in staleEntries + replacedEntries {
                lastAssistantTextBySessionID.removeValue(forKey: entry.record.sessionID)
            }
        }

        for record in recordsToAttach {
            attach(record: record)
        }

        let reusedSessions = lock.withCodexRuntimeSyncerLock {
            for record in reusedRecords {
                if let entry = entriesBySessionID[record.sessionID] {
                    entriesBySessionID[record.sessionID] = RuntimeEntry(record: record, session: entry.session)
                }
            }
            return reusedRecords.compactMap { entriesBySessionID[$0.sessionID]?.session }
        }
        for session in reusedSessions {
            session.ensureThreadSubscription()
        }
    }

    func submitApproval(promptID: String, targetIndex: Int) throws -> AgentEvent {
        let sessions = lock.withCodexRuntimeSyncerLock {
            Array(entriesBySessionID.values.map(\.session))
        }
        var lastError: Error?
        for session in sessions {
            do {
                return try session.submitApproval(promptID: promptID, targetIndex: targetIndex)
            } catch BridgeInternalError.notFound {
                continue
            } catch {
                lastError = error
            }
        }
        if let lastError {
            throw lastError
        }
        throw BridgeInternalError.notFound("Unknown Codex approval prompt.")
    }

    func pendingApprovalPromptEvents(workspaceID: String, sessionID: String? = nil) -> [AgentEvent] {
        let entries = lock.withCodexRuntimeSyncerLock {
            let workspaceEntries = entriesBySessionID.values.filter { entry in
                entry.record.workspaceID == workspaceID
            }
            if let sessionID {
                let matchingSessionEntries = workspaceEntries.filter { entry in
                    entry.record.sessionID == sessionID
                }
                if matchingSessionEntries.isEmpty == false {
                    return matchingSessionEntries
                }
            }
            return workspaceEntries
        }
        let matchingEvents = pendingApprovalPromptEvents(from: entries)
        let events: [AgentEvent]
        if matchingEvents.isEmpty, sessionID != nil {
            let workspaceEntries = lock.withCodexRuntimeSyncerLock {
                entriesBySessionID.values.filter { entry in
                    entry.record.workspaceID == workspaceID
                }
            }
            events = pendingApprovalPromptEvents(from: workspaceEntries)
        } else {
            events = matchingEvents
        }
        var seen = Set<String>()
        return events.filter { event in
            guard seen.contains(event.eventID) == false else {
                return false
            }
            seen.insert(event.eventID)
            return true
        }.sorted { lhs, rhs in
            if lhs.timestamp == rhs.timestamp {
                if lhs.seq == rhs.seq {
                    return lhs.eventID < rhs.eventID
                }
                return lhs.seq < rhs.seq
            }
            return lhs.timestamp < rhs.timestamp
        }
    }

    private func pendingApprovalPromptEvents(from entries: [RuntimeEntry]) -> [AgentEvent] {
        entries.flatMap { entry in
            entry.session.pendingApprovalPromptEvents()
        }
    }

    func submitMessage(sessionID: String, text: String) throws {
        let session = lock.withCodexRuntimeSyncerLock {
            entriesBySessionID[sessionID]?.session
        }
        guard let session else {
            throw BridgeInternalError.notFound("Unknown Codex app-server session.")
        }
        try session.submitMessage(text: text)
    }

    func canSubmitMessage(sessionID: String) -> Bool {
        let session = lock.withCodexRuntimeSyncerLock {
            entriesBySessionID[sessionID]?.session
        }
        let result = session?.canSubmitMessage() == true
        BridgeLogger.server.debug("codex app-server diagnostic can_submit session_id=\(sessionID, privacy: .public) entry_exists=\((session != nil), privacy: .public) result=\(result, privacy: .public)")
        return result
    }

    private func attach(record: AgentSessionRegistryRecord) {
        do {
            let session = try attachHandler(record,
                                            { [eventHub] sessionID in eventHub.nextSyntheticSeq(sessionID: sessionID) },
                                            timestampProvider,
                                            { [weak self] event in
                                                self?.handleSidebarEvent(event, record: record)
                                            },
                                            { [eventHub] envelope in
                                                eventHub.publish(envelope.event)
                                                BridgeLogger.server.info("codex app-server approval prompt published workspace_id=\(envelope.event.workspaceID, privacy: .public) panel_id=\(envelope.event.metadata?["panel_id"] ?? "-", privacy: .public) session_id=\(envelope.event.sessionID, privacy: .public) prompt_id=\(envelope.prompt.promptID, privacy: .public)")
                                            },
                                            { [eventHub] event in
                                                eventHub.publish(event)
                                            },
                                            { [weak self, sessionID = record.sessionID] threadID in
                                                self?.activeThreadHandler?(sessionID, threadID)
                                            })
            lock.withCodexRuntimeSyncerLock {
                entriesBySessionID[record.sessionID] = RuntimeEntry(record: record, session: session)
            }
            BridgeLogger.server.info("codex app-server registry runtime attached workspace_id=\(record.workspaceID, privacy: .public) panel_id=\(record.panelID ?? "-", privacy: .public) session_id=\(record.sessionID, privacy: .public)")
        } catch {
            BridgeLogger.server.error("codex app-server registry runtime attach failed workspace_id=\(record.workspaceID, privacy: .public) panel_id=\(record.panelID ?? "-", privacy: .public) session_id=\(record.sessionID, privacy: .public) error=\(String(describing: error), privacy: .public)")
        }
    }

    private func handleSidebarEvent(_ event: AgentEvent, record: AgentSessionRegistryRecord) {
        let payloadKind = event.payload?.objectValue?["kind"]?.stringValue
        let workspaceID = sidebarWorkspaceID(for: record)
        switch (event.type, payloadKind) {
        case (.thinking, "turn_started"):
            sendSidebar(messages: CodexSidebarMessages.running(workspaceID: workspaceID),
                        sessionID: record.sessionID)

        case (.assistantMessage, "assistant_message"):
            guard let text = event.text,
                  text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                return
            }
            lock.withCodexRuntimeSyncerLock {
                lastAssistantTextBySessionID[record.sessionID] = text
            }

        case (.assistantFinal, "turn_completed"):
            let body = lock.withCodexRuntimeSyncerLock {
                lastAssistantTextBySessionID.removeValue(forKey: record.sessionID)
            } ?? "Task completed"
            sendSidebar(messages: CodexSidebarMessages.completed(workspaceID: workspaceID,
                                                                 body: body),
                        sessionID: record.sessionID)

        case (.assistantMessage, "turn_failed"),
             (.assistantMessage, "error"):
            let body = event.text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? event.text!
                : "Codex turn failed."
            _ = lock.withCodexRuntimeSyncerLock {
                lastAssistantTextBySessionID.removeValue(forKey: record.sessionID)
            }
            sendSidebar(messages: CodexSidebarMessages.completed(workspaceID: workspaceID,
                                                                 body: body),
                        sessionID: record.sessionID)

        default:
            break
        }
    }

    private func sidebarWorkspaceID(for record: AgentSessionRegistryRecord) -> String {
        guard let resolvedWorkspaceID = sidebarWorkspaceIDResolver(record),
              resolvedWorkspaceID.isEmpty == false else {
            return record.workspaceID
        }
        if resolvedWorkspaceID != record.workspaceID {
            BridgeLogger.server.info("codex app-server sidebar workspace resolved session_id=\(record.sessionID, privacy: .public) old_workspace_id=\(record.workspaceID, privacy: .public) workspace_id=\(resolvedWorkspaceID, privacy: .public)")
        }
        return resolvedWorkspaceID
    }

    private func sendSidebar(messages: [String], sessionID: String) {
        sidebarQueue.async { [sidebarMessageSender] in
            for message in messages {
                do {
                    try sidebarMessageSender(message)
                } catch {
                    BridgeLogger.server.error("codex app-server sidebar message failed session_id=\(sessionID, privacy: .public) message=\(message, privacy: .public) error=\(String(describing: error), privacy: .public)")
                }
            }
        }
    }

    private static func isAttachableCodexAppServerRecord(_ record: AgentSessionRegistryRecord) -> Bool {
        record.vendor == "codex" &&
            record.runtime == "codex_app_server" &&
            (record.appServerSocket?.isEmpty == false) &&
            (record.panelID?.isEmpty == false)
    }

    private static func iso8601Now() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }
}

private extension NSLock {
    func withCodexRuntimeSyncerLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
