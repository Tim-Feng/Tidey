import XCTest
@testable import RemoteBridge

final class AgentEventHubAppServerWorkingControlTests: XCTestCase {
    private let sessionID = "session"
    private let workspaceID = "workspace"
    private let epoch = "pid:1|sock:/tmp/a.sock"
    private let root = "thread-1"
    private let turnID = "turn-1"

    private func logical(turnID: String? = nil) -> AppServerLogicalTurnKey {
        AppServerLogicalTurnKey(sessionID: sessionID, epoch: epoch, rootThreadID: root, turnID: turnID ?? self.turnID)
    }

    // Every test needs an established control incarnation before admission
    // will accept anything (production fail-closed guard) — this helper is
    // the SINGLE place that establishes it, so no test accidentally masks
    // the real incarnation-fence guard by skipping it.
    private func newHub() -> AgentEventHub {
        let hub = AgentEventHub()
        hub.beginAppServerControlIncarnation(sessionID: sessionID, epoch: epoch, rootThreadID: root)
        return hub
    }

    private func owner(_ logical: AppServerLogicalTurnKey, generation: String = "gen-1", token: String = "owner-1") -> AppServerOwnerKey {
        AppServerOwnerKey(logical: logical, runtimeGeneration: generation, ownerToken: token)
    }

    private func startHub(_ hub: AgentEventHub, logical: AppServerLogicalTurnKey, owner: AppServerOwnerKey, time: String = "t1") -> [AgentEvent] {
        hub.admitAppServerWorkingControl(logical: logical, ownerKey: owner, workspaceID: workspaceID,
                                         observation: .turnStarted(threadID: logical.rootThreadID, turnID: logical.turnID, time: time)).events
    }

    private func newHub(maxBufferedEvents: Int) -> AgentEventHub {
        let hub = AgentEventHub(maxBufferedEvents: maxBufferedEvents)
        hub.beginAppServerControlIncarnation(sessionID: sessionID, epoch: epoch, rootThreadID: root)
        return hub
    }

    private func makeFillerToolCallEvent(id: String, seq: Int, sessionID: String? = nil, timestamp: String = "t") -> AgentEvent {
        AgentEvent(eventID: id, seq: seq, vendor: "codex", workspaceID: workspaceID, sessionID: sessionID ?? self.sessionID,
                  timestamp: timestamp, type: .toolCall, role: "assistant", text: nil, name: "filler",
                  input: "{}", output: nil, toolCallID: id, metadata: nil)
    }

    // MARK: - Admission disposition contract (accepted / events / ownerContextEffect)
    //
    // `events.isEmpty` must NEVER be used to decide whether to update an
    // attach's owner→logical mapping — a rejected observation and an
    // accepted-but-eventless one (idempotent add-owner, prompt-hidden,
    // exact-duplicate retry) both produce zero events, but only the latter
    // is a real admission the caller must track.

    // Owner is bound to B; a late tombstoned start for A must be rejected
    // (accepted=false, ownerContextEffect=.none) — a caller that mistakenly
    // rebound its runtime to A here would leave B permanently "Working"
    // forever, since its own future disconnect would only ever retire A.
    func testLateTombstonedStartIsRejectedAndOwnerDisconnectStillRetiresB() {
        let hub = newHub()
        let keyB = logical(turnID: "turn-B")
        let ownerB = owner(keyB, generation: "gen-1", token: "owner-B")
        let startedB = hub.admitAppServerWorkingControl(logical: keyB, ownerKey: ownerB, workspaceID: workspaceID,
                                                         observation: .turnStarted(threadID: root, turnID: "turn-B", time: "t1"))
        XCTAssertTrue(startedB.accepted)
        XCTAssertEqual(startedB.ownerContextEffect, .setOwner(ownerB))

        // A was already semantically tombstoned (e.g. an earlier terminal-
        // before-start for A).
        let keyA = logical(turnID: "turn-A")
        let ownerA = owner(keyA, generation: "gen-2", token: "owner-A")
        _ = hub.admitAppServerWorkingControl(logical: keyA, ownerKey: ownerA, workspaceID: workspaceID,
                                             observation: .turnTerminal(threadID: root, turnID: "turn-A", rawStatus: "completed", time: "t2"))

        let lateStartA = hub.admitAppServerWorkingControl(logical: keyA, ownerKey: ownerA, workspaceID: workspaceID,
                                                           observation: .turnStarted(threadID: root, turnID: "turn-A", time: "t3"))
        XCTAssertFalse(lateStartA.accepted, "the late start for tombstoned A must be rejected")
        XCTAssertTrue(lateStartA.events.isEmpty)
        XCTAssertEqual(lateStartA.ownerContextEffect, .none, "a rejection must never tell the caller to rebind its owner mapping")

        // Owner disconnect must still retire B normally (proving B's
        // mapping was never disturbed by the rejected A observation).
        let disconnect = hub.retireAppServerOwner(ownerB, workspaceID: workspaceID, reason: .transportClosed, time: "t4")
        XCTAssertNotNil(disconnect, "B must still be the last live owner and produce a normal owner-scoped terminal")
        XCTAssertEqual(disconnect?.metadata?["terminal_scope"], "owner")
    }

    // A second owner (O2) starting the SAME already-active logical turn A is
    // accepted with zero wire events (idempotent add-owner) — the caller
    // must still record O2 in its own context. O1 disconnecting afterward
    // must produce zero terminal (O2 remains); only O2's own disconnect
    // produces the real terminal.
    func testSecondOwnerSameActiveTurnAcceptedNoWireBothTrackedForDisconnectOrdering() {
        let hub = newHub()
        let key = logical()
        let o1 = owner(key, generation: "gen-1", token: "owner-1")
        let started = hub.admitAppServerWorkingControl(logical: key, ownerKey: o1, workspaceID: workspaceID,
                                                        observation: .turnStarted(threadID: root, turnID: turnID, time: "t1"))
        XCTAssertTrue(started.accepted)

        let o2 = owner(key, generation: "gen-2", token: "owner-2")
        let secondStart = hub.admitAppServerWorkingControl(logical: key, ownerKey: o2, workspaceID: workspaceID,
                                                            observation: .turnStarted(threadID: root, turnID: turnID, time: "t2"))
        XCTAssertTrue(secondStart.accepted, "a second owner joining the SAME already-active logical turn is a valid admission")
        XCTAssertTrue(secondStart.events.isEmpty, "idempotent add-owner produces no second open event")
        XCTAssertEqual(secondStart.ownerContextEffect, .setOwner(o2))
        XCTAssertEqual(hub.appServerControlDebugSnapshotForTesting(sessionID: sessionID).activeOwners, [o1, o2])

        let o1Disconnect = hub.retireAppServerOwner(o1, workspaceID: workspaceID, reason: .transportClosed, time: "t3")
        XCTAssertNil(o1Disconnect, "O2 remains live — O1's disconnect must produce zero UI terminal")

        let o2Disconnect = hub.retireAppServerOwner(o2, workspaceID: workspaceID, reason: .transportClosed, time: "t4")
        XCTAssertNotNil(o2Disconnect, "O2 was the LAST owner — its disconnect must produce exactly one terminal")
    }

    // A prompt-hidden start/activity is still accepted with zero wire
    // events — the caller must still bind its owner context so a later
    // disconnect correctly retires it.
    func testPromptHiddenStartAndActivityAcceptedNoWireOwnerStillTrackedForDisconnect() {
        let hub = newHub()
        let key = logical()
        let o = owner(key)

        hub.publish(makeNativePromptEvent(id: "p1", seq: 10, promptID: "prompt-1", token: "tok-1"))
        let hiddenStart = hub.admitAppServerWorkingControl(logical: key, ownerKey: o, workspaceID: workspaceID,
                                                            observation: .turnStarted(threadID: root, turnID: turnID, time: "t1"))
        XCTAssertTrue(hiddenStart.accepted, "prompt-hidden is still a real typed admission")
        XCTAssertTrue(hiddenStart.events.isEmpty)
        XCTAssertEqual(hiddenStart.ownerContextEffect, .setOwner(o))

        let hiddenActivity = hub.admitAppServerWorkingControl(logical: key, ownerKey: o, workspaceID: workspaceID,
                                                               observation: .internalActivityStarted(threadID: root, turnID: turnID, itemID: "item-1", kind: .sleep, time: "t2"))
        XCTAssertTrue(hiddenActivity.accepted)
        XCTAssertTrue(hiddenActivity.events.isEmpty)
        XCTAssertEqual(hiddenActivity.ownerContextEffect, .setOwner(o))

        // The owner is genuinely tracked (not silently dropped) — its
        // disconnect while still the last owner still produces a real
        // terminal (even though the display was hidden the whole time).
        let disconnect = hub.retireAppServerOwner(o, workspaceID: workspaceID, reason: .transportClosed, time: "t3")
        XCTAssertNotNil(disconnect)
    }

    // Exact-duplicate activity retry is accepted with zero wire events and
    // consumes zero seq; activity for a wrong/different active trajectory
    // is REJECTED with zero wire events — same "zero events" surface, but
    // opposite disposition.
    func testDuplicateActivityAcceptedVersusWrongTrajectoryRejectedHaveDifferentDisposition() {
        let hub = newHub()
        let key = logical()
        let o = owner(key)
        _ = startHub(hub, logical: key, owner: o)
        _ = hub.admitAppServerWorkingControl(logical: key, ownerKey: o, workspaceID: workspaceID,
                                             observation: .internalActivityStarted(threadID: root, turnID: turnID, itemID: "item-1", kind: .sleep, time: "t2"))

        let highWaterBeforeDuplicate = hub.fetch(workspaceID: workspaceID, sessionID: sessionID, limit: 100).newestSeq
        let duplicate = hub.admitAppServerWorkingControl(logical: key, ownerKey: o, workspaceID: workspaceID,
                                                          observation: .internalActivityStarted(threadID: root, turnID: turnID, itemID: "item-1", kind: .sleep, time: "t3"))
        XCTAssertTrue(duplicate.accepted, "an exact-duplicate edge retry is still accepted (just coalesced)")
        XCTAssertTrue(duplicate.events.isEmpty)
        XCTAssertEqual(duplicate.ownerContextEffect, .setOwner(o),
                       "the effect must still name the exact owner — a wrongly-nulled effect here would silently break Syncer's mapping")
        XCTAssertEqual(hub.fetch(workspaceID: workspaceID, sessionID: sessionID, limit: 100).newestSeq, highWaterBeforeDuplicate,
                       "a duplicate must consume zero seq")

        let keyOther = logical(turnID: "turn-other")
        let ownerOther = owner(keyOther, generation: "gen-2", token: "owner-2")
        let wrongTrajectory = hub.admitAppServerWorkingControl(logical: keyOther, ownerKey: ownerOther, workspaceID: workspaceID,
                                                                observation: .internalActivityStarted(threadID: root, turnID: "turn-other", itemID: "item-2", kind: .sleep, time: "t4"))
        XCTAssertFalse(wrongTrajectory.accepted, "activity for a DIFFERENT active trajectory must be rejected, not merely deduped")
        XCTAssertTrue(wrongTrajectory.events.isEmpty)
        XCTAssertEqual(wrongTrajectory.ownerContextEffect, .none)
    }

    // MARK: - Basic admission / edge ID discrimination

    func testTurnStartedThenActivityProduceDistinctEdgesAndNoToolCard() {
        let hub = newHub()
        let key = logical()
        let o = owner(key)

        let started = startHub(hub, logical: key, owner: o)
        XCTAssertEqual(started.map(\.type), [.thinking])
        XCTAssertNil(started.first?.text)
        XCTAssertNil(started.first?.toolCallID)

        let activity = hub.admitAppServerWorkingControl(logical: key, ownerKey: o, workspaceID: workspaceID,
                                                         observation: .internalActivityStarted(threadID: root, turnID: turnID, itemID: "item-1", kind: .sleep, time: "t2")).events
        XCTAssertEqual(activity.map(\.type), [.thinking])
        XCTAssertNotEqual(started.first?.eventID, activity.first?.eventID)
    }

    func testDuplicateTurnStartedProducesNoSecondEvent() {
        let hub = newHub()
        let key = logical()
        let o = owner(key)
        let first = startHub(hub, logical: key, owner: o)
        XCTAssertEqual(first.count, 1)
        let second = startHub(hub, logical: key, owner: o)
        XCTAssertTrue(second.isEmpty)
    }

    func testResumeAfterOwnerDisconnectIsDistinctEdgeFromOriginalOpen() {
        let hub = newHub()
        let key = logical()
        let o1 = owner(key, generation: "gen-1", token: "owner-1")
        let opened = startHub(hub, logical: key, owner: o1)
        XCTAssertEqual(opened.count, 1)

        let disconnectEvent = hub.retireAppServerOwner(o1, workspaceID: workspaceID, reason: .transportClosed, time: "t2")
        XCTAssertNotNil(disconnectEvent)
        XCTAssertEqual(disconnectEvent?.type, .assistantFinal)

        let o2 = owner(key, generation: "gen-2", token: "owner-2")
        let resumed = hub.admitAppServerWorkingControl(logical: key, ownerKey: o2, workspaceID: workspaceID,
                                                        observation: .resumeSnapshot(threadID: root, turnID: turnID, time: "t3")).events
        XCTAssertEqual(resumed.count, 1, "resume must be independently deliverable, not deduped against the original open")
        XCTAssertNotEqual(opened.first?.eventID, resumed.first?.eventID)
    }

    func testMissingOpenerBatchAdmitsBothOpenerAndContinuationInOrder() {
        let hub = newHub()
        let key = logical()
        let o = owner(key)
        let events = hub.admitAppServerWorkingControl(logical: key, ownerKey: o, workspaceID: workspaceID,
                                                       observation: .internalActivityStarted(threadID: root, turnID: turnID, itemID: "item-1", kind: .sleep, time: "t1")).events
        XCTAssertEqual(events.count, 2, "no current turn must synthesize opener + continuation, BOTH real deliverable events")
        XCTAssertTrue(events[0].seq < events[1].seq, "cursor must be continuous across the batch")
        for event in events {
            XCTAssertNil(event.text)
            XCTAssertNil(event.toolCallID)
            XCTAssertEqual(event.type, .thinking)
        }
    }

    func testRetiredOwnerStragglerRejectedOnStartActivityAndResume() {
        let hub = newHub()
        let key = logical()
        let o = owner(key)
        _ = startHub(hub, logical: key, owner: o)
        hub.retireAppServerOwner(o, workspaceID: workspaceID, reason: .transportClosed, time: "t2")

        // The EXACT SAME (now-retired) owner key tries to reopen its OWN
        // logical turn via every owner-bearing path — a fresh owner key
        // (different generation/token) for a DIFFERENT turn is untouched by
        // this tombstone by construction (owner keys are turn-scoped), so
        // this must reuse `key`/`o`, not an unrelated turn.
        let staleStart = hub.admitAppServerWorkingControl(logical: key, ownerKey: o, workspaceID: workspaceID,
                                                           observation: .turnStarted(threadID: root, turnID: turnID, time: "t3")).events
        XCTAssertTrue(staleStart.isEmpty)

        let staleActivity = hub.admitAppServerWorkingControl(logical: key, ownerKey: o, workspaceID: workspaceID,
                                                              observation: .internalActivityStarted(threadID: root, turnID: turnID, itemID: "item-x", kind: .sleep, time: "t4")).events
        XCTAssertTrue(staleActivity.isEmpty)

        let staleResume = hub.admitAppServerWorkingControl(logical: key, ownerKey: o, workspaceID: workspaceID,
                                                            observation: .resumeSnapshot(threadID: root, turnID: turnID, time: "t5")).events
        XCTAssertTrue(staleResume.isEmpty)

        // Proves the three stale rejections above advanced NEITHER the
        // shared session cursor NOR any reservation: a genuinely accepted
        // edge right afterward lands at exactly seq = (owner-disconnect's
        // own seq) + 1, not some higher value a wasted reservation would
        // have produced.
        let terminalSeq = hub.fetch(workspaceID: workspaceID, sessionID: sessionID, limit: 100).events
            .first(where: { $0.metadata?["terminal_scope"] == "owner" })?.seq
        let keyB = logical(turnID: "turn-B")
        let ownerB = owner(keyB, generation: "gen-2", token: "owner-2")
        let accepted = hub.admitAppServerWorkingControl(logical: keyB, ownerKey: ownerB, workspaceID: workspaceID,
                                                         observation: .turnStarted(threadID: root, turnID: "turn-B", time: "t6")).events
        XCTAssertEqual(accepted.count, 1)
        XCTAssertEqual(accepted.first?.seq, (terminalSeq ?? 0) + 1,
                      "three stale rejections must not have advanced the cursor at all")
    }

    func testIdentityMismatchFailsClosed() {
        let hub = newHub()
        let key = logical()
        let wrongOwner = AppServerOwnerKey(logical: logical(turnID: "different-turn"), runtimeGeneration: "gen-1", ownerToken: "owner-1")
        let result = hub.admitAppServerWorkingControl(logical: key, ownerKey: wrongOwner, workspaceID: workspaceID,
                                                       observation: .turnStarted(threadID: root, turnID: turnID, time: "t1")).events
        XCTAssertTrue(result.isEmpty, "ownerKey.logical must equal the admitted logical key")

        let o = owner(key)
        let mismatchedObservation = hub.admitAppServerWorkingControl(logical: key, ownerKey: o, workspaceID: workspaceID,
                                                                      observation: .turnStarted(threadID: "other-thread", turnID: turnID, time: "t1")).events
        XCTAssertTrue(mismatchedObservation.isEmpty, "observation's own threadID must equal logical.rootThreadID")
    }

