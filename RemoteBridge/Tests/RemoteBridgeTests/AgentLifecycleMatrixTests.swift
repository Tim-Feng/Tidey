import XCTest
@testable import RemoteBridge

// Round-2 matrix additions: migration generation guard (midreview 4),
// ordinary-tmux style identity migration without ghost aggregates (D15),
// concurrent delivery monotonicity (D4), and the list augmenter emitting
// the SAME aggregate the store holds (D13).
final class AgentLifecycleMatrixTests: XCTestCase {

    private func identity(_ panel: String, session: String) -> AgentSessionLifecycleIdentity {
        AgentSessionLifecycleIdentity(workspaceID: "ws", panelID: panel, sessionID: session)
    }

    // MARK: - Midreview 4: migration must not regress a newer destination

    func testMigrationDoesNotRegressNewerDestinationGeneration() {
        let store = AgentSessionLifecycleStore()
        let old = identity("panel-old", session: "s1")
        let new = identity("panel-new", session: "s1")

        // Old identity: generation 5, blocked.
        store.beginTurn(old, vendor: "codex", generation: 5)
        store.openBlocker(old, vendor: "codex", generation: 5, blockerID: "b1", kind: .permission)
        // Destination already owned by a NEWER world: generation 9, working.
        store.beginTurn(new, vendor: "codex", generation: 9, turnID: "t9")

        store.migrateSession(from: old, to: new)
        store.waitForDeliveriesForTesting()

        // Destination kept its newer state; old identity is retired.
        let destination = store.snapshot(new)
        XCTAssertEqual(destination?.state, .working)
        XCTAssertEqual(destination?.generation, 9)
        XCTAssertEqual(store.snapshot(old)?.ended, true)
        // Aggregate for the old panel vanishes (retired, no ghost).
        XCTAssertNil(store.panelAggregate(workspaceID: "ws", panelID: "panel-old"))
    }

    func testMigrationOldSourceEqualsNewIsATrueNoOp() {
        let store = AgentSessionLifecycleStore()
        let same = identity("panel-1", session: "s1")
        store.openBlocker(same, vendor: "claude", generation: 1, blockerID: "b1", kind: .permission)
        store.waitForDeliveriesForTesting()
        let before = store.snapshot(same)

        store.migrateSession(from: same, to: same)
        store.waitForDeliveriesForTesting()

        let after = store.snapshot(same)
        XCTAssertEqual(after?.revision, before?.revision, "old==new migration must not touch anything")
        XCTAssertEqual(after?.state, .needsInput)
        XCTAssertEqual(after?.ended, false)
    }

    func testMigrationRejectsStaleSourceGenerationAssumption() {
        let store = AgentSessionLifecycleStore()
        let old = identity("panel-old", session: "s1")
        let new = identity("panel-new", session: "s1")

        // Caller observed generation 3 for `old`...
        store.beginTurn(old, vendor: "claude", generation: 3)
        // ...but the identity has SINCE moved to generation 5 (a fresh
        // connection/epoch claimed it) before the caller's migrate call
        // actually runs.
        store.beginTurn(old, vendor: "claude", generation: 5, turnID: "t5")
        store.openBlocker(old, vendor: "claude", generation: 5, blockerID: "b", kind: .permission)

        store.migrateSession(from: old, to: new, expectedGeneration: 3)
        store.waitForDeliveriesForTesting()

        // The stale-generation migration must be rejected outright: `old`
        // keeps its CURRENT (gen5) record, untouched, and `new` never
        // gets created.
        XCTAssertEqual(store.snapshot(old)?.generation, 5)
        XCTAssertEqual(store.snapshot(old)?.state, .needsInput)
        XCTAssertEqual(store.snapshot(old)?.ended, false)
        XCTAssertNil(store.snapshot(new))
    }

    func testMigrationRejectsIntoARetiredNewerGenerationTombstone() {
        let store = AgentSessionLifecycleStore()
        let old = identity("panel-old", session: "s1")
        let new = identity("panel-new", session: "s1")

        // Destination was already retired at a NEWER generation (gen9).
        store.beginTurn(new, vendor: "claude", generation: 9)
        store.retireSession(new, generation: 9)
        XCTAssertEqual(store.snapshot(new)?.ended, true)

        // A stale gen5 migration must not resurrect it.
        store.beginTurn(old, vendor: "claude", generation: 5)
        store.migrateSession(from: old, to: new)
        store.waitForDeliveriesForTesting()

        let destination = store.snapshot(new)
        XCTAssertEqual(destination?.ended, true, "a retired newer-generation tombstone was resurrected")
        XCTAssertEqual(destination?.generation, 9)
    }

