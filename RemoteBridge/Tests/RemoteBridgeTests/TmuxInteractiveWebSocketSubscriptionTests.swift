import Foundation
import NIOCore
import NIOEmbedded
import NIOWebSocket
import XCTest

@testable import RemoteBridge

final class TmuxInteractiveWebSocketSubscriptionTests: XCTestCase {
    private final class ControllerProbe:
        TmuxInteractivePTYControlling,
        @unchecked Sendable
    {
        private let lock = NSLock()
        private var readResults: [TmuxInteractivePTYReadResult]
        private(set) var closeCount = 0
        private(set) var reapCount = 0

        init(readResults: [TmuxInteractivePTYReadResult]) {
            self.readResults = readResults
        }

        func spawn(
            _ command: TmuxInteractivePTYAttachCommand
        ) throws -> TmuxInteractivePTYHandle {
            TmuxInteractivePTYHandle(masterFileDescriptor: 17, childProcessID: 23)
        }

        func resize(
            masterFileDescriptor: Int32,
            to size: TmuxInteractivePTYSize
        ) throws {}

        func close(masterFileDescriptor: Int32) throws {
            lock.lock()
            closeCount += 1
            lock.unlock()
        }

        func reap(
            childProcessID: Int32,
            blocking: Bool
        ) throws -> TmuxInteractivePTYChildExit? {
            lock.lock()
            reapCount += 1
            lock.unlock()
            return TmuxInteractivePTYChildExit(rawStatus: 0)
        }

        func read(
            masterFileDescriptor: Int32,
            maximumBytes: Int
        ) throws -> TmuxInteractivePTYReadResult {
            lock.lock()
            defer { lock.unlock() }
            guard readResults.isEmpty == false else {
                return .wouldBlock
            }
            return readResults.removeFirst()
        }

        func write(
            _ bytes: Data,
            masterFileDescriptor: Int32
        ) throws -> TmuxInteractivePTYWriteResult {
            .written(bytes.count)
        }
    }

    private struct ProverStub: TmuxInteractiveAttachProving {
        let verifiedAttach: TmuxInteractiveVerifiedAttach

        func prove(
            _ claim: TmuxInteractiveAttachClaim
        ) throws -> TmuxInteractiveVerifiedAttach? {
            verifiedAttach
        }
    }

    private struct RouteResolverStub: OrdinaryTmuxRouteResolving {
        let route: OrdinaryTmuxPanelRoute

        func route(
            forPanelID panelID: String,
            workspaceID: String?
        ) throws -> OrdinaryTmuxPanelRoute? {
            guard panelID == route.panelID,
                  workspaceID == route.workspaceID else {
                return nil
            }
            return route
        }
    }

    private struct Fixture {
        let handler: WebSocketFrameHandler
        let channel: EmbeddedChannel
        let supportDirectory: URL

        func cleanup() {
            _ = try? channel.finish()
            try? FileManager.default.removeItem(at: supportDirectory)
        }
    }

