import XCTest

@testable import RemoteBridge

final class TmuxInteractivePTYConnectionStateTests: XCTestCase {
    private final class OwnerProbe {}

    func testConnectionOwnsExactBindingsAndRetiresWithoutLateResurrection() {
        var state = TmuxInteractivePTYConnectionState<OwnerProbe>()
        let firstBinding = TmuxInteractiveSubscriptionBinding(
            subscriptionID: "interactive-1",
            generation: 4
        )
        let staleBinding = TmuxInteractiveSubscriptionBinding(
            subscriptionID: firstBinding.subscriptionID,
            generation: firstBinding.generation - 1
        )
        let replacementBinding = TmuxInteractiveSubscriptionBinding(
            subscriptionID: firstBinding.subscriptionID,
            generation: firstBinding.generation + 1
        )
        let firstOwner = OwnerProbe()
        let rejectedReplacement = OwnerProbe()

        XCTAssertTrue(state.install(binding: firstBinding, owner: firstOwner))
        XCTAssertTrue(state.owner(for: firstBinding) === firstOwner)
        XCTAssertNil(state.owner(for: staleBinding))
        XCTAssertFalse(
            state.install(binding: replacementBinding, owner: rejectedReplacement)
        )
        XCTAssertNil(state.remove(binding: staleBinding))
        XCTAssertTrue(state.owner(for: firstBinding) === firstOwner)
        XCTAssertTrue(state.remove(binding: firstBinding) === firstOwner)
        XCTAssertEqual(state.count, 0)

        let secondBinding = TmuxInteractiveSubscriptionBinding(
            subscriptionID: "interactive-2",
            generation: 8
        )
        let secondOwner = OwnerProbe()
        XCTAssertTrue(state.install(binding: firstBinding, owner: firstOwner))
        XCTAssertTrue(state.install(binding: secondBinding, owner: secondOwner))
        XCTAssertEqual(state.count, 2)

        let retiredOwners = state.retire()
        XCTAssertTrue(state.isRetired)
        XCTAssertEqual(
            Set(retiredOwners.map(ObjectIdentifier.init)),
            Set([ObjectIdentifier(firstOwner), ObjectIdentifier(secondOwner)])
        )
        XCTAssertEqual(state.count, 0)
        XCTAssertNil(state.owner(for: firstBinding))
        XCTAssertNil(state.remove(binding: secondBinding))
        XCTAssertFalse(
            state.install(
                binding: TmuxInteractiveSubscriptionBinding(
                    subscriptionID: "late",
                    generation: 9
                ),
                owner: OwnerProbe()
            )
        )
    }
}
