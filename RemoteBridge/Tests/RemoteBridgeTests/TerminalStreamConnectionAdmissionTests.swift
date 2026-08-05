import XCTest
@testable import RemoteBridge

final class TerminalStreamConnectionAdmissionTests: XCTestCase {
    func testIdentifiedIDIsConsumedBeforeLaterArbitrationFailure() throws {
        let admission = TerminalStreamConnectionAdmission()
        XCTAssertTrue(admission.prepareUnsubscribeAll(sequence: 5))

        XCTAssertNil(admission.reserveSubscribe(sequence: 3,
                                                 panelID: "panel-1",
                                                 owner: .identified("owner-a")))
        XCTAssertNil(admission.reserveSubscribe(sequence: 6,
                                                 panelID: "panel-1",
                                                 owner: .identified("owner-a")))
        XCTAssertNotNil(admission.reserveSubscribe(sequence: 6,
                                                    panelID: "panel-1",
                                                    owner: .identified("owner-b")))
    }

    func testIdenticalIdentifiedIDCannotBeReservedTwice() throws {
        let admission = TerminalStreamConnectionAdmission()
        XCTAssertNotNil(admission.reserveSubscribe(sequence: 1,
                                                    panelID: "panel-1",
                                                    owner: .identified("owner-a")))
        XCTAssertNil(admission.reserveSubscribe(sequence: 2,
                                                 panelID: "panel-2",
                                                 owner: .identified("owner-a")))
    }

    func testStaleUnsubscribeAllNeverCancelsReservationWithHigherSequence() throws {
        let admission = TerminalStreamConnectionAdmission()
        let reservation = try XCTUnwrap(admission.reserveSubscribe(sequence: 3,
                                                                   panelID: "panel-1",
                                                                   owner: .identified("owner-a")))

        XCTAssertTrue(admission.prepareUnsubscribeAll(sequence: 2))
        XCTAssertEqual(admission.state(of: reservation), .reserved)
        XCTAssertTrue(admission.claimForPhysicalMutation(reservation))
        XCTAssertTrue(admission.finalizeSubscribe(reservation))
        XCTAssertEqual(admission.state(of: reservation), .finalized)
    }

    func testFreshUnsubscribeAllCancelsOlderPendingReservations() throws {
        let admission = TerminalStreamConnectionAdmission()
        let identified = try XCTUnwrap(admission.reserveSubscribe(sequence: 1,
                                                                  panelID: "panel-1",
                                                                  owner: .identified("owner-a")))
        let legacy = try XCTUnwrap(admission.reserveSubscribe(sequence: 2,
                                                              panelID: "panel-2",
                                                              owner: .legacy))

        XCTAssertTrue(admission.prepareUnsubscribeAll(sequence: 3))
        XCTAssertEqual(admission.state(of: identified), .canceled)
        XCTAssertEqual(admission.state(of: legacy), .canceled)
        XCTAssertFalse(admission.claimForPhysicalMutation(identified))
        XCTAssertFalse(admission.claimForPhysicalMutation(legacy))
    }

    func testStaleLegacyCleanupNeverCancelsNewerLegacyReservation() throws {
        let admission = TerminalStreamConnectionAdmission()
        let reservation = try XCTUnwrap(admission.reserveSubscribe(sequence: 3,
                                                                   panelID: "panel-1",
                                                                   owner: .legacy))

        XCTAssertFalse(admission.prepareLegacyUnsubscribe(sequence: 2, panelID: "panel-1"))
        XCTAssertEqual(admission.state(of: reservation), .reserved)
        XCTAssertTrue(admission.claimForPhysicalMutation(reservation))
        XCTAssertTrue(admission.finalizeSubscribe(reservation))
    }

    func testFreshLegacyCleanupCancelsOnlyOlderLegacyReservation() throws {
        let admission = TerminalStreamConnectionAdmission()
        let legacy = try XCTUnwrap(admission.reserveSubscribe(sequence: 1,
                                                              panelID: "panel-1",
                                                              owner: .legacy))
        let identified = try XCTUnwrap(admission.reserveSubscribe(sequence: 2,
                                                                  panelID: "panel-2",
                                                                  owner: .identified("owner-a")))

        XCTAssertTrue(admission.prepareLegacyUnsubscribe(sequence: 3, panelID: "panel-1"))
        XCTAssertEqual(admission.state(of: legacy), .canceled)
        XCTAssertEqual(admission.state(of: identified), .reserved)
        XCTAssertFalse(admission.claimForPhysicalMutation(legacy))
        XCTAssertTrue(admission.claimForPhysicalMutation(identified))
    }

