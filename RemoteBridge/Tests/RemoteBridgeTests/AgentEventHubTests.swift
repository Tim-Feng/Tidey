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

    // Round 7G P0 (TOCTOU addendum): `publish`'s return value is the ONE
    // contract every reserve-then-publish boundary caller (Claude/Codex
    // start() and beginNewSourceEpoch()) relies on to seed its own local
    // sequence base — it must be the ACTUAL stored seq (reflecting any
    // rebase-on-collision), never the caller's pre-publish claimed seq.
    func testPublishReturnsActualRebasedSeqNotClaimedSeqOnCollision() {
        let hub = AgentEventHub()
        let reserved = hub.nextSyntheticSeq(sessionID: "session")
        hub.publish(makeAssistantEvent(id: "native", seq: reserved))
        let actual = hub.publish(makeAssistantEvent(id: "synthetic", seq: reserved))

        XCTAssertNotEqual(actual, reserved,
                          "a caller trusting the pre-publish reservation instead of this return value would desync its local base from what the Hub actually stored")
        XCTAssertEqual(actual, reserved + 1)

        let all = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 10)
        XCTAssertEqual(all.events.first(where: { $0.eventID == "synthetic" })?.seq, actual,
                       "the returned seq must be exactly what the Hub actually stored/fetches back")
    }

    // A boundary caller establishing a NEW local sequence base must fail
    // closed (never advance from the claimed/reserved seq) when the Hub
    // reports the event was NOT genuinely stored at all — a duplicate
    // eventID publish is the simplest reproduction of "not stored."
    func testPublishReturnsNilWhenDuplicateEventIDIsNotGenuinelyStored() {
        let hub = AgentEventHub()
        let first = hub.publish(makeAssistantEvent(id: "dup", seq: 5))
        XCTAssertEqual(first, 5)

        let second = hub.publish(makeAssistantEvent(id: "dup", seq: 5))
        XCTAssertNil(second,
                    "a duplicate eventID is not stored — the return value must be nil, never a seq a caller could mistake for a genuine store")

        let all = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 10)
        XCTAssertEqual(all.events.count, 1, "the duplicate must have zero storage side effects")
    }

    // Round 7G addendum: `.historicalBackfill` publishes return from inside
    // `queue.sync` BEFORE the live-only `wasStored = true` line runs (it
    // never reaches live delivery/the postStoreDeliveryHook), but a
    // genuinely-accepted historical event IS a real store — the return
    // value contract ("nil only when NOT genuinely stored") must hold for
    // this branch too, using its OWN seq, never the live-forward `nil`.
    func testHistoricalBackfillPublishReturnsItsOwnStoredSeqOnAcceptance() {
        let hub = AgentEventHub()
        hub.publish(makeAssistantEvent(id: "live-anchor", seq: 100))

        let historicalSeq = hub.publish(makeAssistantEvent(id: "historical-1", seq: 50),
                                        storage: .historicalBackfill)
        XCTAssertEqual(historicalSeq, 50,
                       "a genuinely-accepted historical event must report its own seq, not nil")

        let stored = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 10, beforeSeq: 100)
        XCTAssertTrue(stored.events.contains { $0.eventID == "historical-1" })
    }

    func testHistoricalBackfillPublishReturnsNilWhenRejectedAtOrAboveHighWater() {
        let hub = AgentEventHub()
        hub.publish(makeAssistantEvent(id: "live-anchor", seq: 100))

        // At the live high-water — rejected (history must sit STRICTLY below).
        let atHighWater = hub.publish(makeAssistantEvent(id: "historical-at", seq: 100),
                                      storage: .historicalBackfill)
        XCTAssertNil(atHighWater, "a historical event at the live high-water must be rejected, never a fake seq")

        // Above the live high-water — also rejected.
        let aboveHighWater = hub.publish(makeAssistantEvent(id: "historical-above", seq: 150),
                                         storage: .historicalBackfill)
        XCTAssertNil(aboveHighWater, "a historical event above the live high-water must be rejected, never a fake seq")

        let stored = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 10, beforeSeq: 200)
        XCTAssertFalse(stored.events.contains { $0.eventID == "historical-at" || $0.eventID == "historical-above" },
                       "a rejected historical event must have zero storage side effects")
    }

    func testHistoricalBackfillPublishReturnsNilOnDuplicateEventID() {
        let hub = AgentEventHub()
        hub.publish(makeAssistantEvent(id: "live-anchor", seq: 100))
        let first = hub.publish(makeAssistantEvent(id: "historical-dup", seq: 50), storage: .historicalBackfill)
        XCTAssertEqual(first, 50)

        let second = hub.publish(makeAssistantEvent(id: "historical-dup", seq: 50), storage: .historicalBackfill)
        XCTAssertNil(second, "a duplicate historical eventID is not genuinely (re-)stored — must be nil")
    }

    // A genuinely-stored historical event must NEVER reach live delivery or
    // the (live-only) postStoreDeliveryHook — the return-value fix above
    // must not blur that boundary.
    func testHistoricalBackfillPublishNeverTriggersLiveDeliveryOrPostStoreHook() {
        let hub = AgentEventHub()
        hub.publish(makeAssistantEvent(id: "live-anchor", seq: 100))

        var hookFired = false
        hub.postStoreDeliveryHook = { _ in hookFired = true }
        var liveDelivered = [String]()
        let (subscriptionID, _) = hub.subscribe(workspaceID: "workspace", sessionID: "session") { envelope in
            liveDelivered.append(envelope.event.eventID)
        }
        defer { hub.unsubscribe(subscriptionID) }

        let historicalSeq = hub.publish(makeAssistantEvent(id: "historical-quiet", seq: 50),
                                        storage: .historicalBackfill)
        XCTAssertEqual(historicalSeq, 50)
        hub.drainDeliveriesForTesting()

        XCTAssertFalse(hookFired, "postStoreDeliveryHook is live-only and must not fire for historical storage")
        XCTAssertTrue(liveDelivered.isEmpty, "historical storage must never reach live subscribers")
    }

    // Shared deterministic competing-producer coverage for every path that
    // establishes `transcriptSequenceBase` from a boundary/start seq —
    // ClaudeTranscriptSession.start/beginNewSourceEpoch and
    // CodexTranscriptSession.start/beginNewSourceEpoch(publishSynthetic) all
    // share this EXACT reserve-then-publish shape against the same Hub.
    // Real concurrency (not a fixed interleaving) exercises the actual race
    // the Round 7G fix closes: two producers reserving a seq for the same
    // sessionID before either has published can legitimately reserve the
    // SAME value — trusting that reservation as a final local base (the
    // pre-fix bug) would desync at least one caller from what the Hub
    // actually stores. Assertions are invariant-based (uniqueness of
    // ACTUAL stored seqs), not timing-based, so this is not flaky even
    // though whether the race window is hit on any given run is not
    // itself asserted.
    func testConcurrentClaudeAndCodexShapedReserveThenPublishNeverDesyncsActualStoredSeqs() {
        let hub = AgentEventHub()
        let sessionID = "shared-session"
        let iterations = 300
        let group = DispatchGroup()
        let resultsLock = NSLock()
        struct Outcome { let reserved: Int; let actual: Int }
        var outcomes: [Outcome] = []

        for i in 0..<iterations {
            group.enter()
            DispatchQueue.global().async {
                let vendor = i % 2 == 0 ? "claude" : "codex"
                // Mirrors the shared shape: reserve, THEN publish claiming
                // that reservation, THEN (in production) seed the local
                // base from publish's RETURN VALUE — never the reservation.
                let reserved = hub.nextSyntheticSeq(sessionID: sessionID)
                let event = AgentEvent(eventID: "boundary-\(vendor)-\(i)",
                                       seq: reserved,
                                       vendor: vendor,
                                       workspaceID: "workspace",
                                       sessionID: sessionID,
                                       timestamp: "2026-01-01T00:00:00Z",
                                       type: .sessionStarted,
                                       role: nil,
                                       text: nil,
                                       name: nil,
                                       input: nil,
                                       output: nil,
                                       toolCallID: nil,
                                       metadata: nil)
                if let actual = hub.publish(event) {
                    resultsLock.lock()
                    outcomes.append(Outcome(reserved: reserved, actual: actual))
                    resultsLock.unlock()
                }
                group.leave()
            }
        }
        group.wait()

        XCTAssertEqual(outcomes.count, iterations,
                       "every uniquely-eventID'd boundary marker must be genuinely stored")

        let actualSeqs = outcomes.map(\.actual)
        XCTAssertEqual(Set(actualSeqs).count, actualSeqs.count,
                       "every genuinely stored boundary marker's ACTUAL seq must stay unique under real concurrent Claude/Codex-shaped reserve-then-publish races")

        let all = hub.fetch(workspaceID: "workspace", sessionID: sessionID, limit: iterations + 10)
        XCTAssertEqual(all.events.count, iterations)
        XCTAssertEqual(Set(all.events.map(\.seq)).count, all.events.count,
                       "the Hub's own stored history must never contain a duplicate seq even under concurrent producers")
    }

    func testBatchTerminalReservationsStayUniqueAgainstInterleavedNativePublishes() {
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

    func testNativeHighSeqThenSyntheticReservationDoesNotCollide() {
        let hub = AgentEventHub()
        hub.publish(makeAssistantEvent(id: "native-high", seq: 100))
        let reserved = hub.nextSyntheticSeq(sessionID: "session")
        XCTAssertGreaterThan(reserved, 100)
        hub.publish(makeAssistantEvent(id: "synthetic", seq: reserved))
        let all = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 10)
        XCTAssertEqual(Set(all.events.map(\.seq)).count, 2)
    }

    func testLateUnseenLowerSeqIsRebasedAboveHighWater() {
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
        XCTAssertEqual(catchUp.events.map(\.eventID), ["late"],
                       "the late event must be reachable after the cursor already reached 100")
        XCTAssertGreaterThan(catchUp.events[0].seq, 100)
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

    // Round 3 item 1: beginNewSourceEpoch wipes bufferedEvents (a source
    // reset's whole point) — with a small buffer capacity forcing eviction,
    // bufferedMax alone would be far BELOW the session's true accepted
    // high-water right after the reset. nextSyntheticSeq must still return a
    // reservation strictly above the RETAINED storedSeqHighWater, never
    // relying on publish()'s hidden rebase-on-collision to fix it up later —
    // a caller minting a cross-epoch boundary seq needs the reservation
    // itself to already be correct.
    func testNextSyntheticSeqAfterBeginNewSourceEpochStaysAboveOldStoredHighWater() {
        let hub = AgentEventHub(maxBufferedEvents: 2, maxSeenEventIDs: 100)
        for i in 1...20 {
            hub.publish(makeAssistantEvent(id: "old-\(i)", seq: i * 10))
        }
        // True accepted high-water is 200 (old-20); the live buffer capacity
        // (2) has already trimmed all but the last couple of events.
        hub.beginNewSourceEpoch(sessionID: "session")
        let next = hub.nextSyntheticSeq(sessionID: "session")
        XCTAssertGreaterThan(next, 200,
                             "the reservation must reflect the RETAINED stored high-water, not just the (wiped) buffer, got \(next)")
    }

    // beginNewSourceEpoch must also clear latestSessionStarted/isActive so a
    // subscriber racing the gap between the reset and the caller's fresh
    // boundary publish is never replayed back into the OLD source's start.
    func testBeginNewSourceEpochClearsStickySessionStartedReplay() {
        let hub = AgentEventHub()
        hub.publish(AgentEvent(eventID: "old-start", seq: 1, vendor: "codex", workspaceID: "workspace",
                               sessionID: "session", timestamp: "2026-01-01T00:00:00Z", type: .sessionStarted,
                               role: nil, text: nil, name: nil, input: nil, output: nil, toolCallID: nil, metadata: nil))
        // Trim the sticky sessionStarted out of the buffer via a full replace.
        hub.beginNewSourceEpoch(sessionID: "session")

        let (subscriptionID, replay) = hub.subscribe(workspaceID: "workspace", sessionID: "session") { _ in }
        defer { hub.unsubscribe(subscriptionID) }
        XCTAssertFalse(replay.contains { $0.event.eventID == "old-start" },
                       "a subscriber joining right after the reset must not be replayed into the OLD source's sessionStarted")
    }

    // A stale workspace/panel binding from a PREVIOUS source incarnation
    // (established via migrateSession, e.g. a resolved-pane-identity
    // rebind) must not survive a beginNewSourceEpoch and silently rewrite
    // the NEW generation's own events — effectiveEvent() applies
    // sessionBindings at READ time, independent of whatever workspace_id
    // the publisher literally stamped, so a leftover binding is invisible
    // at the write call site and only shows up as a wrong workspace_id on
    // fetch.
    func testBeginNewSourceEpochClearsStaleWorkspaceBindingFromPriorGeneration() {
        let hub = AgentEventHub()
        hub.publish(AgentEvent(eventID: "gen-a-event", seq: 1, vendor: "codex", workspaceID: "workspace-old",
                               sessionID: "session", timestamp: "2026-01-01T00:00:00Z", type: .assistantMessage,
                               role: "assistant", text: "from A", name: nil, input: nil, output: nil, toolCallID: nil, metadata: nil))
        // Generation A gets migrated (e.g. a resolved pane-identity rebind).
        _ = hub.migrateSession(sessionID: "session", toWorkspaceID: "workspace-migrated", panelID: nil)
        XCTAssertTrue(hub.fetch(workspaceID: "workspace-migrated", sessionID: "session", limit: 10)
            .events.contains { $0.eventID == "gen-a-event" }, "precondition: the migration binding took effect for A")

        // Generation B starts (a registry monitor stop+recreate reusing the
        // sessionID) — its OWN record's workspace is "workspace-fresh",
        // matching NEITHER of A's workspaces.
        hub.beginNewSourceEpoch(sessionID: "session")
        hub.publish(AgentEvent(eventID: "gen-b-event", seq: 2, vendor: "codex", workspaceID: "workspace-fresh",
                               sessionID: "session", timestamp: "2026-01-01T00:00:01Z", type: .assistantMessage,
                               role: "assistant", text: "from B", name: nil, input: nil, output: nil, toolCallID: nil, metadata: nil))

        let freshFetch = hub.fetch(workspaceID: "workspace-fresh", sessionID: "session", limit: 10)
        XCTAssertTrue(freshFetch.events.contains { $0.eventID == "gen-b-event" },
                      "generation B's own event must be visible under its OWN record's workspace, got \(freshFetch.events.map { ($0.eventID, $0.workspaceID) })")
        let staleFetch = hub.fetch(workspaceID: "workspace-migrated", sessionID: "session", limit: 10)
        XCTAssertFalse(staleFetch.events.contains { $0.eventID == "gen-b-event" },
                       "generation B's event must NOT be silently rewritten to A's stale migrated workspace")
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
        hub.publish(makeAssistantEvent(id: "e1", seq: 1))
        XCTAssertEqual(resolvedButNotInvoked.wait(timeout: .now() + 2.0), .success)

        // Unsubscribe fully RETURNS while the drain is paused pre-invoke.
        hub.unsubscribe(oldID)
        releaseInvoke.signal()
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
        hub.publish(makeAssistantEvent(id: "e1", seq: 1))
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
        wait(for: [unsubscribeReturned], timeout: 2.0)
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

    func testUnseenLiveOldSeqStillRebasedAfterRealEviction() {
        // Small injectable capacities so the buffer/seen trims genuinely run;
        // the high-water must survive eviction and keep rebasing.
        let hub = AgentEventHub(maxBufferedEvents: 8, maxSeenEventIDs: 8)
        for i in 1...32 {
            hub.publish(makeAssistantEvent(id: "e\(i)", seq: i * 10))
        }
        // Buffer now holds only the newest 8 events; the seen set was trimmed
        // several times. A late unseen LIVE event claiming an evicted seq
        // must still be rebased above the high-water.
        hub.publish(makeAssistantEvent(id: "late-old", seq: 15))
        let catchUp = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 10, afterSeq: 320)
        XCTAssertEqual(catchUp.events.map(\.eventID), ["late-old"],
                       "eviction must not resurrect old cursor positions")
        XCTAssertGreaterThan(catchUp.events[0].seq, 320)
    }

    func testSameEventIDOverlayRepublishIsNotTreatedAsNewEvent() {
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
                                 source: String = "codex_command_approval",
                                 submitChannel: String? = "codex_app_server",
                                 turnID: String? = nil) -> AgentEvent {
        var metadata = ["prompt_id": promptID, "source": source]
        if let token {
            metadata["lifecycle_token"] = token
        }
        if let submitChannel {
            metadata["submit_channel"] = submitChannel
        }
        if let turnID {
            metadata["turn_id"] = turnID
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
                                   source: String? = "codex_command_approval",
                                   reason: String = "server_resolved",
                                   turnID: String? = nil,
                                   submitChannel: String? = "codex_app_server") -> AgentEvent {
        var metadata = ["prompt_id": promptID, "reason": reason]
        if let source {
            metadata["source"] = source
        }
        if let token {
            metadata["lifecycle_token"] = token
        }
        if let turnID {
            metadata["turn_id"] = turnID
        }
        if let submitChannel {
            metadata["submit_channel"] = submitChannel
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
                        vendor: "claude", source: "claude_ask_user_question", submitChannel: nil)
    }

    private func legacyTerminal(id: String, seq: Int, promptID: String) -> AgentEvent {
        makeResolvedEvent(id: id, seq: seq, promptID: promptID, token: nil,
                          vendor: "claude", source: "claude_ask_user_question", submitChannel: nil)
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

    // MARK: - Round 7: interactive-prompt-aware Working continuation

    private func makeAnchorThinkingEvent(id: String, seq: Int, turnID: String, reason: String = "task_started") -> AgentEvent {
        AgentEvent(eventID: id, seq: seq, vendor: "codex", workspaceID: "workspace", sessionID: "session",
                  timestamp: "2026-01-01T00:00:00Z", type: .thinking, role: nil, text: nil, name: nil,
                  input: nil, output: nil, toolCallID: nil,
                  metadata: ["turn_id": turnID, "reason": reason])
    }

    private func makeContinuationThinkingEvent(id: String, seq: Int, turnID: String, reason: String = "tool_call") -> AgentEvent {
        AgentEvent(eventID: id, seq: seq, vendor: "codex", workspaceID: "workspace", sessionID: "session",
                  timestamp: "2026-01-01T00:00:00Z", type: .thinking, role: nil, text: nil, name: nil,
                  input: nil, output: nil, toolCallID: nil,
                  metadata: ["turn_id": turnID, "reason": reason, "is_continuation": "true"])
    }

    private func makeToolCallEvent(id: String, seq: Int) -> AgentEvent {
        AgentEvent(eventID: id, seq: seq, vendor: "codex", workspaceID: "workspace", sessionID: "session",
                  timestamp: "2026-01-01T00:00:00Z", type: .toolCall, role: "assistant", text: nil,
                  name: "tool", input: "{}", output: nil, toolCallID: id, metadata: nil)
    }

    private func makeTurnTerminalEvent(id: String, seq: Int, turnID: String) -> AgentEvent {
        AgentEvent(eventID: id, seq: seq, vendor: "codex", workspaceID: "workspace", sessionID: "session",
                  timestamp: "2026-01-01T00:00:00Z", type: .assistantFinal, role: nil, text: nil, name: nil,
                  input: nil, output: nil, toolCallID: nil,
                  metadata: ["turn_id": turnID, "reason": "turn_terminal"])
    }

    private func makeSessionStartedEvent(id: String, seq: Int) -> AgentEvent {
        AgentEvent(eventID: id, seq: seq, vendor: "codex", workspaceID: "workspace", sessionID: "session",
                  timestamp: "2026-01-01T00:00:00Z", type: .sessionStarted, role: nil, text: nil, name: nil,
                  input: nil, output: nil, toolCallID: nil, metadata: nil)
    }

    private func makeSessionEndedEvent(id: String, seq: Int) -> AgentEvent {
        AgentEvent(eventID: id, seq: seq, vendor: "codex", workspaceID: "workspace", sessionID: "session",
                  timestamp: "2026-01-01T00:00:00Z", type: .sessionEnded, role: nil, text: nil, name: nil,
                  input: nil, output: nil, toolCallID: nil, metadata: nil)
    }

    // Round 7 P0 (third independent reviewer, cross-producer race): the
    // Codex transcript producer publishes a turn's main event (e.g. a
    // toolCall) and its Working-continuation `.thinking` as TWO separate
    // publish() calls. The app-server approval-prompt producer is a
    // deliberately separate Hub producer. If an `interactivePrompt` lands
    // between those two calls (or was already there), the continuation must
    // never become the stream's last event — it would flip the client's
    // derived Working state back over an active needs-input/approval card.
    // This is the deterministic interleaving reproduction: postStoreDeliveryHook
    // fires synchronously right after the toolCall is STORED but before its
    // own publish() call returns, and from inside it we publish the captured
    // app-server prompt handler's event — exactly the window the two
    // independent producers could race in.
    func testInteractivePromptInterleavedBetweenMainEventAndContinuationSuppressesContinuation() {
        let hub = AgentEventHub()
        hub.publish(makeAnchorThinkingEvent(id: "anchor", seq: 1, turnID: "turn-1"))

        hub.postStoreDeliveryHook = { [weak hub] event in
            guard event.eventID == "tool-1" else { return }
            hub?.postStoreDeliveryHook = nil
            hub?.publish(self.makePromptEvent(id: "prompt-1", seq: 3, promptID: "p1", token: "tok-1"))
        }
        hub.publish(makeToolCallEvent(id: "tool-1", seq: 2))
        // The transcript producer's own subsequent line: the continuation
        // publish() call, arriving AFTER the interleaved prompt was already
        // stored.
        hub.publish(makeContinuationThinkingEvent(id: "continuation-1", seq: 4, turnID: "turn-1"))

        let events = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 100).events.sorted { $0.seq < $1.seq }
        XCTAssertFalse(events.contains { $0.eventID == "continuation-1" },
                       "the continuation must never be stored once an interactive prompt is active, got \(events.map(\.eventID))")
        XCTAssertEqual(events.last?.type, .interactivePrompt,
                       "the active prompt must remain the last, authoritative state, got \(events.map { ($0.eventID, $0.type) })")
    }

    // Same race, but the prompt is ALREADY active before the main event
    // publishes at all (no interleaving hook needed) — the suppression must
    // not depend on interleaving TIMING, only on prompt-active STATE.
    func testPromptAlreadyActiveBeforeMainEventStillSuppressesContinuation() {
        let hub = AgentEventHub()
        hub.publish(makeAnchorThinkingEvent(id: "anchor", seq: 1, turnID: "turn-1"))
        hub.publish(makePromptEvent(id: "prompt-1", seq: 2, promptID: "p1", token: "tok-1"))
        hub.publish(makeToolCallEvent(id: "tool-1", seq: 3))
        hub.publish(makeContinuationThinkingEvent(id: "continuation-1", seq: 4, turnID: "turn-1"))

        let events = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 100).events.sorted { $0.seq < $1.seq }
        XCTAssertFalse(events.contains { $0.eventID == "continuation-1" },
                       "a prompt already active before the main event must still suppress the continuation, got \(events.map(\.eventID))")
        XCTAssertFalse(events.contains { $0.type == .thinking && $0.metadata?["reason"] != "task_started" },
                       "no continuation/resume may appear while the prompt is active (only the initial anchor), got \(events.map { ($0.eventID, $0.type) })")
    }

    // A resolved event that does NOT close the active prompt (wrong
    // promptID, or a mismatched lifecycle token) must leave the suppression
    // in place — a stale/mismatched terminal is never treated as license to
    // resume Working.
    func testMismatchedResolvedDoesNotLiftSuppressionOrResumeWorking() {
        let hub = AgentEventHub()
        hub.publish(makeAnchorThinkingEvent(id: "anchor", seq: 1, turnID: "turn-1"))
        hub.publish(makePromptEvent(id: "prompt-1", seq: 2, promptID: "p1", token: "tok-1"))
        hub.publish(makeToolCallEvent(id: "tool-1", seq: 3))
        hub.publish(makeContinuationThinkingEvent(id: "continuation-1", seq: 4, turnID: "turn-1"))
        // Wrong token: does not satisfy terminalCloses for the active opener.
        hub.publish(makeResolvedEvent(id: "resolved-mismatched", seq: 5, promptID: "p1", token: "wrong-token"))

        let events = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 100).events.sorted { $0.seq < $1.seq }
        XCTAssertFalse(events.contains { $0.eventID == "continuation-1" })
        XCTAssertFalse(events.contains { $0.type == .thinking && $0.metadata?["reason"] == "prompt_resolved_resume" },
                       "a mismatched resolved must never synthesize a resume, got \(events.map { ($0.eventID, $0.type) })")
        XCTAssertNotNil(hub.activeInteractivePrompt(workspaceID: "workspace", sessionID: "session", promptID: "p1"),
                        "the prompt must still be considered active after a mismatched resolved")
    }

    // The core positive case: a matching resolved for a turn that is STILL
    // the tracked active turn (no new transcript event needed at all) must
    // immediately resume Working via a fresh, cursor-safe, dedupe-safe event
    // — never a replay of the dropped continuation itself.
    func testMatchingResolvedResumesWorkingForStillActiveTurnWithNoNewTranscriptEvent() {
        let hub = AgentEventHub()
        hub.publish(makeAnchorThinkingEvent(id: "anchor", seq: 1, turnID: "turn-1"))
        hub.publish(makePromptEvent(id: "prompt-1", seq: 2, promptID: "p1", token: "tok-1", turnID: "turn-1"))
        hub.publish(makeToolCallEvent(id: "tool-1", seq: 3))
        hub.publish(makeContinuationThinkingEvent(id: "continuation-1", seq: 4, turnID: "turn-1"))
        hub.publish(makeResolvedEvent(id: "resolved-1", seq: 5, promptID: "p1", token: "tok-1", turnID: "turn-1"))

        let events = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 100).events.sorted { $0.seq < $1.seq }
        XCTAssertFalse(events.contains { $0.eventID == "continuation-1" },
                       "the original dropped continuation must never itself appear, got \(events.map(\.eventID))")
        let resume = events.last
        XCTAssertEqual(resume?.type, .thinking,
                       "Working must resume immediately once the matching prompt resolves, got \(events.map { ($0.eventID, $0.type) })")
        XCTAssertEqual(resume?.metadata?["reason"], "prompt_resolved_resume")
        XCTAssertEqual(resume?.metadata?["turn_id"], "turn-1")
        XCTAssertGreaterThan(resume?.seq ?? -1, events.first { $0.eventID == "resolved-1" }?.seq ?? .max,
                             "the resume event must be cursor-safe (strictly above the resolved event's own seq)")
    }

    // If the pending turn was already closed by its OWN matching terminal
    // (assistantFinal reason=turn_terminal) BEFORE the resolved event
    // arrives, the resolved must never resurrect Working — a new/closed
    // turn identity always supersedes the stale pending suppression.
    func testTurnTerminalBeforeResolvedPreventsResume() {
        let hub = AgentEventHub()
        hub.publish(makeAnchorThinkingEvent(id: "anchor", seq: 1, turnID: "turn-1"))
        hub.publish(makePromptEvent(id: "prompt-1", seq: 2, promptID: "p1", token: "tok-1"))
        hub.publish(makeToolCallEvent(id: "tool-1", seq: 3))
        hub.publish(makeContinuationThinkingEvent(id: "continuation-1", seq: 4, turnID: "turn-1"))
        hub.publish(makeTurnTerminalEvent(id: "terminal-1", seq: 5, turnID: "turn-1"))
        hub.publish(makeResolvedEvent(id: "resolved-1", seq: 6, promptID: "p1", token: "tok-1"))

        let events = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 100).events.sorted { $0.seq < $1.seq }
        XCTAssertFalse(events.contains { $0.eventID == "continuation-1" })
        XCTAssertFalse(events.contains { $0.metadata?["reason"] == "prompt_resolved_resume" },
                       "a turn already closed by its own terminal must never be resumed by a later resolved, got \(events.map { ($0.eventID, $0.type) })")
    }

    // A continuation published BEFORE any prompt is active passes straight
    // through — the prompt opening afterward naturally becomes the final
    // state via ordinary chronological ordering, with no special mechanism
    // needed (and none engaged).
    func testContinuationBeforePromptOpensPassesThroughAndPromptNaturallyEndsLast() {
        let hub = AgentEventHub()
        hub.publish(makeAnchorThinkingEvent(id: "anchor", seq: 1, turnID: "turn-1"))
        hub.publish(makeToolCallEvent(id: "tool-1", seq: 2))
        hub.publish(makeContinuationThinkingEvent(id: "continuation-1", seq: 3, turnID: "turn-1"))
        hub.publish(makePromptEvent(id: "prompt-1", seq: 4, promptID: "p1", token: "tok-1"))

        let events = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 100).events.sorted { $0.seq < $1.seq }
        XCTAssertTrue(events.contains { $0.eventID == "continuation-1" },
                      "a continuation published before any prompt existed must be accepted normally")
        XCTAssertEqual(events.last?.type, .interactivePrompt)
    }

    // After a genuine resolve (no pending suppression in play — the
    // continuation before it went through normally), a FRESH continuation
    // for the same still-active turn must still be accepted normally: the
    // suppression mechanism must never become a permanent block once the
    // prompt clears.
    func testFreshContinuationAfterResolvedIsAcceptedNormally() {
        let hub = AgentEventHub()
        hub.publish(makeAnchorThinkingEvent(id: "anchor", seq: 1, turnID: "turn-1"))
        hub.publish(makePromptEvent(id: "prompt-1", seq: 2, promptID: "p1", token: "tok-1"))
        hub.publish(makeToolCallEvent(id: "tool-1", seq: 3))
        hub.publish(makeContinuationThinkingEvent(id: "continuation-1", seq: 4, turnID: "turn-1"))
        hub.publish(makeResolvedEvent(id: "resolved-1", seq: 5, promptID: "p1", token: "tok-1"))
        hub.publish(makeContinuationThinkingEvent(id: "continuation-2", seq: 6, turnID: "turn-1"))

        let events = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 100).events.sorted { $0.seq < $1.seq }
        XCTAssertTrue(events.contains { $0.eventID == "continuation-2" },
                      "a fresh continuation after the prompt resolved must be accepted normally, got \(events.map(\.eventID))")
        XCTAssertEqual(events.last?.eventID, "continuation-2")
    }

    // MARK: - Round 7B: anchors also fold, multi-prompt, reason policy, live-map durability

    // Requirement #1: a prompt active BEFORE the anchor itself arrives must
    // suppress the anchor too — the true invariant is turnActive &&
    // noActivePrompt, not "anchors are exempt."
    func testPromptBeforeAnchorSuppressesTheAnchorItself() {
        let hub = AgentEventHub()
        hub.publish(makePromptEvent(id: "prompt-1", seq: 1, promptID: "p1", token: "tok-1", turnID: "turn-1"))
        hub.publish(makeAnchorThinkingEvent(id: "anchor-1", seq: 2, turnID: "turn-1"))

        var events = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 100).events
        XCTAssertFalse(events.contains { $0.type == .thinking },
                       "the anchor must never appear while a prompt was already active, got \(events.map { ($0.eventID, $0.type) })")

        hub.publish(makeResolvedEvent(id: "resolved-1", seq: 3, promptID: "p1", token: "tok-1", turnID: "turn-1"))
        events = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 100).events.sorted { $0.seq < $1.seq }
        let resume = events.last
        XCTAssertEqual(resume?.type, .thinking,
                       "the anchor's turn must still resume once the prompt resolves, got \(events.map { ($0.eventID, $0.type) })")
        XCTAssertEqual(resume?.metadata?["turn_id"], "turn-1")
        XCTAssertFalse(events.contains { $0.eventID == "anchor-1" },
                       "the original suppressed anchor must never itself appear")
    }

    // Requirement #2: multiple suppressed signals for the SAME turn (an
    // anchor, then a continuation) must resume via exactly ONE resume event
    // when the prompt finally resolves — not one per suppressed signal.
    func testMultipleDeferredSignalsForSameTurnResumeOnlyOnce() {
        let hub = AgentEventHub()
        hub.publish(makePromptEvent(id: "prompt-1", seq: 1, promptID: "p1", token: "tok-1", turnID: "turn-1"))
        hub.publish(makeAnchorThinkingEvent(id: "anchor-1", seq: 2, turnID: "turn-1"))
        hub.publish(makeContinuationThinkingEvent(id: "continuation-1", seq: 3, turnID: "turn-1"))
        hub.publish(makeContinuationThinkingEvent(id: "continuation-2", seq: 4, turnID: "turn-1"))
        hub.publish(makeResolvedEvent(id: "resolved-1", seq: 5, promptID: "p1", token: "tok-1", turnID: "turn-1"))

        let events = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 100).events
        let resumes = events.filter { $0.metadata?["reason"] == "prompt_resolved_resume" }
        XCTAssertEqual(resumes.count, 1,
                       "exactly one resume event must fire regardless of how many signals were suppressed, got \(events.map { ($0.eventID, $0.type) })")
    }

    // Requirement #3: with MULTIPLE concurrent active prompts, only the
    // closure that brings the count to zero may resume — closing one of two
    // must not resume while the other remains active.
    func testMultiplePromptsOnlyResumeWhenTheLastOneCloses() {
        let hub = AgentEventHub()
        hub.publish(makeAnchorThinkingEvent(id: "anchor-1", seq: 1, turnID: "turn-1"))
        hub.publish(makePromptEvent(id: "prompt-A", seq: 2, promptID: "pA", token: "tok-A", turnID: "turn-1"))
        hub.publish(makePromptEvent(id: "prompt-B", seq: 3, promptID: "pB", token: "tok-B", turnID: "turn-1"))
        hub.publish(makeContinuationThinkingEvent(id: "continuation-1", seq: 4, turnID: "turn-1"))

        hub.publish(makeResolvedEvent(id: "resolved-A", seq: 5, promptID: "pA", token: "tok-A", turnID: "turn-1"))
        var events = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 100).events
        XCTAssertFalse(events.contains { $0.metadata?["reason"] == "prompt_resolved_resume" },
                       "closing ONE of two active prompts must not resume Working while the other remains active")

        hub.publish(makeResolvedEvent(id: "resolved-B", seq: 6, promptID: "pB", token: "tok-B", turnID: "turn-1"))
        events = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 100).events
        XCTAssertTrue(events.contains { $0.metadata?["reason"] == "prompt_resolved_resume" },
                      "closing the LAST active prompt must resume Working, got \(events.map { ($0.eventID, $0.type) })")
    }

    // Corrected per Codex frozen review: an active interactive prompt is a
    // SESSION-WIDE display gate, not a per-turn one. Sequence: prompt A
    // opens under turn-1 (still active); turn-2's anchor arrives WHILE A is
    // still open (hidden, but currentTurnID becomes turn-2); A's own exact
    // native resolved then closes the LAST active prompt. That resolved is
    // not "resuming turn-1" — it is lifting the session-wide gate and
    // revealing whatever turn is CURRENTLY tracked (turn-2). Requiring the
    // closing prompt's own turn_id to equal currentTurnID (an earlier,
    // over-tightened pass of this fix) would wrongly suppress Working here.
    func testPromptOpenedUnderOldTurnResumesTheNewSupersedingTurnOnceClosed() {
        let hub = AgentEventHub()
        hub.publish(makeAnchorThinkingEvent(id: "anchor-1", seq: 1, turnID: "turn-1"))
        hub.publish(makePromptEvent(id: "prompt-1", seq: 2, promptID: "p1", token: "tok-1", turnID: "turn-1"))
        hub.publish(makeContinuationThinkingEvent(id: "continuation-1", seq: 3, turnID: "turn-1"))
        // A new turn opens WHILE the prompt is still active (also suppressed).
        hub.publish(makeAnchorThinkingEvent(id: "anchor-2", seq: 4, turnID: "turn-2"))
        // The prompt's own exact resolved — still carrying turn-1 — closes
        // the last active prompt.
        hub.publish(makeResolvedEvent(id: "resolved-1", seq: 5, promptID: "p1", token: "tok-1", turnID: "turn-1"))

        let events = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 100).events
        let resumes = events.filter { $0.metadata?["reason"] == "prompt_resolved_resume" }
        XCTAssertEqual(resumes.count, 1,
                       "exactly one resume must fire once the last active prompt closes, got \(events.map { ($0.eventID, $0.metadata ?? [:]) })")
        XCTAssertEqual(resumes.first?.metadata?["turn_id"], "turn-2",
                       "the resume must reveal the CURRENTLY tracked turn (turn-2), not the turn the prompt happened to open under, got \(events.map { ($0.eventID, $0.metadata ?? [:]) })")

        // Contrast: if the NEW turn's own matching terminal closes it BEFORE
        // the old prompt resolves, currentTurnID is nil and the resolved
        // must not resume anything.
        let hub2 = AgentEventHub()
        hub2.publish(makeAnchorThinkingEvent(id: "anchor-1", seq: 1, turnID: "turn-1"))
        hub2.publish(makePromptEvent(id: "prompt-1", seq: 2, promptID: "p1", token: "tok-1", turnID: "turn-1"))
        hub2.publish(makeAnchorThinkingEvent(id: "anchor-2", seq: 3, turnID: "turn-2"))
        hub2.publish(makeTurnTerminalEvent(id: "terminal-2", seq: 4, turnID: "turn-2"))
        hub2.publish(makeResolvedEvent(id: "resolved-1", seq: 5, promptID: "p1", token: "tok-1", turnID: "turn-1"))
        let events2 = hub2.fetch(workspaceID: "workspace", sessionID: "session", limit: 100).events
        XCTAssertFalse(events2.contains { $0.metadata?["reason"] == "prompt_resolved_resume" },
                       "if the new turn's own terminal already closed it, the old prompt's later resolved must not resume anything, got \(events2.map { ($0.eventID, $0.metadata ?? [:]) })")
    }

    // Positive control: a prompt genuinely opened for the NEW (superseding)
    // turn correctly resumes IT — the turn_id correlation gate is not
    // accidentally fail-closed for a genuinely matching new-turn prompt.
    func testPromptForNewSupersedingTurnDoesResumeIt() {
        let hub = AgentEventHub()
        hub.publish(makeAnchorThinkingEvent(id: "anchor-1", seq: 1, turnID: "turn-1"))
        hub.publish(makePromptEvent(id: "prompt-1", seq: 2, promptID: "p1", token: "tok-1", turnID: "turn-1"))
        hub.publish(makeContinuationThinkingEvent(id: "continuation-1", seq: 3, turnID: "turn-1"))
        // The OLD turn's prompt resolves too (never resumes turn-2, since it
        // is a mismatched turn_id — see testOldPromptExactResolvedDoesNotResumeAfterNewAnchorSupersedes) —
        // this just clears it out of the active-prompt map so it doesn't
        // block the NEW turn's own prompt/resolve pair below.
        hub.publish(makeResolvedEvent(id: "resolved-1", seq: 4, promptID: "p1", token: "tok-1", turnID: "turn-1"))
        hub.publish(makeAnchorThinkingEvent(id: "anchor-2", seq: 5, turnID: "turn-2"))
        // A prompt genuinely opened for the NEW turn.
        hub.publish(makePromptEvent(id: "prompt-2", seq: 6, promptID: "p2", token: "tok-2", turnID: "turn-2"))
        hub.publish(makeResolvedEvent(id: "resolved-2", seq: 7, promptID: "p2", token: "tok-2", turnID: "turn-2"))

        let events = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 100).events
        XCTAssertTrue(events.contains { $0.metadata?["reason"] == "prompt_resolved_resume" && $0.metadata?["turn_id"] == "turn-2" },
                      "a prompt genuinely opened for the new turn must still resume it, got \(events.map { ($0.eventID, $0.metadata ?? [:]) })")
    }

    // Requirement #4: the prompt-active decision uses an independent live
    // map, not a rescan of bufferedEvents — a tiny buffer that trims the
    // interactivePrompt opener OUT of bufferedEvents must still suppress a
    // later continuation for the same session.
    func testPromptOpenerSurvivingBufferTrimStillSuppresses() {
        let hub = AgentEventHub(maxBufferedEvents: 1, maxSeenEventIDs: 100)
        hub.publish(makeAnchorThinkingEvent(id: "anchor-1", seq: 1, turnID: "turn-1"))
        hub.publish(makePromptEvent(id: "prompt-1", seq: 2, promptID: "p1", token: "tok-1"))
        // An unrelated, normally-accepted event pushes "prompt-1" itself OUT
        // of the (capacity-1) bufferedEvents window — the opener's own
        // lifecycle must still live in the independent map, unaffected by
        // this trim.
        hub.publish(makeToolCallEvent(id: "unrelated-tool-call", seq: 3))
        hub.publish(makeContinuationThinkingEvent(id: "continuation-1", seq: 4, turnID: "turn-1"))

        let events = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 100).events
        XCTAssertFalse(events.contains { $0.eventID == "prompt-1" },
                       "precondition: the tiny buffer must have actually evicted the prompt opener event")
        XCTAssertFalse(events.contains { $0.eventID == "continuation-1" },
                       "a trimmed-out-of-buffer opener must still gate suppression via the live map, got \(events.map(\.eventID))")
    }

    // Requirement #6/#7: an exact retry (same eventID) of an already-
    // suppressed event, WITHIN the same source epoch, must never resurrect
    // it — even AFTER the prompt that caused the suppression has already
    // resolved (so the "still active" suppression logic can no longer
    // redundantly catch a retry on its own) and even after enough OTHER
    // churn to force seenEventIDs' own capacity-driven rebuild (which only
    // retains bufferedEvents members; the suppressed tombstone set must NOT
    // depend on that rebuild).
    func testSuppressedExactRetrySurvivesSeenEventIDsCapacityRebuild() {
        let hub = AgentEventHub(maxBufferedEvents: 50, maxSeenEventIDs: 3)
        hub.publish(makeAnchorThinkingEvent(id: "anchor-1", seq: 1, turnID: "turn-1"))
        hub.publish(makePromptEvent(id: "prompt-1", seq: 2, promptID: "p1", token: "tok-1"))
        hub.publish(makeContinuationThinkingEvent(id: "continuation-1", seq: 3, turnID: "turn-1"))
        // The prompt resolves — the "prompt still active" suppression check
        // can no longer redundantly re-suppress a retry on its own; only the
        // dedicated tombstone set protects against it now.
        hub.publish(makeResolvedEvent(id: "resolved-1", seq: 4, promptID: "p1", token: "tok-1"))

        // Force seenEventIDs to rebuild against bufferedEvents multiple
        // times via unrelated churn — "continuation-1" is NOT in
        // bufferedEvents (it was suppressed), so a rebuild sourced from
        // seenEventIDs/bufferedEvents alone would lose track of it.
        for index in 0..<10 {
            hub.publish(makeToolCallEvent(id: "filler-\(index)", seq: 10 + index))
        }

        // Exact retry: same eventID, would-be duplicate.
        hub.publish(makeContinuationThinkingEvent(id: "continuation-1", seq: 999, turnID: "turn-1"))

        let events = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 100).events
        XCTAssertFalse(events.contains { $0.eventID == "continuation-1" },
                       "an exact retry of a suppressed event must never resurrect it, even after its prompt resolved and after a seenEventIDs capacity rebuild, got \(events.map(\.eventID))")
    }

    // Requirement #4's production edge case: a rollout-path-only transcript
    // source epoch reset REUSES the same app-server runtime, which never
    // re-notifies a still-pending approval — the Hub's OWN prompt-lifecycle
    // map must survive the reset so a new deep-recovery anchor for the
    // reset source still gets suppressed, and the eventually-resolved OLD
    // prompt still resumes the NEW turn correctly.
    func testPendingPromptSurvivesTranscriptSourceEpochResetAndStillGatesNewAnchor() {
        let hub = AgentEventHub()
        // The prompt's own turn_id ("turn-new") reflects the underlying
        // Codex app-server turn — which does NOT change across a
        // rollout-path-only switch, only the Bridge's local transcript
        // bookkeeping does (rediscovered via the deep-recovery anchor
        // below, under the SAME real turn).
        hub.publish(makePromptEvent(id: "prompt-A", seq: 1, promptID: "pA", token: "tok-A", turnID: "turn-new"))

        // Rollout-path-only reset: the transcript identity changes, but the
        // app-server runtime (and its pending approval) is REUSED — no new
        // prompt notification arrives.
        hub.beginNewSourceEpoch(sessionID: "session")

        hub.publish(makeAnchorThinkingEvent(id: "anchor-new", seq: 1, turnID: "turn-new", reason: "bootstrap_recovered_task_started"))
        var events = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 100).events
        XCTAssertFalse(events.contains { $0.type == .thinking },
                       "the still-pending pre-epoch prompt must suppress the post-epoch deep-recovery anchor, got \(events.map { ($0.eventID, $0.type) })")

        hub.publish(makeResolvedEvent(id: "resolved-A", seq: 2, promptID: "pA", token: "tok-A", turnID: "turn-new"))
        events = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 100).events
        let resume = events.first { $0.metadata?["reason"] == "prompt_resolved_resume" }
        XCTAssertEqual(resume?.metadata?["turn_id"], "turn-new",
                       "the eventual resolve must resume the NEW (post-epoch) turn, got \(events.map { ($0.eventID, $0.metadata ?? [:]) })")
    }

    // Requirement #10: "turn_completed" is a genuinely closing resolved, but
    // must END the tracked turn rather than resume it — a later, unrelated
    // prompt+resolved cycle must not accidentally resurrect the ended turn.
    func testTurnCompletedReasonEndsTrackedTurnWithoutResuming() {
        let hub = AgentEventHub()
        hub.publish(makeAnchorThinkingEvent(id: "anchor-1", seq: 1, turnID: "turn-1"))
        hub.publish(makePromptEvent(id: "prompt-1", seq: 2, promptID: "p1", token: "tok-1", turnID: "turn-1"))
        hub.publish(makeContinuationThinkingEvent(id: "continuation-1", seq: 3, turnID: "turn-1"))
        // Round 7C P0-B/tri-state case 1: turn_completed only ends the
        // tracked turn when BOTH opener and terminal metadata carry a
        // matching turn_id equal to currentTurnID.
        hub.publish(makeResolvedEvent(id: "resolved-1", seq: 4, promptID: "p1", token: "tok-1", reason: "turn_completed", turnID: "turn-1"))

        var events = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 100).events
        XCTAssertFalse(events.contains { $0.metadata?["reason"] == "prompt_resolved_resume" },
                       "turn_completed must never itself resume Working, got \(events.map { ($0.eventID, $0.type) })")

        // A later, unrelated prompt/resolved cycle (no new anchor in
        // between) must not resurrect the already-ended turn.
        hub.publish(makePromptEvent(id: "prompt-2", seq: 5, promptID: "p2", token: "tok-2"))
        hub.publish(makeResolvedEvent(id: "resolved-2", seq: 6, promptID: "p2", token: "tok-2"))
        events = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 100).events
        XCTAssertFalse(events.contains { $0.metadata?["reason"] == "prompt_resolved_resume" },
                       "an ended turn must never be resurrected by an unrelated later prompt/resolved cycle")
    }

    // Round 7C P0-B: a turn_completed resolved with a STALE/MISMATCHED
    // turn_id must only close ITS OWN prompt — never reach in and kill an
    // unrelated (possibly different) tracked turn.
    func testTurnCompletedWithMismatchedTurnIDOnlyClosesItsPromptNotTheTrackedTurn() {
        let hub = AgentEventHub()
        hub.publish(makeAnchorThinkingEvent(id: "anchor-1", seq: 1, turnID: "turn-1"))
        // The opener AND terminal both carry a non-blank turn_id, but they
        // are MUTUALLY INCONSISTENT with each other (not just missing) —
        // exercises case 3's `openerTurnID == terminalTurnID` requirement
        // specifically, not merely "opener has no turn_id at all."
        hub.publish(makePromptEvent(id: "prompt-1", seq: 2, promptID: "p1", token: "tok-1", turnID: "turn-OPENER"))
        hub.publish(makeResolvedEvent(id: "resolved-1", seq: 3, promptID: "p1", token: "tok-1", reason: "turn_completed", turnID: "turn-UNRELATED"))

        // Assert IMMEDIATELY after the inconsistent terminal — zero resumes.
        // A buggy implementation that wrongly resumes on the inconsistent
        // case itself (rather than only failing to END the turn) must be
        // caught HERE, before a later genuine cycle can mask it.
        var events = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 100).events
        XCTAssertEqual(events.filter { $0.metadata?["reason"] == "prompt_resolved_resume" }.count, 0,
                       "an inconsistent opener/terminal turn_completed must never itself synthesize a resume, got \(events.map { ($0.eventID, $0.metadata ?? [:]) })")

        // The tracked turn (turn-1) must survive: a later genuine
        // server_resolved cycle must still be able to resume it.
        hub.publish(makePromptEvent(id: "prompt-2", seq: 4, promptID: "p2", token: "tok-2", turnID: "turn-1"))
        hub.publish(makeResolvedEvent(id: "resolved-2", seq: 5, promptID: "p2", token: "tok-2", turnID: "turn-1"))
        events = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 100).events
        let resumes = events.filter { $0.metadata?["reason"] == "prompt_resolved_resume" }
        XCTAssertEqual(resumes.count, 1,
                       "exactly one resume must exist in total — from the genuine second closure only, got \(events.map { ($0.eventID, $0.metadata ?? [:]) })")
        XCTAssertEqual(resumes.first?.metadata?["turn_id"], "turn-1",
                       "the single resume must carry the current tracked turn, got \(events.map { ($0.eventID, $0.metadata ?? [:]) })")
        let resolved2Seq = events.first { $0.eventID == "resolved-2" }?.seq ?? .max
        XCTAssertGreaterThan(resumes.first?.seq ?? -1, resolved2Seq,
                             "the resume must be cursor-safe and follow the genuine second (resolved-2) closure, not the earlier inconsistent one, got \(events.map { ($0.eventID, $0.seq) })")
    }

    // Round 7C P0-B: a turn_completed resolved with NO turn_id at all — a
    // malformed/legacy or otherwise defensive case (production
    // CodexAppServerConnection resolved events DO carry turn_id via
    // applyRequestIdentity when a request is available; this covers the
    // case where that identity is nonetheless absent, e.g. a stale test
    // fixture, a future protocol variant, or a resolved event constructed
    // without a request) — must NOT end the tracked turn either: fail-closed
    // on missing correlating identity, same as a mismatch.
    func testTurnCompletedWithMissingTurnIDDoesNotEndTrackedTurn() {
        let hub = AgentEventHub()
        hub.publish(makeAnchorThinkingEvent(id: "anchor-1", seq: 1, turnID: "turn-1"))
        hub.publish(makePromptEvent(id: "prompt-1", seq: 2, promptID: "p1", token: "tok-1"))
        hub.publish(makeResolvedEvent(id: "resolved-1", seq: 3, promptID: "p1", token: "tok-1", reason: "turn_completed"))

        hub.publish(makePromptEvent(id: "prompt-2", seq: 4, promptID: "p2", token: "tok-2", turnID: "turn-1"))
        hub.publish(makeResolvedEvent(id: "resolved-2", seq: 5, promptID: "p2", token: "tok-2", turnID: "turn-1"))
        let events = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 100).events
        let resume = events.first { $0.metadata?["reason"] == "prompt_resolved_resume" }
        XCTAssertEqual(resume?.metadata?["turn_id"], "turn-1",
                       "a turn_completed resolved with NO turn_id must never end the tracked turn, got \(events.map { ($0.eventID, $0.metadata ?? [:]) })")
    }

    // Tri-state case 2: opener/terminal turn_id both non-blank and mutually
    // consistent, but DIFFERENT from currentTurnID — an OLD turn's prompt
    // completed while a NEWER turn (B) already superseded it. currentTurnID
    // must be untouched (not cleared), and since this was the last active
    // prompt, the session-wide gate lifts and resumes the CURRENTLY tracked
    // turn (B) — exactly the example: A prompt active → B anchor arrives
    // (suppressed, current=B) → native turn_completed(A) → exactly one
    // resume(B).
    func testOldTurnCompletedResumesCurrentlyTrackedSupersedingTurn() {
        let hub = AgentEventHub()
        hub.publish(makeAnchorThinkingEvent(id: "anchor-A", seq: 1, turnID: "turn-A"))
        hub.publish(makePromptEvent(id: "prompt-A", seq: 2, promptID: "pA", token: "tok-A", turnID: "turn-A"))
        // Turn B opens WHILE prompt A is still active (suppressed; current becomes B).
        hub.publish(makeAnchorThinkingEvent(id: "anchor-B", seq: 3, turnID: "turn-B"))
        // Prompt A's own turn_completed — consistent opener/terminal (both turn-A), but DIFFERENT from current (turn-B).
        hub.publish(makeResolvedEvent(id: "resolved-A", seq: 4, promptID: "pA", token: "tok-A", reason: "turn_completed", turnID: "turn-A"))

        let events = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 100).events
        let resumes = events.filter { $0.metadata?["reason"] == "prompt_resolved_resume" }
        XCTAssertEqual(resumes.count, 1,
                       "exactly one resume must fire once the last active prompt (A) closes, got \(events.map { ($0.eventID, $0.metadata ?? [:]) })")
        XCTAssertEqual(resumes.first?.metadata?["turn_id"], "turn-B",
                       "an old turn's turn_completed must resume the CURRENTLY tracked (superseding) turn, not end it, got \(events.map { ($0.eventID, $0.metadata ?? [:]) })")
    }

    // Positive control for tri-state case 1: turn_completed for the turn
    // that IS currently tracked ends it cleanly with ZERO resume — nothing
    // to reveal, since the current turn itself just completed.
    func testTurnCompletedForCurrentTrackedTurnEndsItWithZeroResume() {
        let hub = AgentEventHub()
        hub.publish(makeAnchorThinkingEvent(id: "anchor-B", seq: 1, turnID: "turn-B"))
        hub.publish(makePromptEvent(id: "prompt-B", seq: 2, promptID: "pB", token: "tok-B", turnID: "turn-B"))
        hub.publish(makeResolvedEvent(id: "resolved-B", seq: 3, promptID: "pB", token: "tok-B", reason: "turn_completed", turnID: "turn-B"))

        let events = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 100).events
        XCTAssertFalse(events.contains { $0.metadata?["reason"] == "prompt_resolved_resume" },
                       "turn_completed for the CURRENT tracked turn must end it with zero resume, got \(events.map { ($0.eventID, $0.metadata ?? [:]) })")
    }

    // Tri-state case 2, with MULTIPLE concurrent active prompts: an old
    // turn's turn_completed closing one of two active prompts must not
    // resume while the other remains active — only after the LAST one
    // closes.
    func testOldTurnCompletedWithMultiplePromptsOnlyResumesAfterLastCloses() {
        let hub = AgentEventHub()
        hub.publish(makeAnchorThinkingEvent(id: "anchor-A", seq: 1, turnID: "turn-A"))
        hub.publish(makePromptEvent(id: "prompt-A1", seq: 2, promptID: "pA1", token: "tok-A1", turnID: "turn-A"))
        hub.publish(makePromptEvent(id: "prompt-A2", seq: 3, promptID: "pA2", token: "tok-A2", turnID: "turn-A"))
        hub.publish(makeAnchorThinkingEvent(id: "anchor-B", seq: 4, turnID: "turn-B"))

        hub.publish(makeResolvedEvent(id: "resolved-A1", seq: 5, promptID: "pA1", token: "tok-A1", reason: "turn_completed", turnID: "turn-A"))
        var events = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 100).events
        XCTAssertFalse(events.contains { $0.metadata?["reason"] == "prompt_resolved_resume" },
                       "closing ONE of two active prompts must not resume while the other remains active")

        hub.publish(makeResolvedEvent(id: "resolved-A2", seq: 6, promptID: "pA2", token: "tok-A2", reason: "turn_completed", turnID: "turn-A"))
        events = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 100).events
        let resumes = events.filter { $0.metadata?["reason"] == "prompt_resolved_resume" }
        XCTAssertEqual(resumes.count, 1,
                       "exactly one resume must fire once the LAST active prompt closes, got \(events.map { ($0.eventID, $0.metadata ?? [:]) })")
        XCTAssertEqual(resumes.first?.metadata?["turn_id"], "turn-B")
    }

    // Round 7C P0-B: a live .sessionStarted atomically clears whatever
    // turn/deferred state the OLD session incarnation left behind — a stale
    // old-turn continuation arriving under the NEW session must be rejected
    // by P0-A's identity gate (currentTurnID is now nil).
    func testSessionStartedClearsOldTrackedTurnAndDeferredState() {
        let hub = AgentEventHub()
        hub.publish(makeAnchorThinkingEvent(id: "anchor-1", seq: 1, turnID: "turn-1"))
        hub.publish(makeSessionStartedEvent(id: "session-started-1", seq: 2))
        // A stale continuation for the OLD (pre-sessionStarted) turn must
        // never store under the new session incarnation.
        hub.publish(makeContinuationThinkingEvent(id: "stale-continuation", seq: 3, turnID: "turn-1"))

        let events = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 100).events
        XCTAssertFalse(events.contains { $0.eventID == "stale-continuation" },
                       "a continuation for a turn from BEFORE a live sessionStarted must never store, got \(events.map(\.eventID))")
    }

    // Round 7C P0-B: `.sessionEnded` also atomically clears the tracked
    // turn — a stale old-turn continuation arriving after must be rejected.
    func testSessionEndedClearsOldTrackedTurnAndDeferredState() {
        let hub = AgentEventHub()
        hub.publish(makeAnchorThinkingEvent(id: "anchor-1", seq: 1, turnID: "turn-1"))
        hub.publish(makeSessionEndedEvent(id: "session-ended-1", seq: 2))
        hub.publish(makeContinuationThinkingEvent(id: "stale-continuation", seq: 3, turnID: "turn-1"))

        let events = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 100).events
        XCTAssertFalse(events.contains { $0.eventID == "stale-continuation" },
                       "a continuation for a turn from BEFORE a live sessionEnded must never store, got \(events.map(\.eventID))")
    }

    // MARK: - Round 7C P0-C: resume capability fail closed

    // A vendor=claude event faking reason=server_resolved must only close
    // its prompt — never synthesize a resume. "server_resolved" alone (a
    // free-form string) is never trusted without the full native contract.
    func testGenericVendorFakingServerResolvedOnlyClosesNeverResumes() {
        let hub = AgentEventHub()
        hub.publish(makeAnchorThinkingEvent(id: "anchor-1", seq: 1, turnID: "turn-1"))
        hub.publish(legacyPrompt(id: "prompt-1", seq: 2, promptID: "p1"))
        hub.publish(legacyTerminal(id: "resolved-1", seq: 3, promptID: "p1"))

        let events = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 100).events
        XCTAssertNil(hub.activeInteractivePrompt(workspaceID: "workspace", sessionID: "session", promptID: "p1"),
                    "the prompt must still close")
        XCTAssertFalse(events.contains { $0.metadata?["reason"] == "prompt_resolved_resume" },
                       "a non-Codex-native (vendor=claude) lifecycle must never resume Working, got \(events.map { ($0.eventID, $0.type) })")
    }

    // A codex-vendor resolved event MISSING submit_channel=codex_app_server
    // must not resume, even with an otherwise-matching token/source.
    func testMissingSubmitChannelNeverResumes() {
        let hub = AgentEventHub()
        hub.publish(makeAnchorThinkingEvent(id: "anchor-1", seq: 1, turnID: "turn-1"))
        hub.publish(makePromptEvent(id: "prompt-1", seq: 2, promptID: "p1", token: "tok-1", submitChannel: nil))
        hub.publish(makeResolvedEvent(id: "resolved-1", seq: 3, promptID: "p1", token: "tok-1", submitChannel: nil))

        let events = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 100).events
        XCTAssertFalse(events.contains { $0.metadata?["reason"] == "prompt_resolved_resume" },
                       "missing submit_channel=codex_app_server must never resume Working, got \(events.map { ($0.eventID, $0.type) })")
    }

    // A source NOT in the allowlist (neither command/file-change/permissions
    // approval) must not resume, even with vendor=codex and a valid token.
    func testUnknownSourceNeverResumes() {
        let hub = AgentEventHub()
        hub.publish(makeAnchorThinkingEvent(id: "anchor-1", seq: 1, turnID: "turn-1"))
        hub.publish(makePromptEvent(id: "prompt-1", seq: 2, promptID: "p1", token: "tok-1", source: "some_other_codex_source"))
        hub.publish(makeResolvedEvent(id: "resolved-1", seq: 3, promptID: "p1", token: "tok-1", source: "some_other_codex_source"))

        let events = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 100).events
        XCTAssertFalse(events.contains { $0.metadata?["reason"] == "prompt_resolved_resume" },
                       "a source outside the allowlist must never resume Working, got \(events.map { ($0.eventID, $0.type) })")
    }

    // The opener AND the terminal must BOTH satisfy the capability contract
    // — a legacy/non-capability OPENER closed by an otherwise-native-looking
    // terminal must not resume (mixed-domain lifecycle).
    func testNonCapableOpenerWithNativeTerminalNeverResumes() {
        let hub = AgentEventHub()
        hub.publish(makeAnchorThinkingEvent(id: "anchor-1", seq: 1, turnID: "turn-1"))
        // A legacy (non-capability, no token) opener.
        hub.publish(makePromptEvent(id: "prompt-1", seq: 2, promptID: "p1", token: nil, submitChannel: nil))
        // The resolved event, mismatched-token per terminalCloses's own
        // legacy contract, wouldn't even close it — so use the SAME
        // tokenless shape to genuinely close, but still non-capable.
        hub.publish(makeResolvedEvent(id: "resolved-1", seq: 3, promptID: "p1", token: nil, submitChannel: nil))

        let events = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 100).events
        XCTAssertFalse(events.contains { $0.metadata?["reason"] == "prompt_resolved_resume" },
                       "a non-capable opener/terminal pair must never resume Working, got \(events.map { ($0.eventID, $0.type) })")
    }

    // A missing/empty lifecycle token (even with vendor=codex, correct
    // submit_channel and source) must not resume — the EXACT token is part
    // of the contract, not just the other three fields.
    func testMissingLifecycleTokenNeverResumes() {
        let hub = AgentEventHub()
        hub.publish(makeAnchorThinkingEvent(id: "anchor-1", seq: 1, turnID: "turn-1"))
        let opener = AgentEvent(eventID: "prompt-1", seq: 2, vendor: "codex", workspaceID: "workspace", sessionID: "session",
                                timestamp: "2026-01-01T00:00:00Z", type: .interactivePrompt, role: "assistant", text: nil,
                                name: nil, input: nil, output: nil, toolCallID: nil,
                                metadata: ["prompt_id": "p1", "source": "codex_command_approval", "submit_channel": "codex_app_server"])
        let terminal = AgentEvent(eventID: "resolved-1", seq: 3, vendor: "codex", workspaceID: "workspace", sessionID: "session",
                                  timestamp: "2026-01-01T00:00:00Z", type: .interactivePromptResolved, role: "tool", text: nil,
                                  name: nil, input: nil, output: nil, toolCallID: nil,
                                  metadata: ["prompt_id": "p1", "reason": "server_resolved", "source": "codex_command_approval", "submit_channel": "codex_app_server"])
        hub.publish(opener)
        hub.publish(terminal)

        let events = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 100).events
        XCTAssertFalse(events.contains { $0.metadata?["reason"] == "prompt_resolved_resume" },
                       "a missing lifecycle token must never resume Working even with every other field matching, got \(events.map { ($0.eventID, $0.type) })")
    }

    // Positive control: a genuinely full Codex-native app-server lifecycle
    // DOES resume — the capability gate is not accidentally fail-closed for
    // everything.
    func testFullCodexNativeCapabilityLifecycleDoesResume() {
        let hub = AgentEventHub()
        hub.publish(makeAnchorThinkingEvent(id: "anchor-1", seq: 1, turnID: "turn-1"))
        hub.publish(makePromptEvent(id: "prompt-1", seq: 2, promptID: "p1", token: "tok-1", turnID: "turn-1"))
        hub.publish(makeResolvedEvent(id: "resolved-1", seq: 3, promptID: "p1", token: "tok-1", turnID: "turn-1"))

        let events = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 100).events
        XCTAssertTrue(events.contains { $0.metadata?["reason"] == "prompt_resolved_resume" },
                      "a genuinely full Codex-native app-server lifecycle must still resume, got \(events.map { ($0.eventID, $0.type) })")
    }

    // Requirement #10: "expired"/"superseded" (and any unrecognized reason)
    // close the prompt but neither resume NOR end the tracked turn — a
    // SUBSEQUENT genuine resolve for the SAME still-active turn must still
    // be able to resume it correctly (the turn was never lost).
    func testExpiredReasonNeitherResumesNorEndsTurnAllowingLaterGenuineResume() {
        let hub = AgentEventHub()
        hub.publish(makeAnchorThinkingEvent(id: "anchor-1", seq: 1, turnID: "turn-1"))
        hub.publish(makePromptEvent(id: "prompt-1", seq: 2, promptID: "p1", token: "tok-1", turnID: "turn-1"))
        hub.publish(makeContinuationThinkingEvent(id: "continuation-1", seq: 3, turnID: "turn-1"))
        hub.publish(makeResolvedEvent(id: "resolved-1", seq: 4, promptID: "p1", token: "tok-1", reason: "expired", turnID: "turn-1"))

        var events = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 100).events
        XCTAssertFalse(events.contains { $0.metadata?["reason"] == "prompt_resolved_resume" },
                       "expired must never itself resume Working")

        // The turn must still be considered tracked/active: a later,
        // GENUINE (server_resolved) prompt closure must still resume it.
        hub.publish(makePromptEvent(id: "prompt-2", seq: 5, promptID: "p2", token: "tok-2", turnID: "turn-1"))
        hub.publish(makeResolvedEvent(id: "resolved-2", seq: 6, promptID: "p2", token: "tok-2", turnID: "turn-1"))
        events = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 100).events
        let resume = events.first { $0.metadata?["reason"] == "prompt_resolved_resume" }
        XCTAssertEqual(resume?.metadata?["turn_id"], "turn-1",
                       "the turn must survive an expired resolve and still resume on a later genuine one, got \(events.map { ($0.eventID, $0.metadata ?? [:]) })")
    }

    // Requirement #7: a suppressed event must have ZERO side effects on
    // sequencing — it must never advance storedSeqHighWater/the seq
    // reservation. A later, genuinely-accepted event with a LOWER seq than
    // the suppressed one's own claimed seq must keep its own seq unchanged
    // (never rebased above the suppressed event's seq, which was never
    // "stored" at all).
    func testSuppressedEventDoesNotAdvanceSeqHighWaterOrReservation() {
        let hub = AgentEventHub()
        hub.publish(makeAnchorThinkingEvent(id: "anchor-1", seq: 1, turnID: "turn-1"))
        hub.publish(makePromptEvent(id: "prompt-1", seq: 2, promptID: "p1", token: "tok-1"))
        // Suppressed — claims a seq far above anything genuinely stored.
        hub.publish(makeContinuationThinkingEvent(id: "continuation-1", seq: 100, turnID: "turn-1"))
        // A genuinely-accepted event with a seq ABOVE the real high-water (2)
        // but far BELOW the suppressed event's claimed seq (100) — if the
        // suppressed event had illegitimately advanced storedSeqHighWater,
        // this would get rebased to something above 100.
        hub.publish(makeResolvedEvent(id: "resolved-1", seq: 3, promptID: "p1", token: "tok-1"))

        let events = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 100).events
        let resolved = events.first { $0.eventID == "resolved-1" }
        XCTAssertEqual(resolved?.seq, 3,
                       "a suppressed event must never advance storedSeqHighWater/reservation, got seq=\(resolved?.seq.description ?? "<missing>")")
    }

    // MARK: - Round 7C P0-A: continuation identity fail-closed

    // A continuation with a NIL turn_id must be rejected unconditionally —
    // no active prompt required to catch it — with zero side effects
    // (never stored, never advances the seq high-water).
    func testContinuationWithNilTurnIDIsRejectedEvenWithNoActivePrompt() {
        let hub = AgentEventHub()
        hub.publish(makeAnchorThinkingEvent(id: "anchor-1", seq: 1, turnID: "turn-1"))
        let malformed = AgentEvent(eventID: "continuation-nil", seq: 2, vendor: "codex", workspaceID: "workspace",
                                   sessionID: "session", timestamp: "2026-01-01T00:00:00Z", type: .thinking,
                                   role: nil, text: nil, name: nil, input: nil, output: nil, toolCallID: nil,
                                   metadata: ["reason": "tool_call", "is_continuation": "true"])
        hub.publish(malformed)
        hub.publish(makeResolvedEvent(id: "later-1", seq: 3, promptID: "unused", token: nil))

        let events = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 100).events
        XCTAssertFalse(events.contains { $0.eventID == "continuation-nil" },
                       "a continuation with a nil turn_id must never store, got \(events.map(\.eventID))")
    }

    // A continuation with a BLANK/whitespace-only turn_id must be treated
    // exactly like nil — never a real identity, never a match.
    func testContinuationWithBlankTurnIDIsRejected() {
        let hub = AgentEventHub()
        hub.publish(makeAnchorThinkingEvent(id: "anchor-1", seq: 1, turnID: "turn-1"))
        hub.publish(makeContinuationThinkingEvent(id: "continuation-blank", seq: 2, turnID: "   "))

        let events = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 100).events
        XCTAssertFalse(events.contains { $0.eventID == "continuation-blank" },
                       "a continuation with a blank turn_id must never store, got \(events.map(\.eventID))")
    }

    // A continuation for a DIFFERENT, mismatched turn — no active prompt at
    // all — must still be rejected, not silently accepted (the Round 7C
    // regression: previously a non-matching continuation with no active
    // prompt fell through every check and stored/delivered as if valid).
    func testContinuationForMismatchedTurnIsRejectedWithNoActivePrompt() {
        let hub = AgentEventHub()
        hub.publish(makeAnchorThinkingEvent(id: "anchor-1", seq: 1, turnID: "turn-1"))
        hub.publish(makeContinuationThinkingEvent(id: "continuation-wrong-turn", seq: 2, turnID: "turn-OTHER"))

        let events = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 100).events
        XCTAssertFalse(events.contains { $0.eventID == "continuation-wrong-turn" },
                       "a continuation for a turn that is not the tracked one must never store, even with no active prompt, got \(events.map(\.eventID))")
    }

    // A continuation arriving when NO turn is tracked at all (currentTurnID
    // is nil — no anchor ever ran, or it was already closed) must be
    // rejected, never treated as "vacuously matching."
    func testContinuationWithNoTrackedTurnIsRejected() {
        let hub = AgentEventHub()
        hub.publish(makeContinuationThinkingEvent(id: "continuation-no-turn", seq: 1, turnID: "turn-1"))

        let events = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 100).events
        XCTAssertFalse(events.contains { $0.eventID == "continuation-no-turn" },
                       "a continuation must never store when no turn is tracked at all, got \(events.map(\.eventID))")
    }

    // A genuinely MATCHING continuation with NO active prompt must still
    // store normally (the fail-closed fix must not become fail-closed for
    // everything).
    func testMatchingContinuationWithNoActivePromptStillStoresNormally() {
        let hub = AgentEventHub()
        hub.publish(makeAnchorThinkingEvent(id: "anchor-1", seq: 1, turnID: "turn-1"))
        hub.publish(makeContinuationThinkingEvent(id: "continuation-1", seq: 2, turnID: "turn-1"))

        let events = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 100).events
        XCTAssertTrue(events.contains { $0.eventID == "continuation-1" },
                      "a genuinely matching continuation with no active prompt must store normally, got \(events.map(\.eventID))")
    }

    // A matching continuation with an ACTIVE prompt must still defer
    // (suppressed), per the Round 7B mechanism, unaffected by the new
    // identity gate.
    func testMatchingContinuationWithActivePromptStillDefers() {
        let hub = AgentEventHub()
        hub.publish(makeAnchorThinkingEvent(id: "anchor-1", seq: 1, turnID: "turn-1"))
        hub.publish(makePromptEvent(id: "prompt-1", seq: 2, promptID: "p1", token: "tok-1"))
        hub.publish(makeContinuationThinkingEvent(id: "continuation-1", seq: 3, turnID: "turn-1"))

        let events = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 100).events
        XCTAssertFalse(events.contains { $0.eventID == "continuation-1" },
                       "a matching continuation must still defer while a prompt is active, got \(events.map(\.eventID))")
    }

    // An exact retry of a REJECTED (mismatched-identity) continuation must
    // never resurrect it — the tombstone applies to identity-rejected
    // events exactly like prompt-deferred ones.
    func testExactRetryOfIdentityRejectedContinuationStaysDropped() {
        let hub = AgentEventHub()
        hub.publish(makeAnchorThinkingEvent(id: "anchor-1", seq: 1, turnID: "turn-1"))
        hub.publish(makeContinuationThinkingEvent(id: "continuation-wrong", seq: 2, turnID: "turn-OTHER"))
        // Retry: same eventID.
        hub.publish(makeContinuationThinkingEvent(id: "continuation-wrong", seq: 999, turnID: "turn-OTHER"))

        let events = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 100).events
        XCTAssertFalse(events.contains { $0.eventID == "continuation-wrong" },
                       "an exact retry of an identity-rejected continuation must never resurrect it, got \(events.map(\.eventID))")
    }

    // A rejected (mismatched-identity) continuation must have ZERO side
    // effects on sequencing — a later genuinely-accepted lower-seq event
    // must not be rebased above the rejected event's own claimed seq.
    func testIdentityRejectedContinuationDoesNotAdvanceSeqHighWater() {
        let hub = AgentEventHub()
        hub.publish(makeAnchorThinkingEvent(id: "anchor-1", seq: 1, turnID: "turn-1"))
        // Rejected — claims a seq far above anything genuinely stored.
        hub.publish(makeContinuationThinkingEvent(id: "continuation-wrong", seq: 100, turnID: "turn-OTHER"))
        hub.publish(makeContinuationThinkingEvent(id: "continuation-1", seq: 2, turnID: "turn-1"))

        let events = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 100).events
        let accepted = events.first { $0.eventID == "continuation-1" }
        XCTAssertEqual(accepted?.seq, 2,
                       "a rejected continuation must never advance storedSeqHighWater/reservation, got seq=\(accepted?.seq.description ?? "<missing>")")
    }

    // MARK: - Round 7C P0-D: prompt lifecycle vs source/session boundary

    // A Claude/generic (non-Codex-native) opener must NEVER survive a live
    // `.sessionEnded` — it must never permanently gate a later, unrelated
    // turn. A NEW anchor after sessionEnded must be delivered normally.
    func testClaudeGenericPromptDoesNotSurviveSessionEndedNewAnchorShows() {
        let hub = AgentEventHub()
        hub.publish(legacyPrompt(id: "prompt-1", seq: 1, promptID: "p1"))
        hub.publish(makeSessionEndedEvent(id: "session-ended-1", seq: 2))
        hub.publish(makeAnchorThinkingEvent(id: "anchor-1", seq: 3, turnID: "turn-1"))

        let events = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 100).events
        XCTAssertTrue(events.contains { $0.eventID == "anchor-1" },
                      "a new anchor after sessionEnded must show — a Claude/generic prompt must not survive to gate it, got \(events.map(\.eventID))")
    }

    // Same rule at the TRANSCRIPT epoch boundary: a Claude/generic opener
    // must never survive `beginNewSourceEpoch` either — only a genuinely
    // Codex-native pending approval does (see
    // testPendingPromptSurvivesTranscriptSourceEpochResetAndStillGatesNewAnchor).
    func testClaudeGenericPromptDoesNotSurviveTranscriptEpochResetNewAnchorShows() {
        let hub = AgentEventHub()
        hub.publish(legacyPrompt(id: "prompt-1", seq: 1, promptID: "p1"))
        hub.beginNewSourceEpoch(sessionID: "session")
        hub.publish(makeAnchorThinkingEvent(id: "anchor-new", seq: 1, turnID: "turn-new", reason: "bootstrap_recovered_task_started"))

        let events = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 100).events
        XCTAssertTrue(events.contains { $0.eventID == "anchor-new" },
                      "a new anchor after a transcript epoch reset must show — a Claude/generic prompt must not survive to gate it, got \(events.map(\.eventID))")
    }

    // Focused fix #1: a live session boundary must ALSO clear the
    // `suppressedEventIDs` tombstone — a NEW session incarnation reusing an
    // eventID (e.g. a process-local counter restarting) must not be
    // silently swallowed as an "already suppressed" duplicate from the OLD
    // incarnation.
    func testSessionBoundaryClearsTombstoneSoReusedEventIDIsAccepted() {
        let hub = AgentEventHub()
        hub.publish(makeAnchorThinkingEvent(id: "anchor-old", seq: 1, turnID: "turn-old"))
        // A non-native (legacy) prompt: guaranteed to be dropped by the
        // session boundary (P0-D), so it does not itself keep suppressing
        // events after sessionStarted — isolating this test to ONLY the
        // tombstone-clearing behavior.
        hub.publish(legacyPrompt(id: "prompt-1", seq: 2, promptID: "p1"))
        // Suppressed under the OLD incarnation — its eventID goes into the tombstone.
        hub.publish(makeContinuationThinkingEvent(id: "reused-event-id", seq: 3, turnID: "turn-old"))

        // A genuinely NEW session incarnation boundary — the tombstone
        // clears here (unlike `.sessionEnded`, which does NOT clear it —
        // see testSessionEndedPreservesTombstoneSoExactRetryStaysDropped).
        hub.publish(makeSessionStartedEvent(id: "session-started-1", seq: 4))
        hub.publish(makeAnchorThinkingEvent(id: "anchor-new", seq: 5, turnID: "turn-new"))
        // A brand-new, legitimate continuation for the NEW turn happens to
        // reuse the exact same eventID as the OLD suppressed one.
        hub.publish(makeContinuationThinkingEvent(id: "reused-event-id", seq: 6, turnID: "turn-new"))

        let events = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 100).events
        let reused = events.first { $0.eventID == "reused-event-id" }
        XCTAssertEqual(reused?.metadata?["turn_id"], "turn-new",
                       "a reused eventID after a session boundary must be accepted as the NEW event, not swallowed by the OLD tombstone, got \(events.map { ($0.eventID, $0.metadata ?? [:]) })")
    }

    // Corrected per Codex frozen review: `.sessionEnded` clears the tracked
    // turn but must NOT clear the `suppressedEventIDs` tombstone. Sequence:
    // anchor A opens; a native prompt opens; anchor B arrives while the
    // prompt is still active (suppressed/tombstoned, but B still
    // establishes currentTurnID since anchors always self-establish
    // regardless of ambient state); `.sessionEnded` fires (clears
    // currentTurnID, but the tombstone for B must survive); an EXACT retry
    // of the suppressed anchor B arrives; the prompt finally resolves. The
    // retry must never store/deliver, currentTurnID must never be
    // resurrected by it, and the resolve must synthesize ZERO resume — the
    // session already ended.
    func testSessionEndedPreservesTombstoneSoExactRetryStaysDropped() {
        let hub = AgentEventHub()
        hub.publish(makeAnchorThinkingEvent(id: "anchor-A", seq: 1, turnID: "turn-A"))
        hub.publish(makePromptEvent(id: "prompt-1", seq: 2, promptID: "p1", token: "tok-1"))
        // Anchor B arrives while the prompt is still active: suppressed
        // (tombstoned), but currentTurnID becomes B regardless.
        hub.publish(makeAnchorThinkingEvent(id: "anchor-B", seq: 3, turnID: "turn-B"))

        hub.publish(makeSessionEndedEvent(id: "session-ended-1", seq: 4))

        // Exact retry of the previously-suppressed anchor B.
        hub.publish(makeAnchorThinkingEvent(id: "anchor-B", seq: 5, turnID: "turn-B"))

        hub.publish(makeResolvedEvent(id: "resolved-1", seq: 6, promptID: "p1", token: "tok-1"))

        let events = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 100).events
        XCTAssertFalse(events.contains { $0.eventID == "anchor-B" },
                       "an exact retry of a suppressed anchor must never store/deliver after sessionEnded, got \(events.map(\.eventID))")
        XCTAssertFalse(events.contains { $0.metadata?["reason"] == "prompt_resolved_resume" },
                       "the already-ended session must never synthesize a resume from a lingering native prompt, got \(events.map { ($0.eventID, $0.metadata ?? [:]) })")
    }

    // MARK: - Round 7C focused fix #3: Working anchor identity fail-closed

    // A task_started anchor with a NIL turn_id must never be created/shown
    // — it would display Working with no matching-clearable tracked turn.
    func testTaskStartedAnchorWithNilTurnIDIsRejected() {
        let hub = AgentEventHub()
        let malformed = AgentEvent(eventID: "anchor-nil", seq: 1, vendor: "codex", workspaceID: "workspace",
                                   sessionID: "session", timestamp: "2026-01-01T00:00:00Z", type: .thinking,
                                   role: nil, text: nil, name: nil, input: nil, output: nil, toolCallID: nil,
                                   metadata: ["reason": "task_started"])
        hub.publish(malformed)

        let events = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 100).events
        XCTAssertFalse(events.contains { $0.eventID == "anchor-nil" },
                       "a task_started anchor with a nil turn_id must never store, got \(events.map(\.eventID))")
    }

    // Same for the deep-recovery bootstrap anchor, with a BLANK turn_id.
    func testBootstrapRecoveryAnchorWithBlankTurnIDIsRejected() {
        let hub = AgentEventHub()
        hub.publish(makeAnchorThinkingEvent(id: "anchor-blank", seq: 1, turnID: "   ", reason: "bootstrap_recovered_task_started"))

        let events = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 100).events
        XCTAssertFalse(events.contains { $0.eventID == "anchor-blank" },
                       "a bootstrap-recovery anchor with a blank turn_id must never store, got \(events.map(\.eventID))")
    }

    // MARK: - Round 7C focused fix #4/#5: Hub producer-domain (vendor) boundary

    // A vendor=claude event carrying task_started-shaped metadata is
    // ordinary — never establishes a Codex-tracked turn. A subsequent
    // genuinely native Codex prompt/resolved cycle must never synthesize a
    // resume off it (no turn was ever tracked).
    func testClaudeVendorTaskStartedNeverEstablishesFold() {
        let hub = AgentEventHub()
        let claudeAnchorShaped = AgentEvent(eventID: "claude-anchor", seq: 1, vendor: "claude", workspaceID: "workspace",
                                            sessionID: "session", timestamp: "2026-01-01T00:00:00Z", type: .thinking,
                                            role: nil, text: nil, name: nil, input: nil, output: nil, toolCallID: nil,
                                            metadata: ["reason": "task_started", "turn_id": "turn-1"])
        hub.publish(claudeAnchorShaped)
        // It must be stored/delivered as an ORDINARY event (not fail-closed
        // rejected like a malformed Codex anchor would be).
        var events = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 100).events
        XCTAssertTrue(events.contains { $0.eventID == "claude-anchor" },
                      "a non-Codex event must be treated as ordinary, not fail-closed rejected, got \(events.map(\.eventID))")

        hub.publish(makePromptEvent(id: "prompt-1", seq: 2, promptID: "p1", token: "tok-1", turnID: "turn-1"))
        hub.publish(makeResolvedEvent(id: "resolved-1", seq: 3, promptID: "p1", token: "tok-1", turnID: "turn-1"))
        events = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 100).events
        XCTAssertFalse(events.contains { $0.metadata?["reason"] == "prompt_resolved_resume" },
                       "a vendor=claude task_started-shaped event must never establish a tracked turn a native prompt could resume, got \(events.map { ($0.eventID, $0.metadata ?? [:]) })")
    }

    // After a REAL Codex anchor, a vendor=claude event shaped like
    // assistantFinal/turn_terminal must NOT clear the tracked turn — a
    // subsequent native prompt/resolved cycle for the SAME turn still
    // resumes exactly once.
    func testClaudeVendorTurnTerminalDoesNotClearCodexTrackedTurn() {
        let hub = AgentEventHub()
        hub.publish(makeAnchorThinkingEvent(id: "anchor-1", seq: 1, turnID: "turn-1"))
        let claudeTerminalShaped = AgentEvent(eventID: "claude-terminal", seq: 2, vendor: "claude", workspaceID: "workspace",
                                              sessionID: "session", timestamp: "2026-01-01T00:00:00Z", type: .assistantFinal,
                                              role: nil, text: nil, name: nil, input: nil, output: nil, toolCallID: nil,
                                              metadata: ["reason": "turn_terminal", "turn_id": "turn-1"])
        hub.publish(claudeTerminalShaped)

        hub.publish(makePromptEvent(id: "prompt-1", seq: 3, promptID: "p1", token: "tok-1", turnID: "turn-1"))
        hub.publish(makeResolvedEvent(id: "resolved-1", seq: 4, promptID: "p1", token: "tok-1", turnID: "turn-1"))

        let events = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 100).events
        let resumes = events.filter { $0.metadata?["reason"] == "prompt_resolved_resume" }
        XCTAssertEqual(resumes.count, 1,
                       "a vendor=claude turn_terminal-shaped event must never clear the Codex-tracked turn — exactly one native resume must still fire, got \(events.map { ($0.eventID, $0.metadata ?? [:]) })")
        XCTAssertEqual(resumes.first?.metadata?["turn_id"], "turn-1")
    }

    // A vendor=claude event carrying is_continuation=true metadata is
    // ordinary `.thinking` — stored normally, never subject to the Codex
    // reject/suppress identity gate (which would otherwise drop it for
    // having no Codex-tracked turn to match).
    func testClaudeVendorContinuationShapedEventStoresAsOrdinaryThinking() {
        let hub = AgentEventHub()
        let claudeContinuationShaped = AgentEvent(eventID: "claude-continuation", seq: 1, vendor: "claude", workspaceID: "workspace",
                                                  sessionID: "session", timestamp: "2026-01-01T00:00:00Z", type: .thinking,
                                                  role: nil, text: nil, name: nil, input: nil, output: nil, toolCallID: nil,
                                                  metadata: ["reason": "tool_call", "is_continuation": "true", "turn_id": "turn-1"])
        hub.publish(claudeContinuationShaped)

        let events = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 100).events
        XCTAssertTrue(events.contains { $0.eventID == "claude-continuation" },
                      "a vendor=claude is_continuation-shaped event must store as an ordinary thinking event, not be Codex-gate-rejected, got \(events.map(\.eventID))")
    }

    // A generic/Claude terminal with reason=turn_completed and a
    // free-form turn_id that HAPPENS to match the Codex-tracked turn must
    // only close ITS OWN prompt — never end the Codex-tracked turn (the
    // capability gate on endsTrackedTurn, not just resume, closes this).
    func testGenericTurnCompletedWithMatchingTurnIDOnlyClosesPromptNotCodexTurn() {
        let hub = AgentEventHub()
        hub.publish(makeAnchorThinkingEvent(id: "anchor-1", seq: 1, turnID: "turn-1"))
        hub.publish(legacyPrompt(id: "prompt-1", seq: 2, promptID: "p1"))
        let genericTurnCompleted = AgentEvent(eventID: "generic-resolved", seq: 3, vendor: "claude", workspaceID: "workspace",
                                              sessionID: "session", timestamp: "2026-01-01T00:00:00Z", type: .interactivePromptResolved,
                                              role: nil, text: nil, name: nil, input: nil, output: nil, toolCallID: nil,
                                              metadata: ["prompt_id": "p1", "reason": "turn_completed", "turn_id": "turn-1",
                                                        "source": "claude_ask_user_question"])
        hub.publish(genericTurnCompleted)

        // The Codex-tracked turn must survive: a later genuine native
        // prompt/resolved cycle for the SAME turn must still resume it.
        hub.publish(makePromptEvent(id: "prompt-2", seq: 4, promptID: "p2", token: "tok-2", turnID: "turn-1"))
        hub.publish(makeResolvedEvent(id: "resolved-2", seq: 5, promptID: "p2", token: "tok-2", turnID: "turn-1"))
        let events = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 100).events
        let resume = events.first { $0.metadata?["reason"] == "prompt_resolved_resume" }
        XCTAssertEqual(resume?.metadata?["turn_id"], "turn-1",
                       "a generic/Claude turn_completed (even with a matching free-form turn_id) must never end the Codex-tracked turn, got \(events.map { ($0.eventID, $0.metadata ?? [:]) })")
    }

    // Isolates the native-capability gate specifically for turn_completed's
    // tri-state (as opposed to turn_id matching, exercised above): a
    // non-Codex-native (vendor=claude) opener+terminal pair with a
    // genuinely MATCHING turn_id (both sides carry it, consistent with each
    // other AND with the Codex-tracked turn) must STILL never end the
    // Codex-tracked turn — capability is required independently of turn_id
    // agreement.
    func testTurnCompletedCapabilityGateAppliesEvenWithMatchingTurnIDOnBothSides() {
        let hub = AgentEventHub()
        hub.publish(makeAnchorThinkingEvent(id: "anchor-1", seq: 1, turnID: "turn-1"))
        let genericOpener = AgentEvent(eventID: "generic-prompt", seq: 2, vendor: "claude", workspaceID: "workspace",
                                       sessionID: "session", timestamp: "2026-01-01T00:00:00Z", type: .interactivePrompt,
                                       role: nil, text: nil, name: nil, input: nil, output: nil, toolCallID: nil,
                                       metadata: ["prompt_id": "p1", "source": "claude_ask_user_question", "turn_id": "turn-1"])
        hub.publish(genericOpener)
        let genericTurnCompleted = AgentEvent(eventID: "generic-resolved", seq: 3, vendor: "claude", workspaceID: "workspace",
                                              sessionID: "session", timestamp: "2026-01-01T00:00:00Z", type: .interactivePromptResolved,
                                              role: nil, text: nil, name: nil, input: nil, output: nil, toolCallID: nil,
                                              metadata: ["prompt_id": "p1", "reason": "turn_completed", "turn_id": "turn-1",
                                                        "source": "claude_ask_user_question"])
        hub.publish(genericTurnCompleted)

        hub.publish(makePromptEvent(id: "prompt-2", seq: 4, promptID: "p2", token: "tok-2", turnID: "turn-1"))
        hub.publish(makeResolvedEvent(id: "resolved-2", seq: 5, promptID: "p2", token: "tok-2", turnID: "turn-1"))
        let events = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 100).events
        let resume = events.first { $0.metadata?["reason"] == "prompt_resolved_resume" }
        XCTAssertEqual(resume?.metadata?["turn_id"], "turn-1",
                       "a non-native opener/terminal pair must never end the Codex-tracked turn even with a genuinely matching turn_id on both sides, got \(events.map { ($0.eventID, $0.metadata ?? [:]) })")
    }
}
