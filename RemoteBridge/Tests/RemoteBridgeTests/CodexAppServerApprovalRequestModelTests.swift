import Foundation
import XCTest
@testable import RemoteBridge

final class CodexAppServerApprovalRequestModelTests: XCTestCase {
    func testTypedRequestIDsRemainDistinctAndPreserveExactJSONTokens() throws {
        XCTAssertNotEqual(CodexAppServerRequestID.string("1").storageKey,
                          CodexAppServerRequestID.integer(1).storageKey)
        XCTAssertEqual(CodexAppServerRequestID.string("1").jsonToken, #""1""#)
        XCTAssertEqual(CodexAppServerRequestID.integer(1).jsonToken, "1")
        XCTAssertEqual(CodexAppServerRequestID.integer(Int64.max).jsonToken,
                       "9223372036854775807")

        XCTAssertEqual(CodexAppServerRequestID(rawJSONObjectValue: "1"), .string("1"))
        XCTAssertEqual(CodexAppServerRequestID(rawJSONObjectValue: NSNumber(value: Int64.max)),
                       .integer(Int64.max))
        XCTAssertNil(CodexAppServerRequestID(rawJSONObjectValue: true))
        XCTAssertNil(CodexAppServerRequestID(rawJSONObjectValue: NSNumber(value: 1.5)))
        XCTAssertNil(CodexAppServerRequestID(rawJSONObjectValue: NSNumber(value: UInt64.max)))

        let stringRequest = try XCTUnwrap(Self.commandRequest(requestID: .string("1")))
        let integerRequest = try XCTUnwrap(Self.commandRequest(requestID: .integer(1)))
        XCTAssertNotEqual(stringRequest.promptID(epoch: "epoch-a"),
                          integerRequest.promptID(epoch: "epoch-a"))
    }

    func testPromptIdentityIsStableWithinEpochAndChangesAcrossEpochs() throws {
        let request = try XCTUnwrap(Self.commandRequest(requestID: .integer(7)))

        XCTAssertEqual(request.promptID(epoch: "pid:100|sock:/tmp/a.sock"),
                       request.promptID(epoch: "pid:100|sock:/tmp/a.sock"))
        XCTAssertNotEqual(request.promptID(epoch: "pid:100|sock:/tmp/a.sock"),
                          request.promptID(epoch: "pid:200|sock:/tmp/a.sock"))
        XCTAssertEqual(request.makePrompt(epoch: "pid:100|sock:/tmp/a.sock").promptID,
                       request.promptID(epoch: "pid:100|sock:/tmp/a.sock"))

        let legacy = try XCTUnwrap(CodexAppServerApprovalRequest(
            method: "item/commandExecution/requestApproval",
            requestID: JSONValue.string("req-1"),
            params: Self.baseParams()))
        XCTAssertEqual(legacy.makePrompt().promptID, legacy.promptID,
                       "the compatibility path must retain its pre-epoch identity")
    }

    func testStrictCommandAndFileSchemasRequireStartedAt() {
        for method in [
            "item/commandExecution/requestApproval",
            "item/fileChange/requestApproval",
        ] {
            var params = Self.baseParams()
            params.removeValue(forKey: "startedAtMs")
            XCTAssertNil(Self.request(method: method, params: params), method)
        }
    }

    func testRequestUserInputSchemaRendersStructuredQuestions() throws {
        let request = try XCTUnwrap(Self.request(
            method: "item/tool/requestUserInput",
            params: Self.userInputParams(questions: .array([
                Self.question(id: "format",
                              header: "Output",
                              question: "Which format?",
                              options: [
                                ("PNG", "Lossless image"),
                                ("JPEG", "Smaller file"),
                              ]),
                Self.question(id: "notes",
                              header: "Notes",
                              question: "Anything else?",
                              isOther: true,
                              isSecret: true,
                              options: nil),
            ]))))

        XCTAssertEqual(request.userInputQuestions.count, 2)
        XCTAssertEqual(request.startedAtMs, 0)

        let prompt = request.makePrompt(epoch: "epoch-a")
        XCTAssertEqual(prompt.source, "codex_user_input_request")
        XCTAssertEqual(prompt.title, "Output")
        XCTAssertTrue(prompt.body.contains("Which format?"))
        XCTAssertTrue(prompt.body.contains("- PNG: Lossless image"))
        XCTAssertTrue(prompt.body.contains("Anything else?"))
        XCTAssertTrue(prompt.options.isEmpty,
                      "multi-question requests must use the answers-map submit path")

        let questions = try XCTUnwrap(prompt.questions?.arrayValue)
        XCTAssertEqual(questions.count, 2)
        XCTAssertEqual(questions[0].objectValue?["id"]?.stringValue, "format")
        XCTAssertEqual(questions[0].objectValue?["is_other"]?.boolValue, false)
        XCTAssertEqual(questions[1].objectValue?["is_secret"]?.boolValue, true)
        XCTAssertNil(questions[1].objectValue?["options"])
    }

    func testRequestUserInputSchemaRejectsMalformedQuestions() {
        let malformed: [(String, JSONValue)] = [
            ("empty questions", .array([])),
            ("non-array questions", .string("not-an-array")),
            ("empty id", .array([
                Self.question(id: "", header: "H", question: "Q"),
            ])),
            ("duplicate ids", .array([
                Self.question(id: "q", header: "H1", question: "Q1"),
                Self.question(id: "q", header: "H2", question: "Q2"),
            ])),
            ("missing header", .array([
                .object(["id": .string("q"), "question": .string("Q")]),
            ])),
            ("missing question", .array([
                .object(["id": .string("q"), "header": .string("H")]),
            ])),
            ("wrong isOther type", .array([
                .object([
                    "id": .string("q"),
                    "header": .string("H"),
                    "question": .string("Q"),
                    "isOther": .string("true"),
                ]),
            ])),
            ("wrong isSecret type", .array([
                .object([
                    "id": .string("q"),
                    "header": .string("H"),
                    "question": .string("Q"),
                    "isSecret": .number(1),
                ]),
            ])),
            ("wrong options type", .array([
                .object([
                    "id": .string("q"),
                    "header": .string("H"),
                    "question": .string("Q"),
                    "options": .string("not-an-array"),
                ]),
            ])),
            ("option missing description", .array([
                .object([
                    "id": .string("q"),
                    "header": .string("H"),
                    "question": .string("Q"),
                    "options": .array([.object(["label": .string("A")])]),
                ]),
            ])),
        ]

        for (label, questions) in malformed {
            XCTAssertNil(Self.request(method: "item/tool/requestUserInput",
                                      params: Self.userInputParams(questions: questions)),
                         label)
        }
    }

    func testUserInputResponseIncludesEveryQuestionAndRejectsUnknownIDs() throws {
        let request = try XCTUnwrap(Self.request(
            method: "item/tool/requestUserInput",
            params: Self.userInputParams(questions: .array([
                Self.question(id: "format", header: "Output", question: "Which format?"),
                Self.question(id: "notes", header: "Notes", question: "Anything else?"),
            ]))))

        let response = try request.userInputResponse(answers: ["format": ["PNG"]])
        let answers = try XCTUnwrap(response.objectValue?["answers"]?.objectValue)
        XCTAssertEqual(answers["format"]?.objectValue?["answers"]?.arrayValue,
                       [.string("PNG")])
        XCTAssertEqual(answers["notes"]?.objectValue?["answers"]?.arrayValue, [])
        XCTAssertEqual(Set(answers.keys), ["format", "notes"])

        XCTAssertThrowsError(try request.userInputResponse(answers: ["unknown": ["value"]]))
    }

    func testSingleChoiceUserInputEncodesSelectedLabel() throws {
        let request = try XCTUnwrap(Self.request(
            method: "item/tool/requestUserInput",
            params: Self.userInputParams(questions: .array([
                Self.question(id: "format",
                              header: "Output",
                              question: "Which format?",
                              options: [("PNG", "Lossless"), ("JPEG", "Compact")]),
            ]))))

        let prompt = request.makePrompt(epoch: "epoch-a")
        XCTAssertEqual(prompt.options.map(\.inputSequence), ["PNG", "JPEG"])

        let response = try request.response(targetIndex: 1)
        XCTAssertEqual(response.objectValue?["answers"]?.objectValue?["format"]?
            .objectValue?["answers"]?.arrayValue, [.string("JPEG")])
        XCTAssertThrowsError(try request.response(targetIndex: 2))
    }

    func testPermissionsSchemaRequiresPermissionsStartedAtAndCWD() {
        var params = Self.permissionsParams()
        XCTAssertNotNil(Self.request(method: "item/permissions/requestApproval", params: params))

        for key in ["permissions", "startedAtMs", "cwd"] {
            var missing = params
            missing.removeValue(forKey: key)
            XCTAssertNil(Self.request(method: "item/permissions/requestApproval", params: missing),
                         "missing \(key)")
        }

        params["permissions"] = .string("not-an-object")
        XCTAssertNil(Self.request(method: "item/permissions/requestApproval", params: params))
    }

    func testPermissionsPromptRendersRequestedProfileAndContext() throws {
        let request = try XCTUnwrap(Self.request(
            method: "item/permissions/requestApproval",
            params: Self.permissionsParams()))

        let prompt = request.makePrompt(epoch: "epoch-a")
        XCTAssertEqual(prompt.source, "codex_permissions_approval")
        XCTAssertEqual(prompt.title, "Approve Codex permissions?")
        XCTAssertTrue(prompt.body.contains("Reason: Needs broader filesystem access."))
        XCTAssertTrue(prompt.body.contains("Working directory: /tmp/project"))
        XCTAssertTrue(prompt.body.contains("Environment: env-42"))
        XCTAssertTrue(prompt.body.contains("Network: allow outbound network access"))
        XCTAssertTrue(prompt.body.contains("File system:"))
        XCTAssertTrue(prompt.body.contains("- write /tmp/project"))
        XCTAssertTrue(prompt.body.contains("- read glob **/*.swift"))
        XCTAssertTrue(prompt.body.contains("- deny project_roots/secrets"))
        XCTAssertTrue(prompt.body.contains("- read /tmp/legacy-read"))
        XCTAssertTrue(prompt.body.contains("- write /tmp/legacy-write"))
        XCTAssertEqual(prompt.options.map(\.inputSequence),
                       ["allow_turn", "allow_session", "deny"])
    }

    func testSpecialUnknownPathShowsActualGrantedPath() throws {
        let profile: JSONValue = .object([
            "fileSystem": .object([
                "entries": .array([
                    .object([
                        "access": .string("write"),
                        "path": .object([
                            "type": .string("special"),
                            "value": .object([
                                "kind": .string("unknown"),
                                "path": .string("/Volumes/Backup/secrets"),
                            ]),
                        ]),
                    ]),
                    .object([
                        "access": .string("read"),
                        "path": .object([
                            "type": .string("special"),
                            "value": .object([
                                "kind": .string("unknown"),
                                "path": .string("/opt/data"),
                                "subpath": .string("nested"),
                            ]),
                        ]),
                    ]),
                ]),
            ]),
        ])

        var permissionParams = Self.permissionsParams()
        permissionParams["permissions"] = profile
        let permissionRequest = try XCTUnwrap(Self.request(
            method: "item/permissions/requestApproval",
            params: permissionParams))
        let permissionBody = permissionRequest.makePrompt(epoch: "epoch-a").body
        XCTAssertTrue(permissionBody.contains("- write /Volumes/Backup/secrets"))
        XCTAssertTrue(permissionBody.contains("- read /opt/data/nested"))
        XCTAssertFalse(permissionBody.contains("- write unknown"))

        var commandParams = Self.baseParams()
        commandParams["command"] = .string("backup.sh")
        commandParams["additionalPermissions"] = profile
        let commandRequest = try XCTUnwrap(Self.request(
            method: "item/commandExecution/requestApproval",
            params: commandParams))
        let commandBody = commandRequest.makePrompt(epoch: "epoch-a").body
        XCTAssertTrue(commandBody.contains("- write /Volumes/Backup/secrets"))
        XCTAssertTrue(commandBody.contains("- read /opt/data/nested"))
    }

    func testPermissionsResponsesMatchSchemaAndNeverEscalate() throws {
        let params = Self.permissionsParams()
        let request = try XCTUnwrap(Self.request(
            method: "item/permissions/requestApproval",
            params: params))
        let requested = try XCTUnwrap(params["permissions"])

        let allowTurn = try request.response(targetIndex: 0)
        XCTAssertEqual(allowTurn, .object([
            "permissions": requested,
            "scope": .string("turn"),
        ]))

        let allowSession = try request.response(targetIndex: 1)
        XCTAssertEqual(allowSession, .object([
            "permissions": requested,
            "scope": .string("session"),
        ]))

        let deny = try request.response(targetIndex: 2)
        XCTAssertEqual(deny, .object([
            "permissions": .object([:]),
            "scope": .string("turn"),
        ]))
        XCTAssertThrowsError(try request.response(targetIndex: 3))

        for response in [allowTurn, allowSession, deny] {
            let granted = response.objectValue?["permissions"]
            XCTAssertTrue(granted == requested || granted == .object([:]))
            XCTAssertNil(response.objectValue?["decision"])
        }
    }

    private static func request(method: String,
                                requestID: CodexAppServerRequestID = .string("req-1"),
                                params: [String: JSONValue]) -> CodexAppServerApprovalRequest? {
        CodexAppServerApprovalRequest(method: method,
                                      typedRequestID: requestID,
                                      params: params)
    }

    private static func commandRequest(requestID: CodexAppServerRequestID) -> CodexAppServerApprovalRequest? {
        request(method: "item/commandExecution/requestApproval",
                requestID: requestID,
                params: baseParams())
    }

    private static func baseParams() -> [String: JSONValue] {
        [
            "threadId": .string("thread-1"),
            "turnId": .string("turn-1"),
            "itemId": .string("item-1"),
            "startedAtMs": .number(1_786_000_000_000),
        ]
    }

    private static func userInputParams(questions: JSONValue) -> [String: JSONValue] {
        [
            "threadId": .string("thread-1"),
            "turnId": .string("turn-1"),
            "itemId": .string("item-1"),
            "questions": questions,
        ]
    }

    private static func question(id: String,
                                 header: String,
                                 question: String,
                                 isOther: Bool = false,
                                 isSecret: Bool = false,
                                 options: [(String, String)]? = nil) -> JSONValue {
        var value: [String: JSONValue] = [
            "id": .string(id),
            "header": .string(header),
            "question": .string(question),
            "isOther": .bool(isOther),
            "isSecret": .bool(isSecret),
        ]
        if let options {
            value["options"] = .array(options.map { label, description in
                .object([
                    "label": .string(label),
                    "description": .string(description),
                ])
            })
        }
        return .object(value)
    }

    private static func permissionsParams() -> [String: JSONValue] {
        var params = baseParams()
        params["cwd"] = .string("/tmp/project")
        params["reason"] = .string("Needs broader filesystem access.")
        params["environmentId"] = .string("env-42")
        params["permissions"] = .object([
            "network": .object(["enabled": .bool(true)]),
            "fileSystem": .object([
                "entries": .array([
                    .object([
                        "access": .string("write"),
                        "path": .object([
                            "type": .string("path"),
                            "path": .string("/tmp/project"),
                        ]),
                    ]),
                    .object([
                        "access": .string("read"),
                        "path": .object([
                            "type": .string("glob_pattern"),
                            "pattern": .string("**/*.swift"),
                        ]),
                    ]),
                    .object([
                        "access": .string("deny"),
                        "path": .object([
                            "type": .string("special"),
                            "value": .object([
                                "kind": .string("project_roots"),
                                "subpath": .string("secrets"),
                            ]),
                        ]),
                    ]),
                ]),
                "read": .array([.string("/tmp/legacy-read")]),
                "write": .array([.string("/tmp/legacy-write")]),
            ]),
        ])
        return params
    }
}
