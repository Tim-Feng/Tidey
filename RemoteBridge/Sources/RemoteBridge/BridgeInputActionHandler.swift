import Darwin
import Foundation

let ordinaryTmuxChatSubmitEnterDelayNanoseconds: UInt64 = 5_000_000_000

protocol TideyRequestSending {
    func send(_ request: BridgeRequest) throws -> BridgeResponse
}

extension TideySocketClient: TideyRequestSending {}

protocol ActiveAgentSessionResolving {
    func activeSessionForPanel(workspaceID: String, panelID: String) -> ActiveAgentSessionSnapshot?
}

extension AgentSessionRegistryMonitor: ActiveAgentSessionResolving {}

struct BridgeInputActionHandler {
    private let socketSender: TideyRequestSending
    private let sessionResolver: ActiveAgentSessionResolving
    private let ordinaryTmuxInputRouter: OrdinaryTmuxInputRouting?
    private let chatSubmitEchoRegistry: ChatSubmitEchoRegistry?
    private let sleep: @Sendable (UInt64) throws -> Void

    init(socketSender: TideyRequestSending,
         sessionResolver: ActiveAgentSessionResolving,
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

        if let ordinaryTmuxInputRouter,
           let routedPanelID = params["panel_id"]?.stringValue,
           try ordinaryTmuxInputRouter.sendInput(input, toPanelID: routedPanelID) {
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
        if chatSubmitEchoRegistry?.beginSubmission(workspaceID: workspaceID,
                                                   panelID: panelID,
                                                   sessionID: resolvedSessionID,
                                                   vendor: vendor.id,
                                                   clientRequestID: clientRequestID) == false {
            return Self.submittedResponse(for: request,
                                          vendorID: vendor.id,
                                          sessionID: activeSession?.sessionID,
                                          deduplicated: true)
        }

        BridgeLogger.input.info("dispatch action=chat_submit request_id=\(request.id, privacy: .public) workspace_id=\(workspaceID, privacy: .public) panel_id=\(panelID, privacy: .public) session_id=\(activeSession?.sessionID ?? requestedSessionID ?? "-", privacy: .public) vendor=\(vendor.id, privacy: .public) length=\(message.count) has_cr=\(message.contains("\r")) has_lf=\(message.contains("\n")) tail=\(summarizedTail(message), privacy: .public)")

        var previousStepUsedOrdinaryTmux = false
        for (index, step) in vendor.submitMessagePlan(text: message).enumerated() {
            let effectiveDelay = Self.effectiveDelay(for: step,
                                                     previousStepUsedOrdinaryTmux: previousStepUsedOrdinaryTmux)
            if index > 0 {
                try sleep(effectiveDelay)
            }
            BridgeLogger.input.info("step action=send_input request_id=\(request.id, privacy: .public) vendor=\(vendor.id, privacy: .public) step_index=\(index) delay_ns=\(effectiveDelay) length=\(step.input.count) has_cr=\(step.input.contains("\r")) has_lf=\(step.input.contains("\n")) tail=\(summarizedTail(step.input), privacy: .public)")
            if let ordinaryTmuxInputRouter,
               try ordinaryTmuxInputRouter.sendInput(step.input,
                                                     toPanelID: panelID,
                                                     allowAmbiguousPasteTimeout: true) {
                previousStepUsedOrdinaryTmux = true
                BridgeLogger.input.info("route action=chat_submit request_id=\(request.id, privacy: .public) panel_id=\(panelID, privacy: .public) transport=ordinary_tmux step_index=\(index)")
            } else {
                let stepRequest = BridgeRequest(id: UUID().uuidString,
                                                action: "send_input",
                                                params: [
                                                    "panel_id": .string(panelID),
                                                    "input": .string(step.input),
                                                ])
                let response = try socketSender.send(stepRequest)
                guard response.ok else {
                    return BridgeResponse(id: request.id,
                                          ok: false,
                                          result: nil,
                                          error: response.error)
                }
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

    private func summarizedTail(_ input: String) -> String {
        String(input.suffix(3))
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    private static func effectiveDelay(for step: ChatSubmitStep, previousStepUsedOrdinaryTmux: Bool) -> UInt64 {
        guard previousStepUsedOrdinaryTmux,
              isEnterOnly(step.input) else {
            return step.delayNanoseconds
        }
        return ordinaryTmuxChatSubmitEnterDelayNanoseconds
    }

    private static func isEnterOnly(_ input: String) -> Bool {
        input == "\r" || input == "\n" || input == "\r\n"
    }
}
