// The fetch_agent_events production flow: the handler delegates the ENTIRE
// cache/backfill/refetch decision here, so tests exercise exactly the gate a
// real client request goes through.
enum BridgeAgentEventFetchFlow {
    static let maximumRequestLimit = 2_000

    struct Output {
        let fetchResult: AgentEventHub.FetchResult
        let didBackfill: Bool
    }

    // Typed after-cursor session seams (see AgentHistoryContract.swift),
    // threaded from the registry/server. Since G3a the default `.hubOnly`
    // plan means BOUNDED LEASE BEST-EFFORT: the response is the request's
    // live-lease window — never the legacy after backfill, never shared
    // history.
    struct AfterCursorSeams {
        let plan: (_ sessionID: String, _ afterSeq: Int, _ expectedEpoch: AgentHistoryEpoch) -> AgentAfterCursorPlan
        let step: (_ sessionID: String, _ anchor: AgentHistoryAnchor, _ afterSeq: Int, _ limit: Int) -> AgentAfterCursorStep
        let validateEpoch: (_ sessionID: String, _ epoch: AgentHistoryEpoch) -> Bool

        static let legacyNeutral = AfterCursorSeams(
            plan: { _, _, expectedEpoch in
                AgentAfterCursorPlan(epoch: expectedEpoch, mode: .hubOnly)
            },
            step: { _, anchor, _, _ in
                AgentAfterCursorStep(epoch: anchor.epoch, outcome: .unavailable, events: [])
            },
            validateEpoch: { _, _ in true })
    }

    static func run(eventHub: AgentEventHub,
                    workspaceID: String,
                    sessionID: String?,
                    limit: Int,
                    maxBytes: Int? = nil,
                    beforeSeq: Int?,
                    afterSeq: Int?,
                    afterCursorSeams: AfterCursorSeams = .legacyNeutral,
                    backfill: (_ sessionID: String, _ beforeSeq: Int, _ limit: Int) -> Bool) -> Output {
        if let sessionID, beforeSeq != nil || afterSeq != nil {
            return eventHub.withHistoricalRequestTransaction(sessionID: sessionID) {
                runUnlocked(eventHub: eventHub,
                            workspaceID: workspaceID,
                            sessionID: sessionID,
                            limit: limit,
                            maxBytes: maxBytes,
                            beforeSeq: beforeSeq,
                            afterSeq: afterSeq,
                            afterCursorSeams: afterCursorSeams,
                            backfill: backfill)
            }
        }
        return runUnlocked(eventHub: eventHub,
                           workspaceID: workspaceID,
                           sessionID: sessionID,
                           limit: limit,
                           maxBytes: maxBytes,
                           beforeSeq: beforeSeq,
                           afterSeq: afterSeq,
                           afterCursorSeams: afterCursorSeams,
                           backfill: backfill)
    }

    private static func runUnlocked(
        eventHub: AgentEventHub,
        workspaceID: String,
        sessionID: String?,
        limit: Int,
        maxBytes: Int?,
        beforeSeq: Int?,
        afterSeq: Int?,
        afterCursorSeams: AfterCursorSeams,
        backfill: (_ sessionID: String, _ beforeSeq: Int, _ limit: Int) -> Bool
    ) -> Output {
        if let sessionID, let afterSeq, beforeSeq == nil {
            // The typed after path never reads shared history: its response
            // authority is request-owned raw events plus the live lease.
            return runAfterCursor(eventHub: eventHub,
                                  workspaceID: workspaceID,
                                  sessionID: sessionID,
                                  limit: limit,
                                  maxBytes: maxBytes,
                                  afterSeq: afterSeq,
                                  seams: afterCursorSeams)
        }
        var fetchResult = eventHub.fetch(workspaceID: workspaceID,
                                         sessionID: sessionID,
                                         limit: limit,
                                         maxBytes: maxBytes,
                                         beforeSeq: beforeSeq,
                                         afterSeq: afterSeq)
        var didBackfill = false
        if let sessionID, let beforeSeq {
            // Requested-anchor coverage: cache contents (hasMore) can never
            // stand in for the REQUESTED range — a deep page cache from
            // another client would otherwise satisfy the limit and skip the
            // anchor-adjacent page forever. The session backfill is exact-
            // anchor, so the refetch below returns the adjacent page.
            let backfilled = backfill(sessionID, beforeSeq, max(limit, transcriptBootstrapLineLimit))
            if backfilled {
                didBackfill = true
            }
            // Backfill may return false because it detected and revoked a
            // replaced source. Never return the fetch captured before that
            // session-side transaction; read the Hub again either way.
            fetchResult = eventHub.fetch(workspaceID: workspaceID,
                                         sessionID: sessionID,
                                         limit: limit,
                                         maxBytes: maxBytes,
                                         beforeSeq: beforeSeq,
                                         afterSeq: nil)
        }
        return Output(fetchResult: fetchResult, didBackfill: didBackfill)
    }

