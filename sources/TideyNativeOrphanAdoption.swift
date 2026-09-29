import Darwin
import Foundation

// Exact recovery of ONE orphaned native agent session after a GUI restart relaunched its panel
// (2026-09-25: the direct_resume reducer defect). The original job survives as an unattached
// child of the iTermServer multiserver daemon; this operation attaches that exact child in a
// temporary split of its original carrier, and only after the child is proven acquired retires
// the verified-empty replacement shell and hands the original native session GUID to the
// adopted session. It never terminates or detaches the original job. Every live effect goes
// through TideyNativeOrphanAdoptionEnvironment so ModernTests can drive each phase.

@objc(TideyNativeOrphanAdoptionEnvironment)
protocol TideyNativeOrphanAdoptionEnvironment: NSObjectProtocol {
    /// Every session of the carrier's tab in the given workspace, each as
    /// {session_guid: String, shell_pid: NSNumber}; nil when the carrier is not found.
    func carrierSessions(workspaceID: String, carrierPanelID: String) -> [[String: Any]]?
    /// shell pid of the session the global GUID map resolves for `guid`; 0 when none.
    func shellPIDForSessionGUID(_ guid: String) -> Int32
    func descriptor(carrierPanelID: String) -> TideyRuntimeResumeDescriptor?
    /// Live agent registry records (metadata only) as {vendor, durable_id, workspace_id,
    /// panel_id, pid}; nil when the registry cannot be read completely.
    func liveRegistryRecords() -> [[String: Any]]?
    func processBirth(_ pid: Int32) -> String?
    func parentPID(_ pid: Int32) -> Int32
    /// Child pids, or nil when the process inventory could not be read (never "empty").
    func childPIDs(_ pid: Int32) -> [NSNumber]?
    func unattachedChildren(socketNumber: Int32, completion: @escaping ([NSNumber]?) -> Void)
    /// Attach a new session to the multiserver child in a split next to the carrier's session.
    /// Completion: the new session object (or nil) and the pid its task actually acquired (0 if none).
    func attachSplit(carrierPanelID: String, socketNumber: Int32, childPID: Int32,
                     completion: @escaping (NSObject?, Int32) -> Void)
    /// Close a new session that never acquired a job.
    func discardUnattached(_ session: NSObject)
    /// Re-verify the old session is still the exact empty shell, move it to a throwaway GUID,
    /// close it normally, give `guid` to the adopted session and select it. Returns an error or nil.
    func retireReplacedSession(carrierPanelID: String, expectedShellPID: Int32, adopted: NSObject,
                               guid: String) -> String?
    /// The owner's normal restorable-state invalidation (marks the Tidey dirty tracker).
    func saveRestorableState()

    // Already-attached branch: the startup orphan adopter placed the original child in a new
    // workspace/carrier before the recovery request.
    /// Number of panels in the workspace, or -1 when the workspace does not exist.
    func workspacePanelCount(_ workspaceID: String) -> Int
    /// Revision of the agent descriptor the owners currently list for this carrier (only existing
    /// panels are listed or persisted); 0 when none is listed.
    func listedDescriptorRevision(carrierPanelID: String) -> Int64
    /// Move the existing session with `sessionGUID` out of the source carrier (closing that tab
    /// only if it becomes empty) into a split next to the target carrier's session, using the
    /// ordinary move-pane owner sequence. Returns the moved session or nil.
    func moveAttachedSession(sourceCarrierPanelID: String, sessionGUID: String,
                             targetCarrierPanelID: String) -> NSObject?
}

@objc(TideyNativeOrphanAdoptionRequest)
@objcMembers
final class TideyNativeOrphanAdoptionRequest: NSObject {
    let workspaceID: String
    let carrierPanelID: String
    let nativeSessionGUID: String
    let expectedShellPID: Int32
    let expectedShellBirth: String
    let daemonPID: Int32
    let daemonBirth: String
    let daemonSocketNumber: Int32
    let orphanChildPID: Int32
    let orphanChildBirth: String
    let writerPID: Int32
    let writerBirth: String
    let descriptorRevision: Int64
    let durableResumeID: String
    /// Present only for the already-attached branch; all four or none.
    let sourceWorkspaceID: String?
    let sourceCarrierPanelID: String?
    let sourceNativeSessionGUID: String?
    let sourceDescriptorRevision: Int64

