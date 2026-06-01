import Foundation

struct TmuxSnapshot: Sendable {
    let paneToSessionName: [String: String]
    let sessionToClientPIDs: [String: [Int32]]

    func clientPIDs(forPaneID paneID: String) -> [Int32]? {
        guard let sessionName = paneToSessionName[paneID] else {
            return nil
        }
        return sessionToClientPIDs[sessionName]
    }
}

struct TmuxPaneIdentity: Sendable, Equatable {
    let workspaceID: String
    let panelID: String
}

struct TmuxPaneIdentitySnapshot: Sendable {
    let identitiesByPaneID: [String: TmuxPaneIdentity]
}

final class TmuxStateResolver {
    typealias CommandRunner = @Sendable (_ socketPath: String, _ arguments: [String]) throws -> String
    private static let tmuxDiscoveryCandidates = [
        "/opt/homebrew/bin/tmux",
        "/usr/local/bin/tmux",
        "/opt/local/bin/tmux",
        "/usr/bin/tmux",
    ]
    private static let resolvedTmuxBinaryPath = discoverTmuxBinaryPath()
    private static let missingTmuxLogState = DispatchQueue(label: "com.tidey.remote-bridge.tmux-binary-log-state")
    private static var hasLoggedMissingTmux = false
    private static let envLogState = DispatchQueue(label: "com.tidey.remote-bridge.tmux-env-log-state")
    private static var hasLoggedRunnerEnv = false
    private static let liveCommandRunner: CommandRunner = { socketPath, arguments in
        guard let tmuxBinaryPath = resolvedTmuxBinaryPath else {
            missingTmuxLogState.sync {
                if !hasLoggedMissingTmux {
                    hasLoggedMissingTmux = true
                    BridgeLogger.server.error("tmux resolver could not find a tmux binary in supported paths")
                }
            }
            throw NSError(domain: "TmuxStateResolver",
                          code: 127,
                          userInfo: [NSLocalizedDescriptionKey: "tmux not found"])
        }

        envLogState.sync {
            if !hasLoggedRunnerEnv {
                hasLoggedRunnerEnv = true
                let environment = ProcessInfo.processInfo.environment
                BridgeLogger.server.debug("tmux runner env HOME=\(environment["HOME"] ?? "-", privacy: .public) USER=\(environment["USER"] ?? "-", privacy: .public) TMPDIR=\(environment["TMPDIR"] ?? "-", privacy: .public) PWD=\(environment["PWD"] ?? "-", privacy: .public)")
            }
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: tmuxBinaryPath)
        process.arguments = ["-S", socketPath] + arguments
        var environment = ProcessInfo.processInfo.environment
        environment["LC_CTYPE"] = "UTF-8"
        environment["LANG"] = "en_US.UTF-8"
        process.environment = environment

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        let stdoutText = String(data: outputData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let stderrText = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        BridgeLogger.server.debug("tmux command argv=\(process.arguments?.joined(separator: " ") ?? "-", privacy: .public) stdout_bytes=\(outputData.count, privacy: .public) stderr_bytes=\(errorData.count, privacy: .public) stdout=\(String(stdoutText.prefix(500)), privacy: .public) stderr=\(String(stderrText.prefix(500)), privacy: .public)")
        guard process.terminationStatus == 0 else {
            let stderr = stderrText.isEmpty ? "tmux exited \(process.terminationStatus)" : stderrText
            throw NSError(domain: "TmuxStateResolver",
                          code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: stderr])
        }
        return stdoutText
    }

    private struct CacheEntry {
        let snapshot: TmuxSnapshot
        let loadedAt: Date
    }

    private struct PaneIdentityCacheEntry {
        let snapshot: TmuxPaneIdentitySnapshot
        let loadedAt: Date
    }

    private let queue = DispatchQueue(label: "com.tidey.remote-bridge.tmux-state")
    private let ttl: TimeInterval
    private let commandRunner: CommandRunner
    private var cache = [String: CacheEntry]()
    private var paneIdentityCache = [String: PaneIdentityCacheEntry]()

    init(ttl: TimeInterval = 5,
         commandRunner: @escaping CommandRunner = TmuxStateResolver.liveCommandRunner) {
        self.ttl = ttl
        self.commandRunner = commandRunner
    }

    func clientPIDs(forPaneID paneID: String, socketPath: String) -> [Int32]? {
        queue.sync {
            BridgeLogger.server.debug("tmux resolver request pane_id=\(paneID, privacy: .public) socket=\(socketPath, privacy: .public)")
            if let snapshot = loadSnapshot(socketPath: socketPath, forceRefresh: false),
               let pids = snapshot.clientPIDs(forPaneID: paneID) {
                let sessionName = snapshot.paneToSessionName[paneID] ?? "-"
                BridgeLogger.server.debug("tmux resolver snapshot pane_count=\(snapshot.paneToSessionName.count, privacy: .public) session_count=\(snapshot.sessionToClientPIDs.count, privacy: .public) pane_session=\(sessionName, privacy: .public) client_pids=\(String(describing: pids), privacy: .public)")
                return pids
            }
            let refreshedSnapshot = loadSnapshot(socketPath: socketPath, forceRefresh: true)
            let refreshedPIDs = refreshedSnapshot?.clientPIDs(forPaneID: paneID)
            let sessionName = refreshedSnapshot?.paneToSessionName[paneID] ?? "-"
            BridgeLogger.server.debug("tmux resolver refreshed pane_count=\(refreshedSnapshot?.paneToSessionName.count ?? 0, privacy: .public) session_count=\(refreshedSnapshot?.sessionToClientPIDs.count ?? 0, privacy: .public) pane_session=\(sessionName, privacy: .public) client_pids=\(String(describing: refreshedPIDs), privacy: .public)")
            return refreshedPIDs
        }
    }

