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
          "app_server_pid": \(getpid())
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
        XCTAssertTrue(fileManager.fileExists(atPath: registryURL.path))
        XCTAssertEqual(runtimeSyncer.latestRecords.map(\.sessionID), ["session-app-server"])
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
                                                               attachHandler: { _, _, _, onAgentEvent, _, _ in
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
    func canSubmitMessage() -> Bool {
        true
    }

    func ensureThreadSubscription() {}

    func submitApproval(promptID: String, targetIndex: Int) throws -> AgentEvent {
        throw BridgeInternalError.notFound("No prompts in registry monitor fake runtime.")
    }

    func submitMessage(text: String) throws {}

    func stop() {}
}
