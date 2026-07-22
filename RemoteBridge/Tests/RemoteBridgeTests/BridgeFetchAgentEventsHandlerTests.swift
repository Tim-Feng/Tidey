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
}
