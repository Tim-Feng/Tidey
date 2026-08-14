import Foundation

struct TmuxInteractiveAttachClaim: Equatable, Sendable {
    let socket: OrdinaryTmuxSocketSelector
    let childProcessID: Int32
    let workspaceID: String
    let panelID: String
    let sessionID: String
    let windowID: String
}

struct TmuxInteractiveVerifiedAttach: Equatable, Sendable {
    let attachProof: TmuxInteractiveAttachProof
    let childProcessID: Int32
    let clientTTY: String
}

protocol TmuxInteractiveAttachProving: Sendable {
    func prove(_ claim: TmuxInteractiveAttachClaim) throws -> TmuxInteractiveVerifiedAttach?
}

enum TmuxInteractiveAttachProverError: Error, Equatable {
    case malformedClientRecord(String)
}

struct TmuxInteractiveAttachProver: TmuxInteractiveAttachProving {
    private struct ClientRecord {
        let processID: Int32
        let tty: String
        let sessionID: String
        let windowID: String
        let paneID: String
    }

    typealias CommandRunner = OrdinaryTmuxCLIAdapter.CommandRunner

    private let commandRunner: CommandRunner

    init(
        tmuxExecutablePath: String? = TmuxStateResolver.discoverTmuxBinaryPath(),
        timeoutSeconds: TimeInterval = 3
    ) {
        commandRunner = OrdinaryTmuxCLIAdapter.processCommandRunner(
            executablePath: tmuxExecutablePath,
            timeoutSeconds: timeoutSeconds
        )
    }

    init(commandRunner: @escaping CommandRunner) {
        self.commandRunner = commandRunner
    }

    func prove(_ claim: TmuxInteractiveAttachClaim) throws -> TmuxInteractiveVerifiedAttach? {
        guard claim.childProcessID > 0,
              claim.workspaceID.isEmpty == false,
              claim.panelID.isEmpty == false,
              Self.isValidID(claim.sessionID, prefix: "$"),
              Self.isValidID(claim.windowID, prefix: "@") else {
            return nil
        }

        let output = try commandRunner(
            claim.socket,
            [
                "list-clients",
                "-F",
                "#{client_pid}|#{client_tty}|#{session_id}|#{window_id}|#{pane_id}",
            ],
            nil
        )
        let rawRecords = output.split(whereSeparator: \.isNewline)
        let records = try rawRecords.map(Self.parseClientRecord)
        let processMatches = records.filter { $0.processID == claim.childProcessID }
        guard processMatches.count == 1,
              let client = processMatches.first,
              client.sessionID == claim.sessionID,
              client.windowID == claim.windowID else {
            return nil
        }

        return TmuxInteractiveVerifiedAttach(
            attachProof: TmuxInteractiveAttachProof(
                workspaceID: claim.workspaceID,
                panelID: claim.panelID,
                sessionID: client.sessionID,
                windowID: client.windowID,
                paneID: client.paneID
            ),
            childProcessID: client.processID,
            clientTTY: client.tty
        )
    }

    private static func parseClientRecord(_ record: Substring) throws -> ClientRecord {
        let fields = record.split(separator: "|", omittingEmptySubsequences: false)
        guard fields.count == 5,
              let processID = Int32(fields[0]),
              processID > 0,
              fields[1].isEmpty == false,
              isValidID(fields[2], prefix: "$"),
              isValidID(fields[3], prefix: "@"),
              isValidID(fields[4], prefix: "%") else {
            throw TmuxInteractiveAttachProverError.malformedClientRecord(String(record))
        }
        return ClientRecord(
            processID: processID,
            tty: String(fields[1]),
            sessionID: String(fields[2]),
            windowID: String(fields[3]),
            paneID: String(fields[4])
        )
    }

    private static func isValidID<S: StringProtocol>(_ value: S, prefix: Character) -> Bool {
        value.count > 1 && value.first == prefix && value.dropFirst().allSatisfy(\.isNumber)
    }
}
