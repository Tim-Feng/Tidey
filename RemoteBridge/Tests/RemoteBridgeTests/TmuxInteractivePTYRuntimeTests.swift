import XCTest

@testable import RemoteBridge

final class TmuxInteractivePTYRuntimeTests: XCTestCase {
    func testDisabledRuntimeOwnsActivationAndProjectionContextTogether() {
        let runtime = TmuxInteractivePTYRuntime.disabled()

        XCTAssertNil(runtime.activation.candidateBuilder)
        XCTAssertTrue(runtime.activation.protocolCapabilities.isEmpty)
        XCTAssertTrue(
            runtime.ordinaryTmuxProjectionContext.registry ===
                runtime.ordinaryTmuxProjectionContext.registry
        )
        XCTAssertTrue(
            runtime.ordinaryTmuxProjectionContext.inputSubmissionStore ===
                runtime.ordinaryTmuxProjectionContext.inputSubmissionStore
        )
    }
}