    func testSubscribeCommitsOwnershipBeforePumpingStartOutputAndDetach() throws {
        let route = makeRoute()
        let binding = TmuxInteractiveSubscriptionBinding(
            subscriptionID: "interactive-1",
            generation: 9
        )
        let viewport = TmuxInteractiveViewport(columns: 80, rows: 24)
        let startBytes = Data([0x1b, 0x5b, 0x48])
        let outputBytes = Data([0x6f, 0x75, 0x74])
        let store = OrdinaryTmuxInputSubmissionStore()
        let controller = ControllerProbe(
            readResults: [
                .wouldBlock,
                .bytes(startBytes),
                .wouldBlock,
                .wouldBlock,
                .bytes(outputBytes),
                .endOfFile,
            ]
        )
        let verifiedAttach = TmuxInteractiveVerifiedAttach(
            attachProof: TmuxInteractiveAttachProof(
                workspaceID: route.workspaceID,
                panelID: route.panelID,
                sessionID: route.sessionID,
                windowID: route.windowID,
                paneID: route.activePaneID
            ),
            childProcessID: 23,
            clientTTY: "/dev/ttys001"
        )
        let owner = TmuxInteractivePTYSessionOwner(
            admissionStore: store,
            controller: controller,
            attachProver: ProverStub(verifiedAttach: verifiedAttach)
        )
        let subscribe = TmuxInteractiveSubscribe(
            workspaceID: route.workspaceID,
            panelID: route.panelID,
            binding: binding,
            viewport: viewport
        )
        try owner.begin(
            TmuxInteractivePTYSessionStartRequest(
                subscribe: subscribe,
                route: route,
                tmuxExecutablePath: "/opt/homebrew/bin/tmux"
            )
        )
        let session = TmuxInteractivePTYConnectionSession(
            binding: binding,
            owner: owner
        )
        let candidateBuilder = TmuxInteractivePTYSessionCandidateBuilder(
            routeResolver: RouteResolverStub(route: route),
            migrateWindow: { _, _ in
                .notEligible(.currentPolicyNotOwned("latest"))
            },
            sessionFactory: { _ in session },
            tmuxExecutablePath: "/opt/homebrew/bin/tmux"
        )
        let fixture = try makeFixture(candidateBuilder: candidateBuilder)
        defer { fixture.cleanup() }
        let handler = fixture.handler
        let channel = fixture.channel
        let context = try channel.pipeline.syncOperations.context(
            handler: handler
        )
        let endpointResult = try XCTUnwrap(
            handler.handleLocalRequest(
                BridgeRequest(
                    id: "endpoints-before-capability",
                    action: "get_connection_endpoints",
                    params: nil
                ),
                context: context
            )
        )
        XCTAssertFalse(
            endpointResult.response.result?["capabilities"]?
                .arrayValue?
                .contains(.string(BridgeProtocolCapability.tmuxInteractive))
                ?? true
        )

        try writeRequest(
            BridgeRequest(
                id: "subscribe-1",
                action: TmuxInteractiveProtocolV1.subscribeAction,
                params: [
                    "workspace_id": .string(route.workspaceID),
                    "panel_id": .string(route.panelID),
                    "subscription_id": .string(binding.subscriptionID),
                    "generation": .number(Double(binding.generation)),
                    "cols": .number(Double(viewport.columns)),
                    "rows": .number(Double(viewport.rows)),
                ]
            ),
            to: channel
        )
        channel.embeddedEventLoop.run()

        let responseFrame = try XCTUnwrap(
            channel.readOutbound(as: WebSocketFrame.self)
        )
        let response = try decode(responseFrame, as: BridgeResponse.self)
        XCTAssertEqual(response.id, "subscribe-1")
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.result?["subscribed"]?.boolValue, true)
        XCTAssertEqual(
            response.result?["subscription_id"]?.stringValue,
            binding.subscriptionID
        )
        XCTAssertEqual(
            response.result?["generation"]?.intValue,
            Int(binding.generation)
        )
        XCTAssertNil(try channel.readOutbound(as: WebSocketFrame.self))

        channel.embeddedEventLoop.advanceTime(by: .milliseconds(10))
        channel.embeddedEventLoop.run()
        XCTAssertNil(try channel.readOutbound(as: WebSocketFrame.self))

        channel.embeddedEventLoop.advanceTime(by: .milliseconds(10))
        channel.embeddedEventLoop.run()

        let start = try decode(
            XCTUnwrap(channel.readOutbound(as: WebSocketFrame.self)),
            as: TmuxInteractiveAuthoritativeStartEnvelope.self
        )
        XCTAssertEqual(start.type, TmuxInteractiveProtocolV1.startEventType)
        XCTAssertEqual(start.subscriptionID, binding.subscriptionID)
        XCTAssertEqual(start.generation, binding.generation)
        XCTAssertEqual(start.workspaceID, route.workspaceID)
        XCTAssertEqual(start.panelID, route.panelID)
        XCTAssertEqual(start.sessionID, route.sessionID)
        XCTAssertEqual(start.windowID, route.windowID)
        XCTAssertEqual(start.paneID, route.activePaneID)
        XCTAssertEqual(start.columns, viewport.columns)
        XCTAssertEqual(start.rows, viewport.rows)
        XCTAssertEqual(Data(base64Encoded: start.dataBase64), startBytes)

