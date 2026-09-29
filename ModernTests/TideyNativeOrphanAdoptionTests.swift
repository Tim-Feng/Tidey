import XCTest
@testable import iTerm2SharedARC

// Exact native orphan recovery (2026-09-25 incident). The fake reproduces the production shape:
// attaching really adds a second session to the carrier (optionally selected), and retirement
// really leaves one session holding the original GUID. Every refusal changes nothing; a new
// session that never acquired the child is the only thing ever discarded; once the original
// child is acquired it is never closed.
final class TideyNativeOrphanAdoptionTests: XCTestCase {
    private func request() -> TideyNativeOrphanAdoptionRequest {
        TideyNativeOrphanAdoptionRequest(dictionary: [
            "workspace_id": "WS", "carrier_panel_id": "CARRIER", "native_session_id": "GUID",
            "expected_shell_pid": NSNumber(value: 59674), "expected_shell_birth": "200",
            "daemon_pid": NSNumber(value: 772), "daemon_birth": "100", "daemon_socket_number": NSNumber(value: 1),
            "orphan_child_pid": NSNumber(value: 779), "orphan_child_birth": "101",
            "writer_pid": NSNumber(value: 18004), "writer_birth": "102",
            "descriptor_revision": NSNumber(value: 2), "durable_resume_id": "thread-current",
        ])!
    }

    private func run(_ env: FakeAdoptionEnvironment) -> [String: Any] {
        var result: [String: Any]?
        TideyNativeOrphanAdoption(environment: env).adopt(request()) { result = $0 }
        return result ?? [:]
    }

    private func status(_ result: [String: Any]) -> String? { result["status"] as? String }
    private func problems(_ result: [String: Any]) -> [String] { result["problems"] as? [String] ?? [] }

    func testMissingParametersAreRejected() {
        XCTAssertNil(TideyNativeOrphanAdoptionRequest(dictionary: ["workspace_id": "WS"]))
    }

    // Demonstrated failing-before case (controller-probe-f003): the real split has two sessions
    // and may select the new one; the old code re-ran the one-session preflight and stopped at
    // attached_pending_placement with native_session_guid_mismatch/carrier_not_single_session.
    func testRealSplitTransitionAdoptsWithNewSessionActive() {
        let env = FakeAdoptionEnvironment()
        env.newSessionBecomesActive = true
        let result = run(env)
        XCTAssertEqual(status(result), "adopted", "\(problems(result))")
        XCTAssertEqual(env.calls, ["unattached", "attach", "retire:GUID", "save"])
        XCTAssertEqual(env.sessions.count, 1)
        XCTAssertEqual(env.sessions[0].guid, "GUID")
        XCTAssertEqual(env.sessions[0].pid, 779)
    }

    func testRealSplitTransitionAdoptsWithReplacementStillActive() {
        let env = FakeAdoptionEnvironment()
        env.newSessionBecomesActive = false
        XCTAssertEqual(status(run(env)), "adopted")
    }

    func testChangedOrExtraSessionsAfterAttachKeepAttachmentWithoutRetiring() {
        let cases: [(String, (FakeAdoptionEnvironment) -> Void)] = [
            ("replacement replaced", { $0.sessions[0].pid = 60000 }),
            ("extra third session", { $0.sessions.append((guid: "OTHER", pid: 61000)) }),
            ("replacement no longer empty", { $0.children[59674] = [NSNumber(value: 62000)] }),
            ("inventory unavailable after attach", { $0.inventoryAvailable = false }),
            ("registry changed after attach", { $0.records.append($0.record(pid: 18005)) }),
        ]
        for (label, mutate) in cases {
            let env = FakeAdoptionEnvironment()
            env.afterAttach = mutate
            let result = run(env)
            XCTAssertEqual(status(result), "attached_pending_placement", label)
            XCTAssertEqual(env.calls, ["unattached", "attach"], label)
        }
    }

