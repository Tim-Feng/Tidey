import Foundation

let bridgeProtocolVersion = 1

enum JSONValue: Codable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let int = try? container.decode(Int.self) {
            self = .number(Double(int))
        } else if let double = try? container.decode(Double.self) {
            self = .number(double)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let object = try? container.decode([String: JSONValue].self) {
            self = .object(object)
        } else if let array = try? container.decode([JSONValue].self) {
            self = .array(array)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }

    var anyValue: Any {
        switch self {
        case .string(let value):
            return value
        case .number(let value):
            if value.isFinite,
               value.rounded(.towardZero) == value,
               let exact = Int(exactly: value) {
                return exact
            }
            return value
        case .bool(let value):
            return value
        case .object(let value):
            return value.mapValues { $0.anyValue }
        case .array(let value):
            return value.map(\.anyValue)
        case .null:
            return NSNull()
        }
    }

    var stringValue: String? {
        if case .string(let value) = self {
            return value
        }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let value) = self {
            return value
        }
        return nil
    }

    var boolLikeValue: Bool? {
        switch self {
        case .bool(let value):
            return value
        case .number(let value):
            return value != 0
        case .string(let value):
            switch value.lowercased() {
            case "true", "1", "yes", "on":
                return true
            case "false", "0", "no", "off":
                return false
            default:
                return nil
            }
        default:
            return nil
        }
    }

    var intValue: Int? {
        if case .number(let value) = self,
           value.isFinite,
           value.rounded(.towardZero) == value {
            return Int(exactly: value)
        }
        return nil
    }

    var objectValue: [String: JSONValue]? {
        if case .object(let value) = self {
            return value
        }
        return nil
    }

    var arrayValue: [JSONValue]? {
        if case .array(let value) = self {
            return value
        }
        return nil
    }
}

struct BridgeRequest: Codable, Sendable {
    let id: String
    let action: String
    let params: [String: JSONValue]?
}

struct BridgeErrorPayload: Codable, Sendable {
    let code: String
    let message: String
}

struct BridgeResponse: Codable, Sendable {
    let id: String?
    let ok: Bool
    let v: Int
    let result: [String: JSONValue]?
    let error: BridgeErrorPayload?

    enum CodingKeys: String, CodingKey {
        case id
        case ok
        case v
        case result
        case error
    }

    init(id: String?,
         ok: Bool,
         v: Int = bridgeProtocolVersion,
         result: [String: JSONValue]?,
         error: BridgeErrorPayload?) {
        self.id = id
        self.ok = ok
        self.v = v
        self.result = result
        self.error = error
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id)
        ok = try container.decode(Bool.self, forKey: .ok)
        v = try container.decodeIfPresent(Int.self, forKey: .v) ?? bridgeProtocolVersion
        result = try container.decodeIfPresent([String: JSONValue].self, forKey: .result)
        error = try container.decodeIfPresent(BridgeErrorPayload.self, forKey: .error)
    }
}

enum BridgeInternalError: Error {
    case unauthorized
    case invalidRequest(String)
    case notFound(String)
    case forbidden(String)
    case conflict(String)
    case fileNeedsConfirmation(String)
    case fileTooLarge(String)
    case invalidResponse
    case socketUnavailable
}

extension BridgeInternalError {
    var payload: BridgeErrorPayload {
        switch self {
        case .unauthorized:
            return BridgeErrorPayload(code: "unauthorized", message: "Missing or invalid bearer token.")
        case .invalidRequest(let message):
            return BridgeErrorPayload(code: "invalid_request", message: message)
        case .notFound(let message):
            return BridgeErrorPayload(code: "not_found", message: message)
        case .forbidden(let message):
            return BridgeErrorPayload(code: "forbidden", message: message)
        case .conflict(let message):
            return BridgeErrorPayload(code: "conflict", message: message)
        case .fileNeedsConfirmation(let message):
            return BridgeErrorPayload(code: "file_needs_confirmation", message: message)
        case .fileTooLarge(let message):
            return BridgeErrorPayload(code: "file_too_large", message: message)
        case .invalidResponse:
            return BridgeErrorPayload(code: "invalid_response", message: "Bridge received an invalid response from Tidey.")
        case .socketUnavailable:
            return BridgeErrorPayload(code: "socket_unavailable", message: "Could not resolve a live Tidey socket.")
        }
    }
}

extension BridgeRequest {
    var tideySocketJSONObject: [String: Any] {
        var object: [String: Any] = [
            "id": id,
            "action": action,
        ]
        if let params {
            object["params"] = params.mapValues(\.anyValue)
        }
        return object
    }
}

struct BridgeFileReadRequest: Sendable {
    let workspaceID: String
    let panelID: String
    let path: String
    let allowLargeRead: Bool

    init(params: [String: JSONValue]?) throws {
        guard let params,
              let workspaceID = params["workspace_id"]?.stringValue,
              let panelID = params["panel_id"]?.stringValue,
              let path = params["path"]?.stringValue,
              !path.isEmpty else {
            throw BridgeInternalError.invalidRequest("file_read requires workspace_id, panel_id, and path")
        }
        self.workspaceID = workspaceID
        self.panelID = panelID
        self.path = path
        self.allowLargeRead = params["allow_large_read"]?.boolLikeValue ?? false
    }
}

struct BridgeFileWriteRequest: Sendable {
    let workspaceID: String
    let panelID: String
    let path: String
    let content: String
    let expectedRevisionToken: String
    let force: Bool

    init(params: [String: JSONValue]?) throws {
        guard let params,
              let workspaceID = params["workspace_id"]?.stringValue,
              let panelID = params["panel_id"]?.stringValue,
              let path = params["path"]?.stringValue,
              let content = params["content"]?.stringValue,
              let expectedRevisionToken = params["expected_revision_token"]?.stringValue,
              !path.isEmpty,
              !expectedRevisionToken.isEmpty else {
            throw BridgeInternalError.invalidRequest("file_write requires workspace_id, panel_id, path, content, and expected_revision_token")
        }
        self.workspaceID = workspaceID
        self.panelID = panelID
        self.path = path
        self.content = content
        self.expectedRevisionToken = expectedRevisionToken
        self.force = params["force"]?.boolLikeValue ?? false
    }
}
