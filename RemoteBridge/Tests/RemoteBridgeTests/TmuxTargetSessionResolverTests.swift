import XCTest
@testable import RemoteBridge

final class TmuxTargetSessionResolverTests: XCTestCase {
    private let storage = TmuxSessionIdentity(sessionID: "$8", sessionName: "storage")
    private let sandbox = TmuxSessionIdentity(sessionID: "$9", sessionName: "sandbox")

    func testResolvesExactSessionID() {
        XCTAssertEqual(resolve("$8", [storage, sandbox]), storage)
    }

    func testExactNameWinsBeforePrefixAmbiguity() {
        let storageRoom = TmuxSessionIdentity(sessionID: "$10", sessionName: "storageroom")
        XCTAssertEqual(resolve("storage", [storage, storageRoom]), storage)
    }

    func testResolvesUniqueNamePrefix() {
        XCTAssertEqual(resolve("s", [storage]), storage)
    }

    func testRejectsAmbiguousNamePrefix() {
        XCTAssertNil(resolve("s", [storage, sandbox]))
    }

    func testExactNameEscapeDoesNotFallBackToPrefix() {
        XCTAssertNil(resolve("=s", [storage]))
        XCTAssertEqual(resolve("=storage", [storage]), storage)
    }

    func testRejectsMissingTarget() {
        XCTAssertNil(resolve("ghost", [storage]))
    }

    func testStaleSessionIDDoesNotFallBackToName() {
        let recreatedStorage = TmuxSessionIdentity(sessionID: "$11", sessionName: "storage")
        XCTAssertNil(resolve("$8", [recreatedStorage]))
    }

    func testRejectsEmptyOrWhitespaceTarget() {
        XCTAssertNil(resolve("", [storage]))
        XCTAssertNil(resolve("   ", [storage]))
    }

    func testIdenticalInventoryDuplicatesDoNotCreateFalseAmbiguity() {
        XCTAssertEqual(resolve("s", [storage, storage]), storage)
    }

    private func resolve(
        _ target: String,
        _ sessions: [TmuxSessionIdentity]
    ) -> TmuxSessionIdentity? {
        TmuxTargetSessionResolver.resolve(
            target: target,
            liveSessions: sessions
        )
    }
}
