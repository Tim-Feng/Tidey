import Foundation
import XCTest
@testable import RemoteBridge

final class CodexAppServerRequestCollisionTests: XCTestCase {
    func testEquivalentRedeliveryWithReorderedParamsKeepsAssociation() throws {
        let lines = WireLineSink()
        let prompts = WirePromptSink()
        let terminals = WireEventSink()
        let violations = WireCounter()
        let connection = Self.connection(lines: lines,
                                         prompts: prompts,
                                         terminals: terminals,
                                         violations: violations)

        connection.receiveLine(Self.approvalLine)
        connection.receiveLine(Self.reorderedEquivalentApprovalLine)

        let deliveries = prompts.values()
        XCTAssertEqual(deliveries.count, 2)
        XCTAssertEqual(deliveries[0].prompt.promptID,
                       deliveries[1].prompt.promptID)
        XCTAssertNotEqual(deliveries[0].event.eventID,
                          deliveries[1].event.eventID)
        XCTAssertTrue(terminals.values().isEmpty)
        XCTAssertEqual(violations.value(), 0)

        guard case .pendingConfirmation = try connection.submitApproval(
            promptID: deliveries[1].prompt.promptID,
            targetIndex: 0,
            clientRequestID: "client-1",
            lifecycleToken: deliveries[1].event.eventID) else {
            return XCTFail("equivalent redelivery should retain a safe response association")
        }
        XCTAssertEqual(lines.values().count, 1)
    }

    func testHiddenPreWirePayloadChangeSupersedesOldLifecycle() throws {
        let lines = WireLineSink()
        let prompts = WirePromptSink()
        let terminals = WireEventSink()
        let violations = WireCounter()
        let connection = Self.connection(lines: lines,
                                         prompts: prompts,
                                         terminals: terminals,
                                         violations: violations)

        connection.receiveLine(Self.approvalLine)
        let first = try XCTUnwrap(prompts.values().first)
        connection.receiveLine(Self.hiddenPayloadChangedApprovalLine)

        let deliveries = prompts.values()
        XCTAssertEqual(deliveries.count, 2)
        XCTAssertEqual(deliveries[0].prompt.promptID,
                       deliveries[1].prompt.promptID)
        XCTAssertEqual(terminals.values().count, 1)
        XCTAssertEqual(terminals.values().first?.metadata?["reason"], "superseded")
        XCTAssertEqual(terminals.values().first?.metadata?["lifecycle_token"],
                       first.event.eventID)
        XCTAssertEqual(violations.value(), 0,
                       "a pre-wire replacement is safe and must not abort")
        XCTAssertTrue(lines.values().isEmpty)
    }

    func testInt64ExactHiddenChangeDoesNotCollapseFingerprints() {
        let prompts = WirePromptSink()
        let terminals = WireEventSink()
        let violations = WireCounter()
        let connection = Self.connection(prompts: prompts,
                                         terminals: terminals,
                                         violations: violations)

        connection.receiveLine(Self.int64ApprovalLine(value: 9_007_199_254_740_993))
        connection.receiveLine(Self.int64ApprovalLine(value: 9_007_199_254_740_992))

        XCTAssertEqual(prompts.values().count, 2)
        XCTAssertEqual(terminals.values().count, 1)
        XCTAssertEqual(terminals.values().first?.metadata?["reason"], "superseded")
        XCTAssertEqual(violations.value(), 0)
    }

    func testPostWireCollisionAbortsAndTerminalizesAllPendingExactlyOnce() throws {
        let lines = WireLineSink()
        let prompts = WirePromptSink()
        let terminals = WireEventSink()
        let clientResponses = WireClientResponseSink()
        let violations = WireCounter()
        let connection = Self.connection(lines: lines,
                                         prompts: prompts,
                                         terminals: terminals,
                                         violations: violations)
        connection.receiveLine(Self.approvalLine)
        connection.receiveLine(Self.secondApprovalLine)
        let firstPrompt = try XCTUnwrap(prompts.values().first)
        _ = try connection.sendClientRequest(method: "thread/list") {
            clientResponses.append($0)
        }
        _ = try connection.sendClientRequest(method: "model/list") {
            clientResponses.append($0)
        }
        guard case .pendingConfirmation = try connection.submitApproval(
            promptID: firstPrompt.prompt.promptID,
            targetIndex: 0,
            clientRequestID: "approval-client",
            lifecycleToken: firstPrompt.event.eventID) else {
            return XCTFail("the initial response should await confirmation")
        }
        XCTAssertEqual(lines.values().count, 3)

        connection.receiveLine(Self.hiddenPayloadChangedApprovalLine)

        XCTAssertEqual(violations.value(), 1)
        XCTAssertEqual(prompts.values().count, 2,
                       "poisoned content must never become actionable")
        XCTAssertEqual(lines.values().count, 3,
                       "the poisoned id must write no additional response")
        XCTAssertTrue(connection.pendingApprovalPromptEvents().isEmpty)
        let terminalValues = terminals.values()
        XCTAssertEqual(terminalValues.count, 2)
        XCTAssertEqual(Set(terminalValues.map(\.eventID)).count, 2)
        XCTAssertEqual(Set(terminalValues.compactMap { $0.metadata?["reason"] }),
                       ["protocol_violation"])
        XCTAssertEqual(clientResponses.values().count, 2)
        for response in clientResponses.values() {
            guard case .failure(.protocolViolation) = response else {
                return XCTFail("all pending client requests must fail with protocolViolation")
            }
        }

        connection.receiveLine(Self.hiddenPayloadChangedApprovalLine)
        connection.receiveLine(Self.approvalLine)
        connection.close()
        XCTAssertEqual(violations.value(), 1)
        XCTAssertEqual(terminals.values().count, 2)
        XCTAssertEqual(clientResponses.values().count, 2)
        XCTAssertEqual(lines.values().count, 3)
    }

