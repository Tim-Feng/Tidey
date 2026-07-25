import Darwin
import Foundation

private let claudeTranscriptMajorVersion = "2."

private func unsupportedClaudeTranscriptVersion(in object: [String: Any]) -> String? {
    guard object.keys.contains("version") else {
        // Versionless records are a supported legacy schema.
        return nil
    }
    guard let version = object["version"] as? String else {
        return "<non-string>"
    }
    return version.hasPrefix(claudeTranscriptMajorVersion) ? nil : version
}

protocol AgentTranscriptSession: AnyObject {
    func start()
    func update(record: AgentSessionRegistryRecord)
    func backfill(beforeSeq: Int, limit: Int) -> Bool
    func stop()
    // Typed after-cursor seam (see AgentHistoryContract.swift). Defaults
    // are legacy-neutral: hubOnly plan / unavailable step / always-valid
    // epoch keep current fetch behavior for sessions that predate the
    // contract.
    func afterCursorPlan(afterSeq: Int,
                         expectedEpoch: AgentHistoryEpoch) -> AgentAfterCursorPlan
    func afterCursorStep(from anchor: AgentHistoryAnchor,
                         afterSeq: Int,
                         limit: Int) -> AgentAfterCursorStep
    func validateHistoryEpoch(_ epoch: AgentHistoryEpoch) -> Bool
}

struct AgentSessionRegistryRecord: Codable, Sendable {
    let version: Int
    let vendor: String
    let workspaceID: String
    let sessionID: String
    let panelID: String?
    let pid: Int32
    let cwd: String
    let createdAt: String
    let transcriptPath: String?
    let tmuxPaneID: String?
    let tmuxSocketPath: String?
    let runtime: String?
    let appServerSocket: String?
    let appServerPID: Int32?
    let remoteTUIPID: Int32?
    let threadID: String?
    let resumeThreadID: String?

    enum CodingKeys: String, CodingKey {
        case version
        case vendor
        case workspaceID = "workspace_id"
        case sessionID = "session_id"
        case panelID = "panel_id"
        case pid
        case cwd
        case createdAt = "created_at"
        case transcriptPath = "transcript_path"
        case rolloutPath = "rollout_path"
        case tmuxPaneID = "tmux_pane_id"
        case tmuxSocketPath = "tmux_socket_path"
        case runtime
        case appServerSocket = "app_server_socket"
        case appServerPID = "app_server_pid"
        case remoteTUIPID = "remote_tui_pid"
        case threadID = "thread_id"
        case resumeThreadID = "resume_thread_id"
    }

    init(version: Int,
         vendor: String,
         workspaceID: String,
         sessionID: String,
         panelID: String?,
         pid: Int32,
         cwd: String,
         createdAt: String,
         transcriptPath: String?,
         tmuxPaneID: String? = nil,
         tmuxSocketPath: String? = nil,
         runtime: String? = nil,
         appServerSocket: String? = nil,
         appServerPID: Int32? = nil,
         remoteTUIPID: Int32? = nil,
         threadID: String? = nil,
         resumeThreadID: String? = nil) {
        self.version = version
        self.vendor = vendor
        self.workspaceID = workspaceID
        self.sessionID = sessionID
        self.panelID = panelID
        self.pid = pid
        self.cwd = cwd
        self.createdAt = createdAt
        self.transcriptPath = transcriptPath
        self.tmuxPaneID = tmuxPaneID
        self.tmuxSocketPath = tmuxSocketPath
        self.runtime = runtime
        self.appServerSocket = appServerSocket
        self.appServerPID = appServerPID
        self.remoteTUIPID = remoteTUIPID
        self.threadID = threadID ?? resumeThreadID
        self.resumeThreadID = resumeThreadID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        vendor = try container.decode(String.self, forKey: .vendor)
        workspaceID = try container.decode(String.self, forKey: .workspaceID)
        sessionID = try container.decode(String.self, forKey: .sessionID)
        panelID = try container.decodeIfPresent(String.self, forKey: .panelID)
        pid = try container.decode(Int32.self, forKey: .pid)
        cwd = try container.decode(String.self, forKey: .cwd)
        createdAt = try container.decode(String.self, forKey: .createdAt)
        transcriptPath =
            try container.decodeIfPresent(String.self, forKey: .transcriptPath) ??
            container.decodeIfPresent(String.self, forKey: .rolloutPath)
        tmuxPaneID = try container.decodeIfPresent(String.self, forKey: .tmuxPaneID)
        tmuxSocketPath = try container.decodeIfPresent(String.self, forKey: .tmuxSocketPath)
        runtime = try container.decodeIfPresent(String.self, forKey: .runtime)
        appServerSocket = try container.decodeIfPresent(String.self, forKey: .appServerSocket)
        appServerPID = try container.decodeIfPresent(Int32.self, forKey: .appServerPID)
        remoteTUIPID = try container.decodeIfPresent(Int32.self, forKey: .remoteTUIPID)
        let decodedThreadID = try container.decodeIfPresent(String.self, forKey: .threadID)
        let decodedResumeThreadID = try container.decodeIfPresent(String.self, forKey: .resumeThreadID)
        threadID = decodedThreadID ?? decodedResumeThreadID
        resumeThreadID = decodedResumeThreadID
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(vendor, forKey: .vendor)
        try container.encode(workspaceID, forKey: .workspaceID)
        try container.encode(sessionID, forKey: .sessionID)
        try container.encodeIfPresent(panelID, forKey: .panelID)
        try container.encode(pid, forKey: .pid)
        try container.encode(cwd, forKey: .cwd)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encodeIfPresent(transcriptPath, forKey: .transcriptPath)
        try container.encodeIfPresent(transcriptPath, forKey: .rolloutPath)
        try container.encodeIfPresent(tmuxPaneID, forKey: .tmuxPaneID)
        try container.encodeIfPresent(tmuxSocketPath, forKey: .tmuxSocketPath)
        try container.encodeIfPresent(runtime, forKey: .runtime)
        try container.encodeIfPresent(appServerSocket, forKey: .appServerSocket)
        try container.encodeIfPresent(appServerPID, forKey: .appServerPID)
        try container.encodeIfPresent(remoteTUIPID, forKey: .remoteTUIPID)
        try container.encodeIfPresent(threadID, forKey: .threadID)
        try container.encodeIfPresent(resumeThreadID, forKey: .resumeThreadID)
    }
}

struct ActiveAgentSessionSnapshot: Sendable {
    let vendor: String
    let workspaceID: String
    let sessionID: String
    let restoreSessionID: String
    let panelID: String?

    init(vendor: String,
         workspaceID: String,
         sessionID: String,
         panelID: String?,
         restoreSessionID: String? = nil) {
        self.vendor = vendor
        self.workspaceID = workspaceID
        self.sessionID = sessionID
        self.restoreSessionID = restoreSessionID ?? sessionID
        self.panelID = panelID
    }
}

struct ResolvedPanelBinding: Equatable, Sendable {
    let workspaceID: String
    let panelID: String?
}

struct AgentPanelProcessSnapshot: Sendable {
    let workspaceID: String
    let panelID: String
    let effectiveShellPID: Int32?
    let tmuxPaneID: String?
    let tmuxSocketPath: String?
    let cwd: String?

    init(workspaceID: String,
         panelID: String,
         effectiveShellPID: Int32?,
         tmuxPaneID: String? = nil,
         tmuxSocketPath: String? = nil,
         cwd: String? = nil) {
        self.workspaceID = workspaceID
        self.panelID = panelID
        self.effectiveShellPID = effectiveShellPID
        self.tmuxPaneID = tmuxPaneID
        self.tmuxSocketPath = tmuxSocketPath
        self.cwd = cwd
    }
}

private struct LoadedAgentSessionRegistryRecord {
    let record: AgentSessionRegistryRecord
    let url: URL
}

struct AgentProcessDescriptor: Equatable, Sendable {
    let pid: Int32
    let command: String
    let arguments: String
}

final class AgentSessionRegistryMonitor {
    typealias ParentPIDLookup = @Sendable (Int32) -> Int32?
    typealias DescendantProcessLookup = @Sendable (Int32) -> [AgentProcessDescriptor]
    typealias RolloutPathLookup = @Sendable (Int32) -> String?
    typealias CodexRolloutBySessionIDLookup = @Sendable (String) -> String?
    typealias OrdinaryTmuxCarrierIdentityResolver = (AgentSessionRegistryRecord) -> TideyOrdinaryTmuxCarrierIdentity?
    typealias LivePanelListProjector = ([String: JSONValue]) -> [String: JSONValue]
    private static let processLookupTimeout: TimeInterval = 1
    private static let rolloutLookupTimeout: TimeInterval = 2
    private static let liveParentPIDLookup: ParentPIDLookup = { pid in
        guard pid > 0 else {
            return nil
        }

        guard let result = BoundedProcessRunner.run(executablePath: "/bin/ps",
                                                    arguments: ["-o", "ppid=", "-p", String(pid)],
                                                    timeout: processLookupTimeout),
              result.terminationStatus == 0 else {
            return nil
        }

        guard let output = String(data: result.standardOutput, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              let parentPID = Int32(output) else {
            return nil
        }
        return parentPID
    }

    private static let liveDescendantProcessLookup: DescendantProcessLookup = { rootPID in
        guard rootPID > 0 else {
            return []
        }

        var results = [AgentProcessDescriptor]()
        var queue = [rootPID]
        var visited = Set<Int32>([rootPID])

        while queue.isEmpty == false {
            let pid = queue.removeFirst()
            if let descriptor = liveProcessDescriptor(for: pid) {
                results.append(descriptor)
            }
            for childPID in liveChildPIDs(for: pid) where !visited.contains(childPID) {
                visited.insert(childPID)
                queue.append(childPID)
            }
        }

        return results
    }

    private static let liveRolloutPathLookup: RolloutPathLookup = { pid in
        guard pid > 0 else {
            return nil
        }

        guard let result = BoundedProcessRunner.run(executablePath: "/usr/sbin/lsof",
                                                    arguments: ["-Fn", "-p", String(pid)],
                                                    timeout: rolloutLookupTimeout),
              result.terminationStatus == 0,
              let output = String(data: result.standardOutput,
                                  encoding: .utf8) else {
            return nil
        }

        return output.split(separator: "\n")
            .compactMap { line -> String? in
                guard line.hasPrefix("n") else {
                    return nil
                }
                let path = String(line.dropFirst())
                guard path.contains("/.codex/sessions/"),
                      path.contains("/rollout-"),
                      path.hasSuffix(".jsonl") else {
                    return nil
                }
                return path
            }
            .sorted()
            .last
    }

    private static let liveCodexRolloutBySessionIDLookup: CodexRolloutBySessionIDLookup = { sessionID in
        guard !sessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        let sessionsDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(at: sessionsDirectory,
                                                              includingPropertiesForKeys: [.isRegularFileKey],
                                                              options: [.skipsHiddenFiles]) else {
            return nil
        }

        for case let url as URL in enumerator {
            guard url.lastPathComponent.hasPrefix("rollout-"),
                  url.pathExtension == "jsonl",
                  url.lastPathComponent.contains(sessionID) else {
                continue
            }
            return url.path
        }
        return nil
    }

    private static func liveChildPIDs(for pid: Int32) -> [Int32] {
        guard pid > 0 else {
            return []
        }

        guard let result = BoundedProcessRunner.run(executablePath: "/usr/bin/pgrep",
                                                    arguments: ["-P", String(pid)],
                                                    timeout: processLookupTimeout),
              result.terminationStatus == 0,
              let output = String(data: result.standardOutput,
                                  encoding: .utf8) else {
            return []
        }
        return output.split(whereSeparator: \.isNewline).compactMap {
            Int32(String($0).trimmingCharacters(in: .whitespaces))
        }
    }

    private static func liveProcessDescriptor(for pid: Int32) -> AgentProcessDescriptor? {
        guard pid > 0 else {
            return nil
        }

        guard let result = BoundedProcessRunner.run(executablePath: "/bin/ps",
                                                    arguments: ["-o", "comm=", "-o", "args=", "-p", String(pid)],
                                                    timeout: processLookupTimeout),
              result.terminationStatus == 0,
              let output = String(data: result.standardOutput,
                                  encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              output.isEmpty == false else {
            return nil
        }

        let parts = output.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        let command = parts.first.map(String.init) ?? ""
        let arguments = parts.count > 1 ? String(parts[1]) : ""
        return AgentProcessDescriptor(pid: pid, command: command, arguments: arguments)
    }

    private let paths: BridgePaths
    private let fileManager: FileManager
    private let hub: AgentEventHub
    private let socketClient: TideySocketClient?
    let chatSubmitEchoRegistry: ChatSubmitEchoRegistry
    private let tmuxResolver: TmuxStateResolver
    private let parentPIDLookup: ParentPIDLookup
    private let descendantProcessLookup: DescendantProcessLookup
    private let rolloutPathLookup: RolloutPathLookup
    private let codexRolloutBySessionIDLookup: CodexRolloutBySessionIDLookup
    private let ordinaryTmuxCarrierIdentityResolver: OrdinaryTmuxCarrierIdentityResolver?
    private let livePanelSnapshotRequestSender: ((BridgeRequest) throws -> BridgeResponse)?
    private let livePanelListProjector: LivePanelListProjector
    private let livePanelSnapshotRefreshInterval: TimeInterval
    private let now: @Sendable () -> Date
    private let runtimeSyncer: AgentSessionRuntimeSyncing?
    private let queue = DispatchQueue(label: "com.tidey.remote-bridge.agent-registry")
    private var timer: DispatchSourceTimer?
    private var watchers = [String: DispatchSourceFileSystemObject]()
    private var watcherFDs = [String: Int32]()
    private var sessions = [String: AgentTranscriptSession]()
    private var activeRecords = [String: AgentSessionRegistryRecord]()
    private var resolvedPanelBindings = [String: ResolvedPanelBinding]()
    private var livePanelsByWorkspace = [String: [AgentPanelProcessSnapshot]]()
    private var lastLoggedAppServerSessionIDs = Set<String>()
    private var lastLoggedPaneIdentityCorrectionKeyBySessionID = [String: String]()
    private var lastLivePanelSnapshotRefreshAt: Date?
    private var scanScheduled = false

    init(paths: BridgePaths = BridgePaths(),
         fileManager: FileManager = .default,
         hub: AgentEventHub,
         socketClient: TideySocketClient? = nil,
         chatSubmitEchoRegistry: ChatSubmitEchoRegistry = ChatSubmitEchoRegistry(),
         tmuxResolver: TmuxStateResolver = TmuxStateResolver(),
         parentPIDLookup: @escaping ParentPIDLookup = AgentSessionRegistryMonitor.liveParentPIDLookup,
         descendantProcessLookup: @escaping DescendantProcessLookup = AgentSessionRegistryMonitor.liveDescendantProcessLookup,
         rolloutPathLookup: @escaping RolloutPathLookup = AgentSessionRegistryMonitor.liveRolloutPathLookup,
         codexRolloutBySessionIDLookup: @escaping CodexRolloutBySessionIDLookup = AgentSessionRegistryMonitor.liveCodexRolloutBySessionIDLookup,
         ordinaryTmuxCarrierIdentityResolver: OrdinaryTmuxCarrierIdentityResolver? = nil,
         livePanelSnapshotRequestSender: ((BridgeRequest) throws -> BridgeResponse)? = nil,
         livePanelListProjector: @escaping LivePanelListProjector = { $0 },
         livePanelSnapshotRefreshInterval: TimeInterval = 5,
         now: @escaping @Sendable () -> Date = { Date() },
         runtimeSyncer: AgentSessionRuntimeSyncing? = nil) {
        self.paths = paths
        self.fileManager = fileManager
        self.hub = hub
        self.socketClient = socketClient
        self.chatSubmitEchoRegistry = chatSubmitEchoRegistry
        self.tmuxResolver = tmuxResolver
        self.parentPIDLookup = parentPIDLookup
        self.descendantProcessLookup = descendantProcessLookup
        self.rolloutPathLookup = rolloutPathLookup
        self.codexRolloutBySessionIDLookup = codexRolloutBySessionIDLookup
        self.ordinaryTmuxCarrierIdentityResolver = ordinaryTmuxCarrierIdentityResolver
        if let livePanelSnapshotRequestSender {
            self.livePanelSnapshotRequestSender = livePanelSnapshotRequestSender
        } else if let socketClient {
            self.livePanelSnapshotRequestSender = { request in
                try socketClient.send(request)
            }
        } else {
            self.livePanelSnapshotRequestSender = nil
        }
        self.livePanelListProjector = livePanelListProjector
        self.livePanelSnapshotRefreshInterval = livePanelSnapshotRefreshInterval
        self.now = now
        self.runtimeSyncer = runtimeSyncer
    }

    func start() throws {
        try paths.ensureSupportDirectoriesExist(fileManager: fileManager)
        scanRegistry()
        startWatchers()

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .seconds(2), repeating: .seconds(2))
        timer.setEventHandler { [weak self] in
            self?.scheduleScan(delay: .milliseconds(0))
        }
        timer.resume()
        self.timer = timer
    }

    func activeSessionForPanel(workspaceID: String, panelID: String) -> ActiveAgentSessionSnapshot? {
        activeSessionForPanel(workspaceID: workspaceID, panelID: panelID, effectiveShellPID: nil)
    }

    func activeSessionForPanel(workspaceID: String,
                               panelID: String,
                               effectiveShellPID: Int32?,
                               tmuxPaneID: String? = nil,
                               tmuxSocketPath: String? = nil) -> ActiveAgentSessionSnapshot? {
        queue.sync {
            let panel = AgentPanelProcessSnapshot(workspaceID: workspaceID,
                                                 panelID: panelID,
                                                 effectiveShellPID: effectiveShellPID,
                                                 tmuxPaneID: tmuxPaneID,
                                                 tmuxSocketPath: tmuxSocketPath)
            return matchedSession(for: panel)
        }
    }

    func activeSessionForWorkspace(workspaceID: String) -> ActiveAgentSessionSnapshot? {
        queue.sync {
            if let direct = directSessionForWorkspace(workspaceID: workspaceID) {
                return direct
            }
            for panel in livePanelsByWorkspace[workspaceID] ?? [] {
                if let session = matchedSession(for: panel) {
                    return session
                }
            }
            return nil
        }
    }

    func activeSessionSnapshots() -> [ActiveAgentSessionSnapshot] {
        queue.sync {
            activeRecords.values.map {
                ActiveAgentSessionSnapshot(vendor: $0.vendor,
                                           workspaceID: $0.workspaceID,
                                           sessionID: $0.sessionID,
                                           panelID: $0.panelID,
                                           restoreSessionID: Self.restoreSessionID(for: $0))
            }
        }
    }

    func activeRecord(sessionID: String) -> AgentSessionRegistryRecord? {
        queue.sync {
            activeRecords[sessionID]
        }
    }

    func appServerActiveThreadDidChange(sessionID: String, threadID: String) {
        let trimmedThreadID = threadID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedThreadID.isEmpty else {
            return
        }
        queue.async { [weak self] in
            self?.updateAppServerActiveThread(sessionID: sessionID, threadID: trimmedThreadID)
        }
    }

    func canonicalSessionIDForAgentEvents(_ sessionID: String?) -> String? {
        guard let sessionID, !sessionID.isEmpty else {
            return sessionID
        }
        return queue.sync {
            let appServerRecords = activeRecords.values
                .filter(Self.isCodexAppServerRuntimeRecord)
                .sorted(by: Self.isRecordPreferred(_:_:))
            if appServerRecords.contains(where: { $0.sessionID == sessionID }) {
                return sessionID
            }
            if let appServerRecord = appServerRecords.first(where: {
                Self.codexAppServerRecord($0, matchesResumeSessionID: sessionID)
            }) {
                return appServerRecord.sessionID
            }
            return sessionID
        }
    }

    func backfillSession(sessionID: String, beforeSeq: Int, limit: Int) -> Bool {
        let session: AgentTranscriptSession? = queue.sync { sessions[sessionID] }
        return session?.backfill(beforeSeq: beforeSeq, limit: limit) ?? false
    }

    // Typed after-cursor seams: the registry queue only resolves the session
    // reference; the session seam runs OFF this queue so no registry →
    // session queue chain forms. A MISSING session fails closed — it can
    // never let an old raw page plan or validate.
    func afterCursorPlan(sessionID: String,
                         afterSeq: Int,
                         expectedEpoch: AgentHistoryEpoch) -> AgentAfterCursorPlan {
        let session: AgentTranscriptSession? = queue.sync { sessions[sessionID] }
        guard let session else {
            // Read OFF the registry queue: the failed plan reports the TRUE
            // current Hub token, never echoing the caller's expected one.
            return AgentAfterCursorPlan(epoch: hub.currentHistoryEpoch(sessionID: sessionID),
                                        mode: .unavailable)
        }
        return session.afterCursorPlan(afterSeq: afterSeq, expectedEpoch: expectedEpoch)
    }

    func afterCursorStep(sessionID: String,
                         anchor: AgentHistoryAnchor,
                         afterSeq: Int,
                         limit: Int) -> AgentAfterCursorStep {
        let session: AgentTranscriptSession? = queue.sync { sessions[sessionID] }
        guard let session else {
            return AgentAfterCursorStep(epoch: anchor.epoch, outcome: .unavailable, events: [])
        }
        return session.afterCursorStep(from: anchor, afterSeq: afterSeq, limit: limit)
    }

    func validateHistoryEpoch(sessionID: String, epoch: AgentHistoryEpoch) -> Bool {
        let session: AgentTranscriptSession? = queue.sync { sessions[sessionID] }
        return session?.validateHistoryEpoch(epoch) ?? false
    }

    func replaceLivePanels(workspaceID: String, panels: [AgentPanelProcessSnapshot]) {
        queue.sync {
            livePanelsByWorkspace[workspaceID] = panels
        }
    }

    func pruneLivePanels(toWorkspaceIDs workspaceIDs: Set<String>) {
        queue.sync {
            livePanelsByWorkspace = livePanelsByWorkspace.filter { workspaceIDs.contains($0.key) }
        }
    }

    func scanRegistryForTesting() {
        queue.sync {
            scanRegistry()
        }
    }

    deinit {
        stopWatchers()
        timer?.cancel()
        for session in sessions.values {
            session.stop()
        }
    }

    private func startWatchers() {
        for vendor in AgentVendorRegistry.all {
            startWatcher(for: vendor.registryDirectoryName,
                         directory: paths.agentSessionsDirectory(for: vendor.registryDirectoryName))
        }
    }

    private func startWatcher(for vendor: String, directory: URL) {
        stopWatcher(for: vendor)

        let fd = open(directory.path, O_EVTONLY)
        guard fd >= 0 else {
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd,
                                                               eventMask: [.write, .extend, .attrib, .link, .rename, .delete, .revoke],
                                                               queue: queue)
        source.setEventHandler { [weak self] in
            self?.handleWatcherEvent(vendor: vendor)
        }
        source.setCancelHandler { [fd] in
            close(fd)
        }
        source.resume()

        watcherFDs[vendor] = fd
        watchers[vendor] = source
    }

    private func stopWatchers() {
        for vendor in Set(watchers.keys).union(watcherFDs.keys) {
            stopWatcher(for: vendor)
        }
    }

    private func stopWatcher(for vendor: String) {
        if let watcher = watchers.removeValue(forKey: vendor) {
            watcher.cancel()
        } else if let fd = watcherFDs[vendor] {
            close(fd)
        }
        watcherFDs[vendor] = nil
    }

    private func handleWatcherEvent(vendor: String) {
        guard let watcher = watchers[vendor] else {
            return
        }
        let events = watcher.data
        scheduleScan()

        if events.contains(.rename) || events.contains(.delete) || events.contains(.revoke) {
            try? paths.ensureSupportDirectoriesExist(fileManager: fileManager)
            let directory = paths.agentSessionsDirectory(for: vendor)
            startWatcher(for: vendor, directory: directory)
        }
    }

    private func scheduleScan(delay: DispatchTimeInterval = .milliseconds(100)) {
        guard !scanScheduled else {
            return
        }
        scanScheduled = true
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else {
                return
            }
            self.scanScheduled = false
            self.scanRegistry()
        }
    }

