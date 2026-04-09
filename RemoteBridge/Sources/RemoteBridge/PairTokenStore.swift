import Foundation
import Security

struct PairTokenRecord: Codable {
    let token: String
    let createdAt: Date
}

final class PairTokenStore {
    private let fileManager = FileManager.default
    private let paths: BridgePaths

    init() {
        paths = BridgePaths(fileManager: fileManager)
    }

    func loadOrCreateToken() throws -> String {
        if let existing = try loadToken() {
            return existing.token
        }
        try paths.ensureSupportDirectoriesExist(fileManager: fileManager)
        let record = PairTokenRecord(token: Self.generateToken(), createdAt: Date())
        let data = try JSONEncoder().encode(record)
        try data.write(to: paths.pairTokenFileURL, options: .atomic)
        return record.token
    }

    private func loadToken() throws -> PairTokenRecord? {
        guard fileManager.fileExists(atPath: paths.pairTokenFileURL.path) else {
            return nil
        }
        let data = try Data(contentsOf: paths.pairTokenFileURL)
        return try JSONDecoder().decode(PairTokenRecord.self, from: data)
    }

    private static func generateToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status == errSecSuccess {
            return Data(bytes).base64EncodedString()
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "+", with: "-")
        }
        return UUID().uuidString + UUID().uuidString
    }
}
