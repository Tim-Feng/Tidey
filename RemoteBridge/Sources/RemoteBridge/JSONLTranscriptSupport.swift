import Foundation

let transcriptBootstrapLineLimit = 500
let transcriptLineSequenceMultiplier = 4096
let transcriptSessionStartedSequence = 0

struct TranscriptEventPosition: Equatable, Sendable {
    let lineOffset: Int
    let ordinal: Int
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

enum JSONLFileRecord: Equatable {
    case line(offset: Int, value: String)
    case invalidUTF8(offset: Int)

    var offset: Int {
        switch self {
        case .line(let offset, _), .invalidUTF8(let offset):
            return offset
        }
    }
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
        try readRecords(fileURL: fileURL, beforeOffsetExclusive: nil, limit: limit)
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
        let endOffset = includeAnchorLine
            ? try offsetAfterLine(fileURL: fileURL, lineOffset: beforeOffset)
            : beforeOffset
        return try readRecords(fileURL: fileURL,
                               beforeOffsetExclusive: endOffset,
                               limit: limit)
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

    private static func readRecords(fileURL: URL,
                                    beforeOffsetExclusive: Int?,
                                    limit: Int) throws -> [JSONLFileRecord] {
        guard limit > 0 else {
            return []
        }

        let handle = try FileHandle(forReadingFrom: fileURL)
        defer {
            try? handle.close()
        }

        let fileSize = try Int(handle.seekToEnd())
        let endOffset = min(max(beforeOffsetExclusive ?? fileSize, 0), fileSize)
        guard endOffset > 0 else {
            return []
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
                return []
            }
            let bytesToDrop = buffer.distance(from: buffer.startIndex, to: firstNewlineIndex) + 1
            parseBaseOffset += bytesToDrop
            buffer.removeFirst(bytesToDrop)
        }

        return parseRecords(buffer, baseOffset: parseBaseOffset, limit: limit)
    }

    private static func parseRecords(_ data: Data,
                                     baseOffset: Int,
                                     limit: Int) -> [JSONLFileRecord] {
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

        if records.count > limit {
            return Array(records.suffix(limit))
        }
        return records
    }
}
