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
            #"{"action":"clear_status","key":"shell_state","workspace_id":"workspace-1"}"#,
            #"{"action":"report_shell_state","panel_id":"panel-1","session_id":"session-1","state":"prompt","workspace_id":"workspace-1"}"#,
        ])

        syncer.sync(records: [record])
        XCTAssertEqual(sender.commands.count, 2,
                       "an unchanged state must not be resent while the Tidey socket generation is unchanged")

        socketIdentity = "tidey-socket-generation-2"
        syncer.sync(records: [record])
        XCTAssertEqual(sender.commands.count, 4,
                       "a replacement Tidey app owns a new in-memory status store and needs one replay")
    }

    func testClearsLegacyWorkspaceCellBeforeReplayingOwnersForNewSocketGeneration() {
        let store = AgentSessionLifecycleStore()
        let sender = CapturingLifecycleSidebarSender()
        let syncer = AgentLifecycleSidebarSyncer(store: store,
                                                 socketIdentityProvider: { "tidey-socket-generation-1" },
                                                 commandSender: sender.send)
        let firstRecord = Self.record()
        let secondRecord = Self.record(sessionID: "session-2", panelID: "panel-2", pid: 124)
        syncer.attach()
        for record in [firstRecord, secondRecord] {
            let identity = AgentSessionLifecycleIdentity(workspaceID: record.workspaceID,
                                                         panelID: record.panelID ?? "",
                                                         sessionID: record.sessionID)
            store.claimGeneration(identity, vendor: record.vendor, generation: 1)
        }
        store.waitForDeliveriesForTesting()

        syncer.sync(records: [secondRecord, firstRecord])

        XCTAssertEqual(sender.commands, [
            #"{"action":"clear_status","key":"shell_state","workspace_id":"workspace-1"}"#,
            #"{"action":"report_shell_state","panel_id":"panel-1","session_id":"session-1","state":"prompt","workspace_id":"workspace-1"}"#,
            #"{"action":"report_shell_state","panel_id":"panel-2","session_id":"session-2","state":"prompt","workspace_id":"workspace-1"}"#,
        ])
    }

    func testRetriesFailedWorkspaceResetOnNextSyncAndConverges() {
        let store = AgentSessionLifecycleStore()
        let sender = CapturingLifecycleSidebarSender(failuresRemaining: 1)
        let syncer = AgentLifecycleSidebarSyncer(store: store,
                                                 socketIdentityProvider: { "tidey-socket-generation-1" },
                                                 commandSender: sender.send)
        let record = Self.record()
        syncer.attach()
        let identity = AgentSessionLifecycleIdentity(workspaceID: record.workspaceID,
                                                     panelID: record.panelID ?? "",
                                                     sessionID: record.sessionID)
        store.claimGeneration(identity, vendor: record.vendor, generation: 1)
        store.waitForDeliveriesForTesting()

        syncer.sync(records: [record])
        syncer.sync(records: [record])
        syncer.sync(records: [record])

        XCTAssertEqual(sender.commands, [
            #"{"action":"clear_status","key":"shell_state","workspace_id":"workspace-1"}"#,
            #"{"action":"clear_status","key":"shell_state","workspace_id":"workspace-1"}"#,
            #"{"action":"report_shell_state","panel_id":"panel-1","session_id":"session-1","state":"prompt","workspace_id":"workspace-1"}"#,
        ])
    }

    // Receiver state can be lost while the sender's state is unchanged, e.g. by another writer's
    // owner-less workspace reset (a second Bridge process on 2026-09-25 is a candidate; its
    // receipt was not traced). A low-frequency reassertion on the existing sync cadence restores
    // it; outcomes are asserted on the decoded receiver store.
    func testReassertsUnchangedOwnerStateAfterReceiverLosesIt() {
        let store = AgentSessionLifecycleStore()
        let receiver = DecodingStatusReceiver()
        var now: TimeInterval = 1_000
        let syncer = AgentLifecycleSidebarSyncer(store: store,
                                                 socketIdentityProvider: { "tidey-socket-generation-1" },
                                                 commandSender: receiver.apply,
                                                 monotonicNow: { now })
        let working = Self.record(sessionID: "session-1", panelID: "panel-1", pid: 1)
        let idle = Self.record(sessionID: "session-2", panelID: "panel-2", pid: 2)
        let blocked = Self.record(sessionID: "session-3", panelID: "panel-3", pid: 3)
        syncer.attach()
        for record in [working, idle, blocked] {
            store.claimGeneration(Self.identity(record), vendor: record.vendor, generation: 1)
        }
        store.beginTurn(Self.identity(working), vendor: "claude", generation: 1, turnID: "t1")
        store.waitForDeliveriesForTesting()
        syncer.sync(records: [working, idle, blocked])
        XCTAssertEqual(receiver.workspaceValue("workspace-1"), "Running")
        XCTAssertEqual(receiver.ownerValues("workspace-1"),
                       ["session-1": "Running", "session-2": "Idle", "session-3": "Idle"])

        store.openBlocker(Self.identity(blocked), vendor: "claude", generation: 1,
                          blockerID: "permission:1", kind: .permission)
        store.waitForDeliveriesForTesting()
        XCTAssertEqual(receiver.workspaceValue("workspace-1"), "Needs input",
                       "a state change still delivers immediately")

        receiver.externalOwnerlessReset("workspace-1")
        now += 10
        syncer.sync(records: [working, idle, blocked])
        XCTAssertNil(receiver.workspaceValue("workspace-1"), "no replay before the reassertion interval")

        now += 21
        syncer.sync(records: [working, idle, blocked])
        XCTAssertEqual(receiver.ownerValues("workspace-1"),
                       ["session-1": "Running", "session-2": "Idle", "session-3": "Needs input"])
        XCTAssertEqual(receiver.workspaceValue("workspace-1"), "Needs input")
    }

    func testEndedOwnerIsNeverReplayedAsRunning() {
        let store = AgentSessionLifecycleStore()
        let receiver = DecodingStatusReceiver()
        var now: TimeInterval = 1_000
        let syncer = AgentLifecycleSidebarSyncer(store: store,
                                                 socketIdentityProvider: { "tidey-socket-generation-1" },
                                                 commandSender: receiver.apply,
                                                 monotonicNow: { now })
        let record = Self.record()
        syncer.attach()
        store.claimGeneration(Self.identity(record), vendor: record.vendor, generation: 1)
        store.beginTurn(Self.identity(record), vendor: "claude", generation: 1, turnID: "t1")
        store.waitForDeliveriesForTesting()
        syncer.sync(records: [record])
        XCTAssertEqual(receiver.workspaceValue("workspace-1"), "Running")

        store.retireSession(Self.identity(record), generation: 1)
        store.waitForDeliveriesForTesting()
        XCTAssertNil(receiver.workspaceValue("workspace-1"))
        for _ in 0..<3 {
            now += 31
            syncer.sync(records: [record])
            XCTAssertNil(receiver.workspaceValue("workspace-1"))
        }
        syncer.sync(records: [])
        now += 31
        syncer.sync(records: [])
        XCTAssertNil(receiver.workspaceValue("workspace-1"))
    }

    func testOwnerIdentityWithSpacesIsDeliveredExactly() {
        let store = AgentSessionLifecycleStore()
        let receiver = DecodingStatusReceiver()
        let syncer = AgentLifecycleSidebarSyncer(store: store,
                                                 socketIdentityProvider: { "tidey-socket-generation-1" },
                                                 commandSender: receiver.apply)
        let panelID = "ordinary-tmux:/Users/timfeng/Library/Application Support/Tidey/Runtime/tmux-a.sock:%3"
        let record = Self.record(panelID: panelID)
        syncer.attach()
        store.claimGeneration(Self.identity(record), vendor: record.vendor, generation: 1)
        store.beginTurn(Self.identity(record), vendor: "claude", generation: 1, turnID: "t1")
        store.waitForDeliveriesForTesting()
        syncer.sync(records: [record])
        XCTAssertEqual(receiver.ownerValues("workspace-1"), ["session-1": "Running"])
        XCTAssertEqual(receiver.lastPanelID, panelID)
    }

    // Managed app-server Codex: producer (CodexLifecycleFeed, identity = registry workspace/panel/
    // session) -> lifecycle store -> this syncer (owner = session_id) -> decoded receiver. A
    // turn/completed of any status (completed, interrupted, failed) ends the turn; retirement
    // clears the owner; a late callback of the retired generation cannot resurrect Running.
    func testManagedCodexTurnsNeverLeaveRunningAfterCompletionInterruptOrRetire() {
        let store = AgentSessionLifecycleStore()
        let receiver = DecodingStatusReceiver()
        var now: TimeInterval = 1_000
        let syncer = AgentLifecycleSidebarSyncer(store: store,
                                                 socketIdentityProvider: { "tidey-socket-generation-1" },
                                                 commandSender: receiver.apply,
                                                 monotonicNow: { now })
        let record = AgentSessionRegistryRecord(version: 1, vendor: "codex", workspaceID: "workspace-1",
                                                sessionID: "codex-session", panelID: "panel-c", pid: 9,
                                                cwd: "/tmp", createdAt: "2026-09-25T00:00:00Z",
                                                transcriptPath: nil, runtime: "codex_app_server")
        syncer.attach()
        let feed = CodexLifecycleFeed(identity: Self.identity(record), rootThreadID: { "thread-root" }, store: store)
        store.waitForDeliveriesForTesting()
        syncer.sync(records: [record])
        XCTAssertEqual(receiver.ownerValues("workspace-1"), ["codex-session": "Idle"])

        feed.applyTurnStarted(threadID: "thread-root", turnID: "turn-1")
        store.waitForDeliveriesForTesting()
        XCTAssertEqual(receiver.workspaceValue("workspace-1"), "Running")
        feed.applyTurnCompleted(threadID: "thread-root", turnID: "turn-1")  // completed or interrupted
        store.waitForDeliveriesForTesting()
        XCTAssertEqual(receiver.workspaceValue("workspace-1"), "Idle")

        feed.applyTurnStarted(threadID: "thread-root", turnID: "turn-2")
        store.waitForDeliveriesForTesting()
        XCTAssertEqual(receiver.workspaceValue("workspace-1"), "Running")
        feed.retire()  // transport closed mid-turn: no turn/completed will ever arrive
        store.waitForDeliveriesForTesting()
        XCTAssertNil(receiver.workspaceValue("workspace-1"))
        feed.applyTurnStarted(threadID: "thread-root", turnID: "turn-late")
        store.waitForDeliveriesForTesting()
        now += 31
        syncer.sync(records: [record])
        XCTAssertNil(receiver.workspaceValue("workspace-1"), "a late callback of a retired generation stays inert")

        let replacement = CodexLifecycleFeed(identity: Self.identity(record), rootThreadID: { "thread-root" }, store: store)
        store.waitForDeliveriesForTesting()
        syncer.sync(records: [record])
        XCTAssertEqual(receiver.ownerValues("workspace-1"), ["codex-session": "Idle"],
                       "the replacement generation publishes its own authoritative state")
        feed.applyTurnStarted(threadID: "thread-root", turnID: "turn-stale")
        store.waitForDeliveriesForTesting()
        XCTAssertEqual(receiver.workspaceValue("workspace-1"), "Idle", "the old generation cannot drive the new one")
        replacement.applyTurnStarted(threadID: "thread-root", turnID: "turn-3")
        store.waitForDeliveriesForTesting()
        XCTAssertEqual(receiver.workspaceValue("workspace-1"), "Running")
    }

    private static func identity(_ record: AgentSessionRegistryRecord) -> AgentSessionLifecycleIdentity {
        AgentSessionLifecycleIdentity(workspaceID: record.workspaceID,
                                      panelID: record.panelID ?? "",
                                      sessionID: record.sessionID)
    }

    private static func record(sessionID: String = "session-1",
                               panelID: String = "panel-1",
                               pid: Int32 = 123) -> AgentSessionRegistryRecord {
        AgentSessionRegistryRecord(version: 1,
                                   vendor: "claude",
                                   workspaceID: "workspace-1",
                                   sessionID: sessionID,
                                   panelID: panelID,
                                   pid: pid,
                                   cwd: "/tmp",
                                   createdAt: "2026-08-21T00:00:00Z",
                                   transcriptPath: nil)
    }
}

