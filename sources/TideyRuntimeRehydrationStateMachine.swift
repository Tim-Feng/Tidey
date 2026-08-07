import Foundation
import Darwin
import OSLog

@objc(TideyRuntimeTaskEnvironmentBuilder)
@objcMembers
final class TideyRuntimeTaskEnvironmentBuilder: NSObject {
    @objc(
        environmentWithParentEnvironment:canonicalSocketPath:
        canonicalBinDirectory:
    )
    func environment(
        parentEnvironment: [String: String],
        canonicalSocketPath: String,
        canonicalBinDirectory: String
    ) -> [String: String] {
        var environment = parentEnvironment.filter {
            !$0.key.hasPrefix("TIDEY_")
        }
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
        ] {
            environment[key] = nil
        }
        if !canonicalSocketPath.isEmpty {
            environment["TIDEY_SOCKET_PATH"] = canonicalSocketPath
        }
        if !canonicalBinDirectory.isEmpty {
            environment["TIDEY_BIN_DIR"] = canonicalBinDirectory
        }
        return environment
    }
}

@objc(TideyRuntimeTaskExecutionResult)
@objcMembers
final class TideyRuntimeTaskExecutionResult: NSObject {
    let launched: Bool
    let timedOut: Bool
    let terminationReason: Int
    let terminationStatus: Int32
    let standardOutput: String
    let standardError: String
    let launchErrorDescription: String?

    var succeeded: Bool {
        launched &&
            !timedOut &&
            terminationReason == Process.TerminationReason.exit.rawValue &&
            terminationStatus == 0
    }

    init(
        launched: Bool,
        timedOut: Bool,
        terminationReason: Int,
        terminationStatus: Int32,
        standardOutput: String,
        standardError: String,
        launchErrorDescription: String?
    ) {
        self.launched = launched
        self.timedOut = timedOut
        self.terminationReason = terminationReason
        self.terminationStatus = terminationStatus
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.launchErrorDescription = launchErrorDescription
    }
}

@objc(TideyRuntimeRestorationLogRecord)
@objcMembers
final class TideyRuntimeRestorationLogRecord: NSObject {
    let publicFields: [String: String]
    let privateFields: [String: String]

    init(
        publicFields: [String: String],
        privateFields: [String: String]
    ) {
        self.publicFields = publicFields
        self.privateFields = privateFields
    }
}

@objc(TideyRuntimeRestorationLogger)
@objcMembers
final class TideyRuntimeRestorationLogger: NSObject {
    private let logger = Logger(
        subsystem: "com.tidey.app",
        category: "runtime-restoration"
    )

    func logTask(
        descriptor: TideyRuntimeResumeDescriptor,
        phase: String,
        result: TideyRuntimeTaskExecutionResult?,
        postcondition: String,
        outcome: String,
        isError: Bool
    ) {
        emit(
            record: taskRecord(
                descriptor: descriptor,
                phase: phase,
                result: result,
                postcondition: postcondition,
                outcome: outcome
            ),
            isError: isError
        )
    }

    func taskRecord(
        descriptor: TideyRuntimeResumeDescriptor,
        phase: String,
        result: TideyRuntimeTaskExecutionResult?,
        postcondition: String,
        outcome: String
    ) -> TideyRuntimeRestorationLogRecord {
        makeRecord(
            descriptor: descriptor,
            phase: phase,
            panelID: "",
            result: result,
            postcondition: postcondition,
            outcome: outcome
        )
    }

    func logOutcome(
        descriptor: TideyRuntimeResumeDescriptor?,
        phase: String,
        panelID: String,
        postcondition: String,
        outcome: String,
        isError: Bool
    ) {
        emit(
            record: outcomeRecord(
                descriptor: descriptor,
                phase: phase,
                panelID: panelID,
                postcondition: postcondition,
                outcome: outcome
            ),
            isError: isError
        )
    }

    func outcomeRecord(
        descriptor: TideyRuntimeResumeDescriptor?,
        phase: String,
        panelID: String,
        postcondition: String,
        outcome: String
    ) -> TideyRuntimeRestorationLogRecord {
        makeRecord(
            descriptor: descriptor,
            phase: phase,
            panelID: panelID,
            result: nil,
            postcondition: postcondition,
            outcome: outcome
        )
    }

