import Foundation

enum CodexAppServerConnectionError: Error {
    case closed
    case invalidJSONLine(String)
    case initializationTimedOut
    case requestFailed(CodexAppServerJSONRPCError)
    case unknownPrompt(String)
    // No authoritative response (success or requestFailed) arrived within
    // the bounded wait. The outcome is unknown — the request may still land
    // server-side after this returns — never safe to treat as zero effect.
    case responseTimedOut
}

extension CodexAppServerConnectionError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .closed:
            return "Codex app-server connection is closed."
        case .invalidJSONLine(let line):
            return "Codex app-server sent invalid JSON: \(line)"
        case .initializationTimedOut:
            return "Codex app-server did not finish initialization in time."
        case .requestFailed(let error):
            return "Codex app-server request failed: \(error.message)"
        case .unknownPrompt(let promptID):
            return "Codex app-server prompt is unknown: \(promptID)"
        case .responseTimedOut:
            return "Codex app-server did not respond in time."
        }
    }
}

struct CodexAppServerJSONRPCError: Codable, Error, Sendable {
    let code: Int
    let message: String
    let data: JSONValue?

    init(code: Int, message: String, data: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }
}

struct CodexAppServerNotification: Sendable {
    let method: String
    let params: [String: JSONValue]
}

struct CodexAppServerApprovalContext: Sendable {
    let workspaceID: String
    let panelID: String
    let sessionID: String
    // Stable identity of the app-server process instance (derived from the
    // registry record's PID/socket for attached runtimes). Reconnecting to
    // the same process keeps the same epoch; a restarted process gets a new
    // one, so its requests can never match records from the previous run.
    let epoch: String

    init(workspaceID: String, panelID: String, sessionID: String, epoch: String = "") {
        self.workspaceID = workspaceID
        self.panelID = panelID
        self.sessionID = sessionID
        self.epoch = epoch
    }
}

struct CodexAppServerInteractivePromptEnvelope: Sendable {
    let request: CodexAppServerApprovalRequest
    let prompt: InteractivePrompt
    let event: AgentEvent
}

// Result of a Remote approval submit. A flushed response is NOT a resolution:
// only an authoritative lifecycle notification produces a terminal event.
enum CodexAppServerApprovalSubmitOutcome: Sendable {
    // Response was handed to the transport; the request stays pending until
    // the app-server confirms via serverRequest/resolved (or a turn/expiry
    // terminal).
    case pendingConfirmation(promptID: String)
    // The request already has its single authoritative terminal record.
    case alreadyResolved(AgentEvent)
}

final class CodexAppServerConnection {
    typealias SendLine = @Sendable (String) throws -> Void
    typealias ClientResponseHandler = (Result<JSONValue, CodexAppServerConnectionError>) -> Void
    typealias NotificationHandler = (CodexAppServerNotification) -> Void
    typealias SequenceProvider = (String) -> Int
    typealias TimestampProvider = () -> String
    typealias InteractivePromptHandler = (CodexAppServerInteractivePromptEnvelope) -> Void
    typealias InteractivePromptResolvedHandler = (AgentEvent) -> Void

    private let stateLock = NSRecursiveLock()
    private var nextRequestID = 1
    private var pendingClientResponses: [String: ClientResponseHandler] = [:]
    private var closed = false
    private let sendLine: SendLine
    private let sendLineConfirmed: SendLine?
    private let onNotification: NotificationHandler
    private let approvalContext: CodexAppServerApprovalContext?
    private let approvalStore: CodexAppServerApprovalPromptStore
    private let nextSequence: SequenceProvider
    private let timestampProvider: TimestampProvider
    private let onInteractivePrompt: InteractivePromptHandler
    private let onInteractivePromptResolved: InteractivePromptResolvedHandler
    // Invoked on a JSON-RPC protocol violation (changed request under a
    // RequestId whose response may already be on the wire). The owner must
    // abort the transport: no further bytes for that id may ever be written.
    private let onProtocolViolation: () -> Void
    // Serializes [store lifecycle transition + external event publication] so
    // admission/publication cannot interleave with close/lifecycle terminals:
    // a pending prompt can never be observed AFTER its generation's terminal.
    private let publicationLock = NSRecursiveLock()
    // Test-only observability: `publicationBarrierHook` fires when a caller
    // ARRIVES at the serialization point (before acquiring the lock);
    // `publicationInteriorHook` fires at named points inside the critical
    // section. Both are nil in production.
    var publicationBarrierHook: (() -> Void)?
    var publicationInteriorHook: ((String) -> Void)?
    // Test-only: fires when a client submit has entered submitApproval but
    // before beginSubmit — the window where a changed-payload redelivery may
    // land first.
    var submitAdmissionHook: (() -> Void)?
    let generationID = UUID().uuidString