    func testFinalPlacementMustResolveGuidToAdoptedSession() {
        let env = FakeAdoptionEnvironment()
        env.guidMapPIDAfterRetire = 59674  // retiring object still owns the GUID mapping
        let result = run(env)
        XCTAssertEqual(status(result), "attached_pending_placement")
        XCTAssertTrue(problems(result).contains("native_guid_does_not_resolve_to_adopted_session"))
        XCTAssertFalse(env.calls.contains("save"))
    }

    func testRegistryIdentityProof() {
        let cases: [(String, (FakeAdoptionEnvironment) -> Void, String)] = [
            ("unrelated process under the orphan", { env in
                env.parents[18099] = 779; env.births[18099] = "103"; env.writerOverride = 18099 },
             "registry_writer_pid_mismatch"),
            ("registry holds another current durable", { env in
                env.records = [env.record(durable: "thread-newer")] }, "registry_writer_missing"),
            ("duplicate live writer", { env in
                env.records.append(env.record(pid: 18005)) }, "registry_duplicate_writer"),
            ("alias on the same panel", { env in
                env.records.append(env.record(durable: "other-session", vendor: "claude", pid: 18006)) },
             "registry_conflicting_identity"),
            ("writer bound to another panel", { env in
                env.records = [env.record(panel: "native-session:OTHER:X")] }, "registry_binding_mismatch"),
            ("registry unreadable", { env in env.recordsAvailable = false }, "registry_unavailable"),
        ]
        for (label, mutate, expected) in cases {
            let env = FakeAdoptionEnvironment()
            mutate(env)
            var result: [String: Any]?
            let request = env.writerOverride.map { pid -> TideyNativeOrphanAdoptionRequest in
                var dict = Self.dictionary()
                dict["writer_pid"] = NSNumber(value: pid)
                dict["writer_birth"] = env.births[pid]!
                return TideyNativeOrphanAdoptionRequest(dictionary: dict)!
            } ?? self.request()
            TideyNativeOrphanAdoption(environment: env).adopt(request) { result = $0 }
            XCTAssertEqual(status(result ?? [:]), "refused", label)
            XCTAssertTrue(problems(result ?? [:]).contains(expected), "\(label): \(problems(result ?? [:]))")
            XCTAssertEqual(env.calls, [], label)
        }
        // bare-carrier panel binding is the other accepted registry form
        let env = FakeAdoptionEnvironment()
        env.records = [env.record(panel: "CARRIER")]
        XCTAssertEqual(status(run(env)), "adopted")
    }

    func testUnavailableProcessInventoryRefusesBeforeMutation() {
        let env = FakeAdoptionEnvironment()
        env.inventoryAvailable = false
        let result = run(env)
        XCTAssertEqual(status(result), "refused")
        XCTAssertTrue(problems(result).contains("process_inventory_unavailable"))
        XCTAssertEqual(env.calls, [])
    }

    func testAbsentOrphanRefusesWithoutAttaching() {
        let env = FakeAdoptionEnvironment()
        env.unattached = [NSNumber(value: 12345)]
        XCTAssertEqual(status(run(env)), "refused")
        XCTAssertEqual(env.calls, ["unattached"])
    }

    func testReusedOrChangedIdentitiesRefuseWithZeroMutation() {
        let cases: [(String, (FakeAdoptionEnvironment) -> Void)] = [
            ("shell reused", { $0.births[59674] = "999" }),
            ("orphan reused", { $0.births[779] = "999" }),
            ("writer reused", { $0.births[18004] = "999" }),
            ("writer moved", { $0.parents[18004] = 1 }),
            ("orphan not under daemon", { $0.parents[779] = 1 }),
            ("daemon replaced", { $0.births[772] = "999" }),
            ("descriptor revision conflict", { $0.descriptorRevision = 3 }),
            ("descriptor durable conflict", { $0.durable = "thread-old" }),
            ("guid differs", { $0.sessions[0].guid = "OTHER" }),
            ("replacement not empty", { $0.children[59674] = [NSNumber(value: 60000)] }),
            ("carrier split already", { $0.sessions.append((guid: "X", pid: 1234)) }),
            ("carrier missing", { $0.carrierMissing = true }),
        ]
        for (label, mutate) in cases {
            let env = FakeAdoptionEnvironment()
            mutate(env)
            XCTAssertEqual(status(run(env)), "refused", label)
            XCTAssertEqual(env.calls, [], label)
        }
    }

