import Foundation
import XCTest
@testable import RemoteBridge

final class BridgeResolverPublisherTests: XCTestCase {
    func testPublishSecretPersistsAcrossStoreReloads() throws {
        let fixture = try ResolverFixture()

        let first = try fixture.publishSecretStore.loadOrCreateSecret()
        let second = try BridgeResolverPublishSecretStore(paths: fixture.paths).loadOrCreateSecret()

        XCTAssertEqual(first, "resolver-secret-1")
        XCTAssertEqual(second, first)
    }

    func testPublisherSendsResolverPayloadWithBearerSecret() throws {
        let fixture = try ResolverFixture()
        let endpoint = BridgePairEndpoint(scheme: "wss",
                                          host: "fresh-url.trycloudflare.com",
                                          port: nil,
                                          path: "/")
        let client = FakeResolverClient()
        let publisher = BridgeResolverPublisher(resolverBaseURL: URL(string: "https://resolver.example")!,
                                                hostIdentityStore: fixture.hostIdentityStore,
                                                publishSecretStore: fixture.publishSecretStore,
                                                client: client,
                                                nowProvider: { fixture.startDate },
                                                lifetime: 10 * 60)

        try publisher.publishTunnelEndpoint(endpoint)

        let request = try XCTUnwrap(client.requests.first)
        XCTAssertEqual(request.url, URL(string: "https://resolver.example/v1/resolver/hosts/host-1/tunnel")!)
        XCTAssertEqual(request.bearerToken, "resolver-secret-1")
        XCTAssertEqual(request.payload.schemaVersion, 1)
        XCTAssertEqual(request.payload.hostID, "host-1")
        XCTAssertEqual(request.payload.tunnelEndpoint, endpoint)
        XCTAssertEqual(request.payload.publishedAt, fixture.startDate)
        XCTAssertEqual(request.payload.expiresAt, fixture.startDate.addingTimeInterval(600))
    }

    func testPublisherClassifiesUnauthorizedResolverFailure() throws {
        let fixture = try ResolverFixture()
        let client = FakeResolverClient(result: .failure(.unauthorized))
        let publisher = BridgeResolverPublisher(resolverBaseURL: URL(string: "https://resolver.example")!,
                                                hostIdentityStore: fixture.hostIdentityStore,
                                                publishSecretStore: fixture.publishSecretStore,
                                                client: client,
                                                nowProvider: { fixture.startDate },
                                                lifetime: 10 * 60)

        XCTAssertThrowsError(try publisher.publishTunnelEndpoint(BridgePairEndpoint(scheme: "wss",
                                                                                   host: "fresh-url.trycloudflare.com",
                                                                                   port: nil,
                                                                                   path: "/"))) { error in
            XCTAssertEqual(error as? BridgeResolverPublishError, .unauthorized)
        }
    }
}

private final class ResolverFixture {
    let fileManager = FileManager.default
    let tempDirectory: URL
    let paths: BridgePaths
    let startDate = Date(timeIntervalSince1970: 1_775_000_000)
    let hostIdentityStore: BridgeHostIdentityStore
    let publishSecretStore: BridgeResolverPublishSecretStore

    init() throws {
        tempDirectory = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        paths = BridgePaths(supportDirectory: tempDirectory)
        hostIdentityStore = BridgeHostIdentityStore(paths: paths,
                                                    fileManager: fileManager,
                                                    idProvider: { "host-1" },
                                                    displayNameProvider: { "Tim's Mac" })
        publishSecretStore = BridgeResolverPublishSecretStore(paths: paths,
                                                              tokenGenerator: { "resolver-secret-1" })
    }

    deinit {
        try? fileManager.removeItem(at: tempDirectory)
    }
}

private final class FakeResolverClient: BridgeResolverClient {
    var requests = [BridgeResolverPublishRequest]()
    let result: Result<Void, BridgeResolverPublishError>

    init(result: Result<Void, BridgeResolverPublishError> = .success(())) {
        self.result = result
    }

    func publish(_ request: BridgeResolverPublishRequest) throws {
        requests.append(request)
        switch result {
        case .success:
            return
        case .failure(let error):
            throw error
        }
    }
}
