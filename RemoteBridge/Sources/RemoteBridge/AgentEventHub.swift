import Foundation

final class AgentEventHub {
    struct SessionDebugSnapshot: Equatable {
        let sessionID: String
        let workspaceID: String?
        let bufferedEventCount: Int
        let oldestSeq: Int?
        let newestSeq: Int?
        let isActive: Bool
    }

    struct FetchResult {
        let events: [AgentEvent]
        let oldestSeq: Int
        let newestSeq: Int
        let hasMore: Bool
    }

    // Per-subscriber cancellation gate: once cancel() RETURNED, no further
    // invocation of this subscriber's sink may START (even if a drain already
    // resolved the sink to a local). A sink unsubscribing ITSELF must not
    // deadlock: cancel() only waits for an in-flight invocation on another
    // thread.
    final class SubscriberGate: @unchecked Sendable {
        private let condition = NSCondition()
        private var cancelled = false
        private var invokingThread: Thread?

        func beginInvoke() -> Bool {
            condition.lock()
            defer { condition.unlock() }
            guard cancelled == false else {
                return false
            }
            invokingThread = Thread.current
            return true
        }

        func endInvoke() {
            condition.lock()
            invokingThread = nil
            condition.broadcast()
            condition.unlock()
        }

        func cancel(waitHook: (() -> Void)? = nil) {
            condition.lock()
            cancelled = true
            var signalledWait = false
            while let thread = invokingThread, thread !== Thread.current {
                if signalledWait == false {
                    signalledWait = true
                    // Test-only observation: cancel() ARRIVED at its wait
                    // window (an invocation is in flight on another thread)
                    // and has NOT returned yet.
                    waitHook?()
                }
                condition.wait()
            }
            condition.unlock()
        }
    }

    private struct Subscriber {
        let workspaceID: String?
        let sessionID: String?
        let sink: (AgentEventEnvelope) -> Void
        let gate = SubscriberGate()
    }

    private struct SessionState {
        var seenEventIDs = Set<String>()
        // Live-forward window: capacity trims only evict within this class.
        var bufferedEvents = [AgentEvent]()
        // Historical backfill storage: fills BELOW the live cursor, its own
        // capacity, never evicts live events and never live-delivers.
        var historicalEvents = [AgentEvent]()
        // Historical identity is OWNED by the replacement lifecycle (see
        // replaceHistoricalEvents): live idempotency and historical dedupe
        // are separate sets, so an evicted historical ID can never suppress
        // a later legitimate reconcile.
        var historicalEventIDs = Set<String>()
        // Single read contract for fetch/replay/queries: history + live.
        var allStoredEvents: [AgentEvent] { historicalEvents + bufferedEvents }
        var latestSessionStarted: AgentEvent?
        var isActive = false
        // Single cursor sequence authority: the high-water of every seq an
        // event was STORED under. Uniqueness alone is not enough — a late
        // unseen event with a LOWER seq is invisible to any cursor that has
        // already advanced past it, so storage is publish-monotonic: an
        // unseen event claiming a seq at or below the high-water is rebased
        // above it. nil until the session's first event, so a first low/zero
        // seq keeps its original meaning.
        var storedSeqHighWater: Int?
        // Round 7B: cross-producer Working-continuation / interactive-prompt
        // ordering. currentTurnID mirrors a producer's own active-turn
        // tracking, derived PURELY from the stored event stream (never a
        // second source of truth read from outside the state queue): set/
        // superseded by a Working anchor `.thinking` (reason task_started/
        // bootstrap_recovered_task_started) REGARDLESS of whether the anchor
        // itself was suppressed by an active prompt, cleared by ITS matching
        // terminal (`.assistantFinal` reason=turn_terminal with the SAME
        // turn_id), by `.sessionEnded`, or by beginNewSourceEpoch.
        var currentTurnID: String?
        // Round 7B: the live, independent interactive-prompt lifecycle for
        // THIS session — keyed by promptID, value is the opener event (used
        // to look up its lifecycleToken/capability for the terminalCloses
        // contract). Deliberately NOT derived by rescanning
        // bufferedEvents/historicalEvents, which trim by capacity, and
        // deliberately NOT cleared by beginNewSourceEpoch — prompt lifecycle
        // belongs to the app-server RUNTIME, which is not necessarily reset
        // alongside a rollout-path-only transcript source switch (the
        // runtime is REUSED and never re-notifies a still-pending approval
        // in that case; only a runtime-owned expiry/resolved terminal ever
        // removes an entry here). Working may resume only once this map is
        // entirely empty (requirement: multiple concurrent prompts all need
        // closing, not just one).
        var activePromptLifecycle: [String: AgentEvent] = [:]
        // Round 7B: a dedicated tombstone set for event IDs suppressed by an
        // active prompt (an anchor OR a continuation) — deliberately
        // SEPARATE from seenEventIDs, which rebuilds against bufferedEvents
        // on capacity overflow; a suppressed event is NEVER appended to
        // bufferedEvents, so it would otherwise silently fall out of that
        // rebuild and become re-acceptable on an exact retry. Cleared by
        // beginNewSourceEpoch (the transcript identity boundary) — after
        // that, the old suppressed IDs belong to a source that no longer
        // exists.
        var suppressedEventIDs = Set<String>()

        // App-server Working-control admission state (Bridge Phase C).
        // Deliberately INDEPENDENT of currentTurnID/suppressedEventIDs above
        // — those are transcript-vendor state cleared by a transcript
        // `.sessionStarted`/`.sessionEnded`/beginNewSourceEpoch, none of
        // which represent a true app-server process incarnation. This state
        // is cleared ONLY by `beginAppServerControlIncarnation`, a separate,
        // scoped API (never by the transcript-only reset above).
        //
        // The currently open/tracked logical turn, if any.
        var appServerCurrentLogicalTurn: AppServerLogicalTurnKey?
        // A logical turn that lost its last live owner (owner-scoped
        // terminal) without being semantically tombstoned — an exact
        // revision-fenced resume may still reopen it.
        var appServerSuspendedLogicalTurn: AppServerLogicalTurnKey?
        // The owner key that most recently suspended appServerSuspendedLogicalTurn
        // — carried so a later prompt-close resume can attribute the
        // correct runtime_generation/owner_token metadata without having to
        // infer "the current owner" (there is none while suspended).
        var appServerSuspendedLastOwner: AppServerOwnerKey?
        // Every owner (attached runtime) currently contributing to
        // appServerCurrentLogicalTurn.
        var appServerActiveOwners = Set<AppServerOwnerKey>()
        // Deterministic "current" owner for THIS logical turn, for contexts
        // (e.g. prompt-resolve resume metadata) that need exactly ONE owner
        // rather than an arbitrary Set iteration order. Rule: last-writer-
        // wins on every accepted start/activity/resume admission for this
        // owner; on that owner's disconnect, if other owners remain for the
        // SAME logical turn, the fallback is deterministic (lexicographically
        // smallest ownerToken among the remaining), not "whichever the Set
        // iterates first."
        var appServerPreferredOwner: AppServerOwnerKey?
        // A logical turn that reached a genuine semantic terminal (or a
        // terminal arrived before its start) — permanently closed; a late
        // reopen attempt for the SAME key is rejected forever (until a true
        // app-server incarnation rotation clears this set).
        var appServerSemanticTombstones = Set<AppServerLogicalTurnKey>()
        // An owner that was explicitly retired — idempotency guard so a
        // duplicate disconnect notification for the same owner is a no-op,
        // never a second terminal / second retire side effect.
        var appServerRetiredOwnerTombstones = Set<AppServerOwnerKey>()
        // The latest admitted control AgentEvent still considered "active"
        // for replay/snapshot purposes (open or continue phase; cleared on
        // any terminal). An active interactive prompt clears this eagerly
        // at prompt-open time (see applyWorkingAndPromptFoldLocked), not
        // just at fetch/replay time — so an expired/mismatched prompt close
        // can never resurrect it via replay.
        var appServerLatestControlSnapshot: AgentEvent?
        // Persistent (never rebuilt/trimmed against bufferedEvents) dedup
        // set for admitted control edge IDs — deliberately SEPARATE from
        // `seenEventIDs`, which is rebuilt against `bufferedEvents` on
        // capacity overflow (see `publish`'s `maxSeenEventIDs` branch) and
        // would silently forget an evicted control eventID, letting an
        // exact-duplicate re-observation slip through as "new". Cleared
        // ONLY on a true app-server incarnation rotation, never by capacity.
        var appServerAdmittedEdgeIDs = Set<String>()
        // The control incarnation `(epoch, root)` this session's app-server
        // control state currently belongs to. `beginAppServerControlIncarnation`
        // is a no-op (preserves current/suspended/tombstones/snapshot) when
        // called again with the SAME incarnation (e.g. a runtime generation
        // replacement re-attaching to the same underlying process/root) —
        // only a genuinely different epoch or root clears this state.
        var appServerControlIncarnation: AppServerControlIncarnation?
    }

    private struct SessionBinding {
        let workspaceID: String
        let panelID: String?
    }

    private let queue = DispatchQueue(label: "com.tidey.remote-bridge.agent-event-hub")
    // Delivery serialization: sinks are NEVER invoked while holding the
    // state queue (reentrancy/deadlock), but the delivery order is fixed by
    // enqueueing FROM INSIDE the state queue onto this serial queue — so
    // subscriber delivery follows the hub's accepted/store order exactly,
    // across concurrent producers.
    private let deliveryQueue = DispatchQueue(label: "com.tidey.remote-bridge.agent-event-hub.delivery")
    // Test-only: fires on the caller's thread at the very TOP of `publish`,
    // before the dedupe/seenEventIDs check — unlike `postStoreDeliveryHook`
    // (which only fires for an event that was genuinely stored), this fires
    // for EVERY call, including one the dedupe guard goes on to swallow.
    // Exists specifically to catch a caller that wrongly re-publishes an
    // event the Hub already stored via a different entry point (e.g. typed
    // admission's own internal store) — such a re-publish would be silently
    // absorbed by the dedupe guard and produce no observable difference in
    // `postStoreDeliveryHook`/`fetch`, so a test asserting only those would
    // pass against a buggy double-publish just as easily as a correct
    // single-publish. Assert this hook's count directly to catch that.
    var publishAttemptHook: ((AgentEvent) -> Void)?
    // Test-only: fires on the publisher thread AFTER the event was stored
    // (and its delivery position fixed), before publish() returns.
    var postStoreDeliveryHook: ((AgentEvent) -> Void)?
    // Test-only: fires on the delivery queue after a drain resolved its
    // sinks, before invoking them.
    var preInvokeDeliveryHook: (() -> Void)?
    // Test-only: fires when unsubscribe's cancel is WAITING for an in-flight
    // invocation on another thread (before it returns).
    var unsubscribeCancelWaitHook: (() -> Void)?
    private var subscribers = [UUID: Subscriber]()
    private var sessions = [String: SessionState]()
    private var sessionBindings = [String: SessionBinding]()
    private var reservedSeqBySessionID: [String: Int] = [:]
    private let maxBufferedEvents: Int
    private let maxSeenEventIDs: Int

    init(maxBufferedEvents: Int = 2000, maxSeenEventIDs: Int = 4000) {
        self.maxBufferedEvents = max(1, maxBufferedEvents)
        self.maxSeenEventIDs = max(1, maxSeenEventIDs)
    }

    func subscribe(workspaceID: String?,
                   sessionID: String? = nil,
                   sinceSeq: Int? = nil,
                   sink: @escaping (AgentEventEnvelope) -> Void) -> (UUID, [AgentEventEnvelope]) {
        queue.sync {
            let subscriberID = UUID()
            subscribers[subscriberID] = Subscriber(workspaceID: workspaceID, sessionID: sessionID, sink: sink)

            let replay = replayEvents(workspaceID: workspaceID, sessionID: sessionID, sinceSeq: sinceSeq)
                .map { AgentEventEnvelope(replay: true, event: $0) }
            return (subscriberID, replay)
        }
    }

