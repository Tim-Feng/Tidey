import Darwin
import Foundation

private let claudeTranscriptMajorVersion = "2."

protocol AgentTranscriptSession: AnyObject {
    func start()
    func update(record: AgentSessionRegistryRecord)
    func backfill(beforeSeq: Int, limit: Int) -> Bool
    func stop()
    // Two-phase, race-free workspace-migration transaction used by
    // AgentSessionRegistryMonitor whenever a SURVIVING session (not
    // retired — same sessionID) is discovered to have moved to a new
    // workspace_id, whether via a registry scan or a resolved pane/process
    // binding correction:
    //
    // prepareUpdate(record:) runs SYNCHRONOUSLY on this session's own
    // private queue. Any work ALREADY enqueued/executing there (e.g. a
    // just-detected task_complete the tailer's file watcher fired for)
    // drains first via plain FIFO ordering — the same guarantee stop()/
    // backfill() already rely on. It then holds ALL of this session's own
    // sidebar-ish publication (Codex's report_shell_state sidebar, Claude's
    // interactive-prompt lifecycle messages) and switches this session's
    // record and Hub workspace binding to the new workspace — all before
    // returning. Nothing this session could ever say about the new
    // workspace is observable yet.
    //
    // The monitor then sends the OLD workspace's last-owner departure
    // cleanup (only if no other current session still owns it).
    //
    // finishUpdate() releases the hold and flushes EVERY held message
    // batch, in the exact order they were produced — never coalesced or
    // dropped, so a lifecycle-specific message (a task_complete
    // notification, an AskUserQuestion prompt, ...) produced during the
    // held window is still said in full, just delayed until now. This is
    // what actually closes the race a bare "drain, then separately call
    // async update()" sequence could not: draining only flushes what was
    // ALREADY queued, it does not prevent something NEW from being queued
    // (and its sidebar effect published) ahead of a later, separate async
    // update() call — holding publication for the whole prepare-to-finish
    // window does.
    func prepareUpdate(record: AgentSessionRegistryRecord)
    func finishUpdate()
}

struct AgentSessionRegistryRecord: Codable, Sendable, Equatable {
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

// Adapts a plain (String) throws -> Void sender to TideyCommandSending, so
// an injected sidebarMessageSender can also be handed to transcript
// sessions (which require the protocol type) — see AgentSessionRegistryMonitor.
private final class ClosureCommandSender: TideyCommandSending {
    private let sender: (String) throws -> Void
    init(send: @escaping (String) throws -> Void) {
        self.sender = send
    }
    func send(command: String) throws {
        try sender(command)
    }
}

final class AgentSessionRegistryMonitor {
    typealias ParentPIDLookup = @Sendable (Int32) -> Int32?
    typealias DescendantProcessLookup = @Sendable (Int32) -> [AgentProcessDescriptor]
    typealias RolloutPathLookup = @Sendable (Int32) -> String?
    typealias CodexRolloutBySessionIDLookup = @Sendable (String) -> String?
    typealias OrdinaryTmuxCarrierIdentityResolver = (AgentSessionRegistryRecord) -> TideyOrdinaryTmuxCarrierIdentity?
    private static let liveParentPIDLookup: ParentPIDLookup = { pid in
        guard pid > 0 else {
            return nil
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-o", "ppid=", "-p", String(pid)]

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        guard process.terminationStatus == 0 else {
            return nil
        }

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: outputData, encoding: .utf8)?
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

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-Fn", "-p", String(pid)]
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        guard process.terminationStatus == 0,
              let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(),
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

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-P", String(pid)]
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return []
        }

