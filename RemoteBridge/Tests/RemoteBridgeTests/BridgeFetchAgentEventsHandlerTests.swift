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
        func wireFetch(afterSeq: Int) throws -> WirePage {
            let request = BridgeRequest(id: UUID().uuidString,
                                        action: "fetch_agent_events",
                                        params: [
                                            "workspace_id": .string("workspace-after"),
                                            "session_id": .string("session-after"),
                                            "limit": .number(97),
                                            "max_bytes": .number(Double(maxBytes)),
                                            "after_seq": .number(Double(afterSeq)),
                                        ])
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

        var pages = [WirePage]()
        var union = [WireEvent]()
        var cursor = 0
        var completed = false
        for _ in 0..<(lineCount + 1) {
            let page = try wireFetch(afterSeq: cursor)
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
        XCTAssertLessThan(pages[0].events.count, 97,
                          "the byte budget really cut the first page below the count limit")
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
