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

    func testPartialRecordAtStartupIsReassembledWithLaterSuffix() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("events.jsonl")
        // "one\n" is complete; "par" is an unterminated record at startup.
        try "one\npar".write(to: fileURL, atomically: false, encoding: .utf8)

        let queue = DispatchQueue(label: "JSONLFileTailerTests.partial")
        let reassembled = expectation(description: "partial record reassembled")
        var captured = [(Int, String)]()
        let tailer = JSONLFileTailer(fileURL: fileURL,
                                     queue: queue,
                                     bootstrapLineLimit: 10,
                                     lineHandler: { offset, line in
                                         captured.append((offset, line))
                                         if line.hasSuffix("tial") {
                                             reassembled.fulfill()
                                         }
                                     },
                                     invalidationHandler: {})

        try tailer.start()
        XCTAssertEqual(captured.map(\.1), ["one"],
                       "bootstrap must publish only complete records, never the partial")

        let handle = try FileHandle(forWritingTo: fileURL)
        try handle.seekToEnd()
        handle.write(Data("tial\n".utf8))
        try handle.close()

        wait(for: [reassembled], timeout: 2.0)
        tailer.stop()

        XCTAssertEqual(captured.map(\.1), ["one", "partial"],
                       "the pre-EOF fragment must be reassembled with its later suffix exactly once")
        XCTAssertEqual(captured.map(\.0), [0, 4],
                       "the reassembled record must carry the fragment's original offset")
    }

    func testPartialMultibyteUTF8SplitAcrossStartupIsReassembled() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("events.jsonl")
        // “圖” is E5 9C 96; split after its first byte at startup EOF.
        let fullLine = Data("圖片\n".utf8)
        var initial = Data("ok\n".utf8)
        initial.append(fullLine.prefix(1))
        try initial.write(to: fileURL)

        let queue = DispatchQueue(label: "JSONLFileTailerTests.multibyte")
        let reassembled = expectation(description: "multibyte record reassembled")
        var captured = [(Int, String)]()
        let tailer = JSONLFileTailer(fileURL: fileURL,
                                     queue: queue,
                                     bootstrapLineLimit: 10,
                                     lineHandler: { offset, line in
                                         captured.append((offset, line))
                                         if line == "圖片" {
                                             reassembled.fulfill()
                                         }
                                     },
                                     invalidationHandler: {})

        try tailer.start()
        XCTAssertEqual(captured.map(\.1), ["ok"])

        let handle = try FileHandle(forWritingTo: fileURL)
        try handle.seekToEnd()
        handle.write(fullLine.dropFirst(1))
        try handle.close()

        wait(for: [reassembled], timeout: 2.0)
        tailer.stop()

        XCTAssertEqual(captured.map(\.1), ["ok", "圖片"],
                       "a code point split at the startup EOF must decode once reassembled")
        XCTAssertEqual(captured.map(\.0), [0, 3])
    }

    func testPartialLargerThanOneScanChunkIsFullyReassembled() throws {
        // The partial fragment exceeds the 8192-byte backward-scan chunk:
        // the seed must walk multiple chunks to the last newline, not just
        // read the final block.
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("events.jsonl")
        let longPrefix = String(repeating: "x", count: 20_000)
        try ("head\n" + longPrefix).write(to: fileURL, atomically: false, encoding: .utf8)

        let queue = DispatchQueue(label: "JSONLFileTailerTests.large-partial")
        let reassembled = expectation(description: "large partial reassembled")
        var captured = [(Int, String)]()
        let tailer = JSONLFileTailer(fileURL: fileURL,
                                     queue: queue,
                                     bootstrapLineLimit: 10,
                                     lineHandler: { offset, line in
                                         captured.append((offset, line))
                                         if line.hasSuffix("END") {
                                             reassembled.fulfill()
                                         }
                                     },
                                     invalidationHandler: {})

        try tailer.start()
        XCTAssertEqual(captured.map(\.1), ["head"])

        let handle = try FileHandle(forWritingTo: fileURL)
        try handle.seekToEnd()
        handle.write(Data("END\n".utf8))
        try handle.close()

        wait(for: [reassembled], timeout: 2.0)
        tailer.stop()

        XCTAssertEqual(captured.count, 2)
        XCTAssertEqual(captured.last?.1, longPrefix + "END",
                       "the multi-chunk fragment must reassemble in full")
        XCTAssertEqual(captured.last?.0, 5)
    }

    func testSuffixAppendedDuringStartupWindowIsStillReassembledOnce() throws {
        // Deterministic race: the suffix lands AFTER the initial frontier is
        // fixed but BEFORE the seed/drain — the serialized startup must
        // still publish exactly one reassembled record at the original
        // offset, never a suffix-only or duplicate record.
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("events.jsonl")
        try "one\npar".write(to: fileURL, atomically: false, encoding: .utf8)

        let queue = DispatchQueue(label: "JSONLFileTailerTests.startup-race")
        var captured = [(Int, String)]()
        let tailer = JSONLFileTailer(fileURL: fileURL,
                                     queue: queue,
                                     bootstrapLineLimit: 10,
                                     lineHandler: { offset, line in
                                         captured.append((offset, line))
                                     },
                                     invalidationHandler: {})
        tailer.afterInitialFrontierHookForTesting = {
            guard let handle = try? FileHandle(forWritingTo: fileURL) else {
                return XCTFail("could not append during the startup window")
            }
            try? handle.seekToEnd()
            handle.write(Data("tial\n".utf8))
            try? handle.close()
        }

        try tailer.start()
        // The suffix was on disk before the startup drain, so the record is
        // complete by the time start() returns.
        queue.sync {}
        tailer.stop()

        XCTAssertEqual(captured.map(\.1), ["one", "partial"],
                       "the startup-window suffix must complete the seeded fragment exactly once")
        XCTAssertEqual(captured.map(\.0), [0, 4])
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