    private func makeRecord(
        descriptor: TideyRuntimeResumeDescriptor?,
        phase: String,
        panelID: String,
        result: TideyRuntimeTaskExecutionResult?,
        postcondition: String,
        outcome: String
    ) -> TideyRuntimeRestorationLogRecord {
        let endpointKind: String
        let socketSelector: String
        switch descriptor?.target?.socketEndpointKind {
        case .path:
            endpointKind = "path"
            socketSelector = descriptor?.target?.socketPath ?? ""
        case .name:
            endpointKind = "name"
            socketSelector = descriptor?.target?.socketName ?? ""
        case .defaultSocket:
            endpointKind = "default"
            socketSelector = "default"
        case nil:
            endpointKind = "none"
            socketSelector = ""
        }
        let migrationApplied =
            descriptor?.legacyDefaultSocketMigrationApplied ?? false
        let session = descriptor?.target?.tmuxSession ?? ""
        let standardError = boundedSingleLine(
            result?.standardError ?? ""
        )
        let launchError = boundedSingleLine(
            result?.launchErrorDescription ?? ""
        )
        let launched = result.map { String($0.launched) }
            ?? "not_applicable"
        let timedOut = result.map { String($0.timedOut) }
            ?? "not_applicable"
        let status = result.map { String($0.terminationStatus) }
            ?? "not_applicable"

        return TideyRuntimeRestorationLogRecord(
            publicFields: [
                "phase": phase,
                "descriptor_version": String(
                    descriptor?.descriptorVersion ?? 0
                ),
                "revision": String(descriptor?.revision ?? 0),
                "endpoint_kind": endpointKind,
                "migration_applied": String(migrationApplied),
                "launched": launched,
                "timed_out": timedOut,
                "status": status,
                "postcondition": postcondition,
                "outcome": outcome,
            ],
            privateFields: [
                "panel": panelID,
                "session": session,
                "socket": socketSelector,
                "stderr": standardError,
                "launch_error": launchError,
            ]
        )
    }

    private func emit(
        record: TideyRuntimeRestorationLogRecord,
        isError: Bool
    ) {
        let publicFields = record.publicFields
        let privateFields = record.privateFields
        let level: OSLogType = isError ? .error : .default

        logger.log(
            level: level,
            "phase=\(publicFields["phase"] ?? "", privacy: .public) descriptor_version=\(publicFields["descriptor_version"] ?? "", privacy: .public) revision=\(publicFields["revision"] ?? "", privacy: .public) endpoint_kind=\(publicFields["endpoint_kind"] ?? "", privacy: .public) migration_applied=\(publicFields["migration_applied"] ?? "", privacy: .public) launched=\(publicFields["launched"] ?? "", privacy: .public) timed_out=\(publicFields["timed_out"] ?? "", privacy: .public) status=\(publicFields["status"] ?? "", privacy: .public) postcondition=\(publicFields["postcondition"] ?? "", privacy: .public) outcome=\(publicFields["outcome"] ?? "", privacy: .public) panel=\(privateFields["panel"] ?? "", privacy: .private) session=\(privateFields["session"] ?? "", privacy: .private) socket=\(privateFields["socket"] ?? "", privacy: .private) stderr=\(privateFields["stderr"] ?? "", privacy: .private) launch_error=\(privateFields["launch_error"] ?? "", privacy: .private)"
        )
    }

    private func boundedSingleLine(_ value: String) -> String {
        let singleLine = value.components(
            separatedBy: .newlines
        ).joined(separator: " ")
        let maximumLength = 4_096
        guard singleLine.count > maximumLength else {
            return singleLine
        }
        return String(singleLine.prefix(maximumLength)) + "…"
    }
}

@objc(TideyRuntimeTmuxSessionCreationPostcondition)
@objcMembers
final class TideyRuntimeTmuxSessionCreationPostcondition: NSObject {
    func exactProbeArguments(
        sessionName: String
    ) -> [String]? {
        guard !sessionName.isEmpty else {
            return nil
        }
        return ["has-session", "-t", "=\(sessionName)"]
    }

    func parsedWindowIndex(
        output: String
    ) -> NSNumber? {
        let trimmed = output.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard let value = Int(trimmed),
              String(value) == trimmed else {
            return nil
        }
        return NSNumber(value: value)
    }

    func isSatisfied(
        creationResult: TideyRuntimeTaskExecutionResult?,
        parsedWindowIndex: NSNumber?,
        sessionProbeResult: TideyRuntimeTaskExecutionResult?
    ) -> Bool {
        return creationResult?.succeeded == true &&
            parsedWindowIndex != nil &&
            sessionProbeResult?.succeeded == true
    }
}

private final class TideyRuntimeBoundedDataAccumulator {
    private let maximumBytes: Int
    private let lock = NSLock()
    private var data = Data()

    init(maximumBytes: Int) {
        self.maximumBytes = maximumBytes
    }

    func append(_ newData: Data) {
        lock.lock()
        defer { lock.unlock() }
        let remaining = maximumBytes - data.count
        guard remaining > 0 else {
            return
        }
        data.append(newData.prefix(remaining))
    }

    func string() -> String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}

