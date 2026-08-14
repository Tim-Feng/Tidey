import Darwin
import Foundation
import XCTest

@testable import RemoteBridge

final class TmuxInteractivePTYIntegrationTests: XCTestCase {
    private enum TestError: Error {
        case readTimedOut
        case unexpectedEndOfFile
        case writeTimedOut
        case invalidWriteProgress(Int)
    }

    func testRealPTYAttachesExactSessionWindowWithInitialSizeAndReapsAfterMasterClose() throws {
        guard let tmuxPath = TmuxStateResolver.discoverTmuxBinaryPath() else {
            throw XCTSkip("tmux is unavailable")
        }

        let fixture = try InteractivePTYTmuxFixture(tmuxPath: tmuxPath)
        defer { fixture.shutdown() }
        let target = try fixture.startWithNonCurrentTargetWindow()
        let controller = TmuxInteractivePTYController()
        let handle = try controller.spawn(
            TmuxInteractivePTYAttachCommand(
                tmuxExecutablePath: tmuxPath,
                socket: .path(fixture.socketPath),
                sessionID: target.sessionID,
                windowID: target.windowID,
                initialSize: TmuxInteractivePTYSize(columns: 80, rows: 24)
            )
        )
        var didCloseMaster = false
        var didReapChild = false
        defer {
            if didCloseMaster == false {
                try? controller.close(masterFileDescriptor: handle.masterFileDescriptor)
            }
            if didReapChild == false {
                reapForCleanup(controller: controller, childProcessID: handle.childProcessID)
            }
        }

        XCTAssertEqual(isatty(handle.masterFileDescriptor), 1)
        XCTAssertNotEqual(fcntl(handle.masterFileDescriptor, F_GETFL) & O_NONBLOCK, 0)
        XCTAssertNotEqual(fcntl(handle.masterFileDescriptor, F_GETFD) & FD_CLOEXEC, 0)

        let client = try XCTUnwrap(
            fixture.waitForClient(processID: handle.childProcessID, timeout: 3)
        )
        XCTAssertTrue(client.tty.hasPrefix("/dev/ttys"))
        XCTAssertEqual(client.sessionID, target.sessionID)
        XCTAssertEqual(client.windowID, target.windowID)
        XCTAssertEqual(client.columns, 80)
        XCTAssertEqual(client.rows, 24)
        XCTAssertTrue(
            fixture.waitForWindowGeometry(
                windowID: target.windowID,
                expected: "80|23",
                timeout: 2
            )
        )

        try controller.close(masterFileDescriptor: handle.masterFileDescriptor)
        didCloseMaster = true
        let childExit = try waitForChildExit(
            controller: controller,
            childProcessID: handle.childProcessID,
            timeout: 3
        )
        XCTAssertNotNil(childExit)
        didReapChild = childExit != nil
        XCTAssertTrue(fixture.waitForClientCount(0, timeout: 2))
    }

