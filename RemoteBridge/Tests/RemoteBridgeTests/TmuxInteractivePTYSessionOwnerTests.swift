import Foundation
import XCTest

@testable import RemoteBridge

final class TmuxInteractivePTYSessionOwnerTests: XCTestCase {
    private final class ControllerProbe: TmuxInteractivePTYControlling, @unchecked Sendable {
        private(set) var spawnCommands = [TmuxInteractivePTYAttachCommand]()
        private(set) var closedFileDescriptors = [Int32]()
        private(set) var reapCalls = [(processID: Int32, blocking: Bool)]()
        var spawnError: Error?
        var onSpawn: (() -> Void)?
        var reapResult: TmuxInteractivePTYChildExit? = TmuxInteractivePTYChildExit(
            rawStatus: 0
        )

        func spawn(_ command: TmuxInteractivePTYAttachCommand) throws -> TmuxInteractivePTYHandle {
            spawnCommands.append(command)
            onSpawn?()
            if let spawnError {
                throw spawnError
            }
            return TmuxInteractivePTYHandle(masterFileDescriptor: 17, childProcessID: 23)
        }

        func resize(masterFileDescriptor: Int32, to size: TmuxInteractivePTYSize) throws {}

        func close(masterFileDescriptor: Int32) throws {
            closedFileDescriptors.append(masterFileDescriptor)
        }