        let output = try decode(
            XCTUnwrap(channel.readOutbound(as: WebSocketFrame.self)),
            as: TmuxInteractiveOutputEnvelope.self
        )
        XCTAssertEqual(output.type, TmuxInteractiveProtocolV1.outputEventType)
        XCTAssertEqual(output.subscriptionID, binding.subscriptionID)
        XCTAssertEqual(output.generation, binding.generation)
        XCTAssertEqual(output.sequence, 1)
        XCTAssertEqual(Data(base64Encoded: output.dataBase64), outputBytes)

        let state = try decode(
            XCTUnwrap(channel.readOutbound(as: WebSocketFrame.self)),
            as: TmuxInteractiveStateEnvelope.self
        )
        XCTAssertEqual(state.type, TmuxInteractiveProtocolV1.stateEventType)
        XCTAssertEqual(state.subscriptionID, binding.subscriptionID)
        XCTAssertEqual(state.generation, binding.generation)
        XCTAssertEqual(state.state, TmuxInteractiveTerminalState.detached.rawValue)
        XCTAssertNil(state.message)
        XCTAssertNil(try channel.readOutbound(as: WebSocketFrame.self))

        XCTAssertEqual(owner.lifecycleState, .closed)
        XCTAssertEqual(controller.closeCount, 1)
        XCTAssertEqual(controller.reapCount, 1)
        let sessionKey = OrdinaryTmuxSessionKey(
            socket: route.socket,
            sessionID: route.sessionID
        )
        let afterDetachToken = OrdinaryTmuxInteractiveLeaseToken(
            rawValue: "after-detach"
        )
        XCTAssertTrue(
            store.acquireInteractiveLease(
                token: afterDetachToken,
                sessionKey: sessionKey
            )
        )
        store.releaseInteractiveLease(
            token: afterDetachToken,
            sessionKey: sessionKey
        )
    }

    func testDuplicateSubscribeCommitClosesRejectedCandidateWithoutReplacement() throws {
        let route = makeRoute()
        let existingBinding = TmuxInteractiveSubscriptionBinding(
            subscriptionID: "interactive-1",
            generation: 8
        )
        let candidateBinding = TmuxInteractiveSubscriptionBinding(
            subscriptionID: existingBinding.subscriptionID,
            generation: 9
        )
        let viewport = TmuxInteractiveViewport(columns: 80, rows: 24)
        let candidateStore = OrdinaryTmuxInputSubmissionStore()
        let candidateController = ControllerProbe(readResults: [])
        let candidateOwner = TmuxInteractivePTYSessionOwner(
            admissionStore: candidateStore,
            controller: candidateController
        )
        let candidateSubscribe = TmuxInteractiveSubscribe(
            workspaceID: route.workspaceID,
            panelID: route.panelID,
            binding: candidateBinding,
            viewport: viewport
        )
        try candidateOwner.begin(
            TmuxInteractivePTYSessionStartRequest(
                subscribe: candidateSubscribe,
                route: route,
                tmuxExecutablePath: "/opt/homebrew/bin/tmux"
            )
        )
        let candidateSession = TmuxInteractivePTYConnectionSession(
            binding: candidateBinding,
            owner: candidateOwner
        )
        let candidateBuilder = TmuxInteractivePTYSessionCandidateBuilder(
            routeResolver: RouteResolverStub(route: route),
            migrateWindow: { _, _ in
                .notEligible(.currentPolicyNotOwned("latest"))
            },
            sessionFactory: { _ in candidateSession },
            tmuxExecutablePath: "/opt/homebrew/bin/tmux"
        )
        let fixture = try makeFixture(candidateBuilder: candidateBuilder)
        defer { fixture.cleanup() }
        let handler = fixture.handler
        let channel = fixture.channel
        let existingOwner = TmuxInteractivePTYSessionOwner(
            admissionStore: OrdinaryTmuxInputSubmissionStore(),
            controller: ControllerProbe(readResults: [])
        )
        XCTAssertTrue(
            handler.installInteractivePTYOwner(
                binding: existingBinding,
                owner: existingOwner
            )
        )

        try writeRequest(
            BridgeRequest(
                id: "subscribe-duplicate",
                action: TmuxInteractiveProtocolV1.subscribeAction,
                params: [
                    "workspace_id": .string(route.workspaceID),
                    "panel_id": .string(route.panelID),
                    "subscription_id": .string(candidateBinding.subscriptionID),
                    "generation": .number(Double(candidateBinding.generation)),
                    "cols": .number(Double(viewport.columns)),
                    "rows": .number(Double(viewport.rows)),
                ]
            ),
            to: channel
        )
        channel.embeddedEventLoop.run()

        let response = try decode(
            XCTUnwrap(channel.readOutbound(as: WebSocketFrame.self)),
            as: BridgeResponse.self
        )
        XCTAssertEqual(response.id, "subscribe-duplicate")
        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error?.code, "superseded")
        XCTAssertEqual(candidateOwner.lifecycleState, .closed)
        XCTAssertEqual(candidateController.closeCount, 1)
        XCTAssertEqual(candidateController.reapCount, 1)
        XCTAssertEqual(existingOwner.lifecycleState, .idle)
        XCTAssertNil(try channel.readOutbound(as: WebSocketFrame.self))

        let candidateSessionKey = OrdinaryTmuxSessionKey(
            socket: route.socket,
            sessionID: route.sessionID
        )
        let afterRejectionToken = OrdinaryTmuxInteractiveLeaseToken(
            rawValue: "after-rejection"
        )
        XCTAssertTrue(
            candidateStore.acquireInteractiveLease(
                token: afterRejectionToken,
                sessionKey: candidateSessionKey
            )
        )
        candidateStore.releaseInteractiveLease(
            token: afterRejectionToken,
            sessionKey: candidateSessionKey
        )
    }

    private func writeRequest(
        _ request: BridgeRequest,
        to channel: EmbeddedChannel
    ) throws {
        let payload = try JSONEncoder().encode(request)
        var buffer = channel.allocator.buffer(capacity: payload.count)
        buffer.writeBytes(payload)
        _ = try channel.writeInbound(
            WebSocketFrame(fin: true, opcode: .text, data: buffer)
        )
    }

    private func makeFixture(
        candidateBuilder: TmuxInteractivePTYSessionCandidateBuilder
    ) throws -> Fixture {
        let supportDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "TmuxInteractiveWebSocketSubscriptionTests-\(UUID().uuidString)",
                isDirectory: true
            )
        let paths = BridgePaths(supportDirectory: supportDirectory)
        try paths.ensureSupportDirectoriesExist(fileManager: .default)
        let eventHub = AgentEventHub()
        let monitor = AgentSessionRegistryMonitor(
            paths: paths,
            fileManager: .default,
            hub: eventHub,
            tmuxResolver: TmuxStateResolver(ttl: 60) { _, _ in "" },
            parentPIDLookup: { _ in nil }
        )
        let handler = WebSocketFrameHandler(
            socketClient: TideySocketClient(locator: TideySocketLocator()),
            eventHub: eventHub,
            workspaceEventHub: WorkspaceEventHub(),
            registryMonitor: monitor,
            observability: BridgeObservabilityCenter(),
            bridgePort: 0,
            cloudflaredManager: BridgeCloudflaredManager(binaryResolver: { nil }),
            requestExecutor: { work in work() },
            interactivePTYRoutingEnabled: true,
            interactivePTYSessionCandidateBuilder: candidateBuilder
        )
        return Fixture(
            handler: handler,
            channel: EmbeddedChannel(handler: handler),
            supportDirectory: supportDirectory
        )
    }

    private func makeRoute() -> OrdinaryTmuxPanelRoute {
        OrdinaryTmuxPanelRoute(
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
    }

    private func decode<Value: Decodable>(
        _ frame: WebSocketFrame,
        as type: Value.Type
    ) throws -> Value {
        var data = frame.unmaskedData
        let text = try XCTUnwrap(data.readString(length: data.readableBytes))
        return try JSONDecoder().decode(type, from: Data(text.utf8))
    }
}
