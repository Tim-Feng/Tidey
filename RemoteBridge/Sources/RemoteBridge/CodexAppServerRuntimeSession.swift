import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOWebSocket

enum CodexAppServerProcessError: Error {
    case closed
    case invalidUTF8
}

// A successful turn/steer response that names another turn has an unknown
// semantic destination. It is not a definite rejection and must not retry.
struct CodexAppServerTurnIDMismatchError: Error, Equatable {
    let expectedTurnID: String
    let observedTurnID: String?
}

// A successful turn/start response without a usable turn identity may have
// accepted the message, but cannot be reconciled safely.
struct CodexAppServerInvalidTurnStartResponseError: Error, Equatable {
    let observedTurnID: String?
}

protocol CodexAppServerManagedProcess: AnyObject {
    var processID: Int32? { get }
    func sendLine(_ line: String) throws
    func terminate()
}

protocol CodexAppServerProcessRunning {
    func start(configuration: CodexAppServerLaunchConfiguration,
               onStdoutLine: @escaping @Sendable (String) -> Void,
               onStderrLine: @escaping @Sendable (String) -> Void,
               onExit: @escaping @Sendable (Int32) -> Void) throws -> CodexAppServerManagedProcess
}

enum CodexAppServerTransportError: Error {
    case unsupported(CodexAppServerTransportMode)
    case closed
    case invalidUTF8
}

protocol CodexAppServerConnectionTransport: AnyObject {
    func sendLine(_ line: String) throws
    func close()
}

protocol CodexAppServerTransportConnecting {
    func connect(mode: CodexAppServerTransportMode,
                 onLine: @escaping @Sendable (String) -> Void,
                 onClose: @escaping @Sendable (Error?) -> Void) throws -> CodexAppServerConnectionTransport
}

final class CodexAppServerRuntimeSession {
    private static let subscriptionRetryBackoff: TimeInterval = 1.0

    private let process: CodexAppServerManagedProcess
    private let processOwnership: CodexAppServerProcessOwnership
    private let transport: CodexAppServerConnectionTransport
    private let connection: CodexAppServerConnection
    private let runtime: CodexAppServerHeadlessRuntime
    private let initialization: CodexAppServerInitializationState
    private let activeThreadStore: CodexAppServerActiveThreadStore
    private let turnStateStore: CodexAppServerTurnStateStore
    private let lifecycleFeed: CodexLifecycleFeed?
    private let callbackQueue: DispatchQueue
    private let lock = NSLock()
    private var stopped = false
    private var attachSubscriptionState = AttachSubscriptionState.noLoadedThread
    private var nextSubscriptionRetryAt: Date?
    private var registryRootThreadID: String?
    var loadedThreadUnresolvedHook: (() -> Void)?

    var attachSubscriptionStateForTesting: String {
        lock.lock()
        defer { lock.unlock() }
        return attachSubscriptionState.logValue
    }

    enum AttachSubscriptionState: Equatable {
        case noLoadedThread
        case resumePending
        case subscribed(threadID: String)
        case failed(String)

        var logValue: String {
            switch self {
            case .noLoadedThread:
                return "no_loaded_thread"
            case .resumePending:
                return "resume_pending"
            case .subscribed(let threadID):
                return "subscribed:\(threadID)"
            case .failed(let reason):
                return "failed:\(reason)"
            }
        }

        var shouldRetry: Bool {
            switch self {
            case .noLoadedThread, .failed:
                return true
            case .resumePending, .subscribed:
                return false
            }
        }
    }

    init(process: CodexAppServerManagedProcess,
         processOwnership: CodexAppServerProcessOwnership,
         transport: CodexAppServerConnectionTransport,
         connection: CodexAppServerConnection,
         runtime: CodexAppServerHeadlessRuntime,
         initialization: CodexAppServerInitializationState = CodexAppServerInitializationState(),
         activeThreadStore: CodexAppServerActiveThreadStore = CodexAppServerActiveThreadStore(),
         turnStateStore: CodexAppServerTurnStateStore = CodexAppServerTurnStateStore(),
         lifecycleFeed: CodexLifecycleFeed? = nil,
         callbackQueue: DispatchQueue = DispatchQueue(label: "com.tidey.remote-bridge.codex-app-server-runtime-session")) {
        self.process = process
        self.processOwnership = processOwnership
        self.transport = transport
        self.connection = connection
        self.runtime = runtime
        self.initialization = initialization
        self.activeThreadStore = activeThreadStore
        self.turnStateStore = turnStateStore
        self.lifecycleFeed = lifecycleFeed
        self.callbackQueue = callbackQueue
    }

    var processID: Int32? {
        process.processID
    }

    @discardableResult
    func startThread(cwd: String?,
                     model: String? = nil,
                     approvalPolicy: String? = nil,
                     sandbox: JSONValue? = nil,
                     ephemeral: Bool = true,
                     onResponse: @escaping CodexAppServerConnection.ClientResponseHandler = { _ in }) throws -> Int {
        try initialization.wait()
        return try runtime.startThread(on: connection,
                                       cwd: cwd,
                                       model: model,
                                       approvalPolicy: approvalPolicy,
                                       sandbox: sandbox,
                                       ephemeral: ephemeral,
                                       onResponse: onResponse)
    }

    @discardableResult
    func listLoadedThreads(onResponse: @escaping CodexAppServerConnection.ClientResponseHandler = { _ in }) throws -> Int {
        try initialization.wait()
        return try runtime.listLoadedThreads(on: connection,
                                             onResponse: onResponse)
    }

    @discardableResult
    func resumeThread(threadID: String,
                      cwd: String?,
                      onResponse: @escaping CodexAppServerConnection.ClientResponseHandler = { _ in }) throws -> Int {
        try initialization.wait()
        // Order fence captured BEFORE the request goes out: a status
        // notification accepted after this point invalidates the (older)
        // response snapshot.
        let snapshotBarrier = lifecycleFeed?.snapshotBarrier()
        // Separate order fence for the turn-state store: snapshotBarrier
        // above only protects the LIFECYCLE store (thread status/blockers),
        // not CodexAppServerTurnStateStore's active-turn seeding below.
        let turnStateBarrier = turnStateStore.revisionBarrier(threadID: threadID)
        return try runtime.resumeThread(on: connection,
                                        threadID: threadID,
                                        cwd: cwd,
                                        onResponse: { [weak self] response in
                                            if case .success(let payload) = response {
                                                self?.lifecycleFeed?.applySnapshotResult(payload,
                                                                                         threadID: threadID,
                                                                                         barrier: snapshotBarrier)
                                                self?.seedActiveTurnFromResumeSnapshot(payload,
                                                                                       threadID: threadID,
                                                                                       barrier: turnStateBarrier)
                                            }
                                            onResponse(response)
                                        })
    }

