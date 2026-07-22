import Foundation

enum HistoricalOpenerResolution: Equatable, Sendable {
    case visibleTerminal(eventID: String, sequence: Int)
    case silentConsumer(sequence: Int)

    var sequence: Int {
        switch self {
        case .visibleTerminal(_, let sequence), .silentConsumer(let sequence):
            return sequence
        }
    }
}

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
        var bufferedEvents = [AgentEvent]()
        var historicalEvents = [AgentEvent]()
        var historicalEventIDs = Set<String>()
        var historicalOpenerResolutions = [String: HistoricalOpenerResolution]()
        var historicalClosureCoverageIsComplete = true
        var allStoredEvents: [AgentEvent] { historicalEvents + bufferedEvents }
        var latestSessionStarted: AgentEvent?
        var isActive = false
        // Persists beyond buffer eviction so a late unseen event cannot fall
        // behind a cursor that clients have already advanced.
        var storedSeqHighWater: Int?
    }

    private struct SessionBinding {
        let workspaceID: String
        let panelID: String?
    }

    private let queue = DispatchQueue(label: "com.tidey.remote-bridge.agent-event-hub")
    private let deliveryExecutor = DeliveryExecutor()
    var postStoreDeliveryHook: ((AgentEvent) -> Void)?
    var preInvokeDeliveryHook: (() -> Void)?
    var unsubscribeCancelWaitHook: (() -> Void)?
    private var subscribers = [UUID: Subscriber]()
    private var sessions = [String: SessionState]()
    private var sessionBindings = [String: SessionBinding]()
    private var reservedSeqBySessionID = [String: Int]()
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
                    let storedEvents = state.allStoredEvents.compactMap { effectiveEvent($0) }
                    let cursorEligibleEventIDs = Set(storedEvents.lazy.filter { event in
                        beforeSeq.map { event.seq < $0 } ?? true
                    }.map(\.eventID))
                    matchingEvents = storedEvents
                        .filter { event in
                            guard event.sessionID == sessionID,
                                  event.workspaceID == workspaceID else {
                                return false
                            }
                            if requiresHistoricalClosureCoverage(event),
                               state.historicalClosureCoverageIsComplete == false {
                                return false
                            }
                            if let beforeSeq {
                                return event.seq < beforeSeq
                                    && historicalOpenerIsVisible(
                                        event,
                                        state: state,
                                        cursorEligibleEventIDs: cursorEligibleEventIDs,
                                        beforeSeq: beforeSeq)
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
                    .flatMap { state in
                        let storedEvents = state.allStoredEvents.compactMap { effectiveEvent($0) }
                        let cursorEligibleEventIDs = Set(storedEvents.lazy.filter { event in
                            beforeSeq.map { event.seq < $0 } ?? true
                        }.map(\.eventID))
                        return storedEvents
                            .filter { event in
                                if requiresHistoricalClosureCoverage(event),
                                   state.historicalClosureCoverageIsComplete == false {
                                    return false
                                }
                                guard let beforeSeq else {
                                    return true
                                }
                                return historicalOpenerIsVisible(
                                    event,
                                    state: state,
                                    cursorEligibleEventIDs: cursorEligibleEventIDs,
                                    beforeSeq: beforeSeq)
                            }
                    }
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
            let budgetedSlice = budgetLimitedEvents(countLimitedEvents,
                                                    maxBytes: maxBytes,
                                                    prefersNewestEvents: afterSeq == nil)
            let slice = beforeSeq == nil
                ? budgetedSlice
                : droppingOpenersWithoutFinalSliceTerminal(budgetedSlice)
            let oldestSeq = slice.first?.seq ?? 0
            let newestSeq = slice.last?.seq ?? 0
            let hasMore = matchingEvents.count > slice.count
            return FetchResult(events: slice, oldestSeq: oldestSeq, newestSeq: newestSeq, hasMore: hasMore)
        }
    }

    private func droppingOpenersWithoutFinalSliceTerminal(_ events: [AgentEvent]) -> [AgentEvent] {
        let finalEventIDs = Set(events.map(\.eventID))
        return events.filter { event in
            guard let state = sessions[event.sessionID],
                  case .visibleTerminal(let terminalEventID, _)? =
                    state.historicalOpenerResolutions[event.eventID] else {
                return true
            }
            return finalEventIDs.contains(terminalEventID)
        }
    }

    private func historicalOpenerIsVisible(
        _ event: AgentEvent,
        state: SessionState,
        cursorEligibleEventIDs: Set<String>,
        beforeSeq: Int
    ) -> Bool {
        if requiresHistoricalClosureCoverage(event),
           state.historicalClosureCoverageIsComplete == false {
            return false
        }
        guard let resolution = state.historicalOpenerResolutions[event.eventID] else {
            return true
        }
        switch resolution {
        case .visibleTerminal(let eventID, let sequence):
            return sequence < beforeSeq && cursorEligibleEventIDs.contains(eventID)
        case .silentConsumer:
            return false
        }
    }

    private func requiresHistoricalClosureCoverage(_ event: AgentEvent) -> Bool {
        event.type == .interactivePrompt
            || event.metadata?["tidey_generated"] == "claude_context_command"
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
        removed?.gate.cancel(waitHook: unsubscribeCancelWaitHook)
    }

    func oldestBufferedSeq(sessionID: String) -> Int? {
        queue.sync {
            sessions[sessionID]?.allStoredEvents
                .map(\.seq)
                .min()
        }
    }

    func sequenceHighWater(sessionID: String) -> Int {
        queue.sync {
            max(sessions[sessionID]?.storedSeqHighWater ?? transcriptSessionStartedSequence,
                reservedSeqBySessionID[sessionID] ?? transcriptSessionStartedSequence)
        }
    }

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
                let openerToken = AgentInteractivePromptSidebarMessages.lifecycleToken(from: opener)
                let openerRequiresCapability = AgentInteractivePromptSidebarMessages.requiresLifecycleCapability(opener)
                let closure = preTrim.first { candidate in
                    guard candidate.type == .interactivePromptResolved,
                          AgentInteractivePromptSidebarMessages.promptID(from: candidate) == promptID,
                          candidate.seq > opener.seq else {
                        return false
                    }
                    return AgentInteractivePromptSidebarMessages.terminalCloses(
                        openerLifecycleToken: openerToken,
                        openerRequiresCapability: openerRequiresCapability,
                        terminal: candidate
                    )
                }
                if let closure, keptIDs.contains(closure.eventID) == false {
                    dropIDs.insert(opener.eventID)
                }

            default:
                guard opener.metadata?["tidey_generated"] == "claude_context_command" else {
                    continue
                }
                let nextCommandSeq = preTrim
                    .filter {
                        $0.metadata?["tidey_generated"] == "claude_context_command" && $0.seq > opener.seq
                    }
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
        return kept.filter { dropIDs.contains($0.eventID) == false }
    }

    // Test seam for verifying that a session-scoped fetch defends against
    // foreign-session data even if stored state is already corrupt.
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
            guard let state = sessions[sessionID],
                  state.historicalClosureCoverageIsComplete else {
                return nil
            }
            var activePrompt: InteractivePrompt?
            var activePromptEventID: String?
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
                    activePromptEventID = event.eventID
                    activeLifecycleToken = AgentInteractivePromptSidebarMessages.lifecycleToken(from: event)
                    activeRequiresCapability = AgentInteractivePromptSidebarMessages.requiresLifecycleCapability(event)
                case .interactivePromptResolved:
                    if AgentInteractivePromptSidebarMessages.terminalCloses(
                        openerLifecycleToken: activeLifecycleToken,
                        openerRequiresCapability: activeRequiresCapability,
                        terminal: event
                    ) {
                        activePrompt = nil
                        activePromptEventID = nil
                    }
                default:
                    break
                }
            }
            if let activePromptEventID,
               case .visibleTerminal? = state.historicalOpenerResolutions[activePromptEventID] {
                return nil
            }
            return activePrompt
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

    // A transcript source switch revokes the old source's stored products
    // and idempotency state. Cursor authority survives so events from the
    // replacement source continue above every cursor already observed by a
    // client.
    func beginNewSourceEpoch(sessionID: String) {
        queue.sync {
            guard var state = sessions[sessionID] else {
                return
            }
            state.bufferedEvents.removeAll()
            state.historicalEvents.removeAll()
            state.historicalEventIDs.removeAll()
            state.historicalOpenerResolutions.removeAll()
            state.historicalClosureCoverageIsComplete = true
            state.seenEventIDs.removeAll()
            sessions[sessionID] = state
        }
    }

    // Closure evidence belongs to the transcript source epoch, not to one
    // cached page. A before-cursor fetch uses it to suppress an opener whose
    // exact terminal/consumer sits at or beyond the requested boundary,
    // including when bootstrap or another client already cached the opener.
    func replaceHistoricalOpenerResolutions(
        sessionID: String,
        resolutions: [String: HistoricalOpenerResolution]
    ) {
        queue.sync {
            var state = sessions[sessionID] ?? SessionState()
            state.historicalOpenerResolutions = resolutions
            sessions[sessionID] = state
        }
    }

    func setHistoricalClosureCoverage(sessionID: String, isComplete: Bool) {
        queue.sync {
            var state = sessions[sessionID] ?? SessionState()
            state.historicalClosureCoverageIsComplete = isComplete
            sessions[sessionID] = state
        }
    }

    enum PublishStorage {
        case liveForward
        case historicalBackfill
    }

    @discardableResult
    func publish(_ event: AgentEvent,
                 deliverToSubscribers: Bool = true,
                 storage: PublishStorage = .liveForward) -> AgentEvent? {
        var event = event
        var acceptedEvent: AgentEvent?
        let deliveryCompletion: DispatchSemaphore? = queue.sync {
            var state = sessions[event.sessionID] ?? SessionState()
            switch storage {
            case .liveForward:
                guard state.seenEventIDs.contains(event.eventID) == false,
                      state.historicalEventIDs.contains(event.eventID) == false else {
                    return nil
                }
            case .historicalBackfill:
                guard state.historicalEventIDs.contains(event.eventID) == false,
                      state.bufferedEvents.contains(where: { $0.eventID == event.eventID }) == false else {
                    return nil
                }
            }

            switch storage {
            case .liveForward:
                state.seenEventIDs.insert(event.eventID)
                if state.seenEventIDs.count > maxSeenEventIDs {
                    state.seenEventIDs = Set(state.bufferedEvents.map(\.eventID))
                    state.seenEventIDs.insert(event.eventID)
                }

                // Historical storage never changes live cursor authority.
                if let highWater = state.storedSeqHighWater, event.seq <= highWater {
                    let reserved = reservedSeqBySessionID[event.sessionID] ?? transcriptSessionStartedSequence
                    let rebased = max(highWater, reserved) + 1
                    event = event.withSeq(rebased)
                    reservedSeqBySessionID[event.sessionID] = rebased
                }
                state.storedSeqHighWater = max(state.storedSeqHighWater ?? event.seq, event.seq)

            case .historicalBackfill:
                // Backfill must remain strictly behind an established live
                // cursor. It keeps its source sequence and never delivers.
                guard let highWater = state.storedSeqHighWater, event.seq < highWater else {
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
                acceptedEvent = event
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
            acceptedEvent = event

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
        return acceptedEvent
    }

    // Replaces the caller-owned historical window atomically. Live events,
    // live cursor authority, reservations and subscribers remain untouched.
    func replaceHistoricalEvents(sessionID: String,
                                 events: [AgentEvent],
                                 anchorSeq: Int? = nil) {
        queue.sync {
            var state = sessions[sessionID] ?? SessionState()
            let liveIDs = Set(state.bufferedEvents.map(\.eventID))
            var replacementIDs = Set<String>()
            var accepted = [AgentEvent]()

            for event in events {
                guard event.sessionID == sessionID else {
                    continue
                }
                guard let highWater = state.storedSeqHighWater, event.seq < highWater else {
                    continue
                }
                guard liveIDs.contains(event.eventID) == false,
                      replacementIDs.insert(event.eventID).inserted else {
                    continue
                }
                accepted.append(event)
            }

            accepted.sort { $0.seq < $1.seq }
            if accepted.count > maxBufferedEvents {
                let preTrim = accepted
                if let anchorSeq {
                    let belowAnchor = accepted.filter { $0.seq < anchorSeq }
                    let atOrAboveAnchor = accepted.filter { $0.seq >= anchorSeq }
                    let keptBelow = belowAnchor.suffix(maxBufferedEvents)
                    let remainingCapacity = maxBufferedEvents - keptBelow.count
                    accepted = Array(keptBelow) + Array(atOrAboveAnchor.prefix(remainingCapacity))
                } else {
                    accepted.removeFirst(accepted.count - maxBufferedEvents)
                }
                accepted = Self.droppingOpenersWithTrimmedClosures(kept: accepted,
                                                                   preTrim: preTrim)
            }

            state.historicalEvents = accepted
            state.historicalEventIDs = Set(accepted.map(\.eventID))
            sessions[sessionID] = state
        }
    }

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

extension AgentEvent {
    // Rebasing changes only cursor position; event identity remains stable
    // so ordinary event-id deduplication still applies.
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
