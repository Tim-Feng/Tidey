import XCTest
@testable import RemoteBridge

final class TerminalHistoryPagingTests: XCTestCase {
    func testTmuxCapturePlanUsesFixedBoundsAndInvalidatesMismatchedOverlap() throws {
        let firstPlan = try OrdinaryTmuxHistoryPagePolicy.capturePlan(
            offset: 0,
            pageLines: 2,
            anchor: nil,
            paneID: "%7"
        )
        XCTAssertEqual(
            firstPlan.arguments,
            ["capture-pane", "-e", "-p", "-S", "-2", "-E", "-1", "-t", "%7"]
        )

        let first = OrdinaryTmuxHistoryPagePolicy.evaluate(
            rows: [Data("OLDER".utf8), Data("OLD".utf8)],
            plan: firstPlan
        )
        XCTAssertFalse(first.invalidated)
        XCTAssertEqual(first.rows.map { String(decoding: $0, as: UTF8.self) }, ["OLDER", "OLD"])
        XCTAssertEqual(first.nextOffset, 2)
        XCTAssertEqual(first.anchor?.offset, 2)
        XCTAssertEqual(first.anchor?.sha16.count, 16)
        XCTAssertFalse(first.oldestReached)

        let anchor = try XCTUnwrap(first.anchor)
        let olderPlan = try OrdinaryTmuxHistoryPagePolicy.capturePlan(
            offset: first.nextOffset,
            pageLines: 2,
            anchor: anchor,
            paneID: "%7"
        )
        XCTAssertEqual(
            olderPlan.arguments,
            ["capture-pane", "-e", "-p", "-S", "-4", "-E", "-2", "-t", "%7"]
        )

        let valid = OrdinaryTmuxHistoryPagePolicy.evaluate(
            rows: [Data("EARLIEST".utf8), Data("EARLIER".utf8), Data("OLDER".utf8)],
            plan: olderPlan
        )
        XCTAssertFalse(valid.invalidated)
        XCTAssertEqual(valid.rows.map { String(decoding: $0, as: UTF8.self) }, ["EARLIEST", "EARLIER"])
        XCTAssertEqual(valid.nextOffset, 4)

        let invalidated = OrdinaryTmuxHistoryPagePolicy.evaluate(
            rows: [Data("EARLIEST".utf8), Data("EARLIER".utf8), Data("SHIFTED".utf8)],
            plan: olderPlan
        )
        XCTAssertTrue(invalidated.invalidated)
        XCTAssertTrue(invalidated.rows.isEmpty)
        XCTAssertEqual(invalidated.nextOffset, 2)
        XCTAssertNil(invalidated.anchor)
    }
}
