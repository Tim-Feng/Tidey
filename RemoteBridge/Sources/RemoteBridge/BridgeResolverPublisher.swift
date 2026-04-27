import Foundation

struct BridgeResolverPublishPayload: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let hostID: String
    let tunnelEndpoint: BridgePairEndpoint
    let publishedAt: Date
    let expiresAt: Date

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case hostID = "host_id"
        case tunnelEndpoint = "tunnel_endpoint"
        case publishedAt = "published_at"
        case expiresAt = "expires_at"
    }
}

struct BridgeResolverPublishRequest: Equatable, Sendable {
    let url: URL
    let bearerToken: String
    let payload: BridgeResolverPublishPayload
}

enum BridgeResolverPublishError: Error, Equatable {
    case unauthorized
    case badStatus(Int)
    case transport(String)
}

protocol BridgeResolverClient {
    func publish(_ request: BridgeResolverPublishRequest) throws
}

final class BridgeResolverPublishSecretStore {
    private struct SecretRecord: Codable {
        let publishSecret: String

        enum CodingKeys: String, CodingKey {
            case publishSecret = "publish_secret"
        }
    }

    private let paths: BridgePaths
    private let fileManager: FileManager
    private let tokenGenerator: () -> String

    init(paths: BridgePaths = BridgePaths(),
         fileManager: FileManager = .default,
         tokenGenerator: @escaping () -> String = BridgeSecureTokenGenerator.generateToken) {
        self.paths = paths
        self.fileManager = fileManager
        self.tokenGenerator = tokenGenerator
    }

    func loadOrCreateSecret() throws -> String {
        if fileManager.fileExists(atPath: paths.resolverPublishSecretFileURL.path) {
            let data = try Data(contentsOf: paths.resolverPublishSecretFileURL)
            return try JSONDecoder().decode(SecretRecord.self, from: data).publishSecret
        }

        try fileManager.createDirectory(at: paths.supportDirectory, withIntermediateDirectories: true)
        let secret = tokenGenerator()
        let data = try JSONEncoder().encode(SecretRecord(publishSecret: secret))
        try data.write(to: paths.resolverPublishSecretFileURL, options: .atomic)
        return secret
    }
}

final class BridgeResolverPublisher {
    private let resolverBaseURL: URL
    private let hostIdentityStore: BridgeHostIdentityStore
    private let publishSecretStore: BridgeResolverPublishSecretStore
    private let client: BridgeResolverClient
    private let nowProvider: () -> Date
    private let lifetime: TimeInterval

    init(resolverBaseURL: URL,
         hostIdentityStore: BridgeHostIdentityStore,
         publishSecretStore: BridgeResolverPublishSecretStore,
         client: BridgeResolverClient,
         nowProvider: @escaping () -> Date = Date.init,
         lifetime: TimeInterval = 10 * 60) {
        self.resolverBaseURL = resolverBaseURL
        self.hostIdentityStore = hostIdentityStore
        self.publishSecretStore = publishSecretStore
        self.client = client
        self.nowProvider = nowProvider
        self.lifetime = lifetime
    }

    func publishTunnelEndpoint(_ endpoint: BridgePairEndpoint) throws {
        let identity = try hostIdentityStore.loadOrCreateIdentity()
        let now = nowProvider()
        let url = resolverBaseURL
            .appendingPathComponent("v1")
            .appendingPathComponent("resolver")
            .appendingPathComponent("hosts")
            .appendingPathComponent(identity.hostID)
            .appendingPathComponent("tunnel")
        let request = BridgeResolverPublishRequest(
            url: url,
            bearerToken: try publishSecretStore.loadOrCreateSecret(),
            payload: BridgeResolverPublishPayload(schemaVersion: 1,
                                                  hostID: identity.hostID,
                                                  tunnelEndpoint: endpoint,
                                                  publishedAt: now,
                                                  expiresAt: now.addingTimeInterval(lifetime))
        )
        try client.publish(request)
    }
}
