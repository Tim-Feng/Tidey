import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum BridgeImageReadDiagnostics {
    // Unlike file_read diagnostics, never log the full requested path or any
    // payload bytes — image targets are more sensitive; basename only.
    static func log(_ message: String) {
        BridgeLogger.server.info("[image_read] \(message, privacy: .public)")
        if let data = "[image_read] \(message)\n".data(using: .utf8) {
            FileHandle.standardError.write(data)
        }
    }
}

/// Hard limits for `image_read`. Production values are the protocol contract;
/// tests inject smaller values to exercise the caps without huge fixtures.
struct BridgeImageReadLimits {
    let maximumSourceBytes: Int64
    let maximumSourcePixels: Int64
    let minimumRequestedDimension: Int
    let maximumRequestedDimension: Int
    let defaultRequestedDimension: Int
    let maximumEncodedPreviewBytes: Int

    static let production = BridgeImageReadLimits(
        maximumSourceBytes: 100 * 1024 * 1024,
        maximumSourcePixels: 100_000_000,
        minimumRequestedDimension: 512,
        maximumRequestedDimension: 4096,
        defaultRequestedDimension: 3072,
        maximumEncodedPreviewBytes: 1024 * 1024
    )
}

/// Read-only preview policy. Deliberately separate from
/// `BridgeDocumentFilePolicy` so image extensions can never leak into the
/// document write allowlist.
struct BridgeImageFilePolicy: BridgeLocalFileContentPolicy {
    static let allowedExtensions: Set<String> = ["png", "jpg", "jpeg"]

    let uploadsDirectoryURL: URL
    let notInAllowlistMessage = "這個檔案類型目前不支援圖片預覽。"
    let outsideRootMessage = "這個檔案不在允許預覽的範圍內。"

    func allows(_ fileURL: URL) -> Bool {
        Self.allowedExtensions.contains(fileURL.pathExtension.lowercased())
    }

    func allowsReadOnlyHomeScope(_ fileURL: URL, homeDirectoryURL: URL) -> Bool {
        guard allows(fileURL) else {
            return false
        }
        // The Bridge's own uploads directory lives under ~/Library, which the
        // general home scope blocks. Its exact subtree is Bridge-owned image
        // attachments, so previewing there is safe. The comparison is purely
        // lexical (standardized, symlinks NOT resolved): if the uploads
        // directory were swapped for a symlink, a target reached through it
        // canonicalizes elsewhere and fails this compare, and the
        // O_NOFOLLOW_ANY open of the granted lexical path refuses any
        // symlink component that appears afterwards.
        let lexicalUploadsURL = uploadsDirectoryURL.standardizedFileURL
        if isDescendant(fileURL, of: lexicalUploadsURL) {
            return true
        }
        guard isDescendant(fileURL, of: homeDirectoryURL),
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
        // Default APFS is case-insensitive (~/library opens ~/Library) and
        // URL symlink resolution does not GUARANTEE canonical component
        // casing, so the compare must be ASCII case-insensitive (not a
        // locale-sensitive lowercasing).
        guard let first = fileComponents.dropFirst(rootComponents.count).first else {
            return false
        }
        return first.caseInsensitiveCompare("Library") == .orderedSame
    }
}

/// One image decode can pin hundreds of MB of RAM, and panel-root resolution
/// crosses the single Tidey Unix socket. Production therefore serializes the
/// whole validated read pipeline, but permits a small, short-lived waiter set
/// so normal back-to-back taps do not fail merely because the previous request
/// needs another hundred milliseconds.
struct BridgeImageReadAdmissionWaitPolicy: Equatable {
    let maximumWaiters: Int
    let timeout: TimeInterval

    static let immediate = BridgeImageReadAdmissionWaitPolicy(maximumWaiters: 0, timeout: 0)
    static let production = BridgeImageReadAdmissionWaitPolicy(maximumWaiters: 8, timeout: 2)
}

enum BridgeImageReadAdmissionRejection: Equatable {
    case unavailable
    case queueFull
    case timedOut
}

enum BridgeImageReadAdmissionOutcome: Equatable {
    case acquired
    case rejected(BridgeImageReadAdmissionRejection)
}

