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
}

protocol CodexAppServerApprovalPromptProviding: CodexAppServerApprovalSubmitting {
    func pendingApprovalPromptEvents(workspaceID: String, sessionID: String?) -> [AgentEvent]
}

protocol CodexAppServerRuntimeSessionControlling: AnyObject {
    func ensureThreadSubscription()
    func setRegistryRootThreadID(_ rawThreadID: String?)
    func isStopped() -> Bool
    func pendingApprovalPromptEvents() -> [AgentEvent]
    func refreshActiveThread()
    func submitApproval(promptID: String,
                        targetIndex: Int,
                        clientRequestID: String?,
                        lifecycleToken: String?) throws -> CodexAppServerApprovalSubmitOutcome
    func submitMessage(text: String, clientRequestID: String?) throws
    func stop()
}

extension CodexAppServerRuntimeSession: CodexAppServerRuntimeSessionControlling {}

final class CodexAppServerRegistryRuntimeSyncer: AgentSessionRuntimeSyncing, CodexAppServerApprovalPromptProviding, CodexAppServerChatSubmitting {
    typealias SidebarMessageSender = (String) throws -> Void
    typealias DateProvider = () -> Date
    typealias ActiveThreadHandler = (_ sessionID: String, _ threadID: String) -> Void
    typealias AttachHandler = (_ record: AgentSessionRegistryRecord,
                               _ epoch: String,
                               _ nextSequence: @escaping CodexAppServerConnection.SequenceProvider,
                               _ timestampProvider: @escaping CodexAppServerConnection.TimestampProvider,
                               _ onAgentEvent: @escaping CodexAppServerHeadlessRuntime.AgentEventHandler,
                               _ onInteractivePrompt: @escaping CodexAppServerConnection.InteractivePromptHandler,
                               _ onInteractivePromptResolved: @escaping CodexAppServerConnection.InteractivePromptResolvedHandler,
                               _ onActiveThreadID: @escaping CodexAppServerHeadlessRuntime.ThreadIDHandler,
                               _ onWorkingControl: @escaping CodexAppServerHeadlessRuntime.WorkingControlHandler) throws -> CodexAppServerRuntimeSessionControlling

    // Attach-scoped, per-generation mutable Working-control owner context.
    // Reference type: mutated in place under `forwardLock` as admission
    // results come back, and the SAME instance is stored in this
    // generation's `RuntimeEntry` so every live callback re-reads current
    // state through the authoritative `entriesBySessionID` lookup rather
    // than a value captured at closure-construction time (the sole
    // exception, per spec, is `ownerDisconnected`, which uses the exact
    // captured instance directly — see `handleWorkingControlOwnerDisconnected`).
    // `nil` at the RuntimeEntry level means this generation attached with an
    // unknown (blank) authoritative root: no Hub incarnation was ever begun
    // for it, and every control observation for it must fail closed.
    private final class AppServerAttachOwnerContext {
        let epoch: String
        let rootThreadID: String
        let ownerToken: String
        // Immutable for the whole generation: a workspace/panel rebind
        // always triggers a replacement (a new generation with its own
        // context), so this can never go stale within one generation's
        // lifetime — see `recordsToAttach`'s workspaceID/panelID check.
        // Read this instead of a value captured at closure-construction
        // time so `ownerDisconnected` (the one path with no live
        // `entriesBySessionID` entry to consult once the generation is
        // retiring) still has an authoritative binding.
        let workspaceID: String
        var currentLogicalTurn: AppServerLogicalTurnKey?
        // Set exactly once, before this generation's owner is ever retired
        // in the Hub. Every live start/activity/resume after this must be
        // rejected even if the generation is still nominally "current" in
        // `entriesBySessionID` for a brief window.
        var retired = false
        // Guards `ownerDisconnected` admission to fire exactly once per
        // generation, independent of `retired` (which the disconnect path
        // itself sets).
        var disconnected = false

