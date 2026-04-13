import XCTest
@testable import RemoteBridge

final class JSONLFileTailerTests: XCTestCase {
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
}
