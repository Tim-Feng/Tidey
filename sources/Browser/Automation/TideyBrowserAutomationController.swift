import Foundation
import WebKit

@MainActor
@objc protocol TideyBrowserAutomationHost: TideyBrowserEngineHost {
    func browserAutomationVisibleTabs() -> [[String: Any]]
    func browserAutomationEngine(forTabID tabID: String) -> TideyBrowserEngine?
    func browserAutomationPresent(engine: TideyBrowserEngine,
                                  tabID: String,
                                  initialURL: URL) -> Bool
    func browserAutomationClose(tabID: String) -> Bool
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
    private var popupTabIDsByParentID: [String: [String]] = [:]
    private(set) var actionLog: [String] = []

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

    func handle(request: TideyBrowserAutomationRequest,
                ownerSessionID: String) async throws -> TideyBrowserAutomationResponse {
        expireHandoffs(now: Date())
        log(request.command, ownerSessionID: ownerSessionID)
        let workspaceID = request.workspaceID

        switch request.command {
        case .tabs:
            var tabs = host?.browserAutomationVisibleTabs() ?? []
            tabs.append(contentsOf: state.privateTabsByID.values
                .filter {
                    $0.workspaceID == workspaceID &&
                        ($0.ownerSessionID == ownerSessionID ||
                         ($0.ownerSessionID == nil && $0.mark == .handoff))
                }
                .sorted { $0.tabID < $1.tabID }
                .map { tab in
                    [
                        "tab_id": tab.tabID,
                        "url": privateEnginesByID[tab.tabID]?.url?.absoluteString ??
                            privateFallbackURLsByID[tab.tabID]?.absoluteString ?? "",
                        "private": true,
                        "mark": tab.mark.rawValue,
                    ] as [String: Any]
                })
            return response(["tabs": tabs])
        case .open(let url):
            let tabID = try mapStateError {
                try openPrivate(
                    url: url,
                    workspaceID: workspaceID,
                    ownerSessionID: ownerSessionID
                )
            }
            return response(["tab_id": tabID, "private": true])
        case .claim(let tabID):
            guard host?.browserAutomationEngine(forTabID: tabID) != nil else {
                throw protocolError(.targetGone, "Visible browser tab is no longer available")
            }
            try mapStateError {
                try state.claimUserTab(
                    tabID: tabID,
                    workspaceID: workspaceID,
                    ownerSessionID: ownerSessionID
                )
            }
            return response(["claimed": true, "tab_id": tabID])
        case .release(let tabID):
            try mapStateError {
                try state.releaseUserTab(
                    tabID: tabID,
                    workspaceID: workspaceID,
                    ownerSessionID: ownerSessionID
                )
            }
            return response(["released": true, "tab_id": tabID])
        case .reclaim(let tabID):
            try mapStateError {
                try state.reclaimHandoff(
                    tabID: tabID,
                    workspaceID: workspaceID,
                    ownerSessionID: ownerSessionID,
                    now: Date()
                )
            }
            return response(["reclaimed": true, "tab_id": tabID])
        case .mark(let tabID, let mark):
            try mapStateError {
                try state.markPrivateTab(
                    tabID: tabID,
                    workspaceID: workspaceID,
                    ownerSessionID: ownerSessionID,
                    mark: mark
                )
            }
            return response(["tab_id": tabID, "mark": mark.rawValue])
        case .close(let tabID):
            if state.privateTabsByID[tabID] != nil {
                _ = try mapStateError {
                    try state.takePrivateTabForClose(
                        tabID: tabID,
                        workspaceID: workspaceID,
                        ownerSessionID: ownerSessionID
                    )
                }
                removePrivateEngine(tabID: tabID)
            } else {
                _ = try ownedEngine(
                    tabID: tabID,
                    workspaceID: workspaceID,
                    ownerSessionID: ownerSessionID
                )
                guard host?.browserAutomationClose(tabID: tabID) == true else {
                    throw protocolError(.targetGone, "Visible browser tab is no longer available")
                }
                try mapStateError {
                    try state.releaseUserTab(
                        tabID: tabID,
                        workspaceID: workspaceID,
                        ownerSessionID: ownerSessionID
                    )
                }
            }
            return response(["closed": true, "tab_id": tabID])
        case .present(let tabID):
            try mapStateError {
                try presentPrivate(
                    tabID: tabID,
                    workspaceID: workspaceID,
                    ownerSessionID: ownerSessionID
                )
            }
            return response(["presented": true, "tab_id": tabID])
        case .navigate(let tabID, let url):
            let engine = try ownedEngine(tabID: tabID, workspaceID: workspaceID,
                                         ownerSessionID: ownerSessionID)
            engine.load(url)
            return response(["tab_id": tabID, "url": url.absoluteString], createdBy: tabID)
        case .back(let tabID):
            let engine = try ownedEngine(tabID: tabID, workspaceID: workspaceID,
                                         ownerSessionID: ownerSessionID)
            engine.goBack()
            return response(["tab_id": tabID], createdBy: tabID)
        case .forward(let tabID):
            let engine = try ownedEngine(tabID: tabID, workspaceID: workspaceID,
                                         ownerSessionID: ownerSessionID)
            engine.goForward()
            return response(["tab_id": tabID], createdBy: tabID)
        case .reload(let tabID):
            let engine = try ownedEngine(tabID: tabID, workspaceID: workspaceID,
                                         ownerSessionID: ownerSessionID)
            engine.reload()
            return response(["tab_id": tabID], createdBy: tabID)
        case .currentURL(let tabID):
            let engine = try ownedEngine(tabID: tabID, workspaceID: workspaceID,
                                         ownerSessionID: ownerSessionID)
            return response(["tab_id": tabID, "url": engine.url?.absoluteString ?? ""])
        case .snapshot(let tabID):
            let engine = try ownedEngine(tabID: tabID, workspaceID: workspaceID,
                                         ownerSessionID: ownerSessionID)
            return response(try await engine.automationSnapshot(tabID: tabID), createdBy: tabID)
        case .click(let target):
            let engine = try ownedEngine(tabID: target.tabID, workspaceID: workspaceID,
                                         ownerSessionID: ownerSessionID)
            try await engine.automationClick(target)
            return response(["clicked": true, "tab_id": target.tabID], createdBy: target.tabID)
        case .fill(let target, let text):
            let engine = try ownedEngine(tabID: target.tabID, workspaceID: workspaceID,
                                         ownerSessionID: ownerSessionID)
            try await engine.automationFill(target, text: text)
            return response(["filled": true, "tab_id": target.tabID], createdBy: target.tabID)
        case .type(let target, let text):
            let engine = try ownedEngine(tabID: target.tabID, workspaceID: workspaceID,
                                         ownerSessionID: ownerSessionID)
            try await engine.automationType(target, text: text)
            return response(["typed": true, "tab_id": target.tabID], createdBy: target.tabID)
        case .key(let tabID, let key):
            let engine = try ownedEngine(tabID: tabID, workspaceID: workspaceID,
                                         ownerSessionID: ownerSessionID)
            try await engine.automationKey(key)
            return response(["sent": true, "tab_id": tabID], createdBy: tabID)
        case .scroll(let tabID, let deltaX, let deltaY):
            let engine = try ownedEngine(tabID: tabID, workspaceID: workspaceID,
                                         ownerSessionID: ownerSessionID)
            var result = try await engine.automationScroll(deltaX: deltaX, deltaY: deltaY)
            result["tab_id"] = tabID
            return response(result, createdBy: tabID)
        case .wait(let tabID, let condition):
            let engine = try ownedEngine(tabID: tabID, workspaceID: workspaceID,
                                         ownerSessionID: ownerSessionID)
            try await engine.automationWait(condition)
            return response(["satisfied": true, "tab_id": tabID], createdBy: tabID)
        case .screenshot(let tabID):
            let engine = try ownedEngine(tabID: tabID, workspaceID: workspaceID,
                                         ownerSessionID: ownerSessionID)
            let data = try await engine.automationScreenshotPNG()
            return response([
                "tab_id": tabID,
                "mime_type": "image/png",
                "data_base64": data.base64EncodedString(),
            ], createdBy: tabID)
        }
    }

