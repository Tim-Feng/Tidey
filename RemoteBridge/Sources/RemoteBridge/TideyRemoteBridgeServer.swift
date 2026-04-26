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
    private let observability: BridgeObservabilityCenter
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
         observability: BridgeObservabilityCenter) {
        self.host = host
        self.port = port
        self.token = token
        self.authenticator = authenticator
        self.pairingController = pairingController
        self.socketClient = socketClient
        self.eventHub = eventHub
        self.workspaceEventHub = workspaceEventHub
        self.registryMonitor = registryMonitor
        self.observability = observability
    }

    func run() throws {
        try registryMonitor.start()
        let upgrader = NIOWebSocketServerUpgrader(
            maxFrameSize: Self.maximumWebSocketFrameSizeBytes,
            shouldUpgrade: { [authenticator] channel, head in
                let authHeader = head.headers.first(name: "Authorization")
                guard authenticator.isAuthorized(authorizationHeader: authHeader) else {
                    return channel.eventLoop.makeFailedFuture(BridgeInternalError.unauthorized)
                }
                return channel.eventLoop.makeSucceededFuture([:])
            },
            upgradePipelineHandler: { [socketClient, eventHub, workspaceEventHub, registryMonitor, observability] channel, _ in
                channel.pipeline.addHandler(WebSocketFrameHandler(socketClient: socketClient,
                                                                  eventHub: eventHub,
                                                                  workspaceEventHub: workspaceEventHub,
                                                                  registryMonitor: registryMonitor,
                                                                  observability: observability))
            }
        )

        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 16)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { [token, authenticator, pairingController, port, registryMonitor, eventHub, observability] channel in
                let httpHandler = HTTPHandler(legacyPairToken: token,
                                              authenticator: authenticator,
                                              pairingController: pairingController,
                                              bridgePort: port,
                                              registryMonitor: registryMonitor,
                                              eventHub: eventHub,
                                              observability: observability)
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
        try channel.closeFuture.wait()
    }

    deinit {
        try? group.syncShutdownGracefully()
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
         observability: BridgeObservabilityCenter) {
        self.legacyPairToken = legacyPairToken
        self.authenticator = authenticator
        self.pairingController = pairingController
        self.bridgePort = bridgePort
        self.registryMonitor = registryMonitor
        self.eventHub = eventHub
        self.observability = observability
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
        case "/admin/devices":
            respondToDeviceList(head: head, context: context)
        case "/admin/devices/revoke":
            respondToDeviceRevoke(head: head, body: body, context: context)
        case "/pair/exchange":
            respondToPairExchange(head: head, body: body, context: context)
        case "/ws":
            return
        default:
            respond(status: .notFound, data: Data(), context: context, version: head.version)
        }
    }

    private func respondToPairPayload(head: HTTPRequestHead, context: ChannelHandlerContext) {
        guard authenticator.isLegacyTokenAuthorized(authorizationHeader: head.headers.first(name: "Authorization")) else {
            respond(status: .unauthorized, data: Data(), context: context, version: head.version)
            return
        }
        do {
            let endpoints = BridgeLANEndpointResolver.resolve(port: bridgePort)
            let payload = try pairingController.createPairPayload(lanEndpoints: endpoints)
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

private final class WebSocketFrameHandler: ChannelInboundHandler {
    typealias InboundIn = WebSocketFrame
    typealias OutboundOut = WebSocketFrame

    private struct LocalRequestResult {
        let response: BridgeResponse
        let agentReplayEnvelopes: [AgentEventEnvelope]
        let workspaceReplayEnvelopes: [WorkspaceEventEnvelope]
    }

    private let socketClient: TideySocketClient
    private let eventHub: AgentEventHub
    private let workspaceEventHub: WorkspaceEventHub
    private let registryMonitor: AgentSessionRegistryMonitor
    private let observability: BridgeObservabilityCenter
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private lazy var inputActionHandler = BridgeInputActionHandler(socketSender: socketClient,
                                                                   sessionResolver: registryMonitor)
    private lazy var fileActionHandler = BridgeFileActionHandler(rootResolver: TideyPanelFileRootResolver(socketSender: socketClient))
    private lazy var imageUploadHandler = BridgeImageUploadHandler(destinationResolver: DownloadsImageUploadDestinationResolver(),
                                                                   filenameGenerator: TimestampedImageUploadFilenameGenerator())
    private var agentSubscriptionID: UUID?
    private var workspaceSubscriptionID: UUID?

    init(socketClient: TideySocketClient,
         eventHub: AgentEventHub,
         workspaceEventHub: WorkspaceEventHub,
         registryMonitor: AgentSessionRegistryMonitor,
         observability: BridgeObservabilityCenter) {
        self.socketClient = socketClient
        self.eventHub = eventHub
        self.workspaceEventHub = workspaceEventHub
        self.registryMonitor = registryMonitor
        self.observability = observability
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)
        switch frame.opcode {
        case .connectionClose:
            context.close(promise: nil)
        case .ping:
            var buffer = context.channel.allocator.buffer(capacity: frame.data.readableBytes)
            var data = frame.unmaskedData
            buffer.writeBuffer(&data)
            let pong = WebSocketFrame(fin: true, opcode: .pong, data: buffer)
            context.writeAndFlush(wrapOutboundOut(pong), promise: nil)
        case .text:
            var data = frame.unmaskedData
            guard let text = data.readString(length: data.readableBytes) else {
                send(response: BridgeResponse(id: nil, ok: false, result: nil, error: BridgeInternalError.invalidRequest("Invalid UTF-8 message.").payload),
                     to: context)
                return
            }
            DispatchQueue.global(qos: .userInitiated).async { [decoder, socketClient] in
                let response: BridgeResponse
                var agentReplayEnvelopes = [AgentEventEnvelope]()
                var workspaceReplayEnvelopes = [WorkspaceEventEnvelope]()
                do {
                    let request = try decoder.decode(BridgeRequest.self, from: Data(text.utf8))
                    if request.action == "image_upload" {
                        BridgeImageUploadDiagnostics.log("server received request_id=\(request.id) action=\(request.action) params_keys=\(request.params?.keys.sorted().joined(separator: ",") ?? "-") base64_length=\(request.params?["data_base64"]?.stringValue?.count ?? 0)")
                    }
                    if let localResult = self.handleLocalRequest(request, context: context) {
                        response = localResult.response
                        agentReplayEnvelopes = localResult.agentReplayEnvelopes
                        workspaceReplayEnvelopes = localResult.workspaceReplayEnvelopes
                    } else {
                        response = self.augment(response: try socketClient.send(request), for: request)
                    }
                } catch let error as BridgeInternalError {
                    response = BridgeResponse(id: nil, ok: false, result: nil, error: error.payload)
                } catch let error as DecodingError {
                    response = BridgeResponse(id: nil, ok: false, result: nil, error: BridgeInternalError.invalidRequest(error.localizedDescription).payload)
                } catch {
                    response = BridgeResponse(id: nil, ok: false, result: nil, error: BridgeErrorPayload(code: "bridge_error", message: error.localizedDescription))
                }
                context.eventLoop.execute {
                    self.send(response: response, to: context)
                    for envelope in agentReplayEnvelopes {
                        self.send(envelope: envelope, to: context)
                    }
                    for envelope in workspaceReplayEnvelopes {
                        self.send(workspaceEnvelope: envelope, to: context)
                    }
                }
            }
        default:
            break
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        unsubscribeFromAgentEvents()
        unsubscribeFromWorkspaceEvents()
        context.fireChannelInactive()
    }

    private func handleLocalRequest(_ request: BridgeRequest,
                                    context: ChannelHandlerContext) -> LocalRequestResult? {
        do {
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
            if let response = try imageUploadHandler.handle(request) {
                BridgeImageUploadDiagnostics.log("local dispatch handled_by=image_upload request_id=\(request.id) ok=\(response.ok)")
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

            let sessionID = request.params?["session_id"]?.stringValue
            let beforeSeq = request.params?["before_seq"]?.intValue
            let afterSeq = request.params?["after_seq"]?.intValue
            let maxBytes = request.params?["max_bytes"]?.intValue
            if beforeSeq != nil, afterSeq != nil {
                return LocalRequestResult(
                    response: BridgeResponse(id: request.id,
                                             ok: false,
                                             result: nil,
                                             error: BridgeInternalError.invalidRequest("fetch_agent_events accepts either before_seq or after_seq, not both").payload),
                    agentReplayEnvelopes: [],
                    workspaceReplayEnvelopes: []
                )
            }
            var fetchResult = eventHub.fetch(workspaceID: workspaceID,
                                             sessionID: sessionID,
                                             limit: limit,
                                             maxBytes: maxBytes,
                                             beforeSeq: beforeSeq,
                                             afterSeq: afterSeq)
            var didBackfill = false
            if let sessionID,
               let beforeSeq,
               !fetchResult.hasMore {
                let backfilled = registryMonitor.backfillSession(sessionID: sessionID,
                                                                 beforeSeq: beforeSeq,
                                                                 limit: max(limit, transcriptBootstrapLineLimit))
                if backfilled {
                    didBackfill = true
                    fetchResult = eventHub.fetch(workspaceID: workspaceID,
                                                 sessionID: sessionID,
                                                 limit: limit,
                                                 maxBytes: maxBytes,
                                                 beforeSeq: beforeSeq,
                                                 afterSeq: nil)
                }
            } else if let sessionID, let afterSeq {
                while let earliestBufferedSeq = eventHub.oldestBufferedSeq(sessionID: sessionID),
                      earliestBufferedSeq > afterSeq + 1 {
                    let backfilled = registryMonitor.backfillSession(sessionID: sessionID,
                                                                     beforeSeq: earliestBufferedSeq,
                                                                     limit: max(limit, transcriptBootstrapLineLimit))
                    guard backfilled else {
                        break
                    }
                    didBackfill = true
                    fetchResult = eventHub.fetch(workspaceID: workspaceID,
                                                 sessionID: sessionID,
                                                 limit: limit,
                                                 maxBytes: maxBytes,
                                                 beforeSeq: nil,
                                                 afterSeq: afterSeq)
                }
            }
            observability.recordFetch(workspaceID: workspaceID,
                                      sessionID: sessionID,
                                      limit: limit,
                                      beforeSeq: beforeSeq,
                                      afterSeq: afterSeq,
                                      returnedCount: fetchResult.events.count,
                                      didBackfill: didBackfill,
                                      durationMs: (CFAbsoluteTimeGetCurrent() - startedAt) * 1000)
            return LocalRequestResult(
                response: BridgeResponse(id: request.id,
                                         ok: true,
                                         result: [
                                            "events": .array(fetchResult.events.map(Self.jsonValue(for:))),
                                            "oldest_seq": .number(Double(fetchResult.oldestSeq)),
                                            "newest_seq": .number(Double(fetchResult.newestSeq)),
                                            "has_more": .bool(fetchResult.hasMore),
                                         ],
                                         error: nil),
                agentReplayEnvelopes: [],
                workspaceReplayEnvelopes: []
            )

        case "subscribe_agent_events":
            let workspaceID = request.params?["workspace_id"]?.stringValue
            let sessionID = request.params?["session_id"]?.stringValue
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
            let sinceSeq = request.params?["since_seq"]?.intValue
            let noReplay = request.params?["no_replay"]?.boolLikeValue ?? false
            unsubscribeFromAgentEvents()

            let (subscriptionID, replayEnvelopes) = eventHub.subscribe(workspaceID: workspaceID,
                                                                       sessionID: sessionID,
                                                                       sinceSeq: noReplay ? Int.max : sinceSeq) { [weak self, weak context] envelope in
                guard let self, let context else {
                    return
                }
                context.eventLoop.execute {
                    self.send(envelope: envelope, to: context)
                }
            }
            self.agentSubscriptionID = subscriptionID
            return LocalRequestResult(
                response: BridgeResponse(id: request.id,
                                         ok: true,
                                         result: [
                                            "subscribed": .bool(true),
                                            "workspace_id": workspaceID.map(JSONValue.string) ?? .null,
                                            "session_id": sessionID.map(JSONValue.string) ?? .null,
                                            "no_replay": .bool(noReplay),
                                            "replay_count": .number(Double(replayEnvelopes.count)),
                                         ],
                                         error: nil),
                agentReplayEnvelopes: replayEnvelopes,
                workspaceReplayEnvelopes: []
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
                                            "replay_count": .number(0),
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

        default:
            return nil
        }
    }

    private func unsubscribeFromAgentEvents() {
        if let agentSubscriptionID {
            eventHub.unsubscribe(agentSubscriptionID)
            self.agentSubscriptionID = nil
        }
    }

    private func unsubscribeFromWorkspaceEvents() {
        if let workspaceSubscriptionID {
            workspaceEventHub.unsubscribe(workspaceSubscriptionID)
            self.workspaceSubscriptionID = nil
        }
    }

    private func augment(response: BridgeResponse, for request: BridgeRequest) -> BridgeResponse {
        guard response.ok, let result = response.result else {
            return response
        }
        switch request.action {
        case "list_panels":
            recordPanelListResult(result)
            return BridgeResponse(id: response.id,
                                  ok: response.ok,
                                  v: response.v,
                                  result: augmentPanelListResult(result),
                                  error: response.error)
        case "list_workspaces":
            refreshLivePanelsForListedWorkspaces(result)
            return BridgeResponse(id: response.id,
                                  ok: response.ok,
                                  v: response.v,
                                  result: augmentWorkspaceListResult(result),
                                  error: response.error)
        default:
            return response
        }
    }

    private func refreshLivePanelsForListedWorkspaces(_ result: [String: JSONValue]) {
        guard let workspaces = result["workspaces"]?.arrayValue else {
            return
        }

        let workspaceIDs = Set(workspaces.compactMap { $0.objectValue?["workspace_id"]?.stringValue })
        registryMonitor.pruneLivePanels(toWorkspaceIDs: workspaceIDs)

        for workspaceID in workspaceIDs {
            let request = BridgeRequest(id: UUID().uuidString,
                                        action: "list_panels",
                                        params: ["workspace_id": .string(workspaceID)])
            let panelResponse = try? socketClient.send(request)
            guard let panelResult = panelResponse?.result else {
                registryMonitor.replaceLivePanels(workspaceID: workspaceID, panels: [])
                continue
            }
            recordPanelListResult(panelResult)
        }
    }

    private func recordPanelListResult(_ result: [String: JSONValue]) {
        guard let workspaceID = result["workspace_id"]?.stringValue,
              let panels = result["panels"]?.arrayValue else {
            return
        }

        let snapshots = panels.compactMap { Self.panelProcessSnapshot(from: $0, defaultWorkspaceID: workspaceID) }
        registryMonitor.replaceLivePanels(workspaceID: workspaceID, panels: snapshots)
    }

    private static func panelProcessSnapshot(from panelValue: JSONValue,
                                             defaultWorkspaceID: String) -> AgentPanelProcessSnapshot? {
        guard let panel = panelValue.objectValue,
              let panelID = panel["panel_id"]?.stringValue else {
            return nil
        }

        let workspaceID = panel["workspace_id"]?.stringValue ?? defaultWorkspaceID
        let effectiveShellPID = panel["effective_shell_pid"]?.intValue.flatMap(Int32.init)
        return AgentPanelProcessSnapshot(workspaceID: workspaceID,
                                         panelID: panelID,
                                         effectiveShellPID: effectiveShellPID)
    }

    private func augmentPanelListResult(_ result: [String: JSONValue]) -> [String: JSONValue] {
        guard let workspaceID = result["workspace_id"]?.stringValue,
              let panels = result["panels"]?.arrayValue else {
            return result
        }

        let augmentedPanels = panels.map { panelValue -> JSONValue in
            guard var panel = panelValue.objectValue,
                  let panelID = panel["panel_id"]?.stringValue else {
                return panelValue
            }
            let effectiveShellPID = panel["effective_shell_pid"]?.intValue.flatMap(Int32.init)
            if let session = registryMonitor.activeSessionForPanel(workspaceID: workspaceID,
                                                                   panelID: panelID,
                                                                   effectiveShellPID: effectiveShellPID) {
                panel["agent_session"] = .object([
                    "vendor": .string(session.vendor),
                    "session_id": .string(session.sessionID),
                ])
            }
            return .object(panel)
        }

        var augmented = result
        augmented["panels"] = .array(augmentedPanels)
        return augmented
    }

    private func augmentWorkspaceListResult(_ result: [String: JSONValue]) -> [String: JSONValue] {
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
            return .object(workspace)
        }

        var augmented = result
        augmented["workspaces"] = .array(augmentedWorkspaces)
        return augmented
    }

    private func send(response: BridgeResponse, to context: ChannelHandlerContext) {
        do {
            let payload = try encoder.encode(response)
            var buffer = context.channel.allocator.buffer(capacity: payload.count)
            buffer.writeBytes(payload)
            let frame = WebSocketFrame(fin: true, opcode: .text, data: buffer)
            context.writeAndFlush(wrapOutboundOut(frame), promise: nil)
        } catch {
            context.close(promise: nil)
        }
    }

    private func send(envelope: AgentEventEnvelope, to context: ChannelHandlerContext) {
        do {
            let payload = try encoder.encode(envelope)
            var buffer = context.channel.allocator.buffer(capacity: payload.count)
            buffer.writeBytes(payload)
            let frame = WebSocketFrame(fin: true, opcode: .text, data: buffer)
            context.writeAndFlush(wrapOutboundOut(frame), promise: nil)
        } catch {
            context.close(promise: nil)
        }
    }

    private func send(workspaceEnvelope: WorkspaceEventEnvelope, to context: ChannelHandlerContext) {
        do {
            let payload = try encoder.encode(workspaceEnvelope)
            var buffer = context.channel.allocator.buffer(capacity: payload.count)
            buffer.writeBytes(payload)
            let frame = WebSocketFrame(fin: true, opcode: .text, data: buffer)
            context.writeAndFlush(wrapOutboundOut(frame), promise: nil)
        } catch {
            context.close(promise: nil)
        }
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
        return .object(object)
    }
}
