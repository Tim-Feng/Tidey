import Foundation
import XCTest
@testable import RemoteBridge

final class CodexAppServerApprovalPromptStoreLifecycleTests: XCTestCase {
    func testRegisterAndIdenticalRedeliveryAdvanceAttemptAndReplaceSnapshot() throws {
        let store = CodexAppServerApprovalPromptStore()
        let first = try Self.entry(command: "ls")
        let redelivered = try Self.entry(command: "ls")

        guard case .recorded(let recorded, let firstAttempt) =
                store.register(entry: first, makeTerminalEvent: Self.terminalEvent) else {
            return XCTFail("expected a fresh registration")
        }
        XCTAssertEqual(recorded.request.command, "ls")
        XCTAssertEqual(firstAttempt, 1)

        let firstEvent = Self.promptEvent(promptID: first.prompt.promptID,
                                          token: "delivery-1")
        store.recordPublishedPromptEvent(promptID: first.prompt.promptID,
                                         event: firstEvent)
        XCTAssertEqual(store.pendingStates().first?.publishedEvent?.eventID,
                       firstEvent.eventID)

        guard case .reactivated(let replacement, let secondAttempt) =
                store.register(entry: redelivered, makeTerminalEvent: Self.terminalEvent) else {
            return XCTFail("expected identical redelivery to reactivate")
        }
        XCTAssertEqual(replacement.request.command, "ls")
        XCTAssertEqual(secondAttempt, 2)
        XCTAssertNil(store.pendingStates().first?.publishedEvent,
                     "a true redelivery must await a new published capability")
    }

    func testChangedPayloadSupersedesOldLifecycleAtomically() throws {
        let store = CodexAppServerApprovalPromptStore()
        let original = try Self.entry(command: "ls")
        let changed = try Self.entry(command: "rm -rf /tmp/example")
        _ = store.register(entry: original, makeTerminalEvent: Self.terminalEvent)

        guard case .begin = store.beginSubmit(promptID: original.prompt.promptID,
                                              targetIndex: 0,
                                              clientRequestID: "client-old") else {
            return XCTFail("expected submit to begin")
        }

        guard case .supersededPayloadChanged(let terminal, let replacement, let attempt) =
                store.register(entry: changed, makeTerminalEvent: Self.terminalEvent) else {
            return XCTFail("expected changed payload to start a fresh lifecycle")
        }
        XCTAssertEqual(terminal.reason, "superseded")
        XCTAssertEqual(terminal.entry.request.command, "ls")
        XCTAssertEqual(replacement.request.command, "rm -rf /tmp/example")
        XCTAssertEqual(attempt, 2)
        XCTAssertEqual(store.entry(promptID: original.prompt.promptID)?.request.command,
                       "rm -rf /tmp/example")

        guard case .begin(let current, _, let lifecycleAttempt) =
                store.beginSubmit(promptID: changed.prompt.promptID,
                                  targetIndex: 1,
                                  clientRequestID: "client-new") else {
            return XCTFail("the replacement lifecycle must accept a fresh decision")
        }
        XCTAssertEqual(current.request.command, "rm -rf /tmp/example")
        XCTAssertEqual(lifecycleAttempt, 2)
    }