    // The typed after-cursor path (G3a decision table). Response authority
    // is ONLY the request-owned raw accumulator plus the live lease
    // snapshot; `eventHub.fetch`, buffered minima, legacy backfill and the
    // shared historical cache are never consulted.
    private static func runAfterCursor(
        eventHub: AgentEventHub,
        workspaceID: String,
        sessionID: String,
        limit: Int,
        maxBytes: Int?,
        afterSeq: Int,
        seams: AfterCursorSeams
    ) -> Output {
        func failClosed(didBackfill: Bool) -> Output {
            Output(fetchResult: AgentEventHub.FetchResult(events: [],
                                                          oldestSeq: afterSeq,
                                                          newestSeq: afterSeq,
                                                          hasMore: true),
                   didBackfill: didBackfill)
        }
        // The Hub path always served at least one event; the typed path
        // keeps that contract for capacity, raw page size, and count trim.
        let effectiveLimit = max(limit, 1)
        let (rawCapacity, capacityOverflowed) = effectiveLimit.addingReportingOverflow(1)
        let boundedCapacity = capacityOverflowed ? Int.max : rawCapacity

        // Lease FIRST: a publish+evict between plan and lease could hide an
        // event from both the plan's frontier and the lease window.
        let lease = eventHub.beginAfterCursorLiveLease(sessionID: sessionID,
                                                       afterSeq: afterSeq,
                                                       capacity: boundedCapacity)
        // Idempotent: a finished lease token is already consumed, so this
        // never double-releases; every early return path is covered.
        defer { eventHub.cancelAfterCursorLiveLease(lease.token) }
        let expectedEpoch = lease.evidence.epoch

        let plan = seams.plan(sessionID, afterSeq, expectedEpoch)
        guard plan.epoch == expectedEpoch else {
            return failClosed(didBackfill: false)
        }

        enum Mode {
            case leaseOnly
            case walk(from: AgentHistoryAnchor)
            case hubOnlyBestEffort
            case unavailable
        }
        let mode: Mode
        switch plan.mode {
        case .rawCovered(let replayFrom):
            if replayFrom.epoch != expectedEpoch {
                mode = .unavailable
            } else if lease.evidence.containsEveryAcceptedLiveEvent(afterSeq: afterSeq) {
                mode = .leaseOnly
            } else {
                // Raw coverage is NOT retained product coverage: a pre-lease
                // eviction above the cursor forces a raw replay from the
                // plan's FIXED validated frontier.
                mode = .walk(from: replayFrom)
            }
        case .scan(let from):
            mode = from.epoch == expectedEpoch ? .walk(from: from) : .unavailable
        case .hubOnly:
            mode = .hubOnlyBestEffort
        case .unavailable:
            mode = .unavailable
        }

        var didBackfill = false
        var rawByEventID = [String: AgentEvent]()
        var rawTruncated = false
        // Per-candidate bounded retention: the dictionary NEVER exceeds the
        // capacity, the eviction key is deterministically the greatest
        // (seq, eventID) — so equal-seq boundaries keep the lexicographically
        // earliest — and deeper/older steps displace newer candidates. Any
        // unique candidate the cap excludes records the truncation.
        func retainBounded(_ events: [AgentEvent]) {
            for event in events where event.seq > afterSeq {
                if rawByEventID[event.eventID] != nil {
                    rawByEventID[event.eventID] = event
                    continue
                }
                if rawByEventID.count < boundedCapacity {
                    rawByEventID[event.eventID] = event
                    continue
                }
                rawTruncated = true
                guard let worst = rawByEventID.max(by: {
                    ($0.value.seq, $0.key) < ($1.value.seq, $1.key)
                }) else {
                    continue
                }
                if (event.seq, event.eventID) < (worst.value.seq, worst.key) {
                    rawByEventID.removeValue(forKey: worst.key)
                    rawByEventID[event.eventID] = event
                }
            }
        }

        switch mode {
        case .unavailable:
            return failClosed(didBackfill: false)
        case .leaseOnly, .hubOnlyBestEffort:
            break
        case .walk(let startAnchor):
            let stepLimit = max(boundedCapacity, transcriptBootstrapLineLimit)
            var anchor = startAnchor
            walking: while true {
                let step = seams.step(sessionID, anchor, afterSeq, stepLimit)
                guard step.epoch == expectedEpoch else {
                    // G3a: any epoch movement (incl. sourceChanged) discards
                    // the whole attempt; the one-retry state machine is G3c.
                    return failClosed(didBackfill: didBackfill)
                }
                switch step.outcome {
                case .unavailable, .sourceChanged:
                    return failClosed(didBackfill: didBackfill)
                case .complete:
                    didBackfill = true
                    retainBounded(step.events)
                    break walking
                case .advanced(let next):
                    guard next.epoch == expectedEpoch,
                          next.position < anchor.position else {
                        // A stalled or epoch-crossing anchor is rejected —
                        // it never counts as backfill.
                        return failClosed(didBackfill: didBackfill)
                    }
                    didBackfill = true
                    retainBounded(step.events)
                    anchor = next
                }
            }
        }

        // Finalization order: finish the lease, THEN validate the epoch.
        guard let snapshot = eventHub.finishAfterCursorLiveLease(lease.token),
              snapshot.epoch == expectedEpoch,
              seams.validateEpoch(sessionID, expectedEpoch),
              eventHub.currentHistoryEpoch(sessionID: sessionID) == expectedEpoch else {
            return failClosed(didBackfill: didBackfill)
        }

        // Union authority (agreed order): concatenate request-owned raw
        // events THEN lease events → current Hub binding (atomic) → this
        // gate's filters (seq > afterSeq; B13 adds the requested
        // workspace/session filter) → eventID dedupe with the lease's later
        // accepted/rebased copy winning → stable (seq, eventID) sort →
        // count → bytes.
        let combined = rawByEventID.values
            .sorted { ($0.seq, $0.eventID) < ($1.seq, $1.eventID) }
            + snapshot.events
        let projected = eventHub.applyingCurrentSessionBindings(combined)
        var dedupedByEventID = [String: AgentEvent]()
        for event in projected where event.seq > afterSeq {
            dedupedByEventID[event.eventID] = event
        }
        var page = dedupedByEventID.values
            .sorted { ($0.seq, $0.eventID) < ($1.seq, $1.eventID) }
        let droppedByCount = page.count > effectiveLimit
        if droppedByCount {
            page = Array(page.prefix(effectiveLimit))
        }
        let budgeted = eventHub.budgetLimitedPage(page,
                                                  maxBytes: maxBytes,
                                                  prefersNewestEvents: false)
        let droppedByBudget = budgeted.count < page.count
        let hasMore = droppedByCount || droppedByBudget || rawTruncated || snapshot.truncated
        return Output(fetchResult: AgentEventHub.FetchResult(events: budgeted,
                                                             oldestSeq: budgeted.first?.seq ?? afterSeq,
                                                             newestSeq: budgeted.last?.seq ?? afterSeq,
                                                             hasMore: hasMore),
                      didBackfill: didBackfill)
    }
}
