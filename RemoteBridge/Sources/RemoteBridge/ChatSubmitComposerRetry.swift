import Foundation

// Post-submit safety net for agent TUIs that occasionally swallow the
// chat_submit Enter (observed with Claude Code 2.1.283: paste and Enter both
// reached the pane, the text stayed in the composer and was sent together
// with the NEXT message).
//
// Runs AFTER the chat_submit response, off the request path, so the phone's
// 10 s request timeout and send flow are untouched. At most ONE retry Enter:
//   +0.8 s  check — anything but `.containsMessage` ends the check;
//   +0.8 s  check again — still `.containsMessage` ⇒ one retry Enter, sent
//           under the panel's submission reservation (skipped while another
//           submission owns the panel) and only into the pane just checked;
//   +0.8 s  check once more, for the log only.
// A newer chat_submit on the same panel cancels a pending check.
final class ChatSubmitComposerRetry: @unchecked Sendable {
    typealias Executor = (@escaping () -> Void) -> Void

    static let checkDelayNanoseconds: UInt64 = 800_000_000
    static let supportedVendorIDs: Set<String> = ["claude", "codex"]

    private let router: OrdinaryTmuxInputRouting
    private let sleep: (UInt64) -> Void
    private let executor: Executor
    private let lock = NSLock()
    private var generationByPanelID = [String: Int]()

    init(router: OrdinaryTmuxInputRouting,
         sleep: @escaping (UInt64) -> Void = { usleep(useconds_t($0 / 1_000)) },
         executor: @escaping Executor = ChatSubmitComposerRetry.backgroundExecutor()) {
        self.router = router
        self.sleep = sleep
        self.executor = executor
    }

    static func backgroundExecutor() -> Executor {
        let queue = DispatchQueue(label: "com.tidey.remote-bridge.chat-submit-composer-retry",
                                  attributes: .concurrent)
        return { work in queue.async(execute: work) }
    }

    /// Invalidates any pending check for the panel (a newer submission owns it now).
    func cancel(panelID: String) {
        lock.lock()
        let hadPendingCheck = generationByPanelID[panelID] != nil
        if hadPendingCheck {
            generationByPanelID[panelID, default: 0] += 1
        }
        lock.unlock()
        if hadPendingCheck {
            BridgeLogger.input.info("chat submit composer check state=cancelled_by_new_submit panel_id=\(panelID, privacy: .public)")
        }
    }

    func schedule(panelID: String, vendorID: String, message: String, requestID: String) {
        guard Self.supportedVendorIDs.contains(vendorID) else {
            return
        }
        lock.lock()
        generationByPanelID[panelID, default: 0] += 1
        let generation = generationByPanelID[panelID] ?? 0
        lock.unlock()
        executor { [self] in
            run(generation: generation,
                panelID: panelID,
                vendorID: vendorID,
                message: message,
                requestID: requestID)
        }
    }

    private func isCurrent(_ generation: Int, panelID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return generationByPanelID[panelID] == generation
    }

    private func finish(_ generation: Int, panelID: String) {
        lock.lock()
        if generationByPanelID[panelID] == generation {
            generationByPanelID.removeValue(forKey: panelID)
        }
        lock.unlock()
    }

    private func inspect(attempt: String,
                         panelID: String,
                         vendorID: String,
                         message: String,
                         requestID: String) -> (state: AgentComposerState, paneID: String?) {
        let state: AgentComposerState
        var paneID: String?
        do {
            if let capture = try router.captureComposerScreen(toPanelID: panelID) {
                paneID = capture.paneID
                state = AgentComposerInspector.classify(screen: capture.screen,
                                                        vendorID: vendorID,
                                                        message: message)
            } else {
                state = .unknown
            }
        } catch {
            state = .unknown
        }
        BridgeLogger.input.info("chat submit composer check request_id=\(requestID, privacy: .public) panel_id=\(panelID, privacy: .public) pane_id=\(paneID ?? "-", privacy: .public) vendor=\(vendorID, privacy: .public) attempt=\(attempt, privacy: .public) state=\(state.rawValue, privacy: .public)")
        return (state, paneID)
    }

    private func run(generation: Int,
                     panelID: String,
                     vendorID: String,
                     message: String,
                     requestID: String) {
        defer { finish(generation, panelID: panelID) }
        func check(_ attempt: String) -> (state: AgentComposerState, paneID: String?)? {
            sleep(Self.checkDelayNanoseconds)
            guard isCurrent(generation, panelID: panelID) else {
                return nil
            }
            return inspect(attempt: attempt, panelID: panelID, vendorID: vendorID,
                           message: message, requestID: requestID)
        }

        guard let first = check("1"), first.state == .containsMessage,
              let second = check("2"), second.state == .containsMessage,
              let paneID = second.paneID, paneID == first.paneID,
              isCurrent(generation, panelID: panelID) else {
            return
        }

        let outcome: OrdinaryTmuxComposerRetryOutcome
        do {
            outcome = try router.sendComposerRetryEnter(toPanelID: panelID, expectedPaneID: paneID)
        } catch {
            BridgeLogger.input.error("chat submit enter retry failed request_id=\(requestID, privacy: .public) panel_id=\(panelID, privacy: .public) pane_id=\(paneID, privacy: .public) error=\(String(describing: error), privacy: .public)")
            return
        }
        switch outcome {
        case .sent:
            BridgeLogger.input.info("chat submit enter retried request_id=\(requestID, privacy: .public) panel_id=\(panelID, privacy: .public) pane_id=\(paneID, privacy: .public) vendor=\(vendorID, privacy: .public)")
        case .busy:
            BridgeLogger.input.info("chat submit composer check state=skipped_busy request_id=\(requestID, privacy: .public) panel_id=\(panelID, privacy: .public)")
            return
        case .paneChanged:
            BridgeLogger.input.info("chat submit composer check state=skipped_route_changed request_id=\(requestID, privacy: .public) panel_id=\(panelID, privacy: .public)")
            return
        }

        guard let after = check("after_retry") else {
            return
        }
        if after.state == .containsMessage {
            BridgeLogger.input.error("chat submit enter unconfirmed request_id=\(requestID, privacy: .public) panel_id=\(panelID, privacy: .public) pane_id=\(paneID, privacy: .public) vendor=\(vendorID, privacy: .public)")
        } else {
            BridgeLogger.input.info("chat submit enter retry confirmed request_id=\(requestID, privacy: .public) panel_id=\(panelID, privacy: .public) state=\(after.state.rawValue, privacy: .public)")
        }
    }
}
