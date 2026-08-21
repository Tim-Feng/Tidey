import Foundation

final class AgentLifecycleSidebarSyncer: AgentSessionRuntimeSyncing {
    typealias SocketIdentityProvider = () -> String?
    typealias CommandSender = (String) throws -> Void

    private let store: AgentSessionLifecycleStore
    private let socketIdentityProvider: SocketIdentityProvider
    private let commandSender: CommandSender

    init(store: AgentSessionLifecycleStore,
         socketIdentityProvider: @escaping SocketIdentityProvider,
         commandSender: @escaping CommandSender) {
        self.store = store
        self.socketIdentityProvider = socketIdentityProvider
        self.commandSender = commandSender
    }

    func attach() {}

    func sync(records: [AgentSessionRegistryRecord]) {}
}
