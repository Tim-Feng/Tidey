import XCTest
@testable import RemoteBridge

final class ClaudeTranscriptSessionTests: XCTestCase {
    func testClaudeHistoricalClosureIndexStatsStartAtZero() {
        let session = ClaudeTranscriptSession(
            record: makeRecord(transcriptPath: "/tmp/unused-claude-transcript.jsonl"),
            hub: AgentEventHub())

        XCTAssertEqual(session.historicalClosureIndexStatsForTesting(),
                       ClaudeHistoricalClosureIndexStats(scanPassCount: 0,
                                                         readByteCount: 0,
                                                         completeLineCount: 0))
    }

    func testClaudeHistoricalClosureIndexOnlyScansAppendedSuffix() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeTranscriptSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcriptURL = directory.appendingPathComponent("session.jsonl", isDirectory: false)
        let initialLines = (0..<8).map {
            makeClaudeUserLine(uuid: "initial-\($0)", content: "initial-\($0)")
        }
        let initialPayload = initialLines.joined(separator: "\n") + "\n"
        try initialPayload.write(to: transcriptURL, atomically: true, encoding: .utf8)

        let hub = AgentEventHub()
        let session = ClaudeTranscriptSession(record: makeRecord(transcriptPath: transcriptURL.path),
                                              fileManager: .default,
                                              hub: hub)
        session.start()
        defer { session.stop() }
        XCTAssertTrue(waitUntil {
            hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 20)
                .events.contains { $0.text == "initial-7" }
        })
        let initialAnchor = try XCTUnwrap(
            hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 20)
                .events.first { $0.text == "initial-7" }?.seq
        )

        XCTAssertTrue(session.backfill(beforeSeq: initialAnchor, limit: 2))
        let afterInitialScan = session.historicalClosureIndexStatsForTesting()
        XCTAssertEqual(afterInitialScan,
                       ClaudeHistoricalClosureIndexStats(scanPassCount: 1,
                                                         readByteCount: initialPayload.utf8.count,
                                                         completeLineCount: initialLines.count))

        XCTAssertTrue(session.backfill(beforeSeq: initialAnchor, limit: 2))
        XCTAssertEqual(session.historicalClosureIndexStatsForTesting(), afterInitialScan,
                       "a repeated page request without an append must read no transcript bytes")

        let appendedLines = (0..<3).map {
            makeClaudeUserLine(uuid: "appended-\($0)", content: "appended-\($0)")
        }
        let appendedPayload = appendedLines.joined(separator: "\n") + "\n"
        let handle = try FileHandle(forWritingTo: transcriptURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(appendedPayload.utf8))
        try handle.close()
        XCTAssertTrue(waitUntil {
            hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 20)
                .events.contains { $0.text == "appended-2" }
        })
        let appendedAnchor = try XCTUnwrap(
            hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 20)
                .events.first { $0.text == "appended-2" }?.seq
        )

        XCTAssertTrue(session.backfill(beforeSeq: appendedAnchor, limit: 2))
        let afterSuffixScan = session.historicalClosureIndexStatsForTesting()
        XCTAssertEqual(afterSuffixScan,
                       ClaudeHistoricalClosureIndexStats(
                           scanPassCount: 2,
                           readByteCount: initialPayload.utf8.count + appendedPayload.utf8.count,
                           completeLineCount: initialLines.count + appendedLines.count))

        XCTAssertTrue(session.backfill(beforeSeq: appendedAnchor, limit: 2))
        XCTAssertEqual(session.historicalClosureIndexStatsForTesting(), afterSuffixScan,
                       "an indexed suffix must not be scanned again")
    }

    func testClaudeHistoricalClosureIndexRetainsUnterminatedTailWithoutRereading() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeTranscriptSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcriptURL = directory.appendingPathComponent("session.jsonl", isDirectory: false)
        let promptID = "toolu_partial_tail"
        let askLine = makeClaudeAskUserQuestionAssistantLine(uuid: "partial-ask",
                                                             toolCallID: promptID)
        let fillerLines = (0..<transcriptBootstrapLineLimit).map {
            makeClaudeUserLine(uuid: "initial-\($0)", content: "initial-\($0)")
        }
        let initialLines = [askLine] + fillerLines
        let initialPayload = initialLines.joined(separator: "\n") + "\n"
        try initialPayload.write(to: transcriptURL, atomically: true, encoding: .utf8)

        let hub = AgentEventHub()
        let session = ClaudeTranscriptSession(record: makeRecord(transcriptPath: transcriptURL.path),
                                              fileManager: .default,
                                              hub: hub)
        session.start()
        defer { session.stop() }
        XCTAssertTrue(waitUntil {
            hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 20)
                .events.contains { $0.text == "initial-\(transcriptBootstrapLineLimit - 1)" }
        })
        let initialAnchor = try XCTUnwrap(
            hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 20)
                .events.first { $0.text == "initial-\(transcriptBootstrapLineLimit - 1)" }?.seq
        )
        XCTAssertTrue(session.backfill(beforeSeq: initialAnchor, limit: 2))
        let baseline = session.historicalClosureIndexStatsForTesting()
        XCTAssertEqual(baseline,
                       ClaudeHistoricalClosureIndexStats(scanPassCount: 1,
                                                         readByteCount: initialPayload.utf8.count,
                                                         completeLineCount: initialLines.count))

        let partialLine = makeClaudeToolResultLine(uuid: "partial-result",
                                                   toolCallID: promptID,
                                                   content: "已回答")
        let partialLineData = Data(partialLine.utf8)
        let multibyteRange = try XCTUnwrap(partialLineData.range(of: Data("已".utf8)))
        let splitOffset = partialLineData.distance(from: partialLineData.startIndex,
                                                   to: multibyteRange.lowerBound) + 1
        let partialPrefix = Data(partialLineData.prefix(splitOffset))
        var partialCompletion = Data(partialLineData.dropFirst(splitOffset))
        partialCompletion.append(0x0a)
        let partialHandle = try FileHandle(forWritingTo: transcriptURL)
        try partialHandle.seekToEnd()
        try partialHandle.write(contentsOf: partialPrefix)
        try partialHandle.close()

        XCTAssertTrue(session.backfill(beforeSeq: initialAnchor, limit: 2))
        let afterPartialScan = session.historicalClosureIndexStatsForTesting()
        XCTAssertEqual(afterPartialScan,
                       ClaudeHistoricalClosureIndexStats(
                           scanPassCount: 2,
                           readByteCount: initialPayload.utf8.count + partialPrefix.count,
                           completeLineCount: initialLines.count))

        XCTAssertTrue(session.backfill(beforeSeq: initialAnchor, limit: 2))
        XCTAssertEqual(session.historicalClosureIndexStatsForTesting(), afterPartialScan,
                       "an unchanged partial record must not be reread")

        let completionHandle = try FileHandle(forWritingTo: transcriptURL)
        try completionHandle.seekToEnd()
        try completionHandle.write(contentsOf: partialCompletion)
        try completionHandle.close()
        XCTAssertTrue(waitUntil {
            hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 20)
                .events.contains { $0.type == .toolResult && $0.toolCallID == promptID }
        })
        let completedAnchor = try XCTUnwrap(
            hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 20)
                .events.first { $0.type == .toolResult && $0.toolCallID == promptID }?.seq
        )

        XCTAssertTrue(session.backfill(beforeSeq: completedAnchor, limit: 2))
        let afterPartialCompletion = session.historicalClosureIndexStatsForTesting()
        XCTAssertEqual(afterPartialCompletion,
                       ClaudeHistoricalClosureIndexStats(
                           scanPassCount: 3,
                           readByteCount: initialPayload.utf8.count
                               + partialPrefix.count
                               + partialCompletion.count,
                           completeLineCount: initialLines.count + 1))

        XCTAssertTrue(session.backfill(beforeSeq: completedAnchor, limit: 2))
        XCTAssertEqual(session.historicalClosureIndexStatsForTesting(), afterPartialCompletion,
                       "a completed partial record must advance both scan frontiers")

        let firstFillerOffset = (askLine + "\n").utf8.count
        let askPageAnchor = transcriptEventSequence(lineOffset: firstFillerOffset, ordinal: 0)
        let askPage = BridgeAgentEventFetchFlow.run(eventHub: hub,
                                                    workspaceID: "workspace",
                                                    sessionID: "session",
                                                    limit: 20,
                                                    beforeSeq: askPageAnchor,
                                                    afterSeq: nil) { _, anchor, limit in
            session.backfill(beforeSeq: anchor, limit: limit)
        }
        XCTAssertTrue(askPage.didBackfill)
        XCTAssertFalse(askPage.fetchResult.events.contains {
            $0.type == .interactivePrompt && $0.metadata?["prompt_id"] == promptID
        }, "the UTF-8 partial terminal must be reassembled and close its historical opener")
        XCTAssertNil(hub.activeInteractivePrompt(workspaceID: "workspace",
                                                  sessionID: "session",
                                                  promptID: promptID))
    }

    func testClaudeHistoricalClosureIndexFailsClosedForOversizedUnterminatedRecord() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeTranscriptSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcriptURL = directory.appendingPathComponent("session.jsonl", isDirectory: false)
        let initialLines = (0..<8).map {
            makeClaudeUserLine(uuid: "initial-\($0)", content: "initial-\($0)")
        }
        let initialPayload = initialLines.joined(separator: "\n") + "\n"
        try initialPayload.write(to: transcriptURL, atomically: true, encoding: .utf8)

        let partialLineByteLimit = 64
        let hub = AgentEventHub()
        let session = ClaudeTranscriptSession(
            record: makeRecord(transcriptPath: transcriptURL.path),
            fileManager: .default,
            hub: hub,
            historicalPartialLineByteLimit: partialLineByteLimit)
        session.start()
        defer { session.stop() }
        XCTAssertTrue(waitUntil {
            hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 20)
                .events.contains { $0.text == "initial-7" }
        })
        let anchor = try XCTUnwrap(
            hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 20)
                .events.first { $0.text == "initial-7" }?.seq
        )
        XCTAssertTrue(session.backfill(beforeSeq: anchor, limit: 2))

        let oversizedPartial = Data(repeating: 0x78, count: partialLineByteLimit + 1)
        let handle = try FileHandle(forWritingTo: transcriptURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: oversizedPartial)
        try handle.close()

        XCTAssertFalse(session.backfill(beforeSeq: anchor, limit: 2),
                       "unknown closure evidence after an oversized partial record must fail closed")
        let afterOversizedRecord = session.historicalClosureIndexStatsForTesting()
        XCTAssertEqual(afterOversizedRecord.readByteCount,
                       initialPayload.utf8.count + oversizedPartial.count)

        XCTAssertFalse(session.backfill(beforeSeq: anchor, limit: 2))
        XCTAssertEqual(session.historicalClosureIndexStatsForTesting(), afterOversizedRecord,
                       "a poisoned history index must not retain or reread the oversized suffix")
    }

    func testClaudeOversizedHistoryIndexHidesCachedOpenersFailClosed() throws {
        try assertClaudeHistoryIndexFailureHidesCachedOpener(
            appendedData: Data(repeating: 0x78, count: 1_025),
            partialLineByteLimit: 1_024)
    }

    func testClaudeMalformedHistoryRecordHidesCachedOpenersFailClosed() throws {
        try assertClaudeHistoryIndexFailureHidesCachedOpener(
            appendedData: Data("{not-json}\n".utf8),
            partialLineByteLimit: 1_024)
    }

    func testClaudeInvalidUTF8HistoryRecordHidesCachedOpenersFailClosed() throws {
        try assertClaudeHistoryIndexFailureHidesCachedOpener(
            appendedData: Data([0xff, 0x0a]),
            partialLineByteLimit: 1_024)
    }

    func testClaudeUnsupportedMajorHistoryRecordHidesCachedOpenersFailClosed() throws {
        let unsupportedTerminal = makeClaudeToolResultLine(
            uuid: "unsupported-result",
            toolCallID: "toolu_fail_closed",
            content: "future answer",
            version: "3.0.0")
        try assertClaudeHistoryIndexFailureHidesCachedOpener(
            appendedData: Data((unsupportedTerminal + "\n").utf8),
            partialLineByteLimit: 1_024)
    }

    func testClaudeNonStringVersionHistoryRecordHidesCachedOpenersFailClosed() throws {
        let terminal = makeClaudeToolResultLine(
            uuid: "numeric-history-result",
            toolCallID: "toolu_fail_closed",
            content: "unknown schema")
            .replacingOccurrences(of: "\"version\":\"2.0.0\"", with: "\"version\":3")
        try assertClaudeHistoryIndexFailureHidesCachedOpener(
            appendedData: Data((terminal + "\n").utf8),
            partialLineByteLimit: 1_024)
    }

    func testClaudeLiveInvalidRecordsHideBufferedPromptFailClosed() throws {
        let promptID = "toolu_live_invalid"
        let unsupportedTerminal = makeClaudeToolResultLine(
            uuid: "unsupported-live-result",
            toolCallID: promptID,
            content: "future answer",
            version: "3.0.0")
        let numericVersionTerminal = makeClaudeToolResultLine(
            uuid: "numeric-live-result",
            toolCallID: promptID,
            content: "unknown schema")
            .replacingOccurrences(of: "\"version\":\"2.0.0\"", with: "\"version\":3")
        let cases: [(name: String, data: Data)] = [
            ("malformed-json", Data("{not-json}\n".utf8)),
            ("invalid-utf8", Data([0xff, 0x0a])),
            ("unsupported-major", Data((unsupportedTerminal + "\n").utf8)),
            ("non-string-version", Data((numericVersionTerminal + "\n").utf8)),
        ]

        for testCase in cases {
            try assertClaudeLiveRecordFailureHidesBufferedOpener(
                appendedData: testCase.data,
                promptID: promptID,
                caseName: testCase.name)
        }
    }

    func testClaudeBootstrapInvalidUTF8RecordHidesBufferedPromptFailClosed() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeTranscriptSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcriptURL = directory.appendingPathComponent("session.jsonl", isDirectory: false)
        let promptID = "toolu_bootstrap_invalid"
        let askLine = makeClaudeAskUserQuestionAssistantLine(uuid: "bootstrap-invalid-ask",
                                                             toolCallID: promptID)
        let markerLine = makeClaudeUserLine(uuid: "bootstrap-invalid-marker",
                                            content: "bootstrap-invalid-ready")
        var payload = Data((askLine + "\n").utf8)
        payload.append(contentsOf: [0xff, 0x0a])
        payload.append(Data((markerLine + "\n").utf8))
        try payload.write(to: transcriptURL)

        let hub = AgentEventHub()
        let session = ClaudeTranscriptSession(record: makeRecord(transcriptPath: transcriptURL.path),
                                              fileManager: .default,
                                              hub: hub)
        session.start()
        defer { session.stop() }
        XCTAssertTrue(waitUntil {
            hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 20)
                .events.contains { $0.text == "bootstrap-invalid-ready" }
        }, "the marker proves bootstrap delivery reached records after the invalid line")
        XCTAssertFalse(hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 20)
            .events.contains { $0.eventID == "bootstrap-invalid-ask:ask-user-question:\(promptID)" })
        XCTAssertNil(hub.activeInteractivePrompt(workspaceID: "workspace",
                                                  sessionID: "session",
                                                  promptID: promptID))
    }

    func testClaudeRepeatedUnsupportedVersionRecordsNeverReachSupportedParser() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeTranscriptSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcriptURL = directory.appendingPathComponent("session.jsonl", isDirectory: false)
        let lines = [
            makeClaudeUserLine(uuid: "unsupported-first", content: "must-not-publish-first", version: "3.0.0"),
            makeClaudeUserLine(uuid: "unsupported-second", content: "must-not-publish-second", version: "3.0.0"),
        ]
        try (lines.joined(separator: "\n") + "\n")
            .write(to: transcriptURL, atomically: true, encoding: .utf8)

        let hub = AgentEventHub()
        let session = ClaudeTranscriptSession(record: makeRecord(transcriptPath: transcriptURL.path),
                                              fileManager: .default,
                                              hub: hub)
        session.start()
        defer { session.stop() }
        XCTAssertTrue(waitUntil {
            hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 20)
                .events.contains { $0.metadata?["reason"] == "unsupported_version" }
        })

        let events = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 20).events
        XCTAssertEqual(events.filter { $0.metadata?["reason"] == "unsupported_version" }.count, 1)
        XCTAssertFalse(events.contains { ($0.text ?? "").hasPrefix("must-not-publish") },
                       "warning deduplication must not parse later unsupported records")
    }

    func testClaudeMalformedHistoryHidesBufferedPromptFromLatestAndSubmission() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeTranscriptSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcriptURL = directory.appendingPathComponent("session.jsonl", isDirectory: false)
        let promptID = "toolu_buffered_fail_closed"
        let fillerLines = (0..<(transcriptBootstrapLineLimit - 1)).map {
            makeClaudeUserLine(uuid: "filler-\($0)", content: "filler-\($0)")
        }
        let askLine = makeClaudeAskUserQuestionAssistantLine(uuid: "buffered-ask",
                                                             toolCallID: promptID)
        let payload = (fillerLines + [askLine]).joined(separator: "\n") + "\n"
        try payload.write(to: transcriptURL, atomically: true, encoding: .utf8)

        let hub = AgentEventHub()
        let session = ClaudeTranscriptSession(record: makeRecord(transcriptPath: transcriptURL.path),
                                              fileManager: .default,
                                              hub: hub)
        session.start()
        defer { session.stop() }
        XCTAssertTrue(waitUntil {
            hub.activeInteractivePrompt(workspaceID: "workspace",
                                        sessionID: "session",
                                        promptID: promptID) != nil
        })
        let askOffset = (fillerLines.joined(separator: "\n") + "\n").utf8.count
        let askSeq = transcriptEventSequence(lineOffset: askOffset, ordinal: 1)

        let handle = try FileHandle(forWritingTo: transcriptURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{not-json}\n".utf8))
        try handle.close()

        XCTAssertFalse(session.backfill(beforeSeq: askSeq, limit: 2))
        XCTAssertFalse(hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 20)
            .events.contains { $0.eventID == "buffered-ask:ask-user-question:\(promptID)" },
                       "latest fetch must not replay an opener with unknown closure coverage")
        XCTAssertNil(hub.activeInteractivePrompt(workspaceID: "workspace",
                                                  sessionID: "session",
                                                  promptID: promptID),
                     "unknown closure coverage must disable submission of a buffered opener")
    }

    func testClaudeBackfillReplacesFullHistoricalWindowAtRequestedAnchor() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeTranscriptSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcriptURL = directory.appendingPathComponent("session.jsonl", isDirectory: false)
        let lines = (0..<10).map {
            makeClaudeUserLine(uuid: "line-\($0)", content: "line-\($0)")
        }
        try (lines.joined(separator: "\n") + "\n")
            .write(to: transcriptURL, atomically: true, encoding: .utf8)

        let hub = AgentEventHub(maxBufferedEvents: 2)
        let session = ClaudeTranscriptSession(record: makeRecord(transcriptPath: transcriptURL.path),
                                              fileManager: .default,
                                              hub: hub)
        session.start()
        defer { session.stop() }
        XCTAssertTrue(waitUntil {
            hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 2)
                .events.map(\.text) == ["line-8", "line-9"]
        })

        let line8Anchor = try XCTUnwrap(
            hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 2)
                .events.first { $0.text == "line-8" }?.seq
        )
        let shallow = BridgeAgentEventFetchFlow.run(eventHub: hub,
                                                    workspaceID: "workspace",
                                                    sessionID: "session",
                                                    limit: 2,
                                                    beforeSeq: line8Anchor,
                                                    afterSeq: nil) { _, anchor, limit in
            session.backfill(beforeSeq: anchor, limit: limit)
        }
        XCTAssertEqual(shallow.fetchResult.events.map(\.text), ["line-6", "line-7"])

        let line4Offset = (lines.prefix(4).joined(separator: "\n") + "\n").utf8.count
        let line4Anchor = transcriptEventSequence(lineOffset: line4Offset, ordinal: 0)
        let deep = BridgeAgentEventFetchFlow.run(eventHub: hub,
                                                 workspaceID: "workspace",
                                                 sessionID: "session",
                                                 limit: 2,
                                                 beforeSeq: line4Anchor,
                                                 afterSeq: nil) { _, anchor, limit in
            session.backfill(beforeSeq: anchor, limit: limit)
        }
        XCTAssertEqual(deep.fetchResult.events.map(\.text), ["line-2", "line-3"],
                       "a deeper exact-anchor request must displace the newer cached page")
    }

    func testClaudeBackfillSkipsRawPagesWithoutVisibleEvents() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeTranscriptSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcriptURL = directory.appendingPathComponent("session.jsonl", isDirectory: false)
        let oldVisible = makeClaudeUserLine(uuid: "old-visible", content: "old-visible")
        let ignoredLines = (0...transcriptBootstrapLineLimit).map {
            #"{"type":"system","subtype":"api_retry","uuid":"ignored-\#($0)"}"#
        }
        let liveAnchor = makeClaudeUserLine(uuid: "live-anchor", content: "live-anchor")
        try (([oldVisible] + ignoredLines + [liveAnchor]).joined(separator: "\n") + "\n")
            .write(to: transcriptURL, atomically: true, encoding: .utf8)

        let hub = AgentEventHub()
        let session = ClaudeTranscriptSession(record: makeRecord(transcriptPath: transcriptURL.path),
                                              fileManager: .default,
                                              hub: hub)
        session.start()
        defer { session.stop() }
        XCTAssertTrue(waitUntil {
            hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 10)
                .events.contains { $0.text == "live-anchor" }
        })
        let anchor = try XCTUnwrap(
            hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 10)
                .events.first { $0.text == "live-anchor" }?.seq
        )

        let output = BridgeAgentEventFetchFlow.run(eventHub: hub,
                                                   workspaceID: "workspace",
                                                   sessionID: "session",
                                                   limit: 10,
                                                   beforeSeq: anchor,
                                                   afterSeq: nil) { _, beforeSeq, limit in
            session.backfill(beforeSeq: beforeSeq, limit: limit)
        }

        XCTAssertTrue(output.didBackfill)
        XCTAssertEqual(output.fetchResult.events.compactMap(\.text), ["old-visible"],
                       "raw progress must continue past an eventless page")
    }

    func testClaudeLiveTerminalsPublishWhenHistoryIndexWinsAppendRace() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeTranscriptSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcriptURL = directory.appendingPathComponent("session.jsonl", isDirectory: false)
        let promptID = "toolu_index_first"
        let askLine = makeClaudeAskUserQuestionAssistantLine(uuid: "index-first-ask",
                                                             toolCallID: promptID)
        let contextLine = makeClaudeUserLine(uuid: "index-first-context",
                                             content: "<command-name>/context</command-name>")
        let fillerLines = (0..<transcriptBootstrapLineLimit).map {
            makeClaudeUserLine(uuid: "filler-\($0)", content: "filler-\($0)")
        }
        try (([askLine, contextLine] + fillerLines).joined(separator: "\n") + "\n")
            .write(to: transcriptURL, atomically: true, encoding: .utf8)

        let hub = AgentEventHub()
        let session = ClaudeTranscriptSession(record: makeRecord(transcriptPath: transcriptURL.path),
                                              fileManager: .default,
                                              hub: hub)
        session.start()
        defer { session.stop() }
        XCTAssertTrue(waitUntil {
            hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 1)
                .events.first?.text == "filler-\(transcriptBootstrapLineLimit - 1)"
        })
        let firstFillerOffset = ([askLine, contextLine].joined(separator: "\n") + "\n").utf8.count
        let anchor = transcriptEventSequence(lineOffset: firstFillerOffset, ordinal: 0)
        XCTAssertTrue(session.backfill(beforeSeq: anchor, limit: 20))

        let resultLine = makeClaudeToolResultLine(uuid: "index-first-result",
                                                  toolCallID: promptID,
                                                  content: "answered")
        let stdoutLine = makeClaudeContextStdoutLine(uuid: "index-first-summary")
        var appendError: Error?
        var didAppend = false
        session.historicalIndexBeforeScanForTesting = {
            guard didAppend == false else { return }
            didAppend = true
            do {
                let handle = try FileHandle(forWritingTo: transcriptURL)
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(([resultLine, stdoutLine].joined(separator: "\n") + "\n").utf8))
                try handle.close()
            } catch {
                appendError = error
            }
        }

        XCTAssertTrue(session.backfill(beforeSeq: anchor, limit: 20))
        XCTAssertNil(appendError)
        XCTAssertTrue(didAppend)
        XCTAssertTrue(waitUntil {
            let events = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 5000).events
            return events.contains { $0.eventID == "index-first-result:ask-user-question-resolved:\(promptID)" }
                && events.contains { $0.eventID == "index-first-summary:claude-context:0" }
        }, "live publication must reconcile against exact closures already consumed by the index")
    }

    func testClaudeIndexFirstRepeatedAskTerminalKeepsNewerLifecycleOpen() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeTranscriptSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcriptURL = directory.appendingPathComponent("session.jsonl", isDirectory: false)
        let promptID = "toolu_index_first_repeated"
        let firstAsk = makeClaudeAskUserQuestionAssistantLine(uuid: "index-first-a",
                                                              toolCallID: promptID)
        let secondAsk = makeClaudeAskUserQuestionAssistantLine(uuid: "index-first-b",
                                                               toolCallID: promptID)
        let fillerLines = (0..<(transcriptBootstrapLineLimit - 1)).map {
            makeClaudeUserLine(uuid: "filler-\($0)", content: "filler-\($0)")
        }
        try (([firstAsk, secondAsk] + fillerLines).joined(separator: "\n") + "\n")
            .write(to: transcriptURL, atomically: true, encoding: .utf8)

        let hub = AgentEventHub()
        let session = ClaudeTranscriptSession(record: makeRecord(transcriptPath: transcriptURL.path),
                                              fileManager: .default,
                                              hub: hub)
        session.start()
        defer { session.stop() }
        XCTAssertTrue(waitUntil {
            hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 1)
                .events.first?.text == "filler-\(transcriptBootstrapLineLimit - 2)"
        })
        let firstFillerOffset = ([firstAsk, secondAsk].joined(separator: "\n") + "\n").utf8.count
        let anchor = transcriptEventSequence(lineOffset: firstFillerOffset, ordinal: 0)
        XCTAssertTrue(session.backfill(beforeSeq: anchor, limit: 20))

        let terminal = makeClaudeToolResultLine(uuid: "index-first-result-a",
                                                toolCallID: promptID,
                                                content: "answered A")
        var appendError: Error?
        var didAppend = false
        session.historicalIndexBeforeScanForTesting = {
            guard didAppend == false else { return }
            didAppend = true
            do {
                let handle = try FileHandle(forWritingTo: transcriptURL)
                try handle.seekToEnd()
                try handle.write(contentsOf: Data((terminal + "\n").utf8))
                try handle.close()
            } catch {
                appendError = error
            }
        }

        XCTAssertTrue(session.backfill(beforeSeq: anchor, limit: 20))
        XCTAssertNil(appendError)
        let terminalEventID = "index-first-result-a:ask-user-question-resolved:\(promptID)"
        XCTAssertTrue(waitUntil {
            hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 5000)
                .events.contains { $0.eventID == terminalEventID }
        })
        let terminalEvent = try XCTUnwrap(
            hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 5000)
                .events.first { $0.eventID == terminalEventID }
        )
        XCTAssertEqual(terminalEvent.metadata?["lifecycle_token"],
                       "index-first-a:ask-user-question:\(promptID)")
        XCTAssertNotNil(hub.activeInteractivePrompt(workspaceID: "workspace",
                                                     sessionID: "session",
                                                     promptID: promptID),
                        "terminal A must not close the newer same-ID Ask B")
    }

    func testClaudeLiveFirstRepeatedAskTerminalKeepsNewerLifecycleOpen() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeTranscriptSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcriptURL = directory.appendingPathComponent("session.jsonl", isDirectory: false)
        let promptID = "toolu_live_first_repeated"
        let firstAsk = makeClaudeAskUserQuestionAssistantLine(uuid: "live-first-a",
                                                              toolCallID: promptID)
        let secondAsk = makeClaudeAskUserQuestionAssistantLine(uuid: "live-first-b",
                                                               toolCallID: promptID)
        let fillerLines = (0..<(transcriptBootstrapLineLimit - 1)).map {
            makeClaudeUserLine(uuid: "filler-\($0)", content: "filler-\($0)")
        }
        try (([firstAsk, secondAsk] + fillerLines).joined(separator: "\n") + "\n")
            .write(to: transcriptURL, atomically: true, encoding: .utf8)

        let hub = AgentEventHub()
        let session = ClaudeTranscriptSession(record: makeRecord(transcriptPath: transcriptURL.path),
                                              fileManager: .default,
                                              hub: hub)
        session.start()
        defer { session.stop() }
        XCTAssertTrue(waitUntil {
            hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 1)
                .events.first?.text == "filler-\(transcriptBootstrapLineLimit - 2)"
        })
        let firstFillerOffset = ([firstAsk, secondAsk].joined(separator: "\n") + "\n").utf8.count
        let anchor = transcriptEventSequence(lineOffset: firstFillerOffset, ordinal: 0)
        XCTAssertTrue(session.backfill(beforeSeq: anchor, limit: 20))

        let terminal = makeClaudeToolResultLine(uuid: "live-first-result-a",
                                                toolCallID: promptID,
                                                content: "answered A")
        let handle = try FileHandle(forWritingTo: transcriptURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((terminal + "\n").utf8))
        try handle.close()

        let terminalEventID = "live-first-result-a:ask-user-question-resolved:\(promptID)"
        XCTAssertTrue(waitUntil {
            hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 5000)
                .events.contains { $0.eventID == terminalEventID }
        })
        let terminalEvent = try XCTUnwrap(
            hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 5000)
                .events.first { $0.eventID == terminalEventID }
        )
        XCTAssertEqual(terminalEvent.metadata?["lifecycle_token"],
                       "live-first-a:ask-user-question:\(promptID)")
        XCTAssertNotNil(hub.activeInteractivePrompt(workspaceID: "workspace",
                                                     sessionID: "session",
                                                     promptID: promptID),
                        "terminal A must not close the newer same-ID Ask B")
    }

    func testClaudeIndexFirstContextSummaryDoesNotCloseLaterCommand() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeTranscriptSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcriptURL = directory.appendingPathComponent("session.jsonl", isDirectory: false)
        let contextA = makeClaudeUserLine(uuid: "context-a",
                                          content: "<command-name>/context</command-name>")
        let fillerLines = (0..<transcriptBootstrapLineLimit).map {
            makeClaudeUserLine(uuid: "filler-\($0)", content: "filler-\($0)")
        }
        try (([contextA] + fillerLines).joined(separator: "\n") + "\n")
            .write(to: transcriptURL, atomically: true, encoding: .utf8)

        let hub = AgentEventHub()
        let session = ClaudeTranscriptSession(record: makeRecord(transcriptPath: transcriptURL.path),
                                              fileManager: .default,
                                              hub: hub)
        session.start()
        defer { session.stop() }
        XCTAssertTrue(waitUntil {
            hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 1)
                .events.first?.text == "filler-\(transcriptBootstrapLineLimit - 1)"
        })
        let firstFillerOffset = (contextA + "\n").utf8.count
        let initialAnchor = transcriptEventSequence(lineOffset: firstFillerOffset, ordinal: 0)
        XCTAssertTrue(session.backfill(beforeSeq: initialAnchor, limit: 20))

        let summaryA = makeClaudeContextStdoutLine(uuid: "summary-a")
        let contextB = makeClaudeUserLine(uuid: "context-b",
                                          content: "<command-name>/context</command-name>")
        var appendError: Error?
        var didAppend = false
        session.historicalIndexBeforeScanForTesting = {
            guard didAppend == false else { return }
            didAppend = true
            do {
                let handle = try FileHandle(forWritingTo: transcriptURL)
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(([summaryA, contextB].joined(separator: "\n") + "\n").utf8))
                try handle.close()
            } catch {
                appendError = error
            }
        }

        XCTAssertTrue(session.backfill(beforeSeq: initialAnchor, limit: 20))
        XCTAssertNil(appendError)
        XCTAssertTrue(waitUntil {
            let events = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 5000).events
            return events.contains { $0.eventID == "summary-a:claude-context:0" }
                && events.contains { $0.eventID == "context-b:claude-context-command:0" }
        })

        let contextC = makeClaudeUserLine(uuid: "context-c",
                                          content: "<command-name>/context</command-name>")
        let marker = makeClaudeUserLine(uuid: "context-marker", content: "history marker")
        let handle = try FileHandle(forWritingTo: transcriptURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(([contextC, marker].joined(separator: "\n") + "\n").utf8))
        try handle.close()
        XCTAssertTrue(waitUntil {
            hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 5000)
                .events.contains { $0.eventID == "context-marker:user-text:0" }
        })
        let markerSeq = try XCTUnwrap(
            hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 5000)
                .events.first { $0.eventID == "context-marker:user-text:0" }?.seq
        )

        let page = BridgeAgentEventFetchFlow.run(eventHub: hub,
                                                 workspaceID: "workspace",
                                                 sessionID: "session",
                                                 limit: 500,
                                                 beforeSeq: markerSeq,
                                                 afterSeq: nil) { _, beforeSeq, limit in
            session.backfill(beforeSeq: beforeSeq, limit: limit)
        }
        XCTAssertTrue(page.didBackfill)
        XCTAssertFalse(page.fetchResult.events.contains {
            $0.eventID == "context-b:claude-context-command:0"
        }, "the later context C must silently consume still-open context B")
        XCTAssertTrue(page.fetchResult.events.contains {
            $0.eventID == "context-c:claude-context-command:0"
        }, "context C itself must remain the open command")
    }

    func testClaudeHistoricalIndexRejectsSameInodeMutationWhileAdoptingPartial() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeTranscriptSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcriptURL = directory.appendingPathComponent("session.jsonl", isDirectory: false)
        let initialLines = (0..<8).map {
            makeClaudeUserLine(uuid: "old-\($0)", content: "old-\($0)")
        }
        let initialPayload = initialLines.joined(separator: "\n") + "\n"
        try initialPayload.write(to: transcriptURL, atomically: true, encoding: .utf8)

        let hub = AgentEventHub()
        let session = ClaudeTranscriptSession(record: makeRecord(transcriptPath: transcriptURL.path),
                                              fileManager: .default,
                                              hub: hub)
        session.start()
        defer { session.stop() }
        XCTAssertTrue(waitUntil {
            hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 20)
                .events.contains { $0.text == "old-7" }
        })
        let initialAnchor = try XCTUnwrap(
            hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 20)
                .events.first { $0.text == "old-7" }?.seq
        )
        XCTAssertTrue(session.backfill(beforeSeq: initialAnchor, limit: 2))

        let partialLine = makeClaudeToolResultLine(uuid: "partial-result",
                                                   toolCallID: "toolu_mutated_partial",
                                                   content: "舊回答")
        let partialLineData = Data(partialLine.utf8)
        let partialPrefix = Data(partialLineData.prefix(partialLineData.count / 2))
        var seamError: Error?
        var appendedPartial = false
        var mutatedPartial = false
        session.historicalIndexBeforeScanForTesting = {
            guard appendedPartial == false else { return }
            appendedPartial = true
            do {
                let handle = try FileHandle(forWritingTo: transcriptURL)
                try handle.seekToEnd()
                try handle.write(contentsOf: partialPrefix)
                try handle.close()
            } catch {
                seamError = error
            }
        }
        session.historicalIndexBeforeSourceValidationForTesting = {
            guard mutatedPartial == false else { return }
            mutatedPartial = true
            do {
                let handle = try FileHandle(forWritingTo: transcriptURL)
                try handle.truncate(atOffset: UInt64(initialPayload.utf8.count))
                try handle.seek(toOffset: UInt64(initialPayload.utf8.count))
                try handle.write(contentsOf: Data(repeating: 0x78, count: partialPrefix.count))
                try handle.close()
            } catch {
                seamError = error
            }
        }

        let output = BridgeAgentEventFetchFlow.run(eventHub: hub,
                                                   workspaceID: "workspace",
                                                   sessionID: "session",
                                                   limit: 4,
                                                   beforeSeq: initialAnchor,
                                                   afterSeq: nil) { _, anchor, limit in
            session.backfill(beforeSeq: anchor, limit: limit)
        }

        XCTAssertNil(seamError)
        XCTAssertTrue(appendedPartial)
        XCTAssertTrue(mutatedPartial)
        XCTAssertFalse(output.didBackfill)
        XCTAssertTrue(output.fetchResult.events.isEmpty,
                      "same-inode mutation must revoke the old fetch transaction synchronously")
    }

    func testClaudeLocalCommandEnvelopeUserMessagesAreNotPublished() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeTranscriptSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let transcriptURL = directory.appendingPathComponent("session.jsonl", isDirectory: false)
        let envelopeLines = [
            makeClaudeUserLine(uuid: "u1", content: "<local-command-caveat>Caveat: The messages below were generated by the user while running local commands. DO NOT respond to these messages or otherwise consider them in your response unless the user explicitly asks you to.</local-command-caveat>"),
            makeClaudeUserLine(uuid: "u2", content: "<command-name>/exit</command-name> <command-message>exit</command-message> <command-args></command-args>"),
            makeClaudeUserLine(uuid: "u3", content: "<local-command-stdout>Goodbye!</local-command-stdout>"),
        ].joined(separator: "\n") + "\n"
        try envelopeLines.write(to: transcriptURL, atomically: true, encoding: .utf8)

        let hub = AgentEventHub()
        let session = ClaudeTranscriptSession(record: makeRecord(transcriptPath: transcriptURL.path),
                                              fileManager: .default,
                                              hub: hub)
        session.start()
        defer { session.stop() }

        XCTAssertTrue(waitUntil {
            let result = hub.fetch(workspaceID: "workspace",
                                   sessionID: "session",
                                   limit: 10,
                                   beforeSeq: nil,
                                   afterSeq: nil)
            return result.events.contains { $0.type == .sessionStarted }
        })

        let result = hub.fetch(workspaceID: "workspace",
                               sessionID: "session",
                               limit: 10,
                               beforeSeq: nil,
                               afterSeq: nil)
        XCTAssertEqual(result.events.map(\.type), [.sessionStarted])
        XCTAssertFalse(result.events.contains { ($0.text ?? "").contains("local-command") })
        XCTAssertFalse(result.events.contains { ($0.text ?? "").contains("/exit") })
    }

    func testClaudeRegularSlashLikeUserTextStillPublishes() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeTranscriptSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let transcriptURL = directory.appendingPathComponent("session.jsonl", isDirectory: false)
        try makeClaudeUserLine(uuid: "u1", content: "Please explain when to use /exit in docs.")
            .appending("\n")
            .write(to: transcriptURL, atomically: true, encoding: .utf8)

        let hub = AgentEventHub()
        let session = ClaudeTranscriptSession(record: makeRecord(transcriptPath: transcriptURL.path),
                                              fileManager: .default,
                                              hub: hub)
        session.start()
        defer { session.stop() }

        XCTAssertTrue(waitUntil {
            let result = hub.fetch(workspaceID: "workspace",
                                   sessionID: "session",
                                   limit: 10,
                                   beforeSeq: nil,
                                   afterSeq: nil)
            return result.events.contains { $0.type == .userMessage }
        })

        let result = hub.fetch(workspaceID: "workspace",
                               sessionID: "session",
                               limit: 10,
                               beforeSeq: nil,
                               afterSeq: nil)
        XCTAssertEqual(result.events.compactMap(\.text), ["Please explain when to use /exit in docs."])
    }

    func testClaudeQueuedCommandAttachmentAppendPublishesUserMessage() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeTranscriptSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let transcriptURL = directory.appendingPathComponent("session.jsonl", isDirectory: false)
        try Data().write(to: transcriptURL)

        let hub = AgentEventHub()
        let session = ClaudeTranscriptSession(record: makeRecord(transcriptPath: transcriptURL.path),
                                              fileManager: .default,
                                              hub: hub)
        session.start()
        defer { session.stop() }

        XCTAssertTrue(waitUntil {
            let result = hub.fetch(workspaceID: "workspace",
                                   sessionID: "session",
                                   limit: 10,
                                   beforeSeq: nil,
                                   afterSeq: nil)
            return result.events.contains { $0.type == .sessionStarted }
        })

        let handle = try FileHandle(forWritingTo: transcriptURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(makeClaudeQueuedCommandAttachment(uuid: "q1",
                                                                            prompt: "local queued message")
            .appending("\n")
            .utf8))
        try handle.close()

        XCTAssertTrue(waitUntil {
            let result = hub.fetch(workspaceID: "workspace",
                                   sessionID: "session",
                                   limit: 10,
                                   beforeSeq: nil,
                                   afterSeq: nil)
            return result.events.contains {
                $0.type == .userMessage && $0.text == "local queued message"
            }
        })

        let result = hub.fetch(workspaceID: "workspace",
                               sessionID: "session",
                               limit: 10,
                               beforeSeq: nil,
                               afterSeq: nil)
        let userEvent = try XCTUnwrap(result.events.first { $0.type == .userMessage })
        XCTAssertEqual(userEvent.text, "local queued message")
        XCTAssertEqual(userEvent.metadata?["queued_command"], "true")
    }

    func testClaudeContextCommandPublishesCleanGeneratedSummary() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeTranscriptSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let transcriptURL = directory.appendingPathComponent("session.jsonl", isDirectory: false)
        let lines = [
            makeClaudeUserLine(uuid: "u1", content: "<command-name>/context</command-name>\n<command-message>context</command-message>\n<command-args></command-args>"),
            makeClaudeUserLine(uuid: "u2", content: "<local-command-stdout> \u{001B}[1mContext Usage\u{001B}[22m\n◉ ◉ ◉ Opus 4.7 (1M context)\n◉ ◉ ◉ 399.1k/1m tokens (40%)\n▢ ▢ ▢ Estimated usage by category\n◉ System prompt: 8.3k tokens (0.8%)\n◉ System tools: 5.5k tokens (0.5%)\n◉ Memory files: 3.5k tokens (0.3%)\n◉ Skills: 7.2k tokens (0.7%)\n◉ Messages: 376.8k tokens (37.7%)\n▢ Free space: 598.8k (59.9%)\nMCP tools: /mcp (loaded on-demand)\nAvailable\n├ benchmark: 103 tokens</local-command-stdout>"),
        ].joined(separator: "\n") + "\n"
        try lines.write(to: transcriptURL, atomically: true, encoding: .utf8)

        let hub = AgentEventHub()
        let session = ClaudeTranscriptSession(record: makeRecord(transcriptPath: transcriptURL.path),
                                              fileManager: .default,
                                              hub: hub)
        session.start()
        defer { session.stop() }

        XCTAssertTrue(waitUntil {
            let result = hub.fetch(workspaceID: "workspace",
                                   sessionID: "session",
                                   limit: 10,
                                   beforeSeq: nil,
                                   afterSeq: nil)
            return result.events.contains { $0.metadata?["tidey_generated"] == "claude_context" }
        })

        let result = hub.fetch(workspaceID: "workspace",
                               sessionID: "session",
                               limit: 10,
                               beforeSeq: nil,
                               afterSeq: nil)
        let contextEvent = try XCTUnwrap(result.events.first { $0.metadata?["tidey_generated"] == "claude_context" })
        let commandEvent = try XCTUnwrap(result.events.first { $0.metadata?["tidey_generated"] == "claude_context_command" })
        XCTAssertEqual(commandEvent.type, .userMessage)
        XCTAssertEqual(commandEvent.role, "user")
        XCTAssertEqual(commandEvent.text, "/context")
        XCTAssertEqual(commandEvent.metadata?["slash_command"], "/context")
        XCTAssertLessThan(commandEvent.seq, contextEvent.seq)
        XCTAssertEqual(contextEvent.type, .assistantMessage)
        XCTAssertEqual(contextEvent.role, "assistant")
        XCTAssertEqual(contextEvent.metadata?["slash_command"], "/context")
        XCTAssertTrue((contextEvent.text ?? "").contains("### Claude Context"))
        XCTAssertTrue((contextEvent.text ?? "").contains("Opus 4.7 - 1M context"))
        XCTAssertTrue((contextEvent.text ?? "").contains("`■■■■■■■■□□□□□□□□□□□□` 40%"))
        XCTAssertTrue((contextEvent.text ?? "").contains("399.1k / 1m used - 598.8k free"))
        XCTAssertTrue((contextEvent.text ?? "").contains("Messages:\n`■■■■■■■■□□□□□□□□□□□□`\n37.7% - 376.8k"))
        XCTAssertTrue((contextEvent.text ?? "").contains("System prompt:\n`□□□□□□□□□□□□□□□□□□□□`\n0.8% - 8.3k"))
        XCTAssertFalse((contextEvent.text ?? "").contains("- Messages:"))
        XCTAssertFalse((contextEvent.text ?? "").contains("local-command-stdout"))
        XCTAssertFalse((contextEvent.text ?? "").contains("Available"))
        XCTAssertFalse((contextEvent.text ?? "").contains("benchmark"))
        XCTAssertFalse((contextEvent.text ?? "").contains("MCP tools"))
        XCTAssertFalse((contextEvent.text ?? "").contains("\u{001B}"))
        XCTAssertFalse(result.events.contains { ($0.text ?? "").contains("<command-name>") })
    }

    func testClaudeLocalCommandStdoutWithoutContextCommandIsNotPublished() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeTranscriptSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let transcriptURL = directory.appendingPathComponent("session.jsonl", isDirectory: false)
        let lines = [
            makeClaudeUserLine(uuid: "u1", content: "<command-name>/exit</command-name><command-message>exit</command-message><command-args></command-args>"),
            makeClaudeUserLine(uuid: "u2", content: "<local-command-stdout>Goodbye!</local-command-stdout>"),
        ].joined(separator: "\n") + "\n"
        try lines.write(to: transcriptURL, atomically: true, encoding: .utf8)

        let hub = AgentEventHub()
        let session = ClaudeTranscriptSession(record: makeRecord(transcriptPath: transcriptURL.path),
                                              fileManager: .default,
                                              hub: hub)
        session.start()
        defer { session.stop() }

        XCTAssertTrue(waitUntil {
            let result = hub.fetch(workspaceID: "workspace",
                                   sessionID: "session",
                                   limit: 10,
                                   beforeSeq: nil,
                                   afterSeq: nil)
            return result.events.contains { $0.type == .sessionStarted }
        })

        let result = hub.fetch(workspaceID: "workspace",
                               sessionID: "session",
                               limit: 10,
                               beforeSeq: nil,
                               afterSeq: nil)
        XCTAssertEqual(result.events.map(\.type), [.sessionStarted])
    }

    func testClaudeUserEchoConsumesClientRequestIDMetadata() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeTranscriptSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let transcriptURL = directory.appendingPathComponent("session.jsonl", isDirectory: false)
        try makeClaudeUserLine(uuid: "u1", content: "hello from remote")
            .appending("\n")
            .write(to: transcriptURL, atomically: true, encoding: .utf8)

        let registry = ChatSubmitEchoRegistry()
        registry.register(workspaceID: "workspace",
                          panelID: "panel",
                          sessionID: "session",
                          vendor: "claude",
                          text: "hello from remote",
                          clientRequestID: "local-1")

        let hub = AgentEventHub()
        let session = ClaudeTranscriptSession(record: makeRecord(transcriptPath: transcriptURL.path),
                                              fileManager: .default,
                                              hub: hub,
                                              chatSubmitEchoRegistry: registry)
        session.start()
        defer { session.stop() }

        XCTAssertTrue(waitUntil {
            let result = hub.fetch(workspaceID: "workspace",
                                   sessionID: "session",
                                   limit: 10,
                                   beforeSeq: nil,
                                   afterSeq: nil)
            return result.events.contains { $0.metadata?["client_request_id"] == "local-1" }
        })

        let result = hub.fetch(workspaceID: "workspace",
                               sessionID: "session",
                               limit: 10,
                               beforeSeq: nil,
                               afterSeq: nil)
        let userEvent = try XCTUnwrap(result.events.first { $0.type == .userMessage })
        XCTAssertEqual(userEvent.metadata?["client_request_id"], "local-1")
        XCTAssertTrue(registry.snapshot().isEmpty)
    }

    func testClaudeAskUserQuestionPublishesInteractivePromptAndResolvedEvent() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeTranscriptSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let transcriptURL = directory.appendingPathComponent("session.jsonl", isDirectory: false)
        try Data().write(to: transcriptURL)

        let hub = AgentEventHub()
        let commandSender = StubClaudeCommandSender()
        let session = ClaudeTranscriptSession(record: makeRecord(transcriptPath: transcriptURL.path),
                                              fileManager: .default,
                                              hub: hub,
                                              socketClient: commandSender)
        session.start()
        defer { session.stop() }

        XCTAssertTrue(waitUntil {
            hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 10)
                .events.contains { $0.type == .sessionStarted }
        })

        let handle = try FileHandle(forWritingTo: transcriptURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(makeClaudeAskUserQuestionAssistantLine(uuid: "a1",
                                                                                 toolCallID: "toolu_question_1")
            .appending("\n")
            .utf8))

        XCTAssertTrue(waitUntil {
            hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 20)
                .events.contains { $0.type == .interactivePrompt }
        })

        let promptResult = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 20)
        let promptEvent = try XCTUnwrap(promptResult.events.first { $0.type == .interactivePrompt })
        XCTAssertEqual(promptEvent.vendor, "claude")
        XCTAssertEqual(promptEvent.metadata?["prompt_id"], "toolu_question_1")
        XCTAssertEqual(promptEvent.metadata?["source"], "claude_ask_user_question")
        XCTAssertEqual(promptEvent.metadata?["submit_channel"], "terminal_input")
        XCTAssertEqual(promptEvent.payload?.objectValue?["prompt_id"]?.stringValue, "toolu_question_1")
        XCTAssertEqual(promptEvent.payload?.objectValue?["title"]?.stringValue, "Choose a path")
        XCTAssertEqual(promptEvent.payload?.objectValue?["body"]?.stringValue, "Which path should Claude use?")
        let options = try XCTUnwrap(promptEvent.payload?.objectValue?["options"]?.arrayValue)
        XCTAssertEqual(options.count, 2)
        XCTAssertEqual(options[0].objectValue?["label"]?.stringValue, "Use current file")
        XCTAssertEqual(options[0].objectValue?["description"]?.stringValue, "Open the current file.")
        XCTAssertEqual(options[1].objectValue?["input_sequence"]?.stringValue, "\u{1b}[B\r")
        XCTAssertEqual(commandSender.commands.count, 2)
        XCTAssertTrue(commandSender.commands[0].contains(#""action":"notification.create""#))
        XCTAssertEqual(commandSender.commands[1], "report_shell_state needs_input --workspace_id=workspace")

        try handle.write(contentsOf: Data(makeClaudeToolResultLine(uuid: "u1",
                                                                   toolCallID: "toolu_question_1",
                                                                   content: "Use current file")
            .appending("\n")
            .utf8))
        try handle.close()

        XCTAssertTrue(waitUntil {
            hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 30)
                .events.contains { $0.type == .interactivePromptResolved }
        })

        let resolvedResult = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 30)
        let resolvedEvent = try XCTUnwrap(resolvedResult.events.first { $0.type == .interactivePromptResolved })
        XCTAssertEqual(resolvedEvent.metadata?["prompt_id"], "toolu_question_1")
        XCTAssertEqual(resolvedEvent.metadata?["reason"], "tool_result")
        XCTAssertNil(hub.activeInteractivePrompt(workspaceID: "workspace",
                                                 sessionID: "session",
                                                 promptID: "toolu_question_1"))
        XCTAssertEqual(commandSender.commands.last, "report_shell_state running --workspace_id=workspace")
    }

    func testClaudeAskUserQuestionMultiSelectIsLeftForFutureSupport() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeTranscriptSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let transcriptURL = directory.appendingPathComponent("session.jsonl", isDirectory: false)
        try makeClaudeAskUserQuestionAssistantLine(uuid: "a1",
                                                   toolCallID: "toolu_question_1",
                                                   multiSelect: true)
            .appending("\n")
            .write(to: transcriptURL, atomically: true, encoding: .utf8)

        let hub = AgentEventHub()
        let session = ClaudeTranscriptSession(record: makeRecord(transcriptPath: transcriptURL.path),
                                              fileManager: .default,
                                              hub: hub)
        session.start()
        defer { session.stop() }

        XCTAssertTrue(waitUntil {
            hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 10)
                .events.contains { $0.type == .toolCall }
        })

        let result = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 10)
        XCTAssertFalse(result.events.contains { $0.type == .interactivePrompt })
    }

    func testClaudeBackfillOlderLinesKeepOriginalCursorPositions() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeTranscriptSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcriptURL = directory.appendingPathComponent("session.jsonl", isDirectory: false)

        let totalLines = transcriptBootstrapLineLimit + 20
        let lines = (0..<totalLines).map {
            makeClaudeUserLine(uuid: "uuid-\($0)", content: "line-\($0)")
        }
        try (lines.joined(separator: "\n") + "\n").write(to: transcriptURL,
                                                            atomically: true,
                                                            encoding: .utf8)

        let hub = AgentEventHub()
        let session = ClaudeTranscriptSession(record: makeRecord(transcriptPath: transcriptURL.path),
                                              fileManager: .default,
                                              hub: hub)
        session.start()
        defer { session.stop() }

        XCTAssertTrue(waitUntil {
            hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 1)
                .events.first?.text == "line-\(totalLines - 1)"
        })
        let initial = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 5000)
        XCTAssertFalse(initial.events.contains { $0.text == "line-0" })
        let oldestLoadedSeq = initial.events
            .filter { ($0.text ?? "").hasPrefix("line-") }
            .map(\.seq)
            .min() ?? 0
        let newestSeq = initial.events.map(\.seq).max() ?? 0

        XCTAssertTrue(session.backfill(beforeSeq: oldestLoadedSeq, limit: 50))
        let older = hub.fetch(workspaceID: "workspace",
                              sessionID: "session",
                              limit: 5000,
                              beforeSeq: oldestLoadedSeq)
        XCTAssertFalse(older.events.isEmpty)
        XCTAssertTrue(older.events.allSatisfy { $0.seq < oldestLoadedSeq })
        XCTAssertTrue(older.events.contains { ($0.text ?? "").hasPrefix("line-") })

        let catchUp = hub.fetch(workspaceID: "workspace",
                                sessionID: "session",
                                limit: 5000,
                                afterSeq: newestSeq)
        XCTAssertTrue(catchUp.events.isEmpty,
                      "backfilled history must not appear as new live events")
    }

    func testClaudeBackfillPreservesLiveEchoAndKeepsLocalCommandParserStateIsolated() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeTranscriptSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcriptURL = directory.appendingPathComponent("session.jsonl", isDirectory: false)

        var lines = [
            makeClaudeUserLine(uuid: "old-echo", content: "repeat me"),
            makeClaudeAskUserQuestionAssistantLine(uuid: "old-question", toolCallID: "toolu_old"),
            makeClaudeUserLine(uuid: "old-context", content: "<command-name>/context</command-name>"),
        ]
        lines.append(contentsOf: (0..<transcriptBootstrapLineLimit).map {
            makeClaudeUserLine(uuid: "uuid-\($0)", content: "line-\($0)")
        })
        try (lines.joined(separator: "\n") + "\n").write(to: transcriptURL,
                                                            atomically: true,
                                                            encoding: .utf8)

        let hub = AgentEventHub()
        let registry = ChatSubmitEchoRegistry()
        registry.register(workspaceID: "workspace",
                          panelID: "panel",
                          sessionID: "session",
                          vendor: "claude",
                          text: "repeat me",
                          clientRequestID: "client-live")
        let session = ClaudeTranscriptSession(record: makeRecord(transcriptPath: transcriptURL.path),
                                              fileManager: .default,
                                              hub: hub,
                                              chatSubmitEchoRegistry: registry)
        session.start()
        defer { session.stop() }

        XCTAssertTrue(waitUntil {
            hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 1)
                .events.first?.text == "line-\(transcriptBootstrapLineLimit - 1)"
        })
        let oldestLoadedSeq = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 5000)
            .events
            .filter { ($0.text ?? "").hasPrefix("line-") }
            .map(\.seq)
            .min() ?? 0

        XCTAssertTrue(session.backfill(beforeSeq: oldestLoadedSeq, limit: 600))
        XCTAssertEqual(registry.snapshot().map(\.clientRequestID), ["client-live"])

        let handle = try FileHandle(forWritingTo: transcriptURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((makeClaudeToolResultLine(uuid: "live-result",
                                                                    toolCallID: "toolu_old",
                                                                    content: "answered") + "\n").utf8))
        try handle.write(contentsOf: Data((makeClaudeUserLine(uuid: "live-stdout",
                                                              content: "<local-command-stdout>whatever</local-command-stdout>") + "\n").utf8))
        try handle.write(contentsOf: Data((makeClaudeUserLine(uuid: "live-echo", content: "repeat me") + "\n").utf8))
        try handle.close()

        XCTAssertTrue(waitUntil {
            hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 5000).events.contains {
                $0.text == "repeat me" && $0.metadata?["client_request_id"] == "client-live"
            }
        })
        let allEvents = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 5000).events
        XCTAssertTrue(allEvents.contains {
            $0.type == .interactivePromptResolved && $0.metadata?["prompt_id"] == "toolu_old"
        }, "the separate history index may resolve an exposed Ask without leaking replay parser state")
        XCTAssertFalse(allEvents.contains { $0.metadata?["tidey_generated"] == "claude_context" })
    }

    func testClaudeBackfillPreservesExistingLiveParserCorrelation() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeTranscriptSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcriptURL = directory.appendingPathComponent("session.jsonl", isDirectory: false)

        var lines = [
            makeClaudeToolResultLine(uuid: "old-result", toolCallID: "toolu_live", content: "historical"),
            makeClaudeContextStdoutLine(uuid: "old-stdout"),
        ]
        lines.append(contentsOf: (0..<transcriptBootstrapLineLimit).map {
            makeClaudeUserLine(uuid: "uuid-\($0)", content: "line-\($0)")
        })
        try (lines.joined(separator: "\n") + "\n").write(to: transcriptURL,
                                                            atomically: true,
                                                            encoding: .utf8)

        let hub = AgentEventHub()
        let session = ClaudeTranscriptSession(record: makeRecord(transcriptPath: transcriptURL.path),
                                              fileManager: .default,
                                              hub: hub)
        session.start()
        defer { session.stop() }
        XCTAssertTrue(waitUntil {
            hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 1)
                .events.first?.text == "line-\(transcriptBootstrapLineLimit - 1)"
        })

        func append(_ line: String) throws {
            let handle = try FileHandle(forWritingTo: transcriptURL)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data((line + "\n").utf8))
            try handle.close()
        }

        try append(makeClaudeAskUserQuestionAssistantLine(uuid: "live-ask", toolCallID: "toolu_live"))
        try append(makeClaudeUserLine(uuid: "live-command", content: "<command-name>/context</command-name>"))
        XCTAssertTrue(waitUntil {
            hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 20)
                .events.contains { $0.type == .interactivePrompt }
        })
        let boundary = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 5000)
            .events
            .filter { ($0.text ?? "").hasPrefix("line-") }
            .map(\.seq)
            .min() ?? 0

        XCTAssertTrue(session.backfill(beforeSeq: boundary, limit: 600))
        try append(makeClaudeToolResultLine(uuid: "live-result",
                                            toolCallID: "toolu_live",
                                            content: "live"))
        try append(makeClaudeContextStdoutLine(uuid: "live-stdout"))

        XCTAssertTrue(waitUntil {
            let events = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 5000).events
            let resolvedLiveAsk = events.contains {
                $0.type == .interactivePromptResolved
                    && $0.metadata?["prompt_id"] == "toolu_live"
                    && $0.eventID.contains("live-result")
            }
            let summarizedLiveCommand = events.contains {
                $0.metadata?["tidey_generated"] == "claude_context"
                    && $0.eventID.contains("live-stdout")
            }
            return resolvedLiveAsk && summarizedLiveCommand
        })
    }

    func testClaudeBackfillDoesNotRunSidebarSideEffects() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeTranscriptSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcriptURL = directory.appendingPathComponent("session.jsonl", isDirectory: false)

        var lines = [makeClaudeAskUserQuestionAssistantLine(uuid: "old-question", toolCallID: "toolu_old")]
        lines.append(contentsOf: (0..<transcriptBootstrapLineLimit).map {
            makeClaudeUserLine(uuid: "uuid-\($0)", content: "line-\($0)")
        })
        try (lines.joined(separator: "\n") + "\n").write(to: transcriptURL,
                                                            atomically: true,
                                                            encoding: .utf8)

        let hub = AgentEventHub()
        let sender = StubClaudeCommandSender()
        let session = ClaudeTranscriptSession(record: makeRecord(transcriptPath: transcriptURL.path),
                                              fileManager: .default,
                                              hub: hub,
                                              socketClient: sender)
        session.start()
        defer { session.stop() }
        XCTAssertTrue(waitUntil {
            hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 1)
                .events.first?.text == "line-\(transcriptBootstrapLineLimit - 1)"
        })
        let commandsBeforeBackfill = sender.commands
        let oldestLoadedSeq = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 5000)
            .events
            .filter { ($0.text ?? "").hasPrefix("line-") }
            .map(\.seq)
            .min() ?? 0

        XCTAssertTrue(session.backfill(beforeSeq: oldestLoadedSeq, limit: 100))
        XCTAssertEqual(sender.commands, commandsBeforeBackfill)
    }

    func testClaudeBackfillFailsClosedForCrossPageAskAndContextClosures() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeTranscriptSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcriptURL = directory.appendingPathComponent("session.jsonl", isDirectory: false)

        let askLine = makeClaudeAskUserQuestionAssistantLine(uuid: "old-ask", toolCallID: "toolu_cross_page")
        let resultLine = makeClaudeToolResultLine(uuid: "old-result",
                                                  toolCallID: "toolu_cross_page",
                                                  content: "answered")
        let contextCommandLine = makeClaudeUserLine(uuid: "old-context-command",
                                                    content: "<command-name>/context</command-name>")
        let contextSummaryLine = makeClaudeContextStdoutLine(uuid: "old-context-summary")
        let historySpacerLines = (0..<(transcriptBootstrapLineLimit - 1)).map {
            makeClaudeUserLine(uuid: "history-spacer-\($0)", content: "history-spacer-\($0)")
        }
        var lines = [askLine, resultLine] + historySpacerLines + [contextCommandLine, contextSummaryLine]
        lines.append(contentsOf: (0..<transcriptBootstrapLineLimit).map {
            makeClaudeUserLine(uuid: "filler-\($0)", content: "filler-\($0)")
        })
        try (lines.joined(separator: "\n") + "\n").write(to: transcriptURL,
                                                            atomically: true,
                                                            encoding: .utf8)

        let hub = AgentEventHub()
        let session = ClaudeTranscriptSession(record: makeRecord(transcriptPath: transcriptURL.path),
                                              fileManager: .default,
                                              hub: hub)
        session.start()
        defer { session.stop() }
        XCTAssertTrue(waitUntil {
            hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 1)
                .events.first?.text == "filler-\(transcriptBootstrapLineLimit - 1)"
        })

        let resultOffset = (askLine + "\n").utf8.count
        let resultSeq = transcriptEventSequence(lineOffset: resultOffset, ordinal: 0)
        let askPage = BridgeAgentEventFetchFlow.run(eventHub: hub,
                                                    workspaceID: "workspace",
                                                    sessionID: "session",
                                                    limit: 20,
                                                    beforeSeq: resultSeq,
                                                    afterSeq: nil) { _, beforeSeq, limit in
            session.backfill(beforeSeq: beforeSeq, limit: limit)
        }
        XCTAssertTrue(askPage.didBackfill)
        XCTAssertFalse(askPage.fetchResult.events.contains {
            $0.type == .interactivePrompt && $0.metadata?["prompt_id"] == "toolu_cross_page"
        }, "a terminal outside before_seq must not leave its historical opener looking active")
        XCTAssertNil(hub.activeInteractivePrompt(workspaceID: "workspace",
                                                  sessionID: "session",
                                                  promptID: "toolu_cross_page"))

        let contextSummaryOffset = ([askLine, resultLine] + historySpacerLines + [contextCommandLine])
            .joined(separator: "\n")
            .appending("\n")
            .utf8.count
        let contextSummarySeq = transcriptEventSequence(lineOffset: contextSummaryOffset, ordinal: 0)
        let contextPage = BridgeAgentEventFetchFlow.run(eventHub: hub,
                                                        workspaceID: "workspace",
                                                        sessionID: "session",
                                                        limit: 20,
                                                        beforeSeq: contextSummarySeq,
                                                        afterSeq: nil) { _, beforeSeq, limit in
            session.backfill(beforeSeq: beforeSeq, limit: limit)
        }
        XCTAssertTrue(contextPage.didBackfill)
        XCTAssertFalse(contextPage.fetchResult.events.contains {
            $0.metadata?["tidey_generated"] == "claude_context_command"
        }, "a summary outside before_seq must not leave a bare /context command in history")
    }

    func testClaudeBackfillFiltersCachedOpenersWhenClosureIsOutsideCursor() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeTranscriptSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcriptURL = directory.appendingPathComponent("session.jsonl", isDirectory: false)

        let promptID = "toolu_cached"
        let askLine = makeClaudeAskUserQuestionAssistantLine(uuid: "cached-ask", toolCallID: promptID)
        let resultLine = makeClaudeToolResultLine(uuid: "cached-result",
                                                  toolCallID: promptID,
                                                  content: "answered")
        let contextCommandLine = makeClaudeUserLine(uuid: "cached-context-command",
                                                    content: "<command-name>/context</command-name>")
        let contextSummaryLine = makeClaudeContextStdoutLine(uuid: "cached-context-summary")
        let lines = [askLine, resultLine, contextCommandLine, contextSummaryLine]
        try (lines.joined(separator: "\n") + "\n").write(to: transcriptURL,
                                                            atomically: true,
                                                            encoding: .utf8)

        let hub = AgentEventHub()
        let session = ClaudeTranscriptSession(record: makeRecord(transcriptPath: transcriptURL.path),
                                              fileManager: .default,
                                              hub: hub)
        session.start()
        defer { session.stop() }
        XCTAssertTrue(waitUntil {
            hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 20).events.contains {
                $0.eventID == "cached-context-summary:claude-context:0"
            }
        })

        let resultOffset = (askLine + "\n").utf8.count
        let resultSeq = transcriptEventSequence(lineOffset: resultOffset, ordinal: 0)
        let askPage = BridgeAgentEventFetchFlow.run(eventHub: hub,
                                                    workspaceID: "workspace",
                                                    sessionID: "session",
                                                    limit: 20,
                                                    beforeSeq: resultSeq,
                                                    afterSeq: nil) { _, beforeSeq, limit in
            session.backfill(beforeSeq: beforeSeq, limit: limit)
        }
        XCTAssertTrue(askPage.didBackfill)
        XCTAssertFalse(askPage.fetchResult.events.contains {
            $0.eventID == "cached-ask:ask-user-question:\(promptID)"
        }, "an opener cached by bootstrap must still be filtered when its terminal is outside before_seq")

        let contextSummaryOffset = ([askLine, resultLine, contextCommandLine]
            .joined(separator: "\n") + "\n").utf8.count
        let contextSummarySeq = transcriptEventSequence(lineOffset: contextSummaryOffset, ordinal: 0)
        let contextPage = BridgeAgentEventFetchFlow.run(eventHub: hub,
                                                        workspaceID: "workspace",
                                                        sessionID: "session",
                                                        limit: 20,
                                                        beforeSeq: contextSummarySeq,
                                                        afterSeq: nil) { _, beforeSeq, limit in
            session.backfill(beforeSeq: beforeSeq, limit: limit)
        }
        XCTAssertTrue(contextPage.didBackfill)
        XCTAssertFalse(contextPage.fetchResult.events.contains {
            $0.eventID == "cached-context-command:claude-context-command:0"
        }, "a cached /context command must be filtered when its summary is outside before_seq")
    }

    func testClaudeAfterCursorBackfillsNextOrdinalFromSameLineAtCapacityOne() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeTranscriptSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcriptURL = directory.appendingPathComponent("session.jsonl", isDirectory: false)
        let line = makeClaudeAssistantTextLine(uuid: "same-line",
                                               texts: ["zero", "one", "two"])
        try (line + "\n").write(to: transcriptURL, atomically: true, encoding: .utf8)

        let hub = AgentEventHub(maxBufferedEvents: 1)
        let session = ClaudeTranscriptSession(record: makeRecord(transcriptPath: transcriptURL.path),
                                              fileManager: .default,
                                              hub: hub)
        session.start()
        defer { session.stop() }
        XCTAssertTrue(waitUntil {
            hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 1)
                .events.first?.text == "two"
        })

        let firstOrdinalSeq = transcriptEventSequence(lineOffset: 0, ordinal: 0)
        XCTAssertEqual(hub.fetch(workspaceID: "workspace",
                                 sessionID: "session",
                                 limit: 1,
                                 afterSeq: firstOrdinalSeq).events.compactMap(\.text),
                       ["two"],
                       "capacity one initially retains only the last same-line ordinal")

        let page = BridgeAgentEventFetchFlow.run(eventHub: hub,
                                                 workspaceID: "workspace",
                                                 sessionID: "session",
                                                 limit: 1,
                                                 beforeSeq: nil,
                                                 afterSeq: firstOrdinalSeq) { _, beforeSeq, limit in
            session.backfill(beforeSeq: beforeSeq, limit: limit)
        }

        XCTAssertTrue(page.didBackfill)
        XCTAssertEqual(page.fetchResult.events.compactMap(\.text), ["one"])
        XCTAssertEqual(page.fetchResult.events.first?.seq,
                       transcriptEventSequence(lineOffset: 0, ordinal: 1))
    }

    func testClaudeBeforeCursorPagesSequentialOrdinalsFromOffsetZero() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeTranscriptSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcriptURL = directory.appendingPathComponent("session.jsonl", isDirectory: false)
        let offsetZeroLine = makeClaudeAssistantTextLine(uuid: "offset-zero",
                                                         texts: ["zero", "one", "two"])
        let fillerLines = (0..<transcriptBootstrapLineLimit).map {
            makeClaudeUserLine(uuid: "filler-\($0)", content: "filler-\($0)")
        }
        try (([offsetZeroLine] + fillerLines).joined(separator: "\n") + "\n")
            .write(to: transcriptURL, atomically: true, encoding: .utf8)

        let hub = AgentEventHub()
        let session = ClaudeTranscriptSession(record: makeRecord(transcriptPath: transcriptURL.path),
                                              fileManager: .default,
                                              hub: hub)
        session.start()
        defer { session.stop() }
        XCTAssertTrue(waitUntil {
            hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 1)
                .events.first?.text == "filler-\(transcriptBootstrapLineLimit - 1)"
        })

        let beforeOrdinalTwo = BridgeAgentEventFetchFlow.run(
            eventHub: hub,
            workspaceID: "workspace",
            sessionID: "session",
            limit: 1,
            beforeSeq: transcriptEventSequence(lineOffset: 0, ordinal: 2),
            afterSeq: nil
        ) { _, beforeSeq, limit in
            session.backfill(beforeSeq: beforeSeq, limit: limit)
        }
        XCTAssertTrue(beforeOrdinalTwo.didBackfill)
        XCTAssertEqual(beforeOrdinalTwo.fetchResult.events.compactMap(\.text), ["one"])

        let beforeOrdinalOne = BridgeAgentEventFetchFlow.run(
            eventHub: hub,
            workspaceID: "workspace",
            sessionID: "session",
            limit: 1,
            beforeSeq: transcriptEventSequence(lineOffset: 0, ordinal: 1),
            afterSeq: nil
        ) { _, beforeSeq, limit in
            session.backfill(beforeSeq: beforeSeq, limit: limit)
        }
        XCTAssertTrue(beforeOrdinalOne.didBackfill)
        XCTAssertEqual(beforeOrdinalOne.fetchResult.events.compactMap(\.text), ["zero"])
        XCTAssertFalse(beforeOrdinalOne.fetchResult.events.contains { $0.text == "one" },
                       "the exact-anchor replacement must not leak the prior ordinal page")
    }

    func testClaudeBackfillIncludesEarlierOrdinalFromAnchorRecord() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeTranscriptSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcriptURL = directory.appendingPathComponent("session.jsonl", isDirectory: false)

        let promptID = "toolu_same_record"
        let askLine = makeClaudeAskUserQuestionAssistantLine(uuid: "same-record-ask",
                                                             toolCallID: promptID)
        let resultLine = makeClaudeToolResultLine(uuid: "same-record-result",
                                                  toolCallID: promptID,
                                                  content: "answered")
        let fillerLines = (0..<transcriptBootstrapLineLimit).map {
            makeClaudeUserLine(uuid: "filler-\($0)", content: "filler-\($0)")
        }
        try (([askLine, resultLine] + fillerLines).joined(separator: "\n") + "\n")
            .write(to: transcriptURL, atomically: true, encoding: .utf8)

        let hub = AgentEventHub()
        let session = ClaudeTranscriptSession(record: makeRecord(transcriptPath: transcriptURL.path),
                                              fileManager: .default,
                                              hub: hub)
        session.start()
        defer { session.stop() }
        XCTAssertTrue(waitUntil {
            hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 1)
                .events.first?.text == "filler-\(transcriptBootstrapLineLimit - 1)"
        })

        let resultOffset = (askLine + "\n").utf8.count
        let resolvedOrdinalSeq = transcriptEventSequence(lineOffset: resultOffset, ordinal: 1)
        let page = BridgeAgentEventFetchFlow.run(eventHub: hub,
                                                 workspaceID: "workspace",
                                                 sessionID: "session",
                                                 limit: 20,
                                                 beforeSeq: resolvedOrdinalSeq,
                                                 afterSeq: nil) { _, beforeSeq, limit in
            session.backfill(beforeSeq: beforeSeq, limit: limit)
        }

        XCTAssertTrue(page.didBackfill)
        XCTAssertTrue(page.fetchResult.events.contains {
            $0.eventID == "same-record-result:tool-result:0" && $0.type == .toolResult
        }, "ordinal zero from the anchor record must remain visible before ordinal one")
        XCTAssertFalse(page.fetchResult.events.contains {
            $0.eventID == "same-record-result:ask-user-question-resolved:\(promptID)"
        })
        XCTAssertTrue(page.fetchResult.events.allSatisfy { $0.seq < resolvedOrdinalSeq })
    }

    func testClaudeBackfillKeepsRepeatedAskOpenAfterEarlierSameIDWasResolved() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeTranscriptSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcriptURL = directory.appendingPathComponent("session.jsonl", isDirectory: false)

        let promptID = "toolu_reused"
        let firstAskLine = makeClaudeAskUserQuestionAssistantLine(uuid: "first-ask",
                                                                  toolCallID: promptID)
        let firstResultLine = makeClaudeToolResultLine(uuid: "first-result",
                                                       toolCallID: promptID,
                                                       content: "answered first lifecycle")
        let secondAskLine = makeClaudeAskUserQuestionAssistantLine(uuid: "second-ask",
                                                                   toolCallID: promptID)
        let fillerLines = (0..<transcriptBootstrapLineLimit).map {
            makeClaudeUserLine(uuid: "filler-\($0)", content: "filler-\($0)")
        }
        let lifecycleLines = [firstAskLine, firstResultLine, secondAskLine]
        let lines = lifecycleLines + fillerLines
        try (lines.joined(separator: "\n") + "\n").write(to: transcriptURL,
                                                            atomically: true,
                                                            encoding: .utf8)

        let hub = AgentEventHub()
        let session = ClaudeTranscriptSession(record: makeRecord(transcriptPath: transcriptURL.path),
                                              fileManager: .default,
                                              hub: hub)
        session.start()
        defer { session.stop() }
        XCTAssertTrue(waitUntil {
            hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 1)
                .events.first?.text == "filler-\(transcriptBootstrapLineLimit - 1)"
        })

        let firstFillerOffset = (lifecycleLines.joined(separator: "\n") + "\n").utf8.count
        let secondAskPageAnchor = transcriptEventSequence(lineOffset: firstFillerOffset, ordinal: 0)
        let secondAskPage = BridgeAgentEventFetchFlow.run(eventHub: hub,
                                                          workspaceID: "workspace",
                                                          sessionID: "session",
                                                          limit: 1,
                                                          beforeSeq: secondAskPageAnchor,
                                                          afterSeq: nil) { _, beforeSeq, limit in
            session.backfill(beforeSeq: beforeSeq, limit: limit)
        }

        XCTAssertTrue(secondAskPage.didBackfill)
        XCTAssertEqual(secondAskPage.fetchResult.events.map(\.eventID),
                       ["second-ask:ask-user-question:\(promptID)"])
        XCTAssertFalse(secondAskPage.fetchResult.events.contains {
            $0.type == .interactivePromptResolved && $0.metadata?["prompt_id"] == promptID
        }, "the first lifecycle's terminal must not close the later reused tool ID")
        XCTAssertNotNil(hub.activeInteractivePrompt(workspaceID: "workspace",
                                                     sessionID: "session",
                                                     promptID: promptID))
    }

    func testClaudeRepeatedAskUsesExactLifecycleForDelayedTerminal() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeTranscriptSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcriptURL = directory.appendingPathComponent("session.jsonl", isDirectory: false)

        let promptID = "toolu_overlapping_reuse"
        let firstAskLine = makeClaudeAskUserQuestionAssistantLine(uuid: "overlap-first",
                                                                  toolCallID: promptID)
        let secondAskLine = makeClaudeAskUserQuestionAssistantLine(uuid: "overlap-second",
                                                                   toolCallID: promptID)
        let delayedResultLine = makeClaudeToolResultLine(uuid: "delayed-first-result",
                                                         toolCallID: promptID,
                                                         content: "answered first lifecycle")
        let lifecycleLines = [firstAskLine, secondAskLine, delayedResultLine]
        let fillerLines = (0..<transcriptBootstrapLineLimit).map {
            makeClaudeUserLine(uuid: "filler-\($0)", content: "filler-\($0)")
        }
        try ((lifecycleLines + fillerLines).joined(separator: "\n") + "\n")
            .write(to: transcriptURL, atomically: true, encoding: .utf8)

        let hub = AgentEventHub()
        let session = ClaudeTranscriptSession(record: makeRecord(transcriptPath: transcriptURL.path),
                                              fileManager: .default,
                                              hub: hub)
        session.start()
        defer { session.stop() }
        XCTAssertTrue(waitUntil {
            hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 1)
                .events.first?.text == "filler-\(transcriptBootstrapLineLimit - 1)"
        })

        let resultOffset = ([firstAskLine, secondAskLine].joined(separator: "\n") + "\n").utf8.count
        let resultSeq = transcriptEventSequence(lineOffset: resultOffset, ordinal: 0)
        let beforeResult = BridgeAgentEventFetchFlow.run(eventHub: hub,
                                                         workspaceID: "workspace",
                                                         sessionID: "session",
                                                         limit: 20,
                                                         beforeSeq: resultSeq,
                                                         afterSeq: nil) { _, beforeSeq, limit in
            session.backfill(beforeSeq: beforeSeq, limit: limit)
        }
        XCTAssertTrue(beforeResult.didBackfill)
        XCTAssertFalse(beforeResult.fetchResult.events.contains {
            $0.eventID == "overlap-first:ask-user-question:\(promptID)"
        })
        XCTAssertTrue(beforeResult.fetchResult.events.contains {
            $0.eventID == "overlap-second:ask-user-question:\(promptID)"
        }, "the delayed terminal belongs to the oldest pending lifecycle, not the later reused ID")

        let firstFillerOffset = (lifecycleLines.joined(separator: "\n") + "\n").utf8.count
        let afterResult = BridgeAgentEventFetchFlow.run(
            eventHub: hub,
            workspaceID: "workspace",
            sessionID: "session",
            limit: 20,
            beforeSeq: transcriptEventSequence(lineOffset: firstFillerOffset, ordinal: 0),
            afterSeq: nil) { _, beforeSeq, limit in
                session.backfill(beforeSeq: beforeSeq, limit: limit)
            }
        let firstLifecycleToken = "overlap-first:ask-user-question:\(promptID)"
        XCTAssertTrue(afterResult.fetchResult.events.contains {
            $0.type == .interactivePromptResolved
                && $0.metadata?["lifecycle_token"] == firstLifecycleToken
        })
        XCTAssertNotNil(hub.activeInteractivePrompt(workspaceID: "workspace",
                                                     sessionID: "session",
                                                     promptID: promptID),
                        "the newer overlapping lifecycle must remain active after the old terminal")
    }

    func testClaudeLiveResultResolvesPreviouslyBackfilledAsk() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeTranscriptSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcriptURL = directory.appendingPathComponent("session.jsonl", isDirectory: false)

        let promptID = "toolu_historical_then_live"
        let askLine = makeClaudeAskUserQuestionAssistantLine(uuid: "historical-ask",
                                                             toolCallID: promptID)
        let fillerLines = (0..<transcriptBootstrapLineLimit).map {
            makeClaudeUserLine(uuid: "filler-\($0)", content: "filler-\($0)")
        }
        try (([askLine] + fillerLines).joined(separator: "\n") + "\n").write(to: transcriptURL,
                                                                               atomically: true,
                                                                               encoding: .utf8)

        let hub = AgentEventHub()
        let session = ClaudeTranscriptSession(record: makeRecord(transcriptPath: transcriptURL.path),
                                              fileManager: .default,
                                              hub: hub)
        session.start()
        defer { session.stop() }
        XCTAssertTrue(waitUntil {
            hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 1)
                .events.first?.text == "filler-\(transcriptBootstrapLineLimit - 1)"
        })

        let firstFillerOffset = (askLine + "\n").utf8.count
        let firstFillerSeq = transcriptEventSequence(lineOffset: firstFillerOffset, ordinal: 0)
        let askPage = BridgeAgentEventFetchFlow.run(eventHub: hub,
                                                    workspaceID: "workspace",
                                                    sessionID: "session",
                                                    limit: 1,
                                                    beforeSeq: firstFillerSeq,
                                                    afterSeq: nil) { _, beforeSeq, limit in
            session.backfill(beforeSeq: beforeSeq, limit: limit)
        }
        XCTAssertTrue(askPage.didBackfill)
        XCTAssertEqual(askPage.fetchResult.events.map(\.eventID),
                       ["historical-ask:ask-user-question:\(promptID)"])
        XCTAssertNotNil(hub.activeInteractivePrompt(workspaceID: "workspace",
                                                     sessionID: "session",
                                                     promptID: promptID))

        let resultLine = makeClaudeToolResultLine(uuid: "live-result",
                                                  toolCallID: promptID,
                                                  content: "answered live")
        let handle = try FileHandle(forWritingTo: transcriptURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((resultLine + "\n").utf8))
        try handle.close()

        XCTAssertTrue(waitUntil {
            let events = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 5000).events
            let didResolve = events.contains {
                $0.type == .interactivePromptResolved
                    && $0.metadata?["prompt_id"] == promptID
                    && $0.eventID.contains("live-result")
            }
            return didResolve
                && hub.activeInteractivePrompt(workspaceID: "workspace",
                                               sessionID: "session",
                                               promptID: promptID) == nil
        }, "a live terminal must resolve the exact historical opener already exposed by backfill")
    }

    func testClaudeLiveStdoutSummarizesPreviouslyBackfilledContext() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeTranscriptSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcriptURL = directory.appendingPathComponent("session.jsonl", isDirectory: false)

        let contextLine = makeClaudeUserLine(uuid: "historical-context",
                                             content: "<command-name>/context</command-name>")
        let fillerLines = (0..<transcriptBootstrapLineLimit).map {
            makeClaudeUserLine(uuid: "filler-\($0)", content: "filler-\($0)")
        }
        try (([contextLine] + fillerLines).joined(separator: "\n") + "\n").write(to: transcriptURL,
                                                                                   atomically: true,
                                                                                   encoding: .utf8)

        let hub = AgentEventHub()
        let session = ClaudeTranscriptSession(record: makeRecord(transcriptPath: transcriptURL.path),
                                              fileManager: .default,
                                              hub: hub)
        session.start()
        defer { session.stop() }
        XCTAssertTrue(waitUntil {
            hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 1)
                .events.first?.text == "filler-\(transcriptBootstrapLineLimit - 1)"
        })

        let firstFillerOffset = (contextLine + "\n").utf8.count
        let firstFillerSeq = transcriptEventSequence(lineOffset: firstFillerOffset, ordinal: 0)
        let commandPage = BridgeAgentEventFetchFlow.run(eventHub: hub,
                                                        workspaceID: "workspace",
                                                        sessionID: "session",
                                                        limit: 1,
                                                        beforeSeq: firstFillerSeq,
                                                        afterSeq: nil) { _, beforeSeq, limit in
            session.backfill(beforeSeq: beforeSeq, limit: limit)
        }
        XCTAssertTrue(commandPage.didBackfill)
        XCTAssertEqual(commandPage.fetchResult.events.map(\.eventID),
                       ["historical-context:claude-context-command:0"])

        let stdoutLine = makeClaudeContextStdoutLine(uuid: "live-context-summary")
        let handle = try FileHandle(forWritingTo: transcriptURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((stdoutLine + "\n").utf8))
        try handle.close()

        XCTAssertTrue(waitUntil {
            hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 5000).events.contains {
                $0.eventID == "live-context-summary:claude-context:0"
                    && $0.metadata?["tidey_generated"] == "claude_context"
            }
        }, "live stdout must retain the historical /context pairing without leaking replay parser state")
    }

    func testClaudeBackfillTreatsLaterCommandAsContextConsumer() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeTranscriptSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcriptURL = directory.appendingPathComponent("session.jsonl", isDirectory: false)

        let firstContextLine = makeClaudeUserLine(uuid: "first-context",
                                                  content: "<command-name>/context</command-name>")
        let secondContextLine = makeClaudeUserLine(uuid: "second-context",
                                                   content: "<command-name>/context</command-name>")
        let secondSummaryLine = makeClaudeContextStdoutLine(uuid: "second-summary")
        let fillerLines = (0..<transcriptBootstrapLineLimit).map {
            makeClaudeUserLine(uuid: "filler-\($0)", content: "filler-\($0)")
        }
        let lines = [firstContextLine, secondContextLine, secondSummaryLine] + fillerLines
        try (lines.joined(separator: "\n") + "\n").write(to: transcriptURL,
                                                            atomically: true,
                                                            encoding: .utf8)

        let hub = AgentEventHub()
        let session = ClaudeTranscriptSession(record: makeRecord(transcriptPath: transcriptURL.path),
                                              fileManager: .default,
                                              hub: hub)
        session.start()
        defer { session.stop() }
        XCTAssertTrue(waitUntil {
            hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 1)
                .events.first?.text == "filler-\(transcriptBootstrapLineLimit - 1)"
        })

        let secondContextOffset = (firstContextLine + "\n").utf8.count
        let secondContextSeq = transcriptEventSequence(lineOffset: secondContextOffset, ordinal: 0)
        let firstContextPage = BridgeAgentEventFetchFlow.run(eventHub: hub,
                                                             workspaceID: "workspace",
                                                             sessionID: "session",
                                                             limit: 1,
                                                             beforeSeq: secondContextSeq,
                                                             afterSeq: nil) { _, beforeSeq, limit in
            session.backfill(beforeSeq: beforeSeq, limit: limit)
        }

        XCTAssertTrue(firstContextPage.didBackfill)
        XCTAssertFalse(firstContextPage.fetchResult.events.contains {
            $0.eventID == "first-context:claude-context-command:0"
        }, "a later command outside before_seq must consume the earlier /context command")
    }

    func testClaudeBackfillTreatsUnparseableStdoutAsContextConsumer() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeTranscriptSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcriptURL = directory.appendingPathComponent("session.jsonl", isDirectory: false)

        let contextLine = makeClaudeUserLine(uuid: "context",
                                             content: "<command-name>/context</command-name>")
        let unparseableStdoutLine = makeClaudeUserLine(
            uuid: "unparseable-stdout",
            content: "<local-command-stdout>not a context report</local-command-stdout>")
        let fillerLines = (0..<transcriptBootstrapLineLimit).map {
            makeClaudeUserLine(uuid: "filler-\($0)", content: "filler-\($0)")
        }
        let lines = [contextLine, unparseableStdoutLine] + fillerLines
        try (lines.joined(separator: "\n") + "\n").write(to: transcriptURL,
                                                            atomically: true,
                                                            encoding: .utf8)

        let hub = AgentEventHub()
        let session = ClaudeTranscriptSession(record: makeRecord(transcriptPath: transcriptURL.path),
                                              fileManager: .default,
                                              hub: hub)
        session.start()
        defer { session.stop() }
        XCTAssertTrue(waitUntil {
            hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 1)
                .events.first?.text == "filler-\(transcriptBootstrapLineLimit - 1)"
        })

        let stdoutOffset = (contextLine + "\n").utf8.count
        let stdoutSeq = transcriptEventSequence(lineOffset: stdoutOffset, ordinal: 0)
        let contextPage = BridgeAgentEventFetchFlow.run(eventHub: hub,
                                                        workspaceID: "workspace",
                                                        sessionID: "session",
                                                        limit: 1,
                                                        beforeSeq: stdoutSeq,
                                                        afterSeq: nil) { _, beforeSeq, limit in
            session.backfill(beforeSeq: beforeSeq, limit: limit)
        }

        XCTAssertTrue(contextPage.didBackfill)
        XCTAssertFalse(contextPage.fetchResult.events.contains {
            $0.eventID == "context:claude-context-command:0"
        }, "an unparseable stdout outside before_seq must still consume the pending /context")
        XCTAssertFalse(contextPage.fetchResult.events.contains {
            $0.metadata?["tidey_generated"] == "claude_context"
        }, "an unparseable stdout must not invent a context summary")
    }

    func testTranscriptSwitchRevokesOldHistoryAndMapsNewSourceCursor() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeTranscriptSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let oldURL = directory.appendingPathComponent("old.jsonl", isDirectory: false)
        let longPad = String(repeating: "x", count: 400)
        var oldLines = [makeClaudeUserLine(uuid: "shared", content: "old-row")]
        oldLines.append(contentsOf: (0..<200).map {
            makeClaudeUserLine(uuid: "old-pad-\($0)", content: "pad-\($0)-\(longPad)")
        })
        oldLines.append(contentsOf: (0..<transcriptBootstrapLineLimit).map {
            makeClaudeUserLine(uuid: "old-filler-\($0)", content: "old-live-\($0)")
        })
        try (oldLines.joined(separator: "\n") + "\n").write(to: oldURL,
                                                               atomically: true,
                                                               encoding: .utf8)

        let hub = AgentEventHub()
        let session = ClaudeTranscriptSession(record: makeRecord(transcriptPath: oldURL.path),
                                              fileManager: .default,
                                              hub: hub)
        session.start()
        defer { session.stop() }
        XCTAssertTrue(waitUntil {
            hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 1)
                .events.first?.text == "old-live-\(transcriptBootstrapLineLimit - 1)"
        })
        let oldBoundary = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 5000)
            .events.filter { ($0.text ?? "").hasPrefix("old-live-") }.map(\.seq).min() ?? 0
        XCTAssertTrue(session.backfill(beforeSeq: oldBoundary, limit: 300))
        XCTAssertTrue(hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 5000)
            .events.contains { $0.text == "old-row" })
        let oldMaxSeq = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 5000)
            .events.map(\.seq).max() ?? 0

        let newURL = directory.appendingPathComponent("new.jsonl", isDirectory: false)
        var newLines = [
            makeClaudeUserLine(uuid: "shared", content: "new-old-0"),
            makeClaudeUserLine(uuid: "new-old-1", content: "new-old-1"),
        ]
        newLines.append(contentsOf: (0..<transcriptBootstrapLineLimit).map {
            makeClaudeUserLine(uuid: "new-filler-\($0)", content: "new-live-\($0)")
        })
        try (newLines.joined(separator: "\n") + "\n").write(to: newURL,
                                                               atomically: true,
                                                               encoding: .utf8)
        session.update(record: makeRecord(transcriptPath: newURL.path))
        XCTAssertTrue(waitUntil(timeout: 10) {
            hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 1)
                .events.first?.text == "new-live-\(transcriptBootstrapLineLimit - 1)"
        })

        let switched = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 5000)
        XCTAssertFalse(switched.events.contains { $0.text == "old-row" })
        let newBoundary = switched.events
            .filter { ($0.text ?? "").hasPrefix("new-live-") }
            .map(\.seq)
            .min() ?? 0
        XCTAssertGreaterThan(newBoundary, oldMaxSeq)
        XCTAssertTrue(session.backfill(beforeSeq: newBoundary, limit: 2))
        let history = hub.fetch(workspaceID: "workspace",
                                sessionID: "session",
                                limit: 5000,
                                beforeSeq: newBoundary)
            .events
            .filter { $0.seq > 0 }
        XCTAssertEqual(history.compactMap(\.text), ["new-old-0", "new-old-1"])
    }

    func testTranscriptSwitchPreservesExactCursorWhenHubRebasesFirstEvent() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeTranscriptSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let oldURL = directory.appendingPathComponent("old.jsonl", isDirectory: false)
        try (makeClaudeUserLine(uuid: "old", content: "old") + "\n")
            .write(to: oldURL, atomically: true, encoding: .utf8)

        let hub = AgentEventHub(maxBufferedEvents: 1)
        let session = ClaudeTranscriptSession(record: makeRecord(transcriptPath: oldURL.path),
                                              fileManager: .default,
                                              hub: hub)
        session.start()
        defer { session.stop() }
        XCTAssertTrue(waitUntil {
            hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 1)
                .events.first?.text == "old"
        })
        let oldSeq = try XCTUnwrap(
            hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 1).events.first?.seq
        )
        hub.publish(AgentEvent(eventID: "external-synthetic",
                               seq: oldSeq + 1_000,
                               vendor: "claude",
                               workspaceID: "workspace",
                               sessionID: "session",
                               timestamp: "2026-07-23T00:00:00Z",
                               type: .status,
                               role: nil,
                               text: nil,
                               name: nil,
                               input: nil,
                               output: nil,
                               toolCallID: nil,
                               metadata: nil))

        let deliveryLock = NSLock()
        var deliveredEvents = [AgentEvent]()
        let (subscriptionID, _) = hub.subscribe(workspaceID: "workspace", sessionID: "session") { envelope in
            deliveryLock.lock()
            deliveredEvents.append(envelope.event)
            deliveryLock.unlock()
        }
        defer { hub.unsubscribe(subscriptionID) }

        let newURL = directory.appendingPathComponent("new.jsonl", isDirectory: false)
        let newLines = [
            makeClaudeUserLine(uuid: "new-first", content: "new-first"),
            makeClaudeUserLine(uuid: "new-second", content: "new-second"),
        ]
        try (newLines.joined(separator: "\n") + "\n")
            .write(to: newURL, atomically: true, encoding: .utf8)
        session.update(record: makeRecord(transcriptPath: newURL.path))
        XCTAssertTrue(waitUntil(timeout: 10) {
            deliveryLock.lock()
            defer { deliveryLock.unlock() }
            return deliveredEvents.contains { $0.text == "new-first" }
                && deliveredEvents.contains { $0.text == "new-second" }
        })
        deliveryLock.lock()
        let firstPublicSeq = deliveredEvents.first { $0.text == "new-first" }?.seq
        deliveryLock.unlock()
        let firstSeq = try XCTUnwrap(firstPublicSeq)
        XCTAssertFalse(hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 10)
            .events.contains { $0.text == "new-first" },
                       "capacity one must evict the first event before historical replay")

        let beforeFirst = BridgeAgentEventFetchFlow.run(eventHub: hub,
                                                        workspaceID: "workspace",
                                                        sessionID: "session",
                                                        limit: 10,
                                                        beforeSeq: firstSeq,
                                                        afterSeq: nil) { _, beforeSeq, limit in
            session.backfill(beforeSeq: beforeSeq, limit: limit)
        }
        XCTAssertFalse(beforeFirst.fetchResult.events.contains { $0.text == "new-first" },
                       "a rebased public cursor must still exclude its exact source event")
    }

    func testFileBackedCursorUsesAcceptedHubSequenceAfterMidSourceRebase() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeTranscriptSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcriptURL = directory.appendingPathComponent("session.jsonl", isDirectory: false)
        try (makeClaudeUserLine(uuid: "initial", content: "initial") + "\n")
            .write(to: transcriptURL, atomically: true, encoding: .utf8)

        let hub = AgentEventHub(maxBufferedEvents: 1)
        let session = ClaudeTranscriptSession(record: makeRecord(transcriptPath: transcriptURL.path),
                                              fileManager: .default,
                                              hub: hub)
        session.start()
        defer { session.stop() }
        XCTAssertTrue(waitUntil {
            hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 1)
                .events.first?.text == "initial"
        })
        hub.publish(AgentEvent(eventID: "mid-source-synthetic",
                               seq: 20_000_000,
                               vendor: "claude",
                               workspaceID: "workspace",
                               sessionID: "session",
                               timestamp: "2026-07-23T00:00:00Z",
                               type: .status,
                               role: nil,
                               text: nil,
                               name: nil,
                               input: nil,
                               output: nil,
                               toolCallID: nil,
                               metadata: nil))

        let deliveryLock = NSLock()
        var deliveredEvents = [AgentEvent]()
        let (subscriptionID, _) = hub.subscribe(workspaceID: "workspace", sessionID: "session") { envelope in
            deliveryLock.lock()
            deliveredEvents.append(envelope.event)
            deliveryLock.unlock()
        }
        defer { hub.unsubscribe(subscriptionID) }
        let appendedLines = [
            makeClaudeUserLine(uuid: "rebased", content: "rebased"),
            makeClaudeUserLine(uuid: "after-rebased", content: "after-rebased"),
        ]
        let handle = try FileHandle(forWritingTo: transcriptURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((appendedLines.joined(separator: "\n") + "\n").utf8))
        try handle.close()
        XCTAssertTrue(waitUntil {
            deliveryLock.lock()
            defer { deliveryLock.unlock() }
            return deliveredEvents.contains { $0.text == "rebased" }
                && deliveredEvents.contains { $0.text == "after-rebased" }
        })
        deliveryLock.lock()
        let rebasedPublicSeq = deliveredEvents.first { $0.text == "rebased" }?.seq
        deliveryLock.unlock()
        let rebasedSeq = try XCTUnwrap(rebasedPublicSeq)
        XCTAssertGreaterThan(rebasedSeq, 20_000_000)
        XCTAssertFalse(hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 10)
            .events.contains { $0.text == "rebased" })

        let beforeRebased = BridgeAgentEventFetchFlow.run(eventHub: hub,
                                                          workspaceID: "workspace",
                                                          sessionID: "session",
                                                          limit: 10,
                                                          beforeSeq: rebasedSeq,
                                                          afterSeq: nil) { _, beforeSeq, limit in
            session.backfill(beforeSeq: beforeSeq, limit: limit)
        }
        XCTAssertFalse(beforeRebased.fetchResult.events.contains { $0.text == "rebased" },
                       "cursor inversion must use the sequence actually accepted by Hub")
    }

    func testFetchDoesNotReturnOldPageWhenSamePathIsReplacedDuringBackfill() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeTranscriptSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcriptURL = directory.appendingPathComponent("session.jsonl", isDirectory: false)
        let oldLines = (0..<8).map {
            makeClaudeUserLine(uuid: "old-\($0)", content: "old-\($0)")
        }
        try (oldLines.joined(separator: "\n") + "\n")
            .write(to: transcriptURL, atomically: true, encoding: .utf8)

        let hub = AgentEventHub()
        let session = ClaudeTranscriptSession(record: makeRecord(transcriptPath: transcriptURL.path),
                                              fileManager: .default,
                                              hub: hub)
        session.start()
        defer { session.stop() }
        XCTAssertTrue(waitUntil {
            hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 20)
                .events.contains { $0.text == "old-7" }
        })
        let beforeSeq = try XCTUnwrap(
            hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 20)
                .events.last { ($0.text ?? "").hasPrefix("old-") }?.seq
        )
        let replacementLines = (0..<4).map {
            makeClaudeUserLine(uuid: "new-\($0)", content: "new-\($0)")
        }
        var replacementError: Error?
        session.historicalIndexBeforeSourceValidationForTesting = {
            do {
                try (replacementLines.joined(separator: "\n") + "\n")
                    .write(to: transcriptURL, atomically: true, encoding: .utf8)
            } catch {
                replacementError = error
            }
        }

        let output = BridgeAgentEventFetchFlow.run(eventHub: hub,
                                                   workspaceID: "workspace",
                                                   sessionID: "session",
                                                   limit: 4,
                                                   beforeSeq: beforeSeq,
                                                   afterSeq: nil) { _, anchor, limit in
            return session.backfill(beforeSeq: anchor, limit: limit)
        }

        XCTAssertNil(replacementError)
        XCTAssertFalse(output.didBackfill)
        XCTAssertFalse(output.fetchResult.events.contains { ($0.text ?? "").hasPrefix("old-") },
                       "a response captured before the source reset must be discarded")
    }

    func testInteractivePromptSidebarTerminalEffectsAreExactlyOnce() {
        let sender = ClaudePromptRecordingCommandSender()
        let session = ClaudeTranscriptSession(record: makeRecord(transcriptPath: "/tmp/unused.jsonl"),
                                              hub: AgentEventHub(),
                                              socketClient: sender)
        func event(_ eventID: String,
                   type: AgentEventKind,
                   promptID: String = "prompt-1") -> AgentEvent {
            AgentEvent(eventID: eventID,
                       seq: 1,
                       vendor: "claude",
                       workspaceID: "workspace",
                       sessionID: "session",
                       timestamp: "2026-04-30T00:00:00Z",
                       type: type,
                       role: nil,
                       text: nil,
                       name: nil,
                       input: nil,
                       output: nil,
                       toolCallID: nil,
                       metadata: ["prompt_id": promptID])
        }
        func notificationCount() -> Int {
            sender.commands().filter { $0.contains("notification.create") }.count
        }
        func runningCount() -> Int {
            sender.commands().filter { $0.contains("report_shell_state running") }.count
        }

        session.publishInteractivePromptSidebarIfNeeded(event("prompt-a", type: .interactivePrompt))
        session.publishInteractivePromptSidebarIfNeeded(event("prompt-a-duplicate", type: .interactivePrompt))
        XCTAssertEqual(notificationCount(), 1)

        session.publishInteractivePromptSidebarIfNeeded(event("unknown-terminal",
                                                               type: .interactivePromptResolved,
                                                               promptID: "other-prompt"))
        XCTAssertEqual(runningCount(), 0)
        session.publishInteractivePromptSidebarIfNeeded(event("matching-terminal", type: .interactivePromptResolved))
        session.publishInteractivePromptSidebarIfNeeded(event("duplicate-terminal", type: .interactivePromptResolved))
        XCTAssertEqual(runningCount(), 1)

        session.publishInteractivePromptSidebarIfNeeded(event("prompt-redelivery", type: .interactivePrompt))
        XCTAssertEqual(notificationCount(), 2)
    }

    private func makeRecord(transcriptPath: String) -> AgentSessionRegistryRecord {
        AgentSessionRegistryRecord(version: 1,
                                   vendor: "claude",
                                   workspaceID: "workspace",
                                   sessionID: "session",
                                   panelID: "panel",
                                   pid: Int32(ProcessInfo.processInfo.processIdentifier),
                                   cwd: "/tmp",
                                   createdAt: "2026-04-30T00:00:00Z",
                                   transcriptPath: transcriptPath)
    }

    private func assertClaudeHistoryIndexFailureHidesCachedOpener(
        appendedData: Data,
        partialLineByteLimit: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeTranscriptSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcriptURL = directory.appendingPathComponent("session.jsonl", isDirectory: false)
        let promptID = "toolu_fail_closed"
        let askLine = makeClaudeAskUserQuestionAssistantLine(uuid: "fail-closed-ask",
                                                             toolCallID: promptID)
        let fillerLines = (0..<transcriptBootstrapLineLimit).map {
            makeClaudeUserLine(uuid: "filler-\($0)", content: "filler-\($0)")
        }
        try (([askLine] + fillerLines).joined(separator: "\n") + "\n")
            .write(to: transcriptURL, atomically: true, encoding: .utf8)

        let hub = AgentEventHub()
        let session = ClaudeTranscriptSession(
            record: makeRecord(transcriptPath: transcriptURL.path),
            fileManager: .default,
            hub: hub,
            historicalPartialLineByteLimit: partialLineByteLimit)
        session.start()
        defer { session.stop() }
        XCTAssertTrue(waitUntil {
            hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 1)
                .events.first?.text == "filler-\(transcriptBootstrapLineLimit - 1)"
        }, "bootstrap must reach the live anchor", file: file, line: line)
        let firstFillerOffset = (askLine + "\n").utf8.count
        let anchor = transcriptEventSequence(lineOffset: firstFillerOffset, ordinal: 0)
        let initialPage = BridgeAgentEventFetchFlow.run(
            eventHub: hub,
            workspaceID: "workspace",
            sessionID: "session",
            limit: 20,
            beforeSeq: anchor,
            afterSeq: nil) { _, beforeSeq, limit in
                session.backfill(beforeSeq: beforeSeq, limit: limit)
            }
        XCTAssertTrue(initialPage.fetchResult.events.contains {
            $0.eventID == "fail-closed-ask:ask-user-question:\(promptID)"
        }, "the baseline index must expose a genuinely open historical Ask; got \(initialPage.fetchResult.events.map(\.eventID))",
                      file: file, line: line)

        let handle = try FileHandle(forWritingTo: transcriptURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: appendedData)
        try handle.close()
        let failedPage = BridgeAgentEventFetchFlow.run(
            eventHub: hub,
            workspaceID: "workspace",
            sessionID: "session",
            limit: 20,
            beforeSeq: anchor,
            afterSeq: nil) { _, beforeSeq, limit in
                session.backfill(beforeSeq: beforeSeq, limit: limit)
            }
        XCTAssertFalse(failedPage.fetchResult.events.contains {
            $0.eventID == "fail-closed-ask:ask-user-question:\(promptID)"
        }, "unknown source-wide closure coverage must never expose a cached opener",
                       file: file, line: line)
    }

    private func assertClaudeLiveRecordFailureHidesBufferedOpener(
        appendedData: Data,
        promptID: String,
        caseName: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeTranscriptSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcriptURL = directory.appendingPathComponent("session.jsonl", isDirectory: false)
        let askLine = makeClaudeAskUserQuestionAssistantLine(uuid: "live-invalid-ask",
                                                             toolCallID: promptID)
        try (askLine + "\n").write(to: transcriptURL, atomically: true, encoding: .utf8)

        let hub = AgentEventHub()
        let session = ClaudeTranscriptSession(record: makeRecord(transcriptPath: transcriptURL.path),
                                              fileManager: .default,
                                              hub: hub)
        session.start()
        defer { session.stop() }
        XCTAssertTrue(waitUntil {
            hub.activeInteractivePrompt(workspaceID: "workspace",
                                        sessionID: "session",
                                        promptID: promptID) != nil
        }, "precondition failed for \(caseName)", file: file, line: line)

        let handle = try FileHandle(forWritingTo: transcriptURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: appendedData)
        try handle.close()

        XCTAssertTrue(waitUntil {
            hub.activeInteractivePrompt(workspaceID: "workspace",
                                        sessionID: "session",
                                        promptID: promptID) == nil
        }, "\(caseName) must revoke submission immediately", file: file, line: line)
        XCTAssertFalse(hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 20)
            .events.contains { $0.eventID == "live-invalid-ask:ask-user-question:\(promptID)" },
                       "\(caseName) must hide the buffered opener from latest fetch",
                       file: file,
                       line: line)
    }

    private func makeClaudeAssistantTextLine(uuid: String, texts: [String]) -> String {
        let object: [String: Any] = [
            "type": "assistant",
            "uuid": uuid,
            "sessionId": "session",
            "version": "2.0.0",
            "timestamp": "2026-04-30T00:00:00Z",
            "message": [
                "role": "assistant",
                "content": texts.map { ["type": "text", "text": $0] },
            ],
        ]
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(data: data, encoding: .utf8)!
    }

    private func makeClaudeUserLine(uuid: String,
                                    content: String,
                                    version: String = "2.0.0") -> String {
        let object: [String: Any] = [
            "type": "user",
            "uuid": uuid,
            "sessionId": "session",
            "version": version,
            "timestamp": "2026-04-30T00:00:00Z",
            "message": [
                "role": "user",
                "content": content,
            ],
        ]
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(data: data, encoding: .utf8)!
    }

    private func makeClaudeAskUserQuestionAssistantLine(uuid: String,
                                                        toolCallID: String,
                                                        multiSelect: Bool = false) -> String {
        let object: [String: Any] = [
            "type": "assistant",
            "uuid": uuid,
            "sessionId": "session",
            "version": "2.0.0",
            "timestamp": "2026-04-30T00:00:00Z",
            "message": [
                "role": "assistant",
                "content": [
                    [
                        "type": "tool_use",
                        "id": toolCallID,
                        "name": "AskUserQuestion",
                        "input": [
                            "questions": [
                                [
                                    "question": "Which path should Claude use?",
                                    "header": "Choose a path",
                                    "multiSelect": multiSelect,
                                    "options": [
                                        [
                                            "label": "Use current file",
                                            "description": "Open the current file.",
                                        ],
                                        [
                                            "label": "Cancel",
                                            "description": "Do not change files.",
                                        ],
                                    ],
                                ],
                            ],
                        ],
                    ],
                ],
            ],
        ]
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(data: data, encoding: .utf8)!
    }

    private func makeClaudeToolResultLine(uuid: String,
                                          toolCallID: String,
                                          content: String,
                                          version: String = "2.0.0") -> String {
        let object: [String: Any] = [
            "type": "user",
            "uuid": uuid,
            "sessionId": "session",
            "version": version,
            "timestamp": "2026-04-30T00:00:02Z",
            "message": [
                "role": "user",
                "content": [
                    [
                        "type": "tool_result",
                        "tool_use_id": toolCallID,
                        "content": content,
                    ],
                ],
            ],
        ]
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(data: data, encoding: .utf8)!
    }

    private func makeClaudeContextStdoutLine(uuid: String) -> String {
        makeClaudeUserLine(uuid: uuid,
                           content: "<local-command-stdout>Context Usage\n10k/200k tokens (5%)\nSystem prompt: 2k tokens (1%)</local-command-stdout>")
    }

    private func makeClaudeQueuedCommandAttachment(uuid: String, prompt: String) -> String {
        let object: [String: Any] = [
            "type": "attachment",
            "uuid": uuid,
            "sessionId": "session",
            "timestamp": "2026-04-30T00:00:00Z",
            "attachment": [
                "type": "queued_command",
                "prompt": prompt,
                "commandMode": "prompt",
            ],
        ]
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(data: data, encoding: .utf8)!
    }

    private func waitUntil(timeout: TimeInterval = 2,
                           condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return true
            }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        return condition()
    }
}

private final class ClaudePromptRecordingCommandSender: TideyCommandSending {
    private let lock = NSLock()
    private var storage = [String]()

    func send(command: String) throws {
        lock.lock()
        storage.append(command)
        lock.unlock()
    }

    func commands() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private final class StubClaudeCommandSender: TideyCommandSending {
    private(set) var commands = [String]()

    func send(command: String) throws {
        commands.append(command)
    }
}
