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

    func testAppendImmediatelyFollowedByDeleteDrainsFinalCompleteLine() throws {
        let fileURL = try writeTestFile()
        let queue = DispatchQueue(label: "JSONLFileTailerTests.append-delete")
        let finalLineExpectation = expectation(description: "final line delivered")
        let invalidationExpectation = expectation(description: "source invalidated")
        var captured = [String]()
        let tailer = JSONLFileTailer(fileURL: fileURL,
                                     queue: queue,
                                     bootstrapLineLimit: 2,
                                     lineHandler: { _, line in
                                         captured.append(line)
                                         if line == "five" {
                                             finalLineExpectation.fulfill()
                                         }
                                     },
                                     invalidationHandler: {
                                         invalidationExpectation.fulfill()
                                     })

        try tailer.start()
        let handle = try FileHandle(forWritingTo: fileURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("five\n".utf8))
        try handle.close()
        try FileManager.default.removeItem(at: fileURL)

        wait(for: [finalLineExpectation, invalidationExpectation], timeout: 2)
        tailer.stop()
        XCTAssertEqual(captured.suffix(3), ["three", "four", "five"])
    }

    func testInvalidUTF8RecordsDeliverAfterSourceFence() throws {
        var data = Data("one\n".utf8)
        data.append(contentsOf: [0xff, 0x0a])
        data.append(Data("three\n".utf8))
        let fileURL = try writeFile(data: data)
        let queue = DispatchQueue(label: "JSONLFileTailerTests.invalid-utf8")
        let appendedInvalidExpectation = expectation(description: "appended invalid record delivered")
        let appendedLineExpectation = expectation(description: "line after invalid record delivered")
        var captured = [(Int, String)]()
        var invalidOffsets = [Int]()
        let tailer = JSONLFileTailer(fileURL: fileURL,
                                     queue: queue,
                                     bootstrapLineLimit: 3,
                                     lineHandler: { offset, line in
                                         captured.append((offset, line))
                                         if line == "four" {
                                             appendedLineExpectation.fulfill()
                                         }
                                     },
                                     invalidUTF8Handler: { offset in
                                         invalidOffsets.append(offset)
                                         if invalidOffsets.count == 2 {
                                             appendedInvalidExpectation.fulfill()
                                         }
                                     },
                                     invalidationHandler: {})

        try tailer.start()
        let handle = try FileHandle(forWritingTo: fileURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([0xfe, 0x0a]))
        try handle.write(contentsOf: Data("four\n".utf8))
        try handle.close()

        wait(for: [appendedInvalidExpectation, appendedLineExpectation], timeout: 2)
        tailer.stop()
        XCTAssertEqual(captured.map(\.1), ["one", "three", "four"])
        XCTAssertEqual(captured.map(\.0), [0, 6, 14])
        XCTAssertEqual(invalidOffsets, [4, 12])
    }

    func testBackfillDoesNotDeliverInvalidUTF8BeforeSourceFence() throws {
        var data = Data("one\n".utf8)
        data.append(contentsOf: [0xff, 0x0a])
        data.append(Data("two\nthree\nfour\n".utf8))
        let fileURL = try writeFile(data: data)
        let queue = DispatchQueue(label: "JSONLFileTailerTests.invalid-fence")
        var captured = [String]()
        var invalidOffsets = [Int]()
        let tailer = JSONLFileTailer(fileURL: fileURL,
                                     queue: queue,
                                     bootstrapLineLimit: 2,
                                     lineHandler: { _, line in captured.append(line) },
                                     invalidUTF8Handler: { invalidOffsets.append($0) },
                                     invalidationHandler: {})
        try tailer.start()
        defer { tailer.stop() }
        tailer.backfillAfterReadForTesting = {
            try! Data("replacement-one\nreplacement-two\n".utf8)
                .write(to: fileURL, options: .atomic)
        }

        XCTAssertThrowsError(try tailer.backfill(beforeOffset: 10, limit: 3))
        XCTAssertEqual(captured, ["three", "four"])
        XCTAssertTrue(invalidOffsets.isEmpty,
                      "records rejected by the post-read source fence must have no side effects")
    }

    func testOpenedSourceIdentityStaysBoundToActiveFileDescriptor() throws {
        let fileURL = try writeTestFile()
        let queue = DispatchQueue(label: "JSONLFileTailerTests.source-identity")
        let tailer = JSONLFileTailer(fileURL: fileURL,
                                     queue: queue,
                                     bootstrapLineLimit: 2,
                                     lineHandler: { _, _ in },
                                     invalidationHandler: {})

        try tailer.start()
        defer { tailer.stop() }
        let openedIdentity = try XCTUnwrap(tailer.openedSourceIdentity)

        queue.suspend()
        defer { queue.resume() }
        try "replacement\n".write(to: fileURL, atomically: true, encoding: .utf8)

        XCTAssertEqual(tailer.openedSourceIdentity, openedIdentity)
    }

    func testBackfillRejectsSamePathReplacementAndTruncationBeforeCallbacks() throws {
        do {
            let fileURL = try writeTestFile()
            let queue = DispatchQueue(label: "JSONLFileTailerTests.replaced-source")
            var captured = [String]()
            let tailer = JSONLFileTailer(fileURL: fileURL,
                                         queue: queue,
                                         bootstrapLineLimit: 2,
                                         lineHandler: { _, line in captured.append(line) },
                                         invalidationHandler: {})
            try tailer.start()
            defer { tailer.stop() }
            queue.suspend()
            defer { queue.resume() }

            try "replacement-one\nreplacement-two\n".write(to: fileURL,
                                                               atomically: true,
                                                               encoding: .utf8)

            XCTAssertThrowsError(try tailer.backfill(beforeOffset: 8, limit: 2))
            XCTAssertEqual(captured, ["three", "four"])
        }

        do {
            let fileURL = try writeTestFile()
            let queue = DispatchQueue(label: "JSONLFileTailerTests.truncated-source")
            var captured = [String]()
            let tailer = JSONLFileTailer(fileURL: fileURL,
                                         queue: queue,
                                         bootstrapLineLimit: 2,
                                         lineHandler: { _, line in captured.append(line) },
                                         invalidationHandler: {})
            try tailer.start()
            defer { tailer.stop() }
            queue.suspend()
            defer { queue.resume() }
            let handle = try FileHandle(forWritingTo: fileURL)
            try handle.truncate(atOffset: 4)
            try handle.close()

            XCTAssertThrowsError(try tailer.backfill(beforeOffset: 8, limit: 2))
            XCTAssertEqual(captured, ["three", "four"])
        }

        do {
            let fileURL = try writeTestFile()
            let queue = DispatchQueue(label: "JSONLFileTailerTests.truncated-regrown-source")
            var captured = [String]()
            let tailer = JSONLFileTailer(fileURL: fileURL,
                                         queue: queue,
                                         bootstrapLineLimit: 2,
                                         lineHandler: { _, line in captured.append(line) },
                                         invalidationHandler: {})
            try tailer.start()
            defer { tailer.stop() }
            queue.suspend()
            defer { queue.resume() }
            let handle = try FileHandle(forWritingTo: fileURL)
            try handle.truncate(atOffset: 0)
            try handle.write(contentsOf: Data("replacement-one\nreplacement-two\n".utf8))
            try handle.close()

            XCTAssertThrowsError(try tailer.backfill(beforeOffset: 8, limit: 2))
            XCTAssertEqual(captured, ["three", "four"])
        }
    }

    func testStartCriticalSectionRunsOnTailerQueue() throws {
        let fileURL = try writeTestFile()
        let queue = DispatchQueue(label: "JSONLFileTailerTests.start-queue")
        var captured = [String]()
        let tailer = JSONLFileTailer(fileURL: fileURL,
                                     queue: queue,
                                     bootstrapLineLimit: 2,
                                     lineHandler: { _, line in captured.append(line) },
                                     invalidationHandler: {})
        var hookRanOnTailerQueue: Bool?
        tailer.afterInitialFrontierHookForTesting = { [unowned tailer] in
            // Queue-specific evidence, not timing: the startup critical
            // section must already be executing on the tailer queue here.
            hookRanOnTailerQueue = tailer.isOnTailerQueue
            let handle = try? FileHandle(forWritingTo: fileURL)
            try? handle?.seekToEnd()
            try? handle?.write(contentsOf: Data("five\n".utf8))
            try? handle?.close()
        }
        try tailer.start()
        XCTAssertEqual(hookRanOnTailerQueue, true,
                       "the startup critical section must run on the tailer queue")

        // The suffix appended at the hook races the armed vnode watcher;
        // once the watcher settles it must have been delivered exactly once.
        let settled = expectation(description: "watcher settled")
        queue.async { settled.fulfill() }
        wait(for: [settled], timeout: 2.0)
        tailer.stop()
        XCTAssertEqual(captured.filter { $0 == "five" }.count, 1,
                       "the hook-time suffix must deliver exactly once, got \(captured)")
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
        try writeFile(data: Data(contents.utf8))
    }

    private func writeFile(data: Data) throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("events.jsonl")
        try data.write(to: fileURL, options: .atomic)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return fileURL
    }
}
