import Foundation
import XCTest
@testable import RemoteBridge

final class BridgeResolverPublicationMonitorTests: XCTestCase {
    func testPublishesOnlineTunnelEndpointOnFirstPoll() {
        let fixture = PublicationMonitorFixture()

        fixture.monitor.pollOnce()

        XCTAssertEqual(fixture.publisher.publishedEndpoints, [fixture.firstEndpoint])
    }

    func testSkipsUnchangedEndpointBeforeHeartbeatInterval() {
        let fixture = PublicationMonitorFixture()

        fixture.monitor.pollOnce()
        fixture.now = fixture.startDate.addingTimeInterval(119)
        fixture.monitor.pollOnce()

        XCTAssertEqual(fixture.publisher.publishedEndpoints, [fixture.firstEndpoint])
    }

    func testPublishesChangedEndpointImmediately() {
        let fixture = PublicationMonitorFixture()
        fixture.monitor.pollOnce()
        fixture.statusReader.status = BridgeCloudflaredStatus(state: .online,
                                                              endpoint: fixture.secondEndpoint,
                                                              errorMessage: nil,
                                                              updatedAt: fixture.startDate.addingTimeInterval(1),
                                                              processID: 101)

        fixture.monitor.pollOnce()

        XCTAssertEqual(fixture.publisher.publishedEndpoints, [
            fixture.firstEndpoint,
            fixture.secondEndpoint,
        ])
    }

    func testRepublishesUnchangedEndpointAfterHeartbeatInterval() {
        let fixture = PublicationMonitorFixture()
        fixture.monitor.pollOnce()
        fixture.now = fixture.startDate.addingTimeInterval(120)

        fixture.monitor.pollOnce()

        XCTAssertEqual(fixture.publisher.publishedEndpoints, [
            fixture.firstEndpoint,
            fixture.firstEndpoint,
        ])
    }

    func testPublishFailureDoesNotAdvanceLastPublishedState() {
        let fixture = PublicationMonitorFixture()
        fixture.publisher.nextError = BridgeResolverPublishError.transport("offline")

        fixture.monitor.pollOnce()
        fixture.monitor.pollOnce()

        XCTAssertEqual(fixture.publisher.publishedEndpoints, [
            fixture.firstEndpoint,
            fixture.firstEndpoint,
        ])
    }

    func testSkipsOfflineCloudflaredStatus() {
        let fixture = PublicationMonitorFixture()
        fixture.statusReader.status = BridgeCloudflaredStatus(state: .starting,
                                                              endpoint: nil,
                                                              errorMessage: nil,
                                                              updatedAt: fixture.startDate,
                                                              processID: nil)

        fixture.monitor.pollOnce()

        XCTAssertEqual(fixture.publisher.publishedEndpoints, [])
    }
}

private final class PublicationMonitorFixture {
    let startDate = Date(timeIntervalSince1970: 1_775_100_000)
    let firstEndpoint = BridgePairEndpoint(scheme: "wss",
                                           host: "first.trycloudflare.com",
                                           port: nil,
                                           path: "/")
    let secondEndpoint = BridgePairEndpoint(scheme: "wss",
                                            host: "second.trycloudflare.com",
                                            port: nil,
                                            path: "/")
    let statusReader: FakeCloudflaredStatusReader
    let publisher = FakeTunnelEndpointPublisher()
    lazy var monitor = BridgeResolverPublicationMonitor(statusReader: statusReader,
                                                        publisher: publisher,
                                                        heartbeatInterval: 120,
                                                        nowProvider: { self.now })
    var now: Date

    init() {
        now = startDate
        statusReader = FakeCloudflaredStatusReader(status: BridgeCloudflaredStatus(state: .online,
                                                                                   endpoint: firstEndpoint,
                                                                                   errorMessage: nil,
                                                                                   updatedAt: startDate,
                                                                                   processID: 100))
    }
}

private final class FakeCloudflaredStatusReader: BridgeCloudflaredStatusReading {
    var status: BridgeCloudflaredStatus

    init(status: BridgeCloudflaredStatus) {
        self.status = status
    }

    func readStatus() throws -> BridgeCloudflaredStatus {
        status
    }
}

private final class FakeTunnelEndpointPublisher: BridgeTunnelEndpointPublishing {
    var publishedEndpoints = [BridgePairEndpoint]()
    var nextError: Error?

    func publishTunnelEndpoint(_ endpoint: BridgePairEndpoint) throws {
        publishedEndpoints.append(endpoint)
        if let error = nextError {
            nextError = nil
            throw error
        }
    }
}
