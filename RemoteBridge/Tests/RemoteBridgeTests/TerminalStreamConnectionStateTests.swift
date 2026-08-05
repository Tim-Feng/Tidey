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

    func testInstallSubscribeOwnsOneLeasePerPanelAndReturnsDisplacedLease() {
        var state = TerminalStreamConnectionState()
        let first = lease(panelID: "panel-1", token: 5)
        let replacement = lease(panelID: "panel-1", token: 4,
                                owner: .identified("owner-b"))

        switch state.installSubscribe(panelID: "panel-1",
                                      owner: .legacy,
                                      lease: first,
                                      onInvalidated: {}) {
        case .accepted(let displacedLease):
            XCTAssertNil(displacedLease)
        case .rejected:
            XCTFail("First installed lease should be accepted")
        }

        switch state.installSubscribe(panelID: "panel-1",
                                      owner: .identified("owner-b"),
                                      lease: replacement,
                                      onInvalidated: {}) {
        case .accepted(let displacedLease):
            XCTAssertEqual(displacedLease?.token, first.token)
        case .rejected:
            XCTFail("Admission owns ordering; installed state should accept the admitted replacement")
        }
        XCTAssertTrue(first.deliveryGate.allowsDelivery)
        XCTAssertTrue(replacement.deliveryGate.allowsDelivery)
        XCTAssertEqual(state.count, 1)
    }

    func testReleaseInstalledLeasesUsesExactLeaseTokens() {
        var state = TerminalStreamConnectionState()
        let older = lease(panelID: "panel-1", token: 2)
        let newer = lease(panelID: "panel-2", token: 5)
        _ = state.installSubscribe(panelID: "panel-1", owner: .legacy,
                                   lease: older, onInvalidated: {})
        _ = state.installSubscribe(panelID: "panel-2", owner: .legacy,
                                   lease: newer, onInvalidated: {})

        switch state.releaseInstalledLeases(olderThan: 4) {
        case .accepted(let leases):
            XCTAssertEqual(leases.map(\.token), [2])
        case .rejected:
            XCTFail("Active installed state should release matching tokens")
        }
        XCTAssertEqual(state.count, 1)
    }

    func testExactTokenRemovalAndRetirementPreventLateResurrection() {
        var state = TerminalStreamConnectionState()
        let first = lease(panelID: "panel-1", token: 1)
        let second = lease(panelID: "panel-2", token: 2)
        _ = state.installSubscribe(panelID: "panel-1", owner: .legacy,
                                   lease: first, onInvalidated: {})
        _ = state.installSubscribe(panelID: "panel-2", owner: .legacy,
                                   lease: second, onInvalidated: {})

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
        if case .accepted = state.installSubscribe(panelID: "panel-3",
                                                   owner: .legacy,
                                                   lease: late,
                                                   onInvalidated: {}) {
            XCTFail("Retired connections must reject late candidates")
        }
        XCTAssertFalse(late.deliveryGate.allowsDelivery)
        XCTAssertEqual(state.count, 0)
    }

    func testLegacyCleanupNeverRemovesIdentifiedLease() {
        var state = TerminalStreamConnectionState()
        let identified = lease(panelID: "panel-1", token: 10, owner: .identified("owner-b"))
        _ = state.installSubscribe(panelID: "panel-1", owner: .identified("owner-b"),
                                   lease: identified, onInvalidated: {})

        switch state.releaseInstalledLegacyLease(panelID: "panel-1") {
        case .accepted(let leases):
            XCTAssertEqual(leases.count, 0)
        case .rejected:
            XCTFail("Fresh legacy cleanup should be an accepted no-op")
        }
        XCTAssertEqual(state.count, 1)
    }

    func testIdentifiedSubscribeDisplacesCurrentLegacyLease() {
        var state = TerminalStreamConnectionState()
        let legacy = lease(panelID: "panel-1", token: 10, owner: .legacy)
        let identified = lease(panelID: "panel-1", token: 20, owner: .identified("owner-b"))
        _ = state.installSubscribe(panelID: "panel-1", owner: .legacy,
                                   lease: legacy, onInvalidated: {})

        switch state.installSubscribe(panelID: "panel-1",
                                      owner: .identified("owner-b"),
                                      lease: identified,
                                      onInvalidated: {}) {
        case .accepted(let displacedLease):
            XCTAssertEqual(displacedLease?.token, legacy.token)
        case .rejected:
            XCTFail("A newer identified subscribe should displace legacy ownership")
        }
        XCTAssertEqual(state.count, 1)
    }

    func testMismatchedIdentifiedReleaseIsIdempotent() {
        var state = TerminalStreamConnectionState()
        let current = lease(panelID: "panel-1", token: 20, owner: .identified("owner-b"))
        _ = state.installSubscribe(panelID: "panel-1", owner: .identified("owner-b"),
                                   lease: current, onInvalidated: {})

        switch state.releaseInstalledIdentifiedLease(panelID: "panel-1", id: "owner-a") {
        case .accepted(let leases):
            XCTAssertEqual(leases.count, 0)
        case .rejected:
            XCTFail("Mismatched identified cleanup must be idempotently accepted")
        }
        XCTAssertEqual(state.count, 1)
    }

    func testConnectionGlobalIdentifiedReleaseFindsItsLeaseWithoutPanelID() {
        var state = TerminalStreamConnectionState()
        let identified = lease(panelID: "panel-1", token: 10, owner: .identified("owner-a"))
        _ = state.installSubscribe(panelID: "panel-1", owner: .identified("owner-a"),
                                   lease: identified, onInvalidated: {})

        switch state.releaseInstalledIdentifiedLease(panelID: nil, id: "owner-a") {
        case .accepted(let leases):
            XCTAssertEqual(leases.map(\.token), [10])
        case .rejected:
            XCTFail("Matching identified cleanup should be accepted")
        }
        XCTAssertEqual(state.count, 0)
    }

    func testInvalidatedDeliveryGateCannotBecomeInstalledOwnership() {
        var state = TerminalStreamConnectionState()
        let rejectedGate = TerminalStreamDeliveryGate()
        rejectedGate.invalidate()
        let rejected = OrdinaryTmuxTerminalStreamLease(
            token: 1,
            owner: .legacy,
            subscription: StubSubscription(panelID: "panel-1"),
            deliveryGate: rejectedGate
        )
        if case .accepted = state.installSubscribe(panelID: "panel-1",
                                                   owner: .legacy,
                                                   lease: rejected,
                                                   onInvalidated: {}) {
            XCTFail("Invalidated candidate must not become installed ownership")
        }
        XCTAssertEqual(state.count, 0)
    }

    private func lease(panelID: String,
                       token: UInt64,
                       owner: TerminalStreamSubscriptionOwner = .legacy) -> OrdinaryTmuxTerminalStreamLease {
        OrdinaryTmuxTerminalStreamLease(token: token,
                                        owner: owner,
                                        subscription: StubSubscription(panelID: panelID),
                                        deliveryGate: TerminalStreamDeliveryGate())
    }
}
