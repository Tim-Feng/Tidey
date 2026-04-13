import Foundation

let transcriptBootstrapLineLimit = 500
let transcriptLineSequenceMultiplier = 4096
let transcriptSessionStartedSequence = 0

func transcriptEventSequence(lineOffset: Int, ordinal: Int) -> Int {
    precondition(lineOffset >= 0, "lineOffset must be non-negative")
    precondition(ordinal >= 0 && ordinal < transcriptLineSequenceMultiplier,
                 "ordinal must fit within transcriptLineSequenceMultiplier")
    return (lineOffset * transcriptLineSequenceMultiplier) + ordinal + 1
}

func transcriptLineOffset(for sequence: Int) -> Int {
    guard sequence > transcriptSessionStartedSequence else {
        return 0
    }
    return (sequence - 1) / transcriptLineSequenceMultiplier
}

enum JSONLFileReader {
    private static let chunkSize = 64 * 1024

    static func readTail(fileURL: URL, limit: Int) throws -> [(offset: Int, line: String)] {
        try readLines(fileURL: fileURL, beforeOffsetExclusive: nil, limit: limit)
    }

    static func readBefore(fileURL: URL,
                           beforeOffset: Int,
                           limit: Int) throws -> [(offset: Int, line: String)] {
        try readLines(fileURL: fileURL, beforeOffsetExclusive: beforeOffset, limit: limit)
    }

    private static func readLines(fileURL: URL,
                                  beforeOffsetExclusive: Int?,
                                  limit: Int) throws -> [(offset: Int, line: String)] {
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

        return parseLines(buffer, baseOffset: parseBaseOffset, limit: limit)
    }

    private static func parseLines(_ data: Data,
                                   baseOffset: Int,
                                   limit: Int) -> [(offset: Int, line: String)] {
        guard !data.isEmpty else {
            return []
        }

        var lines = [(offset: Int, line: String)]()
        var lineStartIndex = data.startIndex

        for index in data.indices where data[index] == 0x0A {
            let lineData = data[lineStartIndex..<index]
            if !lineData.isEmpty,
               let line = String(data: lineData, encoding: .utf8) {
                let lineOffset = baseOffset + data.distance(from: data.startIndex, to: lineStartIndex)
                lines.append((offset: lineOffset, line: line))
            }
            lineStartIndex = data.index(after: index)
        }

        if lines.count > limit {
            return Array(lines.suffix(limit))
        }
        return lines
    }
}
