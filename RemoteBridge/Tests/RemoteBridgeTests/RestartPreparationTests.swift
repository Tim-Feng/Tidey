import XCTest
import Darwin
@testable import RemoteBridge

final class RestartPreparationTests: XCTestCase {
    func testRuntimeSocketAcceptsLiveSymlinkButRejectsMissingOrNonSocketTargets() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("rs-" + String(UUID().uuidString.prefix(8)))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let endpoint = directory.appendingPathComponent("s")
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        guard fd >= 0 else { return }
        defer { Darwin.close(fd) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(endpoint.path.utf8) + [0]
        XCTAssertLessThanOrEqual(bytes.count, MemoryLayout.size(ofValue: address.sun_path))
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { return }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        XCTAssertEqual(bound, 0)
        guard bound == 0 else { return }
        let alias = directory.appendingPathComponent("app.sock")
        try FileManager.default.createSymbolicLink(atPath: alias.path, withDestinationPath: endpoint.path)
        XCTAssertTrue(RestartWriterEvidence.isSocketEndpoint(at: endpoint.path))
        XCTAssertTrue(RestartWriterEvidence.isSocketEndpoint(at: alias.path), "real app.sock is a symlink to the Codex daemon socket")
        let regular = directory.appendingPathComponent("regular")
        try Data("not a socket".utf8).write(to: regular)
        for (name, target) in [("file-link", regular.path), ("directory-link", directory.path),
                               ("broken-link", directory.appendingPathComponent("missing").path)] {
            let link = directory.appendingPathComponent(name)
            try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: target)
            XCTAssertFalse(RestartWriterEvidence.isSocketEndpoint(at: link.path))
        }
        XCTAssertFalse(RestartWriterEvidence.isSocketEndpoint(at: regular.path))
        XCTAssertFalse(RestartWriterEvidence.isSocketEndpoint(at: ""))
    }

    func testRollbackClassificationNeverExemptsDuplicateDurableIdentity() {
        for rollbackID in ["A", "B"] {
            let value = RuntimeResumeAgentRegistrySnapshot(sourceRecordCount: 2, resolvedCandidateCount: 1,
                records: snapshot(["A"]).records,
                nonRestoringRecords: [.init(sessionID: "rollback-instance", vendor: "codex",
                    durableResumeID: rollbackID, workspaceID: "workspace", panelID: "rollback-panel",
                    tmuxPaneID: "%1", reason: "handoff_rollback_owner_review")])
            XCTAssertEqual(value.isComplete, rollbackID != "A", "rollback status cannot hide a real durable writer collision")
        }
    }

    func testRuntimeOwnershipBlockerStopsBeforePublicationAndReadersAreNotWriters() {
        let table = RestartWriterEvidence.ProcessTable(parents: [10: 1, 20: 10, 30: 20, 40: 1], agentPIDs: [30])
        XCTAssertTrue(table.hasAgent(under: 10), "a direct native agent without registry cannot look like an empty shell")
        XCTAssertFalse(table.hasAgent(under: 40))
        XCTAssertEqual(RestartWriterEvidence.parseWriterPIDs("p10\nf1\nar\np20\nf2\nau\nf3\naw\n"), [20])
        XCTAssertEqual(RestartWriterEvidence.parseWriterPIDs("p10\nf1\naw\np20\nf2\nau\n"), [10, 20])
        let result = RestartPreparation(snapshot: { self.snapshot() }, reconcile: { XCTFail("must not publish") },
            checkpoint: { XCTFail("must not save"); return [:] },
            validateRuntime: { [.init(code: "durable_writer_unconfirmed", detail: "A")] }).prepare()
        XCTAssertEqual(result.blockers.first?.code, "durable_writer_unconfirmed")
    }

    func testVerifiedRollbackLeaseDoesNotFreezeCanonicalPublicationButUnknownPanelDoes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let paths = BridgePaths(supportDirectory: directory)
        try paths.ensureSupportDirectoriesExist()
        let stable = "native-session:carrier:native"
        let rollback = stable + ":handoff-rollback:0123456789abcdef0123456789abcdef"
        let record = AgentSessionRegistryRecord(version: 1, vendor: "claude", workspaceID: "workspace",
            sessionID: "old-A", panelID: rollback, pid: getpid(), cwd: "/tmp", createdAt: "2026-09-01",
            transcriptPath: nil, tmuxPaneID: "%1", tmuxSocketPath: "/tmp/test.sock")
        let url = paths.claudeAgentSessionsDirectory.appendingPathComponent("old-A.json")
        let original = try JSONEncoder().encode(record); try original.write(to: url)
        for authoritative in [rollback, "unknown-panel"] {
            let monitor = AgentSessionRegistryMonitor(paths: paths, hub: AgentEventHub(),
                tmuxResolver: TmuxStateResolver(ttl: 0) { _, arguments in
                    arguments.contains("#{pane_id}|#{@tidey_workspace_id}|#{@tidey_panel_id}")
                        ? "%1|workspace|\(authoritative)" : ""
                }, parentPIDLookup: { _ in nil })
            monitor.replaceLivePanels(workspaceID: "workspace", panels: [
                AgentPanelProcessSnapshot(workspaceID: "workspace", panelID: stable, effectiveShellPID: nil,
                    tmuxPaneID: "%2", tmuxSocketPath: "/tmp/test.sock", logicalKind: .nativeSession,
                    carrierPanelID: "carrier", nativeSessionID: "native")])
            let value = monitor.refreshRuntimeResumeEvidence()
            XCTAssertEqual(value.isComplete, authoritative == rollback)
            XCTAssertEqual(try Data(contentsOf: url), original, "metadata reads must not clean registry")
        }
    }

    func testClaudeAliasResolvesCurrentPayloadFromInitialJournal() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let paths = BridgePaths(supportDirectory: directory)
        try paths.ensureSupportDirectoriesExist()
        let oldID = "d4c190fe-5539-42b6-a717-db4303c8632f"
        let currentID = "0f06b852-713f-4669-8435-3f65f43d7777"
        let initialID = "46efe6fd-837f-48b6-b292-35bffed9db66"
        let epoch = "\(getpid())-\(UInt64(Date().timeIntervalSince1970 * 1_000_000_000))"
        let journal = paths.claudeAgentSessionsDirectory.appendingPathComponent("claude-hooks-\(initialID).jsonl")
        let marker = journal.deletingPathExtension().appendingPathExtension("epoch")
        let payload = try JSONSerialization.data(withJSONObject: ["session_id": currentID, "cwd": "/tmp"])
        let event = try JSONSerialization.data(withJSONObject: ["v": 3, "seq": 171,
            "epoch": epoch, "event": "session-start", "payload_b64": payload.base64EncodedString()])
        try (event + Data("\n".utf8)).write(to: journal)
        try Data(epoch.utf8).write(to: marker)
        try Data("171".utf8).write(to: URL(fileURLWithPath: journal.path + ".seq"))
        let transcript = directory.appendingPathComponent(currentID + ".jsonl")
        try Data("{}\n".utf8).write(to: transcript)
        let timestamp = ISO8601DateFormatter()
        timestamp.formatOptions.insert(.withFractionalSeconds)
        let birth = try XCTUnwrap(ClaudeCurrentHookEvidence.processBirthNanoseconds(getpid()))
        XCTAssertEqual(try XCTUnwrap(ClaudeCurrentHookEvidence.read(directory: paths.claudeAgentSessionsDirectory, pid: getpid(), birth: birth)).sessionID, currentID)
        var original = [URL: Data]()
        for id in [oldID, currentID] {
            let record = AgentSessionRegistryRecord(version: 1, vendor: "claude", workspaceID: "workspace",
                sessionID: id, panelID: "panel", pid: getpid(), cwd: "/tmp",
                createdAt: timestamp.string(from: Date()),
                transcriptPath: id == currentID ? transcript.path : nil,
                tmuxPaneID: "%1", tmuxSocketPath: "/tmp/test.sock")
            let url = paths.claudeAgentSessionsDirectory.appendingPathComponent("claude-\(id).json")
            original[url] = try JSONEncoder().encode(record)
            try original[url]!.write(to: url)
        }
        let monitor = AgentSessionRegistryMonitor(paths: paths, hub: AgentEventHub(),
            tmuxResolver: TmuxStateResolver(ttl: 0) { _, arguments in
                arguments.contains("#{pane_id}|#{@tidey_workspace_id}|#{@tidey_panel_id}") ? "%1|workspace|panel" : ""
            }, parentPIDLookup: { _ in nil })
        monitor.replaceLivePanels(workspaceID: "workspace", panels: [
            AgentPanelProcessSnapshot(workspaceID: "workspace", panelID: "panel", effectiveShellPID: getpid(),
                tmuxPaneID: "%1", tmuxSocketPath: "/tmp/test.sock")])
        let value = monitor.refreshRuntimeResumeEvidence()
        XCTAssertTrue(value.isComplete)
        XCTAssertEqual(value.sourceRecordCount, 2)
        XCTAssertEqual(value.resolvedCandidateCount, 1)
        XCTAssertEqual(value.records.map(\.durableResumeID), [currentID])
        XCTAssertEqual(value.nonRestoringRecords.map(\.durableResumeID), [oldID])
        XCTAssertEqual(value.nonRestoringRecords.first?.reason, "superseded_same_wrapper_alias")
        XCTAssertTrue(monitor.restartDurabilityBlockers().isEmpty)
        for (url, data) in original { XCTAssertEqual(try Data(contentsOf: url), data) }
        let oldURL = paths.claudeAgentSessionsDirectory.appendingPathComponent("claude-\(oldID).json")
        let oldBytes = try XCTUnwrap(original[oldURL])
        // A real second process, wrong cwd/socket, or a pre-birth lease cannot
        // become a historical alias simply because the durable IDs differ.
        let changes: [(String, Any)] = [("pid", getppid()), ("cwd", "/other"),
            ("tmux_socket_path", "/wrong.sock"), ("created_at", "2000-01-01T00:00:00Z")]
        for (key, replacement) in changes {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: oldBytes) as? [String: Any])
            object[key] = replacement
            try JSONSerialization.data(withJSONObject: object).write(to: oldURL)
            let conflict = monitor.refreshRuntimeResumeEvidence()
            XCTAssertFalse(conflict.isComplete, key)
            XCTAssertTrue(conflict.nonRestoringRecords.isEmpty, key)
            try oldBytes.write(to: oldURL)
        }
    }

    private func snapshot(_ ids: [String] = ["current-B"]) -> RuntimeResumeAgentRegistrySnapshot {
        let records = ids.enumerated().map { index, id in
            RuntimeResumeAgentRegistryRecord(
                binding: .init(workspaceID: "workspace", panelID: "carrier-\(index)", tmuxPaneID: nil),
                vendor: .codex, durableResumeID: id,
                launch: .init(executable: "codex", arguments: ["resume", id], workingDirectory: "/tmp"))
        }
        return .init(sourceRecordCount: records.count, resolvedCandidateCount: records.count, records: records)
    }

    func testReconcilesThenFencesBeforeNativeCheckpointWithoutGrantingReboot() {
        var events = [String]()
        let operation = RestartPreparation(snapshot: {
            events.append("snapshot"); return self.snapshot()
        }, reconcile: { events.append("reconcile") }, checkpoint: {
            events.append("checkpoint"); return ["technical_ready": .bool(true)]
        })
        let result = operation.prepare()
        XCTAssertTrue(result.technicalReady)
        XCTAssertTrue(result.ownerReviewRequired)
        XCTAssertTrue(result.blockers.isEmpty)
        XCTAssertEqual(events, ["snapshot", "reconcile", "snapshot", "checkpoint", "snapshot"])
    }

    func testIncompleteAndDuplicateDurableWritersNeverPublish() {
        for input in [RuntimeResumeAgentRegistrySnapshot(sourceRecordCount: 2, resolvedCandidateCount: 1,
                                                         records: snapshot().records), snapshot(["same", "same"])] {
            let result = RestartPreparation(snapshot: { input }, reconcile: { XCTFail("must not publish") },
                                            checkpoint: { XCTFail("must not save"); return [:] }).prepare()
            XCTAssertFalse(result.technicalReady)
            XCTAssertEqual(result.blockers.first?.code, input.isComplete ? "conflicting_writers" : "incomplete_inventory")
        }
    }

    func testThreadChangesDuringPublicationBlockCheckpoint() {
        var count = 0
        let result = RestartPreparation(snapshot: {
            count += 1; return self.snapshot([count == 1 ? "A" : "B"])
        }, reconcile: {}, checkpoint: { XCTFail("stale checkpoint"); return [:] }).prepare()
        XCTAssertEqual(result.blockers.first?.code, "identity_changed")
        XCTAssertFalse(result.technicalReady)
    }

    func testNativeBlockerAndTransportFailureRemainTypedFailures() {
        let native = RestartPreparation(snapshot: { self.snapshot() }, reconcile: {}, checkpoint: {
            ["technical_ready": .bool(false), "blockers": .array([.object(["code": .string("database_mismatch"), "detail": .string("saved graph")])])]
        }).prepare()
        XCTAssertFalse(native.technicalReady)
        XCTAssertEqual(native.blockers.first?.code, "database_mismatch")
        let transport = RestartPreparation(snapshot: { self.snapshot() }, reconcile: {
            throw NSError(domain: "test", code: 1)
        }, checkpoint: { XCTFail("must not save"); return [:] }).prepare()
        XCTAssertEqual(transport.blockers.first?.code, "publication_failed")
    }
}
