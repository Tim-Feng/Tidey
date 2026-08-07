import XCTest
@testable import iTerm2SharedARC

final class TideyRuntimeTaskEnvironmentBuilderTests: XCTestCase {
    func testRuntimeTaskEnvironmentBuilderSeamCompiles() {
        let environment = TideyRuntimeTaskEnvironmentBuilder().environment(
            parentEnvironment: ["CUSTOM_VALUE": "preserved"],
            canonicalSocketPath: "/tmp/tidey-dev.sock",
            canonicalBinDirectory:
                "/Applications/Tidey Dev.app/Contents/Resources/bin"
        )

        XCTAssertEqual(environment["CUSTOM_VALUE"], "preserved")
    }
}

final class TideyRuntimeRehydrationStateMachineTests: XCTestCase {
    func testDirectAgentLauncherSeamsCompile() {
        let builder = TideyRuntimeDirectAgentCommandBuilder()
        let command = builder.command(
            agentExecutable: "/Applications/Tidey.app/Contents/Resources/bin/codex",
            arguments: ["resume", "thread-direct"]
        )

        XCTAssertNotNil(command)
        XCTAssertEqual(
            TideyRuntimeRehydrationEffect.resumeDirectAgent.rawValue,
            6
        )
    }

    func testDirectAgentCommandTreatsResumeIdentityAsLiteralArgument() {
        let builder = TideyRuntimeDirectAgentCommandBuilder()
        let command = builder.command(
            agentExecutable:
                "/Applications/Tidey.app/Contents/Resources/bin/codex",
            arguments: [
                "resume",
                "thread'; $(touch /tmp/tidey-owned); `touch /tmp/tidey-owned`"
            ]
        )

        XCTAssertEqual(
            command,
            "'/Applications/Tidey.app/Contents/Resources/bin/codex' " +
                "'resume' " +
                "'thread'\\''; $(touch /tmp/tidey-owned); " +
                "`touch /tmp/tidey-owned`'"
        )
        XCTAssertNil(
            builder.command(
                agentExecutable: "codex",
                arguments: ["resume", "thread-direct"]
            )
        )
        XCTAssertNil(
            builder.command(
                agentExecutable:
                    "/Applications/Tidey.app/Contents/Resources/bin/sh",
                arguments: ["-c", "touch /tmp/tidey-owned"]
            )
        )
    }

    func testDirectAgentLoginShellCommandBuilderSeamCompiles() {
        let builder = TideyRuntimeLoginShellCommandBuilder()

        XCTAssertNotNil(
            builder.command(
                loginShellExecutable: "/bin/zsh",
                innerCommand:
                    "'/Applications/Tidey.app/Contents/Resources/bin/codex' " +
                    "'resume' 'thread-direct'"
            )
        )
    }

    func testDirectAgentLoginShellCommandReturnsToLoginShellAfterAgentExit() {
        let innerCommand =
            "'/Applications/Tidey.app/Contents/Resources/bin/codex' " +
            "'resume' 'thread-direct'"
        let command = TideyRuntimeLoginShellCommandBuilder().command(
            loginShellExecutable: "/bin/zsh",
            innerCommand: innerCommand
        )!

        XCTAssertEqual(
            (command as NSString).componentsInShellCommand(),
            [
                "/bin/zsh",
                "-lic",
                "\(innerCommand); exec '/bin/zsh' -l",
            ]
        )
    }

    func testDirectAgentLoginShellCommandRebuildsUserPathAndPreservesLiteralResumeIdentity() {
        let resumeIdentity =
            "thread' \"quoted\"; $(touch /tmp/tidey-owned); " +
            "`touch /tmp/tidey-owned`"
        let agentExecutable =
            "/Applications/Tidey.app/Contents/Resources/bin/codex"
        let innerCommand = TideyRuntimeDirectAgentCommandBuilder().command(
            agentExecutable: agentExecutable,
            arguments: ["resume", resumeIdentity]
        )!
        let command = TideyRuntimeLoginShellCommandBuilder().command(
            loginShellExecutable: "/bin/zsh",
            innerCommand: innerCommand
        )!

        XCTAssertEqual(
            (command as NSString).componentsInShellCommand(),
            [
                "/bin/zsh",
                "-lic",
                "\(innerCommand); exec '/bin/zsh' -l",
            ]
        )
        XCTAssertEqual(
            (innerCommand as NSString)
                .componentsInShellCommand(),
            [agentExecutable, "resume", resumeIdentity]
        )
        XCTAssertNil(
            TideyRuntimeLoginShellCommandBuilder().command(
                loginShellExecutable: "zsh",
                innerCommand: innerCommand
            )
        )
    }

