import Foundation

protocol OrdinaryTmuxControlModeProcessManaging: AnyObject, Sendable {
    func addSubscription(name: String, paneID: String) throws
    func removeSubscription(name: String) throws
    func detachAndWait()
}

typealias OrdinaryTmuxControlModeProcessFactory = @Sendable (
    _ socket: OrdinaryTmuxSocketSelector,
    _ sessionID: String,
    _ onOutput: @escaping @Sendable (Data) -> Void,
    _ onExit: @escaping @Sendable (Error?) -> Void
) throws -> OrdinaryTmuxControlModeProcessManaging

struct OrdinaryTmuxTerminalObservationRequest: Sendable {
    let route: OrdinaryTmuxPanelRoute
    let subscriptionID: String
    let expectedFingerprint: OrdinaryTmuxTerminalFingerprintV1
    let onRebootstrapRequired: @Sendable (OrdinaryTmuxTerminalFingerprintV1?) -> Void
}

protocol OrdinaryTmuxTerminalObserverLeasing: AnyObject, Sendable {
    func stop()
}

protocol OrdinaryTmuxTerminalObserving: Sendable {
    func observe(
        _ request: OrdinaryTmuxTerminalObservationRequest
    ) throws -> OrdinaryTmuxTerminalObserverLeasing
}
