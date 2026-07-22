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

        let canonicalizedData = try Data(contentsOf: registryURL)
        let canonicalizedRecord = try JSONDecoder().decode(AgentSessionRegistryRecord.self, from: canonicalizedData)
        XCTAssertEqual(canonicalizedRecord.workspaceID, "current-workspace")
        XCTAssertEqual(canonicalizedRecord.panelID, "current-panel")
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

        let canonicalizedData = try Data(contentsOf: registryURL)
        let canonicalizedRecord = try JSONDecoder().decode(AgentSessionRegistryRecord.self, from: canonicalizedData)
        XCTAssertEqual(canonicalizedRecord.workspaceID, "current-workspace")
        XCTAssertEqual(canonicalizedRecord.panelID, "current-panel")
        XCTAssertEqual(canonicalizedRecord.tmuxPaneID, "%14")
        XCTAssertEqual(canonicalizedRecord.tmuxSocketPath, "/tmp/tmux-501/default")
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

        let canonicalizedData = try Data(contentsOf: registryURL)
        let canonicalizedRecord = try JSONDecoder().decode(AgentSessionRegistryRecord.self, from: canonicalizedData)
        XCTAssertEqual(canonicalizedRecord.workspaceID, "tidey-workspace")
        XCTAssertEqual(canonicalizedRecord.panelID, "tidey-carrier-panel")
        XCTAssertEqual(canonicalizedRecord.tmuxSocketPath, "/tmp/tmux-501/default")

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

        let canonicalizedData = try Data(contentsOf: registryURL)
        let canonicalizedRecord = try JSONDecoder().decode(AgentSessionRegistryRecord.self, from: canonicalizedData)
        XCTAssertEqual(canonicalizedRecord.workspaceID, "genesis-workspace")
        XCTAssertEqual(canonicalizedRecord.panelID, "genesis-carrier-panel")
        XCTAssertEqual(canonicalizedRecord.tmuxSocketPath, "/tmp/tmux-501/default")

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

        let canonicalizedData = try Data(contentsOf: registryURL)
        let canonicalizedRecord = try JSONDecoder().decode(AgentSessionRegistryRecord.self, from: canonicalizedData)
        XCTAssertEqual(canonicalizedRecord.workspaceID, "adbrewer-workspace")
        XCTAssertEqual(canonicalizedRecord.panelID, "adbrewer-codex-panel")
        XCTAssertEqual(canonicalizedRecord.tmuxSocketPath, "/tmp/tmux-501/default")

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
                                                               attachHandler: { _, _, _, _, onAgentEvent, _, _, _, _ in
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

    // Round 4 P0: a FRESH app-server record's transcript session must
    // establish its Hub epoch (CodexTranscriptSession.start's synchronous
    // beginNewSourceEpoch + boundary sessionStarted) BEFORE the runtime
    // syncer's attach() runs — otherwise a synchronous attach-time event
    // (here, an interactive-prompt-resolved terminal fired inline from the
    // fake attach handler, exactly like a real app-server's synchronous
    // first callback) could be published into an epoch that a LATER
    // beginNewSourceEpoch then wipes. Proves: after the scan completes, the
    // synchronously-published event is still present, exactly one
    // sessionStarted boundary exists for this session, and the published
    // event's seq is strictly greater (it landed AFTER the epoch, never
    // erased by one after it).
    func testFreshAppServerAttachEventSurvivesBehindTranscriptSessionEpoch() throws {
        let fileManager = FileManager.default
        let supportDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("tidey-remote-bridge-monitor-\(UUID().uuidString)", isDirectory: true)
        let paths = BridgePaths(supportDirectory: supportDirectory)
        try paths.ensureSupportDirectoriesExist(fileManager: fileManager)
        defer { try? fileManager.removeItem(at: supportDirectory) }

        let rolloutURL = supportDirectory.appendingPathComponent("rollout-fresh.jsonl")
        try (codexTaskStartedLine(turnID: "turn-fresh") + "\n").write(to: rolloutURL, atomically: true, encoding: .utf8)

        let registryURL = paths.codexAgentSessionsDirectory.appendingPathComponent("codex-app-server-fresh.json")
        let recordData = Data("""
        {
          "version": 1,
          "vendor": "codex",
          "workspace_id": "workspace-fresh",
          "session_id": "session-fresh",
          "panel_id": "panel-fresh",
          "pid": 999999,
          "cwd": "/tmp",
          "created_at": "2026-06-07T00:00:00Z",
          "runtime": "codex_app_server",
          "app_server_socket": "/tmp/tidey-codex-app-server/fresh.sock",
          "app_server_pid": \(getpid()),
          "rollout_path": "\(rolloutURL.path)"
        }
        """.utf8)
        try recordData.write(to: registryURL)

        let hub = AgentEventHub()
        let runtimeSyncer = CodexAppServerRegistryRuntimeSyncer(eventHub: hub,
                                                               attachHandler: { record, _, nextSequence, timestampProvider, _, _, onInteractivePromptResolved, _, _ in
            // Fires SYNCHRONOUSLY, before attach() returns — exactly like a
            // real app-server connection's inline first callback.
            onInteractivePromptResolved(AgentEvent(eventID: "sync-attach-resolved",
                                                    seq: nextSequence(record.sessionID),
                                                    vendor: "codex",
                                                    workspaceID: record.workspaceID,
                                                    sessionID: record.sessionID,
                                                    timestamp: timestampProvider(),
                                                    type: .interactivePromptResolved,
                                                    role: nil,
                                                    text: nil,
                                                    name: nil,
                                                    input: nil,
                                                    output: nil,
                                                    toolCallID: nil,
                                                    metadata: ["source": "synchronous-attach-test", "prompt_id": "sync-prompt"]))
            return RegistryMonitorFakeRuntimeSession()
        })
        let monitor = AgentSessionRegistryMonitor(paths: paths,
                                                  fileManager: fileManager,
                                                  hub: hub,
                                                  tmuxResolver: TmuxStateResolver(ttl: 60) { _, _ in "" },
                                                  parentPIDLookup: { _ in nil },
                                                  runtimeSyncer: runtimeSyncer)
        try monitor.start()

        XCTAssertTrue(waitUntil(timeout: 10) {
            hub.fetch(workspaceID: "workspace-fresh", sessionID: "session-fresh", limit: 20)
                .events.contains { $0.metadata?["source"] == "synchronous-attach-test" }
        }, "the synchronous attach-time event must survive, not be silently wiped by a later beginNewSourceEpoch")

        let history = hub.fetch(workspaceID: "workspace-fresh", sessionID: "session-fresh", limit: 20).events
        XCTAssertEqual(history.filter { $0.type == .sessionStarted }.count, 1,
                       "exactly one Hub epoch boundary must exist for this fresh session, got \(history.map(\.type))")
        let sessionStartedSeq = try XCTUnwrap(history.first { $0.type == .sessionStarted }?.seq)
        let syncAttachSeq = try XCTUnwrap(history.first { $0.metadata?["source"] == "synchronous-attach-test" }?.seq)
        XCTAssertGreaterThan(syncAttachSeq, sessionStartedSeq,
                            "the synchronous attach event must land AFTER the transcript session's epoch was established, got session_started seq=\(sessionStartedSeq) event seq=\(syncAttachSeq)")
    }

    // Round 4 P0: the transcript source-epoch reset (beginNewSourceEpoch,
    // now run INSIDE the runtime reconcile callback) must happen strictly
    // AFTER the old runtime generation's fence, so a live old-generation
    // event arriving right as reconcile begins is wiped by the epoch reset
    // rather than surviving/leaking into the new workspace — while the NEW
    // generation's own attach-time marker (which only runs after the
    // callback returns) DOES survive, proving B's attach happens after the
    // epoch reset rather than being cleared by it.
    func testOldRuntimeGenerationEventCannotSurviveTranscriptEpochResetOrdering() throws {
        let fileManager = FileManager.default
        let supportDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("tidey-remote-bridge-monitor-\(UUID().uuidString)", isDirectory: true)
        let paths = BridgePaths(supportDirectory: supportDirectory)
        try paths.ensureSupportDirectoriesExist(fileManager: fileManager)
        defer { try? fileManager.removeItem(at: supportDirectory) }

        let rolloutA = supportDirectory.appendingPathComponent("rollout-epoch-a.jsonl")
        let rolloutB = supportDirectory.appendingPathComponent("rollout-epoch-b.jsonl")
        try (codexTaskStartedLine(turnID: "turn-epoch-a") + "\n").write(to: rolloutA, atomically: true, encoding: .utf8)
        try (codexTaskStartedLine(turnID: "turn-epoch-b") + "\n").write(to: rolloutB, atomically: true, encoding: .utf8)

        let registryURL = paths.codexAgentSessionsDirectory.appendingPathComponent("codex-app-server-epoch.json")
        func writeRegistry(workspaceID: String, socket: String, rollout: URL) throws {
            let recordData = Data("""
            {
              "version": 1,
              "vendor": "codex",
              "workspace_id": "\(workspaceID)",
              "session_id": "session-epoch",
              "panel_id": "panel-epoch",
              "pid": 999999,
              "cwd": "/tmp",
              "created_at": "2026-06-07T00:00:00Z",
              "runtime": "codex_app_server",
              "app_server_socket": "\(socket)",
              "app_server_pid": \(getpid()),
              "rollout_path": "\(rollout.path)"
            }
            """.utf8)
            try recordData.write(to: registryURL)
        }
        try writeRegistry(workspaceID: "workspace-epoch-a", socket: "/tmp/tidey-codex-app-server/epoch-a.sock", rollout: rolloutA)

        let hub = AgentEventHub()
        var oldResolvedHandler: CodexAppServerConnection.InteractivePromptResolvedHandler?
        var attachCount = 0
        let runtimeSyncer = CodexAppServerRegistryRuntimeSyncer(eventHub: hub,
                                                               attachHandler: { record, _, nextSequence, timestampProvider, _, _, onInteractivePromptResolved, _, _ in
            attachCount += 1
            if attachCount == 1 {
                oldResolvedHandler = onInteractivePromptResolved
            } else {
                // The NEW generation's own synchronous attach-time marker.
                onInteractivePromptResolved(AgentEvent(eventID: "new-gen-attach-marker",
                                                        seq: nextSequence(record.sessionID),
                                                        vendor: "codex",
                                                        workspaceID: record.workspaceID,
                                                        sessionID: record.sessionID,
                                                        timestamp: timestampProvider(),
                                                        type: .interactivePromptResolved,
                                                        role: nil,
                                                        text: nil,
                                                        name: nil,
                                                        input: nil,
                                                        output: nil,
                                                        toolCallID: nil,
                                                        metadata: ["source": "new-generation-attach-marker"]))
            }
            return RegistryMonitorFakeRuntimeSession()
        })
        let monitor = AgentSessionRegistryMonitor(paths: paths,
                                                  fileManager: fileManager,
                                                  hub: hub,
                                                  tmuxResolver: TmuxStateResolver(ttl: 60) { _, _ in "" },
                                                  parentPIDLookup: { _ in nil },
                                                  runtimeSyncer: runtimeSyncer)
        try monitor.start()
        XCTAssertTrue(waitUntil(timeout: 10) {
            hub.fetch(workspaceID: "workspace-epoch-a", sessionID: "session-epoch", limit: 20)
                .events.contains { $0.type == .sessionStarted }
        }, "precondition: the first generation must be attached under workspace-A")
        let resolvedHandler = try XCTUnwrap(oldResolvedHandler)

        // Set only after the initial attach: on the NEXT reconciliation this
        // fires BEFORE the generation fence (syncArrivalHook runs before
        // syncSerialLock/syncLockedPass), injecting a live old-generation
        // event right as reconcile begins — exactly the window the ordering
        // fix must close.
        runtimeSyncer.syncArrivalHook = { [weak runtimeSyncer] _ in
            runtimeSyncer?.syncArrivalHook = nil
            resolvedHandler(AgentEvent(eventID: "old-gen-marker",
                                        seq: hub.nextSyntheticSeq(sessionID: "session-epoch"),
                                        vendor: "codex",
                                        workspaceID: "workspace-epoch-a",
                                        sessionID: "session-epoch",
                                        timestamp: "2026-06-07T00:00:01Z",
                                        type: .interactivePromptResolved,
                                        role: nil,
                                        text: nil,
                                        name: nil,
                                        input: nil,
                                        output: nil,
                                        toolCallID: nil,
                                        metadata: ["source": "old-generation-marker"]))
        }

        // Trigger the migration: same sessionID, new workspace AND new
        // rollout (a genuine transcript source-identity switch), forcing a
        // NEW app-server generation (workspace changed) to replace the old.
        try writeRegistry(workspaceID: "workspace-epoch-b", socket: "/tmp/tidey-codex-app-server/epoch-b.sock", rollout: rolloutB)

        XCTAssertTrue(waitUntil(timeout: 10) {
            hub.fetch(workspaceID: "workspace-epoch-b", sessionID: "session-epoch", limit: 20)
                .events.contains { $0.metadata?["source"] == "new-generation-attach-marker" }
        }, "the NEW generation's attach-time marker must land under workspace-B, proving attach ran after the epoch reset")

        let historyB = hub.fetch(workspaceID: "workspace-epoch-b", sessionID: "session-epoch", limit: 30).events
        XCTAssertEqual(historyB.filter { $0.type == .sessionStarted }.count, 1,
                       "exactly one Hub epoch boundary must exist after the migration, got \(historyB.map(\.type))")
        XCTAssertFalse(historyB.contains { $0.metadata?["source"] == "old-generation-marker" },
                      "the OLD generation's marker (published before the fence, wiped by the epoch reset) must never survive/leak into the new workspace's history, got \(historyB.map { ($0.type, $0.metadata) })")
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
        hub.drainDeliveriesForTesting()

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

    // MARK: - Round 4: same-sessionID generation handoff (production monitor path)

    private func codexTaskStartedLine(turnID: String) -> String {
        let object: [String: Any] = ["type": "event_msg", "timestamp": "2026-06-08T22:06:25Z",
                                     "payload": ["type": "task_started", "turn_id": turnID]]
        return String(data: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), encoding: .utf8)!
    }

    private func codexFunctionCallLine(callID: String) -> String {
        let object: [String: Any] = ["type": "response_item", "timestamp": "2026-06-08T22:06:26Z",
                                     "payload": ["type": "function_call", "call_id": callID, "name": "run", "arguments": "{}"]]
        return String(data: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), encoding: .utf8)!
    }

    private func equivalentWorkingStates(for events: [AgentEvent]) -> [Bool] {
        var isThinking = false
        var states = [Bool]()
        for event in events {
            switch event.type {
            case .thinking:
                isThinking = true
            case .assistantMessage, .assistantFinal, .interactivePrompt, .interactivePromptResolved,
                 .toolCall, .sessionStarted, .sessionEnded:
                isThinking = false
            default:
                break
            }
            states.append(isThinking)
        }
        return states
    }

    // Thread-safe recorder: the Hub delivers on its OWN delivery queue,
    // never the test thread — a plain captured `var` array would race.
    private final class RecordingEventCollector {
        private let lock = NSLock()
        private var events = [AgentEvent]()
        func record(_ event: AgentEvent) {
            lock.lock()
            events.append(event)
            lock.unlock()
        }
        func all() -> [AgentEvent] {
            lock.lock()
            defer { lock.unlock() }
            return events
        }
    }

    // The real production path: AgentSessionRegistryMonitor.syncRecords sees
    // sessionID S disappear (record removed, old transcript session object
    // stopped) and later sees the SAME sessionID S reappear (a brand new
    // record/object, reusing the SAME turn_id/call_id/raw offsets). Generation
    // B must accept the reused IDs, its own removal must ALSO deliver its
    // own sessionEnded (not be swallowed by generation A's already-consumed
    // seen state), seq must stay monotonic across the whole two-generation
    // lifecycle, and the final equivalent Working state must be OFF.
    //
    // NOTE on storage vs. delivery: beginNewSourceEpoch (correctly) WIPES the
    // Hub's buffered/historical store for the sessionID when generation B
    // starts — so a FINAL hub.fetch() only ever shows generation B's OWN
    // sessionStarted/sessionEnded, never generation A's (asserted below as a
    // deliberate contrast). The "both generations really happened, in order,
    // with no collision" proof instead comes from a LIVE SUBSCRIBER recorder,
    // which captures every delivery as it happens, unaffected by later
    // buffer wipes.
    func testSameSessionIDStopRecreateStopIsACorrectGenerationHandoff() throws {
        let fileManager = FileManager.default
        let supportDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("tidey-remote-bridge-monitor-\(UUID().uuidString)", isDirectory: true)
        let paths = BridgePaths(supportDirectory: supportDirectory)
        try paths.ensureSupportDirectoriesExist(fileManager: fileManager)
        defer { try? fileManager.removeItem(at: supportDirectory) }

        let rolloutA = supportDirectory.appendingPathComponent("rollout-a.jsonl")
        let rolloutB = supportDirectory.appendingPathComponent("rollout-b.jsonl")
        // A and B are BYTE-IDENTICAL in shape: same turn_id, same call_id,
        // same raw line offsets — a genuine reused-identity generation swap.
        let sharedRolloutContent = codexTaskStartedLine(turnID: "turn-shared") + "\n" + codexFunctionCallLine(callID: "call-shared") + "\n"
        try sharedRolloutContent.write(to: rolloutA, atomically: true, encoding: .utf8)

        let registryURL = paths.codexAgentSessionsDirectory.appendingPathComponent("shared-session.json")
        func writeRegistry(transcriptPath: URL) throws {
            let recordData = Data("""
            {
              "version": 1,
              "vendor": "codex",
              "workspace_id": "workspace-shared",
              "session_id": "shared-session",
              "panel_id": "panel-shared",
              "pid": \(getpid()),
              "cwd": "/tmp",
              "created_at": "2026-06-07T00:00:00Z",
              "rollout_path": "\(transcriptPath.path)"
            }
            """.utf8)
            try recordData.write(to: registryURL)
        }
        try writeRegistry(transcriptPath: rolloutA)

        let hub = AgentEventHub()
        let monitor = AgentSessionRegistryMonitor(paths: paths,
                                                  fileManager: fileManager,
                                                  hub: hub,
                                                  tmuxResolver: TmuxStateResolver(ttl: 60) { _, _ in "" },
                                                  parentPIDLookup: { _ in nil })
        try monitor.start()

        let collector = RecordingEventCollector()
        let (subscriptionID, replay) = hub.subscribe(workspaceID: "workspace-shared", sessionID: "shared-session") { envelope in
            collector.record(envelope.event)
        }
        replay.forEach { collector.record($0.event) }
        defer { hub.unsubscribe(subscriptionID) }

        // Generation A: active, unterminated turn, with its own tool call.
        XCTAssertTrue(waitUntil(timeout: 10) {
            hub.fetch(workspaceID: "workspace-shared", sessionID: "shared-session", limit: 50).events.contains {
                $0.type == .toolCall && $0.toolCallID == "call-shared"
            }
        }, "generation A must show its tool call")
        let aMaxSeq = hub.fetch(workspaceID: "workspace-shared", sessionID: "shared-session", limit: 50).events.map(\.seq).max() ?? 0

        // Remove S: generation A's record disappears -> the monitor stops
        // generation A's transcript session object -> sessionEnded.
        try fileManager.removeItem(at: registryURL)
        XCTAssertTrue(waitUntil(timeout: 10) {
            hub.drainDeliveriesForTesting()
            return collector.all().filter { $0.type == .sessionEnded }.count == 1
        }, "generation A's removal must deliver its sessionEnded")

        // Re-add the SAME sessionID: a BRAND NEW record/object, reusing
        // turn-shared's turn_id AND call-shared's call_id from offset 0.
        try sharedRolloutContent.write(to: rolloutB, atomically: true, encoding: .utf8)
        try writeRegistry(transcriptPath: rolloutB)

        XCTAssertTrue(waitUntil(timeout: 10) {
            hub.drainDeliveriesForTesting()
            return collector.all().filter { $0.type == .toolCall && $0.toolCallID == "call-shared" }.count == 2
        }, "generation B must accept the reused call_id as a SECOND live delivery, not suppress it as a duplicate of generation A's, got \(collector.all().filter { $0.toolCallID == "call-shared" }.map(\.seq))")

        let toolCallSeqs = collector.all().filter { $0.type == .toolCall && $0.toolCallID == "call-shared" }.map(\.seq).sorted()
        XCTAssertEqual(toolCallSeqs.count, 2, "expected exactly 2 reused-callID deliveries, got \(toolCallSeqs)")
        // Guarded so a wrong count reports as the assertion above, never a
        // crash from subscripting a too-short array.
        if toolCallSeqs.count == 2 {
            XCTAssertLessThan(toolCallSeqs[0], toolCallSeqs[1], "generation B's reused-callID delivery must carry a HIGHER seq than generation A's")
            XCTAssertGreaterThan(toolCallSeqs[1], aMaxSeq, "generation B's own seq must land strictly above generation A's high-water")
        }

        // Remove S again: generation B's OWN sessionEnded must ALSO be
        // delivered — not dropped as a duplicate of generation A's.
        try fileManager.removeItem(at: registryURL)
        XCTAssertTrue(waitUntil(timeout: 10) {
            hub.drainDeliveriesForTesting()
            return collector.all().filter { $0.type == .sessionEnded }.count == 2
        }, "generation B's removal must ALSO deliver its own sessionEnded, got \(collector.all().filter { $0.type == .sessionEnded }.map(\.seq))")

        // Storage contrast: beginNewSourceEpoch legitimately wiped
        // generation A's buffered products when B started — the live STORE
        // now only ever shows ONE sessionEnded (B's own), never two.
        let storedSessionEndedCount = hub.fetch(workspaceID: "workspace-shared", sessionID: "shared-session", limit: 50)
            .events.filter { $0.type == .sessionEnded }.count
        XCTAssertEqual(storedSessionEndedCount, 1,
                       "the live STORE only ever retains generation B's own sessionEnded after its epoch reset wiped A's buffer, got \(storedSessionEndedCount)")

        // The equivalent Working fold and cursor-monotonicity checks below
        // must run over the ACTUAL delivery order the collector observed —
        // never a re-sorted copy (asserting sortedness of an ALREADY-sorted
        // array is a tautology that can never fail). A separate sorted copy
        // is used only for count-based lookups above, never for ordering
        // assertions.
        let allDelivered = collector.all()
        XCTAssertEqual(equivalentWorkingStates(for: allDelivered).last, false,
                      "the final equivalent Working state must be OFF, got \(allDelivered.map { ($0.type, $0.text ?? "") })")

        // Explicit per-generation lifecycle-event counts and identity, as
        // ACTUALLY delivered to the live subscriber (not inferred from the
        // final fold alone, which could pass even if generation B never
        // itself re-anchored Working).
        let startedEvents = allDelivered.filter { $0.type == .sessionStarted }
        let endedEvents = allDelivered.filter { $0.type == .sessionEnded }
        XCTAssertEqual(startedEvents.count, 2, "the live subscriber must see exactly two sessionStarted deliveries (one per generation), got \(startedEvents.map(\.seq))")
        XCTAssertEqual(endedEvents.count, 2, "the live subscriber must see exactly two sessionEnded deliveries (one per generation), got \(endedEvents.map(\.seq))")
        XCTAssertEqual(Set(startedEvents.map(\.eventID)).count, 1,
                       "both generations' sessionStarted use the SAME fixed, deterministic eventID (no per-generation randomization), got \(startedEvents.map(\.eventID))")
        // Access by index only after confirming the count above — guard so
        // a regression (wrong count) reports as a clean assertion failure,
        // never a crash from subscripting a too-short array.
        if startedEvents.count == 2 {
            XCTAssertLessThan(startedEvents[0].seq, startedEvents[1].seq, "generation B's sessionStarted must carry a strictly higher seq than generation A's")
        }

        let taskStartedAnchors = allDelivered.filter { $0.type == .thinking && $0.metadata?["reason"] == "task_started" && $0.metadata?["turn_id"] == "turn-shared" }
        XCTAssertEqual(taskStartedAnchors.count, 2,
                       "both generations must independently re-anchor Working for turn-shared, got \(taskStartedAnchors.map(\.seq))")
        let generationBAnchor = try XCTUnwrap(taskStartedAnchors.count == 2 ? taskStartedAnchors[1] : nil,
                                              "generation B's own Working anchor must exist to check its seq")
        XCTAssertGreaterThan(generationBAnchor.seq, aMaxSeq,
                             "generation B's OWN Working anchor (not just its tool call) must land above generation A's high-water")

        // Cursor monotonicity across the WHOLE two-generation lifecycle, in
        // the TRUE delivery order (not a sorted copy).
        let deliveredSeqs = allDelivered.map(\.seq)
        for index in 1..<deliveredSeqs.count {
            XCTAssertGreaterThan(deliveredSeqs[index], deliveredSeqs[index - 1],
                                 "delivery \(index) (seq \(deliveredSeqs[index])) must strictly increase over delivery \(index - 1) (seq \(deliveredSeqs[index - 1])) in TRUE arrival order, got \(deliveredSeqs)")
        }
        XCTAssertEqual(Set(deliveredSeqs).count, deliveredSeqs.count, "no duplicate/colliding seq across the whole S->removed->S->removed lifecycle")
    }

    // MARK: - Round 4: workspace ownership-aware sidebar cleanup (production monitor path)

    private final class RecordingSidebarSender {
        private let lock = NSLock()
        private var messages = [String]()
        func send(_ message: String) {
            lock.lock()
            messages.append(message)
            lock.unlock()
        }
        func all() -> [String] {
            lock.lock()
            defer { lock.unlock() }
            return messages
        }
    }

    private func writeCodexRegistry(at url: URL, workspaceID: String, sessionID: String, panelID: String, transcriptPath: URL) throws {
        let recordData = Data("""
        {
          "version": 1,
          "vendor": "codex",
          "workspace_id": "\(workspaceID)",
          "session_id": "\(sessionID)",
          "panel_id": "\(panelID)",
          "pid": \(getpid()),
          "cwd": "/tmp",
          "created_at": "2026-06-07T00:00:00Z",
          "rollout_path": "\(transcriptPath.path)"
        }
        """.utf8)
        try recordData.write(to: url)
    }

    private func writeClaudeRegistry(at url: URL, workspaceID: String, sessionID: String, panelID: String) throws {
        let recordData = Data("""
        {
          "version": 1,
          "vendor": "claude",
          "workspace_id": "\(workspaceID)",
          "session_id": "\(sessionID)",
          "panel_id": "\(panelID)",
          "pid": \(getpid()),
          "cwd": "/tmp",
          "created_at": "2026-06-07T00:00:00Z"
        }
        """.utf8)
        try recordData.write(to: url)
    }

    // True workspace migration (same sessionID, workspace_id actually
    // changes): the OLD workspace must get a prompt cleanup; the NEW
    // workspace gets its own genuine current state (running, since the
    // record is still an active/unterminated turn) from its own transcript
    // session bootstrap — no second cleanup interferes with that. The
    // injected sidebarMessageSender is ALSO what the transcript sessions
    // themselves use (see AgentSessionRegistryMonitor.transcriptCommandSender),
    // so "running" here is the REAL session-level activation, not a
    // monitor-only artifact.
    func testWorkspaceMigrationSendsPromptToOldWorkspaceAndRunningToNew() throws {
        let fileManager = FileManager.default
        let supportDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("tidey-remote-bridge-monitor-\(UUID().uuidString)", isDirectory: true)
        let paths = BridgePaths(supportDirectory: supportDirectory)
        try paths.ensureSupportDirectoriesExist(fileManager: fileManager)
        defer { try? fileManager.removeItem(at: supportDirectory) }

        let rollout = supportDirectory.appendingPathComponent("rollout.jsonl")
        try (codexTaskStartedLine(turnID: "turn-migrate") + "\n").write(to: rollout, atomically: true, encoding: .utf8)
        let registryURL = paths.codexAgentSessionsDirectory.appendingPathComponent("migrate-session.json")
        try writeCodexRegistry(at: registryURL, workspaceID: "workspace-A", sessionID: "migrate-session", panelID: "panel-A", transcriptPath: rollout)

        let hub = AgentEventHub()
        let sender = RecordingSidebarSender()
        let monitor = AgentSessionRegistryMonitor(paths: paths,
                                                  fileManager: fileManager,
                                                  hub: hub,
                                                  tmuxResolver: TmuxStateResolver(ttl: 60) { _, _ in "" },
                                                  parentPIDLookup: { _ in nil },
                                                  sidebarMessageSender: { message in sender.send(message) })
        try monitor.start()
        XCTAssertTrue(waitUntil(timeout: 10) {
            sender.all().contains("report_shell_state running --workspace_id=workspace-A")
        }, "precondition: workspace-A must be running")

        let commandsBeforeMigration = sender.all()

        // True migration: SAME sessionID, workspace_id changes from A to B.
        try writeCodexRegistry(at: registryURL, workspaceID: "workspace-B", sessionID: "migrate-session", panelID: "panel-B", transcriptPath: rollout)

        // Barrier: wait, via a PURE read-only queue.sync snapshot (no
        // mutation — activeSessionForPanel would itself call
        // applyResolvedBinding and re-trigger session.update, which could
        // make the test's own observation produce the "running B" being
        // asserted), until the monitor's registry scan has actually
        // recorded the new binding.
        XCTAssertTrue(waitUntil(timeout: 10) {
            monitor.activeSessionSnapshots().contains { $0.workspaceID == "workspace-B" && $0.panelID == "panel-B" }
        }, "precondition: the migration scan must have completed")

        XCTAssertTrue(sender.all().dropFirst(commandsBeforeMigration.count).contains("report_shell_state prompt --workspace_id=workspace-A"),
                     "the OLD workspace must receive a prompt cleanup, got \(sender.all().dropFirst(commandsBeforeMigration.count))")

        // The session object's OWN sidebar activation for the new workspace
        // runs on ITS own async queue (session.update), independent of the
        // monitor's scan barrier above — wait for it separately rather than
        // asserting immediately.
        XCTAssertTrue(waitUntil(timeout: 10) {
            sender.all().dropFirst(commandsBeforeMigration.count).contains("report_shell_state running --workspace_id=workspace-B")
        }, "the NEW workspace must get its own genuine (running) state, got \(sender.all().dropFirst(commandsBeforeMigration.count))")

        // The OLD workspace's cleanup must have been sent BEFORE the NEW
        // workspace's own running activation, matching "old A cleaned up
        // first, then B established" from the acceptance criteria.
        let newCommands = sender.all().dropFirst(commandsBeforeMigration.count)
        let promptAIndex = newCommands.firstIndex(of: "report_shell_state prompt --workspace_id=workspace-A")
        let runningBIndex = newCommands.firstIndex(of: "report_shell_state running --workspace_id=workspace-B")
        let unwrappedPromptAIndex = try XCTUnwrap(promptAIndex)
        let unwrappedRunningBIndex = try XCTUnwrap(runningBIndex)
        XCTAssertLessThan(unwrappedPromptAIndex, unwrappedRunningBIndex,
                          "workspace-A's cleanup must be sent before workspace-B's running activation, got \(Array(newCommands))")
    }

    // Production-path A->B correction discovered via pane/process resolution
    // (activeSessionForPanel -> matchedSession -> applyResolvedBinding), NOT
    // a registry rewrite/scan. The registry scan's previous/current diff
    // never sees this transition, so applyResolvedBinding itself must run
    // the SAME prepare -> cleanup -> finish transaction the scan path uses.
    func testApplyResolvedBindingProductionPathMigratesWorkspaceWithCleanupBeforeActivation() throws {
        let fileManager = FileManager.default
        let supportDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("tidey-remote-bridge-monitor-\(UUID().uuidString)", isDirectory: true)
        let paths = BridgePaths(supportDirectory: supportDirectory)
        try paths.ensureSupportDirectoriesExist(fileManager: fileManager)
        defer { try? fileManager.removeItem(at: supportDirectory) }

        let rollout = supportDirectory.appendingPathComponent("rollout.jsonl")
        try (codexTaskStartedLine(turnID: "turn-resolved") + "\n").write(to: rollout, atomically: true, encoding: .utf8)
        let registryURL = paths.codexAgentSessionsDirectory.appendingPathComponent("resolved-session.json")
        let recordData = Data("""
        {
          "version": 1,
          "vendor": "codex",
          "workspace_id": "workspace-A",
          "session_id": "resolved-session",
          "panel_id": "panel-A",
          "pid": \(getpid()),
          "cwd": "/tmp",
          "created_at": "2026-06-07T00:00:00Z",
          "rollout_path": "\(rollout.path)",
          "tmux_pane_id": "pane-shared",
          "tmux_socket_path": "/tmp/tidey-shared.sock"
        }
        """.utf8)
        try recordData.write(to: registryURL)

        let hub = AgentEventHub()
        let sender = RecordingSidebarSender()
        let monitor = AgentSessionRegistryMonitor(paths: paths,
                                                  fileManager: fileManager,
                                                  hub: hub,
                                                  tmuxResolver: TmuxStateResolver(ttl: 60) { _, _ in "" },
                                                  parentPIDLookup: { _ in nil },
                                                  sidebarMessageSender: { message in sender.send(message) })
        try monitor.start()
        XCTAssertTrue(waitUntil(timeout: 10) {
            sender.all().contains("report_shell_state running --workspace_id=workspace-A")
        }, "precondition: workspace-A must be running")
        let sessionStartedCountBefore = hub.fetch(workspaceID: "workspace-A", sessionID: "resolved-session", limit: 50)
            .events.filter { $0.type == .sessionStarted }.count
        XCTAssertEqual(sessionStartedCountBefore, 1)

        let commandsBeforeCorrection = sender.all()

        // Pane/process resolution reports the SAME pane under a DIFFERENT
        // workspace/panel — this is the correction path, not a registry
        // rewrite. No registry scan ever observes an A/B transition here.
        let corrected = monitor.activeSessionForPanel(workspaceID: "workspace-B",
                                                       panelID: "panel-B",
                                                       effectiveShellPID: nil,
                                                       tmuxPaneID: "pane-shared",
                                                       tmuxSocketPath: "/tmp/tidey-shared.sock")
        let unwrappedCorrected = try XCTUnwrap(corrected, "pane-identity resolution must find the session")
        XCTAssertEqual(unwrappedCorrected.sessionID, "resolved-session")
        XCTAssertEqual(unwrappedCorrected.workspaceID, "workspace-B")

        XCTAssertTrue(waitUntil(timeout: 10) {
            sender.all().dropFirst(commandsBeforeCorrection.count).contains("report_shell_state running --workspace_id=workspace-B")
        }, "the NEW workspace must get its own genuine (running) state, got \(sender.all().dropFirst(commandsBeforeCorrection.count))")

        let newCommands = Array(sender.all().dropFirst(commandsBeforeCorrection.count))
        let promptAIndex = try XCTUnwrap(newCommands.firstIndex(of: "report_shell_state prompt --workspace_id=workspace-A"),
                                        "workspace-A must receive a cleanup prompt, got \(newCommands)")
        let runningBIndex = try XCTUnwrap(newCommands.firstIndex(of: "report_shell_state running --workspace_id=workspace-B"))
        XCTAssertLessThan(promptAIndex, runningBIndex,
                          "workspace-A's cleanup must precede workspace-B's running activation, got \(newCommands)")
        XCTAssertEqual(newCommands.filter { $0 == "report_shell_state prompt --workspace_id=workspace-A" }.count, 1,
                       "workspace-A must never receive output again after its single cleanup, got \(newCommands)")
        XCTAssertFalse(newCommands.dropFirst(promptAIndex + 1).contains { $0.contains("workspace-A") },
                       "no workspace-A sidebar output may follow its own cleanup (checked from the cleanup index itself, not just after running-B), got \(newCommands)")

        // Same-source Working is preserved: the SAME session/turn continues
        // uninterrupted (no extra sessionStarted/sessionEnded from the
        // correction itself, and the migrated active-turn's Working anchor
        // is still present with no terminal for it).
        let historyAfter = hub.fetch(workspaceID: "workspace-B", sessionID: "resolved-session", limit: 50).events
        XCTAssertEqual(historyAfter.filter { $0.type == .sessionStarted }.count, 1,
                       "the correction must not fabricate a new session-start boundary")
        XCTAssertEqual(historyAfter.filter { $0.type == .sessionEnded }.count, 0,
                       "the correction must not terminate the session")
        XCTAssertTrue(historyAfter.contains { $0.type == .thinking && $0.metadata?["reason"] == "task_started" && $0.metadata?["turn_id"] == "turn-resolved" },
                     "Working=true: the migrated active-turn anchor must still be present after the correction, got \(historyAfter.map { ($0.type, $0.metadata) })")
        XCTAssertFalse(historyAfter.contains { $0.metadata?["turn_id"] == "turn-resolved" && $0.metadata?["reason"] == "turn_terminal" },
                      "Working=true: the migrated turn must not have been terminated by the correction itself")
    }

    // Panel-only migration (workspace_id UNCHANGED) must never trigger a
    // cleanup prompt for that workspace.
    func testPanelOnlyMigrationNeverSendsPromptCleanup() throws {
        let fileManager = FileManager.default
        let supportDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("tidey-remote-bridge-monitor-\(UUID().uuidString)", isDirectory: true)
        let paths = BridgePaths(supportDirectory: supportDirectory)
        try paths.ensureSupportDirectoriesExist(fileManager: fileManager)
        defer { try? fileManager.removeItem(at: supportDirectory) }

        let rollout = supportDirectory.appendingPathComponent("rollout.jsonl")
        try (codexTaskStartedLine(turnID: "turn-panel") + "\n").write(to: rollout, atomically: true, encoding: .utf8)
        let registryURL = paths.codexAgentSessionsDirectory.appendingPathComponent("panel-session.json")
        try writeCodexRegistry(at: registryURL, workspaceID: "workspace-same", sessionID: "panel-session", panelID: "panel-old", transcriptPath: rollout)

        let hub = AgentEventHub()
        let sender = RecordingSidebarSender()
        let monitor = AgentSessionRegistryMonitor(paths: paths,
                                                  fileManager: fileManager,
                                                  hub: hub,
                                                  tmuxResolver: TmuxStateResolver(ttl: 60) { _, _ in "" },
                                                  parentPIDLookup: { _ in nil },
                                                  sidebarMessageSender: { message in sender.send(message) })
        try monitor.start()
        XCTAssertTrue(waitUntil(timeout: 10) {
            sender.all().contains("report_shell_state running --workspace_id=workspace-same")
        })
        let commandsBeforePanelMigration = sender.all()

        // Panel-only migration: workspace_id is UNCHANGED.
        try writeCodexRegistry(at: registryURL, workspaceID: "workspace-same", sessionID: "panel-session", panelID: "panel-new", transcriptPath: rollout)

        // Barrier: wait, via a PURE read-only queue.sync snapshot (never
        // activeSessionForPanel, which itself calls applyResolvedBinding
        // and could make the test's own observation mutate the system
        // under test), until the scan has recorded the new panel_id.
        XCTAssertTrue(waitUntil(timeout: 10) {
            monitor.activeSessionSnapshots().contains { $0.workspaceID == "workspace-same" && $0.panelID == "panel-new" }
        }, "precondition: the panel-only migration scan must have completed")

        XCTAssertFalse(sender.all().dropFirst(commandsBeforePanelMigration.count).contains { $0.contains("prompt --workspace_id=workspace-same") },
                      "a panel-only migration (workspace unchanged) must never send a cleanup prompt, got \(sender.all().dropFirst(commandsBeforePanelMigration.count))")
    }

    // Round 4 P0: applyResolvedBinding's panel-only correction (discovered
    // via pane/process resolution, not a registry rewrite) must reconcile
    // an app-server runtime's context IMMEDIATELY, in the SAME call — not
    // leave it bound to the stale panel until a later scan happens to
    // notice. Since panelID differs, the runtime syncer's own
    // recordsToAttach classification treats this as a full generation
    // replace; proving a second attach happens synchronously, with the
    // corrected panel, is direct evidence the stale route is gone right
    // away — and no cleanup prompt fires, since the workspace is unchanged.
    func testApplyResolvedBindingPanelOnlyCorrectionReconcilesAppServerRuntimeImmediately() throws {
        let fileManager = FileManager.default
        let supportDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("tidey-remote-bridge-monitor-\(UUID().uuidString)", isDirectory: true)
        let paths = BridgePaths(supportDirectory: supportDirectory)
        try paths.ensureSupportDirectoriesExist(fileManager: fileManager)
        defer { try? fileManager.removeItem(at: supportDirectory) }

        let rollout = supportDirectory.appendingPathComponent("rollout-panel-only.jsonl")
        try (codexTaskStartedLine(turnID: "turn-panel-only") + "\n").write(to: rollout, atomically: true, encoding: .utf8)
        let registryURL = paths.codexAgentSessionsDirectory.appendingPathComponent("codex-app-server-panel-only.json")
        let recordData = Data("""
        {
          "version": 1,
          "vendor": "codex",
          "workspace_id": "workspace-panel-only",
          "session_id": "session-panel-only",
          "panel_id": "panel-old",
          "pid": \(getpid()),
          "cwd": "/tmp",
          "created_at": "2026-06-07T00:00:00Z",
          "runtime": "codex_app_server",
          "app_server_socket": "/tmp/tidey-codex-app-server/panel-only.sock",
          "app_server_pid": \(getpid()),
          "rollout_path": "\(rollout.path)",
          "tmux_pane_id": "pane-panel-only",
          "tmux_socket_path": "/tmp/tidey-shared-panel-only.sock"
        }
        """.utf8)
        try recordData.write(to: registryURL)

        let hub = AgentEventHub()
        let sender = RecordingSidebarSender()
        var attachedPanelIDs = [String]()
        let attachLock = NSLock()
        let runtimeSyncer = CodexAppServerRegistryRuntimeSyncer(eventHub: hub,
                                                               attachHandler: { record, _, _, _, _, _, _, _, _ in
            attachLock.lock()
            attachedPanelIDs.append(record.panelID ?? "-")
            attachLock.unlock()
            return RegistryMonitorFakeRuntimeSession()
        })
        let monitor = AgentSessionRegistryMonitor(paths: paths,
                                                  fileManager: fileManager,
                                                  hub: hub,
                                                  tmuxResolver: TmuxStateResolver(ttl: 60) { _, _ in "" },
                                                  parentPIDLookup: { _ in nil },
                                                  runtimeSyncer: runtimeSyncer,
                                                  sidebarMessageSender: { message in sender.send(message) })
        try monitor.start()
        XCTAssertTrue(waitUntil(timeout: 10) {
            hub.fetch(workspaceID: "workspace-panel-only", sessionID: "session-panel-only", limit: 20)
                .events.contains { $0.type == .sessionStarted }
        }, "precondition: the session must be attached under the old panel")
        attachLock.lock()
        XCTAssertEqual(attachedPanelIDs, ["panel-old"])
        attachLock.unlock()
        let commandsBeforeCorrection = sender.all()

        // Pane/process resolution reports the SAME pane under a DIFFERENT
        // panel, workspace UNCHANGED — the panel-only correction path.
        let corrected = monitor.activeSessionForPanel(workspaceID: "workspace-panel-only",
                                                       panelID: "panel-new",
                                                       effectiveShellPID: nil,
                                                       tmuxPaneID: "pane-panel-only",
                                                       tmuxSocketPath: "/tmp/tidey-shared-panel-only.sock")
        XCTAssertEqual(corrected?.panelID, "panel-new")

        // The runtime's context switch is IMMEDIATE (synchronous, within
        // this very call) — not deferred to a later scan.
        attachLock.lock()
        XCTAssertEqual(attachedPanelIDs, ["panel-old", "panel-new"],
                       "the app-server runtime must be re-attached under the corrected panel immediately, got \(attachedPanelIDs)")
        attachLock.unlock()

        XCTAssertFalse(sender.all().dropFirst(commandsBeforeCorrection.count).contains { $0.contains("prompt --workspace_id=workspace-panel-only") },
                      "a panel-only correction (workspace unchanged) must never send a cleanup prompt, got \(sender.all().dropFirst(commandsBeforeCorrection.count))")
    }

    // Stop/removal: the CURRENT workspace must get a prompt cleanup.
    func testStopRemovalSendsPromptToCurrentWorkspace() throws {
        let fileManager = FileManager.default
        let supportDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("tidey-remote-bridge-monitor-\(UUID().uuidString)", isDirectory: true)
        let paths = BridgePaths(supportDirectory: supportDirectory)
        try paths.ensureSupportDirectoriesExist(fileManager: fileManager)
        defer { try? fileManager.removeItem(at: supportDirectory) }

        let rollout = supportDirectory.appendingPathComponent("rollout.jsonl")
        try (codexTaskStartedLine(turnID: "turn-stop") + "\n").write(to: rollout, atomically: true, encoding: .utf8)
        let registryURL = paths.codexAgentSessionsDirectory.appendingPathComponent("stop-session.json")
        try writeCodexRegistry(at: registryURL, workspaceID: "workspace-stop", sessionID: "stop-session", panelID: "panel-stop", transcriptPath: rollout)

        let hub = AgentEventHub()
        let sender = RecordingSidebarSender()
        let monitor = AgentSessionRegistryMonitor(paths: paths,
                                                  fileManager: fileManager,
                                                  hub: hub,
                                                  tmuxResolver: TmuxStateResolver(ttl: 60) { _, _ in "" },
                                                  parentPIDLookup: { _ in nil },
                                                  sidebarMessageSender: { message in sender.send(message) })
        try monitor.start()
        XCTAssertTrue(waitUntil(timeout: 10) {
            sender.all().contains("report_shell_state running --workspace_id=workspace-stop")
        })

        try fileManager.removeItem(at: registryURL)
        XCTAssertTrue(waitUntil(timeout: 10) {
            sender.all().contains("report_shell_state prompt --workspace_id=workspace-stop")
        }, "removal must send a prompt cleanup for the now-abandoned workspace, got \(sender.all())")
    }

    // An ALREADY-IDLE session's removal (no active turn, task_complete
    // already happened) must still get the plain prompt cleanup — but must
    // NEVER send a "completed" notification (that would fabricate a claim
    // about how the departed session just ended, when in fact it had
    // already ended earlier) or any needs-input/interactive-prompt
    // equivalent. This does not pull in the unaccepted workspace-status
    // architecture — it only exercises the existing plain
    // CodexSidebarMessages.prompt(...) cleanup path.
    func testIdleSessionRemovalOnlySendsPlainPromptNeverCompletedOrNeedsInput() throws {
        let fileManager = FileManager.default
        let supportDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("tidey-remote-bridge-monitor-\(UUID().uuidString)", isDirectory: true)
        let paths = BridgePaths(supportDirectory: supportDirectory)
        try paths.ensureSupportDirectoriesExist(fileManager: fileManager)
        defer { try? fileManager.removeItem(at: supportDirectory) }

        let rollout = supportDirectory.appendingPathComponent("rollout.jsonl")
        // Already idle: the turn started AND completed before the monitor
        // ever attaches — no active turn at removal time.
        let object: [String: Any] = ["type": "event_msg", "timestamp": "2026-06-08T22:06:27Z",
                                     "payload": ["type": "task_complete", "turn_id": "turn-idle", "last_agent_message": "done"]]
        let taskCompleteLine = String(data: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), encoding: .utf8)!
        try (codexTaskStartedLine(turnID: "turn-idle") + "\n" + taskCompleteLine + "\n")
            .write(to: rollout, atomically: true, encoding: .utf8)
        let registryURL = paths.codexAgentSessionsDirectory.appendingPathComponent("idle-session.json")
        try writeCodexRegistry(at: registryURL, workspaceID: "workspace-idle", sessionID: "idle-session", panelID: "panel-idle", transcriptPath: rollout)

        let hub = AgentEventHub()
        let sender = RecordingSidebarSender()
        let monitor = AgentSessionRegistryMonitor(paths: paths,
                                                  fileManager: fileManager,
                                                  hub: hub,
                                                  tmuxResolver: TmuxStateResolver(ttl: 60) { _, _ in "" },
                                                  parentPIDLookup: { _ in nil },
                                                  sidebarMessageSender: { message in sender.send(message) })
        try monitor.start()
        XCTAssertTrue(waitUntil(timeout: 10) {
            sender.all().contains("report_shell_state prompt --workspace_id=workspace-idle")
        }, "precondition: an already-idle session must bootstrap to prompt, not running")
        let commandsBeforeRemoval = sender.all()

        try fileManager.removeItem(at: registryURL)
        XCTAssertTrue(waitUntil(timeout: 10) {
            sender.all().dropFirst(commandsBeforeRemoval.count).contains("report_shell_state prompt --workspace_id=workspace-idle")
        }, "removal of an already-idle session must still send the plain prompt cleanup, got \(sender.all().dropFirst(commandsBeforeRemoval.count))")

        let newCommands = sender.all().dropFirst(commandsBeforeRemoval.count)
        XCTAssertFalse(newCommands.contains { $0.contains("notification.create") },
                       "an idle session's removal must never send a completed/needs-input notification, got \(Array(newCommands))")
    }

    // Shared workspace, two-phase departure: Codex and Claude both own
    // workspace-shared2. Codex departs first — Claude is STILL a current
    // owner, so no cleanup may fire (a departed-Codex-only candidate check
    // would wrongly clean it up here). Claude departs later, in a round
    // with NO Codex change at all — THIS is when the workspace truly has no
    // owner left, and the cleanup must fire exactly once.
    func testSharedWorkspaceTwoPhaseDepartureOnlyPromptsWhenTheLastOwnerLeaves() throws {
        let fileManager = FileManager.default
        let supportDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("tidey-remote-bridge-monitor-\(UUID().uuidString)", isDirectory: true)
        let paths = BridgePaths(supportDirectory: supportDirectory)
        try paths.ensureSupportDirectoriesExist(fileManager: fileManager)
        defer { try? fileManager.removeItem(at: supportDirectory) }

        let rollout = supportDirectory.appendingPathComponent("rollout.jsonl")
        try (codexTaskStartedLine(turnID: "turn-shared2") + "\n").write(to: rollout, atomically: true, encoding: .utf8)
        let codexRegistryURL = paths.codexAgentSessionsDirectory.appendingPathComponent("codex-shared2.json")
        try writeCodexRegistry(at: codexRegistryURL, workspaceID: "workspace-shared2", sessionID: "codex-shared2", panelID: "panel-codex", transcriptPath: rollout)
        let claudeRegistryURL = paths.claudeAgentSessionsDirectory.appendingPathComponent("claude-shared2.json")
        try writeClaudeRegistry(at: claudeRegistryURL, workspaceID: "workspace-shared2", sessionID: "claude-shared2", panelID: "panel-claude")

        let hub = AgentEventHub()
        let sender = RecordingSidebarSender()
        let monitor = AgentSessionRegistryMonitor(paths: paths,
                                                  fileManager: fileManager,
                                                  hub: hub,
                                                  tmuxResolver: TmuxStateResolver(ttl: 60) { _, _ in "" },
                                                  parentPIDLookup: { _ in nil },
                                                  sidebarMessageSender: { message in sender.send(message) })
        try monitor.start()
        XCTAssertTrue(waitUntil(timeout: 10) {
            sender.all().contains("report_shell_state running --workspace_id=workspace-shared2")
        })
        let commandsBeforeCodexDeparture = sender.all()

        // Phase 1: Codex departs. Claude is STILL present — must NOT prompt.
        // Barrier: wait, via a PURE read-only queue.sync snapshot (never
        // activeSessionForPanel, which itself mutates via
        // applyResolvedBinding), until Codex's record is genuinely gone AND
        // Claude's is still present, before asserting the negative.
        try fileManager.removeItem(at: codexRegistryURL)
        XCTAssertTrue(waitUntil(timeout: 10) {
            let snapshots = monitor.activeSessionSnapshots()
            return snapshots.contains { $0.workspaceID == "workspace-shared2" && $0.panelID == "panel-claude" }
                && !snapshots.contains { $0.workspaceID == "workspace-shared2" && $0.panelID == "panel-codex" }
        }, "precondition: Codex's departure scan must have completed while Claude's ownership is confirmed intact")
        XCTAssertFalse(sender.all().dropFirst(commandsBeforeCodexDeparture.count).contains { $0.contains("prompt --workspace_id=workspace-shared2") },
                      "Codex departing while Claude still owns the workspace must NOT prompt, got \(sender.all().dropFirst(commandsBeforeCodexDeparture.count))")
        let commandsBeforeClaudeDeparture = sender.all()

        // Phase 2: Claude ALSO departs, in a round with no Codex change at
        // all — this is the actually-final departure. Must prompt EXACTLY
        // once, not merely "at least once".
        try fileManager.removeItem(at: claudeRegistryURL)
        XCTAssertTrue(waitUntil(timeout: 10) {
            sender.all().dropFirst(commandsBeforeClaudeDeparture.count).contains("report_shell_state prompt --workspace_id=workspace-shared2")
        }, "the LAST owner (Claude, in a round with no Codex change) leaving must prompt, got \(sender.all())")
        let newPromptCount = sender.all().dropFirst(commandsBeforeClaudeDeparture.count)
            .filter { $0 == "report_shell_state prompt --workspace_id=workspace-shared2" }.count
        XCTAssertEqual(newPromptCount, 1, "the last-owner departure must prompt EXACTLY once, got \(sender.all().dropFirst(commandsBeforeClaudeDeparture.count))")
    }

    // Round 4 P0: removal order. retireStaleSessions now runs as the FIRST
    // step INSIDE the runtime-reconcile callback — i.e. AFTER the app-server
    // runtime's own old-generation fence/stop already ran (and its allowed
    // stop-driven interactivePromptResolved terminal may already have
    // published). This proves that terminal always precedes the
    // transcript's own sessionEnded (the Hub's removal boundary is the
    // LAST lifecycle event for this session, never an intermediate one an
    // old runtime terminal can still slip behind), and that the final
    // old-workspace sidebar command is the plain cleanup prompt (never a
    // late "running" resurrection from the runtime terminal).
    func testRemovalOrdersOldRuntimeTerminalBeforeTranscriptSessionEndedAndFinalSidebarIsPlainPrompt() throws {
        let fileManager = FileManager.default
        let supportDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("tidey-remote-bridge-monitor-\(UUID().uuidString)", isDirectory: true)
        let paths = BridgePaths(supportDirectory: supportDirectory)
        try paths.ensureSupportDirectoriesExist(fileManager: fileManager)
        defer { try? fileManager.removeItem(at: supportDirectory) }

        let rollout = supportDirectory.appendingPathComponent("rollout-removal-order.jsonl")
        try (codexTaskStartedLine(turnID: "turn-removal-order") + "\n").write(to: rollout, atomically: true, encoding: .utf8)
        let registryURL = paths.codexAgentSessionsDirectory.appendingPathComponent("codex-app-server-removal-order.json")
        let recordData = Data("""
        {
          "version": 1,
          "vendor": "codex",
          "workspace_id": "workspace-removal-order",
          "session_id": "session-removal-order",
          "panel_id": "panel-removal-order",
          "pid": 999999,
          "cwd": "/tmp",
          "created_at": "2026-06-07T00:00:00Z",
          "runtime": "codex_app_server",
          "app_server_socket": "/tmp/tidey-codex-app-server/removal-order.sock",
          "app_server_pid": \(getpid()),
          "rollout_path": "\(rollout.path)"
        }
        """.utf8)
        try recordData.write(to: registryURL)

        let hub = AgentEventHub()
        let sender = RecordingSidebarSender()
        var resolvedHandler: CodexAppServerConnection.InteractivePromptResolvedHandler?
        let runtime = RegistryMonitorFakeRuntimeSessionWithStopHook()
        let runtimeSyncer = CodexAppServerRegistryRuntimeSyncer(eventHub: hub,
                                                               sidebarMessageSender: { message in sender.send(message) },
                                                               attachHandler: { _, _, _, _, _, _, onInteractivePromptResolved, _, _ in
            resolvedHandler = onInteractivePromptResolved
            return runtime
        })
        let monitor = AgentSessionRegistryMonitor(paths: paths,
                                                  fileManager: fileManager,
                                                  hub: hub,
                                                  tmuxResolver: TmuxStateResolver(ttl: 60) { _, _ in "" },
                                                  parentPIDLookup: { _ in nil },
                                                  runtimeSyncer: runtimeSyncer,
                                                  sidebarMessageSender: { message in sender.send(message) })
        try monitor.start()
        XCTAssertTrue(waitUntil(timeout: 10) {
            hub.fetch(workspaceID: "workspace-removal-order", sessionID: "session-removal-order", limit: 20)
                .events.contains { $0.type == .sessionStarted }
        }, "precondition: the session must be attached/started")
        let handler = try XCTUnwrap(resolvedHandler)

        // stop()-driven terminal cleanup, fired SYNCHRONOUSLY from inside
        // the runtime's stop() — allowed even from a retiring generation.
        runtime.onStop = {
            handler(AgentEvent(eventID: "removal-order-runtime-terminal",
                                seq: hub.nextSyntheticSeq(sessionID: "session-removal-order"),
                                vendor: "codex",
                                workspaceID: "workspace-removal-order",
                                sessionID: "session-removal-order",
                                timestamp: "2026-06-07T00:00:01Z",
                                type: .interactivePromptResolved,
                                role: nil,
                                text: nil,
                                name: nil,
                                input: nil,
                                output: nil,
                                toolCallID: nil,
                                metadata: ["source": "old-runtime-stop-terminal"]))
        }

        // Remove the record entirely — a real retirement, not a migration.
        try fileManager.removeItem(at: registryURL)

        XCTAssertTrue(waitUntil(timeout: 10) {
            hub.fetch(workspaceID: "workspace-removal-order", sessionID: "session-removal-order", limit: 30)
                .events.contains { $0.type == .sessionEnded }
        }, "precondition: the transcript session must be retired")

        let history = hub.fetch(workspaceID: "workspace-removal-order", sessionID: "session-removal-order", limit: 30).events
        let terminalSeq = try XCTUnwrap(history.first { $0.metadata?["source"] == "old-runtime-stop-terminal" }?.seq,
                                       "the old runtime's stop-driven terminal must reach the Hub")
        let sessionEndedSeq = try XCTUnwrap(history.first { $0.type == .sessionEnded }?.seq)
        XCTAssertLessThan(terminalSeq, sessionEndedSeq,
                         "the old runtime's stop-driven terminal must precede the transcript's own sessionEnded, got terminal seq=\(terminalSeq) sessionEnded seq=\(sessionEndedSeq)")
        XCTAssertFalse(history.contains { $0.seq > sessionEndedSeq },
                      "no event for the removed session may follow its own sessionEnded, got \(history.map { ($0.type, $0.seq) })")

        XCTAssertEqual(sender.all().last, "report_shell_state prompt --workspace_id=workspace-removal-order",
                       "the final old-workspace sidebar command must be the plain cleanup prompt, never a late running resurrection, got \(sender.all())")
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

private final class RegistryMonitorFakeRuntimeSession: CodexAppServerRuntimeSessionControlling {
    func setRegistryRootThreadID(_ rawThreadID: String?) {}

    func ensureThreadSubscription() {}

    func refreshActiveThread() {}

    func isStopped() -> Bool {
        false
    }

    func pendingApprovalPromptEvents() -> [AgentEvent] {
        []
    }

    func submitApproval(promptID: String,
                        targetIndex: Int,
                        clientRequestID: String?,
                        lifecycleToken: String?) throws -> CodexAppServerApprovalSubmitOutcome {
        throw BridgeInternalError.notFound("No prompts in registry monitor fake runtime.")
    }

    func submitMessage(text: String, clientRequestID: String?) throws {}

    func stop() {}
}

private final class RegistryMonitorFakeRuntimeSessionWithStopHook: CodexAppServerRuntimeSessionControlling {
    var onStop: (() -> Void)?

    func setRegistryRootThreadID(_ rawThreadID: String?) {}

    func ensureThreadSubscription() {}

    func refreshActiveThread() {}

    func isStopped() -> Bool {
        false
    }

    func pendingApprovalPromptEvents() -> [AgentEvent] {
        []
    }

    func submitApproval(promptID: String,
                        targetIndex: Int,
                        clientRequestID: String?,
                        lifecycleToken: String?) throws -> CodexAppServerApprovalSubmitOutcome {
        throw BridgeInternalError.notFound("No prompts in registry monitor fake runtime.")
    }

    func submitMessage(text: String, clientRequestID: String?) throws {}

    func stop() {
        onStop?()
    }
}
