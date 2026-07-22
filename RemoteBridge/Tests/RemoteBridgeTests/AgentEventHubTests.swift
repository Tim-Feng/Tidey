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
        let hub = AgentEventHub()
        for seq in [10, 12, 11] {
            hub.publish(makeAssistantEvent(id: "assistant-\(seq)", seq: seq))
        }

        let result = hub.fetch(workspaceID: "workspace",
                               sessionID: "session",
                               limit: 10,
                               beforeSeq: nil,
                               afterSeq: 10)

        XCTAssertEqual(result.events.map(\.seq), [11, 12])
        XCTAssertEqual(result.oldestSeq, 11)
        XCTAssertEqual(result.newestSeq, 12)
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

    func testLiveSubscriberDeliveryFollowsStoreOrderAcrossConcurrentPublishers() {
        // Window: publisher LOW has STORED its event but has not returned;
        // publisher HIGH stores next. Delivery must follow the hub's store
        // order, not the publishers' thread scheduling.
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
                       "low must be stored before high publishes")

        hub.publish(makeAssistantEvent(id: "high", seq: 20))
        releaseLow.signal()

        wait(for: [bothDelivered, lowDone], timeout: 2.0)
        orderLock.lock()
        let observed = delivered
        orderLock.unlock()
        XCTAssertEqual(observed, [10, 20],
                       "live delivery must follow the hub's store order, got \(observed)")
    }

    func testUnsubscribeAfterSinkResolutionStillPreventsInvocation() {
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

        hub.unsubscribe(oldID)
        releaseInvoke.signal()
        wait(for: [publishDone], timeout: 2.0)
        hub.drainDeliveriesForTesting()
        XCTAssertEqual(oldSinkCalls, 0,
                       "a sink resolved before unsubscribe returned must still never be invoked")
    }

    func testUnsubscribeWaitsForInFlightSinkOnAnotherThread() {
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
        XCTAssertEqual(cancelWaiting.wait(timeout: .now() + 2.0), .success,
                       "unsubscribe must reach the cancel wait window while the sink is in flight")
        orderLock.lock()
        let midFlight = order
        orderLock.unlock()
        XCTAssertEqual(midFlight, ["cancel-waiting"],
                       "unsubscribe must not return while the sink is still blocked")

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