    func testMigrationMovesStateWhenDestinationIsAbsent() {
        let store = AgentSessionLifecycleStore()
        let old = identity("carrier", session: "s1")
        let new = identity("w1:1", session: "s1")

        store.beginTurn(old, vendor: "claude", generation: 3)
        store.openBlocker(old, vendor: "claude", generation: 3, blockerID: "q1", kind: .userQuestion)
        store.migrateSession(from: old, to: new)
        store.waitForDeliveriesForTesting()

        XCTAssertEqual(store.snapshot(new)?.state, .needsInput)
        XCTAssertNil(store.panelAggregate(workspaceID: "ws", panelID: "carrier"),
                     "carrier identity must not leave a ghost aggregate")
        XCTAssertEqual(store.panelAggregate(workspaceID: "ws", panelID: "w1:1")?.state, .needsInput)
    }

    // MARK: - D15: single -> multi window logical panels stay independent

    func testCarrierSplitLeavesIndependentLogicalPanelStates() {
        let store = AgentSessionLifecycleStore()
        let carrier = identity("carrier", session: "s1")
        store.beginTurn(carrier, vendor: "claude", generation: 1)

        // The carrier's session moves to logical panel w:1; a second agent
        // session appears on logical panel w:2.
        store.migrateSession(from: carrier, to: identity("w:1", session: "s1"))
        store.openBlocker(identity("w:2", session: "s2"), vendor: "codex", generation: 2,
                          blockerID: "b", kind: .permission)
        store.waitForDeliveriesForTesting()

        XCTAssertEqual(store.panelAggregate(workspaceID: "ws", panelID: "w:1")?.state, .working)
        XCTAssertEqual(store.panelAggregate(workspaceID: "ws", panelID: "w:2")?.state, .needsInput)
        XCTAssertNil(store.panelAggregate(workspaceID: "ws", panelID: "carrier"))
        XCTAssertEqual(store.workspaceAggregate(workspaceID: "ws")?.state, .needsInput)
    }

    // MARK: - D4: concurrent mutations deliver monotonic revisions

    func testConcurrentMutationsDeliverMonotonicRevisions() {
        let store = AgentSessionLifecycleStore()
        let lock = NSLock()
        var observedRevisions: [Int] = []
        store.addObserver { snapshot in
            lock.lock()
            observedRevisions.append(snapshot.revision)
            lock.unlock()
        }

        let group = DispatchGroup()
        let queue = DispatchQueue(label: "stress", attributes: .concurrent)
        for worker in 0..<8 {
            group.enter()
            queue.async {
                defer { group.leave() }
                let id = self.identity("panel-\(worker)", session: "session-\(worker)")
                for round in 0..<50 {
                    store.beginTurn(id, vendor: "claude", generation: 1, turnID: "t\(round)")
                    store.openBlocker(id, vendor: "claude", generation: 1,
                                      blockerID: "b\(round)", kind: .permission)
                    store.resolveBlocker(id, vendor: "claude", generation: 1, blockerID: "b\(round)")
                    store.endTurn(id, vendor: "claude", generation: 1, turnID: "t\(round)")
                }
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 20), .success)
        store.waitForDeliveriesForTesting()

        lock.lock()
        let revisions = observedRevisions
        lock.unlock()
        XCTAssertFalse(revisions.isEmpty)
        // FIFO delivery in revision order: a consumer can never observe a
        // regression.
        XCTAssertEqual(revisions, revisions.sorted(),
                       "delivery order regressed: consumers would flicker backwards")
        XCTAssertEqual(Set(revisions).count, revisions.count, "duplicate revision deliveries")
    }

    // MARK: - D13: list augmentation carries the store's exact aggregate

