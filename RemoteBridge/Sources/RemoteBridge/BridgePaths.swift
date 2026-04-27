import Foundation

struct BridgePaths {
    let supportDirectory: URL
    let pairTokenFileURL: URL
    let hostIdentityFileURL: URL
    let deviceCredentialsFileURL: URL
    let cloudflaredStateFileURL: URL
    let resolverPublishSecretFileURL: URL
    let agentSessionsDirectory: URL

    init(supportDirectory: URL) {
        self.supportDirectory = supportDirectory
        pairTokenFileURL = supportDirectory.appendingPathComponent("pair-token.json", isDirectory: false)
        hostIdentityFileURL = supportDirectory.appendingPathComponent("host-identity.json", isDirectory: false)
        deviceCredentialsFileURL = supportDirectory.appendingPathComponent("device-credentials.json", isDirectory: false)
        cloudflaredStateFileURL = supportDirectory.appendingPathComponent("cloudflared-state.json", isDirectory: false)
        resolverPublishSecretFileURL = supportDirectory.appendingPathComponent("resolver-publish-secret.json", isDirectory: false)
        agentSessionsDirectory = supportDirectory.appendingPathComponent("agent-sessions", isDirectory: true)
    }

    init(fileManager: FileManager = .default) {
        let base = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent("Tidey Remote Bridge", isDirectory: true)
        self.init(supportDirectory: base)
    }

    var claudeAgentSessionsDirectory: URL {
        agentSessionsDirectory.appendingPathComponent("claude", isDirectory: true)
    }

    var codexAgentSessionsDirectory: URL {
        agentSessionsDirectory.appendingPathComponent("codex", isDirectory: true)
    }

    func agentSessionsDirectory(for vendorID: String) -> URL {
        agentSessionsDirectory.appendingPathComponent(vendorID, isDirectory: true)
    }

    func ensureSupportDirectoriesExist(fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: agentSessionsDirectory, withIntermediateDirectories: true)
        for vendor in AgentVendorRegistry.all {
            try fileManager.createDirectory(at: agentSessionsDirectory(for: vendor.registryDirectoryName),
                                            withIntermediateDirectories: true)
        }
    }
}
