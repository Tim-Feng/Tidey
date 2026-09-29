import Foundation

struct RestartBlocker: Codable, Equatable {
    let code: String
    let detail: String
}

struct RestartPreparationResult: Codable {
    let schema = "tidey.restart-preparation/1"
    let sampledAt: String
    let technicalReady: Bool
    // A product snapshot never authorizes reboot or decides user/owner intent.
    let ownerReviewRequired = true
    let blockers: [RestartBlocker]
    let checkpoint: [String: JSONValue]?
    var nonRestoringRecords: [RuntimeResumeNonRestoringRecord] = []
    var ownerReceiptSHA256: String?
    var ownerReceiptMatchedSessionIDs: [String]?

    enum CodingKeys: String, CodingKey {
        case schema, blockers, checkpoint
        case sampledAt = "sampled_at"
        case technicalReady = "technical_ready"
        case ownerReviewRequired = "owner_review_required"
        case nonRestoringRecords = "non_restoring_records"
        case ownerReceiptSHA256 = "owner_receipt_sha256"
        case ownerReceiptMatchedSessionIDs = "owner_receipt_matched_session_ids"
    }
}

/// Orchestration seam. The publisher remains the only descriptor writer.
final class RestartPreparation {
    typealias Snapshot = () throws -> RuntimeResumeAgentRegistrySnapshot
    let snapshot: Snapshot
    let reconcile: () throws -> Void
    let checkpoint: () throws -> [String: JSONValue]
    let validateRuntime: () -> [RestartBlocker]

    init(snapshot: @escaping Snapshot, reconcile: @escaping () throws -> Void,
         checkpoint: @escaping () throws -> [String: JSONValue],
         validateRuntime: @escaping () -> [RestartBlocker] = { [] }) {
        self.snapshot = snapshot
        self.reconcile = reconcile
        self.checkpoint = checkpoint
        self.validateRuntime = validateRuntime
    }

    func prepare() -> RestartPreparationResult {
        var nonRestoring = [RuntimeResumeNonRestoringRecord]()
        func result(_ blockers: [RestartBlocker], _ checkpoint: [String: JSONValue]? = nil) -> RestartPreparationResult {
            var value = RestartPreparationResult(sampledAt: ISO8601DateFormatter().string(from: Date()),
                                                 technicalReady: blockers.isEmpty, blockers: blockers, checkpoint: checkpoint)
            value.nonRestoringRecords = nonRestoring
            return value
        }
        var phase = "inventory_unavailable"
        do {
            let before = try snapshot()
            nonRestoring = before.nonRestoringRecords
            guard before.isComplete else {
                return result([.init(code: "incomplete_inventory", detail: "Every live registry record must resolve to one current binding.")])
            }
            let ids = before.records.map { "\($0.vendor.rawValue):\($0.durableResumeID)" }
            guard Set(ids).count == ids.count else {
                return result([.init(code: "conflicting_writers", detail: "A durable identity has more than one live binding.")])
            }
            let runtimeBlockers = validateRuntime()
            guard runtimeBlockers.isEmpty else { return result(runtimeBlockers) }
            phase = "publication_failed"
            try reconcile()
            guard try snapshot() == before else {
                return result([.init(code: "identity_changed", detail: "Runtime changed during reconciliation; take a fresh snapshot.")])
            }
            phase = "checkpoint_failed"
            let saved = try checkpoint()
            guard try snapshot() == before else {
                return result([.init(code: "identity_changed", detail: "Runtime changed during checkpoint; do not reuse this result.")], saved)
            }
            if saved["technical_ready"]?.boolValue != true {
                let blockers = saved["blockers"]?.arrayValue?.compactMap { value -> RestartBlocker? in
                    guard let object = value.objectValue, let code = object["code"]?.stringValue else { return nil }
                    return .init(code: code, detail: object["detail"]?.stringValue ?? "")
                } ?? []
                return result(blockers.isEmpty ? [.init(code: "checkpoint_failed", detail: "Native checkpoint did not confirm saved state.")] : blockers, saved)
            }
            return result([], saved)
        } catch {
            return result([.init(code: phase, detail: String(describing: error))])
        }
    }
}

private struct FreshRestartRegistryReader: RuntimeResumeAgentRegistryReading, @unchecked Sendable {
    let monitor: AgentSessionRegistryMonitor
    func readAgentRegistrySnapshot() throws -> RuntimeResumeAgentRegistrySnapshot {
        monitor.refreshRuntimeResumeEvidence()
    }
    func readAgentRecords() throws -> [RuntimeResumeAgentRegistryRecord] {
        monitor.refreshRuntimeResumeEvidence().records
    }
}

