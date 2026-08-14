import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOWebSocket

final class TideyRemoteBridgeServer {
    private static let maximumWebSocketFrameSizeBytes = 16 * 1024 * 1024

    private let host: String
    private let port: Int
    private let token: String
    private let authenticator: BridgeAuthenticator
    private let pairingController: BridgePairingController
    private let socketClient: TideySocketClient
    private let eventHub: AgentEventHub
    private let workspaceEventHub: WorkspaceEventHub
    private let registryMonitor: AgentSessionRegistryMonitor
    private let codexApprovalProvider: CodexAppServerApprovalPromptProviding?
    private let promptSubmitDeduper = InteractivePromptSubmitDeduper()
    private let observability: BridgeObservabilityCenter
    private let cloudflaredManager: BridgeCloudflaredManager
    private let uploadGarbageCollector: BridgeUploadGarbageCollector
    private let startRegistryMonitor: Bool
    private let startCloudflaredSupervisor: Bool
    private let interactivePTYActivation: TmuxInteractivePTYActivation
    private let ordinaryTmuxProjectionContext: OrdinaryTmuxProjectionContext
    private let requestSequencer: BridgeRequestSequencer
    private let terminalStreamLaneRegistry: OrdinaryTmuxTerminalStreamLaneRegistry
    private let terminalObserver: OrdinaryTmuxTerminalObserving
    private let group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)

    init(host: String = "0.0.0.0",
         port: Int = 4817,
         token: String,
         authenticator: BridgeAuthenticator,
         pairingController: BridgePairingController,
         socketClient: TideySocketClient,
         eventHub: AgentEventHub,
         workspaceEventHub: WorkspaceEventHub,
         registryMonitor: AgentSessionRegistryMonitor,
         codexApprovalSubmitter: CodexAppServerApprovalPromptProviding? = nil,
         terminalObserver: OrdinaryTmuxTerminalObserving = OrdinaryTmuxTerminalObserverRegistry(
            makeProcess: OrdinaryTmuxLiveControlModeProcess.factory()
         ),
         observability: BridgeObservabilityCenter,
         cloudflaredManager: BridgeCloudflaredManager = BridgeCloudflaredManager(),
         uploadGarbageCollector: BridgeUploadGarbageCollector = BridgeUploadGarbageCollector(uploadDirectory: BridgePaths().uploadsDirectory),
         startRegistryMonitor: Bool = true,
         startCloudflaredSupervisor: Bool = true,
         interactivePTYActivation: TmuxInteractivePTYActivation = .disabled,
         ordinaryTmuxProjectionContext: OrdinaryTmuxProjectionContext = OrdinaryTmuxProjectionContext(),
         requestSequencer: BridgeRequestSequencer = BridgeRequestSequencer(),
         terminalStreamLaneRegistry: OrdinaryTmuxTerminalStreamLaneRegistry = OrdinaryTmuxTerminalStreamLaneRegistry()) {
        self.host = host
        self.port = port
        self.token = token
        self.authenticator = authenticator
        self.pairingController = pairingController
        self.socketClient = socketClient
        self.eventHub = eventHub
        self.workspaceEventHub = workspaceEventHub
        self.registryMonitor = registryMonitor
        self.codexApprovalProvider = codexApprovalSubmitter
        self.observability = observability
        self.cloudflaredManager = cloudflaredManager
        self.uploadGarbageCollector = uploadGarbageCollector
        self.startRegistryMonitor = startRegistryMonitor
        self.startCloudflaredSupervisor = startCloudflaredSupervisor
        self.interactivePTYActivation = interactivePTYActivation
        self.ordinaryTmuxProjectionContext = ordinaryTmuxProjectionContext
        self.requestSequencer = requestSequencer
        self.terminalStreamLaneRegistry = terminalStreamLaneRegistry
        self.terminalObserver = terminalObserver
    }

    func run() throws {
        let handle = try start()
        try handle.waitUntilClosed()
    }

    func start() throws -> TideyRemoteBridgeServerHandle {
        if startRegistryMonitor {
            try registryMonitor.start()
        }
        if startCloudflaredSupervisor {
            cloudflaredManager.ensureSupervisorRunning()
        }
        let upgrader = NIOWebSocketServerUpgrader(
            maxFrameSize: Self.maximumWebSocketFrameSizeBytes,
            shouldUpgrade: { [authenticator] channel, head in
                let authHeader = head.headers.first(name: "Authorization")
                guard authenticator.isAuthorized(authorizationHeader: authHeader) else {
                    return channel.eventLoop.makeSucceededFuture(nil)
                }
                return channel.eventLoop.makeSucceededFuture([:])
            },
            upgradePipelineHandler: { [socketClient, eventHub, workspaceEventHub, registryMonitor, codexApprovalProvider, promptSubmitDeduper, observability, interactivePTYActivation, ordinaryTmuxProjectionContext, requestSequencer, terminalStreamLaneRegistry, terminalObserver, port, cloudflaredManager] channel, _ in
                channel.pipeline.addHandler(WebSocketFrameHandler(socketClient: socketClient,
                                                                  eventHub: eventHub,
                                                                  workspaceEventHub: workspaceEventHub,
                                                                  registryMonitor: registryMonitor,
                                                                  codexApprovalSubmitter: codexApprovalProvider,
                                                                  terminalObserver: terminalObserver,
                                                                  observability: observability,
                                                                  bridgePort: port,
                                                                  cloudflaredManager: cloudflaredManager,
                                                                  interactivePTYActivation: interactivePTYActivation,
                                                                  ordinaryTmuxProjectionContext: ordinaryTmuxProjectionContext,
                                                                  requestSequencer: requestSequencer,
                                                                  terminalStreamLaneRegistry: terminalStreamLaneRegistry,
                                                                  promptSubmitDeduper: promptSubmitDeduper))
            }
        )

        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 16)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { [token, authenticator, pairingController, port, registryMonitor, eventHub, observability, cloudflaredManager, uploadGarbageCollector] channel in
                let httpHandler = HTTPHandler(legacyPairToken: token,
                                              authenticator: authenticator,
                                              pairingController: pairingController,
                                              bridgePort: port,
                                              registryMonitor: registryMonitor,
                                              eventHub: eventHub,
                                              observability: observability,
                                              cloudflaredManager: cloudflaredManager,
                                              uploadGarbageCollector: uploadGarbageCollector)
                return channel.pipeline.configureHTTPServerPipeline(
                    withServerUpgrade: (
                        upgraders: [upgrader],
                        completionHandler: { _ in
                            channel.pipeline.removeHandler(httpHandler, promise: nil)
                        }
                    )
                ).flatMap {
                    channel.pipeline.addHandler(httpHandler)
                }
            }
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)

        let channel = try bootstrap.bind(host: host, port: port).wait()
        BridgeLogger.server.info("bridge listening ws_url=ws://\(self.host, privacy: .public):\(self.port) admin_url=http://\(self.host, privacy: .public):\(self.port)/admin/status")
        BridgeLogger.server.info("pair token hash=\(self.token, privacy: .private(mask: .hash))")
        return TideyRemoteBridgeServerHandle(channel: channel)
    }

    deinit {
        cloudflaredManager.stop()
        try? group.syncShutdownGracefully()
    }
}

struct TideyRemoteBridgeServerHandle {
    let port: Int
    private let channel: Channel

    fileprivate init(channel: Channel) {
        self.channel = channel
        self.port = channel.localAddress?.port ?? 0
    }

    func close() throws {
        try channel.close().wait()
    }

    func waitUntilClosed() throws {
        try channel.closeFuture.wait()
    }
}

