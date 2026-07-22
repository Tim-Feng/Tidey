import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOWebSocket

enum CodexAppServerProcessError: Error {
    case closed
    case invalidUTF8
}

// A turn/steer response was a JSON-RPC SUCCESS whose turnId doesn't match
// what was requested — a protocol violation / unknown semantic destination,
// NOT a definite zero-effect rejection (the server returned success, so it
// may have accepted the input somewhere). Deliberately NOT a
// CodexAppServerSubmitFailure case: it must fall into the generic
// "indeterminate" handling alongside transport close/timeout, never the
// safe-to-cancel/retry paths.
struct CodexAppServerTurnIDMismatchError: Error, Equatable {
    let expectedTurnID: String
    let observedTurnID: String?
}

// A successful turn/start response without a usable turnId cannot be
// treated as delivery success: the app-server may have accepted the input,
// but the Bridge has no authoritative identity with which to steer or
// reconcile its lifecycle. This is intentionally an indeterminate protocol
// error (not a definite zero-effect rejection), so callers never retry it
// automatically and the pending claim stays held fail-closed.
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
    // The transport cannot confirm this write without blocking its own event
    // loop; confirmed sends must fail closed instead of pretending success.
    case confirmationUnavailable
}

protocol CodexAppServerConnectionTransport: AnyObject {
    func sendLine(_ line: String) throws
    // Like sendLine, but does not return until the transport has accepted the
    // write (or throws when the write fails). Used for approval responses that
    // must not be treated as delivered on a best-effort enqueue.
    func sendLineAwaitingWrite(_ line: String) throws
    func close()
}

extension CodexAppServerConnectionTransport {
    func sendLineAwaitingWrite(_ line: String) throws {
        try sendLine(line)
    }
}

protocol CodexAppServerTransportConnecting {
    func connect(mode: CodexAppServerTransportMode,
                 onLine: @escaping @Sendable (String) -> Void,
                 onClose: @escaping @Sendable (Error?) -> Void) throws -> CodexAppServerConnectionTransport
}

final class CodexAppServerRuntimeSession {
    private static let subscriptionRetryBackoff: TimeInterval = 1.0

    private let process: CodexAppServerManagedProcess
    private let transport: CodexAppServerConnectionTransport
    private let connection: CodexAppServerConnection
    private let runtime: CodexAppServerHeadlessRuntime
    private let initialization: CodexAppServerInitializationState
    private let activeThreadStore: CodexAppServerActiveThreadStore
    private let turnStateStore: CodexAppServerTurnStateStore
    private let callbackQueue: DispatchQueue
    // Independent from `runtime`'s own internal `onWorkingControl` (which
    // only ever fires for LIVE notification-driven observations) — this is
    // this session's copy, used for the resume-snapshot seam below, which
    // is driven by a `thread/resume` RESPONSE, not a notification. Both
    // ultimately reach the SAME Syncer closure.
    private let onWorkingControl: CodexAppServerHeadlessRuntime.WorkingControlHandler
    private let timestampProvider: CodexAppServerConnection.TimestampProvider
    // The SINGLE lock for all of this session's mutable state: `stopped`
    // (finish-winner claim), `inFlightResumeControls`,
    // `controlTeardownComplete`, `finishWinnerThread`, and every
    // subscription-retry field below (`attachSubscriptionState`,
    // `nextSubscriptionRetryAt`, `registryRootThreadID`). Unified
    // deliberately: `stopped` used to be guarded by a SEPARATE `NSLock`
    // than the finish barrier's own condition, which meant
    // `beginSubscriptionAttempt`/`canRefreshActiveThread`/
    // `sendThreadResumeForSubscriptionIfNeeded` could observe a stale
    // `stopped` value racing the finish winner — a real data race, and it
    // broke the "no subscription attempt may proceed once finish has
    // claimed the session" fence this class depends on. One lock for both
    // concerns closes that gap; the extra contention between subscription
    // bookkeeping and the (rare) finish path is immaterial.
    //
    // Guards exactly: `stopped` (finish-winner claim), `inFlightResumeControls`
    // (reservations currently between "the exact-one-inProgress-turn resume
    // response was received" — reserved BEFORE the revision-fenced
    // turn-state seed even runs, since finish is the FIRST mutation gate,
    // not merely a gate on the later control emission — and "the
    // resume-snapshot control was actually delivered (or the seed/factory
    // guard rejected it)"), and `controlTeardownComplete` (the winner's own
    // control-phase teardown — ownerDisconnected delivered + connection.close()
    // run — is done).
    //
    // Resume-snapshot emission reserves a slot (rejected outright if
    // `stopped` is already true — 0 seed, 0 control), calls `onWorkingControl`
    // OUTSIDE the lock, then releases its slot. The finish winner marks
    // `stopped` FIRST (locking out all FUTURE reservations), then waits for
    // every reservation that got in before it to drain to zero, THEN (still
    // outside the lock) delivers its own single `ownerDisconnected` and
    // calls `connection.close()`. This ordering is exactly what gives:
    // "resume reserves first" -> open, then owner terminal (strictly
    // after); "finish claims first" -> the late resume reservation sees
    // `stopped == true` and never emits at all. No external callback is
    // ever invoked while `finishCondition` is held.
    private let finishCondition = NSCondition()
    private var stopped = false
    // A bare in-flight count is sufficient: there is no PRODUCTION path
    // where `onWorkingControl(.resumeSnapshot)` synchronously calls back
    // into this session's own `stop()` (the Syncer's live-control handling
    // never re-enters the RuntimeSession; the Hub schedules subscriber
    // delivery asynchronously). Per-thread reservation tracking to guard
    // against a purely synthetic same-thread self-stop callback was
    // considered and deliberately dropped — it added real complexity
    // (deferred teardown execution, an extra exactly-once guard) for a
    // scenario outside this session's actual call-graph contract.
    private var inFlightResumeControls = 0
    // Set once the finish winner's OWN control-phase teardown (the
    // ownerDisconnected delivery + connection.close()) has completed —
    // NOT once transport/process cleanup has finished. The public `stop()`
    // caller waits for exactly this (not full teardown) before returning:
    // by this point a new Syncer attach/incarnation-begin is already safe,
    // since the old owner's terminal is guaranteed to have already reached
    // the Hub.
    private var controlTeardownComplete = false
    // The thread currently running the winner's teardown body (between
    // claiming `stopped = true` and `connection.close()` returning).
    // `connection.close()` synchronously expires pending prompts, invoking
    // arbitrary client-response handlers — one of which can call PUBLIC
    // `stop()` reentrantly, on this SAME thread, before this very call
    // returns. If that reentrant `stop()` waited for
    // `controlTeardownComplete` (which only the winner — this exact,
    // currently-blocked call — could ever set), it would self-deadlock. A
    // reentrant call is identified by thread identity: only a `stop()`
    // arriving on a DIFFERENT thread still waits; one on this thread
    // returns immediately (its work is redundant — the winner it's nested
    // inside already IS the teardown).
    private var finishWinnerThread: Thread?
    private var attachSubscriptionState = AttachSubscriptionState.noLoadedThread
    private var nextSubscriptionRetryAt: Date?
    // The registry's AUTHORITATIVE root thread for this session, provided at
    // attach time. Used only as a subscription fallback when the app-server
    // cannot uniquely resolve a loaded root itself. Never written from
    // app-server notifications — a subagent thread can never rebind it.
    private var registryRootThreadID: String?
    // Test seam: invoked while an unresolved loaded-list callback is being
    // processed, before the subscription state transition commits.
    var loadedThreadUnresolvedHook: (() -> Void)?
    // Test-only: fires on the finish winner's thread AFTER `stopped` has
    // been claimed and every resume reservation has drained, but BEFORE
    // `onWorkingControl(.ownerDisconnected)`/`connection.close()` run. Lets
    // a test deterministically pause mid-teardown (e.g. block here on a
    // semaphore) to prove a LATE resume response arriving during that exact
    // window is correctly rejected by `reserveResumeControlEmission`
    // (`stopped` already true) rather than by an accident of timing.
    var finishTeardownPauseHook: (() -> Void)?
    // Test-only: fires ONLY when `seedActiveTurnFromResumeIfUnchanged`
    // actually returned `true` (the turn-state store was genuinely
    // mutated) — lets a test assert the seed did NOT apply for a
    // finish-first/stale/rejected response, independent of the typed
    // control outcome.
    var resumeSnapshotSeedAppliedHook: (() -> Void)?
    // Test-only: fires immediately once `seedActiveTurnFromResumeSnapshot`
    // has acquired the finish-linearization reservation (before ANY of its
    // three branches — exact-one seed, active bookkeeping, idle
    // reconciliation — run). This hook NOT firing shows the response never
    // reached any branch at all, but is NOT by itself sufficient proof of
    // zero mutation for the active/idle branches — a regression that moved
    // the reservation to wrap only the exact-one branch would ALSO leave
    // this hook unfired for those two (since they'd never reach it either),
    // while still running unguarded and mutating the store. A test must
    // pair this hook with `resumeSnapshotSeedAppliedHook`/
    // `resumeSnapshotBookkeepingAppliedHook` (see below) to establish that
    // proof — this hook alone only shows where a rejection happened, not
    // that every branch was actually gated.
    var resumeSnapshotReservationAcquiredHook: (() -> Void)?
    // Test-only: fires ONLY when `markThreadActiveIfUnchanged` or
    // `markThreadIdleIfUnchanged` actually returned `true` — i.e. the
    // turn-store bookkeeping DID apply a mutation. Does NOT prove the
    // method was never attempted (it fires only after a `true` return, so a
    // rejected/no-op call is silent either way) — the active/idle-branch
    // counterpart of `resumeSnapshotSeedAppliedHook`. Needed because these
    // two branches have no OTHER externally observable success signal (no
    // typed control is ever emitted for them, by design): pairing this hook
    // with `resumeSnapshotReservationAcquiredHook` is what actually proves
    // a finish-first late response mutated nothing — the reservation hook
    // alone cannot distinguish "the branch correctly ran and mutated
    // nothing" from "the branch's own reservation call was simply never
    // reached" (see that hook's own doc comment).
    var resumeSnapshotBookkeepingAppliedHook: (() -> Void)?
    // Test-only: fires on `callbackQueue` immediately AFTER
    // `handleLoadedThreadSubscriptionResult` returns — i.e. once a late
    // `thread/loaded/list` response has been FULLY processed (including
    // any `onActiveThreadID` forwarding and, potentially, sending a
    // `thread/resume` request), not merely dispatched. `TestHookBox`
    // lock-protects both the read (at fire time) and the write (a test
    // installing it), since the install can race the fire across queues.
    // Holds neither `finishCondition` nor any connection lock when it
    // fires. Lets a test prove a late loaded-list response was genuinely
    // handled to completion before asserting on its outbound side effects
    // — asserting right after `onActiveThreadID` alone would leave a
    // false-green window, since `thread/resume` (if any) is sent AFTER
    // that callback within the same handler.
    private let loadedThreadSubscriptionResultProcessedHook = TestHookBox()
    func setLoadedThreadSubscriptionResultProcessedHookForTesting(_ hook: (() -> Void)?) {
        loadedThreadSubscriptionResultProcessedHook.set(hook)
    }

