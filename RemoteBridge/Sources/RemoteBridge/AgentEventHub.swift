import Foundation

final class AgentEventHub {
    private struct Subscriber {
        let workspaceID: String?
        let sink: (AgentEventEnvelope) -> Void
    }

    private struct SessionState {
        var seenEventIDs = Set<String>()
        var bufferedEvents = [AgentEvent]()
    }

    private let queue = DispatchQueue(label: "com.tidey.remote-bridge.agent-event-hub")
    private var subscribers = [UUID: Subscriber]()
    private var sessions = [String: SessionState]()
    private let maxBufferedEvents = 400
    private let maxSeenEventIDs = 4000

    func subscribe(workspaceID: String?,
                   sink: @escaping (AgentEventEnvelope) -> Void) -> (UUID, [AgentEventEnvelope]) {
        queue.sync {
            let subscriberID = UUID()
            subscribers[subscriberID] = Subscriber(workspaceID: workspaceID, sink: sink)

            let replay = sessions.values
                .flatMap(\.bufferedEvents)
                .filter { event in
                    guard let workspaceID else {
                        return true
                    }
                    return event.workspaceID == workspaceID
                }
                .sorted { lhs, rhs in
                    if lhs.timestamp == rhs.timestamp {
                        return lhs.seq < rhs.seq
                    }
                    return lhs.timestamp < rhs.timestamp
                }
                .map { AgentEventEnvelope(replay: true, event: $0) }
            return (subscriberID, replay)
        }
    }

    func unsubscribe(_ subscriberID: UUID) {
        _ = queue.sync {
            subscribers.removeValue(forKey: subscriberID)
        }
    }

    func publish(_ event: AgentEvent) {
        let deliveries: [Subscriber] = queue.sync {
            var state = sessions[event.sessionID] ?? SessionState()
            if state.seenEventIDs.contains(event.eventID) {
                return []
            }

            state.seenEventIDs.insert(event.eventID)
            if state.seenEventIDs.count > maxSeenEventIDs {
                state.seenEventIDs = Set(state.seenEventIDs.suffix(maxSeenEventIDs / 2))
            }

            state.bufferedEvents.append(event)
            if state.bufferedEvents.count > maxBufferedEvents {
                state.bufferedEvents.removeFirst(state.bufferedEvents.count - maxBufferedEvents)
            }
            sessions[event.sessionID] = state

            let deliveries = subscribers.values.filter { subscriber in
                guard let workspaceID = subscriber.workspaceID else {
                    return true
                }
                return workspaceID == event.workspaceID
            }
            return Array(deliveries)
        }

        let envelope = AgentEventEnvelope(replay: false, event: event)
        for subscriber in deliveries {
            subscriber.sink(envelope)
        }
    }
}
