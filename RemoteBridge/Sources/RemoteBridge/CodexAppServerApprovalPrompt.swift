import CryptoKit
import Foundation

enum CodexAppServerApprovalMethod: String, Equatable, Sendable {
    case commandExecution = "item/commandExecution/requestApproval"
    case fileChange = "item/fileChange/requestApproval"
    case permissions = "item/permissions/requestApproval"
    case requestUserInput = "item/tool/requestUserInput"
}

// Codex JSON-RPC RequestId is `string | int64`. The two spaces must never
// collide ("1" vs 1) and int64 values must be echoed back bit-exact, so the
// id is kept typed instead of passing through Double-backed JSONValue.
enum CodexAppServerRequestID: Hashable, Sendable {
    case string(String)
    case integer(Int64)

    // Key used for prompt identity and store matching. Prefixed so the string
    // "1" and the integer 1 stay distinct.
    var storageKey: String {
        switch self {
        case .string(let value):
            return "s:\(value)"
        case .integer(let value):
            return "i:\(value)"
        }
    }

    // Exact JSON token for the wire (`"1"` vs `1`), preserving int64 range.
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

    // Parses a JSONSerialization-produced id value (String or NSNumber).
    init?(rawJSONObjectValue value: Any?) {
        if let text = value as? String {
            self = .string(text)
            return
        }
        if let number = value as? NSNumber {
            // Reject booleans; JSONSerialization models true/false as NSNumber.
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return nil
            }
            let objCType = String(cString: number.objCType)
            if objCType == "d" || objCType == "f" {
                // Fractional ids are not valid RequestId values.
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

    // Fallback for values that only exist as JSONValue (already Double-backed).
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
}

enum CodexAppServerApprovalPromptSource {
    static let commandExecution = "codex_command_approval"
    static let fileChange = "codex_file_change_approval"
    static let permissions = "codex_permissions_approval"
    static let userInput = "codex_user_input_request"
}

// 0.144.1 `item/tool/requestUserInput` question shapes. Required fields per
// the official schema: id, header, question; options entries require label
// AND description. `options` may be null (free-form input).
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
    let method: CodexAppServerApprovalMethod
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
    // Non-empty exactly when method == .requestUserInput.
    let userInputQuestions: [CodexAppServerUserInputQuestion]
    let autoResolutionMs: Int?

    var requestIDKey: String {
        requestID.storageKey
    }

    // Wire collision identity: canonical method + COMPLETE raw params (all
    // fields, preserved JSON types, sorted keys, int64-exact). The security
    // gate must never be derived from the lossy presentation subset — any
    // field change under the same RequestId is a changed payload. When the
    // raw JSON object is unavailable (direct in-process construction), the
    // canonical form of the parsed params is the fallback.
    let wireFingerprint: String

    static func canonicalRawJSON(_ object: Any?) -> String? {
        guard let object, JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }

    // Fragment-capable canonicalization of the raw `params` value: objects,
    // arrays, strings, numbers (int64-exact via NSNumber), bools, null AND
    // the missing-vs-present distinction all produce distinct canonical
    // forms; only object key order is normalized.
    static func canonicalRawParamsFragment(rawObject: [String: Any]?) -> String? {
        guard let rawObject else {
            return nil
        }
        guard rawObject.keys.contains("params") else {
            return "absent"
        }
        let value = rawObject["params"] ?? NSNull()
        guard let data = try? JSONSerialization.data(withJSONObject: value,
                                                     options: [.sortedKeys, .fragmentsAllowed]) else {
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }

    init?(method methodName: String,
          requestID: CodexAppServerRequestID,
          params: [String: JSONValue],
          rawParamsCanonical: String? = nil) {
        guard let method = CodexAppServerApprovalMethod(rawValue: methodName),
              let threadID = params["threadId"]?.stringValue,
              let turnID = params["turnId"]?.stringValue,
              let itemID = params["itemId"]?.stringValue else {
            return nil
        }
        let startedAtMs: Int
        if method == .requestUserInput {
            // Official 0.144.1 required fields: threadId, turnId, itemId,
            // questions. startedAtMs is not part of this request.
            guard let questions = Self.userInputQuestions(from: params["questions"]),
                  questions.isEmpty == false else {
                return nil
            }
            userInputQuestions = questions
            startedAtMs = params["startedAtMs"]?.intValue ?? 0
        } else {
            // startedAtMs is required by the official 0.144.1 schema for
            // commandExecution, fileChange, and permissions alike.
            guard let requiredStartedAtMs = params["startedAtMs"]?.intValue else {
                return nil
            }
            userInputQuestions = []
            startedAtMs = requiredStartedAtMs
        }
        autoResolutionMs = params["autoResolutionMs"]?.intValue
        if method == .permissions {
            // The official schema additionally requires cwd and permissions;
            // a partial approval must be rejected instead of being presented
            // incomplete.
            guard params["permissions"]?.objectValue != nil,
                  Self.nonEmptyString(params["cwd"]) != nil else {
                return nil
            }
        }

        self.requestID = requestID
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
        wireFingerprint = "approval:\(methodName)\n" + (rawParamsCanonical ?? Self.canonicalParsedParams(params))
    }

    // Compatibility label used by the isolated pure-model tests. Keeping it
    // distinct avoids ambiguous `.string(...)` call sites while the wired
    // connection uses the canonical typed `requestID:` initializer above.
    init?(method methodName: String,
          typedRequestID requestID: CodexAppServerRequestID,
          params: [String: JSONValue]) {
        self.init(method: methodName,
                  requestID: requestID,
                  params: params)
    }

    // Strict 0.144.1 question parsing: any malformed question or option makes
    // the whole request invalid (-32602), never a partially presented card.
    private static func userInputQuestions(from value: JSONValue?) -> [CodexAppServerUserInputQuestion]? {
        guard let array = value?.arrayValue else {
            return nil
        }
        var questions: [CodexAppServerUserInputQuestion] = []
        var seenIDs = Set<String>()
        for entry in array {
            guard let object = entry.objectValue,
                  let id = object["id"]?.stringValue, !id.isEmpty,
                  let header = object["header"]?.stringValue,
                  let question = object["question"]?.stringValue,
                  seenIDs.insert(id).inserted else {
                return nil
            }
            // A PRESENT but non-bool isOther/isSecret must reject the whole
            // request rather than silently default to false — a wrong-type
            // isSecret defaulting to "not secret" would downgrade a secret
            // answer to plain text end to end.
            let isOther: Bool
            switch object["isOther"] {
            case .none: isOther = false
            case .some(let value):
                guard let bool = value.boolValue else { return nil }
                isOther = bool
            }
            let isSecret: Bool
            switch object["isSecret"] {
            case .none: isSecret = false
            case .some(let value):
                guard let bool = value.boolValue else { return nil }
                isSecret = bool
            }
            var options: [CodexAppServerUserInputOption]?
            switch object["options"] {
            case .none, .some(.null):
                options = nil
            case .some(.array(let values)):
                var parsed: [CodexAppServerUserInputOption] = []
                for optionValue in values {
                    guard let optionObject = optionValue.objectValue,
                          let label = optionObject["label"]?.stringValue,
                          let description = optionObject["description"]?.stringValue else {
                        return nil
                    }
                    parsed.append(CodexAppServerUserInputOption(label: label, description: description))
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

    private static func canonicalParsedParams(_ params: [String: JSONValue]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(JSONValue.object(params))) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    // Canonical fingerprint of all security-relevant content. A re-delivery
    // whose fingerprint changed under the same request identity must never be
    // silently merged into an existing lifecycle.
    var securityFingerprint: String {
        var payload: [String: JSONValue] = [
            "method": .string(method.rawValue),
        ]
        if let reason { payload["reason"] = .string(reason) }
        if let command { payload["command"] = .string(command) }
        if let cwd { payload["cwd"] = .string(cwd) }
        if !commandActions.isEmpty { payload["command_actions"] = .array(commandActions.map(JSONValue.string)) }
        if let networkHost { payload["network_host"] = .string(networkHost) }
        if let networkProtocol { payload["network_protocol"] = .string(networkProtocol) }
        if let proposedExecpolicyAmendment { payload["execpolicy_amendment"] = proposedExecpolicyAmendment }
        if !proposedNetworkPolicyAmendments.isEmpty { payload["network_policy_amendments"] = .array(proposedNetworkPolicyAmendments) }
        if !availableDecisions.isEmpty { payload["available_decisions"] = .array(availableDecisions) }
        if let grantRoot { payload["grant_root"] = .string(grantRoot) }
        if let requestedPermissions { payload["permissions"] = requestedPermissions }
        if let additionalPermissions { payload["additional_permissions"] = additionalPermissions }
        if let environmentID { payload["environment_id"] = .string(environmentID) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(JSONValue.object(payload))) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    // The no-epoch identity preserves the prompt IDs used by the legacy
    // command/file connection path.
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

    // The epoch identifies one app-server process instance. Including it in
    // the prompt identity keeps re-delivered requests on the same card across
    // reconnects to the same process, while a restarted process can never
    // collide with records from the previous one.
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
        case .permissions:
            return try permissionsResponse(inputSequence: options[targetIndex].inputSequence)
        case .commandExecution, .fileChange:
            return .object(["decision": options[targetIndex].decision])
        case .requestUserInput:
            // Option-index submit is only well-defined for the single
            // predefined-options question; everything else uses the
            // answers-map submit path.
            guard userInputQuestions.count == 1,
                  let question = userInputQuestions.first else {
                throw BridgeInternalError.invalidRequest("Codex user input request requires answers")
            }
            return try userInputResponse(answers: [question.id: [options[targetIndex].inputSequence]])
        }
    }

    // Exact 0.144.1 response shape: {answers: {questionId: {answers: [..]}}}
    // — map keyed by question id, every value an inner `answers` string
    // array (single answers and free-form input included). Official
    // semantics (codex-rs/tui/src/bottom_pane/request_user_input/mod.rs
    // `submit_answers`): EVERY question gets an entry, even an empty array
    // for a question the user explicitly left unanswered (after the TUI's
    // own "submit with unanswered questions?" confirmation) — an empty
    // array is not itself invalid, only an unknown question id is.
    func userInputResponse(answers: [String: [String]]) throws -> JSONValue {
        guard method == .requestUserInput else {
            throw BridgeInternalError.invalidRequest("answers are only valid for Codex user input requests")
        }
        let questionIDs = Set(userInputQuestions.map(\.id))
        for key in answers.keys where questionIDs.contains(key) == false {
            throw BridgeInternalError.invalidRequest("Unknown Codex user input question id: \(key)")
        }
        var answersObject: [String: JSONValue] = [:]
        for question in userInputQuestions {
            let values = answers[question.id] ?? []
            answersObject[question.id] = .object(["answers": .array(values.map(JSONValue.string))])
        }
        return .object(["answers": .object(answersObject)])
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
                object["options"] = .array(options.map {
                    .object(["label": .string($0.label), "description": .string($0.description)])
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
               header.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
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
                lines.append(description.isEmpty ? "- \(option.label)" : "- \(option.label): \(description)")
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
        // additionalPermissions grants extra sandbox capabilities alongside
        // the command; the user must see the full profile before approving.
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
        lines.append(contentsOf: Self.permissionProfileLines(requestedPermissions, includeFileSystemHeader: true))
        if lines.isEmpty {
            lines.append("Codex is asking for additional permissions.")
        }
        return lines.joined(separator: "\n")
    }

    // Renders a RequestPermissionProfile (network + fileSystem entries and
    // legacy read/write lists) into display lines.
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
            // Official schema: kind "unknown" always carries the actual
            // filesystem path being granted; hiding it behind the kind label
            // would let the user approve an undisclosed path.
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
            // A single predefined-options question maps onto the standard
            // option card (submit by index); other shapes have no index
            // options and submit through the answers map.
            guard userInputQuestions.count == 1,
                  let question = userInputQuestions.first,
                  question.isOther == false,
                  let options = question.options,
                  options.isEmpty == false else {
                return []
            }
            return options.map { option in
                CodexAppServerApprovalOption(decision: .string(option.label),
                                             label: option.label,
                                             inputSequence: option.label)
            }
        }
        if method == .permissions {
            return [
                CodexAppServerApprovalOption(decision: .string(CodexAppServerPermissionsDecision.allowTurn),
                                             label: "Yes, allow for this turn (y)",
                                             inputSequence: CodexAppServerPermissionsDecision.allowTurn),
                CodexAppServerApprovalOption(decision: .string(CodexAppServerPermissionsDecision.allowSession),
                                             label: "Yes, allow for this session (p)",
                                             inputSequence: CodexAppServerPermissionsDecision.allowSession),
                CodexAppServerApprovalOption(decision: .string(CodexAppServerPermissionsDecision.deny),
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
    enum WireState: Sendable {
        // Response computed, no bytes on the wire yet.
        case preparing
        // Response is being written; it may reach the app-server.
        case writing
        // Response was flushed to the transport.
        case flushed
    }

    let clientRequestID: String?
    let targetIndex: Int
    let response: JSONValue
    var wireState: WireState = .preparing
}

enum CodexAppServerApprovalPhase: Sendable {
    case pending
    case submitting(CodexAppServerApprovalSubmitAttempt)
}

struct CodexAppServerApprovalTerminalRecord: Sendable {
    let entry: CodexAppServerApprovalPromptEntry
    let reason: String
    let event: AgentEvent
    // Delivery attempt this terminal belongs to; a re-delivered request gets
    // a higher attempt and therefore fresh event identities.
    let attempt: Int
}

// State machine for one connection's approval requests. Every transition is a
// single atomic step under one lock so that a request identity has exactly one
// terminal transition:
//
//   pending -> submitting -> (serverRequest/resolved | turn terminal | expiry) -> terminal
//
// A local response flush never terminates an entry; only authoritative
// lifecycle notifications (or connection expiry) do.
final class CodexAppServerApprovalPromptStore: @unchecked Sendable {
    enum RegisterOutcome: Sendable {
        // Fresh prompt (or a re-delivery that replaced a stale terminal
        // record): present it.
        case recorded(CodexAppServerApprovalPromptEntry, attempt: Int)
        // The server re-delivered a request we still consider active with an
        // unchanged security payload. Any in-flight local response was
        // evidently not accepted, so the entry (now backed by the newly
        // delivered request) is reset to pending and re-presented.
        case reactivated(CodexAppServerApprovalPromptEntry, attempt: Int)
        // Same request identity but the security-relevant payload changed:
        // the old lifecycle is terminated (fail closed; its decisions and
        // conflict guards cannot carry over) and a fresh lifecycle starts
        // from the new request, keeping display and response atomic.
        case supersededPayloadChanged(terminal: CodexAppServerApprovalTerminalRecord,
                                      entry: CodexAppServerApprovalPromptEntry,
                                      attempt: Int)
        // The connection generation is retiring/closed: no new prompt may be
        // admitted or published.
        case rejectedRetired
        // JSON-RPC protocol violation: a request whose RequestId already has
        // a response in flight/flushed changed its content (fingerprint,
        // item, or method). The RequestId is poisoned for this connection's
        // lifetime — no prompt, no further response bytes with that id, and
        // the transport must be aborted. `isNewViolation` is true only for
        // the first observation; redeliveries of a poisoned id stay rejected
        // without re-aborting.
        case rejectedPoisonedRequestID(terminals: [CodexAppServerApprovalTerminalRecord], isNewViolation: Bool)
    }

    enum BeginSubmitOutcome: Sendable {
        // The lifecycle attempt token is a capability: every later wire/state
        // transition for this submit must present it, so a submit from an
        // older lifecycle can never complete/fail/flush into a newer one.
        case begin(entry: CodexAppServerApprovalPromptEntry, response: JSONValue, lifecycleAttempt: Int)
        // The submit presented a lifecycle capability token from a different
        // (older) delivery: zero bytes may be written for it.
        case lifecycleTokenMismatch
        // Same client request is already in flight with the same option.
        case duplicateInFlight(CodexAppServerApprovalPromptEntry)
        // A different submit is in flight for this prompt.
        case inFlightConflict
        // A different option was already attempted for this prompt; a second
        // decision must fail closed.
        case optionConflict
        case terminal(CodexAppServerApprovalTerminalRecord)
        case unknown
    }

    enum SubmitCompletionOutcome: Sendable {
        case awaitingConfirmation
        case terminal(CodexAppServerApprovalTerminalRecord)
        // The lifecycle this submit belonged to no longer exists (superseded
        // by a newer delivery); its completion must not touch current state.
        case supersededLifecycle
    }

    private struct ActiveEntry {
        var entry: CodexAppServerApprovalPromptEntry
        var phase: CodexAppServerApprovalPhase
        // Delivery attempt (1-based); bumped on every re-delivery so events
        // for a new lifecycle are not deduplicated away downstream.
        var attempt: Int
        // Remembered across failures so a conflicting second decision can be
        // rejected even after the first attempt errored.
        var lastAttempt: CodexAppServerApprovalSubmitAttempt?
        // The exact event published for this delivery. Pending snapshots must
        // reuse it (identity, seq, timestamp) instead of allocating new,
        // unretained sequence numbers.
        var publishedEvent: AgentEvent?
    }

    // Connection-scoped wire ledger entry keyed by the normalized JSON-RPC
    // RequestId, independent of promptID: whatever fields change (item,
    // method, payload), the same RequestId lands in the same collision
    // domain.
    private struct WireOwner {
        var promptID: String
        var fingerprint: String
        // A response (for `fingerprint`) is being written or was flushed.
        var responseOnWire: Bool
        var poisoned: Bool
    }

    private let lock = NSLock()
    private let terminalCapacity: Int
    private var retired = false
    private var entriesByPromptID: [String: ActiveEntry] = [:]
    private var terminalsByPromptID: [String: CodexAppServerApprovalTerminalRecord] = [:]
    private var terminalOrder: [String] = []
    private var wireOwnersByRequestKey: [String: WireOwner] = [:]

    init(terminalCapacity: Int = 128) {
        self.terminalCapacity = max(1, terminalCapacity)
    }

    // Compatibility seam retained for the connection-only slice. The mutable
    // lifecycle connection uses register(entry:makeTerminalEvent:) so it can
    // publish supersession terminals; callers of this legacy API get the
    // original record-and-return behavior with the caller-supplied prompt ID.
    @discardableResult
    func record(_ request: CodexAppServerApprovalRequest) -> InteractivePrompt {
        let prompt = request.makePrompt()
        return record(request, prompt: prompt)
    }

    @discardableResult
    func record(_ request: CodexAppServerApprovalRequest,
                prompt: InteractivePrompt) -> InteractivePrompt {
        let entry = CodexAppServerApprovalPromptEntry(request: request, prompt: prompt)
        lock.withCodexApprovalLock {
            guard retired == false else {
                return
            }
            let previousAttempt = entriesByPromptID[prompt.promptID]?.attempt
                ?? terminalsByPromptID[prompt.promptID]?.attempt
                ?? 0
            removeTerminalLocked(promptID: prompt.promptID)
            entriesByPromptID[prompt.promptID] = ActiveEntry(entry: entry,
                                                             phase: .pending,
                                                             attempt: previousAttempt + 1,
                                                             lastAttempt: nil,
                                                             publishedEvent: nil)
        }
        return prompt
    }

    func register(entry newEntry: CodexAppServerApprovalPromptEntry,
                  makeTerminalEvent: (CodexAppServerApprovalPromptEntry, String, Int) -> AgentEvent) -> RegisterOutcome {
        lock.withCodexApprovalLock {
            // Closed-admission gate: once the generation started retiring, no
            // request may create or revive an active prompt.
            guard retired == false else {
                return .rejectedRetired
            }
            let promptID = newEntry.prompt.promptID
            let requestKey = newEntry.request.requestIDKey
            let fingerprint = newEntry.request.wireFingerprint

            // Wire ledger first: the collision domain is the JSON-RPC
            // RequestId itself, regardless of which prompt identity fields
            // (item, method, payload) changed.
            if let owner = wireOwnersByRequestKey[requestKey] {
                if owner.poisoned {
                    // Poison is permanent for this connection: no terminal
                    // branch may resurrect the identity.
                    return .rejectedPoisonedRequestID(terminals: [], isNewViolation: false)
                }
                if owner.fingerprint != fingerprint || owner.promptID != promptID {
                    if owner.responseOnWire {
                        // A response for different content may already be on
                        // the wire under this id: protocol violation. Poison
                        // the id, terminalize whatever lifecycle owned it,
                        // publish nothing actionable, write no further bytes.
                        wireOwnersByRequestKey[requestKey] = WireOwner(promptID: owner.promptID,
                                                                       fingerprint: owner.fingerprint,
                                                                       responseOnWire: owner.responseOnWire,
                                                                       poisoned: true)
                        var terminals: [CodexAppServerApprovalTerminalRecord] = []
                        if let active = entriesByPromptID.removeValue(forKey: owner.promptID) {
                            let terminal = CodexAppServerApprovalTerminalRecord(entry: active.entry,
                                                                                reason: "superseded",
                                                                                event: makeTerminalEvent(active.entry, "superseded", active.attempt),
                                                                                attempt: active.attempt)
                            insertTerminalLocked(terminal, promptID: owner.promptID)
                            terminals.append(terminal)
                        }
                        return .rejectedPoisonedRequestID(terminals: terminals, isNewViolation: true)
                    }
                    // Pre-wire: the server replaced the outstanding request.
                    // The old owner's lifecycle terminates (its pre-wire
                    // submits fail the wire gate) and ownership transfers.
                    if owner.promptID != promptID,
                       let previousActive = entriesByPromptID.removeValue(forKey: owner.promptID) {
                        let terminal = CodexAppServerApprovalTerminalRecord(entry: previousActive.entry,
                                                                            reason: "superseded",
                                                                            event: makeTerminalEvent(previousActive.entry, "superseded", previousActive.attempt),
                                                                            attempt: previousActive.attempt)
                        insertTerminalLocked(terminal, promptID: owner.promptID)
                        // Fall through: the new request registers below and a
                        // fresh lifecycle starts; the superseded terminal is
                        // carried on the outcome via supersededPayloadChanged
                        // when identities matched, or handled here for
                        // cross-identity replacement.
                        let attempt = registerFreshLocked(newEntry, promptID: promptID)
                        wireOwnersByRequestKey[requestKey] = WireOwner(promptID: promptID,
                                                                       fingerprint: fingerprint,
                                                                       responseOnWire: false,
                                                                       poisoned: false)
                        return .supersededPayloadChanged(terminal: terminal, entry: newEntry, attempt: attempt)
                    }
                }
            }

            if var active = entriesByPromptID[promptID] {
                if active.entry.request.wireFingerprint == fingerprint {
                    // Equivalent payload: the stored entry is replaced by the
                    // newly delivered request so display and response always
                    // come from the same request object. The server re-asked,
                    // so any earlier response was not accepted: the wire
                    // ownership resets for the new delivery.
                    active.entry = newEntry
                    active.phase = .pending
                    active.attempt += 1
                    active.publishedEvent = nil
                    entriesByPromptID[promptID] = active
                    // Wire taint is connection-level history, not attempt
                    // state: once a response for this RequestId was begun or
                    // enqueued, the taint survives identical re-deliveries
                    // until the request is authoritatively resolved. Only the
                    // active attempt re-arms.
                    wireOwnersByRequestKey[requestKey] = WireOwner(promptID: promptID,
                                                                   fingerprint: fingerprint,
                                                                   responseOnWire: wireOwnersByRequestKey[requestKey]?.responseOnWire ?? false,
                                                                   poisoned: false)
                    return .reactivated(newEntry, attempt: active.attempt)
                }
                // Payload changed under the same identity. If a response for
                // the OLD payload is being written or was already flushed
                // (wire ledger), this was caught above as a violation; here
                // the phase-level wire state is the belt-and-braces check.
                if case .submitting(let attempt) = active.phase,
                   attempt.wireState != .preparing {
                    entriesByPromptID.removeValue(forKey: promptID)
                    let terminal = CodexAppServerApprovalTerminalRecord(entry: active.entry,
                                                                        reason: "superseded",
                                                                        event: makeTerminalEvent(active.entry, "superseded", active.attempt),
                                                                        attempt: active.attempt)
                    insertTerminalLocked(terminal, promptID: promptID)
                    wireOwnersByRequestKey[requestKey] = WireOwner(promptID: promptID,
                                                                   fingerprint: active.entry.request.wireFingerprint,
                                                                   responseOnWire: true,
                                                                   poisoned: true)
                    return .rejectedPoisonedRequestID(terminals: [terminal], isNewViolation: true)
                }
                // No bytes can reach the wire for the old lifecycle any more:
                // a pre-wire submit fails its beginWire check against the new
                // attempt. Terminate the old lifecycle atomically and start a
                // clean one; old submit attempts and conflict guards must not
                // carry over.
                entriesByPromptID.removeValue(forKey: promptID)
                let terminal = CodexAppServerApprovalTerminalRecord(entry: active.entry,
                                                                    reason: "superseded",
                                                                    event: makeTerminalEvent(active.entry, "superseded", active.attempt),
                                                                    attempt: active.attempt)
                let attempt = active.attempt + 1
                entriesByPromptID[promptID] = ActiveEntry(entry: newEntry,
                                                          phase: .pending,
                                                          attempt: attempt,
                                                          lastAttempt: nil,
                                                          publishedEvent: nil)
                wireOwnersByRequestKey[requestKey] = WireOwner(promptID: promptID,
                                                               fingerprint: fingerprint,
                                                               responseOnWire: false,
                                                               poisoned: false)
                return .supersededPayloadChanged(terminal: terminal, entry: newEntry, attempt: attempt)
            }
            // A re-delivered request supersedes any terminal record for the
            // same identity: the server is authoritative that it still wants
            // an answer. The attempt counter keeps rising so the new
            // lifecycle produces fresh event identities.
            let attempt = registerFreshLocked(newEntry, promptID: promptID)
            wireOwnersByRequestKey[requestKey] = WireOwner(promptID: promptID,
                                                           fingerprint: fingerprint,
                                                           responseOnWire: wireOwnersByRequestKey[requestKey]?.responseOnWire ?? false,
                                                           poisoned: false)
            return .recorded(newEntry, attempt: attempt)
        }
    }

    private func registerFreshLocked(_ newEntry: CodexAppServerApprovalPromptEntry, promptID: String) -> Int {
        let attempt = (terminalsByPromptID[promptID]?.attempt ?? 0) + 1
        removeTerminalLocked(promptID: promptID)
        entriesByPromptID[promptID] = ActiveEntry(entry: newEntry,
                                                  phase: .pending,
                                                  attempt: attempt,
                                                  lastAttempt: nil,
                                                  publishedEvent: nil)
        return attempt
    }

    // Claims the right to write a non-approval (error) response for a
    // server-initiated RequestId. ALL server-initiated frames share one
    // connection-scoped collision domain: a malformed or unsupported request
    // reusing an id whose response is already on the wire is the same
    // protocol violation as a changed approval.
    enum ServerErrorResponseClaim {
        case allowed(terminals: [CodexAppServerApprovalTerminalRecord])
        case rejectedPoisoned(terminals: [CodexAppServerApprovalTerminalRecord], isNewViolation: Bool)
    }

    func claimServerErrorResponse(requestIDKey: String,
                                  fingerprint: String,
                                  makeTerminalEvent: (CodexAppServerApprovalPromptEntry, String, Int) -> AgentEvent) -> ServerErrorResponseClaim {
        lock.withCodexApprovalLock {
            guard let owner = wireOwnersByRequestKey[requestIDKey] else {
                wireOwnersByRequestKey[requestIDKey] = WireOwner(promptID: "",
                                                                 fingerprint: fingerprint,
                                                                 responseOnWire: true,
                                                                 poisoned: false)
                return .allowed(terminals: [])
            }
            if owner.poisoned {
                return .rejectedPoisoned(terminals: [], isNewViolation: false)
            }
            if owner.fingerprint == fingerprint {
                // Identical redelivery of the same malformed/unsupported
                // request: re-sending the equivalent error is fine.
                wireOwnersByRequestKey[requestIDKey] = WireOwner(promptID: owner.promptID,
                                                                 fingerprint: owner.fingerprint,
                                                                 responseOnWire: true,
                                                                 poisoned: false)
                return .allowed(terminals: [])
            }
            // Changed content under the same id.
            var terminals: [CodexAppServerApprovalTerminalRecord] = []
            if owner.responseOnWire {
                // A response for different content may already be on the
                // wire: poison, terminalize the owning lifecycle, zero bytes.
                if let active = entriesByPromptID.removeValue(forKey: owner.promptID) {
                    let terminal = CodexAppServerApprovalTerminalRecord(entry: active.entry,
                                                                        reason: "superseded",
                                                                        event: makeTerminalEvent(active.entry, "superseded", active.attempt),
                                                                        attempt: active.attempt)
                    insertTerminalLocked(terminal, promptID: owner.promptID)
                    terminals.append(terminal)
                }
                wireOwnersByRequestKey[requestIDKey] = WireOwner(promptID: owner.promptID,
                                                                 fingerprint: owner.fingerprint,
                                                                 responseOnWire: owner.responseOnWire,
                                                                 poisoned: true)
                return .rejectedPoisoned(terminals: terminals, isNewViolation: true)
            }
            // Pre-wire replacement: the previous owner's lifecycle ends and
            // the error response claims the wire.
            if let active = entriesByPromptID.removeValue(forKey: owner.promptID) {
                let terminal = CodexAppServerApprovalTerminalRecord(entry: active.entry,
                                                                    reason: "superseded",
                                                                    event: makeTerminalEvent(active.entry, "superseded", active.attempt),
                                                                    attempt: active.attempt)
                insertTerminalLocked(terminal, promptID: owner.promptID)
                terminals.append(terminal)
            }
            wireOwnersByRequestKey[requestIDKey] = WireOwner(promptID: "",
                                                             fingerprint: fingerprint,
                                                             responseOnWire: true,
                                                             poisoned: false)
            return .allowed(terminals: terminals)
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
                // Server-issued lifecycle capability: a card from an older
                // delivery (or changed payload) presents a stale token and
                // must not decide the current lifecycle.
                guard let published = active.publishedEvent,
                      published.eventID == lifecycleToken else {
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
                // An earlier (possibly delivered) attempt chose another
                // option; do not blindly send a second decision.
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
            return .begin(entry: active.entry, response: response, lifecycleAttempt: active.attempt)
        }
    }

    // Answers-map submit for `item/tool/requestUserInput`. Shares the exact
    // lifecycle/wire state machine with option submits; the decision
    // identity for conflict detection is the computed response payload.
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
            if let lifecycleToken {
                guard let published = active.publishedEvent,
                      published.eventID == lifecycleToken else {
                    return .lifecycleTokenMismatch
                }
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
                // A different decision (different answers or an earlier
                // option submit) was already attempted; fail closed.
                return .optionConflict
            }
            let attempt = CodexAppServerApprovalSubmitAttempt(clientRequestID: clientRequestID,
                                                              targetIndex: -1,
                                                              response: response)
            active.phase = .submitting(attempt)
            active.lastAttempt = attempt
            entriesByPromptID[promptID] = active
            return .begin(entry: active.entry, response: response, lifecycleAttempt: active.attempt)
        }
    }

    // Marks the response as entering the wire. Returns false when the
    // lifecycle attempt is no longer current (superseded/terminalized): the
    // caller must NOT write any bytes, because they could be interpreted as
    // an approval of a different (changed) payload under the same JSON-RPC
    // request id.
    func beginWire(promptID: String, lifecycleAttempt: Int) -> Bool {
        lock.withCodexApprovalLock {
            guard var active = entriesByPromptID[promptID],
                  active.attempt == lifecycleAttempt,
                  case .submitting(var attempt) = active.phase else {
                return false
            }
            let requestKey = active.entry.request.requestIDKey
            if let owner = wireOwnersByRequestKey[requestKey],
               owner.poisoned || owner.promptID != promptID {
                return false
            }
            attempt.wireState = .writing
            active.phase = .submitting(attempt)
            entriesByPromptID[promptID] = active
            // The ledger marks the wire as owned by this lifecycle BEFORE any
            // byte is enqueued.
            wireOwnersByRequestKey[requestKey] = WireOwner(promptID: promptID,
                                                           fingerprint: active.entry.request.wireFingerprint,
                                                           responseOnWire: true,
                                                           poisoned: false)
            return true
        }
    }

    func endWireFlushed(promptID: String, lifecycleAttempt: Int) {
        lock.withCodexApprovalLock {
            guard var active = entriesByPromptID[promptID],
                  active.attempt == lifecycleAttempt,
                  case .submitting(var attempt) = active.phase else {
                return
            }
            attempt.wireState = .flushed
            active.phase = .submitting(attempt)
            entriesByPromptID[promptID] = active
        }
    }

    func completeSubmitFlush(promptID: String, lifecycleAttempt: Int) -> SubmitCompletionOutcome {
        lock.withCodexApprovalLock {
            if let active = entriesByPromptID[promptID], active.attempt != lifecycleAttempt {
                return .supersededLifecycle
            }
            if let terminal = terminalsByPromptID[promptID] {
                return .terminal(terminal)
            }
            guard entriesByPromptID[promptID] != nil else {
                return .supersededLifecycle
            }
            // Entry stays in submitting phase: the flush only proves the
            // transport accepted the frame, not that the app-server cleared
            // the request.
            return .awaitingConfirmation
        }
    }

    func failSubmit(promptID: String, lifecycleAttempt: Int) -> SubmitCompletionOutcome {
        lock.withCodexApprovalLock {
            if let active = entriesByPromptID[promptID], active.attempt != lifecycleAttempt {
                // A newer lifecycle owns this prompt; the failed old attempt
                // must not disturb it.
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
            guard entriesByPromptID[promptID] != nil else {
                return .supersededLifecycle
            }
            return .awaitingConfirmation
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

    func resolve(promptID: String, targetIndex: Int) throws -> JSONValue {
        let (_, response) = try resolveEntry(promptID: promptID,
                                             targetIndex: targetIndex)
        return response
    }

    func resolveEntry(
        promptID: String,
        targetIndex: Int
    ) throws -> (entry: CodexAppServerApprovalPromptEntry, response: JSONValue) {
        try lock.withCodexApprovalLock {
            guard let active = entriesByPromptID[promptID] else {
                throw BridgeInternalError.notFound("Unknown Codex approval prompt.")
            }
            let response = try active.entry.request.response(targetIndex: targetIndex)
            entriesByPromptID.removeValue(forKey: promptID)
            wireOwnersByRequestKey.removeValue(forKey: active.entry.request.requestIDKey)
            return (active.entry, response)
        }
    }

    func remove(promptID: String) -> CodexAppServerApprovalPromptEntry? {
        lock.withCodexApprovalLock {
            guard let active = entriesByPromptID.removeValue(forKey: promptID) else {
                return nil
            }
            wireOwnersByRequestKey.removeValue(forKey: active.entry.request.requestIDKey)
            return active.entry
        }
    }

    func terminalRecord(promptID: String) -> CodexAppServerApprovalTerminalRecord? {
        lock.withCodexApprovalLock {
            terminalsByPromptID[promptID]
        }
    }

    func pendingStates() -> [(entry: CodexAppServerApprovalPromptEntry, phase: CodexAppServerApprovalPhase, attempt: Int, publishedEvent: AgentEvent?)] {
        lock.withCodexApprovalLock {
            entriesByPromptID.values.map { ($0.entry, $0.phase, $0.attempt, $0.publishedEvent) }
        }
    }

    // Atomically removes matching active entries and records their terminal
    // state. `makeEvent` runs under the lock so no submit can interleave
    // between removal and the terminal record becoming visible.
    func resolveExternally(reason: String,
                           where matches: (CodexAppServerApprovalRequest) -> Bool,
                           makeEvent: (CodexAppServerApprovalPromptEntry, String, Int) -> AgentEvent) -> [CodexAppServerApprovalTerminalRecord] {
        lock.withCodexApprovalLock {
            let matching = entriesByPromptID.values.filter { matches($0.entry.request) }
            var records: [CodexAppServerApprovalTerminalRecord] = []
            for active in matching {
                let promptID = active.entry.prompt.promptID
                entriesByPromptID.removeValue(forKey: promptID)
                // Authoritative resolution ends the request's wire history:
                // the server acknowledged this RequestId, so a future reuse
                // (which a correct server never does) starts clean.
                wireOwnersByRequestKey.removeValue(forKey: active.entry.request.requestIDKey)
                let record = CodexAppServerApprovalTerminalRecord(entry: active.entry,
                                                                  reason: reason,
                                                                  event: makeEvent(active.entry, reason, active.attempt),
                                                                  attempt: active.attempt)
                insertTerminalLocked(record, promptID: promptID)
                records.append(record)
            }
            return records
        }
    }

    func resolveAllExternally(reason: String,
                              makeEvent: (CodexAppServerApprovalPromptEntry, String, Int) -> AgentEvent) -> [CodexAppServerApprovalTerminalRecord] {
        resolveExternally(reason: reason, where: { _ in true }, makeEvent: makeEvent)
    }

    // Atomically retires the generation and terminalizes everything that was
    // admitted before. Requests racing with close either land before this
    // (and are terminalized here) or after (and are rejected by the
    // closed-admission gate); a retired generation can never end up with an
    // active prompt.
    func retireAndResolveAll(reason: String,
                             makeEvent: (CodexAppServerApprovalPromptEntry, String, Int) -> AgentEvent) -> [CodexAppServerApprovalTerminalRecord] {
        lock.withCodexApprovalLock {
            retired = true
            var records: [CodexAppServerApprovalTerminalRecord] = []
            for active in entriesByPromptID.values {
                let promptID = active.entry.prompt.promptID
                let record = CodexAppServerApprovalTerminalRecord(entry: active.entry,
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

    func isRetired() -> Bool {
        lock.withCodexApprovalLock {
            retired
        }
    }

    func terminalRecordCount() -> Int {
        lock.withCodexApprovalLock {
            terminalsByPromptID.count
        }
    }

    private func insertTerminalLocked(_ record: CodexAppServerApprovalTerminalRecord, promptID: String) {
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
