import XCTest
@testable import RemoteBridge

final class AgentSessionLifecycleStoreTests: XCTestCase {
    private func identity(session: String = "session-1",
                          panel: String = "panel-1",
                          workspace: String = "workspace-1") -> AgentSessionLifecycleIdentity {
        AgentSessionLifecycleIdentity(workspaceID: workspace, panelID: panel, sessionID: session)
    }

    func testNormalPromptLifecycleIdleWorkingIdle() {
        let store = AgentSessionLifecycleStore()
        let id = identity()
        var states = [AgentSessionDisplayState]()
        store.onChange = { states.append($0.state) }

        store.beginTurn(id, vendor: "claude", generation: 1)
        XCTAssertEqual(store.snapshot(id)?.state, .working)
        store.endTurn(id, vendor: "claude", generation: 1)
        XCTAssertEqual(store.snapshot(id)?.state, .idle)
        store.waitForDeliveriesForTesting()
        XCTAssertEqual(states, [.working, .idle])
    }

    // An ordinary final response that merely CONTAINS a question is idle —
    // only an explicit blocker makes needs_input.
    func testFinalResponseWithQuestionTextIsIdle() {
        let store = AgentSessionLifecycleStore()
        let id = identity()
        store.beginTurn(id, vendor: "claude", generation: 1)
        store.endTurn(id, vendor: "claude", generation: 1)
        XCTAssertEqual(store.snapshot(id)?.state, .idle)
        XCTAssertTrue(store.snapshot(id)?.blockerIDs.isEmpty ?? false)
    }

    func testPermissionBlockerLifecycleResolveThenTerminal() {
        let store = AgentSessionLifecycleStore()
        let id = identity()
        store.beginTurn(id, vendor: "claude", generation: 1)
        store.openBlocker(id, vendor: "claude", generation: 1,
                          blockerID: "perm:tool-1", kind: .permission)
        XCTAssertEqual(store.snapshot(id)?.state, .needsInput)

        // Resolved (allow) while the turn continues -> working.
        store.resolveBlocker(id, vendor: "claude", generation: 1, blockerID: "perm:tool-1")
        XCTAssertEqual(store.snapshot(id)?.state, .working)

        store.endTurn(id, vendor: "claude", generation: 1)
        XCTAssertEqual(store.snapshot(id)?.state, .idle)
    }

    // Deny/dismiss without an explicit resolve: the turn terminal clears
    // the remaining blocker — no gone-but-blocking ghost.
    func testTurnTerminalClearsUnresolvedBlockers() {
        let store = AgentSessionLifecycleStore()
        let id = identity()
        store.beginTurn(id, vendor: "claude", generation: 1)
        store.openBlocker(id, vendor: "claude", generation: 1,
                          blockerID: "perm:tool-2", kind: .permission)
        XCTAssertEqual(store.snapshot(id)?.state, .needsInput)
        store.endTurn(id, vendor: "claude", generation: 1)
        XCTAssertEqual(store.snapshot(id)?.state, .idle)
        XCTAssertTrue(store.snapshot(id)?.blockerIDs.isEmpty ?? false)
    }

    func testAskUserQuestionLifecycle() {
        let store = AgentSessionLifecycleStore()
        let id = identity()
        store.beginTurn(id, vendor: "claude", generation: 1)
        store.openBlocker(id, vendor: "claude", generation: 1,
                          blockerID: "question:toolu_1", kind: .userQuestion)
        XCTAssertEqual(store.snapshot(id)?.state, .needsInput)
        store.resolveBlocker(id, vendor: "claude", generation: 1, blockerID: "question:toolu_1")
        XCTAssertEqual(store.snapshot(id)?.state, .working)
        store.endTurn(id, vendor: "claude", generation: 1)
        XCTAssertEqual(store.snapshot(id)?.state, .idle)
    }

    func testDuplicateOpenerAndDuplicateTerminalAreIdempotent() {
        let store = AgentSessionLifecycleStore()
        let id = identity()
        var changes = 0
        store.onChange = { _ in changes += 1 }
        store.beginTurn(id, vendor: "claude", generation: 1)
        store.openBlocker(id, vendor: "claude", generation: 1,
                          blockerID: "perm:dup", kind: .permission)
        store.openBlocker(id, vendor: "claude", generation: 1,
                          blockerID: "perm:dup", kind: .permission)
        XCTAssertEqual(store.snapshot(id)?.blockerIDs, ["perm:dup"])
        store.waitForDeliveriesForTesting()
        let changesAfterOpen = changes
        store.endTurn(id, vendor: "claude", generation: 1)
        store.endTurn(id, vendor: "claude", generation: 1)
        XCTAssertEqual(store.snapshot(id)?.state, .idle)
        store.waitForDeliveriesForTesting()
        XCTAssertEqual(changes, changesAfterOpen + 1, "the duplicate terminal publishes nothing")
    }

