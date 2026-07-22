import Foundation

private let codexTranscriptMajorVersion = "0."
private let codexSidebarLogURL = URL(fileURLWithPath: "/tmp/tidey-bridge-codex.log")

typealias CodexTranscriptProcessRunner = (_ executablePath: String,
                                          _ arguments: [String],
                                          _ timeout: TimeInterval) -> BoundedProcessResult?

final class CodexTranscriptSession: AgentTranscriptSession {
    private static let processLookupTimeout: TimeInterval = 1
    private static let rolloutLookupTimeout: TimeInterval = 2

    private let queue: DispatchQueue
    private let fileManager: FileManager
    private let hub: AgentEventHub
    private let socketClient: TideyCommandSending?
    private let chatSubmitEchoRegistry: ChatSubmitEchoRegistry
    private let processRunner: CodexTranscriptProcessRunner

    private var record: AgentSessionRegistryRecord
    private var resolverTimer: DispatchSourceTimer?
    private var tailer: JSONLFileTailer?
    private var transcriptURL: URL?
    private var transcriptSequenceBase = 0
    private var maxObservedSeq = transcriptSessionStartedSequence
    private var didPublishStart = false
    private var didPublishEnd = false
    private var didSeeInteractiveEvent = false
    private var unsupportedVersions = Set<String>()
    private var resolvedToolCallIDs = Set<String>()
    private var publishedAssistantTextKeys = Set<String>()
    private var isBackfillingHistory = false
    private var isBootstrappingSidebarState = false
    private var historicalRawLines: [(offset: Int, line: String)] = []
    private var historicalReplayProducts: [AgentEvent] = []
    private var isCollectingBackfillPage = false
    private var collectedBackfillPage: [(offset: Int, line: String)] = []
    private let historicalReplayWindowCapacity: Int
    private var bootstrappedShellState: CodexSidebarShellState = .prompt
    private var currentShellState: CodexSidebarShellState = .prompt
    private var didPublishSidebarSessionActivation = false
    private var lastStartedTurnID: String?
    private var lastCompletedTurnID: String?
    private var lastAbortedTurnID: String?

    private struct LiveParserStateSnapshot {
        let unsupportedVersions: Set<String>
        let resolvedToolCallIDs: Set<String>
        let publishedAssistantTextKeys: Set<String>
        let didSeeInteractiveEvent: Bool
        let lastStartedTurnID: String?
        let lastCompletedTurnID: String?
        let lastAbortedTurnID: String?
        let currentShellState: CodexSidebarShellState
        let bootstrappedShellState: CodexSidebarShellState
    }

    private var lastRequestedBackfillAnchorSeq: Int?

    private func captureLiveParserState() -> LiveParserStateSnapshot {
        LiveParserStateSnapshot(unsupportedVersions: unsupportedVersions,
                                resolvedToolCallIDs: resolvedToolCallIDs,
                                publishedAssistantTextKeys: publishedAssistantTextKeys,
                                didSeeInteractiveEvent: didSeeInteractiveEvent,
                                lastStartedTurnID: lastStartedTurnID,
                                lastCompletedTurnID: lastCompletedTurnID,
                                lastAbortedTurnID: lastAbortedTurnID,
                                currentShellState: currentShellState,
                                bootstrappedShellState: bootstrappedShellState)
    }

    private func resetParserStateForHistoricalReplay() {
        unsupportedVersions = []
        resolvedToolCallIDs = []
        publishedAssistantTextKeys = []
        didSeeInteractiveEvent = false
        lastStartedTurnID = nil
        lastCompletedTurnID = nil
        lastAbortedTurnID = nil
        currentShellState = .prompt
        bootstrappedShellState = .prompt
    }

    private func restoreLiveParserState(_ snapshot: LiveParserStateSnapshot) {
        unsupportedVersions = snapshot.unsupportedVersions
        resolvedToolCallIDs = snapshot.resolvedToolCallIDs
        publishedAssistantTextKeys = snapshot.publishedAssistantTextKeys
        didSeeInteractiveEvent = snapshot.didSeeInteractiveEvent
        lastStartedTurnID = snapshot.lastStartedTurnID
        lastCompletedTurnID = snapshot.lastCompletedTurnID
        lastAbortedTurnID = snapshot.lastAbortedTurnID
        currentShellState = snapshot.currentShellState
        bootstrappedShellState = snapshot.bootstrappedShellState
    }

