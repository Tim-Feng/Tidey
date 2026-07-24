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

    // A reservation is never just "exists / doesn't exist" — a duplicate
    // arriving while the ORIGINAL is still in flight, or whose outcome is
    // unknown/partial, must NOT be told "submitted: true" (that would be a
    // false success echoed back for a message that may never have reached
    // any transport, or that may have been double-sent). Only a
    // DEFINITELY-delivered original may safely dedupe a duplicate as
    // success.
    enum SubmissionState: Equatable {
        // In flight: no transport has confirmed or ruled out delivery yet.
        case pending
        // Confirmed reached a transport (app-server accepted the turn, or
        // every terminal-fallback step completed) — safe to dedupe as a
        // success echo.
        case delivered
        // Partial/unknown: SOME step of the delivery attempt may have had
        // an externally observable effect (e.g. the message text step
        // succeeded but the Enter step failed), so it can be neither
        // trusted as delivered NOR safely discarded/retried as if nothing
        // happened.
        case indeterminate
    }

    // The outcome of a beginSubmission() call — replaces the old bare Bool,
    // which could only distinguish "new" from "duplicate" and therefore
    // could not tell a caller that a duplicate arrived while its original
    // was still unresolved or in an unknown state.
    enum BeginSubmissionOutcome: Equatable {
        case started
        case duplicate(SubmissionState)
    }

    private struct SubmissionRecord: Equatable {
        let workspaceID: String
        let panelID: String
        let sessionID: String
        let vendor: String
        let clientRequestID: String
        let submittedAt: Date
        var state: SubmissionState
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
                         submittedAt: Date? = nil) -> BeginSubmissionOutcome {
        guard let clientRequestID else {
            return .started
        }
        let trimmedRequestID = clientRequestID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRequestID.isEmpty else {
            return .started
        }

        return queue.sync {
            let now = submittedAt ?? self.now()
            pruneExpired(now: now)
            let normalizedVendor = vendor.lowercased()
            if let existing = submissionRecords.first(where: {
                $0.workspaceID == workspaceID
                    && $0.panelID == panelID
                    && $0.sessionID == sessionID
                    && $0.vendor == normalizedVendor
                    && $0.clientRequestID == trimmedRequestID
            }) {
                BridgeLogger.input.info("chat submit duplicate suppressed workspace_id=\(workspaceID, privacy: .public) panel_id=\(panelID, privacy: .public) session_id=\(sessionID, privacy: .public) vendor=\(vendor, privacy: .public) client_request_id=\(trimmedRequestID, privacy: .public) existing_state=\(String(describing: existing.state))")
                return .duplicate(existing.state)
            }

            submissionRecords.append(SubmissionRecord(workspaceID: workspaceID,
                                                      panelID: panelID,
                                                      sessionID: sessionID,
                                                      vendor: normalizedVendor,
                                                      clientRequestID: trimmedRequestID,
                                                      submittedAt: now,
                                                      state: .pending))
            BridgeLogger.input.info("chat submit submission registered workspace_id=\(workspaceID, privacy: .public) panel_id=\(panelID, privacy: .public) session_id=\(sessionID, privacy: .public) vendor=\(vendor, privacy: .public) client_request_id=\(trimmedRequestID, privacy: .public)")
            return .started
        }
    }

    // Rolls back a beginSubmission() reservation that PROVABLY had zero
    // side effect (e.g. an atomic app-server claim rejected before any
    // transport attempt, or a terminal-fallback attempt whose very FIRST
    // step never reached the transport). Without this, a network retry of
    // the SAME client_request_id would be wrongly dedup-suppressed as if
    // the message had already been sent, even though nothing ever reached
    // app-server or the terminal — the message would silently vanish. Only
    // call this when NO step of the delivery attempt could have had an
    // externally observable effect; otherwise use markIndeterminate.
    func cancelSubmission(workspaceID: String,
                          panelID: String,
                          sessionID: String,
                          vendor: String,
                          clientRequestID: String) {
        let trimmedRequestID = clientRequestID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRequestID.isEmpty else {
            return
        }
        queue.sync {
            let normalizedVendor = vendor.lowercased()
            let beforeCount = submissionRecords.count
            submissionRecords.removeAll {
                $0.workspaceID == workspaceID
                    && $0.panelID == panelID
                    && $0.sessionID == sessionID
                    && $0.vendor == normalizedVendor
                    && $0.clientRequestID == trimmedRequestID
            }
            if submissionRecords.count != beforeCount {
                BridgeLogger.input.info("chat submit submission rolled back workspace_id=\(workspaceID, privacy: .public) panel_id=\(panelID, privacy: .public) session_id=\(sessionID, privacy: .public) vendor=\(vendor, privacy: .public) client_request_id=\(trimmedRequestID, privacy: .public)")
            }
        }
    }

    // Marks a reservation as DEFINITELY delivered — only a duplicate of a
    // submission in THIS state may be told "submitted: true" instead of a
    // conflict.
    func markDelivered(workspaceID: String,
                       panelID: String,
                       sessionID: String,
                       vendor: String,
                       clientRequestID: String) {
        setState(.delivered, workspaceID: workspaceID, panelID: panelID, sessionID: sessionID,
                vendor: vendor, clientRequestID: clientRequestID)
    }

    // Marks a reservation as partial/unknown — some step of the delivery
    // attempt may have had an externally observable effect (a terminal
    // message-text step that succeeded before its Enter step failed, or a
    // generic direct-submit error whose transport-level outcome cannot be
    // proven zero-effect). A duplicate of a submission in this state must
    // get a conflict response, never a silent resend and never a false
    // success.
    func markIndeterminate(workspaceID: String,
                           panelID: String,
                           sessionID: String,
                           vendor: String,
                           clientRequestID: String) {
        setState(.indeterminate, workspaceID: workspaceID, panelID: panelID, sessionID: sessionID,
                vendor: vendor, clientRequestID: clientRequestID)
    }

    private func setState(_ state: SubmissionState,
                          workspaceID: String,
                          panelID: String,
                          sessionID: String,
                          vendor: String,
                          clientRequestID: String) {
        let trimmedRequestID = clientRequestID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRequestID.isEmpty else {
            return
        }
        queue.sync {
            let normalizedVendor = vendor.lowercased()
            guard let index = submissionRecords.firstIndex(where: {
                $0.workspaceID == workspaceID
                    && $0.panelID == panelID
                    && $0.sessionID == sessionID
                    && $0.vendor == normalizedVendor
                    && $0.clientRequestID == trimmedRequestID
            }) else {
                return
            }
            submissionRecords[index].state = state
            BridgeLogger.input.info("chat submit submission state updated workspace_id=\(workspaceID, privacy: .public) panel_id=\(panelID, privacy: .public) session_id=\(sessionID, privacy: .public) vendor=\(vendor, privacy: .public) client_request_id=\(trimmedRequestID, privacy: .public) state=\(String(describing: state), privacy: .public)")
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
