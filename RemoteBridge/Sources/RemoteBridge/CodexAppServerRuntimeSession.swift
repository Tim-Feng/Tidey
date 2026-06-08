import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOWebSocket

enum CodexAppServerProcessError: Error {
    case closed
    case invalidUTF8
}

protocol CodexAppServerManagedProcess: AnyObject {
    var processID: Int32? { get }
    func sendLine(_ line: String) throws
    func terminate()
}

protocol CodexAppServerProcessRunning {
    func start(configuration: CodexAppServerLaunchConfiguration,
               onStdoutLine: @escaping @Sendable (String) -> Void,
               onStderrLine: @escaping @Sendable (String) -> Void,
               onExit: @escaping @Sendable (Int32) -> Void) throws -> CodexAppServerManagedProcess
}

enum CodexAppServerTransportError: Error {
    case unsupported(CodexAppServerTransportMode)
    case closed
    case invalidUTF8
}

protocol CodexAppServerConnectionTransport: AnyObject {
    func sendLine(_ line: String) throws
    func close()
}

protocol CodexAppServerTransportConnecting {
    func connect(mode: CodexAppServerTransportMode,
                 onLine: @escaping @Sendable (String) -> Void,
                 onClose: @escaping @Sendable (Error?) -> Void) throws -> CodexAppServerConnectionTransport
}

final class CodexAppServerRuntimeSession {
    private let process: CodexAppServerManagedProcess
    private let transport: CodexAppServerConnectionTransport
    private let connection: CodexAppServerConnection
    private let runtime: CodexAppServerHeadlessRuntime
    private let initialization: CodexAppServerInitializationState
    private let activeThreadStore: CodexAppServerActiveThreadStore
    private let lock = NSLock()
    private var stopped = false

    init(process: CodexAppServerManagedProcess,
         transport: CodexAppServerConnectionTransport,
         connection: CodexAppServerConnection,
         runtime: CodexAppServerHeadlessRuntime,
         initialization: CodexAppServerInitializationState = CodexAppServerInitializationState(),
         activeThreadStore: CodexAppServerActiveThreadStore = CodexAppServerActiveThreadStore()) {
        self.process = process
        self.transport = transport
        self.connection = connection
        self.runtime = runtime
        self.initialization = initialization
        self.activeThreadStore = activeThreadStore
    }

    var processID: Int32? {
        process.processID
    }

    @discardableResult
    func startThread(cwd: String?,
                     model: String? = nil,
                     approvalPolicy: String? = nil,
                     sandbox: JSONValue? = nil,
                     ephemeral: Bool = true,
                     onResponse: @escaping CodexAppServerConnection.ClientResponseHandler = { _ in }) throws -> Int {
        try initialization.wait()
        return try runtime.startThread(on: connection,
                                       cwd: cwd,
                                       model: model,
                                       approvalPolicy: approvalPolicy,
                                       sandbox: sandbox,
                                       ephemeral: ephemeral,
                                       onResponse: onResponse)
    }

    @discardableResult
    func listLoadedThreads(onResponse: @escaping CodexAppServerConnection.ClientResponseHandler = { _ in }) throws -> Int {
        try initialization.wait()
        return try runtime.listLoadedThreads(on: connection,
                                             onResponse: onResponse)
    }

    @discardableResult
    func resumeThread(threadID: String,
                      cwd: String?,
                      onResponse: @escaping CodexAppServerConnection.ClientResponseHandler = { _ in }) throws -> Int {
        try initialization.wait()
        return try runtime.resumeThread(on: connection,
                                        threadID: threadID,
                                        cwd: cwd,
                                        onResponse: onResponse)
    }

    @discardableResult
    func startTurn(threadID: String,
                   text: String,
                   cwd: String? = nil,
                   approvalPolicy: String? = nil,
                   sandboxPolicy: JSONValue? = nil,
                   onResponse: @escaping CodexAppServerConnection.ClientResponseHandler = { _ in }) throws -> Int {
        try initialization.wait()
        return try runtime.startTurn(on: connection,
                                     threadID: threadID,
                                     text: text,
                                     cwd: cwd,
                                     approvalPolicy: approvalPolicy,
                                     sandboxPolicy: sandboxPolicy,
                                     onResponse: onResponse)
    }