    func testAugmenterEmitsSameAggregateStateAndRevisionAsStore() {
        let store = AgentSessionLifecycleStore()
        let id = identity("panel-1", session: "s1")
        store.beginTurn(id, vendor: "codex", generation: 1)
        store.openBlocker(id, vendor: "codex", generation: 1, blockerID: "b", kind: .permission)
        store.waitForDeliveriesForTesting()

        let panelAggregate = store.panelAggregate(workspaceID: "ws", panelID: "panel-1")
        let augmentedPanel = AgentLifecycleListAugmenter.augmentPanel([
            "panel_id": .string("panel-1"),
            "title": .string("build"),
            "state": .string("running"),
        ], workspaceID: "ws", panelID: "panel-1", hasAgentSession: true, store: store)
        XCTAssertEqual(augmentedPanel["state"]?.stringValue, panelAggregate?.state.rawValue)
        XCTAssertEqual(augmentedPanel["state_revision"]?.intValue, panelAggregate?.revision)
        XCTAssertEqual(augmentedPanel["title"]?.stringValue, "build", "augmentation must not drop fields")

        let workspaceAggregate = store.workspaceAggregate(workspaceID: "ws")
        let augmentedWorkspace = AgentLifecycleListAugmenter.augmentWorkspace([
            "workspace_id": .string("ws"),
            "state": .string("idle"),
        ], workspaceID: "ws", store: store)
        XCTAssertEqual(augmentedWorkspace["state"]?.stringValue, workspaceAggregate?.state.rawValue)
        XCTAssertEqual(augmentedWorkspace["state_revision"]?.intValue, workspaceAggregate?.revision)

        // Known agent session with NO lifecycle data: conservative idle.
        let unknownPanel = AgentLifecycleListAugmenter.augmentPanel([
            "panel_id": .string("panel-x"),
            "state": .string("running"),
        ], workspaceID: "ws", panelID: "panel-x", hasAgentSession: true, store: store)
        XCTAssertEqual(unknownPanel["state"]?.stringValue, "idle")
        XCTAssertEqual(unknownPanel["state_revision"]?.intValue, 0)

        // Plain terminal keeps the legacy carrier state.
        let plainPanel = AgentLifecycleListAugmenter.augmentPanel([
            "panel_id": .string("panel-t"),
            "state": .string("running"),
        ], workspaceID: "ws", panelID: "panel-t", hasAgentSession: false, store: store)
        XCTAssertEqual(plainPanel["state"]?.stringValue, "running")
    }
}

// Round2b P0 additions: generation-fenced retirement, entity-local
// tombstone revisions, hub eviction pressure, plain-terminal fallback.
final class AgentLifecycleRound2bTests: XCTestCase {
    private func identity(_ panel: String, session: String) -> AgentSessionLifecycleIdentity {
        AgentSessionLifecycleIdentity(workspaceID: "ws2b", panelID: panel, sessionID: session)
    }

    // Round2c point 1: a new feed must claim its generation IMMEDIATELY —
    // before any status/resume/prompt event — so a reconnect's stale
    // needs_input/working record never stays visible in the gap.
    func testNewCodexFeedClaimsGenerationBeforeAnyEvent() {
        let store = AgentSessionLifecycleStore()
        let id = identity("panel-1", session: "s1")

        let oldFeed = CodexLifecycleFeed(identity: id, rootThreadID: { "thread-root" }, store: store)
        oldFeed.applyStatus(threadID: "thread-root", statusType: "active", activeFlags: ["waitingOnApproval"])
        XCTAssertEqual(store.snapshot(id)?.state, .needsInput)

        // A NEW connection attaches (init only) — before it sends ANY
        // resume/status/prompt event, the stale needs_input must already
        // be gone.
        let newFeed = CodexLifecycleFeed(identity: id, rootThreadID: { "thread-root" }, store: store)
        XCTAssertEqual(store.snapshot(id)?.state, .idle,
                       "stale needs_input remained visible in the no-snapshot gap")
        XCTAssertEqual(store.snapshot(id)?.generation, newFeed.generation)
    }

