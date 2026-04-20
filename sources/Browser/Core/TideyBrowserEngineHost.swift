//
//  TideyBrowserEngineHost.swift
//  iTerm2
//

import Foundation
import WebKit

@MainActor
struct TideyBrowserEngineState: Equatable {
    let currentURL: URL?
    let currentTitle: String?
    let isLoading: Bool
    let canGoBack: Bool
    let canGoForward: Bool
}

@MainActor
protocol TideyBrowserEngineHost: AnyObject {
    func browserEngine(_ engine: TideyBrowserEngine,
                       didUpdateState state: TideyBrowserEngineState)
    func browserEngine(_ engine: TideyBrowserEngine,
                       requestOpenNewTabFor url: URL,
                       configuration: WKWebViewConfiguration)
}
