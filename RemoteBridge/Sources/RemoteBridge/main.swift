import Foundation

if CommandLine.arguments.contains("--cloudflared-supervisor") {
    BridgeCloudflaredSupervisor().run()
}

let tokenStore = PairTokenStore()
let token = try tokenStore.loadOrCreateToken()
let bridgePaths = BridgePaths()
let deviceCredentialStore = BridgeDeviceCredentialStore(paths: bridgePaths)
let hostIdentityStore = BridgeHostIdentityStore(paths: bridgePaths)
let pairSessionStore = BridgePairSessionStore()
let pairingController = BridgePairingController(hostIdentityStore: hostIdentityStore,
                                                pairSessionStore: pairSessionStore,
                                                deviceCredentialStore: deviceCredentialStore)
let authenticator = BridgeAuthenticator(legacyPairToken: token,
                                        deviceCredentialStore: deviceCredentialStore)
let locator = TideySocketLocator()
let socketClient = TideySocketClient(locator: locator)
let eventHub = AgentEventHub()
let workspaceEventHub = WorkspaceEventHub()
let registryMonitor = AgentSessionRegistryMonitor(hub: eventHub, socketClient: socketClient)
let workspaceEventMonitor = TideyWorkspaceEventMonitor(locator: locator, hub: workspaceEventHub)
let observability = BridgeObservabilityCenter()
let cloudflaredStatusStore = BridgeCloudflaredStatusStore(fileURL: bridgePaths.cloudflaredStateFileURL)
let cloudflaredManager = BridgeCloudflaredManager(statusStore: cloudflaredStatusStore,
                                                  supervisorController: BridgeCloudflaredLaunchAgentController())
let resolverPublisher = BridgeResolverPublisher(resolverBaseURL: BridgeResolverConfiguration.resolverBaseURL(),
                                                hostIdentityStore: hostIdentityStore,
                                                publishSecretStore: BridgeResolverPublishSecretStore(paths: bridgePaths),
                                                client: BridgeURLSessionResolverClient())
let resolverPublicationMonitor = BridgeResolverPublicationMonitor(statusReader: cloudflaredStatusStore,
                                                                  publisher: resolverPublisher)
let server = TideyRemoteBridgeServer(token: token,
                                     authenticator: authenticator,
                                     pairingController: pairingController,
                                     socketClient: socketClient,
                                     eventHub: eventHub,
                                     workspaceEventHub: workspaceEventHub,
                                     registryMonitor: registryMonitor,
                                     observability: observability,
                                     cloudflaredManager: cloudflaredManager)

do {
    workspaceEventMonitor.start()
    resolverPublicationMonitor.start()
    try server.run()
} catch {
    fputs("RemoteBridge failed: \(error)\n", stderr)
    exit(1)
}
