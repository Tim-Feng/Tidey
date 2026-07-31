import XCTest
@testable import iTerm2SharedARC

final class TideyRuntimeResumeDescriptorTests: XCTestCase {
    func testRestoredSessionIdentityOptionSeamsCompile() {
        let options: [String: Any] = [
            PTYSessionArrangementOptionsTideyWorkspaceID:
                "workspace-restored",
            PTYSessionArrangementOptionsTideyPanelID:
                "panel-restored"
        ]
        let environment = PTYSession
            .tideyEnvironment(
                byApplyingRestorationOptions:
                options,
                toEnvironment: ["PATH": "/usr/bin"]
            )

        XCTAssertEqual(environment, ["PATH": "/usr/bin"])
    }

    func testDirectAgentDescriptorSeamsCompile() {
        let launch = TideyRuntimeLaunchSpecification(
            executable: "codex",
            arguments: ["resume", "thread-direct"],
            workingDirectory: "/tmp/project"
        )
        let descriptor = TideyRuntimeResumeDescriptor(
            descriptorVersion:
                TideyRuntimeResumeDescriptor.currentDescriptorVersion,
            revision: 1,
            kind: .agent,
            restorePolicy: .directResume,
            target: nil,
            topology: nil,
            agent: TideyRuntimeAgentResumeSpecification(
                vendor: .codex,
                durableResumeID: "thread-direct",
                launch: launch
            )
        )

        XCTAssertEqual(descriptor.restorePolicy, .directResume)
        XCTAssertNil(descriptor.target)
    }

    func testSocketUpdateAcceptsDirectAgentWithoutTmuxCarrier()
        throws {
        let gate = TideyRuntimeResumeDescriptorUpdateGate()
        let payload = directSocketUpdatePayload(
            durableResumeID: "thread-direct",
            workingDirectory: "/tmp/direct-project"
        )

        let accepted = gate.acceptUpdatePayload(
            payload,
            currentWorkspaceID: "workspace-direct",
            currentPanelID: "panel-direct"
        )

        XCTAssertTrue(accepted.accepted)
        XCTAssertTrue(accepted.changed)
        XCTAssertEqual(accepted.descriptor?.kind, .agent)
        XCTAssertEqual(
            accepted.descriptor?.restorePolicy,
            .directResume
        )
        XCTAssertNil(accepted.descriptor?.target)
        XCTAssertNil(accepted.descriptor?.topology)
        XCTAssertEqual(
            accepted.descriptor?.agent?.launch.arguments,
            ["resume", "thread-direct"]
        )

        let codec = TideyRuntimeResumeDescriptorDictionaryCodec()
        let roundTripped = try codec.decode(
            codec.encode(try XCTUnwrap(accepted.descriptor))
        )
        XCTAssertEqual(roundTripped.restorePolicy, .directResume)
        XCTAssertNil(roundTripped.target)

        var tmuxBoundPayload = payload
        var tmuxBinding = try XCTUnwrap(
            tmuxBoundPayload["binding"] as? [String: Any]
        )
        tmuxBinding["tmux_pane_id"] = "%7"
        tmuxBoundPayload["binding"] = tmuxBinding
        XCTAssertEqual(
            gate.acceptUpdatePayload(
                tmuxBoundPayload,
                currentWorkspaceID: "workspace-direct",
                currentPanelID: "panel-direct"
            ).errorCode,
            "stale_binding"
        )

        var targetedPayload = payload
        var targetedDescriptor = try XCTUnwrap(
            targetedPayload["descriptor"] as? [String: Any]
        )
        targetedDescriptor["target"] = [
            "socket_endpoint_kind": "default",
            "tmux_session": "unexpected"
        ]
        targetedPayload["descriptor"] = targetedDescriptor
        XCTAssertEqual(
            gate.acceptUpdatePayload(
                targetedPayload,
                currentWorkspaceID: "workspace-direct",
                currentPanelID: "panel-direct"
            ).errorCode,
            "invalid_descriptor"
        )
    }

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

