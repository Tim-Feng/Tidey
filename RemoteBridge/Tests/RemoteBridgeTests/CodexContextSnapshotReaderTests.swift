import XCTest
@testable import RemoteBridge

final class CodexContextSnapshotReaderTests: XCTestCase {
    func testReadsLatestNonEmptyTokenCountFromRolloutTail() throws {
        let url = temporaryRolloutURL()
        try """
        {"timestamp":"2026-05-15T10:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1,"cached_input_tokens":0,"output_tokens":1,"reasoning_output_tokens":0,"total_tokens":2},"last_token_usage":{"input_tokens":50000,"cached_input_tokens":0,"output_tokens":1000,"reasoning_output_tokens":0,"total_tokens":51000},"model_context_window":100000}}}
        {"timestamp":"2026-05-15T10:01:00.000Z","type":"event_msg","payload":{"type":"token_count","info":null,"rate_limits":{"limit_id":"codex"}}}
        {"timestamp":"2026-05-15T10:02:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1,"cached_input_tokens":0,"output_tokens":1,"reasoning_output_tokens":0,"total_tokens":2},"last_token_usage":{"input_tokens":63000,"cached_input_tokens":12000,"output_tokens":2000,"reasoning_output_tokens":0,"total_tokens":65000},"model_context_window":100000}}}
        """.appending("\n").write(to: url, atomically: true, encoding: .utf8)

        let snapshot = try CodexContextSnapshotReader().read(transcriptPath: url.path)

        XCTAssertEqual(snapshot.timestamp, "2026-05-15T10:02:00.000Z")
        XCTAssertEqual(snapshot.tokensInContext, 65_000)
        XCTAssertEqual(snapshot.contextWindow, 100_000)
        XCTAssertEqual(snapshot.rawTokensRemaining, 35_000)
        XCTAssertEqual(snapshot.percentRemaining, 40)
        XCTAssertTrue(snapshot.markdownSummary.contains("65,000 / 100,000"))
    }

    func testThrowsWhenRolloutHasNoTokenCount() throws {
        let url = temporaryRolloutURL()
        try """
        {"timestamp":"2026-05-15T10:00:00.000Z","type":"event_msg","payload":{"type":"agent_message","message":"hello"}}
        """.appending("\n").write(to: url, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try CodexContextSnapshotReader().read(transcriptPath: url.path)) { error in
            XCTAssertEqual(error as? CodexContextSnapshotReader.Error, .noTokenCount)
        }
    }

    private func temporaryRolloutURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-context-\(UUID().uuidString)")
            .appendingPathExtension("jsonl")
    }
}