    func testDirectAgentResumeBypassesTmuxAndRunsExactlyOnce() {
        let targetProbe = TideyRuntimeTargetProbeSpy()
        let topologyCreator = TideyRuntimeTopologyCreatorSpy()
        let panelLauncher = TideyRuntimePanelLauncherSpy()
        let stateMachine = TideyRuntimeRehydrationStateMachine(
            reducer: TideyRuntimeRehydrationReducer(),
            targetProbe: targetProbe,
            topologyCreator: topologyCreator,
            panelLauncher: panelLauncher
        )
        let revisionOne = directDescriptor(revision: 1)

        stateMachine.handle(
            panelID: "panel-direct",
            descriptor: revisionOne,
            nativeReattachOutcome: .failed
        )
        stateMachine.handle(
            panelID: "panel-direct",
            descriptor: revisionOne,
            nativeReattachOutcome: .failed
        )

        XCTAssertEqual(panelLauncher.directResumeCount, 1)
        XCTAssertEqual(targetProbe.probeCount, 0)
        XCTAssertEqual(topologyCreator.createCount, 0)
        XCTAssertEqual(panelLauncher.resumeCount, 0)
        XCTAssertEqual(panelLauncher.attachCount, 0)

        panelLauncher.completeDirectResume(true)
        panelLauncher.completeDirectResume(true)
        XCTAssertEqual(panelLauncher.directResumeCount, 1)
        XCTAssertEqual(panelLauncher.attachCount, 0)

        stateMachine.handle(
            panelID: "panel-direct",
            descriptor: directDescriptor(revision: 2),
            nativeReattachOutcome: .failed
        )
        XCTAssertEqual(panelLauncher.directResumeCount, 2)
    }

    func testDirectAgentResumeOverridesNativeReattachSuccessExactlyOnce() {
        let targetProbe = TideyRuntimeTargetProbeSpy()
        let topologyCreator = TideyRuntimeTopologyCreatorSpy()
        let panelLauncher = TideyRuntimePanelLauncherSpy()
        let stateMachine = TideyRuntimeRehydrationStateMachine(
            reducer: TideyRuntimeRehydrationReducer(),
            targetProbe: targetProbe,
            topologyCreator: topologyCreator,
            panelLauncher: panelLauncher
        )
        let descriptor = directDescriptor(revision: 1)

        stateMachine.handle(
            panelID: "panel-direct-native-success",
            descriptor: descriptor,
            nativeReattachOutcome: .succeeded
        )
        stateMachine.handle(
            panelID: "panel-direct-native-success",
            descriptor: descriptor,
            nativeReattachOutcome: .succeeded
        )

        XCTAssertEqual(panelLauncher.directResumeCount, 1)
        XCTAssertEqual(targetProbe.probeCount, 0)
        XCTAssertEqual(topologyCreator.createCount, 0)
        XCTAssertEqual(panelLauncher.resumeCount, 0)
        XCTAssertEqual(panelLauncher.attachCount, 0)

        panelLauncher.completeDirectResume(true)
        panelLauncher.completeDirectResume(true)
        XCTAssertEqual(panelLauncher.directResumeCount, 1)
        XCTAssertEqual(panelLauncher.attachCount, 0)
    }

    func testRuntimeAttachCommandBuilderSeamCompiles() {
        let builder = TideyRuntimeAttachCommandBuilder()

        XCTAssertNotNil(
            builder.command(
                tmuxExecutable: "/opt/homebrew/bin/tmux",
                socketArguments: [],
                tmuxSession: "work"
            )
        )
    }