        func reap(
            childProcessID: Int32,
            blocking: Bool
        ) throws -> TmuxInteractivePTYChildExit? {
            reapCalls.append((childProcessID, blocking))
            return reapResult
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

    func testOwnerAcquiresLeaseBeforeSpawnAndReleasesOnlyAfterCloseAndReap() throws {
        let store = OrdinaryTmuxInputSubmissionStore()
        let route = makeRoute()
        let sessionKey = OrdinaryTmuxSessionKey(
            socket: route.socket,
            sessionID: route.sessionID
        )
        let request = makeRequest(route: route)
        let controller = ControllerProbe()
        let owner = TmuxInteractivePTYSessionOwner(
            admissionStore: store,
            controller: controller
        )

        XCTAssertTrue(
            store.reserve(
                submissionID: "chat-owner",
                routeKey: "chat-route",
                sessionKey: sessionKey
            )
        )
        XCTAssertThrowsError(try owner.begin(request)) { error in
            XCTAssertEqual(error as? TmuxInteractivePTYSessionOwnerError, .admissionConflict)
        }
        XCTAssertTrue(controller.spawnCommands.isEmpty)
        store.release(submissionID: "chat-owner", routeKey: "chat-route")

        controller.onSpawn = {
            XCTAssertFalse(
                store.reserve(
                    submissionID: "racing-chat",
                    routeKey: "racing-route",
                    sessionKey: sessionKey
                )
            )
        }
        try owner.begin(request)
        XCTAssertEqual(owner.lifecycleState, .proving)
        XCTAssertEqual(
            controller.spawnCommands,
            [
                TmuxInteractivePTYAttachCommand(
                    tmuxExecutablePath: "/opt/homebrew/bin/tmux",
                    socket: route.socket,
                    sessionID: route.sessionID,
                    windowID: route.windowID,
                    initialSize: TmuxInteractivePTYSize(columns: 80, rows: 24)
                ),
            ]
        )
        XCTAssertFalse(
            store.reserve(
                submissionID: "blocked-chat",
                routeKey: "blocked-route",
                sessionKey: sessionKey
            )
        )

        try owner.close()
        XCTAssertEqual(owner.lifecycleState, .closed)
        XCTAssertEqual(controller.closedFileDescriptors, [17])
        XCTAssertEqual(controller.reapCalls.count, 1)
        XCTAssertEqual(controller.reapCalls.first?.processID, 23)
        XCTAssertEqual(controller.reapCalls.first?.blocking, true)
        XCTAssertTrue(
            store.reserve(
                submissionID: "after-close",
                routeKey: "after-close-route",
                sessionKey: sessionKey
            )
        )
        store.release(submissionID: "after-close", routeKey: "after-close-route")

        let failingController = ControllerProbe()
        failingController.spawnError = TmuxInteractivePTYControllerError.operationFailed(
            operation: "spawn",
            code: EIO
        )
        let failingOwner = TmuxInteractivePTYSessionOwner(
            admissionStore: store,
            controller: failingController
        )
        XCTAssertThrowsError(try failingOwner.begin(request))
        XCTAssertEqual(failingOwner.lifecycleState, .idle)
        XCTAssertTrue(
            store.reserve(
                submissionID: "after-spawn-failure",
                routeKey: "after-spawn-failure-route",
                sessionKey: sessionKey
            )
        )
    }

    func testOwnerRetainsLeaseUntilCleanupCanReapChild() throws {
        let store = OrdinaryTmuxInputSubmissionStore()
        let route = makeRoute()
        let sessionKey = OrdinaryTmuxSessionKey(
            socket: route.socket,
            sessionID: route.sessionID
        )
        let controller = ControllerProbe()
        controller.reapResult = nil
        let owner = TmuxInteractivePTYSessionOwner(
            admissionStore: store,
            controller: controller
        )
        try owner.begin(makeRequest(route: route))

        XCTAssertThrowsError(try owner.close()) { error in
            XCTAssertEqual(
                error as? TmuxInteractivePTYSessionOwnerError,
                .childDidNotExit
            )
        }
        XCTAssertEqual(owner.lifecycleState, .closing)
        XCTAssertEqual(controller.closedFileDescriptors, [17])
        XCTAssertFalse(
            store.reserve(
                submissionID: "cleanup-still-owned",
                routeKey: "cleanup-still-owned-route",
                sessionKey: sessionKey
            )
        )

        controller.reapResult = TmuxInteractivePTYChildExit(rawStatus: 0)
        try owner.close()
        XCTAssertEqual(owner.lifecycleState, .closed)
        XCTAssertEqual(controller.closedFileDescriptors, [17])
        XCTAssertEqual(controller.reapCalls.count, 2)
        XCTAssertTrue(
            store.reserve(
                submissionID: "cleanup-complete",
                routeKey: "cleanup-complete-route",
                sessionKey: sessionKey
            )
        )
    }

    func testOwnerRejectsUnresolvedTargetBeforeAdmissionOrSpawn() throws {
        let store = OrdinaryTmuxInputSubmissionStore()
        let route = makeRoute()
        let controller = ControllerProbe()
        let owner = TmuxInteractivePTYSessionOwner(
            admissionStore: store,
            controller: controller
        )
        let validRequest = makeRequest(route: route)
        let invalidRequest = TmuxInteractivePTYSessionStartRequest(
            subscribe: TmuxInteractiveSubscribe(
                workspaceID: "different-workspace",
                panelID: validRequest.subscribe.panelID,
                binding: validRequest.subscribe.binding,
                viewport: validRequest.subscribe.viewport
            ),
            route: route,
            tmuxExecutablePath: validRequest.tmuxExecutablePath
        )

        XCTAssertThrowsError(try owner.begin(invalidRequest)) { error in
            XCTAssertEqual(error as? TmuxInteractivePTYSessionOwnerError, .invalidRequest)
        }
        XCTAssertEqual(owner.lifecycleState, .idle)
        XCTAssertTrue(controller.spawnCommands.isEmpty)
        let sessionKey = OrdinaryTmuxSessionKey(
            socket: route.socket,
            sessionID: route.sessionID
        )
        let token = OrdinaryTmuxInteractiveLeaseToken(rawValue: "validation-check")
        XCTAssertTrue(store.acquireInteractiveLease(token: token, sessionKey: sessionKey))
        store.releaseInteractiveLease(token: token, sessionKey: sessionKey)
    }

    private func makeRequest(
        route: OrdinaryTmuxPanelRoute
    ) -> TmuxInteractivePTYSessionStartRequest {
        TmuxInteractivePTYSessionStartRequest(
            subscribe: TmuxInteractiveSubscribe(
                workspaceID: route.workspaceID,
                panelID: route.panelID,
                binding: TmuxInteractiveSubscriptionBinding(
                    subscriptionID: "interactive-1",
                    generation: 9
                ),
                viewport: TmuxInteractiveViewport(columns: 80, rows: 24)
            ),
            route: route,
            tmuxExecutablePath: "/opt/homebrew/bin/tmux"
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
}
