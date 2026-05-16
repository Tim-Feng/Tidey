import Foundation

struct CodexStatusSnapshot: Equatable {
    let timestamp: String
    let sessionID: String?
    let model: String?
    let reasoningEffort: String?
    let summaryMode: String?
    let cwd: String?
    let approvalPolicy: String?
    let sandboxPolicy: String?
    let tokensInContext: Int
    let contextWindow: Int
    let percentRemaining: Int
    let primaryRateLimit: CodexRateLimit?
    let secondaryRateLimit: CodexRateLimit?

    var markdownSummary: String {
        var lines = ["### Codex Status", ""]

        if let modelDisplay {
            lines.append("Model: \(modelDisplay)")
        }
        if let cwd, !cwd.isEmpty {
            lines.append("Directory: \(Self.displayPath(cwd))")
        }
        let permissionParts = [sandboxPolicy, approvalPolicy]
            .compactMap { value -> String? in
                guard let value, !value.isEmpty else { return nil }
                return value
            }
        if !permissionParts.isEmpty {
            lines.append("Permissions: \(permissionParts.joined(separator: " · "))")
        }

        if lines.last != "" {
            lines.append("")
        }
        let percentUsed = 100 - percentRemaining
        lines.append("Context")
        lines.append("`\(Self.progressBar(percent: Double(percentUsed)))` \(percentUsed)% used · \(percentRemaining)% left")
        lines.append("\(Self.compact(tokensInContext)) / \(Self.compact(contextWindow))")
        if let primaryRateLimit {
            lines.append("")
            lines.append("5h limit")
            lines.append(primaryRateLimit.markdownLine)
        }
        if let secondaryRateLimit {
            lines.append("")
            lines.append("Weekly limit")
            lines.append(secondaryRateLimit.markdownLine)
        }
        if let sessionID, !sessionID.isEmpty {
            lines.append("")
            lines.append("Session: \(sessionID)")
        }
        return lines.joined(separator: "\n")
    }

    private var modelDisplay: String? {
        guard let model, !model.isEmpty else {
            return nil
        }
        var details: [String] = []
        if let reasoningEffort, !reasoningEffort.isEmpty {
            details.append("reasoning \(reasoningEffort)")
        }
        if let summaryMode, !summaryMode.isEmpty, summaryMode != "none" {
            details.append("summaries \(summaryMode)")
        }
        guard !details.isEmpty else {
            return model
        }
        return "\(model) (\(details.joined(separator: ", ")))"
    }

    private static func compact(_ value: Int) -> String {
        guard value >= 1_000 else {
            return String(value)
        }
        return "\(Int((Double(value) / 1_000.0).rounded()))K"
    }

    private static func progressBar(percent: Double) -> String {
        let columns = 20
        let clamped = min(max(percent, 0), 100)
        let filled = Int((clamped / 100 * Double(columns)).rounded())
        return String(repeating: "■", count: filled) + String(repeating: "□", count: columns - filled)
    }

    private static func displayPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == home {
            return "~"
        }
        if path.hasPrefix(home + "/") {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}

struct CodexRateLimit: Equatable {
    let usedPercent: Double
    let windowMinutes: Int?
    let resetsAt: Int?

    var percentLeft: Int {
        Int((100.0 - usedPercent).rounded().clamped(to: 0...100))
    }

    var displayLine: String {
        if let resetsAt {
            return "\(percentLeft)% left · resets \(Self.formatResetTime(resetsAt))"
        }
        return "\(percentLeft)% left"
    }

    var markdownLine: String {
        let percentUsed = 100 - percentLeft
        if let resetsAt {
            return "`\(Self.progressBar(percent: Double(percentUsed)))` \(percentLeft)% left · resets \(Self.formatResetTime(resetsAt))"
        }
        return "`\(Self.progressBar(percent: Double(percentUsed)))` \(percentLeft)% left"
    }

    private static func formatResetTime(_ epochSeconds: Int) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(epochSeconds))
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        if Calendar.current.isDateInToday(date) {
            formatter.dateFormat = "HH:mm"
        } else {
            formatter.dateFormat = "HH:mm 'on' d MMM"
        }
        return formatter.string(from: date)
    }

    private static func progressBar(percent: Double) -> String {
        let columns = 20
        let clamped = min(max(percent, 0), 100)
        let filled = Int((clamped / 100 * Double(columns)).rounded())
        return String(repeating: "■", count: filled) + String(repeating: "□", count: columns - filled)
    }
}

struct CodexStatusSnapshotReader {
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

    init(tailLineLimit: Int = 5_000) {
        self.tailLineLimit = tailLineLimit
    }

