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
/// Seconds and nanoseconds stay separate — combining them into one Int64 of
/// nanoseconds can overflow for mtimes near the APFS range limit.
struct BridgeSafeOpenedFile {
    let fileHandle: FileHandle
    let deviceID: Int64
    let inode: UInt64
    let size: Int64
    let changeTimeSeconds: Int64
    let changeTimeNanoseconds: Int64
    let modificationTimeSeconds: Int64
    let modificationTimeNanoseconds: Int64

    var revisionToken: String {
        [
            String(deviceID),
            String(inode),
            String(changeTimeSeconds),
            String(changeTimeNanoseconds),
            String(modificationTimeSeconds),
            String(modificationTimeNanoseconds),
            String(size),
        ].joined(separator: ":")
    }

    func close() {
        try? fileHandle.close()
    }
}

/// Opens the already-resolved target refusing symlinks in EVERY path
/// component (`O_NOFOLLOW_ANY`; the kernel rejects combining it with
/// `O_NOFOLLOW`), without blocking on special files (`O_NONBLOCK`), and
/// verifies via `fstat` that the opened object is a regular file. The
/// descriptor is the only read source afterwards — the path string is never
/// re-opened.
enum BridgeSafeFileOpener {
    static func openRegularFile(at fileURL: URL,
                                notFoundMessage: String,
                                outsideScopeMessage: String) throws -> BridgeSafeOpenedFile {
        let path = privatePrefixNormalized(fileURL.path)
        let descriptor = path.withCString { open($0, O_RDONLY | O_NOFOLLOW_ANY | O_NONBLOCK | O_CLOEXEC) }
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

        return BridgeSafeOpenedFile(fileHandle: FileHandle(fileDescriptor: descriptor, closeOnDealloc: true),
                                    deviceID: Int64(status.st_dev),
                                    inode: UInt64(status.st_ino),
                                    size: Int64(status.st_size),
                                    changeTimeSeconds: Int64(status.st_ctimespec.tv_sec),
                                    changeTimeNanoseconds: Int64(status.st_ctimespec.tv_nsec),
                                    modificationTimeSeconds: Int64(status.st_mtimespec.tv_sec),
                                    modificationTimeNanoseconds: Int64(status.st_mtimespec.tv_nsec))
    }

    /// Foundation's `resolvingSymlinksInPath` strips the `/private` prefix,
    /// handing back paths whose first component is the `/var`, `/tmp`, or
    /// `/etc` symlink — which `O_NOFOLLOW_ANY` would then refuse. Restore the
    /// prefix textually; no symlink is ever followed to do so.
    private static func privatePrefixNormalized(_ path: String) -> String {
        for prefix in ["/var/", "/tmp/", "/etc/"] where path.hasPrefix(prefix) {
            return "/private" + path
        }
        return path
    }

    /// Reads at most `maximumBytes + 1` bytes from the descriptor. Returning
    /// one byte over the cap lets the caller reject a file that grew after
    /// `fstat` without ever buffering an unbounded amount.
    static func readBounded(from fileHandle: FileHandle, maximumBytes: Int) throws -> Data {
        var data = Data()
        while data.count <= maximumBytes {
            let remaining = maximumBytes + 1 - data.count
            guard let chunk = try fileHandle.read(upToCount: min(1_048_576, remaining)),
                  !chunk.isEmpty else {
                break
            }
            data.append(chunk)
        }
        return data
    }
}