    // MARK: - Suspended trajectory supersession

    func testAuthoritativeStartTombstonesDifferentSuspendedTrajectory() {
        let hub = newHub()
        let keyA = logical(turnID: "turn-A")
        let ownerA = owner(keyA)
        _ = startHub(hub, logical: keyA, owner: ownerA)
        hub.retireAppServerOwner(ownerA, workspaceID: workspaceID, reason: .transportClosed, time: "t2")
        XCTAssertEqual(hub.appServerControlDebugSnapshotForTesting(sessionID: sessionID).suspendedLogicalTurn, keyA)

        let keyB = logical(turnID: "turn-B")
        let ownerB = owner(keyB, generation: "gen-2", token: "owner-2")
        let startedB = hub.admitAppServerWorkingControl(logical: keyB, ownerKey: ownerB, workspaceID: workspaceID,
                                                         observation: .turnStarted(threadID: root, turnID: "turn-B", time: "t3")).events
        XCTAssertEqual(startedB.count, 1)
        let terminatedB = hub.admitAppServerWorkingControl(logical: keyB, ownerKey: ownerB, workspaceID: workspaceID,
                                                            observation: .turnTerminal(threadID: root, turnID: "turn-B", rawStatus: "completed", time: "t4")).events
        XCTAssertEqual(terminatedB.count, 1)

        // Stale resume of A must be rejected (tombstoned when B superseded).
        let ownerA2 = owner(keyA, generation: "gen-3", token: "owner-3")
        let staleResumeA = hub.admitAppServerWorkingControl(logical: keyA, ownerKey: ownerA2, workspaceID: workspaceID,
                                                             observation: .resumeSnapshot(threadID: root, turnID: "turn-A", time: "t5")).events
        XCTAssertTrue(staleResumeA.isEmpty)
    }

    func testActivityForDifferentTrajectoryRejectedWhileSuspendedARemains() {
        let hub = newHub()
        let keyA = logical(turnID: "turn-A")
        let ownerA = owner(keyA)
        _ = startHub(hub, logical: keyA, owner: ownerA)
        hub.retireAppServerOwner(ownerA, workspaceID: workspaceID, reason: .transportClosed, time: "t2")

        let keyB = logical(turnID: "turn-B")
        let ownerB = owner(keyB, generation: "gen-2", token: "owner-2")
        let activityB = hub.admitAppServerWorkingControl(logical: keyB, ownerKey: ownerB, workspaceID: workspaceID,
                                                          observation: .internalActivityStarted(threadID: root, turnID: "turn-B", itemID: "item-b", kind: .sleep, time: "t3")).events
        XCTAssertTrue(activityB.isEmpty)
        XCTAssertEqual(hub.appServerControlDebugSnapshotForTesting(sessionID: sessionID).suspendedLogicalTurn, keyA,
                       "A must remain suspended, not tombstoned, by a merely-rejected activity for B")
    }

    func testResumeForDifferentTrajectoryRejectedWhileSuspendedARemains() {
        let hub = newHub()
        let keyA = logical(turnID: "turn-A")
        let ownerA = owner(keyA)
        _ = startHub(hub, logical: keyA, owner: ownerA)
        hub.retireAppServerOwner(ownerA, workspaceID: workspaceID, reason: .transportClosed, time: "t2")

        let keyB = logical(turnID: "turn-B")
        let ownerB = owner(keyB, generation: "gen-2", token: "owner-2")
        let resumeB = hub.admitAppServerWorkingControl(logical: keyB, ownerKey: ownerB, workspaceID: workspaceID,
                                                        observation: .resumeSnapshot(threadID: root, turnID: "turn-B", time: "t3")).events
        XCTAssertTrue(resumeB.isEmpty)
        XCTAssertEqual(hub.appServerControlDebugSnapshotForTesting(sessionID: sessionID).suspendedLogicalTurn, keyA)
    }

    func testExactActivityReopensSuspendedTrajectory() {
        let hub = newHub()
        let keyA = logical(turnID: "turn-A")
        let ownerA = owner(keyA)
        _ = startHub(hub, logical: keyA, owner: ownerA)
        hub.retireAppServerOwner(ownerA, workspaceID: workspaceID, reason: .transportClosed, time: "t2")

        let ownerA2 = owner(keyA, generation: "gen-2", token: "owner-2")
        let reopened = hub.admitAppServerWorkingControl(logical: keyA, ownerKey: ownerA2, workspaceID: workspaceID,
                                                         observation: .internalActivityStarted(threadID: root, turnID: "turn-A", itemID: "item-a", kind: .sleep, time: "t3")).events
        XCTAssertFalse(reopened.isEmpty, "exact activity for the suspended trajectory itself must reopen it")
        XCTAssertEqual(hub.appServerControlDebugSnapshotForTesting(sessionID: sessionID).currentLogicalTurn, keyA)
        XCTAssertNotNil(hub.appServerControlDebugSnapshotForTesting(sessionID: sessionID).latestSnapshot)
    }

    func testExactResumeReopensSuspendedTrajectory() {
        let hub = newHub()
        let keyA = logical(turnID: "turn-A")
        let ownerA = owner(keyA)
        _ = startHub(hub, logical: keyA, owner: ownerA)
        hub.retireAppServerOwner(ownerA, workspaceID: workspaceID, reason: .transportClosed, time: "t2")

        let ownerA2 = owner(keyA, generation: "gen-2", token: "owner-2")
        let reopened = hub.admitAppServerWorkingControl(logical: keyA, ownerKey: ownerA2, workspaceID: workspaceID,
                                                         observation: .resumeSnapshot(threadID: root, turnID: "turn-A", time: "t3")).events
        XCTAssertEqual(reopened.count, 1)
        XCTAssertEqual(hub.appServerControlDebugSnapshotForTesting(sessionID: sessionID).currentLogicalTurn, keyA)
    }

    // MARK: - Owner-scoped reopen must not reuse a dedup'd edge (turnStarted / activity)

    func testAuthoritativeStartReopenAfterDisconnectAlwaysProducesVisibleEventAndSnapshot() {
        let hub = newHub()
        let key = logical()
        let owner1 = owner(key)
        _ = startHub(hub, logical: key, owner: owner1)
        hub.retireAppServerOwner(owner1, workspaceID: workspaceID, reason: .transportClosed, time: "t2")

        let owner2 = owner(key, generation: "gen-2", token: "owner-2")
        let reopened = hub.admitAppServerWorkingControl(logical: key, ownerKey: owner2, workspaceID: workspaceID,
                                                         observation: .turnStarted(threadID: root, turnID: turnID, time: "t3")).events
        XCTAssertEqual(reopened.count, 1, "reopen via authoritative start must never dedupe against the original turn_start edge")
        XCTAssertNotNil(hub.appServerControlDebugSnapshotForTesting(sessionID: sessionID).latestSnapshot)
    }

    func testActivitySyntheticOpenReopenAfterDisconnectWithDuplicateItemStillProducesVisibleEvent() {
        let hub = newHub()
        let key = logical()
        let owner1 = owner(key)
        // Original turn is itself activity-opened (never a turnStarted).
        let original = hub.admitAppServerWorkingControl(logical: key, ownerKey: owner1, workspaceID: workspaceID,
                                                         observation: .internalActivityStarted(threadID: root, turnID: turnID, itemID: "item-1", kind: .sleep, time: "t1")).events
        XCTAssertEqual(original.count, 2, "opener + continuation")
        hub.retireAppServerOwner(owner1, workspaceID: workspaceID, reason: .transportClosed, time: "t2")

        let owner2 = owner(key, generation: "gen-2", token: "owner-2")
        // Exact SAME itemID as before disconnect — the continuation edge
        // itself would dedupe, but the reopen OPENER must still be visible.
        let reopened = hub.admitAppServerWorkingControl(logical: key, ownerKey: owner2, workspaceID: workspaceID,
                                                         observation: .internalActivityStarted(threadID: root, turnID: turnID, itemID: "item-1", kind: .sleep, time: "t3")).events
        XCTAssertFalse(reopened.isEmpty, "must not leave current live with zero wire events")
        XCTAssertNotNil(hub.appServerControlDebugSnapshotForTesting(sessionID: sessionID).latestSnapshot)
        XCTAssertEqual(hub.appServerControlDebugSnapshotForTesting(sessionID: sessionID).currentLogicalTurn, key)
    }

    // MARK: - Prompt-hidden dedupe

    private func makeNativePromptEvent(id: String, seq: Int, promptID: String, token: String, source: String = "codex_command_approval") -> AgentEvent {
        AgentEvent(eventID: id, seq: seq, vendor: "codex", workspaceID: workspaceID, sessionID: sessionID,
                  timestamp: "t", type: .interactivePrompt, role: nil, text: nil, name: nil, input: nil, output: nil,
                  toolCallID: nil, metadata: ["prompt_id": promptID, "lifecycle_token": token, "submit_channel": "codex_app_server", "source": source])
    }

    private func makeNativeResolvedEvent(id: String, seq: Int, promptID: String, token: String, reason: String = "server_resolved", source: String = "codex_command_approval") -> AgentEvent {
        AgentEvent(eventID: id, seq: seq, vendor: "codex", workspaceID: workspaceID, sessionID: sessionID,
                  timestamp: "t", type: .interactivePromptResolved, role: nil, text: nil, name: nil, input: nil, output: nil,
                  toolCallID: nil, metadata: ["prompt_id": promptID, "lifecycle_token": token, "reason": reason, "submit_channel": "codex_app_server", "source": source])
    }

    // Exact token, but reason="expired" — the prompt GENUINELY closes
    // (unlike a wrong-token close, which never removes the lifecycle entry
    // at all and would trivially pass even with the hidden-edge dedupe
    // fix removed). "expired" closes without being eligible to resume
    // (resolvedReasonPolicy only allows "server_resolved").
    func testHiddenActivityDuplicateAfterExpiredCloseStaysZeroAndCursorUnadvanced() {
        let hub = newHub()
        let key = logical()
        let o = owner(key)
        _ = startHub(hub, logical: key, owner: o)

        hub.publish(makeNativePromptEvent(id: "p1", seq: 10, promptID: "prompt-1", token: "tok-1"))
        let hiddenX = hub.admitAppServerWorkingControl(logical: key, ownerKey: o, workspaceID: workspaceID,
                                                        observation: .internalActivityStarted(threadID: root, turnID: turnID, itemID: "item-x", kind: .sleep, time: "t2")).events
        XCTAssertTrue(hiddenX.isEmpty, "hidden by active prompt — no wire event")

        // Genuinely closes (exact token), but reason="expired" — never
        // eligible to resume.
        hub.publish(makeNativeResolvedEvent(id: "r1", seq: 11, promptID: "prompt-1", token: "tok-1", reason: "expired"))
        let resumesAfterExpired = hub.fetch(workspaceID: workspaceID, sessionID: sessionID, limit: 100).events
            .filter { $0.metadata?["reason"] == "resume_snapshot" }
        XCTAssertTrue(resumesAfterExpired.isEmpty, "expired close must never resume")
        XCTAssertNil(hub.appServerControlDebugSnapshotForTesting(sessionID: sessionID).latestSnapshot)

        let duplicateX = hub.admitAppServerWorkingControl(logical: key, ownerKey: o, workspaceID: workspaceID,
                                                           observation: .internalActivityStarted(threadID: root, turnID: turnID, itemID: "item-x", kind: .sleep, time: "t3")).events
        XCTAssertTrue(duplicateX.isEmpty, "exact duplicate of the already-admitted (hidden) edge must coalesce to zero, never re-admit")

        // Real cursor-mutation proof: a genuinely NEW, distinct edge right
        // afterward must land at exactly (current high-water) + 1 — the
        // hidden activity and its duplicate retry must have reserved
        // NOTHING in between (the baseline is taken AFTER the two publish()
        // calls above, which DO legitimately advance the high-water
        // themselves — only the hidden/duplicate activity's own
        // non-consumption is under test here).
        let highWaterBeforeFreshActivity = hub.fetch(workspaceID: workspaceID, sessionID: sessionID, limit: 100).newestSeq
        let freshActivity = hub.admitAppServerWorkingControl(logical: key, ownerKey: o, workspaceID: workspaceID,
                                                              observation: .internalActivityStarted(threadID: root, turnID: turnID, itemID: "item-fresh", kind: .sleep, time: "t4")).events
        XCTAssertEqual(freshActivity.count, 1)
        XCTAssertEqual(freshActivity.first?.seq, highWaterBeforeFreshActivity + 1,
                      "the hidden activity + its duplicate retry must not have consumed any seq")
    }

    // Separate lifecycle-only test: a WRONG-token close never actually
    // closes the prompt at all (the lifecycle entry is untouched), so it is
    // a distinct scenario from the genuine "expired" close above.
    func testWrongTokenCloseNeverClosesThePromptLifecycle() {
        let hub = newHub()
        let key = logical()
        let o = owner(key)
        _ = startHub(hub, logical: key, owner: o)

        hub.publish(makeNativePromptEvent(id: "p1", seq: 10, promptID: "prompt-1", token: "tok-1"))
        hub.publish(makeNativeResolvedEvent(id: "r1", seq: 11, promptID: "prompt-1", token: "wrong-token"))

        let hiddenAfterWrongToken = hub.admitAppServerWorkingControl(logical: key, ownerKey: o, workspaceID: workspaceID,
                                                                      observation: .internalActivityStarted(threadID: root, turnID: turnID, itemID: "item-y", kind: .sleep, time: "t3")).events
        XCTAssertTrue(hiddenAfterWrongToken.isEmpty, "the prompt must still be considered active — wrong token never closes it")
    }

    func testHiddenActivityDuplicateAfterExactResolveStillZeroAndExactlyOneResume() {
        let hub = newHub()
        let key = logical()
        let o = owner(key)
        _ = startHub(hub, logical: key, owner: o)

        hub.publish(makeNativePromptEvent(id: "p1", seq: 10, promptID: "prompt-1", token: "tok-1"))
        let hiddenX = hub.admitAppServerWorkingControl(logical: key, ownerKey: o, workspaceID: workspaceID,
                                                        observation: .internalActivityStarted(threadID: root, turnID: turnID, itemID: "item-x", kind: .sleep, time: "t2")).events
        XCTAssertTrue(hiddenX.isEmpty)

        hub.publish(makeNativeResolvedEvent(id: "r1", seq: 11, promptID: "prompt-1", token: "tok-1"))
        let resumeEvents = hub.fetch(workspaceID: workspaceID, sessionID: sessionID, limit: 100).events
        let resumes = resumeEvents.filter { $0.metadata?["reason"] == "resume_snapshot" }
        XCTAssertEqual(resumes.count, 1)

        let duplicateX = hub.admitAppServerWorkingControl(logical: key, ownerKey: o, workspaceID: workspaceID,
                                                           observation: .internalActivityStarted(threadID: root, turnID: turnID, itemID: "item-x", kind: .sleep, time: "t3")).events
        XCTAssertTrue(duplicateX.isEmpty, "exact duplicate X must still coalesce to zero even after a legitimate resolve")
    }

    // MARK: - Prompt resolve restores live current, never last-owner-suspended

    func testLiveTurnHiddenByPromptResumesWithRealOwnerMetadata() {
        let hub = newHub()
        let key = logical()
        let o = owner(key, generation: "gen-1", token: "owner-O")
        _ = startHub(hub, logical: key, owner: o)

        hub.publish(makeNativePromptEvent(id: "p1", seq: 10, promptID: "prompt-1", token: "tok-1"))
        XCTAssertNil(hub.appServerControlDebugSnapshotForTesting(sessionID: sessionID).latestSnapshot, "prompt open must clear the snapshot")

        hub.publish(makeNativeResolvedEvent(id: "r1", seq: 11, promptID: "prompt-1", token: "tok-1"))
        let events = hub.fetch(workspaceID: workspaceID, sessionID: sessionID, limit: 100).events
        let resumes = events.filter { $0.metadata?["reason"] == "resume_snapshot" }
        XCTAssertEqual(resumes.count, 1)
        XCTAssertEqual(resumes.first?.metadata?["owner_token"], "owner-O")
        XCTAssertEqual(resumes.first?.metadata?["runtime_generation"], "gen-1")
    }

