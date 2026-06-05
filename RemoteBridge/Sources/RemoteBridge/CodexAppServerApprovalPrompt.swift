import CryptoKit
import Foundation

enum CodexAppServerApprovalMethod: String, Equatable, Sendable {
    case commandExecution = "item/commandExecution/requestApproval"
    case fileChange = "item/fileChange/requestApproval"
}

enum CodexAppServerApprovalPromptSource {
    static let commandExecution = "codex_command_approval"
    static let fileChange = "codex_file_change_approval"
}

enum CodexAppServerApprovalDecision: String, CaseIterable, Equatable, Sendable {
    case accept
    case acceptForSession
    case decline
    case cancel

    var label: String {
        switch self {
        case .accept:
            return "Approve"
        case .acceptForSession:
            return "Approve for session"
        case .decline:
            return "Decline"
        case .cancel:
            return "Cancel"
        }
    }

    var jsonValue: JSONValue {
        .string(rawValue)
    }
}
