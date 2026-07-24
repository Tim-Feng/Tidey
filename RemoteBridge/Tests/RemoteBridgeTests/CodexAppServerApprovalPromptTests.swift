import XCTest
@testable import RemoteBridge

final class CodexAppServerApprovalPromptTests: XCTestCase {
    func testMapsCommandApprovalRequestToInteractivePrompt() throws {
        let request = try XCTUnwrap(CodexAppServerApprovalRequest(
            method: "item/commandExecution/requestApproval",
            requestID: .string("req-1"),
            params: [
                "threadId": .string("thread-1"),
                "turnId": .string("turn-1"),
                "itemId": .string("item-1"),
                "startedAtMs": .number(1_786_000_000_000),
                "approvalId": .string("approval-1"),
                "reason": .string("Needs network access."),
                "command": .string("curl https://example.com"),
                "cwd": .string("/Users/timfeng/GitHub/Tidey"),
                "networkApprovalContext": .object([
                    "host": .string("example.com"),
                    "protocol": .string("https"),
                ]),
                "commandActions": .array([
                    .object([
                        "type": .string("search"),
                        "command": .string("rg TODO"),
                        "query": .string("TODO"),
                        "path": .string("/Users/timfeng/GitHub/Tidey"),
                    ]),
                ]),
            ]))

        let prompt = request.makePrompt(epoch: "epoch-a")

        XCTAssertEqual(prompt.vendor, "codex")
        XCTAssertEqual(prompt.source, "codex_command_approval")
        XCTAssertEqual(prompt.title, "Approve Codex command?")
        XCTAssertTrue(prompt.promptID.hasPrefix("codex-app-server-approval:"))
        XCTAssertTrue(prompt.body.contains("Command: curl https://example.com"))
        XCTAssertTrue(prompt.body.contains("Working directory: /Users/timfeng/GitHub/Tidey"))
        XCTAssertTrue(prompt.body.contains("Reason: Needs network access."))
        XCTAssertTrue(prompt.body.contains("Network: https://example.com"))
        XCTAssertTrue(prompt.body.contains("- search /Users/timfeng/GitHub/Tidey TODO rg TODO"))
        XCTAssertEqual(prompt.options.map(\.label), ["Yes, proceed (y)", "No, and tell Codex what to do differently (esc)"])
        XCTAssertEqual(prompt.options.map(\.inputSequence), ["accept", "decline"])
        XCTAssertEqual(prompt.selectedIndex, 0)
        XCTAssertEqual(prompt.jsonValue.objectValue?["submit_channel"]?.stringValue, "codex_app_server")

        let response = try request.response(targetIndex: 1)
        XCTAssertEqual(response.objectValue?["decision"]?.stringValue, "decline")
    }

    func testMapsFileChangeApprovalRequestToInteractivePrompt() throws {
        let request = try XCTUnwrap(CodexAppServerApprovalRequest(
            method: "item/fileChange/requestApproval",
            requestID: .integer(42),
            params: [
                "threadId": .string("thread-1"),
                "turnId": .string("turn-1"),
                "itemId": .string("item-2"),
                "startedAtMs": .number(1_786_000_000_000),
                "reason": .string("Needs write access."),
                "grantRoot": .string("/Users/timfeng/GitHub/Tidey"),
            ]))

        let prompt = request.makePrompt(epoch: "epoch-a")

        XCTAssertEqual(prompt.vendor, "codex")
        XCTAssertEqual(prompt.source, "codex_file_change_approval")
        XCTAssertEqual(prompt.title, "Approve Codex file changes?")
        XCTAssertTrue(prompt.body.contains("Reason: Needs write access."))
        XCTAssertTrue(prompt.body.contains("Grant root: /Users/timfeng/GitHub/Tidey"))
        XCTAssertEqual(prompt.options.map(\.label), [
            "Yes, make edits (y)",
            "Yes, and don't ask again for these files (p)",
            "No, and tell Codex what to do differently (esc)",
        ])
        XCTAssertEqual(prompt.options.map(\.inputSequence), ["accept", "acceptForSession", "decline"])

        let response = try request.response(targetIndex: 2)
        XCTAssertEqual(response.objectValue?["decision"]?.stringValue, "decline")
    }

    func testCommandApprovalFallbackDoesNotInventExecpolicyAmendmentOption() throws {
        let request = try XCTUnwrap(CodexAppServerApprovalRequest(
            method: "item/commandExecution/requestApproval",
            requestID: .string("req-1"),
            params: [
                "threadId": .string("thread-1"),
                "turnId": .string("turn-1"),
                "itemId": .string("item-1"),
                "startedAtMs": .number(1_786_000_000_000),
                "command": .string("python3 -c 'print(1)'"),
                "proposedExecpolicyAmendment": .array([
                    .string("python3"),
                    .string("-c"),
                ]),
            ]))

        let prompt = request.makePrompt(epoch: "epoch-a")

        XCTAssertEqual(prompt.options.map(\.label), [
            "Yes, proceed (y)",
            "No, and tell Codex what to do differently (esc)",
        ])
        XCTAssertEqual(prompt.options.map(\.inputSequence), [
            "accept",
            "decline",
        ])

        let response = try request.response(targetIndex: 1)
        XCTAssertEqual(response.objectValue?["decision"]?.stringValue, "decline")
    }

