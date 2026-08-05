import Foundation
import XCTest
@testable import RemoteBridge

final class OrdinaryTmuxOutputStreamHandlerTests: XCTestCase {
    private final class StubResolver: OrdinaryTmuxRouteResolving, @unchecked Sendable {
        let route: OrdinaryTmuxPanelRoute?

        init(route: OrdinaryTmuxPanelRoute?) {
            self.route = route
        }

        func route(forPanelID panelID: String, workspaceID: String?) throws -> OrdinaryTmuxPanelRoute? {
            guard route?.panelID == panelID else {
                return nil
            }
            guard workspaceID == nil || route?.workspaceID == workspaceID else {
                return nil
            }
            return route
        }
    }

    private final class StubAdapter: OrdinaryTmuxRouteRefreshing, OrdinaryTmuxTerminalStreaming, @unchecked Sendable {
        private let lock = NSLock()
        private(set) var startedPipeRoutes = [OrdinaryTmuxPanelRoute]()
        private(set) var startedPipeOutputPaths = [String]()
        private(set) var stoppedPipeRoutes = [OrdinaryTmuxPanelRoute]()
        var initialOutput = OrdinaryTmuxCapturedOutput(output: "\u{1B}[31mhello\u{1B}[0m",
                                                       cursorRow: 3,
                                                       cursorColumn: 4)
        var cursorPosition: OrdinaryTmuxCursorPosition? = OrdinaryTmuxCursorPosition(row: 5, column: 6)

        func refreshedRoute(_ route: OrdinaryTmuxPanelRoute) throws -> OrdinaryTmuxPanelRoute {
            route
        }

        func route(for logicalID: OrdinaryTmuxLogicalPanelID,
                   authorizedTarget: OrdinaryTmuxAuthorizedTarget) throws -> OrdinaryTmuxPanelRoute {
            throw BridgeInternalError.notFound("unused")
        }

        func captureOutput(route: OrdinaryTmuxPanelRoute, maxLines: Int) throws -> OrdinaryTmuxCapturedOutput {
            throw BridgeInternalError.notFound("unused")
        }

        func captureANSIOutput(route: OrdinaryTmuxPanelRoute, maxLines: Int) throws -> OrdinaryTmuxCapturedOutput {
            XCTAssertEqual(maxLines, 200)
            return initialOutput
        }

        func startPipePane(route: OrdinaryTmuxPanelRoute, outputFilePath: String) throws -> OrdinaryTmuxPanelRoute {
            lock.lock()
            startedPipeRoutes.append(route)
            startedPipeOutputPaths.append(outputFilePath)
            lock.unlock()
            return route
        }

        func stopPipePane(route: OrdinaryTmuxPanelRoute) throws {
            lock.lock()
            stoppedPipeRoutes.append(route)
            lock.unlock()
        }

        func queryCursorPosition(route: OrdinaryTmuxPanelRoute) throws -> OrdinaryTmuxCursorPosition? {
            cursorPosition
        }
    }

    private final class StubTailer: TerminalByteTailing, @unchecked Sendable {
        private let handler: TerminalByteFileTailer.ChunkHandler
        private(set) var startCount = 0
        private(set) var stopCount = 0

        init(handler: @escaping TerminalByteFileTailer.ChunkHandler) {
            self.handler = handler
        }

        func start() throws {
            startCount += 1
        }

        func stop() {
            stopCount += 1
        }

        func emit(_ text: String) {
            handler(Data(text.utf8))
        }
    }

    private final class StubTailerBox: @unchecked Sendable {
        private let lock = NSLock()
        private var tailers = [StubTailer]()

        func makeTailer(url: URL,
                        handler: @escaping TerminalByteFileTailer.ChunkHandler) -> TerminalByteTailing {
            let tailer = StubTailer(handler: handler)
            lock.lock()
            tailers.append(tailer)
            lock.unlock()
            return tailer
        }

        var firstTailer: StubTailer? {
            lock.lock()
            defer { lock.unlock() }
            return tailers.first
        }
    }

    private final class DeltaBox: @unchecked Sendable {
        private let lock = NSLock()
        private var storedDeltas = [TerminalStreamDeltaEnvelope]()

        func append(_ delta: TerminalStreamDeltaEnvelope) {
            lock.lock()
            storedDeltas.append(delta)
            lock.unlock()
        }

        var deltas: [TerminalStreamDeltaEnvelope] {
            lock.lock()
            defer { lock.unlock() }
            return storedDeltas
        }
    }