private final class CapturingLifecycleSidebarSender {
    private(set) var commands = [String]()
    private var failuresRemaining: Int

    init(failuresRemaining: Int = 0) {
        self.failuresRemaining = failuresRemaining
    }

    func send(_ command: String) throws {
        commands.append(command)
        if failuresRemaining > 0 {
            failuresRemaining -= 1
            throw POSIXError(.ECONNREFUSED)
        }
    }
}

/// Test receiver with TideyStatusStore / TideySocketCommandDecoder semantics for shell_state:
/// owner = session_id, else panel_id, else the owner-less cell; an owner-less clear removes every
/// owner; the workspace shows the highest-ranked owner (Needs input > Running > Idle). The real
/// native decoder/store is exercised by the task-local harness for the same JSON commands.
private final class DecodingStatusReceiver {
    private var cells = [String: [String: String]]()
    private(set) var lastPanelID: String?

    func apply(_ command: String) throws {
        guard let object = try JSONSerialization.jsonObject(with: Data(command.utf8)) as? [String: String],
              let workspace = object["workspace_id"] else {
            XCTFail("undecodable command \(command)")
            return
        }
        lastPanelID = object["panel_id"] ?? lastPanelID
        let owner = object["session_id"] ?? object["panel_id"]
        switch object["action"] {
        case "report_shell_state":
            let value = ["running": "Running", "needs_input": "Needs input", "prompt": "Idle"][object["state"] ?? ""]
            guard let value else { return XCTFail("unknown state in \(command)") }
            cells[workspace, default: [:]][owner ?? ""] = value
        case "clear_status":
            if let owner { cells[workspace]?[owner] = nil } else { cells[workspace] = nil }
        default:
            XCTFail("unexpected command \(command)")
        }
    }

    func externalOwnerlessReset(_ workspace: String) {
        cells[workspace] = nil
    }

    func ownerValues(_ workspace: String) -> [String: String] {
        cells[workspace] ?? [:]
    }

    func workspaceValue(_ workspace: String) -> String? {
        let rank = ["Needs input": 3, "Running": 2, "Idle": 1]
        return ownerValues(workspace).values.max { rank[$0, default: 0] < rank[$1, default: 0] }
    }
}
