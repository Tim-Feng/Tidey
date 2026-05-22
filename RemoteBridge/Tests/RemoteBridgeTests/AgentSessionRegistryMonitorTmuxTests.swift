import XCTest
@testable import RemoteBridge

final class AgentSessionRegistryMonitorTmuxTests: XCTestCase {
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
            XCTAssertEqual(Array(arguments.prefix(5)), ["show-options", "-p", "-v", "-t", "%6"])
            switch arguments.last {
            case "@tidey_workspace_id":
                return "current-workspace\n"
            case "@tidey_panel_id":
                return "current-panel\n"
            default:
                XCTFail("unexpected tmux arguments \(arguments)")
                return ""
            }
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
}