    func paneIdentity(forPaneID paneID: String, socketPath: String) -> TmuxPaneIdentity? {
        queue.sync {
            loadPaneIdentitySnapshot(socketPath: socketPath)?.identitiesByPaneID[paneID]
        }
    }

    func invalidate(socketPath: String? = nil) {
        queue.sync {
            if let socketPath {
                cache.removeValue(forKey: socketPath)
                paneIdentityCache.removeValue(forKey: socketPath)
            } else {
                cache.removeAll()
                paneIdentityCache.removeAll()
            }
        }
    }

    private func loadSnapshot(socketPath: String, forceRefresh: Bool) -> TmuxSnapshot? {
        if !forceRefresh,
           let entry = cache[socketPath],
           Date().timeIntervalSince(entry.loadedAt) < ttl {
            return entry.snapshot
        }

        do {
            let panesOutput = try commandRunner(socketPath, ["list-panes", "-a", "-F", "#{pane_id}|#{session_name}"])
            let clientsOutput = try commandRunner(socketPath, ["list-clients", "-F", "#{client_pid}|#{session_name}"])
            let snapshot = Self.snapshot(panesOutput: panesOutput, clientsOutput: clientsOutput)
            cache[socketPath] = CacheEntry(snapshot: snapshot, loadedAt: Date())
            return snapshot
        } catch {
            BridgeLogger.server.error("tmux resolver refresh failed socket=\(socketPath, privacy: .public) error=\(String(describing: error), privacy: .public)")
            return cache[socketPath]?.snapshot
        }
    }

    private static func snapshot(panesOutput: String, clientsOutput: String) -> TmuxSnapshot {
        let panePairs = panesOutput
            .split(whereSeparator: \.isNewline)
            .compactMap(parsePaneLine(_:))
        let clientPairs = clientsOutput
            .split(whereSeparator: \.isNewline)
            .compactMap(parseClientLine(_:))

        let paneToSessionName = Dictionary(uniqueKeysWithValues: panePairs)
        let sessionToClientPIDs = Dictionary(grouping: clientPairs, by: \.sessionName)
            .mapValues { pairs in
                Array(Set(pairs.map(\.clientPID))).sorted()
            }

        return TmuxSnapshot(paneToSessionName: paneToSessionName,
                            sessionToClientPIDs: sessionToClientPIDs)
    }

    private func loadPaneIdentitySnapshot(socketPath: String) -> TmuxPaneIdentitySnapshot? {
        if let entry = paneIdentityCache[socketPath],
           Date().timeIntervalSince(entry.loadedAt) < ttl {
            return entry.snapshot
        }

        do {
            let output = try commandRunner(socketPath, ["list-panes",
                                                       "-a",
                                                       "-F",
                                                       "#{pane_id}|#{@tidey_workspace_id}|#{@tidey_panel_id}"])
            let snapshot = Self.paneIdentitySnapshot(output: output)
            paneIdentityCache[socketPath] = PaneIdentityCacheEntry(snapshot: snapshot,
                                                                   loadedAt: Date())
            return snapshot
        } catch {
            BridgeLogger.server.debug("tmux resolver pane identity snapshot failed socket=\(socketPath, privacy: .public) error=\(String(describing: error), privacy: .public)")
            return paneIdentityCache[socketPath]?.snapshot
        }
    }

    private static func paneIdentitySnapshot(output: String) -> TmuxPaneIdentitySnapshot {
        let identities = output
            .split(whereSeparator: \.isNewline)
            .compactMap(parsePaneIdentityLine(_:))
        return TmuxPaneIdentitySnapshot(identitiesByPaneID: Dictionary(uniqueKeysWithValues: identities))
    }

    private static func parsePaneLine(_ line: Substring) -> (String, String)? {
        let parts = line.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else {
            return nil
        }
        let paneID = String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines)
        let sessionName = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !paneID.isEmpty, !sessionName.isEmpty else {
            return nil
        }
        return (paneID, sessionName)
    }

    private static func parsePaneIdentityLine(_ line: Substring) -> (String, TmuxPaneIdentity)? {
        let parts = line.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3 else {
            return nil
        }
        let paneID = String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines)
        let workspaceID = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
        let panelID = String(parts[2]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !paneID.isEmpty, !workspaceID.isEmpty, !panelID.isEmpty else {
            return nil
        }
        return (paneID, TmuxPaneIdentity(workspaceID: workspaceID, panelID: panelID))
    }

    private static func parseClientLine(_ line: Substring) -> (clientPID: Int32, sessionName: String)? {
        let parts = line.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2,
              let pid = Int32(parts[0]) else {
            return nil
        }
        let sessionName = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sessionName.isEmpty else {
            return nil
        }
        return (pid, sessionName)
    }

    static func discoverTmuxBinaryPath(fileManager: FileManager = .default,
                                       candidates: [String] = tmuxDiscoveryCandidates) -> String? {
        candidates.first { fileManager.isExecutableFile(atPath: $0) }
    }
}
