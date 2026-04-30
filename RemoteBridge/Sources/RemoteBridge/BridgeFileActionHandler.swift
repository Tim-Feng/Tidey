import CryptoKit
import Foundation

protocol PanelFileRootResolving {
    func rootPath(workspaceID: String, panelID: String) throws -> String
}

struct TideyPanelFileRootResolver: PanelFileRootResolving {
    private let socketSender: TideyRequestSending

    init(socketSender: TideyRequestSending) {
        self.socketSender = socketSender
    }

    func rootPath(workspaceID: String, panelID: String) throws -> String {
        // PoC 階段先用 panel cwd 當檔案邊界。之後若 Tidey 提供正式 workspace root，
        // 只要替換這個 resolver，不用改 file_read / file_write contract。
        let request = BridgeRequest(id: UUID().uuidString,
                                    action: "list_panels",
                                    params: ["workspace_id": .string(workspaceID)])
        let response = try socketSender.send(request)
        guard response.ok,
              let panels = response.result?["panels"]?.arrayValue else {
            throw BridgeInternalError.invalidResponse
        }
        guard let panel = panels.compactMap(\.objectValue).first(where: {
            $0["panel_id"]?.stringValue == panelID
        }) else {
            throw BridgeInternalError.notFound("No panel matched panel_id.")
        }
        guard let cwd = panel["cwd"]?.stringValue, !cwd.isEmpty else {
            throw BridgeInternalError.panelContextUnavailable("目前無法判斷這個 panel 的工作目錄。")
        }
        return cwd
    }
}

struct BridgeFileActionHandler {
    private static let warningSizeBytes: Int64 = 512 * 1024
    private static let maximumReadableSizeBytes: Int64 = 1024 * 1024

    private let rootResolver: PanelFileRootResolving
    private let fileManager: FileManager
    private let policy: BridgeDocumentFilePolicy
    private let homeDirectoryURL: URL

    init(rootResolver: PanelFileRootResolving,
         fileManager: FileManager = .default,
         policy: BridgeDocumentFilePolicy = .poc,
         homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.rootResolver = rootResolver
        self.fileManager = fileManager
        self.policy = policy
        self.homeDirectoryURL = homeDirectoryURL
    }

    func handle(_ request: BridgeRequest) throws -> BridgeResponse? {
        switch request.action {
        case "file_read":
            return try readFile(request)
        case "file_write":
            return try writeFile(request)
        default:
            return nil
        }
    }

