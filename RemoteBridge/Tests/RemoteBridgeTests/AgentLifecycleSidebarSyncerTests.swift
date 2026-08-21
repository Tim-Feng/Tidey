import XCTest
@testable import RemoteBridge

final class AgentLifecycleSidebarSyncerTests: XCTestCase {
    func testReplaysAuthoritativeIdleWhenTideySocketAppearsAfterBridgeBootstrap() {
        let store = AgentSessionLifecycleStore()
        let sender = CapturingLifecycleSidebarSender()
        var socketIdentity: String?
        let syncer = AgentLifecycleSidebarSyncer(store: store,
                                                 socketIdentityProvider: { socketIdentity },
                                                 commandSender: sender.send)
        let record = Self.record()
        let identity = AgentSessionLifecycleIdentity(workspaceID: record.workspaceID,
                                                     panelID: record.panelID ?? "",
                                                     sessionID: record.sessionID)
        syncer.attach()

        store.claimGeneration(identity, vendor: record.vendor, generation: 1)
        store.waitForDeliveriesForTesting()
        syncer.sync(records: [record])
        XCTAssertTrue(sender.commands.isEmpty)

        socketIdentity = "tidey-socket-generation-1"
        syncer.sync(records: [record])

        XCTAssertEqual(sender.commands, [
            "report_shell_state prompt --workspace_id=workspace-1 --panel_id=panel-1 --session_id=session-1",
        ])

        syncer.sync(records: [record])
        XCTAssertEqual(sender.commands.count, 1,
                       "an unchanged state must not be resent while the Tidey socket generation is unchanged")

        socketIdentity = "tidey-socket-generation-2"
        syncer.sync(records: [record])
        XCTAssertEqual(sender.commands.count, 2,
                       "a replacement Tidey app owns a new in-memory status store and needs one replay")
    }

    private static func record() -> AgentSessionRegistryRecord {
        AgentSessionRegistryRecord(version: 1,
                                   vendor: "claude",
                                   workspaceID: "workspace-1",
                                   sessionID: "session-1",
                                   panelID: "panel-1",
                                   pid: 123,
                                   cwd: "/tmp",
                                   createdAt: "2026-08-21T00:00:00Z",
                                   transcriptPath: nil)
    }
}

private final class CapturingLifecycleSidebarSender {
    private(set) var commands = [String]()

    func send(_ command: String) throws {
        commands.append(command)
    }
}
