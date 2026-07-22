import NIOEmbedded
import XCTest
@testable import RemoteBridge

final class BridgeWorkspaceEventSubscriptionTests: XCTestCase {
    func testSubscribeReportsTheWorkspaceReplayCountItActuallyReturns() throws {
        let supportDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BridgeWorkspaceSubscription-\(UUID().uuidString)", isDirectory: true)
        let paths = BridgePaths(supportDirectory: supportDirectory)
        try paths.ensureSupportDirectoriesExist(fileManager: .default)
        defer { try? FileManager.default.removeItem(at: supportDirectory) }

        let workspaceHub = WorkspaceEventHub()
        workspaceHub.publish(statePatch(id: "workspace-1-patch",
                                        seq: 1,
                                        workspaceID: "workspace-1",
                                        panelID: "panel-1"))
        workspaceHub.publish(statePatch(id: "workspace-2-patch",
                                        seq: 2,
                                        workspaceID: "workspace-2",
                                        panelID: "panel-2"))

        let eventHub = AgentEventHub()
        let monitor = AgentSessionRegistryMonitor(paths: paths,
                                                  fileManager: .default,
                                                  hub: eventHub,
                                                  tmuxResolver: TmuxStateResolver(ttl: 60) { _, _ in "" },
                                                  parentPIDLookup: { _ in nil })
        let handler = WebSocketFrameHandler(socketClient: TideySocketClient(locator: TideySocketLocator()),
                                            eventHub: eventHub,
                                            workspaceEventHub: workspaceHub,
                                            registryMonitor: monitor,
                                            observability: BridgeObservabilityCenter(),
                                            bridgePort: 0,
                                            cloudflaredManager: BridgeCloudflaredManager(binaryResolver: { nil }))
        let channel = EmbeddedChannel(handler: handler)
        defer { _ = try? channel.finish() }
        let context = try channel.pipeline.syncOperations.context(handler: handler)

        let result = try XCTUnwrap(handler.handleLocalRequest(
            BridgeRequest(id: "subscribe-1",
                          action: "subscribe_workspace_events",
                          params: ["workspace_id": .string("workspace-1")]),
            context: context))

        XCTAssertEqual(result.workspaceReplayEnvelopes.map(\.event.eventID), ["workspace-1-patch"])
        XCTAssertEqual(result.response.result?["replay_count"]?.intValue,
                       result.workspaceReplayEnvelopes.count)
    }

    private func statePatch(id: String,
                            seq: Int,
                            workspaceID: String,
                            panelID: String) -> WorkspaceEvent {
        WorkspaceEvent(eventID: id,
                       seq: seq,
                       timestamp: "2026-07-22T12:00:00.000Z",
                       kind: .panelStateChanged,
                       windowGUID: nil,
                       workspaceID: workspaceID,
                       panelID: panelID,
                       workspace: nil,
                       panel: [
                        "state": .string("working"),
                        "state_revision": .number(Double(seq)),
                       ])
    }
}