    func testRuntimeAttachCommandTreatsShellMetacharactersAsLiteralArguments() {
        let builder = TideyRuntimeAttachCommandBuilder()
        let command = builder.command(
            tmuxExecutable: "/opt/homebrew/bin/tmux",
            socketArguments: [
                "-S",
                "/tmp/socket $(touch /tmp/tidey-owned)",
            ],
            tmuxSession:
                "team'; $(touch /tmp/tidey-owned); " +
                "`touch /tmp/tidey-owned`"
        )

        XCTAssertEqual(
            command,
            """
            '/opt/homebrew/bin/tmux' '-S' \
            '/tmp/socket $(touch /tmp/tidey-owned)' \
            'attach-session' '-t' \
            '=team'\\''; $(touch /tmp/tidey-owned); \
            `touch /tmp/tidey-owned`'
            """
        )
        XCTAssertNil(
            builder.command(
                tmuxExecutable: "/opt/homebrew/bin/tmux\u{0}",
                socketArguments: [],
                tmuxSession: "work"
            )
        )
        XCTAssertNil(
            builder.command(
                tmuxExecutable: "/opt/homebrew/bin/tmux",
                socketArguments: ["-S", "/tmp/socket\u{0}"],
                tmuxSession: "work"
            )
        )
        XCTAssertNil(
            builder.command(
                tmuxExecutable: "/opt/homebrew/bin/tmux",
                socketArguments: [],
                tmuxSession: "work\u{0}"
            )
        )
    }

    func testTmuxRespawnCommandBuilderSeamCompiles() {
        let builder = TideyRuntimeTmuxRespawnCommandBuilder()

        XCTAssertNotNil(builder as Any)
    }

