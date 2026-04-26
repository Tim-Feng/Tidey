import CryptoKit
import Foundation

protocol BridgeImageUploadDestinationResolving {
    func uploadDirectory() throws -> URL
}

protocol BridgeImageUploadFilenameGenerating {
    func nextFilename() -> String
}

struct BridgeImageUploadHandler {
    private static let maximumUploadSizeBytes = 10 * 1024 * 1024
    private static let allowedMimeType = "image/jpeg"

    private let destinationResolver: BridgeImageUploadDestinationResolving
    private let filenameGenerator: BridgeImageUploadFilenameGenerating
    private let fileManager: FileManager

    init(destinationResolver: BridgeImageUploadDestinationResolving,
         filenameGenerator: BridgeImageUploadFilenameGenerating,
         fileManager: FileManager = .default) {
        self.destinationResolver = destinationResolver
        self.filenameGenerator = filenameGenerator
        self.fileManager = fileManager
    }

    func handle(_ request: BridgeRequest) throws -> BridgeResponse? {
        guard request.action == "image_upload" else {
            return nil
        }
        let params = try BridgeImageUploadRequest(params: request.params)
        guard params.mimeType == Self.allowedMimeType else {
            throw BridgeInternalError.invalidRequest("image_upload only accepts image/jpeg")
        }
        guard let data = Data(base64Encoded: params.base64Data) else {
            throw BridgeInternalError.invalidRequest("image_upload data_base64 is not valid base64")
        }
        guard data.count <= Self.maximumUploadSizeBytes else {
            throw BridgeInternalError.fileTooLarge("圖片超過 10MB，無法上傳。")
        }

        let directory = try destinationResolver.uploadDirectory()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let targetURL = directory.appendingPathComponent(filenameGenerator.nextFilename(), isDirectory: false)
        try data.write(to: targetURL, options: .atomic)

        return BridgeResponse(id: request.id,
                              ok: true,
                              result: [
                                "path": .string(targetURL.path),
                                "bytes": .number(Double(data.count)),
                                "mime_type": .string(params.mimeType),
                                "sha256": .string(Self.sha256(data)),
                              ],
                              error: nil)
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

struct DownloadsImageUploadDestinationResolver: BridgeImageUploadDestinationResolving {
    func uploadDirectory() throws -> URL {
        if let downloadsURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first {
            return downloadsURL.appendingPathComponent("Tidey-Remote", isDirectory: true)
        }
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Downloads", isDirectory: true)
            .appendingPathComponent("Tidey-Remote", isDirectory: true)
    }
}

struct TimestampedImageUploadFilenameGenerator: BridgeImageUploadFilenameGenerating {
    func nextFilename() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let timestamp = formatter.string(from: Date())
        let shortUUID = UUID().uuidString
            .replacingOccurrences(of: "-", with: "")
            .prefix(8)
            .lowercased()
        return "\(timestamp)-\(shortUUID).jpg"
    }
}

private struct BridgeImageUploadRequest {
    let workspaceID: String
    let panelID: String
    let mimeType: String
    let base64Data: String

    init(params: [String: JSONValue]?) throws {
        guard let params,
              let workspaceID = params["workspace_id"]?.stringValue,
              let panelID = params["panel_id"]?.stringValue,
              let mimeType = params["mime_type"]?.stringValue,
              let base64Data = params["data_base64"]?.stringValue,
              !workspaceID.isEmpty,
              !panelID.isEmpty,
              !mimeType.isEmpty,
              !base64Data.isEmpty else {
            throw BridgeInternalError.invalidRequest("image_upload requires workspace_id, panel_id, mime_type, and data_base64")
        }
        self.workspaceID = workspaceID
        self.panelID = panelID
        self.mimeType = mimeType
        self.base64Data = base64Data
    }
}
