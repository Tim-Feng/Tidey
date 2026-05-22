import Darwin
import Foundation

private let claudeTranscriptMajorVersion = "2."

protocol AgentTranscriptSession: AnyObject {
    func start()
    func update(record: AgentSessionRegistryRecord)
    func backfill(beforeSeq: Int, limit: Int) -> Bool
    func stop()
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
         tmuxSocketPath: String? = nil) {
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
    }
}

struct ActiveAgentSessionSnapshot: Sendable {
    let vendor: String
    let workspaceID: String
    let sessionID: String
    let panelID: String?
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
    private let queue = DispatchQueue(label: "com.tidey.remote-bridge.agent-registry")
    private var timer: DispatchSourceTimer?
    private var watchers = [String: DispatchSourceFileSystemObject]()
    private var watcherFDs = [String: Int32]()
    private var sessions = [String: AgentTranscriptSession]()
    private var activeRecords = [String: AgentSessionRegistryRecord]()
    private var resolvedPanelBindings = [String: ResolvedPanelBinding]()
    private var livePanelsByWorkspace = [String: [AgentPanelProcessSnapshot]]()
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
         codexRolloutBySessionIDLookup: @escaping CodexRolloutBySessionIDLookup = AgentSessionRegistryMonitor.liveCodexRolloutBySessionIDLookup) {
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
    }

    func start() throws {
        try paths.ensureSupportDirectoriesExist(fileManager: fileManager)
        scanRegistry()
        startWatchers()

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .seconds(2), repeating: .seconds(2))
        timer.setEventHandler { [weak self] in
            self?.scanRegistry()
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
                                           panelID: $0.panelID)
            }
        }
    }

    func activeRecord(sessionID: String) -> AgentSessionRegistryRecord? {
        queue.sync {
            activeRecords[sessionID]
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
        tmuxResolver.invalidate()
        scheduleScan()

        if events.contains(.rename) || events.contains(.delete) || events.contains(.revoke) {
            try? paths.ensureSupportDirectoriesExist(fileManager: fileManager)
            let directory = paths.agentSessionsDirectory(for: vendor)
            startWatcher(for: vendor, directory: directory)
        }
    }

    private func scheduleScan() {
        guard !scanScheduled else {
            return
        }
        scanScheduled = true
        queue.asyncAfter(deadline: .now() + .milliseconds(100)) { [weak self] in
            guard let self else {
                return
            }
            self.scanScheduled = false
            self.scanRegistry()
        }
    }

    private func scanRegistry() {
        let sourceRecords = AgentVendorRegistry.all.flatMap { vendor in
            loadRecords(at: paths.agentSessionsDirectory(for: vendor.registryDirectoryName),
                        vendor: vendor.id)
        }
        let activeSessionIDs = Set(sourceRecords.map(\.sessionID))
        resolvedPanelBindings = resolvedPanelBindings.filter { activeSessionIDs.contains($0.key) }
        let effectiveRecords = sourceRecords
            .map(recordWithPaneIdentityIfAvailable(_:))
            .map(effectiveRecord(for:))
        syncRecords(effectiveRecords)
        activeRecords = Dictionary(uniqueKeysWithValues: effectiveRecords.map { ($0.sessionID, $0) })
        for record in effectiveRecords where resolvedPanelBindings[record.sessionID] != nil {
            applyResolvedBinding(sessionID: record.sessionID,
                                 workspaceID: record.workspaceID,
                                 panelID: record.panelID)
        }
    }

    private func recordWithPaneIdentityIfAvailable(_ record: AgentSessionRegistryRecord) -> AgentSessionRegistryRecord {
        guard let paneID = record.tmuxPaneID,
              !paneID.isEmpty,
              let socketPath = record.tmuxSocketPath,
              !socketPath.isEmpty,
              let identity = tmuxResolver.paneIdentity(forPaneID: paneID, socketPath: socketPath),
              identity.workspaceID != record.workspaceID || identity.panelID != record.panelID else {
            return record
        }

        BridgeLogger.server.info("agent registry corrected from tmux pane identity session_id=\(record.sessionID, privacy: .public) vendor=\(record.vendor, privacy: .public) pane_id=\(paneID, privacy: .public) old_workspace_id=\(record.workspaceID, privacy: .public) old_panel_id=\(record.panelID ?? "-", privacy: .public) workspace_id=\(identity.workspaceID, privacy: .public) panel_id=\(identity.panelID, privacy: .public)")
        return AgentSessionRegistryRecord(version: record.version,
                                          vendor: record.vendor,
                                          workspaceID: identity.workspaceID,
                                          sessionID: record.sessionID,
                                          panelID: identity.panelID,
                                          pid: record.pid,
                                          cwd: record.cwd,
                                          createdAt: record.createdAt,
                                          transcriptPath: record.transcriptPath,
                                          tmuxPaneID: record.tmuxPaneID,
                                          tmuxSocketPath: record.tmuxSocketPath)
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
                                           panelID: $0.panelID)
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
           directMatches.contains(where: { $0.vendor == "codex" && $0.sessionID != liveCodexProcessRecord.sessionID }) {
            applyResolvedBinding(sessionID: liveCodexProcessRecord.sessionID,
                                 workspaceID: panel.workspaceID,
                                 panelID: panel.panelID)
            BridgeLogger.server.info("agent panel corrected codex session from live process workspace_id=\(panel.workspaceID, privacy: .public) panel_id=\(panel.panelID, privacy: .public) session_id=\(liveCodexProcessRecord.sessionID, privacy: .public)")
            return ActiveAgentSessionSnapshot(vendor: liveCodexProcessRecord.vendor,
                                              workspaceID: panel.workspaceID,
                                              sessionID: liveCodexProcessRecord.sessionID,
                                              panelID: panel.panelID)
        }

        if let direct = directMatches.first {
            applyResolvedBinding(sessionID: direct.sessionID,
                                 workspaceID: panel.workspaceID,
                                 panelID: panel.panelID)
            BridgeLogger.server.debug("agent panel direct match session_id=\(direct.sessionID, privacy: .public) vendor=\(direct.vendor, privacy: .public)")
            return ActiveAgentSessionSnapshot(vendor: direct.vendor,
                                              workspaceID: panel.workspaceID,
                                              sessionID: direct.sessionID,
                                              panelID: panel.panelID)
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
                                              panelID: panel.panelID)
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
                                                  panelID: panel.panelID)
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
                                          panelID: panel.panelID)
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
                                          tmuxSocketPath: record.tmuxSocketPath)
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

    private func loadRecords(at directory: URL, vendor: String) -> [AgentSessionRegistryRecord] {
        guard let enumerator = fileManager.enumerator(at: directory,
                                                      includingPropertiesForKeys: [.isRegularFileKey],
                                                      options: [.skipsHiddenFiles]) else {
            return []
        }

        var records = [AgentSessionRegistryRecord]()
        for case let url as URL in enumerator {
            guard url.pathExtension == "json",
                  let data = try? Data(contentsOf: url),
                  let record = try? JSONDecoder().decode(AgentSessionRegistryRecord.self, from: data),
                  record.version == 1,
                  record.vendor == vendor else {
                continue
            }
            if processExists(record.pid) {
                records.append(record)
            } else {
                try? fileManager.removeItem(at: url)
            }
        }
        return records
    }

    private func processExists(_ pid: Int32) -> Bool {
        guard pid > 0 else {
            return false
        }
        return kill(pid, 0) == 0 || errno == EPERM
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

    func backfill(beforeOffset: Int, limit: Int) throws -> Bool {
        guard beforeOffset > 0, limit > 0 else {
            return false
        }
        guard !reachedStartOfFile else {
            return false
        }

        let targetOffset = min(beforeOffset, earliestLoadedOffset ?? beforeOffset)
        let lines = try JSONLFileReader.readBefore(fileURL: fileURL,
                                                   beforeOffset: targetOffset,
                                                   limit: limit)
        guard !lines.isEmpty else {
            reachedStartOfFile = true
            return false
        }

        for (offset, line) in lines {
            lineHandler(offset, line)
        }
        earliestLoadedOffset = lines.first?.offset
        reachedStartOfFile = (lines.first?.offset ?? 0) == 0
        return true
    }

    func stop() {
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
    private let chatSubmitEchoRegistry: ChatSubmitEchoRegistry

    private var record: AgentSessionRegistryRecord
    private var resolverTimer: DispatchSourceTimer?
    private var tailer: JSONLFileTailer?
    private var transcriptURL: URL?
    private var maxObservedSeq = transcriptSessionStartedSequence
    private var didPublishStart = false
    private var didPublishEnd = false
    private var unsupportedVersions = Set<String>()
    private var isBackfillingHistory = false
    private var pendingLocalCommand: ClaudeLocalCommand?

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
         chatSubmitEchoRegistry: ChatSubmitEchoRegistry? = nil) {
        self.record = record
        self.fileManager = fileManager
        self.hub = hub
        self.chatSubmitEchoRegistry = chatSubmitEchoRegistry ?? ChatSubmitEchoRegistry()
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
            }
            self.record = record
            if self.transcriptURL == nil {
                self.resolveTranscriptIfPossible()
            }
        }
    }

    func backfill(beforeSeq: Int, limit: Int) -> Bool {
        queue.sync {
            if tailer == nil {
                resolveTranscriptIfPossible()
            }
            guard let tailer else {
                return false
            }
            let beforeOffset = transcriptLineOffset(for: beforeSeq)
            guard beforeOffset > 0 else {
                return false
            }
            isBackfillingHistory = true
            defer { isBackfillingHistory = false }
            return (try? tailer.backfill(beforeOffset: beforeOffset, limit: limit)) ?? false
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
        guard tailer == nil else {
            return
        }
        guard let transcriptURL = resolveTranscriptURL() else {
            return
        }

        let tailer = JSONLFileTailer(fileURL: transcriptURL,
                                     queue: queue,
                                     lineHandler: { [weak self] offset, line in
                                         self?.consume(line: line, lineOffset: offset)
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
        transcriptURL = nil
        tailer = nil
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
            return
        }

        guard let sessionID = (object["sessionId"] as? String) ?? Optional(record.sessionID),
              sessionID == record.sessionID else {
            return
        }
        let timestamp = (object["timestamp"] as? String) ?? ISO8601DateFormatter().string(from: Date())
        let version = object["version"] as? String
        if let version,
           !version.hasPrefix(claudeTranscriptMajorVersion),
           !unsupportedVersions.contains(version) {
            unsupportedVersions.insert(version)
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

            default:
                continue
            }
        }
    }

    private func consumeUser(object: [String: Any], timestamp: String, lineOffset: Int) {
        guard let uuid = object["uuid"] as? String,
              let message = object["message"] as? [String: Any] else {
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
                                   metadata: [String: String]?) {
        let seq = transcriptEventSequence(lineOffset: lineOffset, ordinal: ordinal)
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
                               metadata: baseMetadata(resolvedMetadata))
        hub.publish(event, deliverToSubscribers: !isBackfillingHistory)
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
        hub.publish(event, deliverToSubscribers: !isBackfillingHistory)
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
        guard kind == .userMessage,
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