    func testLastOwnerDisconnectedTurnDoesNotResumeOnPromptResolve() {
        let hub = newHub()
        let key = logical()
        let o = owner(key)
        _ = startHub(hub, logical: key, owner: o)
        hub.retireAppServerOwner(o, workspaceID: workspaceID, reason: .transportClosed, time: "t2")
        XCTAssertNil(hub.appServerControlDebugSnapshotForTesting(sessionID: sessionID).currentLogicalTurn)

        hub.publish(makeNativePromptEvent(id: "p1", seq: 10, promptID: "prompt-1", token: "tok-1"))
        hub.publish(makeNativeResolvedEvent(id: "r1", seq: 11, promptID: "prompt-1", token: "tok-1"))

        let events = hub.fetch(workspaceID: workspaceID, sessionID: sessionID, limit: 100).events
        let resumes = events.filter { $0.metadata?["reason"] == "resume_snapshot" }
        XCTAssertTrue(resumes.isEmpty, "a disconnected/ownerless suspended turn must never resume via prompt resolve")
        XCTAssertNil(hub.appServerControlDebugSnapshotForTesting(sessionID: sessionID).latestSnapshot)
        XCTAssertNil(hub.appServerControlDebugSnapshotForTesting(sessionID: sessionID).currentLogicalTurn)
    }

    func testGenericFakeServerResolvedNeverResumesTypedControl() {
        let hub = newHub()
        let key = logical()
        let o = owner(key)
        _ = startHub(hub, logical: key, owner: o)

        let genericOpener = AgentEvent(eventID: "generic-open", seq: 10, vendor: "claude", workspaceID: workspaceID, sessionID: sessionID,
                                       timestamp: "t", type: .interactivePrompt, role: nil, text: nil, name: nil, input: nil, output: nil,
                                       toolCallID: nil, metadata: ["prompt_id": "prompt-1", "source": "claude_ask_user_question"])
        hub.publish(genericOpener)
        let genericResolved = AgentEvent(eventID: "generic-resolved", seq: 11, vendor: "claude", workspaceID: workspaceID, sessionID: sessionID,
                                         timestamp: "t", type: .interactivePromptResolved, role: nil, text: nil, name: nil, input: nil, output: nil,
                                         toolCallID: nil, metadata: ["prompt_id": "prompt-1", "reason": "server_resolved", "source": "claude_ask_user_question"])
        hub.publish(genericResolved)

        let events = hub.fetch(workspaceID: workspaceID, sessionID: sessionID, limit: 100).events
        let resumes = events.filter { $0.metadata?["reason"] == "resume_snapshot" }
        XCTAssertTrue(resumes.isEmpty, "a non-Codex-native lifecycle must never resume typed control")
    }

    func testConsecutiveExactResolvesForSameOwnerEachProduceDistinctResume() {
        let hub = newHub()
        let key = logical()
        let o = owner(key)
        _ = startHub(hub, logical: key, owner: o)

        hub.publish(makeNativePromptEvent(id: "p1", seq: 10, promptID: "prompt-1", token: "tok-1"))
        hub.publish(makeNativeResolvedEvent(id: "r1", seq: 11, promptID: "prompt-1", token: "tok-1"))

        hub.publish(makeNativePromptEvent(id: "p2", seq: 12, promptID: "prompt-2", token: "tok-2"))
        hub.publish(makeNativeResolvedEvent(id: "r2", seq: 13, promptID: "prompt-2", token: "tok-2"))

        let events = hub.fetch(workspaceID: workspaceID, sessionID: sessionID, limit: 100).events
        let resumes = events.filter { $0.metadata?["reason"] == "resume_snapshot" }
        XCTAssertEqual(resumes.count, 2)
        XCTAssertNotEqual(resumes[0].eventID, resumes[1].eventID)
    }

    // MARK: - Retired-owner late authoritative terminal must still tombstone-first

    func testLateTerminalFromRetiredOwnerStillTombstonesAndClearsSuspended() {
        let hub = newHub()
        let key = logical()
        let o = owner(key)
        _ = startHub(hub, logical: key, owner: o)
        hub.retireAppServerOwner(o, workspaceID: workspaceID, reason: .transportClosed, time: "t2")
        XCTAssertEqual(hub.appServerControlDebugSnapshotForTesting(sessionID: sessionID).suspendedLogicalTurn, key)

        // The retired owner's own connection still delivers an authoritative
        // late turn/completed for the same logical turn.
        let lateTerminal = hub.admitAppServerWorkingControl(logical: key, ownerKey: o, workspaceID: workspaceID,
                                                             observation: .turnTerminal(threadID: root, turnID: turnID, rawStatus: "completed", time: "t3")).events
        XCTAssertFalse(lateTerminal.isEmpty, "an authoritative terminal must be processed even from a retired owner")
        XCTAssertNil(hub.appServerControlDebugSnapshotForTesting(sessionID: sessionID).suspendedLogicalTurn)
        XCTAssertTrue(hub.appServerControlDebugSnapshotForTesting(sessionID: sessionID).semanticTombstones.contains(key))

        let ownerNew = owner(key, generation: "gen-2", token: "owner-2")
        let rejectedResume = hub.admitAppServerWorkingControl(logical: key, ownerKey: ownerNew, workspaceID: workspaceID,
                                                               observation: .resumeSnapshot(threadID: root, turnID: turnID, time: "t4")).events
        XCTAssertTrue(rejectedResume.isEmpty)
    }

    func testUnrelatedTurnBUnaffectedByRetiredOwnerTerminalOnA() {
        let hub = newHub()
        let keyA = logical(turnID: "turn-A")
        let ownerA = owner(keyA)
        _ = startHub(hub, logical: keyA, owner: ownerA)
        hub.retireAppServerOwner(ownerA, workspaceID: workspaceID, reason: .transportClosed, time: "t2")
        _ = hub.admitAppServerWorkingControl(logical: keyA, ownerKey: ownerA, workspaceID: workspaceID,
                                             observation: .turnTerminal(threadID: root, turnID: "turn-A", rawStatus: "completed", time: "t3")).events

        let keyB = logical(turnID: "turn-B")
        let ownerB = owner(keyB, generation: "gen-2", token: "owner-2")
        let startedB = hub.admitAppServerWorkingControl(logical: keyB, ownerKey: ownerB, workspaceID: workspaceID,
                                                         observation: .turnStarted(threadID: root, turnID: "turn-B", time: "t4")).events
        XCTAssertEqual(startedB.count, 1, "B is a wholly unrelated logical turn and must be unaffected")
    }

    // MARK: - Ordinary transcript anchor/continuation must respect app-server semantic tombstone

    private func makeAnchorThinkingEvent(id: String, seq: Int, turnID: String) -> AgentEvent {
        AgentEvent(eventID: id, seq: seq, vendor: "codex", workspaceID: workspaceID, sessionID: sessionID,
                  timestamp: "t", type: .thinking, role: nil, text: nil, name: nil, input: nil, output: nil,
                  toolCallID: nil, metadata: ["turn_id": turnID, "reason": "task_started"])
    }

    private func makeContinuationThinkingEvent(id: String, seq: Int, turnID: String) -> AgentEvent {
        AgentEvent(eventID: id, seq: seq, vendor: "codex", workspaceID: workspaceID, sessionID: sessionID,
                  timestamp: "t", type: .thinking, role: nil, text: nil, name: nil, input: nil, output: nil,
                  toolCallID: nil, metadata: ["turn_id": turnID, "reason": "tool_call", "is_continuation": "true"])
    }

    func testLateTranscriptAnchorForTombstonedTurnIsRejectedWithZeroSeq() {
        let hub = newHub()
        // Establish `currentTurnID` via a GENUINE ordinary anchor first —
        // without this, the continuation fixture below would be rejected
        // anyway by the pre-existing identity guard (continuationTurnID ==
        // trackedTurnID, which requires trackedTurnID to already be set),
        // proving nothing about the NEW semantic-tombstone gate.
        hub.publish(makeAnchorThinkingEvent(id: "original-anchor", seq: 1, turnID: turnID))

        let key = logical()
        let o = owner(key)
        _ = startHub(hub, logical: key, owner: o)
        _ = hub.admitAppServerWorkingControl(logical: key, ownerKey: o, workspaceID: workspaceID,
                                             observation: .turnTerminal(threadID: root, turnID: turnID, rawStatus: "completed", time: "t2")).events

        let beforeFetch = hub.fetch(workspaceID: workspaceID, sessionID: sessionID, limit: 100)
        let highWaterBefore = beforeFetch.newestSeq

        // The late anchor is NOT blocked by any identity guard (an anchor
        // always supersedes) — only the NEW semantic-tombstone gate can
        // reject it. The late continuation, with currentTurnID already ==
        // turnID from the original anchor above, likewise now genuinely
        // exercises the NEW gate rather than the pre-existing identity
        // check.
        hub.publish(makeAnchorThinkingEvent(id: "late-anchor", seq: 10, turnID: turnID))
        hub.publish(makeContinuationThinkingEvent(id: "late-continuation", seq: 11, turnID: turnID))

        let afterFetch = hub.fetch(workspaceID: workspaceID, sessionID: sessionID, limit: 100)
        XCTAssertFalse(afterFetch.events.contains { $0.eventID == "late-anchor" || $0.eventID == "late-continuation" })
        XCTAssertEqual(afterFetch.newestSeq, highWaterBefore, "a tombstoned-turn late transcript event must consume zero cursor/seq")
    }

    // Mutation killer: terminal-before-start (no prior admitted start at
    // all for this logical turn) must still tombstone — the FIRST typed
    // observation this session ever sees for this turn is itself a
    // terminal.
    func testTerminalBeforeStartStillTombstones() {
        let hub = newHub()
        let key = logical()
        let o = owner(key)
        let terminal = hub.admitAppServerWorkingControl(logical: key, ownerKey: o, workspaceID: workspaceID,
                                                         observation: .turnTerminal(threadID: root, turnID: turnID, rawStatus: "completed", time: "t1"))
        XCTAssertTrue(terminal.accepted, "terminal-before-start is still an accepted tombstone admission")
        XCTAssertTrue(terminal.events.isEmpty, "no matching current/suspended trajectory — no wire event")
        XCTAssertEqual(terminal.ownerContextEffect, .clearIfMatching(key),
                       "terminal admission never sets an owner active — only ever a conditional clear")
        XCTAssertTrue(hub.appServerControlDebugSnapshotForTesting(sessionID: sessionID).semanticTombstones.contains(key))

        let lateStart = hub.admitAppServerWorkingControl(logical: key, ownerKey: o, workspaceID: workspaceID,
                                                          observation: .turnStarted(threadID: root, turnID: turnID, time: "t2"))
        XCTAssertFalse(lateStart.accepted, "the tombstone must reject a start arriving after a terminal-before-start")
        XCTAssertTrue(lateStart.events.isEmpty)
        XCTAssertEqual(lateStart.ownerContextEffect, .none)
    }

    // Mutation killer: a late terminal for A must never clear an already-
    // active DIFFERENT turn B, even though A's own terminal always
    // tombstones A.
    func testLateTerminalForAWithBAlreadyActiveDoesNotClearB() {
        let hub = newHub()
        let keyA = logical(turnID: "turn-A")
        let ownerA = owner(keyA)
        _ = hub.admitAppServerWorkingControl(logical: keyA, ownerKey: ownerA, workspaceID: workspaceID,
                                             observation: .turnStarted(threadID: root, turnID: "turn-A", time: "t1")).events
        hub.retireAppServerOwner(ownerA, workspaceID: workspaceID, reason: .transportClosed, time: "t2")

        let keyB = logical(turnID: "turn-B")
        let ownerB = owner(keyB, generation: "gen-2", token: "owner-2")
        _ = hub.admitAppServerWorkingControl(logical: keyB, ownerKey: ownerB, workspaceID: workspaceID,
                                             observation: .turnStarted(threadID: root, turnID: "turn-B", time: "t3")).events
        XCTAssertEqual(hub.appServerControlDebugSnapshotForTesting(sessionID: sessionID).currentLogicalTurn, keyB)

        // A's own late terminal (from the retired owner's connection) still
        // arrives — it must tombstone A only, never touch B.
        let lateTerminalA = hub.admitAppServerWorkingControl(logical: keyA, ownerKey: ownerA, workspaceID: workspaceID,
                                                              observation: .turnTerminal(threadID: root, turnID: "turn-A", rawStatus: "completed", time: "t4"))
        XCTAssertTrue(lateTerminalA.accepted, "A's own terminal is a valid tombstone admission")
        XCTAssertTrue(lateTerminalA.events.isEmpty, "A was only suspended (not current), so its terminal produces no wire event, but still tombstones")
        XCTAssertEqual(lateTerminalA.ownerContextEffect, .clearIfMatching(keyA),
                       "the effect names A, not B — a caller whose mapping is currently B (per the assertion above) must apply this and see it's a no-op, staying B")
        XCTAssertEqual(hub.appServerControlDebugSnapshotForTesting(sessionID: sessionID).currentLogicalTurn, keyB,
                       "B must remain completely untouched by A's late terminal")
    }

    func testTwoOwnersNonLastDisconnectProducesZeroTerminal() {
        let hub = newHub()
        let key = logical()
        let owner1 = owner(key, generation: "gen-1", token: "owner-1")
        _ = startHub(hub, logical: key, owner: owner1)
        let owner2 = owner(key, generation: "gen-2", token: "owner-2")
        _ = hub.admitAppServerWorkingControl(logical: key, ownerKey: owner2, workspaceID: workspaceID,
                                             observation: .turnStarted(threadID: root, turnID: turnID, time: "t2")).events

        let disconnect1 = hub.retireAppServerOwner(owner1, workspaceID: workspaceID, reason: .transportClosed, time: "t3")
        XCTAssertNil(disconnect1, "another live owner (owner2) remains — no UI terminal")
        XCTAssertEqual(hub.appServerControlDebugSnapshotForTesting(sessionID: sessionID).currentLogicalTurn, key)
        XCTAssertNil(hub.appServerControlDebugSnapshotForTesting(sessionID: sessionID).suspendedLogicalTurn)
    }

    // Mutation killer: establishes a REAL legacy `currentTurnID` via an
    // ordinary transcript anchor for the SAME turn ID, to prove the typed
    // semantic terminal blocks BOTH the typed resume AND the pre-existing
    // legacy `thinking-resume:*` path — a typed terminal only clears
    // app-server control state, never `currentTurnID` (a separate
    // transcript-vendor field), so without an explicit legacy-side
    // tombstone check the legacy path could still resurrect Working.
    func testPromptOpenThenSemanticTerminalThenExactResolveProducesZeroTypedAndZeroLegacyResume() {
        let hub = newHub()
        hub.publish(makeAnchorThinkingEvent(id: "anchor-a", seq: 1, turnID: turnID))
        XCTAssertNotNil(hub.fetch(workspaceID: workspaceID, sessionID: sessionID, limit: 100).events.first { $0.eventID == "anchor-a" })

        let key = logical()
        let o = owner(key)
        _ = startHub(hub, logical: key, owner: o)

        hub.publish(makeNativePromptEvent(id: "p1", seq: 10, promptID: "prompt-1", token: "tok-1"))
        // The turn reaches a genuine semantic terminal WHILE the prompt is
        // still open (e.g. the app-server itself ended the turn).
        _ = hub.admitAppServerWorkingControl(logical: key, ownerKey: o, workspaceID: workspaceID,
                                             observation: .turnTerminal(threadID: root, turnID: turnID, rawStatus: "completed", time: "t2")).events
        XCTAssertNil(hub.appServerControlDebugSnapshotForTesting(sessionID: sessionID).currentLogicalTurn)

        let highWaterBeforeResolve = hub.fetch(workspaceID: workspaceID, sessionID: sessionID, limit: 100).newestSeq
        hub.publish(makeNativeResolvedEvent(id: "r1", seq: 11, promptID: "prompt-1", token: "tok-1"))
        let afterResolve = hub.fetch(workspaceID: workspaceID, sessionID: sessionID, limit: 100).events
        let typedResumes = afterResolve.filter { $0.metadata?["reason"] == "resume_snapshot" }
        let legacyResumes = afterResolve.filter { $0.eventID.hasPrefix("thinking-resume:") }
        XCTAssertTrue(typedResumes.isEmpty, "a semantically-terminated turn must never resume via typed control")
        XCTAssertTrue(legacyResumes.isEmpty, "the legacy path must ALSO respect the app-server semantic tombstone for the same turn")
        // The resolved event's own storage (rebased above the existing
        // high-water, since it collides with the typed terminal's own
        // consumed seq) is the ONLY new high-water contribution — exactly
        // +1, never +2, which a phantom resume event would have produced.
        XCTAssertEqual(hub.fetch(workspaceID: workspaceID, sessionID: sessionID, limit: 100).newestSeq,
                       highWaterBeforeResolve + 1)
    }

    func testExpiredCloseNeverLeavesASnapshot() {
        let hub = newHub()
        let key = logical()
        let o = owner(key)
        _ = startHub(hub, logical: key, owner: o)
        XCTAssertNotNil(hub.appServerControlDebugSnapshotForTesting(sessionID: sessionID).latestSnapshot)

        hub.publish(makeNativePromptEvent(id: "p1", seq: 10, promptID: "prompt-1", token: "tok-1"))
        XCTAssertNil(hub.appServerControlDebugSnapshotForTesting(sessionID: sessionID).latestSnapshot)

        hub.publish(makeNativeResolvedEvent(id: "r1", seq: 11, promptID: "prompt-1", token: "tok-1", reason: "expired"))
        XCTAssertNil(hub.appServerControlDebugSnapshotForTesting(sessionID: sessionID).latestSnapshot,
                    "an expired (non-resuming) close must leave the snapshot nil, not resurrect it")
    }