    func testMultipleBlockersStayNeedsInputUntilAllResolved() {
        let store = AgentSessionLifecycleStore()
        let id = identity()
        store.beginTurn(id, vendor: "codex", generation: 1)
        store.openBlocker(id, vendor: "codex", generation: 1, blockerID: "a", kind: .permission)
        store.openBlocker(id, vendor: "codex", generation: 1, blockerID: "b", kind: .serverRequest)
        store.resolveBlocker(id, vendor: "codex", generation: 1, blockerID: "a")
        XCTAssertEqual(store.snapshot(id)?.state, .needsInput, "one blocker left")
        store.resolveBlocker(id, vendor: "codex", generation: 1, blockerID: "b")
        XCTAssertEqual(store.snapshot(id)?.state, .working)
    }

    // Stale generations may never regress the newer world.
    func testStaleGenerationCannotRegress() {
        let store = AgentSessionLifecycleStore()
        let id = identity()
        store.beginTurn(id, vendor: "codex", generation: 2)
        // Old connection's replay: open + end from generation 1.
        store.openBlocker(id, vendor: "codex", generation: 1, blockerID: "stale", kind: .permission)
        XCTAssertEqual(store.snapshot(id)?.state, .working, "stale opener ignored")
        store.endTurn(id, vendor: "codex", generation: 1)
        XCTAssertEqual(store.snapshot(id)?.state, .working, "stale terminal ignored")
        // A NEWER generation resets and rebuilds.
        store.beginTurn(id, vendor: "codex", generation: 3)
        XCTAssertEqual(store.snapshot(id)?.state, .working)
        XCTAssertEqual(store.snapshot(id)?.generation, 3)
    }

    // Two sessions in the SAME workspace never overwrite each other; the
    // workspace aggregate follows needs_input > working > idle.
    func testTwoSessionsDoNotOverwriteAndAggregatePriority() {
        let store = AgentSessionLifecycleStore()
        let a = identity(session: "session-A", panel: "panel-A")
        let b = identity(session: "session-B", panel: "panel-B")
        store.beginTurn(a, vendor: "claude", generation: 1)
        store.endTurn(a, vendor: "claude", generation: 1)          // A idle
        store.beginTurn(b, vendor: "codex", generation: 1)         // B working
        XCTAssertEqual(store.snapshot(a)?.state, .idle)
        XCTAssertEqual(store.snapshot(b)?.state, .working)
        XCTAssertEqual(store.workspaceState(workspaceID: "workspace-1"), .working)

        store.openBlocker(b, vendor: "codex", generation: 1, blockerID: "p", kind: .permission)
        XCTAssertEqual(store.workspaceState(workspaceID: "workspace-1"), .needsInput)
        XCTAssertEqual(store.panelState(workspaceID: "workspace-1", panelID: "panel-A"), .idle,
                       "panel A keeps its own state")

        store.endTurn(b, vendor: "codex", generation: 1)
        XCTAssertEqual(store.workspaceState(workspaceID: "workspace-1"), .idle)
    }

    // Provider detail (notLoaded / systemError) survives the idle mapping
    // and never covers a still-active session.
    func testDetailPreservedAndEndedSessionExcludedFromAggregate() {
        let store = AgentSessionLifecycleStore()
        let dead = identity(session: "session-dead", panel: "panel-dead")
        let live = identity(session: "session-live", panel: "panel-live")
        store.endSession(dead, vendor: "codex", generation: 1, detail: "systemError: provider notLoaded")
        store.beginTurn(live, vendor: "codex", generation: 1)
        XCTAssertEqual(store.snapshot(dead)?.state, .idle)
        XCTAssertEqual(store.snapshot(dead)?.detail, "systemError: provider notLoaded")
        XCTAssertTrue(store.snapshot(dead)?.ended ?? false)
        XCTAssertEqual(store.workspaceState(workspaceID: "workspace-1"), .working,
                       "the dead session's idle mapping never covers the live one")
    }

