import XCTest
@testable import iTerm2SharedARC

final class TideyRuntimeRehydrationStateMachineTests: XCTestCase {
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
    private(set) var unavailableCount = 0
    private var attachCompletion: ((Bool) -> Void)?
    private var resumeCompletion: ((Bool) -> Void)?

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
