import Foundation
import XCTest
@testable import RemoteBridge

final class CodexAppServerConfirmedSendTests: XCTestCase {
    func testLifecycleApprovalUsesConfirmedWriter() throws {
        let ordinary = ConfirmedLineSink()
        let confirmed = ConfirmedLineSink()
        let prompts = ConfirmedPromptSink()
        let connection = Self.connection(
            sendLine: { ordinary.append($0) },
            sendLineConfirmed: { confirmed.append($0) },
            prompts: prompts)
        connection.receiveLine(Self.commandApprovalLine)
        let prompt = try XCTUnwrap(prompts.values().first)

        guard case .pendingConfirmation = try connection.submitApproval(
            promptID: prompt.prompt.promptID,
            targetIndex: 0,
            clientRequestID: "client-1",
            lifecycleToken: prompt.event.eventID) else {
            return XCTFail("a confirmed write must still await an authoritative terminal")
        }

        XCTAssertTrue(ordinary.values().isEmpty)
        XCTAssertEqual(confirmed.values().count, 1)
        XCTAssertTrue(try XCTUnwrap(confirmed.values().first)
            .hasPrefix(#"{"id":"approval-1","result":"#))
    }

    func testLifecycleUserInputUsesConfirmedWriter() throws {
        let ordinary = ConfirmedLineSink()
        let confirmed = ConfirmedLineSink()
        let prompts = ConfirmedPromptSink()
        let connection = Self.connection(
            sendLine: { ordinary.append($0) },
            sendLineConfirmed: { confirmed.append($0) },
            prompts: prompts)
        connection.receiveLine(Self.userInputLine)
        let prompt = try XCTUnwrap(prompts.values().first)

        guard case .pendingConfirmation = try connection.submitUserInput(
            promptID: prompt.prompt.promptID,
            answers: ["format": ["PNG"]],
            clientRequestID: "client-input",
            lifecycleToken: prompt.event.eventID) else {
            return XCTFail("a confirmed write must still await an authoritative terminal")
        }

        XCTAssertTrue(ordinary.values().isEmpty)
        let response = try Self.object(from: XCTUnwrap(confirmed.values().first))
        XCTAssertEqual(response["result"]?.objectValue?["answers"]?
            .objectValue?["format"]?.objectValue?["answers"]?.arrayValue,
                       [.string("PNG")])
    }

    func testConfirmedWriteFailureRestoresPendingAndAllowsSameDecisionRetry() throws {
        struct ConfirmedWriteFailure: Error {}

        let ordinary = ConfirmedLineSink()
        let confirmed = ConfirmedLineSink()
        let prompts = ConfirmedPromptSink()
        let failWrites = ConfirmedFlag(true)
        let connection = Self.connection(
            sendLine: { ordinary.append($0) },
            sendLineConfirmed: { line in
                if failWrites.value() {
                    throw ConfirmedWriteFailure()
                }
                confirmed.append(line)
            },
            prompts: prompts)
        connection.receiveLine(Self.commandApprovalLine)
        let prompt = try XCTUnwrap(prompts.values().first)

        XCTAssertThrowsError(try connection.submitApproval(
            promptID: prompt.prompt.promptID,
            targetIndex: 0,
            clientRequestID: "client-1",
            lifecycleToken: prompt.event.eventID)) { error in
                XCTAssertTrue(error is ConfirmedWriteFailure)
            }
        XCTAssertEqual(connection.pendingApprovalPromptEvents().first?
            .metadata?["submit_state"], "pending")
        XCTAssertTrue(ordinary.values().isEmpty)

        failWrites.set(false)
        guard case .pendingConfirmation = try connection.submitApproval(
            promptID: prompt.prompt.promptID,
            targetIndex: 0,
            clientRequestID: "client-1",
            lifecycleToken: prompt.event.eventID) else {
            return XCTFail("the same decision should be retryable")
        }
        XCTAssertEqual(confirmed.values().count, 1)
        XCTAssertTrue(ordinary.values().isEmpty)
    }

    private static func connection(
        sendLine: @escaping CodexAppServerConnection.SendLine,
        sendLineConfirmed: CodexAppServerConnection.SendLine?,
        prompts: ConfirmedPromptSink,
        terminals: ConfirmedEventSink = ConfirmedEventSink()
    ) -> CodexAppServerConnection {
        CodexAppServerConnection(
            sendLine: sendLine,
            sendLineConfirmed: sendLineConfirmed,
            approvalContext: CodexAppServerApprovalContext(
                workspaceID: "workspace-1",
                panelID: "panel-1",
                sessionID: "session-1",
                epoch: "process-epoch"),
            nextSequence: { _ in 1 },
            timestampProvider: { "2026-07-22T00:00:00.000Z" },
            onInteractivePrompt: { prompts.append($0) },
            onInteractivePromptResolved: { terminals.append($0) })
    }

    private static let commandApprovalLine = """
    {"id":"approval-1","method":"item/commandExecution/requestApproval","params":{"threadId":"thread-1","turnId":"turn-1","itemId":"item-1","startedAtMs":1786000000000,"command":"ls"}}
    """

    private static let userInputLine = """
    {"id":"input-1","method":"item/tool/requestUserInput","params":{"threadId":"thread-1","turnId":"turn-1","itemId":"item-input","questions":[{"id":"format","header":"Output","question":"Which format?","options":[{"label":"PNG","description":"Lossless"},{"label":"JPEG","description":"Compact"}]}]}}
    """

    private static func object(from line: String) throws -> [String: JSONValue] {
        let data = try XCTUnwrap(line.trimmingCharacters(in: .whitespacesAndNewlines)
            .data(using: .utf8))
        return try XCTUnwrap(JSONDecoder().decode(JSONValue.self, from: data).objectValue)
    }
}

private final class ConfirmedLineSink: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func append(_ line: String) {
        lock.lock()
        storage.append(line)
        lock.unlock()
    }

    func values() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private final class ConfirmedPromptSink: @unchecked Sendable {
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

private final class ConfirmedEventSink: @unchecked Sendable {
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

private final class ConfirmedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Bool

    init(_ value: Bool) {
        storage = value
    }

    func set(_ value: Bool) {
        lock.lock()
        storage = value
        lock.unlock()
    }

    func value() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