    // MARK: - P0-1: an OLD Codex connection tearing down after a NEW one repopulated
    // the identity must not retire the new record. Production feed objects.
    func testOldFeedRetireCannotKillNewerFeedState() {
        let store = AgentSessionLifecycleStore()
        let id = identity("panel-1", session: "s1")
        let oldFeed = CodexLifecycleFeed(identity: id, rootThreadID: { "thread-root" }, store: store)
        oldFeed.applyStatus(threadID: "thread-root", statusType: "active", activeFlags: [])
        XCTAssertEqual(store.snapshot(id)?.state, .working)

        let newFeed = CodexLifecycleFeed(identity: id, rootThreadID: { "thread-root" }, store: store)
        newFeed.applyStatus(threadID: "thread-root", statusType: "active", activeFlags: ["waitingOnApproval"])
        XCTAssertEqual(store.snapshot(id)?.state, .needsInput)

        // The OLD connection's late teardown: generation-fenced no-op.
        oldFeed.retire()
        store.waitForDeliveriesForTesting()
        XCTAssertEqual(store.snapshot(id)?.state, .needsInput,
                       "old connection teardown retired the newer generation")
        XCTAssertEqual(store.snapshot(id)?.ended, false)

        // The NEW connection's own retire still works.
        newFeed.retire()
        store.waitForDeliveriesForTesting()
        XCTAssertEqual(store.snapshot(id)?.ended, true)
    }

    // P0-2: retire/invalidation patches carry ENTITY-LOCAL revisions; the
    // next session's patches keep advancing past them.
    func testRetireThenNewSessionPublishesMonotonicEntityRevisions() {
        let store = AgentSessionLifecycleStore()
        let hub = WorkspaceEventHub()
        let publisher = AgentLifecycleEventPublisher(store: store, hub: hub)
        publisher.attach()

        let lock = NSLock()
        var panelRevisions: [Int] = []
        _ = hub.subscribe(workspaceID: "ws2b") { envelope in
            guard envelope.event.kind == .panelStateChanged,
                  envelope.event.panelID == "panel-r" else { return }
            if let revision = envelope.event.panel?["state_revision"]?.intValue {
                lock.lock(); panelRevisions.append(revision); lock.unlock()
            }
        }

        // Pump the GLOBAL revision counter far ahead on an unrelated panel:
        // a retire patch that leaked the global revision would poison
        // panel-r's entity sequence beyond repair.
        let noise = identity("panel-noise", session: "s0")
        for round in 0..<40 {
            store.beginTurn(noise, vendor: "codex", generation: 1, turnID: "t\(round)")
            store.endTurn(noise, vendor: "codex", generation: 1, turnID: "t\(round)")
        }

        let id = identity("panel-r", session: "s1")
        store.beginTurn(id, vendor: "codex", generation: 1)
        store.retireSession(id, generation: 1)
        store.waitForDeliveriesForTesting()

        lock.lock(); let retirePhase = panelRevisions; lock.unlock()
        // The retire/invalidation patch (aggregate vanished) carries the
        // ENTITY-LOCAL revision (2 mutations on this panel), never the
        // global counter (~80+).
        XCTAssertFalse(retirePhase.isEmpty)
        XCTAssertEqual(retirePhase.max(), 2,
                       "retire patch leaked a non-entity revision: \(retirePhase)")

        // A NEW session on the same panel keeps advancing past it.
        let id2 = identity("panel-r", session: "s2")
        store.openBlocker(id2, vendor: "codex", generation: 2, blockerID: "b", kind: .permission)
        store.waitForDeliveriesForTesting()

        lock.lock(); let revisions = panelRevisions; lock.unlock()
        XCTAssertEqual(revisions, revisions.sorted(),
                       "entity revision regressed across retire -> new session")
        XCTAssertEqual(revisions.max(), 3,
                       "the new session's patch must advance the entity revision")
        XCTAssertEqual(store.panelAggregate(workspaceID: "ws2b", panelID: "panel-r")?.revision, 3)
    }

