import XCTest
@testable import RemoteBridge

final class InteractivePromptSubmitDeduperScopeTests: XCTestCase {
    func testScopedAPIKeepsTheSameScopeDuplicateContract() {
        let deduper = InteractivePromptSubmitDeduper()
        let scope = InteractivePromptSubmitScope(workspaceID: "workspace-1",
                                                 panelID: "panel-1",
                                                 sessionID: "session-1",
                                                 vendor: "codex")
        let result: [String: JSONValue] = ["status": .string("already_resolved")]

        deduper.store(scope: scope,
                      clientRequestID: "client-1",
                      promptID: "prompt-1",
                      decision: "index:1",
                      result: result)

        guard case .duplicate(let cached) = deduper.check(scope: scope,
                                                          clientRequestID: "client-1",
                                                          promptID: "prompt-1",
                                                          decision: "index:1") else {
            return XCTFail("expected a duplicate in the same agent scope")
        }
        XCTAssertEqual(cached["status"]?.stringValue, "already_resolved")
    }

    func testSameClientRequestIDIsIndependentAcrossEveryAgentScopeDimension() {
        let deduper = InteractivePromptSubmitDeduper()
        let scopes = [
            InteractivePromptSubmitScope(workspaceID: "workspace-1", panelID: "panel-1", sessionID: "session-1", vendor: "codex"),
            InteractivePromptSubmitScope(workspaceID: "workspace-2", panelID: "panel-1", sessionID: "session-1", vendor: "codex"),
            InteractivePromptSubmitScope(workspaceID: "workspace-1", panelID: "panel-2", sessionID: "session-1", vendor: "codex"),
            InteractivePromptSubmitScope(workspaceID: "workspace-1", panelID: "panel-1", sessionID: "session-2", vendor: "codex"),
            InteractivePromptSubmitScope(workspaceID: "workspace-1", panelID: "panel-1", sessionID: "session-1", vendor: "claude"),
        ]

        for (index, scope) in scopes.enumerated() {
            guard case .new = deduper.check(scope: scope,
                                            clientRequestID: "client-reused",
                                            promptID: "prompt-\(index)",
                                            decision: "index:\(index)") else {
                return XCTFail("scope \(index) collided with another agent scope")
            }
            deduper.store(scope: scope,
                          clientRequestID: "client-reused",
                          promptID: "prompt-\(index)",
                          decision: "index:\(index)",
                          result: ["scope_index": .number(Double(index))])
        }

        for (index, scope) in scopes.enumerated() {
            guard case .duplicate(let cached) = deduper.check(scope: scope,
                                                              clientRequestID: "client-reused",
                                                              promptID: "prompt-\(index)",
                                                              decision: "index:\(index)") else {
                return XCTFail("scope \(index) did not retain its own result")
            }
            XCTAssertEqual(cached["scope_index"]?.intValue, index)
        }
    }
}
