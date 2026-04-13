import Foundation

final class AgentEventHub {
    struct FetchResult {
        let events: [AgentEvent]
        let oldestSeq: Int
        let newestSeq: Int
        let hasMore: Bool
    }

    private struct Subscriber {
        let workspaceID: String?
        let sessionID: String?
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
    private let maxBufferedEvents = 2000
    private let maxSeenEventIDs = 4000

    func subscribe(workspaceID: String?,
                   sessionID: String? = nil,
                   sinceSeq: Int? = nil,
                   sink: @escaping (AgentEventEnvelope) -> Void) -> (UUID, [AgentEventEnvelope]) {
        queue.sync {
            let subscriberID = UUID()
            subscribers[subscriberID] = Subscriber(workspaceID: workspaceID, sessionID: sessionID, sink: sink)

            let replay = replayEvents(workspaceID: workspaceID, sessionID: sessionID, sinceSeq: sinceSeq)
                .map { AgentEventEnvelope(replay: true, event: $0) }
            return (subscriberID, replay)
        }
    }

    func fetch(workspaceID: String,
               sessionID: String? = nil,
               limit: Int,
               beforeSeq: Int? = nil,
               afterSeq: Int? = nil) -> FetchResult {
        queue.sync {
            let effectiveLimit = max(limit, 1)
            let matchingEvents: [AgentEvent]

            if let sessionID, let state = sessions[sessionID] {
                matchingEvents = state.bufferedEvents.filter { event in
                    guard event.workspaceID == workspaceID else {
                        return false
                    }
                    if let beforeSeq {
                        return event.seq < beforeSeq
                    }
                    if let afterSeq {
                        return event.seq > afterSeq
                    }
                    return true
                }.sorted { $0.seq < $1.seq }
            } else {
                matchingEvents = sessions.values
                    .flatMap(\.bufferedEvents)
                    .filter { event in
                        guard event.workspaceID == workspaceID else {
                            return false
                        }
                        if let beforeSeq {
                            return event.seq < beforeSeq
                        }
                        if let afterSeq {
                            return event.seq > afterSeq
                        }
                        return true
                    }
                    .sorted { lhs, rhs in
                        if lhs.timestamp == rhs.timestamp {
                            return lhs.seq < rhs.seq
                        }
                        return lhs.timestamp < rhs.timestamp
                    }
            }

            let slice: [AgentEvent]
            if afterSeq != nil {
                slice = Array(matchingEvents.prefix(effectiveLimit))
            } else {
                slice = Array(matchingEvents.suffix(effectiveLimit))
            }
            let oldestSeq = slice.first?.seq ?? 0
            let newestSeq = slice.last?.seq ?? 0
            let hasMore = matchingEvents.count > slice.count
            return FetchResult(events: slice, oldestSeq: oldestSeq, newestSeq: newestSeq, hasMore: hasMore)
        }
    }

    private func replayEvents(workspaceID: String?, sessionID: String?, sinceSeq: Int?) -> [AgentEvent] {
        let filteredStates: [SessionState]
        if let sessionID, let state = sessions[sessionID] {
            filteredStates = [state]
        } else {
            filteredStates = Array(sessions.values)
        }

        return filteredStates
            .flatMap { state -> [AgentEvent] in
                var events = state.bufferedEvents
                if state.isActive,
                   let sessionStarted = state.latestSessionStarted,
                   !events.contains(where: { $0.eventID == sessionStarted.eventID }),
                   sinceSeq == nil {
                    events.append(sessionStarted)
                }
                return events
            }
            .filter { event in
                if let workspaceID, event.workspaceID != workspaceID {
                    return false
                }
                if let sessionID, event.sessionID != sessionID {
                    return false
                }
                if let sinceSeq, event.seq <= sinceSeq {
                    return false
                }
                return true
            }
            .sorted { lhs, rhs in
                if lhs.sessionID == rhs.sessionID {
                    return lhs.seq < rhs.seq
                }
                if lhs.timestamp == rhs.timestamp {
                    return lhs.seq < rhs.seq
                }
                return lhs.timestamp < rhs.timestamp
            }
    }

    func unsubscribe(_ subscriberID: UUID) {
        _ = queue.sync {
            subscribers.removeValue(forKey: subscriberID)
        }
    }

    func oldestBufferedSeq(sessionID: String) -> Int? {
        queue.sync {
            sessions[sessionID]?.bufferedEvents
                .map(\.seq)
                .min()
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

    func publish(_ event: AgentEvent, deliverToSubscribers: Bool = true) {
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

            guard deliverToSubscribers else {
                return []
            }
            let deliveries = subscribers.values.filter { subscriber in
                if let workspaceID = subscriber.workspaceID, workspaceID != event.workspaceID {
                    return false
                }
                if let sessionID = subscriber.sessionID, sessionID != event.sessionID {
                    return false
                }
                return true
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
