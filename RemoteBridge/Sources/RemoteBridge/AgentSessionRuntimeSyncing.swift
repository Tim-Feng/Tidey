protocol AgentSessionRuntimeSyncing: AnyObject {
    func sync(records: [AgentSessionRegistryRecord])
}
