import XCTest
@testable import iTerm2SharedARC

final class TideyRestorableStatePreflightTests: XCTestCase {
    func testPreflightAndLaunchActionGatesCompile() {
        let monoServer = TideyRestorableSessionServerIdentifier(
            monoServerProcessID: 42
        )
        let multiServer = TideyRestorableSessionServerIdentifier(
            multiServerSocketNumber: 7,
            childProcessID: 99
        )
        let preflight = TideyRestorableStatePreflight(
            stateExists: true,
            isValid: true,
            numberOfWindows: 2,
            tideySchemaVersion: 1,
            sessionServerIdentifiers: [monoServer, multiServer]
        )
        let actions = TideyRestorationLaunchActionSpy()

        XCTAssertTrue(preflight.hasRestorableWindows)
        XCTAssertTrue(preflight.hasSupportedTideySchemaVersion)
        XCTAssertEqual(preflight.sessionServerIdentifiers.count, 2)

        actions.restoreAcceptedState()
        actions.eraseRejectedState()
        actions.discardOrphanAdoptionForLaunch()
        actions.terminateRejectedSessionServers(
            preflight.sessionServerIdentifiers
        )

        XCTAssertEqual(
            actions.events,
            ["restore", "erase", "discard-orphans", "terminate-2"]
        )
    }
}

private final class TideyRestorationLaunchActionSpy:
    NSObject,
    TideyRestorationWindowRestoring,
    TideyRestorationStateErasing,
    TideyRestorationOrphanAdoptionDiscarding,
    TideyRestorationRejectedServerTerminating {
    private(set) var events = [String]()

    func restoreAcceptedState() {
        events.append("restore")
    }

    func eraseRejectedState() {
        events.append("erase")
    }

    func discardOrphanAdoptionForLaunch() {
        events.append("discard-orphans")
    }

    func terminateRejectedSessionServers(
        _ identifiers: [TideyRestorableSessionServerIdentifier]
    ) {
        events.append("terminate-\(identifiers.count)")
    }
}
