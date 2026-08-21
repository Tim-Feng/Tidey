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

    func testRuntimeTaskEnvironmentUsesCanonicalTideyPathsAndRemovesControllerIdentity() {
        let environment = TideyRuntimeTaskEnvironmentBuilder().environment(
            parentEnvironment: [
                "PATH": "/usr/bin:/bin",
                "CUSTOM_VALUE": "preserved",
                "CODEX_HOME": "/tmp/codex-home",
                "TMUX": "/tmp/stale-tmux,1,0",
                "TMUX_PANE": "%99",
                "NO_COLOR": "1",
                "CODEX_CI": "1",
                "CODEX_THREAD_ID": "controller-thread",
                "CODEX_PERMISSION_PROFILE": "controller-profile",
                "CODEX_SANDBOX": "controller-sandbox",
                "CODEX_SANDBOX_NETWORK_DISABLED": "1",
                "CODEX_ESCALATE_SOCKET": "/tmp/controller.sock",
                "TIDEY_SOCKET_PATH": "/tmp/stale-tidey.sock",
                "TIDEY_BIN_DIR": "/tmp/stale-bin",
                "TIDEY_WORKSPACE_ID": "stale-workspace",
                "TIDEY_PANEL_ID": "stale-panel",
                "TIDEY_AGENT_SESSION_ID": "stale-agent",
                "TIDEY_AGENT_VENDOR": "stale-vendor",
                "TIDEY_CUSTOM_PARENT_VALUE": "must-not-leak",
            ],
            canonicalSocketPath: "/tmp/tidey-dev.sock",
            canonicalBinDirectory:
                "/Applications/Tidey Dev.app/Contents/Resources/bin"
        )

        XCTAssertEqual(environment["PATH"], "/usr/bin:/bin")
        XCTAssertEqual(environment["CUSTOM_VALUE"], "preserved")
        XCTAssertEqual(environment["CODEX_HOME"], "/tmp/codex-home")
        XCTAssertEqual(
            environment["TIDEY_SOCKET_PATH"],
            "/tmp/tidey-dev.sock"
        )
        XCTAssertEqual(
            environment["TIDEY_BIN_DIR"],
            "/Applications/Tidey Dev.app/Contents/Resources/bin"
        )
        for key in [
            "TMUX",
            "TMUX_PANE",
            "NO_COLOR",
            "CODEX_CI",
            "CODEX_THREAD_ID",
            "CODEX_PERMISSION_PROFILE",
            "CODEX_SANDBOX",
            "CODEX_SANDBOX_NETWORK_DISABLED",
            "CODEX_ESCALATE_SOCKET",
            "TIDEY_WORKSPACE_ID",
            "TIDEY_PANEL_ID",
            "TIDEY_AGENT_SESSION_ID",
            "TIDEY_AGENT_VENDOR",
            "TIDEY_CUSTOM_PARENT_VALUE",
        ] {
            XCTAssertNil(environment[key], "Unexpected inherited key: \(key)")
        }
    }
}

final class TideyRuntimeTmuxExecutableLocatorTests: XCTestCase {
    func testFindsFirstExecutableFromPathBeforeFallbacks() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "tidey-tmux-locator-\(UUID().uuidString)",
                isDirectory: true
            )
        let first = root.appendingPathComponent("first", isDirectory: true)
        let second = root.appendingPathComponent("second", isDirectory: true)
        try FileManager.default.createDirectory(
            at: first,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: second,
            withIntermediateDirectories: true
        )
        let executable = second.appendingPathComponent("tmux")
        XCTAssertTrue(
            FileManager.default.createFile(
                atPath: executable.path,
                contents: Data("fixture".utf8),
                attributes: [.posixPermissions: 0o700]
            )
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let located = TideyRuntimeTmuxExecutableLocator().executablePath(
            environmentPath: "\(first.path):\(second.path)",
            fallbackPaths: ["/does/not/exist"]
        )

        XCTAssertEqual(located, executable.path)
    }

    func testRejectsNonExecutableCandidates() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "tidey-tmux-locator-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let candidate = root.appendingPathComponent("tmux")
        XCTAssertTrue(
            FileManager.default.createFile(
                atPath: candidate.path,
                contents: Data("fixture".utf8),
                attributes: [.posixPermissions: 0o600]
            )
        )
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertNil(
            TideyRuntimeTmuxExecutableLocator().executablePath(
                environmentPath: root.path,
                fallbackPaths: []
            )
        )
    }
}