    func testTranscriptEpochResetSequenceStillRejectsTombstonedTurn() {
        let hub = newHub()
        hub.beginAppServerControlIncarnation(sessionID: sessionID, epoch: epoch, rootThreadID: root)
        let key = logical()
        let o = owner(key)
        _ = startHub(hub, logical: key, owner: o)
        _ = hub.admitAppServerWorkingControl(logical: key, ownerKey: o, workspaceID: workspaceID,
                                             observation: .turnTerminal(threadID: root, turnID: turnID, rawStatus: "completed", time: "t2")).events

        // Full realistic sequence: beginNewSourceEpoch (transcript-only
        // reset) then a fresh sessionStarted — must NOT clear the
        // app-server semantic tombstone (that field is untouched by the
        // transcript-only reset).
        hub.beginNewSourceEpoch(sessionID: sessionID)
        let sessionStarted = AgentEvent(eventID: "session-started-2", seq: 1, vendor: "codex", workspaceID: workspaceID,
                                        sessionID: sessionID, timestamp: "t", type: .sessionStarted, role: nil,
                                        text: nil, name: nil, input: nil, output: nil, toolCallID: nil, metadata: nil)
        hub.publish(sessionStarted)

        hub.publish(makeAnchorThinkingEvent(id: "late-anchor-2", seq: 2, turnID: turnID))
        let events = hub.fetch(workspaceID: workspaceID, sessionID: sessionID, limit: 100).events
        XCTAssertFalse(events.contains { $0.eventID == "late-anchor-2" },
                       "transcript epoch reset must not clear the app-server semantic tombstone")

        // True control incarnation rotation clears the tombstone — the SAME
        // turn ID is legitimately reusable in a new incarnation.
        hub.beginAppServerControlIncarnation(sessionID: sessionID, epoch: "pid:2|sock:/tmp/b.sock", rootThreadID: root)
        hub.publish(makeAnchorThinkingEvent(id: "new-incarnation-anchor", seq: 3, turnID: turnID))
        let eventsAfterRotation = hub.fetch(workspaceID: workspaceID, sessionID: sessionID, limit: 100).events
        XCTAssertTrue(eventsAfterRotation.contains { $0.eventID == "new-incarnation-anchor" },
                      "a true incarnation rotation must allow the same turn ID to be reused")
    }

    // MARK: - Incarnation scoping (same epoch+root reattach preserves state)

    func testSameIncarnationReattachPreservesControlState() {
        let hub = newHub()
        hub.beginAppServerControlIncarnation(sessionID: sessionID, epoch: epoch, rootThreadID: root)
        let key = logical()
        let o = owner(key)
        _ = startHub(hub, logical: key, owner: o)

        // Same epoch+root reattach (e.g. runtime generation replacement for
        // the same underlying process/root) must be a no-op.
        hub.beginAppServerControlIncarnation(sessionID: sessionID, epoch: epoch, rootThreadID: root)
        XCTAssertEqual(hub.appServerControlDebugSnapshotForTesting(sessionID: sessionID).currentLogicalTurn, key,
                       "same-incarnation reattach must preserve current logical turn")
    }

    func testDifferentRootIsATrueIncarnationRotation() {
        let hub = newHub()
        hub.beginAppServerControlIncarnation(sessionID: sessionID, epoch: epoch, rootThreadID: root)
        let key = logical()
        let o = owner(key)
        _ = startHub(hub, logical: key, owner: o)

        hub.beginAppServerControlIncarnation(sessionID: sessionID, epoch: epoch, rootThreadID: "thread-2")
        XCTAssertNil(hub.appServerControlDebugSnapshotForTesting(sessionID: sessionID).currentLogicalTurn,
                    "a genuinely different root is a true incarnation rotation and must clear control state")
    }

    // MARK: - Snapshot overlay (fetch/replay independent of the trim-sensitive buffer)

    func testTinyBufferTrimSnapshotFullFetchAndReplaySameEventOnce() {
        // Buffer holds 10 — the snapshot (published FIRST, before the 10
        // fillers) is exactly the one entry trimmed out; all 10 fillers
        // survive, giving a clean base page to assert bounds against.
        let hub = newHub(maxBufferedEvents: 10)
        let key = logical()
        let o = owner(key)
        let opened = startHub(hub, logical: key, owner: o)
        let snapshotEvent = try! XCTUnwrap(opened.first)

        for i in 0..<10 {
            hub.publish(makeFillerToolCallEvent(id: "filler-\(i)", seq: 100 + i, timestamp: "t\(100 + i)"))
        }
        // beforeSeq disables overlay entirely, so this proves the snapshot
        // is truly gone from the physical (trimmed) buffer, not merely
        // absent from some unrelated page.
        let rawFetch = hub.fetch(workspaceID: workspaceID, sessionID: sessionID, limit: 100, beforeSeq: Int.max)
        XCTAssertFalse(rawFetch.events.contains { $0.eventID == snapshotEvent.eventID })

        let fullFetch = hub.fetch(workspaceID: workspaceID, sessionID: sessionID, limit: 100)
        let matches = fullFetch.events.filter { $0.eventID == snapshotEvent.eventID }
        XCTAssertEqual(matches.count, 1, "full fetch must inject the snapshot exactly once")
        XCTAssertEqual(matches.first?.seq, snapshotEvent.seq)
        // Page bounds reflect the base 100-item page, unaffected by the
        // one extra overlaid event.
        XCTAssertEqual(fullFetch.oldestSeq, 100)
        XCTAssertEqual(fullFetch.newestSeq, 109)
        XCTAssertFalse(fullFetch.hasMore)

        let (subscriberID, replay) = hub.subscribe(workspaceID: workspaceID, sessionID: sessionID, sinceSeq: nil) { _ in }
        defer { hub.unsubscribe(subscriberID) }
        let replayMatches = replay.filter { $0.event.eventID == snapshotEvent.eventID }
        XCTAssertEqual(replayMatches.count, 1, "sinceSeq:nil replay must inject the snapshot exactly once")
    }

    func testAfterSeqOverlayOnlyWhenSnapshotStrictlyNewerThanCursor() {
        let hub = newHub(maxBufferedEvents: 2)
        let key = logical()
        let o = owner(key)
        let opened = startHub(hub, logical: key, owner: o)
        let snapshotEvent = try! XCTUnwrap(opened.first)
        for i in 0..<10 {
            hub.publish(makeFillerToolCallEvent(id: "filler-\(i)", seq: 100 + i, timestamp: "t\(100 + i)"))
        }

        let belowCursor = hub.fetch(workspaceID: workspaceID, sessionID: sessionID, limit: 100, afterSeq: snapshotEvent.seq - 1)
        XCTAssertTrue(belowCursor.events.contains { $0.eventID == snapshotEvent.eventID },
                      "afterSeq strictly below the snapshot's own seq must inject it")

        let atCursor = hub.fetch(workspaceID: workspaceID, sessionID: sessionID, limit: 100, afterSeq: snapshotEvent.seq)
        XCTAssertFalse(atCursor.events.contains { $0.eventID == snapshotEvent.eventID },
                       "afterSeq == snapshot.seq must NOT inject (strictly newer only)")
    }

    func testBeforeSeqAndNoReplaySentinelNeverOverlay() {
        let hub = newHub(maxBufferedEvents: 2)
        let key = logical()
        let o = owner(key)
        let opened = startHub(hub, logical: key, owner: o)
        let snapshotEvent = try! XCTUnwrap(opened.first)
        for i in 0..<10 {
            hub.publish(makeFillerToolCallEvent(id: "filler-\(i)", seq: 100 + i, timestamp: "t\(100 + i)"))
        }

        let beforeFetch = hub.fetch(workspaceID: workspaceID, sessionID: sessionID, limit: 100, beforeSeq: 1000)
        XCTAssertFalse(beforeFetch.events.contains { $0.eventID == snapshotEvent.eventID },
                       "beforeSeq (backward pagination) must never overlay")

        let (subscriberID, noReplay) = hub.subscribe(workspaceID: workspaceID, sessionID: sessionID, sinceSeq: Int.max) { _ in }
        defer { hub.unsubscribe(subscriberID) }
        XCTAssertFalse(noReplay.contains { $0.event.eventID == snapshotEvent.eventID },
                       "the noReplay sentinel (sinceSeq = Int.max) must never overlay")
    }

    func testSnapshotStillInPageIsNotDuplicated() {
        let hub = newHub()
        let key = logical()
        let o = owner(key)
        let opened = startHub(hub, logical: key, owner: o)
        let snapshotEvent = try! XCTUnwrap(opened.first)

        // Small buffer, snapshot still resident (not trimmed) — the overlay
        // must recognize it's already in the page and add nothing.
        let fullFetch = hub.fetch(workspaceID: workspaceID, sessionID: sessionID, limit: 100)
        XCTAssertEqual(fullFetch.events.filter { $0.eventID == snapshotEvent.eventID }.count, 1)
    }

    // Independent mutation-kill: after a genuine SEMANTIC TERMINAL (not a
    // disconnect), evict the terminated turn's own event from the trimmed
    // buffer via churn, then prove overlay does NOT resurrect it — the only
    // way it could reappear is via `appServerLatestControlSnapshot`, which
    // the terminal must have cleared.
    func testSemanticTerminalStopsOverlayAfterTrim() {
        let hub = newHub(maxBufferedEvents: 5)
        let key = logical()
        let o = owner(key)
        let opened = startHub(hub, logical: key, owner: o)
        let openEventID = try! XCTUnwrap(opened.first?.eventID)

        let terminal = hub.admitAppServerWorkingControl(logical: key, ownerKey: o, workspaceID: workspaceID,
                                                         observation: .turnTerminal(threadID: root, turnID: turnID, rawStatus: "completed", time: "t2"))
        XCTAssertTrue(terminal.accepted)
        XCTAssertNil(hub.appServerControlDebugSnapshotForTesting(sessionID: sessionID).latestSnapshot,
                    "a semantic terminal must clear the snapshot")

        for i in 0..<10 {
            hub.publish(makeFillerToolCallEvent(id: "post-terminal-churn-\(i)", seq: 200 + i, timestamp: "t\(200 + i)"))
        }
        let afterChurn = hub.fetch(workspaceID: workspaceID, sessionID: sessionID, limit: 100)
        XCTAssertFalse(afterChurn.events.contains { $0.eventID == openEventID },
                       "the terminated turn's own open event must be gone from both storage AND overlay after trim")
    }

    // Independent mutation-kill: same shape, but for OWNER DISCONNECT
    // (never a semantic terminal) — a distinct code path
    // (`retireAppServerOwner`) that must ALSO clear the snapshot on its
    // own, not merely by coincidentally sharing logic with the terminal
    // path.
    func testLastOwnerDisconnectStopsOverlayAfterTrim() {
        let hub = newHub(maxBufferedEvents: 5)
        let key = logical()
        let o = owner(key)
        let opened = startHub(hub, logical: key, owner: o)
        let openEventID = try! XCTUnwrap(opened.first?.eventID)

        let disconnect = hub.retireAppServerOwner(o, workspaceID: workspaceID, reason: .transportClosed, time: "t2")
        XCTAssertNotNil(disconnect)
        XCTAssertNil(hub.appServerControlDebugSnapshotForTesting(sessionID: sessionID).latestSnapshot,
                    "the last owner's disconnect must clear the snapshot")

        for i in 0..<10 {
            hub.publish(makeFillerToolCallEvent(id: "post-disconnect-churn-\(i)", seq: 200 + i, timestamp: "t\(200 + i)"))
        }
        let afterChurn = hub.fetch(workspaceID: workspaceID, sessionID: sessionID, limit: 100)
        XCTAssertFalse(afterChurn.events.contains { $0.eventID == openEventID },
                       "the disconnected turn's own open event must be gone from both storage AND overlay after trim")
    }

    // MARK: - Prompt lifecycle vs full replay

    func testPromptExpiredOrMismatchNeverLeavesStaleReplaySnapshotExactResolveDoes() {
        let hub = newHub()
        let key = logical()
        let o = owner(key)
        _ = startHub(hub, logical: key, owner: o)

        hub.publish(makeNativePromptEvent(id: "p1", seq: 10, promptID: "prompt-1", token: "tok-1"))
        hub.publish(makeNativeResolvedEvent(id: "r1", seq: 11, promptID: "prompt-1", token: "tok-1", reason: "expired"))

        let afterExpired = hub.subscribe(workspaceID: workspaceID, sessionID: sessionID, sinceSeq: nil) { _ in }.1
        XCTAssertTrue(afterExpired.filter { $0.event.metadata?["reason"] == "resume_snapshot" }.isEmpty,
                      "an expired close must never leave a stale resume visible on full replay")

        hub.publish(makeNativePromptEvent(id: "p2", seq: 12, promptID: "prompt-2", token: "tok-2"))
        hub.publish(makeNativeResolvedEvent(id: "r2", seq: 13, promptID: "prompt-2", token: "tok-2"))

        let afterExact = hub.subscribe(workspaceID: workspaceID, sessionID: sessionID, sinceSeq: nil) { _ in }.1
        let resumes = afterExact.filter { $0.event.metadata?["reason"] == "resume_snapshot" }
        let legacyResumes = afterExact.filter { $0.event.eventID.hasPrefix("thinking-resume:") }
        XCTAssertEqual(resumes.count, 1, "the second, EXACT prompt lifecycle must produce a fresh typed resume")
        XCTAssertTrue(legacyResumes.isEmpty)
    }

    // MARK: - Live sessionStarted boundary reassert

    func testSessionStartedBoundaryProducesExactlyOneFreshResumeAfterBoundaryWithMonotonicSeq() {
        let hub = newHub()
        let key = logical()
        let o = owner(key)
        _ = startHub(hub, logical: key, owner: o)

        final class Collector: @unchecked Sendable {
            private let lock = NSLock()
            private var envelopes: [AgentEventEnvelope] = []
            func append(_ e: AgentEventEnvelope) { lock.lock(); envelopes.append(e); lock.unlock() }
            func all() -> [AgentEventEnvelope] { lock.lock(); defer { lock.unlock() }; return envelopes }
        }
        let collector = Collector()
        let (subscriberID, _) = hub.subscribe(workspaceID: workspaceID, sessionID: sessionID, sinceSeq: nil) { collector.append($0) }
        defer { hub.unsubscribe(subscriberID) }

        hub.beginNewSourceEpoch(sessionID: sessionID)
        let sessionStarted = AgentEvent(eventID: "session-started-boundary", seq: 1, vendor: "codex", workspaceID: workspaceID,
                                        sessionID: sessionID, timestamp: "t-boundary", type: .sessionStarted, role: nil,
                                        text: nil, name: nil, input: nil, output: nil, toolCallID: nil, metadata: nil)
        hub.publish(sessionStarted)
        hub.drainDeliveriesForTesting()

        let delivered = collector.all().map(\.event)
        let boundaryIndex = delivered.firstIndex { $0.eventID == "session-started-boundary" }
        let resumeIndex = delivered.firstIndex { $0.metadata?["reason"] == "resume_snapshot" }
        XCTAssertNotNil(boundaryIndex)
        guard let boundaryIndex, let resumeIndex else {
            return XCTFail("expected both boundary and resume delivered")
        }
        XCTAssertLessThan(boundaryIndex, resumeIndex, "delivery order must be sessionStarted THEN the typed resume")
        XCTAssertEqual(delivered.filter { $0.metadata?["reason"] == "resume_snapshot" }.count, 1)
        let storedBoundarySeq = delivered[boundaryIndex].seq
        let storedResumeSeq = delivered[resumeIndex].seq
        XCTAssertGreaterThan(storedResumeSeq, storedBoundarySeq, "the resume's stored seq must be strictly greater than the boundary's")

        // The resume carries the REAL owner context, not a placeholder.
        XCTAssertEqual(delivered[resumeIndex].metadata?["owner_token"], o.ownerToken)
        XCTAssertEqual(delivered[resumeIndex].metadata?["runtime_generation"], o.runtimeGeneration)

        // The transcript-only boundary must NOT have disturbed any
        // app-server control state — current/owners/tombstones survive
        // exactly as `beginNewSourceEpoch` (a transcript-scoped reset)
        // documents.
        let snapshotAfter = hub.appServerControlDebugSnapshotForTesting(sessionID: sessionID)
        XCTAssertEqual(snapshotAfter.currentLogicalTurn, key)
        XCTAssertTrue(snapshotAfter.activeOwners.contains(o))
        XCTAssertTrue(snapshotAfter.semanticTombstones.isEmpty)
    }

