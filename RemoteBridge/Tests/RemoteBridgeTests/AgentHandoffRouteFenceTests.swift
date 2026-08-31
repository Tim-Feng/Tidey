import XCTest
@testable import RemoteBridge

final class AgentHandoffRouteFenceTests: XCTestCase {
    func testRouteCaptureRefreshesLivePaneIdentityBeforeTheMonitorTimerFires() throws {
        let fileManager = FileManager.default
        let supportDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("tidey-handoff-route-refresh-\(UUID().uuidString)", isDirectory: true)
        let paths = BridgePaths(supportDirectory: supportDirectory)
        try paths.ensureSupportDirectoriesExist(fileManager: fileManager)
        defer { try? fileManager.removeItem(at: supportDirectory) }

        func writeRecord(sessionID: String, paneID: String, createdAt: String) throws {
            let record = AgentSessionRegistryRecord(version: 1,
                                                    vendor: "codex",
                                                    workspaceID: "stale-workspace",
                                                    sessionID: sessionID,
                                                    panelID: "stale-panel",
                                                    pid: getpid(),
                                                    cwd: "/tmp",
                                                    createdAt: createdAt,
                                                    transcriptPath: nil,
                                                    tmuxPaneID: paneID,
                                                    tmuxSocketPath: "/tmp/tidey-handoff-route-refresh.sock")
            let url = paths.codexAgentSessionsDirectory
                .appendingPathComponent("codex-\(sessionID).json")
            try JSONEncoder().encode(record).write(to: url, options: [.atomic])
        }

        try writeRecord(sessionID: "session-A", paneID: "%1", createdAt: "2026-08-31T00:00:00Z")
        try writeRecord(sessionID: "session-B", paneID: "%2", createdAt: "2026-08-31T00:01:00Z")

        let paneSnapshot = MutablePaneSnapshot("""
        %1|workspace-1|panel-1
        %2|workspace-1|panel-staging
        """)
        let monitor = AgentSessionRegistryMonitor(
            paths: paths,
            fileManager: fileManager,
            hub: AgentEventHub(),
            tmuxResolver: TmuxStateResolver(ttl: 60) { _, _ in paneSnapshot.value },
            parentPIDLookup: { _ in nil }
        )
        try monitor.start()
        let resolver: ActiveAgentSessionResolving = monitor
        let originalRoute = try XCTUnwrap(
            resolver.activeRouteForPanel(workspaceID: "workspace-1", panelID: "panel-1")
        )
        XCTAssertEqual(originalRoute.session.sessionID, "session-A")

        paneSnapshot.value = """
        %1|workspace-1|panel-rollback
        %2|workspace-1|panel-1
        """

        XCTAssertFalse(resolver.isRouteCurrent(originalRoute.token),
                       "an in-flight submit to A must fail closed as soon as pane identity commits to B")
        XCTAssertEqual(resolver.activeRouteForPanel(workspaceID: "workspace-1", panelID: "panel-1")?.session.sessionID,
                       "session-B",
                       "a submit must see the committed pane identity without waiting for the monitor timer")
    }

    func testRouteTokenBecomesStaleWhenStablePanelMovesToReplacementSession() throws {
        let resolver = MutableHandoffSessionResolver(
            session: ActiveAgentSessionSnapshot(vendor: "codex",
                                                workspaceID: "workspace-1",
                                                sessionID: "session-A",
                                                panelID: "panel-1")
        )

        let route = try XCTUnwrap(
            resolver.activeRouteForPanel(workspaceID: "workspace-1", panelID: "panel-1")
        )
        XCTAssertTrue(resolver.isRouteCurrent(route.token))

        resolver.session = ActiveAgentSessionSnapshot(vendor: "codex",
                                                       workspaceID: "workspace-1",
                                                       sessionID: "session-B",
                                                       panelID: "panel-1")

        XCTAssertFalse(resolver.isRouteCurrent(route.token))
    }
}

private final class MutablePaneSnapshot: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: String

    init(_ value: String) {
        storage = value
    }

    var value: String {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
        set {
            lock.lock()
            storage = newValue
            lock.unlock()
        }
    }
}

private final class MutableHandoffSessionResolver: ActiveAgentSessionResolving {
    var session: ActiveAgentSessionSnapshot?

    init(session: ActiveAgentSessionSnapshot?) {
        self.session = session
    }

    func activeSessionForPanel(workspaceID: String, panelID: String) -> ActiveAgentSessionSnapshot? {
        session
    }

    func activeRecord(sessionID: String) -> AgentSessionRegistryRecord? {
        nil
    }
}
