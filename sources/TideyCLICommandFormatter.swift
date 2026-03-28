import Foundation

@objc(TideyCLICommandFormatter)
final class TideyCLICommandFormatter: NSObject {
    @objc(lastAssistantTextInTranscriptContent:)
    static func lastAssistantText(inTranscriptContent transcriptContent: String) -> String? {
        var lastText: String?

        for line in transcriptContent.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else {
                continue
            }
            guard let lineData = trimmed.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let message = object["message"] as? [String: Any],
                  message["role"] as? String == "assistant" else {
                continue
            }

            let extracted = extractText(from: message)
            if !extracted.isEmpty {
                lastText = extracted
            }
        }

        return lastText
    }

    @objc(singleLineTruncatedString:maxLength:)
    static func singleLineTruncatedString(_ string: String, maxLength: Int) -> String {
        let collapsed = string.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        if collapsed.count <= maxLength {
            return collapsed
        }
        return String(collapsed.prefix(maxLength))
    }

    @objc(messagesForClaudeHookEvent:workspaceID:stdinJSON:transcriptContent:)
    static func messages(forClaudeHookEvent event: String,
                         workspaceID: String,
                         stdinJSON: String?,
                         transcriptContent: String?) -> [String] {
        let stdinData = stdinJSON?.data(using: .utf8)
        return messages(forClaudeHookEvent: event,
                        workspaceID: workspaceID,
                        stdinData: stdinData) { _ in
            transcriptContent
        }
    }

    static func messages(forClaudeHookEvent event: String,
                         workspaceID: String,
                         stdinData: Data?,
                         transcriptLoader: (String) -> String?) -> [String] {
        guard !workspaceID.isEmpty else {
            return []
        }

        switch event {
        case "session-start":
            return [
                "report_shell_state prompt --workspace_id=\(workspaceID)",
                "{\"action\":\"set_title\",\"workspace_id\":\"\(jsonEscapedString(workspaceID))\",\"title\":\"Claude Code\"}"
            ]

        case "notification":
            return [
                "{\"action\":\"set_status\",\"workspace_id\":\"\(jsonEscapedString(workspaceID))\",\"key\":\"shell_state\",\"value\":\"Needs input\",\"icon\":\"bell.fill\",\"color\":\"#4C8DFF\"}"
            ]

        case "stop":
            let body = notificationBodyForStopEvent(stdinData: stdinData,
                                                    transcriptLoader: transcriptLoader)
            return [
                "{\"action\":\"notification.create\",\"workspace_id\":\"\(jsonEscapedString(workspaceID))\",\"title\":\"Claude Code\",\"body\":\"\(jsonEscapedString(body))\"}",
                "report_shell_state prompt --workspace_id=\(workspaceID)"
            ]

        case "session-end":
            return [
                "{\"action\":\"clear_status\",\"workspace_id\":\"\(jsonEscapedString(workspaceID))\",\"key\":\"shell_state\"}",
                "{\"action\":\"set_title\",\"workspace_id\":\"\(jsonEscapedString(workspaceID))\",\"title\":\"\"}"
            ]

        case "prompt-submit":
            return [
                "report_shell_state running --workspace_id=\(workspaceID)"
            ]

        default:
            return []
        }
    }

    private static func notificationBodyForStopEvent(stdinData: Data?,
                                                     transcriptLoader: (String) -> String?) -> String {
        let defaultBody = "Task completed"
        guard let stdinData,
              let inputJSON = try? JSONSerialization.jsonObject(with: stdinData) as? [String: Any] else {
            return defaultBody
        }

        let transcriptPath = (inputJSON["transcript_path"] as? String)
            ?? (inputJSON["transcriptPath"] as? String)
            ?? ""
        guard !transcriptPath.isEmpty,
              let transcriptContent = transcriptLoader(transcriptPath),
              let text = lastAssistantText(inTranscriptContent: transcriptContent) else {
            return defaultBody
        }

        let truncated = singleLineTruncatedString(text, maxLength: 200)
        return truncated.isEmpty ? defaultBody : truncated
    }

    private static func extractText(from message: [String: Any]) -> String {
        if let string = message["content"] as? String {
            return string.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let array = message["content"] as? [[String: Any]] {
            let parts = array.compactMap { block -> String? in
                guard block["type"] as? String == "text",
                      let text = block["text"] as? String else {
                    return nil
                }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
            return parts.joined(separator: " ")
        }
        return ""
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