    func testCommandApprovalUsesAvailableDecisionOrderWhenPresent() throws {
        let request = try XCTUnwrap(CodexAppServerApprovalRequest(
            method: "item/commandExecution/requestApproval",
            requestID: .string("req-1"),
            params: [
                "threadId": .string("thread-1"),
                "turnId": .string("turn-1"),
                "itemId": .string("item-1"),
                "startedAtMs": .number(1_786_000_000_000),
                "availableDecisions": .array([
                    .string("decline"),
                    .string("accept"),
                ]),
                "proposedExecpolicyAmendment": .array([
                    .string("python3"),
                ]),
            ]))

        let prompt = request.makePrompt(epoch: "epoch-a")

        XCTAssertEqual(prompt.options.map(\.inputSequence), ["decline", "accept"])
        XCTAssertEqual(prompt.options.map(\.label), [
            "No, and tell Codex what to do differently (esc)",
            "Yes, proceed (y)",
        ])
        XCTAssertEqual(try request.response(targetIndex: 0).objectValue?["decision"]?.stringValue, "decline")
    }

    func testCommandApprovalKeepsPolicyAmendmentAvailableDecision() throws {
        let request = try XCTUnwrap(CodexAppServerApprovalRequest(
            method: "item/commandExecution/requestApproval",
            requestID: .string("req-1"),
            params: [
                "threadId": .string("thread-1"),
                "turnId": .string("turn-1"),
                "itemId": .string("item-1"),
                "startedAtMs": .number(1_786_000_000_000),
                "availableDecisions": .array([
                    .string("accept"),
                    .object([
                        "acceptWithExecpolicyAmendment": .object([
                            "execpolicy_amendment": .array([
                                .string("python3"),
                                .string("-c"),
                            ]),
                        ]),
                    ]),
                    .string("cancel"),
                ]),
            ]))

        let prompt = request.makePrompt(epoch: "epoch-a")

        XCTAssertEqual(prompt.options.map(\.label), [
            "Yes, proceed (y)",
            "Yes, and don't ask again for commands that start with `python3 -c` (p)",
            "No, and tell Codex what to do differently (esc)",
        ])
        XCTAssertEqual(prompt.options.map(\.inputSequence), [
            "accept",
            "acceptWithExecpolicyAmendment",
            "cancel",
        ])
        XCTAssertNotNil(try request.response(targetIndex: 1).objectValue?["decision"]?.objectValue?["acceptWithExecpolicyAmendment"])
        XCTAssertEqual(try request.response(targetIndex: 2).objectValue?["decision"]?.stringValue, "cancel")
    }

    func testCommandApprovalKeepsNetworkPolicyAmendmentAvailableDecision() throws {
        let request = try XCTUnwrap(CodexAppServerApprovalRequest(
            method: "item/commandExecution/requestApproval",
            requestID: .string("req-1"),
            params: [
                "threadId": .string("thread-1"),
                "turnId": .string("turn-1"),
                "itemId": .string("item-1"),
                "startedAtMs": .number(1_786_000_000_000),
                "availableDecisions": .array([
                    .string("accept"),
                    .object([
                        "applyNetworkPolicyAmendment": .object([
                            "network_policy_amendment": .object([
                                "host": .string("example.com"),
                                "action": .string("allow"),
                            ]),
                        ]),
                    ]),
                    .string("decline"),
                ]),
            ]))

        let prompt = request.makePrompt(epoch: "epoch-a")

        XCTAssertEqual(prompt.options.map(\.label), [
            "Yes, proceed (y)",
            "Yes, and allow example.com for this conversation",
            "No, and tell Codex what to do differently (esc)",
        ])
        XCTAssertEqual(prompt.options.map(\.inputSequence), [
            "accept",
            "applyNetworkPolicyAmendment",
            "decline",
        ])
        XCTAssertNotNil(try request.response(targetIndex: 1).objectValue?["decision"]?.objectValue?["applyNetworkPolicyAmendment"])
        XCTAssertEqual(try request.response(targetIndex: 2).objectValue?["decision"]?.stringValue, "decline")
    }

    func testCommandApprovalFallbackDoesNotInventNetworkPolicyAmendmentOption() throws {
        let request = try XCTUnwrap(CodexAppServerApprovalRequest(
            method: "item/commandExecution/requestApproval",
            requestID: .string("req-1"),
            params: [
                "threadId": .string("thread-1"),
                "turnId": .string("turn-1"),
                "itemId": .string("item-1"),
                "startedAtMs": .number(1_786_000_000_000),
                "command": .string("python3 -c 'import urllib.request'"),
                "proposedNetworkPolicyAmendments": .array([
                    .object([
                        "host": .string("example.com"),
                        "action": .string("allow"),
                    ]),
                ]),
            ]))

        let prompt = request.makePrompt(epoch: "epoch-a")

        XCTAssertEqual(prompt.options.map(\.label), [
            "Yes, proceed (y)",
            "No, and tell Codex what to do differently (esc)",
        ])
        XCTAssertEqual(prompt.options.map(\.inputSequence), [
            "accept",
            "decline",
        ])

        let response = try request.response(targetIndex: 1)
        XCTAssertEqual(response.objectValue?["decision"]?.stringValue, "decline")
    }

    func testRejectsUnsupportedApprovalMethod() {
        let request = CodexAppServerApprovalRequest(
            method: "item/tool/requestUserInput",
            requestID: .string("req-1"),
            params: [
                "threadId": .string("thread-1"),
                "turnId": .string("turn-1"),
                "itemId": .string("item-1"),
            ])

        XCTAssertNil(request)
    }

    // Strict 0.144.1 question parsing: any malformed question makes the
    // WHOLE request invalid (-32602), never a partially presented card.
    private func requestUserInputParams(questions: JSONValue) -> [String: JSONValue] {
        [
            "threadId": .string("thread-1"),
            "turnId": .string("turn-1"),
            "itemId": .string("item-1"),
            "questions": questions,
        ]
    }

    func testAcceptsWellFormedQuestionsAsBaseline() throws {
        let request = try XCTUnwrap(CodexAppServerApprovalRequest(
            method: "item/tool/requestUserInput",
            requestID: .string("req-1"),
            params: requestUserInputParams(questions: .array([
                .object(["id": .string("q1"), "header": .string("H"), "question": .string("Q"),
                         "isOther": .bool(false), "isSecret": .bool(false)]),
            ]))))
        XCTAssertEqual(request.userInputQuestions.count, 1)
    }

