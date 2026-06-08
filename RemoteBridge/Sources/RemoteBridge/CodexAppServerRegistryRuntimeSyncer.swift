import Foundation

protocol CodexAppServerApprovalSubmitting: AnyObject {
    func submitApproval(promptID: String, targetIndex: Int) throws -> AgentEvent
}

protocol CodexAppServerRuntimeSessionControlling: AnyObject {
    func canSubmitMessage() -> Bool
    func submitApproval(promptID: String, targetIndex: Int) throws -> AgentEvent
    func submitMessage(text: String) throws
    func stop()
}

extension CodexAppServerRuntimeSession: CodexAppServerRuntimeSessionControlling {}

final class CodexAppServerRegistryRuntimeSyncer: AgentSessionRuntimeSyncing, CodexAppServerApprovalSubmitting, CodexAppServerChatSubmitting {
    typealias AttachHandler = (_ record: AgentSessionRegistryRecord,
                               _ nextSequence: @escaping CodexAppServerConnection.SequenceProvider,
                               _ timestampProvider: @escaping CodexAppServerConnection.TimestampProvider,
                               _ onAgentEvent: @escaping CodexAppServerHeadlessRuntime.AgentEventHandler,
                               _ onInteractivePrompt: @escaping CodexAppServerConnection.InteractivePromptHandler,
                               _ onInteractivePromptResolved: @escaping CodexAppServerConnection.InteractivePromptResolvedHandler) throws -> CodexAppServerRuntimeSessionControlling

    private struct RuntimeEntry {
        let record: AgentSessionRegistryRecord
        let session: CodexAppServerRuntimeSessionControlling
        var transcriptPath: String?
        var transcriptSession: AgentTranscriptSession?
    }

    private let eventHub: AgentEventHub
    private let fileManager: FileManager
    private let chatSubmitEchoRegistry: ChatSubmitEchoRegistry
    private let timestampProvider: CodexAppServerConnection.TimestampProvider
    private let attachHandler: AttachHandler
    private let lock = NSLock()
    private var entriesBySessionID = [String: RuntimeEntry]()

    init(eventHub: AgentEventHub,
         fileManager: FileManager = .default,
         chatSubmitEchoRegistry: ChatSubmitEchoRegistry = ChatSubmitEchoRegistry(),
         factory: CodexAppServerRuntimeSessionFactory = CodexAppServerRuntimeSessionFactory(),
         timestampProvider: @escaping CodexAppServerConnection.TimestampProvider = CodexAppServerRegistryRuntimeSyncer.iso8601Now,
         attachHandler: AttachHandler? = nil) {
        self.eventHub = eventHub
        self.fileManager = fileManager
        self.chatSubmitEchoRegistry = chatSubmitEchoRegistry
        self.timestampProvider = timestampProvider
        if let attachHandler {
            self.attachHandler = attachHandler
        } else {
            self.attachHandler = { record, nextSequence, timestampProvider, onAgentEvent, onInteractivePrompt, onInteractivePromptResolved in
                guard let socketPath = record.appServerSocket,
                      let panelID = record.panelID,
                      !socketPath.isEmpty,
                      !panelID.isEmpty else {
                    throw BridgeInternalError.invalidRequest("Codex app-server registry record is missing socket or panel identity.")
                }
                return try factory.attach(socketPath: socketPath,
                                          processID: record.appServerPID,
                                          context: CodexAppServerRuntimeContext(workspaceID: record.workspaceID,
                                                                               panelID: panelID,
                                                                               sessionID: record.sessionID),
                                          nextSequence: nextSequence,
                                          timestampProvider: timestampProvider,
                                          onAgentEvent: onAgentEvent,
                                          onInteractivePrompt: onInteractivePrompt,
                                          onInteractivePromptResolved: onInteractivePromptResolved)
            }
        }
    }

    func sync(records: [AgentSessionRegistryRecord]) {
        let runtimeRecords = records.filter(Self.isAttachableCodexAppServerRecord(_:))
        let activeSessionIDs = Set(runtimeRecords.map(\.sessionID))

        lock.lock()
        let staleSessionIDs = entriesBySessionID.keys.filter { !activeSessionIDs.contains($0) }
        let staleEntries = staleSessionIDs.compactMap { entriesBySessionID.removeValue(forKey: $0) }
        let recordsToAttach = runtimeRecords.filter { record in
            guard let existing = entriesBySessionID[record.sessionID] else {
                return true
            }
            return existing.record.appServerSocket != record.appServerSocket ||
                existing.record.appServerPID != record.appServerPID ||
                existing.record.workspaceID != record.workspaceID ||
                existing.record.panelID != record.panelID
        }
        let replacedEntries = recordsToAttach.compactMap { entriesBySessionID.removeValue(forKey: $0.sessionID) }
        lock.unlock()

        for entry in staleEntries + replacedEntries {
            stop(entry: entry)
        }

        for record in recordsToAttach {
            attach(record: record)
        }
    }

    func submitApproval(promptID: String, targetIndex: Int) throws -> AgentEvent {
        let sessions = lock.withCodexRuntimeSyncerLock {
            Array(entriesBySessionID.values.map(\.session))
        }
        var lastError: Error?
        for session in sessions {
            do {
                return try session.submitApproval(promptID: promptID, targetIndex: targetIndex)
            } catch BridgeInternalError.notFound {
                continue
            } catch {
                lastError = error
            }
        }
        if let lastError {
            throw lastError
        }
        throw BridgeInternalError.notFound("Unknown Codex approval prompt.")
    }

