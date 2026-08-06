import Foundation
import XCTest
@testable import RemoteBridge

final class OrdinaryTmuxControlModeEventParserTests: XCTestCase {
    func testParserFramesPartialBytesAndIgnoresCommandOutputBlocks() {
        let parser = OrdinaryTmuxControlModeEventParser()

        XCTAssertEqual(
            parser.feed(Data("%begin 100 2 1\n%layout-cha".utf8)),
            []
        )
        XCTAssertEqual(
            parser.feed(Data("nge @ignored layout visible flags\n%end 100 2 1\r\n%layout-cha".utf8)),
            []
        )
        XCTAssertEqual(
            parser.feed(Data("nge @2 layout visible flags\n%subscription-changed tidey-A $1 @2 0 %21 future : %21,pane=132x40,window=132x40\n%window-pane-changed @2 %22\n%exit\n".utf8)),
            [
                .layoutChanged(windowID: "@2"),
                .subscriptionChanged(
                    name: "tidey-A",
                    sessionID: "$1",
                    windowID: "@2",
                    paneID: "%21",
                    value: "%21,pane=132x40,window=132x40"
                ),
                .windowPaneChanged(windowID: "@2", paneID: "%22"),
                .observerExited,
            ]
        )
    }

    func testParserFailsClosedAfterMalformedControlInput() {
        let mismatchedBlock = OrdinaryTmuxControlModeEventParser()
        XCTAssertEqual(
            mismatchedBlock.feed(Data("%begin 100 2 1\n%end 100 3 1\n".utf8)),
            [.observerUnhealthy]
        )
        XCTAssertEqual(
            mismatchedBlock.feed(Data("%layout-change @2 layout visible flags\n".utf8)),
            []
        )

        let malformedSubscription = OrdinaryTmuxControlModeEventParser()
        XCTAssertEqual(
            malformedSubscription.feed(
                Data("%subscription-changed tidey-A $1 @2 bad %21 : malformed\n".utf8)
            ),
            [.observerUnhealthy]
        )

        let oversized = OrdinaryTmuxControlModeEventParser()
        XCTAssertEqual(
            oversized.feed(Data(repeating: 0x41, count: 64 * 1024 + 1)),
            [.observerUnhealthy]
        )
    }
}
