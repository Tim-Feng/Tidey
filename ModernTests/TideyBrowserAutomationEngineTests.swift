import XCTest
import WebKit
@testable import iTerm2SharedARC

@MainActor
final class TideyBrowserAutomationEngineTests: XCTestCase {
    func testNavigationEpochAndSnapshotSeam() throws {
        let engine = TideyBrowserEngine(configuration: WKWebViewConfiguration())

        XCTAssertEqual(engine.automationNavigationEpoch, 0)
        XCTAssertEqual(
            TideyBrowserAutomationScript.contentWorld.name,
            "com.tidey.browser-automation"
        )
        let source = try TideyBrowserAutomationScript.source()
        XCTAssertTrue(source.contains("tideyBrowserAutomation"))
        XCTAssertTrue(source.contains("snapshot"))
    }
}
