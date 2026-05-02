import XCTest
@testable import RemoteBridge

final class BridgeInputActionHandlerTests: XCTestCase {
    func testTerminalInputForwardsRawSendInputRequest() throws {
        let sender = MockTideyRequestSender()
        let resolver = MockSessionResolver()
        let handler = BridgeInputActionHandler(socketSender: sender, sessionResolver: resolver)

        let response = try handler.handle(BridgeRequest(id: "request-1",
                                                        action: "terminal_input",
                                                        params: [
                                                            "panel_id": .string("panel-1"),
                                                            "input": .string("ls\r"),
                                                        ]))

        XCTAssertEqual(response?.ok, true)
        XCTAssertEqual(sender.sentRequests.count, 1)
        XCTAssertEqual(sender.sentRequests.first?.action, "send_input")
        XCTAssertEqual(sender.sentRequests.first?.params?["panel_id"]?.stringValue, "panel-1")
        XCTAssertEqual(sender.sentRequests.first?.params?["input"]?.stringValue, "ls\r")
    }

    func testTerminalInputRoutesOrdinaryTmuxPanelWithoutMacSocketForward() throws {
        let sender = MockTideyRequestSender()
        let resolver = MockSessionResolver()
        let router = MockOrdinaryTmuxInputRouter(routedPanelIDs: ["ordinary-panel"])
        let handler = BridgeInputActionHandler(socketSender: sender,
                                               sessionResolver: resolver,
                                               ordinaryTmuxInputRouter: router)

        let response = try handler.handle(BridgeRequest(id: "request-1",
                                                        action: "terminal_input",
                                                        params: [
                                                            "panel_id": .string("ordinary-panel"),
                                                            "input": .string("ls\r"),
                                                        ]))

        XCTAssertEqual(response?.ok, true)
        XCTAssertTrue(sender.sentRequests.isEmpty)
        XCTAssertEqual(router.sentInputs.map(\.panelID), ["ordinary-panel"])
        XCTAssertEqual(router.sentInputs.map(\.input), ["ls\r"])
    }

    func testChatSubmitForClaudeSplitsMultilineTextAndEnterWithDelay() throws {
        let sender = MockTideyRequestSender()
        let resolver = MockSessionResolver(session: ActiveAgentSessionSnapshot(vendor: "claude",
                                                                              workspaceID: "workspace-1",
                                                                              sessionID: "session-1",
                                                                              panelID: "panel-1"))
        let delayRecorder = DelayRecorder()
        let handler = BridgeInputActionHandler(socketSender: sender,
                                               sessionResolver: resolver,
                                               sleep: { delayRecorder.record($0) })
        let message = "@/Users/timfeng/Downloads/Tidey-Remote/a.jpg\n\n拍照ok"

        let response = try handler.handle(BridgeRequest(id: "request-1",
                                                        action: "chat_submit",
                                                        params: [
                                                            "workspace_id": .string("workspace-1"),
                                                            "panel_id": .string("panel-1"),
                                                            "message": .string(message),
                                                            "session_id": .string("session-1"),
                                                            "vendor": .string("claude"),
                                                        ]))

        XCTAssertEqual(response?.ok, true)
        XCTAssertEqual(sender.sentRequests.map { $0.params?["input"]?.stringValue }, [message, "\r"])
        XCTAssertEqual(delayRecorder.recordedDelays, [chatSubmitEnterDelayNanoseconds])
    }

    func testChatSubmitForCodexSplitsTextAndEnterWithDelay() throws {
        let sender = MockTideyRequestSender()
        let resolver = MockSessionResolver(session: ActiveAgentSessionSnapshot(vendor: "codex",
                                                                              workspaceID: "workspace-1",
                                                                              sessionID: "session-1",
                                                                              panelID: "panel-1"))
        let delayRecorder = DelayRecorder()
        let handler = BridgeInputActionHandler(socketSender: sender,
                                               sessionResolver: resolver,
                                               sleep: { delayRecorder.record($0) })

        let response = try handler.handle(BridgeRequest(id: "request-1",
                                                        action: "chat_submit",
                                                        params: [
                                                            "workspace_id": .string("workspace-1"),
                                                            "panel_id": .string("panel-1"),
                                                            "message": .string("hello"),
                                                            "session_id": .string("session-1"),
                                                            "vendor": .string("codex"),
                                                        ]))

        XCTAssertEqual(response?.ok, true)
        XCTAssertEqual(sender.sentRequests.map { $0.params?["input"]?.stringValue }, ["hello", "\r"])
        XCTAssertEqual(delayRecorder.recordedDelays, [chatSubmitEnterDelayNanoseconds])
    }

