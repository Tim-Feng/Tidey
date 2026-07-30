import XCTest
@testable import iTerm2SharedARC

final class TideyRuntimeResumeDescriptorTests: XCTestCase {
    func testOrdinaryTmuxMetadataProducesAttachOnlyDescriptorWithoutBridge() throws {
        let factory = TideyRuntimeResumeDescriptorFactory()
        let pathDescriptor = try XCTUnwrap(
            factory.descriptor(
                fromOrdinaryTmuxMetadata: [
                    "socket_path": "/tmp/tidey.sock",
                    "target_session": "work"
                ]
            )
        )
        assertOrdinaryTmuxDescriptor(
            pathDescriptor,
            endpointKind: .path,
            socketPath: "/tmp/tidey.sock",
            socketName: nil,
            session: "work"
        )

        let nameDescriptor = try XCTUnwrap(
            factory.descriptor(
                fromOrdinaryTmuxMetadata: [
                    "socket_name": "tidey",
                    "target_session": "review"
                ]
            )
        )
        assertOrdinaryTmuxDescriptor(
            nameDescriptor,
            endpointKind: .name,
            socketPath: nil,
            socketName: "tidey",
            session: "review"
        )

        let defaultDescriptor = try XCTUnwrap(
            factory.descriptor(
                fromOrdinaryTmuxMetadata: [
                    "target_session": "default-work"
                ]
            )
        )
        assertOrdinaryTmuxDescriptor(
            defaultDescriptor,
            endpointKind: .defaultSocket,
            socketPath: nil,
            socketName: nil,
            session: "default-work"
        )

        XCTAssertNil(
            factory.descriptor(
                fromOrdinaryTmuxMetadata: [
                    "socket_path": "/tmp/tidey.sock",
                    "socket_name": "tidey",
                    "target_session": "work"
                ]
            )
        )
        XCTAssertNil(
            factory.descriptor(
                fromOrdinaryTmuxMetadata: [
                    "socket_path": "",
                    "target_session": "work"
                ]
            )
        )
        XCTAssertNil(
            factory.descriptor(
                fromOrdinaryTmuxMetadata: [
                    "socket_name": "",
                    "target_session": "work"
                ]
            )
        )
        XCTAssertNil(
            factory.descriptor(
                fromOrdinaryTmuxMetadata: [:]
            )
        )
        XCTAssertNil(
            factory.descriptor(
                fromOrdinaryTmuxMetadata: [
                    "target_session": ""
                ]
            )
        )

        let panel = TideyWorkspaceRestorationPanelInput(
            panelID: "saved-panel",
            hasSessions: true,
            isNativeTmux: false,
            runtimeResumeDescriptor: pathDescriptor
        )
        let workspace = TideyWorkspaceRestorationWorkspaceInput(
            workspaceID: "workspace",
            title: nil,
            pinned: false,
            panels: [panel],
            selectedPanelID: panel.panelID
        )
        let planner = TideyWorkspaceRestorationPlanner()
        let capturePlan = planner.capturePlan(
            workspaces: [workspace],
            visiblePanels: [panel],
            selectedWorkspaceID: workspace.workspaceID
        )
        XCTAssertTrue(
            capturePlan.state.runtimeDescriptorsByPanelID[panel.panelID]
                === pathDescriptor
        )

        let codec = TideyWorkspaceRestorationStateDictionaryCodec()
        let encoded = try codec.encode(capturePlan.state)
        let encodedDescriptors = try XCTUnwrap(
            encoded["runtime_descriptors_by_panel_id"]
                as? [String: [String: Any]]
        )
        XCTAssertEqual(
            encodedDescriptors[panel.panelID]?["kind"] as? String,
            "ordinary_tmux"
        )

        let decoded = try codec.decode(encoded)
        let decodedDescriptor = try XCTUnwrap(
            decoded.runtimeDescriptorsByPanelID[panel.panelID]
        )
        assertOrdinaryTmuxDescriptor(
            decodedDescriptor,
            endpointKind: .path,
            socketPath: "/tmp/tidey.sock",
            socketName: nil,
            session: "work"
        )

        var malformedStateDictionary = encoded
        var malformedDescriptors = try XCTUnwrap(
            malformedStateDictionary["runtime_descriptors_by_panel_id"]
                as? [String: Any]
        )
        var malformedDescriptor = try XCTUnwrap(
            malformedDescriptors[panel.panelID] as? [String: Any]
        )
        malformedDescriptor["kind"] = "unknown"
        malformedDescriptors[panel.panelID] = malformedDescriptor
        malformedStateDictionary["runtime_descriptors_by_panel_id"] =
            malformedDescriptors
        let degradedState = try codec.decode(malformedStateDictionary)
        XCTAssertEqual(
            degradedState.workspaces.map(\.workspaceID),
            capturePlan.state.workspaces.map(\.workspaceID)
        )
        XCTAssertTrue(
            degradedState.runtimeDescriptorsByPanelID.isEmpty
        )

        let hydrated = planner.hydrationState(
            savedState: decoded,
            availablePanelIDs: ["actual-panel"],
            panelIDRemap: ["saved-panel": "actual-panel"]
        )
        XCTAssertNil(
            hydrated.runtimeDescriptorsByPanelID["saved-panel"]
        )
        assertOrdinaryTmuxDescriptor(
            try XCTUnwrap(
                hydrated.runtimeDescriptorsByPanelID["actual-panel"]
            ),
            endpointKind: .path,
            socketPath: "/tmp/tidey.sock",
            socketName: nil,
            session: "work"
        )
    }

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

    private func assertOrdinaryTmuxDescriptor(
        _ descriptor: TideyRuntimeResumeDescriptor,
        endpointKind: TideyRuntimeTmuxSocketEndpointKind,
        socketPath: String?,
        socketName: String?,
        session: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(
            descriptor.descriptorVersion,
            TideyRuntimeResumeDescriptor.currentDescriptorVersion,
            file: file,
            line: line
        )
        XCTAssertEqual(descriptor.revision, 1, file: file, line: line)
        XCTAssertEqual(
            descriptor.kind,
            .ordinaryTmux,
            file: file,
            line: line
        )
        XCTAssertEqual(
            descriptor.restorePolicy,
            .attachOnly,
            file: file,
            line: line
        )
        XCTAssertEqual(
            descriptor.target.socketEndpointKind,
            endpointKind,
            file: file,
            line: line
        )
        XCTAssertEqual(
            descriptor.target.socketPath,
            socketPath,
            file: file,
            line: line
        )
        XCTAssertEqual(
            descriptor.target.socketName,
            socketName,
            file: file,
            line: line
        )
        XCTAssertEqual(
            descriptor.target.tmuxSession,
            session,
            file: file,
            line: line
        )
        XCTAssertNil(descriptor.topology, file: file, line: line)
        XCTAssertNil(descriptor.agent, file: file, line: line)
    }
}