    // Seeds the store's active-turn state from a thread/resume response's
    // `result.thread.turns` — this is the ONLY way a Bridge attach/re-attach
    // (especially immediately after a Bridge deploy or a new app-server
    // PID) can learn the exact turn id of an ALREADY-RUNNING turn: nothing
    // guarantees a historical turn/started notification will ever arrive
    // for a turn that started before this connection existed. Without this,
    // routeSubmit() can only see threadStatusActiveStartedAt (busy, no known
    // turn id) and permanently returns .busyWithoutTurnID until the turn
    // happens to complete — remote steer is unusable for the entire
    // duration of that turn.
    //
    // Deliberately narrow: only seeds when the snapshot is UNAMBIGUOUS
    // (response thread.id matches the requested thread, and exactly one
    // turn has a nonblank id with status == "inProgress") and only when
    // `barrier` proves nothing has mutated this thread's turn state since
    // the request was sent (see CodexAppServerTurnStateStore's revision
    // fence) — a stale response racing a live completion, a newer
    // turn/started, or a remote submit's own claim must never
    // resurrect/overwrite that newer state. Any other shape (zero or
    // multiple in-progress turns, thread id mismatch, or a state that has
    // advanced) is silently skipped: the existing safe busyWithoutTurnID
    // fallback still applies — never guess, never terminal-fallback.
    private func seedActiveTurnFromResumeSnapshot(_ payload: JSONValue, threadID: String, barrier: Int) {
        guard let thread = payload.objectValue?["thread"]?.objectValue,
              thread["id"]?.stringValue == threadID else {
            return
        }
        let turns = thread["turns"]?.arrayValue ?? []
        let inProgressTurnIDs = turns.compactMap { turn -> String? in
            guard let object = turn.objectValue,
                  object["status"]?.stringValue == "inProgress" else {
                return nil
            }
            let turnID = object["id"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let turnID, !turnID.isEmpty else {
                return nil
            }
            return turnID
        }
        if inProgressTurnIDs.count == 1, let turnID = inProgressTurnIDs.first {
            turnStateStore.seedActiveTurnFromResumeIfUnchanged(threadID: threadID, turnID: turnID, barrier: barrier)
            return
        }
        // Zero or ambiguous inProgress turns: never guess which one to
        // steer into. But if the snapshot's own thread.status still says
        // the thread IS active/busy, the thread-state store must still
        // learn that — otherwise routeSubmit() would wrongly treat this
        // thread as IDLE (no pending claim, no turn, no active status) and
        // issue a colliding turn/start into a thread the app-server already
        // considers busy. Reuses the SAME status classifier the live
        // thread/status/changed notification path uses, so "active" here
        // means exactly what it means there.
        guard let status = thread["status"]?.objectValue,
              let statusType = status["type"]?.stringValue,
              let level = CodexThreadStatusLifecycle.providerLevel(statusType: statusType,
                                                                   activeFlags: status["activeFlags"]?.arrayValue
                                                                       .map { $0.compactMap(\.stringValue) }),
              level.turnActive else {
            return
        }
        turnStateStore.markThreadActiveIfUnchanged(threadID: threadID, barrier: barrier)
    }

    @discardableResult
    func startTurn(threadID: String,
                   text: String,
                   cwd: String? = nil,
                   approvalPolicy: String? = nil,
                   sandboxPolicy: JSONValue? = nil,
                   onResponse: @escaping CodexAppServerConnection.ClientResponseHandler = { _ in }) throws -> Int {
        try initialization.wait()
        return try runtime.startTurn(on: connection,
                                     threadID: threadID,
                                     text: text,
                                     cwd: cwd,
                                     approvalPolicy: approvalPolicy,
                                     sandboxPolicy: sandboxPolicy,
                                     onResponse: onResponse)
    }

    @discardableResult
    func submitApproval(promptID: String, targetIndex: Int) throws -> AgentEvent {
        try connection.submitApproval(promptID: promptID, targetIndex: targetIndex)
    }

    @discardableResult
    func submitApproval(promptID: String,
                        targetIndex: Int,
                        clientRequestID: String?,
                        lifecycleToken: String?) throws -> CodexAppServerApprovalSubmitOutcome {
        try connection.submitApproval(promptID: promptID,
                                      targetIndex: targetIndex,
                                      clientRequestID: clientRequestID,
                                      lifecycleToken: lifecycleToken)
    }

    @discardableResult
    func submitUserInput(promptID: String,
                         answers: [String: [String]],
                         clientRequestID: String?,
                         lifecycleToken: String?) throws -> CodexAppServerApprovalSubmitOutcome {
        try connection.submitUserInput(promptID: promptID,
                                       answers: answers,
                                       clientRequestID: clientRequestID,
                                       lifecycleToken: lifecycleToken)
    }

    func pendingApprovalPromptEvents() -> [AgentEvent] {
        connection.pendingApprovalPromptEvents()
    }

    private static let submitResponseTimeout: TimeInterval = 10

    // The v2 protocol returns turn/start as { "turn": { "id": ... } }.
    // turn/steer's top-level turnId is a different response shape and is
    // validated separately below; accepting it here would hide a protocol
    // mix-up like the production false-error regression from 2026-07-21.
    private static func startResponseTurnIDCandidate(from response: JSONValue) -> String? {
        response.objectValue?["turn"]?.objectValue?["id"]?.stringValue
    }

    private static func normalizedTurnID(from response: JSONValue) -> String? {
        guard let rawTurnID = startResponseTurnIDCandidate(from: response) else {
            return nil
        }
        let turnID = rawTurnID.trimmingCharacters(in: .whitespacesAndNewlines)
        return turnID.isEmpty ? nil : turnID
    }

    func submitMessage(text: String) throws {
        try submitMessage(text: text, clientRequestID: nil)
    }

    func submitMessage(text: String, clientRequestID: String?) throws {
        // Everything up to and including thread-id resolution happens
        // strictly BEFORE any turn/start or turn/steer request frame for
        // this text is ever built — a failure here (init not ready/timed
        // out, or the pre-send thread lookup failing) cannot have touched
        // the user's message in any way. Zero effect by construction.
        do {
            try initialization.wait()
        } catch {
            throw CodexAppServerSubmitFailure.unavailableBeforeSend("Codex app-server initialization is not ready: \(error)")
        }
        let threadID: String?
        do {
            threadID = try currentThreadIDForSubmit()
        } catch {
            throw CodexAppServerSubmitFailure.unavailableBeforeSend("Codex app-server thread lookup failed: \(error)")
        }
        guard let threadID else {
            throw CodexAppServerSubmitFailure.unavailableBeforeSend("Codex app-server thread is not ready.")
        }
        // ONE atomic routing decision — never canSubmitMessage() (a
        // separate, non-atomic peek) followed by a separate claim. That
        // two-step gate-then-claim pattern is exactly the TOCTOU this
        // route replaces.
        let claimID = UUID()
        switch turnStateStore.routeSubmit(threadID: threadID, claimID: claimID) {
        case .start:
            do {
                let response = try awaitClientResponse(timeout: Self.submitResponseTimeout) { onResponse in
                    try runtime.startTurn(on: connection,
                                          threadID: threadID,
                                          text: text,
                                          clientUserMessageID: clientRequestID,
                                          onResponse: { [turnStateStore] result in
                                              // Reconcile in the durable connection callback before
                                              // waking the bounded waiter. This still runs when an
                                              // authoritative response arrives after the waiter timed out.
                                              switch result {
                                              case .success(let payload):
                                                  if let turnID = Self.normalizedTurnID(from: payload) {
                                                      turnStateStore.reconcileAcceptedStart(threadID: threadID,
                                                                                            claimID: claimID,
                                                                                            turnID: turnID)
                                                  }
                                              case .failure(.requestFailed):
                                                  turnStateStore.releasePendingSubmit(threadID: threadID,
                                                                                      claimID: claimID)
                                              default:
                                                  break
                                              }
                                              onResponse(result)
                                          })
                }
                guard Self.normalizedTurnID(from: response) != nil else {
                    throw CodexAppServerInvalidTurnStartResponseError(observedTurnID: Self.startResponseTurnIDCandidate(from: response))
                }
            } catch CodexAppServerConnectionError.requestFailed(let rpcError) {
                // A DEFINITE JSON-RPC rejection — the app-server refused
                // the turn/start outright (e.g. it raced into a newly
                // active turn). Zero semantic effect: safe to release the
                // claim so a genuine retry can proceed.
                turnStateStore.releasePendingSubmit(threadID: threadID, claimID: claimID)
                throw CodexAppServerSubmitFailure.rejected(rpcError.message)
            }
            // Every OTHER failure (synchronous write failure, transport
            // close, or a bounded-wait timeout with no authoritative
            // response) is UNKNOWN, not zero-effect — the request may still
            // land server-side. The pending claim is deliberately NOT
            // released here: releasing it would let a different
            // client_request_id issue a second turn/start while the first
            // may still be in flight. A stuck claim still self-heals via
            // the turn-state store's own timeout/expiry.
        case .steer(let turnID):
            // An ACTIVE turn with a KNOWN turn id: native turn/steer INTO
            // that turn — never a new turn/start, never terminal input.
            let response: JSONValue
            do {
                response = try awaitClientResponse(timeout: Self.submitResponseTimeout) { onResponse in
                    try runtime.steerTurn(on: connection,
                                         threadID: threadID,
                                         expectedTurnID: turnID,
                                         text: text,
                                         clientUserMessageID: clientRequestID,
                                         onResponse: onResponse)
                }
            } catch CodexAppServerConnectionError.requestFailed(let rpcError) {
                // A DEFINITE rejection — e.g. the turn completed or was
                // replaced before the steer landed, so expectedTurnId no
                // longer matches. Zero semantic effect: nothing was
                // accepted into any turn.
                throw CodexAppServerSubmitFailure.rejected(rpcError.message)
            }
            // A successful RPC whose returned turnId does not match what we
            // asked to steer into is untrustworthy — but it was still a
            // SUCCESS response, meaning the server may have accepted the
            // input into SOME turn. This is an unknown semantic
            // destination, not a definite zero-effect rejection — it must
            // be indeterminate (never cancelled/retried, never reported as
            // success), exactly like any other protocol-violation outcome.
            guard response.objectValue?["turnId"]?.stringValue == turnID else {
                throw CodexAppServerTurnIDMismatchError(expectedTurnID: turnID,
                                                        observedTurnID: response.objectValue?["turnId"]?.stringValue)
            }
            // Every OTHER failure (transport close, bounded-wait timeout)
            // is indeterminate — propagates unchanged from awaitClientResponse.
        case .busyWithoutTurnID:
            // No known turn id to steer into, and no capacity to claim a
            // new turn/start either (another submit is already pending, or
            // the app-server reports the thread active without an
            // observed turn id yet). Zero side effect — no transport
            // attempt was made — but this is NEVER safe to terminal-
            // fallback: for a codex_app_server record, "the terminal" is
            // Tidey's headless viewer, which immediately re-submits
            // whatever it reads back through ANOTHER chat_submit, and
            // falling back here would create a recursive resubmit loop.
            throw CodexAppServerSubmitFailure.busyWithoutTurnID
        }
    }

    // Bounded wait for the authoritative JSON-RPC response to a client
    // request, mirroring the existing thread/loaded/list wait in
    // loadCurrentThreadID(). `send` performs the actual sendClientRequest
    // call (or throws synchronously if the write itself fails); the
    // response handler resolves the condition either way.
    private func awaitClientResponse(timeout: TimeInterval,
                                     send: (@escaping CodexAppServerConnection.ClientResponseHandler) throws -> Void) throws -> JSONValue {
        let condition = NSCondition()
        var result: Result<JSONValue, CodexAppServerConnectionError>?
        try send { response in
            condition.lock()
            result = response
            condition.broadcast()
            condition.unlock()
        }

        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }
        while result == nil {
            if condition.wait(until: deadline) == false {
                throw CodexAppServerConnectionError.responseTimedOut
            }
        }
        return try result!.get()
    }

    // Non-authoritative availability diagnostic: false while initialization
    // is unavailable or the thread is busy. Submit callers must not use this
    // as a gate; submitMessage() makes the only atomic start/steer/busy route
    // decision and can steer when a known turn is active.
    func canSubmitMessage() -> Bool {
        let initializationStatus = initialization.diagnosticStatus()
        let threadID = activeThreadStore.currentThreadID()
        let busySummary = threadID.map { turnStateStore.diagnosticBusySummary(threadID: $0) } ?? "unknown_thread"
        let isBusy = threadID.map { turnStateStore.isBusy(threadID: $0) } ?? false
        let result: Bool
        let falseReason: String
        if case .ready = initializationStatus {
            result = threadID != nil && !isBusy
            if threadID == nil {
                falseReason = "active_thread_unknown"
            } else if isBusy {
                falseReason = "busy"
            } else {
                falseReason = "-"
            }
        } else {
            result = false
            falseReason = "initialization_\(initializationStatus.logValue)"
        }
        BridgeLogger.server.debug("codex app-server diagnostic runtime can_submit result=\(result, privacy: .public) init_status=\(initializationStatus.logValue, privacy: .public) thread_id=\(threadID ?? "-", privacy: .public) busy=\(busySummary, privacy: .public) false_reason=\(falseReason, privacy: .public)")
        return result
    }

