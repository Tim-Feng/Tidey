import Foundation

final class AgentEventHub {
    private struct Subscriber {
        let workspaceID: String?
        let sink: (AgentEventEnvelope) -> Void
    }

    private struct SessionState {
        var seenEventIDs = Set<String>()
        var bufferedEvents = [AgentEvent]()
        var latestSessionStarted: AgentEvent?
        var isActive = false
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
                .flatMap { state -> [AgentEvent] in
                    var events = state.bufferedEvents
                    if state.isActive,
                       let sessionStarted = state.latestSessionStarted,
                       !events.contains(where: { $0.eventID == sessionStarted.eventID }) {
                        events.append(sessionStarted)
                    }
                    return events
                }
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

    @discardableResult
    func migrateSession(sessionID: String,
                        toWorkspaceID workspaceID: String,
                        panelID: String?) -> Int {
        queue.sync {
            guard var state = sessions[sessionID], !state.bufferedEvents.isEmpty else {
                if sessions[sessionID]?.latestSessionStarted == nil {
                    return 0
                }
                guard var state = sessions[sessionID] else {
                    return 0
                }
                if let sessionStarted = state.latestSessionStarted {
                    state.latestSessionStarted = Self.rewritten(event: sessionStarted,
                                                                workspaceID: workspaceID,
                                                                panelID: panelID)
                    sessions[sessionID] = state
                    return 1
                }
                return 0
            }

            state.bufferedEvents = state.bufferedEvents.map { event in
                Self.rewritten(event: event, workspaceID: workspaceID, panelID: panelID)
            }
            if let sessionStarted = state.latestSessionStarted {
                state.latestSessionStarted = Self.rewritten(event: sessionStarted,
                                                            workspaceID: workspaceID,
                                                            panelID: panelID)
            }
            let migratedCount = state.bufferedEvents.count
            sessions[sessionID] = state
            return migratedCount
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
            switch event.type {
            case .sessionStarted:
                state.latestSessionStarted = event
                state.isActive = true
            case .sessionEnded:
                state.isActive = false
            default:
                break
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

    private static func rewritten(event: AgentEvent,
                                  workspaceID: String,
                                  panelID: String?) -> AgentEvent {
        var metadata = event.metadata ?? [:]
        if let panelID, !panelID.isEmpty {
            metadata["panel_id"] = panelID
        } else {
            metadata.removeValue(forKey: "panel_id")
        }
        return AgentEvent(eventID: event.eventID,
                          seq: event.seq,
                          vendor: event.vendor,
                          workspaceID: workspaceID,
                          sessionID: event.sessionID,
                          timestamp: event.timestamp,
                          type: event.type,
                          role: event.role,
                          text: event.text,
                          name: event.name,
                          input: event.input,
                          output: event.output,
                          toolCallID: event.toolCallID,
                          metadata: metadata.isEmpty ? nil : metadata)
    }
}
