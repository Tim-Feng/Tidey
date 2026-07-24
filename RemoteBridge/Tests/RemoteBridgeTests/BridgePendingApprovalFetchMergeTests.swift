import XCTest
@testable import RemoteBridge

// Server-level regression coverage for pending approval snapshots injected
// into fetch/replay: snapshots must reuse the retained published event
// identity and must never advance cursor/bounds past positions the hub has
// actually published.
private final class FakeMergeRuntimeSession: CodexAppServerRuntimeSessionControlling {
    func setRegistryRootThreadID(_ rawThreadID: String?) {}

    func canSubmitMessage() -> Bool { true }
    func ensureThreadSubscription() {}
    func isStopped() -> Bool { false }
    func pendingApprovalPromptEvents() -> [AgentEvent] { [] }
    func refreshActiveThread() {}
    func submitApproval(promptID: String,
                        targetIndex: Int,
                        clientRequestID: String?,
                        lifecycleToken: String?) throws -> CodexAppServerApprovalSubmitOutcome {
        throw BridgeInternalError.notFound("Unknown Codex approval prompt.")
    }
    func submitMessage(text: String, clientRequestID: String?) throws {}
    func stop() {}
}

final class BridgePendingApprovalFetchMergeTests: XCTestCase {
    private static let commandApprovalLine = """
    {"id":"approval-1","method":"item/commandExecution/requestApproval","params":{"threadId":"thread-1","turnId":"turn-1","itemId":"item-1","startedAtMs":1786000000000,"reason":"Needs network.","command":"python3 -c 'print(1)'","cwd":"/Users/timfeng/GitHub/Tidey"}}
    """

    private func makeConnection(hub: AgentEventHub,
                                epoch: String = "pid:100|sock:/tmp/a.sock") -> CodexAppServerConnection {
        CodexAppServerConnection(
            sendLine: { _ in },
            approvalContext: CodexAppServerApprovalContext(workspaceID: "workspace-1",
                                                           panelID: "panel-1",
                                                           sessionID: "session-1",
                                                           epoch: epoch),
            nextSequence: { sessionID in hub.nextSyntheticSeq(sessionID: sessionID) },
            timestampProvider: { "2026-07-15T12:00:00.000Z" },
            onInteractivePrompt: { hub.publish($0.event) },
            onInteractivePromptResolved: { hub.publish($0) })
    }

    private func publishAssistantEvent(hub: AgentEventHub, text: String) -> AgentEvent {
        let seq = hub.nextSyntheticSeq(sessionID: "session-1")
        let event = AgentEvent(eventID: "assistant-\(seq)",
                               seq: seq,
                               vendor: "codex",
                               workspaceID: "workspace-1",
                               sessionID: "session-1",
                               timestamp: "2026-07-15T12:00:\(String(format: "%02d", min(seq, 59)))Z",
                               type: .assistantMessage,
                               role: nil,
                               text: text,
                               name: nil,
                               input: nil,
                               output: nil,
                               toolCallID: nil,
                               metadata: ["panel_id": "panel-1"])
        hub.publish(event)
        return event
    }

    func testPendingSnapshotReusesRetainedSeqAndDoesNotAdvanceBounds() throws {
        let hub = AgentEventHub()
        let connection = makeConnection(hub: hub)

        // Prompt is published (its seq is retained by the hub) and then falls
        // outside the fetch window as newer events arrive.
        connection.receiveLine(Self.commandApprovalLine)
        let promptEvent = try XCTUnwrap(hub.fetch(workspaceID: "workspace-1",
                                                  sessionID: "session-1",
                                                  limit: 10).events.first { $0.type == .interactivePrompt })
        for index in 0..<4 {
            _ = publishAssistantEvent(hub: hub, text: "assistant \(index)")
        }

        let page = hub.fetch(workspaceID: "workspace-1", sessionID: "session-1", limit: 2)
        XCTAssertFalse(page.events.contains { $0.type == .interactivePrompt },
                       "the prompt must be outside the fetch window for this test")

        let pending = connection.pendingApprovalPromptEvents()
        // Snapshots must not allocate sequence numbers: repeated snapshots
        // return the identical retained identity (nextSyntheticSeq is now a
        // reserving call, so equality of two reservation calls is NOT the
        // correctness signal here).
        let pendingAgain = connection.pendingApprovalPromptEvents()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.seq, promptEvent.seq, "snapshot must reuse the retained published seq")
        XCTAssertEqual(pending.first?.eventID, promptEvent.eventID)
        XCTAssertEqual(pending.first?.metadata?["submit_state"], "pending")
        XCTAssertEqual(pendingAgain.first?.seq, pending.first?.seq)
        XCTAssertEqual(pendingAgain.first?.eventID, pending.first?.eventID)