    func testAttachFailureBeforeAcquisitionDiscardsOnlyTheNewSession() {
        let env = FakeAdoptionEnvironment()
        env.acquired = 0
        XCTAssertEqual(status(run(env)), "failed")
        XCTAssertEqual(env.calls, ["unattached", "attach", "discard"])
        XCTAssertEqual(env.sessions.count, 1)
    }

    func testFailureAtRetirementKeepsTheOriginalAttached() {
        let env = FakeAdoptionEnvironment()
        env.retireError = "process_inventory_unavailable"
        let result = run(env)
        XCTAssertEqual(status(result), "attached_pending_placement")
        XCTAssertEqual((result["acquired_pid"] as? NSNumber)?.int32Value, 779)
        XCTAssertFalse(env.calls.contains("discard"), "an acquired original is never closed")
    }

    func testUnexpectedAcquiredPidIsKeptNotClosed() {
        let env = FakeAdoptionEnvironment()
        env.acquired = 4242
        XCTAssertEqual(status(run(env)), "attached_pending_placement")
        XCTAssertEqual(env.calls, ["unattached", "attach"])
    }

    func testRepeatedRequestAfterAdoptionRefuses() {
        let env = FakeAdoptionEnvironment()
        XCTAssertEqual(status(run(env)), "adopted")
        env.calls = []
        XCTAssertEqual(status(run(env)), "refused")
        XCTAssertEqual(env.calls, [])
    }

    // MARK: - Already attached by the startup orphan adopter (2026-09-25 09:45 launch)

    private func alreadyAttachedEnv() -> FakeAdoptionEnvironment {
        let env = FakeAdoptionEnvironment()
        env.sourceSessions = [(guid: "SRC-GUID", pid: 779)]
        env.unattached = []  // the child is attached elsewhere, never "unattached"
        return env
    }

    private func alreadyAttachedRequest(_ changes: [String: Any] = [:]) -> TideyNativeOrphanAdoptionRequest? {
        var dict = Self.dictionary()
        dict["source_workspace_id"] = "SRC-WS"
        dict["source_carrier_panel_id"] = "SRC-CARRIER"
        dict["source_native_session_id"] = "SRC-GUID"
        dict["source_descriptor_revision"] = NSNumber(value: 1)
        changes.forEach { dict[$0.key] = $0.value }
        return TideyNativeOrphanAdoptionRequest(dictionary: dict)
    }

    private func runAttached(_ env: FakeAdoptionEnvironment,
                             _ request: TideyNativeOrphanAdoptionRequest? = nil) -> [String: Any] {
        var result: [String: Any]?
        TideyNativeOrphanAdoption(environment: env).adopt(request ?? alreadyAttachedRequest()!) { result = $0 }
        return result ?? [:]
    }

    func testAlreadyAttachedOriginalIsMovedIntoTargetAndSourceRemoved() {
        let env = alreadyAttachedEnv()
        let result = runAttached(env)
        XCTAssertEqual(status(result), "adopted", "\(problems(result))")
        XCTAssertEqual(env.calls, ["move", "retire:GUID", "save"], "no direct descriptor deletion")
        XCTAssertEqual(env.sessions.map { $0.guid }, ["GUID"])
        XCTAssertEqual(env.sessions.map { $0.pid }, [779])
        XCTAssertEqual(env.shellPIDForSessionGUID("GUID"), 779, "original target GUID maps to 779")
        XCTAssertEqual(env.workspacePanelCount("SRC-WS"), -1, "auto-created source workspace gone")
        XCTAssertEqual(env.listedDescriptorRevision(carrierPanelID: "SRC-CARRIER"), 0,
                       "the sole accidental source's descriptor is no longer listed once its panel is gone")
        XCTAssertEqual(env.otherWorkspaces, ["W-ALFRED": 2, "W-TIDEY": 2], "other workspaces intact")
        XCTAssertTrue(env.alive.contains(779) && env.alive.contains(18004), "original never terminated")
    }

