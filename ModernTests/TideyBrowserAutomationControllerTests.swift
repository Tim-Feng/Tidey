import XCTest
@testable import iTerm2SharedARC

@MainActor
private final class TideyBrowserAutomationHostStub: NSObject, TideyBrowserAutomationHost {
    func browserAutomationVisibleTabs() -> [[String: Any]] {
        []
    }

    func browserAutomationEngine(forTabID tabID: String) -> TideyBrowserEngine? {
        nil
    }

    func browserAutomationPresent(engine: TideyBrowserEngine,
                                  tabID: String,
                                  initialURL: URL) -> Bool {
        false
    }
}

final class TideyBrowserAutomationControllerTests: XCTestCase {
    @MainActor
    func testControllerOwnershipSeam() {
        let host = TideyBrowserAutomationHostStub()
        let controller = TideyBrowserAutomationController(
            host: host,
            maxPrivateTabs: 8,
            handoffTTL: 1_800
        )

        XCTAssertTrue(controller.host === host)
        XCTAssertEqual(controller.state.maxPrivateTabs, 8)
        XCTAssertEqual(controller.state.handoffTTL, 1_800)
        XCTAssertTrue(controller.privateEnginesByID.isEmpty)
    }
}
