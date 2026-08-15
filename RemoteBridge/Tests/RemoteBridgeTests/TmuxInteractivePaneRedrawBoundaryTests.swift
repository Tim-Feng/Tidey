import XCTest

@testable import RemoteBridge

final class TmuxInteractivePaneRedrawBoundaryTests: XCTestCase {
    private final class RequesterProbe:
        TmuxInteractivePaneRedrawRequesting,
        @unchecked Sendable
    {
        private(set) var requests = [TmuxInteractivePaneRedrawRequest]()

        func requestRedraw(
            _ request: TmuxInteractivePaneRedrawRequest
        ) throws {
            requests.append(request)
        }
    }

    func testBoundaryAcceptsOnlyExactProvedSocketAndPaneIdentity() throws {
        let request = TmuxInteractivePaneRedrawRequest(
            socket: .path("/private/tmp/tidey-isolated-tmux/socket"),
            paneID: "%17"
        )
        let requester = RequesterProbe()

        try requester.requestRedraw(request)

        XCTAssertEqual(
            requester.requests,
            [
                TmuxInteractivePaneRedrawRequest(
                    socket: .path("/private/tmp/tidey-isolated-tmux/socket"),
                    paneID: "%17"
                ),
            ]
        )
    }
}
