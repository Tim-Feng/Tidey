import CryptoKit
import Darwin
import Foundation
import Security

struct BridgeHostIdentity: Codable, Equatable, Sendable {
    let hostID: String
    let displayName: String
    let createdAt: Date
}

struct BridgePairEndpoint: Codable, Equatable, Sendable {
    let scheme: String
    let host: String
    let port: Int?
    let path: String
}

struct BridgePairPayload: Codable, Equatable, Sendable {
    let type: String
    let version: Int
    let hostID: String
    let displayName: String
    let lanEndpoints: [BridgePairEndpoint]
    let tailscaleEndpoint: BridgePairEndpoint?
    let tunnelEndpoint: BridgePairEndpoint?
    let resolverEndpoint: URL?
    let pairSecret: String
    let issuedAt: Date
    let expiresAt: Date

    enum CodingKeys: String, CodingKey {
        case type
        case version
        case hostID = "host_id"
        case displayName = "display_name"
        case lanEndpoints = "lan_endpoints"
        case tailscaleEndpoint = "tailscale_endpoint"
        case tunnelEndpoint = "tunnel_endpoint"
        case resolverEndpoint = "resolver_endpoint"
        case pairSecret = "pair_secret"
        case issuedAt = "issued_at"
        case expiresAt = "expires_at"
    }
}

enum BridgeLANEndpointAddressFamily: Sendable {
    case ipv4
    case ipv6
}

struct BridgeLANEndpointCandidate: Equatable, Sendable {
    let interfaceName: String
    let host: String
    let addressFamily: BridgeLANEndpointAddressFamily
    let isUp: Bool
    let isRunning: Bool
    let isLoopback: Bool
}

enum BridgeLANEndpointResolver {
    static func resolve(port: Int) -> [BridgePairEndpoint] {
        endpoints(from: BridgeNetworkInterfaceResolver.currentInterfaceCandidates(), port: port)
    }

    static func endpoints(from candidates: [BridgeLANEndpointCandidate],
                          port: Int) -> [BridgePairEndpoint] {
        var seenHosts = Set<String>()
        return candidates
            .filter { candidate in
                candidate.isUp &&
                candidate.isRunning &&
                !candidate.isLoopback &&
                candidate.addressFamily == .ipv4 &&
                isAllowedInterfaceName(candidate.interfaceName) &&
                !isLinkLocalOrLoopbackHost(candidate.host)
            }
            .compactMap { candidate in
                guard seenHosts.insert(candidate.host).inserted else {
                    return nil
                }
                return BridgePairEndpoint(scheme: "ws",
                                          host: candidate.host,
                                          port: port,
                                          path: "/")
            }
    }

    private static func isAllowedInterfaceName(_ name: String) -> Bool {
        guard name.hasPrefix("anpi") == false,
              name.hasPrefix("awdl") == false,
              name.hasPrefix("gif") == false,
              name.hasPrefix("stf") == false,
              name.hasPrefix("utun") == false,
              name.hasPrefix("utap") == false,
              name.hasPrefix("ipsec") == false else {
            return false
        }
        return name.hasPrefix("en") ||
               name.hasPrefix("bridge")
    }

    private static func isLinkLocalOrLoopbackHost(_ host: String) -> Bool {
        let lowercaseHost = host.lowercased()
        return host == "0.0.0.0" ||
               host.hasPrefix("127.") ||
               host.hasPrefix("169.254.") ||
               lowercaseHost == "::1" ||
               lowercaseHost.hasPrefix("fe80:")
    }
}

enum BridgeTailscaleEndpointResolver {
    static func resolve(port: Int) -> BridgePairEndpoint? {
        endpoints(from: BridgeNetworkInterfaceResolver.currentInterfaceCandidates(), port: port).first
    }

    static func endpoints(from candidates: [BridgeLANEndpointCandidate],
                          port: Int) -> [BridgePairEndpoint] {
        var seenHosts = Set<String>()
        return candidates
            .filter { candidate in
                candidate.isUp &&
                candidate.isRunning &&
                !candidate.isLoopback &&
                isTailscaleHost(candidate)
            }
            .sorted { lhs, rhs in
                priority(for: lhs) < priority(for: rhs)
            }
            .compactMap { candidate in
                let host = hostWithoutZoneIdentifier(candidate.host)
                guard seenHosts.insert(host.lowercased()).inserted else {
                    return nil
                }
                return BridgePairEndpoint(scheme: "ws",
                                          host: host,
                                          port: port,
                                          path: "/")
            }
    }