    func testTmuxRespawnUsesBundledExecutableAndLiteralArguments() throws {
        let injectionMarker = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(
                "tidey-tmux-quote-\(UUID().uuidString)"
            )
        defer {
            try? FileManager.default.removeItem(at: injectionMarker)
        }
        let resumeIdentity =
            "thread'; $(touch '\(injectionMarker.path)'); " +
            "`touch '\(injectionMarker.path)'`"
        let executable =
            "/Applications/Tidey.app/Contents/Resources/bin/codex"
        let launch = TideyRuntimeLaunchSpecification(
            executable: "codex",
            arguments: ["resume", resumeIdentity],
            workingDirectory: "/tmp/project with spaces"
        )

        let arguments = TideyRuntimeTmuxRespawnCommandBuilder()
            .arguments(
                paneID: "%7",
                agentExecutable: executable,
                loginShellExecutable: "/bin/zsh",
                launch: launch
            )

        XCTAssertEqual(
            arguments?.dropLast(),
            [
                "respawn-pane",
                "-k",
                "-t",
                "%7",
                "-c",
                "/tmp/project with spaces",
            ]
        )
        let parser = Process()
        let parserOutput = Pipe()
        parser.executableURL = URL(fileURLWithPath: "/bin/sh")
        parser.arguments = [
            "-c",
            "set -- \(arguments?.last ?? ""); " +
                "printf '%s\\n' \"$@\"",
        ]
        parser.standardOutput = parserOutput
        try parser.run()
        parser.waitUntilExit()
        let outputData = parserOutput.fileHandleForReading.readDataToEndOfFile()
        let output = String(decoding: outputData, as: UTF8.self)
        let shellArguments = Array(
            output.components(separatedBy: "\n").dropLast()
        )

        XCTAssertEqual(parser.terminationStatus, 0)
        XCTAssertEqual(
            shellArguments,
            [
                "/bin/zsh",
                "-lic",
                TideyRuntimeDirectAgentCommandBuilder().command(
                    agentExecutable: executable,
                    arguments: launch.arguments
                )! + "; exec '/bin/zsh' -l",
            ]
        )
        XCTAssertEqual(
            (TideyRuntimeDirectAgentCommandBuilder().command(
                agentExecutable: executable,
                arguments: launch.arguments
            )! as NSString).componentsInShellCommand(),
            [executable, "resume", resumeIdentity]
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: injectionMarker.path))
        XCTAssertNil(
            TideyRuntimeTmuxRespawnCommandBuilder().arguments(
                paneID: "%7",
                agentExecutable: "codex",
                loginShellExecutable: "/bin/zsh",
                launch: launch
            )
        )
        XCTAssertNil(
            TideyRuntimeTmuxRespawnCommandBuilder().arguments(
                paneID: "pane-7",
                agentExecutable: executable,
                loginShellExecutable: "/bin/zsh",
                launch: launch
            )
        )
        XCTAssertNil(
            TideyRuntimeTmuxRespawnCommandBuilder().arguments(
                paneID: "%7",
                agentExecutable: executable,
                loginShellExecutable: "zsh",
                launch: launch
            )
        )
        XCTAssertNil(
            TideyRuntimeTmuxRespawnCommandBuilder().arguments(
                paneID: "%7",
                agentExecutable: executable,
                loginShellExecutable: "/bin/zsh\u{0}",
                launch: launch
            )
        )
    }

    func testTmuxAgentRespawnReturnsToLoginShellAfterWrapperExit() {
        let executable =
            "/Applications/Tidey.app/Contents/Resources/bin/claude"
        let launch = TideyRuntimeLaunchSpecification(
            executable: "claude",
            arguments: ["--resume", "claude-session"],
            workingDirectory: "/tmp/project"
        )
        let arguments = TideyRuntimeTmuxRespawnCommandBuilder()
            .arguments(
                paneID: "%11",
                agentExecutable: executable,
                loginShellExecutable: "/bin/zsh",
                launch: launch
            )
        let agentCommand = TideyRuntimeDirectAgentCommandBuilder()
            .command(
                agentExecutable: executable,
                arguments: launch.arguments
            )!

        XCTAssertEqual(
            ((arguments?.last ?? "") as NSString)
                .componentsInShellCommand(),
            [
                "/bin/zsh",
                "-lic",
                "\(agentCommand); exec '/bin/zsh' -l",
            ]
        )
    }

    func testReducerAndExecutorSeamsCompile() {
        let reducer = TideyRuntimeRehydrationReducer()
        let targetProbe = TideyRuntimeTargetProbeSpy()
        let topologyCreator = TideyRuntimeTopologyCreatorSpy()
        let panelLauncher = TideyRuntimePanelLauncherSpy()
        let stateMachine = TideyRuntimeRehydrationStateMachine(
            reducer: reducer,
            targetProbe: targetProbe,
            topologyCreator: topologyCreator,
            panelLauncher: panelLauncher
        )

        let descriptor = TideyRuntimeResumeDescriptor(
            descriptorVersion:
                TideyRuntimeResumeDescriptor.currentDescriptorVersion,
            revision: 7,
            kind: .ordinaryTmux,
            restorePolicy: .attachOnly,
            target: TideyRuntimeResumeTarget(
                defaultSocketAndTmuxSession: "work"
            ),
            topology: nil,
            agent: nil
        )

        stateMachine.handle(
            panelID: "panel-1",
            descriptor: descriptor,
            nativeReattachOutcome: .notAttempted
        )

        XCTAssertNotNil(stateMachine)
    }

    func testTopologyOwnedAgentLaunchPlanSeamsCompile() {
        let builder = TideyRuntimeTmuxAgentLaunchPlanBuilder()
        let descriptor = TideyRuntimeResumeDescriptor(
            descriptorVersion:
                TideyRuntimeResumeDescriptor
                    .topologyOwnedAgentDescriptorVersion,
            revision: 1,
            kind: .agent,
            restorePolicy: .create,
            target: TideyRuntimeResumeTarget(
                defaultSocketAndTmuxSession: "work"
            ),
            topology: TideyRuntimeTmuxTopology(
                windows: [
                    TideyRuntimeTmuxWindowTopology(
                        index: 0,
                        name: nil,
                        panes: [
                            TideyRuntimeTmuxPaneTopology(
                                index: 0,
                                workingDirectory: "/tmp",
                                launch: TideyRuntimeLaunchSpecification(
                                    executable: "codex",
                                    arguments: [
                                        "resume",
                                        "thread-1",
                                    ],
                                    workingDirectory: "/tmp"
                                )
                            ),
                        ]
                    ),
                ],
                activeWindowIndex: 0,
                activePaneIndex: 0
            ),
            agent: nil
        )

        _ = builder.plan(for: descriptor)
        XCTAssertNotNil(builder as Any)
    }

    func testMultiAgentRestoreLaunchesEveryPaneAndPreservesActiveSelection()
        throws {
        let claudeLaunch = TideyRuntimeLaunchSpecification(
            executable: "claude",
            arguments: ["--resume", "claude-session"],
            workingDirectory: "/tmp/claude"
        )
        let codexLaunch = TideyRuntimeLaunchSpecification(
            executable: "codex",
            arguments: ["resume", "codex-thread"],
            workingDirectory: "/tmp/codex"
        )
        let descriptor = TideyRuntimeResumeDescriptor(
            descriptorVersion:
                TideyRuntimeResumeDescriptor
                    .topologyOwnedAgentDescriptorVersion,
            revision: 1,
            kind: .agent,
            restorePolicy: .create,
            target: TideyRuntimeResumeTarget(
                defaultSocketAndTmuxSession: "work"
            ),
            topology: TideyRuntimeTmuxTopology(
                windows: [
                    TideyRuntimeTmuxWindowTopology(
                        index: 1,
                        name: "agents",
                        panes: [
                            TideyRuntimeTmuxPaneTopology(
                                index: 0,
                                workingDirectory: "/tmp/claude",
                                launch: claudeLaunch
                            ),
                            TideyRuntimeTmuxPaneTopology(
                                index: 1,
                                workingDirectory: "/tmp/codex",
                                launch: codexLaunch
                            ),
                        ]
                    ),
                    TideyRuntimeTmuxWindowTopology(
                        index: 2,
                        name: "monitor",
                        panes: [
                            TideyRuntimeTmuxPaneTopology(
                                index: 0,
                                workingDirectory: "/tmp/monitor",
                                launch: nil
                            ),
                        ]
                    ),
                ],
                activeWindowIndex: 2,
                activePaneIndex: 0
            ),
            agent: nil
        )

        let plan = try XCTUnwrap(
            TideyRuntimeTmuxAgentLaunchPlanBuilder()
                .plan(for: descriptor)
        )

        XCTAssertEqual(plan.jobs.count, 2)
        XCTAssertEqual(
            plan.jobs.map {
                [
                    $0.windowIndex,
                    $0.paneIndex,
                ]
            },
            [
                [1, 0],
                [1, 1],
            ]
        )
        XCTAssertEqual(
            plan.jobs.map(\.launch.arguments),
            [
                ["--resume", "claude-session"],
                ["resume", "codex-thread"],
            ]
        )
        XCTAssertEqual(plan.activeWindowIndex, 2)
        XCTAssertEqual(plan.activePaneIndex, 0)
    }

    func testV1LaunchPlanPreservesSparsePaneIndexCompatibility()
        throws {
        let claudeLaunch = TideyRuntimeLaunchSpecification(
            executable: "claude",
            arguments: ["--resume", "claude-session"],
            workingDirectory: "/tmp/claude"
        )
        let codexLaunch = TideyRuntimeLaunchSpecification(
            executable: "codex",
            arguments: ["resume", "codex-thread"],
            workingDirectory: "/tmp/codex"
        )
        let descriptor = TideyRuntimeResumeDescriptor(
            descriptorVersion:
                TideyRuntimeResumeDescriptor.currentDescriptorVersion,
            revision: 1,
            kind: .agent,
            restorePolicy: .create,
            target: TideyRuntimeResumeTarget(
                defaultSocketAndTmuxSession: "work"
            ),
            topology: TideyRuntimeTmuxTopology(
                windows: [
                    TideyRuntimeTmuxWindowTopology(
                        index: 4,
                        name: "agents",
                        panes: [
                            TideyRuntimeTmuxPaneTopology(
                                index: 3,
                                workingDirectory: "/tmp/claude",
                                launch: claudeLaunch
                            ),
                            TideyRuntimeTmuxPaneTopology(
                                index: 9,
                                workingDirectory: "/tmp/codex",
                                launch: nil
                            ),
                        ]
                    ),
                ],
                activeWindowIndex: 4,
                activePaneIndex: 9
            ),
            agent: TideyRuntimeAgentResumeSpecification(
                vendor: .codex,
                durableResumeID: "codex-thread",
                launch: codexLaunch
            )
        )

        let plan = try XCTUnwrap(
            TideyRuntimeTmuxAgentLaunchPlanBuilder()
                .plan(for: descriptor)
        )

        XCTAssertEqual(
            plan.jobs.map { [$0.windowIndex, $0.paneIndex] },
            [
                [4, 0],
                [4, 1],
            ]
        )
        XCTAssertEqual(
            plan.jobs.map(\.launch.arguments),
            [
                ["--resume", "claude-session"],
                ["resume", "codex-thread"],
            ]
        )
        XCTAssertEqual(plan.activeWindowIndex, 4)
        XCTAssertEqual(plan.activePaneIndex, 1)
    }

    func testRepeatedCompletionCannotAttachCreateOrResumeTwice() {
        let targetProbe = TideyRuntimeTargetProbeSpy()
        let topologyCreator = TideyRuntimeTopologyCreatorSpy()
        let panelLauncher = TideyRuntimePanelLauncherSpy()
        let stateMachine = TideyRuntimeRehydrationStateMachine(
            reducer: TideyRuntimeCreateFlowReducer(),
            targetProbe: targetProbe,
            topologyCreator: topologyCreator,
            panelLauncher: panelLauncher
        )
        let revisionSeven = descriptor(revision: 7)

        stateMachine.handle(
            panelID: "panel-1",
            descriptor: revisionSeven,
            nativeReattachOutcome: .failed
        )
        stateMachine.handle(
            panelID: "panel-1",
            descriptor: revisionSeven,
            nativeReattachOutcome: .failed
        )
        XCTAssertEqual(targetProbe.probeCount, 1)

        targetProbe.complete(.missing)
        targetProbe.complete(.missing)
        XCTAssertEqual(topologyCreator.createCount, 1)

        stateMachine.handle(
            panelID: "panel-1",
            descriptor: revisionSeven,
            nativeReattachOutcome: .failed
        )
        topologyCreator.complete(true)
        topologyCreator.complete(true)
        XCTAssertEqual(panelLauncher.resumeCount, 1)

        stateMachine.handle(
            panelID: "panel-1",
            descriptor: revisionSeven,
            nativeReattachOutcome: .failed
        )
        panelLauncher.completeResume(true)
        panelLauncher.completeResume(true)
        XCTAssertEqual(panelLauncher.attachCount, 1)

        panelLauncher.completeAttach(true)
        panelLauncher.completeAttach(true)
        stateMachine.handle(
            panelID: "panel-1",
            descriptor: revisionSeven,
            nativeReattachOutcome: .failed
        )

        XCTAssertEqual(targetProbe.probeCount, 1)
        XCTAssertEqual(topologyCreator.createCount, 1)
        XCTAssertEqual(panelLauncher.resumeCount, 1)
        XCTAssertEqual(panelLauncher.attachCount, 1)

        stateMachine.handle(
            panelID: "panel-1",
            descriptor: descriptor(revision: 8),
            nativeReattachOutcome: .failed
        )
        stateMachine.handle(
            panelID: "panel-2",
            descriptor: revisionSeven,
            nativeReattachOutcome: .failed
        )

        XCTAssertEqual(targetProbe.probeCount, 3)
    }

    func testPolicyMatrixPreservesGenericAttachOnlyAndRecreatesAgentCreateTargets() {
        let reducer = TideyRuntimeRehydrationReducer()
        let attachOnly = TideyRuntimeResumeDescriptor(
            descriptorVersion:
                TideyRuntimeResumeDescriptor.currentDescriptorVersion,
            revision: 1,
            kind: .generic,
            restorePolicy: .attachOnly,
            target: TideyRuntimeResumeTarget(
                defaultSocketAndTmuxSession: "generic-attach"
            ),
            topology: nil,
            agent: nil
        )
        let runtime = TideyRuntimeResumeDescriptor(
            descriptorVersion:
                TideyRuntimeResumeDescriptor.currentDescriptorVersion,
            revision: 2,
            kind: .generic,
            restorePolicy: .runtime,
            target: TideyRuntimeResumeTarget(
                defaultSocketAndTmuxSession: "generic-runtime"
            ),
            topology: nil,
            agent: nil
        )
        let create = descriptor(revision: 3)

        assertTransition(
            reducer,
            from: .awaitingNativeRestore,
            event: .nativeReattachSucceeded,
            descriptor: attachOnly,
            equals: .nativeAttached,
            effect: .none
        )
        for descriptor in [attachOnly, runtime, create] {
            assertTransition(
                reducer,
                from: .awaitingNativeRestore,
                event: .nativeReattachFailed,
                descriptor: descriptor,
                equals: .checkingTarget,
                effect: .probeTarget
            )
            assertTransition(
                reducer,
                from: .checkingTarget,
                event: .targetFound,
                descriptor: descriptor,
                equals: .attachingExisting,
                effect: .attachExisting
            )
        }
        for descriptor in [attachOnly, runtime] {
            assertTransition(
                reducer,
                from: .checkingTarget,
                event: .targetMissing,
                descriptor: descriptor,
                equals: .unavailable,
                effect: .markUnavailable
            )
        }
        assertTransition(
            reducer,
            from: .checkingTarget,
            event: .targetMissing,
            descriptor: create,
            equals: .creatingTopology,
            effect: .createTopology
        )
        assertTransition(
            reducer,
            from: .creatingTopology,
            event: .topologyCreated,
            descriptor: create,
            equals: .resumingAgent,
            effect: .resumeAgent
        )
        assertTransition(
            reducer,
            from: .resumingAgent,
            event: .agentResumed,
            descriptor: create,
            equals: .attachingExisting,
            effect: .attachExisting
        )
        assertTransition(
            reducer,
            from: .attachingExisting,
            event: .panelAttached,
            descriptor: create,
            equals: .restored,
            effect: .none
        )
        assertTransition(
            reducer,
            from: .checkingTarget,
            event: .targetProbeFailed,
            descriptor: create,
            equals: .failed,
            effect: .none
        )
        for phase in [
            TideyRuntimeRehydrationPhase.attachingExisting,
            .creatingTopology,
            .resumingAgent,
        ] {
            assertTransition(
                reducer,
                from: phase,
                event: .operationFailed,
                descriptor: create,
                equals: .failed,
                effect: .none
            )
        }
    }

    private func assertTransition(
        _ reducer: TideyRuntimeRehydrationReducing,
        from phase: TideyRuntimeRehydrationPhase,
        event: TideyRuntimeRehydrationEvent,
        descriptor: TideyRuntimeResumeDescriptor,
        equals nextPhase: TideyRuntimeRehydrationPhase,
        effect: TideyRuntimeRehydrationEffect,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let transition = reducer.transition(
            from: phase,
            event: event,
            descriptor: descriptor
        )
        XCTAssertEqual(
            transition.nextPhase,
            nextPhase,
            file: file,
            line: line
        )
        XCTAssertEqual(
            transition.effect,
            effect,
            file: file,
            line: line
        )
    }

    private func descriptor(
        revision: Int64
    ) -> TideyRuntimeResumeDescriptor {
        TideyRuntimeResumeDescriptor(
            descriptorVersion:
                TideyRuntimeResumeDescriptor.currentDescriptorVersion,
            revision: revision,
            kind: .agent,
            restorePolicy: .create,
            target: TideyRuntimeResumeTarget(
                defaultSocketAndTmuxSession: "work"
            ),
            topology: nil,
            agent: nil
        )
    }

    private func directDescriptor(
        revision: Int64
    ) -> TideyRuntimeResumeDescriptor {
        let resumeID = "thread-direct-\(revision)"
        return TideyRuntimeResumeDescriptor(
            descriptorVersion:
                TideyRuntimeResumeDescriptor.currentDescriptorVersion,
            revision: revision,
            kind: .agent,
            restorePolicy: .directResume,
            target: nil,
            topology: nil,
            agent: TideyRuntimeAgentResumeSpecification(
                vendor: .codex,
                durableResumeID: resumeID,
                launch: TideyRuntimeLaunchSpecification(
                    executable: "codex",
                    arguments: ["resume", resumeID],
                    workingDirectory: "/tmp/direct-project"
                )
            )
        )
    }
}

