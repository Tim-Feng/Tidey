import Foundation
import WebKit

enum TideyBrowserAutomationScriptError: Error {
    case missingResource
}

enum TideyBrowserAutomationScript {
    static let resourceName = "tidey-browser-automation"
    static let contentWorld = WKContentWorld.world(name: "com.tidey.browser-automation")

    static func source(bundle: Bundle = .main) throws -> String {
        guard let url = bundle.url(forResource: resourceName, withExtension: "js") else {
            throw TideyBrowserAutomationScriptError.missingResource
        }
        return try String(contentsOf: url, encoding: .utf8)
    }
}

extension TideyBrowserEngine {
    var automationContentWorld: WKContentWorld {
        TideyBrowserAutomationScript.contentWorld
    }
}
