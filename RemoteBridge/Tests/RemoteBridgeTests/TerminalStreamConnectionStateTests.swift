import Foundation
import XCTest
@testable import RemoteBridge

final class TerminalStreamConnectionStateTests: XCTestCase {
    private final class StubSubscription: OrdinaryTmuxTerminalStreamSubscribing, @unchecked Sendable {
        let route: OrdinaryTmuxPanelRoute

        init(panelID: String) {
            route = OrdinaryTmuxPanelRoute(workspaceID: "workspace-1",
                                           panelID: panelID,
                                           carrierPanelID: "carrier-panel",
                                           socket: .path("/tmp/tmux-501/default"),
                                           sessionID: "$7",
                                           sessionName: "tidey-codex",
                                           windowID: "@16",
                                           windowIndex: 1,
                                           activePaneID: "%16",
                                           cwd: "/Users/timfeng/GitHub/Tidey",
                                           currentCommand: "codex")
        }

        @discardableResult
        func stop() -> Bool { true }
    }

    func testCommitSubscribeAcceptsNewestLeaseAndRejectsOlderLease() {
        var state = TerminalStreamConnectionState()
        let current = lease(panelID: "panel-1", token: 5)
        let stale = lease(panelID: "panel-1", token: 4)

        switch state.commitSubscribe(sequence: 5,
                                     panelID: "panel-1",
                                     lease: current,
                                     onInvalidated: {}) {
        case .accepted(let displacedLease):
            XCTAssertNil(displacedLease)
        case .rejected:
            XCTFail("Newest lease should be accepted")
        }
        XCTAssertTrue(current.deliveryGate.allowsDelivery)
        XCTAssertEqual(state.count, 1)

        switch state.commitSubscribe(sequence: 4,
                                     panelID: "panel-1",
                                     lease: stale,
                                     onInvalidated: {}) {
        case .accepted:
            XCTFail("Older lease should be rejected")
        case .rejected:
            break
        }
        XCTAssertFalse(stale.deliveryGate.allowsDelivery)
        XCTAssertEqual(state.count, 1)
    }

    func testUnsubscribeAllReleasesOnlyPanelsOlderThanItsSequence() {
        var state = TerminalStreamConnectionState()
        let older = lease(panelID: "panel-1", token: 2)
        let newer = lease(panelID: "panel-2", token: 5)
        _ = state.commitSubscribe(sequence: 2,
                                  panelID: "panel-1",
                                  lease: older,
                                  onInvalidated: {})
        _ = state.commitSubscribe(sequence: 5,
                                  panelID: "panel-2",
                                  lease: newer,
                                  onInvalidated: {})

        switch state.commitUnsubscribeAll(sequence: 4) {
        case .accepted(let leases):
            XCTAssertEqual(leases.map(\.token), [2])
        case .rejected:
            XCTFail("Fresh unsubscribe-all should be accepted")
        }
        XCTAssertEqual(state.count, 1)

        let fenced = lease(panelID: "panel-3", token: 3)
        if case .accepted = state.commitSubscribe(sequence: 3,
                                                  panelID: "panel-3",
                                                  lease: fenced,
                                                  onInvalidated: {}) {
            XCTFail("Unsubscribe-all should fence older pending candidates")
        }

        switch state.commitUnsubscribe(sequence: 6, panelID: "panel-2") {
        case .accepted(let leases):
            XCTAssertEqual(leases.map(\.token), [5])
        case .rejected:
            XCTFail("Fresh targeted unsubscribe should be accepted")
        }
        XCTAssertEqual(state.count, 0)
    }

    func testExactTokenRemovalAndRetirementPreventLateResurrection() {
        var state = TerminalStreamConnectionState()
        let first = lease(panelID: "panel-1", token: 1)
        let second = lease(panelID: "panel-2", token: 2)
        _ = state.commitSubscribe(sequence: 1,
                                  panelID: "panel-1",
                                  lease: first,
                                  onInvalidated: {})
        _ = state.commitSubscribe(sequence: 2,
                                  panelID: "panel-2",
                                  lease: second,
                                  onInvalidated: {})

        XCTAssertFalse(state.removeIfOwned(panelID: "panel-1", token: 99))
        XCTAssertEqual(state.count, 2)
        XCTAssertTrue(state.removeIfOwned(panelID: "panel-1", token: 1))
        XCTAssertEqual(state.count, 1)

        let retirement = state.retire()
        XCTAssertTrue(state.isRetired)
        XCTAssertEqual(retirement.preRetireCount, 1)
        XCTAssertEqual(retirement.leases.map(\.token), [2])
        XCTAssertEqual(state.count, 0)

        let late = lease(panelID: "panel-3", token: 3)
        if case .accepted = state.commitSubscribe(sequence: 3,
                                                  panelID: "panel-3",
                                                  lease: late,
                                                  onInvalidated: {}) {
            XCTFail("Retired connections must reject late candidates")
        }
        XCTAssertFalse(late.deliveryGate.allowsDelivery)
        XCTAssertEqual(state.count, 0)
    }

    private func lease(panelID: String, token: UInt64) -> OrdinaryTmuxTerminalStreamLease {
        OrdinaryTmuxTerminalStreamLease(token: token,
                                        subscription: StubSubscription(panelID: panelID),
                                        deliveryGate: TerminalStreamDeliveryGate())
    }
}