    // Codex thread/status/changed level application.
    func testProviderLevelActiveFlagsMapping() {
        let store = AgentSessionLifecycleStore()
        let id = identity(session: "thread-1")
        // active + no flags -> working
        store.applyProviderLevel(id, vendor: "codex", generation: 1,
                                 turnActive: true, blockedBy: [], blockerNamespace: "codex-status:")
        XCTAssertEqual(store.snapshot(id)?.state, .working)
        // active + waitingOnApproval -> needs_input
        store.applyProviderLevel(id, vendor: "codex", generation: 1,
                                 turnActive: true,
                                 blockedBy: [(id: "codex-status:waitingOnApproval", kind: .permission)],
                                 blockerNamespace: "codex-status:")
        XCTAssertEqual(store.snapshot(id)?.state, .needsInput)
        // flags cleared while still active -> working (namespace replaced)
        store.applyProviderLevel(id, vendor: "codex", generation: 1,
                                 turnActive: true, blockedBy: [], blockerNamespace: "codex-status:")
        XCTAssertEqual(store.snapshot(id)?.state, .working)
        // waitingOnUserInput -> needs_input
        store.applyProviderLevel(id, vendor: "codex", generation: 1,
                                 turnActive: true,
                                 blockedBy: [(id: "codex-status:waitingOnUserInput", kind: .userQuestion)],
                                 blockerNamespace: "codex-status:")
        XCTAssertEqual(store.snapshot(id)?.state, .needsInput)
        // idle -> idle and clears everything
        store.applyProviderLevel(id, vendor: "codex", generation: 1,
                                 turnActive: false, blockedBy: [], blockerNamespace: "codex-status:")
        XCTAssertEqual(store.snapshot(id)?.state, .idle)
        XCTAssertTrue(store.snapshot(id)?.blockerIDs.isEmpty ?? false)
    }

    // Reconnect snapshot (thread/read / thread/resume): a NEW generation
    // applies the provider snapshot; the old connection's late events are
    // dropped.
    func testReconnectSnapshotNewGenerationDropsOldConnectionReplay() {
        let store = AgentSessionLifecycleStore()
        let id = identity(session: "thread-2")
        store.applyProviderLevel(id, vendor: "codex", generation: 1,
                                 turnActive: true,
                                 blockedBy: [(id: "codex-status:waitingOnApproval", kind: .permission)],
                                 blockerNamespace: "codex-status:")
        // Reconnect: resume snapshot says idle on generation 2.
        store.applyProviderLevel(id, vendor: "codex", generation: 2,
                                 turnActive: false, blockedBy: [], blockerNamespace: "codex-status:")
        XCTAssertEqual(store.snapshot(id)?.state, .idle)
        // Old connection's replay arrives late: ignored.
        store.applyProviderLevel(id, vendor: "codex", generation: 1,
                                 turnActive: true,
                                 blockedBy: [(id: "codex-status:waitingOnApproval", kind: .permission)],
                                 blockerNamespace: "codex-status:")
        XCTAssertEqual(store.snapshot(id)?.state, .idle, "stale connection cannot regress")
    }

    func testBlockerOnEndedSessionIsIgnored() {
        let store = AgentSessionLifecycleStore()
        let id = identity()
        store.endSession(id, vendor: "claude", generation: 1)
        store.openBlocker(id, vendor: "claude", generation: 1, blockerID: "x", kind: .permission)
        XCTAssertEqual(store.snapshot(id)?.state, .idle)
        XCTAssertTrue(store.snapshot(id)?.blockerIDs.isEmpty ?? false)
    }

    func testCodexThreadStatusMapper() {
        let working = CodexThreadStatusLifecycle.providerLevel(statusType: "active", activeFlags: [])
        XCTAssertEqual(working?.turnActive, true)
        XCTAssertTrue(working?.blockers.isEmpty ?? false)

        let approval = CodexThreadStatusLifecycle.providerLevel(statusType: "active",
                                                                activeFlags: ["waitingOnApproval"])
        XCTAssertEqual(approval?.blockers.map(\.id), ["codex-status:waitingOnApproval"])
        XCTAssertEqual(approval?.blockers.first?.kind, .permission)

        let input = CodexThreadStatusLifecycle.providerLevel(statusType: "active",
                                                             activeFlags: ["waitingOnUserInput"])
        XCTAssertEqual(input?.blockers.first?.kind, .userQuestion)

        let both = CodexThreadStatusLifecycle.providerLevel(statusType: "active",
                                                            activeFlags: ["waitingOnApproval", "waitingOnUserInput"])
        XCTAssertEqual(both?.blockers.count, 2)

        let idle = CodexThreadStatusLifecycle.providerLevel(statusType: "idle", activeFlags: [])
        XCTAssertEqual(idle?.turnActive, false)

        XCTAssertNil(CodexThreadStatusLifecycle.providerLevel(statusType: "mystery", activeFlags: []),
                     "unknown status types change nothing")
    }

