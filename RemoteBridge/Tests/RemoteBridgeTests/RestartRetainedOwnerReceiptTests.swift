import XCTest
import Darwin
@testable import RemoteBridge

final class RestartRetainedOwnerReceiptTests: XCTestCase {
    func testRestartArgumentsCannotFallThroughOnMalformedReceiptInput() throws {
        XCTAssertNil(try RestartPreparationArguments.parse(["--cloudflared-supervisor"]))
        XCTAssertEqual(try RestartPreparationArguments.parse(["--inspect-restart"]),
                       .init(inspectOnly: true, ownerReceiptPath: nil))
        XCTAssertEqual(try RestartPreparationArguments.parse(["--prepare-for-restart", "--restart-owner-receipt", "/tmp/owner.json"]),
                       .init(inspectOnly: false, ownerReceiptPath: "/tmp/owner.json"))
        for args in [["--restart-owner-receipt"], ["--restart-owner-receipt=/tmp/owner.json"],
                     ["--inspect-restart", "--prepare-for-restart"], ["--inspect-restart", "--inspect-restart"],
                     ["--inspect-restart", "--restart-owner-receipt"],
                     ["--inspect-restart", "--restart-owner-receipt", "relative.json"],
                     ["--prepare-for-restart", "--restart-owner-receipt", "/one", "--restart-owner-receipt", "/two"],
                     ["--inspect-restart", "--cloudflared-supervisor"]] {
            XCTAssertThrowsError(try RestartPreparationArguments.parse(args), args.joined(separator: " "))
        }
    }

