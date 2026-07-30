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
        TideyRuntimeRehydrationTransition(
            nextPhase: phase,
            effect: .none
        )
    }
}

@objc(TideyRuntimeRehydrationStateMachine)
@objcMembers
final class TideyRuntimeRehydrationStateMachine: NSObject {
    private let reducer: TideyRuntimeRehydrationReducing
    private let targetProbe: TideyRuntimeTargetProbing
    private let topologyCreator: TideyRuntimeTopologyCreating
    private let panelLauncher: TideyRuntimePanelLaunching

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
        // Behavioral dispatch and exactly-once bookkeeping land in the next
        // TDD row. This row only establishes the injectable boundary.
    }
}
