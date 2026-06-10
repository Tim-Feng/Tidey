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

struct CodexAppServerApprovalOption: Sendable {
    let decision: JSONValue
    let label: String
    let inputSequence: String
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
    let proposedExecpolicyAmendment: JSONValue?
    let proposedNetworkPolicyAmendments: [JSONValue]
    let availableDecisions: [JSONValue]
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
        proposedExecpolicyAmendment = params["proposedExecpolicyAmendment"] ?? params["proposed_execpolicy_amendment"]
        proposedNetworkPolicyAmendments = Self.arrayValues(params["proposedNetworkPolicyAmendments"] ?? params["proposed_network_policy_amendments"])
        availableDecisions = Self.arrayValues(params["availableDecisions"] ?? params["available_decisions"])
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
                          options: options,
                          selectedIndex: 0,
                          submitChannel: InteractivePromptSubmitChannel.codexAppServer)
    }

    func response(targetIndex: Int) throws -> JSONValue {
        let options = approvalOptions
        guard options.indices.contains(targetIndex) else {
            throw BridgeInternalError.invalidRequest("Unknown Codex approval option index.")
        }
        return .object(["decision": options[targetIndex].decision])
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

    private var approvalOptions: [CodexAppServerApprovalOption] {
        if !availableDecisions.isEmpty {
            return availableDecisions.map { Self.option(for: $0, method: method) }
        }
        switch method {
        case .commandExecution:
            var options = [
                Self.option(for: .string("accept"), method: method),
            ]
            if let proposedExecpolicyAmendment {
                options.append(Self.option(for: .object([
                    "acceptWithExecpolicyAmendment": .object([
                        "execpolicy_amendment": proposedExecpolicyAmendment,
                    ]),
                ]), method: method))
            }
            options.append(contentsOf: proposedNetworkPolicyAmendments.map { amendment in
                Self.option(for: .object([
                    "applyNetworkPolicyAmendment": .object([
                        "network_policy_amendment": amendment,
                    ]),
                ]), method: method)
            })
            options.append(Self.option(for: .string("decline"), method: method))
            return options
        case .fileChange:
            var options = [
                Self.option(for: .string("accept"), method: method),
            ]
            if grantRoot != nil {
                options.append(Self.option(for: .string("acceptForSession"), method: method))
            }
            options.append(Self.option(for: .string("decline"), method: method))
            return options
        }
    }

    private var options: [InteractivePromptOption] {
        approvalOptions.enumerated().map { offset, option in
            InteractivePromptOption(index: offset,
                                    label: option.label,
                                    inputSequence: option.inputSequence)
        }
    }

    private static func option(for decision: JSONValue, method: CodexAppServerApprovalMethod) -> CodexAppServerApprovalOption {
        let inputSequence = decisionIdentifier(decision)
        return CodexAppServerApprovalOption(decision: decision,
                                            label: label(for: decision, method: method),
                                            inputSequence: inputSequence)
    }

    private static func decisionIdentifier(_ decision: JSONValue) -> String {
        if let value = decision.stringValue {
            return value
        }
        if let object = decision.objectValue,
           let key = object.keys.sorted().first {
            return key
        }
        return "decision"
    }

    private static func label(for decision: JSONValue, method: CodexAppServerApprovalMethod) -> String {
        switch decision {
        case .string(let value):
            return label(forDecisionName: value, method: method)
        case .object(let object):
            if let payload = object["acceptWithExecpolicyAmendment"]?.objectValue,
               let amendment = payload["execpolicy_amendment"] {
                return "Yes, and don't ask again for commands that start with `\(execpolicyDisplay(amendment))` (p)"
            }
            if let payload = object["applyNetworkPolicyAmendment"]?.objectValue,
               let amendment = payload["network_policy_amendment"]?.objectValue {
                return networkPolicyLabel(amendment)
            }
            if let key = object.keys.sorted().first {
                return label(forDecisionName: key, method: method)
            }
            return "Approve"
        default:
            return "Approve"
        }
    }

    private static func label(forDecisionName decision: String, method: CodexAppServerApprovalMethod) -> String {
        switch decision {
        case "accept":
            switch method {
            case .commandExecution:
                return "Yes, proceed (y)"
            case .fileChange:
                return "Yes, make edits (y)"
            }
        case "acceptForSession":
            switch method {
            case .commandExecution:
                return "Yes, and don't ask again for this command in this session (p)"
            case .fileChange:
                return "Yes, and don't ask again for these files (p)"
            }
        case "decline":
            return "No, and tell Codex what to do differently (esc)"
        case "cancel":
            switch method {
            case .commandExecution:
                return "No, and tell Codex what to do differently (esc)"
            case .fileChange:
                return "Cancel"
            }
        case "approved_execpolicy_amendment", "acceptWithExecpolicyAmendment":
            return "Yes, and don't ask again for similar commands (p)"
        case "network_policy_amendment", "applyNetworkPolicyAmendment":
            return "Yes, and allow this host for this conversation (p)"
        case "denied":
            return "No, and tell Codex what to do differently (esc)"
        case "abort":
            return "Cancel"
        default:
            return decision
        }
    }

    private static func execpolicyDisplay(_ value: JSONValue) -> String {
        guard let parts = value.arrayValue?.compactMap(\.stringValue),
              !parts.isEmpty else {
            return "this command"
        }
        return parts.joined(separator: " ")
    }

    private static func networkPolicyLabel(_ amendment: [String: JSONValue]) -> String {
        let host = nonEmptyString(amendment["host"]) ?? "this host"
        switch amendment["action"]?.stringValue {
        case "deny":
            return "No, and block \(host) in the future"
        default:
            return "Yes, and allow \(host) for this conversation"
        }
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

    private static func arrayValues(_ value: JSONValue?) -> [JSONValue] {
        value?.arrayValue ?? []
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

    func entries() -> [CodexAppServerApprovalPromptEntry] {
        lock.withCodexApprovalLock {
            Array(entriesByPromptID.values)
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
