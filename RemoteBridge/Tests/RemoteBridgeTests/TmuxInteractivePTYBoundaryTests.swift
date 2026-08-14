import XCTest

@testable import RemoteBridge

final class TmuxInteractivePTYBoundaryTests: XCTestCase {
    private final class Probe: TmuxInteractivePTYControlling, @unchecked Sendable {
        private(set) var spawnedCommand: TmuxInteractivePTYAttachCommand?
        private(set) var resized: (fileDescriptor: Int32, size: TmuxInteractivePTYSize)?
        private(set) var closedFileDescriptor: Int32?
        private(set) var reapedProcessID: Int32?

        func spawn(_ command: TmuxInteractivePTYAttachCommand) throws -> TmuxInteractivePTYHandle {
            spawnedCommand = command
            return TmuxInteractivePTYHandle(masterFileDescriptor: 17, childProcessID: 23)
        }

        func resize(masterFileDescriptor: Int32, to size: TmuxInteractivePTYSize) throws {
            resized = (masterFileDescriptor, size)
        }

        func close(masterFileDescriptor: Int32) throws {
            closedFileDescriptor = masterFileDescriptor
        }

        func reap(childProcessID: Int32, blocking: Bool) throws -> TmuxInteractivePTYChildExit? {
            reapedProcessID = childProcessID
            return TmuxInteractivePTYChildExit(rawStatus: blocking ? 0 : 1)
        }
    }

    func testPTYShimBoundaryCarriesOnlyResolvedTmuxIdentityAndLifecycleValues() throws {
        let size = TmuxInteractivePTYSize(columns: 80, rows: 24)
        let command = TmuxInteractivePTYAttachCommand(
            tmuxExecutablePath: "/opt/homebrew/bin/tmux",
            socket: .path("/private/tmp/tmux-501/default"),
            sessionID: "$7",
            windowID: "@11",
            initialSize: size
        )
        let probe = Probe()

        let handle = try probe.spawn(command)
        try probe.resize(masterFileDescriptor: handle.masterFileDescriptor, to: size)
        try probe.close(masterFileDescriptor: handle.masterFileDescriptor)
        let childExit = try probe.reap(childProcessID: handle.childProcessID, blocking: true)

        XCTAssertEqual(TmuxInteractivePTYShimABI.version, 1)
        XCTAssertEqual(probe.spawnedCommand, command)
        XCTAssertEqual(probe.resized?.fileDescriptor, 17)
        XCTAssertEqual(probe.resized?.size, size)
        XCTAssertEqual(probe.closedFileDescriptor, 17)
        XCTAssertEqual(probe.reapedProcessID, 23)
        XCTAssertEqual(childExit, TmuxInteractivePTYChildExit(rawStatus: 0))
    }
}