    func testAttachProofRequiresExactSpawnedClientTTYSessionWindowAndReportsActivePane() throws {
        guard let tmuxPath = TmuxStateResolver.discoverTmuxBinaryPath() else {
            throw XCTSkip("tmux is unavailable")
        }

        let fixture = try InteractivePTYTmuxFixture(tmuxPath: tmuxPath)
        defer { fixture.shutdown() }
        let target = try fixture.startWithNonCurrentTargetWindow()
        let controller = TmuxInteractivePTYController()
        let handle = try controller.spawn(
            TmuxInteractivePTYAttachCommand(
                tmuxExecutablePath: tmuxPath,
                socket: .path(fixture.socketPath),
                sessionID: target.sessionID,
                windowID: target.windowID,
                initialSize: TmuxInteractivePTYSize(columns: 80, rows: 24)
            )
        )
        var didCloseMaster = false
        var didReapChild = false
        defer {
            if didCloseMaster == false {
                try? controller.close(masterFileDescriptor: handle.masterFileDescriptor)
            }
            if didReapChild == false {
                reapForCleanup(controller: controller, childProcessID: handle.childProcessID)
            }
        }

        let expectedProof = TmuxInteractiveAttachProof(
            workspaceID: "workspace-1",
            panelID: "panel-1",
            sessionID: target.sessionID,
            windowID: target.windowID,
            paneID: target.paneID
        )
        let prover = TmuxInteractiveAttachProver(
            commandRunner: OrdinaryTmuxCLIAdapter.processCommandRunner(
                executablePath: tmuxPath,
                timeoutSeconds: 3
            )
        )
        let claim = TmuxInteractiveAttachClaim(
            socket: .path(fixture.socketPath),
            childProcessID: handle.childProcessID,
            workspaceID: expectedProof.workspaceID,
            panelID: expectedProof.panelID,
            sessionID: expectedProof.sessionID,
            windowID: expectedProof.windowID
        )
        let verified = try XCTUnwrap(
            waitForAttachProof(prover: prover, claim: claim, timeout: 3)
        )
        XCTAssertEqual(verified.attachProof, expectedProof)
        XCTAssertEqual(verified.childProcessID, handle.childProcessID)
        XCTAssertTrue(verified.clientTTY.hasPrefix("/dev/ttys"))

        XCTAssertNil(try prover.prove(claim.replacing(childProcessID: handle.childProcessID + 1)))
        XCTAssertNil(try prover.prove(claim.replacing(sessionID: "$999999")))
        XCTAssertNil(try prover.prove(claim.replacing(windowID: "@999999")))

        try controller.close(masterFileDescriptor: handle.masterFileDescriptor)
        didCloseMaster = true
        let childExit = try waitForChildExit(
            controller: controller,
            childProcessID: handle.childProcessID,
            timeout: 3
        )
        XCTAssertNotNil(childExit)
        didReapChild = childExit != nil
        XCTAssertTrue(fixture.waitForClientCount(0, timeout: 2))
    }

    func testGenerationFencedResizeAppliesLatestValidPhoneViewportToRealClient() throws {
        guard let tmuxPath = TmuxStateResolver.discoverTmuxBinaryPath() else {
            throw XCTSkip("tmux is unavailable")
        }

        let fixture = try InteractivePTYTmuxFixture(tmuxPath: tmuxPath)
        defer { fixture.shutdown() }
        let target = try fixture.startWithNonCurrentTargetWindow()
        let controller = TmuxInteractivePTYController()
        let initialSize = TmuxInteractivePTYSize(columns: 80, rows: 24)
        let handle = try controller.spawn(
            TmuxInteractivePTYAttachCommand(
                tmuxExecutablePath: tmuxPath,
                socket: .path(fixture.socketPath),
                sessionID: target.sessionID,
                windowID: target.windowID,
                initialSize: initialSize
            )
        )
        var didCloseMaster = false
        var didReapChild = false
        defer {
            if didCloseMaster == false {
                try? controller.close(masterFileDescriptor: handle.masterFileDescriptor)
            }
            if didReapChild == false {
                reapForCleanup(controller: controller, childProcessID: handle.childProcessID)
            }
        }

        _ = try XCTUnwrap(
            fixture.waitForClient(processID: handle.childProcessID, timeout: 3)
        )
        let binding = TmuxInteractiveSubscriptionBinding(
            subscriptionID: "interactive-1",
            generation: 7
        )
        let gate = TmuxInteractivePTYResizeGate(
            binding: binding,
            masterFileDescriptor: handle.masterFileDescriptor,
            initialSize: initialSize,
            controller: controller
        )
        XCTAssertFalse(
            try gate.apply(
                TmuxInteractiveResize(
                    binding: TmuxInteractiveSubscriptionBinding(
                        subscriptionID: binding.subscriptionID,
                        generation: binding.generation - 1
                    ),
                    viewport: TmuxInteractiveViewport(columns: 120, rows: 40)
                )
            )
        )
        let invalidViewport = TmuxInteractiveViewport(columns: 0, rows: 24)
        XCTAssertThrowsError(
            try gate.apply(TmuxInteractiveResize(binding: binding, viewport: invalidViewport))
        ) { error in
            XCTAssertEqual(
                error as? TmuxInteractivePTYResizeGateError,
                .invalidViewport(invalidViewport)
            )
        }

        for viewport in [
            TmuxInteractiveViewport(columns: 60, rows: 20),
            TmuxInteractiveViewport(columns: 80, rows: 25),
            TmuxInteractiveViewport(columns: 50, rows: 18),
        ] {
            XCTAssertTrue(
                try gate.apply(TmuxInteractiveResize(binding: binding, viewport: viewport))
            )
            XCTAssertTrue(
                fixture.waitForClientSize(
                    processID: handle.childProcessID,
                    columns: viewport.columns,
                    rows: viewport.rows,
                    timeout: 2
                )
            )
            XCTAssertFalse(
                try gate.apply(TmuxInteractiveResize(binding: binding, viewport: viewport))
            )
        }

        gate.retire()
        XCTAssertFalse(
            try gate.apply(
                TmuxInteractiveResize(
                    binding: binding,
                    viewport: TmuxInteractiveViewport(columns: 100, rows: 30)
                )
            )
        )
        XCTAssertTrue(
            fixture.waitForClientSize(
                processID: handle.childProcessID,
                columns: 50,
                rows: 18,
                timeout: 1
            )
        )

        try controller.close(masterFileDescriptor: handle.masterFileDescriptor)
        didCloseMaster = true
        let childExit = try waitForChildExit(
            controller: controller,
            childProcessID: handle.childProcessID,
            timeout: 3
        )
        XCTAssertNotNil(childExit)
        didReapChild = childExit != nil
        XCTAssertTrue(fixture.waitForClientCount(0, timeout: 2))
    }

