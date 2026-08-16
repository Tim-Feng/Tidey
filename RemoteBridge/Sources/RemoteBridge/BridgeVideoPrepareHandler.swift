import AVFoundation
import Foundation
import UniformTypeIdentifiers

struct BridgeVideoProbeMetadata: Equatable {
    let isReadable: Bool
    let isPlayable: Bool
    let hasVideo: Bool
    let hasAudio: Bool
    let enabledTracksAreSelfContained: Bool
    let durationMS: Double
    let mime: String
}

struct BridgeVideoProbeResult: Equatable {
    let normalizedPath: String
    let displayName: String
    let route: BridgeVideoPreviewRoute
    let mime: String
    let size: UInt64
    let durationMS: Double
    let hasAudio: Bool
    let revisionToken: String
}

struct BridgeVideoPreparedSource {
    let result: BridgeVideoProbeResult
    /// Present only for `.direct`. Ownership passes to the lease registry or
    /// must be closed by the caller if lease creation fails.
    let openedFile: BridgeSafeOpenedFile?
}

struct BridgeVideoFilePolicy: BridgeLocalFileContentPolicy {
    static let allowedExtensions: Set<String> = [
        "3g2", "3gp", "asf", "avi", "f4v", "flv", "m2ts", "m4v", "mkv", "mov",
        "mp4", "mpeg", "mpg", "mts", "ogv", "qt", "ts", "vob", "webm", "wmv",
    ]

    let notInAllowlistMessage = "這個檔案類型目前不支援影片預覽。"
    let outsideRootMessage = "這個檔案不在允許預覽的範圍內。"

    func allows(_ fileURL: URL) -> Bool {
        Self.allowedExtensions.contains(fileURL.pathExtension.lowercased())
    }

    func allowsReadOnlyHomeScope(_ fileURL: URL, homeDirectoryURL: URL) -> Bool {
        guard allows(fileURL), isDescendant(fileURL, of: homeDirectoryURL) else {
            return false
        }
        let rootComponents = homeDirectoryURL.standardizedFileURL.pathComponents
        let relativeComponents = fileURL.standardizedFileURL.pathComponents.dropFirst(rootComponents.count)
        guard !relativeComponents.contains(where: { $0.hasPrefix(".") }),
              relativeComponents.first?.caseInsensitiveCompare("Library") != .orderedSame else {
            return false
        }
        return true
    }

    private func isDescendant(_ fileURL: URL, of rootURL: URL) -> Bool {
        if fileURL.path == rootURL.path {
            return true
        }
        let prefix = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
        return fileURL.path.hasPrefix(prefix)
    }
}

struct BridgeVideoProbeLimits {
    let maximumSourceBytes: Int64

    static let production = BridgeVideoProbeLimits(maximumSourceBytes: 8 * 1024 * 1024 * 1024)
}

struct BridgeVideoPrepareHandler {
    typealias MetadataProbe = (URL) async throws -> BridgeVideoProbeMetadata

    private let targetResolver: BridgePanelFileTargetResolver
    private let policy = BridgeVideoFilePolicy()
    private let limits: BridgeVideoProbeLimits
    private let metadataProbe: MetadataProbe

    init(rootResolver: PanelFileRootResolving,
         fileManager: FileManager = .default,
         homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser,
         limits: BridgeVideoProbeLimits = .production,
         metadataProbe: @escaping MetadataProbe = BridgeVideoPrepareHandler.probeMetadata) {
        self.targetResolver = BridgePanelFileTargetResolver(rootResolver: rootResolver,
                                                            fileManager: fileManager,
                                                            homeDirectoryURL: homeDirectoryURL)
        self.limits = limits
        self.metadataProbe = metadataProbe
    }

    func probe(path: String, workspaceID: String, panelID: String) async throws -> BridgeVideoProbeResult {
        let prepared = try await prepare(path: path, workspaceID: workspaceID, panelID: panelID)
        prepared.openedFile?.close()
        return prepared.result
    }