    // Pairs with the seen-ID-rebuild dedupe tests above, but for the
    // sessionStarted boundary specifically: while the boundary's own
    // eventID is still within the bounded `seenEventIDs` window, an exact
    // retry of the SAME stored sessionStarted must be swallowed by
    // publish()'s own top-level dedup before ever reaching the fold — zero
    // additional resume. Once ordinary churn evicts it from that window and
    // the exact same eventID is genuinely re-accepted (necessarily at a
    // REBASED, higher seq, since it collides with the high-water), that
    // IS a new admission and must mint its own fresh resume — both
    // resumes' seqs still monotonic relative to their own boundary.
    func testSessionStartedBoundaryExactRetryWithinSeenWindowIsZeroButReacceptedAfterRebuildPairsWithFreshResume() {
        // Small buffer AND small maxSeenEventIDs: the churn below both
        // physically evicts the boundary's own stored event from the
        // buffer AND forces publish()'s seenEventIDs rebuild — the ONLY way
        // the exact same eventID can be genuinely re-accepted (necessarily
        // rebased to a new, higher seq) rather than swallowed by the
        // top-level dedup.
        let hub = AgentEventHub(maxBufferedEvents: 5, maxSeenEventIDs: 5)
        hub.beginAppServerControlIncarnation(sessionID: sessionID, epoch: epoch, rootThreadID: root)
        let key = logical()
        let o = owner(key)
        _ = startHub(hub, logical: key, owner: o)

        final class Collector: @unchecked Sendable {
            private let lock = NSLock()
            private var envelopes: [AgentEventEnvelope] = []
            func append(_ e: AgentEventEnvelope) { lock.lock(); envelopes.append(e); lock.unlock() }
            func all() -> [AgentEventEnvelope] { lock.lock(); defer { lock.unlock() }; return envelopes }
        }
        let collector = Collector()
        // sinceSeq = Int.max: the noReplay sentinel — the collector only
        // ever sees LIVE deliveries, exactly like a real long-lived
        // subscriber tail.
        let (subscriberID, initialReplay) = hub.subscribe(workspaceID: workspaceID, sessionID: sessionID, sinceSeq: Int.max) { collector.append($0) }
        defer { hub.unsubscribe(subscriberID) }
        XCTAssertTrue(initialReplay.isEmpty)

        hub.beginNewSourceEpoch(sessionID: sessionID)
        let boundary = AgentEvent(eventID: "boundary-pair", seq: 1, vendor: "codex", workspaceID: workspaceID,
                                  sessionID: sessionID, timestamp: "t1", type: .sessionStarted, role: nil,
                                  text: nil, name: nil, input: nil, output: nil, toolCallID: nil, metadata: nil)
        hub.publish(boundary)
        hub.drainDeliveriesForTesting()

        // Exact retry while still within the seen window: publish()'s own
        // top-level dedup swallows it before the fold ever runs — zero
        // additional delivery of either the boundary or a resume.
        hub.publish(boundary)
        hub.drainDeliveriesForTesting()

        // Ordinary churn: evicts the boundary's stored event from the
        // 5-slot buffer, and (once seenEventIDs exceeds maxSeenEventIDs(5))
        // rebuilds seenEventIDs against the now-boundary-free buffer.
        for i in 0..<20 {
            hub.publish(makeFillerToolCallEvent(id: "pair-churn-\(i)", seq: 100 + i, timestamp: "t\(100 + i)"))
            hub.drainDeliveriesForTesting()
        }

        // Genuinely re-accepted: same eventID, same ORIGINALLY claimed seq
        // (1) — no longer in seenEventIDs, so it is treated as unseen and
        // rebased above the accumulated high-water, running the
        // `.sessionStarted` fold a SECOND time as a bona fide new
        // admission.
        hub.publish(boundary)
        hub.drainDeliveriesForTesting()

        let delivered = collector.all().map(\.event)
        let boundaries = delivered.filter { $0.eventID == "boundary-pair" }
        let resumes = delivered.filter { $0.metadata?["reason"] == "resume_snapshot" }
        XCTAssertEqual(boundaries.count, 2, "exact retry within the seen window must not re-deliver; the post-rebuild retry must")
        XCTAssertEqual(resumes.count, 2, "each genuinely-accepted boundary pairs with exactly one fresh resume")
        guard boundaries.count == 2, resumes.count == 2 else {
            return
        }
        XCTAssertLessThan(boundaries[0].seq, resumes[0].seq)
        XCTAssertLessThan(resumes[0].seq, boundaries[1].seq)
        XCTAssertLessThan(boundaries[1].seq, resumes[1].seq)

        let snapshotAfter = hub.appServerControlDebugSnapshotForTesting(sessionID: sessionID)
        XCTAssertEqual(snapshotAfter.currentLogicalTurn, key, "current must survive both boundaries")
        XCTAssertTrue(snapshotAfter.activeOwners.contains(o), "owner must survive both boundaries")
    }

    func testSessionStartedBoundaryGatesEachProduceZeroResume() {
        // Gate 1: snapshot nil, in ISOLATION from the active-prompt gate —
        // the prompt already closed (activePromptLifecycle is EMPTY) via an
        // "expired" resolve (never eligible to resume), current+owner are
        // STILL live and untouched. If the snapshot-nil check were deleted,
        // every OTHER gate here would still pass (no active prompt, current
        // live, owner live), so only this exact scenario can catch that
        // specific mutation.
        do {
            let hub = newHub()
            let key = logical()
            let o = owner(key)
            _ = startHub(hub, logical: key, owner: o)
            hub.publish(makeNativePromptEvent(id: "p1", seq: 10, promptID: "prompt-1", token: "tok-1"))
            hub.publish(makeNativeResolvedEvent(id: "r1", seq: 11, promptID: "prompt-1", token: "tok-1", reason: "expired"))
            XCTAssertTrue(hub.appServerControlDebugSnapshotForTesting(sessionID: sessionID).activeOwners.contains(o),
                          "owner must still be live")
            XCTAssertEqual(hub.appServerControlDebugSnapshotForTesting(sessionID: sessionID).currentLogicalTurn, key,
                           "current must still be live")
            XCTAssertNil(hub.appServerControlDebugSnapshotForTesting(sessionID: sessionID).latestSnapshot,
                        "expired (non-resuming) close leaves the snapshot nil — this is the exact condition under test")
            hub.beginNewSourceEpoch(sessionID: sessionID)
            hub.publish(AgentEvent(eventID: "boundary-1", seq: 1, vendor: "codex", workspaceID: workspaceID, sessionID: sessionID,
                                   timestamp: "t", type: .sessionStarted, role: nil, text: nil, name: nil, input: nil, output: nil,
                                   toolCallID: nil, metadata: nil))
            let resumes = hub.fetch(workspaceID: workspaceID, sessionID: sessionID, limit: 100).events
                .filter { $0.metadata?["reason"] == "resume_snapshot" }
            XCTAssertTrue(resumes.isEmpty, "snapshot nil ALONE, with every other gate satisfied, must still produce zero boundary resume")
        }
        // Gate 2: suspended/ownerless.
        do {
            let hub = newHub()
            let key = logical()
            let o = owner(key)
            _ = startHub(hub, logical: key, owner: o)
            hub.retireAppServerOwner(o, workspaceID: workspaceID, reason: .transportClosed, time: "t2")
            hub.beginNewSourceEpoch(sessionID: sessionID)
            hub.publish(AgentEvent(eventID: "boundary-2", seq: 1, vendor: "codex", workspaceID: workspaceID, sessionID: sessionID,
                                   timestamp: "t", type: .sessionStarted, role: nil, text: nil, name: nil, input: nil, output: nil,
                                   toolCallID: nil, metadata: nil))
            let resumes = hub.fetch(workspaceID: workspaceID, sessionID: sessionID, limit: 100).events
                .filter { $0.metadata?["reason"] == "resume_snapshot" }
            XCTAssertTrue(resumes.isEmpty, "an ownerless suspended turn must produce zero boundary resume")
        }
        // Gate 3: semantic terminal.
        do {
            let hub = newHub()
            let key = logical()
            let o = owner(key)
            _ = startHub(hub, logical: key, owner: o)
            _ = hub.admitAppServerWorkingControl(logical: key, ownerKey: o, workspaceID: workspaceID,
                                                 observation: .turnTerminal(threadID: root, turnID: turnID, rawStatus: "completed", time: "t2"))
            hub.beginNewSourceEpoch(sessionID: sessionID)
            hub.publish(AgentEvent(eventID: "boundary-3", seq: 1, vendor: "codex", workspaceID: workspaceID, sessionID: sessionID,
                                   timestamp: "t", type: .sessionStarted, role: nil, text: nil, name: nil, input: nil, output: nil,
                                   toolCallID: nil, metadata: nil))
            let resumes = hub.fetch(workspaceID: workspaceID, sessionID: sessionID, limit: 100).events
                .filter { $0.metadata?["reason"] == "resume_snapshot" }
            XCTAssertTrue(resumes.isEmpty, "a semantically-terminated turn must produce zero boundary resume")
        }
        // Gate 4: true incarnation rotation (no current turn at all).
        do {
            let hub = newHub()
            let key = logical()
            let o = owner(key)
            _ = startHub(hub, logical: key, owner: o)
            hub.beginAppServerControlIncarnation(sessionID: sessionID, epoch: epoch, rootThreadID: "thread-rotated")
            hub.beginNewSourceEpoch(sessionID: sessionID)
            hub.publish(AgentEvent(eventID: "boundary-4", seq: 1, vendor: "codex", workspaceID: workspaceID, sessionID: sessionID,
                                   timestamp: "t", type: .sessionStarted, role: nil, text: nil, name: nil, input: nil, output: nil,
                                   toolCallID: nil, metadata: nil))
            let resumes = hub.fetch(workspaceID: workspaceID, sessionID: sessionID, limit: 100).events
                .filter { $0.metadata?["reason"] == "resume_snapshot" }
            XCTAssertTrue(resumes.isEmpty, "a rotated-away incarnation (no current turn) must produce zero boundary resume")
        }
    }

    func testSessionStartedBoundaryOrderSurvivesPendingApprovalMergeReducer() {
        let hub = newHub()
        let key = logical()
        let o = owner(key)
        _ = startHub(hub, logical: key, owner: o)

        hub.beginNewSourceEpoch(sessionID: sessionID)
        hub.publish(AgentEvent(eventID: "boundary-merge", seq: 1, vendor: "codex", workspaceID: workspaceID, sessionID: sessionID,
                               timestamp: "2026-01-01T00:00:00.000Z", type: .sessionStarted, role: nil, text: nil, name: nil,
                               input: nil, output: nil, toolCallID: nil, metadata: nil))

        let fetched = hub.fetch(workspaceID: workspaceID, sessionID: sessionID, limit: 100).events
        let boundary = try! XCTUnwrap(fetched.first { $0.eventID == "boundary-merge" })
        let resume = try! XCTUnwrap(fetched.first { $0.metadata?["reason"] == "resume_snapshot" })
        // Give the resume the SAME timestamp as the boundary (as real
        // production timestamps often coincide within a millisecond) to
        // prove the merge/reducer's seq tie-break still preserves order.
        let resumeSameTimestamp = AgentEvent(eventID: resume.eventID, seq: resume.seq, vendor: resume.vendor,
                                             workspaceID: resume.workspaceID, sessionID: resume.sessionID,
                                             timestamp: boundary.timestamp, type: resume.type, role: resume.role,
                                             text: resume.text, name: resume.name, input: resume.input, output: resume.output,
                                             toolCallID: resume.toolCallID, metadata: resume.metadata, payload: resume.payload)

        let merged = AgentInteractivePromptEventReducer.mergedEvents([boundary], [resumeSameTimestamp])
        let mergedBoundaryIndex = try! XCTUnwrap(merged.firstIndex { $0.eventID == boundary.eventID })
        let mergedResumeIndex = try! XCTUnwrap(merged.firstIndex { $0.eventID == resume.eventID })
        XCTAssertLessThan(mergedBoundaryIndex, mergedResumeIndex,
                          "even with an identical timestamp, the reducer's seq tie-break must keep boundary before resume")

        // Same proof through the actual PRODUCTION entry point (not just
        // the underlying reducer helper) — a real fetch page (containing
        // both the boundary and the fresh resume) merged against a
        // GENUINE pending interactive-prompt snapshot (not present in the
        // fetched page — simulating a still-open approval outside this
        // page's window) must preserve boundary < resume ordering, keep
        // the pending prompt itself, and introduce no duplicate eventIDs.
        let pendingPrompt = makeNativePromptEvent(id: "pending-prompt-1", seq: 5000, promptID: "pending-prompt", token: "pending-tok")
        let fetchResult = hub.fetch(workspaceID: workspaceID, sessionID: sessionID, limit: 100)
        let productionMerged = BridgePendingApprovalFetchMerge.merge(pageEvents: fetchResult.events,
                                                                      pageOldestSeq: fetchResult.oldestSeq,
                                                                      pageNewestSeq: fetchResult.newestSeq,
                                                                      pendingEvents: [pendingPrompt])
        let productionBoundaryIndex = try! XCTUnwrap(productionMerged.events.firstIndex { $0.eventID == boundary.eventID })
        let productionResumeIndex = try! XCTUnwrap(productionMerged.events.firstIndex { $0.eventID == resume.eventID })
        XCTAssertLessThan(productionBoundaryIndex, productionResumeIndex,
                          "the production merge entry point must also preserve boundary < resume ordering")
        XCTAssertTrue(productionMerged.events.contains { $0.eventID == pendingPrompt.eventID },
                      "the pending prompt itself must survive the merge")
        var seenIDs = Set<String>()
        for event in productionMerged.events {
            XCTAssertTrue(seenIDs.insert(event.eventID).inserted, "no duplicate eventIDs after the production merge")
        }
    }

    // MARK: - True incarnation rotation isolates old wire events

    func testTrueRotationHidesOldControlFromFetchAndReplayOrdinaryPreservedLateOldAdmitZeroCursor() {
        let hub = newHub()
        let key = logical()
        let o = owner(key)
        let opened = startHub(hub, logical: key, owner: o)
        let oldEventID = try! XCTUnwrap(opened.first?.eventID)

        hub.publish(makeFillerToolCallEvent(id: "ordinary-1", seq: 500))
        let highWaterBeforeRotation = hub.fetch(workspaceID: workspaceID, sessionID: sessionID, limit: 100).newestSeq

        hub.beginAppServerControlIncarnation(sessionID: sessionID, epoch: "pid:2|sock:/tmp/b.sock", rootThreadID: root)

        let afterRotation = hub.fetch(workspaceID: workspaceID, sessionID: sessionID, limit: 100)
        XCTAssertFalse(afterRotation.events.contains { $0.eventID == oldEventID }, "old control event must be invisible after true rotation")
        XCTAssertTrue(afterRotation.events.contains { $0.eventID == "ordinary-1" }, "ordinary events must survive rotation")
        XCTAssertGreaterThanOrEqual(afterRotation.newestSeq, highWaterBeforeRotation, "high-water must never regress")

        let replay = hub.subscribe(workspaceID: workspaceID, sessionID: sessionID, sinceSeq: nil) { _ in }.1
        XCTAssertFalse(replay.contains { $0.event.eventID == oldEventID })

        // A late observation for the OLD (now rotated-away) logical turn
        // must be rejected by the incarnation fence — zero cursor. Every
        // owner-bearing/terminal observation kind is checked, not just
        // start.
        let cursorBeforeLateAdmit = hub.fetch(workspaceID: workspaceID, sessionID: sessionID, limit: 100).newestSeq
        let lateOldStart = hub.admitAppServerWorkingControl(logical: key, ownerKey: o, workspaceID: workspaceID,
                                                            observation: .turnStarted(threadID: root, turnID: turnID, time: "t99"))
        XCTAssertFalse(lateOldStart.accepted)
        XCTAssertTrue(lateOldStart.events.isEmpty)
        XCTAssertEqual(lateOldStart.ownerContextEffect, .none)

        let lateOldActivity = hub.admitAppServerWorkingControl(logical: key, ownerKey: o, workspaceID: workspaceID,
                                                                observation: .internalActivityStarted(threadID: root, turnID: turnID, itemID: "item-late", kind: .sleep, time: "t99"))
        XCTAssertFalse(lateOldActivity.accepted)
        XCTAssertTrue(lateOldActivity.events.isEmpty)
        XCTAssertEqual(lateOldActivity.ownerContextEffect, .none)

        let lateOldTerminal = hub.admitAppServerWorkingControl(logical: key, ownerKey: o, workspaceID: workspaceID,
                                                                observation: .turnTerminal(threadID: root, turnID: turnID, rawStatus: "completed", time: "t99"))
        XCTAssertFalse(lateOldTerminal.accepted, "even an authoritative terminal for the OLD incarnation must fail the incarnation fence")
        XCTAssertTrue(lateOldTerminal.events.isEmpty)
        XCTAssertEqual(lateOldTerminal.ownerContextEffect, .none)

        XCTAssertEqual(hub.fetch(workspaceID: workspaceID, sessionID: sessionID, limit: 100).newestSeq, cursorBeforeLateAdmit,
                       "none of the three rejected late-old observations may advance the cursor")

        // The NEW incarnation admits normally, and its own seq is strictly
        // greater than everything the OLD incarnation ever stored.
        let keyNew = AppServerLogicalTurnKey(sessionID: sessionID, epoch: "pid:2|sock:/tmp/b.sock", rootThreadID: root, turnID: "turn-new")
        let ownerNew = AppServerOwnerKey(logical: keyNew, runtimeGeneration: "gen-3", ownerToken: "owner-3")
        let newStart = hub.admitAppServerWorkingControl(logical: keyNew, ownerKey: ownerNew, workspaceID: workspaceID,
                                                         observation: .turnStarted(threadID: root, turnID: "turn-new", time: "t100"))
        XCTAssertTrue(newStart.accepted)
        XCTAssertEqual(newStart.events.count, 1)
        XCTAssertGreaterThan(newStart.events[0].seq, cursorBeforeLateAdmit,
                            "the new incarnation's own start must be strictly above the pre-rotation stored cursor")
    }