    static func isTailscaleIPv4Host(_ host: String) -> Bool {
        guard let firstOctet = host.split(separator: ".").first,
              firstOctet == "100" else {
            return false
        }
        return host.split(separator: ".").count == 4
    }

    static func isTailscaleIPv6Host(_ host: String) -> Bool {
        hostWithoutZoneIdentifier(host)
            .lowercased()
            .hasPrefix("fd7a:115c:a1e0:")
    }

    private static func isTailscaleHost(_ candidate: BridgeLANEndpointCandidate) -> Bool {
        switch candidate.addressFamily {
        case .ipv4:
            return isTailscaleIPv4Host(candidate.host)
        case .ipv6:
            return isTailscaleIPv6Host(candidate.host)
        }
    }

    private static func priority(for candidate: BridgeLANEndpointCandidate) -> Int {
        switch candidate.addressFamily {
        case .ipv4:
            return 0
        case .ipv6:
            return 1
        }
    }

    private static func hostWithoutZoneIdentifier(_ host: String) -> String {
        guard let percentIndex = host.firstIndex(of: "%") else {
            return host
        }
        return String(host[..<percentIndex])
    }
}

enum BridgeNetworkInterfaceResolver {
    static func currentInterfaceCandidates() -> [BridgeLANEndpointCandidate] {
        var interfaceList: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaceList) == 0, let firstInterface = interfaceList else {
            return []
        }
        defer { freeifaddrs(interfaceList) }

        var candidates = [BridgeLANEndpointCandidate]()
        var cursor: UnsafeMutablePointer<ifaddrs>? = firstInterface
        while let interface = cursor {
            defer { cursor = interface.pointee.ifa_next }
            guard let address = interface.pointee.ifa_addr else {
                continue
            }
            let family = Int32(address.pointee.sa_family)
            let addressFamily: BridgeLANEndpointAddressFamily
            switch family {
            case AF_INET:
                addressFamily = .ipv4
            case AF_INET6:
                addressFamily = .ipv6
            default:
                continue
            }

            var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(address,
                                     socklen_t(address.pointee.sa_len),
                                     &hostBuffer,
                                     socklen_t(hostBuffer.count),
                                     nil,
                                     0,
                                     NI_NUMERICHOST)
            guard result == 0 else {
                continue
            }
            let flags = Int32(interface.pointee.ifa_flags)
            candidates.append(BridgeLANEndpointCandidate(interfaceName: String(cString: interface.pointee.ifa_name),
                                                        host: String(cString: hostBuffer),
                                                        addressFamily: addressFamily,
                                                        isUp: (flags & IFF_UP) != 0,
                                                        isRunning: (flags & IFF_RUNNING) != 0,
                                                        isLoopback: (flags & IFF_LOOPBACK) != 0))
        }
        return candidates
    }
}

