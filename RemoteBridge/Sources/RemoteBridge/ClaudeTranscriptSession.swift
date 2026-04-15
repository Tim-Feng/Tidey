import Darwin
import Foundation

private let claudeTranscriptMajorVersion = "2."

protocol AgentTranscriptSession: AnyObject {
    func start()
    func update(record: AgentSessionRegistryRecord)
    func backfill(beforeSeq: Int, limit: Int) -> Bool
    func stop()
}

struct AgentSessionRegistryRecord: Decodable, Sendable {
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
}

struct ActiveAgentSessionSnapshot: Sendable {
    let vendor: String
    let workspaceID: String
    let sessionID: String
    let panelID: String?
}

struct AgentPanelProcessSnapshot: Sendable {
    let workspaceID: String
    let panelID: String
    let effectiveShellPID: Int32?
}

final class AgentSessionRegistryMonitor {
    typealias ParentPIDLookup = @Sendable (Int32) -> Int32?
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

    private let paths: BridgePaths
    private let fileManager: FileManager
    private let hub: AgentEventHub
    private let tmuxResolver: TmuxStateResolver
    private let parentPIDLookup: ParentPIDLookup
    private let queue = DispatchQueue(label: "com.tidey.remote-bridge.agent-registry")
    private var timer: DispatchSourceTimer?
    private var watchers = [String: DispatchSourceFileSystemObject]()
    private var watcherFDs = [String: Int32]()
    private var sessions = [String: AgentTranscriptSession]()
    private var activeRecords = [String: AgentSessionRegistryRecord]()
    private var livePanelsByWorkspace = [String: [AgentPanelProcessSnapshot]]()
    private var scanScheduled = false

