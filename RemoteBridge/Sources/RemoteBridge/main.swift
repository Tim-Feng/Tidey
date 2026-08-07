import Foundation

if CommandLine.arguments.contains("--cloudflared-supervisor") {
    let supervisor = BridgeCloudflaredSupervisor()
    supervisor.run()
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
let ordinaryTmuxProjectionContext = OrdinaryTmuxProjectionContext()
let ordinaryTmuxPaneIdentityReconciler = OrdinaryTmuxPaneIdentityReconciler(socketClient: socketClient,
                                                                            projectionContext: ordinaryTmuxProjectionContext)
let ordinaryTmuxCarrierResolver = TideyOrdinaryTmuxCarrierResolver(socketClient: socketClient)
let codexRuntimeSyncer = CodexAppServerRegistryRuntimeSyncer(eventHub: eventHub,
                                                             sidebarMessageSender: { command in
                                                                 try socketClient.send(command: command)
                                                             })
let registryMonitor = AgentSessionRegistryMonitor(hub: eventHub,
                                                  socketClient: socketClient,
                                                  ordinaryTmuxCarrierIdentityResolver: { record in
                                                      ordinaryTmuxCarrierResolver.carrierIdentity(for: record)
                                                  },
                                                  livePanelListProjector: { result in
                                                      ordinaryTmuxProjectionContext.projector.projectPanelListResult(result)
                                                  },
                                                  runtimeSyncer: codexRuntimeSyncer)
codexRuntimeSyncer.activeThreadHandler = { [weak registryMonitor] sessionID, threadID in
    registryMonitor?.appServerActiveThreadDidChange(sessionID: sessionID, threadID: threadID)
}
let runtimeResumeDescriptorSocketSender =
    TideyRuntimeResumeDescriptorSocketSender(
        requestSender: socketClient
    )
let runtimeResumeDescriptorPublisher = RuntimeResumeDescriptorPublisher(
    registryReader: AgentSessionRegistryRuntimeResumeReader(
        monitor: registryMonitor
    ),
    topologyReader: OrdinaryTmuxRuntimeResumeTopologyReader(
        registry: ordinaryTmuxProjectionContext.registry
    ),
    carrierPlanner: OrdinaryTmuxRuntimeResumeCarrierPlanner(
        registry: ordinaryTmuxProjectionContext.registry,
        sessionReader: OrdinaryTmuxCLIAdapter()
    ),
    inventoryReconciler: runtimeResumeDescriptorSocketSender,
    socketSender: runtimeResumeDescriptorSocketSender
)
let workspaceEventMonitor = TideyWorkspaceEventMonitor(locator: locator,
                                                       hub: workspaceEventHub,
                                                       paneIdentityReconciler: ordinaryTmuxPaneIdentityReconciler)
// Live three-state lifecycle patches share the workspace-event channel and
// the same aggregate revisions as the list snapshots.
let agentLifecycleEventPublisher = AgentLifecycleEventPublisher(store: AgentSessionLifecycle.store,
                                                                hub: workspaceEventHub)
agentLifecycleEventPublisher.attach()
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
                                     codexApprovalSubmitter: codexRuntimeSyncer,
                                     observability: observability,
                                     cloudflaredManager: cloudflaredManager,
                                     uploadGarbageCollector: uploadGarbageCollector,
                                     startRegistryMonitor: runtimeConfiguration.shouldStartRegistryMonitor,
                                     startCloudflaredSupervisor: runtimeConfiguration.shouldStartCloudflaredSupervisor,
                                     ordinaryTmuxProjectionContext: ordinaryTmuxProjectionContext)

do {
    if runtimeConfiguration.shouldStartBackgroundServices {
        workspaceEventMonitor.start()
        resolverPublicationMonitor.start()
        uploadGarbageCollector.start()
        runtimeResumeDescriptorPublisher.start()
    } else {
        BridgeLogger.server.info("bridge dev isolated mode enabled port=\(runtimeConfiguration.port, privacy: .public)")
    }
    try server.run()
} catch {
    fputs("RemoteBridge failed: \(error)\n", stderr)
    exit(1)
}