    private func readFile(_ request: BridgeRequest) throws -> BridgeResponse {
        let params = try BridgeFileReadRequest(params: request.params)
        let resolved = try resolveFile(path: params.path,
                                       workspaceID: params.workspaceID,
                                       panelID: params.panelID,
                                       allowsReadOnlyHomeScope: true)
        guard fileManager.fileExists(atPath: resolved.targetURL.path) else {
            throw BridgeInternalError.notFound("file_read target does not exist")
        }
        let attributes = try fileManager.attributesOfItem(atPath: resolved.targetURL.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        if size > Self.maximumReadableSizeBytes {
            throw BridgeInternalError.fileTooLarge("檔案超過 1MB，這個版本的編輯器不支援開啟。")
        }
        if size > Self.warningSizeBytes, !params.allowLargeRead {
            throw BridgeInternalError.fileNeedsConfirmation("檔案超過 512KB，打開可能會較慢。")
        }

        let metadata = try readMetadata(at: resolved.targetURL, attributes: attributes)
        let data = try Data(contentsOf: resolved.targetURL)
        guard let content = String(data: data, encoding: .utf8) else {
            throw BridgeInternalError.fileEncodingUnsupported("這個檔案不是 UTF-8 文字格式，這個版本的編輯器無法開啟。")
        }

        let isWritable = fileManager.isWritableFile(atPath: resolved.targetURL.path)
        let readOnlyReason: JSONValue
        if resolved.isReadOnlyOutsideRoot {
            readOnlyReason = .string("outside_workspace")
        } else if !isWritable {
            readOnlyReason = .string("permission_denied")
        } else {
            readOnlyReason = .null
        }

        let result: [String: JSONValue] = [
            "normalized_path": .string(resolved.targetURL.path),
            "display_name": .string(resolved.targetURL.lastPathComponent),
            "content": .string(content),
            "encoding": .string("utf-8"),
            "size": .number(Double(metadata.size)),
            "mtime": .number(metadata.mtime.timeIntervalSince1970),
            "revision_token": .string(metadata.revisionToken),
            "read_only": .bool(resolved.isReadOnlyOutsideRoot || !isWritable),
            "reason": readOnlyReason,
        ]
        return BridgeResponse(id: request.id, ok: true, result: result, error: nil)
    }

    private func writeFile(_ request: BridgeRequest) throws -> BridgeResponse {
        let params = try BridgeFileWriteRequest(params: request.params)
        let resolved = try resolveFile(path: params.path,
                                       workspaceID: params.workspaceID,
                                       panelID: params.panelID,
                                       allowsReadOnlyHomeScope: false)
        guard fileManager.fileExists(atPath: resolved.targetURL.path) else {
            throw BridgeInternalError.notFound("file_write target does not exist")
        }
        guard fileManager.isWritableFile(atPath: resolved.targetURL.path) else {
            throw BridgeInternalError.fileNotWritable("Mac 端這個檔案沒有寫入權限。")
        }

        let currentMetadata = try readMetadata(at: resolved.targetURL)
        guard params.force || currentMetadata.revisionToken == params.expectedRevisionToken else {
            throw BridgeInternalError.conflict("file_write expected_revision_token does not match the current file version")
        }

        let data = Data(params.content.utf8)
        try data.write(to: resolved.targetURL, options: .atomic)
        let updatedMetadata = try readMetadata(at: resolved.targetURL)

        return BridgeResponse(id: request.id,
                              ok: true,
                              result: [
                                "normalized_path": .string(resolved.targetURL.path),
                                "mtime": .number(updatedMetadata.mtime.timeIntervalSince1970),
                                "revision_token": .string(updatedMetadata.revisionToken),
                                "did_write": .bool(true),
                              ],
                              error: nil)
    }

    private func resolveFile(path: String,
                             workspaceID: String,
                             panelID: String,
                             allowsReadOnlyHomeScope: Bool) throws -> ResolvedFileTarget {
        let rawRootPath = try rootResolver.rootPath(workspaceID: workspaceID, panelID: panelID)
        let rootURL = URL(fileURLWithPath: rawRootPath, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: rootURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw BridgeInternalError.panelContextUnavailable("目前無法取得這個 panel 的檔案根目錄。")
        }

        let candidateURL: URL
        let expandedPath = expandTilde(in: path)
        if NSString(string: expandedPath).isAbsolutePath {
            candidateURL = URL(fileURLWithPath: expandedPath, isDirectory: false)
        } else {
            candidateURL = rootURL.appendingPathComponent(expandedPath, isDirectory: false)
        }
        let normalizedURL = candidateURL.standardizedFileURL.resolvingSymlinksInPath()
        guard policy.allows(normalizedURL) else {
            throw BridgeInternalError.fileNotInAllowlist("這個檔案類型目前不支援在 iPhone 編輯。")
        }
        if isDescendant(normalizedURL, of: rootURL) {
            return ResolvedFileTarget(targetURL: normalizedURL, isReadOnlyOutsideRoot: false)
        }
        guard allowsReadOnlyHomeScope,
              policy.allowsReadOnlyHomeScope(normalizedURL, homeDirectoryURL: normalizedHomeDirectoryURL()) else {
            throw BridgeInternalError.fileOutsideRoot("這個檔案不在允許編輯的範圍內。")
        }
        return ResolvedFileTarget(targetURL: normalizedURL, isReadOnlyOutsideRoot: true)
    }

    private func readMetadata(at fileURL: URL, attributes: [FileAttributeKey: Any]? = nil) throws -> FileRevisionMetadata {
        let attributes = try attributes ?? fileManager.attributesOfItem(atPath: fileURL.path)
        let mtime = attributes[.modificationDate] as? Date ?? .distantPast
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let data = try Data(contentsOf: fileURL)
        let digest = SHA256.hash(data: data)
        let hash = digest.map { String(format: "%02x", $0) }.joined()
        return FileRevisionMetadata(mtime: mtime,
                                    size: size,
                                    revisionToken: "\(Int64(mtime.timeIntervalSince1970 * 1000)):\(size):\(hash)")
    }

    private func isDescendant(_ fileURL: URL, of rootURL: URL) -> Bool {
        if fileURL.path == rootURL.path {
            return true
        }
        let rootPrefix = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
        return fileURL.path.hasPrefix(rootPrefix)
    }

    private func normalizedHomeDirectoryURL() -> URL {
        homeDirectoryURL
            .standardizedFileURL
            .resolvingSymlinksInPath()
    }

    private func expandTilde(in path: String) -> String {
        if path == "~" {
            return homeDirectoryURL.path
        }
        if path.hasPrefix("~/") {
            return homeDirectoryURL.appendingPathComponent(String(path.dropFirst(2))).path
        }
        return path
    }
}

private struct ResolvedFileTarget {
    let targetURL: URL
    let isReadOnlyOutsideRoot: Bool
}

private struct FileRevisionMetadata {
    let mtime: Date
    let size: Int64
    let revisionToken: String
}

struct BridgeDocumentFilePolicy {
    let allowedExtensions: Set<String>
    let wellKnownFilenames: Set<String>

