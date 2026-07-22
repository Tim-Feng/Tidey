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
    private enum NotifiedLifecycle: Equatable {
        case token(String)
        case capabilityTokenless
        case legacy
    }

    enum ResolveOutcome: Equatable {
        case clearedNotified
        case noneNotified
        case staleMismatch
    }

    private let queue = DispatchQueue(label: "com.tidey.remote-bridge.interactive-prompt-notification-deduper")
    private var notifiedLifecyclesBySessionID = [String: [String: NotifiedLifecycle]]()

    private static func lifecycle(for event: AgentEvent) -> NotifiedLifecycle {
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
        let incoming = Self.lifecycle(for: event)
        return queue.sync {
            var notified = notifiedLifecyclesBySessionID[sessionID] ?? [:]
            if let current = notified[promptID] {
                switch (current, incoming) {
                case (.token(let currentToken), .token(let incomingToken)):
                    guard currentToken != incomingToken else {
                        return false
                    }
                case (.token, .capabilityTokenless),
                     (.capabilityTokenless, .capabilityTokenless),
                     (.legacy, .legacy):
                    return false
                default:
                    break
                }
            }
            notified[promptID] = incoming
            notifiedLifecyclesBySessionID[sessionID] = notified
            return true
        }
    }

    @discardableResult
    func markResolved(_ event: AgentEvent, sessionID: String) -> ResolveOutcome {
        guard let promptID = AgentInteractivePromptSidebarMessages.promptID(from: event) else {
            return .noneNotified
        }
        let terminalToken = AgentInteractivePromptSidebarMessages.lifecycleToken(from: event)
        let terminalRequiresCapability = AgentInteractivePromptSidebarMessages.requiresLifecycleCapability(event)
        return queue.sync {
            guard let current = notifiedLifecyclesBySessionID[sessionID]?[promptID] else {
                return .noneNotified
            }
            let matches: Bool
            switch current {
            case .token(let currentToken):
                matches = terminalToken == currentToken
            case .capabilityTokenless:
                matches = false
            case .legacy:
                matches = terminalToken == nil && terminalRequiresCapability == false
            }
            guard matches else {
                return .staleMismatch
            }
            notifiedLifecyclesBySessionID[sessionID]?.removeValue(forKey: promptID)
            return .clearedNotified
        }
    }

    func remove(sessionID: String) {
        _ = queue.sync {
            notifiedLifecyclesBySessionID.removeValue(forKey: sessionID)
        }
    }
}
