import XCTest
@testable import RemoteBridge

final class AgentEventHubTests: XCTestCase {
    func testSessionStartedStickyReplayUsesReservedSequenceOnlyForFullReplay() {
        let hub = AgentEventHub()
        hub.publish(AgentEvent(eventID: "session-start:test",
                               seq: transcriptSessionStartedSequence,
                               vendor: "claude",
                               workspaceID: "workspace",
                               sessionID: "session",
                               timestamp: "2026-01-01T00:00:00Z",
                               type: .sessionStarted,
                               role: nil,
                               text: nil,
                               name: nil,
                               input: nil,
                               output: nil,
                               toolCallID: nil,
                               metadata: nil))
        hub.publish(AgentEvent(eventID: "assistant:test:1",
                               seq: transcriptEventSequence(lineOffset: 100, ordinal: 0),
                               vendor: "claude",
                               workspaceID: "workspace",
                               sessionID: "session",
                               timestamp: "2026-01-01T00:00:01Z",
                               type: .assistantMessage,
                               role: "assistant",
                               text: "hello",
                               name: nil,
                               input: nil,
                               output: nil,
                               toolCallID: nil,
                               metadata: nil))

        let (_, fullReplay) = hub.subscribe(workspaceID: "workspace", sessionID: "session", sinceSeq: nil) { _ in }
        XCTAssertEqual(fullReplay.map(\.event.type), [.sessionStarted, .assistantMessage])

        let (_, incrementalReplay) = hub.subscribe(workspaceID: "workspace",
                                                   sessionID: "session",
                                                   sinceSeq: 50) { _ in }
        XCTAssertEqual(incrementalReplay.map(\.event.type), [.assistantMessage])
    }

    func testFetchAfterSeqReturnsEarliestMissingEventsInAscendingOrder() {
        let hub = AgentEventHub()
        for seq in 1...5 {
            hub.publish(makeAssistantEvent(id: "assistant-\(seq)", seq: seq))
        }

        let result = hub.fetch(workspaceID: "workspace",
                               sessionID: "session",
                               limit: 2,
                               beforeSeq: nil,
                               afterSeq: 2)

        XCTAssertEqual(result.events.map(\.seq), [3, 4])
        XCTAssertEqual(result.oldestSeq, 3)
        XCTAssertEqual(result.newestSeq, 4)
        XCTAssertTrue(result.hasMore)
    }

    func testFetchAfterSeqUsesSessionBufferOrderForCatchUpCursor() {
        // Publish-monotonic authority: the late arrival that claimed seq 11
        // after 12 was stored is rebased above the high-water (13), so an
        // after_seq cursor can never permanently skip it.
        let hub = AgentEventHub()
        for seq in [10, 12, 11] {
            hub.publish(makeAssistantEvent(id: "assistant-\(seq)", seq: seq))
        }

        let result = hub.fetch(workspaceID: "workspace",
                               sessionID: "session",
                               limit: 10,
                               beforeSeq: nil,
                               afterSeq: 10)

        XCTAssertEqual(result.events.map(\.seq), [12, 13])
        XCTAssertEqual(result.events.map(\.eventID), ["assistant-12", "assistant-11"])
        XCTAssertEqual(result.oldestSeq, 12)
        XCTAssertEqual(result.newestSeq, 13)
        XCTAssertFalse(result.hasMore)
    }

    func testReplayUsesMigratedWorkspaceIDAfterSessionBindingChanges() {
        let hub = AgentEventHub()
        hub.publish(makeAssistantEvent(id: "assistant-1", seq: 1))
        _ = hub.migrateSession(sessionID: "session", toWorkspaceID: "current-workspace", panelID: "current-panel")

        let (_, replay) = hub.subscribe(workspaceID: "current-workspace", sessionID: "session", sinceSeq: nil) { _ in }

        XCTAssertEqual(replay.map(\.event.workspaceID), ["current-workspace"])
        XCTAssertEqual(replay.first?.event.metadata?["panel_id"], "current-panel")
    }

    func testFetchUsesMigratedWorkspaceIDAfterSessionBindingChanges() {
        let hub = AgentEventHub()
        hub.publish(makeAssistantEvent(id: "assistant-1", seq: 1))
        _ = hub.migrateSession(sessionID: "session", toWorkspaceID: "current-workspace", panelID: "current-panel")

        let result = hub.fetch(workspaceID: "current-workspace",
                               sessionID: "session",
                               limit: 10,
                               beforeSeq: nil,
                               afterSeq: nil)

        XCTAssertEqual(result.events.map(\.workspaceID), ["current-workspace"])
        XCTAssertEqual(result.events.first?.metadata?["panel_id"], "current-panel")
    }

    func testFetchHonorsMaxBytesForLatestSlice() {
        let hub = AgentEventHub()
        let event1 = makeAssistantEvent(id: "assistant-1", seq: 1, text: String(repeating: "a", count: 32))
        let event2 = makeAssistantEvent(id: "assistant-2", seq: 2, text: String(repeating: "b", count: 32))
        let event3 = makeAssistantEvent(id: "assistant-3", seq: 3, text: String(repeating: "c", count: 32))
        hub.publish(event1)
        hub.publish(event2)
        hub.publish(event3)

        let maxBytes = estimatedBytes(for: event2) + estimatedBytes(for: event3)

        let result = hub.fetch(workspaceID: "workspace",
                               sessionID: "session",
                               limit: 10,
                               maxBytes: maxBytes,
                               beforeSeq: nil,
                               afterSeq: nil)

        XCTAssertEqual(result.events.map(\.seq), [2, 3])
        XCTAssertEqual(result.oldestSeq, 2)
        XCTAssertEqual(result.newestSeq, 3)
        XCTAssertTrue(result.hasMore)
    }

    func testFetchAlwaysReturnsLatestEventWhenMaxBytesIsTooSmall() {
        let hub = AgentEventHub()
        hub.publish(makeAssistantEvent(id: "assistant-1", seq: 1, text: String(repeating: "a", count: 256)))
        hub.publish(makeAssistantEvent(id: "assistant-2", seq: 2, text: String(repeating: "b", count: 256)))

        let result = hub.fetch(workspaceID: "workspace",
                               sessionID: "session",
                               limit: 10,
                               maxBytes: 16,
                               beforeSeq: nil,
                               afterSeq: nil)

        XCTAssertEqual(result.events.map(\.seq), [2])
        XCTAssertEqual(result.oldestSeq, 2)
        XCTAssertEqual(result.newestSeq, 2)
        XCTAssertTrue(result.hasMore)
    }

    func testFetchBeforeSeqHonorsMaxBytesForOlderSlice() {
        let hub = AgentEventHub()
        let event1 = makeAssistantEvent(id: "assistant-1", seq: 1, text: String(repeating: "a", count: 32))
        let event2 = makeAssistantEvent(id: "assistant-2", seq: 2, text: String(repeating: "b", count: 32))
        let event3 = makeAssistantEvent(id: "assistant-3", seq: 3, text: String(repeating: "c", count: 32))
        hub.publish(event1)
        hub.publish(event2)
        hub.publish(event3)
        hub.publish(makeAssistantEvent(id: "assistant-4", seq: 4, text: "newer"))

        let maxBytes = estimatedBytes(for: event2) + estimatedBytes(for: event3)

        let result = hub.fetch(workspaceID: "workspace",
                               sessionID: "session",
                               limit: 10,
                               maxBytes: maxBytes,
                               beforeSeq: 4,
                               afterSeq: nil)

        XCTAssertEqual(result.events.map(\.seq), [2, 3])
        XCTAssertEqual(result.oldestSeq, 2)
        XCTAssertEqual(result.newestSeq, 3)
        XCTAssertTrue(result.hasMore)
    }

    func testFetchReplacesSingleOversizedToolResultWithPlaceholder() {
        let hub = AgentEventHub()
        hub.publish(makeToolResultEvent(id: "tool-result-1",
                                        seq: 1,
                                        output: String(repeating: "x", count: 4096)))

        let result = hub.fetch(workspaceID: "workspace",
                               sessionID: "session",
                               limit: 10,
                               maxBytes: 512,
                               beforeSeq: nil,
                               afterSeq: nil)

        XCTAssertEqual(result.events.count, 1)
        XCTAssertEqual(result.events.first?.seq, 1)
        XCTAssertEqual(result.events.first?.type, .toolResult)
        XCTAssertEqual(result.events.first?.metadata?["tidey_truncated"], "true")
        XCTAssertNotEqual(result.events.first?.output, String(repeating: "x", count: 4096))
        XCTAssertTrue((result.events.first?.output ?? "").contains("大小限制"))
    }

