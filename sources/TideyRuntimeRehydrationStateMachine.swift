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

    @objc(markPanelUnavailable:descriptor:)
    func markPanelUnavailable(
        _ panelID: String,
        descriptor: TideyRuntimeResumeDescriptor
    )
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
        case (.awaitingNativeRestore, .nativeReattachSucceeded):
            return transition(.nativeAttached)
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
