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
            // Workspace and panel views always load an authoritative snapshot via
            // list_workspaces / list_panels before subscribing. Replaying historical
            // workspace events here can resurrect stale workspaces after reconnects
            // or Tidey socket failover, so only deliver live events.
            return (subscriberID, [])
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
