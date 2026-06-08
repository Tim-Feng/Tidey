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
    }

    private let eventHub: AgentEventHub
    private let timestampProvider: CodexAppServerConnection.TimestampProvider
    private let attachHandler: AttachHandler
    private let lock = NSLock()
    private var entriesBySessionID = [String: RuntimeEntry]()

    init(eventHub: AgentEventHub,
         factory: CodexAppServerRuntimeSessionFactory = CodexAppServerRuntimeSessionFactory(),
         timestampProvider: @escaping CodexAppServerConnection.TimestampProvider = CodexAppServerRegistryRuntimeSyncer.iso8601Now,
         attachHandler: AttachHandler? = nil) {
        self.eventHub = eventHub
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
            entry.session.stop()
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
                                            { _ in },
                                            { [eventHub] envelope in
                                                eventHub.publish(envelope.event)
                                                BridgeLogger.server.info("codex app-server approval prompt published workspace_id=\(envelope.event.workspaceID, privacy: .public) panel_id=\(envelope.event.metadata?["panel_id"] ?? "-", privacy: .public) session_id=\(envelope.event.sessionID, privacy: .public) prompt_id=\(envelope.prompt.promptID, privacy: .public)")
                                            },
                                            { [eventHub] event in
                                                eventHub.publish(event)
                                            })
            lock.withCodexRuntimeSyncerLock {
                entriesBySessionID[record.sessionID] = RuntimeEntry(record: record, session: session)
            }
            BridgeLogger.server.info("codex app-server registry runtime attached workspace_id=\(record.workspaceID, privacy: .public) panel_id=\(record.panelID ?? "-", privacy: .public) session_id=\(record.sessionID, privacy: .public)")
        } catch {
            BridgeLogger.server.error("codex app-server registry runtime attach failed workspace_id=\(record.workspaceID, privacy: .public) panel_id=\(record.panelID ?? "-", privacy: .public) session_id=\(record.sessionID, privacy: .public) error=\(String(describing: error), privacy: .public)")
        }
    }

    private static func isAttachableCodexAppServerRecord(_ record: AgentSessionRegistryRecord) -> Bool {
        record.vendor == "codex" &&
            record.runtime == "codex_app_server" &&
            (record.appServerSocket?.isEmpty == false) &&
            (record.panelID?.isEmpty == false)
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