    func fetch(workspaceID: String,
               sessionID: String? = nil,
               limit: Int,
               maxBytes: Int? = nil,
               beforeSeq: Int? = nil,
               afterSeq: Int? = nil) -> FetchResult {
        queue.sync { () -> FetchResult in
            let effectiveLimit = max(limit, 1)
            let matchingEvents: [AgentEvent]

            if let sessionID, let state = sessions[sessionID] {
                matchingEvents = state.allStoredEvents
                    .compactMap { effectiveEvent($0) }
                    .filter { event in
                    // Defense in depth: a session-scoped fetch never serves
                    // an event owned by another session.
                    guard event.sessionID == sessionID else {
                        return false
                    }
                    guard event.workspaceID == workspaceID else {
                        return false
                    }
                    guard isVisibleUnderCurrentIncarnation(event) else {
                        return false
                    }
                    if let beforeSeq {
                        return event.seq < beforeSeq
                    }
                    if let afterSeq {
                        return event.seq > afterSeq
                    }
                    return true
                }.sorted(by: Self.eventOrderingComparator(sessionScoped: true))
            } else {
                matchingEvents = sessions.values
                    .flatMap(\.allStoredEvents)
                    .compactMap { effectiveEvent($0) }
                    .filter { event in
                        guard event.workspaceID == workspaceID else {
                            return false
                        }
                        guard isVisibleUnderCurrentIncarnation(event) else {
                            return false
                        }
                        if let beforeSeq {
                            return event.seq < beforeSeq
                        }
                        if let afterSeq {
                            return event.seq > afterSeq
                        }
                        return true
                    }
                    .sorted(by: Self.eventOrderingComparator(sessionScoped: false))
            }

            let countLimitedEvents: [AgentEvent]
            if afterSeq != nil {
                countLimitedEvents = Array(matchingEvents.prefix(effectiveLimit))
            } else {
                countLimitedEvents = Array(matchingEvents.suffix(effectiveLimit))
            }
            let slice = budgetLimitedEvents(countLimitedEvents,
                                            maxBytes: maxBytes,
                                            prefersNewestEvents: afterSeq == nil)
            let oldestSeq = slice.first?.seq ?? 0
            let newestSeq = slice.last?.seq ?? 0
            let hasMore = matchingEvents.count > slice.count

            // Snapshot overlay: applied strictly AFTER the page/bounds above
            // are finalized — oldestSeq/newestSeq/hasMore reflect the page
            // exactly as they would without this seam; the overlay can only
            // ever ADD events to the returned array. beforeSeq (backward
            // pagination) never overlays. afterSeq only overlays a snapshot
            // strictly newer than the cursor. A snapshot already present in
            // the page is never duplicated. Session-scoped and
            // workspace-wide (sessionID == nil) fetch use the SAME
            // contract: workspace-wide overlays every session's active
            // snapshot whose effective workspace binding matches, not just
            // one — this must stay consistent with `replayEvents`, which
            // already injects every session's snapshot.
            var events = slice
            if beforeSeq == nil {
                // The insertion comparator MUST be the EXACT SAME shared,
                // total-order comparator the base page above was sorted
                // with (see `eventOrderingComparator`) — never a locally
                // re-derived approximation of it.
                let precedes = Self.eventOrderingComparator(sessionScoped: sessionID != nil)
                // Sorted, not raw `sessions.keys` — a Dictionary's iteration
                // order is not guaranteed stable, which would otherwise make
                // multi-session overlay output nondeterministic.
                let candidateSessionIDs = sessionID.map { [$0] } ?? sessions.keys.sorted()
                for candidateSessionID in candidateSessionIDs {
                    guard let rawSnapshot = sessions[candidateSessionID]?.appServerLatestControlSnapshot,
                          // Defense in depth, symmetric with the ordinary
                          // page/replay filters: a snapshot surviving from a
                          // rotated-away incarnation (a snapshot-clear
                          // regression on `beginAppServerControlIncarnation`)
                          // must still never leak through the overlay path.
                          isVisibleUnderCurrentIncarnation(rawSnapshot),
                          afterSeq.map({ rawSnapshot.seq > $0 }) ?? true,
                          events.contains(where: { $0.eventID == rawSnapshot.eventID }) == false,
                          let snapshot = effectiveEvent(rawSnapshot),
                          snapshot.workspaceID == workspaceID else {
                        continue
                    }
                    let insertIndex = events.firstIndex(where: { precedes(snapshot, $0) }) ?? events.count
                    events.insert(snapshot, at: insertIndex)
                }
            }
            return FetchResult(events: events, oldestSeq: oldestSeq, newestSeq: newestSeq, hasMore: hasMore)
        }
    }

    // Read-time incarnation visibility: an ORDINARY/transcript event is
    // always visible. A stored app-server control wire event
    // (`source == codex_app_server_working_control`) is visible only while
    // its own embedded (epoch, root) still matches the session's CURRENT
    // control incarnation. This is defense in depth, NOT the primary
    // mechanism: `beginAppServerControlIncarnation` physically PURGES old
    // control wire artifacts from the buffer/historical store on a true
    // rotation (see its own doc comment) — ordinary/transcript events and
    // `storedSeqHighWater` are never touched by that purge. This filter
    // exists to also catch anything that purge might miss (or a future
    // regression in it), never as a substitute for actually deleting stale
    // control artifacts — a filter alone cannot survive the SAME (epoch,
    // root) tuple being reused by a later generation (A -> B -> A).
    private func isVisibleUnderCurrentIncarnation(_ event: AgentEvent) -> Bool {
        guard event.metadata?["source"] == "codex_app_server_working_control" else {
            return true
        }
        guard let incarnation = sessions[event.sessionID]?.appServerControlIncarnation,
              event.metadata?["app_server_epoch"] == incarnation.epoch,
              event.metadata?["root_thread_id"] == incarnation.rootThreadID else {
            return false
        }
        return true
    }

    private func replayEvents(workspaceID: String?, sessionID: String?, sinceSeq: Int?) -> [AgentEvent] {
        let filteredStates: [SessionState]
        if let sessionID, let state = sessions[sessionID] {
            filteredStates = [state]
        } else {
            filteredStates = Array(sessions.values)
        }

        return filteredStates
            .flatMap { state -> [AgentEvent] in
                var events = state.allStoredEvents
                if state.isActive,
                   let sessionStarted = state.latestSessionStarted,
                   !events.contains(where: { $0.eventID == sessionStarted.eventID }),
                   sinceSeq == nil {
                    events.append(sessionStarted)
                }
                // Snapshot overlay: injected into the raw candidate list
                // (deduped by eventID) and left to the ordinary sinceSeq
                // filter below to decide visibility — `sinceSeq == nil`
                // (full replay) always passes; `sinceSeq >= snapshot.seq`
                // (including the noReplay sentinel `Int.max`) naturally
                // excludes it, matching fetch's afterSeq/beforeSeq/noReplay
                // contract without duplicating that logic here.
                if let snapshot = state.appServerLatestControlSnapshot,
                   !events.contains(where: { $0.eventID == snapshot.eventID }) {
                    events.append(snapshot)
                }
                return events
            }
            .compactMap { effectiveEvent($0) }
            .filter { event in
                if let workspaceID, event.workspaceID != workspaceID {
                    return false
                }
                if let sessionID, event.sessionID != sessionID {
                    return false
                }
                if let sinceSeq, event.seq <= sinceSeq {
                    return false
                }
                guard isVisibleUnderCurrentIncarnation(event) else {
                    return false
                }
                return true
            }
            .sorted(by: Self.eventOrderingComparator(sessionScoped: sessionID != nil))
    }

    // Shared by `fetch`'s base page (both session-scoped and workspace-
    // wide), `fetch`'s snapshot-overlay insertion, AND `replayEvents` —
    // every one of them sorts through THIS single function so all three
    // read paths agree on one total order per request mode. A SINGLE
    // comparator for the whole sort, chosen once by request mode — never
    // switched per-pair based on whether two particular events happen to
    // share a session. A per-pair "same session -> seq, else -> timestamp"
    // rule is NOT a strict weak ordering (three events across two sessions
    // can form A < B < C < A when timestamps aren't monotonic with seq),
    // which is undefined behavior for `sorted(by:)` and can silently
    // corrupt fetch/replay/overlay order or worse.
    //
    // - Session-scoped (sessionID != nil): every candidate is already
    //   filtered to ONE session, so seq is the single shared timeline;
    //   eventID is a deterministic tie-break for an exact seq collision.
    // - Workspace-wide (sessionID == nil): timestamp is the only axis
    //   genuinely shared across DIFFERENT sessions' independent seq
    //   counters; seq, then sessionID, then eventID break ties
    //   deterministically.
    private static func eventOrderingComparator(sessionScoped: Bool) -> (AgentEvent, AgentEvent) -> Bool {
        if sessionScoped {
            return { lhs, rhs in
                if lhs.seq != rhs.seq {
                    return lhs.seq < rhs.seq
                }
                return lhs.eventID < rhs.eventID
            }
        }
        return { lhs, rhs in
            if lhs.timestamp != rhs.timestamp {
                return lhs.timestamp < rhs.timestamp
            }
            if lhs.seq != rhs.seq {
                return lhs.seq < rhs.seq
            }
            if lhs.sessionID != rhs.sessionID {
                return lhs.sessionID < rhs.sessionID
            }
            return lhs.eventID < rhs.eventID
        }
    }

    func unsubscribe(_ subscriberID: UUID) {
        let removed = queue.sync {
            subscribers.removeValue(forKey: subscriberID)
        }
        // Linearize: after this returns, no invocation of the removed sink
        // may start; an in-flight invocation on another thread is awaited.
        removed?.gate.cancel(waitHook: unsubscribeCancelWaitHook)
    }

    func oldestBufferedSeq(sessionID: String) -> Int? {
        queue.sync {
            sessions[sessionID]?.allStoredEvents
                .map(\.seq)
                .min()
        }
    }

    // Reserves and returns the next synthetic sequence number for a session.
    // Reservation is a high-water mark: several events can be created before
    // any of them is published (e.g. a batch of terminal events from one
    // turn/close) and must still get unique, monotonically increasing seqs.
    // A later native publish with a larger seq lifts the next reservation
    // above it via bufferedMax.
    //
    // storedSeqHighWater is included so the returned reservation reflects
    // everything ALREADY stored at the moment this call runs — bufferedEvents
    // is trimmed by both capacity AND by beginNewSourceEpoch (which wipes it
    // entirely to start a fresh source), so bufferedMax alone can be far
    // BELOW the session's true accepted high-water right after a reset;
    // storedSeqHighWater survives that wipe by design and is the single
    // authority for "everything ever accepted" as of THIS instant.
    //
    // This is a snapshot, not a lock: it only guarantees the returned value
    // is higher than every seq stored/reserved SO FAR — between this call
    // returning and the caller's own later `publish()` call, a DIFFERENT
    // producer on the same session can reserve and/or publish a higher seq
    // first (see the Round 7G TOCTOU fix in ClaudeTranscriptSession/
    // CodexTranscriptSession's beginNewSourceEpoch/start). A caller minting
    // a cross-epoch boundary seq (or any producer's own local sequencing
    // derived from this reservation) must NOT treat this return value as
    // the final stored seq — only `publish()`'s own return value (the
    // ACTUAL stored seq, post any rebase-on-collision) is trustworthy for
    // that purpose.
    func nextSyntheticSeq(sessionID: String) -> Int {
        queue.sync {
            let bufferedMax = sessions[sessionID]?.bufferedEvents.map(\.seq).max() ?? transcriptSessionStartedSequence
            let startMax = sessions[sessionID]?.latestSessionStarted?.seq ?? transcriptSessionStartedSequence
            let storedHighWater = sessions[sessionID]?.storedSeqHighWater ?? transcriptSessionStartedSequence
            let reserved = reservedSeqBySessionID[sessionID] ?? transcriptSessionStartedSequence
            let next = max(bufferedMax, startMax, storedHighWater, reserved) + 1
            reservedSeqBySessionID[sessionID] = next
            return next
        }
    }

    private static func droppingOpenersWithTrimmedClosures(kept: [AgentEvent],
                                                            preTrim: [AgentEvent]) -> [AgentEvent] {
        let keptIDs = Set(kept.map(\.eventID))
        var dropIDs = Set<String>()
        for opener in kept {
            switch opener.type {
            case .interactivePrompt:
                guard let promptID = AgentInteractivePromptSidebarMessages.promptID(from: opener) else {
                    continue
                }
                // Closure identity follows the EXACT lifecycle contract of
                // activeInteractivePrompt: a token-bound opener is only
                // closed by ITS token; a capability-bound tokenless opener is
                // closed by no live terminal at all; legacy openers keep the
                // promptID contract. A mismatched terminal being trimmed must
                // never drop a genuinely active opener.
                let openerToken = AgentInteractivePromptSidebarMessages.lifecycleToken(from: opener)
                let openerRequiresCapability = AgentInteractivePromptSidebarMessages.requiresLifecycleCapability(opener)
                let closure = preTrim.first { candidate in
                    guard candidate.type == .interactivePromptResolved,
                          AgentInteractivePromptSidebarMessages.promptID(from: candidate) == promptID,
                          candidate.seq > opener.seq else {
                        return false
                    }
                    return AgentInteractivePromptSidebarMessages.terminalCloses(openerLifecycleToken: openerToken,
                                                                                openerRequiresCapability: openerRequiresCapability,
                                                                                terminal: candidate)
                }
                if let closure, keptIDs.contains(closure.eventID) == false {
                    dropIDs.insert(opener.eventID)
                }
            default:
                guard opener.metadata?["tidey_generated"] == "claude_context_command" else {
                    continue
                }
                // A summary belongs to the NEAREST preceding unmatched
                // command: a later command's summary never closes this one.
                let nextCommandSeq = preTrim
                    .filter { $0.metadata?["tidey_generated"] == "claude_context_command" && $0.seq > opener.seq }
                    .map(\.seq)
                    .min()
                let closure = preTrim.first { candidate in
                    candidate.metadata?["tidey_generated"] == "claude_context"
                        && candidate.seq > opener.seq
                        && (nextCommandSeq == nil || candidate.seq < nextCommandSeq!)
                }
                if let closure, keptIDs.contains(closure.eventID) == false {
                    dropIDs.insert(opener.eventID)
                }
            }
        }
        guard dropIDs.isEmpty == false else {
            return kept
        }
        return kept.filter { dropIDs.contains($0.eventID) == false }
    }

