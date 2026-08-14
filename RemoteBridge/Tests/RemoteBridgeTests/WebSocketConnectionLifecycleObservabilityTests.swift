import Foundation
import NIOCore
import NIOEmbedded
import NIOWebSocket
import XCTest
@testable import RemoteBridge

final class WebSocketConnectionLifecycleObservabilityTests: XCTestCase {
    private struct StubWriteError: Error {}

    private final class InteractivePTYControllerProbe:
        TmuxInteractivePTYControlling,
        @unchecked Sendable
    {
        private(set) var closeCalls = [Int32]()
        private(set) var reapCalls = [(processID: Int32, blocking: Bool)]()

        func spawn(
            _ command: TmuxInteractivePTYAttachCommand
        ) throws -> TmuxInteractivePTYHandle {
            TmuxInteractivePTYHandle(masterFileDescriptor: 17, childProcessID: 23)
        }

        func resize(masterFileDescriptor: Int32, to size: TmuxInteractivePTYSize) throws {}

        func close(masterFileDescriptor: Int32) throws {
            closeCalls.append(masterFileDescriptor)
        }

        func reap(
            childProcessID: Int32,
            blocking: Bool
        ) throws -> TmuxInteractivePTYChildExit? {
            reapCalls.append((childProcessID, blocking))
            return TmuxInteractivePTYChildExit(rawStatus: 0)
        }

        func read(
            masterFileDescriptor: Int32,
            maximumBytes: Int
        ) throws -> TmuxInteractivePTYReadResult {
            .wouldBlock
        }

        func write(
            _ bytes: Data,
            masterFileDescriptor: Int32
        ) throws -> TmuxInteractivePTYWriteResult {
            .written(bytes.count)
        }
    }

    private final class FailingOutboundHandler: ChannelOutboundHandler {
        typealias OutboundIn = WebSocketFrame

