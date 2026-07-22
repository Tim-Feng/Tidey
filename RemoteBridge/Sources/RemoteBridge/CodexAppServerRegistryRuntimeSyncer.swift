import Foundation

protocol CodexAppServerApprovalSubmitting: AnyObject {
    func submitApproval(promptID: String, targetIndex: Int) throws -> AgentEvent
    func submitApproval(promptID: String,
                        targetIndex: Int,
                        workspaceID: String,
                        panelID: String,
                        sessionID: String?) throws -> AgentEvent
    func submitApproval(promptID: String,
                        targetIndex: Int,
                        clientRequestID: String?,
                        lifecycleToken: String?,
                        workspaceID: String,
                        panelID: String,
                        sessionID: String?) throws -> CodexAppServerApprovalSubmitOutcome
    func submitUserInput(promptID: String,
                         answers: [String: [String]],
                         clientRequestID: String?,
                         lifecycleToken: String?,
                         workspaceID: String,
                         panelID: String,
                         sessionID: String?) throws -> CodexAppServerApprovalSubmitOutcome
}

extension CodexAppServerApprovalSubmitting {
    func submitApproval(promptID: String,
                        targetIndex: Int,
                        workspaceID: String,
                        panelID: String,
                        sessionID: String?) throws -> AgentEvent {
        try submitApproval(promptID: promptID, targetIndex: targetIndex)
    }

    func submitApproval(promptID: String,
                        targetIndex: Int,
                        clientRequestID: String?,
                        lifecycleToken: String?,
                        workspaceID: String,
                        panelID: String,
                        sessionID: String?) throws -> CodexAppServerApprovalSubmitOutcome {
        let event = try submitApproval(promptID: promptID,
                                       targetIndex: targetIndex,
                                       workspaceID: workspaceID,
                                       panelID: panelID,
                                       sessionID: sessionID)
        if let reason = event.metadata?["reason"], reason != "submit" {
            return .alreadyResolved(event)
        }
        return .pendingConfirmation(promptID: promptID)
    }

    func submitUserInput(promptID: String,
                         answers: [String: [String]],
                         clientRequestID: String?,
                         lifecycleToken: String?,
                         workspaceID: String,
                         panelID: String,
                         sessionID: String?) throws -> CodexAppServerApprovalSubmitOutcome {
        throw BridgeInternalError.notFound("Unknown Codex approval prompt.")
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
    func submitApproval(promptID: String,
                        targetIndex: Int,
                        clientRequestID: String?,
                        lifecycleToken: String?) throws -> CodexAppServerApprovalSubmitOutcome
    func submitUserInput(promptID: String,
                         answers: [String: [String]],
                         clientRequestID: String?,
                         lifecycleToken: String?) throws -> CodexAppServerApprovalSubmitOutcome
    func submitMessage(text: String) throws
    func submitMessage(text: String, clientRequestID: String?) throws
    func stop()
}

extension CodexAppServerRuntimeSessionControlling {
    func setRegistryRootThreadID(_ rawThreadID: String?) {}
    func isStopped() -> Bool { false }
    func submitApproval(promptID: String,
                        targetIndex: Int,
                        clientRequestID: String?,
                        lifecycleToken: String?) throws -> CodexAppServerApprovalSubmitOutcome {
        let event = try submitApproval(promptID: promptID, targetIndex: targetIndex)
        if let reason = event.metadata?["reason"], reason != "submit" {
            return .alreadyResolved(event)
        }
        return .pendingConfirmation(promptID: promptID)
    }
    func submitUserInput(promptID: String,
                         answers: [String: [String]],
                         clientRequestID: String?,
                         lifecycleToken: String?) throws -> CodexAppServerApprovalSubmitOutcome {
        throw BridgeInternalError.notFound("Unknown Codex approval prompt.")
    }
    func submitMessage(text: String, clientRequestID: String?) throws {
        try submitMessage(text: text)
    }
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
        let generation: UUID
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
    private let forwardLock = NSRecursiveLock()
    private let syncSerialLock = NSLock()
    private var entriesBySessionID = [String: RuntimeEntry]()
    private var currentGenerationBySessionID = [String: UUID]()
    private var retiringGenerations = Set<UUID>()
    private var transitionGroupsBySessionID = [String: DispatchGroup]()
    private var transitionDepthBySessionID = [String: Int]()
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
        syncSerialLock.lock()
        defer { syncSerialLock.unlock() }
        syncLockedPass(records: records)
    }