    func testRejectsNonOrdinaryTmuxPanelID() throws {
        let handler = OrdinaryTmuxOutputStreamHandler(routeResolver: StubResolver(route: nil),
                                                      adapter: StubAdapter())

        XCTAssertThrowsError(
            try handler.subscribe(BridgeRequest(id: "request-1",
                                                action: "subscribe_terminal_stream",
                                                params: ["panel_id": .string("native-panel")]),
                                  onDelta: { _ in })
        ) { error in
            guard case BridgeInternalError.invalidRequest(let message) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(message.contains("ordinary tmux panel_id"))
        }
    }

    func testSubscribeReturnsInitialOutputAndStartsPipePane() throws {
        let route = ordinaryRoute()
        let adapter = StubAdapter()
        let tailerBox = StubTailerBox()
        let outputDirectory = temporaryDirectory()
        let handler = OrdinaryTmuxOutputStreamHandler(routeResolver: StubResolver(route: route),
                                                      adapter: adapter,
                                                      outputDirectory: outputDirectory,
                                                      makeTailer: { url, handler in
                                                          tailerBox.makeTailer(url: url, handler: handler)
                                                      })

        let start = try XCTUnwrap(handler.subscribe(BridgeRequest(id: "request-1",
                                                                  action: "subscribe_terminal_stream",
                                                                  params: [
                                                                    "workspace_id": .string(route.workspaceID),
                                                                    "panel_id": .string(route.panelID),
                                                                  ]),
                                                    onDelta: { _ in }))

        XCTAssertTrue(start.response.ok)
        XCTAssertEqual(start.response.result?["subscribed"]?.boolValue, true)
        XCTAssertEqual(start.response.result?["workspace_id"]?.stringValue, route.workspaceID)
        XCTAssertEqual(start.response.result?["panel_id"]?.stringValue, route.panelID)
        XCTAssertEqual(start.response.result?["initial_output"]?.stringValue, adapter.initialOutput.output)
        XCTAssertEqual(start.response.result?["cursor_row"]?.intValue, 3)
        XCTAssertEqual(start.response.result?["cursor_col"]?.intValue, 4)
        XCTAssertEqual(adapter.startedPipeRoutes, [route])
        let subscription = try XCTUnwrap(start.subscription as? OrdinaryTmuxTerminalStreamSubscription)
        XCTAssertEqual(adapter.startedPipeOutputPaths.first, subscription.outputFileURL.path)
        XCTAssertEqual(tailerBox.firstTailer?.startCount, 1)
    }

    func testTailerDeltaIncludesTextBase64AndCursorPosition() throws {
        let route = ordinaryRoute()
        let adapter = StubAdapter()
        let tailerBox = StubTailerBox()
        let outputDirectory = temporaryDirectory()
        let deltaBox = DeltaBox()
        let handler = OrdinaryTmuxOutputStreamHandler(routeResolver: StubResolver(route: route),
                                                      adapter: adapter,
                                                      outputDirectory: outputDirectory,
                                                      makeTailer: { url, handler in
                                                          tailerBox.makeTailer(url: url, handler: handler)
                                                      })

        let start = try XCTUnwrap(handler.subscribe(BridgeRequest(id: "request-1",
                                                                  action: "subscribe_terminal_stream",
                                                                  params: ["panel_id": .string(route.panelID)]),
                                                    onDelta: { delta in
                                                        deltaBox.append(delta)
                                                    }))
        tailerBox.firstTailer?.emit("\u{1B}[?25lchoice")

        XCTAssertEqual(deltaBox.deltas, [
            TerminalStreamDeltaEnvelope(type: "terminal_stream_delta",
                                        workspaceID: route.workspaceID,
                                        panelID: route.panelID,
                                        chunk: "\u{1B}[?25lchoice",
                                        chunkBase64: Data("\u{1B}[?25lchoice".utf8).base64EncodedString(),
                                        cursorRow: 5,
                                        cursorColumn: 6),
        ])

        start.subscription.stop()
        XCTAssertEqual(tailerBox.firstTailer?.stopCount, 1)
        XCTAssertEqual(adapter.stoppedPipeRoutes, [route])
    }

    private func ordinaryRoute() -> OrdinaryTmuxPanelRoute {
        OrdinaryTmuxPanelRoute(workspaceID: "workspace-1",
                               panelID: "ordinary-tmux:/tmp/tmux-\(getuid())/default:$7:@16",
                               carrierPanelID: "carrier-panel",
                               socket: .path("/tmp/tmux-\(getuid())/default"),
                               sessionID: "$7",
                               sessionName: "tidey-codex",
                               windowID: "@16",
                               windowIndex: 1,
                               activePaneID: "%16",
                               cwd: "/Users/timfeng/GitHub/Tidey",
                               currentCommand: "codex")
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("OrdinaryTmuxOutputStreamHandlerTests-\(UUID().uuidString)",
                                    isDirectory: true)
    }
}
