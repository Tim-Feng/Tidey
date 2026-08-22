import Foundation

enum TideyBrowserAutomationOperation: String, CaseIterable, Equatable {
    case tabs
    case open
    case claim
    case release
    case reclaim
    case mark
    case close
    case present
    case navigate
    case back
    case forward
    case reload
    case currentURL = "current_url"
    case snapshot
    case click
    case fill
    case type
    case key
    case scroll
    case wait
    case screenshot
    case transferPreflight = "transfer_preflight"
    case transferStart = "transfer_start"
    case transferStatus = "transfer_status"
    case transferPause = "transfer_pause"
}

struct TideyBrowserAutomationElementReference: Equatable {
    let tabID: String
    let navigationEpoch: Int
    let elementID: String
}

enum TideyBrowserAutomationWaitCondition: Equatable {
    case load(timeout: TimeInterval)
    case delay(milliseconds: Int)
    case text(String, timeout: TimeInterval)
    case url(String, timeout: TimeInterval)
}

enum TideyBrowserAutomationCommand: Equatable {
    case tabs
    case open(url: URL)
    case claim(tabID: String)
    case release(tabID: String)
    case reclaim(tabID: String)
    case mark(tabID: String, mark: TideyBrowserAutomationTabMark)
    case close(tabID: String)
    case present(tabID: String)
    case navigate(tabID: String, url: URL)
    case back(tabID: String)
    case forward(tabID: String)
    case reload(tabID: String)
    case currentURL(tabID: String)
    case snapshot(tabID: String)
    case click(target: TideyBrowserAutomationElementReference)
    case fill(target: TideyBrowserAutomationElementReference, text: String)
    case type(target: TideyBrowserAutomationElementReference, text: String)
    case key(tabID: String, key: String)
    case scroll(tabID: String, deltaX: Double, deltaY: Double)
    case wait(tabID: String, condition: TideyBrowserAutomationWaitCondition)
    case screenshot(tabID: String)
    case transferPreflight(TideyBrowserTransferPreflightRequest)
    case transferStart(TideyBrowserTransferStartRequest)
    case transferStatus(transferID: String)
    case transferPause(transferID: String)
}

struct TideyBrowserAutomationRequest: Equatable {
    let workspaceID: String
    let command: TideyBrowserAutomationCommand
}

enum TideyBrowserAutomationErrorCode: String, Equatable {
    case invalidRequest = "invalid_request"
    case invalidURL = "invalid_url"
    case unsupportedScheme = "unsupported_scheme"
    case unsupportedOperation = "unsupported_operation"
    case targetGone = "target_gone"
    case ownershipConflict = "ownership_conflict"
    case workspaceMismatch = "workspace_mismatch"
    case staleReference = "stale_reference"
    case tabLimitReached = "tab_limit_reached"
    case busy
    case timeout
    case navigationFailed = "navigation_failed"
    case internalError = "internal_error"
    case transferAuthentication = "auth_or_entitlement"
    case transferRateLimited = "rate_limited"
    case transferRetryable = "retryable"
    case transferInvalidRange = "invalid_range"
    case transferRepresentationMismatch = "representation_mismatch"
    case transferDestinationFailure = "destination_failure"
    case transferValidationFailure = "validation_failure"
}

struct TideyBrowserAutomationProtocolError: Error, Equatable {
    let code: TideyBrowserAutomationErrorCode
    let message: String
}

struct TideyBrowserAutomationResponse: Equatable {
    let result: [String: TideyBrowserAutomationValue]
}

indirect enum TideyBrowserAutomationValue: Equatable {
    case null
    case bool(Bool)
    case integer(Int)
    case number(Double)
    case string(String)
    case array([TideyBrowserAutomationValue])
    case object([String: TideyBrowserAutomationValue])
}

enum TideyBrowserAutomationProtocol {
    private static let maximumWaitMilliseconds = 30_000
    private static let defaultWaitMilliseconds = 10_000
    private static let supportedKeys: Set<String> = [
        "Enter", "Tab", "Escape", "ArrowUp", "ArrowDown", "ArrowLeft",
        "ArrowRight", "Backspace", "Delete", "Home", "End", "PageUp",
        "PageDown", "Space"
    ]