    func testLazyWindowSizeMigrationRestoresOnlyExactTargetOnIsolatedSocket() throws {
        guard let tmuxPath = TmuxStateResolver.discoverTmuxBinaryPath() else {
            throw XCTSkip("tmux is unavailable")
        }

        let fixture = try InteractivePTYTmuxFixture(tmuxPath: tmuxPath)
        defer { fixture.shutdown() }
        let target = try fixture.startWithNonCurrentTargetWindow()
        let socket = OrdinaryTmuxSocketSelector.path(fixture.socketPath)
        let commandRunner = OrdinaryTmuxCLIAdapter.processCommandRunner(
            executablePath: tmuxPath,
            timeoutSeconds: 3
        )
        let windowIDs = try commandRunner(
            socket,
            ["list-windows", "-t", target.sessionID, "-F", "#{window_id}"],
            nil
        ).split(whereSeparator: \.isNewline).map(String.init)
        let otherWindowID = try XCTUnwrap(windowIDs.first { $0 != target.windowID })
        _ = try commandRunner(
            socket,
            [
                "set-option", "-w", "-t", target.windowID,
                "@tidey_window_size_before_multi_client", "latest",
            ],
            nil
        )
        _ = try commandRunner(
            socket,
            ["set-option", "-w", "-t", target.windowID, "window-size", "largest"],
            nil
        )
        _ = try commandRunner(
            socket,
            [
                "set-option", "-w", "-t", otherWindowID,
                "@tidey_window_size_before_multi_client", "untouched",
            ],
            nil
        )
        let migrator = TmuxInteractiveWindowSizeMigrator(commandRunner: commandRunner)

        XCTAssertEqual(
            try migrator.migrateIfEligible(
                socket: socket,
                windowID: target.windowID,
                hasLaterPolicyChangeEvidence: false
            ),
            .migrated(
                TmuxInteractiveWindowSizeMigration(
                    windowID: target.windowID,
                    expectedCurrentPolicy: "largest",
                    restoredPolicy: "latest",
                    markerOption: "@tidey_window_size_before_multi_client",
                    expectedMarkerValue: "latest"
                )
            )
        )
        XCTAssertEqual(
            try commandRunner(
                socket,
                [
                    "display-message", "-p", "-t", target.windowID,
                    "TIDEYv1|#{window-size}|#{@tidey_window_size_before_multi_client}|END",
                ],
                nil
            ),
            "TIDEYv1|latest||END"
        )
        XCTAssertEqual(
            try commandRunner(
                socket,
                [
                    "display-message", "-p", "-t", otherWindowID,
                    "TIDEYv1|#{window-size}|#{@tidey_window_size_before_multi_client}|END",
                ],
                nil
            ),
            "TIDEYv1|latest|untouched|END"
        )
        XCTAssertEqual(
            try migrator.migrateIfEligible(
                socket: socket,
                windowID: target.windowID,
                hasLaterPolicyChangeEvidence: false
            ),
            .notEligible(.currentPolicyNotOwned("latest"))
        )
    }

