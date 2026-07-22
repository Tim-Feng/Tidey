import XCTest
@testable import RemoteBridge

final class ChatSubmitEchoRegistryTests: XCTestCase {
    func testBeginSubmissionSuppressesDuplicateClientRequestIDForSamePanelSessionAndVendor() {
        var now = Date(timeIntervalSince1970: 100)
        let registry = ChatSubmitEchoRegistry(ttl: 600, now: { now })

        XCTAssertEqual(registry.beginSubmission(workspaceID: "workspace-1",
                                                panelID: "panel-1",
                                                sessionID: "session-1",
                                                vendor: "codex",
                                                clientRequestID: "local-1"), .started)

        now = Date(timeIntervalSince1970: 105)
        XCTAssertEqual(registry.beginSubmission(workspaceID: "workspace-1",
                                                panelID: "panel-1",
                                                sessionID: "session-1",
                                                vendor: "codex",
                                                clientRequestID: "local-1"), .duplicate(.pending))
    }

    func testDeliveredSubmissionReportsDeliveredDuplicate() {
        let registry = ChatSubmitEchoRegistry()
        XCTAssertEqual(registry.beginSubmission(workspaceID: "workspace-1",
                                                panelID: "panel-1",
                                                sessionID: "session-1",
                                                vendor: "codex",
                                                clientRequestID: "local-1"), .started)

        registry.markDelivered(workspaceID: "workspace-1",
                               panelID: "panel-1",
                               sessionID: "session-1",
                               vendor: "codex",
                               clientRequestID: "local-1")

        XCTAssertEqual(registry.beginSubmission(workspaceID: "workspace-1",
                                                panelID: "panel-1",
                                                sessionID: "session-1",
                                                vendor: "codex",
                                                clientRequestID: "local-1"), .duplicate(.delivered))
    }

    func testIndeterminateSubmissionReportsIndeterminateDuplicate() {
        let registry = ChatSubmitEchoRegistry()
        XCTAssertEqual(registry.beginSubmission(workspaceID: "workspace-1",
                                                panelID: "panel-1",
                                                sessionID: "session-1",
                                                vendor: "codex",
                                                clientRequestID: "local-1"), .started)

        registry.markIndeterminate(workspaceID: "workspace-1",
                                   panelID: "panel-1",
                                   sessionID: "session-1",
                                   vendor: "codex",
                                   clientRequestID: "local-1")

        XCTAssertEqual(registry.beginSubmission(workspaceID: "workspace-1",
                                                panelID: "panel-1",
                                                sessionID: "session-1",
                                                vendor: "codex",
                                                clientRequestID: "local-1"), .duplicate(.indeterminate))
    }

    func testCancelledSubmissionCanBeginAgain() {
        let registry = ChatSubmitEchoRegistry()
        XCTAssertEqual(registry.beginSubmission(workspaceID: "workspace-1",
                                                panelID: "panel-1",
                                                sessionID: "session-1",
                                                vendor: "codex",
                                                clientRequestID: "local-1"), .started)

        registry.cancelSubmission(workspaceID: "workspace-1",
                                  panelID: "panel-1",
                                  sessionID: "session-1",
                                  vendor: "codex",
                                  clientRequestID: "local-1")

        XCTAssertEqual(registry.beginSubmission(workspaceID: "workspace-1",
                                                panelID: "panel-1",
                                                sessionID: "session-1",
                                                vendor: "codex",
                                                clientRequestID: "local-1"), .started)
    }

    func testBeginSubmissionAllowsSameClientRequestIDAcrossDifferentPanelSessionOrVendor() {
        let registry = ChatSubmitEchoRegistry()
        XCTAssertEqual(registry.beginSubmission(workspaceID: "workspace-1",
                                               panelID: "panel-1",
                                               sessionID: "session-1",
                                               vendor: "codex",
                                               clientRequestID: "local-1"), .started)

        XCTAssertEqual(registry.beginSubmission(workspaceID: "workspace-1",
                                               panelID: "panel-2",
                                               sessionID: "session-1",
                                               vendor: "codex",
                                               clientRequestID: "local-1"), .started)
        XCTAssertEqual(registry.beginSubmission(workspaceID: "workspace-1",
                                               panelID: "panel-1",
                                               sessionID: "session-2",
                                               vendor: "codex",
                                               clientRequestID: "local-1"), .started)
        XCTAssertEqual(registry.beginSubmission(workspaceID: "workspace-1",
                                               panelID: "panel-1",
                                               sessionID: "session-1",
                                               vendor: "claude",
                                               clientRequestID: "local-1"), .started)
    }

    func testExpiredSubmissionCanBeRegisteredAgain() {
        var now = Date(timeIntervalSince1970: 100)
        let registry = ChatSubmitEchoRegistry(ttl: 10, now: { now })
        XCTAssertEqual(registry.beginSubmission(workspaceID: "workspace-1",
                                               panelID: "panel-1",
                                               sessionID: "session-1",
                                               vendor: "codex",
                                               clientRequestID: "local-1"), .started)

        now = Date(timeIntervalSince1970: 111)
        XCTAssertEqual(registry.beginSubmission(workspaceID: "workspace-1",
                                               panelID: "panel-1",
                                               sessionID: "session-1",
                                               vendor: "codex",
                                               clientRequestID: "local-1"), .started)
    }

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