final class BridgeImageReadAdmission {
    static let shared = BridgeImageReadAdmission(limit: 1, waitPolicy: .production)

    private let limit: Int
    private let waitPolicy: BridgeImageReadAdmissionWaitPolicy
    private let condition = NSCondition()
    private var inFlight = 0
    private var waiterCount = 0

    init(limit: Int, waitPolicy: BridgeImageReadAdmissionWaitPolicy = .immediate) {
        self.limit = limit
        self.waitPolicy = waitPolicy
    }

    func tryAcquire() -> Bool {
        condition.lock()
        defer { condition.unlock() }
        guard inFlight < limit else {
            return false
        }
        inFlight += 1
        return true
    }

    func acquire() -> BridgeImageReadAdmissionOutcome {
        condition.lock()
        if inFlight < limit {
            inFlight += 1
            condition.unlock()
            return .acquired
        }
        guard waitPolicy.maximumWaiters > 0, waitPolicy.timeout > 0 else {
            condition.unlock()
            return .rejected(.unavailable)
        }
        guard waiterCount < waitPolicy.maximumWaiters else {
            condition.unlock()
            return .rejected(.queueFull)
        }

        waiterCount += 1
        let deadline = Date().addingTimeInterval(waitPolicy.timeout)
        while inFlight >= limit {
            let wasSignalled = condition.wait(until: deadline)
            if !wasSignalled, inFlight >= limit {
                waiterCount -= 1
                condition.unlock()
                return .rejected(.timedOut)
            }
        }
        waiterCount -= 1
        inFlight += 1
        condition.unlock()
        return .acquired
    }

    func release() {
        condition.lock()
        inFlight = max(0, inFlight - 1)
        condition.signal()
        condition.unlock()
    }

    var waiterCountForTesting: Int {
        condition.withLock { waiterCount }
    }
}

struct BridgeImageReadHandler {
    private let targetResolver: BridgePanelFileTargetResolver
    private let policy: BridgeImageFilePolicy
    private let limits: BridgeImageReadLimits
    private let admission: BridgeImageReadAdmission
    /// Test seam: runs inside the admitted section so concurrency tests can
    /// hold a request open deterministically. Never set in production.
    private let admittedWorkHookForTesting: (() -> Void)?

    init(rootResolver: PanelFileRootResolving,
         fileManager: FileManager = .default,
         homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser,
         uploadsDirectoryURL: URL = BridgePaths().uploadsDirectory,
         limits: BridgeImageReadLimits = .production,
         admission: BridgeImageReadAdmission = .shared,
         admittedWorkHookForTesting: (() -> Void)? = nil) {
        self.targetResolver = BridgePanelFileTargetResolver(rootResolver: rootResolver,
                                                            fileManager: fileManager,
                                                            homeDirectoryURL: homeDirectoryURL)
        self.policy = BridgeImageFilePolicy(uploadsDirectoryURL: uploadsDirectoryURL)
        self.limits = limits
        self.admission = admission
        self.admittedWorkHookForTesting = admittedWorkHookForTesting
    }

