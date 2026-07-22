import Darwin
import Foundation

let ordinaryTmuxChatSubmitEnterDelayNanoseconds: UInt64 = 5_000_000_000

protocol TideyRequestSending {
    func send(_ request: BridgeRequest) throws -> BridgeResponse
}

extension TideySocketClient: TideyRequestSending {}

protocol ActiveAgentSessionResolving {
    func activeSessionForPanel(workspaceID: String, panelID: String) -> ActiveAgentSessionSnapshot?
    func activeRecord(sessionID: String) -> AgentSessionRegistryRecord?
}

extension AgentSessionRegistryMonitor: ActiveAgentSessionResolving {}

protocol CodexAppServerChatSubmitting: AnyObject {
    func submitMessage(sessionID: String, text: String, clientRequestID: String?) throws
}

// Distinguishes the three ZERO-SEMANTIC-EFFECT submitMessage() outcomes
// from every other failure:
//
// - `.busyWithoutTurnID`: an ATOMIC routing rejection — no transport
//   attempt was ever made (no known active turn id to steer into, and no
//   capacity to claim a new turn/start either).
// - `.rejected`: the app-server sent a DEFINITE JSON-RPC error response
//   (turn/start or turn/steer was authoritatively refused — e.g. a race
//   into a newly active turn, or a steer whose expectedTurnId no longer
//   matches because the turn completed or was replaced). The request
//   reached the app-server and was refused; nothing was accepted. A
//   SUCCESSFUL response is never classified here, even if its payload looks
//   wrong (e.g. turn/steer's returned turnId doesn't match expectedTurnId)
//   — a success response means the server may have accepted the input
//   somewhere, so that case is indeterminate, not rejected.
// - `.unavailableBeforeSend`: the submit could not even be ATTEMPTED — no
//   registry entry for the session, app-server initialization failed or
//   timed out, or the pre-send thread-id lookup failed — all of which
//   happen strictly BEFORE any turn/start or turn/steer request frame for
//   the user's text is ever constructed. Zero effect on the user's message
//   by construction.
//
// All three are safe for the caller to return as a conflict/retryable
// response and to cancel the client_request_id reservation — but NEVER
// safe to terminal-fallback: for a codex_app_server record, "the terminal"
// is Tidey's headless viewer, which immediately re-submits whatever it
// reads back through ANOTHER chat_submit — falling back here creates a
// recursive resubmit loop.
//
// Every OTHER submitMessage() failure (transport close, bounded-wait
// timeout with no authoritative response, a synchronous write failure of
// the ACTUAL turn/start or turn/steer request, or a turn/steer success
// response whose turnId doesn't match) has an UNKNOWN outcome — the
// request may still land server-side — and must be treated as
// indeterminate: never retried, never fallen back, never silently reported
// as success. Typed (never string-matched) so the caller never has to
// guess from a message.
enum CodexAppServerSubmitFailure: Error, Equatable {
    case busyWithoutTurnID
    case rejected(String)
    case unavailableBeforeSend(String)
}

struct BridgeInputActionHandler {
    private enum OrdinaryTmuxRouteDecision {
        case routed
        case unavailable
        case macSocketFallback
    }

    private let socketSender: TideyRequestSending
    private let sessionResolver: ActiveAgentSessionResolving
    private let codexAppServerChatSubmitter: CodexAppServerChatSubmitting?
    private let ordinaryTmuxInputRouter: OrdinaryTmuxInputRouting?
    private let chatSubmitEchoRegistry: ChatSubmitEchoRegistry?
    private let sleep: @Sendable (UInt64) throws -> Void

    init(socketSender: TideyRequestSending,
         sessionResolver: ActiveAgentSessionResolving,
         codexAppServerChatSubmitter: CodexAppServerChatSubmitting? = nil,
         ordinaryTmuxInputRouter: OrdinaryTmuxInputRouting? = nil,
         chatSubmitEchoRegistry: ChatSubmitEchoRegistry? = nil,
         sleep: @escaping @Sendable (UInt64) throws -> Void = { delayNanoseconds in
             guard delayNanoseconds > 0 else {
                 return
             }
             usleep(useconds_t(delayNanoseconds / 1_000))
        }) {
        self.socketSender = socketSender
        self.sessionResolver = sessionResolver
        self.codexAppServerChatSubmitter = codexAppServerChatSubmitter
        self.ordinaryTmuxInputRouter = ordinaryTmuxInputRouter
        self.chatSubmitEchoRegistry = chatSubmitEchoRegistry
        self.sleep = sleep
    }

