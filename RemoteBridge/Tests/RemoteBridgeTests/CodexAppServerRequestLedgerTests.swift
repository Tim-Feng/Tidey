import XCTest
@testable import RemoteBridge

final class CodexAppServerRequestLedgerTests: XCTestCase {
    func testEquivalentRequestKeepsItsExistingAssociation() {
        let ledger = CodexAppServerRequestLedger()

        XCTAssertEqual(ledger.admit(requestIDKey: "s:request-1",
                                    fingerprint: "fingerprint-a",
                                    promptID: "prompt-1"),
                       .acceptedNew)
        XCTAssertEqual(ledger.admit(requestIDKey: "s:request-1",
                                    fingerprint: "fingerprint-a",
                                    promptID: "prompt-1"),
                       .acceptedDuplicate)
        XCTAssertTrue(ledger.beginResponse(requestIDKey: "s:request-1",
                                           fingerprint: "fingerprint-a",
                                           promptID: "prompt-1"))
    }

    func testPreWireCollisionTransfersOwnership() {
        let ledger = CodexAppServerRequestLedger()
        _ = ledger.admit(requestIDKey: "s:request-1",
                         fingerprint: "fingerprint-a",
                         promptID: "prompt-1")

        XCTAssertEqual(ledger.admit(requestIDKey: "s:request-1",
                                    fingerprint: "fingerprint-b",
                                    promptID: "prompt-2"),
                       .replaced(previousPromptID: "prompt-1"))
        XCTAssertFalse(ledger.beginResponse(requestIDKey: "s:request-1",
                                            fingerprint: "fingerprint-a",
                                            promptID: "prompt-1"))
        XCTAssertTrue(ledger.beginResponse(requestIDKey: "s:request-1",
                                           fingerprint: "fingerprint-b",
                                           promptID: "prompt-2"))
    }

    func testPostWireCollisionPoisonsExactlyOnce() {
        let ledger = CodexAppServerRequestLedger()
        _ = ledger.admit(requestIDKey: "s:request-1",
                         fingerprint: "fingerprint-a",
                         promptID: "prompt-1")
        XCTAssertTrue(ledger.beginResponse(requestIDKey: "s:request-1",
                                           fingerprint: "fingerprint-a",
                                           promptID: "prompt-1"))

        XCTAssertEqual(ledger.admit(requestIDKey: "s:request-1",
                                    fingerprint: "fingerprint-b",
                                    promptID: "prompt-2"),
                       .protocolViolation(isNew: true))
        XCTAssertEqual(ledger.admit(requestIDKey: "s:request-1",
                                    fingerprint: "fingerprint-b",
                                    promptID: "prompt-2"),
                       .protocolViolation(isNew: false))
        XCTAssertFalse(ledger.beginResponse(requestIDKey: "s:request-1",
                                            fingerprint: "fingerprint-a",
                                            promptID: "prompt-1"))
    }

    func testDifferentAssociationCannotClaimEquivalentFingerprint() {
        let ledger = CodexAppServerRequestLedger()
        _ = ledger.admit(requestIDKey: "s:request-1",
                         fingerprint: "fingerprint-a",
                         promptID: "prompt-1")

        XCTAssertEqual(ledger.admit(requestIDKey: "s:request-1",
                                    fingerprint: "fingerprint-a",
                                    promptID: "prompt-2"),
                       .replaced(previousPromptID: "prompt-1"))
        XCTAssertFalse(ledger.beginResponse(requestIDKey: "s:request-1",
                                            fingerprint: "fingerprint-a",
                                            promptID: "prompt-1"))
    }

    func testStaleResolutionCannotReleaseNewOwner() {
        let ledger = CodexAppServerRequestLedger()
        _ = ledger.admit(requestIDKey: "s:request-1",
                         fingerprint: "fingerprint-a",
                         promptID: "prompt-1")
        _ = ledger.admit(requestIDKey: "s:request-1",
                         fingerprint: "fingerprint-b",
                         promptID: "prompt-2")

        XCTAssertFalse(ledger.resolve(requestIDKey: "s:request-1",
                                      fingerprint: "fingerprint-a",
                                      promptID: "prompt-1"))
        XCTAssertTrue(ledger.resolve(requestIDKey: "s:request-1",
                                     fingerprint: "fingerprint-b",
                                     promptID: "prompt-2"))
        XCTAssertEqual(ledger.admit(requestIDKey: "s:request-1",
                                    fingerprint: "fingerprint-c",
                                    promptID: "prompt-3"),
                       .acceptedNew)
    }

    func testStaleResolutionCannotReleaseSamePromptWithNewFingerprint() {
        let ledger = CodexAppServerRequestLedger()
        _ = ledger.admit(requestIDKey: "s:request-1",
                         fingerprint: "fingerprint-a",
                         promptID: "prompt-1")
        _ = ledger.admit(requestIDKey: "s:request-1",
                         fingerprint: "fingerprint-b",
                         promptID: "prompt-1")

        XCTAssertFalse(ledger.resolve(requestIDKey: "s:request-1",
                                      fingerprint: "fingerprint-a",
                                      promptID: "prompt-1"))
        XCTAssertTrue(ledger.beginResponse(requestIDKey: "s:request-1",
                                           fingerprint: "fingerprint-b",
                                           promptID: "prompt-1"))
    }
}