    // Minimal test seam: builds the corrupt state the fetch defense guards
    // against (a foreign-session event stored inside another session's
    // state). Bypasses the replacement ownership guard ON PURPOSE.
    func injectCorruptStoredHistoricalEventForTesting(sessionID: String, event: AgentEvent) {
        queue.sync {
            var state = sessions[sessionID] ?? SessionState()
            state.historicalEvents.append(event)
            state.historicalEvents.sort { $0.seq < $1.seq }
            state.historicalEventIDs.insert(event.eventID)
            sessions[sessionID] = state
        }
    }

    func debugSnapshots() -> [SessionDebugSnapshot] {
        queue.sync {
            sessions.map { sessionID, state in
                let effectiveEvents = state.allStoredEvents.compactMap { effectiveEvent($0) }
                let seqs = effectiveEvents.map(\.seq)
                return SessionDebugSnapshot(sessionID: sessionID,
                                            workspaceID: effectiveEvents.last?.workspaceID ?? effectiveEvent(state.latestSessionStarted)?.workspaceID,
                                            bufferedEventCount: state.allStoredEvents.count,
                                            oldestSeq: seqs.min(),
                                            newestSeq: seqs.max(),
                                            isActive: state.isActive)
            }
        }
    }

    func activeInteractivePrompt(workspaceID: String,
                                 sessionID: String,
                                 promptID: String) -> InteractivePrompt? {
        queue.sync {
            guard let state = sessions[sessionID] else {
                return nil
            }
            var activePrompt: InteractivePrompt?
            var activeLifecycleToken: String?
            var activeRequiresCapability = false
            for event in state.allStoredEvents
                .compactMap({ effectiveEvent($0) })
                .filter({ $0.workspaceID == workspaceID && $0.sessionID == sessionID })
                .sorted(by: { $0.seq < $1.seq }) {
                guard AgentInteractivePromptSidebarMessages.promptID(from: event) == promptID else {
                    continue
                }
                switch event.type {
                case .interactivePrompt:
                    activePrompt = InteractivePrompt(jsonValue: event.payload)
                    activeLifecycleToken = AgentInteractivePromptSidebarMessages.lifecycleToken(from: event)
                    activeRequiresCapability = AgentInteractivePromptSidebarMessages.requiresLifecycleCapability(event)
                case .interactivePromptResolved:
                    // Single lifecycle-matching contract (shared with the
                    // trim and the latest-resolved lookup): a legacy opener
                    // is closed ONLY by a tokenless non-capability terminal.
                    if AgentInteractivePromptSidebarMessages.terminalCloses(openerLifecycleToken: activeLifecycleToken,
                                                                            openerRequiresCapability: activeRequiresCapability,
                                                                            terminal: event) {
                        activePrompt = nil
                    }
                default:
                    break
                }
            }
            return activePrompt
        }
    }

    // Source identity switch: every stored product and idempotency set of
    // the session's OLD source is revoked; the seq high-water and synthetic
    // reservations survive so subscriber cursors stay monotonic (new
    // products rebase above the old stream). latestSessionStarted/isActive
    // are ALSO cleared (not just the buffers) — replayEvents() re-injects
    // the latest sessionStarted for any subscriber joining after the buffer
    // was trimmed; leaving the OLD source's sessionStarted marked active
    // would let a subscriber that races the gap between this reset and the
    // caller's fresh boundary publish get replayed back into the OLD
    // source's start instead of nothing.
    func beginNewSourceEpoch(sessionID: String) {
        queue.sync {
            // A workspace/panel binding is sticky per sessionID (see
            // migrateSession) and is applied to EVERY future event at
            // read-time via effectiveEvent(), independent of whatever
            // workspace_id the publisher literally stamped on the event. A
            // new source incarnation for this sessionID (a brand new
            // transcript session object, e.g. after a registry monitor
            // stop+recreate for a reused sessionID) must start from its OWN
            // record's workspace/panel, not have it silently overridden by a
            // stale binding left over from a PREVIOUS incarnation's
            // migration — so this is cleared unconditionally, even if no
            // session state exists yet.
            sessionBindings.removeValue(forKey: sessionID)
            guard var state = sessions[sessionID] else {
                return
            }
            state.bufferedEvents.removeAll()
            state.historicalEvents.removeAll()
            state.historicalEventIDs.removeAll()
            state.seenEventIDs.removeAll()
            state.latestSessionStarted = nil
            state.isActive = false
            // Round 7B: a TRANSCRIPT source epoch reset supersedes the OLD
            // source's tracked turn and clears the suppressed-event
            // tombstone (the old source no longer exists, so its suppressed
            // IDs are moot; a new incarnation can legitimately reuse an
            // eventID, which must not be swallowed by a stale tombstone).
            state.currentTurnID = nil
            state.suppressedEventIDs.removeAll()
            // Round 7C P0-D: `activePromptLifecycle` is NOT blindly
            // preserved for every vendor — only entries that satisfy the
            // Codex-native app-server capability contract survive (the
            // actual cross-epoch-reuse case this exists for: the runtime is
            // REUSED and never re-notifies a still-pending approval). A
            // Claude/generic opener is always tied to the TRANSCRIPT
            // identity that just reset and must never persist past it.
            state.activePromptLifecycle = state.activePromptLifecycle.filter { Self.isCodexNativeAppServerCapable($0.value) }
            sessions[sessionID] = state
        }
    }

    func latestInteractivePromptResolvedEvent(workspaceID: String,
                                              sessionID: String,
                                              promptID: String,
                                              lifecycleToken: String? = nil,
                                              openerRequiresCapability: Bool = false) -> AgentEvent? {
        queue.sync {
            guard let state = sessions[sessionID] else {
                return nil
            }
            return state.allStoredEvents
                .compactMap { effectiveEvent($0) }
                .filter { event in
                    guard event.workspaceID == workspaceID,
                          event.sessionID == sessionID,
                          event.type == .interactivePromptResolved,
                          AgentInteractivePromptSidebarMessages.promptID(from: event) == promptID else {
                        return false
                    }
                    // A token-bound lookup may only be answered by the exact
                    // lifecycle's terminal (fail closed for missing tokens);
                    // a LEGACY (tokenless) lookup is never answered by a
                    // capability-bound terminal.
                    // A nil-token lookup is only LEGACY when the opener is
                    // genuinely non-capability; a capability-bound tokenless
                    // lookup can never be answered by a live terminal.
                    return AgentInteractivePromptSidebarMessages.terminalCloses(openerLifecycleToken: lifecycleToken,
                                                                                openerRequiresCapability: openerRequiresCapability,
                                                                                terminal: event)
                }
                .sorted { lhs, rhs in
                    if lhs.seq == rhs.seq {
                        return lhs.timestamp < rhs.timestamp
                    }
                    return lhs.seq < rhs.seq
                }
                .last
        }
    }

    @discardableResult
    func migrateSession(sessionID: String,
                        toWorkspaceID workspaceID: String,
                        panelID: String?) -> Int {
        queue.sync {
            sessionBindings[sessionID] = SessionBinding(workspaceID: workspaceID, panelID: panelID)
            guard var state = sessions[sessionID], !state.allStoredEvents.isEmpty else {
                if sessions[sessionID]?.latestSessionStarted == nil {
                    return 0
                }
                guard var state = sessions[sessionID] else {
                    return 0
                }
                if let sessionStarted = state.latestSessionStarted {
                    state.latestSessionStarted = Self.rewritten(event: sessionStarted,
                                                                workspaceID: workspaceID,
                                                                panelID: panelID)
                    sessions[sessionID] = state
                    return 1
                }
                return 0
            }

            state.historicalEvents = state.historicalEvents.map { event in
                Self.rewritten(event: event, workspaceID: workspaceID, panelID: panelID)
            }
            state.bufferedEvents = state.bufferedEvents.map { event in
                Self.rewritten(event: event, workspaceID: workspaceID, panelID: panelID)
            }
            if let sessionStarted = state.latestSessionStarted {
                state.latestSessionStarted = Self.rewritten(event: sessionStarted,
                                                            workspaceID: workspaceID,
                                                            panelID: panelID)
            }
            let migratedCount = state.allStoredEvents.count
            sessions[sessionID] = state
            return migratedCount
        }
    }

    // Storage policy for publish. Live/forward events own the cursor: unseen
    // events at or below the high-water are rebased above it. Historical
    // backfill (transcript pages older than what is already stored) must keep
    // its ORIGINAL cursor position, never reach live subscribers, and never
    // appear in an already-advanced after_seq catch-up.
    enum PublishStorage {
        case liveForward
        case historicalBackfill
    }

