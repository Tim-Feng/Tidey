import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOWebSocket

final class TideyRemoteBridgeServer {
    private let host: String
    private let port: Int
    private let token: String
    private let socketClient: TideySocketClient
    private let eventHub: AgentEventHub
    private let workspaceEventHub: WorkspaceEventHub
    private let registryMonitor: AgentSessionRegistryMonitor
    private let group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)

    init(host: String = "0.0.0.0",
         port: Int = 4817,
         token: String,
         socketClient: TideySocketClient,
         eventHub: AgentEventHub,
         workspaceEventHub: WorkspaceEventHub,
         registryMonitor: AgentSessionRegistryMonitor) {
        self.host = host
        self.port = port
        self.token = token
        self.socketClient = socketClient
        self.eventHub = eventHub
        self.workspaceEventHub = workspaceEventHub
        self.registryMonitor = registryMonitor
    }

    func run() throws {
        try registryMonitor.start()
        let upgrader = NIOWebSocketServerUpgrader(
            shouldUpgrade: { [token] channel, head in
                let authHeader = head.headers.first(name: "Authorization")
                guard authHeader == "Bearer \(token)" else {
                    return channel.eventLoop.makeFailedFuture(BridgeInternalError.unauthorized)
                }
                return channel.eventLoop.makeSucceededFuture([:])
            },
            upgradePipelineHandler: { [socketClient, eventHub, workspaceEventHub] channel, _ in
                channel.pipeline.addHandler(WebSocketFrameHandler(socketClient: socketClient,
                                                                  eventHub: eventHub,
                                                                  workspaceEventHub: workspaceEventHub))
            }
        )

        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 16)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                let httpHandler = HTTPHandler()
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
        print("Tidey Remote Bridge listening on ws://\(host):\(port)")
        print("Pair token: \(token)")
        try channel.closeFuture.wait()
    }

    deinit {
        try? group.syncShutdownGracefully()
    }
}

private final class HTTPHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = unwrapInboundIn(data)
        if case .head(let head) = part, head.uri != "/ws" {
            var headers = HTTPHeaders()
            headers.add(name: "content-length", value: "0")
            let response = HTTPResponseHead(version: head.version, status: .notFound, headers: headers)
            context.write(wrapOutboundOut(.head(response)), promise: nil)
            context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
        }
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
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var agentSubscriptionID: UUID?
    private var workspaceSubscriptionID: UUID?

    init(socketClient: TideySocketClient, eventHub: AgentEventHub, workspaceEventHub: WorkspaceEventHub) {
        self.socketClient = socketClient
        self.eventHub = eventHub
        self.workspaceEventHub = workspaceEventHub
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
                    if let localResult = self.handleLocalRequest(request, context: context) {
                        response = localResult.response
                        agentReplayEnvelopes = localResult.agentReplayEnvelopes
                        workspaceReplayEnvelopes = localResult.workspaceReplayEnvelopes
                    } else {
                        response = try socketClient.send(request)
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
        switch request.action {
        case "subscribe_agent_events":
            let workspaceID = request.params?["workspace_id"]?.stringValue
            unsubscribeFromAgentEvents()

            let (subscriptionID, replayEnvelopes) = eventHub.subscribe(workspaceID: workspaceID) { [weak self, weak context] envelope in
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
}