    var isAlreadyAttached: Bool { sourceCarrierPanelID != nil }

    var logicalPanelID: String { "native-session:\(carrierPanelID):\(nativeSessionGUID)" }

    init?(dictionary: [String: Any]) {
        func string(_ key: String) -> String? {
            (dictionary[key] as? String).flatMap { $0.isEmpty ? nil : $0 }
        }
        func pid(_ key: String) -> Int32? {
            (dictionary[key] as? NSNumber).map { $0.int32Value }.flatMap { $0 > 1 ? $0 : nil }
        }
        guard let workspaceID = string("workspace_id"),
              let carrierPanelID = string("carrier_panel_id"),
              let nativeSessionGUID = string("native_session_id"),
              let expectedShellPID = pid("expected_shell_pid"),
              let expectedShellBirth = string("expected_shell_birth"),
              let daemonPID = pid("daemon_pid"),
              let daemonBirth = string("daemon_birth"),
              let socket = dictionary["daemon_socket_number"] as? NSNumber, socket.int32Value >= 0,
              let orphanChildPID = pid("orphan_child_pid"),
              let orphanChildBirth = string("orphan_child_birth"),
              let writerPID = pid("writer_pid"),
              let writerBirth = string("writer_birth"),
              let revision = dictionary["descriptor_revision"] as? NSNumber, revision.int64Value > 0,
              let durableResumeID = string("durable_resume_id") else {
            return nil
        }
        let sourceKeys = ["source_workspace_id", "source_carrier_panel_id", "source_native_session_id",
                          "source_descriptor_revision"]
        let sourceWorkspaceID = string("source_workspace_id")
        let sourceCarrierPanelID = string("source_carrier_panel_id")
        let sourceNativeSessionGUID = string("source_native_session_id")
        let sourceRevision = (dictionary["source_descriptor_revision"] as? NSNumber)?.int64Value ?? 0
        let sourceValid = [sourceWorkspaceID != nil, sourceCarrierPanelID != nil,
                           sourceNativeSessionGUID != nil, sourceRevision > 0]
        let sourcePresent = sourceKeys.map { dictionary[$0] != nil }
        // Any supplied source field must be valid, and it is all four or none: an empty or
        // invalid field is rejected, never read as "no source".
        guard sourceValid == sourcePresent,
              sourcePresent.allSatisfy({ $0 }) || sourcePresent.allSatisfy({ !$0 }) else {
            return nil
        }
        guard sourceCarrierPanelID != carrierPanelID, sourceNativeSessionGUID != nativeSessionGUID ||
                sourceNativeSessionGUID == nil else {
            return nil
        }
        self.sourceWorkspaceID = sourceWorkspaceID
        self.sourceCarrierPanelID = sourceCarrierPanelID
        self.sourceNativeSessionGUID = sourceNativeSessionGUID
        self.sourceDescriptorRevision = sourceRevision
        self.workspaceID = workspaceID
        self.carrierPanelID = carrierPanelID
        self.nativeSessionGUID = nativeSessionGUID
        self.expectedShellPID = expectedShellPID
        self.expectedShellBirth = expectedShellBirth
        self.daemonPID = daemonPID
        self.daemonBirth = daemonBirth
        self.daemonSocketNumber = socket.int32Value
        self.orphanChildPID = orphanChildPID
        self.orphanChildBirth = orphanChildBirth
        self.writerPID = writerPID
        self.writerBirth = writerBirth
        self.descriptorRevision = revision.int64Value
        self.durableResumeID = durableResumeID
    }
}

@objc(TideyNativeOrphanAdoption)
@objcMembers
final class TideyNativeOrphanAdoption: NSObject {
    private let environment: TideyNativeOrphanAdoptionEnvironment
    private var inProgress = false

    init(environment: TideyNativeOrphanAdoptionEnvironment) {
        self.environment = environment
    }

