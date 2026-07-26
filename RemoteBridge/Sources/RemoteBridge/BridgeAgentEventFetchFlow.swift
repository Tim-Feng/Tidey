// The fetch_agent_events production flow: the handler delegates the ENTIRE
// cache/backfill/refetch decision here, so tests exercise exactly the gate a
// real client request goes through.
enum BridgeAgentEventFetchFlow {
    static let maximumRequestLimit = 2_000

    struct Output {
        let fetchResult: AgentEventHub.FetchResult
        let didBackfill: Bool
        let beforeCursorUnavailable: Bool
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
        run(eventHub: eventHub,
            workspaceID: workspaceID,
            sessionID: sessionID,
            limit: limit,
            maxBytes: maxBytes,
            beforeSeq: beforeSeq,
            afterSeq: afterSeq,
            afterCursorSeams: afterCursorSeams,
            beforeCursorBackfill: { sessionID, beforeSeq, limit in
                AgentBeforeCursorBackfillResult(
                    didBackfill: backfill(sessionID, beforeSeq, limit),
                    rawContinuation: .unknown
                )
            })
    }

    static func run(
        eventHub: AgentEventHub,
        workspaceID: String,
        sessionID: String?,
        limit: Int,
        maxBytes: Int? = nil,
        beforeSeq: Int?,
        afterSeq: Int?,
        afterCursorSeams: AfterCursorSeams = .legacyNeutral,
        beforeCursorBackfill: (
            _ sessionID: String,
            _ beforeSeq: Int,
            _ limit: Int
        ) -> AgentBeforeCursorBackfillResult
    ) -> Output {
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
                            beforeCursorBackfill: beforeCursorBackfill)
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
                           beforeCursorBackfill: beforeCursorBackfill)
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
        beforeCursorBackfill: (
            _ sessionID: String,
            _ beforeSeq: Int,
            _ limit: Int
        ) -> AgentBeforeCursorBackfillResult
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
        var beforeCursorUnavailable = false
        if let sessionID, let beforeSeq {
            // Requested-anchor coverage: cache contents (hasMore) can never
            // stand in for the REQUESTED range — a deep page cache from
            // another client would otherwise satisfy the limit and skip the
            // anchor-adjacent page forever. The session backfill is exact-
            // anchor, so the refetch below returns the adjacent page.
            let backfillResult = beforeCursorBackfill(
                sessionID,
                beforeSeq,
                max(limit, transcriptBootstrapLineLimit)
            )
            if backfillResult.didBackfill {
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
            if backfillResult.rawContinuation == .more {
                fetchResult = continuingBeforePage(fetchResult,
                                                   requestedBeforeSeq: beforeSeq)
            } else if backfillResult.rawContinuation == .unavailable {
                beforeCursorUnavailable = true
            }
        }
        return Output(fetchResult: fetchResult,
                      didBackfill: didBackfill,
                      beforeCursorUnavailable: beforeCursorUnavailable)
    }

    private static func continuingBeforePage(
        _ page: AgentEventHub.FetchResult,
        requestedBeforeSeq: Int
    ) -> AgentEventHub.FetchResult {
        // Synthetic lifecycle markers have no raw transcript position. If
        // raw authority proves there are older bytes, exposing seq 0 as the
        // page bound would strand the iOS before cursor. Publish the marker
        // only on a later page whose source authority proves real BOF.
        let pageableEvents = page.events.filter { $0.seq > transcriptSessionStartedSequence }
        guard let oldestSeq = pageableEvents.map(\.seq).min(),
              let newestSeq = pageableEvents.map(\.seq).max() else {
            return AgentEventHub.FetchResult(events: [],
                                             oldestSeq: requestedBeforeSeq,
                                             newestSeq: requestedBeforeSeq,
                                             hasMore: true)
        }
        return AgentEventHub.FetchResult(events: pageableEvents,
                                         oldestSeq: oldestSeq,
                                         newestSeq: newestSeq,
                                         hasMore: true)
    }

    // One attempt's classified result: epoch/source/lease invalidations are
    // RETRYABLE (the world moved underneath the attempt); everything else —
    // success and same-epoch terminal failures alike — is completed.
    private enum AfterCursorAttemptResult {
        case completed(Output)
        case retryableInvalidation(didBackfill: Bool)
    }

    // The typed after-cursor path: at most TWO attempts (initial + one
    // retry) inside the same historical request transaction, composed as a
    // loop — never by re-entering the public run. Each attempt owns a fresh
    // lease/plan/accumulator whose defer-cancel unwinds before the next
    // attempt starts; a second invalidation fails closed, never a third
    // attempt. didBackfill is the request-level OR across attempts.
    private static func runAfterCursor(
        eventHub: AgentEventHub,
        workspaceID: String,
        sessionID: String,
        limit: Int,
        maxBytes: Int?,
        afterSeq: Int,
        seams: AfterCursorSeams
    ) -> Output {
        var requestDidBackfill = false
        for _ in 0..<2 {
            switch runAfterCursorAttempt(eventHub: eventHub,
                                         workspaceID: workspaceID,
                                         sessionID: sessionID,
                                         limit: limit,
                                         maxBytes: maxBytes,
                                         afterSeq: afterSeq,
                                         seams: seams) {
            case .completed(let output):
                return Output(fetchResult: output.fetchResult,
                              didBackfill: requestDidBackfill || output.didBackfill,
                              beforeCursorUnavailable: false)
            case .retryableInvalidation(let didBackfill):
                requestDidBackfill = requestDidBackfill || didBackfill
            }
        }
        return Output(fetchResult: AgentEventHub.FetchResult(events: [],
                                                             oldestSeq: afterSeq,
                                                             newestSeq: afterSeq,
                                                             hasMore: true),
                      didBackfill: requestDidBackfill,
                      beforeCursorUnavailable: false)
    }

    // ONE complete after-cursor attempt: lease begin/finish/cancel, plan,
    // decision table, bounded raw walk, and final projection all live —
    // and stay — inside this scope. Response authority is ONLY the
    // request-owned raw accumulator plus the live lease snapshot;
    // `eventHub.fetch`, buffered minima, legacy backfill and the shared
    // historical cache are never consulted.
    private static func runAfterCursorAttempt(
        eventHub: AgentEventHub,
        workspaceID: String,
        sessionID: String,
        limit: Int,
        maxBytes: Int?,
        afterSeq: Int,
        seams: AfterCursorSeams
    ) -> AfterCursorAttemptResult {
        // Same-epoch failures are TERMINAL — retry quota never re-runs them.
        func failClosed(didBackfill: Bool) -> AfterCursorAttemptResult {
            .completed(Output(fetchResult: AgentEventHub.FetchResult(events: [],
                                                                     oldestSeq: afterSeq,
                                                                     newestSeq: afterSeq,
                                                                     hasMore: true),
                              didBackfill: didBackfill,
                              beforeCursorUnavailable: false))
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
            // The world moved between lease and plan: retryable.
            return .retryableInvalidation(didBackfill: false)
        }

        enum Mode {
            case leaseOnly
            case walk(from: AgentHistoryAnchor)
            case hubOnlyBestEffort
        }
        let mode: Mode
        switch plan.mode {
        case .rawCovered(let replayFrom):
            guard replayFrom.epoch == expectedEpoch else {
                return .retryableInvalidation(didBackfill: false)
            }
            if lease.evidence.containsEveryAcceptedLiveEvent(afterSeq: afterSeq) {
                mode = .leaseOnly
            } else {
                // Raw coverage is NOT retained product coverage: a pre-lease
                // eviction above the cursor forces a raw replay from the
                // plan's FIXED validated frontier.
                mode = .walk(from: replayFrom)
            }
        case .scan(let from):
            guard from.epoch == expectedEpoch else {
                return .retryableInvalidation(didBackfill: false)
            }
            mode = .walk(from: from)
        case .hubOnly:
            mode = .hubOnlyBestEffort
        case .unavailable:
            // Same-epoch unavailable is terminal.
            return failClosed(didBackfill: false)
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
                // Identity gate BEFORE the bounded dictionary: a foreign
                // session candidate must not overwrite a requested event's
                // ID, crowd legitimate history out of the capacity, or mark
                // truncation. sessionID is safe to check pre-binding — the
                // Hub binding only rewrites workspace/panel, never session;
                // the workspace filter must wait for the current binding.
                guard event.sessionID == sessionID else {
                    continue
                }
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
        case .leaseOnly, .hubOnlyBestEffort:
            break
        case .walk(let startAnchor):
            let stepLimit = max(boundedCapacity, transcriptBootstrapLineLimit)
            var anchor = startAnchor
            walking: while true {
                let step = seams.step(sessionID, anchor, afterSeq, stepLimit)
                guard step.epoch == expectedEpoch else {
                    return .retryableInvalidation(didBackfill: didBackfill)
                }
                switch step.outcome {
                case .sourceChanged:
                    // The source moved underneath the walk: retryable.
                    return .retryableInvalidation(didBackfill: didBackfill)
                case .unavailable:
                    // Same-epoch incomplete coverage is terminal.
                    return failClosed(didBackfill: didBackfill)
                case .complete:
                    didBackfill = true
                    retainBounded(step.events)
                    break walking
                case .advanced(let next):
                    guard next.epoch == expectedEpoch else {
                        return .retryableInvalidation(didBackfill: didBackfill)
                    }
                    guard next.position < anchor.position else {
                        // A same-epoch stall is terminal — it never counts
                        // as backfill.
                        return failClosed(didBackfill: didBackfill)
                    }
                    didBackfill = true
                    retainBounded(step.events)
                    anchor = next
                }
            }
        }

        // Finalization order: finish the lease, session validate, then read
        // the Hub current epoch REGARDLESS of the validation result — an
        // epoch that moved retries; a false validation under an unchanged
        // epoch is terminal.
        guard let snapshot = eventHub.finishAfterCursorLiveLease(lease.token) else {
            return .retryableInvalidation(didBackfill: didBackfill)
        }
        guard snapshot.epoch == expectedEpoch else {
            return .retryableInvalidation(didBackfill: didBackfill)
        }
        let validated = seams.validateEpoch(sessionID, expectedEpoch)
        guard eventHub.currentHistoryEpoch(sessionID: sessionID) == expectedEpoch else {
            return .retryableInvalidation(didBackfill: didBackfill)
        }
        guard validated else {
            return failClosed(didBackfill: didBackfill)
        }

        // Union authority (agreed order): concatenate request-owned raw
        // events THEN lease events → current Hub binding (atomic) →
        // requested workspace/session filter → seq > afterSeq → eventID
        // dedupe with the lease's later accepted/rebased copy winning →
        // stable (seq, eventID) sort → count → bytes.
        let combined = rawByEventID.values
            .sorted { ($0.seq, $0.eventID) < ($1.seq, $1.eventID) }
            + snapshot.events
        let projected = eventHub.applyingCurrentSessionBindings(combined)
        var dedupedByEventID = [String: AgentEvent]()
        for event in projected
        where event.workspaceID == workspaceID
            && event.sessionID == sessionID
            && event.seq > afterSeq {
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
        return .completed(Output(fetchResult: AgentEventHub.FetchResult(events: budgeted,
                                                                        oldestSeq: budgeted.first?.seq ?? afterSeq,
                                                                        newestSeq: budgeted.last?.seq ?? afterSeq,
                                                                        hasMore: hasMore),
                                 didBackfill: didBackfill,
                                 beforeCursorUnavailable: false))
    }
}
