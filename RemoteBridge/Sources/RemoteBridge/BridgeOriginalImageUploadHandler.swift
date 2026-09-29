import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Connection-owned, bounded staging. No client-supplied filesystem paths.
/// Originals are deliberately outside the top-level ephemeral upload GC.
final class BridgeOriginalImageUploadHandler {
    static let capability = "image_original_upload_v1"
    static let maximumBytes = 20 * 1024 * 1024
    static let chunkBytes = 1024 * 1024
    private let directory: () throws -> URL
    private let lock = NSLock()
    private var transfers: [String: Transfer] = [:]
    private var committing: [String: (workspace: String, panel: String)] = [:]
    private var closed = false
    private var expiryTimer: DispatchSourceTimer?
    private let now: () -> Date
    private let beforeValidation: () -> Void

    private final class Transfer {
        let url: URL
        let handle: FileHandle
        let workspace: String
        let panel: String
        let bytes: Int
        let mime: String
        let hash: String
        var offset = 0
        var touched: Date
        var hasher = SHA256()
        init(url: URL, workspace: String, panel: String, bytes: Int, mime: String, hash: String, now: Date) throws {
            self.url = url; self.workspace = workspace; self.panel = panel
            self.bytes = bytes; self.mime = mime; self.hash = hash; touched = now
            guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw BridgeInternalError.invalidRequest("無法建立圖片暫存檔。")
            }
            handle = try FileHandle(forWritingTo: url)
        }
        deinit { try? handle.close(); try? FileManager.default.removeItem(at: url) }
    }

    init(directory: @escaping () throws -> URL, now: @escaping () -> Date = Date.init, beforeValidation: @escaping () -> Void = {}) {
        self.directory = directory; self.now = now; self.beforeValidation = beforeValidation
    }
    deinit { expiryTimer?.cancel() }
    func close() {
        lock.lock(); defer { lock.unlock() }
        closed = true; expiryTimer?.cancel(); expiryTimer = nil; transfers.removeAll(); committing.removeAll()
    }
    private func startExpiryTimerIfNeeded() {
        guard expiryTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 60, repeating: 60)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.lock(); defer { self.lock.unlock() }
            self.transfers = self.transfers.filter { self.now().timeIntervalSince($0.value.touched) < 180 }
        }
        expiryTimer = timer; timer.resume()
    }

    func handle(_ request: BridgeRequest) throws -> BridgeResponse? {
        guard ["image_original_begin", "image_original_chunk", "image_original_commit", "image_original_cancel"].contains(request.action) else { return nil }
        lock.lock()
        var lockHeld = true
        defer { if lockHeld { lock.unlock() } }
        guard !closed else { throw invalid("圖片連線已結束，請重新選取。") }
        transfers = transfers.filter { now().timeIntervalSince($0.value.touched) < 180 }
        guard let p = request.params, let workspace = p["workspace_id"]?.stringValue, !workspace.isEmpty,
              let panel = p["panel_id"]?.stringValue, !panel.isEmpty else { throw invalid("缺少圖片工作區。") }
        func response(_ result: [String: JSONValue]) -> BridgeResponse { BridgeResponse(id: request.id, ok: true, result: result, error: nil) }
        if request.action == "image_original_begin" {
            guard let bytes = p["bytes"]?.intValue, bytes > 0, bytes <= Self.maximumBytes else {
                throw BridgeInternalError.fileTooLarge("原圖上限為 20 MiB；請透過 AirDrop 或檔案傳送保存較大的原檔。")
            }
            guard let mime = p["mime_type"]?.stringValue, ["image/jpeg", "image/png", "image/heic", "image/heif"].contains(mime),
                  let hash = p["sha256"]?.stringValue, hash.count == 64, hash.allSatisfy({ "0123456789abcdef".contains($0) }) else { throw invalid("不支援的原圖格式或雜湊。") }
            guard transfers.count + committing.count < 10 else { throw invalid("同時上傳的圖片過多。") }
            let root = try directory().appendingPathComponent("originals", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            // A process crash bypasses Transfer.deinit. Only old, private staging
            // names are reaped; completed original files are never aged out.
            for url in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey])
                where url.lastPathComponent.hasPrefix(".upload-") {
                if let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                   values.isRegularFile == true, let modified = values.contentModificationDate,
                   now().timeIntervalSince(modified) > 3600 { try? FileManager.default.removeItem(at: url) }
            }
            let id = UUID().uuidString.lowercased()
            startExpiryTimerIfNeeded()
            transfers[id] = try Transfer(url: root.appendingPathComponent(".upload-\(id)"), workspace: workspace, panel: panel, bytes: bytes, mime: mime, hash: hash, now: now())
            return response(["upload_id": .string(id), "chunk_bytes": .number(Double(Self.chunkBytes))])
        }
        if request.action == "image_original_cancel", let id = p["upload_id"]?.stringValue,
           let owner = committing[id], owner.workspace == workspace, owner.panel == panel {
            committing[id] = nil
            return response(["cancelled": .bool(true)])
        }
        guard let id = p["upload_id"]?.stringValue, let t = transfers[id], t.workspace == workspace, t.panel == panel else { throw invalid("圖片上傳已失效或不屬於此對話。") }
        if request.action == "image_original_cancel" { transfers[id] = nil; return response(["cancelled": .bool(true)]) }
        do {
            if request.action == "image_original_chunk" {
                guard let offset = p["offset"]?.intValue, offset == t.offset,
                      let encoded = p["data_base64"]?.stringValue, encoded.utf8.count <= ((Self.chunkBytes + 2) / 3) * 4,
                      let data = Data(base64Encoded: encoded), !data.isEmpty, data.count <= Self.chunkBytes,
                      data.count <= t.bytes - t.offset else { throw invalid("圖片分塊順序或大小不符，請重新選取。") }
                try t.handle.write(contentsOf: data)
                t.hasher.update(data: data); t.offset += data.count; t.touched = now()
                return response(["received_bytes": .number(Double(t.offset))])
            }
            guard t.offset == t.bytes, t.hasher.finalize().map({ String(format: "%02x", $0) }).joined() == t.hash else { throw invalid("圖片未完整送達或雜湊不符，請重新選取。") }
            transfers[id] = nil
            committing[id] = (workspace, panel)
            lock.unlock(); lockHeld = false
            // This worker exclusively owns t. Decode and all large writes happen
            // outside the connection lock so close/cancel never waits for ImageIO.
            try t.handle.synchronize(); try t.handle.close()
            let validated = try validate(t)
            let destination = t.url.deletingLastPathComponent().appendingPathComponent("\(id).\(validated.ext)")
            let agentURL = validated.jpeg == nil ? destination : destination.deletingPathExtension().appendingPathExtension("agent.jpg")
            let stagedAgent = t.url.appendingPathExtension("agent")
            defer { try? FileManager.default.removeItem(at: stagedAgent) }
            if let jpeg = validated.jpeg { try jpeg.write(to: stagedAgent, options: .atomic) }
            lock.lock(); lockHeld = true
            guard !closed, committing[id] != nil else { throw invalid("圖片上傳已取消或連線已結束。") }
            defer { committing[id] = nil }
            do {
                if validated.jpeg != nil { try FileManager.default.moveItem(at: stagedAgent, to: agentURL) }
                try FileManager.default.moveItem(at: t.url, to: destination)
            } catch {
                if agentURL != destination { try? FileManager.default.removeItem(at: agentURL) }
                throw error
            }
            return response(["path": .string(destination.path), "agent_path": .string(agentURL.path),
                             "bytes": .number(Double(t.bytes)), "mime_type": .string(t.mime), "sha256": .string(t.hash)])
        } catch {
            if !lockHeld { lock.lock(); lockHeld = true }
            transfers[id] = nil; committing[id] = nil
            throw error
        }
    }

    private func validate(_ t: Transfer) throws -> (ext: String, jpeg: Data?) {
        beforeValidation()
        // Share the existing process-wide image decode admission with previews;
        // concurrent clients must not allocate several full-resolution HEICs.
        let admission = BridgeImageReadAdmission.shared
        guard admission.acquire() == .acquired else { throw BridgeInternalError.resourceBusy("目前正在處理另一張圖片，請稍後重新選取。") }
        defer { admission.release() }
        guard let source = CGImageSourceCreateWithURL(t.url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetStatus(source) == .statusComplete,
              let name = CGImageSourceGetType(source) as String?, let type = UTType(name) else { throw invalid("無法讀取原圖。") }
        let ext: String
        switch t.mime {
        case "image/jpeg" where type == .jpeg: ext = "jpg"
        case "image/png" where type == .png: ext = "png"
        case "image/heic" where type == .heic: ext = "heic"
        case "image/heif" where type == .heif || type == .heic: ext = type == .heic ? "heic" : "heif"
        default: throw invalid("圖片內容與格式不符。")
        }
        let index = CGImageSourceGetPrimaryImageIndex(source)
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int,
              w > 0, h > 0, w <= 100_000_000 / h,
              (ext == "heic" || ext == "heif" || CGImageSourceGetCount(source) == 1) else { throw invalid("原圖尺寸過大或為多張圖片格式。") }
        // Decode a bounded thumbnail even for pass-through JPEG/PNG: reject broken image data.
        let isHEIF = ext == "heic" || ext == "heif"
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, index, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: isHEIF ? max(w, h) : 64,
                kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { throw invalid("原圖資料損壞。") }
        guard isHEIF else { return (ext, nil) }
        // Agent-compatible, full-resolution derivative. The original bytes above are never changed.
        let jpeg = NSMutableData()
        guard let output = CGImageDestinationCreateWithData(jpeg, UTType.jpeg.identifier as CFString, 1, nil) else { throw invalid("無法建立 agent 圖片副本。") }
        CGImageDestinationAddImage(output, image, [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
        guard CGImageDestinationFinalize(output) else { throw invalid("無法完成 agent 圖片副本。") }
        return (ext, jpeg as Data)
    }
    private func invalid(_ message: String) -> BridgeInternalError { .invalidRequest(message) }
}
