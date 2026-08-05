import NIOEmbedded
import NIOCore
import NIOWebSocket
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

    private final class LaneQueueStore: @unchecked Sendable {
        private let lock = NSLock()
        private var queues = [DispatchQueue]()

        func makeQueue(panelID: String) -> DispatchQueue {
            let queue = DispatchQueue(label: "TerminalStreamSubscriptionLifecycleTests.\(panelID)")
            lock.lock()
            queues.append(queue)
            lock.unlock()
            return queue
        }

        func drain() {
            lock.lock()
            let snapshot = queues
            lock.unlock()
            for queue in snapshot {
                queue.sync {}
            }
        }
    }

    private final class ManualTerminalScheduler: @unchecked Sendable {
        private struct ScheduledWork {
            let eventLoop: EventLoop
            let work: () -> Void
        }

        private let lock = NSLock()
        private var scheduled = [ScheduledWork]()

        func schedule(eventLoop: EventLoop, work: @escaping () -> Void) {
            lock.lock()
            scheduled.append(ScheduledWork(eventLoop: eventLoop, work: work))
            lock.unlock()
        }

        func enqueuePendingOnEventLoops() {
            lock.lock()
            let pending = scheduled
            scheduled.removeAll()
            lock.unlock()
            for item in pending {
                item.eventLoop.execute(item.work)
            }
        }
    }

    private final class ManualRequestExecutor: @unchecked Sendable {
        private let lock = NSLock()
        private var workItems = [() -> Void]()

        func enqueue(_ work: @escaping () -> Void) {
            lock.lock()
            workItems.append(work)
            lock.unlock()
        }

        func runFirst(file: StaticString = #filePath, line: UInt = #line) {
            run(at: 0, file: file, line: line)
        }

        func runLast(file: StaticString = #filePath, line: UInt = #line) {
            lock.lock()
            let index = workItems.indices.last
            lock.unlock()
            guard let index else {
                XCTFail("No queued request work", file: file, line: line)
                return
            }
            run(at: index, file: file, line: line)
        }

        private func run(at index: Int, file: StaticString, line: UInt) {
            lock.lock()
            guard workItems.indices.contains(index) else {
                lock.unlock()
                XCTFail("No queued request work at index \(index)", file: file, line: line)
                return
            }
            let work = workItems.remove(at: index)
            lock.unlock()
            work()
        }
    }

    private final class StubTerminalStreamSubscription: OrdinaryTmuxTerminalStreamSubscribing, @unchecked Sendable {
        let route: OrdinaryTmuxPanelRoute
        private let label: String
        private let eventLog: EventLog
        private let onActivate: (@Sendable () -> Void)?

        init(route: OrdinaryTmuxPanelRoute,
             label: String,
             eventLog: EventLog,
             onActivate: (@Sendable () -> Void)? = nil) {
            self.route = route
            self.label = label
            self.eventLog = eventLog
            self.onActivate = onActivate
        }

        func activate() {
            onActivate?()
        }

        @discardableResult
        func stop() -> Bool {
            eventLog.append("stop-\(label)")
            return true
        }
    }

    private final class StubTerminalStreamHandler: OrdinaryTmuxOutputStreaming, @unchecked Sendable {
        private let eventLog: EventLog
        private let emitOnActivate: Bool
        private let lock = NSLock()
        private var subscribeCount = 0
        private var deltaHandlers = [Int: @Sendable (TerminalStreamDeltaEnvelope) -> Void]()

        init(eventLog: EventLog, emitOnActivate: Bool = false) {
            self.eventLog = eventLog
            self.emitOnActivate = emitOnActivate
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
            let subscriptionNumber = subscribeCount
            deltaHandlers[subscriptionNumber] = onDelta
            let label = "\(subscriptionNumber)"
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
            let onActivate: (@Sendable () -> Void)?
            if emitOnActivate {
                onActivate = {
                    self.eventLog.append("activate-\(label)")
                    onDelta(TerminalStreamDeltaEnvelope(
                        type: "terminal_stream_delta",
                        workspaceID: route.workspaceID,
                        panelID: route.panelID,
                        chunk: "pending",
                        chunkBase64: Data("pending".utf8).base64EncodedString(),
                        cursorRow: 1,
                        cursorColumn: 1,
                        cursorVisible: true
                    ))
                }
            } else {
                onActivate = nil
            }
            return OrdinaryTmuxOutputStreamStart(
                response: response,
                subscription: StubTerminalStreamSubscription(route: route,
                                                            label: label,
                                                            eventLog: eventLog,
                                                            onActivate: onActivate)
            )
        }

        func emit(subscriptionNumber: Int, panelID: String, text: String) {
            lock.lock()
            let handler = deltaHandlers[subscriptionNumber]
            lock.unlock()
            handler?(TerminalStreamDeltaEnvelope(type: "terminal_stream_delta",
                                                 workspaceID: "workspace-1",
                                                 panelID: panelID,
                                                 chunk: text,
                                                 chunkBase64: Data(text.utf8).base64EncodedString(),
                                                 cursorRow: 1,
                                                 cursorColumn: 1,
                                                 cursorVisible: true))
        }
    }

    func testResponseIsEnqueuedBeforeDurablePendingBytesActivate() throws {
        let eventLog = EventLog()
        let outputStreamHandler = StubTerminalStreamHandler(eventLog: eventLog,
                                                            emitOnActivate: true)
        let fixture = try makeFixture(outputStreamHandler: outputStreamHandler)
        defer { fixture.cleanup() }
        let panelID = ordinaryPanelID(windowID: "@16")

        try writeRequest(subscribeRequest(id: "subscribe-1", panelID: panelID),
                         to: fixture.channel)
        fixture.requestExecutor.runFirst()
        fixture.channel.embeddedEventLoop.run()
        fixture.drainTerminalWork()

        let responseFrame = try XCTUnwrap(fixture.channel.readOutbound(as: WebSocketFrame.self))
        let response = try decode(responseFrame, as: BridgeResponse.self)
        XCTAssertEqual(response.id, "subscribe-1")
        XCTAssertTrue(response.ok)

        let deltaFrame = try XCTUnwrap(fixture.channel.readOutbound(as: WebSocketFrame.self))
        let delta = try decode(deltaFrame, as: TerminalStreamDeltaEnvelope.self)
        XCTAssertEqual(delta.chunk, "pending")
        XCTAssertEqual(eventLog.events, ["subscribe-1", "activate-1"])
    }

    func testResubscribeStopsExistingPanelStreamBeforeStartingReplacement() throws {
        let eventLog = EventLog()
        let fixture = try makeFixture(outputStreamHandler: StubTerminalStreamHandler(eventLog: eventLog))
        defer { fixture.cleanup() }
        let panelID = ordinaryPanelID(windowID: "@16")

        let first = try XCTUnwrap(fixture.handler.handleLocalRequest(subscribeRequest(id: "subscribe-1", panelID: panelID),
                                                                     context: fixture.context))
        XCTAssertEqual(first.applyOnEventLoop?() ?? .accepted, .accepted)
        let second = try XCTUnwrap(fixture.handler.handleLocalRequest(subscribeRequest(id: "subscribe-2", panelID: panelID),
                                                                      context: fixture.context))
        XCTAssertEqual(second.applyOnEventLoop?() ?? .accepted, .accepted)
        fixture.drainTerminalWork()

        XCTAssertEqual(eventLog.events, ["subscribe-1", "stop-1", "subscribe-2"])
        XCTAssertEqual(fixture.observability.snapshot(activeSessions: []).activeTerminalStreamSubscriptionCount, 1)
    }

    func testExplicitUnsubscribeStopsOnlyRequestedTerminalStream() throws {
        let eventLog = EventLog()
        let fixture = try makeFixture(outputStreamHandler: StubTerminalStreamHandler(eventLog: eventLog))
        defer { fixture.cleanup() }
        let firstPanelID = ordinaryPanelID(windowID: "@16")
        let secondPanelID = ordinaryPanelID(windowID: "@17")

        let first = try XCTUnwrap(fixture.handler.handleLocalRequest(subscribeRequest(id: "subscribe-1", panelID: firstPanelID),
                                                                     context: fixture.context))
        XCTAssertEqual(first.applyOnEventLoop?() ?? .accepted, .accepted)
        let second = try XCTUnwrap(fixture.handler.handleLocalRequest(subscribeRequest(id: "subscribe-2", panelID: secondPanelID),
                                                                      context: fixture.context))
        XCTAssertEqual(second.applyOnEventLoop?() ?? .accepted, .accepted)
        let unsubscribe = try XCTUnwrap(fixture.handler.handleLocalRequest(BridgeRequest(id: "unsubscribe-1",
                                                                                         action: "unsubscribe_terminal_stream",
                                                                                         params: ["panel_id": .string(firstPanelID)]),
                                                                           context: fixture.context))
        XCTAssertEqual(unsubscribe.applyOnEventLoop?() ?? .accepted, .accepted)
        fixture.drainTerminalWork()

        XCTAssertEqual(eventLog.events, ["subscribe-1", "subscribe-2", "stop-1"])
        XCTAssertEqual(fixture.observability.snapshot(activeSessions: []).activeTerminalStreamSubscriptionCount, 1)
    }

    func testChannelInactiveStopsAllTerminalStreams() throws {
        let eventLog = EventLog()
        let fixture = try makeFixture(outputStreamHandler: StubTerminalStreamHandler(eventLog: eventLog))
        defer { fixture.cleanup() }

        let first = try XCTUnwrap(fixture.handler.handleLocalRequest(subscribeRequest(id: "subscribe-1",
                                                                                      panelID: ordinaryPanelID(windowID: "@16")),
                                                                     context: fixture.context))
        XCTAssertEqual(first.applyOnEventLoop?() ?? .accepted, .accepted)
        let second = try XCTUnwrap(fixture.handler.handleLocalRequest(subscribeRequest(id: "subscribe-2",
                                                                                       panelID: ordinaryPanelID(windowID: "@17")),
                                                                      context: fixture.context))
        XCTAssertEqual(second.applyOnEventLoop?() ?? .accepted, .accepted)
        fixture.handler.channelInactive(context: fixture.context)
        fixture.drainTerminalWork()

        XCTAssertEqual(Set(eventLog.events), Set(["subscribe-1", "subscribe-2", "stop-1", "stop-2"]))
        let snapshot = fixture.observability.snapshot(activeSessions: [])
        XCTAssertEqual(snapshot.activeTerminalStreamSubscriptionCount, 0)
        XCTAssertEqual(snapshot.connectionEvents.last?.kind, .disconnected)
        XCTAssertEqual(snapshot.connectionEvents.last?.terminalStreamSubscriptionCount, 2)
    }

    func testSharedPanelSubscriptionMovesOwnershipAcrossConnections() throws {
        let eventLog = EventLog()
        let outputStreamHandler = StubTerminalStreamHandler(eventLog: eventLog)
        let observability = BridgeObservabilityCenter()
        let requestSequencer = BridgeRequestSequencer()
        let laneQueues = LaneQueueStore()
        let terminalScheduler = ManualTerminalScheduler()
        let laneRegistry = OrdinaryTmuxTerminalStreamLaneRegistry(makeQueue: { panelID in
            laneQueues.makeQueue(panelID: panelID)
        })
        let firstFixture = try makeFixture(outputStreamHandler: outputStreamHandler,
                                           observability: observability,
                                           requestSequencer: requestSequencer,
                                           terminalStreamLaneRegistry: laneRegistry,
                                           laneQueues: laneQueues,
                                           terminalScheduler: terminalScheduler)
        let secondFixture = try makeFixture(outputStreamHandler: outputStreamHandler,
                                            observability: observability,
                                            requestSequencer: requestSequencer,
                                            terminalStreamLaneRegistry: laneRegistry,
                                            laneQueues: laneQueues,
                                            terminalScheduler: terminalScheduler)
        defer {
            firstFixture.cleanup()
            secondFixture.cleanup()
        }
        let panelID = ordinaryPanelID(windowID: "@16")

        let first = try XCTUnwrap(firstFixture.handler.handleLocalRequest(
            subscribeRequest(id: "subscribe-1", panelID: panelID),
            context: firstFixture.context
        ))
        XCTAssertEqual(first.applyOnEventLoop?() ?? .accepted, .accepted)
        let second = try XCTUnwrap(secondFixture.handler.handleLocalRequest(
            subscribeRequest(id: "subscribe-2", panelID: panelID),
            context: secondFixture.context
        ))
        XCTAssertEqual(second.applyOnEventLoop?() ?? .accepted, .accepted)
        laneQueues.drain()
        terminalScheduler.enqueuePendingOnEventLoops()
        firstFixture.channel.embeddedEventLoop.run()
        secondFixture.channel.embeddedEventLoop.run()

        XCTAssertEqual(eventLog.events, ["subscribe-1", "stop-1", "subscribe-2"])
        XCTAssertEqual(observability.snapshot(activeSessions: []).activeTerminalStreamSubscriptionCount, 1)
    }

    func testQueuedDeltaIsDroppedWhenAnotherConnectionDisplacesItsLeaseBeforeDelivery() throws {
        let eventLog = EventLog()
        let outputStreamHandler = StubTerminalStreamHandler(eventLog: eventLog)
        let observability = BridgeObservabilityCenter()
        let requestSequencer = BridgeRequestSequencer()
        let laneQueues = LaneQueueStore()
        let terminalScheduler = ManualTerminalScheduler()
        let laneRegistry = OrdinaryTmuxTerminalStreamLaneRegistry(makeQueue: { panelID in
            laneQueues.makeQueue(panelID: panelID)
        })
        let firstFixture = try makeFixture(outputStreamHandler: outputStreamHandler,
                                           observability: observability,
                                           requestSequencer: requestSequencer,
                                           terminalStreamLaneRegistry: laneRegistry,
                                           laneQueues: laneQueues,
                                           terminalScheduler: terminalScheduler)
        let secondFixture = try makeFixture(outputStreamHandler: outputStreamHandler,
                                            observability: observability,
                                            requestSequencer: requestSequencer,
                                            terminalStreamLaneRegistry: laneRegistry,
                                            laneQueues: laneQueues,
                                            terminalScheduler: terminalScheduler)
        defer {
            firstFixture.cleanup()
            secondFixture.cleanup()
        }
        let panelID = ordinaryPanelID(windowID: "@16")

        let first = try XCTUnwrap(firstFixture.handler.handleLocalRequest(
            subscribeRequest(id: "subscribe-1", panelID: panelID),
            context: firstFixture.context
        ))
        XCTAssertEqual(first.applyOnEventLoop?() ?? .accepted, .accepted)
        outputStreamHandler.emit(subscriptionNumber: 1, panelID: panelID, text: "stale")

        let second = try XCTUnwrap(secondFixture.handler.handleLocalRequest(
            subscribeRequest(id: "subscribe-2", panelID: panelID),
            context: secondFixture.context
        ))
        XCTAssertEqual(second.applyOnEventLoop?() ?? .accepted, .accepted)
        laneQueues.drain()
        terminalScheduler.enqueuePendingOnEventLoops()
        firstFixture.channel.embeddedEventLoop.run()
        secondFixture.channel.embeddedEventLoop.run()

        let staleFrame = try firstFixture.channel.readOutbound(as: WebSocketFrame.self)
        XCTAssertNil(staleFrame)
        XCTAssertEqual(observability.snapshot(activeSessions: []).activeTerminalStreamSubscriptionCount, 1)
    }

    func testPendingOlderSubscribeIsSupersededAfterNewerSubscribeDisplacesIt() throws {
        let eventLog = EventLog()
        let fixture = try makeFixture(outputStreamHandler: StubTerminalStreamHandler(eventLog: eventLog))
        defer { fixture.cleanup() }
        let panelID = ordinaryPanelID(windowID: "@16")

        try writeRequest(subscribeRequest(id: "subscribe-1", panelID: panelID), to: fixture.channel)
        try writeRequest(subscribeRequest(id: "subscribe-2", panelID: panelID), to: fixture.channel)
        fixture.requestExecutor.runFirst()
        fixture.requestExecutor.runFirst()
        fixture.channel.embeddedEventLoop.run()
        fixture.drainTerminalWork()

        let responses = try readResponses(from: fixture.channel)
        XCTAssertEqual(responses["subscribe-1"]?.error?.code, "superseded")
        XCTAssertEqual(responses["subscribe-2"]?.ok, true)
        XCTAssertEqual(eventLog.events, ["subscribe-1", "stop-1", "subscribe-2"])
        XCTAssertEqual(fixture.observability.snapshot(activeSessions: []).activeTerminalStreamSubscriptionCount, 1)
    }

    func testNewerUnsubscribeCompletingFirstFencesOlderSubscribeCandidate() throws {
        let eventLog = EventLog()
        let fixture = try makeFixture(outputStreamHandler: StubTerminalStreamHandler(eventLog: eventLog))
        defer { fixture.cleanup() }
        let panelID = ordinaryPanelID(windowID: "@16")

        try writeRequest(subscribeRequest(id: "subscribe-1", panelID: panelID), to: fixture.channel)
        try writeRequest(BridgeRequest(id: "unsubscribe-2",
                                       action: "unsubscribe_terminal_stream",
                                       params: ["panel_id": .string(panelID)]),
                         to: fixture.channel)
        fixture.requestExecutor.runLast()
        fixture.requestExecutor.runFirst()
        fixture.channel.embeddedEventLoop.run()
        fixture.drainTerminalWork()

        let responses = try readResponses(from: fixture.channel)
        XCTAssertEqual(responses["unsubscribe-2"]?.ok, true)
        XCTAssertEqual(responses["subscribe-1"]?.error?.code, "superseded")
        XCTAssertEqual(eventLog.events, ["subscribe-1", "stop-1"])
        XCTAssertEqual(fixture.observability.snapshot(activeSessions: []).activeTerminalStreamSubscriptionCount, 0)
    }

    func testOlderUnsubscribeCompletingAfterNewerSubscribeCannotStopIt() throws {
        let eventLog = EventLog()
        let fixture = try makeFixture(outputStreamHandler: StubTerminalStreamHandler(eventLog: eventLog))
        defer { fixture.cleanup() }
        let panelID = ordinaryPanelID(windowID: "@16")

        try writeRequest(BridgeRequest(id: "unsubscribe-1",
                                       action: "unsubscribe_terminal_stream",
                                       params: ["panel_id": .string(panelID)]),
                         to: fixture.channel)
        try writeRequest(subscribeRequest(id: "subscribe-2", panelID: panelID), to: fixture.channel)
        fixture.requestExecutor.runLast()
        fixture.requestExecutor.runFirst()
        fixture.channel.embeddedEventLoop.run()
        fixture.drainTerminalWork()

        let responses = try readResponses(from: fixture.channel)
        XCTAssertEqual(responses["subscribe-2"]?.ok, true)
        XCTAssertEqual(responses["unsubscribe-1"]?.error?.code, "superseded")
        XCTAssertEqual(eventLog.events, ["subscribe-1"])
        XCTAssertEqual(fixture.observability.snapshot(activeSessions: []).activeTerminalStreamSubscriptionCount, 1)
    }

    func testDisconnectBeforeSubscribeFinalizeRejectsAndReleasesLateCandidate() throws {
        let eventLog = EventLog()
        let fixture = try makeFixture(outputStreamHandler: StubTerminalStreamHandler(eventLog: eventLog))
        defer { fixture.cleanup() }
        let panelID = ordinaryPanelID(windowID: "@16")

        try writeRequest(subscribeRequest(id: "subscribe-1", panelID: panelID), to: fixture.channel)
        fixture.requestExecutor.runFirst()
        fixture.handler.channelInactive(context: fixture.context)
        fixture.channel.embeddedEventLoop.run()
        fixture.drainTerminalWork()

        XCTAssertEqual(eventLog.events, ["subscribe-1", "stop-1"])
        let snapshot = fixture.observability.snapshot(activeSessions: [])
        XCTAssertEqual(snapshot.activeTerminalStreamSubscriptionCount, 0)
        XCTAssertEqual(snapshot.connectionEvents.last?.kind, .disconnected)
        XCTAssertEqual(snapshot.connectionEvents.last?.terminalStreamSubscriptionCount, 0)
    }

    func testUnsubscribeAllReleasesEveryOwnedPanelThroughItsLane() throws {
        let eventLog = EventLog()
        let fixture = try makeFixture(outputStreamHandler: StubTerminalStreamHandler(eventLog: eventLog))
        defer { fixture.cleanup() }

        try writeRequest(subscribeRequest(id: "subscribe-1",
                                          panelID: ordinaryPanelID(windowID: "@16")),
                         to: fixture.channel)
        fixture.requestExecutor.runFirst()
        fixture.channel.embeddedEventLoop.run()
        try writeRequest(subscribeRequest(id: "subscribe-2",
                                          panelID: ordinaryPanelID(windowID: "@17")),
                         to: fixture.channel)
        fixture.requestExecutor.runFirst()
        fixture.channel.embeddedEventLoop.run()
        try writeRequest(BridgeRequest(id: "unsubscribe-all",
                                       action: "unsubscribe_terminal_stream",
                                       params: nil),
                         to: fixture.channel)
        fixture.requestExecutor.runFirst()
        fixture.channel.embeddedEventLoop.run()
        fixture.drainTerminalWork()

        let responses = try readResponses(from: fixture.channel)
        XCTAssertEqual(responses["unsubscribe-all"]?.ok, true)
        XCTAssertEqual(Set(eventLog.events), Set(["subscribe-1", "subscribe-2", "stop-1", "stop-2"]))
        XCTAssertEqual(fixture.observability.snapshot(activeSessions: []).activeTerminalStreamSubscriptionCount, 0)
    }

    private func subscribeRequest(id: String, panelID: String) -> BridgeRequest {
        BridgeRequest(id: id,
                      action: "subscribe_terminal_stream",
                      params: [
                        "workspace_id": .string("workspace-1"),
                        "panel_id": .string(panelID),
                      ])
    }

    private func writeRequest(_ request: BridgeRequest, to channel: EmbeddedChannel) throws {
        let payload = try JSONEncoder().encode(request)
        var buffer = channel.allocator.buffer(capacity: payload.count)
        buffer.writeBytes(payload)
        _ = try channel.writeInbound(WebSocketFrame(fin: true, opcode: .text, data: buffer))
    }

    private func readResponses(from channel: EmbeddedChannel) throws -> [String: BridgeResponse] {
        var responses = [String: BridgeResponse]()
        while let frame = try channel.readOutbound(as: WebSocketFrame.self) {
            var data = frame.unmaskedData
            guard let text = data.readString(length: data.readableBytes) else {
                continue
            }
            let response = try JSONDecoder().decode(BridgeResponse.self, from: Data(text.utf8))
            if let id = response.id {
                responses[id] = response
            }
        }
        return responses
    }

    private func decode<Value: Decodable>(_ frame: WebSocketFrame,
                                           as type: Value.Type) throws -> Value {
        var data = frame.unmaskedData
        let text = try XCTUnwrap(data.readString(length: data.readableBytes))
        return try JSONDecoder().decode(type, from: Data(text.utf8))
    }

    private struct Fixture {
        let handler: WebSocketFrameHandler
        let context: ChannelHandlerContext
        let channel: EmbeddedChannel
        let observability: BridgeObservabilityCenter
        let supportDirectory: URL
        let laneQueues: LaneQueueStore
        let terminalScheduler: ManualTerminalScheduler
        let requestExecutor: ManualRequestExecutor

        func drainTerminalWork() {
            laneQueues.drain()
            terminalScheduler.enqueuePendingOnEventLoops()
            channel.embeddedEventLoop.run()
            laneQueues.drain()
            terminalScheduler.enqueuePendingOnEventLoops()
            channel.embeddedEventLoop.run()
        }

        func cleanup() {
            _ = try? channel.finish()
            drainTerminalWork()
            try? FileManager.default.removeItem(at: supportDirectory)
        }
    }

    private func makeFixture(outputStreamHandler: OrdinaryTmuxOutputStreaming,
                             observability: BridgeObservabilityCenter = BridgeObservabilityCenter(),
                             requestSequencer: BridgeRequestSequencer = BridgeRequestSequencer(),
                             terminalStreamLaneRegistry: OrdinaryTmuxTerminalStreamLaneRegistry? = nil,
                             laneQueues: LaneQueueStore? = nil,
                             terminalScheduler: ManualTerminalScheduler? = nil,
                             requestExecutor: ManualRequestExecutor? = nil) throws -> Fixture {
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
        let laneQueues = laneQueues ?? LaneQueueStore()
        let terminalStreamLaneRegistry = terminalStreamLaneRegistry ?? OrdinaryTmuxTerminalStreamLaneRegistry(
            makeQueue: { panelID in
                laneQueues.makeQueue(panelID: panelID)
            }
        )
        let terminalScheduler = terminalScheduler ?? ManualTerminalScheduler()
        let requestExecutor = requestExecutor ?? ManualRequestExecutor()
        let handler = WebSocketFrameHandler(socketClient: TideySocketClient(locator: TideySocketLocator()),
                                            eventHub: eventHub,
                                            workspaceEventHub: WorkspaceEventHub(),
                                            registryMonitor: monitor,
                                            observability: observability,
                                            bridgePort: 0,
                                            cloudflaredManager: BridgeCloudflaredManager(binaryResolver: { nil }),
                                            requestExecutor: { work in requestExecutor.enqueue(work) },
                                            terminalStreamEventLoopScheduler: { eventLoop, work in
                                                terminalScheduler.schedule(eventLoop: eventLoop, work: work)
                                            },
                                            ordinaryTmuxOutputStreamHandler: outputStreamHandler,
                                            requestSequencer: requestSequencer,
                                            terminalStreamLaneRegistry: terminalStreamLaneRegistry)
        let channel = EmbeddedChannel(handler: handler)
        let context = try channel.pipeline.syncOperations.context(handler: handler)
        return Fixture(handler: handler,
                       context: context,
                       channel: channel,
                       observability: observability,
                       supportDirectory: supportDirectory,
                       laneQueues: laneQueues,
                       terminalScheduler: terminalScheduler,
                       requestExecutor: requestExecutor)
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
