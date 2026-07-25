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
    // threaded from the registry/server. The legacy-neutral default keeps
    // every existing call site and the current after path unchanged; the
    // lease/walk decision table lands as separate behavioral rows.
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
        // afterCursorSeams is intentionally unused here: this row only
        // threads the seams; the legacy after path below stays authoritative
        // until the lease/walk decision table lands.
        _ = afterCursorSeams
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
            while nextAfterSeqOverflowed == false,
                  let earliestBufferedSeq = eventHub.oldestBufferedSeq(sessionID: sessionID),
                  earliestBufferedSeq > nextAfterSeq {
                let backfilled = backfill(sessionID, earliestBufferedSeq, max(limit, transcriptBootstrapLineLimit))
                didBackfill = didBackfill || backfilled
                fetchResult = eventHub.fetch(workspaceID: workspaceID,
                                             sessionID: sessionID,
                                             limit: limit,
                                             maxBytes: maxBytes,
                                             beforeSeq: nil,
                                             afterSeq: afterSeq)
                guard backfilled,
                      let nextEarliestBufferedSeq = eventHub.oldestBufferedSeq(sessionID: sessionID),
                      nextEarliestBufferedSeq < earliestBufferedSeq else {
                    break
                }
            }
        }
        return Output(fetchResult: fetchResult, didBackfill: didBackfill)
    }
}
