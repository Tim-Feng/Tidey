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
}
