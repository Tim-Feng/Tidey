import Foundation

struct TmuxSessionIdentity: Equatable, Hashable, Sendable {
    let sessionID: String
    let sessionName: String
}

enum TmuxTargetSessionResolver {
    static func resolve(
        target: String,
        liveSessions: [TmuxSessionIdentity]
    ) -> TmuxSessionIdentity? {
        let target = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard target.isEmpty == false else {
            return nil
        }

        let sessions = Array(Set(liveSessions))
        if target.hasPrefix("$") {
            let matches = sessions.filter { $0.sessionID == target }
            return matches.count == 1 ? matches[0] : nil
        }

        let exactOnly = target.hasPrefix("=")
        let candidate = exactOnly ? String(target.dropFirst()) : target
        guard candidate.isEmpty == false else {
            return nil
        }

        let exactMatches = sessions.filter { $0.sessionName == candidate }
        if exactMatches.count == 1 {
            return exactMatches[0]
        }
        guard exactMatches.isEmpty, exactOnly == false else {
            return nil
        }

        let prefixMatches = sessions.filter {
            $0.sessionName.hasPrefix(candidate)
        }
        return prefixMatches.count == 1 ? prefixMatches[0] : nil
    }
}