    // D16: workspace aggregate transitions with STRICTLY increasing
    // revisions — a finished high-revision session never drags it down.
    func testWorkspaceAggregateTransitionsWithMonotonicRevision() {
        let store = AgentSessionLifecycleStore()
        let a = identity(session: "s-A", panel: "p-A")
        let b = identity(session: "s-B", panel: "p-B")
        store.beginTurn(a, vendor: "claude", generation: 1)                       // A working
        let r1 = store.workspaceAggregate(workspaceID: "workspace-1")
        XCTAssertEqual(r1?.state, .working)
        store.openBlocker(b, vendor: "codex", generation: 1, blockerID: "x", kind: .permission)
        let r2 = store.workspaceAggregate(workspaceID: "workspace-1")
        XCTAssertEqual(r2?.state, .needsInput)
        XCTAssertGreaterThan(r2!.revision, r1!.revision)
        store.endSession(b, vendor: "codex", generation: 1)                        // B ends
        let r3 = store.workspaceAggregate(workspaceID: "workspace-1")
        XCTAssertEqual(r3?.state, .working)
        XCTAssertGreaterThan(r3!.revision, r2!.revision)
        store.endSession(a, vendor: "claude", generation: 1)                       // A ends
        let r4 = store.workspaceAggregate(workspaceID: "workspace-1")
        XCTAssertEqual(r4?.state, .idle, "ended sessions leave an idle aggregate")
        XCTAssertGreaterThan(r4!.revision, r3!.revision)
    }

    // A2/A3: lifecycle changes publish typed patches through the workspace
    // hub, and a late subscriber REPLAYS them (closing the list->subscribe
    // gap); full-entity events are never replayed.
    func testLifecycleEventPublisherEmitsPatchesAndHubReplaysThem() {
        let store = AgentSessionLifecycleStore()
        let hub = WorkspaceEventHub()
        let publisher = AgentLifecycleEventPublisher(store: store, hub: hub)
        publisher.attach()

        let id = identity()
        store.beginTurn(id, vendor: "claude", generation: 1)
        store.openBlocker(id, vendor: "claude", generation: 1,
                          blockerID: "perm:1", kind: .permission)
        store.waitForDeliveriesForTesting()

        // A full-entity event published earlier must NOT replay…
        hub.publish(WorkspaceEvent(eventID: "full-1", seq: 999,
                                   timestamp: "2026-07-18T00:00:00Z",
                                   kind: .workspaceUpdated,
                                   windowGUID: nil,
                                   workspaceID: "workspace-1",
                                   panelID: nil,
                                   workspace: ["workspace_id": .string("workspace-1")],
                                   panel: nil))

        // …but the state patches DO: a subscriber arriving after the fact
        // still sees the needs_input transition.
        let (token, replay) = hub.subscribe(workspaceID: "workspace-1") { _ in }
        defer { hub.unsubscribe(token) }
        XCTAssertFalse(replay.isEmpty, "state patches replay to close the subscribe gap")
        XCTAssertTrue(replay.allSatisfy { $0.event.kind == .panelStateChanged },
                      "full-entity events never replay")
        let last = replay.last!.event
        XCTAssertEqual(last.panel?["state"]?.stringValue, "needs_input")
        XCTAssertNotNil(last.panel?["state_revision"]?.intValue)
        XCTAssertEqual(last.workspace?["state"]?.stringValue, "needs_input")
        XCTAssertTrue(replay.allSatisfy { $0.replay })
    }

    func testAggregateHelperPriority() {
        XCTAssertNil(AgentSessionLifecycleStore.aggregate([]))
        XCTAssertEqual(AgentSessionLifecycleStore.aggregate([.idle, .working]), .working)
        XCTAssertEqual(AgentSessionLifecycleStore.aggregate([.idle, .working, .needsInput]), .needsInput)
        XCTAssertEqual(AgentSessionLifecycleStore.aggregate([.idle, .idle]), .idle)
    }
}
