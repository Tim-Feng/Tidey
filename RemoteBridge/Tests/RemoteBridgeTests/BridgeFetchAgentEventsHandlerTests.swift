import XCTest
import NIOEmbedded
@testable import RemoteBridge

// R13 B1: fetch_agent_events requests dispatched through the REAL
// WebSocketFrameHandler.handleLocalRequest — real registry monitor, real
// transcript session, real Hub. No parallel test-only flow.
final class BridgeFetchAgentEventsHandlerTests: XCTestCase {
    private func makeCodexMessageLine(role: String, content: String) -> String {
        """
        {"timestamp":"2026-04-12T12:00:00Z","type":"response_item","payload":{"type":"message","role":"\(role)","content":[{"type":"output_text","text":"\(content)"}]}}
        """
    }

    private func makeCodexTokenCountLine() -> String {
        """
        {"timestamp":"2026-04-12T12:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{}}}
        """
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        return condition()
    }

    func testHandlerRejectsSessionLocalCursorsWithoutSession() throws {
        let supportDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BridgeFetchHandlerTests-\(UUID().uuidString)", isDirectory: true)
        let paths = BridgePaths(supportDirectory: supportDirectory)
        try paths.ensureSupportDirectoriesExist(fileManager: .default)
        defer { try? FileManager.default.removeItem(at: supportDirectory) }

        let hub = AgentEventHub()
        let monitor = AgentSessionRegistryMonitor(paths: paths,
                                                  fileManager: .default,
                                                  hub: hub,
                                                  tmuxResolver: TmuxStateResolver(ttl: 60) { _, _ in "" },
                                                  parentPIDLookup: { _ in nil })
        let handler = WebSocketFrameHandler(socketClient: TideySocketClient(locator: TideySocketLocator()),
                                            eventHub: hub,
                                            workspaceEventHub: WorkspaceEventHub(),
                                            registryMonitor: monitor,
                                            observability: BridgeObservabilityCenter(),
                                            bridgePort: 0,
                                            cloudflaredManager: BridgeCloudflaredManager(binaryResolver: { nil }),
                                            ordinaryTmuxProjectionContext: OrdinaryTmuxProjectionContext())
        let channel = EmbeddedChannel(handler: handler)
        defer { _ = try? channel.finish() }
        let context = try channel.pipeline.syncOperations.context(handler: handler)
        let request = BridgeRequest(id: "workspace-cursor",
                                    action: "fetch_agent_events",
                                    params: [
                                        "workspace_id": .string("workspace"),
                                        "limit": .number(20),
                                        "before_seq": .number(100),
                                    ])

        let result = try XCTUnwrap(handler.handleLocalRequest(request, context: context))

        XCTAssertFalse(result.response.ok)
        XCTAssertEqual(result.response.error?.code, "invalid_request")
        XCTAssertEqual(result.response.error?.message,
                       "fetch_agent_events cursor requests require session_id")

        let subscribeRequest = BridgeRequest(id: "workspace-replay-cursor",
                                             action: "subscribe_agent_events",
                                             params: [
                                                "workspace_id": .string("workspace"),
                                                "since_seq": .number(100),
                                             ])
        let subscribeResult = try XCTUnwrap(
            handler.handleLocalRequest(subscribeRequest, context: context)
        )
        XCTAssertFalse(subscribeResult.response.ok)
        XCTAssertEqual(subscribeResult.response.error?.code, "invalid_request")
        XCTAssertEqual(subscribeResult.response.error?.message,
                       "subscribe_agent_events since_seq requires session_id")
    }

    func testHandlerRejectsMalformedCursorFieldsAndOutOfRangeLimits() throws {
        let supportDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BridgeFetchHandlerTests-\(UUID().uuidString)", isDirectory: true)
        let paths = BridgePaths(supportDirectory: supportDirectory)
        try paths.ensureSupportDirectoriesExist(fileManager: .default)
        defer { try? FileManager.default.removeItem(at: supportDirectory) }

        let hub = AgentEventHub()
        let monitor = AgentSessionRegistryMonitor(paths: paths,
                                                  fileManager: .default,
                                                  hub: hub,
                                                  tmuxResolver: TmuxStateResolver(ttl: 60) { _, _ in "" },
                                                  parentPIDLookup: { _ in nil })
        let handler = WebSocketFrameHandler(socketClient: TideySocketClient(locator: TideySocketLocator()),
                                            eventHub: hub,
                                            workspaceEventHub: WorkspaceEventHub(),
                                            registryMonitor: monitor,
                                            observability: BridgeObservabilityCenter(),
                                            bridgePort: 0,
                                            cloudflaredManager: BridgeCloudflaredManager(binaryResolver: { nil }),
                                            ordinaryTmuxProjectionContext: OrdinaryTmuxProjectionContext())
        let channel = EmbeddedChannel(handler: handler)
        defer { _ = try? channel.finish() }
        let context = try channel.pipeline.syncOperations.context(handler: handler)

        let cases: [(id: String, params: [String: JSONValue], message: String)] = [
            (
                "malformed-before",
                [
                    "workspace_id": .string("workspace"),
                    "limit": .number(20),
                    "before_seq": .string("oops"),
                ],
                "fetch_agent_events received an unrepresentable before_seq"
            ),
            (
                "fractional-after",
                [
                    "workspace_id": .string("workspace"),
                    "session_id": .string("session"),
                    "limit": .number(20),
                    "after_seq": .number(1.5),
                ],
                "fetch_agent_events received an unrepresentable after_seq"
            ),
            (
                "dual-raw-cursors",
                [
                    "workspace_id": .string("workspace"),
                    "session_id": .string("session"),
                    "limit": .number(20),
                    "before_seq": .string("oops"),
                    "after_seq": .number(10),
                ],
                "fetch_agent_events accepts either before_seq or after_seq, not both"
            ),
            (
                "zero-limit",
                [
                    "workspace_id": .string("workspace"),
                    "limit": .number(0),
                ],
                "fetch_agent_events limit must be between 1 and 2000"
            ),
            (
                "negative-limit",
                [
                    "workspace_id": .string("workspace"),
                    "limit": .number(-1),
                ],
                "fetch_agent_events limit must be between 1 and 2000"
            ),
            (
                "oversized-limit",
                [
                    "workspace_id": .string("workspace"),
                    "limit": .number(2_001),
                ],
                "fetch_agent_events limit must be between 1 and 2000"
            ),
        ]

        for testCase in cases {
            let request = BridgeRequest(id: testCase.id,
                                        action: "fetch_agent_events",
                                        params: testCase.params)
            let result = try XCTUnwrap(handler.handleLocalRequest(request, context: context))
            XCTAssertFalse(result.response.ok, testCase.id)
            XCTAssertEqual(result.response.error?.code, "invalid_request", testCase.id)
            XCTAssertEqual(result.response.error?.message, testCase.message, testCase.id)
        }

        let boundaryRequest = BridgeRequest(id: "maximum-limit",
                                            action: "fetch_agent_events",
                                            params: [
                                                "workspace_id": .string("workspace"),
                                                "limit": .number(2_000),
                                            ])
        let boundaryResult = try XCTUnwrap(
            handler.handleLocalRequest(boundaryRequest, context: context)
        )
        XCTAssertTrue(boundaryResult.response.ok)
    }