final class TideyRuntimeTmuxServerPreparerTests: XCTestCase {
    func testPlanDerivesBoundedSocketAndFixedCanaryTopology() {
        let plan = TideyRuntimeTmuxServerPreparationPlanBuilder().plan(
            serverIdentifier: "tcc-20260821",
            supportDirectory: "/Users/test/Library/Application Support/Tidey",
            homeDirectory: "/Users/test"
        )

        XCTAssertEqual(
            plan?.runtimeDirectory,
            "/Users/test/Library/Application Support/Tidey/Runtime"
        )
        XCTAssertEqual(
            plan?.socketPath,
            "/Users/test/Library/Application Support/Tidey/Runtime/" +
                "tmux-tcc-20260821.sock"
        )
        XCTAssertEqual(plan?.sessionName, "tidey-runtime-canary")
        XCTAssertEqual(
            plan?.newSessionArguments,
            [
                "-S",
                "/Users/test/Library/Application Support/Tidey/Runtime/" +
                    "tmux-tcc-20260821.sock",
                "new-session", "-d", "-P", "-F",
                "#{pid}|#{session_name}|#{window_index}",
                "-s", "tidey-runtime-canary",
                "-n", "canary",
                "-c", "/Users/test",
            ]
        )
        XCTAssertEqual(
            plan?.exactSessionProbeArguments,
            [
                "-S",
                "/Users/test/Library/Application Support/Tidey/Runtime/" +
                    "tmux-tcc-20260821.sock",
                "has-session", "-t", "=tidey-runtime-canary",
            ]
        )
    }

    func testPlanRejectsUnsafeIdentifiersAndPaths() {
        let builder = TideyRuntimeTmuxServerPreparationPlanBuilder()
        for identifier in [
            "",
            "../escape",
            "contains/slash",
            "contains space",
            ".starts-with-dot",
            String(repeating: "a", count: 49),
        ] {
            XCTAssertNil(
                builder.plan(
                    serverIdentifier: identifier,
                    supportDirectory: "/Users/test/Tidey",
                    homeDirectory: "/Users/test"
                ),
                "Unexpectedly accepted: \(identifier)"
            )
        }
        XCTAssertNil(
            builder.plan(
                serverIdentifier: "valid-id",
                supportDirectory: "relative/support",
                homeDirectory: "/Users/test"
            )
        )
        XCTAssertNil(
            builder.plan(
                serverIdentifier: "valid-id",
                supportDirectory: "/Users/test/Tidey",
                homeDirectory: "relative/home"
            )
        )
    }

    func testPreparerCreatesAndReusesOneIsolatedServer() throws {
        let tmuxExecutable = TideyRuntimeTmuxExecutableLocator()
            .executablePath(
                environmentPath: ProcessInfo.processInfo.environment["PATH"]
            )
        guard let tmuxExecutable else {
            throw XCTSkip("tmux is unavailable")
        }
        let suffix = UUID().uuidString.prefix(8).lowercased()
        let supportDirectory = "/tmp/tidey-prep-\(suffix)"
        let serverIdentifier = "test-\(suffix)"
        let environment = [
            "HOME": "/tmp",
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "SHELL": "/bin/zsh",
        ]
        let plan = TideyRuntimeTmuxServerPreparationPlanBuilder().plan(
            serverIdentifier: serverIdentifier,
            supportDirectory: supportDirectory,
            homeDirectory: "/tmp"
        )!
        let runner = TideyRuntimeTaskRunner()
        defer {
            _ = runner.run(
                executable: tmuxExecutable,
                arguments: ["-S", plan.socketPath, "kill-server"],
                environment: environment,
                timeout: 2
            )
            try? FileManager.default.removeItem(
                atPath: supportDirectory
            )
        }

        let preparer = TideyRuntimeTmuxServerPreparer()
        let first = preparer.prepare(
            serverIdentifier: serverIdentifier,
            supportDirectory: supportDirectory,
            homeDirectory: "/tmp",
            tmuxExecutable: tmuxExecutable,
            environment: environment,
            timeout: 3
        )
        let second = preparer.prepare(
            serverIdentifier: serverIdentifier,
            supportDirectory: supportDirectory,
            homeDirectory: "/tmp",
            tmuxExecutable: tmuxExecutable,
            environment: environment,
            timeout: 3
        )

        XCTAssertTrue(first.succeeded, first.errorCode ?? "")
        XCTAssertTrue(first.created)
        XCTAssertGreaterThan(first.serverPID, 1)
        XCTAssertEqual(first.socketPath, plan.socketPath)
        XCTAssertEqual(first.sessionName, plan.sessionName)
        XCTAssertTrue(second.succeeded, second.errorCode ?? "")
        XCTAssertFalse(second.created)
        XCTAssertEqual(second.serverPID, first.serverPID)
    }
}