    private func syncLockedPass(records: [AgentSessionRegistryRecord]) {
        let runtimeRecords = records.filter(Self.isAttachableCodexAppServerRecord(_:))
        let activeSessionIDs = Set(runtimeRecords.map(\.sessionID))

        forwardLock.lock()
        lock.lock()
        let staleSessionIDs = entriesBySessionID.keys.filter { !activeSessionIDs.contains($0) }
        let staleEntries = staleSessionIDs.compactMap { sessionID -> RuntimeEntry? in
            guard let entry = entriesBySessionID.removeValue(forKey: sessionID) else {
                return nil
            }
            if currentGenerationBySessionID[sessionID] == entry.generation {
                currentGenerationBySessionID.removeValue(forKey: sessionID)
                retiringGenerations.insert(entry.generation)
            }
            return entry
        }
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
        let replacedEntries = recordsToAttach.compactMap { record -> RuntimeEntry? in
            guard let entry = entriesBySessionID.removeValue(forKey: record.sessionID) else {
                return nil
            }
            if currentGenerationBySessionID[record.sessionID] == entry.generation {
                currentGenerationBySessionID.removeValue(forKey: record.sessionID)
                retiringGenerations.insert(entry.generation)
            }
            return entry
        }
        let reusedRecords = runtimeRecords.filter { record in
            entriesBySessionID[record.sessionID] != nil &&
                recordsToAttach.contains(where: { $0.sessionID == record.sessionID }) == false
        }
        let transitioningSessionIDs = Set(staleEntries.map(\.record.sessionID))
            .union(recordsToAttach.map(\.sessionID))
        for sessionID in transitioningSessionIDs {
            let group = transitionGroupsBySessionID[sessionID] ?? DispatchGroup()
            group.enter()
            transitionGroupsBySessionID[sessionID] = group
            transitionDepthBySessionID[sessionID, default: 0] += 1
        }
        lock.unlock()
        forwardLock.unlock()

        if recordsToAttach.isEmpty == false || staleEntries.isEmpty == false || replacedEntries.isEmpty == false {
            BridgeLogger.server.info("codex app-server diagnostic sync changed runtime_count=\(runtimeRecords.count, privacy: .public) attach_count=\(recordsToAttach.count, privacy: .public) reuse_count=\(reusedRecords.count, privacy: .public) stale_count=\(staleEntries.count, privacy: .public) replace_count=\(replacedEntries.count, privacy: .public) session_ids=\(runtimeRecords.map(\.sessionID).joined(separator: ","), privacy: .public)")
        }

        for entry in staleEntries + replacedEntries {
            entry.session.stop()
        }
        let retiredEntries = staleEntries + replacedEntries
        lock.withCodexRuntimeSyncerLock {
            for entry in retiredEntries {
                lastAssistantTextBySessionID.removeValue(forKey: entry.record.sessionID)
                nextActiveThreadRefreshAtBySessionID.removeValue(forKey: entry.record.sessionID)
            }
        }
        if retiredEntries.isEmpty == false {
            // stop() may synchronously enqueue the retiring lifecycle's terminal.
            // Clear its notification state behind that work and before callbacks
            // from the replacement attach can enqueue their new lifecycle.
            sidebarQueue.async { [weak self] in
                guard let self else { return }
                self.forwardLock.withCodexRuntimeSyncerLock {
                    self.lock.withCodexRuntimeSyncerLock {
                        for entry in retiredEntries {
                            self.retiringGenerations.remove(entry.generation)
                            self.promptNotificationDeduper.remove(sessionID: entry.record.sessionID)
                        }
                    }
                }
            }
        }

        let attachSessionIDs = Set(recordsToAttach.map(\.sessionID))
        for entry in staleEntries where attachSessionIDs.contains(entry.record.sessionID) == false {
            leaveGenerationTransition(sessionID: entry.record.sessionID)
        }
        for record in recordsToAttach {
            attach(record: record)
            leaveGenerationTransition(sessionID: record.sessionID)
        }

        let reusedSessions = lock.withCodexRuntimeSyncerLock {
            let now = dateProvider()
            for record in reusedRecords {
                if let entry = entriesBySessionID[record.sessionID] {
                    entriesBySessionID[record.sessionID] = RuntimeEntry(
                        record: record,
                        session: entry.session,
                        generation: entry.generation,
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

    func submitApproval(promptID: String,
                        targetIndex: Int,
                        clientRequestID: String?,
                        lifecycleToken: String?,
                        workspaceID: String,
                        panelID: String,
                        sessionID: String?) throws -> CodexAppServerApprovalSubmitOutcome {
        try performLifecyclePromptSubmit(promptID: promptID,
                                         lifecycleToken: lifecycleToken,
                                         workspaceID: workspaceID,
                                         panelID: panelID,
                                         sessionID: sessionID) { session in
            try session.submitApproval(promptID: promptID,
                                       targetIndex: targetIndex,
                                       clientRequestID: clientRequestID,
                                       lifecycleToken: lifecycleToken)
        }
    }

    func submitUserInput(promptID: String,
                         answers: [String: [String]],
                         clientRequestID: String?,
                         lifecycleToken: String?,
                         workspaceID: String,
                         panelID: String,
                         sessionID: String?) throws -> CodexAppServerApprovalSubmitOutcome {
        try performLifecyclePromptSubmit(promptID: promptID,
                                         lifecycleToken: lifecycleToken,
                                         workspaceID: workspaceID,
                                         panelID: panelID,
                                         sessionID: sessionID) { session in
            try session.submitUserInput(promptID: promptID,
                                        answers: answers,
                                        clientRequestID: clientRequestID,
                                        lifecycleToken: lifecycleToken)
        }
    }

    private func submitApproval(promptID: String,
                                targetIndex: Int,
                                workspaceID: String?,
                                panelID: String?,
                                sessionID: String?,
                                generationRetriesRemaining: Int = 1) throws -> AgentEvent {
        let candidates = lock.withCodexRuntimeSyncerLock {
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
            return entries.map {
                (sessionID: $0.record.sessionID,
                 session: $0.session,
                 generation: $0.generation)
            }
        }
        var lastError: Error?
        for candidate in candidates {
            let result: Result<AgentEvent, Error>
            do {
                result = .success(try candidate.session.submitApproval(promptID: promptID,
                                                                       targetIndex: targetIndex))
            } catch {
                result = .failure(error)
            }
            let stillCurrent = lock.withCodexRuntimeSyncerLock {
                entriesBySessionID[candidate.sessionID]?.generation == candidate.generation
            }
            if stillCurrent == false, generationRetriesRemaining > 0 {
                try requireTransitionSettled(awaitGenerationTransition(sessionID: candidate.sessionID))
                return try submitApproval(promptID: promptID,
                                          targetIndex: targetIndex,
                                          workspaceID: workspaceID,
                                          panelID: panelID,
                                          sessionID: sessionID,
                                          generationRetriesRemaining: generationRetriesRemaining - 1)
            }
            switch result {
            case .success(let event):
                guard stillCurrent else {
                    throw BridgeInternalError.conflict("Codex runtime was replaced during approval submit; retry.")
                }
                return event
            case .failure(let error):
                if case BridgeInternalError.notFound = error {
                    continue
                }
                lastError = error
            }
        }
        if let lastError {
            throw lastError
        }
        if candidates.isEmpty,
           let sessionID,
           generationRetriesRemaining > 0,
           lock.withCodexRuntimeSyncerLock({ (transitionDepthBySessionID[sessionID] ?? 0) > 0 }) {
            try requireTransitionSettled(awaitGenerationTransition(sessionID: sessionID))
            return try submitApproval(promptID: promptID,
                                      targetIndex: targetIndex,
                                      workspaceID: workspaceID,
                                      panelID: panelID,
                                      sessionID: sessionID,
                                      generationRetriesRemaining: generationRetriesRemaining - 1)
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

    private func performLifecyclePromptSubmit(
        promptID: String,
        lifecycleToken: String?,
        workspaceID: String,
        panelID: String,
        sessionID: String?,
        generationRetriesRemaining: Int = 1,
        using submit: (CodexAppServerRuntimeSessionControlling) throws -> CodexAppServerApprovalSubmitOutcome
    ) throws -> CodexAppServerApprovalSubmitOutcome {
        guard let sessionID,
              sessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw BridgeInternalError.notFound("Unknown Codex approval prompt.")
        }

        let candidate = lock.withCodexRuntimeSyncerLock { () -> (session: CodexAppServerRuntimeSessionControlling, generation: UUID)? in
            guard let entry = entriesBySessionID[sessionID],
                  entry.record.workspaceID == workspaceID,
                  entry.record.panelID == panelID else {
                return nil
            }
            return (entry.session, entry.generation)
        }

        if let candidate {
            let result: Result<CodexAppServerApprovalSubmitOutcome, Error>
            do {
                result = .success(try submit(candidate.session))
            } catch {
                result = .failure(error)
            }
            let stillCurrent = lock.withCodexRuntimeSyncerLock {
                entriesBySessionID[sessionID]?.generation == candidate.generation
            }
            if stillCurrent == false {
                guard generationRetriesRemaining > 0 else {
                    throw BridgeInternalError.conflict("Codex runtime was replaced during approval submit; retry.")
                }
                try requireTransitionSettled(awaitGenerationTransition(sessionID: sessionID))
                return try performLifecyclePromptSubmit(
                    promptID: promptID,
                    lifecycleToken: lifecycleToken,
                    workspaceID: workspaceID,
                    panelID: panelID,
                    sessionID: sessionID,
                    generationRetriesRemaining: generationRetriesRemaining - 1,
                    using: submit)
            }

            switch result {
            case .success(let outcome):
                return try validatedLifecycleOutcome(outcome,
                                                     promptID: promptID,
                                                     lifecycleToken: lifecycleToken,
                                                     workspaceID: workspaceID,
                                                     panelID: panelID,
                                                     sessionID: sessionID)
            case .failure(let error):
                if case BridgeInternalError.notFound = error {
                    break
                }
                throw error
            }
        }

        if candidate == nil,
           generationRetriesRemaining > 0,
           lock.withCodexRuntimeSyncerLock({ (transitionDepthBySessionID[sessionID] ?? 0) > 0 }) {
            try requireTransitionSettled(awaitGenerationTransition(sessionID: sessionID))
            return try performLifecyclePromptSubmit(
                promptID: promptID,
                lifecycleToken: lifecycleToken,
                workspaceID: workspaceID,
                panelID: panelID,
                sessionID: sessionID,
                generationRetriesRemaining: generationRetriesRemaining - 1,
                using: submit)
        }

        if let resolvedEvent = eventHub.latestInteractivePromptResolvedEvent(
            workspaceID: workspaceID,
            sessionID: sessionID,
            promptID: promptID,
            lifecycleToken: lifecycleToken,
            openerRequiresCapability: true),
           isMatchingLifecycleTerminal(resolvedEvent,
                                       promptID: promptID,
                                       lifecycleToken: lifecycleToken,
                                       workspaceID: workspaceID,
                                       panelID: panelID,
                                       sessionID: sessionID),
           eventHub.activeInteractivePrompt(workspaceID: workspaceID,
                                            sessionID: sessionID,
                                            promptID: promptID) == nil {
            return .alreadyResolved(resolvedEvent)
        }
        throw BridgeInternalError.notFound("Unknown Codex approval prompt.")
    }

    private func validatedLifecycleOutcome(
        _ outcome: CodexAppServerApprovalSubmitOutcome,
        promptID: String,
        lifecycleToken: String?,
        workspaceID: String,
        panelID: String,
        sessionID: String
    ) throws -> CodexAppServerApprovalSubmitOutcome {
        switch outcome {
        case .pendingConfirmation(let returnedPromptID):
            guard returnedPromptID == promptID else {
                throw BridgeInternalError.notFound("Unknown Codex approval prompt.")
            }
        case .alreadyResolved(let event):
            guard isMatchingLifecycleTerminal(event,
                                              promptID: promptID,
                                              lifecycleToken: lifecycleToken,
                                              workspaceID: workspaceID,
                                              panelID: panelID,
                                              sessionID: sessionID) else {
                throw BridgeInternalError.notFound("Unknown Codex approval prompt.")
            }
        }
        return outcome
    }

    private func isMatchingLifecycleTerminal(
        _ event: AgentEvent,
        promptID: String,
        lifecycleToken: String?,
        workspaceID: String,
        panelID: String,
        sessionID: String
    ) -> Bool {
        let eventPanelID = event.metadata?["panel_id"]
            ?? event.payload?.objectValue?["panel_id"]?.stringValue
        return event.vendor == "codex"
            && event.workspaceID == workspaceID
            && event.sessionID == sessionID
            && event.type == .interactivePromptResolved
            && AgentInteractivePromptSidebarMessages.promptID(from: event) == promptID
            && eventPanelID == panelID
            && AgentInteractivePromptSidebarMessages.terminalCloses(
                openerLifecycleToken: lifecycleToken,
                openerRequiresCapability: true,
                terminal: event)
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
        try submitMessage(sessionID: sessionID, text: text, clientRequestID: nil)
    }

    func submitMessage(sessionID: String, text: String, clientRequestID: String?) throws {
        let session = lock.withCodexRuntimeSyncerLock {
            entriesBySessionID[sessionID]?.session
        }
        guard let session else {
            throw CodexAppServerSubmitFailure.unavailableBeforeSend(
                "Unknown Codex app-server session.")
        }
        try session.submitMessage(text: text, clientRequestID: clientRequestID)
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
        let generation = UUID()
        forwardLock.withCodexRuntimeSyncerLock {
            lock.withCodexRuntimeSyncerLock {
                currentGenerationBySessionID[record.sessionID] = generation
            }
        }
        let stage = CodexAppServerAttachStage()
        attachStageHook?(stage)
        do {
            let session = try attachHandler(record,
                                            { [eventHub] sessionID in eventHub.nextSyntheticSeq(sessionID: sessionID) },
                                            timestampProvider,
                                            { [weak self, sessionID = record.sessionID, generation] event in
                                                stage.run {
                                                    self?.forwardIfCurrent(sessionID: sessionID, generation: generation) {
                                                        self?.handleSidebarEvent(event, record: record, generation: generation)
                                                    }
                                                }
                                            },
                                            { [weak self, eventHub, sessionID = record.sessionID, generation] envelope in
                                                stage.run {
                                                    self?.forwardIfCurrent(sessionID: sessionID, generation: generation) {
                                                        eventHub.publish(envelope.event)
                                                        self?.handleSidebarEvent(envelope.event, record: record, generation: generation)
                                                        BridgeLogger.server.info("codex app-server approval prompt published workspace_id=\(envelope.event.workspaceID, privacy: .public) panel_id=\(envelope.event.metadata?["panel_id"] ?? "-", privacy: .public) session_id=\(envelope.event.sessionID, privacy: .public) prompt_id=\(envelope.prompt.promptID, privacy: .public)")
                                                    }
                                                }
                                            },
                                            { [weak self, eventHub, sessionID = record.sessionID, generation] event in
                                                stage.run {
                                                    self?.forwardIfCurrentOrRetiring(sessionID: sessionID, generation: generation) {
                                                        eventHub.publish(event)
                                                        self?.handleSidebarEvent(event, record: record, generation: generation)
                                                    }
                                                }
                                            },
                                            { [weak self, sessionID = record.sessionID, generation] threadID in
                                                stage.run {
                                                    self?.forwardIfCurrent(sessionID: sessionID, generation: generation) {
                                                        self?.activeThreadHandler?(sessionID, threadID)
                                                    }
                                                }
                                            })
            let rootThreadID = Self.registryRootThreadID(from: record)
            session.setRegistryRootThreadID(rootThreadID)
            lock.withCodexRuntimeSyncerLock {
                entriesBySessionID[record.sessionID] = RuntimeEntry(record: record,
                                                                    session: session,
                                                                    generation: generation,
                                                                    effectiveRootThreadID: rootThreadID)
                nextActiveThreadRefreshAtBySessionID[record.sessionID] = dateProvider().addingTimeInterval(activeThreadRefreshInterval)
            }
            stage.commit()
            BridgeLogger.server.info("codex app-server registry runtime attached workspace_id=\(record.workspaceID, privacy: .public) panel_id=\(record.panelID ?? "-", privacy: .public) session_id=\(record.sessionID, privacy: .public)")
        } catch {
            stage.discard()
            forwardLock.withCodexRuntimeSyncerLock {
                lock.withCodexRuntimeSyncerLock {
                    if currentGenerationBySessionID[record.sessionID] == generation {
                        currentGenerationBySessionID.removeValue(forKey: record.sessionID)
                    }
                }
            }
            BridgeLogger.server.error("codex app-server registry runtime attach failed workspace_id=\(record.workspaceID, privacy: .public) panel_id=\(record.panelID ?? "-", privacy: .public) session_id=\(record.sessionID, privacy: .public) error=\(String(describing: error), privacy: .public)")
        }
    }

    private func forwardIfCurrent(sessionID: String, generation: UUID, _ commit: () -> Void) {
        guard isCurrentGeneration(sessionID: sessionID, generation: generation) else {
            return
        }
        generationRecheckHook?()
        forwardLock.withCodexRuntimeSyncerLock {
            guard isCurrentGeneration(sessionID: sessionID, generation: generation) else {
                return
            }
            commit()
        }
    }

    private func forwardIfCurrentOrRetiring(sessionID: String, generation: UUID, _ commit: () -> Void) {
        guard isCurrentOrRetiringGeneration(sessionID: sessionID, generation: generation) else {
            return
        }
        generationRecheckHook?()
        forwardLock.withCodexRuntimeSyncerLock {
            guard isCurrentOrRetiringGeneration(sessionID: sessionID, generation: generation) else {
                return
            }
            commit()
        }
    }

    private func isCurrentGeneration(sessionID: String, generation: UUID) -> Bool {
        lock.withCodexRuntimeSyncerLock {
            currentGenerationBySessionID[sessionID] == generation
        }
    }

    private func isCurrentOrRetiringGeneration(sessionID: String, generation: UUID) -> Bool {
        lock.withCodexRuntimeSyncerLock {
            currentGenerationBySessionID[sessionID] == generation || retiringGenerations.contains(generation)
        }
    }

    private func handleSidebarEvent(_ event: AgentEvent,
                                    record: AgentSessionRegistryRecord,
                                    generation: UUID) {
        sidebarQueue.async { [weak self] in
            guard let self else { return }
            let mayExecute: () -> Bool = {
                if event.type == .interactivePromptResolved {
                    return self.isCurrentOrRetiringGeneration(sessionID: record.sessionID,
                                                              generation: generation)
                }
                return self.isCurrentGeneration(sessionID: record.sessionID, generation: generation)
            }
            guard mayExecute() else { return }
            self.sidebarDequeueRecheckHook?()
            self.forwardLock.withCodexRuntimeSyncerLock {
                guard mayExecute() else { return }
                self.handleSidebarEventOnQueue(event, record: record)
            }
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
            guard promptNotificationDeduper.markResolved(event,
                                                         sessionID: record.sessionID) == .clearedNotified else {
                return
            }
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

    private func sendSidebarOnQueue(messages: [String], sessionID: String) {
        for message in messages {
            do {
                try sidebarMessageSender(message)
            } catch {
                BridgeLogger.server.error("codex app-server sidebar message failed session_id=\(sessionID, privacy: .public) message=\(message, privacy: .public) error=\(String(describing: error), privacy: .public)")
            }
        }
    }

    private func leaveGenerationTransition(sessionID: String) {
        let group = lock.withCodexRuntimeSyncerLock { () -> DispatchGroup? in
            guard let depth = transitionDepthBySessionID[sessionID] else {
                return nil
            }
            if depth <= 1 {
                transitionDepthBySessionID.removeValue(forKey: sessionID)
            } else {
                transitionDepthBySessionID[sessionID] = depth - 1
            }
            return transitionGroupsBySessionID[sessionID]
        }
        group?.leave()
    }

    private enum TransitionWaitOutcome {
        case noTransition
        case completed
        case timedOut
    }

    private func awaitGenerationTransition(sessionID: String?) -> TransitionWaitOutcome {
        guard let sessionID else {
            return .noTransition
        }
        let group = lock.withCodexRuntimeSyncerLock { () -> DispatchGroup? in
            guard (transitionDepthBySessionID[sessionID] ?? 0) > 0 else {
                return nil
            }
            return transitionGroupsBySessionID[sessionID]
        }
        guard let group else {
            return .noTransition
        }
        transitionWaitHook?(sessionID)
        switch group.wait(timeout: .now() + transitionWaitTimeout) {
        case .success:
            return .completed
        case .timedOut:
            return .timedOut
        }
    }

    private func requireTransitionSettled(_ outcome: TransitionWaitOutcome) throws {
        if case .timedOut = outcome {
            throw BridgeInternalError.conflict("Codex runtime generation transition did not complete in time; retry.")
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
    private enum Mode {
        case staging
        case committing
        case committed
        case discarded
    }

    private let lock = NSLock()
    private var mode = Mode.staging
    private var buffered = [() -> Void]()
    var commitDrainHook: (() -> Void)?

    func run(_ work: @escaping () -> Void) {
        lock.lock()
        switch mode {
        case .staging, .committing:
            buffered.append(work)
            lock.unlock()
        case .committed:
            lock.unlock()
            work()
        case .discarded:
            lock.unlock()
        }
    }

    func commit() {
        lock.lock()
        guard mode == .staging else {
            lock.unlock()
            return
        }
        mode = .committing
        while buffered.isEmpty == false {
            let next = buffered.removeFirst()
            lock.unlock()
            commitDrainHook?()
            next()
            lock.lock()
        }
        mode = .committed
        lock.unlock()
    }

    func discard() {
        lock.lock()
        mode = .discarded
        buffered = []
        lock.unlock()
    }
}

private extension NSLock {
    func withCodexRuntimeSyncerLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}

private extension NSRecursiveLock {
    func withCodexRuntimeSyncerLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
