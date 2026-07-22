// The fetch_agent_events production flow: the handler delegates the ENTIRE
// cache/backfill/refetch decision here, so tests exercise exactly the gate a
// real client request goes through.
enum BridgeAgentEventFetchFlow {
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
                fetchResult = eventHub.fetch(workspaceID: workspaceID,
                                             sessionID: sessionID,
                                             limit: limit,
                                             maxBytes: maxBytes,
                                             beforeSeq: beforeSeq,
                                             afterSeq: nil)
            }
        } else if let sessionID, let afterSeq {
            while let earliestBufferedSeq = eventHub.oldestBufferedSeq(sessionID: sessionID),
                  earliestBufferedSeq > afterSeq + 1 {
                let backfilled = backfill(sessionID, earliestBufferedSeq, max(limit, transcriptBootstrapLineLimit))
                guard backfilled else {
                    break
                }
                didBackfill = true
                fetchResult = eventHub.fetch(workspaceID: workspaceID,
                                             sessionID: sessionID,
                                             limit: limit,
                                             maxBytes: maxBytes,
                                             beforeSeq: nil,
                                             afterSeq: afterSeq)
            }
        }
        return Output(fetchResult: fetchResult, didBackfill: didBackfill)
    }
}
