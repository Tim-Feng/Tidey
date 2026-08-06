import Foundation
import XCTest
@testable import RemoteBridge

final class OrdinaryTmuxTerminalObserverRegistryTests: XCTestCase {
    private final class StubLease: OrdinaryTmuxTerminalObserverLeasing, @unchecked Sendable {
        func stop() {}
    }

    private struct StubObserver: OrdinaryTmuxTerminalObserving {
        func observe(
            _ request: OrdinaryTmuxTerminalObservationRequest
        ) throws -> OrdinaryTmuxTerminalObserverLeasing {
            XCTAssertEqual(request.route.activePaneID, "%21")
            XCTAssertEqual(request.subscriptionID, "strict-1")
            XCTAssertEqual(request.expectedFingerprint.columns, 132)
            return StubLease()
        }
    }

    func testObserverContractCompiles() throws {
        let route = OrdinaryTmuxPanelRoute(
            workspaceID: "workspace-1",
            panelID: "ordinary-tmux:runtime-default:$1:@2",
            carrierPanelID: "carrier-1",
            socket: .defaultSocket,
            sessionID: "$1",
            sessionName: "work",
            windowID: "@2",
            windowIndex: 2,
            activePaneID: "%21",
            cwd: nil,
            currentCommand: nil
        )
        let fingerprint = OrdinaryTmuxTerminalFingerprintV1(
            paneID: "%21",
            columns: 132,
            rows: 40,
            alternateOn: false
        )
        let request = OrdinaryTmuxTerminalObservationRequest(
            route: route,
            subscriptionID: "strict-1",
            expectedFingerprint: fingerprint,
            onRebootstrapRequired: { _ in }
        )

        let lease = try StubObserver().observe(request)
        lease.stop()
    }
}
