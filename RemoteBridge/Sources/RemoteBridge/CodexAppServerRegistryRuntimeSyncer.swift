import Foundation

protocol CodexAppServerApprovalSubmitting: AnyObject {
    func submitApproval(promptID: String, targetIndex: Int) throws -> AgentEvent
    func submitApproval(promptID: String,
                        targetIndex: Int,
                        workspaceID: String,
                        panelID: String,
                        sessionID: String?) throws -> AgentEvent
}

extension CodexAppServerApprovalSubmitting {
    func submitApproval(promptID: String,
                        targetIndex: Int,
                        workspaceID: String,
                        panelID: String,
                        sessionID: String?) throws -> AgentEvent {
        try submitApproval(promptID: promptID, targetIndex: targetIndex)
    }
}

protocol CodexAppServerApprovalPromptProviding: CodexAppServerApprovalSubmitting {
    func pendingApprovalPromptEvents(workspaceID: String, sessionID: String?) -> [AgentEvent]
}

protocol CodexAppServerRuntimeSessionControlling: AnyObject {
    func canSubmitMessage() -> Bool
    func ensureThreadSubscription()
    func setRegistryRootThreadID(_ rawThreadID: String?)
    func isStopped() -> Bool
    func pendingApprovalPromptEvents() -> [AgentEvent]
    func refreshActiveThread()
    func submitApproval(promptID: String, targetIndex: Int) throws -> AgentEvent
    func submitMessage(text: String) throws
    func stop()
}

extension CodexAppServerRuntimeSessionControlling {
    func setRegistryRootThreadID(_ rawThreadID: String?) {}
    func isStopped() -> Bool { false }
}

extension CodexAppServerRuntimeSession: CodexAppServerRuntimeSessionControlling {}

