import XCTest
@testable import RemoteBridge

final class BridgeMediaRangeParserTests: XCTestCase {
    func testAbsentHeaderSelectsFullRepresentation() throws {
        XCTAssertEqual(try BridgeMediaRangeParser.parse(nil, size: 100), .full(size: 100))
    }

    func testClosedOpenAndSuffixRangesUseInclusiveBounds() throws {
        XCTAssertEqual(try BridgeMediaRangeParser.parse("bytes=10-19", size: 100),
                       .partial(range: 10...19, size: 100))
        XCTAssertEqual(try BridgeMediaRangeParser.parse("bytes=90-", size: 100),
                       .partial(range: 90...99, size: 100))
        XCTAssertEqual(try BridgeMediaRangeParser.parse("bytes=-12", size: 100),
                       .partial(range: 88...99, size: 100))
    }

    func testEndAndOversizedSuffixClampToRepresentation() throws {
        XCTAssertEqual(try BridgeMediaRangeParser.parse("bytes=90-999", size: 100),
                       .partial(range: 90...99, size: 100))
        XCTAssertEqual(try BridgeMediaRangeParser.parse("bytes=-999", size: 100),
                       .partial(range: 0...99, size: 100))
    }

    func testMultipleMalformedAndUnsatisfiableRangesReturnDeterministic416Metadata() {
        for header in [
            "bytes=0-1,4-5",
            "items=0-1",
            "bytes=",
            "bytes=-",
            "bytes=abc-9",
            "bytes=9-abc",
            "bytes=20-10",
            "bytes=100-",
            "bytes=-0",
            "bytes=18446744073709551616-",
            "bytes=-18446744073709551616",
        ] {
            XCTAssertThrowsError(try BridgeMediaRangeParser.parse(header, size: 100), header) { error in
                XCTAssertEqual(error as? BridgeMediaRangeError,
                               BridgeMediaRangeError(contentRange: "bytes */100"),
                               header)
            }
        }
    }

    func testAnyRangeAgainstEmptyRepresentationIsUnsatisfiable() {
        XCTAssertThrowsError(try BridgeMediaRangeParser.parse("bytes=0-", size: 0)) { error in
            XCTAssertEqual(error as? BridgeMediaRangeError,
                           BridgeMediaRangeError(contentRange: "bytes */0"))
        }
    }
}
