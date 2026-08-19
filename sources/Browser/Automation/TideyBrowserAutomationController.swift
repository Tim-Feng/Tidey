import Foundation
import WebKit

@MainActor
@objc protocol TideyBrowserAutomationHost: TideyBrowserEngineHost {
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
    private(set) var privateFallbackURLsByID: [String: URL] = [:]
    private let tabIDGenerator: () -> String
    private let engineFactory: (WKWebViewConfiguration) -> TideyBrowserEngine

    @objc convenience init(host: TideyBrowserAutomationHost,
                           maxPrivateTabs: Int = 8,
                           handoffTTL: TimeInterval = 30 * 60) {
        self.init(
            host: host,
            maxPrivateTabs: maxPrivateTabs,
            handoffTTL: handoffTTL,
            tabIDGenerator: { UUID().uuidString },
            engineFactory: { configuration in
                TideyBrowserEngine(configuration: configuration)
            }
        )
    }

    init(host: TideyBrowserAutomationHost,
         maxPrivateTabs: Int = 8,
         handoffTTL: TimeInterval = 30 * 60,
         tabIDGenerator: @escaping () -> String,
         engineFactory: @escaping (WKWebViewConfiguration) -> TideyBrowserEngine) {
        self.host = host
        self.state = TideyBrowserAutomationState(
            maxPrivateTabs: maxPrivateTabs,
            handoffTTL: handoffTTL
        )
        self.tabIDGenerator = tabIDGenerator
        self.engineFactory = engineFactory
        super.init()
    }

    func openPrivate(url: URL,
                     workspaceID: String,
                     ownerSessionID: String,
                     configuration: WKWebViewConfiguration? = nil) throws -> String {
        let tabID = tabIDGenerator()
        try state.registerPrivateTab(
            tabID: tabID,
            workspaceID: workspaceID,
            ownerSessionID: ownerSessionID
        )

        let engine = engineFactory(configuration ?? TideyBrowserEngine.defaultConfiguration())
        engine.host = self
        engine.webView.customUserAgent = TideyBrowserEngine.sessionCompatibleUserAgent()
        if #available(macOS 13.3, *) {
            engine.webView.isInspectable = true
        }
        privateEnginesByID[tabID] = engine
        privateFallbackURLsByID[tabID] = url
        engine.load(url)
        return tabID
    }

    func presentPrivate(tabID: String,
                        workspaceID: String,
                        ownerSessionID: String) throws {
        _ = try state.ownedPrivateTab(
            tabID: tabID,
            workspaceID: workspaceID,
            ownerSessionID: ownerSessionID
        )
        guard let engine = privateEnginesByID[tabID],
              let url = engine.url ?? privateFallbackURLsByID[tabID] else {
            throw TideyBrowserAutomationProtocolError(
                code: .targetGone,
                message: "Private browser engine is no longer available"
            )
        }
        guard let host,
              host.browserAutomationPresent(engine: engine, tabID: tabID, initialURL: url) else {
            throw TideyBrowserAutomationProtocolError(
                code: .targetGone,
                message: "Browser host is no longer available"
            )
        }

        _ = try state.takePrivateTabForPresentation(
            tabID: tabID,
            workspaceID: workspaceID,
            ownerSessionID: ownerSessionID
        )
        privateEnginesByID.removeValue(forKey: tabID)
        privateFallbackURLsByID.removeValue(forKey: tabID)
        engine.host = host
    }

    func browserEngine(_ engine: TideyBrowserEngine,
                       didUpdateState state: TideyBrowserEngineState) {
        guard let tabID = privateEnginesByID.first(where: { $0.value === engine })?.key else {
            return
        }
        if let currentURL = state.currentURL {
            privateFallbackURLsByID[tabID] = currentURL
        }
    }

    func browserEngine(_ engine: TideyBrowserEngine,
                       requestPopup request: TideyBrowserPopupRequest) {
        guard let parentTabID = privateEnginesByID.first(where: { $0.value === engine })?.key,
              let parent = state.privateTabsByID[parentTabID],
              let ownerSessionID = parent.ownerSessionID else {
            return
        }
        _ = try? openPrivate(
            url: request.url,
            workspaceID: parent.workspaceID,
            ownerSessionID: ownerSessionID,
            configuration: request.configuration
        )
    }
}
