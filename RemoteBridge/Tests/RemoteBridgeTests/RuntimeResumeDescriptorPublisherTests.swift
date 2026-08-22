import Darwin
import Foundation
import XCTest
@testable import RemoteBridge

final class RuntimeResumeDescriptorPublisherTests: XCTestCase {
    func testRevocationRequiresTwoConsecutiveCompleteAbsenceObservations()
        throws {
        let staleSlot = RuntimeResumeDescriptorSlot(
            workspaceID: "workspace-stale",
            panelID: "panel-stale"
        )
        let socket = ReconcilingRuntimeResumeSocket(
            descriptors: [
                RuntimeResumeStoredDescriptor(
                    slot: staleSlot,
                    revision: 8,
                    content: Self.directContent(
                        durableResumeID: "thread-stale"
                    )
                ),
            ]
        )
        let publisher = RuntimeResumeDescriptorPublisher(
            registryReader: StubRuntimeResumeRegistryReader(
                records: []
            ),
            topologyReader: StubRuntimeResumeTopologyReader(
                snapshotsByBinding: [:]
            ),
            inventoryReconciler: socket,
            socketSender: socket
        )

        try publisher.publishCurrentDescriptors()
        XCTAssertEqual(socket.events, ["list"])
        XCTAssertEqual(socket.descriptors.map(\.slot), [staleSlot])

        try publisher.publishCurrentDescriptors()
        XCTAssertEqual(
            socket.events,
            ["list", "list", "remove:panel-stale"]
        )
        XCTAssertTrue(socket.descriptors.isEmpty)
    }

    func testMalformedRegistryFileMakesSnapshotIncomplete()
        throws {
        let supportDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "RuntimeResumeDescriptorPublisherTests-\(UUID().uuidString)",
                isDirectory: true
            )
        defer {
            try? FileManager.default.removeItem(
                at: supportDirectory
            )
        }
        let paths = BridgePaths(
            supportDirectory: supportDirectory
        )
        try paths.ensureSupportDirectoriesExist()
        let malformedURL = paths
            .agentSessionsDirectory(for: "codex")
            .appendingPathComponent("malformed.json")
        try Data("not-json".utf8).write(to: malformedURL)
        let monitor = AgentSessionRegistryMonitor(
            paths: paths,
            hub: AgentEventHub()
        )

        monitor.scanRegistryForTesting()

