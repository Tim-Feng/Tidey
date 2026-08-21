import Foundation

struct TideyBrowserTransferStartRequest: Equatable {
    let target: TideyBrowserAutomationElementReference
    let archiveRoot: String
    let expectedVolumeUUID: String
    let destinationRelativePath: String
    let resumeOffset: Int
    let ifRange: String?
    let pauseAfterBytes: Int?
}

enum TideyBrowserTransferResponseDecision: Equatable {
    case fresh(expectedTotal: Int?)
    case resumed(expectedTotal: Int?)
    case rangeNotSatisfiable(remoteTotal: Int?)
}

enum TideyBrowserTransferValidationError: Error, Equatable {
    case invalidSource
    case invalidDestination
    case invalidResponse
}

enum TideyBrowserTransferRouteValidator {
    static func sourceURL(pageURL: URL, href: String) throws -> URL {
        guard isOfficialVaultURL(pageURL),
              let resolved = URL(string: href, relativeTo: pageURL)?.absoluteURL,
              isOfficialVaultURL(resolved),
              sameOrigin(pageURL, resolved),
              let components = URLComponents(url: resolved, resolvingAgainstBaseURL: false),
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil else {
            throw TideyBrowserTransferValidationError.invalidSource
        }
        return resolved
    }

    static func destinationComponents(_ relativePath: String) throws -> [String] {
        guard !relativePath.isEmpty,
              !relativePath.hasPrefix("/"),
              !relativePath.contains("\\"),
              !relativePath.contains("\0"),
              relativePath.hasSuffix(".partial") else {
            throw TideyBrowserTransferValidationError.invalidDestination
        }
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw TideyBrowserTransferValidationError.invalidDestination
        }
        return components
    }

    private static func isOfficialVaultURL(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              components.host?.lowercased() == "studio.blender.org",
              components.port == nil else {
            return false
        }
        let decodedPath = components.percentEncodedPath.removingPercentEncoding ?? ""
        let pathComponents = decodedPath.split(separator: "/", omittingEmptySubsequences: false)
        guard !pathComponents.contains(where: { $0 == "." || $0 == ".." }) else {
            return false
        }
        return decodedPath == "/vault/browse" || decodedPath.hasPrefix("/vault/browse/")
    }

    private static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        let left = URLComponents(url: lhs, resolvingAgainstBaseURL: false)
        let right = URLComponents(url: rhs, resolvingAgainstBaseURL: false)
        return left?.scheme?.lowercased() == right?.scheme?.lowercased() &&
            left?.host?.lowercased() == right?.host?.lowercased() &&
            left?.port == right?.port
    }
}

enum TideyBrowserTransferResponsePolicy {
    static func evaluate(statusCode: Int,
                         resumeOffset: Int,
                         headers: [String: String]) throws -> TideyBrowserTransferResponseDecision {
        guard resumeOffset >= 0 else {
            throw TideyBrowserTransferValidationError.invalidResponse
        }
        switch statusCode {
        case 200:
            guard resumeOffset == 0 else {
                throw TideyBrowserTransferValidationError.invalidResponse
            }
            return .fresh(expectedTotal: positiveInteger(header("Content-Length", in: headers)))
        case 206:
            guard let rawRange = header("Content-Range", in: headers),
                  let range = parseSatisfiedContentRange(rawRange),
                  range.start == resumeOffset else {
                throw TideyBrowserTransferValidationError.invalidResponse
            }
            return .resumed(expectedTotal: range.total)
        case 416:
            return .rangeNotSatisfiable(
                remoteTotal: parseUnsatisfiedContentRange(header("Content-Range", in: headers))
            )
        default:
            throw TideyBrowserTransferValidationError.invalidResponse
        }
    }

    private static func header(_ name: String, in headers: [String: String]) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    private static func positiveInteger(_ raw: String?) -> Int? {
        guard let raw, let value = Int(raw), value >= 0 else {
            return nil
        }
        return value
    }

    private static func parseSatisfiedContentRange(_ raw: String) -> (start: Int, total: Int?)? {
        let parts = raw.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2, parts[0].lowercased() == "bytes" else {
            return nil
        }
        let rangeAndTotal = parts[1].split(separator: "/", maxSplits: 1).map(String.init)
        let bounds = rangeAndTotal.first?.split(separator: "-", maxSplits: 1).map(String.init) ?? []
        guard rangeAndTotal.count == 2,
              bounds.count == 2,
              let start = Int(bounds[0]),
              let end = Int(bounds[1]),
              start >= 0,
              end >= start else {
            return nil
        }
        let total = rangeAndTotal[1] == "*" ? nil : positiveInteger(rangeAndTotal[1])
        guard rangeAndTotal[1] == "*" || total != nil else {
            return nil
        }
        return (start, total)
    }

    private static func parseUnsatisfiedContentRange(_ raw: String?) -> Int? {
        guard let raw else { return nil }
        let normalized = raw.lowercased()
        guard normalized.hasPrefix("bytes */") else { return nil }
        return positiveInteger(String(normalized.dropFirst("bytes */".count)))
    }
}

enum TideyBrowserTransferRedaction {
    static func url(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return "redacted-url"
        }
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        return components.string ?? "redacted-url"
    }

    static func message(_ message: String) -> String {
        let lowercased = message.lowercased()
        let sensitiveMarkers = ["authorization", "bearer ", "cookie", "token=", "signature=", "x-amz-"]
        guard !sensitiveMarkers.contains(where: lowercased.contains) else {
            return "Transfer failed"
        }
        return String(message
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .prefix(240))
    }
}
