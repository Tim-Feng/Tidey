import XCTest
@testable import RemoteBridge

final class AgentEventHubTests: XCTestCase {
    func testReplayHidesPromptWhenHistoricalClosureCoverageIsUnknown() {
        let hub = AgentEventHub()
        let prompt = makePromptEvent(id: "poisoned-opener",
                                     seq: 10,
                                     promptID: "prompt",
                                     token: "token",
                                     vendor: "claude",
                                     source: "claude_ask_user_question")
        hub.publish(prompt)
        hub.setHistoricalClosureCoverage(sessionID: "session", isComplete: false)

        let (subscriptionID, replay) = hub.subscribe(workspaceID: "workspace",
                                                     sessionID: "session") { _ in }
        defer { hub.unsubscribe(subscriptionID) }

        XCTAssertFalse(replay.contains { $0.event.eventID == prompt.eventID },
                       "reconnect replay must not resurrect an opener with unknown closure coverage")
    }

    func testHistoricalOpenerResolutionKindsPreserveCursorFiltering() {
        let hub = AgentEventHub()
        hub.publish(makeAssistantEvent(id: "visible-opener", seq: 10))
        hub.publish(makeAssistantEvent(id: "silent-opener", seq: 11))
        hub.replaceHistoricalOpenerResolutions(
            sessionID: "session",
            resolutions: [
                "visible-opener": .visibleTerminal(eventID: "terminal", sequence: 20),
                "silent-opener": .silentConsumer(sequence: 20),
            ])

        let result = hub.fetch(workspaceID: "workspace",
                               sessionID: "session",
                               limit: 20,
                               beforeSeq: 20)

        XCTAssertTrue(result.events.isEmpty)
    }

