import XCTest
@testable import RemoteBridge

final class BridgeAgentEventFetchFlowTests: XCTestCase {
    func testBeforeCursorBackfillsRequestedAnchorEvenWhenDeepCacheHasMore() {
        let hub = AgentEventHub(maxBufferedEvents: 20, maxSeenEventIDs: 100)
        for seq in 100...105 {
            hub.publish(makeEvent(seq: seq, text: "live-\(seq)"))
        }
        hub.replaceHistoricalEvents(sessionID: "session",
                                    events: (1...10).map { makeEvent(seq: $0, text: "deep-\($0)") })

        let cached = hub.fetch(workspaceID: "workspace",
                               sessionID: "session",
                               limit: 3,
                               beforeSeq: 100)
        XCTAssertTrue(cached.hasMore)
        XCTAssertEqual(cached.events.compactMap(\.text), ["deep-8", "deep-9", "deep-10"])

        var backfillCalls = [(beforeSeq: Int, limit: Int)]()
        let output = BridgeAgentEventFetchFlow.run(eventHub: hub,
                                                   workspaceID: "workspace",
                                                   sessionID: "session",
                                                   limit: 3,
                                                   beforeSeq: 100,
                                                   afterSeq: nil) { _, beforeSeq, limit in
            backfillCalls.append((beforeSeq, limit))
            hub.replaceHistoricalEvents(sessionID: "session",
                                        events: (97...99).map { self.makeEvent(seq: $0, text: "near-\($0)") },
                                        anchorSeq: beforeSeq)
            return true
        }

        XCTAssertEqual(backfillCalls.count, 1)
        XCTAssertEqual(backfillCalls.first?.beforeSeq, 100)
        XCTAssertGreaterThanOrEqual(backfillCalls.first?.limit ?? 0, 3)
        XCTAssertTrue(output.didBackfill)
        XCTAssertEqual(output.fetchResult.events.compactMap(\.text), ["near-97", "near-98", "near-99"])
    }

    func testBeforeCursorRefetchesWhenBackfillInvalidatesOldSourceWithoutLoading() {
        let hub = AgentEventHub()
        for seq in 100...105 {
            hub.publish(makeEvent(seq: seq, text: "old-\(seq)"))
        }

        let output = BridgeAgentEventFetchFlow.run(eventHub: hub,
                                                   workspaceID: "workspace",
                                                   sessionID: "session",
                                                   limit: 3,
                                                   beforeSeq: 106,
                                                   afterSeq: nil) { sessionID, _, _ in
            hub.beginNewSourceEpoch(sessionID: sessionID)
            return false
        }

        XCTAssertFalse(output.didBackfill)
        XCTAssertTrue(output.fetchResult.events.isEmpty,
                      "a fetch transaction must not return its pre-reset source snapshot")
    }

    func testAfterCursorRefetchesBeforeStoppingWhenBackfillInvalidatesOldSource() {
        let hub = AgentEventHub()
        for seq in 100...105 {
            hub.publish(makeEvent(seq: seq, text: "old-\(seq)"))
        }

        let output = BridgeAgentEventFetchFlow.run(eventHub: hub,
                                                   workspaceID: "workspace",
                                                   sessionID: "session",
                                                   limit: 3,
                                                   beforeSeq: nil,
                                                   afterSeq: 1) { sessionID, _, _ in
            hub.beginNewSourceEpoch(sessionID: sessionID)
            return false
        }

        XCTAssertFalse(output.didBackfill)
        XCTAssertTrue(output.fetchResult.events.isEmpty,
                      "the final result must be refetched after a failed coverage attempt")
    }

    func testAfterCursorStopsWhenBackfillDoesNotAdvanceCoverage() {
        let hub = AgentEventHub()
        for seq in 100...105 {
            hub.publish(makeEvent(seq: seq, text: "live-\(seq)"))
        }
        var backfillCalls = 0

        let output = BridgeAgentEventFetchFlow.run(eventHub: hub,
                                                   workspaceID: "workspace",
                                                   sessionID: "session",
                                                   limit: 3,
                                                   beforeSeq: nil,
                                                   afterSeq: 1) { _, _, _ in
            backfillCalls += 1
            return backfillCalls < 3
        }

        XCTAssertEqual(backfillCalls, 1,
                       "a successful read that publishes no older event cannot justify retrying the same anchor")
        XCTAssertTrue(output.didBackfill)
    }