    // Fail closed: blank/whitespace identities are never stored, and a nil
    // or blank update never clears an existing valid binding.
    func setRegistryRootThreadID(_ rawThreadID: String?) {
        guard let threadID = rawThreadID?.trimmingCharacters(in: .whitespacesAndNewlines),
              threadID.isEmpty == false else {
            return
        }
        lock.lock()
        registryRootThreadID = threadID
        let subscriptionState = attachSubscriptionState
        lock.unlock()
        guard case .ready = initialization.diagnosticStatus() else {
            return
        }
        if case .subscribed(let existingThreadID) = subscriptionState,
           existingThreadID != threadID {
            activeThreadStore.setThreadID(threadID)
            sendThreadResumeForSubscriptionIfNeeded(threadID: threadID,
                                                    reason: "registry_root_changed")
            return
        }
        guard beginSubscriptionAttempt() else {
            return
        }
        activeThreadStore.setThreadID(threadID)
        sendThreadResumeForSubscription(threadID: threadID)
    }

    func isStopped() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    func ensureThreadSubscription() {
        let initializationStatus = initialization.diagnosticStatus()
        guard case .ready = initializationStatus else {
            return
        }
        guard beginSubscriptionAttempt() else {
            return
        }
        sendLoadedThreadRequestForSubscription()
    }

    func refreshActiveThread() {
        let initializationStatus = initialization.diagnosticStatus()
        guard case .ready = initializationStatus else {
            return
        }
        guard canRefreshActiveThread() else {
            return
        }
        sendLoadedThreadRequestForSubscription(clearSubscriptionOnMissing: false,
                                               reason: "active_thread_refresh")
    }

    private func currentThreadIDForSubmit() throws -> String? {
        if let threadID = activeThreadStore.currentThreadID() {
            return threadID
        }
        return try loadCurrentThreadID()
    }

    private func loadCurrentThreadID(timeout: TimeInterval = 5) throws -> String? {
        let condition = NSCondition()
        var result: Result<String?, Error>?
        try connection.sendClientRequest(method: "thread/loaded/list") { response in
            condition.lock()
            switch response {
            case .success(let value):
                let threadID = codexAppServerLoadedThreadID(from: value)
                if let threadID {
                    self.activeThreadStore.setThreadID(threadID)
                } else {
                    BridgeLogger.server.info("codex app-server submit loaded thread list returned no thread shape=\(codexAppServerLoadedThreadShapeDescription(from: value), privacy: .public)")
                }
                result = .success(threadID)
            case .failure(let error):
                result = .failure(error)
            }
            condition.broadcast()
            condition.unlock()
        }

        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }
        while result == nil {
            if condition.wait(until: deadline) == false {
                throw CodexAppServerConnectionError.initializationTimedOut
            }
        }
        return try result?.get()
    }

    func stop() {
        lock.lock()
        guard stopped == false else {
            lock.unlock()
            return
        }
        stopped = true
        lock.unlock()

        initialization.fail(CodexAppServerConnectionError.closed)
        connection.close()
        transport.close()
        if processOwnership == .owned {
            process.terminate()
        }
        lifecycleFeed?.retire()
    }

    func handleProcessExit(exitCode: Int32) {
        lock.lock()
        stopped = true
        lock.unlock()
        initialization.fail(CodexAppServerConnectionError.closed)
        connection.close()
        lifecycleFeed?.retire()
    }

    func handleTransportClosed(error: Error?) {
        lock.lock()
        guard stopped == false else {
            lock.unlock()
            return
        }
        stopped = true
        lock.unlock()
        BridgeLogger.server.error("codex app-server transport closed session_id=\(self.runtime.contextSessionID, privacy: .public) error=\(String(describing: error), privacy: .public)")
        initialization.fail(CodexAppServerConnectionError.closed)
        connection.close()
        transport.close()
        lifecycleFeed?.retire()
    }

    func whenInitialized(_ callback: @escaping @Sendable (Result<Void, Error>) -> Void) {
        initialization.notify(callback)
    }

    private func beginSubscriptionAttempt() -> Bool {
        lock.lock()
        guard stopped == false else {
            lock.unlock()
            return false
        }
        if let nextSubscriptionRetryAt, nextSubscriptionRetryAt > Date() {
            lock.unlock()
            return false
        }
        guard attachSubscriptionState.shouldRetry else {
            lock.unlock()
            return false
        }
        let previousState = attachSubscriptionState
        nextSubscriptionRetryAt = nil
        attachSubscriptionState = .resumePending
        lock.unlock()
        logAttachSubscriptionTransition(from: previousState,
                                        to: .resumePending,
                                        reason: "ensure_retry")
        return true
    }

    private func canRefreshActiveThread() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard stopped == false else {
            return false
        }
        if case .subscribed = attachSubscriptionState {
            return true
        }
        return false
    }

    private func setAttachSubscriptionState(_ state: AttachSubscriptionState, reason: String) {
        lock.lock()
        let previousState = attachSubscriptionState
        attachSubscriptionState = state
        lock.unlock()
        logAttachSubscriptionTransition(from: previousState, to: state, reason: reason)
    }

    private func logAttachSubscriptionTransition(from previousState: AttachSubscriptionState,
                                                 to state: AttachSubscriptionState,
                                                 reason: String) {
        guard previousState != state else {
            return
        }
        BridgeLogger.server.info("codex app-server subscription state changed session_id=\(self.runtime.contextSessionID, privacy: .public) from=\(previousState.logValue, privacy: .public) to=\(state.logValue, privacy: .public) reason=\(reason, privacy: .public)")
    }

    private func sendLoadedThreadRequestForSubscription(clearSubscriptionOnMissing: Bool = true,
                                                        reason: String = "loaded_thread_found") {
        do {
            try connection.sendClientRequest(method: "thread/loaded/list") { [weak self] result in
                guard let self else {
                    return
                }
                self.callbackQueue.async {
                    self.handleLoadedThreadSubscriptionResult(result,
                                                              clearSubscriptionOnMissing: clearSubscriptionOnMissing,
                                                              reason: reason)
                }
            }
        } catch {
            BridgeLogger.server.error("codex app-server subscription loaded thread list request failed error=\(String(describing: error), privacy: .public)")
            setAttachSubscriptionState(.failed("loaded_thread_list_request_failed"), reason: "loaded_thread_list_request_failed")
        }
    }

    private func handleLoadedThreadSubscriptionResult(_ result: Result<JSONValue, CodexAppServerConnectionError>,
                                                      clearSubscriptionOnMissing: Bool,
                                                      reason: String) {
        switch result {
        case .success(let value):
            lock.lock()
            let knownRootThreadID = registryRootThreadID
            lock.unlock()
            guard let threadID = codexAppServerLoadedThreadID(from: value,
                                                              registryRootThreadID: knownRootThreadID) else {
                BridgeLogger.server.debug("codex app-server subscription no loaded thread shape=\(codexAppServerLoadedThreadShapeDescription(from: value), privacy: .public)")
                if clearSubscriptionOnMissing {
                    loadedThreadUnresolvedHook?()
                    lock.lock()
                    let fallbackThreadID = registryRootThreadID
                    let previousState = attachSubscriptionState
                    if fallbackThreadID == nil {
                        attachSubscriptionState = .noLoadedThread
                    }
                    lock.unlock()
                    if let fallbackThreadID {
                        activeThreadStore.setThreadID(fallbackThreadID)
                        sendThreadResumeForSubscriptionIfNeeded(threadID: fallbackThreadID,
                                                                reason: "registry_root_fallback")
                    } else {
                        logAttachSubscriptionTransition(from: previousState,
                                                        to: .noLoadedThread,
                                                        reason: "loaded_thread_missing")
                    }
                }
                return
            }
            activeThreadStore.setThreadID(threadID)
            sendThreadResumeForSubscriptionIfNeeded(threadID: threadID, reason: reason)
        case .failure(let error):
            BridgeLogger.server.error("codex app-server subscription loaded thread list failed error=\(String(describing: error), privacy: .public)")
            setAttachSubscriptionState(.failed("loaded_thread_list_failed"), reason: "loaded_thread_list_failed")
        }
    }

    private func sendThreadResumeForSubscriptionIfNeeded(threadID: String, reason: String) {
        lock.lock()
        guard stopped == false else {
            lock.unlock()
            return
        }
        if case .subscribed(let existingThreadID) = attachSubscriptionState {
            if existingThreadID == threadID {
                lock.unlock()
                return
            }
            lock.unlock()
            BridgeLogger.server.error("codex app-server subscription root changed while subscribed session_id=\(self.runtime.contextSessionID, privacy: .public) from=\(existingThreadID, privacy: .public) to=\(threadID, privacy: .public) action=stop_for_replacement")
            stop()
            return
        }
        let previousState = attachSubscriptionState
        attachSubscriptionState = .resumePending
        lock.unlock()
        logAttachSubscriptionTransition(from: previousState, to: .resumePending, reason: reason)
        sendThreadResumeForSubscription(threadID: threadID)
    }

    private func sendThreadResumeForSubscription(threadID: String) {
        BridgeLogger.server.debug("codex app-server diagnostic resume request session_id=\(self.runtime.contextSessionID, privacy: .public) thread_id=\(threadID, privacy: .public) request_has_approvalsReviewer=false cwd=- source=subscription_ensure")
        let snapshotBarrier = lifecycleFeed?.snapshotBarrier()
        let turnStateBarrier = turnStateStore.revisionBarrier(threadID: threadID)
        do {
            try connection.sendClientRequest(method: "thread/resume",
                                             params: [
                                                "threadId": .string(threadID),
                                                "excludeTurns": .bool(false),
                                             ],
                                             onResponse: { [weak self] response in
                                                CodexAppServerHeadlessRuntime.logThreadResumeResponse(response,
                                                                                                      sessionID: self?.runtime.contextSessionID ?? "-",
                                                                                                      threadID: threadID,
                                                                                                      requestHasApprovalsReviewer: false)
                                                switch response {
                                                case .success(let payload):
                                                    guard let self else {
                                                        return
                                                    }
                                                    self.lock.lock()
                                                    guard self.stopped == false else {
                                                        self.lock.unlock()
                                                        return
                                                    }
                                                    let knownRootThreadID = self.registryRootThreadID
                                                    if let knownRootThreadID,
                                                       knownRootThreadID != threadID {
                                                        self.lock.unlock()
                                                        self.stop()
                                                        return
                                                    }
                                                    let previousState = self.attachSubscriptionState
                                                    self.attachSubscriptionState = .subscribed(threadID: threadID)
                                                    self.lock.unlock()
                                                    self.logAttachSubscriptionTransition(from: previousState,
                                                                                         to: .subscribed(threadID: threadID),
                                                                                         reason: "thread_resume_success")
                                                    self.lifecycleFeed?.applySnapshotResult(payload,
                                                                                            threadID: threadID,
                                                                                            barrier: snapshotBarrier)
                                                    self.seedActiveTurnFromResumeSnapshot(payload,
                                                                                        threadID: threadID,
                                                                                        barrier: turnStateBarrier)
                                                case .failure(let error):
                                                    if self?.handleThreadResumeNoRollout(error, threadID: threadID) == true {
                                                        return
                                                    }
                                                    BridgeLogger.server.error("codex app-server subscription thread resume failed thread_id=\(threadID, privacy: .public) error=\(String(describing: error), privacy: .public)")
                                                    self?.setAttachSubscriptionState(.failed("thread_resume_failed"), reason: "thread_resume_failed")
                                                }
                                             })
        } catch {
            BridgeLogger.server.error("codex app-server subscription thread resume request failed thread_id=\(threadID, privacy: .public) error=\(String(describing: error), privacy: .public)")
            setAttachSubscriptionState(.failed("thread_resume_request_failed"), reason: "thread_resume_request_failed")
        }
    }

    private func handleThreadResumeNoRollout(_ error: CodexAppServerConnectionError, threadID: String) -> Bool {
        guard case .requestFailed(let rpcError) = error,
              rpcError.code == -32600,
              rpcError.message.localizedCaseInsensitiveContains("no rollout found") else {
            return false
        }

        activeThreadStore.clearThreadID(ifEqualTo: threadID)
        lock.lock()
        nextSubscriptionRetryAt = Date().addingTimeInterval(Self.subscriptionRetryBackoff)
        lock.unlock()
        BridgeLogger.server.info("codex app-server subscription waiting for rollout thread_id=\(threadID, privacy: .public) retry_after_seconds=\(Self.subscriptionRetryBackoff, privacy: .public)")
        setAttachSubscriptionState(.noLoadedThread, reason: "thread_resume_no_rollout")
        return true
    }
}