    private func scanRegistry() {
        let loadedRecords = AgentVendorRegistry.all.flatMap { vendor in
            loadRecordEntries(at: paths.agentSessionsDirectory(for: vendor.registryDirectoryName),
                              vendor: vendor.id)
        }
        let sourceRecords = loadedRecords.map(\.record)
        refreshLivePanelSnapshotsIfNeeded(for: sourceRecords)
        let activeSessionIDs = Set(sourceRecords.map(\.sessionID))
        resolvedPanelBindings = resolvedPanelBindings.filter { activeSessionIDs.contains($0.key) }
        lastLoggedPaneIdentityCorrectionKeyBySessionID = lastLoggedPaneIdentityCorrectionKeyBySessionID
            .filter { activeSessionIDs.contains($0.key) }
        // Registry runtime lifecycle fields are wrapper-owned. Keep pane identity correction in
        // memory: writing a previously loaded record here can overwrite a concurrent runtime
        // transition or resurrect a file the wrapper deleted while this scan was resolving it.
        let paneCorrectedEntries = loadedRecords.map { loadedRecord in
            let paneCorrectedRecord = recordWithPaneIdentityIfAvailable(loadedRecord.record)
            let correctedRecord = recordWithLivePanelProcessIdentityIfAvailable(paneCorrectedRecord)
            return LoadedAgentSessionRegistryRecord(record: correctedRecord, url: loadedRecord.url)
        }
        let effectiveEntries = paneCorrectedEntries
            .map { LoadedAgentSessionRegistryRecord(record: effectiveRecord(for: $0.record), url: $0.url) }
        let activeEntries = recordsWithObsoleteCodexAppServerPanelRecordsRemoved(effectiveEntries)
        let activeRecords = activeEntries.map(\.record)
        let appServerRecords = activeRecords.filter {
            $0.vendor == "codex" && $0.runtime == "codex_app_server"
        }
        let appServerSessionIDs = Set(appServerRecords.map(\.sessionID))
        if appServerSessionIDs != lastLoggedAppServerSessionIDs {
            BridgeLogger.server.info("codex app-server diagnostic scan registry app_server_count=\(appServerRecords.count, privacy: .public) session_ids=\(appServerRecords.map(\.sessionID).joined(separator: ","), privacy: .public)")
            lastLoggedAppServerSessionIDs = appServerSessionIDs
        }
        syncRecords(activeRecords)
        self.activeRecords = Dictionary(uniqueKeysWithValues: activeRecords.map { ($0.sessionID, $0) })
        runtimeSyncer?.sync(records: activeRecords)
        for record in activeRecords where resolvedPanelBindings[record.sessionID] != nil {
            applyResolvedBinding(sessionID: record.sessionID,
                                 workspaceID: record.workspaceID,
                                 panelID: record.panelID)
        }
    }

    private func refreshLivePanelSnapshotsIfNeeded(for records: [AgentSessionRegistryRecord]) {
        guard records.contains(where: recordMayNeedLivePanelSnapshotRefresh(_:)),
              let livePanelSnapshotRequestSender else {
            return
        }
        let currentDate = now()
        if let lastLivePanelSnapshotRefreshAt,
           currentDate.timeIntervalSince(lastLivePanelSnapshotRefreshAt) < livePanelSnapshotRefreshInterval {
            return
        }
        lastLivePanelSnapshotRefreshAt = currentDate

        do {
            let workspaceResponse = try livePanelSnapshotRequestSender(BridgeRequest(id: UUID().uuidString,
                                                                                    action: "list_workspaces",
                                                                                    params: nil))
            guard workspaceResponse.ok,
                  let workspaces = workspaceResponse.result?["workspaces"]?.arrayValue else {
                return
            }
            let workspaceIDs = Set(workspaces.compactMap { workspace -> String? in
                workspace.objectValue?["workspace_id"]?.stringValue
            })
            livePanelsByWorkspace = livePanelsByWorkspace.filter { workspaceIDs.contains($0.key) }

            for workspaceID in workspaceIDs.sorted() {
                let panelResponse = try livePanelSnapshotRequestSender(BridgeRequest(id: UUID().uuidString,
                                                                                    action: "list_panels",
                                                                                    params: ["workspace_id": .string(workspaceID)]))
                guard panelResponse.ok,
                      let result = panelResponse.result else {
                    continue
                }
                let projectedResult = livePanelListProjector(result)
                guard let extracted = AgentPanelProcessSnapshotExtractor.snapshots(fromPanelListResult: projectedResult) else {
                    continue
                }
                livePanelsByWorkspace[extracted.workspaceID] = extracted.snapshots
            }
        } catch {
            BridgeLogger.server.debug("agent registry live panel snapshot refresh failed error=\(String(describing: error), privacy: .public)")
        }
    }

    private func recordMayNeedLivePanelSnapshotRefresh(_ record: AgentSessionRegistryRecord) -> Bool {
        guard let paneID = record.tmuxPaneID,
              paneID.isEmpty == false else {
            return record.vendor == "claude"
        }
        guard let panelID = record.panelID,
              panelID.isEmpty == false else {
            return true
        }
        return paneIdentityMatchesKnownLivePanel(TmuxPaneIdentity(workspaceID: record.workspaceID,
                                                                  panelID: panelID)) == false
    }

    private func recordWithLivePanelProcessIdentityIfAvailable(
        _ record: AgentSessionRegistryRecord
    ) -> AgentSessionRegistryRecord {
        guard let panel = uniqueLivePanelProcessMatch(for: record),
              panel.workspaceID != record.workspaceID || panel.panelID != record.panelID else {
            return record
        }

        let correctionKey = [
            "process",
            record.workspaceID,
            record.panelID ?? "-",
            panel.workspaceID,
            panel.panelID,
            String(record.pid),
        ].joined(separator: "|")
        if lastLoggedPaneIdentityCorrectionKeyBySessionID[record.sessionID] != correctionKey {
            BridgeLogger.server.info("agent registry corrected from live panel process ancestry session_id=\(record.sessionID, privacy: .public) vendor=\(record.vendor, privacy: .public) pid=\(record.pid, privacy: .public) old_workspace_id=\(record.workspaceID, privacy: .public) old_panel_id=\(record.panelID ?? "-", privacy: .public) workspace_id=\(panel.workspaceID, privacy: .public) panel_id=\(panel.panelID, privacy: .public)")
            lastLoggedPaneIdentityCorrectionKeyBySessionID[record.sessionID] = correctionKey
        }
        return AgentSessionRegistryRecord(version: record.version,
                                          vendor: record.vendor,
                                          workspaceID: panel.workspaceID,
                                          sessionID: record.sessionID,
                                          panelID: panel.panelID,
                                          pid: record.pid,
                                          cwd: record.cwd,
                                          createdAt: record.createdAt,
                                          transcriptPath: record.transcriptPath,
                                          tmuxPaneID: record.tmuxPaneID,
                                          tmuxSocketPath: record.tmuxSocketPath,
                                          runtime: record.runtime,
                                          appServerSocket: record.appServerSocket,
                                          appServerPID: record.appServerPID,
                                          remoteTUIPID: record.remoteTUIPID,
                                          threadID: record.threadID,
                                          resumeThreadID: record.resumeThreadID)
    }

    private func uniqueLivePanelProcessMatch(
        for record: AgentSessionRegistryRecord
    ) -> AgentPanelProcessSnapshot? {
        guard record.vendor == "claude",
              record.pid > 0,
              (record.tmuxPaneID ?? "").isEmpty else {
            return nil
        }

        var ancestorPIDs = Set<Int32>()
        var currentPID = record.pid
        for _ in 0..<32 {
            guard currentPID > 0, ancestorPIDs.insert(currentPID).inserted else {
                break
            }
            guard currentPID > 1,
                  let parentPID = parentPIDLookup(currentPID),
                  parentPID > 0 else {
                break
            }
            currentPID = parentPID
        }

        let matches = livePanelsByWorkspace.values
            .flatMap { $0 }
            .filter { panel in
                guard let effectiveShellPID = panel.effectiveShellPID,
                      effectiveShellPID > 0 else {
                    return false
                }
                return ancestorPIDs.contains(effectiveShellPID)
            }
        guard matches.count == 1 else {
            return nil
        }
        return matches[0]
    }

    private func recordsWithObsoleteCodexAppServerPanelRecordsRemoved(_ entries: [LoadedAgentSessionRegistryRecord]) -> [LoadedAgentSessionRegistryRecord] {
        let records = entries.map(\.record)
        var preferredByPanelKey = [String: AgentSessionRegistryRecord]()
        var obsoleteSessionIDs = Set<String>()
        let appServerPaneRestoreKeys = Set(
            records
                .filter(Self.isCodexAppServerRuntimeRecord)
                .compactMap(Self.codexPaneRestoreKey(for:))
        )

        for record in records where Self.isCodexAppServerRuntimeRecord(record) {
            guard let panelID = record.panelID, !panelID.isEmpty else {
                continue
            }
            let key = "\(record.workspaceID)|\(panelID)"
            if let current = preferredByPanelKey[key] {
                if Self.isRecordPreferred(record, current) {
                    obsoleteSessionIDs.insert(current.sessionID)
                    preferredByPanelKey[key] = record
                } else {
                    obsoleteSessionIDs.insert(record.sessionID)
                }
            } else {
                preferredByPanelKey[key] = record
            }
        }

        for record in records where record.vendor == "codex" && !Self.isCodexAppServerRuntimeRecord(record) {
            guard let key = Self.codexPaneRestoreKey(for: record),
                  appServerPaneRestoreKeys.contains(key) else {
                continue
            }
            obsoleteSessionIDs.insert(record.sessionID)
        }

        guard obsoleteSessionIDs.isEmpty == false else {
            return entries
        }
        for entry in entries where obsoleteSessionIDs.contains(entry.record.sessionID) {
            try? fileManager.removeItem(at: entry.url)
        }
        return entries.filter { obsoleteSessionIDs.contains($0.record.sessionID) == false }
    }

    private static func codexPaneRestoreKey(for record: AgentSessionRegistryRecord) -> String? {
        guard record.vendor == "codex",
              let paneID = record.tmuxPaneID,
              !paneID.isEmpty else {
            return nil
        }
        let restoreID = restoreSessionID(for: record)
        guard !restoreID.isEmpty else {
            return nil
        }
        let socketPath = record.tmuxSocketPath.map(normalizeSocketPath) ?? ""
        return "\(socketPath)|\(paneID)|\(restoreID)"
    }

    private func recordWithPaneIdentityIfAvailable(_ record: AgentSessionRegistryRecord) -> AgentSessionRegistryRecord {
        guard let paneID = record.tmuxPaneID,
              !paneID.isEmpty,
              let resolved = resolvedPaneIdentity(forRecord: record, paneID: paneID),
              resolved.identity.workspaceID != record.workspaceID ||
              resolved.identity.panelID != record.panelID ||
              resolved.socketPath != record.tmuxSocketPath else {
            return record
        }

        let correctionKey = [
            record.workspaceID,
            record.panelID ?? "-",
            record.tmuxSocketPath ?? "-",
            resolved.identity.workspaceID,
            resolved.identity.panelID,
            resolved.socketPath ?? "-",
        ].joined(separator: "|")
        if lastLoggedPaneIdentityCorrectionKeyBySessionID[record.sessionID] != correctionKey {
            BridgeLogger.server.info("agent registry corrected from tmux pane identity session_id=\(record.sessionID, privacy: .public) vendor=\(record.vendor, privacy: .public) pane_id=\(paneID, privacy: .public) old_workspace_id=\(record.workspaceID, privacy: .public) old_panel_id=\(record.panelID ?? "-", privacy: .public) workspace_id=\(resolved.identity.workspaceID, privacy: .public) panel_id=\(resolved.identity.panelID, privacy: .public) socket_path=\(resolved.socketPath ?? "-", privacy: .public)")
            lastLoggedPaneIdentityCorrectionKeyBySessionID[record.sessionID] = correctionKey
        }
        return AgentSessionRegistryRecord(version: record.version,
                                          vendor: record.vendor,
                                          workspaceID: resolved.identity.workspaceID,
                                          sessionID: record.sessionID,
                                          panelID: resolved.identity.panelID,
                                          pid: record.pid,
                                          cwd: record.cwd,
                                          createdAt: record.createdAt,
                                          transcriptPath: record.transcriptPath,
                                          tmuxPaneID: record.tmuxPaneID,
                                          tmuxSocketPath: resolved.socketPath,
                                          runtime: record.runtime,
                                          appServerSocket: record.appServerSocket,
                                          appServerPID: record.appServerPID,
                                          remoteTUIPID: record.remoteTUIPID,
                                          threadID: record.threadID,
                                          resumeThreadID: record.resumeThreadID)
    }

    private func resolvedPaneIdentity(forRecord record: AgentSessionRegistryRecord,
                                      paneID: String) -> (identity: TmuxPaneIdentity, socketPath: String?)? {
        if let panel = livePanelSnapshot(forPaneID: paneID, socketPath: record.tmuxSocketPath) {
            return (TmuxPaneIdentity(workspaceID: panel.workspaceID, panelID: panel.panelID),
                    normalizedNonEmptySocketPath(panel.tmuxSocketPath) ?? normalizedNonEmptySocketPath(record.tmuxSocketPath))
        }

        guard let socketPath = normalizedNonEmptySocketPath(record.tmuxSocketPath) else {
            return resolvedCarrierPaneIdentity(for: record)
        }

        if recordNeedsLivePaneRecovery(record),
           let panel = livePanelSnapshotForTmuxClient(paneID: paneID, socketPath: socketPath) {
            return (TmuxPaneIdentity(workspaceID: panel.workspaceID, panelID: panel.panelID), socketPath)
        }

        guard let identity = tmuxResolver.paneIdentity(forPaneID: paneID, socketPath: socketPath) else {
            return resolvedCarrierPaneIdentity(for: record)
        }

        if paneIdentityMatchesKnownLivePanel(identity) == false {
            if let carrierIdentity = resolvedCarrierPaneIdentity(for: record) {
                return carrierIdentity
            }
            if let panel = livePanelSnapshotForTmuxClient(paneID: paneID, socketPath: socketPath) {
                return (TmuxPaneIdentity(workspaceID: panel.workspaceID, panelID: panel.panelID), socketPath)
            }
        }
        return (identity, socketPath)
    }

    private func recordNeedsLivePaneRecovery(_ record: AgentSessionRegistryRecord) -> Bool {
        guard let panelID = record.panelID,
              !panelID.isEmpty else {
            return true
        }
        return paneIdentityMatchesKnownLivePanel(TmuxPaneIdentity(workspaceID: record.workspaceID,
                                                                  panelID: panelID)) == false
    }

    private func livePanelSnapshotForTmuxClient(paneID: String, socketPath: String) -> AgentPanelProcessSnapshot? {
        let candidatePanels = livePanelsByWorkspace.values
            .flatMap { $0 }
            .filter { panel in
                guard let effectiveShellPID = panel.effectiveShellPID else {
                    return false
                }
                return effectiveShellPID > 0
            }
        guard candidatePanels.isEmpty == false else {
            return nil
        }
        guard let clientPIDs = tmuxResolver.clientPIDs(forPaneID: paneID, socketPath: socketPath),
              clientPIDs.isEmpty == false else {
            return nil
        }
        let matches = candidatePanels.filter { panel in
            guard let effectiveShellPID = panel.effectiveShellPID else {
                return false
            }
            return clientPIDs.contains { clientPID in
                processIsDescendantOrSelf(of: effectiveShellPID, candidate: clientPID)
            }
        }
        guard matches.count == 1 else {
            return nil
        }
        return matches[0]
    }

    private func resolvedCarrierPaneIdentity(for record: AgentSessionRegistryRecord) -> (identity: TmuxPaneIdentity, socketPath: String?)? {
        guard let carrierIdentity = ordinaryTmuxCarrierIdentityResolver?(record) else {
            return nil
        }
        return (TmuxPaneIdentity(workspaceID: carrierIdentity.workspaceID,
                                 panelID: carrierIdentity.panelID),
                normalizedNonEmptySocketPath(carrierIdentity.socketPath))
    }

    private func paneIdentityMatchesKnownLivePanel(_ identity: TmuxPaneIdentity) -> Bool {
        guard let panels = livePanelsByWorkspace[identity.workspaceID] else {
            return false
        }
        return panels.contains { $0.panelID == identity.panelID }
    }

    private func livePanelSnapshot(forPaneID paneID: String,
                                   socketPath: String?) -> AgentPanelProcessSnapshot? {
        let normalizedRecordSocket = normalizedNonEmptySocketPath(socketPath)
        let matches = livePanelsByWorkspace.values
            .flatMap { $0 }
            .filter { panel in
                guard panel.tmuxPaneID == paneID else {
                    return false
                }
                guard let normalizedRecordSocket else {
                    return true
                }
                guard let panelSocket = normalizedNonEmptySocketPath(panel.tmuxSocketPath) else {
                    return false
                }
                return panelSocket == normalizedRecordSocket
            }
        guard matches.count == 1 else {
            return nil
        }
        return matches[0]
    }

    private static func normalizedNonEmptySocketPath(_ socketPath: String?) -> String? {
        guard let socketPath else {
            return nil
        }
        let normalized = normalizeSocketPath(socketPath)
        return normalized.isEmpty ? nil : normalized
    }

    private func normalizedNonEmptySocketPath(_ socketPath: String?) -> String? {
        Self.normalizedNonEmptySocketPath(socketPath)
    }

    private func directSessionForWorkspace(workspaceID: String) -> ActiveAgentSessionSnapshot? {
        activeRecords.values
            .filter { $0.workspaceID == workspaceID }
            .sorted(by: Self.isRecordPreferred(_:_:))
            .first
            .map {
                ActiveAgentSessionSnapshot(vendor: $0.vendor,
                                           workspaceID: workspaceID,
                                           sessionID: $0.sessionID,
                                           panelID: $0.panelID,
                                           restoreSessionID: Self.restoreSessionID(for: $0))
            }
    }

    private func matchedSession(for panel: AgentPanelProcessSnapshot) -> ActiveAgentSessionSnapshot? {
        BridgeLogger.server.debug("agent panel match start workspace_id=\(panel.workspaceID, privacy: .public) panel_id=\(panel.panelID, privacy: .public) effective_shell_pid=\(panel.effectiveShellPID.map(String.init) ?? "-", privacy: .public)")
        let directMatches = activeRecords.values
            .filter { $0.workspaceID == panel.workspaceID && $0.panelID == panel.panelID }
            .sorted(by: Self.isRecordPreferred(_:_:))

        var liveCodexProcessRecord: AgentSessionRegistryRecord?
        if let effectiveShellPID = panel.effectiveShellPID, effectiveShellPID > 0 {
            liveCodexProcessRecord = liveCodexSessionMatch(for: panel,
                                                           effectiveShellPID: effectiveShellPID,
                                                           requireProcessResumeSession: true)
        } else {
            liveCodexProcessRecord = nil
        }

        if liveCodexProcessRecord == nil,
           let staleCodexRecord = directMatches.first(where: {
               $0.vendor == "codex" &&
               $0.pid > 0 &&
               $0.tmuxPaneID?.isEmpty == false &&
               $0.tmuxSocketPath?.isEmpty == false
           }) {
            let fallbackPanel = AgentPanelProcessSnapshot(workspaceID: panel.workspaceID,
                                                          panelID: panel.panelID,
                                                          effectiveShellPID: staleCodexRecord.pid,
                                                          tmuxPaneID: staleCodexRecord.tmuxPaneID,
                                                          tmuxSocketPath: staleCodexRecord.tmuxSocketPath,
                                                          cwd: panel.cwd ?? staleCodexRecord.cwd)
            liveCodexProcessRecord = liveCodexSessionMatch(for: fallbackPanel,
                                                           effectiveShellPID: staleCodexRecord.pid,
                                                           requireProcessResumeSession: true)
        }

        if let liveCodexProcessRecord,
           Self.isCodexAppServerRuntimeRecord(liveCodexProcessRecord) {
            applyResolvedBinding(sessionID: liveCodexProcessRecord.sessionID,
                                 workspaceID: panel.workspaceID,
                                 panelID: panel.panelID)
            BridgeLogger.server.info("agent panel matched codex app-server session from live process workspace_id=\(panel.workspaceID, privacy: .public) panel_id=\(panel.panelID, privacy: .public) session_id=\(liveCodexProcessRecord.sessionID, privacy: .public)")
            return ActiveAgentSessionSnapshot(vendor: liveCodexProcessRecord.vendor,
                                              workspaceID: panel.workspaceID,
                                              sessionID: liveCodexProcessRecord.sessionID,
                                              panelID: panel.panelID,
                                              restoreSessionID: Self.restoreSessionID(for: liveCodexProcessRecord))
        }

        if let liveCodexProcessRecord,
           directMatches.contains(where: { $0.vendor == "codex" && $0.sessionID != liveCodexProcessRecord.sessionID }) {
            applyResolvedBinding(sessionID: liveCodexProcessRecord.sessionID,
                                 workspaceID: panel.workspaceID,
                                 panelID: panel.panelID)
            BridgeLogger.server.info("agent panel corrected codex session from live process workspace_id=\(panel.workspaceID, privacy: .public) panel_id=\(panel.panelID, privacy: .public) session_id=\(liveCodexProcessRecord.sessionID, privacy: .public)")
            return ActiveAgentSessionSnapshot(vendor: liveCodexProcessRecord.vendor,
                                              workspaceID: panel.workspaceID,
                                              sessionID: liveCodexProcessRecord.sessionID,
                                              panelID: panel.panelID,
                                              restoreSessionID: Self.restoreSessionID(for: liveCodexProcessRecord))
        }

        if let direct = directMatches.first {
            applyResolvedBinding(sessionID: direct.sessionID,
                                 workspaceID: panel.workspaceID,
                                 panelID: panel.panelID)
            BridgeLogger.server.debug("agent panel direct match session_id=\(direct.sessionID, privacy: .public) vendor=\(direct.vendor, privacy: .public)")
            return ActiveAgentSessionSnapshot(vendor: direct.vendor,
                                              workspaceID: panel.workspaceID,
                                              sessionID: direct.sessionID,
                                              panelID: panel.panelID,
                                              restoreSessionID: Self.restoreSessionID(for: direct))
        }

        let paneMatches = activeRecords.values
            .filter { Self.record($0, matchesTmuxPaneOf: panel) }
            .sorted(by: Self.isRecordPreferred(_:_:))
        if let paneMatch = paneMatches.first {
            applyResolvedBinding(sessionID: paneMatch.sessionID,
                                 workspaceID: panel.workspaceID,
                                 panelID: panel.panelID)
            BridgeLogger.server.info("agent panel matched via live pane identity workspace_id=\(panel.workspaceID, privacy: .public) panel_id=\(panel.panelID, privacy: .public) session_id=\(paneMatch.sessionID, privacy: .public) record_workspace_id=\(paneMatch.workspaceID, privacy: .public) record_panel_id=\(paneMatch.panelID ?? "-", privacy: .public)")
            return ActiveAgentSessionSnapshot(vendor: paneMatch.vendor,
                                              workspaceID: panel.workspaceID,
                                              sessionID: paneMatch.sessionID,
                                              panelID: panel.panelID,
                                              restoreSessionID: Self.restoreSessionID(for: paneMatch))
        }

        guard let effectiveShellPID = panel.effectiveShellPID, effectiveShellPID > 0 else {
            BridgeLogger.server.debug("agent panel no direct match and effective_shell_pid unavailable workspace_id=\(panel.workspaceID, privacy: .public) panel_id=\(panel.panelID, privacy: .public)")
            logPanelMatchFailure(panel, matchedReason: "no_effective_shell_pid")
            return nil
        }

        BridgeLogger.server.debug("agent panel trying tmux match effective_shell_pid=\(effectiveShellPID, privacy: .public) candidate_records=\(self.activeRecords.count, privacy: .public)")
        if let ordinaryTmuxMatch = ordinaryTmuxProcessMatch(for: panel, effectiveShellPID: effectiveShellPID) {
            applyResolvedBinding(sessionID: ordinaryTmuxMatch.sessionID,
                                 workspaceID: panel.workspaceID,
                                 panelID: panel.panelID)
            BridgeLogger.server.debug("agent panel matched via ordinary tmux pane process vendor=\(ordinaryTmuxMatch.vendor, privacy: .public) session_id=\(ordinaryTmuxMatch.sessionID, privacy: .public)")
            return ActiveAgentSessionSnapshot(vendor: ordinaryTmuxMatch.vendor,
                                              workspaceID: panel.workspaceID,
                                              sessionID: ordinaryTmuxMatch.sessionID,
                                              panelID: panel.panelID,
                                              restoreSessionID: Self.restoreSessionID(for: ordinaryTmuxMatch))
        }

        let tmuxCandidates = self.activeRecords.values
            .filter { record in
                guard let paneID = record.tmuxPaneID,
                      !paneID.isEmpty,
                      let socketPath = record.tmuxSocketPath,
                      !socketPath.isEmpty else {
                    return false
                }
                BridgeLogger.server.debug("agent panel tmux candidate session_id=\(record.sessionID, privacy: .public) pane_id=\(paneID, privacy: .public) socket=\(socketPath, privacy: .public)")
                if let clientPIDs = tmuxResolver.clientPIDs(forPaneID: paneID, socketPath: socketPath) {
                    BridgeLogger.server.debug("agent panel tmux candidate session_id=\(record.sessionID, privacy: .public) pane_id=\(paneID, privacy: .public) client_pids=\(String(describing: clientPIDs), privacy: .public)")
                    return clientPIDs.contains { clientPID in
                        let result = processIsDescendantOrSelf(of: effectiveShellPID, candidate: clientPID)
                        BridgeLogger.server.debug("agent panel ancestry candidate_pid=\(clientPID, privacy: .public) ancestor_pid=\(effectiveShellPID, privacy: .public) result=\(result, privacy: .public)")
                        return result
                    }
                }
                BridgeLogger.server.debug("agent panel tmux candidate session_id=\(record.sessionID, privacy: .public) pane_id=\(paneID, privacy: .public) client_pids=nil")
                return false
            }
            .sorted(by: Self.isRecordPreferred(_:_:))

        guard let match = tmuxCandidates.first else {
            BridgeLogger.server.debug("agent panel no tmux match workspace_id=\(panel.workspaceID, privacy: .public) panel_id=\(panel.panelID, privacy: .public)")
            if let liveCodexMatch = liveCodexProcessRecord ?? liveCodexSessionMatch(for: panel, effectiveShellPID: effectiveShellPID) {
                applyResolvedBinding(sessionID: liveCodexMatch.sessionID,
                                     workspaceID: panel.workspaceID,
                                     panelID: panel.panelID)
                BridgeLogger.server.info("agent panel matched via live codex discovery workspace_id=\(panel.workspaceID, privacy: .public) panel_id=\(panel.panelID, privacy: .public) session_id=\(liveCodexMatch.sessionID, privacy: .public)")
                return ActiveAgentSessionSnapshot(vendor: liveCodexMatch.vendor,
                                                  workspaceID: panel.workspaceID,
                                                  sessionID: liveCodexMatch.sessionID,
                                                  panelID: panel.panelID,
                                                  restoreSessionID: Self.restoreSessionID(for: liveCodexMatch))
            }
            logPanelMatchFailure(panel, matchedReason: "none")
            return nil
        }

        applyResolvedBinding(sessionID: match.sessionID,
                             workspaceID: panel.workspaceID,
                             panelID: panel.panelID)
        BridgeLogger.server.debug("agent panel matched via tmux vendor=\(match.vendor, privacy: .public) session_id=\(match.sessionID, privacy: .public)")
        return ActiveAgentSessionSnapshot(vendor: match.vendor,
                                          workspaceID: panel.workspaceID,
                                          sessionID: match.sessionID,
                                          panelID: panel.panelID,
                                          restoreSessionID: Self.restoreSessionID(for: match))
    }

