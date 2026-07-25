import XCTest
@testable import RemoteBridge

// B-race: registry removal and same-ID replacement must fail the typed
// history seams closed — a missing or replaced session can never let an
// old raw page validate.
final class AgentSessionRegistryMonitorHistoryTests: XCTestCase {
    private struct Fixture {
        let supportDirectory: URL
        let paths: BridgePaths
        let hub: AgentEventHub
        let monitor: AgentSessionRegistryMonitor
        let registryURL: URL
    }

    private func waitUntil(timeout: TimeInterval = 6, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return condition()
    }

    private func makeUserLine(uuid: String, content: String) -> String {
        let object: [String: Any] = [
            "type": "user",
            "uuid": uuid,
            "sessionId": "session",
            "version": "2.0.0",
            "timestamp": "2026-04-30T00:00:00Z",
            "message": ["role": "user", "content": content],
        ]
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(data: data, encoding: .utf8)!
    }

    private func writeTranscript(into directory: URL, name: String, prefix: String) throws -> URL {
        let url = directory.appendingPathComponent(name, isDirectory: false)
        let lines = (0..<6).map { makeUserLine(uuid: "\(prefix)-\($0)", content: "\(prefix)-\($0)") }
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func writeRecord(at url: URL,
                             workspaceID: String,
                             transcriptPath: String,
                             panelID: String = "panel") throws {
        let record = """
        {
          "version": 1,
          "vendor": "claude",
          "workspace_id": "\(workspaceID)",
          "session_id": "session",
          "panel_id": "\(panelID)",
          "pid": \(getpid()),
          "cwd": "/tmp",
          "created_at": "2026-04-30T00:00:00Z",
          "transcript_path": "\(transcriptPath)"
        }
        """
        try Data(record.utf8).write(to: url, options: .atomic)
    }

    private func makeFixture(transcriptURL: URL) throws -> Fixture {
        let fileManager = FileManager.default
        let supportDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("tidey-monitor-history-\(UUID().uuidString)", isDirectory: true)
        let paths = BridgePaths(supportDirectory: supportDirectory)
        try paths.ensureSupportDirectoriesExist(fileManager: fileManager)
        let registryURL = paths.claudeAgentSessionsDirectory.appendingPathComponent("claude-session.json")
        try writeRecord(at: registryURL, workspaceID: "workspace", transcriptPath: transcriptURL.path)
        let hub = AgentEventHub()
        let monitor = AgentSessionRegistryMonitor(paths: paths,
                                                  fileManager: fileManager,
                                                  hub: hub,
                                                  tmuxResolver: TmuxStateResolver(ttl: 60) { _, _ in "" },
                                                  parentPIDLookup: { _ in nil })
        try monitor.start()
        return Fixture(supportDirectory: supportDirectory,
                       paths: paths,
                       hub: hub,
                       monitor: monitor,
                       registryURL: registryURL)
    }

    private func planIsUsable(_ plan: AgentAfterCursorPlan) -> Bool {
        switch plan.mode {
        case .rawCovered, .scan:
            return true
        case .hubOnly, .unavailable:
            return false
        }
    }

    func testHistoryPlanFailsClosedWhenSessionRemovedBeforeValidation() throws {
        let workDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tidey-monitor-history-tx-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDirectory) }
        let transcriptURL = try writeTranscript(into: workDirectory, name: "one.jsonl", prefix: "one")
        let fixture = try makeFixture(transcriptURL: transcriptURL)
        defer { try? FileManager.default.removeItem(at: fixture.supportDirectory) }

        XCTAssertTrue(waitUntil {
            planIsUsable(fixture.monitor.afterCursorPlan(
                sessionID: "session",
                afterSeq: 0,
                expectedEpoch: fixture.hub.currentHistoryEpoch(sessionID: "session")))
        }, "precondition: the live session plans successfully")
        let oldEpoch = fixture.hub.currentHistoryEpoch(sessionID: "session")

        try FileManager.default.removeItem(at: fixture.registryURL)
        fixture.monitor.scanRegistryForTesting()