    /// Result keys: status (refused | failed | attached_pending_placement | adopted), phase,
    /// problems, acquired_pid, native_session_id. Only "adopted" means the placement finished.
    func adopt(_ request: TideyNativeOrphanAdoptionRequest,
               completion: @escaping ([String: Any]) -> Void) {
        guard !inProgress else {
            completion(Self.result("refused", "preflight", ["adoption_already_in_progress"]))
            return
        }
        let problems = beforeAttachProblems(request)
        guard problems.isEmpty else {
            completion(Self.result("refused", "preflight", problems))
            return
        }
        inProgress = true
        if request.isAlreadyAttached {
            adoptAlreadyAttached(request, completion: completion)
            return
        }
        environment.unattachedChildren(socketNumber: request.daemonSocketNumber) { [weak self] children in
            guard let self else { return }
            guard let children, children.contains(where: { $0.int32Value == request.orphanChildPID }) else {
                self.finish(completion, Self.result("refused", "orphan_availability",
                                                    ["orphan_child_not_unattached_on_daemon_socket"]))
                return
            }
            let again = self.beforeAttachProblems(request)
            guard again.isEmpty else {
                self.finish(completion, Self.result("refused", "revalidation", again))
                return
            }
            self.environment.attachSplit(carrierPanelID: request.carrierPanelID,
                                         socketNumber: request.daemonSocketNumber,
                                         childPID: request.orphanChildPID) { session, acquired in
                self.afterAttach(request, session: session, acquired: acquired, completion: completion)
            }
        }
    }

    private func afterAttach(_ request: TideyNativeOrphanAdoptionRequest,
                             session: NSObject?,
                             acquired: Int32,
                             completion: @escaping ([String: Any]) -> Void) {
        guard let session, acquired > 0 else {
            // Never acquired a job: removing the new split is safe; the carrier is untouched.
            if let session {
                environment.discardUnattached(session)
            }
            finish(completion, Self.result("failed", "attach", ["orphan_not_acquired"]))
            return
        }
        guard acquired == request.orphanChildPID else {
            // Some job was acquired, but not the expected one: never close it.
            finish(completion, Self.result("attached_pending_placement", "attach",
                                           ["unexpected_acquired_pid"], acquired: acquired))
            return
        }
        // The original child is attached. From here nothing may close or detach it.
        let problems = afterAttachProblems(request)
        guard problems.isEmpty else {
            finish(completion, Self.result("attached_pending_placement", "post_attach_validation",
                                           problems, acquired: acquired))
            return
        }
        if let error = environment.retireReplacedSession(carrierPanelID: request.carrierPanelID,
                                                         expectedShellPID: request.expectedShellPID,
                                                         adopted: session,
                                                         guid: request.nativeSessionGUID) {
            finish(completion, Self.result("attached_pending_placement", "retire_replacement",
                                           [error], acquired: acquired))
            return
        }
        let final = finalPlacementProblems(request)
        guard final.isEmpty else {
            finish(completion, Self.result("attached_pending_placement", "final_placement", final,
                                           acquired: acquired))
            return
        }
        environment.saveRestorableState()
        var result = Self.result("adopted", "complete", [], acquired: acquired)
        result["native_session_id"] = request.nativeSessionGUID
        result["carrier_panel_id"] = request.carrierPanelID
        result["final_sessions"] = environment.carrierSessions(workspaceID: request.workspaceID,
                                                               carrierPanelID: request.carrierPanelID) ?? []
        finish(completion, result)
    }

    /// The startup orphan adopter already attached the original child in exactly one proven
    /// auto-created source carrier. Move the existing session (no re-attach) next to the target's
    /// empty replacement; the emptied sole source tab closes through the ordinary move-pane owner
    /// (removing its workspace/window), and with its panel gone the source's duplicate
    /// descriptor is no longer listed or persisted. No descriptor is deleted directly, so a
    /// restored source descriptor still awaiting runtime evidence needs no acknowledgement.
    private func adoptAlreadyAttached(_ request: TideyNativeOrphanAdoptionRequest,
                                      completion: @escaping ([String: Any]) -> Void) {
        let sourceWorkspaceID = request.sourceWorkspaceID!, sourceCarrier = request.sourceCarrierPanelID!
        guard let moved = environment.moveAttachedSession(sourceCarrierPanelID: sourceCarrier,
                                                          sessionGUID: request.sourceNativeSessionGUID!,
                                                          targetCarrierPanelID: request.carrierPanelID) else {
            // Nothing moved: the original stays attached in place and nothing was removed.
            finish(completion, Self.result("attached_pending_placement", "move",
                                           ["move_not_performed"], acquired: request.orphanChildPID))
            return
        }
        var extra = [String]()
        if environment.workspacePanelCount(sourceWorkspaceID) != -1 {
            extra.append("source_workspace_still_present")
        }
        if environment.carrierSessions(workspaceID: sourceWorkspaceID, carrierPanelID: sourceCarrier) != nil {
            extra.append("source_carrier_still_present")
        }
        if environment.listedDescriptorRevision(carrierPanelID: sourceCarrier) != 0 {
            extra.append("source_descriptor_still_listed")
        }
        guard extra.isEmpty else {
            finish(completion, Self.result("attached_pending_placement", "source_removal", extra,
                                           acquired: request.orphanChildPID))
            return
        }
        afterAttach(request, session: moved, acquired: request.orphanChildPID, completion: completion)
    }

