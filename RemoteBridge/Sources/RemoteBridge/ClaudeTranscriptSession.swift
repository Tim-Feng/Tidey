import Darwin
import Foundation

private let claudeTranscriptMajorVersion = "2."

struct AgentSessionRegistryRecord: Codable, Sendable {
    let version: Int
    let vendor: String
    let workspaceID: String
    let sessionID: String
    let pid: Int32
    let cwd: String
    let createdAt: String
    let transcriptPath: String?

    enum CodingKeys: String, CodingKey {
        case version
        case vendor
        case workspaceID = "workspace_id"
        case sessionID = "session_id"
        case pid
        case cwd
        case createdAt = "created_at"
        case transcriptPath = "transcript_path"
    }
}

final class AgentSessionRegistryMonitor {
    private let paths: BridgePaths
    private let fileManager: FileManager
    private let hub: AgentEventHub
    private let queue = DispatchQueue(label: "com.tidey.remote-bridge.agent-registry")
    private var timer: DispatchSourceTimer?
    private var sessions = [String: ClaudeTranscriptSession]()

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

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .seconds(2), repeating: .seconds(2))
        timer.setEventHandler { [weak self] in
            self?.scanRegistry()
        }
        timer.resume()
        self.timer = timer
    }

    deinit {
        timer?.cancel()
        for session in sessions.values {
            session.stop()
        }
    }

    private func scanRegistry() {
        let records = loadClaudeRecords()
        let activeSessionIDs = Set(records.map(\.sessionID))

        for record in records {
            if let session = sessions[record.sessionID] {
                session.update(record: record)
            } else {
                let session = ClaudeTranscriptSession(record: record, fileManager: fileManager, hub: hub)
                sessions[record.sessionID] = session
                session.start()
            }
        }

        let staleSessionIDs = sessions.keys.filter { !activeSessionIDs.contains($0) }
        for sessionID in staleSessionIDs {
            sessions.removeValue(forKey: sessionID)?.stop()
        }
    }

    private func loadClaudeRecords() -> [AgentSessionRegistryRecord] {
        guard let enumerator = fileManager.enumerator(at: paths.claudeAgentSessionsDirectory,
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
                  record.vendor == "claude" else {
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

private final class JSONLFileTailer {
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
                         metadata: ["cwd": self.record.cwd])
            self.startResolver()
        }
    }

    func update(record: AgentSessionRegistryRecord) {
        queue.async {
            self.record = record
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
                        metadata: nil)
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
              let message = object["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]] else {
            return
        }

        for (index, block) in content.enumerated() {
            guard block["type"] as? String == "tool_result" else {
                continue
            }
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
                               metadata: metadata)
        nextSequence += 1
        hub.publish(event)
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
