import Foundation

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
    @objc(commandWithLoginShellExecutable:innerCommand:)
    func command(
        loginShellExecutable: String,
        innerCommand: String
    ) -> String? {
        guard loginShellExecutable.hasPrefix("/"),
              URL(fileURLWithPath: loginShellExecutable)
                .standardizedFileURL.path == loginShellExecutable,
              !innerCommand.isEmpty,
              ![loginShellExecutable, innerCommand].contains(
                  where: { $0.contains("\u{0}") }
              ) else {
            return nil
        }
        return [
            loginShellExecutable,
            "-lic",
            "\(innerCommand); exec " +
                "\(Self.shellQuote(loginShellExecutable)) -l",
        ]
        .map(Self.commandArgumentQuote)
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
    @objc(argumentsWithPaneID:agentExecutable:launch:)
    func arguments(
        paneID: String,
        agentExecutable: String,
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
        result.append(command)
        return result
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
        for window in windows {
            let panes = window.panes.sorted {
                $0.index < $1.index
            }
            guard panes.isEmpty == false,
                  Set(panes.map(\.index)).count == panes.count,
                  panes.map(\.index) == Array(0 ..< panes.count) else {
                return nil
            }
            for pane in panes {
                var launch = pane.launch
                let isActive =
                    window.index == topology.activeWindowIndex &&
                    pane.index == topology.activePaneIndex
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
                        paneIndex: pane.index,
                        launch: launch
                    )
                )
            }
        }
        guard jobs.isEmpty == false else {
            return nil
        }
        return TideyRuntimeTmuxAgentLaunchPlan(
            jobs: jobs,
            activeWindowIndex: topology.activeWindowIndex,
            activePaneIndex: topology.activePaneIndex
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
            return
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
