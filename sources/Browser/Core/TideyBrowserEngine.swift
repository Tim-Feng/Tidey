//
//  TideyBrowserEngine.swift
//  iTerm2
//

import Foundation
import WebKit

@MainActor
final class TideyBrowserEngine: NSObject {
    weak var host: TideyBrowserEngineHost?
    let webView: WKWebView

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
        host?.browserEngine(self,
                            requestOpenNewTabFor: url,
                            configuration: configuration)
        return nil
    }
}
