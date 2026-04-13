import XCTest
@testable import RemoteBridge

final class JSONLFileReaderTests: XCTestCase {
    func testOffsetBasedSequencesRemainOrderedAcrossBackfillAndLiveAppend() {
        let olderSeq = transcriptEventSequence(lineOffset: 128, ordinal: 0)
        let newerSeq = transcriptEventSequence(lineOffset: 4096, ordinal: 0)
        let newestSeq = transcriptEventSequence(lineOffset: 8192, ordinal: 3)

        XCTAssertLessThan(olderSeq, newerSeq)
        XCTAssertLessThan(newerSeq, newestSeq)
        XCTAssertEqual(transcriptLineOffset(for: olderSeq), 128)
        XCTAssertEqual(transcriptLineOffset(for: newerSeq), 4096)
        XCTAssertEqual(transcriptLineOffset(for: newestSeq), 8192)
    }

    func testReadTailReturnsLatestLinesWithOffsets() throws {
        let fileURL = try writeJSONLFile(contents: "a\nb\nc\n")
        let lines = try JSONLFileReader.readTail(fileURL: fileURL, limit: 2)

        XCTAssertEqual(lines.map(\.line), ["b", "c"])
        XCTAssertEqual(lines.map(\.offset), [2, 4])
    }

    func testReadTailReturnsLatestSliceForLargeFile() throws {
        let contents = (0..<5000)
            .map { "line-\($0)" }
            .joined(separator: "\n") + "\n"
        let fileURL = try writeJSONLFile(contents: contents)

        let lines = try JSONLFileReader.readTail(fileURL: fileURL, limit: 5)

        XCTAssertEqual(lines.count, 5)
        XCTAssertEqual(lines.map(\.line), ["line-4995", "line-4996", "line-4997", "line-4998", "line-4999"])
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
