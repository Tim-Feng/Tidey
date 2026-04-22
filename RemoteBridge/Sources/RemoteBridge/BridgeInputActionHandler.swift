import Darwin
import Foundation

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
    private let sleep: @Sendable (UInt64) throws -> Void

    init(socketSender: TideyRequestSending,
         sessionResolver: ActiveAgentSessionResolving,
         sleep: @escaping @Sendable (UInt64) throws -> Void = { delayNanoseconds in
             guard delayNanoseconds > 0 else {
                 return
             }
             usleep(useconds_t(delayNanoseconds / 1_000))
         }) {
        self.socketSender = socketSender
        self.sessionResolver = sessionResolver
        self.sleep = sleep
    }

    func handle(_ request: BridgeRequest) throws -> BridgeResponse? {
        switch request.action {
        case "terminal_input":
            return try forwardTerminalInput(request)
        case "chat_submit":
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

        for (index, step) in vendor.submitMessagePlan(text: message).enumerated() {
            if index > 0 {
                try sleep(step.delayNanoseconds)
            }
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
        }

        return BridgeResponse(id: request.id,
                              ok: true,
                              result: [
                                "submitted": .bool(true),
                                "vendor": .string(vendor.id),
                                "session_id": activeSession.map { .string($0.sessionID) } ?? .null,
                              ],
                              error: nil)
    }

    private func summarizedTail(_ input: String) -> String {
        String(input.suffix(3))
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
    }
}