final class CodexAppServerRegistryRuntimeSyncer: AgentSessionRuntimeSyncing, CodexAppServerApprovalPromptProviding, CodexAppServerChatSubmitting {
    typealias SidebarMessageSender = (String) throws -> Void
    typealias DateProvider = () -> Date
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
        let effectiveRootThreadID: String?
    }

    private let eventHub: AgentEventHub
    private let sidebarMessageSender: SidebarMessageSender
    private let sidebarQueue: DispatchQueue
    private let timestampProvider: CodexAppServerConnection.TimestampProvider
    private let dateProvider: DateProvider
    private let activeThreadRefreshInterval: TimeInterval
    private let transitionWaitTimeout: TimeInterval
    private let attachHandler: AttachHandler
    private let promptNotificationDeduper = AgentInteractivePromptNotificationDeduper()
    private let lock = NSLock()
    private var entriesBySessionID = [String: RuntimeEntry]()
    private var lastAssistantTextBySessionID = [String: String]()
    private var nextActiveThreadRefreshAtBySessionID = [String: Date]()
    var activeThreadHandler: ActiveThreadHandler?
    var generationRecheckHook: (() -> Void)?
    var transitionWaitHook: ((String) -> Void)?
    var sidebarDequeueRecheckHook: (() -> Void)?
    var syncArrivalHook: (([AgentSessionRegistryRecord]) -> Void)?
    var attachStageHook: ((CodexAppServerAttachStage) -> Void)?

    init(eventHub: AgentEventHub,
         factory: CodexAppServerRuntimeSessionFactory = CodexAppServerRuntimeSessionFactory(),
         sidebarMessageSender: @escaping SidebarMessageSender = { _ in },
         timestampProvider: @escaping CodexAppServerConnection.TimestampProvider = CodexAppServerRegistryRuntimeSyncer.iso8601Now,
         dateProvider: @escaping DateProvider = Date.init,
         activeThreadRefreshInterval: TimeInterval = 2.0,
         sidebarQueue: DispatchQueue = DispatchQueue(label: "com.tidey.remote-bridge.codex-app-server-sidebar"),
         transitionWaitTimeout: TimeInterval = 5.0,
         attachHandler: AttachHandler? = nil) {
        self.eventHub = eventHub
        self.sidebarQueue = sidebarQueue
        self.transitionWaitTimeout = transitionWaitTimeout
        self.sidebarMessageSender = sidebarMessageSender
        self.timestampProvider = timestampProvider
        self.dateProvider = dateProvider
        self.activeThreadRefreshInterval = activeThreadRefreshInterval
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
        syncArrivalHook?(records)
        let runtimeRecords = records.filter(Self.isAttachableCodexAppServerRecord(_:))
        let activeSessionIDs = Set(runtimeRecords.map(\.sessionID))

        lock.lock()
        let staleSessionIDs = entriesBySessionID.keys.filter { !activeSessionIDs.contains($0) }
        let staleEntries = staleSessionIDs.compactMap { entriesBySessionID.removeValue(forKey: $0) }
        let recordsToAttach = runtimeRecords.filter { record in
            guard let existing = entriesBySessionID[record.sessionID] else {
                return true
            }
            if existing.session.isStopped() {
                return true
            }
            if existing.record.appServerSocket != record.appServerSocket ||
                existing.record.appServerPID != record.appServerPID ||
                existing.record.workspaceID != record.workspaceID ||
                existing.record.panelID != record.panelID {
                return true
            }
            if let rootThreadID = Self.registryRootThreadID(from: record),
               rootThreadID != existing.effectiveRootThreadID {
                return true
            }
            return false
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
                nextActiveThreadRefreshAtBySessionID.removeValue(forKey: entry.record.sessionID)
                promptNotificationDeduper.remove(sessionID: entry.record.sessionID)
            }
        }

        for record in recordsToAttach {
            attach(record: record)
        }

        let reusedSessions = lock.withCodexRuntimeSyncerLock {
            let now = dateProvider()
            for record in reusedRecords {
                if let entry = entriesBySessionID[record.sessionID] {
                    entriesBySessionID[record.sessionID] = RuntimeEntry(
                        record: record,
                        session: entry.session,
                        effectiveRootThreadID: Self.registryRootThreadID(from: record)
                            ?? entry.effectiveRootThreadID)
                }
            }
            return reusedRecords.compactMap { record -> (session: CodexAppServerRuntimeSessionControlling, shouldRefresh: Bool)? in
                guard let session = entriesBySessionID[record.sessionID]?.session else {
                    return nil
                }
                return (session, shouldRefreshActiveThreadLocked(sessionID: record.sessionID, now: now))
            }
        }
        for (session, shouldRefresh) in reusedSessions {
            session.ensureThreadSubscription()
            if shouldRefresh {
                session.refreshActiveThread()
            }
        }
    }

    func submitApproval(promptID: String, targetIndex: Int) throws -> AgentEvent {
        try submitApproval(promptID: promptID,
                           targetIndex: targetIndex,
                           workspaceID: nil,
                           panelID: nil,
                           sessionID: nil)
    }

    func submitApproval(promptID: String,
                        targetIndex: Int,
                        workspaceID: String,
                        panelID: String,
                        sessionID: String?) throws -> AgentEvent {
        try submitApproval(promptID: promptID,
                           targetIndex: targetIndex,
                           workspaceID: Optional(workspaceID),
                           panelID: Optional(panelID),
                           sessionID: sessionID)
    }

    private func submitApproval(promptID: String,
                                targetIndex: Int,
                                workspaceID: String?,
                                panelID: String?,
                                sessionID: String?) throws -> AgentEvent {
        let sessions = lock.withCodexRuntimeSyncerLock {
            let entries: [RuntimeEntry]
            if let sessionID {
                if let matchingEntry = entriesBySessionID[sessionID] {
                    entries = [matchingEntry]
                } else {
                    entries = []
                }
            } else {
                entries = Array(entriesBySessionID.values)
            }
            return entries.map(\.session)
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
        if let workspaceID,
           let panelID,
           let sessionID {
            if let resolvedEvent = eventHub.latestInteractivePromptResolvedEvent(workspaceID: workspaceID,
                                                                                sessionID: sessionID,
                                                                                promptID: promptID) {
                return resolvedEvent
            }
            return alreadyResolvedApprovalEvent(promptID: promptID,
                                                workspaceID: workspaceID,
                                                panelID: panelID,
                                                sessionID: sessionID)
        }
        throw BridgeInternalError.notFound("Unknown Codex approval prompt.")
    }

    func pendingApprovalPromptEvents(workspaceID: String, sessionID: String? = nil) -> [AgentEvent] {
        let entries = lock.withCodexRuntimeSyncerLock {
            let workspaceEntries = entriesBySessionID.values.filter { entry in
                entry.record.workspaceID == workspaceID
            }
            if let sessionID {
                return workspaceEntries.filter { entry in
                    entry.record.sessionID == sessionID
                }
            }
            return workspaceEntries
        }
        let events = pendingApprovalPromptEvents(from: entries)
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

    private func alreadyResolvedApprovalEvent(promptID: String,
                                              workspaceID: String,
                                              panelID: String,
                                              sessionID: String) -> AgentEvent {
        AgentEvent(eventID: "codex-app-server-prompt-resolved:\(promptID):already_resolved",
                   seq: eventHub.nextSyntheticSeq(sessionID: sessionID),
                   vendor: "codex",
                   workspaceID: workspaceID,
                   sessionID: sessionID,
                   timestamp: timestampProvider(),
                   type: .interactivePromptResolved,
                   role: nil,
                   text: nil,
                   name: nil,
                   input: nil,
                   output: nil,
                   toolCallID: nil,
                   metadata: [
                    "panel_id": panelID,
                    "source": "codex_app_server",
                    "prompt_id": promptID,
                    "reason": "already_resolved",
                    "submit_channel": InteractivePromptSubmitChannel.codexAppServer,
                   ])
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

    static func registryRootThreadID(from record: AgentSessionRegistryRecord) -> String? {
        for candidate in [record.threadID, record.resumeThreadID] {
            if let threadID = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
               threadID.isEmpty == false {
                return threadID
            }
        }
        return nil
    }

    private func attach(record: AgentSessionRegistryRecord) {
        do {
            let session = try attachHandler(record,
                                            { [eventHub] sessionID in eventHub.nextSyntheticSeq(sessionID: sessionID) },
                                            timestampProvider,
                                            { [weak self] event in
                                                self?.handleSidebarEvent(event, record: record)
                                            },
                                            { [weak self, eventHub] envelope in
                                                eventHub.publish(envelope.event)
                                                self?.handleSidebarEvent(envelope.event, record: record)
                                                BridgeLogger.server.info("codex app-server approval prompt published workspace_id=\(envelope.event.workspaceID, privacy: .public) panel_id=\(envelope.event.metadata?["panel_id"] ?? "-", privacy: .public) session_id=\(envelope.event.sessionID, privacy: .public) prompt_id=\(envelope.prompt.promptID, privacy: .public)")
                                            },
                                            { [weak self, eventHub] event in
                                                eventHub.publish(event)
                                                self?.handleSidebarEvent(event, record: record)
                                            },
                                            { [weak self, sessionID = record.sessionID] threadID in
                                                self?.activeThreadHandler?(sessionID, threadID)
                                            })
            let rootThreadID = Self.registryRootThreadID(from: record)
            session.setRegistryRootThreadID(rootThreadID)
            lock.withCodexRuntimeSyncerLock {
                entriesBySessionID[record.sessionID] = RuntimeEntry(record: record,
                                                                    session: session,
                                                                    effectiveRootThreadID: rootThreadID)
                nextActiveThreadRefreshAtBySessionID[record.sessionID] = dateProvider().addingTimeInterval(activeThreadRefreshInterval)
            }
            BridgeLogger.server.info("codex app-server registry runtime attached workspace_id=\(record.workspaceID, privacy: .public) panel_id=\(record.panelID ?? "-", privacy: .public) session_id=\(record.sessionID, privacy: .public)")
        } catch {
            BridgeLogger.server.error("codex app-server registry runtime attach failed workspace_id=\(record.workspaceID, privacy: .public) panel_id=\(record.panelID ?? "-", privacy: .public) session_id=\(record.sessionID, privacy: .public) error=\(String(describing: error), privacy: .public)")
        }
    }

    private func handleSidebarEvent(_ event: AgentEvent, record: AgentSessionRegistryRecord) {
        sidebarQueue.async { [weak self] in
            self?.handleSidebarEventOnQueue(event, record: record)
        }
    }

    private func handleSidebarEventOnQueue(_ event: AgentEvent, record: AgentSessionRegistryRecord) {
        let payloadKind = event.payload?.objectValue?["kind"]?.stringValue
        switch (event.type, payloadKind) {
        case (.thinking, "turn_started"):
            sendSidebarOnQueue(messages: CodexSidebarMessages.running(workspaceID: record.workspaceID),
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
            sendSidebarOnQueue(messages: CodexSidebarMessages.completed(workspaceID: record.workspaceID,
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
            sendSidebarOnQueue(messages: CodexSidebarMessages.completed(workspaceID: record.workspaceID,
                                                                        body: body),
                               sessionID: record.sessionID)

        case (.interactivePrompt, _):
            guard shouldNotifyPrompt(event, sessionID: record.sessionID) else {
                return
            }
            sendSidebarOnQueue(messages: AgentInteractivePromptSidebarMessages.messages(for: event,
                                                                                       workspaceID: record.workspaceID),
                               sessionID: record.sessionID)

        case (.interactivePromptResolved, _):
            markPromptResolved(event, sessionID: record.sessionID)
            sendSidebarOnQueue(messages: AgentInteractivePromptSidebarMessages.messages(for: event,
                                                                                       workspaceID: record.workspaceID),
                               sessionID: record.sessionID)

        default:
            break
        }
    }

    private func shouldNotifyPrompt(_ event: AgentEvent, sessionID: String) -> Bool {
        promptNotificationDeduper.shouldNotify(event, sessionID: sessionID)
    }

    private func markPromptResolved(_ event: AgentEvent, sessionID: String) {
        promptNotificationDeduper.markResolved(event, sessionID: sessionID)
    }

    private func sendSidebarOnQueue(messages: [String], sessionID: String) {
        for message in messages {
            do {
                try sidebarMessageSender(message)
            } catch {
                BridgeLogger.server.error("codex app-server sidebar message failed session_id=\(sessionID, privacy: .public) message=\(message, privacy: .public) error=\(String(describing: error), privacy: .public)")
            }
        }
    }

    private func shouldRefreshActiveThreadLocked(sessionID: String, now: Date) -> Bool {
        guard activeThreadRefreshInterval >= 0 else {
            return false
        }
        if let nextRefreshAt = nextActiveThreadRefreshAtBySessionID[sessionID],
           nextRefreshAt > now {
            return false
        }
        nextActiveThreadRefreshAtBySessionID[sessionID] = now.addingTimeInterval(activeThreadRefreshInterval)
        return true
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

// Test seam for attach-time callback transactionality. The pass-through
// implementation preserves existing behavior until the behavioral change
// wires staging into attach().
final class CodexAppServerAttachStage: @unchecked Sendable {
    var commitDrainHook: (() -> Void)?

    func run(_ work: @escaping () -> Void) {
        work()
    }

    func commit() {}
    func discard() {}
}

private extension NSLock {
    func withCodexRuntimeSyncerLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