    private final class Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let oldBase = "native-session:4054152F-2625-4823-A4F0-86D75397CB6F:C9333404-9D3D-4B7D-95E0-AB811F361C0D"
        let carrier = "05BCA054-18B1-487E-9E0E-142082C48C74"
        let native = "437BEA2D-A3DC-4B1F-BE78-9A9CEF927A4E"
        let workspace = "BD0D9DFC-C9C4-4CD6-A169-CEAFEAC300CC"
        var ids = ["8c054d56-c2c1-40bd-9c57-71bfb0d23465", "449b9f28-cb23-4559-a765-e1792968f08a", "2c2c20b7-e4f3-4310-8dc4-1e6457da3f41"]
        let threads = ["01a0b4af-ed47-7993-8ea3-0076dc8a3039", "01a0b9e8-3972-7a33-bcc2-9cb5f691d1cc", "01a0beeb-74da-7d41-b9ad-07a1053d7e9e"]
        let tokens = ["b79e1a8889e94701b7c5287b1e7f9163", "b41b7efe4ef74f038e9dfd2d07d80549"]
        var processes = [Process]()
        var pids: [Int32] { processes.map(\.processIdentifier) + [getpid()] }
        var paths: BridgePaths { BridgePaths(supportDirectory: directory) }
        var receiptURL: URL { directory.appendingPathComponent("receipt.json") }
        var evidenceURL: URL { directory.appendingPathComponent("owner.md") }
        var originals = [URL: Data]()
        init() throws {
            try paths.ensureSupportDirectoriesExist()
            for _ in 0..<2 {
                let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/sleep")
                process.arguments = ["120"]; try process.run(); processes.append(process)
            }
            try Data("owner: retain both old conversations without auto-resume\n".utf8).write(to: evidenceURL)
            for i in 0..<3 {
                let panel = i == 2 ? carrier : oldBase + (i == 1 ? ":handoff-staging:" + tokens[0] : "")
                let record = AgentSessionRegistryRecord(version: 1, vendor: "codex", workspaceID: workspace,
                    sessionID: ids[i], panelID: panel, pid: pids[i], cwd: "/tmp", createdAt: "2026-09-24T00:00:00Z",
                    transcriptPath: directory.appendingPathComponent("rollout-\(threads[i]).jsonl").path,
                    tmuxPaneID: i == 2 ? nil : (i == 0 ? "%4" : "%27"),
                    tmuxSocketPath: i == 2 ? nil : "/tmp/test.sock", runtime: "codex_app_server", threadID: threads[i])
                let url = paths.codexAgentSessionsDirectory.appendingPathComponent("codex-\(ids[i]).json")
                let bytes = try JSONEncoder().encode(record); try bytes.write(to: url); originals[url] = bytes
            }
        }
        deinit {
            for process in processes { if process.isRunning { process.terminate() }; process.waitUntilExit() }
            try? FileManager.default.removeItem(at: directory)
        }
        func document() throws -> RestartRetainedOwnerReceipt.Document {
            func identity(_ i: Int) throws -> RestartRetainedOwnerReceipt.Identity {
                .init(registrySessionId: ids[i], durableResumeId: threads[i], pid: pids[i],
                      birthNanoseconds: try XCTUnwrap(ClaudeCurrentHookEvidence.processBirthNanoseconds(pids[i])))
            }
            return .init(schema: "tidey.retained-rollback-owner/1", ownerEvidencePath: evidenceURL.path,
                ownerEvidenceSha256: RestartRetainedOwnerReceipt.digest(try Data(contentsOf: evidenceURL)),
                successor: try identity(2), retained: try (0..<2).map {
                    .init(identity: try identity($0), resolvedPanelId: oldBase + ":handoff-rollback:" + tokens[$0],
                          retainHistory: true, autoResume: false)
                })
        }
        func receipt(edit: (inout [String: Any]) -> Void = { _ in }) throws -> RestartRetainedOwnerReceipt {
            let encoder = JSONEncoder(); encoder.keyEncodingStrategy = .convertToSnakeCase
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(document())) as? [String: Any])
            edit(&object)
            try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: receiptURL)
            return try RestartRetainedOwnerReceipt.load(path: receiptURL.path)
        }
        func monitor(_ receipt: RestartRetainedOwnerReceipt?, wrongRoot: Bool = false,
                     healthyRetained: Bool = false, successorInTmux: Bool = false) -> AgentSessionRegistryMonitor {
            let oldBase = oldBase, tokens = tokens, workspace = workspace, pids = pids
            let monitor = AgentSessionRegistryMonitor(paths: paths, hub: AgentEventHub(),
                tmuxResolver: TmuxStateResolver(ttl: 0) { socket, args in
                    guard socket == "/tmp/test.sock" else { return "" }
                    if args.contains("#{pane_id}|#{@tidey_workspace_id}|#{@tidey_panel_id}") {
                        return "%4|\(workspace)|\(oldBase):handoff-rollback:\(tokens[0])\n%27|\(workspace)|\(oldBase):handoff-rollback:\(tokens[1])"
                    }
                    if args.contains("#{pane_id}|#{pane_pid}|#{@tidey_workspace_id}|#{@tidey_panel_id}") {
                        let i = args.contains("%4") ? 0 : 1
                        return "\(i == 0 ? "%4" : "%27")|\(wrongRoot ? 1 : pids[i])|\(workspace)|\(oldBase):handoff-rollback:\(tokens[i])"
                    }
                    return ""
                }, parentPIDLookup: { _ in nil }, restartOwnerReceipt: receipt)
            var panels: [AgentPanelProcessSnapshot] = [
                .init(workspaceID: workspace, panelID: "native-session:\(carrier):\(native)", effectiveShellPID: getpid(),
                      tmuxPaneID: successorInTmux ? "%90" : nil, tmuxSocketPath: successorInTmux ? "/tmp/test.sock" : nil,
                      logicalKind: .nativeSession, carrierPanelID: carrier, nativeSessionID: native)]
            if healthyRetained {
                panels.append(.init(workspaceID: workspace, panelID: oldBase + ":handoff-rollback:" + tokens[0],
                    effectiveShellPID: pids[0], tmuxPaneID: "%4", tmuxSocketPath: "/tmp/test.sock"))
            }
            monitor.replaceLivePanels(workspaceID: workspace, panels: panels)
            return monitor
        }
    }

    func testExplicitReceiptResolvesCrossCarrierHistoryWithoutMutatingRegistry() throws {
        let f = try Fixture()
        XCTAssertFalse(f.monitor(nil).refreshRuntimeResumeEvidence().isComplete)
        let receipt = try f.receipt()
        let monitor = f.monitor(receipt)
        let snapshot = monitor.refreshRuntimeResumeEvidence()
        XCTAssertTrue(snapshot.isComplete)
        XCTAssertEqual(snapshot.sourceRecordCount, 3)
        XCTAssertEqual(snapshot.resolvedCandidateCount, 1)
        XCTAssertEqual(snapshot.records.map(\.durableResumeID), [f.threads[2]])
        XCTAssertEqual(Set(snapshot.nonRestoringRecords.map(\.durableResumeID)), Set(f.threads.prefix(2)))
        XCTAssertEqual(Set(snapshot.nonRestoringRecords.map(\.reason)), ["owner_confirmed_retained_rollback"])
        XCTAssertEqual(receipt.matchedSessionIDs(in: snapshot.nonRestoringRecords), f.ids.sorted())
        XCTAssertFalse(monitor.restartDurabilityBlockers().contains { $0.code == "writer_binding_mismatch" })
        let socket = ReceiptRecordingSocket()
        let publisher = RuntimeResumeDescriptorPublisher(registryReader: AgentSessionRegistryRuntimeResumeReader(monitor: monitor),
            topologyReader: ReceiptNoTmuxTopology(), inventoryReconciler: socket, socketSender: socket)
        try publisher.reconcileForRestart()
        XCTAssertEqual(socket.descriptors.count, 1)
        XCTAssertEqual(socket.descriptors.first?.slot.panelID, f.carrier)
        XCTAssertEqual(socket.descriptors.first?.content.agent?.durableResumeID, f.threads[2])
        XCTAssertEqual(socket.descriptors.first?.content.restorePolicy, .directResume)
        XCTAssertEqual(socket.descriptors.first?.content.agent?.launch.arguments, ["resume", f.threads[2]])
        for (url, bytes) in f.originals { XCTAssertEqual(try Data(contentsOf: url), bytes) }
    }

    func testPostRefreshRollbackPanelOptionsStillRequireFreshOwnerReceipt() throws {
        let f = try Fixture()
        let oldReceipt = try f.receipt()
        XCTAssertTrue(f.monitor(oldReceipt).refreshRuntimeResumeEvidence().isComplete)
        // Simulate normal old-writer exit followed by two new wrapper generations.
        // New wrappers take the exact rollback pane option rather than old raw
        // canonical/staging aliases. The old carrier is absent from live panels.
        for i in 0..<2 {
            f.processes[i].terminate(); f.processes[i].waitUntilExit()
            let replacement = Process(); replacement.executableURL = URL(fileURLWithPath: "/bin/sleep")
            replacement.arguments = ["120"]; try replacement.run(); f.processes[i] = replacement
            let url = f.paths.codexAgentSessionsDirectory.appendingPathComponent("codex-\(f.ids[i]).json")
            var record = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
            f.ids[i] = UUID().uuidString.lowercased(); record["session_id"] = f.ids[i]
            record["pid"] = f.pids[i]
            record["panel_id"] = f.oldBase + ":handoff-rollback:" + f.tokens[i]
            try FileManager.default.removeItem(at: url)
            try JSONSerialization.data(withJSONObject: record).write(to:
                f.paths.codexAgentSessionsDirectory.appendingPathComponent("codex-\(f.ids[i]).json"))
        }
        let unclassified = f.monitor(nil).refreshRuntimeResumeEvidence()
        XCTAssertFalse(unclassified.isComplete)
        XCTAssertEqual(unclassified.records.map(\.durableResumeID), [f.threads[2]])
        XCTAssertTrue(unclassified.nonRestoringRecords.isEmpty, "same-base guard cannot classify a missing old carrier")
        XCTAssertFalse(f.monitor(oldReceipt).refreshRuntimeResumeEvidence().isComplete, "old process receipt must fail")
        let urls = try FileManager.default.contentsOfDirectory(at: f.paths.codexAgentSessionsDirectory, includingPropertiesForKeys: nil)
        let bytes = try Dictionary(uniqueKeysWithValues: urls.map { ($0, try Data(contentsOf: $0)) })
        let refreshed = f.monitor(try f.receipt()).refreshRuntimeResumeEvidence()
        XCTAssertTrue(refreshed.isComplete)
        XCTAssertEqual(refreshed.records.map(\.durableResumeID), [f.threads[2]])
        XCTAssertEqual(Set(refreshed.nonRestoringRecords.map(\.durableResumeID)), Set(f.threads.prefix(2)))
        XCTAssertEqual(Set(refreshed.nonRestoringRecords.map(\.reason)), ["owner_confirmed_retained_rollback"])
        for (url, original) in bytes { XCTAssertEqual(try Data(contentsOf: url), original) }
    }

    func testWrongPerPaneTokenIdentityBirthOrSuccessorNeverExemptsOldRecords() throws {
        let f = try Fixture()
        let changes: [(inout [String: Any]) -> Void] = [
            { o in var r = o["retained"] as! [[String: Any]]
                let first = r[0]["resolved_panel_id"]; r[0]["resolved_panel_id"] = r[1]["resolved_panel_id"]
                r[1]["resolved_panel_id"] = first; o["retained"] = r },
            { o in var r = o["retained"] as! [[String: Any]]
                var a = r[0]["identity"] as! [String: Any]; var b = r[1]["identity"] as! [String: Any]
                let first = a["durable_resume_id"]; a["durable_resume_id"] = b["durable_resume_id"]; b["durable_resume_id"] = first
                r[0]["identity"] = a; r[1]["identity"] = b; o["retained"] = r },
            { o in var r = o["retained"] as! [[String: Any]]; var id = r[0]["identity"] as! [String: Any]
                id["birth_nanoseconds"] = 1; r[0]["identity"] = id; o["retained"] = r },
            { o in var id = o["successor"] as! [String: Any]; id["durable_resume_id"] = UUID().uuidString; o["successor"] = id },
        ]
        for edit in changes {
            let monitor = f.monitor(try f.receipt(edit: edit))
            XCTAssertFalse(monitor.refreshRuntimeResumeEvidence().isComplete)
            XCTAssertTrue(monitor.currentRuntimeResumeAgentSnapshot().nonRestoringRecords.isEmpty)
        }
        let receipt = try f.receipt()
        XCTAssertFalse(f.monitor(receipt, wrongRoot: true).refreshRuntimeResumeEvidence().isComplete)
        try Data("changed owner intent".utf8).write(to: f.evidenceURL)
        XCTAssertFalse(f.monitor(receipt).refreshRuntimeResumeEvidence().isComplete)
    }

    func testReceiptRejectsStagingDuplicateDurableAndAutomaticResume() throws {
        let f = try Fixture()
        for field in ["staging", "duplicate", "resume"] {
            XCTAssertThrowsError(try f.receipt { o in
                var r = o["retained"] as! [[String: Any]]
                if field == "staging" { r[1]["resolved_panel_id"] = f.oldBase + ":handoff-staging:" + f.tokens[0] }
                if field == "resume" { r[0]["auto_resume"] = true }
                if field == "duplicate" { var id = r[0]["identity"] as! [String: Any]
                    id["durable_resume_id"] = f.threads[2]; r[0]["identity"] = id }
                o["retained"] = r
            })
        }
    }

    func testChangedReceiptFileCannotReuseEarlierOwnerChoice() throws {
        let f = try Fixture(); let receipt = try f.receipt()
        let monitor = f.monitor(receipt)
        XCTAssertTrue(monitor.refreshRuntimeResumeEvidence().isComplete)
        try Data("changed receipt bytes".utf8).write(to: f.receiptURL)
        XCTAssertFalse(monitor.refreshRuntimeResumeEvidence().isComplete)
        XCTAssertTrue(monitor.restartDurabilityBlockers().contains { $0.code == "owner_receipt_mismatch" })
    }

    func testCurrentContextMismatchAndDuplicateDurableRemainBlocked() throws {
        let f = try Fixture(); let receipt = try f.receipt()
        let monitor = f.monitor(receipt)
        let url = f.paths.codexAgentSessionsDirectory.appendingPathComponent("codex-\(f.ids[0]).json")
        let original = try XCTUnwrap(f.originals[url])
        for (key, replacement) in [("cwd", "/other"), ("tmux_socket_path", "/other.sock"), ("tmux_pane_id", "%88")] {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
            object[key] = replacement
            try JSONSerialization.data(withJSONObject: object).write(to: url)
            XCTAssertFalse(monitor.refreshRuntimeResumeEvidence().isComplete, key)
            try original.write(to: url)
        }
        let extraURL = f.paths.codexAgentSessionsDirectory.appendingPathComponent("codex-extra.json")
        var extra = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
        extra["session_id"] = UUID().uuidString; extra["panel_id"] = f.carrier
        extra["pid"] = getpid(); extra.removeValue(forKey: "tmux_pane_id"); extra.removeValue(forKey: "tmux_socket_path")
        try JSONSerialization.data(withJSONObject: extra).write(to: extraURL)
        XCTAssertFalse(monitor.refreshRuntimeResumeEvidence().isComplete, "real duplicate writer is never hidden by owner intent")
    }

    func testOwnerEvidenceChangeDuringReconcileStopsCheckpoint() throws {
        let f = try Fixture(); let monitor = f.monitor(try f.receipt())
        let result = RestartPreparation(snapshot: { monitor.refreshRuntimeResumeEvidence() },
            reconcile: { try Data("owner choice changed".utf8).write(to: f.evidenceURL) },
            checkpoint: { XCTFail("changed owner intent must stop before saved graph checkpoint"); return [:] }).prepare()
        XCTAssertFalse(result.technicalReady)
        XCTAssertEqual(result.blockers.first?.code, "identity_changed")
    }

    func testReceiptCannotExcludeAnIndependentlyRestorableConversation() throws {
        let f = try Fixture(); let monitor = f.monitor(try f.receipt(), healthyRetained: true)
        let snapshot = monitor.refreshRuntimeResumeEvidence()
        XCTAssertTrue(snapshot.records.contains { $0.durableResumeID == f.threads[0] }, "fixture must actually resolve the healthy retained record")
        XCTAssertFalse(snapshot.isComplete)
        XCTAssertFalse(snapshot.nonRestoringRecords.contains { $0.reason == "owner_confirmed_retained_rollback" })
        XCTAssertTrue(monitor.restartDurabilityBlockers().contains { $0.code == "owner_receipt_mismatch" })
    }

    func testReceiptRequiresDirectNativeSuccessorEvenWhenTmuxSuccessorIsRestorable() throws {
        let f = try Fixture(); let receipt = try f.receipt()
        let url = f.paths.codexAgentSessionsDirectory.appendingPathComponent("codex-\(f.ids[2]).json")
        var record = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        record["panel_id"] = "native-session:\(f.carrier):\(f.native)"
        record["tmux_pane_id"] = "%90"; record["tmux_socket_path"] = "/tmp/test.sock"
        try JSONSerialization.data(withJSONObject: record).write(to: url)
        let monitor = f.monitor(receipt, successorInTmux: true)
        let snapshot = monitor.refreshRuntimeResumeEvidence()
        XCTAssertTrue(snapshot.records.contains { $0.durableResumeID == f.threads[2] && $0.binding.tmuxPaneID == "%90" }, "fixture must resolve successor before native-only guard")
        XCTAssertFalse(snapshot.isComplete)
        XCTAssertFalse(snapshot.nonRestoringRecords.contains { $0.reason == "owner_confirmed_retained_rollback" })
        XCTAssertTrue(monitor.restartDurabilityBlockers().contains { $0.code == "owner_receipt_mismatch" })
    }
}

private struct ReceiptNoTmuxTopology: RuntimeResumeTmuxTopologyReading {
    func topologySnapshot(for binding: RuntimeResumeDescriptorBinding) throws -> RuntimeResumeTmuxTopologySnapshot? {
        XCTFail("only the current direct-native successor may be published"); return nil
    }
}

private final class ReceiptRecordingSocket: RuntimeResumeDescriptorSocketSending,
    RuntimeResumeDescriptorInventoryReconciling, @unchecked Sendable {
    var descriptors = [RuntimeResumeStoredDescriptor]()
    func send(_ update: RuntimeResumeDescriptorSocketUpdate) throws {
        descriptors.append(.init(slot: .init(binding: update.binding), revision: 1, content: update.content))
    }
    func currentAgentDescriptors() throws -> [RuntimeResumeStoredDescriptor] { descriptors }
    func remove(_ removal: RuntimeResumeDescriptorSocketRemoval) throws -> Bool {
        XCTFail("restart preparation must never delete retained history"); return false
    }
}
