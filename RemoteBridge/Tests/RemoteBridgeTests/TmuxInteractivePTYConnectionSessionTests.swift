import Foundation
import XCTest

@testable import RemoteBridge

final class TmuxInteractivePTYConnectionSessionTests: XCTestCase {
    private final class ControllerProbe: TmuxInteractivePTYControlling, @unchecked Sendable {
        var readResults = [TmuxInteractivePTYReadResult]()
        private(set) var closeCount = 0
        private(set) var reapCount = 0

        func spawn(
            _ command: TmuxInteractivePTYAttachCommand
        ) throws -> TmuxInteractivePTYHandle {
            TmuxInteractivePTYHandle(masterFileDescriptor: 17, childProcessID: 23)
        }

        func resize(masterFileDescriptor: Int32, to size: TmuxInteractivePTYSize) throws {}

        func close(masterFileDescriptor: Int32) throws {
            closeCount += 1
        }

        func reap(
            childProcessID: Int32,
            blocking: Bool
        ) throws -> TmuxInteractivePTYChildExit? {
            reapCount += 1
            return TmuxInteractivePTYChildExit(rawStatus: 0)
        }

        func read(
            masterFileDescriptor: Int32,
            maximumBytes: Int
        ) throws -> TmuxInteractivePTYReadResult {
            guard readResults.isEmpty == false else {
                return .wouldBlock
            }
            return readResults.removeFirst()
        }

        func write(
            _ bytes: Data,
            masterFileDescriptor: Int32
        ) throws -> TmuxInteractivePTYWriteResult {
            .written(bytes.count)
        }
    }

    private final class ProverProbe: TmuxInteractiveAttachProving, @unchecked Sendable {
        var results = [TmuxInteractiveVerifiedAttach?]()

        func prove(
            _ claim: TmuxInteractiveAttachClaim
        ) throws -> TmuxInteractiveVerifiedAttach? {
            guard results.isEmpty == false else { return nil }
            return results.removeFirst()
        }
    }

    func testSessionPumpHidesProofAndEmitsAtMostOneOrderedEventPerPoll() throws {
        let route = OrdinaryTmuxPanelRoute(
            workspaceID: "workspace-1",
            panelID: "ordinary-tmux:path:$1:@2",
            carrierPanelID: "carrier-1",
            socket: .path("/private/tmp/tmux-501/default"),
            sessionID: "$1",
            sessionName: "session-1",
            windowID: "@2",
            windowIndex: 1,
            activePaneID: "%3",
            cwd: nil,
            currentCommand: "zsh"
        )
        let binding = TmuxInteractiveSubscriptionBinding(
            subscriptionID: "interactive-1",
            generation: 9
        )
        let request = TmuxInteractivePTYSessionStartRequest(
            subscribe: TmuxInteractiveSubscribe(
                workspaceID: route.workspaceID,
                panelID: route.panelID,
                binding: binding,
                viewport: TmuxInteractiveViewport(columns: 80, rows: 24)
            ),
            route: route,
            tmuxExecutablePath: "/opt/homebrew/bin/tmux"
        )
        let hiddenProofBytes = Data([0x70, 0x72, 0x6f, 0x6f, 0x66])
        let startBytes = Data([0x1b, 0x5b, 0x48])
        let firstOutput = Data([0x66, 0x69, 0x72, 0x73, 0x74])
        let secondOutput = Data([0x73, 0x65, 0x63, 0x6f, 0x6e, 0x64])
        let controller = ControllerProbe()
        controller.readResults = [
            .bytes(hiddenProofBytes),
            .wouldBlock,
            .wouldBlock,
            .bytes(startBytes),
            .wouldBlock,
            .wouldBlock,
            .bytes(firstOutput),
            .bytes(secondOutput),
            .endOfFile,
        ]
        let verifiedAttach = TmuxInteractiveVerifiedAttach(
            attachProof: TmuxInteractiveAttachProof(
                workspaceID: route.workspaceID,
                panelID: route.panelID,
                sessionID: route.sessionID,
                windowID: route.windowID,
                paneID: route.activePaneID
            ),
            childProcessID: 23,
            clientTTY: "/dev/ttys001"
        )
        let prover = ProverProbe()
        prover.results = [nil, verifiedAttach]
        let owner = TmuxInteractivePTYSessionOwner(
            admissionStore: OrdinaryTmuxInputSubmissionStore(),
            controller: controller,
            attachProver: prover
        )
        try owner.begin(request)
        let session = TmuxInteractivePTYConnectionSession(
            binding: binding,
            owner: owner
        )

        XCTAssertEqual(try session.poll(), .wouldBlock)
        XCTAssertEqual(try session.poll(), .wouldBlock)
        XCTAssertEqual(try session.poll(), .wouldBlock)
        XCTAssertEqual(
            try session.poll(),
            .start(
                TmuxInteractiveAuthoritativeStart(
                    binding: binding,
                    attachProof: verifiedAttach.attachProof,
                    viewport: request.subscribe.viewport,
                    initialBytes: startBytes
                )
            )
        )
        XCTAssertEqual(
            try session.poll(),
            .output(
                TmuxInteractiveOutputChunk(
                    binding: binding,
                    sequence: 1,
                    bytes: firstOutput
                )
            )
        )
        XCTAssertEqual(
            try session.poll(),
            .output(
                TmuxInteractiveOutputChunk(
                    binding: binding,
                    sequence: 2,
                    bytes: secondOutput
                )
            )
        )
        XCTAssertEqual(
            try session.poll(),
            .terminal(
                TmuxInteractiveStateChange(
                    binding: binding,
                    state: .detached,
                    message: nil
                )
            )
        )
        XCTAssertEqual(try session.poll(), .finished)
        XCTAssertEqual(try session.poll(), .finished)
        XCTAssertEqual(controller.closeCount, 1)
        XCTAssertEqual(controller.reapCount, 1)
        XCTAssertEqual(owner.lifecycleState, .closed)
    }
}
