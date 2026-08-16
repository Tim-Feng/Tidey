import Darwin
import Foundation
import NIOCore
import Security

struct BridgeMediaLeaseRegistryLimits: Equatable {
    let maximumPerDevice: Int
    let maximumGlobal: Int
    let idleTTL: TimeInterval
    let absoluteTTL: TimeInterval

    static let production = BridgeMediaLeaseRegistryLimits(maximumPerDevice: 2,
                                                           maximumGlobal: 8,
                                                           idleTTL: 5 * 60,
                                                           absoluteTTL: 60 * 60)
}

enum BridgeMediaLeaseRegistryError: Error, Equatable {
    case capacityExceeded
    case secureTokenUnavailable
    case tokenCollision
}

struct BridgeMediaLeaseGrant: Equatable {
    let opaqueToken: String
    let leasePath: String
    let prepareID: String
    let mime: String
    let size: UInt64
    let revisionToken: String
    let expiresAt: Date
}

struct BridgeMediaLeaseReadAuthority {
    /// A response-specific duplicate. Ownership passes to the HTTP response
    /// writer, which closes it after the outbound write completes or fails.
    let fileHandle: NIOFileHandle
    let prepareID: String
    let mime: String
    let size: UInt64
    let revisionToken: String
}

final class BridgeMediaLeaseRegistry {
    typealias TokenGenerator = () throws -> Data

    private struct Entry {
        let openedFile: BridgeSafeOpenedFile
        let deviceID: String
        let prepareID: String
        let mime: String
        let createdAt: Date
        var lastAccessAt: Date
    }

    private let limits: BridgeMediaLeaseRegistryLimits
    private let nowProvider: () -> Date
    private let tokenGenerator: TokenGenerator
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    init(limits: BridgeMediaLeaseRegistryLimits = .production,
         nowProvider: @escaping () -> Date = Date.init,
         tokenGenerator: @escaping TokenGenerator = BridgeMediaLeaseTokenGenerator.generate) {
        precondition(limits.maximumPerDevice > 0)
        precondition(limits.maximumGlobal > 0)
        precondition(limits.idleTTL > 0)
        precondition(limits.absoluteTTL > 0)
        self.limits = limits
        self.nowProvider = nowProvider
        self.tokenGenerator = tokenGenerator
    }

    /// On success the registry takes ownership of `openedFile`. On failure the
    /// caller retains ownership and must close it.
    func register(openedFile: BridgeSafeOpenedFile,
                  deviceID: String,
                  prepareID: String,
                  mime: String) throws -> BridgeMediaLeaseGrant {
        let now = nowProvider()
        lock.lock()
        defer { lock.unlock() }
        reapExpiredLocked(now: now)

        guard entries.count < limits.maximumGlobal,
              entries.values.lazy.filter({ $0.deviceID == deviceID }).count < limits.maximumPerDevice else {
            throw BridgeMediaLeaseRegistryError.capacityExceeded
        }

        var opaqueToken: String?
        for _ in 0..<8 {
            let tokenBytes = try tokenGenerator()
            guard tokenBytes.count >= 16 else {
                throw BridgeMediaLeaseRegistryError.secureTokenUnavailable
            }
            let candidate = Self.base64URL(tokenBytes)
            if entries[candidate] == nil {
                opaqueToken = candidate
                break
            }
        }
        guard let opaqueToken else {
            throw BridgeMediaLeaseRegistryError.tokenCollision
        }

        entries[opaqueToken] = Entry(openedFile: openedFile,
                                     deviceID: deviceID,
                                     prepareID: prepareID,
                                     mime: mime,
                                     createdAt: now,
                                     lastAccessAt: now)
        return BridgeMediaLeaseGrant(opaqueToken: opaqueToken,
                                     leasePath: "/media/\(opaqueToken)",
                                     prepareID: prepareID,
                                     mime: mime,
                                     size: UInt64(openedFile.size),
                                     revisionToken: openedFile.revisionToken,
                                     expiresAt: now.addingTimeInterval(limits.absoluteTTL))
    }

    func checkout(opaqueToken: String) -> BridgeMediaLeaseReadAuthority? {
        let now = nowProvider()
        lock.lock()
        defer { lock.unlock() }
        reapExpiredLocked(now: now)
        guard var entry = entries[opaqueToken] else {
            return nil
        }

        let sourceDescriptor = entry.openedFile.fileHandle.fileDescriptor
        let responseDescriptor = fcntl(sourceDescriptor, F_DUPFD_CLOEXEC, 0)
        guard responseDescriptor >= 0 else {
            removeLocked(opaqueToken)
            return nil
        }

        var status = stat()
        guard fstat(responseDescriptor, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG,
              Self.revisionToken(for: status) == entry.openedFile.revisionToken else {
            Darwin.close(responseDescriptor)
            removeLocked(opaqueToken)
            return nil
        }

        entry.lastAccessAt = now
        entries[opaqueToken] = entry
        return BridgeMediaLeaseReadAuthority(
            fileHandle: NIOFileHandle(_deprecatedTakingOwnershipOfDescriptor: responseDescriptor),
            prepareID: entry.prepareID,
            mime: entry.mime,
            size: UInt64(entry.openedFile.size),
            revisionToken: entry.openedFile.revisionToken
        )
    }

    @discardableResult
    func close(prepareID: String, deviceID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let tokens = entries.compactMap { token, entry in
            entry.prepareID == prepareID && entry.deviceID == deviceID ? token : nil
        }
        for token in tokens {
            removeLocked(token)
        }
        return !tokens.isEmpty
    }

    @discardableResult
    func revoke(deviceID: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        let tokens = entries.compactMap { token, entry in
            entry.deviceID == deviceID ? token : nil
        }
        for token in tokens {
            removeLocked(token)
        }
        return tokens.count
    }

    @discardableResult
    func reapExpired() -> Int {
        let now = nowProvider()
        lock.lock()
        defer { lock.unlock() }
        return reapExpiredLocked(now: now)
    }

    deinit {
        lock.lock()
        let retained = entries.values.map(\.openedFile)
        entries.removeAll()
        lock.unlock()
        retained.forEach { $0.close() }
    }

    private func reapExpiredLocked(now: Date) -> Int {
        let tokens = entries.compactMap { token, entry in
            let idleAge = now.timeIntervalSince(entry.lastAccessAt)
            let absoluteAge = now.timeIntervalSince(entry.createdAt)
            return idleAge >= limits.idleTTL || absoluteAge >= limits.absoluteTTL ? token : nil
        }
        for token in tokens {
            removeLocked(token)
        }
        return tokens.count
    }

    private func removeLocked(_ opaqueToken: String) {
        entries.removeValue(forKey: opaqueToken)?.openedFile.close()
    }

    private static func revisionToken(for status: stat) -> String {
        [
            String(Int64(status.st_dev)),
            String(UInt64(status.st_ino)),
            String(Int64(status.st_ctimespec.tv_sec)),
            String(Int64(status.st_ctimespec.tv_nsec)),
            String(Int64(status.st_mtimespec.tv_sec)),
            String(Int64(status.st_mtimespec.tv_nsec)),
            String(Int64(status.st_size)),
        ].joined(separator: ":")
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
    }
}

enum BridgeMediaLeaseTokenGenerator {
    static func generate() throws -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw BridgeMediaLeaseRegistryError.secureTokenUnavailable
        }
        return Data(bytes)
    }
}