final class CodexAppServerTurnStateStore: @unchecked Sendable {
    private enum TurnOrigin {
        case remoteSubmit
        case appServer

        var logValue: String {
            switch self {
            case .remoteSubmit:
                return "remote_submit"
            case .appServer:
                return "app_server"
            }
        }
    }

    private struct TurnActivity {
        let turnID: String
        let startedAt: Date
        let origin: TurnOrigin
    }

    private struct PendingSubmit {
        let claimID: UUID
        let startedAt: Date
        // A terminal can race ahead of turn/start's JSON-RPC response. It
        // cannot safely clear an anonymous pending claim immediately (it
        // may belong to an older turn), so retain the exact terminal IDs
        // until this claim's response supplies the authoritative identity.
        var completedTurnIDs: Set<String> = []
    }

    private struct State {
        var pendingSubmit: PendingSubmit?
        var turn: TurnActivity?
        var threadStatusActiveStartedAt: Date?

        var isBusy: Bool {
            pendingSubmit != nil || turn != nil || threadStatusActiveStartedAt != nil
        }

        mutating func pruneExpired(now: Date, timeout: TimeInterval) {
            if let pendingSubmit,
               now.timeIntervalSince(pendingSubmit.startedAt) >= timeout {
                self.pendingSubmit = nil
            }
            if let activeTurn = turn,
               now.timeIntervalSince(activeTurn.startedAt) >= timeout {
                turn = nil
            }
            if let startedAt = threadStatusActiveStartedAt,
               now.timeIntervalSince(startedAt) >= timeout {
                threadStatusActiveStartedAt = nil
            }
        }
    }

    private let lock = NSLock()
    private let timeout: TimeInterval
    private let now: () -> Date
    private var statesByThreadID = [String: State]()
    // Order fence for thread/resume's active-turn seeding — separate from
    // any lifecycle-store barrier, since this store's state (pending
    // claims, live turn/started-turn/completed edges) advances
    // independently. Deliberately NEVER cleared when a thread's `State`
    // entry is removed (goes idle) — a stale resume response must stay
    // invalidated even across a busy -> idle -> busy transition.
    private var revisionsByThreadID: [String: Int] = [:]

    init(timeout: TimeInterval = 15 * 60,
         now: @escaping () -> Date = Date.init) {
        self.timeout = timeout
        self.now = now
    }

    func claimForSubmit(threadID: String) throws {
        lock.lock()
        defer { lock.unlock() }
        pruneExpiredLocked(now: now())
        if statesByThreadID[threadID]?.isBusy == true {
            throw BridgeInternalError.invalidRequest("Codex app-server turn is already running.")
        }
        statesByThreadID[threadID] = State(pendingSubmit: PendingSubmit(claimID: UUID(),
                                                                        startedAt: now()))
        bumpRevisionLocked(threadID: threadID)
    }

    // Captured BEFORE sending a thread/resume request; the response
    // snapshot's active-turn seeding applies only while this thread's
    // state has not advanced since (see seedActiveTurnFromResumeIfUnchanged).
    func revisionBarrier(threadID: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return revisionsByThreadID[threadID] ?? 0
    }

    // Seeds the active turn observed in a thread/resume response — ONLY if
    // this thread's turn state has not advanced (no claim, no turn/started,
    // no turn/completed, no thread-status edge) since `barrier` was
    // captured right before the resume request was sent. A stale response
    // racing a live completion, a newer turn/started, or a remote submit's
    // own claim must never resurrect/overwrite that newer state — the
    // revision check and the mutation happen under ONE lock hold, so there
    // is no TOCTOU window between "barrier looked valid" and "the seed was
    // actually applied."
    @discardableResult
    func seedActiveTurnFromResumeIfUnchanged(threadID: String, turnID: String, barrier: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        pruneExpiredLocked(now: now())
        guard (revisionsByThreadID[threadID] ?? 0) == barrier else {
            return false
        }
        var state = statesByThreadID[threadID] ?? State()
        if state.pendingSubmit?.completedTurnIDs.contains(turnID) == true {
            // The matching terminal arrived before this snapshot exposed
            // the identity. Retire the claim but never resurrect an already
            // completed turn or emit a resume-open control for it.
            state.pendingSubmit = nil
            if state.turn?.turnID == turnID {
                state.turn = nil
            }
            if state.isBusy {
                statesByThreadID[threadID] = state
            } else {
                statesByThreadID.removeValue(forKey: threadID)
            }
            bumpRevisionLocked(threadID: threadID)
            return false
        }
        state.turn = TurnActivity(turnID: turnID, startedAt: now(), origin: .appServer)
        statesByThreadID[threadID] = state
        bumpRevisionLocked(threadID: threadID)
        return true
    }

    // Same revision-fenced contract as seedActiveTurnFromResumeIfUnchanged,
    // for the case where a thread/resume snapshot reports the thread as
    // active/busy but names zero or an ambiguous set of inProgress turns —
    // there is no turn id to steer into, but the thread must still be
    // marked busy so routeSubmit() fails closed to .busyWithoutTurnID
    // instead of wrongly treating it as idle.
    @discardableResult
    func markThreadActiveIfUnchanged(threadID: String, barrier: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        pruneExpiredLocked(now: now())
        guard (revisionsByThreadID[threadID] ?? 0) == barrier else {
            return false
        }
        var state = statesByThreadID[threadID] ?? State()
        state.threadStatusActiveStartedAt = now()
        statesByThreadID[threadID] = state
        bumpRevisionLocked(threadID: threadID)
        return true
    }

    // The ONE atomic routing decision for a remote chat submit — replaces
    // canSubmitMessage() + claimForSubmit() as two separate calls (which
    // left a TOCTOU window between the gate check and the claim). A
    // single lock hold both DECIDES the route and, for .start, claims the
    // pending-submit slot:
    // - an active turn with a KNOWN turn id -> steer INTO that turn
    //   (native turn/steer), never a new turn/start;
    // - no known turn id, but busy (another submit's pending claim, or an
    //   app-server-reported active thread status with no observed turn id
    //   yet) -> a typed conflict; the caller must never terminal-fallback
    //   here (for a codex_app_server record the "terminal" is Tidey's
    //   headless viewer, which re-submits via chat_submit — falling back
    //   would create a recursive resubmit loop);
    // - otherwise idle -> claim the pending-submit slot for a new
    //   turn/start, exactly like claimForSubmit() did.
    enum SubmitRoute: Equatable {
        case start
        case steer(turnID: String)
        case busyWithoutTurnID
    }

    func routeSubmit(threadID: String, claimID: UUID = UUID()) -> SubmitRoute {
        lock.lock()
        defer { lock.unlock() }
        pruneExpiredLocked(now: now())
        var state = statesByThreadID[threadID] ?? State()
        if let turn = state.turn {
            return .steer(turnID: turn.turnID)
        }
        if state.pendingSubmit != nil || state.threadStatusActiveStartedAt != nil {
            return .busyWithoutTurnID
        }
        state.pendingSubmit = PendingSubmit(claimID: claimID, startedAt: now())
        statesByThreadID[threadID] = state
        bumpRevisionLocked(threadID: threadID)
        return .start
    }