private final class TideyRuntimePipeDrain {
    private let pipe: Pipe
    private let accumulator: TideyRuntimeBoundedDataAccumulator
    private let completion = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var finished = false

    init(pipe: Pipe, maximumBytes: Int) {
        self.pipe = pipe
        accumulator = TideyRuntimeBoundedDataAccumulator(
            maximumBytes: maximumBytes
        )
    }

    func start() {
        DispatchQueue.global(qos: .userInteractive).async { [self] in
            defer { finish() }
            do {
                while let data = try pipe.fileHandleForReading.read(
                    upToCount: 65_536
                ), !data.isEmpty {
                    accumulator.append(data)
                }
            } catch {
                return
            }
        }
    }

    func closeParentWriteEnd() {
        try? pipe.fileHandleForWriting.close()
    }

    func waitForEnd(timeout: TimeInterval) {
        let result = completion.wait(
            timeout: .now() + max(0, timeout)
        )
        if result == .timedOut {
            finish()
        }
    }

    func finish() {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        lock.unlock()

        try? pipe.fileHandleForReading.close()
        completion.signal()
    }

    func string() -> String {
        accumulator.string()
    }
}

@objc(TideyRuntimeTaskRunner)
@objcMembers
final class TideyRuntimeTaskRunner: NSObject {
    private static let maximumCapturedBytes = 262_144
    private static let terminationGrace: TimeInterval = 0.25
    private static let forcedTerminationGrace: TimeInterval = 1
    private static let pipeDrainGrace: TimeInterval = 0.5

    @objc(runExecutable:arguments:environment:timeout:)
    func run(
        executable: String,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval
    ) -> TideyRuntimeTaskExecutionResult {
        guard executable.hasPrefix("/"), timeout.isFinite, timeout > 0 else {
            return TideyRuntimeTaskExecutionResult(
                launched: false,
                timedOut: false,
                terminationReason: -1,
                terminationStatus: -1,
                standardOutput: "",
                standardError: "",
                launchErrorDescription: "Invalid executable or timeout"
            )
        }

        let process = Process()
        let standardOutputPipe = Pipe()
        let standardErrorPipe = Pipe()
        let standardOutputDrain = TideyRuntimePipeDrain(
            pipe: standardOutputPipe,
            maximumBytes: Self.maximumCapturedBytes
        )
        let standardErrorDrain = TideyRuntimePipeDrain(
            pipe: standardErrorPipe,
            maximumBytes: Self.maximumCapturedBytes
        )
        let termination = DispatchSemaphore(value: 0)

        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = standardOutputPipe
        process.standardError = standardErrorPipe
        process.terminationHandler = { _ in
            termination.signal()
        }
        standardOutputDrain.start()
        standardErrorDrain.start()

        do {
            try process.run()
        } catch {
            standardOutputDrain.closeParentWriteEnd()
            standardErrorDrain.closeParentWriteEnd()
            standardOutputDrain.finish()
            standardErrorDrain.finish()
            return TideyRuntimeTaskExecutionResult(
                launched: false,
                timedOut: false,
                terminationReason: -1,
                terminationStatus: -1,
                standardOutput: standardOutputDrain.string(),
                standardError: standardErrorDrain.string(),
                launchErrorDescription: error.localizedDescription
            )
        }

        standardOutputDrain.closeParentWriteEnd()
        standardErrorDrain.closeParentWriteEnd()

        var timedOut = false
        if termination.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            if process.isRunning {
                process.terminate()
            }
            if termination.wait(
                timeout: .now() + Self.terminationGrace
            ) == .timedOut,
               process.isRunning {
                Darwin.kill(process.processIdentifier, SIGKILL)
                _ = termination.wait(
                    timeout: .now() + Self.forcedTerminationGrace
                )
            }
        }

        standardOutputDrain.waitForEnd(timeout: Self.pipeDrainGrace)
        standardErrorDrain.waitForEnd(timeout: Self.pipeDrainGrace)

        let hasTerminated = !process.isRunning
        return TideyRuntimeTaskExecutionResult(
            launched: true,
            timedOut: timedOut,
            terminationReason: hasTerminated
                ? process.terminationReason.rawValue
                : -1,
            terminationStatus: hasTerminated
                ? process.terminationStatus
                : -1,
            standardOutput: standardOutputDrain.string(),
            standardError: standardErrorDrain.string(),
            launchErrorDescription: nil
        )
    }
}

@objc(TideyRuntimeRehydrationPhase)
enum TideyRuntimeRehydrationPhase: Int {
    case awaitingNativeRestore
    case nativeAttached
    case checkingTarget
    case attachingExisting
    case creatingTopology
    case resumingAgent
    case restored
    case unavailable
    case failed
}

