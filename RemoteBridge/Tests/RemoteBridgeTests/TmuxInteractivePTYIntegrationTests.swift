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

    func testRealPTYForcesUTF8WhenBridgeLocaleIsNotUTF8() throws {
        guard let tmuxPath = TmuxStateResolver.discoverTmuxBinaryPath() else {
            throw XCTSkip("tmux is unavailable")
        }

        let fixture = try InteractivePTYTmuxFixture(tmuxPath: tmuxPath)
        defer { fixture.shutdown() }
        let target = try fixture.startWithNonCurrentTargetWindow()
        let controller = TmuxInteractivePTYController()
        let handle = try withNonUTF8ProcessLocale {
            try controller.spawn(
                TmuxInteractivePTYAttachCommand(
                    tmuxExecutablePath: tmuxPath,
                    socket: .path(fixture.socketPath),
                    sessionID: target.sessionID,
                    windowID: target.windowID,
                    initialSize: TmuxInteractivePTYSize(columns: 80, rows: 24)
                )
            )
        }
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

        let client = try XCTUnwrap(
            fixture.waitForClient(processID: handle.childProcessID, timeout: 3)
        )
        XCTAssertTrue(
            client.flags.contains("UTF-8"),
            "the Bridge-owned tmux client must preserve CJK cells even without a UTF-8 daemon locale"
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

    func testRealPTYResizeImmediatelyEmitsAuthoritativeRedrawWithoutUserInput() throws {
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
        XCTAssertFalse(
            try readFirstBytes(
                controller: controller,
                masterFileDescriptor: handle.masterFileDescriptor,
                timeout: 2
            ).isEmpty
        )
        try drainAvailableBytes(
            controller: controller,
            masterFileDescriptor: handle.masterFileDescriptor
        )

        let binding = TmuxInteractiveSubscriptionBinding(
            subscriptionID: "interactive-redraw",
            generation: 1
        )
        let resizedViewport = TmuxInteractiveViewport(columns: 60, rows: 20)
        let gate = TmuxInteractivePTYResizeGate(
            binding: binding,
            masterFileDescriptor: handle.masterFileDescriptor,
            initialSize: initialSize,
            controller: controller
        )
        XCTAssertTrue(
            try gate.apply(
                TmuxInteractiveResize(binding: binding, viewport: resizedViewport)
            )
        )
        XCTAssertTrue(
            fixture.waitForClientSize(
                processID: handle.childProcessID,
                columns: resizedViewport.columns,
                rows: resizedViewport.rows,
                timeout: 2
            )
        )

        let redraw = try readFirstBytes(
            controller: controller,
            masterFileDescriptor: handle.masterFileDescriptor,
            timeout: 2
        )
        let redrawText = String(decoding: redraw, as: UTF8.self)
        XCTAssertTrue(
            redrawText.contains("\u{1b}[1;\(resizedViewport.rows)r"),
            "resize repaint must establish the new full-height scroll region"
        )
        XCTAssertGreaterThanOrEqual(
            redrawText.components(separatedBy: "\u{1b}[K").count - 1,
            resizedViewport.rows - 1,
            "resize repaint must erase every pane row without waiting for user input"
        )
        XCTAssertTrue(
            redrawText.contains("\u{1b}[1;1H"),
            "resize repaint must address the pane from its new top-left origin"
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

    func testRealPTYClientRefreshEmitsAuthoritativeScreenWithoutPaneSignalOrInput() throws {
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

        let client = try XCTUnwrap(
            fixture.waitForClient(processID: handle.childProcessID, timeout: 3)
        )
        try drainUntilQuiet(
            controller: controller,
            masterFileDescriptor: handle.masterFileDescriptor,
            quietPeriod: 0.2,
            timeout: 2
        )

        try TmuxInteractiveClientRefreshRequester(
            tmuxExecutablePath: tmuxPath
        ).requestRefresh(
            TmuxInteractiveClientRefreshRequest(
                socket: .path(fixture.socketPath),
                clientTTY: client.tty
            )
        )

        let screen = try readBytesUntilQuiet(
            controller: controller,
            masterFileDescriptor: handle.masterFileDescriptor,
            quietPeriod: 0.2,
            timeout: 2
        )
        let screenText = String(decoding: screen, as: UTF8.self)
        XCTAssertTrue(
            screenText.contains("\u{1b}[1;1H"),
            screen.base64EncodedString()
        )
        XCTAssertGreaterThanOrEqual(
            screenText.components(separatedBy: "\u{1b}[K").count - 1,
            Int(initialSize.rows) - 1
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

    func testSessionOwnerPublishesCompleteFooterFromProvedAttachStream() throws {
        guard let tmuxPath = TmuxStateResolver.discoverTmuxBinaryPath() else {
            throw XCTSkip("tmux is unavailable")
        }
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/clang") else {
            throw XCTSkip("the isolated signal-aware TUI fixture requires clang")
        }

        let fixture = try InteractivePTYTmuxFixture(tmuxPath: tmuxPath)
        defer { fixture.shutdown() }
        let target = try fixture.startWithAttachResizeFooterTargetWindow()
        let route = OrdinaryTmuxPanelRoute(
            workspaceID: "workspace-footer",
            panelID: "panel-footer",
            carrierPanelID: "carrier-footer",
            socket: .path(fixture.socketPath),
            sessionID: target.sessionID,
            sessionName: "pty-exact",
            windowID: target.windowID,
            windowIndex: 1,
            activePaneID: target.paneID,
            cwd: nil,
            currentCommand: "sh"
        )
        let binding = TmuxInteractiveSubscriptionBinding(
            subscriptionID: "interactive-footer",
            generation: 12
        )
        let owner = TmuxInteractivePTYSessionOwner(
            admissionStore: OrdinaryTmuxInputSubmissionStore(),
            controller: TmuxInteractivePTYController(),
            attachProver: OneCycleDeferredAttachProver(
                underlying: TmuxInteractiveAttachProver(
                    tmuxExecutablePath: tmuxPath
                )
            ),
            authoritativeStartQuiescenceNanoseconds:
                TmuxInteractivePTYSessionOwner
                    .productionAuthoritativeStartQuiescenceNanoseconds
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
        _ = try XCTUnwrap(
            waitForSessionOwnerProof(owner: owner, timeout: 3)
        )

        let startedAt = Date()
        let start = try XCTUnwrap(
            waitForSessionOwnerStart(owner: owner, timeout: 2)
        )
        let paneProcessSnapshot = try fixture.paneProcessSnapshot(
            paneID: target.paneID
        )

        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 2)
        XCTAssertTrue(
            String(decoding: start.initialBytes, as: UTF8.self)
                .contains("gpt-5.6-sol xhigh"),
            paneProcessSnapshot
        )
        XCTAssertEqual(
            Array(try fixture.capturePaneLines(paneID: target.paneID).suffix(3)),
            [
                "> Summarize recent commits",
                "",
                "gpt-5.6-sol xhigh",
            ],
            paneProcessSnapshot
        )

        try owner.close()
        didClose = true
        XCTAssertTrue(fixture.waitForClientCount(0, timeout: 2))
        XCTAssertEqual(try fixture.windowCount(sessionID: target.sessionID), 1)
    }

    func testSessionOwnerRequiresSecondGenuineResizeForCompleteFooterAndRestoresSizingClientGeometry() throws {
        guard let tmuxPath = TmuxStateResolver.discoverTmuxBinaryPath() else {
            throw XCTSkip("tmux is unavailable")
        }
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/clang") else {
            throw XCTSkip("the isolated signal-aware TUI fixture requires clang")
        }

        let fixture = try InteractivePTYTmuxFixture(tmuxPath: tmuxPath)
        defer { fixture.shutdown() }
        let target = try fixture.startWithSecondResizeFooterTargetWindow()
        let controller = TmuxInteractivePTYController()
        let baselineHandle = try controller.spawn(
            TmuxInteractivePTYAttachCommand(
                tmuxExecutablePath: tmuxPath,
                socket: .path(fixture.socketPath),
                sessionID: target.sessionID,
                windowID: target.windowID,
                initialSize: TmuxInteractivePTYSize(columns: 132, rows: 37)
            )
        )
        var didCloseBaseline = false
        var didReapBaseline = false
        defer {
            if didCloseBaseline == false {
                try? controller.close(
                    masterFileDescriptor: baselineHandle.masterFileDescriptor
                )
            }
            if didReapBaseline == false {
                reapForCleanup(
                    controller: controller,
                    childProcessID: baselineHandle.childProcessID
                )
            }
        }
        _ = try XCTUnwrap(
            fixture.waitForClient(
                processID: baselineHandle.childProcessID,
                timeout: 3
            )
        )
        try drainUntilQuiet(
            controller: controller,
            masterFileDescriptor: baselineHandle.masterFileDescriptor,
            quietPeriod: 0.1,
            timeout: 2
        )

        let route = OrdinaryTmuxPanelRoute(
            workspaceID: "workspace-second-resize",
            panelID: "panel-second-resize",
            carrierPanelID: "carrier-second-resize",
            socket: .path(fixture.socketPath),
            sessionID: target.sessionID,
            sessionName: "pty-exact",
            windowID: target.windowID,
            windowIndex: 0,
            activePaneID: target.paneID,
            cwd: nil,
            currentCommand: "second-resize-footer"
        )
        let binding = TmuxInteractiveSubscriptionBinding(
            subscriptionID: "interactive-second-resize",
            generation: 13
        )
        let owner = TmuxInteractivePTYSessionOwner(
            admissionStore: OrdinaryTmuxInputSubmissionStore(),
            controller: controller,
            attachProver: TmuxInteractiveAttachProver(
                tmuxExecutablePath: tmuxPath
            ),
            clientRefreshRequester: TmuxInteractiveClientRefreshRequester(
                tmuxExecutablePath: tmuxPath
            ),
            authoritativeStartQuiescenceNanoseconds:
                TmuxInteractivePTYSessionOwner
                    .productionAuthoritativeStartQuiescenceNanoseconds,
            clientRefreshTimeoutNanoseconds:
                TmuxInteractivePTYSessionOwner
                    .productionClientRefreshTimeoutNanoseconds,
            requiresVerificationClientRefresh: true,
            verificationClientRefreshQuiescenceNanoseconds:
                TmuxInteractivePTYSessionOwner
                    .productionVerificationClientRefreshQuiescenceNanoseconds
        )
        var didCloseOwner = false
        defer {
            if didCloseOwner == false {
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

        let verifiedAttach = try XCTUnwrap(
            waitForSessionOwnerProof(owner: owner, timeout: 3)
        )
        XCTAssertTrue(
            fixture.waitForClientSize(
                processID: verifiedAttach.childProcessID,
                columns: 80,
                rows: 24,
                timeout: 2
            )
        )
        let start = try XCTUnwrap(
            waitForSessionOwnerStart(owner: owner, timeout: 3)
        )
        XCTAssertTrue(
            String(decoding: start.initialBytes, as: UTF8.self)
                .contains("gpt-5.6-sol xhigh")
        )
        XCTAssertEqual(
            Array(try fixture.capturePaneLines(paneID: target.paneID).suffix(3)),
            [
                "> Summarize recent commits",
                "",
                "gpt-5.6-sol xhigh",
            ]
        )

        try owner.close()
        didCloseOwner = true
        XCTAssertTrue(fixture.waitForClientCount(1, timeout: 2))
        XCTAssertTrue(
            fixture.waitForWindowGeometry(
                windowID: target.windowID,
                expected: "132|36",
                timeout: 2
            )
        )
        XCTAssertEqual(try fixture.windowCount(sessionID: target.sessionID), 1)
        XCTAssertTrue(
            try fixture.capturePaneLines(paneID: target.paneID)
                .contains("gpt-5.6-sol xhigh")
        )

        try controller.close(
            masterFileDescriptor: baselineHandle.masterFileDescriptor
        )
        didCloseBaseline = true
        let baselineExit = try waitForChildExit(
            controller: controller,
            childProcessID: baselineHandle.childProcessID,
            timeout: 3
        )
        XCTAssertNotNil(baselineExit)
        didReapBaseline = baselineExit != nil
    }

    func testSessionOwnerRepeatedAttachWithPersistentSameSizeClientPublishesEveryFinalFooter() throws {
        guard let tmuxPath = TmuxStateResolver.discoverTmuxBinaryPath() else {
            throw XCTSkip("tmux is unavailable")
        }
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/clang") else {
            throw XCTSkip("the isolated viewport-sensitive TUI fixture requires clang")
        }

        let fixture = try InteractivePTYTmuxFixture(tmuxPath: tmuxPath)
        defer { fixture.shutdown() }
        let target = try fixture.startWithViewportSensitiveFooterTargetWindow()
        let controller = TmuxInteractivePTYController()
        let persistentHandle = try controller.spawn(
            TmuxInteractivePTYAttachCommand(
                tmuxExecutablePath: tmuxPath,
                socket: .path(fixture.socketPath),
                sessionID: target.sessionID,
                windowID: target.windowID,
                initialSize: TmuxInteractivePTYSize(columns: 50, rows: 45)
            )
        )
        var didClosePersistent = false
        var didReapPersistent = false
        defer {
            if didClosePersistent == false {
                try? controller.close(
                    masterFileDescriptor: persistentHandle.masterFileDescriptor
                )
            }
            if didReapPersistent == false {
                reapForCleanup(
                    controller: controller,
                    childProcessID: persistentHandle.childProcessID
                )
            }
        }
        _ = try XCTUnwrap(
            fixture.waitForClient(
                processID: persistentHandle.childProcessID,
                timeout: 3
            )
        )
        try drainUntilQuiet(
            controller: controller,
            masterFileDescriptor: persistentHandle.masterFileDescriptor,
            quietPeriod: 0.1,
            timeout: 2
        )
        XCTAssertTrue(
            fixture.waitForWindowGeometry(
                windowID: target.windowID,
                expected: "50|44",
                timeout: 2
            )
        )

        let route = OrdinaryTmuxPanelRoute(
            workspaceID: "workspace-repeated-same-size",
            panelID: "panel-repeated-same-size",
            carrierPanelID: "carrier-repeated-same-size",
            socket: .path(fixture.socketPath),
            sessionID: target.sessionID,
            sessionName: "pty-exact",
            windowID: target.windowID,
            windowIndex: 0,
            activePaneID: target.paneID,
            cwd: nil,
            currentCommand: "viewport-sensitive-footer"
        )
        let store = OrdinaryTmuxInputSubmissionStore()

        for generation in 1...6 {
            let binding = TmuxInteractiveSubscriptionBinding(
                subscriptionID: "interactive-repeated-\(generation)",
                generation: UInt64(generation)
            )
            let owner = TmuxInteractivePTYSessionOwner(
                admissionStore: store,
                controller: controller,
                attachProver: TmuxInteractiveAttachProver(
                    tmuxExecutablePath: tmuxPath
                ),
                clientRefreshRequester: TmuxInteractiveClientRefreshRequester(
                    tmuxExecutablePath: tmuxPath
                ),
                authoritativeStartQuiescenceNanoseconds:
                    TmuxInteractivePTYSessionOwner
                        .productionAuthoritativeStartQuiescenceNanoseconds,
                clientRefreshTimeoutNanoseconds:
                    TmuxInteractivePTYSessionOwner
                        .productionClientRefreshTimeoutNanoseconds,
                requiresVerificationClientRefresh: true,
                verificationClientRefreshQuiescenceNanoseconds:
                    TmuxInteractivePTYSessionOwner
                        .productionVerificationClientRefreshQuiescenceNanoseconds
            )
            var didCloseOwner = false
            defer {
                if didCloseOwner == false {
                    try? owner.close()
                }
            }
            try owner.begin(
                TmuxInteractivePTYSessionStartRequest(
                    subscribe: TmuxInteractiveSubscribe(
                        workspaceID: route.workspaceID,
                        panelID: route.panelID,
                        binding: binding,
                        viewport: TmuxInteractiveViewport(columns: 50, rows: 45)
                    ),
                    route: route,
                    tmuxExecutablePath: tmuxPath
                )
            )

            _ = try XCTUnwrap(
                waitForSessionOwnerProof(owner: owner, timeout: 3),
                "attach proof missing on generation \(generation)"
            )
            let start = try XCTUnwrap(
                waitForSessionOwnerStart(owner: owner, timeout: 3),
                "authoritative start missing on generation \(generation)"
            )
            XCTAssertNil(
                start.bootstrapPhase,
                "Termius-style direct attach must not manufacture a second startup resize on generation \(generation)"
            )
            XCTAssertEqual(
                start.viewport,
                TmuxInteractiveViewport(columns: 50, rows: 45),
                "wrong final viewport on generation \(generation)"
            )
            let startText = String(decoding: start.initialBytes, as: UTF8.self)
            let lastPrompt = startText.range(
                of: "> Summarize recent commits",
                options: .backwards
            )
            let lastFooter = startText.range(
                of: "gpt-5.6-sol xhigh",
                options: .backwards
            )
            XCTAssertTrue(
                lastPrompt.map { prompt in
                    lastFooter.map { footer in prompt.lowerBound < footer.lowerBound }
                        ?? false
                } ?? false,
                "last final-size frame lacks footer on generation \(generation): "
                    + start.initialBytes.base64EncodedString()
            )
            XCTAssertTrue(
                fixture.waitForWindowGeometry(
                    windowID: target.windowID,
                    expected: "50|44",
                    timeout: 2
                ),
                "phone-client geometry was not active on generation \(generation)"
            )
            XCTAssertEqual(
                Array(try fixture.capturePaneLines(paneID: target.paneID).suffix(3)),
                [
                    "> Summarize recent commits",
                    "",
                    "gpt-5.6-sol xhigh",
                ],
                "pane footer incomplete on generation \(generation)"
            )

            try owner.close()
            didCloseOwner = true
            XCTAssertTrue(
                fixture.waitForClientCount(1, timeout: 2),
                "prior client did not fully detach on generation \(generation)"
            )
            XCTAssertTrue(
                fixture.waitForWindowGeometry(
                    windowID: target.windowID,
                    expected: "50|44",
                    timeout: 2
                ),
                "persistent-client geometry was not restored on generation \(generation)"
            )
        }

        try controller.close(
            masterFileDescriptor: persistentHandle.masterFileDescriptor
        )
        didClosePersistent = true
        let persistentExit = try waitForChildExit(
            controller: controller,
            childProcessID: persistentHandle.childProcessID,
            timeout: 3
        )
        XCTAssertNotNil(persistentExit)
        didReapPersistent = persistentExit != nil
    }

    func testSessionOwnerRepeatedAttachFromDifferentSizeClientPublishesEveryFinalFooter() throws {
        guard let tmuxPath = TmuxStateResolver.discoverTmuxBinaryPath() else {
            throw XCTSkip("tmux is unavailable")
        }
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/clang") else {
            throw XCTSkip("the isolated viewport-sensitive TUI fixture requires clang")
        }

        let fixture = try InteractivePTYTmuxFixture(tmuxPath: tmuxPath)
        defer { fixture.shutdown() }
        let target = try fixture.startWithViewportSensitiveFooterTargetWindow(
            redrawDelayMicroseconds: 250_000
        )
        let controller = TmuxInteractivePTYController()
        let persistentHandle = try controller.spawn(
            TmuxInteractivePTYAttachCommand(
                tmuxExecutablePath: tmuxPath,
                socket: .path(fixture.socketPath),
                sessionID: target.sessionID,
                windowID: target.windowID,
                initialSize: TmuxInteractivePTYSize(columns: 132, rows: 37)
            )
        )
        var didClosePersistent = false
        var didReapPersistent = false
        defer {
            if didClosePersistent == false {
                try? controller.close(
                    masterFileDescriptor: persistentHandle.masterFileDescriptor
                )
            }
            if didReapPersistent == false {
                reapForCleanup(
                    controller: controller,
                    childProcessID: persistentHandle.childProcessID
                )
            }
        }
        _ = try XCTUnwrap(
            fixture.waitForClient(
                processID: persistentHandle.childProcessID,
                timeout: 3
            )
        )
        try drainUntilQuiet(
            controller: controller,
            masterFileDescriptor: persistentHandle.masterFileDescriptor,
            quietPeriod: 0.1,
            timeout: 2
        )
        XCTAssertTrue(
            fixture.waitForWindowGeometry(
                windowID: target.windowID,
                expected: "132|36",
                timeout: 2
            )
        )

        let route = OrdinaryTmuxPanelRoute(
            workspaceID: "workspace-repeated-different-size",
            panelID: "panel-repeated-different-size",
            carrierPanelID: "carrier-repeated-different-size",
            socket: .path(fixture.socketPath),
            sessionID: target.sessionID,
            sessionName: "pty-exact",
            windowID: target.windowID,
            windowIndex: 0,
            activePaneID: target.paneID,
            cwd: nil,
            currentCommand: "viewport-sensitive-footer"
        )
        let store = OrdinaryTmuxInputSubmissionStore()

        for generation in 1...7 {
            let binding = TmuxInteractiveSubscriptionBinding(
                subscriptionID: "interactive-repeated-different-size-\(generation)",
                generation: UInt64(generation)
            )
            let owner = TmuxInteractivePTYSessionOwner(
                admissionStore: store,
                controller: controller,
                attachProver: TmuxInteractiveAttachProver(
                    tmuxExecutablePath: tmuxPath
                ),
                clientRefreshRequester: TmuxInteractiveClientRefreshRequester(
                    tmuxExecutablePath: tmuxPath
                ),
                authoritativeStartQuiescenceNanoseconds:
                    TmuxInteractivePTYSessionOwner
                        .productionAuthoritativeStartQuiescenceNanoseconds,
                clientRefreshTimeoutNanoseconds:
                    TmuxInteractivePTYSessionOwner
                        .productionClientRefreshTimeoutNanoseconds,
                requiresVerificationClientRefresh: true,
                verificationClientRefreshQuiescenceNanoseconds:
                    TmuxInteractivePTYSessionOwner
                        .productionVerificationClientRefreshQuiescenceNanoseconds
            )
            var didCloseOwner = false
            defer {
                if didCloseOwner == false {
                    try? owner.close()
                }
            }
            try owner.begin(
                TmuxInteractivePTYSessionStartRequest(
                    subscribe: TmuxInteractiveSubscribe(
                        workspaceID: route.workspaceID,
                        panelID: route.panelID,
                        binding: binding,
                        viewport: TmuxInteractiveViewport(columns: 50, rows: 45)
                    ),
                    route: route,
                    tmuxExecutablePath: tmuxPath
                )
            )

            _ = try XCTUnwrap(
                waitForSessionOwnerProof(owner: owner, timeout: 3),
                "attach proof missing on generation \(generation)"
            )
            let start = try XCTUnwrap(
                waitForSessionOwnerStart(owner: owner, timeout: 3),
                "authoritative start missing on generation \(generation)"
            )
            XCTAssertNil(start.bootstrapPhase)
            XCTAssertEqual(
                start.viewport,
                TmuxInteractiveViewport(columns: 50, rows: 45),
                "wrong final viewport on generation \(generation)"
            )
            let startText = String(decoding: start.initialBytes, as: UTF8.self)
            let lastPrompt = startText.range(
                of: "> Summarize recent commits",
                options: .backwards
            )
            let lastFooter = startText.range(
                of: "gpt-5.6-sol xhigh",
                options: .backwards
            )
            XCTAssertTrue(
                lastPrompt.map { prompt in
                    lastFooter.map { footer in prompt.lowerBound < footer.lowerBound }
                        ?? false
                } ?? false,
                "last final-size frame lacks footer on generation \(generation): "
                    + start.initialBytes.base64EncodedString()
            )
            XCTAssertTrue(
                fixture.waitForWindowGeometry(
                    windowID: target.windowID,
                    expected: "50|44",
                    timeout: 2
                ),
                "phone-client geometry was not active on generation \(generation)"
            )
            XCTAssertEqual(
                Array(try fixture.capturePaneLines(paneID: target.paneID).suffix(3)),
                [
                    "> Summarize recent commits",
                    "",
                    "gpt-5.6-sol xhigh",
                ],
                "pane footer incomplete on generation \(generation)"
            )

            try owner.close()
            didCloseOwner = true
            XCTAssertTrue(
                fixture.waitForClientCount(1, timeout: 2),
                "prior client did not fully detach on generation \(generation)"
            )
            XCTAssertTrue(
                fixture.waitForWindowGeometry(
                    windowID: target.windowID,
                    expected: "132|36",
                    timeout: 2
                ),
                "persistent-client geometry was not restored on generation \(generation)"
            )
        }

        try controller.close(
            masterFileDescriptor: persistentHandle.masterFileDescriptor
        )
        didClosePersistent = true
        let persistentExit = try waitForChildExit(
            controller: controller,
            childProcessID: persistentHandle.childProcessID,
            timeout: 3
        )
        XCTAssertNotNil(persistentExit)
        didReapPersistent = persistentExit != nil
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

    private func drainAvailableBytes(
        controller: TmuxInteractivePTYControlling,
        masterFileDescriptor: Int32
    ) throws {
        while true {
            switch try controller.read(
                masterFileDescriptor: masterFileDescriptor,
                maximumBytes: 16 * 1_024
            ) {
            case .bytes:
                continue
            case .wouldBlock:
                return
            case .endOfFile:
                throw TestError.unexpectedEndOfFile
            }
        }
    }

    private func drainUntilQuiet(
        controller: TmuxInteractivePTYControlling,
        masterFileDescriptor: Int32,
        quietPeriod: TimeInterval,
        timeout: TimeInterval
    ) throws {
        let deadline = Date().addingTimeInterval(timeout)
        var quietSince: Date?
        repeat {
            switch try controller.read(
                masterFileDescriptor: masterFileDescriptor,
                maximumBytes: 16 * 1_024
            ) {
            case .bytes:
                quietSince = nil
            case .wouldBlock:
                if let quietSince,
                   Date().timeIntervalSince(quietSince) >= quietPeriod {
                    return
                }
                if quietSince == nil {
                    quietSince = Date()
                }
                usleep(20_000)
            case .endOfFile:
                throw TestError.unexpectedEndOfFile
            }
        } while Date() < deadline
        throw TestError.readTimedOut
    }

    private func readBytesUntilQuiet(
        controller: TmuxInteractivePTYControlling,
        masterFileDescriptor: Int32,
        quietPeriod: TimeInterval,
        timeout: TimeInterval
    ) throws -> Data {
        let deadline = Date().addingTimeInterval(timeout)
        var bytes = Data()
        var quietSince: Date?
        repeat {
            switch try controller.read(
                masterFileDescriptor: masterFileDescriptor,
                maximumBytes: 16 * 1_024
            ) {
            case .bytes(let nextBytes):
                bytes.append(nextBytes)
                quietSince = nil
            case .wouldBlock:
                if bytes.isEmpty == false,
                   let quietSince,
                   Date().timeIntervalSince(quietSince) >= quietPeriod {
                    return bytes
                }
                if quietSince == nil {
                    quietSince = Date()
                }
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

private final class OneCycleDeferredAttachProver:
    TmuxInteractiveAttachProving,
    @unchecked Sendable
{
    private let underlying: TmuxInteractiveAttachProving
    private var heldVerification: TmuxInteractiveVerifiedAttach?

    init(underlying: TmuxInteractiveAttachProving) {
        self.underlying = underlying
    }

    func prove(
        _ claim: TmuxInteractiveAttachClaim
    ) throws -> TmuxInteractiveVerifiedAttach? {
        if let heldVerification {
            self.heldVerification = nil
            return heldVerification
        }
        guard let verification = try underlying.prove(claim) else {
            return nil
        }
        usleep(100_000)
        heldVerification = verification
        return nil
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

    func startWithAttachResizeFooterTargetWindow() throws -> InteractivePTYTmuxTarget {
        let sourceURL = rootURL.appendingPathComponent("attach-resize-footer.c")
        let executableURL = rootURL.appendingPathComponent("attach-resize-footer")
        let readyURL = rootURL.appendingPathComponent("attach-resize-footer-ready")
        let source = """
        #include <fcntl.h>
        #include <signal.h>
        #include <stddef.h>
        #include <sys/ioctl.h>
        #include <termios.h>
        #include <unistd.h>

        static volatile sig_atomic_t redraw_requested = 0;
        static const char collapsed[] =
            "\\033[21;1H\\033[2K\\033[22;1H\\033[2K\\033[23;1H\\033[2K> Summarize recent commits";
        static const char complete[] =
            "\\033[21;1H\\033[2K> Summarize recent commits\\033[22;1H\\033[2K\\033[23;1H\\033[2Kgpt-5.6-sol xhigh";

        static void handle_winch(int signal_number) {
            (void)signal_number;
            redraw_requested = 1;
        }

        int main(void) {
            struct sigaction action = {0};
            action.sa_handler = handle_winch;
            sigemptyset(&action.sa_mask);
            if (sigaction(SIGWINCH, &action, NULL) != 0) {
                return 2;
            }

            sigset_t blocked;
            sigset_t prior;
            sigemptyset(&blocked);
            sigaddset(&blocked, SIGWINCH);
            if (sigprocmask(SIG_BLOCK, &blocked, &prior) != 0) {
                return 3;
            }
            struct winsize last_size = {0};
            if (ioctl(STDIN_FILENO, TIOCGWINSZ, &last_size) != 0) {
                return 4;
            }
            (void)write(STDOUT_FILENO, collapsed, sizeof(collapsed) - 1);
            int ready_fd = open("\(readyURL.path)", O_CREAT | O_WRONLY, 0600);
            if (ready_fd < 0 || close(ready_fd) != 0) {
                return 6;
            }

            for (;;) {
                while (redraw_requested == 0) {
                    (void)sigsuspend(&prior);
                }
                redraw_requested = 0;
                struct winsize current_size = {0};
                if (ioctl(STDIN_FILENO, TIOCGWINSZ, &current_size) != 0) {
                    return 5;
                }
                if (current_size.ws_col != last_size.ws_col ||
                    current_size.ws_row != last_size.ws_row) {
                    last_size = current_size;
                    (void)write(STDOUT_FILENO, complete, sizeof(complete) - 1);
                }
            }
        }
        """
        try Data(source.utf8).write(to: sourceURL, options: .atomic)
        let compileArguments = [
            "-std=c11", "-Wall", "-Wextra", "-Werror",
            sourceURL.path,
            "-o", executableURL.path,
        ]
        guard let compileResult = BoundedProcessRunner.run(
            executablePath: "/usr/bin/clang",
            arguments: compileArguments,
            timeout: 3,
            circuitBreakerCooldown: 0
        ) else {
            throw FixtureError.commandTimedOut(arguments: compileArguments)
        }
        guard compileResult.terminationStatus == 0 else {
            throw FixtureError.commandFailed(
                arguments: compileArguments,
                status: compileResult.terminationStatus,
                stderr: String(decoding: compileResult.standardError, as: UTF8.self)
            )
        }
        let target = try run([
            "-f", "/dev/null",
            "new-session", "-d",
            "-P", "-F", "#{session_id}|#{window_id}|#{pane_id}",
            "-s", "pty-exact",
            "-n", "phone-target",
            "-x", "132",
            "-y", "37",
            executableURL.path,
        ])
        hasStartedServer = true
        let targetFields = target.split(separator: "|", omittingEmptySubsequences: false)
        guard targetFields.count == 3 else {
            throw FixtureError.invalidRecord(target)
        }
        guard waitUntil(timeout: 2, predicate: {
            FileManager.default.fileExists(atPath: readyURL.path)
        }) else {
            throw FixtureError.invalidRecord("attach resize footer fixture did not become ready")
        }
        return InteractivePTYTmuxTarget(
            sessionID: String(targetFields[0]),
            windowID: String(targetFields[1]),
            paneID: String(targetFields[2])
        )
    }

    func startWithSecondResizeFooterTargetWindow() throws -> InteractivePTYTmuxTarget {
        let sourceURL = rootURL.appendingPathComponent("second-resize-footer.c")
        let executableURL = rootURL.appendingPathComponent("second-resize-footer")
        let readyURL = rootURL.appendingPathComponent("second-resize-footer-ready")
        let source = """
        #include <fcntl.h>
        #include <signal.h>
        #include <stddef.h>
        #include <sys/ioctl.h>
        #include <termios.h>
        #include <unistd.h>

        static volatile sig_atomic_t redraw_requested = 0;
        static const char collapsed[] =
            "\\033[21;1H\\033[2K\\033[22;1H\\033[2K\\033[23;1H\\033[2K> Summarize recent commits";
        static const char complete[] =
            "\\033[21;1H\\033[2K> Summarize recent commits\\033[22;1H\\033[2K\\033[23;1H\\033[2Kgpt-5.6-sol xhigh";

        static void handle_winch(int signal_number) {
            (void)signal_number;
            redraw_requested = 1;
        }

        int main(void) {
            struct sigaction action = {0};
            action.sa_handler = handle_winch;
            sigemptyset(&action.sa_mask);
            if (sigaction(SIGWINCH, &action, NULL) != 0) {
                return 2;
            }

            sigset_t blocked;
            sigset_t prior;
            sigemptyset(&blocked);
            sigaddset(&blocked, SIGWINCH);
            if (sigprocmask(SIG_BLOCK, &blocked, &prior) != 0) {
                return 3;
            }
            struct winsize last_size = {0};
            if (ioctl(STDIN_FILENO, TIOCGWINSZ, &last_size) != 0) {
                return 4;
            }
            (void)write(STDOUT_FILENO, collapsed, sizeof(collapsed) - 1);
            int ready_fd = open("\(readyURL.path)", O_CREAT | O_WRONLY, 0600);
            if (ready_fd < 0 || close(ready_fd) != 0) {
                return 6;
            }

            int changed_size_count = 0;
            for (;;) {
                while (redraw_requested == 0) {
                    (void)sigsuspend(&prior);
                }
                redraw_requested = 0;
                struct winsize current_size = {0};
                if (ioctl(STDIN_FILENO, TIOCGWINSZ, &current_size) != 0) {
                    return 5;
                }
                if (current_size.ws_col != last_size.ws_col ||
                    current_size.ws_row != last_size.ws_row) {
                    last_size = current_size;
                    changed_size_count++;
                    const char *frame = changed_size_count >= 2 ? complete : collapsed;
                    size_t frame_size = changed_size_count >= 2
                        ? sizeof(complete) - 1
                        : sizeof(collapsed) - 1;
                    (void)write(STDOUT_FILENO, frame, frame_size);
                }
            }
        }
        """
        try Data(source.utf8).write(to: sourceURL, options: .atomic)
        let compileArguments = [
            "-std=c11", "-Wall", "-Wextra", "-Werror",
            sourceURL.path,
            "-o", executableURL.path,
        ]
        guard let compileResult = BoundedProcessRunner.run(
            executablePath: "/usr/bin/clang",
            arguments: compileArguments,
            timeout: 3,
            circuitBreakerCooldown: 0
        ) else {
            throw FixtureError.commandTimedOut(arguments: compileArguments)
        }
        guard compileResult.terminationStatus == 0 else {
            throw FixtureError.commandFailed(
                arguments: compileArguments,
                status: compileResult.terminationStatus,
                stderr: String(decoding: compileResult.standardError, as: UTF8.self)
            )
        }
        let target = try run([
            "-f", "/dev/null",
            "new-session", "-d",
            "-P", "-F", "#{session_id}|#{window_id}|#{pane_id}",
            "-s", "pty-exact",
            "-n", "phone-target",
            "-x", "132",
            "-y", "37",
            executableURL.path,
        ])
        hasStartedServer = true
        let targetFields = target.split(separator: "|", omittingEmptySubsequences: false)
        guard targetFields.count == 3 else {
            throw FixtureError.invalidRecord(target)
        }
        guard waitUntil(timeout: 2, predicate: {
            FileManager.default.fileExists(atPath: readyURL.path)
        }) else {
            throw FixtureError.invalidRecord("second resize footer fixture did not become ready")
        }
        return InteractivePTYTmuxTarget(
            sessionID: String(targetFields[0]),
            windowID: String(targetFields[1]),
            paneID: String(targetFields[2])
        )
    }

    func startWithViewportSensitiveFooterTargetWindow(
        redrawDelayMicroseconds: UInt32 = 0
    ) throws -> InteractivePTYTmuxTarget {
        let sourceURL = rootURL.appendingPathComponent("viewport-sensitive-footer.c")
        let executableURL = rootURL.appendingPathComponent("viewport-sensitive-footer")
        let readyURL = rootURL.appendingPathComponent("viewport-sensitive-footer-ready")
        let source = """
        #include <fcntl.h>
        #include <signal.h>
        #include <stddef.h>
        #include <sys/ioctl.h>
        #include <termios.h>
        #include <unistd.h>

        static volatile sig_atomic_t redraw_requested = 0;
        static const char collapsed[] =
            "\\033[42;1H\\033[2K\\033[43;1H\\033[2K> Summarize recent commits\\033[44;1H\\033[2K";
        static const char complete[] =
            "\\033[42;1H\\033[2K> Summarize recent commits\\033[43;1H\\033[2K\\033[44;1H\\033[2Kgpt-5.6-sol xhigh";

        static void handle_winch(int signal_number) {
            (void)signal_number;
            redraw_requested = 1;
        }

        static int draw_for_current_size(void) {
            struct winsize current_size = {0};
            if (ioctl(STDIN_FILENO, TIOCGWINSZ, &current_size) != 0) {
                return 5;
            }
            const char *frame = current_size.ws_row == 44 ? complete : collapsed;
            size_t frame_size = current_size.ws_row == 44
                ? sizeof(complete) - 1
                : sizeof(collapsed) - 1;
            (void)write(STDOUT_FILENO, frame, frame_size);
            return 0;
        }

        int main(void) {
            struct sigaction action = {0};
            action.sa_handler = handle_winch;
            sigemptyset(&action.sa_mask);
            if (sigaction(SIGWINCH, &action, NULL) != 0) {
                return 2;
            }

            sigset_t blocked;
            sigset_t prior;
            sigemptyset(&blocked);
            sigaddset(&blocked, SIGWINCH);
            if (sigprocmask(SIG_BLOCK, &blocked, &prior) != 0) {
                return 3;
            }
            if (draw_for_current_size() != 0) {
                return 4;
            }
            int ready_fd = open("\(readyURL.path)", O_CREAT | O_WRONLY, 0600);
            if (ready_fd < 0 || close(ready_fd) != 0) {
                return 6;
            }

            for (;;) {
                while (redraw_requested == 0) {
                    (void)sigsuspend(&prior);
                }
                redraw_requested = 0;
                (void)usleep(\(redrawDelayMicroseconds));
                if (draw_for_current_size() != 0) {
                    return 5;
                }
            }
        }
        """
        try Data(source.utf8).write(to: sourceURL, options: .atomic)
        let compileArguments = [
            "-std=c11", "-Wall", "-Wextra", "-Werror",
            sourceURL.path,
            "-o", executableURL.path,
        ]
        guard let compileResult = BoundedProcessRunner.run(
            executablePath: "/usr/bin/clang",
            arguments: compileArguments,
            timeout: 3,
            circuitBreakerCooldown: 0
        ) else {
            throw FixtureError.commandTimedOut(arguments: compileArguments)
        }
        guard compileResult.terminationStatus == 0 else {
            throw FixtureError.commandFailed(
                arguments: compileArguments,
                status: compileResult.terminationStatus,
                stderr: String(decoding: compileResult.standardError, as: UTF8.self)
            )
        }
        let target = try run([
            "-f", "/dev/null",
            "new-session", "-d",
            "-P", "-F", "#{session_id}|#{window_id}|#{pane_id}",
            "-s", "pty-exact",
            "-n", "phone-target",
            "-x", "132",
            "-y", "37",
            executableURL.path,
        ])
        hasStartedServer = true
        let targetFields = target.split(separator: "|", omittingEmptySubsequences: false)
        guard targetFields.count == 3 else {
            throw FixtureError.invalidRecord(target)
        }
        guard waitUntil(timeout: 2, predicate: {
            FileManager.default.fileExists(atPath: readyURL.path)
        }) else {
            throw FixtureError.invalidRecord("viewport-sensitive footer fixture did not become ready")
        }
        return InteractivePTYTmuxTarget(
            sessionID: String(targetFields[0]),
            windowID: String(targetFields[1]),
            paneID: String(targetFields[2])
        )
    }

    func capturePaneLines(paneID: String) throws -> [String] {
        let output = try run([
            "capture-pane", "-p",
            "-t", paneID,
        ])
        return output.split(
            separator: "\n",
            omittingEmptySubsequences: false
        ).map(String.init)
    }

    func paneProcessSnapshot(paneID: String) throws -> String {
        let paneRecord = try run([
            "display-message", "-p",
            "-t", paneID,
            "#{pane_pid}|#{pane_tty}",
        ])
        let processID = paneRecord.split(separator: "|").first.map(String.init) ?? ""
        let result = BoundedProcessRunner.run(
            executablePath: "/bin/ps",
            arguments: [
                "-o", "pid=,ppid=,pgid=,tpgid=,tty=,state=,sigmask=,command=",
                "-p", processID,
            ],
            timeout: 1,
            circuitBreakerCooldown: 0
        )
        let processRecord = String(
            decoding: result?.standardOutput ?? Data(),
            as: UTF8.self
        )
        return "\(paneRecord)\n\(processRecord)"
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
