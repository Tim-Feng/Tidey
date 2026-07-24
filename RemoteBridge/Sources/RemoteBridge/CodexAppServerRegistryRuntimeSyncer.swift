import Foundation

protocol CodexAppServerApprovalSubmitting: AnyObject {
    func submitApproval(promptID: String,
                        targetIndex: Int,
                        clientRequestID: String?,
                        lifecycleToken: String?) throws -> CodexAppServerApprovalSubmitOutcome
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
                        clientRequestID: String?,
                        lifecycleToken: String?,
                        workspaceID: String,
                        panelID: String,
                        sessionID: String?) throws -> CodexAppServerApprovalSubmitOutcome {
        try submitApproval(promptID: promptID,
                           targetIndex: targetIndex,
                           clientRequestID: clientRequestID,
                           lifecycleToken: lifecycleToken)
    }

    // Answers-map submit for `item/tool/requestUserInput` cards. Default
    // implementation fails closed for conformers without a Codex runtime.
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
    func submitApproval(promptID: String,
                        targetIndex: Int,
                        clientRequestID: String?,
                        lifecycleToken: String?) throws -> CodexAppServerApprovalSubmitOutcome
    func submitUserInput(promptID: String,
                         answers: [String: [String]],
                         clientRequestID: String?,
                         lifecycleToken: String?) throws -> CodexAppServerApprovalSubmitOutcome
    func submitMessage(text: String, clientRequestID: String?) throws
    func stop()
}

extension CodexAppServerRuntimeSessionControlling {
    // Back-compat default for test doubles predating requestUserInput; the
    // real runtime session forwards to its connection.
    func submitUserInput(promptID: String,
                         answers: [String: [String]],
                         clientRequestID: String?,
                         lifecycleToken: String?) throws -> CodexAppServerApprovalSubmitOutcome {
        throw BridgeInternalError.notFound("Unknown Codex approval prompt.")
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
        // Identity of this attach generation. Late callbacks and in-flight
        // submits from a replaced (retired) generation must be ignored so
        // they cannot mask or overwrite the current generation's state.
        let generation: UUID
        // LAST-KNOWN-GOOD effective registry root: a record whose root field
        // momentarily goes blank must not reset the replacement identity —
        // B -> blank -> B never rebuilds; A -> blank -> B still does.
        let effectiveRootThreadID: String?
    }