    private func mergeHistoricalPage(_ page: [(offset: Int, line: String)]) {
        guard let pageMin = page.map(\.offset).min(),
              let pageMax = page.map(\.offset).max() else {
            return
        }
        var merged = page + historicalRawLines
        merged.sort { $0.offset < $1.offset }
        var seenOffsets = Set<Int>()
        merged = merged.filter { seenOffsets.insert($0.offset).inserted }
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

        let products = historicalReplayProducts
        hub.replaceHistoricalEvents(sessionID: record.sessionID,
                                    events: products,
                                    anchorSeq: lastRequestedBackfillAnchorSeq)
        historicalReplayProducts = []
        return products
    }

    init(record: AgentSessionRegistryRecord,
         fileManager: FileManager = .default,
         hub: AgentEventHub,
         socketClient: TideyCommandSending? = nil,
         chatSubmitEchoRegistry: ChatSubmitEchoRegistry? = nil,
         historicalReplayWindowCapacity: Int = 4000,
         processRunner: CodexTranscriptProcessRunner? = nil) {
        self.historicalReplayWindowCapacity = max(1, historicalReplayWindowCapacity)
        self.record = record
        self.fileManager = fileManager
        self.hub = hub
        self.socketClient = socketClient
        self.chatSubmitEchoRegistry = chatSubmitEchoRegistry ?? ChatSubmitEchoRegistry()
        self.processRunner = processRunner ?? Self.liveProcessRunner
        self.queue = DispatchQueue(label: "com.tidey.remote-bridge.codex-session.\(record.sessionID)")
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
            if self.tailer == nil {
                self.publishSidebarSessionActivation(force: false)
            }
        }
    }

    func update(record: AgentSessionRegistryRecord) {
        queue.async {
            let previousRecord = self.record
            let didMigrateWorkspace = previousRecord.workspaceID != record.workspaceID
            let didMigratePanel = previousRecord.panelID != record.panelID
            let didChangeTranscriptIdentity = Self.transcriptIdentity(for: previousRecord) !=
                Self.transcriptIdentity(for: record)
            if didMigrateWorkspace || didMigratePanel {
                self.hub.migrateSession(sessionID: previousRecord.sessionID,
                                        toWorkspaceID: record.workspaceID,
                                        panelID: record.panelID)
            }
            self.record = record
            if didChangeTranscriptIdentity {
                self.switchTranscriptIdentity()
            }
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
                self.publishSidebarSessionActivation(force: true)
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
            guard beforeSeq > transcriptSequenceBase else {
                return false
            }
            let beforeOffset = transcriptLineOffset(for: beforeSeq - transcriptSequenceBase)
            guard beforeOffset > 0 else {
                return false
            }
            let effectiveLimit = min(limit, historicalReplayWindowCapacity)
            lastRequestedBackfillAnchorSeq = beforeSeq
            var pageAnchorOffset = beforeOffset
            var loadedAny = false
            while true {
                isCollectingBackfillPage = true
                collectedBackfillPage = []
                let loaded = (try? tailer.backfill(beforeOffset: pageAnchorOffset,
                                                   limit: effectiveLimit)) ?? false
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
            log("startResolver resolved transcript=\(transcriptURL?.path ?? "<nil>")")
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
            isBootstrappingSidebarState = true
            bootstrappedShellState = .prompt
            try tailer.start()
            isBootstrappingSidebarState = false
            self.tailer = tailer
            self.transcriptURL = transcriptURL
            resolverTimer?.cancel()
            resolverTimer = nil
            log("tailer.start bootstrap end shellState=\(currentShellState) startedTurn=\(lastStartedTurnID ?? "<nil>") completedTurn=\(lastCompletedTurnID ?? "<nil>")")
            publishSidebarSessionActivation(force: false)
        } catch {
            isBootstrappingSidebarState = false
            self.transcriptURL = nil
            log("tailer.start failed transcript=\(transcriptURL.path) error=\(error)")
        }
    }

    private func handleTailerInvalidation() {
        transcriptURL = nil
        tailer = nil
        if resolverTimer == nil {
            startResolver()
        }
    }

    private func switchTranscriptIdentity() {
        historicalRawLines = []
        collectedBackfillPage = []
        historicalReplayProducts = []
        lastRequestedBackfillAnchorSeq = nil
        hub.replaceHistoricalEvents(sessionID: record.sessionID, events: [], anchorSeq: nil)
        transcriptSequenceBase = maxObservedSeq
        transcriptURL = nil
        tailer?.stop()
        tailer = nil
        resolverTimer?.cancel()
        resolverTimer = nil
        didSeeInteractiveEvent = false
        unsupportedVersions.removeAll()
        resolvedToolCallIDs.removeAll()
        publishedAssistantTextKeys.removeAll()
        isBackfillingHistory = false
        isBootstrappingSidebarState = false
        bootstrappedShellState = .prompt
        currentShellState = .prompt
        lastStartedTurnID = nil
        lastCompletedTurnID = nil
        lastAbortedTurnID = nil
        startResolver()
    }

    private func resolveTranscriptURL() -> URL? {
        if let transcriptPath = record.transcriptPath,
           !transcriptPath.isEmpty {
            let url = URL(fileURLWithPath: NSString(string: transcriptPath).expandingTildeInPath)
            if fileManager.fileExists(atPath: url.path) {
                return url
            }
        }

        if let processTreeResolved = resolveTranscriptURLFromProcessTree() {
            return processTreeResolved
        }

        let sessionsDirectory = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions", isDirectory: true)

        guard let enumerator = fileManager.enumerator(at: sessionsDirectory,
                                                      includingPropertiesForKeys: [.isRegularFileKey],
                                                      options: [.skipsHiddenFiles]) else {
            return nil
        }
        for case let url as URL in enumerator {
            guard url.lastPathComponent.hasPrefix("rollout-"),
                  url.pathExtension == "jsonl",
                  transcriptSessionIDs.contains(where: { url.lastPathComponent.contains($0) }) else {
                continue
            }
            return url
        }
        return nil
    }

    private var transcriptSessionIDs: [String] {
        var values = [String]()
        for value in [record.sessionID, record.threadID, record.resumeThreadID] {
            guard let value,
                  !value.isEmpty,
                  !values.contains(value) else {
                continue
            }
            values.append(value)
        }
        return values
    }

    private func resolveTranscriptURLFromProcessTree() -> URL? {
        for rootPID in transcriptResolutionRootPIDs() {
            guard let path = rolloutPathForPIDTree(rootPID: rootPID),
                  !path.isEmpty else {
                continue
            }
            let expanded = NSString(string: path).expandingTildeInPath
            let url = URL(fileURLWithPath: expanded)
            guard fileManager.fileExists(atPath: url.path) else {
                continue
            }
            return url
        }
        return nil
    }

    private func transcriptResolutionRootPIDs() -> [Int32] {
        let candidates = [record.appServerPID, record.remoteTUIPID, record.pid].compactMap { $0 }
        var seen = Set<Int32>()
        return candidates.filter { pid in
            guard pid > 0 else {
                return false
            }
            return seen.insert(pid).inserted
        }
    }

    private func consume(line: String, lineOffset: Int) {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String,
              let payload = object["payload"] as? [String: Any] else {
            return
        }

        let timestamp = (object["timestamp"] as? String) ?? ISO8601DateFormatter().string(from: Date())

        switch type {
        case "session_meta":
            consumeSessionMeta(payload: payload, timestamp: timestamp, lineOffset: lineOffset)
        case "response_item":
            consumeResponseItem(payload: payload, timestamp: timestamp, lineOffset: lineOffset)
        case "event_msg":
            consumeEventMessage(payload: payload, timestamp: timestamp, lineOffset: lineOffset)
        default:
            break
        }
    }

    private func consumeSessionMeta(payload: [String: Any], timestamp: String, lineOffset: Int) {
        guard let sessionID = payload["id"] as? String,
              transcriptSessionIDs.contains(sessionID) else {
            return
        }
        if let cliVersion = payload["cli_version"] as? String,
           !cliVersion.hasPrefix(codexTranscriptMajorVersion),
           !unsupportedVersions.contains(cliVersion) {
            unsupportedVersions.insert(cliVersion)
            publishFileBacked(kind: .status,
                              lineOffset: lineOffset,
                              ordinal: 0,
                              eventID: "status:\(record.sessionID):\(fileBackedSequence(lineOffset: lineOffset, ordinal: 0)):unsupported-version:\(cliVersion)",
                              timestamp: timestamp,
                              role: nil,
                              text: "Unsupported Codex transcript version \(cliVersion)",
                              name: nil,
                              input: nil,
                              output: nil,
                              toolCallID: nil,
                              metadata: baseMetadata(["reason": "unsupported_version"]))
        }
    }

    private func consumeResponseItem(payload: [String: Any], timestamp: String, lineOffset: Int) {
        guard let payloadType = payload["type"] as? String else {
            return
        }

        switch payloadType {
        case "message":
            consumeMessageItem(payload: payload, timestamp: timestamp, lineOffset: lineOffset)
        case "function_call":
            consumeFunctionCall(payload: payload, timestamp: timestamp, lineOffset: lineOffset)
        case "function_call_output":
            consumeFunctionCallOutput(payload: payload, timestamp: timestamp, lineOffset: lineOffset)
        case "reasoning":
            break
        default:
            break
        }
    }

    private func consumeMessageItem(payload: [String: Any], timestamp: String, lineOffset: Int) {
        guard let role = payload["role"] as? String else {
            return
        }

        let phase = payload["phase"] as? String
        let text = Self.compactString(Self.extractMessageText(from: payload["content"]))
        guard !text.isEmpty else {
            return
        }

        switch role {
        case "assistant":
            if phase == "commentary" || phase == "final_answer" {
                return
            }
            didSeeInteractiveEvent = true
            publishAssistantText(kind: .assistantMessage,
                                 eventNamespace: "assistant",
                                 phase: phase ?? "message",
                                 timestamp: timestamp,
                                 text: text,
                                 lineOffset: lineOffset,
                                 ordinal: 0)

        case "user":
            guard shouldPublishUserMessage(text) else {
                return
            }
            publishFileBacked(kind: .userMessage,
                              lineOffset: lineOffset,
                              ordinal: 0,
                              eventID: "user:\(record.sessionID):\(fileBackedSequence(lineOffset: lineOffset, ordinal: 0))",
                              timestamp: timestamp,
                              role: role,
                              text: text,
                              name: nil,
                              input: nil,
                              output: nil,
                              toolCallID: nil,
                              metadata: nil)

        default:
            break
        }
    }

    private func consumeFunctionCall(payload: [String: Any], timestamp: String, lineOffset: Int) {
        guard let callID = payload["call_id"] as? String else {
            return
        }

        didSeeInteractiveEvent = true
        publishFileBacked(kind: .toolCall,
                          lineOffset: lineOffset,
                          ordinal: 0,
                          eventID: callID,
                          timestamp: timestamp,
                          role: "assistant",
                          text: nil,
                          name: (payload["name"] as? String) ?? "tool",
                          input: Self.compactString(payload["arguments"] as? String),
                          output: nil,
                          toolCallID: callID,
                          metadata: nil)
    }

    private func consumeFunctionCallOutput(payload: [String: Any], timestamp: String, lineOffset: Int) {
        guard let callID = payload["call_id"] as? String,
              !resolvedToolCallIDs.contains(callID) else {
            return
        }
        let output = Self.compactString(payload["output"] as? String)
        guard !output.isEmpty else {
            return
        }

        didSeeInteractiveEvent = true
        resolvedToolCallIDs.insert(callID)
        publishFileBacked(kind: .toolResult,
                          lineOffset: lineOffset,
                          ordinal: 0,
                          eventID: "\(callID):function-output",
                          timestamp: timestamp,
                          role: "tool",
                          text: nil,
                          name: nil,
                          input: nil,
                          output: output,
                          toolCallID: callID,
                          metadata: ["source": "function_call_output"])
    }

    private func consumeEventMessage(payload: [String: Any], timestamp: String, lineOffset: Int) {
        guard let payloadType = payload["type"] as? String else {
            return
        }

        switch payloadType {
        case "agent_message":
            consumeAgentMessage(payload: payload, timestamp: timestamp, lineOffset: lineOffset)
        case "task_started":
            consumeTaskStarted(payload: payload)
        case "task_complete":
            consumeTaskComplete(payload: payload)
        case "turn_aborted":
            consumeTurnAborted(payload: payload)
        case "exec_command_end":
            consumeExecCommandEnd(payload: payload, timestamp: timestamp, lineOffset: lineOffset)
        case "patch_apply_end":
            consumePatchApplyEnd(payload: payload, timestamp: timestamp, lineOffset: lineOffset)
        default:
            break
        }
    }

    private func consumeTaskStarted(payload: [String: Any]) {
        guard let turnID = payload["turn_id"] as? String,
              !turnID.isEmpty,
              turnID != lastStartedTurnID else {
            return
        }
        lastStartedTurnID = turnID

        if isBootstrappingSidebarState {
            bootstrappedShellState = .running
            currentShellState = .running
            return
        }

        guard currentShellState != .running else { return }
        currentShellState = .running
        log("consumeTaskStarted publish running turnID=\(turnID)")
        publishSidebar(messages: CodexSidebarMessages.running(workspaceID: record.workspaceID))
    }

    private func consumeTaskComplete(payload: [String: Any]) {
        guard let turnID = payload["turn_id"] as? String,
              !turnID.isEmpty,
              turnID != lastCompletedTurnID else {
            return
        }
        lastCompletedTurnID = turnID
        let body = Self.compactString(payload["last_agent_message"] as? String)

        if isBootstrappingSidebarState {
            bootstrappedShellState = .prompt
            currentShellState = .prompt
            return
        }

        currentShellState = .prompt
        if body.isEmpty {
            log("consumeTaskComplete publish prompt turnID=\(turnID)")
            publishSidebar(messages: CodexSidebarMessages.prompt(workspaceID: record.workspaceID))
            return
        }
        log("consumeTaskComplete publish completed turnID=\(turnID) bodyLength=\(body.count)")
        publishSidebar(messages: CodexSidebarMessages.completed(workspaceID: record.workspaceID,
                                                               body: body))
    }

    private func consumeTurnAborted(payload: [String: Any]) {
        guard let turnID = payload["turn_id"] as? String,
              !turnID.isEmpty,
              turnID != lastAbortedTurnID else {
            return
        }
        lastAbortedTurnID = turnID

        if isBootstrappingSidebarState {
            bootstrappedShellState = .prompt
            currentShellState = .prompt
            return
        }

        guard currentShellState != .prompt else { return }
        currentShellState = .prompt
        log("consumeTurnAborted publish prompt turnID=\(turnID)")
        publishSidebar(messages: CodexSidebarMessages.prompt(workspaceID: record.workspaceID))
    }

    private func consumeAgentMessage(payload: [String: Any], timestamp: String, lineOffset: Int) {
        let text = Self.compactString(payload["message"] as? String)
        guard !text.isEmpty else {
            return
        }

        didSeeInteractiveEvent = true
        let phase = payload["phase"] as? String
        switch phase {
        case "final_answer":
            publishAssistantText(kind: .assistantFinal,
                                 eventNamespace: "final",
                                 phase: "final_answer",
                                 timestamp: timestamp,
                                 text: text,
                                 lineOffset: lineOffset,
                                 ordinal: 0)
        case "commentary":
            publishAssistantText(kind: .assistantMessage,
                                 eventNamespace: "commentary",
                                 phase: "commentary",
                                 timestamp: timestamp,
                                 text: text,
                                 lineOffset: lineOffset,
                                 ordinal: 0)
        default:
            break
        }
    }

    private func publishAssistantText(kind: AgentEventKind,
                                      eventNamespace: String,
                                      phase: String,
                                      timestamp: String,
                                      text: String,
                                      lineOffset: Int,
                                      ordinal: Int) {
        let dedupeKey = "\(kind.rawValue)|\(phase)|\(timestamp)|\(text)"
        guard !publishedAssistantTextKeys.contains(dedupeKey) else {
            return
        }
        publishedAssistantTextKeys.insert(dedupeKey)
        let seq = fileBackedSequence(lineOffset: lineOffset, ordinal: ordinal)
        publishFileBacked(kind: kind,
                          lineOffset: lineOffset,
                          ordinal: ordinal,
                          eventID: "\(eventNamespace):\(record.sessionID):\(seq)",
                          timestamp: timestamp,
                          role: "assistant",
                          text: text,
                          name: nil,
                          input: nil,
                          output: nil,
                          toolCallID: nil,
                          metadata: ["phase": phase])
    }

    private func consumeExecCommandEnd(payload: [String: Any], timestamp: String, lineOffset: Int) {
        guard let callID = payload["call_id"] as? String,
              !resolvedToolCallIDs.contains(callID) else {
            return
        }
        let output = Self.compactString(
            (payload["aggregated_output"] as? String) ??
            (payload["formatted_output"] as? String) ??
            (payload["stdout"] as? String) ??
            (payload["stderr"] as? String)
        )
        guard !output.isEmpty else {
            return
        }

        didSeeInteractiveEvent = true
        resolvedToolCallIDs.insert(callID)
        publishFileBacked(kind: .toolResult,
                          lineOffset: lineOffset,
                          ordinal: 0,
                          eventID: "\(callID):exec-end",
                          timestamp: timestamp,
                          role: "tool",
                          text: nil,
                          name: nil,
                          input: nil,
                          output: output,
                          toolCallID: callID,
                          metadata: Self.metadata(
                              source: "exec_command_end",
                              values: [
                                  "exit_code": Self.stringValue(payload["exit_code"]),
                                  "status": payload["status"] as? String,
                              ]
                          ))
    }

    private func consumePatchApplyEnd(payload: [String: Any], timestamp: String, lineOffset: Int) {
        guard let callID = payload["call_id"] as? String,
              !resolvedToolCallIDs.contains(callID) else {
            return
        }
        let output = Self.compactString(
            (payload["stdout"] as? String) ??
            (payload["stderr"] as? String)
        )
        guard !output.isEmpty else {
            return
        }

        didSeeInteractiveEvent = true
        resolvedToolCallIDs.insert(callID)
        publishFileBacked(kind: .toolResult,
                          lineOffset: lineOffset,
                          ordinal: 0,
                          eventID: "\(callID):patch-end",
                          timestamp: timestamp,
                          role: "tool",
                          text: nil,
                          name: nil,
                          input: nil,
                          output: output,
                          toolCallID: callID,
                          metadata: Self.metadata(
                              source: "patch_apply_end",
                              values: [
                                  "success": Self.boolString(payload["success"]),
                                  "status": payload["status"] as? String,
                              ]
                          ))
    }

    private func shouldPublishUserMessage(_ text: String) -> Bool {
        guard !text.isEmpty else {
            return false
        }
        if Self.isBootstrapUserMessage(text) {
            return false
        }
        if didSeeInteractiveEvent {
            return true
        }
        return true
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
        let seq = fileBackedSequence(lineOffset: lineOffset, ordinal: ordinal)
        maxObservedSeq = max(maxObservedSeq, seq)
        let resolvedMetadata = metadataWithClientRequestID(kind: kind, text: text, metadata: metadata)
        let event = AgentEvent(eventID: eventID,
                               seq: seq,
                               vendor: "codex",
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
        if isBackfillingHistory {
            historicalReplayProducts.append(event)
            return
        }
        hub.publish(event)
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
                               vendor: "codex",
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
            historicalReplayProducts.append(event)
            return
        }
        hub.publish(event)
    }

    private func publishSidebarSessionActivation(force: Bool) {
        guard force || !didPublishSidebarSessionActivation else {
            return
        }
        didPublishSidebarSessionActivation = true
        let shellState = isBootstrappingSidebarState ? bootstrappedShellState : currentShellState
        currentShellState = shellState
        log("publishSidebarSessionActivation force=\(force) shellState=\(shellState) workspace=\(record.workspaceID)")
        publishSidebar(messages: CodexSidebarMessages.sessionActive(workspaceID: record.workspaceID,
                                                                   shellState: shellState))
    }

    private func publishSidebar(messages: [String]) {
        guard isBackfillingHistory == false else {
            return
        }
        guard let socketClient else {
            log("publishSidebar skipped socketClient=nil messages=\(messages)")
            return
        }
        for message in messages {
            do {
                try socketClient.send(command: message)
                log("publishSidebar sent message=\(message)")
            } catch {
                log("publishSidebar failed message=\(message) error=\(error)")
            }
        }
    }

    private func log(_ message: String) {
        guard isBackfillingHistory == false else {
            return
        }
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "\(timestamp) [\(record.workspaceID)] [\(record.sessionID)] \(message)\n"
        guard let data = line.data(using: .utf8) else {
            return
        }
        if fileManager.fileExists(atPath: codexSidebarLogURL.path),
           let handle = try? FileHandle(forWritingTo: codexSidebarLogURL) {
            defer { try? handle.close() }
            do {
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } catch {
                try? data.write(to: codexSidebarLogURL, options: .atomic)
            }
            return
        }
        try? data.write(to: codexSidebarLogURL, options: .atomic)
    }

    private func nextSyntheticSequence() -> Int {
        maxObservedSeq += 1
        return maxObservedSeq
    }

    private func fileBackedSequence(lineOffset: Int, ordinal: Int) -> Int {
        transcriptSequenceBase + transcriptEventSequence(lineOffset: lineOffset, ordinal: ordinal)
    }

    private static func transcriptIdentity(for record: AgentSessionRegistryRecord) -> [String] {
        [
            record.transcriptPath ?? "",
            record.threadID ?? "",
            record.resumeThreadID ?? "",
        ]
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
                                                                                  vendor: "codex",
                                                                                  text: text) else {
            return metadata
        }
        var merged = metadata ?? [:]
        merged["client_request_id"] = clientRequestID
        return merged
    }

    private static func extractMessageText(from value: Any?) -> String {
        if let string = value as? String {
            return string
        }
        guard let blocks = value as? [[String: Any]] else {
            return ""
        }

        let parts = blocks.compactMap { block -> String? in
            guard let type = block["type"] as? String else {
                return nil
            }
            switch type {
            case "input_text", "output_text", "text", "summary_text":
                return block["text"] as? String
            default:
                return nil
            }
        }
        return parts.joined(separator: "\n\n")
    }

    private static func isBootstrapUserMessage(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixes = [
            "# AGENTS.md instructions",
            "<environment_context>",
            "<permissions instructions>",
            "<app-context>",
        ]
        return prefixes.contains { trimmed.hasPrefix($0) }
    }

    private static func compactString(_ value: String?) -> String {
        guard let value else {
            return ""
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stringValue(_ value: Any?) -> String? {
        if let string = value as? String {
            return string
        }
        if let number = value as? NSNumber {
            return number.stringValue
        }
        return nil
    }

    private static func boolString(_ value: Any?) -> String? {
        guard let bool = value as? Bool else {
            return nil
        }
        return bool ? "true" : "false"
    }

    private static func metadata(source: String, values: [String: String?]) -> [String: String] {
        var metadata = ["source": source]
        for (key, value) in values {
            if let value, !value.isEmpty {
                metadata[key] = value
            }
        }
        return metadata
    }

    private func rolloutPathForPIDTree(rootPID: Int32) -> String? {
        guard rootPID > 0 else {
            return nil
        }

        var queue = [rootPID]
        var visited = Set<Int32>([rootPID])

        while !queue.isEmpty {
            let pid = queue.removeFirst()
            if let path = rolloutPathForPID(pid), !path.isEmpty {
                return path
            }
            for child in childPIDs(for: pid) where !visited.contains(child) {
                visited.insert(child)
                queue.append(child)
            }
        }

        return nil
    }

    private func rolloutPathForPID(_ pid: Int32) -> String? {
        guard pid > 0 else {
            return nil
        }
        guard let result = processRunner("/usr/sbin/lsof",
                                         ["-Fn", "-p", String(pid)],
                                         Self.rolloutLookupTimeout),
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

    private func childPIDs(for pid: Int32) -> [Int32] {
        guard pid > 0 else {
            return []
        }
        guard let result = processRunner("/usr/bin/pgrep",
                                         ["-P", String(pid)],
                                         Self.processLookupTimeout),
              let output = String(data: result.standardOutput,
                                  encoding: .utf8) else {
            return []
        }
        return output
            .split(whereSeparator: \.isNewline)
            .compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
    }

    private static let liveProcessRunner: CodexTranscriptProcessRunner = { executablePath, arguments, timeout in
        BoundedProcessRunner.run(executablePath: executablePath,
                                 arguments: arguments,
                                 timeout: timeout)
    }
}