    // MARK: single sequence authority

    func testReservedSeqTakenByNativePublishRebasesSyntheticEvent() {
        let hub = AgentEventHub()
        // Reserve N for a synthetic event, but a native producer publishes
        // its own event with seq N first.
        let reserved = hub.nextSyntheticSeq(sessionID: "session")
        hub.publish(makeAssistantEvent(id: "native", seq: reserved))
        hub.publish(makeAssistantEvent(id: "synthetic", seq: reserved))

        let all = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 10)
        XCTAssertEqual(all.events.count, 2)
        let seqs = all.events.map(\.seq)
        XCTAssertEqual(Set(seqs).count, 2, "two events must never share a cursor seq, got \(seqs)")

        // Cursor catch-up must be able to reach BOTH events: limit=1 first,
        // then continue from the returned cursor.
        let first = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 1, afterSeq: 0)
        XCTAssertEqual(first.events.count, 1)
        let second = hub.fetch(workspaceID: "workspace",
                               sessionID: "session",
                               limit: 10,
                               afterSeq: first.events[0].seq)
        XCTAssertEqual(second.events.count, 1, "the second event must be reachable from the catch-up cursor")
        XCTAssertNotEqual(second.events[0].eventID, first.events[0].eventID)
    }

    func testBatchReservationsStayUniqueAgainstInterleavedNativePublishes() {
        let hub = AgentEventHub()
        // A batch reserves several seqs before any publish (e.g. terminal
        // events from one close), while a native producer interleaves.
        let r1 = hub.nextSyntheticSeq(sessionID: "session")
        let r2 = hub.nextSyntheticSeq(sessionID: "session")
        let r3 = hub.nextSyntheticSeq(sessionID: "session")
        hub.publish(makeAssistantEvent(id: "native-a", seq: r2))
        hub.publish(makeAssistantEvent(id: "batch-1", seq: r1))
        hub.publish(makeAssistantEvent(id: "batch-2", seq: r2))
        hub.publish(makeAssistantEvent(id: "batch-3", seq: r3))

        let all = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 10)
        XCTAssertEqual(all.events.count, 4)
        XCTAssertEqual(Set(all.events.map(\.seq)).count, 4,
                       "all published events must own distinct seqs, got \(all.events.map { ($0.eventID, $0.seq) })")
    }

    func testNativeHighSeqLiftsNextSyntheticReservation() {
        let hub = AgentEventHub()
        hub.publish(makeAssistantEvent(id: "native-high", seq: 100))
        let reserved = hub.nextSyntheticSeq(sessionID: "session")
        XCTAssertGreaterThan(reserved, 100)
        hub.publish(makeAssistantEvent(id: "synthetic", seq: reserved))
        let all = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 10)
        XCTAssertEqual(Set(all.events.map(\.seq)).count, 2)
    }

    func testLateUnseenLowerSeqIsRebasedAboveHighWater() throws {
        // A late producer publishing an unseen seq BELOW the stored
        // high-water must be rebased above it, or an after_seq cursor that
        // already advanced past it can never fetch the event.
        let hub = AgentEventHub()
        var liveSeqs = [Int]()
        let (subscriptionID, _) = hub.subscribe(workspaceID: "workspace", sessionID: "session") { envelope in
            liveSeqs.append(envelope.event.seq)
        }
        defer { hub.unsubscribe(subscriptionID) }

        hub.publish(makeAssistantEvent(id: "high", seq: 100))
        hub.publish(makeAssistantEvent(id: "late", seq: 50))
        hub.drainDeliveriesForTesting()

        let catchUp = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 10, afterSeq: 100)
        let late = try XCTUnwrap(catchUp.events.first)
        XCTAssertEqual(catchUp.events.map(\.eventID), ["late"],
                       "the late event must be reachable after the cursor already reached 100")
        XCTAssertGreaterThan(late.seq, 100)
        XCTAssertEqual(liveSeqs.count, 2)
        XCTAssertGreaterThan(liveSeqs[1], liveSeqs[0], "subscriber delivery must be seq-monotonic")
    }

    func testReservationsPublishedOutOfOrderStayMonotonic() {
        let hub = AgentEventHub()
        let r1 = hub.nextSyntheticSeq(sessionID: "session")
        let r2 = hub.nextSyntheticSeq(sessionID: "session")
        hub.publish(makeAssistantEvent(id: "second-reserved", seq: r2))
        hub.publish(makeAssistantEvent(id: "first-reserved", seq: r1))

        let all = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 10)
        XCTAssertEqual(Set(all.events.map(\.seq)).count, 2)
        let firstSeq = all.events.first { $0.eventID == "first-reserved" }!.seq
        let secondSeq = all.events.first { $0.eventID == "second-reserved" }!.seq
        XCTAssertGreaterThan(firstSeq, secondSeq,
                             "the later PUBLISH must land after the earlier one, regardless of reservation order")
        let catchUp = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 10, afterSeq: secondSeq)
        XCTAssertEqual(catchUp.events.map(\.eventID), ["first-reserved"], "cursor catch-up must not skip it")
    }

    func testConcurrentSyntheticReservationsAreUnique() {
        let hub = AgentEventHub()
        let lock = NSLock()
        var reservations = [Int]()
        let bothReserved = expectation(description: "both producers reserved")
        bothReserved.expectedFulfillmentCount = 2
        let releasePublish = DispatchSemaphore(value: 0)
        let group = DispatchGroup()

        for producer in 0..<2 {
            DispatchQueue.global(qos: .userInitiated).async(group: group) {
                let reserved = hub.nextSyntheticSeq(sessionID: "session")
                lock.lock()
                reservations.append(reserved)
                lock.unlock()
                bothReserved.fulfill()
                _ = releasePublish.wait(timeout: .now() + 5.0)
                hub.publish(self.makeAssistantEvent(id: "producer-\(producer)", seq: reserved))
            }
        }

        wait(for: [bothReserved], timeout: 2.0)
        releasePublish.signal()
        releasePublish.signal()
        XCTAssertEqual(group.wait(timeout: .now() + 5.0), .success)

        lock.lock()
        let observedReservations = reservations
        lock.unlock()
        XCTAssertEqual(Set(observedReservations).count, 2)
        let stored = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 10).events
        XCTAssertEqual(stored.count, 2)
        XCTAssertEqual(Set(stored.map(\.seq)).count, 2)
    }

    func testVeryOldUnseenSeqAfterTrimmingIsStillRebased() {
        // Buffer/used-set eviction must not resurrect old cursor positions:
        // the high-water is authoritative even after trims.
        let hub = AgentEventHub()
        for i in 1...20 {
            hub.publish(makeAssistantEvent(id: "e\(i)", seq: i * 10))
        }
        hub.publish(makeAssistantEvent(id: "ancient", seq: 1))
        let page = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 50, afterSeq: 200)
        XCTAssertEqual(page.events.map(\.eventID), ["ancient"])
        XCTAssertGreaterThan(page.events[0].seq, 200)
    }

    func testLiveSubscriberDeliveryFollowsStoreOrderAcrossConcurrentPublishers() {
        // Window: publisher LOW has STORED its (lower) seq but has not
        // delivered yet; publisher HIGH stores and delivers first. The
        // subscriber must still observe [low, high] — delivery must follow
        // the hub's store order, not the publishers' thread scheduling.
        let hub = AgentEventHub()
        let orderLock = NSLock()
        var delivered = [Int]()
        let bothDelivered = expectation(description: "both delivered")
        bothDelivered.expectedFulfillmentCount = 2
        let (subscriptionID, _) = hub.subscribe(workspaceID: "workspace", sessionID: "session") { envelope in
            orderLock.lock()
            delivered.append(envelope.event.seq)
            orderLock.unlock()
            bothDelivered.fulfill()
        }
        defer { hub.unsubscribe(subscriptionID) }

        let lowStored = DispatchSemaphore(value: 0)
        let releaseLow = DispatchSemaphore(value: 0)
        let lowDone = expectation(description: "low publisher done")
        hub.postStoreDeliveryHook = { [weak hub] event in
            guard event.eventID == "low" else { return }
            hub?.postStoreDeliveryHook = nil
            lowStored.signal()
            _ = releaseLow.wait(timeout: .now() + 5.0)
        }
        DispatchQueue.global(qos: .userInitiated).async {
            hub.publish(self.makeAssistantEvent(id: "low", seq: 10))
            lowDone.fulfill()
        }
        XCTAssertEqual(lowStored.wait(timeout: .now() + 2.0), .success,
                       "low must be STORED before high publishes")

        // Publisher HIGH stores and (in the broken ordering) delivers first.
        hub.publish(makeAssistantEvent(id: "high", seq: 20))
        releaseLow.signal()

        wait(for: [bothDelivered, lowDone], timeout: 2.0)
        orderLock.lock()
        let observed = delivered
        orderLock.unlock()
        XCTAssertEqual(observed, [10, 20],
                       "live delivery must follow the hub's accepted seq order, got \(observed)")
    }

    func testCrossProducerDeliveryStaysSeqMonotonicAndHistoricalNeverDelivers() {
        // Production-shaped regression: a transcript-style producer and an
        // approval-style producer publish concurrently from different
        // queues; the subscriber must see a seq-monotonic stream. Historical
        // storage never reaches the subscriber.
        let hub = AgentEventHub()
        let orderLock = NSLock()
        var delivered = [Int]()
        var deliveredIDs = [String]()
        let allDelivered = expectation(description: "all delivered")
        allDelivered.expectedFulfillmentCount = 40
        let (subscriptionID, _) = hub.subscribe(workspaceID: "workspace", sessionID: "session") { envelope in
            orderLock.lock()
            delivered.append(envelope.event.seq)
            deliveredIDs.append(envelope.event.eventID)
            orderLock.unlock()
            allDelivered.fulfill()
        }
        defer { hub.unsubscribe(subscriptionID) }

        let group = DispatchGroup()
        DispatchQueue.global(qos: .userInitiated).async(group: group) {
            for index in 0..<20 {
                let seq = hub.nextSyntheticSeq(sessionID: "session")
                hub.publish(self.makeAssistantEvent(id: "transcript-\(index)", seq: seq))
            }
        }
        DispatchQueue.global(qos: .userInitiated).async(group: group) {
            for index in 0..<20 {
                let seq = hub.nextSyntheticSeq(sessionID: "session")
                hub.publish(self.makeAssistantEvent(id: "prompt-\(index)", seq: seq))
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 5.0), .success)
        hub.publish(makeAssistantEvent(id: "historical", seq: 1),
                    deliverToSubscribers: false,
                    storage: .historicalBackfill)

        wait(for: [allDelivered], timeout: 5.0)
        orderLock.lock()
        let observed = delivered
        let observedIDs = deliveredIDs
        orderLock.unlock()
        XCTAssertEqual(observed.count, 40)
        XCTAssertEqual(observed, observed.sorted(),
                       "cross-producer live delivery must be seq-monotonic, got \(observed)")
        XCTAssertFalse(observedIDs.contains("historical"), "historical storage never delivers")
    }

    func testHistoricalBackfillKeepsOriginalCursorPosition() {
        let hub = AgentEventHub()
        var liveDelivered = [String]()
        let (subscriptionID, _) = hub.subscribe(workspaceID: "workspace", sessionID: "session") { envelope in
            liveDelivered.append(envelope.event.eventID)
        }
        defer { hub.unsubscribe(subscriptionID) }

        hub.publish(makeAssistantEvent(id: "live-100", seq: 100))
        // Historical page older than the stored window: it must keep its
        // original cursor position.
        hub.publish(makeAssistantEvent(id: "hist-50", seq: 50),
                    deliverToSubscribers: false,
                    storage: .historicalBackfill)

        let older = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 10, beforeSeq: 100)
        XCTAssertEqual(older.events.map(\.eventID), ["hist-50"],
                       "before_seq must reach the backfilled history at its original position")
        XCTAssertEqual(older.events.map(\.seq), [50])

        let catchUp = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 10, afterSeq: 100)
        XCTAssertTrue(catchUp.events.isEmpty,
                      "backfilled history must not appear as new live events, got \(catchUp.events.map(\.eventID))")
        hub.drainDeliveriesForTesting()
        XCTAssertEqual(liveDelivered, ["live-100"], "historical storage never reaches live subscribers")

        // The next live reservation still moves forward from the live cursor.
        XCTAssertGreaterThan(hub.nextSyntheticSeq(sessionID: "session"), 100)
    }

    func testUnsubscribeAfterSinkResolutionStillPreventsInvocation() {
        // Window: the drain RESOLVED the old sink to a local value but has
        // not invoked it; unsubscribe returns in that window. The old
        // callback must still never run.
        let hub = AgentEventHub()
        var oldSinkCalls = 0
        let (oldID, _) = hub.subscribe(workspaceID: "workspace", sessionID: "session") { _ in
            oldSinkCalls += 1
        }
        let resolvedButNotInvoked = DispatchSemaphore(value: 0)
        let releaseInvoke = DispatchSemaphore(value: 0)
        hub.preInvokeDeliveryHook = { [weak hub] in
            hub?.preInvokeDeliveryHook = nil
            resolvedButNotInvoked.signal()
            _ = releaseInvoke.wait(timeout: .now() + 5.0)
        }
        let publishDone = expectation(description: "publisher returned")
        DispatchQueue.global(qos: .userInitiated).async {
            hub.publish(self.makeAssistantEvent(id: "e1", seq: 1))
            publishDone.fulfill()
        }
        XCTAssertEqual(resolvedButNotInvoked.wait(timeout: .now() + 2.0), .success)

        // Unsubscribe fully RETURNS while the drain is paused pre-invoke.
        hub.unsubscribe(oldID)
        releaseInvoke.signal()
        wait(for: [publishDone], timeout: 2.0)
        hub.drainDeliveriesForTesting()
        XCTAssertEqual(oldSinkCalls, 0,
                       "a sink resolved before unsubscribe returned must still never be invoked")
    }

    func testUnsubscribeWaitsForInFlightSinkOnAnotherThread() {
        // The sink has BEGUN invoking on the delivery queue and is blocked
        // inside the callback. The cancel-wait interior hook PROVES the
        // unsubscribe thread arrived at its wait window (a broken no-wait
        // implementation never fires it); only after the sink releases may
        // unsubscribe return, and no further deliveries arrive.
        let hub = AgentEventHub()
        let orderLock = NSLock()
        var order = [String]()
        var sinkCalls = 0
        let sinkEntered = DispatchSemaphore(value: 0)
        let releaseSink = DispatchSemaphore(value: 0)
        let cancelWaiting = DispatchSemaphore(value: 0)
        hub.unsubscribeCancelWaitHook = {
            orderLock.lock()
            order.append("cancel-waiting")
            orderLock.unlock()
            cancelWaiting.signal()
        }
        let (subscriptionID, _) = hub.subscribe(workspaceID: "workspace", sessionID: "session") { _ in
            sinkCalls += 1
            if sinkCalls == 1 {
                sinkEntered.signal()
                _ = releaseSink.wait(timeout: .now() + 5.0)
                orderLock.lock()
                order.append("sink-released")
                orderLock.unlock()
            }
        }
        let publishDone = expectation(description: "publisher returned")
        DispatchQueue.global(qos: .userInitiated).async {
            hub.publish(self.makeAssistantEvent(id: "e1", seq: 1))
            publishDone.fulfill()
        }
        XCTAssertEqual(sinkEntered.wait(timeout: .now() + 2.0), .success)

        let unsubscribeReturned = expectation(description: "unsubscribe returned")
        DispatchQueue.global(qos: .userInitiated).async {
            hub.unsubscribe(subscriptionID)
            orderLock.lock()
            order.append("unsubscribe-returned")
            orderLock.unlock()
            unsubscribeReturned.fulfill()
        }
        // Barrier: unsubscribe must have ARRIVED at its cancel-wait window
        // (and therefore NOT returned) BEFORE the sink is released.
        XCTAssertEqual(cancelWaiting.wait(timeout: .now() + 2.0), .success,
                       "unsubscribe must reach the cancel wait window while the sink is in flight")
        orderLock.lock()
        let midFlight = order
        orderLock.unlock()
        XCTAssertEqual(midFlight, ["cancel-waiting"],
                       "unsubscribe must not have returned while the sink is still blocked, got \(midFlight)")

        releaseSink.signal()
        wait(for: [unsubscribeReturned, publishDone], timeout: 2.0)
        orderLock.lock()
        let observed = order
        orderLock.unlock()
        XCTAssertEqual(observed, ["cancel-waiting", "sink-released", "unsubscribe-returned"],
                       "unsubscribe returns only after the in-flight sink completed")

        hub.publish(makeAssistantEvent(id: "e2", seq: 2))
        hub.drainDeliveriesForTesting()
        XCTAssertEqual(sinkCalls, 1, "no further deliveries after unsubscribe returned")
    }

    func testSinkMayUnsubscribeItselfWithoutDeadlock() {
        let hub = AgentEventHub()
        var calls = 0
        var subscriptionID: UUID?
        let done = expectation(description: "self-unsubscribing sink ran")
        let (id, _) = hub.subscribe(workspaceID: "workspace", sessionID: "session") { _ in
            calls += 1
            if let subscriptionID {
                hub.unsubscribe(subscriptionID)
            }
            done.fulfill()
        }
        subscriptionID = id
        hub.publish(makeAssistantEvent(id: "e1", seq: 1))
        wait(for: [done], timeout: 2.0)
        hub.publish(makeAssistantEvent(id: "e2", seq: 2))
        hub.drainDeliveriesForTesting()
        XCTAssertEqual(calls, 1, "after self-unsubscribe no further deliveries arrive")
    }

    func testHistoricalInsertDoesNotEvictRetainedLiveWindow() {
        // Capacity-full live window [100,101,102]; a historical insert must
        // NOT evict live events or break the committed after_seq cursor.
        let hub = AgentEventHub(maxBufferedEvents: 3, maxSeenEventIDs: 100)
        var liveDelivered = [String]()
        let (subscriptionID, _) = hub.subscribe(workspaceID: "workspace", sessionID: "session") { envelope in
            liveDelivered.append(envelope.event.eventID)
        }
        defer { hub.unsubscribe(subscriptionID) }
        hub.publish(makeAssistantEvent(id: "live-100", seq: 100))
        hub.publish(makeAssistantEvent(id: "live-101", seq: 101))
        hub.publish(makeAssistantEvent(id: "live-102", seq: 102))
        hub.publish(makeAssistantEvent(id: "hist-50", seq: 50),
                    deliverToSubscribers: false,
                    storage: .historicalBackfill)

        let catchUp = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 10, afterSeq: 99)
        XCTAssertEqual(catchUp.events.map(\.eventID), ["live-100", "live-101", "live-102"],
                       "the retained live window must survive a historical insert")
        let older = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 10, beforeSeq: 100)
        XCTAssertEqual(older.events.map(\.eventID), ["hist-50"])
        hub.drainDeliveriesForTesting()
        XCTAssertFalse(liveDelivered.contains("hist-50"))
        XCTAssertGreaterThan(hub.nextSyntheticSeq(sessionID: "session"), 102,
                             "the live reservation is unaffected by history")
    }

    func testHistoricalInsertAtOrAboveLiveHighWaterIsRejected() {
        // The API contract requires history to sit BELOW the live cursor;
        // violations are enforced in production code, not by caller
        // assumption.
        let hub = AgentEventHub()
        hub.publish(makeAssistantEvent(id: "live-100", seq: 100))
        hub.publish(makeAssistantEvent(id: "hist-150", seq: 150),
                    deliverToSubscribers: false,
                    storage: .historicalBackfill)
        let all = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 10)
        XCTAssertEqual(all.events.map(\.eventID), ["live-100"],
                       "history at/above the live high-water must be rejected, got \(all.events.map(\.eventID))")
        XCTAssertGreaterThan(hub.nextSyntheticSeq(sessionID: "session"), 100)
        XCTAssertLessThanOrEqual(hub.nextSyntheticSeq(sessionID: "session"), 102,
                                 "a rejected historical insert must not inflate the live cursor")
    }

    func testVeryOldUnseenSeqAfterRealBufferEvictionIsStillRebased() throws {
        let hub = AgentEventHub(maxBufferedEvents: 4, maxSeenEventIDs: 4)
        for index in 1...20 {
            hub.publish(makeAssistantEvent(id: "event-\(index)", seq: index * 10))
        }

        let beforeLateArrival = try XCTUnwrap(hub.debugSnapshots().first)
        XCTAssertEqual(beforeLateArrival.bufferedEventCount, 4,
                       "the test must exercise the post-eviction state")
        XCTAssertEqual(beforeLateArrival.oldestSeq, 170)
        XCTAssertEqual(beforeLateArrival.newestSeq, 200)

        hub.publish(makeAssistantEvent(id: "ancient-unseen", seq: 1))

        let catchUp = hub.fetch(workspaceID: "workspace",
                                sessionID: "session",
                                limit: 10,
                                afterSeq: 200)
        let ancient = try XCTUnwrap(catchUp.events.first)
        XCTAssertEqual(catchUp.events.map(\.eventID), ["ancient-unseen"])
        XCTAssertGreaterThan(ancient.seq, 200)
    }

    func testSameEventIDRepublishDoesNotConsumeSequence() {
        let hub = AgentEventHub()
        let reserved = hub.nextSyntheticSeq(sessionID: "session")
        hub.publish(makeAssistantEvent(id: "prompt-1", seq: reserved, text: "original"))
        // An overlay/snapshot copy of the SAME delivery (same eventID) must
        // dedupe, not burn a new seq or shift the cursor.
        hub.publish(makeAssistantEvent(id: "prompt-1", seq: reserved, text: "overlaid"))

        let all = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 10)
        XCTAssertEqual(all.events.map(\.eventID), ["prompt-1"])
        XCTAssertEqual(all.events.map(\.seq), [reserved])
        XCTAssertEqual(hub.nextSyntheticSeq(sessionID: "session"), reserved + 1,
                       "an eventID dedupe must not consume sequence numbers")
    }

    private func makePromptEvent(id: String,
                                 seq: Int,
                                 promptID: String,
                                 token: String?,
                                 vendor: String = "codex",
                                 source: String = "codex_command_approval") -> AgentEvent {
        var metadata = ["prompt_id": promptID, "source": source]
        if let token {
            metadata["lifecycle_token"] = token
        }
        let payload: JSONValue = .object([
            "prompt_id": .string(promptID),
            "vendor": .string("codex"),
            "source": .string("codex_command_approval"),
            "title": .string("Approve?"),
            "body": .string("Command: ls"),
            "selected_index": .number(0),
            "options": .array([.object(["index": .number(0), "label": .string("Yes"), "input_sequence": .string("accept")])]),
        ])
        return AgentEvent(eventID: id,
                          seq: seq,
                          vendor: vendor,
                          workspaceID: "workspace",
                          sessionID: "session",
                          timestamp: "2026-01-01T00:00:00Z",
                          type: .interactivePrompt,
                          role: "assistant",
                          text: nil,
                          name: nil,
                          input: nil,
                          output: nil,
                          toolCallID: nil,
                          metadata: metadata,
                          payload: payload)
    }

    private func makeResolvedEvent(id: String,
                                   seq: Int,
                                   promptID: String,
                                   token: String?,
                                   vendor: String = "codex",
                                   source: String? = "codex_command_approval") -> AgentEvent {
        var metadata = ["prompt_id": promptID, "reason": "server_resolved"]
        if let source {
            metadata["source"] = source
        }
        if let token {
            metadata["lifecycle_token"] = token
        }
        return AgentEvent(eventID: id,
                          seq: seq,
                          vendor: vendor,
                          workspaceID: "workspace",
                          sessionID: "session",
                          timestamp: "2026-01-01T00:00:00Z",
                          type: .interactivePromptResolved,
                          role: "tool",
                          text: nil,
                          name: nil,
                          input: nil,
                          output: nil,
                          toolCallID: nil,
                          metadata: metadata,
                          payload: nil)
    }

    private func legacyPrompt(id: String, seq: Int, promptID: String) -> AgentEvent {
        makePromptEvent(id: id, seq: seq, promptID: promptID, token: nil,
                        vendor: "claude", source: "claude_ask_user_question")
    }

    private func legacyTerminal(id: String, seq: Int, promptID: String) -> AgentEvent {
        makeResolvedEvent(id: id, seq: seq, promptID: promptID, token: nil,
                          vendor: "claude", source: "claude_ask_user_question")
    }

    // R13 B3D1: a LEGACY opener is closed ONLY by a tokenless non-capability
    // terminal — a tokenful/capability Codex terminal neither closes it live
    // nor drags it out through the trim.
    func testLegacyOpenerSurvivesCapabilityTerminalAndTrim() {
        // Stored together (roomy hub): the capability terminal does not
        // close the legacy opener.
        let roomyHub = AgentEventHub(maxBufferedEvents: 10, maxSeenEventIDs: 100)
        roomyHub.publish(makeAssistantEvent(id: "live-1000", seq: 1000))
        roomyHub.replaceHistoricalEvents(sessionID: "session",
                                         events: [legacyPrompt(id: "opener-L", seq: 10, promptID: "p1"),
                                                  makeResolvedEvent(id: "terminal-codex", seq: 20, promptID: "p1", token: "token-X")],
                                         anchorSeq: 30)
        XCTAssertNotNil(roomyHub.activeInteractivePrompt(workspaceID: "workspace", sessionID: "session", promptID: "p1"),
                        "a tokenful Codex terminal never closes a legacy opener")

        // Trimmed (tiny hub): the mismatched-domain terminal being dropped
        // must not withdraw the still-active legacy opener.
        let hub = AgentEventHub(maxBufferedEvents: 1, maxSeenEventIDs: 100)
        hub.publish(makeAssistantEvent(id: "live-1000", seq: 1000))
        hub.replaceHistoricalEvents(sessionID: "session",
                                    events: [legacyPrompt(id: "opener-L", seq: 10, promptID: "p1"),
                                             makeResolvedEvent(id: "terminal-codex", seq: 20, promptID: "p1", token: "token-X")],
                                    anchorSeq: 12)
        let stored = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 100).events.map(\.eventID)
        XCTAssertTrue(stored.contains("opener-L"),
                      "the legacy opener survives the trim of a foreign-domain terminal, got \(stored)")
        XCTAssertNotNil(hub.activeInteractivePrompt(workspaceID: "workspace", sessionID: "session", promptID: "p1"))
    }

    // R13 B3D1: only the genuine legacy tokenless non-capability terminal
    // closes the legacy opener — live and atomically through the trim.
    func testLegacyOpenerClosedOnlyByLegacyTerminal() {
        let roomyHub = AgentEventHub(maxBufferedEvents: 10, maxSeenEventIDs: 100)
        roomyHub.publish(makeAssistantEvent(id: "live-1000", seq: 1000))
        roomyHub.replaceHistoricalEvents(sessionID: "session",
                                         events: [legacyPrompt(id: "opener-L", seq: 10, promptID: "p1"),
                                                  legacyTerminal(id: "terminal-L", seq: 20, promptID: "p1")],
                                         anchorSeq: 30)
        XCTAssertNil(roomyHub.activeInteractivePrompt(workspaceID: "workspace", sessionID: "session", promptID: "p1"),
                     "the legacy terminal closes the legacy opener")

        // Trim the matching legacy terminal: the pair is atomic.
        let hub = AgentEventHub(maxBufferedEvents: 1, maxSeenEventIDs: 100)
        hub.publish(makeAssistantEvent(id: "live-1000", seq: 1000))
        hub.replaceHistoricalEvents(sessionID: "session",
                                    events: [legacyPrompt(id: "opener-L", seq: 10, promptID: "p1"),
                                             legacyTerminal(id: "terminal-L", seq: 20, promptID: "p1")],
                                    anchorSeq: 12)
        XCTAssertNil(hub.activeInteractivePrompt(workspaceID: "workspace", sessionID: "session", promptID: "p1"),
                     "a resolved legacy lifecycle must not revive when its terminal is trimmed")
    }

    // R13 B3D1: a capability-bound TOKENLESS opener is closed by NO live
    // terminal — before and after any trim it stays active.
    func testCapabilityTokenlessOpenerStaysActiveThroughTrim() {
        let hub = AgentEventHub(maxBufferedEvents: 1, maxSeenEventIDs: 100)
        hub.publish(makeAssistantEvent(id: "live-1000", seq: 1000))
        hub.replaceHistoricalEvents(sessionID: "session",
                                    events: [makePromptEvent(id: "opener-cap", seq: 10, promptID: "p1", token: nil),
                                             legacyTerminal(id: "terminal-L", seq: 20, promptID: "p1"),
                                             makeResolvedEvent(id: "terminal-codex", seq: 25, promptID: "p1", token: "token-X")],
                                    anchorSeq: 12)
        let stored = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 100).events.map(\.eventID)
        XCTAssertTrue(stored.contains("opener-cap"),
                      "no live terminal can prove a capability-bound tokenless opener closed, got \(stored)")
        XCTAssertNotNil(hub.activeInteractivePrompt(workspaceID: "workspace", sessionID: "session", promptID: "p1"))
    }

    // R13 B3D1: the latest-resolved lookup does not treat a nil token as
    // legacy when the opener is capability-bound.
    func testLatestResolvedLookupFailsClosedForCapabilityTokenlessOpener() {
        let hub = AgentEventHub()
        hub.publish(makeAssistantEvent(id: "live-1000", seq: 1000))
        hub.replaceHistoricalEvents(sessionID: "session",
                                    events: [legacyTerminal(id: "terminal-L", seq: 20, promptID: "p1")],
                                    anchorSeq: nil)
        XCTAssertNotNil(hub.latestInteractivePromptResolvedEvent(workspaceID: "workspace",
                                                                 sessionID: "session",
                                                                 promptID: "p1",
                                                                 lifecycleToken: nil,
                                                                 openerRequiresCapability: false),
                        "a genuine legacy lookup is answered by the legacy terminal")
        XCTAssertNil(hub.latestInteractivePromptResolvedEvent(workspaceID: "workspace",
                                                              sessionID: "session",
                                                              promptID: "p1",
                                                              lifecycleToken: nil,
                                                              openerRequiresCapability: true),
                     "a capability-bound tokenless lookup is never answered by a live terminal")
    }

    private func contextEvent(id: String, seq: Int, generated: String) -> AgentEvent {
        AgentEvent(eventID: id,
                   seq: seq,
                   vendor: "claude",
                   workspaceID: "workspace",
                   sessionID: "session",
                   timestamp: "2026-01-01T00:00:00Z",
                   type: generated == "claude_context" ? .assistantMessage : .userMessage,
                   role: generated == "claude_context" ? "assistant" : "user",
                   text: "ctx",
                   name: nil,
                   input: nil,
                   output: nil,
                   toolCallID: nil,
                   metadata: ["tidey_generated": generated])
    }

    // R13 B3D5: a summary belongs to the NEAREST preceding unmatched command —
    // summary2 must not be treated as cmd1's closure by the trim.
    func testTrimPairsSummaryWithNearestPrecedingCommand() {
        let hub = AgentEventHub(maxBufferedEvents: 2, maxSeenEventIDs: 100)
        hub.publish(makeAssistantEvent(id: "live-1000", seq: 1000))
        hub.replaceHistoricalEvents(sessionID: "session",
                                    events: [contextEvent(id: "cmd-1", seq: 10, generated: "claude_context_command"),
                                             contextEvent(id: "cmd-2", seq: 20, generated: "claude_context_command"),
                                             contextEvent(id: "summary-2", seq: 30, generated: "claude_context")],
                                    anchorSeq: 22)
        let stored = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 100).events.map(\.eventID)
        XCTAssertTrue(stored.contains("cmd-1"),
                      "cmd1 is an UNMATCHED opener — summary2 is not its closure, got \(stored)")
        XCTAssertFalse(stored.contains("cmd-2") && stored.contains("summary-2") == false,
                       "cmd2 without its summary2 is half a group, got \(stored)")
    }

    // R13 B3 late addendum: the correlation-safe trim uses the EXACT
    // lifecycle identity — a trimmed MISMATCHED terminal (token B) never
    // drops the genuinely active token-A opener.
    func testTrimKeepsTokenBoundOpenerWhenMismatchedTerminalTrimmed() {
        let hub = AgentEventHub(maxBufferedEvents: 1, maxSeenEventIDs: 100)
        hub.publish(makeAssistantEvent(id: "live-1000", seq: 1000))

        hub.replaceHistoricalEvents(sessionID: "session",
                                    events: [makePromptEvent(id: "opener-A", seq: 10, promptID: "p1", token: "token-A"),
                                             makeResolvedEvent(id: "terminal-B", seq: 20, promptID: "p1", token: "token-B")],
                                    anchorSeq: 12)
        let stored = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 100).events.map(\.eventID)
        XCTAssertTrue(stored.contains("opener-A"),
                      "the token-A opener stays: the trimmed token-B terminal is NOT its closure, got \(stored)")
        XCTAssertNotNil(hub.activeInteractivePrompt(workspaceID: "workspace", sessionID: "session", promptID: "p1"),
                        "the real permission prompt must remain visible")
    }

    // R13 B3 late addendum: the MATCHING token-A terminal being trimmed makes
    // the pair atomic — the opener is withdrawn fail closed, never revived.
    func testTrimWithdrawsOpenerWhenMatchingTerminalTrimmed() {
        let hub = AgentEventHub(maxBufferedEvents: 1, maxSeenEventIDs: 100)
        hub.publish(makeAssistantEvent(id: "live-1000", seq: 1000))

        hub.replaceHistoricalEvents(sessionID: "session",
                                    events: [makePromptEvent(id: "opener-A", seq: 10, promptID: "p1", token: "token-A"),
                                             makeResolvedEvent(id: "terminal-A", seq: 20, promptID: "p1", token: "token-A")],
                                    anchorSeq: 12)
        XCTAssertNil(hub.activeInteractivePrompt(workspaceID: "workspace", sessionID: "session", promptID: "p1"),
                     "a resolved lifecycle must not revive when its matching terminal is trimmed")
        let stored = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 100).events.map(\.eventID)
        XCTAssertFalse(stored.contains("opener-A") && stored.contains("terminal-A") == false,
                       "keeping the opener without its matching terminal is half a lifecycle, got \(stored)")
    }

    private func makeSessionEvent(id: String, seq: Int, sessionID: String) -> AgentEvent {
        AgentEvent(eventID: id,
                   seq: seq,
                   vendor: "claude",
                   workspaceID: "workspace",
                   sessionID: sessionID,
                   timestamp: "2026-01-01T00:00:00Z",
                   type: .assistantMessage,
                   role: "assistant",
                   text: id,
                   name: nil,
                   input: nil,
                   output: nil,
                   toolCallID: nil,
                   metadata: nil)
    }

    // R12 B4: the historical replacement is OWNED by the named session — a
    // wrong-session event never enters any state and never leaks to fetches.
    func testHistoricalReplacementRejectsWrongSessionEvents() {
        let hub = AgentEventHub()
        hub.publish(makeSessionEvent(id: "a-live-100", seq: 100, sessionID: "session-A"))
        hub.publish(makeSessionEvent(id: "b-live-100", seq: 100, sessionID: "session-B"))

        hub.replaceHistoricalEvents(sessionID: "session-A",
                                    events: [makeSessionEvent(id: "b-history-10", seq: 10, sessionID: "session-B"),
                                             makeSessionEvent(id: "a-history-10", seq: 10, sessionID: "session-A")],
                                    anchorSeq: nil)

        let fetchA = hub.fetch(workspaceID: "workspace", sessionID: "session-A", limit: 100).events
        XCTAssertFalse(fetchA.contains { $0.eventID == "b-history-10" },
                       "a wrong-session event must never enter the owner's state, got \(fetchA.map(\.eventID))")
        XCTAssertTrue(fetchA.contains { $0.eventID == "a-history-10" },
                      "the owner's own event is stored normally")
        let fetchB = hub.fetch(workspaceID: "workspace", sessionID: "session-B", limit: 100).events
        XCTAssertFalse(fetchB.contains { $0.eventID == "b-history-10" },
                       "the rejected event must not leak into the named session either")
        // Workspace-wide view reads ALL session states directly: the foreign
        // event must not be stored ANYWHERE — this assertion is what a
        // deleted ownership guard cannot hide behind the session-fetch
        // defense.
        let workspaceWide = hub.fetch(workspaceID: "workspace", sessionID: nil, limit: 100).events
        XCTAssertFalse(workspaceWide.contains { $0.eventID == "b-history-10" },
                       "a wrong-session replacement event must not be stored in ANY state, got \(workspaceWide.map(\.eventID))")
    }

    // R13 B4: the session-fetch defense is killable on its own — a corrupt
    // state (foreign event already inside A's stored state, injected via the
    // minimal test seam) must still never leave a REAL session fetch.
    func testSessionFetchDefenseFiltersCorruptForeignState() {
        let hub = AgentEventHub()
        hub.publish(makeSessionEvent(id: "a-live-100", seq: 100, sessionID: "session-A"))
        hub.injectCorruptStoredHistoricalEventForTesting(sessionID: "session-A",
                                                         event: makeSessionEvent(id: "b-corrupt-10", seq: 10, sessionID: "session-B"))
        // Precondition: the corrupt state really exists — the raw
        // workspace-wide view (which reads stored state directly) sees it.
        let rawView = hub.fetch(workspaceID: "workspace", sessionID: nil, limit: 100).events
        XCTAssertTrue(rawView.contains { $0.eventID == "b-corrupt-10" },
                      "precondition: the foreign event was injected into A's stored state, got \(rawView.map(\.eventID))")

        let fetchA = hub.fetch(workspaceID: "workspace", sessionID: "session-A", limit: 100).events
        XCTAssertFalse(fetchA.contains { $0.eventID == "b-corrupt-10" },
                       "the session fetch defense must filter a foreign event out of a corrupt state, got \(fetchA.map(\.eventID))")
        XCTAssertTrue(fetchA.contains { $0.eventID == "a-live-100" })
    }

    // R12 B4: replacement leaves the live contract untouched — buffered
    // events, the stored high-water and the next live acceptance semantics
    // are exactly what they were, no subscriber fires, and a client whose
    // after_seq cursor already advanced never sees historical events.
    func testHistoricalReplacementPreservesLiveInvariants() {
        let hub = AgentEventHub()
        hub.publish(makeAssistantEvent(id: "live-100", seq: 100))
        hub.publish(makeAssistantEvent(id: "live-200", seq: 200))
        var subscriberCalls = 0
        let (subscriptionID, _) = hub.subscribe(workspaceID: "workspace", sessionID: "session", sinceSeq: Int.max) { _ in
            subscriberCalls += 1
        }
        defer { hub.unsubscribe(subscriptionID) }
        let liveBefore = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 100, afterSeq: 0).events
            .filter { $0.eventID.hasPrefix("live-") }

        hub.replaceHistoricalEvents(sessionID: "session",
                                    events: [makeAssistantEvent(id: "history-10", seq: 10),
                                             makeAssistantEvent(id: "history-20", seq: 20)],
                                    anchorSeq: 100)
        hub.drainDeliveriesForTesting()

        // Live buffered events unchanged.
        let liveAfter = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 100, afterSeq: 0).events
            .filter { $0.eventID.hasPrefix("live-") }
        XCTAssertEqual(liveAfter.map(\.eventID), liveBefore.map(\.eventID))
        // No subscriber invocation from a replacement.
        XCTAssertEqual(subscriberCalls, 0, "a historical replacement must not trigger subscribers")
        // High-water / next-acceptance semantics unchanged: a live event at
        // or below the high-water is still rejected as historical would be,
        // and a genuinely newer one still lands.
        hub.publish(makeAssistantEvent(id: "live-300", seq: 300))
        hub.drainDeliveriesForTesting()
        XCTAssertEqual(subscriberCalls, 1, "the next LIVE publish still reaches the subscriber")
        let stored = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 100).events.map(\.eventID)
        XCTAssertTrue(stored.contains("live-300"))
        // An advanced after_seq cursor never sees the (older) historical.
        let catchUp = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 100, afterSeq: 200).events
        XCTAssertFalse(catchUp.contains { $0.eventID.hasPrefix("history-") },
                       "historical events must not reappear behind an advanced after_seq cursor, got \(catchUp.map(\.eventID))")
    }

    // R12 B4 addendum: the stored high-water SURVIVES a historical
    // replacement — an unseen live event at/below the pre-replacement
    // high-water published afterwards is rebased to exactly the next
    // sequence, never accepted at its stale position.
    func testHistoricalReplacementPreservesStoredSeqHighWater() {
        let hub = AgentEventHub()
        hub.publish(makeAssistantEvent(id: "live-100", seq: 100))
        hub.publish(makeAssistantEvent(id: "live-300", seq: 300))

        hub.replaceHistoricalEvents(sessionID: "session",
                                    events: [makeAssistantEvent(id: "history-10", seq: 10)],
                                    anchorSeq: 100)

        // Unseen live event at/below the pre-replacement high-water: it must
        // be rebased to EXACTLY highWater + 1 (301), proving the high-water
        // was neither cleared nor lowered by the replacement.
        hub.publish(makeAssistantEvent(id: "live-late-150", seq: 150))
        let stored = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 100).events
        let late = stored.first { $0.eventID == "live-late-150" }
        XCTAssertEqual(late?.seq, 301,
                       "the late live event must rebase to exactly the next sequence after the surviving high-water, got \(String(describing: late?.seq)) stored=\(stored.map { ($0.eventID, $0.seq) })")
    }

    // R12 B4 addendum: the synthetic-seq reservation SURVIVES a historical
    // replacement — reservations continue exactly monotonically.
    func testHistoricalReplacementPreservesSyntheticSeqReservation() {
        let hub = AgentEventHub()
        hub.publish(makeAssistantEvent(id: "live-100", seq: 100))
        let before = hub.nextSyntheticSeq(sessionID: "session")
        XCTAssertEqual(before, 101)

        hub.replaceHistoricalEvents(sessionID: "session",
                                    events: [makeAssistantEvent(id: "history-10", seq: 10)],
                                    anchorSeq: 100)

        let after = hub.nextSyntheticSeq(sessionID: "session")
        XCTAssertEqual(after, before + 1,
                       "the reservation must continue exactly monotonically across a replacement, got \(after) after \(before)")
    }

    // MARK: Historical storage integration baseline

    func testHistoricalBackfillKeepsOriginalCursorPositionAndNeverLiveDelivers() {
        let hub = AgentEventHub()
        var deliveredIDs = [String]()
        let (subscriptionID, _) = hub.subscribe(workspaceID: "workspace", sessionID: "session") { envelope in
            deliveredIDs.append(envelope.event.eventID)
        }
        defer { hub.unsubscribe(subscriptionID) }

        hub.publish(makeAssistantEvent(id: "live-100", seq: 100))
        hub.publish(makeAssistantEvent(id: "history-50", seq: 50),
                    storage: .historicalBackfill)
        hub.drainDeliveriesForTesting()

        let older = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 10, beforeSeq: 100)
        XCTAssertEqual(older.events.map(\.eventID), ["history-50"])
        XCTAssertEqual(older.events.map(\.seq), [50])
        XCTAssertTrue(hub.fetch(workspaceID: "workspace",
                                sessionID: "session",
                                limit: 10,
                                afterSeq: 100).events.isEmpty)
        XCTAssertEqual(deliveredIDs, ["live-100"])
        XCTAssertEqual(hub.nextSyntheticSeq(sessionID: "session"), 101)
    }

    func testHistoricalBackfillHasIndependentBoundAndDoesNotEvictLiveWindow() {
        let hub = AgentEventHub(maxBufferedEvents: 3, maxSeenEventIDs: 100)
        for seq in 100...102 {
            hub.publish(makeAssistantEvent(id: "live-\(seq)", seq: seq))
        }
        for seq in [10, 20, 30, 40] {
            hub.publish(makeAssistantEvent(id: "history-\(seq)", seq: seq),
                        storage: .historicalBackfill)
        }

        let live = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 10, afterSeq: 99)
        XCTAssertEqual(live.events.map(\.eventID), ["live-100", "live-101", "live-102"])
        let history = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 10, beforeSeq: 100)
        XCTAssertEqual(history.events.map(\.eventID), ["history-20", "history-30", "history-40"])
    }

    func testHistoricalBackfillAtOrAboveHighWaterIsRejectedWithoutMovingCursor() {
        let hub = AgentEventHub()
        hub.publish(makeAssistantEvent(id: "live-100", seq: 100))
        hub.publish(makeAssistantEvent(id: "history-100", seq: 100),
                    storage: .historicalBackfill)
        hub.publish(makeAssistantEvent(id: "history-150", seq: 150),
                    storage: .historicalBackfill)

        XCTAssertEqual(hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 10)
            .events.map(\.eventID), ["live-100"])
        XCTAssertEqual(hub.nextSyntheticSeq(sessionID: "session"), 101)

        hub.publish(makeSessionEvent(id: "unanchored-history",
                                     seq: 10,
                                     sessionID: "unanchored"),
                    storage: .historicalBackfill)
        XCTAssertTrue(hub.fetch(workspaceID: "workspace", sessionID: "unanchored", limit: 10).events.isEmpty)
    }

    func testHistoricalReplacementRetractsStaleEventsAndResetsHistoricalIdentity() {
        let hub = AgentEventHub()
        hub.publish(makeAssistantEvent(id: "live-100", seq: 100))

        hub.replaceHistoricalEvents(sessionID: "session",
                                    events: [makeAssistantEvent(id: "history-10", seq: 10),
                                             makeAssistantEvent(id: "history-20", seq: 20),
                                             makeAssistantEvent(id: "history-20", seq: 20)])
        XCTAssertEqual(hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 10, beforeSeq: 100)
            .events.map(\.eventID), ["history-10", "history-20"])

        hub.replaceHistoricalEvents(sessionID: "session",
                                    events: [makeAssistantEvent(id: "history-20", seq: 20),
                                             makeAssistantEvent(id: "history-30", seq: 30)])
        XCTAssertEqual(hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 10, beforeSeq: 100)
            .events.map(\.eventID), ["history-20", "history-30"])

        hub.replaceHistoricalEvents(sessionID: "session", events: [])
        hub.replaceHistoricalEvents(sessionID: "session",
                                    events: [makeAssistantEvent(id: "history-10", seq: 10)])
        XCTAssertEqual(hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 10, beforeSeq: 100)
            .events.map(\.eventID), ["history-10"])
    }

    func testHistoricalReplacementBoundKeepsEventsAdjacentToAnchor() {
        let hub = AgentEventHub(maxBufferedEvents: 3, maxSeenEventIDs: 100)
        hub.publish(makeAssistantEvent(id: "live-100", seq: 100))
        let history = [10, 20, 30, 40, 50].map {
            makeAssistantEvent(id: "history-\($0)", seq: $0)
        }

        hub.replaceHistoricalEvents(sessionID: "session", events: history, anchorSeq: 45)
        XCTAssertEqual(hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 10, beforeSeq: 100)
            .events.map(\.seq), [20, 30, 40])

        hub.replaceHistoricalEvents(sessionID: "session", events: history)
        XCTAssertEqual(hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 10, beforeSeq: 100)
            .events.map(\.seq), [30, 40, 50])
    }

    func testHistoricalReplacementRejectsLiveIdentityAndNonHistoricalSequences() {
        let hub = AgentEventHub()
        hub.publish(makeAssistantEvent(id: "live-100", seq: 100))

        hub.replaceHistoricalEvents(sessionID: "session",
                                    events: [makeAssistantEvent(id: "live-100", seq: 10),
                                             makeAssistantEvent(id: "history-100", seq: 100),
                                             makeAssistantEvent(id: "history-150", seq: 150)])

        XCTAssertEqual(hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 10)
            .events.map(\.eventID), ["live-100"])
        XCTAssertEqual(hub.nextSyntheticSeq(sessionID: "session"), 101)
    }

    func testSessionFetchFiltersCorruptHistoricalEventOwnedByAnotherSession() {
        let hub = AgentEventHub()
        hub.publish(makeSessionEvent(id: "a-live", seq: 100, sessionID: "session-A"))
        hub.injectCorruptStoredHistoricalEventForTesting(
            sessionID: "session-A",
            event: makeSessionEvent(id: "b-corrupt", seq: 10, sessionID: "session-B")
        )

        XCTAssertTrue(hub.fetch(workspaceID: "workspace", limit: 10)
            .events.contains { $0.eventID == "b-corrupt" })
        let fetchA = hub.fetch(workspaceID: "workspace", sessionID: "session-A", limit: 10).events
        XCTAssertEqual(fetchA.map(\.eventID), ["a-live"])
    }

    func testHistoricalReplacementPreservesLiveHighWaterAndDoesNotDeliver() {
        let hub = AgentEventHub()
        hub.publish(makeAssistantEvent(id: "live-100", seq: 100))
        var delivered = [AgentEvent]()
        let (subscriptionID, _) = hub.subscribe(workspaceID: "workspace",
                                                sessionID: "session",
                                                sinceSeq: Int.max) { envelope in
            delivered.append(envelope.event)
        }
        defer { hub.unsubscribe(subscriptionID) }

        hub.replaceHistoricalEvents(sessionID: "session",
                                    events: [makeAssistantEvent(id: "history-10", seq: 10),
                                             makeAssistantEvent(id: "history-20", seq: 20)])
        hub.drainDeliveriesForTesting()
        XCTAssertTrue(delivered.isEmpty)

        hub.publish(makeAssistantEvent(id: "late-live", seq: 50))
        XCTAssertEqual(delivered.map(\.eventID), ["late-live"])
        XCTAssertEqual(delivered.map(\.seq), [101])
        XCTAssertEqual(hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 10, afterSeq: 100)
            .events.map(\.eventID), ["late-live"])
    }

    func testHistoricalReplacementPreservesSyntheticSequenceReservation() {
        let hub = AgentEventHub()
        hub.publish(makeAssistantEvent(id: "live-100", seq: 100))
        let before = hub.nextSyntheticSeq(sessionID: "session")

        hub.replaceHistoricalEvents(sessionID: "session",
                                    events: [makeAssistantEvent(id: "history-10", seq: 10)])

        XCTAssertEqual(hub.nextSyntheticSeq(sessionID: "session"), before + 1)
    }

    func testHistoricalStorageMigratesAndReplaysWithCurrentBinding() throws {
        let hub = AgentEventHub()
        hub.publish(makeAssistantEvent(id: "live-100", seq: 100))
        hub.publish(makeAssistantEvent(id: "history-50", seq: 50),
                    storage: .historicalBackfill)

        XCTAssertEqual(hub.migrateSession(sessionID: "session",
                                          toWorkspaceID: "current-workspace",
                                          panelID: "current-panel"), 2)
        XCTAssertEqual(hub.oldestBufferedSeq(sessionID: "session"), 50)
        let snapshot = try XCTUnwrap(hub.debugSnapshots().first)
        XCTAssertEqual(snapshot.bufferedEventCount, 2)
        XCTAssertEqual(snapshot.oldestSeq, 50)
        XCTAssertEqual(snapshot.newestSeq, 100)

        let fetched = hub.fetch(workspaceID: "current-workspace", sessionID: "session", limit: 10).events
        XCTAssertEqual(fetched.map(\.eventID), ["history-50", "live-100"])
        XCTAssertEqual(Set(fetched.map(\.workspaceID)), ["current-workspace"])
        XCTAssertEqual(Set(fetched.compactMap { $0.metadata?["panel_id"] }), ["current-panel"])

        let (_, replay) = hub.subscribe(workspaceID: "current-workspace",
                                        sessionID: "session",
                                        sinceSeq: nil) { _ in }
        XCTAssertEqual(replay.map(\.event.eventID), ["history-50", "live-100"])
    }

    func testTokenBoundPromptOnlyClosesOnMatchingLifecycleTerminal() {
        let hub = AgentEventHub()
        hub.publish(makePromptEvent(id: "opener-A", seq: 10, promptID: "p1", token: "token-A"))
        hub.publish(makeResolvedEvent(id: "terminal-B", seq: 20, promptID: "p1", token: "token-B"))

        XCTAssertNotNil(hub.activeInteractivePrompt(workspaceID: "workspace",
                                                    sessionID: "session",
                                                    promptID: "p1"))

        hub.publish(makeResolvedEvent(id: "terminal-A", seq: 30, promptID: "p1", token: "token-A"))
        XCTAssertNil(hub.activeInteractivePrompt(workspaceID: "workspace",
                                                 sessionID: "session",
                                                 promptID: "p1"))
    }

    func testLegacyPromptIgnoresCapabilityTerminalAndClosesOnLegacyTerminal() {
        let hub = AgentEventHub()
        hub.publish(makePromptEvent(id: "legacy-opener", seq: 10, promptID: "p1", token: nil,
                                    vendor: "claude", source: "claude_ask_user_question"))
        hub.publish(makeResolvedEvent(id: "capability-terminal", seq: 20, promptID: "p1", token: "token-A"))

        XCTAssertNotNil(hub.activeInteractivePrompt(workspaceID: "workspace",
                                                    sessionID: "session",
                                                    promptID: "p1"))

        hub.publish(makeResolvedEvent(id: "legacy-terminal", seq: 30, promptID: "p1", token: nil,
                                      vendor: "claude", source: "claude_ask_user_question"))
        XCTAssertNil(hub.activeInteractivePrompt(workspaceID: "workspace",
                                                 sessionID: "session",
                                                 promptID: "p1"))
    }

    func testCapabilityTokenlessPromptFailsClosedAgainstLiveTerminals() {
        let hub = AgentEventHub()
        hub.publish(makePromptEvent(id: "tokenless-opener", seq: 10, promptID: "p1", token: nil))
        hub.publish(makeResolvedEvent(id: "legacy-terminal", seq: 20, promptID: "p1", token: nil,
                                      vendor: "claude", source: "claude_ask_user_question"))
        hub.publish(makeResolvedEvent(id: "capability-terminal", seq: 30, promptID: "p1", token: "token-X"))

        XCTAssertNotNil(hub.activeInteractivePrompt(workspaceID: "workspace",
                                                    sessionID: "session",
                                                    promptID: "p1"))
    }

    func testLatestResolvedLookupMatchesExactCapabilityLifecycleToken() {
        let hub = AgentEventHub()
        hub.publish(makeResolvedEvent(id: "terminal-A", seq: 10, promptID: "p1", token: "token-A"))
        hub.publish(makeResolvedEvent(id: "terminal-B", seq: 20, promptID: "p1", token: "token-B"))

        XCTAssertEqual(hub.latestInteractivePromptResolvedEvent(workspaceID: "workspace",
                                                                sessionID: "session",
                                                                promptID: "p1",
                                                                lifecycleToken: "token-A",
                                                                openerRequiresCapability: true)?.eventID,
                       "terminal-A")
        XCTAssertNil(hub.latestInteractivePromptResolvedEvent(workspaceID: "workspace",
                                                              sessionID: "session",
                                                              promptID: "p1",
                                                              lifecycleToken: "token-C",
                                                              openerRequiresCapability: true))
    }

    func testHistoricalTrimKeepsOpenerWhenTrimmedTerminalTokenDoesNotMatch() {
        let hub = AgentEventHub(maxBufferedEvents: 1, maxSeenEventIDs: 100)
        hub.publish(makeAssistantEvent(id: "live-1000", seq: 1000))

        hub.replaceHistoricalEvents(sessionID: "session",
                                    events: [makePromptEvent(id: "opener-A", seq: 10, promptID: "p1", token: "token-A"),
                                             makeResolvedEvent(id: "terminal-B", seq: 20, promptID: "p1", token: "token-B")],
                                    anchorSeq: 12)

        XCTAssertEqual(hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 100, beforeSeq: 1000)
            .events.map(\.eventID), ["opener-A"])
    }

    func testHistoricalTrimDropsOpenerWhenMatchingTerminalWasTrimmed() {
        let hub = AgentEventHub(maxBufferedEvents: 1, maxSeenEventIDs: 100)
        hub.publish(makeAssistantEvent(id: "live-1000", seq: 1000))

        hub.replaceHistoricalEvents(sessionID: "session",
                                    events: [makePromptEvent(id: "opener-A", seq: 10, promptID: "p1", token: "token-A"),
                                             makeResolvedEvent(id: "terminal-A", seq: 20, promptID: "p1", token: "token-A")],
                                    anchorSeq: 12)

        XCTAssertTrue(hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 100, beforeSeq: 1000)
            .events.isEmpty,
                      "a resolved opener and its trimmed terminal are removed atomically")
    }

    func testHistoricalTrimPairsContextSummaryWithNearestPrecedingCommand() {
        let hub = AgentEventHub(maxBufferedEvents: 2, maxSeenEventIDs: 100)
        hub.publish(makeAssistantEvent(id: "live-1000", seq: 1000))
        hub.replaceHistoricalEvents(sessionID: "session",
                                    events: [contextEvent(id: "command-1", seq: 10, generated: "claude_context_command"),
                                             contextEvent(id: "command-2", seq: 20, generated: "claude_context_command"),
                                             contextEvent(id: "summary-2", seq: 30, generated: "claude_context")],
                                    anchorSeq: 22)

        let stored = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 100, beforeSeq: 1000)
            .events.map(\.eventID)
        XCTAssertTrue(stored.contains("command-1"),
                      "the second command's summary must not close the first command")
        XCTAssertFalse(stored.contains("command-2") && stored.contains("summary-2") == false,
                       "a context command and its summary must not be trimmed into a partial group")
    }

    private func makeAssistantEvent(id: String, seq: Int, text: String? = nil) -> AgentEvent {
        AgentEvent(eventID: id,
                   seq: seq,
                   vendor: "claude",
                   workspaceID: "workspace",
                   sessionID: "session",
                   timestamp: String(format: "2026-01-01T00:00:%02dZ", seq),
                   type: .assistantMessage,
                   role: "assistant",
                   text: text ?? id,
                   name: nil,
                   input: nil,
                   output: nil,
                   toolCallID: nil,
                   metadata: nil)
    }

    private func makeToolResultEvent(id: String, seq: Int, output: String) -> AgentEvent {
        AgentEvent(eventID: id,
                   seq: seq,
                   vendor: "claude",
                   workspaceID: "workspace",
                   sessionID: "session",
                   timestamp: String(format: "2026-01-01T00:00:%02dZ", seq),
                   type: .toolResult,
                   role: nil,
                   text: nil,
                   name: nil,
                   input: nil,
                   output: output,
                   toolCallID: "tool-call-1",
                   metadata: nil)
    }

    private func estimatedBytes(for event: AgentEvent) -> Int {
        let encoder = JSONEncoder()
        return try! encoder.encode(event).count
    }
}
