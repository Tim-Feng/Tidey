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
            throw BridgeInternalError.invalidRequest("file access requires a panel with cwd.")
        }
        return cwd
    }
}

struct BridgeFileActionHandler {
    private let rootResolver: PanelFileRootResolving
    private let fileManager: FileManager
    private let policy: BridgeDocumentFilePolicy

    init(rootResolver: PanelFileRootResolving,
         fileManager: FileManager = .default,
         policy: BridgeDocumentFilePolicy = .poc) {
        self.rootResolver = rootResolver
        self.fileManager = fileManager
        self.policy = policy
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
                                       panelID: params.panelID)
        let metadata = try readMetadata(at: resolved.targetURL)
        let data = try Data(contentsOf: resolved.targetURL)
        guard let content = String(data: data, encoding: .utf8) else {
            throw BridgeInternalError.invalidRequest("file_read only supports UTF-8 text content")
        }

        let result: [String: JSONValue] = [
            "normalized_path": .string(resolved.targetURL.path),
            "display_name": .string(resolved.targetURL.lastPathComponent),
            "content": .string(content),
            "encoding": .string("utf-8"),
            "size": .number(Double(metadata.size)),
            "mtime": .number(metadata.mtime.timeIntervalSince1970),
            "revision_token": .string(metadata.revisionToken),
            "read_only": .bool(!fileManager.isWritableFile(atPath: resolved.targetURL.path)),
            "reason": fileManager.isWritableFile(atPath: resolved.targetURL.path) ? .null : .string("permission_denied"),
        ]
        return BridgeResponse(id: request.id, ok: true, result: result, error: nil)
    }

    private func writeFile(_ request: BridgeRequest) throws -> BridgeResponse {
        let params = try BridgeFileWriteRequest(params: request.params)
        let resolved = try resolveFile(path: params.path,
                                       workspaceID: params.workspaceID,
                                       panelID: params.panelID)
        guard fileManager.fileExists(atPath: resolved.targetURL.path) else {
            throw BridgeInternalError.notFound("file_write target does not exist")
        }
        guard fileManager.isWritableFile(atPath: resolved.targetURL.path) else {
            throw BridgeInternalError.forbidden("file_write target is not writable")
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

    private func resolveFile(path: String, workspaceID: String, panelID: String) throws -> ResolvedFileTarget {
        let rawRootPath = try rootResolver.rootPath(workspaceID: workspaceID, panelID: panelID)
        let rootURL = URL(fileURLWithPath: rawRootPath, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: rootURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw BridgeInternalError.invalidRequest("file access root is unavailable")
        }

        let candidateURL: URL
        if NSString(string: path).isAbsolutePath {
            candidateURL = URL(fileURLWithPath: path, isDirectory: false)
        } else {
            candidateURL = rootURL.appendingPathComponent(path, isDirectory: false)
        }
        let normalizedURL = candidateURL.standardizedFileURL.resolvingSymlinksInPath()
        guard isDescendant(normalizedURL, of: rootURL) else {
            throw BridgeInternalError.forbidden("file path must stay within the panel root")
        }
        guard policy.allows(normalizedURL) else {
            throw BridgeInternalError.forbidden("file path is not in the document allowlist")
        }
        return ResolvedFileTarget(targetURL: normalizedURL)
    }

    private func readMetadata(at fileURL: URL) throws -> FileRevisionMetadata {
        let attributes = try fileManager.attributesOfItem(atPath: fileURL.path)
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
}

private struct ResolvedFileTarget {
    let targetURL: URL
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
}
