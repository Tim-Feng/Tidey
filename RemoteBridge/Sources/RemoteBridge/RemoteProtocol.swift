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
            return value.rounded(.towardZero) == value ? Int(value) : value
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

    var intValue: Int? {
        if case .number(let value) = self {
            return Int(value)
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
