import Foundation
import XCTest

@testable import RemoteBridge

final class TmuxInteractivePTYConnectionSessionTests: XCTestCase {
    private final class ControllerProbe: TmuxInteractivePTYControlling, @unchecked Sendable {
        var readResults = [TmuxInteractivePTYReadResult]()
        var readResultsAfterResize = [TmuxInteractivePTYReadResult]()
        private(set) var closeCount = 0
        private(set) var reapCount = 0
        private(set) var writtenBytes = [Data]()

        func spawn(
            _ command: TmuxInteractivePTYAttachCommand
        ) throws -> TmuxInteractivePTYHandle {
            TmuxInteractivePTYHandle(masterFileDescriptor: 17, childProcessID: 23)
        }

        func resize(masterFileDescriptor: Int32, to size: TmuxInteractivePTYSize) throws {
            readResults.append(contentsOf: readResultsAfterResize)
            readResultsAfterResize.removeAll()
        }

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
            writtenBytes.append(bytes)
            return .written(bytes.count)
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
        let firstOutput = Data([0x66, 0x69, 0x72, 0x73, 0x74])
        let secondOutput = Data([0x73, 0x65, 0x63, 0x6f, 0x6e, 0x64])
        let controller = ControllerProbe()
        controller.readResults = [
            .bytes(hiddenProofBytes),
            .wouldBlock,
            .wouldBlock,
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
        XCTAssertEqual(
            try session.poll(),
            .start(
                TmuxInteractiveAuthoritativeStart(
                    binding: binding,
                    attachProof: verifiedAttach.attachProof,
                    viewport: request.subscribe.viewport,
                    initialBytes: hiddenProofBytes
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

    func testSessionRoutesStreamingAttachedReadyAndLiveOutputInOrder() throws {
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
                viewport: TmuxInteractiveViewport(columns: 80, rows: 24),
                startupMode: .streamingReplies
            ),
            route: route,
            tmuxExecutablePath: "/opt/homebrew/bin/tmux"
        )
        let provedPrefix = Data([0x1b, 0x5b, 0x3e, 0x63])
        let liveOutput = Data([0x00, 0xff])
        let controller = ControllerProbe()
        controller.readResults = [.bytes(provedPrefix), .wouldBlock]
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
        prover.results = [verifiedAttach]
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
        XCTAssertEqual(
            try session.poll(),
            .attached(
                TmuxInteractiveAttached(
                    binding: binding,
                    attachProof: verifiedAttach.attachProof,
                    viewport: request.subscribe.viewport,
                    initialBytes: provedPrefix,
                    sequence: 1
                )
            )
        )
        let replyBytes = Data([0x1b, 0x5b, 0x3e, 0x36, 0x35, 0x3b, 0x63])
        XCTAssertEqual(
            try session.sendTerminalReply(
                TmuxInteractiveTerminalReply(binding: binding, bytes: replyBytes)
            ),
            .written(replyBytes.count)
        )
        XCTAssertEqual(controller.writtenBytes, [replyBytes])
        XCTAssertEqual(
            try session.poll(),
            .ready(TmuxInteractiveReady(binding: binding, sequence: 2))
        )
        controller.readResults.append(.bytes(liveOutput))
        XCTAssertEqual(
            try session.poll(),
            .output(
                TmuxInteractiveOutputChunk(
                    binding: binding,
                    sequence: 3,
                    bytes: liveOutput
                )
            )
        )
        try session.close()
    }
}