    func testSocketUpdateAcceptsOnlyCurrentWorkspacePanelBinding() throws {
        let gate = TideyRuntimeResumeDescriptorUpdateGate(
            initialDescriptorsByPanelID: [:]
        )
        let originalPayload = socketUpdatePayload(
            durableResumeID: "thread-1",
            workingDirectory: "/tmp/project"
        )

        let accepted = gate.acceptUpdatePayload(
            originalPayload,
            currentWorkspaceID: "workspace-1",
            currentPanelID: "panel-1"
        )
        XCTAssertTrue(accepted.accepted)
        XCTAssertTrue(accepted.changed)
        XCTAssertNil(accepted.errorCode)
        XCTAssertEqual(accepted.descriptor?.revision, 1)
        XCTAssertEqual(
            accepted.descriptor?.agent?.durableResumeID,
            "thread-1"
        )

        let staleWorkspace = gate.acceptUpdatePayload(
            originalPayload,
            currentWorkspaceID: "workspace-new",
            currentPanelID: "panel-1"
        )
        XCTAssertFalse(staleWorkspace.accepted)
        XCTAssertFalse(staleWorkspace.changed)
        XCTAssertEqual(staleWorkspace.errorCode, "stale_binding")
        XCTAssertEqual(
            gate.descriptor(forPanelID: "panel-1")?.revision,
            1
        )

        let stalePanel = gate.acceptUpdatePayload(
            originalPayload,
            currentWorkspaceID: "workspace-1",
            currentPanelID: "panel-new"
        )
        XCTAssertFalse(stalePanel.accepted)
        XCTAssertEqual(stalePanel.errorCode, "stale_binding")

        var malformedPayload = originalPayload
        var malformedDescriptor = try XCTUnwrap(
            malformedPayload["descriptor"] as? [String: Any]
        )
        malformedDescriptor["topology"] = [
            "windows": "not-an-array",
            "active_window_index": 0,
            "active_pane_index": 0
        ]
        malformedPayload["descriptor"] = malformedDescriptor
        let malformed = gate.acceptUpdatePayload(
            malformedPayload,
            currentWorkspaceID: "workspace-1",
            currentPanelID: "panel-1"
        )
        XCTAssertFalse(malformed.accepted)
        XCTAssertEqual(malformed.errorCode, "invalid_descriptor")
        XCTAssertEqual(
            gate.descriptor(forPanelID: "panel-1")?.revision,
            1
        )

        var unsafePayload = originalPayload
        var unsafeDescriptor = try XCTUnwrap(
            unsafePayload["descriptor"] as? [String: Any]
        )
        var unsafeTopology = try XCTUnwrap(
            unsafeDescriptor["topology"] as? [String: Any]
        )
        var unsafeWindows = try XCTUnwrap(
            unsafeTopology["windows"] as? [[String: Any]]
        )
        var unsafeWindow = try XCTUnwrap(unsafeWindows.first)
        var unsafePanes = try XCTUnwrap(
            unsafeWindow["panes"] as? [[String: Any]]
        )
        var unsafePane = try XCTUnwrap(unsafePanes.first)
        unsafePane["launch"] = [
            "executable": "/bin/sh",
            "arguments": ["-c", "touch /tmp/should-not-run"],
            "cwd": "/tmp/project"
        ]
        unsafePanes[0] = unsafePane
        unsafeWindow["panes"] = unsafePanes
        unsafeWindows[0] = unsafeWindow
        unsafeTopology["windows"] = unsafeWindows
        unsafeDescriptor["topology"] = unsafeTopology
        unsafePayload["descriptor"] = unsafeDescriptor
        let unsafe = gate.acceptUpdatePayload(
            unsafePayload,
            currentWorkspaceID: "workspace-1",
            currentPanelID: "panel-1"
        )
        XCTAssertFalse(unsafe.accepted)
        XCTAssertEqual(unsafe.errorCode, "invalid_descriptor")
        XCTAssertEqual(
            gate.descriptor(forPanelID: "panel-1")?.revision,
            1
        )

        let afterBridgeRestart = gate.acceptUpdatePayload(
            originalPayload,
            currentWorkspaceID: "workspace-1",
            currentPanelID: "panel-1"
        )
        XCTAssertTrue(afterBridgeRestart.accepted)
        XCTAssertFalse(afterBridgeRestart.changed)
        XCTAssertEqual(afterBridgeRestart.descriptor?.revision, 1)

        let changedPayload = socketUpdatePayload(
            durableResumeID: "thread-2",
            workingDirectory: "/tmp/project"
        )
        let changed = gate.acceptUpdatePayload(
            changedPayload,
            currentWorkspaceID: "workspace-1",
            currentPanelID: "panel-1"
        )
        XCTAssertTrue(changed.accepted)
        XCTAssertTrue(changed.changed)
        XCTAssertEqual(changed.descriptor?.revision, 2)

        let hydratedGate = TideyRuntimeResumeDescriptorUpdateGate(
            initialDescriptorsByPanelID: [
                "panel-1": try XCTUnwrap(changed.descriptor)
            ]
        )
        let unchangedAfterTideyRestart =
            hydratedGate.acceptUpdatePayload(
                changedPayload,
                currentWorkspaceID: "workspace-1",
                currentPanelID: "panel-1"
            )
        XCTAssertTrue(unchangedAfterTideyRestart.accepted)
        XCTAssertFalse(unchangedAfterTideyRestart.changed)
        XCTAssertEqual(
            unchangedAfterTideyRestart.descriptor?.revision,
            2
        )
        let changedAfterTideyRestart =
            hydratedGate.acceptUpdatePayload(
                socketUpdatePayload(
                    durableResumeID: "thread-after-restart",
                    workingDirectory: "/tmp/project"
                ),
                currentWorkspaceID: "workspace-1",
                currentPanelID: "panel-1"
            )
        XCTAssertTrue(changedAfterTideyRestart.accepted)
        XCTAssertTrue(changedAfterTideyRestart.changed)
        XCTAssertEqual(changedAfterTideyRestart.descriptor?.revision, 3)

        let resultLock = NSLock()
        var concurrentResults:
            [TideyRuntimeResumeDescriptorUpdateResult] = []
        DispatchQueue.concurrentPerform(iterations: 12) { index in
            let result = gate.acceptUpdatePayload(
                socketUpdatePayload(
                    durableResumeID: "thread-\(index + 3)",
                    workingDirectory: "/tmp/project/\(index)"
                ),
                currentWorkspaceID: "workspace-1",
                currentPanelID: "panel-1"
            )
            resultLock.lock()
            concurrentResults.append(result)
            resultLock.unlock()
        }
        XCTAssertEqual(concurrentResults.count, 12)
        XCTAssertTrue(concurrentResults.allSatisfy(\.accepted))
        XCTAssertTrue(concurrentResults.allSatisfy(\.changed))
        XCTAssertEqual(
            Set(concurrentResults.compactMap(\.descriptor?.revision)),
            Set(3 ... 14)
        )
        XCTAssertEqual(
            gate.descriptor(forPanelID: "panel-1")?.revision,
            14
        )

        let persistedDescriptor = try XCTUnwrap(
            gate.descriptor(forPanelID: "panel-1")
        )
        let state = TideyWorkspaceRestorationState(
            schemaVersion:
                TideyWorkspaceRestorationState.currentSchemaVersion,
            selectedWorkspaceID: "workspace-1",
            workspaces: [
                TideyWorkspaceState(
                    workspaceID: "workspace-1",
                    title: nil,
                    pinned: false,
                    panelIDs: ["panel-1"],
                    selectedPanelID: "panel-1"
                )
            ],
            runtimeDescriptorsByPanelID: [
                "panel-1": persistedDescriptor
            ]
        )
        let codec = TideyWorkspaceRestorationStateDictionaryCodec()
        let decoded = try codec.decode(codec.encode(state))
        let roundTripped = try XCTUnwrap(
            decoded.runtimeDescriptorsByPanelID["panel-1"]
        )
        XCTAssertEqual(roundTripped.revision, 14)
        XCTAssertEqual(roundTripped.kind, .agent)
        XCTAssertEqual(roundTripped.restorePolicy, .create)
        let roundTrippedResumeID = try XCTUnwrap(
            roundTripped.agent?.durableResumeID
        )
        XCTAssertEqual(
            roundTripped.agent?.launch.arguments,
            ["resume", roundTrippedResumeID]
        )
    }