    private func finish(_ completion: ([String: Any]) -> Void, _ result: [String: Any]) {
        inProgress = false
        completion(result)
    }

    // MARK: - Predicates

    /// Before attaching: the carrier holds exactly the original-GUID replacement session, which is
    /// the proven-empty expected shell; plus the shared identity proof.
    func beforeAttachProblems(_ request: TideyNativeOrphanAdoptionRequest) -> [String] {
        var problems = identityProblems(request)
        guard let sessions = environment.carrierSessions(workspaceID: request.workspaceID,
                                                         carrierPanelID: request.carrierPanelID) else {
            return problems + ["carrier_not_found"]
        }
        if sessions.count != 1 {
            problems.append("carrier_not_single_session")
        } else if Self.guid(sessions[0]) != request.nativeSessionGUID {
            problems.append("native_session_guid_mismatch")
        } else if Self.pid(sessions[0]) != request.expectedShellPID {
            problems.append("replacement_shell_changed")
        }
        problems.append(contentsOf: emptyShellProblems(request))
        if request.isAlreadyAttached {
            problems.append(contentsOf: sourceProblems(request))
        }
        return problems
    }

    /// The accidental source must be exactly one auto-created carrier, alone in its workspace,
    /// holding only the original child under the fenced GUID, with the same-durable descriptor
    /// at the fenced revision. Anything ambiguous or modified is not eligible.
    func sourceProblems(_ request: TideyNativeOrphanAdoptionRequest) -> [String] {
        var problems = [String]()
        let workspaceID = request.sourceWorkspaceID!, carrier = request.sourceCarrierPanelID!
        if environment.workspacePanelCount(workspaceID) != 1 {
            problems.append("source_workspace_not_single_panel")
        }
        guard let sessions = environment.carrierSessions(workspaceID: workspaceID, carrierPanelID: carrier) else {
            return problems + ["source_carrier_not_found"]
        }
        if sessions.count != 1 || Self.guid(sessions[0]) != request.sourceNativeSessionGUID ||
            Self.pid(sessions[0]) != request.orphanChildPID {
            problems.append("source_not_single_original_session")
        }
        if let descriptor = environment.descriptor(carrierPanelID: carrier) {
            if descriptor.revision != request.sourceDescriptorRevision {
                problems.append("source_descriptor_revision_changed")
            }
            let targetVendor = environment.descriptor(carrierPanelID: request.carrierPanelID)?.agent?.vendor
            if descriptor.restorePolicy != .directResume || descriptor.agent == nil ||
                descriptor.agent?.durableResumeID != request.durableResumeID ||
                descriptor.agent?.vendor != targetVendor {
                problems.append("source_descriptor_identity_mismatch")
            }
        } else {
            problems.append("source_descriptor_missing")
        }
        return problems
    }

    /// After acquisition: exactly two sessions, independent of which one is selected — the
    /// original-GUID empty replacement and one other session holding the original child.
    func afterAttachProblems(_ request: TideyNativeOrphanAdoptionRequest) -> [String] {
        var problems = identityProblems(request)
        guard let sessions = environment.carrierSessions(workspaceID: request.workspaceID,
                                                         carrierPanelID: request.carrierPanelID) else {
            return problems + ["carrier_not_found"]
        }
        let replacements = sessions.filter {
            Self.guid($0) == request.nativeSessionGUID && Self.pid($0) == request.expectedShellPID
        }
        let adopted = sessions.filter {
            Self.guid($0) != request.nativeSessionGUID && Self.pid($0) == request.orphanChildPID
        }
        if sessions.count != 2 || replacements.count != 1 || adopted.count != 1 {
            problems.append("carrier_not_exact_replacement_plus_adopted")
        }
        problems.append(contentsOf: emptyShellProblems(request))
        return problems
    }