private final class HTTPHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private struct BridgeAdminPairedDevicesResponse: Codable {
        let devices: [BridgePairedDevice]
    }

    private struct BridgeAdminRevokeDeviceRequest: Codable {
        let deviceID: String

        enum CodingKeys: String, CodingKey {
            case deviceID = "device_id"
        }
    }

    private struct BridgeAdminRevokeDeviceResponse: Codable {
        let revokedDeviceID: String

        enum CodingKeys: String, CodingKey {
            case revokedDeviceID = "revoked_device_id"
        }
    }

    private let legacyPairToken: String
    private let authenticator: BridgeAuthenticator
    private let pairingController: BridgePairingController
    private let bridgePort: Int
    private let registryMonitor: AgentSessionRegistryMonitor
    private let eventHub: AgentEventHub
    private let observability: BridgeObservabilityCenter
    private let cloudflaredManager: BridgeCloudflaredManager
    private let uploadGarbageCollector: BridgeUploadGarbageCollector
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var pendingHead: HTTPRequestHead?
    private var pendingBody: ByteBuffer?

    init(legacyPairToken: String,
         authenticator: BridgeAuthenticator,
         pairingController: BridgePairingController,
         bridgePort: Int,
         registryMonitor: AgentSessionRegistryMonitor,
         eventHub: AgentEventHub,
         observability: BridgeObservabilityCenter,
         cloudflaredManager: BridgeCloudflaredManager,
         uploadGarbageCollector: BridgeUploadGarbageCollector) {
        self.legacyPairToken = legacyPairToken
        self.authenticator = authenticator
        self.pairingController = pairingController
        self.bridgePort = bridgePort
        self.registryMonitor = registryMonitor
        self.eventHub = eventHub
        self.observability = observability
        self.cloudflaredManager = cloudflaredManager
        self.uploadGarbageCollector = uploadGarbageCollector
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        decoder.dateDecodingStrategy = .iso8601
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = unwrapInboundIn(data)
        switch part {
        case .head(let head):
            pendingHead = head
            pendingBody = context.channel.allocator.buffer(capacity: 0)
            if head.uri == "/admin/status" {
                respondToAdminStatus(head: head, context: context)
                clearPendingRequest()
                return
            }
            if requestPath(from: head.uri) == "/ws" {
                return
            }
        case .body(var body):
            pendingBody?.writeBuffer(&body)
        case .end:
            guard let head = pendingHead else { return }
            defer { clearPendingRequest() }
            handleHTTP(head: head, body: pendingBody, context: context)
        }
    }

    private func handleHTTP(head: HTTPRequestHead, body: ByteBuffer?, context: ChannelHandlerContext) {
        switch requestPath(from: head.uri) {
        case "/admin/pair_payload":
            respondToPairPayload(head: head, context: context)
        case "/admin/tunnel_status":
            respondToTunnelStatus(head: head, context: context)
        case "/admin/devices":
            respondToDeviceList(head: head, context: context)
        case "/admin/devices/revoke":
            respondToDeviceRevoke(head: head, body: body, context: context)
        case "/admin/uploads/stats":
            respondToUploadStats(head: head, context: context)
        case "/admin/uploads/sweep":
            respondToUploadSweep(head: head, context: context)
        case "/pair/exchange":
            respondToPairExchange(head: head, body: body, context: context)
        case "/ws":
            respondToWebSocketHTTPFallback(head: head, context: context)
        default:
            respond(status: .notFound, data: Data(), context: context, version: head.version)
        }
    }

    private func respondToWebSocketHTTPFallback(head: HTTPRequestHead, context: ChannelHandlerContext) {
        guard head.method == .GET else {
            respond(status: .methodNotAllowed, data: Data(), context: context, version: head.version)
            return
        }
        guard authenticator.isAuthorized(authorizationHeader: head.headers.first(name: "Authorization")) else {
            respond(status: .unauthorized, data: Data(), context: context, version: head.version)
            return
        }
        respond(status: .badRequest, data: Data(), context: context, version: head.version)
    }

    private func respondToPairPayload(head: HTTPRequestHead, context: ChannelHandlerContext) {
        guard authenticator.isLegacyTokenAuthorized(authorizationHeader: head.headers.first(name: "Authorization")) else {
            respond(status: .unauthorized, data: Data(), context: context, version: head.version)
            return
        }
        do {
            let endpoints = BridgeLANEndpointResolver.resolve(port: bridgePort)
            let tailscaleEndpoint = BridgeTailscaleEndpointResolver.resolve(port: bridgePort)
            cloudflaredManager.ensureSupervisorRunning()
            let tunnelStatus = cloudflaredManager.currentStatus()
            let payload = try pairingController.createPairPayload(lanEndpoints: endpoints,
                                                                  tailscaleEndpoint: tailscaleEndpoint,
                                                                  tunnelEndpoint: tunnelStatus.endpoint,
                                                                  resolverEndpoint: BridgeResolverConfiguration.resolverBaseURL())
            let data = try encoder.encode(payload)
            respond(status: .ok,
                    data: data,
                    context: context,
                    version: head.version,
                    contentType: "application/json")
        } catch {
            respond(error: BridgeInternalError.invalidRequest(error.localizedDescription).payload,
                    status: .badRequest,
                    context: context,
                    version: head.version)
        }
    }

    private func respondToTunnelStatus(head: HTTPRequestHead, context: ChannelHandlerContext) {
        guard head.method == .GET else {
            respond(status: .methodNotAllowed, data: Data(), context: context, version: head.version)
            return
        }
        guard authenticator.isLegacyTokenAuthorized(authorizationHeader: head.headers.first(name: "Authorization")) else {
            respond(status: .unauthorized, data: Data(), context: context, version: head.version)
            return
        }
        do {
            respond(status: .ok,
                    data: try encoder.encode(cloudflaredManager.currentStatus()),
                    context: context,
                    version: head.version,
                    contentType: "application/json")
        } catch {
            respond(error: BridgeInternalError.invalidRequest(error.localizedDescription).payload,
                    status: .badRequest,
                    context: context,
                    version: head.version)
        }
    }

    private func respondToDeviceList(head: HTTPRequestHead, context: ChannelHandlerContext) {
        guard head.method == .GET else {
            respond(status: .methodNotAllowed, data: Data(), context: context, version: head.version)
            return
        }
        guard authenticator.isLegacyTokenAuthorized(authorizationHeader: head.headers.first(name: "Authorization")) else {
            respond(status: .unauthorized, data: Data(), context: context, version: head.version)
            return
        }

        do {
            let response = BridgeAdminPairedDevicesResponse(devices: try pairingController.listDevices())
            respond(status: .ok,
                    data: try encoder.encode(response),
                    context: context,
                    version: head.version,
                    contentType: "application/json")
        } catch {
            respond(error: BridgeInternalError.invalidRequest(error.localizedDescription).payload,
                    status: .badRequest,
                    context: context,
                    version: head.version)
        }
    }

    private func respondToDeviceRevoke(head: HTTPRequestHead,
                                       body: ByteBuffer?,
                                       context: ChannelHandlerContext) {
        guard head.method == .POST else {
            respond(status: .methodNotAllowed, data: Data(), context: context, version: head.version)
            return
        }
        guard authenticator.isLegacyTokenAuthorized(authorizationHeader: head.headers.first(name: "Authorization")) else {
            respond(status: .unauthorized, data: Data(), context: context, version: head.version)
            return
        }

        do {
            var body = body ?? context.channel.allocator.buffer(capacity: 0)
            guard let text = body.readString(length: body.readableBytes),
                  let data = text.data(using: .utf8) else {
                throw BridgeInternalError.invalidRequest("device revoke requires a JSON request body")
            }
            let request = try decoder.decode(BridgeAdminRevokeDeviceRequest.self, from: data)
            guard request.deviceID.isEmpty == false else {
                throw BridgeInternalError.invalidRequest("device revoke requires device_id")
            }
            guard try pairingController.revokeDevice(deviceID: request.deviceID) else {
                throw BridgeInternalError.notFound("No paired device exists for device_id \(request.deviceID)")
            }
            let response = BridgeAdminRevokeDeviceResponse(revokedDeviceID: request.deviceID)
            respond(status: .ok,
                    data: try encoder.encode(response),
                    context: context,
                    version: head.version,
                    contentType: "application/json")
        } catch let error as BridgeInternalError {
            let status: HTTPResponseStatus = {
                switch error {
                case .notFound:
                    return .notFound
                default:
                    return .badRequest
                }
            }()
            respond(error: error.payload, status: status, context: context, version: head.version)
        } catch {
            respond(error: BridgeInternalError.invalidRequest(error.localizedDescription).payload,
                    status: .badRequest,
                    context: context,
                    version: head.version)
        }
    }

    private func respondToUploadStats(head: HTTPRequestHead, context: ChannelHandlerContext) {
        guard head.method == .GET else {
            respond(status: .methodNotAllowed, data: Data(), context: context, version: head.version)
            return
        }
        guard authenticator.isLegacyTokenAuthorized(authorizationHeader: head.headers.first(name: "Authorization")) else {
            respond(status: .unauthorized, data: Data(), context: context, version: head.version)
            return
        }

        do {
            respond(status: .ok,
                    data: try encoder.encode(uploadGarbageCollector.stats()),
                    context: context,
                    version: head.version,
                    contentType: "application/json")
        } catch {
            respond(error: BridgeInternalError.invalidRequest(error.localizedDescription).payload,
                    status: .badRequest,
                    context: context,
                    version: head.version)
        }
    }

    private func respondToUploadSweep(head: HTTPRequestHead, context: ChannelHandlerContext) {
        guard head.method == .POST else {
            respond(status: .methodNotAllowed, data: Data(), context: context, version: head.version)
            return
        }
        guard authenticator.isLegacyTokenAuthorized(authorizationHeader: head.headers.first(name: "Authorization")) else {
            respond(status: .unauthorized, data: Data(), context: context, version: head.version)
            return
        }

        do {
            let result = try uploadGarbageCollector.sweep()
            BridgeLogger.server.info("upload GC manual_sweep removed_files=\(result.removedFileCount, privacy: .public) freed_bytes=\(result.freedBytes, privacy: .public)")
            respond(status: .ok,
                    data: try encoder.encode(result),
                    context: context,
                    version: head.version,
                    contentType: "application/json")
        } catch {
            respond(error: BridgeInternalError.invalidRequest(error.localizedDescription).payload,
                    status: .badRequest,
                    context: context,
                    version: head.version)
        }
    }

    private func respondToPairExchange(head: HTTPRequestHead, body: ByteBuffer?, context: ChannelHandlerContext) {
        guard head.method == .POST else {
            respond(status: .methodNotAllowed, data: Data(), context: context, version: head.version)
            return
        }
        do {
            var body = body ?? context.channel.allocator.buffer(capacity: 0)
            guard let text = body.readString(length: body.readableBytes),
                  let data = text.data(using: .utf8) else {
                throw BridgeInternalError.invalidRequest("pair.exchange requires a JSON request body")
            }
            let request = try decoder.decode(BridgePairExchangeRequest.self, from: data)
            let result = try pairingController.exchange(request)
            let response = BridgeResponse(id: nil,
                                          ok: true,
                                          result: [
                                            "host_id": .string(result.hostID),
                                            "display_name": .string(result.displayName),
                                            "device_credential": .string(result.deviceCredential),
                                            "credential_type": .string(result.credentialType),
                                          ],
                                          error: nil)
            respond(status: .ok,
                    data: try encoder.encode(response),
                    context: context,
                    version: head.version,
                    contentType: "application/json")
        } catch let error as BridgeInternalError {
            let status: HTTPResponseStatus = {
                switch error {
                case .unauthorized:
                    return .unauthorized
                default:
                    return .badRequest
                }
            }()
            respond(error: error.payload, status: status, context: context, version: head.version)
        } catch {
            respond(error: BridgeInternalError.invalidRequest(error.localizedDescription).payload,
                    status: .badRequest,
                    context: context,
                    version: head.version)
        }
    }

    private func respondToAdminStatus(head: HTTPRequestHead, context: ChannelHandlerContext) {
        guard authenticator.isLegacyTokenAuthorized(authorizationHeader: head.headers.first(name: "Authorization")) else {
            respond(status: .unauthorized, data: Data(), context: context, version: head.version)
            return
        }

        let activeSessions = registryMonitor.activeSessionSnapshots()
        let eventSnapshots = Dictionary(uniqueKeysWithValues: eventHub.debugSnapshots().map { ($0.sessionID, $0) })
        let status = observability.snapshot(activeSessions: activeSessions.map { session in
            let eventSnapshot = eventSnapshots[session.sessionID]
            return BridgeActiveSessionStatus(vendor: session.vendor,
                                             workspaceID: session.workspaceID,
                                             sessionID: session.sessionID,
                                             panelID: session.panelID,
                                             restoreSessionID: session.restoreSessionID,
                                             bufferedEventCount: eventSnapshot?.bufferedEventCount ?? 0,
                                             oldestSeq: eventSnapshot?.oldestSeq,
                                             newestSeq: eventSnapshot?.newestSeq,
                                             isActive: eventSnapshot?.isActive ?? false)
        })
        let data = (try? encoder.encode(status)) ?? Data("{}".utf8)
        respond(status: .ok,
                data: data,
                context: context,
                version: head.version,
                contentType: "application/json")
    }

    private func respond(error: BridgeErrorPayload,
                         status: HTTPResponseStatus,
                         context: ChannelHandlerContext,
                         version: HTTPVersion) {
        let response = BridgeResponse(id: nil, ok: false, result: nil, error: error)
        let data = (try? encoder.encode(response)) ?? Data()
        respond(status: status,
                data: data,
                context: context,
                version: version,
                contentType: "application/json")
    }

    private func respond(status: HTTPResponseStatus,
                         data: Data,
                         context: ChannelHandlerContext,
                         version: HTTPVersion,
                         contentType: String? = nil) {
        var buffer = context.channel.allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)
        var headers = HTTPHeaders()
        if let contentType {
            headers.add(name: "content-type", value: contentType)
        }
        headers.add(name: "content-length", value: "\(data.count)")
        let response = HTTPResponseHead(version: version, status: status, headers: headers)
        context.write(wrapOutboundOut(.head(response)), promise: nil)
        if data.isEmpty == false {
            context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        }
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
    }

    private func clearPendingRequest() {
        pendingHead = nil
        pendingBody = nil
    }

    private func requestPath(from uri: String) -> String {
        String(uri.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
    }
}

typealias BridgeRequestExecutor = (@escaping () -> Void) -> Void
typealias TerminalStreamEventLoopScheduler = (EventLoop, @escaping () -> Void) -> Void

enum BridgeProtocolCapability {
    static let terminalStreamSubscriptionOwnership = "terminal_stream_subscription_ownership_v1"
    static let tmuxInteractive = TmuxInteractiveProtocolV1.capability
}

enum TmuxInteractivePTYActivation: Sendable {
    case disabled
    case enabled(TmuxInteractivePTYSessionCandidateBuilder)

    var candidateBuilder: TmuxInteractivePTYSessionCandidateBuilder? {
        switch self {
        case .disabled:
            return nil
        case .enabled(let candidateBuilder):
            return candidateBuilder
        }
    }

    var protocolCapabilities: [String] {
        switch self {
        case .disabled:
            return []
        case .enabled:
            return [BridgeProtocolCapability.tmuxInteractive]
        }
    }
}

final class WebSocketFrameHandler: ChannelInboundHandler {
    typealias InboundIn = WebSocketFrame
    typealias OutboundOut = WebSocketFrame

    private enum InteractivePTYRoutingError: Error {
        case connectionUnavailable
        case superseded
    }

    private struct InteractivePTYPumpEntry {
        let binding: TmuxInteractiveSubscriptionBinding
        let session: TmuxInteractivePTYConnectionSession
        let outputPump: TmuxInteractivePTYEventPump
        let inputPump: TmuxInteractivePTYInputPump
        let resizePump: TmuxInteractivePTYResizePump
    }

    private final class TerminalStreamDeltaSender: @unchecked Sendable {
        private weak var handler: WebSocketFrameHandler?
        private weak var context: ChannelHandlerContext?
        private let schedule: TerminalStreamEventLoopScheduler

        init(handler: WebSocketFrameHandler,
             context: ChannelHandlerContext,
             schedule: @escaping TerminalStreamEventLoopScheduler) {
            self.handler = handler
            self.context = context
            self.schedule = schedule
        }

        func send(_ envelope: TerminalStreamDeltaEnvelope,
                  allowedIf isStillAccepted: @escaping @Sendable () -> Bool) {
            guard let handler, let context else {
                return
            }
            guard isStillAccepted() else {
                return
            }
            schedule(context.eventLoop) { [weak handler, weak context] in
                guard let handler, let context, isStillAccepted() else {
                    return
                }
                handler.send(terminalStreamEnvelope: envelope, to: context)
            }
        }
    }

    private final class TerminalStreamLaneResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var storedResult: Result<OrdinaryTmuxTerminalStreamLaneCandidate, Error>??

        func store(_ result: Result<OrdinaryTmuxTerminalStreamLaneCandidate, Error>?) {
            lock.lock()
            storedResult = .some(result)
            lock.unlock()
        }

