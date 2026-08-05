import Foundation

struct TerminalStreamDeltaEnvelope: Codable, Sendable, Equatable {
    let type: String
    let workspaceID: String
    let panelID: String
    let chunk: String
    let chunkBase64: String
    let cursorRow: Int?
    let cursorColumn: Int?
    let cursorVisible: Bool?

    init(type: String,
         workspaceID: String,
         panelID: String,
         chunk: String,
         chunkBase64: String,
         cursorRow: Int?,
         cursorColumn: Int?,
         cursorVisible: Bool? = nil) {
        self.type = type
        self.workspaceID = workspaceID
        self.panelID = panelID
        self.chunk = chunk
        self.chunkBase64 = chunkBase64
        self.cursorRow = cursorRow
        self.cursorColumn = cursorColumn
        self.cursorVisible = cursorVisible
    }

    enum CodingKeys: String, CodingKey {
        case type
        case workspaceID = "workspace_id"
        case panelID = "panel_id"
        case chunk
        case chunkBase64 = "chunk_base64"
        case cursorRow = "cursor_row"
        case cursorColumn = "cursor_col"
        case cursorVisible = "cursor_visible"
    }
}

protocol TerminalByteTailing: Sendable {
    func start() throws
    func stop()
}

final class TerminalByteFileTailer: TerminalByteTailing, @unchecked Sendable {
    typealias ChunkHandler = @Sendable (Data) -> Void

    private let url: URL
    private let queue: DispatchQueue
    private let handler: ChunkHandler
    private var fileHandle: FileHandle?
    private var source: DispatchSourceFileSystemObject?
    private var isStarted = false

    init(url: URL,
         queue: DispatchQueue = DispatchQueue(label: "com.tidey.remote-bridge.terminal-byte-file-tailer"),
         handler: @escaping ChunkHandler) {
        self.url = url
        self.queue = queue
        self.handler = handler
    }

    func start() throws {
        var startError: Error?
        queue.sync {
            guard isStarted == false else {
                return
            }
            do {
                let handle = try FileHandle(forReadingFrom: url)
                try handle.seekToEnd()
                let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: handle.fileDescriptor,
                                                                       eventMask: [.extend, .write],
                                                                       queue: queue)
                source.setEventHandler { [weak self] in
                    self?.readAvailableBytes()
                }
                source.setCancelHandler { [weak self, weak handle] in
                    try? handle?.close()
                    self?.fileHandle = nil
                }
                fileHandle = handle
                self.source = source
                isStarted = true
                source.resume()
            } catch {
                startError = error
            }
        }
        if let startError {
            throw startError
        }
    }

    func stop() {
        queue.sync {
            guard isStarted else {
                return
            }
            isStarted = false
            source?.cancel()
            source = nil
        }
    }

    private func readAvailableBytes() {
        guard let fileHandle else {
            return
        }
        let data = fileHandle.readDataToEndOfFile()
        guard data.isEmpty == false else {
            return
        }
        handler(data)
    }
}

protocol OrdinaryTmuxTerminalStreamSubscribing: AnyObject, Sendable {
    var route: OrdinaryTmuxPanelRoute { get }
    func stop()
    func stopForReplacement() throws
}

extension OrdinaryTmuxTerminalStreamSubscribing {
    func stopForReplacement() throws {
        stop()
    }
}

final class OrdinaryTmuxTerminalStreamSubscription: OrdinaryTmuxTerminalStreamSubscribing, @unchecked Sendable {
    let route: OrdinaryTmuxPanelRoute
    let outputFileURL: URL
    private let adapter: OrdinaryTmuxTerminalStreaming
    private let tailer: TerminalByteTailing
    private let cleanup: (URL) -> Void
    private let lock = NSLock()
    private var physicallyClosed = false

    init(route: OrdinaryTmuxPanelRoute,
         outputFileURL: URL,
         adapter: OrdinaryTmuxTerminalStreaming,
         tailer: TerminalByteTailing,
         cleanup: @escaping (URL) -> Void) {
        self.route = route
        self.outputFileURL = outputFileURL
        self.adapter = adapter
        self.tailer = tailer
        self.cleanup = cleanup
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard physicallyClosed == false else {
            return
        }

        tailer.stop()
        defer { cleanup(outputFileURL) }
        do {
            try adapter.stopPipePane(route: route)
            physicallyClosed = true
        } catch {
            // Best effort. A later lane replacement may retry the physical stop.
        }
    }

    func stopForReplacement() throws {
        lock.lock()
        defer { lock.unlock() }
        guard physicallyClosed == false else {
            return
        }

        tailer.stop()
        defer { cleanup(outputFileURL) }
        try adapter.stopPipePane(route: route)
        physicallyClosed = true
    }
}

struct OrdinaryTmuxOutputStreamStart {
    let response: BridgeResponse
    let subscription: OrdinaryTmuxTerminalStreamSubscribing
}