    func testBeforeCursorProjectsVisiblePairsAndSilentConsumersWithoutDeletingStorage() {
        let hub = AgentEventHub()
        let prompt = makePromptEvent(id: "visible-opener",
                                     seq: 10,
                                     promptID: "prompt",
                                     token: nil,
                                     vendor: "claude",
                                     source: "claude_ask_user_question")
        let silentContext = makeContextEvent(id: "silent-context",
                                             seq: 11,
                                             kind: "claude_context_command")
        let terminal = makeResolvedEvent(id: "visible-terminal",
                                         seq: 20,
                                         promptID: "prompt",
                                         token: nil,
                                         vendor: "claude",
                                         source: "claude_ask_user_question")
        hub.publish(prompt)
        hub.publish(silentContext)
        hub.publish(terminal)
        hub.replaceHistoricalOpenerResolutions(
            sessionID: "session",
            resolutions: [
                prompt.eventID: .visibleTerminal(eventID: terminal.eventID, sequence: terminal.seq),
                silentContext.eventID: .silentConsumer(sequence: 15),
            ])

        let beforeTerminal = hub.fetch(workspaceID: "workspace",
                                       sessionID: "session",
                                       limit: 20,
                                       beforeSeq: terminal.seq)
        XCTAssertFalse(beforeTerminal.events.contains { $0.eventID == prompt.eventID })
        XCTAssertFalse(beforeTerminal.events.contains { $0.eventID == silentContext.eventID })

        let afterTerminal = hub.fetch(workspaceID: "workspace",
                                      sessionID: "session",
                                      limit: 20,
                                      beforeSeq: terminal.seq + 1)
        XCTAssertTrue(afterTerminal.events.contains { $0.eventID == prompt.eventID })
        XCTAssertTrue(afterTerminal.events.contains { $0.eventID == terminal.eventID })
        XCTAssertFalse(afterTerminal.events.contains { $0.eventID == silentContext.eventID },
                       "a silent consumer has no visible partner in any before-history page")

        let latest = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 20)
        XCTAssertTrue(latest.events.contains { $0.eventID == silentContext.eventID },
                      "history projection must not permanently delete the raw command")
    }

    func testHistoricalReplayRefillsEvictedLiveTerminalDespiteSeenTombstone() {
        let hub = AgentEventHub(maxBufferedEvents: 2, maxSeenEventIDs: 100)
        let opener = makePromptEvent(id: "historical-opener",
                                     seq: 10,
                                     promptID: "prompt",
                                     token: nil,
                                     vendor: "claude",
                                     source: "claude_ask_user_question")
        let terminal = makeResolvedEvent(id: "evicted-terminal",
                                         seq: 20,
                                         promptID: "prompt",
                                         token: nil,
                                         vendor: "claude",
                                         source: "claude_ask_user_question")
        hub.publish(terminal)
        hub.publish(makeAssistantEvent(id: "later-live-1", seq: 30))
        hub.publish(makeAssistantEvent(id: "later-live-2", seq: 31))
        hub.replaceHistoricalOpenerResolutions(
            sessionID: "session",
            resolutions: [
                opener.eventID: .visibleTerminal(eventID: terminal.eventID, sequence: terminal.seq),
            ])

        hub.publish(opener, deliverToSubscribers: false, storage: .historicalBackfill)
        hub.publish(terminal, deliverToSubscribers: false, storage: .historicalBackfill)

        let result = hub.fetch(workspaceID: "workspace",
                               sessionID: "session",
                               limit: 20,
                               beforeSeq: 32)
        XCTAssertTrue(result.events.contains { $0.eventID == opener.eventID })
        XCTAssertTrue(result.events.contains { $0.eventID == terminal.eventID },
                      "an evicted live terminal must be eligible for historical storage again")
    }

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
        // The late arrival that claims seq 11 after 12 was stored must move
        // above the stored high-water, otherwise an advanced cursor can miss
        // it permanently.
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

    func testNewSourceEpochRevokesStoredIdentityButPreservesCursorAuthority() {
        let hub = AgentEventHub()
        hub.publish(makeAssistantEvent(id: "shared-id", seq: 10, text: "old source"))
        XCTAssertEqual(hub.nextSyntheticSeq(sessionID: "session"), 11)

        hub.beginNewSourceEpoch(sessionID: "session")

        XCTAssertTrue(hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 10).events.isEmpty)
        hub.publish(makeAssistantEvent(id: "shared-id", seq: 1, text: "new source"))
        let replacement = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 10).events
        XCTAssertEqual(replacement.map(\.text), ["new source"])
        XCTAssertEqual(replacement.map(\.seq), [12])
        XCTAssertEqual(hub.nextSyntheticSeq(sessionID: "session"), 13)
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

    // MARK: Live sequence authority

    func testReservedSeqTakenByNativePublishRebasesSyntheticEvent() {
        let hub = AgentEventHub()
        let reserved = hub.nextSyntheticSeq(sessionID: "session")
        hub.publish(makeAssistantEvent(id: "native", seq: reserved))
        hub.publish(makeAssistantEvent(id: "synthetic", seq: reserved))

        let all = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 10)
        XCTAssertEqual(all.events.count, 2)
        XCTAssertEqual(Set(all.events.map(\.seq)).count, 2)

        let first = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 1, afterSeq: 0)
        XCTAssertEqual(first.events.count, 1)
        let second = hub.fetch(workspaceID: "workspace",
                               sessionID: "session",
                               limit: 10,
                               afterSeq: first.events[0].seq)
        XCTAssertEqual(second.events.count, 1,
                       "the second event must remain reachable from the catch-up cursor")
        XCTAssertNotEqual(second.events[0].eventID, first.events[0].eventID)
    }

    func testBatchReservationsStayUniqueAgainstInterleavedNativePublishes() {
        let hub = AgentEventHub()
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
                       "all published events must own distinct cursor positions")
    }

    func testNativeHighSeqLiftsNextSyntheticReservation() {
        let hub = AgentEventHub()
        hub.publish(makeAssistantEvent(id: "native-high", seq: 100))

        let reserved = hub.nextSyntheticSeq(sessionID: "session")

        XCTAssertGreaterThan(reserved, 100)
    }

    func testLateUnseenLowerSeqIsRebasedAboveHighWater() throws {
        let hub = AgentEventHub()
        var liveSeqs = [Int]()
        let (subscriptionID, _) = hub.subscribe(workspaceID: "workspace", sessionID: "session") { envelope in
            liveSeqs.append(envelope.event.seq)
        }
        defer { hub.unsubscribe(subscriptionID) }

        hub.publish(makeAssistantEvent(id: "high", seq: 100))
        hub.publish(makeAssistantEvent(id: "late", seq: 50))

        let catchUp = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 10, afterSeq: 100)
        let late = try XCTUnwrap(catchUp.events.first)
        XCTAssertEqual(catchUp.events.map(\.eventID), ["late"])
        XCTAssertGreaterThan(late.seq, 100)
        XCTAssertEqual(liveSeqs.count, 2)
        XCTAssertGreaterThan(liveSeqs[1], liveSeqs[0])
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

    func testReservationsPublishedOutOfOrderStayMonotonic() {
        let hub = AgentEventHub()
        let r1 = hub.nextSyntheticSeq(sessionID: "session")
        let r2 = hub.nextSyntheticSeq(sessionID: "session")
        hub.publish(makeAssistantEvent(id: "second-reserved", seq: r2))
        hub.publish(makeAssistantEvent(id: "first-reserved", seq: r1))

        let all = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 10)
        let firstSeq = all.events.first { $0.eventID == "first-reserved" }!.seq
        let secondSeq = all.events.first { $0.eventID == "second-reserved" }!.seq
        XCTAssertEqual(Set(all.events.map(\.seq)).count, 2)
        XCTAssertGreaterThan(firstSeq, secondSeq)
        XCTAssertEqual(hub.fetch(workspaceID: "workspace",
                                 sessionID: "session",
                                 limit: 10,
                                 afterSeq: secondSeq).events.map(\.eventID),
                       ["first-reserved"])
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

    func testSameEventIDRepublishDoesNotConsumeSequence() {
        let hub = AgentEventHub()
        let reserved = hub.nextSyntheticSeq(sessionID: "session")
        hub.publish(makeAssistantEvent(id: "same", seq: reserved, text: "original"))
        hub.publish(makeAssistantEvent(id: "same", seq: reserved, text: "duplicate"))

        let all = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 10)
        XCTAssertEqual(all.events.map(\.eventID), ["same"])
        XCTAssertEqual(all.events.map(\.seq), [reserved])
        XCTAssertEqual(hub.nextSyntheticSeq(sessionID: "session"), reserved + 1)
    }

    // MARK: Historical storage

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

    func testHistoricalReplacementRejectsWrongSessionEvents() {
        let hub = AgentEventHub()
        hub.publish(makeSessionEvent(id: "a-live", seq: 100, sessionID: "session-A"))
        hub.publish(makeSessionEvent(id: "b-live", seq: 100, sessionID: "session-B"))

        hub.replaceHistoricalEvents(sessionID: "session-A",
                                    events: [makeSessionEvent(id: "b-history", seq: 10, sessionID: "session-B"),
                                             makeSessionEvent(id: "a-history", seq: 10, sessionID: "session-A")])

        let fetchA = hub.fetch(workspaceID: "workspace", sessionID: "session-A", limit: 10).events
        XCTAssertEqual(fetchA.map(\.eventID), ["a-history", "a-live"])
        let workspaceWide = hub.fetch(workspaceID: "workspace", limit: 10).events
        XCTAssertFalse(workspaceWide.contains { $0.eventID == "b-history" })
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

    // MARK: Prompt lifecycle trim

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

    func testLatestResolvedLookupFailsClosedForCapabilityTokenlessOpener() {
        let hub = AgentEventHub()
        hub.publish(makeResolvedEvent(id: "legacy-terminal", seq: 10, promptID: "p1", token: nil,
                                      vendor: "claude", source: "claude_ask_user_question"))

        XCTAssertNotNil(hub.latestInteractivePromptResolvedEvent(workspaceID: "workspace",
                                                                 sessionID: "session",
                                                                 promptID: "p1",
                                                                 lifecycleToken: nil,
                                                                 openerRequiresCapability: false))
        XCTAssertNil(hub.latestInteractivePromptResolvedEvent(workspaceID: "workspace",
                                                              sessionID: "session",
                                                              promptID: "p1",
                                                              lifecycleToken: nil,
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
                                    events: [makeContextEvent(id: "command-1", seq: 10, kind: "claude_context_command"),
                                             makeContextEvent(id: "command-2", seq: 20, kind: "claude_context_command"),
                                             makeContextEvent(id: "summary-2", seq: 30, kind: "claude_context")],
                                    anchorSeq: 22)

        let stored = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 100, beforeSeq: 1000)
            .events.map(\.eventID)
        XCTAssertTrue(stored.contains("command-1"),
                      "the second command's summary must not close the first command")
        XCTAssertFalse(stored.contains("command-2") && stored.contains("summary-2") == false,
                       "a context command and its summary must not be trimmed into a partial group")
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
                          payload: .object([
                            "prompt_id": .string(promptID),
                            "vendor": .string(vendor),
                            "source": .string(source),
                            "title": .string("Approve?"),
                            "body": .string("Command: ls"),
                            "selected_index": .number(0),
                            "options": .array([
                                .object([
                                    "index": .number(0),
                                    "label": .string("Yes"),
                                    "input_sequence": .string("accept"),
                                ]),
                            ]),
                          ]))
    }

    private func makeResolvedEvent(id: String,
                                   seq: Int,
                                   promptID: String,
                                   token: String?,
                                   vendor: String = "codex",
                                   source: String = "codex_command_approval") -> AgentEvent {
        var metadata = ["prompt_id": promptID, "source": source]
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
                          metadata: metadata)
    }

    // Lease seam lifecycle: begin-copy window, truncation, consume-once,
    // idempotent cancel, and epoch-reset invalidation. Eviction-watermark
    // and publish-accumulation behavior are covered by their own tests
    // below.
    func testAfterCursorLiveLeaseSeamCopiesRequestStartWindowAndConsumesOnce() throws {
        let hub = AgentEventHub()
        for seq in 1...5 {
            hub.publish(makeAssistantEvent(id: "live-\(seq)", seq: seq), deliverToSubscribers: false)
        }
        let epoch = hub.currentHistoryEpoch(sessionID: "session")
        XCTAssertEqual(epoch, AgentHistoryEpoch(sessionID: "session", generation: 0))

        let lease = hub.beginAfterCursorLiveLease(sessionID: "session", afterSeq: 2, capacity: 2)
        XCTAssertEqual(lease.evidence.epoch, epoch)
        XCTAssertNil(lease.evidence.evictedThroughSeqAtLeaseStart)
        XCTAssertTrue(lease.evidence.containsEveryAcceptedLiveEvent(afterSeq: 2))

        let snapshot = try XCTUnwrap(hub.finishAfterCursorLiveLease(lease.token))
        XCTAssertEqual(snapshot.events.map(\.seq), [3, 4],
                       "the lease retains the EARLIEST events above the cursor")
        XCTAssertTrue(snapshot.truncated, "seq 5 exceeded capacity")
        XCTAssertNil(hub.finishAfterCursorLiveLease(lease.token), "finish consumes the token")
        hub.cancelAfterCursorLiveLease(lease.token)

        let second = hub.beginAfterCursorLiveLease(sessionID: "session", afterSeq: 0, capacity: 10)
        hub.beginNewSourceEpoch(sessionID: "session")
        XCTAssertNil(hub.finishAfterCursorLiveLease(second.token),
                     "a sourceChanged lease must not serve retired-source events")
        XCTAssertEqual(hub.currentHistoryEpoch(sessionID: "session").generation, 1)
    }

    func testEmptySessionEpochResetInvalidatesLeaseAndAdvancesGeneration() {
        let hub = AgentEventHub()
        // No SessionState exists yet: a lease can still be begun (empty
        // window), so a reset MUST still invalidate it — otherwise finish
        // serves a retired-epoch snapshot.
        let lease = hub.beginAfterCursorLiveLease(sessionID: "session", afterSeq: 0, capacity: 10)

        hub.beginNewSourceEpoch(sessionID: "session")

        XCTAssertNil(hub.finishAfterCursorLiveLease(lease.token),
                     "a reset before any stored event must still mark the lease sourceChanged")
        XCTAssertEqual(hub.currentHistoryEpoch(sessionID: "session").generation, 1,
                       "the Hub-issued generation must advance even for an empty session")
    }

    func testLiveEvictionWatermarkFeedsLeaseEvidence() {
        let hub = AgentEventHub(maxBufferedEvents: 2, maxSeenEventIDs: 100)
        for seq in 1...4 {
            hub.publish(makeAssistantEvent(id: "evict-\(seq)", seq: seq), deliverToSubscribers: false)
        }
        // Capacity 2 keeps [3,4]; seq 1...2 were evicted from the LIVE buffer.
        let lease = hub.beginAfterCursorLiveLease(sessionID: "session", afterSeq: 0, capacity: 10)
        XCTAssertEqual(lease.evidence.evictedThroughSeqAtLeaseStart, 2,
                       "the watermark is the highest accepted live seq the buffer evicted")
        XCTAssertFalse(lease.evidence.containsEveryAcceptedLiveEvent(afterSeq: 1),
                       "a cursor below the watermark cannot trust the retained window")
        XCTAssertTrue(lease.evidence.containsEveryAcceptedLiveEvent(afterSeq: 2))
        XCTAssertTrue(lease.evidence.containsEveryAcceptedLiveEvent(afterSeq: 3))
        hub.cancelAfterCursorLiveLease(lease.token)
    }

    func testHistoricalReplacementDoesNotTouchEvictionWatermark() {
        let hub = AgentEventHub(maxBufferedEvents: 100, maxSeenEventIDs: 100)
        for seq in 5...8 {
            hub.publish(makeAssistantEvent(id: "live-\(seq)", seq: seq), deliverToSubscribers: false)
        }
        hub.replaceHistoricalEvents(sessionID: "session",
                                    events: (1...3).map { makeAssistantEvent(id: "hist-\($0)", seq: $0) })

        let lease = hub.beginAfterCursorLiveLease(sessionID: "session", afterSeq: 0, capacity: 10)
        XCTAssertNil(lease.evidence.evictedThroughSeqAtLeaseStart,
                     "historical cache replacement is not a live eviction")
        hub.cancelAfterCursorLiveLease(lease.token)
    }

    func testEpochResetClearsWatermarkAndPreservesCursorAuthority() {
        let hub = AgentEventHub(maxBufferedEvents: 2, maxSeenEventIDs: 100)
        for seq in 1...4 {
            hub.publish(makeAssistantEvent(id: "pre-\(seq)", seq: seq), deliverToSubscribers: false)
        }
        hub.beginNewSourceEpoch(sessionID: "session")

        let lease = hub.beginAfterCursorLiveLease(sessionID: "session", afterSeq: 0, capacity: 10)
        XCTAssertNil(lease.evidence.evictedThroughSeqAtLeaseStart,
                     "the watermark described the retired buffer and must reset")
        XCTAssertEqual(lease.evidence.epoch.generation, 1)
        hub.cancelAfterCursorLiveLease(lease.token)

        // Cursor authority survives the reset: a replacement-source event
        // reusing a low seq must rebase above the old high water.
        let accepted = hub.publish(makeAssistantEvent(id: "replacement-1", seq: 1),
                                   deliverToSubscribers: false)
        XCTAssertEqual(accepted?.seq, 5,
                       "high-water/reservation must not be cleared by the epoch reset")
    }

    func testAfterCursorLeaseCapturesAcceptedRebasedLivePublishesExactlyOnce() throws {
        let hub = AgentEventHub(maxBufferedEvents: 100, maxSeenEventIDs: 100)
        for seq in 1...4 {
            hub.publish(makeAssistantEvent(id: "seed-\(seq)", seq: seq), deliverToSubscribers: false)
        }
        let lease = hub.beginAfterCursorLiveLease(sessionID: "session", afterSeq: 2, capacity: 10)
        let highCursorLease = hub.beginAfterCursorLiveLease(sessionID: "session", afterSeq: 100, capacity: 10)
        // The session moves workspaces AFTER the lease began: the lease must
        // keep its captured raw values and never re-project at finish.
        hub.migrateSession(sessionID: "session", toWorkspaceID: "workspace-moved", panelID: nil)

        hub.publish(makeAssistantEvent(id: "live-5", seq: 5), deliverToSubscribers: false)
        hub.publish(makeAssistantEvent(id: "live-5", seq: 5), deliverToSubscribers: false)   // duplicate: rejected
        let rebased = hub.publish(makeAssistantEvent(id: "live-low", seq: 3), deliverToSubscribers: false)
        XCTAssertEqual(rebased?.seq, 6, "precondition: the low-seq publish must be rebased")
        hub.publish(makeSessionEvent(id: "foreign-1", seq: 7, sessionID: "other-session"),
                    deliverToSubscribers: false)
        hub.publish(makeAssistantEvent(id: "hist-1", seq: 1),
                    deliverToSubscribers: false,
                    storage: .historicalBackfill)

        let snapshot = try XCTUnwrap(hub.finishAfterCursorLiveLease(lease.token))
        XCTAssertEqual(snapshot.events.map(\.eventID),
                       ["seed-3", "seed-4", "live-5", "live-low"],
                       "accepted liveForward publishes enter the lease exactly once")
        XCTAssertEqual(snapshot.events.map(\.seq), [3, 4, 5, 6],
                       "the lease stores the accepted/rebased seq")
        XCTAssertEqual(snapshot.events.map(\.workspaceID),
                       Array(repeating: "workspace", count: 4),
                       "lease events stay raw — the current binding applies only at final assembly")

        let highSnapshot = try XCTUnwrap(hub.finishAfterCursorLiveLease(highCursorLease.token))
        XCTAssertTrue(highSnapshot.events.isEmpty,
                      "publishes at or below the cursor never enter a lease")
    }

    func testAfterCursorLeaseKeepsEarliestCapacityAcrossPublishAndBufferEviction() throws {
        let hub = AgentEventHub(maxBufferedEvents: 2, maxSeenEventIDs: 100)
        let lease = hub.beginAfterCursorLiveLease(sessionID: "session", afterSeq: 0, capacity: 2)
        for seq in 1...3 {
            hub.publish(makeAssistantEvent(id: "pub-\(seq)", seq: seq), deliverToSubscribers: false)
        }
        // The live buffer (capacity 2) evicted seq 1; the lease still owns it.
        let snapshot = try XCTUnwrap(hub.finishAfterCursorLiveLease(lease.token))
        XCTAssertEqual(snapshot.events.map(\.seq), [1, 2],
                       "the lease keeps the EARLIEST capacity events exactly once each")
        XCTAssertTrue(snapshot.truncated, "seq 3 exceeded the lease capacity")
    }

    func testLeaseEvidenceRecordsRebasedEvictionAndIgnoresHistoricalPaths() throws {
        let hub = AgentEventHub(maxBufferedEvents: 1, maxSeenEventIDs: 100)
        hub.publish(makeAssistantEvent(id: "a", seq: 5), deliverToSubscribers: false)
        let rebased = hub.publish(makeAssistantEvent(id: "b", seq: 2), deliverToSubscribers: false)
        XCTAssertEqual(rebased?.seq, 6, "precondition: the low incoming seq must be rebased")
        hub.publish(makeAssistantEvent(id: "c", seq: 9), deliverToSubscribers: false)

        // The rebased event itself was evicted: the watermark must be its
        // REBASED seq (6), never the incoming raw seq (2).
        let lease = hub.beginAfterCursorLiveLease(sessionID: "session", afterSeq: 0, capacity: 10)
        XCTAssertEqual(lease.evidence.evictedThroughSeqAtLeaseStart, 6)
        hub.cancelAfterCursorLiveLease(lease.token)

        // With the watermark non-nil, historical paths must not move it:
        // window replacement AND a historicalBackfill publish whose cache
        // trim also evicts (capacity 1).
        hub.replaceHistoricalEvents(sessionID: "session",
                                    events: (1...2).map { makeAssistantEvent(id: "hist-\($0)", seq: $0) })
        hub.publish(makeAssistantEvent(id: "hist-3", seq: 3),
                    deliverToSubscribers: false,
                    storage: .historicalBackfill)
        let after = hub.beginAfterCursorLiveLease(sessionID: "session", afterSeq: 0, capacity: 10)
        XCTAssertEqual(after.evidence.evictedThroughSeqAtLeaseStart, 6,
                       "historical replacement/backfill trims are not live evictions")

        // cancel -> cancel -> finish: cancel is idempotent and consuming.
        hub.cancelAfterCursorLiveLease(after.token)
        hub.cancelAfterCursorLiveLease(after.token)
        XCTAssertNil(hub.finishAfterCursorLiveLease(after.token))
    }

    private func makeContextEvent(id: String, seq: Int, kind: String) -> AgentEvent {
        AgentEvent(eventID: id,
                   seq: seq,
                   vendor: "claude",
                   workspaceID: "workspace",
                   sessionID: "session",
                   timestamp: "2026-01-01T00:00:00Z",
                   type: kind == "claude_context" ? .assistantMessage : .userMessage,
                   role: kind == "claude_context" ? "assistant" : "user",
                   text: "context",
                   name: nil,
                   input: nil,
                   output: nil,
                   toolCallID: nil,
                   metadata: ["tidey_generated": kind])
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
