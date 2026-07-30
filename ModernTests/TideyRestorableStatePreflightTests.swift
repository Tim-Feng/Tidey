import XCTest
@testable import iTerm2SharedARC

final class TideyRestorableStatePreflightTests: XCTestCase {
    func testBlankLaunchGateAndRejectedServerRouterSeamsCompile() {
        let gate = TideyOrphanAdoptionGate()

        XCTAssertFalse(gate.shouldDiscardOrphanAdoptionForLaunch)
        gate.discardOrphanAdoptionForLaunch()
        gate.discardOrphanAdoptionForLaunch()
        XCTAssertTrue(gate.shouldDiscardOrphanAdoptionForLaunch)

        let monoServer = TideyRestorableSessionServerIdentifier(
            monoServerProcessID: 42
        )
        let multiServer = TideyRestorableSessionServerIdentifier(
            multiServerSocketNumber: 7,
            childProcessID: 99
        )
        let executors = TideyRejectedServerExecutorSpy()
        let router = TideyRestorationRejectedServerTerminator(
            monoServerTerminator: executors,
            multiServerChildTerminator: executors
        )

        router.terminateRejectedSessionServers([])
        XCTAssertTrue(executors.identifiers.isEmpty)

        router.terminateRejectedSessionServers([monoServer, multiServer])
        XCTAssertEqual(executors.events, ["mono", "multi"])
        XCTAssertTrue(executors.identifiers[0] === monoServer)
        XCTAssertTrue(executors.identifiers[1] === multiServer)
    }

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
        XCTAssertEqual(preflight.savedStateKind, .taggedSupported)
        XCTAssertEqual(preflight.sessionServerIdentifiers.count, 2)

        XCTAssertEqual(
            TideyRestorableStatePreflight(
                stateExists: true,
                isValid: true,
                numberOfWindows: 1,
                tideySchemaVersion: nil,
                sessionServerIdentifiers: []
            ).savedStateKind,
            .untagged
        )
        XCTAssertEqual(
            TideyRestorableStatePreflight(
                stateExists: true,
                isValid: true,
                numberOfWindows: 1,
                tideySchemaVersion: 99,
                sessionServerIdentifiers: []
            ).savedStateKind,
            .taggedUnsupported
        )

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

private final class TideyRejectedServerExecutorSpy:
    NSObject,
    TideyRestorationMonoServerTerminating,
    TideyRestorationMultiServerChildTerminating {
    private(set) var events = [String]()
    private(set) var identifiers =
        [TideyRestorableSessionServerIdentifier]()

    func terminateRejectedMonoServer(
        _ identifier: TideyRestorableSessionServerIdentifier
    ) {
        events.append("mono")
        identifiers.append(identifier)
    }

    func terminateRejectedMultiServerChild(
        _ identifier: TideyRestorableSessionServerIdentifier
    ) {
        events.append("multi")
        identifiers.append(identifier)
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
