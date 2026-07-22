import Foundation

enum AgentInteractivePromptEventReducer {
    private struct PromptKey: Hashable {
        let workspaceID: String
        let sessionID: String
        let promptID: String
    }

    static func pendingEvents(_ pendingEvents: [AgentEvent],
                              excludingResolvedIn replayEvents: [AgentEvent]) -> [AgentEvent] {
        // A resolved terminal only suppresses the pending delivery it
        // terminates. Token-bound (Codex) lifecycles match on the EXACT
        // lifecycle token — a late terminal for lifecycle A, even when the
        // Hub's publish authority rebased it after lifecycle B, must not
        // suppress B. Tokenless legacy prompts keep the promptID+seq rule
        // (and only tokenless terminals participate in it).
        var resolvedTokensByKey: [PromptKey: Set<String>] = [:]
        var latestTokenlessResolvedSeqByKey: [PromptKey: Int] = [:]
        for event in replayEvents where event.type == .interactivePromptResolved {
            guard let key = promptKey(for: event) else {
                continue
            }
            if let token = AgentInteractivePromptSidebarMessages.lifecycleToken(from: event) {
                resolvedTokensByKey[key, default: []].insert(token)
            } else if AgentInteractivePromptSidebarMessages.requiresLifecycleCapability(event) == false {
                // The strict legacy contract: only a tokenless NON-CAPABILITY
                // terminal creates a legacy tombstone. A tokenless Codex/
                // capability terminal proves nothing about a legacy opener.
                latestTokenlessResolvedSeqByKey[key] = max(latestTokenlessResolvedSeqByKey[key] ?? Int.min, event.seq)
            }
        }
        guard resolvedTokensByKey.isEmpty == false || latestTokenlessResolvedSeqByKey.isEmpty == false else {
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
                // A capability-bound pending prompt with a MISSING token
                // fails closed: no terminal may suppress it by promptID.
                return true
            }
            guard let resolvedSeq = latestTokenlessResolvedSeqByKey[key] else {
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
