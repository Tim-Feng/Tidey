import Foundation

enum AgentInteractivePromptSidebarMessages {
    static func messages(for event: AgentEvent, workspaceID: String) -> [String] {
        switch event.type {
        case .interactivePrompt:
            return [
                notificationMessage(for: event, workspaceID: workspaceID),
                "report_shell_state needs_input --workspace_id=\(workspaceID)",
            ]

        case .interactivePromptResolved:
            return [
                "report_shell_state running --workspace_id=\(workspaceID)",
            ]

        default:
            return []
        }
    }

    static func lifecycleToken(from event: AgentEvent) -> String? {
        event.metadata?["lifecycle_token"]
            ?? event.payload?.objectValue?["lifecycle_token"]?.stringValue
    }

    // Capability classification: ANY trusted Codex-native signal (vendor,
    // approval source, or the app-server submit channel) marks the lifecycle
    // as capability-bound. A capability-bound prompt/terminal missing its
    // token fails closed — it never degrades to the legacy promptID-only
    // contract.
    static func requiresLifecycleCapability(_ event: AgentEvent) -> Bool {
        if event.vendor == "codex" {
            return true
        }
        let source = event.metadata?["source"]
            ?? event.payload?.objectValue?["source"]?.stringValue
        if let source, source.hasPrefix("codex_") {
            return true
        }
        let channel = event.metadata?["submit_channel"]
            ?? event.payload?.objectValue?["submit_channel"]?.stringValue
        return channel == "codex_app_server"
    }

    // THE single lifecycle-matching contract, shared by the Hub's active
    // lookup, the historical trim and the latest-resolved lookup: a token-
    // bound opener is closed only by ITS token; a capability-bound tokenless
    // opener is closed by no live terminal; a legacy opener is closed only by
    // a TOKENLESS NON-CAPABILITY terminal.
    static func terminalCloses(openerLifecycleToken: String?,
                               openerRequiresCapability: Bool,
                               terminal: AgentEvent) -> Bool {
        let terminalToken = lifecycleToken(from: terminal)
        if let openerLifecycleToken {
            return terminalToken == openerLifecycleToken
        }
        if openerRequiresCapability {
            return false
        }
        return terminalToken == nil && requiresLifecycleCapability(terminal) == false
    }

    static func promptID(from event: AgentEvent) -> String? {
        let promptID = event.metadata?["prompt_id"]
            ?? event.payload?.objectValue?["prompt_id"]?.stringValue
        guard let promptID,
              promptID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return nil
        }
        return promptID
    }

    private static func notificationMessage(for event: AgentEvent, workspaceID: String) -> String {
        let title = agentTitle(for: event.vendor)
        let body = promptBody(for: event)
        return #"{"action":"notification.create","workspace_id":"\#(jsonEscapedString(workspaceID))","title":"\#(jsonEscapedString(title))","body":"\#(jsonEscapedString(singleLineTruncatedString(body, maxLength: 200)))"}"#
    }

    private static func promptBody(for event: AgentEvent) -> String {
        let payload = event.payload?.objectValue
        let promptTitle = payload?["title"]?.stringValue
            ?? event.text
        let promptBody = payload?["body"]?.stringValue

        switch (nonEmpty(promptTitle), nonEmpty(promptBody)) {
        case let (.some(title), .some(body)) where title != body:
            return "\(title): \(body)"
        case let (.some(title), _):
            return title
        case let (_, .some(body)):
            return body
        case _:
            return "\(agentTitle(for: event.vendor)) needs input."
        }
    }

    private static func agentTitle(for vendor: String) -> String {
        switch vendor.lowercased() {
        case "codex":
            return "Codex"
        case "claude":
            return "Claude Code"
        default:
            return vendor.isEmpty ? "Agent" : vendor
        }
    }

    private static func nonEmpty(_ string: String?) -> String? {
        guard let string else {
            return nil
        }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func singleLineTruncatedString(_ string: String, maxLength: Int) -> String {
        let collapsed = string.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        if collapsed.count <= maxLength {
            return collapsed
        }
        return String(collapsed.prefix(maxLength))
    }

    private static func jsonEscapedString(_ string: String) -> String {
        var result = ""
        result.reserveCapacity(string.count)
        for character in string {
            switch character {
            case "\"":
                result += "\\\""
            case "\\":
                result += "\\\\"
            case "\n":
                result += "\\n"
            case "\r":
                result += "\\r"
            case "\t":
                result += "\\t"
            default:
                if character.asciiValue.map({ $0 < 0x20 }) == true {
                    result += String(format: "\\u%04x", character.asciiValue!)
                } else {
                    result.append(character)
                }
            }
        }
        return result
    }
}