@objc(TideyRuntimeRehydrationEvent)
enum TideyRuntimeRehydrationEvent: Int {
    case nativeReattachSucceeded
    case nativeReattachFailed
    case targetFound
    case targetMissing
    case targetProbeFailed
    case panelAttached
    case topologyCreated
    case agentResumed
    case operationFailed
}

@objc(TideyRuntimeRehydrationEffect)
enum TideyRuntimeRehydrationEffect: Int {
    case none
    case probeTarget
    case attachExisting
    case createTopology
    case resumeAgent
    case markUnavailable
    case resumeDirectAgent
}

@objc(TideyRuntimeTargetProbeResult)
enum TideyRuntimeTargetProbeResult: Int {
    case existing
    case missing
    case failed
}

@objc(TideyRuntimeRehydrationTransition)
@objcMembers
final class TideyRuntimeRehydrationTransition: NSObject {
    let nextPhase: TideyRuntimeRehydrationPhase
    let effect: TideyRuntimeRehydrationEffect

    init(
        nextPhase: TideyRuntimeRehydrationPhase,
        effect: TideyRuntimeRehydrationEffect
    ) {
        self.nextPhase = nextPhase
        self.effect = effect
    }
}

@objc(TideyRuntimeRehydrationReducing)
protocol TideyRuntimeRehydrationReducing: NSObjectProtocol {
    @objc(transitionFromPhase:event:descriptor:)
    func transition(
        from phase: TideyRuntimeRehydrationPhase,
        event: TideyRuntimeRehydrationEvent,
        descriptor: TideyRuntimeResumeDescriptor
    ) -> TideyRuntimeRehydrationTransition
}

@objc(TideyRuntimeTargetProbing)
protocol TideyRuntimeTargetProbing: NSObjectProtocol {
    @objc(probeTargetForDescriptor:completion:)
    func probeTarget(
        for descriptor: TideyRuntimeResumeDescriptor,
        completion: @escaping (TideyRuntimeTargetProbeResult) -> Void
    )
}

@objc(TideyRuntimeTopologyCreating)
protocol TideyRuntimeTopologyCreating: NSObjectProtocol {
    @objc(createTopologyForDescriptor:completion:)
    func createTopology(
        for descriptor: TideyRuntimeResumeDescriptor,
        completion: @escaping (Bool) -> Void
    )
}

@objc(TideyRuntimePanelLaunching)
protocol TideyRuntimePanelLaunching: NSObjectProtocol {
    @objc(attachPanel:toDescriptor:completion:)
    func attachPanel(
        _ panelID: String,
        to descriptor: TideyRuntimeResumeDescriptor,
        completion: @escaping (Bool) -> Void
    )

    @objc(resumeAgentInPanel:withDescriptor:completion:)
    func resumeAgent(
        in panelID: String,
        with descriptor: TideyRuntimeResumeDescriptor,
        completion: @escaping (Bool) -> Void
    )

    @objc(resumeDirectAgentInPanel:withDescriptor:completion:)
    func resumeDirectAgent(
        in panelID: String,
        with descriptor: TideyRuntimeResumeDescriptor,
        completion: @escaping (Bool) -> Void
    )

    @objc(markPanelUnavailable:descriptor:)
    func markPanelUnavailable(
        _ panelID: String,
        descriptor: TideyRuntimeResumeDescriptor
    )
}

@objc(TideyRuntimeDirectAgentCommandBuilder)
@objcMembers
final class TideyRuntimeDirectAgentCommandBuilder: NSObject {
    @objc(commandWithAgentExecutable:arguments:)
    func command(
        agentExecutable: String,
        arguments: [String]
    ) -> String? {
        let executableURL = URL(fileURLWithPath: agentExecutable)
        let executableName = executableURL.lastPathComponent
        let isCodexResume =
            executableName == "codex" &&
            arguments.count == 2 &&
            arguments[0] == "resume"
        let isClaudeResume =
            executableName == "claude" &&
            arguments.count == 2 &&
            arguments[0] == "--resume"
        guard agentExecutable.hasPrefix("/"),
              executableURL.standardizedFileURL.path == agentExecutable,
              isCodexResume || isClaudeResume,
              !arguments[1].isEmpty,
              !([agentExecutable] + arguments).contains(
                  where: { $0.contains("\u{0}") }
              ) else {
            return nil
        }
        return ([agentExecutable] + arguments)
            .map(Self.shellQuote)
            .joined(separator: " ")
    }

    private static func shellQuote(_ argument: String) -> String {
        "'" +
        argument.replacingOccurrences(
            of: "'",
            with: "'\\''"
        ) +
        "'"
    }
}