    func testHandlerServesRequestedAnchorDespiteDeepCache() throws {
        let supportDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BridgeFetchHandlerTests-\(UUID().uuidString)", isDirectory: true)
        let paths = BridgePaths(supportDirectory: supportDirectory)
        try paths.ensureSupportDirectoriesExist(fileManager: .default)
        defer { try? FileManager.default.removeItem(at: supportDirectory) }

        // Real codex rollout transcript: 30 old lines + a small live tail.
        let transcriptURL = supportDirectory.appendingPathComponent("rollout-session.jsonl", isDirectory: false)
        var lines = [String]()
        for index in 0..<30 {
            lines.append(makeCodexMessageLine(role: "assistant", content: "old-\(index)"))
        }
        for index in 0..<6 {
            lines.append(makeCodexMessageLine(role: "assistant", content: "line-\(index)"))
        }
        try (lines.joined(separator: "\n") + "\n").write(to: transcriptURL, atomically: true, encoding: .utf8)

        // Real registry record so the monitor spawns the REAL transcript session.
        let record = """
        {
          "version": 1,
          "vendor": "codex",
          "workspace_id": "workspace",
          "session_id": "session",
          "panel_id": "panel-1",
          "pid": \(ProcessInfo.processInfo.processIdentifier),
          "cwd": "/tmp",
          "created_at": "2026-04-12T12:00:00Z",
          "transcript_path": "\(transcriptURL.path)"
        }
        """
        try Data(record.utf8).write(to: paths.codexAgentSessionsDirectory.appendingPathComponent("codex-session.json"))

        // Small Hub bound: client A's deep paging leaves a deep cache that
        // could satisfy client B's limit without covering B's anchor.
        let hub = AgentEventHub(maxBufferedEvents: 6, maxSeenEventIDs: 100)
        let monitor = AgentSessionRegistryMonitor(paths: paths,
                                                  fileManager: .default,
                                                  hub: hub,
                                                  tmuxResolver: TmuxStateResolver(ttl: 60) { _, _ in "" },
                                                  parentPIDLookup: { _ in nil })
        try monitor.start()
        XCTAssertTrue(waitUntil {
            hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 100).events.contains { $0.text == "line-5" }
        }, "the real session must bootstrap through the registry monitor")

        let handler = WebSocketFrameHandler(socketClient: TideySocketClient(locator: TideySocketLocator()),
                                            eventHub: hub,
                                            workspaceEventHub: WorkspaceEventHub(),
                                            registryMonitor: monitor,
                                            observability: BridgeObservabilityCenter(),
                                            bridgePort: 0,
                                            cloudflaredManager: BridgeCloudflaredManager(binaryResolver: { nil }),
                                            ordinaryTmuxProjectionContext: OrdinaryTmuxProjectionContext())
        let channel = EmbeddedChannel(handler: handler)
        defer { _ = try? channel.finish() }
        let context = try channel.pipeline.syncOperations.context(handler: handler)

        struct Page {
            let texts: [String]
            let seqs: [Int]
        }
        func serverFetch(limit: Int, beforeSeq: Int) throws -> Page {
            let request = BridgeRequest(id: UUID().uuidString,
                                        action: "fetch_agent_events",
                                        params: [
                                            "workspace_id": .string("workspace"),
                                            "session_id": .string("session"),
                                            "limit": .number(Double(limit)),
                                            "before_seq": .number(Double(beforeSeq)),
                                        ])
            let result = try XCTUnwrap(handler.handleLocalRequest(request, context: context),
                                       "the handler must dispatch fetch_agent_events locally")
            XCTAssertEqual(result.response.ok, true)
            let events = try XCTUnwrap(result.response.result?["events"]?.arrayValue)
            let objects = events.compactMap(\.objectValue)
            return Page(texts: objects.compactMap { $0["text"]?.stringValue },
                        seqs: objects.compactMap { $0["seq"]?.intValue })
        }

