import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum BridgeImageReadDiagnostics {
    // Unlike file_read diagnostics, never log the full requested path or any
    // payload bytes — image targets are more sensitive; basename only.
    static func log(_ message: String) {
        BridgeLogger.server.info("[image_read] \(message, privacy: .public)")
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
        maximumEncodedPreviewBytes: 4 * 1024 * 1024
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
        // attachments, so previewing there is safe.
        let normalizedUploadsURL = uploadsDirectoryURL.standardizedFileURL.resolvingSymlinksInPath()
        if isDescendant(fileURL, of: normalizedUploadsURL) {
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
        return fileComponents.dropFirst(rootComponents.count).first == "Library"
    }
}

struct BridgeImageReadHandler {
    private let targetResolver: BridgePanelFileTargetResolver
    private let policy: BridgeImageFilePolicy
    private let limits: BridgeImageReadLimits

    init(rootResolver: PanelFileRootResolving,
         fileManager: FileManager = .default,
         homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser,
         uploadsDirectoryURL: URL = BridgePaths().uploadsDirectory,
         limits: BridgeImageReadLimits = .production) {
        self.targetResolver = BridgePanelFileTargetResolver(rootResolver: rootResolver,
                                                            fileManager: fileManager,
                                                            homeDirectoryURL: homeDirectoryURL)
        self.policy = BridgeImageFilePolicy(uploadsDirectoryURL: uploadsDirectoryURL)
        self.limits = limits
    }

    func handle(_ request: BridgeRequest) throws -> BridgeResponse? {
        guard request.action == "image_read" else {
            return nil
        }
        let params = try BridgeImageReadRequest(params: request.params)
        let requestedDimension = clampRequestedDimension(params.maxPixelDimension)
        let resolved = try targetResolver.resolve(path: params.path,
                                                  workspaceID: params.workspaceID,
                                                  panelID: params.panelID,
                                                  policy: policy,
                                                  allowsReadOnlyHomeScope: true)
        let displayName = resolved.targetURL.lastPathComponent
        BridgeImageReadDiagnostics.log("start request_id=\(request.id) file=\(displayName) max_dimension=\(requestedDimension)")

        let opened = try BridgeSafeFileOpener.openRegularFile(at: resolved.targetURL,
                                                              notFoundMessage: "image_read target does not exist",
                                                              outsideScopeMessage: policy.outsideRootMessage)
        defer { opened.close() }

        guard opened.size <= limits.maximumSourceBytes else {
            throw BridgeInternalError.fileTooLarge("圖片檔案太大，無法產生預覽。")
        }
        guard let sourceData = try opened.fileHandle.readToEnd(), !sourceData.isEmpty else {
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

        let preview: EncodedPreview
        if max(pixelWidth, pixelHeight) <= requestedDimension, sourceData.count <= limits.maximumEncodedPreviewBytes {
            preview = EncodedPreview(data: sourceData,
                                     type: matchedType,
                                     pixelWidth: pixelWidth,
                                     pixelHeight: pixelHeight)
        } else {
            preview = try makeBoundedPreview(from: imageSource,
                                             sourceType: matchedType,
                                             requestedDimension: requestedDimension)
        }

        let result: [String: JSONValue] = [
            "normalized_path": .string(resolved.targetURL.path),
            "display_name": .string(displayName),
            "source_mime_type": .string(Self.mimeType(for: matchedType)),
            "preview_mime_type": .string(Self.mimeType(for: preview.type)),
            "data_base64": .string(preview.data.base64EncodedString()),
            "source_size": .number(Double(opened.size)),
            "preview_size": .number(Double(preview.data.count)),
            "pixel_width": .number(Double(preview.pixelWidth)),
            "pixel_height": .number(Double(preview.pixelHeight)),
            "revision_token": .string("\(opened.modificationTimeNanoseconds):\(opened.size)"),
            "read_only": .bool(true),
        ]
        BridgeImageReadDiagnostics.log("success request_id=\(request.id) file=\(displayName) source_bytes=\(opened.size) preview_bytes=\(preview.data.count) dimensions=\(preview.pixelWidth)x\(preview.pixelHeight) mime=\(Self.mimeType(for: preview.type))")
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
            // PNG first for PNG sources to keep sharp UI captures lossless;
            // fall back to JPEG when the lossless encoding blows the cap.
            var candidateTypes: [UTType] = sourceType == .png ? [.png, .jpeg] : [.jpeg]
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

    private static func mimeType(for type: UTType) -> String {
        type == .png ? "image/png" : "image/jpeg"
    }
}