    // Round 7G P0 (TOCTOU fix, corrected contract): returns the ACTUAL
    // stored seq, or `nil` if this event was NOT stored at all (a duplicate
    // eventID, or suppressed by the Working/prompt fold) — `nil` is not an
    // error, but it is NOT proof of a seq either, so a caller must never
    // treat it as "claimed seq was fine." The stored seq may differ from
    // the caller's claimed `event.seq` if this exact call triggered the
    // liveForward rebase-on-collision path below. A caller that needs to
    // mint a cross-epoch boundary seq and then immediately rely on it being
    // the TRUE stored value (e.g. to set its own local high-water/base)
    // MUST use this return value — and MUST fail closed (never establish a
    // new base) if it is `nil` — rather than a separately reserved seq from
    // `nextSyntheticSeq` alone: between that reservation and this publish
    // call, another producer could have published a higher seq that pushes
    // the Hub's high-water past the reservation, silently rebasing this
    // event out from under a caller trusting its own pre-computed value.
    // This whole `queue.sync` block is the ONE atomic critical section that
    // decides the final seq (or non-storage); there is no separate
    // reserve-then-store race INSIDE this call. The returned seq is
    // identical to what `postStoreDeliveryHook`, every scheduled subscriber
    // envelope, and a subsequent `fetch`'s high-water will observe for this
    // SAME event — they all read the one `event` this function rebases
    // (if at all) inside this same critical section, never a second,
    // independently-recomputed value.
    @discardableResult
    func publish(_ event: AgentEvent, deliverToSubscribers: Bool = true, storage: PublishStorage = .liveForward) -> Int? {
        publishAttemptHook?(event)
        var event = event
        // `wasStored` gates ONLY the live-forward delivery/hook path
        // (scheduleDeliveryLocked + postStoreDeliveryHook below) — it must
        // stay false for a genuinely-stored HISTORICAL event, which never
        // reaches subscribers or the test hook. `historicalStoredSeq` is
        // the SEPARATE "was this event genuinely stored at all" signal the
        // RETURN VALUE is based on for that branch: a historical event that
        // is accepted (strictly below the live high-water) IS a genuine
        // store and must report its actual seq, never `nil` — `nil` is
        // reserved for a truly unstored event (duplicate, or rejected for
        // sitting at/above the live high-water).
        var wasStored = false
        var historicalStoredSeq: Int?
        queue.sync {
            var state = sessions[event.sessionID] ?? SessionState()
            if state.seenEventIDs.contains(event.eventID)
                || state.historicalEventIDs.contains(event.eventID)
                || state.suppressedEventIDs.contains(event.eventID) {
                return
            }

            // Round 7C: the interactive-prompt-aware Working fold decides
            // suppression HERE, before seenEventIDs insertion, the seq
            // rebase, storedSeqHighWater advance, buffer append, subscriber
            // scheduling, or the postStoreDeliveryHook — a suppressed OR
            // rejected event must have ZERO side effects on sequencing or
            // delivery. Both dedupe via `suppressedEventIDs`, a set
            // DELIBERATELY separate from `seenEventIDs` (whose own
            // capacity-driven rebuild below only retains IDs still present
            // in bufferedEvents — such an event is never appended there, so
            // it would otherwise silently fall back out of dedupe and become
            // re-acceptable on an exact retry). Only applies to liveForward:
            // historical backfill/replace never touches Working/prompt fold
            // state at all.
            if storage == .liveForward {
                if Self.isWorkingAnchor(event) {
                    // Round 7C: an anchor with a NIL/BLANK turn_id must
                    // never be created/displayed — if stored normally it
                    // would show Working with no matching-clearable tracked
                    // turn (no terminal could ever reference it back).
                    // Tombstoned unconditionally, before ANY side effect,
                    // exactly like a malformed continuation (P0-A).
                    guard let anchorTurnID = Self.normalizedTurnID(event.metadata?["turn_id"]) else {
                        state.suppressedEventIDs.insert(event.eventID)
                        sessions[event.sessionID] = state
                        return
                    }
                    // Bridge Phase C: an ordinary transcript anchor for a
                    // turn ID the app-server control seam has already
                    // reached a SEMANTIC terminal for (typed `turnTerminal`
                    // admission) must never resurrect it — a late rollout
                    // replay racing behind the live app-server connection
                    // could otherwise reopen Working for a turn control
                    // already closed. Derived only when a known control
                    // incarnation (epoch, root) exists for this session;
                    // zero side effect (no cursor/seq consumption) before
                    // ANY other mutation, same as the blank-turn-id guard
                    // above.
                    if let key = Self.appServerLogicalTurnKey(sessionID: event.sessionID, turnID: anchorTurnID, state: state),
                       state.appServerSemanticTombstones.contains(key) {
                        state.suppressedEventIDs.insert(event.eventID)
                        sessions[event.sessionID] = state
                        return
                    }
                    // An anchor otherwise ALWAYS applies (it supersedes/
                    // establishes turn identity) — only suppressed if a
                    // prompt is active.
                    if hasAnyActiveInteractivePrompt(in: state) {
                        // The anchor still supersedes/establishes the
                        // tracked turn even while suppressed (invisible to
                        // the client) — a later closing resolved must know
                        // EXACTLY which turn to resume, and a NEWER anchor
                        // must be able to supersede an older pending one.
                        state.currentTurnID = anchorTurnID
                        state.suppressedEventIDs.insert(event.eventID)
                        sessions[event.sessionID] = state
                        return
                    }
                } else if Self.isWorkingContinuation(event) {
                    // Round 7C P0: identity fail-closed. A continuation must
                    // carry a non-empty turn_id that EQUALS the currently
                    // tracked turn — nil, blank, mismatched, or a nil tracked
                    // turn (no anchor ever established one, or it was
                    // already closed/superseded) is REJECTED unconditionally,
                    // regardless of whether a prompt is active. Previously,
                    // a non-matching continuation fell through this check
                    // entirely and was stored/delivered exactly like a
                    // legitimate one — silently resurrecting Working from a
                    // stale, wrong-turn, or malformed continuation. Only a
                    // genuinely MATCHING continuation ever reaches the
                    // ordinary store path below; if a prompt is active, it
                    // additionally defers (suppressed) rather than storing.
                    let continuationTurnID = Self.normalizedTurnID(event.metadata?["turn_id"])
                    let trackedTurnID = Self.normalizedTurnID(state.currentTurnID)
                    guard let continuationTurnID, continuationTurnID == trackedTurnID else {
                        state.suppressedEventIDs.insert(event.eventID)
                        sessions[event.sessionID] = state
                        return
                    }
                    // Bridge Phase C: same semantic-tombstone check as the
                    // anchor branch above — a late continuation for a turn
                    // control already closed must never resurrect it.
                    if let key = Self.appServerLogicalTurnKey(sessionID: event.sessionID, turnID: continuationTurnID, state: state),
                       state.appServerSemanticTombstones.contains(key) {
                        state.suppressedEventIDs.insert(event.eventID)
                        sessions[event.sessionID] = state
                        return
                    }
                    if hasAnyActiveInteractivePrompt(in: state) {
                        state.suppressedEventIDs.insert(event.eventID)
                        sessions[event.sessionID] = state
                        return
                    }
                }
            }

            state.seenEventIDs.insert(event.eventID)
            if state.seenEventIDs.count > maxSeenEventIDs {
                // The live seen lifecycle must at least cover everything
                // still LIVE-stored; historical identity lives in its own
                // replacement-owned set.
                state.seenEventIDs = Set(state.bufferedEvents.map(\.eventID))
                state.seenEventIDs.insert(event.eventID)
            }

            switch storage {
            case .liveForward:
                // Publish-monotonic single authority: an unseen event whose
                // claimed seq is not ABOVE the stored high-water (collision
                // with an outstanding reservation, an out-of-order reserved
                // batch, or a late native producer) is rebased above
                // everything stored or reserved, keeping its event identity.
                // The high-water survives buffer trims, so evictions can
                // never resurrect old cursor positions.
                if let highWater = state.storedSeqHighWater, event.seq <= highWater {
                    let reserved = reservedSeqBySessionID[event.sessionID] ?? transcriptSessionStartedSequence
                    let rebased = max(highWater, reserved) + 1
                    event = event.withSeq(rebased)
                    reservedSeqBySessionID[event.sessionID] = rebased
                }
                state.storedSeqHighWater = max(state.storedSeqHighWater ?? event.seq, event.seq)
            case .historicalBackfill:
                // Historical pages keep their ORIGINAL cursor position: they
                // fill in below the live window for before_seq pagination and
                // must never move past an already-advanced after_seq cursor.
                // The contract is ENFORCED here: history must sit strictly
                // below the live high-water; anything else is rejected (the
                // live cursor and high-water never move for history).
                guard let highWater = state.storedSeqHighWater, event.seq < highWater else {
                    BridgeLogger.server.error("agent event hub rejected historical event at/above live high-water event_id=\(event.eventID, privacy: .public) seq=\(event.seq, privacy: .public)")
                    state.seenEventIDs.remove(event.eventID)
                    sessions[event.sessionID] = state
                    return
                }
                state.seenEventIDs.remove(event.eventID)
                state.historicalEventIDs.insert(event.eventID)
                state.historicalEvents.append(event)
                if state.historicalEvents.count > maxBufferedEvents {
                    let evicted = state.historicalEvents.removeFirst(state.historicalEvents.count - maxBufferedEvents)
                    _ = evicted
                    state.historicalEventIDs = Set(state.historicalEvents.map(\.eventID))
                }
                sessions[event.sessionID] = state
                // Genuinely stored (accepted, appended to historicalEvents)
                // — the caller must see this event's own seq, never `nil`,
                // even though it never reaches live delivery/the hook.
                historicalStoredSeq = event.seq
                return
            }

            state.bufferedEvents.append(event)
            if state.bufferedEvents.count > maxBufferedEvents {
                state.bufferedEvents.removeFirst(state.bufferedEvents.count - maxBufferedEvents)
            }
            switch event.type {
            case .sessionStarted:
                state.latestSessionStarted = event
                state.isActive = true
            case .sessionEnded:
                state.isActive = false
            default:
                break
            }
            let resumeEvent = applyWorkingAndPromptFoldLocked(for: event, state: &state)

            sessions[event.sessionID] = state
            wasStored = true

            // Historical storage NEVER reaches live subscribers, regardless
            // of the delivery flag.
            guard deliverToSubscribers, storage == .liveForward else {
                return
            }
            scheduleDeliveryLocked(event)
            if let resumeEvent {
                scheduleDeliveryLocked(resumeEvent)
            }
        }

        guard wasStored else {
            // Not live-stored — either genuinely unstored (duplicate/
            // suppressed/rejected-historical, `historicalStoredSeq` stays
            // nil), or a genuinely-stored HISTORICAL event, which reports
            // its own seq here without ever touching the live
            // delivery/hook path above.
            return historicalStoredSeq
        }
        postStoreDeliveryHook?(event)
        return event.seq
    }

    // MARK: - Round 7B helpers (interactive-prompt-aware Working continuation)
    //
    // Core invariant: the mobile client should show Working iff a turn is
    // tracked active AND no interactive prompt is active for the session —
    // never "turn active" alone (an active prompt/approval card must always
    // win) and never "a continuation was suppressed at some point" (a prompt
    // arriving AFTER an already-shown anchor/continuation must ALSO gate
    // resume on ITS closure, even with zero new transcript events in
    // between).

    // A Working-indicator ANCHOR: `.thinking` opening a turn, either the
    // ordinary live task_started or the deep-recovery bootstrap anchor.
    private static func isWorkingAnchor(_ event: AgentEvent) -> Bool {
        // Producer-domain boundary: task_started/bootstrap_recovered_task_started
        // are CodexTranscriptSession-specific free-form metadata — the Hub has
        // no typed producer boundary otherwise, so a non-Codex event that
        // happens to carry the same reason string (e.g. a generic/Claude
        // event) must never be treated as a Working anchor: it must not
        // create/supersede currentTurnID and must never be fail-closed
        // rejected by the Codex-specific gate — it is ordinary.
        guard event.vendor == "codex", event.type == .thinking, let reason = event.metadata?["reason"] else {
            return false
        }
        return reason == "task_started" || reason == "bootstrap_recovered_task_started"
    }

    // A Working-indicator CONTINUATION: `.thinking` maintaining an
    // already-open turn, explicitly marked by the producer (never inferred
    // from `reason`, which is free-form per call site).
    private static func isWorkingContinuation(_ event: AgentEvent) -> Bool {
        // Producer-domain boundary: `is_continuation` is CodexTranscriptSession-
        // specific free-form metadata — a non-Codex event carrying the same
        // flag must be treated as ordinary (stored/delivered normally), never
        // fail-closed rejected by the Codex-specific identity gate.
        event.vendor == "codex" && event.type == .thinking && event.metadata?["is_continuation"] == "true"
    }

    // Round 7C: nil-safe, whitespace-trimmed turn_id normalization shared by
    // every identity comparison in the fold — a blank/whitespace-only value
    // is treated exactly like nil (never a real turn identity), so it can
    // never accidentally "match" another blank/nil value.
    private static func normalizedTurnID(_ raw: String?) -> String? {
        guard let raw else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // Bridge Phase C: derives the app-server logical turn key an ORDINARY
    // transcript anchor/continuation would correspond to, so it can be
    // checked against `appServerSemanticTombstones` — nil when this session
    // has no known control incarnation yet (nothing to check against).
    private static func appServerLogicalTurnKey(sessionID: String, turnID: String, state: SessionState) -> AppServerLogicalTurnKey? {
        guard let incarnation = state.appServerControlIncarnation else {
            return nil
        }
        return AppServerLogicalTurnKey(sessionID: sessionID, epoch: incarnation.epoch, rootThreadID: incarnation.rootThreadID, turnID: turnID)
    }

    // The single deterministic "current" owner for `logical`: the tracked
    // `appServerPreferredOwner` if it is still active for this exact
    // logical turn, else a deterministic (lexicographically smallest
    // ownerToken) fallback among the remaining active owners — NEVER an
    // arbitrary `Set` iteration order.
    private static func deterministicOwner(for logical: AppServerLogicalTurnKey, in state: SessionState) -> AppServerOwnerKey? {
        if let preferred = state.appServerPreferredOwner, preferred.logical == logical,
           state.appServerActiveOwners.contains(preferred) {
            return preferred
        }
        return state.appServerActiveOwners
            .filter { $0.logical == logical }
            .sorted { $0.ownerToken < $1.ownerToken }
            .first
    }

    // Classifies what an ACTUALLY-closing `.interactivePromptResolved` with
    // a reason OTHER than "turn_completed" (handled separately as its own
    // tri-state — see the `.interactivePromptResolved` case above) means
    // for Working, against the real reason catalog produced by
    // CodexAppServerConnection/CodexAppServerApprovalPrompt:
    // - "server_resolved": the user genuinely answered and the turn
    //   continues — the ONLY reason eligible to auto-resume Working.
    // - "expired" (connection-close retirement), "superseded" (payload
    //   changed under the same request identity / redelivery / a
    //   JSON-RPC id-collision protocol terminal), or any OTHER/unrecognized
    //   reason: an abnormal or non-authoritative retirement — the prompt
    //   still closes (multi-prompt bookkeeping stays correct), but never
    //   resumes. Fail-closed: a subsequent genuine transcript event
    //   (continuation/terminal) still resolves it correctly on its own,
    //   rather than this guessing.
    private struct ResolvedReasonPolicy {
        let mayResumeWorking: Bool
    }

    private static func resolvedReasonPolicy(_ event: AgentEvent) -> ResolvedReasonPolicy {
        switch event.metadata?["reason"] {
        case "server_resolved":
            return ResolvedReasonPolicy(mayResumeWorking: true)
        default:
            return ResolvedReasonPolicy(mayResumeWorking: false)
        }
    }

    // Round 7C P0-C: the ONLY sources CodexAppServerConnection ever attaches
    // to a genuine approval-lifecycle event — a free-form "reason" string
    // alone (e.g. a generic/Claude/unknown producer faking "server_resolved")
    // is never trusted on its own for resuming Working.
    private static let codexNativeApprovalSourceAllowlist: Set<String> = [
        "codex_command_approval",
        "codex_file_change_approval",
        "codex_permissions_approval",
    ]

    // Round 7C P0-C: the full Codex-native app-server capability contract —
    // ALL FOUR must hold: vendor is exactly "codex" (not a generic/Claude
    // event merely carrying a matching reason string), the submit channel is
    // exactly "codex_app_server" (the live app-server connection, never a
    // CLI/transcript-only path), a non-empty exact lifecycle token is
    // present (the server-issued delivery capability — see
    // CodexAppServerConnection.makePromptEvent/makeResolvedEvent), and the
    // source is one of the three genuine approval kinds the app-server ever
    // emits. Applied to BOTH the opener and the terminal — a mismatch on
    // either side fails closed.
    private static func isCodexNativeAppServerCapable(_ event: AgentEvent) -> Bool {
        guard event.vendor == "codex" else {
            return false
        }
        guard event.metadata?["submit_channel"] == "codex_app_server" else {
            return false
        }
        guard let lifecycleToken = AgentInteractivePromptSidebarMessages.lifecycleToken(from: event),
              lifecycleToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return false
        }
        guard let source = event.metadata?["source"],
              codexNativeApprovalSourceAllowlist.contains(source) else {
            return false
        }
        return true
    }

    // Any-active-prompt check for THIS session — O(1) against the
    // independent live `activePromptLifecycle` map, NEVER a rescan of
    // `allStoredEvents` (which trims by capacity and is wiped wholesale by a
    // transcript-identity beginNewSourceEpoch; prompt lifecycle belongs to
    // the app-server RUNTIME, which is not necessarily reset alongside a
    // rollout-path-only transcript switch — see beginNewSourceEpoch).
    private func hasAnyActiveInteractivePrompt(in state: SessionState) -> Bool {
        state.activePromptLifecycle.isEmpty == false
    }