    static let poc = BridgeDocumentFilePolicy(
        allowedExtensions: ["md", "markdown", "mdx", "txt", "rst"],
        wellKnownFilenames: ["README", "LICENSE", "CHANGELOG", "TODO"]
    )

    func allows(_ fileURL: URL) -> Bool {
        let filename = fileURL.lastPathComponent
        let ext = fileURL.pathExtension.lowercased()
        if !ext.isEmpty {
            return allowedExtensions.contains(ext)
        }
        return wellKnownFilenames.contains(filename.uppercased())
    }

    func allowsReadOnlyHomeScope(_ fileURL: URL, homeDirectoryURL: URL) -> Bool {
        guard allows(fileURL),
              isDescendant(fileURL, of: homeDirectoryURL),
              !hasHiddenPathComponent(fileURL, relativeTo: homeDirectoryURL),
              !hasSensitiveHomePathComponent(fileURL, relativeTo: homeDirectoryURL) else {
            return false
        }
        return true
    }

    private func isDescendant(_ fileURL: URL, of rootURL: URL) -> Bool {
        if fileURL.path == rootURL.path {
            return true
        }
        let rootPrefix = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
        return fileURL.path.hasPrefix(rootPrefix)
    }

    private func hasHiddenPathComponent(_ fileURL: URL, relativeTo rootURL: URL) -> Bool {
        let rootComponents = rootURL.standardizedFileURL.pathComponents
        let fileComponents = fileURL.standardizedFileURL.pathComponents
        guard fileComponents.count > rootComponents.count else {
            return false
        }
        return fileComponents.dropFirst(rootComponents.count).contains { component in
            component.hasPrefix(".")
        }
    }

    private func hasSensitiveHomePathComponent(_ fileURL: URL, relativeTo rootURL: URL) -> Bool {
        let rootComponents = rootURL.standardizedFileURL.pathComponents
        let fileComponents = fileURL.standardizedFileURL.pathComponents
        guard fileComponents.count > rootComponents.count else {
            return false
        }
        let relativeComponents = Array(fileComponents.dropFirst(rootComponents.count))
        return relativeComponents.first == "Library"
    }
}