    func handle(_ request: BridgeRequest) throws -> BridgeResponse? {
        switch request.action {
        case "terminal_input":
            BridgeLogger.input.info("receive action=terminal_input request_id=\(request.id, privacy: .public)")
            return try forwardTerminalInput(request)
        case "chat_submit":
            BridgeLogger.input.info("receive action=chat_submit request_id=\(request.id, privacy: .public)")
            return try submitChatMessage(request)
        default:
            return nil
        }
    }

    private func forwardTerminalInput(_ request: BridgeRequest) throws -> BridgeResponse {
        guard let params = request.params,
              params["input"]?.stringValue != nil,
              params["panel_id"]?.stringValue != nil || params["workspace_id"]?.stringValue != nil else {
            throw BridgeInternalError.invalidRequest("terminal_input requires input and panel_id or workspace_id")
        }

        let input = params["input"]?.stringValue ?? ""
        let panelID = params["panel_id"]?.stringValue ?? "-"
        let workspaceID = params["workspace_id"]?.stringValue ?? "-"
        BridgeLogger.input.info("forward action=terminal_input request_id=\(request.id, privacy: .public) workspace_id=\(workspaceID, privacy: .public) panel_id=\(panelID, privacy: .public) length=\(input.count) has_cr=\(input.contains("\r")) has_lf=\(input.contains("\n")) tail=\(summarizedTail(input), privacy: .public)")

        if let routedPanelID = params["panel_id"]?.stringValue,
           try routeOrdinaryTmuxInputIfAvailable(input,
                                                 panelID: routedPanelID,
                                                 requestID: request.id,
                                                 action: "terminal_input",
                                                 stepIndex: nil,
                                                 mode: .rawTerminalInput,
                                                 allowAmbiguousPasteTimeout: false) == .routed {
            BridgeLogger.input.info("route action=terminal_input request_id=\(request.id, privacy: .public) panel_id=\(routedPanelID, privacy: .public) transport=ordinary_tmux")
            return BridgeResponse(id: request.id,
                                  ok: true,
                                  result: ["sent": .bool(true)],
                                  error: nil)
        }

        let forwardedRequest = BridgeRequest(id: request.id,
                                             action: "send_input",
                                             params: params)
        return try socketSender.send(forwardedRequest)
    }