    func handle(_ request: BridgeRequest) throws -> BridgeResponse? {
        guard request.action == "image_read" else {
            return nil
        }
        let params = try BridgeImageReadRequest(params: request.params)
        let requestedDimension = clampRequestedDimension(params.maxPixelDimension)
        let requestedDisplayName = URL(fileURLWithPath: params.path).lastPathComponent
        BridgeImageReadDiagnostics.log(
            "start request_id=\(request.id) file=\(requestedDisplayName) max_dimension=\(requestedDimension)"
        )

        // Root lookup uses Tidey's request socket, which can reject overlapping
        // short-lived connections. It belongs inside the same bounded admission
        // region as decode so an image burst cannot fail before reaching the
        // decode queue.
        let admissionStartedAt = CFAbsoluteTimeGetCurrent()
        let admissionOutcome = admission.acquire()
        guard admissionOutcome == .acquired else {
            let rejection: String
            switch admissionOutcome {
            case .rejected(.unavailable): rejection = "unavailable"
            case .rejected(.queueFull): rejection = "queue_full"
            case .rejected(.timedOut): rejection = "timed_out"
            case .acquired: rejection = "none"
            }
            BridgeImageReadDiagnostics.log(
                "admission_rejected request_id=\(request.id) file=\(requestedDisplayName) reason=\(rejection)"
            )
            throw BridgeInternalError.resourceBusy("目前正在處理另一張圖片，請稍後再試。")
        }
        let admissionWaitMilliseconds = (CFAbsoluteTimeGetCurrent() - admissionStartedAt) * 1_000
        if admissionWaitMilliseconds >= 1 {
            BridgeImageReadDiagnostics.log(
                "admission_acquired request_id=\(request.id) file=\(requestedDisplayName) wait_ms=\(String(format: "%.1f", admissionWaitMilliseconds))"
            )
        }
        defer { admission.release() }

        let resolved = try targetResolver.resolve(path: params.path,
                                                  workspaceID: params.workspaceID,
                                                  panelID: params.panelID,
                                                  policy: policy,
                                                  allowsReadOnlyHomeScope: true)
        let displayName = resolved.targetURL.lastPathComponent

        let opened = try BridgeSafeFileOpener.openRegularFile(at: resolved.targetURL,
                                                              notFoundMessage: "image_read target does not exist",
                                                              outsideScopeMessage: policy.outsideRootMessage)
        defer { opened.close() }

        guard opened.size <= limits.maximumSourceBytes else {
            throw BridgeInternalError.fileTooLarge("圖片檔案太大，無法產生預覽。")
        }
        if params.ifRevisionToken == opened.revisionToken {
            let result: [String: JSONValue] = [
                "not_modified": .bool(true),
                "normalized_path": .string(resolved.targetURL.path),
                "display_name": .string(displayName),
                "source_size": .number(Double(opened.size)),
                "revision_token": .string(opened.revisionToken),
                "read_only": .bool(true),
            ]
            BridgeImageReadDiagnostics.log("conditional request_id=\(request.id) file=\(displayName) not_modified=true")
            return BridgeResponse(id: request.id, ok: true, result: result, error: nil)
        }

        admittedWorkHookForTesting?()

        // Bounded read from the same descriptor: a file that grows between
        // fstat and the read is rejected instead of buffered without limit.
        let sourceData = try BridgeSafeFileOpener.readBounded(from: opened.fileHandle,
                                                              maximumBytes: Int(limits.maximumSourceBytes))
        guard Int64(sourceData.count) <= limits.maximumSourceBytes else {
            throw BridgeInternalError.fileTooLarge("圖片檔案太大，無法產生預覽。")
        }
        guard !sourceData.isEmpty else {
            throw BridgeInternalError.imageDecodeFailed("這個檔案無法解讀為圖片。")
        }

        let noCacheOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let imageSource = CGImageSourceCreateWithData(sourceData as CFData, noCacheOptions),
              CGImageSourceGetCount(imageSource) >= 1,
              let typeIdentifier = CGImageSourceGetType(imageSource),
              let sourceType = UTType(typeIdentifier as String) else {
            throw BridgeInternalError.imageDecodeFailed("這個檔案無法解讀為圖片。")
        }
        guard let matchedType = [UTType.png, UTType.jpeg].first(where: { sourceType.conforms(to: $0) }) else {
            throw BridgeInternalError.imageFormatUnsupported("這個圖片格式目前不支援預覽。")
        }
        // Exactly one frame: an APNG or other multi-frame container must not
        // slip through on its first frame's properties.
        guard CGImageSourceGetCount(imageSource) == 1 else {
            throw BridgeInternalError.imageFormatUnsupported("這個圖片格式目前不支援預覽。")
        }

        guard let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, noCacheOptions) as? [CFString: Any],
              let pixelWidth = properties[kCGImagePropertyPixelWidth] as? Int,
              let pixelHeight = properties[kCGImagePropertyPixelHeight] as? Int,
              pixelWidth > 0, pixelHeight > 0 else {
            throw BridgeInternalError.imageDecodeFailed("這個檔案無法解讀為圖片。")
        }
        let (pixelProduct, pixelOverflow) = Int64(pixelWidth).multipliedReportingOverflow(by: Int64(pixelHeight))
        guard !pixelOverflow, pixelProduct <= limits.maximumSourcePixels else {
            throw BridgeInternalError.imageDimensionsTooLarge("圖片像素尺寸太大，無法產生預覽。")
        }