    func releasePendingSubmit(threadID: String, claimID: UUID) {
        lock.lock()
        defer { lock.unlock() }
        pruneExpiredLocked(now: now())
        guard var state = statesByThreadID[threadID],
              state.pendingSubmit?.claimID == claimID else {
            return
        }
        state.pendingSubmit = nil
        bumpRevisionLocked(threadID: threadID)
        if state.isBusy {
            statesByThreadID[threadID] = state
        } else {
            statesByThreadID.removeValue(forKey: threadID)
        }
    }

    // Compatibility seam for the current caller. Runtime wiring switches to
    // exact claim identity in the behavioral step.
    func releasePendingSubmit(threadID: String) {
        lock.lock()
        defer { lock.unlock() }
        pruneExpiredLocked(now: now())
        guard var state = statesByThreadID[threadID], state.pendingSubmit != nil else {
            return
        }
        state.pendingSubmit = nil
        bumpRevisionLocked(threadID: threadID)
        if state.isBusy {
            statesByThreadID[threadID] = state
        } else {
            statesByThreadID.removeValue(forKey: threadID)
        }
    }

    // Applies an authoritative turn/start success only to the exact pending
    // claim that issued it. A stale P1 response is a no-op after P1 expires
    // or P2 owns the slot; the claim check and transition share one lock.
    func reconcileAcceptedStart(threadID: String, claimID: UUID, turnID: String) {
        lock.lock()
        defer { lock.unlock() }
        pruneExpiredLocked(now: now())
        guard var state = statesByThreadID[threadID],
              let pending = state.pendingSubmit,
              pending.claimID == claimID else {
            // A live turn/started or another exact recovery path may have
            // consumed the claim already. Never overwrite newer state.
            return
        }

        state.pendingSubmit = nil
        if pending.completedTurnIDs.contains(turnID) {
            // completion-before-response: retire the claim without
            // recreating an already-completed turn.
            if state.turn?.turnID == turnID {
                state.turn = nil
            }
        } else if let currentTurn = state.turn {
            if currentTurn.turnID == turnID {
                state.turn = TurnActivity(turnID: turnID,
                                          startedAt: currentTurn.startedAt,
                                          origin: .remoteSubmit)
            }
        } else {
            state.turn = TurnActivity(turnID: turnID,
                                      startedAt: pending.startedAt,
                                      origin: .remoteSubmit)
        }

        bumpRevisionLocked(threadID: threadID)
        if state.isBusy {
            statesByThreadID[threadID] = state
        } else {
            statesByThreadID.removeValue(forKey: threadID)
        }
    }

    func markStarted(threadID: String, turnID: String) {
        lock.lock()
        updateStateLocked(threadID: threadID) { state in
            let pending = state.pendingSubmit
            let existing = state.turn
            let origin: TurnOrigin
            if pending != nil || (existing?.turnID == turnID && existing?.origin == .remoteSubmit) {
                origin = .remoteSubmit
            } else {
                origin = .appServer
            }
            state.pendingSubmit = nil
            state.turn = TurnActivity(turnID: turnID,
                                      startedAt: existing?.turnID == turnID ? existing?.startedAt ?? now() : pending?.startedAt ?? now(),
                                      origin: origin)
        }
        lock.unlock()
    }

    func markCompleted(threadID: String, turnID: String) {
        lock.lock()
        updateStateLocked(threadID: threadID) { state in
            if state.turn?.turnID == turnID {
                state.turn = nil
                state.pendingSubmit = nil
            } else if var pending = state.pendingSubmit {
                pending.completedTurnIDs.insert(turnID)
                state.pendingSubmit = pending
            }
        }
        lock.unlock()
    }

    func markThreadActive(threadID: String) {
        lock.lock()
        updateStateLocked(threadID: threadID) { state in
            state.threadStatusActiveStartedAt = now()
        }
        lock.unlock()
    }

    func markThreadIdle(threadID: String) {
        lock.lock()
        updateStateLocked(threadID: threadID) { state in
            state.threadStatusActiveStartedAt = nil
            if state.turn?.origin == .appServer {
                state.turn = nil
            }
        }
        lock.unlock()
    }

    // Non-mutating peek used by canSubmitMessage() to gate BEFORE
    // attempting claimForSubmit — expired activity is pruned first so a
    // long-dead "busy" state (past the timeout) does not wrongly block.
    func isBusy(threadID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        pruneExpiredLocked(now: now())
        return statesByThreadID[threadID]?.isBusy == true
    }

    func diagnosticBusySummary(threadID: String) -> String {
        lock.lock()
        defer { lock.unlock() }
        guard let state = statesByThreadID[threadID] else {
            return "idle"
        }
        var parts = [String]()
        if state.pendingSubmit != nil {
            parts.append("pending_submit")
        }
        if let turn = state.turn {
            parts.append("turn:\(turn.origin.logValue)")
        }
        if state.threadStatusActiveStartedAt != nil {
            parts.append("thread_status_active")
        }
        return parts.isEmpty ? "idle" : parts.joined(separator: "+")
    }

    private func pruneExpiredLocked(now: Date) {
        for threadID in Array(statesByThreadID.keys) {
            guard var state = statesByThreadID[threadID] else {
                continue
            }
            state.pruneExpired(now: now, timeout: timeout)
            if state.isBusy {
                statesByThreadID[threadID] = state
            } else {
                statesByThreadID.removeValue(forKey: threadID)
            }
        }
    }

    private func updateStateLocked(threadID: String, mutate: (inout State) -> Void) {
        var state = statesByThreadID[threadID] ?? State()
        mutate(&state)
        bumpRevisionLocked(threadID: threadID)
        if state.isBusy {
            statesByThreadID[threadID] = state
        } else {
            statesByThreadID.removeValue(forKey: threadID)
        }
    }

    private func bumpRevisionLocked(threadID: String) {
        revisionsByThreadID[threadID, default: 0] += 1
    }
}

final class CodexAppServerActiveThreadStore: @unchecked Sendable {
    private let lock = NSLock()
    private let onChange: (String) -> Void
    private var threadID: String?

    init(onChange: @escaping (String) -> Void = { _ in }) {
        self.onChange = onChange
    }

    @discardableResult
    func setThreadID(_ threadID: String) -> Bool {
        lock.lock()
        let changed = self.threadID != threadID
        self.threadID = threadID
        lock.unlock()
        if changed {
            onChange(threadID)
        }
        return changed
    }

    // Passive notification observations may seed an empty binding but may
    // never replace an already-authoritative loaded-list/resume root.
    @discardableResult
    func noteObservedThreadID(_ threadID: String) -> Bool {
        lock.lock()
        guard self.threadID == nil else {
            lock.unlock()
            return false
        }
        self.threadID = threadID
        lock.unlock()
        onChange(threadID)
        return true
    }

    func currentThreadID() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return threadID
    }

    func clearThreadID(ifEqualTo expectedThreadID: String) {
        lock.lock()
        if threadID == expectedThreadID {
            threadID = nil
        }
        lock.unlock()
    }
}

final class CodexAppServerInitializationState: @unchecked Sendable {
    enum DiagnosticStatus {
        case pending
        case ready
        case failed

        var logValue: String {
            switch self {
            case .pending:
                return "pending"
            case .ready:
                return "ready"
            case .failed:
                return "failed"
            }
        }
    }

    private enum State {
        case pending
        case ready
        case failed(Error)
    }

    private let condition = NSCondition()
    private var state: State = .pending
    private var callbacks: [@Sendable (Result<Void, Error>) -> Void] = []

    func succeed() {
        complete(.ready)
    }

    func fail(_ error: Error) {
        complete(.failed(error))
    }

    func wait(timeout: TimeInterval = 10) throws {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }

        while true {
            switch state {
            case .ready:
                return
            case .failed(let error):
                throw error
            case .pending:
                let shouldContinue = condition.wait(until: deadline)
                if shouldContinue == false {
                    state = .failed(CodexAppServerConnectionError.initializationTimedOut)
                    condition.broadcast()
                    throw CodexAppServerConnectionError.initializationTimedOut
                }
            }
        }
    }

    func diagnosticStatus() -> DiagnosticStatus {
        condition.lock()
        defer { condition.unlock() }
        switch state {
        case .pending:
            return .pending
        case .ready:
            return .ready
        case .failed:
            return .failed
        }
    }

    private func complete(_ newState: State) {
        let result: Result<Void, Error>
        switch newState {
        case .ready:
            result = .success(())
        case .failed(let error):
            result = .failure(error)
        case .pending:
            return
        }

        condition.lock()
        guard case .pending = state else {
            condition.unlock()
            return
        }
        state = newState
        let callbacks = callbacks
        self.callbacks.removeAll()
        condition.broadcast()
        condition.unlock()
        for callback in callbacks {
            callback(result)
        }
    }

    func notify(_ callback: @escaping @Sendable (Result<Void, Error>) -> Void) {
        let result: Result<Void, Error>?
        condition.lock()
        switch state {
        case .pending:
            callbacks.append(callback)
            result = nil
        case .ready:
            result = .success(())
        case .failed(let error):
            result = .failure(error)
        }
        condition.unlock()

        if let result {
            callback(result)
        }
    }
}

final class CodexAppServerRuntimeSessionFactory {
    static func makeLifecycleFeed(context: CodexAppServerRuntimeContext,
                                  activeThreadStore: CodexAppServerActiveThreadStore) -> CodexLifecycleFeed {
        CodexLifecycleFeed(identity: AgentSessionLifecycleIdentity(workspaceID: context.workspaceID,
                                                                   panelID: context.panelID,
                                                                   sessionID: context.sessionID),
                           rootThreadID: { activeThreadStore.currentThreadID() })
    }

    private let processRunner: CodexAppServerProcessRunning
    private let transportConnector: CodexAppServerTransportConnecting
    private let externalProcessFactory: (Int32?) -> CodexAppServerManagedProcess