    private func submitChatMessage(_ request: BridgeRequest) throws -> BridgeResponse {
        guard let params = request.params,
              let workspaceID = params["workspace_id"]?.stringValue,
              let panelID = params["panel_id"]?.stringValue,
              let message = params["message"]?.stringValue,
              !message.isEmpty else {
            throw BridgeInternalError.invalidRequest("chat_submit requires workspace_id, panel_id, and message")
        }

        let requestedSessionID = params["session_id"]?.stringValue
        let requestedVendor = params["vendor"]?.stringValue
        let clientRequestID = params["client_request_id"]?.stringValue
        let activeSession = sessionResolver.activeSessionForPanel(workspaceID: workspaceID, panelID: panelID)
        BridgeLogger.input.info("resolve action=chat_submit request_id=\(request.id, privacy: .public) workspace_id=\(workspaceID, privacy: .public) panel_id=\(panelID, privacy: .public) requested_session_id=\(requestedSessionID ?? "-", privacy: .public) requested_vendor=\(requestedVendor ?? "-", privacy: .public) active_session_id=\(activeSession?.sessionID ?? "-", privacy: .public) active_vendor=\(activeSession?.vendor ?? "-", privacy: .public)")

        if let requestedSessionID,
           let activeSession,
           activeSession.sessionID != requestedSessionID {
            throw BridgeInternalError.invalidRequest("chat_submit session_id does not match the active panel session")
        }

        if let requestedVendor,
           let activeSession,
           activeSession.vendor != requestedVendor {
            throw BridgeInternalError.invalidRequest("chat_submit vendor does not match the active panel session")
        }

        guard let resolvedVendorID = activeSession?.vendor ?? requestedVendor else {
            throw BridgeInternalError.invalidRequest("chat_submit requires vendor when no active panel session is registered")
        }
        guard let vendor = AgentVendorRegistry.resolve(id: resolvedVendorID) else {
            throw BridgeInternalError.invalidRequest("chat_submit vendor is not supported")
        }
        let resolvedSessionID = activeSession?.sessionID ?? requestedSessionID ?? "-"
        switch chatSubmitEchoRegistry?.beginSubmission(workspaceID: workspaceID,
                                                       panelID: panelID,
                                                       sessionID: resolvedSessionID,
                                                       vendor: vendor.id,
                                                       clientRequestID: clientRequestID) {
        case .none, .some(.started):
            break
        case .some(.duplicate(.delivered)):
            // Only a DEFINITELY-delivered original may safely dedupe a
            // duplicate as success.
            return Self.submittedResponse(for: request,
                                          vendorID: vendor.id,
                                          sessionID: activeSession?.sessionID,
                                          deduplicated: true)
        case .some(.duplicate(.pending)), .some(.duplicate(.indeterminate)):
            // The original is still in flight, or its outcome is unknown/
            // partial — telling the caller "submitted: true" here could be
            // a false success (nothing may have been delivered) or mask an
            // already-partial delivery. Fail closed with a conflict rather
            // than guess.
            return Self.conflictResponse(for: request,
                                         vendorID: vendor.id,
                                         sessionID: activeSession?.sessionID)
        }
        // Reservation finalization: exactly one of delivered/indeterminate/
        // (nil ->) cancelled applies when this function returns, covering
        // every exit path (throw included, since `defer` runs on throws).
        // - delivered: app-server accepted the turn, or every terminal step
        //   completed — the ONLY state a duplicate may see as success.
        // - indeterminate: some step may have had an externally observable
        //   effect (a text step succeeded before Enter failed; a generic
        //   direct-submit error whose transport outcome is unprovable) — a
        //   duplicate must get a conflict, never a resend, never a false
        //   success.
        // - nil (cancelled): PROVABLY zero effect — safe to free the id so
        //   a retry is a genuinely fresh attempt.
        var finalState: ChatSubmitEchoRegistry.SubmissionState?
        defer {
            if let clientRequestID {
                switch finalState {
                case .delivered:
                    chatSubmitEchoRegistry?.markDelivered(workspaceID: workspaceID, panelID: panelID,
                                                          sessionID: resolvedSessionID, vendor: vendor.id,
                                                          clientRequestID: clientRequestID)
                case .indeterminate:
                    chatSubmitEchoRegistry?.markIndeterminate(workspaceID: workspaceID, panelID: panelID,
                                                              sessionID: resolvedSessionID, vendor: vendor.id,
                                                              clientRequestID: clientRequestID)
                case nil:
                    chatSubmitEchoRegistry?.cancelSubmission(workspaceID: workspaceID, panelID: panelID,
                                                             sessionID: resolvedSessionID, vendor: vendor.id,
                                                             clientRequestID: clientRequestID)
                case .some(.pending):
                    break // never explicitly set — pending is the pre-finalization default
                }
            }
        }

        BridgeLogger.input.info("dispatch action=chat_submit request_id=\(request.id, privacy: .public) workspace_id=\(workspaceID, privacy: .public) panel_id=\(panelID, privacy: .public) session_id=\(activeSession?.sessionID ?? requestedSessionID ?? "-", privacy: .public) vendor=\(vendor.id, privacy: .public) length=\(message.count) has_cr=\(message.contains("\r")) has_lf=\(message.contains("\n")) tail=\(summarizedTail(message), privacy: .public)")

        // Resolve the record from whichever session id is actually known —
        // NOT only via activeSession. If the panel snapshot is briefly
        // missing but the request carries a valid session_id, looking the
        // record up ONLY through activeSession would miss a
        // codex_app_server record and fall through into terminal
        // injection, which is the exact recursive HeadlessCodexTerminal
        // path this whole fix exists to close.
        let appServerSessionID = activeSession?.sessionID ?? requestedSessionID
        let activeRecord = appServerSessionID.flatMap { sessionResolver.activeRecord(sessionID: $0) }

        // A codex_app_server record's paired "terminal" is Tidey's headless
        // Codex viewer (HeadlessCodexTerminal), which reads any injected
        // line straight back out and re-submits it as a BRAND NEW
        // chat_submit — terminal fallback for this runtime is a recursive
        // resubmit loop, not a safe degraded path. So this branch must fail
        // closed (never fall through to the terminal loop below) on every
        // outcome except a genuine app-server accept.
        //
        // The RECORD's runtime decides this branch — not the request's
        // claimed vendor. A request could claim vendor=claude while the
        // resolved session id actually belongs to a codex_app_server
        // record (e.g. a stale/forged session_id); routing on the record
        // itself, before any vendor-specific branch, closes that gap.
        if let activeRecord, let appServerSessionID, activeRecord.runtime == "codex_app_server" {
            // The session id may have come from requestedSessionID alone
            // (no activeSession to vouch for it) — never trust it without
            // checking that the record it resolves to actually BELONGS to
            // this request's workspace/panel/vendor, AND that the request
            // actually claims (or resolves to) vendor=codex. Without this
            // check a request for panel X could supply a session id that
            // happens to belong to panel Y and submit into Y's Codex
            // thread, or a vendor=claude request could be silently routed
            // into a Codex app-server thread.
            guard vendor.id == "codex",
                  activeRecord.workspaceID == workspaceID,
                  activeRecord.panelID == panelID,
                  activeRecord.vendor == vendor.id else {
                throw BridgeInternalError.invalidRequest("chat_submit session_id does not belong to the requested workspace_id/panel_id/vendor")
            }
            guard let codexAppServerChatSubmitter else {
                BridgeLogger.input.error("codex app-server chat submitter missing for a codex_app_server record; failing closed (no terminal fallback) request_id=\(request.id, privacy: .public) session_id=\(appServerSessionID, privacy: .public)")
                return Self.conflictResponse(for: request,
                                             vendorID: vendor.id,
                                             sessionID: appServerSessionID)
            }
            // No canSubmitMessage() pre-check here: that was a separate,
            // non-atomic peek that left a TOCTOU window between "checked
            // busy" and "claimed". submitMessage() now performs ONE atomic
            // route decision (start / steer(activeTurnID) / busyWithoutTurnID)
            // internally and always attempts it directly, then bounded-waits
            // for the app-server's authoritative accept/reject.
            do {
                try codexAppServerChatSubmitter.submitMessage(sessionID: appServerSessionID,
                                                              text: message,
                                                              clientRequestID: clientRequestID)
                if let clientRequestID {
                    chatSubmitEchoRegistry?.register(workspaceID: workspaceID,
                                                     panelID: panelID,
                                                     sessionID: appServerSessionID,
                                                     vendor: vendor.id,
                                                     text: message,
                                                     clientRequestID: clientRequestID)
                }
                finalState = .delivered
                return Self.submittedResponse(for: request,
                                              vendorID: vendor.id,
                                              sessionID: appServerSessionID,
                                              deduplicated: false)
            } catch CodexAppServerSubmitFailure.busyWithoutTurnID {
                // No known active turn id to steer into, and no capacity to
                // claim a new turn/start (another submit already pending, or
                // the thread reports active with no observed turn id yet).
                // Zero side effect — but NEVER safe to terminal-fallback for
                // this runtime. Typed conflict, retryable by the caller.
                BridgeLogger.input.info("codex app-server busy with no known active turn id; returning conflict (no terminal fallback for codex_app_server) request_id=\(request.id, privacy: .public) session_id=\(appServerSessionID, privacy: .public)")
                return Self.conflictResponse(for: request,
                                             vendorID: vendor.id,
                                             sessionID: appServerSessionID)
            } catch CodexAppServerSubmitFailure.rejected(let rejectionMessage) {
                // The app-server sent a DEFINITE JSON-RPC rejection — the
                // request reached it and was authoritatively refused
                // (turn/start raced into a newly active turn, or
                // turn/steer's expectedTurnId no longer matched). Zero
                // semantic effect: nothing was accepted, so the reservation
                // is safe to cancel for a genuine retry — but still NEVER
                // safe to terminal-fallback for this runtime.
                BridgeLogger.input.info("codex app-server submit definitively rejected; returning conflict (no terminal fallback for codex_app_server) request_id=\(request.id, privacy: .public) session_id=\(appServerSessionID, privacy: .public) reason=\(rejectionMessage, privacy: .public)")
                return Self.conflictResponse(for: request,
                                             vendorID: vendor.id,
                                             sessionID: appServerSessionID)
            } catch CodexAppServerSubmitFailure.unavailableBeforeSend(let reason) {
                // The submit could not even be ATTEMPTED — no registry entry
                // for the session, app-server initialization failed/timed
                // out, or the pre-send thread-id lookup failed. All of this
                // happens strictly before any turn/start or turn/steer
                // request frame for the user's text is built. Zero effect
                // by construction — safe to cancel for a genuine retry once
                // the runtime recovers, but still NEVER safe to
                // terminal-fallback for this runtime.
                BridgeLogger.input.info("codex app-server unavailable before any send attempt; returning conflict (no terminal fallback for codex_app_server) request_id=\(request.id, privacy: .public) session_id=\(appServerSessionID, privacy: .public) reason=\(reason, privacy: .public)")
                return Self.conflictResponse(for: request,
                                             vendorID: vendor.id,
                                             sessionID: appServerSessionID)
            } catch {
                // Every OTHER failure — a synchronous write failure, the
                // transport closing, or a bounded-wait timeout with no
                // authoritative response — is UNKNOWN, not zero-effect: the
                // request may still land server-side. Must NEVER fall back
                // and must NEVER be reported as success.
                finalState = .indeterminate
                BridgeLogger.input.error("codex app-server submit failed with an indeterminate outcome; NOT falling back request_id=\(request.id, privacy: .public) session_id=\(appServerSessionID, privacy: .public) error=\(String(describing: error), privacy: .public)")
                throw error
            }
        } else if vendor.id == "codex", activeRecord == nil {
            // vendor=codex with NO resolved registry record — whether
            // because the session id is known but the registry hasn't
            // caught up yet (e.g. Bridge just restarted), or because no
            // session id is known at all (activeSession nil and no
            // requested session_id). Either way we cannot prove this ISN'T
            // a codex_app_server record — and terminal fallback for that
            // runtime is a recursive resubmit loop — so this must fail
            // closed rather than risk it. Zero effect: a retry once the
            // record resolves (or a session id becomes known) goes through
            // normally.
            BridgeLogger.input.error("codex session record unavailable; failing closed (no terminal fallback) request_id=\(request.id, privacy: .public) session_id=\(appServerSessionID ?? "-", privacy: .public)")
            return Self.conflictResponse(for: request,
                                         vendorID: vendor.id,
                                         sessionID: appServerSessionID)
        } else if vendor.id == "codex", let activeRecord {
            // A RESOLVED record, already confirmed NOT codex_app_server
            // (the first branch above owns that case) — but a resolved
            // non-app-server record is still not automatically safe to
            // terminal-fallback into. It must genuinely BELONG to this
            // request's workspace/panel/vendor (never trust a session id
            // that happens to resolve to a DIFFERENT panel's record), and
            // its runtime must be a CONFIRMED ordinary shape — currently
            // `nil`, exactly like production's synthesized record for a
            // plain tmux Codex panel. Any other non-nil, non-
            // "codex_app_server" runtime value (a starting/transitional/
            // unrecognized state) is not provably safe — fail closed
            // rather than guess, for the same recursive-resubmit reason as
            // the codex_app_server branch.
            guard activeRecord.workspaceID == workspaceID,
                  activeRecord.panelID == panelID,
                  activeRecord.vendor == vendor.id,
                  activeRecord.runtime == nil else {
                BridgeLogger.input.error("codex session record identity mismatch or unconfirmed runtime; failing closed (no terminal fallback) request_id=\(request.id, privacy: .public) session_id=\(appServerSessionID ?? "-", privacy: .public) record_workspace_id=\(activeRecord.workspaceID, privacy: .public) record_panel_id=\(activeRecord.panelID ?? "-", privacy: .public) record_vendor=\(activeRecord.vendor, privacy: .public) record_runtime=\(activeRecord.runtime ?? "-", privacy: .public)")
                return Self.conflictResponse(for: request,
                                             vendorID: vendor.id,
                                             sessionID: appServerSessionID)
            }
            // Identity matches and the runtime is a confirmed ordinary
            // shape — falls through to the terminal plan below, unchanged.
        }
        var previousStepUsedOrdinaryTmux = false
        var forceMacSocketForRemainingSteps = false
        // Zero-effect provability: no step has reached ANY transport yet.
        // Only while this stays false may a failure cancel the reservation
        // outright; once ANY step is confirmed sent, a later failure is
        // indeterminate (partial delivery), never cancellable.
        var anyStepConfirmedSent = false
        do {
            for (index, step) in vendor.submitMessagePlan(text: message).enumerated() {
                let effectiveDelay = Self.effectiveDelay(for: step,
                                                         previousStepUsedOrdinaryTmux: previousStepUsedOrdinaryTmux)
                if index > 0 {
                    try sleep(effectiveDelay)
                }
                BridgeLogger.input.info("step action=send_input request_id=\(request.id, privacy: .public) vendor=\(vendor.id, privacy: .public) step_index=\(index) delay_ns=\(effectiveDelay) length=\(step.input.count) has_cr=\(step.input.contains("\r")) has_lf=\(step.input.contains("\n")) tail=\(summarizedTail(step.input), privacy: .public)")
                let routeDecision: OrdinaryTmuxRouteDecision
                if forceMacSocketForRemainingSteps {
                    routeDecision = .macSocketFallback
                } else {
                    // The step ROLE (declared by the vendor plan) decides the
                    // semantics: the message step is literal chat text even when
                    // its payload happens to be an enter-only sequence; only the
                    // submit step keeps raw key semantics.
                    routeDecision = try routeOrdinaryTmuxInputIfAvailable(step.input,
                                                                          panelID: panelID,
                                                                          requestID: request.id,
                                                                          action: "chat_submit",
                                                                          stepIndex: index,
                                                                          mode: step.role == .submitEnter ? .rawTerminalInput : .literalChatText,
                                                                          allowAmbiguousPasteTimeout: true)
                }
                if routeDecision == .routed {
                    previousStepUsedOrdinaryTmux = true
                    anyStepConfirmedSent = true
                    BridgeLogger.input.info("route action=chat_submit request_id=\(request.id, privacy: .public) panel_id=\(panelID, privacy: .public) transport=ordinary_tmux step_index=\(index)")
                } else {
                    if routeDecision == .macSocketFallback {
                        forceMacSocketForRemainingSteps = true
                    }
                    let stepRequest: BridgeRequest
                    if step.role == .submitEnter {
                        stepRequest = BridgeRequest(id: UUID().uuidString,
                                                    action: "send_key",
                                                    params: [
                                                        "panel_id": .string(panelID),
                                                        "key": .string("enter"),
                                                    ])
                    } else {
                        stepRequest = BridgeRequest(id: UUID().uuidString,
                                                    action: "send_input",
                                                    params: [
                                                        "panel_id": .string(panelID),
                                                        "input": .string(step.input),
                                                    ])
                    }
                    let response = try socketSender.send(stepRequest)
                    guard response.ok else {
                        // NOT ok: this exact step was refused by the transport.
                        // If a PRIOR step already succeeded, that step's effect
                        // is real and unretractable — indeterminate. Otherwise
                        // nothing has been sent at all yet — provably safe to
                        // cancel and let a retry start completely fresh.
                        if anyStepConfirmedSent {
                            finalState = .indeterminate
                        }
                        return BridgeResponse(id: request.id,
                                              ok: false,
                                              result: nil,
                                              error: response.error)
                    }
                    anyStepConfirmedSent = true
                    previousStepUsedOrdinaryTmux = false
                }
            }
        } catch {
            // A THROWN error (unlike a clean ok:false response above) has an
            // unprovable side-effect status — the write may have partially
            // reached the transport before failing. Conservatively always
            // indeterminate here, never cancellable, regardless of whether
            // an earlier step already succeeded. Only an explicit
            // zero-side-effect ok:false response (handled above) may still
            // cancel when no prior step succeeded.
            finalState = .indeterminate
            throw error
        }

        if let clientRequestID,
           let resolvedSessionID = activeSession?.sessionID ?? requestedSessionID {
            chatSubmitEchoRegistry?.register(workspaceID: workspaceID,
                                             panelID: panelID,
                                             sessionID: resolvedSessionID,
                                             vendor: vendor.id,
                                             text: message,
                                             clientRequestID: clientRequestID)
        }

        finalState = .delivered
        return Self.submittedResponse(for: request,
                                      vendorID: vendor.id,
                                      sessionID: activeSession?.sessionID,
                                      deduplicated: false)
    }