    @discardableResult
    func submitApproval(promptID: String, targetIndex: Int) throws -> AgentEvent {
        try connection.submitApproval(promptID: promptID, targetIndex: targetIndex)
    }

    func submitMessage(text: String) throws {
        try initialization.wait()
        guard let threadID = try currentThreadIDForSubmit() else {
            throw BridgeInternalError.invalidRequest("Codex app-server thread is not ready.")
        }
        try runtime.startTurn(on: connection,
                              threadID: threadID,
                              text: text)
    }

    private func currentThreadIDForSubmit() throws -> String? {
        if let threadID = activeThreadStore.currentThreadID() {
            return threadID
        }
        return try loadCurrentThreadID()
    }

    private func loadCurrentThreadID(timeout: TimeInterval = 5) throws -> String? {
        let condition = NSCondition()
        var result: Result<String?, Error>?
        try connection.sendClientRequest(method: "thread/loaded/list") { response in
            condition.lock()
            switch response {
            case .success(let value):
                let threadID = codexAppServerLoadedThreadID(from: value)
                if let threadID {
                    self.activeThreadStore.setThreadID(threadID)
                } else {
                    BridgeLogger.server.info("codex app-server submit loaded thread list returned no thread shape=\(codexAppServerLoadedThreadShapeDescription(from: value), privacy: .public)")
                }
                result = .success(threadID)
            case .failure(let error):
                result = .failure(error)
            }
            condition.broadcast()
            condition.unlock()
        }

        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }
        while result == nil {
            if condition.wait(until: deadline) == false {
                throw CodexAppServerConnectionError.initializationTimedOut
            }
        }
        return try result?.get()
    }

    func stop() {
        lock.lock()
        guard stopped == false else {
            lock.unlock()
            return
        }
        stopped = true
        lock.unlock()

        initialization.fail(CodexAppServerConnectionError.closed)
        connection.close()
        transport.close()
        process.terminate()
    }

    func handleProcessExit(exitCode: Int32) {
        lock.lock()
        stopped = true
        lock.unlock()
        initialization.fail(CodexAppServerConnectionError.closed)
        connection.close()
    }

    func whenInitialized(_ callback: @escaping @Sendable (Result<Void, Error>) -> Void) {
        initialization.notify(callback)
    }
}

final class CodexAppServerActiveThreadStore: @unchecked Sendable {
    private let lock = NSLock()
    private var threadID: String?

    func setThreadID(_ threadID: String) {
        lock.lock()
        self.threadID = threadID
        lock.unlock()
    }

    func currentThreadID() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return threadID
    }
}

final class CodexAppServerInitializationState: @unchecked Sendable {
    private enum State {
        case pending
        case ready
        case failed(Error)
    }

    private let condition = NSCondition()
    private var state: State = .pending
    private var callbacks: [@Sendable (Result<Void, Error>) -> Void] = []

    func succeed() {
        complete(.ready)
    }

    func fail(_ error: Error) {
        complete(.failed(error))
    }

    func wait(timeout: TimeInterval = 10) throws {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }

        while true {
            switch state {
            case .ready:
                return
            case .failed(let error):
                throw error
            case .pending:
                let shouldContinue = condition.wait(until: deadline)
                if shouldContinue == false {
                    state = .failed(CodexAppServerConnectionError.initializationTimedOut)
                    condition.broadcast()
                    throw CodexAppServerConnectionError.initializationTimedOut
                }
            }
        }
    }

    private func complete(_ newState: State) {
        let result: Result<Void, Error>
        switch newState {
        case .ready:
            result = .success(())
        case .failed(let error):
            result = .failure(error)
        case .pending:
            return
        }

        condition.lock()
        guard case .pending = state else {
            condition.unlock()
            return
        }
        state = newState
        let callbacks = callbacks
        self.callbacks.removeAll()
        condition.broadcast()
        condition.unlock()
        for callback in callbacks {
            callback(result)
        }
    }

    func notify(_ callback: @escaping @Sendable (Result<Void, Error>) -> Void) {
        let result: Result<Void, Error>?
        condition.lock()
        switch state {
        case .pending:
            callbacks.append(callback)
            result = nil
        case .ready:
            result = .success(())
        case .failed(let error):
            result = .failure(error)
        }
        condition.unlock()

        if let result {
            callback(result)
        }
    }
}

