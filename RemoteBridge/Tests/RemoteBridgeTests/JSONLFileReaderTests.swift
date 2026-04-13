import XCTest
@testable import RemoteBridge

final class JSONLFileReaderTests: XCTestCase {
    func testReadTailReturnsLatestLinesWithOffsets() throws {
        let fileURL = try writeJSONLFile(contents: "a\nb\nc\n")
        let lines = try JSONLFileReader.readTail(fileURL: fileURL, limit: 2)

        XCTAssertEqual(lines.map(\.line), ["b", "c"])
        XCTAssertEqual(lines.map(\.offset), [2, 4])
    }

    func testReadBeforeReturnsOlderLinesBeforeOffset() throws {
        let fileURL = try writeJSONLFile(contents: "a\nb\nc\nd\n")
        let lines = try JSONLFileReader.readBefore(fileURL: fileURL, beforeOffset: 4, limit: 2)

        XCTAssertEqual(lines.map(\.line), ["a", "b"])
        XCTAssertEqual(lines.map(\.offset), [0, 2])
    }

    private func writeJSONLFile(contents: String) throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("events.jsonl")
        try contents.write(to: fileURL, atomically: true, encoding: .utf8)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return fileURL
    }
}
