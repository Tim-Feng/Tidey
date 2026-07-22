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
        let cursorFloor = max(pageNewestSeq, requestedAfterSeq ?? Int.min)
        return Merged(events: events,
                      oldestSeq: events.first?.seq ?? pageOldestSeq,
                      newestSeq: max(events.last?.seq ?? cursorFloor, cursorFloor))
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