    func testSessionOwnerHoldsRealPTYLeaseUntilCloseAndReapComplete() throws {
        guard let tmuxPath = TmuxStateResolver.discoverTmuxBinaryPath() else {
            throw XCTSkip("tmux is unavailable")
        }

        let fixture = try InteractivePTYTmuxFixture(tmuxPath: tmuxPath)
        defer { fixture.shutdown() }
        let target = try fixture.startWithNonCurrentTargetWindow()
        let route = OrdinaryTmuxPanelRoute(
            workspaceID: "workspace-1",
            panelID: "panel-1",
            carrierPanelID: "carrier-1",
            socket: .path(fixture.socketPath),
            sessionID: target.sessionID,
            sessionName: "pty-exact",
            windowID: target.windowID,
            windowIndex: 1,
            activePaneID: target.paneID,
            cwd: nil,
            currentCommand: "zsh"
        )
        let binding = TmuxInteractiveSubscriptionBinding(
            subscriptionID: "interactive-owner-1",
            generation: 11
        )
        let store = OrdinaryTmuxInputSubmissionStore()
        let owner = TmuxInteractivePTYSessionOwner(
            admissionStore: store,
            controller: TmuxInteractivePTYController()
        )
        var didClose = false
        defer {
            if didClose == false {
                try? owner.close()
            }
        }
        try owner.begin(
            TmuxInteractivePTYSessionStartRequest(
                subscribe: TmuxInteractiveSubscribe(
                    workspaceID: route.workspaceID,
                    panelID: route.panelID,
                    binding: binding,
                    viewport: TmuxInteractiveViewport(columns: 80, rows: 24)
                ),
                route: route,
                tmuxExecutablePath: tmuxPath
            )
        )
        XCTAssertTrue(fixture.waitForClientCount(1, timeout: 3))
        let input = TmuxInteractiveInput(
            binding: binding,
            bytes: Data([0x02, 0x63])
        )
        XCTAssertThrowsError(try owner.sendInput(input)) { error in
            XCTAssertEqual(
                error as? TmuxInteractivePTYSessionOwnerError,
                .inputNotEnabled(.proving)
            )
        }
        let verifiedAttach = try XCTUnwrap(
            waitForSessionOwnerProof(owner: owner, timeout: 3)
        )
        XCTAssertEqual(
            verifiedAttach.attachProof,
            TmuxInteractiveAttachProof(
                workspaceID: route.workspaceID,
                panelID: route.panelID,
                sessionID: route.sessionID,
                windowID: route.windowID,
                paneID: route.activePaneID
            )
        )
        XCTAssertTrue(verifiedAttach.clientTTY.hasPrefix("/dev/ttys"))
        XCTAssertEqual(owner.lifecycleState, .redrawing)
        XCTAssertThrowsError(try owner.sendInput(input)) { error in
            XCTAssertEqual(
                error as? TmuxInteractivePTYSessionOwnerError,
                .inputNotEnabled(.redrawing)
            )
        }
        let authoritativeStart = try XCTUnwrap(
            waitForSessionOwnerStart(owner: owner, timeout: 3)
        )
        XCTAssertEqual(authoritativeStart.binding, binding)
        XCTAssertEqual(authoritativeStart.attachProof, verifiedAttach.attachProof)
        XCTAssertEqual(
            authoritativeStart.viewport,
            TmuxInteractiveViewport(columns: 80, rows: 24)
        )
        XCTAssertFalse(authoritativeStart.initialBytes.isEmpty)
        XCTAssertEqual(owner.lifecycleState, .live)
        let phoneViewport = TmuxInteractiveViewport(columns: 60, rows: 20)
        let phoneResize = TmuxInteractiveResize(
            binding: binding,
            viewport: phoneViewport
        )
        XCTAssertTrue(try owner.applyResize(phoneResize))
        XCTAssertTrue(
            fixture.waitForClientSize(
                processID: verifiedAttach.childProcessID,
                columns: phoneViewport.columns,
                rows: phoneViewport.rows,
                timeout: 2
            )
        )
        XCTAssertFalse(try owner.applyResize(phoneResize))
        XCTAssertEqual(try owner.sendInput(input), .written(input.bytes.count))
        XCTAssertTrue(
            fixture.waitForWindowCount(
                sessionID: target.sessionID,
                expected: 3,
                timeout: 2
            )
        )
        let sessionKey = OrdinaryTmuxSessionKey(
            socket: route.socket,
            sessionID: route.sessionID
        )
        XCTAssertFalse(
            store.reserve(
                submissionID: "blocked-while-owned",
                routeKey: "blocked-while-owned-route",
                sessionKey: sessionKey
            )
        )

        let detachInput = TmuxInteractiveInput(
            binding: binding,
            bytes: Data([0x02, 0x64])
        )
        XCTAssertEqual(
            try owner.sendInput(detachInput),
            .written(detachInput.bytes.count)
        )
        let terminal = try XCTUnwrap(
            waitForSessionOwnerTerminal(owner: owner, timeout: 3)
        )
        XCTAssertEqual(
            terminal.chunks.map(\.sequence),
            terminal.chunks.indices.map { UInt64($0 + 1) }
        )
        XCTAssertTrue(terminal.chunks.allSatisfy { $0.binding == binding })
        XCTAssertEqual(
            terminal.state,
            TmuxInteractiveStateChange(
                binding: binding,
                state: .detached,
                message: nil
            )
        )
        didClose = true
        XCTAssertEqual(owner.lifecycleState, .closed)
        XCTAssertTrue(fixture.waitForClientCount(0, timeout: 2))
        XCTAssertEqual(try fixture.windowCount(sessionID: target.sessionID), 3)
        usleep(100_000)
        XCTAssertEqual(try fixture.clientCount(), 0)
        XCTAssertTrue(
            store.reserve(
                submissionID: "admitted-after-reap",
                routeKey: "admitted-after-reap-route",
                sessionKey: sessionKey
            )
        )
    }