        let merged = BridgePendingApprovalFetchMerge.merge(pageEvents: page.events,
                                                           pageOldestSeq: page.oldestSeq,
                                                           pageNewestSeq: page.newestSeq,
                                                           pendingEvents: pending)
        // The injected snapshot is included but bounds stay at the retained
        // hub page.
        XCTAssertTrue(merged.events.contains { $0.eventID == promptEvent.eventID })
        XCTAssertEqual(merged.newestSeq, page.newestSeq)
        XCTAssertEqual(merged.oldestSeq, page.oldestSeq)

        // The next real event's seq must not collide with anything injected.
        let nextEvent = publishAssistantEvent(hub: hub, text: "next real event")
        let allSeqs = merged.events.map(\.seq)
        XCTAssertFalse(allSeqs.contains(nextEvent.seq), "next real event seq must be fresh")

        // A client resuming after the merged newest_seq must still see the
        // next real event (no skipped events).
        let catchUp = hub.fetch(workspaceID: "workspace-1",
                                sessionID: "session-1",
                                limit: 10,
                                afterSeq: merged.newestSeq)
        XCTAssertTrue(catchUp.events.contains { $0.eventID == nextEvent.eventID })
    }

    func testSyntheticSeqReservationIsMonotonicAndRespectsNativePublishes() {
        let hub = AgentEventHub()
        // Consecutive reservations never collide even before anything is
        // published (batch-creation case).
        let first = hub.nextSyntheticSeq(sessionID: "session-1")
        let second = hub.nextSyntheticSeq(sessionID: "session-1")
        let third = hub.nextSyntheticSeq(sessionID: "session-1")
        XCTAssertEqual(Set([first, second, third]).count, 3)
        XCTAssertTrue(first < second && second < third)

        // A native publish with a larger seq lifts the next reservation.
        hub.publish(AgentEvent(eventID: "native-100",
                               seq: 100,
                               vendor: "codex",
                               workspaceID: "workspace-1",
                               sessionID: "session-1",
                               timestamp: "2026-07-15T12:00:00Z",
                               type: .assistantMessage,
                               role: nil,
                               text: "native",
                               name: nil,
                               input: nil,
                               output: nil,
                               toolCallID: nil,
                               metadata: ["panel_id": "panel-1"]))
        XCTAssertGreaterThan(hub.nextSyntheticSeq(sessionID: "session-1"), 100)
    }

    func testMergeKeepsSnapshotDynamicMetadataWhenPromptInsidePage() throws {
        let hub = AgentEventHub()
        let connection = makeConnection(hub: hub)
        connection.receiveLine(Self.commandApprovalLine)
        let promptEvent = try XCTUnwrap(hub.fetch(workspaceID: "workspace-1",
                                                  sessionID: "session-1",
                                                  limit: 10).events.first { $0.type == .interactivePrompt })

        // Start a submit so the snapshot carries submitting + client id.
        _ = try connection.submitApproval(promptID: try XCTUnwrap(promptEvent.metadata?["prompt_id"]),
                                          targetIndex: 0,
                                          clientRequestID: "client-1")
        let pending = connection.pendingApprovalPromptEvents()
        XCTAssertEqual(pending.first?.metadata?["submit_state"], "submitting")

        let page = hub.fetch(workspaceID: "workspace-1", sessionID: "session-1", limit: 10)
        XCTAssertTrue(page.events.contains { $0.eventID == promptEvent.eventID },
                      "the prompt must be INSIDE the page for this test")

        let merged = BridgePendingApprovalFetchMerge.merge(pageEvents: page.events,
                                                           pageOldestSeq: page.oldestSeq,
                                                           pageNewestSeq: page.newestSeq,
                                                           pendingEvents: pending)
        let mergedPrompts = merged.events.filter { $0.eventID == promptEvent.eventID }
        XCTAssertEqual(mergedPrompts.count, 1, "same eventID must merge to a single event")
        // The snapshot's dynamic submit metadata wins over the stale page
        // copy; identity/seq/timestamp stay the retained originals.
        XCTAssertEqual(mergedPrompts.first?.metadata?["submit_state"], "submitting")
        XCTAssertEqual(mergedPrompts.first?.metadata?["client_request_id"], "client-1")
        XCTAssertEqual(mergedPrompts.first?.seq, promptEvent.seq)
        XCTAssertEqual(merged.oldestSeq, page.oldestSeq)
        XCTAssertEqual(merged.newestSeq, page.newestSeq)
    }

    func testReplayMergeKeepsSnapshotDynamicMetadata() throws {
        let hub = AgentEventHub()
        let connection = makeConnection(hub: hub)
        connection.receiveLine(Self.commandApprovalLine)
        let promptEvent = try XCTUnwrap(hub.fetch(workspaceID: "workspace-1",
                                                  sessionID: "session-1",
                                                  limit: 10).events.first { $0.type == .interactivePrompt })
        _ = try connection.submitApproval(promptID: try XCTUnwrap(promptEvent.metadata?["prompt_id"]),
                                          targetIndex: 0,
                                          clientRequestID: "client-1")
        let pending = connection.pendingApprovalPromptEvents()

        let replayEnvelopes = [AgentEventEnvelope(replay: true, event: promptEvent)]
        let merged = BridgePendingApprovalFetchMerge.mergeReplayEnvelopes(replayEnvelopes,
                                                                          pendingEvents: pending)
        let mergedPrompts = merged.filter { $0.event.eventID == promptEvent.eventID }
        XCTAssertEqual(mergedPrompts.count, 1)
        XCTAssertEqual(mergedPrompts.first?.event.metadata?["submit_state"], "submitting")
        XCTAssertEqual(mergedPrompts.first?.event.metadata?["client_request_id"], "client-1")
        XCTAssertEqual(mergedPrompts.first?.replay, true)
    }

    func testSubscribeRacePromptDeliveredOnceWithSnapshotMetadata() throws {
        // Race: the live subscriber is installed FIRST, the prompt publishes,
        // THEN the pending-snapshot provider answers with the same eventID.
        // The client must receive exactly one copy — the snapshot's newest
        // submit metadata — not a replay/live duplicate.
        let hub = AgentEventHub()
        let connection = makeConnection(hub: hub)
        let gate = BridgeAgentEventReplayGate()
        var delivered = [AgentEventEnvelope]()
        let (subscriptionID, replayEnvelopes) = hub.subscribe(workspaceID: "workspace-1",
                                                              sessionID: "session-1") { envelope in
            if let envelope = gate.receive(envelope) {
                delivered.append(envelope)
            }
        }
        defer { hub.unsubscribe(subscriptionID) }
        XCTAssertTrue(replayEnvelopes.isEmpty)

        // Prompt publishes between subscribe() and the snapshot fetch: it
        // lands in the gate's live buffer.
        connection.receiveLine(Self.commandApprovalLine)
        let promptEvent = try XCTUnwrap(hub.fetch(workspaceID: "workspace-1",
                                                  sessionID: "session-1",
                                                  limit: 10).events.first { $0.type == .interactivePrompt })
        _ = try connection.submitApproval(promptID: try XCTUnwrap(promptEvent.metadata?["prompt_id"]),
                                          targetIndex: 0,
                                          clientRequestID: "client-1")

        // Server order: inject the snapshot into the replay stream, send it,
        // then open the gate suppressing everything already replayed.
        hub.drainDeliveriesForTesting()
        let injected = BridgePendingApprovalFetchMerge.mergeReplayEnvelopes(replayEnvelopes,
                                                                            pendingEvents: connection.pendingApprovalPromptEvents())
        delivered.append(contentsOf: injected)
        delivered.append(contentsOf: gate.open(suppressing: Set(injected.map(\.event.eventID))))

        let promptCopies = delivered.filter { $0.event.eventID == promptEvent.eventID }
        XCTAssertEqual(promptCopies.count, 1,
                       "the same delivery must not arrive via both replay and the live buffer")
        XCTAssertEqual(promptCopies.first?.event.metadata?["submit_state"], "submitting",
                       "the surviving copy must carry the snapshot's newest submit metadata")
        XCTAssertEqual(promptCopies.first?.event.metadata?["client_request_id"], "client-1")
    }

    func testReplaySuppressionCoversLiveEnvelopeArrivingAfterGateOpen() throws {
        // Production race on the ordered drain: P is STORED but its live
        // delivery is stuck behind an earlier sink; the pending snapshot
        // merge injects P into the replay; the server sends the replay and
        // opens the gate while live P is still queued. The suppression must
        // cover the late live arrival — the subscription sees P exactly once.
        let hub = AgentEventHub()
        let connection = makeConnection(hub: hub)
        let gate = BridgeAgentEventReplayGate()
        var delivered = [AgentEventEnvelope]()
        let deliveredLock = NSLock()

        // Blocker: an earlier subscription whose sink jams the delivery queue.
        let blockerEntered = DispatchSemaphore(value: 0)
        let releaseBlocker = DispatchSemaphore(value: 0)
        let (blockerID, _) = hub.subscribe(workspaceID: "workspace-1", sessionID: "blocker-session") { _ in
            blockerEntered.signal()
            _ = releaseBlocker.wait(timeout: .now() + 5.0)
        }
        defer { hub.unsubscribe(blockerID) }

        let (subscriptionID, replayEnvelopes) = hub.subscribe(workspaceID: "workspace-1",
                                                              sessionID: "session-1") { envelope in
            if let envelope = gate.receive(envelope) {
                deliveredLock.lock()
                delivered.append(envelope)
                deliveredLock.unlock()
            }
        }
        defer { hub.unsubscribe(subscriptionID) }
        XCTAssertTrue(replayEnvelopes.isEmpty)

        let blockerPublishDone = expectation(description: "blocker publisher returned")
        DispatchQueue.global(qos: .userInitiated).async {
            hub.publish(AgentEvent(eventID: "blocker-event",
                                   seq: 1,
                                   vendor: "codex",
                                   workspaceID: "workspace-1",
                                   sessionID: "blocker-session",
                                   timestamp: "2026-07-15T12:00:00.000Z",
                                   type: .assistantMessage,
                                   role: nil,
                                   text: "jam",
                                   name: nil,
                                   input: nil,
                                   output: nil,
                                   toolCallID: nil,
                                   metadata: nil))
            blockerPublishDone.fulfill()
        }
        XCTAssertEqual(blockerEntered.wait(timeout: .now() + 2.0), .success)

        // P stores now; its live delivery is queued BEHIND the blocker.
        let promptStored = DispatchSemaphore(value: 0)
        hub.postStoreDeliveryHook = { event in
            if event.sessionID == "session-1" {
                promptStored.signal()
            }
        }
        let promptPublishDone = expectation(description: "prompt publisher returned")
        DispatchQueue.global(qos: .userInitiated).async {
            connection.receiveLine(Self.commandApprovalLine)
            promptPublishDone.fulfill()
        }
        XCTAssertEqual(promptStored.wait(timeout: .now() + 2.0), .success)
        let pending = connection.pendingApprovalPromptEvents()
        let promptEventID = try XCTUnwrap(pending.first?.eventID)

        // Server-shaped replay injection + send + open while live P is stuck.
        let injected = BridgePendingApprovalFetchMerge.mergeReplayEnvelopes(replayEnvelopes,
                                                                            pendingEvents: pending)
        XCTAssertEqual(injected.map(\.event.eventID), [promptEventID])
        deliveredLock.lock()
        delivered.append(contentsOf: injected)
        deliveredLock.unlock()
        let flushed = gate.open(suppressing: Set(injected.map(\.event.eventID)))
        deliveredLock.lock()
        delivered.append(contentsOf: flushed)
        deliveredLock.unlock()

        // Release the jam: the late live P now reaches the OPEN gate.
        releaseBlocker.signal()
        wait(for: [blockerPublishDone, promptPublishDone], timeout: 2.0)
        hub.drainDeliveriesForTesting()

        deliveredLock.lock()
        let promptCopies = delivered.filter { $0.event.eventID == promptEventID }
        deliveredLock.unlock()
        XCTAssertEqual(promptCopies.count, 1,
                       "the subscription must see the prompt exactly once, got \(promptCopies.count)")
    }

    func testUnsubscribedSinkIsNotCalledByQueuedDrains() throws {
        // Cancellation linearization: a drain may already have resolved the
        // old sink, but it still must not invoke that sink after unsubscribe
        // returned; a replacement subscriber receives only its own events.
        let hub = AgentEventHub()
        var oldSinkCalls = 0
        var newDelivered = [String]()
        let (oldID, _) = hub.subscribe(workspaceID: "workspace-1", sessionID: "session-1") { _ in
            oldSinkCalls += 1
        }

        let resolvedButNotInvoked = DispatchSemaphore(value: 0)
        let releaseInvoke = DispatchSemaphore(value: 0)
        hub.preInvokeDeliveryHook = { [weak hub] in
            hub?.preInvokeDeliveryHook = nil
            resolvedButNotInvoked.signal()
            _ = releaseInvoke.wait(timeout: .now() + 5.0)
        }
        let oldPublishDone = expectation(description: "old publisher returned")
        DispatchQueue.global(qos: .userInitiated).async {
            _ = self.publishAssistantEvent(hub: hub, text: "queued for old")
            oldPublishDone.fulfill()
        }
        XCTAssertEqual(resolvedButNotInvoked.wait(timeout: .now() + 2.0), .success)

        // The old sink has been resolved to the drain's local value, but its
        // gate is cancelled before invocation begins.
        hub.unsubscribe(oldID)
        let (newID, _) = hub.subscribe(workspaceID: "workspace-1", sessionID: "session-1") { envelope in
            newDelivered.append(envelope.event.eventID)
        }
        defer { hub.unsubscribe(newID) }

        releaseInvoke.signal()
        wait(for: [oldPublishDone], timeout: 2.0)
        let newEvent = publishAssistantEvent(hub: hub, text: "for new subscriber")
        hub.drainDeliveriesForTesting()

        XCTAssertEqual(oldSinkCalls, 0,
                       "a queued drain must not call an unsubscribed sink")
        XCTAssertEqual(newDelivered, [newEvent.eventID],
                       "the replacement subscriber receives only its own events")
    }

    func testGateOpenStillDeliversUnreplayedBufferedEvents() throws {
        let hub = AgentEventHub()
        let gate = BridgeAgentEventReplayGate()
        var delivered = [AgentEventEnvelope]()
        let (subscriptionID, _) = hub.subscribe(workspaceID: "workspace-1",
                                                sessionID: "session-1") { envelope in
            if let envelope = gate.receive(envelope) {
                delivered.append(envelope)
            }
        }
        defer { hub.unsubscribe(subscriptionID) }
        let live = publishAssistantEvent(hub: hub, text: "buffered while replaying")
        hub.drainDeliveriesForTesting()
        delivered.append(contentsOf: gate.open(suppressing: ["some-other-event"]))
        XCTAssertEqual(delivered.map(\.event.eventID), [live.eventID],
                       "suppression is by eventID only; unrelated buffered events must flow")
    }

    func testEmptyPageWithOlderSnapshotDoesNotLowerCursorBelowRequestedAfterSeq() throws {
        // Poll: after_seq=10 returns an empty page, but a pending snapshot
        // retained at seq 5 is injected. The reported bounds must not drag
        // the client's cursor backwards below the requested position.
        let hub = AgentEventHub()
        let connection = makeConnection(hub: hub)
        connection.receiveLine(Self.commandApprovalLine)
        let pending = connection.pendingApprovalPromptEvents()
        let snapshotSeq = try XCTUnwrap(pending.first?.seq)

        let requestedAfterSeq = snapshotSeq + 9
        let page = hub.fetch(workspaceID: "workspace-1",
                             sessionID: "session-1",
                             limit: 10,
                             afterSeq: requestedAfterSeq)
        XCTAssertTrue(page.events.isEmpty)

        let merged = BridgePendingApprovalFetchMerge.merge(pageEvents: page.events,
                                                           pageOldestSeq: page.oldestSeq,
                                                           pageNewestSeq: page.newestSeq,
                                                           requestedAfterSeq: requestedAfterSeq,
                                                           pendingEvents: pending)
        // The snapshot itself is still delivered (the card must recover)...
        XCTAssertEqual(merged.events.map(\.eventID), pending.map(\.eventID))
        // ...but the poll cursor must not regress.
        XCTAssertGreaterThanOrEqual(merged.newestSeq, requestedAfterSeq,
                                    "newest_seq must never fall below the requested after_seq")
    }

    private func tokenPromptEvent(seq: Int, token: String, promptID: String = "prompt-1") -> AgentEvent {
        AgentEvent(eventID: token,
                   seq: seq,
                   vendor: "codex",
                   workspaceID: "workspace-1",
                   sessionID: "session-1",
                   timestamp: "2026-07-15T12:00:\(String(format: "%02d", min(seq, 59))).000Z",
                   type: .interactivePrompt,
                   role: nil,
                   text: "Approve?",
                   name: nil,
                   input: nil,
                   output: nil,
                   toolCallID: nil,
                   metadata: [
                    "panel_id": "panel-1",
                    "prompt_id": promptID,
                    "source": "codex_command_approval",
                    "lifecycle_token": token,
                   ],
                   payload: .object([
                    "prompt_id": .string(promptID),
                    "vendor": .string("codex"),
                    "source": .string("codex_command_approval"),
                    "submit_channel": .string("codex_app_server"),
                    "title": .string("Approve?"),
                    "body": .string("Command: ls"),
                    "selected_index": .number(0),
                    "options": .array([
                        .object(["index": .number(0), "label": .string("Yes"), "input_sequence": .string("accept")]),
                    ]),
                    "lifecycle_token": .string(token),
                   ]))
    }

    private func tokenResolvedEvent(seq: Int, token: String?, promptID: String = "prompt-1", reason: String = "server_resolved") -> AgentEvent {
        var metadata = [
            "panel_id": "panel-1",
            "prompt_id": promptID,
            "source": "codex_command_approval",
            "reason": reason,
        ]
        if let token {
            metadata["lifecycle_token"] = token
        }
        return AgentEvent(eventID: "resolved-\(promptID)-\(token ?? "tokenless")-\(seq)",
                          seq: seq,
                          vendor: "codex",
                          workspaceID: "workspace-1",
                          sessionID: "session-1",
                          timestamp: "2026-07-15T12:01:\(String(format: "%02d", min(seq, 59))).000Z",
                          type: .interactivePromptResolved,
                          role: nil,
                          text: nil,
                          name: nil,
                          input: nil,
                          output: nil,
                          toolCallID: nil,
                          metadata: metadata)
    }

    func testLateRebaseTokenATerminalDoesNotSuppressTokenBPromptInMergeOrActiveQuery() throws {
        // Hub publish authority: B prompt goes in first, the LATE token-A
        // terminal claims an older seq and is rebased AFTER B. The merge
        // suppression and the active query must key on the lifecycle token,
        // not on seq/promptID.
        let hub = AgentEventHub()
        hub.publish(tokenPromptEvent(seq: 10, token: "token-B"))
        hub.publish(tokenResolvedEvent(seq: 5, token: "token-A"))

        let page = hub.fetch(workspaceID: "workspace-1", sessionID: "session-1", limit: 10)
        XCTAssertEqual(page.events.count, 2)
        XCTAssertGreaterThan(page.events.last!.seq, 10, "the late terminal must have been rebased after B")

        let merged = BridgePendingApprovalFetchMerge.merge(pageEvents: [],
                                                           pageOldestSeq: 0,
                                                           pageNewestSeq: 0,
                                                           pendingEvents: [tokenPromptEvent(seq: 10, token: "token-B")])
        _ = merged
        let suppressed = AgentInteractivePromptEventReducer.pendingEvents([tokenPromptEvent(seq: 10, token: "token-B")],
                                                                          excludingResolvedIn: page.events)
        XCTAssertEqual(suppressed.map(\.eventID), ["token-B"],
                       "a terminal for lifecycle A must not suppress lifecycle B's pending snapshot")

        XCTAssertNotNil(hub.activeInteractivePrompt(workspaceID: "workspace-1",
                                                    sessionID: "session-1",
                                                    promptID: "prompt-1"),
                        "lifecycle B stays active after lifecycle A's terminal")
    }

    func testSubmitFallbackDoesNotAnswerTokenBWithTokenATerminal() throws {
        // No runtime entry: the syncer falls back to the Hub. A token-B
        // submit must never be answered by lifecycle A's terminal.
        let hub = AgentEventHub()
        hub.publish(tokenPromptEvent(seq: 10, token: "token-B"))
        hub.publish(tokenResolvedEvent(seq: 5, token: "token-A"))
        let syncer = CodexAppServerRegistryRuntimeSyncer(eventHub: hub, attachHandler: { _, _, _, _, _, _, _ in
            FakeMergeRuntimeSession()
        })

        XCTAssertThrowsError(try syncer.submitApproval(promptID: "prompt-1",
                                                       targetIndex: 0,
                                                       clientRequestID: "client-B",
                                                       lifecycleToken: "token-B",
                                                       workspaceID: "workspace-1",
                                                       panelID: "panel-1",
                                                       sessionID: "session-1")) { error in
            guard case BridgeInternalError.notFound = error else {
                return XCTFail("token-B submit must not be answered by lifecycle A's terminal, got \(error)")
            }
        }

        // Only B's own terminal may answer B idempotently.
        hub.publish(tokenResolvedEvent(seq: 20, token: "token-B"))
        guard case .alreadyResolved(let event) = try syncer.submitApproval(promptID: "prompt-1",
                                                                           targetIndex: 0,
                                                                           clientRequestID: "client-B",
                                                                           lifecycleToken: "token-B",
                                                                           workspaceID: "workspace-1",
                                                                           panelID: "panel-1",
                                                                           sessionID: "session-1") else {
            return XCTFail("expected alreadyResolved from B's own terminal")
        }
        XCTAssertEqual(event.metadata?["lifecycle_token"], "token-B")
    }

    func testLifecycleBOnlyTerminatedByItsOwnTerminal() throws {
        let hub = AgentEventHub()
        hub.publish(tokenResolvedEvent(seq: 1, token: "token-A"))
        hub.publish(tokenPromptEvent(seq: 10, token: "token-B"))
        XCTAssertNotNil(hub.activeInteractivePrompt(workspaceID: "workspace-1",
                                                    sessionID: "session-1",
                                                    promptID: "prompt-1"))
        hub.publish(tokenResolvedEvent(seq: 20, token: "token-B"))
        XCTAssertNil(hub.activeInteractivePrompt(workspaceID: "workspace-1",
                                                 sessionID: "session-1",
                                                 promptID: "prompt-1"),
                     "B's own terminal ends it")
    }

    private func tokenlessCodexPromptEvent(seq: Int, promptID: String = "prompt-1") -> AgentEvent {
        AgentEvent(eventID: "tokenless-codex-\(promptID)-\(seq)",
                   seq: seq,
                   vendor: "codex",
                   workspaceID: "workspace-1",
                   sessionID: "session-1",
                   timestamp: "2026-07-15T12:00:\(String(format: "%02d", min(seq, 59))).000Z",
                   type: .interactivePrompt,
                   role: nil,
                   text: "Approve?",
                   name: nil,
                   input: nil,
                   output: nil,
                   toolCallID: nil,
                   metadata: [
                    "panel_id": "panel-1",
                    "prompt_id": promptID,
                    "source": "codex_command_approval",
                    "submit_channel": "codex_app_server",
                   ],
                   payload: .object([
                    "prompt_id": .string(promptID),
                    "vendor": .string("codex"),
                    "source": .string("codex_command_approval"),
                    "submit_channel": .string("codex_app_server"),
                    "title": .string("Approve?"),
                    "body": .string("Command: ls"),
                    "selected_index": .number(0),
                    "options": .array([
                        .object(["index": .number(0), "label": .string("Yes"), "input_sequence": .string("accept")]),
                    ]),
                   ]))
    }

    func testTokenlessCodexPromptFailsClosedAgainstAnyTerminalInMergeAndActiveQuery() throws {
        // A capability-required (Codex) prompt whose token is MISSING must
        // fail closed: no terminal (tokenless, token-A, or mismatched) may
        // suppress or clear it by promptID. Asserted on the actual merge
        // output and the active query.
        for terminalToken in [nil, "token-A"] as [String?] {
            let hub = AgentEventHub()
            let prompt = tokenlessCodexPromptEvent(seq: 10)
            hub.publish(prompt)
            hub.publish(tokenResolvedEvent(seq: 20, token: terminalToken))
            hub.drainDeliveriesForTesting()

            XCTAssertNotNil(hub.activeInteractivePrompt(workspaceID: "workspace-1",
                                                        sessionID: "session-1",
                                                        promptID: "prompt-1"),
                            "a tokenless Codex prompt must stay ACTIVE against a \(terminalToken ?? "tokenless") terminal")

            let page = hub.fetch(workspaceID: "workspace-1", sessionID: "session-1", limit: 10)
            let merged = BridgePendingApprovalFetchMerge.merge(pageEvents: page.events,
                                                               pageOldestSeq: page.oldestSeq,
                                                               pageNewestSeq: page.newestSeq,
                                                               pendingEvents: [prompt])
            XCTAssertTrue(merged.events.contains { $0.eventID == prompt.eventID },
                          "the merge output must retain the tokenless Codex prompt against a \(terminalToken ?? "tokenless") terminal")

            let replay = BridgePendingApprovalFetchMerge.mergeReplayEnvelopes(page.events.map { AgentEventEnvelope(replay: true, event: $0) },
                                                                              pendingEvents: [prompt])
            XCTAssertTrue(replay.contains { $0.event.eventID == prompt.eventID },
                          "the subscribe replay output must retain the prompt too")
        }
    }

    // R13 delta D1: a tokenless CAPABILITY terminal must not create a legacy
    // tombstone — the pending legacy opener survives fetch merge and
    // subscribe replay even when the page omits it.
    func testTokenlessCapabilityTerminalDoesNotTombstoneLegacyOpener() throws {
        let legacyOpener = AgentEvent(eventID: "legacy-opener-10",
                                      seq: 10,
                                      vendor: "claude",
                                      workspaceID: "workspace-1",
                                      sessionID: "session-1",
                                      timestamp: "2026-07-15T12:00:10.000Z",
                                      type: .interactivePrompt,
                                      role: nil,
                                      text: "Continue?",
                                      name: nil,
                                      input: nil,
                                      output: nil,
                                      toolCallID: nil,
                                      metadata: ["panel_id": "panel-1", "prompt_id": "legacy-1", "source": "workflow_confirm"],
                                      payload: .object([
                                        "prompt_id": .string("legacy-1"),
                                        "vendor": .string("claude"),
                                        "source": .string("workflow_confirm"),
                                        "title": .string("Continue?"),
                                        "body": .string("Continue?"),
                                        "selected_index": .number(0),
                                        "options": .array([
                                            .object(["index": .number(0), "label": .string("Yes"), "input_sequence": .string("\r")]),
                                        ]),
                                      ]))
        // A tokenless CAPABILITY terminal (codex source, no lifecycle_token).
        let capabilityTokenlessTerminal = AgentEvent(eventID: "cap-tokenless-20",
                                                     seq: 20,
                                                     vendor: "codex",
                                                     workspaceID: "workspace-1",
                                                     sessionID: "session-1",
                                                     timestamp: "2026-07-15T12:00:20.000Z",
                                                     type: .interactivePromptResolved,
                                                     role: nil,
                                                     text: nil,
                                                     name: nil,
                                                     input: nil,
                                                     output: nil,
                                                     toolCallID: nil,
                                                     metadata: ["panel_id": "panel-1", "prompt_id": "legacy-1", "source": "codex_command_approval", "reason": "server_resolved"])

        // The page contains ONLY the later terminal — the pending snapshot
        // path is genuinely exercised.
        let merged = BridgePendingApprovalFetchMerge.merge(pageEvents: [capabilityTokenlessTerminal],
                                                           pageOldestSeq: 20,
                                                           pageNewestSeq: 20,
                                                           pendingEvents: [legacyOpener])
        XCTAssertTrue(merged.events.contains { $0.eventID == "legacy-opener-10" },
                      "fetch merge must keep the legacy opener — a tokenless capability terminal is not its closure, got \(merged.events.map(\.eventID))")

        let replay = BridgePendingApprovalFetchMerge.mergeReplayEnvelopes(
            [AgentEventEnvelope(replay: true, event: capabilityTokenlessTerminal)],
            pendingEvents: [legacyOpener])
        XCTAssertTrue(replay.contains { $0.event.eventID == "legacy-opener-10" },
                      "subscribe replay must keep the legacy opener too, got \(replay.map(\.event.eventID))")

        // Hub active lookup agrees.
        let hub = AgentEventHub()
        hub.publish(legacyOpener)
        hub.publish(capabilityTokenlessTerminal)
        XCTAssertNotNil(hub.activeInteractivePrompt(workspaceID: "workspace-1",
                                                    sessionID: "session-1",
                                                    promptID: "legacy-1"),
                        "the Hub active lookup keeps the legacy opener against a tokenless capability terminal")
    }

    func testTokenlessLegacyPromptKeepsPromptIDContract() throws {
        // Non-Codex prompts carry no token: the legacy promptID+seq contract
        // stays intact.
        let hub = AgentEventHub()
        let legacyPrompt = AgentEvent(eventID: "legacy-prompt-1",
                                      seq: 10,
                                      vendor: "claude",
                                      workspaceID: "workspace-1",
                                      sessionID: "session-1",
                                      timestamp: "2026-07-15T12:00:10.000Z",
                                      type: .interactivePrompt,
                                      role: nil,
                                      text: "Continue?",
                                      name: nil,
                                      input: nil,
                                      output: nil,
                                      toolCallID: nil,
                                      metadata: ["panel_id": "panel-1", "prompt_id": "legacy-1"],
                                      payload: .object([
                                        "prompt_id": .string("legacy-1"),
                                        "vendor": .string("claude"),
                                        "source": .string("workflow_confirm"),
                                        "title": .string("Continue?"),
                                        "body": .string("Continue?"),
                                        "selected_index": .number(0),
                                        "options": .array([
                                            .object(["index": .number(0), "label": .string("Yes"), "input_sequence": .string("\r")]),
                                        ]),
                                      ]))
        hub.publish(legacyPrompt)
        // R13 B3D1 contract: only a genuinely LEGACY terminal (tokenless AND
        // non-capability) closes a legacy opener — a tokenless Codex
        // capability terminal proves nothing.
        let legacyTerminal = AgentEvent(eventID: "resolved-legacy-1-20",
                                        seq: 20,
                                        vendor: "claude",
                                        workspaceID: "workspace-1",
                                        sessionID: "session-1",
                                        timestamp: "2026-07-15T12:01:20.000Z",
                                        type: .interactivePromptResolved,
                                        role: nil,
                                        text: nil,
                                        name: nil,
                                        input: nil,
                                        output: nil,
                                        toolCallID: nil,
                                        metadata: ["panel_id": "panel-1", "prompt_id": "legacy-1", "source": "workflow_confirm", "reason": "server_resolved"])
        hub.publish(legacyTerminal)
        XCTAssertNil(hub.activeInteractivePrompt(workspaceID: "workspace-1",
                                                 sessionID: "session-1",
                                                 promptID: "legacy-1"))
        let suppressed = AgentInteractivePromptEventReducer.pendingEvents(
            [legacyPrompt],
            excludingResolvedIn: hub.fetch(workspaceID: "workspace-1", sessionID: "session-1", limit: 10).events)
        XCTAssertTrue(suppressed.isEmpty, "legacy tokenless terminals keep suppressing by promptID+seq")
    }

    func testOldExpiredAttemptDoesNotSuppressNewerPendingAttempt() throws {
        let hub = AgentEventHub()

        // First connection: prompt published, then the connection dies and
        // the prompt expires.
        let firstConnection = makeConnection(hub: hub)
        firstConnection.receiveLine(Self.commandApprovalLine)
        firstConnection.close()

        // Second connection to the same app-server process: the request is
        // re-delivered as a new pending attempt.
        let secondConnection = makeConnection(hub: hub)
        secondConnection.receiveLine(Self.commandApprovalLine)

        let page = hub.fetch(workspaceID: "workspace-1", sessionID: "session-1", limit: 50)
        let pending = secondConnection.pendingApprovalPromptEvents()
        XCTAssertEqual(pending.count, 1)

        let merged = BridgePendingApprovalFetchMerge.merge(pageEvents: page.events,
                                                           pageOldestSeq: page.oldestSeq,
                                                           pageNewestSeq: page.newestSeq,
                                                           pendingEvents: pending)

        // The old expired terminal is in the page, but the NEWER pending
        // attempt (sorting after it) must still be present so the card is
        // actionable after reconnect.
        let expiredCount = merged.events.filter { $0.type == .interactivePromptResolved && $0.metadata?["reason"] == "expired" }.count
        XCTAssertEqual(expiredCount, 1)
        let lastLifecycleEvent = merged.events
            .filter { $0.metadata?["prompt_id"] != nil }
            .max(by: { $0.seq < $1.seq })
        // The newest lifecycle event is the re-delivered prompt (already part
        // of the retained page here), so the card ends actionable.
        XCTAssertEqual(lastLifecycleEvent?.type, .interactivePrompt)
        XCTAssertEqual(lastLifecycleEvent?.eventID, pending.first?.eventID)
        XCTAssertEqual(merged.newestSeq, page.newestSeq)
    }
}
