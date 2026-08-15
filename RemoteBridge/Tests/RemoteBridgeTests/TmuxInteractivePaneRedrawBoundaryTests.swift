import XCTest

@testable import RemoteBridge

final class TmuxInteractivePaneRedrawBoundaryTests: XCTestCase {
    private final class ProcessProbe: @unchecked Sendable {
        var results = [BoundedProcessResult?]()
        private(set) var arguments = [[String]]()

        func run(_ arguments: [String]) -> BoundedProcessResult? {
            self.arguments.append(arguments)
            guard results.isEmpty == false else { return nil }
            return results.removeFirst()
        }
    }

    private final class SignalProbe: @unchecked Sendable {
        private(set) var processIDs = [[Int32]]()

        func signal(_ processIDs: [Int32]) throws {
            self.processIDs.append(processIDs)
        }
    }

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

    func testRequesterSignalsOnlyForegroundMembersOfExactPaneTTY() throws {
        let tmux = ProcessProbe()
        tmux.results = [
            BoundedProcessResult(
                terminationStatus: 0,
                standardOutput: Data(
                    "TIDEYv1|%17|4321|/dev/ttys123|END\n".utf8
                ),
                standardError: Data()
            ),
        ]
        let processStatus = ProcessProbe()
        processStatus.results = [
            BoundedProcessResult(
                terminationStatus: 0,
                standardOutput: Data("ttys123 7000\n".utf8),
                standardError: Data()
            ),
            BoundedProcessResult(
                terminationStatus: 0,
                standardOutput: Data(
                    "4321 7000 ttys123\n"
                        .appending("4333 7000 ttys123\n")
                        .appending("4444 7000 ttys999\n")
                        .appending("4555 8000 ttys123\n")
                        .utf8
                ),
                standardError: Data()
            ),
        ]
        let signal = SignalProbe()
        let requester = TmuxInteractivePaneRedrawRequester(
            runTmux: { tmux.run($0) },
            runProcessStatus: { processStatus.run($0) },
            signalProcesses: { try signal.signal($0) }
        )

        try requester.requestRedraw(
            TmuxInteractivePaneRedrawRequest(
                socket: .path("/private/tmp/tidey-isolated-tmux/socket"),
                paneID: "%17"
            )
        )

        XCTAssertEqual(
            tmux.arguments,
            [[
                "-S", "/private/tmp/tidey-isolated-tmux/socket",
                "display-message", "-p",
                "-t", "%17",
                "TIDEYv1|#{pane_id}|#{pane_pid}|#{pane_tty}|END",
            ]]
        )
        XCTAssertEqual(
            processStatus.arguments,
            [
                ["-o", "tty=", "-o", "tpgid=", "-p", "4321"],
                ["-a", "-x", "-o", "pid=", "-o", "pgid=", "-o", "tty="],
            ]
        )
        XCTAssertEqual(signal.processIDs, [[4321, 4333]])
    }

    func testRequesterRejectsMismatchedPaneRecordBeforeProcessInspection() {
        let tmux = ProcessProbe()
        tmux.results = [
            BoundedProcessResult(
                terminationStatus: 0,
                standardOutput: Data(
                    "TIDEYv1|%18|4321|/dev/ttys123|END\n".utf8
                ),
                standardError: Data()
            ),
        ]
        let processStatus = ProcessProbe()
        let signal = SignalProbe()
        let requester = TmuxInteractivePaneRedrawRequester(
            runTmux: { tmux.run($0) },
            runProcessStatus: { processStatus.run($0) },
            signalProcesses: { try signal.signal($0) }
        )

        XCTAssertThrowsError(
            try requester.requestRedraw(
                TmuxInteractivePaneRedrawRequest(
                    socket: .defaultSocket,
                    paneID: "%17"
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? TmuxInteractivePaneRedrawRequesterError,
                .invalidPaneRecord
            )
        }
        XCTAssertTrue(processStatus.arguments.isEmpty)
        XCTAssertTrue(signal.processIDs.isEmpty)
    }
}