    func submitMessage(sessionID: String, text: String) throws {
        let session = lock.withCodexRuntimeSyncerLock {
            entriesBySessionID[sessionID]?.session
        }
        guard let session else {
            throw BridgeInternalError.notFound("Unknown Codex app-server session.")
        }
        try session.submitMessage(text: text)
    }

    func canSubmitMessage(sessionID: String) -> Bool {
        let session = lock.withCodexRuntimeSyncerLock {
            entriesBySessionID[sessionID]?.session
        }
        return session?.canSubmitMessage() == true
    }

    private func attach(record: AgentSessionRegistryRecord) {
        do {
            let session = try attachHandler(record,
                                            { [eventHub] sessionID in eventHub.nextSyntheticSeq(sessionID: sessionID) },
                                            timestampProvider,
                                            { [weak self, eventHub] event in
                                                self?.startTranscriptTailerIfAvailable(from: event,
                                                                                       sessionID: record.sessionID)
                                                eventHub.publish(event)
                                            },
                                            { [eventHub] envelope in
                                                eventHub.publish(envelope.event)
                                                BridgeLogger.server.info("codex app-server approval prompt published workspace_id=\(envelope.event.workspaceID, privacy: .public) panel_id=\(envelope.event.metadata?["panel_id"] ?? "-", privacy: .public) session_id=\(envelope.event.sessionID, privacy: .public) prompt_id=\(envelope.prompt.promptID, privacy: .public)")
                                            },
                                            { [eventHub] event in
                                                eventHub.publish(event)
                                            })
            lock.withCodexRuntimeSyncerLock {
                entriesBySessionID[record.sessionID] = RuntimeEntry(record: record,
                                                                    session: session,
                                                                    transcriptPath: nil,
                                                                    transcriptSession: nil)
            }
            BridgeLogger.server.info("codex app-server registry runtime attached workspace_id=\(record.workspaceID, privacy: .public) panel_id=\(record.panelID ?? "-", privacy: .public) session_id=\(record.sessionID, privacy: .public)")
        } catch {
            BridgeLogger.server.error("codex app-server registry runtime attach failed workspace_id=\(record.workspaceID, privacy: .public) panel_id=\(record.panelID ?? "-", privacy: .public) session_id=\(record.sessionID, privacy: .public) error=\(String(describing: error), privacy: .public)")
        }
    }

    private func startTranscriptTailerIfAvailable(from event: AgentEvent, sessionID: String) {
        guard event.payload?.objectValue?["kind"]?.stringValue == "thread_started",
              let rolloutPath = Self.threadRolloutPath(from: event),
              !rolloutPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }

        let existingSession: AgentTranscriptSession?
        let transcriptRecord: AgentSessionRegistryRecord?
        lock.lock()
        if entriesBySessionID[sessionID]?.transcriptPath == rolloutPath {
            lock.unlock()
            return
        }
        if var entry = entriesBySessionID[sessionID] {
            existingSession = entry.transcriptSession
            transcriptRecord = Self.record(entry.record, transcriptPath: rolloutPath)
            entry.transcriptPath = rolloutPath
            entry.transcriptSession = transcriptRecord.map {
                CodexTranscriptSession(record: $0,
                                       fileManager: fileManager,
                                       hub: eventHub,
                                       socketClient: nil,
                                       chatSubmitEchoRegistry: chatSubmitEchoRegistry)
            }
            entriesBySessionID[sessionID] = entry
        } else {
            existingSession = nil
            transcriptRecord = nil
        }
        let transcriptSession = entriesBySessionID[sessionID]?.transcriptSession
        lock.unlock()

        existingSession?.stop()
        guard let transcriptRecord,
              let transcriptSession else {
            return
        }
        transcriptSession.start()
        BridgeLogger.server.info("codex app-server transcript tailer attached workspace_id=\(transcriptRecord.workspaceID, privacy: .public) panel_id=\(transcriptRecord.panelID ?? "-", privacy: .public) session_id=\(transcriptRecord.sessionID, privacy: .public)")
    }

    private func stop(entry: RuntimeEntry) {
        entry.transcriptSession?.stop()
        entry.session.stop()
    }

    private static func isAttachableCodexAppServerRecord(_ record: AgentSessionRegistryRecord) -> Bool {
        record.vendor == "codex" &&
            record.runtime == "codex_app_server" &&
            (record.appServerSocket?.isEmpty == false) &&
            (record.panelID?.isEmpty == false)
    }

    private static func threadRolloutPath(from event: AgentEvent) -> String? {
        guard let payload = event.payload?.objectValue,
              let params = payload["params"]?.objectValue,
              let thread = params["thread"]?.objectValue else {
            return nil
        }
        return thread["path"]?.stringValue
            ?? thread["rollout_path"]?.stringValue
            ?? thread["transcript_path"]?.stringValue
    }

    private static func record(_ record: AgentSessionRegistryRecord,
                               transcriptPath: String) -> AgentSessionRegistryRecord {
        AgentSessionRegistryRecord(version: record.version,
                                   vendor: record.vendor,
                                   workspaceID: record.workspaceID,
                                   sessionID: record.sessionID,
                                   panelID: record.panelID,
                                   pid: record.pid,
                                   cwd: record.cwd,
                                   createdAt: record.createdAt,
                                   transcriptPath: transcriptPath,
                                   tmuxPaneID: record.tmuxPaneID,
                                   tmuxSocketPath: record.tmuxSocketPath,
                                   runtime: record.runtime,
                                   appServerSocket: record.appServerSocket,
                                   appServerPID: record.appServerPID,
                                   remoteTUIPID: record.remoteTUIPID)
    }

    private static func iso8601Now() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }
}

private extension NSLock {
    func withCodexRuntimeSyncerLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
