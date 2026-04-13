import XCTest
@testable import RemoteBridge

final class JSONLFileTailerTests: XCTestCase {
    func testLargeFileBootstrapCapturesOnlyTailWindow() throws {
        let fileURL = try writeLargeTestFile(lineCount: 5000)

        let queue = DispatchQueue(label: "JSONLFileTailerTests.large")
        var captured = [(Int, String)]()
        let tailer = JSONLFileTailer(fileURL: fileURL,
                                     queue: queue,
                                     bootstrapLineLimit: 5,
                                     lineHandler: { offset, line in
                                         captured.append((offset, line))
                                     },
                                     invalidationHandler: {})

        try tailer.start()
        tailer.stop()

        XCTAssertEqual(captured.count, 5)
        XCTAssertEqual(captured.map(\.1), ["line-4995", "line-4996", "line-4997", "line-4998", "line-4999"])
    }

    func testStartBootstrapsFromTailInsteadOfWholeFile() throws {
        let fileURL = try writeTestFile()

        let queue = DispatchQueue(label: "JSONLFileTailerTests")
        var captured = [(Int, String)]()
        let tailer = JSONLFileTailer(fileURL: fileURL,
                                     queue: queue,
                                     bootstrapLineLimit: 2,
                                     lineHandler: { offset, line in
                                         captured.append((offset, line))
                                     },
                                     invalidationHandler: {})

        try tailer.start()
        tailer.stop()

        XCTAssertEqual(captured.map(\.1), ["three", "four"])
        XCTAssertEqual(captured.map(\.0), [8, 14])
    }

    func testBackfillLoadsOlderLinesBeforeCurrentEarliestOffset() throws {
        let fileURL = try writeTestFile()

        let queue = DispatchQueue(label: "JSONLFileTailerTests.backfill")
        var captured = [(Int, String)]()
        let tailer = JSONLFileTailer(fileURL: fileURL,
                                     queue: queue,
                                     bootstrapLineLimit: 2,
                                     lineHandler: { offset, line in
                                         captured.append((offset, line))
                                     },
                                     invalidationHandler: {})

        try tailer.start()
        let didBackfill = try tailer.backfill(beforeOffset: 8, limit: 2)
        tailer.stop()

        XCTAssertTrue(didBackfill)
        XCTAssertEqual(captured.map(\.1), ["three", "four", "one", "two"])
        XCTAssertEqual(Set(captured.map(\.0)), Set([0, 4, 8, 14]))
    }

    func testAppendAfterBootstrapDeliversNewLineWithGreaterOffset() throws {
        let fileURL = try writeLargeTestFile(lineCount: 100)

        let queue = DispatchQueue(label: "JSONLFileTailerTests.append")
        let appendExpectation = expectation(description: "append delivered")
        var captured = [(Int, String)]()
        let tailer = JSONLFileTailer(fileURL: fileURL,
                                     queue: queue,
                                     bootstrapLineLimit: 3,
                                     lineHandler: { offset, line in
                                         captured.append((offset, line))
                                         if line == "line-100" {
                                             appendExpectation.fulfill()
                                         }
                                     },
                                     invalidationHandler: {})

        try tailer.start()
        let bootstrapOffsets = captured.map(\.0)

        let handle = try FileHandle(forWritingTo: fileURL)
        try handle.seekToEnd()
        handle.write(Data("line-100\n".utf8))
        try handle.close()

        wait(for: [appendExpectation], timeout: 2.0)
        tailer.stop()

        XCTAssertEqual(captured.suffix(4).map(\.1), ["line-97", "line-98", "line-99", "line-100"])
        XCTAssertGreaterThan(captured.last?.0 ?? 0, bootstrapOffsets.max() ?? 0)
    }

    private func writeTestFile() throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("events.jsonl")
        try "one\ntwo\nthree\nfour\n".write(to: fileURL, atomically: true, encoding: .utf8)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return fileURL
    }

    private func writeLargeTestFile(lineCount: Int) throws -> URL {
        let contents = (0..<lineCount)
            .map { "line-\($0)" }
            .joined(separator: "\n") + "\n"
        return try writeFile(contents: contents)
    }

    private func writeFile(contents: String) throws -> URL {
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