        guard let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(),
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

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-o", "comm=", "-o", "args=", "-p", String(pid)]
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        guard process.terminationStatus == 0,
              let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(),
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
    private let livePanelSnapshotRefreshInterval: TimeInterval
    private let runtimeSyncer: AgentSessionRuntimeSyncing?
    // Injectable seam for the departed-workspace sidebar ownership cleanup
    // (see sendSidebarCleanupForDepartedWorkspaceOwners) — defaults to
    // wrapping socketClient.send(command:), but production tests can inject
    // a recorder directly without needing a real Unix socket, and failures
    // are always logged here rather than silently swallowed at the call site.
    private let sidebarMessageSender: (String) throws -> Void
    // The SAME effective sender, wrapped as TideyCommandSending, so an
    // injected sidebarMessageSender ALSO reaches each transcript session's
    // OWN sidebar activation (running/prompt) — not just this class's
    // departed-workspace cleanup. Production default is still socketClient
    // itself (no wrapping, no behavior change) when no override is given.
    private let transcriptCommandSender: TideyCommandSending?
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
         livePanelSnapshotRefreshInterval: TimeInterval = 5,
         runtimeSyncer: AgentSessionRuntimeSyncing? = nil,
         sidebarMessageSender: ((String) throws -> Void)? = nil) {
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
        self.livePanelSnapshotRefreshInterval = livePanelSnapshotRefreshInterval
        self.runtimeSyncer = runtimeSyncer
        if let sidebarMessageSender {
            self.sidebarMessageSender = sidebarMessageSender
            // An injected sender must ALSO be what each transcript session
            // uses for its own sidebar activation — otherwise a production
            // test can observe this class's cleanup commands but never the
            // sessions' own running/prompt activation, which is not the
            // real production wiring (both flow through ONE sender there).
            self.transcriptCommandSender = ClosureCommandSender(send: sidebarMessageSender)
        } else {
            self.sidebarMessageSender = { message in
                try socketClient?.send(command: message)
            }
            self.transcriptCommandSender = socketClient
        }
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
        let paneCorrectedEntries = loadedRecords.map { loadedRecord in
            let correctedRecord = recordWithPaneIdentityIfAvailable(loadedRecord.record)
            persistCanonicalizedRecordIfNeeded(sourceRecord: loadedRecord.record,
                                               correctedRecord: correctedRecord,
                                               url: loadedRecord.url)
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
        let previousActiveRecords = Array(self.activeRecords.values)
        // Everything below runs AFTER the independent app-server runtime
        // producer's own old-generation fence/stop/sidebar-drain (reconcile's
        // internal retirement + sidebarQueue barrier) — as ONE ordered
        // sequence inside the reconcile callback, not staged before it:
        //
        // 1. Retire stale TRANSCRIPT sessions. session.stop() is queue.sync,
        //    so it drains any work ALREADY enqueued on that session's own
        //    queue (e.g. a task_complete the tailer's file watcher just
        //    fired for) before this call returns. Doing this INSIDE the
        //    callback (after the runtime's own stop-driven terminal may
        //    already have published) means a stop-driven runtime terminal
        //    can never arrive AFTER this transcript's sessionEnded — the
        //    Hub's removal boundary for this session is the LAST lifecycle
        //    event, not an intermediate one an old runtime terminal can
        //    still slip behind.
        // 2. Prepare EVERY surviving session whose record actually changed —
        //    not just a workspace migration, ANY change (panel, transcript
        //    path/source identity, app-server socket/root...) — atomically
        //    switching its record/Hub-binding and holding sidebar
        //    publication. Running this AFTER the runtime fence (not before
        //    reconcile, and not before transcript retirement) is what
        //    establishes each session's Hub epoch (e.g.
        //    CodexTranscriptSession.start's beginNewSourceEpoch) only once
        //    no old runtime generation can still publish into it.
        // 3. Send the all-vendor departed-workspace cleanup.
        // 4. Create/start genuinely NEW transcript sessions — establishing
        //    THEIR Hub epoch too — before the runtime syncer attaches any
        //    new/surviving producer.
        //
        // Only after this whole callback returns does runtime attach run;
        // prepared sessions are released (finishUpdate) after reconcile
        // itself returns. With no runtime syncer, the callback still runs,
        // directly, in the same order.
        var prepared: [(sessionID: String, record: AgentSessionRegistryRecord)] = []
        let retirePrepareCleanupAndActivateNewSessions = {
            self.retireStaleSessions(activeRecords)
            prepared = self.prepareExistingSessionUpdates(activeRecords)
            self.sendSidebarCleanupForDepartedWorkspaceOwners(previousRecords: previousActiveRecords, currentRecords: activeRecords)
            self.activateSessions(activeRecords, skipping: Set(self.sessions.keys))
        }
        if let runtimeSyncer {
            runtimeSyncer.reconcile(records: activeRecords, betweenRetirementAndActivation: retirePrepareCleanupAndActivateNewSessions)
        } else {
            retirePrepareCleanupAndActivateNewSessions()
        }
        for entry in prepared {
            sessions[entry.sessionID]?.finishUpdate()
        }
        self.activeRecords = Dictionary(uniqueKeysWithValues: activeRecords.map { ($0.sessionID, $0) })
        for record in activeRecords where resolvedPanelBindings[record.sessionID] != nil {
            applyResolvedBinding(sessionID: record.sessionID,
                                 workspaceID: record.workspaceID,
                                 panelID: record.panelID)
        }
    }

    // Prepares (synchronously switches record/Hub-binding + holds sidebar
    // publication for) every EXISTING session whose record actually changed
    // this scan — a superset of "workspace migrated": panel-only changes,
    // transcript-path/source-identity switches, and app-server root/socket
    // changes all establish their new Hub epoch here too, before any
    // independent runtime producer or new-session activation runs. Returns
    // the prepared entries so the caller can both skip them in
    // activateSessions and finishUpdate() them once the runtime producer has
    // been reconciled.
    private func prepareExistingSessionUpdates(_ currentRecords: [AgentSessionRegistryRecord]) -> [(sessionID: String, record: AgentSessionRegistryRecord)] {
        var prepared: [(sessionID: String, record: AgentSessionRegistryRecord)] = []
        for record in currentRecords {
            guard let session = sessions[record.sessionID],
                  activeRecords[record.sessionID] != record else {
                continue
            }
            session.prepareUpdate(record: record)
            activeRecords[record.sessionID] = record
            prepared.append((record.sessionID, record))
        }
        return prepared
    }

    private func refreshLivePanelSnapshotsIfNeeded(for records: [AgentSessionRegistryRecord]) {
        guard records.contains(where: recordMayNeedLivePanelSnapshotRefresh(_:)),
              let livePanelSnapshotRequestSender else {
            return
        }
        let now = Date()
        if let lastLivePanelSnapshotRefreshAt,
           now.timeIntervalSince(lastLivePanelSnapshotRefreshAt) < livePanelSnapshotRefreshInterval {
            return
        }
        lastLivePanelSnapshotRefreshAt = now

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
                      let result = panelResponse.result,
                      let extracted = AgentPanelProcessSnapshotExtractor.snapshots(fromPanelListResult: result) else {
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
            return false
        }
        guard let panelID = record.panelID,
              panelID.isEmpty == false else {
            return true
        }
        return paneIdentityMatchesKnownLivePanel(TmuxPaneIdentity(workspaceID: record.workspaceID,
                                                                  panelID: panelID)) == false
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

    private func persistCanonicalizedRecordIfNeeded(sourceRecord: AgentSessionRegistryRecord,
                                                    correctedRecord: AgentSessionRegistryRecord,
                                                    url: URL) {
        guard sourceRecord.workspaceID != correctedRecord.workspaceID ||
              sourceRecord.panelID != correctedRecord.panelID ||
              sourceRecord.tmuxSocketPath != correctedRecord.tmuxSocketPath else {
            return
        }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(correctedRecord)
            try data.write(to: url, options: [.atomic])
            BridgeLogger.server.info("agent registry canonicalized pane identity session_id=\(correctedRecord.sessionID, privacy: .public) vendor=\(correctedRecord.vendor, privacy: .public) workspace_id=\(correctedRecord.workspaceID, privacy: .public) panel_id=\(correctedRecord.panelID ?? "-", privacy: .public)")
        } catch {
            BridgeLogger.server.error("agent registry canonicalize_failed session_id=\(correctedRecord.sessionID, privacy: .public) vendor=\(correctedRecord.vendor, privacy: .public) error=\(String(describing: error), privacy: .public)")
        }
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
            // A single newly-discovered record is being ADDED here, never
            // removed — no retirement or departed-workspace cleanup applies,
            // just activation (create-or-update) for this record.
            let records = activeRecords.values.filter { $0.sessionID != record.sessionID } + [record]
            activateSessions(records)
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
        // Route through the SAME runtime-reconcile-first, prepare-inside-
        // callback shape as scanRegistry/applyResolvedBinding: this active-
        // thread update can itself be a transcript source-identity switch
        // (rolloutPath/threadID changed), which must only begin its new Hub
        // epoch AFTER the runtime syncer's own reconciliation has
        // fenced/drained the OLD root-thread generation (the root thread ID
        // changed too) — never before it, or a stale runtime callback could
        // leak into the new epoch. Workspace is unchanged here, so there is
        // no departed-workspace cleanup to send.
        if let session = sessions[sessionID] {
            let prepare = { session.prepareUpdate(record: updated) }
            if let runtimeSyncer {
                runtimeSyncer.reconcile(records: Array(activeRecords.values), betweenRetirementAndActivation: prepare)
            } else {
                prepare()
            }
            session.finishUpdate()
        } else {
            runtimeSyncer?.reconcile(records: Array(activeRecords.values), betweenRetirementAndActivation: {})
        }
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
        guard let sourceRecord = activeRecords[sessionID] else {
            // No active record yet to derive an effective record from —
            // there is no session/sidebar/runtime state to reconcile
            // against either (a runtime entry is always derived from a real
            // registry record already in activeRecords).
            hub.migrateSession(sessionID: sessionID, toWorkspaceID: workspaceID, panelID: panelID)
            return
        }
        let effective = effectiveRecord(for: sourceRecord)
        let previousWorkspaceID = sourceRecord.workspaceID
        let session = sessions[sessionID]
        activeRecords[sessionID] = effective
        // EVERY effective-record change (workspace and/or panel-only, with
        // or without an existing transcript session) is reconciled through
        // the SAME runtime-first, prepare/migrate-inside-callback shape
        // scanRegistry uses (see prepareExistingSessionUpdates): an
        // independent app-server runtime producer must never retain a stale
        // workspace/panel context (and thus a stale submit/prompt route)
        // until a LATER scan happens to notice it — a panel-only correction
        // still needs its runtime context switched immediately, just
        // without any departed-workspace cleanup (workspace unchanged).
        // Running prepare/migrate INSIDE the callback (after reconcile's
        // own old-generation fence/drain) means a stale runtime generation
        // can never leak into a same-call transcript source-epoch reset.
        let prepareOrMigrateThenCleanupIfNeeded = {
            if let session {
                session.prepareUpdate(record: effective)
            } else {
                self.hub.migrateSession(sessionID: sessionID, toWorkspaceID: workspaceID, panelID: panelID)
            }
            if previousWorkspaceID != effective.workspaceID,
               !self.isWorkspaceStillOwned(previousWorkspaceID, excludingSessionID: sessionID) {
                for message in CodexSidebarMessages.prompt(workspaceID: previousWorkspaceID) {
                    self.sendSidebarMessage(message)
                }
            }
        }
        if let runtimeSyncer {
            runtimeSyncer.reconcile(records: Array(activeRecords.values), betweenRetirementAndActivation: prepareOrMigrateThenCleanupIfNeeded)
        } else {
            prepareOrMigrateThenCleanupIfNeeded()
        }
        session?.finishUpdate()
    }

    private func isWorkspaceStillOwned(_ workspaceID: String, excludingSessionID: String) -> Bool {
        activeRecords.values.contains { $0.sessionID != excludingSessionID && $0.workspaceID == workspaceID }
    }

    // Retirement runs as the FIRST step inside the runtime-reconcile
    // callback (see scanRegistry) — after the independent app-server runtime
    // producer's own old-generation fence/stop/sidebar-drain, so an old
    // runtime's allowed stop-driven terminal (e.g. an interactivePrompt
    // resolution) can never arrive AFTER this transcript session's own
    // sessionEnded boundary. session.stop() is itself queue.sync, which
    // drains any work ALREADY enqueued on that session's own queue (e.g. a
    // just-detected task_complete line the tailer's file watcher fired for,
    // which would itself send a sidebar "completed" message) before stop()'s
    // own body runs — any such terminal sidebar output a retiring session
    // was ever going to send is fully flushed before anything else in this
    // callback runs.
    private func retireStaleSessions(_ records: [AgentSessionRegistryRecord]) {
        let activeSessionIDs = Set(records.map(\.sessionID))
        let staleSessionIDs = sessions.keys.filter { !activeSessionIDs.contains($0) }
        for sessionID in staleSessionIDs {
            sessions.removeValue(forKey: sessionID)?.stop()
        }
    }
    // Activation (create-or-update) runs INSIDE the runtime reconcile
    // callback, after cleanup and after every already-existing session was
    // already prepared — see scanRegistry. `skipping` excludes sessionIDs
    // already fully handled by prepareExistingSessionUpdates's own
    // prepare/finish transaction, so only genuinely NEW sessions are
    // created here (and their Hub epoch established) before the runtime
    // syncer attaches any new/surviving producer.
    private func activateSessions(_ records: [AgentSessionRegistryRecord], skipping skippedSessionIDs: Set<String> = []) {
        for record in records {
            if skippedSessionIDs.contains(record.sessionID) {
                continue
            }
            if let session = sessions[record.sessionID] {
                session.update(record: record)
                continue
            }
            guard let vendor = AgentVendorRegistry.resolve(id: record.vendor) else {
                continue
            }
            let session = vendor.makeTranscriptSession(record: record,
                                                       fileManager: fileManager,
                                                       hub: hub,
                                                       socketClient: transcriptCommandSender,
                                                       chatSubmitEchoRegistry: chatSubmitEchoRegistry)
            sessions[record.sessionID] = session
            session.start()
        }
    }

    // Workspace ownership departure cleanup (no workspace-status lifecycle
    // store): a workspace's sidebar shell-state (running/prompt) is owned
    // by whichever record(s) — of EITHER vendor — currently claim that
    // workspace_id. Claude's own interactive-prompt lifecycle writes
    // sidebar state for a shared workspace too, so a Claude record is just
    // as much a current owner as a Codex one; ownership here is generic
    // across vendors even though the actual cleanup message sent is
    // Codex's `report_shell_state` sidebar protocol (the only vendor with a
    // sidebar shell-state notion to clean up). A record leaving a
    // workspace — a true workspace migration, a stale-record removal, or a
    // stop — must not leave that workspace's sidebar frozen on its
    // last-seen running state.
    //
    // This only ever fires when NO current record (of any vendor) still
    // claims the departed workspace_id (the monitor is the only place that
    // sees both the previous and the current full record sets at once, so
    // it is the only place that can prove no other owner remains) —
    // checking only "was there a Codex owner before that's gone now" would
    // miss the two-step case: Codex leaves first (correctly no-ops, Claude
    // still owns it), then Claude leaves later with no Codex change in that
    // round at all — a Codex-only candidate set would never fire for that
    // second, actually-final departure, leaving the workspace's sidebar
    // frozen on Codex's old running state forever. A panel-only migration
    // (workspace_id unchanged) never appears in this diff at all. The
    // arriving workspace's own correct state (running/prompt) is
    // established independently by that record's own transcript session
    // bootstrap (see CodexTranscriptSession.resolveTranscriptIfPossible /
    // publishSidebarSessionActivation) — this only cleans up what was left
    // behind, sending the same plain `prompt` message idle-stop already
    // uses (never a "completed" notification, which would be a fabricated
    // claim about how the departed session actually ended).
    private func sendSidebarCleanupForDepartedWorkspaceOwners(previousRecords: [AgentSessionRegistryRecord],
                                                              currentRecords: [AgentSessionRegistryRecord]) {
        let previousWorkspaces = Set(previousRecords.map(\.workspaceID))
        let currentWorkspaces = Set(currentRecords.map(\.workspaceID))
        let departedWorkspaces = previousWorkspaces.subtracting(currentWorkspaces)
        guard !departedWorkspaces.isEmpty else {
            return
        }
        for workspaceID in departedWorkspaces.sorted() {
            for message in CodexSidebarMessages.prompt(workspaceID: workspaceID) {
                sendSidebarMessage(message)
            }
        }
    }

    private func sendSidebarMessage(_ message: String) {
        do {
            try sidebarMessageSender(message)
        } catch {
            BridgeLogger.server.error("departed-workspace sidebar cleanup command failed message=\(message, privacy: .public) error=\(String(describing: error), privacy: .public)")
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

final class JSONLFileTailer {
    private let fileURL: URL
    private let queue: DispatchQueue
    private let bootstrapLineLimit: Int
    private let lineHandler: (Int, String) -> Void
    private let invalidationHandler: () -> Void

    private var fd: Int32 = -1
    private var source: DispatchSourceFileSystemObject?
    private var pendingData = Data()
    private var nextReadOffset = 0
    private var pendingLineOffset: Int?
    private(set) var earliestLoadedOffset: Int?
    private(set) var reachedStartOfFile = false

    init(fileURL: URL,
         queue: DispatchQueue,
         bootstrapLineLimit: Int = transcriptBootstrapLineLimit,
         lineHandler: @escaping (Int, String) -> Void,
         invalidationHandler: @escaping () -> Void) {
        self.fileURL = fileURL
        self.queue = queue
        self.bootstrapLineLimit = bootstrapLineLimit
        self.lineHandler = lineHandler
        self.invalidationHandler = invalidationHandler
    }

    func start() throws {
        let fd = open(fileURL.path, O_RDONLY)
        guard fd >= 0 else {
            throw POSIXError(.ENOENT)
        }
        self.fd = fd
        let bootstrappedLines = try JSONLFileReader.readTail(fileURL: fileURL, limit: bootstrapLineLimit)
        for (offset, line) in bootstrappedLines {
            lineHandler(offset, line)
        }
        earliestLoadedOffset = bootstrappedLines.first?.offset
        reachedStartOfFile = (bootstrappedLines.first?.offset ?? 0) == 0

        let endOffset = lseek(fd, 0, SEEK_END)
        guard endOffset >= 0 else {
            let posixCode = POSIXErrorCode(rawValue: errno) ?? .EIO
            close(fd)
            self.fd = -1
            throw POSIXError(posixCode)
        }
        nextReadOffset = Int(endOffset)
        pendingData.removeAll(keepingCapacity: false)
        pendingLineOffset = nil

        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd,
                                                               eventMask: [.write, .extend, .delete, .rename, .revoke],
                                                               queue: queue)
        source.setEventHandler { [weak self] in
            self?.handleFileEvent()
        }
        source.setCancelHandler { [fd] in
            close(fd)
        }
        source.resume()
        self.source = source
    }

    // Test observability at the CALLEE: records every beforeOffset this
    // tailer actually RECEIVED — a call-site mutation cannot fake it.
    private(set) var receivedBackfillOffsetsForTesting: [Int] = []

    func resetBackfillObservationForTesting() {
        receivedBackfillOffsetsForTesting = []
    }

    func backfill(beforeOffset: Int, limit: Int) throws -> Bool {
        receivedBackfillOffsetsForTesting.append(beforeOffset)
        guard beforeOffset > 0, limit > 0 else {
            return false
        }
        // Honor the CALLER's anchor: a fresh client may legitimately request
        // a NEWER range than the deepest page another client already read —
        // neither `earliestLoadedOffset` nor a sticky EOF marker may redirect
        // or block that request.
        let lines = try JSONLFileReader.readBefore(fileURL: fileURL,
                                                   beforeOffset: beforeOffset,
                                                   limit: limit)
        guard !lines.isEmpty else {
            if beforeOffset <= (earliestLoadedOffset ?? beforeOffset) {
                reachedStartOfFile = true
            }
            return false
        }

        for (offset, line) in lines {
            lineHandler(offset, line)
        }
        earliestLoadedOffset = min(earliestLoadedOffset ?? Int.max, lines.first?.offset ?? Int.max)
        reachedStartOfFile = (lines.first?.offset ?? 0) == 0
        return true
    }

    func stop() {
        // Drain any bytes already written to the fd but not yet delivered
        // by a dispatched .write/.extend event: stop() runs synchronously
        // on this tailer's own queue (via the wrapping session's
        // queue.sync stop()), so this read cannot race a LATER file-event
        // callback — it can only pick up data already sitting in the fd
        // right now. Without this, a final line written in the same
        // instant as removal/migration (e.g. a task_complete or
        // prompt-resolved terminal) could be silently lost: the
        // DispatchSource is cancelled below before its event for that
        // write would ever fire.
        readAvailableData()
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
            stop()
            invalidationHandler()
            return
        }
        readAvailableData()
    }

    private func readAvailableData() {
        guard fd >= 0 else {
            return
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

        drainCompleteLines()
    }

    private func drainCompleteLines() {
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
            guard !lineData.isEmpty,
                  let line = String(data: lineData, encoding: .utf8) else {
                continue
            }
            lineHandler(lineOffset, line)
        }
    }
}

final class ClaudeTranscriptSession: AgentTranscriptSession {
    private let queue: DispatchQueue
    private let fileManager: FileManager
    private let hub: AgentEventHub
    private let socketClient: TideyCommandSending?
    private let chatSubmitEchoRegistry: ChatSubmitEchoRegistry
    private let promptNotificationDeduper = AgentInteractivePromptNotificationDeduper()

    private var record: AgentSessionRegistryRecord
    private var resolverTimer: DispatchSourceTimer?
    private var tailer: JSONLFileTailer?
    private var transcriptURL: URL?
    private var maxObservedSeq = transcriptSessionStartedSequence
    // Per-source sequence base (Codex-style): a NEW source epoch emits every
    // file-backed seq above the previous stream, keeping the Hub cursor
    // monotonic while raw offsets stay local to the new file.
    private var transcriptSequenceBase = transcriptSessionStartedSequence
    private var didPublishStart = false
    private var didPublishEnd = false
    private var unsupportedVersions = Set<String>()
    private var isBackfillingHistory = false
    // Set for the duration of a prepareUpdate()...finishUpdate() workspace
    // migration transaction (see CodexTranscriptSession.isSidebarPublicationHeld
    // for the full rationale). While held,
    // publishInteractivePromptSidebarIfNeeded BUFFERS each message batch,
    // in order, instead of sending — finishUpdate() flushes them all, in
    // the same order, never coalesced/dropped.
    private var isSidebarPublicationHeld = false
    private var heldSidebarMessageBatches: [[String]] = []
    private var pendingLocalCommand: ClaudeLocalCommand?
    private var activeAskUserQuestionPromptIDByToolCallID = [String: String]()
    // Historical replay transaction: raw historical lines (offset-sorted,
    // capacity-limited) are re-parsed with a FRESH parser state on every
    // page, so cross-page correlations (Ask across pages, /context pairs)
    // derive complete history without touching live parser state.
    private var historicalRawLines: [(offset: Int, line: String)] = []
    private var historicalReplayProducts: [AgentEvent] = []
    private var isCollectingBackfillPage = false
    private var collectedBackfillPage: [(offset: Int, line: String)] = []
    private let historicalReplayWindowCapacity: Int

    private struct LiveParserStateSnapshot {
        let unsupportedVersions: Set<String>
        let pendingLocalCommand: ClaudeLocalCommand?
        let activeAskUserQuestionPromptIDByToolCallID: [String: String]
    }

    private func captureLiveParserState() -> LiveParserStateSnapshot {
        LiveParserStateSnapshot(unsupportedVersions: unsupportedVersions,
                                pendingLocalCommand: pendingLocalCommand,
                                activeAskUserQuestionPromptIDByToolCallID: activeAskUserQuestionPromptIDByToolCallID)
    }

    private func resetParserStateForHistoricalReplay() {
        unsupportedVersions = []
        pendingLocalCommand = nil
        activeAskUserQuestionPromptIDByToolCallID = [:]
    }

    private func restoreLiveParserState(_ snapshot: LiveParserStateSnapshot) {
        unsupportedVersions = snapshot.unsupportedVersions
        pendingLocalCommand = snapshot.pendingLocalCommand
        activeAskUserQuestionPromptIDByToolCallID = snapshot.activeAskUserQuestionPromptIDByToolCallID
    }

    private func transcriptEventSequenceAnchor(forLineOffset lineOffset: Int) -> Int {
        transcriptSequenceBase + transcriptEventSequence(lineOffset: lineOffset, ordinal: 0)
    }

    // Reverse seq→line-offset mapping for the CURRENT source: fails closed
    // for cursors at/below the base (they belong to a previous source).
    private func transcriptLineOffsetInCurrentSource(for seq: Int) -> Int? {
        guard seq > transcriptSequenceBase else {
            return nil
        }
        return transcriptLineOffset(for: seq - transcriptSequenceBase)
    }

    private var lastBackfillPageOffsets: ClosedRange<Int>?
    private var lastRequestedBackfillAnchorSeq: Int?
    // Test observability: the EXACT first beforeOffset the tailer RECEIVED
    // during the last backfill call — recorded at the callee entry.
    var lastBackfillStartOffsetForTesting: Int? {
        queue.sync { tailer?.receivedBackfillOffsetsForTesting.first }
    }
    // Test observability: the CURRENT local sequence base — direct proof
    // that a boundary/start seq is seeded from publish's ACTUAL return
    // value, not the pre-publish reservation. A test asserting only on
    // externally-observed seqs (subscriber deliveries, Hub fetch) cannot
    // reliably catch a wrong local base: every event that flows back
    // through `hub.publish` gets silently rebased-on-collision by the
    // Hub's OWN safety net, which launders a systematically wrong local
    // base into a still-monotonic, still-externally-consistent sequence.
    // Only OFFLINE arithmetic that never touches `hub.publish` again
    // (`transcriptLineOffsetInCurrentSource`, used by `backfill`) would
    // eventually diverge, but confirming that divergence indirectly is
    // fragile — this exposes the actual value directly.
    var transcriptSequenceBaseForTesting: Int {
        queue.sync { transcriptSequenceBase }
    }
    // Correlation-closure retention: derived terminals / context summaries
    // whose OPENER may outlive them in the bounded raw window. Eviction must
    // never leave half a lifecycle — a window that still shows the opener
    // gets its retained closure re-added to the replacement.
    private var retainedHistoricalClosuresByKey: [String: AgentEvent] = [:]
    private var retainedHistoricalClosureKeyOrder: [String] = []
    let retainedHistoricalClosureCapacity: Int
    // Resolution safety is derived from the FILE (the source of truth), not
    // from an evictable in-memory ledger or a fixed line budget: any finite
    // in-memory threshold just moves the semantic-eviction bug. The forward
    // probe scans to EOF (bounded by the transcript itself).

    private func mergeHistoricalPage(_ page: [(offset: Int, line: String)]) {
        guard let pageMin = page.map(\.offset).min(),
              let pageMax = page.map(\.offset).max() else {
            return
        }
        lastBackfillPageOffsets = pageMin...pageMax
        var merged = page + historicalRawLines
        merged.sort { $0.offset < $1.offset }
        var seenOffsets = Set<Int>()
        merged = merged.filter { seenOffsets.insert($0.offset).inserted }
        // Direction-aware eviction: the JUST-REQUESTED page always stays; the
        // window sheds whichever end is farther from it, so deep old-paging
        // sheds the newest end while a fresh newer-range request sheds the
        // oldest end. The Hub's historical replacement scope follows the
        // window exactly.
        while merged.count > historicalReplayWindowCapacity {
            let distanceToOldEnd = pageMin - (merged.first?.offset ?? pageMin)
            let distanceToNewEnd = (merged.last?.offset ?? pageMax) - pageMax
            if distanceToNewEnd >= distanceToOldEnd {
                merged.removeLast()
            } else {
                merged.removeFirst()
            }
        }
        historicalRawLines = merged
    }

    // The historical parse is an isolated transaction: fresh parser state,
    // full replay of the window in offset order, storage-only publication
    // (the Hub dedupes replays by original line identity), then the live
    // parser state is restored untouched.
    @discardableResult
    private func replayHistoricalWindow() -> [AgentEvent] {
        let liveSnapshot = captureLiveParserState()
        resetParserStateForHistoricalReplay()
        historicalReplayProducts = []
        isBackfillingHistory = true
        for entry in historicalRawLines {
            consume(line: entry.line, lineOffset: entry.offset)
        }
        isBackfillingHistory = false
        restoreLiveParserState(liveSnapshot)
        // Atomic replacement: the Hub's historical state becomes EXACTLY the
        // window's derived set — retracting derivations (newer duplicates,
        // cross-page statuses) that this replay proved wrong. The anchor
        // marks the just-requested page so capacity trims never drop it.
        // The trim anchor is the REQUESTED before-seq: when the Hub bound is
        // smaller than the window, the retained interval stays adjacent to
        // the caller's anchor so its next cursor advances without a gap.
        let anchorSeq = lastRequestedBackfillAnchorSeq
        let products = reconcileHistoricalCorrelationClosures(historicalReplayProducts)
        hub.replaceHistoricalEvents(sessionID: record.sessionID,
                                    events: products,
                                    anchorSeq: anchorSeq)
        historicalReplayProducts = []
        return products
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

    private func retainClosure(key: String, event: AgentEvent) {
        if retainedHistoricalClosuresByKey[key] == nil {
            retainedHistoricalClosureKeyOrder.append(key)
            while retainedHistoricalClosureKeyOrder.count > retainedHistoricalClosureCapacity {
                let evicted = retainedHistoricalClosureKeyOrder.removeFirst()
                retainedHistoricalClosuresByKey.removeValue(forKey: evicted)
            }
        }
        retainedHistoricalClosuresByKey[key] = event
    }

    private func fileProvesClosureExists(afterLineOffset offset: Int,
                                         matching predicate: (String) -> Bool,
                                         terminatedBy terminator: ((String) -> Bool)? = nil) -> Bool {
        guard let transcriptURL,
              let handle = try? FileHandle(forReadingFrom: transcriptURL) else {
            return false
        }
        defer { try? handle.close() }
        guard offset >= 0, (try? handle.seek(toOffset: UInt64(offset))) != nil else {
            return false
        }
        var buffer = Data()
        var skippedOpenerLine = false
        func check(_ lineData: Data) -> Bool? {
            guard skippedOpenerLine else {
                skippedOpenerLine = true
                return nil
            }
            guard let line = String(data: lineData, encoding: .utf8) else {
                return nil
            }
            // Production recognizes a NEW local command before treating
            // content as stdout: the terminator is checked FIRST so a line
            // carrying both a command tag and parseable stdout ends the
            // previous search instead of closing it.
            if let terminator, terminator(line) {
                return false
            }
            if predicate(line) {
                return true
            }
            return nil
        }
        while true {
            guard let chunk = try? handle.read(upToCount: 64 * 1024), chunk.isEmpty == false else {
                break
            }
            buffer.append(chunk)
            while let newlineIndex = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let lineData = buffer.subdata(in: buffer.startIndex..<newlineIndex)
                buffer.removeSubrange(buffer.startIndex...newlineIndex)
                if let verdict = check(lineData) {
                    return verdict
                }
            }
        }
        // The transcript's LAST line may not have its newline yet: the
        // residual buffer is still a complete record for closure purposes.
        if buffer.isEmpty == false, let verdict = check(buffer) {
            return verdict
        }
        return false
    }

    // The probe mirrors the production parser's OUTER admission: a record
    // only counts when consume() itself would accept and derive from it —
    // correct outer type, user path, and this session's identity.
    private func probeAdmittedUserObject(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        if let sessionID = object["sessionId"] as? String, sessionID != record.sessionID {
            return nil
        }
        if let version = object["version"] as? String, !version.hasPrefix(claudeTranscriptMajorVersion) {
            return nil
        }
        guard (object["type"] as? String) == "user",
              object["uuid"] is String,
              let message = object["message"] as? [String: Any],
              message["role"] as? String == "user" else {
            return nil
        }
        return object
    }

    // Exact closure recognition: only a REAL tool_result whose tool_use_id
    // equals the prompt id, on a record the production parser would accept.
    private func lineProvesAskClosure(_ line: String, promptID: String) -> Bool {
        guard let object = probeAdmittedUserObject(line),
              let message = object["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]] else {
            return false
        }
        return content.contains { block in
            (block["type"] as? String) == "tool_result" && (block["tool_use_id"] as? String) == promptID
        }
    }

    // Exact context closure: production only treats STRING-content user
    // records as local command envelopes, and the summary must actually be
    // parseable by the production context-summary parser.
    private func lineProvesContextClosure(_ line: String) -> Bool {
        guard let object = probeAdmittedUserObject(line),
              let message = object["message"] as? [String: Any],
              let content = message["content"] as? String else {
            return false
        }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let stdout = Self.localCommandStdout(in: trimmed) else {
            return false
        }
        return Self.markdownForClaudeContext(stdout: stdout) != nil
    }

    // A later context COMMAND ends the previous command's closure search: a
    // summary belongs to the nearest preceding unmatched command.
    private func lineIsContextCommand(_ line: String) -> Bool {
        guard let object = probeAdmittedUserObject(line),
              let message = object["message"] as? [String: Any],
              let content = message["content"] as? String else {
            return false
        }
        return Self.localCommandName(in: content.trimmingCharacters(in: .whitespacesAndNewlines)) != nil
    }

    private func reconcileHistoricalCorrelationClosures(_ products: [AgentEvent]) -> [AgentEvent] {
        // 1. Record closures visible in THIS window, keyed by their SPECIFIC
        //    opener event (a later lifecycle reusing the same promptID must
        //    never inherit an old terminal).
        for event in products {
            if event.type == .interactivePromptResolved,
               let promptID = event.metadata?["prompt_id"] {
                let opener = products.last { candidate in
                    candidate.type == .interactivePrompt
                        && candidate.metadata?["prompt_id"] == promptID
                        && candidate.seq < event.seq
                }
                if let opener {
                    retainClosure(key: "ask:\(opener.eventID)", event: event)
                }
            }
            if event.metadata?["tidey_generated"] == "claude_context" {
                let opener = products.last { candidate in
                    candidate.metadata?["tidey_generated"] == "claude_context_command" && candidate.seq < event.seq
                }
                if let opener {
                    retainClosure(key: "context:\(opener.eventID)", event: event)
                }
            }
        }
        // 2. Re-add retained closures whose opener is in the window but whose
        //    closing event was evicted; when the bounded retention has lost
        //    the closure of a KNOWN-resolved opener, the opener is withdrawn
        //    (fail closed) instead of reviving.
        var reconciled = products
        var presentIDs = Set(products.map(\.eventID))
        var withdrawnOpenerIDs = Set<String>()
        for event in products {
            if event.type == .interactivePrompt,
               let promptID = event.metadata?["prompt_id"],
               products.contains(where: { $0.type == .interactivePromptResolved && $0.metadata?["prompt_id"] == promptID && $0.seq > event.seq }) == false {
                if let retained = retainedHistoricalClosuresByKey["ask:\(event.eventID)"] {
                    if presentIDs.insert(retained.eventID).inserted {
                        reconciled.append(retained)
                    }
                } else if let promptID = event.metadata?["prompt_id"],
                          let openerOffset = transcriptLineOffsetInCurrentSource(for: event.seq),
                          fileProvesClosureExists(afterLineOffset: openerOffset,
                                                  matching: { self.lineProvesAskClosure($0, promptID: promptID) }) {
                    withdrawnOpenerIDs.insert(event.eventID)
                }
            }
            if event.metadata?["tidey_generated"] == "claude_context_command",
               products.contains(where: { $0.metadata?["tidey_generated"] == "claude_context" && $0.seq > event.seq }) == false {
                if let retained = retainedHistoricalClosuresByKey["context:\(event.eventID)"] {
                    if presentIDs.insert(retained.eventID).inserted {
                        reconciled.append(retained)
                    }
                } else if let openerOffset = transcriptLineOffsetInCurrentSource(for: event.seq),
                          fileProvesClosureExists(afterLineOffset: openerOffset,
                                                  matching: { self.lineProvesContextClosure($0) },
                                                  terminatedBy: { self.lineIsContextCommand($0) }) {
                    withdrawnOpenerIDs.insert(event.eventID)
                }
            }
        }
        if withdrawnOpenerIDs.isEmpty == false {
            reconciled.removeAll { withdrawnOpenerIDs.contains($0.eventID) }
        }
        return reconciled.sorted { $0.seq < $1.seq }
    }

    // TEST-ONLY: overrides the fallback scan's search root (production
    // default is ~/.claude/projects). Lets tests exercise the fallback
    // path (and a reintroduced-fallback-bug mutation) against an isolated
    // temp directory instead of the user's real project history — mirrors
    // CodexTranscriptSession's sessionsDirectoryOverrideForTesting.
    private let projectsDirectoryOverride: URL?

    init(record: AgentSessionRegistryRecord,
         fileManager: FileManager = .default,
         hub: AgentEventHub,
         socketClient: TideyCommandSending? = nil,
         chatSubmitEchoRegistry: ChatSubmitEchoRegistry? = nil,
         historicalReplayWindowCapacity: Int = 4000,
         retainedHistoricalClosureCapacity: Int = 256,
         projectsDirectoryOverrideForTesting: URL? = nil) {
        self.historicalReplayWindowCapacity = max(1, historicalReplayWindowCapacity)
        self.retainedHistoricalClosureCapacity = max(1, retainedHistoricalClosureCapacity)
        self.record = record
        self.fileManager = fileManager
        self.hub = hub
        self.socketClient = socketClient
        self.chatSubmitEchoRegistry = chatSubmitEchoRegistry ?? ChatSubmitEchoRegistry()
        self.projectsDirectoryOverride = projectsDirectoryOverrideForTesting
        self.queue = DispatchQueue(label: "com.tidey.remote-bridge.claude-session.\(record.sessionID)")
    }

    func start() {
        guard !didPublishStart else {
            return
        }
        didPublishStart = true
        // New-generation ownership handoff (see CodexTranscriptSession.start
        // for the full rationale): this session object IS a new source
        // incarnation for its sessionID — reset Hub-side seen/live state and
        // workspace bindings SYNCHRONOUSLY, BEFORE returning to the caller
        // (the registry monitor), so a runtime syncer started immediately
        // afterward can never race behind this, and a reused eventID from a
        // registry monitor stop+recreate is never suppressed by the OLD
        // generation's seen set. Safe no-op for a genuinely fresh sessionID.
        //
        // The boundary's seq is minted from the Hub's OWN cross-generation
        // reservation (nextSyntheticSeq), NOT the fixed sentinel
        // transcriptSessionStartedSequence — this only seeds a readable/
        // unique eventID and a claimed seq to publish; it is NEVER trusted
        // as the final stored seq (see the Round 7G TOCTOU contract below).
        //
        // Round 7G P0 (TOCTOU fix, corrected contract): `maxObservedSeq`/
        // `transcriptSequenceBase` are set from `publish`'s RETURN VALUE
        // (the TRUE stored seq, post-rebase), never the pre-publish
        // reservation — the reservation is only used to make the eventID
        // readable and to seed the boundary event's claimed seq. `publish`
        // returns `nil` when the event was NOT genuinely stored (duplicate
        // eventID / suppressed), which is not proof of any seq — this fails
        // closed: it does NOT advance the base from the unstored
        // reservation, leaving `maxObservedSeq`/`transcriptSequenceBase` at
        // their prior (pre-start) values.
        hub.beginNewSourceEpoch(sessionID: record.sessionID)
        let reservedSeq = hub.nextSyntheticSeq(sessionID: record.sessionID)
        afterBoundaryReservationBeforePublishHook.fire()
        let publishedStartSeq = hub.publish(AgentEvent(eventID: "session-start:\(record.sessionID)",
                               seq: reservedSeq,
                               vendor: "claude",
                               workspaceID: record.workspaceID,
                               sessionID: record.sessionID,
                               timestamp: record.createdAt,
                               type: .sessionStarted,
                               role: nil,
                               text: nil,
                               name: nil,
                               input: nil,
                               output: nil,
                               toolCallID: nil,
                               metadata: baseMetadata(["cwd": record.cwd])))
        if let publishedStartSeq {
            maxObservedSeq = max(maxObservedSeq, publishedStartSeq)
        } else {
            BridgeLogger.server.error("claude session-start boundary marker was not stored; sequence base not advanced from unstored reservation session_id=\(self.record.sessionID, privacy: .public) reserved_seq=\(reservedSeq, privacy: .public)")
        }
        transcriptSequenceBase = maxObservedSeq
        // The resolver's FIRST attach attempt must ALSO complete before
        // start() returns (see CodexTranscriptSession.start for the full
        // lost-line race this closes) — a fresh object has nothing else
        // scheduled on `queue` yet, so this is deadlock-safe. A path that
        // doesn't resolve yet still returns promptly: resolveTranscriptIfPossible's
        // failure is quick and startResolver just arms its retry timer.
        queue.sync {
            startResolver()
        }
    }

    func update(record: AgentSessionRegistryRecord) {
        queue.async {
            self.stopOldTailerBeforeSourceSwitchIfNeeded(for: record)
            self.performUpdate(record: record)
        }
    }

    // Phase 1 of the two-phase, race-free workspace-migration transaction
    // (see AgentSessionRegistryMonitor / CodexTranscriptSession.prepareUpdate
    // for the full protocol this participates in). Claude's OWN sidebar
    // publication is the AskUserQuestion/permission interactive-prompt
    // lifecycle (publishInteractivePromptSidebarIfNeeded) — held here for
    // the same reason Codex's is: forced synchronous (queue.sync, draining
    // any already enqueued work first) so the monitor can prove this
    // session's transition to the new workspace happens strictly before it
    // sends the OLD workspace's departure cleanup, and nothing this session
    // says about the interactive-prompt lifecycle for the NEW workspace can
    // leak out before then either.
    func prepareUpdate(record: AgentSessionRegistryRecord) {
        queue.sync {
            // Stop/drain the OLD tailer under the OLD record — BEFORE the
            // hold is enabled — so a legitimate final A interactive-prompt
            // lifecycle message (e.g. an AskUserQuestion/permission
            // resolution already sitting in A's fd) is attributed to and
            // sent for workspace A immediately, normally — never buried in
            // B's held batches (see stopOldTailerBeforeSourceSwitchIfNeeded,
            // matching CodexTranscriptSession's equivalent fix).
            self.stopOldTailerBeforeSourceSwitchIfNeeded(for: record)
            self.isSidebarPublicationHeld = true
            self.heldSidebarMessageBatches = []
            self.performUpdate(record: record)
        }
    }

    // TEST-ONLY OBSERVATION SEAM — fires synchronously, ON this session's
    // own queue, inside stopOldTailerBeforeSourceSwitchIfNeeded, after a
    // genuine switch is confirmed but BEFORE tailer.stop() actually runs.
    // See CodexTranscriptSession's equivalent hook for why this makes an
    // append from inside the hook deterministic (no other file-event
    // callback can have consumed it first). No production caller.
    var beforeOldTailerStopForTesting: (() -> Void)?

    // TEST-ONLY: fires synchronously, immediately after a boundary/start seq
    // is RESERVED (hub.nextSyntheticSeq) but before it is PUBLISHED — see
    // CodexTranscriptSession's equivalent hook for the full rationale (this
    // is the exact window the Round 7G TOCTOU fix closes). `start()` runs
    // synchronously on the CALLER's thread while other call sites run on
    // this session's own queue — `TestHookBox` is lock-protected
    // unconditionally so both are race-free. No production caller.
    private let afterBoundaryReservationBeforePublishHook = TestHookBox()
    func setAfterBoundaryReservationBeforePublishHookForTesting(_ hook: (() -> Void)?) {
        afterBoundaryReservationBeforePublishHook.set(hook)
    }

    // TEST-ONLY: fires synchronously at the END of every
    // resolveTranscriptIfPossible() attempt — including the resolver
    // timer's own periodic retries — whether or not it attached anything.
    // See CodexTranscriptSession's equivalent hook for the full rationale.
    // No production caller.
    private let afterResolveAttemptHook = TestHookBox()
    func setAfterResolveAttemptHookForTesting(_ hook: (() -> Void)?) {
        afterResolveAttemptHook.set(hook)
    }

    // A genuine source-identity switch (a DIFFERENT explicit, canonical
    // transcript path) must stop/drain the OLD tailer under the OLD
    // record, BEFORE anything else (Hub binding switch, self.record
    // assignment, or the migration sidebar hold) changes. This checks only
    // the EXPLICIT registry transcriptPath field, not the resolver's own
    // fallback chain — Claude's resolver DOES still scan
    // ~/.claude/projects when no explicit path resolves, same as Codex has
    // process-tree/directory enumeration; the reason this check only looks
    // at the explicit field is that the REGISTRY's identity switch signal
    // is the explicit path itself, not resolver fallback behavior.
    // JSONLFileTailer.stop() drains any bytes already written to the fd
    // but not yet delivered; running that drain AFTER self.record already
    // flipped to B and the hold is already active would attribute (and
    // bury) a legitimate final A interactive-prompt message into B's held
    // batches instead of sending it immediately, normally, for A. A nil or
    // empty/whitespace path, an equivalent ~/./ spelling, or a pure
    // metadata addition that still resolves to the SAME file must never
    // trigger this.
    // SHARED between the pre-check (detectsSourceSwitch) and performUpdate's
    // own epoch-reset decision — both must treat an explicit transcriptPath
    // identically, or the two can drift: one says "not a switch" (skips
    // the drain) while the other still resets the epoch on record=B,
    // reproducing the exact wrong-order bug this fix exists to close. A
    // nil or whitespace-only path is never explicit.
    private static func explicitTranscriptPath(from record: AgentSessionRegistryRecord) -> String? {
        guard let path = record.transcriptPath else {
            return nil
        }
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : path
    }

    private func detectsSourceSwitch(for candidateRecord: AgentSessionRegistryRecord) -> Bool {
        guard let currentURL = transcriptURL,
              let newPath = Self.explicitTranscriptPath(from: candidateRecord) else {
            return false
        }
        return Self.canonicalTranscriptPath(newPath) != Self.canonicalTranscriptPath(currentURL.path)
    }

    private func stopOldTailerBeforeSourceSwitchIfNeeded(for candidateRecord: AgentSessionRegistryRecord) {
        guard detectsSourceSwitch(for: candidateRecord) else {
            return
        }
        beforeOldTailerStopForTesting?()
        tailer?.stop()
        tailer = nil
    }

    // Phase 2: releases the hold and flushes EVERY buffered interactive-
    // prompt message batch, in the SAME order they were produced — never
    // coalesced/dropped, so an AskUserQuestion/permission lifecycle message
    // produced during the held window is still said in full, just delayed.
    func finishUpdate() {
        queue.sync {
            self.isSidebarPublicationHeld = false
            let batches = self.heldSidebarMessageBatches
            self.heldSidebarMessageBatches = []
            for batch in batches {
                self.sendInteractivePromptSidebarMessagesNow(batch)
            }
        }
    }

    private func performUpdate(record: AgentSessionRegistryRecord) {
        let previousRecord = self.record
        let didMigrateWorkspace = previousRecord.workspaceID != record.workspaceID
        let didMigratePanel = previousRecord.panelID != record.panelID
        if didMigrateWorkspace || didMigratePanel {
            self.hub.migrateSession(sessionID: previousRecord.sessionID,
                                    toWorkspaceID: record.workspaceID,
                                    panelID: record.panelID)
        }
        self.record = record
        // A registry update pointing at a DIFFERENT transcript is a full
        // source identity switch — even while the old file still exists.
        // Identity is the STANDARDIZED resolved path: a nil path later
        // filled in with the file we already resolved is a pure metadata
        // update, never a reset.
        if let currentURL = self.transcriptURL,
           let newPath = Self.explicitTranscriptPath(from: record),
           Self.canonicalTranscriptPath(newPath) != Self.canonicalTranscriptPath(currentURL.path) {
            self.beginNewSourceEpoch()
            // Round 7G P0: a SINGLE `resolveTranscriptIfPossible()` call
            // only ever tries once — if the NEW explicit path does not
            // exist YET (a genuinely delayed new source), this session
            // would then wait forever with no retry, matching Codex's
            // `switchTranscriptIdentity` (which arms its own resolver timer
            // on every source switch, not just on tailer invalidation).
            // `startResolver()` tries once immediately and, if still
            // unresolved, arms the periodic retry timer exactly like
            // `handleTailerInvalidation` already does for a same-path
            // delete-and-recreate.
            if self.resolverTimer == nil {
                self.startResolver()
            } else {
                self.resolveTranscriptIfPossible()
            }
            return
        }
        if self.transcriptURL == nil {
            self.resolveTranscriptIfPossible()
        }
    }

    // Everything that could let the OLD source suppress or leak into the new
    // one is revoked: the old tailer (no late injection), the historical
    // window/retention, the Hub's stored products AND idempotency sets (a
    // reused eventID must be re-acceptable), and the parser correlation /
    // notification state. Seq high-water and reservations survive so
    // subscriber cursors stay monotonic.
    // The SAME canonicalization the resolver uses: tilde expansion +
    // standardized file URL — two resolver-equivalent spellings never count
    // as different sources.
    static func canonicalTranscriptPath(_ path: String) -> String {
        URL(fileURLWithPath: NSString(string: path).expandingTildeInPath).standardizedFileURL.path
    }

    private func beginNewSourceEpoch() {
        tailer?.stop()
        tailer = nil
        historicalRawLines = []
        collectedBackfillPage = []
        historicalReplayProducts = []
        lastBackfillPageOffsets = nil
        lastRequestedBackfillAnchorSeq = nil
        retainedHistoricalClosuresByKey = [:]
        retainedHistoricalClosureKeyOrder = []
        activeAskUserQuestionPromptIDByToolCallID = [:]
        pendingLocalCommand = nil
        unsupportedVersions = []
        promptNotificationDeduper.clearSession(record.sessionID)
        hub.beginNewSourceEpoch(sessionID: record.sessionID)
        hub.replaceHistoricalEvents(sessionID: record.sessionID, events: [], anchorSeq: nil)
        // Round 7D P0: a store-only reset does not, by itself, notify an
        // ALREADY-SUBSCRIBED client that was mid-turn on the OLD source —
        // its local reducer keeps showing Working until some new clearing
        // event arrives. Both iOS ChatTranscriptReducer and ChatResponseState
        // treat a live `.sessionStarted` as an unconditional Working/
        // expecting-response reset for the CURRENT session, so it is
        // LIVE-DELIVERED here as the new source's boundary marker — not
        // merely stored history. Mirrors CodexTranscriptSession.beginNewSourceEpoch
        // and this file's own `start()` first-boundary precedent above.
        //
        // Round 7G P0 (TOCTOU fix, corrected contract): `nextSyntheticSeq`
        // only RESERVES a seq — between that reservation and the `publish`
        // call below, a different producer could publish a higher seq on
        // the SAME session, which would silently rebase THIS event above
        // the reservation this session already trusted. `publish` itself is
        // the ONE atomic critical section that resolves the FINAL stored
        // seq (it applies the exact same rebase-on-collision the
        // reservation was trying to avoid), so `maxObservedSeq`/
        // `transcriptSequenceBase` are set from its RETURN VALUE, never the
        // earlier reservation — the reservation is used only to make the
        // eventID readable/unique, never trusted as the actual final seq.
        // `publish` now returns `nil` when the event was NOT genuinely
        // stored (duplicate eventID / suppressed) — that is not proof of
        // any seq, so this fails closed: it does NOT advance
        // `maxObservedSeq`/`transcriptSequenceBase` from the unstored
        // reservation, leaving them at whatever this session already knew.
        let reservedSeq = hub.nextSyntheticSeq(sessionID: record.sessionID)
        afterBoundaryReservationBeforePublishHook.fire()
        let publishedBoundarySeq = hub.publish(AgentEvent(eventID: "source-epoch:\(record.sessionID):\(reservedSeq)",
                                                       seq: reservedSeq,
                                                       vendor: "claude",
                                                       workspaceID: record.workspaceID,
                                                       sessionID: record.sessionID,
                                                       timestamp: ISO8601DateFormatter().string(from: Date()),
                                                       type: .sessionStarted,
                                                       role: nil,
                                                       text: nil,
                                                       name: nil,
                                                       input: nil,
                                                       output: nil,
                                                       toolCallID: nil,
                                                       metadata: baseMetadata(["cwd": record.cwd])))
        if let publishedBoundarySeq {
            maxObservedSeq = max(maxObservedSeq, publishedBoundarySeq)
        } else {
            BridgeLogger.server.error("claude source epoch boundary marker was not stored; epoch base not advanced from unstored reservation session_id=\(self.record.sessionID, privacy: .public) reserved_seq=\(reservedSeq, privacy: .public)")
        }
        // New-source file offsets restart at 0: rebase every future emitted
        // seq above everything this session has already published,
        // INCLUDING the boundary marker just published above (using its
        // TRUE stored seq, not the pre-publish reservation, and never the
        // reservation itself if the marker failed to store).
        transcriptSequenceBase = maxObservedSeq
        transcriptURL = nil
    }

    func backfill(beforeSeq: Int, limit: Int) -> Bool {
        queue.sync {
            if tailer == nil {
                resolveTranscriptIfPossible()
            }
            guard let tailer else {
                return false
            }
            guard let beforeOffset = transcriptLineOffsetInCurrentSource(for: beforeSeq),
                  beforeOffset > 0 else {
                return false
            }
            // The requested anchor is honored exactly; when the page derives
            // no event visible below the anchor (so the client's oldest_seq
            // cursor could never advance), keep reading deeper within this
            // same transaction until progress is visible or the file starts.
            // A read never exceeds the raw window capacity: reading more and
            // then evicting would skip lines before their FIRST parse. The
            // caller pages onward from the returned oldest_seq instead.
            let effectiveLimit = min(limit, historicalReplayWindowCapacity)
            lastRequestedBackfillAnchorSeq = beforeSeq
            var pageAnchorOffset = beforeOffset
            var loadedAny = false
            tailer.resetBackfillObservationForTesting()
            while true {
                isCollectingBackfillPage = true
                collectedBackfillPage = []
                let loaded = (try? tailer.backfill(beforeOffset: pageAnchorOffset, limit: effectiveLimit)) ?? false
                isCollectingBackfillPage = false
                guard loaded, collectedBackfillPage.isEmpty == false else {
                    return loadedAny
                }
                loadedAny = true
                let pageMinOffset = collectedBackfillPage.map(\.offset).min() ?? pageAnchorOffset
                mergeHistoricalPage(collectedBackfillPage)
                collectedBackfillPage = []
                let products = replayHistoricalWindow()
                if products.contains(where: { $0.seq < beforeSeq }) || pageMinOffset <= 0 {
                    return true
                }
                pageAnchorOffset = pageMinOffset
            }
        }
    }

    func stop() {
        queue.sync {
            resolverTimer?.cancel()
            resolverTimer = nil
            tailer?.stop()
            tailer = nil
            if !didPublishEnd {
                didPublishEnd = true
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
        resolveTranscriptIfPossible()
        if tailer != nil {
            return
        }

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .seconds(1), repeating: .seconds(1))
        timer.setEventHandler { [weak self] in
            self?.resolveTranscriptIfPossible()
        }
        timer.resume()
        resolverTimer = timer
    }

    private func resolveTranscriptIfPossible() {
        defer { afterResolveAttemptHook.fire() }
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
                                         if self.isCollectingBackfillPage {
                                             self.collectedBackfillPage.append((offset: offset, line: line))
                                             return
                                         }
                                         self.consume(line: line, lineOffset: offset)
                                     },
                                     invalidationHandler: { [weak self] in
                                         self?.handleTailerInvalidation()
                                     })
        do {
            try tailer.start()
            self.tailer = tailer
            self.transcriptURL = transcriptURL
            resolverTimer?.cancel()
            resolverTimer = nil
        } catch {
            self.transcriptURL = nil
        }
    }

    private func handleTailerInvalidation() {
        // The transcript source is gone: a delete-and-recreate at the SAME
        // path is a new source identity exactly like a registry path change —
        // the FULL epoch reset applies (history, Hub live/seen, parser
        // correlation, notification state), not a historical-only clear.
        beginNewSourceEpoch()
        if resolverTimer == nil {
            startResolver()
        }
    }

    private func resolveTranscriptURL() -> URL? {
        // Round 7G P0: an EXPLICIT transcript path is EXCLUSIVE and has NO
        // fallback — if it does not exist YET (a genuine new source that
        // has not been created on disk), this must wait for exactly that
        // path, never scan `.claude/projects` for a DIFFERENT file sharing
        // the session's filename. Falling back here could re-attach a
        // REVOKED old source (the same sessionID.jsonl left behind under a
        // stale cwd) to the NEW epoch — the fallback scan below is only
        // ever appropriate when the record carries no explicit path at all.
        if let explicitPath = Self.explicitTranscriptPath(from: record) {
            let url = URL(fileURLWithPath: NSString(string: explicitPath).expandingTildeInPath)
            return fileManager.fileExists(atPath: url.path) ? url : nil
        }

        let projectsDirectory = projectsDirectoryOverride ?? fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)
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
            return
        }

