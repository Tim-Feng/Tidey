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

    func testBeforeCursorRejectsStaleMoreEpochAfterBackfill() {
        let hub = AgentEventHub()
        let oldEpoch = hub.currentHistoryEpoch(sessionID: "session")

        let output = BridgeAgentEventFetchFlow.run(
            eventHub: hub,
            workspaceID: "workspace",
            sessionID: "session",
            limit: 3,
            beforeSeq: 100,
            afterSeq: nil,
            beforeCursorBackfill: { sessionID, _, _ in
                hub.beginNewSourceEpoch(sessionID: sessionID)
                return AgentBeforeCursorBackfillResult(didBackfill: true,
                                                       rawContinuation: .more,
                                                       authorityEpoch: oldEpoch)
            })

        XCTAssertTrue(output.beforeCursorUnavailable,
                      "source A continuation cannot authorize a source B refetch")
        XCTAssertTrue(output.fetchResult.events.isEmpty)
    }

    func testBeforeCursorRejectsStaleEndEpochAfterBackfill() {
        let hub = AgentEventHub()
        let oldEpoch = hub.currentHistoryEpoch(sessionID: "session")

        let output = BridgeAgentEventFetchFlow.run(
            eventHub: hub,
            workspaceID: "workspace",
            sessionID: "session",
            limit: 3,
            beforeSeq: 100,
            afterSeq: nil,
            beforeCursorBackfill: { sessionID, _, _ in
                hub.beginNewSourceEpoch(sessionID: sessionID)
                return AgentBeforeCursorBackfillResult(didBackfill: false,
                                                       rawContinuation: .end,
                                                       authorityEpoch: oldEpoch)
            })

        XCTAssertTrue(output.beforeCursorUnavailable,
                      "source A BOF cannot authorize an empty source B refetch")
        XCTAssertTrue(output.fetchResult.events.isEmpty)
    }

    func testBeforeCursorRejectsEmptyMorePage() {
        let hub = AgentEventHub()
        let epoch = hub.currentHistoryEpoch(sessionID: "session")

        let output = BridgeAgentEventFetchFlow.run(
            eventHub: hub,
            workspaceID: "workspace",
            sessionID: "session",
            limit: 3,
            beforeSeq: 100,
            afterSeq: nil,
            beforeCursorBackfill: { _, _, _ in
                AgentBeforeCursorBackfillResult(didBackfill: false,
                                                rawContinuation: .more,
                                                authorityEpoch: epoch)
            })

        XCTAssertTrue(output.beforeCursorUnavailable,
                      "a nonterminal page without a retreating public cursor must fail closed")
        XCTAssertTrue(output.fetchResult.events.isEmpty)
    }

    func testBeforeCursorRejectsMoreWithoutAuthorityEpoch() {
        let hub = AgentEventHub()
        hub.replaceHistoricalEvents(
            sessionID: "session",
            events: (97...99).map { makeEvent(seq: $0, text: "near-\($0)") },
            anchorSeq: 100)

        let output = BridgeAgentEventFetchFlow.run(
            eventHub: hub,
            workspaceID: "workspace",
            sessionID: "session",
            limit: 3,
            beforeSeq: 100,
            afterSeq: nil,
            beforeCursorBackfill: { _, _, _ in
                AgentBeforeCursorBackfillResult(didBackfill: true,
                                                rawContinuation: .more)
            })

        XCTAssertTrue(output.beforeCursorUnavailable,
                      "typed source authority must carry its Hub epoch")
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

    // MARK: B21 concurrent history request ownership matrix
    //
    // Contract (G1b): the WHOLE same-session history flow serializes
    // through the per-session transaction gate. "Independent ownership"
    // means concurrently launched callers queue and each receives its own
    // exact result — never that two same-session walks run simultaneously.
    // Deterministic order pinned in every same-session test:
    //   A seam entered/blocking → B contention observed with B's seam
    //   count still 0 → release A → B's seam eventually enters.
    // Caller-side output writes are NOT ordered against B's gate acquire
    // (the gate unlocks in the transaction body's defer, before `run`
    // returns) — A's non-contamination is proven by A's exact output.

    private final class LockedCounters: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = [String: Int]()
        func increment(_ key: String) {
            lock.lock()
            storage[key, default: 0] += 1
            lock.unlock()
        }
        func value(_ key: String) -> Int {
            lock.lock()
            defer { lock.unlock() }
            return storage[key] ?? 0
        }
    }

    private final class LockedBox<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Value?
        func set(_ value: Value) {
            lock.lock()
            stored = value
            lock.unlock()
        }
        var value: Value? {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
    }

    // A. Same-session before → before.
    func testConcurrentSameSessionBeforeRequestsSerializeThroughFinalFetch() {
        let hub = AgentEventHub()
        defer { hub.historicalRequestContentionHookForTesting = nil }
        // Live seed: the session must exist in the Hub live buffer for the
        // before path to serve; seq 100 sits AT the first cursor and is
        // excluded from both results.
        hub.publish(makeEvent(id: "live-seed-100", seq: 100, text: "live-seed-100"))
        let aEntered = DispatchSemaphore(value: 0)
        let releaseA = DispatchSemaphore(value: 0)
        let bContended = DispatchSemaphore(value: 0)
        let counters = LockedCounters()
        let aReleaseWait = LockedBox<DispatchTimeoutResult>()
        let aOutput = LockedBox<BridgeAgentEventFetchFlow.Output>()
        let bOutput = LockedBox<BridgeAgentEventFetchFlow.Output>()
        let aDone = expectation(description: "A completed")
        let bDone = expectation(description: "B completed")
        hub.historicalRequestContentionHookForTesting = { sessionID in
            if sessionID == "session" { bContended.signal() }
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let output = BridgeAgentEventFetchFlow.run(eventHub: hub,
                                                       workspaceID: "workspace",
                                                       sessionID: "session",
                                                       limit: 3,
                                                       beforeSeq: 100,
                                                       afterSeq: nil) { _, beforeSeq, _ in
                counters.increment("aBackfill")
                hub.replaceHistoricalEvents(
                    sessionID: "session",
                    events: (97...99).map { self.makeEvent(id: "first-\($0)", seq: $0, text: "first-\($0)") },
                    anchorSeq: beforeSeq)
                aEntered.signal()
                aReleaseWait.set(releaseA.wait(timeout: .now() + 5.0))
                return true
            }
            aOutput.set(output)
            aDone.fulfill()
        }
        let aEnteredResult = aEntered.wait(timeout: .now() + 2.0)
        guard aEnteredResult == .success else {
            releaseA.signal()
            wait(for: [aDone], timeout: 5.0)
            return XCTFail("A never entered its backfill seam")
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let output = BridgeAgentEventFetchFlow.run(eventHub: hub,
                                                       workspaceID: "workspace",
                                                       sessionID: "session",
                                                       limit: 3,
                                                       beforeSeq: 50,
                                                       afterSeq: nil) { _, beforeSeq, _ in
                counters.increment("bBackfill")
                hub.replaceHistoricalEvents(
                    sessionID: "session",
                    events: (47...49).map { self.makeEvent(id: "second-\($0)", seq: $0, text: "second-\($0)") },
                    anchorSeq: beforeSeq)
                return true
            }
            bOutput.set(output)
            bDone.fulfill()
        }
        let bContendedResult = bContended.wait(timeout: .now() + 2.0)
        let bBackfillsAtContention = counters.value("bBackfill")
        guard bContendedResult == .success else {
            releaseA.signal()
            wait(for: [aDone, bDone], timeout: 5.0)
            return XCTFail("B never contended on the session gate")
        }
        XCTAssertEqual(bBackfillsAtContention, 0,
                       "B's backfill seam has NOT entered while A holds the gate")
        releaseA.signal()
        wait(for: [aDone, bDone], timeout: 5.0)
        XCTAssertEqual(aReleaseWait.value, .success, "A's release wait completed")
        XCTAssertEqual(counters.value("aBackfill"), 1)
        XCTAssertEqual(counters.value("bBackfill"), 1,
                       "B's seam entered after the release — the queued caller still ran")
        guard let a = aOutput.value, let b = bOutput.value else {
            return XCTFail("both outputs captured")
        }
        XCTAssertTrue(a.didBackfill)
        XCTAssertTrue(b.didBackfill)
        XCTAssertEqual(a.fetchResult.events.map(\.eventID), ["first-97", "first-98", "first-99"])
        XCTAssertEqual(a.fetchResult.events.compactMap(\.text), ["first-97", "first-98", "first-99"])
        XCTAssertEqual(b.fetchResult.events.map(\.eventID), ["second-47", "second-48", "second-49"])
        XCTAssertEqual(b.fetchResult.events.compactMap(\.text), ["second-47", "second-48", "second-49"])
        XCTAssertFalse(a.fetchResult.events.contains { $0.eventID.hasPrefix("second-") })
        XCTAssertFalse(b.fetchResult.events.contains { $0.eventID.hasPrefix("first-") })
    }

    // B. Different sessions never share a global gate: a typed AFTER flow
    // for session-b completes while session-a's before flow holds its own
    // gate — and BOTH requests are real, fully asserted history requests.
    // Timeout ladder: A's blocked release allowance (15s) far exceeds B's
    // while-A-blocked liveness wait (5s), so a B "success" cannot be A
    // timing out and freeing the gate first.
    func testConcurrentHistoryRequestsForDifferentSessionsDoNotShareGate() {
        let hub = AgentEventHub()
        // Live seeds: replaceHistoricalEvents rejects rows for a session
        // with no stored high-water, so BOTH sessions need one. Cursor 100
        // excludes session-a's seed from its result.
        hub.publish(makeEvent(id: "a-live-100", seq: 100, text: "a-live-100",
                              workspaceID: "workspace-a", sessionID: "session-a"))
        hub.publish(makeEvent(id: "b-live-160", seq: 160, text: "b-live-160",
                              workspaceID: "workspace-b", sessionID: "session-b"))
        let aEntered = DispatchSemaphore(value: 0)
        let releaseA = DispatchSemaphore(value: 0)
        let aCompleted = DispatchSemaphore(value: 0)
        let bCompleted = DispatchSemaphore(value: 0)
        let counters = LockedCounters()
        let aReleaseWait = LockedBox<DispatchTimeoutResult>()
        let aOutput = LockedBox<BridgeAgentEventFetchFlow.Output>()
        let bOutput = LockedBox<BridgeAgentEventFetchFlow.Output>()

        DispatchQueue.global(qos: .userInitiated).async {
            let output = BridgeAgentEventFetchFlow.run(eventHub: hub,
                                                       workspaceID: "workspace-a",
                                                       sessionID: "session-a",
                                                       limit: 3,
                                                       beforeSeq: 100,
                                                       afterSeq: nil) { _, beforeSeq, _ in
                counters.increment("aBackfill")
                hub.replaceHistoricalEvents(
                    sessionID: "session-a",
                    events: (97...99).map {
                        self.makeEvent(id: "a-\($0)", seq: $0, text: "a-\($0)",
                                       workspaceID: "workspace-a", sessionID: "session-a")
                    },
                    anchorSeq: beforeSeq)
                aEntered.signal()
                aReleaseWait.set(releaseA.wait(timeout: .now() + 15.0))
                return true
            }
            aOutput.set(output)
            aCompleted.signal()
        }
        let aEnteredResult = aEntered.wait(timeout: .now() + 2.0)
        guard aEnteredResult == .success else {
            releaseA.signal()
            let aCleanup = aCompleted.wait(timeout: .now() + 5.0)
            XCTAssertEqual(aCleanup, .success, "A worker joined during cleanup")
            return XCTFail("A never entered its backfill seam")
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let output = BridgeAgentEventFetchFlow.run(
                eventHub: hub,
                workspaceID: "workspace-b",
                sessionID: "session-b",
                limit: 10,
                beforeSeq: nil,
                afterSeq: 100,
                afterCursorSeams: .init(
                    plan: { _, _, expected in
                        counters.increment("bPlan")
                        // session-b's OWN epoch anchors the scan.
                        return AgentAfterCursorPlan(
                            epoch: expected,
                            mode: .scan(from: AgentHistoryAnchor(
                                epoch: expected,
                                position: TranscriptEventPosition(lineOffset: 10_000, ordinal: 0))))
                    },
                    step: { _, stepAnchor, _, _ in
                        counters.increment("bStep")
                        return AgentAfterCursorStep(
                            epoch: stepAnchor.epoch,
                            outcome: .complete,
                            events: (101...103).map {
                                self.makeEvent(id: "b-\($0)", seq: $0, text: "b-\($0)",
                                               workspaceID: "workspace-b", sessionID: "session-b")
                            })
                    },
                    validateEpoch: { _, _ in
                        counters.increment("bValidate")
                        return true
                    })) { _, _, _ in
                counters.increment("bLegacyBackfill")
                XCTFail("the legacy backfill closure must not serve a typed after request")
                return false
            }
            bOutput.set(output)
            bCompleted.signal()
        }
        // Liveness: B must COMPLETE (output captured) while A is still
        // blocked inside its 15s allowance.
        let bLiveness = bCompleted.wait(timeout: .now() + 5.0)
        guard bLiveness == .success else {
            releaseA.signal()
            let aCleanup = aCompleted.wait(timeout: .now() + 5.0)
            let bCleanup = bCompleted.wait(timeout: .now() + 5.0)
            XCTAssertEqual(aCleanup, .success, "A worker joined during cleanup")
            XCTAssertEqual(bCleanup, .success, "B worker joined during cleanup")
            return XCTFail("session B's request must run to completion while session A holds ITS gate")
        }
        releaseA.signal()
        let aJoin = aCompleted.wait(timeout: .now() + 5.0)
        XCTAssertEqual(aJoin, .success, "A worker joined after the release")
        XCTAssertEqual(aReleaseWait.value, .success,
                       "A was released by the test, not by its own timeout")

        XCTAssertEqual(counters.value("aBackfill"), 1)
        guard let a = aOutput.value else {
            return XCTFail("A output captured")
        }
        XCTAssertTrue(a.didBackfill)
        XCTAssertFalse(a.fetchResult.hasMore)
        XCTAssertEqual(a.fetchResult.events.map(\.eventID), ["a-97", "a-98", "a-99"],
                       "session A's before page is a real, exact history page")
        XCTAssertEqual(a.fetchResult.oldestSeq, 97)
        XCTAssertEqual(a.fetchResult.newestSeq, 99)
        for event in a.fetchResult.events {
            XCTAssertEqual(event.workspaceID, "workspace-a")
            XCTAssertEqual(event.sessionID, "session-a")
        }

        XCTAssertEqual(counters.value("bPlan"), 1)
        XCTAssertEqual(counters.value("bStep"), 1)
        XCTAssertEqual(counters.value("bValidate"), 1)
        XCTAssertEqual(counters.value("bLegacyBackfill"), 0)
        guard let b = bOutput.value else {
            return XCTFail("B output captured")
        }
        XCTAssertTrue(b.didBackfill)
        XCTAssertFalse(b.fetchResult.hasMore)
        XCTAssertEqual(b.fetchResult.events.map(\.eventID),
                       ["b-101", "b-102", "b-103", "b-live-160"])
        XCTAssertEqual(b.fetchResult.oldestSeq, 101)
        XCTAssertEqual(b.fetchResult.newestSeq, 160)
        for event in b.fetchResult.events {
            XCTAssertEqual(event.workspaceID, "workspace-b")
            XCTAssertEqual(event.sessionID, "session-b")
        }
    }

    // C. Same-session before → after: the queued AFTER page stays
    // request-owned and never absorbs the shared-cache before page.
    func testConcurrentSameSessionBeforeThenAfterKeepsAfterPageRequestOwned() {
        let hub = AgentEventHub()
        defer { hub.historicalRequestContentionHookForTesting = nil }
        hub.publish(makeEvent(id: "live-160", seq: 160, text: "live-160"))
        let aEntered = DispatchSemaphore(value: 0)
        let releaseA = DispatchSemaphore(value: 0)
        let bContended = DispatchSemaphore(value: 0)
        let counters = LockedCounters()
        let aReleaseWait = LockedBox<DispatchTimeoutResult>()
        let aOutput = LockedBox<BridgeAgentEventFetchFlow.Output>()
        let bOutput = LockedBox<BridgeAgentEventFetchFlow.Output>()
        let aDone = expectation(description: "A completed")
        let bDone = expectation(description: "B completed")
        hub.historicalRequestContentionHookForTesting = { sessionID in
            if sessionID == "session" { bContended.signal() }
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let output = BridgeAgentEventFetchFlow.run(eventHub: hub,
                                                       workspaceID: "workspace",
                                                       sessionID: "session",
                                                       limit: 3,
                                                       beforeSeq: 100,
                                                       afterSeq: nil) { _, beforeSeq, _ in
                counters.increment("aBackfill")
                hub.replaceHistoricalEvents(
                    sessionID: "session",
                    events: (61...63).map { self.makeEvent(id: "before-\($0)", seq: $0, text: "before-\($0)") },
                    anchorSeq: beforeSeq)
                aEntered.signal()
                aReleaseWait.set(releaseA.wait(timeout: .now() + 5.0))
                return true
            }
            aOutput.set(output)
            aDone.fulfill()
        }
        let aEnteredResult = aEntered.wait(timeout: .now() + 2.0)
        guard aEnteredResult == .success else {
            releaseA.signal()
            wait(for: [aDone], timeout: 5.0)
            return XCTFail("A never entered its backfill seam")
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let output = BridgeAgentEventFetchFlow.run(
                eventHub: hub,
                workspaceID: "workspace",
                sessionID: "session",
                limit: 10,
                beforeSeq: nil,
                afterSeq: 50,
                afterCursorSeams: .init(
                    plan: { _, _, expected in
                        counters.increment("bPlan")
                        return AgentAfterCursorPlan(
                            epoch: expected,
                            mode: .scan(from: AgentHistoryAnchor(
                                epoch: expected,
                                position: TranscriptEventPosition(lineOffset: 10_000, ordinal: 0))))
                    },
                    step: { _, stepAnchor, _, _ in
                        counters.increment("bStep")
                        return AgentAfterCursorStep(
                            epoch: stepAnchor.epoch,
                            outcome: .complete,
                            events: (51...53).map {
                                self.makeEvent(id: "after-\($0)", seq: $0, text: "after-\($0)")
                            })
                    },
                    validateEpoch: { _, _ in
                        counters.increment("bValidate")
                        return true
                    })) { _, _, _ in
                counters.increment("bLegacyBackfill")
                XCTFail("the legacy backfill closure must not serve a typed after request")
                return false
            }
            bOutput.set(output)
            bDone.fulfill()
        }
        let bContendedResult = bContended.wait(timeout: .now() + 2.0)
        let bPlansAtContention = counters.value("bPlan")
        guard bContendedResult == .success else {
            releaseA.signal()
            wait(for: [aDone, bDone], timeout: 5.0)
            return XCTFail("B never contended on the session gate")
        }
        XCTAssertEqual(bPlansAtContention, 0,
                       "B's plan seam has NOT entered while A holds the gate")
        releaseA.signal()
        wait(for: [aDone, bDone], timeout: 5.0)
        XCTAssertEqual(aReleaseWait.value, .success)
        XCTAssertEqual(counters.value("aBackfill"), 1)
        XCTAssertEqual(counters.value("bPlan"), 1)
        XCTAssertEqual(counters.value("bStep"), 1)
        XCTAssertEqual(counters.value("bValidate"), 1)
        XCTAssertEqual(counters.value("bLegacyBackfill"), 0)
        guard let a = aOutput.value, let b = bOutput.value else {
            return XCTFail("both outputs captured")
        }
        XCTAssertTrue(a.didBackfill)
        XCTAssertEqual(a.fetchResult.events.map(\.eventID),
                       ["before-61", "before-62", "before-63"],
                       "A's before page holds exactly its own rows")
        XCTAssertTrue(b.didBackfill)
        XCTAssertFalse(b.fetchResult.hasMore)
        XCTAssertEqual(b.fetchResult.events.map(\.eventID),
                       ["after-51", "after-52", "after-53", "live-160"],
                       "B's after page is request-owned plus its lease window")
        XCTAssertFalse(b.fetchResult.events.contains { $0.eventID.hasPrefix("before-") },
                       "the shared-cache before page never enters the after response")
    }

    // D. Same-session after → before: the blocked after walk keeps its
    // request-owned page and its lease captures live publishes that the
    // history gate must not block.
    func testConcurrentSameSessionAfterThenBeforeKeepsAfterPageOwned() {
        let hub = AgentEventHub()
        defer { hub.historicalRequestContentionHookForTesting = nil }
        hub.publish(makeEvent(id: "live-160", seq: 160, text: "live-160"))
        let aEntered = DispatchSemaphore(value: 0)
        let releaseA = DispatchSemaphore(value: 0)
        let bContended = DispatchSemaphore(value: 0)
        let counters = LockedCounters()
        let aReleaseWait = LockedBox<DispatchTimeoutResult>()
        let aOutput = LockedBox<BridgeAgentEventFetchFlow.Output>()
        let bOutput = LockedBox<BridgeAgentEventFetchFlow.Output>()
        let aDone = expectation(description: "A completed")
        let bDone = expectation(description: "B completed")
        hub.historicalRequestContentionHookForTesting = { sessionID in
            if sessionID == "session" { bContended.signal() }
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let output = BridgeAgentEventFetchFlow.run(
                eventHub: hub,
                workspaceID: "workspace",
                sessionID: "session",
                limit: 10,
                beforeSeq: nil,
                afterSeq: 50,
                afterCursorSeams: .init(
                    plan: { _, _, expected in
                        counters.increment("aPlan")
                        return AgentAfterCursorPlan(
                            epoch: expected,
                            mode: .scan(from: AgentHistoryAnchor(
                                epoch: expected,
                                position: TranscriptEventPosition(lineOffset: 10_000, ordinal: 0))))
                    },
                    step: { _, stepAnchor, _, _ in
                        counters.increment("aStep")
                        if counters.value("aStep") == 1 {
                            aEntered.signal()
                            aReleaseWait.set(releaseA.wait(timeout: .now() + 5.0))
                            return AgentAfterCursorStep(
                                epoch: stepAnchor.epoch,
                                outcome: .advanced(AgentHistoryAnchor(
                                    epoch: stepAnchor.epoch,
                                    position: TranscriptEventPosition(lineOffset: 5_000, ordinal: 0))),
                                events: [self.makeEvent(id: "after-a-52", seq: 52, text: "after-a-52")])
                        }
                        return AgentAfterCursorStep(
                            epoch: stepAnchor.epoch,
                            outcome: .complete,
                            events: [self.makeEvent(id: "after-a-51", seq: 51, text: "after-a-51"),
                                     self.makeEvent(id: "after-a-53", seq: 53, text: "after-a-53")])
                    },
                    validateEpoch: { _, _ in
                        counters.increment("aValidate")
                        return true
                    })) { _, _, _ in
                counters.increment("aLegacyBackfill")
                XCTFail("the legacy backfill closure must not serve a typed after request")
                return false
            }
            aOutput.set(output)
            aDone.fulfill()
        }
        let aEnteredResult = aEntered.wait(timeout: .now() + 2.0)
        guard aEnteredResult == .success else {
            releaseA.signal()
            wait(for: [aDone], timeout: 5.0)
            return XCTFail("A never entered its step seam")
        }
        // Live publish while A blocks INSIDE its step: the history gate
        // must not block Hub publishes, and A's lease must capture it.
        hub.publish(makeEvent(id: "live-161", seq: 161, text: "live-161"))

        DispatchQueue.global(qos: .userInitiated).async {
            let output = BridgeAgentEventFetchFlow.run(eventHub: hub,
                                                       workspaceID: "workspace",
                                                       sessionID: "session",
                                                       limit: 10,
                                                       beforeSeq: 100,
                                                       afterSeq: nil) { _, beforeSeq, _ in
                counters.increment("bBackfill")
                hub.replaceHistoricalEvents(
                    sessionID: "session",
                    events: (61...63).map { self.makeEvent(id: "before-b-\($0)", seq: $0, text: "before-b-\($0)") },
                    anchorSeq: beforeSeq)
                return true
            }
            bOutput.set(output)
            bDone.fulfill()
        }
        let bContendedResult = bContended.wait(timeout: .now() + 2.0)
        let bBackfillsAtContention = counters.value("bBackfill")
        guard bContendedResult == .success else {
            releaseA.signal()
            wait(for: [aDone, bDone], timeout: 5.0)
            return XCTFail("B never contended on the session gate")
        }
        XCTAssertEqual(bBackfillsAtContention, 0,
                       "B's backfill seam has NOT entered while A holds the gate")
        releaseA.signal()
        wait(for: [aDone, bDone], timeout: 5.0)
        XCTAssertEqual(aReleaseWait.value, .success)
        XCTAssertEqual(counters.value("aPlan"), 1)
        XCTAssertEqual(counters.value("aStep"), 2)
        XCTAssertEqual(counters.value("aValidate"), 1)
        XCTAssertEqual(counters.value("aLegacyBackfill"), 0)
        XCTAssertEqual(counters.value("bBackfill"), 1)
        guard let a = aOutput.value, let b = bOutput.value else {
            return XCTFail("both outputs captured")
        }
        XCTAssertTrue(a.didBackfill)
        XCTAssertFalse(a.fetchResult.hasMore)
        XCTAssertEqual(a.fetchResult.events.map(\.eventID),
                       ["after-a-51", "after-a-52", "after-a-53", "live-160", "live-161"],
                       "A owns its raw page and its lease captured the mid-walk live publish")
        XCTAssertEqual(a.fetchResult.oldestSeq, 51)
        XCTAssertEqual(a.fetchResult.newestSeq, 161)
        XCTAssertTrue(b.didBackfill)
        XCTAssertFalse(b.fetchResult.hasMore)
        XCTAssertEqual(b.fetchResult.events.map(\.eventID),
                       ["before-b-61", "before-b-62", "before-b-63"])
        XCTAssertEqual(b.fetchResult.oldestSeq, 61)
        XCTAssertEqual(b.fetchResult.newestSeq, 63)
        XCTAssertFalse(a.fetchResult.events.contains { $0.eventID.hasPrefix("before-b-") })
        XCTAssertFalse(b.fetchResult.events.contains { $0.eventID.hasPrefix("after-a-") })
    }

    // E. Same-session after → after: queued walks keep independent
    // accumulators and lease snapshots (the gate serializes them — this is
    // NOT an active-walk overlap test).
    func testConcurrentAfterWalksKeepIndependentOwnership() {
        let hub = AgentEventHub()
        defer { hub.historicalRequestContentionHookForTesting = nil }
        let aEntered = DispatchSemaphore(value: 0)
        let releaseA = DispatchSemaphore(value: 0)
        let bContended = DispatchSemaphore(value: 0)
        let counters = LockedCounters()
        let aReleaseWait = LockedBox<DispatchTimeoutResult>()
        let aOutput = LockedBox<BridgeAgentEventFetchFlow.Output>()
        let bOutput = LockedBox<BridgeAgentEventFetchFlow.Output>()
        let aDone = expectation(description: "A completed")
        let bDone = expectation(description: "B completed")
        hub.historicalRequestContentionHookForTesting = { sessionID in
            if sessionID == "session" { bContended.signal() }
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let output = BridgeAgentEventFetchFlow.run(
                eventHub: hub,
                workspaceID: "workspace",
                sessionID: "session",
                limit: 10,
                beforeSeq: nil,
                afterSeq: 100,
                afterCursorSeams: .init(
                    plan: { _, _, expected in
                        counters.increment("aPlan")
                        return AgentAfterCursorPlan(
                            epoch: expected,
                            mode: .scan(from: AgentHistoryAnchor(
                                epoch: expected,
                                position: TranscriptEventPosition(lineOffset: 10_000, ordinal: 0))))
                    },
                    step: { _, stepAnchor, _, _ in
                        counters.increment("aStep")
                        if counters.value("aStep") == 1 {
                            aEntered.signal()
                            aReleaseWait.set(releaseA.wait(timeout: .now() + 5.0))
                            return AgentAfterCursorStep(
                                epoch: stepAnchor.epoch,
                                outcome: .advanced(AgentHistoryAnchor(
                                    epoch: stepAnchor.epoch,
                                    position: TranscriptEventPosition(lineOffset: 5_000, ordinal: 0))),
                                events: [self.makeEvent(id: "request-a-130", seq: 130, text: "request-a-130")])
                        }
                        return AgentAfterCursorStep(
                            epoch: stepAnchor.epoch,
                            outcome: .complete,
                            events: [self.makeEvent(id: "request-a-131", seq: 131, text: "request-a-131"),
                                     self.makeEvent(id: "request-a-132", seq: 132, text: "request-a-132")])
                    },
                    validateEpoch: { _, _ in
                        counters.increment("aValidate")
                        return true
                    })) { _, _, _ in
                counters.increment("aLegacyBackfill")
                XCTFail("the legacy backfill closure must not serve a typed after request")
                return false
            }
            aOutput.set(output)
            aDone.fulfill()
        }
        let aEnteredResult = aEntered.wait(timeout: .now() + 2.0)
        guard aEnteredResult == .success else {
            releaseA.signal()
            wait(for: [aDone], timeout: 5.0)
            return XCTFail("A never entered its step seam")
        }
        // Shared retained lives, published while A blocks: both requests
        // may legally serve them under their own cursors.
        hub.publish(makeEvent(id: "live-190", seq: 190, text: "live-190"))
        hub.publish(makeEvent(id: "live-191", seq: 191, text: "live-191"))

        DispatchQueue.global(qos: .userInitiated).async {
            let output = BridgeAgentEventFetchFlow.run(
                eventHub: hub,
                workspaceID: "workspace",
                sessionID: "session",
                limit: 10,
                beforeSeq: nil,
                afterSeq: 125,
                afterCursorSeams: .init(
                    plan: { _, _, expected in
                        counters.increment("bPlan")
                        return AgentAfterCursorPlan(
                            epoch: expected,
                            mode: .scan(from: AgentHistoryAnchor(
                                epoch: expected,
                                position: TranscriptEventPosition(lineOffset: 10_000, ordinal: 0))))
                    },
                    step: { _, stepAnchor, _, _ in
                        counters.increment("bStep")
                        return AgentAfterCursorStep(
                            epoch: stepAnchor.epoch,
                            outcome: .complete,
                            events: (126...128).map {
                                self.makeEvent(id: "request-b-\($0)", seq: $0, text: "request-b-\($0)")
                            })
                    },
                    validateEpoch: { _, _ in
                        counters.increment("bValidate")
                        return true
                    })) { _, _, _ in
                counters.increment("bLegacyBackfill")
                XCTFail("the legacy backfill closure must not serve a typed after request")
                return false
            }
            bOutput.set(output)
            bDone.fulfill()
        }
        let bContendedResult = bContended.wait(timeout: .now() + 2.0)
        let bPlansAtContention = counters.value("bPlan")
        guard bContendedResult == .success else {
            releaseA.signal()
            wait(for: [aDone, bDone], timeout: 5.0)
            return XCTFail("B never contended on the session gate")
        }
        XCTAssertEqual(bPlansAtContention, 0,
                       "B's plan seam has NOT entered while A holds the gate")
        releaseA.signal()
        wait(for: [aDone, bDone], timeout: 5.0)
        XCTAssertEqual(aReleaseWait.value, .success)
        XCTAssertEqual(counters.value("aPlan"), 1)
        XCTAssertEqual(counters.value("aStep"), 2)
        XCTAssertEqual(counters.value("aValidate"), 1)
        XCTAssertEqual(counters.value("aLegacyBackfill"), 0)
        XCTAssertEqual(counters.value("bPlan"), 1)
        XCTAssertEqual(counters.value("bStep"), 1)
        XCTAssertEqual(counters.value("bValidate"), 1)
        XCTAssertEqual(counters.value("bLegacyBackfill"), 0)
        guard let a = aOutput.value, let b = bOutput.value else {
            return XCTFail("both outputs captured")
        }
        XCTAssertTrue(a.didBackfill)
        XCTAssertFalse(a.fetchResult.hasMore)
        XCTAssertEqual(a.fetchResult.events.map(\.eventID),
                       ["request-a-130", "request-a-131", "request-a-132", "live-190", "live-191"],
                       "A's page is its own raw walk plus the shared lives above ITS cursor")
        XCTAssertEqual(a.fetchResult.oldestSeq, 130)
        XCTAssertEqual(a.fetchResult.newestSeq, 191)
        XCTAssertTrue(b.didBackfill)
        XCTAssertFalse(b.fetchResult.hasMore)
        XCTAssertEqual(b.fetchResult.events.map(\.eventID),
                       ["request-b-126", "request-b-127", "request-b-128", "live-190", "live-191"],
                       "B's page is its own raw walk plus the shared lives above ITS cursor")
        XCTAssertEqual(b.fetchResult.oldestSeq, 126)
        XCTAssertEqual(b.fetchResult.newestSeq, 191)
        XCTAssertFalse(a.fetchResult.events.contains { $0.eventID.hasPrefix("request-b-") },
                       "no B raw event leaks into A")
        XCTAssertFalse(b.fetchResult.events.contains { $0.eventID.hasPrefix("request-a-") },
                       "no A raw event leaks into B — A's raw seqs all sit above B's cursor, a shared accumulator would show them")
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

    func testAdvancedNextAnchorEpochMismatchRetriesOnceWithoutAcceptingStep() {
        let hub = AgentEventHub()
        hub.publish(makeEvent(seq: 101, text: "live-101"))
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
                                  // step.epoch is valid, but the NEXT anchor
                                  // crosses epochs: the whole step is
                                  // rejected and the attempt retries.
                                  return AgentAfterCursorStep(
                                      epoch: stepAnchor.epoch,
                                      outcome: .advanced(AgentHistoryAnchor(
                                          epoch: AgentHistoryEpoch(sessionID: "session",
                                                                   generation: stepAnchor.epoch.generation &+ 99),
                                          position: TranscriptEventPosition(lineOffset: 4_000, ordinal: 0))),
                                      events: [self.makeEvent(id: "stale", seq: 150, text: "stale")])
                              })

        XCTAssertEqual(planCalls, 2)
        XCTAssertEqual(stepCalls, 1)
        XCTAssertEqual(output.fetchResult.events.compactMap(\.text), ["live-101"],
                       "only the retry attempt's lease window is served — the stale step event must not leak")
        XCTAssertFalse(output.didBackfill,
                       "an epoch-crossing next anchor rejects the whole step — it is never accepted")
        XCTAssertEqual(output.fetchResult.oldestSeq, 101)
        XCTAssertEqual(output.fetchResult.newestSeq, 101)
        XCTAssertFalse(output.fetchResult.hasMore)
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
