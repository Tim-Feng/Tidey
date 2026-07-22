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

    func testServerResolutionWinsWhileConfirmedWriteIsBlocked() throws {
        let sendEntered = DispatchSemaphore(value: 0)
        let releaseSend = DispatchSemaphore(value: 0)
        let terminalPublished = DispatchSemaphore(value: 0)
        let submitFinished = DispatchSemaphore(value: 0)
        let resolutionFinished = DispatchSemaphore(value: 0)
        let prompts = ConfirmedPromptSink()
        let terminals = ConfirmedEventSink()
        let submitResult = ConfirmedSubmitResultBox()
        let connection = Self.connection(
            sendLine: { _ in },
            sendLineConfirmed: { _ in
                sendEntered.signal()
                guard releaseSend.wait(timeout: .now() + 3) == .success else {
                    throw ConfirmedTestError.timedOut
                }
            },
            prompts: prompts,
            terminals: terminals,
            onTerminal: { _ in terminalPublished.signal() })
        connection.receiveLine(Self.commandApprovalLine)
        let prompt = try XCTUnwrap(prompts.values().first)

        DispatchQueue.global(qos: .userInitiated).async {
            submitResult.set(Result {
                try connection.submitApproval(
                    promptID: prompt.prompt.promptID,
                    targetIndex: 0,
                    clientRequestID: "client-1",
                    lifecycleToken: prompt.event.eventID)
            })
            submitFinished.signal()
        }
        XCTAssertEqual(sendEntered.wait(timeout: .now() + 1), .success)

        DispatchQueue.global(qos: .userInitiated).async {
            connection.receiveLine(Self.serverResolvedLine)
            resolutionFinished.signal()
        }
        let terminalArrivedBeforeRelease = terminalPublished.wait(timeout: .now() + 1)
        releaseSend.signal()

        XCTAssertEqual(terminalArrivedBeforeRelease, .success,
                       "authoritative resolution must not wait for the response writer")
        XCTAssertEqual(resolutionFinished.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(submitFinished.wait(timeout: .now() + 2), .success)
        let terminal = try XCTUnwrap(terminals.values().first)
        guard case .success(.alreadyResolved(let returned))? = submitResult.value() else {
            return XCTFail("submit must return the stored authoritative terminal")
        }
        XCTAssertEqual(returned.eventID, terminal.eventID)
        XCTAssertEqual(terminal.metadata?["reason"], "server_resolved")
        XCTAssertEqual(terminals.values().count, 1)
        XCTAssertTrue(connection.pendingApprovalPromptEvents().isEmpty)
    }

    func testCloseWinsWhileConfirmedWriteIsBlocked() throws {
        let sendEntered = DispatchSemaphore(value: 0)
        let releaseSend = DispatchSemaphore(value: 0)
        let terminalPublished = DispatchSemaphore(value: 0)
        let submitFinished = DispatchSemaphore(value: 0)
        let closeFinished = DispatchSemaphore(value: 0)
        let prompts = ConfirmedPromptSink()
        let terminals = ConfirmedEventSink()
        let submitResult = ConfirmedSubmitResultBox()
        let connection = Self.connection(
            sendLine: { _ in },
            sendLineConfirmed: { _ in
                sendEntered.signal()
                guard releaseSend.wait(timeout: .now() + 3) == .success else {
                    throw ConfirmedTestError.timedOut
                }
            },
            prompts: prompts,
            terminals: terminals,
            onTerminal: { _ in terminalPublished.signal() })
        connection.receiveLine(Self.commandApprovalLine)
        let prompt = try XCTUnwrap(prompts.values().first)

        DispatchQueue.global(qos: .userInitiated).async {
            submitResult.set(Result {
                try connection.submitApproval(
                    promptID: prompt.prompt.promptID,
                    targetIndex: 0,
                    clientRequestID: "client-1",
                    lifecycleToken: prompt.event.eventID)
            })
            submitFinished.signal()
        }
        XCTAssertEqual(sendEntered.wait(timeout: .now() + 1), .success)

        DispatchQueue.global(qos: .userInitiated).async {
            connection.close()
            closeFinished.signal()
        }
        let terminalArrivedBeforeRelease = terminalPublished.wait(timeout: .now() + 1)
        releaseSend.signal()

        XCTAssertEqual(terminalArrivedBeforeRelease, .success,
                       "close must not wait for the response writer")
        XCTAssertEqual(closeFinished.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(submitFinished.wait(timeout: .now() + 2), .success)
        let terminal = try XCTUnwrap(terminals.values().first)
        guard case .success(.alreadyResolved(let returned))? = submitResult.value() else {
            return XCTFail("submit must return the stored expiry terminal")
        }
        XCTAssertEqual(returned.eventID, terminal.eventID)
        XCTAssertEqual(terminal.metadata?["reason"], "expired")
        XCTAssertEqual(terminals.values().count, 1)
        XCTAssertTrue(connection.pendingApprovalPromptEvents().isEmpty)
    }

    func testAuthoritativeResolutionWinsWhenBlockedConfirmedWriteFails() throws {
        let sendEntered = DispatchSemaphore(value: 0)
        let releaseSend = DispatchSemaphore(value: 0)
        let terminalPublished = DispatchSemaphore(value: 0)
        let submitFinished = DispatchSemaphore(value: 0)
        let prompts = ConfirmedPromptSink()
        let terminals = ConfirmedEventSink()
        let submitResult = ConfirmedSubmitResultBox()
        let connection = Self.connection(
            sendLine: { _ in },
            sendLineConfirmed: { _ in
                sendEntered.signal()
                guard releaseSend.wait(timeout: .now() + 3) == .success else {
                    throw ConfirmedTestError.timedOut
                }
                throw ConfirmedTestError.writeFailed
            },
            prompts: prompts,
            terminals: terminals,
            onTerminal: { _ in terminalPublished.signal() })
        connection.receiveLine(Self.commandApprovalLine)
        let prompt = try XCTUnwrap(prompts.values().first)

        DispatchQueue.global(qos: .userInitiated).async {
            submitResult.set(Result {
                try connection.submitApproval(
                    promptID: prompt.prompt.promptID,
                    targetIndex: 0,
                    clientRequestID: "client-1",
                    lifecycleToken: prompt.event.eventID)
            })
            submitFinished.signal()
        }
        XCTAssertEqual(sendEntered.wait(timeout: .now() + 1), .success)
        connection.receiveLine(Self.serverResolvedLine)
        XCTAssertEqual(terminalPublished.wait(timeout: .now() + 1), .success)
        releaseSend.signal()

        XCTAssertEqual(submitFinished.wait(timeout: .now() + 2), .success)
        let terminal = try XCTUnwrap(terminals.values().first)
        guard case .success(.alreadyResolved(let returned))? = submitResult.value() else {
            return XCTFail("the authoritative terminal must supersede the write error")
        }
        XCTAssertEqual(returned.eventID, terminal.eventID)
        XCTAssertEqual(terminals.values().count, 1)
    }

    func testConcurrentResolutionAndClosePublishOneTerminal() throws {
        let prompts = ConfirmedPromptSink()
        let terminals = ConfirmedEventSink()
        let connection = Self.connection(
            sendLine: { _ in },
            sendLineConfirmed: nil,
            prompts: prompts,
            terminals: terminals)
        connection.receiveLine(Self.commandApprovalLine)
        XCTAssertEqual(prompts.values().count, 1)

        let start = DispatchSemaphore(value: 0)
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            _ = start.wait(timeout: .now() + 2)
            connection.receiveLine(Self.serverResolvedLine)
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            _ = start.wait(timeout: .now() + 2)
            connection.close()
            group.leave()
        }
        start.signal()
        start.signal()

        XCTAssertEqual(group.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(terminals.values().count, 1)
        XCTAssertTrue(["server_resolved", "expired"]
            .contains(try XCTUnwrap(terminals.values().first?.metadata?["reason"])))
        XCTAssertTrue(connection.pendingApprovalPromptEvents().isEmpty)
    }

    private static func connection(
        sendLine: @escaping CodexAppServerConnection.SendLine,
        sendLineConfirmed: CodexAppServerConnection.SendLine?,
        prompts: ConfirmedPromptSink,
        terminals: ConfirmedEventSink = ConfirmedEventSink(),
        onTerminal: @escaping (AgentEvent) -> Void = { _ in }
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
            onInteractivePromptResolved: {
                terminals.append($0)
                onTerminal($0)
            })
    }

    private static let commandApprovalLine = """
    {"id":"approval-1","method":"item/commandExecution/requestApproval","params":{"threadId":"thread-1","turnId":"turn-1","itemId":"item-1","startedAtMs":1786000000000,"command":"ls"}}
    """

    private static let userInputLine = """
    {"id":"input-1","method":"item/tool/requestUserInput","params":{"threadId":"thread-1","turnId":"turn-1","itemId":"item-input","questions":[{"id":"format","header":"Output","question":"Which format?","options":[{"label":"PNG","description":"Lossless"},{"label":"JPEG","description":"Compact"}]}]}}
    """

    private static let serverResolvedLine = """
    {"method":"serverRequest/resolved","params":{"threadId":"thread-1","requestId":"approval-1"}}
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

private enum ConfirmedTestError: Error {
    case timedOut
    case writeFailed
}

private final class ConfirmedSubmitResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Result<CodexAppServerApprovalSubmitOutcome, Error>?

    func set(_ value: Result<CodexAppServerApprovalSubmitOutcome, Error>) {
        lock.lock()
        storage = value
        lock.unlock()
    }

    func value() -> Result<CodexAppServerApprovalSubmitOutcome, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
