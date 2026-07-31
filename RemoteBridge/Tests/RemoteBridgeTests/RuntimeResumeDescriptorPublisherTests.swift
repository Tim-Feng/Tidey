import Darwin
import Foundation
import XCTest
@testable import RemoteBridge

final class RuntimeResumeDescriptorPublisherTests: XCTestCase {
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

    func testRegistryReaderUsesOnlyPersistedExactBinding()
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
            workspaceID: "workspace-1",
            sessionID: "wrapper-session",
            panelID: "panel-1",
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

        XCTAssertEqual(
            try reader.readAgentRegistryRecords(),
            [
                RuntimeResumeAgentRegistryRecord(
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
            ]
        )

        monitor.replaceLivePanels(
            workspaceID: "workspace-1",
            panels: [
                AgentPanelProcessSnapshot(
                    workspaceID: "workspace-1",
                    panelID: "ancestry-corrected-panel",
                    effectiveShellPID: getpid(),
                    tmuxPaneID: "%7",
                    tmuxSocketPath:
                        "/tmp/tmux-501/tidey-agents"
                )
            ]
        )
        XCTAssertTrue(
            try reader.readAgentRegistryRecords().isEmpty
        )
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
        XCTAssertTrue(
            try reader.readAgentRegistryRecords().isEmpty
        )
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
        cwd: String?
    ) -> OrdinaryTmuxPanelRoute {
        OrdinaryTmuxPanelRoute(
            workspaceID: "workspace-1",
            panelID: panelID,
            carrierPanelID: "carrier-1",
            socket: .name("tidey-agents"),
            sessionID: "$1",
            sessionName: "work",
            windowID: windowID,
            windowIndex: windowIndex,
            activePaneID: paneID,
            cwd: cwd,
            currentCommand: "zsh"
        )
    }
}

private final class StubRuntimeResumeRegistryReader:
    RuntimeResumeAgentRegistryReading,
    @unchecked Sendable {
    let records: [RuntimeResumeAgentRegistryRecord]

    init(records: [RuntimeResumeAgentRegistryRecord]) {
        self.records = records
    }

    func readAgentRegistryRecords()
        throws -> [RuntimeResumeAgentRegistryRecord] {
        records
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

private final class RecordingTideyRequestSender:
    TideyRequestSending {
    private(set) var requests = [BridgeRequest]()

    func send(_ request: BridgeRequest)
        throws -> BridgeResponse {
        requests.append(request)
        return BridgeResponse(
            id: request.id,
            ok: true,
            result: [:],
            error: nil
        )
    }
}