        let plan = fixture.monitor.afterCursorPlan(sessionID: "session",
                                                   afterSeq: 0,
                                                   expectedEpoch: oldEpoch)
        guard case .unavailable = plan.mode else {
            return XCTFail("a removed session must plan unavailable, never hubOnly, got \(plan.mode)")
        }
        XCTAssertFalse(fixture.monitor.validateHistoryEpoch(sessionID: "session", epoch: oldEpoch),
                       "a missing session must never validate an old raw page")
    }

    func testSameSessionIDReplacementAdvancesEpochAndRejectsOldAnchor() throws {
        let workDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tidey-monitor-history-tx-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDirectory) }
        let firstTranscript = try writeTranscript(into: workDirectory, name: "one.jsonl", prefix: "one")
        let secondTranscript = try writeTranscript(into: workDirectory, name: "two.jsonl", prefix: "two")
        let fixture = try makeFixture(transcriptURL: firstTranscript)
        defer { try? FileManager.default.removeItem(at: fixture.supportDirectory) }

        XCTAssertTrue(waitUntil {
            planIsUsable(fixture.monitor.afterCursorPlan(
                sessionID: "session",
                afterSeq: 0,
                expectedEpoch: fixture.hub.currentHistoryEpoch(sessionID: "session")))
        }, "precondition: the first incarnation plans successfully")
        let oldEpoch = fixture.hub.currentHistoryEpoch(sessionID: "session")
        let oldAnchor = AgentHistoryAnchor(epoch: oldEpoch,
                                           position: TranscriptEventPosition(lineOffset: 100, ordinal: 0))

        // Removal must be OBSERVED before the same-ID recreation, otherwise
        // the scan would treat it as an update of the same incarnation.
        try FileManager.default.removeItem(at: fixture.registryURL)
        fixture.monitor.scanRegistryForTesting()
        if case .unavailable = fixture.monitor.afterCursorPlan(sessionID: "session",
                                                               afterSeq: 0,
                                                               expectedEpoch: oldEpoch).mode {
        } else {
            return XCTFail("precondition: the removal was observed")
        }
        try writeRecord(at: fixture.registryURL,
                        workspaceID: "workspace",
                        transcriptPath: secondTranscript.path)
        fixture.monitor.scanRegistryForTesting()

        XCTAssertTrue(waitUntil {
            planIsUsable(fixture.monitor.afterCursorPlan(
                sessionID: "session",
                afterSeq: 0,
                expectedEpoch: fixture.hub.currentHistoryEpoch(sessionID: "session")))
        }, "the replacement incarnation plans under the CURRENT epoch")
        let newEpoch = fixture.hub.currentHistoryEpoch(sessionID: "session")
        XCTAssertGreaterThan(newEpoch.generation, oldEpoch.generation,
                             "a same-ID replacement must strictly advance the Hub epoch")
        XCTAssertFalse(fixture.monitor.validateHistoryEpoch(sessionID: "session", epoch: oldEpoch),
                       "the old incarnation's epoch must not validate")
        let step = fixture.monitor.afterCursorStep(sessionID: "session",
                                                   anchor: oldAnchor,
                                                   afterSeq: 0,
                                                   limit: 5)
        guard case .sourceChanged = step.outcome else {
            return XCTFail("an old-incarnation anchor is sourceChanged, got \(step.outcome)")
        }
        XCTAssertTrue(step.events.isEmpty)
    }

    func testWorkspaceMigrationKeepsEpochAndValidation() throws {
        let workDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tidey-monitor-history-tx-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDirectory) }
        let transcriptURL = try writeTranscript(into: workDirectory, name: "one.jsonl", prefix: "one")
        let fixture = try makeFixture(transcriptURL: transcriptURL)
        defer { try? FileManager.default.removeItem(at: fixture.supportDirectory) }

        XCTAssertTrue(waitUntil {
            planIsUsable(fixture.monitor.afterCursorPlan(
                sessionID: "session",
                afterSeq: 0,
                expectedEpoch: fixture.hub.currentHistoryEpoch(sessionID: "session")))
        }, "precondition: the session plans successfully")
        let epoch = fixture.hub.currentHistoryEpoch(sessionID: "session")

        // Workspace AND panel migration is an UPDATE of the same incarnation.
        try writeRecord(at: fixture.registryURL,
                        workspaceID: "workspace-moved",
                        transcriptPath: transcriptURL.path,
                        panelID: "panel-moved")
        fixture.monitor.scanRegistryForTesting()

        XCTAssertTrue(waitUntil {
            fixture.hub.fetch(workspaceID: "workspace-moved", sessionID: "session", limit: 5)
                .events.isEmpty == false
        }, "precondition: the migration was observed (session async update convergence)")
        XCTAssertEqual(fixture.hub.currentHistoryEpoch(sessionID: "session"), epoch,
                       "migration is not a replacement — the epoch must not change")
        XCTAssertTrue(fixture.monitor.validateHistoryEpoch(sessionID: "session", epoch: epoch),
                      "the current epoch stays valid across a migration")
    }
}
