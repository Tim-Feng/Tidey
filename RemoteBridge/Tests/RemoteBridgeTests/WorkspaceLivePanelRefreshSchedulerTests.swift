import XCTest
@testable import RemoteBridge

final class WorkspaceLivePanelRefreshSchedulerTests: XCTestCase {
    private final class BlockingSocketSender: TideyRequestSending, @unchecked Sendable {
        private let lock = NSLock()
        private let releaseSemaphore = DispatchSemaphore(value: 0)
        private let responseByWorkspaceID: [String: BridgeResponse]
        private var startedExpectation: XCTestExpectation?
        private(set) var requestedWorkspaceIDs = [String]()
        private(set) var maxConcurrentCalls = 0
        private var currentConcurrentCalls = 0

        init(responseByWorkspaceID: [String: BridgeResponse]) {
            self.responseByWorkspaceID = responseByWorkspaceID
        }

        func expectSendStarted(_ expectation: XCTestExpectation) {
            lock.lock()
            startedExpectation = expectation
            lock.unlock()
        }

        func releaseAll(count: Int = 1) {
            for _ in 0..<count {
                releaseSemaphore.signal()
            }
        }

        func send(_ request: BridgeRequest) throws -> BridgeResponse {
            let workspaceID = request.params?["workspace_id"]?.stringValue ?? ""
            lock.lock()
            requestedWorkspaceIDs.append(workspaceID)
            currentConcurrentCalls += 1
            maxConcurrentCalls = max(maxConcurrentCalls, currentConcurrentCalls)
            let expectation = startedExpectation
            startedExpectation = nil
            lock.unlock()

            expectation?.fulfill()
            _ = releaseSemaphore.wait(timeout: .now() + 2)

            lock.lock()
            currentConcurrentCalls -= 1
            lock.unlock()

            return responseByWorkspaceID[workspaceID]
                ?? BridgeResponse(id: request.id,
                                  ok: false,
                                  result: nil,
                                  error: BridgeErrorPayload(code: "not_found", message: "missing fixture"))
        }
    }

    private final class RecordingRegistry: LivePanelRegistryUpdating, @unchecked Sendable {
        private let lock = NSLock()
        private var replacementExpectation: XCTestExpectation?
        private(set) var prunedWorkspaceIDs: [Set<String>] = []
        private(set) var replacements: [(workspaceID: String, panels: [AgentPanelProcessSnapshot])] = []

        func expectReplacement(_ expectation: XCTestExpectation) {
            lock.lock()
            replacementExpectation = expectation
            lock.unlock()
        }

        func replaceLivePanels(workspaceID: String, panels: [AgentPanelProcessSnapshot]) {
            lock.lock()
            replacements.append((workspaceID, panels))
            let expectation = replacementExpectation
            lock.unlock()
            expectation?.fulfill()
        }

        func pruneLivePanels(toWorkspaceIDs workspaceIDs: Set<String>) {
            lock.lock()
            prunedWorkspaceIDs.append(workspaceIDs)
            lock.unlock()
        }
    }

    private struct PassThroughProjector: PanelListResultProjecting {
        func projectPanelListResult(_ result: [String: JSONValue]) -> [String: JSONValue] {
            result
        }
    }

    func testScheduleRefreshReturnsWithoutWaitingForPanelRefresh() {
        let sender = BlockingSocketSender(responseByWorkspaceID: [
            "workspace-1": Self.panelListResponse(workspaceID: "workspace-1", panelID: "panel-1"),
        ])
        let registry = RecordingRegistry()
        let scheduler = WorkspaceLivePanelRefreshScheduler(socketSender: sender,
                                                           registry: registry,
                                                           projector: PassThroughProjector())
        let sendStarted = expectation(description: "background panel refresh started")
        sender.expectSendStarted(sendStarted)

        let startedAt = Date()
        scheduler.scheduleRefresh(forListedWorkspaces: Self.workspaceListResult(["workspace-1"]))
        let elapsed = Date().timeIntervalSince(startedAt)

        XCTAssertLessThan(elapsed, 0.2)
        XCTAssertEqual(registry.prunedWorkspaceIDs, [Set(["workspace-1"])])

        wait(for: [sendStarted], timeout: 1)
        let replaced = expectation(description: "live panels replaced")
        registry.expectReplacement(replaced)
        sender.releaseAll()
        wait(for: [replaced], timeout: 1)
        XCTAssertEqual(sender.requestedWorkspaceIDs, ["workspace-1"])
        XCTAssertEqual(registry.replacements.first?.workspaceID, "workspace-1")
        XCTAssertEqual(registry.replacements.first?.panels.map(\.panelID), ["panel-1"])
    }

    func testConcurrentSchedulesAreProcessedByOneWorkerAtATime() {
        let sender = BlockingSocketSender(responseByWorkspaceID: [
            "workspace-1": Self.panelListResponse(workspaceID: "workspace-1", panelID: "panel-1"),
            "workspace-2": Self.panelListResponse(workspaceID: "workspace-2", panelID: "panel-2"),
        ])
        let registry = RecordingRegistry()
        let scheduler = WorkspaceLivePanelRefreshScheduler(socketSender: sender,
                                                           registry: registry,
                                                           projector: PassThroughProjector())
        let firstSendStarted = expectation(description: "first background refresh started")
        sender.expectSendStarted(firstSendStarted)

        scheduler.scheduleRefresh(forListedWorkspaces: Self.workspaceListResult(["workspace-1"]))
        wait(for: [firstSendStarted], timeout: 1)
        scheduler.scheduleRefresh(forListedWorkspaces: Self.workspaceListResult(["workspace-2"]))

        let replacements = expectation(description: "both workspaces refreshed")
        replacements.expectedFulfillmentCount = 2
        registry.expectReplacement(replacements)
        sender.releaseAll(count: 2)
        wait(for: [replacements], timeout: 2)

        XCTAssertEqual(sender.maxConcurrentCalls, 1)
        XCTAssertEqual(Set(sender.requestedWorkspaceIDs), Set(["workspace-1", "workspace-2"]))
        XCTAssertEqual(Set(registry.replacements.map(\.workspaceID)), Set(["workspace-1", "workspace-2"]))
    }

    private static func workspaceListResult(_ workspaceIDs: [String]) -> [String: JSONValue] {
        [
            "workspaces": .array(workspaceIDs.map { workspaceID in
                .object([
                    "workspace_id": .string(workspaceID),
                    "title": .string(workspaceID),
                ])
            }),
        ]
    }

    private static func panelListResponse(workspaceID: String, panelID: String) -> BridgeResponse {
        BridgeResponse(id: "response-\(workspaceID)",
                       ok: true,
                       result: [
                        "workspace_id": .string(workspaceID),
                        "panels": .array([
                            .object([
                                "workspace_id": .string(workspaceID),
                                "panel_id": .string(panelID),
                                "effective_shell_pid": .number(1234),
                                "cwd": .string("/Users/timfeng"),
                            ]),
                        ]),
                       ],
                       error: nil)
    }
}
