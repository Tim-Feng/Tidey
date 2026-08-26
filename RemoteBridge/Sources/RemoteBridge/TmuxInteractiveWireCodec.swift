import Foundation

enum TmuxInteractiveWireAction: Equatable, Sendable {
    case subscribe(TmuxInteractiveSubscribe)
    case input(TmuxInteractiveInput)
    case reply(TmuxInteractiveTerminalReply)
    case resize(TmuxInteractiveResize)
    case unsubscribe(TmuxInteractiveUnsubscribe)
}

enum TmuxInteractiveWireCodecError: Error, Equatable {
    case invalidField(String)
}

struct TmuxInteractiveAuthoritativeStartEnvelope: Codable, Equatable, Sendable {
    let type: String
    let subscriptionID: String
    let generation: UInt64
    let workspaceID: String
    let panelID: String
    let sessionID: String
    let windowID: String
    let paneID: String
    let historyAnchorOffset: Int?
    let historyAnchorSHA16: String?
    let historyAttachSize: Int?
    let bootstrapColumns: Int?
    let bootstrapRows: Int?
    let bootstrapDataBase64: String?
    let columns: Int
    let rows: Int
    let dataBase64: String

    enum CodingKeys: String, CodingKey {
        case type
        case subscriptionID = "subscription_id"
        case generation
        case workspaceID = "workspace_id"
        case panelID = "panel_id"
        case sessionID = "session_id"
        case windowID = "window_id"
        case paneID = "pane_id"
        case historyAnchorOffset = "history_anchor_offset"
        case historyAnchorSHA16 = "history_anchor_sha16"
        case historyAttachSize = "history_attach_size"
        case bootstrapColumns = "bootstrap_cols"
        case bootstrapRows = "bootstrap_rows"
        case bootstrapDataBase64 = "bootstrap_data_base64"
        case columns = "cols"
        case rows
        case dataBase64 = "data_base64"
    }
}

struct TmuxInteractiveOutputEnvelope: Codable, Equatable, Sendable {
    let type: String
    let subscriptionID: String
    let generation: UInt64
    let sequence: UInt64
    let dataBase64: String

    enum CodingKeys: String, CodingKey {
        case type
        case subscriptionID = "subscription_id"
        case generation
        case sequence
        case dataBase64 = "data_base64"
    }
}

struct TmuxInteractiveAttachedEnvelope: Codable, Equatable, Sendable {
    let type: String
    let subscriptionID: String
    let generation: UInt64
    let workspaceID: String
    let panelID: String
    let sessionID: String
    let windowID: String
    let paneID: String
    let historyAnchorOffset: Int?
    let historyAnchorSHA16: String?
    let historyAttachSize: Int?
    let columns: Int
    let rows: Int
    let dataBase64: String
    let sequence: UInt64

    enum CodingKeys: String, CodingKey {
        case type
        case subscriptionID = "subscription_id"
        case generation
        case workspaceID = "workspace_id"
        case panelID = "panel_id"
        case sessionID = "session_id"
        case windowID = "window_id"
        case paneID = "pane_id"
        case historyAnchorOffset = "history_anchor_offset"
        case historyAnchorSHA16 = "history_anchor_sha16"
        case historyAttachSize = "history_attach_size"
        case columns = "cols"
        case rows
        case dataBase64 = "data_base64"
        case sequence
    }
}

struct TmuxInteractiveReadyEnvelope: Codable, Equatable, Sendable {
    let type: String
    let subscriptionID: String
    let generation: UInt64
    let sequence: UInt64

    enum CodingKeys: String, CodingKey {
        case type
        case subscriptionID = "subscription_id"
        case generation
        case sequence
    }
}

struct TmuxInteractiveStateEnvelope: Codable, Equatable, Sendable {
    let type: String
    let subscriptionID: String
    let generation: UInt64
    let state: String
    let message: String?

    enum CodingKeys: String, CodingKey {
        case type
        case subscriptionID = "subscription_id"
        case generation
        case state
        case message
    }
}

