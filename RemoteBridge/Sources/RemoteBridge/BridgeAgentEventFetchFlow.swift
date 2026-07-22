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
        backfill: (_ sessionID: String, _ beforeSeq: Int, _ limit: Int) -> Bool
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
            while let earliestBufferedSeq = eventHub.oldestBufferedSeq(sessionID: sessionID),
                  earliestBufferedSeq > afterSeq + 1 {
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