    @objc(handleOperation:parameters:workspaceID:ownerSessionID:completion:)
    func handle(operation: String,
                parameters: [String: Any],
                workspaceID: String,
                ownerSessionID: String,
                completion: @escaping ([String: Any]?, [String: Any]?) -> Void) {
        Task { @MainActor in
            do {
                let request = try TideyBrowserAutomationProtocol.decodeRequest(
                    workspaceID: workspaceID,
                    operation: operation,
                    parameters: parameters
                )
                let result = try await handle(request: request, ownerSessionID: ownerSessionID)
                completion(result.dictionary, nil)
            } catch let error as TideyBrowserAutomationProtocolError {
                completion(nil, error.dictionary)
            } catch {
                completion(nil, TideyBrowserAutomationProtocolError(
                    code: .internalError,
                    message: "Browser automation failed"
                ).dictionary)
            }
        }
    }

    @objc(cleanupSessionWithOwnerSessionID:)
    func cleanupSession(ownerSessionID: String) {
        cleanupSession(ownerSessionID: ownerSessionID, now: Date())
    }

    func cleanupSession(ownerSessionID: String, now: Date = Date()) {
        let plan = state.cleanupSession(ownerSessionID: ownerSessionID, now: now)
        for tabID in plan.privateTabIDsToClose {
            removePrivateEngine(tabID: tabID)
        }
        for tabID in plan.privateTabIDsToAdopt {
            guard let engine = privateEnginesByID[tabID],
                  let url = engine.url ?? privateFallbackURLsByID[tabID],
                  let host,
                  host.browserAutomationPresent(engine: engine, tabID: tabID, initialURL: url) else {
                removePrivateEngine(tabID: tabID)
                continue
            }
            privateEnginesByID.removeValue(forKey: tabID)
            privateFallbackURLsByID.removeValue(forKey: tabID)
            engine.host = host
        }
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
        if let popupTabID = try? openPrivate(
            url: request.url,
            workspaceID: parent.workspaceID,
            ownerSessionID: ownerSessionID,
            configuration: request.configuration
        ) {
            popupTabIDsByParentID[parentTabID, default: []].append(popupTabID)
        }
    }

