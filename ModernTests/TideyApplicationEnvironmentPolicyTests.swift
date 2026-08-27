import AppKit
import XCTest
@testable import iTerm2SharedARC

final class TideyApplicationEnvironmentPolicyTests: XCTestCase {
    func testOnlyExactProductionBundleMayUseProductionIntegrations() {
        XCTAssertTrue(
            TideyApplicationEnvironmentPolicy.allowsProductionIntegrations(
                bundleIdentifier: "com.tidey.app"
            )
        )
        XCTAssertFalse(
            TideyApplicationEnvironmentPolicy.allowsProductionIntegrations(
                bundleIdentifier: "com.tidey.app.dev"
            )
        )
        XCTAssertFalse(
            TideyApplicationEnvironmentPolicy.allowsProductionIntegrations(
                bundleIdentifier: "com.tidey.app.preview"
            )
        )
        XCTAssertFalse(
            TideyApplicationEnvironmentPolicy.allowsProductionIntegrations(
                bundleIdentifier: nil
            )
        )
    }

    func testDevelopmentIdentityIsExact() {
        XCTAssertTrue(
            TideyApplicationEnvironmentPolicy.isDevelopment(
                bundleIdentifier: "com.tidey.app.dev"
            )
        )
        XCTAssertFalse(
            TideyApplicationEnvironmentPolicy.isDevelopment(
                bundleIdentifier: "com.tidey.app"
            )
        )
        XCTAssertFalse(
            TideyApplicationEnvironmentPolicy.isDevelopment(bundleIdentifier: nil)
        )
    }

    func testShellIntegrationPromptRequiresProductionOutsideUnitTests() {
        XCTAssertTrue(
            TideyApplicationEnvironmentPolicy.shouldOfferShellIntegrationPrompt(
                bundleIdentifier: "com.tidey.app",
                isRunningUnitTests: false
            )
        )
        XCTAssertFalse(
            TideyApplicationEnvironmentPolicy.shouldOfferShellIntegrationPrompt(
                bundleIdentifier: "com.tidey.app.dev",
                isRunningUnitTests: false
            )
        )
        XCTAssertFalse(
            TideyApplicationEnvironmentPolicy.shouldOfferShellIntegrationPrompt(
                bundleIdentifier: "com.tidey.app",
                isRunningUnitTests: true
            )
        )
    }

    func testRemoteSettingsAreDisabledInDevelopmentHost() throws {
        XCTAssertFalse(TideyApplicationEnvironmentPolicy.currentAllowsProductionIntegrations)
        guard let controllerType = NSClassFromString("TideyRemoteSettingsViewController") as? NSObject.Type,
              let controller = controllerType.init() as? NSViewController else {
            return XCTFail("TideyRemoteSettingsViewController is unavailable")
        }

        _ = controller.view

        let setupLabel = try XCTUnwrap(controller.value(forKey: "bridgeSetupLabel") as? NSTextField)
        let refreshButton = try XCTUnwrap(controller.value(forKey: "refreshButton") as? NSButton)
        let reinstallButton = try XCTUnwrap(controller.value(forKey: "reinstallBridgeButton") as? NSButton)
        let revealButton = try XCTUnwrap(controller.value(forKey: "uploadsRevealButton") as? NSButton)
        let cleanButton = try XCTUnwrap(controller.value(forKey: "uploadsCleanButton") as? NSButton)

        XCTAssertEqual(setupLabel.stringValue, "Tidey Remote is unavailable in Tidey Dev.")
        XCTAssertFalse(refreshButton.isEnabled)
        XCTAssertFalse(reinstallButton.isEnabled)
        XCTAssertFalse(revealButton.isEnabled)
        XCTAssertFalse(cleanButton.isEnabled)
    }
}
