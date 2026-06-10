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

        let prompt = request.makePrompt()

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
            requestID: .number(42),
            params: [
                "threadId": .string("thread-1"),
                "turnId": .string("turn-1"),
                "itemId": .string("item-2"),
                "startedAtMs": .number(1_786_000_000_000),
                "reason": .string("Needs write access."),
                "grantRoot": .string("/Users/timfeng/GitHub/Tidey"),
            ]))

        let prompt = request.makePrompt()

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

        let prompt = request.makePrompt()

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

        let prompt = request.makePrompt()

        XCTAssertEqual(prompt.options.map(\.inputSequence), ["decline", "accept"])
        XCTAssertEqual(prompt.options.map(\.label), [
            "No, and tell Codex what to do differently (esc)",
            "Yes, proceed (y)",
        ])
        XCTAssertEqual(try request.response(targetIndex: 0).objectValue?["decision"]?.stringValue, "decline")
    }

    func testCommandApprovalFiltersPolicyAmendmentAvailableDecision() throws {
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

        let prompt = request.makePrompt()

        XCTAssertEqual(prompt.options.map(\.label), [
            "Yes, proceed (y)",
            "No, and tell Codex what to do differently (esc)",
        ])
        XCTAssertEqual(prompt.options.map(\.inputSequence), [
            "accept",
            "cancel",
        ])
        XCTAssertEqual(try request.response(targetIndex: 1).objectValue?["decision"]?.stringValue, "cancel")
    }

    func testCommandApprovalFiltersNetworkPolicyAmendmentAvailableDecision() throws {
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

        let prompt = request.makePrompt()

        XCTAssertEqual(prompt.options.map(\.label), [
            "Yes, proceed (y)",
            "No, and tell Codex what to do differently (esc)",
        ])
        XCTAssertEqual(prompt.options.map(\.inputSequence), [
            "accept",
            "decline",
        ])
        XCTAssertEqual(try request.response(targetIndex: 1).objectValue?["decision"]?.stringValue, "decline")
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

        let prompt = request.makePrompt()

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
            method: "item/permissions/requestApproval",
            requestID: .string("req-1"),
            params: [
                "threadId": .string("thread-1"),
                "turnId": .string("turn-1"),
                "itemId": .string("item-1"),
            ])

        XCTAssertNil(request)
    }

    func testPromptStoreResolvesPromptOnce() throws {
        let request = try XCTUnwrap(CodexAppServerApprovalRequest(
            method: "item/fileChange/requestApproval",
            requestID: .string("req-1"),
            params: [
                "threadId": .string("thread-1"),
                "turnId": .string("turn-1"),
                "itemId": .string("item-1"),
                "startedAtMs": .number(1_786_000_000_000),
            ]))
        let store = CodexAppServerApprovalPromptStore()
        let prompt = store.record(request)

        XCTAssertNotNil(store.entry(promptID: prompt.promptID))
        let response = try store.resolve(promptID: prompt.promptID, targetIndex: 1)
        XCTAssertEqual(response.objectValue?["decision"]?.stringValue, "decline")
        XCTAssertNil(store.entry(promptID: prompt.promptID))
        XCTAssertThrowsError(try store.resolve(promptID: prompt.promptID, targetIndex: 0))
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