    func prepare(path: String,
                 workspaceID: String,
                 panelID: String) async throws -> BridgeVideoPreparedSource {
        let resolved = try targetResolver.resolve(path: path,
                                                  workspaceID: workspaceID,
                                                  panelID: panelID,
                                                  policy: policy,
                                                  allowsReadOnlyHomeScope: true)
        let opened = try BridgeSafeFileOpener.openRegularFile(
            at: resolved.targetURL,
            notFoundMessage: "video_prepare target does not exist",
            outsideScopeMessage: policy.outsideRootMessage
        )
        defer { opened.close() }

        guard opened.size >= 0, opened.size <= limits.maximumSourceBytes else {
            throw BridgeInternalError.fileTooLarge("影片檔案太大，無法預覽。")
        }

        let metadata = try await metadataProbe(resolved.targetURL)

        let verified = try BridgeSafeFileOpener.openRegularFile(
            at: resolved.targetURL,
            notFoundMessage: "video_prepare target changed during inspection",
            outsideScopeMessage: policy.outsideRootMessage
        )
        guard verified.revisionToken == opened.revisionToken else {
            verified.close()
            throw BridgeInternalError.forbidden("影片檔案在檢查期間已變更，請重試。")
        }

        let route: BridgeVideoPreviewRoute
        if !metadata.isReadable || !metadata.hasVideo || !metadata.enabledTracksAreSelfContained {
            route = .unsupported
        } else if metadata.isPlayable {
            route = .direct
        } else {
            route = .transcode
        }

        let result = BridgeVideoProbeResult(normalizedPath: resolved.targetURL.path,
                                            displayName: resolved.targetURL.lastPathComponent,
                                            route: route,
                                            mime: metadata.mime,
                                            size: UInt64(opened.size),
                                            durationMS: metadata.durationMS,
                                            hasAudio: metadata.hasAudio,
                                            revisionToken: opened.revisionToken)
        if route == .direct {
            return BridgeVideoPreparedSource(result: result, openedFile: verified)
        }
        verified.close()
        return BridgeVideoPreparedSource(result: result, openedFile: nil)
    }

    private static func probeMetadata(at fileURL: URL) async throws -> BridgeVideoProbeMetadata {
        let asset = AVURLAsset(url: fileURL)
        let tracks = try await asset.load(.tracks)
        var enabledTracks: [AVAssetTrack] = []
        for track in tracks where try await track.load(.isEnabled) {
            enabledTracks.append(track)
        }
        let durationSeconds = CMTimeGetSeconds(try await asset.load(.duration))
        let durationMS = durationSeconds.isFinite && durationSeconds >= 0 ? durationSeconds * 1_000 : 0

        var enabledTracksAreSelfContained = true
        for track in enabledTracks where !(try await track.load(.isSelfContained)) {
            enabledTracksAreSelfContained = false
            break
        }

        return BridgeVideoProbeMetadata(
            isReadable: try await asset.load(.isReadable),
            isPlayable: try await asset.load(.isPlayable),
            hasVideo: enabledTracks.contains(where: { $0.mediaType == .video }),
            hasAudio: enabledTracks.contains(where: { $0.mediaType == .audio }),
            enabledTracksAreSelfContained: enabledTracksAreSelfContained,
            durationMS: durationMS,
            mime: mimeType(for: fileURL)
        )
    }

    private static func mimeType(for fileURL: URL) -> String {
        if let mime = UTType(filenameExtension: fileURL.pathExtension)?.preferredMIMEType {
            return mime
        }
        switch fileURL.pathExtension.lowercased() {
        case "mkv": return "video/x-matroska"
        case "webm": return "video/webm"
        case "ogv": return "video/ogg"
        case "mov", "qt": return "video/quicktime"
        case "ts", "mts", "m2ts": return "video/mp2t"
        default: return "application/octet-stream"
        }
    }
}
