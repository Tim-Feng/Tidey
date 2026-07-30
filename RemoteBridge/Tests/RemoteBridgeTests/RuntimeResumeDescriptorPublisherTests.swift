import Foundation
import XCTest
@testable import RemoteBridge

final class RuntimeResumeDescriptorPublisherTests: XCTestCase {
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
