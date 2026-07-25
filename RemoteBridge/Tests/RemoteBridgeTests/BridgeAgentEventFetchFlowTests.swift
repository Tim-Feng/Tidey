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

    // Reframed from the legacy plain-refetch test: with typed seams the
    // legacy-neutral hubOnly plan serves the bounded lease window and the
    // legacy backfill closure is NEVER consulted for an after request.
    func testAfterCursorHubOnlyServesLeaseWindowWithoutLegacyBackfill() {
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
                                                   afterSeq: 103) { _, _, _ in
            backfillCalls += 1
            return true
        }

        XCTAssertEqual(backfillCalls, 0,
                       "the legacy backfill closure never serves a typed after request")
        XCTAssertFalse(output.didBackfill)
        XCTAssertEqual(output.fetchResult.events.compactMap(\.text), ["live-104", "live-105"])
    }

    // Reframed from the legacy no-advance test: an unavailable plan is the
    // typed fail-closed path — no legacy backfill, exact fail-closed shape.
    func testAfterCursorUnavailablePlanFailsClosed() {
        let hub = AgentEventHub()
        for seq in 100...105 {
            hub.publish(makeEvent(seq: seq, text: "live-\(seq)"))
        }
        var backfillCalls = 0

        let output = runAfter(hub: hub,
                              limit: 3,
                              afterSeq: 1,
                              plan: { _, _, expected in
                                  AgentAfterCursorPlan(epoch: expected, mode: .unavailable)
                              },
                              backfill: { _, _, _ in
                                  backfillCalls += 1
                                  return true
                              })

        XCTAssertEqual(backfillCalls, 0)
        XCTAssertFalse(output.didBackfill)
        assertFailClosed(output, afterSeq: 1)
    }

    func testAfterCursorAtIntMaxReturnsEmptyWithoutBackfill() {
        let hub = AgentEventHub()
        hub.publish(makeEvent(seq: 100, text: "live-100"))
        var backfillCalls = 0

        let output = BridgeAgentEventFetchFlow.run(eventHub: hub,
                                                   workspaceID: "workspace",
                                                   sessionID: "session",
                                                   limit: 3,
                                                   beforeSeq: nil,
                                                   afterSeq: Int.max) { _, _, _ in
            backfillCalls += 1
            return true
        }

        XCTAssertTrue(output.fetchResult.events.isEmpty)
        XCTAssertFalse(output.didBackfill)
        XCTAssertEqual(backfillCalls, 0)
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

    // MARK: G3a request-owned coverage batch

    private func epoch(_ hub: AgentEventHub) -> AgentHistoryEpoch {
        hub.currentHistoryEpoch(sessionID: "session")
    }

    private func anchor(_ hub: AgentEventHub, at offset: Int) -> AgentHistoryAnchor {
        AgentHistoryAnchor(epoch: epoch(hub),
                           position: TranscriptEventPosition(lineOffset: offset, ordinal: 0))
    }

    private func runAfter(hub: AgentEventHub,
                          limit: Int,
                          maxBytes: Int? = nil,
                          afterSeq: Int,
                          plan: @escaping (String, Int, AgentHistoryEpoch) -> AgentAfterCursorPlan,
                          step: @escaping (String, AgentHistoryAnchor, Int, Int) -> AgentAfterCursorStep = { _, anchor, _, _ in
                              XCTFail("no raw step expected for this request")
                              return AgentAfterCursorStep(epoch: anchor.epoch, outcome: .unavailable, events: [])
                          },
                          validate: @escaping (String, AgentHistoryEpoch) -> Bool = { _, _ in true },
                          backfill: @escaping (String, Int, Int) -> Bool = { _, _, _ in
                              XCTFail("the legacy backfill closure must not serve a typed after request")
                              return false
                          }) -> BridgeAgentEventFetchFlow.Output {
        BridgeAgentEventFetchFlow.run(eventHub: hub,
                                      workspaceID: "workspace",
                                      sessionID: "session",
                                      limit: limit,
                                      maxBytes: maxBytes,
                                      beforeSeq: nil,
                                      afterSeq: afterSeq,
                                      afterCursorSeams: .init(plan: plan,
                                                              step: step,
                                                              validateEpoch: validate),
                                      backfill: backfill)
    }

    private func assertFailClosed(_ output: BridgeAgentEventFetchFlow.Output,
                                  afterSeq: Int,
                                  file: StaticString = #filePath,
                                  line: UInt = #line) {
        XCTAssertTrue(output.fetchResult.events.isEmpty, "fail closed serves no event",
                      file: file, line: line)
        XCTAssertEqual(output.fetchResult.oldestSeq, afterSeq, file: file, line: line)
        XCTAssertEqual(output.fetchResult.newestSeq, afterSeq, file: file, line: line)
        XCTAssertTrue(output.fetchResult.hasMore, "fail closed keeps the client retrying",
                      file: file, line: line)
    }

    func testFinalPayloadOwnsScannedHistoryEvenWhenHubCacheDropsIt() {
        let hub = AgentEventHub()
        for seq in 200...202 {
            hub.publish(makeEvent(seq: seq, text: "live-\(seq)"))
        }
        hub.replaceHistoricalEvents(sessionID: "session",
                                    events: (150...152).map { makeEvent(seq: $0, text: "cache-\($0)") })

        let output = runAfter(hub: hub,
                              limit: 10,
                              afterSeq: 100,
                              plan: { _, _, expected in
                                  AgentAfterCursorPlan(
                                      epoch: expected,
                                      mode: .scan(from: self.anchor(hub, at: 10_000)))
                              },
                              step: { _, stepAnchor, _, _ in
                                  AgentAfterCursorStep(
                                      epoch: stepAnchor.epoch,
                                      outcome: .complete,
                                      events: (101...103).map { self.makeEvent(seq: $0, text: "step-\($0)") })
                              })

        XCTAssertTrue(output.didBackfill)
        let texts = output.fetchResult.events.compactMap(\.text)
        XCTAssertEqual(texts, ["step-101", "step-102", "step-103",
                               "live-200", "live-201", "live-202"],
                       "step-returned history + lease window are the ONLY response authority")
        XCTAssertFalse(texts.contains { $0.hasPrefix("cache-") },
                       "shared historical cache events never enter the response")
        XCTAssertFalse(output.fetchResult.hasMore)
    }

    func testTinyMaxBytesTrimsPayloadOnly() {
        let hub = AgentEventHub()
        hub.publish(makeEvent(seq: 300, text: "live-300"))
        var stepCalls = 0

        let output = runAfter(hub: hub,
                              limit: 10,
                              maxBytes: 1,
                              afterSeq: 100,
                              plan: { _, _, expected in
                                  AgentAfterCursorPlan(
                                      epoch: expected,
                                      mode: .scan(from: self.anchor(hub, at: 10_000)))
                              },
                              step: { _, stepAnchor, _, _ in
                                  stepCalls += 1
                                  if stepCalls == 1 {
                                      return AgentAfterCursorStep(
                                          epoch: stepAnchor.epoch,
                                          outcome: .advanced(self.anchor(hub, at: 5_000)),
                                          events: [self.makeEvent(seq: 101, text: "raw-101"),
                                                   self.makeEvent(seq: 102, text: "raw-102")])
                                  }
                                  return AgentAfterCursorStep(
                                      epoch: stepAnchor.epoch,
                                      outcome: .complete,
                                      events: [self.makeEvent(seq: 103, text: "raw-103")])
                              })

        XCTAssertEqual(stepCalls, 2,
                       "coverage walks to completion regardless of the byte budget")
        XCTAssertFalse(output.fetchResult.events.isEmpty)
        XCTAssertLessThan(output.fetchResult.events.count, 4,
                          "the byte budget trims only the complete union")
        XCTAssertTrue(output.fetchResult.hasMore, "the byte trim is reflected in hasMore")
    }

    func testStalledWalkFailsClosed() {
        let hub = AgentEventHub()
        hub.publish(makeEvent(seq: 300, text: "live-300"))
        var stepCalls = 0

        let output = runAfter(hub: hub,
                              limit: 3,
                              afterSeq: 100,
                              plan: { _, _, expected in
                                  AgentAfterCursorPlan(
                                      epoch: expected,
                                      mode: .scan(from: self.anchor(hub, at: 1_000)))
                              },
                              step: { _, stepAnchor, _, _ in
                                  stepCalls += 1
                                  return AgentAfterCursorStep(
                                      epoch: stepAnchor.epoch,
                                      outcome: .advanced(stepAnchor),
                                      events: [self.makeEvent(seq: 150, text: "stalled-150")])
                              })

        XCTAssertEqual(stepCalls, 1, "a stalled anchor is rejected immediately — no loop")
        XCTAssertFalse(output.didBackfill,
                       "a rejected stalled step never counts as backfill")
        assertFailClosed(output, afterSeq: 100)
    }

    func testIncompleteCoverageFailsClosed() {
        let hub = AgentEventHub()
        hub.publish(makeEvent(seq: 300, text: "live-300"))
        var stepCalls = 0

        let output = runAfter(hub: hub,
                              limit: 3,
                              afterSeq: 100,
                              plan: { _, _, expected in
                                  AgentAfterCursorPlan(
                                      epoch: expected,
                                      mode: .scan(from: self.anchor(hub, at: 1_000)))
                              },
                              step: { _, stepAnchor, _, _ in
                                  stepCalls += 1
                                  if stepCalls == 1 {
                                      return AgentAfterCursorStep(
                                          epoch: stepAnchor.epoch,
                                          outcome: .advanced(self.anchor(hub, at: 500)),
                                          events: [self.makeEvent(seq: 150, text: "partial-150")])
                                  }
                                  return AgentAfterCursorStep(epoch: stepAnchor.epoch,
                                                              outcome: .unavailable,
                                                              events: [])
                              })

        XCTAssertEqual(stepCalls, 2)
        assertFailClosed(output, afterSeq: 100)
    }

    func testRawCoveredUsesLeaseOnlyWhenStartWindowIsComplete() {
        let hub = AgentEventHub()
        for seq in 101...103 {
            hub.publish(makeEvent(seq: seq, text: "live-\(seq)"))
        }

        let output = runAfter(hub: hub,
                              limit: 5,
                              afterSeq: 100,
                              plan: { _, _, expected in
                                  AgentAfterCursorPlan(
                                      epoch: expected,
                                      mode: .rawCovered(replayFrom: self.anchor(hub, at: 9_999)))
                              })

        XCTAssertFalse(output.didBackfill)
        XCTAssertEqual(output.fetchResult.events.compactMap(\.text),
                       ["live-101", "live-102", "live-103"],
                       "a complete start window serves the lease directly, no raw step")
        XCTAssertFalse(output.fetchResult.hasMore)
    }

    func testRawCoveredReplaysFromFixedFrontierWhenLeaseEvidenceShowsEviction() {
        let hub = AgentEventHub(maxBufferedEvents: 2, maxSeenEventIDs: 100)
        for seq in 101...105 {
            hub.publish(makeEvent(seq: seq, text: "live-\(seq)"))
        }
        var stepAnchors = [AgentHistoryAnchor]()

        let output = runAfter(hub: hub,
                              limit: 10,
                              afterSeq: 100,
                              plan: { _, _, expected in
                                  AgentAfterCursorPlan(
                                      epoch: expected,
                                      mode: .rawCovered(replayFrom: self.anchor(hub, at: 9_999)))
                              },
                              step: { _, stepAnchor, _, _ in
                                  stepAnchors.append(stepAnchor)
                                  return AgentAfterCursorStep(
                                      epoch: stepAnchor.epoch,
                                      outcome: .complete,
                                      events: (101...103).map { self.makeEvent(seq: $0, text: "raw-\($0)") })
                              })

        XCTAssertEqual(stepAnchors.map(\.position.lineOffset), [9_999],
                       "pre-lease eviction forces a raw walk from the plan's FIXED frontier")
        XCTAssertTrue(output.didBackfill)
        XCTAssertEqual(output.fetchResult.events.map(\.seq), [101, 102, 103, 104, 105],
                       "raw coverage must not be mistaken for retained product coverage")
    }

    func testHubOnlyReturnsBoundedLeaseDespitePriorEviction() {
        let hub = AgentEventHub(maxBufferedEvents: 2, maxSeenEventIDs: 100)
        for seq in 101...105 {
            hub.publish(makeEvent(seq: seq, text: "live-\(seq)"))
        }

        let output = runAfter(hub: hub,
                              limit: 5,
                              afterSeq: 100,
                              plan: { _, _, expected in
                                  AgentAfterCursorPlan(epoch: expected, mode: .hubOnly)
                              })

        XCTAssertFalse(output.didBackfill)
        XCTAssertEqual(output.fetchResult.events.compactMap(\.text),
                       ["live-104", "live-105"],
                       "hubOnly is bounded best-effort — old transient eviction neither fails closed nor scans")
        XCTAssertFalse(output.fetchResult.hasMore,
                       "pre-request evicted transients do not count toward hasMore")
    }

    func testLiveAppendEvictionDuringCoverageWalkIsCapturedOrRetries() {
        let hub = AgentEventHub(maxBufferedEvents: 2, maxSeenEventIDs: 100)
        for seq in 101...102 {
            hub.publish(makeEvent(seq: seq, text: "live-\(seq)"))
        }
        var stepCalls = 0

        let output = runAfter(hub: hub,
                              limit: 3,
                              afterSeq: 100,
                              plan: { _, _, expected in
                                  AgentAfterCursorPlan(
                                      epoch: expected,
                                      mode: .scan(from: self.anchor(hub, at: 5_000)))
                              },
                              step: { _, stepAnchor, _, _ in
                                  stepCalls += 1
                                  // Live publishes DURING the open walk evict
                                  // 101/102 from the tiny buffer; the open
                                  // lease must already own them.
                                  for seq in 103...105 {
                                      hub.publish(self.makeEvent(seq: seq, text: "live-\(seq)"))
                                  }
                                  return AgentAfterCursorStep(epoch: stepAnchor.epoch,
                                                              outcome: .complete,
                                                              events: [])
                              })

        XCTAssertEqual(stepCalls, 1)
        let seqs = output.fetchResult.events.map(\.seq)
        XCTAssertEqual(seqs, [101, 102, 103],
                       "the earliest response-window events survive eviction exactly once — no gap, no duplicate")
        XCTAssertTrue(output.fetchResult.hasMore)
    }

    func testPublishAndEvictionDuringPlanIsCapturedByLeaseFirstOrdering() {
        let hub = AgentEventHub(maxBufferedEvents: 2, maxSeenEventIDs: 100)

        let output = runAfter(hub: hub,
                              limit: 10,
                              afterSeq: 100,
                              plan: { _, _, expected in
                                  // Publish + evict INSIDE the plan itself:
                                  // only a lease begun BEFORE the plan can
                                  // still own 101/102.
                                  for seq in 101...105 {
                                      hub.publish(self.makeEvent(seq: seq, text: "live-\(seq)"))
                                  }
                                  return AgentAfterCursorPlan(
                                      epoch: expected,
                                      mode: .rawCovered(replayFrom: self.anchor(hub, at: 9_999)))
                              })

        XCTAssertEqual(output.fetchResult.events.map(\.seq), [101, 102, 103, 104, 105],
                       "the lease exists before the plan and captured the whole window")
    }

    func testLeaseTruncationSetsHasMore() {
        let hub = AgentEventHub()

        let output = runAfter(hub: hub,
                              limit: 2,
                              afterSeq: 100,
                              plan: { _, _, expected in
                                  for seq in 101...105 {
                                      hub.publish(self.makeEvent(seq: seq, text: "live-\(seq)"))
                                  }
                                  return AgentAfterCursorPlan(
                                      epoch: expected,
                                      mode: .rawCovered(replayFrom: self.anchor(hub, at: 9_999)))
                              })

        XCTAssertEqual(output.fetchResult.events.map(\.seq), [101, 102],
                       "the lease keeps the earliest bounded window")
        XCTAssertTrue(output.fetchResult.hasMore,
                      "lease truncation is reflected in hasMore")
    }

    func testDisjointHistoricalCacheNeverRedirectsAnchors() {
        let hub = AgentEventHub()
        for seq in 200...202 {
            hub.publish(makeEvent(seq: seq, text: "live-\(seq)"))
        }
        hub.replaceHistoricalEvents(sessionID: "session",
                                    events: (10...20).map { makeEvent(seq: $0, text: "deep-\($0)") })
        var stepAnchors = [Int]()
        var stepCalls = 0

        let output = runAfter(hub: hub,
                              limit: 10,
                              afterSeq: 100,
                              plan: { _, _, expected in
                                  AgentAfterCursorPlan(
                                      epoch: expected,
                                      mode: .scan(from: self.anchor(hub, at: 5_000)))
                              },
                              step: { _, stepAnchor, _, _ in
                                  stepCalls += 1
                                  stepAnchors.append(stepAnchor.position.lineOffset)
                                  if stepCalls == 1 {
                                      return AgentAfterCursorStep(
                                          epoch: stepAnchor.epoch,
                                          outcome: .advanced(self.anchor(hub, at: 4_000)),
                                          events: [self.makeEvent(seq: 150, text: "raw-150")])
                                  }
                                  return AgentAfterCursorStep(
                                      epoch: stepAnchor.epoch,
                                      outcome: .complete,
                                      events: [self.makeEvent(seq: 140, text: "raw-140")])
                              })

        XCTAssertEqual(stepAnchors, [5_000, 4_000],
                       "the only raw anchors are the plan anchor and strictly decreasing step anchors")
        let texts = output.fetchResult.events.compactMap(\.text)
        XCTAssertEqual(texts, ["raw-140", "raw-150", "live-200", "live-201", "live-202"])
        XCTAssertFalse(texts.contains { $0.hasPrefix("deep-") },
                       "shared historical cache neither redirects the walk nor enters the payload")
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
