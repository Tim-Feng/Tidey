import Foundation

let tokenStore = PairTokenStore()
let token = try tokenStore.loadOrCreateToken()
let locator = TideySocketLocator()
let socketClient = TideySocketClient(locator: locator)
let eventHub = AgentEventHub()
let workspaceEventHub = WorkspaceEventHub()
let registryMonitor = AgentSessionRegistryMonitor(hub: eventHub)
let workspaceEventMonitor = TideyWorkspaceEventMonitor(locator: locator, hub: workspaceEventHub)
let observability = BridgeObservabilityCenter()
let server = TideyRemoteBridgeServer(token: token,
                                     socketClient: socketClient,
                                     eventHub: eventHub,
                                     workspaceEventHub: workspaceEventHub,
                                     registryMonitor: registryMonitor,
                                     observability: observability)

do {
    workspaceEventMonitor.start()
    try server.run()
} catch {
    fputs("RemoteBridge failed: \(error)\n", stderr)
    exit(1)
}
