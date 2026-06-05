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

struct CodexAppServerApprovalRequest: Sendable {
    let requestID: String
    let requestIDValue: JSONValue
    let method: CodexAppServerApprovalMethod
    let threadID: String
    let turnID: String
    let itemID: String
    let startedAtMs: Int?
    let approvalID: String?
    let reason: String?
    let command: String?
    let cwd: String?
    let commandActions: [String]
    let networkHost: String?
    let networkProtocol: String?
    let grantRoot: String?

    init?(method methodName: String, requestID: JSONValue, params: [String: JSONValue]) {
        guard let method = CodexAppServerApprovalMethod(rawValue: methodName),
              let requestIDText = Self.stringID(from: requestID),
              let threadID = params["threadId"]?.stringValue,
              let turnID = params["turnId"]?.stringValue,
              let itemID = params["itemId"]?.stringValue else {
            return nil
        }

        self.requestID = requestIDText
        requestIDValue = requestID
        self.method = method
        self.threadID = threadID
        self.turnID = turnID
        self.itemID = itemID
        startedAtMs = params["startedAtMs"]?.intValue
        approvalID = Self.nonEmptyString(params["approvalId"])
        reason = Self.nonEmptyString(params["reason"])
        command = Self.nonEmptyString(params["command"])
        cwd = Self.nonEmptyString(params["cwd"])
        commandActions = Self.commandActionSummaries(from: params["commandActions"])

        let networkContext = params["networkApprovalContext"]?.objectValue
        networkHost = Self.nonEmptyString(networkContext?["host"])
        networkProtocol = Self.nonEmptyString(networkContext?["protocol"])
        grantRoot = Self.nonEmptyString(params["grantRoot"])
    }

    var promptID: String {
        let seed = [
            method.rawValue,
            requestID,
            threadID,
            turnID,
            itemID,
            approvalID ?? "",
        ].joined(separator: "\n")
        let digest = SHA256.hash(data: Data(seed.utf8))
        let prefix = digest.prefix(10).map { String(format: "%02x", $0) }.joined()
        return "codex-app-server-approval:\(prefix)"
    }

    var promptSource: String {
        switch method {
        case .commandExecution:
            return CodexAppServerApprovalPromptSource.commandExecution
        case .fileChange:
            return CodexAppServerApprovalPromptSource.fileChange
        }
    }

    func makePrompt() -> InteractivePrompt {
        InteractivePrompt(promptID: promptID,
                          vendor: "codex",
                          source: promptSource,
                          title: title,
                          body: body,
                          options: Self.options,
                          selectedIndex: 0)
    }

    func response(targetIndex: Int) throws -> JSONValue {
        guard Self.options.indices.contains(targetIndex) else {
            throw BridgeInternalError.invalidRequest("Unknown Codex approval option index.")
        }
        let decision = CodexAppServerApprovalDecision.allCases[targetIndex]
        return .object(["decision": decision.jsonValue])
    }

    private var title: String {
        switch method {
        case .commandExecution:
            return "Approve Codex command?"
        case .fileChange:
            return "Approve Codex file changes?"
        }
    }

    private var body: String {
        switch method {
        case .commandExecution:
            return commandBody
        case .fileChange:
            return fileChangeBody
        }
    }

    private var commandBody: String {
        var lines: [String] = []
        if let command {
            lines.append("Command: \(command)")
        }
        if let cwd {
            lines.append("Working directory: \(cwd)")
        }
        if let reason {
            lines.append("Reason: \(reason)")
        }
        if let networkHost {
            let label = networkProtocol.map { "\($0)://\(networkHost)" } ?? networkHost
            lines.append("Network: \(label)")
        }
        if !commandActions.isEmpty {
            lines.append("Actions:")
            lines.append(contentsOf: commandActions.map { "- \($0)" })
        }
        if lines.isEmpty {
            lines.append("Codex is asking to run a command.")
        }
        return lines.joined(separator: "\n")
    }

