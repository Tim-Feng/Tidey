import CryptoKit
import Foundation

enum CodexAppServerApprovalMethod: String, Equatable, Sendable {
    case commandExecution = "item/commandExecution/requestApproval"
    case fileChange = "item/fileChange/requestApproval"
}

// The typed request path supports the complete app-server approval surface.
// Keep the legacy two-method enum below for callers that still opt into the
// permissive command/file compatibility initializer.
enum CodexAppServerApprovalRequestMethod: String, Equatable, Sendable {
    case commandExecution = "item/commandExecution/requestApproval"
    case fileChange = "item/fileChange/requestApproval"
    case permissions = "item/permissions/requestApproval"
    case requestUserInput = "item/tool/requestUserInput"
}

// JSON-RPC RequestId is `string | int64`. Keep the type so "1" and 1 do
// not collide and integer ids can be written back without a Double roundtrip.
enum CodexAppServerRequestID: Hashable, Sendable {
    case string(String)
    case integer(Int64)

    var storageKey: String {
        switch self {
        case .string(let value):
            return "s:\(value)"
        case .integer(let value):
            return "i:\(value)"
        }
    }

    var jsonToken: String {
        switch self {
        case .string(let value):
            let data = (try? JSONEncoder().encode([value])) ?? Data("[\"\"]".utf8)
            let text = String(decoding: data, as: UTF8.self)
            return String(text.dropFirst().dropLast())
        case .integer(let value):
            return String(value)
        }
    }

    init?(rawJSONObjectValue value: Any?) {
        if let text = value as? String {
            self = .string(text)
            return
        }
        if let number = value as? NSNumber {
            guard CFGetTypeID(number) != CFBooleanGetTypeID() else {
                return nil
            }
            let objCType = String(cString: number.objCType)
            if objCType == "d" || objCType == "f" {
                let doubleValue = number.doubleValue
                guard doubleValue.rounded(.towardZero) == doubleValue,
                      let exact = Int64(exactly: doubleValue) else {
                    return nil
                }
                self = .integer(exact)
                return
            }
            guard let exact = Int64(number.stringValue) else {
                return nil
            }
            self = .integer(exact)
            return
        }
        return nil
    }

    init?(jsonValue: JSONValue?) {
        switch jsonValue {
        case .string(let value):
            self = .string(value)
        case .number(let value):
            guard value.isFinite,
                  value.rounded(.towardZero) == value,
                  let exact = Int64(exactly: value) else {
                return nil
            }
            self = .integer(exact)
        default:
            return nil
        }
    }

    var legacyJSONValue: JSONValue {
        switch self {
        case .string(let value):
            return .string(value)
        case .integer(let value):
            return .number(Double(value))
        }
    }
}

enum CodexAppServerApprovalPromptSource {
    static let commandExecution = "codex_command_approval"
    static let fileChange = "codex_file_change_approval"
    static let permissions = "codex_permissions_approval"
    static let userInput = "codex_user_input_request"
}

struct CodexAppServerUserInputOption: Equatable, Sendable {
    let label: String
    let description: String
}

struct CodexAppServerUserInputQuestion: Equatable, Sendable {
    let id: String
    let header: String
    let question: String
    let isOther: Bool
    let isSecret: Bool
    let options: [CodexAppServerUserInputOption]?
}

enum CodexAppServerPermissionsDecision {
    static let allowTurn = "allow_turn"
    static let allowSession = "allow_session"
    static let deny = "deny"
}

struct CodexAppServerApprovalOption: Sendable {
    let decision: JSONValue
    let label: String
    let inputSequence: String
}

struct CodexAppServerApprovalRequest: Sendable {
    let requestID: CodexAppServerRequestID
    let requestIDValue: JSONValue
    let method: CodexAppServerApprovalRequestMethod
    let threadID: String
    let turnID: String
    let itemID: String
    let startedAtMs: Int
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
    let requestedPermissions: JSONValue?
    let additionalPermissions: JSONValue?
    let environmentID: String?
    let userInputQuestions: [CodexAppServerUserInputQuestion]
    let autoResolutionMs: Int?

    var requestIDKey: String {
        requestID.storageKey
    }

    // Compatibility path for older callers. It intentionally keeps the
    // pre-existing permissive command/file schema; the connection uses the
    // strict typed RequestId initializer below.
    init?(method methodName: String, requestID: JSONValue, params: [String: JSONValue]) {
        guard CodexAppServerApprovalMethod(rawValue: methodName) != nil,
              let method = CodexAppServerApprovalRequestMethod(rawValue: methodName),
              let typedRequestID = CodexAppServerRequestID(jsonValue: requestID) else {
            return nil
        }
        self.init(method: method,
                  requestID: typedRequestID,
                  requestIDValue: requestID,
                  params: params,
                  strictSchema: false)
    }

