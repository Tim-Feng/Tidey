import NIOEmbedded
import NIOCore
import XCTest
@testable import RemoteBridge

final class TerminalStreamSubscriptionLifecycleTests: XCTestCase {
    func testLocalRequestResultExposesDeferredEventLoopCommitOutcome() throws {
        let accepted = WebSocketFrameHandler.LocalRequestResult(
            response: BridgeResponse(id: "accepted", ok: true, result: nil, error: nil),
            agentReplayEnvelopes: [],
            workspaceReplayEnvelopes: [],
            applyOnEventLoop: { .accepted }
        )
        let rejected = WebSocketFrameHandler.LocalRequestResult(
            response: BridgeResponse(id: "rejected", ok: true, result: nil, error: nil),
            agentReplayEnvelopes: [],
            workspaceReplayEnvelopes: [],
            applyOnEventLoop: { .rejected(reason: "newer request already owns the slot") }
        )

        XCTAssertEqual(try XCTUnwrap(accepted.applyOnEventLoop)(), .accepted)
        XCTAssertEqual(try XCTUnwrap(rejected.applyOnEventLoop)(),
                       .rejected(reason: "newer request already owns the slot"))
    }

    private final class EventLog: @unchecked Sendable {
        private let lock = NSLock()
        private var storedEvents = [String]()

        func append(_ event: String) {
            lock.lock()
            storedEvents.append(event)
            lock.unlock()
        }

        var events: [String] {
            lock.lock()
            defer { lock.unlock() }
            return storedEvents
        }
    }

    private final class StubTerminalStreamSubscription: OrdinaryTmuxTerminalStreamSubscribing, @unchecked Sendable {
        let route: OrdinaryTmuxPanelRoute
        private let label: String
        private let eventLog: EventLog

        init(route: OrdinaryTmuxPanelRoute, label: String, eventLog: EventLog) {
            self.route = route
            self.label = label
            self.eventLog = eventLog
        }

        func stop() {
            eventLog.append("stop-\(label)")
        }
    }

    private final class StubTerminalStreamHandler: OrdinaryTmuxOutputStreaming, @unchecked Sendable {
        private let eventLog: EventLog
        private let lock = NSLock()
        private var subscribeCount = 0

        init(eventLog: EventLog) {
            self.eventLog = eventLog
        }

        func subscribe(_ request: BridgeRequest,
                       onDelta: @escaping @Sendable (TerminalStreamDeltaEnvelope) -> Void) throws -> OrdinaryTmuxOutputStreamStart? {
            guard request.action == "subscribe_terminal_stream" else {
                return nil
            }
            guard let panelID = request.params?["panel_id"]?.stringValue else {
                throw BridgeInternalError.invalidRequest("missing panel_id")
            }
            lock.lock()
            subscribeCount += 1
            let label = "\(subscribeCount)"
            lock.unlock()
            eventLog.append("subscribe-\(label)")
            let route = TerminalStreamSubscriptionLifecycleTests.ordinaryRoute(panelID: panelID)
            let response = BridgeResponse(id: request.id,
                                          ok: true,
                                          result: [
                                            "subscribed": .bool(true),
                                            "workspace_id": .string(route.workspaceID),
                                            "panel_id": .string(route.panelID),
                                            "initial_output": .string("initial"),
                                          ],
                                          error: nil)
            return OrdinaryTmuxOutputStreamStart(
                response: response,
                subscription: StubTerminalStreamSubscription(route: route,
                                                            label: label,
                                                            eventLog: eventLog)
            )
        }
    }

    func testResubscribeStopsExistingPanelStreamBeforeStartingReplacement() throws {
        let eventLog = EventLog()
        let fixture = try makeFixture(outputStreamHandler: StubTerminalStreamHandler(eventLog: eventLog))
        defer { fixture.cleanup() }
        let panelID = ordinaryPanelID(windowID: "@16")

        _ = try XCTUnwrap(fixture.handler.handleLocalRequest(subscribeRequest(id: "subscribe-1", panelID: panelID),
                                                             context: fixture.context))
        _ = try XCTUnwrap(fixture.handler.handleLocalRequest(subscribeRequest(id: "subscribe-2", panelID: panelID),
                                                             context: fixture.context))

        XCTAssertEqual(eventLog.events, ["subscribe-1", "stop-1", "subscribe-2"])
        XCTAssertEqual(fixture.observability.snapshot(activeSessions: []).activeTerminalStreamSubscriptionCount, 1)
    }