    private var fileChangeBody: String {
        var lines: [String] = []
        if let reason {
            lines.append("Reason: \(reason)")
        }
        if let grantRoot {
            lines.append("Grant root: \(grantRoot)")
        }
        if lines.isEmpty {
            lines.append("Codex is asking to apply file changes.")
        }
        return lines.joined(separator: "\n")
    }

    private static let options: [InteractivePromptOption] = CodexAppServerApprovalDecision.allCases.enumerated().map { offset, decision in
        InteractivePromptOption(index: offset,
                                label: decision.label,
                                inputSequence: decision.rawValue)
    }

    private static func stringID(from value: JSONValue) -> String? {
        switch value {
        case .string(let value):
            return value
        case .number(let value):
            if value.isFinite,
               value.rounded(.towardZero) == value,
               let exact = Int(exactly: value) {
                return String(exact)
            }
            return String(value)
        default:
            return nil
        }
    }

    private static func nonEmptyString(_ value: JSONValue?) -> String? {
        guard case .string(let text) = value else {
            return nil
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : text
    }

    private static func commandActionSummaries(from value: JSONValue?) -> [String] {
        guard let actions = value?.arrayValue else {
            return []
        }
        return actions.compactMap { action in
            guard let object = action.objectValue,
                  let type = object["type"]?.stringValue else {
                return nil
            }
            let command = nonEmptyString(object["command"])
            switch type {
            case "read":
                let path = nonEmptyString(object["path"])
                let name = nonEmptyString(object["name"])
                return [type, name, path, command].compactMap(\.self).joined(separator: " ")
            case "listFiles", "search":
                let path = nonEmptyString(object["path"])
                let query = nonEmptyString(object["query"])
                return [type, path, query, command].compactMap(\.self).joined(separator: " ")
            case "unknown":
                return [type, command].compactMap(\.self).joined(separator: " ")
            default:
                return [type, command].compactMap(\.self).joined(separator: " ")
            }
        }
    }
}

struct CodexAppServerApprovalPromptEntry: Sendable {
    let request: CodexAppServerApprovalRequest
    let prompt: InteractivePrompt
}

final class CodexAppServerApprovalPromptStore: @unchecked Sendable {
    private let lock = NSLock()
    private var entriesByPromptID: [String: CodexAppServerApprovalPromptEntry] = [:]

    @discardableResult
    func record(_ request: CodexAppServerApprovalRequest) -> InteractivePrompt {
        let prompt = request.makePrompt()
        let entry = CodexAppServerApprovalPromptEntry(request: request, prompt: prompt)
        lock.withCodexApprovalLock {
            entriesByPromptID[prompt.promptID] = entry
        }
        return prompt
    }

    func entry(promptID: String) -> CodexAppServerApprovalPromptEntry? {
        lock.withCodexApprovalLock {
            entriesByPromptID[promptID]
        }
    }

    func resolve(promptID: String, targetIndex: Int) throws -> JSONValue {
        let (_, response) = try resolveEntry(promptID: promptID, targetIndex: targetIndex)
        return response
    }

    func resolveEntry(promptID: String,
                      targetIndex: Int) throws -> (entry: CodexAppServerApprovalPromptEntry, response: JSONValue) {
        try lock.withCodexApprovalLock {
            guard let entry = entriesByPromptID[promptID] else {
                throw BridgeInternalError.notFound("Unknown Codex approval prompt.")
            }
            let response = try entry.request.response(targetIndex: targetIndex)
            entriesByPromptID.removeValue(forKey: promptID)
            return (entry, response)
        }
    }

    func remove(promptID: String) -> CodexAppServerApprovalPromptEntry? {
        let entry = lock.withCodexApprovalLock {
            entriesByPromptID.removeValue(forKey: promptID)
        }
        return entry
    }
}

private extension NSLock {
    func withCodexApprovalLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
