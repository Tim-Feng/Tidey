protocol AgentSessionRuntimeSyncing: AnyObject {
    func sync(records: [AgentSessionRegistryRecord])
}

final class AgentSessionRuntimeSyncGroup: AgentSessionRuntimeSyncing {
    private let syncers: [AgentSessionRuntimeSyncing]

    init(syncers: [AgentSessionRuntimeSyncing]) {
        self.syncers = syncers
    }

    func sync(records: [AgentSessionRegistryRecord]) {
        for syncer in syncers {
            syncer.sync(records: records)
        }
    }
}