final class TideyRuntimeRehydrationStateMachineTests: XCTestCase {
    private let controllerEnvironmentUnsetCommand =
        "unset NO_COLOR CODEX_CI CODEX_THREAD_ID " +
        "CODEX_PERMISSION_PROFILE CODEX_SANDBOX " +
        "CODEX_SANDBOX_NETWORK_DISABLED CODEX_ESCALATE_SOCKET"

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
                "\(controllerEnvironmentUnsetCommand); " +
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
                "\(controllerEnvironmentUnsetCommand); " +
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
        let agentCommand = TideyRuntimeDirectAgentCommandBuilder().command(
            agentExecutable: executable,
            arguments: launch.arguments
        )!

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
                "\(controllerEnvironmentUnsetCommand); " +
                    "\(agentCommand); exec '/bin/zsh' -l",
            ]
        )
        XCTAssertEqual(
            (agentCommand as NSString).componentsInShellCommand(),
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
                "\(controllerEnvironmentUnsetCommand); " +
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

    func testColdBootWithoutNativeReattachProbesManagedCreateTarget() {
        XCTAssertEqual(
            TideyManagedRestoreLaunchPolicy().disposition(
                nativeReattachOutcome: .notAttempted,
                hasValidDescriptor: true
            ),
            .deferToRuntimeRehydrator
        )
        let targetProbe = TideyRuntimeTargetProbeSpy()
        let topologyCreator = TideyRuntimeTopologyCreatorSpy()
        let panelLauncher = TideyRuntimePanelLauncherSpy()
        let stateMachine = TideyRuntimeRehydrationStateMachine(
            reducer: TideyRuntimeRehydrationReducer(),
            targetProbe: targetProbe,
            topologyCreator: topologyCreator,
            panelLauncher: panelLauncher
        )
        let descriptor = descriptor(revision: 1)

        stateMachine.handle(
            panelID: "panel-cold-boot",
            descriptor: descriptor,
            nativeReattachOutcome: .notAttempted
        )
        stateMachine.handle(
            panelID: "panel-cold-boot",
            descriptor: descriptor,
            nativeReattachOutcome: .notAttempted
        )

        XCTAssertEqual(targetProbe.probeCount, 1)
        targetProbe.complete(.missing)
        XCTAssertEqual(topologyCreator.createCount, 1)
    }

    func testColdBootWithoutNativeReattachResumesDirectAgent() {
        let targetProbe = TideyRuntimeTargetProbeSpy()
        let topologyCreator = TideyRuntimeTopologyCreatorSpy()
        let panelLauncher = TideyRuntimePanelLauncherSpy()
        let stateMachine = TideyRuntimeRehydrationStateMachine(
            reducer: TideyRuntimeRehydrationReducer(),
            targetProbe: targetProbe,
            topologyCreator: topologyCreator,
            panelLauncher: panelLauncher
        )

        stateMachine.handle(
            panelID: "panel-direct-cold-boot",
            descriptor: directDescriptor(revision: 1),
            nativeReattachOutcome: .notAttempted
        )
        stateMachine.handle(
            panelID: "panel-direct-cold-boot",
            descriptor: directDescriptor(revision: 1),
            nativeReattachOutcome: .notAttempted
        )

        XCTAssertEqual(panelLauncher.directResumeCount, 1)
        XCTAssertEqual(targetProbe.probeCount, 0)
    }

    func testRuntimeTaskRunnerCapturesExitStatusAndDiagnostics() {
        let result = TideyRuntimeTaskRunner().run(
            executable: "/bin/sh",
            arguments: [
                "-c",
                "printf stdout; printf stderr >&2; exit 7",
            ],
            environment: ["PATH": "/usr/bin:/bin"],
            timeout: 2
        )

        XCTAssertTrue(result.launched)
        XCTAssertFalse(result.timedOut)
        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(
            result.terminationReason,
            Process.TerminationReason.exit.rawValue
        )
        XCTAssertEqual(result.terminationStatus, 7)
        XCTAssertEqual(result.standardOutput, "stdout")
        XCTAssertEqual(result.standardError, "stderr")
        XCTAssertNil(result.launchErrorDescription)
    }

    func testRuntimeRestorationLoggerSeamCompiles() {
        XCTAssertNotNil(TideyRuntimeRestorationLogger() as Any)
    }

    func testRuntimeRestorationLoggerUsesFixedPrivacySchemaAndBoundsDiagnostics() {
        let descriptor = descriptor(revision: 7)
        let result = TideyRuntimeTaskExecutionResult(
            launched: true,
            timedOut: false,
            terminationReason: Process.TerminationReason.exit.rawValue,
            terminationStatus: 1,
            standardOutput: "transcript /tmp/private-project",
            standardError: String(repeating: "x", count: 5_000) + "\nend",
            launchErrorDescription: "launch\nerror"
        )

        let record = TideyRuntimeRestorationLogger().taskRecord(
            descriptor: descriptor,
            phase: "has-session",
            result: result,
            postcondition: "not_applicable",
            outcome: "missing"
        )

        XCTAssertEqual(
            Set(record.publicFields.keys),
            Set([
                "phase",
                "descriptor_version",
                "revision",
                "endpoint_kind",
                "migration_applied",
                "launched",
                "timed_out",
                "status",
                "postcondition",
                "outcome",
            ])
        )
        XCTAssertEqual(
            Set(record.privateFields.keys),
            Set([
                "panel",
                "session",
                "socket",
                "stderr",
                "launch_error",
            ])
        )
        XCTAssertEqual(record.publicFields["status"], "1")
        XCTAssertEqual(record.publicFields["outcome"], "missing")
        XCTAssertFalse(record.privateFields["stderr", default: ""]
            .contains("\n"))
        XCTAssertLessThanOrEqual(
            record.privateFields["stderr", default: ""].count,
            4_097
        )
        XCTAssertFalse(
            (Array(record.publicFields.values) +
                Array(record.privateFields.values))
                .contains { $0.contains("private-project") }
        )

        let outcomeRecord = TideyRuntimeRestorationLogger().outcomeRecord(
            descriptor: descriptor,
            phase: "admit",
            panelID: "panel-7",
            postcondition: "not_applicable",
            outcome: "admitted"
        )
        XCTAssertEqual(
            outcomeRecord.publicFields["launched"],
            "not_applicable"
        )
        XCTAssertEqual(
            outcomeRecord.publicFields["status"],
            "not_applicable"
        )
    }

    func testTmuxSessionCreationPostconditionSeamCompiles() {
        XCTAssertNotNil(
            TideyRuntimeTmuxSessionCreationPostcondition() as Any
        )
    }

    func testTmuxPaneListCodecSeamPreservesStrictIndexMapping() {
        let codec = TideyRuntimeTmuxPaneListCodec()
        let output = codec.formatString
            .replacingOccurrences(of: "#{pane_index}", with: "0")
            .replacingOccurrences(of: "#{pane_id}", with: "%5") + "\n"

        XCTAssertEqual(
            codec.paneIDsByIndex(from: output),
            [NSNumber(value: 0): "%5"]
        )
        XCTAssertNil(codec.paneIDsByIndex(from: "0|%5\n0|%6\n"))
        XCTAssertNil(codec.paneIDsByIndex(from: "00|%5\n"))
    }

    func testTmuxPaneListCodecUsesProcessSafePrintableDelimiter() {
        let codec = TideyRuntimeTmuxPaneListCodec()

        XCTAssertEqual(codec.formatString, "#{pane_index}|#{pane_id}")
        XCTAssertEqual(
            codec.paneIDsByIndex(from: "0|%5\n"),
            [NSNumber(value: 0): "%5"]
        )
        XCTAssertEqual(
            codec.paneIDsByIndex(from: "0|%5\n1|%6"),
            [NSNumber(value: 0): "%5", NSNumber(value: 1): "%6"]
        )
        for malformedOutput in [
            "",
            "0_%5\n",
            "0\t%5\n",
            "0|%5|extra\n",
            "00|%5\n",
            "0|%5\n0|%6\n",
            "0|%5\n1|%5\n",
            "0|pane-5\n",
            "0|%five\n",
            "\n0|%5\n",
            "0|%5\n\n",
        ] {
            XCTAssertNil(
                codec.paneIDsByIndex(from: malformedOutput),
                "Unexpectedly accepted: \(malformedOutput.debugDescription)"
            )
        }
    }

    func testTmuxPaneListCodecSurvivesFoundationProcessRoundTrip() throws {
        let tmuxExecutable = [
            "/opt/homebrew/bin/tmux",
            "/usr/local/bin/tmux",
            "/usr/bin/tmux",
        ].first {
            FileManager.default.isExecutableFile(atPath: $0)
        }
        guard let tmuxExecutable else {
            throw XCTSkip("tmux is unavailable")
        }

        let fixtureDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "tidey-pane-codec-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: fixtureDirectory,
            withIntermediateDirectories: true
        )
        let socketIdentifier = UUID().uuidString.prefix(8)
        let socketPath = "/tmp/tidey-p-" +
            "\(ProcessInfo.processInfo.processIdentifier)-" +
            "\(socketIdentifier).sock"
        let sessionName = "pane-codec-\(UUID().uuidString)"
        let environment = [
            "HOME": fixtureDirectory.path,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "SHELL": "/bin/sh",
        ]
        let runner = TideyRuntimeTaskRunner()
        defer {
            _ = runner.run(
                executable: tmuxExecutable,
                arguments: [
                    "-f", "/dev/null",
                    "-S", socketPath,
                    "kill-server",
                ],
                environment: environment,
                timeout: 2
            )
            try? FileManager.default.removeItem(atPath: socketPath)
            try? FileManager.default.removeItem(at: fixtureDirectory)
        }

        let creation = runner.run(
            executable: tmuxExecutable,
            arguments: [
                "-f", "/dev/null",
                "-S", socketPath,
                "new-session", "-d",
                "-s", sessionName,
            ],
            environment: environment,
            timeout: 3
        )
        guard creation.succeeded else {
            XCTFail("tmux fixture creation failed: \(creation.standardError)")
            return
        }

        let codec = TideyRuntimeTmuxPaneListCodec()
        let listing = runner.run(
            executable: tmuxExecutable,
            arguments: [
                "-f", "/dev/null",
                "-S", socketPath,
                "list-panes",
                "-t", "=\(sessionName):0",
                "-F", codec.formatString,
            ],
            environment: environment,
            timeout: 3
        )

        guard listing.succeeded else {
            XCTFail("tmux pane listing failed: \(listing.standardError)")
            return
        }
        let paneIDsByIndex = codec.paneIDsByIndex(
            from: listing.standardOutput
        )
        XCTAssertNotNil(
            paneIDsByIndex?[NSNumber(value: 0)],
            "Unexpected stdout: \(listing.standardOutput.debugDescription)"
        )
    }

    func testTmuxSessionCreationRequiresExactLiveSessionPostcondition() {
        let postcondition = TideyRuntimeTmuxSessionCreationPostcondition()
        let creationResult = TideyRuntimeTaskExecutionResult(
            launched: true,
            timedOut: false,
            terminationReason: Process.TerminationReason.exit.rawValue,
            terminationStatus: 0,
            standardOutput: "0\n",
            standardError: "error creating server socket",
            launchErrorDescription: nil
        )
        let missingSessionProbe = TideyRuntimeTaskExecutionResult(
            launched: true,
            timedOut: false,
            terminationReason: Process.TerminationReason.exit.rawValue,
            terminationStatus: 1,
            standardOutput: "",
            standardError: "no server running",
            launchErrorDescription: nil
        )
        let liveSessionProbe = TideyRuntimeTaskExecutionResult(
            launched: true,
            timedOut: false,
            terminationReason: Process.TerminationReason.exit.rawValue,
            terminationStatus: 0,
            standardOutput: "",
            standardError: "",
            launchErrorDescription: nil
        )
        let parsedWindowIndex = postcondition.parsedWindowIndex(
            output: creationResult.standardOutput
        )

        XCTAssertEqual(
            postcondition.exactProbeArguments(sessionName: "carrier-a"),
            ["has-session", "-t", "=carrier-a"]
        )
        XCTAssertFalse(
            postcondition.isSatisfied(
                creationResult: creationResult,
                parsedWindowIndex: parsedWindowIndex,
                sessionProbeResult: missingSessionProbe
            )
        )
        XCTAssertTrue(
            postcondition.isSatisfied(
                creationResult: creationResult,
                parsedWindowIndex: parsedWindowIndex,
                sessionProbeResult: liveSessionProbe
            )
        )
    }

    func testRuntimeTaskRunnerTimeoutDoesNotBlockNextCommand() {
        let runner = TideyRuntimeTaskRunner()
        let start = Date()
        let timedOut = runner.run(
            executable: "/bin/sleep",
            arguments: ["5"],
            environment: [:],
            timeout: 0.05
        )
        let next = runner.run(
            executable: "/usr/bin/printf",
            arguments: ["second-carrier"],
            environment: [:],
            timeout: 2
        )

        XCTAssertTrue(timedOut.launched)
        XCTAssertTrue(timedOut.timedOut)
        XCTAssertFalse(timedOut.succeeded)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        XCTAssertTrue(next.succeeded)
        XCTAssertEqual(next.standardOutput, "second-carrier")
    }

    func testRuntimeTaskRunnerForceKillsProcessesThatIgnoreTermination() {
        let start = Date()
        let result = TideyRuntimeTaskRunner().run(
            executable: "/bin/sh",
            arguments: [
                "-c",
                "trap '' TERM; while :; do :; done",
            ],
            environment: ["PATH": "/usr/bin:/bin"],
            timeout: 0.05
        )

        XCTAssertTrue(result.launched)
        XCTAssertTrue(result.timedOut)
        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(
            result.terminationReason,
            Process.TerminationReason.uncaughtSignal.rawValue
        )
        XCTAssertEqual(result.terminationStatus, SIGKILL)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }

    func testRuntimeTaskRunnerDrainsAndBoundsBothOutputStreams() {
        let result = TideyRuntimeTaskRunner().run(
            executable: "/bin/sh",
            arguments: [
                "-c",
                "dd if=/dev/zero bs=65536 count=8 2>/dev/null; " +
                    "dd if=/dev/zero bs=65536 count=8 1>&2 2>/dev/null",
            ],
            environment: ["PATH": "/usr/bin:/bin"],
            timeout: 2
        )

        XCTAssertTrue(result.succeeded)
        XCTAssertGreaterThan(result.standardOutput.utf8.count, 0)
        XCTAssertGreaterThan(result.standardError.utf8.count, 0)
        XCTAssertLessThanOrEqual(result.standardOutput.utf8.count, 262_144)
        XCTAssertLessThanOrEqual(result.standardError.utf8.count, 262_144)
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

    func testFailedTopologyCreationDoesNotPreventNextCarrierRestore() {
        let targetProbe = TideyRuntimeTargetProbeSpy()
        let topologyCreator = TideyRuntimeTopologyCreatorSpy()
        let panelLauncher = TideyRuntimePanelLauncherSpy()
        let stateMachine = TideyRuntimeRehydrationStateMachine(
            reducer: TideyRuntimeCreateFlowReducer(),
            targetProbe: targetProbe,
            topologyCreator: topologyCreator,
            panelLauncher: panelLauncher
        )

        stateMachine.handle(
            panelID: "panel-a",
            descriptor: descriptor(revision: 1),
            nativeReattachOutcome: .failed
        )
        targetProbe.complete(.missing)
        topologyCreator.complete(false)

        stateMachine.handle(
            panelID: "panel-b",
            descriptor: descriptor(revision: 1),
            nativeReattachOutcome: .failed
        )
        targetProbe.complete(.missing)
        topologyCreator.complete(true)

        XCTAssertEqual(topologyCreator.createCount, 2)
        XCTAssertEqual(panelLauncher.resumeCount, 1)
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