final class CodexAppServerRuntimeSessionFactory {
    private let processRunner: CodexAppServerProcessRunning
    private let transportConnector: CodexAppServerTransportConnecting

    init(processRunner: CodexAppServerProcessRunning = CodexAppServerProcessRunner(),
         transportConnector: CodexAppServerTransportConnecting = CodexAppServerWebSocketTransportConnector()) {
        self.processRunner = processRunner
        self.transportConnector = transportConnector
    }

    func start(configuration: CodexAppServerLaunchConfiguration,
               context: CodexAppServerRuntimeContext,
               nextSequence: @escaping CodexAppServerConnection.SequenceProvider,
               timestampProvider: @escaping CodexAppServerConnection.TimestampProvider,
               onAgentEvent: @escaping CodexAppServerHeadlessRuntime.AgentEventHandler,
               onInteractivePrompt: @escaping CodexAppServerConnection.InteractivePromptHandler,
               onInteractivePromptResolved: @escaping CodexAppServerConnection.InteractivePromptResolvedHandler,
               onStderrLine: @escaping @Sendable (String) -> Void = { _ in },
               onExit: @escaping @Sendable (Int32) -> Void = { _ in }) throws -> CodexAppServerRuntimeSession {
        let stdoutRouter = CodexAppServerConnectionLineRouter()
        let exitRouter = CodexAppServerRuntimeSessionExitRouter(onExit: onExit)
        let process = try processRunner.start(configuration: configuration,
                                              onStdoutLine: { line in
                                                  stdoutRouter.receive(line)
                                              },
                                              onStderrLine: onStderrLine,
                                              onExit: { exitCode in
                                                  exitRouter.receive(exitCode)
                                              })
        let transport: CodexAppServerConnectionTransport
        switch configuration.transport {
        case .stdio:
            transport = CodexAppServerStdioTransport(process: process)
        case .unixSocket:
            transport = try transportConnector.connect(mode: configuration.transport,
                                                       onLine: { line in
                                                           stdoutRouter.receive(line)
                                                       },
                                                       onClose: { error in
                                                           if let error {
                                                               BridgeLogger.server.error("codex app-server websocket closed error=\(String(describing: error), privacy: .public)")
                                                           }
                                                       })
        }
        let activeThreadStore = CodexAppServerActiveThreadStore()
        let runtime = CodexAppServerHeadlessRuntime(context: context,
                                                    nextSequence: nextSequence,
                                                    timestampProvider: timestampProvider,
                                                    onAgentEvent: onAgentEvent,
                                                    onThreadID: activeThreadStore.setThreadID)
        let connection = CodexAppServerConnection(sendLine: { line in
            try transport.sendLine(line)
        },
                                                   onNotification: runtime.handleNotification,
                                                   approvalContext: CodexAppServerApprovalContext(workspaceID: context.workspaceID,
                                                                                                  panelID: context.panelID,
                                                                                                  sessionID: context.sessionID),
                                                   nextSequence: nextSequence,
                                                   timestampProvider: timestampProvider,
                                                   onInteractivePrompt: onInteractivePrompt,
                                                   onInteractivePromptResolved: onInteractivePromptResolved)
        let initialization = CodexAppServerInitializationState()
        let runtimeSession = CodexAppServerRuntimeSession(process: process,
                                                          transport: transport,
                                                          connection: connection,
                                                          runtime: runtime,
                                                          initialization: initialization,
                                                          activeThreadStore: activeThreadStore)
        exitRouter.attach(runtimeSession)
        stdoutRouter.attach(connection)
        try connection.sendClientRequest(method: "initialize",
                                         params: [
                                            "clientInfo": .object([
                                                "name": .string("tidey-bridge"),
                                                "title": .string("Tidey Remote Bridge"),
                                                "version": .string("0"),
                                            ]),
                                            "capabilities": .object([
                                                "experimentalApi": .bool(true),
                                                "requestAttestation": .bool(false),
                                                "optOutNotificationMethods": .array([]),
                                            ]),
                                         ]) { result in
            switch result {
            case .success:
                do {
                    try connection.sendClientNotification(method: "initialized")
                    initialization.succeed()
                } catch {
                    initialization.fail(error)
                    BridgeLogger.server.error("codex app-server initialized notification failed error=\(String(describing: error), privacy: .public)")
                }
            case .failure(let error):
                initialization.fail(error)
                BridgeLogger.server.error("codex app-server initialize failed error=\(String(describing: error), privacy: .public)")
            }
        }
        return runtimeSession
    }