        guard let sessionID = (object["sessionId"] as? String) ?? Optional(record.sessionID),
              sessionID == record.sessionID else {
            return
        }
        let timestamp = (object["timestamp"] as? String) ?? ISO8601DateFormatter().string(from: Date())
        let version = object["version"] as? String
        if let version, !version.hasPrefix(claudeTranscriptMajorVersion) {
            // EVERY unsupported record is rejected; only the status
            // notification is deduped — a second same-version record must
            // not silently continue parsing.
            if !unsupportedVersions.contains(version) {
                unsupportedVersions.insert(version)
                publishFileBacked(kind: .status,
                                  lineOffset: lineOffset,
                                  ordinal: 0,
                                  eventID: "status:\(record.sessionID):\(lineOffset):unsupported-version:\(version)",
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
        default:
            break
        }
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
                if name == "AskUserQuestion",
                   let prompt = Self.askUserQuestionPrompt(from: block, uuid: uuid, index: index) {
                    if let toolCallID {
                        activeAskUserQuestionPromptIDByToolCallID[toolCallID] = prompt.promptID
                    }
                    publishFileBacked(kind: .interactivePrompt,
                                      lineOffset: lineOffset,
                                      ordinal: ordinal,
                                      eventID: "\(uuid):ask-user-question:\(prompt.promptID)",
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
            if consumeLocalCommandEnvelope(trimmed, uuid: uuid, timestamp: timestamp, lineOffset: lineOffset) {
                return
            }
            if shouldPublishUserMessage(trimmed) {
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
                if let toolCallID,
                   let promptID = activeAskUserQuestionPromptIDByToolCallID.removeValue(forKey: toolCallID) {
                    publishFileBacked(kind: .interactivePromptResolved,
                                      lineOffset: lineOffset,
                                      ordinal: ordinal,
                                      eventID: "\(uuid):ask-user-question-resolved:\(promptID)",
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
                                        "reason": "tool_result",
                                      ],
                                      payload: .object([
                                        "prompt_id": .string(promptID),
                                        "reason": .string("tool_result"),
                                      ]))
                    ordinal += 1
                }
            } else if blockType == "text" {
                let text = Self.compactString(block["text"])
                guard shouldPublishUserMessage(text) else { continue }
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
        guard command?.name == "/context",
              let markdown = Self.markdownForClaudeContext(stdout: stdout) else {
            return true
        }

        publishFileBacked(kind: .assistantMessage,
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
                                   payload: JSONValue? = nil) {
        let seq = transcriptSequenceBase + transcriptEventSequence(lineOffset: lineOffset, ordinal: ordinal)
        maxObservedSeq = max(maxObservedSeq, seq)
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
        if isBackfillingHistory {
            // Historical replay is a transaction: products are collected and
            // applied to the Hub as one atomic replacement afterwards.
            historicalReplayProducts.append(event)
            return
        }
        hub.publish(event)
        publishInteractivePromptSidebarIfNeeded(event)
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
        maxObservedSeq = max(maxObservedSeq, seq)
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
        if isBackfillingHistory {
            // Historical replay is a transaction: products are collected and
            // applied to the Hub as one atomic replacement afterwards.
            historicalReplayProducts.append(event)
            return
        }
        hub.publish(event)
        publishInteractivePromptSidebarIfNeeded(event)
    }

    // THE production interactive-prompt seam: both normal publish paths
    // (publishFileBacked / publishSynthetic) route every constructed event
    // through here. Internal (not private) so tests can inject synthetic
    // unknown/duplicate terminals through the exact caller production uses —
    // the ResolveOutcome guard below is what they lock.
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
            // Shared outcome contract with the Codex path: only a terminal
            // that ACTUALLY ended the currently notified lifecycle may send
            // running; unknown/duplicate/stale terminals are zero sidebar
            // side effects.
            guard promptNotificationDeduper.markResolved(event, sessionID: record.sessionID) == .clearedNotified else {
                return
            }
        default:
            return
        }

        let messages = AgentInteractivePromptSidebarMessages.messages(for: event,
                                                                      workspaceID: event.workspaceID)
        guard !messages.isEmpty else {
            return
        }
        // Held during a prepared workspace-migration transaction (see
        // isSidebarPublicationHeld) — BUFFER this exact batch, in order;
        // finishUpdate() flushes every buffered batch once released. This
        // dedup bookkeeping above still ran normally either way, so the
        // notified/resolved lifecycle state stays accurate even while held.
        guard isSidebarPublicationHeld == false else {
            heldSidebarMessageBatches.append(messages)
            return
        }
        sendInteractivePromptSidebarMessagesNow(messages)
    }

    private func sendInteractivePromptSidebarMessagesNow(_ messages: [String]) {
        guard let socketClient else {
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
        // Backfill is storage-only: history must NOT consume the live submit
        // echo registry — the true live echo still needs its correlation.
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