        let snapshot = monitor.currentRuntimeResumeAgentSnapshot()
        XCTAssertFalse(snapshot.sourceScanIsComplete)
        XCTAssertFalse(snapshot.isComplete)
        XCTAssertTrue(snapshot.records.isEmpty)
    }

    func testCompleteSnapshotRevokesExitedAndMovedBindings()
        throws {
        let oldContent = Self.directContent(
            durableResumeID: "thread-old"
        )
        let oldSlot = RuntimeResumeDescriptorSlot(
            workspaceID: "workspace-old",
            panelID: "panel-old"
        )
        let socket = ReconcilingRuntimeResumeSocket(
            descriptors: [
                RuntimeResumeStoredDescriptor(
                    slot: oldSlot,
                    revision: 3,
                    content: oldContent
                ),
            ]
        )
        let newBinding = RuntimeResumeDescriptorBinding(
            workspaceID: "workspace-new",
            panelID: "panel-new",
            tmuxPaneID: nil
        )
        let newRecord = RuntimeResumeAgentRegistryRecord(
            binding: newBinding,
            vendor: .codex,
            durableResumeID: "thread-new",
            launch: RuntimeResumeLaunchSpecification(
                executable: "codex",
                arguments: ["resume", "thread-new"],
                workingDirectory: "/tmp/project"
            )
        )
        let publisher = RuntimeResumeDescriptorPublisher(
            registryReader: StubRuntimeResumeRegistryReader(
                records: [newRecord]
            ),
            topologyReader: StubRuntimeResumeTopologyReader(
                snapshotsByBinding: [:]
            ),
            inventoryReconciler: socket,
            socketSender: socket
        )

        try publisher.publishCurrentDescriptors()
        XCTAssertEqual(
            socket.events,
            [
                "update:panel-new",
                "list",
            ]
        )
        XCTAssertEqual(
            Set(socket.descriptors.map(\.slot)),
            Set([
                oldSlot,
                RuntimeResumeDescriptorSlot(
                    workspaceID: "workspace-new",
                    panelID: "panel-new"
                ),
            ])
        )

        try publisher.publishCurrentDescriptors()

        XCTAssertEqual(
            socket.events,
            [
                "update:panel-new",
                "list",
                "update:panel-new",
                "list",
                "remove:panel-old",
            ]
        )
        XCTAssertEqual(
            socket.descriptors.map(\.slot),
            [
                RuntimeResumeDescriptorSlot(
                    workspaceID: "workspace-new",
                    panelID: "panel-new"
                ),
            ]
        )

        let restartedPublisher = RuntimeResumeDescriptorPublisher(
            registryReader: StubRuntimeResumeRegistryReader(
                records: []
            ),
            topologyReader: StubRuntimeResumeTopologyReader(
                snapshotsByBinding: [:]
            ),
            inventoryReconciler: socket,
            socketSender: socket
        )
        try restartedPublisher.publishCurrentDescriptors()
        XCTAssertEqual(
            Array(socket.events.suffix(1)),
            ["list"]
        )
        XCTAssertFalse(socket.descriptors.isEmpty)
        try restartedPublisher.publishCurrentDescriptors()
        XCTAssertEqual(
            Array(socket.events.suffix(3)),
            ["list", "list", "remove:panel-new"]
        )
        XCTAssertTrue(socket.descriptors.isEmpty)

        let incompletePublisher = RuntimeResumeDescriptorPublisher(
            registryReader: StubRuntimeResumeRegistryReader(
                snapshot: RuntimeResumeAgentRegistrySnapshot(
                    sourceRecordCount: 1,
                    resolvedCandidateCount: 0,
                    records: []
                )
            ),
            topologyReader: StubRuntimeResumeTopologyReader(
                snapshotsByBinding: [:]
            ),
            inventoryReconciler: socket,
            socketSender: socket
        )
        let eventCountBeforeIncomplete = socket.events.count
        XCTAssertThrowsError(
            try incompletePublisher.publishCurrentDescriptors()
        )
        XCTAssertEqual(
            socket.events.count,
            eventCountBeforeIncomplete
        )

        let tmuxRecord = RuntimeResumeAgentRegistryRecord(
            binding: RuntimeResumeDescriptorBinding(
                workspaceID: "workspace-tmux",
                panelID: "panel-tmux",
                tmuxPaneID: "%9"
            ),
            vendor: .claude,
            durableResumeID: "claude-session",
            launch: RuntimeResumeLaunchSpecification(
                executable: "claude",
                arguments: ["--resume", "claude-session"],
                workingDirectory: "/tmp/project"
            )
        )
        let planningGapPublisher = RuntimeResumeDescriptorPublisher(
            registryReader: StubRuntimeResumeRegistryReader(
                records: [tmuxRecord]
            ),
            topologyReader: StubRuntimeResumeTopologyReader(
                snapshotsByBinding: [:]
            ),
            carrierPlanner: StubRuntimeResumeCarrierPlanner(
                plans: []
            ),
            inventoryReconciler: socket,
            socketSender: socket
        )
        XCTAssertThrowsError(
            try planningGapPublisher.publishCurrentDescriptors()
        )
        XCTAssertEqual(
            socket.events.count,
            eventCountBeforeIncomplete
        )

        let failingSocket = ReconcilingRuntimeResumeSocket(
            descriptors: [
                RuntimeResumeStoredDescriptor(
                    slot: oldSlot,
                    revision: 3,
                    content: oldContent
                ),
            ],
            failNextUpdate: true
        )
        let failingPublisher = RuntimeResumeDescriptorPublisher(
            registryReader: StubRuntimeResumeRegistryReader(
                records: [newRecord]
            ),
            topologyReader: StubRuntimeResumeTopologyReader(
                snapshotsByBinding: [:]
            ),
            inventoryReconciler: failingSocket,
            socketSender: failingSocket
        )
        XCTAssertThrowsError(
            try failingPublisher.publishCurrentDescriptors()
        )
        XCTAssertEqual(failingSocket.events, ["update:panel-new"])
        XCTAssertEqual(failingSocket.descriptors.map(\.slot), [oldSlot])
    }

    func testDescriptorRemovalSocketSeamCompiles() {
        let slot = RuntimeResumeDescriptorSlot(
            workspaceID: "workspace-1",
            panelID: "panel-1"
        )
        let content = RuntimeResumeDescriptorContent(
            descriptorVersion: 1,
            kind: .agent,
            restorePolicy: .directResume,
            target: nil,
            topology: nil,
            agent: RuntimeResumeAgentSpecification(
                vendor: .codex,
                durableResumeID: "thread-1",
                launch: RuntimeResumeLaunchSpecification(
                    executable: "codex",
                    arguments: ["resume", "thread-1"],
                    workingDirectory: "/tmp/project"
                )
            )
        )
        let stored = RuntimeResumeStoredDescriptor(
            slot: slot,
            revision: 4,
            content: content
        )
        let removal = RuntimeResumeDescriptorSocketRemoval(
            slot: slot,
            expectedRevision: stored.revision,
            expectedContent: stored.content
        )
        let reconciler = StubRuntimeResumeInventoryReconciler(
            descriptors: [stored]
        )
        let publisher = RuntimeResumeDescriptorPublisher(
            registryReader: StubRuntimeResumeRegistryReader(
                records: []
            ),
            topologyReader: StubRuntimeResumeTopologyReader(
                snapshotsByBinding: [:]
            ),
            inventoryReconciler: reconciler,
            socketSender: RecordingRuntimeResumeSocketSender()
        )

        XCTAssertEqual(stored.slot, slot)
        XCTAssertEqual(removal.expectedRevision, 4)
        XCTAssertEqual(
            try! reconciler.currentAgentDescriptors(),
            [stored]
        )
        XCTAssertNotNil(publisher as Any)
    }

    func testRegistrySnapshotCompletenessSeamCompiles() {
        let snapshot = RuntimeResumeAgentRegistrySnapshot(
            sourceRecordCount: 1,
            resolvedCandidateCount: 0,
            records: []
        )

        XCTAssertTrue(snapshot.records.isEmpty)
        XCTAssertEqual(snapshot.sourceRecordCount, 1)
        XCTAssertEqual(snapshot.resolvedCandidateCount, 0)
        XCTAssertFalse(snapshot.isComplete)
    }

    func testIncompleteRegistrySnapshotPublishesNothing()
        throws {
        let binding = RuntimeResumeDescriptorBinding(
            workspaceID: "workspace-direct",
            panelID: "panel-direct",
            tmuxPaneID: nil
        )
        let record = RuntimeResumeAgentRegistryRecord(
            binding: binding,
            vendor: .codex,
            durableResumeID: "thread-direct",
            launch: RuntimeResumeLaunchSpecification(
                executable: "codex",
                arguments: ["resume", "thread-direct"],
                workingDirectory: "/tmp/project"
            )
        )
        let socketSender = RecordingRuntimeResumeSocketSender()
        let publisher = RuntimeResumeDescriptorPublisher(
            registryReader: StubRuntimeResumeRegistryReader(
                snapshot: RuntimeResumeAgentRegistrySnapshot(
                    sourceRecordCount: 2,
                    resolvedCandidateCount: 1,
                    records: [record]
                )
            ),
            topologyReader: StubRuntimeResumeTopologyReader(
                snapshotsByBinding: [:]
            ),
            socketSender: socketSender
        )

        XCTAssertThrowsError(
            try publisher.publishCurrentDescriptors()
        ) { error in
            XCTAssertEqual(
                error as? RuntimeResumeDescriptorPublisherError,
                .incompleteRegistrySnapshot(
                    sourceRecordCount: 2,
                    resolvedCandidateCount: 1,
                    publishedRecordCount: 1
                )
            )
        }
        XCTAssertTrue(socketSender.updates.isEmpty)
    }

    func testDirectAgentDescriptorSeamsCompile() {
        let binding = RuntimeResumeDescriptorBinding(
            workspaceID: "workspace-direct",
            panelID: "panel-direct",
            tmuxPaneID: nil
        )
        let content = RuntimeResumeDescriptorContent(
            descriptorVersion: 1,
            kind: .agent,
            restorePolicy: .directResume,
            target: nil,
            topology: nil,
            agent: RuntimeResumeAgentSpecification(
                vendor: .codex,
                durableResumeID: "thread-direct",
                launch: RuntimeResumeLaunchSpecification(
                    executable: "codex",
                    arguments: ["resume", "thread-direct"],
                    workingDirectory: "/tmp/project"
                )
            )
        )

        XCTAssertNil(binding.tmuxPaneID)
        XCTAssertEqual(content.restorePolicy, .directResume)
        XCTAssertNil(content.target)
    }

    func testCarrierPublicationPlannerSeamsCompile() {
        let registry = OrdinaryTmuxPanelRegistry()
        let sessionReader = StubRuntimeResumeTmuxSessionReader(
            statesBySessionID: [:]
        )
        let planner = OrdinaryTmuxRuntimeResumeCarrierPlanner(
            registry: registry,
            sessionReader: sessionReader
        )
        let publisher = RuntimeResumeDescriptorPublisher(
            registryReader: StubRuntimeResumeRegistryReader(
                records: []
            ),
            topologyReader: StubRuntimeResumeTopologyReader(
                snapshotsByBinding: [:]
            ),
            carrierPlanner: planner,
            socketSender: RecordingRuntimeResumeSocketSender()
        )

        XCTAssertNotNil(planner as Any)
        XCTAssertNotNil(publisher as Any)
        XCTAssertTrue(
            try! planner.publicationPlans(for: []).isEmpty
        )
    }

    func testCarrierDescriptorUsesCanonicalTmuxSessionName()
        throws {
        let registry = OrdinaryTmuxPanelRegistry()
        registry.replaceRoutes(
            workspaceID: "workspace-1",
            routes: [
                Self.route(
                    panelID: "panel-storage",
                    windowID: "@1",
                    windowIndex: 0,
                    paneID: "%7",
                    cwd: "/tmp/storage",
                    carrierPanelID: "carrier-storage",
                    sessionID: "$1",
                    sessionName: "s"
                ),
            ]
        )
        let planner = OrdinaryTmuxRuntimeResumeCarrierPlanner(
            registry: registry,
            sessionReader: StubRuntimeResumeTmuxSessionReader(
                statesBySessionID: [
                    "$1": RuntimeResumeTmuxSessionState(
                        sessionID: "$1",
                        sessionName: "storage",
                        windows: [
                            RuntimeResumeTmuxWindowState(
                                windowID: "@1",
                                index: 0,
                                name: "storage",
                                isActive: true,
                                panes: [
                                    RuntimeResumeTmuxPaneState(
                                        paneID: "%7",
                                        index: 0,
                                        workingDirectory:
                                            "/tmp/storage",
                                        isActive: true
                                    ),
                                ]
                            ),
                        ]
                    ),
                ]
            )
        )
        let record = RuntimeResumeAgentRegistryRecord(
            binding: RuntimeResumeDescriptorBinding(
                workspaceID: "workspace-1",
                panelID: "panel-storage",
                tmuxPaneID: "%7"
            ),
            vendor: .codex,
            durableResumeID: "storage-thread",
            launch: RuntimeResumeLaunchSpecification(
                executable: "codex",
                arguments: ["resume", "storage-thread"],
                workingDirectory: "/tmp/storage"
            )
        )

        let plan = try XCTUnwrap(
            planner.publicationPlans(for: [record]).first
        )

        XCTAssertEqual(
            plan.target,
            RuntimeResumeTmuxTarget(
                socketName: "tidey-agents",
                tmuxSession: "storage"
            )
        )
    }

    func testCarrierDescriptorBindsTheNativeCarrierPanel()
        throws {
        let registry = OrdinaryTmuxPanelRegistry()
        registry.replaceRoutes(
            workspaceID: "workspace-1",
            routes: [
                Self.route(
                    panelID: "ordinary-panel",
                    windowID: "@1",
                    windowIndex: 0,
                    paneID: "%7",
                    cwd: "/tmp/storage",
                    carrierPanelID:
                        "native-session:carrier-storage:leaf-1",
                    nativeCarrierPanelID: "carrier-storage",
                    sessionID: "$1",
                    sessionName: "storage"
                ),
            ]
        )
        let planner = OrdinaryTmuxRuntimeResumeCarrierPlanner(
            registry: registry,
            sessionReader: StubRuntimeResumeTmuxSessionReader(
                statesBySessionID: [
                    "$1": RuntimeResumeTmuxSessionState(
                        sessionID: "$1",
                        sessionName: "storage",
                        windows: [
                            RuntimeResumeTmuxWindowState(
                                windowID: "@1",
                                index: 0,
                                name: "storage",
                                isActive: true,
                                panes: [
                                    RuntimeResumeTmuxPaneState(
                                        paneID: "%7",
                                        index: 0,
                                        workingDirectory:
                                            "/tmp/storage",
                                        isActive: true
                                    ),
                                ]
                            ),
                        ]
                    ),
                ]
            )
        )
        let record = RuntimeResumeAgentRegistryRecord(
            binding: RuntimeResumeDescriptorBinding(
                workspaceID: "workspace-1",
                panelID: "ordinary-panel",
                tmuxPaneID: "%7"
            ),
            vendor: .codex,
            durableResumeID: "storage-thread",
            launch: RuntimeResumeLaunchSpecification(
                executable: "codex",
                arguments: ["resume", "storage-thread"],
                workingDirectory: "/tmp/storage"
            )
        )

        let plan = try XCTUnwrap(
            planner.publicationPlans(for: [record]).first
        )

        XCTAssertEqual(plan.binding.workspaceID, "workspace-1")
        XCTAssertEqual(plan.binding.panelID, "carrier-storage")
        XCTAssertEqual(plan.binding.tmuxPaneID, "%7")
    }

    func testCarrierDescriptorPreservesCanonicalTmuxSessionNameVerbatim()
        throws {
        let registry = OrdinaryTmuxPanelRegistry()
        registry.replaceRoutes(
            workspaceID: "workspace-1",
            routes: [
                Self.route(
                    panelID: "panel-storage",
                    windowID: "@1",
                    windowIndex: 0,
                    paneID: "%7",
                    cwd: "/tmp/storage",
                    carrierPanelID: "carrier-storage",
                    sessionID: "$1",
                    sessionName: "s"
                ),
            ]
        )
        let planner = OrdinaryTmuxRuntimeResumeCarrierPlanner(
            registry: registry,
            sessionReader: StubRuntimeResumeTmuxSessionReader(
                statesBySessionID: [
                    "$1": RuntimeResumeTmuxSessionState(
                        sessionID: "$1",
                        sessionName: " storage ",
                        windows: [
                            RuntimeResumeTmuxWindowState(
                                windowID: "@1",
                                index: 0,
                                name: "storage",
                                isActive: true,
                                panes: [
                                    RuntimeResumeTmuxPaneState(
                                        paneID: "%7",
                                        index: 0,
                                        workingDirectory:
                                            "/tmp/storage",
                                        isActive: true
                                    ),
                                ]
                            ),
                        ]
                    ),
                ]
            )
        )
        let record = RuntimeResumeAgentRegistryRecord(
            binding: RuntimeResumeDescriptorBinding(
                workspaceID: "workspace-1",
                panelID: "panel-storage",
                tmuxPaneID: "%7"
            ),
            vendor: .codex,
            durableResumeID: "storage-thread",
            launch: RuntimeResumeLaunchSpecification(
                executable: "codex",
                arguments: ["resume", "storage-thread"],
                workingDirectory: "/tmp/storage"
            )
        )

        let plan = try XCTUnwrap(
            planner.publicationPlans(for: [record]).first
        )

        XCTAssertEqual(
            plan.target,
            RuntimeResumeTmuxTarget(
                socketName: "tidey-agents",
                tmuxSession: " storage "
            )
        )
    }

    func testCarrierDescriptorUsesRestorationSocketWithoutChangingLiveSocket()
        throws {
        let registry = OrdinaryTmuxPanelRegistry()
        let liveSocket = OrdinaryTmuxSocketSelector.path(
            "/private/tmp/tmux-501/default"
        )
        registry.replaceRoutes(
            workspaceID: "workspace-1",
            routes: [
                OrdinaryTmuxPanelRoute(
                    workspaceID: "workspace-1",
                    panelID: "panel-1",
                    carrierPanelID: "carrier-1",
                    socket: liveSocket,
                    restorationSocket: .defaultSocket,
                    sessionID: "$1",
                    sessionName: "work",
                    windowID: "@1",
                    windowIndex: 0,
                    activePaneID: "%7",
                    cwd: "/tmp/project",
                    currentCommand: "codex"
                ),
            ]
        )
        let planner = OrdinaryTmuxRuntimeResumeCarrierPlanner(
            registry: registry,
            sessionReader: StubRuntimeResumeTmuxSessionReader(
                statesBySessionID: [
                    "$1": RuntimeResumeTmuxSessionState(
                        sessionID: "$1",
                        sessionName: "work",
                        windows: [
                            RuntimeResumeTmuxWindowState(
                                windowID: "@1",
                                index: 0,
                                name: "codex",
                                isActive: true,
                                panes: [
                                    RuntimeResumeTmuxPaneState(
                                        paneID: "%7",
                                        index: 0,
                                        workingDirectory:
                                            "/tmp/project",
                                        isActive: true
                                    ),
                                ]
                            ),
                        ]
                    ),
                ]
            )
        )
        let record = RuntimeResumeAgentRegistryRecord(
            binding: RuntimeResumeDescriptorBinding(
                workspaceID: "workspace-1",
                panelID: "panel-1",
                tmuxPaneID: "%7"
            ),
            vendor: .codex,
            durableResumeID: "thread-1",
            launch: RuntimeResumeLaunchSpecification(
                executable: "codex",
                arguments: ["resume", "thread-1"],
                workingDirectory: "/tmp/project"
            )
        )

        let plan = try XCTUnwrap(
            planner.publicationPlans(for: [record]).first
        )

        XCTAssertEqual(
            registry.route(forPanelID: "panel-1")?.socket,
            liveSocket
        )
        XCTAssertEqual(
            plan.target,
            RuntimeResumeTmuxTarget(
                defaultSocketAndTmuxSession: "work"
            )
        )
    }

    func testCarrierPlannerRejectsMixedRestorationSocketSemantics()
        throws {
        let registry = OrdinaryTmuxPanelRegistry()
        let liveSocket = OrdinaryTmuxSocketSelector.path(
            "/private/tmp/tmux-501/default"
        )
        registry.replaceRoutes(
            workspaceID: "workspace-1",
            routes: [
                Self.route(
                    panelID: "panel-1",
                    windowID: "@1",
                    windowIndex: 0,
                    paneID: "%7",
                    cwd: "/tmp/one",
                    socket: liveSocket,
                    restorationSocket: .defaultSocket
                ),
                Self.route(
                    panelID: "panel-2",
                    windowID: "@2",
                    windowIndex: 1,
                    paneID: "%8",
                    cwd: "/tmp/two",
                    socket: liveSocket,
                    restorationSocket: liveSocket
                ),
            ]
        )
        let planner = OrdinaryTmuxRuntimeResumeCarrierPlanner(
            registry: registry,
            sessionReader: StubRuntimeResumeTmuxSessionReader(
                statesBySessionID: [
                    "$1": RuntimeResumeTmuxSessionState(
                        sessionID: "$1",
                        sessionName: "work",
                        windows: [
                            RuntimeResumeTmuxWindowState(
                                windowID: "@1",
                                index: 0,
                                name: "one",
                                isActive: true,
                                panes: [
                                    RuntimeResumeTmuxPaneState(
                                        paneID: "%7",
                                        index: 0,
                                        workingDirectory: "/tmp/one",
                                        isActive: true
                                    ),
                                ]
                            ),
                            RuntimeResumeTmuxWindowState(
                                windowID: "@2",
                                index: 1,
                                name: "two",
                                isActive: false,
                                panes: [
                                    RuntimeResumeTmuxPaneState(
                                        paneID: "%8",
                                        index: 0,
                                        workingDirectory: "/tmp/two",
                                        isActive: true
                                    ),
                                ]
                            ),
                        ]
                    ),
                ]
            )
        )
        let records = [
            RuntimeResumeAgentRegistryRecord(
                binding: RuntimeResumeDescriptorBinding(
                    workspaceID: "workspace-1",
                    panelID: "panel-1",
                    tmuxPaneID: "%7"
                ),
                vendor: .claude,
                durableResumeID: "claude-1",
                launch: RuntimeResumeLaunchSpecification(
                    executable: "claude",
                    arguments: ["--resume", "claude-1"],
                    workingDirectory: "/tmp/one"
                )
            ),
            RuntimeResumeAgentRegistryRecord(
                binding: RuntimeResumeDescriptorBinding(
                    workspaceID: "workspace-1",
                    panelID: "panel-2",
                    tmuxPaneID: "%8"
                ),
                vendor: .codex,
                durableResumeID: "codex-1",
                launch: RuntimeResumeLaunchSpecification(
                    executable: "codex",
                    arguments: ["resume", "codex-1"],
                    workingDirectory: "/tmp/two"
                )
            ),
        ]

        XCTAssertTrue(
            try planner.publicationPlans(for: records).isEmpty
        )
    }

    func testColdRebootInventoryProducesCompleteDurableDescriptorSet()
        throws {
        let registry = OrdinaryTmuxPanelRegistry()
        let socket = OrdinaryTmuxSocketSelector.name(
            "tidey-agents"
        )
        var routesByWorkspace =
            [String: [OrdinaryTmuxPanelRoute]]()
        var records = [RuntimeResumeAgentRegistryRecord]()
        var statesBySessionID =
            [String: RuntimeResumeTmuxSessionState]()

        let genesisWorkspaceID = "workspace-1"
        let genesisCarrierPanelID = "carrier-genesis"
        let genesisSessionID = "$100"
        var genesisWindows = [RuntimeResumeTmuxWindowState]()
        for windowIndex in 0 ..< 12 {
            let paneID = "%g\(windowIndex)"
            let panelID = "genesis-window-\(windowIndex)"
            routesByWorkspace[genesisWorkspaceID, default: []]
                .append(
                    OrdinaryTmuxPanelRoute(
                        workspaceID: genesisWorkspaceID,
                        panelID: panelID,
                        carrierPanelID: genesisCarrierPanelID,
                        socket: socket,
                        sessionID: genesisSessionID,
                        sessionName: "genesis-extraction",
                        windowID: "@g\(windowIndex)",
                        windowIndex: windowIndex,
                        activePaneID: paneID,
                        cwd: "/tmp/genesis/\(windowIndex)",
                        currentCommand:
                            windowIndex < 11 ? "claude" : "bash"
                    )
                )
            genesisWindows.append(
                RuntimeResumeTmuxWindowState(
                    windowID: "@g\(windowIndex)",
                    index: windowIndex,
                    name: windowIndex < 11
                        ? "claude-\(windowIndex + 1)"
                        : "monitor",
                    isActive: windowIndex == 11,
                    panes: [
                        RuntimeResumeTmuxPaneState(
                            paneID: paneID,
                            index: 0,
                            workingDirectory:
                                "/tmp/genesis/\(windowIndex)",
                            isActive: true
                        ),
                    ]
                )
            )
            if windowIndex < 11 {
                let durableID = "claude-\(windowIndex + 1)"
                records.append(
                    RuntimeResumeAgentRegistryRecord(
                        binding: RuntimeResumeDescriptorBinding(
                            workspaceID: genesisWorkspaceID,
                            panelID: panelID,
                            tmuxPaneID: paneID
                        ),
                        vendor: .claude,
                        durableResumeID: durableID,
                        launch: RuntimeResumeLaunchSpecification(
                            executable: "claude",
                            arguments: ["--resume", durableID],
                            workingDirectory:
                                "/tmp/genesis/\(windowIndex)"
                        )
                    )
                )
            }
        }
        statesBySessionID[genesisSessionID] =
            RuntimeResumeTmuxSessionState(
                sessionID: genesisSessionID,
                sessionName: "genesis-extraction",
                windows: genesisWindows
            )

        for offset in 0 ..< 10 {
            let workspaceID = "workspace-\((offset % 6) + 2)"
            let sessionID = "$\(101 + offset)"
            let isStorage = offset == 9
            let canonicalSessionName = isStorage
                ? "storage"
                : "carrier-\(offset + 1)-session"
            let persistedSessionName = isStorage
                ? "s"
                : canonicalSessionName
            let carrierPanelID = "carrier-\(offset + 1)"
            let panelID = "agent-\(offset + 1)"
            let paneID = "%a\(offset + 1)"
            let vendor: RuntimeResumeAgentVendor =
                offset < 5 ? .claude : .codex
            let durableID = offset < 5
                ? "claude-\(offset + 12)"
                : "codex-\(offset - 4)"
            let executable = vendor == .claude
                ? "claude"
                : "codex"
            let resumeArgument = vendor == .claude
                ? "--resume"
                : "resume"
            let workingDirectory = "/tmp/agent/\(offset + 1)"
            routesByWorkspace[workspaceID, default: []].append(
                OrdinaryTmuxPanelRoute(
                    workspaceID: workspaceID,
                    panelID: panelID,
                    carrierPanelID: carrierPanelID,
                    socket: socket,
                    sessionID: sessionID,
                    sessionName: persistedSessionName,
                    windowID: "@a\(offset + 1)",
                    windowIndex: 0,
                    activePaneID: paneID,
                    cwd: workingDirectory,
                    currentCommand: executable
                )
            )
            records.append(
                RuntimeResumeAgentRegistryRecord(
                    binding: RuntimeResumeDescriptorBinding(
                        workspaceID: workspaceID,
                        panelID: panelID,
                        tmuxPaneID: paneID
                    ),
                    vendor: vendor,
                    durableResumeID: durableID,
                    launch: RuntimeResumeLaunchSpecification(
                        executable: executable,
                        arguments: [resumeArgument, durableID],
                        workingDirectory: workingDirectory
                    )
                )
            )
            statesBySessionID[sessionID] =
                RuntimeResumeTmuxSessionState(
                    sessionID: sessionID,
                    sessionName: canonicalSessionName,
                    windows: [
                        RuntimeResumeTmuxWindowState(
                            windowID: "@a\(offset + 1)",
                            index: 0,
                            name: executable,
                            isActive: true,
                            panes: [
                                RuntimeResumeTmuxPaneState(
                                    paneID: paneID,
                                    index: 0,
                                    workingDirectory:
                                        workingDirectory,
                                    isActive: true
                                ),
                            ]
                        ),
                    ]
                )
        }
        for workspaceID in routesByWorkspace.keys.sorted() {
            registry.replaceRoutes(
                workspaceID: workspaceID,
                routes: routesByWorkspace[workspaceID] ?? []
            )
        }
        let planner = OrdinaryTmuxRuntimeResumeCarrierPlanner(
            registry: registry,
            sessionReader: StubRuntimeResumeTmuxSessionReader(
                statesBySessionID: statesBySessionID
            )
        )
        let socketSender = RecordingRuntimeResumeSocketSender()
        let publisher = RuntimeResumeDescriptorPublisher(
            registryReader: StubRuntimeResumeRegistryReader(
                records: records
            ),
            topologyReader: StubRuntimeResumeTopologyReader(
                snapshotsByBinding: [:]
            ),
            carrierPlanner: planner,
            socketSender: socketSender
        )

        try publisher.publishCurrentDescriptors()

        let updates = socketSender.updates
        let launches = updates.flatMap {
            $0.content.topology?.windows.flatMap {
                $0.panes.compactMap(\.launch)
            } ?? []
        }
        let durableIDs = launches.map { $0.arguments[1] }
        let occurrences = Dictionary(
            grouping: durableIDs,
            by: { $0 }
        ).mapValues(\.count)
        let expectedIDs = Set(
            (1 ... 16).map { "claude-\($0)" } +
                (1 ... 5).map { "codex-\($0)" }
        )

        XCTAssertEqual(routesByWorkspace.keys.count, 7)
        XCTAssertEqual(updates.count, 11)
        XCTAssertEqual(Set(updates.map(\.binding.panelID)).count, 11)
        XCTAssertEqual(Set(updates.map(\.binding.workspaceID)).count, 7)
        XCTAssertTrue(updates.allSatisfy {
            $0.content.descriptorVersion == 3 &&
                $0.content.kind == .agent &&
                $0.content.restorePolicy == .create &&
                $0.content.agent == nil
        })
        XCTAssertEqual(launches.filter {
            $0.executable == "claude"
        }.count, 16)
        XCTAssertEqual(launches.filter {
            $0.executable == "codex"
        }.count, 5)
        XCTAssertEqual(Set(durableIDs), expectedIDs)
        XCTAssertTrue(occurrences.values.allSatisfy { $0 == 1 })

        let genesis = try XCTUnwrap(
            updates.first {
                $0.content.target?.tmuxSession ==
                    "genesis-extraction"
            }
        )
        let genesisTopology = try XCTUnwrap(
            genesis.content.topology
        )
        XCTAssertEqual(genesisTopology.windows.count, 12)
        XCTAssertEqual(
            genesisTopology.windows.flatMap(\.panes)
                .compactMap(\.launch).count,
            11
        )
        XCTAssertEqual(
            genesisTopology.windows.flatMap(\.panes)
                .filter { $0.launch == nil }.count,
            1
        )
        XCTAssertEqual(genesisTopology.activeWindowIndex, 11)
        XCTAssertEqual(genesisTopology.activePaneIndex, 0)
        XCTAssertEqual(genesis.binding.tmuxPaneID, "%g11")

        let storage = try XCTUnwrap(
            updates.first {
                $0.content.target?.tmuxSession == "storage"
            }
        )
        XCTAssertEqual(
            storage.content.target?.tmuxSession,
            "storage"
        )
        XCTAssertFalse(
            updates.contains {
                $0.content.target?.tmuxSession == "s"
            }
        )
    }

    func testCarrierPlannerRejectsIncompleteOrDuplicateInventory()
        throws {
        let routeA = Self.route(
            panelID: "panel-a",
            windowID: "@1",
            windowIndex: 0,
            paneID: "%1",
            cwd: "/tmp/a",
            carrierPanelID: "carrier-a",
            sessionID: "$1",
            sessionName: "a"
        )
        let routeB = Self.route(
            panelID: "panel-b",
            windowID: "@2",
            windowIndex: 0,
            paneID: "%2",
            cwd: "/tmp/b",
            carrierPanelID: "carrier-b",
            sessionID: "$2",
            sessionName: "b"
        )
        let registry = OrdinaryTmuxPanelRegistry()
        registry.replaceRoutes(
            workspaceID: "workspace-1",
            routes: [routeA, routeB]
        )
        let states = [
            "$1": RuntimeResumeTmuxSessionState(
                sessionID: "$1",
                sessionName: "a",
                windows: [
                    RuntimeResumeTmuxWindowState(
                        windowID: "@1",
                        index: 0,
                        name: "a",
                        isActive: true,
                        panes: [
                            RuntimeResumeTmuxPaneState(
                                paneID: "%1",
                                index: 0,
                                workingDirectory: "/tmp/a",
                                isActive: true
                            ),
                        ]
                    ),
                ]
            ),
            "$2": RuntimeResumeTmuxSessionState(
                sessionID: "$2",
                sessionName: "b",
                windows: [
                    RuntimeResumeTmuxWindowState(
                        windowID: "@2",
                        index: 0,
                        name: "b",
                        isActive: true,
                        panes: [
                            RuntimeResumeTmuxPaneState(
                                paneID: "%2",
                                index: 0,
                                workingDirectory: "/tmp/b",
                                isActive: true
                            ),
                        ]
                    ),
                ]
            ),
        ]
        let planner = OrdinaryTmuxRuntimeResumeCarrierPlanner(
            registry: registry,
            sessionReader: StubRuntimeResumeTmuxSessionReader(
                statesBySessionID: states
            )
        )
        let recordA = RuntimeResumeAgentRegistryRecord(
            binding: RuntimeResumeDescriptorBinding(
                workspaceID: "workspace-1",
                panelID: "panel-a",
                tmuxPaneID: "%1"
            ),
            vendor: .claude,
            durableResumeID: "duplicate-id",
            launch: RuntimeResumeLaunchSpecification(
                executable: "claude",
                arguments: ["--resume", "duplicate-id"],
                workingDirectory: "/tmp/a"
            )
        )
        let recordB = RuntimeResumeAgentRegistryRecord(
            binding: RuntimeResumeDescriptorBinding(
                workspaceID: "workspace-1",
                panelID: "panel-b",
                tmuxPaneID: "%2"
            ),
            vendor: .claude,
            durableResumeID: "duplicate-id",
            launch: RuntimeResumeLaunchSpecification(
                executable: "claude",
                arguments: ["--resume", "duplicate-id"],
                workingDirectory: "/tmp/b"
            )
        )
        let missingRouteRecord = RuntimeResumeAgentRegistryRecord(
            binding: RuntimeResumeDescriptorBinding(
                workspaceID: "workspace-1",
                panelID: "panel-missing",
                tmuxPaneID: "%3"
            ),
            vendor: .codex,
            durableResumeID: "missing-thread",
            launch: RuntimeResumeLaunchSpecification(
                executable: "codex",
                arguments: ["resume", "missing-thread"],
                workingDirectory: "/tmp/missing"
            )
        )

        XCTAssertTrue(
            try planner.publicationPlans(
                for: [recordA, recordB]
            ).isEmpty
        )
        XCTAssertTrue(
            try planner.publicationPlans(
                for: [recordA, missingRouteRecord]
            ).isEmpty
        )
    }

    func testRegistryReaderPublishesLiveResolvedBindingWithoutRewritingRegistry()
        throws {
        let supportDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "RuntimeResumeDescriptorPublisherTests-\(UUID().uuidString)",
                isDirectory: true
            )
        defer {
            try? FileManager.default.removeItem(
                at: supportDirectory
            )
        }
        let paths = BridgePaths(
            supportDirectory: supportDirectory
        )
        try paths.ensureSupportDirectoriesExist()
        let record = AgentSessionRegistryRecord(
            version: 1,
            vendor: "codex",
            workspaceID: "workspace-stale",
            sessionID: "wrapper-session",
            panelID: "panel-stale",
            pid: getpid(),
            cwd: "/tmp/project",
            createdAt: "2026-07-30T00:00:00Z",
            transcriptPath: nil,
            tmuxPaneID: "%7",
            tmuxSocketPath: "/tmp/tmux-501/tidey-agents",
            runtime: "codex_app_server",
            threadID: "thread-1"
        )
        let recordURL = paths
            .agentSessionsDirectory(for: "codex")
            .appendingPathComponent("wrapper-session.json")
        try JSONEncoder().encode(record).write(to: recordURL)
        let persistedBytes = try Data(contentsOf: recordURL)
        let monitor = AgentSessionRegistryMonitor(
            paths: paths,
            hub: AgentEventHub()
        )
        monitor.replaceLivePanels(
            workspaceID: "workspace-1",
            panels: [
                AgentPanelProcessSnapshot(
                    workspaceID: "workspace-1",
                    panelID: "panel-current",
                    effectiveShellPID: nil,
                    tmuxPaneID: "%7",
                    tmuxSocketPath:
                        "/tmp/tmux-501/tidey-agents"
                )
            ]
        )
        let reader =
            AgentSessionRegistryRuntimeResumeReader(
                monitor: monitor
            )
        monitor.scanRegistryForTesting()

        XCTAssertEqual(
            try reader.readAgentRegistryRecords(),
            [
                RuntimeResumeAgentRegistryRecord(
                    binding: RuntimeResumeDescriptorBinding(
                        workspaceID: "workspace-1",
                        panelID: "panel-current",
                        tmuxPaneID: "%7"
                    ),
                    vendor: .codex,
                    durableResumeID: "thread-1",
                    launch: RuntimeResumeLaunchSpecification(
                        executable: "codex",
                        arguments: ["resume", "thread-1"],
                        workingDirectory: "/tmp/project"
                    )
                )
            ]
        )
        XCTAssertEqual(
            try Data(contentsOf: recordURL),
            persistedBytes
        )
    }

    func testRegistryReaderRejectsProvisionalTrackedPlainCodexUntilRolloutIdentityExists()
        throws {
        let supportDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "RuntimeResumeDescriptorPublisherTests-\(UUID().uuidString)",
                isDirectory: true
            )
        defer {
            try? FileManager.default.removeItem(
                at: supportDirectory
            )
        }
        let paths = BridgePaths(
            supportDirectory: supportDirectory
        )
        try paths.ensureSupportDirectoriesExist()
        let wrapperSessionID =
            "11111111-1111-4111-8111-111111111111"
        let durableSessionID =
            "22222222-2222-4222-8222-222222222222"
        let rolloutURL = supportDirectory.appendingPathComponent(
            "rollout-2026-08-08T00-00-00-\(durableSessionID).jsonl"
        )
        try Data("{}\n".utf8).write(to: rolloutURL)
        let recordURL = paths
            .agentSessionsDirectory(for: "codex")
            .appendingPathComponent("tracked-plain.json")
        let monitor = AgentSessionRegistryMonitor(
            paths: paths,
            hub: AgentEventHub()
        )
        monitor.replaceLivePanels(
            workspaceID: "workspace-1",
            panels: [
                AgentPanelProcessSnapshot(
                    workspaceID: "workspace-1",
                    panelID: "panel-1",
                    effectiveShellPID: getpid(),
                    tmuxPaneID: "%7",
                    tmuxSocketPath:
                        "/tmp/tmux-501/default"
                )
            ]
        )
        let reader = AgentSessionRegistryRuntimeResumeReader(
            monitor: monitor
        )

        func writeRecord(
            sessionID: String,
            transcriptPath: String?,
            runtime: String? = nil,
            threadID: String? = nil
        ) throws {
            let record = AgentSessionRegistryRecord(
                version: 1,
                vendor: "codex",
                workspaceID: "workspace-1",
                sessionID: sessionID,
                panelID: "panel-1",
                pid: getpid(),
                cwd: "/tmp/project",
                createdAt: "2026-08-08T00:00:00Z",
                transcriptPath: transcriptPath,
                tmuxPaneID: "%7",
                tmuxSocketPath: "/tmp/tmux-501/default",
                runtime: runtime,
                threadID: threadID
            )
            try JSONEncoder().encode(record).write(
                to: recordURL,
                options: .atomic
            )
            monitor.scanRegistryForTesting()
        }

        try writeRecord(
            sessionID: wrapperSessionID,
            transcriptPath: nil
        )
        var snapshot = try reader.readAgentRegistrySnapshot()
        XCTAssertEqual(snapshot.sourceRecordCount, 1)
        XCTAssertEqual(snapshot.resolvedCandidateCount, 0)
        XCTAssertTrue(snapshot.records.isEmpty)
        XCTAssertFalse(snapshot.isComplete)
        XCTAssertNotNil(
            monitor.activeRecord(sessionID: wrapperSessionID)
        )

        try writeRecord(
            sessionID: wrapperSessionID,
            transcriptPath: rolloutURL.path
        )
        snapshot = try reader.readAgentRegistrySnapshot()
        XCTAssertEqual(snapshot.sourceRecordCount, 1)
        XCTAssertEqual(snapshot.resolvedCandidateCount, 0)
        XCTAssertTrue(snapshot.records.isEmpty)
        XCTAssertFalse(snapshot.isComplete)

        try writeRecord(
            sessionID: wrapperSessionID,
            transcriptPath: nil,
            runtime: "codex_app_server_starting"
        )
        snapshot = try reader.readAgentRegistrySnapshot()
        XCTAssertEqual(snapshot.sourceRecordCount, 1)
        XCTAssertEqual(snapshot.resolvedCandidateCount, 0)
        XCTAssertTrue(snapshot.records.isEmpty)
        XCTAssertFalse(snapshot.isComplete)

        try writeRecord(
            sessionID: wrapperSessionID,
            transcriptPath: nil,
            runtime: "codex_app_server"
        )
        snapshot = try reader.readAgentRegistrySnapshot()
        XCTAssertEqual(snapshot.sourceRecordCount, 1)
        XCTAssertEqual(snapshot.resolvedCandidateCount, 0)
        XCTAssertTrue(snapshot.records.isEmpty)
        XCTAssertFalse(snapshot.isComplete)

        try writeRecord(
            sessionID: durableSessionID,
            transcriptPath: rolloutURL.path
        )
        snapshot = try reader.readAgentRegistrySnapshot()
        XCTAssertTrue(snapshot.isComplete)
        XCTAssertEqual(snapshot.sourceRecordCount, 1)
        XCTAssertEqual(snapshot.resolvedCandidateCount, 1)
        XCTAssertEqual(
            snapshot.records.first?.durableResumeID,
            durableSessionID
        )
    }

    func testRegistryReaderTreatsMacOSTmpSocketAliasesAsSameEndpoint()
        throws {
        let supportDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "RuntimeResumeDescriptorPublisherTests-\(UUID().uuidString)",
                isDirectory: true
            )
        defer {
            try? FileManager.default.removeItem(
                at: supportDirectory
            )
        }
        let paths = BridgePaths(
            supportDirectory: supportDirectory
        )
        try paths.ensureSupportDirectoriesExist()
        let record = AgentSessionRegistryRecord(
            version: 1,
            vendor: "claude",
            workspaceID: "workspace-1",
            sessionID: "session-1",
            panelID: "panel-1",
            pid: getpid(),
            cwd: "/tmp/project",
            createdAt: "2026-08-07T00:00:00Z",
            transcriptPath: nil,
            tmuxPaneID: "%7",
            tmuxSocketPath: "/tmp/tmux-501/default"
        )
        let recordURL = paths
            .agentSessionsDirectory(for: "claude")
            .appendingPathComponent("session-1.json")
        try JSONEncoder().encode(record).write(to: recordURL)
        let monitor = AgentSessionRegistryMonitor(
            paths: paths,
            hub: AgentEventHub()
        )
        monitor.replaceLivePanels(
            workspaceID: "workspace-1",
            panels: [
                AgentPanelProcessSnapshot(
                    workspaceID: "workspace-1",
                    panelID: "panel-1",
                    effectiveShellPID: getpid(),
                    tmuxPaneID: "%7",
                    tmuxSocketPath:
                        "/private/tmp/tmux-501/default"
                )
            ]
        )
        monitor.scanRegistryForTesting()

        let snapshot = try AgentSessionRegistryRuntimeResumeReader(
            monitor: monitor
        ).readAgentRegistrySnapshot()

        XCTAssertTrue(snapshot.isComplete)
        XCTAssertEqual(snapshot.sourceRecordCount, 1)
        XCTAssertEqual(snapshot.resolvedCandidateCount, 1)
        XCTAssertEqual(snapshot.records.count, 1)
        XCTAssertEqual(
            snapshot.records.first?.binding,
            RuntimeResumeDescriptorBinding(
                workspaceID: "workspace-1",
                panelID: "panel-1",
                tmuxPaneID: "%7"
            )
        )
    }

    func testRegistryReaderStillRejectsDifferentTmuxSocketEndpoint()
        throws {
        let supportDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "RuntimeResumeDescriptorPublisherTests-\(UUID().uuidString)",
                isDirectory: true
            )
        defer {
            try? FileManager.default.removeItem(
                at: supportDirectory
            )
        }
        let paths = BridgePaths(
            supportDirectory: supportDirectory
        )
        try paths.ensureSupportDirectoriesExist()
        let record = AgentSessionRegistryRecord(
            version: 1,
            vendor: "claude",
            workspaceID: "workspace-1",
            sessionID: "session-1",
            panelID: "panel-1",
            pid: getpid(),
            cwd: "/tmp/project",
            createdAt: "2026-08-07T00:00:00Z",
            transcriptPath: nil,
            tmuxPaneID: "%7",
            tmuxSocketPath: "/tmp/tmux-501/default"
        )
        let recordURL = paths
            .agentSessionsDirectory(for: "claude")
            .appendingPathComponent("session-1.json")
        try JSONEncoder().encode(record).write(to: recordURL)
        let monitor = AgentSessionRegistryMonitor(
            paths: paths,
            hub: AgentEventHub()
        )
        monitor.replaceLivePanels(
            workspaceID: "workspace-1",
            panels: [
                AgentPanelProcessSnapshot(
                    workspaceID: "workspace-1",
                    panelID: "panel-1",
                    effectiveShellPID: getpid(),
                    tmuxPaneID: "%7",
                    tmuxSocketPath:
                        "/private/tmp/tmux-501/different"
                )
            ]
        )
        monitor.scanRegistryForTesting()

        let snapshot = try AgentSessionRegistryRuntimeResumeReader(
            monitor: monitor
        ).readAgentRegistrySnapshot()

        XCTAssertFalse(snapshot.isComplete)
        XCTAssertEqual(snapshot.sourceRecordCount, 1)
        XCTAssertEqual(snapshot.resolvedCandidateCount, 0)
        XCTAssertTrue(snapshot.records.isEmpty)
    }

    func testRegistryReaderAndPublisherPreserveDirectNonTmuxAgentBinding()
        throws {
        let supportDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "RuntimeResumeDescriptorPublisherTests-\(UUID().uuidString)",
                isDirectory: true
            )
        defer {
            try? FileManager.default.removeItem(
                at: supportDirectory
            )
        }
        let paths = BridgePaths(
            supportDirectory: supportDirectory
        )
        try paths.ensureSupportDirectoriesExist()
        let record = AgentSessionRegistryRecord(
            version: 1,
            vendor: "codex",
            workspaceID: "workspace-direct",
            sessionID: "wrapper-direct",
            panelID: "panel-direct",
            pid: getpid(),
            cwd: "/tmp/direct-project",
            createdAt: "2026-08-01T00:00:00Z",
            transcriptPath: nil,
            tmuxPaneID: nil,
            tmuxSocketPath: nil,
            runtime: "codex_app_server",
            threadID: "thread-direct"
        )
        let recordURL = paths
            .agentSessionsDirectory(for: "codex")
            .appendingPathComponent("wrapper-direct.json")
        try JSONEncoder().encode(record).write(to: recordURL)
        let monitor = AgentSessionRegistryMonitor(
            paths: paths,
            hub: AgentEventHub()
        )
        monitor.replaceLivePanels(
            workspaceID: "workspace-direct",
            panels: [
                AgentPanelProcessSnapshot(
                    workspaceID: "workspace-direct",
                    panelID: "panel-direct",
                    effectiveShellPID: getpid(),
                    tmuxPaneID: nil,
                    tmuxSocketPath: nil
                )
            ]
        )
        let reader = AgentSessionRegistryRuntimeResumeReader(
            monitor: monitor
        )
        monitor.scanRegistryForTesting()
        let records = try reader.readAgentRegistryRecords()
        let directRecord = try XCTUnwrap(records.first)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(directRecord.binding.workspaceID, "workspace-direct")
        XCTAssertEqual(directRecord.binding.panelID, "panel-direct")
        XCTAssertNil(directRecord.binding.tmuxPaneID)

        let socketSender = RecordingRuntimeResumeSocketSender()
        let publisher = RuntimeResumeDescriptorPublisher(
            registryReader: StubRuntimeResumeRegistryReader(
                records: records
            ),
            topologyReader: StubRuntimeResumeTopologyReader(
                snapshotsByBinding: [:]
            ),
            socketSender: socketSender,
            queue: DispatchQueue(
                label: "RuntimeResumeDescriptorPublisherTests.direct"
            )
        )

        try publisher.publishCurrentDescriptors()

        let update = try XCTUnwrap(socketSender.updates.first)
        XCTAssertEqual(socketSender.updates.count, 1)
        XCTAssertEqual(update.binding, directRecord.binding)
        XCTAssertEqual(update.content.kind, .agent)
        XCTAssertEqual(update.content.restorePolicy, .directResume)
        XCTAssertNil(update.content.target)
        XCTAssertNil(update.content.topology)
        XCTAssertEqual(
            update.content.agent?.durableResumeID,
            "thread-direct"
        )

        monitor.replaceLivePanels(
            workspaceID: "workspace-direct",
            panels: [
                AgentPanelProcessSnapshot(
                    workspaceID: "workspace-direct",
                    panelID: "panel-direct",
                    effectiveShellPID: getpid(),
                    tmuxPaneID: "%99",
                    tmuxSocketPath: "/tmp/tmux.sock"
                )
            ]
        )
        let incompleteSnapshot =
            try reader.readAgentRegistrySnapshot()
        XCTAssertEqual(incompleteSnapshot.sourceRecordCount, 1)
        XCTAssertEqual(
            incompleteSnapshot.resolvedCandidateCount,
            0
        )
        XCTAssertTrue(incompleteSnapshot.records.isEmpty)
        XCTAssertFalse(incompleteSnapshot.isComplete)
    }

    func testRegistrySnapshotRejectsConflictingRecordsSharingBinding()
        throws {
        let supportDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "RuntimeResumeDescriptorPublisherTests-\(UUID().uuidString)",
                isDirectory: true
            )
        defer {
            try? FileManager.default.removeItem(
                at: supportDirectory
            )
        }
        let paths = BridgePaths(
            supportDirectory: supportDirectory
        )
        try paths.ensureSupportDirectoriesExist()
        for sessionID in ["session-a", "session-b"] {
            let record = AgentSessionRegistryRecord(
                version: 1,
                vendor: "claude",
                workspaceID: "workspace-direct",
                sessionID: sessionID,
                panelID: "panel-direct",
                pid: getpid(),
                cwd: "/tmp/project",
                createdAt: "2026-08-07T00:00:00Z",
                transcriptPath: nil
            )
            let recordURL = paths
                .agentSessionsDirectory(for: "claude")
                .appendingPathComponent("\(sessionID).json")
            try JSONEncoder().encode(record).write(to: recordURL)
        }
        let monitor = AgentSessionRegistryMonitor(
            paths: paths,
            hub: AgentEventHub()
        )
        monitor.replaceLivePanels(
            workspaceID: "workspace-direct",
            panels: [
                AgentPanelProcessSnapshot(
                    workspaceID: "workspace-direct",
                    panelID: "panel-direct",
                    effectiveShellPID: getpid(),
                    tmuxPaneID: nil,
                    tmuxSocketPath: nil
                )
            ]
        )
        monitor.scanRegistryForTesting()

        let snapshot = try AgentSessionRegistryRuntimeResumeReader(
            monitor: monitor
        ).readAgentRegistrySnapshot()

        XCTAssertEqual(snapshot.sourceRecordCount, 2)
        XCTAssertEqual(snapshot.resolvedCandidateCount, 2)
        XCTAssertTrue(snapshot.records.isEmpty)
        XCTAssertFalse(snapshot.isComplete)
    }

    func testTopologyReaderRequiresExactCurrentPaneBinding()
        throws {
        let registry = OrdinaryTmuxPanelRegistry()
        registry.replaceRoutes(
            workspaceID: "workspace-1",
            routes: [
                Self.route(
                    panelID: "panel-1",
                    windowID: "@1",
                    windowIndex: 1,
                    paneID: "%7",
                    cwd: "/tmp/agent"
                ),
                Self.route(
                    panelID: "panel-2",
                    windowID: "@2",
                    windowIndex: 2,
                    paneID: "%8",
                    cwd: "/tmp/shell"
                )
            ]
        )
        let reader =
            OrdinaryTmuxRuntimeResumeTopologyReader(
                registry: registry
            )
        let binding = RuntimeResumeDescriptorBinding(
            workspaceID: "workspace-1",
            panelID: "panel-1",
            tmuxPaneID: "%7"
        )

        let snapshot = try XCTUnwrap(
            reader.topologySnapshot(for: binding)
        )

        XCTAssertEqual(snapshot.binding, binding)
        XCTAssertEqual(
            snapshot.target,
            RuntimeResumeTmuxTarget(
                socketName: "tidey-agents",
                tmuxSession: "work"
            )
        )
        XCTAssertEqual(
            snapshot.topology,
            RuntimeResumeTmuxTopology(
                windows: [
                    RuntimeResumeTmuxWindow(
                        index: 1,
                        name: nil,
                        panes: [
                            RuntimeResumeTmuxPane(
                                index: 0,
                                workingDirectory: "/tmp/agent",
                                launch: nil
                            )
                        ]
                    ),
                    RuntimeResumeTmuxWindow(
                        index: 2,
                        name: nil,
                        panes: [
                            RuntimeResumeTmuxPane(
                                index: 0,
                                workingDirectory: "/tmp/shell",
                                launch: nil
                            )
                        ]
                    )
                ],
                activeWindowIndex: 1,
                activePaneIndex: 0
            )
        )
        XCTAssertNil(
            try reader.topologySnapshot(
                for: RuntimeResumeDescriptorBinding(
                    workspaceID: "workspace-1",
                    panelID: "panel-1",
                    tmuxPaneID: "%99"
                )
            )
        )
    }

    func testTopologyReaderMergesTrackedPanesSharingWindowIndex()
        throws {
        let registry = OrdinaryTmuxPanelRegistry()
        registry.replaceRoutes(
            workspaceID: "workspace-1",
            routes: [
                Self.route(
                    panelID: "panel-peer",
                    windowID: "@1",
                    windowIndex: 1,
                    paneID: "%6",
                    cwd: "/tmp/peer"
                ),
                Self.route(
                    panelID: "panel-agent",
                    windowID: "@1",
                    windowIndex: 1,
                    paneID: "%7",
                    cwd: "/tmp/agent"
                ),
                Self.route(
                    panelID: "panel-shell",
                    windowID: "@2",
                    windowIndex: 2,
                    paneID: "%8",
                    cwd: "/tmp/shell"
                )
            ]
        )
        let reader =
            OrdinaryTmuxRuntimeResumeTopologyReader(
                registry: registry
            )

        let snapshot = try XCTUnwrap(
            reader.topologySnapshot(
                for: RuntimeResumeDescriptorBinding(
                    workspaceID: "workspace-1",
                    panelID: "panel-agent",
                    tmuxPaneID: "%7"
                )
            )
        )

        XCTAssertEqual(
            snapshot.topology,
            RuntimeResumeTmuxTopology(
                windows: [
                    RuntimeResumeTmuxWindow(
                        index: 1,
                        name: nil,
                        panes: [
                            RuntimeResumeTmuxPane(
                                index: 0,
                                workingDirectory: "/tmp/peer",
                                launch: nil
                            ),
                            RuntimeResumeTmuxPane(
                                index: 1,
                                workingDirectory: "/tmp/agent",
                                launch: nil
                            )
                        ]
                    ),
                    RuntimeResumeTmuxWindow(
                        index: 2,
                        name: nil,
                        panes: [
                            RuntimeResumeTmuxPane(
                                index: 0,
                                workingDirectory: "/tmp/shell",
                                launch: nil
                            )
                        ]
                    )
                ],
                activeWindowIndex: 1,
                activePaneIndex: 1
            )
        )
    }

    func testTopologyReaderUsesRestorationSocketWithoutChangingLiveSocket()
        throws {
        let registry = OrdinaryTmuxPanelRegistry()
        let liveSocket = OrdinaryTmuxSocketSelector.path(
            "/private/tmp/tmux-501/default"
        )
        registry.replaceRoutes(
            workspaceID: "workspace-1",
            routes: [
                OrdinaryTmuxPanelRoute(
                    workspaceID: "workspace-1",
                    panelID: "panel-1",
                    carrierPanelID: "carrier-1",
                    socket: liveSocket,
                    restorationSocket: .defaultSocket,
                    sessionID: "$1",
                    sessionName: "work",
                    windowID: "@1",
                    windowIndex: 0,
                    activePaneID: "%7",
                    cwd: "/tmp/project",
                    currentCommand: "codex"
                ),
            ]
        )
        let reader = OrdinaryTmuxRuntimeResumeTopologyReader(
            registry: registry
        )

        let snapshot = try XCTUnwrap(
            reader.topologySnapshot(
                for: RuntimeResumeDescriptorBinding(
                    workspaceID: "workspace-1",
                    panelID: "panel-1",
                    tmuxPaneID: "%7"
                )
            )
        )

        XCTAssertEqual(
            registry.route(forPanelID: "panel-1")?.socket,
            liveSocket
        )
        XCTAssertEqual(
            snapshot.target,
            RuntimeResumeTmuxTarget(
                defaultSocketAndTmuxSession: "work"
            )
        )
    }

    func testPublishesOneCarrierDescriptorWithEveryPaneAgentLaunch()
        throws {
        let registry = OrdinaryTmuxPanelRegistry()
        registry.replaceRoutes(
            workspaceID: "workspace-1",
            routes: [
                Self.route(
                    panelID: "panel-claude",
                    windowID: "@1",
                    windowIndex: 1,
                    paneID: "%7",
                    cwd: "/tmp/claude",
                    carrierPanelID: "carrier-1",
                    sessionID: "$12",
                    sessionName: "genesis-extraction"
                ),
                Self.route(
                    panelID: "panel-codex",
                    windowID: "@2",
                    windowIndex: 2,
                    paneID: "%8",
                    cwd: "/tmp/codex",
                    carrierPanelID: "carrier-1",
                    sessionID: "$12",
                    sessionName: "genesis-extraction"
                ),
            ]
        )
        let claudeLaunch = RuntimeResumeLaunchSpecification(
            executable: "claude",
            arguments: ["--resume", "claude-session"],
            workingDirectory: "/tmp/claude"
        )
        let codexLaunch = RuntimeResumeLaunchSpecification(
            executable: "codex",
            arguments: ["resume", "codex-thread"],
            workingDirectory: "/tmp/codex"
        )
        let records = [
            RuntimeResumeAgentRegistryRecord(
                binding: RuntimeResumeDescriptorBinding(
                    workspaceID: "workspace-1",
                    panelID: "panel-claude",
                    tmuxPaneID: "%7"
                ),
                vendor: .claude,
                durableResumeID: "claude-session",
                launch: claudeLaunch
            ),
            RuntimeResumeAgentRegistryRecord(
                binding: RuntimeResumeDescriptorBinding(
                    workspaceID: "workspace-1",
                    panelID: "panel-codex",
                    tmuxPaneID: "%8"
                ),
                vendor: .codex,
                durableResumeID: "codex-thread",
                launch: codexLaunch
            ),
        ]
        let state = RuntimeResumeTmuxSessionState(
            sessionID: "$12",
            sessionName: "genesis-extraction",
            windows: [
                RuntimeResumeTmuxWindowState(
                    windowID: "@1",
                    index: 1,
                    name: "claude",
                    isActive: false,
                    panes: [
                        RuntimeResumeTmuxPaneState(
                            paneID: "%7",
                            index: 0,
                            workingDirectory: "/tmp/claude",
                            isActive: true
                        ),
                        RuntimeResumeTmuxPaneState(
                            paneID: "%70",
                            index: 1,
                            workingDirectory: "/tmp/shell",
                            isActive: false
                        ),
                    ]
                ),
                RuntimeResumeTmuxWindowState(
                    windowID: "@2",
                    index: 2,
                    name: "codex",
                    isActive: false,
                    panes: [
                        RuntimeResumeTmuxPaneState(
                            paneID: "%8",
                            index: 0,
                            workingDirectory: "/tmp/codex",
                            isActive: true
                        ),
                    ]
                ),
                RuntimeResumeTmuxWindowState(
                    windowID: "@3",
                    index: 3,
                    name: "monitor",
                    isActive: true,
                    panes: [
                        RuntimeResumeTmuxPaneState(
                            paneID: "%9",
                            index: 0,
                            workingDirectory: "/tmp/monitor",
                            isActive: true
                        ),
                    ]
                ),
            ]
        )
        let planner = OrdinaryTmuxRuntimeResumeCarrierPlanner(
            registry: registry,
            sessionReader: StubRuntimeResumeTmuxSessionReader(
                statesBySessionID: ["$12": state]
            )
        )
        let socketSender = RecordingRuntimeResumeSocketSender()
        let publisher = RuntimeResumeDescriptorPublisher(
            registryReader: StubRuntimeResumeRegistryReader(
                records: records
            ),
            topologyReader: StubRuntimeResumeTopologyReader(
                snapshotsByBinding: [:]
            ),
            carrierPlanner: planner,
            socketSender: socketSender
        )

        try publisher.publishCurrentDescriptors()

        let update = try XCTUnwrap(socketSender.updates.first)
        XCTAssertEqual(socketSender.updates.count, 1)
        XCTAssertEqual(
            update.binding,
            RuntimeResumeDescriptorBinding(
                workspaceID: "workspace-1",
                panelID: "carrier-1",
                tmuxPaneID: "%9"
            )
        )
        XCTAssertEqual(update.content.descriptorVersion, 3)
        XCTAssertEqual(update.content.kind, .agent)
        XCTAssertEqual(update.content.restorePolicy, .create)
        XCTAssertEqual(
            update.content.target,
            RuntimeResumeTmuxTarget(
                socketName: "tidey-agents",
                tmuxSession: "genesis-extraction"
            )
        )
        XCTAssertNil(update.content.agent)
        XCTAssertEqual(
            update.content.topology,
            RuntimeResumeTmuxTopology(
                windows: [
                    RuntimeResumeTmuxWindow(
                        index: 1,
                        name: "claude",
                        panes: [
                            RuntimeResumeTmuxPane(
                                index: 0,
                                workingDirectory: "/tmp/claude",
                                launch: claudeLaunch
                            ),
                            RuntimeResumeTmuxPane(
                                index: 1,
                                workingDirectory: "/tmp/shell",
                                launch: nil
                            ),
                        ]
                    ),
                    RuntimeResumeTmuxWindow(
                        index: 2,
                        name: "codex",
                        panes: [
                            RuntimeResumeTmuxPane(
                                index: 0,
                                workingDirectory: "/tmp/codex",
                                launch: codexLaunch
                            ),
                        ]
                    ),
                    RuntimeResumeTmuxWindow(
                        index: 3,
                        name: "monitor",
                        panes: [
                            RuntimeResumeTmuxPane(
                                index: 0,
                                workingDirectory: "/tmp/monitor",
                                launch: nil
                            ),
                        ]
                    ),
                ],
                activeWindowIndex: 3,
                activePaneIndex: 0
            )
        )
    }

    func testSocketSenderUsesNestedDescriptorPayloadWithoutBridgeAuthority()
        throws {
        let requestSender = RecordingTideyRequestSender()
        let sender = TideyRuntimeResumeDescriptorSocketSender(
            requestSender: requestSender
        )
        let binding = RuntimeResumeDescriptorBinding(
            workspaceID: "workspace-1",
            panelID: "panel-1",
            tmuxPaneID: "%7"
        )
        let target = RuntimeResumeTmuxTarget(
            defaultSocketAndTmuxSession: "work"
        )
        let content = RuntimeResumeDescriptorContent(
            descriptorVersion: 1,
            kind: .agent,
            restorePolicy: .create,
            target: target,
            topology: nil,
            agent: RuntimeResumeAgentSpecification(
                vendor: .claude,
                durableResumeID: "session-1",
                launch: RuntimeResumeLaunchSpecification(
                    executable: "claude",
                    arguments: ["--resume", "session-1"],
                    workingDirectory: "/tmp/project"
                )
            )
        )

        try sender.send(
            RuntimeResumeDescriptorSocketUpdate(
                binding: binding,
                content: content
            )
        )

        let request = try XCTUnwrap(
            requestSender.requests.first
        )
        XCTAssertEqual(
            request.action,
            "update_runtime_resume_descriptor"
        )
        XCTAssertNotNil(request.params?["binding"]?.objectValue)
        XCTAssertNotNil(
            request.params?["descriptor"]?.objectValue
        )
        XCTAssertNil(request.params?["revision"])
        XCTAssertNil(
            request.params?["content_fingerprint"]
        )
    }

    func testSocketSenderListsAndConditionallyRemovesAgentDescriptors()
        throws {
        let content = RuntimeResumeDescriptorContent(
            descriptorVersion: 1,
            kind: .agent,
            restorePolicy: .directResume,
            target: nil,
            topology: nil,
            agent: RuntimeResumeAgentSpecification(
                vendor: .codex,
                durableResumeID: "thread-1",
                launch: RuntimeResumeLaunchSpecification(
                    executable: "codex",
                    arguments: ["resume", "thread-1"],
                    workingDirectory: "/tmp/project"
                )
            )
        )
        let contentData = try JSONEncoder().encode(content)
        let contentObject = try JSONDecoder().decode(
            [String: JSONValue].self,
            from: contentData
        )
        let requestSender = RecordingTideyRequestSender(
            responses: [
                BridgeResponse(
                    id: nil,
                    ok: true,
                    result: [
                        "descriptors": .array([
                            .object([
                                "binding": .object([
                                    "workspace_id": .string(
                                        "workspace-1"
                                    ),
                                    "panel_id": .string("panel-1"),
                                ]),
                                "revision": .number(4),
                                "descriptor": .object(
                                    contentObject
                                ),
                            ]),
                        ]),
                    ],
                    error: nil
                ),
                BridgeResponse(
                    id: nil,
                    ok: true,
                    result: [
                        "accepted": .bool(true),
                        "changed": .bool(true),
                    ],
                    error: nil
                ),
            ]
        )
        let sender = TideyRuntimeResumeDescriptorSocketSender(
            requestSender: requestSender
        )

        let stored = try XCTUnwrap(
            sender.currentAgentDescriptors().first
        )
        XCTAssertEqual(
            stored.slot,
            RuntimeResumeDescriptorSlot(
                workspaceID: "workspace-1",
                panelID: "panel-1"
            )
        )
        XCTAssertEqual(stored.revision, 4)
        XCTAssertEqual(stored.content, content)

        let changed = try sender.remove(
            RuntimeResumeDescriptorSocketRemoval(
                slot: stored.slot,
                expectedRevision: stored.revision,
                expectedContent: stored.content
            )
        )
        XCTAssertTrue(changed)
        XCTAssertEqual(
            requestSender.requests.map(\.action),
            [
                "list_runtime_resume_descriptors",
                "remove_runtime_resume_descriptor",
            ]
        )
        let removalParams = try XCTUnwrap(
            requestSender.requests.last?.params
        )
        XCTAssertEqual(
            removalParams["binding"]?.objectValue?["workspace_id"]?
                .stringValue,
            "workspace-1"
        )
        XCTAssertEqual(
            removalParams["binding"]?.objectValue?["panel_id"]?
                .stringValue,
            "panel-1"
        )
        XCTAssertNil(
            removalParams["binding"]?.objectValue?["tmux_pane_id"]
        )
        XCTAssertEqual(
            removalParams["expected_revision"]?.intValue,
            4
        )
        XCTAssertNotNil(
            removalParams["expected_descriptor"]?.objectValue
        )
    }

    func testPublishesCanonicalAgentAndTmuxTopologyForBoundPanel()
        throws {
        let binding = RuntimeResumeDescriptorBinding(
            workspaceID: "workspace-1",
            panelID: "panel-1",
            tmuxPaneID: "%7"
        )
        let staleBinding = RuntimeResumeDescriptorBinding(
            workspaceID: "workspace-stale",
            panelID: "panel-stale",
            tmuxPaneID: "%9"
        )
        let currentBindingForStaleRecord =
            RuntimeResumeDescriptorBinding(
                workspaceID: "workspace-current",
                panelID: "panel-current",
                tmuxPaneID: "%9"
            )
        let target = RuntimeResumeTmuxTarget(
            socketName: "tidey-agents",
            tmuxSession: "work"
        )
        let launch = RuntimeResumeLaunchSpecification(
            executable: "codex",
            arguments: ["resume", "thread-1"],
            workingDirectory: "/tmp/project"
        )
        let topology = RuntimeResumeTmuxTopology(
            windows: [
                RuntimeResumeTmuxWindow(
                    index: 1,
                    name: "agent",
                    panes: [
                        RuntimeResumeTmuxPane(
                            index: 0,
                            workingDirectory: "/tmp/project",
                            launch: launch
                        )
                    ]
                ),
                RuntimeResumeTmuxWindow(
                    index: 2,
                    name: "shell",
                    panes: [
                        RuntimeResumeTmuxPane(
                            index: 0,
                            workingDirectory: "/tmp/project",
                            launch: nil
                        )
                    ]
                )
            ],
            activeWindowIndex: 1,
            activePaneIndex: 0
        )
        let matchingRecord = RuntimeResumeAgentRegistryRecord(
            binding: binding,
            vendor: .codex,
            durableResumeID: "thread-1",
            launch: launch
        )
        let staleRecord = RuntimeResumeAgentRegistryRecord(
            binding: staleBinding,
            vendor: .claude,
            durableResumeID: "stale-session",
            launch: RuntimeResumeLaunchSpecification(
                executable: "claude",
                arguments: ["--resume", "stale-session"],
                workingDirectory: "/tmp/stale"
            )
        )
        let topologySnapshot = RuntimeResumeTmuxTopologySnapshot(
            binding: binding,
            target: target,
            topology: topology
        )
        let registryReader = StubRuntimeResumeRegistryReader(
            records: [staleRecord, matchingRecord]
        )
        let topologyReader = StubRuntimeResumeTopologyReader(
            snapshotsByBinding: [
                binding: topologySnapshot,
                staleBinding: RuntimeResumeTmuxTopologySnapshot(
                    binding: currentBindingForStaleRecord,
                    target: target,
                    topology: topology
                )
            ]
        )
        let socketSender = RecordingRuntimeResumeSocketSender()
        let publisher = RuntimeResumeDescriptorPublisher(
            registryReader: registryReader,
            topologyReader: topologyReader,
            socketSender: socketSender,
            queue: DispatchQueue(
                label:
                    "RuntimeResumeDescriptorPublisherTests.behavior"
            )
        )

        try publisher.publishCurrentDescriptors()

        XCTAssertEqual(
            socketSender.updates,
            [
                RuntimeResumeDescriptorSocketUpdate(
                    binding: binding,
                    content: RuntimeResumeDescriptorContent(
                        descriptorVersion: 1,
                        kind: .agent,
                        restorePolicy: .create,
                        target: target,
                        topology: topology,
                        agent: RuntimeResumeAgentSpecification(
                            vendor: .codex,
                            durableResumeID: "thread-1",
                            launch: launch
                        )
                    )
                )
            ]
        )

        try publisher.publishCurrentDescriptors()
        XCTAssertEqual(socketSender.updates.count, 1)
    }

    func testPublisherSeamsCompile() throws {
        let binding = RuntimeResumeDescriptorBinding(
            workspaceID: "workspace-1",
            panelID: "panel-1",
            tmuxPaneID: "%7"
        )
        let target = RuntimeResumeTmuxTarget(
            socketPath: "/tmp/tmux-501/default",
            tmuxSession: "work"
        )
        let launch = RuntimeResumeLaunchSpecification(
            executable: "/usr/local/bin/codex",
            arguments: ["resume", "thread-1"],
            workingDirectory: "/tmp/project"
        )
        let registryRecord = RuntimeResumeAgentRegistryRecord(
            binding: binding,
            vendor: .codex,
            durableResumeID: "thread-1",
            launch: launch
        )
        let topologySnapshot = RuntimeResumeTmuxTopologySnapshot(
            binding: binding,
            target: target,
            topology: RuntimeResumeTmuxTopology(
                windows: [
                    RuntimeResumeTmuxWindow(
                        index: 0,
                        name: "editor",
                        panes: [
                            RuntimeResumeTmuxPane(
                                index: 0,
                                workingDirectory: "/tmp/project",
                                launch: launch
                            )
                        ]
                    )
                ],
                activeWindowIndex: 0,
                activePaneIndex: 0
            )
        )
        let content = RuntimeResumeDescriptorContent(
            descriptorVersion: 1,
            kind: .agent,
            restorePolicy: .create,
            target: target,
            topology: topologySnapshot.topology,
            agent: RuntimeResumeAgentSpecification(
                vendor: registryRecord.vendor,
                durableResumeID: registryRecord.durableResumeID,
                launch: registryRecord.launch
            )
        )

        let canonicalizer =
            RuntimeResumeDescriptorCanonicalizer()
        let canonical = try canonicalizer.canonicalize(content)
        XCTAssertFalse(canonical.data.isEmpty)
        XCTAssertFalse(canonical.fingerprint.rawValue.isEmpty)

        var reducer = RuntimeResumeDescriptorPublicationReducer()
        XCTAssertEqual(
            reducer.decision(
                binding: binding,
                canonicalContent: canonical
            ),
            .publish
        )
        reducer.acknowledgePublished(
            binding: binding,
            canonicalContent: canonical
        )
        XCTAssertEqual(
            reducer.decision(
                binding: binding,
                canonicalContent: canonical
            ),
            .unchanged
        )

        let registryReader = StubRuntimeResumeRegistryReader(
            records: [registryRecord]
        )
        let topologyReader = StubRuntimeResumeTopologyReader(
            snapshotsByBinding: [binding: topologySnapshot]
        )
        let socketSender = RecordingRuntimeResumeSocketSender()
        let publisher = RuntimeResumeDescriptorPublisher(
            registryReader: registryReader,
            topologyReader: topologyReader,
            canonicalizer: canonicalizer,
            socketSender: socketSender,
            queue: DispatchQueue(
                label: "RuntimeResumeDescriptorPublisherTests"
            )
        )

        XCTAssertNotNil(publisher as Any)
        XCTAssertTrue(socketSender.updates.isEmpty)
        XCTAssertEqual(registryReader.records, [registryRecord])
        XCTAssertEqual(
            try topologyReader.topologySnapshot(for: binding),
            topologySnapshot
        )
    }

    private static func route(
        panelID: String,
        windowID: String,
        windowIndex: Int,
        paneID: String,
        cwd: String?,
        carrierPanelID: String = "carrier-1",
        nativeCarrierPanelID: String? = nil,
        sessionID: String = "$1",
        sessionName: String = "work",
        socket: OrdinaryTmuxSocketSelector =
            .name("tidey-agents"),
        restorationSocket: OrdinaryTmuxSocketSelector? = nil
    ) -> OrdinaryTmuxPanelRoute {
        OrdinaryTmuxPanelRoute(
            workspaceID: "workspace-1",
            panelID: panelID,
            carrierPanelID: carrierPanelID,
            nativeCarrierPanelID: nativeCarrierPanelID,
            socket: socket,
            restorationSocket: restorationSocket,
            sessionID: sessionID,
            sessionName: sessionName,
            windowID: windowID,
            windowIndex: windowIndex,
            activePaneID: paneID,
            cwd: cwd,
            currentCommand: "zsh"
        )
    }

    private static func directContent(
        durableResumeID: String
    ) -> RuntimeResumeDescriptorContent {
        RuntimeResumeDescriptorContent(
            descriptorVersion: 1,
            kind: .agent,
            restorePolicy: .directResume,
            target: nil,
            topology: nil,
            agent: RuntimeResumeAgentSpecification(
                vendor: .codex,
                durableResumeID: durableResumeID,
                launch: RuntimeResumeLaunchSpecification(
                    executable: "codex",
                    arguments: ["resume", durableResumeID],
                    workingDirectory: "/tmp/project"
                )
            )
        )
    }
}