        func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
            promise?.fail(StubWriteError())
        }
    }

    private final class StubClock: @unchecked Sendable {
        private let lock = NSLock()
        private var dates: [Date]

        init(_ dates: [Date]) {
            self.dates = dates
        }

        func now() -> Date {
            lock.lock()
            defer { lock.unlock() }
            return dates.isEmpty ? Date(timeIntervalSince1970: 0) : dates.removeFirst()
        }
    }

    func testPeerCloseRecordsCodeReasonSizeAndConnectionDuration() throws {
        let observability = BridgeObservabilityCenter()
        let clock = StubClock([
            Date(timeIntervalSince1970: 10),
            Date(timeIntervalSince1970: 11),
            Date(timeIntervalSince1970: 12),
        ])
        let fixture = try makeFixture(observability: observability,
                                      connectionID: "connection-test",
                                      now: { clock.now() })
        defer { fixture.cleanup() }

        var closeData = fixture.channel.allocator.buffer(capacity: 5)
        closeData.writeInteger(UInt16(1001))
        closeData.writeString("bye")
        _ = try fixture.channel.writeInbound(WebSocketFrame(fin: true,
                                                            opcode: .connectionClose,
                                                            data: closeData))
        fixture.channel.embeddedEventLoop.run()

        let events = observability.snapshot(activeSessions: []).connectionEvents
        XCTAssertEqual(events.map(\.kind), [.connected, .peerClose, .disconnected])
        XCTAssertEqual(events[1].connectionID, "connection-test")
        XCTAssertEqual(events[1].closeCode, 1001)
        XCTAssertEqual(events[1].reasonByteCount, 3)
        XCTAssertEqual(try XCTUnwrap(events[2].durationMs), 2_000, accuracy: 0.001)
    }

    func testChannelErrorRecordsBoundedMetadataAndStillForwardsError() throws {
        let observability = BridgeObservabilityCenter()
        let fixture = try makeFixture(observability: observability,
                                      connectionID: "connection-error",
                                      now: { Date(timeIntervalSince1970: 20) })
        defer { fixture.cleanup() }
        let error = NSError(domain: "WebSocketConnectionLifecycleTests",
                            code: 42,
                            userInfo: [NSLocalizedDescriptionKey: "SENTINEL_PRIVATE_DESCRIPTION"])

        fixture.handler.errorCaught(context: fixture.context, error: error)

        XCTAssertThrowsError(try fixture.channel.throwIfErrorCaught())
        let snapshot = observability.snapshot(activeSessions: [])
        let event = try XCTUnwrap(snapshot.connectionEvents.last)
        XCTAssertEqual(event.kind, .channelError)
        XCTAssertEqual(event.errorDomain, "WebSocketConnectionLifecycleTests")
        XCTAssertEqual(event.errorCode, 42)

        let encoded = try JSONEncoder().encode(snapshot)
        let encodedText = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertFalse(encodedText.contains("SENTINEL_PRIVATE_DESCRIPTION"))
    }

    func testPongWriteFailureIsRecordedWithoutClosingChannel() throws {
        let observability = BridgeObservabilityCenter()
        let fixture = try makeFixture(observability: observability,
                                      connectionID: "connection-write",
                                      now: { Date(timeIntervalSince1970: 30) },
                                      failWrites: true)
        defer { fixture.cleanup() }
        var pingData = fixture.channel.allocator.buffer(capacity: 4)
        pingData.writeString("ping")

        _ = try fixture.channel.writeInbound(WebSocketFrame(fin: true,
                                                            opcode: .ping,
                                                            data: pingData))
        fixture.channel.embeddedEventLoop.run()

        let events = observability.snapshot(activeSessions: []).connectionEvents
        let event = try XCTUnwrap(events.last)
        XCTAssertEqual(event.kind, .writeFailed)
        XCTAssertEqual(event.messageType, "pong")
        XCTAssertEqual(event.byteCount, 4)
        XCTAssertFalse(events.contains { $0.kind == .disconnected })
    }

    func testChannelInactiveClosesInteractivePTYAndReleasesLeaseExactlyOnce() throws {
        let observability = BridgeObservabilityCenter()
        let fixture = try makeFixture(
            observability: observability,
            connectionID: "connection-interactive-pty",
            now: { Date(timeIntervalSince1970: 40) },
            requestExecutor: { work in work() }
        )
        defer { fixture.cleanup() }
        let store = OrdinaryTmuxInputSubmissionStore()
        let controller = InteractivePTYControllerProbe()
        let owner = TmuxInteractivePTYSessionOwner(
            admissionStore: store,
            controller: controller
        )
        let route = OrdinaryTmuxPanelRoute(
            workspaceID: "workspace-1",
            panelID: "ordinary-tmux:path:$1:@2",
            carrierPanelID: "carrier-1",
            socket: .path("/private/tmp/tmux-501/default"),
            sessionID: "$1",
            sessionName: "session-1",
            windowID: "@2",
            windowIndex: 1,
            activePaneID: "%3",
            cwd: nil,
            currentCommand: "zsh"
        )
        let binding = TmuxInteractiveSubscriptionBinding(
            subscriptionID: "interactive-1",
            generation: 9
        )
        try owner.begin(
            TmuxInteractivePTYSessionStartRequest(
                subscribe: TmuxInteractiveSubscribe(
                    workspaceID: route.workspaceID,
                    panelID: route.panelID,
                    binding: binding,
                    viewport: TmuxInteractiveViewport(columns: 80, rows: 24)
                ),
                route: route,
                tmuxExecutablePath: "/opt/homebrew/bin/tmux"
            )
        )
        XCTAssertTrue(
            fixture.handler.installInteractivePTYOwner(
                binding: binding,
                owner: owner
            )
        )

        fixture.handler.channelInactive(context: fixture.context)
        fixture.handler.channelInactive(context: fixture.context)

        XCTAssertEqual(owner.lifecycleState, .closed)
        XCTAssertEqual(controller.closeCalls, [17])
        XCTAssertEqual(controller.reapCalls.count, 1)
        let sessionKey = OrdinaryTmuxSessionKey(
            socket: route.socket,
            sessionID: route.sessionID
        )
        let afterLossToken = OrdinaryTmuxInteractiveLeaseToken(rawValue: "after-loss")
        XCTAssertTrue(
            store.acquireInteractiveLease(token: afterLossToken, sessionKey: sessionKey)
        )
        store.releaseInteractiveLease(token: afterLossToken, sessionKey: sessionKey)
        XCTAssertFalse(
            fixture.handler.installInteractivePTYOwner(
                binding: TmuxInteractiveSubscriptionBinding(
                    subscriptionID: "late",
                    generation: 10
                ),
                owner: TmuxInteractivePTYSessionOwner(
                    admissionStore: store,
                    controller: InteractivePTYControllerProbe()
                )
            )
        )
    }

    private struct Fixture {
        let handler: WebSocketFrameHandler
        let context: ChannelHandlerContext
        let channel: EmbeddedChannel
        let supportDirectory: URL

        func cleanup() {
            _ = try? channel.finish()
            try? FileManager.default.removeItem(at: supportDirectory)
        }
    }

    private func makeFixture(observability: BridgeObservabilityCenter,
                             connectionID: String,
                             now: @escaping @Sendable () -> Date,
                             failWrites: Bool = false,
                             requestExecutor: @escaping BridgeRequestExecutor = { work in
                                 work()
                             }) throws -> Fixture {
        let supportDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WebSocketConnectionLifecycleObservabilityTests-\(UUID().uuidString)",
                                    isDirectory: true)
        let paths = BridgePaths(supportDirectory: supportDirectory)
        try paths.ensureSupportDirectoriesExist(fileManager: .default)
        let eventHub = AgentEventHub()
        let monitor = AgentSessionRegistryMonitor(paths: paths,
                                                  fileManager: .default,
                                                  hub: eventHub,
                                                  tmuxResolver: TmuxStateResolver(ttl: 60) { _, _ in "" },
                                                  parentPIDLookup: { _ in nil })
        let handler = WebSocketFrameHandler(socketClient: TideySocketClient(locator: TideySocketLocator()),
                                            eventHub: eventHub,
                                            workspaceEventHub: WorkspaceEventHub(),
                                            registryMonitor: monitor,
                                            observability: observability,
                                            bridgePort: 0,
                                            cloudflaredManager: BridgeCloudflaredManager(binaryResolver: { nil }),
                                            connectionID: connectionID,
                                            now: now,
                                            requestExecutor: requestExecutor)
        let channel = failWrites
            ? EmbeddedChannel(handlers: [FailingOutboundHandler(), handler])
            : EmbeddedChannel(handler: handler)
        let context = try channel.pipeline.syncOperations.context(handler: handler)
        return Fixture(handler: handler,
                       context: context,
                       channel: channel,
                       supportDirectory: supportDirectory)
    }
}
