import XCTest
@testable import iTerm2SharedARC

final class TideyBrowserAutomationStoreTests: XCTestCase {
    func testPrivateTabIdentityAndOwnershipSeam() {
        let state = TideyBrowserAutomationState(
            maxPrivateTabs: 8,
            handoffTTL: 30 * 60
        )

        XCTAssertEqual(state.maxPrivateTabs, 8)
        XCTAssertEqual(state.handoffTTL, 30 * 60)
        XCTAssertTrue(state.privateTabsByID.isEmpty)
        XCTAssertTrue(state.userClaimsByTabID.isEmpty)
        XCTAssertEqual(
            TideyBrowserAutomationTabMark.deliverable.rawValue,
            "deliverable"
        )
    }
}
