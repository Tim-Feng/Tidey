import XCTest
@testable import iTerm2SharedARC

final class TideyRuntimeResumeDescriptorTests: XCTestCase {
    func testVersionedDescriptorAndNativeReattachOutcomeSeamsCompile() {
        let launch = TideyRuntimeLaunchSpecification(
            executable: "/usr/local/bin/codex",
            arguments: ["resume", "thread-123"],
            workingDirectory: "/Users/timfeng/GitHub/Tidey"
        )
        let pane = TideyRuntimeTmuxPaneTopology(
            index: 2,
            workingDirectory: "/Users/timfeng/GitHub/Tidey",
            launch: launch
        )
        let window = TideyRuntimeTmuxWindowTopology(
            index: 1,
            name: "Tidey",
            panes: [pane]
        )
        let topology = TideyRuntimeTmuxTopology(
            windows: [window],
            activeWindowIndex: 1,
            activePaneIndex: 2
        )
        let target = TideyRuntimeResumeTarget(
            socketName: "tidey",
            tmuxSession: "tidey-codex"
        )
        let agent = TideyRuntimeAgentResumeSpecification(
            vendor: .codex,
            durableResumeID: "thread-123",
            launch: launch
        )
        let descriptor = TideyRuntimeResumeDescriptor(
            descriptorVersion:
                TideyRuntimeResumeDescriptor.currentDescriptorVersion,
            revision: 7,
            kind: .agent,
            restorePolicy: .create,
            target: target,
            topology: topology,
            agent: agent
        )

        XCTAssertEqual(descriptor.descriptorVersion, 1)
        XCTAssertEqual(descriptor.revision, 7)
        XCTAssertEqual(descriptor.kind, .agent)
        XCTAssertEqual(descriptor.restorePolicy, .create)
        XCTAssertTrue(descriptor.target === target)
        XCTAssertTrue(descriptor.topology === topology)
        XCTAssertTrue(descriptor.agent === agent)
        XCTAssertEqual(descriptor.target.socketEndpointKind, .name)
        XCTAssertNil(descriptor.target.socketPath)
        XCTAssertEqual(descriptor.target.socketName, "tidey")
        XCTAssertEqual(descriptor.target.tmuxSession, "tidey-codex")
        XCTAssertEqual(descriptor.topology?.activeWindowIndex, 1)
        XCTAssertEqual(descriptor.topology?.activePaneIndex, 2)
        XCTAssertEqual(descriptor.topology?.windows.first?.panes.first?.index, 2)
        XCTAssertEqual(descriptor.agent?.launch.arguments, ["resume", "thread-123"])
        XCTAssertEqual(
            [
                TideyRuntimeResumeKind.ordinaryTmux,
                .agent,
                .generic
            ].map(\.rawValue),
            [0, 1, 2]
        )
        XCTAssertEqual(
            [
                TideyRuntimeRestorePolicy.create,
                .attachOnly,
                .runtime
            ].map(\.rawValue),
            [0, 1, 2]
        )
        XCTAssertEqual(
            [
                TideyRuntimeAgentVendor.claude,
                .codex
            ].map(\.rawValue),
            [0, 1]
        )
        XCTAssertEqual(
            [
                TideyRuntimeTmuxSocketEndpointKind.path,
                .name,
                .defaultSocket
            ].map(\.rawValue),
            [0, 1, 2]
        )

        let pathTarget = TideyRuntimeResumeTarget(
            socketPath: "/tmp/tidey.sock",
            tmuxSession: "path-session"
        )
        XCTAssertEqual(pathTarget.socketEndpointKind, .path)
        XCTAssertEqual(pathTarget.socketPath, "/tmp/tidey.sock")
        XCTAssertNil(pathTarget.socketName)

        let defaultTarget = TideyRuntimeResumeTarget(
            defaultSocketAndTmuxSession: "default-session"
        )
        XCTAssertEqual(defaultTarget.socketEndpointKind, .defaultSocket)
        XCTAssertNil(defaultTarget.socketPath)
        XCTAssertNil(defaultTarget.socketName)

        let outcomeKeyPath:
            ReferenceWritableKeyPath<
                PTYSession,
                TideyNativeServerReattachOutcome
            > = \.tideyNativeServerReattachOutcome
        XCTAssertNotNil(outcomeKeyPath)
        XCTAssertEqual(TideyNativeServerReattachOutcome.notAttempted.rawValue, 0)
    }
}