    func testLifecycleTokenMustMatchPublishedSnapshotAndRotateOnRedelivery() throws {
        let store = CodexAppServerApprovalPromptStore()
        let entry = try Self.entry(command: "ls")
        _ = store.register(entry: entry, makeTerminalEvent: Self.terminalEvent)
        let firstEvent = Self.promptEvent(promptID: entry.prompt.promptID,
                                          token: "delivery-1")
        store.recordPublishedPromptEvent(promptID: entry.prompt.promptID,
                                         event: firstEvent)

        XCTAssertEqual(store.pendingStates().first?.publishedEvent?.eventID,
                       "delivery-1")
        guard case .lifecycleTokenMismatch =
                store.beginSubmit(promptID: entry.prompt.promptID,
                                  targetIndex: 0,
                                  clientRequestID: "client-wrong",
                                  lifecycleToken: "delivery-stale") else {
            return XCTFail("a stale capability must not decide the lifecycle")
        }
        guard case .begin = store.beginSubmit(promptID: entry.prompt.promptID,
                                              targetIndex: 0,
                                              clientRequestID: "client-1",
                                              lifecycleToken: "delivery-1") else {
            return XCTFail("the published capability should be accepted")
        }
        _ = store.failSubmit(promptID: entry.prompt.promptID, lifecycleAttempt: 1)

        _ = store.register(entry: entry, makeTerminalEvent: Self.terminalEvent)
        guard case .lifecycleTokenMismatch =
                store.beginSubmit(promptID: entry.prompt.promptID,
                                  targetIndex: 0,
                                  clientRequestID: "client-old",
                                  lifecycleToken: "delivery-1") else {
            return XCTFail("redelivery must invalidate the earlier capability")
        }
        let secondEvent = Self.promptEvent(promptID: entry.prompt.promptID,
                                           token: "delivery-2")
        store.recordPublishedPromptEvent(promptID: entry.prompt.promptID,
                                         event: secondEvent)
        guard case .begin(_, _, let attempt) =
                store.beginSubmit(promptID: entry.prompt.promptID,
                                  targetIndex: 0,
                                  clientRequestID: "client-2",
                                  lifecycleToken: "delivery-2") else {
            return XCTFail("the replacement capability should be accepted")
        }
        XCTAssertEqual(attempt, 2)
    }

