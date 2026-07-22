import Foundation
import XCTest
@testable import RemoteBridge

final class CodexAppServerConnectionRequestModelTests: XCTestCase {
    func testStringAndInt64RequestIDsRoundTripExactly() throws {
        let sink = RequestModelLineSink()
        var prompts: [CodexAppServerInteractivePromptEnvelope] = []
        let connection = Self.connection(sink: sink,
                                         epoch: "epoch-a",
                                         onPrompt: { prompts.append($0) })

        connection.receiveLine(Self.commandLine(id: #""1""#, itemID: "item-string"))
        connection.receiveLine(Self.commandLine(id: "1", itemID: "item-integer"))
        connection.receiveLine(Self.commandLine(id: "9223372036854775807", itemID: "item-max"))

        XCTAssertEqual(prompts.count, 3)
        XCTAssertEqual(Set(prompts.map(\.prompt.promptID)).count, 3)
        XCTAssertEqual(prompts.map(\.request.requestID), [
            .string("1"),
            .integer(1),
            .integer(Int64.max),
        ])

        for prompt in prompts {
            _ = try connection.submitApproval(promptID: prompt.prompt.promptID, targetIndex: 0)
        }

        let lines = sink.lines()
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines[0].hasPrefix(#"{"id":"1","result":"#))
        XCTAssertTrue(lines[1].hasPrefix(#"{"id":1,"result":"#))
        XCTAssertTrue(lines[2].hasPrefix(#"{"id":9223372036854775807,"result":"#),
                      "int64 response id must not pass through Double: \(lines[2])")
    }

    func testRequestUserInputPublishesStructuredPromptAndSubmitsAnswers() throws {
        let sink = RequestModelLineSink()
        var envelope: CodexAppServerInteractivePromptEnvelope?
        var resolved: AgentEvent?
        let connection = Self.connection(sink: sink,
                                         epoch: "epoch-questions",
                                         onPrompt: { envelope = $0 },
                                         onResolved: { resolved = $0 })

        connection.receiveLine(#"{"id":"ask-17","method":"item/tool/requestUserInput","params":{"threadId":"thread-1","turnId":"turn-1","itemId":"item-ask","questions":[{"id":"format","header":"Output","question":"Which format?","options":[{"label":"PNG","description":"Lossless"},{"label":"JPEG","description":"Compact"}]},{"id":"notes","header":"Notes","question":"Anything else?","isOther":true,"options":null}]}}"#)

        let promptEnvelope = try XCTUnwrap(envelope)
        XCTAssertEqual(promptEnvelope.request.method, .requestUserInput)
        XCTAssertEqual(promptEnvelope.prompt.source, "codex_user_input_request")
        XCTAssertEqual(promptEnvelope.prompt.questions?.arrayValue?.count, 2)
        XCTAssertEqual(promptEnvelope.prompt.promptID,
                       promptEnvelope.request.promptID(epoch: "epoch-questions"))

        let event = try connection.submitUserInput(promptID: promptEnvelope.prompt.promptID,
                                                   answers: ["format": ["PNG"]])
        XCTAssertEqual(event.type, .interactivePromptResolved)
        XCTAssertEqual(resolved?.eventID, event.eventID)

        let response = try Self.object(from: sink.lines()[0])
        XCTAssertEqual(response["id"]?.stringValue, "ask-17")
        let answers = try XCTUnwrap(response["result"]?.objectValue?["answers"]?.objectValue)
        XCTAssertEqual(answers["format"]?.objectValue?["answers"]?.arrayValue,
                       [.string("PNG")])
        XCTAssertEqual(answers["notes"]?.objectValue?["answers"]?.arrayValue, [])
    }

    func testPermissionsRequestPublishesAndSubmitsSchemaResponse() throws {
        let sink = RequestModelLineSink()
        var envelope: CodexAppServerInteractivePromptEnvelope?
        let connection = Self.connection(sink: sink,
                                         epoch: "epoch-permissions",
                                         onPrompt: { envelope = $0 })

        connection.receiveLine(#"{"id":"perm-1","method":"item/permissions/requestApproval","params":{"threadId":"thread-1","turnId":"turn-1","itemId":"item-perm","startedAtMs":1786000000000,"cwd":"/tmp/project","reason":"Needs network.","permissions":{"network":{"enabled":true}}}}"#)

        let promptEnvelope = try XCTUnwrap(envelope)
        XCTAssertEqual(promptEnvelope.request.method, .permissions)
        XCTAssertEqual(promptEnvelope.prompt.source, "codex_permissions_approval")
        XCTAssertEqual(promptEnvelope.prompt.promptID,
                       promptEnvelope.request.promptID(epoch: "epoch-permissions"))
        XCTAssertTrue(promptEnvelope.prompt.body.contains("Network: allow outbound network access"))

        _ = try connection.submitApproval(promptID: promptEnvelope.prompt.promptID,
                                          targetIndex: 1)
        let response = try Self.object(from: sink.lines()[0])
        XCTAssertEqual(response["id"]?.stringValue, "perm-1")
        let result = try XCTUnwrap(response["result"]?.objectValue)
        XCTAssertEqual(result["scope"]?.stringValue, "session")
        XCTAssertEqual(result["permissions"]?.objectValue?["network"]?
            .objectValue?["enabled"]?.boolValue, true)
        XCTAssertNil(result["decision"])
    }

    func testNewMethodsUseInvalidParamsWhileUnknownMethodUsesMethodNotFound() throws {
        let sink = RequestModelLineSink()
        let connection = CodexAppServerConnection(sendLine: { sink.append($0) })

        connection.receiveLine(#"{"id":"ask-invalid","method":"item/tool/requestUserInput","params":{"threadId":"thread-1","turnId":"turn-1","itemId":"item-1"}}"#)
        connection.receiveLine(#"{"id":9223372036854775807,"method":"item/permissions/requestApproval","params":{"threadId":"thread-1","turnId":"turn-1","itemId":"item-2","startedAtMs":1786000000000,"permissions":{}}}"#)
        connection.receiveLine(#"{"id":"unknown","method":"item/tool/somethingUnknown","params":{}}"#)

        let responses = try sink.lines().map(Self.object(from:))
        XCTAssertEqual(responses.count, 3)
        XCTAssertEqual(responses[0]["error"]?.objectValue?["code"]?.intValue, -32602)
        XCTAssertEqual(responses[1]["error"]?.objectValue?["code"]?.intValue, -32602)
        XCTAssertTrue(sink.lines()[1].hasPrefix(#"{"id":9223372036854775807,"error":"#))
        XCTAssertEqual(responses[2]["error"]?.objectValue?["code"]?.intValue, -32601)
    }

    func testEpochPromptIdentityIsTheSameIdentityStoredForSubmit() throws {
        let firstSink = RequestModelLineSink()
        let secondSink = RequestModelLineSink()
        let legacySink = RequestModelLineSink()
        var firstPrompt: CodexAppServerInteractivePromptEnvelope?
        var secondPrompt: CodexAppServerInteractivePromptEnvelope?
        var legacyPrompt: CodexAppServerInteractivePromptEnvelope?
        let first = Self.connection(sink: firstSink,
                                    epoch: "pid:100|sock:/tmp/a.sock",
                                    onPrompt: { firstPrompt = $0 })
        let second = Self.connection(sink: secondSink,
                                     epoch: "pid:200|sock:/tmp/a.sock",
                                     onPrompt: { secondPrompt = $0 })
        let legacy = CodexAppServerConnection(
            sendLine: { legacySink.append($0) },
            approvalContext: CodexAppServerApprovalContext(workspaceID: "workspace-1",
                                                           panelID: "panel-1",
                                                           sessionID: "session-1"),
            onInteractivePrompt: { legacyPrompt = $0 })
        let line = Self.commandLine(id: #""approval-1""#, itemID: "item-1")

        first.receiveLine(line)
        second.receiveLine(line)
        legacy.receiveLine(line)

        let firstEnvelope = try XCTUnwrap(firstPrompt)
        let secondEnvelope = try XCTUnwrap(secondPrompt)
        XCTAssertNotEqual(firstEnvelope.prompt.promptID, secondEnvelope.prompt.promptID)
        let legacyEnvelope = try XCTUnwrap(legacyPrompt)
        XCTAssertEqual(legacyEnvelope.prompt.promptID, legacyEnvelope.request.promptID,
                       "an omitted epoch must retain the legacy prompt identity")
        XCTAssertEqual(first.pendingApprovalPromptEvents().first?.metadata?["prompt_id"],
                       firstEnvelope.prompt.promptID)
        XCTAssertEqual(second.pendingApprovalPromptEvents().first?.metadata?["prompt_id"],
                       secondEnvelope.prompt.promptID)

        XCTAssertNoThrow(try first.submitApproval(promptID: firstEnvelope.prompt.promptID,
                                                  targetIndex: 0))
        XCTAssertNoThrow(try second.submitApproval(promptID: secondEnvelope.prompt.promptID,
                                                   targetIndex: 0))
        XCTAssertEqual(firstSink.lines().count, 1)
        XCTAssertEqual(secondSink.lines().count, 1)
    }

    private static func connection(
        sink: RequestModelLineSink,
        epoch: String,
        onPrompt: @escaping (CodexAppServerInteractivePromptEnvelope) -> Void,
        onResolved: @escaping (AgentEvent) -> Void = { _ in }
    ) -> CodexAppServerConnection {
        CodexAppServerConnection(
            sendLine: { sink.append($0) },
            approvalContext: CodexAppServerApprovalContext(workspaceID: "workspace-1",
                                                           panelID: "panel-1",
                                                           sessionID: "session-1",
                                                           epoch: epoch),
            timestampProvider: { "2026-07-22T00:00:00.000Z" },
            onInteractivePrompt: onPrompt,
            onInteractivePromptResolved: onResolved)
    }

    private static func commandLine(id: String, itemID: String) -> String {
        """
        {"id":\(id),"method":"item/commandExecution/requestApproval","params":{"threadId":"thread-1","turnId":"turn-1","itemId":"\(itemID)","startedAtMs":1786000000000,"command":"ls"}}
        """
    }

    private static func object(from line: String) throws -> [String: JSONValue] {
        let data = try XCTUnwrap(line.trimmingCharacters(in: .whitespacesAndNewlines)
            .data(using: .utf8))
        return try XCTUnwrap(JSONDecoder().decode(JSONValue.self, from: data).objectValue)
    }
}

private final class RequestModelLineSink: @unchecked Sendable {
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
