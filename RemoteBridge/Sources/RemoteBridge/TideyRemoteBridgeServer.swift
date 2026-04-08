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
    private let group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)

    init(host: String = "127.0.0.1", port: Int = 4817, token: String, socketClient: TideySocketClient) {
        self.host = host
        self.port = port
        self.token = token
        self.socketClient = socketClient
    }

    func run() throws {
        let upgrader = NIOWebSocketServerUpgrader(
            shouldUpgrade: { [token] channel, head in
                let authHeader = head.headers.first(name: "Authorization")
                guard authHeader == "Bearer \(token)" else {
                    return channel.eventLoop.makeFailedFuture(BridgeInternalError.unauthorized)
                }
                return channel.eventLoop.makeSucceededFuture([:])
            },
            upgradePipelineHandler: { [socketClient] channel, _ in
                channel.pipeline.addHandler(WebSocketFrameHandler(socketClient: socketClient))
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

    private let socketClient: TideySocketClient
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(socketClient: TideySocketClient) {
        self.socketClient = socketClient
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
            DispatchQueue.global(qos: .userInitiated).async { [decoder, encoder, socketClient] in
                let response: BridgeResponse
                do {
                    let request = try decoder.decode(BridgeRequest.self, from: Data(text.utf8))
                    response = try socketClient.send(request)
                } catch let error as BridgeInternalError {
                    response = BridgeResponse(id: nil, ok: false, result: nil, error: error.payload)
                } catch let error as DecodingError {
                    response = BridgeResponse(id: nil, ok: false, result: nil, error: BridgeInternalError.invalidRequest(error.localizedDescription).payload)
                } catch {
                    response = BridgeResponse(id: nil, ok: false, result: nil, error: BridgeErrorPayload(code: "bridge_error", message: error.localizedDescription))
                }
                context.eventLoop.execute {
                    do {
                        let payload = try encoder.encode(response)
                        var buffer = context.channel.allocator.buffer(capacity: payload.count)
                        buffer.writeBytes(payload)
                        let frame = WebSocketFrame(fin: true, opcode: .text, data: buffer)
                        context.writeAndFlush(self.wrapOutboundOut(frame), promise: nil)
                    } catch {
                        context.close(promise: nil)
                    }
                }
            }
        default:
            break
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
}