@objc(TideyRuntimeLoginShellCommandBuilder)
@objcMembers
final class TideyRuntimeLoginShellCommandBuilder: NSObject {
    private static let controllerRuntimeEnvironmentKeys = [
        "NO_COLOR",
        "CODEX_CI",
        "CODEX_THREAD_ID",
        "CODEX_PERMISSION_PROFILE",
        "CODEX_SANDBOX",
        "CODEX_SANDBOX_NETWORK_DISABLED",
        "CODEX_ESCALATE_SOCKET",
    ]

    @objc(argumentsWithLoginShellExecutable:innerCommand:)
    func arguments(
        loginShellExecutable: String,
        innerCommand: String
    ) -> [String]? {
        guard loginShellExecutable.hasPrefix("/"),
              URL(fileURLWithPath: loginShellExecutable)
                .standardizedFileURL.path == loginShellExecutable,
              !innerCommand.isEmpty,
              ![loginShellExecutable, innerCommand].contains(
                  where: { $0.contains("\u{0}") }
              ) else {
            return nil
        }
        let unsetControllerRuntime =
            "unset " +
            Self.controllerRuntimeEnvironmentKeys.joined(separator: " ")
        return [
            loginShellExecutable,
            "-lic",
            "\(unsetControllerRuntime); " +
                "\(innerCommand); exec " +
                "\(Self.shellQuote(loginShellExecutable)) -l",
        ]
    }

    @objc(commandWithLoginShellExecutable:innerCommand:)
    func command(
        loginShellExecutable: String,
        innerCommand: String
    ) -> String? {
        guard let arguments = arguments(
            loginShellExecutable: loginShellExecutable,
            innerCommand: innerCommand
        ) else {
            return nil
        }
        return arguments.map(Self.commandArgumentQuote)
            .joined(separator: " ")
    }

    private static func shellQuote(_ argument: String) -> String {
        "'" +
        argument.replacingOccurrences(
            of: "'",
            with: "'\\''"
        ) +
        "'"
    }

    private static func commandArgumentQuote(_ argument: String) -> String {
        let escapedBackslashes = argument.replacingOccurrences(
            of: "\\",
            with: "\\\\"
        )
        let escapedQuotes = escapedBackslashes.replacingOccurrences(
            of: "\"",
            with: "\\\""
        )
        return "\"\(escapedQuotes)\""
    }
}

@objc(TideyRuntimeAttachCommandBuilder)
@objcMembers
final class TideyRuntimeAttachCommandBuilder: NSObject {
    @objc(
        commandWithTmuxExecutable:socketArguments:tmuxSession:
    )
    func command(
        tmuxExecutable: String,
        socketArguments: [String],
        tmuxSession: String
    ) -> String? {
        let arguments =
            [tmuxExecutable] +
            socketArguments +
            [
                "attach-session",
                "-t",
                "=\(tmuxSession)",
            ]
        guard
            !tmuxExecutable.isEmpty,
            !tmuxSession.isEmpty,
            !arguments.contains(where: { $0.contains("\u{0}") })
        else {
            return nil
        }
        return arguments
            .map(Self.shellQuote)
            .joined(separator: " ")
    }

    private static func shellQuote(_ argument: String) -> String {
        "'" +
        argument.replacingOccurrences(
            of: "'",
            with: "'\\''"
        ) +
        "'"
    }
}

@objc(TideyRuntimeTmuxRespawnCommandBuilder)
@objcMembers
final class TideyRuntimeTmuxRespawnCommandBuilder: NSObject {
    @objc(
        argumentsWithPaneID:agentExecutable:loginShellExecutable:launch:
    )
    func arguments(
        paneID: String,
        agentExecutable: String,
        loginShellExecutable: String,
        launch: TideyRuntimeLaunchSpecification
    ) -> [String]? {
        let executableURL = URL(fileURLWithPath: agentExecutable)
        guard paneID.first == "%",
              paneID.dropFirst().isEmpty == false,
              paneID.dropFirst().allSatisfy(\.isNumber),
              agentExecutable.hasPrefix("/"),
              executableURL.standardizedFileURL.path ==
                agentExecutable,
              executableURL.lastPathComponent == launch.executable,
              launch.workingDirectory?.isEmpty != true,
              ![paneID, agentExecutable,
                 launch.workingDirectory ?? ""]
                .contains(where: { $0.contains("\u{0}") }),
              let command = TideyRuntimeDirectAgentCommandBuilder()
                .command(
                    agentExecutable: agentExecutable,
                    arguments: launch.arguments
                ),
              let loginShellArguments =
                TideyRuntimeLoginShellCommandBuilder().arguments(
                    loginShellExecutable: loginShellExecutable,
                    innerCommand: command
                ) else {
            return nil
        }
        var result = [
            "respawn-pane",
            "-k",
            "-t",
            paneID,
        ]
        if let workingDirectory = launch.workingDirectory {
            result.append(contentsOf: [
                "-c",
                workingDirectory,
            ])
        }
        result.append(
            loginShellArguments.map(Self.shellQuote)
                .joined(separator: " ")
        )
        return result
    }

