import Foundation

struct CodexContextSnapshot: Equatable {
    let timestamp: String
    let tokensInContext: Int
    let contextWindow: Int
    let percentRemaining: Int

    var rawTokensRemaining: Int {
        max(contextWindow - tokensInContext, 0)
    }

    var markdownSummary: String {
        """
        ### Codex Context

        Context window: \(Self.format(tokensInContext)) / \(Self.format(contextWindow)) tokens
        Remaining: \(percentRemaining)% (\(Self.format(rawTokensRemaining)) raw tokens)
        """
    }

    private static func format(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }
}

struct CodexContextSnapshotReader {
    enum Error: Swift.Error, LocalizedError, Equatable {
        case missingTranscriptPath
        case noTokenCount
        case missingContextWindow

        var errorDescription: String? {
            switch self {
            case .missingTranscriptPath:
                return "Codex transcript path is unavailable."
            case .noTokenCount:
                return "Codex transcript does not contain token usage yet."
            case .missingContextWindow:
                return "Codex transcript does not include a model context window."
            }
        }
    }

    private static let baselineTokens = 12_000
    private let tailLineLimit: Int

    init(tailLineLimit: Int = 1_000) {
        self.tailLineLimit = tailLineLimit
    }

    func read(transcriptPath: String?) throws -> CodexContextSnapshot {
        guard let transcriptPath, !transcriptPath.isEmpty else {
            throw Error.missingTranscriptPath
        }
        let url = URL(fileURLWithPath: NSString(string: transcriptPath).expandingTildeInPath)
        let lines = try JSONLFileReader.readTail(fileURL: url, limit: tailLineLimit)
        let decoder = JSONDecoder()

        for line in lines.reversed() {
            guard let data = line.line.data(using: .utf8),
                  let record = try? decoder.decode(CodexRolloutRecord.self, from: data),
                  record.type == "event_msg",
                  record.payload.type == "token_count",
                  let info = record.payload.info else {
                continue
            }
            guard let contextWindow = info.modelContextWindow else {
                throw Error.missingContextWindow
            }
            let tokensInContext = max(info.lastTokenUsage.totalTokens, 0)
            return CodexContextSnapshot(timestamp: record.timestamp,
                                        tokensInContext: tokensInContext,
                                        contextWindow: contextWindow,
                                        percentRemaining: Self.percentRemaining(tokensInContext: tokensInContext,
                                                                                 contextWindow: contextWindow))
        }

        throw Error.noTokenCount
    }

    private static func percentRemaining(tokensInContext: Int, contextWindow: Int) -> Int {
        guard contextWindow > baselineTokens else {
            return 0
        }
        let effectiveWindow = contextWindow - baselineTokens
        let used = max(tokensInContext - baselineTokens, 0)
        let remaining = max(effectiveWindow - used, 0)
        let percent = (Double(remaining) / Double(effectiveWindow)) * 100.0
        return Int(percent.rounded().clamped(to: 0...100))
    }
}

private struct CodexRolloutRecord: Decodable {
    let timestamp: String
    let type: String
    let payload: CodexTokenCountPayload
}

private struct CodexTokenCountPayload: Decodable {
    let type: String
    let info: CodexTokenCountInfo?
}

private struct CodexTokenCountInfo: Decodable {
    let lastTokenUsage: CodexTokenUsage
    let modelContextWindow: Int?

    enum CodingKeys: String, CodingKey {
        case lastTokenUsage = "last_token_usage"
        case modelContextWindow = "model_context_window"
    }
}

private struct CodexTokenUsage: Decodable {
    let totalTokens: Int

    enum CodingKeys: String, CodingKey {
        case totalTokens = "total_tokens"
    }
}

private extension Comparable {
    func clamped(to limits: ClosedRange<Self>) -> Self {
        min(max(self, limits.lowerBound), limits.upperBound)
    }
}
