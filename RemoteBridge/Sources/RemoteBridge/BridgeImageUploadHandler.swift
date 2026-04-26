import CryptoKit
import Foundation

enum BridgeImageUploadDiagnostics {
    static func log(_ message: String) {
        BridgeLogger.server.info("[image_upload] \(message, privacy: .public)")
        if let data = "[image_upload] \(message)\n".data(using: .utf8) {
            FileHandle.standardError.write(data)
        }
    }
}

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
        BridgeImageUploadDiagnostics.log("handler enter request_id=\(request.id) action=\(request.action) has_params=\(request.params != nil)")
        let params: BridgeImageUploadRequest
        do {
            params = try BridgeImageUploadRequest(params: request.params)
            BridgeImageUploadDiagnostics.log("params parsed request_id=\(request.id) workspace_id=\(params.workspaceID) panel_id=\(params.panelID) mime=\(params.mimeType) base64_length=\(params.base64Data.count)")
        } catch {
            BridgeImageUploadDiagnostics.log("params rejected request_id=\(request.id) error=\(error)")
            throw error
        }
        guard params.mimeType == Self.allowedMimeType else {
            BridgeImageUploadDiagnostics.log("mime rejected request_id=\(request.id) mime=\(params.mimeType)")
            throw BridgeInternalError.invalidRequest("image_upload only accepts image/jpeg")
        }
        guard let data = Data(base64Encoded: params.base64Data) else {
            BridgeImageUploadDiagnostics.log("base64 rejected request_id=\(request.id) base64_length=\(params.base64Data.count)")
            throw BridgeInternalError.invalidRequest("image_upload data_base64 is not valid base64")
        }
        guard data.count <= Self.maximumUploadSizeBytes else {
            BridgeImageUploadDiagnostics.log("size rejected request_id=\(request.id) bytes=\(data.count) limit=\(Self.maximumUploadSizeBytes)")
            throw BridgeInternalError.fileTooLarge("圖片超過 10MB，無法上傳。")
        }

        let directory = try destinationResolver.uploadDirectory()
        BridgeImageUploadDiagnostics.log("write start request_id=\(request.id) directory=\(directory.path) bytes=\(data.count)")
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let targetURL = directory.appendingPathComponent(filenameGenerator.nextFilename(), isDirectory: false)
        try data.write(to: targetURL, options: .atomic)
        BridgeImageUploadDiagnostics.log("write success request_id=\(request.id) path=\(targetURL.path) bytes=\(data.count)")

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