private final class StubRuntimeResumeRegistryReader:
    RuntimeResumeAgentRegistryReading,
    @unchecked Sendable {
    let snapshot: RuntimeResumeAgentRegistrySnapshot

    var records: [RuntimeResumeAgentRegistryRecord] {
        snapshot.records
    }

    init(records: [RuntimeResumeAgentRegistryRecord]) {
        snapshot = RuntimeResumeAgentRegistrySnapshot(
            sourceRecordCount: records.count,
            resolvedCandidateCount: records.count,
            records: records
        )
    }

    init(snapshot: RuntimeResumeAgentRegistrySnapshot) {
        self.snapshot = snapshot
    }

    func readAgentRegistrySnapshot()
        throws -> RuntimeResumeAgentRegistrySnapshot {
        snapshot
    }
}

private final class StubRuntimeResumeTopologyReader:
    RuntimeResumeTmuxTopologyReading,
    @unchecked Sendable {
    let snapshotsByBinding:
        [RuntimeResumeDescriptorBinding:
            RuntimeResumeTmuxTopologySnapshot]

    init(
        snapshotsByBinding:
            [RuntimeResumeDescriptorBinding:
                RuntimeResumeTmuxTopologySnapshot]
    ) {
        self.snapshotsByBinding = snapshotsByBinding
    }

    func topologySnapshot(
        for binding: RuntimeResumeDescriptorBinding
    ) throws -> RuntimeResumeTmuxTopologySnapshot? {
        snapshotsByBinding[binding]
    }
}

