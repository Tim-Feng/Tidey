import Foundation

let transcriptBootstrapLineLimit = 500
let transcriptLineSequenceMultiplier = 4096
let transcriptSessionStartedSequence = 0

struct TranscriptEventPosition: Equatable, Sendable, Comparable {
    let lineOffset: Int
    let ordinal: Int

    // Raw-position order is lexicographic (lineOffset, ordinal) — never
    // derived from public sequence arithmetic.
    static func < (lhs: TranscriptEventPosition, rhs: TranscriptEventPosition) -> Bool {
        (lhs.lineOffset, lhs.ordinal) < (rhs.lineOffset, rhs.ordinal)
    }
}

func transcriptEventSequence(lineOffset: Int, ordinal: Int) -> Int {
    precondition(lineOffset >= 0, "lineOffset must be non-negative")
    precondition(ordinal >= 0 && ordinal < transcriptLineSequenceMultiplier,
                 "ordinal must fit within transcriptLineSequenceMultiplier")
    return (lineOffset * transcriptLineSequenceMultiplier) + ordinal + 1
}

func transcriptLineOffset(for sequence: Int) -> Int {
    transcriptEventPosition(for: sequence).lineOffset
}

func transcriptEventPosition(for sequence: Int) -> TranscriptEventPosition {
    guard sequence > transcriptSessionStartedSequence else {
        return TranscriptEventPosition(lineOffset: 0, ordinal: 0)
    }
    let zeroBasedSequence = sequence - 1
    return TranscriptEventPosition(
        lineOffset: zeroBasedSequence / transcriptLineSequenceMultiplier,
        ordinal: zeroBasedSequence % transcriptLineSequenceMultiplier)
}

enum JSONLFileRecord: Equatable, Sendable {
    case line(offset: Int, value: String)
    case invalidUTF8(offset: Int)

    var offset: Int {
        switch self {
        case .line(let offset, _), .invalidUTF8(let offset):
            return offset
        }
    }
}

// One backward read with its ACTUAL raw scan boundary. The metadata comes
// from the reader's own scan/selection state, never from guessing off the
// first non-blank record: blank lines inside the covered range yield no
// record but ARE covered; records dropped by `limit` are NOT covered, so a
// truncated page's boundary is the first RETAINED record.
struct JSONLFileReadPage: Sendable {
    let records: [JSONLFileRecord]
    // Oldest byte offset this page's selection fully covers.
    let minimumRawOffset: Int
    // The reader's ACTUAL exclusive upper bound for this read — the clamped
    // end offset (after any anchor-line extension). This is the authority
    // for interval-connectivity decisions; callers must not re-derive it
    // from request parameters or the includeAnchorLine flag.
    let maximumRawOffsetExclusive: Int
    // True only when the covered range extends to byte 0 (leading blanks
    // included) — a first-record offset above 0 does not contradict it.
    let reachedSourceStart: Bool
}

enum JSONLFileReader {
    private static let chunkSize = 64 * 1024

    static func readTail(fileURL: URL, limit: Int) throws -> [(offset: Int, line: String)] {
        try readTailRecords(fileURL: fileURL, limit: limit).compactMap { record in
            guard case .line(let offset, let value) = record else { return nil }
            return (offset: offset, line: value)
        }
    }

    static func readTailRecords(fileURL: URL, limit: Int) throws -> [JSONLFileRecord] {
        try readTailPage(fileURL: fileURL, limit: limit).records
    }

    static func readTailPage(fileURL: URL, limit: Int) throws -> JSONLFileReadPage {
        try readPage(fileURL: fileURL, beforeOffsetExclusive: nil, limit: limit)
    }

    static func readBeforePage(fileURL: URL,
                               beforeOffset: Int,
                               limit: Int,
                               includeAnchorLine: Bool = false) throws -> JSONLFileReadPage {
        let endOffset = includeAnchorLine
            ? try offsetAfterLine(fileURL: fileURL, lineOffset: beforeOffset)
            : beforeOffset
        return try readPage(fileURL: fileURL,
                            beforeOffsetExclusive: endOffset,
                            limit: limit)
    }

    static func readBefore(fileURL: URL,
                           beforeOffset: Int,
                           limit: Int,
                           includeAnchorLine: Bool = false) throws
        -> [(offset: Int, line: String)] {
        try readBeforeRecords(fileURL: fileURL,
                              beforeOffset: beforeOffset,
                              limit: limit,
                              includeAnchorLine: includeAnchorLine).compactMap { record in
            guard case .line(let offset, let value) = record else { return nil }
            return (offset: offset, line: value)
        }
    }

