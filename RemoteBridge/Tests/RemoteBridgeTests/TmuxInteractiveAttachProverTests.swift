import XCTest

@testable import RemoteBridge

final class TmuxInteractiveAttachProverTests: XCTestCase {
    func testAttachProofRejectsMissingDuplicateAndMalformedClientEvidence() throws {
        let claim = TmuxInteractiveAttachClaim(
            socket: .path("/private/tmp/tmux-proof/socket"),
            childProcessID: 123,
            workspaceID: "workspace-1",
            panelID: "panel-1",
            sessionID: "$1",
            windowID: "@2"
        )
        let exactRecord = "123|/dev/ttys001|$1|@2|%3"

        XCTAssertNil(try prover(output: "").prove(claim))
        XCTAssertNil(try prover(output: "\(exactRecord)\n\(exactRecord)").prove(claim))
        XCTAssertThrowsError(
            try prover(output: "123||$1|@2|%3").prove(claim)
        ) { error in
            XCTAssertEqual(
                error as? TmuxInteractiveAttachProverError,
                .malformedClientRecord("123||$1|@2|%3")
            )
        }
        XCTAssertThrowsError(
            try prover(output: "123|/dev/ttys001|$1|@2|").prove(claim)
        ) { error in
            XCTAssertEqual(
                error as? TmuxInteractiveAttachProverError,
                .malformedClientRecord("123|/dev/ttys001|$1|@2|")
            )
        }
    }

    private func prover(output: String) -> TmuxInteractiveAttachProver {
        TmuxInteractiveAttachProver { socket, arguments, stdin in
            XCTAssertEqual(socket, .path("/private/tmp/tmux-proof/socket"))
            XCTAssertEqual(
                arguments,
                [
                    "list-clients",
                    "-F",
                    "#{client_pid}|#{client_tty}|#{session_id}|#{window_id}|#{pane_id}",
                ]
            )
            XCTAssertNil(stdin)
            return output
        }
    }
}
