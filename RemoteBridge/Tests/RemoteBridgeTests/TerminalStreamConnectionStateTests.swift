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

    func testLegacyCleanupNeverRemovesIdentifiedLease() {
        var state = TerminalStreamConnectionState()
        let identified = lease(panelID: "panel-1", token: 10, owner: .identified("owner-b"))
        _ = state.commitSubscribe(sequence: 10,
                                  panelID: "panel-1",
                                  owner: .identified("owner-b"),
                                  lease: identified,
                                  onInvalidated: {})

        switch state.commitLegacyUnsubscribe(sequence: 20, panelID: "panel-1") {
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
        _ = state.commitSubscribe(sequence: 10,
                                  panelID: "panel-1",
                                  owner: .legacy,
                                  lease: legacy,
                                  onInvalidated: {})

        switch state.commitSubscribe(sequence: 20,
                                     panelID: "panel-1",
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

    func testMismatchedIdentifiedUnsubscribeIsIdempotentAndTombstonesOnlyItsOwner() {
        var state = TerminalStreamConnectionState()
        let current = lease(panelID: "panel-1", token: 20, owner: .identified("owner-b"))
        _ = state.commitSubscribe(sequence: 20,
                                  panelID: "panel-1",
                                  owner: .identified("owner-b"),
                                  lease: current,
                                  onInvalidated: {})

        switch state.commitIdentifiedUnsubscribe(panelID: "panel-1", id: "owner-a") {
        case .accepted(let leases):
            XCTAssertEqual(leases.count, 0)
        case .rejected:
            XCTFail("Mismatched identified cleanup must be idempotently accepted")
        }
        XCTAssertEqual(state.count, 1)

        let tombstoned = lease(panelID: "panel-2", token: 30, owner: .identified("owner-a"))
        if case .accepted = state.commitSubscribe(sequence: 30,
                                                  panelID: "panel-2",
                                                  owner: .identified("owner-a"),
                                                  lease: tombstoned,
                                                  onInvalidated: {}) {
            XCTFail("Cleanup must tombstone a matching pending identified attempt")
        }
    }

    func testMatchingIdentifiedUnsubscribeRemovesOnlyItsLease() {
        var state = TerminalStreamConnectionState()
        let identified = lease(panelID: "panel-1", token: 10, owner: .identified("owner-a"))
        _ = state.commitSubscribe(sequence: 10,
                                  panelID: "panel-1",
                                  owner: .identified("owner-a"),
                                  lease: identified,
                                  onInvalidated: {})

        switch state.commitIdentifiedUnsubscribe(panelID: "panel-1", id: "owner-a") {
        case .accepted(let leases):
            XCTAssertEqual(leases.map(\.token), [10])
        case .rejected:
            XCTFail("Matching identified cleanup should be accepted")
        }
        XCTAssertEqual(state.count, 0)
    }

    func testFirstIdentifiedSubscribeAttemptConsumesIDEvenWhenPanelArbitrationRejects() {
        var state = TerminalStreamConnectionState()
        let current = lease(panelID: "panel-1", token: 10, owner: .legacy)
        _ = state.commitSubscribe(sequence: 10,
                                  panelID: "panel-1",
                                  owner: .legacy,
                                  lease: current,
                                  onInvalidated: {})

        let rejected = lease(panelID: "panel-1", token: 5, owner: .identified("owner-a"))
        if case .accepted = state.commitSubscribe(sequence: 5,
                                                  panelID: "panel-1",
                                                  owner: .identified("owner-a"),
                                                  lease: rejected,
                                                  onInvalidated: {}) {
            XCTFail("Older identified subscribe should lose panel arbitration")
        }

        let reused = lease(panelID: "panel-1", token: 20, owner: .identified("owner-a"))
        if case .accepted = state.commitSubscribe(sequence: 20,
                                                  panelID: "panel-1",
                                                  owner: .identified("owner-a"),
                                                  lease: reused,
                                                  onInvalidated: {}) {
            XCTFail("The same identified owner ID must never be reused")
        }
        XCTAssertEqual(state.count, 1)
    }

    func testStaleIdentifiedCleanupCannotRemoveNewerIdentifiedOwner() {
        var state = TerminalStreamConnectionState()
        let first = lease(panelID: "panel-1", token: 10, owner: .identified("owner-a"))
        let second = lease(panelID: "panel-1", token: 20, owner: .identified("owner-b"))
        _ = state.commitSubscribe(sequence: 10,
                                  panelID: "panel-1",
                                  owner: .identified("owner-a"),
                                  lease: first,
                                  onInvalidated: {})
        _ = state.commitSubscribe(sequence: 20,
                                  panelID: "panel-1",
                                  owner: .identified("owner-b"),
                                  lease: second,
                                  onInvalidated: {})

        switch state.commitIdentifiedUnsubscribe(panelID: "panel-1", id: "owner-a") {
        case .accepted(let leases):
            XCTAssertEqual(leases.count, 0)
        case .rejected:
            XCTFail("Stale identified cleanup should be an accepted no-op")
        }
        XCTAssertEqual(state.count, 1)
    }

    func testUnsubscribeAllUsesLeaseTokenInsteadOfLatestSubscribeHighWater() {
        var state = TerminalStreamConnectionState()
        let current = lease(panelID: "panel-1", token: 5, owner: .identified("owner-a"))
        _ = state.commitSubscribe(sequence: 5,
                                  panelID: "panel-1",
                                  owner: .identified("owner-a"),
                                  lease: current,
                                  onInvalidated: {})

        let rejectedGate = TerminalStreamDeliveryGate()
        rejectedGate.invalidate()
        let rejected = OrdinaryTmuxTerminalStreamLease(
            token: 8,
            owner: .identified("owner-b"),
            subscription: StubSubscription(panelID: "panel-1"),
            deliveryGate: rejectedGate
        )
        if case .accepted = state.commitSubscribe(sequence: 8,
                                                  panelID: "panel-1",
                                                  owner: .identified("owner-b"),
                                                  lease: rejected,
                                                  onInvalidated: {}) {
            XCTFail("Invalidated candidate must not replace the current lease")
        }

        switch state.commitUnsubscribeAll(sequence: 7) {
        case .accepted(let leases):
            XCTAssertEqual(leases.map(\.token), [5])
        case .rejected:
            XCTFail("A fresh unsubscribe-all should be accepted")
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