    // A -> B -> A: the SAME (epoch, root) tuple is reused for a THIRD
    // incarnation (a restarted process reclaiming the same PID/socket) —
    // proves the true-rotation PURGE (not just a read-time filter) keeps
    // the first generation's artifacts permanently invisible even once the
    // exact same incarnation identity comes back around, and that the
    // reincarnated generation's own wire events are exactly-once.
    func testTripleRotationAThenBThenAgainANeverResurrectsFirstGenerationA() {
        let hub = newHub()
        let epochA = epoch
        let epochB = "pid:2|sock:/tmp/b.sock"

        // Generation 1: A.
        let key1 = logical(turnID: "turn-1")
        let owner1 = owner(key1, generation: "gen-1", token: "owner-1")
        let opened1 = startHub(hub, logical: key1, owner: owner1)
        let gen1EventID = try! XCTUnwrap(opened1.first?.eventID)
        let activity1 = hub.admitAppServerWorkingControl(logical: key1, ownerKey: owner1, workspaceID: workspaceID,
                                                          observation: .internalActivityStarted(threadID: root, turnID: "turn-1", itemID: "item-1", kind: .sleep, time: "t2"))
        let gen1ActivityEventID = try! XCTUnwrap(activity1.events.first?.eventID)
        let terminal1 = hub.admitAppServerWorkingControl(logical: key1, ownerKey: owner1, workspaceID: workspaceID,
                                                          observation: .turnTerminal(threadID: root, turnID: "turn-1", rawStatus: "completed", time: "t3"))
        let gen1TerminalEventID = try! XCTUnwrap(terminal1.events.first?.eventID)
        let gen1MaxSeq = [opened1.first?.seq, activity1.events.first?.seq, terminal1.events.first?.seq].compactMap { $0 }.max()!

        // Rotate to B.
        hub.beginAppServerControlIncarnation(sessionID: sessionID, epoch: epochB, rootThreadID: "thread-b")

        // Rotate BACK to the exact same (epoch, root) as generation 1 — a
        // genuinely new (3rd) incarnation, reusing the tuple.
        hub.beginAppServerControlIncarnation(sessionID: sessionID, epoch: epochA, rootThreadID: root)

        let fullFetch = hub.fetch(workspaceID: workspaceID, sessionID: sessionID, limit: 1000)
        for staleID in [gen1EventID, gen1ActivityEventID, gen1TerminalEventID] {
            XCTAssertFalse(fullFetch.events.contains { $0.eventID == staleID },
                           "generation-1 A's own artifact \(staleID) must never resurface after A -> B -> A")
        }
        let sinceNilReplay = hub.subscribe(workspaceID: workspaceID, sessionID: sessionID, sinceSeq: nil) { _ in }.1
        for staleID in [gen1EventID, gen1ActivityEventID, gen1TerminalEventID] {
            XCTAssertFalse(sinceNilReplay.contains { $0.event.eventID == staleID })
        }
        let afterSeqFetch = hub.fetch(workspaceID: workspaceID, sessionID: sessionID, limit: 1000, afterSeq: 0)
        for staleID in [gen1EventID, gen1ActivityEventID, gen1TerminalEventID] {
            XCTAssertFalse(afterSeqFetch.events.contains { $0.eventID == staleID })
        }

        // Generation 3 (A again) admits the EXACT SAME logical key as
        // generation 1 did (since the eventID scheme is generation-
        // independent) — its own wire event must appear exactly once, as a
        // genuinely new admission, not a leftover from generation 1.
        let owner3 = owner(key1, generation: "gen-3", token: "owner-3")
        let started3 = hub.admitAppServerWorkingControl(logical: key1, ownerKey: owner3, workspaceID: workspaceID,
                                                         observation: .turnStarted(threadID: root, turnID: "turn-1", time: "t10"))
        XCTAssertTrue(started3.accepted)
        XCTAssertEqual(started3.events.count, 1)
        let finalFetch = hub.fetch(workspaceID: workspaceID, sessionID: sessionID, limit: 1000)
        XCTAssertEqual(finalFetch.events.filter { $0.eventID == started3.events[0].eventID }.count, 1)
        // Generation 3 reuses the SAME deterministic eventID scheme as
        // generation 1 (turn_start for the same logical key) — but its
        // stored seq must be strictly greater than every seq generation 1
        // ever consumed, proving the high-water genuinely carried forward
        // across both rotations rather than resetting.
        XCTAssertEqual(started3.events[0].eventID, gen1EventID,
                       "same deterministic edge identity across generations, by construction of the eventID scheme")
        XCTAssertGreaterThan(started3.events[0].seq, gen1MaxSeq)
    }

    // Reattaching with the SAME incarnation (no rotation at all) must keep
    // every wire event and the snapshot visible exactly once — this is the
    // explicit contrast case for the purge logic above (which must trigger
    // ONLY on a genuine incarnation change, never on a same-incarnation
    // reattach).
    func testSameIncarnationReattachKeepsWireAndSnapshotVisibleExactlyOnce() {
        let hub = newHub()
        let key = logical()
        let o = owner(key)
        let opened = startHub(hub, logical: key, owner: o)
        let eventID = try! XCTUnwrap(opened.first?.eventID)

        hub.beginAppServerControlIncarnation(sessionID: sessionID, epoch: epoch, rootThreadID: root)

        let fetch = hub.fetch(workspaceID: workspaceID, sessionID: sessionID, limit: 1000)
        XCTAssertEqual(fetch.events.filter { $0.eventID == eventID }.count, 1)
        XCTAssertNotNil(hub.appServerControlDebugSnapshotForTesting(sessionID: sessionID).latestSnapshot)
        let replay = hub.subscribe(workspaceID: workspaceID, sessionID: sessionID, sinceSeq: nil) { _ in }.1
        XCTAssertEqual(replay.filter { $0.event.eventID == eventID }.count, 1)
    }

    // MARK: - Seen-ID capacity churn does not defeat control dedupe

    func testOrdinaryChurnTriggeringSeenIDRebuildStillDedupesControlEdges() {
        // Small buffer AND small maxSeenEventIDs: churn below must both
        // physically EVICT activity X's own stored event from the buffer
        // AND force publish()'s seenEventIDs rebuild-against-bufferedEvents
        // path — proving `appServerAdmittedEdgeIDs` (unlike seenEventIDs)
        // survives BOTH kinds of churn untouched.
        let hub = AgentEventHub(maxBufferedEvents: 5, maxSeenEventIDs: 4)
        hub.beginAppServerControlIncarnation(sessionID: sessionID, epoch: epoch, rootThreadID: root)
        let key = logical()
        let o = owner(key)
        _ = startHub(hub, logical: key, owner: o)

        // Admit activity X FIRST.
        let admittedX = hub.admitAppServerWorkingControl(logical: key, ownerKey: o, workspaceID: workspaceID,
                                                          observation: .internalActivityStarted(threadID: root, turnID: turnID, itemID: "item-x", kind: .sleep, time: "t2"))
        XCTAssertEqual(admittedX.events.count, 1)
        let xEventID = try! XCTUnwrap(admittedX.events.first?.eventID)

        // Ordinary churn AFTER X — enough to both evict X from the 5-slot
        // buffer and blow past maxSeenEventIDs(4), forcing the rebuild.
        for i in 0..<20 {
            hub.publish(makeFillerToolCallEvent(id: "churn-\(i)", seq: 200 + i, timestamp: "t\(200 + i)"))
        }
        let baseline = hub.fetch(workspaceID: workspaceID, sessionID: sessionID, limit: 100, beforeSeq: Int.max)
        XCTAssertFalse(baseline.events.contains { $0.eventID == xEventID }, "X must be physically evicted from the trimmed buffer")

        // X is still the CURRENT snapshot (the latest admitted continuation)
        // — full fetch/replay overlay must still surface it exactly once.
        let fullFetch = hub.fetch(workspaceID: workspaceID, sessionID: sessionID, limit: 100)
        XCTAssertEqual(fullFetch.events.filter { $0.eventID == xEventID }.count, 1)
        let replay = hub.subscribe(workspaceID: workspaceID, sessionID: sessionID, sinceSeq: nil) { _ in }.1
        XCTAssertEqual(replay.filter { $0.event.eventID == xEventID }.count, 1)

        let highWaterBeforeRetry = hub.fetch(workspaceID: workspaceID, sessionID: sessionID, limit: 100).newestSeq
        // Retry the EXACT same (now-evicted, seenEventIDs-rebuilt-away) X.
        let retryX = hub.admitAppServerWorkingControl(logical: key, ownerKey: o, workspaceID: workspaceID,
                                                       observation: .internalActivityStarted(threadID: root, turnID: turnID, itemID: "item-x", kind: .sleep, time: "t300"))
        XCTAssertTrue(retryX.accepted)
        XCTAssertTrue(retryX.events.isEmpty, "X's edge is still in appServerAdmittedEdgeIDs — never re-treated as fresh")
        XCTAssertEqual(hub.fetch(workspaceID: workspaceID, sessionID: sessionID, limit: 100).newestSeq, highWaterBeforeRetry,
                       "a retried already-admitted edge must consume zero seq even after both eviction AND a seenEventIDs rebuild")

        // A genuinely NEW item Y DOES produce +1.
        let newActivityY = hub.admitAppServerWorkingControl(logical: key, ownerKey: o, workspaceID: workspaceID,
                                                             observation: .internalActivityStarted(threadID: root, turnID: turnID, itemID: "item-y", kind: .sleep, time: "t301"))
        XCTAssertTrue(newActivityY.accepted)
        XCTAssertEqual(newActivityY.events.count, 1)
        XCTAssertEqual(hub.fetch(workspaceID: workspaceID, sessionID: sessionID, limit: 100).newestSeq, highWaterBeforeRetry + 1)
    }

    // MARK: - Workspace-wide overlay (multi-session)

    func testWorkspaceWideFetchOverlaysEverySessionsTrimmedSnapshotOncePreservingBounds() {
        let hub = newHub(maxBufferedEvents: 10)
        let sessionA = sessionID
        let sessionB = "session-b"
        hub.beginAppServerControlIncarnation(sessionID: sessionB, epoch: "pid:2|sock:/tmp/b.sock", rootThreadID: "thread-b")

        let keyA = logical()
        let ownerA = owner(keyA)
        let openedA = startHub(hub, logical: keyA, owner: ownerA)
        let snapshotA = try! XCTUnwrap(openedA.first)

        let keyB = AppServerLogicalTurnKey(sessionID: sessionB, epoch: "pid:2|sock:/tmp/b.sock", rootThreadID: "thread-b", turnID: "turn-b")
        let ownerB = AppServerOwnerKey(logical: keyB, runtimeGeneration: "gen-b", ownerToken: "owner-b")
        let openedB = hub.admitAppServerWorkingControl(logical: keyB, ownerKey: ownerB, workspaceID: workspaceID,
                                                        observation: .turnStarted(threadID: "thread-b", turnID: "turn-b", time: "t1"))
        let snapshotB = try! XCTUnwrap(openedB.events.first)

        // Trim BOTH sessions' small buffers past their snapshots.
        for i in 0..<10 {
            hub.publish(makeFillerToolCallEvent(id: "filler-a-\(i)", seq: 100 + i, sessionID: sessionA, timestamp: "t\(300 + i)"))
            hub.publish(makeFillerToolCallEvent(id: "filler-b-\(i)", seq: 100 + i, sessionID: sessionB, timestamp: "t\(400 + i)"))
        }

        let rawFullFetch = hub.fetch(workspaceID: workspaceID, sessionID: sessionA, limit: 100, beforeSeq: Int.max)
        XCTAssertFalse(rawFullFetch.events.contains { $0.eventID == snapshotA.eventID })

        let workspaceFullFetch = hub.fetch(workspaceID: workspaceID, sessionID: nil, limit: 1000)
        XCTAssertEqual(workspaceFullFetch.events.filter { $0.eventID == snapshotA.eventID }.count, 1,
                       "workspace-wide full fetch must overlay session A's trimmed snapshot exactly once")
        XCTAssertEqual(workspaceFullFetch.events.filter { $0.eventID == snapshotB.eventID }.count, 1,
                       "workspace-wide full fetch must ALSO overlay session B's trimmed snapshot exactly once")

        let boundsOnlyFetch = hub.fetch(workspaceID: workspaceID, sessionID: nil, limit: 1000)
        // Recompute the base (non-overlay) bounds independently via a
        // beforeSeq call (which never overlays) to prove the overlay never
        // touched oldestSeq/newestSeq/hasMore.
        let baseline = hub.fetch(workspaceID: workspaceID, sessionID: nil, limit: 1000, beforeSeq: Int.max)
        XCTAssertEqual(boundsOnlyFetch.oldestSeq, baseline.oldestSeq)
        XCTAssertEqual(boundsOnlyFetch.newestSeq, baseline.newestSeq)
        XCTAssertEqual(boundsOnlyFetch.hasMore, baseline.hasMore)

        // Each session's snapshot asserted INDEPENDENTLY (not "A or B") —
        // a cursor strictly below EACH one's own seq must overlay THAT one.
        let workspaceAfterSeqA = hub.fetch(workspaceID: workspaceID, sessionID: nil, limit: 1000, afterSeq: snapshotA.seq - 1)
        XCTAssertEqual(workspaceAfterSeqA.events.filter { $0.eventID == snapshotA.eventID }.count, 1,
                       "snapshot A alone must overlay when the cursor is strictly below A's own seq")
        let workspaceAfterSeqB = hub.fetch(workspaceID: workspaceID, sessionID: nil, limit: 1000, afterSeq: snapshotB.seq - 1)
        XCTAssertEqual(workspaceAfterSeqB.events.filter { $0.eventID == snapshotB.eventID }.count, 1,
                       "snapshot B alone must overlay when the cursor is strictly below B's own seq")

        let workspaceBeforeSeq = hub.fetch(workspaceID: workspaceID, sessionID: nil, limit: 1000, beforeSeq: 1000)
        XCTAssertFalse(workspaceBeforeSeq.events.contains { $0.eventID == snapshotA.eventID || $0.eventID == snapshotB.eventID },
                       "beforeSeq must never overlay, even workspace-wide")

        let (subscriberID, noReplay) = hub.subscribe(workspaceID: workspaceID, sessionID: nil, sinceSeq: Int.max) { _ in }
        defer { hub.unsubscribe(subscriberID) }
        XCTAssertFalse(noReplay.contains { $0.event.eventID == snapshotA.eventID || $0.event.eventID == snapshotB.eventID })
    }

