import Darwin
import Foundation

private let claudeTranscriptMajorVersion = "2."

protocol AgentTranscriptSession: AnyObject {
    func start()
    func update(record: AgentSessionRegistryRecord)
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
    }
}

struct ActiveAgentSessionSnapshot: Sendable {
    let vendor: String
    let workspaceID: String
    let sessionID: String
    let panelID: String?
}

final class AgentSessionRegistryMonitor {
    private let paths: BridgePaths
    private let fileManager: FileManager
    private let hub: AgentEventHub
    private let queue = DispatchQueue(label: "com.tidey.remote-bridge.agent-registry")
    private var timer: DispatchSourceTimer?
    private var watchers = [String: DispatchSourceFileSystemObject]()
    private var watcherFDs = [String: Int32]()
    private var claudeSessions = [String: ClaudeTranscriptSession]()
    private var codexSessions = [String: CodexTranscriptSession]()
    private var activeRecords = [String: AgentSessionRegistryRecord]()
    private var scanScheduled = false

    init(paths: BridgePaths = BridgePaths(),
         fileManager: FileManager = .default,
         hub: AgentEventHub) {
        self.paths = paths
        self.fileManager = fileManager
        self.hub = hub
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
        queue.sync {
            activeRecords.values
                .first { $0.workspaceID == workspaceID && $0.panelID == panelID }
                .map {
                    ActiveAgentSessionSnapshot(vendor: $0.vendor,
                                               workspaceID: $0.workspaceID,
                                               sessionID: $0.sessionID,
                                               panelID: $0.panelID)
                }
        }
    }

    func activeSessionForWorkspace(workspaceID: String) -> ActiveAgentSessionSnapshot? {
        queue.sync {
            activeRecords.values
                .filter { $0.workspaceID == workspaceID }
                .sorted {
                    if $0.createdAt == $1.createdAt {
                        return $0.sessionID < $1.sessionID
                    }
                    return $0.createdAt > $1.createdAt
                }
                .first
                .map {
                    ActiveAgentSessionSnapshot(vendor: $0.vendor,
                                               workspaceID: $0.workspaceID,
                                               sessionID: $0.sessionID,
                                               panelID: $0.panelID)
                }
        }
    }

    deinit {
        stopWatchers()
        timer?.cancel()
        for session in claudeSessions.values {
            session.stop()
        }
        for session in codexSessions.values {
            session.stop()
        }
    }

    private func startWatchers() {
        startWatcher(for: "claude", directory: paths.claudeAgentSessionsDirectory)
        startWatcher(for: "codex", directory: paths.codexAgentSessionsDirectory)
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
            let directory = vendor == "codex" ? paths.codexAgentSessionsDirectory : paths.claudeAgentSessionsDirectory
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
        let claudeRecords = loadRecords(at: paths.claudeAgentSessionsDirectory, vendor: "claude")
        let codexRecords = loadRecords(at: paths.codexAgentSessionsDirectory, vendor: "codex")
        syncClaudeRecords(claudeRecords)
        syncCodexRecords(codexRecords)
        activeRecords = Dictionary(uniqueKeysWithValues: (claudeRecords + codexRecords).map { ($0.sessionID, $0) })
    }

    private func syncClaudeRecords(_ records: [AgentSessionRegistryRecord]) {
        let activeSessionIDs = Set(records.map(\.sessionID))
        for record in records {
            if let session = claudeSessions[record.sessionID] {
                session.update(record: record)
            } else {
                let session = ClaudeTranscriptSession(record: record, fileManager: fileManager, hub: hub)
                claudeSessions[record.sessionID] = session
                session.start()
            }
        }

        let staleSessionIDs = claudeSessions.keys.filter { !activeSessionIDs.contains($0) }
        for sessionID in staleSessionIDs {
            claudeSessions.removeValue(forKey: sessionID)?.stop()
        }
    }