final class AgentInteractivePromptNotificationDeduper: @unchecked Sendable {
    // The notified lifecycle for a promptID. Identity rules:
    // - capability prompt WITH token: session + promptID + exact token;
    // - capability prompt MISSING its token: fail closed — it never degrades
    //   to an eventID-based lifecycle, and no live terminal can clear it;
    // - legacy tokenless prompt: session + promptID (eventID changes before
    //   the terminal are duplicates).
    enum NotifiedLifecycle: Equatable {
        case token(String)
        case capabilityTokenless
        case legacy
    }

    private let queue = DispatchQueue(label: "com.tidey.remote-bridge.interactive-prompt-notification-deduper")
    private var notifiedLifecycleByPromptIDBySessionID = [String: [String: NotifiedLifecycle]]()

    private static func incomingLifecycle(for event: AgentEvent) -> NotifiedLifecycle {
        if let token = AgentInteractivePromptSidebarMessages.lifecycleToken(from: event) {
            return .token(token)
        }
        if AgentInteractivePromptSidebarMessages.requiresLifecycleCapability(event) {
            return .capabilityTokenless
        }
        return .legacy
    }

    func shouldNotify(_ event: AgentEvent, sessionID: String) -> Bool {
        guard let promptID = AgentInteractivePromptSidebarMessages.promptID(from: event) else {
            return true
        }
        let incoming = Self.incomingLifecycle(for: event)
        return queue.sync {
            var notified = notifiedLifecycleByPromptIDBySessionID[sessionID] ?? [:]
            if let recorded = notified[promptID] {
                switch (recorded, incoming) {
                case (.token(let recordedToken), .token(let incomingToken)):
                    // Only the EXACT same delivery dedupes; a different token
                    // is a NEW lifecycle and becomes current.
                    guard recordedToken != incomingToken else {
                        return false
                    }
                case (.token, .capabilityTokenless):
                    // A malformed (tokenless) capability duplicate can never
                    // replace or re-notify a token-bound lifecycle.
                    return false
                case (.capabilityTokenless, .capabilityTokenless),
                     (.legacy, .legacy):
                    // Same promptID before the terminal: a duplicate, even
                    // with a different eventID.
                    return false
                default:
                    break
                }
            }
            notified[promptID] = incoming
            notifiedLifecycleByPromptIDBySessionID[sessionID] = notified
            return true
        }
    }

    enum ResolveOutcome {
        // The terminal ended the delivery currently notified for this prompt.
        case clearedNotified
        // No notified state existed for this prompt.
        case noneNotified
        // The terminal belongs to a DIFFERENT (stale) lifecycle than the one
        // currently notified: nothing may be cleared and no state-restoring
        // side effect may run for it.
        case staleMismatch
    }

    @discardableResult
    // Source identity switch: the session's notified lifecycles belong to
    // the old source and must not suppress the new source's deliveries.
    func clearSession(_ sessionID: String) {
        queue.sync {
            _ = notifiedLifecycleByPromptIDBySessionID.removeValue(forKey: sessionID)
        }
    }

    func markResolved(_ event: AgentEvent, sessionID: String) -> ResolveOutcome {
        guard let promptID = AgentInteractivePromptSidebarMessages.promptID(from: event) else {
            return .noneNotified
        }
        let token = AgentInteractivePromptSidebarMessages.lifecycleToken(from: event)
        let terminalIsCapabilityBound = AgentInteractivePromptSidebarMessages.requiresLifecycleCapability(event)
        return queue.sync {
            guard let recorded = notifiedLifecycleByPromptIDBySessionID[sessionID]?[promptID] else {
                return .noneNotified
            }
            let matches: Bool
            switch recorded {
            case .token(let recordedToken):
                matches = token == recordedToken
            case .capabilityTokenless:
                // No live terminal can prove it ends a tokenless capability
                // lifecycle; only an authoritative replacement may.
                matches = false
            case .legacy:
                // Legacy lifecycles only accept the legacy tokenless
                // contract; a tokenful or capability-bound terminal is a
                // different domain.
                matches = token == nil && terminalIsCapabilityBound == false
            }
            guard matches else {
                return .staleMismatch
            }
            notifiedLifecycleByPromptIDBySessionID[sessionID]?.removeValue(forKey: promptID)
            return .clearedNotified
        }
    }

    func remove(sessionID: String) {
        _ = queue.sync {
            notifiedLifecycleByPromptIDBySessionID.removeValue(forKey: sessionID)
        }
    }
}
