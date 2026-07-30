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
}

private final class TideyRuntimeTargetProbeSpy:
    NSObject,
    TideyRuntimeTargetProbing {
    func probeTarget(
        for descriptor: TideyRuntimeResumeDescriptor,
        completion: @escaping (TideyRuntimeTargetProbeResult) -> Void
    ) {
        completion(.missing)
    }
}

private final class TideyRuntimeTopologyCreatorSpy:
    NSObject,
    TideyRuntimeTopologyCreating {
    func createTopology(
        for descriptor: TideyRuntimeResumeDescriptor,
        completion: @escaping (Bool) -> Void
    ) {
        completion(true)
    }
}

private final class TideyRuntimePanelLauncherSpy:
    NSObject,
    TideyRuntimePanelLaunching {
    func attachPanel(
        _ panelID: String,
        to descriptor: TideyRuntimeResumeDescriptor,
        completion: @escaping (Bool) -> Void
    ) {
        completion(true)
    }

    func resumeAgent(
        in panelID: String,
        with descriptor: TideyRuntimeResumeDescriptor,
        completion: @escaping (Bool) -> Void
    ) {
        completion(true)
    }

    func markPanelUnavailable(
        _ panelID: String,
        descriptor: TideyRuntimeResumeDescriptor
    ) {}
}
