import Foundation

// Applies the authoritative three-state lifecycle to list_panels /
// list_workspaces summaries. Panels/workspaces WITH a known agent session
// use the lifecycle aggregate (needs_input > working > idle) plus a
// monotonic per-entity state_revision; a known session with no lifecycle
// data yet is CONSERVATIVELY idle (never guessed Working from terminal
// output activity). Plain terminals keep the legacy carrier state.
enum AgentLifecycleListAugmenter {
    static func augmentPanel(_ panel: [String: JSONValue],
                             workspaceID: String,
                             panelID: String,
                             hasAgentSession: Bool,
                             store: AgentSessionLifecycleStore) -> [String: JSONValue] {
        guard hasAgentSession else {
            return panel  // legacy terminal-activity fallback stays
        }
        var augmented = panel
        if let aggregate = store.panelAggregate(workspaceID: workspaceID, panelID: panelID) {
            augmented["state"] = .string(aggregate.state.rawValue)
            augmented["state_revision"] = .number(Double(aggregate.revision))
        } else {
            augmented["state"] = .string(AgentSessionDisplayState.idle.rawValue)
            augmented["state_revision"] = .number(0)
        }
        return augmented
    }

    static func augmentWorkspace(_ workspace: [String: JSONValue],
                                 workspaceID: String,
                                 store: AgentSessionLifecycleStore) -> [String: JSONValue] {
        guard let aggregate = store.workspaceAggregate(workspaceID: workspaceID) else {
            return workspace  // no live agent sessions: legacy state stays
        }
        var augmented = workspace
        augmented["state"] = .string(aggregate.state.rawValue)
        augmented["state_revision"] = .number(Double(aggregate.revision))
        return augmented
    }
}