    // Strict typed model path. The distinct label avoids making legacy
    // `.string(...)` call sites ambiguous.
    init?(method methodName: String,
          typedRequestID requestID: CodexAppServerRequestID,
          params: [String: JSONValue]) {
        guard let method = CodexAppServerApprovalRequestMethod(rawValue: methodName) else {
            return nil
        }
        self.init(method: method,
                  requestID: requestID,
                  requestIDValue: requestID.legacyJSONValue,
                  params: params,
                  strictSchema: true)
    }

    private init?(method: CodexAppServerApprovalRequestMethod,
                  requestID: CodexAppServerRequestID,
                  requestIDValue: JSONValue,
                  params: [String: JSONValue],
                  strictSchema: Bool) {
        guard let threadID = params["threadId"]?.stringValue,
              let turnID = params["turnId"]?.stringValue,
              let itemID = params["itemId"]?.stringValue else {
            return nil
        }

        let startedAtMs: Int
        let questions: [CodexAppServerUserInputQuestion]
        if strictSchema {
            if method == .requestUserInput {
                guard let parsedQuestions = Self.userInputQuestions(from: params["questions"]),
                      !parsedQuestions.isEmpty else {
                    return nil
                }
                questions = parsedQuestions
                startedAtMs = params["startedAtMs"]?.intValue ?? 0
            } else {
                guard let requiredStartedAtMs = params["startedAtMs"]?.intValue else {
                    return nil
                }
                questions = []
                startedAtMs = requiredStartedAtMs
            }
            if method == .permissions {
                guard params["permissions"]?.objectValue != nil,
                      Self.nonEmptyString(params["cwd"]) != nil else {
                    return nil
                }
            }
        } else {
            questions = []
            startedAtMs = params["startedAtMs"]?.intValue ?? 0
        }

        self.requestID = requestID
        self.requestIDValue = requestIDValue
        self.method = method
        self.threadID = threadID
        self.turnID = turnID
        self.itemID = itemID
        self.startedAtMs = startedAtMs
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
        requestedPermissions = params["permissions"]
        additionalPermissions = params["additionalPermissions"]
        environmentID = Self.nonEmptyString(params["environmentId"])
        userInputQuestions = questions
        autoResolutionMs = params["autoResolutionMs"]?.intValue
    }

    private static func userInputQuestions(from value: JSONValue?) -> [CodexAppServerUserInputQuestion]? {
        guard let array = value?.arrayValue else {
            return nil
        }
        var questions: [CodexAppServerUserInputQuestion] = []
        var seenIDs = Set<String>()
        for entry in array {
            guard let object = entry.objectValue,
                  let id = object["id"]?.stringValue,
                  !id.isEmpty,
                  let header = object["header"]?.stringValue,
                  let question = object["question"]?.stringValue,
                  seenIDs.insert(id).inserted else {
                return nil
            }

            let isOther: Bool
            switch object["isOther"] {
            case .none:
                isOther = false
            case .some(let value):
                guard let bool = value.boolValue else {
                    return nil
                }
                isOther = bool
            }

            let isSecret: Bool
            switch object["isSecret"] {
            case .none:
                isSecret = false
            case .some(let value):
                guard let bool = value.boolValue else {
                    return nil
                }
                isSecret = bool
            }

            let options: [CodexAppServerUserInputOption]?
            switch object["options"] {
            case .none, .some(.null):
                options = nil
            case .some(.array(let values)):
                var parsed: [CodexAppServerUserInputOption] = []
                for option in values {
                    guard let optionObject = option.objectValue,
                          let label = optionObject["label"]?.stringValue,
                          let description = optionObject["description"]?.stringValue else {
                        return nil
                    }
                    parsed.append(CodexAppServerUserInputOption(label: label,
                                                                description: description))
                }
                options = parsed
            default:
                return nil
            }

            questions.append(CodexAppServerUserInputQuestion(id: id,
                                                             header: header,
                                                             question: question,
                                                             isOther: isOther,
                                                             isSecret: isSecret,
                                                             options: options))
        }
        return questions
    }

    var promptID: String {
        let requestIDText: String
        switch requestID {
        case .string(let value):
            requestIDText = value
        case .integer(let value):
            requestIDText = String(value)
        }
        return Self.promptID(seedParts: [
            method.rawValue,
            requestIDText,
            threadID,
            turnID,
            itemID,
            approvalID ?? "",
        ])
    }

