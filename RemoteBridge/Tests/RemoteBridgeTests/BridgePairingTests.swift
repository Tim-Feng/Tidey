import Foundation
import XCTest
@testable import RemoteBridge

final class BridgePairingTests: XCTestCase {
    func testPairPayloadUsesStableHostIdentityAndShortLivedSecret() throws {
        let fixture = try PairingFixture()
        let endpoint = BridgePairEndpoint(scheme: "ws",
                                          host: "192.168.1.23",
                                          port: 4817,
                                          path: "/")

        let identity = try fixture.hostIdentityStore.loadOrCreateIdentity()
        let payload = try fixture.pairSessionStore.createPayload(hostIdentity: identity,
                                                                 lanEndpoints: [endpoint])

        XCTAssertEqual(identity.hostID, "host-1")
        XCTAssertEqual(identity.displayName, "Tim's Mac")
        XCTAssertEqual(payload.type, "tidey_remote_pair")
        XCTAssertEqual(payload.version, 1)
        XCTAssertEqual(payload.hostID, "host-1")
        XCTAssertEqual(payload.displayName, "Tim's Mac")
        XCTAssertEqual(payload.lanEndpoints, [endpoint])
        XCTAssertNil(payload.tunnelEndpoint)
        XCTAssertEqual(payload.pairSecret, "pair-secret-1")
        XCTAssertEqual(payload.issuedAt, fixture.startDate)
        XCTAssertEqual(payload.expiresAt, fixture.startDate.addingTimeInterval(300))

        let reloadedStore = BridgeHostIdentityStore(paths: fixture.paths,
                                                    fileManager: fixture.fileManager,
                                                    idProvider: { "host-2" },
                                                    displayNameProvider: { "Other Mac" })
        let reloadedIdentity = try reloadedStore.loadOrCreateIdentity()
        XCTAssertEqual(reloadedIdentity.hostID, "host-1")
        XCTAssertEqual(reloadedIdentity.displayName, "Tim's Mac")
    }