enum TmuxInteractiveWireCodec {
    static let maximumSafeJSONInteger = 9_007_199_254_740_991
    static let maximumInputBytes = 1_024 * 1_024
    static let maximumReplyBytes = 4 * 1_024
    static let maximumPendingReplyBytes = 64 * 1_024
    static let maximumStartupReplyBytes = 64 * 1_024

    static func decode(_ request: BridgeRequest) throws -> TmuxInteractiveWireAction? {
        switch request.action {
        case TmuxInteractiveProtocolV1.subscribeAction:
            let params = try requiredParams(request)
            return .subscribe(
                TmuxInteractiveSubscribe(
                    workspaceID: try requiredString("workspace_id", in: params),
                    panelID: try requiredString("panel_id", in: params),
                    binding: try binding(in: params),
                    viewport: try viewport(in: params),
                    startupMode: try startupMode(in: params)
                )
            )
        case TmuxInteractiveProtocolV1.inputAction:
            let params = try requiredParams(request)
            let encoded = try requiredString("data_base64", in: params)
            guard let bytes = Data(base64Encoded: encoded),
                  bytes.isEmpty == false,
                  bytes.count <= maximumInputBytes else {
                throw TmuxInteractiveWireCodecError.invalidField("data_base64")
            }
            return .input(
                TmuxInteractiveInput(binding: try binding(in: params), bytes: bytes)
            )
        case TmuxInteractiveProtocolV1.replyAction:
            let params = try requiredParams(request)
            let encoded = try requiredString("data_base64", in: params)
            guard let bytes = Data(base64Encoded: encoded),
                  bytes.isEmpty == false,
                  bytes.count <= maximumReplyBytes else {
                throw TmuxInteractiveWireCodecError.invalidField("data_base64")
            }
            return .reply(
                TmuxInteractiveTerminalReply(
                    binding: try binding(in: params),
                    bytes: bytes
                )
            )
        case TmuxInteractiveProtocolV1.resizeAction:
            let params = try requiredParams(request)
            return .resize(
                TmuxInteractiveResize(
                    binding: try binding(in: params),
                    viewport: try viewport(in: params)
                )
            )
        case TmuxInteractiveProtocolV1.unsubscribeAction:
            let params = try requiredParams(request)
            return .unsubscribe(
                TmuxInteractiveUnsubscribe(binding: try binding(in: params))
            )
        default:
            return nil
        }
    }

    static func envelope(
        for start: TmuxInteractiveAuthoritativeStart
    ) -> TmuxInteractiveAuthoritativeStartEnvelope {
        let proof = start.attachProof
        return TmuxInteractiveAuthoritativeStartEnvelope(
            type: TmuxInteractiveProtocolV1.startEventType,
            subscriptionID: start.binding.subscriptionID,
            generation: start.binding.generation,
            workspaceID: proof.workspaceID,
            panelID: proof.panelID,
            sessionID: proof.sessionID,
            windowID: proof.windowID,
            paneID: proof.paneID,
            historyAnchorOffset: start.historyAnchor?.offset,
            historyAnchorSHA16: start.historyAnchor?.sha16,
            historyAttachSize: start.historyAnchor?.attachHistorySize,
            bootstrapColumns: start.bootstrapPhase?.viewport.columns,
            bootstrapRows: start.bootstrapPhase?.viewport.rows,
            bootstrapDataBase64: start.bootstrapPhase?.bytes.base64EncodedString(),
            columns: start.viewport.columns,
            rows: start.viewport.rows,
            dataBase64: start.initialBytes.base64EncodedString()
        )
    }

    static func envelope(
        for output: TmuxInteractiveOutputChunk
    ) -> TmuxInteractiveOutputEnvelope {
        TmuxInteractiveOutputEnvelope(
            type: TmuxInteractiveProtocolV1.outputEventType,
            subscriptionID: output.binding.subscriptionID,
            generation: output.binding.generation,
            sequence: output.sequence,
            dataBase64: output.bytes.base64EncodedString()
        )
    }