    func testAlreadyAttachedRejectsAmbiguousOrModifiedSourceWithZeroMutation() {
        let cases: [(String, (FakeAdoptionEnvironment) -> Void)] = [
            ("source carrier holds two sessions", { $0.sourceSessions?.append((guid: "X", pid: 5555)) }),
            ("source workspace has other panels", { $0.sourceWorkspacePanels = 2 }),
            ("source session is not the original child", { $0.sourceSessions = [(guid: "SRC-GUID", pid: 5555)] }),
            ("source GUID changed", { $0.sourceSessions = [(guid: "OTHER", pid: 779)] }),
            ("source descriptor wrong revision", { $0.sourceDescriptorRevision = 2 }),
            ("source descriptor other durable", { $0.sourceDescriptorDurable = "thread-other" }),
            ("source descriptor other vendor", { $0.sourceDescriptorVendor = .claude }),
            ("source missing", { $0.sourceSessions = nil }),
            ("another live writer", { $0.records.append($0.record(pid: 18005)) }),
            ("no child inventory", { $0.inventoryAvailable = false }),
            ("replacement no longer empty", { $0.children[59674] = [NSNumber(value: 60000)] }),
        ]
        for (label, mutate) in cases {
            let env = alreadyAttachedEnv()
            mutate(env)
            XCTAssertEqual(status(runAttached(env)), "refused", label)
            XCTAssertEqual(env.calls, [], label)
        }
    }

    func testAlreadyAttachedSourceOfAnotherVendorIsNotTheDuplicate() {
        let env = alreadyAttachedEnv()
        env.sourceDescriptorVendor = .claude
        let result = runAttached(env)
        XCTAssertEqual(status(result), "refused")
        XCTAssertEqual(problems(result), ["source_descriptor_identity_mismatch"])
        XCTAssertEqual(env.calls, [])
    }

    func testAlreadyAttachedPartialSourceFenceIsInvalid() {
        var dict = Self.dictionary()
        dict["source_carrier_panel_id"] = "SRC-CARRIER"
        XCTAssertNil(TideyNativeOrphanAdoptionRequest(dictionary: dict))
    }

    // The ordinary pending-removal protection stays: the real gate still rejects removing a
    // restored descriptor that has no runtime evidence (what follow-up 005 relied on).
    func testRestoredSourceDescriptorStillRejectsDirectRemoval() {
        let env = alreadyAttachedEnv()
        XCTAssertEqual(env.removeDuplicateDescriptor(workspaceID: "SRC-WS", carrierPanelID: "SRC-CARRIER",
                                                     expectedRevision: 1),
                       "source_descriptor_removal_rejected:runtime_rehydration_pending")
        XCTAssertEqual(env.listedDescriptorRevision(carrierPanelID: "SRC-CARRIER"), 1)
    }

    func testRestoredPendingSourceIsCleanedUpByOrdinaryOwnershipAfterMove() {
        let env = alreadyAttachedEnv()
        XCTAssertTrue(env.sourceDescriptorRestoredPending)
        let result = runAttached(env)
        XCTAssertEqual(status(result), "adopted", "\(problems(result))")
        XCTAssertEqual(env.sessions.map { $0.pid }, [779])
        XCTAssertEqual(env.shellPIDForSessionGUID("GUID"), 779)
        XCTAssertEqual(env.listedDescriptorRevision(carrierPanelID: "SRC-CARRIER"), 0)
        XCTAssertTrue(env.alive.contains(779))
    }

    func testInvalidOrEmptySourceFieldsAreRejectedNotIgnored() {
        for (key, value) in [("source_workspace_id", "" as Any), ("source_descriptor_revision", NSNumber(value: 0)),
                             ("source_native_session_id", NSNumber(value: 5))] {
            var dict = Self.dictionary()
            dict[key] = value
            XCTAssertNil(TideyNativeOrphanAdoptionRequest(dictionary: dict), key)
        }
        XCTAssertNil(alreadyAttachedRequest(["source_carrier_panel_id": ""]))
    }

