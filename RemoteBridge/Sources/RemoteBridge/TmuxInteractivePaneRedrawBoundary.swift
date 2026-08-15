import Darwin
import Foundation

struct TmuxInteractivePaneRedrawRequest: Equatable, Sendable {
    let socket: OrdinaryTmuxSocketSelector
    let paneID: String
}

protocol TmuxInteractivePaneRedrawRequesting: Sendable {
    func requestRedraw(
        _ request: TmuxInteractivePaneRedrawRequest
    ) throws
}

struct DisabledTmuxInteractivePaneRedrawRequester:
    TmuxInteractivePaneRedrawRequesting
{
    func requestRedraw(
        _ request: TmuxInteractivePaneRedrawRequest
    ) throws {}
}

enum TmuxInteractivePaneRedrawRequesterError: Error, Equatable {
    case invalidPaneID
    case tmuxCommandTimedOut
    case tmuxCommandFailed(status: Int32)
    case invalidPaneRecord
    case processStatusTimedOut
    case processStatusFailed(status: Int32)
    case invalidProcessStatus
    case invalidProcessGroupMembers
    case signalFailed(code: Int32)
}

final class TmuxInteractivePaneRedrawRequester:
    TmuxInteractivePaneRedrawRequesting,
    @unchecked Sendable
{
    typealias RunTmux = @Sendable ([String]) -> BoundedProcessResult?
    typealias RunProcessStatus = @Sendable ([String]) -> BoundedProcessResult?
    typealias SignalProcesses = @Sendable ([Int32]) throws -> Void

    private struct ProvedPaneProcess {
        let processID: Int32
        let ttyPath: String
    }

    private static let recordPrefix = "TIDEYv1"
    private static let recordSuffix = "END"

    private let runTmux: RunTmux
    private let runProcessStatus: RunProcessStatus
    private let signalProcesses: SignalProcesses

    init(tmuxExecutablePath: String) {
        runTmux = { arguments in
            BoundedProcessRunner.run(
                executablePath: tmuxExecutablePath,
                arguments: arguments,
                timeout: 1,
                circuitBreakerCooldown: 0
            )
        }
        runProcessStatus = { arguments in
            BoundedProcessRunner.run(
                executablePath: "/bin/ps",
                arguments: arguments,
                timeout: 1,
                circuitBreakerCooldown: 0
            )
        }
        signalProcesses = { processIDs in
            var didSignal = false
            for processID in processIDs {
                if Darwin.kill(processID, SIGWINCH) == 0 {
                    didSignal = true
                } else if errno != ESRCH {
                    throw TmuxInteractivePaneRedrawRequesterError.signalFailed(
                        code: errno
                    )
                }
            }
            guard didSignal else {
                throw TmuxInteractivePaneRedrawRequesterError.signalFailed(
                    code: ESRCH
                )
            }
        }
    }

    init(
        runTmux: @escaping RunTmux,
        runProcessStatus: @escaping RunProcessStatus,
        signalProcesses: @escaping SignalProcesses
    ) {
        self.runTmux = runTmux
        self.runProcessStatus = runProcessStatus
        self.signalProcesses = signalProcesses
    }

    func requestRedraw(
        _ request: TmuxInteractivePaneRedrawRequest
    ) throws {
        guard Self.isValidPaneID(request.paneID) else {
            throw TmuxInteractivePaneRedrawRequesterError.invalidPaneID
        }
        let format = [
            Self.recordPrefix,
            "#{pane_id}",
            "#{pane_pid}",
            "#{pane_tty}",
            Self.recordSuffix,
        ].joined(separator: "|")
        let arguments = OrdinaryTmuxCLIAdapter.arguments(
            for: request.socket,
            commandArguments: [
                "display-message", "-p",
                "-t", request.paneID,
                format,
            ]
        )
        guard let result = runTmux(arguments) else {
            throw TmuxInteractivePaneRedrawRequesterError.tmuxCommandTimedOut
        }
        guard result.terminationStatus == 0 else {
            throw TmuxInteractivePaneRedrawRequesterError.tmuxCommandFailed(
                status: result.terminationStatus
            )
        }
        guard let pane = Self.parsePaneProcess(
            result.standardOutput,
            expectedPaneID: request.paneID
        ) else {
            throw TmuxInteractivePaneRedrawRequesterError.invalidPaneRecord
        }
        guard let processStatus = runProcessStatus([
            "-o", "tty=",
            "-o", "tpgid=",
            "-p", String(pane.processID),
        ]) else {
            throw TmuxInteractivePaneRedrawRequesterError.processStatusTimedOut
        }
        guard processStatus.terminationStatus == 0 else {
            throw TmuxInteractivePaneRedrawRequesterError.processStatusFailed(
                status: processStatus.terminationStatus
            )
        }
        guard let foregroundProcessGroup = Self.parseForegroundProcessGroup(
            processStatus.standardOutput,
            expectedTTYPath: pane.ttyPath
        ) else {
            throw TmuxInteractivePaneRedrawRequesterError.invalidProcessStatus
        }
        guard let groupMembersResult = runProcessStatus([
            "-a", "-x",
            "-o", "pid=",
            "-o", "pgid=",
            "-o", "tty=",
        ]) else {
            throw TmuxInteractivePaneRedrawRequesterError.processStatusTimedOut
        }
        guard groupMembersResult.terminationStatus == 0 else {
            throw TmuxInteractivePaneRedrawRequesterError.processStatusFailed(
                status: groupMembersResult.terminationStatus
            )
        }
        let processIDs = Self.parseForegroundProcessGroupMembers(
            groupMembersResult.standardOutput,
            processGroup: foregroundProcessGroup,
            expectedTTYPath: pane.ttyPath
        )
        guard processIDs.isEmpty == false else {
            throw TmuxInteractivePaneRedrawRequesterError
                .invalidProcessGroupMembers
        }
        try signalProcesses(processIDs)
    }

    private static func isValidPaneID(_ paneID: String) -> Bool {
        guard paneID.first == "%" else { return false }
        let digits = paneID.dropFirst()
        return digits.isEmpty == false && digits.allSatisfy { $0.isASCII && $0.isNumber }
    }

    private static func parsePaneProcess(
        _ data: Data,
        expectedPaneID: String
    ) -> ProvedPaneProcess? {
        let output = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let fields = output.split(
            separator: "|",
            omittingEmptySubsequences: false
        )
        guard fields.count == 5,
              fields[0] == Substring(recordPrefix),
              fields[1] == Substring(expectedPaneID),
              let processID = Int32(fields[2]),
              processID > 0,
              fields[4] == Substring(recordSuffix) else {
            return nil
        }
        let paneTTY = String(fields[3])
        guard paneTTY.hasPrefix("/dev/tty"),
              paneTTY.utf8.count < Int(PATH_MAX),
              paneTTY.utf8.contains(0) == false else {
            return nil
        }
        return ProvedPaneProcess(processID: processID, ttyPath: paneTTY)
    }

    private static func parseForegroundProcessGroup(
        _ data: Data,
        expectedTTYPath: String
    ) -> Int32? {
        let fields = String(decoding: data, as: UTF8.self)
            .split(whereSeparator: { $0.isWhitespace })
        guard fields.count == 2,
              fields[0] == Substring(
                URL(fileURLWithPath: expectedTTYPath).lastPathComponent
              ),
              let processGroup = Int32(fields[1]),
              processGroup > 0 else {
            return nil
        }
        return processGroup
    }

    private static func parseForegroundProcessGroupMembers(
        _ data: Data,
        processGroup: Int32,
        expectedTTYPath: String
    ) -> [Int32] {
        let expectedTTY = URL(fileURLWithPath: expectedTTYPath).lastPathComponent
        return String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .compactMap { line in
                let fields = line.split(whereSeparator: { $0.isWhitespace })
                guard fields.count == 3,
                      let processID = Int32(fields[0]),
                      processID > 0,
                      let candidateProcessGroup = Int32(fields[1]),
                      candidateProcessGroup == processGroup,
                      fields[2] == Substring(expectedTTY) else {
                    return nil
                }
                return processID
            }
            .sorted()
    }
}
