import XCTest
@testable import RemoteBridge

final class AgentSessionRegistryRecordTests: XCTestCase {
    func testDecodesLegacyRegistryRecordWithoutTmuxMetadata() throws {
        let data = Data("""
        {
          "version": 1,
          "vendor": "claude",
          "workspace_id": "workspace-1",
          "session_id": "session-1",
          "panel_id": "panel-1",
          "pid": 123,
          "cwd": "/tmp",
          "created_at": "2026-04-15T00:00:00Z",
          "transcript_path": "/tmp/transcript.jsonl"
        }
        """.utf8)

        let record = try JSONDecoder().decode(AgentSessionRegistryRecord.self, from: data)
        XCTAssertEqual(record.vendor, "claude")
        XCTAssertEqual(record.sessionID, "session-1")
        XCTAssertNil(record.tmuxPaneID)
        XCTAssertNil(record.tmuxSocketPath)
    }

    func testDecodesRegistryRecordWithTmuxMetadata() throws {
        let data = Data("""
        {
          "version": 1,
          "vendor": "codex",
          "workspace_id": "workspace-1",
          "session_id": "session-1",
          "panel_id": "panel-1",
          "pid": 123,
          "cwd": "/tmp",
          "created_at": "2026-04-15T00:00:00Z",
          "rollout_path": "/tmp/rollout.jsonl",
          "tmux_pane_id": "%42",
          "tmux_socket_path": "/tmp/tmux-501/default"
        }
        """.utf8)

        let record = try JSONDecoder().decode(AgentSessionRegistryRecord.self, from: data)
        XCTAssertEqual(record.vendor, "codex")
        XCTAssertEqual(record.transcriptPath, "/tmp/rollout.jsonl")
        XCTAssertEqual(record.tmuxPaneID, "%42")
        XCTAssertEqual(record.tmuxSocketPath, "/tmp/tmux-501/default")
    }
}