    private func ownedEngine(tabID: String,
                             workspaceID: String,
                             ownerSessionID: String) throws -> TideyBrowserEngine {
        if state.privateTabsByID[tabID] != nil {
            _ = try mapStateError {
                try state.ownedPrivateTab(
                    tabID: tabID,
                    workspaceID: workspaceID,
                    ownerSessionID: ownerSessionID
                )
            }
            guard let engine = privateEnginesByID[tabID] else {
                throw protocolError(.targetGone, "Private browser engine is no longer available")
            }
            return engine
        }
        _ = try mapStateError {
            try state.ownedUserClaim(
                tabID: tabID,
                workspaceID: workspaceID,
                ownerSessionID: ownerSessionID
            )
        }
        guard let engine = host?.browserAutomationEngine(forTabID: tabID) else {
            throw protocolError(.targetGone, "Visible browser tab is no longer available")
        }
        return engine
    }

    private func expireHandoffs(now: Date) {
        for tabID in state.expireHandoffs(now: now) {
            removePrivateEngine(tabID: tabID)
        }
    }

    private func removePrivateEngine(tabID: String) {
        let engine = privateEnginesByID.removeValue(forKey: tabID)
        privateFallbackURLsByID.removeValue(forKey: tabID)
        popupTabIDsByParentID.removeValue(forKey: tabID)
        engine?.webView.stopLoading()
        engine?.host = nil
    }

    private func response(_ result: [String: Any],
                          createdBy parentTabID: String? = nil) -> TideyBrowserAutomationResponse {
        var result = result
        if let parentTabID,
           let created = popupTabIDsByParentID.removeValue(forKey: parentTabID),
           !created.isEmpty {
            result["tabs_created"] = created
        }
        return TideyBrowserAutomationResponse(
            result: result.mapValues(TideyBrowserAutomationValue.fromFoundation)
        )
    }

    private func mapStateError<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let error as TideyBrowserAutomationStateError {
            throw TideyBrowserAutomationProtocolError(stateError: error)
        }
    }

    private func protocolError(_ code: TideyBrowserAutomationErrorCode,
                               _ message: String) -> TideyBrowserAutomationProtocolError {
        TideyBrowserAutomationProtocolError(code: code, message: message)
    }

    private func log(_ command: TideyBrowserAutomationCommand,
                     ownerSessionID: String) {
        actionLog.append("\(ownerSessionID) \(String(describing: command).split(separator: "(").first ?? "unknown")")
        if actionLog.count > 200 {
            actionLog.removeFirst(actionLog.count - 200)
        }
    }
}
