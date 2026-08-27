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
}
