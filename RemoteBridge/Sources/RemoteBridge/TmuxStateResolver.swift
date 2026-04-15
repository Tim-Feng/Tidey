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

final class TmuxStateResolver {
    typealias CommandRunner = @Sendable (_ socketPath: String, _ arguments: [String]) throws -> String
    private static let liveCommandRunner: CommandRunner = { socketPath, arguments in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["tmux", "-S", socketPath] + arguments

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            let stderr = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "tmux exited \(process.terminationStatus)"
            throw NSError(domain: "TmuxStateResolver",
                          code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: stderr])
        }
        return String(data: outputData, encoding: .utf8) ?? ""
    }

    private struct CacheEntry {
        let snapshot: TmuxSnapshot
        let loadedAt: Date
    }

    private let queue = DispatchQueue(label: "com.tidey.remote-bridge.tmux-state")
    private let ttl: TimeInterval
    private let commandRunner: CommandRunner
    private var cache = [String: CacheEntry]()

    init(ttl: TimeInterval = 5,
         commandRunner: @escaping CommandRunner = TmuxStateResolver.liveCommandRunner) {
        self.ttl = ttl
        self.commandRunner = commandRunner
    }

    func clientPIDs(forPaneID paneID: String, socketPath: String) -> [Int32]? {
        queue.sync {
            if let snapshot = loadSnapshot(socketPath: socketPath, forceRefresh: false),
               let pids = snapshot.clientPIDs(forPaneID: paneID) {
                return pids
            }
            return loadSnapshot(socketPath: socketPath, forceRefresh: true)?.clientPIDs(forPaneID: paneID)
        }
    }

    func invalidate(socketPath: String? = nil) {
        queue.sync {
            if let socketPath {
                cache.removeValue(forKey: socketPath)
            } else {
                cache.removeAll()
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
            let panesOutput = try commandRunner(socketPath, ["list-panes", "-a", "-F", "#{pane_id}\t#{session_name}"])
            let clientsOutput = try commandRunner(socketPath, ["list-clients", "-F", "#{client_pid}\t#{session_name}"])
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

    private static func parsePaneLine(_ line: Substring) -> (String, String)? {
        let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
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

    private static func parseClientLine(_ line: Substring) -> (clientPID: Int32, sessionName: String)? {
        let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
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
}
