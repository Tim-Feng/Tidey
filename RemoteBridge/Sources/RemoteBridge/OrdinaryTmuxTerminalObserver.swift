import Foundation

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

