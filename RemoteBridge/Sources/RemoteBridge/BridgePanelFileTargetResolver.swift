import Foundation

/// Content-type policy consulted while resolving a panel-scoped local file
/// target. Document and image actions each supply their own policy so the
/// write-side document allowlist can never be widened by a read-only feature.
protocol BridgeLocalFileContentPolicy {
    func allows(_ fileURL: URL) -> Bool
    func allowsReadOnlyHomeScope(_ fileURL: URL, homeDirectoryURL: URL) -> Bool
    var notInAllowlistMessage: String { get }
    var outsideRootMessage: String { get }
}

struct BridgeResolvedFileTarget {
    let targetURL: URL
    let isReadOnlyOutsideRoot: Bool
}

/// Shared canonical path resolution for panel-scoped file actions: tilde
/// expansion, relative-path anchoring on the panel root, standardization,
/// symlink resolution, descendant check, and the read-only home scope.
struct BridgePanelFileTargetResolver {
    private let rootResolver: PanelFileRootResolving
    private let fileManager: FileManager
    private let homeDirectoryURL: URL

    init(rootResolver: PanelFileRootResolving,
         fileManager: FileManager = .default,
         homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.rootResolver = rootResolver
        self.fileManager = fileManager
        self.homeDirectoryURL = homeDirectoryURL
    }

    func resolve(path: String,
                 workspaceID: String,
                 panelID: String,
                 policy: BridgeLocalFileContentPolicy,
                 allowsReadOnlyHomeScope: Bool) throws -> BridgeResolvedFileTarget {
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
            throw BridgeInternalError.fileNotInAllowlist(policy.notInAllowlistMessage)
        }
        if isDescendant(normalizedURL, of: rootURL) {
            return BridgeResolvedFileTarget(targetURL: normalizedURL, isReadOnlyOutsideRoot: false)
        }
        guard allowsReadOnlyHomeScope,
              policy.allowsReadOnlyHomeScope(normalizedURL, homeDirectoryURL: normalizedHomeDirectoryURL()) else {
            throw BridgeInternalError.fileOutsideRoot(policy.outsideRootMessage)
        }
        return BridgeResolvedFileTarget(targetURL: normalizedURL, isReadOnlyOutsideRoot: true)
    }

    func expandTilde(in path: String) -> String {
        if path == "~" {
            return homeDirectoryURL.path
        }
        if path.hasPrefix("~/") {
            return homeDirectoryURL.appendingPathComponent(String(path.dropFirst(2))).path
        }
        return path
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
}

/// Metadata captured from `fstat` on an already-opened descriptor, so every
/// later read observes the same file object that passed the scope checks.
struct BridgeSafeOpenedFile {
    let fileHandle: FileHandle
    let size: Int64
    let modificationDate: Date
    let modificationTimeNanoseconds: Int64

    func close() {
        try? fileHandle.close()
    }
}

/// Opens the already-resolved target with `O_NOFOLLOW` and verifies it is a
/// regular file via `fstat`, eliminating the symlink-swap window between the
/// resolver's checks and the read.
enum BridgeSafeFileOpener {
    static func openRegularFile(at fileURL: URL,
                                notFoundMessage: String,
                                outsideScopeMessage: String) throws -> BridgeSafeOpenedFile {
        let descriptor = fileURL.path.withCString { open($0, O_RDONLY | O_NOFOLLOW) }
        guard descriptor >= 0 else {
            switch errno {
            case ELOOP:
                throw BridgeInternalError.fileOutsideRoot(outsideScopeMessage)
            case ENOENT, ENOTDIR:
                throw BridgeInternalError.notFound(notFoundMessage)
            default:
                throw BridgeInternalError.forbidden(notFoundMessage)
            }
        }

        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            Darwin.close(descriptor)
            throw BridgeInternalError.notFound(notFoundMessage)
        }
        guard (status.st_mode & S_IFMT) == S_IFREG else {
            Darwin.close(descriptor)
            throw BridgeInternalError.fileOutsideRoot(outsideScopeMessage)
        }

        let mtimeNanoseconds = Int64(status.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(status.st_mtimespec.tv_nsec)
        return BridgeSafeOpenedFile(fileHandle: FileHandle(fileDescriptor: descriptor, closeOnDealloc: true),
                                    size: Int64(status.st_size),
                                    modificationDate: Date(timeIntervalSince1970: TimeInterval(mtimeNanoseconds) / 1_000_000_000),
                                    modificationTimeNanoseconds: mtimeNanoseconds)
    }
}
