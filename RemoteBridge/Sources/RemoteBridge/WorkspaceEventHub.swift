import Foundation

final class WorkspaceEventHub {
    private struct Subscriber {
        let workspaceID: String?
        let sink: (WorkspaceEventEnvelope) -> Void
    }

    private let queue = DispatchQueue(label: "com.tidey.remote-bridge.workspace-event-hub")
    private var subscribers = [UUID: Subscriber]()
    private var bufferedEvents = [WorkspaceEvent]()
    private var seenEventIDs = Set<String>()
    private let maxBufferedEvents = 400
    private let maxSeenEventIDs = 4000

    func subscribe(workspaceID: String?,
                   sink: @escaping (WorkspaceEventEnvelope) -> Void) -> (UUID, [WorkspaceEventEnvelope]) {
        queue.sync {
            let subscriberID = UUID()
            subscribers[subscriberID] = Subscriber(workspaceID: workspaceID, sink: sink)

            let replay = bufferedEvents
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
                .map { WorkspaceEventEnvelope(replay: true, event: $0) }
            return (subscriberID, replay)
        }
    }

    func unsubscribe(_ subscriberID: UUID) {
        _ = queue.sync {
            subscribers.removeValue(forKey: subscriberID)
        }
    }

    func publish(_ event: WorkspaceEvent) {
        let deliveries: [Subscriber] = queue.sync {
            if seenEventIDs.contains(event.eventID) {
                return []
            }

            seenEventIDs.insert(event.eventID)
            if seenEventIDs.count > maxSeenEventIDs {
                seenEventIDs = Set(seenEventIDs.suffix(maxSeenEventIDs / 2))
            }

            bufferedEvents.append(event)
            if bufferedEvents.count > maxBufferedEvents {
                bufferedEvents.removeFirst(bufferedEvents.count - maxBufferedEvents)
            }

            return subscribers.values.filter { subscriber in
                guard let workspaceID = subscriber.workspaceID else {
                    return true
                }
                return workspaceID == event.workspaceID
            }
        }

        let envelope = WorkspaceEventEnvelope(replay: false, event: event)
        for subscriber in deliveries {
            subscriber.sink(envelope)
        }
    }
}
