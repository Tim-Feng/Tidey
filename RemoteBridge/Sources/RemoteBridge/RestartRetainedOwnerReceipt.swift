import CryptoKit
import Foundation

/// An explicit operator input for one restart preparation, never an automatically
/// discovered authority store. The digest identifies the reviewed bytes; it is not
/// a signature or a substitute for owner authorization.
struct RestartRetainedOwnerReceipt {
    struct Identity: Codable {
        let registrySessionId: String
        let durableResumeId: String
        let pid: Int32
        let birthNanoseconds: UInt64
    }
    struct Retained: Codable {
        let identity: Identity
        let resolvedPanelId: String
        let retainHistory: Bool
        let autoResume: Bool
    }
    struct Document: Codable {
        let schema: String
        let ownerEvidencePath: String
        let ownerEvidenceSha256: String
        let successor: Identity
        let retained: [Retained]
    }
    let document: Document
    let sha256: String
    let sourcePath: String

    enum Invalid: Error { case receipt }
    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    private static func boundedRead(_ path: String, limit: Int) throws -> Data {
        guard path.hasPrefix("/"),
              try FileManager.default.attributesOfItem(atPath: path)[.type] as? FileAttributeType == .typeRegular else {
            throw Invalid.receipt
        }
        let file = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? file.close() }
        let bytes = try file.read(upToCount: limit + 1) ?? Data()
        guard bytes.count <= limit else { throw Invalid.receipt }
        return bytes
    }
    static func load(path: String) throws -> Self {
        let bytes = try boundedRead(path, limit: 65_536)
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        let document = try decoder.decode(Document.self, from: bytes)
        let all = [document.successor] + document.retained.map(\.identity)
        guard document.schema == "tidey.retained-rollback-owner/1",
              !document.retained.isEmpty, document.retained.count <= 32,
              all.allSatisfy({ UUID(uuidString: $0.registrySessionId) != nil &&
                  UUID(uuidString: $0.durableResumeId) != nil && $0.pid > 0 && $0.birthNanoseconds > 0 }),
              Set(all.map(\.registrySessionId)).count == all.count,
              Set(all.map(\.durableResumeId)).count == all.count,
              Set(all.map(\.pid)).count == all.count,
              document.retained.allSatisfy({ $0.retainHistory && !$0.autoResume && validRollbackPanel($0.resolvedPanelId) }),
              Set(document.retained.map(\.resolvedPanelId)).count == document.retained.count else { throw Invalid.receipt }
        let value = Self(document: document, sha256: digest(bytes), sourcePath: path)
        guard value.evidenceIsUnchanged() else { throw Invalid.receipt }
        return value
    }
    static func validRollbackPanel(_ panel: String) -> Bool {
        let fields = panel.components(separatedBy: ":")
        return fields.count == 5 && fields[0] == "native-session" &&
            UUID(uuidString: fields[1]) != nil && UUID(uuidString: fields[2]) != nil &&
            fields[3] == "handoff-rollback" && fields[4].count == 32 && fields[4].allSatisfy(\.isHexDigit)
    }
    func evidenceIsUnchanged() -> Bool {
        guard let bytes = try? Self.boundedRead(document.ownerEvidencePath, limit: 1_048_576),
              let receipt = try? Self.boundedRead(sourcePath, limit: 65_536) else { return false }
        return Self.digest(bytes) == document.ownerEvidenceSha256 && Self.digest(receipt) == sha256
    }
    func matches(_ identity: Identity, record: AgentSessionRegistryRecord) -> Bool {
        record.vendor == "codex" && record.sessionID == identity.registrySessionId &&
            record.threadID == identity.durableResumeId && record.pid == identity.pid &&
            ClaudeCurrentHookEvidence.processBirthNanoseconds(record.pid) == identity.birthNanoseconds
    }

    func matchedSessionIDs(in records: [RuntimeResumeNonRestoringRecord]) -> [String] {
        let matched = records.filter { $0.reason == "owner_confirmed_retained_rollback" }.map(\.sessionID)
        guard Set(matched) == Set(document.retained.map { $0.identity.registrySessionId }) else { return [] }
        return (matched + [document.successor.registrySessionId]).sorted()
    }
}
