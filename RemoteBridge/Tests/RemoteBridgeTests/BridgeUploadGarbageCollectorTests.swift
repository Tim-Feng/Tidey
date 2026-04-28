import Foundation
import XCTest
@testable import RemoteBridge

final class BridgeUploadGarbageCollectorTests: XCTestCase {
    func testStatsReturnsFileCountTotalBytesAndOldestModificationDate() throws {
        let fixture = UploadGCFixture(files: [
            .file("new.jpg", modifiedAt: fixtureDate(100), bytes: 10),
            .file("old.jpg", modifiedAt: fixtureDate(50), bytes: 30),
        ])

        let stats = try fixture.collector.stats()

        XCTAssertEqual(stats.fileCount, 2)
        XCTAssertEqual(stats.totalBytes, 40)
        XCTAssertEqual(stats.oldestModifiedAt, fixtureDate(50))
    }

    func testSweepRemovesFilesOlderThanRetention() throws {
        let fixture = UploadGCFixture(files: [
            .file("expired.jpg", modifiedAt: fixtureDate(daysAgo: 8), bytes: 100),
            .file("fresh.jpg", modifiedAt: fixtureDate(daysAgo: 2), bytes: 200),
        ])

        let result = try fixture.collector.sweep()

        XCTAssertEqual(fixture.storage.removedURLs.map(\.lastPathComponent), ["expired.jpg"])
        XCTAssertEqual(result.removedFileCount, 1)
        XCTAssertEqual(result.freedBytes, 100)
        XCTAssertEqual(result.remainingFileCount, 1)
        XCTAssertEqual(result.remainingBytes, 200)
    }

    func testSweepReducesSizeCapByRemovingOldestFilesOutsideSafetyFloor() throws {
        let fixture = UploadGCFixture(configuration: BridgeUploadGarbageCollectorConfiguration(retentionInterval: 7 * 24 * 60 * 60,
                                                                                              maximumTotalBytes: 1_000,
                                                                                              safetyFloorInterval: 24 * 60 * 60),
                                      files: [
                                        .file("old-a.jpg", modifiedAt: fixtureDate(daysAgo: 3), bytes: 400),
                                        .file("old-b.jpg", modifiedAt: fixtureDate(daysAgo: 2), bytes: 400),
                                        .file("recent.jpg", modifiedAt: fixtureDate(hoursAgo: 2), bytes: 400),
                                      ])

        let result = try fixture.collector.sweep()

        XCTAssertEqual(fixture.storage.removedURLs.map(\.lastPathComponent), ["old-a.jpg"])
        XCTAssertEqual(result.freedBytes, 400)
        XCTAssertEqual(result.remainingBytes, 800)
    }

    func testSweepKeepsFilesInsideSafetyFloorEvenWhenTotalSizeRemainsOverCap() throws {
        let fixture = UploadGCFixture(configuration: BridgeUploadGarbageCollectorConfiguration(retentionInterval: 7 * 24 * 60 * 60,
                                                                                              maximumTotalBytes: 1_000,
                                                                                              safetyFloorInterval: 24 * 60 * 60),
                                      files: [
                                        .file("recent-a.jpg", modifiedAt: fixtureDate(hoursAgo: 3), bytes: 700),
                                        .file("recent-b.jpg", modifiedAt: fixtureDate(hoursAgo: 2), bytes: 700),
                                      ])

        let result = try fixture.collector.sweep()

        XCTAssertEqual(fixture.storage.removedURLs, [])
        XCTAssertEqual(result.remainingBytes, 1_400)
    }
}

private final class UploadGCFixture {
    let uploadDirectory = URL(fileURLWithPath: "/tmp/uploads", isDirectory: true)
    let storage: FakeUploadStorage
    let clock: FixedUploadClock
    let collector: BridgeUploadGarbageCollector

    init(configuration: BridgeUploadGarbageCollectorConfiguration = BridgeUploadGarbageCollectorConfiguration(),
         files: [BridgeUploadFileRecord]) {
        storage = FakeUploadStorage(files: files)
        clock = FixedUploadClock(now: fixtureDate(0))
        collector = BridgeUploadGarbageCollector(uploadDirectory: uploadDirectory,
                                                 configuration: configuration,
                                                 storage: storage,
                                                 clock: clock,
                                                 queue: DispatchQueue(label: "BridgeUploadGarbageCollectorTests"))
    }
}

private final class FakeUploadStorage: BridgeUploadStorageManaging {
    private(set) var files: [BridgeUploadFileRecord]
    private(set) var removedURLs = [URL]()

    init(files: [BridgeUploadFileRecord]) {
        self.files = files
    }

    func uploadFiles(in directory: URL) throws -> [BridgeUploadFileRecord] {
        files
    }

    func removeUploadFile(at url: URL) throws {
        removedURLs.append(url)
        files.removeAll { $0.url == url }
    }
}

private struct FixedUploadClock: BridgeUploadClock {
    let now: Date
}

private func fixtureDate(_ seconds: TimeInterval) -> Date {
    Date(timeIntervalSince1970: 1_775_000_000 + seconds)
}

private func fixtureDate(daysAgo: TimeInterval) -> Date {
    fixtureDate(0).addingTimeInterval(-daysAgo * 24 * 60 * 60)
}

private func fixtureDate(hoursAgo: TimeInterval) -> Date {
    fixtureDate(0).addingTimeInterval(-hoursAgo * 60 * 60)
}

private extension BridgeUploadFileRecord {
    static func file(_ name: String, modifiedAt: Date, bytes: Int64) -> BridgeUploadFileRecord {
        BridgeUploadFileRecord(url: URL(fileURLWithPath: "/tmp/uploads", isDirectory: true).appendingPathComponent(name),
                               modifiedAt: modifiedAt,
                               byteCount: bytes)
    }
}