private final class StubRuntimeResumeTmuxSessionReader:
    RuntimeResumeTmuxSessionReading,
    @unchecked Sendable {
    let statesBySessionID:
        [String: RuntimeResumeTmuxSessionState]

    init(
        statesBySessionID:
            [String: RuntimeResumeTmuxSessionState]
    ) {
        self.statesBySessionID = statesBySessionID
    }

    func runtimeResumeSessionState(
        for route: OrdinaryTmuxPanelRoute
    ) throws -> RuntimeResumeTmuxSessionState? {
        statesBySessionID[route.sessionID]
    }
}

private struct StubRuntimeResumeCarrierPlanner:
    RuntimeResumeTmuxCarrierPlanning,
    Sendable {
    let plans: [RuntimeResumeTmuxCarrierPublicationPlan]

    func publicationPlans(
        for records: [RuntimeResumeAgentRegistryRecord]
    ) throws -> [RuntimeResumeTmuxCarrierPublicationPlan] {
        plans
    }
}

private final class ReconcilingRuntimeResumeSocket:
    RuntimeResumeDescriptorSocketSending,
    RuntimeResumeDescriptorInventoryReconciling,
    @unchecked Sendable {
    private let lock = NSLock()
    private var storedBySlot:
        [RuntimeResumeDescriptorSlot: RuntimeResumeStoredDescriptor]
    private var storedEvents = [String]()
    private var failNextUpdate: Bool

    init(
        descriptors: [RuntimeResumeStoredDescriptor],
        failNextUpdate: Bool = false
    ) {
        storedBySlot = Dictionary(
            uniqueKeysWithValues: descriptors.map { ($0.slot, $0) }
        )
        self.failNextUpdate = failNextUpdate
    }

    var events: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storedEvents
    }

    var descriptors: [RuntimeResumeStoredDescriptor] {
        lock.lock()
        defer { lock.unlock() }
        return storedBySlot.values.sorted {
            ($0.slot.workspaceID, $0.slot.panelID) <
                ($1.slot.workspaceID, $1.slot.panelID)
        }
    }

    func send(
        _ update: RuntimeResumeDescriptorSocketUpdate
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        storedEvents.append("update:\(update.binding.panelID)")
        if failNextUpdate {
            failNextUpdate = false
            throw BridgeInternalError.invalidResponse
        }
        let slot = RuntimeResumeDescriptorSlot(
            binding: update.binding
        )
        let revision =
            (storedBySlot[slot]?.revision ?? 0) + 1
        storedBySlot[slot] = RuntimeResumeStoredDescriptor(
            slot: slot,
            revision: revision,
            content: update.content
        )
    }

    func currentAgentDescriptors()
        throws -> [RuntimeResumeStoredDescriptor] {
        lock.lock()
        defer { lock.unlock() }
        storedEvents.append("list")
        return storedBySlot.values.sorted {
            ($0.slot.workspaceID, $0.slot.panelID) <
                ($1.slot.workspaceID, $1.slot.panelID)
        }
    }

    func remove(
        _ removal: RuntimeResumeDescriptorSocketRemoval
    ) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        storedEvents.append("remove:\(removal.slot.panelID)")
        guard let stored = storedBySlot[removal.slot] else {
            return false
        }
        guard stored.revision == removal.expectedRevision,
              stored.content == removal.expectedContent else {
            throw BridgeInternalError.invalidResponse
        }
        storedBySlot[removal.slot] = nil
        return true
    }
}