    // A session migrated to a new workspace: the OLD workspace's fetch
    // (session-scoped or workspace-wide) must return zero occurrences of
    // the snapshot; the NEW workspace's fetch must return exactly one, in
    // both session-scoped and workspace-wide form.
    func testMigrateSessionBindingMovesSnapshotOverlayToNewWorkspaceExactlyOnce() {
        // Snapshot-ONLY: a tiny buffer + churn physically evicts the raw
        // stored event from `bufferedEvents` BEFORE migrating, proven via a
        // `beforeSeq` (no-overlay) baseline. This matters because
        // `migrateSession` ALSO bulk-rewrites `bufferedEvents`/
        // `historicalEvents` directly — if the snapshot were still
        // physically buffered, that bulk rewrite alone would carry the new
        // workspace binding and the test would pass even if the overlay's
        // OWN `effectiveEvent(rawSnapshot)` call were broken. With the raw
        // copy evicted, the overlay path is the ONLY way the migrated
        // binding can appear.
        let hub = newHub(maxBufferedEvents: 5)
        let key = logical()
        let o = owner(key)
        let opened = startHub(hub, logical: key, owner: o)
        let snapshotEvent = try! XCTUnwrap(opened.first)

        for i in 0..<10 {
            hub.publish(makeFillerToolCallEvent(id: "migrate-churn-\(i)", seq: 200 + i, timestamp: "t\(200 + i)"))
        }
        let noOverlayBaseline = hub.fetch(workspaceID: workspaceID, sessionID: sessionID, limit: 100, beforeSeq: Int.max)
        XCTAssertFalse(noOverlayBaseline.events.contains { $0.eventID == snapshotEvent.eventID },
                       "the raw snapshot event must be physically evicted before migration")

        let oldWorkspaceSessionScoped = hub.fetch(workspaceID: workspaceID, sessionID: sessionID, limit: 100)
        XCTAssertEqual(oldWorkspaceSessionScoped.events.filter { $0.eventID == snapshotEvent.eventID }.count, 1,
                       "still visible pre-migration ONLY via overlay")

        let newWorkspaceID = "workspace-new"
        hub.migrateSession(sessionID: sessionID, toWorkspaceID: newWorkspaceID, panelID: nil)

        let oldWorkspaceAfterMigrate = hub.fetch(workspaceID: workspaceID, sessionID: sessionID, limit: 100)
        XCTAssertEqual(oldWorkspaceAfterMigrate.events.filter { $0.eventID == snapshotEvent.eventID }.count, 0,
                       "the OLD workspace must see zero occurrences after migration")
        let oldWorkspaceWideAfterMigrate = hub.fetch(workspaceID: workspaceID, sessionID: nil, limit: 100)
        XCTAssertEqual(oldWorkspaceWideAfterMigrate.events.filter { $0.eventID == snapshotEvent.eventID }.count, 0)
        let oldWorkspaceSessionReplay = hub.subscribe(workspaceID: workspaceID, sessionID: sessionID, sinceSeq: nil) { _ in }.1
        XCTAssertEqual(oldWorkspaceSessionReplay.filter { $0.event.eventID == snapshotEvent.eventID }.count, 0,
                       "the OLD workspace's session-scoped replay must also see zero")
        let oldWorkspaceWideReplay = hub.subscribe(workspaceID: workspaceID, sessionID: nil, sinceSeq: nil) { _ in }.1
        XCTAssertEqual(oldWorkspaceWideReplay.filter { $0.event.eventID == snapshotEvent.eventID }.count, 0,
                       "the OLD workspace's workspace-wide replay must also see zero")

        let newWorkspaceSessionScoped = hub.fetch(workspaceID: newWorkspaceID, sessionID: sessionID, limit: 100)
        XCTAssertEqual(newWorkspaceSessionScoped.events.filter { $0.eventID == snapshotEvent.eventID }.count, 1,
                       "the NEW workspace's session-scoped fetch must see it exactly once")
        let newWorkspaceWide = hub.fetch(workspaceID: newWorkspaceID, sessionID: nil, limit: 100)
        XCTAssertEqual(newWorkspaceWide.events.filter { $0.eventID == snapshotEvent.eventID }.count, 1,
                       "the NEW workspace's workspace-wide fetch must ALSO see it exactly once, same ID/seq")
        // Bounds still come from the BASE page, unaffected by overlay.
        let newWorkspaceBaseline = hub.fetch(workspaceID: newWorkspaceID, sessionID: sessionID, limit: 100, beforeSeq: Int.max)
        XCTAssertEqual(newWorkspaceSessionScoped.oldestSeq, newWorkspaceBaseline.oldestSeq)
        XCTAssertEqual(newWorkspaceSessionScoped.newestSeq, newWorkspaceBaseline.newestSeq)
        XCTAssertEqual(newWorkspaceSessionScoped.events.first { $0.eventID == snapshotEvent.eventID }?.seq,
                       newWorkspaceWide.events.first { $0.eventID == snapshotEvent.eventID }?.seq)

        // Same proof for `subscribe`'s sinceSeq:nil replay, both modes —
        // this is what actually exercises the overlay's `effectiveEvent`
        // rebind inside `replayEvents`, not just `fetch`.
        let newWorkspaceSessionReplay = hub.subscribe(workspaceID: newWorkspaceID, sessionID: sessionID, sinceSeq: nil) { _ in }.1
        let newWorkspaceWideReplay = hub.subscribe(workspaceID: newWorkspaceID, sessionID: nil, sinceSeq: nil) { _ in }.1
        let sessionReplayMatches = newWorkspaceSessionReplay.filter { $0.event.eventID == snapshotEvent.eventID }
        let wideReplayMatches = newWorkspaceWideReplay.filter { $0.event.eventID == snapshotEvent.eventID }
        XCTAssertEqual(sessionReplayMatches.count, 1, "the NEW workspace's session-scoped replay must see it exactly once")
        XCTAssertEqual(wideReplayMatches.count, 1, "the NEW workspace's workspace-wide replay must ALSO see it exactly once")
        XCTAssertEqual(sessionReplayMatches.first?.event.seq, wideReplayMatches.first?.event.seq, "same ID/seq across both replay modes")
        XCTAssertEqual(sessionReplayMatches.first?.event.workspaceID, newWorkspaceID)
    }

    func testWorkspaceWideOverlayOrderingMatchesTimestampSeqComparatorAcrossSessions() {
        let hub = newHub(maxBufferedEvents: 10)
        let sessionA = sessionID
        let sessionB = "session-b"
        hub.beginAppServerControlIncarnation(sessionID: sessionB, epoch: "pid:2|sock:/tmp/b.sock", rootThreadID: "thread-b")

        let keyA = logical()
        let ownerA = owner(keyA)
        // NOTE: publish()'s workspace-wide sort compares raw opaque
        // timestamp STRINGS lexicographically (not calendar time) — "t500"
        // sorts after "t300"/"t400"... digit-by-digit, so pick fixture
        // literals that are unambiguous under plain string comparison, not
        // ones that merely "look" chronological.
        let openedA = startHub(hub, logical: keyA, owner: ownerA, time: "t500")
        let snapshotA = try! XCTUnwrap(openedA.first)

        let keyB = AppServerLogicalTurnKey(sessionID: sessionB, epoch: "pid:2|sock:/tmp/b.sock", rootThreadID: "thread-b", turnID: "turn-b")
        let ownerB = AppServerOwnerKey(logical: keyB, runtimeGeneration: "gen-b", ownerToken: "owner-b")
        let openedB = hub.admitAppServerWorkingControl(logical: keyB, ownerKey: ownerB, workspaceID: workspaceID,
                                                        observation: .turnStarted(threadID: "thread-b", turnID: "turn-b", time: "t500"))
        let snapshotB = try! XCTUnwrap(openedB.events.first)

        for i in 0..<10 {
            hub.publish(makeFillerToolCallEvent(id: "filler-a-\(i)", seq: 100 + i, sessionID: sessionA, timestamp: "t3\(String(format: "%02d", i))"))
            hub.publish(makeFillerToolCallEvent(id: "filler-b-\(i)", seq: 100 + i, sessionID: sessionB, timestamp: "t4\(String(format: "%02d", i))"))
        }
        // Both snapshots' own admit timestamp ("t500") sorts strictly AFTER
        // every filler's ("t3xx"/"t4xx") under plain string comparison —
        // both must land after every filler event in the final
        // workspace-wide (timestamp, seq) order.
        let result = hub.fetch(workspaceID: workspaceID, sessionID: nil, limit: 1000)
        let orderedIDs = result.events.map(\.eventID)
        let lastFillerIndex = orderedIDs.lastIndex { $0.hasPrefix("filler-") }
        let snapshotAIndex = orderedIDs.firstIndex(of: snapshotA.eventID)
        let snapshotBIndex = orderedIDs.firstIndex(of: snapshotB.eventID)
        XCTAssertNotNil(lastFillerIndex)
        XCTAssertNotNil(snapshotAIndex)
        XCTAssertNotNil(snapshotBIndex)
        if let lastFillerIndex, let snapshotAIndex, let snapshotBIndex {
            XCTAssertGreaterThan(snapshotAIndex, lastFillerIndex,
                                 "snapshot A's own timestamp is older, but it must still be positioned per the (timestamp, seq) comparator, not seq alone")
            XCTAssertGreaterThan(snapshotBIndex, lastFillerIndex)
        }
        // Determinism: repeating the exact same fetch must yield the exact
        // same order (no Dictionary/Set iteration leak).
        let result2 = hub.fetch(workspaceID: workspaceID, sessionID: nil, limit: 1000)
        XCTAssertEqual(result2.events.map(\.eventID), orderedIDs)
    }

    // Multi-session workspace-wide REPLAY (not just fetch) — both
    // sessions' trimmed active snapshots must each appear exactly once
    // with the correct effective workspace binding.
    func testWorkspaceWideFullReplayOverlaysBothSessionsTrimmedSnapshotsExactlyOnce() {
        let hub = newHub(maxBufferedEvents: 10)
        let sessionA = sessionID
        let sessionB = "session-b"
        hub.beginAppServerControlIncarnation(sessionID: sessionB, epoch: "pid:2|sock:/tmp/b.sock", rootThreadID: "thread-b")

        let keyA = logical()
        let ownerA = owner(keyA)
        let openedA = startHub(hub, logical: keyA, owner: ownerA)
        let snapshotA = try! XCTUnwrap(openedA.first)

        let keyB = AppServerLogicalTurnKey(sessionID: sessionB, epoch: "pid:2|sock:/tmp/b.sock", rootThreadID: "thread-b", turnID: "turn-b")
        let ownerB = AppServerOwnerKey(logical: keyB, runtimeGeneration: "gen-b", ownerToken: "owner-b")
        let openedB = hub.admitAppServerWorkingControl(logical: keyB, ownerKey: ownerB, workspaceID: workspaceID,
                                                        observation: .turnStarted(threadID: "thread-b", turnID: "turn-b", time: "t1"))
        let snapshotB = try! XCTUnwrap(openedB.events.first)

        for i in 0..<10 {
            hub.publish(makeFillerToolCallEvent(id: "replay-filler-a-\(i)", seq: 100 + i, sessionID: sessionA, timestamp: "t\(300 + i)"))
            hub.publish(makeFillerToolCallEvent(id: "replay-filler-b-\(i)", seq: 100 + i, sessionID: sessionB, timestamp: "t\(400 + i)"))
        }

        let (subscriberID, replay) = hub.subscribe(workspaceID: workspaceID, sessionID: nil, sinceSeq: nil) { _ in }
        defer { hub.unsubscribe(subscriberID) }
        let matchesA = replay.filter { $0.event.eventID == snapshotA.eventID }
        let matchesB = replay.filter { $0.event.eventID == snapshotB.eventID }
        XCTAssertEqual(matchesA.count, 1, "session A's trimmed snapshot must appear exactly once in a multi-session workspace-wide replay")
        XCTAssertEqual(matchesB.count, 1, "session B's trimmed snapshot must appear exactly once in a multi-session workspace-wide replay")
        XCTAssertEqual(matchesA.first?.event.workspaceID, workspaceID)
        XCTAssertEqual(matchesB.first?.event.workspaceID, workspaceID)
    }

    // MARK: - Locked Section 5 wire contract: control events can never
    // become a tool card

    // Explicit, field-by-field contract for one of each stored typed
    // control wire kind (open/continue/terminal) — proves the "no card can
    // ever be created" invariant directly from the wire shape, not merely
    // inferred from `events.isEmpty` at the admission layer. The Bridge
    // package has no card/formatter mapper of its own (that logic lives in
    // the iOS client's typed reducer, covered by its own test target) — so
    // this is the strongest contract available on the Bridge side: every
    // single card-bearing field is nil, on every kind, with no exception.
    func testStoredControlWireEventsAreFieldByFieldZeroCardAcrossOpenContinueAndTerminal() {
        let hub = newHub()
        let key = logical()
        let o = owner(key)

        func assertZeroCardShape(_ event: AgentEvent, expectedType: AgentEventKind, file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertEqual(event.type, expectedType, file: file, line: line)
            XCTAssertNil(event.text, "text must be nil — no chat bubble content", file: file, line: line)
            XCTAssertNil(event.name, "name must be nil — no tool name to render", file: file, line: line)
            XCTAssertNil(event.input, "input must be nil — no tool-call input to render", file: file, line: line)
            XCTAssertNil(event.output, "output must be nil — no tool-result output to render", file: file, line: line)
            XCTAssertNil(event.toolCallID, "toolCallID must be nil — no card identity to key off of", file: file, line: line)
            XCTAssertNil(event.payload, "payload must be nil — no structured card body at all", file: file, line: line)
            XCTAssertEqual(event.metadata?["source"], "codex_app_server_working_control", file: file, line: line)
            XCTAssertEqual(event.metadata?["tidey_control"], "working", file: file, line: line)
            XCTAssertEqual(event.metadata?["thread_id"], root, file: file, line: line)
            XCTAssertEqual(event.metadata?["root_thread_id"], root, file: file, line: line)
            XCTAssertEqual(event.metadata?["turn_id"], turnID, file: file, line: line)
            XCTAssertEqual(event.metadata?["app_server_epoch"], epoch, file: file, line: line)
        }

        // OPEN (turn start).
        let opened = startHub(hub, logical: key, owner: o)
        let openEvent = try! XCTUnwrap(opened.first)
        assertZeroCardShape(openEvent, expectedType: .thinking)
        XCTAssertEqual(openEvent.metadata?["working_phase"], "open")
        XCTAssertEqual(openEvent.metadata?["reason"], "turn_started")
        XCTAssertEqual(openEvent.metadata?["runtime_generation"], o.runtimeGeneration)
        XCTAssertEqual(openEvent.metadata?["owner_token"], o.ownerToken)
        XCTAssertNil(openEvent.metadata?["activity_id"], "open has no activity — must not carry one")
        XCTAssertNil(openEvent.metadata?["terminal_scope"], "open is not a terminal — must not carry a terminal_scope")

        // CONTINUE (an allowlisted internal activity).
        let activity = hub.admitAppServerWorkingControl(logical: key, ownerKey: o, workspaceID: workspaceID,
                                                         observation: .internalActivityStarted(threadID: root, turnID: turnID, itemID: "item-1", kind: .sleep, time: "t2"))
        let continueEvent = try! XCTUnwrap(activity.events.first)
        assertZeroCardShape(continueEvent, expectedType: .thinking)
        XCTAssertEqual(continueEvent.metadata?["working_phase"], "continue")
        XCTAssertEqual(continueEvent.metadata?["reason"], "internal_activity")
        XCTAssertEqual(continueEvent.metadata?["activity_id"], "item-1")
        XCTAssertEqual(continueEvent.metadata?["kind"], CodexAppServerInternalActivityKind.sleep.rawValue)
        XCTAssertEqual(continueEvent.metadata?["runtime_generation"], o.runtimeGeneration)
        XCTAssertEqual(continueEvent.metadata?["owner_token"], o.ownerToken)
        XCTAssertNil(continueEvent.metadata?["terminal_scope"])

        // TERMINAL (semantic).
        let terminal = hub.admitAppServerWorkingControl(logical: key, ownerKey: o, workspaceID: workspaceID,
                                                         observation: .turnTerminal(threadID: root, turnID: turnID, rawStatus: "failed", time: "t3"))
        let terminalEvent = try! XCTUnwrap(terminal.events.first)
        assertZeroCardShape(terminalEvent, expectedType: .assistantFinal)
        XCTAssertEqual(terminalEvent.metadata?["working_phase"], "terminal")
        XCTAssertEqual(terminalEvent.metadata?["reason"], "turn_failed")
        XCTAssertEqual(terminalEvent.metadata?["terminal_scope"], "semantic_turn")
        XCTAssertNil(terminalEvent.metadata?["activity_id"], "a semantic terminal carries no activity_id")
    }

    // MARK: - Overlay survives limit/maxBytes truncation, not just the raw buffer

    func testOverlayAddsSnapshotOnTopOfATrulyLimitedPage() {
        let hub = newHub(maxBufferedEvents: 20)
        let key = logical()
        let o = owner(key)
        let opened = startHub(hub, logical: key, owner: o)
        let snapshotEvent = try! XCTUnwrap(opened.first)

        for i in 0..<10 {
            hub.publish(makeFillerToolCallEvent(id: "limit-filler-\(i)", seq: 100 + i, timestamp: "t\(100 + i)"))
        }
        let baseline = hub.fetch(workspaceID: workspaceID, sessionID: sessionID, limit: 1, beforeSeq: Int.max)
        XCTAssertEqual(baseline.events.count, 1)
        XCTAssertEqual(baseline.events.first?.eventID, "limit-filler-9", "base page (limit=1) is the single latest event")

        let limited = hub.fetch(workspaceID: workspaceID, sessionID: sessionID, limit: 1)
        XCTAssertEqual(limited.events.count, 2, "base latest 1 + the overlaid snapshot")
        XCTAssertTrue(limited.events.contains { $0.eventID == "limit-filler-9" })
        XCTAssertTrue(limited.events.contains { $0.eventID == snapshotEvent.eventID })
        XCTAssertEqual(limited.oldestSeq, baseline.oldestSeq, "bounds are the BASE page's, unaffected by the extra overlaid event")
        XCTAssertEqual(limited.newestSeq, baseline.newestSeq)
        XCTAssertTrue(limited.hasMore, "10 fillers exist but the base page only kept 1 — hasMore must still reflect that")

        let maxBytesBaseline = hub.fetch(workspaceID: workspaceID, sessionID: sessionID, limit: 100, maxBytes: 16, beforeSeq: Int.max)
        let maxBytesLimited = hub.fetch(workspaceID: workspaceID, sessionID: sessionID, limit: 100, maxBytes: 16)
        XCTAssertTrue(maxBytesLimited.events.contains { $0.eventID == snapshotEvent.eventID },
                      "a byte-budget-truncated page must ALSO still get the snapshot overlaid on top")
        XCTAssertEqual(maxBytesLimited.oldestSeq, maxBytesBaseline.oldestSeq)
        XCTAssertEqual(maxBytesLimited.newestSeq, maxBytesBaseline.newestSeq)
        XCTAssertEqual(maxBytesLimited.hasMore, maxBytesBaseline.hasMore)
    }

    // MARK: - Total comparator mutation matrix