    func testAlreadyAttachedFailuresAfterMoveKeepOriginalAttached() {
        let cases: [(String, (FakeAdoptionEnvironment) -> Void, String)] = [
            ("move refused", { $0.moveFails = true }, "move"),
            ("source window survived", { $0.sourceSurvivesMove = true }, "source_removal"),
            ("source descriptor still listed", { $0.sourceDescriptorListedAfterMove = true }, "source_removal"),
            ("topology changed after move", { env in env.afterAttach = { $0.sessions.append((guid: "Z", pid: 1)) } },
             "post_attach_validation"),
        ]
        for (label, mutate, phase) in cases {
            let env = alreadyAttachedEnv()
            mutate(env)
            let result = runAttached(env)
            XCTAssertEqual(status(result), "attached_pending_placement", label)
            XCTAssertEqual(result["phase"] as? String, phase, label)
            XCTAssertFalse(env.calls.contains("discard") || env.calls.contains { $0.hasPrefix("retire") }, label)
            XCTAssertTrue(env.alive.contains(779), label)
            if phase == "move" {
                XCTAssertEqual(env.shellPIDForSessionGUID("GUID"), 59674, "target untouched: \(label)")
            }
        }
    }

    func testSourceDescriptorStillListedAfterMoveIsReportedNotAdopted() {
        let env = alreadyAttachedEnv()
        env.sourceDescriptorListedAfterMove = true
        let result = runAttached(env)
        XCTAssertEqual(status(result), "attached_pending_placement")
        XCTAssertEqual(problems(result), ["source_descriptor_still_listed"])
        XCTAssertEqual(env.calls, ["move"])
        XCTAssertTrue(env.alive.contains(779))
    }

    func testRelaunchedAdopterWithNewSourceIdsIsRefusedUntilRefenced() {
        // A later GUI relaunch may adopt again under new IDs; stale fences never match.
        let env = alreadyAttachedEnv()
        env.sourceSessions = [(guid: "NEWER-GUID", pid: 779)]
        XCTAssertEqual(status(runAttached(env)), "refused")
        XCTAssertEqual(env.calls, [])
    }

    private static func dictionary() -> [String: Any] {
        ["workspace_id": "WS", "carrier_panel_id": "CARRIER", "native_session_id": "GUID",
         "expected_shell_pid": NSNumber(value: 59674), "expected_shell_birth": "200",
         "daemon_pid": NSNumber(value: 772), "daemon_birth": "100", "daemon_socket_number": NSNumber(value: 1),
         "orphan_child_pid": NSNumber(value: 779), "orphan_child_birth": "101",
         "writer_pid": NSNumber(value: 18004), "writer_birth": "102",
         "descriptor_revision": NSNumber(value: 2), "durable_resume_id": "thread-current"]
    }
}

private final class FakeAdoptionEnvironment: NSObject, TideyNativeOrphanAdoptionEnvironment {
    var calls = [String]()
    var sessions: [(guid: String, pid: Int32)] = [(guid: "GUID", pid: 59674)]
    var births: [Int32: String] = [59674: "200", 772: "100", 779: "101", 18004: "102"]
    var parents: [Int32: Int32] = [779: 772, 18004: 779, 59674: 772]
    var children: [Int32: [NSNumber]] = [:]
    var inventoryAvailable = true
    var records = [[String: Any]]()
    var recordsAvailable = true
    var unattached: [NSNumber]? = [NSNumber(value: 779)]
    var acquired: Int32 = 779
    var newSessionBecomesActive = true
    var retireError: String?
    var guidMapPIDAfterRetire: Int32?
    var afterAttach: ((FakeAdoptionEnvironment) -> Void)?
    var descriptorRevision: Int64 = 2
    var durable = "thread-current"
    var carrierMissing = false
    var writerOverride: Int32?

    override init() {
        super.init()
        records = [record()]
    }