    private static func submittedResponse(for request: BridgeRequest,
                                          vendorID: String,
                                          sessionID: String?,
                                          deduplicated: Bool) -> BridgeResponse {
        return BridgeResponse(id: request.id,
                              ok: true,
                              result: [
                                "submitted": .bool(true),
                                "vendor": .string(vendorID),
                                "session_id": sessionID.map { .string($0) } ?? .null,
                                "deduplicated": .bool(deduplicated),
                              ],
                              error: nil)
    }

    // A duplicate client_request_id whose original submission is still
    // in-flight (pending) or ended in an unknown/partial state
    // (indeterminate) must NEVER get "submitted: true" — that would either
    // be a false success (nothing may have been delivered) or mask an
    // already-partial delivery a caller should surface, not silently
    // treat as done.
    private static func conflictResponse(for request: BridgeRequest,
                                         vendorID: String,
                                         sessionID: String?) -> BridgeResponse {
        return BridgeResponse(id: request.id,
                              ok: false,
                              result: [
                                "submitted": .bool(false),
                                "vendor": .string(vendorID),
                                "session_id": sessionID.map { .string($0) } ?? .null,
                              ],
                              error: BridgeErrorPayload(code: "conflict",
                                                        message: "A submission for this client_request_id is already in flight or ended in an unknown state."))
    }

