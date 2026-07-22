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
    // Latest `panel_state_changed` patch per PANEL, immune to raw-buffer
    // eviction: a list -> subscribe gap must observe the newest state
    // transition even when >maxBufferedEvents unrelated events landed in
    // between. Replay is idempotent (merge-only, revision-fenced).
    private var latestStatePatchByPanelKey = [String: WorkspaceEvent]()

    func subscribe(workspaceID: String?,
                   sink: @escaping (WorkspaceEventEnvelope) -> Void) -> (UUID, [WorkspaceEventEnvelope]) {
        queue.sync {
            let subscriberID = UUID()
            subscribers[subscriberID] = Subscriber(workspaceID: workspaceID, sink: sink)
            // Workspace and panel views always load an authoritative snapshot via
            // list_workspaces / list_panels before subscribing. Replaying historical
            // FULL-ENTITY events here can resurrect stale workspaces after
            // reconnects, so those stay live-only. Typed `panel_state_changed`
            // PATCHES are the exception: they are merge-only and revision-
            // fenced on the client, so replaying them is idempotent — and it
            // CLOSES the list -> subscribe gap (a state change landing between
            // the snapshot and the server-side subscription would otherwise be
            // lost forever).
            let statePatchReplay = latestStatePatchByPanelKey.values
                .filter { event in
                    guard let workspaceID else {
                        return true
                    }
                    return workspaceID == event.workspaceID
                }
                .sorted { $0.seq < $1.seq }
                .map { WorkspaceEventEnvelope(replay: true, event: $0) }
            return (subscriberID, statePatchReplay)
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
            if event.kind == .panelStateChanged,
               let workspaceID = event.workspaceID,
               let panelID = event.panelID {
                latestStatePatchByPanelKey[workspaceID + "\u{1F}" + panelID] = event
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
