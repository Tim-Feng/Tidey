import Foundation

@MainActor
@objc protocol TideyBrowserAutomationHost: AnyObject {
    func browserAutomationVisibleTabs() -> [[String: Any]]
    func browserAutomationEngine(forTabID tabID: String) -> TideyBrowserEngine?
    func browserAutomationPresent(engine: TideyBrowserEngine,
                                  tabID: String,
                                  initialURL: URL) -> Bool
}

@MainActor
@objc(TideyBrowserAutomationController)
final class TideyBrowserAutomationController: NSObject, TideyBrowserEngineHost {
    weak var host: TideyBrowserAutomationHost?
    private(set) var state: TideyBrowserAutomationState
    private(set) var privateEnginesByID: [String: TideyBrowserEngine] = [:]

    @objc init(host: TideyBrowserAutomationHost,
               maxPrivateTabs: Int = 8,
               handoffTTL: TimeInterval = 30 * 60) {
        self.host = host
        self.state = TideyBrowserAutomationState(
            maxPrivateTabs: maxPrivateTabs,
            handoffTTL: handoffTTL
        )
        super.init()
    }

    func browserEngine(_ engine: TideyBrowserEngine,
                       didUpdateState state: TideyBrowserEngineState) {
    }

    func browserEngine(_ engine: TideyBrowserEngine,
                       requestPopup request: TideyBrowserPopupRequest) {
    }
}
