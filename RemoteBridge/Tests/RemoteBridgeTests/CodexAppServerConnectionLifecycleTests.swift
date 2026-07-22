import Foundation
import XCTest
@testable import RemoteBridge

final class CodexAppServerConnectionLifecycleTests: XCTestCase {
    func testLifecycleSubmitStaysPendingUntilServerResolved() throws {
        let outbound = LifecycleLineSink()
        let prompts = LifecyclePromptSink()
        let terminals = LifecycleEventSink()
        let connection = Self.connection(outbound: outbound,
                                         prompts: prompts,
                                         terminals: terminals)
        connection.receiveLine(Self.commandLine(id: #""approval-1""#,
                                                itemID: "item-1",
                                                turnID: "turn-1",
                                                command: "ls"))
        let prompt = try XCTUnwrap(prompts.values().first)
        let token = try XCTUnwrap(prompt.event.payload?.objectValue?["lifecycle_token"]?.stringValue)

        let outcome = try connection.submitApproval(promptID: prompt.prompt.promptID,
                                                    targetIndex: 0,
                                                    clientRequestID: "client-1",
                                                    lifecycleToken: token)
        guard case .pendingConfirmation(let promptID) = outcome else {
            return XCTFail("a local response flush is not an authoritative terminal")
        }
        XCTAssertEqual(promptID, prompt.prompt.promptID)
        XCTAssertTrue(terminals.values().isEmpty)
        XCTAssertEqual(connection.pendingApprovalPromptEvents().first?
            .metadata?["submit_state"], "submitting")
        XCTAssertTrue(outbound.values()[0].hasPrefix(#"{"id":"approval-1","result":"#))

        connection.receiveLine(#"{"method":"serverRequest/resolved","params":{"threadId":"thread-1","requestId":"approval-1"}}"#)

        let terminal = try XCTUnwrap(terminals.values().first)
        XCTAssertEqual(terminal.metadata?["reason"], "server_resolved")
        XCTAssertEqual(terminal.metadata?["lifecycle_token"], token)
        XCTAssertEqual(terminal.payload?.objectValue?["lifecycle_token"]?.stringValue,
                       token)
        XCTAssertTrue(connection.pendingApprovalPromptEvents().isEmpty)
    }

    func testIdenticalRedeliveryRotatesAttemptAndCapability() throws {
        let prompts = LifecyclePromptSink()
        let connection = Self.connection(prompts: prompts)
        let line = Self.commandLine(id: #""approval-1""#,
                                    itemID: "item-1",
                                    turnID: "turn-1",
                                    command: "ls")

        connection.receiveLine(line)
        connection.receiveLine(line)

        let values = prompts.values()
        XCTAssertEqual(values.count, 2)
        XCTAssertEqual(values[0].prompt.promptID, values[1].prompt.promptID)
        XCTAssertNotEqual(values[0].event.eventID, values[1].event.eventID)
        XCTAssertEqual(values[0].event.metadata?["attempt"], "1")
        XCTAssertEqual(values[1].event.metadata?["attempt"], "2")
        XCTAssertEqual(connection.pendingApprovalPromptEvents().first?.eventID,
                       values[1].event.eventID)
    }

    func testChangedPayloadTerminatesOldAttemptBeforePublishingReplacement() throws {
        let prompts = LifecyclePromptSink()
        let terminals = LifecycleEventSink()
        let connection = Self.connection(prompts: prompts, terminals: terminals)

        connection.receiveLine(Self.commandLine(id: #""approval-1""#,
                                                itemID: "item-1",
                                                turnID: "turn-1",
                                                command: "ls"))
        connection.receiveLine(Self.commandLine(id: #""approval-1""#,
                                                itemID: "item-1",
                                                turnID: "turn-1",
                                                command: "rm -rf /tmp/example"))

        let promptValues = prompts.values()
        XCTAssertEqual(promptValues.count, 2)
        XCTAssertEqual(promptValues[0].prompt.promptID,
                       promptValues[1].prompt.promptID)
        XCTAssertTrue(promptValues[1].prompt.body.contains("rm -rf /tmp/example"))
        XCTAssertEqual(promptValues[1].event.metadata?["attempt"], "2")
        let terminal = try XCTUnwrap(terminals.values().first)
        XCTAssertEqual(terminal.metadata?["reason"], "superseded")
        XCTAssertEqual(terminal.metadata?["attempt"], "1")
        XCTAssertEqual(terminal.metadata?["lifecycle_token"],
                       promptValues[0].event.eventID)
    }

    func testPendingSnapshotsReusePublishedIdentityWithoutAllocatingSequence() throws {
        let prompts = LifecyclePromptSink()
        let sequence = LifecycleCounter()
        let connection = Self.connection(prompts: prompts,
                                         nextSequence: { _ in sequence.next() })
        connection.receiveLine(Self.commandLine(id: #""approval-1""#,
                                                itemID: "item-1",
                                                turnID: "turn-1",
                                                command: "ls"))
        let published = try XCTUnwrap(prompts.values().first?.event)
        XCTAssertEqual(sequence.value(), 1)

        let first = try XCTUnwrap(connection.pendingApprovalPromptEvents().first)
        let second = try XCTUnwrap(connection.pendingApprovalPromptEvents().first)

        XCTAssertEqual(first.eventID, published.eventID)
        XCTAssertEqual(first.seq, published.seq)
        XCTAssertEqual(first.timestamp, published.timestamp)
        XCTAssertEqual(second.eventID, published.eventID)
        XCTAssertEqual(sequence.value(), 1,
                       "recovery snapshots must not consume sequence numbers")
        XCTAssertEqual(first.metadata?["submit_state"], "pending")
    }

    func testTurnCompletedResolvesOnlyMatchingTurn() throws {
        let prompts = LifecyclePromptSink()
        let terminals = LifecycleEventSink()
        let connection = Self.connection(prompts: prompts, terminals: terminals)
        connection.receiveLine(Self.commandLine(id: #""approval-1""#,
                                                itemID: "item-1",
                                                turnID: "turn-1",
                                                command: "ls"))
        connection.receiveLine(Self.commandLine(id: #""approval-2""#,
                                                itemID: "item-2",
                                                turnID: "turn-2",
                                                command: "pwd"))

        connection.receiveLine(#"{"method":"turn/completed","params":{"threadId":"thread-1","turnId":"turn-1"}}"#)

        XCTAssertEqual(terminals.values().count, 1)
        XCTAssertEqual(terminals.values()[0].metadata?["reason"], "turn_completed")
        let pending = connection.pendingApprovalPromptEvents()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending[0].metadata?["turn_id"], "turn-2")
    }

    func testServerResolvedKeepsStringAndIntegerRequestIDsDistinct() {
        let prompts = LifecyclePromptSink()
        let terminals = LifecycleEventSink()
        let connection = Self.connection(prompts: prompts, terminals: terminals)
        connection.receiveLine(Self.commandLine(id: #""1""#,
                                                itemID: "item-string",
                                                turnID: "turn-1",
                                                command: "ls"))
        connection.receiveLine(Self.commandLine(id: "1",
                                                itemID: "item-integer",
                                                turnID: "turn-1",
                                                command: "pwd"))

        connection.receiveLine(#"{"method":"serverRequest/resolved","params":{"threadId":"thread-1","requestId":1}}"#)

        XCTAssertEqual(terminals.values().count, 1)
        XCTAssertEqual(terminals.values()[0].metadata?["request_id"], "i:1")
        let pending = connection.pendingApprovalPromptEvents()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending[0].metadata?["request_id"], "s:1")
    }

    func testCloseExpiresPendingPromptOnceAndRejectsRedelivery() throws {
        let outbound = LifecycleLineSink()
        let prompts = LifecyclePromptSink()
        let terminals = LifecycleEventSink()
        let connection = Self.connection(outbound: outbound,
                                         prompts: prompts,
                                         terminals: terminals)
        let line = Self.commandLine(id: #""approval-1""#,
                                    itemID: "item-1",
                                    turnID: "turn-1",
                                    command: "ls")
        connection.receiveLine(line)
        let token = try XCTUnwrap(prompts.values().first?.event.eventID)

        connection.close()
        connection.close()
        connection.receiveLine(line)

        XCTAssertEqual(prompts.values().count, 1)
        XCTAssertEqual(terminals.values().count, 1)
        XCTAssertEqual(terminals.values()[0].metadata?["reason"], "expired")
        XCTAssertEqual(terminals.values()[0].metadata?["lifecycle_token"], token)
        XCTAssertTrue(connection.pendingApprovalPromptEvents().isEmpty)
        XCTAssertTrue(outbound.values().isEmpty,
                      "a closed connection must not answer a redelivery")
    }

    func testCloseCannotPublishTerminalInsidePendingPromptCallback() {
        let timeline = LifecycleStringSink()
        let promptEntered = DispatchSemaphore(value: 0)
        let releasePrompt = DispatchSemaphore(value: 0)
        let work = DispatchGroup()
        let connection = CodexAppServerConnection(
            sendLine: { _ in },
            approvalContext: CodexAppServerApprovalContext(
                workspaceID: "workspace-1",
                panelID: "panel-1",
                sessionID: "session-1",
                epoch: "process-epoch"),
            onInteractivePrompt: { _ in
                timeline.append("prompt_enter")
                promptEntered.signal()
                _ = releasePrompt.wait(timeout: .now() + 3)
                timeline.append("prompt_return")
            },
            onInteractivePromptResolved: { _ in
                timeline.append("terminal")
            })

        work.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            connection.receiveLine(Self.commandLine(
                id: #""approval-1""#,
                itemID: "item-1",
                turnID: "turn-1",
                command: "ls"))
            work.leave()
        }
        XCTAssertEqual(promptEntered.wait(timeout: .now() + 2), .success)

        work.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            connection.close()
            work.leave()
        }
        Thread.sleep(forTimeInterval: 0.05)
        XCTAssertEqual(timeline.values(), ["prompt_enter"],
                       "close must wait until pending publication completes")

        releasePrompt.signal()
        XCTAssertEqual(work.wait(timeout: .now() + 3), .success)
        XCTAssertEqual(timeline.values(),
                       ["prompt_enter", "prompt_return", "terminal"])
    }

    func testStaleLifecycleCapabilityFailsWithoutWriting() throws {
        let outbound = LifecycleLineSink()
        let prompts = LifecyclePromptSink()
        let connection = Self.connection(outbound: outbound, prompts: prompts)
        let line = Self.commandLine(id: #""approval-1""#,
                                    itemID: "item-1",
                                    turnID: "turn-1",
                                    command: "ls")
        connection.receiveLine(line)
        let staleToken = try XCTUnwrap(prompts.values().first?.event.eventID)
        connection.receiveLine(line)

        XCTAssertThrowsError(try connection.submitApproval(
            promptID: prompts.values()[1].prompt.promptID,
            targetIndex: 0,
            clientRequestID: "client-stale",
            lifecycleToken: staleToken)) { error in
                guard case BridgeInternalError.conflict = error else {
                    return XCTFail("expected lifecycle conflict, got \(error)")
                }
            }
        XCTAssertTrue(outbound.values().isEmpty)
    }

    func testWriteFailureReturnsLifecycleToPendingForSameDecisionRetry() throws {
        struct WriteFailure: Error {}
        let outbound = LifecycleLineSink()
        let prompts = LifecyclePromptSink()
        let failWrites = LifecycleFlag(true)
        let connection = Self.connection(
            sendLine: { line in
                if failWrites.value() {
                    throw WriteFailure()
                }
                outbound.append(line)
            },
            prompts: prompts)
        connection.receiveLine(Self.commandLine(id: #""approval-1""#,
                                                itemID: "item-1",
                                                turnID: "turn-1",
                                                command: "ls"))
        let prompt = try XCTUnwrap(prompts.values().first)

        XCTAssertThrowsError(try connection.submitApproval(
            promptID: prompt.prompt.promptID,
            targetIndex: 0,
            clientRequestID: "client-1",
            lifecycleToken: prompt.event.eventID))
        XCTAssertEqual(connection.pendingApprovalPromptEvents().first?
            .metadata?["submit_state"], "pending")

        failWrites.set(false)
        guard case .pendingConfirmation = try connection.submitApproval(
            promptID: prompt.prompt.promptID,
            targetIndex: 0,
            clientRequestID: "client-1",
            lifecycleToken: prompt.event.eventID) else {
            return XCTFail("the same decision should be retryable")
        }
        XCTAssertEqual(outbound.values().count, 1)
    }

    func testUserInputLifecycleSubmitUsesStructuredAnswersAndAwaitsTerminal() throws {
        let outbound = LifecycleLineSink()
        let prompts = LifecyclePromptSink()
        let terminals = LifecycleEventSink()
        let connection = Self.connection(outbound: outbound,
                                         prompts: prompts,
                                         terminals: terminals)
        connection.receiveLine(#"{"id":"input-1","method":"item/tool/requestUserInput","params":{"threadId":"thread-1","turnId":"turn-1","itemId":"item-input","questions":[{"id":"format","header":"Output","question":"Which format?","options":[{"label":"PNG","description":"Lossless"},{"label":"JPEG","description":"Compact"}]}]}}"#)
        let prompt = try XCTUnwrap(prompts.values().first)

        guard case .pendingConfirmation = try connection.submitUserInput(
            promptID: prompt.prompt.promptID,
            answers: ["format": ["PNG"]],
            clientRequestID: "client-input",
            lifecycleToken: prompt.event.eventID) else {
            return XCTFail("structured input should await authoritative resolution")
        }
        XCTAssertTrue(terminals.values().isEmpty)
        let response = try Self.object(from: outbound.values()[0])
        XCTAssertEqual(response["result"]?.objectValue?["answers"]?
            .objectValue?["format"]?.objectValue?["answers"]?.arrayValue,
                       [.string("PNG")])
    }

    private static func connection(
        outbound: LifecycleLineSink = LifecycleLineSink(),
        prompts: LifecyclePromptSink = LifecyclePromptSink(),
        terminals: LifecycleEventSink = LifecycleEventSink(),
        nextSequence: @escaping CodexAppServerConnection.SequenceProvider = { _ in 1 }
    ) -> CodexAppServerConnection {
        connection(sendLine: { outbound.append($0) },
                   prompts: prompts,
                   terminals: terminals,
                   nextSequence: nextSequence)
    }

    private static func connection(
        sendLine: @escaping CodexAppServerConnection.SendLine,
        prompts: LifecyclePromptSink,
        terminals: LifecycleEventSink = LifecycleEventSink(),
        nextSequence: @escaping CodexAppServerConnection.SequenceProvider = { _ in 1 }
    ) -> CodexAppServerConnection {
        CodexAppServerConnection(
            sendLine: sendLine,
            approvalContext: CodexAppServerApprovalContext(
                workspaceID: "workspace-1",
                panelID: "panel-1",
                sessionID: "session-1",
                epoch: "process-epoch"),
            nextSequence: nextSequence,
            timestampProvider: { "2026-07-22T00:00:00.000Z" },
            onInteractivePrompt: { prompts.append($0) },
            onInteractivePromptResolved: { terminals.append($0) })
    }

    private static func commandLine(id: String,
                                    itemID: String,
                                    turnID: String,
                                    command: String) -> String {
        """
        {"id":\(id),"method":"item/commandExecution/requestApproval","params":{"threadId":"thread-1","turnId":"\(turnID)","itemId":"\(itemID)","startedAtMs":1786000000000,"command":"\(command)"}}
        """
    }

    private static func object(from line: String) throws -> [String: JSONValue] {
        let data = try XCTUnwrap(line.trimmingCharacters(in: .whitespacesAndNewlines)
            .data(using: .utf8))
        return try XCTUnwrap(JSONDecoder().decode(JSONValue.self, from: data).objectValue)
    }
}

private final class LifecycleLineSink: @unchecked Sendable {
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

private final class LifecyclePromptSink: @unchecked Sendable {
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

private final class LifecycleEventSink: @unchecked Sendable {
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

private final class LifecycleCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

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

private final class LifecycleFlag: @unchecked Sendable {
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

private final class LifecycleStringSink: @unchecked Sendable {
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