    private static func restoreSessionID(for record: AgentSessionRegistryRecord) -> String {
        if isCodexAppServerRuntimeRecord(record) {
            return record.threadID ?? record.resumeThreadID ?? record.sessionID
        }
        return record.sessionID
    }

    private func logPanelMatchFailure(_ panel: AgentPanelProcessSnapshot,
                                      matchedReason: String) {
        BridgeLogger.server.info("agent panel match failed summary workspace_id=\(panel.workspaceID, privacy: .public) panel_id=\(panel.panelID, privacy: .public) effective_shell_pid=\(panel.effectiveShellPID.map(String.init) ?? "-", privacy: .public) tmux_pane_id=\(panel.tmuxPaneID ?? "-", privacy: .public) tmux_socket_path=\(panel.tmuxSocketPath ?? "-", privacy: .public) active_record_count=\(self.activeRecords.count, privacy: .public) matched_reason=\(matchedReason, privacy: .public)")
    }

    private func liveCodexSessionMatch(for panel: AgentPanelProcessSnapshot,
                                       effectiveShellPID: Int32,
                                       requireProcessResumeSession: Bool = false) -> AgentSessionRegistryRecord? {
        guard let tmuxPaneID = panel.tmuxPaneID,
              tmuxPaneID.isEmpty == false,
              let tmuxSocketPath = panel.tmuxSocketPath,
              tmuxSocketPath.isEmpty == false else {
            BridgeLogger.server.info("agent panel live codex discovery skipped workspace_id=\(panel.workspaceID, privacy: .public) panel_id=\(panel.panelID, privacy: .public) reason=missing_tmux_context")
            return nil
        }

        BridgeLogger.server.info("agent panel live codex discovery start workspace_id=\(panel.workspaceID, privacy: .public) panel_id=\(panel.panelID, privacy: .public) effective_shell_pid=\(effectiveShellPID, privacy: .public) tmux_pane_id=\(tmuxPaneID, privacy: .public) tmux_socket_path=\(tmuxSocketPath, privacy: .public) active_record_count=\(self.activeRecords.count, privacy: .public)")

        let descendants = descendantProcessLookup(effectiveShellPID)
        let codexCandidates = descendants
            .filter(Self.isCodexProcess)
            .sorted { lhs, rhs in lhs.pid < rhs.pid }

        guard codexCandidates.isEmpty == false else {
            BridgeLogger.server.info("agent panel live codex discovery no_candidate workspace_id=\(panel.workspaceID, privacy: .public) panel_id=\(panel.panelID, privacy: .public) descendant_count=\(descendants.count, privacy: .public)")
            return nil
        }

        for candidate in codexCandidates {
            BridgeLogger.server.info("agent panel live codex discovery candidate workspace_id=\(panel.workspaceID, privacy: .public) panel_id=\(panel.panelID, privacy: .public) pid=\(candidate.pid, privacy: .public) command=\(candidate.command, privacy: .public)")
            let resolved: (sessionID: String, rolloutPath: String)?
            if let processSessionID = Self.codexResumeSessionID(from: candidate) {
                if let appServerRecord = codexAppServerRecord(matchingResumeSessionID: processSessionID,
                                                              for: panel) {
                    BridgeLogger.server.info("agent panel live codex discovery using app-server record workspace_id=\(panel.workspaceID, privacy: .public) panel_id=\(panel.panelID, privacy: .public) pid=\(candidate.pid, privacy: .public) resume_session_id=\(processSessionID, privacy: .public) app_server_session_id=\(appServerRecord.sessionID, privacy: .public)")
                    return appServerRecord
                }
                if let rolloutPath = codexRolloutBySessionIDLookup(processSessionID) {
                    resolved = (processSessionID, rolloutPath)
                    BridgeLogger.server.info("agent panel live codex discovery using_process_resume workspace_id=\(panel.workspaceID, privacy: .public) panel_id=\(panel.panelID, privacy: .public) pid=\(candidate.pid, privacy: .public) session_id=\(processSessionID, privacy: .public)")
                } else {
                    BridgeLogger.server.info("agent panel live codex discovery no_rollout_for_process_resume workspace_id=\(panel.workspaceID, privacy: .public) panel_id=\(panel.panelID, privacy: .public) pid=\(candidate.pid, privacy: .public) session_id=\(processSessionID, privacy: .public)")
                    resolved = nil
                }
            } else if requireProcessResumeSession {
                BridgeLogger.server.info("agent panel live codex discovery no_process_resume workspace_id=\(panel.workspaceID, privacy: .public) panel_id=\(panel.panelID, privacy: .public) pid=\(candidate.pid, privacy: .public)")
                resolved = nil
            } else {
                guard let rolloutPath = rolloutPathLookup(candidate.pid),
                      rolloutPath.isEmpty == false else {
                    BridgeLogger.server.info("agent panel live codex discovery no_rollout workspace_id=\(panel.workspaceID, privacy: .public) panel_id=\(panel.panelID, privacy: .public) pid=\(candidate.pid, privacy: .public)")
                    continue
                }
                guard let sessionID = Self.codexSessionID(fromRolloutPath: rolloutPath) else {
                    BridgeLogger.server.info("agent panel live codex discovery invalid_rollout workspace_id=\(panel.workspaceID, privacy: .public) panel_id=\(panel.panelID, privacy: .public) pid=\(candidate.pid, privacy: .public) rollout_path=\(rolloutPath, privacy: .private)")
                    continue
                }
                resolved = (sessionID, rolloutPath)
            }

            guard let (sessionID, rolloutPath) = resolved else {
                continue
            }

            let record = AgentSessionRegistryRecord(version: 1,
                                                    vendor: "codex",
                                                    workspaceID: panel.workspaceID,
                                                    sessionID: sessionID,
                                                    panelID: panel.panelID,
                                                    pid: candidate.pid,
                                                    cwd: panel.cwd ?? fileManager.currentDirectoryPath,
                                                    createdAt: Self.iso8601Now(),
                                                    transcriptPath: rolloutPath,
                                                    tmuxPaneID: tmuxPaneID,
                                                    tmuxSocketPath: tmuxSocketPath)
            persistSynthesizedCodexRecord(record)
            BridgeLogger.server.info("agent panel live codex discovery synthesized workspace_id=\(panel.workspaceID, privacy: .public) panel_id=\(panel.panelID, privacy: .public) session_id=\(sessionID, privacy: .public) pid=\(candidate.pid, privacy: .public) tmux_pane_id=\(tmuxPaneID, privacy: .public)")
            return record
        }

        BridgeLogger.server.info("agent panel live codex discovery no_rollout_match workspace_id=\(panel.workspaceID, privacy: .public) panel_id=\(panel.panelID, privacy: .public) candidate_count=\(codexCandidates.count, privacy: .public)")
        return nil
    }

    private func codexAppServerRecord(matchingResumeSessionID resumeSessionID: String,
                                      for panel: AgentPanelProcessSnapshot) -> AgentSessionRegistryRecord? {
        activeRecords.values
            .filter { record in
                Self.isCodexAppServerRuntimeRecord(record) &&
                    Self.codexAppServerRecord(record, matchesResumeSessionID: resumeSessionID) &&
                    (Self.record(record, matchesPanel: panel) ||
                     Self.record(record, matchesTmuxPaneOf: panel))
            }
            .sorted(by: Self.isRecordPreferred(_:_:))
            .first
    }

    private static func codexAppServerRecord(_ record: AgentSessionRegistryRecord,
                                             matchesResumeSessionID resumeSessionID: String) -> Bool {
        [record.threadID, record.resumeThreadID]
            .compactMap { $0 }
            .contains(resumeSessionID)
    }

    private static func record(_ record: AgentSessionRegistryRecord,
                               matchesPanel panel: AgentPanelProcessSnapshot) -> Bool {
        record.workspaceID == panel.workspaceID && record.panelID == panel.panelID
    }

    private static func record(_ record: AgentSessionRegistryRecord,
                               matchesTmuxPaneOf panel: AgentPanelProcessSnapshot) -> Bool {
        guard let recordPaneID = record.tmuxPaneID,
              !recordPaneID.isEmpty,
              let panelPaneID = panel.tmuxPaneID,
              !panelPaneID.isEmpty,
              recordPaneID == panelPaneID else {
            return false
        }
        let recordSocketPath = normalizedNonEmptySocketPath(record.tmuxSocketPath)
        let panelSocketPath = normalizedNonEmptySocketPath(panel.tmuxSocketPath)
        if let recordSocketPath, let panelSocketPath {
            return recordSocketPath == panelSocketPath
        }
        return recordSocketPath == nil && panelSocketPath != nil
    }

    private static func isCodexProcess(_ descriptor: AgentProcessDescriptor) -> Bool {
        let command = descriptor.command.lowercased()
        let arguments = descriptor.arguments.lowercased()
        let combined = command + " " + arguments
        if URL(fileURLWithPath: command).lastPathComponent == "codex" {
            return true
        }
        if combined.contains("@openai/codex") {
            return true
        }
        if combined.contains("/codex") || combined.contains(" codex") {
            return true
        }
        return false
    }

    private static func codexResumeSessionID(from descriptor: AgentProcessDescriptor) -> String? {
        let combined = descriptor.command + " " + descriptor.arguments
        let tokens = combined.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let codexIndex = tokens.lastIndex(where: { token in
            let component = URL(fileURLWithPath: token).lastPathComponent
            return component == "codex" || component == "codex.js"
        }) else {
            return nil
        }
        let remaining = tokens.dropFirst(codexIndex + 1)
        guard let resumeIndex = remaining.firstIndex(of: "resume") else {
            return nil
        }
        let sessionIndex = remaining.index(after: resumeIndex)
        guard sessionIndex < tokens.endIndex else {
            return nil
        }
        let sessionID = tokens[sessionIndex]
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        return Self.isCodexSessionID(sessionID) ? sessionID : nil
    }

    private static func isCodexSessionID(_ value: String) -> Bool {
        let parts = value.split(separator: "-")
        guard parts.count == 5 else {
            return false
        }
        let lengths = [8, 4, 4, 4, 12]
        return zip(parts, lengths).allSatisfy { part, length in
            part.count == length && part.allSatisfy(\.isHexDigit)
        }
    }

    private static func codexSessionID(fromRolloutPath rolloutPath: String) -> String? {
        let stem = URL(fileURLWithPath: rolloutPath).deletingPathExtension().lastPathComponent
        guard stem.count >= 36 else {
            return nil
        }
        return String(stem.suffix(36))
    }

    private static func iso8601Now() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: Date())
    }

    private func persistSynthesizedCodexRecord(_ record: AgentSessionRegistryRecord) {
        do {
            try fileManager.createDirectory(at: paths.codexAgentSessionsDirectory,
                                            withIntermediateDirectories: true)
            let url = paths.codexAgentSessionsDirectory
                .appendingPathComponent("codex-\(record.sessionID).json", isDirectory: false)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(record)
            try data.write(to: url, options: [.atomic])
            let records = activeRecords.values.filter { $0.sessionID != record.sessionID } + [record]
            syncRecords(records)
            activeRecords[record.sessionID] = record
        } catch {
            BridgeLogger.server.error("agent panel live codex discovery persist_failed workspace_id=\(record.workspaceID, privacy: .public) panel_id=\(record.panelID ?? "-", privacy: .public) session_id=\(record.sessionID, privacy: .public) error=\(String(describing: error), privacy: .public)")
        }
    }

    private func updateAppServerActiveThread(sessionID: String, threadID: String) {
        guard let record = activeRecords[sessionID],
              Self.isCodexAppServerRuntimeRecord(record) else {
            return
        }
        let rolloutPath = codexRolloutBySessionIDLookup(threadID)
        let transcriptAlreadyMatchesThread = record.transcriptPath?.contains(threadID) == true
        let transcriptPathNeedsUpdate = rolloutPath.map { record.transcriptPath != $0 } ??
            (record.transcriptPath != nil && !transcriptAlreadyMatchesThread)
        guard record.threadID != threadID || transcriptPathNeedsUpdate else {
            return
        }

        let updated = AgentSessionRegistryRecord(version: record.version,
                                                 vendor: record.vendor,
                                                 workspaceID: record.workspaceID,
                                                 sessionID: record.sessionID,
                                                 panelID: record.panelID,
                                                 pid: record.pid,
                                                 cwd: record.cwd,
                                                 createdAt: record.createdAt,
                                                 transcriptPath: rolloutPath,
                                                 tmuxPaneID: record.tmuxPaneID,
                                                 tmuxSocketPath: record.tmuxSocketPath,
                                                 runtime: record.runtime,
                                                 appServerSocket: record.appServerSocket,
                                                 appServerPID: record.appServerPID,
                                                 remoteTUIPID: record.remoteTUIPID,
                                                 threadID: threadID,
                                                 resumeThreadID: record.resumeThreadID ?? record.threadID)

        activeRecords[sessionID] = updated
        sessions[sessionID]?.update(record: updated)
        persistCodexAppServerActiveThreadRecord(updated)
        BridgeLogger.server.info("codex app-server active thread updated session_id=\(sessionID, privacy: .public) thread_id=\(threadID, privacy: .public) transcript_path=\(rolloutPath ?? "-", privacy: .private)")
    }

    private func persistCodexAppServerActiveThreadRecord(_ record: AgentSessionRegistryRecord) {
        do {
            try fileManager.createDirectory(at: paths.codexAgentSessionsDirectory,
                                            withIntermediateDirectories: true)
            let url = paths.codexAgentSessionsDirectory
                .appendingPathComponent("codex-\(record.sessionID).json", isDirectory: false)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(record)
            try data.write(to: url, options: [.atomic])
        } catch {
            BridgeLogger.server.error("codex app-server active thread persist_failed session_id=\(record.sessionID, privacy: .public) thread_id=\(record.threadID ?? "-", privacy: .public) error=\(String(describing: error), privacy: .public)")
        }
    }

    private func ordinaryTmuxProcessMatch(for panel: AgentPanelProcessSnapshot,
                                          effectiveShellPID: Int32) -> AgentSessionRegistryRecord? {
        guard let panelPaneID = panel.tmuxPaneID,
              !panelPaneID.isEmpty,
              let panelSocketPath = panel.tmuxSocketPath,
              !panelSocketPath.isEmpty else {
            return nil
        }

        let candidates = activeRecords.values
            .filter { record in
                guard let recordPaneID = record.tmuxPaneID,
                      recordPaneID == panelPaneID,
                      let recordSocketPath = record.tmuxSocketPath,
                      Self.socketPathsMatch(recordSocketPath, panelSocketPath) else {
                    return false
                }
                return processIsDescendantOrSelf(of: effectiveShellPID, candidate: record.pid)
            }
            .sorted(by: Self.isRecordPreferred(_:_:))
        return candidates.first
    }

    private static func socketPathsMatch(_ lhs: String, _ rhs: String) -> Bool {
        normalizeSocketPath(lhs) == normalizeSocketPath(rhs)
    }

    private static func normalizeSocketPath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("/private/tmp/") {
            return "/tmp/" + trimmed.dropFirst("/private/tmp/".count)
        }
        return trimmed
    }

    private static func isRecordPreferred(_ lhs: AgentSessionRegistryRecord,
                                          _ rhs: AgentSessionRegistryRecord) -> Bool {
        if lhs.vendor == "codex" && rhs.vendor == "codex" {
            let lhsIsAppServer = isCodexAppServerRuntimeRecord(lhs)
            let rhsIsAppServer = isCodexAppServerRuntimeRecord(rhs)
            if lhsIsAppServer != rhsIsAppServer {
                return lhsIsAppServer
            }
        }
        if lhs.createdAt == rhs.createdAt {
            return lhs.sessionID < rhs.sessionID
        }
        return lhs.createdAt > rhs.createdAt
    }

    private func processIsDescendantOrSelf(of ancestorPID: Int32, candidate: Int32) -> Bool {
        guard ancestorPID > 0, candidate > 0 else {
            return false
        }
        var currentPID = candidate
        var visited = Set<Int32>()

        for _ in 0..<32 {
            if currentPID == ancestorPID {
                return true
            }
            if currentPID <= 1 || visited.contains(currentPID) {
                return false
            }
            visited.insert(currentPID)
            guard let parentPID = parentPIDLookup(currentPID), parentPID > 0 else {
                return false
            }
            currentPID = parentPID
        }
        return false
    }

    private func effectiveRecord(for record: AgentSessionRegistryRecord) -> AgentSessionRegistryRecord {
        guard let binding = resolvedPanelBindings[record.sessionID] else {
            return record
        }
        return AgentSessionRegistryRecord(version: record.version,
                                          vendor: record.vendor,
                                          workspaceID: binding.workspaceID,
                                          sessionID: record.sessionID,
                                          panelID: binding.panelID,
                                          pid: record.pid,
                                          cwd: record.cwd,
                                          createdAt: record.createdAt,
                                          transcriptPath: record.transcriptPath,
                                          tmuxPaneID: record.tmuxPaneID,
                                          tmuxSocketPath: record.tmuxSocketPath,
                                          runtime: record.runtime,
                                          appServerSocket: record.appServerSocket,
                                          appServerPID: record.appServerPID,
                                          remoteTUIPID: record.remoteTUIPID,
                                          threadID: record.threadID,
                                          resumeThreadID: record.resumeThreadID)
    }

    private func applyResolvedBinding(sessionID: String,
                                      workspaceID: String,
                                      panelID: String?) {
        let binding = ResolvedPanelBinding(workspaceID: workspaceID, panelID: panelID)
        if resolvedPanelBindings[sessionID] == binding {
            return
        }
        resolvedPanelBindings[sessionID] = binding
        hub.migrateSession(sessionID: sessionID,
                           toWorkspaceID: workspaceID,
                           panelID: panelID)
        guard let sourceRecord = activeRecords[sessionID] else {
            return
        }
        let effective = effectiveRecord(for: sourceRecord)
        activeRecords[sessionID] = effective
        sessions[sessionID]?.update(record: effective)
    }

    private func syncRecords(_ records: [AgentSessionRegistryRecord]) {
        let activeSessionIDs = Set(records.map(\.sessionID))
        for record in records {
            if let session = sessions[record.sessionID] {
                session.update(record: record)
                continue
            }
            guard let vendor = AgentVendorRegistry.resolve(id: record.vendor) else {
                continue
            }
            // A NEW session incarnation (same ID or not) must never accept
            // anchors minted against a previous object: advance the
            // Hub-issued epoch BEFORE the incarnation exists, so every old
            // plan/step/validate fails closed. Workspace/panel migration
            // takes the update() path above and never reaches this.
            hub.beginNewSourceEpoch(sessionID: record.sessionID)
            let session = vendor.makeTranscriptSession(record: record,
                                                       fileManager: fileManager,
                                                       hub: hub,
                                                       socketClient: socketClient,
                                                       chatSubmitEchoRegistry: chatSubmitEchoRegistry)
            sessions[record.sessionID] = session
            session.start()
        }

        let staleSessionIDs = sessions.keys.filter { !activeSessionIDs.contains($0) }
        for sessionID in staleSessionIDs {
            sessions.removeValue(forKey: sessionID)?.stop()
        }
    }

    private func loadRecordEntries(at directory: URL, vendor: String) -> [LoadedAgentSessionRegistryRecord] {
        guard let enumerator = fileManager.enumerator(at: directory,
                                                      includingPropertiesForKeys: [.isRegularFileKey],
                                                      options: [.skipsHiddenFiles]) else {
            return []
        }

        var records = [LoadedAgentSessionRegistryRecord]()
        for case let url as URL in enumerator {
            guard url.pathExtension == "json",
                  let data = try? Data(contentsOf: url),
                  let record = try? JSONDecoder().decode(AgentSessionRegistryRecord.self, from: data),
                  record.version == 1,
                  record.vendor == vendor else {
                continue
            }
            if recordProcessExists(record) {
                records.append(LoadedAgentSessionRegistryRecord(record: record, url: url))
            } else {
                try? fileManager.removeItem(at: url)
            }
        }
        return records
    }

    private func recordProcessExists(_ record: AgentSessionRegistryRecord) -> Bool {
        if Self.isCodexAppServerRuntimeRecord(record) {
            let candidatePIDs = [record.appServerPID, record.remoteTUIPID, record.pid].compactMap { $0 }
            return candidatePIDs.contains { processExists($0) }
        }
        return processExists(record.pid)
    }

    private func processExists(_ pid: Int32) -> Bool {
        guard pid > 0 else {
            return false
        }
        return kill(pid, 0) == 0 || errno == EPERM
    }

    private static func isCodexAppServerRuntimeRecord(_ record: AgentSessionRegistryRecord) -> Bool {
        record.vendor == "codex" && record.runtime == "codex_app_server"
    }
}

struct JSONLFileSourceIdentity: Equatable, Sendable {
    let device: UInt64
    let inode: UInt64
}

enum JSONLFileTailerError: Error {
    case sourceInvalidated
}

// Typed raw-page evidence from one tailer backfill read. Assembled strictly
// after the post-read source fence succeeds, from the reader's ACTUAL scan
// boundary: covered blank lines count, limit-dropped records do not, and
// invalid-UTF8 records are raw evidence. This is the ONLY raw scan
// authority — the tailer keeps no record-based floor/source-start state.
struct JSONLRawFrontier: Equatable, Sendable {
    let readAnyRecord: Bool
    let minimumRawOffset: Int?
    let containsInvalidRecord: Bool
    let reachedSourceStart: Bool
}

struct JSONLBackfillResult: Sendable {
    let didRead: Bool
    let rawFrontier: JSONLRawFrontier?
}

// The tailer's contiguously scanned raw interval under ONE source identity:
// every byte in [minimumRawOffset, replayUpperBoundOffset) has been read
// through a successful source fence. The floor only classifies whether a
// cursor lies inside trusted raw coverage; walks anchor at the fixed
// validated ceiling, never at the floor.
struct JSONLContiguousRawCoverage: Equatable, Sendable {
    let minimumRawOffset: Int
    let replayUpperBoundOffset: Int
    let sourceIdentity: JSONLFileSourceIdentity
}

final class JSONLFileTailer {
    private enum SourceContinuity {
        case valid
        case detached
        case mutated
    }

    private struct SourceSnapshot {
        let identity: JSONLFileSourceIdentity
        let size: Int
        let validatedBoundary: Data
    }

    fileprivate static let sourceValidationBoundaryByteCount = 4096

    private let fileURL: URL
    private let queue: DispatchQueue
    private let bootstrapLineLimit: Int
    private let lineHandler: (Int, String) -> Void
    private let invalidUTF8Handler: ((Int) -> Void)?
    private let invalidationHandler: () -> Void

    private var fd: Int32 = -1
    private var source: DispatchSourceFileSystemObject?
    private var pendingData = Data()
    private var nextReadOffset = 0
    private var pendingLineOffset: Int?
    private(set) var openedSourceIdentity: JSONLFileSourceIdentity?
    // Queue-owned contiguous raw coverage snapshot. Structural seam only:
    // nothing populates it yet — maintenance is the next behavioral row.
    private(set) var contiguousRawCoverage: JSONLContiguousRawCoverage?
    var backfillAfterReadForTesting: (() -> Void)?
    var afterInitialFrontierHookForTesting: (() -> Void)?
    // Per-instance queue identity: the key object itself is unique to this
    // tailer, so a queue shared across tailer generations can never observe
    // a stale association (cleared again in deinit for hygiene).
    private let queueIdentityKey = DispatchSpecificKey<UInt8>()
    private var validatedBoundaryOffset = 0
    private var validatedBoundary = Data()