    /// After retirement: one session, holding the original GUID and the original child, and the
    /// global GUID lookup resolves to it.
    func finalPlacementProblems(_ request: TideyNativeOrphanAdoptionRequest) -> [String] {
        var problems = [String]()
        let sessions = environment.carrierSessions(workspaceID: request.workspaceID,
                                                   carrierPanelID: request.carrierPanelID) ?? []
        if sessions.count != 1 || Self.guid(sessions[0]) != request.nativeSessionGUID ||
            Self.pid(sessions[0]) != request.orphanChildPID {
            problems.append("final_carrier_not_single_adopted_session")
        }
        if environment.shellPIDForSessionGUID(request.nativeSessionGUID) != request.orphanChildPID {
            problems.append("native_guid_does_not_resolve_to_adopted_session")
        }
        return problems
    }

    private func emptyShellProblems(_ request: TideyNativeOrphanAdoptionRequest) -> [String] {
        var problems = [String]()
        if environment.processBirth(request.expectedShellPID) != request.expectedShellBirth {
            problems.append("replacement_shell_birth_mismatch")
        }
        switch environment.childPIDs(request.expectedShellPID) {
        case .none:
            problems.append("process_inventory_unavailable")
        case .some(let children) where !children.isEmpty:
            problems.append("replacement_shell_not_empty")
        default:
            break
        }
        return problems
    }

    /// Descriptor, process ancestry and the authoritative registry identity, shared by both phases.
    private func identityProblems(_ request: TideyNativeOrphanAdoptionRequest) -> [String] {
        var problems = [String]()
        let env = environment
        var vendor: String?
        if let descriptor = env.descriptor(carrierPanelID: request.carrierPanelID) {
            if descriptor.revision != request.descriptorRevision {
                problems.append("descriptor_revision_changed")
            }
            if descriptor.restorePolicy != .directResume ||
                descriptor.agent?.durableResumeID != request.durableResumeID {
                problems.append("descriptor_identity_mismatch")
            }
            switch descriptor.agent?.vendor {
            case .codex?: vendor = "codex"
            case .claude?: vendor = "claude"
            case nil: vendor = nil
            }
        } else {
            problems.append("descriptor_missing")
        }
        if env.processBirth(request.daemonPID) != request.daemonBirth {
            problems.append("daemon_birth_mismatch")
        }
        if env.processBirth(request.orphanChildPID) != request.orphanChildBirth {
            problems.append("orphan_child_birth_mismatch")
        }
        if env.parentPID(request.orphanChildPID) != request.daemonPID {
            problems.append("orphan_child_not_under_daemon")
        }
        if env.processBirth(request.writerPID) != request.writerBirth {
            problems.append("writer_birth_mismatch")
        }
        if env.parentPID(request.writerPID) != request.orphanChildPID {
            problems.append("writer_not_under_orphan_child")
        }
        problems.append(contentsOf: registryProblems(request, vendor: vendor))
        return problems
    }

    /// Exactly one live registry record owns (vendor, current durable) on this workspace and this
    /// native panel (full logical ID or bare carrier), and it is the proven writer PID; no other
    /// live record claims the same panel, the same writer PID or the same durable.
    private func registryProblems(_ request: TideyNativeOrphanAdoptionRequest, vendor: String?) -> [String] {
        guard let records = environment.liveRegistryRecords() else {
            return ["registry_unavailable"]
        }
        let panelIDs: Set<String> = [request.logicalPanelID, request.carrierPanelID]
        func string(_ record: [String: Any], _ key: String) -> String? { record[key] as? String }
        func pid(_ record: [String: Any]) -> Int32 { (record["pid"] as? NSNumber)?.int32Value ?? 0 }
        let owners = records.filter {
            string($0, "vendor") == vendor && string($0, "durable_id") == request.durableResumeID
        }
        var problems = [String]()
        if owners.count != 1 {
            problems.append(owners.isEmpty ? "registry_writer_missing" : "registry_duplicate_writer")
        } else {
            let owner = owners[0]
            if pid(owner) != request.writerPID {
                problems.append("registry_writer_pid_mismatch")
            }
            if string(owner, "workspace_id") != request.workspaceID ||
                !panelIDs.contains(string(owner, "panel_id") ?? "") {
                problems.append("registry_binding_mismatch")
            }
        }
        let conflicts = records.filter { record in
            !(string(record, "vendor") == vendor && string(record, "durable_id") == request.durableResumeID) &&
                (panelIDs.contains(string(record, "panel_id") ?? "") || pid(record) == request.writerPID)
        }
        if !conflicts.isEmpty {
            problems.append("registry_conflicting_identity")
        }
        return problems
    }