    private static func shellQuote(_ argument: String) -> String {
        "'" +
        argument.replacingOccurrences(
            of: "'",
            with: "'\\''"
        ) +
        "'"
    }
}

@objc(TideyRuntimeTmuxPaneLaunchJob)
@objcMembers
final class TideyRuntimeTmuxPaneLaunchJob: NSObject {
    let windowIndex: Int
    let paneIndex: Int
    let launch: TideyRuntimeLaunchSpecification

    init(
        windowIndex: Int,
        paneIndex: Int,
        launch: TideyRuntimeLaunchSpecification
    ) {
        self.windowIndex = windowIndex
        self.paneIndex = paneIndex
        self.launch = launch
    }
}

@objc(TideyRuntimeTmuxAgentLaunchPlan)
@objcMembers
final class TideyRuntimeTmuxAgentLaunchPlan: NSObject {
    let jobs: [TideyRuntimeTmuxPaneLaunchJob]
    let activeWindowIndex: Int
    let activePaneIndex: Int

    init(
        jobs: [TideyRuntimeTmuxPaneLaunchJob],
        activeWindowIndex: Int,
        activePaneIndex: Int
    ) {
        self.jobs = jobs
        self.activeWindowIndex = activeWindowIndex
        self.activePaneIndex = activePaneIndex
    }
}

@objc(TideyRuntimeTmuxAgentLaunchPlanBuilder)
@objcMembers
final class TideyRuntimeTmuxAgentLaunchPlanBuilder: NSObject {
    @objc(planForDescriptor:)
    func plan(
        for descriptor: TideyRuntimeResumeDescriptor
    ) -> TideyRuntimeTmuxAgentLaunchPlan? {
        guard descriptor.kind == .agent,
              descriptor.restorePolicy == .create,
              let topology = descriptor.topology else {
            return nil
        }
        let windows = topology.windows.sorted {
            $0.index < $1.index
        }
        guard windows.isEmpty == false,
              Set(windows.map(\.index)).count == windows.count,
              windows.allSatisfy({ $0.index >= 0 }),
              windows.contains(where: {
                  $0.index == topology.activeWindowIndex &&
                      $0.panes.contains(where: {
                          $0.index == topology.activePaneIndex
                      })
              }) else {
            return nil
        }

        let topologyOwnsLaunches =
            descriptor.topologyOwnsAgentLaunches
        let topLevelLaunch = descriptor.agent?.launch
        if topologyOwnsLaunches {
            guard descriptor.agent == nil else {
                return nil
            }
        } else {
            guard descriptor.descriptorVersion ==
                    TideyRuntimeResumeDescriptor
                        .currentDescriptorVersion,
                  let topLevelLaunch,
                  Self.isAllowlisted(topLevelLaunch) else {
                return nil
            }
        }

        var jobs = [TideyRuntimeTmuxPaneLaunchJob]()
        var durableResumeKeys = Set<String>()
        var effectiveActivePaneIndex: Int?
        for window in windows {
            let panes = window.panes.sorted {
                $0.index < $1.index
            }
            guard panes.isEmpty == false,
                  Set(panes.map(\.index)).count == panes.count,
                  panes.allSatisfy({ $0.index >= 0 }),
                  topologyOwnsLaunches == false ||
                    panes.map(\.index) ==
                    Array(0 ..< panes.count) else {
                return nil
            }
            for (paneOffset, pane) in panes.enumerated() {
                var launch = pane.launch
                let isActive =
                    window.index == topology.activeWindowIndex &&
                    pane.index == topology.activePaneIndex
                if isActive {
                    effectiveActivePaneIndex = topologyOwnsLaunches
                        ? pane.index
                        : paneOffset
                }
                if topologyOwnsLaunches == false && isActive {
                    if let launch,
                       Self.launchesAreEqual(
                        launch,
                        topLevelLaunch
                       ) == false {
                        return nil
                    }
                    launch = topLevelLaunch
                }
                guard let launch else {
                    continue
                }
                guard Self.isAllowlisted(launch) else {
                    return nil
                }
                let durableResumeKey = [
                    launch.executable,
                    launch.arguments[1],
                ].joined(separator: "|")
                guard durableResumeKeys
                    .insert(durableResumeKey).inserted else {
                    return nil
                }
                jobs.append(
                    TideyRuntimeTmuxPaneLaunchJob(
                        windowIndex: window.index,
                        paneIndex: topologyOwnsLaunches
                            ? pane.index
                            : paneOffset,
                        launch: launch
                    )
                )
            }
        }
        guard jobs.isEmpty == false,
              let effectiveActivePaneIndex else {
            return nil
        }
        return TideyRuntimeTmuxAgentLaunchPlan(
            jobs: jobs,
            activeWindowIndex: topology.activeWindowIndex,
            activePaneIndex: effectiveActivePaneIndex
        )
    }

