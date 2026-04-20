//
//  TideyBrowserEngine.swift
//  iTerm2
//

import Foundation
import WebKit

@MainActor
@objcMembers
final class TideyBrowserEngine: NSObject {
    weak var host: TideyBrowserEngineHost? {
        didSet {
            notifyStateDidChange()
        }
    }
    let webView: WKWebView
    private var observations: [NSKeyValueObservation] = []

    convenience init(host: TideyBrowserEngineHost? = nil) {
        self.init(configuration: Self.defaultConfiguration(), host: host)
    }

    init(configuration: WKWebViewConfiguration,
         host: TideyBrowserEngineHost? = nil) {
        self.host = host
        self.webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        configureStateObservations()
    }

    static func defaultConfiguration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        return configuration
    }

    var url: URL? {
        webView.url
    }

    var title: String? {
        webView.title
    }

    var isLoading: Bool {
        webView.isLoading
    }

    var canGoBack: Bool {
        webView.canGoBack
    }

    var canGoForward: Bool {
        webView.canGoForward
    }

    var state: TideyBrowserEngineState {
        TideyBrowserEngineState(currentURL: url,
                                currentTitle: title,
                                isLoading: isLoading,
                                canGoBack: canGoBack,
                                canGoForward: canGoForward)
    }

    func load(_ url: URL) {
        webView.load(URLRequest(url: url))
    }

    func goBack() {
        webView.goBack()
    }

    func goForward() {
        webView.goForward()
    }

    func reload() {
        webView.reload()
    }

    private func configureStateObservations() {
        observations = [
            webView.observe(\.url, options: [.initial, .new]) { [weak self] _, _ in
                self?.notifyStateDidChange()
            },
            webView.observe(\.title, options: [.initial, .new]) { [weak self] _, _ in
                self?.notifyStateDidChange()
            },
            webView.observe(\.isLoading, options: [.initial, .new]) { [weak self] _, _ in
                self?.notifyStateDidChange()
            },
            webView.observe(\.canGoBack, options: [.initial, .new]) { [weak self] _, _ in
                self?.notifyStateDidChange()
            },
            webView.observe(\.canGoForward, options: [.initial, .new]) { [weak self] _, _ in
                self?.notifyStateDidChange()
            }
        ]
    }

    private func notifyStateDidChange() {
        host?.browserEngine(self, didUpdateState: state)
    }
}

extension TideyBrowserEngine: WKNavigationDelegate {
}

extension TideyBrowserEngine: WKUIDelegate {
    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let url = navigationAction.request.url else {
            return nil
        }
        let request = TideyBrowserPopupRequest(url: url,
                                               configuration: configuration,
                                               opensInNewBrowsingContext: navigationAction.targetFrame == nil)
        host?.browserEngine(self, requestPopup: request)
        return nil
    }
}