    // Test-only: reads `attachSubscriptionState`/`nextSubscriptionRetryAt`
    // together under a single `finishCondition` lock hold, so a test can
    // assert the exact typed subscription state a response handler left
    // behind without racing a concurrent transition or observing the two
    // fields torn across separate lock acquisitions.
    struct SubscriptionDiagnosticSnapshotForTesting {
        let state: AttachSubscriptionState
        let nextRetryAt: Date?
    }
    func subscriptionDiagnosticSnapshotForTesting() -> SubscriptionDiagnosticSnapshotForTesting {
        finishCondition.lock()
        defer { finishCondition.unlock() }
        return SubscriptionDiagnosticSnapshotForTesting(state: attachSubscriptionState, nextRetryAt: nextSubscriptionRetryAt)
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
         transport: CodexAppServerConnectionTransport,
         connection: CodexAppServerConnection,
         runtime: CodexAppServerHeadlessRuntime,
         initialization: CodexAppServerInitializationState = CodexAppServerInitializationState(),
         activeThreadStore: CodexAppServerActiveThreadStore = CodexAppServerActiveThreadStore(),
         turnStateStore: CodexAppServerTurnStateStore = CodexAppServerTurnStateStore(),
         callbackQueue: DispatchQueue = DispatchQueue(label: "com.tidey.remote-bridge.codex-app-server-runtime-session"),
         onWorkingControl: @escaping CodexAppServerHeadlessRuntime.WorkingControlHandler = { _ in },
         timestampProvider: @escaping CodexAppServerConnection.TimestampProvider) {
        self.process = process
        self.transport = transport
        self.connection = connection
        self.runtime = runtime
        self.initialization = initialization
        self.activeThreadStore = activeThreadStore
        self.turnStateStore = turnStateStore
        self.callbackQueue = callbackQueue
        self.onWorkingControl = onWorkingControl
        self.timestampProvider = timestampProvider
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
        // Order fence for the turn-state store's active-turn seeding below
        // (see seedActiveTurnFromResumeSnapshot): captured BEFORE the
        // request goes out, so a live turn/started, turn/completed, or
        // remote-submit claim accepted after this point invalidates the
        // (older) response snapshot.
        let turnStateBarrier = turnStateStore.revisionBarrier(threadID: threadID)
        return try runtime.resumeThread(on: connection,
                                        threadID: threadID,
                                        cwd: cwd,
                                        onResponse: { [weak self] response in
                                            if case .success(let payload) = response {
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
    // happens to complete on its own.
    //
    // Deliberately narrow: only seeds when the snapshot is UNAMBIGUOUS
    // (response thread.id matches the requested thread, `turns` is an
    // actual array, and exactly ONE raw entry has status == "inProgress"
    // AND that entry has a nonblank id) and only when `barrier` proves
    // nothing has mutated this thread's turn state since the request was
    // sent (see CodexAppServerTurnStateStore's revision fence) — a stale
    // response racing a live completion, a newer turn/started, or a remote
    // submit's own claim must never resurrect/overwrite that newer state.
    // Zero raw in-progress turns still reconciles the store's compatible
    // active/idle bookkeeping (`markThreadActiveIfUnchanged`/
    // `markThreadIdleIfUnchanged`) from `thread.status.type`; a raw
    // in-progress count other than exactly one (including a single entry
    // with a BLANK id, or a missing/non-array `turns`) never guesses a turn
    // id AND never reconciles idle either — only the exact-zero and
    // exact-one shapes are trustworthy enough to act on. A thread id
    // mismatch or an advanced barrier is silently skipped entirely: the
    // existing safe busyWithoutTurnID fallback still applies — never guess,
    // never terminal-fallback.
    private func seedActiveTurnFromResumeSnapshot(_ payload: JSONValue, threadID: String, barrier: CodexAppServerTurnStateStore.RevisionBarrier) {
        guard let thread = payload.objectValue?["thread"]?.objectValue,
              thread["id"]?.stringValue == threadID else {
            return
        }
        // Raw shape fence: `turns` must be an ACTUAL array. A missing or
        // non-array `turns` must never be silently treated as "zero
        // turns" — that would let idle reconciliation clear busy state from
        // a response that couldn't actually be read, and would let the
        // exact-one path never even apply (fine there) but for the wrong
        // reason (fine to reject, wrong to conflate with genuine zero).
        guard let turns = thread["turns"]?.arrayValue else {
            return
        }
        // Raw in-progress COUNT — every entry whose status == "inProgress",
        // regardless of whether its id is nonblank. This is deliberately
        // separate from valid-ID extraction: `[valid A, blank-ID
        // inProgress]` is a raw count of 2 (ambiguous), not a false unique
        // A — and a lone blank-ID inProgress entry is a raw count of 1, so
        // it can never be misread as "zero turns" for idle reconciliation
        // either.
        let inProgressTurns = turns.filter { $0.objectValue?["status"]?.stringValue == "inProgress" }

        // Finish-linearization is the FIRST mutation gate for EVERY branch
        // below (exact-one seed, active bookkeeping, idle reconciliation) —
        // ONE reservation, not a per-branch guard. A finish that already
        // claimed `stopped` must prevent this response from mutating ANY
        // turn-store state for a session that's already being torn down: 0
        // seed, 0 bookkeeping, 0 control, 0 cursor.
        guard reserveResumeControlEmission() else {
            return
        }
        defer { releaseResumeControlEmission() }
        resumeSnapshotReservationAcquiredHook?()

        if inProgressTurns.count == 1 {
            let rawTurnID = inProgressTurns[0].objectValue?["id"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let turnID = rawTurnID, turnID.isEmpty == false {
                // Revision-fenced: only when the seed ACTUALLY applied
                // (nothing mutated this thread's turn state since the
                // request went out) may a `.resumeSnapshot` control
                // observation be emitted. A stale/superseded response —
                // barrier already invalidated by a live turn/started,
                // turn/completed, or a remote submit's own claim — must
                // produce ZERO control/cursor effect, exactly like any
                // other rejected observation.
                guard turnStateStore.seedActiveTurnFromResumeIfUnchanged(threadID: threadID, turnID: turnID, barrier: barrier) else {
                    return
                }
                resumeSnapshotSeedAppliedHook?()
                guard let control = CodexAppServerWorkingControlFactory.resumeSnapshot(threadID: threadID, turnID: turnID, time: timestampProvider()) else {
                    return
                }
                onWorkingControl(control)
                return
            }
            // A single inProgress turn with a BLANK id: falls through to
            // the shared active/idle bookkeeping below exactly like any
            // other non-exact-one shape — never guessed, and (since
            // `inProgressTurns.isEmpty` is false here) never reconciled as
            // idle either.
        }
        // Zero OR ambiguous (including blank-ID) inProgress turns: never
        // guess which one to steer into. But if the snapshot's own
        // thread.status still says the thread IS active/busy, the
        // thread-state store must still learn that — regardless of
        // turn-count ambiguity or malformed ids — otherwise routeSubmit()
        // would wrongly treat this thread as IDLE (no pending claim, no
        // turn, no active status) and issue a colliding turn/start into a
        // thread the app-server already considers busy.
        let statusType = thread["status"]?.objectValue?["type"]?.stringValue
        if statusType == "active" {
            if turnStateStore.markThreadActiveIfUnchanged(threadID: threadID, barrier: barrier) {
                resumeSnapshotBookkeepingAppliedHook?()
            }
            return
        }
        // Idle reconciliation is narrower than the active branch above:
        // only when the snapshot is ALSO unambiguous — the RAW in-progress
        // count is genuinely zero, not merely "no valid id extracted". Idle
        // alongside any reported in-progress turn (valid id or not) is a
        // contradictory shape, not a trustworthy idle signal, and must stay
        // a no-op exactly like before this fix. Clears any
        // compatible-but-now-obsolete `threadStatusActiveStartedAt` a
        // racing live ACTIVE notification left behind (see
        // `markThreadActive`'s deliberately weak, non-invalidating `state`-
        // dimension behavior) — without this, a thread that raced
        // active-then-idle entirely BEFORE its own resume response arrived
        // would be left permanently busy-without-turn-id, since
        // `.subscribed` never retries. `markThreadIdleIfUnchanged` itself
        // additionally requires the `activeEvidence` barrier dimension
        // unchanged — a fresh "active" notification arriving AFTER this
        // barrier was captured still blocks this stale idle snapshot from
        // clearing it (see that method's own doc comment).
        if statusType == "idle", inProgressTurns.isEmpty {
            if turnStateStore.markThreadIdleIfUnchanged(threadID: threadID, barrier: barrier) {
                resumeSnapshotBookkeepingAppliedHook?()
            }
        }
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
    func submitApproval(promptID: String,
                        targetIndex: Int,
                        clientRequestID: String?,
                        lifecycleToken: String?) throws -> CodexAppServerApprovalSubmitOutcome {
        try connection.submitApproval(promptID: promptID,
                                      targetIndex: targetIndex,
                                      clientRequestID: clientRequestID,
                                      lifecycleToken: lifecycleToken)
    }

    func pendingApprovalPromptEvents() -> [AgentEvent] {
        connection.pendingApprovalPromptEvents()
    }

    // A request write is not acceptance: sendClientRequest returns as soon
    // as the request is encoded/written, but the AUTHORITATIVE outcome
    // (accepted, or a JSON-RPC error response) arrives later via
    // handleClientResponse. A bounded wait here is what lets this function
    // distinguish "app-server accepted the turn" from "app-server
    // definitively rejected it" from "no answer arrived in time" —
    // returning immediately after the write would report false success for
    // an app-server that goes on to reject the request.
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
                                              // Reconcile inside the durable connection callback, BEFORE
                                              // waking the bounded waiter. The callback can still arrive
                                              // after submitMessage() has timed out and returned; doing the
                                              // state transition here means that late authoritative outcome
                                              // is not lost.
                                              switch result {
                                              case .success(let payload):
                                                  if let turnID = Self.normalizedTurnID(from: payload) {
                                                      turnStateStore.reconcileAcceptedStart(threadID: threadID,
                                                                                            claimID: claimID,
                                                                                            turnID: turnID)
                                                  }
                                              case .failure(.requestFailed):
                                                  // A definitive rejection is zero-effect, but only for
                                                  // THIS claim. A late P1 response must never release P2.
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

    // Fail closed: blank/whitespace identities are never stored, and a nil
    // or blank update never clears an existing valid binding.
    func setRegistryRootThreadID(_ rawThreadID: String?) {
        guard let trimmed = rawThreadID?.trimmingCharacters(in: .whitespacesAndNewlines),
              trimmed.isEmpty == false else {
            return
        }
        finishCondition.lock()
        registryRootThreadID = trimmed
        finishCondition.unlock()
        // A LATE root delivery re-arms the subscription by itself: the
        // attach-time loaded/list may already have come back unresolvable
        // and parked the session on no_loaded_thread before this setter ran.
        // Timing safety: initialization pending -> the first attempt after
        // ready sees the stored root; a list request in flight (resumePending)
        // or an existing subscription -> beginSubscriptionAttempt declines;
        // no_loaded_thread/failed -> resume the root now (backoff honored).
        guard case .ready = initialization.diagnosticStatus() else {
            return
        }
        guard beginSubscriptionAttempt() else {
            return
        }
        // The re-armed subscription is about to resume this root: bind it as
        // the active thread too, exactly like the loaded-list path does —
        // otherwise approvals would flow while submitMessage still reports
        // "thread not ready".
        activeThreadStore.setThreadID(trimmed)
        sendThreadResumeForSubscription(threadID: trimmed)
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

    // Reserves a slot for resume-snapshot turn-store reconciliation, unless
    // finish() has already claimed the session. Called ONCE at the top of
    // `seedActiveTurnFromResumeSnapshot`, wrapping ALL THREE of its
    // branches (exact-one seed, active bookkeeping, idle reconciliation) —
    // BEFORE any of their revision-fenced store mutations run — finish is
    // the FIRST mutation gate, not merely a gate on the later control
    // emission (a finish-first response must not mutate the dead session's
    // turn-state routing either, regardless of which branch it would have
    // taken). MUST be paired with `releaseResumeControlEmission()` at the
    // call site (a `defer`) — see `finishCondition`'s doc comment for the
    // full ordering argument.
    private func reserveResumeControlEmission() -> Bool {
        finishCondition.lock()
        defer { finishCondition.unlock() }
        guard stopped == false else {
            return false
        }
        inFlightResumeControls += 1
        return true
    }

    private func releaseResumeControlEmission() {
        finishCondition.lock()
        inFlightResumeControls -= 1
        if inFlightResumeControls == 0 {
            finishCondition.broadcast()
        }
        finishCondition.unlock()
    }

    // Single finish-winner implementation shared by every termination
    // trigger (explicit Syncer stop, process exit, transport close,
    // protocol violation) — each maps to its own `reason` and post-signal
    // `cleanup` (see each public wrapper below), but the winner
    // arbitration, resume-reservation drain, and ownerDisconnected/
    // connection.close() ordering are identical for all of them.
    //
    // `waitForTeardown` distinguishes the ONE caller that may safely block
    // on a lost race (the public `stop()`, called from the Syncer) from
    // every INTERNAL trigger (process exit / transport close / protocol
    // violation), which must return immediately without waiting if it
    // loses — `connection.close()`/transport teardown run by the ACTUAL
    // winner can re-enter these same internal handlers synchronously on the
    // winner's own call stack, and waiting there would self-deadlock.
    //
    // A SEPARATE hazard applies even to the waiting public `stop()`:
    // `connection.close()` (called below, still inside the winner's own
    // call) synchronously expires pending prompts and invokes their
    // client-response handlers, one of which can itself call public
    // `stop()` reentrantly — on this SAME thread, before this very call
    // returns. `finishWinnerThread` identifies that thread: a `stop()` that
    // loses the race but is running on the winner's own thread returns
    // immediately without waiting (waiting would deadlock, since the
    // winner blocked in that same call can never reach the point where it
    // sets `controlTeardownComplete`); a `stop()` losing from any OTHER
    // thread still waits, unaffected.
    //
    // There is no production path where `onWorkingControl(.resumeSnapshot)`
    // synchronously calls back into this session's own `stop()` (the
    // Syncer's live-control handling never re-enters the RuntimeSession;
    // the Hub schedules subscriber delivery asynchronously) — so the
    // winner waiting for `inFlightResumeControls` to drain to zero
    // (unconditionally, not excluding its own thread) cannot deadlock in
    // practice.
    private func finish(reason: CodexAppServerOwnerDisconnectReason,
                        waitForTeardown: Bool,
                        cleanup: () -> Void) {
        finishCondition.lock()
        guard stopped == false else {
            let isReentrantOnWinnerThread = finishWinnerThread === Thread.current
            if waitForTeardown, isReentrantOnWinnerThread == false {
                while controlTeardownComplete == false {
                    finishCondition.wait()
                }
            }
            finishCondition.unlock()
            return
        }
        stopped = true
        finishWinnerThread = Thread.current
        // Wait for every resume-control reservation that got in BEFORE this
        // winner claimed `stopped` to fully drain — this is what guarantees
        // "resume reserved first" always delivers its open strictly before
        // this winner's own owner-scoped terminal.
        while inFlightResumeControls > 0 {
            finishCondition.wait()
        }
        finishCondition.unlock()

        // Test-only pause point: `stopped` is already claimed and every
        // reservation that got in first has drained, but the actual
        // ownerDisconnected/connection.close() has not run yet — a test
        // can block here to deterministically prove a request arriving
        // during exactly this window is rejected by the `stopped` check
        // rather than by incidental timing.
        finishTeardownPauseHook?()

        // Everything below runs OUTSIDE finishCondition — no external
        // callback (onWorkingControl) or lock-taking call (connection.close())
        // is ever invoked while the lock is held. `connection.close()` may
        // reenter `stop()` synchronously (see the doc comment above) — that
        // reentrant call finds `stopped == true` and, running on this exact
        // thread, returns immediately rather than waiting.
        initialization.fail(CodexAppServerConnectionError.closed)
        onWorkingControl(.ownerDisconnected(reason: reason, time: timestampProvider()))
        connection.close()

        finishCondition.lock()
        controlTeardownComplete = true
        finishCondition.broadcast()
        finishCondition.unlock()

        // Full transport/process cleanup may continue after signaling —
        // any caller waiting on `controlTeardownComplete` has already been
        // released. This can ALSO reenter an internal handler (e.g.
        // transport.close() synchronously invoking its own onClose ->
        // handleTransportClosed) on this same thread — those are
        // `waitForTeardown: false` unconditionally, so they already never
        // wait regardless of thread identity.
        cleanup()
    }

    func stop() {
        finish(reason: .sessionRetired, waitForTeardown: true) { [transport, process] in
            transport.close()
            process.terminate()
        }
    }

    func handleProcessExit(exitCode: Int32) {
        finish(reason: .processExited, waitForTeardown: false) {
            // The process already exited — nothing further to terminate.
        }
    }

    func isStopped() -> Bool {
        finishCondition.lock()
        defer { finishCondition.unlock() }
        return stopped
    }

    // The app-server process may still be alive while this client channel
    // died. Tear the session down exactly once: connection.close() expires
    // the pending approvals (visible on Remote), and the syncer re-attaches
    // to the same still-living app-server epoch on its next registry scan.
    // A JSON-RPC protocol violation must stop this runtime GENERATION for
    // real: connection retired, transport aborted, and — for an owned stdio
    // process, whose transport cannot be closed separately — the process
    // terminated. For attached external processes `process.terminate()` is a
    // no-op by construction, so the server itself is never killed. This is
    // an INTERNAL trigger (not the Syncer's own `stop()` call), so a lost
    // race must not wait.
    func handleProtocolViolation() {
        BridgeLogger.server.error("codex app-server protocol violation: stopping runtime session session_id=\(self.runtime.contextSessionID, privacy: .public)")
        finish(reason: .transportClosed, waitForTeardown: false) { [transport, process] in
            transport.close()
            process.terminate()
        }
    }

    func handleTransportClosed(error: Error?) {
        BridgeLogger.server.error("codex app-server transport closed session_id=\(self.runtime.contextSessionID, privacy: .public) error=\(String(describing: error), privacy: .public)")
        finish(reason: .transportClosed, waitForTeardown: false) { [transport] in
            transport.close()
        }
    }

    func whenInitialized(_ callback: @escaping @Sendable (Result<Void, Error>) -> Void) {
        initialization.notify(callback)
    }

    private func beginSubscriptionAttempt() -> Bool {
        finishCondition.lock()
        guard stopped == false else {
            finishCondition.unlock()
            return false
        }
        if let nextSubscriptionRetryAt, nextSubscriptionRetryAt > Date() {
            finishCondition.unlock()
            return false
        }
        guard attachSubscriptionState.shouldRetry else {
            finishCondition.unlock()
            return false
        }
        let previousState = attachSubscriptionState
        nextSubscriptionRetryAt = nil
        attachSubscriptionState = .resumePending
        finishCondition.unlock()
        logAttachSubscriptionTransition(from: previousState,
                                        to: .resumePending,
                                        reason: "ensure_retry")
        return true
    }

    private func canRefreshActiveThread() -> Bool {
        finishCondition.lock()
        defer { finishCondition.unlock() }
        guard stopped == false else {
            return false
        }
        if case .subscribed = attachSubscriptionState {
            return true
        }
        return false
    }

    private func setAttachSubscriptionState(_ state: AttachSubscriptionState, reason: String) {
        finishCondition.lock()
        let previousState = attachSubscriptionState
        attachSubscriptionState = state
        finishCondition.unlock()
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
                    self.loadedThreadSubscriptionResultProcessedHook.fire()
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
            guard let threadID = codexAppServerLoadedThreadID(from: value) else {
                BridgeLogger.server.debug("codex app-server subscription no loaded thread shape=\(codexAppServerLoadedThreadShapeDescription(from: value), privacy: .public)")
                if clearSubscriptionOnMissing {
                    // The app-server could not present a UNIQUE loaded root
                    // (empty, paginated, ambiguous) — but the registry may
                    // already hold this session's authoritative root thread.
                    // Resume that instead of parking on loaded_thread_missing
                    // forever while approvals stay invisible to Remote.
                    loadedThreadUnresolvedHook?()
                    // Atomic [fallback read + park]: a late setter either
                    // landed BEFORE this lock (visible here, resumed below)
                    // or lands AFTER the park (sees no_loaded_thread and
                    // re-arms itself). No interleaving loses the wakeup, and
                    // only one side ever sends the resume.
                    finishCondition.lock()
                    let fallbackThreadID = registryRootThreadID
                    let previousState = attachSubscriptionState
                    if fallbackThreadID == nil {
                        attachSubscriptionState = .noLoadedThread
                    }
                    finishCondition.unlock()
                    if let fallbackThreadID {
                        BridgeLogger.server.info("codex app-server subscription falling back to registry root thread session_id=\(self.runtime.contextSessionID, privacy: .public) thread_id=\(fallbackThreadID, privacy: .public)")
                        activeThreadStore.setThreadID(fallbackThreadID)
                        sendThreadResumeForSubscriptionIfNeeded(threadID: fallbackThreadID,
                                                                reason: "registry_root_fallback")
                        return
                    }
                    logAttachSubscriptionTransition(from: previousState,
                                                    to: .noLoadedThread,
                                                    reason: "loaded_thread_missing")
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
        finishCondition.lock()
        guard stopped == false else {
            finishCondition.unlock()
            return
        }
        if case .subscribed(let existingThreadID) = attachSubscriptionState {
            if existingThreadID == threadID {
                finishCondition.unlock()
                return
            }
            finishCondition.unlock()
            // Codex 0.144.1 thread/resume is ADDITIVE (no unsubscribe): a
            // resume(B) on a connection already subscribed to A would keep
            // BOTH threads' approvals flowing into this session. Fail closed:
            // stop this runtime — the syncer's isStopped() replacement path
            // attaches a fresh generation that subscribes only the new root.
            // The new root is already recorded via the active-thread store.
            BridgeLogger.server.error("codex app-server subscription root changed while subscribed session_id=\(self.runtime.contextSessionID, privacy: .public) from=\(existingThreadID, privacy: .public) to=\(threadID, privacy: .public) reason=\(reason, privacy: .public) action=stop_for_replacement")
            stop()
            return
        }
        let previousState = attachSubscriptionState
        attachSubscriptionState = .resumePending
        finishCondition.unlock()
        logAttachSubscriptionTransition(from: previousState, to: .resumePending, reason: reason)
        sendThreadResumeForSubscription(threadID: threadID)
    }

    private func sendThreadResumeForSubscription(threadID: String) {
        BridgeLogger.server.debug("codex app-server diagnostic resume request session_id=\(self.runtime.contextSessionID, privacy: .public) thread_id=\(threadID, privacy: .public) request_has_approvalsReviewer=false cwd=- source=subscription_ensure")
        // Order fence for the turn-state store's active-turn seeding (see
        // resumeThread / seedActiveTurnFromResumeSnapshot).
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
                                                    self?.setAttachSubscriptionState(.subscribed(threadID: threadID), reason: "thread_resume_success")
                                                    self?.seedActiveTurnFromResumeSnapshot(payload,
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
        finishCondition.lock()
        nextSubscriptionRetryAt = Date().addingTimeInterval(Self.subscriptionRetryBackoff)
        finishCondition.unlock()
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
        // may be a late terminal for an older turn), so remember the exact
        // turn ID until this claim's response supplies the identity. The
        // active-evidence revision lets that later reconciliation clear
        // only evidence no newer ACTIVE edge has superseded.
        var completedTurnActiveEvidenceRevisions: [String: Int] = [:]
    }

    private struct State {
        var pendingSubmit: PendingSubmit?
        var turn: TurnActivity?
        var threadStatusActiveStartedAt: Date?

        var isBusy: Bool {
            pendingSubmit != nil || turn != nil || threadStatusActiveStartedAt != nil
        }

        // Returns whether pruning actually changed anything — the caller
        // uses this to bump the revision fence exactly like any other
        // state mutation (see CodexAppServerTurnStateStore.pruneExpiredLocked):
        // a thread/resume response racing a timeout-based expiry must be
        // invalidated too, otherwise it could resurrect state the store
        // already gave up on as stale.
        @discardableResult
        mutating func pruneExpired(now: Date, timeout: TimeInterval) -> Bool {
            var changed = false
            if let pendingSubmit,
               now.timeIntervalSince(pendingSubmit.startedAt) >= timeout {
                self.pendingSubmit = nil
                changed = true
            }
            if let activeTurn = turn,
               now.timeIntervalSince(activeTurn.startedAt) >= timeout {
                turn = nil
                changed = true
            }
            if let startedAt = threadStatusActiveStartedAt,
               now.timeIntervalSince(startedAt) >= timeout {
                threadStatusActiveStartedAt = nil
                changed = true
            }
            return changed
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
    // A SECOND, independent dimension: bumped ONLY by `markThreadActive`'s
    // live "active" notification (see its own doc comment — deliberately
    // NOT part of `revisionsByThreadID`, so it never invalidates the
    // exact-one resume seed). This dimension exists so a DIFFERENT
    // operation — clearing evidence, not just setting it — can still be
    // fenced against it: `markThreadIdleIfUnchanged` requires BOTH
    // dimensions unchanged, because a stale idle+zero-turns resume response
    // has no downstream identity protection (unlike the exact-one seed,
    // where a subsequent `turn/steer(expectedTurnId:)` still gets rejected
    // server-side if the turn id is wrong) — it must never clear active
    // evidence that a live "active" notification established AFTER the
    // barrier was captured, or the next submit would issue a colliding
    // turn/start into a thread the app-server still considers busy.
    // Deliberately NEVER cleared either, for the same reason as above.
    private var activeEvidenceRevisionsByThreadID: [String: Int] = [:]

    init(timeout: TimeInterval = 15 * 60,
         now: @escaping () -> Date = Date.init) {
        self.timeout = timeout
        self.now = now
    }

    // Captured atomically (one lock hold) BEFORE sending a thread/resume
    // request. `state` is the identity/state-invalidation dimension the
    // exact-one seed and the active-bookkeeping branch check; `activeEvidence`
    // is the SECOND dimension only `markThreadIdleIfUnchanged` additionally
    // requires unchanged (see `activeEvidenceRevisionsByThreadID`'s doc
    // comment above).
    struct RevisionBarrier: Equatable {
        let state: Int
        let activeEvidence: Int
    }

    func revisionBarrier(threadID: String) -> RevisionBarrier {
        lock.lock()
        defer { lock.unlock() }
        return RevisionBarrier(state: revisionsByThreadID[threadID] ?? 0,
                               activeEvidence: activeEvidenceRevisionsByThreadID[threadID] ?? 0)
    }

    // Seeds the active turn observed in a thread/resume response — ONLY if
    // this thread's turn state has not advanced (no claim, no turn/started,
    // no turn/completed, no IDLE thread-status edge) since `barrier` was
    // captured right before the resume request was sent. A stale response
    // racing a live completion, a newer turn/started, or a remote submit's
    // own claim must never resurrect/overwrite that newer state — the
    // revision check and the mutation happen under ONE lock hold, so there
    // is no TOCTOU window between "barrier looked valid" and "the seed was
    // actually applied." NOTE: a live ACTIVE thread-status edge is
    // deliberately weak/compatible evidence and does NOT bump the `state`
    // dimension (see `markThreadActive`) — only IDLE, a live turn/started/
    // completed, or a submit's own claim genuinely invalidate this barrier.
    // Deliberately checks ONLY `barrier.state`, never `barrier.activeEvidence`
    // — a later live "active" notification is safe to race here because a
    // subsequent `turn/steer(expectedTurnId:)` still has server-side
    // identity protection against steering into the wrong turn.
    @discardableResult
    func seedActiveTurnFromResumeIfUnchanged(threadID: String, turnID: String, barrier: RevisionBarrier) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        pruneExpiredLocked(now: now())
        guard (revisionsByThreadID[threadID] ?? 0) == barrier.state else {
            return false
        }
        var state = statesByThreadID[threadID] ?? State()
        // If a remote submit already owns the thread, this exact-one
        // snapshot is the authoritative identity recovery for that claim:
        // Codex can omit the live turn/started edge when the Bridge's
        // subscription becomes ready after the turn began. Transfer the
        // claim into a known remote-origin turn instead of retaining two
        // independent busy flags. Keeping the claim would strand the
        // thread as busyWithoutTurnID after the matching completion clears
        // the recovered turn.
        if let terminalActiveRevision = state.pendingSubmit?.completedTurnActiveEvidenceRevisions[turnID] {
            // The matching terminal arrived before this snapshot exposed
            // the identity. Retire the claim but never resurrect an already
            // completed turn or emit a resume-open control for it.
            state.pendingSubmit = nil
            if (activeEvidenceRevisionsByThreadID[threadID] ?? 0) == terminalActiveRevision {
                state.threadStatusActiveStartedAt = nil
            }
            if state.isBusy {
                statesByThreadID[threadID] = state
            } else {
                statesByThreadID.removeValue(forKey: threadID)
            }
            bumpRevisionLocked(threadID: threadID)
            return false
        }
        let pending = state.pendingSubmit
        let origin: TurnOrigin = pending == nil ? .appServer : .remoteSubmit
        state.pendingSubmit = nil
        state.turn = TurnActivity(turnID: turnID,
                                  startedAt: pending?.startedAt ?? now(),
                                  origin: origin)
        statesByThreadID[threadID] = state
        bumpRevisionLocked(threadID: threadID)
        return true
    }

    // Same revision-fenced contract as seedActiveTurnFromResumeIfUnchanged,
    // for the case where a thread/resume snapshot reports the thread as
    // active/busy but names zero or an ambiguous set of inProgress turns —
    // there is no turn id to steer into, but the thread must still be
    // marked busy so routeSubmit() fails closed to .busyWithoutTurnID
    // instead of wrongly treating it as idle. Also checks ONLY
    // `barrier.state` — setting busy evidence is never destructive, so it
    // needs no protection against a racing "active" notification either.
    @discardableResult
    func markThreadActiveIfUnchanged(threadID: String, barrier: RevisionBarrier) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        pruneExpiredLocked(now: now())
        guard (revisionsByThreadID[threadID] ?? 0) == barrier.state else {
            return false
        }
        var state = statesByThreadID[threadID] ?? State()
        state.threadStatusActiveStartedAt = now()
        statesByThreadID[threadID] = state
        bumpRevisionLocked(threadID: threadID)
        return true
    }

    // Revision-fenced reconciliation for the case where a thread/resume
    // snapshot unambiguously reports the thread IDLE (zero in-progress
    // turns, `status.type == "idle"`) — clears any compatible-but-now-
    // obsolete `threadStatusActiveStartedAt` a racing live ACTIVE
    // notification left behind (see `markThreadActive`'s deliberately
    // weak/non-invalidating `state`-dimension behavior), and any
    // app-server-origin turn, exactly like a live idle notification would
    // (see `markThreadIdle`). Without this, a thread that raced
    // active-then-idle entirely BEFORE its own resume response arrived
    // would be left permanently reporting busy-without-turn-id:
    // `.subscribed` has already committed (no further loaded-list/resume
    // retry), and nothing else ever clears `threadStatusActiveStartedAt`
    // until a FUTURE live idle notification happens to arrive or the
    // 15-minute expiry fires.
    //
    // Unlike the two methods above, this CLEARS evidence rather than only
    // setting it, and clearing has no downstream identity protection (a
    // wrongly-cleared thread routes straight to a colliding turn/start —
    // there is no server-side "expected turn id" check to catch it the way
    // `turn/steer` does for the exact-one seed). It therefore requires BOTH
    // dimensions of `barrier` unchanged: `state` (no claim, no
    // turn/started/completed, no live idle, no expiry) AND `activeEvidence`
    // (no live "active" notification arrived after the barrier was
    // captured) — a stale idle+zero-turns response must never clear active
    // evidence that is actually newer than the snapshot it came from.
    @discardableResult
    func markThreadIdleIfUnchanged(threadID: String, barrier: RevisionBarrier) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        pruneExpiredLocked(now: now())
        guard (revisionsByThreadID[threadID] ?? 0) == barrier.state,
              (activeEvidenceRevisionsByThreadID[threadID] ?? 0) == barrier.activeEvidence else {
            return false
        }
        var state = statesByThreadID[threadID] ?? State()
        state.threadStatusActiveStartedAt = nil
        if state.turn?.origin == .appServer {
            state.turn = nil
        }
        if state.isBusy {
            statesByThreadID[threadID] = state
        } else {
            statesByThreadID.removeValue(forKey: threadID)
        }
        bumpRevisionLocked(threadID: threadID)
        return true
    }

    // The ONE atomic routing decision for a remote chat submit. A single
    // lock hold both DECIDES the route and, for .start, claims the
    // pending-submit slot — closing the TOCTOU window a separate
    // gate-check-then-claim pair would leave open:
    // - an active turn with a KNOWN turn id -> steer INTO that turn
    //   (native turn/steer), never a new turn/start;
    // - no known turn id, but busy (another submit's pending claim, or an
    //   app-server-reported active thread status with no observed turn id
    //   yet) -> a typed conflict; the caller must never terminal-fallback
    //   here (for a codex_app_server record the "terminal" is Tidey's
    //   headless viewer, which re-submits via chat_submit — falling back
    //   would create a recursive resubmit loop);
    // - otherwise idle -> claim the pending-submit slot for a new
    //   turn/start.
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

    // Applies an authoritative turn/start SUCCESS only to the exact pending
    // claim that issued that request. A stale P1 response is a no-op once P1
    // has expired or P2 owns the slot. The transition is atomic with the
    // claim check, so no response/notification interleaving can observe a
    // cleared-but-not-yet-promoted state.
    func reconcileAcceptedStart(threadID: String, claimID: UUID, turnID: String) {
        lock.lock()
        defer { lock.unlock() }
        pruneExpiredLocked(now: now())
        guard var state = statesByThreadID[threadID],
              let pending = state.pendingSubmit,
              pending.claimID == claimID else {
            // A live turn/started or exact resume seed may already have
            // consumed this claim. Never overwrite that newer state; the
            // matching response is simply idempotent.
            return
        }

        state.pendingSubmit = nil
        if let terminalActiveRevision = pending.completedTurnActiveEvidenceRevisions[turnID] {
            // completion-before-response: the response proves which of the
            // observed terminals belonged to this claim. Retire it without
            // recreating the completed turn. Preserve any ACTIVE evidence
            // that arrived after that terminal.
            if (activeEvidenceRevisionsByThreadID[threadID] ?? 0) == terminalActiveRevision {
                state.threadStatusActiveStartedAt = nil
            }
        } else if let currentTurn = state.turn {
            // Defensive compatibility with older/recovered state that may
            // still carry both flags: never overwrite a different live
            // turn; preserve the same turn and make its remote origin
            // explicit.
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
        let activeEvidenceRevision = activeEvidenceRevisionsByThreadID[threadID] ?? 0
        updateStateLocked(threadID: threadID) { state in
            if state.turn?.turnID == turnID {
                state.turn = nil
                // A pending claim can coexist with a known turn only when
                // this attachment missed turn/started and recovered the
                // identity from a resume snapshot. The matching terminal
                // owns that same recovered trajectory, so it is safe—and
                // necessary—to retire the claim with the turn.
                state.pendingSubmit = nil
                // A matching turn/completed is the authoritative terminal
                // for the thread's current turn. Codex does not guarantee a
                // separate thread/status/changed(idle) notification after
                // that terminal, so retaining the earlier thread-level
                // active evidence would leave this otherwise-idle thread
                // stuck as busyWithoutTurnID until timeout. The turn-ID
                // match is essential: a late terminal for an older turn
                // must not clear active evidence owned by a newer turn.
                state.threadStatusActiveStartedAt = nil
            } else if var pending = state.pendingSubmit {
                // The response has not supplied this claim's turn identity
                // yet. Record, but do not act on, the terminal: it could be
                // stale. A later SUCCESS response for this same claim and
                // exact turn ID is what safely retires the claim.
                pending.completedTurnActiveEvidenceRevisions[turnID] = activeEvidenceRevision
                state.pendingSubmit = pending
            }
        }
        lock.unlock()
    }

    // Deliberately does NOT bump the `state` dimension — unlike every other
    // mutation routed through `updateStateLocked`. A live
    // `thread/status/changed(active)` notification is WEAK, compatible
    // evidence: it can legitimately race a `thread/resume` already in
    // flight for the very same thread (the resume's own revision barrier
    // was captured before this notification arrived), and must never
    // invalidate that resume's otherwise-unambiguous exactly-one-inProgress
    // snapshot. Reproduced regression: a fresh Codex panel resumes an
    // already-running turn right as the app-server's own "active" status
    // ping lands first — if this bumped `state`, the resume's
    // `seedActiveTurnFromResumeIfUnchanged` would find its barrier stale
    // and silently reject the exact turn id, while `.subscribed` had
    // already committed (so no retry ever re-fetches it) — the thread is
    // then permanently stuck reporting busy-without-turn-id, and every
    // subsequent submit routes to `.busyWithoutTurnID` forever.
    // `threadStatusActiveStartedAt` is still set below (so `routeSubmit`
    // correctly reports busy for any submit that races in the interim) —
    // only the `state`-dimension side effect is skipped. Genuinely
    // invalidating mutations of `state` — idle (`markThreadIdle`), a live
    // turn/started or turn/completed (`markStarted`/`markCompleted`), a
    // remote submit's own claim (`routeSubmit`'s `.start` branch), and
    // timeout-based expiry (`pruneExpiredLocked`) — are UNCHANGED and still
    // bump `state` exactly as before.
    //
    // DOES bump `activeEvidenceRevisionsByThreadID` unconditionally, every
    // call — this is the SECOND barrier dimension `markThreadIdleIfUnchanged`
    // additionally requires unchanged (see its own doc comment): a fresh
    // "active" notification arriving AFTER a resume's barrier was captured
    // must block that resume's later idle+zero-turns snapshot from clearing
    // this newer evidence, even though it does not block the exact-one seed.
    func markThreadActive(threadID: String) {
        lock.lock()
        defer { lock.unlock() }
        var state = statesByThreadID[threadID] ?? State()
        state.threadStatusActiveStartedAt = now()
        statesByThreadID[threadID] = state
        activeEvidenceRevisionsByThreadID[threadID, default: 0] += 1
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

    // TEST-ONLY OBSERVATION SEAM — no production caller (routeSubmit is the
    // sole atomic decision point for real submits). Non-mutating: exists so
    // tests can assert busy state BETWEEN store mutations without the claim
    // side effect routeSubmit's .start branch would otherwise introduce.
    // Expired activity is pruned first so a long-dead "busy" state (past
    // the timeout) does not wrongly report busy. Do not call this from
    // production code — route real submit decisions through routeSubmit.
    func isBusy(threadID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        pruneExpiredLocked(now: now())
        return statesByThreadID[threadID]?.isBusy == true
    }

    private func pruneExpiredLocked(now: Date) {
        for threadID in Array(statesByThreadID.keys) {
            guard var state = statesByThreadID[threadID] else {
                continue
            }
            guard state.pruneExpired(now: now, timeout: timeout) else {
                continue
            }
            // Pruning is a real state mutation exactly like any other —
            // bump the revision fence so a thread/resume response racing
            // this timeout-based expiry is invalidated too. Without this,
            // a resume snapshot captured before the expiry (barrier
            // unchanged by prune alone) could seed/resurrect turn state
            // the store had already given up on as stale.
            bumpRevisionLocked(threadID: threadID)
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

    // Passive observations (thread ids seen on arbitrary notifications, which
    // include subagent threads) may only fill an empty binding. Rebinding an
    // existing root thread requires an authoritative source such as
    // thread/loaded/list or thread/resume, which call setThreadID directly.
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
    private let processRunner: CodexAppServerProcessRunning
    private let transportConnector: CodexAppServerTransportConnecting

    init(processRunner: CodexAppServerProcessRunning = CodexAppServerProcessRunner(),
         transportConnector: CodexAppServerTransportConnecting = CodexAppServerWebSocketTransportConnector()) {
        self.processRunner = processRunner
        self.transportConnector = transportConnector
    }

    func start(configuration: CodexAppServerLaunchConfiguration,
               context: CodexAppServerRuntimeContext,
               epoch: String = UUID().uuidString,
               nextSequence: @escaping CodexAppServerConnection.SequenceProvider,
               timestampProvider: @escaping CodexAppServerConnection.TimestampProvider,
               onAgentEvent: @escaping CodexAppServerHeadlessRuntime.AgentEventHandler,
               onInteractivePrompt: @escaping CodexAppServerConnection.InteractivePromptHandler,
               onInteractivePromptResolved: @escaping CodexAppServerConnection.InteractivePromptResolvedHandler,
               onActiveThreadID: @escaping CodexAppServerHeadlessRuntime.ThreadIDHandler = { _ in },
               onWorkingControl: @escaping CodexAppServerHeadlessRuntime.WorkingControlHandler = { _ in },
               onStderrLine: @escaping @Sendable (String) -> Void = { _ in },
               onExit: @escaping @Sendable (Int32) -> Void = { _ in }) throws -> CodexAppServerRuntimeSession {
        let stdoutRouter = CodexAppServerConnectionLineRouter()
        let exitRouter = CodexAppServerRuntimeSessionExitRouter(onExit: onExit)
        let process = try processRunner.start(configuration: configuration,
                                              onStdoutLine: { line in
                                                  stdoutRouter.receive(line)
                                              },
                                              onStderrLine: onStderrLine,
                                              onExit: { exitCode in
                                                  exitRouter.receive(exitCode)
                                              })
        let closeRouter = CodexAppServerTransportCloseRouter()
        let violationRouter = CodexAppServerProtocolViolationRouter()
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
        let runtime = CodexAppServerHeadlessRuntime(context: context,
                                                    nextSequence: nextSequence,
                                                    timestampProvider: timestampProvider,
                                                    onAgentEvent: onAgentEvent,
                                                    onThreadID: { _ = activeThreadStore.noteObservedThreadID($0) },
                                                    onTurnStarted: turnStateStore.markStarted,
                                                    onTurnCompleted: turnStateStore.markCompleted,
                                                    onThreadActive: turnStateStore.markThreadActive,
                                                    onThreadIdle: turnStateStore.markThreadIdle,
                                                    onWorkingControl: onWorkingControl)
        let connection = CodexAppServerConnection(sendLine: { line in
            try transport.sendLine(line)
        },
                                                   sendLineConfirmed: { line in
            try transport.sendLineAwaitingWrite(line)
        },
                                                   onNotification: runtime.handleNotification,
                                                   approvalContext: CodexAppServerApprovalContext(workspaceID: context.workspaceID,
                                                                                                  panelID: context.panelID,
                                                                                                  sessionID: context.sessionID,
                                                                                                  epoch: epoch),
                                                   nextSequence: nextSequence,
                                                   timestampProvider: timestampProvider,
                                                   onInteractivePrompt: onInteractivePrompt,
                                                   onInteractivePromptResolved: onInteractivePromptResolved,
                                                   onProtocolViolation: {
                                                       // Stop the runtime generation for real: connection
                                                       // retired, transport aborted (fail-closed writes),
                                                       // owned process terminated. The syncer re-attaches
                                                       // a fresh generation on its next registry scan.
                                                       violationRouter.trigger()
                                                   })
        let initialization = CodexAppServerInitializationState()
        let runtimeSession = CodexAppServerRuntimeSession(process: process,
                                                          transport: transport,
                                                          connection: connection,
                                                          runtime: runtime,
                                                          initialization: initialization,
                                                          activeThreadStore: activeThreadStore,
                                                          turnStateStore: turnStateStore,
                                                          onWorkingControl: onWorkingControl,
                                                          timestampProvider: timestampProvider)
        exitRouter.attach(runtimeSession)
        closeRouter.attach(runtimeSession)
        violationRouter.attach(runtimeSession)
        stdoutRouter.attach(connection)
        do {
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
        } catch {
            // Roll the half-built session back: the caller never receives it
            // and could not release its resources otherwise.
            runtimeSession.stop()
            throw error
        }
        return runtimeSession
    }

    func attach(socketPath: String,
                processID: Int32?,
                context: CodexAppServerRuntimeContext,
                epoch: String = "",
                nextSequence: @escaping CodexAppServerConnection.SequenceProvider,
                timestampProvider: @escaping CodexAppServerConnection.TimestampProvider,
                onAgentEvent: @escaping CodexAppServerHeadlessRuntime.AgentEventHandler,
                onInteractivePrompt: @escaping CodexAppServerConnection.InteractivePromptHandler,
                onInteractivePromptResolved: @escaping CodexAppServerConnection.InteractivePromptResolvedHandler,
                onActiveThreadID: @escaping CodexAppServerHeadlessRuntime.ThreadIDHandler = { _ in },
                onWorkingControl: @escaping CodexAppServerHeadlessRuntime.WorkingControlHandler = { _ in }) throws -> CodexAppServerRuntimeSession {
        let stdoutRouter = CodexAppServerConnectionLineRouter()
        let process = CodexAppServerExternalProcess(processID: processID)
        let closeRouter = CodexAppServerTransportCloseRouter()
        let violationRouter = CodexAppServerProtocolViolationRouter()
        let transport = try transportConnector.connect(mode: .unixSocket(path: socketPath),
                                                       onLine: { line in
                                                           stdoutRouter.receive(line)
                                                       },
                                                       onClose: { error in
                                                           closeRouter.receive(error)
                                                       })
        let activeThreadStore = CodexAppServerActiveThreadStore(onChange: onActiveThreadID)
        let turnStateStore = CodexAppServerTurnStateStore()
        let runtime = CodexAppServerHeadlessRuntime(context: context,
                                                    nextSequence: nextSequence,
                                                    timestampProvider: timestampProvider,
                                                    onAgentEvent: onAgentEvent,
                                                    onThreadID: { _ = activeThreadStore.noteObservedThreadID($0) },
                                                    onTurnStarted: turnStateStore.markStarted,
                                                    onTurnCompleted: turnStateStore.markCompleted,
                                                    onThreadActive: turnStateStore.markThreadActive,
                                                    onThreadIdle: turnStateStore.markThreadIdle,
                                                    onWorkingControl: onWorkingControl)
        let connection = CodexAppServerConnection(sendLine: { line in
            try transport.sendLine(line)
        },
                                                   sendLineConfirmed: { line in
            try transport.sendLineAwaitingWrite(line)
        },
                                                   onNotification: runtime.handleNotification,
                                                   approvalContext: CodexAppServerApprovalContext(workspaceID: context.workspaceID,
                                                                                                  panelID: context.panelID,
                                                                                                  sessionID: context.sessionID,
                                                                                                  epoch: epoch),
                                                   nextSequence: nextSequence,
                                                   timestampProvider: timestampProvider,
                                                   onInteractivePrompt: onInteractivePrompt,
                                                   onInteractivePromptResolved: onInteractivePromptResolved,
                                                   onProtocolViolation: {
                                                       // Stop the runtime generation for real: connection
                                                       // retired, transport aborted (fail-closed writes),
                                                       // owned process terminated. The syncer re-attaches
                                                       // a fresh generation on its next registry scan.
                                                       violationRouter.trigger()
                                                   })
        let initialization = CodexAppServerInitializationState()
        let runtimeSession = CodexAppServerRuntimeSession(process: process,
                                                          transport: transport,
                                                          connection: connection,
                                                          runtime: runtime,
                                                          initialization: initialization,
                                                          activeThreadStore: activeThreadStore,
                                                          turnStateStore: turnStateStore,
                                                          onWorkingControl: onWorkingControl,
                                                          timestampProvider: timestampProvider)
        closeRouter.attach(runtimeSession)
        violationRouter.attach(runtimeSession)
        stdoutRouter.attach(connection)
        do {
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
        } catch {
            // Roll the half-built session back: transport closed, external
            // process untouched (its terminate is a no-op).
            runtimeSession.stop()
            throw error
        }
        return runtimeSession
    }
}

private func codexAppServerLoadedThreadID(from value: JSONValue) -> String? {
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
    if candidates.count == 1 {
        return candidates[0].id
    }
    let currentCandidates = candidates.filter(\.isCurrent)
    if currentCandidates.count == 1 {
        return currentCandidates[0].id
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
}

private func codexAppServerLoadedThreadCandidate(from value: JSONValue) -> CodexAppServerLoadedThreadCandidate? {
    if let id = value.stringValue {
        return CodexAppServerLoadedThreadCandidate(id: id, isCurrent: false)
    }
    guard let object = value.objectValue else {
        return nil
    }
    if let id = object["id"]?.stringValue ?? object["threadId"]?.stringValue {
        return CodexAppServerLoadedThreadCandidate(id: id,
                                                   isCurrent: codexAppServerLoadedThreadIsCurrent(object))
    }
    if let thread = object["thread"]?.objectValue,
       let id = thread["id"]?.stringValue ?? thread["threadId"]?.stringValue {
        return CodexAppServerLoadedThreadCandidate(id: id,
                                                   isCurrent: codexAppServerLoadedThreadIsCurrent(object)
                                                    || codexAppServerLoadedThreadIsCurrent(thread))
    }
    return nil
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

// Routes a protocol violation to the runtime session's teardown. The session
// does not exist yet when the connection is constructed, so the router holds
// the trigger until attach; it fires at most once.
final class CodexAppServerProtocolViolationRouter: @unchecked Sendable {
    private let lock = NSLock()
    private var session: CodexAppServerRuntimeSession?
    private var pendingTrigger = false
    private var delivered = false

    func attach(_ session: CodexAppServerRuntimeSession) {
        lock.lock()
        self.session = session
        let fire = pendingTrigger && delivered == false
        if fire {
            delivered = true
        }
        lock.unlock()
        if fire {
            session.handleProtocolViolation()
        }
    }

    func trigger() {
        lock.lock()
        guard delivered == false else {
            lock.unlock()
            return
        }
        guard let session else {
            pendingTrigger = true
            lock.unlock()
            return
        }
        delivered = true
        lock.unlock()
        session.handleProtocolViolation()
    }
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
    private let lock = NSLock()
    private var closed = false
    private let process: CodexAppServerManagedProcess

    init(process: CodexAppServerManagedProcess) {
        self.process = process
    }

    func sendLine(_ line: String) throws {
        lock.lock()
        let isClosed = closed
        lock.unlock()
        guard isClosed == false else {
            throw CodexAppServerTransportError.closed
        }
        try process.sendLine(line)
    }

    // stdio has no separately closable client channel; closing the transport
    // fail-closes all further writes. Actually stopping the app-server is
    // the owned process's terminate().
    func close() {
        lock.lock()
        closed = true
        lock.unlock()
    }
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

final class CodexAppServerWebSocketFrameHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = WebSocketFrame
    typealias OutboundOut = WebSocketFrame

    private let onText: @Sendable (String) -> Void
    private let onClose: @Sendable (Error?) -> Void
    private let closeLock = NSLock()
    private var closeDelivered = false

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
            deliverCloseOnce(nil)
            context.close(promise: nil)
        default:
            break
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        deliverCloseOnce(error)
        context.close(promise: nil)
    }

    // A dying channel (peer close, error, TCP/unix socket teardown) must
    // reach onClose exactly once so the session can expire its pending
    // approvals and be re-attached; close frame, error, and inactive can all
    // fire for the same channel.
    func channelInactive(context: ChannelHandlerContext) {
        deliverCloseOnce(nil)
        context.fireChannelInactive()
    }

    private func deliverCloseOnce(_ error: Error?) {
        closeLock.lock()
        let shouldDeliver = closeDelivered == false
        closeDelivered = true
        closeLock.unlock()
        guard shouldDeliver else {
            return
        }
        onClose(error)
    }
}

final class CodexAppServerWebSocketTransport: CodexAppServerConnectionTransport {
    private let channel: Channel
    private let lock = NSLock()
    private var closed = false

    init(channel: Channel) {
        self.channel = channel
    }

    func sendLine(_ line: String) throws {
        let frame = try makeTextFrame(line)
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

    func sendLineAwaitingWrite(_ line: String) throws {
        let frame = try makeTextFrame(line)
        guard channel.eventLoop.inEventLoop == false else {
            // Waiting here would deadlock the loop that must perform the
            // write, and a best-effort enqueue cannot be reported as a
            // confirmed submission. Fail closed; the caller keeps the prompt
            // pending and surfaces a retryable error.
            throw CodexAppServerTransportError.confirmationUnavailable
        }
        try channel.writeAndFlush(frame).wait()
    }

    private func makeTextFrame(_ line: String) throws -> WebSocketFrame {
        lock.lock()
        guard closed == false else {
            lock.unlock()
            throw CodexAppServerTransportError.closed
        }
        lock.unlock()

        let payload = line.hasSuffix("\n") ? String(line.dropLast()) : line
        let buffer = channel.allocator.buffer(string: payload)
        return WebSocketFrame(fin: true,
                              opcode: .text,
                              maskKey: WebSocketMaskingKey.random(),
                              data: buffer)
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

// Routes transport onClose callbacks (which are wired before the session
// object exists) to the session, buffering an early close.
private final class CodexAppServerTransportCloseRouter: @unchecked Sendable {
    private let lock = NSLock()
    private var session: CodexAppServerRuntimeSession?
    private var pendingError: Error?
    private var pendingClose = false

    func attach(_ session: CodexAppServerRuntimeSession) {
        lock.lock()
        self.session = session
        let shouldDeliver = pendingClose
        let error = pendingError
        pendingClose = false
        pendingError = nil
        lock.unlock()
        if shouldDeliver {
            session.handleTransportClosed(error: error)
        }
    }

    func receive(_ error: Error?) {
        lock.lock()
        guard let session else {
            pendingClose = true
            pendingError = error
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
