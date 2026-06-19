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

        connection.receiveLine(#"{"id":"server-1","method":"item/tool/requestUserInput","params":{}}"#)

        let response = try Self.object(from: outbound.lines()[0])
        XCTAssertEqual(response["id"]?.stringValue, "server-1")
        let error = response["error"]?.objectValue
        XCTAssertEqual(error?["code"]?.intValue, -32601)
        XCTAssertEqual(error?["message"]?.stringValue, "Unsupported server request: item/tool/requestUserInput")
    }

    func testCommandApprovalRequestPublishesPromptAndSubmitSendsDecisionReply() throws {
        let outbound = LineSink()
        var promptEnvelope: CodexAppServerInteractivePromptEnvelope?
        var resolvedEvent: AgentEvent?
        var nextSeq = 41
        let connection = CodexAppServerConnection(
            sendLine: { outbound.append($0) },
            approvalContext: CodexAppServerApprovalContext(workspaceID: "workspace-1",
                                                           panelID: "panel-1",
                                                           sessionID: "session-1"),
            nextSequence: { _ in
                nextSeq += 1
                return nextSeq
            },
            timestampProvider: { "2026-06-05T12:00:00.000Z" },
            onInteractivePrompt: { promptEnvelope = $0 },
            onInteractivePromptResolved: { resolvedEvent = $0 })

        connection.receiveLine("""
        {"id":"approval-1","method":"item/commandExecution/requestApproval","params":{"threadId":"thread-1","turnId":"turn-1","itemId":"item-1","startedAtMs":1786000000000,"reason":"Needs network.","command":"python3 -c 'print(1)'","cwd":"/Users/timfeng/GitHub/Tidey","proposedExecpolicyAmendment":["python3","-c"]}}
        """)

        let envelope = try XCTUnwrap(promptEnvelope)
        XCTAssertEqual(envelope.prompt.vendor, "codex")
        XCTAssertEqual(envelope.prompt.source, "codex_command_approval")
        XCTAssertEqual(envelope.prompt.title, "Approve Codex command?")
        XCTAssertTrue(envelope.prompt.body.contains("Command: python3 -c 'print(1)'"))
        XCTAssertEqual(envelope.prompt.options.map(\.inputSequence), ["accept", "decline"])
        XCTAssertEqual(envelope.event.type, .interactivePrompt)
        XCTAssertEqual(envelope.event.vendor, "codex")
        XCTAssertEqual(envelope.event.workspaceID, "workspace-1")
        XCTAssertEqual(envelope.event.sessionID, "session-1")
        XCTAssertEqual(envelope.event.metadata?["panel_id"], "panel-1")
        XCTAssertEqual(envelope.event.metadata?["prompt_id"], envelope.prompt.promptID)
        XCTAssertEqual(envelope.event.payload?.objectValue?["prompt_id"]?.stringValue, envelope.prompt.promptID)

        let resolved = try connection.submitApproval(promptID: envelope.prompt.promptID,
                                                     targetIndex: 1)
        XCTAssertEqual(resolved.type, .interactivePromptResolved)
        XCTAssertEqual(resolved.metadata?["reason"], "submit")
        XCTAssertEqual(resolvedEvent?.eventID, resolved.eventID)

        let response = try Self.object(from: outbound.lines()[0])
        XCTAssertEqual(response["id"]?.stringValue, "approval-1")
        XCTAssertEqual(response["result"]?.objectValue?["decision"]?.stringValue, "decline")
    }

    func testFileChangeApprovalRequestPublishesPromptAndSubmitSendsDecisionReply() throws {
        let outbound = LineSink()
        var promptEnvelope: CodexAppServerInteractivePromptEnvelope?
        let connection = CodexAppServerConnection(
            sendLine: { outbound.append($0) },
            approvalContext: CodexAppServerApprovalContext(workspaceID: "workspace-1",
                                                           panelID: "panel-1",
                                                           sessionID: "session-1"),
            onInteractivePrompt: { promptEnvelope = $0 })

        connection.receiveLine("""
        {"id":7,"method":"item/fileChange/requestApproval","params":{"threadId":"thread-1","turnId":"turn-1","itemId":"item-2","startedAtMs":1786000000000,"reason":"Needs write access.","grantRoot":"/Users/timfeng/GitHub/Tidey"}}
        """)

        let envelope = try XCTUnwrap(promptEnvelope)
        XCTAssertEqual(envelope.prompt.source, "codex_file_change_approval")
        XCTAssertTrue(envelope.prompt.body.contains("Grant root: /Users/timfeng/GitHub/Tidey"))

        XCTAssertEqual(envelope.prompt.options.map(\.inputSequence), ["accept", "acceptForSession", "decline"])

        try connection.submitApproval(promptID: envelope.prompt.promptID, targetIndex: 2)
        let response = try Self.object(from: outbound.lines()[0])
        XCTAssertEqual(response["id"]?.intValue, 7)
        XCTAssertEqual(response["result"]?.objectValue?["decision"]?.stringValue, "decline")
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