        var result: Result<OrdinaryTmuxTerminalStreamLaneCandidate, Error>?? {
            lock.lock()
            defer { lock.unlock() }
            return storedResult
        }
    }

    private final class TerminalStreamConnectionCallbackTarget: @unchecked Sendable {
        private weak var handler: WebSocketFrameHandler?
        private let eventLoop: EventLoop
        private let schedule: TerminalStreamEventLoopScheduler

        init(handler: WebSocketFrameHandler,
             context: ChannelHandlerContext,
             schedule: @escaping TerminalStreamEventLoopScheduler) {
            self.handler = handler
            self.eventLoop = context.eventLoop
            self.schedule = schedule
        }

        func removeIfOwned(panelID: String, token: UInt64) {
            schedule(eventLoop) { [weak handler] in
                guard let handler,
                      handler.terminalStreamConnectionState.removeIfOwned(panelID: panelID,
                                                                          token: token) else {
                    return
                }
                handler.publishTerminalStreamSubscriptionCount()
            }
        }
    }

    private final class InteractivePTYWorkExecutor: @unchecked Sendable {
        private let execute: BridgeRequestExecutor

        init(execute: @escaping BridgeRequestExecutor) {
            self.execute = execute
        }

        func submit(_ work: @escaping @Sendable () -> Void) {
            execute(work)
        }
    }

    private final class InteractivePTYConnectionCallbackTarget:
        @unchecked Sendable
    {
        private weak var handler: WebSocketFrameHandler?
        private weak var context: ChannelHandlerContext?
        private let eventLoop: EventLoop

        init(
            handler: WebSocketFrameHandler,
            context: ChannelHandlerContext
        ) {
            self.handler = handler
            self.context = context
            eventLoop = context.eventLoop
        }

        func scheduleRetry(
            _ work: @escaping @Sendable () -> Void,
            closeSession: @escaping @Sendable () -> Void
        ) {
            guard context != nil else {
                closeSession()
                return
            }
            _ = eventLoop.scheduleTask(in: .milliseconds(10), work)
        }

        func deliver(
            _ event: TmuxInteractivePTYEvent,
            binding: TmuxInteractiveSubscriptionBinding,
            session: TmuxInteractivePTYConnectionSession,
            completion: @escaping TmuxInteractivePTYEventPump.DeliveryCompletion
        ) {
            eventLoop.execute { [weak self] in
                guard let self,
                      let handler = self.handler,
                      let context = self.context else {
                    completion(.failure(
                        InteractivePTYRoutingError.connectionUnavailable
                    ))
                    return
                }
                guard handler.interactivePTYConnectionState.owner(for: binding)
                        === session else {
                    completion(.failure(
                        InteractivePTYRoutingError.superseded
                    ))
                    return
                }
                handler.send(
                    interactivePTYEvent: event,
                    to: context,
                    afterWrite: { result in
                        self.completeDelivery(
                            result,
                            event: event,
                            binding: binding,
                            session: session,
                            completion: completion
                        )
                    }
                )
            }
        }

        private func completeDelivery(
            _ result: Result<Void, Error>,
            event: TmuxInteractivePTYEvent,
            binding: TmuxInteractiveSubscriptionBinding,
            session: TmuxInteractivePTYConnectionSession,
            completion: @escaping TmuxInteractivePTYEventPump.DeliveryCompletion
        ) {
            if case .success = result,
               case .start = event {
                guard let handler,
                      handler.activateInteractivePTYMutationPumps(
                        binding: binding,
                        session: session
                      ) else {
                    completion(.failure(
                        InteractivePTYRoutingError.superseded
                    ))
                    return
                }
            }
            completion(result)
        }

        func stopped(
            error: Error?,
            binding: TmuxInteractiveSubscriptionBinding,
            session: TmuxInteractivePTYConnectionSession,
            closeSession: @escaping @Sendable () -> Void
        ) {
            eventLoop.execute { [weak self] in
                guard let self,
                      let handler = self.handler,
                      let context = self.context else {
                    closeSession()
                    return
                }
                handler.finishInteractivePTYPump(
                    binding: binding,
                    session: session,
                    error: error,
                    context: context,
                    closeSession: closeSession
                )
            }
        }
    }

    enum CommitOutcome: Equatable {
        case accepted
        case rejected(reason: String)
        case failed(code: String, reason: String)
    }

    struct LocalRequestResult {
        let response: BridgeResponse
        let agentReplayEnvelopes: [AgentEventEnvelope]
        let workspaceReplayEnvelopes: [WorkspaceEventEnvelope]

        let agentLiveGate: BridgeAgentEventReplayGate?
        let applyOnEventLoop: (() -> CommitOutcome)?
        let afterAcceptedResponseEnqueued: (() -> Void)?

        init(response: BridgeResponse,
             agentReplayEnvelopes: [AgentEventEnvelope],
             workspaceReplayEnvelopes: [WorkspaceEventEnvelope],
             agentLiveGate: BridgeAgentEventReplayGate? = nil,
             applyOnEventLoop: (() -> CommitOutcome)? = nil,
             afterAcceptedResponseEnqueued: (() -> Void)? = nil) {
            self.response = response
            self.agentReplayEnvelopes = agentReplayEnvelopes
            self.workspaceReplayEnvelopes = workspaceReplayEnvelopes
            self.agentLiveGate = agentLiveGate
            self.applyOnEventLoop = applyOnEventLoop
            self.afterAcceptedResponseEnqueued = afterAcceptedResponseEnqueued
        }
    }

    private let socketClient: TideySocketClient
    private let eventHub: AgentEventHub
    private let workspaceEventHub: WorkspaceEventHub
    private let registryMonitor: AgentSessionRegistryMonitor
    private let lifecycleStore: AgentSessionLifecycleStore
    private let codexApprovalProvider: CodexAppServerApprovalPromptProviding?
    private let observability: BridgeObservabilityCenter
    private let bridgePort: Int
    private let cloudflaredManager: BridgeCloudflaredManager
    private let connectionID: String
    private let now: @Sendable () -> Date
    private let requestExecutor: BridgeRequestExecutor
    private let terminalStreamEventLoopScheduler: TerminalStreamEventLoopScheduler
    private let interactivePTYActivation: TmuxInteractivePTYActivation
    private let ordinaryTmuxPanelRegistry: OrdinaryTmuxPanelRegistry
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let ordinaryTmuxRouteResolver: OrdinaryTmuxRouteResolver
    private let inputActionHandler: BridgeInputActionHandler
    private let fileActionHandler: BridgeFileActionHandler
    private let ordinaryTmuxRecentOutputHandler: OrdinaryTmuxRecentOutputHandler
    private let ordinaryTmuxOutputStreamHandler: OrdinaryTmuxOutputStreaming
    private let requestSequencer: BridgeRequestSequencer
    private let terminalStreamLaneRegistry: OrdinaryTmuxTerminalStreamLaneRegistry
    private let terminalStreamConnectionAdmission: TerminalStreamConnectionAdmission
    private let interactivePromptActionHandler: InteractivePromptActionHandler
    private let imageUploadHandler: BridgeImageUploadHandler
    private let imageReadHandler: BridgeImageReadHandler
    private let ordinaryTmuxPanelProjector: OrdinaryTmuxPanelProjector
    private var agentSubscriptions = BridgeAgentSubscriptionSlots()
    private var workspaceSubscriptionID: UUID?
    private var terminalStreamConnectionState = TerminalStreamConnectionState()
    private var interactivePTYConnectionState =
        TmuxInteractivePTYConnectionState<TmuxInteractivePTYConnectionSession>()
    private var interactivePTYPumps = [String: InteractivePTYPumpEntry]()
    private var connectedAt: Date?
    private var didRecordConnection = false
    private var didRecordDisconnect = false

    init(socketClient: TideySocketClient,
         eventHub: AgentEventHub,
         workspaceEventHub: WorkspaceEventHub,
         registryMonitor: AgentSessionRegistryMonitor,
         codexApprovalSubmitter: CodexAppServerApprovalPromptProviding? = nil,
         terminalObserver: OrdinaryTmuxTerminalObserving? = nil,
         observability: BridgeObservabilityCenter,
         bridgePort: Int,
         cloudflaredManager: BridgeCloudflaredManager,
         connectionID: String = UUID().uuidString,
         now: @escaping @Sendable () -> Date = { Date() },
         requestExecutor: @escaping BridgeRequestExecutor = { work in
             DispatchQueue.global(qos: .userInitiated).async {
                 work()
             }
         },
         terminalStreamEventLoopScheduler: @escaping TerminalStreamEventLoopScheduler = { eventLoop, work in
             eventLoop.execute(work)
         },
         interactivePTYActivation: TmuxInteractivePTYActivation = .disabled,
         ordinaryTmuxProjectionContext: OrdinaryTmuxProjectionContext = OrdinaryTmuxProjectionContext(),
         ordinaryTmuxOutputStreamHandler: OrdinaryTmuxOutputStreaming? = nil,
         requestSequencer: BridgeRequestSequencer = BridgeRequestSequencer(),
         terminalStreamLaneRegistry: OrdinaryTmuxTerminalStreamLaneRegistry = OrdinaryTmuxTerminalStreamLaneRegistry(),
         terminalStreamConnectionAdmission: TerminalStreamConnectionAdmission = TerminalStreamConnectionAdmission(),
         promptSubmitDeduper: InteractivePromptSubmitDeduper = InteractivePromptSubmitDeduper(),
         lifecycleStore: AgentSessionLifecycleStore = AgentSessionLifecycle.store) {
        self.socketClient = socketClient
        self.eventHub = eventHub
        self.workspaceEventHub = workspaceEventHub
        self.registryMonitor = registryMonitor
        self.lifecycleStore = lifecycleStore
        self.codexApprovalProvider = codexApprovalSubmitter
        self.observability = observability
        self.bridgePort = bridgePort
        self.cloudflaredManager = cloudflaredManager
        self.connectionID = connectionID
        self.now = now
        self.requestExecutor = requestExecutor
        self.terminalStreamEventLoopScheduler = terminalStreamEventLoopScheduler
        self.interactivePTYActivation = interactivePTYActivation
        self.ordinaryTmuxPanelRegistry = ordinaryTmuxProjectionContext.registry
        self.ordinaryTmuxPanelProjector = ordinaryTmuxProjectionContext.projector
        let routeResolver = OrdinaryTmuxRouteResolver(registry: ordinaryTmuxProjectionContext.registry)
        self.ordinaryTmuxRouteResolver = routeResolver
        self.inputActionHandler = BridgeInputActionHandler(socketSender: socketClient,
                                                           sessionResolver: registryMonitor,
                                                           codexAppServerChatSubmitter: codexApprovalSubmitter as? CodexAppServerChatSubmitting,
                                                           ordinaryTmuxInputRouter: OrdinaryTmuxInputRouter(
                                                            routeResolver: routeResolver,
                                                            inputSubmissionStore: ordinaryTmuxProjectionContext.inputSubmissionStore
                                                           ),
                                                           chatSubmitEchoRegistry: registryMonitor.chatSubmitEchoRegistry)
        self.fileActionHandler = BridgeFileActionHandler(rootResolver: TideyPanelFileRootResolver(socketSender: socketClient,
                                                                                                  ordinaryTmuxRouteResolver: routeResolver))
        self.ordinaryTmuxRecentOutputHandler = OrdinaryTmuxRecentOutputHandler(routeResolver: routeResolver)
        self.ordinaryTmuxOutputStreamHandler = ordinaryTmuxOutputStreamHandler ?? OrdinaryTmuxOutputStreamHandler(
            routeResolver: routeResolver,
            terminalObserver: terminalObserver
        )
        self.requestSequencer = requestSequencer
        self.terminalStreamLaneRegistry = terminalStreamLaneRegistry
        self.terminalStreamConnectionAdmission = terminalStreamConnectionAdmission
        self.interactivePromptActionHandler = InteractivePromptActionHandler(routeResolver: routeResolver,
                                                                            sessionResolver: registryMonitor,
                                                                            eventHub: eventHub,
                                                                            inputActionHandler: inputActionHandler,
                                                                            codexApprovalSubmitter: codexApprovalSubmitter,
                                                                            submitDeduper: promptSubmitDeduper)
        self.imageUploadHandler = BridgeImageUploadHandler(destinationResolver: ApplicationSupportImageUploadDestinationResolver(),
                                                           filenameGenerator: TimestampedImageUploadFilenameGenerator())
        self.imageReadHandler = BridgeImageReadHandler(rootResolver: TideyPanelFileRootResolver(socketSender: socketClient,
                                                                                                ordinaryTmuxRouteResolver: routeResolver))
    }

    func handlerAdded(context: ChannelHandlerContext) {
        recordConnectionStartedIfNeeded()
    }

    func channelActive(context: ChannelHandlerContext) {
        recordConnectionStartedIfNeeded()
        context.fireChannelActive()
    }

    private func recordConnectionStartedIfNeeded() {
        guard !didRecordConnection else {
            return
        }
        let timestamp = now()
        connectedAt = timestamp
        didRecordConnection = true
        didRecordDisconnect = false
        publishTerminalStreamSubscriptionCount()
        recordConnectionEvent(kind: .connected, timestamp: timestamp)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)
        switch frame.opcode {
        case .connectionClose:
            var closeData = frame.unmaskedData
            let closeCode = closeData.readInteger(as: UInt16.self).map(Int.init)
            recordConnectionEvent(kind: .peerClose,
                                  closeCode: closeCode,
                                  reasonByteCount: closeData.readableBytes)
            context.close(promise: nil)
        case .ping:
            var buffer = context.channel.allocator.buffer(capacity: frame.data.readableBytes)
            var data = frame.unmaskedData
            buffer.writeBuffer(&data)
            let pong = WebSocketFrame(fin: true, opcode: .pong, data: buffer)
            write(frame: pong,
                  messageType: "pong",
                  byteCount: buffer.readableBytes,
                  to: context)
        case .text:
            let receiptSequence = requestSequencer.next()
            var data = frame.unmaskedData
            guard let text = data.readString(length: data.readableBytes) else {
                send(response: BridgeResponse(id: nil, ok: false, result: nil, error: BridgeInternalError.invalidRequest("Invalid UTF-8 message.").payload),
                     messageType: "response.invalid_utf8",
                     to: context)
                return
            }
            let inboundByteCount = text.utf8.count
            requestExecutor { [decoder, socketClient] in
                let response: BridgeResponse
                var agentReplayEnvelopes = [AgentEventEnvelope]()
                var workspaceReplayEnvelopes = [WorkspaceEventEnvelope]()
                var agentLiveGate: BridgeAgentEventReplayGate?
                var applyOnEventLoop: (() -> CommitOutcome)?
                var afterAcceptedResponseEnqueued: (() -> Void)?
                var responseMessageType = "response.invalid_request"
                var requestID: String?
                var requestAction: String?
                do {
                    let decodeStartedAt = CFAbsoluteTimeGetCurrent()
                    let request = try decoder.decode(BridgeRequest.self, from: Data(text.utf8))
                    requestID = request.id
                    requestAction = request.action
                    self.observability.recordPayload(direction: .inbound,
                                                     messageType: "request.\(request.action)",
                                                     byteCount: inboundByteCount,
                                                     durationMs: (CFAbsoluteTimeGetCurrent() - decodeStartedAt) * 1000)
                    responseMessageType = "response.\(request.action)"
                    if request.action == "image_upload" {
                        BridgeImageUploadDiagnostics.log("server received request_id=\(request.id) action=\(request.action) params_keys=\(request.params?.keys.sorted().joined(separator: ",") ?? "-") base64_length=\(request.params?["data_base64"]?.stringValue?.count ?? 0)")
                    }
                    if let localResult = self.handleLocalRequest(request,
                                                                context: context,
                                                                receiptSequence: receiptSequence) {
                        response = localResult.response
                        agentReplayEnvelopes = localResult.agentReplayEnvelopes
                        workspaceReplayEnvelopes = localResult.workspaceReplayEnvelopes
                        agentLiveGate = localResult.agentLiveGate
                        applyOnEventLoop = localResult.applyOnEventLoop
                        afterAcceptedResponseEnqueued = localResult.afterAcceptedResponseEnqueued
                    } else {
                        response = self.augment(response: try socketClient.send(request), for: request)
                    }
                } catch let error as BridgeInternalError {
                    self.observability.recordPayload(direction: .inbound,
                                                     messageType: "request.invalid",
                                                     byteCount: inboundByteCount,
                                                     durationMs: 0)
                    if let requestID, let requestAction {
                        BridgeLogger.server.error("request failed action=\(requestAction, privacy: .public) request_id=\(requestID, privacy: .public) code=\(error.payload.code, privacy: .public) message=\(error.payload.message, privacy: .public)")
                    }
                    response = BridgeResponse(id: requestID, ok: false, result: nil, error: error.payload)
                } catch let error as DecodingError {
                    self.observability.recordPayload(direction: .inbound,
                                                     messageType: "request.invalid_json",
                                                     byteCount: inboundByteCount,
                                                     durationMs: 0)
                    response = BridgeResponse(id: nil, ok: false, result: nil, error: BridgeInternalError.invalidRequest(error.localizedDescription).payload)
                } catch {
                    response = BridgeResponse(id: nil, ok: false, result: nil, error: BridgeErrorPayload(code: "bridge_error", message: error.localizedDescription))
                }
                context.eventLoop.execute {
                    let responseToSend: BridgeResponse
                    let shouldReplay: Bool
                    switch applyOnEventLoop?() ?? .accepted {
                    case .accepted:
                        responseToSend = response
                        shouldReplay = true
                    case .rejected(let reason):
                        responseToSend = BridgeResponse(
                            id: response.id,
                            ok: false,
                            result: nil,
                            error: BridgeErrorPayload(code: "superseded", message: reason)
                        )
                        shouldReplay = false
                    case .failed(let code, let reason):
                        responseToSend = BridgeResponse(
                            id: response.id,
                            ok: false,
                            result: nil,
                            error: BridgeErrorPayload(code: code, message: reason)
                        )
                        shouldReplay = false
                    }
                    self.send(response: responseToSend,
                              messageType: responseMessageType,
                              to: context,
                              afterEnqueued: shouldReplay ? afterAcceptedResponseEnqueued : nil)
                    guard shouldReplay else {
                        return
                    }
                    for envelope in agentReplayEnvelopes {
                        self.send(envelope: envelope, to: context)
                    }
                    for envelope in workspaceReplayEnvelopes {
                        self.send(workspaceEnvelope: envelope, to: context)
                    }
                    if let agentLiveGate {
                        for envelope in BridgePendingApprovalFetchMerge.openLiveGate(
                            agentLiveGate,
                            afterReplaying: agentReplayEnvelopes) {
                            self.send(envelope: envelope, to: context)
                        }
                    }
                }
            }
        default:
            break
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        let interactivePTYOutputPumpsToStop =
            interactivePTYPumps.values.map(\.outputPump)
        let interactivePTYInputPumpsToStop =
            interactivePTYPumps.values.map(\.inputPump)
        let interactivePTYResizePumpsToStop =
            interactivePTYPumps.values.map(\.resizePump)
        interactivePTYPumps.removeAll(keepingCapacity: false)
        let interactivePTYSessions = interactivePTYConnectionState.retire()
        for pump in interactivePTYOutputPumpsToStop {
            pump.stop()
        }
        for pump in interactivePTYInputPumpsToStop {
            pump.stop()
        }
        for pump in interactivePTYResizePumpsToStop {
            pump.stop()
        }
        let cleanupConnectionID = connectionID
        for session in interactivePTYSessions {
            requestExecutor {
                do {
                    try session.close()
                } catch {
                    BridgeLogger.server.error(
                        "interactive PTY connection cleanup failed connection_id=\(cleanupConnectionID, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
                    )
                }
            }
        }
        terminalStreamConnectionAdmission.retire()
        if !didRecordDisconnect {
            let timestamp = now()
            let durationMs = connectedAt.map { timestamp.timeIntervalSince($0) * 1_000 }
            let terminalRetirement = terminalStreamConnectionState.retire()
            recordConnectionEvent(kind: .disconnected,
                                  timestamp: timestamp,
                                  durationMs: durationMs,
                                  terminalStreamSubscriptionCount: terminalRetirement.preRetireCount)
            didRecordDisconnect = true
            publishTerminalStreamSubscriptionCount()
            releaseTerminalStreamLeases(terminalRetirement.leases)
        }
        unsubscribeFromAgentEvents()
        unsubscribeFromWorkspaceEvents()
        observability.clearActiveTerminalStreamSubscriptionCount(forConnectionID: connectionID)
        context.fireChannelInactive()
    }

    func installInteractivePTYOwner(
        binding: TmuxInteractiveSubscriptionBinding,
        owner: TmuxInteractivePTYSessionOwner
    ) -> Bool {
        interactivePTYConnectionState.install(
            binding: binding,
            owner: TmuxInteractivePTYConnectionSession(
                binding: binding,
                owner: owner
            )
        )
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        let bridgedError = error as NSError
        recordConnectionEvent(kind: .channelError,
                              errorType: String(reflecting: type(of: error)),
                              errorDomain: bridgedError.domain,
                              errorCode: bridgedError.code)
        context.fireErrorCaught(error)
    }

    private func recordConnectionEvent(kind: BridgeConnectionEventKind,
                                       timestamp: Date? = nil,
                                       durationMs: Double? = nil,
                                       closeCode: Int? = nil,
                                       reasonByteCount: Int? = nil,
                                       errorType: String? = nil,
                                       errorDomain: String? = nil,
                                       errorCode: Int? = nil,
                                       messageType: String? = nil,
                                       byteCount: Int? = nil,
                                       terminalStreamSubscriptionCount: Int? = nil) {
        observability.recordConnectionEvent(
            BridgeConnectionEventSnapshot(
                connectionID: connectionID,
                kind: kind,
                timestamp: timestamp ?? now(),
                durationMs: durationMs,
                closeCode: closeCode,
                reasonByteCount: reasonByteCount,
                errorType: errorType,
                errorDomain: errorDomain,
                errorCode: errorCode,
                messageType: messageType,
                byteCount: byteCount,
                terminalStreamSubscriptionCount: terminalStreamSubscriptionCount ?? terminalStreamConnectionState.count,
                agentSubscriptionCount: agentSubscriptions.count,
                workspaceSubscriptionCount: workspaceSubscriptionID == nil ? 0 : 1
            )
        )
    }

    func handleLocalRequest(_ request: BridgeRequest,
                            context: ChannelHandlerContext) -> LocalRequestResult? {
        handleLocalRequest(request,
                           context: context,
                           receiptSequence: requestSequencer.next())
    }

    func handleLocalRequest(_ request: BridgeRequest,
                            context: ChannelHandlerContext,
                            receiptSequence: UInt64) -> LocalRequestResult? {
        do {
            if interactivePTYActivation.candidateBuilder != nil,
               let action = try TmuxInteractiveWireCodec.decode(request) {
                return try handleInteractivePTYRequest(
                    action,
                    request: request,
                    context: context
                )
            }
            if request.action == "image_upload" {
                BridgeImageUploadDiagnostics.log("local dispatch enter request_id=\(request.id)")
            }
            if let response = try inputActionHandler.handle(request) {
                if request.action == "image_upload" {
                    BridgeImageUploadDiagnostics.log("local dispatch handled_by=input request_id=\(request.id)")
                }
                return LocalRequestResult(response: response,
                                          agentReplayEnvelopes: [],
                                          workspaceReplayEnvelopes: [])
            }
            if let response = try fileActionHandler.handle(request) {
                if request.action == "image_upload" {
                    BridgeImageUploadDiagnostics.log("local dispatch handled_by=file request_id=\(request.id)")
                }
                return LocalRequestResult(response: response,
                                          agentReplayEnvelopes: [],
                                          workspaceReplayEnvelopes: [])
            }
            if let response = try ordinaryTmuxRecentOutputHandler.handle(request) {
                return LocalRequestResult(response: response,
                                          agentReplayEnvelopes: [],
                                          workspaceReplayEnvelopes: [])
            }
            if let response = try interactivePromptActionHandler.handle(request) {
                return LocalRequestResult(response: response,
                                          agentReplayEnvelopes: [],
                                          workspaceReplayEnvelopes: [])
            }
            if let response = try imageUploadHandler.handle(request) {
                BridgeImageUploadDiagnostics.log("local dispatch handled_by=image_upload request_id=\(request.id) ok=\(response.ok)")
                return LocalRequestResult(response: response,
                                          agentReplayEnvelopes: [],
                                          workspaceReplayEnvelopes: [])
            }
            if let response = try imageReadHandler.handle(request) {
                return LocalRequestResult(response: response,
                                          agentReplayEnvelopes: [],
                                          workspaceReplayEnvelopes: [])
            }
        } catch let bridgeError as BridgeInternalError {
            if request.action == "image_upload" {
                BridgeImageUploadDiagnostics.log("local dispatch bridge_error request_id=\(request.id) code=\(bridgeError.payload.code) message=\(bridgeError.payload.message)")
            }
            return LocalRequestResult(response: BridgeResponse(id: request.id,
                                                               ok: false,
                                                               result: nil,
                                                               error: bridgeError.payload),
                                      agentReplayEnvelopes: [],
                                      workspaceReplayEnvelopes: [])
        } catch {
            if request.action == "image_upload" {
                BridgeImageUploadDiagnostics.log("local dispatch error request_id=\(request.id) error=\(error)")
            }
            return LocalRequestResult(response: BridgeResponse(id: request.id,
                                                               ok: false,
                                                               result: nil,
                                                               error: BridgeErrorPayload(code: "bridge_error", message: error.localizedDescription)),
                                      agentReplayEnvelopes: [],
                                      workspaceReplayEnvelopes: [])
        }

        switch request.action {
        case "get_connection_endpoints":
            let lanEndpoints = BridgeLANEndpointResolver.resolve(port: bridgePort)
            let tailscaleEndpoint = BridgeTailscaleEndpointResolver.resolve(port: bridgePort)
            let tunnelEndpoint = cloudflaredManager.currentStatus().endpoint
            let connectionCapabilities: [JSONValue] = [
                .string("image_read_v1"),
                .string(BridgeProtocolCapability.terminalStreamSubscriptionOwnership),
            ] + interactivePTYActivation.protocolCapabilities.map(JSONValue.string)
            return LocalRequestResult(
                response: BridgeResponse(id: request.id,
                                         ok: true,
                                         result: [
                                            "lan_endpoints": .array(lanEndpoints.map(Self.jsonValue(for:))),
                                            "tailscale_endpoint": tailscaleEndpoint.map(Self.jsonValue(for:)) ?? .null,
                                            "tunnel_endpoint": tunnelEndpoint.map(Self.jsonValue(for:)) ?? .null,
                                            "resolver_endpoint": .string(BridgeResolverConfiguration.resolverBaseURL().absoluteString),
                                            "capabilities": .array(connectionCapabilities),
                                         ],
                                         error: nil),
                agentReplayEnvelopes: [],
                workspaceReplayEnvelopes: []
            )

        case "publish_codex_status_snapshot":
            guard let workspaceID = request.params?["workspace_id"]?.stringValue,
                  let panelID = request.params?["panel_id"]?.stringValue else {
                return LocalRequestResult(
                    response: BridgeResponse(id: request.id,
                                             ok: false,
                                             result: nil,
                                             error: BridgeInternalError.invalidRequest("publish_codex_status_snapshot requires workspace_id and panel_id").payload),
                    agentReplayEnvelopes: [],
                    workspaceReplayEnvelopes: []
                )
            }
            let requestedSessionID = canonicalAgentEventSessionID(request.params?["session_id"]?.stringValue)
            guard let activeSession = registryMonitor.activeSessionForPanel(workspaceID: workspaceID,
                                                                            panelID: panelID) else {
                return LocalRequestResult(
                    response: BridgeResponse(id: request.id,
                                             ok: false,
                                             result: nil,
                                             error: BridgeInternalError.invalidRequest("No active agent session for panel.").payload),
                    agentReplayEnvelopes: [],
                    workspaceReplayEnvelopes: []
                )
            }
            guard activeSession.vendor == "codex" else {
                return LocalRequestResult(
                    response: BridgeResponse(id: request.id,
                                             ok: false,
                                             result: nil,
                                             error: BridgeInternalError.invalidRequest("Native /status is only available for Codex panels.").payload),
                    agentReplayEnvelopes: [],
                    workspaceReplayEnvelopes: []
                )
            }
            if let requestedSessionID, requestedSessionID != activeSession.sessionID {
                return LocalRequestResult(
                    response: BridgeResponse(id: request.id,
                                             ok: false,
                                             result: nil,
                                             error: BridgeInternalError.invalidRequest("publish_codex_status_snapshot session_id does not match the active panel session").payload),
                    agentReplayEnvelopes: [],
                    workspaceReplayEnvelopes: []
                )
            }
            guard let record = registryMonitor.activeRecord(sessionID: activeSession.sessionID) else {
                return LocalRequestResult(
                    response: BridgeResponse(id: request.id,
                                             ok: false,
                                             result: nil,
                                             error: BridgeInternalError.invalidRequest("Codex registry record is unavailable.").payload),
                    agentReplayEnvelopes: [],
                    workspaceReplayEnvelopes: []
                )
            }
            do {
                let snapshot = try CodexStatusSnapshotReader().read(transcriptPath: record.transcriptPath,
                                                                    fallbackSessionID: activeSession.sessionID,
                                                                    fallbackCWD: record.cwd)
                let seq = eventHub.nextSyntheticSeq(sessionID: activeSession.sessionID)
                let eventID = "codex-status:\(activeSession.sessionID):\(seq)"
                let event = AgentEvent(eventID: eventID,
                                       seq: seq,
                                       vendor: "codex",
                                       workspaceID: workspaceID,
                                       sessionID: activeSession.sessionID,
                                       timestamp: Self.iso8601Now(),
                                       type: .assistantMessage,
                                       role: "assistant",
                                       text: snapshot.markdownSummary,
                                       name: nil,
                                       input: nil,
                                       output: nil,
                                       toolCallID: nil,
                                       metadata: [
                                        "panel_id": panelID,
                                        "tidey_generated": "codex_status",
                                        "slash_command": "/status",
                                        "tokens_in_context": String(snapshot.tokensInContext),
                                        "context_window": String(snapshot.contextWindow),
                                        "percent_remaining": String(snapshot.percentRemaining),
                                        "snapshot_timestamp": snapshot.timestamp,
                                       ])
                eventHub.publish(event)
                return LocalRequestResult(
                    response: BridgeResponse(id: request.id,
                                             ok: true,
                                             result: [
                                                "published": .bool(true),
                                                "event_id": .string(eventID),
                                                "tokens_in_context": .number(Double(snapshot.tokensInContext)),
                                                "context_window": .number(Double(snapshot.contextWindow)),
                                                "percent_remaining": .number(Double(snapshot.percentRemaining)),
                                             ],
                                             error: nil),
                    agentReplayEnvelopes: [],
                    workspaceReplayEnvelopes: []
                )
            } catch {
                return LocalRequestResult(
                    response: BridgeResponse(id: request.id,
                                             ok: false,
                                             result: nil,
                                             error: BridgeErrorPayload(code: "codex_status_unavailable",
                                                                       message: error.localizedDescription)),
                    agentReplayEnvelopes: [],
                    workspaceReplayEnvelopes: []
                )
            }

        case "fetch_agent_events":
            let startedAt = CFAbsoluteTimeGetCurrent()
            guard let workspaceID = request.params?["workspace_id"]?.stringValue,
                  let limit = request.params?["limit"]?.intValue else {
                return LocalRequestResult(
                    response: BridgeResponse(id: request.id,
                                             ok: false,
                                             result: nil,
                                             error: BridgeInternalError.invalidRequest("fetch_agent_events requires workspace_id and limit").payload),
                    agentReplayEnvelopes: [],
                    workspaceReplayEnvelopes: []
                )
            }
            guard (1...BridgeAgentEventFetchFlow.maximumRequestLimit).contains(limit) else {
                return LocalRequestResult(
                    response: BridgeResponse(
                        id: request.id,
                        ok: false,
                        result: nil,
                        error: BridgeInternalError.invalidRequest(
                            "fetch_agent_events limit must be between 1 and \(BridgeAgentEventFetchFlow.maximumRequestLimit)").payload),
                    agentReplayEnvelopes: [],
                    workspaceReplayEnvelopes: []
                )
            }

            let sessionID = canonicalAgentEventSessionID(request.params?["session_id"]?.stringValue)
            let rawBeforeSeq = request.params?["before_seq"]
            let rawAfterSeq = request.params?["after_seq"]
            let maxBytes = request.params?["max_bytes"]?.intValue
            if rawBeforeSeq != nil, rawAfterSeq != nil {
                return LocalRequestResult(
                    response: BridgeResponse(id: request.id,
                                             ok: false,
                                             result: nil,
                                             error: BridgeInternalError.invalidRequest("fetch_agent_events accepts either before_seq or after_seq, not both").payload),
                    agentReplayEnvelopes: [],
                    workspaceReplayEnvelopes: []
                )
            }
            if let rawBeforeSeq, rawBeforeSeq.intValue == nil {
                return LocalRequestResult(
                    response: BridgeResponse(
                        id: request.id,
                        ok: false,
                        result: nil,
                        error: BridgeInternalError.invalidRequest(
                            "fetch_agent_events received an unrepresentable before_seq").payload),
                    agentReplayEnvelopes: [],
                    workspaceReplayEnvelopes: []
                )
            }
            if let rawAfterSeq, rawAfterSeq.intValue == nil {
                return LocalRequestResult(
                    response: BridgeResponse(
                        id: request.id,
                        ok: false,
                        result: nil,
                        error: BridgeInternalError.invalidRequest(
                            "fetch_agent_events received an unrepresentable after_seq").payload),
                    agentReplayEnvelopes: [],
                    workspaceReplayEnvelopes: []
                )
            }
            if sessionID == nil, rawBeforeSeq != nil || rawAfterSeq != nil {
                return LocalRequestResult(
                    response: BridgeResponse(
                        id: request.id,
                        ok: false,
                        result: nil,
                        error: BridgeInternalError.invalidRequest(
                            "fetch_agent_events cursor requests require session_id").payload),
                    agentReplayEnvelopes: [],
                    workspaceReplayEnvelopes: []
                )
            }
            let beforeSeq = rawBeforeSeq?.intValue
            let afterSeq = rawAfterSeq?.intValue
            let afterCursorSeams = BridgeAgentEventFetchFlow.AfterCursorSeams(
                plan: { [registryMonitor] sessionID, afterSeq, expectedEpoch in
                    registryMonitor.afterCursorPlan(sessionID: sessionID,
                                                    afterSeq: afterSeq,
                                                    expectedEpoch: expectedEpoch)
                },
                step: { [registryMonitor] sessionID, anchor, afterSeq, limit in
                    registryMonitor.afterCursorStep(sessionID: sessionID,
                                                    anchor: anchor,
                                                    afterSeq: afterSeq,
                                                    limit: limit)
                },
                validateEpoch: { [registryMonitor] sessionID, epoch in
                    registryMonitor.validateHistoryEpoch(sessionID: sessionID, epoch: epoch)
                })
            let flow = BridgeAgentEventFetchFlow.run(eventHub: eventHub,
                                                     workspaceID: workspaceID,
                                                     sessionID: sessionID,
                                                     limit: limit,
                                                     maxBytes: maxBytes,
                                                     beforeSeq: beforeSeq,
                                                     afterSeq: afterSeq,
                                                     afterCursorSeams: afterCursorSeams,
                                                     beforeCursorBackfill: { [registryMonitor] sessionID, beforeSeq, limit in
                registryMonitor.beforeCursorBackfillSession(sessionID: sessionID,
                                                            beforeSeq: beforeSeq,
                                                            limit: limit)
            })
            let fetchResult = flow.fetchResult
            let didBackfill = flow.didBackfill
            observability.recordFetch(workspaceID: workspaceID,
                                      sessionID: sessionID,
                                      limit: limit,
                                      beforeSeq: beforeSeq,
                                      afterSeq: afterSeq,
                                      returnedCount: fetchResult.events.count,
                                      didBackfill: didBackfill,
                                      durationMs: (CFAbsoluteTimeGetCurrent() - startedAt) * 1000)
            if flow.beforeCursorUnavailable {
                return LocalRequestResult(
                    response: BridgeResponse(
                        id: request.id,
                        ok: false,
                        result: nil,
                        error: BridgeErrorPayload(
                            code: "agent_history_unavailable",
                            message: "Agent history is temporarily unavailable; retry the request."
                        )),
                    agentReplayEnvelopes: [],
                    workspaceReplayEnvelopes: []
                )
            }
            let merged = BridgePendingApprovalFetchMerge.merge(
                pageEvents: fetchResult.events,
                pageOldestSeq: fetchResult.oldestSeq,
                pageNewestSeq: fetchResult.newestSeq,
                requestedBeforeSeq: beforeSeq,
                requestedAfterSeq: afterSeq,
                pendingEvents: pendingCodexApprovalEvents(workspaceID: workspaceID,
                                                          sessionID: sessionID))
            return LocalRequestResult(
                response: BridgeResponse(id: request.id,
                                         ok: true,
                                         result: [
                                            "events": .array(merged.events.map(Self.jsonValue(for:))),
                                            "oldest_seq": .number(Double(merged.oldestSeq)),
                                            "newest_seq": .number(Double(merged.newestSeq)),
                                            "has_more": .bool(fetchResult.hasMore),
                                         ],
                                         error: nil),
                agentReplayEnvelopes: [],
                workspaceReplayEnvelopes: []
            )

        case "subscribe_agent_events":
            let workspaceID = request.params?["workspace_id"]?.stringValue
            let sessionID = canonicalAgentEventSessionID(request.params?["session_id"]?.stringValue)
            if let rawSinceSeq = request.params?["since_seq"],
               rawSinceSeq.intValue == nil {
                return LocalRequestResult(
                    response: BridgeResponse(id: request.id,
                                             ok: false,
                                             result: nil,
                                             error: BridgeInternalError.invalidRequest("subscribe_agent_events received an unrepresentable since_seq").payload),
                    agentReplayEnvelopes: [],
                    workspaceReplayEnvelopes: []
                )
            }
            if sessionID == nil, request.params?["since_seq"] != nil {
                return LocalRequestResult(
                    response: BridgeResponse(
                        id: request.id,
                        ok: false,
                        result: nil,
                        error: BridgeInternalError.invalidRequest(
                            "subscribe_agent_events since_seq requires session_id").payload),
                    agentReplayEnvelopes: [],
                    workspaceReplayEnvelopes: []
                )
            }
            let sinceSeq = request.params?["since_seq"]?.intValue
            let noReplay = request.params?["no_replay"]?.boolLikeValue ?? false
            let liveGate = BridgeAgentEventReplayGate()

            let (subscriptionID, replayEnvelopes) = eventHub.subscribe(workspaceID: workspaceID,
                                                                       sessionID: sessionID,
                                                                       sinceSeq: noReplay ? Int.max : sinceSeq) { [weak self, weak context] envelope in
                guard let self, let context else {
                    return
                }
                guard let envelope = liveGate.receive(envelope) else {
                    return
                }
                context.eventLoop.execute {
                    self.send(envelope: envelope, to: context)
                }
            }
            let installResult = self.agentSubscriptions.install(workspaceID: workspaceID,
                                                                sessionID: sessionID,
                                                                id: subscriptionID)
            for unsubscribeID in installResult.unsubscribeIDs {
                eventHub.unsubscribe(unsubscribeID)
            }
            let effectiveReplayEnvelopes = installResult.accepted
                ? replayEnvelopesWithPendingCodexApprovals(replayEnvelopes,
                                                           workspaceID: workspaceID,
                                                           sessionID: sessionID,
                                                           noReplay: noReplay)
                : []
            return LocalRequestResult(
                response: BridgeResponse(id: request.id,
                                         ok: true,
                                         result: [
                                            "subscribed": .bool(installResult.accepted),
                                            "workspace_id": workspaceID.map(JSONValue.string) ?? .null,
                                            "session_id": sessionID.map(JSONValue.string) ?? .null,
                                            "no_replay": .bool(noReplay),
                                            "replay_count": .number(Double(effectiveReplayEnvelopes.count)),
                                         ],
                                         error: nil),
                agentReplayEnvelopes: effectiveReplayEnvelopes,
                workspaceReplayEnvelopes: [],
                agentLiveGate: liveGate
            )

        case "unsubscribe_agent_events":
            unsubscribeFromAgentEvents()
            return LocalRequestResult(
                response: BridgeResponse(id: request.id,
                                         ok: true,
                                         result: ["subscribed": .bool(false)],
                                         error: nil),
                agentReplayEnvelopes: [],
                workspaceReplayEnvelopes: []
            )

        case "subscribe_workspace_events":
            let workspaceID = request.params?["workspace_id"]?.stringValue
            unsubscribeFromWorkspaceEvents()

            let (subscriptionID, replayEnvelopes) = workspaceEventHub.subscribe(workspaceID: workspaceID) { [weak self, weak context] envelope in
                guard let self, let context else {
                    return
                }
                context.eventLoop.execute {
                    self.send(workspaceEnvelope: envelope, to: context)
                }
            }
            self.workspaceSubscriptionID = subscriptionID
            return LocalRequestResult(
                response: BridgeResponse(id: request.id,
                                         ok: true,
                                         result: [
                                            "subscribed": .bool(true),
                                            "workspace_id": workspaceID.map(JSONValue.string) ?? .null,
                                            "replay_count": .number(Double(replayEnvelopes.count)),
                                         ],
                                         error: nil),
                agentReplayEnvelopes: [],
                workspaceReplayEnvelopes: replayEnvelopes
            )

        case "unsubscribe_workspace_events":
            unsubscribeFromWorkspaceEvents()
            return LocalRequestResult(
                response: BridgeResponse(id: request.id,
                                         ok: true,
                                         result: ["subscribed": .bool(false)],
                                         error: nil),
                agentReplayEnvelopes: [],
                workspaceReplayEnvelopes: []
            )

        case "subscribe_terminal_stream":
            do {
                guard let panelID = request.params?["panel_id"]?.stringValue else {
                    throw BridgeInternalError.invalidRequest("subscribe_terminal_stream requires panel_id")
                }
                let owner = try Self.terminalStreamSubscriptionOwner(from: request.params)
                guard let reservation = terminalStreamConnectionAdmission.reserveSubscribe(
                    sequence: receiptSequence,
                    panelID: panelID,
                    owner: owner
                ) else {
                    return LocalRequestResult(response: supersededResponse(id: request.id,
                                                                           reason: "newer terminal stream request already owns the panel"),
                                              agentReplayEnvelopes: [],
                                              workspaceReplayEnvelopes: [])
                }
                let candidate: OrdinaryTmuxTerminalStreamLaneCandidate
                do {
                    guard let laneResult = awaitTerminalStreamCandidate(request: request,
                                                                        reservation: reservation,
                                                                        context: context) else {
                        terminalStreamConnectionAdmission.abandonSubscribe(reservation)
                        return LocalRequestResult(response: supersededResponse(id: request.id,
                                                                               reason: "newer terminal stream request already owns the panel"),
                                                  agentReplayEnvelopes: [],
                                                  workspaceReplayEnvelopes: [])
                    }
                    candidate = try laneResult.get()
                } catch {
                    terminalStreamConnectionAdmission.abandonSubscribe(reservation)
                    throw error
                }
                return LocalRequestResult(response: candidate.response,
                                          agentReplayEnvelopes: [],
                                          workspaceReplayEnvelopes: [],
                                          applyOnEventLoop: terminalStreamSubscribeCommit(
                                            candidate: candidate,
                                            reservation: reservation,
                                            context: context
                                          ),
                                          afterAcceptedResponseEnqueued: {
                                            candidate.lease.activate()
                                          })
            } catch let bridgeError as BridgeInternalError {
                return LocalRequestResult(response: BridgeResponse(id: request.id,
                                                                   ok: false,
                                                                   result: nil,
                                                                   error: bridgeError.payload),
                                          agentReplayEnvelopes: [],
                                          workspaceReplayEnvelopes: [])
            } catch {
                return LocalRequestResult(response: BridgeResponse(id: request.id,
                                                                   ok: false,
                                                                   result: nil,
                                                                   error: BridgeErrorPayload(code: "terminal_stream_unavailable",
                                                                                             message: error.localizedDescription)),
                                          agentReplayEnvelopes: [],
                                          workspaceReplayEnvelopes: [])
            }

        case "unsubscribe_terminal_stream":
            do {
                let panelValue = request.params?["panel_id"]
                let subscriptionValue = request.params?["subscription_id"]
                let panelID: String?
                if let panelValue {
                    guard let parsedPanelID = panelValue.stringValue else {
                        throw BridgeInternalError.invalidRequest(
                            "unsubscribe_terminal_stream panel_id must be a string"
                        )
                    }
                    panelID = parsedPanelID
                } else {
                    panelID = nil
                }

                let owner: TerminalStreamSubscriptionOwner?
                if subscriptionValue != nil {
                    let parsedOwner = try Self.terminalStreamSubscriptionOwner(from: request.params)
                    guard case .identified(let id) = parsedOwner else {
                        throw BridgeInternalError.invalidRequest(
                            "unsubscribe_terminal_stream requires identified ownership when subscription_id is present"
                        )
                    }
                    guard terminalStreamConnectionAdmission.prepareIdentifiedUnsubscribe(id: id) else {
                        return LocalRequestResult(response: supersededResponse(id: request.id,
                                                                               reason: "terminal stream connection is no longer active"),
                                                  agentReplayEnvelopes: [],
                                                  workspaceReplayEnvelopes: [])
                    }
                    owner = parsedOwner
                } else if let panelID {
                    guard terminalStreamConnectionAdmission.prepareLegacyUnsubscribe(
                        sequence: receiptSequence,
                        panelID: panelID
                    ) else {
                        return LocalRequestResult(response: supersededResponse(id: request.id,
                                                                               reason: "newer terminal stream request already changed the subscription"),
                                                  agentReplayEnvelopes: [],
                                                  workspaceReplayEnvelopes: [])
                    }
                    owner = .legacy
                } else {
                    guard terminalStreamConnectionAdmission.prepareUnsubscribeAll(sequence: receiptSequence) else {
                        return LocalRequestResult(response: supersededResponse(id: request.id,
                                                                               reason: "newer terminal stream request already changed the subscription"),
                                                  agentReplayEnvelopes: [],
                                                  workspaceReplayEnvelopes: [])
                    }
                    owner = nil
                }

                if panelID == nil, owner == nil {
                    return LocalRequestResult(
                        response: BridgeResponse(id: request.id,
                                                 ok: true,
                                                 result: ["subscribed": .bool(false)],
                                                 error: nil),
                        agentReplayEnvelopes: [],
                        workspaceReplayEnvelopes: [],
                        applyOnEventLoop: terminalStreamUnsubscribeCommit(panelID: nil,
                                                                          owner: nil,
                                                                          receiptSequence: receiptSequence)
                    )
                }
                return LocalRequestResult(
                    response: BridgeResponse(id: request.id,
                                             ok: true,
                                             result: ["subscribed": .bool(false)],
                                             error: nil),
                    agentReplayEnvelopes: [],
                    workspaceReplayEnvelopes: [],
                    applyOnEventLoop: terminalStreamUnsubscribeCommit(panelID: panelID,
                                                                      owner: owner,
                                                                      receiptSequence: receiptSequence)
                )
            } catch let bridgeError as BridgeInternalError {
                return LocalRequestResult(response: BridgeResponse(id: request.id,
                                                                   ok: false,
                                                                   result: nil,
                                                                   error: bridgeError.payload),
                                          agentReplayEnvelopes: [],
                                          workspaceReplayEnvelopes: [])
            } catch {
                return LocalRequestResult(response: BridgeResponse(
                    id: request.id,
                    ok: false,
                    result: nil,
                    error: BridgeErrorPayload(code: "terminal_stream_unavailable",
                                              message: error.localizedDescription)
                ), agentReplayEnvelopes: [], workspaceReplayEnvelopes: [])
            }

        default:
            return nil
        }
    }

    private func handleInteractivePTYRequest(
        _ action: TmuxInteractiveWireAction,
        request: BridgeRequest,
        context: ChannelHandlerContext
    ) throws -> LocalRequestResult {
        switch action {
        case .subscribe(let subscribe):
            guard let candidateBuilder = interactivePTYActivation.candidateBuilder else {
                return interactivePTYUnavailableResponse(
                    requestID: request.id,
                    message: "Interactive tmux PTY routing is unavailable."
                )
            }
            let session = try candidateBuilder.build(subscribe)
            let binding = subscribe.binding
            return LocalRequestResult(
                response: BridgeResponse(
                    id: request.id,
                    ok: true,
                    result: [
                        "subscribed": .bool(true),
                        "subscription_id": .string(binding.subscriptionID),
                        "generation": .number(Double(binding.generation)),
                    ],
                    error: nil
                ),
                agentReplayEnvelopes: [],
                workspaceReplayEnvelopes: [],
                applyOnEventLoop: interactivePTYSubscribeCommit(
                    session: session,
                    binding: binding,
                    context: context
                ),
                afterAcceptedResponseEnqueued: { [weak self] in
                    self?.startInteractivePTYPump(binding: binding)
                }
            )
        case .unsubscribe(let unsubscribe):
            let binding = unsubscribe.binding
            return LocalRequestResult(
                response: BridgeResponse(
                    id: request.id,
                    ok: true,
                    result: [
                        "subscribed": .bool(false),
                        "subscription_id": .string(binding.subscriptionID),
                        "generation": .number(Double(binding.generation)),
                    ],
                    error: nil
                ),
                agentReplayEnvelopes: [],
                workspaceReplayEnvelopes: [],
                applyOnEventLoop: interactivePTYUnsubscribeCommit(
                    binding: binding
                )
            )
        case .input(let input):
            let binding = input.binding
            return LocalRequestResult(
                response: BridgeResponse(
                    id: request.id,
                    ok: true,
                    result: [
                        "accepted": .bool(true),
                        "subscription_id": .string(binding.subscriptionID),
                        "generation": .number(Double(binding.generation)),
                        "byte_count": .number(Double(input.bytes.count)),
                    ],
                    error: nil
                ),
                agentReplayEnvelopes: [],
                workspaceReplayEnvelopes: [],
                applyOnEventLoop: interactivePTYInputCommit(input: input)
            )
        case .resize(let resize):
            let binding = resize.binding
            return LocalRequestResult(
                response: BridgeResponse(
                    id: request.id,
                    ok: true,
                    result: [
                        "accepted": .bool(true),
                        "subscription_id": .string(binding.subscriptionID),
                        "generation": .number(Double(binding.generation)),
                        "cols": .number(Double(resize.viewport.columns)),
                        "rows": .number(Double(resize.viewport.rows)),
                    ],
                    error: nil
                ),
                agentReplayEnvelopes: [],
                workspaceReplayEnvelopes: [],
                applyOnEventLoop: interactivePTYResizeCommit(resize: resize)
            )
        }
    }

    private func interactivePTYResizeCommit(
        resize: TmuxInteractiveResize
    ) -> () -> CommitOutcome {
        let binding = resize.binding
        return { [weak self] in
            guard let self else {
                return .rejected(
                    reason: "interactive PTY connection is no longer active"
                )
            }
            guard let session = self.interactivePTYConnectionState.owner(
                for: binding
            ),
            let entry = self.interactivePTYPumps[binding.subscriptionID],
            entry.binding == binding,
            entry.session === session else {
                return .rejected(
                    reason: "interactive PTY subscription is no longer current"
                )
            }
            switch entry.resizePump.enqueue(resize) {
            case .accepted:
                return .accepted
            case .notActive:
                return .failed(
                    code: "tmux_interactive_not_ready",
                    reason: "Interactive PTY authoritative start is not active."
                )
            case .bindingMismatch:
                return .rejected(
                    reason: "interactive PTY subscription is no longer current"
                )
            case .invalidViewport:
                return .failed(
                    code: "invalid_request",
                    reason: "Interactive PTY viewport is invalid."
                )
            }
        }
    }

    private func interactivePTYInputCommit(
        input: TmuxInteractiveInput
    ) -> () -> CommitOutcome {
        let binding = input.binding
        return { [weak self] in
            guard let self else {
                return .rejected(
                    reason: "interactive PTY connection is no longer active"
                )
            }
            guard let session = self.interactivePTYConnectionState.owner(
                for: binding
            ),
            let entry = self.interactivePTYPumps[binding.subscriptionID],
            entry.binding == binding,
            entry.session === session else {
                return .rejected(
                    reason: "interactive PTY subscription is no longer current"
                )
            }
            switch entry.inputPump.enqueue(input) {
            case .accepted:
                return .accepted
            case .notActive:
                return .failed(
                    code: "tmux_interactive_not_ready",
                    reason: "Interactive PTY authoritative start is not active."
                )
            case .capacityExceeded(let limit):
                return .failed(
                    code: "tmux_interactive_backpressure",
                    reason: "Interactive PTY input queue exceeds \(limit) bytes."
                )
            case .bindingMismatch:
                return .rejected(
                    reason: "interactive PTY subscription is no longer current"
                )
            case .invalidInput:
                return .failed(
                    code: "invalid_request",
                    reason: "Interactive PTY input bytes are invalid."
                )
            }
        }
    }

    private func interactivePTYUnsubscribeCommit(
        binding: TmuxInteractiveSubscriptionBinding
    ) -> () -> CommitOutcome {
        let workExecutor = InteractivePTYWorkExecutor(execute: requestExecutor)
        let cleanupConnectionID = connectionID
        return { [weak self] in
            guard let self else {
                return .rejected(
                    reason: "interactive PTY connection is no longer active"
                )
            }
            guard let session = self.interactivePTYConnectionState.remove(
                binding: binding
            ) else {
                return .rejected(
                    reason: "interactive PTY subscription is no longer current"
                )
            }
            let pumpsToStop: InteractivePTYPumpEntry?
            if let entry = self.interactivePTYPumps[binding.subscriptionID],
               entry.binding == binding,
               entry.session === session {
                self.interactivePTYPumps.removeValue(
                    forKey: binding.subscriptionID
                )
                pumpsToStop = entry
            } else {
                pumpsToStop = nil
            }
            pumpsToStop?.outputPump.stop()
            pumpsToStop?.inputPump.stop()
            pumpsToStop?.resizePump.stop()
            workExecutor.submit {
                do {
                    try session.close()
                } catch {
                    BridgeLogger.server.error(
                        "interactive PTY unsubscribe cleanup failed connection_id=\(cleanupConnectionID, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
                    )
                }
            }
            return .accepted
        }
    }

    private func interactivePTYUnavailableResponse(
        requestID: String,
        message: String
    ) -> LocalRequestResult {
        LocalRequestResult(
            response: BridgeResponse(
                id: requestID,
                ok: false,
                result: nil,
                error: BridgeErrorPayload(
                    code: "tmux_interactive_unavailable",
                    message: message
                )
            ),
            agentReplayEnvelopes: [],
            workspaceReplayEnvelopes: []
        )
    }

    private func interactivePTYSubscribeCommit(
        session: TmuxInteractivePTYConnectionSession,
        binding: TmuxInteractiveSubscriptionBinding,
        context: ChannelHandlerContext
    ) -> () -> CommitOutcome {
        let workExecutor = InteractivePTYWorkExecutor(execute: requestExecutor)
        let cleanupConnectionID = connectionID
        let closeCandidate: @Sendable () -> Void = {
            workExecutor.submit {
                do {
                    try session.close()
                } catch {
                    BridgeLogger.server.error(
                        "interactive PTY candidate cleanup failed connection_id=\(cleanupConnectionID, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
                    )
                }
            }
        }
        return { [weak self, weak context] in
            guard let self, let context else {
                closeCandidate()
                return .rejected(
                    reason: "interactive PTY connection is no longer active"
                )
            }
            guard self.interactivePTYConnectionState.install(
                binding: binding,
                owner: session
            ) else {
                closeCandidate()
                return .rejected(
                    reason: "interactive PTY subscription is no longer current"
                )
            }
            let outputPump = self.makeInteractivePTYPump(
                session: session,
                binding: binding,
                context: context
            )
            let inputPump = self.makeInteractivePTYInputPump(
                session: session,
                binding: binding,
                context: context
            )
            let resizePump = self.makeInteractivePTYResizePump(
                session: session,
                binding: binding,
                context: context
            )
            self.interactivePTYPumps[binding.subscriptionID] =
                InteractivePTYPumpEntry(
                    binding: binding,
                    session: session,
                    outputPump: outputPump,
                    inputPump: inputPump,
                    resizePump: resizePump
                )
            return .accepted
        }
    }

    private func startInteractivePTYPump(
        binding: TmuxInteractiveSubscriptionBinding
    ) {
        guard let session = interactivePTYConnectionState.owner(for: binding),
              let entry = interactivePTYPumps[binding.subscriptionID],
              entry.binding == binding,
              entry.session === session else {
            return
        }
        entry.outputPump.start()
    }

    private func activateInteractivePTYMutationPumps(
        binding: TmuxInteractiveSubscriptionBinding,
        session: TmuxInteractivePTYConnectionSession
    ) -> Bool {
        guard interactivePTYConnectionState.owner(for: binding) === session,
              let entry = interactivePTYPumps[binding.subscriptionID],
              entry.binding == binding,
              entry.session === session else {
            return false
        }
        return entry.inputPump.activate() && entry.resizePump.activate()
    }

    private func makeInteractivePTYPump(
        session: TmuxInteractivePTYConnectionSession,
        binding: TmuxInteractiveSubscriptionBinding,
        context: ChannelHandlerContext
    ) -> TmuxInteractivePTYEventPump {
        let workExecutor = InteractivePTYWorkExecutor(execute: requestExecutor)
        let callbackTarget = InteractivePTYConnectionCallbackTarget(
            handler: self,
            context: context
        )
        let cleanupConnectionID = connectionID
        let closeSession: @Sendable () -> Void = {
            workExecutor.submit {
                do {
                    try session.close()
                } catch {
                    BridgeLogger.server.error(
                        "interactive PTY pump cleanup failed connection_id=\(cleanupConnectionID, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
                    )
                }
            }
        }
        return TmuxInteractivePTYEventPump(
            poll: { try session.poll() },
            execute: { work in
                workExecutor.submit(work)
            },
            scheduleRetry: { work in
                callbackTarget.scheduleRetry(
                    work,
                    closeSession: closeSession
                )
            },
            deliver: { event, completion in
                callbackTarget.deliver(
                    event,
                    binding: binding,
                    session: session,
                    completion: completion
                )
            },
            onStopped: { error in
                callbackTarget.stopped(
                    error: error,
                    binding: binding,
                    session: session,
                    closeSession: closeSession
                )
            }
        )
    }

    private func makeInteractivePTYInputPump(
        session: TmuxInteractivePTYConnectionSession,
        binding: TmuxInteractiveSubscriptionBinding,
        context: ChannelHandlerContext
    ) -> TmuxInteractivePTYInputPump {
        let workExecutor = InteractivePTYWorkExecutor(execute: requestExecutor)
        let callbackTarget = InteractivePTYConnectionCallbackTarget(
            handler: self,
            context: context
        )
        let cleanupConnectionID = connectionID
        let closeSession: @Sendable () -> Void = {
            workExecutor.submit {
                do {
                    try session.close()
                } catch {
                    BridgeLogger.server.error(
                        "interactive PTY input cleanup failed connection_id=\(cleanupConnectionID, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
                    )
                }
            }
        }
        return TmuxInteractivePTYInputPump(
            binding: binding,
            maximumPendingBytes: TmuxInteractiveWireCodec.maximumInputBytes,
            write: { bytes in
                try session.sendInput(
                    TmuxInteractiveInput(binding: binding, bytes: bytes)
                )
            },
            execute: { work in
                workExecutor.submit(work)
            },
            scheduleRetry: { work in
                callbackTarget.scheduleRetry(
                    work,
                    closeSession: closeSession
                )
            },
            onStopped: { error in
                callbackTarget.stopped(
                    error: error,
                    binding: binding,
                    session: session,
                    closeSession: closeSession
                )
            }
        )
    }

    private func makeInteractivePTYResizePump(
        session: TmuxInteractivePTYConnectionSession,
        binding: TmuxInteractiveSubscriptionBinding,
        context: ChannelHandlerContext
    ) -> TmuxInteractivePTYResizePump {
        let workExecutor = InteractivePTYWorkExecutor(execute: requestExecutor)
        let callbackTarget = InteractivePTYConnectionCallbackTarget(
            handler: self,
            context: context
        )
        let cleanupConnectionID = connectionID
        let closeSession: @Sendable () -> Void = {
            workExecutor.submit {
                do {
                    try session.close()
                } catch {
                    BridgeLogger.server.error(
                        "interactive PTY resize cleanup failed connection_id=\(cleanupConnectionID, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
                    )
                }
            }
        }
        return TmuxInteractivePTYResizePump(
            binding: binding,
            apply: { resize in
                try session.applyResize(resize)
            },
            execute: { work in
                workExecutor.submit(work)
            },
            onStopped: { error in
                callbackTarget.stopped(
                    error: error,
                    binding: binding,
                    session: session,
                    closeSession: closeSession
                )
            }
        )
    }

    private func finishInteractivePTYPump(
        binding: TmuxInteractiveSubscriptionBinding,
        session: TmuxInteractivePTYConnectionSession,
        error: Error?,
        context: ChannelHandlerContext,
        closeSession: @escaping @Sendable () -> Void
    ) {
        guard let removedSession = interactivePTYConnectionState.remove(
            binding: binding
        ),
        removedSession === session else {
            return
        }
        let pumpsToStop: InteractivePTYPumpEntry?
        if let entry = interactivePTYPumps[binding.subscriptionID],
           entry.binding == binding,
           entry.session === session {
            interactivePTYPumps.removeValue(forKey: binding.subscriptionID)
            pumpsToStop = entry
        } else {
            pumpsToStop = nil
        }
        pumpsToStop?.outputPump.stop()
        pumpsToStop?.inputPump.stop()
        pumpsToStop?.resizePump.stop()
        guard error != nil else { return }
        send(
            interactivePTYEvent: .terminal(
                TmuxInteractiveStateChange(
                    binding: binding,
                    state: .failed,
                    message: "Interactive PTY session failed."
                )
            ),
            to: context,
            afterWrite: { _ in closeSession() }
        )
    }

    private func unsubscribeFromAgentEvents() {
        for subscriptionID in agentSubscriptions.removeAll() {
            eventHub.unsubscribe(subscriptionID)
        }
    }

    private func unsubscribeFromWorkspaceEvents() {
        if let workspaceSubscriptionID {
            workspaceEventHub.unsubscribe(workspaceSubscriptionID)
            self.workspaceSubscriptionID = nil
        }
    }

    private func awaitTerminalStreamCandidate(request: BridgeRequest,
                                              reservation: TerminalStreamConnectionAdmission.Reservation,
                                              context: ChannelHandlerContext) -> Result<OrdinaryTmuxTerminalStreamLaneCandidate, Error>? {
        let gate = TerminalStreamDeliveryGate()
        let sender = TerminalStreamDeltaSender(handler: self,
                                               context: context,
                                               schedule: terminalStreamEventLoopScheduler)
        let lane = terminalStreamLaneRegistry.lane(for: reservation.panelID)
        let completion = DispatchSemaphore(value: 0)
        let resultBox = TerminalStreamLaneResultBox()
        let outputStreamHandler = ordinaryTmuxOutputStreamHandler
        let admission = terminalStreamConnectionAdmission
        lane.submitSubscribe(sequence: reservation.sequence,
                             claimForPhysicalMutation: {
                                 admission.claimForPhysicalMutation(reservation)
                             },
                             build: {
            let start: OrdinaryTmuxOutputStreamStart
            do {
                guard let acceptedStart = try outputStreamHandler.subscribe(request,
                                                                             allowedIf: { gate.allowsDelivery },
                                                                             onDelta: { envelope in
                                                                                 sender.send(envelope,
                                                                                             allowedIf: { gate.allowsDelivery })
                                                                             }) else {
                    throw BridgeInternalError.invalidRequest("terminal stream handler did not accept subscribe request")
                }
                start = acceptedStart
            } catch let ownedFailure as OrdinaryTmuxOutputStreamOwnedFailure {
                throw OrdinaryTmuxTerminalStreamLaneOwnedFailure(
                    underlying: ownedFailure.underlying,
                    lease: OrdinaryTmuxTerminalStreamLease(token: reservation.sequence,
                                                           owner: reservation.owner,
                                                           subscription: ownedFailure.subscription,
                                                           deliveryGate: gate)
                )
            }
            return OrdinaryTmuxTerminalStreamLaneCandidate(
                response: start.response,
                lease: OrdinaryTmuxTerminalStreamLease(token: reservation.sequence,
                                                       owner: reservation.owner,
                                                       subscription: start.subscription,
                                                       deliveryGate: gate)
            )
        }, completion: { result in
            resultBox.store(result)
            completion.signal()
        })
        completion.wait()
        guard let completed = resultBox.result else {
            preconditionFailure("Terminal stream lane completed without recording a result")
        }
        return completed
    }

    private func terminalStreamSubscribeCommit(candidate: OrdinaryTmuxTerminalStreamLaneCandidate,
                                               reservation: TerminalStreamConnectionAdmission.Reservation,
                                               context: ChannelHandlerContext) -> () -> CommitOutcome {
        let lane = terminalStreamLaneRegistry.lane(for: reservation.panelID)
        let admission = terminalStreamConnectionAdmission
        let callbackTarget = TerminalStreamConnectionCallbackTarget(
            handler: self,
            context: context,
            schedule: terminalStreamEventLoopScheduler
        )
        return { [weak self, weak context] in
            guard let self, context != nil else {
                admission.abandonSubscribe(reservation)
                candidate.lease.deliveryGate.invalidate()
                lane.releaseIfCurrent(token: candidate.lease.token)
                return .rejected(reason: "terminal stream connection is no longer active")
            }
            guard admission.finalizeSubscribe(reservation) else {
                admission.abandonSubscribe(reservation)
                candidate.lease.deliveryGate.invalidate()
                lane.releaseIfCurrent(token: candidate.lease.token)
                return .rejected(reason: "newer terminal stream request already changed the subscription")
            }
            let decision = self.terminalStreamConnectionState.installSubscribe(
                panelID: reservation.panelID,
                owner: reservation.owner,
                lease: candidate.lease,
                onInvalidated: {
                    callbackTarget.removeIfOwned(panelID: reservation.panelID,
                                                 token: candidate.lease.token)
                }
            )
            switch decision {
            case .accepted(let displacedLease):
                if let displacedLease {
                    self.releaseTerminalStreamLeases([displacedLease])
                }
                self.publishTerminalStreamSubscriptionCount()
                return .accepted
            case .rejected:
                candidate.lease.deliveryGate.invalidate()
                lane.releaseIfCurrent(token: candidate.lease.token)
                return .rejected(reason: "newer terminal stream request already owns the panel")
            }
        }
    }

    private func terminalStreamUnsubscribeCommit(panelID: String?,
                                                 owner: TerminalStreamSubscriptionOwner?,
                                                 receiptSequence: UInt64) -> () -> CommitOutcome {
        { [weak self] in
            guard let self else {
                return .rejected(reason: "terminal stream connection is no longer active")
            }
            let decision: TerminalStreamConnectionState.ReleaseDecision
            switch owner {
            case .some(.legacy):
                guard let panelID else {
                    return .rejected(reason: "legacy terminal stream cleanup requires panel ownership")
                }
                decision = self.terminalStreamConnectionState.releaseInstalledLegacyLease(
                    panelID: panelID
                )
            case .some(.identified(let id)):
                decision = self.terminalStreamConnectionState.releaseInstalledIdentifiedLease(
                    id: id
                )
            case .none:
                decision = self.terminalStreamConnectionState.releaseInstalledLeases(
                    olderThan: receiptSequence
                )
            }
            switch decision {
            case .accepted(let leases):
                self.releaseTerminalStreamLeases(leases)
                self.publishTerminalStreamSubscriptionCount()
                return .accepted
            case .rejected:
                return .rejected(reason: "newer terminal stream request already changed the subscription")
            }
        }
    }

    private static func terminalStreamSubscriptionOwner(
        from params: [String: JSONValue]?
    ) throws -> TerminalStreamSubscriptionOwner {
        guard let value = params?["subscription_id"] else {
            return .legacy
        }
        guard case .string(let id) = value,
              id.isEmpty == false,
              id.utf8.count <= 128 else {
            throw BridgeInternalError.invalidRequest(
                "subscription_id must be a non-empty string no longer than 128 UTF-8 bytes"
            )
        }
        return .identified(id)
    }

    private func releaseTerminalStreamLeases(_ leases: [OrdinaryTmuxTerminalStreamLease]) {
        for lease in leases {
            lease.deliveryGate.invalidate()
            terminalStreamLaneRegistry.lane(for: lease.route.panelID).releaseIfCurrent(token: lease.token)
        }
    }

    private func supersededResponse(id: String?, reason: String) -> BridgeResponse {
        BridgeResponse(id: id,
                       ok: false,
                       result: nil,
                       error: BridgeErrorPayload(code: "superseded", message: reason))
    }

    private func publishTerminalStreamSubscriptionCount() {
        observability.setActiveTerminalStreamSubscriptionCount(
            terminalStreamConnectionState.count,
            forConnectionID: connectionID
        )
    }

    private func canonicalAgentEventSessionID(_ sessionID: String?) -> String? {
        registryMonitor.canonicalSessionIDForAgentEvents(sessionID)
    }

    private func pendingCodexApprovalEvents(workspaceID: String?,
                                            sessionID: String?) -> [AgentEvent] {
        guard let workspaceID else {
            return []
        }
        return codexApprovalProvider?.pendingApprovalPromptEvents(workspaceID: workspaceID,
                                                                  sessionID: sessionID) ?? []
    }

    private func replayEnvelopesWithPendingCodexApprovals(_ replayEnvelopes: [AgentEventEnvelope],
                                                          workspaceID: String?,
                                                          sessionID: String?,
                                                          noReplay: Bool) -> [AgentEventEnvelope] {
        guard noReplay == false else {
            return replayEnvelopes
        }
        return BridgePendingApprovalFetchMerge.mergeReplayEnvelopes(
            replayEnvelopes,
            pendingEvents: pendingCodexApprovalEvents(workspaceID: workspaceID,
                                                      sessionID: sessionID))
    }

    private func augment(response: BridgeResponse, for request: BridgeRequest) -> BridgeResponse {
        guard response.ok, let result = response.result else {
            return response
        }
        switch request.action {
        case "list_panels":
            let projectedResult = ordinaryTmuxPanelProjector.projectPanelListResult(result)
            recordPanelListResult(projectedResult)
            return BridgeResponse(id: response.id,
                                  ok: response.ok,
                                  v: response.v,
                                  result: augmentPanelListResult(projectedResult),
                                  error: response.error)
        case "list_workspaces":
            pruneLivePanelsForListedWorkspaces(result)
            let augmented = augmentWorkspaceListResult(result)
            return BridgeResponse(id: response.id,
                                  ok: response.ok,
                                  v: response.v,
                                  result: augmented,
                                  error: response.error)
        default:
            return response
        }
    }

    private func pruneLivePanelsForListedWorkspaces(_ result: [String: JSONValue]) {
        guard let workspaces = result["workspaces"]?.arrayValue else {
            return
        }
        let workspaceIDs = Set(workspaces.compactMap { $0.objectValue?["workspace_id"]?.stringValue })
        registryMonitor.pruneLivePanels(toWorkspaceIDs: workspaceIDs)
    }

    private func recordPanelListResult(_ result: [String: JSONValue]) {
        guard let extracted = AgentPanelProcessSnapshotExtractor.snapshots(fromPanelListResult: result) else {
            return
        }
        registryMonitor.replaceLivePanels(workspaceID: extracted.workspaceID, panels: extracted.snapshots)
    }

    func augmentPanelListResult(_ result: [String: JSONValue]) -> [String: JSONValue] {
        guard let workspaceID = result["workspace_id"]?.stringValue,
              let panels = result["panels"]?.arrayValue else {
            return result
        }

        let augmentedPanels = panels.map { panelValue -> JSONValue in
            guard var panel = panelValue.objectValue,
                  let panelID = panel["panel_id"]?.stringValue else {
                return panelValue
            }
            let snapshot = AgentPanelProcessSnapshotExtractor.snapshot(from: panelValue, defaultWorkspaceID: workspaceID)
            var hasAgentSession = false
            if let session = registryMonitor.activeSessionForPanel(workspaceID: workspaceID,
                                                                   panelID: panelID,
                                                                   effectiveShellPID: snapshot?.effectiveShellPID,
                                                                   tmuxPaneID: snapshot?.tmuxPaneID,
                                                                   tmuxSocketPath: snapshot?.tmuxSocketPath) {
                panel["agent_session"] = .object([
                    "vendor": .string(session.vendor),
                    "session_id": .string(session.sessionID),
                ])
                hasAgentSession = true
            }
            panel = AgentLifecycleListAugmenter.augmentPanel(panel,
                                                             workspaceID: workspaceID,
                                                             panelID: panelID,
                                                             hasAgentSession: hasAgentSession,
                                                             store: lifecycleStore)
            return .object(panel)
        }

        var augmented = result
        augmented["panels"] = .array(augmentedPanels)
        return augmented
    }

    func augmentWorkspaceListResult(_ result: [String: JSONValue]) -> [String: JSONValue] {
        guard let workspaces = result["workspaces"]?.arrayValue else {
            return result
        }

        let augmentedWorkspaces = workspaces.map { workspaceValue -> JSONValue in
            guard var workspace = workspaceValue.objectValue,
                  let workspaceID = workspace["workspace_id"]?.stringValue else {
                return workspaceValue
            }
            if let session = registryMonitor.activeSessionForWorkspace(workspaceID: workspaceID) {
                workspace["has_agent_session"] = .bool(true)
                if let panelID = session.panelID, !panelID.isEmpty {
                    workspace["agent_panel_id"] = .string(panelID)
                }
            }
            workspace = AgentLifecycleListAugmenter.augmentWorkspace(workspace,
                                                                     workspaceID: workspaceID,
                                                                     store: lifecycleStore)
            return .object(workspace)
        }

        var augmented = result
        augmented["workspaces"] = .array(augmentedWorkspaces)
        return augmented
    }

    private func send(response: BridgeResponse,
                      messageType: String = "response",
                      to context: ChannelHandlerContext,
                      afterEnqueued: (() -> Void)? = nil) {
        sendEncodable(response,
                      messageType: messageType,
                      to: context,
                      afterEnqueued: afterEnqueued)
    }

    private func send(envelope: AgentEventEnvelope, to context: ChannelHandlerContext) {
        sendEncodable(envelope, messageType: "agent_event", to: context)
    }

    private func send(workspaceEnvelope: WorkspaceEventEnvelope, to context: ChannelHandlerContext) {
        sendEncodable(workspaceEnvelope, messageType: "workspace_event", to: context)
    }

    private func send(terminalStreamEnvelope: TerminalStreamDeltaEnvelope, to context: ChannelHandlerContext) {
        sendEncodable(terminalStreamEnvelope, messageType: "terminal_stream_delta", to: context)
    }

    private func send(
        interactivePTYEvent: TmuxInteractivePTYEvent,
        to context: ChannelHandlerContext,
        afterWrite: @escaping @Sendable (Result<Void, Error>) -> Void
    ) {
        switch interactivePTYEvent {
        case .start(let start):
            sendEncodable(
                TmuxInteractiveWireCodec.envelope(for: start),
                messageType: TmuxInteractiveProtocolV1.startEventType,
                to: context,
                afterWrite: afterWrite
            )
        case .output(let output):
            sendEncodable(
                TmuxInteractiveWireCodec.envelope(for: output),
                messageType: TmuxInteractiveProtocolV1.outputEventType,
                to: context,
                afterWrite: afterWrite
            )
        case .terminal(let state):
            sendEncodable(
                TmuxInteractiveWireCodec.envelope(for: state),
                messageType: TmuxInteractiveProtocolV1.stateEventType,
                to: context,
                afterWrite: afterWrite
            )
        }
    }

    private func sendEncodable<Value: Encodable>(_ value: Value,
                                                  messageType: String,
                                                  to context: ChannelHandlerContext,
                                                  afterEnqueued: (() -> Void)? = nil,
                                                  afterWrite: (@Sendable (Result<Void, Error>) -> Void)? = nil) {
        do {
            let startedAt = CFAbsoluteTimeGetCurrent()
            let payload = try encoder.encode(value)
            observability.recordPayload(direction: .outbound,
                                        messageType: messageType,
                                        byteCount: payload.count,
                                        durationMs: (CFAbsoluteTimeGetCurrent() - startedAt) * 1000)
            var buffer = context.channel.allocator.buffer(capacity: payload.count)
            buffer.writeBytes(payload)
            let frame = WebSocketFrame(fin: true, opcode: .text, data: buffer)
            write(frame: frame,
                  messageType: messageType,
                  byteCount: payload.count,
                  to: context,
                  afterEnqueued: afterEnqueued,
                  afterWrite: afterWrite)
        } catch {
            let bridgedError = error as NSError
            recordConnectionEvent(kind: .encodeFailed,
                                  errorType: String(reflecting: type(of: error)),
                                  errorDomain: bridgedError.domain,
                                  errorCode: bridgedError.code,
                                  messageType: messageType)
            afterWrite?(.failure(error))
            context.close(promise: nil)
        }
    }

    private func write(frame: WebSocketFrame,
                       messageType: String,
                       byteCount: Int,
                       to context: ChannelHandlerContext,
                       afterEnqueued: (() -> Void)? = nil,
                       afterWrite: (@Sendable (Result<Void, Error>) -> Void)? = nil) {
        let promise = context.eventLoop.makePromise(of: Void.self)
        promise.futureResult.whenComplete { [weak self] result in
            if case .failure(let error) = result,
               let self {
                let bridgedError = error as NSError
                self.recordConnectionEvent(kind: .writeFailed,
                                           errorType: String(reflecting: type(of: error)),
                                           errorDomain: bridgedError.domain,
                                           errorCode: bridgedError.code,
                                           messageType: messageType,
                                           byteCount: byteCount)
            }
            afterWrite?(result)
        }
        context.writeAndFlush(wrapOutboundOut(frame), promise: promise)
        afterEnqueued?()
    }

    private static func iso8601Now() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }

    private static func jsonValue(for endpoint: BridgePairEndpoint) -> JSONValue {
        .object([
            "scheme": .string(endpoint.scheme),
            "host": .string(endpoint.host),
            "port": endpoint.port.map { .number(Double($0)) } ?? .null,
            "path": .string(endpoint.path),
        ])
    }

    private static func jsonValue(for event: AgentEvent) -> JSONValue {
        var object: [String: JSONValue] = [
            "event_id": .string(event.eventID),
            "seq": .number(Double(event.seq)),
            "vendor": .string(event.vendor),
            "workspace_id": .string(event.workspaceID),
            "session_id": .string(event.sessionID),
            "timestamp": .string(event.timestamp),
            "type": .string(event.type.rawValue),
        ]
        if let role = event.role {
            object["role"] = .string(role)
        }
        if let text = event.text {
            object["text"] = .string(text)
        }
        if let name = event.name {
            object["name"] = .string(name)
        }
        if let input = event.input {
            object["input"] = .string(input)
        }
        if let output = event.output {
            object["output"] = .string(output)
        }
        if let toolCallID = event.toolCallID {
            object["tool_call_id"] = .string(toolCallID)
        }
        if let metadata = event.metadata {
            object["metadata"] = .object(metadata.mapValues(JSONValue.string))
        }
        if let payload = event.payload {
            object["payload"] = payload
        }
        return .object(object)
    }
}
