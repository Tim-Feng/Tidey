import Foundation

enum BridgePendingApprovalFetchMerge {
    struct Merged {
        let events: [AgentEvent]
        let oldestSeq: Int
        let newestSeq: Int
    }

    static func merge(pageEvents: [AgentEvent],
                      pageOldestSeq: Int,
                      pageNewestSeq: Int,
                      requestedBeforeSeq: Int? = nil,
                      requestedAfterSeq: Int? = nil,
                      pendingEvents: [AgentEvent]) -> Merged {
        let activePending = AgentInteractivePromptEventReducer.pendingEvents(
            pendingEvents,
            excludingResolvedIn: pageEvents)
        let merged = AgentInteractivePromptEventReducer.mergedEvents(pageEvents, activePending)
        let events = overlaySnapshots(merged, activePending: activePending)
        guard pageEvents.isEmpty else {
            return Merged(events: events,
                          oldestSeq: pageOldestSeq,
                          newestSeq: pageNewestSeq)
        }
        if requestedBeforeSeq != nil {
            return Merged(events: events,
                          oldestSeq: pageOldestSeq,
                          newestSeq: pageNewestSeq)
        }
        if let requestedAfterSeq {
            // Injected pending snapshots ride along in the payload but must
            // never advance the after-directional bound: the Hub fetch and
            // the pending lookup are two separate reads, and letting a
            // pending seq above the cursor advance newest_seq would make
            // the next poll permanently skip everything appended between
            // those two reads.
            return Merged(events: events,
                          oldestSeq: events.first?.seq ?? pageOldestSeq,
                          newestSeq: max(pageNewestSeq, requestedAfterSeq))
        }
        // Cursor-less initial fetch: an empty stored page with injected
        // pending events keeps its latest-snapshot semantics — the bounds
        // follow the injected events.
        return Merged(events: events,
                      oldestSeq: events.first?.seq ?? pageOldestSeq,
                      newestSeq: max(events.last?.seq ?? pageNewestSeq, pageNewestSeq))
    }

    static func mergeReplayEnvelopes(_ replayEnvelopes: [AgentEventEnvelope],
                                     pendingEvents: [AgentEvent]) -> [AgentEventEnvelope] {
        let replayEvents = replayEnvelopes.map(\.event)
        let activePending = AgentInteractivePromptEventReducer.pendingEvents(
            pendingEvents,
            excludingResolvedIn: replayEvents)
        let merged = AgentInteractivePromptEventReducer.mergedEvents(replayEvents, activePending)
        let events = overlaySnapshots(merged, activePending: activePending)
        return events.map { AgentEventEnvelope(replay: true, event: $0) }
    }

    static func openLiveGate(_ gate: BridgeAgentEventReplayGate,
                             afterReplaying replayEnvelopes: [AgentEventEnvelope]) -> [AgentEventEnvelope] {
        gate.open(suppressing: Set(replayEnvelopes.map(\.event.eventID)))
    }

    private static func overlaySnapshots(_ events: [AgentEvent],
                                         activePending: [AgentEvent]) -> [AgentEvent] {
        let snapshots = Dictionary(activePending.map { ($0.eventID, $0) },
                                   uniquingKeysWith: { _, latest in latest })
        return events.map { snapshots[$0.eventID] ?? $0 }
    }
}