    private func withPublicationLock<T>(_ body: () throws -> T) rethrows -> T {
        publicationBarrierHook?()
        publicationLock.lock()
        defer { publicationLock.unlock() }
        return try body()
    }

    init(sendLine: @escaping SendLine,
         sendLineConfirmed: SendLine? = nil,
         onNotification: @escaping NotificationHandler = { _ in },
         approvalContext: CodexAppServerApprovalContext? = nil,
         approvalStore: CodexAppServerApprovalPromptStore = CodexAppServerApprovalPromptStore(),
         nextSequence: @escaping SequenceProvider = { _ in 0 },
         timestampProvider: @escaping TimestampProvider = { CodexAppServerConnection.iso8601Now() },
         onInteractivePrompt: @escaping InteractivePromptHandler = { _ in },
         onInteractivePromptResolved: @escaping InteractivePromptResolvedHandler = { _ in },
         onProtocolViolation: @escaping () -> Void = {}) {
        self.sendLine = sendLine
        self.sendLineConfirmed = sendLineConfirmed
        self.onNotification = onNotification
        self.approvalContext = approvalContext
        self.approvalStore = approvalStore
        self.nextSequence = nextSequence
        self.timestampProvider = timestampProvider
        self.onInteractivePrompt = onInteractivePrompt
        self.onInteractivePromptResolved = onInteractivePromptResolved
        self.onProtocolViolation = onProtocolViolation
    }

    @discardableResult
    func sendClientRequest(method: String,
                           params: [String: JSONValue] = [:],
                           onResponse: @escaping ClientResponseHandler) throws -> Int {
        stateLock.lock()
        guard !closed else {
            stateLock.unlock()
            throw CodexAppServerConnectionError.closed
        }
        let id = nextRequestID
        nextRequestID += 1
        pendingClientResponses[String(id)] = onResponse
        stateLock.unlock()

        do {
            try sendUnlocked(.object([
                "id": .number(Double(id)),
                "method": .string(method),
                "params": .object(params),
            ]))
        } catch {
            stateLock.lock()
            pendingClientResponses.removeValue(forKey: String(id))
            stateLock.unlock()
            throw error
        }
        return id
    }

    func sendClientNotification(method: String,
                                params: [String: JSONValue]? = nil) throws {
        var payload: [String: JSONValue] = [
            "method": .string(method),
        ]
        if let params {
            payload["params"] = .object(params)
        }
        try sendIfOpen(.object(payload))
    }

    func receiveLine(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }
        guard let data = trimmed.data(using: .utf8),
              let message = try? JSONDecoder().decode(JSONValue.self, from: data),
              let object = message.objectValue else {
            BridgeLogger.server.error("codex app-server ignored non-json stdout line=\(line, privacy: .public)")
            return
        }

