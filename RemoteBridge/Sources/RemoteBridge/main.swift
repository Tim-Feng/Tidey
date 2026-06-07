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
let codexAppServerPanelRuntime = CodexAppServerPanelRuntimeManager(eventHub: eventHub)
let registryMonitor = AgentSessionRegistryMonitor(hub: eventHub,
                                                  socketClient: socketClient,
                                                  runtimeSyncer: codexAppServerPanelRuntime)
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
let uploadGarbageCollector = BridgeUploadGarbageCollector(uploadDirectory: bridgePaths.uploadsDirectory)
let runtimeConfiguration = BridgeProcessRuntimeConfiguration.from()
let server = TideyRemoteBridgeServer(host: runtimeConfiguration.host,
                                     port: runtimeConfiguration.port,
                                     token: token,
                                     authenticator: authenticator,
                                     pairingController: pairingController,
                                     socketClient: socketClient,
                                     eventHub: eventHub,
                                     workspaceEventHub: workspaceEventHub,
                                     registryMonitor: registryMonitor,
                                     observability: observability,
                                     cloudflaredManager: cloudflaredManager,
                                     uploadGarbageCollector: uploadGarbageCollector,
                                     headlessCodexRuntime: codexAppServerPanelRuntime,
                                     startRegistryMonitor: runtimeConfiguration.shouldStartRegistryMonitor,
                                     startCloudflaredSupervisor: runtimeConfiguration.shouldStartCloudflaredSupervisor)

do {
    if runtimeConfiguration.shouldStartBackgroundServices {
        workspaceEventMonitor.start()
        resolverPublicationMonitor.start()
        uploadGarbageCollector.start()
    } else {
        BridgeLogger.server.info("bridge dev isolated mode enabled port=\(runtimeConfiguration.port, privacy: .public)")
    }
    try server.run()
} catch {
    fputs("RemoteBridge failed: \(error)\n", stderr)
    exit(1)
}