    func record(durable: String = "thread-current", vendor: String = "codex", pid: Int32 = 18004,
                panel: String = "native-session:CARRIER:GUID") -> [String: Any] {
        ["vendor": vendor, "durable_id": durable, "workspace_id": "WS", "panel_id": panel,
         "pid": NSNumber(value: pid)]
    }

    // Already-attached branch: the startup adopter put the original child in its own window.
    var sourceSessions: [(guid: String, pid: Int32)]? = nil
    var sourceWorkspacePanels = 1
    // The source descriptor lives in a REAL descriptor gate, restored from saved state as awaiting
    // runtime evidence, exactly as the next GUI launch restores the auto-created window's root.
    var sourceDescriptorRevision: Int64 = 1
    var sourceDescriptorDurable = "thread-current"
    var sourceDescriptorVendor: TideyRuntimeAgentVendor = .codex
    var sourceDescriptorRestoredPending = true
    private(set) lazy var sourceGate: TideyRuntimeResumeDescriptorUpdateGate = {
        let descriptor = TideyRuntimeResumeDescriptor(
            descriptorVersion: TideyRuntimeResumeDescriptor.currentDescriptorVersion,
            revision: sourceDescriptorRevision, kind: .agent, restorePolicy: .directResume,
            target: nil, topology: nil,
            agent: TideyRuntimeAgentResumeSpecification(
                vendor: sourceDescriptorVendor, durableResumeID: sourceDescriptorDurable,
                launch: sourceDescriptorVendor == .claude
                    ? TideyRuntimeLaunchSpecification(executable: "claude",
                                                      arguments: ["--resume", sourceDescriptorDurable],
                                                      workingDirectory: "/tmp")
                    : TideyRuntimeLaunchSpecification(executable: "codex",
                                                      arguments: ["resume", sourceDescriptorDurable],
                                                      workingDirectory: "/tmp")))
        if sourceDescriptorRestoredPending {
            let gate = TideyRuntimeResumeDescriptorUpdateGate(initialDescriptorsByPanelID: [:])
            gate.restoreDescriptorsByPanelIDAwaitingRuntimeEvidence(["SRC-CARRIER": descriptor])
            return gate
        }
        return TideyRuntimeResumeDescriptorUpdateGate(initialDescriptorsByPanelID: ["SRC-CARRIER": descriptor])
    }()

    /// Simulates an owner that still lists the source panel after the move.
    var sourceDescriptorListedAfterMove = false
    private var sourcePanelMap: [String: String] {
        sourceSessions == nil && !sourceDescriptorListedAfterMove ? [:] : ["SRC-CARRIER": "SRC-WS"]
    }

    func sourceSnapshot() -> [String: Any]? {
        sourceGate.runtimeAgentDescriptorSnapshots(currentWorkspaceIDByPanelID: sourcePanelMap)
            .first { (($0["binding"] as? [String: Any])?["panel_id"] as? String) == "SRC-CARRIER" }
    }

    func listedDescriptorRevision(carrierPanelID: String) -> Int64 {
        guard carrierPanelID == "SRC-CARRIER" else { return 0 }
        return (sourceSnapshot()?["revision"] as? NSNumber)?.int64Value ?? 0
    }
    var moveFails = false
    var sourceSurvivesMove = false
    var otherWorkspaces = ["W-ALFRED": 2, "W-TIDEY": 2]
    var alive: Set<Int32> = [779, 18004, 59674]

    func carrierSessions(workspaceID: String, carrierPanelID: String) -> [[String: Any]]? {
        if carrierPanelID == "SRC-CARRIER" {
            guard workspaceID == "SRC-WS", let sourceSessions else { return nil }
            return sourceSessions.map { ["session_guid": $0.guid, "shell_pid": NSNumber(value: $0.pid)] }
        }
        guard !carrierMissing, workspaceID == "WS", carrierPanelID == "CARRIER" else { return nil }
        return sessions.map { ["session_guid": $0.guid, "shell_pid": NSNumber(value: $0.pid)] }
    }

    func workspacePanelCount(_ workspaceID: String) -> Int {
        if workspaceID == "SRC-WS" { return sourceSessions == nil ? -1 : sourceWorkspacePanels }
        if workspaceID == "WS" { return 1 }
        return otherWorkspaces[workspaceID] ?? -1
    }

