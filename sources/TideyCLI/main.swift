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
    let stdinData = event == "stop" ? FileHandle.standardInput.readDataToEndOfFile() : nil
    let messages = TideyCLICommandFormatter.messages(forClaudeHookEvent: event,
                                                     workspaceID: workspaceID,
                                                     stdinData: stdinData) { transcriptPath in
        let expandedPath = NSString(string: transcriptPath).expandingTildeInPath
        guard let data = FileManager.default.contents(atPath: expandedPath) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
    for message in messages {
        sendToSocket(path: socketPath, message: message)
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