    func testRealPTYForwardsOpaqueBytesThroughTmuxKeyTableAndDetachesNormally() throws {
        guard let tmuxPath = TmuxStateResolver.discoverTmuxBinaryPath() else {
            throw XCTSkip("tmux is unavailable")
        }

        let fixture = try InteractivePTYTmuxFixture(tmuxPath: tmuxPath)
        defer { fixture.shutdown() }
        let target = try fixture.startWithNonCurrentTargetWindow()
        let controller = TmuxInteractivePTYController()
        let handle = try controller.spawn(
            TmuxInteractivePTYAttachCommand(
                tmuxExecutablePath: tmuxPath,
                socket: .path(fixture.socketPath),
                sessionID: target.sessionID,
                windowID: target.windowID,
                initialSize: TmuxInteractivePTYSize(columns: 80, rows: 24)
            )
        )
        var didCloseMaster = false
        var didReapChild = false
        defer {
            if didCloseMaster == false {
                try? controller.close(masterFileDescriptor: handle.masterFileDescriptor)
            }
            if didReapChild == false {
                reapForCleanup(controller: controller, childProcessID: handle.childProcessID)
            }
        }

        _ = try XCTUnwrap(
            fixture.waitForClient(processID: handle.childProcessID, timeout: 3)
        )
        XCTAssertEqual(try fixture.windowCount(sessionID: target.sessionID), 2)
        XCTAssertFalse(
            try readFirstBytes(
                controller: controller,
                masterFileDescriptor: handle.masterFileDescriptor,
                timeout: 2
            ).isEmpty
        )

        try writeAll(
            Data([0x02, 0x63]),
            controller: controller,
            masterFileDescriptor: handle.masterFileDescriptor,
            timeout: 2
        )
        XCTAssertTrue(
            fixture.waitForWindowCount(
                sessionID: target.sessionID,
                expected: 3,
                timeout: 2
            )
        )

        try writeAll(
            Data([0x02, 0x64]),
            controller: controller,
            masterFileDescriptor: handle.masterFileDescriptor,
            timeout: 2
        )
        let childExit = try waitForChildExit(
            controller: controller,
            childProcessID: handle.childProcessID,
            timeout: 3
        )
        XCTAssertEqual(childExit?.rawStatus, 0)
        didReapChild = childExit != nil
        XCTAssertTrue(fixture.waitForClientCount(0, timeout: 2))
        XCTAssertTrue(
            try waitForEndOfFile(
                controller: controller,
                masterFileDescriptor: handle.masterFileDescriptor,
                timeout: 2
            )
        )

        try controller.close(masterFileDescriptor: handle.masterFileDescriptor)
        didCloseMaster = true
        usleep(100_000)
        XCTAssertEqual(try fixture.clientCount(), 0)
        XCTAssertEqual(try fixture.windowCount(sessionID: target.sessionID), 3)
    }

