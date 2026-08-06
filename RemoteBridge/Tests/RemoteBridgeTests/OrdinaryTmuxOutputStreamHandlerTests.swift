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
        enum StubError: Error, Equatable {
            case bootstrapFailed
            case stopFailed
        }

        private let lock = NSLock()
        private(set) var startedPipeRoutes = [OrdinaryTmuxPanelRoute]()
        private(set) var startedPipeOutputPaths = [String]()
        private(set) var stoppedPipeRoutes = [OrdinaryTmuxPanelRoute]()
        private(set) var cursorQueryCount = 0
        private(set) var strictBootstrapCount = 0
        var remainingStopFailures = 0
        var shouldFailBootstrap = false
        var strictState: OrdinaryTmuxTerminalStateV1?
        var strictFingerprint: OrdinaryTmuxTerminalFingerprintV1?
        var initialOutput = OrdinaryTmuxCapturedOutput(output: "\u{1B}[31mhello\u{1B}[0m",
                                                       cursorRow: 3,
                                                       cursorColumn: 4,
                                                       cursorVisible: false)
        var cursorPosition: OrdinaryTmuxCursorPosition? = OrdinaryTmuxCursorPosition(row: 5,
                                                                                     column: 6,
                                                                                     cursorVisible: false)

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

        func bootstrapTerminalStream(refreshedRoute: OrdinaryTmuxPanelRoute,
                                     outputFilePath: String,
                                     maxLines: Int) throws -> OrdinaryTmuxTerminalStreamBootstrap {
            if shouldFailBootstrap {
                throw StubError.bootstrapFailed
            }
            let initialOutput = try captureANSIOutput(route: refreshedRoute, maxLines: maxLines)
            let streamRoute = try startPipePane(route: refreshedRoute,
                                                outputFilePath: outputFilePath)
            return OrdinaryTmuxTerminalStreamBootstrap(route: streamRoute,
                                                       initialOutput: initialOutput)
        }

        func bootstrapStrictTerminalStream(
            refreshedRoute: OrdinaryTmuxPanelRoute,
            outputFilePath: String,
            subscriptionID: String
        ) throws -> OrdinaryTmuxTerminalStateV1 {
            if shouldFailBootstrap {
                throw StubError.bootstrapFailed
            }
            guard let strictState else {
                throw BridgeInternalError.invalidResponse
            }
            XCTAssertEqual(strictState.subscriptionID, subscriptionID)
            lock.lock()
            strictBootstrapCount += 1
            startedPipeRoutes.append(refreshedRoute)
            startedPipeOutputPaths.append(outputFilePath)
            lock.unlock()
            return strictState
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
            let shouldFail = remainingStopFailures > 0
            if shouldFail {
                remainingStopFailures -= 1
            }
            lock.unlock()
            if shouldFail {
                throw StubError.stopFailed
            }
        }

        func stopPipePane(exactRoute: OrdinaryTmuxPanelRoute) throws {
            try stopPipePane(route: exactRoute)
        }

        func queryCursorPosition(route: OrdinaryTmuxPanelRoute) throws -> OrdinaryTmuxCursorPosition? {
            lock.lock()
            cursorQueryCount += 1
            lock.unlock()
            return cursorPosition
        }

        func queryCursorPosition(exactRoute: OrdinaryTmuxPanelRoute) throws -> OrdinaryTmuxCursorPosition? {
            try queryCursorPosition(route: exactRoute)
        }

        func queryStrictTerminalFingerprint(
            exactRoute: OrdinaryTmuxPanelRoute
        ) throws -> OrdinaryTmuxTerminalFingerprintV1? {
            strictFingerprint
        }
    }

    private final class StubTailer: TerminalByteTailing, @unchecked Sendable {
        private let handler: TerminalByteFileTailer.ChunkHandler
        private(set) var startCount = 0
        private(set) var stopCount = 0

        init(handler: @escaping TerminalByteFileTailer.ChunkHandler) {
            self.handler = handler
        }

        func prepare() throws {
            startCount += 1
        }

        func activate() {}

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
        XCTAssertEqual(start.response.result?["cursor_visible"]?.boolValue, false)
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
                                        cursorColumn: 6,
                                        cursorVisible: false),
        ])

        start.subscription.stop()
        XCTAssertEqual(tailerBox.firstTailer?.stopCount, 1)
        XCTAssertEqual(adapter.stoppedPipeRoutes, [route])
    }

    func testIdentifiedSubscriptionEchoesIdentityInResponseAndDelta() throws {
        let route = ordinaryRoute()
        let adapter = StubAdapter()
        let tailerBox = StubTailerBox()
        let deltaBox = DeltaBox()
        let handler = OrdinaryTmuxOutputStreamHandler(routeResolver: StubResolver(route: route),
                                                      adapter: adapter,
                                                      outputDirectory: temporaryDirectory(),
                                                      makeTailer: { url, handler in
                                                          tailerBox.makeTailer(url: url, handler: handler)
                                                      })

        let start = try XCTUnwrap(handler.subscribe(BridgeRequest(
            id: "request-1",
            action: "subscribe_terminal_stream",
            params: [
                "panel_id": .string(route.panelID),
                "subscription_id": .string("owner-a"),
            ]
        ), onDelta: { delta in
            deltaBox.append(delta)
        }))
        start.subscription.activate()
        tailerBox.firstTailer?.emit("identified")

        XCTAssertEqual(start.response.result?["subscription_id"]?.stringValue, "owner-a")
        XCTAssertEqual(deltaBox.deltas.first?.subscriptionID, "owner-a")
        start.subscription.stop()
    }

    func testStrictSubscribeReturnsVersionedStateAndSequencedFingerprintDeltas() throws {
        let route = ordinaryRoute()
        let expectedFingerprint = OrdinaryTmuxTerminalFingerprintV1(
            paneID: route.activePaneID,
            columns: 80,
            rows: 2,
            alternateOn: true
        )
        let adapter = StubAdapter()
        adapter.strictState = OrdinaryTmuxTerminalStateV1(
            subscriptionID: "owner-a",
            paneID: route.activePaneID,
            columns: 80,
            rows: 2,
            cursor: OrdinaryTmuxTerminalCursorV1(row: 1, column: 4),
            cursorVisible: false,
            alternateOn: true,
            alternateSavedCursor: OrdinaryTmuxTerminalCursorV1(row: 0, column: 3),
            scrollRegionUpper: 0,
            scrollRegionLower: 1,
            tabStops: [8, 16, 24],
            modes: OrdinaryTmuxTerminalModesV1(
                insert: false,
                applicationCursorKeys: true,
                applicationKeypad: false,
                wrap: true,
                origin: false,
                mouseStandard: false,
                mouseButton: false,
                mouseAny: false,
                mouseUTF8: false,
                mouseSGR: true,
                paneKeyMode: "VT10x"
            ),
            activeScreen: Data("menu\nchoice".utf8),
            backgroundScreen: Data("shell\nprompt".utf8),
            pendingPrefix: Data([0x1B, 0x5B, 0x33, 0x31])
        )
        adapter.strictFingerprint = expectedFingerprint
        let tailerBox = StubTailerBox()
        let deltaBox = DeltaBox()
        let handler = OrdinaryTmuxOutputStreamHandler(
            routeResolver: StubResolver(route: route),
            adapter: adapter,
            outputDirectory: temporaryDirectory(),
            makeTailer: { url, handler in
                tailerBox.makeTailer(url: url, handler: handler)
            }
        )

        let start = try XCTUnwrap(handler.subscribe(BridgeRequest(
            id: "request-1",
            action: "subscribe_terminal_stream",
            params: [
                "panel_id": .string(route.panelID),
                "subscription_id": .string("owner-a"),
                "terminal_state_version": .number(1),
            ]
        ), onDelta: { deltaBox.append($0) }))

        XCTAssertEqual(start.response.result?["terminal_state_version"]?.intValue, 1)
        XCTAssertEqual(start.response.result?["pane_id"]?.stringValue, route.activePaneID)
        XCTAssertEqual(start.response.result?["cols"]?.intValue, 80)
        XCTAssertEqual(start.response.result?["rows"]?.intValue, 2)
        XCTAssertNil(start.response.result?["initial_output"])
        let screen = try XCTUnwrap(start.response.result?["screen"]?.objectValue)
        XCTAssertEqual(screen["cursor_col"]?.intValue, 4)
        XCTAssertEqual(screen["cursor_row"]?.intValue, 1)
        XCTAssertEqual(screen["cursor_visible"]?.boolValue, false)
        XCTAssertEqual(
            screen["active_capture_base64"]?.stringValue,
            Data("menu\nchoice".utf8).base64EncodedString()
        )
        XCTAssertEqual(
            screen["primary_capture_base64"]?.stringValue,
            Data("shell\nprompt".utf8).base64EncodedString()
        )
        let alternate = try XCTUnwrap(start.response.result?["alternate"]?.objectValue)
        XCTAssertEqual(alternate["active"]?.boolValue, true)
        XCTAssertEqual(alternate["saved_cursor_col"]?.intValue, 3)
        XCTAssertEqual(alternate["saved_cursor_row"]?.intValue, 0)
        let scrollRegion = try XCTUnwrap(start.response.result?["scroll_region"]?.objectValue)
        XCTAssertEqual(scrollRegion["upper"]?.intValue, 0)
        XCTAssertEqual(scrollRegion["lower"]?.intValue, 1)
        XCTAssertEqual(
            start.response.result?["tab_stops"]?.arrayValue?.compactMap(\.intValue),
            [8, 16, 24]
        )
        let modes = try XCTUnwrap(start.response.result?["modes"]?.objectValue)
        XCTAssertEqual(modes["insert"]?.boolValue, false)
        XCTAssertEqual(modes["keypad_cursor"]?.boolValue, true)
        XCTAssertEqual(modes["keypad"]?.boolValue, false)
        XCTAssertEqual(modes["wrap"]?.boolValue, true)
        XCTAssertEqual(modes["origin"]?.boolValue, false)
        XCTAssertEqual(modes["mouse_sgr"]?.boolValue, true)
        XCTAssertEqual(start.response.result?["pane_key_mode"]?.stringValue, "VT10x")
        XCTAssertEqual(
            start.response.result?["pending_prefix_base64"]?.stringValue,
            Data([0x1B, 0x5B, 0x33, 0x31]).base64EncodedString()
        )
        XCTAssertEqual(adapter.strictBootstrapCount, 1)

        start.subscription.activate()
        tailerBox.firstTailer?.emit("one")
        tailerBox.firstTailer?.emit("two")
        adapter.strictFingerprint = OrdinaryTmuxTerminalFingerprintV1(
            paneID: route.activePaneID,
            columns: 81,
            rows: 2,
            alternateOn: true
        )
        tailerBox.firstTailer?.emit("resize")
        tailerBox.firstTailer?.emit("must-drop")

        XCTAssertEqual(deltaBox.deltas.map(\.sequence), [1, 2, 3])
        XCTAssertEqual(deltaBox.deltas.map(\.rebootstrapRequired), [false, false, true])
        XCTAssertEqual(deltaBox.deltas.map(\.columns), [80, 80, 81])
        XCTAssertEqual(deltaBox.deltas.map(\.rows), [2, 2, 2])
        XCTAssertEqual(deltaBox.deltas.map(\.alternateOn), [true, true, true])
        XCTAssertEqual(deltaBox.deltas.map(\.subscriptionID), ["owner-a", "owner-a", "owner-a"])
        XCTAssertEqual(adapter.cursorQueryCount, 0)
        start.subscription.stop()
    }

    func testStrictSubscribeRequiresExactSubscriptionIdentityAndKnownVersion() {
        let route = ordinaryRoute()
        let handler = OrdinaryTmuxOutputStreamHandler(
            routeResolver: StubResolver(route: route),
            adapter: StubAdapter(),
            outputDirectory: temporaryDirectory()
        )

        for params: [String: JSONValue] in [
            [
                "panel_id": .string(route.panelID),
                "terminal_state_version": .number(1),
            ],
            [
                "panel_id": .string(route.panelID),
                "subscription_id": .string("owner-a"),
                "terminal_state_version": .number(2),
            ],
        ] {
            XCTAssertThrowsError(
                try handler.subscribe(
                    BridgeRequest(
                        id: "request-1",
                        action: "subscribe_terminal_stream",
                        params: params
                    ),
                    onDelta: { _ in }
                )
            ) { error in
                guard case BridgeInternalError.invalidRequest = error else {
                    return XCTFail("unexpected error: \(error)")
                }
            }
        }
    }

    func testReplacementStopCleansUpAndRemainsRetryableAfterPipeStopFailure() throws {
        let route = ordinaryRoute()
        let adapter = StubAdapter()
        adapter.remainingStopFailures = 1
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
                                                                  params: ["panel_id": .string(route.panelID)]),
                                                    onDelta: { _ in }))
        let subscription = try XCTUnwrap(start.subscription as? OrdinaryTmuxTerminalStreamSubscription)

        XCTAssertThrowsError(try subscription.stopForReplacement())
        XCTAssertEqual(tailerBox.firstTailer?.stopCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: subscription.outputFileURL.path))

        XCTAssertNoThrow(try subscription.stopForReplacement())
        XCTAssertEqual(tailerBox.firstTailer?.stopCount, 2)
        XCTAssertEqual(adapter.stoppedPipeRoutes, [route, route])

        XCTAssertNoThrow(try subscription.stopForReplacement())
        XCTAssertEqual(tailerBox.firstTailer?.stopCount, 2)
        XCTAssertEqual(adapter.stoppedPipeRoutes, [route, route])
    }

    func testBootstrapErrorWithSuccessfulRollbackLeavesNoPhantomOwner() throws {
        let route = ordinaryRoute()
        let adapter = StubAdapter()
        adapter.shouldFailBootstrap = true
        let tailerBox = StubTailerBox()
        let handler = OrdinaryTmuxOutputStreamHandler(routeResolver: StubResolver(route: route),
                                                      adapter: adapter,
                                                      outputDirectory: temporaryDirectory(),
                                                      makeTailer: { url, handler in
                                                          tailerBox.makeTailer(url: url, handler: handler)
                                                      })

        do {
            _ = try handler.subscribe(BridgeRequest(id: "request-1",
                                                    action: "subscribe_terminal_stream",
                                                    params: ["panel_id": .string(route.panelID)]),
                                      onDelta: { _ in })
            XCTFail("Ambiguous bootstrap failure must preserve an exact cleanup owner")
        } catch let failure as OrdinaryTmuxOutputStreamOwnedFailure {
            XCTAssertEqual(failure.underlying as? StubAdapter.StubError, .bootstrapFailed)
            XCTAssertEqual(failure.subscription.route, route)
            XCTAssertNoThrow(try failure.subscription.stopForReplacement())
            XCTAssertEqual(adapter.stoppedPipeRoutes, [route])
            XCTAssertEqual(tailerBox.firstTailer?.stopCount, 1)
        }
    }

    func testRejectedDeliverySkipsCursorQueryAndDeltaConstruction() throws {
        let route = ordinaryRoute()
        let adapter = StubAdapter()
        let tailerBox = StubTailerBox()
        let deltaBox = DeltaBox()
        let handler = OrdinaryTmuxOutputStreamHandler(routeResolver: StubResolver(route: route),
                                                      adapter: adapter,
                                                      outputDirectory: temporaryDirectory(),
                                                      makeTailer: { url, handler in
                                                          tailerBox.makeTailer(url: url, handler: handler)
                                                      })
        let start = try XCTUnwrap(handler.subscribe(BridgeRequest(id: "request-1",
                                                                  action: "subscribe_terminal_stream",
                                                                  params: ["panel_id": .string(route.panelID)]),
                                                    allowedIf: { false },
                                                    onDelta: { delta in
                                                        deltaBox.append(delta)
                                                    }))

        tailerBox.firstTailer?.emit("blocked")

        XCTAssertEqual(adapter.cursorQueryCount, 0)
        XCTAssertEqual(deltaBox.deltas, [])
        start.subscription.stop()
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