    // Whether `resolvedEvent` (not yet stored) genuinely closes an entry in
    // the live prompt-lifecycle map, per the existing promptID +
    // lifecycleToken/capability terminalCloses contract — a stale, mismatched,
    // or duplicate resolved (wrong token, unknown promptID, or a promptID
    // already removed by an earlier resolved) closes nothing and returns nil.
    // Must be called while already holding `queue` (never re-enters it).
    private func closingPromptID(for resolvedEvent: AgentEvent, in state: SessionState) -> String? {
        guard let promptID = AgentInteractivePromptSidebarMessages.promptID(from: resolvedEvent),
              let opener = state.activePromptLifecycle[promptID] else {
            return nil
        }
        let openerToken = AgentInteractivePromptSidebarMessages.lifecycleToken(from: opener)
        let openerRequiresCapability = AgentInteractivePromptSidebarMessages.requiresLifecycleCapability(opener)
        guard AgentInteractivePromptSidebarMessages.terminalCloses(openerLifecycleToken: openerToken,
                                                                    openerRequiresCapability: openerRequiresCapability,
                                                                    terminal: resolvedEvent) else {
            return nil
        }
        return promptID
    }

    // Applies the Round 7B fold's bookkeeping for an ACCEPTED (non-suppressed)
    // live event: Working-anchor/terminal/session turn tracking, the live
    // prompt-lifecycle map's opener/resolved updates, and — if warranted —
    // synthesizes the exactly-once resolved-time resume event. Returns that
    // resume event (to be stored+scheduled alongside the original), or nil.
    // Must be called while already holding `queue`.
    private func applyWorkingAndPromptFoldLocked(for event: AgentEvent, state: inout SessionState) -> AgentEvent? {
        switch event.type {
        case .thinking:
            if Self.isWorkingAnchor(event) {
                // Supersedes whatever turn was tracked before it — a NEW
                // task_started always wins over stale pending state.
                state.currentTurnID = Self.normalizedTurnID(event.metadata?["turn_id"])
            }
        case .assistantFinal:
            // Producer-domain boundary: `reason=turn_terminal` is
            // CodexTranscriptSession-specific free-form metadata — a
            // non-Codex event carrying the same reason string must never
            // clear the Codex-tracked turn.
            guard event.vendor == "codex",
                  event.metadata?["reason"] == "turn_terminal",
                  let turnID = Self.normalizedTurnID(event.metadata?["turn_id"]),
                  turnID == state.currentTurnID else {
                // A stale/mismatched terminal (for a turn that is not the
                // tracked one) must never clear tracked-turn state.
                return nil
            }
            state.currentTurnID = nil
        case .sessionStarted:
            // Round 7C P0-B: a live `.sessionStarted` is a genuinely NEW
            // session incarnation boundary — atomically clears whatever
            // turn/deferred state the OLD incarnation left behind. A stale
            // old-turn continuation, terminal, or resolved arriving after
            // this must never be able to influence the NEW session: with
            // currentTurnID nil, P0-A's identity fail-closed gate rejects
            // any continuation outright, and a terminal/resolved's own
            // turn_id match requirement (below) rejects it too.
            state.currentTurnID = nil
            // The tombstone set ALSO clears here — a new session incarnation
            // can legitimately reuse an eventID (e.g. a process-local
            // counter restarting), and without this, the OLD tombstone would
            // still swallow it as an "already suppressed" duplicate even
            // though it is a brand-new, legitimate event. A genuinely stale
            // OLD-turn continuation arriving late after this clear is still
            // independently fail-closed by P0-A's identity gate
            // (currentTurnID is now nil) — clearing this tombstone is safe.
            state.suppressedEventIDs.removeAll()
            // Round 7C P0-D: a session boundary drops any prompt-lifecycle
            // entry that is NOT Codex-native-app-server-capable — a Claude/
            // generic opener must never survive a session boundary to
            // permanently gate a later, unrelated turn. A genuinely
            // Codex-native pending approval (the cross-epoch-reuse case
            // beginNewSourceEpoch exists for) is preserved, identically to
            // the rule applied there.
            state.activePromptLifecycle = state.activePromptLifecycle.filter { Self.isCodexNativeAppServerCapable($0.value) }

            // Bridge Phase C: a live transcript source-epoch boundary
            // resets the mobile reducer's Working state on receipt of THIS
            // exact `.sessionStarted` — an already-subscribed client has no
            // other signal to re-fetch a snapshot. If an app-server control
            // turn is still genuinely live right through this boundary
            // (there WAS a snapshot before it, the current logical turn is
            // neither tombstoned nor gone, at least one owner is still
            // active, and no prompt is hiding it), mint exactly one fresh
            // typed resume scheduled AFTER this sessionStarted so the
            // client's Working reappears immediately rather than waiting
            // for the next real activity tick. Every gate below is a hard
            // requirement — missing any one means zero resume:
            // expired/mismatched-prompt-cleared snapshot, an ownerless
            // suspended turn, a semantic terminal, or a true incarnation
            // rotation (no current turn) all correctly produce nothing.
            if state.appServerLatestControlSnapshot != nil,
               let current = state.appServerCurrentLogicalTurn,
               state.appServerSemanticTombstones.contains(current) == false,
               state.activePromptLifecycle.isEmpty,
               let activeOwner = Self.deterministicOwner(for: current, in: state) {
                // Edge ID is bound to THIS exact accepted boundary event's
                // own eventID+seq (its real stored seq, post any rebase) —
                // an exact retry of the SAME stored sessionStarted can never
                // double-fire (blocked earlier by publish()'s own
                // seenEventIDs dedup); an eventID that fell out of the
                // bounded seenEventIDs window and gets genuinely
                // re-accepted (a new rebased seq) correctly mints its OWN
                // fresh resume, since that is a distinct edge.
                return storeAppServerControlEventLocked(logical: current,
                                                        ownerKey: activeOwner,
                                                        workspaceID: event.workspaceID,
                                                        workingPhase: "continue",
                                                        edgeKind: "resume:boundary:\(event.eventID):\(event.seq)",
                                                        reason: "resume_snapshot",
                                                        activity: nil,
                                                        terminalScope: nil,
                                                        time: event.timestamp,
                                                        state: &state)
            }
        case .sessionEnded:
            // Correction (Codex frozen review): `.sessionEnded` is NOT a new
            // incarnation boundary — it clears the tracked turn (a session
            // that ended has no turn left to reveal), and still drops any
            // non-Codex-native prompt-lifecycle entry (same P0-D rule), but
            // DOES NOT clear the `suppressedEventIDs` tombstone. Unlike a
            // continuation (which P0-A independently fail-closes once
            // currentTurnID is nil), an ANCHOR always re-establishes
            // currentTurnID from itself regardless of ambient state — so an
            // exact retry of a PREVIOUSLY-suppressed anchor, after the
            // tombstone was wrongly cleared here, would be reprocessed as if
            // new: re-suppressed (if a surviving native prompt is still
            // active) while STILL setting currentTurnID, or delivered
            // outright, in an already-ENDED session — and a later resolved
            // for that lingering native prompt could then synthesize a
            // resume Working signal for a session that no longer exists.
            state.currentTurnID = nil
            state.activePromptLifecycle = state.activePromptLifecycle.filter { Self.isCodexNativeAppServerCapable($0.value) }
        case .interactivePrompt:
            if let promptID = AgentInteractivePromptSidebarMessages.promptID(from: event) {
                state.activePromptLifecycle[promptID] = event
            }
            // App-server control precedence: a prompt OPENING hides control
            // Working immediately by clearing the latest snapshot outright —
            // not merely filtered out at fetch/replay time. This matters
            // because an expired/mismatched close later must never be able
            // to resurrect a stale snapshot via replay; only a fresh,
            // independently-identified resume (below) can re-establish one.
            state.appServerLatestControlSnapshot = nil
        case .interactivePromptResolved:
            guard let promptID = closingPromptID(for: event, in: state) else {
                return nil
            }
            // Captured BEFORE removal: the resume/end-turn capability gates
            // (below) need the OPENER event itself, not just its promptID.
            let opener = state.activePromptLifecycle[promptID]
            state.activePromptLifecycle.removeValue(forKey: promptID)

            // App-server control precedence: a prompt opening only HIDES
            // the display snapshot of a still-live, still-owned control
            // turn (see the `.interactivePrompt` case above) — it never
            // suspends it. So resuming here must re-reveal the turn that is
            // STILL `appServerCurrentLogicalTurn` with a STILL-active owner,
            // never `appServerSuspendedLogicalTurn` (that field is owned
            // exclusively by the owner-disconnect/revision-fenced-resume
            // path — see `retireAppServerOwner`/Section 6 — and reopening a
            // disconnected, ownerless turn here would show Working for a
            // turn nobody is actually running). Both the opener AND the
            // resolved event must independently satisfy the Codex-native
            // app-server capability contract; a generic/Claude/unknown
            // lifecycle can never resume typed control just by carrying a
            // matching reason string. When eligible, ONLY the typed control
            // resume fires — the legacy transcript resume path below is
            // skipped entirely for this event, so a single resolved event
            // can never produce both a legacy `thinking-resume:<seq>` AND a
            // typed control resume (double open / double seq).
            // `turn_completed`-reason resolves never qualify here
            // (resolvedReasonPolicy only allows "server_resolved").
            if state.activePromptLifecycle.isEmpty,
               Self.resolvedReasonPolicy(event).mayResumeWorking,
               let opener,
               Self.isCodexNativeAppServerCapable(opener),
               Self.isCodexNativeAppServerCapable(event),
               let current = state.appServerCurrentLogicalTurn,
               state.appServerSemanticTombstones.contains(current) == false,
               let activeOwner = Self.deterministicOwner(for: current, in: state) {
                let lifecycleToken = AgentInteractivePromptSidebarMessages.lifecycleToken(from: event) ?? "-"
                // Scoped by the EXACT prompt lifecycle (promptID + token),
                // not just the owner — a second, later prompt resolution
                // for the SAME still-live owner must still produce its own
                // distinct resume, never dedupe-coalesce against the first.
                return storeAppServerControlEventLocked(logical: current,
                                                        ownerKey: activeOwner,
                                                        workspaceID: event.workspaceID,
                                                        workingPhase: "continue",
                                                        edgeKind: "resume:prompt:\(promptID):\(lifecycleToken)",
                                                        reason: "resume_snapshot",
                                                        activity: nil,
                                                        terminalScope: nil,
                                                        time: event.timestamp,
                                                        state: &state)
            }

            // An active interactive prompt is a SESSION-WIDE display gate,
            // not a per-turn one. Closing the LAST active prompt lifts that
            // gate and reveals whatever turn is CURRENTLY tracked — it is
            // never "resuming" the turn the prompt happened to open under.
            // `turn_completed` is the one reason that can ALSO end a turn
            // outright, via a genuine tri-state (both requiring the SAME
            // Codex-native app-server capability contract on both opener
            // and terminal — a generic/Claude terminal never gets any of
            // this power just because its free-form reason/turn_id happen
            // to match):
            //   1. opener/terminal turn_id both non-blank, mutually
            //      consistent, AND equal to currentTurnID: the CURRENT turn
            //      itself completed — clear it, 0 resume (nothing to reveal).
            //   2. opener/terminal turn_id both non-blank, mutually
            //      consistent, but DIFFERENT from currentTurnID: an OLD
            //      turn's prompt completed — currentTurnID is untouched, and
            //      if this was the last active prompt, the gate lifts and
            //      resumes the turn that is CURRENTLY tracked (which may be
            //      a newer one that superseded the old turn while this
            //      prompt was still open).
            //   3. turn_id missing/blank on either side, opener/terminal
            //      turn_id inconsistent with each other, or either side is
            //      not Codex-native-capable: fail closed — only this exact
            //      lifecycle closes (already done above); neither ends the
            //      current turn nor resumes anything.
            if event.metadata?["reason"] == "turn_completed" {
                guard let opener,
                      Self.isCodexNativeAppServerCapable(opener),
                      Self.isCodexNativeAppServerCapable(event),
                      let openerTurnID = Self.normalizedTurnID(opener.metadata?["turn_id"]),
                      let terminalTurnID = Self.normalizedTurnID(event.metadata?["turn_id"]),
                      openerTurnID == terminalTurnID else {
                    // Case 3: fail closed.
                    return nil
                }
                if openerTurnID == state.currentTurnID {
                    // Case 1: the CURRENT turn completed.
                    state.currentTurnID = nil
                    return nil
                }
                // Case 2: an OLD turn's prompt completed — currentTurnID is
                // untouched; resume it if this closed the last active prompt.
                guard state.activePromptLifecycle.isEmpty,
                      let turnID = state.currentTurnID else {
                    return nil
                }
                // Bridge Phase C: the legacy resume must ALSO respect an
                // app-server semantic tombstone for this same turn ID — a
                // typed terminal admission only clears app-server control
                // state, never `currentTurnID` (a wholly separate
                // transcript-vendor field), so without this check a
                // corresponding ordinary anchor could still let this legacy
                // path resurrect Working for a turn control already closed.
                if let key = Self.appServerLogicalTurnKey(sessionID: event.sessionID, turnID: turnID, state: state),
                   state.appServerSemanticTombstones.contains(key) {
                    return nil
                }
                return makeResumeEventLocked(sessionID: event.sessionID,
                                             workspaceID: event.workspaceID,
                                             timestamp: event.timestamp,
                                             turnID: turnID,
                                             state: &state)
            }

            // Round 7C P0-C: `server_resolved` alone is a free-form string a
            // generic/Claude/unknown producer could trivially fake. Resume
            // additionally requires BOTH the opener AND the terminal to
            // satisfy the Codex-native app-server capability contract — a
            // non-Codex-native lifecycle only ever closes its prompt here,
            // never resumes Working. Same session-wide-gate semantics as
            // above: no turn_id correlation to currentTurnID is required —
            // closing the last active prompt reveals whichever turn is
            // CURRENTLY tracked.
            let policy = Self.resolvedReasonPolicy(event)
            guard policy.mayResumeWorking,
                  state.activePromptLifecycle.isEmpty,
                  let turnID = state.currentTurnID,
                  let opener,
                  Self.isCodexNativeAppServerCapable(opener),
                  Self.isCodexNativeAppServerCapable(event) else {
                return nil
            }
            // Bridge Phase C: same semantic-tombstone check as case 2 above.
            if let key = Self.appServerLogicalTurnKey(sessionID: event.sessionID, turnID: turnID, state: state),
               state.appServerSemanticTombstones.contains(key) {
                return nil
            }
            return makeResumeEventLocked(sessionID: event.sessionID,
                                         workspaceID: event.workspaceID,
                                         timestamp: event.timestamp,
                                         turnID: turnID,
                                         state: &state)
        default:
            break
        }
        return nil
    }