    init(processRunner: CodexAppServerProcessRunning = CodexAppServerProcessRunner(),
         transportConnector: CodexAppServerTransportConnecting = CodexAppServerWebSocketTransportConnector(),
         externalProcessFactory: @escaping (Int32?) -> CodexAppServerManagedProcess = {
             CodexAppServerExternalProcess(processID: $0)
         }) {
        self.processRunner = processRunner
        self.transportConnector = transportConnector
        self.externalProcessFactory = externalProcessFactory
    }

    func start(configuration: CodexAppServerLaunchConfiguration,
               context: CodexAppServerRuntimeContext,
               nextSequence: @escaping CodexAppServerConnection.SequenceProvider,
               timestampProvider: @escaping CodexAppServerConnection.TimestampProvider,
               onAgentEvent: @escaping CodexAppServerHeadlessRuntime.AgentEventHandler,
               onInteractivePrompt: @escaping CodexAppServerConnection.InteractivePromptHandler,
               onInteractivePromptResolved: @escaping CodexAppServerConnection.InteractivePromptResolvedHandler,
               onActiveThreadID: @escaping CodexAppServerHeadlessRuntime.ThreadIDHandler = { _ in },
               onStderrLine: @escaping @Sendable (String) -> Void = { _ in },
               onExit: @escaping @Sendable (Int32) -> Void = { _ in }) throws -> CodexAppServerRuntimeSession {
        let stdoutRouter = CodexAppServerConnectionLineRouter()
        let exitRouter = CodexAppServerRuntimeSessionExitRouter(onExit: onExit)
        let closeRouter = CodexAppServerTransportCloseRouter()
        let process = try processRunner.start(configuration: configuration,
                                              onStdoutLine: { line in
                                                  stdoutRouter.receive(line)
                                              },
                                              onStderrLine: onStderrLine,
                                              onExit: { exitCode in
                                                  exitRouter.receive(exitCode)
                                              })
        let transport: CodexAppServerConnectionTransport
        switch configuration.transport {
        case .stdio:
            transport = CodexAppServerStdioTransport(process: process)
        case .unixSocket:
            transport = try transportConnector.connect(mode: configuration.transport,
                                                       onLine: { line in
                                                           stdoutRouter.receive(line)
                                                       },
                                                       onClose: { error in
                                                           closeRouter.receive(error)
                                                       })
        }
        let activeThreadStore = CodexAppServerActiveThreadStore(onChange: onActiveThreadID)
        let turnStateStore = CodexAppServerTurnStateStore()
        let lifecycleFeed = Self.makeLifecycleFeed(context: context,
                                                   activeThreadStore: activeThreadStore)
        let runtime = CodexAppServerHeadlessRuntime(context: context,
                                                    nextSequence: nextSequence,
                                                    timestampProvider: timestampProvider,
                                                    onAgentEvent: onAgentEvent,
                                                    onThreadID: { _ = activeThreadStore.noteObservedThreadID($0) },
                                                    onTurnStarted: { threadID, turnID in
                                                        turnStateStore.markStarted(threadID: threadID, turnID: turnID)
                                                        lifecycleFeed.applyTurnStarted(threadID: threadID, turnID: turnID)
                                                    },
                                                    onTurnCompleted: { threadID, turnID in
                                                        turnStateStore.markCompleted(threadID: threadID, turnID: turnID)
                                                        lifecycleFeed.applyTurnCompleted(threadID: threadID, turnID: turnID)
                                                    },
                                                    onThreadActive: turnStateStore.markThreadActive,
                                                    onThreadIdle: turnStateStore.markThreadIdle,
                                                    onThreadStatusLifecycle: lifecycleFeed.applyStatus)
        let connection = CodexAppServerConnection(sendLine: { line in
            try transport.sendLine(line)
        },
                                                   onNotification: runtime.handleNotification,
                                                   approvalContext: CodexAppServerApprovalContext(workspaceID: context.workspaceID,
                                                                                                  panelID: context.panelID,
                                                                                                  sessionID: context.sessionID),
                                                   nextSequence: nextSequence,
                                                   timestampProvider: timestampProvider,
                                                   onInteractivePrompt: onInteractivePrompt,
                                                   onInteractivePromptResolved: onInteractivePromptResolved)
        let initialization = CodexAppServerInitializationState()
        let runtimeSession = CodexAppServerRuntimeSession(process: process,
                                                          processOwnership: .owned,
                                                          transport: transport,
                                                          connection: connection,
                                                          runtime: runtime,
                                                          initialization: initialization,
                                                          activeThreadStore: activeThreadStore,
                                                          turnStateStore: turnStateStore,
                                                          lifecycleFeed: lifecycleFeed)
        exitRouter.attach(runtimeSession)
        closeRouter.attach(runtimeSession)
        stdoutRouter.attach(connection)
        try connection.sendClientRequest(method: "initialize",
                                         params: [
                                            "clientInfo": .object([
                                                "name": .string("tidey-bridge"),
                                                "title": .string("Tidey Remote Bridge"),
                                                "version": .string("0"),
                                            ]),
                                            "capabilities": .object([
                                                "experimentalApi": .bool(true),
                                                "requestAttestation": .bool(false),
                                                "optOutNotificationMethods": .array([]),
                                            ]),
                                         ]) { result in
            switch result {
            case .success:
                do {
                    try connection.sendClientNotification(method: "initialized")
                    initialization.succeed()
                } catch {
                    initialization.fail(error)
                    BridgeLogger.server.error("codex app-server initialized notification failed error=\(String(describing: error), privacy: .public)")
                }
            case .failure(let error):
                initialization.fail(error)
                BridgeLogger.server.error("codex app-server initialize failed error=\(String(describing: error), privacy: .public)")
            }
        }
        return runtimeSession
    }

    func attach(socketPath: String,
                processID: Int32?,
                context: CodexAppServerRuntimeContext,
                nextSequence: @escaping CodexAppServerConnection.SequenceProvider,
                timestampProvider: @escaping CodexAppServerConnection.TimestampProvider,
                onAgentEvent: @escaping CodexAppServerHeadlessRuntime.AgentEventHandler,
                onInteractivePrompt: @escaping CodexAppServerConnection.InteractivePromptHandler,
                onInteractivePromptResolved: @escaping CodexAppServerConnection.InteractivePromptResolvedHandler,
                onActiveThreadID: @escaping CodexAppServerHeadlessRuntime.ThreadIDHandler = { _ in }) throws -> CodexAppServerRuntimeSession {
        let stdoutRouter = CodexAppServerConnectionLineRouter()
        let process = externalProcessFactory(processID)
        let closeRouter = CodexAppServerTransportCloseRouter()
        let transport = try transportConnector.connect(mode: .unixSocket(path: socketPath),
                                                       onLine: { line in
                                                           stdoutRouter.receive(line)
                                                       },
                                                       onClose: { error in
                                                           closeRouter.receive(error)
                                                       })
        let activeThreadStore = CodexAppServerActiveThreadStore(onChange: onActiveThreadID)
        let turnStateStore = CodexAppServerTurnStateStore()
        let lifecycleFeed = Self.makeLifecycleFeed(context: context,
                                                   activeThreadStore: activeThreadStore)
        let runtime = CodexAppServerHeadlessRuntime(context: context,
                                                    nextSequence: nextSequence,
                                                    timestampProvider: timestampProvider,
                                                    onAgentEvent: onAgentEvent,
                                                    onThreadID: { _ = activeThreadStore.noteObservedThreadID($0) },
                                                    onTurnStarted: { threadID, turnID in
                                                        turnStateStore.markStarted(threadID: threadID, turnID: turnID)
                                                        lifecycleFeed.applyTurnStarted(threadID: threadID, turnID: turnID)
                                                    },
                                                    onTurnCompleted: { threadID, turnID in
                                                        turnStateStore.markCompleted(threadID: threadID, turnID: turnID)
                                                        lifecycleFeed.applyTurnCompleted(threadID: threadID, turnID: turnID)
                                                    },
                                                    onThreadActive: turnStateStore.markThreadActive,
                                                    onThreadIdle: turnStateStore.markThreadIdle,
                                                    onThreadStatusLifecycle: lifecycleFeed.applyStatus)
        let connection = CodexAppServerConnection(sendLine: { line in
            try transport.sendLine(line)
        },
                                                   onNotification: runtime.handleNotification,
                                                   approvalContext: CodexAppServerApprovalContext(workspaceID: context.workspaceID,
                                                                                                  panelID: context.panelID,
                                                                                                  sessionID: context.sessionID),
                                                   nextSequence: nextSequence,
                                                   timestampProvider: timestampProvider,
                                                   onInteractivePrompt: onInteractivePrompt,
                                                   onInteractivePromptResolved: onInteractivePromptResolved)
        let initialization = CodexAppServerInitializationState()
        let runtimeSession = CodexAppServerRuntimeSession(process: process,
                                                          processOwnership: .external,
                                                          transport: transport,
                                                          connection: connection,
                                                          runtime: runtime,
                                                          initialization: initialization,
                                                          activeThreadStore: activeThreadStore,
                                                          turnStateStore: turnStateStore,
                                                          lifecycleFeed: lifecycleFeed)
        closeRouter.attach(runtimeSession)
        stdoutRouter.attach(connection)
        try connection.sendClientRequest(method: "initialize",
                                         params: [
                                            "clientInfo": .object([
                                                "name": .string("tidey-bridge"),
                                                "title": .string("Tidey Remote Bridge"),
                                                "version": .string("0"),
                                            ]),
                                            "capabilities": .object([
                                                "experimentalApi": .bool(true),
                                                "requestAttestation": .bool(false),
                                                "optOutNotificationMethods": .array([]),
                                            ]),
                                         ]) { result in
            switch result {
            case .success:
                do {
                    try connection.sendClientNotification(method: "initialized")
                    initialization.succeed()
                    runtimeSession.ensureThreadSubscription()
                } catch {
                    initialization.fail(error)
                    BridgeLogger.server.error("codex app-server panel initialized notification failed error=\(String(describing: error), privacy: .public)")
                }
            case .failure(let error):
                initialization.fail(error)
                BridgeLogger.server.error("codex app-server panel initialize failed error=\(String(describing: error), privacy: .public)")
            }
        }
        return runtimeSession
    }
}

