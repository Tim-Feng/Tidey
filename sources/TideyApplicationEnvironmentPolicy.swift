import Foundation

@objcMembers
final class TideyApplicationEnvironmentPolicy: NSObject {
    static let productionBundleIdentifier = "com.tidey.app"
    static let developmentBundleIdentifier = "com.tidey.app.dev"

    static func allowsProductionIntegrations(bundleIdentifier: String?) -> Bool {
        bundleIdentifier == productionBundleIdentifier
    }

    static var currentAllowsProductionIntegrations: Bool {
        allowsProductionIntegrations(bundleIdentifier: Bundle.main.bundleIdentifier)
    }

    static func isDevelopment(bundleIdentifier: String?) -> Bool {
        bundleIdentifier == developmentBundleIdentifier
    }

    static var currentIsDevelopment: Bool {
        isDevelopment(bundleIdentifier: Bundle.main.bundleIdentifier)
    }

    @objc(shouldOfferShellIntegrationPromptWithBundleIdentifier:isRunningUnitTests:)
    static func shouldOfferShellIntegrationPrompt(bundleIdentifier: String?,
                                                  isRunningUnitTests: Bool) -> Bool {
        allowsProductionIntegrations(bundleIdentifier: bundleIdentifier) && !isRunningUnitTests
    }
}