    func testRejectsQuestionWithEmptyID() {
        let request = CodexAppServerApprovalRequest(
            method: "item/tool/requestUserInput",
            requestID: .string("req-1"),
            params: requestUserInputParams(questions: .array([
                .object(["id": .string(""), "header": .string("H"), "question": .string("Q")]),
            ])))
        XCTAssertNil(request)
    }

    func testRejectsDuplicateQuestionIDs() {
        let request = CodexAppServerApprovalRequest(
            method: "item/tool/requestUserInput",
            requestID: .string("req-1"),
            params: requestUserInputParams(questions: .array([
                .object(["id": .string("q1"), "header": .string("H1"), "question": .string("Q1")]),
                .object(["id": .string("q1"), "header": .string("H2"), "question": .string("Q2")]),
            ])))
        XCTAssertNil(request)
    }

    func testRejectsNonBoolIsOtherOnQuestion() {
        let request = CodexAppServerApprovalRequest(
            method: "item/tool/requestUserInput",
            requestID: .string("req-1"),
            params: requestUserInputParams(questions: .array([
                .object(["id": .string("q1"), "header": .string("H"), "question": .string("Q"),
                         "isOther": .string("true")]),
            ])))
        XCTAssertNil(request, "a present-but-non-bool isOther must never silently default to false")
    }

    func testRejectsNonBoolIsSecretOnQuestion() {
        let request = CodexAppServerApprovalRequest(
            method: "item/tool/requestUserInput",
            requestID: .string("req-1"),
            params: requestUserInputParams(questions: .array([
                .object(["id": .string("q1"), "header": .string("H"), "question": .string("Q"),
                         "isSecret": .number(1)]),
            ])))
        XCTAssertNil(request, "a present-but-non-bool isSecret must never silently downgrade to plain text")
    }

    func testRejectsNonArrayOptionsOnQuestion() {
        let request = CodexAppServerApprovalRequest(
            method: "item/tool/requestUserInput",
            requestID: .string("req-1"),
            params: requestUserInputParams(questions: .array([
                .object(["id": .string("q1"), "header": .string("H"), "question": .string("Q"),
                         "options": .string("not-an-array")]),
            ])))
        XCTAssertNil(request, "a present-but-non-array options must never silently become free-form")
    }

    func testRejectsMalformedOptionEntryMissingLabelOrDescription() {
        let request = CodexAppServerApprovalRequest(
            method: "item/tool/requestUserInput",
            requestID: .string("req-1"),
            params: requestUserInputParams(questions: .array([
                .object(["id": .string("q1"), "header": .string("H"), "question": .string("Q"),
                         "options": .array([.object(["label": .string("A")])])]), // missing description
            ])))
        XCTAssertNil(request)
    }

    func testRejectsNonArrayQuestionsField() {
        let request = CodexAppServerApprovalRequest(
            method: "item/tool/requestUserInput",
            requestID: .string("req-1"),
            params: requestUserInputParams(questions: .string("not-an-array")))
        XCTAssertNil(request)
    }

    func testRejectsMissingHeaderOrQuestionField() {
        let missingHeader = CodexAppServerApprovalRequest(
            method: "item/tool/requestUserInput",
            requestID: .string("req-1"),
            params: requestUserInputParams(questions: .array([
                .object(["id": .string("q1"), "question": .string("Q")]),
            ])))
        XCTAssertNil(missingHeader)

        let missingQuestion = CodexAppServerApprovalRequest(
            method: "item/tool/requestUserInput",
            requestID: .string("req-1"),
            params: requestUserInputParams(questions: .array([
                .object(["id": .string("q1"), "header": .string("H")]),
            ])))
        XCTAssertNil(missingQuestion)
    }

    func testRejectsPermissionsApprovalRequestMissingRequiredFields() {
        var baseParams: [String: JSONValue] = [
            "threadId": .string("thread-1"),
            "turnId": .string("turn-1"),
            "itemId": .string("item-1"),
            "cwd": .string("/Users/timfeng/GitHub/Tidey"),
            "startedAtMs": .number(1_786_000_000_000),
            "permissions": .object([:]),
        ]

        XCTAssertNotNil(CodexAppServerApprovalRequest(method: "item/permissions/requestApproval",
                                                      requestID: .string("req-1"),
                                                      params: baseParams))

        // Installed schema requires permissions, startedAtMs, and cwd; a
        // partial approval must be rejected (the connection then answers
        // -32602), not presented incomplete.
        for missingKey in ["permissions", "startedAtMs", "cwd"] {
            var params = baseParams
            params.removeValue(forKey: missingKey)
            XCTAssertNil(CodexAppServerApprovalRequest(method: "item/permissions/requestApproval",
                                                       requestID: .string("req-1"),
                                                       params: params),
                         "missing \(missingKey) must be rejected")
        }
        baseParams["permissions"] = .string("not-an-object")
        XCTAssertNil(CodexAppServerApprovalRequest(method: "item/permissions/requestApproval",
                                                   requestID: .string("req-1"),
                                                   params: baseParams))
    }

