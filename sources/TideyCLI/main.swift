// TideyCLI/main.swift
// Single-file Swift CLI that replaces tidey-hook (bash) and nc -U socket calls.
//
// Usage:
//   tidey claude-hook <session-start|stop|notification|session-end|prompt-submit>
//   tidey send <plaintext message>
//
// Deployment target: macOS 12. No external dependencies.

import Foundation
import Darwin

// MARK: - Socket

/// Connect to a Unix domain socket, write a newline-terminated message, then close.
/// Returns silently on any error (fire-and-forget).
private func sendToSocket(path: String, message: String) {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return }

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)

    let maxLen = MemoryLayout.size(ofValue: addr.sun_path) - 1
    guard path.utf8.count <= maxLen else { close(fd); return }

    withUnsafeMutablePointer(to: &addr.sun_path) { sunPathPtr in
        sunPathPtr.withMemoryRebound(to: CChar.self, capacity: maxLen + 1) { ptr in
            path.withCString { cstr in
                _ = strcpy(ptr, cstr)
            }
        }
    }

    let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
    let connectResult = withUnsafePointer(to: &addr) { addrPtr in
        addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
            Darwin.connect(fd, sockaddrPtr, addrLen)
        }
    }
    guard connectResult == 0 else { close(fd); return }

    let payload = message + "\n"
    payload.withCString { buf in
        _ = Darwin.write(fd, buf, strlen(buf))
    }
    close(fd)
}

// MARK: - JSON Helpers

/// Minimal JSON string escaping (for values embedded in hand-built JSON).
private func jsonEscape(_ s: String) -> String {
    var result = ""
    result.reserveCapacity(s.count)
    for ch in s {
        switch ch {
        case "\"": result += "\\\""
        case "\\": result += "\\\\"
        case "\n": result += "\\n"
        case "\r": result += "\\r"
        case "\t": result += "\\t"
        default:
            if ch.asciiValue.map({ $0 < 0x20 }) == true {
                let code = ch.asciiValue!
                result += String(format: "\\u%04x", code)
            } else {
                result.append(ch)
            }
        }
    }
    return result
}

// MARK: - Transcript Parsing

/// Read a JSONL transcript file and return the text of the last assistant message.
private func lastAssistantText(transcriptPath: String) -> String? {
    let expandedPath = NSString(string: transcriptPath).expandingTildeInPath
    guard let data = FileManager.default.contents(atPath: expandedPath),
          let content = String(data: data, encoding: .utf8) else {
        return nil
    }

    var lastText: String?

    for line in content.components(separatedBy: .newlines) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { continue }
        guard let lineData = trimmed.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
              let message = obj["message"] as? [String: Any],
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

/// Extract text from a message's `content` field (string or array of blocks).
private func extractText(from message: [String: Any]) -> String {
    if let str = message["content"] as? String {
        return str.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    if let arr = message["content"] as? [[String: Any]] {
        let parts = arr.compactMap { block -> String? in
            guard block["type"] as? String == "text",
                  let text = block["text"] as? String else { return nil }
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        return parts.joined(separator: " ")
    }
    return ""
}

/// Collapse whitespace and truncate to a given length.
private func singleLineTruncated(_ s: String, maxLength: Int = 200) -> String {
    let collapsed = s.components(separatedBy: .whitespacesAndNewlines)
        .filter { !$0.isEmpty }
        .joined(separator: " ")
    if collapsed.count <= maxLength {
        return collapsed
    }
    return String(collapsed.prefix(maxLength))
}

// MARK: - Subcommands

private func handleSend(args: ArraySlice<String>, socketPath: String) {
    let message = args.joined(separator: " ")
    guard !message.isEmpty else { return }
    sendToSocket(path: socketPath, message: message)
}

private func handleClaudeHook(event: String, socketPath: String, workspaceID: String) {
    // Claude hooks are workspace-scoped. If the session did not inherit a
    // workspace identifier, fail closed rather than accidentally broadcasting
    // state/notifications to every workspace.
    guard !workspaceID.isEmpty else { return }

    switch event {
    case "session-start":
        sendToSocket(path: socketPath,
                     message: "report_shell_state prompt --workspace_id=\(workspaceID)")
        let titleJSON = "{\"action\":\"set_title\",\"workspace_id\":\"\(jsonEscape(workspaceID))\",\"title\":\"Claude Code\"}"
        sendToSocket(path: socketPath, message: titleJSON)

    case "notification":
        let json = "{\"action\":\"set_status\",\"workspace_id\":\"\(jsonEscape(workspaceID))\",\"key\":\"shell_state\",\"value\":\"Needs input\",\"icon\":\"bell.fill\",\"color\":\"#4C8DFF\"}"
        sendToSocket(path: socketPath, message: json)

    case "stop":
        // Read stdin JSON from Claude Code.
        let stdinData = FileHandle.standardInput.readDataToEndOfFile()
        var body = "Task completed"

        if let inputJSON = try? JSONSerialization.jsonObject(with: stdinData) as? [String: Any] {
            let transcriptPath = (inputJSON["transcript_path"] as? String)
                ?? (inputJSON["transcriptPath"] as? String)
                ?? ""
            if !transcriptPath.isEmpty,
               let text = lastAssistantText(transcriptPath: transcriptPath) {
                let truncated = singleLineTruncated(text)
                if !truncated.isEmpty {
                    body = truncated
                }
            }
        }

        let notifJSON = "{\"action\":\"notification.create\",\"workspace_id\":\"\(jsonEscape(workspaceID))\",\"title\":\"Claude Code\",\"body\":\"\(jsonEscape(body))\"}"
        sendToSocket(path: socketPath, message: notifJSON)
        sendToSocket(path: socketPath,
                     message: "report_shell_state prompt --workspace_id=\(workspaceID)")

    case "session-end":
        let json = "{\"action\":\"clear_status\",\"workspace_id\":\"\(jsonEscape(workspaceID))\",\"key\":\"shell_state\"}"
        sendToSocket(path: socketPath, message: json)
        let clearTitleJSON = "{\"action\":\"set_title\",\"workspace_id\":\"\(jsonEscape(workspaceID))\",\"title\":\"\"}"
        sendToSocket(path: socketPath, message: clearTitleJSON)

    case "prompt-submit":
        sendToSocket(path: socketPath,
                     message: "report_shell_state running --workspace_id=\(workspaceID)")

    default:
        // Unknown event — exit silently.
        break
    }
}

// MARK: - Main

let args = CommandLine.arguments          // args[0] = binary path
let socketPath = ProcessInfo.processInfo.environment["TIDEY_SOCKET_PATH"] ?? ""
let workspaceID = ProcessInfo.processInfo.environment["TIDEY_WORKSPACE_ID"] ?? ""

guard args.count >= 2 else { exit(0) }

let subcommand = args[1]

switch subcommand {
case "send":
    guard !socketPath.isEmpty else { exit(0) }
    handleSend(args: args.dropFirst(2), socketPath: socketPath)

case "claude-hook":
    guard args.count >= 3 else { exit(0) }
    guard !socketPath.isEmpty else { exit(0) }
    let event = args[2]

    // For events that don't need stdin, avoid blocking on stdin reads.
    // Only "stop" reads stdin.
    handleClaudeHook(event: event, socketPath: socketPath, workspaceID: workspaceID)

default:
    // Unknown subcommand — exit silently.
    break
}

exit(0)
