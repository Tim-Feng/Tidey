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

        var planCalls = 0
        let output = runAfter(hub: hub,
                              limit: 3,
                              afterSeq: 1,
                              plan: { _, _, expected in
                                  planCalls += 1
                                  return AgentAfterCursorPlan(epoch: expected, mode: .unavailable)
                              },
                              backfill: { _, _, _ in
                                  backfillCalls += 1
                                  return true
                              })

        XCTAssertEqual(backfillCalls, 0)
        XCTAssertEqual(planCalls, 1, "a same-epoch unavailable plan is terminal — no retry")
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
        XCTAssertEqual(output.fetchResult.oldestSeq, Int.max,
                       "a successful empty page anchors at the cursor")
        XCTAssertEqual(output.fetchResult.newestSeq, Int.max)
        XCTAssertFalse(output.fetchResult.hasMore)
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
                          workspaceID: String = "workspace",
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
                                      workspaceID: workspaceID,
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
        var stepCalls = 0

        let output = runAfter(hub: hub,
                              limit: 10,
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
                                          events: [self.makeEvent(seq: 103, text: "step-103")])
                                  }
                                  // The shared cache is REPLACED between the
                                  // steps: request-owned events must survive.
                                  hub.replaceHistoricalEvents(
                                      sessionID: "session",
                                      events: [self.makeEvent(seq: 160, text: "cache-replaced-160")])
                                  return AgentAfterCursorStep(
                                      epoch: stepAnchor.epoch,
                                      outcome: .complete,
                                      events: (101...102).map { self.makeEvent(seq: $0, text: "step-\($0)") })
                              })

        XCTAssertEqual(stepCalls, 2)
        XCTAssertTrue(output.didBackfill)
        let texts = output.fetchResult.events.compactMap(\.text)
        XCTAssertEqual(texts, ["step-101", "step-102", "step-103",
                               "live-200", "live-201", "live-202"],
                       "earlier request-owned step events survive a mid-walk cache replacement")
        XCTAssertFalse(texts.contains { $0.hasPrefix("cache-") },
                       "shared historical cache events never enter the response")
        XCTAssertFalse(output.fetchResult.hasMore)
    }

    func testAfterCursorZeroLimitUsesEffectiveLimitOne() {
        let hub = AgentEventHub()
        for seq in 101...102 {
            hub.publish(makeEvent(seq: seq, text: "live-\(seq)"))
        }

        let output = runAfter(hub: hub,
                              limit: 0,
                              afterSeq: 100,
                              plan: { _, _, expected in
                                  AgentAfterCursorPlan(epoch: expected, mode: .hubOnly)
                              })

        XCTAssertEqual(output.fetchResult.events.map(\.seq), [101],
                       "limit 0 serves ONE event via effectiveLimit = max(limit, 1)")
        XCTAssertTrue(output.fetchResult.hasMore)
    }

    func testEqualSequenceTieBreakKeepsLexicographicallyEarliest() {
        let hub = AgentEventHub()
        let letters = "abcdefghijklmnopqrst".map(String.init)

        let output = runAfter(hub: hub,
                              limit: 2,
                              afterSeq: 100,
                              plan: { _, _, expected in
                                  AgentAfterCursorPlan(
                                      epoch: expected,
                                      mode: .scan(from: self.anchor(hub, at: 5_000)))
                              },
                              step: { _, stepAnchor, _, _ in
                                  AgentAfterCursorStep(
                                      epoch: stepAnchor.epoch,
                                      outcome: .complete,
                                      events: letters.map {
                                          self.makeEvent(id: "tie-\($0)", seq: 150, text: "tie-\($0)")
                                      })
                              })

        XCTAssertEqual(output.fetchResult.events.map(\.eventID), ["tie-a", "tie-b"],
                       "equal-seq candidates at the capacity boundary must keep the lexicographically earliest (seq,eventID)")
        XCTAssertTrue(output.fetchResult.hasMore,
                      "unique candidates excluded by the cap set the truncation flag")
    }

    // Guard on the parent commit (deterministic non-tie displacement was
    // already correct); it additionally pins the raw step page size.
    func testDeeperStepsDisplaceNewerCandidatesAcrossCapacity() {
        let hub = AgentEventHub()
        var suppliedStepLimits = [Int]()
        var stepCalls = 0

        let output = runAfter(hub: hub,
                              limit: 3,
                              afterSeq: 100,
                              plan: { _, _, expected in
                                  AgentAfterCursorPlan(
                                      epoch: expected,
                                      mode: .scan(from: self.anchor(hub, at: 5_000)))
                              },
                              step: { _, stepAnchor, _, stepLimit in
                                  suppliedStepLimits.append(stepLimit)
                                  stepCalls += 1
                                  if stepCalls == 1 {
                                      return AgentAfterCursorStep(
                                          epoch: stepAnchor.epoch,
                                          outcome: .advanced(self.anchor(hub, at: 4_000)),
                                          events: (200...204).map { self.makeEvent(seq: $0, text: "new-\($0)") })
                                  }
                                  return AgentAfterCursorStep(
                                      epoch: stepAnchor.epoch,
                                      outcome: .complete,
                                      events: (101...105).map { self.makeEvent(seq: $0, text: "old-\($0)") })
                              })

        XCTAssertEqual(output.fetchResult.events.map(\.seq), [101, 102, 103],
                       "deeper earliest events displace newer retained candidates")
        XCTAssertTrue(output.fetchResult.hasMore)
        XCTAssertTrue(suppliedStepLimits.allSatisfy { $0 >= max(4, transcriptBootstrapLineLimit) },
                      "the raw step page size is at least max(effectiveLimit + 1, bootstrap), got \(suppliedStepLimits)")
    }

    // Guard: the lease's accepted/rebased copy wins a raw/lease eventID
    // overlap (union insertion order already guaranteed this on the parent).
    func testLeaseRebasedCopyWinsRawOverlap() {
        let hub = AgentEventHub()
        hub.publish(makeEvent(seq: 300, text: "live-300"))

        let output = runAfter(hub: hub,
                              limit: 10,
                              afterSeq: 100,
                              plan: { _, _, expected in
                                  // The matching publish is REBASED above the
                                  // high water and captured by the open lease.
                                  hub.publish(self.makeEvent(id: "shared-1", seq: 150, text: "shared"))
                                  return AgentAfterCursorPlan(
                                      epoch: expected,
                                      mode: .scan(from: self.anchor(hub, at: 5_000)))
                              },
                              step: { _, stepAnchor, _, _ in
                                  AgentAfterCursorStep(
                                      epoch: stepAnchor.epoch,
                                      outcome: .complete,
                                      events: [self.makeEvent(id: "shared-1", seq: 150, text: "shared")])
                              })

        let shared = output.fetchResult.events.filter { $0.eventID == "shared-1" }
        XCTAssertEqual(shared.count, 1, "the overlapping eventID appears exactly once")
        XCTAssertEqual(shared.first?.seq, 301,
                       "the lease's accepted/rebased copy wins the overlap")
    }

    // MARK: G3c one-retry state machine

    func testEpochChangeAfterFinalStepDiscardsWholePageAndRetriesOnce() {
        let hub = AgentEventHub()
        var planCalls = 0
        var stepCalls = 0

        let output = runAfter(hub: hub,
                              limit: 5,
                              afterSeq: 100,
                              plan: { _, _, expected in
                                  planCalls += 1
                                  if planCalls == 1 {
                                      return AgentAfterCursorPlan(
                                          epoch: expected,
                                          mode: .scan(from: AgentHistoryAnchor(
                                              epoch: expected,
                                              position: TranscriptEventPosition(lineOffset: 5_000, ordinal: 0))))
                                  }
                                  return AgentAfterCursorPlan(epoch: expected, mode: .hubOnly)
                              },
                              step: { _, stepAnchor, _, _ in
                                  stepCalls += 1
                                  // The epoch moves AFTER the final step is
                                  // accepted: the whole page is discarded
                                  // and the retry serves the replacement.
                                  hub.beginNewSourceEpoch(sessionID: "session")
                                  hub.publish(self.makeEvent(id: "replacement", seq: 200, text: "replacement"))
                                  return AgentAfterCursorStep(
                                      epoch: stepAnchor.epoch,
                                      outcome: .complete,
                                      events: [self.makeEvent(id: "stale", seq: 150, text: "stale")])
                              })

        XCTAssertEqual(planCalls, 2)
        XCTAssertEqual(stepCalls, 1)
        XCTAssertEqual(output.fetchResult.events.compactMap(\.text), ["replacement"],
                       "only the replacement-epoch payload survives")
        XCTAssertTrue(output.didBackfill,
                      "the first attempt accepted a complete step even though its payload was discarded")
    }

    func testEpochChangeMidWalkRetriesOnceThenFailsClosed() {
        let hub = AgentEventHub()
        var planCalls = 0
        var stepCalls = 0

        let output = runAfter(hub: hub,
                              limit: 5,
                              afterSeq: 100,
                              plan: { _, _, expected in
                                  planCalls += 1
                                  return AgentAfterCursorPlan(
                                      epoch: expected,
                                      mode: .scan(from: AgentHistoryAnchor(
                                          epoch: expected,
                                          position: TranscriptEventPosition(lineOffset: 5_000, ordinal: 0))))
                              },
                              step: { _, stepAnchor, _, _ in
                                  stepCalls += 1
                                  hub.beginNewSourceEpoch(sessionID: "session")
                                  return AgentAfterCursorStep(epoch: stepAnchor.epoch,
                                                              outcome: .sourceChanged,
                                                              events: [])
                              })

        XCTAssertEqual(planCalls, 2, "exactly one retry — never a third attempt")
        XCTAssertEqual(stepCalls, 2)
        XCTAssertFalse(output.didBackfill, "no step was ever accepted")
        assertFailClosed(output, afterSeq: 100)
    }

    func testSourceInvalidationRetriesCoverageInsteadOfPlainHubFetch() {
        let hub = AgentEventHub()
        var planCalls = 0
        var stepCalls = 0

        let output = runAfter(hub: hub,
                              limit: 5,
                              afterSeq: 100,
                              plan: { _, _, expected in
                                  planCalls += 1
                                  return AgentAfterCursorPlan(
                                      epoch: expected,
                                      mode: .scan(from: AgentHistoryAnchor(
                                          epoch: expected,
                                          position: TranscriptEventPosition(lineOffset: 5_000, ordinal: 0))))
                              },
                              step: { _, stepAnchor, _, _ in
                                  stepCalls += 1
                                  if stepCalls == 1 {
                                      // Same-epoch .sourceChanged: the
                                      // OUTCOME classification must retry
                                      // with fresh coverage, not fall back
                                      // to a plain Hub fetch.
                                      hub.beginNewSourceEpoch(sessionID: "session")
                                      hub.publish(self.makeEvent(id: "live-repl", seq: 300, text: "live-repl"))
                                      return AgentAfterCursorStep(
                                          epoch: stepAnchor.epoch,
                                          outcome: .sourceChanged,
                                          events: [self.makeEvent(id: "stale", seq: 150, text: "stale")])
                                  }
                                  return AgentAfterCursorStep(
                                      epoch: stepAnchor.epoch,
                                      outcome: .complete,
                                      events: [self.makeEvent(id: "raw-repl", seq: 250, text: "raw-repl")])
                              })

        XCTAssertEqual(planCalls, 2)
        XCTAssertEqual(stepCalls, 2)
        XCTAssertEqual(output.fetchResult.events.compactMap(\.text), ["raw-repl", "live-repl"],
                       "the retry re-plans and re-walks: replacement raw prefix + retry lease live — a plain Hub fetch would miss the raw prefix")
    }

    func testPlanEpochMismatchRetriesOnce() {
        let hub = AgentEventHub()
        hub.publish(makeEvent(seq: 101, text: "live-101"))
        var planCalls = 0

        let output = runAfter(hub: hub,
                              limit: 5,
                              afterSeq: 100,
                              plan: { _, _, expected in
                                  planCalls += 1
                                  if planCalls == 1 {
                                      return AgentAfterCursorPlan(
                                          epoch: AgentHistoryEpoch(sessionID: "session",
                                                                   generation: expected.generation &+ 99),
                                          mode: .hubOnly)
                                  }
                                  return AgentAfterCursorPlan(epoch: expected, mode: .hubOnly)
                              })

        XCTAssertEqual(planCalls, 2)
        XCTAssertEqual(output.fetchResult.events.compactMap(\.text), ["live-101"],
                       "the mismatched first attempt contributes no payload")
    }

    func testPlanAnchorEpochMismatchRetriesOnce() {
        let hub = AgentEventHub()
        var planCalls = 0
        var stepCalls = 0

        let output = runAfter(hub: hub,
                              limit: 5,
                              afterSeq: 100,
                              plan: { _, _, expected in
                                  planCalls += 1
                                  let anchorEpoch = planCalls == 1
                                      ? AgentHistoryEpoch(sessionID: "session",
                                                          generation: expected.generation &+ 99)
                                      : expected
                                  return AgentAfterCursorPlan(
                                      epoch: expected,
                                      mode: .scan(from: AgentHistoryAnchor(
                                          epoch: anchorEpoch,
                                          position: TranscriptEventPosition(lineOffset: 5_000, ordinal: 0))))
                              },
                              step: { _, stepAnchor, _, _ in
                                  stepCalls += 1
                                  return AgentAfterCursorStep(
                                      epoch: stepAnchor.epoch,
                                      outcome: .complete,
                                      events: [self.makeEvent(seq: 101, text: "raw-101")])
                              })

        XCTAssertEqual(planCalls, 2)
        XCTAssertEqual(stepCalls, 1, "the mismatched-anchor attempt never walks")
        XCTAssertEqual(output.fetchResult.events.compactMap(\.text), ["raw-101"])
    }

    func testStepEpochMismatchRetriesOnce() {
        let hub = AgentEventHub()
        var planCalls = 0
        var stepCalls = 0

        let output = runAfter(hub: hub,
                              limit: 5,
                              afterSeq: 100,
                              plan: { _, _, expected in
                                  planCalls += 1
                                  return AgentAfterCursorPlan(
                                      epoch: expected,
                                      mode: .scan(from: AgentHistoryAnchor(
                                          epoch: expected,
                                          position: TranscriptEventPosition(lineOffset: 5_000, ordinal: 0))))
                              },
                              step: { _, stepAnchor, _, _ in
                                  stepCalls += 1
                                  if stepCalls == 1 {
                                      return AgentAfterCursorStep(
                                          epoch: AgentHistoryEpoch(sessionID: "session",
                                                                   generation: stepAnchor.epoch.generation &+ 99),
                                          outcome: .complete,
                                          events: [self.makeEvent(id: "stale", seq: 150, text: "stale")])
                                  }
                                  return AgentAfterCursorStep(
                                      epoch: stepAnchor.epoch,
                                      outcome: .complete,
                                      events: [self.makeEvent(id: "second", seq: 201, text: "second")])
                              })

        XCTAssertEqual(planCalls, 2)
        XCTAssertEqual(stepCalls, 2)
        XCTAssertEqual(output.fetchResult.events.compactMap(\.text), ["second"],
                       "only the second attempt's events are served")
    }

    func testValidationFalseAfterEpochChangeRetriesOnce() {
        let hub = AgentEventHub()
        for seq in 101...102 {
            hub.publish(makeEvent(seq: seq, text: "pre-\(seq)"))
        }
        var planCalls = 0
        var validateCalls = 0

        let output = runAfter(hub: hub,
                              limit: 5,
                              afterSeq: 100,
                              plan: { _, _, expected in
                                  planCalls += 1
                                  return AgentAfterCursorPlan(
                                      epoch: expected,
                                      mode: .rawCovered(replayFrom: AgentHistoryAnchor(
                                          epoch: expected,
                                          position: TranscriptEventPosition(lineOffset: 9_999, ordinal: 0))))
                              },
                              validate: { _, _ in
                                  validateCalls += 1
                                  if validateCalls == 1 {
                                      hub.beginNewSourceEpoch(sessionID: "session")
                                      hub.publish(self.makeEvent(id: "replacement", seq: 200, text: "replacement"))
                                      return false
                                  }
                                  return true
                              })

        XCTAssertEqual(planCalls, 2)
        XCTAssertEqual(validateCalls, 2)
        XCTAssertEqual(output.fetchResult.events.compactMap(\.text), ["replacement"],
                       "a false validation caused by an epoch change retries and serves the replacement epoch")
    }

    func testValidationAdvancingEpochRetriesOnceEvenWhenReturningTrue() {
        let hub = AgentEventHub()
        for seq in 101...103 {
            hub.publish(makeEvent(seq: seq, text: "pre-\(seq)"))
        }
        var planCalls = 0
        var validateCalls = 0

        let output = runAfter(hub: hub,
                              limit: 5,
                              afterSeq: 100,
                              plan: { _, _, expected in
                                  planCalls += 1
                                  return AgentAfterCursorPlan(
                                      epoch: expected,
                                      mode: .rawCovered(replayFrom: AgentHistoryAnchor(
                                          epoch: expected,
                                          position: TranscriptEventPosition(lineOffset: 9_999, ordinal: 0))))
                              },
                              validate: { _, _ in
                                  validateCalls += 1
                                  if validateCalls == 1 {
                                      hub.beginNewSourceEpoch(sessionID: "session")
                                      hub.publish(self.makeEvent(id: "replacement", seq: 200, text: "replacement"))
                                      return true
                                  }
                                  return true
                              })

        XCTAssertEqual(planCalls, 2,
                       "an epoch that moved during validation retries even when validation returns true")
        XCTAssertEqual(validateCalls, 2)
        XCTAssertEqual(output.fetchResult.events.compactMap(\.text), ["replacement"],
                       "only the replacement-epoch payload survives")
    }

    // Terminal guard: validation false while the Hub epoch is UNCHANGED is
    // a terminal fail — no retry quota applies.
    func testValidationFalseWithoutEpochChangeFailsClosedWithoutRetry() {
        let hub = AgentEventHub()
        hub.publish(makeEvent(seq: 101, text: "live-101"))
        var planCalls = 0
        var validateCalls = 0

        let output = runAfter(hub: hub,
                              limit: 5,
                              afterSeq: 100,
                              plan: { _, _, expected in
                                  planCalls += 1
                                  return AgentAfterCursorPlan(
                                      epoch: expected,
                                      mode: .rawCovered(replayFrom: AgentHistoryAnchor(
                                          epoch: expected,
                                          position: TranscriptEventPosition(lineOffset: 9_999, ordinal: 0))))
                              },
                              validate: { _, _ in
                                  validateCalls += 1
                                  return false
                              })

        XCTAssertEqual(planCalls, 1)
        XCTAssertEqual(validateCalls, 1)
        assertFailClosed(output, afterSeq: 100)
    }

    func testValidationPublishAfterLeaseFinishIsNotRetroactivelyIncluded() {
        let hub = AgentEventHub()
        for seq in 101...102 {
            hub.publish(makeEvent(seq: seq, text: "live-\(seq)"))
        }

        let output = runAfter(hub: hub,
                              limit: 5,
                              afterSeq: 100,
                              plan: { _, _, expected in
                                  AgentAfterCursorPlan(
                                      epoch: expected,
                                      mode: .rawCovered(replayFrom: self.anchor(hub, at: 9_999)))
                              },
                              validate: { _, _ in
                                  hub.publish(self.makeEvent(seq: 103, text: "late-103"))
                                  return true
                              })

        XCTAssertEqual(output.fetchResult.events.map(\.seq), [101, 102],
                       "a publish after lease finish is the NEXT page's business")
    }

    // Guard: the parent already rejected a non-descending anchor.
    func testHigherNextAnchorFailsClosed() {
        let hub = AgentEventHub()
        hub.publish(makeEvent(seq: 300, text: "live-300"))
        var stepCalls = 0

        var planCalls = 0
        let output = runAfter(hub: hub,
                              limit: 3,
                              afterSeq: 100,
                              plan: { _, _, expected in
                                  planCalls += 1
                                  return AgentAfterCursorPlan(
                                      epoch: expected,
                                      mode: .scan(from: self.anchor(hub, at: 1_000)))
                              },
                              step: { _, stepAnchor, _, _ in
                                  stepCalls += 1
                                  return AgentAfterCursorStep(
                                      epoch: stepAnchor.epoch,
                                      outcome: .advanced(self.anchor(hub, at: 2_000)),
                                      events: [self.makeEvent(seq: 150, text: "climbing-150")])
                              })

        XCTAssertEqual(planCalls, 1, "a same-epoch stall is terminal — no retry")
        XCTAssertEqual(stepCalls, 1, "a HIGHER next raw position is a stall — exactly one step call")
        XCTAssertFalse(output.didBackfill)
        assertFailClosed(output, afterSeq: 100)
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
                                          events: [self.makeEvent(seq: 102, text: "raw-102"),
                                                   self.makeEvent(seq: 103, text: "raw-103")])
                                  }
                                  // The DEEPER, FINAL step provides the
                                  // earliest event: only a budget applied
                                  // after the complete union can retain it.
                                  return AgentAfterCursorStep(
                                      epoch: stepAnchor.epoch,
                                      outcome: .complete,
                                      events: [self.makeEvent(seq: 101, text: "raw-101")])
                              })

        XCTAssertEqual(stepCalls, 2,
                       "coverage walks to completion regardless of the byte budget")
        XCTAssertEqual(output.fetchResult.events.map(\.eventID), ["event-101"],
                       "the earliest event from the deeper final step is the one retained")
        XCTAssertEqual(output.fetchResult.events.first?.metadata?["tidey_truncated"], "true",
                       "an event over the byte budget keeps its placeholder metadata")
        XCTAssertEqual(output.fetchResult.events.first?.metadata?["tidey_max_bytes"], "1")
        XCTAssertEqual(output.fetchResult.oldestSeq, 101)
        XCTAssertEqual(output.fetchResult.newestSeq, 101)
        XCTAssertTrue(output.fetchResult.hasMore, "the byte trim is reflected in hasMore")
    }

    // Guard on current HEAD: an Int.max LIMIT (distinct from the existing
    // afterSeq == Int.max case) exercises the overflow-safe capacity seam.
    func testAfterCursorIntMaxLimitScanIsOverflowSafe() {
        let hub = AgentEventHub()
        hub.publish(makeEvent(seq: 300, text: "live-300"))
        var suppliedStepLimits = [Int]()

        let output = runAfter(hub: hub,
                              limit: Int.max,
                              afterSeq: 100,
                              plan: { _, _, expected in
                                  AgentAfterCursorPlan(
                                      epoch: expected,
                                      mode: .scan(from: self.anchor(hub, at: 5_000)))
                              },
                              step: { _, stepAnchor, _, stepLimit in
                                  suppliedStepLimits.append(stepLimit)
                                  return AgentAfterCursorStep(
                                      epoch: stepAnchor.epoch,
                                      outcome: .complete,
                                      events: [self.makeEvent(seq: 101, text: "raw-101")])
                              })

        XCTAssertEqual(suppliedStepLimits, [Int.max],
                       "the raw step receives the overflow-clamped limit unchanged")
        XCTAssertTrue(output.didBackfill)
        XCTAssertEqual(output.fetchResult.events.map(\.seq), [101, 300])
        XCTAssertEqual(output.fetchResult.oldestSeq, 101)
        XCTAssertEqual(output.fetchResult.newestSeq, 300)
        XCTAssertFalse(output.fetchResult.hasMore)
    }

    func testStalledWalkFailsClosed() {
        let hub = AgentEventHub()
        hub.publish(makeEvent(seq: 300, text: "live-300"))
        var planCalls = 0
        var stepCalls = 0

        let output = runAfter(hub: hub,
                              limit: 3,
                              afterSeq: 100,
                              plan: { _, _, expected in
                                  planCalls += 1
                                  return AgentAfterCursorPlan(
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

        XCTAssertEqual(planCalls, 1, "a same-epoch stall is terminal — no retry")
        XCTAssertEqual(stepCalls, 1, "a stalled anchor is rejected immediately — no loop")
        XCTAssertFalse(output.didBackfill,
                       "a rejected stalled step never counts as backfill")
        assertFailClosed(output, afterSeq: 100)
    }

    func testIncompleteCoverageFailsClosed() {
        let hub = AgentEventHub()
        hub.publish(makeEvent(seq: 300, text: "live-300"))
        var planCalls = 0
        var stepCalls = 0

        let output = runAfter(hub: hub,
                              limit: 3,
                              afterSeq: 100,
                              plan: { _, _, expected in
                                  planCalls += 1
                                  return AgentAfterCursorPlan(
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

        XCTAssertEqual(planCalls, 1, "same-epoch incomplete coverage is terminal — no retry")
        XCTAssertEqual(stepCalls, 2)
        XCTAssertTrue(output.didBackfill,
                      "one ACCEPTED advanced step counts as backfill even when coverage later fails")
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
        // The cache sits ABOVE the cursor: only the union authority — never
        // shared history — keeps it out of the payload.
        hub.replaceHistoricalEvents(sessionID: "session",
                                    events: (155...165).map { makeEvent(seq: $0, text: "deep-\($0)") })
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

    private func makeEvent(id: String,
                           seq: Int,
                           text: String,
                           workspaceID: String = "workspace",
                           sessionID: String = "session") -> AgentEvent {
        AgentEvent(eventID: id,
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

    // MARK: G3b/B13 requested-identity filter

    func testRequestOwnedPageFiltersCurrentWorkspaceAndSessionAfterBindingChange() {
        let hub = AgentEventHub()

        let output = runAfter(hub: hub,
                              workspaceID: "current-workspace",
                              limit: 10,
                              afterSeq: 100,
                              plan: { _, _, expected in
                                  // The session migrates AFTER the lease
                                  // began: the CURRENT binding must be
                                  // applied before the identity filter.
                                  hub.migrateSession(sessionID: "session",
                                                     toWorkspaceID: "current-workspace",
                                                     panelID: "current-panel")
                                  return AgentAfterCursorPlan(
                                      epoch: expected,
                                      mode: .scan(from: self.anchor(hub, at: 5_000)))
                              },
                              step: { _, stepAnchor, _, _ in
                                  AgentAfterCursorStep(
                                      epoch: stepAnchor.epoch,
                                      outcome: .complete,
                                      events: [
                                          self.makeEvent(id: "z", seq: 150, text: "legit-z",
                                                         workspaceID: "old-workspace"),
                                          self.makeEvent(id: "a", seq: 150, text: "legit-a",
                                                         workspaceID: "old-workspace"),
                                          self.makeEvent(id: "foreign", seq: 151, text: "foreign",
                                                         workspaceID: "current-workspace",
                                                         sessionID: "other-session"),
                                      ])
                              })

        XCTAssertEqual(output.fetchResult.events.map(\.eventID), ["a", "z"],
                       "only the requested identity survives, in stable (seq,eventID) order")
        for event in output.fetchResult.events {
            XCTAssertEqual(event.workspaceID, "current-workspace",
                           "the CURRENT binding is applied before the filter")
            XCTAssertEqual(event.sessionID, "session")
            XCTAssertEqual(event.metadata?["panel_id"], "current-panel")
        }
    }

    func testForeignRawCandidatesCannotOverwriteOrCrowdOutRequestedIdentity() {
        let hub = AgentEventHub()

        let output = runAfter(hub: hub,
                              limit: 2,
                              afterSeq: 100,
                              plan: { _, _, expected in
                                  AgentAfterCursorPlan(
                                      epoch: expected,
                                      mode: .scan(from: self.anchor(hub, at: 5_000)))
                              },
                              step: { _, stepAnchor, _, _ in
                                  AgentAfterCursorStep(
                                      epoch: stepAnchor.epoch,
                                      outcome: .complete,
                                      events: [
                                          self.makeEvent(id: "shared", seq: 104, text: "legit-shared"),
                                          self.makeEvent(id: "requested-b", seq: 105, text: "legit-b"),
                                          self.makeEvent(id: "f1", seq: 101, text: "foreign-1",
                                                         sessionID: "other-session"),
                                          self.makeEvent(id: "f2", seq: 102, text: "foreign-2",
                                                         sessionID: "other-session"),
                                          // ABOVE the cursor so it reaches
                                          // the identity gate itself — an
                                          // eventID collision with the legit
                                          // "shared" copy.
                                          self.makeEvent(id: "shared", seq: 103, text: "foreign-shared",
                                                         sessionID: "other-session"),
                                          self.makeEvent(id: "f3", seq: 103, text: "foreign-3",
                                                         sessionID: "other-session"),
                                      ])
                              })

        XCTAssertEqual(output.fetchResult.events.map(\.eventID), ["shared", "requested-b"],
                       "foreign session events can neither overwrite nor crowd out requested history")
        XCTAssertEqual(output.fetchResult.events.map(\.seq), [104, 105])
        XCTAssertEqual(output.fetchResult.events.first?.text, "legit-shared",
                       "the foreign collision copy must not overwrite the requested copy")
        XCTAssertTrue(output.fetchResult.events.allSatisfy { $0.sessionID == "session" })
        XCTAssertFalse(output.fetchResult.hasMore,
                       "excluded foreign candidates never count as truncation")
    }

    func testRequestOwnedPageRejectsForeignWorkspaceWithoutCurrentBinding() {
        let hub = AgentEventHub()

        let output = runAfter(hub: hub,
                              limit: 10,
                              afterSeq: 100,
                              plan: { _, _, expected in
                                  AgentAfterCursorPlan(
                                      epoch: expected,
                                      mode: .scan(from: self.anchor(hub, at: 5_000)))
                              },
                              step: { _, stepAnchor, _, _ in
                                  AgentAfterCursorStep(
                                      epoch: stepAnchor.epoch,
                                      outcome: .complete,
                                      events: [
                                          self.makeEvent(id: "home", seq: 101, text: "home"),
                                          self.makeEvent(id: "away", seq: 102, text: "away",
                                                         workspaceID: "other-workspace"),
                                      ])
                              })

        XCTAssertEqual(output.fetchResult.events.map(\.eventID), ["home"],
                       "without a current binding the exact requested workspace still filters")
        XCTAssertEqual(output.fetchResult.oldestSeq, 101)
        XCTAssertEqual(output.fetchResult.newestSeq, 101)
        XCTAssertFalse(output.fetchResult.hasMore)
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