    init(fileURL: URL,
         queue: DispatchQueue,
         bootstrapLineLimit: Int = transcriptBootstrapLineLimit,
         lineHandler: @escaping (Int, String) -> Void,
         invalidUTF8Handler: ((Int) -> Void)? = nil,
         invalidationHandler: @escaping () -> Void) {
        self.fileURL = fileURL
        self.queue = queue
        self.bootstrapLineLimit = bootstrapLineLimit
        self.lineHandler = lineHandler
        self.invalidUTF8Handler = invalidUTF8Handler
        self.invalidationHandler = invalidationHandler
        queue.setSpecific(key: queueIdentityKey, value: 1)
    }

    deinit {
        queue.setSpecific(key: queueIdentityKey, value: nil)
    }

    var isOnTailerQueue: Bool {
        DispatchQueue.getSpecific(key: queueIdentityKey) != nil
    }

    // Reentrant-safe: running on the tailer queue executes the body in
    // place; any other context hops onto the queue synchronously.
    private func syncOnQueue<T>(_ body: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: queueIdentityKey) != nil {
            return try body()
        }
        return try queue.sync(execute: body)
    }

    func start() throws {
        // The armed vnode watcher handles events on the tailer queue; the
        // startup critical section (frontier adoption, bootstrap read,
        // append drain, publication) must not interleave with it.
        try syncOnQueue { try startOnQueue() }
    }

    private func startOnQueue() throws {
        let fd = open(fileURL.path, O_RDONLY)
        guard fd >= 0 else {
            throw POSIXError(.ENOENT)
        }
        self.fd = fd
        do {
            var fileStatus = stat()
            guard fstat(fd, &fileStatus) == 0 else {
                let posixCode = POSIXErrorCode(rawValue: errno) ?? .EIO
                throw POSIXError(posixCode)
            }
            openedSourceIdentity = JSONLFileSourceIdentity(device: UInt64(fileStatus.st_dev),
                                                           inode: UInt64(fileStatus.st_ino))

            // Arm the vnode watcher as soon as the opened descriptor has an
            // identity. A truncate-and-regrow after this point must leave a
            // filesystem event for the live tail; work done before this
            // point is simply part of the source we are opening.
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd,
                eventMask: [.write, .extend, .delete, .rename, .revoke],
                queue: queue)
            source.setEventHandler { [weak self] in
                self?.handleFileEvent()
            }
            source.setCancelHandler { [fd] in
                close(fd)
            }
            self.source = source
            source.resume()

            // Adopt an initial EOF only after two matching descriptor
            // snapshots agree with the current path. This prevents a
            // truncate-and-regrow during startup from being mistaken for a
            // stable initial frontier.
            guard establishInitialValidatedFrontier() else {
                throw JSONLFileTailerError.sourceInvalidated
            }
            afterInitialFrontierHookForTesting?()
            pendingData.removeAll(keepingCapacity: false)
            pendingLineOffset = nil
            // A record whose newline had not been written by the fixed
            // startup EOF must not be lost: later appends complete it, so
            // its bytes seed the pending buffer at their ORIGINAL offset.
            try seedPendingTailFragment()

            let bootstrapPage = try JSONLFileReader.readBeforePage(
                fileURL: fileURL,
                beforeOffset: nextReadOffset,
                limit: bootstrapLineLimit)
            guard currentSourceIsValid(minimumSize: nextReadOffset) else {
                throw JSONLFileTailerError.sourceInvalidated
            }

            // Drain any append that landed after the fixed bootstrap EOF.
            // Publication waits until the post-read fence succeeds.
            let appendedRecords = readAvailableRecords()
            guard currentSourceIsValid(minimumSize: nextReadOffset),
                  refreshValidatedBoundary(),
                  currentSourceIsValid(minimumSize: nextReadOffset) else {
                throw JSONLFileTailerError.sourceInvalidated
            }
            deliver(bootstrapPage.records + appendedRecords)
            // Contiguous coverage is established only after the FINAL fence:
            // the floor is the bootstrap page's actual scan boundary (never
            // a record offset) and the ceiling is the fixed validated EOF —
            // the appended drain is contiguous with the bootstrap window.
            if let openedSourceIdentity {
                contiguousRawCoverage = JSONLContiguousRawCoverage(
                    minimumRawOffset: bootstrapPage.minimumRawOffset,
                    replayUpperBoundOffset: validatedBoundaryOffset,
                    sourceIdentity: openedSourceIdentity)
            }
        } catch {
            stop()
            throw error
        }
    }

    func backfill(beforeOffset: Int,
                  limit: Int,
                  includeAnchorLine: Bool = false) throws -> JSONLBackfillResult {
        guard (beforeOffset > 0 || includeAnchorLine), limit > 0 else {
            return JSONLBackfillResult(didRead: false, rawFrontier: nil)
        }
        guard currentSourceIsValid(minimumSize: nextReadOffset) else {
            throw JSONLFileTailerError.sourceInvalidated
        }
        // Honor the caller's anchor. A fresh client may request a newer range
        // than the deepest page another client already read; neither the
        // earliest observed offset nor a sticky start-of-file marker may
        // redirect or block that request.
        let page = try JSONLFileReader.readBeforePage(
            fileURL: fileURL,
            beforeOffset: beforeOffset,
            limit: limit,
            includeAnchorLine: includeAnchorLine)
        backfillAfterReadForTesting?()
        guard currentSourceIsValid(minimumSize: nextReadOffset) else {
            throw JSONLFileTailerError.sourceInvalidated
        }
        let records = page.records
        // The frontier is assembled ONLY after the post-read source fence
        // succeeded (a fence failure throws and exposes nothing) and comes
        // from the reader's ACTUAL scan boundary: blank lines it covered
        // count, records the limit dropped do not, and invalid-UTF8 records
        // are raw evidence — an all-invalid page never masquerades as an
        // eventless source start, and a blank-only page still advances the
        // boundary.
        let rawFrontier = JSONLRawFrontier(
            readAnyRecord: !records.isEmpty,
            minimumRawOffset: page.minimumRawOffset,
            containsInvalidRecord: records.contains {
                if case .invalidUTF8 = $0 { return true }
                return false
            },
            reachedSourceStart: page.reachedSourceStart)
        // Connectivity is judged from the page's ACTUAL scanned interval:
        // the floor lowers only when the page touches/overlaps the current
        // interval within the validated ceiling. Blank/eventless/invalid
        // bytes all count as scanned here — semantic trust is the session's
        // concern, not the tailer's.
        if let coverage = contiguousRawCoverage,
           coverage.sourceIdentity == openedSourceIdentity,
           page.maximumRawOffsetExclusive <= coverage.replayUpperBoundOffset,
           page.maximumRawOffsetExclusive >= coverage.minimumRawOffset,
           page.minimumRawOffset < coverage.minimumRawOffset {
            contiguousRawCoverage = JSONLContiguousRawCoverage(
                minimumRawOffset: page.minimumRawOffset,
                replayUpperBoundOffset: coverage.replayUpperBoundOffset,
                sourceIdentity: coverage.sourceIdentity)
        }
        guard !records.isEmpty else {
            return JSONLBackfillResult(didRead: false, rawFrontier: rawFrontier)
        }

        deliver(records)
        return JSONLBackfillResult(didRead: true, rawFrontier: rawFrontier)
    }

    func validateCurrentSource() throws {
        guard currentSourceIsValid(minimumSize: nextReadOffset) else {
            throw JSONLFileTailerError.sourceInvalidated
        }
    }

    func stop() {
        // Callers may stop from any thread while the vnode handler is
        // mid-flight on the tailer queue; tearing down shared state (fd,
        // validated boundary) must serialize with it. Reentrant-safe: the
        // handler's own stop() calls execute in place.
        syncOnQueue { stopOnQueue() }
    }

    private func stopOnQueue() {
        openedSourceIdentity = nil
        contiguousRawCoverage = nil
        validatedBoundaryOffset = 0
        validatedBoundary.removeAll(keepingCapacity: false)
        if let source {
            self.source = nil
            source.cancel()
            fd = -1
            return
        }
        if fd >= 0 {
            close(fd)
            fd = -1
        }
    }

    private func handleFileEvent() {
        guard let source else {
            return
        }
        let events = source.data
        if events.contains(.delete) || events.contains(.rename) || events.contains(.revoke) {
            // The unlinked file's bytes stay readable through the open fd:
            // drain the final appends (e.g. a session-end journal line
            // written just before the wrapper removed the file) BEFORE
            // tearing the tailer down.
            drainDetachedSourceAndInvalidate()
            return
        }
        switch sourceContinuity(minimumSize: nextReadOffset) {
        case .detached:
            // vnode delivery can coalesce an append followed by unlink into
            // a write-only event. The open descriptor still names the old
            // immutable generation, so its final complete lines are safe to
            // publish before switching epochs.
            drainDetachedSourceAndInvalidate()
            return
        case .mutated:
            // Same-inode truncation/rewrite can expose bytes from a different
            // logical generation through this descriptor. Never drain it.
            stop()
            invalidationHandler()
            return
        case .valid:
            break
        }
        let records = readAvailableRecords()
        switch sourceContinuity(minimumSize: nextReadOffset) {
        case .detached:
            // The path detached after the pre-read fence. All bytes just
            // read still came from the old descriptor and precede the epoch
            // switch, so preserve them exactly once.
            drainDetachedSourceAndInvalidate(alreadyRead: records)
            return
        case .mutated:
            stop()
            invalidationHandler()
            return
        case .valid:
            break
        }
        guard refreshValidatedBoundary() else {
            if sourceContinuity(minimumSize: nextReadOffset) == .detached {
                drainDetachedSourceAndInvalidate(alreadyRead: records)
                return
            }
            stop()
            invalidationHandler()
            return
        }
        switch sourceContinuity(minimumSize: nextReadOffset) {
        case .valid:
            deliver(records)
            // A fully fenced live append only ADVANCES the validated
            // ceiling; the floor never moves on the live path.
            if let coverage = contiguousRawCoverage,
               coverage.sourceIdentity == openedSourceIdentity {
                contiguousRawCoverage = JSONLContiguousRawCoverage(
                    minimumRawOffset: coverage.minimumRawOffset,
                    replayUpperBoundOffset: max(coverage.replayUpperBoundOffset,
                                                validatedBoundaryOffset),
                    sourceIdentity: coverage.sourceIdentity)
            }
        case .detached:
            // Unlink/rename can land after the proposed boundary was
            // adopted but before publication. The buffered bytes still came
            // from the old descriptor and must precede invalidation.
            drainDetachedSourceAndInvalidate(alreadyRead: records)
        case .mutated:
            stop()
            invalidationHandler()
        }
    }

    private func drainDetachedSourceAndInvalidate(
        alreadyRead: [JSONLFileRecord] = []
    ) {
        let records = alreadyRead + readAvailableRecords()
        if openedDescriptorPreservesValidatedPrefix(minimumSize: nextReadOffset) {
            deliver(records)
        }
        stop()
        invalidationHandler()
    }

    private func openedDescriptorPreservesValidatedPrefix(minimumSize: Int) -> Bool {
        guard fd >= 0, let openedSourceIdentity else {
            return false
        }
        var fileStatus = stat()
        guard fstat(fd, &fileStatus) == 0,
              JSONLFileSourceIdentity(device: UInt64(fileStatus.st_dev),
                                      inode: UInt64(fileStatus.st_ino)) == openedSourceIdentity,
              Int(fileStatus.st_size) >= minimumSize,
              let boundary = Self.readBoundary(fileDescriptor: fd,
                                               throughOffset: validatedBoundaryOffset),
              boundary == validatedBoundary else {
            return false
        }
        return true
    }

    private func currentSourceIsValid(minimumSize: Int) -> Bool {
        sourceContinuity(minimumSize: minimumSize) == .valid
    }

    private func sourceContinuity(minimumSize: Int) -> SourceContinuity {
        guard let openedSourceIdentity else {
            return .mutated
        }
        guard let snapshot = Self.sourceSnapshot(at: fileURL,
                                                 boundaryOffset: validatedBoundaryOffset) else {
            return .detached
        }
        guard snapshot.identity == openedSourceIdentity else {
            return .detached
        }
        guard snapshot.size >= minimumSize,
              snapshot.validatedBoundary == validatedBoundary else {
            return .mutated
        }
        return .valid
    }

    private static func sourceSnapshot(at url: URL,
                                       boundaryOffset: Int) -> SourceSnapshot? {
        let currentFD = open(url.path, O_RDONLY)
        guard currentFD >= 0 else {
            return nil
        }
        defer { close(currentFD) }
        var fileStatus = stat()
        guard fstat(currentFD, &fileStatus) == 0 else {
            return nil
        }
        guard let boundary = readBoundary(fileDescriptor: currentFD,
                                          throughOffset: boundaryOffset) else {
            return nil
        }
        return SourceSnapshot(identity: JSONLFileSourceIdentity(device: UInt64(fileStatus.st_dev),
                                                                inode: UInt64(fileStatus.st_ino)),
                              size: Int(fileStatus.st_size),
                              validatedBoundary: boundary)
    }

    private static func sourceSnapshot(fileDescriptor: Int32) -> SourceSnapshot? {
        var fileStatus = stat()
        guard fstat(fileDescriptor, &fileStatus) == 0 else {
            return nil
        }
        let size = Int(fileStatus.st_size)
        guard let boundary = readBoundary(fileDescriptor: fileDescriptor,
                                          throughOffset: size) else {
            return nil
        }
        return SourceSnapshot(identity: JSONLFileSourceIdentity(device: UInt64(fileStatus.st_dev),
                                                                inode: UInt64(fileStatus.st_ino)),
                              size: size,
                              validatedBoundary: boundary)
    }

    private func establishInitialValidatedFrontier() -> Bool {
        guard fd >= 0, let openedSourceIdentity else {
            return false
        }
        for _ in 0..<3 {
            guard let first = Self.sourceSnapshot(fileDescriptor: fd),
                  first.identity == openedSourceIdentity,
                  let pathSnapshot = Self.sourceSnapshot(at: fileURL,
                                                         boundaryOffset: first.size),
                  let second = Self.sourceSnapshot(fileDescriptor: fd),
                  second.identity == first.identity,
                  second.size == first.size,
                  second.validatedBoundary == first.validatedBoundary,
                  pathSnapshot.identity == first.identity,
                  pathSnapshot.size >= first.size,
                  pathSnapshot.validatedBoundary == first.validatedBoundary,
                  lseek(fd, off_t(first.size), SEEK_SET) == off_t(first.size) else {
                continue
            }
            nextReadOffset = first.size
            validatedBoundaryOffset = first.size
            validatedBoundary = first.validatedBoundary
            return true
        }
        return false
    }

    private func refreshValidatedBoundary() -> Bool {
        guard fd >= 0,
              let openedSourceIdentity,
              let proposedBoundary = Self.readBoundary(fileDescriptor: fd,
                                                       throughOffset: nextReadOffset),
              currentSourceIsValid(minimumSize: nextReadOffset),
              let proposedPathSnapshot = Self.sourceSnapshot(at: fileURL,
                                                             boundaryOffset: nextReadOffset),
              proposedPathSnapshot.identity == openedSourceIdentity,
              proposedPathSnapshot.size >= nextReadOffset,
              proposedPathSnapshot.validatedBoundary == proposedBoundary else {
            return false
        }
        validatedBoundaryOffset = nextReadOffset
        validatedBoundary = proposedBoundary
        return true
    }

    fileprivate static func readBoundary(fileDescriptor: Int32,
                                         throughOffset: Int) -> Data? {
        guard throughOffset >= 0 else {
            return nil
        }
        let byteCount = min(sourceValidationBoundaryByteCount, throughOffset)
        guard byteCount > 0 else {
            return Data()
        }
        let startOffset = throughOffset - byteCount
        var bytes = [UInt8](repeating: 0, count: byteCount)
        var totalBytesRead = 0
        while totalBytesRead < byteCount {
            let bytesRead = bytes.withUnsafeMutableBytes { buffer in
                pread(fileDescriptor,
                      buffer.baseAddress?.advanced(by: totalBytesRead),
                      byteCount - totalBytesRead,
                      off_t(startOffset + totalBytesRead))
            }
            if bytesRead > 0 {
                totalBytesRead += bytesRead
                continue
            }
            if bytesRead < 0, errno == EINTR {
                continue
            }
            return nil
        }
        return Data(bytes)
    }

    // Backward-scan from the fixed validated EOF in 8KiB chunks to the last
    // newline, then read the trailing fragment in one allocation. Peak
    // memory is O(fragment length + one scan chunk); the fragment is
    // whatever the source already holds, never an amplification of it.
    private func seedPendingTailFragment() throws {
        guard nextReadOffset > 0 else {
            return
        }
        let chunkSize = 8192
        var scanEnd = nextReadOffset
        var lastNewlineOffset: Int?
        while scanEnd > 0, lastNewlineOffset == nil {
            let start = max(0, scanEnd - chunkSize)
            let chunk = try readRange(offset: start, length: scanEnd - start)
            if let index = chunk.lastIndex(of: 0x0a) {
                lastNewlineOffset = start + chunk.distance(from: chunk.startIndex, to: index)
            }
            scanEnd = start
        }
        let fragmentStart = lastNewlineOffset.map { $0 + 1 } ?? 0
        guard fragmentStart < nextReadOffset else {
            return
        }
        pendingData = try readRange(offset: fragmentStart,
                                    length: nextReadOffset - fragmentStart)
        pendingLineOffset = fragmentStart
    }

    private func readRange(offset: Int, length: Int) throws -> Data {
        var data = Data(count: length)
        try data.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) in
            var totalBytesRead = 0
            while totalBytesRead < length {
                let bytesRead = pread(fd,
                                      buffer.baseAddress?.advanced(by: totalBytesRead),
                                      length - totalBytesRead,
                                      off_t(offset + totalBytesRead))
                if bytesRead > 0 {
                    totalBytesRead += bytesRead
                    continue
                }
                if bytesRead < 0, errno == EINTR {
                    continue
                }
                throw JSONLFileTailerError.sourceInvalidated
            }
        }
        return data
    }

    private func readAvailableRecords() -> [JSONLFileRecord] {
        guard fd >= 0 else {
            return []
        }

        var chunk = [UInt8](repeating: 0, count: 8192)
        while true {
            let readStartOffset = nextReadOffset
            let bytesRead = read(fd, &chunk, chunk.count)
            if bytesRead > 0 {
                if pendingData.isEmpty {
                    pendingLineOffset = readStartOffset
                }
                pendingData.append(chunk, count: bytesRead)
                nextReadOffset += bytesRead
                continue
            }
            if bytesRead == 0 {
                break
            }
            if errno == EINTR {
                continue
            }
            break
        }

        return drainCompleteRecords()
    }

    private func drainCompleteRecords() -> [JSONLFileRecord] {
        var records = [JSONLFileRecord]()
        while let newlineIndex = pendingData.firstIndex(of: 0x0a) {
            let lineData = pendingData.prefix(upTo: newlineIndex)
            let lineOffset = pendingLineOffset ?? nextReadOffset
            let consumedBytes = pendingData.distance(from: pendingData.startIndex, to: newlineIndex) + 1
            pendingData.removeSubrange(...newlineIndex)
            if pendingData.isEmpty {
                pendingLineOffset = nil
            } else {
                pendingLineOffset = lineOffset + consumedBytes
            }
            guard !lineData.isEmpty else {
                continue
            }
            if let line = String(data: lineData, encoding: .utf8) {
                records.append(.line(offset: lineOffset, value: line))
            } else {
                records.append(.invalidUTF8(offset: lineOffset))
            }
        }
        return records
    }

    private func deliver(_ records: [JSONLFileRecord]) {
        for record in records {
            switch record {
            case .line(let offset, let value):
                lineHandler(offset, value)
            case .invalidUTF8(let offset):
                invalidUTF8Handler?(offset)
            }
        }
    }
}

struct ClaudeHistoricalClosureIndexStats: Equatable {
    let scanPassCount: Int
    let readByteCount: Int
    let completeLineCount: Int
}

final class ClaudeTranscriptSession: AgentTranscriptSession {
    private static let defaultHistoricalPartialLineByteLimit = 16 * 1024 * 1024

    private let queue: DispatchQueue
    private let fileManager: FileManager
    private let hub: AgentEventHub
    private let socketClient: TideyCommandSending?
    private let chatSubmitEchoRegistry: ChatSubmitEchoRegistry
    private let historicalPartialLineByteLimit: Int
    private let promptNotificationDeduper = AgentInteractivePromptNotificationDeduper()

    private var record: AgentSessionRegistryRecord
    // Three-state lifecycle feed (single product-semantic truth): the LIVE
    // tail (bootstrap suffix + appended lines) is linear, so re-tailing
    // after a Bridge restart converges to the same final state. Historical
    // backfill NEVER touches the lifecycle (see lifecycle* helpers).
    var lifecycleStoreForTesting: AgentSessionLifecycleStore?
    private var lifecycleStore: AgentSessionLifecycleStore {
        lifecycleStoreForTesting ?? AgentSessionLifecycle.store
    }
    private var lifecycleIdentity: AgentSessionLifecycleIdentity {
        AgentSessionLifecycleIdentity(workspaceID: record.workspaceID,
                                      panelID: record.panelID ?? "",
                                      sessionID: record.sessionID)
    }
    // One generation per live instance/source epoch — never a constant. A
    // source switch (delete-and-recreate, registry path change) claims a
    // fresh generation so the old tail's late events are stale by
    // construction.
    private var lifecycleGeneration = AgentSessionLifecycle.nextGeneration()
    // AskUserQuestion tool calls whose lifecycle blocker is open. Keyed by
    // tool_use_id; the matching tool_result resolves the blocker even when
    // the CARD shape is unsupported (e.g. multiSelect).
    private var openLifecycleQuestionTokensByToolCallID = [String: [String]]()
    // Typed hook journal (wrapper-written JSONL): PermissionRequest PREPARES
    // the identity; only the actual permission_prompt notification opens the
    // needs_input blocker (an auto-allowed PermissionRequest never leaves a
    // false needs_input).
    private var hookTailer: JSONLFileTailer?
    var hookJournalURLOverrideForTesting: URL?
    // FIFO of prepared PermissionRequest tool ids; the matching
    // permission_prompt notification CONSUMES the head so two sequential
    // permissions correlate to their own blockers.
    private var preparedPermissionToolUseIDs: [String] = []
    // Blocker suffixes ("<tool_use_id>" or the generic "prompt") currently
    // open from permission_prompt notifications.
    private var openLifecyclePermissionSuffixes = Set<String>()
    // Hook journal source-epoch and dedupe state: one wrapper instance is
    // one epoch; a retired wrapper's late events and duplicate deliveries
    // are rejected.
    private var currentHookEpoch: String?
    private var retiredHookEpochs = Set<String>()
    private var seenHookEventIDs = Set<String>()
    private var seenHookEventIDOrder: [String] = []
    // Turn identity + cross-stream correlation. The transcript stream is
    // linear; hook events are a SECOND stream. Correlation is EXPLICIT —
    // never wall-clock: each UserPromptSubmit hook opens a hook-turn token
    // (in journal order), the transcript opener that follows binds the
    // newest pending token to its turn id, and a hook terminal/prompt acts
    // ONLY on the turn its token is bound to. An old turn's late idle or
    // permission notification can therefore never touch a newer turn —
    // including two turns inside the same wall-clock second.
    private var lifecycleActiveTurnID: String?
    // Hook-turn machine (per journal epoch). Queued prompts are a REAL
    // production case (Claude Code accepts a second UserPromptSubmit while
    // the first turn is still processing): openHookTurnTokens is a FIFO —
    // Claude Code completes queued turns in submission order, so a
    // terminal/idle/stop always closes the OLDEST still-open token, never
    // whichever token happens to be most recently opened.
    private var hookTurnCounter = 0
    private var openHookTurnTokens: [Int] = []
    private var pendingHookTurnTokens: [Int] = []
    private var hookTurnBindings: [Int: String] = [:]
    private var hookSawPromptSubmit = false
    private var lastHookSeqByEpoch: [String: Int] = [:]
    // parentUuid lineage: uuid -> the OWNING USER TURN's uuid. A synchronous
    // parse can process an assistant line whose owning turn is A (via
    // parentUuid chain) WHILE a queued turn B has already become the
    // "current" active turn (Claude Code can process a queued prompt B
    // before A's own trailing assistant lines are all appended/consumed).
    // `lifecycleActiveTurnID` at parse time is therefore NOT a reliable
    // proxy for "which turn does this specific line belong to" — only the
    // parentUuid chain is. Bounded (LRU-ish by insertion order trim).
    private var lifecycleTurnLineageByUuid: [String: String] = [:]
    private var lifecycleTurnLineageOrder: [String] = []

