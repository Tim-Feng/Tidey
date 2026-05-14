import XCTest
@testable import RemoteBridge

final class ChatSubmitEchoRegistryTests: XCTestCase {
    func testConsumesMatchingClientRequestIDForSamePanelSessionAndVendor() {
        var now = Date(timeIntervalSince1970: 100)
        let registry = ChatSubmitEchoRegistry(ttl: 600, now: { now })
        registry.register(workspaceID: "workspace-1",
                          panelID: "panel-1",
                          sessionID: "session-1",
                          vendor: "codex",
                          text: "@/tmp/image.jpg\n\n這是測試",
                          clientRequestID: "local-1")

        now = Date(timeIntervalSince1970: 110)
        let clientRequestID = registry.consumeClientRequestID(workspaceID: "workspace-1",
                                                              panelID: "panel-1",
                                                              sessionID: "session-1",
                                                              vendor: "codex",
                                                              text: "@/tmp/image.jpg\r\n\r\n這是測試")

        XCTAssertEqual(clientRequestID, "local-1")
        XCTAssertTrue(registry.snapshot().isEmpty)
    }

    func testDoesNotMatchAcrossPanelSessionOrVendor() {
        let registry = ChatSubmitEchoRegistry()
        registry.register(workspaceID: "workspace-1",
                          panelID: "panel-1",
                          sessionID: "session-1",
                          vendor: "codex",
                          text: "hello",
                          clientRequestID: "local-1")

        XCTAssertNil(registry.consumeClientRequestID(workspaceID: "workspace-1",
                                                     panelID: "panel-2",
                                                     sessionID: "session-1",
                                                     vendor: "codex",
                                                     text: "hello"))
        XCTAssertNil(registry.consumeClientRequestID(workspaceID: "workspace-1",
                                                     panelID: "panel-1",
                                                     sessionID: "session-2",
                                                     vendor: "codex",
                                                     text: "hello"))
        XCTAssertNil(registry.consumeClientRequestID(workspaceID: "workspace-1",
                                                     panelID: "panel-1",
                                                     sessionID: "session-1",
                                                     vendor: "claude",
                                                     text: "hello"))
        XCTAssertEqual(registry.snapshot().count, 1)
    }

    func testExpiredEntriesAreNotMatched() {
        var now = Date(timeIntervalSince1970: 100)
        let registry = ChatSubmitEchoRegistry(ttl: 10, now: { now })
        registry.register(workspaceID: "workspace-1",
                          panelID: "panel-1",
                          sessionID: "session-1",
                          vendor: "claude",
                          text: "hello",
                          clientRequestID: "local-1")

        now = Date(timeIntervalSince1970: 111)

        XCTAssertNil(registry.consumeClientRequestID(workspaceID: "workspace-1",
                                                     panelID: "panel-1",
                                                     sessionID: "session-1",
                                                     vendor: "claude",
                                                     text: "hello"))
        XCTAssertTrue(registry.snapshot().isEmpty)
    }
}