    private func readFirstBytes(
        controller: TmuxInteractivePTYControlling,
        masterFileDescriptor: Int32,
        timeout: TimeInterval
    ) throws -> Data {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            switch try controller.read(
                masterFileDescriptor: masterFileDescriptor,
                maximumBytes: 16 * 1_024
            ) {
            case .bytes(let bytes):
                return bytes
            case .wouldBlock:
                usleep(20_000)
            case .endOfFile:
                throw TestError.unexpectedEndOfFile
            }
        } while Date() < deadline
        throw TestError.readTimedOut
    }

    private func writeAll(
        _ bytes: Data,
        controller: TmuxInteractivePTYControlling,
        masterFileDescriptor: Int32,
        timeout: TimeInterval
    ) throws {
        let deadline = Date().addingTimeInterval(timeout)
        var offset = 0
        while offset < bytes.count, Date() < deadline {
            let remaining = bytes.subdata(in: offset..<bytes.count)
            switch try controller.write(
                remaining,
                masterFileDescriptor: masterFileDescriptor
            ) {
            case .written(let count):
                guard count > 0, count <= remaining.count else {
                    throw TestError.invalidWriteProgress(count)
                }
                offset += count
            case .wouldBlock:
                usleep(20_000)
            }
        }
        guard offset == bytes.count else {
            throw TestError.writeTimedOut
        }
    }

    private func waitForEndOfFile(
        controller: TmuxInteractivePTYControlling,
        masterFileDescriptor: Int32,
        timeout: TimeInterval
    ) throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            switch try controller.read(
                masterFileDescriptor: masterFileDescriptor,
                maximumBytes: 16 * 1_024
            ) {
            case .bytes:
                continue
            case .wouldBlock:
                usleep(20_000)
            case .endOfFile:
                return true
            }
        } while Date() < deadline
        return false
    }

    private func waitForChildExit(
        controller: TmuxInteractivePTYControlling,
        childProcessID: Int32,
        timeout: TimeInterval
    ) throws -> TmuxInteractivePTYChildExit? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let childExit = try controller.reap(
                childProcessID: childProcessID,
                blocking: false
            ) {
                return childExit
            }
            usleep(20_000)
        } while Date() < deadline
        return try controller.reap(childProcessID: childProcessID, blocking: false)
    }

    private func waitForAttachProof(
        prover: TmuxInteractiveAttachProving,
        claim: TmuxInteractiveAttachClaim,
        timeout: TimeInterval
    ) throws -> TmuxInteractiveVerifiedAttach? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let proof = try prover.prove(claim) {
                return proof
            }
            usleep(20_000)
        } while Date() < deadline
        return try prover.prove(claim)
    }

    private func waitForSessionOwnerProof(
        owner: TmuxInteractivePTYSessionOwner,
        timeout: TimeInterval
    ) throws -> TmuxInteractiveVerifiedAttach? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let proof = try owner.pollAttachProof() {
                return proof
            }
            usleep(20_000)
        } while Date() < deadline
        return try owner.pollAttachProof()
    }

    private func waitForSessionOwnerStart(
        owner: TmuxInteractivePTYSessionOwner,
        timeout: TimeInterval
    ) throws -> TmuxInteractiveAuthoritativeStart? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let start = try owner.pollAuthoritativeStart() {
                return start
            }
            usleep(20_000)
        } while Date() < deadline
        return try owner.pollAuthoritativeStart()
    }

    private func waitForSessionOwnerTerminal(
        owner: TmuxInteractivePTYSessionOwner,
        timeout: TimeInterval
    ) throws -> (chunks: [TmuxInteractiveOutputChunk], state: TmuxInteractiveStateChange)? {
        var chunks: [TmuxInteractiveOutputChunk] = []
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            switch try owner.pollLiveOutput() {
            case .output(let chunk):
                chunks.append(chunk)
            case .wouldBlock:
                usleep(20_000)
            case .terminal(let state):
                return (chunks, state)
            }
        } while Date() < deadline
        return nil
    }

    private func reapForCleanup(
        controller: TmuxInteractivePTYControlling,
        childProcessID: Int32
    ) {
        do {
            if try waitForChildExit(
                controller: controller,
                childProcessID: childProcessID,
                timeout: 1
            ) != nil {
                return
            }
        } catch let error as TmuxInteractivePTYControllerError {
            if case .operationFailed(let operation, let code) = error,
               operation == "reap",
               code == ECHILD {
                return
            }
        } catch {
            // Continue with bounded cleanup of the exact spawned child.
        }
        _ = kill(childProcessID, SIGHUP)
        _ = try? controller.reap(childProcessID: childProcessID, blocking: true)
    }
}