        let boundary = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 100)
            .events.filter { ($0.text ?? "").hasPrefix("line-") }.map(\.seq).min() ?? 0

        // Client A pages deep through the REAL handler, advancing by the
        // returned page's oldest seq.
        var cursorA = boundary
        for _ in 0..<12 {
            let page = try serverFetch(limit: 4, beforeSeq: cursorA)
            guard let next = page.seqs.filter({ $0 > 0 }).min(), next < cursorA else {
                break
            }
            cursorA = next
        }

        // Precondition: client A's paging really left a DEEP stale cache
        // that does NOT cover B's anchor-adjacent range — the exact mislead
        // the handler must not fall for.
        let cachedBelowBoundary = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 100, beforeSeq: boundary).events
        XCTAssertGreaterThan(cachedBelowBoundary.count, 3,
                             "precondition: the stale cache is DEEPER than B's limit — the old hasMore gate would trust it")
        XCTAssertFalse(cachedBelowBoundary.contains { $0.text == "old-29" },
                       "precondition: the anchor-adjacent page is NOT in the stale cache, got \(cachedBelowBoundary.compactMap(\.text))")

        // Client B starts fresh at the ORIGINAL anchor with a small limit:
        // the deep cache could satisfy the limit, but the handler must serve
        // B's requested anchor-adjacent page.
        let pageB = try serverFetch(limit: 3, beforeSeq: boundary)
        for expected in ["old-29", "old-28", "old-27"] {
            XCTAssertTrue(pageB.texts.contains(expected),
                          "the requested anchor-adjacent page must be served (\(expected)), got \(pageB.texts)")
        }

        // B pages onward through the same handler: union contiguous, no
        // gap, no duplicate.
        var union = pageB.texts
        var cursorB = pageB.seqs.filter { $0 > 0 }.min() ?? boundary
        for _ in 0..<30 {
            let page = try serverFetch(limit: 3, beforeSeq: cursorB)
            guard page.texts.isEmpty == false,
                  let next = page.seqs.filter({ $0 > 0 }).min(), next < cursorB else {
                break
            }
            union.append(contentsOf: page.texts)
            cursorB = next
        }
        let expectedUnion = (0..<30).map { "old-\($0)" }
        XCTAssertEqual(Set(union), Set(expectedUnion), "no gap in B's union, got \(union)")
        XCTAssertEqual(union.count, expectedUnion.count, "no duplicate in B's union, got \(union)")
    }

    // B22 RED: the production iOS older-history request uses the wire
    // oldest_seq as its next before_seq and stops on has_more == false.
    // Codex rollouts contain many legal eventless records, so one 500-raw-
    // record backfill can yield far fewer than 500 visible products while
    // substantial raw history still remains below that page. The handler
    // must preserve raw-frontier authority until real BOF, and the
    // synthetic session_started seq 0 must never become a nonterminal
    // paging cursor.
    func testHandlerBeforeCursorCodexHistoryUsesRawFrontierUntilBOF() throws {
        let supportDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BridgeFetchHandlerTests-\(UUID().uuidString)", isDirectory: true)
        let paths = BridgePaths(supportDirectory: supportDirectory)
        try paths.ensureSupportDirectoriesExist(fileManager: .default)
        defer { try? FileManager.default.removeItem(at: supportDirectory) }

        // Realistic low semantic density: exactly 1,800 raw records, but
        // only every third record produces a visible assistant event.
        // The other 1,200 token_count records are legal eventless progress,
        // not malformed input and not semantic-trust poison.
        let transcriptURL = supportDirectory.appendingPathComponent("rollout-low-density.jsonl",
                                                                    isDirectory: false)
        var lines = [String]()
        var expectedVisibleIDs = [String]()
        var expectedVisibleTexts = [String]()
        var runningOffset = 0
        for rawIndex in 0..<1_800 {
            let line: String
            if rawIndex.isMultiple(of: 3) {
                let visibleIndex = rawIndex / 3
                let text = String(format: "history-%04d", visibleIndex)
                let seq = transcriptEventSequence(lineOffset: runningOffset, ordinal: 0)
                line = makeCodexMessageLine(role: "assistant", content: text)
                expectedVisibleIDs.append("assistant:session-before:\(seq)")
                expectedVisibleTexts.append(text)
            } else {
                line = makeCodexTokenCountLine()
            }
            lines.append(line)
            runningOffset += line.utf8.count + 1
        }
        XCTAssertEqual(expectedVisibleIDs.count, 600)
        XCTAssertEqual(lines.count - expectedVisibleIDs.count, 1_200)
        try (lines.joined(separator: "\n") + "\n")
            .write(to: transcriptURL, atomically: true, encoding: .utf8)
        let fixtureBytes = try XCTUnwrap(
            (FileManager.default.attributesOfItem(atPath: transcriptURL.path)[.size] as? NSNumber)?
                .intValue)
        XCTAssertGreaterThan(fixtureBytes, 64 * 1024,
                             "precondition: history crosses the reader chunk boundary")

        // created_at is deliberately newer than the raw event timestamps:
        // the handler's timestamp merge can place session_started(seq: 0)
        // after historical rows on the wire, matching the live failure.
        let record = """
        {
          "version": 1,
          "vendor": "codex",
          "workspace_id": "workspace-before",
          "session_id": "session-before",
          "panel_id": "panel-before",
          "pid": \(ProcessInfo.processInfo.processIdentifier),
          "cwd": "/tmp",
          "created_at": "2026-07-26T12:00:00Z",
          "transcript_path": "\(transcriptURL.path)"
        }
        """
        try Data(record.utf8).write(
            to: paths.codexAgentSessionsDirectory.appendingPathComponent("codex-session-before.json"))

        let hub = AgentEventHub()
        let monitor = AgentSessionRegistryMonitor(paths: paths,
                                                  fileManager: .default,
                                                  hub: hub,
                                                  tmuxResolver: TmuxStateResolver(ttl: 60) { _, _ in "" },
                                                  parentPIDLookup: { _ in nil })
        try monitor.start()
        XCTAssertTrue(waitUntil {
            hub.fetch(workspaceID: "workspace-before",
                      sessionID: "session-before",
                      limit: 10).events.contains { $0.text == "history-0599" }
        }, "the real Codex session must bootstrap through the registry monitor")

        let handler = WebSocketFrameHandler(socketClient: TideySocketClient(locator: TideySocketLocator()),
                                            eventHub: hub,
                                            workspaceEventHub: WorkspaceEventHub(),
                                            registryMonitor: monitor,
                                            observability: BridgeObservabilityCenter(),
                                            bridgePort: 0,
                                            cloudflaredManager: BridgeCloudflaredManager(binaryResolver: { nil }),
                                            ordinaryTmuxProjectionContext: OrdinaryTmuxProjectionContext())
        let channel = EmbeddedChannel(handler: handler)
        defer { _ = try? channel.finish() }
        let context = try channel.pipeline.syncOperations.context(handler: handler)

        struct WireEvent {
            let eventID: String
            let seq: Int
            let type: String
            let text: String?
        }
        struct WirePage {
            let events: [WireEvent]
            let oldestSeq: Int
            let newestSeq: Int
            let hasMore: Bool
        }
        func wireFetch(limit: Int, maxBytes: Int, beforeSeq: Int?) throws -> WirePage {
            var params: [String: JSONValue] = [
                "workspace_id": .string("workspace-before"),
                "session_id": .string("session-before"),
                "limit": .number(Double(limit)),
                "max_bytes": .number(Double(maxBytes)),
            ]
            if let beforeSeq {
                params["before_seq"] = .number(Double(beforeSeq))
            }
            let request = BridgeRequest(id: UUID().uuidString,
                                        action: "fetch_agent_events",
                                        params: params)
            let result = try XCTUnwrap(handler.handleLocalRequest(request, context: context),
                                       "the handler must dispatch fetch_agent_events locally")
            XCTAssertTrue(result.response.ok)
            XCTAssertNil(result.response.error)
            let values = try XCTUnwrap(result.response.result?["events"]?.arrayValue)
            let events: [WireEvent] = try values.map { value in
                let object = try XCTUnwrap(value.objectValue)
                return WireEvent(eventID: try XCTUnwrap(object["event_id"]?.stringValue),
                                 seq: try XCTUnwrap(object["seq"]?.intValue),
                                 type: try XCTUnwrap(object["type"]?.stringValue),
                                 text: object["text"]?.stringValue)
            }
            return WirePage(events: events,
                            oldestSeq: try XCTUnwrap(result.response.result?["oldest_seq"]?.intValue),
                            newestSeq: try XCTUnwrap(result.response.result?["newest_seq"]?.intValue),
                            hasMore: try XCTUnwrap(result.response.result?["has_more"]?.boolValue))
        }

        // Exact production iOS request shapes.
        let bootstrap = try wireFetch(limit: 24, maxBytes: 80 * 1024, beforeSeq: nil)
        let bootstrapVisible = bootstrap.events.filter { $0.type == "assistant_message" }
        XCTAssertEqual(bootstrapVisible.map(\.eventID), Array(expectedVisibleIDs.suffix(24)))
        XCTAssertEqual(bootstrapVisible.compactMap(\.text), Array(expectedVisibleTexts.suffix(24)))
        XCTAssertTrue(bootstrap.hasMore)
        XCTAssertGreaterThan(bootstrap.oldestSeq, 0)

        var visibleEvents = bootstrapVisible
        var seenVisibleIDs = Set(bootstrapVisible.map(\.eventID))
        var cursor = bootstrap.oldestSeq
        var didReachBOF = false
        var olderPageCount = 0
        var terminalPage: WirePage?
        for _ in 0..<(expectedVisibleIDs.count + 2) {
            let requestCursor = cursor
            let page = try wireFetch(limit: 500,
                                     maxBytes: 160 * 1024,
                                     beforeSeq: requestCursor)
            olderPageCount += 1
            let pageVisible = page.events.filter { $0.type == "assistant_message" }
            if olderPageCount == 1 {
                XCTAssertLessThan(pageVisible.count, 500,
                                  "precondition: raw density leaves the visible page below the count limit")
                XCTAssertTrue(page.hasMore,
                              "raw frontier, not visible count, keeps the first sparse page nonterminal")
            }
            XCTAssertTrue(pageVisible.allSatisfy { $0.seq < requestCursor },
                          "every older-history product lies below its wire cursor")
            for event in pageVisible {
                XCTAssertTrue(seenVisibleIDs.insert(event.eventID).inserted,
                              "visible event \(event.eventID) must appear exactly once")
                visibleEvents.append(event)
            }

            if page.hasMore {
                XCTAssertGreaterThan(page.oldestSeq, 0,
                                     "session_started seq 0 is not a nonterminal before cursor")
                XCTAssertLessThan(page.oldestSeq, requestCursor,
                                  "each nonterminal wire cursor strictly retreats")
                cursor = page.oldestSeq
            } else {
                terminalPage = page
                didReachBOF = true
                break
            }
        }

        XCTAssertTrue(didReachBOF, "paging terminates only when the raw source reaches BOF")
        XCTAssertEqual(terminalPage?.oldestSeq, transcriptSessionStartedSequence,
                       "seq 0 is exposed as the cursor bound only on the proven BOF page")
        XCTAssertTrue(terminalPage?.events.contains {
            $0.type == "session_started" && $0.seq == transcriptSessionStartedSequence
        } == true, "the terminal page retains the synthetic session-start marker")
        XCTAssertGreaterThan(olderPageCount, 1,
                             "the low-density fixture spans multiple iOS older-history pages")
        let orderedVisible = visibleEvents.sorted {
            ($0.seq, $0.eventID) < ($1.seq, $1.eventID)
        }
        XCTAssertEqual(orderedVisible.count, 600)
        XCTAssertEqual(orderedVisible.map(\.eventID), expectedVisibleIDs,
                       "wire paging returns the exact 600 visible Codex identities")
        XCTAssertEqual(orderedVisible.compactMap(\.text), expectedVisibleTexts,
                       "wire paging returns every visible history row without a gap")
    }

    // B22 RED: raw-frontier progress can cross a page made entirely of blank
    // lines. Such a page has no JSONL records and therefore no public events,
    // but it is not BOF. The server must continue the same source-owned walk
    // until it reaches an older public event or real BOF; returning has_more
    // with the unchanged wire cursor would make the iOS client retry forever.
    func testHandlerBeforeCursorCodexHistoryCrossesBlankRawGapWithoutStalling() throws {
        let supportDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BridgeFetchHandlerTests-\(UUID().uuidString)", isDirectory: true)
        let paths = BridgePaths(supportDirectory: supportDirectory)
        try paths.ensureSupportDirectoriesExist(fileManager: .default)
        defer { try? FileManager.default.removeItem(at: supportDirectory) }

        // Oldest -> newest:
        // 1. one public event whose >64 KiB raw line makes the blank page's
        //    backward scan stop inside this partial line (not at byte zero);
        // 2. 600 truly blank lines, which are raw progress but no records;
        // 3. exactly 500 recent public events, which form the bootstrap tail.
        let transcriptURL = supportDirectory.appendingPathComponent("rollout-blank-gap.jsonl",
                                                                    isDirectory: false)
        let beforeGapText = "before-gap-" + String(repeating: "x", count: 70 * 1024)
        let recentTexts = (0..<500).map { String(format: "recent-%04d", $0) }
        let lines = [makeCodexMessageLine(role: "assistant", content: beforeGapText)]
            + Array(repeating: "", count: 600)
            + recentTexts.map { makeCodexMessageLine(role: "assistant", content: $0) }
        try (lines.joined(separator: "\n") + "\n")
            .write(to: transcriptURL, atomically: true, encoding: .utf8)
        let fixtureBytes = try XCTUnwrap(
            (FileManager.default.attributesOfItem(atPath: transcriptURL.path)[.size] as? NSNumber)?
                .intValue)
        XCTAssertGreaterThan(fixtureBytes, 2 * 64 * 1024,
                             "precondition: the fixture crosses two reader chunks")

        let record = """
        {
          "version": 1,
          "vendor": "codex",
          "workspace_id": "workspace-blank-gap",
          "session_id": "session-blank-gap",
          "panel_id": "panel-blank-gap",
          "pid": \(ProcessInfo.processInfo.processIdentifier),
          "cwd": "/tmp",
          "created_at": "2026-07-26T12:00:00Z",
          "transcript_path": "\(transcriptURL.path)"
        }
        """
        try Data(record.utf8).write(
            to: paths.codexAgentSessionsDirectory.appendingPathComponent("codex-session-blank-gap.json"))

        let hub = AgentEventHub()
        let monitor = AgentSessionRegistryMonitor(paths: paths,
                                                  fileManager: .default,
                                                  hub: hub,
                                                  tmuxResolver: TmuxStateResolver(ttl: 60) { _, _ in "" },
                                                  parentPIDLookup: { _ in nil })
        try monitor.start()
        XCTAssertTrue(waitUntil {
            hub.fetch(workspaceID: "workspace-blank-gap",
                      sessionID: "session-blank-gap",
                      limit: 10).events.contains { $0.text == "recent-0499" }
        }, "the real Codex session must bootstrap through the registry monitor")

        let handler = WebSocketFrameHandler(socketClient: TideySocketClient(locator: TideySocketLocator()),
                                            eventHub: hub,
                                            workspaceEventHub: WorkspaceEventHub(),
                                            registryMonitor: monitor,
                                            observability: BridgeObservabilityCenter(),
                                            bridgePort: 0,
                                            cloudflaredManager: BridgeCloudflaredManager(binaryResolver: { nil }),
                                            ordinaryTmuxProjectionContext: OrdinaryTmuxProjectionContext())
        let channel = EmbeddedChannel(handler: handler)
        defer { _ = try? channel.finish() }
        let context = try channel.pipeline.syncOperations.context(handler: handler)

        struct WireEvent {
            let seq: Int
            let type: String
            let text: String?
        }
        struct WirePage {
            let events: [WireEvent]
            let oldestSeq: Int
            let hasMore: Bool
        }
        func wireFetch(limit: Int, maxBytes: Int, beforeSeq: Int?) throws -> WirePage {
            var params: [String: JSONValue] = [
                "workspace_id": .string("workspace-blank-gap"),
                "session_id": .string("session-blank-gap"),
                "limit": .number(Double(limit)),
                "max_bytes": .number(Double(maxBytes)),
            ]
            if let beforeSeq {
                params["before_seq"] = .number(Double(beforeSeq))
            }
            let request = BridgeRequest(id: UUID().uuidString,
                                        action: "fetch_agent_events",
                                        params: params)
            let result = try XCTUnwrap(handler.handleLocalRequest(request, context: context))
            XCTAssertTrue(result.response.ok)
            XCTAssertNil(result.response.error)
            let values = try XCTUnwrap(result.response.result?["events"]?.arrayValue)
            let events: [WireEvent] = try values.map { value in
                let object = try XCTUnwrap(value.objectValue)
                return WireEvent(seq: try XCTUnwrap(object["seq"]?.intValue),
                                 type: try XCTUnwrap(object["type"]?.stringValue),
                                 text: object["text"]?.stringValue)
            }
            return WirePage(events: events,
                            oldestSeq: try XCTUnwrap(result.response.result?["oldest_seq"]?.intValue),
                            hasMore: try XCTUnwrap(result.response.result?["has_more"]?.boolValue))
        }

        let bootstrap = try wireFetch(limit: 24, maxBytes: 80 * 1024, beforeSeq: nil)
        XCTAssertEqual(bootstrap.events
            .filter { $0.type == "assistant_message" }
            .compactMap(\.text),
            Array(recentTexts.suffix(24)))
        XCTAssertTrue(bootstrap.hasMore)
        XCTAssertGreaterThan(bootstrap.oldestSeq, 0)

        // Page one consumes the 476 recent events below the bootstrap cursor.
        // Its next wire cursor sits immediately above the blank raw gap.
        let pageBeforeGap = try wireFetch(limit: 500,
                                          maxBytes: 160 * 1024,
                                          beforeSeq: bootstrap.oldestSeq)
        XCTAssertEqual(pageBeforeGap.events
            .filter { $0.type == "assistant_message" }
            .compactMap(\.text),
            Array(recentTexts.prefix(476)))
        XCTAssertTrue(pageBeforeGap.hasMore)
        XCTAssertGreaterThan(pageBeforeGap.oldestSeq, 0)
        XCTAssertLessThan(pageBeforeGap.oldestSeq, bootstrap.oldestSeq)

        let gapCursor = pageBeforeGap.oldestSeq
        let pageAcrossGap = try wireFetch(limit: 500,
                                          maxBytes: 160 * 1024,
                                          beforeSeq: gapCursor)
        if pageAcrossGap.hasMore, pageAcrossGap.oldestSeq >= gapCursor {
            XCTFail("same-cursor stall across blank raw page: requested \(gapCursor), "
                + "received oldest_seq \(pageAcrossGap.oldestSeq) with has_more=true")
            return
        }

        XCTAssertFalse(pageAcrossGap.hasMore,
                       "the same request crosses the blank page and proves real BOF")
        XCTAssertEqual(pageAcrossGap.oldestSeq, transcriptSessionStartedSequence)
        XCTAssertTrue(pageAcrossGap.events.contains {
            $0.type == "assistant_message" && $0.text == beforeGapText
        }, "the public event below the blank raw gap is not skipped")
        XCTAssertTrue(pageAcrossGap.events.contains {
            $0.type == "session_started" && $0.seq == transcriptSessionStartedSequence
        }, "the synthetic start marker appears only on the terminal BOF page")
    }

    private func makeClaudeUserLine(uuid: String, sessionID: String, content: String) -> String {
        let object: [String: Any] = [
            "type": "user",
            "uuid": uuid,
            "sessionId": sessionID,
            "version": "2.0.0",
            "timestamp": "2026-04-30T00:00:00Z",
            "message": [
                "role": "user",
                "content": content,
            ],
        ]
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(data: data, encoding: .utf8)!
    }

    // B20: a wire client paging after-cursor with a byte budget must
    // reassemble the EXACT contiguous deep history through the real
    // handler — real registry record, real monitor, real Claude session,
    // real flow; nothing below handleLocalRequest is called directly. The
    // fixture exceeds the bootstrap window AND 64 KiB, so the oldest rows
    // are only reachable via the request-owned raw walk, and the byte
    // budget forces the first page below the count limit while raw page
    // boundaries sit inside the walk.
    func testHandlerAfterCursorDeepHistoryUnionContiguous() throws {
        let supportDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BridgeFetchHandlerTests-\(UUID().uuidString)", isDirectory: true)
        let paths = BridgePaths(supportDirectory: supportDirectory)
        try paths.ensureSupportDirectoriesExist(fileManager: .default)
        defer { try? FileManager.default.removeItem(at: supportDirectory) }

        let lineCount = transcriptBootstrapLineLimit + 37
        let ids = (0..<lineCount).map { String(format: "history-%04d", $0) }
        let contents = ids.map { "\($0)|" + String(repeating: "x", count: 192) }
        let transcriptURL = supportDirectory.appendingPathComponent("claude-session.jsonl", isDirectory: false)
        let lines = (0..<lineCount).map {
            makeClaudeUserLine(uuid: ids[$0], sessionID: "session-after", content: contents[$0])
        }
        try (lines.joined(separator: "\n") + "\n").write(to: transcriptURL, atomically: true, encoding: .utf8)
        let fixtureBytes = try XCTUnwrap(
            (FileManager.default.attributesOfItem(atPath: transcriptURL.path)[.size] as? NSNumber)?.intValue)
        XCTAssertGreaterThan(fixtureBytes, 64 * 1024,
                             "precondition: the fixture crosses the 64 KiB raw page size")

        let record = """
        {
          "version": 1,
          "vendor": "claude",
          "workspace_id": "workspace-after",
          "session_id": "session-after",
          "panel_id": "panel-after",
          "pid": \(ProcessInfo.processInfo.processIdentifier),
          "cwd": "/tmp",
          "created_at": "2026-04-12T12:00:00Z",
          "transcript_path": "\(transcriptURL.path)"
        }
        """
        try Data(record.utf8).write(to: paths.claudeAgentSessionsDirectory.appendingPathComponent("claude-session.json"))

        let hub = AgentEventHub(maxBufferedEvents: 64, maxSeenEventIDs: 4000)
        let monitor = AgentSessionRegistryMonitor(paths: paths,
                                                  fileManager: .default,
                                                  hub: hub,
                                                  tmuxResolver: TmuxStateResolver(ttl: 60) { _, _ in "" },
                                                  parentPIDLookup: { _ in nil })
        try monitor.start()
        XCTAssertTrue(waitUntil {
            hub.fetch(workspaceID: "workspace-after", sessionID: "session-after", limit: 100)
                .events.contains { $0.text?.hasPrefix("\(ids[lineCount - 1])|") == true }
        }, "the real Claude session must bootstrap through the registry monitor")

        // The oldest rows are only reachable by the raw walk.
        let retainedBefore = hub.fetch(workspaceID: "workspace-after", sessionID: "session-after", limit: 4000).events
        XCTAssertTrue(retainedBefore.contains { $0.text?.hasPrefix("\(ids[lineCount - 1])|") == true })
        XCTAssertFalse(retainedBefore.contains { $0.text?.hasPrefix("history-0000|") == true },
                       "precondition: the oldest row is NOT in the retained cache")

        // Byte budget from a REAL production event's encoded size.
        let sample = try XCTUnwrap(retainedBefore.first { $0.text?.hasPrefix("history-") == true })
        let sampleSize = try JSONEncoder().encode(sample).count
        let maxBytes = sampleSize * 31
        XCTAssertLessThan(sampleSize, maxBytes)

        let handler = WebSocketFrameHandler(socketClient: TideySocketClient(locator: TideySocketLocator()),
                                            eventHub: hub,
                                            workspaceEventHub: WorkspaceEventHub(),
                                            registryMonitor: monitor,
                                            observability: BridgeObservabilityCenter(),
                                            bridgePort: 0,
                                            cloudflaredManager: BridgeCloudflaredManager(binaryResolver: { nil }),
                                            ordinaryTmuxProjectionContext: OrdinaryTmuxProjectionContext())
        let channel = EmbeddedChannel(handler: handler)
        defer { _ = try? channel.finish() }
        let context = try channel.pipeline.syncOperations.context(handler: handler)

        struct WireEvent {
            let eventID: String
            let seq: Int
            let type: String
            let vendor: String
            let workspaceID: String
            let sessionID: String
            let text: String
        }
        struct WirePage {
            let events: [WireEvent]
            let oldestSeq: Int
            let newestSeq: Int
            let hasMore: Bool
        }
        func wireFetch(afterSeq: Int, maxBytes: Int?) throws -> WirePage {
            var params: [String: JSONValue] = [
                "workspace_id": .string("workspace-after"),
                "session_id": .string("session-after"),
                "limit": .number(97),
                "after_seq": .number(Double(afterSeq)),
            ]
            if let maxBytes {
                params["max_bytes"] = .number(Double(maxBytes))
            }
            let request = BridgeRequest(id: UUID().uuidString,
                                        action: "fetch_agent_events",
                                        params: params)
            let result = try XCTUnwrap(handler.handleLocalRequest(request, context: context),
                                       "the handler must dispatch fetch_agent_events locally")
            XCTAssertEqual(result.response.ok, true)
            XCTAssertNil(result.response.error)
            let eventValues = try XCTUnwrap(result.response.result?["events"]?.arrayValue)
            // NO compactMap over malformed wire events: unwrap every field.
            let events: [WireEvent] = try eventValues.map { value in
                let object = try XCTUnwrap(value.objectValue, "every wire event is an object")
                let metadata = object["metadata"]?.objectValue
                XCTAssertNil(metadata?["tidey_truncated"],
                             "no event is replaced by a tidey_truncated placeholder")
                return WireEvent(eventID: try XCTUnwrap(object["event_id"]?.stringValue),
                                 seq: try XCTUnwrap(object["seq"]?.intValue),
                                 type: try XCTUnwrap(object["type"]?.stringValue),
                                 vendor: try XCTUnwrap(object["vendor"]?.stringValue),
                                 workspaceID: try XCTUnwrap(object["workspace_id"]?.stringValue),
                                 sessionID: try XCTUnwrap(object["session_id"]?.stringValue),
                                 text: try XCTUnwrap(object["text"]?.stringValue))
            }
            return WirePage(events: events,
                            oldestSeq: try XCTUnwrap(result.response.result?["oldest_seq"]?.intValue),
                            newestSeq: try XCTUnwrap(result.response.result?["newest_seq"]?.intValue),
                            hasMore: try XCTUnwrap(result.response.result?["has_more"]?.boolValue))
        }

        // CONTROL request — same handler/session/fixture, NO max_bytes: it
        // pins that a count-limited first page holds exactly 97 rows, so
        // the budget run's smaller first page below is attributable to the
        // byte budget and nothing else (raw page / history boundaries
        // included, since the control crosses the very same ones).
        let control = try wireFetch(afterSeq: 0, maxBytes: nil)
        XCTAssertEqual(control.events.count, 97, "the control page is exactly the count limit")
        XCTAssertTrue(control.hasMore)
        XCTAssertEqual(control.events.map(\.eventID),
                       (0..<97).map { String(format: "history-%04d:user-text:0", $0) },
                       "the control page is exactly the first 97 fixture identities")
        XCTAssertEqual(control.oldestSeq, control.events.first?.seq)
        XCTAssertEqual(control.newestSeq, control.events.last?.seq)

        var pages = [WirePage]()
        var union = [WireEvent]()
        var cursor = 0
        var completed = false
        for _ in 0..<(lineCount + 1) {
            let page = try wireFetch(afterSeq: cursor, maxBytes: maxBytes)
            XCTAssertFalse(page.events.isEmpty, "every page carries events")
            XCTAssertLessThanOrEqual(page.events.count, 97)
            for event in page.events {
                XCTAssertGreaterThan(event.seq, cursor, "every seq lies above the request cursor")
                XCTAssertEqual(event.vendor, "claude")
                XCTAssertEqual(event.type, "user_message")
                XCTAssertEqual(event.workspaceID, "workspace-after")
                XCTAssertEqual(event.sessionID, "session-after")
            }
            let seqs = page.events.map(\.seq)
            XCTAssertEqual(seqs, seqs.sorted(), "in-page sequences strictly increase")
            XCTAssertEqual(Set(seqs).count, seqs.count)
            XCTAssertEqual(Set(page.events.map(\.eventID)).count, page.events.count,
                           "in-page eventIDs are unique")
            XCTAssertEqual(page.oldestSeq, page.events.first?.seq, "wire oldest_seq is the first seq")
            XCTAssertEqual(page.newestSeq, page.events.last?.seq, "wire newest_seq is the last seq")
            pages.append(page)
            union.append(contentsOf: page.events)
            if page.hasMore {
                XCTAssertGreaterThan(page.newestSeq, cursor,
                                     "the next cursor strictly advances past this request's cursor")
                cursor = page.newestSeq
            } else {
                completed = true
                break
            }
        }
        XCTAssertTrue(completed, "the paging loop ends ONLY on has_more == false")

        // Final union: exact, ordered, complete.
        XCTAssertEqual(union.map(\.eventID),
                       (0..<lineCount).map { String(format: "history-%04d:user-text:0", $0) },
                       "the union's eventIDs are exactly the ordered fixture identities")
        XCTAssertEqual(union.map { String($0.text.split(separator: "|")[0]) }, ids,
                       "the union's texts are exactly history-0000...history-\(String(format: "%04d", lineCount - 1)) in order")
        XCTAssertEqual(union.count, lineCount)
        let allSeqs = union.map(\.seq)
        XCTAssertEqual(allSeqs, allSeqs.sorted())
        XCTAssertEqual(Set(allSeqs).count, allSeqs.count, "global sequences strictly increase, unique")
        XCTAssertEqual(Set(union.map(\.eventID)).count, lineCount)
        XCTAssertEqual(union.first.map { String($0.text.split(separator: "|")[0]) }, "history-0000")
        XCTAssertEqual(union.last.map { String($0.text.split(separator: "|")[0]) },
                       String(format: "history-%04d", lineCount - 1))
        XCTAssertGreaterThan(pages.count, 1, "the deep history spans multiple wire pages")
        // Direct byte-budget proof against the control: the SAME request
        // shape without max_bytes served exactly 97 rows, so the smaller
        // budget first page can only come from the byte budget.
        let budgetFirst = try XCTUnwrap(pages.first)
        XCTAssertLessThan(budgetFirst.events.count, control.events.count,
                          "the byte budget really cut the first page below the 97-row control")
        XCTAssertEqual(budgetFirst.events.map(\.eventID),
                       Array(control.events.map(\.eventID).prefix(budgetFirst.events.count)),
                       "the budget first page is EXACTLY the control page's prefix")
        XCTAssertTrue(budgetFirst.hasMore)
        XCTAssertFalse(pages.last?.hasMore ?? true)

        // The raw walk stays request-owned: the shared retained cache is
        // still unpolluted by the oldest row.
        XCTAssertFalse(hub.fetch(workspaceID: "workspace-after", sessionID: "session-after", limit: 4000)
                        .events.contains { $0.text?.hasPrefix("history-0000|") == true },
                       "the request-owned walk never populates the shared historical window")
    }

    // Server-level guard for the empty after-page cursor bound: a pending
    // approval far above the cursor must ride the response WITHOUT advancing
    // newest_seq past events the client has never seen.
    func testEmptyAfterPageWithHighPendingApprovalKeepsCursorBound() throws {
        let supportDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BridgeFetchHandlerTests-\(UUID().uuidString)", isDirectory: true)
        let paths = BridgePaths(supportDirectory: supportDirectory)
        try paths.ensureSupportDirectoriesExist(fileManager: .default)
        defer { try? FileManager.default.removeItem(at: supportDirectory) }

        let hub = AgentEventHub(maxBufferedEvents: 100, maxSeenEventIDs: 100)
        let monitor = AgentSessionRegistryMonitor(paths: paths,
                                                  fileManager: .default,
                                                  hub: hub,
                                                  tmuxResolver: TmuxStateResolver(ttl: 60) { _, _ in "" },
                                                  parentPIDLookup: { _ in nil })
        try monitor.start()

        let pendingApproval = AgentEvent(eventID: "prompt-100",
                                         seq: 100,
                                         vendor: "codex",
                                         workspaceID: "workspace",
                                         sessionID: "session",
                                         timestamp: "2026-07-22T12:00:00.000Z",
                                         type: .interactivePrompt,
                                         role: nil,
                                         text: "Approve?",
                                         name: nil,
                                         input: nil,
                                         output: nil,
                                         toolCallID: nil,
                                         metadata: ["submit_state": "pending"],
                                         payload: nil)
        let handler = WebSocketFrameHandler(socketClient: TideySocketClient(locator: TideySocketLocator()),
                                            eventHub: hub,
                                            workspaceEventHub: WorkspaceEventHub(),
                                            registryMonitor: monitor,
                                            codexApprovalSubmitter: StubPendingApprovalProvider(events: [pendingApproval]),
                                            observability: BridgeObservabilityCenter(),
                                            bridgePort: 0,
                                            cloudflaredManager: BridgeCloudflaredManager(binaryResolver: { nil }),
                                            ordinaryTmuxProjectionContext: OrdinaryTmuxProjectionContext())
        let channel = EmbeddedChannel(handler: handler)
        defer { _ = try? channel.finish() }
        let context = try channel.pipeline.syncOperations.context(handler: handler)

        let request = BridgeRequest(id: UUID().uuidString,
                                    action: "fetch_agent_events",
                                    params: [
                                        "workspace_id": .string("workspace"),
                                        "session_id": .string("session"),
                                        "limit": .number(50),
                                        "after_seq": .number(14),
                                    ])
        let result = try XCTUnwrap(handler.handleLocalRequest(request, context: context))
        XCTAssertEqual(result.response.ok, true)
        let events = try XCTUnwrap(result.response.result?["events"]?.arrayValue)
        XCTAssertEqual(events.compactMap { $0.objectValue?["event_id"]?.stringValue }, ["prompt-100"],
                       "the pending approval snapshot still rides the empty page")
        XCTAssertEqual(result.response.result?["newest_seq"]?.intValue, 14,
                       "newest_seq must stay at the after cursor, not jump to the pending approval seq")
    }
}

private final class StubPendingApprovalProvider: CodexAppServerApprovalPromptProviding {
    let events: [AgentEvent]
    init(events: [AgentEvent]) {
        self.events = events
    }

    func pendingApprovalPromptEvents(workspaceID: String, sessionID: String?) -> [AgentEvent] {
        events
    }

    func submitApproval(promptID: String, targetIndex: Int) throws -> AgentEvent {
        throw BridgeInternalError.invalidRequest("unexpected submit in test")
    }

    func submitApproval(promptID: String,
                        targetIndex: Int,
                        workspaceID: String,
                        panelID: String,
                        sessionID: String?) throws -> AgentEvent {
        throw BridgeInternalError.invalidRequest("unexpected submit in test")
    }

    func submitApproval(promptID: String,
                        targetIndex: Int,
                        clientRequestID: String?,
                        lifecycleToken: String?,
                        workspaceID: String,
                        panelID: String,
                        sessionID: String?) throws -> AgentEvent {
        throw BridgeInternalError.invalidRequest("unexpected submit in test")
    }
}