protocol OrdinaryTmuxOutputStreaming {
    func subscribe(_ request: BridgeRequest,
                   onDelta: @escaping @Sendable (TerminalStreamDeltaEnvelope) -> Void) throws -> OrdinaryTmuxOutputStreamStart?
    func subscribe(_ request: BridgeRequest,
                   allowedIf: @escaping @Sendable () -> Bool,
                   onDelta: @escaping @Sendable (TerminalStreamDeltaEnvelope) -> Void) throws -> OrdinaryTmuxOutputStreamStart?
}

extension OrdinaryTmuxOutputStreaming {
    func subscribe(_ request: BridgeRequest,
                   allowedIf: @escaping @Sendable () -> Bool,
                   onDelta: @escaping @Sendable (TerminalStreamDeltaEnvelope) -> Void) throws -> OrdinaryTmuxOutputStreamStart? {
        try subscribe(request, onDelta: onDelta)
    }
}

struct OrdinaryTmuxOutputStreamHandler: OrdinaryTmuxOutputStreaming {
    typealias Adapter = OrdinaryTmuxRouteRefreshing & OrdinaryTmuxTerminalStreaming
    typealias TailerFactory = @Sendable (_ url: URL, _ handler: @escaping TerminalByteFileTailer.ChunkHandler) -> TerminalByteTailing

    private let routeResolver: OrdinaryTmuxRouteResolving
    private let adapter: Adapter
    private let outputDirectory: URL
    private let fileManager: FileManager
    private let makeTailer: TailerFactory

    init(routeResolver: OrdinaryTmuxRouteResolving,
         adapter: Adapter = OrdinaryTmuxCLIAdapter(),
         outputDirectory: URL = FileManager.default.temporaryDirectory.appendingPathComponent("tidey-terminal-streams", isDirectory: true),
         fileManager: FileManager = .default,
         makeTailer: @escaping TailerFactory = { url, handler in
             TerminalByteFileTailer(url: url, handler: handler)
         }) {
        self.routeResolver = routeResolver
        self.adapter = adapter
        self.outputDirectory = outputDirectory
        self.fileManager = fileManager
        self.makeTailer = makeTailer
    }

    func subscribe(_ request: BridgeRequest,
                   onDelta: @escaping @Sendable (TerminalStreamDeltaEnvelope) -> Void) throws -> OrdinaryTmuxOutputStreamStart? {
        guard request.action == "subscribe_terminal_stream" else {
            return nil
        }
        guard let panelID = request.params?["panel_id"]?.stringValue,
              panelID.hasPrefix("\(OrdinaryTmuxLogicalPanelID.prefix):") else {
            throw BridgeInternalError.invalidRequest("subscribe_terminal_stream requires ordinary tmux panel_id")
        }
        let workspaceID = request.params?["workspace_id"]?.stringValue
        guard let route = try routeResolver.route(forPanelID: panelID, workspaceID: workspaceID) else {
            throw BridgeInternalError.notFound("ordinary tmux logical panel is not authorized")
        }

        let outputFileURL = try makeOutputFile()
        let initial = try adapter.captureANSIOutput(route: route, maxLines: 200)
        let tailer = makeTailer(outputFileURL) { data in
            let cursor = try? adapter.queryCursorPosition(route: route)
            onDelta(TerminalStreamDeltaEnvelope(type: "terminal_stream_delta",
                                                workspaceID: route.workspaceID,
                                                panelID: route.panelID,
                                                chunk: String(data: data, encoding: .utf8) ?? "",
                                                chunkBase64: data.base64EncodedString(),
                                                cursorRow: cursor?.row,
                                                cursorColumn: cursor?.column,
                                                cursorVisible: cursor?.cursorVisible))
        }
        try tailer.start()

        do {
            let streamRoute = try adapter.startPipePane(route: route, outputFilePath: outputFileURL.path)
            let subscription = OrdinaryTmuxTerminalStreamSubscription(route: streamRoute,
                                                                     outputFileURL: outputFileURL,
                                                                     adapter: adapter,
                                                                     tailer: tailer,
                                                                     cleanup: { [fileManager] url in
                                                                         try? fileManager.removeItem(at: url)
                                                                     })
            let response = BridgeResponse(id: request.id,
                                          ok: true,
                                          result: [
                                            "subscribed": .bool(true),
                                            "workspace_id": .string(streamRoute.workspaceID),
                                            "panel_id": .string(streamRoute.panelID),
                                            "initial_output": .string(initial.output),
                                            "cursor_row": initial.cursorRow.map { .number(Double($0)) } ?? .null,
                                            "cursor_col": initial.cursorColumn.map { .number(Double($0)) } ?? .null,
                                            "cursor_visible": initial.cursorVisible.map(JSONValue.bool) ?? .null,
                                          ],
                                          error: nil)
            return OrdinaryTmuxOutputStreamStart(response: response, subscription: subscription)
        } catch {
            tailer.stop()
            try? fileManager.removeItem(at: outputFileURL)
            throw error
        }
    }

    private func makeOutputFile() throws -> URL {
        try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let url = outputDirectory.appendingPathComponent("terminal-\(UUID().uuidString).bytes", isDirectory: false)
        fileManager.createFile(atPath: url.path, contents: Data())
        return url
    }
}