    static func readBeforeRecords(fileURL: URL,
                                  beforeOffset: Int,
                                  limit: Int,
                                  includeAnchorLine: Bool = false) throws -> [JSONLFileRecord] {
        try readBeforePage(fileURL: fileURL,
                           beforeOffset: beforeOffset,
                           limit: limit,
                           includeAnchorLine: includeAnchorLine).records
    }

    private static func offsetAfterLine(fileURL: URL, lineOffset: Int) throws -> Int {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        let fileSize = try Int(handle.seekToEnd())
        var scanOffset = min(max(lineOffset, 0), fileSize)
        try handle.seek(toOffset: UInt64(scanOffset))
        while scanOffset < fileSize,
              let chunk = try handle.read(upToCount: min(chunkSize, fileSize - scanOffset)),
              chunk.isEmpty == false {
            if let newlineIndex = chunk.firstIndex(of: 0x0A) {
                return scanOffset
                    + chunk.distance(from: chunk.startIndex, to: newlineIndex)
                    + 1
            }
            scanOffset += chunk.count
        }
        return fileSize
    }

    private static func readPage(fileURL: URL,
                                 beforeOffsetExclusive: Int?,
                                 limit: Int) throws -> JSONLFileReadPage {
        guard limit > 0 else {
            // Nothing was scanned: claim no coverage (an empty interval).
            let clamped = max(beforeOffsetExclusive ?? 0, 0)
            return JSONLFileReadPage(records: [],
                                     minimumRawOffset: clamped,
                                     maximumRawOffsetExclusive: clamped,
                                     reachedSourceStart: false)
        }

        let handle = try FileHandle(forReadingFrom: fileURL)
        defer {
            try? handle.close()
        }

        let fileSize = try Int(handle.seekToEnd())
        let endOffset = min(max(beforeOffsetExclusive ?? fileSize, 0), fileSize)
        guard endOffset > 0 else {
            // The requested range already sits at byte 0.
            return JSONLFileReadPage(records: [],
                                     minimumRawOffset: 0,
                                     maximumRawOffsetExclusive: 0,
                                     reachedSourceStart: true)
        }

        var startOffset = endOffset
        var buffer = Data()
        var newlineCount = 0

        while startOffset > 0 && newlineCount <= limit {
            let bytesToRead = min(chunkSize, startOffset)
            startOffset -= bytesToRead
            try handle.seek(toOffset: UInt64(startOffset))
            let chunk = try handle.read(upToCount: bytesToRead) ?? Data()
            buffer.insert(contentsOf: chunk, at: 0)
            newlineCount += chunk.reduce(into: 0) { count, byte in
                if byte == 0x0A {
                    count += 1
                }
            }
        }

        var parseBaseOffset = startOffset
        if startOffset > 0 {
            guard let firstNewlineIndex = buffer.firstIndex(of: 0x0A) else {
                return JSONLFileReadPage(records: [],
                                         minimumRawOffset: endOffset,
                                         maximumRawOffsetExclusive: endOffset,
                                         reachedSourceStart: false)
            }
            let bytesToDrop = buffer.distance(from: buffer.startIndex, to: firstNewlineIndex) + 1
            parseBaseOffset += bytesToDrop
            buffer.removeFirst(bytesToDrop)
        }

        let parsedRecords = parseRecords(buffer, baseOffset: parseBaseOffset)
        if parsedRecords.count > limit {
            // Older records were dropped by the limit: their range is NOT
            // covered, so the boundary is the first RETAINED record.
            let retained = Array(parsedRecords.suffix(limit))
            return JSONLFileReadPage(records: retained,
                                     minimumRawOffset: retained.first?.offset ?? endOffset,
                                     maximumRawOffsetExclusive: endOffset,
                                     reachedSourceStart: false)
        }
        // Every parsed byte from the parse base (blank lines included) is
        // covered; byte 0 was reached only when the scan itself got there.
        return JSONLFileReadPage(records: parsedRecords,
                                 minimumRawOffset: parseBaseOffset,
                                 maximumRawOffsetExclusive: endOffset,
                                 reachedSourceStart: startOffset == 0)
    }

    private static func parseRecords(_ data: Data,
                                     baseOffset: Int) -> [JSONLFileRecord] {
        guard !data.isEmpty else {
            return []
        }

        var records = [JSONLFileRecord]()
        var lineStartIndex = data.startIndex

        for index in data.indices where data[index] == 0x0A {
            let lineData = data[lineStartIndex..<index]
            if !lineData.isEmpty {
                let lineOffset = baseOffset + data.distance(from: data.startIndex, to: lineStartIndex)
                if let line = String(data: lineData, encoding: .utf8) {
                    records.append(.line(offset: lineOffset, value: line))
                } else {
                    records.append(.invalidUTF8(offset: lineOffset))
                }
            }
            lineStartIndex = data.index(after: index)
        }

        return records
    }
}