        init(epoch: String, rootThreadID: String, ownerToken: String, workspaceID: String) {
            self.epoch = epoch
            self.rootThreadID = rootThreadID
            self.ownerToken = ownerToken
            self.workspaceID = workspaceID
        }
    }

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
        // `nil` iff this generation attached with an unknown (blank)
        // authoritative root — no Hub control incarnation was begun, and
        // every Working-control observation for it fails closed.
        let ownerContext: AppServerAttachOwnerContext?
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
    // Test-only: fires at the very start of a live Working-control
    // observation, before the authoritative `entriesBySessionID` recheck
    // under `forwardLock` — lets a test complete a replacement in that exact
    // window to prove the LOCKED recheck itself (not merely an earlier,
    // stale-by-construction check) is what rejects a superseded generation's
    // callback.
    var workingControlObservationHook: (() -> Void)?

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
            self.attachHandler = { record, epoch, nextSequence, timestampProvider, onAgentEvent, onInteractivePrompt, onInteractivePromptResolved, onActiveThreadID, onWorkingControl in
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
                                          epoch: epoch,
                                          nextSequence: nextSequence,
                                          timestampProvider: timestampProvider,
                                          onAgentEvent: onAgentEvent,
                                          onInteractivePrompt: onInteractivePrompt,
                                          onInteractivePromptResolved: onInteractivePromptResolved,
                                          onActiveThreadID: onActiveThreadID,
                                          onWorkingControl: onWorkingControl)
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
        // false: the old, non-draining pass — no sidebarQueue.sync barrier,
        // no callback. Ordinary sync() must NEVER run the drain barrier: it
        // can be called from contexts that are already ON (or synchronously
        // blocking) sidebarQueue (e.g. a dequeued work item's own recheck,
        // or a test hook), and `sidebarQueue.sync {}` there would be a
        // reentrant self-deadlock. Only the monitor's explicit reconcile()
        // path — never invoked from sidebarQueue — may run the barrier.
        syncLockedPass(records: records, runsReconciliationBarrier: false, betweenRetirementAndActivation: {})
    }

    // betweenRetirementAndActivation is deliberately NON-escaping: monitor
    // correctness depends on it running synchronously exactly once, before
    // this call returns (the monitor captures/mutates its local
    // prepared-session list inside the closure, then calls finishUpdate()
    // immediately after reconcile() returns). An escaping signature would
    // let a future conformer retain and defer it, breaking that ordering.
    func reconcile(records: [AgentSessionRegistryRecord], betweenRetirementAndActivation: () -> Void) {
        syncArrivalHook?(records)
        syncSerialLock.lock()
        defer { syncSerialLock.unlock() }
        syncLockedPass(records: records, runsReconciliationBarrier: true, betweenRetirementAndActivation: betweenRetirementAndActivation)
    }

    private func syncLockedPass(records: [AgentSessionRegistryRecord],
                                runsReconciliationBarrier: Bool,
                                betweenRetirementAndActivation: () -> Void) {
        let runtimeRecords = records.filter(Self.isAttachableCodexAppServerRecord(_:))
        let activeSessionIDs = Set(runtimeRecords.map(\.sessionID))

        // Snapshot session identity + stopped state OUTSIDE forwardLock/lock.
        // Once the finish barrier lands, session.stop()'s teardown itself
        // synchronizes with an owner-disconnect callback that may need
        // forwardLock — calling session.isStopped() (which touches the
        // session's own lock) while holding forwardLock here would then risk
        // a reverse lock-order deadlock. A snapshot taken moments before this
        // pass's locked decision is no less current than any two separate
        // sync passes already are.
        let stoppedSnapshotBySessionID: [String: Bool] = lock.withCodexRuntimeSyncerLock {
            entriesBySessionID.mapValues { $0.session }
        }.mapValues { $0.isStopped() }

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
        // Bridge Phase C: whether a triggering record still identifies the
        // SAME physical app-server process as the entry it is replacing
        // (PID + socket + createdAt all unchanged). Only same-process
        // replacements (a died transport reattaching, or a pure
        // workspace/panel binding move) may carry the prior generation's
        // last-known-good effective root forward when the new record's own
        // root field is momentarily blank. A TRUE process replacement
        // (createdAt changed) with a blank root must NOT inherit the old
        // process's root — that root belongs to a different process
        // instance and must never be attributed to the new one.
        var samePhysicalProcessSessionIDs = Set<String>()
        let recordsToAttach = runtimeRecords.filter { record in
            guard let existing = entriesBySessionID[record.sessionID] else {
                return true
            }
            let samePhysicalProcess = existing.record.appServerSocket == record.appServerSocket &&
                existing.record.appServerPID == record.appServerPID &&
                existing.record.createdAt == record.createdAt
            if samePhysicalProcess {
                samePhysicalProcessSessionIDs.insert(record.sessionID)
            }
            // A session whose transport died must not be reused forever: the
            // app-server (same epoch) may still be alive, so re-attach and
            // let it replay its pending requests.
            if stoppedSnapshotBySessionID[record.sessionID] ?? false {
                return true
            }
            if existing.record.appServerSocket != record.appServerSocket ||
                existing.record.appServerPID != record.appServerPID ||
                existing.record.workspaceID != record.workspaceID ||
                existing.record.panelID != record.panelID {
                return true
            }
            // Bridge Phase C: a PID/socket tuple CAN be reused across a
            // process restart — `createdAt` changing with everything else
            // held equal is still a genuine process replacement (and must
            // drive a new `appServerEpoch`, including a true Hub
            // control-incarnation rotation), not a same-generation reuse.
            if existing.record.createdAt != record.createdAt {
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
        var priorEffectiveRootBySessionID = [String: String]()
        let replacedEntries = recordsToAttach.compactMap { record -> RuntimeEntry? in
            guard let entry = entriesBySessionID.removeValue(forKey: record.sessionID) else {
                return nil
            }
            if samePhysicalProcessSessionIDs.contains(record.sessionID),
               let priorRoot = entry.effectiveRootThreadID {
                priorEffectiveRootBySessionID[record.sessionID] = priorRoot
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

        // Barrier + callback: ONLY when a reconcile() caller asked for it. A
        // plain sync() call passes false and skips both — it must remain
        // the old, non-draining pass, since sync() can be invoked from
        // contexts already on (or synchronously blocking) sidebarQueue (a
        // dequeued work item's own recheck, a test hook), and
        // `sidebarQueue.sync {}` there would be a reentrant self-deadlock.
        if runsReconciliationBarrier {
            // Block until every item already enqueued on the sidebar queue —
            // including the retiring-token removal just enqueued above — has
            // drained. Any legitimately queued old-generation work (a
            // stop()-driven terminal) either completes before this returns,
            // or (if somehow still in flight) now fails its generation
            // recheck, since the retiring token is gone by the time this
            // barrier's own block runs (FIFO on the same serial queue). Runs
            // with NEITHER forwardLock NOR lock held: dequeued sidebar work
            // itself acquires forwardLock (see handleSidebarEvent), so
            // holding it here would deadlock this very call.
            sidebarQueue.sync {}

            // The callback (transcript prepare, THEN the caller's departed-
            // workspace cleanup, THEN new-session activation) runs wholly
            // under forwardLock. This closes the LAST epoch race: a runtime
            // generation whose record is REUSED/still current this pass
            // (e.g. only the transcript's rollout path changed — socket/
            // PID/workspace/panel/root all equal, so `recordsToAttach` never
            // touches it) can still pass forwardIfCurrent and try to publish
            // during the callback's beginNewSourceEpoch. Serializing every
            // current/reused generation's [check + Hub/sidebar commit]
            // against the callback via this SAME lock means: a commit that
            // acquires the lock BEFORE the callback is old-epoch content,
            // cleared by beginNewSourceEpoch same as any other stale write;
            // a commit that has to wait for the callback's forwardLock hold
            // to release runs AFTER the new epoch boundary and lands
            // correctly. Replaced/stale generations still fail the
            // generation recheck regardless. Must run AFTER the sidebarQueue
            // barrier above (holding forwardLock across that barrier would
            // deadlock — dequeued sidebar work itself acquires forwardLock)
            // and must be released BEFORE any new generation is attached
            // below. The callback must never call sync/reconcile
            // recursively — it would try to re-enter syncSerialLock (already
            // held by this very call) and hang.
            forwardLock.lock()
            betweenRetirementAndActivation()
            forwardLock.unlock()
        }

        let attachSessionIDs = Set(recordsToAttach.map(\.sessionID))
        for entry in staleEntries where attachSessionIDs.contains(entry.record.sessionID) == false {
            leaveGenerationTransition(sessionID: entry.record.sessionID)
        }
        for record in recordsToAttach {
            attach(record: record, priorEffectiveRoot: priorEffectiveRootBySessionID[record.sessionID])
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
                                                                            ?? entry.effectiveRootThreadID,
                                                                        ownerContext: entry.ownerContext)
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
            try submitApproval(promptID: promptID,
                               targetIndex: targetIndex,
                               clientRequestID: clientRequestID,
                               lifecycleToken: lifecycleToken,
                               workspaceID: nil,
                               panelID: nil,
                               sessionID: nil)
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
            try submitApproval(promptID: promptID,
                               targetIndex: targetIndex,
                               clientRequestID: clientRequestID,
                               lifecycleToken: lifecycleToken,
                               workspaceID: Optional(workspaceID),
                               panelID: Optional(panelID),
                               sessionID: sessionID)
        }
    }

    private func convertingTransitionTimeout<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch is GenerationTransitionTimedOut {
            throw BridgeInternalError.conflict("Codex runtime generation transition did not complete in time; retry.")
        }
    }

    private func submitApproval(promptID: String,
                                targetIndex: Int,
                                clientRequestID: String?,
                                lifecycleToken: String?,
                                workspaceID: String?,
                                panelID: String?,
                                sessionID: String?,
                                generationRetriesRemaining: Int = 1) throws -> CodexAppServerApprovalSubmitOutcome {
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
                let outcome = try candidate.session.submitApproval(promptID: promptID,
                                                                   targetIndex: targetIndex,
                                                                   clientRequestID: clientRequestID,
                                                                   lifecycleToken: lifecycleToken)
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
                return try submitApproval(promptID: promptID,
                                          targetIndex: targetIndex,
                                          clientRequestID: clientRequestID,
                                          lifecycleToken: lifecycleToken,
                                          workspaceID: workspaceID,
                                          panelID: panelID,
                                          sessionID: sessionID,
                                          generationRetriesRemaining: generationRetriesRemaining - 1)
            } catch BridgeInternalError.notFound {
                // A replaced runtime answering notFound is stale evidence: the
                // new generation may hold the (re-delivered) prompt.
                let stillCurrent = lock.withCodexRuntimeSyncerLock {
                    entriesBySessionID[candidate.sessionID]?.generation == candidate.generation
                }
                if stillCurrent == false, generationRetriesRemaining > 0 {
                    try requireTransitionSettled(awaitGenerationTransition(sessionID: candidate.sessionID))
                    return try submitApproval(promptID: promptID,
                                              targetIndex: targetIndex,
                                              clientRequestID: clientRequestID,
                                              lifecycleToken: lifecycleToken,
                                              workspaceID: workspaceID,
                                              panelID: panelID,
                                              sessionID: sessionID,
                                              generationRetriesRemaining: generationRetriesRemaining - 1)
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
                    return try submitApproval(promptID: promptID,
                                              targetIndex: targetIndex,
                                              clientRequestID: clientRequestID,
                                              lifecycleToken: lifecycleToken,
                                              workspaceID: workspaceID,
                                              panelID: panelID,
                                              sessionID: sessionID,
                                              generationRetriesRemaining: generationRetriesRemaining - 1)
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
            return try submitApproval(promptID: promptID,
                                      targetIndex: targetIndex,
                                      clientRequestID: clientRequestID,
                                      lifecycleToken: lifecycleToken,
                                      workspaceID: workspaceID,
                                      panelID: panelID,
                                      sessionID: sessionID,
                                      generationRetriesRemaining: generationRetriesRemaining - 1)
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

    static func registryRootThreadID(from record: AgentSessionRegistryRecord) -> String? {
        for candidate in [record.threadID, record.resumeThreadID] {
            if let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
               trimmed.isEmpty == false {
                return trimmed
            }
        }
        return nil
    }

    private func attach(record: AgentSessionRegistryRecord, priorEffectiveRoot: String?) {
        let generation = UUID()
        // Last-known-good effective root: a record whose root field is
        // momentarily blank must not collapse the epoch to "-" and thereby
        // masquerade as a different process instance than the one just
        // retired/reused. See `RuntimeEntry.effectiveRootThreadID`.
        let effectiveRoot = Self.registryRootThreadID(from: record) ?? priorEffectiveRoot
        let epoch = Self.appServerEpoch(record: record, effectiveRoot: effectiveRoot)
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
        // Bridge Phase C: this generation's Working-control owner context.
        // `nil` iff the authoritative root is still unknown (blank, no
        // last-known-good) — such an attach is provisional (thread
        // discovery / approval transport may still legitimately proceed on
        // its ordinary paths) but is NEVER a control incarnation: no Hub
        // `beginAppServerControlIncarnation` is staged for it, and every
        // control observation it produces fails closed until a later
        // replacement attaches with a genuine nonblank root.
        let trimmedRoot = effectiveRoot?.trimmingCharacters(in: .whitespacesAndNewlines)
        let ownerContext: AppServerAttachOwnerContext?
        if let trimmedRoot, trimmedRoot.isEmpty == false {
            ownerContext = AppServerAttachOwnerContext(epoch: epoch, rootThreadID: trimmedRoot, ownerToken: UUID().uuidString, workspaceID: record.workspaceID)
            // `beginAppServerControlIncarnation` must be the FIRST committed
            // operation in this attach stage — staged here, before any
            // other working-control callback can possibly be staged, so a
            // synchronous notification firing during `attachHandler` below
            // still queues its own `stage.run` behind this one.
            stage.run { [eventHub, sessionID = record.sessionID, epoch, root = trimmedRoot] in
                eventHub.beginAppServerControlIncarnation(sessionID: sessionID, epoch: epoch, rootThreadID: root)
            }
        } else {
            ownerContext = nil
        }
        do {
            let session = try attachHandler(record,
                                            epoch,
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
                                            },
                                            { [weak self, sessionID = record.sessionID, generation, ownerContext] control in
                                                stage.run {
                                                    guard let self else {
                                                        return
                                                    }
                                                    switch control {
                                                    case let .ownerDisconnected(reason, time):
                                                        // The sole exception to the "re-read
                                                        // entriesBySessionID" rule: this uses the
                                                        // exact captured generation's owner
                                                        // context (including its immutable
                                                        // workspaceID), so it still fires for a
                                                        // generation already removed from
                                                        // entriesBySessionID by a replacement.
                                                        self.handleWorkingControlOwnerDisconnected(ownerContext,
                                                                                                    reason: reason,
                                                                                                    time: time,
                                                                                                    sessionID: sessionID,
                                                                                                    generation: generation)
                                                    default:
                                                        // workspaceID is intentionally NOT
                                                        // captured here — it is read fresh from
                                                        // the authoritative entry inside this
                                                        // call, never from the record bound at
                                                        // attach-closure-construction time.
                                                        self.handleLiveWorkingControlObservation(control,
                                                                                                  sessionID: sessionID,
                                                                                                  generation: generation)
                                                    }
                                                }
                                            })
            // Hand the runtime the SAME authoritative root this generation's
            // control identity (epoch/owner/begin) was computed from —
            // `effectiveRoot`, not a fresh raw read of the record. For a
            // same-physical-process reattach whose registry root is
            // momentarily blank, `effectiveRoot` already carries forward
            // the prior generation's last-known-good root (see above);
            // passing the raw `record` read here instead would silently
            // drop that LKG root at the RuntimeSession level even though
            // control identity still uses it — if thread/loaded/list then
            // comes back empty/ambiguous, the runtime would have no
            // fallback to resume the correct thread. The setter fail-closes
            // on blanks regardless (a true-replacement generation with an
            // unknown root correctly receives nil here too).
            session.setRegistryRootThreadID(effectiveRoot)
            lock.withCodexRuntimeSyncerLock {
                entriesBySessionID[record.sessionID] = RuntimeEntry(record: record,
                                                                    session: session,
                                                                    generation: generation,
                                                                    effectiveRootThreadID: effectiveRoot,
                                                                    ownerContext: ownerContext)
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

    // Live start/activity/resume/(semantic-terminal) control observation.
    // This re-reads the authoritative `entriesBySessionID[sessionID]` under
    // THIS SAME `forwardLock` transaction rather than trusting only the
    // generation captured at closure-construction time — a replacement's
    // own `entriesBySessionID.removeValue` also runs under `forwardLock`
    // (see `syncLockedPass`), so this lookup is fully serialized against it:
    // a late observation from a superseded generation either finds the
    // entry already gone, or a mismatched generation, and is rejected.
    // `workspaceID` is deliberately NOT a parameter — it is always read
    // fresh from this same authoritative entry, never from a value captured
    // at attach-closure-construction time.
    private func handleLiveWorkingControlObservation(_ observation: CodexAppServerWorkingControlEvent,
                                                      sessionID: String,
                                                      generation: UUID) {
        guard let (rawThreadID, rawTurnID) = Self.liveObservationIdentity(from: observation) else {
            return
        }
        workingControlObservationHook?()
        let isSemanticTerminal: Bool
        if case .turnTerminal = observation {
            isSemanticTerminal = true
        } else {
            isSemanticTerminal = false
        }
        forwardLock.withCodexRuntimeSyncerLock {
            let resolved: (ownerContext: AppServerAttachOwnerContext, workspaceID: String)? = lock.withCodexRuntimeSyncerLock {
                // Defense-in-depth redundant with the entry lookup below:
                // both authoritative generation pointers must agree this is
                // still the current generation.
                guard currentGenerationBySessionID[sessionID] == generation,
                      let entry = entriesBySessionID[sessionID],
                      entry.generation == generation,
                      let ownerContext = entry.ownerContext else {
                    return nil
                }
                // The owner context must still describe exactly the
                // incarnation its OWN authoritative entry would compute
                // right now — never trust a context that could have
                // drifted from the entry it was minted alongside.
                let canonicalEpoch = Self.appServerEpoch(record: entry.record, effectiveRoot: entry.effectiveRootThreadID)
                guard canonicalEpoch == ownerContext.epoch,
                      entry.effectiveRootThreadID == ownerContext.rootThreadID else {
                    return nil
                }
                return (ownerContext, entry.record.workspaceID)
            }
            // `resolved == nil` covers "this generation was never a control
            // incarnation" (unknown root at attach time), "this generation
            // is no longer current", and "the context has drifted from its
            // own entry" — all fail closed identically.
            guard let (ownerContext, workspaceID) = resolved else {
                return
            }
            // `retired` rejects every kind EXCEPT a semantic terminal: an
            // owner disconnect must not block its OWN turn's tombstone-first
            // terminal admission (which may legitimately arrive after the
            // owner already disconnected) — only start/activity/resume are
            // gated on the owner still being live.
            guard isSemanticTerminal || ownerContext.retired == false else {
                return
            }
            // Raw identity fence: the observation's own thread must be the
            // EXACT authoritative root for this attach — a child/subagent
            // thread or any mismatch fails closed rather than being treated
            // as this turn's root.
            let threadID = rawThreadID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard threadID.isEmpty == false, threadID == ownerContext.rootThreadID else {
                return
            }
            let turnID = rawTurnID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard turnID.isEmpty == false else {
                return
            }
            let logical = AppServerLogicalTurnKey(sessionID: sessionID,
                                                  epoch: ownerContext.epoch,
                                                  rootThreadID: ownerContext.rootThreadID,
                                                  turnID: turnID)
            let ownerKey = AppServerOwnerKey(logical: logical,
                                             runtimeGeneration: generation.uuidString,
                                             ownerToken: ownerContext.ownerToken)
            let admission = eventHub.admitAppServerWorkingControl(logical: logical,
                                                                   ownerKey: ownerKey,
                                                                   workspaceID: workspaceID,
                                                                   observation: observation)
            // Only `ownerContextEffect` drives the mapping update — NEVER
            // `admission.events.isEmpty` or `admission.accepted` alone (an
            // accepted-but-zero-wire admission, e.g. an idempotent add-owner
            // or a prompt-hidden open, still must `.setOwner`).
            switch admission.ownerContextEffect {
            case .setOwner(let key):
                ownerContext.currentLogicalTurn = key.logical
            case .clearIfMatching(let key):
                // Only clears the caller's OWN mapping if it still points at
                // this EXACT logical turn — a late terminal for an old turn
                // must never clear a newer turn's mapping.
                if ownerContext.currentLogicalTurn == key {
                    ownerContext.currentLogicalTurn = nil
                }
            case .none:
                break
            }
            // `admitAppServerWorkingControl` already stores every returned
            // event, schedules its delivery, and fires the postStore hook —
            // publishing `admission.events` again here would double-deliver.
            // The Syncer only ever consumes the typed admission effect.
        }
    }

    // Defense-in-depth re-validation at the Syncer's own boundary: the
    // Headless factory already refuses to construct an observation with any
    // blank required ID, but this re-checks every field this method itself
    // depends on (per observation kind) rather than assuming that upstream
    // guarantee always holds.
    private static func liveObservationIdentity(from observation: CodexAppServerWorkingControlEvent) -> (threadID: String, turnID: String)? {
        switch observation {
        case let .turnStarted(threadID, turnID, _):
            guard isNonBlank(threadID), isNonBlank(turnID) else {
                return nil
            }
            return (threadID, turnID)
        case let .internalActivityStarted(threadID, turnID, itemID, _, _):
            guard isNonBlank(threadID), isNonBlank(turnID), isNonBlank(itemID) else {
                return nil
            }
            return (threadID, turnID)
        case let .internalActivityObserved(threadID, turnID, itemID, _, _):
            guard isNonBlank(threadID), isNonBlank(turnID), isNonBlank(itemID) else {
                return nil
            }
            return (threadID, turnID)
        case let .turnTerminal(threadID, turnID, rawStatus, _):
            guard isNonBlank(threadID), isNonBlank(turnID), isNonBlank(rawStatus) else {
                return nil
            }
            return (threadID, turnID)
        case let .resumeSnapshot(threadID, turnID, _):
            guard isNonBlank(threadID), isNonBlank(turnID) else {
                return nil
            }
            return (threadID, turnID)
        case .ownerDisconnected:
            return nil
        }
    }

    private static func isNonBlank(_ value: String) -> Bool {
        value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    // `ownerDisconnected` is the sole Working-control callback that uses the
    // EXACT captured generation's owner context (including its immutable
    // `workspaceID`) rather than re-reading `entriesBySessionID` — it must
    // still fire for a generation already removed from `entriesBySessionID`
    // by a replacement. Still generation-fenced: only a CURRENT or RETIRING
    // generation may admit (a fully-retired generation's stray late
    // callback, or one from an attach whose stage was discarded, is 0).
    // Idempotent: marks `retired = true` first (even if the mapping is
    // already nil), THEN retires only the mapping's captured exact owner
    // and clears it — never touches a replacement generation's own mapping,
    // since that lives in a DIFFERENT `AppServerAttachOwnerContext`
    // instance entirely.
    private func handleWorkingControlOwnerDisconnected(_ ownerContext: AppServerAttachOwnerContext?,
                                                        reason: CodexAppServerOwnerDisconnectReason,
                                                        time: String,
                                                        sessionID: String,
                                                        generation: UUID) {
        guard let ownerContext else {
            return
        }
        forwardLock.withCodexRuntimeSyncerLock {
            guard isCurrentOrRetiringGeneration(sessionID: sessionID, generation: generation) else {
                return
            }
            guard ownerContext.disconnected == false else {
                return
            }
            ownerContext.disconnected = true
            ownerContext.retired = true
            guard let logical = ownerContext.currentLogicalTurn else {
                return
            }
            let ownerKey = AppServerOwnerKey(logical: logical,
                                             runtimeGeneration: generation.uuidString,
                                             ownerToken: ownerContext.ownerToken)
            ownerContext.currentLogicalTurn = nil
            // `retireAppServerOwner` already stores + schedules delivery +
            // fires the postStore hook for the event it returns — no
            // separate `eventHub.publish` here.
            _ = eventHub.retireAppServerOwner(ownerKey, workspaceID: ownerContext.workspaceID, reason: reason, time: time)
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

    // Stable identity of one app-server PROCESS INSTANCE. Used both to scope
    // approval-prompt IDs (`CodexAppServerApprovalContext.epoch`,
    // `CodexAppServerApprovalRequest.promptID(epoch:)`) and to drive Hub
    // Working-control incarnation rotation
    // (`AgentEventHub.beginAppServerControlIncarnation`) — a SINGLE canonical
    // helper, deliberately not split in two: PID/socket alone are not enough
    // (the OS can reuse a PID, and a restarted app-server can reuse the same
    // socket path), so `createdAt` (the registry's own record-creation
    // timestamp) is required to distinguish a genuine process restart from a
    // mere re-read of an unchanged record. The authoritative effective root
    // is included too — a thread/turn/item ID collision across two
    // generations that share PID+socket+createdAt but resolved to a
    // different root must still mint a different epoch. Deliberately
    // excludes workspace/panel — a pure `migrateSession` binding change must
    // never masquerade as a process rotation. `effectiveRoot` is the
    // caller's already-resolved last-known-good root; `nil`/blank is a
    // LEGAL input here — a true process replacement whose root is still
    // unknown correctly computes an epoch ending in `|root:-` (see the
    // epoch/LKG matrix test's row E). This helper does NOT itself fail
    // closed on a blank root — the fail-closed behavior lives entirely at
    // the CALL SITE (`attach(record:)`): an unknown-root generation simply
    // never constructs an `AppServerAttachOwnerContext` and never stages
    // `beginAppServerControlIncarnation`, so this epoch string, even
    // though it's a well-formed value, is never actually used to begin a
    // Hub incarnation.
    static func appServerEpoch(record: AgentSessionRegistryRecord, effectiveRoot: String?) -> String {
        let pid = record.appServerPID.map(String.init) ?? "-"
        let socket = record.appServerSocket ?? "-"
        let trimmedRoot = effectiveRoot?.trimmingCharacters(in: .whitespacesAndNewlines)
        let root = (trimmedRoot?.isEmpty == false) ? trimmedRoot! : "-"
        return "pid:\(pid)|sock:\(socket)|created:\(record.createdAt)|root:\(root)"
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