    private static func guid(_ session: [String: Any]) -> String? { session["session_guid"] as? String }
    private static func pid(_ session: [String: Any]) -> Int32 { (session["shell_pid"] as? NSNumber)?.int32Value ?? 0 }

    private static func result(_ status: String, _ phase: String, _ problems: [String],
                               acquired: Int32 = 0) -> [String: Any] {
        ["status": status, "phase": phase, "problems": problems, "acquired_pid": NSNumber(value: acquired)]
    }
}

/// Live process facts via sysctl (read-only).
@objc(TideyNativeOrphanProcessInfo)
@objcMembers
final class TideyNativeOrphanProcessInfo: NSObject {
    private static func info(_ pid: Int32) -> kinfo_proc? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0, info.kp_proc.p_pid == pid else {
            return nil
        }
        return info
    }

    /// Start time in whole epoch seconds (what `ps -o lstart` shows, converted); stable per process.
    static func birth(_ pid: Int32) -> String? {
        guard let info = info(pid) else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        return String(start.tv_sec)
    }

    static func parent(_ pid: Int32) -> Int32 {
        info(pid)?.kp_eproc.e_ppid ?? -1
    }

    /// Children of `pid`, or nil when the process table could not be read in one consistent pass.
    static func children(_ pid: Int32) -> [NSNumber]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        let capacity = size / MemoryLayout<kinfo_proc>.stride
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: capacity)
        // A table that grew between the two calls fails with ENOMEM: unknown, not empty.
        guard sysctl(&mib, 3, &procs, &size, nil, 0) == 0 else { return nil }
        return procs.prefix(size / MemoryLayout<kinfo_proc>.stride)
            .filter { $0.kp_eproc.e_ppid == pid }
            .map { NSNumber(value: $0.kp_proc.p_pid) }
    }

    static func isAlive(_ pid: Int32) -> Bool {
        pid > 1 && (kill(pid, 0) == 0 || errno == EPERM)
    }
}

/// Read-only view of the Remote Bridge agent registry (metadata only; no history, no writes).
/// Durable identity follows the product rule: Codex app-server records use
/// thread_id ?? resume_thread_id ?? session_id; every other record uses session_id.
@objc(TideyNativeOrphanRegistryReader)
@objcMembers
final class TideyNativeOrphanRegistryReader: NSObject {
    static func durableID(_ record: [String: Any]) -> String? {
        let chosen: Any?
        if record["vendor"] as? String == "codex", record["runtime"] as? String == "codex_app_server" {
            chosen = ["thread_id", "resume_thread_id", "session_id"]
                .lazy.compactMap { record[$0] is NSNull ? nil : record[$0] }.first
        } else {
            chosen = record["session_id"]
        }
        guard let value = chosen as? String, !value.isEmpty else { return nil }
        return value
    }

    /// Live records, or nil when any directory or record cannot be read (fail closed).
    static func liveRecords(root: URL) -> [[String: Any]]? {
        let manager = FileManager.default
        guard let vendors = try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else {
            return nil
        }
        var records = [[String: Any]]()
        for vendorDirectory in vendors where vendorDirectory.hasDirectoryPath {
            guard let files = try? manager.contentsOfDirectory(at: vendorDirectory, includingPropertiesForKeys: nil) else {
                return nil
            }
            for file in files where file.pathExtension == "json" {
                guard let data = try? Data(contentsOf: file),
                      let record = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                    return nil
                }
                let pid = (record["pid"] as? NSNumber)?.int32Value ?? 0
                guard TideyNativeOrphanProcessInfo.isAlive(pid) else { continue }
                records.append(["vendor": record["vendor"] as? String ?? "",
                                "durable_id": durableID(record) ?? "",
                                "workspace_id": record["workspace_id"] as? String ?? "",
                                "panel_id": record["panel_id"] as? String ?? "",
                                "pid": NSNumber(value: pid)])
            }
        }
        return records
    }

    static func liveRecords() -> [[String: Any]]? {
        liveRecords(root: URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/Tidey Remote Bridge/agent-sessions"))
    }
}