    func attach(socketPath: String,
                processID: Int32?,
                context: CodexAppServerRuntimeContext,
                nextSequence: @escaping CodexAppServerConnection.SequenceProvider,
                timestampProvider: @escaping CodexAppServerConnection.TimestampProvider,
                onAgentEvent: @escaping CodexAppServerHeadlessRuntime.AgentEventHandler,
                onInteractivePrompt: @escaping CodexAppServerConnection.InteractivePromptHandler,
                onInteractivePromptResolved: @escaping CodexAppServerConnection.InteractivePromptResolvedHandler) throws -> CodexAppServerRuntimeSession {
        let stdoutRouter = CodexAppServerConnectionLineRouter()
        let process = CodexAppServerExternalProcess(processID: processID)
        let transport = try transportConnector.connect(mode: .unixSocket(path: socketPath),
                                                       onLine: { line in
                                                           stdoutRouter.receive(line)
                                                       },
                                                       onClose: { error in
                                                           if let error {
                                                               BridgeLogger.server.error("codex app-server panel socket closed error=\(String(describing: error), privacy: .public)")
                                                           }
                                                       })
        let activeThreadStore = CodexAppServerActiveThreadStore()
        let runtime = CodexAppServerHeadlessRuntime(context: context,
                                                    nextSequence: nextSequence,
                                                    timestampProvider: timestampProvider,
                                                    onAgentEvent: onAgentEvent,
                                                    onThreadID: activeThreadStore.setThreadID)
        let connection = CodexAppServerConnection(sendLine: { line in
            try transport.sendLine(line)
        },
                                                   onNotification: runtime.handleNotification,
                                                   approvalContext: CodexAppServerApprovalContext(workspaceID: context.workspaceID,
                                                                                                  panelID: context.panelID,
                                                                                                  sessionID: context.sessionID),
                                                   nextSequence: nextSequence,
                                                   timestampProvider: timestampProvider,
                                                   onInteractivePrompt: onInteractivePrompt,
                                                   onInteractivePromptResolved: onInteractivePromptResolved)
        let initialization = CodexAppServerInitializationState()
        let runtimeSession = CodexAppServerRuntimeSession(process: process,
                                                          transport: transport,
                                                          connection: connection,
                                                          runtime: runtime,
                                                          initialization: initialization,
                                                          activeThreadStore: activeThreadStore)
        stdoutRouter.attach(connection)
        try connection.sendClientRequest(method: "initialize",
                                         params: [
                                            "clientInfo": .object([
                                                "name": .string("tidey-bridge"),
                                                "title": .string("Tidey Remote Bridge"),
                                                "version": .string("0"),
                                            ]),
                                            "capabilities": .object([
                                                "experimentalApi": .bool(true),
                                                "requestAttestation": .bool(false),
                                                "optOutNotificationMethods": .array([]),
                                            ]),
                                         ]) { result in
            switch result {
            case .success:
                do {
                    try connection.sendClientNotification(method: "initialized")
                    initialization.succeed()
                    Self.resumeLoadedThreadIfAvailable(on: connection,
                                                       activeThreadStore: activeThreadStore)
                } catch {
                    initialization.fail(error)
                    BridgeLogger.server.error("codex app-server panel initialized notification failed error=\(String(describing: error), privacy: .public)")
                }
            case .failure(let error):
                initialization.fail(error)
                BridgeLogger.server.error("codex app-server panel initialize failed error=\(String(describing: error), privacy: .public)")
            }
        }
        return runtimeSession
    }