    func testManagedRestoreDefersSavedProgramOnlyAfterNativeReattachFails() {
        let policy = TideyManagedRestoreLaunchPolicy()

        XCTAssertEqual(
            policy.disposition(
                nativeReattachOutcome: .notAttempted,
                hasValidDescriptor: true
            ),
            .launchSavedProgram
        )
        XCTAssertEqual(
            policy.disposition(
                nativeReattachOutcome: .succeeded,
                hasValidDescriptor: true
            ),
            .preserveNativeAttachment
        )
        XCTAssertEqual(
            policy.disposition(
                nativeReattachOutcome: .failed,
                hasValidDescriptor: false
            ),
            .launchSavedProgram
        )
        XCTAssertEqual(
            policy.disposition(
                nativeReattachOutcome: .failed,
                hasValidDescriptor: true
            ),
            .deferToRuntimeRehydrator
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
        XCTAssertEqual(descriptor.target?.socketEndpointKind, .name)
        XCTAssertNil(descriptor.target?.socketPath)
        XCTAssertEqual(descriptor.target?.socketName, "tidey")
        XCTAssertEqual(descriptor.target?.tmuxSession, "tidey-codex")
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
                .runtime,
                .directResume
            ].map(\.rawValue),
            [0, 1, 2, 3]
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
            descriptor.target?.socketEndpointKind,
            endpointKind,
            file: file,
            line: line
        )
        XCTAssertEqual(
            descriptor.target?.socketPath,
            socketPath,
            file: file,
            line: line
        )
        XCTAssertEqual(
            descriptor.target?.socketName,
            socketName,
            file: file,
            line: line
        )
        XCTAssertEqual(
            descriptor.target?.tmuxSession,
            session,
            file: file,
            line: line
        )
        XCTAssertNil(descriptor.topology, file: file, line: line)
        XCTAssertNil(descriptor.agent, file: file, line: line)
    }

    private func socketUpdatePayload(
        durableResumeID: String,
        workingDirectory: String
    ) -> [String: Any] {
        [
            "binding": [
                "workspace_id": "workspace-1",
                "panel_id": "panel-1",
                "tmux_pane_id": "%7"
            ],
            "descriptor": [
                "descriptor_version": 1,
                "kind": "agent",
                "restore_policy": "create",
                "target": [
                    "socket_endpoint_kind": "name",
                    "socket_name": "tidey",
                    "tmux_session": "tidey-codex"
                ],
                "topology": [
                    "windows": [
                        [
                            "index": 1,
                            "name": "Tidey",
                            "panes": [
                                [
                                    "index": 0,
                                    "cwd": workingDirectory,
                                    "launch": [
                                        "executable": "codex",
                                        "arguments": [
                                            "resume",
                                            durableResumeID
                                        ],
                                        "cwd": workingDirectory
                                    ]
                                ]
                            ]
                        ]
                    ],
                    "active_window_index": 1,
                    "active_pane_index": 0
                ],
                "agent": [
                    "vendor": "codex",
                    "durable_resume_id": durableResumeID,
                    "launch": [
                        "executable": "codex",
                        "arguments": ["resume", durableResumeID],
                        "cwd": workingDirectory
                    ]
                ]
            ]
        ]
    }

    private func directSocketUpdatePayload(
        durableResumeID: String,
        workingDirectory: String
    ) -> [String: Any] {
        [
            "binding": [
                "workspace_id": "workspace-direct",
                "panel_id": "panel-direct"
            ],
            "descriptor": [
                "descriptor_version": 1,
                "kind": "agent",
                "restore_policy": "direct_resume",
                "agent": [
                    "vendor": "codex",
                    "durable_resume_id": durableResumeID,
                    "launch": [
                        "executable": "codex",
                        "arguments": ["resume", durableResumeID],
                        "cwd": workingDirectory
                    ]
                ]
            ]
        ]
    }
}