    func testUnsupportedMethodCannotWriteUnderTaintedApprovalID() throws {
        let lines = WireLineSink()
        let prompts = WirePromptSink()
        let terminals = WireEventSink()
        let violations = WireCounter()
        let connection = Self.connection(lines: lines,
                                         prompts: prompts,
                                         terminals: terminals,
                                         violations: violations)
        connection.receiveLine(Self.approvalLine)
        let prompt = try XCTUnwrap(prompts.values().first)
        _ = try connection.submitApproval(promptID: prompt.prompt.promptID,
                                          targetIndex: 0,
                                          clientRequestID: "client-1",
                                          lifecycleToken: prompt.event.eventID)
        XCTAssertEqual(lines.values().count, 1)

        connection.receiveLine(#"{"id":"approval-1","method":"unknown/method","params":{"value":1}}"#)

        XCTAssertEqual(violations.value(), 1)
        XCTAssertEqual(lines.values().count, 1)
        XCTAssertEqual(terminals.values().count, 1)
        XCTAssertEqual(terminals.values().first?.metadata?["reason"],
                       "protocol_violation")
    }

    func testErrorResponseTaintsIDAgainstLaterApproval() {
        let lines = WireLineSink()
        let prompts = WirePromptSink()
        let violations = WireCounter()
        let connection = Self.connection(lines: lines,
                                         prompts: prompts,
                                         violations: violations)

        connection.receiveLine(#"{"id":"approval-1","method":"unknown/method","params":{"value":1}}"#)
        XCTAssertEqual(lines.values().count, 1)
        connection.receiveLine(Self.approvalLine)

        XCTAssertEqual(violations.value(), 1)
        XCTAssertTrue(prompts.values().isEmpty)
        XCTAssertEqual(lines.values().count, 1)
    }

    func testMissingAndEmptyParamsHaveDifferentFingerprints() {
        let lines = WireLineSink()
        let violations = WireCounter()
        let connection = Self.connection(lines: lines,
                                         violations: violations)

        connection.receiveLine(#"{"id":"request-1","method":"unknown/method"}"#)
        XCTAssertEqual(lines.values().count, 1)
        connection.receiveLine(#"{"id":"request-1","method":"unknown/method","params":{}}"#)

        XCTAssertEqual(violations.value(), 1)
        XCTAssertEqual(lines.values().count, 1)
    }

    private static func connection(
        lines: WireLineSink = WireLineSink(),
        prompts: WirePromptSink = WirePromptSink(),
        terminals: WireEventSink = WireEventSink(),
        violations: WireCounter
    ) -> CodexAppServerConnection {
        let sequence = WireCounter()
        return CodexAppServerConnection(
            sendLine: { lines.append($0) },
            sendLineConfirmed: { lines.append($0) },
            approvalContext: CodexAppServerApprovalContext(
                workspaceID: "workspace-1",
                panelID: "panel-1",
                sessionID: "session-1",
                epoch: "process-epoch"),
            nextSequence: { _ in sequence.next() },
            timestampProvider: { "2026-07-22T00:00:00.000Z" },
            onInteractivePrompt: { prompts.append($0) },
            onInteractivePromptResolved: { terminals.append($0) },
            onProtocolViolation: { _ = violations.next() })
    }

    private static let approvalLine = """
    {"id":"approval-1","method":"item/commandExecution/requestApproval","params":{"threadId":"thread-1","turnId":"turn-1","itemId":"item-1","startedAtMs":1786000000000,"command":"ls","opaque":{"policy":1,"mode":"safe"}}}
    """

    private static let reorderedEquivalentApprovalLine = """
    {"method":"item/commandExecution/requestApproval","params":{"opaque":{"mode":"safe","policy":1},"command":"ls","startedAtMs":1786000000000,"itemId":"item-1","turnId":"turn-1","threadId":"thread-1"},"id":"approval-1"}
    """

    private static let hiddenPayloadChangedApprovalLine = """
    {"id":"approval-1","method":"item/commandExecution/requestApproval","params":{"threadId":"thread-1","turnId":"turn-1","itemId":"item-1","startedAtMs":1786000000000,"command":"ls","opaque":{"policy":2,"mode":"safe"}}}
    """

    private static let secondApprovalLine = """
    {"id":"approval-2","method":"item/commandExecution/requestApproval","params":{"threadId":"thread-1","turnId":"turn-2","itemId":"item-2","startedAtMs":1786000000001,"command":"pwd"}}
    """

    private static func int64ApprovalLine(value: Int64) -> String {
        """
        {"id":"approval-int64","method":"item/commandExecution/requestApproval","params":{"threadId":"thread-1","turnId":"turn-int64","itemId":"item-int64","startedAtMs":1786000000000,"command":"ls","opaque":\(value)}}
        """
    }
}

private final class WireLineSink: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func append(_ value: String) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }

    func values() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private final class WirePromptSink: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [CodexAppServerInteractivePromptEnvelope] = []

    func append(_ value: CodexAppServerInteractivePromptEnvelope) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }

    func values() -> [CodexAppServerInteractivePromptEnvelope] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private final class WireEventSink: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [AgentEvent] = []

    func append(_ value: AgentEvent) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }

    func values() -> [AgentEvent] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private final class WireClientResponseSink: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Result<JSONValue, CodexAppServerConnectionError>] = []

    func append(_ value: Result<JSONValue, CodexAppServerConnectionError>) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }

    func values() -> [Result<JSONValue, CodexAppServerConnectionError>] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private final class WireCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    @discardableResult
    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        storage += 1
        return storage
    }

    func value() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
