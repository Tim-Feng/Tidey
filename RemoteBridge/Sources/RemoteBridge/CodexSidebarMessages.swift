import Foundation

enum CodexSidebarShellState {
    case prompt
    case running

    var socketValue: String {
        switch self {
        case .prompt:
            return "prompt"
        case .running:
            return "running"
        }
    }
}

enum CodexSidebarMessages {
    static func sessionActive(workspaceID: String, shellState: CodexSidebarShellState) -> [String] {
        [
            "report_shell_state \(shellState.socketValue) --workspace_id=\(workspaceID)",
            #"{"action":"set_title","workspace_id":"\#(jsonEscapedString(workspaceID))","title":"Codex"}"#
        ]
    }

    static func running(workspaceID: String) -> [String] {
        [
            "report_shell_state running --workspace_id=\(workspaceID)"
        ]
    }

    static func completed(workspaceID: String, body: String) -> [String] {
        [
            #"{"action":"notification.create","workspace_id":"\#(jsonEscapedString(workspaceID))","title":"Codex","body":"\#(jsonEscapedString(singleLineTruncatedString(body, maxLength: 200)))"}"#,
            "report_shell_state prompt --workspace_id=\(workspaceID)"
        ]
    }

    static func prompt(workspaceID: String) -> [String] {
        [
            "report_shell_state prompt --workspace_id=\(workspaceID)"
        ]
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
