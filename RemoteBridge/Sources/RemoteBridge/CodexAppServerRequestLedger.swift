import Foundation

enum CodexAppServerRequestFingerprint {
    static func make(method: String,
                     rawObject: [String: Any]?,
                     fallbackParams: [String: JSONValue]) -> String {
        let paramsComponent: String
        if let rawObject {
            if rawObject.keys.contains("params") {
                let rawParams = rawObject["params"] ?? NSNull()
                paramsComponent = canonicalRawFragment(rawParams)
                    .map { "present:\($0.utf8.count):\($0)" }
                    ?? canonicalFallback(fallbackParams)
            } else {
                paramsComponent = "missing"
            }
        } else {
            paramsComponent = canonicalFallback(fallbackParams)
        }
        return "method:\(method.utf8.count):\(method)\nparams:\(paramsComponent)"
    }

    static func make(method: String,
                     params: [String: JSONValue]) -> String {
        make(method: method, rawObject: nil, fallbackParams: params)
    }

    private static func canonicalRawFragment(_ value: Any) -> String? {
        guard let data = try? JSONSerialization.data(
            withJSONObject: value,
            options: [.sortedKeys, .fragmentsAllowed]) else {
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func canonicalFallback(
        _ params: [String: JSONValue]
    ) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(JSONValue.object(params))) ?? Data()
        let value = String(decoding: data, as: UTF8.self)
        return "present:\(value.utf8.count):\(value)"
    }
}

// Connection-scoped ownership for JSON-RPC ids used by server-initiated
// requests. A response may only be written by the exact request fingerprint
// and prompt association that admitted the id.
final class CodexAppServerRequestLedger: @unchecked Sendable {
    enum Admission: Equatable {
        case acceptedNew
        case acceptedDuplicate
        case replaced(previousPromptID: String?)
        case protocolViolation(isNew: Bool)
    }

    private struct Owner {
        let fingerprint: String
        let promptID: String?
        var responseStarted: Bool
        var poisoned: Bool
    }

    private let lock = NSLock()
    private var ownersByRequestID: [String: Owner] = [:]

    func admit(requestIDKey: String,
               fingerprint: String,
               promptID: String?) -> Admission {
        lock.lock()
        defer { lock.unlock() }

        guard var owner = ownersByRequestID[requestIDKey] else {
            ownersByRequestID[requestIDKey] = Owner(
                fingerprint: fingerprint,
                promptID: promptID,
                responseStarted: false,
                poisoned: false)
            return .acceptedNew
        }
        guard !owner.poisoned else {
            return .protocolViolation(isNew: false)
        }
        if owner.fingerprint == fingerprint,
           owner.promptID == promptID {
            return .acceptedDuplicate
        }
        if owner.responseStarted {
            owner.poisoned = true
            ownersByRequestID[requestIDKey] = owner
            return .protocolViolation(isNew: true)
        }

        ownersByRequestID[requestIDKey] = Owner(
            fingerprint: fingerprint,
            promptID: promptID,
            responseStarted: false,
            poisoned: false)
        return .replaced(previousPromptID: owner.promptID)
    }

    // Marks the point after which a changed request under the same id is a
    // protocol violation. This happens before the transport is invoked,
    // because a throwing writer may still have emitted a partial frame.
    func beginResponse(requestIDKey: String,
                       fingerprint: String,
                       promptID: String?) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard var owner = ownersByRequestID[requestIDKey],
              !owner.poisoned,
              owner.fingerprint == fingerprint,
              owner.promptID == promptID else {
            return false
        }
        owner.responseStarted = true
        ownersByRequestID[requestIDKey] = owner
        return true
    }

    // An authoritative lifecycle terminal releases only the association it
    // actually resolved. A stale terminal cannot clear a newer owner.
    @discardableResult
    func resolve(requestIDKey: String,
                 fingerprint: String,
                 promptID: String?) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard let owner = ownersByRequestID[requestIDKey],
              owner.fingerprint == fingerprint,
              owner.promptID == promptID,
              !owner.poisoned else {
            return false
        }
        ownersByRequestID.removeValue(forKey: requestIDKey)
        return true
    }
}
