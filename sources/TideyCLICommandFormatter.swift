import Foundation

struct ClaudeHookInputContext: Equatable {
    let sessionID: String?
    let transcriptPath: String?
    let cwd: String?
    let lastAssistantMessage: String?
}

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

    @objc(messagesForCodexHookEvent:workspaceID:payloadJSON:)
    static func messages(forCodexHookEvent event: String,
                         workspaceID: String,
                         payloadJSON: String?) -> [String] {
        guard !workspaceID.isEmpty else {
            return []
        }

        switch event {
        case "session-start":
            return [
                "report_shell_state prompt --workspace_id=\(workspaceID)",
                "{\"action\":\"set_title\",\"workspace_id\":\"\(jsonEscapedString(workspaceID))\",\"title\":\"Codex\"}"
            ]

        case "user-prompt-submit":
            return [
                "report_shell_state running --workspace_id=\(workspaceID)"
            ]

        case "stop":
            let body = notificationBodyForCodexStopEvent(payloadJSON: payloadJSON)
            return [
                "{\"action\":\"notification.create\",\"workspace_id\":\"\(jsonEscapedString(workspaceID))\",\"title\":\"Codex\",\"body\":\"\(jsonEscapedString(body))\"}",
                "report_shell_state prompt --workspace_id=\(workspaceID)"
            ]

        default:
            return []
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

    static func claudeHookInputContext(stdinData: Data?) -> ClaudeHookInputContext? {
        guard let stdinData,
              let inputJSON = try? JSONSerialization.jsonObject(with: stdinData) as? [String: Any] else {
            return nil
        }

        let transcriptPath = (inputJSON["transcript_path"] as? String)
            ?? (inputJSON["transcriptPath"] as? String)
        let sessionID = (inputJSON["session_id"] as? String)
            ?? (inputJSON["sessionId"] as? String)
            ?? transcriptPath.flatMap(sessionID(fromTranscriptPath:))
        let cwd = inputJSON["cwd"] as? String
        let lastAssistantMessage = (inputJSON["last_assistant_message"] as? String)
            ?? (inputJSON["lastAssistantMessage"] as? String)

        return ClaudeHookInputContext(sessionID: sessionID,
                                      transcriptPath: transcriptPath,
                                      cwd: cwd,
                                      lastAssistantMessage: lastAssistantMessage)
    }

    static func sessionID(fromTranscriptPath transcriptPath: String) -> String? {
        let expandedPath = NSString(string: transcriptPath).expandingTildeInPath
        let filename = URL(fileURLWithPath: expandedPath).lastPathComponent
        guard filename.hasSuffix(".jsonl") else {
            return nil
        }
        let sessionID = String(filename.dropLast(".jsonl".count))
        return sessionID.isEmpty ? nil : sessionID
    }

    static func writeClaudeRegistryFile(registryRoot: URL,
                                        workspaceID: String,
                                        sessionID: String,
                                        panelID: String,
                                        pid: Int32,
                                        cwd: String,
                                        createdAt: String,
                                        transcriptPath: String?,
                                        fileManager: FileManager = .default) throws -> URL {
        try fileManager.createDirectory(at: registryRoot, withIntermediateDirectories: true)

        let registryURL = registryRoot.appendingPathComponent("claude-\(sessionID).json", isDirectory: false)
        let tempURL = registryRoot.appendingPathComponent(".claude-registry.\(UUID().uuidString)", isDirectory: false)

        var payload: [String: Any] = [
            "version": 1,
            "vendor": "claude",
            "workspace_id": workspaceID,
            "session_id": sessionID,
            "panel_id": panelID,
            "pid": pid,
            "cwd": cwd,
            "created_at": createdAt,
        ]
        if let transcriptPath, !transcriptPath.isEmpty {
            payload["transcript_path"] = transcriptPath
        }

        let data = try JSONSerialization.data(withJSONObject: payload)
        try data.write(to: tempURL, options: .atomic)
        if fileManager.fileExists(atPath: registryURL.path) {
            try fileManager.removeItem(at: registryURL)
        }
        try fileManager.moveItem(at: tempURL, to: registryURL)
        return registryURL
    }

    static func removeClaudeRegistryFile(registryRoot: URL,
                                         sessionID: String,
                                         fileManager: FileManager = .default) throws {
        let registryURL = registryRoot.appendingPathComponent("claude-\(sessionID).json", isDirectory: false)
        guard fileManager.fileExists(atPath: registryURL.path) else {
            return
        }
        try fileManager.removeItem(at: registryURL)
    }

    private static func notificationBodyForStopEvent(stdinData: Data?,
                                                     transcriptLoader: (String) -> String?) -> String {
        let defaultBody = "Task completed"
        guard let inputContext = claudeHookInputContext(stdinData: stdinData) else {
            return defaultBody
        }
        if let lastAssistantMessage = inputContext.lastAssistantMessage,
           !lastAssistantMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let truncated = singleLineTruncatedString(lastAssistantMessage, maxLength: 200)
            return truncated.isEmpty ? defaultBody : truncated
        }
        guard let transcriptPath = inputContext.transcriptPath, !transcriptPath.isEmpty else {
            return defaultBody
        }
        guard let transcriptContent = transcriptLoader(transcriptPath),
              let text = lastAssistantText(inTranscriptContent: transcriptContent) else {
            return defaultBody
        }

        let truncated = singleLineTruncatedString(text, maxLength: 200)
        return truncated.isEmpty ? defaultBody : truncated
    }

    private static func notificationBodyForCodexStopEvent(payloadJSON: String?) -> String {
        let defaultBody = "Task completed"
        guard let payloadJSON,
              let payloadData = payloadJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else {
            return defaultBody
        }

        let candidates: [String?] = [
            object["last-assistant-message"] as? String,
            object["last_assistant_message"] as? String,
            object["lastAssistantMessage"] as? String,
        ]

        guard let text = candidates.compactMap({ $0 }).first,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
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