    // Mints and stores (but does not deliver — the caller schedules that) a
    // single fresh, cursor-safe, dedupe-safe resume event for `turnID`, using
    // the same publish-monotonic reservation logic the ordinary rebase path
    // uses. Must be called while already holding `queue`.
    private func makeResumeEventLocked(sessionID: String,
                                       workspaceID: String,
                                       timestamp: String,
                                       turnID: String,
                                       state: inout SessionState) -> AgentEvent {
        let reserved = reservedSeqBySessionID[sessionID] ?? transcriptSessionStartedSequence
        let highWater = state.storedSeqHighWater ?? transcriptSessionStartedSequence
        let resumeSeq = max(highWater, reserved) + 1
        reservedSeqBySessionID[sessionID] = resumeSeq
        state.storedSeqHighWater = max(state.storedSeqHighWater ?? resumeSeq, resumeSeq)
        let synthesized = AgentEvent(eventID: "thinking-resume:\(sessionID):\(resumeSeq)",
                                     seq: resumeSeq,
                                     vendor: "codex",
                                     workspaceID: workspaceID,
                                     sessionID: sessionID,
                                     timestamp: timestamp,
                                     type: .thinking,
                                     role: nil,
                                     text: nil,
                                     name: nil,
                                     input: nil,
                                     output: nil,
                                     toolCallID: nil,
                                     metadata: ["turn_id": turnID, "reason": "prompt_resolved_resume"])
        state.seenEventIDs.insert(synthesized.eventID)
        state.bufferedEvents.append(synthesized)
        if state.bufferedEvents.count > maxBufferedEvents {
            state.bufferedEvents.removeFirst(state.bufferedEvents.count - maxBufferedEvents)
        }
        return synthesized
    }

    // Subscriber-match + ordered-delivery scheduling for one already-stored
    // live event. Must be called while already holding `queue` (the ordered
    // enqueue onto deliveryQueue happens from inside the state queue so
    // delivery order equals store order — unchanged from the original
    // single-event publish path).
    private func scheduleDeliveryLocked(_ event: AgentEvent) {
        guard let effectiveEvent = effectiveEvent(event) else {
            return
        }
        let matchedIDs = subscribers.filter { _, subscriber in
            if let workspaceID = subscriber.workspaceID, workspaceID != effectiveEvent.workspaceID {
                return false
            }
            if let sessionID = subscriber.sessionID, sessionID != effectiveEvent.sessionID {
                return false
            }
            return true
        }.map(\.key)
        guard matchedIDs.isEmpty == false else {
            return
        }
        let envelope = AgentEventEnvelope(replay: false, event: effectiveEvent)
        deliveryQueue.async { [weak self] in
            guard let self else {
                return
            }
            let targets = self.queue.sync {
                matchedIDs.compactMap { self.subscribers[$0] }
            }
            self.preInvokeDeliveryHook?()
            for target in targets {
                guard target.gate.beginInvoke() else {
                    continue
                }
                target.sink(envelope)
                target.gate.endInvoke()
            }
        }
    }

    // Atomic historical replacement: the session/source that OWNS a
    // historical window replaces the Hub's historical state with the
    // window's freshly derived set — derivations that no longer hold (a
    // newer duplicate suppressed by an older line, a cross-page status)
    // are retracted, not merely appended around. Live storage, the live
    // high-water and subscribers are untouched.
    func replaceHistoricalEvents(sessionID: String, events: [AgentEvent], anchorSeq: Int? = nil) {
        queue.sync {
            var state = sessions[sessionID] ?? SessionState()
            // The replacement OWNS historical identity: dedupe is live
            // collision + THIS desired set — stale (possibly evicted)
            // historical IDs can never suppress a legitimate reconcile.
            let liveIDs = Set(state.bufferedEvents.map(\.eventID))
            var localSeen = Set<String>()
            var accepted: [AgentEvent] = []
            for event in events {
                // The replacement is OWNED by the named session: a wrong-
                // session event never enters any state.
                guard event.sessionID == sessionID else {
                    BridgeLogger.server.error("agent event hub rejected historical replacement event for foreign session event_id=\(event.eventID, privacy: .public) event_session=\(event.sessionID, privacy: .public) owner=\(sessionID, privacy: .public)")
                    continue
                }
                guard let highWater = state.storedSeqHighWater, event.seq < highWater else {
                    BridgeLogger.server.error("agent event hub rejected historical replacement event at/above live high-water event_id=\(event.eventID, privacy: .public) seq=\(event.seq, privacy: .public)")
                    continue
                }
                guard liveIDs.contains(event.eventID) == false,
                      localSeen.insert(event.eventID).inserted else {
                    continue
                }
                accepted.append(event)
            }
            accepted.sort { $0.seq < $1.seq }
            // The Hub's historical bound holds across replacements — and the
            // just-requested page (marked by the anchor) survives the trim:
            // the window sheds the end farther from the anchor.
            if accepted.count > maxBufferedEvents {
                let preTrim = accepted
                if let anchorSeq {
                    // The requested direction wins: keep the NEWEST events
                    // BELOW the anchor first (the page adjacent to the
                    // caller's cursor, so its next cursor advances without a
                    // gap), then fill any remaining room with events at or
                    // above the anchor.
                    let below = accepted.filter { $0.seq < anchorSeq }
                    let atOrAbove = accepted.filter { $0.seq >= anchorSeq }
                    let keptBelow = below.suffix(maxBufferedEvents)
                    let keptAbove = atOrAbove.prefix(maxBufferedEvents - keptBelow.count)
                    accepted = Array(keptBelow) + Array(keptAbove)
                } else {
                    accepted.removeFirst(accepted.count - maxBufferedEvents)
                }
                // Correlation safety: the trim never leaves HALF a lifecycle.
                // A kept opener whose closing event existed before the trim
                // but was dropped is dropped too (fail closed within the hard
                // bound) — a resolved prompt must not revive as active and a
                // command must not lose its derived summary.
                accepted = Self.droppingOpenersWithTrimmedClosures(kept: accepted, preTrim: preTrim)
                BridgeLogger.server.info("agent event hub bounded historical replacement session_id=\(sessionID, privacy: .public) kept=\(accepted.count, privacy: .public)")
            }
            state.historicalEvents = accepted
            state.historicalEventIDs = Set(accepted.map(\.eventID))
            sessions[sessionID] = state
        }
    }

    // Test-only: synchronously drains the ordered delivery queue so tests
    // can assert on delivered state without sleeping.
    func drainDeliveriesForTesting() {
        deliveryQueue.sync {}
    }

    private func effectiveEvent(_ event: AgentEvent?) -> AgentEvent? {
        guard let event else {
            return nil
        }
        guard let binding = sessionBindings[event.sessionID] else {
            return event
        }
        return Self.rewritten(event: event,
                              workspaceID: binding.workspaceID,
                              panelID: binding.panelID)
    }

    private static func rewritten(event: AgentEvent,
                                  workspaceID: String,
                                  panelID: String?) -> AgentEvent {
        var metadata = event.metadata ?? [:]
        if let panelID, !panelID.isEmpty {
            metadata["panel_id"] = panelID
        } else {
            metadata.removeValue(forKey: "panel_id")
        }
        return AgentEvent(eventID: event.eventID,
                          seq: event.seq,
                          vendor: event.vendor,
                          workspaceID: workspaceID,
                          sessionID: event.sessionID,
                          timestamp: event.timestamp,
                          type: event.type,
                          role: event.role,
                          text: event.text,
                          name: event.name,
                          input: event.input,
                          output: event.output,
                          toolCallID: event.toolCallID,
                          metadata: metadata.isEmpty ? nil : metadata,
                          payload: event.payload)
    }

    private func budgetLimitedEvents(_ events: [AgentEvent],
                                     maxBytes: Int?,
                                     prefersNewestEvents: Bool) -> [AgentEvent] {
        guard let maxBytes, maxBytes > 0 else {
            return events
        }

        let encoder = JSONEncoder()
        if prefersNewestEvents {
            var selected = [AgentEvent]()
            var accumulatedBytes = 0
            for event in events.reversed() {
                let candidate = budgetSafeEvent(event, maxBytes: maxBytes, encoder: encoder)
                let estimatedBytes = (try? encoder.encode(candidate).count) ?? 0
                if !selected.isEmpty, accumulatedBytes + estimatedBytes > maxBytes {
                    break
                }
                selected.append(candidate)
                accumulatedBytes += estimatedBytes
            }
            return selected.reversed()
        } else {
            var selected = [AgentEvent]()
            var accumulatedBytes = 0
            for event in events {
                let candidate = budgetSafeEvent(event, maxBytes: maxBytes, encoder: encoder)
                let estimatedBytes = (try? encoder.encode(candidate).count) ?? 0
                if !selected.isEmpty, accumulatedBytes + estimatedBytes > maxBytes {
                    break
                }
                selected.append(candidate)
                accumulatedBytes += estimatedBytes
            }
            return selected
        }
    }

    private func budgetSafeEvent(_ event: AgentEvent,
                                 maxBytes: Int,
                                 encoder: JSONEncoder) -> AgentEvent {
        let estimatedBytes = (try? encoder.encode(event).count) ?? 0
        guard estimatedBytes > maxBytes else {
            return event
        }

        var metadata = event.metadata ?? [:]
        metadata["tidey_truncated"] = "true"
        metadata["tidey_original_estimated_bytes"] = String(estimatedBytes)
        metadata["tidey_max_bytes"] = String(maxBytes)

        let placeholder = "內容超過這次載入的大小限制，已先顯示摘要。需要完整內容時請回到 Mac 端查看。"
        let text: String?
        let input: String?
        let output: String?

        switch event.type {
        case .toolResult:
            text = event.text == nil ? nil : placeholder
            input = event.input
            output = placeholder
        case .toolCall:
            text = event.text
            input = placeholder
            output = event.output
        default:
            text = placeholder
            input = event.input
            output = event.output
        }

        return AgentEvent(eventID: event.eventID,
                          seq: event.seq,
                          vendor: event.vendor,
                          workspaceID: event.workspaceID,
                          sessionID: event.sessionID,
                          timestamp: event.timestamp,
                          type: event.type,
                          role: event.role,
                          text: text,
                          name: event.name,
                          input: input,
                          output: output,
                          toolCallID: event.toolCallID,
                          metadata: metadata,
                          payload: event.payload)
    }

    // MARK: - App-server Working control admission (Bridge Phase C)
    //
    // Independent typed pre-admission for Codex app-server internal-activity
    // Working control — a separate state machine from the transcript-vendor
    // Working/prompt fold above (`currentTurnID`/`suppressedEventIDs`/the
    // anchor+continuation reason-string matching), keyed by
    // `AppServerLogicalTurnKey`/`AppServerOwnerKey` instead of eventID. A
    // sequence number is minted ONLY when a wire event is actually stored,
    // which only ever happens after admission succeeded — an idempotent
    // no-op add-owner is an ACCEPTED admission with zero wire events (see
    // `AppServerWorkingControlAdmission`), not a rejection. A genuine
    // rejection (semantic tombstone, wrong/different active trajectory, a
    // retired owner, an incarnation mismatch, or a root/generation/attach
    // rejection the Syncer already enforced before ever calling this) has
    // zero effect on `reservedSeqBySessionID` / `storedSeqHighWater` either
    // way.

    // Test-only: fires at the very TOP of `admitAppServerWorkingControl`,
    // before any guard — lets a test prove a CALLER-SIDE fence (e.g. the
    // Syncer's own attach-scoped `retired`/generation checks) rejected an
    // observation before it ever reached the Hub at all, as opposed to the
    // observation reaching the Hub and being rejected there (identity
    // mismatch, incarnation fence, semantic/retired-owner tombstone) —
    // those two failure modes are otherwise indistinguishable from the
    // returned `AppServerWorkingControlAdmission` alone.
    var admissionAttemptHook: ((AppServerLogicalTurnKey, CodexAppServerWorkingControlEvent) -> Void)?