    private static func isAllowlisted(
        _ launch: TideyRuntimeLaunchSpecification
    ) -> Bool {
        let isClaude = launch.executable == "claude" &&
            launch.arguments.count == 2 &&
            launch.arguments[0] == "--resume"
        let isCodex = launch.executable == "codex" &&
            launch.arguments.count == 2 &&
            launch.arguments[0] == "resume"
        return (isClaude || isCodex) &&
            launch.arguments[1].isEmpty == false &&
            launch.workingDirectory?.isEmpty != true
    }

    private static func launchesAreEqual(
        _ lhs: TideyRuntimeLaunchSpecification,
        _ rhs: TideyRuntimeLaunchSpecification?
    ) -> Bool {
        guard let rhs else {
            return false
        }
        return lhs.executable == rhs.executable &&
            lhs.arguments == rhs.arguments &&
            lhs.workingDirectory == rhs.workingDirectory
    }
}

@objc(TideyRuntimeRehydrationReducer)
@objcMembers
final class TideyRuntimeRehydrationReducer:
    NSObject,
    TideyRuntimeRehydrationReducing {
    func transition(
        from phase: TideyRuntimeRehydrationPhase,
        event: TideyRuntimeRehydrationEvent,
        descriptor: TideyRuntimeResumeDescriptor
    ) -> TideyRuntimeRehydrationTransition {
        switch (phase, event) {
        case (.awaitingNativeRestore, .nativeReattachSucceeded)
            where descriptor.kind == .agent &&
                  descriptor.restorePolicy == .directResume:
            return transition(
                .resumingAgent,
                effect: .resumeDirectAgent
            )
        case (.awaitingNativeRestore, .nativeReattachSucceeded):
            return transition(.nativeAttached)
        case (.awaitingNativeRestore, .nativeReattachFailed)
            where descriptor.kind == .agent &&
                  descriptor.restorePolicy == .directResume:
            return transition(
                .resumingAgent,
                effect: .resumeDirectAgent
            )
        case (.awaitingNativeRestore, .nativeReattachFailed):
            return transition(.checkingTarget, effect: .probeTarget)
        case (.checkingTarget, .targetFound):
            return transition(
                .attachingExisting,
                effect: .attachExisting
            )
        case (.checkingTarget, .targetMissing)
            where descriptor.restorePolicy == .create &&
                  descriptor.kind == .agent:
            return transition(
                .creatingTopology,
                effect: .createTopology
            )
        case (.checkingTarget, .targetMissing):
            return transition(
                .unavailable,
                effect: .markUnavailable
            )
        case (.creatingTopology, .topologyCreated):
            return transition(
                .resumingAgent,
                effect: .resumeAgent
            )
        case (.resumingAgent, .agentResumed)
            where descriptor.restorePolicy == .directResume:
            return transition(.restored)
        case (.resumingAgent, .agentResumed):
            return transition(
                .attachingExisting,
                effect: .attachExisting
            )
        case (.attachingExisting, .panelAttached):
            return transition(.restored)
        case (.checkingTarget, .targetProbeFailed),
             (.attachingExisting, .operationFailed),
             (.creatingTopology, .operationFailed),
             (.resumingAgent, .operationFailed):
            return transition(.failed)
        default:
            return transition(phase)
        }
    }

    private func transition(
        _ phase: TideyRuntimeRehydrationPhase,
        effect: TideyRuntimeRehydrationEffect = .none
    ) -> TideyRuntimeRehydrationTransition {
        TideyRuntimeRehydrationTransition(
            nextPhase: phase,
            effect: effect
        )
    }
}

@objc(TideyRuntimeRehydrationStateMachine)
@objcMembers
final class TideyRuntimeRehydrationStateMachine: NSObject {
    private struct Key: Hashable {
        let panelID: String
        let descriptorRevision: Int64
    }

    private final class Entry {
        let descriptor: TideyRuntimeResumeDescriptor
        var phase: TideyRuntimeRehydrationPhase
        var step = 0

        init(
            descriptor: TideyRuntimeResumeDescriptor,
            phase: TideyRuntimeRehydrationPhase
        ) {
            self.descriptor = descriptor
            self.phase = phase
        }
    }

    private let reducer: TideyRuntimeRehydrationReducing
    private let targetProbe: TideyRuntimeTargetProbing
    private let topologyCreator: TideyRuntimeTopologyCreating
    private let panelLauncher: TideyRuntimePanelLaunching
    private var entries: [Key: Entry] = [:]