        let id = object["id"]
        let method = object["method"]?.stringValue
        if let id, let method {
            // Server request ids are string | int64; re-parse the raw line so
            // "1" vs 1 stay distinct and int64 survives round-trip.
            let rawObject = Self.rawJSONObject(from: trimmed)
            guard let typedID = CodexAppServerRequestID(rawJSONObjectValue: rawObject?["id"])
                    ?? CodexAppServerRequestID(jsonValue: id) else {
                BridgeLogger.server.error("codex app-server server request with unsupported id shape method=\(method, privacy: .public)")
                return
            }
            if CodexAppServerApprovalMethod(rawValue: method) != nil {
                BridgeLogger.server.info("codex app-server server request received method=\(method, privacy: .public) id=\(typedID.storageKey, privacy: .public)")
            } else {
                BridgeLogger.server.debug("codex app-server server request received method=\(method, privacy: .public) id=\(typedID.storageKey, privacy: .public)")
            }
            handleServerRequest(id: typedID,
                                method: method,
                                params: object["params"]?.objectValue ?? [:],
                                rawParamsCanonical: CodexAppServerApprovalRequest.canonicalRawParamsFragment(rawObject: rawObject))
            return
        }
        if let id {
            handleClientResponse(id: id, result: object["result"], error: object["error"])
            return
        }
        if let method {
            let params = object["params"]?.objectValue ?? [:]
            let rawObject = method == "serverRequest/resolved" ? Self.rawJSONObject(from: trimmed) : nil
            handleApprovalLifecycleNotification(method: method, params: params, rawObject: rawObject)
            onNotification(CodexAppServerNotification(method: method,
                                                      params: params))
        }
    }

    private static func rawJSONObject(from line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }

    private func isClosedNow() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return closed
    }

    func close(error: CodexAppServerConnectionError? = nil) {
        let pending: [String: ClientResponseHandler]
        stateLock.lock()
        guard !closed else {
            stateLock.unlock()
            return
        }
        closed = true
        let failure = error ?? .closed
        pending = pendingClientResponses
        pendingClientResponses.removeAll()
        stateLock.unlock()
        // Test-only observation point: the closed flag is set but the store
        // is not yet retired. The admission gate inside the publication
        // domain (handleApprovalRequest checks `closed`) keeps this window
        // safe: a redelivery landing here is rejected, not re-admitted.
        publicationInteriorHook?("closed-preretire")
        // Retire the approval store and publish the terminals BEFORE any
        // arbitrary pending-response handler runs: a blocked handler must not
        // leave a window in which the closed connection still admits server
        // requests or re-creates pending prompts.
        expirePendingApprovals()
        for handler in pending.values {
            handler(.failure(failure))
        }
    }

    private func expirePendingApprovals() {
        guard approvalContext != nil else {
            return
        }
        withPublicationLock {
            let records = approvalStore.retireAndResolveAll(reason: "expired") { entry, reason, attempt in
                makeResolvedEvent(prompt: entry.prompt, request: entry.request, reason: reason, attempt: attempt)
            }
            publicationInteriorHook?("retired")
            for record in records {
                BridgeLogger.server.info("codex app-server approval prompt expired prompt_id=\(record.entry.prompt.promptID, privacy: .public) reason=connection_closed")
            }
            publishTerminalRecords(records)
        }
    }

    func pendingApprovalPromptEvents() -> [AgentEvent] {
        approvalStore.pendingStates().compactMap { state in
            // Snapshots must reuse the exact published event (identity, seq,
            // timestamp): allocating a fresh sequence here would inject an
            // unretained seq into fetch/replay and collide with the next
            // real event. Only the dynamic submit metadata is overlaid.
            guard let publishedEvent = state.publishedEvent else {
                return nil
            }
            var extraMetadata: [String: String] = [:]
            switch state.phase {
            case .pending:
                extraMetadata["submit_state"] = "pending"
            case .submitting(let attempt):
                extraMetadata["submit_state"] = "submitting"
                if let clientRequestID = attempt.clientRequestID {
                    extraMetadata["client_request_id"] = clientRequestID
                }
            }
            return Self.overlayMetadata(publishedEvent, extraMetadata: extraMetadata)
        }
    }

    private static func overlayMetadata(_ event: AgentEvent, extraMetadata: [String: String]) -> AgentEvent {
        var metadata = event.metadata ?? [:]
        metadata.merge(extraMetadata) { _, override in override }
        return AgentEvent(eventID: event.eventID,
                          seq: event.seq,
                          vendor: event.vendor,
                          workspaceID: event.workspaceID,
                          sessionID: event.sessionID,
                          timestamp: event.timestamp,
                          type: event.type,
                          role: event.role,
                          text: event.text,
                          name: event.name,
                          input: event.input,
                          output: event.output,
                          toolCallID: event.toolCallID,
                          metadata: metadata,
                          payload: event.payload)
    }

    func handleServerRequest(id: CodexAppServerRequestID,
                             method: String,
                             params: [String: JSONValue],
                             rawParamsCanonical: String? = nil) {
        if let request = CodexAppServerApprovalRequest(method: method,
                                                       requestID: id,
                                                       params: params,
                                                       rawParamsCanonical: rawParamsCanonical) {
            handleApprovalRequest(request)
            return
        }
        // Malformed supported approvals and unsupported methods live in the
        // SAME RequestId collision domain as valid approvals: no frame —
        // success OR error — may be written for an id whose response is
        // already on the wire for different content.
        let code: Int
        let message: String
        if CodexAppServerApprovalMethod(rawValue: method) != nil {
            code = -32602
            message = "Invalid Codex approval request: \(method)"
        } else {
            code = -32601
            message = "Unsupported server request: \(method)"
        }
        withPublicationLock {
            // Closed-admission gate covers ALL server requests: after close()
            // marked the connection closed, a malformed/unsupported request
            // may not claim the ledger, terminalize a lifecycle, publish, or
            // write any frame. Only close's own expired terminals remain.
            if isClosedNow() {
                BridgeLogger.server.info("codex app-server non-approval request ignored on closed connection request_id=\(id.storageKey, privacy: .public) method=\(method, privacy: .public)")
                return
            }
            let fingerprint = "non-approval:\(method)\n" + (rawParamsCanonical ?? Self.serverRequestFingerprint(method: method, params: params))
            switch approvalStore.claimServerErrorResponse(requestIDKey: id.storageKey,
                                                          fingerprint: fingerprint,
                                                          makeTerminalEvent: { entry, reason, attempt in
                                                              self.makeResolvedEvent(prompt: entry.prompt,
                                                                                     request: entry.request,
                                                                                     reason: reason,
                                                                                     attempt: attempt)
                                                          }) {
            case .allowed(let terminals):
                publishTerminalRecords(terminals)
                sendError(id: id, code: code, message: message)
            case .rejectedPoisoned(let terminals, let isNewViolation):
                publishTerminalRecords(terminals)
                if isNewViolation {
                    BridgeLogger.server.error("codex app-server JSON-RPC protocol violation: non-approval request reused a RequestId with a response on the wire; aborting connection request_id=\(id.storageKey, privacy: .public) method=\(method, privacy: .public)")
                    onProtocolViolation()
                }
            }
        }
    }

    private static func serverRequestFingerprint(method: String, params: [String: JSONValue]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let payload = JSONValue.object(["non_approval_method": .string(method), "params": .object(params)])
        let data = (try? encoder.encode(payload)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    // A successful transport flush is NOT a resolution: the entry stays in
    // submitting phase until the app-server confirms via serverRequest/resolved
    // (or a turn/expiry terminal), which is the only path that publishes the
    // single terminal event for a request identity.
    @discardableResult
    func submitApproval(promptID: String,
                        targetIndex: Int,
                        clientRequestID: String? = nil,
                        lifecycleToken: String? = nil) throws -> CodexAppServerApprovalSubmitOutcome {
        submitAdmissionHook?()
        switch approvalStore.beginSubmit(promptID: promptID,
                                         targetIndex: targetIndex,
                                         clientRequestID: clientRequestID,
                                         lifecycleToken: lifecycleToken) {
        case .terminal(let record):
            return .alreadyResolved(record.event)
        case .unknown:
            throw BridgeInternalError.notFound("Unknown Codex approval prompt.")
        case .duplicateInFlight:
            return .pendingConfirmation(promptID: promptID)
        case .inFlightConflict:
            throw BridgeInternalError.conflict("Codex approval submit is already in flight.")
        case .optionConflict:
            throw BridgeInternalError.conflict("A different decision was already submitted for this approval.")
        case .lifecycleTokenMismatch:
            // A card from an older delivery (or a changed payload) presented
            // a stale lifecycle capability: zero bytes may be written for it.
            throw BridgeInternalError.conflict("The approval card is from an older delivery of this request; refresh and decide again.")
        case .begin(let entry, let response, let lifecycleAttempt):
            // Wire gate: no bytes may be written unless this lifecycle
            // attempt is still current at write-begin time. A changed-payload
            // redelivery that lands before this point supersedes the
            // lifecycle and the check fails — the stale response never
            // reaches the wire.
            guard approvalStore.beginWire(promptID: promptID, lifecycleAttempt: lifecycleAttempt) else {
                if let terminal = approvalStore.terminalRecord(promptID: promptID) {
                    return .alreadyResolved(terminal.event)
                }
                throw BridgeInternalError.conflict("Codex approval lifecycle changed before the response could be sent.")
            }
            do {
                try sendResponseLine(id: entry.request.requestID,
                                     bodyKey: "result",
                                     value: response,
                                     preferConfirmed: true)
            } catch {
                switch approvalStore.failSubmit(promptID: promptID, lifecycleAttempt: lifecycleAttempt) {
                case .terminal(let record):
                    return .alreadyResolved(record.event)
                case .awaitingConfirmation, .supersededLifecycle:
                    throw error
                }
            }
            approvalStore.endWireFlushed(promptID: promptID, lifecycleAttempt: lifecycleAttempt)
            switch approvalStore.completeSubmitFlush(promptID: promptID, lifecycleAttempt: lifecycleAttempt) {
            case .terminal(let record):
                // The authoritative resolution raced ahead of the flush;
                // return that same terminal record instead of synthesizing a
                // local one.
                return .alreadyResolved(record.event)
            case .awaitingConfirmation:
                return .pendingConfirmation(promptID: promptID)
            case .supersededLifecycle:
                // Only an identical-payload reactivation can replace the
                // lifecycle while our response was in the wire (changed
                // payloads are rejected during the write); the flushed
                // response matches the identical content, so awaiting the
                // authoritative confirmation stays correct.
                return .pendingConfirmation(promptID: promptID)
            }
        }
    }

    private func handleApprovalLifecycleNotification(method: String,
                                                     params: [String: JSONValue],
                                                     rawObject: [String: Any]?) {
        withPublicationLock {
        switch method {
        case "serverRequest/resolved":
            guard let threadID = Self.notificationThreadID(from: params) else {
                return
            }
            let requestID = CodexAppServerRequestID(rawJSONObjectValue: (rawObject?["params"] as? [String: Any])?["requestId"])
                ?? CodexAppServerRequestID(jsonValue: params["requestId"])
            guard let requestIDKey = requestID?.storageKey else {
                return
            }
            let records = approvalStore.resolveExternally(reason: "server_resolved",
                                                          where: { request in
                                                              request.threadID == threadID && request.requestIDKey == requestIDKey
                                                          },
                                                          makeEvent: { entry, reason, attempt in
                                                              self.makeResolvedEvent(prompt: entry.prompt,
                                                                                     request: entry.request,
                                                                                     reason: reason,
                                                                                     attempt: attempt)
                                                          })
            publishTerminalRecords(records)
        case "turn/completed", "turn/aborted":
            guard let threadID = Self.notificationThreadID(from: params),
                  let turnID = Self.notificationTurnID(from: params) else {
                return
            }
            let records = approvalStore.resolveExternally(reason: "turn_completed",
                                                          where: { request in
                                                              request.threadID == threadID && request.turnID == turnID
                                                          },
                                                          makeEvent: { entry, reason, attempt in
                                                              self.makeResolvedEvent(prompt: entry.prompt,
                                                                                     request: entry.request,
                                                                                     reason: reason,
                                                                                     attempt: attempt)
                                                          })
            publishTerminalRecords(records)
        default:
            break
        }
        }
    }

    private func publishTerminalRecords(_ records: [CodexAppServerApprovalTerminalRecord]) {
        for record in records {
            BridgeLogger.server.info("codex app-server approval prompt resolved prompt_id=\(record.entry.prompt.promptID, privacy: .public) reason=\(record.reason, privacy: .public)")
            onInteractivePromptResolved(record.event)
        }
    }

    private static func notificationThreadID(from params: [String: JSONValue]) -> String? {
        params["threadId"]?.stringValue
            ?? params["thread"]?.objectValue?["id"]?.stringValue
    }

    private static func notificationTurnID(from params: [String: JSONValue]) -> String? {
        params["turnId"]?.stringValue
            ?? params["turn"]?.objectValue?["id"]?.stringValue
    }

    func sendError(id: CodexAppServerRequestID, code: Int, message: String, data: JSONValue? = nil) {
        var error: [String: JSONValue] = [
            "code": .number(Double(code)),
            "message": .string(message),
        ]
        if let data {
            error["data"] = data
        }
        try? sendResponseLine(id: id, bodyKey: "error", value: .object(error), preferConfirmed: false)
    }

    // Builds the response line by splicing the exact id token so string ids
    // stay quoted and int64 ids keep their full precision (JSONValue's
    // Double-backed numbers cannot represent all int64 values).
    private func sendResponseLine(id: CodexAppServerRequestID,
                                  bodyKey: String,
                                  value: JSONValue,
                                  preferConfirmed: Bool) throws {
        stateLock.lock()
        let isClosed = closed
        stateLock.unlock()
        guard isClosed == false else {
            throw CodexAppServerConnectionError.closed
        }
        let data = try JSONEncoder().encode(value)
        let bodyJSON = String(decoding: data, as: UTF8.self)
        let line = "{\"id\":\(id.jsonToken),\"\(bodyKey)\":\(bodyJSON)}"
        if preferConfirmed, let sendLineConfirmed {
            try sendLineConfirmed(line + "\n")
            return
        }
        try sendLine(line + "\n")
    }

    private func handleClientResponse(id: JSONValue, result: JSONValue?, error: JSONValue?) {
        guard let key = Self.idKey(from: id) else {
            return
        }
        stateLock.lock()
        let handler = pendingClientResponses.removeValue(forKey: key)
        stateLock.unlock()
        guard let handler else {
            return
        }
        if let errorObject = error?.objectValue {
            let code = errorObject["code"]?.intValue ?? -32000
            let message = errorObject["message"]?.stringValue ?? "Codex app-server request failed."
            handler(.failure(.requestFailed(CodexAppServerJSONRPCError(code: code,
                                                                        message: message,
                                                                        data: errorObject["data"]))))
            return
        }
        handler(.success(result ?? .object([:])))
    }

    private func sendIfOpen(_ value: JSONValue, preferConfirmed: Bool = false) throws {
        stateLock.lock()
        let isClosed = closed
        stateLock.unlock()
        guard isClosed == false else {
            throw CodexAppServerConnectionError.closed
        }
        try sendUnlocked(value, preferConfirmed: preferConfirmed)
    }

    private func sendUnlocked(_ value: JSONValue, preferConfirmed: Bool = false) throws {
        let data = try JSONEncoder().encode(value)
        guard let line = String(data: data, encoding: .utf8) else {
            throw CodexAppServerConnectionError.invalidJSONLine("<encoding failed>")
        }
        if preferConfirmed, let sendLineConfirmed {
            try sendLineConfirmed(line + "\n")
            return
        }
        try sendLine(line + "\n")
    }

    static func idKey(from id: JSONValue) -> String? {
        switch id {
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

    private func handleApprovalRequest(_ request: CodexAppServerApprovalRequest) {
        guard let approvalContext else {
            sendError(id: request.requestID,
                      code: -32000,
                      message: "Codex approval context is unavailable.")
            return
        }
        // Admission, event recording, and the external publication happen
        // under the publication lock: close/lifecycle terminals serialize
        // against this whole block, so a pending prompt can never be
        // published after its generation's terminal.
        withPublicationLock {
        // Closed-admission gate inside the publication domain: once close()
        // marked the connection closed, no server request may be admitted —
        // even in the window before the store retire runs.
        if isClosedNow() {
            // No side effects and no bytes: a closed connection writes
            // nothing, not even a best-effort error frame.
            BridgeLogger.server.info("codex app-server approval request rejected on closed connection request_id=\(request.requestIDKey, privacy: .public)")
            return
        }
        let prompt = request.makePrompt(epoch: approvalContext.epoch)
        let entry = CodexAppServerApprovalPromptEntry(request: request, prompt: prompt)
        // A re-delivered request is authoritative: whatever we may have
        // flushed before was not accepted, so the prompt goes back to being
        // actionable. Terminal records for the same identity are superseded.
        let outcome = approvalStore.register(entry: entry) { entry, reason, attempt in
            self.makeResolvedEvent(prompt: entry.prompt,
                                   request: entry.request,
                                   reason: reason,
                                   attempt: attempt)
        }
        publicationInteriorHook?("registered")
        let attempt: Int
        // Round 7C P0-E: a superseded-payload-changed replacement must never
        // publish the OLD terminal before the NEW opener — that ordering
        // leaves a real window (between these two Hub `publish()` calls)
        // where the active-prompt map is EMPTY: the old prompt just closed,
        // the new one hasn't opened yet. A concurrent transcript
        // continuation landing in that exact window would be wrongly
        // accepted as unsuppressed (no active prompt), showing Working ON
        // right before a new approval card appears. The fix: DEFER the old
        // terminal's publish until AFTER the replacement opener is
        // published (via onInteractivePrompt, below) — its EXACT old token
        // means it can only ever close ITS OWN (now-superseded) opener
        // entry, never the new one, per the existing promptID+
        // lifecycleToken terminalCloses contract. The active-prompt map is
        // therefore never empty across this transition. The poisoned/
        // rejected-retired paths above are unaffected — they have no
        // replacement to order against, so they still publish immediately.
        var deferredSupersededTerminal: CodexAppServerApprovalTerminalRecord?
        switch outcome {
        case .rejectedRetired:
            // The generation is closing: no new prompt may be admitted or
            // published; the reply is best-effort on a dying transport.
            BridgeLogger.server.info("codex app-server approval request rejected on retired connection prompt_id=\(prompt.promptID, privacy: .public)")
            sendError(id: request.requestID,
                      code: -32000,
                      message: "Codex app-server connection is closed.")
            return
        case .rejectedPoisonedRequestID(let terminals, let isNewViolation):
            // Protocol violation: a response for different content may
            // already be on the wire under this JSON-RPC id. No prompt, and
            // — critically — no further response bytes (success OR error)
            // with this id, ever, on this connection. The transport is
            // aborted; the id stays poisoned so later redeliveries cannot be
            // resurrected by the generic terminal branch.
            publishTerminalRecords(terminals)
            if isNewViolation {
                BridgeLogger.server.error("codex app-server JSON-RPC protocol violation: request content changed while a response was on the wire; aborting connection request_id=\(request.requestIDKey, privacy: .public)")
                onProtocolViolation()
            }
            return
        case .recorded(_, let recordedAttempt):
            attempt = recordedAttempt
            BridgeLogger.server.info("codex app-server approval prompt publishing method=\(request.method.rawValue, privacy: .public) prompt_id=\(prompt.promptID, privacy: .public) source=\(prompt.source, privacy: .public)")
        case .reactivated(_, let reactivatedAttempt):
            attempt = reactivatedAttempt
            BridgeLogger.server.info("codex app-server approval prompt redelivered method=\(request.method.rawValue, privacy: .public) prompt_id=\(prompt.promptID, privacy: .public)")
        case .supersededPayloadChanged(let terminal, _, let supersededAttempt):
            attempt = supersededAttempt
            BridgeLogger.server.error("codex app-server approval payload changed under same request identity; old lifecycle terminated prompt_id=\(prompt.promptID, privacy: .public)")
            deferredSupersededTerminal = terminal
        }
        let event = makePromptEvent(prompt: prompt, request: request, attempt: attempt)
        approvalStore.recordPublishedPromptEvent(promptID: prompt.promptID, event: event)
        publicationInteriorHook?("recorded")
        onInteractivePrompt(CodexAppServerInteractivePromptEnvelope(request: request,
                                                                    prompt: prompt,
                                                                    event: event))
        if let deferredSupersededTerminal {
            publishTerminalRecords([deferredSupersededTerminal])
        }
        }
    }

    private func makePromptEvent(prompt: InteractivePrompt,
                                 request: CodexAppServerApprovalRequest?,
                                 attempt: Int,
                                 extraMetadata: [String: String] = [:]) -> AgentEvent {
        guard let approvalContext else {
            preconditionFailure("approvalContext must exist before creating prompt events")
        }
        var metadata = [
            "panel_id": approvalContext.panelID,
            "source": prompt.source,
            "prompt_id": prompt.promptID,
            "attempt": String(attempt),
            "connection_generation": generationID,
            "app_server_epoch": approvalContext.epoch,
        ]
        if let submitChannel = prompt.submitChannel {
            metadata["submit_channel"] = submitChannel
        }
        applyRequestIdentity(request, to: &metadata)
        metadata.merge(extraMetadata) { _, override in override }
        // The delivery token keeps event identity unique per lifecycle
        // attempt (and per connection), so the event hub's eventID dedupe
        // cannot swallow a re-delivered prompt; the logical prompt identity
        // stays in metadata.prompt_id.
        let eventID = "codex-app-server-prompt:\(prompt.promptID):\(deliveryToken(attempt: attempt))"
        // The event id doubles as the server-issued lifecycle capability the
        // client must echo on submit; it is carried inside the prompt payload
        // so the card itself holds it.
        var payload = prompt.jsonValue.objectValue ?? [:]
        payload["lifecycle_token"] = .string(eventID)
        return AgentEvent(eventID: eventID,
                          seq: nextSequence(approvalContext.sessionID),
                          vendor: "codex",
                          workspaceID: approvalContext.workspaceID,
                          sessionID: approvalContext.sessionID,
                          timestamp: timestampProvider(),
                          type: .interactivePrompt,
                          role: nil,
                          text: prompt.title,
                          name: nil,
                          input: nil,
                          output: nil,
                          toolCallID: nil,
                          metadata: metadata,
                          payload: .object(payload))
    }

    private func makeResolvedEvent(prompt: InteractivePrompt,
                                   request: CodexAppServerApprovalRequest?,
                                   reason: String,
                                   attempt: Int) -> AgentEvent {
        guard let approvalContext else {
            preconditionFailure("approvalContext must exist before creating resolved events")
        }
        // The terminal identifies WHICH delivery it terminates: the exact
        // lifecycle capability the prompt event of this attempt carried.
        let lifecycleToken = "codex-app-server-prompt:\(prompt.promptID):\(deliveryToken(attempt: attempt))"
        var metadata = [
            "panel_id": approvalContext.panelID,
            "source": prompt.source,
            "prompt_id": prompt.promptID,
            "reason": reason,
            "attempt": String(attempt),
            "connection_generation": generationID,
            "app_server_epoch": approvalContext.epoch,
            "lifecycle_token": lifecycleToken,
        ]
        if let submitChannel = prompt.submitChannel {
            metadata["submit_channel"] = submitChannel
        }
        applyRequestIdentity(request, to: &metadata)
        var resolvedPayload = prompt.jsonValue.objectValue ?? [:]
        resolvedPayload["lifecycle_token"] = .string(lifecycleToken)
        return AgentEvent(eventID: "codex-app-server-prompt-resolved:\(prompt.promptID):\(reason):\(deliveryToken(attempt: attempt))",
                          seq: nextSequence(approvalContext.sessionID),
                          vendor: "codex",
                          workspaceID: approvalContext.workspaceID,
                          sessionID: approvalContext.sessionID,
                          timestamp: timestampProvider(),
                          type: .interactivePromptResolved,
                          role: nil,
                          text: prompt.title,
                          name: nil,
                          input: nil,
                          output: nil,
                          toolCallID: nil,
                          metadata: metadata,
                          payload: .object(resolvedPayload))
    }

    private static func iso8601Now() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }

    private func deliveryToken(attempt: Int) -> String {
        // Full connection generation: no truncated-UUID collision space.
        "g\(generationID)a\(attempt)"
    }

    private func applyRequestIdentity(_ request: CodexAppServerApprovalRequest?,
                                      to metadata: inout [String: String]) {
        guard let request else {
            return
        }
        metadata["thread_id"] = request.threadID
        metadata["turn_id"] = request.turnID
        metadata["item_id"] = request.itemID
        metadata["request_id"] = request.requestIDKey
    }
}