        // Always decode and re-encode — never pass source bytes through.
        // A truncated raster or animated payload must not reach the iPhone
        // just because its header parsed.
        let preview = try makeBoundedPreview(from: imageSource,
                                             sourceType: matchedType,
                                             requestedDimension: requestedDimension)

        let result: [String: JSONValue] = [
            "not_modified": .bool(false),
            "normalized_path": .string(resolved.targetURL.path),
            "display_name": .string(displayName),
            "source_mime_type": .string(Self.mimeType(for: matchedType)),
            "preview_mime_type": .string(Self.mimeType(for: preview.type)),
            "data_base64": .string(preview.data.base64EncodedString()),
            "source_size": .number(Double(sourceData.count)),
            "preview_size": .number(Double(preview.data.count)),
            "pixel_width": .number(Double(preview.pixelWidth)),
            "pixel_height": .number(Double(preview.pixelHeight)),
            "revision_token": .string(opened.revisionToken),
            "read_only": .bool(true),
        ]
        BridgeImageReadDiagnostics.log("success request_id=\(request.id) file=\(displayName) source_bytes=\(sourceData.count) preview_bytes=\(preview.data.count) dimensions=\(preview.pixelWidth)x\(preview.pixelHeight) mime=\(Self.mimeType(for: preview.type))")
        return BridgeResponse(id: request.id, ok: true, result: result, error: nil)
    }

    private struct EncodedPreview {
        let data: Data
        let type: UTType
        let pixelWidth: Int
        let pixelHeight: Int
    }

    private func clampRequestedDimension(_ requested: Int?) -> Int {
        let requested = requested ?? limits.defaultRequestedDimension
        return min(max(requested, limits.minimumRequestedDimension), limits.maximumRequestedDimension)
    }

    private func makeBoundedPreview(from imageSource: CGImageSource,
                                    sourceType: UTType,
                                    requestedDimension: Int) throws -> EncodedPreview {
        var dimension = requestedDimension
        while dimension >= 64 {
            let thumbnailOptions = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: dimension,
            ] as CFDictionary
            guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, thumbnailOptions) else {
                throw BridgeInternalError.imageDecodeFailed("這個檔案無法解讀為圖片。")
            }
            // PNG first for PNG sources to keep sharp UI captures lossless.
            // JPEG is only safe when the decoded image has no alpha channel;
            // an alpha-bearing PNG must shrink until lossless encoding fits.
            let candidateTypesForThumbnail: [UTType]
            if sourceType == .png {
                candidateTypesForThumbnail = Self.hasAlpha(thumbnail) ? [.png] : [.png, .jpeg]
            } else {
                candidateTypesForThumbnail = [.jpeg]
            }
            var candidateTypes = candidateTypesForThumbnail
            while let type = candidateTypes.first {
                candidateTypes.removeFirst()
                guard let encoded = Self.encode(image: thumbnail, as: type) else {
                    continue
                }
                if encoded.count <= limits.maximumEncodedPreviewBytes {
                    return EncodedPreview(data: encoded,
                                          type: type,
                                          pixelWidth: thumbnail.width,
                                          pixelHeight: thumbnail.height)
                }
            }
            dimension = dimension * 3 / 4
        }
        throw BridgeInternalError.fileTooLarge("無法在大小限制內產生圖片預覽。")
    }

    private static func encode(image: CGImage, as type: UTType) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData,
                                                                 type.identifier as CFString,
                                                                 1,
                                                                 nil) else {
            return nil
        }
        let encodeOptions = [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary
        CGImageDestinationAddImage(destination, image, encodeOptions)
        guard CGImageDestinationFinalize(destination) else {
            return nil
        }
        return data as Data
    }

    private static func hasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast:
            return false
        case .premultipliedFirst, .premultipliedLast, .first, .last, .alphaOnly:
            return true
        @unknown default:
            return true
        }
    }

    private static func mimeType(for type: UTType) -> String {
        type == .png ? "image/png" : "image/jpeg"
    }
}
