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
    func canSubmitMessage(sessionID: String) -> Bool
    func submitMessage(sessionID: String, text: String) throws
    func submitMessage(sessionID: String, text: String, clientRequestID: String?) throws
}

extension CodexAppServerChatSubmitting {
    func submitMessage(sessionID: String, text: String, clientRequestID: String?) throws {
        try submitMessage(sessionID: sessionID, text: text)
    }
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
            return Self.submittedResponse(for: request,
                                          vendorID: vendor.id,
                                          sessionID: activeSession?.sessionID,
                                          deduplicated: true)
        case .some(.duplicate(.pending)), .some(.duplicate(.indeterminate)):
            return Self.conflictResponse(for: request,
                                         vendorID: vendor.id,
                                         sessionID: activeSession?.sessionID)
        }

        var finalSubmissionState: ChatSubmitEchoRegistry.SubmissionState?
        defer {
            if let clientRequestID {
                switch finalSubmissionState {
                case .delivered:
                    chatSubmitEchoRegistry?.markDelivered(workspaceID: workspaceID,
                                                          panelID: panelID,
                                                          sessionID: resolvedSessionID,
                                                          vendor: vendor.id,
                                                          clientRequestID: clientRequestID)
                case .indeterminate:
                    chatSubmitEchoRegistry?.markIndeterminate(workspaceID: workspaceID,
                                                              panelID: panelID,
                                                              sessionID: resolvedSessionID,
                                                              vendor: vendor.id,
                                                              clientRequestID: clientRequestID)
                case nil:
                    chatSubmitEchoRegistry?.cancelSubmission(workspaceID: workspaceID,
                                                             panelID: panelID,
                                                             sessionID: resolvedSessionID,
                                                             vendor: vendor.id,
                                                             clientRequestID: clientRequestID)
                case .some(.pending):
                    break
                }
            }
        }

        BridgeLogger.input.info("dispatch action=chat_submit request_id=\(request.id, privacy: .public) workspace_id=\(workspaceID, privacy: .public) panel_id=\(panelID, privacy: .public) session_id=\(activeSession?.sessionID ?? requestedSessionID ?? "-", privacy: .public) vendor=\(vendor.id, privacy: .public) length=\(message.count) has_cr=\(message.contains("\r")) has_lf=\(message.contains("\n")) tail=\(summarizedTail(message), privacy: .public)")

        let activeRecord = activeSession.flatMap { sessionResolver.activeRecord(sessionID: $0.sessionID) }
        let canSubmitViaAppServer: Bool?
        if vendor.id == "codex",
           let activeSession,
           activeRecord?.runtime == "codex_app_server",
           let codexAppServerChatSubmitter {
            canSubmitViaAppServer = codexAppServerChatSubmitter.canSubmitMessage(sessionID: activeSession.sessionID)
        } else {
            canSubmitViaAppServer = nil
        }
        if vendor.id == "codex",
           activeRecord?.runtime == "codex_app_server" {
            if codexAppServerChatSubmitter != nil,
               canSubmitViaAppServer == true {
                BridgeLogger.input.debug("codex app-server submit gate request_id=\(request.id, privacy: .public) workspace_id=\(workspaceID, privacy: .public) panel_id=\(panelID, privacy: .public) session_id=\(activeSession?.sessionID ?? "-", privacy: .public) active_record_runtime=\(activeRecord?.runtime ?? "-", privacy: .public) has_submitter=true can_submit=true")
            } else {
                BridgeLogger.input.info("codex app-server submit gate blocked request_id=\(request.id, privacy: .public) workspace_id=\(workspaceID, privacy: .public) panel_id=\(panelID, privacy: .public) session_id=\(activeSession?.sessionID ?? "-", privacy: .public) active_record_runtime=\(activeRecord?.runtime ?? "-", privacy: .public) has_submitter=\((codexAppServerChatSubmitter != nil), privacy: .public) can_submit=\(canSubmitViaAppServer.map(String.init) ?? "-", privacy: .public)")
            }
        }

        if vendor.id == "codex",
           let activeSession,
           activeRecord?.runtime == "codex_app_server" {
            if let codexAppServerChatSubmitter,
               canSubmitViaAppServer == true {
                finalSubmissionState = .indeterminate
                try codexAppServerChatSubmitter.submitMessage(sessionID: activeSession.sessionID,
                                                              text: message)
                if let clientRequestID {
                    chatSubmitEchoRegistry?.register(workspaceID: workspaceID,
                                                     panelID: panelID,
                                                     sessionID: activeSession.sessionID,
                                                     vendor: vendor.id,
                                                     text: message,
                                                     clientRequestID: clientRequestID)
                }
                finalSubmissionState = .delivered
                return Self.submittedResponse(for: request,
                                              vendorID: vendor.id,
                                              sessionID: activeSession.sessionID,
                                              deduplicated: false)
            }
            let fallbackReason: String
            if codexAppServerChatSubmitter == nil {
                fallbackReason = "missing_submitter"
            } else {
                fallbackReason = "can_submit_false"
            }
            BridgeLogger.input.info("codex app-server runtime not ready; falling back to terminal input session_id=\(activeSession.sessionID, privacy: .public) reason=\(fallbackReason, privacy: .public)")
        }

        var previousStepUsedOrdinaryTmux = false
        var forceMacSocketForRemainingSteps = false
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
                finalSubmissionState = .indeterminate
                previousStepUsedOrdinaryTmux = true
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
                    return BridgeResponse(id: request.id,
                                          ok: false,
                                          result: nil,
                                          error: response.error)
                }
                finalSubmissionState = .indeterminate
                previousStepUsedOrdinaryTmux = false
            }
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
        finalSubmissionState = .delivered

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

    private static func conflictResponse(for request: BridgeRequest,
                                         vendorID: String,
                                         sessionID: String?) -> BridgeResponse {
        BridgeResponse(id: request.id,
                       ok: false,
                       result: [
                        "submitted": .bool(false),
                        "vendor": .string(vendorID),
                        "session_id": sessionID.map { .string($0) } ?? .null,
                       ],
                       error: BridgeErrorPayload(code: "CONFLICT",
                                                 message: "A submission for this client_request_id is still pending or has an indeterminate outcome."))
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