    @discardableResult
    func admitAppServerWorkingControl(logical: AppServerLogicalTurnKey,
                                      ownerKey: AppServerOwnerKey,
                                      workspaceID: String,
                                      observation: CodexAppServerWorkingControlEvent) -> AppServerWorkingControlAdmission {
        admissionAttemptHook?(logical, observation)
        // Identity fail-closed: the owner must be scoped to exactly this
        // logical turn, and the observation's own embedded thread/turn IDs
        // (trimmed) must equal this logical turn's root/turn — a caller
        // passing a mismatched `logical`/`ownerKey` pair, or an observation
        // whose own IDs disagree with the key it was filed under, is
        // rejected outright rather than silently trusted.
        guard ownerKey.logical == logical,
              Self.observationIdentityMatches(observation, logical: logical) else {
            return AppServerWorkingControlAdmission(accepted: false, events: [], ownerContextEffect: .none)
        }

        var storedEvents: [AgentEvent] = []
        // Independent from `storedEvents.isEmpty` — see
        // `AppServerWorkingControlAdmission`'s doc comment. Set true ONLY
        // once every rejection guard for the matched branch has passed.
        var accepted = false
        var ownerContextEffect: AppServerOwnerContextEffect = .none
        queue.sync {
            var state = sessions[logical.sessionID] ?? SessionState()
            defer { sessions[logical.sessionID] = state }

            // Incarnation fence: admission requires this session to have an
            // established control incarnation (via
            // `beginAppServerControlIncarnation`) EXACTLY matching this
            // logical turn's (epoch, root) — before any state
            // mutation/seq. No incarnation yet, a stale epoch, or a stale
            // root all fail closed. This is what makes a true incarnation
            // rotation (Section 8) actually isolate a late straggler from
            // the OLD incarnation: it can never re-establish state or
            // consume a seq after `beginAppServerControlIncarnation` moved
            // on.
            guard state.appServerControlIncarnation == AppServerControlIncarnation(epoch: logical.epoch, rootThreadID: logical.rootThreadID) else {
                return
            }

            switch observation {
            case let .turnStarted(_, _, time):
                guard state.appServerSemanticTombstones.contains(logical) == false,
                      state.appServerRetiredOwnerTombstones.contains(ownerKey) == false else {
                    return
                }
                accepted = true
                ownerContextEffect = .setOwner(ownerKey)
                if state.appServerCurrentLogicalTurn == logical {
                    // Idempotent: the same logical turn re-announced — add
                    // this owner only, no second open event.
                    state.appServerActiveOwners.insert(ownerKey)
                    state.appServerPreferredOwner = ownerKey
                    return
                }
                let isExactSuspendedReopen = state.appServerSuspendedLogicalTurn == logical
                // A different trajectory may supersede ONLY through this
                // authoritative start — whichever trajectory (current OR
                // suspended) currently occupies a DIFFERENT logical key is
                // tombstoned against a late reopen. Exact reopen of the
                // SAME suspended key is not a supersession.
                if let old = state.appServerCurrentLogicalTurn, old != logical {
                    state.appServerSemanticTombstones.insert(old)
                }
                if let oldSuspended = state.appServerSuspendedLogicalTurn, oldSuspended != logical {
                    state.appServerSemanticTombstones.insert(oldSuspended)
                }
                state.appServerCurrentLogicalTurn = logical
                state.appServerSuspendedLogicalTurn = nil
                state.appServerSuspendedLastOwner = nil
                state.appServerActiveOwners = [ownerKey]
                state.appServerPreferredOwner = ownerKey
                // An exact reopen of a suspended trajectory is a DISTINCT
                // edge from its original open (a fresh owner is taking over
                // a turn the client's snapshot was already cleared for) —
                // it must not dedupe-coalesce against the original
                // "turn_start" edge, or the client would never see Working
                // resume.
                let edgeKind = isExactSuspendedReopen ? "turn_start:reopen:\(ownerKey.runtimeGeneration):\(ownerKey.ownerToken)" : "turn_start"
                if let event = storeAppServerControlEventLocked(logical: logical,
                                                                 ownerKey: ownerKey,
                                                                 workspaceID: workspaceID,
                                                                 workingPhase: "open",
                                                                 edgeKind: edgeKind,
                                                                 reason: "turn_started",
                                                                 activity: nil,
                                                                 terminalScope: nil,
                                                                 time: time,
                                                                 state: &state) {
                    storedEvents.append(event)
                }

            case let .internalActivityStarted(_, _, itemID, kind, time),
                 let .internalActivityObserved(_, _, itemID, kind, time):
                guard state.appServerSemanticTombstones.contains(logical) == false,
                      state.appServerRetiredOwnerTombstones.contains(ownerKey) == false else {
                    return
                }
                var openedNow = false
                var isExactSuspendedReopen = false
                if state.appServerCurrentLogicalTurn == logical {
                    // Already the live trajectory — plain continuation.
                } else if state.appServerCurrentLogicalTurn == nil {
                    if let suspended = state.appServerSuspendedLogicalTurn {
                        guard suspended == logical else {
                            // Reject activity claimed for a DIFFERENT
                            // trajectory while A remains suspended — A is
                            // NOT tombstoned here (only an authoritative
                            // turnStarted may supersede a suspended trajectory).
                            return
                        }
                        // Exact reopen of the suspended trajectory via activity.
                        state.appServerSuspendedLogicalTurn = nil
                        state.appServerSuspendedLastOwner = nil
                        state.appServerCurrentLogicalTurn = logical
                        openedNow = true
                        isExactSuspendedReopen = true
                    } else {
                        // No trajectory at all: synthesize exactly one
                        // canonical opener, then this continuation.
                        state.appServerCurrentLogicalTurn = logical
                        openedNow = true
                    }
                } else {
                    // A DIFFERENT trajectory is live — reject.
                    return
                }
                accepted = true
                ownerContextEffect = .setOwner(ownerKey)
                state.appServerActiveOwners.insert(ownerKey)
                state.appServerPreferredOwner = ownerKey
                // An exact reopen of a suspended trajectory via activity
                // must NEVER reuse the plain "synthetic_open" edge — if the
                // original open was ALSO a synthetic opener (the turn was
                // itself activity-opened, never a turnStarted), that exact
                // edge ID was already admitted before the disconnect and
                // would dedupe to nothing here, leaving `current` live with
                // no visible open/snapshot at all. A fresh, owner-scoped
                // edge guarantees this reopen is always independently
                // admissible and always updates the snapshot — even when
                // the triggering activity's OWN continuation edge (same
                // kind+itemID as before disconnect) separately dedupes.
                let openEdgeKind = isExactSuspendedReopen ? "synthetic_open:reopen:\(ownerKey.runtimeGeneration):\(ownerKey.ownerToken)" : "synthetic_open"
                if openedNow, let opener = storeAppServerControlEventLocked(logical: logical,
                                                                            ownerKey: ownerKey,
                                                                            workspaceID: workspaceID,
                                                                            workingPhase: "open",
                                                                            edgeKind: openEdgeKind,
                                                                            reason: "turn_started",
                                                                            activity: nil,
                                                                            terminalScope: nil,
                                                                            time: time,
                                                                            state: &state) {
                    // The canonical opener is a real, independently
                    // deliverable event — same as the continuation below,
                    // not a side effect discarded after minting a seq for
                    // it. Subscribers must see BOTH, in order, on a
                    // continuous cursor.
                    storedEvents.append(opener)
                }
                if let continuation = storeAppServerControlEventLocked(logical: logical,
                                                                       ownerKey: ownerKey,
                                                                       workspaceID: workspaceID,
                                                                       workingPhase: "continue",
                                                                       edgeKind: "activity:\(kind.rawValue):\(itemID)",
                                                                       reason: "internal_activity",
                                                                       activity: (itemID: itemID, kind: kind),
                                                                       terminalScope: nil,
                                                                       time: time,
                                                                       state: &state) {
                    storedEvents.append(continuation)
                }

            case let .turnTerminal(_, _, rawStatus, time):
                // Tombstone FIRST — including terminal-before-start: even if
                // no event is stored below, the logical turn can never
                // reopen after this.
                state.appServerSemanticTombstones.insert(logical)
                // A semantic-terminal tombstone admission is ALWAYS
                // accepted, even terminal-before-start (which never matches
                // a current/suspended trajectory and so never emits a wire
                // event) — the tombstone bookkeeping itself is the
                // admission.
                accepted = true
                // Terminal admission NEVER sets an owner active — it only
                // ever tells the caller to CLEAR its mapping, and only if
                // that mapping currently points at this exact logical key
                // (a late terminal for an old A while the caller has
                // already moved on to B must leave B's mapping untouched;
                // terminal-before-start has no prior mapping to clear
                // either way, so this is a safe no-op there too).
                ownerContextEffect = .clearIfMatching(logical)
                guard state.appServerCurrentLogicalTurn == logical || state.appServerSuspendedLogicalTurn == logical else {
                    // Terminal A can never clear an unrelated turn B.
                    return
                }
                state.appServerCurrentLogicalTurn = nil
                state.appServerSuspendedLogicalTurn = nil
                state.appServerSuspendedLastOwner = nil
                state.appServerActiveOwners = state.appServerActiveOwners.filter { $0.logical != logical }
                state.appServerLatestControlSnapshot = nil
                if let event = storeAppServerControlEventLocked(logical: logical,
                                                                 ownerKey: ownerKey,
                                                                 workspaceID: workspaceID,
                                                                 workingPhase: "terminal",
                                                                 edgeKind: "semantic_terminal",
                                                                 reason: Self.appServerTerminalReason(rawStatus: rawStatus),
                                                                 activity: nil,
                                                                 terminalScope: "semantic_turn",
                                                                 time: time,
                                                                 state: &state) {
                    storedEvents.append(event)
                }

            case let .resumeSnapshot(_, _, time):
                // Base admission mirrors turnStarted's idempotent/open rule.
                // The REVISION FENCE (exact-one live turn + unchanged since
                // snapshot) is enforced upstream, before this is ever
                // called — see `seedActiveTurnFromResumeSnapshot`.
                guard state.appServerSemanticTombstones.contains(logical) == false,
                      state.appServerRetiredOwnerTombstones.contains(ownerKey) == false else {
                    return
                }
                if state.appServerCurrentLogicalTurn == logical {
                    accepted = true
                    ownerContextEffect = .setOwner(ownerKey)
                    state.appServerActiveOwners.insert(ownerKey)
                    state.appServerPreferredOwner = ownerKey
                    return
                }
                guard state.appServerCurrentLogicalTurn == nil else {
                    // A resume snapshot can never supersede a live turn —
                    // only an authoritative turnStarted may.
                    return
                }
                if let suspended = state.appServerSuspendedLogicalTurn, suspended != logical {
                    // A resume snapshot can never overwrite a DIFFERENT
                    // suspended trajectory — A stays suspended, untouched
                    // (no tombstone; only an authoritative turnStarted may
                    // supersede a suspended trajectory).
                    return
                }
                accepted = true
                ownerContextEffect = .setOwner(ownerKey)
                state.appServerCurrentLogicalTurn = logical
                state.appServerSuspendedLogicalTurn = nil
                state.appServerSuspendedLastOwner = nil
                state.appServerActiveOwners = [ownerKey]
                state.appServerPreferredOwner = ownerKey
                if let event = storeAppServerControlEventLocked(logical: logical,
                                                                 ownerKey: ownerKey,
                                                                 workspaceID: workspaceID,
                                                                 workingPhase: "open",
                                                                 edgeKind: "resume:\(ownerKey.runtimeGeneration):\(ownerKey.ownerToken)",
                                                                 reason: "resume_snapshot",
                                                                 activity: nil,
                                                                 terminalScope: nil,
                                                                 time: time,
                                                                 state: &state) {
                    storedEvents.append(event)
                }

            case .ownerDisconnected:
                // Disconnect has its own explicit-owner-key entry point —
                // see `retireAppServerOwner`. An owner-disconnect
                // observation carries no turn identity by itself and must
                // never be routed through here.
                return
            }

            for event in storedEvents {
                scheduleDeliveryLocked(event)
            }
        }
        for event in storedEvents {
            postStoreDeliveryHook?(event)
        }
        return AppServerWorkingControlAdmission(accepted: accepted, events: storedEvents, ownerContextEffect: ownerContextEffect)
    }

    // An observation's own embedded thread/turn IDs (trimmed) must equal
    // the logical turn key it is being admitted under. `.ownerDisconnected`
    // carries no turn identity and is exempt (it never reaches the switch
    // above by key).
    private static func observationIdentityMatches(_ observation: CodexAppServerWorkingControlEvent,
                                                    logical: AppServerLogicalTurnKey) -> Bool {
        func matches(_ threadID: String, _ turnID: String) -> Bool {
            threadID.trimmingCharacters(in: .whitespacesAndNewlines) == logical.rootThreadID &&
                turnID.trimmingCharacters(in: .whitespacesAndNewlines) == logical.turnID
        }
        switch observation {
        case let .turnStarted(threadID, turnID, _):
            return matches(threadID, turnID)
        case let .internalActivityStarted(threadID, turnID, _, _, _):
            return matches(threadID, turnID)
        case let .internalActivityObserved(threadID, turnID, _, _, _):
            return matches(threadID, turnID)
        case let .turnTerminal(threadID, turnID, _, _):
            return matches(threadID, turnID)
        case let .resumeSnapshot(threadID, turnID, _):
            return matches(threadID, turnID)
        case .ownerDisconnected:
            return true
        }
    }