    func testExplicitUnsubscribeStopsOnlyRequestedTerminalStream() throws {
        let eventLog = EventLog()
        let fixture = try makeFixture(outputStreamHandler: StubTerminalStreamHandler(eventLog: eventLog))
        defer { fixture.cleanup() }
        let firstPanelID = ordinaryPanelID(windowID: "@16")
        let secondPanelID = ordinaryPanelID(windowID: "@17")

        _ = try XCTUnwrap(fixture.handler.handleLocalRequest(subscribeRequest(id: "subscribe-1", panelID: firstPanelID),
                                                             context: fixture.context))
        _ = try XCTUnwrap(fixture.handler.handleLocalRequest(subscribeRequest(id: "subscribe-2", panelID: secondPanelID),
                                                             context: fixture.context))
        _ = try XCTUnwrap(fixture.handler.handleLocalRequest(BridgeRequest(id: "unsubscribe-1",
                                                                           action: "unsubscribe_terminal_stream",
                                                                           params: ["panel_id": .string(firstPanelID)]),
                                                             context: fixture.context))

        XCTAssertEqual(eventLog.events, ["subscribe-1", "subscribe-2", "stop-1"])
        XCTAssertEqual(fixture.observability.snapshot(activeSessions: []).activeTerminalStreamSubscriptionCount, 1)
    }

    func testChannelInactiveStopsAllTerminalStreams() throws {
        let eventLog = EventLog()
        let fixture = try makeFixture(outputStreamHandler: StubTerminalStreamHandler(eventLog: eventLog))
        defer { fixture.cleanup() }

        _ = try XCTUnwrap(fixture.handler.handleLocalRequest(subscribeRequest(id: "subscribe-1",
                                                                              panelID: ordinaryPanelID(windowID: "@16")),
                                                             context: fixture.context))
        _ = try XCTUnwrap(fixture.handler.handleLocalRequest(subscribeRequest(id: "subscribe-2",
                                                                              panelID: ordinaryPanelID(windowID: "@17")),
                                                             context: fixture.context))
        fixture.handler.channelInactive(context: fixture.context)

        XCTAssertEqual(Set(eventLog.events), Set(["subscribe-1", "subscribe-2", "stop-1", "stop-2"]))
        let snapshot = fixture.observability.snapshot(activeSessions: [])
        XCTAssertEqual(snapshot.activeTerminalStreamSubscriptionCount, 0)
        XCTAssertEqual(snapshot.connectionEvents.last?.kind, .disconnected)
        XCTAssertEqual(snapshot.connectionEvents.last?.terminalStreamSubscriptionCount, 2)
    }

    private func subscribeRequest(id: String, panelID: String) -> BridgeRequest {
        BridgeRequest(id: id,
                      action: "subscribe_terminal_stream",
                      params: [
                        "workspace_id": .string("workspace-1"),
                        "panel_id": .string(panelID),
                      ])
    }

    private struct Fixture {
        let handler: WebSocketFrameHandler
        let context: ChannelHandlerContext
        let channel: EmbeddedChannel
        let observability: BridgeObservabilityCenter
        let supportDirectory: URL

        func cleanup() {
            _ = try? channel.finish()
            try? FileManager.default.removeItem(at: supportDirectory)
        }
    }

    private func makeFixture(outputStreamHandler: OrdinaryTmuxOutputStreaming) throws -> Fixture {
        let supportDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TerminalStreamSubscriptionLifecycleTests-\(UUID().uuidString)",
                                    isDirectory: true)
        let paths = BridgePaths(supportDirectory: supportDirectory)
        try paths.ensureSupportDirectoriesExist(fileManager: .default)
        let eventHub = AgentEventHub()
        let monitor = AgentSessionRegistryMonitor(paths: paths,
                                                  fileManager: .default,
                                                  hub: eventHub,
                                                  tmuxResolver: TmuxStateResolver(ttl: 60) { _, _ in "" },
                                                  parentPIDLookup: { _ in nil })
        let observability = BridgeObservabilityCenter()
        let handler = WebSocketFrameHandler(socketClient: TideySocketClient(locator: TideySocketLocator()),
                                            eventHub: eventHub,
                                            workspaceEventHub: WorkspaceEventHub(),
                                            registryMonitor: monitor,
                                            observability: observability,
                                            bridgePort: 0,
                                            cloudflaredManager: BridgeCloudflaredManager(binaryResolver: { nil }),
                                            ordinaryTmuxOutputStreamHandler: outputStreamHandler)
        let channel = EmbeddedChannel(handler: handler)
        let context = try channel.pipeline.syncOperations.context(handler: handler)
        return Fixture(handler: handler,
                       context: context,
                       channel: channel,
                       observability: observability,
                       supportDirectory: supportDirectory)
    }

    private static func ordinaryRoute(panelID: String) -> OrdinaryTmuxPanelRoute {
        let windowID = panelID.split(separator: ":").last.map(String.init) ?? "@16"
        let paneID = "%\(windowID.dropFirst())"
        return OrdinaryTmuxPanelRoute(workspaceID: "workspace-1",
                                      panelID: panelID,
                                      carrierPanelID: "carrier-panel",
                                      socket: .path("/tmp/tmux-\(getuid())/default"),
                                      sessionID: "$7",
                                      sessionName: "tidey-codex",
                                      windowID: windowID,
                                      windowIndex: 1,
                                      activePaneID: paneID,
                                      cwd: "/Users/timfeng/GitHub/Tidey",
                                      currentCommand: "codex")
    }

    private func ordinaryPanelID(windowID: String) -> String {
        "ordinary-tmux:/tmp/tmux-\(getuid())/default:$7:\(windowID)"
    }
}
