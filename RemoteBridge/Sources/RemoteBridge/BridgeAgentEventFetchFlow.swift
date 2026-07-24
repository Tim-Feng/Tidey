// The fetch_agent_events production flow: the handler delegates the ENTIRE
// cache/backfill/refetch decision here, so tests exercise exactly the gate a
// real client request goes through.
enum BridgeAgentEventFetchFlow {
    static let maximumRequestLimit = 2_000

    struct Output {
        let fetchResult: AgentEventHub.FetchResult
        let didBackfill: Bool
    }

    static func run(eventHub: AgentEventHub,
                    workspaceID: String,
                    sessionID: String?,
                    limit: Int,
                    maxBytes: Int? = nil,
                    beforeSeq: Int?,
                    afterSeq: Int?,
                    backfill: (_ sessionID: String, _ beforeSeq: Int, _ limit: Int) -> Bool,
                    afterSeed: (_ sessionID: String, _ afterSeq: Int) -> AgentAfterCursorCoverageSeed,
                    afterStep: (_ sessionID: String, _ beforeSeq: Int, _ afterSeq: Int, _ limit: Int) -> AgentAfterCursorBackfillStep) -> Output {
        if let sessionID, beforeSeq != nil || afterSeq != nil {
            return eventHub.withHistoricalRequestTransaction(sessionID: sessionID) {
                runUnlocked(eventHub: eventHub,
                            workspaceID: workspaceID,
                            sessionID: sessionID,
                            limit: limit,
                            maxBytes: maxBytes,
                            beforeSeq: beforeSeq,
                            afterSeq: afterSeq,
                            backfill: backfill,
                            afterSeed: afterSeed,
                            afterStep: afterStep)
            }
        }
        return runUnlocked(eventHub: eventHub,
                           workspaceID: workspaceID,
                           sessionID: sessionID,
                           limit: limit,
                           maxBytes: maxBytes,
                           beforeSeq: beforeSeq,
                           afterSeq: afterSeq,
                           backfill: backfill,
                           afterSeed: afterSeed,
                           afterStep: afterStep)
    }