private struct InteractivePTYTmuxTarget {
    let sessionID: String
    let windowID: String
    let paneID: String
}

private extension TmuxInteractiveAttachClaim {
    func replacing(childProcessID: Int32) -> Self {
        Self(
            socket: socket,
            childProcessID: childProcessID,
            workspaceID: workspaceID,
            panelID: panelID,
            sessionID: sessionID,
            windowID: windowID
        )
    }

    func replacing(sessionID: String) -> Self {
        Self(
            socket: socket,
            childProcessID: childProcessID,
            workspaceID: workspaceID,
            panelID: panelID,
            sessionID: sessionID,
            windowID: windowID
        )
    }

    func replacing(windowID: String) -> Self {
        Self(
            socket: socket,
            childProcessID: childProcessID,
            workspaceID: workspaceID,
            panelID: panelID,
            sessionID: sessionID,
            windowID: windowID
        )
    }
}

private struct InteractivePTYTmuxClientRecord {
    enum ParsingError: Error {
        case invalidRecord(String)
    }

    let processID: Int32
    let tty: String
    let sessionID: String
    let windowID: String
    let columns: Int
    let rows: Int
    let flags: Set<String>

    init(record: Substring) throws {
        let fields = record.split(separator: "|", omittingEmptySubsequences: false)
        guard fields.count == 7,
              let processID = Int32(fields[0]),
              let columns = Int(fields[4]),
              let rows = Int(fields[5]) else {
            throw ParsingError.invalidRecord(String(record))
        }
        self.processID = processID
        tty = String(fields[1])
        sessionID = String(fields[2])
        windowID = String(fields[3])
        self.columns = columns
        self.rows = rows
        flags = Set(fields[6].split(separator: ",").map(String.init))
    }
}

private final class InteractivePTYTmuxFixture {
    enum FixtureError: Error, CustomStringConvertible {
        case invalidRecord(String)
        case commandFailed(arguments: [String], status: Int32, stderr: String)
        case commandTimedOut(arguments: [String])

        var description: String {
            switch self {
            case .invalidRecord(let record):
                return "invalid tmux record: \(record)"
            case .commandFailed(let arguments, let status, let stderr):
                return "tmux command failed (\(status)): \(arguments.joined(separator: " ")): \(stderr)"
            case .commandTimedOut(let arguments):
                return "tmux command timed out: \(arguments.joined(separator: " "))"
            }
        }
    }

    let socketPath: String

    private let tmuxPath: String
    private let rootURL: URL
    private var hasStartedServer = false
    private var isShutDown = false