    private static func resumeLoadedThreadIfAvailable(on connection: CodexAppServerConnection,
                                                      activeThreadStore: CodexAppServerActiveThreadStore) {
        do {
            try connection.sendClientRequest(method: "thread/loaded/list") { result in
                switch result {
                case .success(let value):
                    guard let threadID = codexAppServerLoadedThreadID(from: value) else {
                        BridgeLogger.server.info("codex app-server panel loaded thread list returned no thread shape=\(codexAppServerLoadedThreadShapeDescription(from: value), privacy: .public)")
                        return
                    }
                    activeThreadStore.setThreadID(threadID)
                    do {
                        try connection.sendClientRequest(method: "thread/resume",
                                                        params: [
                                                            "threadId": .string(threadID),
                                                            "excludeTurns": .bool(false),
                                                        ],
                                                        onResponse: { response in
                                                            if case .failure(let error) = response {
                                                                BridgeLogger.server.error("codex app-server panel thread resume failed thread_id=\(threadID, privacy: .public) error=\(String(describing: error), privacy: .public)")
                                                            }
                                                        })
                    } catch {
                        BridgeLogger.server.error("codex app-server panel thread resume request failed thread_id=\(threadID, privacy: .public) error=\(String(describing: error), privacy: .public)")
                    }
                case .failure(let error):
                    BridgeLogger.server.error("codex app-server panel loaded thread list failed error=\(String(describing: error), privacy: .public)")
                }
            }
        } catch {
            BridgeLogger.server.error("codex app-server panel loaded thread list request failed error=\(String(describing: error), privacy: .public)")
        }
    }

}

private func codexAppServerLoadedThreadID(from value: JSONValue) -> String? {
    if let object = value.objectValue {
        if let thread = object["thread"]?.objectValue,
           let id = thread["id"]?.stringValue ?? thread["threadId"]?.stringValue {
            return id
        }
        if let thread = object["currentThread"]?.objectValue,
           let id = thread["id"]?.stringValue ?? thread["threadId"]?.stringValue {
            return id
        }
    }
    let threads = value.objectValue?["threads"]?.arrayValue
        ?? value.objectValue?["items"]?.arrayValue
        ?? value.objectValue?["loadedThreads"]?.arrayValue
        ?? value.objectValue?["data"]?.arrayValue
        ?? value.arrayValue
        ?? []
    return threads
        .compactMap { item -> String? in
            if let id = item.stringValue {
                return id
            }
            if let id = item.objectValue?["id"]?.stringValue ?? item.objectValue?["threadId"]?.stringValue {
                return id
            }
            if let thread = item.objectValue?["thread"]?.objectValue {
                return thread["id"]?.stringValue ?? thread["threadId"]?.stringValue
            }
            return nil
        }
        .last
}

private func codexAppServerLoadedThreadShapeDescription(from value: JSONValue) -> String {
    if let object = value.objectValue {
        let keys = object.keys.sorted().joined(separator: ",")
        let collectionCount = object["threads"]?.arrayValue?.count
            ?? object["items"]?.arrayValue?.count
            ?? object["loadedThreads"]?.arrayValue?.count
            ?? object["data"]?.arrayValue?.count
            ?? -1
        let firstKeys = (object["threads"]?.arrayValue?.first?.objectValue
            ?? object["items"]?.arrayValue?.first?.objectValue
            ?? object["loadedThreads"]?.arrayValue?.first?.objectValue
            ?? object["data"]?.arrayValue?.first?.objectValue)?
            .keys
            .sorted()
            .joined(separator: ",") ?? "-"
        return "object_keys=\(keys) collection_count=\(collectionCount) first_object_keys=\(firstKeys)"
    }
    if let array = value.arrayValue {
        let firstKeys = array.first?.objectValue?.keys.sorted().joined(separator: ",") ?? "-"
        return "array_count=\(array.count) first_object_keys=\(firstKeys)"
    }
    return "scalar"
}

private final class CodexAppServerExternalProcess: CodexAppServerManagedProcess {
    let processID: Int32?

    init(processID: Int32?) {
        self.processID = processID
    }

    func sendLine(_ line: String) throws {
        throw CodexAppServerProcessError.closed
    }

    func terminate() {}
}

private final class CodexAppServerStdioTransport: CodexAppServerConnectionTransport {
    private let process: CodexAppServerManagedProcess

    init(process: CodexAppServerManagedProcess) {
        self.process = process
    }

