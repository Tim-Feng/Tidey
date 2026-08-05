import Foundation
import XCTest
@testable import RemoteBridge

final class TerminalByteFileTailerTests: XCTestCase {
    private final class DataBox: @unchecked Sendable {
        private let lock = NSLock()
        private var chunks = [Data]()

        func append(_ data: Data) {
            lock.lock()
            chunks.append(data)
            lock.unlock()
        }

        var combined: Data {
            lock.lock()
            defer { lock.unlock() }
            return chunks.reduce(into: Data()) { result, chunk in
                result.append(chunk)
            }
        }

        var strings: [String] {
            lock.lock()
            defer { lock.unlock() }
            return chunks.compactMap { String(data: $0, encoding: .utf8) }
        }
    }

    func testPrepareOpensDormantWithoutConsuming() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TerminalByteFileTailerTests-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let fileURL = directory.appendingPathComponent("terminal.bytes")
        XCTAssertTrue(FileManager.default.createFile(atPath: fileURL.path,
                                                     contents: Data()))
        let received = DataBox()
        let tailer = TerminalByteFileTailer(
            url: fileURL,
            queue: DispatchQueue(label: "TerminalByteFileTailerTests.prepare"),
            handler: { received.append($0) }
        )
        defer { tailer.stop() }

        try tailer.prepare()
        try append(Data("pending".utf8), to: fileURL)
        tailer.processFileEventForTesting()

        XCTAssertEqual(received.combined, Data(),
                       "preparation must leave durable pending bytes unread until activation")
    }

    func testActivateDrainsDurablePendingBytesInFIFOOrder() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TerminalByteFileTailerTests-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let fileURL = directory.appendingPathComponent("terminal.bytes")
        XCTAssertTrue(FileManager.default.createFile(atPath: fileURL.path,
                                                     contents: Data()))
        let received = DataBox()
        let tailer = TerminalByteFileTailer(
            url: fileURL,
            queue: DispatchQueue(label: "TerminalByteFileTailerTests.activate"),
            handler: { received.append($0) }
        )
        defer { tailer.stop() }

        try tailer.prepare()
        try append(Data("pending-".utf8), to: fileURL)
        tailer.activate()
        tailer.processFileEventForTesting()
        try append(Data("live".utf8), to: fileURL)
        tailer.processFileEventForTesting()

        XCTAssertEqual(received.combined, Data("pending-live".utf8))
        XCTAssertEqual(received.strings, ["pending-", "live"],
                       "activation and later file events must advance one shared FIFO offset")
    }

    func testStopFromDormantPreventsLaterActivation() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TerminalByteFileTailerTests-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let fileURL = directory.appendingPathComponent("terminal.bytes")
        XCTAssertTrue(FileManager.default.createFile(atPath: fileURL.path,
                                                     contents: Data()))
        let received = DataBox()
        let tailer = TerminalByteFileTailer(
            url: fileURL,
            queue: DispatchQueue(label: "TerminalByteFileTailerTests.stop"),
            handler: { received.append($0) }
        )

        try tailer.prepare()
        try append(Data("discarded".utf8), to: fileURL)
        tailer.stop()
        tailer.activate()
        tailer.processFileEventForTesting()

        XCTAssertEqual(received.combined, Data())
    }

    private func append(_ data: Data, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }
}
