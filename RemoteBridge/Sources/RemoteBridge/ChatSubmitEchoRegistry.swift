import Foundation

final class ChatSubmitEchoRegistry {
    struct Record: Equatable {
        let workspaceID: String
        let panelID: String
        let sessionID: String
        let vendor: String
        let normalizedText: String
        let clientRequestID: String
        let submittedAt: Date
    }

    private struct SubmissionRecord: Equatable {
        let workspaceID: String
        let panelID: String
        let sessionID: String
        let vendor: String
        let clientRequestID: String
        let submittedAt: Date
    }

    private let ttl: TimeInterval
    private let now: () -> Date
    private let queue = DispatchQueue(label: "com.tidey.remote-bridge.chat-submit-echo-registry")
    private var records = [Record]()
    private var submissionRecords = [SubmissionRecord]()

    init(ttl: TimeInterval = 10 * 60,
         now: @escaping () -> Date = Date.init) {
        self.ttl = ttl
        self.now = now
    }

    func register(workspaceID: String,
                  panelID: String,
                  sessionID: String,
                  vendor: String,
                  text: String,
                  clientRequestID: String,
                  submittedAt: Date? = nil) {
        let trimmedRequestID = clientRequestID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRequestID.isEmpty else {
            return
        }

        queue.sync {
            let now = submittedAt ?? self.now()
            pruneExpired(now: now)
            records.append(Record(workspaceID: workspaceID,
                                  panelID: panelID,
                                  sessionID: sessionID,
                                  vendor: vendor.lowercased(),
                                  normalizedText: Self.normalizedKey(text),
                                  clientRequestID: trimmedRequestID,
                                  submittedAt: now))
            BridgeLogger.input.info("chat submit echo registered workspace_id=\(workspaceID, privacy: .public) panel_id=\(panelID, privacy: .public) session_id=\(sessionID, privacy: .public) vendor=\(vendor, privacy: .public) client_request_id=\(trimmedRequestID, privacy: .public)")
        }
    }

    func beginSubmission(workspaceID: String,
                         panelID: String,
                         sessionID: String,
                         vendor: String,
                         clientRequestID: String?,
                         submittedAt: Date? = nil) -> Bool {
        guard let clientRequestID else {
            return true
        }
        let trimmedRequestID = clientRequestID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRequestID.isEmpty else {
            return true
        }

        return queue.sync {
            let now = submittedAt ?? self.now()
            pruneExpired(now: now)
            let normalizedVendor = vendor.lowercased()
            if submissionRecords.contains(where: {
                $0.workspaceID == workspaceID
                    && $0.panelID == panelID
                    && $0.sessionID == sessionID
                    && $0.vendor == normalizedVendor
                    && $0.clientRequestID == trimmedRequestID
            }) {
                BridgeLogger.input.info("chat submit duplicate suppressed workspace_id=\(workspaceID, privacy: .public) panel_id=\(panelID, privacy: .public) session_id=\(sessionID, privacy: .public) vendor=\(vendor, privacy: .public) client_request_id=\(trimmedRequestID, privacy: .public)")
                return false
            }

            submissionRecords.append(SubmissionRecord(workspaceID: workspaceID,
                                                      panelID: panelID,
                                                      sessionID: sessionID,
                                                      vendor: normalizedVendor,
                                                      clientRequestID: trimmedRequestID,
                                                      submittedAt: now))
            BridgeLogger.input.info("chat submit submission registered workspace_id=\(workspaceID, privacy: .public) panel_id=\(panelID, privacy: .public) session_id=\(sessionID, privacy: .public) vendor=\(vendor, privacy: .public) client_request_id=\(trimmedRequestID, privacy: .public)")
            return true
        }
    }

    func consumeClientRequestID(workspaceID: String,
                                panelID: String?,
                                sessionID: String,
                                vendor: String,
                                text: String) -> String? {
        queue.sync {
            let now = self.now()
            pruneExpired(now: now)
            let normalizedText = Self.normalizedKey(text)
            guard let index = records.indices
                .filter({ index in
                    let record = records[index]
                    return record.workspaceID == workspaceID
                        && panelID.map { $0 == record.panelID } == true
                        && record.sessionID == sessionID
                        && record.vendor == vendor.lowercased()
                        && record.normalizedText == normalizedText
                })
                .min(by: { records[$0].submittedAt < records[$1].submittedAt }) else {
                return nil
            }

            let record = records.remove(at: index)
            BridgeLogger.input.info("chat submit echo consumed workspace_id=\(workspaceID, privacy: .public) panel_id=\(panelID ?? "-", privacy: .public) session_id=\(sessionID, privacy: .public) vendor=\(vendor, privacy: .public) client_request_id=\(record.clientRequestID, privacy: .public)")
            return record.clientRequestID
        }
    }

    func snapshot() -> [Record] {
        queue.sync {
            records
        }
    }

    private func pruneExpired(now: Date) {
        records.removeAll { now.timeIntervalSince($0.submittedAt) > ttl }
        submissionRecords.removeAll { now.timeIntervalSince($0.submittedAt) > ttl }
    }

    static func normalizedKey(_ text: String) -> String {
        let normalizedLineEndings = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let trimmedLines = normalizedLineEndings
            .components(separatedBy: "\n")
            .map(trimTrailingWhitespace)
            .joined(separator: "\n")
        let trimmed = trimmedLines.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.replacingOccurrences(of: "\n{3,}",
                                            with: "\n\n",
                                            options: .regularExpression)
    }

    private static func trimTrailingWhitespace(_ line: String) -> String {
        var endIndex = line.endIndex
        while endIndex > line.startIndex {
            let previousIndex = line.index(before: endIndex)
            let character = line[previousIndex]
            guard character.unicodeScalars.allSatisfy({ CharacterSet.whitespaces.contains($0) }) else {
                break
            }
            endIndex = previousIndex
        }
        return String(line[..<endIndex])
    }
}
