//
//  TideyBrowserEngineHost.swift
//  iTerm2
//

import Foundation
import WebKit

@MainActor
@objcMembers
final class TideyBrowserEngineState: NSObject {
    let currentURL: URL?
    let currentTitle: String?
    let isLoading: Bool
    let canGoBack: Bool
    let canGoForward: Bool

    init(currentURL: URL?,
         currentTitle: String?,
         isLoading: Bool,
         canGoBack: Bool,
         canGoForward: Bool) {
        self.currentURL = currentURL
        self.currentTitle = currentTitle
        self.isLoading = isLoading
        self.canGoBack = canGoBack
        self.canGoForward = canGoForward
    }
}

@MainActor
@objcMembers
final class TideyBrowserPopupRequest: NSObject {
    let url: URL
    let configuration: WKWebViewConfiguration
    let opensInNewBrowsingContext: Bool

    init(url: URL,
         configuration: WKWebViewConfiguration,
         opensInNewBrowsingContext: Bool) {
        self.url = url
        self.configuration = configuration
        self.opensInNewBrowsingContext = opensInNewBrowsingContext
    }
}

@MainActor
@objc
protocol TideyBrowserEngineHost: AnyObject {
    func browserEngine(_ engine: TideyBrowserEngine,
                       didUpdateState state: TideyBrowserEngineState)
    func browserEngine(_ engine: TideyBrowserEngine,
                       requestPopup request: TideyBrowserPopupRequest)
}