    func testConcurrentSameSessionHistoryRequestsReturnTheirOwnPages() {
        let hub = AgentEventHub()
        hub.publish(makeEvent(seq: 100, text: "live"))
        let firstInstalled = DispatchSemaphore(value: 0)
        let releaseFirst = DispatchSemaphore(value: 0)
        let firstDone = expectation(description: "first request completed")
        let secondDone = expectation(description: "second request completed")
        let contention = expectation(description: "second request waited at the session gate")
        hub.historicalRequestContentionHookForTesting = { sessionID in
            if sessionID == "session" {
                contention.fulfill()
            }
        }
        let outputLock = NSLock()
        var firstOutput: BridgeAgentEventFetchFlow.Output?
        var secondOutput: BridgeAgentEventFetchFlow.Output?

        DispatchQueue.global(qos: .userInitiated).async {
            let output = BridgeAgentEventFetchFlow.run(eventHub: hub,
                                                       workspaceID: "workspace",
                                                       sessionID: "session",
                                                       limit: 3,
                                                       beforeSeq: 100,
                                                       afterSeq: nil) { _, beforeSeq, _ in
                hub.replaceHistoricalEvents(
                    sessionID: "session",
                    events: (97...99).map { self.makeEvent(seq: $0, text: "first-\($0)") },
                    anchorSeq: beforeSeq)
                firstInstalled.signal()
                _ = releaseFirst.wait(timeout: .now() + 5.0)
                return true
            }
            outputLock.lock()
            firstOutput = output
            outputLock.unlock()
            firstDone.fulfill()
        }
        XCTAssertEqual(firstInstalled.wait(timeout: .now() + 2.0), .success)

        DispatchQueue.global(qos: .userInitiated).async {
            let output = BridgeAgentEventFetchFlow.run(eventHub: hub,
                                                       workspaceID: "workspace",
                                                       sessionID: "session",
                                                       limit: 3,
                                                       beforeSeq: 50,
                                                       afterSeq: nil) { _, beforeSeq, _ in
                hub.replaceHistoricalEvents(
                    sessionID: "session",
                    events: (47...49).map { self.makeEvent(seq: $0, text: "second-\($0)") },
                    anchorSeq: beforeSeq)
                return true
            }
            outputLock.lock()
            secondOutput = output
            outputLock.unlock()
            secondDone.fulfill()
        }

        let contentionResult = XCTWaiter.wait(for: [contention], timeout: 1.0)
        releaseFirst.signal()
        wait(for: [firstDone, secondDone], timeout: 5.0)
        XCTAssertEqual(contentionResult, .completed,
                       "same-session request B must wait until A finishes its final fetch")
        outputLock.lock()
        let firstTexts = firstOutput?.fetchResult.events.compactMap(\.text)
        let secondTexts = secondOutput?.fetchResult.events.compactMap(\.text)
        outputLock.unlock()
        XCTAssertEqual(firstTexts, ["first-97", "first-98", "first-99"])
        XCTAssertEqual(secondTexts, ["second-47", "second-48", "second-49"])
    }

    func testHistoryRequestTransactionDoesNotBlockDifferentSessions() {
        let hub = AgentEventHub()
        hub.publish(makeEvent(seq: 100,
                              text: "live-a",
                              workspaceID: "workspace-a",
                              sessionID: "session-a"))
        hub.publish(makeEvent(seq: 200,
                              text: "live-b",
                              workspaceID: "workspace-b",
                              sessionID: "session-b"))
        let firstEntered = DispatchSemaphore(value: 0)
        let releaseFirst = DispatchSemaphore(value: 0)
        let firstDone = expectation(description: "session A completed")
        let secondDone = expectation(description: "session B completed without waiting for A")
        let outputLock = NSLock()
        var secondOutput: BridgeAgentEventFetchFlow.Output?

        DispatchQueue.global(qos: .userInitiated).async {
            _ = BridgeAgentEventFetchFlow.run(eventHub: hub,
                                              workspaceID: "workspace-a",
                                              sessionID: "session-a",
                                              limit: 3,
                                              beforeSeq: 100,
                                              afterSeq: nil) { _, beforeSeq, _ in
                hub.replaceHistoricalEvents(
                    sessionID: "session-a",
                    events: (97...99).map {
                        self.makeEvent(seq: $0,
                                       text: "a-\($0)",
                                       workspaceID: "workspace-a",
                                       sessionID: "session-a")
                    },
                    anchorSeq: beforeSeq)
                firstEntered.signal()
                _ = releaseFirst.wait(timeout: .now() + 5.0)
                return true
            }
            firstDone.fulfill()
        }
        XCTAssertEqual(firstEntered.wait(timeout: .now() + 2.0), .success)

        DispatchQueue.global(qos: .userInitiated).async {
            let output = BridgeAgentEventFetchFlow.run(eventHub: hub,
                                                       workspaceID: "workspace-b",
                                                       sessionID: "session-b",
                                                       limit: 3,
                                                       beforeSeq: 200,
                                                       afterSeq: nil) { _, beforeSeq, _ in
                hub.replaceHistoricalEvents(
                    sessionID: "session-b",
                    events: (197...199).map {
                        self.makeEvent(seq: $0,
                                       text: "b-\($0)",
                                       workspaceID: "workspace-b",
                                       sessionID: "session-b")
                    },
                    anchorSeq: beforeSeq)
                return true
            }
            outputLock.lock()
            secondOutput = output
            outputLock.unlock()
            secondDone.fulfill()
        }

        let secondResult = XCTWaiter.wait(for: [secondDone], timeout: 1.0)
        releaseFirst.signal()
        wait(for: [firstDone], timeout: 5.0)
        XCTAssertEqual(secondResult, .completed,
                       "a history request for session B must run while session A is blocked")
        outputLock.lock()
        let secondTexts = secondOutput?.fetchResult.events.compactMap(\.text)
        outputLock.unlock()
        XCTAssertEqual(secondTexts, ["b-197", "b-198", "b-199"])
    }

    private func makeEvent(seq: Int,
                           text: String,
                           workspaceID: String = "workspace",
                           sessionID: String = "session") -> AgentEvent {
        AgentEvent(eventID: "event-\(seq)",
                   seq: seq,
                   vendor: "codex",
                   workspaceID: workspaceID,
                   sessionID: sessionID,
                   timestamp: "2026-07-22T12:00:00Z",
                   type: .assistantMessage,
                   role: "assistant",
                   text: text,
                   name: nil,
                   input: nil,
                   output: nil,
                   toolCallID: nil,
                   metadata: nil)
    }
}
