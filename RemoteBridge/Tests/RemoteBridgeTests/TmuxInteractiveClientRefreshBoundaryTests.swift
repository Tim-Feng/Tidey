import XCTest

@testable import RemoteBridge

final class TmuxInteractiveClientRefreshBoundaryTests: XCTestCase {
    private final class ProcessProbe: @unchecked Sendable {
        var result: BoundedProcessResult?
        private(set) var arguments = [[String]]()

        func run(_ arguments: [String]) -> BoundedProcessResult? {
            self.arguments.append(arguments)
            return result
        }
    }

    func testRequesterRefreshesOnlyExactProvedClientTTY() throws {
        let process = ProcessProbe()
        process.result = BoundedProcessResult(
            terminationStatus: 0,
            standardOutput: Data(),
            standardError: Data()
        )
        let requester = TmuxInteractiveClientRefreshRequester(
            runTmux: { process.run($0) }
        )

        try requester.requestRefresh(
            TmuxInteractiveClientRefreshRequest(
                socket: .path("/private/tmp/tidey-isolated-tmux/socket"),
                clientTTY: "/dev/ttys017"
            )
        )

        XCTAssertEqual(
            process.arguments,
            [[
                "-S", "/private/tmp/tidey-isolated-tmux/socket",
                "refresh-client", "-t", "/dev/ttys017",
            ]]
        )
    }

    func testRequesterRejectsInvalidClientTTYBeforeRunningTmux() {
        let process = ProcessProbe()
        let requester = TmuxInteractiveClientRefreshRequester(
            runTmux: { process.run($0) }
        )

        XCTAssertThrowsError(
            try requester.requestRefresh(
                TmuxInteractiveClientRefreshRequest(
                    socket: .defaultSocket,
                    clientTTY: "client-name"
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? TmuxInteractiveClientRefreshRequesterError,
                .invalidClientTTY
            )
        }
        XCTAssertTrue(process.arguments.isEmpty)
    }
}
