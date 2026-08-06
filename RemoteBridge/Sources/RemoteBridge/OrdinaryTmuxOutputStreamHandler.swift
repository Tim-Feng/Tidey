import Foundation

private final class OrdinaryTmuxStrictTerminalEmitterSlot: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: OrdinaryTmuxStrictTerminalEmitter?

    func install(_ emitter: OrdinaryTmuxStrictTerminalEmitter) {
        lock.lock()
        storage = emitter
        lock.unlock()
    }

    var emitter: OrdinaryTmuxStrictTerminalEmitter? {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

struct TerminalStreamDeltaEnvelope: Codable, Sendable, Equatable {
    let type: String
    let workspaceID: String
    let panelID: String
    let subscriptionID: String?
    let sequence: UInt64?
    let paneID: String?
    let columns: Int?
    let rows: Int?
    let alternateOn: Bool?
    let rebootstrapRequired: Bool?
    let chunk: String
    let chunkBase64: String
    let cursorRow: Int?
    let cursorColumn: Int?
    let cursorVisible: Bool?

    init(type: String,
         workspaceID: String,
         panelID: String,
         subscriptionID: String? = nil,
         sequence: UInt64? = nil,
         paneID: String? = nil,
         columns: Int? = nil,
         rows: Int? = nil,
         alternateOn: Bool? = nil,
         rebootstrapRequired: Bool? = nil,
         chunk: String,
         chunkBase64: String,
         cursorRow: Int?,
         cursorColumn: Int?,
         cursorVisible: Bool? = nil) {
        self.type = type
        self.workspaceID = workspaceID
        self.panelID = panelID
        self.subscriptionID = subscriptionID
        self.sequence = sequence
        self.paneID = paneID
        self.columns = columns
        self.rows = rows
        self.alternateOn = alternateOn
        self.rebootstrapRequired = rebootstrapRequired
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
        case subscriptionID = "subscription_id"
        case sequence
        case paneID = "pane_id"
        case columns = "cols"
        case rows
        case alternateOn = "alternate_on"
        case rebootstrapRequired = "rebootstrap_required"
        case chunk
        case chunkBase64 = "chunk_base64"
        case cursorRow = "cursor_row"
        case cursorColumn = "cursor_col"
        case cursorVisible = "cursor_visible"
    }
}

protocol TerminalByteTailing: Sendable {
    func prepare() throws
    func activate()
    func stop()
}

final class TerminalByteFileTailer: TerminalByteTailing, @unchecked Sendable {
    typealias ChunkHandler = @Sendable (Data) -> Void

    private enum State {
        case idle
        case prepared
        case active
        case stopped
    }

    private let url: URL
    private let queue: DispatchQueue
    private let handler: ChunkHandler
    private var fileHandle: FileHandle?
    private var source: DispatchSourceFileSystemObject?
    private var state: State = .idle

    init(url: URL,
         queue: DispatchQueue = DispatchQueue(label: "com.tidey.remote-bridge.terminal-byte-file-tailer"),
         handler: @escaping ChunkHandler) {
        self.url = url
        self.queue = queue
        self.handler = handler
    }

    func prepare() throws {
        var prepareError: Error?
        queue.sync {
            guard state == .idle else {
                return
            }
            do {
                let handle = try FileHandle(forReadingFrom: url)
                try handle.seek(toOffset: 0)
                fileHandle = handle
                state = .prepared
            } catch {
                prepareError = error
            }
        }
        if let prepareError {
            throw prepareError
        }
    }

    func activate() {
        queue.async {
            guard self.state == .prepared,
                  let handle = self.fileHandle else {
                return
            }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: handle.fileDescriptor,
                                                                   eventMask: [.extend, .write],
                                                                   queue: self.queue)
            source.setEventHandler { [weak self] in
                self?.processFileEvent()
            }
            source.setCancelHandler { [weak self, weak handle] in
                try? handle?.close()
                self?.fileHandle = nil
            }
            self.source = source
            self.state = .active
            source.resume()
            self.processFileEvent()
        }
    }

    func stop() {
        queue.sync {
            switch state {
            case .idle:
                state = .stopped
            case .prepared:
                state = .stopped
                try? fileHandle?.close()
                fileHandle = nil
            case .active:
                state = .stopped
                source?.cancel()
                source = nil
            case .stopped:
                break
            }
        }
    }

    #if DEBUG
    func processFileEventForTesting() {
        queue.sync {
            processFileEvent()
        }
    }
    #endif

    private func processFileEvent() {
        guard state == .active else {
            return
        }
        readAvailableBytes()
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
    func activate()
    @discardableResult func stop() -> Bool
    func stopForReplacement() throws
}

extension OrdinaryTmuxTerminalStreamSubscribing {
    func activate() {}

    func stopForReplacement() throws {
        _ = stop()
    }
}

final class OrdinaryTmuxTerminalStreamSubscription: OrdinaryTmuxTerminalStreamSubscribing, @unchecked Sendable {
    let route: OrdinaryTmuxPanelRoute
    let outputFileURL: URL
    private let adapter: OrdinaryTmuxTerminalStreaming
    private let tailer: TerminalByteTailing
    private let cleanup: (URL) -> Void
    private let observerInvalidationGate: OrdinaryTmuxTerminalObserverInvalidationGate?
    private let lock = NSLock()
    private var observerLease: OrdinaryTmuxTerminalObserverLeasing?
    private var physicallyClosed = false

    init(route: OrdinaryTmuxPanelRoute,
         outputFileURL: URL,
         adapter: OrdinaryTmuxTerminalStreaming,
         tailer: TerminalByteTailing,
         observerInvalidationGate: OrdinaryTmuxTerminalObserverInvalidationGate? = nil,
         cleanup: @escaping (URL) -> Void) {
        self.route = route
        self.outputFileURL = outputFileURL
        self.adapter = adapter
        self.tailer = tailer
        self.observerInvalidationGate = observerInvalidationGate
        self.cleanup = cleanup
    }

    func activate() {
        observerInvalidationGate?.activate()
        tailer.activate()
    }

    func installObserverLease(_ lease: OrdinaryTmuxTerminalObserverLeasing) {
        var shouldStop = false
        lock.lock()
        if physicallyClosed || observerLease != nil {
            shouldStop = true
        } else {
            observerLease = lease
        }
        lock.unlock()
        if shouldStop {
            lease.stop()
        }
    }

    @discardableResult
    func stop() -> Bool {
        lock.lock()
        guard physicallyClosed == false else {
            lock.unlock()
            return true
        }

        observerInvalidationGate?.stop()
        tailer.stop()
        do {
            try adapter.stopPipePane(exactRoute: route)
            physicallyClosed = true
            let lease = observerLease
            observerLease = nil
            lock.unlock()
            cleanup(outputFileURL)
            lease?.stop()
            return true
        } catch {
            lock.unlock()
            cleanup(outputFileURL)
            // Best effort. A later lane replacement may retry the physical stop.
            return false
        }
    }

    func stopForReplacement() throws {
        lock.lock()
        guard physicallyClosed == false else {
            lock.unlock()
            return
        }

        observerInvalidationGate?.stop()
        tailer.stop()
        do {
            try adapter.stopPipePane(exactRoute: route)
            physicallyClosed = true
            let lease = observerLease
            observerLease = nil
            lock.unlock()
            cleanup(outputFileURL)
            lease?.stop()
        } catch {
            lock.unlock()
            cleanup(outputFileURL)
            throw error
        }
    }
}

struct OrdinaryTmuxOutputStreamStart {
    let response: BridgeResponse
    let subscription: OrdinaryTmuxTerminalStreamSubscribing
}

struct OrdinaryTmuxOutputStreamOwnedFailure: Error, LocalizedError {
    let underlying: Error
    let subscription: OrdinaryTmuxTerminalStreamSubscribing

    var errorDescription: String? {
        underlying.localizedDescription
    }
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
    private let terminalObserver: OrdinaryTmuxTerminalObserving?
    private let outputDirectory: URL
    private let fileManager: FileManager
    private let makeTailer: TailerFactory

    init(routeResolver: OrdinaryTmuxRouteResolving,
         adapter: Adapter = OrdinaryTmuxCLIAdapter(),
         terminalObserver: OrdinaryTmuxTerminalObserving? = nil,
         outputDirectory: URL = FileManager.default.temporaryDirectory.appendingPathComponent("tidey-terminal-streams", isDirectory: true),
         fileManager: FileManager = .default,
         makeTailer: @escaping TailerFactory = { url, handler in
             TerminalByteFileTailer(url: url, handler: handler)
         }) {
        self.routeResolver = routeResolver
        self.adapter = adapter
        self.terminalObserver = terminalObserver
        self.outputDirectory = outputDirectory
        self.fileManager = fileManager
        self.makeTailer = makeTailer
    }

    func subscribe(_ request: BridgeRequest,
                   onDelta: @escaping @Sendable (TerminalStreamDeltaEnvelope) -> Void) throws -> OrdinaryTmuxOutputStreamStart? {
        try subscribe(request, allowedIf: { true }, onDelta: onDelta)
    }

    func subscribe(_ request: BridgeRequest,
                   allowedIf: @escaping @Sendable () -> Bool,
                   onDelta: @escaping @Sendable (TerminalStreamDeltaEnvelope) -> Void) throws -> OrdinaryTmuxOutputStreamStart? {
        guard request.action == "subscribe_terminal_stream" else {
            return nil
        }
        guard let panelID = request.params?["panel_id"]?.stringValue,
              panelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw BridgeInternalError.invalidRequest("subscribe_terminal_stream requires panel_id")
        }
        let workspaceID = request.params?["workspace_id"]?.stringValue
        let subscriptionID = request.params?["subscription_id"]?.stringValue
        let requestedStateVersion = request.params?["terminal_state_version"]
        let usesStrictState: Bool
        if let requestedStateVersion {
            guard requestedStateVersion.intValue == OrdinaryTmuxTerminalStateV1.schemaVersion else {
                throw BridgeInternalError.invalidRequest("unsupported terminal_state_version")
            }
            guard let subscriptionID,
                  subscriptionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                throw BridgeInternalError.invalidRequest(
                    "terminal_state_version requires subscription_id"
                )
            }
            usesStrictState = true
        } else {
            usesStrictState = false
        }
        guard let route = try routeResolver.route(forPanelID: panelID, workspaceID: workspaceID) else {
            throw BridgeInternalError.notFound("ordinary tmux logical panel is not authorized")
        }
        let streamRoute = try adapter.refreshedRoute(route)

        let outputFileURL = try makeOutputFile()
        let strictEmitterSlot = OrdinaryTmuxStrictTerminalEmitterSlot()
        let observerInvalidationGate = usesStrictState
            ? OrdinaryTmuxTerminalObserverInvalidationGate { fingerprint in
                strictEmitterSlot.emitter?.requireRebootstrap(
                    currentFingerprint: fingerprint
                )
            }
            : nil
        let tailer = makeTailer(outputFileURL) { data in
            guard allowedIf() else {
                return
            }
            if usesStrictState {
                let fingerprint = try? adapter.queryStrictTerminalFingerprint(
                    exactRoute: streamRoute
                )
                strictEmitterSlot.emitter?.emit(
                    chunk: data,
                    currentFingerprint: fingerprint
                )
                return
            }
            let cursor = try? adapter.queryCursorPosition(exactRoute: streamRoute)
            onDelta(TerminalStreamDeltaEnvelope(type: "terminal_stream_delta",
                                                workspaceID: streamRoute.workspaceID,
                                                panelID: streamRoute.panelID,
                                                subscriptionID: subscriptionID,
                                                chunk: String(data: data, encoding: .utf8) ?? "",
                                                chunkBase64: data.base64EncodedString(),
                                                cursorRow: cursor?.row,
                                                cursorColumn: cursor?.column,
                                                cursorVisible: cursor?.cursorVisible))
        }
        do {
            try tailer.prepare()
        } catch {
            tailer.stop()
            try? fileManager.removeItem(at: outputFileURL)
            throw error
        }
        let subscription = OrdinaryTmuxTerminalStreamSubscription(route: streamRoute,
                                                                 outputFileURL: outputFileURL,
                                                                 adapter: adapter,
                                                                 tailer: tailer,
                                                                 observerInvalidationGate: observerInvalidationGate,
                                                                 cleanup: { [fileManager] url in
                                                                     try? fileManager.removeItem(at: url)
                                                                 })

        do {
            if usesStrictState, let subscriptionID {
                let state = try adapter.bootstrapStrictTerminalStream(
                    refreshedRoute: streamRoute,
                    outputFilePath: outputFileURL.path,
                    subscriptionID: subscriptionID
                )
                guard state.subscriptionID == subscriptionID,
                      state.paneID == streamRoute.activePaneID else {
                    throw BridgeInternalError.invalidResponse
                }
                let fingerprint = OrdinaryTmuxTerminalFingerprintV1(
                    paneID: state.paneID,
                    columns: state.columns,
                    rows: state.rows,
                    alternateOn: state.alternateOn
                )
                let emitter = OrdinaryTmuxStrictTerminalEmitter(
                    subscriptionID: subscriptionID,
                    expectedFingerprint: fingerprint,
                    onDelta: { delta in
                        onDelta(TerminalStreamDeltaEnvelope(
                            type: "terminal_stream_delta",
                            workspaceID: streamRoute.workspaceID,
                            panelID: streamRoute.panelID,
                            subscriptionID: delta.subscriptionID,
                            sequence: delta.sequence,
                            paneID: delta.fingerprint.paneID,
                            columns: delta.fingerprint.columns,
                            rows: delta.fingerprint.rows,
                            alternateOn: delta.fingerprint.alternateOn,
                            rebootstrapRequired: delta.rebootstrapRequired,
                            chunk: String(data: delta.chunk, encoding: .utf8) ?? "",
                            chunkBase64: delta.chunk.base64EncodedString(),
                            cursorRow: nil,
                            cursorColumn: nil
                        ))
                    }
                )
                strictEmitterSlot.install(emitter)
                if let terminalObserver, let observerInvalidationGate {
                    let observerLease = try terminalObserver.observe(
                        OrdinaryTmuxTerminalObservationRequest(
                            route: streamRoute,
                            subscriptionID: subscriptionID,
                            expectedFingerprint: fingerprint,
                            onRebootstrapRequired: { observedFingerprint in
                                observerInvalidationGate.requireRebootstrap(
                                    observedFingerprint
                                )
                            }
                        )
                    )
                    subscription.installObserverLease(observerLease)
                    let admittedFingerprint = try? adapter.queryStrictTerminalFingerprint(
                        exactRoute: streamRoute
                    )
                    if admittedFingerprint != fingerprint {
                        observerInvalidationGate.requireRebootstrap(
                            admittedFingerprint
                        )
                    }
                }
                let response = BridgeResponse(
                    id: request.id,
                    ok: true,
                    result: Self.strictBootstrapResult(
                        state: state,
                        workspaceID: streamRoute.workspaceID,
                        panelID: streamRoute.panelID
                    ),
                    error: nil
                )
                return OrdinaryTmuxOutputStreamStart(
                    response: response,
                    subscription: subscription
                )
            }

            let bootstrap = try adapter.bootstrapTerminalStream(refreshedRoute: streamRoute,
                                                                outputFilePath: outputFileURL.path,
                                                                maxLines: 200)
            var result: [String: JSONValue] = [
                "subscribed": .bool(true),
                "workspace_id": .string(streamRoute.workspaceID),
                "panel_id": .string(streamRoute.panelID),
                "initial_output": .string(bootstrap.initialOutput.output),
                "cursor_row": bootstrap.initialOutput.cursorRow.map { .number(Double($0)) } ?? .null,
                "cursor_col": bootstrap.initialOutput.cursorColumn.map { .number(Double($0)) } ?? .null,
                "cursor_visible": bootstrap.initialOutput.cursorVisible.map(JSONValue.bool) ?? .null,
            ]
            if let subscriptionID {
                result["subscription_id"] = .string(subscriptionID)
            }
            let response = BridgeResponse(id: request.id,
                                          ok: true,
                                          result: result,
                                          error: nil)
            return OrdinaryTmuxOutputStreamStart(response: response, subscription: subscription)
        } catch {
            throw OrdinaryTmuxOutputStreamOwnedFailure(underlying: error,
                                                       subscription: subscription)
        }
    }

    private static func strictBootstrapResult(
        state: OrdinaryTmuxTerminalStateV1,
        workspaceID: String,
        panelID: String
    ) -> [String: JSONValue] {
        var screen: [String: JSONValue] = [
            "cursor_col": .number(Double(state.cursor.column)),
            "cursor_row": .number(Double(state.cursor.row)),
            "cursor_visible": .bool(state.cursorVisible),
            "active_capture_base64": .string(state.activeScreen.base64EncodedString()),
        ]
        if state.alternateOn {
            screen["primary_capture_base64"] = .string(
                state.backgroundScreen.base64EncodedString()
            )
        }

        var alternate: [String: JSONValue] = [
            "active": .bool(state.alternateOn),
        ]
        if let savedCursor = state.alternateSavedCursor {
            alternate["saved_cursor_col"] = .number(Double(savedCursor.column))
            alternate["saved_cursor_row"] = .number(Double(savedCursor.row))
        }

        return [
            "subscribed": .bool(true),
            "workspace_id": .string(workspaceID),
            "panel_id": .string(panelID),
            "subscription_id": .string(state.subscriptionID),
            "terminal_state_version": .number(Double(OrdinaryTmuxTerminalStateV1.schemaVersion)),
            "pane_id": .string(state.paneID),
            "cols": .number(Double(state.columns)),
            "rows": .number(Double(state.rows)),
            "screen": .object(screen),
            "alternate": .object(alternate),
            "scroll_region": .object([
                "upper": .number(Double(state.scrollRegionUpper)),
                "lower": .number(Double(state.scrollRegionLower)),
            ]),
            "tab_stops": .array(state.tabStops.map { .number(Double($0)) }),
            "modes": .object([
                "insert": .bool(state.modes.insert),
                "keypad_cursor": .bool(state.modes.applicationCursorKeys),
                "keypad": .bool(state.modes.applicationKeypad),
                "wrap": .bool(state.modes.wrap),
                "origin": .bool(state.modes.origin),
                "mouse_standard": .bool(state.modes.mouseStandard),
                "mouse_button": .bool(state.modes.mouseButton),
                "mouse_any": .bool(state.modes.mouseAny),
                "mouse_utf8": .bool(state.modes.mouseUTF8),
                "mouse_sgr": .bool(state.modes.mouseSGR),
            ]),
            "pane_key_mode": .string(state.modes.paneKeyMode),
            "pending_prefix_base64": .string(state.pendingPrefix.base64EncodedString()),
        ]
    }

    private func makeOutputFile() throws -> URL {
        try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let url = outputDirectory.appendingPathComponent("terminal-\(UUID().uuidString).bytes", isDirectory: false)
        fileManager.createFile(atPath: url.path, contents: Data())
        return url
    }
}