    init(paths: BridgePaths = BridgePaths(),
         fileManager: FileManager = .default,
         hub: AgentEventHub,
         tmuxResolver: TmuxStateResolver = TmuxStateResolver(),
         parentPIDLookup: @escaping ParentPIDLookup = AgentSessionRegistryMonitor.liveParentPIDLookup) {
        self.paths = paths
        self.fileManager = fileManager
        self.hub = hub
        self.tmuxResolver = tmuxResolver
        self.parentPIDLookup = parentPIDLookup
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
                               effectiveShellPID: Int32?) -> ActiveAgentSessionSnapshot? {
        queue.sync {
            let panel = AgentPanelProcessSnapshot(workspaceID: workspaceID,
                                                 panelID: panelID,
                                                 effectiveShellPID: effectiveShellPID)
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
        let records = AgentVendorRegistry.all.flatMap { vendor in
            loadRecords(at: paths.agentSessionsDirectory(for: vendor.registryDirectoryName),
                        vendor: vendor.id)
        }
        syncRecords(records)
        activeRecords = Dictionary(uniqueKeysWithValues: records.map { ($0.sessionID, $0) })
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
        BridgeLogger.server.info("agent panel match start workspace_id=\(panel.workspaceID, privacy: .public) panel_id=\(panel.panelID, privacy: .public) effective_shell_pid=\(panel.effectiveShellPID.map(String.init) ?? "-", privacy: .public)")
        if let direct = activeRecords.values
            .first(where: { $0.workspaceID == panel.workspaceID && $0.panelID == panel.panelID }) {
            BridgeLogger.server.info("agent panel direct match session_id=\(direct.sessionID, privacy: .public) vendor=\(direct.vendor, privacy: .public)")
            return ActiveAgentSessionSnapshot(vendor: direct.vendor,
                                              workspaceID: panel.workspaceID,
                                              sessionID: direct.sessionID,
                                              panelID: panel.panelID)
        }

        guard let effectiveShellPID = panel.effectiveShellPID, effectiveShellPID > 0 else {
            BridgeLogger.server.info("agent panel no direct match and effective_shell_pid unavailable workspace_id=\(panel.workspaceID, privacy: .public) panel_id=\(panel.panelID, privacy: .public)")
            return nil
        }

        BridgeLogger.server.info("agent panel trying tmux match effective_shell_pid=\(effectiveShellPID, privacy: .public) candidate_records=\(self.activeRecords.count, privacy: .public)")
        let tmuxCandidates = self.activeRecords.values
            .filter { record in
                guard let paneID = record.tmuxPaneID,
                      !paneID.isEmpty,
                      let socketPath = record.tmuxSocketPath,
                      !socketPath.isEmpty else {
                    return false
                }
                BridgeLogger.server.info("agent panel tmux candidate session_id=\(record.sessionID, privacy: .public) pane_id=\(paneID, privacy: .public) socket=\(socketPath, privacy: .public)")
                if let clientPIDs = tmuxResolver.clientPIDs(forPaneID: paneID, socketPath: socketPath) {
                    BridgeLogger.server.info("agent panel tmux candidate session_id=\(record.sessionID, privacy: .public) pane_id=\(paneID, privacy: .public) client_pids=\(String(describing: clientPIDs), privacy: .public)")
                    return clientPIDs.contains { clientPID in
                        let result = processIsDescendantOrSelf(of: effectiveShellPID, candidate: clientPID)
                        BridgeLogger.server.info("agent panel ancestry candidate_pid=\(clientPID, privacy: .public) ancestor_pid=\(effectiveShellPID, privacy: .public) result=\(result, privacy: .public)")
                        return result
                    }
                }
                BridgeLogger.server.info("agent panel tmux candidate session_id=\(record.sessionID, privacy: .public) pane_id=\(paneID, privacy: .public) client_pids=nil")
                return false
            }
            .sorted(by: Self.isRecordPreferred(_:_:))

        guard let match = tmuxCandidates.first else {
            BridgeLogger.server.info("agent panel no tmux match workspace_id=\(panel.workspaceID, privacy: .public) panel_id=\(panel.panelID, privacy: .public)")
            return nil
        }

        BridgeLogger.server.info("agent panel matched via tmux vendor=\(match.vendor, privacy: .public) session_id=\(match.sessionID, privacy: .public)")
        return ActiveAgentSessionSnapshot(vendor: match.vendor,
                                          workspaceID: panel.workspaceID,
                                          sessionID: match.sessionID,
                                          panelID: panel.panelID)
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
                                                       hub: hub)
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

    private var record: AgentSessionRegistryRecord
    private var resolverTimer: DispatchSourceTimer?
    private var tailer: JSONLFileTailer?
    private var transcriptURL: URL?
    private var maxObservedSeq = transcriptSessionStartedSequence
    private var didPublishStart = false
    private var didPublishEnd = false
    private var unsupportedVersions = Set<String>()
    private var isBackfillingHistory = false

    init(record: AgentSessionRegistryRecord,
         fileManager: FileManager = .default,
         hub: AgentEventHub) {
        self.record = record
        self.fileManager = fileManager
        self.hub = hub
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
            if didMigrateWorkspace || didMigratePanel {
                let seq = self.nextSyntheticSequence()
                self.publishSynthetic(kind: .sessionStarted,
                                      seq: seq,
                                      eventID: "session-start:\(record.sessionID):migrated:\(seq)",
                                      timestamp: ISO8601DateFormatter().string(from: Date()),
                                      role: nil,
                                      text: nil,
                                      name: nil,
                                      input: nil,
                                      output: nil,
                                      toolCallID: nil,
                                      metadata: self.baseMetadata(["cwd": record.cwd]))
            }
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
            if !trimmed.isEmpty {
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
                guard !text.isEmpty else { continue }
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
                               metadata: baseMetadata(metadata))
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

    private static func compactString(_ value: Any?) -> String {
        guard let string = value as? String else {
            return ""
        }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= 8000 {
            return trimmed
        }
        return String(trimmed.prefix(8000)) + "…"
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
              var string = String(data: data, encoding: .utf8) else {
            return nil
        }
        if string.count > 8000 {
            string = String(string.prefix(8000)) + "…"
        }
        return string
    }
}