    private let eventHub: AgentEventHub
    private let sidebarMessageSender: SidebarMessageSender
    private let sidebarQueue: DispatchQueue
    private let timestampProvider: CodexAppServerConnection.TimestampProvider
    private let dateProvider: DateProvider
    private let activeThreadRefreshInterval: TimeInterval
    private let attachHandler: AttachHandler
    private let promptNotificationDeduper = AgentInteractivePromptNotificationDeduper()
    private let lock = NSLock()
    private var entriesBySessionID = [String: RuntimeEntry]()
    // The generation is registered here BEFORE the attach handler runs so a
    // runtime that reports callbacks synchronously during attach is already
    // "current"; replacement installs the new generation first, making every
    // late callback from the old one stale.
    private var currentGenerationBySessionID = [String: UUID]()
    // Generations being torn down: their stop()-driven terminal cleanup may
    // still publish resolved events, but nothing else. Membership is removed
    // once stop() returned.
    private var retiringGenerations = Set<UUID>()
    // In-progress generation transitions (entry gap between old-entry removal
    // and new-attach commit). Submits observing stale evidence wait here —
    // bounded — instead of treating the gap as "no runtime".
    private var transitionGroupsBySessionID = [String: DispatchGroup]()
    private var transitionDepthBySessionID = [String: Int]()
    private let transitionWaitTimeout: TimeInterval
    // Serializes whole sync passes (see the sync() concurrency contract).
    private let syncSerialLock = NSLock()
    // Serializes [generation check + side-effect commit] against generation
    // transitions (install/retire), closing the check-then-act window.
    private let forwardLock = NSRecursiveLock()
    private var lastAssistantTextBySessionID = [String: String]()
    private var nextActiveThreadRefreshAtBySessionID = [String: Date]()
    var activeThreadHandler: ActiveThreadHandler?
    // Test-only: fires after a callback passed its initial generation check
    // but before the check-and-commit critical section, so tests can complete
    // a replacement in that window.
    var generationRecheckHook: (() -> Void)?
    // Test-only: fires when a submit decided to wait for an in-progress
    // generation transition (entry gap) before reconciling.
    var transitionWaitHook: ((String) -> Void)?
    // Test-only: fires after a dequeued sidebar work item passed its initial
    // generation check but before the locked recheck + send.
    var sidebarDequeueRecheckHook: (() -> Void)?
    // Test-only: fires when a caller ARRIVES at sync() (before the internal
    // serialization), so tests can prove a concurrent sync waited.
    var syncArrivalHook: (([AgentSessionRegistryRecord]) -> Void)?
    // Test-only: observes each attach's staging transaction.
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
        self.transitionWaitTimeout = transitionWaitTimeout
        self.sidebarQueue = sidebarQueue
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
                                          epoch: CodexAppServerRegistryRuntimeSyncer.appServerEpoch(record: record),
                                          nextSequence: nextSequence,
                                          timestampProvider: timestampProvider,
                                          onAgentEvent: onAgentEvent,
                                          onInteractivePrompt: onInteractivePrompt,
                                          onInteractivePromptResolved: onInteractivePromptResolved,
                                          onActiveThreadID: onActiveThreadID)
            }
        }
    }

    // Concurrency contract: sync passes are serialized INSIDE the syncer.
    // Interleaved syncs would otherwise split entry vs current-generation
    // state (a stale attach result overwriting a newer generation's entry).
    // The caller's queue is not relied upon.
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
            // The generation moves to `retiring` BEFORE stop() runs: the
            // stop()-driven expired terminals must still flow to the hub.
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
            // A session whose transport died must not be reused forever: the
            // app-server (same epoch) may still be alive, so re-attach and
            // let it replay its pending requests.
            if existing.session.isStopped() {
                return true
            }
            if existing.record.appServerSocket != record.appServerSocket ||
                existing.record.appServerPID != record.appServerPID ||
                existing.record.workspaceID != record.workspaceID ||
                existing.record.panelID != record.panelID {
                return true
            }
            // Codex 0.144.1 thread/resume ADDS the connection to the thread;
            // there is no unsubscribe. Resuming B on a connection that already
            // subscribed A would keep delivering A's approvals into this
            // session. A CHANGED effective root therefore replaces the whole
            // runtime generation. A root that merely disappears (blank) keeps
            // the reuse — fail closed on registry hiccups.
            if let newRoot = Self.registryRootThreadID(from: record),
               newRoot != existing.effectiveRootThreadID {
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
        // The retiring tokens are removed ON the sidebar queue, BEHIND any
        // terminal cleanup the stop() calls enqueued: the cleanup thus always
        // finds its generation still retiring and completes. Per-session maps
        // are cleaned immediately; deduper state for replaced sessions is
        // per-lifecycle-token, so the new generation is unaffected.
        let retiredEntries = staleEntries + replacedEntries
        forwardLock.withCodexRuntimeSyncerLock {
            lock.withCodexRuntimeSyncerLock {
                for entry in retiredEntries {
                    lastAssistantTextBySessionID.removeValue(forKey: entry.record.sessionID)
                    nextActiveThreadRefreshAtBySessionID.removeValue(forKey: entry.record.sessionID)
                }
            }
        }
        if retiredEntries.isEmpty == false {
            sidebarQueue.async { [weak self] in
                guard let self else {
                    return
                }
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
                    entriesBySessionID[record.sessionID] = RuntimeEntry(record: record,
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
        // A reused record's effective root is by construction UNCHANGED (a
        // changed root goes through generation replacement above), so there
        // is no in-place root update here.
        for (session, shouldRefresh) in reusedSessions {
            session.ensureThreadSubscription()
            if shouldRefresh {
                session.refreshActiveThread()
            }
        }
    }

    func submitApproval(promptID: String,
                        targetIndex: Int,
                        clientRequestID: String?,
                        lifecycleToken: String?) throws -> CodexAppServerApprovalSubmitOutcome {
        try convertingTransitionTimeout {
            try performPromptSubmit(promptID: promptID,
                                    lifecycleToken: lifecycleToken,
                                    workspaceID: nil,
                                    panelID: nil,
                                    sessionID: nil) { session in
                try session.submitApproval(promptID: promptID,
                                           targetIndex: targetIndex,
                                           clientRequestID: clientRequestID,
                                           lifecycleToken: lifecycleToken)
            }
        }
    }

    func submitApproval(promptID: String,
                        targetIndex: Int,
                        clientRequestID: String?,
                        lifecycleToken: String?,
                        workspaceID: String,
                        panelID: String,
                        sessionID: String?) throws -> CodexAppServerApprovalSubmitOutcome {
        try convertingTransitionTimeout {
            try performPromptSubmit(promptID: promptID,
                                    lifecycleToken: lifecycleToken,
                                    workspaceID: Optional(workspaceID),
                                    panelID: Optional(panelID),
                                    sessionID: sessionID) { session in
                try session.submitApproval(promptID: promptID,
                                           targetIndex: targetIndex,
                                           clientRequestID: clientRequestID,
                                           lifecycleToken: lifecycleToken)
            }
        }
    }

    func submitUserInput(promptID: String,
                         answers: [String: [String]],
                         clientRequestID: String?,
                         lifecycleToken: String?,
                         workspaceID: String,
                         panelID: String,
                         sessionID: String?) throws -> CodexAppServerApprovalSubmitOutcome {
        try convertingTransitionTimeout {
            try performPromptSubmit(promptID: promptID,
                                    lifecycleToken: lifecycleToken,
                                    workspaceID: Optional(workspaceID),
                                    panelID: Optional(panelID),
                                    sessionID: sessionID) { session in
                try session.submitUserInput(promptID: promptID,
                                            answers: answers,
                                            clientRequestID: clientRequestID,
                                            lifecycleToken: lifecycleToken)
            }
        }
    }

    private func convertingTransitionTimeout<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch is GenerationTransitionTimedOut {
            throw BridgeInternalError.conflict("Codex runtime generation transition did not complete in time; retry.")
        }
    }

    private func performPromptSubmit(promptID: String,
                                     lifecycleToken: String?,
                                     workspaceID: String?,
                                     panelID: String?,
                                     sessionID: String?,
                                     generationRetriesRemaining: Int = 1,
                                     using submit: (CodexAppServerRuntimeSessionControlling) throws -> CodexAppServerApprovalSubmitOutcome) throws -> CodexAppServerApprovalSubmitOutcome {
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
            return entries.filter { entry in
                if let workspaceID, entry.record.workspaceID != workspaceID {
                    return false
                }
                if let panelID, let recordPanelID = entry.record.panelID, recordPanelID != panelID {
                    return false
                }
                return true
            }.map { (sessionID: $0.record.sessionID, session: $0.session, generation: $0.generation) }
        }
        var lastError: Error?
        for candidate in candidates {
            do {
                let outcome = try submit(candidate.session)
                // The result is only trustworthy if this session is still the
                // current generation: a session replaced mid-submit may
                // answer with a stale terminal (e.g. expired) that must not
                // mask the replayed prompt on the new generation.
                let stillCurrent = lock.withCodexRuntimeSyncerLock {
                    entriesBySessionID[candidate.sessionID]?.generation == candidate.generation
                }
                if stillCurrent {
                    return outcome
                }
                guard generationRetriesRemaining > 0 else {
                    throw BridgeInternalError.conflict("Codex runtime was replaced during approval submit; retry.")
                }
                try requireTransitionSettled(awaitGenerationTransition(sessionID: candidate.sessionID))
                return try performPromptSubmit(promptID: promptID,
                                               lifecycleToken: lifecycleToken,
                                               workspaceID: workspaceID,
                                               panelID: panelID,
                                               sessionID: sessionID,
                                               generationRetriesRemaining: generationRetriesRemaining - 1,
                                               using: submit)
            } catch BridgeInternalError.notFound {
                // A replaced runtime answering notFound is stale evidence: the
                // new generation may hold the (re-delivered) prompt.
                let stillCurrent = lock.withCodexRuntimeSyncerLock {
                    entriesBySessionID[candidate.sessionID]?.generation == candidate.generation
                }
                if stillCurrent == false, generationRetriesRemaining > 0 {
                    try requireTransitionSettled(awaitGenerationTransition(sessionID: candidate.sessionID))
                    return try performPromptSubmit(promptID: promptID,
                                                   lifecycleToken: lifecycleToken,
                                                   workspaceID: workspaceID,
                                                   panelID: panelID,
                                                   sessionID: sessionID,
                                                   generationRetriesRemaining: generationRetriesRemaining - 1,
                                                   using: submit)
                }
                continue
            } catch {
                // A transition timeout is NOT candidate evidence: it must
                // pass through untouched and fail the submit closed.
                if error is GenerationTransitionTimedOut {
                    throw error
                }
                // Same for hard errors (e.g. closed): a stale generation's
                // error must not be surfaced when the current generation can
                // answer.
                let stillCurrent = lock.withCodexRuntimeSyncerLock {
                    entriesBySessionID[candidate.sessionID]?.generation == candidate.generation
                }
                if stillCurrent == false, generationRetriesRemaining > 0 {
                    try requireTransitionSettled(awaitGenerationTransition(sessionID: candidate.sessionID))
                    return try performPromptSubmit(promptID: promptID,
                                                   lifecycleToken: lifecycleToken,
                                                   workspaceID: workspaceID,
                                                   panelID: panelID,
                                                   sessionID: sessionID,
                                                   generationRetriesRemaining: generationRetriesRemaining - 1,
                                                   using: submit)
                }
                lastError = error
            }
        }
        if let lastError {
            throw lastError
        }
        // Empty candidates during an in-progress transition is the entry gap,
        // not an authoritative "no runtime": wait for the commit and retry.
        if candidates.isEmpty, let sessionID, generationRetriesRemaining > 0,
           lock.withCodexRuntimeSyncerLock({ (transitionDepthBySessionID[sessionID] ?? 0) > 0 }) {
            try requireTransitionSettled(awaitGenerationTransition(sessionID: sessionID))
            return try performPromptSubmit(promptID: promptID,
                                           lifecycleToken: lifecycleToken,
                                           workspaceID: workspaceID,
                                           panelID: panelID,
                                           sessionID: sessionID,
                                           generationRetriesRemaining: generationRetriesRemaining - 1,
                                           using: submit)
        }
        // Only an exact terminal record for the same prompt identity may
        // answer idempotently. Prompt ids embed the app-server epoch, so a
        // restarted process can never match records from the previous run.
        // If a newer delivery attempt of the same request is active in the
        // hub (prompt event after the last resolved), the old terminal must
        // not answer for it.
        if let workspaceID,
           let sessionID,
           let resolvedEvent = eventHub.latestInteractivePromptResolvedEvent(workspaceID: workspaceID,
                                                                             sessionID: sessionID,
                                                                             promptID: promptID,
                                                                             lifecycleToken: lifecycleToken,
                                                                             openerRequiresCapability: true) {
            if eventHub.activeInteractivePrompt(workspaceID: workspaceID,
                                                sessionID: sessionID,
                                                promptID: promptID) != nil {
                throw BridgeInternalError.notFound("Unknown Codex approval prompt.")
            }
            return .alreadyResolved(resolvedEvent)
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

    func submitMessage(sessionID: String, text: String, clientRequestID: String?) throws {
        let session = lock.withCodexRuntimeSyncerLock {
            entriesBySessionID[sessionID]?.session
        }
        guard let session else {
            // No registry entry for this session at all — strictly before
            // any turn/start or turn/steer request frame could ever be
            // built. Zero effect by construction.
            throw CodexAppServerSubmitFailure.unavailableBeforeSend("Unknown Codex app-server session.")
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
            if let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
               trimmed.isEmpty == false {
                return trimmed
            }
        }
        return nil
    }

    private func attach(record: AgentSessionRegistryRecord) {
        let generation = UUID()
        // Install the generation BEFORE the attach handler runs: a runtime
        // that reports its first thread/events synchronously during attach is
        // legitimate and must not be dropped as stale.
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
                                                // A retired generation's late prompt must not be
                                                // published to the hub.
                                                stage.run {
                                                    self?.forwardIfCurrent(sessionID: sessionID, generation: generation) {
                                                        eventHub.publish(envelope.event)
                                                        self?.handleSidebarEvent(envelope.event, record: record, generation: generation)
                                                        BridgeLogger.server.info("codex app-server approval prompt published workspace_id=\(envelope.event.workspaceID, privacy: .public) panel_id=\(envelope.event.metadata?["panel_id"] ?? "-", privacy: .public) session_id=\(envelope.event.sessionID, privacy: .public) prompt_id=\(envelope.prompt.promptID, privacy: .public)")
                                                    }
                                                }
                                            },
                                            { [weak self, eventHub, sessionID = record.sessionID, generation] event in
                                                // Terminal cleanup is also legitimate from a
                                                // RETIRING generation (stop()-driven expiry).
                                                stage.run {
                                                    self?.forwardIfCurrentOrRetiring(sessionID: sessionID, generation: generation) {
                                                        eventHub.publish(event)
                                                        self?.handleSidebarEvent(event, record: record, generation: generation)
                                                    }
                                                }
                                            },
                                            { [weak self, sessionID = record.sessionID, generation] threadID in
                                                // Retired generations must not rebind the
                                                // current registry thread state.
                                                stage.run {
                                                    self?.forwardIfCurrent(sessionID: sessionID, generation: generation) {
                                                        self?.activeThreadHandler?(sessionID, threadID)
                                                    }
                                                }
                                            })
            // The registry already knows this session's authoritative root
            // thread: hand it to the runtime as the subscription fallback for
            // the cases where thread/loaded/list cannot resolve a unique root
            // (empty, paginated, ambiguous). Prefer the resolved threadID and
            // fall back to resumeThreadID; the setter fail-closes on blanks.
            session.setRegistryRootThreadID(Self.registryRootThreadID(from: record))
            lock.withCodexRuntimeSyncerLock {
                entriesBySessionID[record.sessionID] = RuntimeEntry(record: record,
                                                                    session: session,
                                                                    generation: generation,
                                                                    effectiveRootThreadID: Self.registryRootThreadID(from: record))
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

    // Atomic [generation re-check + side-effect commit]: the recheck and the
    // publish happen under forwardLock, the same lock generation transitions
    // take, so a replacement that completed after the caller's initial check
    // invalidates the commit.
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

    private func isCurrentOrRetiringGeneration(sessionID: String, generation: UUID) -> Bool {
        lock.withCodexRuntimeSyncerLock {
            currentGenerationBySessionID[sessionID] == generation || retiringGenerations.contains(generation)
        }
    }

    private func handleSidebarEvent(_ event: AgentEvent, record: AgentSessionRegistryRecord, generation: UUID) {
        // Queued work carries its generation and is re-validated when it
        // executes. Terminal cleanup (resolved) is also legitimate from a
        // RETIRING generation — its removal is ordered BEHIND this work on
        // the same serial queue, so the cleanup always completes.
        sidebarQueue.async { [weak self] in
            guard let self else {
                return
            }
            let mayExecute: () -> Bool = {
                if event.type == .interactivePromptResolved {
                    return self.isCurrentOrRetiringGeneration(sessionID: record.sessionID, generation: generation)
                }
                return self.isCurrentGeneration(sessionID: record.sessionID, generation: generation)
            }
            guard mayExecute() else {
                return
            }
            self.sidebarDequeueRecheckHook?()
            // The recheck and the external send are atomic with generation
            // transitions: a replacement either completes before this work
            // (and the recheck drops it) or waits until the send finished.
            self.forwardLock.withCodexRuntimeSyncerLock {
                guard mayExecute() else {
                    return
                }
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
            // A terminal may only restore the running shell state when it
            // actually ended the delivery the sidebar is showing: a stale
            // terminal for a superseded lifecycle must neither clear the
            // notification gate nor flip the prompt state back to running.
            switch promptNotificationDeduper.markResolved(event, sessionID: record.sessionID) {
            case .clearedNotified:
                // Only a terminal that ACTUALLY ended the currently notified
                // delivery restores the running state — stale mismatches,
                // unknown prompts, and duplicate terminals are all zero side
                // effects (exactly-once).
                sendSidebarOnQueue(messages: AgentInteractivePromptSidebarMessages.messages(for: event,
                                                                                           workspaceID: record.workspaceID),
                                   sessionID: record.sessionID)
            case .staleMismatch, .noneNotified:
                break
            }

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

    enum TransitionWaitOutcome {
        case noTransition
        case completed
        case timedOut
    }

    // Bounded wait for an in-progress transition; a no-op when none is in
    // flight. Never a poll/sleep: the group is signalled by the transition
    // commit (or failure) itself. The outcome MUST be propagated: a timed-out
    // wait means the runtime state is still unknown and no old fallback may
    // answer.
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

    // Internal marker so a transition timeout can pass THROUGH the candidate
    // submit error handling untouched: any first `.timedOut` fails closed —
    // no retry, no second wait, no Hub fallback.
    struct GenerationTransitionTimedOut: Error {}

    private func requireTransitionSettled(_ outcome: TransitionWaitOutcome) throws {
        if case .timedOut = outcome {
            throw GenerationTransitionTimedOut()
        }
    }

    private func isCurrentGeneration(sessionID: String, generation: UUID) -> Bool {
        lock.withCodexRuntimeSyncerLock {
            currentGenerationBySessionID[sessionID] == generation
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

    // Stable identity of one app-server process instance: same process across
    // Bridge reconnects keeps its epoch, a restarted process gets a new PID
    // and therefore a new epoch.
    static func appServerEpoch(record: AgentSessionRegistryRecord) -> String {
        let pid = record.appServerPID.map(String.init) ?? "-"
        let socket = record.appServerSocket ?? "-"
        return "pid:\(pid)|sock:\(socket)"
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

private extension NSRecursiveLock {
    func withCodexRuntimeSyncerLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}


// Attach transaction staging: callbacks arriving while the attach handler is
// still running are buffered; they publish (in FIFO arrival order) only if
// the attach commits, and are discarded on failure so a failed attach leaves
// no hub/sidebar/thread side effects.
final class CodexAppServerAttachStage: @unchecked Sendable {
    private enum Mode { case staging, committing, committed, discarded }
    private let lock = NSLock()
    private var mode: Mode = .staging
    private var buffered: [() -> Void] = []

    func run(_ work: @escaping () -> Void) {
        lock.lock()
        switch mode {
        case .staging, .committing:
            // While the single drain executor is still flushing staged work,
            // new arrivals queue at the tail so FIFO arrival order holds.
            buffered.append(work)
            lock.unlock()
        case .committed:
            lock.unlock()
            work()
        case .discarded:
            lock.unlock()
        }
    }

    // Test-only: fires after an item was dequeued for execution (mode is
    // .committing, the tail may still hold undrained work), outside the lock.
    var commitDrainHook: (() -> Void)?

    func commit() {
        lock.lock()
        guard mode == .staging else {
            lock.unlock()
            return
        }
        mode = .committing
        // Single drain executor: work runs WITHOUT the stage lock (callbacks
        // may take other locks), but only this loop dequeues, and the mode
        // flips to committed only once the tail is empty.
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