    private func summarizedTail(_ input: String) -> String {
        String(input.suffix(3))
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    private static func effectiveDelay(for step: ChatSubmitStep, previousStepUsedOrdinaryTmux: Bool) -> UInt64 {
        guard previousStepUsedOrdinaryTmux,
              step.role == .submitEnter else {
            return step.delayNanoseconds
        }
        return ordinaryTmuxChatSubmitEnterDelayNanoseconds
    }

    private func routeOrdinaryTmuxInputIfAvailable(_ input: String,
                                                   panelID: String,
                                                   requestID: String,
                                                   action: String,
                                                   stepIndex: Int?,
                                                   mode: OrdinaryTmuxInputMode,
                                                   allowAmbiguousPasteTimeout: Bool) throws -> OrdinaryTmuxRouteDecision {
        guard let ordinaryTmuxInputRouter else {
            return .unavailable
        }
        do {
            return try ordinaryTmuxInputRouter.sendInput(input,
                                                        toPanelID: panelID,
                                                        mode: mode,
                                                        allowAmbiguousPasteTimeout: allowAmbiguousPasteTimeout) ? .routed : .unavailable
        } catch {
            guard Self.shouldFallbackToMacSocket(panelID: panelID, error: error) else {
                throw error
            }
            BridgeLogger.input.info("ordinary tmux route timeout fallback action=\(action, privacy: .public) request_id=\(requestID, privacy: .public) panel_id=\(panelID, privacy: .public) step_index=\(stepIndex.map(String.init) ?? "-", privacy: .public) transport=mac_socket error=\(String(describing: error), privacy: .public)")
            return .macSocketFallback
        }
    }

    private static func shouldFallbackToMacSocket(panelID: String, error: Error) -> Bool {
        guard OrdinaryTmuxLogicalPanelID(rawValue: panelID) == nil else {
            return false
        }
        let nsError = error as NSError
        return nsError.domain == "OrdinaryTmuxCLIAdapter" && nsError.code == 124
    }
}