    // Explicit-owner-key disconnect entry point (never infers "the current
    // turn"): `ownerKey` embeds the EXACT logical turn this owner was
    // observing, per its own attach-time context — so a late disconnect
    // from a stale/superseded owner can only ever retire that owner's own
    // turn, never a replacement generation's turn, even if both happen to
    // share the same session/root.
    @discardableResult
    func retireAppServerOwner(_ ownerKey: AppServerOwnerKey,
                              workspaceID: String,
                              reason: CodexAppServerOwnerDisconnectReason,
                              time: String) -> AgentEvent? {
        var storedEvent: AgentEvent?
        queue.sync {
            var state = sessions[ownerKey.logical.sessionID] ?? SessionState()
            defer { sessions[ownerKey.logical.sessionID] = state }

            guard state.appServerRetiredOwnerTombstones.contains(ownerKey) == false else {
                // Idempotent: a duplicate disconnect for the same owner is a
                // no-op, never a second terminal.
                return
            }
            state.appServerRetiredOwnerTombstones.insert(ownerKey)
            guard state.appServerActiveOwners.contains(ownerKey) else {
                // This owner was never tracked active (never observed a
                // start) or was already implicitly dropped by a semantic
                // terminal — no UI effect.
                return
            }
            state.appServerActiveOwners.remove(ownerKey)
            // Only affects the EXACT logical turn this owner was attached
            // to — a replacement generation's turn (even for the same
            // session/root) is untouched regardless of what "current" is.
            guard state.appServerCurrentLogicalTurn == ownerKey.logical else {
                return
            }
            let otherOwnersRemain = state.appServerActiveOwners.contains { $0.logical == ownerKey.logical }
            guard otherOwnersRemain == false else {
                // Another live owner remains for the SAME logical turn — no
                // UI terminal. If the retiring owner was the deterministic
                // preferred owner, fall back to a DETERMINISTIC pick among
                // the remaining owners (lexicographically smallest
                // ownerToken) — never left dangling on a removed key, and
                // never re-derived from Set iteration order at read time.
                if state.appServerPreferredOwner == ownerKey {
                    state.appServerPreferredOwner = state.appServerActiveOwners
                        .filter { $0.logical == ownerKey.logical }
                        .sorted { $0.ownerToken < $1.ownerToken }
                        .first
                }
                return
            }
            // Last owner for this logical turn: owner-scoped terminal,
            // SUSPEND (not tombstone) so an exact revision-fenced resume may
            // still reopen it.
            state.appServerCurrentLogicalTurn = nil
            state.appServerSuspendedLogicalTurn = ownerKey.logical
            state.appServerSuspendedLastOwner = ownerKey
            state.appServerLatestControlSnapshot = nil
            storedEvent = storeAppServerControlEventLocked(logical: ownerKey.logical,
                                                            ownerKey: ownerKey,
                                                            workspaceID: workspaceID,
                                                            workingPhase: "terminal",
                                                            edgeKind: "owner_terminal:\(ownerKey.runtimeGeneration):\(ownerKey.ownerToken)",
                                                            reason: reason.rawValue,
                                                            activity: nil,
                                                            terminalScope: "owner",
                                                            time: time,
                                                            state: &state)
            if let storedEvent {
                scheduleDeliveryLocked(storedEvent)
            }
        }
        if let storedEvent {
            postStoreDeliveryHook?(storedEvent)
        }
        return storedEvent
    }

    // Constructs, dedupes (exact-duplicate coalesce via a deterministic
    // eventID), sequences, and stores ONE control-only AgentEvent — text/
    // name/input/output/toolCallID/payload are ALWAYS nil, so no tool card
    // can ever be created from it. Must be called while already holding
    // `queue`. Prompt precedence: an active interactive prompt hides an
    // open/continue control event outright (no store, no snapshot update) —
    // a terminal is never hidden (a real end is never suppressed).
    private func storeAppServerControlEventLocked(logical: AppServerLogicalTurnKey,
                                                   ownerKey: AppServerOwnerKey,
                                                   workspaceID: String,
                                                   workingPhase: String,
                                                   edgeKind: String,
                                                   reason: String,
                                                   activity: (itemID: String, kind: CodexAppServerInternalActivityKind)?,
                                                   terminalScope: String?,
                                                   time: String,
                                                   state: inout SessionState) -> AgentEvent? {
        // `edgeKind` fully discriminates WHICH edge this is (turn_start vs
        // resume vs synthetic_open vs a specific activity+kind+item vs
        // semantic_terminal vs an owner-scoped terminal keyed by
        // generation+token) — two structurally different edges for the same
        // logical turn must never collide onto the same eventID (a
        // turnStarted open and a LATER resumeSnapshot open for the same
        // turn are different edges and both must be independently
        // deliverable; only a literal retry of the SAME edge coalesces).
        let eventID = "codex-app-server-control:\(logical.sessionID):\(logical.epoch):\(logical.rootThreadID):\(logical.turnID):\(workingPhase):\(edgeKind)"
        guard state.appServerAdmittedEdgeIDs.contains(eventID) == false else {
            // Exact duplicate observation of the SAME edge — coalesce, no
            // second store, REGARDLESS of whether the original admission
            // was ever wire-published (see the prompt-hiding branch below).
            // Uses the dedicated, never-trimmed appServerAdmittedEdgeIDs
            // set, NOT seenEventIDs (which is rebuilt against
            // bufferedEvents on capacity overflow and would forget an
            // evicted control ID).
            return nil
        }
        // Mark this edge admitted BEFORE the prompt-hiding check below —
        // typed admission (the state-machine transition) happened
        // regardless of whether the resulting event is actually
        // wire-published. A hidden edge still consumed its one-time
        // admission: an exact repeat of the SAME edge after the hiding
        // prompt closes (validly or not) must never be treated as fresh and
        // wrongly re-admitted/re-resumed.
        state.appServerAdmittedEdgeIDs.insert(eventID)

        if workingPhase != "terminal", hasAnyActiveInteractivePrompt(in: state) {
            // Hidden: admitted but never wire-published — no seq minted, no
            // store, no snapshot update, no delivery/postHook.
            return nil
        }

        let reserved = reservedSeqBySessionID[logical.sessionID] ?? transcriptSessionStartedSequence
        let highWater = state.storedSeqHighWater ?? transcriptSessionStartedSequence
        let seq = max(highWater, reserved) + 1
        reservedSeqBySessionID[logical.sessionID] = seq
        state.storedSeqHighWater = max(state.storedSeqHighWater ?? seq, seq)

        var metadata: [String: String] = [
            "source": "codex_app_server_working_control",
            "tidey_control": "working",
            "working_phase": workingPhase,
            "reason": reason,
            "thread_id": logical.rootThreadID,
            "root_thread_id": logical.rootThreadID,
            "turn_id": logical.turnID,
            "app_server_epoch": logical.epoch,
            "runtime_generation": ownerKey.runtimeGeneration,
            "owner_token": ownerKey.ownerToken,
        ]
        if let activity {
            metadata["activity_id"] = activity.itemID
            metadata["kind"] = activity.kind.rawValue
        }
        if let terminalScope {
            metadata["terminal_scope"] = terminalScope
        }

        let event = AgentEvent(eventID: eventID,
                               seq: seq,
                               vendor: "codex",
                               workspaceID: workspaceID,
                               sessionID: logical.sessionID,
                               timestamp: time,
                               type: workingPhase == "terminal" ? .assistantFinal : .thinking,
                               role: nil,
                               text: nil,
                               name: nil,
                               input: nil,
                               output: nil,
                               toolCallID: nil,
                               metadata: metadata)
        state.seenEventIDs.insert(eventID)
        state.bufferedEvents.append(event)
        if state.bufferedEvents.count > maxBufferedEvents {
            state.bufferedEvents.removeFirst(state.bufferedEvents.count - maxBufferedEvents)
        }
        if workingPhase != "terminal" {
            state.appServerLatestControlSnapshot = event
        }
        return event
    }

    // Scoped app-server control incarnation rotation: reattaching with the
    // SAME (epoch, root) — a runtime generation replacement for the same
    // underlying process/root — is a no-op that preserves every existing
    // control field untouched. Only a genuinely different epoch or root (a
    // true process restart or authoritative root change) clears
    // current/suspended/owners/tombstones/snapshot/dedupe. Must be called
    // BEFORE any admission for the new attach, typically once per Syncer
    // `attach(record:)`.
    func beginAppServerControlIncarnation(sessionID: String, epoch: String, rootThreadID: String) {
        queue.sync {
            var state = sessions[sessionID] ?? SessionState()
            let incarnation = AppServerControlIncarnation(epoch: epoch, rootThreadID: rootThreadID)
            guard state.appServerControlIncarnation != incarnation else {
                // Same incarnation: no-op, preserve everything.
                return
            }
            state.appServerControlIncarnation = incarnation
            state.appServerCurrentLogicalTurn = nil
            state.appServerSuspendedLogicalTurn = nil
            state.appServerSuspendedLastOwner = nil
            state.appServerActiveOwners.removeAll()
            state.appServerPreferredOwner = nil
            state.appServerSemanticTombstones.removeAll()
            state.appServerRetiredOwnerTombstones.removeAll()
            state.appServerLatestControlSnapshot = nil
            state.appServerAdmittedEdgeIDs.removeAll()

            // True rotation PURGES every stored control wire artifact for
            // this session — read-time incarnation filtering (see
            // `isVisibleUnderCurrentIncarnation`) is not enough on its own:
            // a process/socket (epoch, root) tuple CAN be reused
            // (A -> B -> A). Without a physical purge here, a later
            // generation-3 A's own control events would sit ALONGSIDE
            // generation-1 A's untouched buffered/historical events, and a
            // mere read-time filter comparing against the CURRENT
            // incarnation would then WRONGLY re-admit gen-1's stale events
            // as visible (their embedded epoch/root would match the new
            // current incarnation by construction, since it's the SAME
            // tuple reused). Ordinary/transcript events are completely
            // unaffected. `storedSeqHighWater` and every seq reservation
            // are NEVER rolled back here — only forward-looking identity
            // bookkeeping (`seenEventIDs`/`historicalEventIDs`) is rebuilt
            // to drop the purged IDs, so a later same-eventID admission
            // from a NEW generation is never mistaken for an old duplicate.
            let isOldControlEvent: (AgentEvent) -> Bool = { $0.metadata?["source"] == "codex_app_server_working_control" }
            let removedBufferedIDs = Set(state.bufferedEvents.filter(isOldControlEvent).map(\.eventID))
            let removedHistoricalIDs = Set(state.historicalEvents.filter(isOldControlEvent).map(\.eventID))
            if removedBufferedIDs.isEmpty == false {
                state.bufferedEvents.removeAll(where: isOldControlEvent)
                state.seenEventIDs.subtract(removedBufferedIDs)
            }
            if removedHistoricalIDs.isEmpty == false {
                state.historicalEvents.removeAll(where: isOldControlEvent)
                state.historicalEventIDs.subtract(removedHistoricalIDs)
            }
            sessions[sessionID] = state
        }
    }

    private static func appServerTerminalReason(rawStatus: String) -> String {
        switch rawStatus {
        case "failed":
            return "turn_failed"
        case "interrupted":
            return "turn_interrupted"
        case "aborted":
            return "turn_aborted"
        default:
            return "turn_completed"
        }
    }

    // Test/debug-only: current app-server control admission snapshot for a
    // session, independent of the ordinary event stream.
    func appServerControlDebugSnapshotForTesting(sessionID: String) -> (currentLogicalTurn: AppServerLogicalTurnKey?,
                                                                        suspendedLogicalTurn: AppServerLogicalTurnKey?,
                                                                        activeOwners: Set<AppServerOwnerKey>,
                                                                        semanticTombstones: Set<AppServerLogicalTurnKey>,
                                                                        retiredOwnerTombstones: Set<AppServerOwnerKey>,
                                                                        latestSnapshot: AgentEvent?) {
        queue.sync {
            let state = sessions[sessionID] ?? SessionState()
            return (state.appServerCurrentLogicalTurn,
                    state.appServerSuspendedLogicalTurn,
                    state.appServerActiveOwners,
                    state.appServerSemanticTombstones,
                    state.appServerRetiredOwnerTombstones,
                    state.appServerLatestControlSnapshot)
        }
    }
}

private extension AgentEvent {
    // Identity-preserving seq rebase: the eventID (and therefore dedupe,
    // snapshot overlay, and lifecycle-token semantics) stays the same.
    func withSeq(_ seq: Int) -> AgentEvent {
        AgentEvent(eventID: eventID,
                   seq: seq,
                   vendor: vendor,
                   workspaceID: workspaceID,
                   sessionID: sessionID,
                   timestamp: timestamp,
                   type: type,
                   role: role,
                   text: text,
                   name: name,
                   input: input,
                   output: output,
                   toolCallID: toolCallID,
                   metadata: metadata,
                   payload: payload)
    }
}