    func testChatSubmitRoutesOrdinaryTmuxPanelStepsWithoutMacSocketForward() throws {
        let sender = MockTideyRequestSender()
        let resolver = MockSessionResolver(session: ActiveAgentSessionSnapshot(vendor: "codex",
                                                                              workspaceID: "workspace-1",
                                                                              sessionID: "session-1",
                                                                              panelID: "ordinary-panel"))
        let router = MockOrdinaryTmuxInputRouter(routedPanelIDs: ["ordinary-panel"])
        let delayRecorder = DelayRecorder()
        let handler = BridgeInputActionHandler(socketSender: sender,
                                               sessionResolver: resolver,
                                               ordinaryTmuxInputRouter: router,
                                               sleep: { delayRecorder.record($0) })

        let response = try handler.handle(BridgeRequest(id: "request-1",
                                                        action: "chat_submit",
                                                        params: [
                                                            "workspace_id": .string("workspace-1"),
                                                            "panel_id": .string("ordinary-panel"),
                                                            "message": .string("hello"),
                                                            "session_id": .string("session-1"),
                                                            "vendor": .string("codex"),
                                                        ]))

        XCTAssertEqual(response?.ok, true)
        XCTAssertTrue(sender.sentRequests.isEmpty)
        XCTAssertEqual(router.sentInputs.map(\.panelID), ["ordinary-panel", "ordinary-panel"])
        XCTAssertEqual(router.sentInputs.map(\.input), ["hello", "\r"])
        XCTAssertEqual(delayRecorder.recordedDelays, [chatSubmitEnterDelayNanoseconds])
    }

    func testChatSubmitRejectsMismatchedSession() throws {
        let sender = MockTideyRequestSender()
        let resolver = MockSessionResolver(session: ActiveAgentSessionSnapshot(vendor: "codex",
                                                                              workspaceID: "workspace-1",
                                                                              sessionID: "session-1",
                                                                              panelID: "panel-1"))
        let handler = BridgeInputActionHandler(socketSender: sender, sessionResolver: resolver)

        XCTAssertThrowsError(
            try handler.handle(BridgeRequest(id: "request-1",
                                             action: "chat_submit",
                                             params: [
                                                "workspace_id": .string("workspace-1"),
                                                "panel_id": .string("panel-1"),
                                                "message": .string("hello"),
                                                "session_id": .string("session-2"),
                                                "vendor": .string("codex"),
                                             ]))
        ) { error in
            guard case BridgeInternalError.invalidRequest(let message) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(message.contains("session_id"))
        }
        XCTAssertTrue(sender.sentRequests.isEmpty)
    }

    func testChatSubmitRejectsUnsupportedVendor() {
        let sender = MockTideyRequestSender()
        let resolver = MockSessionResolver()
        let handler = BridgeInputActionHandler(socketSender: sender, sessionResolver: resolver)

        XCTAssertThrowsError(
            try handler.handle(BridgeRequest(id: "request-1",
                                             action: "chat_submit",
                                             params: [
                                                "workspace_id": .string("workspace-1"),
                                                "panel_id": .string("panel-1"),
                                                "message": .string("hello"),
                                                "vendor": .string("unknown-agent"),
                                             ]))
        ) { error in
            guard case BridgeInternalError.invalidRequest(let message) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(message.contains("not supported"))
        }
        XCTAssertTrue(sender.sentRequests.isEmpty)
    }
}

private final class MockSessionResolver: ActiveAgentSessionResolving {
    private let session: ActiveAgentSessionSnapshot?

    init(session: ActiveAgentSessionSnapshot? = nil) {
        self.session = session
    }

    func activeSessionForPanel(workspaceID: String, panelID: String) -> ActiveAgentSessionSnapshot? {
        session
    }
}

private final class MockTideyRequestSender: TideyRequestSending {
    private(set) var sentRequests = [BridgeRequest]()

    func send(_ request: BridgeRequest) throws -> BridgeResponse {
        sentRequests.append(request)
        return BridgeResponse(id: request.id,
                              ok: true,
                              result: ["ok": .bool(true)],
                              error: nil)
    }
}

private final class MockOrdinaryTmuxInputRouter: OrdinaryTmuxInputRouting, @unchecked Sendable {
    private let routedPanelIDs: Set<String>
    private(set) var sentInputs = [(panelID: String, input: String)]()

    init(routedPanelIDs: Set<String>) {
        self.routedPanelIDs = routedPanelIDs
    }

    func sendInput(_ input: String, toPanelID panelID: String) throws -> Bool {
        guard routedPanelIDs.contains(panelID) else {
            return false
        }
        sentInputs.append((panelID, input))
        return true
    }
}

private final class DelayRecorder: @unchecked Sendable {
    private var storage = [UInt64]()
    private let lock = NSLock()

    var recordedDelays: [UInt64] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func record(_ delay: UInt64) {
        lock.lock()
        storage.append(delay)
        lock.unlock()
    }
}