    // Live-only lifecycle feed: every mutation is dropped while a
    // historical backfill replay is running — paging up may never change
    // the live three-state status.
    // `adoptNewTurn` is true for genuine user openers: a new prompt is a
    // NEW turn identity even while the previous turn is still active (B's
    // opener before A's terminal must not leave A's identity in place).
    private func lifecycleBeginTurn(turnID: String, adoptNewTurn: Bool) {
        guard !isBackfillingHistory else { return }
        if adoptNewTurn || lifecycleActiveTurnID == nil {
            // This uuid IS a fresh turn root: it owns itself, overriding
            // whatever the generic parentUuid inheritance step recorded
            // (a real new-turn opener's parentUuid points at the PRIOR
            // turn's last line, which the generic step would otherwise
            // have inherited).
            recordLifecycleTurnLineageRoot(turnID)
            lifecycleActiveTurnID = turnID
            // The newest pending hook-turn token belongs to this opener;
            // older pendings were submissions that never opened a
            // transcript turn (local commands) and stay unbound.
            if let pending = pendingHookTurnTokens.last {
                hookTurnBindings[pending] = turnID
                while hookTurnBindings.count > 16 {
                    if let oldest = hookTurnBindings.keys.min() {
                        hookTurnBindings.removeValue(forKey: oldest)
                    }
                }
            }
            pendingHookTurnTokens = []
        }
        lifecycleStore.beginTurn(lifecycleIdentity,
                                 vendor: record.vendor,
                                 generation: lifecycleGeneration,
                                 turnID: lifecycleActiveTurnID)
    }

    // `expectedTurnID` fences CROSS-STREAM terminals: the terminal acts only
    // when the turn it was bound to is still the active one. Transcript
    // terminals pass nil (the stream itself is linear).
    private func lifecycleEndTurn(expectedTurnID: String? = nil) {
        guard !isBackfillingHistory else { return }
        if let expectedTurnID, lifecycleActiveTurnID != expectedTurnID {
            return  // stale terminal for an older turn
        }
        // The store's turn terminal resolves every blocker; the local
        // tracking must not survive it.
        openLifecycleQuestionTokensByToolCallID = [:]
        openLifecyclePermissionSuffixes = []
        preparedPermissionToolUseIDs = []
        let turnID = lifecycleActiveTurnID
        lifecycleActiveTurnID = nil
        // Purge any hook token(s) bound to THIS turn: a transcript-side
        // terminal (turn_duration, interrupt) ends the turn directly and
        // must not leave an orphaned hook token in the FIFO queue to
        // silently steal a LATER turn's idle/stop resolution.
        if let turnID {
            let orphaned = hookTurnBindings.filter { $0.value == turnID }.keys
            for token in orphaned {
                hookTurnBindings.removeValue(forKey: token)
                openHookTurnTokens.removeAll { $0 == token }
            }
        }
        // The terminal names the turn it ends (nil ends unconditionally
        // when no opener was ever seen): turn A's late terminal can never
        // end turn B in the store either.
        lifecycleStore.endTurn(lifecycleIdentity,
                               vendor: record.vendor,
                               generation: lifecycleGeneration,
                               turnID: turnID)
    }

    // Closes the current hook-turn token and returns the transcript turn it
    // may terminate: the bound turn id, or nil when the token never bound
    // (a local-command submission — nothing to end). Without ANY observed
    // prompt-submit this epoch (bootstrap joined mid-turn) the machine runs
    // in legacy mode and the current turn is the target.
    // Records uuid -> owning-user-turn lineage for EVERY consumed line
    // (assistant, user, system alike), inherited via parentUuid. A line
    // with no resolvable parent is self-owning (a fresh root). Genuine new
    // turn openers OVERRIDE this via `recordLifecycleTurnLineageRoot`
    // (called from `lifecycleBeginTurn(adoptNewTurn: true)`), since a new
    // turn's own parentUuid points at the PRIOR turn's tail and must not
    // be inherited.
    private func recordLifecycleTurnLineage(object: [String: Any]) {
        guard let uuid = object["uuid"] as? String else { return }
        let parentUuid = object["parentUuid"] as? String
        // Only record an entry when the parent chain actually RESOLVES to
        // a known owning turn. Eagerly self-anchoring an unresolvable line
        // (no parentUuid, or a parent this map has no record of — e.g. a
        // truncated bootstrap window) would permanently shadow the correct
        // fallback (`lifecycleOwningTurnID` falling through to the current
        // `lifecycleActiveTurnID`, the best remaining evidence) with a
        // wrong self-reference.
        guard let parentUuid, let owningTurn = lifecycleTurnLineageByUuid[parentUuid] else {
            return
        }
        setLifecycleTurnLineage(uuid: uuid, owningTurn: owningTurn)
    }

    private func recordLifecycleTurnLineageRoot(_ uuid: String) {
        setLifecycleTurnLineage(uuid: uuid, owningTurn: uuid)
    }

    private func setLifecycleTurnLineage(uuid: String, owningTurn: String) {
        if lifecycleTurnLineageByUuid[uuid] == nil {
            lifecycleTurnLineageOrder.append(uuid)
            while lifecycleTurnLineageOrder.count > 4000 {
                lifecycleTurnLineageByUuid.removeValue(forKey: lifecycleTurnLineageOrder.removeFirst())
            }
        }
        lifecycleTurnLineageByUuid[uuid] = owningTurn
    }

    // The OWNING USER TURN for a given line's uuid — the correct source
    // identity for a turn-scoped opener, as opposed to `lifecycleActiveTurnID`
    // (whatever turn happens to be current AT PARSE TIME, which can already
    // be a LATER queued turn by the time this line's opener is processed).
    private func lifecycleOwningTurnID(for uuid: String) -> String? {
        // Priority: an actually-resolved parentUuid chain (the strongest
        // evidence) > the current active turn (legacy/truncated-bootstrap
        // evidence, where no parent chain reaches a known root) > this
        // line's own uuid as a last resort (only when no turn has ever
        // been observed at all).
        lifecycleTurnLineageByUuid[uuid] ?? lifecycleActiveTurnID ?? uuid
    }

    private func closeHookTurnAndResolveTarget() -> (shouldEnd: Bool, expectedTurnID: String?) {
        guard hookSawPromptSubmit else {
            return (true, nil)  // legacy mode: no tokens to correlate with
        }
        guard !openHookTurnTokens.isEmpty else {
            return (false, nil)  // duplicate/late terminal: token already closed
        }
        let token = openHookTurnTokens.removeFirst()  // FIFO: oldest first
        pendingHookTurnTokens.removeAll { $0 == token }
        guard let boundTurnID = hookTurnBindings.removeValue(forKey: token) else {
            return (false, nil)  // never opened a transcript turn (local command)
        }
        return (true, boundTurnID)
    }

    private func lifecycleOpenQuestionBlocker(toolCallID: String,
                                              lifecycleToken: String,
                                              sourceTurnID: String?) {
        guard !isBackfillingHistory else { return }
        openLifecycleQuestionTokensByToolCallID[toolCallID, default: []].append(lifecycleToken)
        // Fenced to the SOURCE turn the AskUserQuestion event itself
        // belongs to (the assistant message's own uuid) — NOT a fresh read
        // of "whatever is current right now", which would trivially always
        // match itself and fence nothing.
        lifecycleStore.openBlocker(lifecycleIdentity,
                                   vendor: record.vendor,
                                   generation: lifecycleGeneration,
                                   blockerID: "question:\(lifecycleToken)",
                                   kind: .userQuestion,
                                   expectedTurnID: sourceTurnID)
    }

    private func lifecycleResolveQuestionBlocker(toolCallID: String,
                                                 exactLifecycleToken: String? = nil) {
        guard !isBackfillingHistory else { return }
        var lifecycleTokens = openLifecycleQuestionTokensByToolCallID[toolCallID] ?? []
        guard lifecycleTokens.isEmpty == false else { return }
        let tokenIndex: Int
        if let exactLifecycleToken {
            guard let exactIndex = lifecycleTokens.firstIndex(of: exactLifecycleToken) else {
                return
            }
            tokenIndex = exactIndex
        } else {
            tokenIndex = lifecycleTokens.startIndex
        }
        let lifecycleToken = lifecycleTokens.remove(at: tokenIndex)
        if lifecycleTokens.isEmpty {
            openLifecycleQuestionTokensByToolCallID.removeValue(forKey: toolCallID)
        } else {
            openLifecycleQuestionTokensByToolCallID[toolCallID] = lifecycleTokens
        }
        lifecycleStore.resolveBlocker(lifecycleIdentity,
                                      vendor: record.vendor,
                                      generation: lifecycleGeneration,
                                      blockerID: "question:\(lifecycleToken)")
    }

    private func lifecycleEndSession() {
        lifecycleStore.endSession(lifecycleIdentity, vendor: record.vendor, generation: lifecycleGeneration)
    }

    private func lifecycleResolvePermissionBlocker(toolCallID: String) {
        guard !isBackfillingHistory else { return }
        var suffixes: [String] = []
        if openLifecyclePermissionSuffixes.remove(toolCallID) != nil {
            suffixes.append(toolCallID)
        }
        // A generic (id-less) permission blocker is resolved by ANY
        // tool_result: a result can only exist after the prompt was decided.
        if openLifecyclePermissionSuffixes.remove("prompt") != nil {
            suffixes.append("prompt")
        }
        for suffix in suffixes {
            lifecycleStore.resolveBlocker(lifecycleIdentity,
                                          vendor: record.vendor,
                                          generation: lifecycleGeneration,
                                          blockerID: "permission:\(suffix)")
        }
    }

    // MARK: - Typed hook journal (A6)

    private func hookJournalURL() -> URL {
        hookJournalURLOverrideForTesting
            ?? BridgePaths().claudeAgentSessionsDirectory
                .appendingPathComponent("claude-hooks-\(record.sessionID).jsonl", isDirectory: false)
    }

    private func resolveHookJournalIfPossible() {
        guard hookTailer == nil else {
            return
        }
        let url = hookJournalURL()
        guard fileManager.fileExists(atPath: url.path) else {
            return
        }
        let tailer = JSONLFileTailer(fileURL: url,
                                     queue: queue,
                                     lineHandler: { [weak self] _, line in
                                         self?.consumeHookLine(line)
                                     },
                                     invalidationHandler: { [weak self] in
                                         guard let self else { return }
                                         self.hookTailer?.stop()
                                         self.hookTailer = nil
                                         // A recreated journal (new wrapper run for the
                                         // same session) re-resolves on the next tick.
                                         self.startResolver()
                                     })
        do {
            try tailer.start()
            hookTailer = tailer
        } catch {
            // Journal not readable yet; the resolver keeps retrying.
        }
    }

    // Hook journal lines are the wrapper's typed envelopes:
    //   v2: {"v":2,"event":…,"ts":…,"epoch":…,"event_id":…,"payload_b64":…}
    //   v1: {"v":1,"event":…,"ts":…,"wrapper_pid":N,"payload":{…}}
    // Only permission_prompt opens needs_input; PermissionRequest merely
    // prepares the stable blocker identity (an auto-allow leaves no trace).
    // Turn terminals stay owned by the transcript (`turn_duration`) and the
    // idle_prompt notification — the Stop hook is NOT a terminal (a Stop
    // hook may prevent continuation).
    private func consumeHookLine(_ line: String) {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let event = object["event"] as? String else {
            return
        }
        // Duplicate delivery: one envelope, one effect.
        if let eventID = object["event_id"] as? String {
            guard seenHookEventIDs.contains(eventID) == false else {
                return
            }
            seenHookEventIDs.insert(eventID)
            seenHookEventIDOrder.append(eventID)
            while seenHookEventIDOrder.count > 512 {
                seenHookEventIDs.remove(seenHookEventIDOrder.removeFirst())
            }
        }
        // Source-epoch gate: one wrapper instance per epoch. Adoption is by
        // wrapper START TIME, never by message kind alone — a retired
        // wrapper's LATE session-start can never re-adopt the old epoch.
        if let epoch = object["epoch"] as? String, epoch != "unknown" {
            if retiredHookEpochs.contains(epoch) {
                return
            }
            if let current = currentHookEpoch, current != epoch {
                if Self.hookEpochStart(epoch) >= Self.hookEpochStart(current) {
                    retiredHookEpochs.insert(current)
                    currentHookEpoch = epoch
                    resetHookTurnMachine()
                } else {
                    retiredHookEpochs.insert(epoch)
                    return
                }
            } else if currentHookEpoch == nil {
                currentHookEpoch = epoch
            }
            // Per-epoch monotonic sequence: a replayed/duplicated envelope
            // whose seq does not advance is dropped.
            if let seq = object["seq"] as? Int, seq > 0 {
                if let last = lastHookSeqByEpoch[epoch], seq <= last {
                    return
                }
                lastHookSeqByEpoch[epoch] = seq
            }
        }
        let payload: [String: Any]?
        if let b64 = object["payload_b64"] as? String {
            payload = Data(base64Encoded: b64)
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        } else {
            payload = object["payload"] as? [String: Any]
        }
        if let payloadSessionID = (payload?["session_id"] as? String) ?? (payload?["sessionId"] as? String),
           payloadSessionID != record.sessionID {
            return
        }
        switch event {
        case "prompt-submit":
            // A user submission opens a hook-turn token. It does NOT begin
            // Working (local commands submit too); the transcript opener
            // that follows binds the token to its turn identity.
            hookSawPromptSubmit = true
            hookTurnCounter += 1
            let token = hookTurnCounter
            openHookTurnTokens.append(token)
            // A prior token still awaiting its transcript opener (queued
            // submission whose turn hasn't started yet) stays pending
            // alongside the new one; the NEXT opener binds the newest.
            pendingHookTurnTokens.append(token)
            while openHookTurnTokens.count > 32 {
                openHookTurnTokens.removeFirst()
            }
        case "permission-request":
            let toolUseID = (payload?["tool_use_id"] as? String) ?? (payload?["toolUseId"] as? String)
            if let toolUseID, preparedPermissionToolUseIDs.contains(toolUseID) == false {
                preparedPermissionToolUseIDs.append(toolUseID)
                while preparedPermissionToolUseIDs.count > 8 {
                    preparedPermissionToolUseIDs.removeFirst()
                }
            }
        case "notification-permission":
            // Turn correlation: the prompt belongs to the OPEN hook turn.
            // Once the machine has tokens, a notification without an open
            // token — or bound to a turn that is no longer active — is a
            // previous turn's late prompt and may not block this one.
            // `owningTurnID` is captured HERE, at the source of truth (the
            // hook token's binding) — never re-read as "whatever turn is
            // current" at the point the blocker actually opens below.
            var owningTurnID: String?
            if hookSawPromptSubmit {
                // Claude Code processes queued prompts SERIALLY: at most
                // one token is ever the CURRENTLY EXECUTING turn, and it is
                // always the OLDEST still-open one (newer tokens are
                // queued, unbound, and not yet running).
                guard let token = openHookTurnTokens.first else {
                    return
                }
                if let boundTurnID = hookTurnBindings[token] {
                    guard boundTurnID == lifecycleActiveTurnID else {
                        return
                    }
                    owningTurnID = boundTurnID
                } else if let activeTurnID = lifecycleActiveTurnID {
                    // Prompt implies the open hook turn IS the active
                    // transcript turn: bind now (transcript opener lag).
                    hookTurnBindings[token] = activeTurnID
                    pendingHookTurnTokens.removeAll { $0 == token }
                    owningTurnID = activeTurnID
                }
            } else {
                // Legacy mode (bootstrap joined mid-turn, no tokens ever
                // observed): no captured source exists, so the current
                // turn is the best available identity.
                owningTurnID = lifecycleActiveTurnID
            }
            let suffix: String
            if preparedPermissionToolUseIDs.isEmpty == false {
                // Deterministic correlation: each actual prompt CONSUMES its
                // prepared request head, so sequential permissions map to
                // their own blockers and a consumed id is never reused.
                suffix = preparedPermissionToolUseIDs.removeFirst()
            } else if openLifecyclePermissionSuffixes.isEmpty == false {
                // Duplicate notification for the prompt already open: one
                // card, one blocker.
                return
            } else {
                suffix = "prompt"
            }
            openLifecyclePermissionSuffixes.insert(suffix)
            // Fenced to the CAPTURED owning turn (see above) — a permission
            // prompt whose owning turn has already ended (or been
            // superseded) must not attach to a DIFFERENT current turn.
            lifecycleStore.openBlocker(lifecycleIdentity,
                                       vendor: record.vendor,
                                       generation: lifecycleGeneration,
                                       blockerID: "permission:\(suffix)",
                                       kind: .permission,
                                       expectedTurnID: owningTurnID)
        case "notification-idle":
            // Claude is WAITING at an idle prompt: the turn this token was
            // bound to is over (never a newer turn — token fence).
            let target = closeHookTurnAndResolveTarget()
            if target.shouldEnd {
                lifecycleEndTurn(expectedTurnID: target.expectedTurnID)
            }
        case "stop":
            // Stop is a TURN-SCOPED idle edge with the same token fence.
            // stop_hook_active means a Stop hook is already driving a
            // continuation — not a terminal. If a Stop hook later prevents
            // continuation anyway, assistant activity restores Working via
            // reconciliation.
            if (payload?["stop_hook_active"] as? Bool) == true {
                break
            }
            let target = closeHookTurnAndResolveTarget()
            if target.shouldEnd {
                lifecycleEndTurn(expectedTurnID: target.expectedTurnID)
            }
        case "session-start":
            // Creates the session record so the panel aggregates exist —
            // conservatively idle until real activity arrives.
            resetHookTurnMachine()
            lifecycleEndTurn()
        case "session-end":
            lifecycleEndSession()
        default:
            break
        }
    }

    private func resetHookTurnMachine() {
        openHookTurnTokens = []
        pendingHookTurnTokens = []
        hookTurnBindings = [:]
        hookSawPromptSubmit = false
    }

    // Epoch token "pid-startTimestamp"; the wrapper allocates a monotonic
    // nanosecond-scale suffix and ordering uses that suffix.
    private static func hookEpochStart(_ epoch: String) -> Int {
        guard let range = epoch.range(of: "-", options: .backwards),
              let start = Int(epoch[range.upperBound...]) else {
            return 0
        }
        return start
    }
    private var resolverTimer: DispatchSourceTimer?
    private var tailer: JSONLFileTailer?
    private var transcriptURL: URL?
    private var maxObservedSeq = transcriptSessionStartedSequence
    // File offsets restart at zero for each transcript source. This base
    // keeps the public cursor monotonic across source switches while still
    // allowing an exact inverse mapping to the current file.
    private var transcriptSequenceBase = transcriptSessionStartedSequence
    private var didPublishStart = false
    private var didPublishEnd = false
    private var unsupportedVersions = Set<String>()
    private var isBackfillingHistory = false
    private var pendingLocalCommand: ClaudeLocalCommand?

    private struct ClaudeAskLifecycle: Equatable {
        let promptID: String
        let token: String
    }

    private var activeAskUserQuestionLifecyclesByToolCallID = [String: [ClaudeAskLifecycle]]()

    private struct LiveParserStateSnapshot {
        let unsupportedVersions: Set<String>
        let pendingLocalCommand: ClaudeLocalCommand?
        let activeAskUserQuestionLifecyclesByToolCallID: [String: [ClaudeAskLifecycle]]
        let lifecycleTurnLineageByUuid: [String: String]
        let lifecycleTurnLineageOrder: [String]
    }

    private struct HistoricalClosureSourceIdentity: Equatable {
        let canonicalPath: String
        let device: UInt64
        let inode: UInt64
        let epoch: UInt64
    }

    private final class HistoricalClosureIndexState {
        let sourceIdentity: HistoricalClosureSourceIdentity
        var indexedThroughByteOffset: Int
        var scannedThroughByteOffset: Int
        var scannedBoundary: Data
        var pendingPartialLineData: Data
        var parserState: LiveParserStateSnapshot?
        var pendingAskOpenerEventIDsByPromptID: [String: [String]]
        var pendingContextOpenerEventID: String?
        var closureByOpenerEventID: [String: AgentEvent]
        var openerEventIDByClosureEventID: [String: String]
        var contextConsumerSequenceByOpenerEventID: [String: Int]
        var isPoisonedByOversizedPartialLine: Bool
        var isPoisonedByMalformedRecord: Bool

        init(sourceIdentity: HistoricalClosureSourceIdentity,
             indexedThroughByteOffset: Int,
             scannedThroughByteOffset: Int,
             scannedBoundary: Data,
             pendingPartialLineData: Data,
             parserState: LiveParserStateSnapshot?,
             pendingAskOpenerEventIDsByPromptID: [String: [String]],
             pendingContextOpenerEventID: String?,
             closureByOpenerEventID: [String: AgentEvent],
             openerEventIDByClosureEventID: [String: String],
             contextConsumerSequenceByOpenerEventID: [String: Int],
             isPoisonedByOversizedPartialLine: Bool = false,
             isPoisonedByMalformedRecord: Bool = false) {
            self.sourceIdentity = sourceIdentity
            self.indexedThroughByteOffset = indexedThroughByteOffset
            self.scannedThroughByteOffset = scannedThroughByteOffset
            self.scannedBoundary = scannedBoundary
            self.pendingPartialLineData = pendingPartialLineData
            self.parserState = parserState
            self.pendingAskOpenerEventIDsByPromptID = pendingAskOpenerEventIDsByPromptID
            self.pendingContextOpenerEventID = pendingContextOpenerEventID
            self.closureByOpenerEventID = closureByOpenerEventID
            self.openerEventIDByClosureEventID = openerEventIDByClosureEventID
            self.contextConsumerSequenceByOpenerEventID = contextConsumerSequenceByOpenerEventID
            self.isPoisonedByOversizedPartialLine = isPoisonedByOversizedPartialLine
            self.isPoisonedByMalformedRecord = isPoisonedByMalformedRecord
        }
    }

    private var historicalClosureSourceEpoch: UInt64 = 0
    private var historicalClosureIndex: HistoricalClosureIndexState?
    private var historicalIndexEventSink: ((AgentEvent) -> Void)?
    var historicalIndexBeforeScanForTesting: (() -> Void)?
    // Deterministic injection point: fires after the step's raw read has
    // completed (page collected) and before any final validation/return.
    var afterCursorStepAfterRawReadForTesting: (() -> Void)?
    var hasActiveAskLifecyclesForTesting: Bool {
        queue.sync { activeAskUserQuestionLifecyclesByToolCallID.isEmpty == false }
    }
    var historicalIndexBeforeSourceValidationForTesting: (() -> Void)?
    private var historicalIndexScanPassCount = 0
    private var historicalIndexReadByteCount = 0
    private var historicalIndexCompleteLineCount = 0
    private var historicalReplayOpenerEventIDs = Set<String>()
    private var historicalReplayProducts = [AgentEvent]()

    // Request-local after-cursor replay collection: exists ONLY for the
    // lifetime of one afterCursorStep. While present, replay products are
    // routed here and never into the legacy shared replay state, so stale
    // entries cannot accumulate across requests.
    private struct AfterCursorReplayCollector {
        var products = [AgentEvent]()
        var positionsByEventID = [String: TranscriptEventPosition]()
        var openerEventIDs = Set<String>()
    }
    private var afterCursorReplayCollector: AfterCursorReplayCollector?
    private var isCollectingHistoricalBackfillPage = false
    private var collectedHistoricalBackfillPage = [(offset: Int, line: String)]()
    private var historicalBackfillAnchorSeq: Int?
    private var exactTranscriptPositionByPublicSequence = [Int: TranscriptEventPosition]()
    // Semantic trust over the CURRENT source epoch: EARNED, never assumed —
    // false until a successful semantic index under a validated source
    // fence, false again after any unknown/malformed/unsupported record,
    // failed closure coverage, or source epoch switch.
    private var historySemanticTrust = false
    private var publicTranscriptSequenceByEventID = [String: Int]()

    func historicalClosureIndexStatsForTesting() -> ClaudeHistoricalClosureIndexStats {
        queue.sync {
            ClaudeHistoricalClosureIndexStats(
                scanPassCount: historicalIndexScanPassCount,
                readByteCount: historicalIndexReadByteCount,
                completeLineCount: historicalIndexCompleteLineCount)
        }
    }

    private func captureLiveParserState() -> LiveParserStateSnapshot {
        LiveParserStateSnapshot(unsupportedVersions: unsupportedVersions,
                                pendingLocalCommand: pendingLocalCommand,
                                activeAskUserQuestionLifecyclesByToolCallID:
                                    activeAskUserQuestionLifecyclesByToolCallID,
                                lifecycleTurnLineageByUuid: lifecycleTurnLineageByUuid,
                                lifecycleTurnLineageOrder: lifecycleTurnLineageOrder)
    }

    private func resetParserStateForHistoricalReplay() {
        unsupportedVersions = []
        pendingLocalCommand = nil
        activeAskUserQuestionLifecyclesByToolCallID = [:]
        lifecycleTurnLineageByUuid = [:]
        lifecycleTurnLineageOrder = []
    }

    private func restoreLiveParserState(_ snapshot: LiveParserStateSnapshot) {
        unsupportedVersions = snapshot.unsupportedVersions
        pendingLocalCommand = snapshot.pendingLocalCommand
        activeAskUserQuestionLifecyclesByToolCallID =
            snapshot.activeAskUserQuestionLifecyclesByToolCallID
        lifecycleTurnLineageByUuid = snapshot.lifecycleTurnLineageByUuid
        lifecycleTurnLineageOrder = snapshot.lifecycleTurnLineageOrder
    }

    private func transcriptEventPositionInCurrentSource(for seq: Int) -> TranscriptEventPosition? {
        if let exactPosition = exactTranscriptPositionByPublicSequence[seq] {
            return exactPosition
        }
        guard seq > transcriptSequenceBase else {
            return nil
        }
        return transcriptEventPosition(for: seq - transcriptSequenceBase)
    }

