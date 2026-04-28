import Foundation

struct BridgeUploadGarbageCollectorConfiguration: Equatable {
    var retentionInterval: TimeInterval = 7 * 24 * 60 * 60
    var maximumTotalBytes: Int64 = 1_073_741_824
    var safetyFloorInterval: TimeInterval = 24 * 60 * 60
    var startupDelay: TimeInterval = 30
    var sweepInterval: TimeInterval = 6 * 60 * 60
}

struct BridgeUploadFileRecord: Equatable {
    let url: URL
    let modifiedAt: Date
    let byteCount: Int64
}

struct BridgeUploadStorageStats: Codable, Equatable {
    let fileCount: Int
    let totalBytes: Int64
    let oldestModifiedAt: Date?

    enum CodingKeys: String, CodingKey {
        case fileCount = "file_count"
        case totalBytes = "total_bytes"
        case oldestModifiedAt = "oldest_mtime"
    }
}

struct BridgeUploadSweepResult: Codable, Equatable {
    let removedFileCount: Int
    let freedBytes: Int64
    let remainingFileCount: Int
    let remainingBytes: Int64

    enum CodingKeys: String, CodingKey {
        case removedFileCount = "removed_file_count"
        case freedBytes = "freed_bytes"
        case remainingFileCount = "remaining_file_count"
        case remainingBytes = "remaining_bytes"
    }
}

protocol BridgeUploadStorageManaging {
    func uploadFiles(in directory: URL) throws -> [BridgeUploadFileRecord]
    func removeUploadFile(at url: URL) throws
}

protocol BridgeUploadClock {
    var now: Date { get }
}

struct BridgeSystemUploadClock: BridgeUploadClock {
    var now: Date { Date() }
}

struct BridgeUploadFileManager: BridgeUploadStorageManaging {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func uploadFiles(in directory: URL) throws -> [BridgeUploadFileRecord] {
        guard fileManager.fileExists(atPath: directory.path) else {
            return []
        }

        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]
        return try fileManager.contentsOfDirectory(at: directory,
                                                   includingPropertiesForKeys: keys,
                                                   options: [.skipsHiddenFiles])
            .compactMap { url in
                let values = try url.resourceValues(forKeys: Set(keys))
                guard values.isRegularFile == true,
                      let modifiedAt = values.contentModificationDate,
                      let fileSize = values.fileSize else {
                    return nil
                }
                return BridgeUploadFileRecord(url: url,
                                              modifiedAt: modifiedAt,
                                              byteCount: Int64(fileSize))
            }
    }

    func removeUploadFile(at url: URL) throws {
        try fileManager.removeItem(at: url)
    }
}

final class BridgeUploadGarbageCollector {
    private let uploadDirectory: URL
    private let configuration: BridgeUploadGarbageCollectorConfiguration
    private let storage: BridgeUploadStorageManaging
    private let clock: BridgeUploadClock
    private let queue: DispatchQueue
    private var timer: DispatchSourceTimer?

    init(uploadDirectory: URL,
         configuration: BridgeUploadGarbageCollectorConfiguration = BridgeUploadGarbageCollectorConfiguration(),
         storage: BridgeUploadStorageManaging = BridgeUploadFileManager(),
         clock: BridgeUploadClock = BridgeSystemUploadClock(),
         queue: DispatchQueue = DispatchQueue(label: "com.tidey.remote-bridge.upload-gc")) {
        self.uploadDirectory = uploadDirectory
        self.configuration = configuration
        self.storage = storage
        self.clock = clock
        self.queue = queue
    }

    func start() {
        queue.async { [weak self] in
            guard let self, self.timer == nil else {
                return
            }
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + self.configuration.startupDelay,
                           repeating: self.configuration.sweepInterval)
            timer.setEventHandler { [weak self] in
                self?.performScheduledSweep()
            }
            self.timer = timer
            timer.resume()
        }
    }

    func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
        }
    }

    func stats() throws -> BridgeUploadStorageStats {
        let files = try storage.uploadFiles(in: uploadDirectory)
        return Self.stats(for: files)
    }

    func sweep() throws -> BridgeUploadSweepResult {
        let now = clock.now
        var files = try storage.uploadFiles(in: uploadDirectory)
        var removedFileCount = 0
        var freedBytes: Int64 = 0

        let retentionCutoff = now.addingTimeInterval(-configuration.retentionInterval)
        let expiredFiles = files
            .filter { $0.modifiedAt < retentionCutoff }
            .sorted { lhs, rhs in lhs.modifiedAt < rhs.modifiedAt }
        for file in expiredFiles {
            try storage.removeUploadFile(at: file.url)
            removedFileCount += 1
            freedBytes += file.byteCount
        }
        let expiredURLs = Set(expiredFiles.map(\.url))
        files.removeAll { expiredURLs.contains($0.url) }

        var totalBytes = files.reduce(Int64(0)) { $0 + $1.byteCount }
        if totalBytes > configuration.maximumTotalBytes {
            let safetyCutoff = now.addingTimeInterval(-configuration.safetyFloorInterval)
            for file in files.sorted(by: { lhs, rhs in lhs.modifiedAt < rhs.modifiedAt }) where totalBytes > configuration.maximumTotalBytes {
                guard file.modifiedAt <= safetyCutoff else {
                    continue
                }
                try storage.removeUploadFile(at: file.url)
                removedFileCount += 1
                freedBytes += file.byteCount
                totalBytes -= file.byteCount
                files.removeAll { $0.url == file.url }
            }
        }

        return BridgeUploadSweepResult(removedFileCount: removedFileCount,
                                       freedBytes: freedBytes,
                                       remainingFileCount: files.count,
                                       remainingBytes: files.reduce(Int64(0)) { $0 + $1.byteCount })
    }

    private func performScheduledSweep() {
        do {
            let result = try sweep()
            let freedMB = Double(result.freedBytes) / 1_048_576.0
            BridgeLogger.server.info("upload GC removed_files=\(result.removedFileCount, privacy: .public) freed_mb=\(freedMB, format: .fixed(precision: 2)) remaining_files=\(result.remainingFileCount, privacy: .public) remaining_bytes=\(result.remainingBytes, privacy: .public)")
        } catch {
            BridgeLogger.server.error("upload GC failed error=\(error.localizedDescription, privacy: .public)")
        }
    }

    private static func stats(for files: [BridgeUploadFileRecord]) -> BridgeUploadStorageStats {
        BridgeUploadStorageStats(fileCount: files.count,
                                 totalBytes: files.reduce(Int64(0)) { $0 + $1.byteCount },
                                 oldestModifiedAt: files.map(\.modifiedAt).min())
    }
}