    func testDifferentIdentifiedCleanupDoesNotCancelReservation() throws {
        let admission = TerminalStreamConnectionAdmission()
        let reservation = try XCTUnwrap(admission.reserveSubscribe(sequence: 1,
                                                                   panelID: "panel-1",
                                                                   owner: .identified("owner-b")))

        XCTAssertTrue(admission.prepareIdentifiedUnsubscribe(panelID: "panel-1", id: "owner-a"))
        XCTAssertEqual(admission.state(of: reservation), .reserved)
        XCTAssertTrue(admission.claimForPhysicalMutation(reservation))
        XCTAssertTrue(admission.finalizeSubscribe(reservation))
    }

    func testCleanupBetweenReserveAndClaimPreventsPhysicalMutation() throws {
        let admission = TerminalStreamConnectionAdmission()
        let reservation = try XCTUnwrap(admission.reserveSubscribe(sequence: 1,
                                                                   panelID: "panel-1",
                                                                   owner: .identified("owner-a")))

        XCTAssertTrue(admission.prepareIdentifiedUnsubscribe(panelID: "panel-1", id: "owner-a"))
        XCTAssertEqual(admission.state(of: reservation), .canceled)
        XCTAssertFalse(admission.claimForPhysicalMutation(reservation))
        XCTAssertFalse(admission.finalizeSubscribe(reservation))
    }

    func testCleanupAfterClaimVetoesFinalInstall() throws {
        let admission = TerminalStreamConnectionAdmission()
        let reservation = try XCTUnwrap(admission.reserveSubscribe(sequence: 1,
                                                                   panelID: "panel-1",
                                                                   owner: .identified("owner-a")))

        XCTAssertTrue(admission.claimForPhysicalMutation(reservation))
        XCTAssertTrue(admission.prepareIdentifiedUnsubscribe(panelID: "panel-1", id: "owner-a"))
        XCTAssertFalse(admission.finalizeSubscribe(reservation))
        admission.abandonSubscribe(reservation)
        XCTAssertEqual(admission.state(of: reservation), .canceled)
    }

    func testAbandonKeepsIdentifiedIDConsumed() throws {
        let admission = TerminalStreamConnectionAdmission()
        let reservation = try XCTUnwrap(admission.reserveSubscribe(sequence: 1,
                                                                   panelID: "panel-1",
                                                                   owner: .identified("owner-a")))

        admission.abandonSubscribe(reservation)
        XCTAssertEqual(admission.state(of: reservation), .canceled)
        XCTAssertNil(admission.reserveSubscribe(sequence: 2,
                                                 panelID: "panel-1",
                                                 owner: .identified("owner-a")))
    }

    func testRetireCancelsEveryPendingReservationAndRejectsFurtherWork() throws {
        let admission = TerminalStreamConnectionAdmission()
        let identified = try XCTUnwrap(admission.reserveSubscribe(sequence: 1,
                                                                  panelID: "panel-1",
                                                                  owner: .identified("owner-a")))
        let legacy = try XCTUnwrap(admission.reserveSubscribe(sequence: 2,
                                                              panelID: "panel-2",
                                                              owner: .legacy))

        admission.retire()

        XCTAssertEqual(admission.state(of: identified), .canceled)
        XCTAssertEqual(admission.state(of: legacy), .canceled)
        XCTAssertFalse(admission.claimForPhysicalMutation(identified))
        XCTAssertFalse(admission.claimForPhysicalMutation(legacy))
        XCTAssertNil(admission.reserveSubscribe(sequence: 3,
                                                 panelID: "panel-3",
                                                 owner: .identified("owner-b")))
        XCTAssertFalse(admission.prepareUnsubscribeAll(sequence: 4))
    }
}