    func sendLine(_ line: String) throws {
        try process.sendLine(line)
    }

    func close() {}
}

final class CodexAppServerWebSocketTransportConnector: CodexAppServerTransportConnecting {
    private static let maximumWebSocketFrameSizeBytes = 16 * 1024 * 1024

    private let group: EventLoopGroup
    private let ownsGroup: Bool

    init(group: EventLoopGroup? = nil) {
        if let group {
            self.group = group
            self.ownsGroup = false
        } else {
            self.group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
            self.ownsGroup = true
        }
    }

    func connect(mode: CodexAppServerTransportMode,
                 onLine: @escaping @Sendable (String) -> Void,
                 onClose: @escaping @Sendable (Error?) -> Void) throws -> CodexAppServerConnectionTransport {
        guard case .unixSocket(let socketPath) = mode else {
            throw CodexAppServerTransportError.unsupported(mode)
        }

        let deadline = Date().addingTimeInterval(5)
        repeat {
            do {
                return try connectOnce(socketPath: socketPath,
                                       onLine: onLine,
                                       onClose: onClose)
            } catch {
                if Date() >= deadline {
                    throw error
                }
                Thread.sleep(forTimeInterval: 0.05)
            }
        } while true
    }

    private func connectOnce(socketPath: String,
                             onLine: @escaping @Sendable (String) -> Void,
                             onClose: @escaping @Sendable (Error?) -> Void) throws -> CodexAppServerConnectionTransport {
        let frameHandler = CodexAppServerWebSocketFrameHandler(onText: onLine,
                                                               onClose: onClose)
        let httpHandler = CodexAppServerWebSocketUpgradeRequestHandler(uri: "/")
        let upgradeState = CodexAppServerWebSocketUpgradeState()
        let upgrader = NIOWebSocketClientUpgrader(
            maxFrameSize: Self.maximumWebSocketFrameSizeBytes,
            upgradePipelineHandler: { channel, _ in
                channel.pipeline.addHandler(frameHandler).map {
                    upgradeState.succeed()
                }
            }
        )
        let bootstrap = ClientBootstrap(group: group)
            .channelInitializer { channel in
                let upgradePromise = channel.eventLoop.makePromise(of: Void.self)
                upgradeState.attach(upgradePromise)
                channel.closeFuture.whenComplete { _ in
                    upgradeState.fail(CodexAppServerTransportError.closed)
                }
                let config: NIOHTTPClientUpgradeSendableConfiguration = (
                    upgraders: [upgrader],
                    completionHandler: { context in
                        context.pipeline.removeHandler(httpHandler, promise: nil)
                    }
                )
                return channel.pipeline.addHTTPClientHandlers(withClientUpgrade: config).flatMap {
                    channel.pipeline.addHandler(httpHandler)
                }
            }

        let channel = try bootstrap.connect(unixDomainSocketPath: socketPath).wait()
        try upgradeState.wait()
        return CodexAppServerWebSocketTransport(channel: channel)
    }

    deinit {
        if ownsGroup {
            try? group.syncShutdownGracefully()
        }
    }
}

private final class CodexAppServerWebSocketUpgradeState: @unchecked Sendable {
    private let lock = NSLock()
    private var promise: EventLoopPromise<Void>?
    private var completed = false

    func attach(_ promise: EventLoopPromise<Void>) {
        lock.lock()
        self.promise = promise
        let shouldComplete = completed
        lock.unlock()

        if shouldComplete {
            promise.succeed(())
        }
    }

    func succeed() {
        complete(.success(()))
    }

    func fail(_ error: Error) {
        complete(.failure(error))
    }

    func wait() throws {
        let future: EventLoopFuture<Void>
        lock.lock()
        guard let promise else {
            lock.unlock()
            throw CodexAppServerTransportError.closed
        }
        future = promise.futureResult
        lock.unlock()
        try future.wait()
    }

    private func complete(_ result: Result<Void, Error>) {
        lock.lock()
        guard completed == false else {
            lock.unlock()
            return
        }
        completed = true
        let promise = self.promise
        lock.unlock()

        switch result {
        case .success:
            promise?.succeed(())
        case .failure(let error):
            promise?.fail(error)
        }
    }
}

