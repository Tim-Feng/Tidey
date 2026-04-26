import XCTest
@testable import RemoteBridge

final class AgentVendorTests: XCTestCase {
    func testResolveClaudeVendorProvidesSplitSubmitPlan() throws {
        let vendor = try XCTUnwrap(AgentVendorRegistry.resolve(id: "claude"))

        XCTAssertEqual(vendor.id, "claude")
        XCTAssertEqual(vendor.registryDirectoryName, "claude")
        XCTAssertEqual(vendor.submitMessagePlan(text: "hello"), [
            ChatSubmitStep(input: "hello", delayNanoseconds: 0),
            ChatSubmitStep(input: "\r", delayNanoseconds: chatSubmitEnterDelayNanoseconds),
        ])
        XCTAssertNil(vendor.cancelRequestPlan())
    }

    func testResolveCodexVendorProvidesSplitSubmitPlan() throws {
        let vendor = try XCTUnwrap(AgentVendorRegistry.resolve(id: "codex"))

        XCTAssertEqual(vendor.id, "codex")
        XCTAssertEqual(vendor.registryDirectoryName, "codex")
        XCTAssertEqual(vendor.submitMessagePlan(text: "hello"), [
            ChatSubmitStep(input: "hello", delayNanoseconds: 0),
            ChatSubmitStep(input: "\r", delayNanoseconds: chatSubmitEnterDelayNanoseconds),
        ])
        XCTAssertNil(vendor.cancelRequestPlan())
    }

    func testResolveUnknownVendorReturnsNil() {
        XCTAssertNil(AgentVendorRegistry.resolve(id: "unknown"))
    }

    func testVendorCreatesMatchingTranscriptSessionType() throws {
        let record = AgentSessionRegistryRecord(version: 1,
                                                vendor: "codex",
                                                workspaceID: "workspace-1",
                                                sessionID: "session-1",
                                                panelID: "panel-1",
                                                pid: 123,
                                                cwd: "/tmp",
                                                createdAt: "2026-04-14T00:00:00Z",
                                                transcriptPath: nil)
        let hub = AgentEventHub()

        let codexVendor = try XCTUnwrap(AgentVendorRegistry.resolve(id: "codex"))
        let codexSession = codexVendor.makeTranscriptSession(record: record,
                                                             fileManager: .default,
                                                             hub: hub,
                                                             socketClient: nil)
        XCTAssertTrue(codexSession is CodexTranscriptSession)

        let claudeRecord = AgentSessionRegistryRecord(version: 1,
                                                      vendor: "claude",
                                                      workspaceID: "workspace-1",
                                                      sessionID: "session-2",
                                                      panelID: "panel-1",
                                                      pid: 123,
                                                      cwd: "/tmp",
                                                      createdAt: "2026-04-14T00:00:00Z",
                                                      transcriptPath: nil)
        let claudeVendor = try XCTUnwrap(AgentVendorRegistry.resolve(id: "claude"))
        let claudeSession = claudeVendor.makeTranscriptSession(record: claudeRecord,
                                                               fileManager: .default,
                                                               hub: hub,
                                                               socketClient: nil)
        XCTAssertTrue(claudeSession is ClaudeTranscriptSession)
    }
}
