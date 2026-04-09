import Foundation

let tokenStore = PairTokenStore()
let token = try tokenStore.loadOrCreateToken()
let locator = TideySocketLocator()
let socketClient = TideySocketClient(locator: locator)
let eventHub = AgentEventHub()
let registryMonitor = AgentSessionRegistryMonitor(hub: eventHub)
let server = TideyRemoteBridgeServer(token: token,
                                     socketClient: socketClient,
                                     eventHub: eventHub,
                                     registryMonitor: registryMonitor)

do {
    try server.run()
} catch {
    fputs("RemoteBridge failed: \(error)\n", stderr)
    exit(1)
}