    static func envelope(
        for attached: TmuxInteractiveAttached
    ) -> TmuxInteractiveAttachedEnvelope {
        let proof = attached.attachProof
        return TmuxInteractiveAttachedEnvelope(
            type: TmuxInteractiveProtocolV1.attachedEventType,
            subscriptionID: attached.binding.subscriptionID,
            generation: attached.binding.generation,
            workspaceID: proof.workspaceID,
            panelID: proof.panelID,
            sessionID: proof.sessionID,
            windowID: proof.windowID,
            paneID: proof.paneID,
            historyAnchorOffset: attached.historyAnchor?.offset,
            historyAnchorSHA16: attached.historyAnchor?.sha16,
            historyAttachSize: attached.historyAnchor?.attachHistorySize,
            columns: attached.viewport.columns,
            rows: attached.viewport.rows,
            dataBase64: attached.initialBytes.base64EncodedString(),
            sequence: attached.sequence
        )
    }

    static func envelope(
        for ready: TmuxInteractiveReady
    ) -> TmuxInteractiveReadyEnvelope {
        TmuxInteractiveReadyEnvelope(
            type: TmuxInteractiveProtocolV1.readyEventType,
            subscriptionID: ready.binding.subscriptionID,
            generation: ready.binding.generation,
            sequence: ready.sequence
        )
    }

    static func envelope(
        for state: TmuxInteractiveStateChange
    ) -> TmuxInteractiveStateEnvelope {
        TmuxInteractiveStateEnvelope(
            type: TmuxInteractiveProtocolV1.stateEventType,
            subscriptionID: state.binding.subscriptionID,
            generation: state.binding.generation,
            state: state.state.rawValue,
            message: state.message
        )
    }

    private static func requiredParams(
        _ request: BridgeRequest
    ) throws -> [String: JSONValue] {
        guard let params = request.params else {
            throw TmuxInteractiveWireCodecError.invalidField("params")
        }
        return params
    }

    private static func requiredString(
        _ field: String,
        in params: [String: JSONValue]
    ) throws -> String {
        guard let value = params[field]?.stringValue,
              value.isEmpty == false else {
            throw TmuxInteractiveWireCodecError.invalidField(field)
        }
        return value
    }

    private static func binding(
        in params: [String: JSONValue]
    ) throws -> TmuxInteractiveSubscriptionBinding {
        let subscriptionID = try requiredString("subscription_id", in: params)
        guard case .number(let generationValue) = params["generation"],
              generationValue.isFinite,
              generationValue.rounded(.towardZero) == generationValue,
              generationValue >= 0,
              generationValue <= Double(maximumSafeJSONInteger) else {
            throw TmuxInteractiveWireCodecError.invalidField("generation")
        }
        return TmuxInteractiveSubscriptionBinding(
            subscriptionID: subscriptionID,
            generation: UInt64(generationValue)
        )
    }

    private static func viewport(
        in params: [String: JSONValue]
    ) throws -> TmuxInteractiveViewport {
        let columns = try positiveUInt16Field("cols", in: params)
        let rows = try positiveUInt16Field("rows", in: params)
        return TmuxInteractiveViewport(columns: columns, rows: rows)
    }

    private static func startupMode(
        in params: [String: JSONValue]
    ) throws -> TmuxInteractiveStartupMode {
        guard let value = params["startup_mode"] else {
            return .legacy
        }
        guard let rawValue = value.stringValue,
              let mode = TmuxInteractiveStartupMode(rawValue: rawValue) else {
            throw TmuxInteractiveWireCodecError.invalidField("startup_mode")
        }
        return mode
    }

    private static func positiveUInt16Field(
        _ field: String,
        in params: [String: JSONValue]
    ) throws -> Int {
        guard let value = params[field]?.intValue,
              value > 0,
              value <= Int(UInt16.max) else {
            throw TmuxInteractiveWireCodecError.invalidField(field)
        }
        return value
    }
}
