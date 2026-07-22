import Foundation

enum AgentInteractivePromptEventReducer {
    private struct PromptKey: Hashable {
        let workspaceID: String
        let sessionID: String
        let promptID: String
    }

    static func pendingEvents(_ pendingEvents: [AgentEvent],
                              excludingResolvedIn replayEvents: [AgentEvent]) -> [AgentEvent] {
        var resolvedTokensByKey: [PromptKey: Set<String>] = [:]
        var latestLegacyResolvedSeqByKey: [PromptKey: Int] = [:]
        for event in replayEvents where event.type == .interactivePromptResolved {
            guard let key = promptKey(for: event) else {
                continue
            }
            if let token = AgentInteractivePromptSidebarMessages.lifecycleToken(from: event) {
                resolvedTokensByKey[key, default: []].insert(token)
            } else if AgentInteractivePromptSidebarMessages.requiresLifecycleCapability(event) == false {
                latestLegacyResolvedSeqByKey[key] = max(latestLegacyResolvedSeqByKey[key] ?? Int.min,
                                                        event.seq)
            }
        }
        guard resolvedTokensByKey.isEmpty == false || latestLegacyResolvedSeqByKey.isEmpty == false else {
            return pendingEvents
        }
        return pendingEvents.filter { event in
            guard event.type == .interactivePrompt,
                  let key = promptKey(for: event) else {
                return true
            }
            if let token = AgentInteractivePromptSidebarMessages.lifecycleToken(from: event) {
                return resolvedTokensByKey[key]?.contains(token) != true
            }
            if AgentInteractivePromptSidebarMessages.requiresLifecycleCapability(event) {
                return true
            }
            guard let resolvedSeq = latestLegacyResolvedSeqByKey[key] else {
                return true
            }
            return event.seq > resolvedSeq
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