    func testSpecialUnknownPathShowsActualGrantedPath() throws {
        // Official schema: FileSystemSpecialPath kind "unknown" always
        // carries the real filesystem path; hiding it would let the user
        // approve an undisclosed grant. Both display paths (permissions and
        // command additionalPermissions) must show it.
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

        let permissionsRequest = try XCTUnwrap(CodexAppServerApprovalRequest(
            method: "item/permissions/requestApproval",
            requestID: .string("req-1"),
            params: [
                "threadId": .string("thread-1"),
                "turnId": .string("turn-1"),
                "itemId": .string("item-1"),
                "cwd": .string("/Users/timfeng/GitHub/Tidey"),
                "startedAtMs": .number(1_786_000_000_000),
                "permissions": profile,
            ]))
        let permissionsBody = permissionsRequest.makePrompt(epoch: "e").body
        XCTAssertTrue(permissionsBody.contains("- write /Volumes/Backup/secrets"))
        XCTAssertTrue(permissionsBody.contains("- read /opt/data/nested"))
        XCTAssertFalse(permissionsBody.contains("- write unknown"))

        let commandRequest = try XCTUnwrap(CodexAppServerApprovalRequest(
            method: "item/commandExecution/requestApproval",
            requestID: .string("req-2"),
            params: [
                "threadId": .string("thread-1"),
                "turnId": .string("turn-1"),
                "itemId": .string("item-2"),
                "startedAtMs": .number(1_786_000_000_000),
                "command": .string("backup.sh"),
                "additionalPermissions": profile,
            ]))
        let commandBody = commandRequest.makePrompt(epoch: "e").body
        XCTAssertTrue(commandBody.contains("- write /Volumes/Backup/secrets"))
        XCTAssertTrue(commandBody.contains("- read /opt/data/nested"))
    }

    func testKnownSpecialAndPatternPathDisplaysDoNotRegress() throws {
        var entries: [JSONValue] = []
        for kind in ["root", "minimal", "tmpdir", "slash_tmp"] {
            entries.append(.object([
                "access": .string("read"),
                "path": .object([
                    "type": .string("special"),
                    "value": .object(["kind": .string(kind)]),
                ]),
            ]))
        }
        entries.append(.object([
            "access": .string("read"),
            "path": .object([
                "type": .string("special"),
                "value": .object(["kind": .string("project_roots"), "subpath": .string("src")]),
            ]),
        ]))
        entries.append(.object([
            "access": .string("write"),
            "path": .object(["type": .string("path"), "path": .string("/tmp/plain")]),
        ]))
        entries.append(.object([
            "access": .string("read"),
            "path": .object(["type": .string("glob_pattern"), "pattern": .string("**/*.swift")]),
        ]))
        let request = try XCTUnwrap(CodexAppServerApprovalRequest(
            method: "item/permissions/requestApproval",
            requestID: .string("req-1"),
            params: [
                "threadId": .string("thread-1"),
                "turnId": .string("turn-1"),
                "itemId": .string("item-1"),
                "cwd": .string("/Users/timfeng/GitHub/Tidey"),
                "startedAtMs": .number(1_786_000_000_000),
                "permissions": .object(["fileSystem": .object(["entries": .array(entries)])]),
            ]))

        let body = request.makePrompt(epoch: "e").body
        for expected in ["- read root", "- read minimal", "- read tmpdir", "- read slash_tmp",
                         "- read project_roots/src", "- write /tmp/plain", "- read glob **/*.swift"] {
            XCTAssertTrue(body.contains(expected), "missing \(expected) in body: \(body)")
        }
    }

    func testPermissionsPromptShowsEnvironmentAndDisabledNetwork() throws {
        let request = try XCTUnwrap(CodexAppServerApprovalRequest(
            method: "item/permissions/requestApproval",
            requestID: .string("req-1"),
            params: [
                "threadId": .string("thread-1"),
                "turnId": .string("turn-1"),
                "itemId": .string("item-1"),
                "cwd": .string("/Users/timfeng/GitHub/Tidey"),
                "startedAtMs": .number(1_786_000_000_000),
                "environmentId": .string("env-42"),
                "permissions": .object([
                    "network": .object([
                        "enabled": .bool(false),
                    ]),
                ]),
            ]))

        let prompt = request.makePrompt(epoch: "epoch-a")

        XCTAssertTrue(prompt.body.contains("Environment: env-42"))
        XCTAssertTrue(prompt.body.contains("Network: outbound network access disabled"))
        XCTAssertFalse(prompt.body.contains("allow outbound network access"))
    }

