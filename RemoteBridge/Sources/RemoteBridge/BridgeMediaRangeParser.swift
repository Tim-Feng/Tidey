import Foundation

enum BridgeMediaRangeSelection: Equatable {
    case full(size: UInt64)
    case partial(range: ClosedRange<UInt64>, size: UInt64)
}

struct BridgeMediaRangeError: Error, Equatable {
    let contentRange: String
}

enum BridgeMediaRangeParser {
    static func parse(_ header: String?, size: UInt64) throws -> BridgeMediaRangeSelection {
        guard let header else {
            return .full(size: size)
        }

        let failure = BridgeMediaRangeError(contentRange: "bytes */\(size)")
        let trimmed = header.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("bytes=") else {
            throw failure
        }

        let specification = String(trimmed.dropFirst("bytes=".count))
        guard !specification.contains(",") else {
            throw failure
        }
        let bounds = specification.split(separator: "-", maxSplits: 2, omittingEmptySubsequences: false)
        guard bounds.count == 2, size > 0 else {
            throw failure
        }

        if bounds[0].isEmpty {
            guard let suffixLength = UInt64(bounds[1]), suffixLength > 0 else {
                throw failure
            }
            let boundedLength = min(suffixLength, size)
            return .partial(range: (size - boundedLength)...(size - 1), size: size)
        }

        guard let start = UInt64(bounds[0]), start < size else {
            throw failure
        }
        if bounds[1].isEmpty {
            return .partial(range: start...(size - 1), size: size)
        }

        guard let requestedEnd = UInt64(bounds[1]), requestedEnd >= start else {
            throw failure
        }
        return .partial(range: start...min(requestedEnd, size - 1), size: size)
    }
}
