import Foundation

struct TmuxInteractiveClientRefreshRequest: Equatable, Sendable {
    let socket: OrdinaryTmuxSocketSelector
    let clientTTY: String
}

protocol TmuxInteractiveClientRefreshRequesting: Sendable {
    func requestRefresh(
        _ request: TmuxInteractiveClientRefreshRequest
    ) throws
}

struct DisabledTmuxInteractiveClientRefreshRequester:
    TmuxInteractiveClientRefreshRequesting
{
    func requestRefresh(
        _ request: TmuxInteractiveClientRefreshRequest
    ) throws {}
}

enum TmuxInteractiveClientRefreshRequesterError: Error, Equatable {
    case invalidClientTTY
    case tmuxCommandTimedOut
    case tmuxCommandFailed(status: Int32)
}

final class TmuxInteractiveClientRefreshRequester:
    TmuxInteractiveClientRefreshRequesting,
    @unchecked Sendable
{
    typealias RunTmux = @Sendable ([String]) -> BoundedProcessResult?

    private let runTmux: RunTmux

    init(tmuxExecutablePath: String) {
        runTmux = { arguments in
            BoundedProcessRunner.run(
                executablePath: tmuxExecutablePath,
                arguments: arguments,
                timeout: 1,
                circuitBreakerCooldown: 0
            )
        }
    }

    init(runTmux: @escaping RunTmux) {
        self.runTmux = runTmux
    }

    func requestRefresh(
        _ request: TmuxInteractiveClientRefreshRequest
    ) throws {
        guard Self.isValidClientTTY(request.clientTTY) else {
            throw TmuxInteractiveClientRefreshRequesterError.invalidClientTTY
        }
        let arguments = OrdinaryTmuxCLIAdapter.arguments(
            for: request.socket,
            commandArguments: [
                "refresh-client", "-t", request.clientTTY,
            ]
        )
        guard let result = runTmux(arguments) else {
            throw TmuxInteractiveClientRefreshRequesterError.tmuxCommandTimedOut
        }
        guard result.terminationStatus == 0 else {
            throw TmuxInteractiveClientRefreshRequesterError.tmuxCommandFailed(
                status: result.terminationStatus
            )
        }
    }

    private static func isValidClientTTY(_ clientTTY: String) -> Bool {
        let prefix = "/dev/ttys"
        guard clientTTY.hasPrefix(prefix) else { return false }
        let suffix = clientTTY.dropFirst(prefix.count)
        return suffix.isEmpty == false && suffix.allSatisfy(\.isHexDigit)
    }
}