    func testSubmitFlushStaysPendingUntilExternalResolutionWins() throws {
        let store = CodexAppServerApprovalPromptStore()
        let entry = try Self.entry(command: "ls")
        _ = store.register(entry: entry, makeTerminalEvent: Self.terminalEvent)

        guard case .begin = store.beginSubmit(promptID: entry.prompt.promptID,
                                              targetIndex: 0,
                                              clientRequestID: "client-1") else {
            return XCTFail("expected submit to begin")
        }
        guard case .awaitingConfirmation =
                store.completeSubmitFlush(promptID: entry.prompt.promptID,
                                          lifecycleAttempt: 1) else {
            return XCTFail("a transport flush must not terminate the prompt")
        }
        XCTAssertEqual(store.pendingStates().count, 1)

        let records = store.resolveExternally(reason: "server_resolved",
                                              where: { $0.itemID == "item-1" },
                                              makeEvent: Self.terminalEvent)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].reason, "server_resolved")
        XCTAssertTrue(store.pendingStates().isEmpty)

        guard case .terminal(let terminal) =
                store.completeSubmitFlush(promptID: entry.prompt.promptID,
                                          lifecycleAttempt: 1) else {
            return XCTFail("a late local completion must observe the terminal")
        }
        XCTAssertEqual(terminal.event.eventID, records[0].event.eventID)
    }

    func testUserInputAnswersShareLifecycleTokenAndConflictSemantics() throws {
        let store = CodexAppServerApprovalPromptStore()
        let request = try Self.userInputRequest()
        let entry = CodexAppServerApprovalPromptEntry(
            request: request,
            prompt: request.makePrompt(epoch: "process-epoch"))
        _ = store.register(entry: entry, makeTerminalEvent: Self.terminalEvent)
        store.recordPublishedPromptEvent(
            promptID: entry.prompt.promptID,
            event: Self.promptEvent(promptID: entry.prompt.promptID,
                                    token: "delivery-input"))

        guard case .begin(_, let response, let attempt) =
                store.beginSubmitUserInput(promptID: entry.prompt.promptID,
                                           answers: ["format": ["PNG"]],
                                           clientRequestID: "client-1",
                                           lifecycleToken: "delivery-input") else {
            return XCTFail("expected structured answers to begin")
        }
        XCTAssertEqual(attempt, 1)
        XCTAssertEqual(response.objectValue?["answers"]?.objectValue?["format"]?
            .objectValue?["answers"]?.arrayValue, [.string("PNG")])

        _ = store.failSubmit(promptID: entry.prompt.promptID,
                             lifecycleAttempt: 1)
        guard case .optionConflict =
                store.beginSubmitUserInput(promptID: entry.prompt.promptID,
                                           answers: ["format": ["JPEG"]],
                                           clientRequestID: "client-2",
                                           lifecycleToken: "delivery-input") else {
            return XCTFail("an ambiguous earlier answer must fail closed")
        }
    }

    func testExternalResolutionAndRedeliveryKeepAttemptsMonotonic() throws {
        let store = CodexAppServerApprovalPromptStore()
        let entry = try Self.entry(command: "ls")
        guard case .recorded(_, let firstAttempt) =
                store.register(entry: entry, makeTerminalEvent: Self.terminalEvent) else {
            return XCTFail("expected first registration")
        }
        XCTAssertEqual(firstAttempt, 1)

        let records = store.resolveExternally(reason: "server_resolved",
                                              where: { _ in true },
                                              makeEvent: Self.terminalEvent)
        XCTAssertEqual(records.first?.attempt, 1)
        XCTAssertNotNil(store.terminalRecord(promptID: entry.prompt.promptID))

        guard case .recorded(_, let secondAttempt) =
                store.register(entry: entry, makeTerminalEvent: Self.terminalEvent) else {
            return XCTFail("redelivery after a terminal should start fresh")
        }
        XCTAssertEqual(secondAttempt, 2)
        XCTAssertNil(store.terminalRecord(promptID: entry.prompt.promptID))
    }

    func testTerminalRecordsAreBounded() throws {
        let store = CodexAppServerApprovalPromptStore(terminalCapacity: 2)
        var promptIDs: [String] = []
        for index in 0..<3 {
            let entry = try Self.entry(requestID: .string("req-\(index)"),
                                       itemID: "item-\(index)",
                                       command: "ls")
            promptIDs.append(entry.prompt.promptID)
            _ = store.register(entry: entry, makeTerminalEvent: Self.terminalEvent)
            _ = store.resolveExternally(reason: "server_resolved",
                                        where: { $0.itemID == "item-\(index)" },
                                        makeEvent: Self.terminalEvent)
        }

        XCTAssertEqual(store.terminalRecordCount(), 2)
        XCTAssertNil(store.terminalRecord(promptID: promptIDs[0]))
        XCTAssertNotNil(store.terminalRecord(promptID: promptIDs[1]))
        XCTAssertNotNil(store.terminalRecord(promptID: promptIDs[2]))
    }

    func testRetireResolvesExistingEntriesAndRejectsFutureRegistration() throws {
        let store = CodexAppServerApprovalPromptStore()
        let first = try Self.entry(requestID: .string("req-1"),
                                   itemID: "item-1",
                                   command: "ls")
        let afterRetire = try Self.entry(requestID: .string("req-2"),
                                         itemID: "item-2",
                                         command: "pwd")
        _ = store.register(entry: first, makeTerminalEvent: Self.terminalEvent)

        let terminals = store.retireAndResolveAll(reason: "expired",
                                                  makeEvent: Self.terminalEvent)
        XCTAssertEqual(terminals.count, 1)
        XCTAssertEqual(terminals[0].reason, "expired")
        XCTAssertTrue(store.isRetired())
        XCTAssertTrue(store.pendingStates().isEmpty)

        guard case .rejectedRetired =
                store.register(entry: afterRetire,
                               makeTerminalEvent: Self.terminalEvent) else {
            return XCTFail("a retired store must close admission")
        }
        XCTAssertTrue(store.pendingStates().isEmpty)
    }

    func testRetireAndConcurrentRegistrationCannotLeaveAnActiveEntry() throws {
        let store = CodexAppServerApprovalPromptStore()
        let group = DispatchGroup()

        for index in 0..<48 {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                defer { group.leave() }
                if index == 24 {
                    _ = store.retireAndResolveAll(reason: "expired",
                                                  makeEvent: Self.terminalEvent)
                    return
                }
                guard let request = try? Self.request(
                    requestID: .string("req-\(index)"),
                    itemID: "item-\(index)",
                    command: "ls") else {
                    return
                }
                let entry = CodexAppServerApprovalPromptEntry(
                    request: request,
                    prompt: request.makePrompt(epoch: "process-epoch"))
                _ = store.register(entry: entry,
                                   makeTerminalEvent: Self.terminalEvent)
            }
        }

        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)
        XCTAssertTrue(store.isRetired())
        XCTAssertTrue(store.pendingStates().isEmpty,
                      "registration and retirement must share one admission gate")
    }

    func testCompatibilityRecordKeepsCallerSuppliedPromptIdentity() throws {
        let store = CodexAppServerApprovalPromptStore()
        let request = try Self.request(command: "ls")
        let prompt = request.makePrompt(epoch: "process-epoch")

        XCTAssertEqual(store.record(request, prompt: prompt).promptID,
                       prompt.promptID)
        XCTAssertEqual(store.entry(promptID: prompt.promptID)?.prompt.promptID,
                       prompt.promptID)
        let resolved = try store.resolveEntry(promptID: prompt.promptID,
                                              targetIndex: 0)
        XCTAssertEqual(resolved.entry.prompt.promptID, prompt.promptID)
        XCTAssertNil(store.entry(promptID: prompt.promptID))
    }

    private static func request(requestID: CodexAppServerRequestID = .string("req-1"),
                                itemID: String = "item-1",
                                command: String) throws -> CodexAppServerApprovalRequest {
        try XCTUnwrap(CodexAppServerApprovalRequest(
            method: "item/commandExecution/requestApproval",
            typedRequestID: requestID,
            params: [
                "threadId": .string("thread-1"),
                "turnId": .string("turn-1"),
                "itemId": .string(itemID),
                "startedAtMs": .number(1_786_000_000_000),
                "command": .string(command),
            ]))
    }

    private static func entry(requestID: CodexAppServerRequestID = .string("req-1"),
                              itemID: String = "item-1",
                              command: String) throws -> CodexAppServerApprovalPromptEntry {
        let request = try self.request(requestID: requestID,
                                       itemID: itemID,
                                       command: command)
        return CodexAppServerApprovalPromptEntry(
            request: request,
            prompt: request.makePrompt(epoch: "process-epoch"))
    }

    private static func userInputRequest() throws -> CodexAppServerApprovalRequest {
        try XCTUnwrap(CodexAppServerApprovalRequest(
            method: "item/tool/requestUserInput",
            typedRequestID: .string("input-1"),
            params: [
                "threadId": .string("thread-1"),
                "turnId": .string("turn-1"),
                "itemId": .string("item-input"),
                "questions": .array([
                    .object([
                        "id": .string("format"),
                        "header": .string("Output"),
                        "question": .string("Which format?"),
                        "options": .array([
                            .object([
                                "label": .string("PNG"),
                                "description": .string("Lossless"),
                            ]),
                            .object([
                                "label": .string("JPEG"),
                                "description": .string("Compact"),
                            ]),
                        ]),
                    ]),
                ]),
            ]))
    }

    private static func promptEvent(promptID: String, token: String) -> AgentEvent {
        AgentEvent(eventID: token,
                   seq: 1,
                   vendor: "codex",
                   workspaceID: "workspace-1",
                   sessionID: "session-1",
                   timestamp: "2026-07-22T00:00:00.000Z",
                   type: .interactivePrompt,
                   role: nil,
                   text: nil,
                   name: nil,
                   input: nil,
                   output: nil,
                   toolCallID: nil,
                   metadata: ["prompt_id": promptID])
    }

    private static func terminalEvent(_ entry: CodexAppServerApprovalPromptEntry,
                                      _ reason: String,
                                      _ attempt: Int) -> AgentEvent {
        AgentEvent(eventID: "terminal:\(entry.prompt.promptID):\(reason):\(attempt)",
                   seq: attempt,
                   vendor: "codex",
                   workspaceID: "workspace-1",
                   sessionID: "session-1",
                   timestamp: "2026-07-22T00:00:00.000Z",
                   type: .interactivePromptResolved,
                   role: nil,
                   text: nil,
                   name: nil,
                   input: nil,
                   output: nil,
                   toolCallID: nil,
                   metadata: ["prompt_id": entry.prompt.promptID,
                              "reason": reason,
                              "attempt": String(attempt)])
    }
}