    private static func permissionsParams() -> [String: JSONValue] {
        [
            "threadId": .string("thread-1"),
            "turnId": .string("turn-1"),
            "itemId": .string("item-1"),
            "cwd": .string("/Users/timfeng/GitHub/Tidey"),
            "startedAtMs": .number(1_786_000_000_000),
            "reason": .string("Needs broader filesystem access."),
            "permissions": .object([
                "network": .object([
                    "enabled": .bool(true),
                ]),
                "fileSystem": .object([
                    "entries": .array([
                        .object([
                            "access": .string("write"),
                            "path": .object([
                                "type": .string("path"),
                                "path": .string("/Users/timfeng/GitHub/Tidey"),
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
            ]),
        ]
    }

    func testMapsPermissionsApprovalRequestToInteractivePrompt() throws {
        let request = try XCTUnwrap(CodexAppServerApprovalRequest(
            method: "item/permissions/requestApproval",
            requestID: .string("req-1"),
            params: Self.permissionsParams()))

        let prompt = request.makePrompt(epoch: "epoch-a")

        XCTAssertEqual(prompt.vendor, "codex")
        XCTAssertEqual(prompt.source, "codex_permissions_approval")
        XCTAssertEqual(prompt.title, "Approve Codex permissions?")
        XCTAssertTrue(prompt.body.contains("Reason: Needs broader filesystem access."))
        XCTAssertTrue(prompt.body.contains("Working directory: /Users/timfeng/GitHub/Tidey"))
        XCTAssertTrue(prompt.body.contains("Network: allow outbound network access"))
        XCTAssertTrue(prompt.body.contains("File system:"))
        XCTAssertTrue(prompt.body.contains("- write /Users/timfeng/GitHub/Tidey"))
        XCTAssertTrue(prompt.body.contains("- read glob **/*.swift"))
        XCTAssertTrue(prompt.body.contains("- deny project_roots/secrets"))
        XCTAssertTrue(prompt.body.contains("- read /tmp/legacy-read"))
        XCTAssertTrue(prompt.body.contains("- write /tmp/legacy-write"))
        XCTAssertEqual(prompt.options.map(\.inputSequence), ["allow_turn", "allow_session", "deny"])
        XCTAssertEqual(prompt.options.map(\.label), [
            "Yes, allow for this turn (y)",
            "Yes, allow for this session (p)",
            "No, and tell Codex what to do differently (esc)",
        ])
        XCTAssertEqual(prompt.jsonValue.objectValue?["submit_channel"]?.stringValue, "codex_app_server")
    }

    func testPermissionsApprovalResponsesMatchInstalledSchemaShape() throws {
        let params = Self.permissionsParams()
        let request = try XCTUnwrap(CodexAppServerApprovalRequest(
            method: "item/permissions/requestApproval",
            requestID: .string("req-1"),
            params: params))

        let allowTurn = try request.response(targetIndex: 0)
        XCTAssertEqual(allowTurn.objectValue?["scope"]?.stringValue, "turn")
        XCTAssertEqual(try Self.canonicalJSON(allowTurn.objectValue?["permissions"]),
                       try Self.canonicalJSON(params["permissions"]))
        XCTAssertNil(allowTurn.objectValue?["decision"])
        XCTAssertEqual(Set(try XCTUnwrap(allowTurn.objectValue).keys), ["permissions", "scope"])

        let allowSession = try request.response(targetIndex: 1)
        XCTAssertEqual(allowSession.objectValue?["scope"]?.stringValue, "session")
        XCTAssertEqual(try Self.canonicalJSON(allowSession.objectValue?["permissions"]),
                       try Self.canonicalJSON(params["permissions"]))
        XCTAssertNil(allowSession.objectValue?["decision"])

        let deny = try request.response(targetIndex: 2)
        XCTAssertEqual(try Self.canonicalJSON(deny.objectValue?["permissions"]),
                       try Self.canonicalJSON(.object([:])))
        XCTAssertEqual(deny.objectValue?["scope"]?.stringValue, "turn")
        XCTAssertNil(deny.objectValue?["decision"])

        XCTAssertThrowsError(try request.response(targetIndex: 3))
    }

    private static func canonicalJSON(_ value: JSONValue?) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value ?? .null)
        return String(decoding: data, as: UTF8.self)
    }

    func testPermissionsApprovalNeverGrantsBeyondRequestedProfile() throws {
        let params = Self.permissionsParams()
        let request = try XCTUnwrap(CodexAppServerApprovalRequest(
            method: "item/permissions/requestApproval",
            requestID: .string("req-1"),
            params: params))

        let requestedJSON = try Self.canonicalJSON(params["permissions"])
        let emptyJSON = try Self.canonicalJSON(.object([:]))
        for targetIndex in 0...2 {
            let response = try request.response(targetIndex: targetIndex)
            let granted = try Self.canonicalJSON(try XCTUnwrap(response.objectValue?["permissions"]))
            XCTAssertTrue(granted == requestedJSON || granted == emptyJSON,
                          "granted profile must be the requested profile or empty, got \(granted)")
        }
    }

    // MARK: - Typed request ids and epoch identity

    func testTypedRequestIDsDoNotCollideAndPreserveInt64() throws {
        XCTAssertNotEqual(CodexAppServerRequestID.string("1").storageKey,
                          CodexAppServerRequestID.integer(1).storageKey)
        XCTAssertEqual(CodexAppServerRequestID.string("1").jsonToken, "\"1\"")
        XCTAssertEqual(CodexAppServerRequestID.integer(1).jsonToken, "1")
        XCTAssertEqual(CodexAppServerRequestID.integer(Int64.max).jsonToken, "9223372036854775807")

        let parsedString = CodexAppServerRequestID(rawJSONObjectValue: "1")
        let parsedInteger = CodexAppServerRequestID(rawJSONObjectValue: NSNumber(value: Int64.max))
        XCTAssertEqual(parsedString, .string("1"))
        XCTAssertEqual(parsedInteger, .integer(Int64.max))
        XCTAssertNil(CodexAppServerRequestID(rawJSONObjectValue: true))

        let stringRequest = try XCTUnwrap(Self.commandRequest(requestID: .string("1")))
        let integerRequest = try XCTUnwrap(Self.commandRequest(requestID: .integer(1)))
        XCTAssertNotEqual(stringRequest.promptID(epoch: "e"), integerRequest.promptID(epoch: "e"))
    }

    func testPromptIdentityIsStableForSameEpochAndChangesAcrossEpochs() throws {
        let request = try XCTUnwrap(Self.commandRequest(requestID: .integer(1)))
        // Reconnecting to the same app-server process re-delivers the request
        // with the same identity; a restarted process must never collide.
        XCTAssertEqual(request.promptID(epoch: "pid:100|sock:/tmp/a.sock"),
                       request.promptID(epoch: "pid:100|sock:/tmp/a.sock"))
        XCTAssertNotEqual(request.promptID(epoch: "pid:100|sock:/tmp/a.sock"),
                          request.promptID(epoch: "pid:200|sock:/tmp/a.sock"))
    }

    // MARK: - Store state machine

    private static func commandRequest(requestID: CodexAppServerRequestID,
                                       itemID: String = "item-1") -> CodexAppServerApprovalRequest? {
        CodexAppServerApprovalRequest(
            method: "item/commandExecution/requestApproval",
            requestID: requestID,
            params: [
                "threadId": .string("thread-1"),
                "turnId": .string("turn-1"),
                "itemId": .string(itemID),
                "startedAtMs": .number(1_786_000_000_000),
            ])
    }

    private static func entry(requestID: CodexAppServerRequestID = .string("req-1"),
                              itemID: String = "item-1",
                              epoch: String = "epoch-a") throws -> CodexAppServerApprovalPromptEntry {
        let request = try XCTUnwrap(commandRequest(requestID: requestID, itemID: itemID))
        return CodexAppServerApprovalPromptEntry(request: request,
                                                 prompt: request.makePrompt(epoch: epoch))
    }

    private static func terminalEvent(promptID: String, reason: String) -> AgentEvent {
        AgentEvent(eventID: "codex-app-server-prompt-resolved:\(promptID):\(reason)",
                   seq: 1,
                   vendor: "codex",
                   workspaceID: "workspace-1",
                   sessionID: "session-1",
                   timestamp: "2026-07-15T00:00:00.000Z",
                   type: .interactivePromptResolved,
                   role: nil,
                   text: nil,
                   name: nil,
                   input: nil,
                   output: nil,
                   toolCallID: nil,
                   metadata: ["prompt_id": promptID, "reason": reason])
    }

    func testStoreSubmitFlushDoesNotTerminateEntry() throws {
        let store = CodexAppServerApprovalPromptStore()
        let entry = try Self.entry()
        _ = store.register(entry: entry, makeTerminalEvent: { entry, reason, _ in
            Self.terminalEvent(promptID: entry.prompt.promptID, reason: reason)
        })

        guard case .begin = store.beginSubmit(promptID: entry.prompt.promptID,
                                              targetIndex: 0,
                                              clientRequestID: "client-1") else {
            return XCTFail("expected begin")
        }
        guard case .awaitingConfirmation = store.completeSubmitFlush(promptID: entry.prompt.promptID, lifecycleAttempt: 1) else {
            return XCTFail("flush must not terminate the entry")
        }
        XCTAssertEqual(store.pendingStates().count, 1)
        if case .submitting(let attempt)? = store.pendingStates().first?.phase {
            XCTAssertEqual(attempt.clientRequestID, "client-1")
        } else {
            XCTFail("entry should remain in submitting phase")
        }
    }

    func testStoreDuplicateAndConflictingSubmitSemantics() throws {
        let store = CodexAppServerApprovalPromptStore()
        let entry = try Self.entry()
        _ = store.register(entry: entry, makeTerminalEvent: { entry, reason, _ in
            Self.terminalEvent(promptID: entry.prompt.promptID, reason: reason)
        })
        let promptID = entry.prompt.promptID

        guard case .begin = store.beginSubmit(promptID: promptID, targetIndex: 0, clientRequestID: "client-1") else {
            return XCTFail("expected begin")
        }
        // Same client identity + same option: idempotent duplicate, no resend.
        guard case .duplicateInFlight = store.beginSubmit(promptID: promptID, targetIndex: 0, clientRequestID: "client-1") else {
            return XCTFail("expected duplicateInFlight")
        }
        // Same client identity + different option: fail closed.
        guard case .optionConflict = store.beginSubmit(promptID: promptID, targetIndex: 1, clientRequestID: "client-1") else {
            return XCTFail("expected optionConflict")
        }
        // Different client identity while in flight: conflict.
        guard case .inFlightConflict = store.beginSubmit(promptID: promptID, targetIndex: 0, clientRequestID: "client-2") else {
            return XCTFail("expected inFlightConflict")
        }

        // After an ambiguous failure the same identity may retry the same
        // option, but a different option stays fail-closed.
        _ = store.failSubmit(promptID: promptID, lifecycleAttempt: 1)
        guard case .optionConflict = store.beginSubmit(promptID: promptID, targetIndex: 1, clientRequestID: "client-1") else {
            return XCTFail("expected optionConflict after failure")
        }
        guard case .begin = store.beginSubmit(promptID: promptID, targetIndex: 0, clientRequestID: "client-1") else {
            return XCTFail("expected retry begin after failure")
        }
    }

    func testStoreExternalResolutionWinsOverInFlightSubmit() throws {
        let store = CodexAppServerApprovalPromptStore()
        let entry = try Self.entry()
        _ = store.register(entry: entry, makeTerminalEvent: { entry, reason, _ in
            Self.terminalEvent(promptID: entry.prompt.promptID, reason: reason)
        })
        let promptID = entry.prompt.promptID

        guard case .begin = store.beginSubmit(promptID: promptID, targetIndex: 0, clientRequestID: "client-1") else {
            return XCTFail("expected begin")
        }
        let records = store.resolveExternally(reason: "server_resolved",
                                              where: { _ in true },
                                              makeEvent: { entry, reason, _ in
                                                  Self.terminalEvent(promptID: entry.prompt.promptID, reason: reason)
                                              })
        XCTAssertEqual(records.count, 1)

        // The local submit waking up after the flush sees the terminal record
        // instead of terminating the entry itself.
        guard case .terminal(let record) = store.completeSubmitFlush(promptID: promptID, lifecycleAttempt: 1) else {
            return XCTFail("expected terminal after external resolution")
        }
        XCTAssertEqual(record.reason, "server_resolved")
        XCTAssertTrue(store.pendingStates().isEmpty)

        // Re-delivery supersedes the terminal record and re-arms the prompt.
        guard case .recorded = store.register(entry: entry, makeTerminalEvent: { entry, reason, _ in
            Self.terminalEvent(promptID: entry.prompt.promptID, reason: reason)
        }) else {
            return XCTFail("expected fresh registration after terminal")
        }
        XCTAssertNil(store.terminalRecord(promptID: promptID))
    }

    func testStoreAttemptCounterAdvancesAcrossRedeliveryAndTerminals() throws {
        let store = CodexAppServerApprovalPromptStore()
        let entry = try Self.entry()

        guard case .recorded(_, let firstAttempt) = store.register(entry: entry, makeTerminalEvent: { entry, reason, _ in
            Self.terminalEvent(promptID: entry.prompt.promptID, reason: reason)
        }) else {
            return XCTFail("expected recorded")
        }
        XCTAssertEqual(firstAttempt, 1)

        guard case .reactivated(_, let secondAttempt) = store.register(entry: entry, makeTerminalEvent: { entry, reason, _ in
            Self.terminalEvent(promptID: entry.prompt.promptID, reason: reason)
        }) else {
            return XCTFail("expected reactivated")
        }
        XCTAssertEqual(secondAttempt, 2)

        let records = store.resolveExternally(reason: "server_resolved",
                                              where: { _ in true },
                                              makeEvent: { entry, reason, _ in
                                                  Self.terminalEvent(promptID: entry.prompt.promptID, reason: reason)
                                              })
        XCTAssertEqual(records.first?.attempt, 2)

        // A re-delivery after the terminal starts a fresh lifecycle with a
        // higher attempt so its events cannot be deduplicated as repeats.
        guard case .recorded(_, let thirdAttempt) = store.register(entry: entry, makeTerminalEvent: { entry, reason, _ in
            Self.terminalEvent(promptID: entry.prompt.promptID, reason: reason)
        }) else {
            return XCTFail("expected recorded after terminal")
        }
        XCTAssertEqual(thirdAttempt, 3)
    }

    private static func commandRequest(requestID: CodexAppServerRequestID,
                                       itemID: String = "item-1",
                                       command: String) -> CodexAppServerApprovalRequest? {
        CodexAppServerApprovalRequest(
            method: "item/commandExecution/requestApproval",
            requestID: requestID,
            params: [
                "threadId": .string("thread-1"),
                "turnId": .string("turn-1"),
                "itemId": .string(itemID),
                "startedAtMs": .number(1_786_000_000_000),
                "command": .string(command),
            ])
    }

    func testStoreRedeliveryWithIdenticalPayloadReplacesEntryAtomically() throws {
        let store = CodexAppServerApprovalPromptStore()
        let first = try XCTUnwrap(Self.commandRequest(requestID: .string("req-1"), command: "ls"))
        let redelivered = try XCTUnwrap(Self.commandRequest(requestID: .string("req-1"), command: "ls"))
        let firstEntry = CodexAppServerApprovalPromptEntry(request: first, prompt: first.makePrompt(epoch: "e"))
        let redeliveredEntry = CodexAppServerApprovalPromptEntry(request: redelivered, prompt: redelivered.makePrompt(epoch: "e"))
        let makeEvent: (CodexAppServerApprovalPromptEntry, String, Int) -> AgentEvent = { entry, reason, _ in
            Self.terminalEvent(promptID: entry.prompt.promptID, reason: reason)
        }

        _ = store.register(entry: firstEntry, makeTerminalEvent: makeEvent)
        guard case .begin = store.beginSubmit(promptID: firstEntry.prompt.promptID,
                                              targetIndex: 0,
                                              clientRequestID: "client-1") else {
            return XCTFail("expected begin")
        }
        // Re-delivery while submitting with identical payload: the stored
        // entry is the newly delivered request, phase resets to pending, and
        // the same-option conflict guard survives.
        guard case .reactivated = store.register(entry: redeliveredEntry, makeTerminalEvent: makeEvent) else {
            return XCTFail("expected reactivated")
        }
        guard case .optionConflict = store.beginSubmit(promptID: firstEntry.prompt.promptID,
                                                       targetIndex: 1,
                                                       clientRequestID: "client-1") else {
            return XCTFail("conflict guard must survive an identical-payload re-delivery")
        }
    }

    func testStoreRedeliveryWithChangedPayloadFailsClosed() throws {
        let store = CodexAppServerApprovalPromptStore()
        let original = try XCTUnwrap(Self.commandRequest(requestID: .string("req-1"), command: "ls"))
        let changed = try XCTUnwrap(Self.commandRequest(requestID: .string("req-1"), command: "rm -rf /"))
        let originalEntry = CodexAppServerApprovalPromptEntry(request: original, prompt: original.makePrompt(epoch: "e"))
        let changedEntry = CodexAppServerApprovalPromptEntry(request: changed, prompt: changed.makePrompt(epoch: "e"))
        let makeEvent: (CodexAppServerApprovalPromptEntry, String, Int) -> AgentEvent = { entry, reason, _ in
            Self.terminalEvent(promptID: entry.prompt.promptID, reason: reason)
        }

        _ = store.register(entry: originalEntry, makeTerminalEvent: makeEvent)
        // A local decision is already in flight against the ORIGINAL payload.
        guard case .begin = store.beginSubmit(promptID: originalEntry.prompt.promptID,
                                              targetIndex: 0,
                                              clientRequestID: "client-1") else {
            return XCTFail("expected begin")
        }

        guard case .supersededPayloadChanged(let terminal, let entry, let attempt) =
                store.register(entry: changedEntry, makeTerminalEvent: makeEvent) else {
            return XCTFail("expected supersededPayloadChanged")
        }
        // The inconsistent old lifecycle is terminated...
        XCTAssertEqual(terminal.reason, "superseded")
        XCTAssertEqual(terminal.entry.request.command, "ls")
        // ...and the fresh lifecycle is backed entirely by the new request:
        // the displayed prompt and the response source are the same object.
        XCTAssertEqual(entry.request.command, "rm -rf /")
        XCTAssertEqual(attempt, 2)
        XCTAssertEqual(store.entry(promptID: originalEntry.prompt.promptID)?.request.command, "rm -rf /")

        // The in-flight old decision does not carry over to the changed
        // payload: the new lifecycle accepts a fresh decision of any option.
        guard case .begin(let beginEntry, _, _) = store.beginSubmit(promptID: originalEntry.prompt.promptID,
                                                                 targetIndex: 1,
                                                                 clientRequestID: "client-2") else {
            return XCTFail("new lifecycle must accept a fresh decision")
        }
        XCTAssertEqual(beginEntry.request.command, "rm -rf /")
    }

    func testStoreRedeliveryAfterTerminalStartsFreshForBothPayloadShapes() throws {
        for command in ["ls", "rm -rf /"] {
            let store = CodexAppServerApprovalPromptStore()
            let original = try XCTUnwrap(Self.commandRequest(requestID: .string("req-1"), command: "ls"))
            let redelivered = try XCTUnwrap(Self.commandRequest(requestID: .string("req-1"), command: command))
            let originalEntry = CodexAppServerApprovalPromptEntry(request: original, prompt: original.makePrompt(epoch: "e"))
            let redeliveredEntry = CodexAppServerApprovalPromptEntry(request: redelivered, prompt: redelivered.makePrompt(epoch: "e"))
            let makeEvent: (CodexAppServerApprovalPromptEntry, String, Int) -> AgentEvent = { entry, reason, _ in
                Self.terminalEvent(promptID: entry.prompt.promptID, reason: reason)
            }

            _ = store.register(entry: originalEntry, makeTerminalEvent: makeEvent)
            _ = store.resolveExternally(reason: "server_resolved",
                                        where: { _ in true },
                                        makeEvent: makeEvent)

            guard case .recorded(let entry, let attempt) = store.register(entry: redeliveredEntry,
                                                                          makeTerminalEvent: makeEvent) else {
                return XCTFail("expected recorded after terminal")
            }
            XCTAssertEqual(entry.request.command, command)
            XCTAssertEqual(attempt, 2)
        }
    }

    func testStoreRetireGateSerializesCloseAndRegistration() throws {
        let makeEvent: (CodexAppServerApprovalPromptEntry, String, Int) -> AgentEvent = { entry, reason, _ in
            Self.terminalEvent(promptID: entry.prompt.promptID, reason: reason)
        }

        // Order A: register before retire -> the same retire terminalizes it.
        let storeA = CodexAppServerApprovalPromptStore()
        let entryA = try Self.entry()
        _ = storeA.register(entry: entryA, makeTerminalEvent: makeEvent)
        let records = storeA.retireAndResolveAll(reason: "expired", makeEvent: makeEvent)
        XCTAssertEqual(records.count, 1)
        XCTAssertTrue(storeA.pendingStates().isEmpty)

        // Order B: retire before register -> registration is rejected, no
        // active prompt, no lifecycle to publish.
        let storeB = CodexAppServerApprovalPromptStore()
        _ = storeB.retireAndResolveAll(reason: "expired", makeEvent: makeEvent)
        guard case .rejectedRetired = storeB.register(entry: entryA, makeTerminalEvent: makeEvent) else {
            return XCTFail("expected rejectedRetired")
        }
        XCTAssertTrue(storeB.pendingStates().isEmpty)

        // Interleaved stress: whatever the ordering, a retired store never
        // ends up with an active prompt and each identity has at most one
        // terminal event from the retire.
        let storeC = CodexAppServerApprovalPromptStore()
        let group = DispatchGroup()
        let terminalRecords = NSMutableArray()
        let recordsLock = NSLock()
        for index in 0..<32 {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                defer { group.leave() }
                if index == 16 {
                    let records = storeC.retireAndResolveAll(reason: "expired", makeEvent: makeEvent)
                    recordsLock.lock()
                    terminalRecords.addObjects(from: records)
                    recordsLock.unlock()
                } else if let request = Self.commandRequest(requestID: .string("req-\(index)"),
                                                            itemID: "item-\(index)",
                                                            command: "ls") {
                    let entry = CodexAppServerApprovalPromptEntry(request: request,
                                                                  prompt: request.makePrompt(epoch: "e"))
                    _ = storeC.register(entry: entry, makeTerminalEvent: makeEvent)
                }
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)
        XCTAssertTrue(storeC.isRetired())
        XCTAssertTrue(storeC.pendingStates().isEmpty, "a retired generation must never retain an active prompt")
    }

    func testStoreTerminalRecordsAreBounded() throws {
        let store = CodexAppServerApprovalPromptStore(terminalCapacity: 2)
        var promptIDs: [String] = []
        for index in 0..<3 {
            let entry = try Self.entry(requestID: .string("req-\(index)"), itemID: "item-\(index)")
            promptIDs.append(entry.prompt.promptID)
            _ = store.register(entry: entry, makeTerminalEvent: { entry, reason, _ in
            Self.terminalEvent(promptID: entry.prompt.promptID, reason: reason)
        })
            _ = store.resolveExternally(reason: "server_resolved",
                                        where: { $0.itemID == "item-\(index)" },
                                        makeEvent: { entry, reason, _ in
                                            Self.terminalEvent(promptID: entry.prompt.promptID, reason: reason)
                                        })
        }

        XCTAssertEqual(store.terminalRecordCount(), 2)
        XCTAssertNil(store.terminalRecord(promptID: promptIDs[0]))
        XCTAssertNotNil(store.terminalRecord(promptID: promptIDs[1]))
        XCTAssertNotNil(store.terminalRecord(promptID: promptIDs[2]))
    }

    func testRejectsUnknownPromptOptionIndex() throws {
        let request = try XCTUnwrap(CodexAppServerApprovalRequest(
            method: "item/commandExecution/requestApproval",
            requestID: .string("req-1"),
            params: [
                "threadId": .string("thread-1"),
                "turnId": .string("turn-1"),
                "itemId": .string("item-1"),
                "startedAtMs": .number(1_786_000_000_000),
            ]))

        XCTAssertThrowsError(try request.response(targetIndex: 2))
    }
}