    func read(transcriptPath: String?,
              fallbackSessionID: String? = nil,
              fallbackCWD: String? = nil) throws -> CodexStatusSnapshot {
        guard let transcriptPath, !transcriptPath.isEmpty else {
            throw Error.missingTranscriptPath
        }
        let url = URL(fileURLWithPath: NSString(string: transcriptPath).expandingTildeInPath)
        let lines = try JSONLFileReader.readTail(fileURL: url, limit: tailLineLimit)
        let decoder = JSONDecoder()

        var latestSessionMeta: CodexSessionMetaPayload?
        var latestTurnContext: CodexTurnContextPayload?
        var latestTokenCount: (timestamp: String, payload: CodexRolloutPayload)?

        for line in lines {
            guard let data = line.line.data(using: .utf8),
                  let record = try? decoder.decode(CodexRolloutRecord.self, from: data) else {
                continue
            }
            switch record.type {
            case "session_meta":
                latestSessionMeta = record.payload.sessionMeta
            case "turn_context":
                latestTurnContext = record.payload.turnContext
            case "event_msg" where record.payload.type == "token_count":
                if record.payload.info != nil {
                    latestTokenCount = (record.timestamp, record.payload)
                }
            default:
                continue
            }
        }

        guard let tokenCount = latestTokenCount,
              let info = tokenCount.payload.info else {
            throw Error.noTokenCount
        }
        guard let contextWindow = info.modelContextWindow else {
            throw Error.missingContextWindow
        }

        let tokensInContext = max(info.lastTokenUsage.totalTokens, 0)
        return CodexStatusSnapshot(timestamp: tokenCount.timestamp,
                                   sessionID: latestSessionMeta?.id ?? fallbackSessionID,
                                   model: latestTurnContext?.model,
                                   reasoningEffort: latestTurnContext?.reasoningEffort ??
                                       latestTurnContext?.collaborationMode?.settings?.reasoningEffort,
                                   summaryMode: latestTurnContext?.summary ??
                                       latestTurnContext?.collaborationMode?.settings?.summary,
                                   cwd: latestTurnContext?.cwd ?? latestSessionMeta?.cwd ?? fallbackCWD,
                                   approvalPolicy: latestTurnContext?.approvalPolicy,
                                   sandboxPolicy: latestTurnContext?.sandboxPolicy?.type,
                                   tokensInContext: tokensInContext,
                                   contextWindow: contextWindow,
                                   percentRemaining: Self.percentRemaining(tokensInContext: tokensInContext,
                                                                            contextWindow: contextWindow),
                                   primaryRateLimit: tokenCount.payload.rateLimits?.primary,
                                   secondaryRateLimit: tokenCount.payload.rateLimits?.secondary)
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
    let payload: CodexRolloutPayload
}

private struct CodexRolloutPayload: Decodable {
    let type: String?
    let sessionMeta: CodexSessionMetaPayload?
    let turnContext: CodexTurnContextPayload?
    let info: CodexTokenCountInfo?
    let rateLimits: CodexRateLimits?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decodeIfPresent(String.self, forKey: .type)
        sessionMeta = try? CodexSessionMetaPayload(from: decoder)
        turnContext = try? CodexTurnContextPayload(from: decoder)
        info = try container.decodeIfPresent(CodexTokenCountInfo.self, forKey: .info)
        rateLimits = try container.decodeIfPresent(CodexRateLimits.self, forKey: .rateLimits)
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case info
        case rateLimits = "rate_limits"
    }
}

private struct CodexSessionMetaPayload: Decodable {
    let id: String?
    let cwd: String?
}

private struct CodexTurnContextPayload: Decodable {
    let cwd: String?
    let approvalPolicy: String?
    let sandboxPolicy: CodexSandboxPolicy?
    let model: String?
    let reasoningEffort: String?
    let summary: String?
    let collaborationMode: CodexCollaborationMode?

    private enum CodingKeys: String, CodingKey {
        case cwd
        case approvalPolicy = "approval_policy"
        case sandboxPolicy = "sandbox_policy"
        case model
        case reasoningEffort = "reasoning_effort"
        case summary
        case collaborationMode = "collaboration_mode"
    }
}

private struct CodexSandboxPolicy: Decodable {
    let type: String?
}

private struct CodexCollaborationMode: Decodable {
    let settings: CodexCollaborationSettings?
}

private struct CodexCollaborationSettings: Decodable {
    let reasoningEffort: String?
    let summary: String?

    private enum CodingKeys: String, CodingKey {
        case reasoningEffort = "reasoning_effort"
        case summary
    }
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

private struct CodexRateLimits: Decodable {
    let primary: CodexRateLimit?
    let secondary: CodexRateLimit?
}

extension CodexRateLimit: Decodable {
    private enum CodingKeys: String, CodingKey {
        case usedPercent = "used_percent"
        case windowMinutes = "window_minutes"
        case resetsAt = "resets_at"
    }
}

private extension Comparable {
    func clamped(to limits: ClosedRange<Self>) -> Self {
        min(max(self, limits.lowerBound), limits.upperBound)
    }
}
