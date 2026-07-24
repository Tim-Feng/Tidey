import XCTest
@testable import RemoteBridge

final class CodexAppServerConnectionTests: XCTestCase {
    func testSendsClientRequestAndResolvesResponse() throws {
        let outbound = LineSink()
        var response: JSONValue?
        let connection = CodexAppServerConnection(sendLine: { outbound.append($0) })

        let id = try connection.sendClientRequest(method: "initialize",
                                                  params: ["client": .string("tidey")]) { result in
            if case .success(let value) = result {
                response = value
            }
        }

        XCTAssertEqual(id, 1)
        let request = try Self.object(from: outbound.lines()[0])
        XCTAssertEqual(request["id"]?.intValue, 1)
        XCTAssertEqual(request["method"]?.stringValue, "initialize")
        XCTAssertEqual(request["params"]?.objectValue?["client"]?.stringValue, "tidey")

        connection.receiveLine(#"{"id":1,"result":{"ok":true}}"#)
        XCTAssertEqual(response?.objectValue?["ok"]?.boolValue, true)
    }

    func testReceivesServerNotification() {
        var received: CodexAppServerNotification?
        let connection = CodexAppServerConnection(sendLine: { _ in },
                                                  onNotification: { received = $0 })

        connection.receiveLine(#"{"method":"thread/status/changed","params":{"threadId":"thread-1"}}"#)

        XCTAssertEqual(received?.method, "thread/status/changed")
        XCTAssertEqual(received?.params["threadId"]?.stringValue, "thread-1")
    }

    func testUnsupportedServerRequestSendsJsonRPCError() throws {
        let outbound = LineSink()
        let connection = CodexAppServerConnection(sendLine: { outbound.append($0) })

        // A method 0.144.1 does not define is the only -32601 case;
        // item/tool/requestUserInput is a supported contract method now.
        connection.receiveLine(#"{"id":"server-1","method":"item/tool/somethingUnknown","params":{}}"#)

        let response = try Self.object(from: outbound.lines()[0])
        XCTAssertEqual(response["id"]?.stringValue, "server-1")
        let error = response["error"]?.objectValue
        XCTAssertEqual(error?["code"]?.intValue, -32601)
        XCTAssertEqual(error?["message"]?.stringValue, "Unsupported server request: item/tool/somethingUnknown")
    }

    func testMalformedRequestUserInputSendsInvalidParamsNotUnknownMethod() throws {
        let outbound = LineSink()
        let connection = CodexAppServerConnection(sendLine: { outbound.append($0) })

        // Supported method missing required `questions` -> -32602, not -32601.
        connection.receiveLine(#"{"id":"server-1","method":"item/tool/requestUserInput","params":{"threadId":"thread-1","turnId":"turn-1","itemId":"item-1"}}"#)

        let response = try Self.object(from: outbound.lines()[0])
        XCTAssertEqual(response["id"]?.stringValue, "server-1")
        let error = response["error"]?.objectValue
        XCTAssertEqual(error?["code"]?.intValue, -32602)
        XCTAssertEqual(error?["message"]?.stringValue, "Invalid Codex approval request: item/tool/requestUserInput")
    }

    func testCommandApprovalSubmitFlushIsPendingConfirmationNotResolution() throws {
        let outbound = LineSink()
        var promptEnvelope: CodexAppServerInteractivePromptEnvelope?
        var resolvedEvents = [AgentEvent]()
        var nextSeq = 41
        let connection = CodexAppServerConnection(
            sendLine: { outbound.append($0) },
            approvalContext: CodexAppServerApprovalContext(workspaceID: "workspace-1",
                                                           panelID: "panel-1",
                                                           sessionID: "session-1",
                                                           epoch: "pid:100|sock:/tmp/a.sock"),
            nextSequence: { _ in
                nextSeq += 1
                return nextSeq
            },
            timestampProvider: { "2026-06-05T12:00:00.000Z" },
            onInteractivePrompt: { promptEnvelope = $0 },
            onInteractivePromptResolved: { resolvedEvents.append($0) })

        connection.receiveLine("""
        {"id":"approval-1","method":"item/commandExecution/requestApproval","params":{"threadId":"thread-1","turnId":"turn-1","itemId":"item-1","startedAtMs":1786000000000,"reason":"Needs network.","command":"python3 -c 'print(1)'","cwd":"/Users/timfeng/GitHub/Tidey","proposedExecpolicyAmendment":["python3","-c"]}}
        """)

        let envelope = try XCTUnwrap(promptEnvelope)
        XCTAssertEqual(envelope.prompt.vendor, "codex")
        XCTAssertEqual(envelope.prompt.source, "codex_command_approval")
        XCTAssertEqual(envelope.event.type, .interactivePrompt)
        XCTAssertEqual(envelope.event.metadata?["panel_id"], "panel-1")
        XCTAssertEqual(envelope.event.metadata?["prompt_id"], envelope.prompt.promptID)
        XCTAssertEqual(envelope.event.metadata?["app_server_epoch"], "pid:100|sock:/tmp/a.sock")

        let outcome = try connection.submitApproval(promptID: envelope.prompt.promptID,
                                                    targetIndex: 1,
                                                    clientRequestID: "client-1")
        guard case .pendingConfirmation = outcome else {
            return XCTFail("flush success must not be treated as resolution")
        }

        // Acceptance case 1: response flushed, serverRequest/resolved not yet
        // received -> prompt stays pending, no resolved event exists.
        XCTAssertTrue(resolvedEvents.isEmpty)
        let pending = connection.pendingApprovalPromptEvents()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.metadata?["submit_state"], "submitting")
        XCTAssertEqual(pending.first?.metadata?["client_request_id"], "client-1")

        let response = try Self.object(from: outbound.lines()[0])
        XCTAssertEqual(response["id"]?.stringValue, "approval-1")
        XCTAssertEqual(response["result"]?.objectValue?["decision"]?.stringValue, "decline")

        // Acceptance case 2: the authoritative notification produces the one
        // and only terminal event.
        connection.receiveLine(#"{"method":"serverRequest/resolved","params":{"threadId":"thread-1","requestId":"approval-1"}}"#)
        XCTAssertEqual(resolvedEvents.map { $0.metadata?["reason"] }, ["server_resolved"])
        XCTAssertTrue(connection.pendingApprovalPromptEvents().isEmpty)

        // A late duplicate submit answers idempotently from the exact
        // terminal record without another wire write.
        let lateOutcome = try connection.submitApproval(promptID: envelope.prompt.promptID,
                                                        targetIndex: 1,
                                                        clientRequestID: "client-1")
        guard case .alreadyResolved(let terminalEvent) = lateOutcome else {
            return XCTFail("expected alreadyResolved")
        }
        XCTAssertEqual(terminalEvent.eventID, resolvedEvents[0].eventID)
        XCTAssertEqual(resolvedEvents.count, 1)
        XCTAssertEqual(outbound.lines().count, 1)
    }

    func testRedeliveredRequestReactivatesPromptInsteadOfAutoReplying() throws {
        let outbound = LineSink()
        var promptEnvelopes = [CodexAppServerInteractivePromptEnvelope]()
        var resolvedEvents = [AgentEvent]()
        let connection = Self.makeApprovalConnection(
            sendLine: { outbound.append($0) },
            onInteractivePrompt: { promptEnvelopes.append($0) },
            onInteractivePromptResolved: { resolvedEvents.append($0) })

        connection.receiveLine(Self.commandApprovalLine)
        let promptID = try XCTUnwrap(promptEnvelopes.first?.prompt.promptID)

        guard case .pendingConfirmation = try connection.submitApproval(promptID: promptID,
                                                                        targetIndex: 0,
                                                                        clientRequestID: "client-1") else {
            return XCTFail("expected pendingConfirmation")
        }
        XCTAssertEqual(outbound.lines().count, 1)

        // The server re-asks (e.g. after its own reconnect): the flushed
        // response evidently was not accepted, so the card must become
        // actionable again instead of a stored local choice auto-winning.
        connection.receiveLine(Self.commandApprovalLine)
        XCTAssertEqual(promptEnvelopes.count, 2)
        XCTAssertEqual(promptEnvelopes.last?.prompt.promptID, promptID)
        XCTAssertEqual(outbound.lines().count, 1)
        XCTAssertTrue(resolvedEvents.isEmpty)
        XCTAssertEqual(connection.pendingApprovalPromptEvents().first?.metadata?["submit_state"], "pending")

        // Retry with the same client request identity re-sends the response.
        guard case .pendingConfirmation = try connection.submitApproval(promptID: promptID,
                                                                        targetIndex: 0,
                                                                        clientRequestID: "client-1") else {
            return XCTFail("expected pendingConfirmation on retry")
        }
        XCTAssertEqual(outbound.lines().count, 2)
    }

    func testFileChangeApprovalSubmitSendsDecisionReply() throws {
        let outbound = LineSink()
        var promptEnvelope: CodexAppServerInteractivePromptEnvelope?
        let connection = Self.makeApprovalConnection(
            sendLine: { outbound.append($0) },
            onInteractivePrompt: { promptEnvelope = $0 })

        connection.receiveLine("""
        {"id":7,"method":"item/fileChange/requestApproval","params":{"threadId":"thread-1","turnId":"turn-1","itemId":"item-2","startedAtMs":1786000000000,"reason":"Needs write access.","grantRoot":"/Users/timfeng/GitHub/Tidey"}}
        """)

        let envelope = try XCTUnwrap(promptEnvelope)
        XCTAssertEqual(envelope.prompt.source, "codex_file_change_approval")
        XCTAssertEqual(envelope.prompt.options.map(\.inputSequence), ["accept", "acceptForSession", "decline"])

        guard case .pendingConfirmation = try connection.submitApproval(promptID: envelope.prompt.promptID,
                                                                        targetIndex: 2,
                                                                        clientRequestID: nil) else {
            return XCTFail("expected pendingConfirmation")
        }
        let response = try Self.object(from: outbound.lines()[0])
        XCTAssertEqual(response["id"]?.intValue, 7)
        XCTAssertEqual(response["result"]?.objectValue?["decision"]?.stringValue, "decline")
    }

    func testInt64AndStringRequestIDsRoundTripExactly() throws {
        let outbound = LineSink()
        var promptEnvelopes = [CodexAppServerInteractivePromptEnvelope]()
        let connection = Self.makeApprovalConnection(
            sendLine: { outbound.append($0) },
            epoch: "epoch-exact-request-id",
            onInteractivePrompt: { promptEnvelopes.append($0) })

        // Two requests identical except for the id type: "1" vs 1. They must
        // map to distinct prompts and echo their ids exactly.
        connection.receiveLine("""
        {"id":"1","method":"item/commandExecution/requestApproval","params":{"threadId":"thread-1","turnId":"turn-1","itemId":"item-1","startedAtMs":1786000000000,"command":"ls"}}
        """)
        connection.receiveLine("""
        {"id":1,"method":"item/commandExecution/requestApproval","params":{"threadId":"thread-1","turnId":"turn-1","itemId":"item-1","startedAtMs":1786000000000,"command":"ls"}}
        """)
        connection.receiveLine("""
        {"id":9223372036854775807,"method":"item/commandExecution/requestApproval","params":{"threadId":"thread-1","turnId":"turn-1","itemId":"item-9","startedAtMs":1786000000000,"command":"ls"}}
        """)

        XCTAssertEqual(promptEnvelopes.count, 3)
        let promptIDs = promptEnvelopes.map(\.prompt.promptID)
        XCTAssertEqual(Set(promptIDs).count, 3, "string and integer ids must not collide")

        guard case .pendingConfirmation = try connection.submitApproval(promptID: promptIDs[0],
                                                                        targetIndex: 0,
                                                                        clientRequestID: nil) else {
            return XCTFail("expected pendingConfirmation")
        }
        guard case .pendingConfirmation = try connection.submitApproval(promptID: promptIDs[1],
                                                                        targetIndex: 0,
                                                                        clientRequestID: nil) else {
            return XCTFail("expected pendingConfirmation")
        }
        guard case .pendingConfirmation = try connection.submitApproval(promptID: promptIDs[2],
                                                                        targetIndex: 0,
                                                                        clientRequestID: nil) else {
            return XCTFail("expected pendingConfirmation")
        }

        let lines = outbound.lines()
        XCTAssertTrue(lines[0].hasPrefix("{\"id\":\"1\","), lines[0])
        XCTAssertTrue(lines[1].hasPrefix("{\"id\":1,"), lines[1])
        XCTAssertTrue(lines[2].hasPrefix("{\"id\":9223372036854775807,"), lines[2])
    }

    func testExternalResolvedDuringBlockedConfirmedSendYieldsSingleTerminal() throws {
        // Acceptance case 3: the authoritative resolution arrives while the
        // local response write is still blocked in the transport. Exactly one
        // terminal event may exist, the local choice must not be recorded as
        // the winner, and a re-delivered request must not auto-receive the
        // local response.
        let sendEntered = expectation(description: "confirmed send entered")
        let releaseSend = DispatchSemaphore(value: 0)
        let outbound = LineSink()
        var promptEnvelopes = [CodexAppServerInteractivePromptEnvelope]()
        let resolvedEvents = LockedEvents()
        let connection = Self.makeApprovalConnection(
            sendLine: { outbound.append($0) },
            sendLineConfirmed: { line in
                sendEntered.fulfill()
                _ = releaseSend.wait(timeout: .now() + 2.0)
                outbound.append(line)
            },
            onInteractivePrompt: { promptEnvelopes.append($0) },
            onInteractivePromptResolved: { resolvedEvents.append($0) })

        connection.receiveLine(Self.commandApprovalLine)
        let promptID = try XCTUnwrap(promptEnvelopes.first?.prompt.promptID)

        var submitOutcome: CodexAppServerApprovalSubmitOutcome?
        let submitReturned = expectation(description: "submit returned")
        DispatchQueue.global(qos: .userInitiated).async {
            submitOutcome = try? connection.submitApproval(promptID: promptID,
                                                           targetIndex: 0,
                                                           clientRequestID: "client-1")
            submitReturned.fulfill()
        }
        wait(for: [sendEntered], timeout: 1.0)

        // External resolution wins while the write is still blocked.
        connection.receiveLine(#"{"method":"serverRequest/resolved","params":{"threadId":"thread-1","requestId":"approval-1"}}"#)
        releaseSend.signal()
        wait(for: [submitReturned], timeout: 2.0)

        // The submit reports the authoritative terminal record, not a local win.
        guard case .alreadyResolved(let event)? = submitOutcome else {
            return XCTFail("expected alreadyResolved, got \(String(describing: submitOutcome))")
        }
        XCTAssertEqual(event.metadata?["reason"], "server_resolved")
        let reasons = resolvedEvents.snapshot().map { $0.metadata?["reason"] }
        XCTAssertEqual(reasons, ["server_resolved"], "exactly one terminal event")

        // A re-delivered request becomes a fresh prompt; the blocked local
        // response is not replayed automatically.
        let sentBefore = outbound.lines().count
        connection.receiveLine(Self.commandApprovalLine)
        XCTAssertEqual(promptEnvelopes.count, 2)
        XCTAssertEqual(outbound.lines().count, sentBefore)
    }

    func testInvalidApprovalRequestSendsInvalidParamsError() throws {
        let outbound = LineSink()
        let connection = CodexAppServerConnection(
            sendLine: { outbound.append($0) },
            approvalContext: CodexAppServerApprovalContext(workspaceID: "workspace-1",
                                                           panelID: "panel-1",
                                                           sessionID: "session-1"))

        connection.receiveLine(#"{"id":"approval-1","method":"item/fileChange/requestApproval","params":{"turnId":"turn-1"}}"#)

        let response = try Self.object(from: outbound.lines()[0])
        XCTAssertEqual(response["id"]?.stringValue, "approval-1")
        let error = response["error"]?.objectValue
        XCTAssertEqual(error?["code"]?.intValue, -32602)
        XCTAssertEqual(error?["message"]?.stringValue, "Invalid Codex approval request: item/fileChange/requestApproval")
    }

    func testApprovalRequestWithoutContextSendsContextUnavailableError() throws {
        let outbound = LineSink()
        let connection = CodexAppServerConnection(sendLine: { outbound.append($0) })

        connection.receiveLine("""
        {"id":"approval-1","method":"item/fileChange/requestApproval","params":{"threadId":"thread-1","turnId":"turn-1","itemId":"item-1","startedAtMs":1786000000000}}
        """)

        let response = try Self.object(from: outbound.lines()[0])
        XCTAssertEqual(response["id"]?.stringValue, "approval-1")
        let error = response["error"]?.objectValue
        XCTAssertEqual(error?["code"]?.intValue, -32000)
        XCTAssertEqual(error?["message"]?.stringValue, "Codex approval context is unavailable.")
    }

    func testIgnoresNonJSONStdoutLineBeforeClientResponse() throws {
        var response: JSONValue?
        let connection = CodexAppServerConnection(sendLine: { _ in })
        try connection.sendClientRequest(method: "initialize") { result in
            if case .success(let value) = result {
                response = value
            }
        }

        connection.receiveLine("2026-06-06T09:07:44.558405Z ERROR codex_api::endpoint::responses_websocket: failed to connect")
        connection.receiveLine(#"{"id":1,"result":{"ok":true}}"#)

        XCTAssertEqual(response?.objectValue?["ok"]?.boolValue, true)
    }

    func testConcurrentClientRequestsResolveAllHandlers() throws {
        let outbound = LineSink()
        let responseIDs = LockedStringSet()
        let connection = CodexAppServerConnection(sendLine: { outbound.append($0) })
        let requestCount = 50
        let group = DispatchGroup()

        for _ in 0..<requestCount {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                defer { group.leave() }
                do {
                    try connection.sendClientRequest(method: "thread/loaded/list") { result in
                        if case .success(let value) = result,
                           let id = value.objectValue?["request_id"]?.stringValue {
                            responseIDs.insert(id)
                        }
                    }
                } catch {
                    XCTFail("sendClientRequest failed: \(error)")
                }
            }
        }

        XCTAssertEqual(group.wait(timeout: .now() + 2.0), .success)
        let requests = try outbound.lines().map { try Self.object(from: $0) }
        let ids = requests.compactMap { $0["id"]?.intValue }.sorted()
        XCTAssertEqual(ids, Array(1...requestCount))

        DispatchQueue.concurrentPerform(iterations: requestCount) { offset in
            let id = ids[offset]
            connection.receiveLine(#"{"id":\#(id),"result":{"request_id":"\#(id)"}}"#)
        }

        XCTAssertTrue(responseIDs.waitForCount(requestCount))
        XCTAssertEqual(responseIDs.values(), Set((1...requestCount).map(String.init)))
    }

    func testClientResponseDoesNotWaitForConcurrentBlockingSend() throws {
        let sendEntered = expectation(description: "sendLine entered")
        let responseHandled = expectation(description: "client response handler called")
        let receiveReturned = expectation(description: "receiveLine returned while sendLine is still blocked")
        let requestReturned = expectation(description: "sendClientRequest returned after blocked send releases")
        let releaseSend = DispatchSemaphore(value: 0)

        let connection = CodexAppServerConnection(sendLine: { _ in
            sendEntered.fulfill()
            _ = releaseSend.wait(timeout: .now() + 2.0)
        })

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try connection.sendClientRequest(method: "thread/loaded/list") { result in
                    if case .success(let value) = result,
                       value.objectValue?["ok"]?.boolValue == true {
                        responseHandled.fulfill()
                    }
                }
            } catch {
                XCTFail("sendClientRequest failed: \(error)")
            }
            requestReturned.fulfill()
        }

        wait(for: [sendEntered], timeout: 1.0)

        DispatchQueue.global(qos: .userInitiated).async {
            connection.receiveLine(#"{"id":1,"result":{"ok":true}}"#)
            receiveReturned.fulfill()
        }

        wait(for: [receiveReturned, responseHandled], timeout: 0.5)
        releaseSend.signal()
        wait(for: [requestReturned], timeout: 1.0)
    }

    private static let commandApprovalLine = """
    {"id":"approval-1","method":"item/commandExecution/requestApproval","params":{"threadId":"thread-1","turnId":"turn-1","itemId":"item-1","startedAtMs":1786000000000,"reason":"Needs network.","command":"python3 -c 'print(1)'","cwd":"/Users/timfeng/GitHub/Tidey"}}
    """

    private static func makeApprovalConnection(sendLine: @escaping CodexAppServerConnection.SendLine,
                                               sendLineConfirmed: CodexAppServerConnection.SendLine? = nil,
                                               epoch: String = "",
                                               onInteractivePrompt: @escaping CodexAppServerConnection.InteractivePromptHandler = { _ in },
                                               onInteractivePromptResolved: @escaping CodexAppServerConnection.InteractivePromptResolvedHandler = { _ in }) -> CodexAppServerConnection {
        CodexAppServerConnection(
            sendLine: sendLine,
            sendLineConfirmed: sendLineConfirmed,
            approvalContext: CodexAppServerApprovalContext(workspaceID: "workspace-1",
                                                           panelID: "panel-1",
                                                           sessionID: "session-1",
                                                           epoch: epoch),
            timestampProvider: { "2026-07-15T12:00:00.000Z" },
            onInteractivePrompt: onInteractivePrompt,
            onInteractivePromptResolved: onInteractivePromptResolved)
    }

    func testSubmitApprovalKeepsPromptPendingWhenTransportWriteFails() throws {
        struct WriteFailure: Error {}
        let failWrites = LockedFlag()
        var promptEnvelope: CodexAppServerInteractivePromptEnvelope?
        var resolvedEvents = [AgentEvent]()
        let connection = Self.makeApprovalConnection(
            sendLine: { _ in
                if failWrites.value {
                    throw WriteFailure()
                }
            },
            onInteractivePrompt: { promptEnvelope = $0 },
            onInteractivePromptResolved: { resolvedEvents.append($0) })

        connection.receiveLine(Self.commandApprovalLine)
        let envelope = try XCTUnwrap(promptEnvelope)
        failWrites.set(true)

        // Acceptance case 4: send failure keeps the prompt pending; the
        // client sees an error instead of a fake success.
        XCTAssertThrowsError(try connection.submitApproval(promptID: envelope.prompt.promptID,
                                                           targetIndex: 0,
                                                           clientRequestID: "client-1")) { error in
            XCTAssertTrue(error is WriteFailure)
        }

        XCTAssertTrue(resolvedEvents.isEmpty)
        XCTAssertEqual(connection.pendingApprovalPromptEvents().count, 1)

        // Retry with the same client request identity re-sends once and
        // lands in pending confirmation; no resolution is invented.
        failWrites.set(false)
        guard case .pendingConfirmation = try connection.submitApproval(promptID: envelope.prompt.promptID,
                                                                        targetIndex: 0,
                                                                        clientRequestID: "client-1") else {
            return XCTFail("expected pendingConfirmation after retry")
        }
        XCTAssertTrue(resolvedEvents.isEmpty)
        XCTAssertEqual(connection.pendingApprovalPromptEvents().first?.metadata?["submit_state"], "submitting")

        // A duplicate of the same in-flight retry does not send again.
        guard case .pendingConfirmation = try connection.submitApproval(promptID: envelope.prompt.promptID,
                                                                        targetIndex: 0,
                                                                        clientRequestID: "client-1") else {
            return XCTFail("expected idempotent duplicate")
        }
    }

    func testSubmitApprovalUsesConfirmedSendPathWhenAvailable() throws {
        struct ConfirmedFailure: Error {}
        let bestEffort = LineSink()
        var promptEnvelope: CodexAppServerInteractivePromptEnvelope?
        var resolvedEvents = [AgentEvent]()
        let connection = Self.makeApprovalConnection(
            sendLine: { bestEffort.append($0) },
            sendLineConfirmed: { _ in throw ConfirmedFailure() },
            onInteractivePrompt: { promptEnvelope = $0 },
            onInteractivePromptResolved: { resolvedEvents.append($0) })

        connection.receiveLine(Self.commandApprovalLine)
        let envelope = try XCTUnwrap(promptEnvelope)

        XCTAssertThrowsError(try connection.submitApproval(promptID: envelope.prompt.promptID,
                                                           targetIndex: 0,
                                                           clientRequestID: nil)) { error in
            XCTAssertTrue(error is ConfirmedFailure)
        }
        // The best-effort path must not have been used for the approval result.
        XCTAssertTrue(bestEffort.lines().isEmpty)
        XCTAssertTrue(resolvedEvents.isEmpty)
        XCTAssertEqual(connection.pendingApprovalPromptEvents().count, 1)
    }

    func testServerRequestResolvedNotificationClearsPendingPrompt() throws {
        let outbound = LineSink()
        var promptEnvelope: CodexAppServerInteractivePromptEnvelope?
        var resolvedEvents = [AgentEvent]()
        let connection = Self.makeApprovalConnection(
            sendLine: { outbound.append($0) },
            onInteractivePrompt: { promptEnvelope = $0 },
            onInteractivePromptResolved: { resolvedEvents.append($0) })

        connection.receiveLine(Self.commandApprovalLine)
        let envelope = try XCTUnwrap(promptEnvelope)

        connection.receiveLine(#"{"method":"serverRequest/resolved","params":{"threadId":"thread-1","requestId":"approval-1"}}"#)

        XCTAssertEqual(resolvedEvents.map { $0.metadata?["reason"] }, ["server_resolved"])
        XCTAssertEqual(resolvedEvents.first?.metadata?["prompt_id"], envelope.prompt.promptID)
        XCTAssertTrue(connection.pendingApprovalPromptEvents().isEmpty)
        // No result line may be written for a request that was resolved elsewhere.
        XCTAssertTrue(outbound.lines().isEmpty)

        // A late submit answers idempotently with the exact terminal record.
        guard case .alreadyResolved(let event) = try connection.submitApproval(promptID: envelope.prompt.promptID,
                                                                               targetIndex: 0,
                                                                               clientRequestID: nil) else {
            return XCTFail("expected alreadyResolved")
        }
        XCTAssertEqual(event.eventID, resolvedEvents[0].eventID)
        XCTAssertTrue(outbound.lines().isEmpty)
        XCTAssertEqual(resolvedEvents.count, 1, "no second terminal event")
    }

    func testTurnCompletedNotificationClearsPendingPromptsForThatTurn() throws {
        let outbound = LineSink()
        var promptEnvelope: CodexAppServerInteractivePromptEnvelope?
        var resolvedEvents = [AgentEvent]()
        let connection = Self.makeApprovalConnection(
            sendLine: { outbound.append($0) },
            onInteractivePrompt: { promptEnvelope = $0 },
            onInteractivePromptResolved: { resolvedEvents.append($0) })

        connection.receiveLine(Self.commandApprovalLine)
        XCTAssertNotNil(promptEnvelope)

        connection.receiveLine(#"{"method":"turn/completed","params":{"threadId":"thread-1","turn":{"id":"turn-1","status":"completed"}}}"#)

        XCTAssertEqual(resolvedEvents.map { $0.metadata?["reason"] }, ["turn_completed"])
        XCTAssertTrue(connection.pendingApprovalPromptEvents().isEmpty)
        XCTAssertTrue(outbound.lines().isEmpty)
    }

    func testCloseExpiresPendingApprovalPrompts() throws {
        var promptEnvelope: CodexAppServerInteractivePromptEnvelope?
        var resolvedEvents = [AgentEvent]()
        let connection = Self.makeApprovalConnection(
            sendLine: { _ in },
            onInteractivePrompt: { promptEnvelope = $0 },
            onInteractivePromptResolved: { resolvedEvents.append($0) })

        connection.receiveLine(Self.commandApprovalLine)
        let envelope = try XCTUnwrap(promptEnvelope)

        connection.close()

        XCTAssertEqual(resolvedEvents.map { $0.metadata?["reason"] }, ["expired"])
        XCTAssertTrue(connection.pendingApprovalPromptEvents().isEmpty)

        // A submit against a dead transport reports the expired terminal, not
        // success.
        guard case .alreadyResolved(let event) = try connection.submitApproval(promptID: envelope.prompt.promptID,
                                                                               targetIndex: 0,
                                                                               clientRequestID: nil) else {
            return XCTFail("expected expired terminal")
        }
        XCTAssertEqual(event.metadata?["reason"], "expired")
        XCTAssertEqual(resolvedEvents.count, 1)
    }

    func testConflictingSecondDecisionFailsClosed() throws {
        let outbound = LineSink()
        var promptEnvelope: CodexAppServerInteractivePromptEnvelope?
        let connection = Self.makeApprovalConnection(
            sendLine: { outbound.append($0) },
            onInteractivePrompt: { promptEnvelope = $0 })

        connection.receiveLine(Self.commandApprovalLine)
        let envelope = try XCTUnwrap(promptEnvelope)

        guard case .pendingConfirmation = try connection.submitApproval(promptID: envelope.prompt.promptID,
                                                                        targetIndex: 0,
                                                                        clientRequestID: "client-1") else {
            return XCTFail("expected pendingConfirmation")
        }

        // A different decision — whether from the same or another client
        // request identity — must not produce a second wire write.
        XCTAssertThrowsError(try connection.submitApproval(promptID: envelope.prompt.promptID,
                                                           targetIndex: 1,
                                                           clientRequestID: "client-1")) { error in
            guard case BridgeInternalError.conflict = error else {
                return XCTFail("expected conflict, got \(error)")
            }
        }
        XCTAssertThrowsError(try connection.submitApproval(promptID: envelope.prompt.promptID,
                                                           targetIndex: 1,
                                                           clientRequestID: "client-2")) { error in
            guard case BridgeInternalError.conflict = error else {
                return XCTFail("expected conflict, got \(error)")
            }
        }
        XCTAssertEqual(outbound.lines().count, 1)
        let response = try Self.object(from: outbound.lines()[0])
        XCTAssertEqual(response["result"]?.objectValue?["decision"]?.stringValue, "accept")
    }

    func testPermissionsApprovalSubmitSendsSchemaShapedResult() throws {
        let outbound = LineSink()
        var promptEnvelope: CodexAppServerInteractivePromptEnvelope?
        let connection = Self.makeApprovalConnection(
            sendLine: { outbound.append($0) },
            onInteractivePrompt: { promptEnvelope = $0 })

        connection.receiveLine("""
        {"id":"perm-1","method":"item/permissions/requestApproval","params":{"threadId":"thread-1","turnId":"turn-1","itemId":"item-9","startedAtMs":1786000000000,"cwd":"/Users/timfeng/GitHub/Tidey","reason":"Needs network.","permissions":{"network":{"enabled":true}}}}
        """)

        let envelope = try XCTUnwrap(promptEnvelope)
        XCTAssertEqual(envelope.prompt.source, "codex_permissions_approval")
        XCTAssertEqual(envelope.event.metadata?["thread_id"], "thread-1")
        XCTAssertEqual(envelope.event.metadata?["turn_id"], "turn-1")
        XCTAssertEqual(envelope.event.metadata?["item_id"], "item-9")
        XCTAssertEqual(envelope.event.metadata?["request_id"], "s:perm-1")
        XCTAssertNotNil(envelope.event.metadata?["connection_generation"])

        guard case .pendingConfirmation = try connection.submitApproval(promptID: envelope.prompt.promptID,
                                                                        targetIndex: 1,
                                                                        clientRequestID: nil) else {
            return XCTFail("expected pendingConfirmation")
        }
        let response = try Self.object(from: outbound.lines()[0])
        XCTAssertEqual(response["id"]?.stringValue, "perm-1")
        let result = try XCTUnwrap(response["result"]?.objectValue)
        XCTAssertNil(result["decision"])
        XCTAssertEqual(result["scope"]?.stringValue, "session")
        XCTAssertEqual(result["permissions"]?.objectValue?["network"]?.objectValue?["enabled"]?.boolValue, true)
    }

    func testMissingPermissionsRequiredFieldsAnswerInvalidParams() throws {
        let outbound = LineSink()
        var promptEnvelope: CodexAppServerInteractivePromptEnvelope?
        let connection = Self.makeApprovalConnection(
            sendLine: { outbound.append($0) },
            onInteractivePrompt: { promptEnvelope = $0 })

        // Missing startedAtMs.
        connection.receiveLine("""
        {"id":"perm-1","method":"item/permissions/requestApproval","params":{"threadId":"thread-1","turnId":"turn-1","itemId":"item-1","cwd":"/Users/timfeng/GitHub/Tidey","permissions":{}}}
        """)
        // Missing cwd.
        connection.receiveLine("""
        {"id":"perm-2","method":"item/permissions/requestApproval","params":{"threadId":"thread-1","turnId":"turn-1","itemId":"item-1","startedAtMs":1786000000000,"permissions":{}}}
        """)

        XCTAssertNil(promptEnvelope, "partial permission approvals must not be presented")
        let responses = try outbound.lines().map { try Self.object(from: $0) }
        XCTAssertEqual(responses.count, 2)
        for response in responses {
            XCTAssertEqual(response["error"]?.objectValue?["code"]?.intValue, -32602)
        }
    }

    func testRedeliveredPromptGetsFreshEventIdentityWithStableLogicalIdentity() throws {
        var promptEnvelopes = [CodexAppServerInteractivePromptEnvelope]()
        var resolvedEvents = [AgentEvent]()
        let connection = Self.makeApprovalConnection(
            sendLine: { _ in },
            onInteractivePrompt: { promptEnvelopes.append($0) },
            onInteractivePromptResolved: { resolvedEvents.append($0) })

        connection.receiveLine(Self.commandApprovalLine)
        connection.receiveLine(Self.commandApprovalLine)

        XCTAssertEqual(promptEnvelopes.count, 2)
        // Logical prompt identity is stable; delivery event identity is not,
        // so the event hub cannot deduplicate the re-delivery away.
        XCTAssertEqual(promptEnvelopes[0].event.metadata?["prompt_id"],
                       promptEnvelopes[1].event.metadata?["prompt_id"])
        XCTAssertNotEqual(promptEnvelopes[0].event.eventID, promptEnvelopes[1].event.eventID)
        XCTAssertEqual(promptEnvelopes[0].event.metadata?["attempt"], "1")
        XCTAssertEqual(promptEnvelopes[1].event.metadata?["attempt"], "2")

        connection.receiveLine(#"{"method":"serverRequest/resolved","params":{"threadId":"thread-1","requestId":"approval-1"}}"#)
        XCTAssertEqual(resolvedEvents.count, 1)
        XCTAssertEqual(resolvedEvents[0].metadata?["attempt"], "2")
    }

    func testHubDeliversExpiredThenReplayedPromptAcrossConnections() throws {
        // Acceptance: expired -> same-process request replay -> the new
        // prompt really is published (not swallowed by eventID dedupe) and a
        // later resolution publishes exactly once more.
        let hub = AgentEventHub()
        var seq = 0
        let nextSeq: CodexAppServerConnection.SequenceProvider = { _ in
            seq += 1
            return seq
        }
        func makeConnection() -> CodexAppServerConnection {
            CodexAppServerConnection(
                sendLine: { _ in },
                approvalContext: CodexAppServerApprovalContext(workspaceID: "workspace-1",
                                                               panelID: "panel-1",
                                                               sessionID: "session-1",
                                                               epoch: "pid:100|sock:/tmp/a.sock"),
                nextSequence: nextSeq,
                timestampProvider: { "2026-07-15T12:00:00.000Z" },
                onInteractivePrompt: { hub.publish($0.event) },
                onInteractivePromptResolved: { hub.publish($0) })
        }

        let firstConnection = makeConnection()
        firstConnection.receiveLine(Self.commandApprovalLine)
        firstConnection.close()

        // Bridge reconnects to the same app-server process; the pending
        // request is re-delivered on a fresh connection.
        let secondConnection = makeConnection()
        secondConnection.receiveLine(Self.commandApprovalLine)

        var events = hub.fetch(workspaceID: "workspace-1", sessionID: "session-1", limit: 50).events
        var promptEvents = events.filter { $0.type == .interactivePrompt }
        let expiredEvents = events.filter { $0.type == .interactivePromptResolved && $0.metadata?["reason"] == "expired" }
        XCTAssertEqual(promptEvents.count, 2, "the replayed prompt must be published, not deduplicated away")
        XCTAssertEqual(expiredEvents.count, 1)
        XCTAssertEqual(Set(promptEvents.compactMap { $0.metadata?["prompt_id"] }).count, 1)
        // The replayed prompt sorts after the expired terminal, restoring the card.
        let lastLifecycleEvent = events.filter { $0.metadata?["prompt_id"] != nil }.max(by: { $0.seq < $1.seq })
        XCTAssertEqual(lastLifecycleEvent?.type, .interactivePrompt)

        secondConnection.receiveLine(#"{"method":"serverRequest/resolved","params":{"threadId":"thread-1","requestId":"approval-1"}}"#)
        events = hub.fetch(workspaceID: "workspace-1", sessionID: "session-1", limit: 50).events
        promptEvents = events.filter { $0.type == .interactivePrompt }
        let resolvedEvents = events.filter { $0.type == .interactivePromptResolved && $0.metadata?["reason"] == "server_resolved" }
        XCTAssertEqual(resolvedEvents.count, 1, "the resolution publishes exactly once")
        XCTAssertEqual(promptEvents.count, 2)
    }

    func testChangedPayloadRedeliveryWithoutInFlightResponseKeepsDisplayResponseAtomic() throws {
        let outbound = LineSink()
        var promptEnvelopes = [CodexAppServerInteractivePromptEnvelope]()
        var resolvedEvents = [AgentEvent]()
        let connection = Self.makeApprovalConnection(
            sendLine: { outbound.append($0) },
            onInteractivePrompt: { promptEnvelopes.append($0) },
            onInteractivePromptResolved: { resolvedEvents.append($0) })

        // No submit has happened: nothing for the old payload can reach the
        // wire, so the changed payload may start a clean lifecycle.
        connection.receiveLine(Self.commandApprovalLine)
        connection.receiveLine("""
        {"id":"approval-1","method":"item/commandExecution/requestApproval","params":{"threadId":"thread-1","turnId":"turn-1","itemId":"item-1","startedAtMs":1786000000000,"reason":"Needs network.","command":"rm -rf /","cwd":"/Users/timfeng/GitHub/Tidey"}}
        """)

        XCTAssertEqual(resolvedEvents.map { $0.metadata?["reason"] }, ["superseded"])
        XCTAssertEqual(promptEnvelopes.count, 2)
        XCTAssertTrue(promptEnvelopes[1].prompt.body.contains("rm -rf /"))
        XCTAssertEqual(promptEnvelopes[1].request.command, "rm -rf /")

        // A fresh decision produces a response from the NEW request: the
        // displayed prompt and the response source are the same lifecycle.
        guard case .pendingConfirmation = try connection.submitApproval(promptID: promptEnvelopes[1].prompt.promptID,
                                                                        targetIndex: 1,
                                                                        clientRequestID: "client-2") else {
            return XCTFail("expected pendingConfirmation for the new lifecycle")
        }
        XCTAssertEqual(outbound.lines().count, 1)
        let response = try Self.object(from: outbound.lines()[0])
        XCTAssertEqual(response["result"]?.objectValue?["decision"]?.stringValue, "decline")
    }

    func testChangedPayloadRedeliveryAfterFlushedResponseIsRejectedFailClosed() throws {
        let outbound = LineSink()
        var promptEnvelopes = [CodexAppServerInteractivePromptEnvelope]()
        var resolvedEvents = [AgentEvent]()
        let connection = Self.makeApprovalConnection(
            sendLine: { outbound.append($0) },
            onInteractivePrompt: { promptEnvelopes.append($0) },
            onInteractivePromptResolved: { resolvedEvents.append($0) })

        connection.receiveLine(Self.commandApprovalLine)
        guard case .pendingConfirmation = try connection.submitApproval(promptID: promptEnvelopes[0].prompt.promptID,
                                                                        targetIndex: 0,
                                                                        clientRequestID: "client-1") else {
            return XCTFail("expected pendingConfirmation")
        }
        XCTAssertEqual(outbound.lines().count, 1)

        // The old payload's response is already on the wire under this
        // JSON-RPC request id. A changed payload under the same identity
        // must NOT become an actionable lifecycle those bytes could approve.
        connection.receiveLine("""
        {"id":"approval-1","method":"item/commandExecution/requestApproval","params":{"threadId":"thread-1","turnId":"turn-1","itemId":"item-1","startedAtMs":1786000000000,"reason":"Needs network.","command":"rm -rf /","cwd":"/Users/timfeng/GitHub/Tidey"}}
        """)

        XCTAssertEqual(resolvedEvents.map { $0.metadata?["reason"] }, ["superseded"])
        XCTAssertEqual(promptEnvelopes.count, 1, "no prompt may be published for the rejected delivery")
        XCTAssertTrue(connection.pendingApprovalPromptEvents().isEmpty)

        // Round 6: the RequestId is poisoned — after the old response, NO
        // further bytes (success OR error) may be written with this id.
        let lines = try outbound.lines().map { try Self.object(from: $0) }
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0]["result"]?.objectValue?["decision"]?.stringValue, "accept")

        // Late submits answer with the superseded terminal, never a fresh
        // approval of the changed payload.
        guard case .alreadyResolved(let event) = try connection.submitApproval(promptID: promptEnvelopes[0].prompt.promptID,
                                                                               targetIndex: 1,
                                                                               clientRequestID: "client-2") else {
            return XCTFail("expected alreadyResolved")
        }
        XCTAssertEqual(event.metadata?["reason"], "superseded")
    }

    func testCloseAdmissionGateRejectsRequestsArrivingAfterClose() throws {
        var promptEnvelopes = [CodexAppServerInteractivePromptEnvelope]()
        var resolvedEvents = [AgentEvent]()
        let outbound = LineSink()
        let connection = Self.makeApprovalConnection(
            sendLine: { outbound.append($0) },
            onInteractivePrompt: { promptEnvelopes.append($0) },
            onInteractivePromptResolved: { resolvedEvents.append($0) })

        connection.receiveLine(Self.commandApprovalLine)
        connection.close()

        // Admitted-before-close request was terminalized by the same close.
        XCTAssertEqual(resolvedEvents.map { $0.metadata?["reason"] }, ["expired"])
        XCTAssertTrue(connection.pendingApprovalPromptEvents().isEmpty)

        // A request racing in after close must not create or publish an
        // active prompt on the retired generation.
        connection.receiveLine("""
        {"id":"approval-2","method":"item/commandExecution/requestApproval","params":{"threadId":"thread-1","turnId":"turn-1","itemId":"item-2","startedAtMs":1786000000000,"command":"ls"}}
        """)
        XCTAssertEqual(promptEnvelopes.count, 1, "retired generation must not publish new prompts")
        XCTAssertTrue(connection.pendingApprovalPromptEvents().isEmpty)
        XCTAssertEqual(resolvedEvents.count, 1)
    }

    func testCloseInterleavedWithRegistrationNeverLeavesActivePrompt() throws {
        // Deterministic barrier variant: registration begins, close runs, and
        // whatever the interleaving, the retired generation ends with zero
        // active prompts and exactly one terminal lifecycle per admitted
        // request.
        for closeFirst in [true, false] {
            var resolvedEvents = [AgentEvent]()
            var promptEnvelopes = [CodexAppServerInteractivePromptEnvelope]()
            let connection = Self.makeApprovalConnection(
                sendLine: { _ in },
                onInteractivePrompt: { promptEnvelopes.append($0) },
                onInteractivePromptResolved: { resolvedEvents.append($0) })

            if closeFirst {
                connection.close()
                connection.receiveLine(Self.commandApprovalLine)
                XCTAssertTrue(promptEnvelopes.isEmpty)
                XCTAssertTrue(resolvedEvents.isEmpty)
            } else {
                connection.receiveLine(Self.commandApprovalLine)
                connection.close()
                XCTAssertEqual(promptEnvelopes.count, 1)
                XCTAssertEqual(resolvedEvents.map { $0.metadata?["reason"] }, ["expired"])
            }
            XCTAssertTrue(connection.pendingApprovalPromptEvents().isEmpty)
        }
    }

    func testCommandAndFileChangeRequestsRequireStartedAtMs() throws {
        let outbound = LineSink()
        var promptEnvelope: CodexAppServerInteractivePromptEnvelope?
        let connection = Self.makeApprovalConnection(
            sendLine: { outbound.append($0) },
            onInteractivePrompt: { promptEnvelope = $0 })

        // Official 0.144.1 schema: startedAtMs is required for all approval
        // methods, not only permissions.
        connection.receiveLine("""
        {"id":"cmd-1","method":"item/commandExecution/requestApproval","params":{"threadId":"thread-1","turnId":"turn-1","itemId":"item-1","command":"ls"}}
        """)
        connection.receiveLine("""
        {"id":"file-1","method":"item/fileChange/requestApproval","params":{"threadId":"thread-1","turnId":"turn-1","itemId":"item-2","reason":"write"}}
        """)

        XCTAssertNil(promptEnvelope, "partial approvals must not be presented")
        let responses = try outbound.lines().map { try Self.object(from: $0) }
        XCTAssertEqual(responses.count, 2)
        for response in responses {
            XCTAssertEqual(response["error"]?.objectValue?["code"]?.intValue, -32602)
        }
    }

    func testCommandApprovalDisplaysAdditionalPermissionsAndEnvironment() throws {
        var promptEnvelope: CodexAppServerInteractivePromptEnvelope?
        let connection = Self.makeApprovalConnection(
            sendLine: { _ in },
            onInteractivePrompt: { promptEnvelope = $0 })

        connection.receiveLine("""
        {"id":"cmd-1","method":"item/commandExecution/requestApproval","params":{"threadId":"thread-1","turnId":"turn-1","itemId":"item-1","startedAtMs":1786000000000,"command":"curl https://example.com","cwd":"/Users/timfeng/GitHub/Tidey","environmentId":"env-9","additionalPermissions":{"network":{"enabled":true},"fileSystem":{"entries":[{"access":"write","path":{"type":"path","path":"/Users/timfeng/secrets"}}]}}}}
        """)

        let prompt = try XCTUnwrap(promptEnvelope?.prompt)
        // The full additional permission profile must be disclosed before the
        // user can approve.
        XCTAssertTrue(prompt.body.contains("Environment: env-9"))
        XCTAssertTrue(prompt.body.contains("Additional permissions:"))
        XCTAssertTrue(prompt.body.contains("Network: allow outbound network access"))
        XCTAssertTrue(prompt.body.contains("- write /Users/timfeng/secrets"))
    }

    // MARK: - Round 5 deterministic barrier tests

    func testStaleResponseBlockedInWriteCannotApproveChangedPayload() throws {
        // Old submit is blocked INSIDE the confirmed write (bytes may reach
        // the wire); a changed-payload redelivery of the same identity must
        // not create anything that response could approve.
        let sendEntered = expectation(description: "confirmed send entered")
        let releaseSend = DispatchSemaphore(value: 0)
        let outbound = LineSink()
        var promptEnvelopes = [CodexAppServerInteractivePromptEnvelope]()
        let resolvedEvents = LockedEvents()
        let connection = Self.makeApprovalConnection(
            sendLine: { outbound.append($0) },
            sendLineConfirmed: { line in
                sendEntered.fulfill()
                _ = releaseSend.wait(timeout: .now() + 2.0)
                outbound.append(line)
            },
            onInteractivePrompt: { promptEnvelopes.append($0) },
            onInteractivePromptResolved: { resolvedEvents.append($0) })

        connection.receiveLine(Self.commandApprovalLine)
        let promptID = promptEnvelopes[0].prompt.promptID

        var submitOutcome: CodexAppServerApprovalSubmitOutcome?
        let submitReturned = expectation(description: "submit returned")
        DispatchQueue.global(qos: .userInitiated).async {
            submitOutcome = try? connection.submitApproval(promptID: promptID,
                                                           targetIndex: 0,
                                                           clientRequestID: "client-1")
            submitReturned.fulfill()
        }
        wait(for: [sendEntered], timeout: 1.0)

        // Changed payload redelivers while the old response is mid-write.
        connection.receiveLine("""
        {"id":"approval-1","method":"item/commandExecution/requestApproval","params":{"threadId":"thread-1","turnId":"turn-1","itemId":"item-1","startedAtMs":1786000000000,"reason":"Needs network.","command":"rm -rf /","cwd":"/Users/timfeng/GitHub/Tidey"}}
        """)

        // Fail closed: no new prompt published, no active lifecycle, old
        // lifecycle terminalized exactly once.
        XCTAssertEqual(promptEnvelopes.count, 1)
        XCTAssertTrue(connection.pendingApprovalPromptEvents().isEmpty)
        XCTAssertEqual(resolvedEvents.snapshot().map { $0.metadata?["reason"] }, ["superseded"])

        releaseSend.signal()
        wait(for: [submitReturned], timeout: 2.0)

        // The old submit sees the superseded terminal; it must not report a
        // pending confirmation that could be read as approving the new
        // payload.
        guard case .alreadyResolved(let event)? = submitOutcome else {
            return XCTFail("expected alreadyResolved, got \(String(describing: submitOutcome))")
        }
        XCTAssertEqual(event.metadata?["reason"], "superseded")

        // Round 6: the id is poisoned — no error reply may be written. The
        // wire carries only the (already irrevocable) old response; the store
        // holds no active prompt.
        let lines = try outbound.lines().map { try Self.object(from: $0) }
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0]["result"]?.objectValue?["decision"]?.stringValue, "accept")
        XCTAssertEqual(resolvedEvents.snapshot().count, 1, "exactly one terminal for the identity")
    }

    func testStaleWriteFailureAfterChangedPayloadDoesNotDisturbTerminalState() throws {
        // Failure interleaving: the blocked confirmed write ultimately throws
        // after the changed-payload redelivery already terminalized the old
        // lifecycle. The old attempt's failure handling must not resurrect or
        // alter anything.
        struct WriteFailure: Error {}
        let sendEntered = expectation(description: "confirmed send entered")
        let releaseSend = DispatchSemaphore(value: 0)
        let outbound = LineSink()
        var promptEnvelopes = [CodexAppServerInteractivePromptEnvelope]()
        let resolvedEvents = LockedEvents()
        let connection = Self.makeApprovalConnection(
            sendLine: { outbound.append($0) },
            sendLineConfirmed: { _ in
                sendEntered.fulfill()
                _ = releaseSend.wait(timeout: .now() + 2.0)
                throw WriteFailure()
            },
            onInteractivePrompt: { promptEnvelopes.append($0) },
            onInteractivePromptResolved: { resolvedEvents.append($0) })

        connection.receiveLine(Self.commandApprovalLine)
        let promptID = promptEnvelopes[0].prompt.promptID

        var submitOutcome: Result<CodexAppServerApprovalSubmitOutcome, Error>?
        let submitReturned = expectation(description: "submit returned")
        DispatchQueue.global(qos: .userInitiated).async {
            submitOutcome = Result { try connection.submitApproval(promptID: promptID,
                                                                   targetIndex: 0,
                                                                   clientRequestID: "client-1") }
            submitReturned.fulfill()
        }
        wait(for: [sendEntered], timeout: 1.0)

        connection.receiveLine("""
        {"id":"approval-1","method":"item/commandExecution/requestApproval","params":{"threadId":"thread-1","turnId":"turn-1","itemId":"item-1","startedAtMs":1786000000000,"reason":"Needs network.","command":"rm -rf /","cwd":"/Users/timfeng/GitHub/Tidey"}}
        """)
        releaseSend.signal()
        wait(for: [submitReturned], timeout: 2.0)

        // The failed old attempt resolves to the superseded terminal; it must
        // not flip the terminal back to pending or create a new lifecycle.
        guard case .success(.alreadyResolved(let event))? = submitOutcome else {
            return XCTFail("expected alreadyResolved, got \(String(describing: submitOutcome))")
        }
        XCTAssertEqual(event.metadata?["reason"], "superseded")
        XCTAssertEqual(promptEnvelopes.count, 1)
        XCTAssertTrue(connection.pendingApprovalPromptEvents().isEmpty)
        XCTAssertEqual(resolvedEvents.snapshot().map { $0.metadata?["reason"] }, ["superseded"])
    }

    func testCloseDuringBlockedWriteTerminalizesExactlyOnce() throws {
        let sendEntered = expectation(description: "confirmed send entered")
        let releaseSend = DispatchSemaphore(value: 0)
        let outbound = LineSink()
        var promptEnvelopes = [CodexAppServerInteractivePromptEnvelope]()
        let resolvedEvents = LockedEvents()
        let connection = Self.makeApprovalConnection(
            sendLine: { outbound.append($0) },
            sendLineConfirmed: { line in
                sendEntered.fulfill()
                _ = releaseSend.wait(timeout: .now() + 2.0)
                outbound.append(line)
            },
            onInteractivePrompt: { promptEnvelopes.append($0) },
            onInteractivePromptResolved: { resolvedEvents.append($0) })

        connection.receiveLine(Self.commandApprovalLine)
        let promptID = promptEnvelopes[0].prompt.promptID

        var submitOutcome: CodexAppServerApprovalSubmitOutcome?
        let submitReturned = expectation(description: "submit returned")
        DispatchQueue.global(qos: .userInitiated).async {
            submitOutcome = try? connection.submitApproval(promptID: promptID,
                                                           targetIndex: 0,
                                                           clientRequestID: "client-1")
            submitReturned.fulfill()
        }
        wait(for: [sendEntered], timeout: 1.0)

        // close() interleaves with the blocked write.
        connection.close()
        releaseSend.signal()
        wait(for: [submitReturned], timeout: 2.0)

        // Exactly one terminal (expired), the old attempt completes into it,
        // and nothing pending survives.
        XCTAssertEqual(resolvedEvents.snapshot().map { $0.metadata?["reason"] }, ["expired"])
        guard case .alreadyResolved(let event)? = submitOutcome else {
            return XCTFail("expected alreadyResolved, got \(String(describing: submitOutcome))")
        }
        XCTAssertEqual(event.metadata?["reason"], "expired")
        XCTAssertTrue(connection.pendingApprovalPromptEvents().isEmpty)
    }

    func testCloseSerializesWithPromptPublicationNeverTerminalThenPending() throws {
        // Barrier inside the admission+publication critical section: close on
        // another thread must WAIT, so the observable order is always
        // pending -> terminal, never terminal -> pending.
        let publicationEntered = expectation(description: "prompt publication entered")
        let releasePublication = DispatchSemaphore(value: 0)
        let observedOrder = LockedStrings()
        var isFirstPrompt = true
        let connection = Self.makeApprovalConnection(
            sendLine: { _ in },
            onInteractivePrompt: { envelope in
                observedOrder.append("prompt:\(envelope.event.metadata?["attempt"] ?? "-")")
                if isFirstPrompt {
                    isFirstPrompt = false
                    publicationEntered.fulfill()
                    _ = releasePublication.wait(timeout: .now() + 2.0)
                }
            },
            onInteractivePromptResolved: { event in
                observedOrder.append("terminal:\(event.metadata?["reason"] ?? "-")")
            })

        let receiveReturned = expectation(description: "receive returned")
        DispatchQueue.global(qos: .userInitiated).async {
            connection.receiveLine(Self.commandApprovalLine)
            receiveReturned.fulfill()
        }
        wait(for: [publicationEntered], timeout: 1.0)

        // close starts while the pending publication callback is still
        // running; it must serialize behind it.
        let closeReturned = expectation(description: "close returned")
        DispatchQueue.global(qos: .userInitiated).async {
            connection.close()
            closeReturned.fulfill()
        }
        // Deterministically assert close has NOT completed while the
        // publication holds the critical section.
        XCTAssertFalse(observedOrder.snapshot().contains { $0.hasPrefix("terminal") })
        releasePublication.signal()
        wait(for: [receiveReturned, closeReturned], timeout: 2.0)

        XCTAssertEqual(observedOrder.snapshot(), ["prompt:1", "terminal:expired"],
                       "a pending prompt must never be observable after its generation's terminal")
        XCTAssertTrue(connection.pendingApprovalPromptEvents().isEmpty)
    }

    func testCloseBlockedInTerminalPublicationRejectsConcurrentAdmission() throws {
        // Reverse interleaving: close holds the critical section publishing
        // the expired terminal; a racing request admission must wait and then
        // be rejected — terminal -> pending is impossible.
        let terminalEntered = expectation(description: "terminal publication entered")
        let releaseTerminal = DispatchSemaphore(value: 0)
        let observedOrder = LockedStrings()
        let connection = Self.makeApprovalConnection(
            sendLine: { _ in },
            onInteractivePrompt: { envelope in
                observedOrder.append("prompt:\(envelope.event.metadata?["item_id"] ?? "-")")
            },
            onInteractivePromptResolved: { event in
                observedOrder.append("terminal:\(event.metadata?["reason"] ?? "-")")
                terminalEntered.fulfill()
                _ = releaseTerminal.wait(timeout: .now() + 2.0)
            })

        connection.receiveLine(Self.commandApprovalLine)

        let closeReturned = expectation(description: "close returned")
        DispatchQueue.global(qos: .userInitiated).async {
            connection.close()
            closeReturned.fulfill()
        }
        wait(for: [terminalEntered], timeout: 1.0)

        // A new request races in while the terminal publication is mid-way.
        let admissionReturned = expectation(description: "admission returned")
        DispatchQueue.global(qos: .userInitiated).async {
            connection.receiveLine("""
            {"id":"approval-2","method":"item/commandExecution/requestApproval","params":{"threadId":"thread-1","turnId":"turn-1","itemId":"item-9","startedAtMs":1786000000000,"command":"ls"}}
            """)
            admissionReturned.fulfill()
        }
        releaseTerminal.signal()
        wait(for: [closeReturned, admissionReturned], timeout: 2.0)

        XCTAssertEqual(observedOrder.snapshot(), ["prompt:item-1", "terminal:expired"],
                       "no pending prompt may follow the retired generation's terminal")
        XCTAssertTrue(connection.pendingApprovalPromptEvents().isEmpty)
    }

    func testBatchedTerminalsFromSingleCloseGetUniqueMonotonicSeqs() throws {
        let hub = AgentEventHub()
        let connection = CodexAppServerConnection(
            sendLine: { _ in },
            approvalContext: CodexAppServerApprovalContext(workspaceID: "workspace-1",
                                                           panelID: "panel-1",
                                                           sessionID: "session-1",
                                                           epoch: "pid:1|sock:/tmp/a.sock"),
            nextSequence: { sessionID in hub.nextSyntheticSeq(sessionID: sessionID) },
            timestampProvider: { "2026-07-15T12:00:00.000Z" },
            onInteractivePrompt: { hub.publish($0.event) },
            onInteractivePromptResolved: { hub.publish($0) })

        connection.receiveLine(Self.commandApprovalLine)
        connection.receiveLine("""
        {"id":"approval-2","method":"item/commandExecution/requestApproval","params":{"threadId":"thread-1","turnId":"turn-1","itemId":"item-2","startedAtMs":1786000000000,"command":"pwd"}}
        """)

        // One close expires BOTH approvals: the terminals are created in one
        // batch before publication and must still get unique, increasing
        // seqs, or (sessionID, seq) identity collapses them on iOS.
        connection.close()

        let events = hub.fetch(workspaceID: "workspace-1", sessionID: "session-1", limit: 50).events
        let terminals = events.filter { $0.type == .interactivePromptResolved }
        XCTAssertEqual(terminals.count, 2, "both terminals must survive publication")
        let seqs = terminals.map(\.seq)
        XCTAssertEqual(Set(seqs).count, 2, "terminal seqs must be unique")
        XCTAssertEqual(seqs, seqs.sorted())
    }

    func testBatchedTerminalsFromSingleTurnCompletedGetUniqueSeqs() throws {
        let hub = AgentEventHub()
        let connection = CodexAppServerConnection(
            sendLine: { _ in },
            approvalContext: CodexAppServerApprovalContext(workspaceID: "workspace-1",
                                                           panelID: "panel-1",
                                                           sessionID: "session-1",
                                                           epoch: "pid:1|sock:/tmp/a.sock"),
            nextSequence: { sessionID in hub.nextSyntheticSeq(sessionID: sessionID) },
            timestampProvider: { "2026-07-15T12:00:00.000Z" },
            onInteractivePrompt: { hub.publish($0.event) },
            onInteractivePromptResolved: { hub.publish($0) })

        connection.receiveLine(Self.commandApprovalLine)
        connection.receiveLine("""
        {"id":"approval-2","method":"item/commandExecution/requestApproval","params":{"threadId":"thread-1","turnId":"turn-1","itemId":"item-2","startedAtMs":1786000000000,"command":"pwd"}}
        """)
        connection.receiveLine(#"{"method":"turn/completed","params":{"threadId":"thread-1","turn":{"id":"turn-1","status":"completed"}}}"#)

        let events = hub.fetch(workspaceID: "workspace-1", sessionID: "session-1", limit: 50).events
        let terminals = events.filter { $0.type == .interactivePromptResolved && $0.metadata?["reason"] == "turn_completed" }
        XCTAssertEqual(terminals.count, 2)
        let seqs = terminals.map(\.seq)
        XCTAssertEqual(Set(seqs).count, 2)
        XCTAssertEqual(seqs, seqs.sorted())
    }

    // MARK: - Round 6

    // Production transport enqueues the frame BEFORE waiting on the write
    // future. This fake reproduces that order: append (enqueue) first, then
    // block (the .wait()).
    private final class EnqueueThenWaitWriter: @unchecked Sendable {
        let outbound = LineSink()
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)

        func send(_ line: String) {
            outbound.append(line)
            entered.signal()
            _ = release.wait(timeout: .now() + 3.0)
        }
    }

    private static let changedPayloadLine = """
    {"id":"approval-1","method":"item/commandExecution/requestApproval","params":{"threadId":"thread-1","turnId":"turn-1","itemId":"item-1","startedAtMs":1786000000000,"reason":"Needs network.","command":"rm -rf /","cwd":"/Users/timfeng/GitHub/Tidey"}}
    """

    func testChangedRequestAfterEnqueuedResponsePoisonsRequestIDAndWritesNoFurtherBytes() throws {
        let writer = EnqueueThenWaitWriter()
        var promptEnvelopes = [CodexAppServerInteractivePromptEnvelope]()
        let resolvedEvents = LockedEvents()
        var protocolViolations = 0
        let connection = CodexAppServerConnection(
            sendLine: { writer.outbound.append($0) },
            sendLineConfirmed: { writer.send($0) },
            approvalContext: CodexAppServerApprovalContext(workspaceID: "workspace-1",
                                                           panelID: "panel-1",
                                                           sessionID: "session-1",
                                                           epoch: "pid:1|sock:/tmp/a.sock"),
            timestampProvider: { "2026-07-15T12:00:00.000Z" },
            onInteractivePrompt: { promptEnvelopes.append($0) },
            onInteractivePromptResolved: { resolvedEvents.append($0) },
            onProtocolViolation: { protocolViolations += 1 })

        connection.receiveLine(Self.commandApprovalLine)
        let promptID = promptEnvelopes[0].prompt.promptID
        let lifecycleToken = promptEnvelopes[0].event.eventID

        var submitOutcome: Result<CodexAppServerApprovalSubmitOutcome, Error>?
        let submitReturned = expectation(description: "submit returned")
        DispatchQueue.global(qos: .userInitiated).async {
            submitOutcome = Result { try connection.submitApproval(promptID: promptID,
                                                                   targetIndex: 0,
                                                                   clientRequestID: "client-1",
                                                                   lifecycleToken: lifecycleToken) }
            submitReturned.fulfill()
        }
        // The A response frame is ENQUEUED (production order) and the writer
        // is stuck in the wait.
        XCTAssertEqual(writer.entered.wait(timeout: .now() + 2.0), .success)
        XCTAssertEqual(writer.outbound.lines().count, 1)

        // B: changed payload under the SAME JSON-RPC RequestId.
        connection.receiveLine(Self.changedPayloadLine)

        // Fail closed: no prompt for B, no second response frame with this
        // id (success OR error), the request identity is poisoned, and the
        // connection reports a protocol violation (abort).
        XCTAssertEqual(promptEnvelopes.count, 1)
        XCTAssertEqual(writer.outbound.lines().count, 1,
                       "no further bytes may be written for a poisoned RequestId")
        XCTAssertEqual(protocolViolations, 1)
        XCTAssertTrue(connection.pendingApprovalPromptEvents().isEmpty)

        // Second and third redeliveries stay rejected: the generic terminal
        // branch must not resurrect a poisoned identity.
        connection.receiveLine(Self.changedPayloadLine)
        connection.receiveLine(Self.commandApprovalLine)
        XCTAssertEqual(promptEnvelopes.count, 1)
        XCTAssertTrue(connection.pendingApprovalPromptEvents().isEmpty)
        XCTAssertEqual(writer.outbound.lines().count, 1)

        writer.release.signal()
        wait(for: [submitReturned], timeout: 2.0)
        if case .success(.pendingConfirmation)? = submitOutcome {
            XCTFail("a poisoned lifecycle must not report pending confirmation")
        }
    }

    func testIdenticalRedeliveryDoesNotClearWireTaintBeforeChangedRequest() throws {
        // Window: A response is ENQUEUED (production order) and blocked; an
        // identical A redelivery re-arms the prompt; then a changed B arrives
        // under the same JSON-RPC id. The identical redelivery must NOT have
        // cleared the wire taint: B is a protocol violation, never actionable.
        let writer = EnqueueThenWaitWriter()
        var promptEnvelopes = [CodexAppServerInteractivePromptEnvelope]()
        var protocolViolations = 0
        let connection = CodexAppServerConnection(
            sendLine: { writer.outbound.append($0) },
            sendLineConfirmed: { writer.send($0) },
            approvalContext: CodexAppServerApprovalContext(workspaceID: "workspace-1",
                                                           panelID: "panel-1",
                                                           sessionID: "session-1",
                                                           epoch: "pid:1|sock:/tmp/a.sock"),
            timestampProvider: { "2026-07-15T12:00:00.000Z" },
            onInteractivePrompt: { promptEnvelopes.append($0) },
            onInteractivePromptResolved: { _ in },
            onProtocolViolation: { protocolViolations += 1 })

        connection.receiveLine(Self.commandApprovalLine)
        let promptID = promptEnvelopes[0].prompt.promptID
        let token = promptEnvelopes[0].event.eventID

        var submitOutcome: Result<CodexAppServerApprovalSubmitOutcome, Error>?
        let submitReturned = expectation(description: "submit returned")
        DispatchQueue.global(qos: .userInitiated).async {
            submitOutcome = Result { try connection.submitApproval(promptID: promptID,
                                                                   targetIndex: 0,
                                                                   clientRequestID: "client-1",
                                                                   lifecycleToken: token) }
            submitReturned.fulfill()
        }
        XCTAssertEqual(writer.entered.wait(timeout: .now() + 2.0), .success)
        XCTAssertEqual(writer.outbound.lines().count, 1)

        // Identical A redelivery while the A frame is on the wire.
        connection.receiveLine(Self.commandApprovalLine)
        XCTAssertEqual(promptEnvelopes.count, 2, "identical redelivery re-arms the prompt")

        // Changed B under the same id: must be a violation despite the
        // intervening identical redelivery.
        connection.receiveLine(Self.changedPayloadLine)
        connection.receiveLine(Self.changedPayloadLine)
        connection.receiveLine(Self.changedPayloadLine)

        XCTAssertEqual(promptEnvelopes.count, 2, "B must never become actionable")
        XCTAssertEqual(protocolViolations, 1, "exactly one violation/abort")
        XCTAssertEqual(writer.outbound.lines().count, 1, "no second response or error bytes for the tainted id")
        XCTAssertTrue(connection.pendingApprovalPromptEvents().isEmpty)

        writer.release.signal()
        wait(for: [submitReturned], timeout: 2.0)
        if case .success(.pendingConfirmation)? = submitOutcome {
            XCTFail("a poisoned lifecycle must not report pending confirmation")
        }
    }

    func testChangedRequestAfterFlushedResponsePoisonsPermanently() throws {
        let outbound = LineSink()
        var promptEnvelopes = [CodexAppServerInteractivePromptEnvelope]()
        var protocolViolations = 0
        let connection = CodexAppServerConnection(
            sendLine: { outbound.append($0) },
            approvalContext: CodexAppServerApprovalContext(workspaceID: "workspace-1",
                                                           panelID: "panel-1",
                                                           sessionID: "session-1",
                                                           epoch: "pid:1|sock:/tmp/a.sock"),
            timestampProvider: { "2026-07-15T12:00:00.000Z" },
            onInteractivePrompt: { promptEnvelopes.append($0) },
            onInteractivePromptResolved: { _ in },
            onProtocolViolation: { protocolViolations += 1 })

        connection.receiveLine(Self.commandApprovalLine)
        let token = promptEnvelopes[0].event.eventID
        guard case .pendingConfirmation = try connection.submitApproval(promptID: promptEnvelopes[0].prompt.promptID,
                                                                        targetIndex: 0,
                                                                        clientRequestID: "client-1",
                                                                        lifecycleToken: token) else {
            return XCTFail("expected pendingConfirmation")
        }
        XCTAssertEqual(outbound.lines().count, 1)

        // Response fully flushed; a changed request with the same id is a
        // protocol violation and poisons the identity for the connection.
        connection.receiveLine(Self.changedPayloadLine)
        connection.receiveLine(Self.changedPayloadLine)
        connection.receiveLine(Self.commandApprovalLine)

        XCTAssertEqual(promptEnvelopes.count, 1)
        XCTAssertEqual(outbound.lines().count, 1)
        XCTAssertEqual(protocolViolations, 1)
        XCTAssertTrue(connection.pendingApprovalPromptEvents().isEmpty)
    }

    private func makeEnqueueBlockedApproval() -> (CodexAppServerConnection, EnqueueThenWaitWriter, () -> Int, () -> Int, XCTestExpectation) {
        let writer = EnqueueThenWaitWriter()
        var promptEnvelopes = [CodexAppServerInteractivePromptEnvelope]()
        var protocolViolations = 0
        let connection = CodexAppServerConnection(
            sendLine: { writer.outbound.append($0) },
            sendLineConfirmed: { writer.send($0) },
            approvalContext: CodexAppServerApprovalContext(workspaceID: "workspace-1",
                                                           panelID: "panel-1",
                                                           sessionID: "session-1",
                                                           epoch: "pid:1|sock:/tmp/a.sock"),
            timestampProvider: { "2026-07-15T12:00:00.000Z" },
            onInteractivePrompt: { promptEnvelopes.append($0) },
            onInteractivePromptResolved: { _ in },
            onProtocolViolation: { protocolViolations += 1 })
        connection.receiveLine(Self.commandApprovalLine)
        let submitReturned = expectation(description: "submit returned")
        let promptID = promptEnvelopes[0].prompt.promptID
        let token = promptEnvelopes[0].event.eventID
        DispatchQueue.global(qos: .userInitiated).async {
            _ = try? connection.submitApproval(promptID: promptID,
                                               targetIndex: 0,
                                               clientRequestID: "client-1",
                                               lifecycleToken: token)
            submitReturned.fulfill()
        }
        XCTAssertEqual(writer.entered.wait(timeout: .now() + 2.0), .success)
        XCTAssertEqual(writer.outbound.lines().count, 1)
        return (connection, writer, { promptEnvelopes.count }, { protocolViolations }, submitReturned)
    }

    func testMalformedApprovalWithTaintedRequestIDWritesNoErrorFrame() throws {
        // A approval response enqueued/blocked; a malformed (supported
        // method, missing startedAtMs) request reuses the same id. The error
        // path must go through the same ledger: no second frame, poisoned.
        let (connection, writer, promptCount, violations, submitReturned) = makeEnqueueBlockedApproval()

        connection.receiveLine("""
        {"id":"approval-1","method":"item/commandExecution/requestApproval","params":{"threadId":"thread-1","turnId":"turn-1","itemId":"item-1","command":"ls"}}
        """)
        connection.receiveLine("""
        {"id":"approval-1","method":"item/commandExecution/requestApproval","params":{"threadId":"thread-1","turnId":"turn-1","itemId":"item-1","command":"ls"}}
        """)

        XCTAssertEqual(writer.outbound.lines().count, 1, "no error frame may join a tainted RequestId")
        XCTAssertEqual(violations(), 1)
        XCTAssertEqual(promptCount(), 1, "no prompt revival")
        XCTAssertTrue(connection.pendingApprovalPromptEvents().isEmpty)
        writer.release.signal()
        wait(for: [submitReturned], timeout: 2.0)
    }

    func testUnsupportedMethodWithTaintedRequestIDWritesNoErrorFrame() throws {
        let (connection, writer, promptCount, violations, submitReturned) = makeEnqueueBlockedApproval()

        connection.receiveLine("""
        {"id":"approval-1","method":"totally/unknownMethod","params":{"foo":"bar"}}
        """)
        connection.receiveLine("""
        {"id":"approval-1","method":"totally/unknownMethod","params":{"foo":"bar"}}
        """)

        XCTAssertEqual(writer.outbound.lines().count, 1, "no unsupported-method error may join a tainted RequestId")
        XCTAssertEqual(violations(), 1)
        XCTAssertEqual(promptCount(), 1)
        XCTAssertTrue(connection.pendingApprovalPromptEvents().isEmpty)
        writer.release.signal()
        wait(for: [submitReturned], timeout: 2.0)
    }

    func testErrorRespondedRequestIDCannotBecomeFreshApproval() throws {
        // Reverse direction: an error frame was already written for an
        // unsupported request; the same id later arriving as a valid approval
        // must not be treated as a fresh id.
        let outbound = LineSink()
        var promptEnvelopes = [CodexAppServerInteractivePromptEnvelope]()
        var protocolViolations = 0
        let connection = CodexAppServerConnection(
            sendLine: { outbound.append($0) },
            approvalContext: CodexAppServerApprovalContext(workspaceID: "workspace-1",
                                                           panelID: "panel-1",
                                                           sessionID: "session-1",
                                                           epoch: "pid:1|sock:/tmp/a.sock"),
            timestampProvider: { "2026-07-15T12:00:00.000Z" },
            onInteractivePrompt: { promptEnvelopes.append($0) },
            onInteractivePromptResolved: { _ in },
            onProtocolViolation: { protocolViolations += 1 })

        connection.receiveLine("""
        {"id":"approval-1","method":"totally/unknownMethod","params":{"foo":"bar"}}
        """)
        XCTAssertEqual(outbound.lines().count, 1, "the unsupported request gets its error response")

        connection.receiveLine(Self.commandApprovalLine)
        connection.receiveLine(Self.commandApprovalLine)

        XCTAssertTrue(promptEnvelopes.isEmpty, "an error-responded id must not revive as a fresh approval")
        XCTAssertEqual(outbound.lines().count, 1, "no contradictory second frame")
        XCTAssertEqual(protocolViolations, 1)
        XCTAssertTrue(connection.pendingApprovalPromptEvents().isEmpty)
    }

    func testIdenticalUnsupportedRedeliveryMayRepeatSameError() throws {
        // Equivalence is preserved: the SAME malformed/unsupported request
        // redelivered may re-send the equivalent error response.
        let outbound = LineSink()
        var violations = 0
        let connection = CodexAppServerConnection(
            sendLine: { outbound.append($0) },
            approvalContext: CodexAppServerApprovalContext(workspaceID: "workspace-1",
                                                           panelID: "panel-1",
                                                           sessionID: "session-1",
                                                           epoch: "pid:1|sock:/tmp/a.sock"),
            timestampProvider: { "2026-07-15T12:00:00.000Z" },
            onInteractivePrompt: { _ in },
            onInteractivePromptResolved: { _ in },
            onProtocolViolation: { violations += 1 })

        connection.receiveLine("""
        {"id":"approval-9","method":"totally/unknownMethod","params":{"foo":"bar"}}
        """)
        connection.receiveLine("""
        {"id":"approval-9","method":"totally/unknownMethod","params":{"foo":"bar"}}
        """)
        XCTAssertEqual(outbound.lines().count, 2, "identical redelivery keeps the equivalent error behavior")
        XCTAssertEqual(violations, 0)
    }

    // Round 8 addendum P0-6: the wire collision fingerprint must cover the
    // COMPLETE raw request payload, not the lossy presentation subset.

    private func makeEnqueueBlockedApproval(line: String) -> (CodexAppServerConnection, EnqueueThenWaitWriter, () -> Int, () -> Int, XCTestExpectation, () -> String?) {
        let writer = EnqueueThenWaitWriter()
        var promptEnvelopes = [CodexAppServerInteractivePromptEnvelope]()
        var protocolViolations = 0
        let connection = CodexAppServerConnection(
            sendLine: { writer.outbound.append($0) },
            sendLineConfirmed: { writer.send($0) },
            approvalContext: CodexAppServerApprovalContext(workspaceID: "workspace-1",
                                                           panelID: "panel-1",
                                                           sessionID: "session-1",
                                                           epoch: "pid:1|sock:/tmp/a.sock"),
            timestampProvider: { "2026-07-15T12:00:00.000Z" },
            onInteractivePrompt: { promptEnvelopes.append($0) },
            onInteractivePromptResolved: { _ in },
            onProtocolViolation: { protocolViolations += 1 })
        connection.receiveLine(line)
        XCTAssertEqual(promptEnvelopes.count, 1)
        let submitReturned = expectation(description: "submit returned")
        let promptID = promptEnvelopes[0].prompt.promptID
        let token = promptEnvelopes[0].event.eventID
        DispatchQueue.global(qos: .userInitiated).async {
            _ = try? connection.submitApproval(promptID: promptID,
                                               targetIndex: 0,
                                               clientRequestID: "client-1",
                                               lifecycleToken: token)
            submitReturned.fulfill()
        }
        XCTAssertEqual(writer.entered.wait(timeout: .now() + 2.0), .success)
        XCTAssertEqual(writer.outbound.lines().count, 1)
        return (connection, writer, { promptEnvelopes.count }, { protocolViolations }, submitReturned, { promptEnvelopes.last?.prompt.promptID })
    }

    private func assertChangedPayloadPoisons(baseLine: String,
                                             changedLine: String,
                                             file: StaticString = #filePath,
                                             line: UInt = #line) {
        let (connection, writer, promptCount, violations, submitReturned, _) = makeEnqueueBlockedApproval(line: baseLine)
        connection.receiveLine(changedLine)
        connection.receiveLine(changedLine)
        XCTAssertEqual(promptCount(), 1, "changed payload must never become actionable", file: file, line: line)
        XCTAssertEqual(violations(), 1, "exactly one poison/abort", file: file, line: line)
        XCTAssertEqual(writer.outbound.lines().count, 1, "zero second bytes", file: file, line: line)
        XCTAssertTrue(connection.pendingApprovalPromptEvents().isEmpty, file: file, line: line)
        writer.release.signal()
        wait(for: [submitReturned], timeout: 2.0)
    }

    private func makeErrorRespondedConnection(firstLine: String) -> (CodexAppServerConnection, LineSink, () -> Int, () -> Int) {
        let outbound = LineSink()
        var promptCount = 0
        var protocolViolations = 0
        let connection = CodexAppServerConnection(
            sendLine: { outbound.append($0) },
            approvalContext: CodexAppServerApprovalContext(workspaceID: "workspace-1",
                                                           panelID: "panel-1",
                                                           sessionID: "session-1",
                                                           epoch: "pid:1|sock:/tmp/a.sock"),
            timestampProvider: { "2026-07-15T12:00:00.000Z" },
            onInteractivePrompt: { _ in promptCount += 1 },
            onInteractivePromptResolved: { _ in },
            onProtocolViolation: { protocolViolations += 1 })
        connection.receiveLine(firstLine)
        XCTAssertEqual(outbound.lines().count, 1, "the first request gets its error response")
        return (connection, outbound, { promptCount }, { protocolViolations })
    }

    func testNonObjectParamsFragmentChangeIsACollision() throws {
        // A's error frame for params:[1] is on the wire; same id/method with
        // params:[2] is CHANGED content: zero further bytes, poison exactly
        // once.
        let (connection, outbound, _, violations) = makeErrorRespondedConnection(firstLine: """
        {"id":"frag-1","method":"totally/unknownMethod","params":[1]}
        """)
        connection.receiveLine("""
        {"id":"frag-1","method":"totally/unknownMethod","params":[2]}
        """)
        connection.receiveLine("""
        {"id":"frag-1","method":"totally/unknownMethod","params":[2]}
        """)
        XCTAssertEqual(outbound.lines().count, 1, "no second frame for changed fragment params")
        XCTAssertEqual(violations(), 1, "poison/abort exactly once")
    }

    func testParamsPresenceAndJSONTypeChangesAreAllCollisions() throws {
        // missing / null / bool / string / number / array / object are all
        // mutually non-equivalent under the same id/method.
        let variants = [
            "",                       // missing params
            ",\"params\":null",
            ",\"params\":true",
            ",\"params\":\"x\"",
            ",\"params\":1",
            ",\"params\":[1]",
            ",\"params\":{\"a\":1}",
        ]
        for (index, first) in variants.enumerated() {
            for (otherIndex, second) in variants.enumerated() where otherIndex != index {
                let (connection, outbound, _, violations) = makeErrorRespondedConnection(firstLine: """
                {"id":"presence-\(index)-\(otherIndex)","method":"totally/unknownMethod"\(first)}
                """)
                connection.receiveLine("""
                {"id":"presence-\(index)-\(otherIndex)","method":"totally/unknownMethod"\(second)}
                """)
                XCTAssertEqual(outbound.lines().count, 1,
                               "variant \(index) -> \(otherIndex) must be a changed payload (no second frame)")
                XCTAssertEqual(violations(), 1,
                               "variant \(index) -> \(otherIndex) must poison")
            }
        }
        // Object key order-only stays equivalent (second identical error OK).
        let (connection, outbound, _, violations) = makeErrorRespondedConnection(firstLine: """
        {"id":"order-1","method":"totally/unknownMethod","params":{"a":1,"b":"x"}}
        """)
        connection.receiveLine("""
        {"id":"order-1","method":"totally/unknownMethod","params":{"b":"x","a":1}}
        """)
        XCTAssertEqual(outbound.lines().count, 2, "key-order-only is identical: the equivalent error repeats")
        XCTAssertEqual(violations(), 0)
    }

    func testValidApprovalUnknownFieldTypeChangesAreCollisions() throws {
        // Type changes on a parser-unknown field must collide, and they stay
        // in the VALID approval domain (a pre-wire change supersedes; the
        // enqueue-blocked change poisons).
        let base = """
        {"id":"approval-t","method":"item/commandExecution/requestApproval","params":{"threadId":"thread-1","turnId":"turn-1","itemId":"item-1","startedAtMs":1786000000000,"command":"ls","cwd":"/tmp","futureField":"1"}}
        """
        for changed in [
            "\"futureField\":1",
            "\"futureField\":true",
            "\"futureField\":null",
            "\"futureField\":[\"1\"]",
        ] {
            let changedLine = """
            {"id":"approval-t","method":"item/commandExecution/requestApproval","params":{"threadId":"thread-1","turnId":"turn-1","itemId":"item-1","startedAtMs":1786000000000,"command":"ls","cwd":"/tmp",\(changed)}}
            """
            assertChangedPayloadPoisons(baseLine: base, changedLine: changedLine)
        }
    }

    func testUnknownInt64FieldBeyondDoublePrecisionIsACollision() throws {
        // 9007199254740992 vs 9007199254740993 are equal after a Double
        // round-trip: the fingerprint must be int64-exact.
        let base = """
        {"id":"approval-i","method":"item/commandExecution/requestApproval","params":{"threadId":"thread-1","turnId":"turn-1","itemId":"item-1","startedAtMs":1786000000000,"command":"ls","cwd":"/tmp","bigCounter":9007199254740992}}
        """
        let changed = """
        {"id":"approval-i","method":"item/commandExecution/requestApproval","params":{"threadId":"thread-1","turnId":"turn-1","itemId":"item-1","startedAtMs":1786000000000,"command":"ls","cwd":"/tmp","bigCounter":9007199254740993}}
        """
        assertChangedPayloadPoisons(baseLine: base, changedLine: changed)

        // Key-order-only equivalent with the big int stays identical.
        let reordered = """
        {"id":"approval-i2","method":"item/commandExecution/requestApproval","params":{"bigCounter":9007199254740992,"cwd":"/tmp","command":"ls","startedAtMs":1786000000000,"itemId":"item-1","turnId":"turn-1","threadId":"thread-1"}}
        """
        let baseI2 = base.replacingOccurrences(of: "approval-i", with: "approval-i2")
        let (connection, writer, promptCount, violations, submitReturned, _) = makeEnqueueBlockedApproval(line: baseI2)
        connection.receiveLine(reordered)
        XCTAssertEqual(promptCount(), 2, "key-order-only redelivery with a big int64 is identical")
        XCTAssertEqual(violations(), 0)
        writer.release.signal()
        wait(for: [submitReturned], timeout: 2.0)
    }

    func testChangedStartedAtMsOnlyIsACollision() throws {
        assertChangedPayloadPoisons(
            baseLine: Self.commandApprovalLine,
            changedLine: """
            {"id":"approval-1","method":"item/commandExecution/requestApproval","params":{"threadId":"thread-1","turnId":"turn-1","itemId":"item-1","startedAtMs":1786000000001,"reason":"Needs network.","command":"python3 -c 'print(1)'","cwd":"/Users/timfeng/GitHub/Tidey"}}
            """)
    }

    func testChangedUnknownParamsFieldIsACollision() throws {
        assertChangedPayloadPoisons(
            baseLine: Self.commandApprovalLine,
            changedLine: """
            {"id":"approval-1","method":"item/commandExecution/requestApproval","params":{"threadId":"thread-1","turnId":"turn-1","itemId":"item-1","startedAtMs":1786000000000,"reason":"Needs network.","command":"python3 -c 'print(1)'","cwd":"/Users/timfeng/GitHub/Tidey","futureUnknownField":"changed"}}
            """)
    }

    func testChangedCommandActionSubfieldIgnoredBySummaryIsACollision() throws {
        let base = """
        {"id":"approval-1","method":"item/commandExecution/requestApproval","params":{"threadId":"thread-1","turnId":"turn-1","itemId":"item-1","startedAtMs":1786000000000,"command":"ls","cwd":"/tmp","commandActions":[{"type":"read","path":"/etc/hosts","annotation":"v1"}]}}
        """
        let changed = """
        {"id":"approval-1","method":"item/commandExecution/requestApproval","params":{"threadId":"thread-1","turnId":"turn-1","itemId":"item-1","startedAtMs":1786000000000,"command":"ls","cwd":"/tmp","commandActions":[{"type":"read","path":"/etc/hosts","annotation":"v2"}]}}
        """
        assertChangedPayloadPoisons(baseLine: base, changedLine: changed)
    }

    func testKeyOrderOnlyDifferenceIsIdenticalButTypeDifferencesAreNot() throws {
        // Same semantics, different JSON object key order: identical
        // re-delivery (re-arms, no violation, no second frame while blocked).
        let reordered = """
        {"id":"approval-1","method":"item/commandExecution/requestApproval","params":{"cwd":"/Users/timfeng/GitHub/Tidey","command":"python3 -c 'print(1)'","reason":"Needs network.","startedAtMs":1786000000000,"itemId":"item-1","turnId":"turn-1","threadId":"thread-1"}}
        """
        let (connection, writer, promptCount, violations, submitReturned, _) = makeEnqueueBlockedApproval(line: Self.commandApprovalLine)
        connection.receiveLine(reordered)
        XCTAssertEqual(promptCount(), 2, "a key-order-only redelivery is IDENTICAL and re-arms the prompt")
        XCTAssertEqual(violations(), 0)
        XCTAssertEqual(writer.outbound.lines().count, 1)
        writer.release.signal()
        wait(for: [submitReturned], timeout: 2.0)

        // Type differences must be preserved: number 1786000000000 vs the
        // string "1786000000000" is a CHANGED payload.
        assertChangedPayloadPoisons(
            baseLine: Self.commandApprovalLine.replacingOccurrences(of: "approval-1", with: "approval-2"),
            changedLine: """
            {"id":"approval-2","method":"item/commandExecution/requestApproval","params":{"threadId":"thread-1","turnId":"turn-1","itemId":"item-1","startedAtMs":"1786000000000","reason":"Needs network.","command":"python3 -c 'print(1)'","cwd":"/Users/timfeng/GitHub/Tidey"}}
            """)
    }

    func testSameRequestIDDifferentItemOrMethodCannotCoexistAsPending() throws {
        // Pre-wire: the server replacing the outstanding request (different
        // item, then different method, same JSON-RPC id) must never leave TWO
        // actionable prompts able to answer with the same id.
        var promptEnvelopes = [CodexAppServerInteractivePromptEnvelope]()
        let resolvedEvents = LockedEvents()
        let connection = Self.makeApprovalConnection(
            sendLine: { _ in },
            onInteractivePrompt: { promptEnvelopes.append($0) },
            onInteractivePromptResolved: { resolvedEvents.append($0) })

        connection.receiveLine(Self.commandApprovalLine)
        // Same id, different item.
        connection.receiveLine("""
        {"id":"approval-1","method":"item/commandExecution/requestApproval","params":{"threadId":"thread-1","turnId":"turn-1","itemId":"item-OTHER","startedAtMs":1786000000000,"command":"ls"}}
        """)
        XCTAssertEqual(connection.pendingApprovalPromptEvents().count, 1,
                       "only the latest request owning the id may be pending")

        // Same id, different method.
        connection.receiveLine("""
        {"id":"approval-1","method":"item/fileChange/requestApproval","params":{"threadId":"thread-1","turnId":"turn-1","itemId":"item-F","startedAtMs":1786000000000,"reason":"write"}}
        """)
        let pending = connection.pendingApprovalPromptEvents()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.metadata?["source"], "codex_file_change_approval")
    }

    func testNewConnectionMayReuseSamePoisonedRequestID() throws {
        func makePoisonedConnection() -> (CodexAppServerConnection, LineSink) {
            let outbound = LineSink()
            var envelopes = [CodexAppServerInteractivePromptEnvelope]()
            let connection = Self.makeApprovalConnection(
                sendLine: { outbound.append($0) },
                onInteractivePrompt: { envelopes.append($0) })
            connection.receiveLine(Self.commandApprovalLine)
            _ = try? connection.submitApproval(promptID: envelopes[0].prompt.promptID,
                                               targetIndex: 0,
                                               clientRequestID: "client-1",
                                               lifecycleToken: envelopes[0].event.eventID)
            connection.receiveLine(Self.changedPayloadLine)  // poisons approval-1
            return (connection, outbound)
        }
        _ = makePoisonedConnection()

        // A fresh connection (new generation) may use the same JSON-RPC id.
        var freshEnvelopes = [CodexAppServerInteractivePromptEnvelope]()
        let freshConnection = Self.makeApprovalConnection(
            sendLine: { _ in },
            onInteractivePrompt: { freshEnvelopes.append($0) })
        freshConnection.receiveLine(Self.commandApprovalLine)
        XCTAssertEqual(freshEnvelopes.count, 1, "poison scope must not leak across connections")
    }

    func testCloseFlagSetButStoreNotRetiredCannotYieldTerminalThenPending() throws {
        // Window: close() set `closed=true` but has not yet retired the
        // store. A lifecycle terminal and a redelivery both land in that
        // window. Allowed outcome: existing pending -> its single terminal.
        // Never terminal -> pending -> terminal; no new prompt on a closed
        // connection.
        let order = LockedStrings()
        let connection = Self.makeApprovalConnection(
            sendLine: { _ in },
            onInteractivePrompt: { order.append("prompt:\($0.prompt.promptID)") },
            onInteractivePromptResolved: { order.append("resolved:\($0.metadata?["reason"] ?? "?")") })

        connection.receiveLine(Self.commandApprovalLine)
        XCTAssertEqual(order.snapshot().count, 1)

        let arrivals = DispatchSemaphore(value: 0)
        let awaiting = LatchFlag()
        connection.publicationBarrierHook = {
            if awaiting.isSet() {
                arrivals.signal()
            }
        }
        let terminalDone = expectation(description: "terminal competitor done")
        let redeliveryDone = expectation(description: "redelivery competitor done")
        connection.publicationInteriorHook = { [weak connection] point in
            guard point == "closed-preretire" else { return }
            connection?.publicationInteriorHook = nil
            awaiting.set()
            DispatchQueue.global(qos: .userInitiated).async {
                connection?.receiveLine("""
                {"method":"serverRequest/resolved","params":{"threadId":"thread-1","requestId":"approval-1"}}
                """)
                terminalDone.fulfill()
            }
            DispatchQueue.global(qos: .userInitiated).async {
                connection?.receiveLine(Self.commandApprovalLine)
                redeliveryDone.fulfill()
            }
            // Both competitors must have ARRIVED at the publication barrier
            // (and here they fully complete) before close resumes its retire.
            XCTAssertEqual(arrivals.wait(timeout: .now() + 2.0), .success)
            XCTAssertEqual(arrivals.wait(timeout: .now() + 2.0), .success)
        }
        connection.close()
        wait(for: [terminalDone, redeliveryDone], timeout: 2.0)

        let snapshot = order.snapshot()
        XCTAssertEqual(snapshot.count, 2,
                       "only pending -> single terminal is allowed, got \(snapshot)")
        XCTAssertTrue(snapshot[0].hasPrefix("prompt:"))
        XCTAssertEqual(snapshot[1], "resolved:server_resolved")
        XCTAssertTrue(connection.pendingApprovalPromptEvents().isEmpty,
                      "a closed connection must not hold a pending prompt")
    }

    func testClosedConnectionRejectsMalformedAndUnsupportedRequestsWithoutLifecycleSideEffects() throws {
        // Window: closed=true is set but the store retire has not run. A
        // malformed approval and an unsupported request (both reusing the
        // ACTIVE RequestId) land in that window. Neither may claim the
        // ledger, terminalize the active lifecycle, publish, or write any
        // frame — the only terminal is close's own `expired`.
        let outbound = LineSink()
        let order = LockedStrings()
        var protocolViolations = 0
        let connection = CodexAppServerConnection(
            sendLine: { outbound.append($0) },
            approvalContext: CodexAppServerApprovalContext(workspaceID: "workspace-1",
                                                           panelID: "panel-1",
                                                           sessionID: "session-1",
                                                           epoch: "pid:1|sock:/tmp/a.sock"),
            timestampProvider: { "2026-07-15T12:00:00.000Z" },
            onInteractivePrompt: { order.append("prompt:\($0.prompt.promptID)") },
            onInteractivePromptResolved: { order.append("resolved:\($0.metadata?["reason"] ?? "?")") },
            onProtocolViolation: { protocolViolations += 1 })

        connection.receiveLine(Self.commandApprovalLine)
        XCTAssertEqual(order.snapshot().count, 1)
        let framesBeforeClose = outbound.lines().count

        // Both workers must COMPLETE inside the closed-preretire window —
        // close only proceeds to its retire after their full return, so the
        // pre-retire gate itself (not the retire) is what blocked them.
        let malformedReturned = DispatchSemaphore(value: 0)
        let unsupportedReturned = DispatchSemaphore(value: 0)
        connection.publicationInteriorHook = { [weak connection] point in
            guard point == "closed-preretire" else { return }
            connection?.publicationInteriorHook = nil
            DispatchQueue.global(qos: .userInitiated).async {
                connection?.receiveLine("""
                {"id":"approval-1","method":"item/commandExecution/requestApproval","params":{"threadId":"thread-1","turnId":"turn-1","itemId":"item-1","command":"ls"}}
                """)
                malformedReturned.signal()
            }
            DispatchQueue.global(qos: .userInitiated).async {
                connection?.receiveLine("""
                {"id":"approval-1","method":"totally/unknownMethod","params":{"foo":"bar"}}
                """)
                unsupportedReturned.signal()
            }
            XCTAssertEqual(malformedReturned.wait(timeout: .now() + 2.0), .success,
                           "the malformed request must fully return before close retires")
            XCTAssertEqual(unsupportedReturned.wait(timeout: .now() + 2.0), .success,
                           "the unsupported request must fully return before close retires")
        }
        connection.close()

        let snapshot = order.snapshot()
        XCTAssertEqual(snapshot.count, 2, "the only terminal is close's expired, got \(snapshot)")
        XCTAssertEqual(snapshot.last, "resolved:expired")
        XCTAssertFalse(snapshot.contains { $0.contains("superseded") },
                       "closed input must not rewrite the lifecycle as superseded")
        XCTAssertEqual(outbound.lines().count, framesBeforeClose,
                       "no error bytes may be written after close")
        XCTAssertEqual(protocolViolations, 0)
        XCTAssertTrue(connection.pendingApprovalPromptEvents().isEmpty)
    }

    func testCloseRetiresApprovalsBeforeInvokingPendingResponseHandlers() throws {
        var promptEnvelopes = [CodexAppServerInteractivePromptEnvelope]()
        let resolvedEvents = LockedEvents()
        let handlerEntered = expectation(description: "pending handler entered")
        let releaseHandler = DispatchSemaphore(value: 0)
        let connection = Self.makeApprovalConnection(
            sendLine: { _ in },
            onInteractivePrompt: { promptEnvelopes.append($0) },
            onInteractivePromptResolved: { resolvedEvents.append($0) })

        connection.receiveLine(Self.commandApprovalLine)
        // A pending client request whose handler blocks during close.
        try connection.sendClientRequest(method: "thread/loaded/list") { _ in
            handlerEntered.fulfill()
            _ = releaseHandler.wait(timeout: .now() + 3.0)
        }

        let closeReturned = expectation(description: "close returned")
        DispatchQueue.global(qos: .userInitiated).async {
            connection.close()
            closeReturned.fulfill()
        }
        wait(for: [handlerEntered], timeout: 2.0)

        // The store must ALREADY be retired before arbitrary handlers run:
        // the expired terminal exists and a racing redelivery cannot create a
        // pending prompt (no terminal -> pending).
        XCTAssertEqual(resolvedEvents.snapshot().map { $0.metadata?["reason"] }, ["expired"])
        connection.receiveLine(Self.commandApprovalLine)
        XCTAssertEqual(promptEnvelopes.count, 1, "closed connection must not admit new prompts")
        XCTAssertTrue(connection.pendingApprovalPromptEvents().isEmpty)

        releaseHandler.signal()
        wait(for: [closeReturned], timeout: 2.0)
    }

    func testStaleCardTokenAfterChangedPayloadRegisterIsConflictWithZeroResponseBytes() throws {
        // Barrier interleaving: the old card's submit has ENTERED the submit
        // path, then the changed-payload redelivery registers (new lifecycle,
        // new token), then the old submit proceeds. The stale token must be a
        // conflict with zero response bytes — never a response for B.
        let outbound = LineSink()
        var promptEnvelopes = [CodexAppServerInteractivePromptEnvelope]()
        let resolvedEvents = LockedEvents()
        let connection = Self.makeApprovalConnection(
            sendLine: { outbound.append($0) },
            onInteractivePrompt: { promptEnvelopes.append($0) },
            onInteractivePromptResolved: { resolvedEvents.append($0) })

        connection.receiveLine(Self.commandApprovalLine)
        let staleToken = promptEnvelopes[0].event.eventID
        XCTAssertEqual(promptEnvelopes[0].event.payload?.objectValue?["lifecycle_token"]?.stringValue, staleToken,
                       "the published card must carry the server-issued lifecycle capability")

        let submitEntered = DispatchSemaphore(value: 0)
        let releaseSubmit = DispatchSemaphore(value: 0)
        connection.submitAdmissionHook = {
            submitEntered.signal()
            _ = releaseSubmit.wait(timeout: .now() + 3.0)
        }
        var staleOutcome: Result<CodexAppServerApprovalSubmitOutcome, Error>?
        let submitReturned = expectation(description: "stale submit returned")
        DispatchQueue.global(qos: .userInitiated).async {
            staleOutcome = Result { try connection.submitApproval(promptID: promptEnvelopes[0].prompt.promptID,
                                                                  targetIndex: 0,
                                                                  clientRequestID: "client-stale",
                                                                  lifecycleToken: staleToken) }
            submitReturned.fulfill()
        }
        XCTAssertEqual(submitEntered.wait(timeout: .now() + 2.0), .success)

        // Changed payload registers while the stale submit is paused: the
        // lifecycle is superseded and a NEW capability token is issued.
        connection.submitAdmissionHook = nil
        connection.receiveLine(Self.changedPayloadLine)
        XCTAssertEqual(promptEnvelopes.count, 2)
        let freshToken = promptEnvelopes[1].event.eventID
        XCTAssertNotEqual(freshToken, staleToken, "a changed payload must rotate the lifecycle token")

        releaseSubmit.signal()
        wait(for: [submitReturned], timeout: 2.0)
        guard case .failure(let error)? = staleOutcome,
              case BridgeInternalError.conflict = error else {
            return XCTFail("stale token must conflict, got \(String(describing: staleOutcome))")
        }
        XCTAssertTrue(outbound.lines().isEmpty, "a stale-token submit must put zero response bytes on the wire")

        // The fresh card decides the new lifecycle normally.
        guard case .pendingConfirmation = try connection.submitApproval(promptID: promptEnvelopes[1].prompt.promptID,
                                                                        targetIndex: 0,
                                                                        clientRequestID: "client-fresh",
                                                                        lifecycleToken: freshToken) else {
            return XCTFail("expected pendingConfirmation for the fresh token")
        }
        XCTAssertEqual(outbound.lines().count, 1)
    }

    func testLifecycleTokenStableForPendingSnapshotAndRotatedByTrueRedelivery() throws {
        let outbound = LineSink()
        var promptEnvelopes = [CodexAppServerInteractivePromptEnvelope]()
        let connection = Self.makeApprovalConnection(
            sendLine: { outbound.append($0) },
            onInteractivePrompt: { promptEnvelopes.append($0) })

        connection.receiveLine(Self.commandApprovalLine)
        let originalToken = promptEnvelopes[0].event.eventID

        // Recovery/pending snapshots are the SAME delivery: identical
        // identity and token, so an in-flight card stays valid.
        let snapshot = try XCTUnwrap(connection.pendingApprovalPromptEvents().first)
        XCTAssertEqual(snapshot.eventID, originalToken)
        XCTAssertEqual(snapshot.payload?.objectValue?["lifecycle_token"]?.stringValue, originalToken)

        // A true redelivery (server re-asked) is a NEW delivery: the token
        // rotates and the pre-redelivery card can no longer decide it.
        connection.receiveLine(Self.commandApprovalLine)
        XCTAssertEqual(promptEnvelopes.count, 2)
        let rotatedToken = promptEnvelopes[1].event.eventID
        XCTAssertNotEqual(rotatedToken, originalToken)
        XCTAssertThrowsError(try connection.submitApproval(promptID: promptEnvelopes[1].prompt.promptID,
                                                           targetIndex: 0,
                                                           clientRequestID: "client-old",
                                                           lifecycleToken: originalToken)) { error in
            guard case BridgeInternalError.conflict = error else {
                return XCTFail("expected conflict, got \(error)")
            }
        }
        XCTAssertTrue(outbound.lines().isEmpty)
        guard case .pendingConfirmation = try connection.submitApproval(promptID: promptEnvelopes[1].prompt.promptID,
                                                                        targetIndex: 0,
                                                                        clientRequestID: "client-new",
                                                                        lifecycleToken: rotatedToken) else {
            return XCTFail("expected pendingConfirmation for the rotated token")
        }
        XCTAssertEqual(outbound.lines().count, 1)
    }

    func testResolvedAndExpiredEventsCarryLifecycleTokenOfTerminatedDelivery() throws {
        // Terminal events must identify WHICH delivery they terminate: the
        // same lifecycle token the prompt event carried, not just the logical
        // promptID (which survives redeliveries).
        var promptEnvelopes = [CodexAppServerInteractivePromptEnvelope]()
        let resolvedEvents = LockedEvents()
        let connection = Self.makeApprovalConnection(
            sendLine: { _ in },
            onInteractivePrompt: { promptEnvelopes.append($0) },
            onInteractivePromptResolved: { resolvedEvents.append($0) })

        connection.receiveLine(Self.commandApprovalLine)
        let token = promptEnvelopes[0].event.eventID
        connection.receiveLine("""
        {"method":"serverRequest/resolved","params":{"threadId":"thread-1","requestId":"approval-1"}}
        """)
        let resolved = try XCTUnwrap(resolvedEvents.snapshot().first)
        XCTAssertEqual(resolved.metadata?["lifecycle_token"], token)
        XCTAssertEqual(resolved.payload?.objectValue?["lifecycle_token"]?.stringValue, token)

        // Expired terminals too (close path), for the re-armed delivery.
        connection.receiveLine(Self.commandApprovalLine)
        let rearmedToken = promptEnvelopes[1].event.eventID
        XCTAssertNotEqual(rearmedToken, token)
        connection.close()
        let expired = try XCTUnwrap(resolvedEvents.snapshot().last)
        XCTAssertEqual(expired.metadata?["reason"], "expired")
        XCTAssertEqual(expired.metadata?["lifecycle_token"], rearmedToken)
    }

    // MARK: publication-lock latch proofs
    //
    // Each test proves the competitor genuinely ARRIVED at the serialization
    // point (publicationBarrierHook latch) while the first party is paused at
    // a named interior point — sequential scheduling cannot fake the pass.

    private final class LatchFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.lock(); value = true; lock.unlock() }
        func isSet() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
    }

    func testCloseArrivingBeforePromptPublicationYieldsPendingThenTerminal() throws {
        // Gap: without the shared publication lock, close could retire the
        // store between register and the prompt-event publication, producing
        // a published prompt AFTER its generation terminal.
        let order = LockedStrings()
        let connection = Self.makeApprovalConnection(
            sendLine: { _ in },
            onInteractivePrompt: { order.append("prompt:\($0.prompt.promptID)") },
            onInteractivePromptResolved: { order.append("resolved:\($0.metadata?["reason"] ?? "?")") })

        let closeArrived = DispatchSemaphore(value: 0)
        let closeReturned = expectation(description: "close returned")
        let awaitingClose = LatchFlag()
        connection.publicationBarrierHook = {
            if awaitingClose.isSet() {
                closeArrived.signal()
            }
        }
        connection.publicationInteriorHook = { [weak connection] point in
            guard point == "registered" else { return }
            connection?.publicationInteriorHook = nil
            awaitingClose.set()
            DispatchQueue.global(qos: .userInitiated).async {
                connection?.close()
                closeReturned.fulfill()
            }
            XCTAssertEqual(closeArrived.wait(timeout: .now() + 2.0), .success,
                           "close must have arrived at the serialization point before publication resumes")
        }

        connection.receiveLine(Self.commandApprovalLine)
        wait(for: [closeReturned], timeout: 2.0)
        XCTAssertEqual(order.snapshot().count, 2)
        XCTAssertTrue(order.snapshot()[0].hasPrefix("prompt:"), "pending must publish before its terminal, got \(order.snapshot())")
        XCTAssertEqual(order.snapshot()[1], "resolved:expired")
        XCTAssertTrue(connection.pendingApprovalPromptEvents().isEmpty)
    }

    func testCloseArrivingBetweenRecordAndPromptCallbackYieldsPendingThenTerminal() throws {
        // Gap: close landing after the event is recorded but before the
        // prompt callback runs must still observe strict pending -> terminal
        // ordering for downstream consumers.
        let order = LockedStrings()
        let connection = Self.makeApprovalConnection(
            sendLine: { _ in },
            onInteractivePrompt: { order.append("prompt:\($0.prompt.promptID)") },
            onInteractivePromptResolved: { order.append("resolved:\($0.metadata?["reason"] ?? "?")") })

        let closeArrived = DispatchSemaphore(value: 0)
        let closeReturned = expectation(description: "close returned")
        let awaitingClose = LatchFlag()
        connection.publicationBarrierHook = {
            if awaitingClose.isSet() {
                closeArrived.signal()
            }
        }
        connection.publicationInteriorHook = { [weak connection] point in
            guard point == "recorded" else { return }
            connection?.publicationInteriorHook = nil
            awaitingClose.set()
            DispatchQueue.global(qos: .userInitiated).async {
                connection?.close()
                closeReturned.fulfill()
            }
            XCTAssertEqual(closeArrived.wait(timeout: .now() + 2.0), .success,
                           "close must have arrived at the serialization point before the prompt callback runs")
        }

        connection.receiveLine(Self.commandApprovalLine)
        wait(for: [closeReturned], timeout: 2.0)
        XCTAssertEqual(order.snapshot().count, 2)
        XCTAssertTrue(order.snapshot()[0].hasPrefix("prompt:"))
        XCTAssertEqual(order.snapshot()[1], "resolved:expired")
    }

    func testAdmissionArrivingDuringRetireIsRejectedAfterTerminalPublication() throws {
        // Gap: an admission racing the retire pass must not slot in between
        // "store retired" and "terminals published" — retire-first means the
        // late admission is rejected and NO pending state exists afterwards.
        let order = LockedStrings()
        let connection = Self.makeApprovalConnection(
            sendLine: { _ in },
            onInteractivePrompt: { order.append("prompt:\($0.prompt.promptID)") },
            onInteractivePromptResolved: { order.append("resolved:\($0.metadata?["reason"] ?? "?")") })

        connection.receiveLine(Self.commandApprovalLine)
        XCTAssertEqual(order.snapshot().count, 1)

        let admissionArrived = DispatchSemaphore(value: 0)
        let admissionReturned = expectation(description: "admission returned")
        let awaitingAdmission = LatchFlag()
        connection.publicationBarrierHook = {
            if awaitingAdmission.isSet() {
                admissionArrived.signal()
            }
        }
        connection.publicationInteriorHook = { [weak connection] point in
            guard point == "retired" else { return }
            connection?.publicationInteriorHook = nil
            awaitingAdmission.set()
            DispatchQueue.global(qos: .userInitiated).async {
                connection?.receiveLine(Self.commandApprovalLine)
                admissionReturned.fulfill()
            }
            XCTAssertEqual(admissionArrived.wait(timeout: .now() + 2.0), .success,
                           "the racing admission must have arrived at the serialization point mid-retire")
        }

        connection.close()
        wait(for: [admissionReturned], timeout: 2.0)
        let snapshot = order.snapshot()
        XCTAssertEqual(snapshot.count, 2, "retire-first: the racing admission publishes nothing, got \(snapshot)")
        XCTAssertTrue(snapshot[0].hasPrefix("prompt:"))
        XCTAssertEqual(snapshot[1], "resolved:expired")
        XCTAssertTrue(connection.pendingApprovalPromptEvents().isEmpty)
    }

    private static func object(from line: String,
                               file: StaticString = #filePath,
                               line sourceLine: UInt = #line) throws -> [String: JSONValue] {
        let data = try XCTUnwrap(line.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
                                 file: file,
                                 line: sourceLine)
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        return try XCTUnwrap(value.objectValue, file: file, line: sourceLine)
    }
}

private final class LineSink: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func append(_ line: String) {
        lock.lock()
        storage.append(line)
        lock.unlock()
    }

    func lines() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private final class LockedStrings: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func append(_ value: String) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }

    func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private final class LockedEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [AgentEvent] = []

    func append(_ event: AgentEvent) {
        lock.lock()
        storage.append(event)
        lock.unlock()
    }

    func snapshot() -> [AgentEvent] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func set(_ newValue: Bool) {
        lock.lock()
        storage = newValue
        lock.unlock()
    }
}

private final class LockedStringSet: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Set<String>()

    func insert(_ value: String) {
        lock.lock()
        storage.insert(value)
        lock.unlock()
    }

    func values() -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func waitForCount(_ count: Int, timeout: TimeInterval = 2.0) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if values().count == count {
                return true
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return values().count == count
    }
}