    private struct ClaudeLocalCommand {
        let name: String
    }

    private struct ClaudeContextMetric {
        let label: String
        let value: String
        let percentText: String
        let percentValue: Double
    }

    private struct ClaudeContextSummary {
        let model: String?
        let used: String
        let total: String
        let usedPercentText: String
        let usedPercentValue: Double
        let free: ClaudeContextMetric?
        let breakdown: [ClaudeContextMetric]
    }

    init(record: AgentSessionRegistryRecord,
         fileManager: FileManager = .default,
         hub: AgentEventHub,
         socketClient: TideyCommandSending? = nil,
         chatSubmitEchoRegistry: ChatSubmitEchoRegistry? = nil,
         historicalPartialLineByteLimit: Int = ClaudeTranscriptSession.defaultHistoricalPartialLineByteLimit) {
        self.record = record
        self.fileManager = fileManager
        self.hub = hub
        self.socketClient = socketClient
        self.chatSubmitEchoRegistry = chatSubmitEchoRegistry ?? ChatSubmitEchoRegistry()
        self.historicalPartialLineByteLimit = max(1, historicalPartialLineByteLimit)
        self.queue = DispatchQueue(label: "com.tidey.remote-bridge.claude-session.\(record.sessionID)")
    }

    func start() {
        queue.async {
            guard !self.didPublishStart else {
                return
            }
            self.didPublishStart = true
            self.publishSynthetic(kind: .sessionStarted,
                                  seq: transcriptSessionStartedSequence,
                                  eventID: "session-start:\(self.record.sessionID)",
                                  timestamp: self.record.createdAt,
                                  role: nil,
                                  text: nil,
                                  name: nil,
                                  input: nil,
                                  output: nil,
                                  toolCallID: nil,
                                  metadata: self.baseMetadata(["cwd": self.record.cwd]))
            self.startResolver()
        }
    }

    func update(record: AgentSessionRegistryRecord) {
        queue.async {
            let previousRecord = self.record
            let didMigrateWorkspace = previousRecord.workspaceID != record.workspaceID
            let didMigratePanel = previousRecord.panelID != record.panelID
            if didMigrateWorkspace || didMigratePanel {
                self.hub.migrateSession(sessionID: previousRecord.sessionID,
                                        toWorkspaceID: record.workspaceID,
                                        panelID: record.panelID)
                // Lifecycle identity moves with the session: the old
                // identity is tombstoned (no ghost aggregate) and the live
                // state carries over under the same generation.
                let previousIdentity = AgentSessionLifecycleIdentity(workspaceID: previousRecord.workspaceID,
                                                                     panelID: previousRecord.panelID ?? "",
                                                                     sessionID: previousRecord.sessionID)
                let newIdentity = AgentSessionLifecycleIdentity(workspaceID: record.workspaceID,
                                                                panelID: record.panelID ?? "",
                                                                sessionID: record.sessionID)
                // This session is the exclusive writer for its own
                // generation: fencing on it rejects the migration outright
                // if some other event already advanced the generation
                // between reading `previousRecord` and this call.
                self.lifecycleStore.migrateSession(from: previousIdentity, to: newIdentity,
                                                   expectedGeneration: self.lifecycleGeneration)
            }
            self.record = record
            // A registry update pointing at a DIFFERENT transcript is a full
            // source identity switch — even while the old file still exists.
            // Identity is the STANDARDIZED resolved path: a nil path later
            // filled in with the file we already resolved is a pure metadata
            // update, never a reset.
            if let currentURL = self.transcriptURL,
               let newPath = record.transcriptPath,
               Self.canonicalTranscriptPath(newPath) != Self.canonicalTranscriptPath(currentURL.path) {
                self.beginNewSourceEpoch()
                self.resolveTranscriptIfPossible()
                return
            }
            if self.transcriptURL == nil {
                self.resolveTranscriptIfPossible()
            }
        }
    }

    // Everything that could let the OLD source's live lifecycle leak into
    // the new one is revoked: the old tailer, parser correlation, and
    // three-state generation. Hook epoch retirement survives so a retired
    // wrapper cannot re-enter through a transcript source switch.
    // The SAME canonicalization the resolver uses: tilde expansion +
    // standardized file URL — two resolver-equivalent spellings never count
    // as different sources.
    static func canonicalTranscriptPath(_ path: String) -> String {
        URL(fileURLWithPath: NSString(string: path).expandingTildeInPath).standardizedFileURL.path
    }

    private func beginNewSourceEpoch() {
        tailer?.stop()
        tailer = nil
        transcriptSequenceBase = max(maxObservedSeq,
                                     hub.sequenceHighWater(sessionID: record.sessionID))
        exactTranscriptPositionByPublicSequence = [:]
        publicTranscriptSequenceByEventID = [:]
        // The replacement source has proven nothing yet.
        historySemanticTrust = false
        afterCursorReplayCollector = nil
        historicalClosureSourceEpoch &+= 1
        historicalClosureIndex = nil
        historicalIndexEventSink = nil
        historicalReplayOpenerEventIDs = []
        historicalReplayProducts = []
        isCollectingHistoricalBackfillPage = false
        collectedHistoricalBackfillPage = []
        historicalBackfillAnchorSeq = nil
        activeAskUserQuestionLifecyclesByToolCallID = [:]
        pendingLocalCommand = nil
        unsupportedVersions = []
        // Source switch = new lifecycle epoch: the fresh generation makes
        // every late event from the old tail stale by construction, and the
        // replay of the new source rebuilds it. The new generation is
        // CLAIMED IMMEDIATELY (reconciled idle snapshot) — the old source's
        // needs_input/working must not stay visible until some later
        // mutation happens to arrive.
        // Hook-journal identity state (current/retired epochs, seen event
        // ids, per-epoch sequences) SURVIVES the transcript source switch:
        // clearing it would let a retired wrapper's late events re-enter
        // under the fresh generation. Only the turn-correlation machine
        // resets (the old transcript's turn ids are gone).
        lifecycleGeneration = AgentSessionLifecycle.nextGeneration()
        lifecycleActiveTurnID = nil
        resetHookTurnMachine()
        preparedPermissionToolUseIDs = []
        openLifecyclePermissionSuffixes = []
        // The new source's parentUuid chain starts fresh — a reused uuid
        // from the OLD transcript (delete-and-recreate at the same path)
        // must never resolve through the previous source's lineage map.
        lifecycleTurnLineageByUuid = [:]
        lifecycleTurnLineageOrder = []
        // Explicit claim: guarantees a live publish EVEN for a brand-new
        // identity's very first source epoch (endTurn alone would look
        // "unchanged" for a fresh idle record and publish nothing).
        lifecycleStore.claimGeneration(lifecycleIdentity,
                                       vendor: record.vendor,
                                       generation: lifecycleGeneration)
        openLifecycleQuestionTokensByToolCallID = [:]
        promptNotificationDeduper.remove(sessionID: record.sessionID)
        hub.beginNewSourceEpoch(sessionID: record.sessionID)
        transcriptURL = nil
    }

    // Typed after-cursor plan: classifies the cursor against RAW evidence
    // only (contiguous coverage + the exact seq→position map). Lease/
    // retention evidence is the flow's cross-check — the session never
    // guesses it. Successful modes always anchor at the FIXED validated
    // EOF ceiling, never the floor: if live eviction happened above the
    // floor, a floor-anchored walk could never recover that range.
    func afterCursorPlan(afterSeq: Int,
                         expectedEpoch: AgentHistoryEpoch) -> AgentAfterCursorPlan {
        queue.sync {
            // Every failed plan reports the TRUE current Hub epoch at the
            // moment of failure — never a captured or caller-supplied token.
            func unavailableNow() -> AgentAfterCursorPlan {
                AgentAfterCursorPlan(epoch: hub.currentHistoryEpoch(sessionID: record.sessionID),
                                     mode: .unavailable)
            }
            let capturedEpoch = hub.currentHistoryEpoch(sessionID: record.sessionID)
            guard didPublishStart, didPublishEnd == false,
                  expectedEpoch == capturedEpoch else {
                return unavailableNow()
            }
            if tailer == nil {
                resolveTranscriptIfPossible()
            }
            guard let tailer else {
                return unavailableNow()
            }
            do {
                try tailer.validateCurrentSource()
                // Semantic validation: the incremental closure/index scan
                // must fully understand the source. Raw frontier coverage is
                // NEVER a substitute for it.
                let indexIsReady = try ensureHistoricalClosureIndex()
                try tailer.validateCurrentSource()
                guard indexIsReady else {
                    historySemanticTrust = false
                    return unavailableNow()
                }
            } catch JSONLFileTailerError.sourceInvalidated {
                beginNewSourceEpoch()
                startResolver()
                return unavailableNow()
            } catch {
                historySemanticTrust = false
                return unavailableNow()
            }
            historySemanticTrust = true
            guard let coverage = queueOwnedContiguousRawCoverage(of: tailer) else {
                return unavailableNow()
            }
            // Final epoch fence: the semantic scan and coverage read take
            // time — a Hub epoch that moved underneath them invalidates
            // everything derived above.
            let currentEpoch = hub.currentHistoryEpoch(sessionID: record.sessionID)
            guard currentEpoch == capturedEpoch else {
                return unavailableNow()
            }
            let ceilingAnchor = AgentHistoryAnchor(
                epoch: currentEpoch,
                position: TranscriptEventPosition(lineOffset: coverage.replayUpperBoundOffset,
                                                  ordinal: 0))
            let rawCovered: Bool
            if coverage.minimumRawOffset == 0 {
                rawCovered = true
            } else if let position = exactTranscriptPositionByPublicSequence[afterSeq],
                      position.lineOffset >= coverage.minimumRawOffset,
                      position.lineOffset < coverage.replayUpperBoundOffset {
                rawCovered = true
            } else if afterSeq >= maxObservedSeq {
                rawCovered = true
            } else {
                rawCovered = false
            }
            return AgentAfterCursorPlan(epoch: currentEpoch,
                                        mode: rawCovered
                                            ? .rawCovered(replayFrom: ceilingAnchor)
                                            : .scan(from: ceilingAnchor))
        }
    }

    func validateHistoryEpoch(_ epoch: AgentHistoryEpoch) -> Bool {
        queue.sync {
            guard didPublishStart, didPublishEnd == false, historySemanticTrust else {
                return false
            }
            return epoch == hub.currentHistoryEpoch(sessionID: record.sessionID)
        }
    }

    // One request-owned raw walk step: reads exactly one raw page below the
    // anchor, replays it through the parser, and RETURNS the products —
    // the shared historical window is never populated from here. The
    // interval is sliced by raw (lineOffset, ordinal) order; an unknown or
    // synthetic cursor never terminates the walk early on a virtual
    // sequence boundary — it walks conservatively to BOF.
    func afterCursorStep(from anchor: AgentHistoryAnchor,
                         afterSeq: Int,
                         limit: Int) -> AgentAfterCursorStep {
        queue.sync {
            var currentEpoch = hub.currentHistoryEpoch(sessionID: record.sessionID)
            func out(_ outcome: AgentAfterCursorStep.Outcome,
                     _ events: [AgentEvent] = []) -> AgentAfterCursorStep {
                AgentAfterCursorStep(epoch: currentEpoch, outcome: outcome, events: events)
            }
            // Trust is EARNED by this step's own semantic index below —
            // an initial false must not block a legitimate direct seam.
            guard didPublishStart, didPublishEnd == false, limit > 0 else {
                return out(.unavailable)
            }
            guard anchor.epoch == currentEpoch else {
                return out(.sourceChanged)
            }
            let anchorPosition = anchor.position
            guard anchorPosition.lineOffset > 0 || anchorPosition.ordinal > 0 else {
                return out(.complete)
            }
            if tailer == nil {
                resolveTranscriptIfPossible()
            }
            guard let tailer else {
                return out(.unavailable)
            }
            do {
                try tailer.validateCurrentSource()
                let indexIsReady = try ensureHistoricalClosureIndex()
                try tailer.validateCurrentSource()
                guard indexIsReady else {
                    historySemanticTrust = false
                    return out(.unavailable)
                }
            } catch JSONLFileTailerError.sourceInvalidated {
                beginNewSourceEpoch()
                startResolver()
                currentEpoch = hub.currentHistoryEpoch(sessionID: record.sessionID)
                return out(.sourceChanged)
            } catch {
                historySemanticTrust = false
                return out(.unavailable)
            }
            historySemanticTrust = true

            let liveParserState = captureLiveParserState()
            resetParserStateForHistoricalReplay()
            afterCursorReplayCollector = AfterCursorReplayCollector()
            isBackfillingHistory = true
            // Cleanup ordering is explicit: when the source was invalidated
            // mid-replay, beginNewSourceEpoch already installed the NEW
            // epoch's fresh parser state — restoring source A's live
            // snapshot afterwards would pour a retired source's pending
            // command/Ask lifecycles/lineage into the new epoch.
            var sourceWasInvalidated = false
            defer {
                isCollectingHistoricalBackfillPage = false
                collectedHistoricalBackfillPage = []
                afterCursorReplayCollector = nil
                isBackfillingHistory = false
                if sourceWasInvalidated == false {
                    restoreLiveParserState(liveParserState)
                }
            }

            isCollectingHistoricalBackfillPage = true
            collectedHistoricalBackfillPage = []
            let readResult: JSONLBackfillResult
            do {
                readResult = try tailer.backfill(beforeOffset: anchorPosition.lineOffset,
                                                 limit: limit,
                                                 includeAnchorLine: anchorPosition.ordinal > 0)
            } catch JSONLFileTailerError.sourceInvalidated {
                sourceWasInvalidated = true
                beginNewSourceEpoch()
                startResolver()
                currentEpoch = hub.currentHistoryEpoch(sessionID: record.sessionID)
                return out(.sourceChanged)
            } catch {
                historySemanticTrust = false
                return out(.unavailable)
            }
            isCollectingHistoricalBackfillPage = false
            let rawPage = collectedHistoricalBackfillPage
            collectedHistoricalBackfillPage = []
            afterCursorStepAfterRawReadForTesting?()
            guard let frontier = readResult.rawFrontier else {
                return out(.unavailable)
            }
            // Invalid raw bytes poison the whole step: nothing from this
            // page may be served, and the walk must not advance past bytes
            // it cannot understand.
            guard frontier.containsInvalidRecord == false else {
                return out(.unavailable)
            }
            for entry in rawPage {
                consume(line: entry.line, lineOffset: entry.offset)
            }
            do {
                try tailer.validateCurrentSource()
            } catch JSONLFileTailerError.sourceInvalidated {
                sourceWasInvalidated = true
                beginNewSourceEpoch()
                startResolver()
                currentEpoch = hub.currentHistoryEpoch(sessionID: record.sessionID)
                return out(.sourceChanged)
            } catch {
                historySemanticTrust = false
                return out(.unavailable)
            }
            guard historySemanticTrust else {
                // A malformed record surfaced during the replay itself.
                return out(.unavailable)
            }
            // Final Hub epoch fence: nothing derived from this read may be
            // served if the epoch moved after the raw read — the whole page
            // is discarded, not trimmed.
            let epochAfterRead = hub.currentHistoryEpoch(sessionID: record.sessionID)
            guard epochAfterRead == currentEpoch else {
                currentEpoch = epochAfterRead
                return out(.sourceChanged)
            }

            let pageFloorOffset = frontier.minimumRawOffset ?? anchorPosition.lineOffset
            let pageFloor = TranscriptEventPosition(lineOffset: pageFloorOffset, ordinal: 0)
            let collector = afterCursorReplayCollector ?? AfterCursorReplayCollector()
            // Interval slice by raw position: [pageFloor, anchor).
            var sliced = collector.products.filter { event in
                guard let position = collector.positionsByEventID[event.eventID] else {
                    return false
                }
                return position >= pageFloor && position < anchorPosition
            }
            if let index = historicalClosureIndex {
                // Documented exception: an Ask/context opener's EXACT
                // closure may ride from outside the interval (eventID
                // deduplicated); an opener consumed by a silent context
                // consumer is suppressed instead of resurfacing stale.
                var closures = [AgentEvent]()
                sliced = sliced.filter { event in
                    guard collector.openerEventIDs.contains(event.eventID) else {
                        return true
                    }
                    if let closure = index.closureByOpenerEventID[event.eventID] {
                        closures.append(closure)
                        return true
                    }
                    return index.contextConsumerSequenceByOpenerEventID[event.eventID] == nil
                }
                sliced.append(contentsOf: closures)
            }
            var seenEventIDs = Set<String>()
            let events = sliced
                .filter { $0.seq > afterSeq }
                .filter { seenEventIDs.insert($0.eventID).inserted }
                .sorted { $0.seq < $1.seq }

            if frontier.reachedSourceStart {
                return out(.complete, events)
            }
            // Only an EXACT raw cursor position can prove the walk crossed
            // the cursor, and only when it lies INSIDE this step's read
            // interval [pageFloor, anchor) — a cursor above the anchor was
            // never part of this walk. Synthetic seqs have none and walk
            // conservatively to BOF.
            if let cursorPosition = exactTranscriptPositionByPublicSequence[afterSeq],
               cursorPosition >= pageFloor,
               cursorPosition < anchorPosition {
                return out(.complete, events)
            }
            let nextPosition = TranscriptEventPosition(lineOffset: pageFloorOffset, ordinal: 0)
            guard nextPosition < anchorPosition else {
                // A stalled walk is incomplete coverage.
                return out(.unavailable)
            }
            return out(.advanced(AgentHistoryAnchor(epoch: currentEpoch, position: nextPosition)),
                       events)
        }
    }

    // The tailer runs on this session's queue; reading its queue-owned
    // snapshot from here is already serialized.
    private func queueOwnedContiguousRawCoverage(of tailer: JSONLFileTailer) -> JSONLContiguousRawCoverage? {
        tailer.contiguousRawCoverage
    }

    func backfill(beforeSeq: Int, limit: Int) -> Bool {
        queue.sync {
            if tailer == nil {
                resolveTranscriptIfPossible()
            }
            guard let tailer else {
                return false
            }
            guard let beforePosition = transcriptEventPositionInCurrentSource(for: beforeSeq),
                  beforePosition.lineOffset > 0 || beforePosition.ordinal > 0 else {
                return false
            }
            do {
                try tailer.validateCurrentSource()
            } catch JSONLFileTailerError.sourceInvalidated {
                beginNewSourceEpoch()
                startResolver()
                return false
            } catch {
                failHistoricalClosureCoverage(beforeSeq: beforeSeq)
                return false
            }
            // Closure knowledge is three-state: closed, genuinely open, or
            // unknown because the source could not be indexed. Unknown must
            // fail closed; replaying the page would otherwise revive an
            // opener whose terminal may simply be outside this page.
            let closureIndexIsReady: Bool
            do {
                closureIndexIsReady = try ensureHistoricalClosureIndex()
            } catch JSONLFileTailerError.sourceInvalidated {
                beginNewSourceEpoch()
                startResolver()
                return false
            } catch {
                failHistoricalClosureCoverage(beforeSeq: beforeSeq)
                return false
            }
            do {
                try tailer.validateCurrentSource()
            } catch JSONLFileTailerError.sourceInvalidated {
                beginNewSourceEpoch()
                startResolver()
                return false
            } catch {
                failHistoricalClosureCoverage(beforeSeq: beforeSeq)
                return false
            }
            guard closureIndexIsReady else {
                failHistoricalClosureCoverage(beforeSeq: beforeSeq)
                return false
            }
            hub.setHistoricalClosureCoverage(sessionID: record.sessionID, isComplete: true)
            let liveParserState = captureLiveParserState()
            resetParserStateForHistoricalReplay()
            historicalReplayOpenerEventIDs = []
            historicalReplayProducts = []
            historicalBackfillAnchorSeq = beforeSeq
            isBackfillingHistory = true
            var sourceWasInvalidated = false
            defer {
                isCollectingHistoricalBackfillPage = false
                collectedHistoricalBackfillPage = []
                historicalBackfillAnchorSeq = nil
                historicalReplayProducts = []
                isBackfillingHistory = false
                restoreLiveParserState(liveParserState)
                if sourceWasInvalidated {
                    beginNewSourceEpoch()
                    startResolver()
                }
            }
            var pageAnchorOffset = beforePosition.lineOffset
            var includeAnchorLine = beforePosition.ordinal > 0
            var loadedAnyRawPage = false
            while pageAnchorOffset > 0 || includeAnchorLine {
                isCollectingHistoricalBackfillPage = true
                collectedHistoricalBackfillPage = []
                let didLoad: Bool
                do {
                    didLoad = try tailer.backfill(
                        beforeOffset: pageAnchorOffset,
                        limit: limit,
                        includeAnchorLine: includeAnchorLine).didRead
                } catch JSONLFileTailerError.sourceInvalidated {
                    sourceWasInvalidated = true
                    return false
                } catch {
                    return false
                }
                isCollectingHistoricalBackfillPage = false
                let rawPage = collectedHistoricalBackfillPage
                collectedHistoricalBackfillPage = []
                guard didLoad, rawPage.isEmpty == false else {
                    hub.replaceHistoricalEvents(sessionID: record.sessionID,
                                                events: [],
                                                anchorSeq: beforeSeq)
                    return loadedAnyRawPage
                }
                loadedAnyRawPage = true

                resetParserStateForHistoricalReplay()
                historicalReplayOpenerEventIDs = []
                historicalReplayProducts = []
                for entry in rawPage {
                    consume(line: entry.line, lineOffset: entry.offset)
                }
                do {
                    try tailer.validateCurrentSource()
                } catch JSONLFileTailerError.sourceInvalidated {
                    sourceWasInvalidated = true
                    return false
                } catch {
                    return false
                }
                guard let index = historicalClosureIndex else {
                    return false
                }
                for openerEventID in historicalReplayOpenerEventIDs {
                    guard let closure = index.closureByOpenerEventID[openerEventID],
                          closure.seq < beforeSeq else {
                        continue
                    }
                    historicalReplayProducts.append(closure)
                }
                var seenEventIDs = Set<String>()
                let products = historicalReplayProducts.filter {
                    seenEventIDs.insert($0.eventID).inserted
                }
                let productEventIDs = Set(products.map(\.eventID))
                let hasVisibleProduct = products.contains { event in
                    guard event.seq < beforeSeq else {
                        return false
                    }
                    let isOpener = event.type == .interactivePrompt
                        || event.metadata?["tidey_generated"] == "claude_context_command"
                    guard isOpener else {
                        return true
                    }
                    if let closure = index.closureByOpenerEventID[event.eventID] {
                        return closure.seq < beforeSeq
                            && productEventIDs.contains(closure.eventID)
                    }
                    return index.contextConsumerSequenceByOpenerEventID[event.eventID] == nil
                }
                if hasVisibleProduct {
                    hub.replaceHistoricalEvents(sessionID: record.sessionID,
                                                events: products,
                                                anchorSeq: beforeSeq)
                    historicalReplayOpenerEventIDs = []
                    return true
                }

                guard let pageMinOffset = rawPage.map(\.offset).min(),
                      pageMinOffset > 0,
                      pageMinOffset < pageAnchorOffset || includeAnchorLine else {
                    hub.replaceHistoricalEvents(sessionID: record.sessionID,
                                                events: [],
                                                anchorSeq: beforeSeq)
                    return loadedAnyRawPage
                }
                pageAnchorOffset = pageMinOffset
                includeAnchorLine = false
            }
            hub.replaceHistoricalEvents(sessionID: record.sessionID,
                                        events: [],
                                        anchorSeq: beforeSeq)
            return loadedAnyRawPage
        }
    }

    private func failHistoricalClosureCoverage(beforeSeq: Int) {
        historySemanticTrust = false
        hub.setHistoricalClosureCoverage(sessionID: record.sessionID, isComplete: false)
        hub.replaceHistoricalEvents(sessionID: record.sessionID,
                                    events: [],
                                    anchorSeq: beforeSeq)
    }