    private func syncCodexRecords(_ records: [AgentSessionRegistryRecord]) {
        let activeSessionIDs = Set(records.map(\.sessionID))
        for record in records {
            if let session = codexSessions[record.sessionID] {
                session.update(record: record)
            } else {
                let session = CodexTranscriptSession(record: record, fileManager: fileManager, hub: hub)
                codexSessions[record.sessionID] = session
                session.start()
            }
        }

        let staleSessionIDs = codexSessions.keys.filter { !activeSessionIDs.contains($0) }
        for sessionID in staleSessionIDs {
            codexSessions.removeValue(forKey: sessionID)?.stop()
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
    private let lineHandler: (String) -> Void
    private let invalidationHandler: () -> Void

    private var fd: Int32 = -1
    private var source: DispatchSourceFileSystemObject?
    private var pendingData = Data()

    init(fileURL: URL,
         queue: DispatchQueue,
         lineHandler: @escaping (String) -> Void,
         invalidationHandler: @escaping () -> Void) {
        self.fileURL = fileURL
        self.queue = queue
        self.lineHandler = lineHandler
        self.invalidationHandler = invalidationHandler
    }

    func start() throws {
        let fd = open(fileURL.path, O_RDONLY)
        guard fd >= 0 else {
            throw POSIXError(.ENOENT)
        }
        self.fd = fd
        readAvailableData()

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
            let bytesRead = read(fd, &chunk, chunk.count)
            if bytesRead > 0 {
                pendingData.append(chunk, count: bytesRead)
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
            pendingData.removeSubrange(...newlineIndex)
            guard !lineData.isEmpty,
                  let line = String(data: lineData, encoding: .utf8) else {
                continue
            }
            lineHandler(line)
        }
    }
}

final class ClaudeTranscriptSession {
    private let queue: DispatchQueue
    private let fileManager: FileManager
    private let hub: AgentEventHub

    private var record: AgentSessionRegistryRecord
    private var resolverTimer: DispatchSourceTimer?
    private var tailer: JSONLFileTailer?
    private var transcriptURL: URL?
    private var nextSequence = 1
    private var didPublishStart = false
    private var didPublishEnd = false
    private var unsupportedVersions = Set<String>()

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
            self.publish(kind: .sessionStarted,
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
                self.publish(kind: .sessionStarted,
                             eventID: "session-start:\(record.sessionID):migrated:\(self.nextSequence)",
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

    func stop() {
        queue.sync {
            resolverTimer?.cancel()
            resolverTimer = nil
            tailer?.stop()
            tailer = nil
            if !didPublishEnd {
                didPublishEnd = true
                publish(kind: .sessionEnded,
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
                                     lineHandler: { [weak self] line in
                                         self?.consume(line: line)
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

    private func consume(line: String) {
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
            publish(kind: .status,
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
            consumeAssistant(object: object, timestamp: timestamp)
        case "user":
            consumeUser(object: object, timestamp: timestamp)
        default:
            break
        }
    }

    private func consumeAssistant(object: [String: Any], timestamp: String) {
        guard let uuid = object["uuid"] as? String,
              let message = object["message"] as? [String: Any],
              message["role"] as? String == "assistant",
              let content = message["content"] as? [[String: Any]] else {
            return
        }

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
                publish(kind: .assistantMessage,
                        eventID: "\(uuid):text:\(index)",
                        timestamp: timestamp,
                        role: "assistant",
                        text: text,
                        name: nil,
                        input: nil,
                        output: nil,
                        toolCallID: nil,
                        metadata: nil)

            case "thinking":
                let thinking = Self.compactString(block["thinking"])
                guard !thinking.isEmpty else {
                    continue
                }
                publish(kind: .thinking,
                        eventID: "\(uuid):thinking:\(index)",
                        timestamp: timestamp,
                        role: "assistant",
                        text: thinking,
                        name: nil,
                        input: nil,
                        output: nil,
                        toolCallID: nil,
                        metadata: nil)

            case "tool_use":
                let name = (block["name"] as? String) ?? "Tool"
                let toolCallID = block["id"] as? String
                let input = Self.stringifyJSON(block["input"])
                publish(kind: .toolCall,
                        eventID: toolCallID ?? "\(uuid):tool-use:\(index)",
                        timestamp: timestamp,
                        role: "assistant",
                        text: nil,
                        name: name,
                        input: input,
                        output: nil,
                        toolCallID: toolCallID,
                        metadata: nil)

            default:
                continue
            }
        }
    }

    private func consumeUser(object: [String: Any], timestamp: String) {
        guard let uuid = object["uuid"] as? String,
              let message = object["message"] as? [String: Any] else {
            return
        }

        // User messages can have content as a plain string (user input)
        if let text = message["content"] as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                publish(kind: .userMessage,
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

        for (index, block) in content.enumerated() {
            let blockType = block["type"] as? String
            if blockType == "tool_result" {
                let output = Self.stringifyToolResultContent(block["content"])
                let toolCallID = block["tool_use_id"] as? String
                let metadata = [
                    "is_error": ((block["is_error"] as? Bool) == true) ? "true" : "false"
                ]
                publish(kind: .toolResult,
                        eventID: "\(uuid):tool-result:\(index)",
                        timestamp: timestamp,
                        role: "tool",
                        text: nil,
                        name: nil,
                        input: nil,
                        output: output,
                        toolCallID: toolCallID,
                        metadata: metadata)
            } else if blockType == "text" {
                let text = Self.compactString(block["text"])
                guard !text.isEmpty else { continue }
                publish(kind: .userMessage,
                        eventID: "\(uuid):user-text:\(index)",
                        timestamp: timestamp,
                        role: "user",
                        text: text,
                        name: nil,
                        input: nil,
                        output: nil,
                        toolCallID: nil,
                        metadata: nil)
            }
        }
    }

    private func publish(kind: AgentEventKind,
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
                               seq: nextSequence,
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
        nextSequence += 1
        hub.publish(event)
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