private final class TideyRuntimeTargetProbeSpy:
    NSObject,
    TideyRuntimeTargetProbing {
    private(set) var probeCount = 0
    private var completion:
        ((TideyRuntimeTargetProbeResult) -> Void)?

    func probeTarget(
        for descriptor: TideyRuntimeResumeDescriptor,
        completion: @escaping (TideyRuntimeTargetProbeResult) -> Void
    ) {
        probeCount += 1
        self.completion = completion
    }

    func complete(
        _ result: TideyRuntimeTargetProbeResult
    ) {
        completion?(result)
    }
}

private final class TideyRuntimeTopologyCreatorSpy:
    NSObject,
    TideyRuntimeTopologyCreating {
    private(set) var createCount = 0
    private var completion: ((Bool) -> Void)?

    func createTopology(
        for descriptor: TideyRuntimeResumeDescriptor,
        completion: @escaping (Bool) -> Void
    ) {
        createCount += 1
        self.completion = completion
    }

    func complete(
        _ succeeded: Bool
    ) {
        completion?(succeeded)
    }
}

private final class TideyRuntimePanelLauncherSpy:
    NSObject,
    TideyRuntimePanelLaunching {
    private(set) var attachCount = 0
    private(set) var resumeCount = 0
    private(set) var directResumeCount = 0
    private(set) var unavailableCount = 0
    private var attachCompletion: ((Bool) -> Void)?
    private var resumeCompletion: ((Bool) -> Void)?
    private var directResumeCompletion: ((Bool) -> Void)?

    func attachPanel(
        _ panelID: String,
        to descriptor: TideyRuntimeResumeDescriptor,
        completion: @escaping (Bool) -> Void
    ) {
        attachCount += 1
        attachCompletion = completion
    }

    func resumeAgent(
        in panelID: String,
        with descriptor: TideyRuntimeResumeDescriptor,
        completion: @escaping (Bool) -> Void
    ) {
        resumeCount += 1
        resumeCompletion = completion
    }

    func resumeDirectAgent(
        in panelID: String,
        with descriptor: TideyRuntimeResumeDescriptor,
        completion: @escaping (Bool) -> Void
    ) {
        directResumeCount += 1
        directResumeCompletion = completion
    }

    func markPanelUnavailable(
        _ panelID: String,
        descriptor: TideyRuntimeResumeDescriptor
    ) {
        unavailableCount += 1
    }

    func completeAttach(
        _ succeeded: Bool
    ) {
        attachCompletion?(succeeded)
    }

    func completeResume(
        _ succeeded: Bool
    ) {
        resumeCompletion?(succeeded)
    }

    func completeDirectResume(
        _ succeeded: Bool
    ) {
        directResumeCompletion?(succeeded)
    }
}

