import Foundation

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
    let result: [String: JSONValue]?
    let error: BridgeErrorPayload?
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
