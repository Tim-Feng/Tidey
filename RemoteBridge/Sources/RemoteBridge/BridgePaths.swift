import Foundation

struct BridgePaths {
    let supportDirectory: URL
    let pairTokenFileURL: URL
    let agentSessionsDirectory: URL

    init(fileManager: FileManager = .default) {
        let base = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent("Tidey Remote Bridge", isDirectory: true)
        supportDirectory = base
        pairTokenFileURL = base.appendingPathComponent("pair-token.json", isDirectory: false)
        agentSessionsDirectory = base.appendingPathComponent("agent-sessions", isDirectory: true)
    }

    var claudeAgentSessionsDirectory: URL {
        agentSessionsDirectory.appendingPathComponent("claude", isDirectory: true)
    }

    var codexAgentSessionsDirectory: URL {
        agentSessionsDirectory.appendingPathComponent("codex", isDirectory: true)
    }

    func ensureSupportDirectoriesExist(fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: agentSessionsDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: claudeAgentSessionsDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: codexAgentSessionsDirectory, withIntermediateDirectories: true)
    }
}