    // Round2c point 3: aggregate captured ATOMICALLY with each mutation.
    // Rapid working -> needs_input -> idle transitions must never let a
    // later mutation's aggregate leak into an earlier revision's delivery.
    func testRapidTransitionsNeverProduceMismatchedAggregateSnapshots() {
        let store = AgentSessionLifecycleStore()
        let id = identity("panel-rapid", session: "s1")
        let lock = NSLock()
        var deliveries: [(revision: Int, panelState: AgentSessionDisplayState, panelRevision: Int)] = []
        store.addObserver { snapshot in
            lock.lock()
            deliveries.append((snapshot.revision, snapshot.panelAggregateState, snapshot.panelAggregateRevision))
            lock.unlock()
        }

        store.beginTurn(id, vendor: "codex", generation: 1)                          // working
        store.openBlocker(id, vendor: "codex", generation: 1, blockerID: "b", kind: .permission)  // needs_input
        store.resolveBlocker(id, vendor: "codex", generation: 1, blockerID: "b")      // working
        store.endTurn(id, vendor: "codex", generation: 1)                            // idle
        store.waitForDeliveriesForTesting()

        lock.lock(); let observed = deliveries; lock.unlock()
        XCTAssertEqual(observed.count, 4)
        // Each delivery's aggregate state matches EXACTLY what that specific
        // mutation produced — never a later transition's state.
        XCTAssertEqual(observed.map(\.panelState), [.working, .needsInput, .working, .idle])
        // Panel aggregate revisions strictly increase in lockstep with the
        // session revision — no duplicate/mismatched pairing.
        XCTAssertEqual(observed.map(\.revision), observed.map(\.panelRevision))
    }

    // A slow/blocking observer must not deadlock delivery, and later
    // mutations queued while it blocks must still arrive in order after.
    func testBlockingObserverDoesNotDeadlockOrReorderLaterDeliveries() {
        let store = AgentSessionLifecycleStore()
        let id = identity("panel-block", session: "s1")
        let lock = NSLock()
        var observedRevisions: [Int] = []
        let firstDeliveryStarted = DispatchSemaphore(value: 0)
        var releaseFirst = false
        let releaseLock = NSLock()

        store.addObserver { snapshot in
            lock.lock(); observedRevisions.append(snapshot.revision); lock.unlock()
            if snapshot.revision == 1 {
                firstDeliveryStarted.signal()
                // Block until the test explicitly releases — proves the
                // delivery queue does not need this callback to return
                // before the STORE accepts further mutations.
                while true {
                    releaseLock.lock()
                    let shouldRelease = releaseFirst
                    releaseLock.unlock()
                    if shouldRelease { break }
                    Thread.sleep(forTimeInterval: 0.005)
                }
            }
        }

        store.beginTurn(id, vendor: "codex", generation: 1)  // revision 1, blocks observer
        XCTAssertEqual(firstDeliveryStarted.wait(timeout: .now() + 2), .success)

        // The store itself accepts further mutations without waiting on
        // the blocked observer.
        store.openBlocker(id, vendor: "codex", generation: 1, blockerID: "b", kind: .permission)
        store.resolveBlocker(id, vendor: "codex", generation: 1, blockerID: "b")
        XCTAssertEqual(store.snapshot(id)?.state, .working)

        releaseLock.lock(); releaseFirst = true; releaseLock.unlock()
        store.waitForDeliveriesForTesting()

        lock.lock(); let revisions = observedRevisions; lock.unlock()
        XCTAssertEqual(revisions, revisions.sorted(), "deliveries reordered around a blocking observer")
    }

    // MARK: - P0-6: the latest state patch survives raw-buffer eviction pressure.
    func testHubReplaysLatestStatePatchAfterEvictionPressure() throws {
        let hub = WorkspaceEventHub()
        func event(seq: Int, kind: WorkspaceEventKind, panel: [String: JSONValue]? = nil) -> WorkspaceEvent {
            WorkspaceEvent(eventID: "evt-\(seq)", seq: seq, timestamp: "t",
                           kind: kind, windowGUID: nil,
                           workspaceID: "ws2b", panelID: panel == nil ? "panel-f" : "panel-p",
                           workspace: nil, panel: panel)
        }
        hub.publish(event(seq: 1, kind: .panelStateChanged,
                          panel: ["panel_id": .string("panel-p"),
                                  "state": .string("needs_input"),
                                  "state_revision": .number(7)]))
        // 500 unrelated events blow through the 400-entry raw buffer.
        for index in 0..<500 {
            hub.publish(event(seq: 100 + index, kind: .panelUpdated))
        }

        let (token, replay) = hub.subscribe(workspaceID: "ws2b") { _ in }
        defer { hub.unsubscribe(token) }
        let statePatches = replay.filter { $0.event.kind == .panelStateChanged }
        XCTAssertEqual(statePatches.count, 1,
                       "the only state transition was lost to buffer eviction")
        XCTAssertEqual(statePatches.first?.event.panel?["state"]?.stringValue, "needs_input")
        XCTAssertEqual(statePatches.first?.event.panel?["state_revision"]?.intValue, 7)
    }

}