private final class TideyRuntimeCreateFlowReducer:
    NSObject,
    TideyRuntimeRehydrationReducing {
    func transition(
        from phase: TideyRuntimeRehydrationPhase,
        event: TideyRuntimeRehydrationEvent,
        descriptor: TideyRuntimeResumeDescriptor
    ) -> TideyRuntimeRehydrationTransition {
        switch (phase, event) {
        case (.awaitingNativeRestore, .nativeReattachFailed):
            return TideyRuntimeRehydrationTransition(
                nextPhase: .checkingTarget,
                effect: .probeTarget
            )
        case (.checkingTarget, .targetMissing):
            return TideyRuntimeRehydrationTransition(
                nextPhase: .creatingTopology,
                effect: .createTopology
            )
        case (.creatingTopology, .topologyCreated):
            return TideyRuntimeRehydrationTransition(
                nextPhase: .resumingAgent,
                effect: .resumeAgent
            )
        case (.resumingAgent, .agentResumed):
            return TideyRuntimeRehydrationTransition(
                nextPhase: .attachingExisting,
                effect: .attachExisting
            )
        case (.attachingExisting, .panelAttached):
            return TideyRuntimeRehydrationTransition(
                nextPhase: .restored,
                effect: .none
            )
        default:
            return TideyRuntimeRehydrationTransition(
                nextPhase: phase,
                effect: .none
            )
        }
    }
}