enum BridgePairPayloadQRCodeEncoder {
    static func qrPayloadString(for payload: BridgePairPayload) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return base64URLEncoded(try encoder.encode(payload))
    }

    static func decodeQRCodePayloadString(_ string: String) -> Data? {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder > 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }
        return Data(base64Encoded: base64)
    }

    private static func base64URLEncoded(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

struct BridgePairExchangeRequest: Codable, Equatable, Sendable {
    let action: String
    let hostID: String
    let pairSecret: String
    let deviceID: String
    let deviceName: String
    let devicePublicKey: String?

    enum CodingKeys: String, CodingKey {
        case action
        case hostID = "host_id"
        case pairSecret = "pair_secret"
        case deviceID = "device_id"
        case deviceName = "device_name"
        case devicePublicKey = "device_public_key"
    }
}

struct BridgePairExchangeResult: Codable, Equatable, Sendable {
    let hostID: String
    let displayName: String
    let deviceCredential: String
    let credentialType: String

    enum CodingKeys: String, CodingKey {
        case hostID = "host_id"
        case displayName = "display_name"
        case deviceCredential = "device_credential"
        case credentialType = "credential_type"
    }
}

struct BridgeIssuedDeviceCredential: Equatable, Sendable {
    let deviceID: String
    let token: String
}

final class BridgeHostIdentityStore {
    private let paths: BridgePaths
    private let fileManager: FileManager
    private let idProvider: () -> String
    private let displayNameProvider: () -> String
    private let nowProvider: () -> Date

    init(paths: BridgePaths = BridgePaths(),
         fileManager: FileManager = .default,
         idProvider: @escaping () -> String = { UUID().uuidString },
         displayNameProvider: @escaping () -> String = {
             Host.current().localizedName ?? "Tidey Mac"
         },
         nowProvider: @escaping () -> Date = Date.init) {
        self.paths = paths
        self.fileManager = fileManager
        self.idProvider = idProvider
        self.displayNameProvider = displayNameProvider
        self.nowProvider = nowProvider
    }

    func loadOrCreateIdentity() throws -> BridgeHostIdentity {
        if fileManager.fileExists(atPath: paths.hostIdentityFileURL.path) {
            let data = try Data(contentsOf: paths.hostIdentityFileURL)
            let identity = try JSONDecoder().decode(BridgeHostIdentity.self, from: data)
            let normalizedDisplayName = Self.normalizedDisplayName(identity.displayName)
            guard normalizedDisplayName != identity.displayName else {
                return identity
            }
            let normalizedIdentity = BridgeHostIdentity(hostID: identity.hostID,
                                                        displayName: normalizedDisplayName,
                                                        createdAt: identity.createdAt)
            try save(normalizedIdentity)
            return normalizedIdentity
        }
        try fileManager.createDirectory(at: paths.supportDirectory, withIntermediateDirectories: true)
        let identity = BridgeHostIdentity(hostID: idProvider(),
                                          displayName: Self.normalizedDisplayName(displayNameProvider()),
                                          createdAt: nowProvider())
        try save(identity)
        return identity
    }

    private func save(_ identity: BridgeHostIdentity) throws {
        let data = try JSONEncoder().encode(identity)
        try data.write(to: paths.hostIdentityFileURL, options: .atomic)
    }

    private static func normalizedDisplayName(_ displayName: String) -> String {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Tidey Mac" : trimmed
    }
}

final class BridgePairSessionStore {
    private struct Session {
        let hostID: String
        let secret: String
        let expiresAt: Date
    }

    private var sessionsBySecret = [String: Session]()
    private let secretGenerator: () -> String
    private let nowProvider: () -> Date
    private let lifetime: TimeInterval
    private let cleanupGracePeriod: TimeInterval

    init(secretGenerator: @escaping () -> String = BridgeSecureTokenGenerator.generateToken,
         nowProvider: @escaping () -> Date = Date.init,
         lifetime: TimeInterval = 5 * 60,
         cleanupGracePeriod: TimeInterval = 30) {
        self.secretGenerator = secretGenerator
        self.nowProvider = nowProvider
        self.lifetime = lifetime
        self.cleanupGracePeriod = cleanupGracePeriod
    }

    func createPayload(hostIdentity: BridgeHostIdentity,
                       lanEndpoints: [BridgePairEndpoint],
                       tailscaleEndpoint: BridgePairEndpoint? = nil,
                       tunnelEndpoint: BridgePairEndpoint? = nil,
                       resolverEndpoint: URL? = nil) throws -> BridgePairPayload {
        pruneExpired()
        let issuedAt = nowProvider()
        let expiresAt = issuedAt.addingTimeInterval(lifetime)
        let secret = secretGenerator()
        sessionsBySecret[secret] = Session(hostID: hostIdentity.hostID,
                                           secret: secret,
                                           expiresAt: expiresAt)
        return BridgePairPayload(type: "tidey_remote_pair",
                                 version: 1,
                                 hostID: hostIdentity.hostID,
                                 displayName: hostIdentity.displayName,
                                 lanEndpoints: lanEndpoints,
                                 tailscaleEndpoint: tailscaleEndpoint,
                                 tunnelEndpoint: tunnelEndpoint,
                                 resolverEndpoint: resolverEndpoint,
                                 pairSecret: secret,
                                 issuedAt: issuedAt,
                                 expiresAt: expiresAt)
    }

    func validate(pairSecret: String, hostID: String) throws {
        pruneExpired()
        guard let session = sessionsBySecret[pairSecret],
              session.hostID == hostID,
              session.expiresAt > nowProvider() else {
            throw BridgeInternalError.unauthorized
        }
    }

    func activeSessionCount() -> Int {
        pruneExpired()
        return sessionsBySecret.count
    }

    private func pruneExpired() {
        let now = nowProvider()
        sessionsBySecret = sessionsBySecret.filter { _, session in
            session.expiresAt.addingTimeInterval(cleanupGracePeriod) > now
        }
    }
}

struct BridgePairedDevice: Codable, Equatable, Sendable {
    let deviceID: String
    let deviceName: String
    let pairedAt: Date
    let lastConnectedAt: Date?

    enum CodingKeys: String, CodingKey {
        case deviceID = "device_id"
        case deviceName = "device_name"
        case pairedAt = "paired_at"
        case lastConnectedAt = "last_connected_at"
    }
}

final class BridgeDeviceCredentialStore {
    private struct FileRecord: Codable {
        var devices: [DeviceRecord]
    }

    private struct DeviceRecord: Codable {
        let deviceID: String
        let deviceName: String
        let tokenHash: String
        let createdAt: Date
        var lastConnectedAt: Date?

        enum CodingKeys: String, CodingKey {
            case deviceID = "device_id"
            case deviceName = "device_name"
            case tokenHash = "token_hash"
            case createdAt = "created_at"
            case lastConnectedAt = "last_connected_at"
        }
    }

    private let paths: BridgePaths
    private let fileManager: FileManager
    private let tokenGenerator: () -> String
    private let nowProvider: () -> Date

    init(paths: BridgePaths = BridgePaths(),
         fileManager: FileManager = .default,
         tokenGenerator: @escaping () -> String = BridgeSecureTokenGenerator.generateToken,
         nowProvider: @escaping () -> Date = Date.init) {
        self.paths = paths
        self.fileManager = fileManager
        self.tokenGenerator = tokenGenerator
        self.nowProvider = nowProvider
    }

    func issueCredential(deviceID: String, deviceName: String) throws -> BridgeIssuedDeviceCredential {
        let token = tokenGenerator()
        var record = try loadRecord()
        let deviceRecord = DeviceRecord(deviceID: deviceID,
                                        deviceName: deviceName,
                                        tokenHash: Self.hash(token),
                                        createdAt: nowProvider(),
                                        lastConnectedAt: nil)
        if let index = record.devices.firstIndex(where: { $0.deviceID == deviceID }) {
            record.devices[index] = deviceRecord
        } else {
            record.devices.append(deviceRecord)
        }
        try save(record)
        return BridgeIssuedDeviceCredential(deviceID: deviceID, token: token)
    }

    func isValidCredential(_ token: String) throws -> Bool {
        let tokenHash = Self.hash(token)
        var record = try loadRecord()
        guard let index = record.devices.firstIndex(where: { $0.tokenHash == tokenHash }) else {
            return false
        }
        record.devices[index].lastConnectedAt = nowProvider()
        try save(record)
        return true
    }

    func listDevices() throws -> [BridgePairedDevice] {
        try loadRecord().devices.map { device in
            BridgePairedDevice(deviceID: device.deviceID,
                               deviceName: device.deviceName,
                               pairedAt: device.createdAt,
                               lastConnectedAt: device.lastConnectedAt)
        }
    }

    @discardableResult
    func revokeDevice(deviceID: String) throws -> Bool {
        var record = try loadRecord()
        let originalCount = record.devices.count
        record.devices.removeAll { $0.deviceID == deviceID }
        guard record.devices.count != originalCount else {
            return false
        }
        try save(record)
        return true
    }

    private func loadRecord() throws -> FileRecord {
        guard fileManager.fileExists(atPath: paths.deviceCredentialsFileURL.path) else {
            return FileRecord(devices: [])
        }
        let data = try Data(contentsOf: paths.deviceCredentialsFileURL)
        return try JSONDecoder().decode(FileRecord.self, from: data)
    }

    private func save(_ record: FileRecord) throws {
        try fileManager.createDirectory(at: paths.supportDirectory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(record)
        try data.write(to: paths.deviceCredentialsFileURL, options: .atomic)
    }

    private static func hash(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

final class BridgePairingController {
    private let hostIdentityStore: BridgeHostIdentityStore
    private let pairSessionStore: BridgePairSessionStore
    private let deviceCredentialStore: BridgeDeviceCredentialStore

    init(hostIdentityStore: BridgeHostIdentityStore,
         pairSessionStore: BridgePairSessionStore,
         deviceCredentialStore: BridgeDeviceCredentialStore) {
        self.hostIdentityStore = hostIdentityStore
        self.pairSessionStore = pairSessionStore
        self.deviceCredentialStore = deviceCredentialStore
    }

    func createPairPayload(lanEndpoints: [BridgePairEndpoint],
                           tailscaleEndpoint: BridgePairEndpoint? = nil,
                           tunnelEndpoint: BridgePairEndpoint? = nil,
                           resolverEndpoint: URL? = nil) throws -> BridgePairPayload {
        let identity = try hostIdentityStore.loadOrCreateIdentity()
        return try pairSessionStore.createPayload(hostIdentity: identity,
                                                  lanEndpoints: lanEndpoints,
                                                  tailscaleEndpoint: tailscaleEndpoint,
                                                  tunnelEndpoint: tunnelEndpoint,
                                                  resolverEndpoint: resolverEndpoint)
    }

    func exchange(_ request: BridgePairExchangeRequest) throws -> BridgePairExchangeResult {
        guard request.action == "pair.exchange" else {
            throw BridgeInternalError.invalidRequest("pair.exchange requires action=pair.exchange")
        }
        let identity = try hostIdentityStore.loadOrCreateIdentity()
        guard request.hostID == identity.hostID else {
            throw BridgeInternalError.unauthorized
        }
        try pairSessionStore.validate(pairSecret: request.pairSecret,
                                      hostID: request.hostID)
        let credential = try deviceCredentialStore.issueCredential(deviceID: request.deviceID,
                                                                   deviceName: request.deviceName)
        return BridgePairExchangeResult(hostID: identity.hostID,
                                        displayName: identity.displayName,
                                        deviceCredential: credential.token,
                                        credentialType: "bearer")
    }

    func listDevices() throws -> [BridgePairedDevice] {
        try deviceCredentialStore.listDevices()
    }

    @discardableResult
    func revokeDevice(deviceID: String) throws -> Bool {
        try deviceCredentialStore.revokeDevice(deviceID: deviceID)
    }
}

final class BridgeAuthenticator {
    private let legacyPairToken: String
    private let deviceCredentialStore: BridgeDeviceCredentialStore

    init(legacyPairToken: String,
         deviceCredentialStore: BridgeDeviceCredentialStore) {
        self.legacyPairToken = legacyPairToken
        self.deviceCredentialStore = deviceCredentialStore
    }

    func isAuthorized(authorizationHeader: String?) -> Bool {
        guard let token = bearerToken(from: authorizationHeader) else {
            return false
        }
        if token == legacyPairToken {
            return true
        }
        return (try? deviceCredentialStore.isValidCredential(token)) == true
    }

    func isLegacyTokenAuthorized(authorizationHeader: String?) -> Bool {
        bearerToken(from: authorizationHeader) == legacyPairToken
    }

    private func bearerToken(from authorizationHeader: String?) -> String? {
        guard let authorizationHeader,
              authorizationHeader.hasPrefix("Bearer ") else {
            return nil
        }
        return String(authorizationHeader.dropFirst("Bearer ".count))
    }
}

enum BridgeSecureTokenGenerator {
    static func generateToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status == errSecSuccess {
            return Data(bytes).base64EncodedString()
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "=", with: "")
        }
        return UUID().uuidString + UUID().uuidString
    }
}
