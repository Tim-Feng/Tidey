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
    private let queue = DispatchQueue(label: "com.tidey.remote-bridge.interactive-prompt-notification-deduper")
    private var notifiedPromptIDsBySessionID = [String: Set<String>]()

    func shouldNotify(_ event: AgentEvent, sessionID: String) -> Bool {
        guard let promptID = AgentInteractivePromptSidebarMessages.promptID(from: event) else {
            return true
        }
        return queue.sync {
            var notifiedPromptIDs = notifiedPromptIDsBySessionID[sessionID] ?? []
            guard !notifiedPromptIDs.contains(promptID) else {
                return false
            }
            notifiedPromptIDs.insert(promptID)
            notifiedPromptIDsBySessionID[sessionID] = notifiedPromptIDs
            return true
        }
    }

    func markResolved(_ event: AgentEvent, sessionID: String) {
        guard let promptID = AgentInteractivePromptSidebarMessages.promptID(from: event) else {
            return
        }
        _ = queue.sync {
            notifiedPromptIDsBySessionID[sessionID]?.remove(promptID)
        }
    }

    func remove(sessionID: String) {
        _ = queue.sync {
            notifiedPromptIDsBySessionID.removeValue(forKey: sessionID)
        }
    }
}