    func promptID(epoch: String) -> String {
        Self.promptID(seedParts: [
            method.rawValue,
            requestID.storageKey,
            threadID,
            turnID,
            itemID,
            approvalID ?? "",
            epoch,
        ])
    }

    private static func promptID(seedParts: [String]) -> String {
        let seed = seedParts.joined(separator: "\n")
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
        case .permissions:
            return CodexAppServerApprovalPromptSource.permissions
        case .requestUserInput:
            return CodexAppServerApprovalPromptSource.userInput
        }
    }

    func makePrompt() -> InteractivePrompt {
        makePrompt(promptID: promptID)
    }

    func makePrompt(epoch: String) -> InteractivePrompt {
        makePrompt(promptID: promptID(epoch: epoch))
    }

    private func makePrompt(promptID: String) -> InteractivePrompt {
        InteractivePrompt(promptID: promptID,
                          vendor: "codex",
                          source: promptSource,
                          title: title,
                          body: body,
                          options: options,
                          selectedIndex: 0,
                          submitChannel: InteractivePromptSubmitChannel.codexAppServer,
                          questions: userInputQuestionsJSON)
    }

    func response(targetIndex: Int) throws -> JSONValue {
        let options = approvalOptions
        guard options.indices.contains(targetIndex) else {
            throw BridgeInternalError.invalidRequest("Unknown Codex approval option index.")
        }
        switch method {
        case .commandExecution, .fileChange:
            return .object(["decision": options[targetIndex].decision])
        case .permissions:
            return try permissionsResponse(inputSequence: options[targetIndex].inputSequence)
        case .requestUserInput:
            guard userInputQuestions.count == 1,
                  let question = userInputQuestions.first else {
                throw BridgeInternalError.invalidRequest("Codex user input request requires answers")
            }
            return try userInputResponse(answers: [
                question.id: [options[targetIndex].inputSequence],
            ])
        }
    }

    func userInputResponse(answers: [String: [String]]) throws -> JSONValue {
        guard method == .requestUserInput else {
            throw BridgeInternalError.invalidRequest("answers are only valid for Codex user input requests")
        }
        let questionIDs = Set(userInputQuestions.map(\.id))
        for key in answers.keys where !questionIDs.contains(key) {
            throw BridgeInternalError.invalidRequest("Unknown Codex user input question id: \(key)")
        }
        var encoded: [String: JSONValue] = [:]
        for question in userInputQuestions {
            encoded[question.id] = .object([
                "answers": .array((answers[question.id] ?? []).map(JSONValue.string)),
            ])
        }
        return .object(["answers": .object(encoded)])
    }

    private var userInputQuestionsJSON: JSONValue? {
        guard method == .requestUserInput else {
            return nil
        }
        return .array(userInputQuestions.map { question in
            var object: [String: JSONValue] = [
                "id": .string(question.id),
                "header": .string(question.header),
                "question": .string(question.question),
                "is_other": .bool(question.isOther),
                "is_secret": .bool(question.isSecret),
            ]
            if let options = question.options {
                object["options"] = .array(options.map { option in
                    .object([
                        "label": .string(option.label),
                        "description": .string(option.description),
                    ])
                })
            }
            return .object(object)
        })
    }

    private func permissionsResponse(inputSequence: String) throws -> JSONValue {
        let requested = requestedPermissions ?? .object([:])
        switch inputSequence {
        case CodexAppServerPermissionsDecision.allowTurn:
            return .object([
                "permissions": requested,
                "scope": .string("turn"),
            ])
        case CodexAppServerPermissionsDecision.allowSession:
            return .object([
                "permissions": requested,
                "scope": .string("session"),
            ])
        case CodexAppServerPermissionsDecision.deny:
            return .object([
                "permissions": .object([:]),
                "scope": .string("turn"),
            ])
        default:
            throw BridgeInternalError.invalidRequest("Unknown Codex permissions decision.")
        }
    }

    private var title: String {
        switch method {
        case .commandExecution:
            return "Approve Codex command?"
        case .fileChange:
            return "Approve Codex file changes?"
        case .permissions:
            return "Approve Codex permissions?"
        case .requestUserInput:
            if let header = userInputQuestions.first?.header,
               !header.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return header
            }
            return "Codex needs your input"
        }
    }

    private var body: String {
        switch method {
        case .commandExecution:
            return commandBody
        case .fileChange:
            return fileChangeBody
        case .permissions:
            return permissionsBody
        case .requestUserInput:
            return userInputBody
        }
    }

    private var userInputBody: String {
        var lines: [String] = []
        for question in userInputQuestions {
            lines.append(question.question)
            for option in question.options ?? [] {
                let description = option.description.trimmingCharacters(in: .whitespacesAndNewlines)
                lines.append(description.isEmpty
                    ? "- \(option.label)"
                    : "- \(option.label): \(description)")
            }
        }
        if lines.isEmpty {
            lines.append("Codex is asking for your input.")
        }
        return lines.joined(separator: "\n")
    }

    private var commandBody: String {
        var lines: [String] = []
        if let command {
            lines.append("Command: \(command)")
        }
        if let cwd {
            lines.append("Working directory: \(cwd)")
        }
        if let environmentID {
            lines.append("Environment: \(environmentID)")
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
        let additionalLines = Self.permissionProfileLines(additionalPermissions)
        if !additionalLines.isEmpty {
            lines.append("Additional permissions:")
            lines.append(contentsOf: additionalLines)
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

    private var permissionsBody: String {
        var lines: [String] = []
        if let reason {
            lines.append("Reason: \(reason)")
        }
        if let cwd {
            lines.append("Working directory: \(cwd)")
        }
        if let environmentID {
            lines.append("Environment: \(environmentID)")
        }
        lines.append(contentsOf: Self.permissionProfileLines(requestedPermissions,
                                                             includeFileSystemHeader: true))
        if lines.isEmpty {
            lines.append("Codex is asking for additional permissions.")
        }
        return lines.joined(separator: "\n")
    }

    static func permissionProfileLines(_ value: JSONValue?,
                                       includeFileSystemHeader: Bool = true) -> [String] {
        guard let profile = value?.objectValue else {
            return []
        }
        var lines: [String] = []
        if let network = profile["network"]?.objectValue,
           let enabled = network["enabled"]?.boolValue {
            lines.append(enabled
                ? "Network: allow outbound network access"
                : "Network: outbound network access disabled")
        }

        let fileSystem = profile["fileSystem"]?.objectValue
        var fileSystemLines: [String] = []
        for entry in fileSystem?["entries"]?.arrayValue ?? [] {
            guard let object = entry.objectValue,
                  let access = object["access"]?.stringValue else {
                continue
            }
            fileSystemLines.append("- \(access) \(Self.fileSystemPathDescription(object["path"]))")
        }
        for path in fileSystem?["read"]?.arrayValue?.compactMap(\.stringValue) ?? [] {
            fileSystemLines.append("- read \(path)")
        }
        for path in fileSystem?["write"]?.arrayValue?.compactMap(\.stringValue) ?? [] {
            fileSystemLines.append("- write \(path)")
        }
        if !fileSystemLines.isEmpty {
            if includeFileSystemHeader {
                lines.append("File system:")
            }
            lines.append(contentsOf: fileSystemLines)
        }
        return lines
    }

    private static func fileSystemPathDescription(_ value: JSONValue?) -> String {
        guard let object = value?.objectValue else {
            return "unknown path"
        }
        switch object["type"]?.stringValue {
        case "path":
            return object["path"]?.stringValue ?? "unknown path"
        case "glob_pattern":
            return object["pattern"]?.stringValue.map { "glob \($0)" } ?? "unknown pattern"
        case "special":
            let special = object["value"]?.objectValue
            let kind = special?["kind"]?.stringValue ?? "special"
            if kind == "unknown",
               let actualPath = special?["path"]?.stringValue,
               !actualPath.isEmpty {
                if let subpath = special?["subpath"]?.stringValue,
                   !subpath.isEmpty {
                    return "\(actualPath)/\(subpath)"
                }
                return actualPath
            }
            if let subpath = special?["subpath"]?.stringValue,
               !subpath.isEmpty {
                return "\(kind)/\(subpath)"
            }
            return kind
        default:
            return "unknown path"
        }
    }

    private var approvalOptions: [CodexAppServerApprovalOption] {
        if method == .requestUserInput {
            guard userInputQuestions.count == 1,
                  let question = userInputQuestions.first,
                  !question.isOther,
                  let questionOptions = question.options,
                  !questionOptions.isEmpty else {
                return []
            }
            return questionOptions.map { option in
                CodexAppServerApprovalOption(decision: .string(option.label),
                                             label: option.label,
                                             inputSequence: option.label)
            }
        }
        if method == .permissions {
            return [
                CodexAppServerApprovalOption(
                    decision: .string(CodexAppServerPermissionsDecision.allowTurn),
                    label: "Yes, allow for this turn (y)",
                    inputSequence: CodexAppServerPermissionsDecision.allowTurn),
                CodexAppServerApprovalOption(
                    decision: .string(CodexAppServerPermissionsDecision.allowSession),
                    label: "Yes, allow for this session (p)",
                    inputSequence: CodexAppServerPermissionsDecision.allowSession),
                CodexAppServerApprovalOption(
                    decision: .string(CodexAppServerPermissionsDecision.deny),
                    label: "No, and tell Codex what to do differently (esc)",
                    inputSequence: CodexAppServerPermissionsDecision.deny),
            ]
        }
        if !availableDecisions.isEmpty {
            return availableDecisions
                .map { Self.option(for: $0, method: method) }
        }
        switch method {
        case .permissions, .requestUserInput:
            preconditionFailure("permissions/user-input options are constructed above")
        case .commandExecution:
            return [
                Self.option(for: .string("accept"), method: method),
                Self.option(for: .string("decline"), method: method),
            ]
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

    private static func option(for decision: JSONValue, method: CodexAppServerApprovalRequestMethod) -> CodexAppServerApprovalOption {
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

    private static func label(for decision: JSONValue, method: CodexAppServerApprovalRequestMethod) -> String {
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

    private static func label(forDecisionName decision: String, method: CodexAppServerApprovalRequestMethod) -> String {
        switch decision {
        case "accept":
            switch method {
            case .commandExecution:
                return "Yes, proceed (y)"
            case .fileChange:
                return "Yes, make edits (y)"
            case .permissions, .requestUserInput:
                return "Yes, allow for this turn (y)"
            }
        case "acceptForSession":
            switch method {
            case .commandExecution:
                return "Yes, and don't ask again for this command in this session (p)"
            case .fileChange:
                return "Yes, and don't ask again for these files (p)"
            case .permissions, .requestUserInput:
                return "Yes, allow for this session (p)"
            }
        case "decline":
            return "No, and tell Codex what to do differently (esc)"
        case "cancel":
            switch method {
            case .commandExecution:
                return "No, and tell Codex what to do differently (esc)"
            case .fileChange, .permissions, .requestUserInput:
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

struct CodexAppServerApprovalSubmitAttempt: Sendable {
    let clientRequestID: String?
    let targetIndex: Int
    let response: JSONValue
}

enum CodexAppServerApprovalPhase: Sendable {
    case pending
    case submitting(CodexAppServerApprovalSubmitAttempt)
}

struct CodexAppServerApprovalTerminalRecord: Sendable {
    let entry: CodexAppServerApprovalPromptEntry
    let reason: String
    let event: AgentEvent
    let attempt: Int
}

// Connection-scoped lifecycle state for app-server approval prompts. All
// state transitions are atomic under one lock. A local submit never creates a
// terminal record; only an authoritative lifecycle signal or store retirement
// does that.
final class CodexAppServerApprovalPromptStore: @unchecked Sendable {
    enum RegisterOutcome: Sendable {
        case recorded(CodexAppServerApprovalPromptEntry, attempt: Int)
        case reactivated(CodexAppServerApprovalPromptEntry, attempt: Int)
        case supersededPayloadChanged(terminal: CodexAppServerApprovalTerminalRecord,
                                      entry: CodexAppServerApprovalPromptEntry,
                                      attempt: Int)
        case rejectedRetired
    }

    enum BeginSubmitOutcome: Sendable {
        case begin(entry: CodexAppServerApprovalPromptEntry,
                   response: JSONValue,
                   lifecycleAttempt: Int)
        case lifecycleTokenMismatch
        case duplicateInFlight(CodexAppServerApprovalPromptEntry)
        case inFlightConflict
        case optionConflict
        case terminal(CodexAppServerApprovalTerminalRecord)
        case unknown
    }

    enum SubmitCompletionOutcome: Sendable {
        case awaitingConfirmation
        case terminal(CodexAppServerApprovalTerminalRecord)
        case supersededLifecycle
    }

    private struct ActiveEntry {
        var entry: CodexAppServerApprovalPromptEntry
        var phase: CodexAppServerApprovalPhase
        var attempt: Int
        var lastAttempt: CodexAppServerApprovalSubmitAttempt?
        // The exact event published for this delivery. Pending snapshots reuse
        // it, and its eventID is the capability accepted by submit.
        var publishedEvent: AgentEvent?
    }

    private let lock = NSLock()
    private let terminalCapacity: Int
    private var retired = false
    private var entriesByPromptID: [String: ActiveEntry] = [:]
    private var terminalsByPromptID: [String: CodexAppServerApprovalTerminalRecord] = [:]
    private var terminalOrder: [String] = []

    init(terminalCapacity: Int = 128) {
        self.terminalCapacity = max(1, terminalCapacity)
    }

    @discardableResult
    func record(_ request: CodexAppServerApprovalRequest) -> InteractivePrompt {
        let prompt = request.makePrompt()
        return record(request, prompt: prompt)
    }

    // The connection owns process-epoch identity. Accept its prebuilt prompt
    // so the ID published to clients is exactly the ID later used for submit.
    @discardableResult
    func record(_ request: CodexAppServerApprovalRequest,
                prompt: InteractivePrompt) -> InteractivePrompt {
        let entry = CodexAppServerApprovalPromptEntry(request: request, prompt: prompt)
        lock.withCodexApprovalLock {
            guard !retired else {
                return
            }
            let attempt = entriesByPromptID[prompt.promptID]?.attempt
                ?? terminalsByPromptID[prompt.promptID]?.attempt
                ?? 0
            removeTerminalLocked(promptID: prompt.promptID)
            entriesByPromptID[prompt.promptID] = ActiveEntry(entry: entry,
                                                             phase: .pending,
                                                             attempt: attempt + 1,
                                                             lastAttempt: nil,
                                                             publishedEvent: nil)
        }
        return prompt
    }

    func register(
        entry newEntry: CodexAppServerApprovalPromptEntry,
        makeTerminalEvent: (CodexAppServerApprovalPromptEntry, String, Int) -> AgentEvent
    ) -> RegisterOutcome {
        lock.withCodexApprovalLock {
            guard !retired else {
                return .rejectedRetired
            }
            let promptID = newEntry.prompt.promptID
            let newFingerprint = Self.lifecycleFingerprint(for: newEntry)

            if var active = entriesByPromptID[promptID] {
                let attempt = active.attempt + 1
                if Self.lifecycleFingerprint(for: active.entry) == newFingerprint {
                    active.entry = newEntry
                    active.phase = .pending
                    active.attempt = attempt
                    active.publishedEvent = nil
                    entriesByPromptID[promptID] = active
                    return .reactivated(newEntry, attempt: attempt)
                }

                let terminal = CodexAppServerApprovalTerminalRecord(
                    entry: active.entry,
                    reason: "superseded",
                    event: makeTerminalEvent(active.entry, "superseded", active.attempt),
                    attempt: active.attempt)
                entriesByPromptID[promptID] = ActiveEntry(entry: newEntry,
                                                          phase: .pending,
                                                          attempt: attempt,
                                                          lastAttempt: nil,
                                                          publishedEvent: nil)
                return .supersededPayloadChanged(terminal: terminal,
                                                  entry: newEntry,
                                                  attempt: attempt)
            }

            let attempt = (terminalsByPromptID[promptID]?.attempt ?? 0) + 1
            removeTerminalLocked(promptID: promptID)
            entriesByPromptID[promptID] = ActiveEntry(entry: newEntry,
                                                      phase: .pending,
                                                      attempt: attempt,
                                                      lastAttempt: nil,
                                                      publishedEvent: nil)
            return .recorded(newEntry, attempt: attempt)
        }
    }

    func recordPublishedPromptEvent(promptID: String, event: AgentEvent) {
        lock.withCodexApprovalLock {
            guard var active = entriesByPromptID[promptID] else {
                return
            }
            active.publishedEvent = event
            entriesByPromptID[promptID] = active
        }
    }

    func beginSubmit(promptID: String,
                     targetIndex: Int,
                     clientRequestID: String?,
                     lifecycleToken: String? = nil) -> BeginSubmitOutcome {
        lock.withCodexApprovalLock {
            if let terminal = terminalsByPromptID[promptID] {
                return .terminal(terminal)
            }
            guard var active = entriesByPromptID[promptID] else {
                return .unknown
            }
            if let lifecycleToken {
                guard active.publishedEvent?.eventID == lifecycleToken else {
                    return .lifecycleTokenMismatch
                }
            }
            if case .submitting(let attempt) = active.phase {
                if let clientRequestID,
                   attempt.clientRequestID == clientRequestID {
                    return attempt.targetIndex == targetIndex
                        ? .duplicateInFlight(active.entry)
                        : .optionConflict
                }
                return .inFlightConflict
            }
            if let lastAttempt = active.lastAttempt,
               lastAttempt.targetIndex != targetIndex {
                return .optionConflict
            }
            guard let response = try? active.entry.request.response(targetIndex: targetIndex) else {
                return .optionConflict
            }
            let attempt = CodexAppServerApprovalSubmitAttempt(clientRequestID: clientRequestID,
                                                              targetIndex: targetIndex,
                                                              response: response)
            active.phase = .submitting(attempt)
            active.lastAttempt = attempt
            entriesByPromptID[promptID] = active
            return .begin(entry: active.entry,
                          response: response,
                          lifecycleAttempt: active.attempt)
        }
    }

    func beginSubmitUserInput(promptID: String,
                              answers: [String: [String]],
                              clientRequestID: String?,
                              lifecycleToken: String? = nil) -> BeginSubmitOutcome {
        lock.withCodexApprovalLock {
            if let terminal = terminalsByPromptID[promptID] {
                return .terminal(terminal)
            }
            guard var active = entriesByPromptID[promptID] else {
                return .unknown
            }
            if let lifecycleToken,
               active.publishedEvent?.eventID != lifecycleToken {
                return .lifecycleTokenMismatch
            }
            guard let response = try? active.entry.request.userInputResponse(answers: answers) else {
                return .optionConflict
            }
            if case .submitting(let attempt) = active.phase {
                if let clientRequestID,
                   attempt.clientRequestID == clientRequestID {
                    return attempt.response == response
                        ? .duplicateInFlight(active.entry)
                        : .optionConflict
                }
                return .inFlightConflict
            }
            if let lastAttempt = active.lastAttempt,
               lastAttempt.response != response {
                return .optionConflict
            }
            let attempt = CodexAppServerApprovalSubmitAttempt(clientRequestID: clientRequestID,
                                                              targetIndex: -1,
                                                              response: response)
            active.phase = .submitting(attempt)
            active.lastAttempt = attempt
            entriesByPromptID[promptID] = active
            return .begin(entry: active.entry,
                          response: response,
                          lifecycleAttempt: active.attempt)
        }
    }

    func completeSubmitFlush(promptID: String,
                             lifecycleAttempt: Int) -> SubmitCompletionOutcome {
        lock.withCodexApprovalLock {
            if let active = entriesByPromptID[promptID],
               active.attempt != lifecycleAttempt {
                return .supersededLifecycle
            }
            if let terminal = terminalsByPromptID[promptID] {
                return .terminal(terminal)
            }
            guard entriesByPromptID[promptID] != nil else {
                return .supersededLifecycle
            }
            return .awaitingConfirmation
        }
    }

    func failSubmit(promptID: String,
                    lifecycleAttempt: Int) -> SubmitCompletionOutcome {
        lock.withCodexApprovalLock {
            if let active = entriesByPromptID[promptID],
               active.attempt != lifecycleAttempt {
                return .supersededLifecycle
            }
            if let terminal = terminalsByPromptID[promptID] {
                return .terminal(terminal)
            }
            if var active = entriesByPromptID[promptID],
               case .submitting = active.phase {
                active.phase = .pending
                entriesByPromptID[promptID] = active
                return .awaitingConfirmation
            }
            return entriesByPromptID[promptID] == nil
                ? .supersededLifecycle
                : .awaitingConfirmation
        }
    }

    func entry(promptID: String) -> CodexAppServerApprovalPromptEntry? {
        lock.withCodexApprovalLock {
            entriesByPromptID[promptID]?.entry
        }
    }

    func entries() -> [CodexAppServerApprovalPromptEntry] {
        lock.withCodexApprovalLock {
            entriesByPromptID.values.map(\.entry)
        }
    }

    func pendingStates() -> [(entry: CodexAppServerApprovalPromptEntry,
                              phase: CodexAppServerApprovalPhase,
                              attempt: Int,
                              publishedEvent: AgentEvent?)] {
        lock.withCodexApprovalLock {
            entriesByPromptID.values.map {
                ($0.entry, $0.phase, $0.attempt, $0.publishedEvent)
            }
        }
    }

    func resolve(promptID: String, targetIndex: Int) throws -> JSONValue {
        let (_, response) = try resolveEntry(promptID: promptID, targetIndex: targetIndex)
        return response
    }

    func resolveEntry(promptID: String,
                      targetIndex: Int) throws -> (entry: CodexAppServerApprovalPromptEntry, response: JSONValue) {
        try lock.withCodexApprovalLock {
            guard let active = entriesByPromptID[promptID] else {
                throw BridgeInternalError.notFound("Unknown Codex approval prompt.")
            }
            let response = try active.entry.request.response(targetIndex: targetIndex)
            entriesByPromptID.removeValue(forKey: promptID)
            return (active.entry, response)
        }
    }

    func remove(promptID: String) -> CodexAppServerApprovalPromptEntry? {
        let entry = lock.withCodexApprovalLock {
            entriesByPromptID.removeValue(forKey: promptID)?.entry
        }
        return entry
    }

    func resolveExternally(
        reason: String,
        where matches: (CodexAppServerApprovalRequest) -> Bool,
        makeEvent: (CodexAppServerApprovalPromptEntry, String, Int) -> AgentEvent
    ) -> [CodexAppServerApprovalTerminalRecord] {
        lock.withCodexApprovalLock {
            let matching = entriesByPromptID.values.filter {
                matches($0.entry.request)
            }
            var records: [CodexAppServerApprovalTerminalRecord] = []
            for active in matching {
                let promptID = active.entry.prompt.promptID
                entriesByPromptID.removeValue(forKey: promptID)
                let record = CodexAppServerApprovalTerminalRecord(
                    entry: active.entry,
                    reason: reason,
                    event: makeEvent(active.entry, reason, active.attempt),
                    attempt: active.attempt)
                insertTerminalLocked(record, promptID: promptID)
                records.append(record)
            }
            return records
        }
    }

    func resolveAllExternally(
        reason: String,
        makeEvent: (CodexAppServerApprovalPromptEntry, String, Int) -> AgentEvent
    ) -> [CodexAppServerApprovalTerminalRecord] {
        resolveExternally(reason: reason,
                          where: { _ in true },
                          makeEvent: makeEvent)
    }

    func retireAndResolveAll(
        reason: String,
        makeEvent: (CodexAppServerApprovalPromptEntry, String, Int) -> AgentEvent
    ) -> [CodexAppServerApprovalTerminalRecord] {
        lock.withCodexApprovalLock {
            retired = true
            let activeEntries = Array(entriesByPromptID.values)
            var records: [CodexAppServerApprovalTerminalRecord] = []
            for active in activeEntries {
                let promptID = active.entry.prompt.promptID
                let record = CodexAppServerApprovalTerminalRecord(
                    entry: active.entry,
                    reason: reason,
                    event: makeEvent(active.entry, reason, active.attempt),
                    attempt: active.attempt)
                insertTerminalLocked(record, promptID: promptID)
                records.append(record)
            }
            entriesByPromptID.removeAll()
            return records
        }
    }

    func terminalRecord(promptID: String) -> CodexAppServerApprovalTerminalRecord? {
        lock.withCodexApprovalLock {
            terminalsByPromptID[promptID]
        }
    }

    func terminalRecordCount() -> Int {
        lock.withCodexApprovalLock {
            terminalsByPromptID.count
        }
    }

    func isRetired() -> Bool {
        lock.withCodexApprovalLock {
            retired
        }
    }

    private static func lifecycleFingerprint(
        for entry: CodexAppServerApprovalPromptEntry
    ) -> String {
        let request = entry.request
        var value: [String: JSONValue] = [
            "request_id": .string(request.requestID.storageKey),
            "method": .string(request.method.rawValue),
            "thread_id": .string(request.threadID),
            "turn_id": .string(request.turnID),
            "item_id": .string(request.itemID),
            "started_at_ms": .string(String(request.startedAtMs)),
            "command_actions": .array(request.commandActions.map(JSONValue.string)),
            "network_policy_amendments": .array(request.proposedNetworkPolicyAmendments),
            "available_decisions": .array(request.availableDecisions),
            "prompt": entry.prompt.jsonValue,
        ]
        if let approvalID = request.approvalID { value["approval_id"] = .string(approvalID) }
        if let reason = request.reason { value["reason"] = .string(reason) }
        if let command = request.command { value["command"] = .string(command) }
        if let cwd = request.cwd { value["cwd"] = .string(cwd) }
        if let host = request.networkHost { value["network_host"] = .string(host) }
        if let networkProtocol = request.networkProtocol { value["network_protocol"] = .string(networkProtocol) }
        if let amendment = request.proposedExecpolicyAmendment { value["execpolicy_amendment"] = amendment }
        if let grantRoot = request.grantRoot { value["grant_root"] = .string(grantRoot) }
        if let permissions = request.requestedPermissions { value["permissions"] = permissions }
        if let additional = request.additionalPermissions { value["additional_permissions"] = additional }
        if let environmentID = request.environmentID { value["environment_id"] = .string(environmentID) }
        if let autoResolutionMs = request.autoResolutionMs { value["auto_resolution_ms"] = .string(String(autoResolutionMs)) }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(JSONValue.object(value))) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    private func insertTerminalLocked(
        _ record: CodexAppServerApprovalTerminalRecord,
        promptID: String
    ) {
        if terminalsByPromptID[promptID] == nil {
            terminalOrder.append(promptID)
        }
        terminalsByPromptID[promptID] = record
        while terminalOrder.count > terminalCapacity {
            let evicted = terminalOrder.removeFirst()
            terminalsByPromptID.removeValue(forKey: evicted)
        }
    }

    private func removeTerminalLocked(promptID: String) {
        guard terminalsByPromptID.removeValue(forKey: promptID) != nil else {
            return
        }
        terminalOrder.removeAll { $0 == promptID }
    }
}

private extension NSLock {
    func withCodexApprovalLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