    func testPairExchangeIssuesDeviceCredentialAndConsumesSecret() throws {
        let fixture = try PairingFixture()
        let payload = try fixture.controller.createPairPayload(lanEndpoints: [])

        let result = try fixture.controller.exchange(BridgePairExchangeRequest(action: "pair.exchange",
                                                                               hostID: payload.hostID,
                                                                               pairSecret: payload.pairSecret,
                                                                               deviceName: "Tim's iPhone",
                                                                               devicePublicKey: "public-key"))

        XCTAssertEqual(result.hostID, "host-1")
        XCTAssertEqual(result.displayName, "Tim's Mac")
        XCTAssertEqual(result.deviceCredential, "device-token-1")
        XCTAssertEqual(result.credentialType, "bearer")
        XCTAssertTrue(try fixture.deviceCredentialStore.isValidCredential("device-token-1"))

        XCTAssertThrowsError(try fixture.controller.exchange(BridgePairExchangeRequest(action: "pair.exchange",
                                                                                      hostID: payload.hostID,
                                                                                      pairSecret: payload.pairSecret,
                                                                                      deviceName: "Tim's iPhone",
                                                                                      devicePublicKey: nil))) { error in
            guard case BridgeInternalError.unauthorized = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testPairExchangeRejectsWrongOrExpiredSecret() throws {
        let fixture = try PairingFixture()
        let payload = try fixture.controller.createPairPayload(lanEndpoints: [])

        XCTAssertThrowsError(try fixture.controller.exchange(BridgePairExchangeRequest(action: "pair.exchange",
                                                                                      hostID: payload.hostID,
                                                                                      pairSecret: "wrong-secret",
                                                                                      deviceName: "Tim's iPhone",
                                                                                      devicePublicKey: nil))) { error in
            guard case BridgeInternalError.unauthorized = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        fixture.now = payload.expiresAt.addingTimeInterval(1)
        XCTAssertThrowsError(try fixture.controller.exchange(BridgePairExchangeRequest(action: "pair.exchange",
                                                                                      hostID: payload.hostID,
                                                                                      pairSecret: payload.pairSecret,
                                                                                      deviceName: "Tim's iPhone",
                                                                                      devicePublicKey: nil))) { error in
            guard case BridgeInternalError.unauthorized = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testBridgeAuthenticatorAcceptsLegacyTokenAndDeviceCredential() throws {
        let fixture = try PairingFixture()
        _ = try fixture.deviceCredentialStore.issueCredential(deviceName: "Tim's iPhone")
        let authenticator = BridgeAuthenticator(legacyPairToken: "legacy-token",
                                                deviceCredentialStore: fixture.deviceCredentialStore)

        XCTAssertTrue(authenticator.isAuthorized(authorizationHeader: "Bearer legacy-token"))
        XCTAssertTrue(authenticator.isAuthorized(authorizationHeader: "Bearer device-token-1"))
        XCTAssertFalse(authenticator.isAuthorized(authorizationHeader: "Bearer unknown-token"))
        XCTAssertFalse(authenticator.isAuthorized(authorizationHeader: nil))
    }

    func testDeviceCredentialStoreListsTouchesAndRevokesPairedDevices() throws {
        let fixture = try PairingFixture()
        let credential = try fixture.deviceCredentialStore.issueCredential(deviceName: "Tim's iPhone")

        var devices = try fixture.deviceCredentialStore.listDevices()
        let device = try XCTUnwrap(devices.first)
        XCTAssertEqual(devices.count, 1)
        XCTAssertEqual(device.deviceID, credential.deviceID)
        XCTAssertEqual(device.deviceName, "Tim's iPhone")
        XCTAssertEqual(device.pairedAt, fixture.startDate)
        XCTAssertNil(device.lastConnectedAt)

        fixture.now = fixture.startDate.addingTimeInterval(42)
        XCTAssertTrue(try fixture.deviceCredentialStore.isValidCredential(credential.token))
        devices = try fixture.deviceCredentialStore.listDevices()
        XCTAssertEqual(devices.first?.lastConnectedAt, fixture.now)

        XCTAssertTrue(try fixture.deviceCredentialStore.revokeDevice(deviceID: credential.deviceID))
        XCTAssertTrue(try fixture.deviceCredentialStore.listDevices().isEmpty)
        XCTAssertFalse(try fixture.deviceCredentialStore.isValidCredential(credential.token))
    }

    func testRevokingDeviceCredentialDoesNotInvalidateLegacyPairToken() throws {
        let fixture = try PairingFixture()
        let credential = try fixture.deviceCredentialStore.issueCredential(deviceName: "Tim's iPhone")
        let authenticator = BridgeAuthenticator(legacyPairToken: "legacy-token",
                                                deviceCredentialStore: fixture.deviceCredentialStore)

        XCTAssertTrue(try fixture.deviceCredentialStore.revokeDevice(deviceID: credential.deviceID))

        XCTAssertTrue(authenticator.isAuthorized(authorizationHeader: "Bearer legacy-token"))
        XCTAssertFalse(authenticator.isAuthorized(authorizationHeader: "Bearer \(credential.token)"))
    }

    func testPairSessionsRejectExpiredSecretButPruneAfterGracePeriod() throws {
        let fixture = try PairingFixture()
        let identity = try fixture.hostIdentityStore.loadOrCreateIdentity()
        let payload = try fixture.pairSessionStore.createPayload(hostIdentity: identity, lanEndpoints: [])

        fixture.now = payload.expiresAt.addingTimeInterval(1)
        XCTAssertThrowsError(try fixture.pairSessionStore.consume(pairSecret: payload.pairSecret,
                                                                  hostID: payload.hostID)) { error in
            guard case BridgeInternalError.unauthorized = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertEqual(fixture.pairSessionStore.activeSessionCount(), 1)

        fixture.now = payload.expiresAt.addingTimeInterval(31)
        XCTAssertEqual(fixture.pairSessionStore.activeSessionCount(), 0)
    }

    func testLANEndpointResolverIncludesReachableIPv4Interfaces() {
        let candidates = [
            BridgeLANEndpointCandidate(interfaceName: "lo0",
                                       host: "127.0.0.1",
                                       addressFamily: .ipv4,
                                       isUp: true,
                                       isRunning: true,
                                       isLoopback: true),
            BridgeLANEndpointCandidate(interfaceName: "en0",
                                       host: "10.0.1.7",
                                       addressFamily: .ipv4,
                                       isUp: true,
                                       isRunning: true,
                                       isLoopback: false),
            BridgeLANEndpointCandidate(interfaceName: "en1",
                                       host: "192.168.1.112",
                                       addressFamily: .ipv4,
                                       isUp: true,
                                       isRunning: true,
                                       isLoopback: false),
            BridgeLANEndpointCandidate(interfaceName: "utun1",
                                       host: "100.74.239.4",
                                       addressFamily: .ipv4,
                                       isUp: true,
                                       isRunning: true,
                                       isLoopback: false),
            BridgeLANEndpointCandidate(interfaceName: "bridge100",
                                       host: "172.16.0.2",
                                       addressFamily: .ipv4,
                                       isUp: true,
                                       isRunning: true,
                                       isLoopback: false),
            BridgeLANEndpointCandidate(interfaceName: "en2",
                                       host: "169.254.12.10",
                                       addressFamily: .ipv4,
                                       isUp: true,
                                       isRunning: true,
                                       isLoopback: false),
            BridgeLANEndpointCandidate(interfaceName: "en3",
                                       host: "10.0.0.42",
                                       addressFamily: .ipv4,
                                       isUp: false,
                                       isRunning: true,
                                       isLoopback: false),
            BridgeLANEndpointCandidate(interfaceName: "en4",
                                       host: "10.0.0.43",
                                       addressFamily: .ipv4,
                                       isUp: true,
                                       isRunning: false,
                                       isLoopback: false),
            BridgeLANEndpointCandidate(interfaceName: "anpi0",
                                       host: "192.168.64.1",
                                       addressFamily: .ipv4,
                                       isUp: true,
                                       isRunning: true,
                                       isLoopback: false),
            BridgeLANEndpointCandidate(interfaceName: "awdl0",
                                       host: "192.168.64.2",
                                       addressFamily: .ipv4,
                                       isUp: true,
                                       isRunning: true,
                                       isLoopback: false),
            BridgeLANEndpointCandidate(interfaceName: "gif0",
                                       host: "192.168.64.3",
                                       addressFamily: .ipv4,
                                       isUp: true,
                                       isRunning: true,
                                       isLoopback: false),
            BridgeLANEndpointCandidate(interfaceName: "stf0",
                                       host: "192.168.64.4",
                                       addressFamily: .ipv4,
                                       isUp: true,
                                       isRunning: true,
                                       isLoopback: false),
            BridgeLANEndpointCandidate(interfaceName: "en0",
                                       host: "fd12:3456:789a::1",
                                       addressFamily: .ipv6,
                                       isUp: true,
                                       isRunning: true,
                                       isLoopback: false),
        ]

        let endpoints = BridgeLANEndpointResolver.endpoints(from: candidates, port: 4817)

        XCTAssertEqual(endpoints, [
            BridgePairEndpoint(scheme: "ws", host: "10.0.1.7", port: 4817, path: "/"),
            BridgePairEndpoint(scheme: "ws", host: "192.168.1.112", port: 4817, path: "/"),
            BridgePairEndpoint(scheme: "ws", host: "100.74.239.4", port: 4817, path: "/"),
            BridgePairEndpoint(scheme: "ws", host: "172.16.0.2", port: 4817, path: "/"),
        ])
    }

    func testPairPayloadQRCodeStringDecodesToRawPairPayload() throws {
        let fixture = try PairingFixture()
        let endpoint = BridgePairEndpoint(scheme: "ws",
                                          host: "192.168.1.23",
                                          port: 4817,
                                          path: "/")
        let payload = try fixture.controller.createPairPayload(lanEndpoints: [endpoint])

        let qrPayload = try BridgePairPayloadQRCodeEncoder.qrPayloadString(for: payload)
        let data = try XCTUnwrap(BridgePairPayloadQRCodeEncoder.decodeQRCodePayloadString(qrPayload))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(BridgePairPayload.self, from: data)

        XCTAssertEqual(decoded, payload)
        XCTAssertFalse(qrPayload.contains("+"))
        XCTAssertFalse(qrPayload.contains("/"))
        XCTAssertFalse(qrPayload.contains("="))
    }
}

private final class PairingFixture {
    let fileManager = FileManager.default
    let tempDirectory: URL
    let paths: BridgePaths
    let startDate = Date(timeIntervalSince1970: 1_775_000_000)
    let clock: MutableClock
    let hostIdentityStore: BridgeHostIdentityStore
    let pairSessionStore: BridgePairSessionStore
    let deviceCredentialStore: BridgeDeviceCredentialStore
    let controller: BridgePairingController

    init() throws {
        tempDirectory = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        paths = BridgePaths(supportDirectory: tempDirectory)
        clock = MutableClock(now: startDate)
        let clock = self.clock
        hostIdentityStore = BridgeHostIdentityStore(paths: paths,
                                                    fileManager: fileManager,
                                                    idProvider: { "host-1" },
                                                    displayNameProvider: { "Tim's Mac" })
        pairSessionStore = BridgePairSessionStore(secretGenerator: { "pair-secret-1" },
                                                  nowProvider: { clock.now },
                                                  lifetime: 300)
        deviceCredentialStore = BridgeDeviceCredentialStore(paths: paths,
                                                            fileManager: fileManager,
                                                            tokenGenerator: { "device-token-1" },
                                                            nowProvider: { clock.now })
        controller = BridgePairingController(hostIdentityStore: hostIdentityStore,
                                             pairSessionStore: pairSessionStore,
                                             deviceCredentialStore: deviceCredentialStore)
    }

    var now: Date {
        get { clock.now }
        set { clock.now = newValue }
    }
}

private final class MutableClock {
    var now: Date

    init(now: Date) {
        self.now = now
    }
}