    // A cycle under the OLD (per-pair) comparator: same-session pairs
    // compared by seq, cross-session pairs by timestamp — with A's seq
    // deliberately non-monotonic against its own timestamp. The single
    // GLOBAL (timestamp, seq, sessionID, eventID) comparator must still
    // produce one deterministic, reproducible order; session-scoped A
    // alone must still be pure-seq order.
    // Deterministic killer for the old per-pair "same session -> seq, else
    // -> timestamp" comparator: with ONLY ever a SINGLE session in the
    // whole hub, every pair the old comparator ever compares IS a
    // same-session pair, so it would ALWAYS fall back to pure seq order
    // even for a workspace-wide (sessionID: nil) request — silently
    // identical to the session-scoped result. This is not "undefined sort
    // might happen to match"; it is a guaranteed wrong answer under the old
    // rule, every single run. The correct, single global comparator MUST
    // still use timestamp for the workspace-wide case even with one
    // session, and seq for the session-scoped case.
    func testSingleSessionWorkspaceWideStillUsesTimestampOrderNotSeqOrder() {
        let hub = newHub()
        // A1 has the LATER timestamp but the SMALLER seq; A2 the reverse.
        hub.publish(AgentEvent(eventID: "A1", seq: 1, vendor: "codex", workspaceID: workspaceID, sessionID: sessionID,
                               timestamp: "t0300", type: .toolCall, role: "assistant", text: nil, name: "f", input: "{}",
                               output: nil, toolCallID: "A1", metadata: nil))
        hub.publish(AgentEvent(eventID: "A2", seq: 2, vendor: "codex", workspaceID: workspaceID, sessionID: sessionID,
                               timestamp: "t0100", type: .toolCall, role: "assistant", text: nil, name: "f", input: "{}",
                               output: nil, toolCallID: "A2", metadata: nil))

        let workspaceReplay = hub.subscribe(workspaceID: workspaceID, sessionID: nil, sinceSeq: nil) { _ in }.1
        XCTAssertEqual(workspaceReplay.map(\.event.eventID), ["A2", "A1"],
                       "workspace-wide (sessionID: nil) must order by TIMESTAMP even with only one session present")

        let sessionScopedFetch = hub.fetch(workspaceID: workspaceID, sessionID: sessionID, limit: 100).events.map(\.eventID)
        XCTAssertEqual(sessionScopedFetch, ["A1", "A2"], "session-scoped must order by SEQ")
        let sessionScopedReplay = hub.subscribe(workspaceID: workspaceID, sessionID: sessionID, sinceSeq: nil) { _ in }.1
        XCTAssertEqual(sessionScopedReplay.map(\.event.eventID), ["A1", "A2"])
    }

    func testWorkspaceComparatorHandlesNonMonotonicCycleFixtureDeterministically() {
        let hub = newHub()
        let sessionA = sessionID
        let sessionB = "session-b"
        hub.beginAppServerControlIncarnation(sessionID: sessionB, epoch: "pid:2|sock:/tmp/b.sock", rootThreadID: "thread-b")

        // Session A: seq1 has the LATER timestamp, seq2 has the EARLIER one
        // (seq is not monotonic with timestamp within A).
        hub.publish(AgentEvent(eventID: "A1", seq: 1, vendor: "codex", workspaceID: workspaceID, sessionID: sessionA,
                               timestamp: "t3", type: .toolCall, role: "assistant", text: nil, name: "f", input: "{}",
                               output: nil, toolCallID: "A1", metadata: nil))
        hub.publish(AgentEvent(eventID: "A2", seq: 2, vendor: "codex", workspaceID: workspaceID, sessionID: sessionA,
                               timestamp: "t1", type: .toolCall, role: "assistant", text: nil, name: "f", input: "{}",
                               output: nil, toolCallID: "A2", metadata: nil))
        // Session B: one event whose timestamp sits between A1 and A2's.
        hub.publish(AgentEvent(eventID: "B1", seq: 1, vendor: "codex", workspaceID: workspaceID, sessionID: sessionB,
                               timestamp: "t2", type: .toolCall, role: "assistant", text: nil, name: "f", input: "{}",
                               output: nil, toolCallID: "B1", metadata: nil))

        // Workspace-wide: pure (timestamp, seq, sessionID, eventID) order —
        // A2(t1) < B1(t2) < A1(t3).
        let workspaceOrder = hub.fetch(workspaceID: workspaceID, sessionID: nil, limit: 100).events.map(\.eventID)
        XCTAssertEqual(workspaceOrder, ["A2", "B1", "A1"])
        // Repeat to confirm determinism.
        XCTAssertEqual(hub.fetch(workspaceID: workspaceID, sessionID: nil, limit: 100).events.map(\.eventID), workspaceOrder)
        let workspaceReplay = hub.subscribe(workspaceID: workspaceID, sessionID: nil, sinceSeq: nil) { _ in }.1
        XCTAssertEqual(workspaceReplay.map(\.event.eventID), ["A2", "B1", "A1"])

        // Session-scoped A: pure seq order — A1(seq1) < A2(seq2).
        let sessionAOrder = hub.fetch(workspaceID: workspaceID, sessionID: sessionA, limit: 100).events.map(\.eventID)
        XCTAssertEqual(sessionAOrder, ["A1", "A2"])
    }

    // Exact (timestamp, seq) ties across TWO sessions, both for base events
    // AND overlay snapshots — the full expected order must follow
    // timestamp -> seq -> sessionID -> eventID, deterministically, on
    // repeat.
    func testWorkspaceComparatorExactTiesAcrossSessionsIncludingOverlaySnapshots() {
        // Per session: snapshot(1) + tieBase(1) + 10 fillers = 12 appended.
        // Capacity 11 evicts ONLY the oldest (the snapshot, recoverable via
        // overlay) and keeps tieBase + all 10 fillers physically resident —
        // capacity 10 would ALSO evict tieBase (an ordinary event with NO
        // overlay recovery), silently emptying the tie-order assertions
        // below into a vacuous `[] == [].sorted()` pass.
        let hub = newHub(maxBufferedEvents: 11)
        let sessionA = sessionID
        let sessionB = "session-b"
        hub.beginAppServerControlIncarnation(sessionID: sessionB, epoch: "pid:2|sock:/tmp/b.sock", rootThreadID: "thread-b")

        // All timestamps below are "t" + a fixed-width zero-padded 4-digit
        // number, so plain string comparison always agrees with numeric
        // order — mixing digit-run lengths (or digits vs letters, e.g. "7"
        // vs "i") under lexicographic comparison is a classic trap ("t700"
        // < "tie...", NOT the other way, since '7' < 'i').
        let keyA = logical()
        let ownerA = owner(keyA)
        let openedA = startHub(hub, logical: keyA, owner: ownerA, time: "t0100")
        let snapshotA = try! XCTUnwrap(openedA.first)

        let keyB = AppServerLogicalTurnKey(sessionID: sessionB, epoch: "pid:2|sock:/tmp/b.sock", rootThreadID: "thread-b", turnID: "turn-b")
        let ownerB = AppServerOwnerKey(logical: keyB, runtimeGeneration: "gen-b", ownerToken: "owner-b")
        let openedB = hub.admitAppServerWorkingControl(logical: keyB, ownerKey: ownerB, workspaceID: workspaceID,
                                                        observation: .turnStarted(threadID: "thread-b", turnID: "turn-b", time: "t0100"))
        let snapshotB = try! XCTUnwrap(openedB.events.first)

        // Base events with the EXACT same timestamp+seq across sessions —
        // only sessionID/eventID can break the tie.
        hub.publish(AgentEvent(eventID: "tieA", seq: 500, vendor: "codex", workspaceID: workspaceID, sessionID: sessionA,
                               timestamp: "t0200", type: .toolCall, role: "assistant", text: nil, name: "f", input: "{}",
                               output: nil, toolCallID: "tieA", metadata: nil))
        hub.publish(AgentEvent(eventID: "tieB", seq: 500, vendor: "codex", workspaceID: workspaceID, sessionID: sessionB,
                               timestamp: "t0200", type: .toolCall, role: "assistant", text: nil, name: "f", input: "{}",
                               output: nil, toolCallID: "tieB", metadata: nil))

        for i in 0..<10 {
            hub.publish(makeFillerToolCallEvent(id: "tie-filler-a-\(i)", seq: 600 + i, sessionID: sessionA, timestamp: "t03\(String(format: "%02d", i))"))
            hub.publish(makeFillerToolCallEvent(id: "tie-filler-b-\(i)", seq: 600 + i, sessionID: sessionB, timestamp: "t04\(String(format: "%02d", i))"))
        }

        // Expected: "t0100" (snapshots' shared timestamp) < "t0200" (base
        // events' shared timestamp) < "t03xx"/"t04xx" fillers. Within each
        // timestamp tie, sessionID then eventID breaks it.
        let expectedSnapshotOrder: [String]
        if sessionA < sessionB {
            expectedSnapshotOrder = [snapshotA.eventID, snapshotB.eventID]
        } else {
            expectedSnapshotOrder = [snapshotB.eventID, snapshotA.eventID]
        }
        let expectedBaseTieOrder = sessionA < sessionB ? ["tieA", "tieB"] : ["tieB", "tieA"]

        let result = hub.fetch(workspaceID: workspaceID, sessionID: nil, limit: 1000)
        let ids = result.events.map(\.eventID)
        // Non-vacuous existence checks FIRST — a `compactMap` + `.sorted()`
        // comparison alone would trivially pass on an empty array if either
        // tied event were silently missing (e.g. evicted), catching
        // nothing.
        XCTAssertEqual(ids.filter { $0 == "tieA" }.count, 1)
        XCTAssertEqual(ids.filter { $0 == "tieB" }.count, 1)
        XCTAssertEqual(ids.filter { $0 == snapshotA.eventID }.count, 1)
        XCTAssertEqual(ids.filter { $0 == snapshotB.eventID }.count, 1)

        XCTAssertEqual(Array(ids.prefix(2)), expectedSnapshotOrder, "the two tied snapshots come first, ordered by sessionID")
        let baseTieIndices = expectedBaseTieOrder.compactMap { ids.firstIndex(of: $0) }
        XCTAssertEqual(baseTieIndices.count, 2, "both tied base events must actually be present")
        XCTAssertEqual(baseTieIndices, baseTieIndices.sorted(), "the two tied base events preserve sessionID order")
        // Full expected prefix: snapshot order, then base-tie order.
        XCTAssertEqual(Array(ids.prefix(4)), expectedSnapshotOrder + expectedBaseTieOrder)

        // Determinism on repeat, fetch and replay alike.
        XCTAssertEqual(hub.fetch(workspaceID: workspaceID, sessionID: nil, limit: 1000).events.map(\.eventID), ids)
        let replayIDs = hub.subscribe(workspaceID: workspaceID, sessionID: nil, sinceSeq: nil) { _ in }.1.map { $0.event.eventID }
        XCTAssertEqual(replayIDs, ids)
    }

    // MARK: - Historical control purge (not just the live buffer)

    // Mutation killer: a purge that only clears `bufferedEvents` (and
    // forgets `historicalEvents`) would let an OLD incarnation's
    // historically-backfilled control wire resurface after A -> B -> A —
    // this test fails specifically if that half of the purge is removed.
    func testTrueRotationPurgesHistoricalControlArtifactsNotJustTheLiveBuffer() {
        let hub = newHub()
        let key = logical(turnID: "turn-hist")
        let o = owner(key)
        // Establish a live high-water well above the historical seqs below.
        _ = hub.admitAppServerWorkingControl(logical: key, ownerKey: o, workspaceID: workspaceID,
                                             observation: .turnStarted(threadID: root, turnID: "turn-hist", time: "t1"))
        hub.publish(makeFillerToolCallEvent(id: "live-anchor", seq: 500))
        let highWaterBeforeBackfill = hub.fetch(workspaceID: workspaceID, sessionID: sessionID, limit: 100).newestSeq

        let oldHistoricalControl = AgentEvent(eventID: "hist-control-old", seq: 10, vendor: "codex", workspaceID: workspaceID,
                                              sessionID: sessionID, timestamp: "t0", type: .thinking, role: nil, text: nil,
                                              name: nil, input: nil, output: nil, toolCallID: nil,
                                              metadata: ["source": "codex_app_server_working_control",
                                                        "app_server_epoch": epoch, "root_thread_id": root,
                                                        "tidey_control": "working", "working_phase": "open"])
        let ordinaryHistorical = AgentEvent(eventID: "hist-ordinary", seq: 11, vendor: "codex", workspaceID: workspaceID,
                                            sessionID: sessionID, timestamp: "t0", type: .assistantMessage, role: "assistant",
                                            text: "historical text", name: nil, input: nil, output: nil, toolCallID: nil, metadata: nil)
        hub.replaceHistoricalEvents(sessionID: sessionID, events: [oldHistoricalControl, ordinaryHistorical])

        let beforeRotation = hub.fetch(workspaceID: workspaceID, sessionID: sessionID, limit: 1000, beforeSeq: Int.max)
        XCTAssertTrue(beforeRotation.events.contains { $0.eventID == "hist-control-old" })
        XCTAssertTrue(beforeRotation.events.contains { $0.eventID == "hist-ordinary" })

        // A -> B -> A.
        hub.beginAppServerControlIncarnation(sessionID: sessionID, epoch: "pid:2|sock:/tmp/b.sock", rootThreadID: "thread-b")
        hub.beginAppServerControlIncarnation(sessionID: sessionID, epoch: epoch, rootThreadID: root)

        let afterRotation = hub.fetch(workspaceID: workspaceID, sessionID: sessionID, limit: 1000, beforeSeq: Int.max)
        XCTAssertFalse(afterRotation.events.contains { $0.eventID == "hist-control-old" },
                       "the OLD incarnation's HISTORICAL control artifact must never resurface via fetch — purging only bufferedEvents is not enough")
        XCTAssertTrue(afterRotation.events.contains { $0.eventID == "hist-ordinary" },
                      "ordinary historical events are untouched by the purge (fetch)")

        let afterRotationReplay = hub.subscribe(workspaceID: workspaceID, sessionID: sessionID, sinceSeq: nil) { _ in }.1
        XCTAssertFalse(afterRotationReplay.contains { $0.event.eventID == "hist-control-old" },
                       "the OLD incarnation's HISTORICAL control artifact must never resurface via sinceSeq:nil replay either")
        XCTAssertTrue(afterRotationReplay.contains { $0.event.eventID == "hist-ordinary" },
                      "ordinary historical events are untouched by the purge (replay)")

        XCTAssertGreaterThanOrEqual(hub.fetch(workspaceID: workspaceID, sessionID: sessionID, limit: 1000).newestSeq, highWaterBeforeBackfill,
                                    "high-water must never regress")
    }

    // MARK: - Persistent dedupe for the START edge specifically (not just activity)

    func testOrdinaryChurnTriggeringSeenIDRebuildStillDedupesTheStartEdgeItself() {
        let hub = AgentEventHub(maxBufferedEvents: 5, maxSeenEventIDs: 5)
        hub.beginAppServerControlIncarnation(sessionID: sessionID, epoch: epoch, rootThreadID: root)
        let key = logical()
        let o = owner(key)
        let opened = startHub(hub, logical: key, owner: o)
        XCTAssertEqual(opened.count, 1)

        for i in 0..<20 {
            hub.publish(makeFillerToolCallEvent(id: "start-churn-\(i)", seq: 200 + i, timestamp: "t\(200 + i)"))
        }
        let baseline = hub.fetch(workspaceID: workspaceID, sessionID: sessionID, limit: 100, beforeSeq: Int.max)
        XCTAssertFalse(baseline.events.contains { $0.eventID == opened.first?.eventID },
                       "the start edge's own event must be physically evicted")

        let highWaterBeforeRetry = hub.fetch(workspaceID: workspaceID, sessionID: sessionID, limit: 100).newestSeq
        let retryStart = hub.admitAppServerWorkingControl(logical: key, ownerKey: o, workspaceID: workspaceID,
                                                           observation: .turnStarted(threadID: root, turnID: turnID, time: "t300"))
        XCTAssertTrue(retryStart.accepted, "the START edge must still be recognized as already-admitted")
        XCTAssertEqual(retryStart.ownerContextEffect, .setOwner(o))
        XCTAssertTrue(retryStart.events.isEmpty)
        XCTAssertEqual(hub.fetch(workspaceID: workspaceID, sessionID: sessionID, limit: 100).newestSeq, highWaterBeforeRetry,
                       "a retried already-admitted START edge must consume zero seq even after eviction + seenEventIDs rebuild")

        let activityX = hub.admitAppServerWorkingControl(logical: key, ownerKey: o, workspaceID: workspaceID,
                                                          observation: .internalActivityStarted(threadID: root, turnID: turnID, itemID: "item-x", kind: .sleep, time: "t301"))
        XCTAssertEqual(activityX.events.count, 1, "a genuinely new activity after the retried start still produces +1")
        XCTAssertEqual(activityX.events[0].seq, highWaterBeforeRetry + 1, "exact next seq, not just 'some higher value'")
        let newY = hub.admitAppServerWorkingControl(logical: key, ownerKey: o, workspaceID: workspaceID,
                                                     observation: .internalActivityStarted(threadID: root, turnID: turnID, itemID: "item-y", kind: .sleep, time: "t302"))
        XCTAssertEqual(newY.events.count, 1, "and another genuinely new item Y still produces +1")
        XCTAssertEqual(newY.events[0].seq, activityX.events[0].seq + 1)
    }
}
