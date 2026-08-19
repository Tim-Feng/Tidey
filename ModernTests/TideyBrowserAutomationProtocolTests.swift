import XCTest
@testable import iTerm2SharedARC

final class TideyBrowserAutomationProtocolTests: XCTestCase {
    func testCommandAndErrorSeam() {
        let target = TideyBrowserAutomationElementReference(
            tabID: "tab-1",
            navigationEpoch: 7,
            elementID: "element-3"
        )
        let request = TideyBrowserAutomationRequest(
            workspaceID: "workspace-1",
            command: .click(target: target)
        )
        let response = TideyBrowserAutomationResponse(result: [
            "tab_id": .string("tab-1"),
            "navigation_epoch": .integer(7),
            "ok": .bool(true)
        ])

        XCTAssertEqual(request.command, .click(target: target))
        XCTAssertEqual(response.result["tab_id"], .string("tab-1"))
        XCTAssertEqual(
            TideyBrowserAutomationOperation.currentURL.rawValue,
            "current_url"
        )
        XCTAssertEqual(
            TideyBrowserAutomationErrorCode.staleReference.rawValue,
            "stale_reference"
        )
    }
}