enum RestartPreparationCommand {
    static func failure(code: String, detail: String) -> Int32 {
        let result = RestartPreparationResult(sampledAt: ISO8601DateFormatter().string(from: Date()),
            technicalReady: false, blockers: [.init(code: code, detail: detail)], checkpoint: nil)
        if let data = try? JSONEncoder().encode(result) { print(String(decoding: data, as: UTF8.self)) }
        return 2
    }

    static func run(inspectOnly: Bool, ownerReceiptPath: String? = nil) -> Int32 {
        let receipt: RestartRetainedOwnerReceipt?
        do { receipt = try ownerReceiptPath.map { try RestartRetainedOwnerReceipt.load(path: $0) } }
        catch { return failure(code: "invalid_owner_receipt", detail: "Explicit owner receipt or its evidence could not be validated.") }
        let client = TideySocketClient(locator: TideySocketLocator())
        let projection = OrdinaryTmuxProjectionContext()
        let resolver = TideyOrdinaryTmuxCarrierResolver(socketClient: client)
        let monitor = AgentSessionRegistryMonitor(hub: AgentEventHub(), socketClient: client,
            ordinaryTmuxCarrierIdentityResolver: { resolver.carrierIdentity(for: $0) },
            livePanelListProjector: { projection.projector.projectPanelListResult($0) },
            restartOwnerReceipt: receipt)
        let reader = FreshRestartRegistryReader(monitor: monitor)
        let sender = TideyRuntimeResumeDescriptorSocketSender(requestSender: client)
        let publisher = RuntimeResumeDescriptorPublisher(registryReader: reader,
            topologyReader: OrdinaryTmuxRuntimeResumeTopologyReader(registry: projection.registry),
            carrierPlanner: OrdinaryTmuxRuntimeResumeCarrierPlanner(registry: projection.registry,
                                                                   sessionReader: OrdinaryTmuxCLIAdapter()),
            inventoryReconciler: sender, socketSender: sender)
        do {
            if inspectOnly {
                let snapshot = monitor.refreshRuntimeResumeEvidence()
                let runtimeBlockers = monitor.restartDurabilityBlockers()
                var object: [String: Any] = [
                    "schema": "tidey.restart-inventory/1", "complete": snapshot.isComplete,
                    "sampled_at": ISO8601DateFormatter().string(from: Date()),
                    "source_count": snapshot.sourceRecordCount,
                    "resolved_count": snapshot.resolvedCandidateCount,
                    "runtime_blockers": runtimeBlockers.map { ["code": $0.code, "detail": $0.detail] },
                    "non_restoring_records": snapshot.nonRestoringRecords.map {
                        ["session_id": $0.sessionID, "workspace_id": $0.workspaceID, "panel_id": $0.panelID,
                         "tmux_pane_id": $0.tmuxPaneID, "reason": $0.reason,
                         "vendor": $0.vendor, "durable_resume_id": $0.durableResumeID]
                    },
                    "records": snapshot.records.map { ["workspace_id": $0.binding.workspaceID,
                        "panel_id": $0.binding.panelID, "tmux_pane_id": $0.binding.tmuxPaneID ?? "",
                        "vendor": $0.vendor.rawValue, "durable_id": $0.durableResumeID] }
                ]
                if let receipt {
                    object["owner_receipt_sha256"] = receipt.sha256
                    object["owner_receipt_matched_session_ids"] = receipt.matchedSessionIDs(in: snapshot.nonRestoringRecords)
                }
                let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
                print(String(decoding: data, as: UTF8.self))
                return snapshot.isComplete && runtimeBlockers.isEmpty ? 0 : 2
            }
            let operation = RestartPreparation(snapshot: { try reader.readAgentRegistrySnapshot() },
                reconcile: { try publisher.reconcileForRestart() }, checkpoint: {
                    let inventory = try client.send(BridgeRequest(id: UUID().uuidString,
                        action: "list_runtime_resume_descriptors", params: nil))
                    guard inventory.ok, let descriptors = inventory.result?["descriptors"] else {
                        throw BridgeInternalError.invalidResponse
                    }
                    let response = try client.send(BridgeRequest(id: UUID().uuidString,
                        action: "checkpoint_for_restart", params: ["expected_descriptors": descriptors]))
                    guard response.ok, let result = response.result else {
                        throw BridgeInternalError.invalidResponse
                    }
                    return result
                }, validateRuntime: { monitor.restartDurabilityBlockers() })
            var result = operation.prepare()
            if let receipt {
                result.ownerReceiptSHA256 = receipt.sha256
                result.ownerReceiptMatchedSessionIDs = receipt.matchedSessionIDs(in: result.nonRestoringRecords)
            }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            print(String(decoding: try encoder.encode(result), as: UTF8.self))
            return result.technicalReady ? 0 : 2
        } catch {
            return failure(code: "inventory_unavailable", detail: String(describing: error))
        }
    }
}

