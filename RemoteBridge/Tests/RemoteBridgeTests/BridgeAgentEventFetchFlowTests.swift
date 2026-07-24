import XCTest
@testable import RemoteBridge

final class BridgeAgentEventFetchFlowTests: XCTestCase {
    private func unusedAfterStep(_ sessionID: String,
                                 _ beforeSeq: Int,
                                 _ afterSeq: Int,
                                 _ limit: Int) -> AgentAfterCursorBackfillStep {
        XCTFail("the after-cursor step must not run in this scenario")
        return AgentAfterCursorBackfillStep(outcome: .unavailable, nextBeforeSeq: nil, events: [])
    }

    private func unusedBackfill(_ sessionID: String, _ beforeSeq: Int, _ limit: Int) -> Bool {
        XCTFail("the before-cursor backfill must not run in this scenario")
        return false
    }

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
                                                   afterSeq: nil,
                                                   backfill: { _, beforeSeq, limit in
            backfillCalls.append((beforeSeq, limit))
            hub.replaceHistoricalEvents(sessionID: "session",
                                        events: (97...99).map { self.makeEvent(seq: $0, text: "near-\($0)") },
                                        anchorSeq: beforeSeq)
            return true
        },
                                                   afterSeed: { _, _ in .unavailable },
                                                   afterStep: unusedAfterStep)

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
                                                   afterSeq: nil,
                                                   backfill: { sessionID, _, _ in
            hub.beginNewSourceEpoch(sessionID: sessionID)
            return false
        },
                                                   afterSeed: { _, _ in .unavailable },
                                                   afterStep: unusedAfterStep)

        XCTAssertFalse(output.didBackfill)
        XCTAssertTrue(output.fetchResult.events.isEmpty,
                      "a fetch transaction must not return its pre-reset source snapshot")
    }

    func testAfterCursorBackfillsGapAboveCursorDespiteDeepCacheBelow() {
        let hub = AgentEventHub(maxBufferedEvents: 200, maxSeenEventIDs: 500)
        for seq in 100...105 {
            hub.publish(makeEvent(seq: seq, text: "live-\(seq)"))
        }
        // Unrelated deep history BELOW the cursor: its global minimum (1)
        // must not stand in for coverage of the 51...99 gap ABOVE it.
        hub.replaceHistoricalEvents(sessionID: "session",
                                    events: (1...10).map { makeEvent(seq: $0, text: "deep-\($0)") })

        var stepAnchors = [Int]()
        let output = BridgeAgentEventFetchFlow.run(eventHub: hub,
                                                   workspaceID: "workspace",
                                                   sessionID: "session",
                                                   limit: 200,
                                                   beforeSeq: nil,
                                                   afterSeq: 50,
                                                   backfill: unusedBackfill,
                                                   afterSeed: { _, _ in .walkFrom(beforeSeq: 100) },
                                                   afterStep: { _, beforeSeq, _, _ in
            stepAnchors.append(beforeSeq)
            return AgentAfterCursorBackfillStep(outcome: .coveredCursor,
                                                nextBeforeSeq: 51,
                                                events: (51...99).map { self.makeEvent(seq: $0, text: "mid-\($0)") })
        })

        XCTAssertEqual(stepAnchors, [100],
                       "the walk must anchor at the live floor, not the global minimum of a mixed cache")
        XCTAssertTrue(output.didBackfill)
        XCTAssertEqual(output.fetchResult.events.first?.seq, 51,
                       "cursor-adjacent events must not be skipped")
        XCTAssertEqual(output.fetchResult.events.last?.seq, 105)
    }

    func testSparseLiveWindowCursorInsideWindowNeverBackfills() {
        // Sequence numbers derive from byte offsets and are inherently
        // sparse: a retained live window of [100, 10_000] with the cursor
        // at 100 is a NORMAL poll — 10_000 is simply the next record, not
        // evidence that 101...9_999 were lost.
        let hub = AgentEventHub()
        hub.publish(makeEvent(seq: 100, text: "live-100"))
        hub.publish(makeEvent(seq: 10_000, text: "live-10000"))

        let output = BridgeAgentEventFetchFlow.run(eventHub: hub,
                                                   workspaceID: "workspace",
                                                   sessionID: "session",
                                                   limit: 50,
                                                   beforeSeq: nil,
                                                   afterSeq: 100,
                                                   backfill: unusedBackfill,
                                                   afterSeed: { _, _ in .covered },
                                                   afterStep: unusedAfterStep)

        XCTAssertFalse(output.didBackfill)
        XCTAssertEqual(output.fetchResult.events.compactMap(\.text), ["live-10000"])
    }

    func testCoverageLoopAnchorsAtLiveFloorNotUnrelatedHistoricalRun() {
        // An unrelated historical run above the cursor (60...70, left by
        // another client) says nothing about 71...(live floor); the first
        // backfill must anchor at the LIVE floor so its replace establishes
        // an honest frontier.
        let hub = AgentEventHub(maxBufferedEvents: 200, maxSeenEventIDs: 500)
        for seq in 10_000...10_002 {
            hub.publish(makeEvent(seq: seq, text: "live-\(seq)"))
        }
        hub.replaceHistoricalEvents(sessionID: "session",
                                    events: (60...70).map { makeEvent(seq: $0, text: "unrelated-\($0)") })

        var stepAnchors = [Int]()
        let output = BridgeAgentEventFetchFlow.run(eventHub: hub,
                                                   workspaceID: "workspace",
                                                   sessionID: "session",
                                                   limit: 200,
                                                   beforeSeq: nil,
                                                   afterSeq: 50,
                                                   backfill: unusedBackfill,
                                                   afterSeed: { _, _ in .walkFrom(beforeSeq: 10_000) },
                                                   afterStep: { _, beforeSeq, _, _ in
            stepAnchors.append(beforeSeq)
            return AgentAfterCursorBackfillStep(outcome: .coveredCursor,
                                                nextBeforeSeq: 51,
                                                events: (51...99).map { self.makeEvent(seq: $0, text: "mid-\($0)") })
        })

        XCTAssertEqual(stepAnchors.first, 10_000,
                       "the coverage walk must anchor at the live floor, never at an unrelated cached run")
        XCTAssertTrue(output.didBackfill)
        XCTAssertEqual(output.fetchResult.events.first?.seq, 51)
    }

    func testDisjointHistoricalCacheNeverRedirectsAnchors() {
        // Codex sessions merge old cached pages into each replace
        // (mergeHistoricalPage keeps prior lines), so the Hub cache can
        // contain DISJOINT runs: after backfilling 90...99 below the live
        // floor, the replace may also carry an unrelated 60...70 run. The
        // anchor chain must keep walking the raw transcript (100 → 90),
        // never jump to the unrelated run's floor (60) and skip 71...89.
        let hub = AgentEventHub(maxBufferedEvents: 200, maxSeenEventIDs: 500)
        for seq in 100...105 {
            hub.publish(makeEvent(seq: seq, text: "live-\(seq)"))
        }
        hub.replaceHistoricalEvents(sessionID: "session",
                                    events: (60...70).map { makeEvent(seq: $0, text: "unrelated-\($0)") })

        var anchors = [Int]()
        let output = BridgeAgentEventFetchFlow.run(eventHub: hub,
                                                   workspaceID: "workspace",
                                                   sessionID: "session",
                                                   limit: 200,
                                                   beforeSeq: nil,
                                                   afterSeq: 50,
                                                   backfill: unusedBackfill,
                                                   afterSeed: { _, _ in .walkFrom(beforeSeq: 100) },
                                                   afterStep: { _, beforeSeq, _, _ in
            anchors.append(beforeSeq)
            if anchors.count == 1 {
                // Codex-style merged replace pollutes the cache with the
                // retained unrelated run alongside this step's page.
                hub.replaceHistoricalEvents(
                    sessionID: "session",
                    events: (60...70).map { self.makeEvent(seq: $0, text: "unrelated-\($0)") }
                        + (90...99).map { self.makeEvent(seq: $0, text: "page1-\($0)") },
                    anchorSeq: beforeSeq)
                return AgentAfterCursorBackfillStep(outcome: .advanced,
                                                    nextBeforeSeq: 90,
                                                    events: (90...99).map { self.makeEvent(seq: $0, text: "page1-\($0)") })
            }
            hub.replaceHistoricalEvents(
                sessionID: "session",
                events: (51...89).map { self.makeEvent(seq: $0, text: "page2-\($0)") },
                anchorSeq: beforeSeq)
            return AgentAfterCursorBackfillStep(outcome: .coveredCursor,
                                                nextBeforeSeq: 51,
                                                events: (71...89).map { self.makeEvent(seq: $0, text: "page2-\($0)") }
                                                    + (51...59).map { self.makeEvent(seq: $0, text: "page2-\($0)") })
        })

        XCTAssertEqual(anchors, [100, 90],
                       "anchors must follow the raw scan frontier, never a disjoint cached run")
        XCTAssertTrue(output.didBackfill)
        let seqs = output.fetchResult.events.map(\.seq)
        XCTAssertEqual(seqs, Array(51...59) + Array(71...99) + Array(100...105),
                       "the final payload is request-owned + live only; the unrelated cached 60...70 must not leak in")
    }

    func testFinalPayloadOwnsScannedHistoryEvenWhenHubCacheDropsIt() {
        // The Hub keeps a bounded, possibly replaced historical cache. A
        // multi-page coverage walk can scan 90...99 in page one and then
        // REPLACE the cache with page two (51...89). The final response
        // must still contain 90...99 — the request's own scan is the
        // authority for the covered interval, not whatever survived in the
        // cache.
        let hub = AgentEventHub(maxBufferedEvents: 200, maxSeenEventIDs: 500)
        for seq in 100...105 {
            hub.publish(makeEvent(seq: seq, text: "live-\(seq)"))
        }

        var anchors = [Int]()
        let output = BridgeAgentEventFetchFlow.run(eventHub: hub,
                                                   workspaceID: "workspace",
                                                   sessionID: "session",
                                                   limit: 100,
                                                   beforeSeq: nil,
                                                   afterSeq: 50,
                                                   backfill: unusedBackfill,
                                                   afterSeed: { _, _ in .walkFrom(beforeSeq: 100) },
                                                   afterStep: { _, beforeSeq, _, _ in
            anchors.append(beforeSeq)
            if anchors.count == 1 {
                hub.replaceHistoricalEvents(sessionID: "session",
                                            events: (90...99).map { self.makeEvent(seq: $0, text: "page1-\($0)") },
                                            anchorSeq: beforeSeq)
                return AgentAfterCursorBackfillStep(outcome: .advanced,
                                                    nextBeforeSeq: 90,
                                                    events: (90...99).map { self.makeEvent(seq: $0, text: "page1-\($0)") })
            }
            // Page two replaces the cache and page one's events fall out
            // of it — the response must not care.
            hub.replaceHistoricalEvents(sessionID: "session",
                                        events: (51...89).map { self.makeEvent(seq: $0, text: "page2-\($0)") },
                                        anchorSeq: beforeSeq)
            return AgentAfterCursorBackfillStep(outcome: .coveredCursor,
                                                nextBeforeSeq: 51,
                                                events: (51...89).map { self.makeEvent(seq: $0, text: "page2-\($0)") })
        })

        XCTAssertEqual(anchors, [100, 90])
        let seqs = output.fetchResult.events.map(\.seq)
        XCTAssertEqual(seqs, Array(51...105).map { $0 },
                       "the final payload must cover the full scanned interval with no gap")
    }

    func testEventlessStepStillAdvancesCoverage() {
        // A raw page whose records are all filtered (or invalid) still
        // advances the frontier; coverage is judged by the raw scan, not by
        // whether the page produced events.
        let hub = AgentEventHub(maxBufferedEvents: 200, maxSeenEventIDs: 500)
        for seq in 100...105 {
            hub.publish(makeEvent(seq: seq, text: "live-\(seq)"))
        }

        var anchors = [Int]()
        let output = BridgeAgentEventFetchFlow.run(eventHub: hub,
                                                   workspaceID: "workspace",
                                                   sessionID: "session",
                                                   limit: 100,
                                                   beforeSeq: nil,
                                                   afterSeq: 50,
                                                   backfill: unusedBackfill,
                                                   afterSeed: { _, _ in .walkFrom(beforeSeq: 100) },
                                                   afterStep: { _, beforeSeq, _, _ in
            anchors.append(beforeSeq)
            if anchors.count == 1 {
                return AgentAfterCursorBackfillStep(outcome: .advanced, nextBeforeSeq: 90, events: [])
            }
            return AgentAfterCursorBackfillStep(outcome: .coveredCursor,
                                                nextBeforeSeq: 51,
                                                events: (51...89).map { self.makeEvent(seq: $0, text: "page2-\($0)") })
        })

        XCTAssertEqual(anchors, [100, 90])
        XCTAssertEqual(output.fetchResult.events.map(\.seq), Array(51...105).map { $0 })
    }

    func testTinyMaxBytesTrimsPayloadWithoutChangingCoverage() {
        let hub = AgentEventHub(maxBufferedEvents: 200, maxSeenEventIDs: 500)
        for seq in 100...105 {
            hub.publish(makeEvent(seq: seq, text: "live-\(seq)"))
        }

        var anchors = [Int]()
        let output = BridgeAgentEventFetchFlow.run(eventHub: hub,
                                                   workspaceID: "workspace",
                                                   sessionID: "session",
                                                   limit: 100,
                                                   maxBytes: 700,
                                                   beforeSeq: nil,
                                                   afterSeq: 50,
                                                   backfill: unusedBackfill,
                                                   afterSeed: { _, _ in .walkFrom(beforeSeq: 100) },
                                                   afterStep: { _, beforeSeq, _, _ in
            anchors.append(beforeSeq)
            return AgentAfterCursorBackfillStep(outcome: .coveredCursor,
                                                nextBeforeSeq: 51,
                                                events: (51...99).map { self.makeEvent(seq: $0, text: "mid-\($0)") })
        })

        XCTAssertEqual(anchors, [100],
                       "a tiny byte budget must not change what gets scanned")
        XCTAssertEqual(output.fetchResult.events.first?.seq, 51,
                       "the budget keeps the earliest events of an ascending page")
        XCTAssertLessThan(output.fetchResult.events.count, 55)
        XCTAssertTrue(output.fetchResult.hasMore)
        XCTAssertEqual(output.fetchResult.newestSeq, output.fetchResult.events.last?.seq,
                       "the cursor bound must not advance past the delivered page")
    }

    func testIncompleteCoverageFailsClosed() {
        // Step one scans 90...99, step two reports the transcript became
        // unavailable. Serving step one's events (or the live window) now
        // would advance the cursor past the never-walked 51...89 gap.
        let hub = AgentEventHub(maxBufferedEvents: 200, maxSeenEventIDs: 500)
        for seq in 100...105 {
            hub.publish(makeEvent(seq: seq, text: "live-\(seq)"))
        }

        var anchors = [Int]()
        let output = BridgeAgentEventFetchFlow.run(eventHub: hub,
                                                   workspaceID: "workspace",
                                                   sessionID: "session",
                                                   limit: 100,
                                                   beforeSeq: nil,
                                                   afterSeq: 50,
                                                   backfill: unusedBackfill,
                                                   afterSeed: { _, _ in .walkFrom(beforeSeq: 100) },
                                                   afterStep: { _, beforeSeq, _, _ in
            anchors.append(beforeSeq)
            if anchors.count == 1 {
                return AgentAfterCursorBackfillStep(outcome: .advanced,
                                                    nextBeforeSeq: 90,
                                                    events: (90...99).map { self.makeEvent(seq: $0, text: "page1-\($0)") })
            }
            return AgentAfterCursorBackfillStep(outcome: .unavailable, nextBeforeSeq: nil, events: [])
        })

        XCTAssertEqual(anchors, [100, 90])
        XCTAssertTrue(output.fetchResult.events.isEmpty,
                      "no partial scan or live event may be served over an unverified gap")
        XCTAssertEqual(output.fetchResult.newestSeq, 50,
                       "the cursor must not advance; the client retries")
        XCTAssertTrue(output.fetchResult.hasMore)
    }

    func testAfterCursorAtLiveTipStillSkipsBackfill() {
        let hub = AgentEventHub()
        for seq in 100...105 {
            hub.publish(makeEvent(seq: seq, text: "live-\(seq)"))
        }
        hub.replaceHistoricalEvents(sessionID: "session",
                                    events: (1...10).map { makeEvent(seq: $0, text: "deep-\($0)") })

        let output = BridgeAgentEventFetchFlow.run(eventHub: hub,
                                                   workspaceID: "workspace",
                                                   sessionID: "session",
                                                   limit: 50,
                                                   beforeSeq: nil,
                                                   afterSeq: 105,
                                                   backfill: unusedBackfill,
                                                   afterSeed: { _, _ in .covered },
                                                   afterStep: unusedAfterStep)

        XCTAssertFalse(output.didBackfill)
        XCTAssertTrue(output.fetchResult.events.isEmpty)
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
                                                   afterSeq: 1,
                                                   backfill: unusedBackfill,
                                                   afterSeed: { _, _ in .walkFrom(beforeSeq: 100) },
                                                   afterStep: { sessionID, _, _, _ in
            hub.beginNewSourceEpoch(sessionID: sessionID)
            return AgentAfterCursorBackfillStep(outcome: .sourceInvalidated,
                                                nextBeforeSeq: nil,
                                                events: (2...5).map { self.makeEvent(seq: $0, text: "stale-\($0)") })
        })

        XCTAssertFalse(output.didBackfill)
        XCTAssertTrue(output.fetchResult.events.isEmpty,
                      "the final result must be refetched from the new epoch, never the stale walk")
    }

    func testAfterCursorStopsWhenBackfillDoesNotAdvanceCoverage() {
        let hub = AgentEventHub()
        for seq in 100...105 {
            hub.publish(makeEvent(seq: seq, text: "live-\(seq)"))
        }
        var stepCalls = 0

        let output = BridgeAgentEventFetchFlow.run(eventHub: hub,
                                                   workspaceID: "workspace",
                                                   sessionID: "session",
                                                   limit: 3,
                                                   beforeSeq: nil,
                                                   afterSeq: 1,
                                                   backfill: unusedBackfill,
                                                   afterSeed: { _, _ in .walkFrom(beforeSeq: 100) },
                                                   afterStep: { _, beforeSeq, _, _ in
            stepCalls += 1
            // Claims progress but reports the SAME anchor back.
            return AgentAfterCursorBackfillStep(outcome: .advanced,
                                                nextBeforeSeq: beforeSeq,
                                                events: [])
        })

        XCTAssertEqual(stepCalls, 1,
                       "a step that does not lower the anchor cannot justify retrying the same anchor")
        XCTAssertTrue(output.didBackfill)
        XCTAssertTrue(output.fetchResult.events.isEmpty,
                      "a stalled walk is incomplete coverage and must fail closed")
        XCTAssertEqual(output.fetchResult.newestSeq, 1)
    }

    func testAfterCursorAtIntMaxReturnsEmptyWithoutBackfill() {
        let hub = AgentEventHub()
        hub.publish(makeEvent(seq: 100, text: "live-100"))

        let output = BridgeAgentEventFetchFlow.run(eventHub: hub,
                                                   workspaceID: "workspace",
                                                   sessionID: "session",
                                                   limit: 3,
                                                   beforeSeq: nil,
                                                   afterSeq: Int.max,
                                                   backfill: unusedBackfill,
                                                   afterSeed: { _, _ in .unavailable },
                                                   afterStep: unusedAfterStep)

        XCTAssertTrue(output.fetchResult.events.isEmpty)
        XCTAssertFalse(output.didBackfill)
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
                                                       afterSeq: nil,
                                                       backfill: { _, beforeSeq, _ in
                hub.replaceHistoricalEvents(
                    sessionID: "session",
                    events: (97...99).map { self.makeEvent(seq: $0, text: "first-\($0)") },
                    anchorSeq: beforeSeq)
                firstInstalled.signal()
                _ = releaseFirst.wait(timeout: .now() + 5.0)
                return true
            }, afterSeed: { _, _ in .unavailable }, afterStep: self.unusedAfterStep)
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
                                                       afterSeq: nil,
                                                       backfill: { _, beforeSeq, _ in
                hub.replaceHistoricalEvents(
                    sessionID: "session",
                    events: (47...49).map { self.makeEvent(seq: $0, text: "second-\($0)") },
                    anchorSeq: beforeSeq)
                return true
            }, afterSeed: { _, _ in .unavailable }, afterStep: self.unusedAfterStep)
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
                                              afterSeq: nil,
                                                       backfill: { _, beforeSeq, _ in
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
            }, afterSeed: { _, _ in .unavailable }, afterStep: self.unusedAfterStep)
            firstDone.fulfill()
        }
        XCTAssertEqual(firstEntered.wait(timeout: .now() + 2.0), .success)

        DispatchQueue.global(qos: .userInitiated).async {
            let output = BridgeAgentEventFetchFlow.run(eventHub: hub,
                                                       workspaceID: "workspace-b",
                                                       sessionID: "session-b",
                                                       limit: 3,
                                                       beforeSeq: 200,
                                                       afterSeq: nil,
                                                       backfill: { _, beforeSeq, _ in
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
            }, afterSeed: { _, _ in .unavailable }, afterStep: self.unusedAfterStep)
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
