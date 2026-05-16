import XCTest
@testable import RemoteBridge

final class CodexStatusSnapshotReaderTests: XCTestCase {
    func testReadsLatestStatusFieldsFromRolloutTail() throws {
        let url = temporaryRolloutURL()
        try """
        {"timestamp":"2026-05-15T09:59:00.000Z","type":"session_meta","payload":{"id":"019d70fe-fd27-7a12-a3f7-9c89ae5048b6","cwd":"/Users/timfeng","cli_version":"0.125.0"}}
        {"timestamp":"2026-05-15T10:00:00.000Z","type":"turn_context","payload":{"cwd":"/Users/timfeng/GitHub/Tidey","approval_policy":"on-request","sandbox_policy":{"type":"workspace-write"},"model":"gpt-5.5","collaboration_mode":{"settings":{"reasoning_effort":"xhigh","summary":"auto"}}}}
        {"timestamp":"2026-05-15T10:01:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1,"cached_input_tokens":0,"output_tokens":1,"reasoning_output_tokens":0,"total_tokens":2},"last_token_usage":{"input_tokens":50000,"cached_input_tokens":0,"output_tokens":1000,"reasoning_output_tokens":0,"total_tokens":51000},"model_context_window":100000},"rate_limits":{"primary":{"used_percent":1.0,"window_minutes":300,"resets_at":1770000000},"secondary":{"used_percent":16.2,"window_minutes":10080,"resets_at":1770500000}}}}
        {"timestamp":"2026-05-15T10:02:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1,"cached_input_tokens":0,"output_tokens":1,"reasoning_output_tokens":0,"total_tokens":2},"last_token_usage":{"input_tokens":63000,"cached_input_tokens":12000,"output_tokens":2000,"reasoning_output_tokens":0,"total_tokens":65000},"model_context_window":100000},"rate_limits":{"primary":{"used_percent":1.4,"window_minutes":300,"resets_at":1770000000},"secondary":{"used_percent":15.9,"window_minutes":10080,"resets_at":1770500000}}}}
        """.appending("\n").write(to: url, atomically: true, encoding: .utf8)

        let snapshot = try CodexStatusSnapshotReader().read(transcriptPath: url.path)

        XCTAssertEqual(snapshot.timestamp, "2026-05-15T10:02:00.000Z")
        XCTAssertEqual(snapshot.sessionID, "019d70fe-fd27-7a12-a3f7-9c89ae5048b6")
        XCTAssertEqual(snapshot.model, "gpt-5.5")
        XCTAssertEqual(snapshot.reasoningEffort, "xhigh")
        XCTAssertEqual(snapshot.summaryMode, "auto")
        XCTAssertEqual(snapshot.cwd, "/Users/timfeng/GitHub/Tidey")
        XCTAssertEqual(snapshot.approvalPolicy, "on-request")
        XCTAssertEqual(snapshot.sandboxPolicy, "workspace-write")
        XCTAssertEqual(snapshot.tokensInContext, 65_000)
        XCTAssertEqual(snapshot.contextWindow, 100_000)
        XCTAssertEqual(snapshot.percentRemaining, 40)
        XCTAssertEqual(snapshot.primaryRateLimit?.percentLeft, 99)
        XCTAssertEqual(snapshot.secondaryRateLimit?.percentLeft, 84)
        XCTAssertTrue(snapshot.markdownSummary.contains("### Codex Status"))
        XCTAssertTrue(snapshot.markdownSummary.contains("Model: `gpt-5.5 (reasoning xhigh, summaries auto)`"))
        XCTAssertTrue(snapshot.markdownSummary.contains("Permissions: `workspace-write · on-request`"))
        XCTAssertTrue(snapshot.markdownSummary.contains("Context window: `■■■■■■■■■■■■□□□□□□□□ 60% used · 40% left`"))
        XCTAssertTrue(snapshot.markdownSummary.contains("Tokens: `65K / 100K`"))
        XCTAssertTrue(snapshot.markdownSummary.contains("5h limit: `□□□□□□□□□□□□□□□□□□□□ 99% left"))
        XCTAssertTrue(snapshot.markdownSummary.contains("Weekly limit: `■■■□□□□□□□□□□□□□□□□□ 84% left"))
        XCTAssertTrue(snapshot.markdownSummary.contains("Session: `019d70fe-fd27-7a12-a3f7-9c89ae5048b6`"))
    }

    func testUsesFallbackSessionMetadataWhenTailLacksSessionMeta() throws {
        let url = temporaryRolloutURL()
        try """
        {"timestamp":"2026-05-15T10:02:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1,"cached_input_tokens":0,"output_tokens":1,"reasoning_output_tokens":0,"total_tokens":2},"last_token_usage":{"input_tokens":63000,"cached_input_tokens":12000,"output_tokens":2000,"reasoning_output_tokens":0,"total_tokens":65000},"model_context_window":100000}}}
        """.appending("\n").write(to: url, atomically: true, encoding: .utf8)

        let snapshot = try CodexStatusSnapshotReader().read(transcriptPath: url.path,
                                                            fallbackSessionID: "session-from-registry",
                                                            fallbackCWD: "/Users/timfeng")

        XCTAssertEqual(snapshot.sessionID, "session-from-registry")
        XCTAssertEqual(snapshot.cwd, "/Users/timfeng")
        XCTAssertTrue(snapshot.markdownSummary.contains("Directory: `~`"))
    }

    func testThrowsWhenRolloutHasNoTokenCount() throws {
        let url = temporaryRolloutURL()
        try """
        {"timestamp":"2026-05-15T10:00:00.000Z","type":"event_msg","payload":{"type":"agent_message","message":"hello"}}
        """.appending("\n").write(to: url, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try CodexStatusSnapshotReader().read(transcriptPath: url.path)) { error in
            XCTAssertEqual(error as? CodexStatusSnapshotReader.Error, .noTokenCount)
        }
    }

    private func temporaryRolloutURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-status-\(UUID().uuidString)")
            .appendingPathExtension("jsonl")
    }
}
