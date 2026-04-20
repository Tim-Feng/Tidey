//
//  iTermBrowserSessionEngineAdapter.swift
//  iTerm2
//

import WebKit

@MainActor
final class iTermBrowserSessionEngineAdapter: TideyBrowserNavigationEngine {
    private unowned let manager: iTermBrowserManager

    init(manager: iTermBrowserManager) {
        self.manager = manager
    }

    var webView: WKWebView {
        manager.webView
    }

    var url: URL? {
        manager.webView.url
    }

    var title: String? {
        manager.webView.title
    }

    var isLoading: Bool {
        manager.webView.isLoading
    }

    var canGoBack: Bool {
        manager.webView.canGoBack
    }

    var canGoForward: Bool {
        manager.webView.canGoForward
    }

    func load(_ url: URL) {
        manager.loadURL(url, continuation: nil)
    }

    func goBack() {
        manager.goBack()
    }

    func goForward() {
        manager.goForward()
    }

    func reload() {
        manager.reload()
    }
}
