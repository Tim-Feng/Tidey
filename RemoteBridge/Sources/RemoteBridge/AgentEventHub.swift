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

    private final class DeliveryExecutor {
        private let queueKey = DispatchSpecificKey<Void>()
        let queue = DispatchQueue(label: "com.tidey.remote-bridge.agent-event-hub.delivery")

        init() {
            queue.setSpecific(key: queueKey, value: ())
        }

        var isCurrent: Bool {
            DispatchQueue.getSpecific(key: queueKey) != nil
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
    private let deliveryExecutor = DeliveryExecutor()
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

            if let sessionID {
                if let state = sessions[sessionID] {
                    matchingEvents = state.allStoredEvents
                        .compactMap { effectiveEvent($0) }
                        .filter { event in
                            guard event.sessionID == sessionID,
                                  event.workspaceID == workspaceID else {
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
                        .sorted { $0.seq < $1.seq }
                } else {
                    matchingEvents = []
                }
            } else {
                matchingEvents = sessions.values
                    .flatMap(\.allStoredEvents)
                    .compactMap { effectiveEvent($0) }
                    .filter { event in
                        guard event.workspaceID == workspaceID else {
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
                    .sorted { lhs, rhs in
                        if lhs.timestamp == rhs.timestamp {
                            return lhs.seq < rhs.seq
                        }
                        return lhs.timestamp < rhs.timestamp
                    }
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
            return FetchResult(events: slice, oldestSeq: oldestSeq, newestSeq: newestSeq, hasMore: hasMore)
        }
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
                return true
            }
            .sorted { lhs, rhs in
                if lhs.sessionID == rhs.sessionID {
                    return lhs.seq < rhs.seq
                }
                if lhs.timestamp == rhs.timestamp {
                    return lhs.seq < rhs.seq
                }
                return lhs.timestamp < rhs.timestamp
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
    // above the persisted live high-water.
    func nextSyntheticSeq(sessionID: String) -> Int {
        queue.sync {
            let stored = sessions[sessionID]?.storedSeqHighWater ?? transcriptSessionStartedSequence
            let reserved = reservedSeqBySessionID[sessionID] ?? transcriptSessionStartedSequence
            let next = max(stored, reserved) + 1
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
    // products rebase above the old stream).
    func beginNewSourceEpoch(sessionID: String) {
        queue.sync {
            guard var state = sessions[sessionID] else {
                return
            }
            state.bufferedEvents.removeAll()
            state.historicalEvents.removeAll()
            state.historicalEventIDs.removeAll()
            state.seenEventIDs.removeAll()
            sessions[sessionID] = state
        }
    }

    func latestInteractivePromptResolvedEvent(workspaceID: String,
                                              sessionID: String,
                                              promptID: String,
                                              lifecycleToken: String? = nil,
                                              openerRequiresCapability: Bool? = nil) -> AgentEvent? {
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
                    if lifecycleToken != nil || openerRequiresCapability != nil {
                        return AgentInteractivePromptSidebarMessages.terminalCloses(
                            openerLifecycleToken: lifecycleToken,
                            openerRequiresCapability: openerRequiresCapability ?? false,
                            terminal: event
                        )
                    }
                    // Preserve the pre-capability lookup for callers that do
                    // not yet supply lifecycle identity. Capability-aware
                    // callers pass the explicit flag and fail closed.
                    return true
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

    func publish(_ event: AgentEvent, deliverToSubscribers: Bool = true, storage: PublishStorage = .liveForward) {
        var event = event
        let deliveryCompletion: DispatchSemaphore? = queue.sync {
            var state = sessions[event.sessionID] ?? SessionState()
            if state.seenEventIDs.contains(event.eventID) || state.historicalEventIDs.contains(event.eventID) {
                return nil
            }

            switch storage {
            case .liveForward:
                state.seenEventIDs.insert(event.eventID)
                if state.seenEventIDs.count > maxSeenEventIDs {
                    state.seenEventIDs = Set(state.bufferedEvents.map(\.eventID))
                    state.seenEventIDs.insert(event.eventID)
                }

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
                    return nil
                }
                state.historicalEventIDs.insert(event.eventID)
                state.historicalEvents.append(event)
                state.historicalEvents.sort { $0.seq < $1.seq }
                if state.historicalEvents.count > maxBufferedEvents {
                    state.historicalEvents.removeFirst(state.historicalEvents.count - maxBufferedEvents)
                    state.historicalEventIDs = Set(state.historicalEvents.map(\.eventID))
                }
                sessions[event.sessionID] = state
                return nil
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
            sessions[event.sessionID] = state

            // Historical storage NEVER reaches live subscribers, regardless
            // of the delivery flag.
            guard deliverToSubscribers else {
                return nil
            }
            guard let effectiveEvent = effectiveEvent(event) else {
                return nil
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
                return nil
            }

            // The ordered drain: the enqueue happens inside the state queue,
            // so delivery order equals store order. Resolve sinks again at
            // drain time so an already-queued delivery observes unsubscribe.
            let envelope = AgentEventEnvelope(replay: false, event: effectiveEvent)
            let completion = DispatchSemaphore(value: 0)
            deliveryExecutor.queue.async { [weak self] in
                defer { completion.signal() }
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
            return completion
        }

        postStoreDeliveryHook?(event)
        if deliveryExecutor.isCurrent == false {
            deliveryCompletion?.wait()
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
            var replacementIDs = Set<String>()
            var accepted = [AgentEvent]()
            for event in events {
                guard event.sessionID == sessionID else {
                    BridgeLogger.server.error("agent event hub rejected historical replacement event for foreign session event_id=\(event.eventID, privacy: .public) event_session=\(event.sessionID, privacy: .public) owner=\(sessionID, privacy: .public)")
                    continue
                }
                guard let highWater = state.storedSeqHighWater, event.seq < highWater else {
                    BridgeLogger.server.error("agent event hub rejected historical replacement event at/above live high-water event_id=\(event.eventID, privacy: .public) seq=\(event.seq, privacy: .public)")
                    continue
                }
                guard liveIDs.contains(event.eventID) == false,
                      replacementIDs.insert(event.eventID).inserted else {
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
        guard deliveryExecutor.isCurrent == false else {
            return
        }
        deliveryExecutor.queue.sync {}
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
