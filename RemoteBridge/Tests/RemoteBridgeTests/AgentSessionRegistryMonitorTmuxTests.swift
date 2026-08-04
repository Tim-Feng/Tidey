import XCTest
@testable import RemoteBridge

final class AgentSessionRegistryMonitorTmuxTests: XCTestCase {
    private final class CommandLog: @unchecked Sendable {
        private let lock = NSLock()
        private var calls = [[String]]()

        func append(_ arguments: [String]) {
            lock.lock()
            calls.append(arguments)
            lock.unlock()
        }

        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return calls.count
        }
    }

    private final class TestClock: @unchecked Sendable {
        private let lock = NSLock()
        private var date: Date

        init(_ date: Date) {
            self.date = date
        }

        func now() -> Date {
            lock.lock()
            defer { lock.unlock() }
            return date
        }

        func advance(_ interval: TimeInterval) {
            lock.lock()
            date = date.addingTimeInterval(interval)
            lock.unlock()
        }
    }

    func testScanCorrectsStaleRegistryRecordFromTmuxPaneIdentity() throws {
        let fileManager = FileManager.default
        let supportDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("tidey-remote-bridge-monitor-\(UUID().uuidString)", isDirectory: true)
        let paths = BridgePaths(supportDirectory: supportDirectory)
        try paths.ensureSupportDirectoriesExist(fileManager: fileManager)
        defer { try? fileManager.removeItem(at: supportDirectory) }

        let registryURL = paths.codexAgentSessionsDirectory.appendingPathComponent("codex-session-stale-env.json")
        let recordData = Data("""
        {
          "version": 1,
          "vendor": "codex",
          "workspace_id": "stale-workspace",
          "session_id": "session-stale-env",
          "panel_id": "stale-panel",
          "pid": \(getpid()),
          "cwd": "/tmp",
          "created_at": "2026-05-21T00:00:00Z",
          "tmux_pane_id": "%6",
          "tmux_socket_path": "/tmp/tmux.sock"
        }
        """.utf8)
        try recordData.write(to: registryURL)

        let tmuxResolver = TmuxStateResolver(ttl: 60) { socketPath, arguments in
            XCTAssertEqual(socketPath, "/tmp/tmux.sock")
            XCTAssertEqual(arguments, ["list-panes", "-a", "-F", "#{pane_id}|#{@tidey_workspace_id}|#{@tidey_panel_id}"])
            return "%6|current-workspace|current-panel\n"
        }
        let monitor = AgentSessionRegistryMonitor(paths: paths,
                                                  fileManager: fileManager,
                                                  hub: AgentEventHub(),
                                                  tmuxResolver: tmuxResolver,
                                                  parentPIDLookup: { _ in nil })
        try monitor.start()

        let snapshots = monitor.activeSessionSnapshots()
        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(snapshots.first?.workspaceID, "current-workspace")
        XCTAssertEqual(snapshots.first?.panelID, "current-panel")
        XCTAssertEqual(monitor.activeSessionForWorkspace(workspaceID: "stale-workspace")?.sessionID, nil)
        XCTAssertEqual(monitor.activeSessionForWorkspace(workspaceID: "current-workspace")?.sessionID, "session-stale-env")

        XCTAssertEqual(try Data(contentsOf: registryURL), recordData)
    }

    func testScanDoesNotOverwriteRegistryRecordAdvancedWhileResolvingPaneIdentity() throws {
        let fileManager = FileManager.default
        let supportDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("tidey-remote-bridge-monitor-\(UUID().uuidString)", isDirectory: true)
        let paths = BridgePaths(supportDirectory: supportDirectory)
        try paths.ensureSupportDirectoriesExist(fileManager: fileManager)
        defer { try? fileManager.removeItem(at: supportDirectory) }

        let registryURL = paths.codexAgentSessionsDirectory
            .appendingPathComponent("codex-concurrent-runtime-advance.json")
        let sessionID = "019f7731-32ee-7f61-b700-2df0ae55b09e"
        let startingRecord = AgentSessionRegistryRecord(version: 1,
                                                        vendor: "codex",
                                                        workspaceID: "stale-workspace",
                                                        sessionID: sessionID,
                                                        panelID: "stale-panel",
                                                        pid: getpid(),
                                                        cwd: "/tmp",
                                                        createdAt: "2026-07-22T07:30:00Z",
                                                        transcriptPath: nil,
                                                        tmuxPaneID: "%31",
                                                        tmuxSocketPath: "/tmp/tmux-501/default",
                                                        runtime: "codex_app_server_starting",
                                                        appServerSocket: "/tmp/app.sock",
                                                        appServerPID: getpid(),
                                                        threadID: sessionID,
                                                        resumeThreadID: sessionID)
        try JSONEncoder().encode(startingRecord).write(to: registryURL, options: [.atomic])

        let advancedRecord = AgentSessionRegistryRecord(version: 1,
                                                        vendor: "codex",
                                                        workspaceID: "writer-workspace",
                                                        sessionID: sessionID,
                                                        panelID: "writer-panel",
                                                        pid: getpid(),
                                                        cwd: "/tmp",
                                                        createdAt: "2026-07-22T07:30:00Z",
                                                        transcriptPath: nil,
                                                        tmuxPaneID: "%31",
                                                        tmuxSocketPath: "/tmp/tmux-501/default",
                                                        runtime: "codex_app_server",
                                                        appServerSocket: "/tmp/app.sock",
                                                        appServerPID: getpid(),
                                                        remoteTUIPID: getpid(),
                                                        threadID: sessionID,
                                                        resumeThreadID: sessionID)
        let advancedData = try JSONEncoder().encode(advancedRecord)

        let monitor = AgentSessionRegistryMonitor(paths: paths,
                                                  fileManager: fileManager,
                                                  hub: AgentEventHub(),
                                                  tmuxResolver: TmuxStateResolver(ttl: 60) { _, _ in "" },
                                                  parentPIDLookup: { _ in nil },
                                                  ordinaryTmuxCarrierIdentityResolver: { _ in
                                                      do {
                                                          try advancedData.write(to: registryURL, options: [.atomic])
                                                      } catch {
                                                          XCTFail("Failed to advance registry fixture: \(error)")
                                                      }
                                                      return TideyOrdinaryTmuxCarrierIdentity(
                                                          workspaceID: "current-workspace",
                                                          panelID: "current-panel",
                                                          socketPath: "/tmp/tmux-501/default",
                                                          targetSession: "storage")
                                                  })
        try monitor.start()

        let snapshot = try XCTUnwrap(monitor.activeSessionSnapshots().first)
        XCTAssertEqual(snapshot.workspaceID, "current-workspace")
        XCTAssertEqual(snapshot.panelID, "current-panel")
        XCTAssertEqual(try Data(contentsOf: registryURL), advancedData)

        let persisted = try JSONDecoder().decode(AgentSessionRegistryRecord.self,
                                                 from: Data(contentsOf: registryURL))
        XCTAssertEqual(persisted.runtime, "codex_app_server")
        XCTAssertEqual(persisted.remoteTUIPID, getpid())
    }

    func testScanDoesNotResurrectRegistryRecordDeletedWhileResolvingPaneIdentity() throws {
        let fileManager = FileManager.default
        let supportDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("tidey-remote-bridge-monitor-\(UUID().uuidString)", isDirectory: true)
        let paths = BridgePaths(supportDirectory: supportDirectory)
        try paths.ensureSupportDirectoriesExist(fileManager: fileManager)
        defer { try? fileManager.removeItem(at: supportDirectory) }

        let registryURL = paths.codexAgentSessionsDirectory
            .appendingPathComponent("codex-concurrent-runtime-delete.json")
        let sessionID = "019f840d-e291-7d83-99df-bffaabe66df7"
        let startingRecord = AgentSessionRegistryRecord(version: 1,
                                                        vendor: "codex",
                                                        workspaceID: "stale-workspace",
                                                        sessionID: sessionID,
                                                        panelID: "stale-panel",
                                                        pid: getpid(),
                                                        cwd: "/tmp",
                                                        createdAt: "2026-07-22T07:31:00Z",
                                                        transcriptPath: nil,
                                                        tmuxPaneID: "%32",
                                                        tmuxSocketPath: "/tmp/tmux-501/default",
                                                        runtime: "codex_app_server_starting",
                                                        appServerSocket: "/tmp/app.sock",
                                                        appServerPID: getpid(),
                                                        threadID: sessionID,
                                                        resumeThreadID: sessionID)
        try JSONEncoder().encode(startingRecord).write(to: registryURL, options: [.atomic])

        let monitor = AgentSessionRegistryMonitor(paths: paths,
                                                  fileManager: fileManager,
                                                  hub: AgentEventHub(),
                                                  tmuxResolver: TmuxStateResolver(ttl: 60) { _, _ in "" },
                                                  parentPIDLookup: { _ in nil },
                                                  ordinaryTmuxCarrierIdentityResolver: { _ in
                                                      do {
                                                          try fileManager.removeItem(at: registryURL)
                                                      } catch {
                                                          XCTFail("Failed to delete registry fixture: \(error)")
                                                      }
                                                      return TideyOrdinaryTmuxCarrierIdentity(
                                                          workspaceID: "current-workspace",
                                                          panelID: "current-panel",
                                                          socketPath: "/tmp/tmux-501/default",
                                                          targetSession: "video-process-codex")
                                                  })
        try monitor.start()

        let snapshot = try XCTUnwrap(monitor.activeSessionSnapshots().first)
        XCTAssertEqual(snapshot.workspaceID, "current-workspace")
        XCTAssertEqual(snapshot.panelID, "current-panel")
        XCTAssertFalse(fileManager.fileExists(atPath: registryURL.path))
    }

    func testScanCorrectsStaleRegistryRecordFromLivePaneSnapshotWithoutSocketPath() throws {
        let fileManager = FileManager.default
        let supportDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("tidey-remote-bridge-monitor-\(UUID().uuidString)", isDirectory: true)
        let paths = BridgePaths(supportDirectory: supportDirectory)
        try paths.ensureSupportDirectoriesExist(fileManager: fileManager)
        defer { try? fileManager.removeItem(at: supportDirectory) }

        let registryURL = paths.claudeAgentSessionsDirectory.appendingPathComponent("claude-session-stale-env.json")
        let recordData = Data("""
        {
          "version": 1,
          "vendor": "claude",
          "workspace_id": "stale-workspace",
          "session_id": "session-stale-env",
          "panel_id": "stale-panel",
          "pid": \(getpid()),
          "cwd": "/tmp",
          "created_at": "2026-06-19T10:25:00Z",
          "tmux_pane_id": "%14"
        }
        """.utf8)
        try recordData.write(to: registryURL)

        let monitor = AgentSessionRegistryMonitor(paths: paths,
                                                  fileManager: fileManager,
                                                  hub: AgentEventHub(),
                                                  tmuxResolver: TmuxStateResolver(ttl: 60) { _, _ in
                                                      XCTFail("live panel snapshot should resolve missing tmux_socket_path without shelling out to tmux")
                                                      return ""
                                                  },
                                                  parentPIDLookup: { _ in nil })
        monitor.replaceLivePanels(workspaceID: "current-workspace",
                                  panels: [
                                      AgentPanelProcessSnapshot(workspaceID: "current-workspace",
                                                                panelID: "current-panel",
                                                                effectiveShellPID: nil,
                                                                tmuxPaneID: "%14",
                                                                tmuxSocketPath: "/private/tmp/tmux-501/default"),
                                  ])
        try monitor.start()

        let session = monitor.activeSessionForPanel(workspaceID: "current-workspace",
                                                    panelID: "current-panel",
                                                    effectiveShellPID: nil,
                                                    tmuxPaneID: "%14",
                                                    tmuxSocketPath: "/tmp/tmux-501/default")
        XCTAssertEqual(session?.sessionID, "session-stale-env")
        XCTAssertNil(monitor.activeSessionForPanel(workspaceID: "stale-workspace",
                                                   panelID: "stale-panel"))

        XCTAssertEqual(try Data(contentsOf: registryURL), recordData)
    }

    func testScanReconcilesClaudeWithoutPaneIDFromUniqueLivePanelProcessAncestry() throws {
        let fileManager = FileManager.default
        let supportDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("tidey-remote-bridge-monitor-\(UUID().uuidString)", isDirectory: true)
        let paths = BridgePaths(supportDirectory: supportDirectory)
        try paths.ensureSupportDirectoriesExist(fileManager: fileManager)
        defer { try? fileManager.removeItem(at: supportDirectory) }

        let registryURL = paths.claudeAgentSessionsDirectory
            .appendingPathComponent("claude-session-without-pane-id.json")
        let recordData = Data("""
        {
          "version": 1,
          "vendor": "claude",
          "workspace_id": "stale-workspace",
          "session_id": "session-without-pane-id",
          "panel_id": "stale-panel",
          "pid": \(getpid()),
          "cwd": "/tmp",
          "created_at": "2026-07-22T07:40:00Z"
        }
        """.utf8)
        try recordData.write(to: registryURL)

        let effectiveShellPID: Int32 = 12_345
        var requestedActions = [String]()
        let runtimeSyncer = CapturingRuntimeSyncer()
        let monitor = AgentSessionRegistryMonitor(
            paths: paths,
            fileManager: fileManager,
            hub: AgentEventHub(),
            tmuxResolver: TmuxStateResolver(ttl: 60) { _, _ in
                XCTFail("Claude registry without tmux_pane_id must reconcile from process ancestry")
                return ""
            },
            parentPIDLookup: { pid in
                pid == getpid() ? effectiveShellPID : nil
            },
            livePanelSnapshotRequestSender: { request in
                requestedActions.append(request.action)
                if request.action == "list_workspaces" {
                    return BridgeResponse(id: request.id,
                                          ok: true,
                                          result: [
                                            "workspaces": .array([
                                                .object([
                                                    "workspace_id": .string("current-workspace"),
                                                ]),
                                            ]),
                                          ],
                                          error: nil)
                }
                if request.action == "list_panels" {
                    XCTAssertEqual(request.params?["workspace_id"]?.stringValue,
                                   "current-workspace")
                    return BridgeResponse(id: request.id,
                                          ok: true,
                                          result: [
                                            "workspace_id": .string("current-workspace"),
                                            "panels": .array([
                                                .object([
                                                    "workspace_id": .string("current-workspace"),
                                                    "panel_id": .string("current-panel"),
                                                    "effective_shell_pid": .number(Double(effectiveShellPID)),
                                                ]),
                                            ]),
                                          ],
                                          error: nil)
                }
                XCTFail("Unexpected Tidey socket action: \(request.action)")
                return BridgeResponse(id: request.id, ok: false, result: nil, error: nil)
            },
            runtimeSyncer: runtimeSyncer)
        try monitor.start()

        XCTAssertEqual(requestedActions, ["list_workspaces", "list_panels"])
        let snapshot = try XCTUnwrap(monitor.activeSessionSnapshots().first)
        XCTAssertEqual(snapshot.workspaceID, "current-workspace")
        XCTAssertEqual(snapshot.panelID, "current-panel")
        let syncedRecord = try XCTUnwrap(runtimeSyncer.latestRecords.first)
        XCTAssertEqual(syncedRecord.workspaceID, "current-workspace")
        XCTAssertEqual(syncedRecord.panelID, "current-panel")
        XCTAssertEqual(try Data(contentsOf: registryURL), recordData)
    }

    func testScanReconcilesNativeCodexAppServerPollutedByInheritedTmuxIdentity() throws {
        let fileManager = FileManager.default
        let supportDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("tidey-remote-bridge-monitor-\(UUID().uuidString)", isDirectory: true)
        let paths = BridgePaths(supportDirectory: supportDirectory)
        try paths.ensureSupportDirectoriesExist(fileManager: fileManager)
        defer { try? fileManager.removeItem(at: supportDirectory) }

        let registryURL = paths.codexAgentSessionsDirectory
            .appendingPathComponent("codex-app-server-inherited-tmux.json")
        let recordData = Data("""
        {
          "version": 1,
          "vendor": "codex",
          "workspace_id": "stale-tmux-workspace",
          "session_id": "app-server-inherited-tmux",
          "panel_id": "stale-tmux-panel",
          "pid": \(getpid()),
          "cwd": "/tmp",
          "created_at": "2026-08-05T02:00:00Z",
          "tmux_pane_id": "%7",
          "tmux_socket_path": "/private/tmp/tmux-501/default",
          "runtime": "codex_app_server",
          "app_server_socket": "/tmp/app.sock",
          "app_server_pid": \(getpid()),
          "thread_id": "019fc672-7536-7782-bd19-0ede7e023706",
          "resume_thread_id": "019fc672-7536-7782-bd19-0ede7e023706"
        }
        """.utf8)
        try recordData.write(to: registryURL)

        let directPanelShellPID: Int32 = 41_005
        var requestedActions = [String]()
        let runtimeSyncer = CapturingRuntimeSyncer()
        let monitor = AgentSessionRegistryMonitor(
            paths: paths,
            fileManager: fileManager,
            hub: AgentEventHub(),
            tmuxResolver: TmuxStateResolver(ttl: 60) { socketPath, arguments in
                XCTAssertEqual(socketPath, "/tmp/tmux-501/default")
                XCTAssertEqual(arguments,
                               ["list-panes", "-a", "-F",
                                "#{pane_id}|#{@tidey_workspace_id}|#{@tidey_panel_id}"])
                return "%7|stale-tmux-workspace|stale-tmux-panel\n"
            },
            parentPIDLookup: { pid in
                pid == getpid() ? directPanelShellPID : nil
            },
            livePanelSnapshotRequestSender: { request in
                requestedActions.append(request.action)
                if request.action == "list_workspaces" {
                    return BridgeResponse(id: request.id,
                                          ok: true,
                                          result: [
                                            "workspaces": .array([
                                                .object(["workspace_id": .string("stale-tmux-workspace")]),
                                                .object(["workspace_id": .string("direct-workspace")]),
                                            ]),
                                          ],
                                          error: nil)
                }
                if request.action == "list_panels" {
                    switch request.params?["workspace_id"]?.stringValue {
                    case "stale-tmux-workspace":
                        return BridgeResponse(id: request.id,
                                              ok: true,
                                              result: [
                                                "workspace_id": .string("stale-tmux-workspace"),
                                                "panels": .array([
                                                    .object([
                                                        "workspace_id": .string("stale-tmux-workspace"),
                                                        "panel_id": .string("stale-tmux-panel"),
                                                        "effective_shell_pid": .number(51_007),
                                                        "tmux_pane_id": .string("%7"),
                                                        "tmux_socket_path": .string("/private/tmp/tmux-501/default"),
                                                    ]),
                                                ]),
                                              ],
                                              error: nil)
                    case "direct-workspace":
                        return BridgeResponse(id: request.id,
                                              ok: true,
                                              result: [
                                                "workspace_id": .string("direct-workspace"),
                                                "panels": .array([
                                                    .object([
                                                        "workspace_id": .string("direct-workspace"),
                                                        "panel_id": .string("direct-panel"),
                                                        "effective_shell_pid": .number(Double(directPanelShellPID)),
                                                    ]),
                                                ]),
                                              ],
                                              error: nil)
                    default:
                        XCTFail("Unexpected workspace snapshot request")
                    }
                }
                return BridgeResponse(id: request.id, ok: false, result: nil, error: nil)
            },
            runtimeSyncer: runtimeSyncer)
        monitor.replaceLivePanels(workspaceID: "stale-tmux-workspace",
                                  panels: [
                                    AgentPanelProcessSnapshot(workspaceID: "stale-tmux-workspace",
                                                              panelID: "stale-tmux-panel",
                                                              effectiveShellPID: 51_007,
                                                              tmuxPaneID: "%7",
                                                              tmuxSocketPath: "/private/tmp/tmux-501/default"),
                                  ])
        try monitor.start()

        XCTAssertEqual(requestedActions,
                       ["list_workspaces", "list_panels", "list_panels"],
                       "Codex app-server records need a fresh graph even when stale tmux identity matches the cache")
        XCTAssertNil(monitor.activeSessionForPanel(workspaceID: "stale-tmux-workspace",
                                                   panelID: "stale-tmux-panel"))
        XCTAssertEqual(monitor.activeSessionForPanel(workspaceID: "direct-workspace",
                                                     panelID: "direct-panel")?.sessionID,
                       "app-server-inherited-tmux")

        let syncedRecord = try XCTUnwrap(runtimeSyncer.latestRecords.first)
        XCTAssertEqual(syncedRecord.workspaceID, "direct-workspace")
        XCTAssertEqual(syncedRecord.panelID, "direct-panel")
        XCTAssertNil(syncedRecord.tmuxPaneID)
        XCTAssertNil(syncedRecord.tmuxSocketPath)
        XCTAssertEqual(try Data(contentsOf: registryURL), recordData)
    }

    func testScanRefreshesPanellessClaudeProcessAncestryAfterCachedPanelMoves() throws {
        let fileManager = FileManager.default
        let supportDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("tidey-remote-bridge-monitor-\(UUID().uuidString)", isDirectory: true)
        let paths = BridgePaths(supportDirectory: supportDirectory)
        try paths.ensureSupportDirectoriesExist(fileManager: fileManager)
        defer { try? fileManager.removeItem(at: supportDirectory) }

        let registryURL = paths.claudeAgentSessionsDirectory
            .appendingPathComponent("claude-session-moving-without-pane-id.json")
        let recordData = Data("""
        {
          "version": 1,
          "vendor": "claude",
          "workspace_id": "stale-workspace",
          "session_id": "session-moving-without-pane-id",
          "panel_id": "stale-panel",
          "pid": \(getpid()),
          "cwd": "/tmp",
          "created_at": "2026-07-22T08:30:00Z"
        }
        """.utf8)
        try recordData.write(to: registryURL)

        let effectiveShellPID: Int32 = 32_100
        let clock = TestClock(Date(timeIntervalSince1970: 100))
        var panelLocation = (workspaceID: "first-workspace", panelID: "first-panel")
        var requestedActions = [String]()
        let runtimeSyncer = CapturingRuntimeSyncer()
        let monitor = AgentSessionRegistryMonitor(
            paths: paths,
            fileManager: fileManager,
            hub: AgentEventHub(),
            tmuxResolver: TmuxStateResolver(ttl: 60) { _, _ in "" },
            parentPIDLookup: { pid in
                pid == getpid() ? effectiveShellPID : nil
            },
            livePanelSnapshotRequestSender: { request in
                requestedActions.append(request.action)
                if request.action == "list_workspaces" {
                    return BridgeResponse(id: request.id,
                                          ok: true,
                                          result: [
                                            "workspaces": .array([
                                                .object([
                                                    "workspace_id": .string(panelLocation.workspaceID),
                                                ]),
                                            ]),
                                          ],
                                          error: nil)
                }
                if request.action == "list_panels" {
                    XCTAssertEqual(request.params?["workspace_id"]?.stringValue,
                                   panelLocation.workspaceID)
                    return BridgeResponse(id: request.id,
                                          ok: true,
                                          result: [
                                            "workspace_id": .string(panelLocation.workspaceID),
                                            "panels": .array([
                                                .object([
                                                    "workspace_id": .string(panelLocation.workspaceID),
                                                    "panel_id": .string(panelLocation.panelID),
                                                    "effective_shell_pid": .number(Double(effectiveShellPID)),
                                                ]),
                                            ]),
                                          ],
                                          error: nil)
                }
                XCTFail("Unexpected Tidey socket action: \(request.action)")
                return BridgeResponse(id: request.id, ok: false, result: nil, error: nil)
            },
            livePanelSnapshotRefreshInterval: 5,
            now: { clock.now() },
            runtimeSyncer: runtimeSyncer)
        try monitor.start()

        XCTAssertEqual(requestedActions, ["list_workspaces", "list_panels"])
        XCTAssertEqual(monitor.activeSessionSnapshots().first?.workspaceID, "first-workspace")
        XCTAssertEqual(monitor.activeSessionSnapshots().first?.panelID, "first-panel")
        XCTAssertEqual(runtimeSyncer.latestRecords.first?.workspaceID, "first-workspace")
        XCTAssertEqual(runtimeSyncer.latestRecords.first?.panelID, "first-panel")

        panelLocation = (workspaceID: "second-workspace", panelID: "second-panel")
        clock.advance(4)
        monitor.scanRegistryForTesting()

        XCTAssertEqual(requestedActions, ["list_workspaces", "list_panels"],
                       "the existing five-second refresh throttle must still apply")
        XCTAssertEqual(monitor.activeSessionSnapshots().first?.workspaceID, "first-workspace")
        XCTAssertEqual(monitor.activeSessionSnapshots().first?.panelID, "first-panel")

        clock.advance(2)
        monitor.scanRegistryForTesting()

        XCTAssertEqual(requestedActions,
                       ["list_workspaces", "list_panels", "list_workspaces", "list_panels"])
        XCTAssertEqual(monitor.activeSessionSnapshots().first?.workspaceID, "second-workspace")
        XCTAssertEqual(monitor.activeSessionSnapshots().first?.panelID, "second-panel")
        XCTAssertEqual(runtimeSyncer.latestRecords.first?.workspaceID, "second-workspace")
        XCTAssertEqual(runtimeSyncer.latestRecords.first?.panelID, "second-panel")
        XCTAssertEqual(try Data(contentsOf: registryURL), recordData)
    }

    func testScanProjectsOrdinaryTmuxCarrierBeforeReconcilingClaudeWithoutPaneID() throws {
        let fileManager = FileManager.default
        let supportDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("tidey-remote-bridge-monitor-\(UUID().uuidString)", isDirectory: true)
        let paths = BridgePaths(supportDirectory: supportDirectory)
        try paths.ensureSupportDirectoriesExist(fileManager: fileManager)
        defer { try? fileManager.removeItem(at: supportDirectory) }

        let registryURL = paths.claudeAgentSessionsDirectory
            .appendingPathComponent("claude-video-process-without-pane-id.json")
        let recordData = Data("""
        {
          "version": 1,
          "vendor": "claude",
          "workspace_id": "stale-workspace",
          "session_id": "video-process-claude-session",
          "panel_id": "stale-panel",
          "pid": \(getpid()),
          "cwd": "/tmp",
          "created_at": "2026-07-22T08:00:00Z"
        }
        """.utf8)
        try recordData.write(to: registryURL)

        let outerCarrierShellPID: Int32 = 41_808
        let innerTmuxPaneShellPID: Int32 = 1_764
        let projector = OrdinaryTmuxPanelProjector(
            adapter: RegistryMonitorOrdinaryTmuxProjectionStub(
                expectedTargetSession: "video-process-cc",
                projectedPanels: [
                    OrdinaryTmuxProjectedPanel(
                        panelID: "ordinary-tmux:default:$1:@1",
                        socketPath: "/tmp/tmux-501/default",
                        sessionID: "$1",
                        sessionName: "video-process-cc",
                        windowID: "@1",
                        windowIndex: 0,
                        windowName: "video-process-cc",
                        isCurrentWindow: true,
                        activePaneID: "%30",
                        activePanePID: innerTmuxPaneShellPID,
                        cwd: "/Users/timfeng",
                        currentCommand: "claude",
                        title: "video-process-cc",
                        subtitle: "/Users/timfeng"
                    ),
                ]
            )
        )
        var requestedActions = [String]()
        let runtimeSyncer = CapturingRuntimeSyncer()
        let monitor = AgentSessionRegistryMonitor(
            paths: paths,
            fileManager: fileManager,
            hub: AgentEventHub(),
            tmuxResolver: TmuxStateResolver(ttl: 60) { _, _ in
                XCTFail("Projected ordinary tmux ancestry should not use registry pane lookup")
                return ""
            },
            parentPIDLookup: { pid in
                pid == getpid() ? innerTmuxPaneShellPID : nil
            },
            livePanelSnapshotRequestSender: { request in
                requestedActions.append(request.action)
                if request.action == "list_workspaces" {
                    return BridgeResponse(id: request.id,
                                          ok: true,
                                          result: [
                                            "workspaces": .array([
                                                .object([
                                                    "workspace_id": .string("video-workspace"),
                                                ]),
                                            ]),
                                          ],
                                          error: nil)
                }
                if request.action == "list_panels" {
                    return BridgeResponse(id: request.id,
                                          ok: true,
                                          result: [
                                            "workspace_id": .string("video-workspace"),
                                            "panels": .array([
                                                .object([
                                                    "workspace_id": .string("video-workspace"),
                                                    "panel_id": .string("video-process-cc-panel"),
                                                    "effective_shell_pid": .number(Double(outerCarrierShellPID)),
                                                    "ordinary_tmux": .object([
                                                        "client_tty": .string("/dev/ttys030"),
                                                        "target_session": .string("video-process-cc"),
                                                    ]),
                                                ]),
                                            ]),
                                          ],
                                          error: nil)
                }
                XCTFail("Unexpected Tidey socket action: \(request.action)")
                return BridgeResponse(id: request.id, ok: false, result: nil, error: nil)
            },
            livePanelListProjector: { result in
                projector.projectPanelListResult(result)
            },
            runtimeSyncer: runtimeSyncer
        )
        try monitor.start()

        XCTAssertEqual(requestedActions, ["list_workspaces", "list_panels"])
        let snapshot = try XCTUnwrap(monitor.activeSessionSnapshots().first)
        XCTAssertEqual(snapshot.workspaceID, "video-workspace")
        XCTAssertEqual(snapshot.panelID, "video-process-cc-panel")
        let syncedRecord = try XCTUnwrap(runtimeSyncer.latestRecords.first)
        XCTAssertEqual(syncedRecord.workspaceID, "video-workspace")
        XCTAssertEqual(syncedRecord.panelID, "video-process-cc-panel")
        XCTAssertEqual(try Data(contentsOf: registryURL), recordData)
    }

    func testScanDoesNotReconcileClaudeWithoutPaneIDWhenProcessAncestryMatchesMultiplePanels() throws {
        let fileManager = FileManager.default
        let supportDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("tidey-remote-bridge-monitor-\(UUID().uuidString)", isDirectory: true)
        let paths = BridgePaths(supportDirectory: supportDirectory)
        try paths.ensureSupportDirectoriesExist(fileManager: fileManager)
        defer { try? fileManager.removeItem(at: supportDirectory) }

        let registryURL = paths.claudeAgentSessionsDirectory
            .appendingPathComponent("claude-session-ambiguous-process.json")
        let recordData = Data("""
        {
          "version": 1,
          "vendor": "claude",
          "workspace_id": "stale-workspace",
          "session_id": "session-ambiguous-process",
          "panel_id": "stale-panel",
          "pid": \(getpid()),
          "cwd": "/tmp",
          "created_at": "2026-07-22T07:41:00Z"
        }
        """.utf8)
        try recordData.write(to: registryURL)

        let firstPaneShellPID: Int32 = 12_345
        let secondPaneShellPID: Int32 = 23_456
        let projector = OrdinaryTmuxPanelProjector(
            adapter: RegistryMonitorOrdinaryTmuxProjectionStub(
                expectedTargetSession: "ambiguous-cc",
                projectedPanels: [
                    OrdinaryTmuxProjectedPanel(
                        panelID: "ordinary-tmux:default:$1:@1",
                        socketPath: "/tmp/tmux-501/default",
                        sessionID: "$1",
                        sessionName: "ambiguous-cc",
                        windowID: "@1",
                        windowIndex: 0,
                        windowName: "first",
                        isCurrentWindow: true,
                        activePaneID: "%30",
                        activePanePID: firstPaneShellPID,
                        cwd: "/tmp",
                        currentCommand: "claude",
                        title: "first",
                        subtitle: "/tmp"
                    ),
                    OrdinaryTmuxProjectedPanel(
                        panelID: "ordinary-tmux:default:$1:@2",
                        socketPath: "/tmp/tmux-501/default",
                        sessionID: "$1",
                        sessionName: "ambiguous-cc",
                        windowID: "@2",
                        windowIndex: 1,
                        windowName: "second",
                        isCurrentWindow: false,
                        activePaneID: "%31",
                        activePanePID: secondPaneShellPID,
                        cwd: "/tmp",
                        currentCommand: "claude",
                        title: "second",
                        subtitle: "/tmp"
                    ),
                ]
            )
        )
        let monitor = AgentSessionRegistryMonitor(
            paths: paths,
            fileManager: fileManager,
            hub: AgentEventHub(),
            tmuxResolver: TmuxStateResolver(ttl: 60) { _, _ in "" },
            parentPIDLookup: { pid in
                if pid == getpid() {
                    return firstPaneShellPID
                }
                return pid == firstPaneShellPID ? secondPaneShellPID : nil
            },
            livePanelSnapshotRequestSender: { request in
                if request.action == "list_workspaces" {
                    return BridgeResponse(id: request.id,
                                          ok: true,
                                          result: [
                                            "workspaces": .array([
                                                .object([
                                                    "workspace_id": .string("ambiguous-workspace"),
                                                ]),
                                            ]),
                                          ],
                                          error: nil)
                }
                if request.action == "list_panels" {
                    return BridgeResponse(id: request.id,
                                          ok: true,
                                          result: [
                                            "workspace_id": .string("ambiguous-workspace"),
                                            "panels": .array([
                                                .object([
                                                    "workspace_id": .string("ambiguous-workspace"),
                                                    "panel_id": .string("ambiguous-carrier"),
                                                    "effective_shell_pid": .number(41_808),
                                                    "ordinary_tmux": .object([
                                                        "client_tty": .string("/dev/ttys031"),
                                                        "target_session": .string("ambiguous-cc"),
                                                    ]),
                                                ]),
                                            ]),
                                          ],
                                          error: nil)
                }
                return BridgeResponse(id: request.id, ok: false, result: nil, error: nil)
            },
            livePanelListProjector: { result in
                projector.projectPanelListResult(result)
            })
        try monitor.start()

        let snapshot = try XCTUnwrap(monitor.activeSessionSnapshots().first)
        XCTAssertEqual(snapshot.workspaceID, "stale-workspace")
        XCTAssertEqual(snapshot.panelID, "stale-panel")
        XCTAssertEqual(try Data(contentsOf: registryURL), recordData)
    }

    func testScanCorrectsStaleAppServerRecordFromOrdinaryTmuxCarrierWhenPaneOptionsAreEmpty() throws {
        let fileManager = FileManager.default
        let supportDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("tidey-remote-bridge-monitor-\(UUID().uuidString)", isDirectory: true)
        let paths = BridgePaths(supportDirectory: supportDirectory)
        try paths.ensureSupportDirectoriesExist(fileManager: fileManager)
        defer { try? fileManager.removeItem(at: supportDirectory) }

        let registryURL = paths.codexAgentSessionsDirectory.appendingPathComponent("codex-app-server-stale-carrier.json")
        let recordData = Data("""
        {
          "version": 1,
          "vendor": "codex",
          "workspace_id": "genesis-workspace",
          "session_id": "app-server-session",
          "panel_id": "",
          "pid": \(getpid()),
          "cwd": "/tmp",
          "created_at": "2026-06-30T07:51:00Z",
          "tmux_pane_id": "%13",
          "tmux_socket_path": "/private/tmp/tmux-501/default",
          "runtime": "codex_app_server",
          "app_server_socket": "/tmp/app.sock",
          "app_server_pid": \(getpid()),
          "thread_id": "019ec8cb-6128-7892-8441-8c22d854286c",
          "resume_thread_id": "019ec8cb-6128-7892-8441-8c22d854286c"
        }
        """.utf8)
        try recordData.write(to: registryURL)

        let tmuxResolver = TmuxStateResolver(ttl: 60) { socketPath, arguments in
            XCTAssertEqual(socketPath, "/tmp/tmux-501/default")
            if arguments == ["list-panes", "-a", "-F", "#{pane_id}|#{@tidey_workspace_id}|#{@tidey_panel_id}"] {
                return "%13||\n"
            }
            if arguments == ["list-panes", "-a", "-F", "#{pane_id}|#{session_name}"] {
                return "%13|tidey-codex\n"
            }
            if arguments == ["list-clients", "-F", "#{client_pid}|#{session_name}"] {
                return "123|tidey-codex\n"
            }
            XCTFail("Unexpected tmux arguments: \(arguments)")
            return ""
        }
        let ordinaryTmuxResolver = TideyOrdinaryTmuxCarrierResolver(requestSender: { request in
            if request.action == "list_workspaces" {
                return BridgeResponse(id: request.id,
                                      ok: true,
                                      result: [
                                        "workspaces": .array([
                                            .object([
                                                "workspace_id": .string("genesis-workspace"),
                                                "title": .string("Genesis"),
                                            ]),
                                            .object([
                                                "workspace_id": .string("tidey-workspace"),
                                                "title": .string("Tidey"),
                                                "selected_panel_id": .string("tidey-carrier-panel"),
                                                "ordinary_tmux": .object([
                                                    "target_session": .string("tidey-codex"),
                                                ]),
                                            ]),
                                        ]),
                                      ],
                                      error: nil)
            }
            if request.action == "list_panels" {
                XCTAssertEqual(request.params?["workspace_id"]?.stringValue, "tidey-workspace")
                return BridgeResponse(id: request.id,
                                      ok: true,
                                      result: [
                                        "workspace_id": .string("tidey-workspace"),
                                        "panels": .array([
                                            .object([
                                                "panel_id": .string("tidey-carrier-panel"),
                                                "workspace_id": .string("tidey-workspace"),
                                                "ordinary_tmux": .object([
                                                    "target_session": .string("tidey-codex"),
                                                ]),
                                            ]),
                                        ]),
                                      ],
                                      error: nil)
            }
            XCTFail("Unexpected Tidey socket action: \(request.action)")
            return BridgeResponse(id: request.id, ok: false, result: nil, error: nil)
        }, tmuxResolver: tmuxResolver)
        let runtimeSyncer = CapturingRuntimeSyncer()
        let monitor = AgentSessionRegistryMonitor(paths: paths,
                                                  fileManager: fileManager,
                                                  hub: AgentEventHub(),
                                                  tmuxResolver: tmuxResolver,
                                                  parentPIDLookup: { _ in nil },
                                                  ordinaryTmuxCarrierIdentityResolver: { record in
                                                      ordinaryTmuxResolver.carrierIdentity(for: record)
                                                  },
                                                  runtimeSyncer: runtimeSyncer)
        try monitor.start()

        let snapshots = monitor.activeSessionSnapshots()
        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(snapshots.first?.workspaceID, "tidey-workspace")
        XCTAssertEqual(snapshots.first?.panelID, "tidey-carrier-panel")
        XCTAssertEqual(monitor.activeSessionForWorkspace(workspaceID: "genesis-workspace")?.sessionID, nil)
        XCTAssertEqual(monitor.activeSessionForWorkspace(workspaceID: "tidey-workspace")?.sessionID, "app-server-session")

        XCTAssertEqual(try Data(contentsOf: registryURL), recordData)

        let syncedRecord = try XCTUnwrap(runtimeSyncer.latestRecords.first)
        XCTAssertEqual(syncedRecord.workspaceID, "tidey-workspace")
        XCTAssertEqual(syncedRecord.panelID, "tidey-carrier-panel")
        XCTAssertEqual(syncedRecord.runtime, "codex_app_server")
    }

    func testScanPrefersOrdinaryTmuxCarrierWhenPaneOptionsPointToMissingWorkspace() throws {
        let fileManager = FileManager.default
        let supportDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("tidey-remote-bridge-monitor-\(UUID().uuidString)", isDirectory: true)
        let paths = BridgePaths(supportDirectory: supportDirectory)
        try paths.ensureSupportDirectoriesExist(fileManager: fileManager)
        defer { try? fileManager.removeItem(at: supportDirectory) }

        let registryURL = paths.codexAgentSessionsDirectory.appendingPathComponent("codex-app-server-stale-pane-options.json")
        let recordData = Data("""
        {
          "version": 1,
          "vendor": "codex",
          "workspace_id": "stale-workspace",
          "session_id": "app-server-session",
          "panel_id": "stale-panel",
          "pid": \(getpid()),
          "cwd": "/tmp",
          "created_at": "2026-07-06T15:10:00Z",
          "tmux_pane_id": "%13",
          "tmux_socket_path": "/private/tmp/tmux-501/default",
          "runtime": "codex_app_server",
          "app_server_socket": "/tmp/app.sock",
          "app_server_pid": \(getpid()),
          "thread_id": "019ec8cb-6128-7892-8441-8c22d854286c",
          "resume_thread_id": "019ec8cb-6128-7892-8441-8c22d854286c"
        }
        """.utf8)
        try recordData.write(to: registryURL)

        let tmuxResolver = TmuxStateResolver(ttl: 60) { socketPath, arguments in
            XCTAssertEqual(socketPath, "/tmp/tmux-501/default")
            if arguments == ["list-panes", "-a", "-F", "#{pane_id}|#{@tidey_workspace_id}|#{@tidey_panel_id}"] {
                return "%13|stale-workspace|stale-panel\n"
            }
            if arguments == ["list-panes", "-a", "-F", "#{pane_id}|#{session_name}"] {
                return "%13|genesis-codex\n"
            }
            if arguments == ["list-clients", "-F", "#{client_pid}|#{session_name}"] {
                return "123|genesis-codex\n"
            }
            XCTFail("Unexpected tmux arguments: \(arguments)")
            return ""
        }
        let ordinaryTmuxResolver = TideyOrdinaryTmuxCarrierResolver(requestSender: { request in
            if request.action == "list_workspaces" {
                return BridgeResponse(id: request.id,
                                      ok: true,
                                      result: [
                                        "workspaces": .array([
                                            .object([
                                                "workspace_id": .string("genesis-workspace"),
                                                "title": .string("Genesis"),
                                                "selected_panel_id": .string("genesis-carrier-panel"),
                                                "ordinary_tmux": .object([
                                                    "target_session": .string("genesis-codex"),
                                                ]),
                                            ]),
                                        ]),
                                      ],
                                      error: nil)
            }
            if request.action == "list_panels" {
                XCTAssertEqual(request.params?["workspace_id"]?.stringValue, "genesis-workspace")
                return BridgeResponse(id: request.id,
                                      ok: true,
                                      result: [
                                        "workspace_id": .string("genesis-workspace"),
                                        "panels": .array([
                                            .object([
                                                "panel_id": .string("genesis-carrier-panel"),
                                                "workspace_id": .string("genesis-workspace"),
                                                "ordinary_tmux": .object([
                                                    "target_session": .string("genesis-codex"),
                                                ]),
                                            ]),
                                        ]),
                                      ],
                                      error: nil)
            }
            XCTFail("Unexpected Tidey socket action: \(request.action)")
            return BridgeResponse(id: request.id, ok: false, result: nil, error: nil)
        }, tmuxResolver: tmuxResolver)
        let runtimeSyncer = CapturingRuntimeSyncer()
        let monitor = AgentSessionRegistryMonitor(paths: paths,
                                                  fileManager: fileManager,
                                                  hub: AgentEventHub(),
                                                  tmuxResolver: tmuxResolver,
                                                  parentPIDLookup: { _ in nil },
                                                  ordinaryTmuxCarrierIdentityResolver: { record in
                                                      ordinaryTmuxResolver.carrierIdentity(for: record)
                                                  },
                                                  runtimeSyncer: runtimeSyncer)
        try monitor.start()

        XCTAssertNil(monitor.activeSessionForWorkspace(workspaceID: "stale-workspace"))
        XCTAssertEqual(monitor.activeSessionForWorkspace(workspaceID: "genesis-workspace")?.sessionID,
                       "app-server-session")

        XCTAssertEqual(try Data(contentsOf: registryURL), recordData)

        let syncedRecord = try XCTUnwrap(runtimeSyncer.latestRecords.first)
        XCTAssertEqual(syncedRecord.workspaceID, "genesis-workspace")
        XCTAssertEqual(syncedRecord.panelID, "genesis-carrier-panel")
        XCTAssertEqual(syncedRecord.runtime, "codex_app_server")
    }

    func testScanFillsMissingAppServerPanelIDFromTmuxClientProcessAncestry() throws {
        let fileManager = FileManager.default
        let supportDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("tidey-remote-bridge-monitor-\(UUID().uuidString)", isDirectory: true)
        let paths = BridgePaths(supportDirectory: supportDirectory)
        try paths.ensureSupportDirectoriesExist(fileManager: fileManager)
        defer { try? fileManager.removeItem(at: supportDirectory) }

        let registryURL = paths.codexAgentSessionsDirectory.appendingPathComponent("codex-app-server-missing-panel.json")
        let recordData = Data("""
        {
          "version": 1,
          "vendor": "codex",
          "workspace_id": "adbrewer-workspace",
          "session_id": "app-server-session",
          "panel_id": "",
          "pid": \(getpid()),
          "cwd": "/tmp",
          "created_at": "2026-07-06T15:20:00Z",
          "tmux_pane_id": "%29",
          "tmux_socket_path": "/private/tmp/tmux-501/default",
          "runtime": "codex_app_server",
          "app_server_socket": "/tmp/app.sock",
          "app_server_pid": \(getpid()),
          "thread_id": "019f37e6-2f79-7d90-93be-6c066a30a366",
          "resume_thread_id": "019f37e6-2f79-7d90-93be-6c066a30a366"
        }
        """.utf8)
        try recordData.write(to: registryURL)

        let tmuxResolver = TmuxStateResolver(ttl: 60) { socketPath, arguments in
            XCTAssertEqual(socketPath, "/tmp/tmux-501/default")
            if arguments == ["list-panes", "-a", "-F", "#{pane_id}|#{@tidey_workspace_id}|#{@tidey_panel_id}"] {
                return "%29||\n"
            }
            if arguments == ["list-panes", "-a", "-F", "#{pane_id}|#{session_name}"] {
                return "%29|adbrewer-codex\n"
            }
            if arguments == ["list-clients", "-F", "#{client_pid}|#{session_name}"] {
                return "200|adbrewer-codex\n"
            }
            XCTFail("Unexpected tmux arguments: \(arguments)")
            return ""
        }
        let runtimeSyncer = CapturingRuntimeSyncer()
        var requestedActions = [String]()
        let monitor = AgentSessionRegistryMonitor(paths: paths,
                                                  fileManager: fileManager,
                                                  hub: AgentEventHub(),
                                                  tmuxResolver: tmuxResolver,
                                                  parentPIDLookup: { pid in
                                                      pid == 200 ? 100 : nil
                                                  },
                                                  livePanelSnapshotRequestSender: { request in
                                                      requestedActions.append(request.action)
                                                      if request.action == "list_workspaces" {
                                                          return BridgeResponse(id: request.id,
                                                                                ok: true,
                                                                                result: [
                                                                                    "workspaces": .array([
                                                                                        .object([
                                                                                            "workspace_id": .string("adbrewer-workspace"),
                                                                                            "title": .string("釀酒人"),
                                                                                        ]),
                                                                                    ]),
                                                                                ],
                                                                                error: nil)
                                                      }
                                                      if request.action == "list_panels" {
                                                          XCTAssertEqual(request.params?["workspace_id"]?.stringValue,
                                                                         "adbrewer-workspace")
                                                          return BridgeResponse(id: request.id,
                                                                                ok: true,
                                                                                result: [
                                                                                    "workspace_id": .string("adbrewer-workspace"),
                                                                                    "panels": .array([
                                                                                        .object([
                                                                                            "workspace_id": .string("adbrewer-workspace"),
                                                                                            "panel_id": .string("adbrewer-codex-panel"),
                                                                                            "effective_shell_pid": .number(100),
                                                                                            "title": .string("Codex"),
                                                                                        ]),
                                                                                        .object([
                                                                                            "workspace_id": .string("adbrewer-workspace"),
                                                                                            "panel_id": .string("other-panel"),
                                                                                            "effective_shell_pid": .number(300),
                                                                                            "title": .string("Codex"),
                                                                                        ]),
                                                                                    ]),
                                                                                ],
                                                                                error: nil)
                                                      }
                                                      XCTFail("Unexpected Tidey socket action: \(request.action)")
                                                      return BridgeResponse(id: request.id,
                                                                            ok: false,
                                                                            result: nil,
                                                                            error: nil)
                                                  },
                                                  runtimeSyncer: runtimeSyncer)
        try monitor.start()

        XCTAssertEqual(requestedActions, ["list_workspaces", "list_panels"])
        XCTAssertEqual(monitor.activeSessionForWorkspace(workspaceID: "adbrewer-workspace")?.panelID,
                       "adbrewer-codex-panel")

        XCTAssertEqual(try Data(contentsOf: registryURL), recordData)

        let syncedRecord = try XCTUnwrap(runtimeSyncer.latestRecords.first)
        XCTAssertEqual(syncedRecord.workspaceID, "adbrewer-workspace")
        XCTAssertEqual(syncedRecord.panelID, "adbrewer-codex-panel")
        XCTAssertEqual(syncedRecord.runtime, "codex_app_server")
    }

    func testScanDoesNotUseSelectedPanelAsOrdinaryTmuxCarrierFallback() throws {
        let fileManager = FileManager.default
        let supportDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("tidey-remote-bridge-monitor-\(UUID().uuidString)", isDirectory: true)
        let paths = BridgePaths(supportDirectory: supportDirectory)
        try paths.ensureSupportDirectoriesExist(fileManager: fileManager)
        defer { try? fileManager.removeItem(at: supportDirectory) }

        let registryURL = paths.codexAgentSessionsDirectory.appendingPathComponent("codex-app-server-stale-carrier-no-panel.json")
        let recordData = Data("""
        {
          "version": 1,
          "vendor": "codex",
          "workspace_id": "genesis-workspace",
          "session_id": "app-server-session",
          "panel_id": "",
          "pid": \(getpid()),
          "cwd": "/tmp",
          "created_at": "2026-06-30T08:20:00Z",
          "tmux_pane_id": "%13",
          "tmux_socket_path": "/private/tmp/tmux-501/default",
          "runtime": "codex_app_server",
          "app_server_socket": "/tmp/app.sock",
          "app_server_pid": \(getpid()),
          "thread_id": "019ec8cb-6128-7892-8441-8c22d854286c",
          "resume_thread_id": "019ec8cb-6128-7892-8441-8c22d854286c"
        }
        """.utf8)
        try recordData.write(to: registryURL)

        let tmuxResolver = TmuxStateResolver(ttl: 60) { socketPath, arguments in
            XCTAssertEqual(socketPath, "/tmp/tmux-501/default")
            if arguments == ["list-panes", "-a", "-F", "#{pane_id}|#{@tidey_workspace_id}|#{@tidey_panel_id}"] {
                return "%13||\n"
            }
            if arguments == ["list-panes", "-a", "-F", "#{pane_id}|#{session_name}"] {
                return "%13|tidey-codex\n"
            }
            if arguments == ["list-clients", "-F", "#{client_pid}|#{session_name}"] {
                return "123|tidey-codex\n"
            }
            XCTFail("Unexpected tmux arguments: \(arguments)")
            return ""
        }
        let ordinaryTmuxResolver = TideyOrdinaryTmuxCarrierResolver(requestSender: { request in
            if request.action == "list_workspaces" {
                return BridgeResponse(id: request.id,
                                      ok: true,
                                      result: [
                                        "workspaces": .array([
                                            .object([
                                                "workspace_id": .string("tidey-workspace"),
                                                "title": .string("Tidey"),
                                                "selected_panel_id": .string("unrelated-selected-panel"),
                                                "ordinary_tmux": .object([
                                                    "target_session": .string("tidey-codex"),
                                                ]),
                                            ]),
                                        ]),
                                      ],
                                      error: nil)
            }
            if request.action == "list_panels" {
                XCTAssertEqual(request.params?["workspace_id"]?.stringValue, "tidey-workspace")
                return BridgeResponse(id: request.id,
                                      ok: true,
                                      result: [
                                        "workspace_id": .string("tidey-workspace"),
                                        "panels": .array([
                                            .object([
                                                "panel_id": .string("unrelated-selected-panel"),
                                                "workspace_id": .string("tidey-workspace"),
                                            ]),
                                        ]),
                                      ],
                                      error: nil)
            }
            XCTFail("Unexpected Tidey socket action: \(request.action)")
            return BridgeResponse(id: request.id, ok: false, result: nil, error: nil)
        }, tmuxResolver: tmuxResolver)
        let monitor = AgentSessionRegistryMonitor(paths: paths,
                                                  fileManager: fileManager,
                                                  hub: AgentEventHub(),
                                                  tmuxResolver: tmuxResolver,
                                                  parentPIDLookup: { _ in nil },
                                                  ordinaryTmuxCarrierIdentityResolver: { record in
                                                      ordinaryTmuxResolver.carrierIdentity(for: record)
                                                  })
        try monitor.start()

        XCTAssertEqual(monitor.activeSessionForWorkspace(workspaceID: "tidey-workspace")?.sessionID, nil)
        XCTAssertEqual(monitor.activeSessionForWorkspace(workspaceID: "genesis-workspace")?.sessionID, "app-server-session")

        let persistedData = try Data(contentsOf: registryURL)
        let persistedRecord = try JSONDecoder().decode(AgentSessionRegistryRecord.self, from: persistedData)
        XCTAssertEqual(persistedRecord.workspaceID, "genesis-workspace")
        XCTAssertEqual(persistedRecord.panelID, "")
        XCTAssertEqual(persistedRecord.tmuxSocketPath, "/private/tmp/tmux-501/default")
    }

    func testScanDoesNotRewriteRegistryRecordWithoutTmuxPaneIdentity() throws {
        let fileManager = FileManager.default
        let supportDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("tidey-remote-bridge-monitor-\(UUID().uuidString)", isDirectory: true)
        let paths = BridgePaths(supportDirectory: supportDirectory)
        try paths.ensureSupportDirectoriesExist(fileManager: fileManager)
        defer { try? fileManager.removeItem(at: supportDirectory) }

        let registryURL = paths.claudeAgentSessionsDirectory.appendingPathComponent("claude-session-no-pane.json")
        let recordData = Data("""
        {
          "version": 1,
          "vendor": "claude",
          "workspace_id": "stale-workspace",
          "session_id": "session-no-pane",
          "panel_id": "stale-panel",
          "pid": \(getpid()),
          "cwd": "/tmp",
          "created_at": "2026-06-19T10:25:00Z"
        }
        """.utf8)
        try recordData.write(to: registryURL)

        let monitor = AgentSessionRegistryMonitor(paths: paths,
                                                  fileManager: fileManager,
                                                  hub: AgentEventHub(),
                                                  tmuxResolver: TmuxStateResolver(ttl: 60) { _, _ in
                                                      XCTFail("record without tmux_pane_id must not trigger tmux lookup")
                                                      return ""
                                                  },
                                                  parentPIDLookup: { _ in nil })
        monitor.replaceLivePanels(workspaceID: "current-workspace",
                                  panels: [
                                      AgentPanelProcessSnapshot(workspaceID: "current-workspace",
                                                                panelID: "current-panel",
                                                                effectiveShellPID: nil,
                                                                tmuxPaneID: "%14",
                                                                tmuxSocketPath: "/private/tmp/tmux-501/default"),
                                  ])
        try monitor.start()

        let snapshot = monitor.activeSessionSnapshots().first
        XCTAssertEqual(snapshot?.workspaceID, "stale-workspace")
        XCTAssertEqual(snapshot?.panelID, "stale-panel")

        let persistedData = try Data(contentsOf: registryURL)
        let persistedRecord = try JSONDecoder().decode(AgentSessionRegistryRecord.self, from: persistedData)
        XCTAssertEqual(persistedRecord.workspaceID, "stale-workspace")
        XCTAssertEqual(persistedRecord.panelID, "stale-panel")
        XCTAssertNil(persistedRecord.tmuxPaneID)
        XCTAssertNil(persistedRecord.tmuxSocketPath)
    }

    func testActiveSessionForPanelUsesCurrentPaneWhenRecordLacksSocketPath() throws {
        let fileManager = FileManager.default
        let supportDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("tidey-remote-bridge-monitor-\(UUID().uuidString)", isDirectory: true)
        let paths = BridgePaths(supportDirectory: supportDirectory)
        try paths.ensureSupportDirectoriesExist(fileManager: fileManager)
        defer { try? fileManager.removeItem(at: supportDirectory) }

        let registryURL = paths.claudeAgentSessionsDirectory.appendingPathComponent("claude-session-stale-env.json")
        let recordData = Data("""
        {
          "version": 1,
          "vendor": "claude",
          "workspace_id": "stale-workspace",
          "session_id": "session-stale-env",
          "panel_id": "stale-panel",
          "pid": \(getpid()),
          "cwd": "/tmp",
          "created_at": "2026-06-19T10:25:00Z",
          "tmux_pane_id": "%14"
        }
        """.utf8)
        try recordData.write(to: registryURL)

        let monitor = AgentSessionRegistryMonitor(paths: paths,
                                                  fileManager: fileManager,
                                                  hub: AgentEventHub(),
                                                  tmuxResolver: TmuxStateResolver(ttl: 60) { _, _ in "" },
                                                  parentPIDLookup: { _ in nil })
        try monitor.start()

        let session = monitor.activeSessionForPanel(workspaceID: "current-workspace",
                                                    panelID: "current-panel",
                                                    effectiveShellPID: nil,
                                                    tmuxPaneID: "%14",
                                                    tmuxSocketPath: "/private/tmp/tmux-501/default")
        XCTAssertEqual(session?.sessionID, "session-stale-env")
        XCTAssertEqual(session?.workspaceID, "current-workspace")
        XCTAssertEqual(session?.panelID, "current-panel")
    }

    func testScanBatchesPaneIdentityLookupOncePerSocket() throws {
        let fileManager = FileManager.default
        let supportDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("tidey-remote-bridge-monitor-\(UUID().uuidString)", isDirectory: true)
        let paths = BridgePaths(supportDirectory: supportDirectory)
        try paths.ensureSupportDirectoriesExist(fileManager: fileManager)
        defer { try? fileManager.removeItem(at: supportDirectory) }

        try writeRegistryRecord(paths.codexAgentSessionsDirectory.appendingPathComponent("codex-session-1.json"),
                                vendor: "codex",
                                workspaceID: "stale-workspace-1",
                                sessionID: "session-1",
                                panelID: "stale-panel-1",
                                paneID: "%1")
        try writeRegistryRecord(paths.codexAgentSessionsDirectory.appendingPathComponent("codex-session-2.json"),
                                vendor: "codex",
                                workspaceID: "stale-workspace-2",
                                sessionID: "session-2",
                                panelID: "stale-panel-2",
                                paneID: "%2")
        try writeRegistryRecord(paths.claudeAgentSessionsDirectory.appendingPathComponent("claude-session-3.json"),
                                vendor: "claude",
                                workspaceID: "stale-workspace-3",
                                sessionID: "session-3",
                                panelID: "stale-panel-3",
                                paneID: "%3")

        let calls = CommandLog()
        let tmuxResolver = TmuxStateResolver(ttl: 60) { socketPath, arguments in
            XCTAssertEqual(socketPath, "/tmp/tmux.sock")
            calls.append(arguments)
            XCTAssertEqual(arguments, ["list-panes", "-a", "-F", "#{pane_id}|#{@tidey_workspace_id}|#{@tidey_panel_id}"])
            return "%1|workspace-1|panel-1\n%2|workspace-2|panel-2\n%3||\n"
        }
        let monitor = AgentSessionRegistryMonitor(paths: paths,
                                                  fileManager: fileManager,
                                                  hub: AgentEventHub(),
                                                  tmuxResolver: tmuxResolver,
                                                  parentPIDLookup: { _ in nil })
        try monitor.start()

        let snapshots = Dictionary(uniqueKeysWithValues: monitor.activeSessionSnapshots().map { ($0.sessionID, $0) })
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(snapshots["session-1"]?.workspaceID, "workspace-1")
        XCTAssertEqual(snapshots["session-1"]?.panelID, "panel-1")
        XCTAssertEqual(snapshots["session-2"]?.workspaceID, "workspace-2")
        XCTAssertEqual(snapshots["session-2"]?.panelID, "panel-2")
        XCTAssertEqual(snapshots["session-3"]?.workspaceID, "stale-workspace-3")
        XCTAssertEqual(snapshots["session-3"]?.panelID, "stale-panel-3")
    }

    func testScanKeepsCodexAppServerRecordWhenAppServerPIDIsAlive() throws {
        let fileManager = FileManager.default
        let supportDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("tidey-remote-bridge-monitor-\(UUID().uuidString)", isDirectory: true)
        let paths = BridgePaths(supportDirectory: supportDirectory)
        try paths.ensureSupportDirectoriesExist(fileManager: fileManager)
        defer { try? fileManager.removeItem(at: supportDirectory) }

        let registryURL = paths.codexAgentSessionsDirectory.appendingPathComponent("codex-app-server-panel.json")
        let recordData = Data("""
        {
          "version": 1,
          "vendor": "codex",
          "workspace_id": "workspace-app-server",
          "session_id": "session-app-server",
          "panel_id": "panel-app-server",
          "pid": 999999,
          "cwd": "/tmp",
          "created_at": "2026-06-07T00:00:00Z",
          "runtime": "codex_app_server",
          "app_server_socket": "/tmp/tidey-codex-app-server/app.sock",
          "app_server_pid": \(getpid()),
          "thread_id": "thread-current",
          "resume_thread_id": "thread-resume"
        }
        """.utf8)
        try recordData.write(to: registryURL)

        let runtimeSyncer = CapturingRuntimeSyncer()
        let monitor = AgentSessionRegistryMonitor(paths: paths,
                                                  fileManager: fileManager,
                                                  hub: AgentEventHub(),
                                                  tmuxResolver: TmuxStateResolver(ttl: 60) { _, _ in "" },
                                                  parentPIDLookup: { _ in nil },
                                                  runtimeSyncer: runtimeSyncer)
        try monitor.start()

        let session = monitor.activeSessionForPanel(workspaceID: "workspace-app-server",
                                                    panelID: "panel-app-server")
        XCTAssertEqual(session?.sessionID, "session-app-server")
        XCTAssertEqual(session?.restoreSessionID, "thread-current")
        XCTAssertTrue(fileManager.fileExists(atPath: registryURL.path))
        XCTAssertEqual(runtimeSyncer.latestRecords.map(\.sessionID), ["session-app-server"])
    }

    func testCodexAppServerActiveThreadUpdatesRegistryTranscriptIdentity() throws {
        let fileManager = FileManager.default
        let supportDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("tidey-remote-bridge-monitor-\(UUID().uuidString)", isDirectory: true)
        let paths = BridgePaths(supportDirectory: supportDirectory)
        try paths.ensureSupportDirectoriesExist(fileManager: fileManager)
        defer { try? fileManager.removeItem(at: supportDirectory) }

        let threadA = "019d70fe-fd27-7a12-a3f7-9c89ae5048b6"
        let threadB = "019ec8cb-fd27-7a12-a3f7-9c89ae5048b6"
        let rolloutA = supportDirectory.appendingPathComponent("rollout-a-\(threadA).jsonl")
        let rolloutB = supportDirectory.appendingPathComponent("rollout-b-\(threadB).jsonl")
        try "\n".write(to: rolloutA, atomically: true, encoding: .utf8)
        try "\n".write(to: rolloutB, atomically: true, encoding: .utf8)

        let registryURL = paths.codexAgentSessionsDirectory.appendingPathComponent("codex-instance-session.json")
        let recordData = Data("""
        {
          "version": 1,
          "vendor": "codex",
          "workspace_id": "workspace-app-server",
          "session_id": "instance-session",
          "panel_id": "panel-app-server",
          "pid": 999999,
          "cwd": "/tmp",
          "created_at": "2026-06-07T00:00:00Z",
          "runtime": "codex_app_server",
          "app_server_socket": "/tmp/tidey-codex-app-server/app.sock",
          "app_server_pid": \(getpid()),
          "thread_id": "\(threadA)",
          "resume_thread_id": "\(threadA)",
          "rollout_path": "\(rolloutA.path)"
        }
        """.utf8)
        try recordData.write(to: registryURL)

        let monitor = AgentSessionRegistryMonitor(paths: paths,
                                                  fileManager: fileManager,
                                                  hub: AgentEventHub(),
                                                  tmuxResolver: TmuxStateResolver(ttl: 60) { _, _ in "" },
                                                  parentPIDLookup: { _ in nil },
                                                  codexRolloutBySessionIDLookup: { sessionID in
                                                      sessionID == threadB ? rolloutB.path : rolloutA.path
                                                  })
        try monitor.start()

        XCTAssertEqual(monitor.activeSessionForPanel(workspaceID: "workspace-app-server",
                                                     panelID: "panel-app-server")?.restoreSessionID,
                       threadA)

        monitor.appServerActiveThreadDidChange(sessionID: "instance-session", threadID: threadB)

        XCTAssertTrue(waitUntil {
            monitor.activeSessionForPanel(workspaceID: "workspace-app-server",
                                          panelID: "panel-app-server")?.restoreSessionID == threadB
        })
        let updatedData = try Data(contentsOf: registryURL)
        let updatedRecord = try JSONDecoder().decode(AgentSessionRegistryRecord.self, from: updatedData)
        XCTAssertEqual(updatedRecord.sessionID, "instance-session")
        XCTAssertEqual(updatedRecord.threadID, threadB)
        XCTAssertEqual(updatedRecord.resumeThreadID, threadA)
        XCTAssertEqual(updatedRecord.transcriptPath, rolloutB.path)
    }

    func testCodexAppServerAttachLoadedThreadUpdatesRegistryTranscriptIdentity() throws {
        let fileManager = FileManager.default
        let supportDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("tidey-remote-bridge-monitor-\(UUID().uuidString)", isDirectory: true)
        let paths = BridgePaths(supportDirectory: supportDirectory)
        try paths.ensureSupportDirectoriesExist(fileManager: fileManager)
        defer { try? fileManager.removeItem(at: supportDirectory) }

        let threadA = "019d70fe-fd27-7a12-a3f7-9c89ae5048b6"
        let threadB = "019ec8cb-fd27-7a12-a3f7-9c89ae5048b6"
        let rolloutA = supportDirectory.appendingPathComponent("rollout-a-\(threadA).jsonl")
        let rolloutB = supportDirectory.appendingPathComponent("rollout-b-\(threadB).jsonl")
        try "\n".write(to: rolloutA, atomically: true, encoding: .utf8)
        try "\n".write(to: rolloutB, atomically: true, encoding: .utf8)

        let registryURL = paths.codexAgentSessionsDirectory.appendingPathComponent("codex-instance-session.json")
        let recordData = Data("""
        {
          "version": 1,
          "vendor": "codex",
          "workspace_id": "workspace-app-server",
          "session_id": "instance-session",
          "panel_id": "panel-app-server",
          "pid": 999999,
          "cwd": "/tmp",
          "created_at": "2026-06-07T00:00:00Z",
          "runtime": "codex_app_server",
          "app_server_socket": "/tmp/tidey-codex-app-server/app.sock",
          "app_server_pid": \(getpid()),
          "thread_id": "\(threadA)",
          "resume_thread_id": "\(threadA)",
          "rollout_path": "\(rolloutA.path)"
        }
        """.utf8)
        try recordData.write(to: registryURL)

        let connector = FakeCodexAppServerTransportConnector()
        let factory = CodexAppServerRuntimeSessionFactory(processRunner: FakeCodexAppServerProcessRunner(),
                                                          transportConnector: connector)
        let hub = AgentEventHub()
        let runtimeSyncer = CodexAppServerRegistryRuntimeSyncer(eventHub: hub, factory: factory)
        let monitor = AgentSessionRegistryMonitor(paths: paths,
                                                  fileManager: fileManager,
                                                  hub: hub,
                                                  tmuxResolver: TmuxStateResolver(ttl: 60) { _, _ in "" },
                                                  parentPIDLookup: { _ in nil },
                                                  codexRolloutBySessionIDLookup: { sessionID in
                                                      sessionID == threadB ? rolloutB.path : rolloutA.path
                                                  },
                                                  runtimeSyncer: runtimeSyncer)
        runtimeSyncer.activeThreadHandler = { [weak monitor] sessionID, threadID in
            monitor?.appServerActiveThreadDidChange(sessionID: sessionID, threadID: threadID)
        }
        try monitor.start()

        let transport = try XCTUnwrap(connector.transport)
        try acknowledgeCodexAppServerInitialize(from: transport)
        let listLoaded = try jsonObject(from: try XCTUnwrap(transport.sentLines().dropFirst(2).first))
        XCTAssertEqual(listLoaded["method"]?.stringValue, "thread/loaded/list")
        let listLoadedID = try XCTUnwrap(listLoaded["id"])
        transport.emitLine(try jsonResponseText(id: listLoadedID, result: .object([
            "threads": .array([
                .object([
                    "id": .string(threadA),
                    "preview": .string("Launch thread"),
                ]),
                .object([
                    "id": .string(threadB),
                    "preview": .string("Current thread"),
                    "isCurrent": .bool(true),
                ]),
            ]),
        ])))

        XCTAssertTrue(waitUntil {
            monitor.activeSessionForPanel(workspaceID: "workspace-app-server",
                                          panelID: "panel-app-server")?.restoreSessionID == threadB
        })
        let updatedData = try Data(contentsOf: registryURL)
        let updatedRecord = try JSONDecoder().decode(AgentSessionRegistryRecord.self, from: updatedData)
        XCTAssertEqual(updatedRecord.threadID, threadB)
        XCTAssertEqual(updatedRecord.resumeThreadID, threadA)
        XCTAssertEqual(updatedRecord.transcriptPath, rolloutB.path)
    }

    func testCodexAppServerActiveThreadNoopsWhenThreadAndTranscriptAlreadyCurrent() throws {
        let fileManager = FileManager.default
        let supportDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("tidey-remote-bridge-monitor-\(UUID().uuidString)", isDirectory: true)
        let paths = BridgePaths(supportDirectory: supportDirectory)
        try paths.ensureSupportDirectoriesExist(fileManager: fileManager)
        defer { try? fileManager.removeItem(at: supportDirectory) }

        let threadID = "019ec8cb-fd27-7a12-a3f7-9c89ae5048b6"
        let rolloutURL = supportDirectory.appendingPathComponent("rollout-current-\(threadID).jsonl")
        try "\n".write(to: rolloutURL, atomically: true, encoding: .utf8)
        let registryURL = paths.codexAgentSessionsDirectory.appendingPathComponent("codex-instance-session.json")
        let recordData = Data("""
        {
          "version": 1,
          "vendor": "codex",
          "workspace_id": "workspace-app-server",
          "session_id": "instance-session",
          "panel_id": "panel-app-server",
          "pid": 999999,
          "cwd": "/tmp",
          "created_at": "2026-06-07T00:00:00Z",
          "runtime": "codex_app_server",
          "app_server_socket": "/tmp/tidey-codex-app-server/app.sock",
          "app_server_pid": \(getpid()),
          "thread_id": "\(threadID)",
          "resume_thread_id": "launch-thread",
          "rollout_path": "\(rolloutURL.path)"
        }
        """.utf8)
        try recordData.write(to: registryURL)
        let originalData = try Data(contentsOf: registryURL)

        let monitor = AgentSessionRegistryMonitor(paths: paths,
                                                  fileManager: fileManager,
                                                  hub: AgentEventHub(),
                                                  tmuxResolver: TmuxStateResolver(ttl: 60) { _, _ in "" },
                                                  parentPIDLookup: { _ in nil },
                                                  codexRolloutBySessionIDLookup: { _ in rolloutURL.path })
        try monitor.start()

        monitor.appServerActiveThreadDidChange(sessionID: "instance-session", threadID: threadID)
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))

        XCTAssertEqual(try Data(contentsOf: registryURL), originalData)
        XCTAssertEqual(monitor.activeSessionForPanel(workspaceID: "workspace-app-server",
                                                     panelID: "panel-app-server")?.restoreSessionID,
                       threadID)
    }

    func testScanPicksUpCodexAppServerRecordCreatedAfterStart() throws {
        let fileManager = FileManager.default
        let supportDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("tidey-remote-bridge-monitor-\(UUID().uuidString)", isDirectory: true)
        let paths = BridgePaths(supportDirectory: supportDirectory)
        try paths.ensureSupportDirectoriesExist(fileManager: fileManager)
        defer { try? fileManager.removeItem(at: supportDirectory) }

        let runtimeSyncer = CapturingRuntimeSyncer()
        let monitor = AgentSessionRegistryMonitor(paths: paths,
                                                  fileManager: fileManager,
                                                  hub: AgentEventHub(),
                                                  tmuxResolver: TmuxStateResolver(ttl: 60) { _, _ in "" },
                                                  parentPIDLookup: { _ in nil },
                                                  runtimeSyncer: runtimeSyncer)
        try monitor.start()
        XCTAssertEqual(runtimeSyncer.latestRecords.map(\.sessionID), [])

        let registryURL = paths.codexAgentSessionsDirectory.appendingPathComponent("codex-app-server-panel.json")
        let recordData = Data("""
        {
          "version": 1,
          "vendor": "codex",
          "workspace_id": "workspace-app-server",
          "session_id": "session-app-server",
          "panel_id": "panel-app-server",
          "pid": 999999,
          "cwd": "/tmp",
          "created_at": "2026-06-07T00:00:00Z",
          "runtime": "codex_app_server",
          "app_server_socket": "/tmp/tidey-codex-app-server/app.sock",
          "app_server_pid": \(getpid())
        }
        """.utf8)
        try recordData.write(to: registryURL)

        XCTAssertTrue(waitUntil {
            runtimeSyncer.latestRecords.map(\.sessionID) == ["session-app-server"]
        })
    }

    func testCodexAppServerRecordStartsTranscriptSessionFromRolloutPath() throws {
        let fileManager = FileManager.default
        let supportDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("tidey-remote-bridge-monitor-\(UUID().uuidString)", isDirectory: true)
        let paths = BridgePaths(supportDirectory: supportDirectory)
        try paths.ensureSupportDirectoriesExist(fileManager: fileManager)
        defer { try? fileManager.removeItem(at: supportDirectory) }

        let rolloutURL = supportDirectory.appendingPathComponent("rollout-2026-06-08T22-06-25-019ea78e-5aee-7a40-848c-7e9b78025fc9.jsonl")
        let lines = [
            makeCodexMessageLine(role: "user", content: "Message from Mac TUI"),
            makeCodexMessageLine(role: "assistant", content: "Message visible on Remote"),
        ].joined(separator: "\n") + "\n"
        try lines.write(to: rolloutURL, atomically: true, encoding: .utf8)

        let registryURL = paths.codexAgentSessionsDirectory.appendingPathComponent("codex-app-server-panel.json")
        let recordData = Data("""
        {
          "version": 1,
          "vendor": "codex",
          "workspace_id": "workspace-app-server",
          "session_id": "session-app-server",
          "panel_id": "panel-app-server",
          "pid": 999999,
          "cwd": "/tmp",
          "created_at": "2026-06-07T00:00:00Z",
          "runtime": "codex_app_server",
          "app_server_socket": "/tmp/tidey-codex-app-server/app.sock",
          "app_server_pid": \(getpid()),
          "rollout_path": "\(rolloutURL.path)"
        }
        """.utf8)
        try recordData.write(to: registryURL)

        let hub = AgentEventHub()
        var capturedAgentEventHandler: CodexAppServerHeadlessRuntime.AgentEventHandler?
        let runtimeSyncer = CodexAppServerRegistryRuntimeSyncer(eventHub: hub,
                                                               attachHandler: { _, _, _, onAgentEvent, _, _, _ in
            capturedAgentEventHandler = onAgentEvent
            return RegistryMonitorFakeRuntimeSession()
        })
        let monitor = AgentSessionRegistryMonitor(paths: paths,
                                                  fileManager: fileManager,
                                                  hub: hub,
                                                  tmuxResolver: TmuxStateResolver(ttl: 60) { _, _ in "" },
                                                  parentPIDLookup: { _ in nil },
                                                  runtimeSyncer: runtimeSyncer)
        try monitor.start()

        XCTAssertTrue(waitUntil {
            let result = hub.fetch(workspaceID: "workspace-app-server",
                                   sessionID: "session-app-server",
                                   limit: 10)
            return result.events.contains { $0.text == "Message visible on Remote" }
        })

        let result = hub.fetch(workspaceID: "workspace-app-server",
                               sessionID: "session-app-server",
                               limit: 10)
        XCTAssertEqual(result.events.filter { $0.type == .userMessage }.map(\.text),
                       ["Message from Mac TUI"])
        XCTAssertEqual(result.events.filter { $0.type == .assistantMessage }.map(\.text),
                       ["Message visible on Remote"])

        let onAgentEvent = try XCTUnwrap(capturedAgentEventHandler)
        onAgentEvent(AgentEvent(eventID: "runtime-user-duplicate",
                                seq: 10_000,
                                vendor: "codex",
                                workspaceID: "workspace-app-server",
                                sessionID: "session-app-server",
                                timestamp: "2026-06-08T22:06:26.000Z",
                                type: .userMessage,
                                role: nil,
                                text: "Message from Mac TUI",
                                name: nil,
                                input: nil,
                                output: nil,
                                toolCallID: nil,
                                metadata: ["source": "codex_app_server"]))
        onAgentEvent(AgentEvent(eventID: "runtime-assistant-duplicate",
                                seq: 10_001,
                                vendor: "codex",
                                workspaceID: "workspace-app-server",
                                sessionID: "session-app-server",
                                timestamp: "2026-06-08T22:06:27.000Z",
                                type: .assistantMessage,
                                role: nil,
                                text: "Message visible on Remote",
                                name: nil,
                                input: nil,
                                output: nil,
                                toolCallID: nil,
                                metadata: ["source": "codex_app_server"]))

        let deduplicated = hub.fetch(workspaceID: "workspace-app-server",
                                     sessionID: "session-app-server",
                                     limit: 10)
        XCTAssertEqual(deduplicated.events.filter { $0.type == .userMessage }.map(\.text),
                       ["Message from Mac TUI"])
        XCTAssertEqual(deduplicated.events.filter { $0.type == .assistantMessage }.map(\.text),
                       ["Message visible on Remote"])
    }

    func testScanPrefersNewestCodexAppServerRecordForSamePanel() throws {
        let fileManager = FileManager.default
        let supportDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("tidey-remote-bridge-monitor-\(UUID().uuidString)", isDirectory: true)
        let paths = BridgePaths(supportDirectory: supportDirectory)
        try paths.ensureSupportDirectoriesExist(fileManager: fileManager)
        defer { try? fileManager.removeItem(at: supportDirectory) }

        let oldRecordURL = paths.codexAgentSessionsDirectory.appendingPathComponent("codex-old-app-server.json")
        let newRecordURL = paths.codexAgentSessionsDirectory.appendingPathComponent("codex-new-app-server.json")
        try Data("""
        {
          "version": 1,
          "vendor": "codex",
          "workspace_id": "workspace-app-server",
          "session_id": "old-session",
          "panel_id": "panel-app-server",
          "pid": \(getpid()),
          "cwd": "/tmp",
          "created_at": "2026-06-07T00:00:00Z",
          "runtime": "codex_app_server",
          "app_server_socket": "/tmp/tidey-codex-app-server/old.sock",
          "app_server_pid": \(getpid())
        }
        """.utf8).write(to: oldRecordURL)
        try Data("""
        {
          "version": 1,
          "vendor": "codex",
          "workspace_id": "workspace-app-server",
          "session_id": "new-session",
          "panel_id": "panel-app-server",
          "pid": \(getpid()),
          "cwd": "/tmp",
          "created_at": "2026-06-07T00:01:00Z",
          "runtime": "codex_app_server",
          "app_server_socket": "/tmp/tidey-codex-app-server/new.sock",
          "app_server_pid": \(getpid())
        }
        """.utf8).write(to: newRecordURL)

        let runtimeSyncer = CapturingRuntimeSyncer()
        let monitor = AgentSessionRegistryMonitor(paths: paths,
                                                  fileManager: fileManager,
                                                  hub: AgentEventHub(),
                                                  tmuxResolver: TmuxStateResolver(ttl: 60) { _, _ in "" },
                                                  parentPIDLookup: { _ in nil },
                                                  runtimeSyncer: runtimeSyncer)
        try monitor.start()

        let session = monitor.activeSessionForPanel(workspaceID: "workspace-app-server",
                                                    panelID: "panel-app-server")
        XCTAssertEqual(session?.sessionID, "new-session")
        XCTAssertEqual(runtimeSyncer.latestRecords.map(\.sessionID), ["new-session"])
    }

    func testScanDropsLegacyCodexRecordDuplicatedByAppServerPaneAndRestoreID() throws {
        let fileManager = FileManager.default
        let supportDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("tidey-remote-bridge-monitor-\(UUID().uuidString)", isDirectory: true)
        let paths = BridgePaths(supportDirectory: supportDirectory)
        try paths.ensureSupportDirectoriesExist(fileManager: fileManager)
        defer { try? fileManager.removeItem(at: supportDirectory) }

        let restoreSessionID = "019d70fe-fd27-7a12-a3f7-9c89ae5048b6"
        let legacyRecordURL = paths.codexAgentSessionsDirectory.appendingPathComponent("codex-\(restoreSessionID).json")
        let appServerRecordURL = paths.codexAgentSessionsDirectory.appendingPathComponent("codex-instance-session.json")
        try Data("""
        {
          "version": 1,
          "vendor": "codex",
          "workspace_id": "workspace-current",
          "session_id": "\(restoreSessionID)",
          "panel_id": "panel-current",
          "pid": \(getpid()),
          "cwd": "/tmp",
          "created_at": "2026-06-07T00:00:00Z",
          "rollout_path": "/tmp/rollout-\(restoreSessionID).jsonl",
          "tmux_pane_id": "%1",
          "tmux_socket_path": "/tmp/tmux.sock"
        }
        """.utf8).write(to: legacyRecordURL)
        try Data("""
        {
          "version": 1,
          "vendor": "codex",
          "workspace_id": "workspace-current",
          "session_id": "instance-session",
          "panel_id": "panel-current",
          "pid": 999999,
          "cwd": "/tmp",
          "created_at": "2026-06-07T00:01:00Z",
          "runtime": "codex_app_server",
          "app_server_socket": "/tmp/tidey-codex-app-server/app.sock",
          "app_server_pid": \(getpid()),
          "thread_id": "\(restoreSessionID)",
          "resume_thread_id": "\(restoreSessionID)",
          "tmux_pane_id": "%1",
          "tmux_socket_path": "/tmp/tmux.sock"
        }
        """.utf8).write(to: appServerRecordURL)

        let runtimeSyncer = CapturingRuntimeSyncer()
        let monitor = AgentSessionRegistryMonitor(paths: paths,
                                                  fileManager: fileManager,
                                                  hub: AgentEventHub(),
                                                  tmuxResolver: TmuxStateResolver(ttl: 60) { _, _ in "" },
                                                  parentPIDLookup: { _ in nil },
                                                  runtimeSyncer: runtimeSyncer)
        try monitor.start()

        let snapshots = monitor.activeSessionSnapshots()
        XCTAssertEqual(snapshots.map(\.sessionID), ["instance-session"])
        XCTAssertEqual(snapshots.first?.restoreSessionID, restoreSessionID)
        XCTAssertEqual(runtimeSyncer.latestRecords.map(\.sessionID), ["instance-session"])
        XCTAssertFalse(fileManager.fileExists(atPath: legacyRecordURL.path))
    }

    func testActiveSessionForPanelKeepsAppServerInstanceWhenRemoteResumeProcessMatchesLegacyThread() throws {
        let fileManager = FileManager.default
        let supportDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("tidey-remote-bridge-monitor-\(UUID().uuidString)", isDirectory: true)
        let paths = BridgePaths(supportDirectory: supportDirectory)
        try paths.ensureSupportDirectoriesExist(fileManager: fileManager)
        defer { try? fileManager.removeItem(at: supportDirectory) }

        let restoreSessionID = "019d70fe-fd27-7a12-a3f7-9c89ae5048b6"
        let instanceSessionID = "68e6f3aa-7829-4115-ba05-6bb01c090d24"
        let wrapperPID = Int32(getpid())
        let legacyRecordURL = paths.codexAgentSessionsDirectory.appendingPathComponent("codex-\(restoreSessionID).json")
        let appServerRecordURL = paths.codexAgentSessionsDirectory.appendingPathComponent("codex-\(instanceSessionID).json")
        try Data("""
        {
          "version": 1,
          "vendor": "codex",
          "workspace_id": "workspace-current",
          "session_id": "\(restoreSessionID)",
          "panel_id": "panel-current",
          "pid": \(wrapperPID),
          "cwd": "/",
          "created_at": "2026-06-18T06:06:20Z",
          "rollout_path": "/tmp/rollout-\(restoreSessionID).jsonl",
          "tmux_pane_id": "%1",
          "tmux_socket_path": "/private/tmp/tmux-501/default"
        }
        """.utf8).write(to: legacyRecordURL)
        try Data("""
        {
          "version": 1,
          "vendor": "codex",
          "workspace_id": "workspace-current",
          "session_id": "\(instanceSessionID)",
          "panel_id": "panel-current",
          "pid": \(wrapperPID),
          "cwd": "/Users/timfeng",
          "created_at": "2026-06-10T02:39:53Z",
          "runtime": "codex_app_server",
          "app_server_socket": "/tmp/tidey-codex-app-server/app.sock",
          "app_server_pid": \(getpid()),
          "remote_tui_pid": 40556,
          "thread_id": "\(restoreSessionID)",
          "resume_thread_id": "\(restoreSessionID)",
          "tmux_pane_id": "%1",
          "tmux_socket_path": "/private/tmp/tmux-501/default"
        }
        """.utf8).write(to: appServerRecordURL)

        let runtimeSyncer = CapturingRuntimeSyncer()
        let monitor = AgentSessionRegistryMonitor(paths: paths,
                                                  fileManager: fileManager,
                                                  hub: AgentEventHub(),
                                                  tmuxResolver: TmuxStateResolver(ttl: 60) { _, _ in "" },
                                                  parentPIDLookup: { _ in nil },
                                                  descendantProcessLookup: { rootPID in
                                                      XCTAssertEqual(rootPID, wrapperPID)
                                                      return [
                                                          AgentProcessDescriptor(pid: 40556,
                                                                                 command: "/Users/timfeng/.nvm/versions/node/v24.13.0/bin/node",
                                                                                 arguments: "/Users/timfeng/.nvm/versions/node/v24.13.0/lib/node_modules/@openai/codex/bin/codex.js --remote unix:///tmp/tidey-codex-app-server/app.sock resume \(restoreSessionID)"),
                                                      ]
                                                  },
                                                  rolloutPathLookup: { _ in
                                                      XCTFail("matching app-server resume process should not synthesize a legacy rollout-backed record")
                                                      return nil
                                                  },
                                                  codexRolloutBySessionIDLookup: { _ in
                                                      XCTFail("matching app-server resume process should not resolve a legacy rollout")
                                                      return "/tmp/rollout-\(restoreSessionID).jsonl"
                                                  },
                                                  runtimeSyncer: runtimeSyncer)
        try monitor.start()

        let session = monitor.activeSessionForPanel(workspaceID: "workspace-current",
                                                    panelID: "panel-current",
                                                    effectiveShellPID: wrapperPID,
                                                    tmuxPaneID: "%1",
                                                    tmuxSocketPath: "/tmp/tmux-501/default")

        XCTAssertEqual(session?.vendor, "codex")
        XCTAssertEqual(session?.sessionID, instanceSessionID)
        XCTAssertEqual(session?.restoreSessionID, restoreSessionID)
        XCTAssertEqual(runtimeSyncer.latestRecords.map(\.sessionID), [instanceSessionID])
        XCTAssertFalse(fileManager.fileExists(atPath: legacyRecordURL.path))
    }

    func testLiveCodexDiscoveryTreatsRemoteResumeAsExistingAppServerSessionByPane() throws {
        let fileManager = FileManager.default
        let supportDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("tidey-remote-bridge-monitor-\(UUID().uuidString)", isDirectory: true)
        let paths = BridgePaths(supportDirectory: supportDirectory)
        try paths.ensureSupportDirectoriesExist(fileManager: fileManager)
        defer { try? fileManager.removeItem(at: supportDirectory) }

        let restoreSessionID = "019d70fe-fd27-7a12-a3f7-9c89ae5048b6"
        let instanceSessionID = "68e6f3aa-7829-4115-ba05-6bb01c090d24"
        let wrapperPID = Int32(getpid())
        let appServerRecordURL = paths.codexAgentSessionsDirectory.appendingPathComponent("codex-\(instanceSessionID).json")
        try Data("""
        {
          "version": 1,
          "vendor": "codex",
          "workspace_id": "stale-workspace",
          "session_id": "\(instanceSessionID)",
          "panel_id": "stale-panel",
          "pid": \(wrapperPID),
          "cwd": "/Users/timfeng",
          "created_at": "2026-06-10T02:39:53Z",
          "runtime": "codex_app_server",
          "app_server_socket": "/tmp/tidey-codex-app-server/app.sock",
          "app_server_pid": \(getpid()),
          "remote_tui_pid": 40556,
          "thread_id": "\(restoreSessionID)",
          "resume_thread_id": "\(restoreSessionID)",
          "tmux_pane_id": "%1",
          "tmux_socket_path": "/private/tmp/tmux-501/default"
        }
        """.utf8).write(to: appServerRecordURL)

        let monitor = AgentSessionRegistryMonitor(paths: paths,
                                                  fileManager: fileManager,
                                                  hub: AgentEventHub(),
                                                  tmuxResolver: TmuxStateResolver(ttl: 60) { _, _ in "" },
                                                  parentPIDLookup: { _ in nil },
                                                  descendantProcessLookup: { rootPID in
                                                      XCTAssertEqual(rootPID, wrapperPID)
                                                      return [
                                                          AgentProcessDescriptor(pid: 40556,
                                                                                 command: "/Users/timfeng/.nvm/versions/node/v24.13.0/bin/node",
                                                                                 arguments: "/Users/timfeng/.nvm/versions/node/v24.13.0/lib/node_modules/@openai/codex/bin/codex.js --remote unix:///tmp/tidey-codex-app-server/app.sock resume \(restoreSessionID)"),
                                                      ]
                                                  },
                                                  rolloutPathLookup: { _ in
                                                      XCTFail("matching app-server resume process should not synthesize a legacy rollout-backed record")
                                                      return nil
                                                  },
                                                  codexRolloutBySessionIDLookup: { _ in
                                                      XCTFail("matching app-server resume process should not resolve a legacy rollout")
                                                      return "/tmp/rollout-\(restoreSessionID).jsonl"
                                                  })
        try monitor.start()

        let session = monitor.activeSessionForPanel(workspaceID: "current-workspace",
                                                    panelID: "current-panel",
                                                    effectiveShellPID: wrapperPID,
                                                    tmuxPaneID: "%1",
                                                    tmuxSocketPath: "/tmp/tmux-501/default")

        XCTAssertEqual(session?.vendor, "codex")
        XCTAssertEqual(session?.sessionID, instanceSessionID)
        XCTAssertEqual(session?.workspaceID, "current-workspace")
        XCTAssertEqual(session?.panelID, "current-panel")
        XCTAssertFalse(fileManager.fileExists(atPath: paths.codexAgentSessionsDirectory.appendingPathComponent("codex-\(restoreSessionID).json").path))
    }

    func testCanonicalAgentEventSessionIDAliasesLegacyThreadToAppServerInstance() throws {
        let fileManager = FileManager.default
        let supportDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("tidey-remote-bridge-monitor-\(UUID().uuidString)", isDirectory: true)
        let paths = BridgePaths(supportDirectory: supportDirectory)
        try paths.ensureSupportDirectoriesExist(fileManager: fileManager)
        defer { try? fileManager.removeItem(at: supportDirectory) }

        let threadID = "019d70fe-fd27-7a12-a3f7-9c89ae5048b6"
        let resumeThreadID = "019e21cf-fd27-7a12-a3f7-9c89ae5048b6"
        let instanceSessionID = "68e6f3aa-7829-4115-ba05-6bb01c090d24"
        let legacyRecordURL = paths.codexAgentSessionsDirectory.appendingPathComponent("codex-\(threadID).json")
        try Data("""
        {
          "version": 1,
          "vendor": "codex",
          "workspace_id": "workspace-current",
          "session_id": "\(threadID)",
          "panel_id": "panel-current",
          "pid": \(getpid()),
          "cwd": "/",
          "created_at": "2026-06-18T06:06:20Z",
          "rollout_path": "/tmp/rollout-\(threadID).jsonl",
          "tmux_pane_id": "%1",
          "tmux_socket_path": "/tmp/tmux-501/default"
        }
        """.utf8).write(to: legacyRecordURL)
        try Data("""
        {
          "version": 1,
          "vendor": "codex",
          "workspace_id": "workspace-current",
          "session_id": "\(instanceSessionID)",
          "panel_id": "panel-current",
          "pid": \(getpid()),
          "cwd": "/Users/timfeng",
          "created_at": "2026-06-10T02:39:53Z",
          "runtime": "codex_app_server",
          "app_server_socket": "/tmp/tidey-codex-app-server/app.sock",
          "app_server_pid": \(getpid()),
          "thread_id": "\(threadID)",
          "resume_thread_id": "\(resumeThreadID)",
          "tmux_pane_id": "%1",
          "tmux_socket_path": "/tmp/tmux-501/default"
        }
        """.utf8).write(to: paths.codexAgentSessionsDirectory.appendingPathComponent("codex-\(instanceSessionID).json"))

        let monitor = AgentSessionRegistryMonitor(paths: paths,
                                                  fileManager: fileManager,
                                                  hub: AgentEventHub(),
                                                  tmuxResolver: TmuxStateResolver(ttl: 60) { _, _ in "" },
                                                  parentPIDLookup: { _ in nil })
        try monitor.start()

        XCTAssertEqual(monitor.canonicalSessionIDForAgentEvents(threadID), instanceSessionID)
        XCTAssertEqual(monitor.canonicalSessionIDForAgentEvents(resumeThreadID), instanceSessionID)
        XCTAssertEqual(monitor.canonicalSessionIDForAgentEvents(instanceSessionID), instanceSessionID)
        XCTAssertEqual(monitor.canonicalSessionIDForAgentEvents("unrelated-session"), "unrelated-session")
        XCTAssertNil(monitor.canonicalSessionIDForAgentEvents(nil))
    }

    func testLegacyThreadAliasSubscriptionReceivesAppServerInstanceEvent() throws {
        let fileManager = FileManager.default
        let supportDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("tidey-remote-bridge-monitor-\(UUID().uuidString)", isDirectory: true)
        let paths = BridgePaths(supportDirectory: supportDirectory)
        try paths.ensureSupportDirectoriesExist(fileManager: fileManager)
        defer { try? fileManager.removeItem(at: supportDirectory) }

        let threadID = "019d70fe-fd27-7a12-a3f7-9c89ae5048b6"
        let instanceSessionID = "68e6f3aa-7829-4115-ba05-6bb01c090d24"
        try Data("""
        {
          "version": 1,
          "vendor": "codex",
          "workspace_id": "workspace-current",
          "session_id": "\(instanceSessionID)",
          "panel_id": "panel-current",
          "pid": \(getpid()),
          "cwd": "/Users/timfeng",
          "created_at": "2026-06-10T02:39:53Z",
          "runtime": "codex_app_server",
          "app_server_socket": "/tmp/tidey-codex-app-server/app.sock",
          "app_server_pid": \(getpid()),
          "thread_id": "\(threadID)",
          "resume_thread_id": "\(threadID)",
          "tmux_pane_id": "%1",
          "tmux_socket_path": "/tmp/tmux-501/default"
        }
        """.utf8).write(to: paths.codexAgentSessionsDirectory.appendingPathComponent("codex-\(instanceSessionID).json"))

        let hub = AgentEventHub()
        let monitor = AgentSessionRegistryMonitor(paths: paths,
                                                  fileManager: fileManager,
                                                  hub: hub,
                                                  tmuxResolver: TmuxStateResolver(ttl: 60) { _, _ in "" },
                                                  parentPIDLookup: { _ in nil })
        try monitor.start()

        let canonicalSessionID = monitor.canonicalSessionIDForAgentEvents(threadID)
        var receivedEvents = [AgentEvent]()
        _ = hub.subscribe(workspaceID: "workspace-current",
                          sessionID: canonicalSessionID,
                          sinceSeq: nil) { envelope in
            receivedEvents.append(envelope.event)
        }
        hub.publish(AgentEvent(eventID: "app-server-event",
                               seq: 42,
                               vendor: "codex",
                               workspaceID: "workspace-current",
                               sessionID: instanceSessionID,
                               timestamp: "2026-06-18T06:06:21Z",
                               type: .assistantMessage,
                               role: "assistant",
                               text: "live",
                               name: nil,
                               input: nil,
                               output: nil,
                               toolCallID: nil,
                               metadata: ["panel_id": "panel-current"]))

        XCTAssertEqual(canonicalSessionID, instanceSessionID)
        XCTAssertEqual(receivedEvents.map(\.sessionID), [instanceSessionID])
        XCTAssertEqual(receivedEvents.first?.text, "live")
    }

    func testActiveSessionForPanelFallsBackToTmuxPaneMatchWhenPanelIDsChanged() throws {
        let fileManager = FileManager.default
        let supportDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("tidey-remote-bridge-monitor-\(UUID().uuidString)", isDirectory: true)
        let paths = BridgePaths(supportDirectory: supportDirectory)
        try paths.ensureSupportDirectoriesExist(fileManager: fileManager)
        defer { try? fileManager.removeItem(at: supportDirectory) }

        let registryURL = paths.claudeAgentSessionsDirectory.appendingPathComponent("claude-session-1.json")
        let recordData = Data("""
        {
          "version": 1,
          "vendor": "claude",
          "workspace_id": "stale-workspace",
          "session_id": "session-1",
          "panel_id": "stale-panel",
          "pid": \(getpid()),
          "cwd": "/tmp",
          "created_at": "2026-04-15T00:00:00Z",
          "tmux_pane_id": "%42",
          "tmux_socket_path": "/tmp/tmux.sock"
        }
        """.utf8)
        try recordData.write(to: registryURL)

        let tmuxResolver = TmuxStateResolver(ttl: 60) { socketPath, arguments in
            XCTAssertEqual(socketPath, "/tmp/tmux.sock")
            if arguments.first == "list-panes" {
                return "%42|cc\n"
            }
            return "12345|cc\n"
        }
        let monitor = AgentSessionRegistryMonitor(paths: paths,
                                                  fileManager: fileManager,
                                                  hub: AgentEventHub(),
                                                  tmuxResolver: tmuxResolver,
                                                  parentPIDLookup: { pid in
                                                      switch pid {
                                                      case 12345:
                                                          return 999
                                                      case 999:
                                                          return nil
                                                      default:
                                                          return nil
                                                      }
                                                  })
        try monitor.start()

        let session = monitor.activeSessionForPanel(workspaceID: "new-workspace",
                                                    panelID: "new-panel",
                                                    effectiveShellPID: 12345)
        XCTAssertEqual(session?.vendor, "claude")
        XCTAssertEqual(session?.sessionID, "session-1")
        XCTAssertEqual(session?.workspaceID, "new-workspace")
        XCTAssertEqual(session?.panelID, "new-panel")
    }

    func testActiveSessionForPanelMatchesWhenShellPidIsAncestorOfTmuxClient() throws {
        let fileManager = FileManager.default
        let supportDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("tidey-remote-bridge-monitor-\(UUID().uuidString)", isDirectory: true)
        let paths = BridgePaths(supportDirectory: supportDirectory)
        try paths.ensureSupportDirectoriesExist(fileManager: fileManager)
        defer { try? fileManager.removeItem(at: supportDirectory) }

        let registryURL = paths.claudeAgentSessionsDirectory.appendingPathComponent("claude-session-plain-attach.json")
        let recordData = Data("""
        {
          "version": 1,
          "vendor": "claude",
          "workspace_id": "stale-workspace",
          "session_id": "session-plain-attach",
          "panel_id": "stale-panel",
          "pid": \(getpid()),
          "cwd": "/tmp",
          "created_at": "2026-04-15T00:00:00Z",
          "tmux_pane_id": "%17",
          "tmux_socket_path": "/tmp/tmux.sock"
        }
        """.utf8)
        try recordData.write(to: registryURL)

        let tmuxResolver = TmuxStateResolver(ttl: 60) { socketPath, arguments in
            XCTAssertEqual(socketPath, "/tmp/tmux.sock")
            if arguments.first == "list-panes" {
                return "%17|tidey-remote-cc\n"
            }
            return "41907|tidey-remote-cc\n"
        }
        let monitor = AgentSessionRegistryMonitor(paths: paths,
                                                  fileManager: fileManager,
                                                  hub: AgentEventHub(),
                                                  tmuxResolver: tmuxResolver,
                                                  parentPIDLookup: { pid in
                                                      switch pid {
                                                      case 41907:
                                                          return 41163
                                                      case 41163:
                                                          return 1
                                                      default:
                                                          return nil
                                                      }
                                                  })
        try monitor.start()

        let session = monitor.activeSessionForPanel(workspaceID: "new-workspace",
                                                    panelID: "new-panel",
                                                    effectiveShellPID: 41163)
        XCTAssertEqual(session?.sessionID, "session-plain-attach")
        XCTAssertEqual(session?.panelID, "new-panel")
        let workspaceSession = monitor.activeSessionForWorkspace(workspaceID: "new-workspace")
        XCTAssertEqual(workspaceSession?.sessionID, "session-plain-attach")
        XCTAssertEqual(workspaceSession?.workspaceID, "new-workspace")
        XCTAssertEqual(workspaceSession?.panelID, "new-panel")
    }

    func testActiveSessionForOrdinaryTmuxLogicalPanelMatchesRunningAgentByPaneProcess() throws {
        let fileManager = FileManager.default
        let supportDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("tidey-remote-bridge-monitor-\(UUID().uuidString)", isDirectory: true)
        let paths = BridgePaths(supportDirectory: supportDirectory)
        try paths.ensureSupportDirectoriesExist(fileManager: fileManager)
        defer { try? fileManager.removeItem(at: supportDirectory) }

        let agentPID = Int32(getpid())
        let registryURL = paths.claudeAgentSessionsDirectory.appendingPathComponent("claude-session-priest.json")
        let recordData = Data("""
        {
          "version": 1,
          "vendor": "claude",
          "workspace_id": "stale-workspace",
          "session_id": "session-priest",
          "panel_id": "stale-panel",
          "pid": \(agentPID),
          "cwd": "/Users/timfeng/GitHub/priest",
          "created_at": "2026-04-15T00:00:00Z",
          "tmux_pane_id": "%15",
          "tmux_socket_path": "/private/tmp/tmux-501/default"
        }
        """.utf8)
        try recordData.write(to: registryURL)

        let monitor = AgentSessionRegistryMonitor(paths: paths,
                                                  fileManager: fileManager,
                                                  hub: AgentEventHub(),
                                                  tmuxResolver: TmuxStateResolver(ttl: 60) { _, _ in "" },
                                                  parentPIDLookup: { pid in
                                                      switch pid {
                                                      case agentPID:
                                                          return 5000
                                                      case 5000:
                                                          return 1
                                                      default:
                                                          return nil
                                                      }
                                                  })
        try monitor.start()

        let session = monitor.activeSessionForPanel(workspaceID: "current-workspace",
                                                    panelID: "ordinary-tmux:/tmp/tmux-501/default:$13:@15",
                                                    effectiveShellPID: 5000,
                                                    tmuxPaneID: "%15",
                                                    tmuxSocketPath: "/tmp/tmux-501/default")

        XCTAssertEqual(session?.vendor, "claude")
        XCTAssertEqual(session?.sessionID, "session-priest")
        XCTAssertEqual(session?.workspaceID, "current-workspace")
        XCTAssertEqual(session?.panelID, "ordinary-tmux:/tmp/tmux-501/default:$13:@15")
    }

    func testActiveSessionForSingleWindowCarrierMatchesCodexByPaneProcess() throws {
        let fileManager = FileManager.default
        let supportDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("tidey-remote-bridge-monitor-\(UUID().uuidString)", isDirectory: true)
        let paths = BridgePaths(supportDirectory: supportDirectory)
        try paths.ensureSupportDirectoriesExist(fileManager: fileManager)
        defer { try? fileManager.removeItem(at: supportDirectory) }

        let agentPID = Int32(getpid())
        let registryURL = paths.codexAgentSessionsDirectory.appendingPathComponent("codex-session-adbrewer.json")
        let recordData = Data("""
        {
          "version": 1,
          "vendor": "codex",
          "workspace_id": "stale-workspace",
          "session_id": "session-adbrewer",
          "panel_id": "stale-panel",
          "pid": \(agentPID),
          "cwd": "/Users/timfeng/GitHub/adbrewer",
          "created_at": "2026-04-15T00:00:00Z",
          "tmux_pane_id": "%43",
          "tmux_socket_path": "/private/tmp/tmux-501/default"
        }
        """.utf8)
        try recordData.write(to: registryURL)

        let monitor = AgentSessionRegistryMonitor(paths: paths,
                                                  fileManager: fileManager,
                                                  hub: AgentEventHub(),
                                                  tmuxResolver: TmuxStateResolver(ttl: 60) { _, _ in "" },
                                                  parentPIDLookup: { pid in
                                                      switch pid {
                                                      case agentPID:
                                                          return 82923
                                                      case 82923:
                                                          return 1
                                                      default:
                                                          return nil
                                                      }
                                                  })
        try monitor.start()

        let session = monitor.activeSessionForPanel(workspaceID: "current-workspace",
                                                    panelID: "carrier-panel",
                                                    effectiveShellPID: 82923,
                                                    tmuxPaneID: "%43",
                                                    tmuxSocketPath: "/tmp/tmux-501/default")

        XCTAssertEqual(session?.vendor, "codex")
        XCTAssertEqual(session?.sessionID, "session-adbrewer")
        XCTAssertEqual(session?.workspaceID, "current-workspace")
        XCTAssertEqual(session?.panelID, "carrier-panel")
    }

    func testActiveSessionForSingleWindowCarrierSynthesizesCodexRecordFromLiveProcess() throws {
        let fileManager = FileManager.default
        let supportDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("tidey-remote-bridge-monitor-\(UUID().uuidString)", isDirectory: true)
        let paths = BridgePaths(supportDirectory: supportDirectory)
        try paths.ensureSupportDirectoriesExist(fileManager: fileManager)
        defer { try? fileManager.removeItem(at: supportDirectory) }

        let sessionID = "11111111-2222-3333-4444-555555555555"
        let rolloutURL = supportDirectory
            .appendingPathComponent(".codex/sessions/2026/05/13", isDirectory: true)
            .appendingPathComponent("rollout-2026-05-13T00-00-00-\(sessionID).jsonl", isDirectory: false)
        try fileManager.createDirectory(at: rolloutURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("[]\n".utf8).write(to: rolloutURL)

        let codexPID = Int32(getpid())
        let monitor = AgentSessionRegistryMonitor(paths: paths,
                                                  fileManager: fileManager,
                                                  hub: AgentEventHub(),
                                                  tmuxResolver: TmuxStateResolver(ttl: 60) { _, _ in "" },
                                                  parentPIDLookup: { _ in nil },
                                                  descendantProcessLookup: { rootPID in
                                                      XCTAssertTrue(rootPID == 82923 || rootPID == getpid())
                                                      return [
                                                          AgentProcessDescriptor(pid: 95759,
                                                                                 command: "/Users/timfeng/.nvm/versions/node/v24.13.0/bin/node",
                                                                                 arguments: "/Users/timfeng/.nvm/versions/node/v24.13.0/lib/node_modules/@openai/codex/bin/codex.js resume \(sessionID)"),
                                                          AgentProcessDescriptor(pid: codexPID,
                                                                                 command: "/Users/timfeng/.nvm/versions/node/v24.13.0/lib/node_modules/@openai/codex/vendor/darwin-arm64/codex",
                                                                                 arguments: "codex"),
                                                      ]
                                                  },
                                                  rolloutPathLookup: { _ in
                                                      XCTFail("process resume session should avoid lsof rollout fallback")
                                                      return nil
                                                  },
                                                  codexRolloutBySessionIDLookup: { sessionID in
                                                      sessionID == "11111111-2222-3333-4444-555555555555" ? rolloutURL.path : nil
                                                  })
        try monitor.start()

        let session = monitor.activeSessionForPanel(workspaceID: "current-workspace",
                                                    panelID: "carrier-panel",
                                                    effectiveShellPID: 82923,
                                                    tmuxPaneID: "%43",
                                                    tmuxSocketPath: "/private/tmp/tmux-501/default")

        XCTAssertEqual(session?.vendor, "codex")
        XCTAssertEqual(session?.sessionID, sessionID)
        XCTAssertEqual(session?.workspaceID, "current-workspace")
        XCTAssertEqual(session?.panelID, "carrier-panel")

        let registryURL = paths.codexAgentSessionsDirectory.appendingPathComponent("codex-\(sessionID).json")
        let registryData = try Data(contentsOf: registryURL)
        let record = try JSONDecoder().decode(AgentSessionRegistryRecord.self, from: registryData)
        XCTAssertEqual(record.vendor, "codex")
        XCTAssertEqual(record.workspaceID, "current-workspace")
        XCTAssertEqual(record.panelID, "carrier-panel")
        XCTAssertEqual(record.pid, 95759)
        XCTAssertEqual(record.tmuxPaneID, "%43")
        XCTAssertEqual(record.tmuxSocketPath, "/private/tmp/tmux-501/default")
        XCTAssertEqual(record.transcriptPath, rolloutURL.path)

        let subsequent = monitor.activeSessionForPanel(workspaceID: "current-workspace",
                                                       panelID: "carrier-panel",
                                                       effectiveShellPID: 82923,
                                                       tmuxPaneID: "%43",
                                                       tmuxSocketPath: "/private/tmp/tmux-501/default")
        XCTAssertEqual(subsequent?.sessionID, sessionID)
    }

    func testActiveSessionForSingleWindowCarrierPrefersCodexProcessResumeOverSubagentRecord() throws {
        let fileManager = FileManager.default
        let supportDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("tidey-remote-bridge-monitor-\(UUID().uuidString)", isDirectory: true)
        let paths = BridgePaths(supportDirectory: supportDirectory)
        try paths.ensureSupportDirectoriesExist(fileManager: fileManager)
        defer { try? fileManager.removeItem(at: supportDirectory) }

        let parentSessionID = "11111111-2222-3333-4444-555555555555"
        let subagentSessionID = "99999999-8888-7777-6666-555555555555"
        let parentRolloutURL = supportDirectory
            .appendingPathComponent(".codex/sessions/2026/05/22", isDirectory: true)
            .appendingPathComponent("rollout-2026-05-22T00-00-00-\(parentSessionID).jsonl", isDirectory: false)
        try fileManager.createDirectory(at: parentRolloutURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("[]\n".utf8).write(to: parentRolloutURL)

        let staleRegistryURL = paths.codexAgentSessionsDirectory.appendingPathComponent("codex-\(subagentSessionID).json")
        let staleRecordData = Data("""
        {
          "version": 1,
          "vendor": "codex",
          "workspace_id": "current-workspace",
          "session_id": "\(subagentSessionID)",
          "panel_id": "carrier-panel",
          "pid": \(getpid()),
          "cwd": "/Users/timfeng",
          "created_at": "2026-05-22T01:00:00Z",
          "rollout_path": "/Users/timfeng/.codex/sessions/2026/05/22/rollout-2026-05-22T01-00-00-\(subagentSessionID).jsonl",
          "tmux_pane_id": "%43",
          "tmux_socket_path": "/private/tmp/tmux-501/default"
        }
        """.utf8)
        try staleRecordData.write(to: staleRegistryURL)

        let monitor = AgentSessionRegistryMonitor(paths: paths,
                                                  fileManager: fileManager,
                                                  hub: AgentEventHub(),
                                                  tmuxResolver: TmuxStateResolver(ttl: 60) { _, _ in "" },
                                                  parentPIDLookup: { _ in nil },
                                                  descendantProcessLookup: { rootPID in
                                                      XCTAssertTrue([82923, getpid(), 95759].contains(rootPID))
                                                      return [
                                                          AgentProcessDescriptor(pid: 95759,
                                                                                 command: "/Users/timfeng/.nvm/versions/node/v24.13.0/bin/node",
                                                                                 arguments: "/Users/timfeng/.nvm/versions/node/v24.13.0/lib/node_modules/@openai/codex/bin/codex.js resume \(parentSessionID)")
                                                      ]
                                                  },
                                                  rolloutPathLookup: { _ in
                                                      XCTFail("stale subagent direct record should be corrected without lsof fallback")
                                                      return nil
                                                  },
                                                  codexRolloutBySessionIDLookup: { sessionID in
                                                      sessionID == parentSessionID ? parentRolloutURL.path : nil
                                                  })
        try monitor.start()

        let session = monitor.activeSessionForPanel(workspaceID: "current-workspace",
                                                    panelID: "carrier-panel",
                                                    effectiveShellPID: 82923,
                                                    tmuxPaneID: "%43",
                                                    tmuxSocketPath: "/private/tmp/tmux-501/default")

        XCTAssertEqual(session?.vendor, "codex")
        XCTAssertEqual(session?.sessionID, parentSessionID)
        XCTAssertEqual(session?.workspaceID, "current-workspace")
        XCTAssertEqual(session?.panelID, "carrier-panel")

        let parentRegistryURL = paths.codexAgentSessionsDirectory.appendingPathComponent("codex-\(parentSessionID).json")
        XCTAssertTrue(fileManager.fileExists(atPath: parentRegistryURL.path))

        let subsequent = monitor.activeSessionForPanel(workspaceID: "current-workspace",
                                                       panelID: "carrier-panel")
        XCTAssertEqual(subsequent?.sessionID, parentSessionID)
    }

    func testActiveSessionForSingleWindowCarrierUsesStaleCodexRecordPaneContextWhenPanelSummaryLacksEnrichment() throws {
        let fileManager = FileManager.default
        let supportDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("tidey-remote-bridge-monitor-\(UUID().uuidString)", isDirectory: true)
        let paths = BridgePaths(supportDirectory: supportDirectory)
        try paths.ensureSupportDirectoriesExist(fileManager: fileManager)
        defer { try? fileManager.removeItem(at: supportDirectory) }

        let parentSessionID = "11111111-2222-3333-4444-555555555555"
        let subagentSessionID = "99999999-8888-7777-6666-555555555555"
        let parentRolloutURL = supportDirectory
            .appendingPathComponent(".codex/sessions/2026/05/22", isDirectory: true)
            .appendingPathComponent("rollout-2026-05-22T00-00-00-\(parentSessionID).jsonl", isDirectory: false)
        try fileManager.createDirectory(at: parentRolloutURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("[]\n".utf8).write(to: parentRolloutURL)

        let staleRegistryURL = paths.codexAgentSessionsDirectory.appendingPathComponent("codex-\(subagentSessionID).json")
        let staleRecordData = Data("""
        {
          "version": 1,
          "vendor": "codex",
          "workspace_id": "current-workspace",
          "session_id": "\(subagentSessionID)",
          "panel_id": "carrier-panel",
          "pid": \(getpid()),
          "cwd": "/Users/timfeng",
          "created_at": "2026-05-22T01:00:00Z",
          "rollout_path": "/Users/timfeng/.codex/sessions/2026/05/22/rollout-2026-05-22T01-00-00-\(subagentSessionID).jsonl",
          "tmux_pane_id": "%43",
          "tmux_socket_path": "/private/tmp/tmux-501/default"
        }
        """.utf8)
        try staleRecordData.write(to: staleRegistryURL)

        let monitor = AgentSessionRegistryMonitor(paths: paths,
                                                  fileManager: fileManager,
                                                  hub: AgentEventHub(),
                                                  tmuxResolver: TmuxStateResolver(ttl: 60) { _, _ in "" },
                                                  parentPIDLookup: { _ in nil },
                                                  descendantProcessLookup: { rootPID in
                                                      XCTAssertEqual(rootPID, getpid())
                                                      return [
                                                          AgentProcessDescriptor(pid: 95759,
                                                                                 command: "/Users/timfeng/.nvm/versions/node/v24.13.0/bin/node",
                                                                                 arguments: "/Users/timfeng/.nvm/versions/node/v24.13.0/lib/node_modules/@openai/codex/bin/codex.js resume \(parentSessionID)")
                                                      ]
                                                  },
                                                  rolloutPathLookup: { _ in
                                                      XCTFail("stale direct record should be corrected from process resume without lsof fallback")
                                                      return nil
                                                  },
                                                  codexRolloutBySessionIDLookup: { sessionID in
                                                      sessionID == parentSessionID ? parentRolloutURL.path : nil
                                                  })
        try monitor.start()

        let session = monitor.activeSessionForPanel(workspaceID: "current-workspace",
                                                    panelID: "carrier-panel")

        XCTAssertEqual(session?.vendor, "codex")
        XCTAssertEqual(session?.sessionID, parentSessionID)

        let parentRegistryURL = paths.codexAgentSessionsDirectory.appendingPathComponent("codex-\(parentSessionID).json")
        XCTAssertTrue(fileManager.fileExists(atPath: parentRegistryURL.path))
    }

    func testActiveSessionForSingleWindowCarrierDoesNotSynthesizeWithoutCodexProcess() throws {
        let fileManager = FileManager.default
        let supportDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("tidey-remote-bridge-monitor-\(UUID().uuidString)", isDirectory: true)
        let paths = BridgePaths(supportDirectory: supportDirectory)
        try paths.ensureSupportDirectoriesExist(fileManager: fileManager)
        defer { try? fileManager.removeItem(at: supportDirectory) }

        let monitor = AgentSessionRegistryMonitor(paths: paths,
                                                  fileManager: fileManager,
                                                  hub: AgentEventHub(),
                                                  tmuxResolver: TmuxStateResolver(ttl: 60) { _, _ in "" },
                                                  parentPIDLookup: { _ in nil },
                                                  descendantProcessLookup: { rootPID in
                                                      XCTAssertEqual(rootPID, 82923)
                                                      return [
                                                          AgentProcessDescriptor(pid: Int32(getpid()),
                                                                                 command: "/bin/zsh",
                                                                                 arguments: "-zsh"),
                                                      ]
                                                  },
                                                  rolloutPathLookup: { _ in
                                                      XCTFail("rollout lookup should not run without a codex process")
                                                      return nil
                                                  })
        try monitor.start()

        let session = monitor.activeSessionForPanel(workspaceID: "current-workspace",
                                                    panelID: "carrier-panel",
                                                    effectiveShellPID: 82923,
                                                    tmuxPaneID: "%43",
                                                    tmuxSocketPath: "/private/tmp/tmux-501/default")

        XCTAssertNil(session)
    }

    func testActiveSessionForSingleWindowCarrierDoesNotSynthesizeCodexWithoutRollout() throws {
        let fileManager = FileManager.default
        let supportDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("tidey-remote-bridge-monitor-\(UUID().uuidString)", isDirectory: true)
        let paths = BridgePaths(supportDirectory: supportDirectory)
        try paths.ensureSupportDirectoriesExist(fileManager: fileManager)
        defer { try? fileManager.removeItem(at: supportDirectory) }

        let monitor = AgentSessionRegistryMonitor(paths: paths,
                                                  fileManager: fileManager,
                                                  hub: AgentEventHub(),
                                                  tmuxResolver: TmuxStateResolver(ttl: 60) { _, _ in "" },
                                                  parentPIDLookup: { _ in nil },
                                                  descendantProcessLookup: { _ in
                                                      [
                                                          AgentProcessDescriptor(pid: Int32(getpid()),
                                                                                 command: "/Users/timfeng/.nvm/versions/node/v24.13.0/bin/node",
                                                                                 arguments: "/Users/timfeng/.nvm/versions/node/v24.13.0/lib/node_modules/@openai/codex/bin/codex.js"),
                                                      ]
                                                  },
                                                  rolloutPathLookup: { _ in nil })
        try monitor.start()

        let session = monitor.activeSessionForPanel(workspaceID: "current-workspace",
                                                    panelID: "carrier-panel",
                                                    effectiveShellPID: 82923,
                                                    tmuxPaneID: "%43",
                                                    tmuxSocketPath: "/private/tmp/tmux-501/default")

        XCTAssertNil(session)
        let files = try fileManager.contentsOfDirectory(atPath: paths.codexAgentSessionsDirectory.path)
        XCTAssertTrue(files.isEmpty)
    }

    func testActiveSessionForPanelImmediatelyMigratesBufferedEventsToCurrentIDs() throws {
        let fileManager = FileManager.default
        let supportDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("tidey-remote-bridge-monitor-\(UUID().uuidString)", isDirectory: true)
        let paths = BridgePaths(supportDirectory: supportDirectory)
        try paths.ensureSupportDirectoriesExist(fileManager: fileManager)
        defer { try? fileManager.removeItem(at: supportDirectory) }

        let registryURL = paths.claudeAgentSessionsDirectory.appendingPathComponent("claude-session-buffered.json")
        let recordData = Data("""
        {
          "version": 1,
          "vendor": "claude",
          "workspace_id": "stale-workspace",
          "session_id": "session-buffered",
          "panel_id": "stale-panel",
          "pid": \(getpid()),
          "cwd": "/tmp",
          "created_at": "2026-04-15T00:00:00Z",
          "tmux_pane_id": "%17",
          "tmux_socket_path": "/tmp/tmux.sock"
        }
        """.utf8)
        try recordData.write(to: registryURL)

        let hub = AgentEventHub()
        let monitor = AgentSessionRegistryMonitor(paths: paths,
                                                  fileManager: fileManager,
                                                  hub: hub,
                                                  tmuxResolver: TmuxStateResolver(ttl: 60) { _, arguments in
                                                      if arguments.first == "list-panes" {
                                                          return "%17|tidey-remote-cc\n"
                                                      }
                                                      return "41907|tidey-remote-cc\n"
                                                  },
                                                  parentPIDLookup: { pid in
                                                      switch pid {
                                                      case 41907:
                                                          return 41163
                                                      case 41163:
                                                          return 1
                                                      default:
                                                          return nil
                                                      }
                                                  })
        try monitor.start()

        hub.publish(AgentEvent(eventID: "assistant-buffered",
                               seq: 100,
                               vendor: "claude",
                               workspaceID: "stale-workspace",
                               sessionID: "session-buffered",
                               timestamp: "2026-04-15T00:00:01Z",
                               type: .assistantMessage,
                               role: "assistant",
                               text: "hello",
                               name: nil,
                               input: nil,
                               output: nil,
                               toolCallID: nil,
                               metadata: nil))

        let session = monitor.activeSessionForPanel(workspaceID: "new-workspace",
                                                    panelID: "new-panel",
                                                    effectiveShellPID: 41163)
        XCTAssertEqual(session?.sessionID, "session-buffered")

        let fetched = hub.fetch(workspaceID: "new-workspace",
                                sessionID: "session-buffered",
                                limit: 10,
                                beforeSeq: nil,
                                afterSeq: nil)
        XCTAssertFalse(fetched.events.isEmpty)
        XCTAssertTrue(fetched.events.allSatisfy { $0.workspaceID == "new-workspace" })
        XCTAssertTrue(fetched.events.contains { $0.metadata?["panel_id"] == "new-panel" })
    }

    func testDirectPanelMatchAlsoAppliesResolvedBindingToBufferedEvents() throws {
        let fileManager = FileManager.default
        let supportDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("tidey-remote-bridge-monitor-\(UUID().uuidString)", isDirectory: true)
        let paths = BridgePaths(supportDirectory: supportDirectory)
        try paths.ensureSupportDirectoriesExist(fileManager: fileManager)
        defer { try? fileManager.removeItem(at: supportDirectory) }

        let registryURL = paths.claudeAgentSessionsDirectory.appendingPathComponent("claude-session-direct.json")
        let recordData = Data("""
        {
          "version": 1,
          "vendor": "claude",
          "workspace_id": "current-workspace",
          "session_id": "session-direct",
          "panel_id": "current-panel",
          "pid": \(getpid()),
          "cwd": "/tmp",
          "created_at": "2026-04-15T00:00:00Z"
        }
        """.utf8)
        try recordData.write(to: registryURL)

        let hub = AgentEventHub()
        let monitor = AgentSessionRegistryMonitor(paths: paths,
                                                  fileManager: fileManager,
                                                  hub: hub,
                                                  tmuxResolver: TmuxStateResolver(ttl: 60) { _, _ in "" },
                                                  parentPIDLookup: { _ in nil })
        try monitor.start()

        hub.publish(AgentEvent(eventID: "assistant-direct",
                               seq: 100,
                               vendor: "claude",
                               workspaceID: "stale-workspace",
                               sessionID: "session-direct",
                               timestamp: "2026-04-15T00:00:01Z",
                               type: .assistantMessage,
                               role: "assistant",
                               text: "hello",
                               name: nil,
                               input: nil,
                               output: nil,
                               toolCallID: nil,
                               metadata: nil))

        let session = monitor.activeSessionForPanel(workspaceID: "current-workspace",
                                                    panelID: "current-panel",
                                                    effectiveShellPID: nil)
        XCTAssertEqual(session?.sessionID, "session-direct")

        let fetched = hub.fetch(workspaceID: "current-workspace",
                                sessionID: "session-direct",
                                limit: 10,
                                beforeSeq: nil,
                                afterSeq: nil)
        XCTAssertFalse(fetched.events.isEmpty)
        XCTAssertTrue(fetched.events.allSatisfy { $0.workspaceID == "current-workspace" })
    }

    private func writeRegistryRecord(_ url: URL,
                                     vendor: String,
                                     workspaceID: String,
                                     sessionID: String,
                                     panelID: String,
                                     paneID: String,
                                     socketPath: String = "/tmp/tmux.sock") throws {
        let recordData = Data("""
        {
          "version": 1,
          "vendor": "\(vendor)",
          "workspace_id": "\(workspaceID)",
          "session_id": "\(sessionID)",
          "panel_id": "\(panelID)",
          "pid": \(getpid()),
          "cwd": "/tmp",
          "created_at": "2026-05-21T00:00:00Z",
          "tmux_pane_id": "\(paneID)",
          "tmux_socket_path": "\(socketPath)"
        }
        """.utf8)
        try recordData.write(to: url)
    }

    private func makeCodexMessageLine(role: String, content: String) -> String {
        let object: [String: Any] = [
            "type": "response_item",
            "timestamp": "2026-06-08T22:06:25Z",
            "payload": [
                "type": "message",
                "role": role,
                "content": [
                    [
                        "type": role == "user" ? "input_text" : "output_text",
                        "text": content,
                    ],
                ],
            ],
        ]
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(data: data, encoding: .utf8)!
    }

    private func waitUntil(timeout: TimeInterval = 2,
                           condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return true
            }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        return condition()
    }

    private func acknowledgeCodexAppServerInitialize(from transport: FakeCodexAppServerConnectionTransport,
                                                     file: StaticString = #filePath,
                                                     line sourceLine: UInt = #line) throws {
        let initialize = try jsonObject(from: try XCTUnwrap(transport.sentLines().first,
                                                            file: file,
                                                            line: sourceLine),
                                        file: file,
                                        line: sourceLine)
        transport.emitLine(try jsonResponseText(id: try XCTUnwrap(initialize["id"],
                                                                   file: file,
                                                                   line: sourceLine),
                                                result: .object([
                                                    "serverInfo": .object([
                                                        "name": .string("codex"),
                                                        "version": .string("test"),
                                                    ]),
                                                    "capabilities": .object([:]),
                                                ])))
    }

    private func jsonObject(from line: String,
                            file: StaticString = #filePath,
                            line sourceLine: UInt = #line) throws -> [String: JSONValue] {
        let data = try XCTUnwrap(line.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
                                 file: file,
                                 line: sourceLine)
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        return try XCTUnwrap(value.objectValue, file: file, line: sourceLine)
    }

    private func jsonResponseText(id: JSONValue, result: JSONValue) throws -> String {
        let idData = try JSONEncoder().encode(id)
        let idText = String(decoding: idData, as: UTF8.self)
        let resultData = try JSONEncoder().encode(result)
        let resultText = String(decoding: resultData, as: UTF8.self)
        return #"{"id":\#(idText),"result":\#(resultText)}"#
    }
}

private final class CapturingRuntimeSyncer: AgentSessionRuntimeSyncing {
    private let lock = NSLock()
    private var records = [AgentSessionRegistryRecord]()

    var latestRecords: [AgentSessionRegistryRecord] {
        lock.lock()
        defer { lock.unlock() }
        return records
    }

    func sync(records: [AgentSessionRegistryRecord]) {
        lock.lock()
        self.records = records
        lock.unlock()
    }
}

private struct RegistryMonitorOrdinaryTmuxProjectionStub: OrdinaryTmuxWindowProjecting {
    let expectedTargetSession: String
    let projectedPanels: [OrdinaryTmuxProjectedPanel]

    func projectedPanels(for metadata: OrdinaryTmuxAttachMetadata) throws -> [OrdinaryTmuxProjectedPanel] {
        XCTAssertEqual(metadata.targetSession, expectedTargetSession)
        return projectedPanels
    }

    func setPaneIdentity(route: OrdinaryTmuxPanelRoute) throws {}
}

private final class RegistryMonitorFakeRuntimeSession: CodexAppServerRuntimeSessionControlling {
    func canSubmitMessage() -> Bool {
        true
    }

    func ensureThreadSubscription() {}

    func refreshActiveThread() {}

    func pendingApprovalPromptEvents() -> [AgentEvent] {
        []
    }

    func submitApproval(promptID: String, targetIndex: Int) throws -> AgentEvent {
        throw BridgeInternalError.notFound("No prompts in registry monitor fake runtime.")
    }

    func submitMessage(text: String) throws {}

    func stop() {}
}