enum RestartWriterEvidence {
    static func isSocketEndpoint(at path: String, fileManager: FileManager = .default) -> Bool {
        guard path.hasPrefix("/") else { return false }
        // Codex exposes app.sock as a symlink to its daemon endpoint. Inspect the
        // destination type; a missing, regular-file or directory target still fails.
        let endpoint = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        return (try? fileManager.attributesOfItem(atPath: endpoint)[.type] as? FileAttributeType) == .typeSocket
    }

    struct ProcessTable {
        let parents: [Int32: Int32]
        let agentPIDs: Set<Int32>

        func hasAgent(under root: Int32) -> Bool {
            agentPIDs.contains { pid in
                var current = pid
                var visited = Set<Int32>()
                while current > 1, visited.count < 64, visited.insert(current).inserted {
                    if current == root { return true }
                    guard let parent = parents[current] else { return false }
                    current = parent
                }
                return false
            }
        }
    }

    static func processTable() -> ProcessTable? {
        guard let result = BoundedProcessRunner.run(executablePath: "/bin/ps",
            arguments: ["-axo", "pid=,ppid=,comm="], timeout: 3), result.terminationStatus == 0,
              let output = String(data: result.standardOutput, encoding: .utf8) else { return nil }
        var parents = [Int32: Int32](); var agents = Set<Int32>()
        for line in output.split(separator: "\n") {
            let fields = line.split(maxSplits: 2, whereSeparator: \.isWhitespace)
            guard fields.count == 3, let pid = Int32(fields[0]), let parent = Int32(fields[1]) else { return nil }
            parents[pid] = parent
            let name = URL(fileURLWithPath: String(fields[2]).trimmingCharacters(in: .whitespaces)).lastPathComponent
            if name == "codex" || name == "claude" { agents.insert(pid) }
        }
        return ProcessTable(parents: parents, agentPIDs: agents)
    }

    static func parseWriterPIDs(_ text: String) -> Set<Int32> {
        var current: Int32?
        var writers = Set<Int32>()
        for line in text.split(separator: "\n") {
            if line.hasPrefix("p") { current = Int32(line.dropFirst()) }
            if (line == "aw" || line == "au"), let current { writers.insert(current) }
        }
        return writers
    }

    static func openWriterPIDs(path: String) -> Set<Int32>? {
        guard let result = BoundedProcessRunner.run(executablePath: "/usr/sbin/lsof",
            arguments: ["-nP", "-Fpa", "--", path], timeout: 3), result.terminationStatus == 0,
              let output = String(data: result.standardOutput, encoding: .utf8) else { return nil }
        return parseWriterPIDs(output)
    }
}

struct RestartPreparationArguments: Equatable {
    let inspectOnly: Bool
    let ownerReceiptPath: String?
    enum Invalid: Error { case arguments }
    static func parse(_ arguments: [String]) throws -> Self? {
        let names = ["--inspect-restart", "--prepare-for-restart", "--restart-owner-receipt"]
        guard arguments.contains(where: { arg in names.contains(where: { arg.hasPrefix($0) }) }) else { return nil }
        var operation: Bool?
        var receipt: String?
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--inspect-restart", "--prepare-for-restart":
                guard operation == nil else { throw Invalid.arguments }
                operation = arguments[index] == "--inspect-restart"
            case "--restart-owner-receipt":
                guard receipt == nil, index + 1 < arguments.count, arguments[index + 1].hasPrefix("/") else {
                    throw Invalid.arguments
                }
                index += 1; receipt = arguments[index]
            default: throw Invalid.arguments
            }
            index += 1
        }
        guard let operation else { throw Invalid.arguments }
        return .init(inspectOnly: operation, ownerReceiptPath: receipt)
    }
}
