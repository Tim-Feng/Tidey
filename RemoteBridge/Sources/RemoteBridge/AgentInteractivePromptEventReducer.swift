import Foundation

enum AgentInteractivePromptEventReducer {
    private struct PromptKey: Hashable {
        let workspaceID: String
        let sessionID: String
        let promptID: String
    }

    static func pendingEvents(_ pendingEvents: [AgentEvent],
                              excludingResolvedIn replayEvents: [AgentEvent]) -> [AgentEvent] {
        let resolvedKeys = Set(replayEvents.compactMap { event -> PromptKey? in
            guard event.type == .interactivePromptResolved else {
                return nil
            }
            return promptKey(for: event)
        })
        guard resolvedKeys.isEmpty == false else {
            return pendingEvents
        }
        return pendingEvents.filter { event in
            guard event.type == .interactivePrompt,
                  let key = promptKey(for: event) else {
                return true
            }
            return resolvedKeys.contains(key) == false
        }
    }

    static func mergedEvents(_ events: [AgentEvent],
                             _ additionalEvents: [AgentEvent]) -> [AgentEvent] {
        var seen = Set<String>()
        return (events + additionalEvents)
            .filter { event in
                guard seen.contains(event.eventID) == false else {
                    return false
                }
                seen.insert(event.eventID)
                return true
            }
            .sorted { lhs, rhs in
                if lhs.timestamp == rhs.timestamp {
                    return lhs.seq < rhs.seq
                }
                return lhs.timestamp < rhs.timestamp
            }
    }

    private static func promptKey(for event: AgentEvent) -> PromptKey? {
        guard let promptID = AgentInteractivePromptSidebarMessages.promptID(from: event) else {
            return nil
        }
        return PromptKey(workspaceID: event.workspaceID,
                         sessionID: event.sessionID,
                         promptID: promptID)
    }
}
