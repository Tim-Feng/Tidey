import Foundation
import XCTest

@testable import RemoteBridge

final class TmuxInteractivePTYSessionCandidateBuilderTests: XCTestCase {
    private final class Trace: @unchecked Sendable {
        private let lock = NSLock()
        private var values = [String]()

        func append(_ value: String) {
            lock.lock()
            values.append(value)
            lock.unlock()
        }

        var snapshot: [String] {
            lock.lock()
            defer { lock.unlock() }
            return values
        }
    }

    private struct RouteResolver: OrdinaryTmuxRouteResolving {
        let route: OrdinaryTmuxPanelRoute?
        let trace: Trace

        func route(
            forPanelID panelID: String,
            workspaceID: String?
        ) throws -> OrdinaryTmuxPanelRoute? {
            trace.append("resolve:\(workspaceID ?? "nil"):\(panelID)")
            return route
        }
    }

    private struct ControllerStub: TmuxInteractivePTYControlling {
        func spawn(
            _ command: TmuxInteractivePTYAttachCommand
        ) throws -> TmuxInteractivePTYHandle {
            TmuxInteractivePTYHandle(masterFileDescriptor: 17, childProcessID: 23)
        }

        func resize(masterFileDescriptor: Int32, to size: TmuxInteractivePTYSize) throws {}
        func close(masterFileDescriptor: Int32) throws {}

        func reap(
            childProcessID: Int32,
            blocking: Bool
        ) throws -> TmuxInteractivePTYChildExit? {
            TmuxInteractivePTYChildExit(rawStatus: 0)
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

    func testBuilderOrdersExactRouteMigrationBeforeSessionStartAndRejectsUnsafePolicy() throws {
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
        let subscribe = TmuxInteractiveSubscribe(
            workspaceID: route.workspaceID,
            panelID: route.panelID,
            binding: TmuxInteractiveSubscriptionBinding(
                subscriptionID: "interactive-1",
                generation: 9
            ),
            viewport: TmuxInteractiveViewport(columns: 80, rows: 24)
        )
        let trace = Trace()
        let migration = TmuxInteractiveWindowSizeMigration(
            windowID: route.windowID,
            expectedCurrentPolicy: "largest",
            restoredPolicy: "latest",
            markerOption: "@tidey_window_size_before_multi_client",
            expectedMarkerValue: "latest"
        )
        var capturedRequest: TmuxInteractivePTYSessionStartRequest?
        let builder = TmuxInteractivePTYSessionCandidateBuilder(
            routeResolver: RouteResolver(route: route, trace: trace),
            migrateWindow: { socket, windowID in
                trace.append("migrate:\(socket.cacheKey):\(windowID)")
                return .migrated(migration)
            },
            sessionFactory: { request in
                trace.append("start:\(request.route.windowID)")
                capturedRequest = request
                return self.makeIdleSession(binding: request.subscribe.binding)
            },
            tmuxExecutablePath: "/opt/homebrew/bin/tmux"
        )

        let candidate = try builder.build(subscribe)

        XCTAssertEqual(candidate.binding, subscribe.binding)
        XCTAssertEqual(capturedRequest?.subscribe, subscribe)
        XCTAssertEqual(capturedRequest?.route, route)
        XCTAssertEqual(capturedRequest?.tmuxExecutablePath, "/opt/homebrew/bin/tmux")
        XCTAssertEqual(
            trace.snapshot,
            [
                "resolve:workspace-1:\(route.panelID)",
                "migrate:\(route.socket.cacheKey):@2",
                "start:@2",
            ]
        )

        var unsafeFactoryCallCount = 0
        let unsafeReasons: [TmuxInteractiveWindowSizeMigrationNoOpReason] = [
            .currentPolicyNotOwned("manual"),
            .markerNotOwned(nil),
            .laterPolicyChangeEvidence,
        ]
        for reason in unsafeReasons {
            let unsafeBuilder = TmuxInteractivePTYSessionCandidateBuilder(
                routeResolver: RouteResolver(route: route, trace: Trace()),
                migrateWindow: { _, _ in .notEligible(reason) },
                sessionFactory: { request in
                    unsafeFactoryCallCount += 1
                    return self.makeIdleSession(binding: request.subscribe.binding)
                },
                tmuxExecutablePath: "/opt/homebrew/bin/tmux"
            )
            XCTAssertThrowsError(try unsafeBuilder.build(subscribe)) { error in
                XCTAssertEqual(
                    error as? TmuxInteractivePTYSessionCandidateBuilderError,
                    .unsafeWindowSizePolicy(reason)
                )
            }
        }
        XCTAssertEqual(unsafeFactoryCallCount, 0)

        var latestFactoryCallCount = 0
        let latestBuilder = TmuxInteractivePTYSessionCandidateBuilder(
            routeResolver: RouteResolver(route: route, trace: Trace()),
            migrateWindow: { _, _ in
                .notEligible(.currentPolicyNotOwned("latest"))
            },
            sessionFactory: { request in
                latestFactoryCallCount += 1
                return self.makeIdleSession(binding: request.subscribe.binding)
            },
            tmuxExecutablePath: "/opt/homebrew/bin/tmux"
        )
        XCTAssertEqual(try latestBuilder.build(subscribe).binding, subscribe.binding)
        XCTAssertEqual(latestFactoryCallCount, 1)
    }

    private func makeIdleSession(
        binding: TmuxInteractiveSubscriptionBinding
    ) -> TmuxInteractivePTYConnectionSession {
        TmuxInteractivePTYConnectionSession(
            binding: binding,
            owner: TmuxInteractivePTYSessionOwner(
                admissionStore: OrdinaryTmuxInputSubmissionStore(),
                controller: ControllerStub()
            )
        )
    }
}