    init(
        reducer: TideyRuntimeRehydrationReducing,
        targetProbe: TideyRuntimeTargetProbing,
        topologyCreator: TideyRuntimeTopologyCreating,
        panelLauncher: TideyRuntimePanelLaunching
    ) {
        self.reducer = reducer
        self.targetProbe = targetProbe
        self.topologyCreator = topologyCreator
        self.panelLauncher = panelLauncher
    }

    @objc(handlePanelID:descriptor:nativeReattachOutcome:)
    func handle(
        panelID: String,
        descriptor: TideyRuntimeResumeDescriptor,
        nativeReattachOutcome: TideyNativeServerReattachOutcome
    ) {
        it_assert(Thread.isMainThread)
        let key = Key(
            panelID: panelID,
            descriptorRevision: descriptor.revision
        )
        guard entries[key] == nil else {
            return
        }

        let entry = Entry(
            descriptor: descriptor,
            phase: .awaitingNativeRestore
        )
        entries[key] = entry

        let event: TideyRuntimeRehydrationEvent
        switch nativeReattachOutcome {
        case .succeeded:
            event = .nativeReattachSucceeded
        case .failed:
            event = .nativeReattachFailed
        case .notAttempted:
            event = .nativeReattachFailed
        @unknown default:
            return
        }
        advance(
            key: key,
            panelID: panelID,
            event: event,
            expectedStep: entry.step
        )
    }

    private func advance(
        key: Key,
        panelID: String,
        event: TideyRuntimeRehydrationEvent,
        expectedStep: Int
    ) {
        it_assert(Thread.isMainThread)
        guard let entry = entries[key],
              entry.step == expectedStep else {
            return
        }

        let transition = reducer.transition(
            from: entry.phase,
            event: event,
            descriptor: entry.descriptor
        )
        entry.phase = transition.nextPhase
        entry.step += 1
        perform(
            transition.effect,
            key: key,
            panelID: panelID,
            descriptor: entry.descriptor,
            expectedStep: entry.step
        )
    }

    private func perform(
        _ effect: TideyRuntimeRehydrationEffect,
        key: Key,
        panelID: String,
        descriptor: TideyRuntimeResumeDescriptor,
        expectedStep: Int
    ) {
        switch effect {
        case .none:
            return
        case .probeTarget:
            targetProbe.probeTarget(
                for: descriptor
            ) { [weak self] result in
                let event: TideyRuntimeRehydrationEvent
                switch result {
                case .existing:
                    event = .targetFound
                case .missing:
                    event = .targetMissing
                case .failed:
                    event = .targetProbeFailed
                @unknown default:
                    event = .targetProbeFailed
                }
                self?.receive(
                    key: key,
                    panelID: panelID,
                    event: event,
                    expectedStep: expectedStep
                )
            }
        case .attachExisting:
            panelLauncher.attachPanel(
                panelID,
                to: descriptor
            ) { [weak self] succeeded in
                self?.receive(
                    key: key,
                    panelID: panelID,
                    event: succeeded
                        ? .panelAttached
                        : .operationFailed,
                    expectedStep: expectedStep
                )
            }
        case .createTopology:
            topologyCreator.createTopology(
                for: descriptor
            ) { [weak self] succeeded in
                self?.receive(
                    key: key,
                    panelID: panelID,
                    event: succeeded
                        ? .topologyCreated
                        : .operationFailed,
                    expectedStep: expectedStep
                )
            }
        case .resumeAgent:
            panelLauncher.resumeAgent(
                in: panelID,
                with: descriptor
            ) { [weak self] succeeded in
                self?.receive(
                    key: key,
                    panelID: panelID,
                    event: succeeded
                        ? .agentResumed
                        : .operationFailed,
                    expectedStep: expectedStep
                )
            }
        case .resumeDirectAgent:
            panelLauncher.resumeDirectAgent(
                in: panelID,
                with: descriptor
            ) { [weak self] succeeded in
                self?.receive(
                    key: key,
                    panelID: panelID,
                    event: succeeded
                        ? .agentResumed
                        : .operationFailed,
                    expectedStep: expectedStep
                )
            }
        case .markUnavailable:
            panelLauncher.markPanelUnavailable(
                panelID,
                descriptor: descriptor
            )
        @unknown default:
            return
        }
    }

    private func receive(
        key: Key,
        panelID: String,
        event: TideyRuntimeRehydrationEvent,
        expectedStep: Int
    ) {
        if Thread.isMainThread {
            advance(
                key: key,
                panelID: panelID,
                event: event,
                expectedStep: expectedStep
            )
            return
        }
        DispatchQueue.main.async { [weak self] in
            self?.advance(
                key: key,
                panelID: panelID,
                event: event,
                expectedStep: expectedStep
            )
        }
    }
}