private final class CodexAppServerWebSocketUpgradeRequestHandler: ChannelInboundHandler, RemovableChannelHandler, Sendable {
    typealias InboundIn = HTTPClientResponsePart
    typealias OutboundOut = HTTPClientRequestPart

    private let uri: String

    init(uri: String) {
        self.uri = uri
    }

    func channelActive(context: ChannelHandlerContext) {
        var headers = HTTPHeaders()
        headers.add(name: "Host", value: "localhost")
        headers.add(name: "Content-Length", value: "0")
        let requestHead = HTTPRequestHead(version: .http1_1,
                                          method: .GET,
                                          uri: uri,
                                          headers: headers)
        context.write(Self.wrapOutboundOut(.head(requestHead)), promise: nil)
        context.write(Self.wrapOutboundOut(.body(.byteBuffer(context.channel.allocator.buffer(capacity: 0)))), promise: nil)
        context.writeAndFlush(Self.wrapOutboundOut(.end(nil)), promise: nil)
    }
}

private final class CodexAppServerWebSocketFrameHandler: ChannelInboundHandler, Sendable {
    typealias InboundIn = WebSocketFrame
    typealias OutboundOut = WebSocketFrame

    private let onText: @Sendable (String) -> Void
    private let onClose: @Sendable (Error?) -> Void

    init(onText: @escaping @Sendable (String) -> Void,
         onClose: @escaping @Sendable (Error?) -> Void) {
        self.onText = onText
        self.onClose = onClose
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = Self.unwrapInboundIn(data)
        switch frame.opcode {
        case .text:
            var data = frame.unmaskedData
            if let text = data.readString(length: data.readableBytes) {
                onText(text)
            }
        case .ping:
            let data = frame.unmaskedData
            let pong = WebSocketFrame(fin: true,
                                      opcode: .pong,
                                      maskKey: WebSocketMaskingKey.random(),
                                      data: data)
            context.writeAndFlush(Self.wrapOutboundOut(pong), promise: nil)
        case .connectionClose:
            onClose(nil)
            context.close(promise: nil)
        default:
            break
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        onClose(error)
        context.close(promise: nil)
    }
}

private final class CodexAppServerWebSocketTransport: CodexAppServerConnectionTransport {
    private let channel: Channel
    private let lock = NSLock()
    private var closed = false

    init(channel: Channel) {
        self.channel = channel
    }

    func sendLine(_ line: String) throws {
        lock.lock()
        guard closed == false else {
            lock.unlock()
            throw CodexAppServerTransportError.closed
        }
        lock.unlock()

        let payload = line.hasSuffix("\n") ? String(line.dropLast()) : line
        let buffer = channel.allocator.buffer(string: payload)
        let frame = WebSocketFrame(fin: true,
                                   opcode: .text,
                                   maskKey: WebSocketMaskingKey.random(),
                                   data: buffer)
        let future = channel.writeAndFlush(frame)
        if channel.eventLoop.inEventLoop {
            return
        }
        try future.wait()
    }

    func close() {
        lock.lock()
        let shouldClose = closed == false
        closed = true
        lock.unlock()
        guard shouldClose else {
            return
        }
        _ = channel.close()
    }
}

final class CodexAppServerProcessRunner: CodexAppServerProcessRunning {
    func start(configuration: CodexAppServerLaunchConfiguration,
               onStdoutLine: @escaping @Sendable (String) -> Void,
               onStderrLine: @escaping @Sendable (String) -> Void,
               onExit: @escaping @Sendable (Int32) -> Void) throws -> CodexAppServerManagedProcess {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: configuration.executablePath)
        process.arguments = configuration.arguments
        process.currentDirectoryURL = URL(fileURLWithPath: configuration.workingDirectory)
        process.environment = ProcessInfo.processInfo.environment.merging(configuration.environment) { _, override in
            override
        }

        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let stdoutBuffer = CodexAppServerLineBuffer(onLine: onStdoutLine)
        let stderrBuffer = CodexAppServerLineBuffer(onLine: onStderrLine)

        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard data.isEmpty == false,
                  let text = String(data: data, encoding: .utf8) else {
                return
            }
            stdoutBuffer.append(text)
        }
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard data.isEmpty == false,
                  let text = String(data: data, encoding: .utf8) else {
                return
            }
            stderrBuffer.append(text)
        }

        let managedProcess = CodexAppServerProcess(process: process,
                                                   stdinHandle: inputPipe.fileHandleForWriting)
        process.terminationHandler = { process in
            outputPipe.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil
            stdoutBuffer.flush()
            stderrBuffer.flush()
            managedProcess.markTerminated()
            onExit(process.terminationStatus)
        }

        try process.run()
        return managedProcess
    }
}