    static func decodeRequest(workspaceID: String,
                              operation: String,
                              parameters: [String: Any]) throws -> TideyBrowserAutomationRequest {
        guard !workspaceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw error(.invalidRequest, "workspace_id is required")
        }
        guard let operation = TideyBrowserAutomationOperation(rawValue: operation) else {
            throw error(.unsupportedOperation, "Unsupported browser operation")
        }

        let command: TideyBrowserAutomationCommand
        switch operation {
        case .tabs:
            command = .tabs
        case .open:
            command = .open(url: try httpURL(parameters, key: "url"))
        case .claim:
            command = .claim(tabID: try tabID(parameters))
        case .release:
            command = .release(tabID: try tabID(parameters))
        case .reclaim:
            command = .reclaim(tabID: try tabID(parameters))
        case .mark:
            let rawMark = try string(parameters, key: "mark")
            guard let mark = TideyBrowserAutomationTabMark(rawValue: rawMark) else {
                throw error(.invalidRequest, "mark must be none, deliverable, or handoff")
            }
            command = .mark(tabID: try tabID(parameters), mark: mark)
        case .close:
            command = .close(tabID: try tabID(parameters))
        case .present:
            command = .present(tabID: try tabID(parameters))
        case .navigate:
            command = .navigate(
                tabID: try tabID(parameters),
                url: try httpURL(parameters, key: "url")
            )
        case .back:
            command = .back(tabID: try tabID(parameters))
        case .forward:
            command = .forward(tabID: try tabID(parameters))
        case .reload:
            command = .reload(tabID: try tabID(parameters))
        case .currentURL:
            command = .currentURL(tabID: try tabID(parameters))
        case .snapshot:
            command = .snapshot(tabID: try tabID(parameters))
        case .click:
            command = .click(target: try elementReference(parameters))
        case .fill:
            command = .fill(
                target: try elementReference(parameters),
                text: try string(parameters, key: "text", allowEmpty: true)
            )
        case .type:
            command = .type(
                target: try elementReference(parameters),
                text: try string(parameters, key: "text", allowEmpty: true)
            )
        case .key:
            let key = try string(parameters, key: "key")
            guard supportedKeys.contains(key) else {
                throw error(.invalidRequest, "Unsupported key")
            }
            command = .key(tabID: try tabID(parameters), key: key)
        case .scroll:
            command = .scroll(
                tabID: try tabID(parameters),
                deltaX: try number(parameters, key: "delta_x", defaultValue: 0),
                deltaY: try number(parameters, key: "delta_y", defaultValue: 0)
            )
        case .wait:
            command = .wait(
                tabID: try tabID(parameters),
                condition: try waitCondition(parameters)
            )
        case .screenshot:
            command = .screenshot(tabID: try tabID(parameters))
        case .transferPreflight:
            let resumeOffset = try integer(parameters, key: "resume_offset", defaultValue: 0)
            guard resumeOffset >= 0 else {
                throw error(.invalidRequest, "Transfer offset is invalid")
            }
            command = .transferPreflight(TideyBrowserTransferPreflightRequest(
                target: try elementReference(parameters),
                destination: TideyBrowserTransferDestinationRequest(
                    archiveRoot: try string(parameters, key: "archive_root"),
                    expectedVolumeUUID: try string(parameters, key: "expected_volume_uuid"),
                    destinationRelativePath: try string(
                        parameters,
                        key: "destination_relative_path"
                    ),
                    resumeOffset: resumeOffset
                )
            ))
        case .transferStart:
            let resumeOffset = try integer(parameters, key: "resume_offset", defaultValue: 0)
            let expectedTotalBytes = try integer(parameters, key: "expected_total_bytes")
            let pauseAfterBytes = try optionalInteger(parameters, key: "pause_after_bytes")
            guard expectedTotalBytes > 0,
                  resumeOffset >= 0,
                  resumeOffset <= expectedTotalBytes,
                  pauseAfterBytes == nil || pauseAfterBytes! > resumeOffset else {
                throw error(.invalidRequest, "Transfer offsets are invalid")
            }
            let ifRange = try optionalBoundedString(parameters, key: "if_range", maximumLength: 1_024)
            let validatorKindRaw = try optionalBoundedString(
                parameters,
                key: "representation_validator_kind",
                maximumLength: 32
            )
            let validatorValue = try optionalBoundedString(
                parameters,
                key: "representation_validator",
                maximumLength: 1_024
            )
            let representationBinding: TideyBrowserTransferRepresentationBinding?
            if validatorKindRaw == nil, validatorValue == nil {
                representationBinding = nil
            } else {
                guard let validatorKindRaw,
                      let validatorValue,
                      let validatorKind = TideyBrowserTransferValidatorKind(
                        rawValue: validatorKindRaw
                      ),
                      validatorKind == .strongETag || validatorKind == .lastModified,
                      ifRange == nil || ifRange == validatorValue else {
                    throw error(.invalidRequest, "Representation binding is invalid")
                }
                representationBinding = TideyBrowserTransferRepresentationBinding(
                    exactTotalBytes: expectedTotalBytes,
                    validatorKind: validatorKind,
                    validatorValue: validatorValue
                )
            }
            command = .transferStart(TideyBrowserTransferStartRequest(
                target: try elementReference(parameters),
                archiveRoot: try string(parameters, key: "archive_root"),
                expectedVolumeUUID: try string(parameters, key: "expected_volume_uuid"),
                destinationRelativePath: try string(parameters, key: "destination_relative_path"),
                expectedTotalBytes: expectedTotalBytes,
                resumeOffset: resumeOffset,
                ifRange: ifRange,
                pauseAfterBytes: pauseAfterBytes,
                representationBinding: representationBinding
            ))
        case .transferStatus:
            command = .transferStatus(transferID: try string(parameters, key: "transfer_id"))
        case .transferPause:
            command = .transferPause(transferID: try string(parameters, key: "transfer_id"))
        }
        return TideyBrowserAutomationRequest(workspaceID: workspaceID, command: command)
    }

    private static func tabID(_ parameters: [String: Any]) throws -> String {
        try string(parameters, key: "tab_id")
    }

    private static func elementReference(_ parameters: [String: Any]) throws -> TideyBrowserAutomationElementReference {
        let epoch = try integer(parameters, key: "navigation_epoch")
        guard epoch >= 0 else {
            throw error(.invalidRequest, "navigation_epoch must be nonnegative")
        }
        return TideyBrowserAutomationElementReference(
            tabID: try tabID(parameters),
            navigationEpoch: epoch,
            elementID: try string(parameters, key: "element_id")
        )
    }

    private static func waitCondition(_ parameters: [String: Any]) throws -> TideyBrowserAutomationWaitCondition {
        let kind = try string(parameters, key: "condition")
        switch kind {
        case "load":
            return .load(timeout: try timeout(parameters))
        case "delay":
            let milliseconds = try integer(parameters, key: "milliseconds")
            guard (0...maximumWaitMilliseconds).contains(milliseconds) else {
                throw error(.invalidRequest, "milliseconds must be between 0 and 30000")
            }
            return .delay(milliseconds: milliseconds)
        case "text":
            return .text(
                try string(parameters, key: "value"),
                timeout: try timeout(parameters)
            )
        case "url":
            return .url(
                try string(parameters, key: "value"),
                timeout: try timeout(parameters)
            )
        default:
            throw error(.invalidRequest, "Unsupported wait condition")
        }
    }

    private static func timeout(_ parameters: [String: Any]) throws -> TimeInterval {
        let milliseconds = try integer(
            parameters,
            key: "timeout_ms",
            defaultValue: defaultWaitMilliseconds
        )
        guard (1...maximumWaitMilliseconds).contains(milliseconds) else {
            throw error(.invalidRequest, "timeout_ms must be between 1 and 30000")
        }
        return TimeInterval(milliseconds) / 1_000
    }

    private static func httpURL(_ parameters: [String: Any], key: String) throws -> URL {
        let rawValue = try string(parameters, key: key)
        guard let components = URLComponents(string: rawValue),
              let scheme = components.scheme?.lowercased() else {
            throw error(.invalidURL, "Invalid URL")
        }
        guard scheme == "http" || scheme == "https" else {
            throw error(.unsupportedScheme, "Only HTTP and HTTPS URLs are supported")
        }
        guard let host = components.host,
              !host.isEmpty,
              let url = components.url else {
            throw error(.invalidURL, "Invalid URL")
        }
        return url
    }

    private static func string(_ parameters: [String: Any],
                               key: String,
                               allowEmpty: Bool = false) throws -> String {
        guard let value = parameters[key] as? String,
              allowEmpty || !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw error(.invalidRequest, "\(key) is required")
        }
        return value
    }

    private static func integer(_ parameters: [String: Any],
                                key: String,
                                defaultValue: Int? = nil) throws -> Int {
        if parameters[key] == nil, let defaultValue {
            return defaultValue
        }
        guard let number = parameters[key] as? NSNumber else {
            throw error(.invalidRequest, "\(key) must be an integer")
        }
        let value = number.doubleValue
        guard value.isFinite, value.rounded() == value else {
            throw error(.invalidRequest, "\(key) must be an integer")
        }
        return number.intValue
    }

    private static func optionalInteger(_ parameters: [String: Any], key: String) throws -> Int? {
        guard parameters[key] != nil else { return nil }
        return try integer(parameters, key: key)
    }

    private static func optionalBoundedString(_ parameters: [String: Any],
                                              key: String,
                                              maximumLength: Int) throws -> String? {
        guard parameters[key] != nil else { return nil }
        let value = try string(parameters, key: key)
        guard value.count <= maximumLength,
              !value.contains("\n"),
              !value.contains("\r") else {
            throw error(.invalidRequest, "\(key) is invalid")
        }
        return value
    }

    private static func number(_ parameters: [String: Any],
                               key: String,
                               defaultValue: Double? = nil) throws -> Double {
        if parameters[key] == nil, let defaultValue {
            return defaultValue
        }
        guard let number = parameters[key] as? NSNumber,
              number.doubleValue.isFinite else {
            throw error(.invalidRequest, "\(key) must be a finite number")
        }
        return number.doubleValue
    }

    private static func error(_ code: TideyBrowserAutomationErrorCode,
                              _ message: String) -> TideyBrowserAutomationProtocolError {
        TideyBrowserAutomationProtocolError(code: code, message: message)
    }
}

