import Foundation

struct BridgeProcessRuntimeConfiguration: Equatable {
    let host: String
    let port: Int
    let devIsolated: Bool

    var shouldStartBackgroundServices: Bool {
        devIsolated == false
    }

    var shouldStartRegistryMonitor: Bool {
        devIsolated == false
    }

    var shouldStartCloudflaredSupervisor: Bool {
        devIsolated == false
    }

    static func from(environment: [String: String] = ProcessInfo.processInfo.environment) -> BridgeProcessRuntimeConfiguration {
        let host = environment["TIDEY_REMOTE_BRIDGE_HOST"] ?? "0.0.0.0"
        let port = environment["TIDEY_REMOTE_BRIDGE_PORT"].flatMap(Int.init) ?? 4817
        let devIsolated = environment["TIDEY_REMOTE_BRIDGE_DEV_ISOLATED"]?.lowercased() == "1"
        return BridgeProcessRuntimeConfiguration(host: host,
                                                 port: port,
                                                 devIsolated: devIsolated)
    }
}