    /// Follow-up 005 removal-first path, kept only to demonstrate its failure against the real
    /// gate (the corrected core no longer calls it).
    func removeDuplicateDescriptor(workspaceID: String, carrierPanelID: String, expectedRevision: Int64) -> String? {
        guard let snapshot = sourceSnapshot() else { return "source_descriptor_snapshot_mismatch" }
        let payload: [String: Any] = ["binding": snapshot["binding"]!, "expected_revision": snapshot["revision"]!,
                                      "expected_descriptor": snapshot["descriptor"]!]
        let result = sourceGate.removeRuntimeAgentDescriptorPayload(payload, currentWorkspaceID: workspaceID,
                                                                    currentPanelID: carrierPanelID)
        guard result.accepted, result.changed else {
            return "source_descriptor_removal_rejected:\(result.errorCode ?? "")"
        }
        calls.append("remove-source-descriptor")
        return nil
    }

    func moveAttachedSession(sourceCarrierPanelID: String, sessionGUID: String,
                             targetCarrierPanelID: String) -> NSObject? {
        guard !moveFails, let moving = sourceSessions?.first(where: { $0.guid == sessionGUID }) else { return nil }
        calls.append("move")
        if !sourceSurvivesMove { sourceSessions = nil }
        sessions.insert(moving, at: 0)
        afterAttach?(self)
        return NSObject()
    }

    func shellPIDForSessionGUID(_ guid: String) -> Int32 {
        if let forced = guidMapPIDAfterRetire, calls.contains("retire:\(guid)") { return forced }
        return sessions.first { $0.guid == guid }?.pid ?? 0
    }

    func descriptor(carrierPanelID: String) -> TideyRuntimeResumeDescriptor? {
        if carrierPanelID == "SRC-CARRIER" {
            return sourceGate.descriptor(forPanelID: "SRC-CARRIER")
        }
        return TideyRuntimeResumeDescriptor(
            descriptorVersion: TideyRuntimeResumeDescriptor.currentDescriptorVersion,
            revision: descriptorRevision, kind: .agent, restorePolicy: .directResume,
            target: nil, topology: nil,
            agent: TideyRuntimeAgentResumeSpecification(
                vendor: .codex, durableResumeID: durable,
                launch: TideyRuntimeLaunchSpecification(executable: "codex", arguments: ["resume", durable],
                                                        workingDirectory: "/tmp")))
    }

    func liveRegistryRecords() -> [[String: Any]]? { recordsAvailable ? records : nil }
    func processBirth(_ pid: Int32) -> String? { births[pid] }
    func parentPID(_ pid: Int32) -> Int32 { parents[pid] ?? -1 }
    func childPIDs(_ pid: Int32) -> [NSNumber]? { inventoryAvailable ? (children[pid] ?? []) : nil }

    func unattachedChildren(socketNumber: Int32, completion: @escaping ([NSNumber]?) -> Void) {
        calls.append("unattached")
        completion(unattached)
    }

    func attachSplit(carrierPanelID: String, socketNumber: Int32, childPID: Int32,
                     completion: @escaping (NSObject?, Int32) -> Void) {
        calls.append("attach")
        if acquired > 0 {
            let adopted = (guid: "NEW-GUID", pid: acquired)
            if newSessionBecomesActive {
                sessions.insert(adopted, at: 0)
            } else {
                sessions.append(adopted)
            }
        }
        afterAttach?(self)
        completion(NSObject(), acquired)
    }

    func discardUnattached(_ session: NSObject) { calls.append("discard") }

    func retireReplacedSession(carrierPanelID: String, expectedShellPID: Int32, adopted: NSObject,
                               guid: String) -> String? {
        if let retireError { return retireError }
        calls.append("retire:\(guid)")
        sessions = sessions.filter { $0.pid != expectedShellPID }.map { (guid: guid, pid: $0.pid) }
        return nil
    }

    func saveRestorableState() { calls.append("save") }
}
