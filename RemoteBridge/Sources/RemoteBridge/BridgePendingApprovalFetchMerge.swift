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
        let events = AgentInteractivePromptEventReducer.mergedEvents(pageEvents, activePending)
        return Merged(events: events,
                      oldestSeq: events.first?.seq ?? pageOldestSeq,
                      newestSeq: events.last?.seq ?? pageNewestSeq)
    }

    static func mergeReplayEnvelopes(_ replayEnvelopes: [AgentEventEnvelope],
                                     pendingEvents: [AgentEvent]) -> [AgentEventEnvelope] {
        let replayEvents = replayEnvelopes.map(\.event)
        let activePending = AgentInteractivePromptEventReducer.pendingEvents(
            pendingEvents,
            excludingResolvedIn: replayEvents)
        let events = AgentInteractivePromptEventReducer.mergedEvents(replayEvents, activePending)
        return events.map { event in
            replayEnvelopes.first(where: { $0.event.eventID == event.eventID })
                ?? AgentEventEnvelope(replay: true, event: event)
        }
    }

    static func openLiveGate(_ gate: BridgeAgentEventReplayGate,
                             afterReplaying replayEnvelopes: [AgentEventEnvelope]) -> [AgentEventEnvelope] {
        gate.open()
    }
}
