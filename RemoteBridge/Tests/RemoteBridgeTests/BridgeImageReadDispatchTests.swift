import NIOEmbedded
import XCTest
@testable import RemoteBridge

final class BridgeImageReadDispatchTests: XCTestCase {
    func testImageReadIsHandledLocallyAndNeverForwardedToTideySocket() throws {
        let handler = Self.makeHandler()
        let channel = EmbeddedChannel(handler: handler)
        defer { _ = try? channel.finish() }
        let context = try channel.pipeline.syncOperations.context(handler: handler)

        let request = BridgeRequest(id: "image-read-1",
                                    action: "image_read",
                                    params: [
                                        "workspace_id": .string("workspace-1"),
                                        "panel_id": .string("panel-1"),
                                        "path": .string("/tmp/example.png"),
                                    ])
        // A local result (even an error one: no live Tidey socket in this
        // test) proves the action never falls through to socket forwarding.
        let result = try XCTUnwrap(handler.handleLocalRequest(request, context: context))
        XCTAssertEqual(result.response.id, "image-read-1")
        XCTAssertFalse(result.response.ok)
        XCTAssertNotNil(result.response.error)
    }

    func testConnectionEndpointsAdvertiseImageReadCapability() throws {
        let handler = Self.makeHandler()
        let channel = EmbeddedChannel(handler: handler)
        defer { _ = try? channel.finish() }
        let context = try channel.pipeline.syncOperations.context(handler: handler)

        let request = BridgeRequest(id: "endpoints-1",
                                    action: "get_connection_endpoints",
                                    params: nil)
        let result = try XCTUnwrap(handler.handleLocalRequest(request, context: context))

        XCTAssertTrue(result.response.ok)
        let capabilities = try XCTUnwrap(result.response.result?["capabilities"]?.arrayValue)
        XCTAssertTrue(capabilities.compactMap(\.stringValue).contains("image_read_v1"))
    }

    private static func makeHandler() -> WebSocketFrameHandler {
        WebSocketFrameHandler(socketClient: TideySocketClient(locator: TideySocketLocator()),
                              eventHub: AgentEventHub(),
                              workspaceEventHub: WorkspaceEventHub(),
                              registryMonitor: AgentSessionRegistryMonitor(paths: BridgePaths(supportDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)),
                                                                           fileManager: .default,
                                                                           hub: AgentEventHub(),
                                                                           tmuxResolver: TmuxStateResolver(ttl: 60) { _, _ in "" },
                                                                           parentPIDLookup: { _ in nil }),
                              observability: BridgeObservabilityCenter(),
                              bridgePort: 0,
                              cloudflaredManager: BridgeCloudflaredManager(binaryResolver: { nil }),
                              ordinaryTmuxProjectionContext: OrdinaryTmuxProjectionContext())
    }
}
