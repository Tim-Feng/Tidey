import XCTest

@testable import RemoteBridge

final class TmuxInteractivePTYStartupSizingPlanTests: XCTestCase {
    func testPlanBootstrapsOneRowShortThenGrowsToExactViewport() throws {
        let target = TmuxInteractivePTYSize(columns: 50, rows: 20)
        let plan = try XCTUnwrap(
            TmuxInteractivePTYStartupSizingPlan(targetSize: target)
        )

        XCTAssertEqual(
            plan.bootstrapSize,
            TmuxInteractivePTYSize(columns: 50, rows: 19)
        )
        XCTAssertEqual(plan.targetSize, target)
        XCTAssertTrue(plan.requiresFinalResize)
    }

    func testPlanUsesOneColumnBootstrapOnlyWhenOneRowIsAllThatExists() throws {
        let target = TmuxInteractivePTYSize(columns: 2, rows: 1)
        let plan = try XCTUnwrap(
            TmuxInteractivePTYStartupSizingPlan(targetSize: target)
        )

        XCTAssertEqual(
            plan.bootstrapSize,
            TmuxInteractivePTYSize(columns: 1, rows: 1)
        )
        XCTAssertEqual(plan.targetSize, target)
        XCTAssertTrue(plan.requiresFinalResize)
        XCTAssertNil(
            TmuxInteractivePTYStartupSizingPlan(
                targetSize: TmuxInteractivePTYSize(columns: 1, rows: 1)
            )
        )
    }
}