private final class RecordingRuntimeResumeSocketSender:
    RuntimeResumeDescriptorSocketSending,
    @unchecked Sendable {
    private let lock = NSLock()
    private var storedUpdates =
        [RuntimeResumeDescriptorSocketUpdate]()

    var updates: [RuntimeResumeDescriptorSocketUpdate] {
        lock.lock()
        defer { lock.unlock() }
        return storedUpdates
    }

    func send(
        _ update: RuntimeResumeDescriptorSocketUpdate
    ) throws {
        lock.lock()
        storedUpdates.append(update)
        lock.unlock()
    }
}

private final class StubRuntimeResumeInventoryReconciler:
    RuntimeResumeDescriptorInventoryReconciling,
    @unchecked Sendable {
    private let descriptors: [RuntimeResumeStoredDescriptor]

    init(descriptors: [RuntimeResumeStoredDescriptor]) {
        self.descriptors = descriptors
    }

    func currentAgentDescriptors()
        throws -> [RuntimeResumeStoredDescriptor] {
        descriptors
    }

    func remove(
        _ removal: RuntimeResumeDescriptorSocketRemoval
    ) throws -> Bool {
        false
    }
}

private final class RecordingTideyRequestSender:
    TideyRequestSending {
    private(set) var requests = [BridgeRequest]()
    private var responses: [BridgeResponse]

    init(responses: [BridgeResponse] = []) {
        self.responses = responses
    }

    func send(_ request: BridgeRequest)
        throws -> BridgeResponse {
        requests.append(request)
        if responses.isEmpty == false {
            return responses.removeFirst()
        }
        return BridgeResponse(
            id: request.id,
            ok: true,
            result: [:],
            error: nil
        )
    }
}
