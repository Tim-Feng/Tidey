import XCTest
@testable import RemoteBridge

final class BridgeProcessRuntimeConfigurationTests: XCTestCase {
    func testDefaultConfigurationUsesProductionPortAndServices() {
        let config = BridgeProcessRuntimeConfiguration.from(environment: [:])

        XCTAssertEqual(config.host, "0.0.0.0")
        XCTAssertEqual(config.port, 4817)
        XCTAssertFalse(config.devIsolated)
        XCTAssertTrue(config.shouldStartBackgroundServices)
        XCTAssertTrue(config.shouldStartRegistryMonitor)
        XCTAssertTrue(config.shouldStartCloudflaredSupervisor)
        XCTAssertFalse(config.shouldServeHeadlessCodexStandalone)
    }

    func testDevIsolatedConfigurationCanUseSeparatePortWithoutBackgroundServices() {
        let config = BridgeProcessRuntimeConfiguration.from(environment: [
            "TIDEY_REMOTE_BRIDGE_HOST": "127.0.0.1",
            "TIDEY_REMOTE_BRIDGE_PORT": "4917",
            "TIDEY_REMOTE_BRIDGE_DEV_ISOLATED": "1",
        ])

        XCTAssertEqual(config.host, "127.0.0.1")
        XCTAssertEqual(config.port, 4917)
        XCTAssertTrue(config.devIsolated)
        XCTAssertFalse(config.shouldStartBackgroundServices)
        XCTAssertFalse(config.shouldStartRegistryMonitor)
        XCTAssertFalse(config.shouldStartCloudflaredSupervisor)
        XCTAssertTrue(config.shouldServeHeadlessCodexStandalone)
    }

    func testInvalidPortFallsBackToProductionPort() {
        let config = BridgeProcessRuntimeConfiguration.from(environment: [
            "TIDEY_REMOTE_BRIDGE_PORT": "not-a-port",
        ])

        XCTAssertEqual(config.port, 4817)
    }
}
