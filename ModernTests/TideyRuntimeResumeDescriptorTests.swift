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

        XCTAssertNotNil(environment)
    }

    func testRestoredSessionIdentityOptionsOverrideSavedEnvironment() {
        let environment = PTYSession.tideyEnvironment(
            byApplyingRestorationOptions: [
                PTYSessionArrangementOptionsTideyWorkspaceID:
                    "workspace-restored",
                PTYSessionArrangementOptionsTideyPanelID:
                    "panel-restored"
            ],
            toEnvironment: [
                "PATH": "/usr/bin",
                "TIDEY_WORKSPACE_ID": "workspace-stale",
                "TIDEY_PANEL_ID": "panel-stale"
            ]
        )

        XCTAssertEqual(environment?["PATH"], "/usr/bin")
        XCTAssertEqual(
            environment?["TIDEY_WORKSPACE_ID"],
            "workspace-restored"
        )
        XCTAssertEqual(
            environment?["TIDEY_PANEL_ID"],
            "panel-restored"
        )

        let ignored = PTYSession.tideyEnvironment(
            byApplyingRestorationOptions: [
                PTYSessionArrangementOptionsTideyWorkspaceID: "",
                PTYSessionArrangementOptionsTideyPanelID: 7
            ],
            toEnvironment: ["PATH": "/usr/bin"]
        )
        XCTAssertEqual(ignored, ["PATH": "/usr/bin"])
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

    func testMultiAgentCreateDescriptorSeamsCompile() {
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
                        index: 0,
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
                ],
                activeWindowIndex: 0,
                activePaneIndex: 0
            ),
            agent: nil
        )

        XCTAssertTrue(descriptor.topologyOwnsAgentLaunches)
        XCTAssertNil(descriptor.agent)
    }

    func testMultiAgentCreateDescriptorRoundTripsEveryPaneLaunch()
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
        func descriptor(
            launches: [TideyRuntimeLaunchSpecification?]
        ) -> TideyRuntimeResumeDescriptor {
            TideyRuntimeResumeDescriptor(
                descriptorVersion:
                    TideyRuntimeResumeDescriptor
                        .topologyOwnedAgentDescriptorVersion,
                revision: 4,
                kind: .agent,
                restorePolicy: .create,
                target: TideyRuntimeResumeTarget(
                    socketName: "tidey-agents",
                    tmuxSession: "genesis-extraction"
                ),
                topology: TideyRuntimeTmuxTopology(
                    windows: [
                        TideyRuntimeTmuxWindowTopology(
                            index: 1,
                            name: "agents",
                            panes: launches.enumerated().map {
                                index, launch in
                                TideyRuntimeTmuxPaneTopology(
                                    index: index,
                                    workingDirectory:
                                        launch?.workingDirectory ??
                                        "/tmp/monitor",
                                    launch: launch
                                )
                            }
                        ),
                    ],
                    activeWindowIndex: 1,
                    activePaneIndex: launches.count - 1
                ),
                agent: nil
            )
        }
        let codec = TideyRuntimeResumeDescriptorDictionaryCodec()

        let roundTripped = try codec.decode(
            codec.encode(
                descriptor(
                    launches: [
                        claudeLaunch,
                        codexLaunch,
                        nil,
                    ]
                )
            )
        )

        XCTAssertTrue(roundTripped.topologyOwnsAgentLaunches)
        XCTAssertNil(roundTripped.agent)
        XCTAssertEqual(
            roundTripped.topology?.windows
                .flatMap(\.panes)
                .compactMap(\.launch)
                .map(\.arguments),
            [
                ["--resume", "claude-session"],
                ["resume", "codex-thread"],
            ]
        )
        XCTAssertEqual(
            roundTripped.topology?.activePaneIndex,
            2
        )
        XCTAssertThrowsError(
            try codec.encode(
                descriptor(launches: [nil])
            )
        )
        XCTAssertThrowsError(
            try codec.encode(
                descriptor(
                    launches: [
                        claudeLaunch,
                        claudeLaunch,
                    ]
                )
            )
        )
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

    func testDescriptorRemovalSeamCompiles() throws {
        let gate = TideyRuntimeResumeDescriptorUpdateGate()
        let accepted = gate.acceptUpdatePayload(
            socketUpdatePayload(
                durableResumeID: "thread-inventory",
                workingDirectory: "/tmp/project"
            ),
            currentWorkspaceID: "workspace-1",
            currentPanelID: "panel-1"
        )
        XCTAssertTrue(accepted.accepted)

        let snapshots = gate.runtimeAgentDescriptorSnapshots(
            currentWorkspaceIDByPanelID: [
                "panel-1": "workspace-1"
            ]
        )

        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(snapshots[0]["revision"] as? Int64, 1)
        let binding = try XCTUnwrap(
            snapshots[0]["binding"] as? [String: Any]
        )
        XCTAssertEqual(
            binding["workspace_id"] as? String,
            "workspace-1"
        )
        XCTAssertEqual(binding["panel_id"] as? String, "panel-1")
        XCTAssertNotNil(
            snapshots[0]["descriptor"] as? [String: Any]
        )
        XCTAssertNotNil(gate.descriptor(forPanelID: "panel-1"))
    }

    func testRestoredDescriptorRemovalReadinessSeamCompiles() throws {
        let descriptor = try XCTUnwrap(
            TideyRuntimeResumeDescriptorUpdateGate()
                .acceptUpdatePayload(
                    socketUpdatePayload(
                        durableResumeID: "thread-restored",
                        workingDirectory: "/tmp/project"
                    ),
                    currentWorkspaceID: "workspace-1",
                    currentPanelID: "panel-1"
                ).descriptor
        )
        let gate = TideyRuntimeResumeDescriptorUpdateGate()

        gate.restoreDescriptorsByPanelIDAwaitingRuntimeEvidence([
            "panel-1": descriptor
        ])

        XCTAssertEqual(
            gate.descriptor(forPanelID: "panel-1")?.revision,
            descriptor.revision
        )
    }

    func testRestoredDescriptorRejectsRemovalUntilMatchingRuntimeEvidenceArrives()
        throws {
        let updatePayload = socketUpdatePayload(
            durableResumeID: "thread-restored",
            workingDirectory: "/tmp/project"
        )
        let descriptor = try XCTUnwrap(
            TideyRuntimeResumeDescriptorUpdateGate()
                .acceptUpdatePayload(
                    updatePayload,
                    currentWorkspaceID: "workspace-1",
                    currentPanelID: "panel-1"
                ).descriptor
        )
        let gate = TideyRuntimeResumeDescriptorUpdateGate()
        gate.restoreDescriptorsByPanelIDAwaitingRuntimeEvidence([
            "panel-1": descriptor
        ])
        let stored = try XCTUnwrap(
            gate.runtimeAgentDescriptorSnapshots(
                currentWorkspaceIDByPanelID: [
                    "panel-1": "workspace-1"
                ]
            ).first
        )
        let removal = try removalPayload(from: stored)

        let rejected = gate.removeRuntimeAgentDescriptorPayload(
            removal,
            currentWorkspaceID: "workspace-1",
            currentPanelID: "panel-1"
        )

        XCTAssertFalse(rejected.accepted)
        XCTAssertFalse(rejected.changed)
        XCTAssertEqual(
            rejected.errorCode,
            "runtime_rehydration_pending"
        )
        XCTAssertNotNil(gate.descriptor(forPanelID: "panel-1"))

        let evidence = gate.acceptUpdatePayload(
            updatePayload,
            currentWorkspaceID: "workspace-1",
            currentPanelID: "panel-1"
        )
        XCTAssertTrue(evidence.accepted)
        XCTAssertFalse(evidence.changed)
        XCTAssertEqual(evidence.descriptor?.revision, descriptor.revision)

        let removed = gate.removeRuntimeAgentDescriptorPayload(
            removal,
            currentWorkspaceID: "workspace-1",
            currentPanelID: "panel-1"
        )
        XCTAssertTrue(removed.accepted)
        XCTAssertTrue(removed.changed)
        XCTAssertNil(gate.descriptor(forPanelID: "panel-1"))
    }

    func testRemovalDropsRuntimeDescriptorAndRestoresOrdinaryTmuxFallback()
        throws {
        let gate = TideyRuntimeResumeDescriptorUpdateGate()
        let first = gate.acceptUpdatePayload(
            socketUpdatePayload(
                durableResumeID: "thread-old",
                workingDirectory: "/tmp/project"
            ),
            currentWorkspaceID: "workspace-1",
            currentPanelID: "panel-1"
        )
        XCTAssertTrue(first.accepted)
        let oldRemovalPayload = try removalPayload(
            from: XCTUnwrap(
                gate.runtimeAgentDescriptorSnapshots(
                    currentWorkspaceIDByPanelID: [
                        "panel-1": "workspace-1"
                    ]
                ).first
            )
        )

        let second = gate.acceptUpdatePayload(
            socketUpdatePayload(
                durableResumeID: "thread-new",
                workingDirectory: "/tmp/project"
            ),
            currentWorkspaceID: "workspace-1",
            currentPanelID: "panel-1"
        )
        XCTAssertEqual(second.descriptor?.revision, 2)

        let staleRevision = gate.removeRuntimeAgentDescriptorPayload(
            oldRemovalPayload,
            currentWorkspaceID: "workspace-1",
            currentPanelID: "panel-1"
        )
        XCTAssertFalse(staleRevision.accepted)
        XCTAssertFalse(staleRevision.changed)
        XCTAssertEqual(
            staleRevision.errorCode,
            "descriptor_changed"
        )
        XCTAssertEqual(
            gate.descriptor(forPanelID: "panel-1")?
                .agent?.durableResumeID,
            "thread-new"
        )

        let currentRemovalPayload = try removalPayload(
            from: XCTUnwrap(
                gate.runtimeAgentDescriptorSnapshots(
                    currentWorkspaceIDByPanelID: [
                        "panel-1": "workspace-1"
                    ]
                ).first
            )
        )
        let staleBinding = gate.removeRuntimeAgentDescriptorPayload(
            currentRemovalPayload,
            currentWorkspaceID: "workspace-other",
            currentPanelID: "panel-1"
        )
        XCTAssertEqual(staleBinding.errorCode, "stale_binding")
        XCTAssertNotNil(gate.descriptor(forPanelID: "panel-1"))

        let removed = gate.removeRuntimeAgentDescriptorPayload(
            currentRemovalPayload,
            currentWorkspaceID: "workspace-1",
            currentPanelID: "panel-1"
        )
        XCTAssertTrue(removed.accepted)
        XCTAssertTrue(removed.changed)
        XCTAssertNil(gate.descriptor(forPanelID: "panel-1"))

        let repeated = gate.removeRuntimeAgentDescriptorPayload(
            currentRemovalPayload,
            currentWorkspaceID: "workspace-1",
            currentPanelID: "panel-1"
        )
        XCTAssertTrue(repeated.accepted)
        XCTAssertFalse(repeated.changed)

        let fallback = try XCTUnwrap(
            TideyRuntimeResumeDescriptorFactory().descriptor(
                fromOrdinaryTmuxMetadata: [
                    "socket_name": "tidey",
                    "target_session": "work",
                ]
            )
        )
        XCTAssertEqual(fallback.kind, .ordinaryTmux)
        XCTAssertEqual(fallback.restorePolicy, .attachOnly)

        let ordinaryGate = TideyRuntimeResumeDescriptorUpdateGate(
            initialDescriptorsByPanelID: [
                "panel-1": fallback
            ]
        )
        let ordinaryRemoval =
            ordinaryGate.removeRuntimeAgentDescriptorPayload(
                currentRemovalPayload,
                currentWorkspaceID: "workspace-1",
                currentPanelID: "panel-1"
            )
        XCTAssertEqual(
            ordinaryRemoval.errorCode,
            "not_agent_descriptor"
        )
        XCTAssertEqual(
            ordinaryGate.descriptor(forPanelID: "panel-1")?.kind,
            .ordinaryTmux
        )
    }

    func testRemovalRevisionDoesNotRepeatAfterDeleteAndReinsert()
        throws {
        let gate = TideyRuntimeResumeDescriptorUpdateGate()
        let payload = socketUpdatePayload(
            durableResumeID: "thread-same",
            workingDirectory: "/tmp/project"
        )
        let first = gate.acceptUpdatePayload(
            payload,
            currentWorkspaceID: "workspace-1",
            currentPanelID: "panel-1"
        )
        XCTAssertEqual(first.descriptor?.revision, 1)
        let oldRemovalPayload = try removalPayload(
            from: XCTUnwrap(
                gate.runtimeAgentDescriptorSnapshots(
                    currentWorkspaceIDByPanelID: [
                        "panel-1": "workspace-1"
                    ]
                ).first
            )
        )
        let removed = gate.removeRuntimeAgentDescriptorPayload(
            oldRemovalPayload,
            currentWorkspaceID: "workspace-1",
            currentPanelID: "panel-1"
        )
        XCTAssertTrue(removed.accepted)
        XCTAssertTrue(removed.changed)

        let reinserted = gate.acceptUpdatePayload(
            payload,
            currentWorkspaceID: "workspace-1",
            currentPanelID: "panel-1"
        )
        XCTAssertEqual(reinserted.descriptor?.revision, 2)

        let replayedRemoval =
            gate.removeRuntimeAgentDescriptorPayload(
                oldRemovalPayload,
                currentWorkspaceID: "workspace-1",
                currentPanelID: "panel-1"
            )
        XCTAssertFalse(replayedRemoval.accepted)
        XCTAssertFalse(replayedRemoval.changed)
        XCTAssertEqual(
            replayedRemoval.errorCode,
            "descriptor_changed"
        )
        XCTAssertEqual(
            gate.descriptor(forPanelID: "panel-1")?.revision,
            2
        )
        XCTAssertEqual(
            gate.descriptor(forPanelID: "panel-1")?
                .agent?.durableResumeID,
            "thread-same"
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

    func testManagedRestoreDefersSavedProgramWheneverValidDescriptorOwnsColdBootRelaunch() {
        let policy = TideyManagedRestoreLaunchPolicy()

        XCTAssertEqual(
            policy.disposition(
                nativeReattachOutcome: .notAttempted,
                hasValidDescriptor: true
            ),
            .deferToRuntimeRehydrator
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
                nativeReattachOutcome: .notAttempted,
                hasValidDescriptor: false
            ),
            .launchSavedProgram
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

    func testManagedNativeReattachOutcomeSeamCompiles() {
        _ = PTYSession.tideyNativeServerReattachOutcome(
            forAttached: true,
            registered: false,
            hasManagedRuntimeDescriptor: true
        )
    }

    func testManagedNativeReattachRequiresRegisteredLiveChild() {
        XCTAssertEqual(
            PTYSession.tideyNativeServerReattachOutcome(
                forAttached: true,
                registered: false,
                hasManagedRuntimeDescriptor: true
            ),
            .failed
        )
        XCTAssertEqual(
            PTYSession.tideyNativeServerReattachOutcome(
                forAttached: true,
                registered: true,
                hasManagedRuntimeDescriptor: true
            ),
            .succeeded
        )
        XCTAssertEqual(
            PTYSession.tideyNativeServerReattachOutcome(
                forAttached: true,
                registered: false,
                hasManagedRuntimeDescriptor: false
            ),
            .succeeded
        )
        XCTAssertEqual(
            PTYSession.tideyNativeServerReattachOutcome(
                forAttached: false,
                registered: false,
                hasManagedRuntimeDescriptor: true
            ),
            .failed
        )
    }

    func testManagedRestoreRelaunchPreparationSeamsCompile() {
        XCTAssertTrue(
            PTYSession.instancesRespond(
                to: #selector(
                    PTYSession.tideyPrepareForManagedRestoreRelaunch
                )
            )
        )
    }

    func testManagedRestoreAutoCloseSuppressionSeamCompiles() {
        XCTAssertTrue(
            PTYSession.instancesRespond(
                to: NSSelectorFromString(
                    "tideyAwaitingFirstManagedRelaunchOutcome"
                )
            )
        )
        XCTAssertTrue(
            PTYSession.instancesRespond(
                to: NSSelectorFromString(
                    "tideyConsumeManagedRestoreAutoCloseSuppression"
                )
            )
        )
    }

    func testManagedRestoreAutoCloseSuppressionIsOneShot() throws {
        let session = try XCTUnwrap(PTYSession(synthetic: true))

        XCTAssertFalse(session.tideyAwaitingFirstManagedRelaunchOutcome)
        session.tideyPrepareForManagedRestoreRelaunch()
        XCTAssertTrue(session.tideyAwaitingFirstManagedRelaunchOutcome)
        XCTAssertTrue(
            session.tideyConsumeManagedRestoreAutoCloseSuppression()
        )
        XCTAssertFalse(session.tideyAwaitingFirstManagedRelaunchOutcome)
        XCTAssertFalse(
            session.tideyConsumeManagedRestoreAutoCloseSuppression()
        )
    }

    func testBrokenPipeCallbackCarriesOriginatingTaskSeam() throws {
        let session = try XCTUnwrap(PTYSession(synthetic: true))

        XCTAssertTrue(
            session.responds(
                to: NSSelectorFromString("threadedTaskBrokenPipe:")
            )
        )
    }

    func testManagedRestoreBrokenPipeOwnershipSeamCompiles() {
        XCTAssertTrue(
            PTYSession.responds(
                to: NSSelectorFromString(
                    "tideyShouldHandleBrokenPipeFromTask:currentTask:"
                )
            )
        )
    }

    func testManagedRestoreHandlesBrokenPipeOnlyFromCurrentTask() throws {
        let currentTask = try XCTUnwrap(PTYSession(synthetic: true)?.shell)
        let abandonedTask = try XCTUnwrap(PTYSession(synthetic: true)?.shell)

        XCTAssertTrue(
            PTYSession.tideyShouldHandleBrokenPipe(
                from: currentTask,
                currentTask: currentTask
            )
        )
        XCTAssertFalse(
            PTYSession.tideyShouldHandleBrokenPipe(
                from: abandonedTask,
                currentTask: currentTask
            )
        )
    }

    func testManagedRestoreIgnoresQueuedBrokenPipeAfterReplacingTask() throws {
        let session = try XCTUnwrap(PTYSession(synthetic: true))
        let abandonedTask = try XCTUnwrap(session.shell)

        session.tideyNativeServerReattachOutcome = .failed
        session.tideyPrepareForManagedRestoreRelaunch()
        let replacementTask = try XCTUnwrap(session.shell)
        session.threadedTaskBrokenPipe(abandonedTask)

        let mainQueueDrained = expectation(
            description: "queued broken-pipe callback drained"
        )
        DispatchQueue.main.async {
            mainQueueDrained.fulfill()
        }
        wait(for: [mainQueueDrained], timeout: 1)

        XCTAssertFalse(session.exited)
        XCTAssertTrue(session.shell === replacementTask)
    }

    func testManagedRestoreRelaunchReplacesEveryNativeOutcomeWithoutChangingIdentity() throws {
        for outcome in [
            TideyNativeServerReattachOutcome.notAttempted,
            .succeeded,
            .failed
        ] {
            let session = try XCTUnwrap(PTYSession(synthetic: true))
            let originalShell = session.shell
            let originalGUID = session.guid

            session.tideyNativeServerReattachOutcome = outcome
            session.tideyPrepareForManagedRestoreRelaunch()

            XCTAssertTrue(session.shell !== originalShell)
            XCTAssertEqual(session.guid, originalGUID)
            XCTAssertTrue(session.shell.delegate === session)
        }
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

    private func removalPayload(
        from snapshot: [String: Any]
    ) throws -> [String: Any] {
        [
            "binding": try XCTUnwrap(
                snapshot["binding"] as? [String: Any]
            ),
            "expected_revision": try XCTUnwrap(
                snapshot["revision"]
            ),
            "expected_descriptor": try XCTUnwrap(
                snapshot["descriptor"] as? [String: Any]
            ),
        ]
    }
}