private final class CodexAppServerProcess: CodexAppServerManagedProcess {
    private let process: Process
    private let stdinHandle: FileHandle
    private let lock = NSLock()
    private var terminated = false

    init(process: Process, stdinHandle: FileHandle) {
        self.process = process
        self.stdinHandle = stdinHandle
    }

    var processID: Int32? {
        process.processIdentifier
    }

    func sendLine(_ line: String) throws {
        guard let data = line.data(using: .utf8) else {
            throw CodexAppServerProcessError.invalidUTF8
        }
        lock.lock()
        guard terminated == false else {
            lock.unlock()
            throw CodexAppServerProcessError.closed
        }
        lock.unlock()
        try stdinHandle.write(contentsOf: data)
    }

    func terminate() {
        lock.lock()
        let shouldTerminate = terminated == false
        terminated = true
        lock.unlock()
        guard shouldTerminate else {
            return
        }
        try? stdinHandle.close()
        if process.isRunning {
            process.terminate()
        }
    }

    func markTerminated() {
        lock.lock()
        terminated = true
        lock.unlock()
        try? stdinHandle.close()
    }
}

private final class CodexAppServerConnectionLineRouter: @unchecked Sendable {
    private let lock = NSLock()
    private var connection: CodexAppServerConnection?
    private var pendingLines: [String] = []

    func attach(_ connection: CodexAppServerConnection) {
        lock.lock()
        self.connection = connection
        let pending = pendingLines
        pendingLines.removeAll()
        lock.unlock()

        for line in pending {
            connection.receiveLine(line)
        }
    }

    func receive(_ line: String) {
        lock.lock()
        guard let connection else {
            pendingLines.append(line)
            lock.unlock()
            return
        }
        lock.unlock()
        connection.receiveLine(line)
    }
}

private final class CodexAppServerRuntimeSessionExitRouter: @unchecked Sendable {
    private let lock = NSLock()
    private var session: CodexAppServerRuntimeSession?
    private var pendingExitCode: Int32?
    private let onExit: @Sendable (Int32) -> Void

    init(onExit: @escaping @Sendable (Int32) -> Void) {
        self.onExit = onExit
    }

    func attach(_ session: CodexAppServerRuntimeSession) {
        lock.lock()
        self.session = session
        let pending = pendingExitCode
        pendingExitCode = nil
        lock.unlock()

        if let pending {
            session.handleProcessExit(exitCode: pending)
            onExit(pending)
        }
    }

    func receive(_ exitCode: Int32) {
        lock.lock()
        guard let session else {
            pendingExitCode = exitCode
            lock.unlock()
            return
        }
        lock.unlock()

        session.handleProcessExit(exitCode: exitCode)
        onExit(exitCode)
    }
}

private final class CodexAppServerLineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = ""
    private let onLine: @Sendable (String) -> Void

    init(onLine: @escaping @Sendable (String) -> Void) {
        self.onLine = onLine
    }

    func append(_ text: String) {
        let lines = extractLines(appending: text)
        for line in lines {
            onLine(line)
        }
    }

    func flush() {
        let line: String?
        lock.lock()
        if pending.isEmpty {
            line = nil
        } else {
            line = pending
            pending = ""
        }
        lock.unlock()
        if let line {
            onLine(line)
        }
    }

    private func extractLines(appending text: String) -> [String] {
        lock.lock()
        pending.append(text)
        var lines: [String] = []
        while let newlineIndex = pending.firstIndex(of: "\n") {
            let line = String(pending[..<newlineIndex])
            lines.append(line)
            pending.removeSubrange(...newlineIndex)
        }
        lock.unlock()
        return lines
    }
}