    private static func runUnlocked(
        eventHub: AgentEventHub,
        workspaceID: String,
        sessionID: String?,
        limit: Int,
        maxBytes: Int?,
        beforeSeq: Int?,
        afterSeq: Int?,
        backfill: (_ sessionID: String, _ beforeSeq: Int, _ limit: Int) -> Bool,
        afterSeed: (_ sessionID: String, _ afterSeq: Int) -> AgentAfterCursorCoverageSeed,
        afterStep: (_ sessionID: String, _ beforeSeq: Int, _ afterSeq: Int, _ limit: Int) -> AgentAfterCursorBackfillStep
    ) -> Output {
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
        } else if let sessionID, let afterSeq {
            let (nextAfterSeq, nextAfterSeqOverflowed) = afterSeq.addingReportingOverflow(1)
            // Coverage authority is SESSION-OWNED: the seed derives from
            // the current source epoch's tailer frontier plus the
            // transcript sequence mapping. No event buffer may stand in —
            // synthetic events (session-start seq 0) and bounded bootstrap
            // windows make Hub minima meaningless as raw coverage proof.
            //  - covered: the cursor lies inside the contiguously scanned
            //    raw interval — sparse sequence jumps inside it are NOT
            //    gaps, so a normal poll never backfills.
            //  - walkFrom: walk the raw transcript in steps; each returns
            //    its REQUEST-OWNED events and raw frontier.
            //  - hubOnly: no transcript backing at all — plain fetch.
            //  - unavailable/sourceInvalidated: fail closed / refetch.
            let initialCoverageAnchor: Int?
            enum CoverageWalkResult {
                case notNeeded
                case complete([String: AgentEvent])
                case failedClosed
                case invalidated
            }
            var walkResult = CoverageWalkResult.notNeeded
            if nextAfterSeqOverflowed {
                initialCoverageAnchor = nil
            } else {
                switch afterSeed(sessionID, afterSeq) {
                case .covered, .hubOnly:
                    initialCoverageAnchor = nil
                case .unavailable:
                    initialCoverageAnchor = nil
                    walkResult = .failedClosed
                case .sourceInvalidated:
                    initialCoverageAnchor = nil
                    walkResult = .invalidated
                case .walkFrom(let frontier):
                    initialCoverageAnchor = frontier > nextAfterSeq ? frontier : nil
                }
            }
            var requestOwnedWasTruncated = false
            if var coverageAnchor = initialCoverageAnchor {
                var requestOwnedByEventID = [String: AgentEvent]()
                // The walk must cover the whole raw interval, but the
                // response only ever needs the earliest limit+1 events —
                // trimming per step keeps memory bounded on long
                // transcripts, and the trim is recorded for hasMore.
                let retentionCap = limit + 1
                func retainBounded(_ events: [AgentEvent]) {
                    for event in events where event.seq > afterSeq {
                        requestOwnedByEventID[event.eventID] = event
                    }
                    if requestOwnedByEventID.count > retentionCap {
                        requestOwnedWasTruncated = true
                        let kept = requestOwnedByEventID.values
                            .sorted { $0.seq < $1.seq }
                            .prefix(retentionCap)
                        requestOwnedByEventID = Dictionary(uniqueKeysWithValues: kept.map { ($0.eventID, $0) })
                    }
                }
                walkResult = .failedClosed
                coverage: while true {
                    let step = afterStep(sessionID, coverageAnchor, afterSeq, max(limit, transcriptBootstrapLineLimit))
                    switch step.outcome {
                    case .sourceInvalidated:
                        // Never serve events from a replaced source epoch.
                        walkResult = .invalidated
                        break coverage
                    case .unavailable:
                        // Incomplete coverage fails CLOSED: partial scans
                        // must not reach the client, or the cursor would
                        // advance past a gap that was never walked.
                        walkResult = .failedClosed
                        break coverage
                    case .coveredCursor, .reachedSourceStart:
                        didBackfill = true
                        retainBounded(step.events)
                        walkResult = .complete(requestOwnedByEventID)
                        break coverage
                    case .advanced:
                        didBackfill = true
                        retainBounded(step.events)
                        guard let next = step.nextBeforeSeq, next < coverageAnchor else {
                            // A stalled walk is incomplete coverage.
                            walkResult = .failedClosed
                            break coverage
                        }
                        if next <= nextAfterSeq {
                            walkResult = .complete(requestOwnedByEventID)
                            break coverage
                        }
                        coverageAnchor = next
                    }
                }
            }
            switch walkResult {
            case .notNeeded:
                // Cursor inside the retained live window (or nothing above
                // it): the plain fetch is already gap-free.
                break
            case .invalidated:
                // Re-read the post-reset epoch; the stale walk is dropped.
                fetchResult = eventHub.fetch(workspaceID: workspaceID,
                                             sessionID: sessionID,
                                             limit: limit,
                                             maxBytes: maxBytes,
                                             beforeSeq: nil,
                                             afterSeq: afterSeq)
            case .failedClosed:
                // No stored/live event may move newest_seq past the cursor
                // while the interval below the live window is unverified;
                // the client keeps its cursor and retries.
                fetchResult = AgentEventHub.FetchResult(events: [],
                                                        oldestSeq: afterSeq,
                                                        newestSeq: afterSeq,
                                                        hasMore: true)
            case .complete(let requestOwnedByEventID):
                // Final payload: the request-owned scan is the authority
                // for the covered interval, joined with the LIVE-ONLY
                // window (read limit+1 so overlap with request-owned IDs
                // cannot mask further live events) — the bounded historical
                // cache never contributes. limit and maxBytes trim the
                // assembled page only.
                var pageByEventID = [String: AgentEvent]()
                for event in eventHub.applyingSessionBindings(Array(requestOwnedByEventID.values)) {
                    pageByEventID[event.eventID] = event
                }
                for event in eventHub.fetchLiveOnly(workspaceID: workspaceID,
                                                    sessionID: sessionID,
                                                    limit: limit + 1,
                                                    afterSeq: afterSeq) {
                    pageByEventID[event.eventID] = event
                }
                var page = pageByEventID.values
                    .filter { $0.seq > afterSeq }
                    .sorted { $0.seq < $1.seq }
                let droppedByLimit = page.count > limit
                if droppedByLimit {
                    page = Array(page.prefix(limit))
                }
                let budgetedPage = eventHub.budgetLimitedPage(page,
                                                              maxBytes: maxBytes,
                                                              prefersNewestEvents: false)
                let droppedByBudget = budgetedPage.count < page.count
                fetchResult = AgentEventHub.FetchResult(events: budgetedPage,
                                                        oldestSeq: budgetedPage.first?.seq ?? afterSeq,
                                                        newestSeq: budgetedPage.last?.seq ?? afterSeq,
                                                        hasMore: droppedByLimit || droppedByBudget || requestOwnedWasTruncated)
            }
        }
        return Output(fetchResult: fetchResult, didBackfill: didBackfill)
    }
}