    init(tmuxPath: String) throws {
        self.tmuxPath = tmuxPath
        let temporaryRoot = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .standardizedFileURL
        rootURL = temporaryRoot
            .appendingPathComponent("tidey-tmux-pty-\(UUID().uuidString.prefix(12))", isDirectory: true)
            .standardizedFileURL
        let candidateSocketPath = rootURL.appendingPathComponent("socket").path
        guard rootURL.path.hasPrefix(temporaryRoot.path + "/"),
              candidateSocketPath.utf8.count < 100 else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: false
        )
        socketPath = candidateSocketPath
    }

    func startWithNonCurrentTargetWindow() throws -> InteractivePTYTmuxTarget {
        let first = try run([
            "-f", "/dev/null",
            "new-session", "-d",
            "-P", "-F", "#{session_id}|#{window_id}",
            "-s", "pty-exact",
            "-x", "132",
            "-y", "37",
        ])
        hasStartedServer = true
        let firstFields = first.split(separator: "|", omittingEmptySubsequences: false)
        guard firstFields.count == 2 else {
            throw FixtureError.invalidRecord(first)
        }
        let sessionID = String(firstFields[0])
        let target = try run([
            "new-window", "-d",
            "-P", "-F", "#{session_id}|#{window_id}|#{pane_id}",
            "-t", sessionID,
            "-n", "phone-target",
        ])
        let targetFields = target.split(separator: "|", omittingEmptySubsequences: false)
        guard targetFields.count == 3,
              targetFields[0] == Substring(sessionID) else {
            throw FixtureError.invalidRecord(target)
        }
        return InteractivePTYTmuxTarget(
            sessionID: sessionID,
            windowID: String(targetFields[1]),
            paneID: String(targetFields[2])
        )
    }

    func waitForClient(
        processID: Int32,
        timeout: TimeInterval
    ) -> InteractivePTYTmuxClientRecord? {
        var matched: InteractivePTYTmuxClientRecord?
        _ = waitUntil(timeout: timeout) {
            matched = try? self.clientRecords().first { $0.processID == processID }
            return matched != nil
        }
        return matched
    }

    func waitForClientCount(_ expected: Int, timeout: TimeInterval) -> Bool {
        waitUntil(timeout: timeout) {
            (try? self.clientRecords().count) == expected
        }
    }

    func waitForClientSize(
        processID: Int32,
        columns: Int,
        rows: Int,
        timeout: TimeInterval
    ) -> Bool {
        waitUntil(timeout: timeout) {
            (try? self.clientRecords().contains {
                $0.processID == processID &&
                    $0.columns == columns &&
                    $0.rows == rows
            }) == true
        }
    }

    func clientCount() throws -> Int {
        try clientRecords().count
    }

    func windowCount(sessionID: String) throws -> Int {
        let output = try run([
            "list-windows",
            "-t", sessionID,
            "-F", "#{window_id}",
        ])
        return output.split(whereSeparator: \.isNewline).count
    }

    func waitForWindowCount(
        sessionID: String,
        expected: Int,
        timeout: TimeInterval
    ) -> Bool {
        waitUntil(timeout: timeout) {
            (try? self.windowCount(sessionID: sessionID)) == expected
        }
    }

    func waitForWindowGeometry(
        windowID: String,
        expected: String,
        timeout: TimeInterval
    ) -> Bool {
        waitUntil(timeout: timeout) {
            (try? self.run([
                "display-message", "-p",
                "-t", windowID,
                "#{window_width}|#{window_height}",
            ])) == expected
        }
    }

    func shutdown() {
        guard isShutDown == false else { return }
        isShutDown = true
        if hasStartedServer {
            _ = try? run(["kill-server"])
        }
        try? FileManager.default.removeItem(at: rootURL)
    }

    private func clientRecords() throws -> [InteractivePTYTmuxClientRecord] {
        let output = try run([
            "list-clients",
            "-F", "#{client_pid}|#{client_tty}|#{session_id}|#{window_id}|#{client_width}|#{client_height}|#{client_flags}",
        ])
        return try output.split(whereSeparator: \.isNewline).map {
            try InteractivePTYTmuxClientRecord(record: $0)
        }
    }

    private func run(_ commandArguments: [String]) throws -> String {
        let arguments = ["-S", socketPath] + commandArguments
        guard let result = BoundedProcessRunner.run(
            executablePath: tmuxPath,
            arguments: arguments,
            timeout: 3,
            circuitBreakerCooldown: 0
        ) else {
            throw FixtureError.commandTimedOut(arguments: arguments)
        }
        guard result.terminationStatus == 0 else {
            throw FixtureError.commandFailed(
                arguments: arguments,
                status: result.terminationStatus,
                stderr: String(decoding: result.standardError, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return String(decoding: result.standardOutput, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func waitUntil(
        timeout: TimeInterval,
        predicate: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if predicate() {
                return true
            }
            usleep(20_000)
        } while Date() < deadline
        return predicate()
    }
}

private func withNonUTF8ProcessLocale<Result>(
    _ body: () throws -> Result
) rethrows -> Result {
    let variableNames = ["LANG", "LC_ALL", "LC_CTYPE"]
    let originalValues = Dictionary(uniqueKeysWithValues: variableNames.map { name in
        (name, getenv(name).map { String(cString: $0) })
    })

    for name in variableNames {
        unsetenv(name)
    }
    setenv("LANG", "C", 1)
    defer {
        for name in variableNames {
            if let value = originalValues[name] ?? nil {
                setenv(name, value, 1)
            } else {
                unsetenv(name)
            }
        }
    }
    return try body()
}
