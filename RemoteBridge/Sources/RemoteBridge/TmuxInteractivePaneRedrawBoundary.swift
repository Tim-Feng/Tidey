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