    private func ensureHistoricalClosureIndex() throws -> Bool {
        historicalIndexBeforeScanForTesting?()
        guard let transcriptURL,
              let handle = try? FileHandle(forReadingFrom: transcriptURL) else {
            return false
        }
        defer { try? handle.close() }

        var fileStatus = stat()
        guard fstat(handle.fileDescriptor, &fileStatus) == 0 else {
            return false
        }
        let sourceIdentity = HistoricalClosureSourceIdentity(
            canonicalPath: Self.canonicalTranscriptPath(transcriptURL.path),
            device: UInt64(fileStatus.st_dev),
            inode: UInt64(fileStatus.st_ino),
            epoch: historicalClosureSourceEpoch)
        let sourceSize = Int(fileStatus.st_size)

        if let existingIndex = historicalClosureIndex {
            guard existingIndex.sourceIdentity == sourceIdentity,
                  sourceSize >= existingIndex.scannedThroughByteOffset,
                  let currentBoundary = JSONLFileTailer.readBoundary(
                    fileDescriptor: handle.fileDescriptor,
                    throughOffset: existingIndex.scannedThroughByteOffset),
                  currentBoundary == existingIndex.scannedBoundary else {
                throw JSONLFileTailerError.sourceInvalidated
            }
            guard existingIndex.isPoisonedByOversizedPartialLine == false,
                  existingIndex.isPoisonedByMalformedRecord == false else {
                return false
            }
        } else {
            historicalClosureIndex = HistoricalClosureIndexState(
                sourceIdentity: sourceIdentity,
                indexedThroughByteOffset: 0,
                scannedThroughByteOffset: 0,
                scannedBoundary: Data(),
                pendingPartialLineData: Data(),
                parserState: nil,
                pendingAskOpenerEventIDsByPromptID: [:],
                pendingContextOpenerEventID: nil,
                closureByOpenerEventID: [:],
                openerEventIDByClosureEventID: [:],
                contextConsumerSequenceByOpenerEventID: [:])
        }
        guard let startingIndex = historicalClosureIndex else {
            return false
        }

        let liveParserState = captureLiveParserState()
        if let parserState = startingIndex.parserState {
            restoreLiveParserState(parserState)
        } else {
            resetParserStateForHistoricalReplay()
        }
        isBackfillingHistory = true
        historicalIndexEventSink = { [weak self] event in
            self?.recordHistoricalClosureIndexEvent(event)
        }
        var completed = false
        defer {
            historicalIndexEventSink = nil
            isBackfillingHistory = false
            if completed == false {
                historicalClosureIndex = nil
            }
            restoreLiveParserState(liveParserState)
        }

        do {
            try handle.seek(toOffset: UInt64(startingIndex.scannedThroughByteOffset))
            // Move, rather than copy, a potentially large unterminated
            // record out of the state object. Appending many small suffixes
            // must not trigger Data COW of the entire retained prefix on
            // every history request.
            var pendingData = Data()
            swap(&pendingData, &startingIndex.pendingPartialLineData)
            var pendingDataOffset = startingIndex.indexedThroughByteOffset
            var searchedThroughIndex = pendingData.endIndex
            var scannedThroughByteOffset = startingIndex.scannedThroughByteOffset
            var scannedBoundary = startingIndex.scannedBoundary
            // Scan a fixed EOF snapshot. A continuously appending Claude
            // process must not make this synchronous history request chase
            // a moving end forever; the next ensure call consumes the suffix.
            var remainingByteCount = max(0, sourceSize - startingIndex.scannedThroughByteOffset)
            var countedScanPass = false
            scanLoop: while remainingByteCount > 0,
                  let chunk = try handle.read(upToCount: min(64 * 1024, remainingByteCount)),
                  chunk.isEmpty == false {
                if countedScanPass == false {
                    historicalIndexScanPassCount += 1
                    countedScanPass = true
                }
                pendingData.append(chunk)
                remainingByteCount -= chunk.count
                scannedThroughByteOffset += chunk.count
                historicalIndexReadByteCount += chunk.count
                if chunk.count >= JSONLFileTailer.sourceValidationBoundaryByteCount {
                    scannedBoundary = Data(chunk.suffix(JSONLFileTailer.sourceValidationBoundaryByteCount))
                } else {
                    scannedBoundary.append(chunk)
                    if scannedBoundary.count > JSONLFileTailer.sourceValidationBoundaryByteCount {
                        scannedBoundary.removeFirst(
                            scannedBoundary.count - JSONLFileTailer.sourceValidationBoundaryByteCount)
                    }
                }
                var lineStartIndex = pendingData.startIndex
                var newlineSearchIndex = min(searchedThroughIndex, pendingData.endIndex)
                var encounteredMalformedRecord = false
                while newlineSearchIndex < pendingData.endIndex,
                      let newlineIndex = pendingData[newlineSearchIndex...].firstIndex(of: 0x0a) {
                    historicalIndexCompleteLineCount += 1
                    let lineOffset = pendingDataOffset
                        + pendingData.distance(from: pendingData.startIndex, to: lineStartIndex)
                    let lineData = pendingData[lineStartIndex..<newlineIndex]
                    if lineData.isEmpty == false {
                        guard let line = String(data: Data(lineData), encoding: .utf8),
                              let jsonData = line.data(using: .utf8),
                              let object = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
                            encounteredMalformedRecord = true
                            break
                        }
                        if unsupportedClaudeTranscriptVersion(in: object) != nil {
                            // A valid future-major record may carry a closure
                            // terminal whose shape this parser cannot know.
                            // Treating it as eventless would make coverage
                            // appear complete and revive stale openers.
                            encounteredMalformedRecord = true
                            break
                        }
                        consume(line: line, lineOffset: lineOffset)
                        if pendingLocalCommand?.name != "/context",
                           let index = historicalClosureIndex,
                           let openerEventID = index.pendingContextOpenerEventID {
                            index.contextConsumerSequenceByOpenerEventID[openerEventID]
                                = transcriptSequenceBase
                                + transcriptEventSequence(lineOffset: lineOffset, ordinal: 0)
                            index.pendingContextOpenerEventID = nil
                        }
                    }
                    lineStartIndex = pendingData.index(after: newlineIndex)
                    newlineSearchIndex = lineStartIndex
                }
                if encounteredMalformedRecord {
                    startingIndex.isPoisonedByMalformedRecord = true
                    pendingData = Data()
                    break scanLoop
                }
                if lineStartIndex > pendingData.startIndex {
                    let consumedByteCount = pendingData.distance(from: pendingData.startIndex,
                                                                 to: lineStartIndex)
                    pendingData.removeSubrange(pendingData.startIndex..<lineStartIndex)
                    pendingDataOffset += consumedByteCount
                }
                // Every remaining byte was searched once and contains no
                // newline. The next chunk resumes at this frontier instead
                // of rescanning an arbitrarily long partial JSON record.
                searchedThroughIndex = pendingData.endIndex
                if pendingData.count > historicalPartialLineByteLimit {
                    // A source with an unbounded record cannot provide
                    // complete closure evidence. Keep only the validated
                    // source frontier and fail all history requests closed;
                    // retaining or rereading this suffix would turn a
                    // corrupt transcript into unbounded memory/CPU growth.
                    startingIndex.isPoisonedByOversizedPartialLine = true
                    pendingData = Data()
                    break
                }
            }

            historicalIndexBeforeSourceValidationForTesting?()
            guard let currentIdentity = historicalClosureSourceIdentity(at: transcriptURL),
                  currentIdentity == sourceIdentity,
                  let currentBoundary = JSONLFileTailer.readBoundary(
                    fileDescriptor: handle.fileDescriptor,
                    throughOffset: scannedThroughByteOffset),
                  currentBoundary == scannedBoundary else {
                throw JSONLFileTailerError.sourceInvalidated
            }
            historicalClosureIndex?.indexedThroughByteOffset =
                startingIndex.isPoisonedByOversizedPartialLine
                    || startingIndex.isPoisonedByMalformedRecord
                    ? scannedThroughByteOffset
                    : pendingDataOffset
            historicalClosureIndex?.scannedThroughByteOffset = scannedThroughByteOffset
            historicalClosureIndex?.scannedBoundary = scannedBoundary
            historicalClosureIndex?.pendingPartialLineData = pendingData
            historicalClosureIndex?.parserState = captureLiveParserState()
            completed = true
            synchronizeHistoricalOpenerClosureSequences()
            return startingIndex.isPoisonedByOversizedPartialLine == false
                && startingIndex.isPoisonedByMalformedRecord == false
        } catch JSONLFileTailerError.sourceInvalidated {
            throw JSONLFileTailerError.sourceInvalidated
        } catch {
            return false
        }
    }

    private func historicalClosureSourceIdentity(at url: URL) -> HistoricalClosureSourceIdentity? {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return nil
        }
        defer { try? handle.close() }
        var fileStatus = stat()
        guard fstat(handle.fileDescriptor, &fileStatus) == 0 else {
            return nil
        }
        return HistoricalClosureSourceIdentity(
            canonicalPath: Self.canonicalTranscriptPath(url.path),
            device: UInt64(fileStatus.st_dev),
            inode: UInt64(fileStatus.st_ino),
            epoch: historicalClosureSourceEpoch)
    }

    private func synchronizeHistoricalOpenerClosureSequences() {
        guard let index = historicalClosureIndex else {
            return
        }
        var resolutions = index.contextConsumerSequenceByOpenerEventID.mapValues {
            HistoricalOpenerResolution.silentConsumer(sequence: $0)
        }
        for (openerEventID, closure) in index.closureByOpenerEventID {
            resolutions[openerEventID] = .visibleTerminal(eventID: closure.eventID,
                                                          sequence: closure.seq)
        }
        hub.replaceHistoricalOpenerResolutions(sessionID: record.sessionID,
                                               resolutions: resolutions)
    }

    private func recordHistoricalClosureIndexEvent(_ event: AgentEvent) {
        guard let index = historicalClosureIndex else {
            return
        }
        if event.type == .interactivePrompt,
           let promptID = event.metadata?["prompt_id"] {
            index.pendingAskOpenerEventIDsByPromptID[promptID, default: []].append(event.eventID)
        } else if event.type == .interactivePromptResolved,
                  let promptID = event.metadata?["prompt_id"] {
            var openerEventIDs = index.pendingAskOpenerEventIDsByPromptID[promptID] ?? []
            guard openerEventIDs.isEmpty == false else {
                return
            }
            let openerIndex: Int
            if let lifecycleToken = event.metadata?["lifecycle_token"] {
                guard let exactIndex = openerEventIDs.firstIndex(of: lifecycleToken) else {
                    // A capability terminal revisited by an incremental scan
                    // may already have been reconciled live. Never let its
                    // stale token fall through to a newer same-ID opener.
                    return
                }
                openerIndex = exactIndex
            } else {
                openerIndex = openerEventIDs.startIndex
            }
            let openerEventID = openerEventIDs.remove(at: openerIndex)
            if openerEventIDs.isEmpty {
                index.pendingAskOpenerEventIDsByPromptID.removeValue(forKey: promptID)
            } else {
                index.pendingAskOpenerEventIDsByPromptID[promptID] = openerEventIDs
            }
            index.closureByOpenerEventID[openerEventID] = event
            index.openerEventIDByClosureEventID[event.eventID] = openerEventID
        } else if event.metadata?["tidey_generated"] == "claude_context_command" {
            if let openerEventID = index.pendingContextOpenerEventID {
                index.contextConsumerSequenceByOpenerEventID[openerEventID] = event.seq
            }
            index.pendingContextOpenerEventID = event.eventID
        } else if event.metadata?["tidey_generated"] == "claude_context",
                  let openerEventID = index.pendingContextOpenerEventID {
            index.closureByOpenerEventID[openerEventID] = event
            index.openerEventIDByClosureEventID[event.eventID] = openerEventID
            index.pendingContextOpenerEventID = nil
        }
    }

    func stop() {
        queue.sync {
            resolverTimer?.cancel()
            resolverTimer = nil
            afterCursorReplayCollector = nil
            tailer?.stop()
            tailer = nil
            hookTailer?.stop()
            hookTailer = nil
            if !didPublishEnd {
                didPublishEnd = true
                lifecycleEndSession()
                // The session is DEFINITELY gone (registry/process removal
                // — the only production caller of `stop()`), not merely a
                // transient source-epoch switch: retire the identity so
                // its panel/workspace aggregate excludes it going forward
                // and the panel can fall back to plain-terminal legacy
                // activity, rather than an idle "ghost" lingering forever.
                lifecycleStore.retireSession(lifecycleIdentity, generation: lifecycleGeneration)
                let seq = nextSyntheticSequence()
                publishSynthetic(kind: .sessionEnded,
                                 seq: seq,
                                 eventID: "session-end:\(record.sessionID)",
                                 timestamp: ISO8601DateFormatter().string(from: Date()),
                                 role: nil,
                                 text: nil,
                                 name: nil,
                                 input: nil,
                                 output: nil,
                                 toolCallID: nil,
                                 metadata: baseMetadata(nil))
            }
        }
    }

    private func startResolver() {
        attemptSourceResolutions()
        if tailer != nil && hookTailer != nil {
            return
        }
        guard resolverTimer == nil else {
            return
        }

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .seconds(1), repeating: .seconds(1))
        timer.setEventHandler { [weak self] in
            self?.attemptSourceResolutions()
        }
        timer.resume()
        resolverTimer = timer
    }

    private func attemptSourceResolutions() {
        resolveTranscriptIfPossible()
        resolveHookJournalIfPossible()
        if tailer != nil && hookTailer != nil {
            resolverTimer?.cancel()
            resolverTimer = nil
        }
    }

    private func resolveTranscriptIfPossible() {
        guard tailer == nil else {
            return
        }
        guard let transcriptURL = resolveTranscriptURL() else {
            return
        }

        let tailer = JSONLFileTailer(fileURL: transcriptURL,
                                     queue: queue,
                                     lineHandler: { [weak self] offset, line in
                                         guard let self else { return }
                                         if self.isCollectingHistoricalBackfillPage {
                                             self.collectedHistoricalBackfillPage.append((offset: offset,
                                                                                          line: line))
                                             return
                                         }
                                         self.consume(line: line, lineOffset: offset)
                                     },
                                     invalidUTF8Handler: { [weak self] offset in
                                         self?.failClosedForUnknownTranscriptRecord(lineOffset: offset)
                                     },
                                     invalidationHandler: { [weak self] in
                                         self?.handleTailerInvalidation()
                                     })
        do {
            try tailer.start()
            self.tailer = tailer
            self.transcriptURL = transcriptURL
        } catch {
            self.transcriptURL = nil
        }
    }

    private func handleTailerInvalidation() {
        // The transcript source is gone: a delete-and-recreate at the SAME
        // path is a new lifecycle source identity exactly like a registry
        // path change.
        beginNewSourceEpoch()
        if resolverTimer == nil {
            startResolver()
        }
    }

    private func resolveTranscriptURL() -> URL? {
        if let transcriptPath = record.transcriptPath,
           !transcriptPath.isEmpty {
            let url = URL(fileURLWithPath: NSString(string: transcriptPath).expandingTildeInPath)
            if fileManager.fileExists(atPath: url.path) {
                return url
            }
        }

        let home = fileManager.homeDirectoryForCurrentUser
        let projectsDirectory = home.appendingPathComponent(".claude/projects", isDirectory: true)
        let sessionFilename = "\(record.sessionID).jsonl"

        let candidateDirectory = projectsDirectory
            .appendingPathComponent(Self.sanitizedProjectDirectoryName(for: record.cwd), isDirectory: true)
        let candidateURL = candidateDirectory.appendingPathComponent(sessionFilename, isDirectory: false)
        if fileManager.fileExists(atPath: candidateURL.path) {
            return candidateURL
        }

        guard let enumerator = fileManager.enumerator(at: projectsDirectory,
                                                      includingPropertiesForKeys: [.isRegularFileKey],
                                                      options: [.skipsHiddenFiles]) else {
            return nil
        }
        for case let url as URL in enumerator {
            if url.lastPathComponent == sessionFilename {
                return url
            }
        }
        return nil
    }

    private static func sanitizedProjectDirectoryName(for cwd: String) -> String {
        cwd.replacingOccurrences(of: "/", with: "-")
    }

    private func consume(line: String, lineOffset: Int) {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            failClosedForUnknownTranscriptRecord(lineOffset: lineOffset)
            return
        }

        guard let sessionID = (object["sessionId"] as? String) ?? Optional(record.sessionID),
              sessionID == record.sessionID else {
            return
        }
        let timestamp = (object["timestamp"] as? String) ?? ISO8601DateFormatter().string(from: Date())
        if let version = unsupportedClaudeTranscriptVersion(in: object) {
            failClosedForUnknownTranscriptRecord(lineOffset: lineOffset)
            if unsupportedVersions.insert(version).inserted {
                publishFileBacked(kind: .status,
                                  lineOffset: lineOffset,
                                  ordinal: 0,
                                  eventID: "status:\(record.sessionID):unsupported-version:\(version)",
                                  timestamp: timestamp,
                                  role: nil,
                                  text: "Unsupported Claude transcript version \(version)",
                                  name: nil,
                                  input: nil,
                                  output: nil,
                                  toolCallID: nil,
                                  metadata: ["reason": "unsupported_version"])
            }
            return
        }

        recordLifecycleTurnLineage(object: object)

        guard let type = object["type"] as? String else {
            return
        }
        switch type {
        case "assistant":
            consumeAssistant(object: object, timestamp: timestamp, lineOffset: lineOffset)
        case "user":
            consumeUser(object: object, timestamp: timestamp, lineOffset: lineOffset)
        case "attachment":
            consumeAttachment(object: object, timestamp: timestamp, lineOffset: lineOffset)
        case "system":
            // The transcript's turn terminal: `turn_duration` is written
            // once per completed turn (NOT `stop_hook_summary`, which also
            // appears when a Stop hook blocks continuation). Current-version
            // schema evidence; used as replay/reconciliation, not the only
            // edge.
            if object["subtype"] as? String == "turn_duration" {
                // Fenced to the OWNING turn resolved via this system line's
                // own parentUuid lineage — never unconditional — so a
                // late-arriving turn_duration for an already-superseded
                // turn A cannot terminate a newer turn B.
                let owningTurnID = (object["uuid"] as? String).flatMap(lifecycleOwningTurnID(for:))
                lifecycleEndTurn(expectedTurnID: owningTurnID)
            }
        default:
            break
        }
    }

    private func failClosedForUnknownTranscriptRecord(lineOffset _: Int) {
        historySemanticTrust = false
        hub.setHistoricalClosureCoverage(sessionID: record.sessionID, isComplete: false)
    }

    private func consumeAssistant(object: [String: Any], timestamp: String, lineOffset: Int) {
        guard let uuid = object["uuid"] as? String,
              let message = object["message"] as? [String: Any],
              message["role"] as? String == "assistant",
              let content = message["content"] as? [[String: Any]] else {
            return
        }

        var ordinal = 0
        for (index, block) in content.enumerated() {
            guard let contentType = block["type"] as? String else {
                continue
            }
            switch contentType {
            case "text":
                let text = Self.compactString(block["text"])
                guard !text.isEmpty else {
                    continue
                }
                lifecycleBeginTurn(turnID: uuid, adoptNewTurn: false)
                publishFileBacked(kind: .assistantMessage,
                                  lineOffset: lineOffset,
                                  ordinal: ordinal,
                                  eventID: "\(uuid):text:\(index)",
                                  timestamp: timestamp,
                                  role: "assistant",
                                  text: text,
                                  name: nil,
                                  input: nil,
                                  output: nil,
                                  toolCallID: nil,
                                  metadata: nil)
                ordinal += 1

            case "thinking":
                let thinking = Self.compactString(block["thinking"])
                guard !thinking.isEmpty else {
                    continue
                }
                lifecycleBeginTurn(turnID: uuid, adoptNewTurn: false)
                publishFileBacked(kind: .thinking,
                                  lineOffset: lineOffset,
                                  ordinal: ordinal,
                                  eventID: "\(uuid):thinking:\(index)",
                                  timestamp: timestamp,
                                  role: "assistant",
                                  text: thinking,
                                  name: nil,
                                  input: nil,
                                  output: nil,
                                  toolCallID: nil,
                                  metadata: nil)
                ordinal += 1

            case "tool_use":
                let name = (block["name"] as? String) ?? "Tool"
                let toolCallID = block["id"] as? String
                let input = Self.stringifyJSON(block["input"])
                publishFileBacked(kind: .toolCall,
                                  lineOffset: lineOffset,
                                  ordinal: ordinal,
                                  eventID: toolCallID ?? "\(uuid):tool-use:\(index)",
                                  timestamp: timestamp,
                                  role: "assistant",
                                  text: nil,
                                  name: name,
                                  input: input,
                                  output: nil,
                                  toolCallID: toolCallID,
                                  metadata: nil)
                ordinal += 1
                // Assistant tool activity proves the turn is alive —
                // reconciliation for a missed/filtered user opener.
                lifecycleBeginTurn(turnID: uuid, adoptNewTurn: false)
                if name == "AskUserQuestion", let toolCallID {
                    // The blocker opens even when the CARD shape is
                    // unsupported (multiSelect); the tool_result resolves
                    // it by tool_use_id either way.
                    // Source turn: resolved via the parentUuid lineage
                    // chain from THIS assistant line's own uuid — NEVER
                    // `lifecycleActiveTurnID` read at parse time, which can
                    // already be a LATER queued turn B by the time A's own
                    // trailing assistant lines are processed (Claude Code
                    // can begin processing a queued prompt B before every
                    // one of A's lines is done appending).
                    lifecycleOpenQuestionBlocker(
                        toolCallID: toolCallID,
                        lifecycleToken: "\(uuid):ask-user-question:\(toolCallID)",
                        sourceTurnID: lifecycleOwningTurnID(for: uuid))
                }
                if name == "AskUserQuestion",
                   let prompt = Self.askUserQuestionPrompt(from: block, uuid: uuid, index: index) {
                    let lifecycleToken = "\(uuid):ask-user-question:\(prompt.promptID)"
                    if let toolCallID {
                        activeAskUserQuestionLifecyclesByToolCallID[toolCallID, default: []]
                            .append(ClaudeAskLifecycle(promptID: prompt.promptID,
                                                       token: lifecycleToken))
                    }
                    publishFileBacked(kind: .interactivePrompt,
                                      lineOffset: lineOffset,
                                      ordinal: ordinal,
                                      eventID: lifecycleToken,
                                      timestamp: timestamp,
                                      role: "assistant",
                                      text: prompt.title,
                                      name: "AskUserQuestion",
                                      input: input,
                                      output: nil,
                                      toolCallID: toolCallID,
                                      metadata: [
                                        "source": prompt.source,
                                        "prompt_id": prompt.promptID,
                                        "lifecycle_token": lifecycleToken,
                                        "submit_channel": InteractivePromptSubmitChannel.terminalInput,
                                        "multi_select": "false",
                                      ],
                                      payload: prompt.jsonValue)
                    ordinal += 1
                }

            default:
                continue
            }
        }
    }

    private static func askUserQuestionPrompt(from block: [String: Any],
                                              uuid: String,
                                              index: Int) -> InteractivePrompt? {
        guard let input = block["input"] as? [String: Any],
              let questions = input["questions"] as? [[String: Any]],
              let question = questions.first else {
            return nil
        }

        // TODO: support Claude AskUserQuestion multiSelect prompts once Remote can submit multiple choices safely.
        if (question["multiSelect"] as? Bool) == true {
            return nil
        }

        guard let optionsInput = question["options"] as? [[String: Any]],
              !optionsInput.isEmpty else {
            return nil
        }

        let selectedIndex = 0
        let options = optionsInput.enumerated().compactMap { optionIndex, option -> InteractivePromptOption? in
            guard let label = compactOptionalString(option["label"]) else {
                return nil
            }
            let inputSequence = inputSequence(selectedIndex: selectedIndex, targetIndex: optionIndex)
            return InteractivePromptOption(index: optionIndex,
                                           label: label,
                                           description: compactOptionalString(option["description"]),
                                           inputSequence: inputSequence)
        }
        guard options.count == optionsInput.count else {
            return nil
        }

        let body = compactOptionalString(question["question"]) ?? "Claude Code needs input."
        let title = compactOptionalString(question["header"]) ?? body
        let toolCallID = compactOptionalString(block["id"])
        let promptID = toolCallID ?? "claude-ask-user-question:\(uuid):\(index)"
        return InteractivePrompt(promptID: promptID,
                                 vendor: "claude",
                                 source: "claude_ask_user_question",
                                 title: title,
                                 body: body,
                                 options: options,
                                 selectedIndex: selectedIndex,
                                 submitChannel: InteractivePromptSubmitChannel.terminalInput)
    }

    private static func inputSequence(selectedIndex: Int, targetIndex: Int) -> String {
        let delta = targetIndex - selectedIndex
        if delta == 0 {
            return "\r"
        }
        let step = delta > 0 ? "\u{1b}[B" : "\u{1b}[A"
        return String(repeating: step, count: abs(delta)) + "\r"
    }

    private func consumeUser(object: [String: Any], timestamp: String, lineOffset: Int) {
        guard let uuid = object["uuid"] as? String,
              let message = object["message"] as? [String: Any],
              message["role"] as? String == "user" else {
            // A type=user record wrapping a non-user message is not a
            // genuine user message: it derives nothing.
            return
        }

        // User messages can have content as a plain string (user input)
        if let text = message["content"] as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if (object["isMeta"] as? Bool) != true,
               trimmed.hasPrefix("[Request interrupted") {
                // The user interrupted: the OWNING turn (and any blocker)
                // ends — fenced via lineage, not unconditional, so a late
                // interrupt line for an already-superseded turn cannot
                // terminate a newer one.
                lifecycleEndTurn(expectedTurnID: lifecycleOwningTurnID(for: uuid))
            }
            if consumeLocalCommandEnvelope(trimmed, uuid: uuid, timestamp: timestamp, lineOffset: lineOffset) {
                return
            }
            if shouldPublishUserMessage(trimmed) {
                // Only a GENUINE user prompt begins a turn: local commands,
                // continuation summaries, system-reminder-only strings,
                // meta records AND interrupt markers never open Working.
                if (object["isMeta"] as? Bool) != true,
                   !trimmed.hasPrefix("[Request interrupted") {
                    lifecycleBeginTurn(turnID: uuid, adoptNewTurn: true)
                }
                publishFileBacked(kind: .userMessage,
                                  lineOffset: lineOffset,
                                  ordinal: 0,
                                  eventID: "\(uuid):user-text:0",
                                  timestamp: timestamp,
                                  role: "user",
                                  text: trimmed,
                                  name: nil,
                                  input: nil,
                                  output: nil,
                                  toolCallID: nil,
                                  metadata: nil)
            }
            return
        }

        guard let content = message["content"] as? [[String: Any]] else {
            return
        }

        var ordinal = 0
        for (index, block) in content.enumerated() {
            let blockType = block["type"] as? String
            if blockType == "tool_result" {
                let output = Self.stringifyToolResultContent(block["content"])
                let toolCallID = block["tool_use_id"] as? String
                let metadata = [
                    "is_error": ((block["is_error"] as? Bool) == true) ? "true" : "false"
                ]
                publishFileBacked(kind: .toolResult,
                                  lineOffset: lineOffset,
                                  ordinal: ordinal,
                                  eventID: "\(uuid):tool-result:\(index)",
                                  timestamp: timestamp,
                                  role: "tool",
                                  text: nil,
                                  name: nil,
                                  input: nil,
                                  output: output,
                                  toolCallID: toolCallID,
                                  metadata: metadata)
                ordinal += 1
                if let toolCallID {
                    let resolvedEventID = "\(uuid):ask-user-question-resolved:\(toolCallID)"
                    let exactHistoricalOpenerEventID = historicalClosureIndex?
                        .openerEventIDByClosureEventID[resolvedEventID]
                    let historicalOpenerEventID = exactHistoricalOpenerEventID
                        ?? historicalClosureIndex?
                            .pendingAskOpenerEventIDsByPromptID[toolCallID]?.first
                    var liveLifecycles = activeAskUserQuestionLifecyclesByToolCallID[toolCallID] ?? []
                    let liveLifecycle: ClaudeAskLifecycle?
                    if let historicalOpenerEventID {
                        if let exactIndex = liveLifecycles.firstIndex(where: {
                            $0.token == historicalOpenerEventID
                        }) {
                            liveLifecycle = liveLifecycles.remove(at: exactIndex)
                        } else {
                            // The full index can own an older same-ID Ask
                            // while bootstrap owns a newer one. Indexed
                            // transcript order wins even when the live tailer
                            // reaches the result before the index does.
                            liveLifecycle = nil
                        }
                    } else {
                        liveLifecycle = liveLifecycles.first
                        if liveLifecycle != nil {
                            liveLifecycles.removeFirst()
                        }
                    }
                    if liveLifecycle != nil {
                        if liveLifecycles.isEmpty {
                            activeAskUserQuestionLifecyclesByToolCallID.removeValue(forKey: toolCallID)
                        } else {
                            activeAskUserQuestionLifecyclesByToolCallID[toolCallID] = liveLifecycles
                        }
                    }
                    // A tool_result never opens a turn; it resolves the
                    // indexed Ask blocker when history has identified it.
                    // Only use FIFO when no indexed transcript identity is known
                    // (multiSelect-shaped cards included).
                    lifecycleResolveQuestionBlocker(
                        toolCallID: toolCallID,
                        exactLifecycleToken: historicalOpenerEventID)
                    lifecycleResolvePermissionBlocker(toolCallID: toolCallID)
                    let promptID = liveLifecycle?.promptID
                        ?? historicalOpenerEventID.map { _ in toolCallID }
                    let lifecycleToken = liveLifecycle?.token ?? historicalOpenerEventID
                    if let promptID, let lifecycleToken {
                        let resolvedEvent = publishFileBacked(
                            kind: .interactivePromptResolved,
                            lineOffset: lineOffset,
                            ordinal: ordinal,
                            eventID: resolvedEventID,
                            timestamp: timestamp,
                            role: "tool",
                            text: nil,
                            name: "AskUserQuestion",
                            input: nil,
                            output: output,
                            toolCallID: toolCallID,
                            metadata: [
                                "source": "claude_ask_user_question",
                                "prompt_id": promptID,
                                "lifecycle_token": lifecycleToken,
                                "reason": "tool_result",
                            ],
                            payload: .object([
                                "prompt_id": .string(promptID),
                                "lifecycle_token": .string(lifecycleToken),
                                "reason": .string("tool_result"),
                            ]))
                        if let historicalOpenerEventID,
                           let index = historicalClosureIndex {
                            var openerEventIDs = index.pendingAskOpenerEventIDsByPromptID[toolCallID] ?? []
                            if let openerIndex = openerEventIDs.firstIndex(of: historicalOpenerEventID) {
                                openerEventIDs.remove(at: openerIndex)
                            }
                            if openerEventIDs.isEmpty {
                                index.pendingAskOpenerEventIDsByPromptID.removeValue(forKey: toolCallID)
                            } else {
                                index.pendingAskOpenerEventIDsByPromptID[toolCallID] = openerEventIDs
                            }
                            index.closureByOpenerEventID[historicalOpenerEventID] = resolvedEvent
                            index.openerEventIDByClosureEventID[resolvedEvent.eventID]
                                = historicalOpenerEventID
                            synchronizeHistoricalOpenerClosureSequences()
                        }
                        ordinal += 1
                    }
                }
            } else if blockType == "text" {
                let text = Self.compactString(block["text"])
                if (object["isMeta"] as? Bool) != true,
                   text.hasPrefix("[Request interrupted") {
                    // Array-form interrupt (e.g. with attachments) ends the
                    // OWNING turn exactly like the string form — fenced via
                    // lineage, not unconditional.
                    lifecycleEndTurn(expectedTurnID: lifecycleOwningTurnID(for: uuid))
                }
                guard shouldPublishUserMessage(text) else { continue }
                // A genuine array-form user prompt (text + attachments)
                // begins Working exactly like the string form; interrupt
                // markers never do.
                if (object["isMeta"] as? Bool) != true,
                   !text.hasPrefix("[Request interrupted") {
                    lifecycleBeginTurn(turnID: uuid, adoptNewTurn: true)
                }
                publishFileBacked(kind: .userMessage,
                                  lineOffset: lineOffset,
                                  ordinal: ordinal,
                                  eventID: "\(uuid):user-text:\(index)",
                                  timestamp: timestamp,
                                  role: "user",
                                  text: text,
                                  name: nil,
                                  input: nil,
                                  output: nil,
                                  toolCallID: nil,
                                  metadata: nil)
                ordinal += 1
            }
        }
    }

    private func consumeAttachment(object: [String: Any], timestamp: String, lineOffset: Int) {
        guard let uuid = object["uuid"] as? String,
              let attachment = object["attachment"] as? [String: Any],
              attachment["type"] as? String == "queued_command",
              let prompt = attachment["prompt"] as? String else {
            return
        }

        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard shouldPublishUserMessage(trimmed) else {
            return
        }

        var metadata = [
            "queued_command": "true",
        ]
        if let commandMode = attachment["commandMode"] as? String,
           !commandMode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            metadata["command_mode"] = commandMode
        }

        publishFileBacked(kind: .userMessage,
                          lineOffset: lineOffset,
                          ordinal: 0,
                          eventID: "\(uuid):queued-command:0",
                          timestamp: timestamp,
                          role: "user",
                          text: trimmed,
                          name: nil,
                          input: nil,
                          output: nil,
                          toolCallID: nil,
                          metadata: metadata)
    }

    private func consumeLocalCommandEnvelope(_ text: String,
                                             uuid: String,
                                             timestamp: String,
                                             lineOffset: Int) -> Bool {
        if let commandName = Self.localCommandName(in: text) {
            let replayedContextOpenerEventID = commandName == "/context"
                ? "\(uuid):claude-context-command:0"
                : nil
            if isBackfillingHistory == false,
               historicalIndexEventSink == nil,
               let index = historicalClosureIndex,
               let openerEventID = index.pendingContextOpenerEventID,
               openerEventID != replayedContextOpenerEventID {
                index.contextConsumerSequenceByOpenerEventID[openerEventID]
                    = transcriptSequenceBase
                    + transcriptEventSequence(lineOffset: lineOffset, ordinal: 0)
                index.pendingContextOpenerEventID = nil
                synchronizeHistoricalOpenerClosureSequences()
            }
            pendingLocalCommand = ClaudeLocalCommand(name: commandName)
            if commandName == "/context" {
                publishFileBacked(kind: .userMessage,
                                  lineOffset: lineOffset,
                                  ordinal: 0,
                                  eventID: "\(uuid):claude-context-command:0",
                                  timestamp: timestamp,
                                  role: "user",
                                  text: commandName,
                                  name: nil,
                                  input: nil,
                                  output: nil,
                                  toolCallID: nil,
                                  metadata: [
                                      "slash_command": commandName,
                                      "tidey_generated": "claude_context_command",
                                  ])
            }
            return true
        }

        guard let stdout = Self.localCommandStdout(in: text) else {
            return false
        }

        let command = pendingLocalCommand
        pendingLocalCommand = nil
        let historicalOpenerEventID: String?
        if command == nil,
           isBackfillingHistory == false,
           historicalIndexEventSink == nil {
            let closureEventID = "\(uuid):claude-context:0"
            historicalOpenerEventID = historicalClosureIndex?
                .openerEventIDByClosureEventID[closureEventID]
                ?? historicalClosureIndex?.pendingContextOpenerEventID
        } else {
            historicalOpenerEventID = nil
        }
        guard command?.name == "/context" || historicalOpenerEventID != nil else {
            return true
        }
        guard let markdown = Self.markdownForClaudeContext(stdout: stdout) else {
            if let historicalOpenerEventID,
               let index = historicalClosureIndex {
                index.contextConsumerSequenceByOpenerEventID[historicalOpenerEventID]
                    = transcriptSequenceBase
                    + transcriptEventSequence(lineOffset: lineOffset, ordinal: 0)
                if index.pendingContextOpenerEventID == historicalOpenerEventID {
                    index.pendingContextOpenerEventID = nil
                }
                synchronizeHistoricalOpenerClosureSequences()
            }
            return true
        }

        let summaryEvent = publishFileBacked(kind: .assistantMessage,
                                             lineOffset: lineOffset,
                                             ordinal: 0,
                                             eventID: "\(uuid):claude-context:0",
                                             timestamp: timestamp,
                                             role: "assistant",
                                             text: markdown,
                                             name: nil,
                                             input: nil,
                                             output: nil,
                                             toolCallID: nil,
                                             metadata: [
                                                 "slash_command": "/context",
                                                 "tidey_generated": "claude_context",
                                             ])
        if let historicalOpenerEventID,
           let index = historicalClosureIndex {
            if index.pendingContextOpenerEventID == historicalOpenerEventID {
                index.pendingContextOpenerEventID = nil
            }
            index.closureByOpenerEventID[historicalOpenerEventID] = summaryEvent
            index.openerEventIDByClosureEventID[summaryEvent.eventID] = historicalOpenerEventID
            synchronizeHistoricalOpenerClosureSequences()
        }
        return true
    }

    private func shouldPublishUserMessage(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return false
        }

        if trimmed.contains("<task-notification>") {
            return false
        }

        if trimmed.contains("<turn_aborted>") || trimmed.contains("<tool_aborted>") {
            return false
        }

        if Self.isClaudeLocalCommandEnvelope(trimmed) {
            return false
        }

        if trimmed.hasPrefix("This session is being continued from a previous conversation") {
            return false
        }

        let withoutSystemReminders = trimmed
            .replacingOccurrences(of: "<system-reminder>[\\s\\S]*?</system-reminder>",
                                  with: "",
                                  options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if withoutSystemReminders.isEmpty {
            return false
        }

        return true
    }

    private static func isClaudeLocalCommandEnvelope(_ text: String) -> Bool {
        let stripped = text
            .replacingOccurrences(of: #"<(local-command-[A-Za-z0-9_-]+|command-(?:name|message|args))\b[^>]*>[\s\S]*?</\1>"#,
                                  with: "",
                                  options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return stripped.isEmpty && stripped != text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func localCommandName(in text: String) -> String? {
        firstCapture(in: text,
                     pattern: #"<command-name\b[^>]*>\s*([\s\S]*?)\s*</command-name>"#)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func localCommandStdout(in text: String) -> String? {
        firstCapture(in: text,
                     pattern: #"<local-command-stdout\b[^>]*>([\s\S]*?)</local-command-stdout>"#)
    }

    private static func markdownForClaudeContext(stdout: String) -> String? {
        let cleaned = stripANSIEscapeSequences(stdout)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        guard let summary = parseClaudeContextSummary(from: cleaned) else {
            return nil
        }
        return markdown(for: summary)
    }

    private static func parseClaudeContextSummary(from text: String) -> ClaudeContextSummary? {
        let lines = text
            .components(separatedBy: "\n")
            .map { normalizedClaudeContextLine($0) }
            .filter { !$0.isEmpty }
        guard lines.contains(where: { $0.range(of: "Context Usage", options: [.caseInsensitive, .diacriticInsensitive]) != nil }) else {
            return nil
        }

        let model = lines.first { line in
            line.range(of: #"^[A-Za-z][A-Za-z0-9 ._-]*\([^)]*context[^)]*\)$"#,
                       options: [.regularExpression, .caseInsensitive]) != nil &&
            line.range(of: "Context Usage", options: [.caseInsensitive, .diacriticInsensitive]) == nil
        }

        guard let usageLine = lines.first(where: { line in
            line.range(of: #"^[0-9]+(?:\.[0-9]+)?[kKmM]?/[0-9]+(?:\.[0-9]+)?[kKmM]?\s+tokens\s+\([0-9]+(?:\.[0-9]+)?%\)"#,
                       options: .regularExpression) != nil
        }),
              let usageMatch = captureGroups(in: usageLine,
                                             pattern: #"^([0-9]+(?:\.[0-9]+)?[kKmM]?)/([0-9]+(?:\.[0-9]+)?[kKmM]?)\s+tokens\s+\(([0-9]+(?:\.[0-9]+)?)%\)"#),
              let usedPercentValue = Double(usageMatch[2]) else {
            return nil
        }

        let free = metric(in: lines,
                          label: "Free space",
                          pattern: #"^Free space:\s*([0-9]+(?:\.[0-9]+)?[kKmM]?)\s*(?:tokens)?\s*\(([0-9]+(?:\.[0-9]+)?)%\)"#)
        let desiredBreakdown = [
            "Messages",
            "System prompt",
            "Skills",
            "System tools",
            "Memory files",
        ]
        let breakdown = desiredBreakdown.compactMap { label in
            metric(in: lines,
                   label: label,
                   pattern: #"^\#(label):\s*([0-9]+(?:\.[0-9]+)?[kKmM]?)\s+tokens\s+\(([0-9]+(?:\.[0-9]+)?)%\)"#)
        }

        return ClaudeContextSummary(model: model,
                                    used: usageMatch[0],
                                    total: usageMatch[1],
                                    usedPercentText: usageMatch[2],
                                    usedPercentValue: usedPercentValue,
                                    free: free,
                                    breakdown: breakdown)
    }

    private static func metric(in lines: [String], label: String, pattern: String) -> ClaudeContextMetric? {
        guard let line = lines.first(where: { $0.hasPrefix("\(label):") }),
              let groups = captureGroups(in: line, pattern: pattern),
              groups.count >= 2,
              let percentValue = Double(groups[1]) else {
            return nil
        }
        return ClaudeContextMetric(label: label,
                                   value: groups[0],
                                   percentText: groups[1],
                                   percentValue: percentValue)
    }

    private static func markdown(for summary: ClaudeContextSummary) -> String {
        var parts = ["### Claude Context"]
        if let model = summary.model {
            parts.append(model.replacingOccurrences(of: " (", with: " - ").replacingOccurrences(of: ")", with: ""))
        }
        parts.append("")
        parts.append("**Context**")
        parts.append("`\(progressBar(percent: summary.usedPercentValue))` \(summary.usedPercentText)%")
        var usageLine = "\(summary.used) / \(summary.total) used"
        if let free = summary.free {
            usageLine += " - \(free.value) free"
        }
        parts.append(usageLine)
        if !summary.breakdown.isEmpty {
            parts.append("")
            parts.append("**Breakdown**")
            for metric in summary.breakdown {
                parts.append("\(metric.label):")
                parts.append("`\(progressBar(percent: metric.percentValue))`")
                parts.append("\(metric.percentText)% - \(metric.value)")
            }
        }
        return parts.joined(separator: "\n")
    }

    private static func progressBar(percent: Double) -> String {
        let columns = 20
        let clamped = min(max(percent, 0), 100)
        let filled = Int((clamped / 100 * Double(columns)).rounded())
        return String(repeating: "■", count: filled) + String(repeating: "□", count: columns - filled)
    }

    private static func normalizedClaudeContextLine(_ line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let start = trimmed.firstIndex(where: { $0.isLetter || $0.isNumber }) else {
            return ""
        }
        return String(trimmed[start...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stripANSIEscapeSequences(_ text: String) -> String {
        let escape = "\u{001B}"
        let bell = "\u{0007}"
        return text
            .replacingOccurrences(of: "\(escape)\\][\\s\\S]*?(\(bell)|\(escape)\\\\)",
                                  with: "",
                                  options: .regularExpression)
            .replacingOccurrences(of: "\(escape)\\[[0-?]*[ -/]*[@-~]",
                                  with: "",
                                  options: .regularExpression)
    }

    private static func firstCapture(in text: String, pattern: String) -> String? {
        captureGroups(in: text, pattern: pattern)?.first
    }

    private static func captureGroups(in text: String, pattern: String) -> [String]? {
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = expression.firstMatch(in: text, range: range),
              match.numberOfRanges > 1 else {
            return nil
        }
        var groups = [String]()
        for index in 1..<match.numberOfRanges {
            guard let captureRange = Range(match.range(at: index), in: text) else {
                return nil
            }
            groups.append(String(text[captureRange]))
        }
        return groups
    }

    @discardableResult
    private func publishFileBacked(kind: AgentEventKind,
                                   lineOffset: Int,
                                   ordinal: Int,
                                   eventID: String,
                                   timestamp: String,
                                   role: String?,
                                   text: String?,
                                   name: String?,
                                   input: String?,
                                   output: String?,
                                   toolCallID: String?,
                                   metadata: [String: String]?,
                                   payload: JSONValue? = nil) -> AgentEvent {
        let position = TranscriptEventPosition(lineOffset: lineOffset, ordinal: ordinal)
        let proposedSeq = transcriptSequenceBase
            + transcriptEventSequence(lineOffset: lineOffset, ordinal: ordinal)
        let seq = publicTranscriptSequenceByEventID[eventID] ?? proposedSeq
        let resolvedMetadata = metadataWithClientRequestID(kind: kind, text: text, metadata: metadata)
        let event = AgentEvent(eventID: eventID,
                               seq: seq,
                               vendor: "claude",
                               workspaceID: record.workspaceID,
                               sessionID: record.sessionID,
                               timestamp: timestamp,
                               type: kind,
                               role: role,
                               text: text,
                               name: name,
                               input: input,
                               output: output,
                               toolCallID: toolCallID,
                               metadata: baseMetadata(resolvedMetadata),
                               payload: payload)
        if let historicalIndexEventSink {
            exactTranscriptPositionByPublicSequence[seq] = position
            historicalIndexEventSink(event)
            return event
        }
        if isBackfillingHistory {
            maxObservedSeq = max(maxObservedSeq, seq)
            // EVERY file-backed product — live, historical index, legacy
            // replay, or after-cursor step — records its exact public seq →
            // raw position; nothing is ever reverse-derived from synthetic
            // sequence arithmetic.
            exactTranscriptPositionByPublicSequence[seq] = position
            // Request-local after-cursor collection: while a step collector
            // exists, products (with their RAW positions — the walk slices
            // by position, never by public-sequence arithmetic) go ONLY to
            // it; the legacy before-cursor replay state stays untouched.
            if afterCursorReplayCollector != nil {
                if event.type == .interactivePrompt
                    || event.metadata?["tidey_generated"] == "claude_context_command" {
                    afterCursorReplayCollector?.openerEventIDs.insert(event.eventID)
                }
                afterCursorReplayCollector?.products.append(event)
                afterCursorReplayCollector?.positionsByEventID[event.eventID] = position
                return event
            }
            if let anchorSeq = historicalBackfillAnchorSeq,
               event.seq >= anchorSeq {
                return event
            }
            if event.type == .interactivePrompt
                || event.metadata?["tidey_generated"] == "claude_context_command" {
                historicalReplayOpenerEventIDs.insert(event.eventID)
            }
            historicalReplayProducts.append(event)
            return event
        }
        guard let acceptedEvent = hub.publish(event) else {
            maxObservedSeq = max(maxObservedSeq, seq)
            return event
        }
        maxObservedSeq = max(maxObservedSeq, acceptedEvent.seq)
        // EVERY file-backed product (normal or Hub-rebased) records its
        // public seq → raw position mapping: the typed plan classifies
        // cursors only through this exact map — synthetic seqs have no raw
        // position and must never be reverse-engineered via base arithmetic.
        exactTranscriptPositionByPublicSequence[acceptedEvent.seq] = position
        if acceptedEvent.seq != proposedSeq {
            publicTranscriptSequenceByEventID[eventID] = acceptedEvent.seq
            if let index = historicalClosureIndex,
               let openerEventID = index.openerEventIDByClosureEventID[eventID],
               let closure = index.closureByOpenerEventID[openerEventID] {
                index.closureByOpenerEventID[openerEventID] = closure.withSeq(acceptedEvent.seq)
                synchronizeHistoricalOpenerClosureSequences()
            }
        }
        publishInteractivePromptSidebarIfNeeded(acceptedEvent)
        return acceptedEvent
    }

    private func publishSynthetic(kind: AgentEventKind,
                                  seq: Int,
                                  eventID: String,
                                  timestamp: String,
                                  role: String?,
                                  text: String?,
                                  name: String?,
                                  input: String?,
                                  output: String?,
                                  toolCallID: String?,
                                  metadata: [String: String]?) {
        let event = AgentEvent(eventID: eventID,
                               seq: seq,
                               vendor: "claude",
                               workspaceID: record.workspaceID,
                               sessionID: record.sessionID,
                               timestamp: timestamp,
                               type: kind,
                               role: role,
                               text: text,
                               name: name,
                               input: input,
                               output: output,
                               toolCallID: toolCallID,
                               metadata: metadata)
        let acceptedEvent = hub.publish(event, deliverToSubscribers: !isBackfillingHistory) ?? event
        maxObservedSeq = max(maxObservedSeq, acceptedEvent.seq)
        publishInteractivePromptSidebarIfNeeded(acceptedEvent)
    }

    func publishInteractivePromptSidebarIfNeeded(_ event: AgentEvent) {
        guard !isBackfillingHistory,
              event.type == .interactivePrompt || event.type == .interactivePromptResolved else {
            return
        }
        switch event.type {
        case .interactivePrompt:
            guard promptNotificationDeduper.shouldNotify(event, sessionID: record.sessionID) else {
                return
            }
        case .interactivePromptResolved:
            guard promptNotificationDeduper.markResolved(event,
                                                         sessionID: record.sessionID) == .clearedNotified else {
                return
            }
        default:
            return
        }

        let messages = AgentInteractivePromptSidebarMessages.messages(for: event,
                                                                      workspaceID: event.workspaceID)
        guard let socketClient,
              !messages.isEmpty else {
            return
        }
        for message in messages {
            do {
                try socketClient.send(command: message)
            } catch {
                BridgeLogger.server.error("claude interactive prompt sidebar message failed session_id=\(self.record.sessionID, privacy: .public) message=\(message, privacy: .public) error=\(String(describing: error), privacy: .public)")
            }
        }
    }

    private func nextSyntheticSequence() -> Int {
        maxObservedSeq += 1
        return maxObservedSeq
    }

    private func baseMetadata(_ metadata: [String: String]?) -> [String: String]? {
        var merged = metadata ?? [:]
        if let panelID = record.panelID, !panelID.isEmpty {
            merged["panel_id"] = panelID
        }
        return merged.isEmpty ? nil : merged
    }

    private func metadataWithClientRequestID(kind: AgentEventKind,
                                             text: String?,
                                             metadata: [String: String]?) -> [String: String]? {
        guard isBackfillingHistory == false,
              kind == .userMessage,
              let text,
              let clientRequestID = chatSubmitEchoRegistry.consumeClientRequestID(workspaceID: record.workspaceID,
                                                                                  panelID: record.panelID,
                                                                                  sessionID: record.sessionID,
                                                                                  vendor: "claude",
                                                                                  text: text) else {
            return metadata
        }
        var merged = metadata ?? [:]
        merged["client_request_id"] = clientRequestID
        return merged
    }

    private static func compactString(_ value: Any?) -> String {
        guard let string = value as? String else {
            return ""
        }
        return string.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func compactOptionalString(_ value: Any?) -> String? {
        let string = compactString(value)
        return string.isEmpty ? nil : string
    }

    private static func stringifyToolResultContent(_ value: Any?) -> String? {
        if let string = value as? String {
            return compactString(string)
        }
        return stringifyJSON(value)
    }

    private static func stringifyJSON(_ value: Any?) -> String? {
        guard let value else {
            return nil
        }
        if let string = value as? String {
            return compactString(string)
        }
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            return nil
        }
        return string
    }
}
