import Foundation

final class AgentLifecycleSidebarSyncer: AgentSessionRuntimeSyncing {
    typealias SocketIdentityProvider = () -> String?
    typealias CommandSender = (String) throws -> Void

    private let store: AgentSessionLifecycleStore
    private let socketIdentityProvider: SocketIdentityProvider
    private let commandSender: CommandSender
    private let lock = NSLock()
    private var observerToken: UUID?
    private var activeIdentities = Set<AgentSessionLifecycleIdentity>()
    private var pendingClears = Set<AgentSessionLifecycleIdentity>()
    private var deliveredCommands = [AgentSessionLifecycleIdentity: String]()
    private var socketIdentity: String?

    init(store: AgentSessionLifecycleStore,
         socketIdentityProvider: @escaping SocketIdentityProvider,
         commandSender: @escaping CommandSender) {
        self.store = store
        self.socketIdentityProvider = socketIdentityProvider
        self.commandSender = commandSender
    }

    deinit {
        lock.lock()
        let token = observerToken
        observerToken = nil
        lock.unlock()
        if let token {
            store.removeObserver(token)
        }
    }

    func attach() {
        lock.lock()
        defer { lock.unlock() }
        guard observerToken == nil else {
            return
        }
        observerToken = store.addObserver { [weak self] snapshot in
            self?.lifecycleDidChange(snapshot)
        }
    }

    func sync(records: [AgentSessionRegistryRecord]) {
        lock.lock()
        defer { lock.unlock() }

        let nextIdentities = Set(records.compactMap(Self.identity(for:)))
        pendingClears.formUnion(activeIdentities.subtracting(nextIdentities))
        pendingClears.subtract(nextIdentities)
        activeIdentities = nextIdentities

        guard refreshSocketIdentityLocked() != nil else {
            return
        }

        for identity in Self.sorted(pendingClears) {
            deliverLocked(command: Self.clearCommand(for: identity), identity: identity)
        }
        for identity in Self.sorted(activeIdentities) {
            let command = Self.command(for: store.snapshot(identity), identity: identity)
            deliverLocked(command: command, identity: identity)
        }
    }

    private func lifecycleDidChange(_ snapshot: AgentSessionLifecycleSnapshot) {
        lock.lock()
        defer { lock.unlock() }
        guard activeIdentities.contains(snapshot.identity),
              refreshSocketIdentityLocked() != nil else {
            return
        }
        deliverLocked(command: Self.command(for: snapshot, identity: snapshot.identity),
                      identity: snapshot.identity)
    }

    @discardableResult
    private func refreshSocketIdentityLocked() -> String? {
        let current = socketIdentityProvider()
        if current != socketIdentity {
            socketIdentity = current
            deliveredCommands.removeAll()
        }
        return current
    }

    private func deliverLocked(command: String?, identity: AgentSessionLifecycleIdentity) {
        guard let command, deliveredCommands[identity] != command else {
            return
        }
        do {
            try commandSender(command)
            deliveredCommands[identity] = command
            if pendingClears.contains(identity) {
                pendingClears.remove(identity)
                deliveredCommands.removeValue(forKey: identity)
            }
        } catch {
            BridgeLogger.server.error("lifecycle sidebar sync failed workspace_id=\(identity.workspaceID, privacy: .public) panel_id=\(identity.panelID, privacy: .public) session_id=\(identity.sessionID, privacy: .public) error=\(String(describing: error), privacy: .public)")
        }
    }

    private static func identity(for record: AgentSessionRegistryRecord) -> AgentSessionLifecycleIdentity? {
        guard !record.workspaceID.isEmpty, !record.sessionID.isEmpty else {
            return nil
        }
        return AgentSessionLifecycleIdentity(workspaceID: record.workspaceID,
                                             panelID: record.panelID ?? "",
                                             sessionID: record.sessionID)
    }

    private static func command(for snapshot: AgentSessionLifecycleSnapshot?,
                                identity: AgentSessionLifecycleIdentity) -> String? {
        guard snapshot?.ended != true else {
            return clearCommand(for: identity)
        }
        let state: String
        switch snapshot?.state ?? .idle {
        case .working:
            state = "running"
        case .needsInput:
            state = "needs_input"
        case .idle:
            state = "prompt"
        }
        guard isPlaintextToken(identity.workspaceID),
              isPlaintextToken(identity.sessionID),
              identity.panelID.isEmpty || isPlaintextToken(identity.panelID) else {
            return nil
        }
        let panelArgument = identity.panelID.isEmpty ? "" : " --panel_id=\(identity.panelID)"
        return "report_shell_state \(state) --workspace_id=\(identity.workspaceID)\(panelArgument) --session_id=\(identity.sessionID)"
    }

    private static func clearCommand(for identity: AgentSessionLifecycleIdentity) -> String? {
        var message: [String: String] = [
            "action": "clear_status",
            "workspace_id": identity.workspaceID,
            "key": "shell_state",
            "session_id": identity.sessionID,
        ]
        if !identity.panelID.isEmpty {
            message["panel_id"] = identity.panelID
        }
        guard JSONSerialization.isValidJSONObject(message),
              let data = try? JSONSerialization.data(withJSONObject: message, options: [.sortedKeys]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private static func isPlaintextToken(_ value: String) -> Bool {
        !value.isEmpty && !value.contains(where: { $0.isWhitespace })
    }

    private static func sorted(_ identities: Set<AgentSessionLifecycleIdentity>)
        -> [AgentSessionLifecycleIdentity] {
        identities.sorted {
            ($0.workspaceID, $0.panelID, $0.sessionID) < ($1.workspaceID, $1.panelID, $1.sessionID)
        }
    }
}