func codexAppServerLoadedThreadID(from value: JSONValue,
                                  registryRootThreadID: String? = nil) -> String? {
    if let object = value.objectValue {
        if let thread = object["thread"]?.objectValue,
           let id = thread["id"]?.stringValue ?? thread["threadId"]?.stringValue {
            return id
        }
        if let thread = object["currentThread"]?.objectValue,
           let id = thread["id"]?.stringValue ?? thread["threadId"]?.stringValue {
            return id
        }
        if codexAppServerLoadedThreadListIsPaginated(object) {
            return nil
        }
    }
    let threads = value.objectValue?["threads"]?.arrayValue
        ?? value.objectValue?["items"]?.arrayValue
        ?? value.objectValue?["loadedThreads"]?.arrayValue
        ?? value.objectValue?["data"]?.arrayValue
        ?? value.arrayValue
        ?? []
    let candidates = threads.compactMap(codexAppServerLoadedThreadCandidate(from:))
    let nonChildCandidates = candidates.filter { $0.isChild == false }
    let currentCandidates = nonChildCandidates.filter(\.isCurrent)
    if currentCandidates.count == 1 {
        return currentCandidates[0].id
    }
    if let registryRootThreadID {
        if nonChildCandidates.contains(where: { $0.id == registryRootThreadID }) {
            return registryRootThreadID
        }
        if candidates.isEmpty == false,
           candidates.allSatisfy(\.isBareString) {
            return nil
        }
    }
    if nonChildCandidates.count == 1 {
        return nonChildCandidates[0].id
    }
    return nil
}

private func codexAppServerLoadedThreadListIsPaginated(_ object: [String: JSONValue]) -> Bool {
    guard let nextCursor = object["nextCursor"] else {
        return false
    }
    if case .null = nextCursor {
        return false
    }
    return true
}

private struct CodexAppServerLoadedThreadCandidate {
    let id: String
    let isCurrent: Bool
    let isChild: Bool
    let isBareString: Bool
}

private func codexAppServerLoadedThreadCandidate(from value: JSONValue) -> CodexAppServerLoadedThreadCandidate? {
    if let id = value.stringValue {
        return CodexAppServerLoadedThreadCandidate(id: id,
                                                   isCurrent: false,
                                                   isChild: false,
                                                   isBareString: true)
    }
    guard let object = value.objectValue else {
        return nil
    }
    if let id = object["id"]?.stringValue ?? object["threadId"]?.stringValue {
        return CodexAppServerLoadedThreadCandidate(id: id,
                                                   isCurrent: codexAppServerLoadedThreadIsCurrent(object),
                                                   isChild: codexAppServerLoadedThreadIsChild(object),
                                                   isBareString: false)
    }
    if let thread = object["thread"]?.objectValue,
       let id = thread["id"]?.stringValue ?? thread["threadId"]?.stringValue {
        return CodexAppServerLoadedThreadCandidate(id: id,
                                                   isCurrent: codexAppServerLoadedThreadIsCurrent(object)
                                                    || codexAppServerLoadedThreadIsCurrent(thread),
                                                   isChild: codexAppServerLoadedThreadIsChild(object)
                                                    || codexAppServerLoadedThreadIsChild(thread),
                                                   isBareString: false)
    }
    return nil
}

private func codexAppServerLoadedThreadIsChild(_ object: [String: JSONValue]) -> Bool {
    let parentKeys = ["parentThreadId", "parent_thread_id", "parentId", "parent_id"]
    for key in parentKeys where object[key]?.stringValue != nil {
        return true
    }
    let agentKeys = ["agentRole", "agent_role", "agentNickname", "agent_nickname"]
    for key in agentKeys where object[key]?.stringValue?.isEmpty == false {
        return true
    }
    if object["role"]?.stringValue == "subagent" {
        return true
    }
    if object["source"]?.objectValue?["subAgent"] != nil {
        return true
    }
    return false
}

private func codexAppServerLoadedThreadIsCurrent(_ object: [String: JSONValue]) -> Bool {
    object["current"]?.boolValue == true
        || object["isCurrent"]?.boolValue == true
        || object["active"]?.boolValue == true
        || object["isActive"]?.boolValue == true
        || object["selected"]?.boolValue == true
}

private func codexAppServerLoadedThreadShapeDescription(from value: JSONValue) -> String {
    if let object = value.objectValue {
        let keys = object.keys.sorted().joined(separator: ",")
        let collectionCount = object["threads"]?.arrayValue?.count
            ?? object["items"]?.arrayValue?.count
            ?? object["loadedThreads"]?.arrayValue?.count
            ?? object["data"]?.arrayValue?.count
            ?? -1
        let firstKeys = (object["threads"]?.arrayValue?.first?.objectValue
            ?? object["items"]?.arrayValue?.first?.objectValue
            ?? object["loadedThreads"]?.arrayValue?.first?.objectValue
            ?? object["data"]?.arrayValue?.first?.objectValue)?
            .keys
            .sorted()
            .joined(separator: ",") ?? "-"
        return "object_keys=\(keys) collection_count=\(collectionCount) first_object_keys=\(firstKeys)"
    }
    if let array = value.arrayValue {
        let firstKeys = array.first?.objectValue?.keys.sorted().joined(separator: ",") ?? "-"
        return "array_count=\(array.count) first_object_keys=\(firstKeys)"
    }
    return "scalar"
}

private final class CodexAppServerExternalProcess: CodexAppServerManagedProcess {
    let processID: Int32?

    init(processID: Int32?) {
        self.processID = processID
    }

    func sendLine(_ line: String) throws {
        throw CodexAppServerProcessError.closed
    }

    func terminate() {}
}

private final class CodexAppServerStdioTransport: CodexAppServerConnectionTransport {
    private let process: CodexAppServerManagedProcess

    init(process: CodexAppServerManagedProcess) {
        self.process = process
    }

    func sendLine(_ line: String) throws {
        try process.sendLine(line)
    }

    func close() {}
}

final class CodexAppServerWebSocketTransportConnector: CodexAppServerTransportConnecting {
    private static let defaultMaximumWebSocketFrameSizeBytes = 256 * 1024 * 1024

    private let group: EventLoopGroup
    private let ownsGroup: Bool
    private let maximumWebSocketFrameSizeBytes: Int

    init(group: EventLoopGroup? = nil,
         maximumWebSocketFrameSizeBytes: Int = CodexAppServerWebSocketTransportConnector.defaultMaximumWebSocketFrameSizeBytes) {
        self.maximumWebSocketFrameSizeBytes = maximumWebSocketFrameSizeBytes
        if let group {
            self.group = group
            self.ownsGroup = false
        } else {
            self.group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
            self.ownsGroup = true
        }
    }

    func connect(mode: CodexAppServerTransportMode,
                 onLine: @escaping @Sendable (String) -> Void,
                 onClose: @escaping @Sendable (Error?) -> Void) throws -> CodexAppServerConnectionTransport {
        guard case .unixSocket(let socketPath) = mode else {
            throw CodexAppServerTransportError.unsupported(mode)
        }

        let deadline = Date().addingTimeInterval(5)
        repeat {
            do {
                return try connectOnce(socketPath: socketPath,
                                       onLine: onLine,
                                       onClose: onClose)
            } catch {
                if Date() >= deadline {
                    throw error
                }
                Thread.sleep(forTimeInterval: 0.05)
            }
        } while true
    }

    private func connectOnce(socketPath: String,
                             onLine: @escaping @Sendable (String) -> Void,
                             onClose: @escaping @Sendable (Error?) -> Void) throws -> CodexAppServerConnectionTransport {
        let frameHandler = CodexAppServerWebSocketFrameHandler(onText: onLine,
                                                               onClose: onClose)
        let httpHandler = CodexAppServerWebSocketUpgradeRequestHandler(uri: "/")
        let upgradeState = CodexAppServerWebSocketUpgradeState()
        let upgrader = NIOWebSocketClientUpgrader(
            maxFrameSize: maximumWebSocketFrameSizeBytes,
            upgradePipelineHandler: { channel, _ in
                channel.pipeline.addHandler(frameHandler).map {
                    upgradeState.succeed()
                }
            }
        )
        let bootstrap = ClientBootstrap(group: group)
            .channelInitializer { channel in
                let upgradePromise = channel.eventLoop.makePromise(of: Void.self)
                upgradeState.attach(upgradePromise)
                channel.closeFuture.whenComplete { _ in
                    upgradeState.fail(CodexAppServerTransportError.closed)
                }
                let config: NIOHTTPClientUpgradeSendableConfiguration = (
                    upgraders: [upgrader],
                    completionHandler: { context in
                        context.pipeline.removeHandler(httpHandler, promise: nil)
                    }
                )
                return channel.pipeline.addHTTPClientHandlers(withClientUpgrade: config).flatMap {
                    channel.pipeline.addHandler(httpHandler)
                }
            }

        let channel = try bootstrap.connect(unixDomainSocketPath: socketPath).wait()
        try upgradeState.wait()
        return CodexAppServerWebSocketTransport(channel: channel)
    }

    deinit {
        if ownsGroup {
            try? group.syncShutdownGracefully()
        }
    }
}

private final class CodexAppServerWebSocketUpgradeState: @unchecked Sendable {
    private let lock = NSLock()
    private var promise: EventLoopPromise<Void>?
    private var completed = false

    func attach(_ promise: EventLoopPromise<Void>) {
        lock.lock()
        self.promise = promise
        let shouldComplete = completed
        lock.unlock()

        if shouldComplete {
            promise.succeed(())
        }
    }

    func succeed() {
        complete(.success(()))
    }

    func fail(_ error: Error) {
        complete(.failure(error))
    }

