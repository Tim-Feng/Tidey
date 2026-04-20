//
//  TideyBrowserEngineHost.swift
//  iTerm2
//

import Foundation
import WebKit

@MainActor
protocol TideyBrowserEngineHost: AnyObject {
    func browserEngine(_ engine: TideyBrowserEngine,
                       requestOpenNewTabFor url: URL,
                       configuration: WKWebViewConfiguration)
}