extension TideyBrowserAutomationProtocolError {
    init(transferFailure: TideyBrowserTransferFailure) {
        let code: TideyBrowserAutomationErrorCode
        switch transferFailure.category {
        case .authentication:
            code = .transferAuthentication
        case .rateLimited:
            code = .transferRateLimited
        case .retryable:
            code = .transferRetryable
        case .invalidRange:
            code = .transferInvalidRange
        case .representationMismatch:
            code = .transferRepresentationMismatch
        case .destination:
            code = .transferDestinationFailure
        case .validation:
            code = .transferValidationFailure
        }
        self.init(code: code, message: transferFailure.code)
    }

    init(stateError: TideyBrowserAutomationStateError) {
        switch stateError {
        case .tabLimitReached:
            self.init(code: .tabLimitReached, message: "Private browser tab limit reached")
        case .targetGone:
            self.init(code: .targetGone, message: "Browser tab is no longer available")
        case .ownershipConflict:
            self.init(code: .ownershipConflict, message: "Browser tab is owned by another session")
        case .workspaceMismatch:
            self.init(code: .workspaceMismatch, message: "Browser tab belongs to another workspace")
        case .invalidTransition:
            self.init(code: .invalidRequest, message: "Invalid browser tab state transition")
        }
    }

    var dictionary: [String: Any] {
        ["code": code.rawValue, "message": message]
    }
}

extension TideyBrowserAutomationResponse {
    var dictionary: [String: Any] {
        result.mapValues(\.foundationValue)
    }
}

extension TideyBrowserAutomationValue {
    static func fromFoundation(_ value: Any) -> TideyBrowserAutomationValue {
        if value is NSNull {
            return .null
        }
        if let value = value as? Bool {
            return .bool(value)
        }
        if let value = value as? Int {
            return .integer(value)
        }
        if let value = value as? NSNumber {
            let number = value.doubleValue
            return number.rounded() == number ? .integer(value.intValue) : .number(number)
        }
        if let value = value as? String {
            return .string(value)
        }
        if let value = value as? [Any] {
            return .array(value.map(Self.fromFoundation))
        }
        if let value = value as? [String: Any] {
            return .object(value.mapValues(Self.fromFoundation))
        }
        return .string(String(describing: value))
    }

    var foundationValue: Any {
        switch self {
        case .null:
            return NSNull()
        case .bool(let value):
            return value
        case .integer(let value):
            return value
        case .number(let value):
            return value
        case .string(let value):
            return value
        case .array(let values):
            return values.map(\.foundationValue)
        case .object(let values):
            return values.mapValues(\.foundationValue)
        }
    }
}