    func wait() throws {
        let future: EventLoopFuture<Void>
        lock.lock()
        guard let promise else {
            lock.unlock()
            throw CodexAppServerTransportError.closed
        }
        future = promise.futureResult
        lock.unlock()
        try future.wait()
    }

    private func complete(_ result: Result<Void, Error>) {
        lock.lock()
        guard completed == false else {
            lock.unlock()
            return
        }
        completed = true
        let promise = self.promise
        lock.unlock()

        switch result {
        case .success:
            promise?.succeed(())
        case .failure(let error):
            promise?.fail(error)
        }
    }
}

private final class CodexAppServerWebSocketUpgradeRequestHandler: ChannelInboundHandler, RemovableChannelHandler, Sendable {
    typealias InboundIn = HTTPClientResponsePart
    typealias OutboundOut = HTTPClientRequestPart

    private let uri: String

    init(uri: String) {
        self.uri = uri
    }

    func channelActive(context: ChannelHandlerContext) {
        var headers = HTTPHeaders()
        headers.add(name: "Host", value: "localhost")
        headers.add(name: "Content-Length", value: "0")
        let requestHead = HTTPRequestHead(version: .http1_1,
                                          method: .GET,
                                          uri: uri,
                                          headers: headers)
        context.write(Self.wrapOutboundOut(.head(requestHead)), promise: nil)
        context.write(Self.wrapOutboundOut(.body(.byteBuffer(context.channel.allocator.buffer(capacity: 0)))), promise: nil)
        context.writeAndFlush(Self.wrapOutboundOut(.end(nil)), promise: nil)
    }
}

private final class CodexAppServerWebSocketFrameHandler: ChannelInboundHandler, Sendable {
    typealias InboundIn = WebSocketFrame
    typealias OutboundOut = WebSocketFrame

    private let onText: @Sendable (String) -> Void
    private let onClose: @Sendable (Error?) -> Void

    init(onText: @escaping @Sendable (String) -> Void,
         onClose: @escaping @Sendable (Error?) -> Void) {
        self.onText = onText
        self.onClose = onClose
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = Self.unwrapInboundIn(data)
        switch frame.opcode {
        case .text:
            var data = frame.unmaskedData
            if let text = data.readString(length: data.readableBytes) {
                onText(text)
            }
        case .ping:
            let data = frame.unmaskedData
            let pong = WebSocketFrame(fin: true,
                                      opcode: .pong,
                                      maskKey: WebSocketMaskingKey.random(),
                                      data: data)
            context.writeAndFlush(Self.wrapOutboundOut(pong), promise: nil)
        case .connectionClose:
            onClose(nil)
            context.close(promise: nil)
        default:
            break
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        onClose(error)
        context.close(promise: nil)
    }
}

private final class CodexAppServerWebSocketTransport: CodexAppServerConnectionTransport {
    private let channel: Channel
    private let lock = NSLock()
    private var closed = false

    init(channel: Channel) {
        self.channel = channel
    }

    func sendLine(_ line: String) throws {
        lock.lock()
        guard closed == false else {
            lock.unlock()
            throw CodexAppServerTransportError.closed
        }
        lock.unlock()

        let payload = line.hasSuffix("\n") ? String(line.dropLast()) : line
        let buffer = channel.allocator.buffer(string: payload)
        let frame = WebSocketFrame(fin: true,
                                   opcode: .text,
                                   maskKey: WebSocketMaskingKey.random(),
                                   data: buffer)
        if channel.eventLoop.inEventLoop {
            let future = channel.writeAndFlush(frame)
            future.whenFailure { error in
                BridgeLogger.server.error("codex app-server websocket write failed error=\(String(describing: error), privacy: .public)")
            }
            return
        }
        channel.eventLoop.execute { [channel] in
            let future = channel.writeAndFlush(frame)
            future.whenFailure { error in
                BridgeLogger.server.error("codex app-server websocket write failed error=\(String(describing: error), privacy: .public)")
            }
        }
    }

    func close() {
        lock.lock()
        let shouldClose = closed == false
        closed = true
        lock.unlock()
        guard shouldClose else {
            return
        }
        _ = channel.close()
    }
}

final class CodexAppServerProcessRunner: CodexAppServerProcessRunning {
    func start(configuration: CodexAppServerLaunchConfiguration,
               onStdoutLine: @escaping @Sendable (String) -> Void,
               onStderrLine: @escaping @Sendable (String) -> Void,
               onExit: @escaping @Sendable (Int32) -> Void) throws -> CodexAppServerManagedProcess {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: configuration.executablePath)
        process.arguments = configuration.arguments
        process.currentDirectoryURL = URL(fileURLWithPath: configuration.workingDirectory)
        process.environment = ProcessInfo.processInfo.environment.merging(configuration.environment) { _, override in
            override
        }

        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let stdoutBuffer = CodexAppServerLineBuffer(onLine: onStdoutLine)
        let stderrBuffer = CodexAppServerLineBuffer(onLine: onStderrLine)

        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard data.isEmpty == false,
                  let text = String(data: data, encoding: .utf8) else {
                return
            }
            stdoutBuffer.append(text)
        }
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard data.isEmpty == false,
                  let text = String(data: data, encoding: .utf8) else {
                return
            }
            stderrBuffer.append(text)
        }

        let managedProcess = CodexAppServerProcess(process: process,
                                                   stdinHandle: inputPipe.fileHandleForWriting)
        process.terminationHandler = { process in
            outputPipe.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil
            stdoutBuffer.flush()
            stderrBuffer.flush()
            managedProcess.markTerminated()
            onExit(process.terminationStatus)
        }

        try process.run()
        return managedProcess
    }
}

private final class CodexAppServerProcess: CodexAppServerManagedProcess {
    private let process: Process
    private let stdinHandle: FileHandle
    private let lock = NSLock()
    private var terminated = false

    init(process: Process, stdinHandle: FileHandle) {
        self.process = process
        self.stdinHandle = stdinHandle
    }

    var processID: Int32? {
        process.processIdentifier
    }

    func sendLine(_ line: String) throws {
        guard let data = line.data(using: .utf8) else {
            throw CodexAppServerProcessError.invalidUTF8
        }
        lock.lock()
        guard terminated == false else {
            lock.unlock()
            throw CodexAppServerProcessError.closed
        }
        lock.unlock()
        try stdinHandle.write(contentsOf: data)
    }

    func terminate() {
        lock.lock()
        let shouldTerminate = terminated == false
        terminated = true
        lock.unlock()
        guard shouldTerminate else {
            return
        }
        try? stdinHandle.close()
        if process.isRunning {
            process.terminate()
        }
    }

    func markTerminated() {
        lock.lock()
        terminated = true
        lock.unlock()
        try? stdinHandle.close()
    }
}

private final class CodexAppServerConnectionLineRouter: @unchecked Sendable {
    private let lock = NSLock()
    private var connection: CodexAppServerConnection?
    private var pendingLines: [String] = []

    func attach(_ connection: CodexAppServerConnection) {
        lock.lock()
        self.connection = connection
        let pending = pendingLines
        pendingLines.removeAll()
        lock.unlock()

        for line in pending {
            connection.receiveLine(line)
        }
    }

    func receive(_ line: String) {
        lock.lock()
        guard let connection else {
            pendingLines.append(line)
            lock.unlock()
            return
        }
        lock.unlock()
        connection.receiveLine(line)
    }
}

private final class CodexAppServerTransportCloseRouter: @unchecked Sendable {
    private let lock = NSLock()
    private var session: CodexAppServerRuntimeSession?
    private var pendingClose: (didClose: Bool, error: Error?) = (false, nil)

    func attach(_ session: CodexAppServerRuntimeSession) {
        lock.lock()
        self.session = session
        let pendingClose = self.pendingClose
        self.pendingClose = (false, nil)
        lock.unlock()
        if pendingClose.didClose {
            session.handleTransportClosed(error: pendingClose.error)
        }
    }

    func receive(_ error: Error?) {
        lock.lock()
        guard let session else {
            pendingClose = (true, error)
            lock.unlock()
            return
        }
        lock.unlock()
        session.handleTransportClosed(error: error)
    }
}

private final class CodexAppServerRuntimeSessionExitRouter: @unchecked Sendable {
    private let lock = NSLock()
    private var session: CodexAppServerRuntimeSession?
    private var pendingExitCode: Int32?
    private let onExit: @Sendable (Int32) -> Void

    init(onExit: @escaping @Sendable (Int32) -> Void) {
        self.onExit = onExit
    }

    func attach(_ session: CodexAppServerRuntimeSession) {
        lock.lock()
        self.session = session
        let pending = pendingExitCode
        pendingExitCode = nil
        lock.unlock()

        if let pending {
            session.handleProcessExit(exitCode: pending)
            onExit(pending)
        }
    }

    func receive(_ exitCode: Int32) {
        lock.lock()
        guard let session else {
            pendingExitCode = exitCode
            lock.unlock()
            return
        }
        lock.unlock()

        session.handleProcessExit(exitCode: exitCode)
        onExit(exitCode)
    }
}

private final class CodexAppServerLineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = ""
    private let onLine: @Sendable (String) -> Void

    init(onLine: @escaping @Sendable (String) -> Void) {
        self.onLine = onLine
    }

    func append(_ text: String) {
        let lines = extractLines(appending: text)
        for line in lines {
            onLine(line)
        }
    }

    func flush() {
        let line: String?
        lock.lock()
        if pending.isEmpty {
            line = nil
        } else {
            line = pending
            pending = ""
        }
        lock.unlock()
        if let line {
            onLine(line)
        }
    }

    private func extractLines(appending text: String) -> [String] {
        lock.lock()
        pending.append(text)
        var lines: [String] = []
        while let newlineIndex = pending.firstIndex(of: "\n") {
            let line = String(pending[..<newlineIndex])
            lines.append(line)
            pending.removeSubrange(...newlineIndex)
        }
        lock.unlock()
        return lines
    }
}
