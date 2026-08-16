import Darwin
import Foundation
import XCTest
@testable import RemoteBridge

final class BridgeMediaLeaseRegistryTests: XCTestCase {
    func testLeaseBindsOpaquePathToDescriptorRevisionAndMetadata() throws {
        let fixture = try LeaseFixture()
        let registry = fixture.makeRegistry()
        let opened = try fixture.open(contents: Data("0123456789".utf8))

        let grant = try registry.register(openedFile: opened,
                                          deviceID: "device-a",
                                          prepareID: "prepare-a",
                                          mime: "video/mp4")

        XCTAssertTrue(grant.leasePath.hasPrefix("/media/"))
        XCTAssertFalse(grant.leasePath.contains("fixture"))
        XCTAssertFalse(grant.leasePath.contains("device-a"))
        XCTAssertFalse(grant.leasePath.contains("prepare-a"))
        XCTAssertFalse(grant.leasePath.contains(opened.revisionToken))
        XCTAssertEqual(grant.expiresAt, fixture.now.addingTimeInterval(3_600))

        let authority = try XCTUnwrap(registry.checkout(opaqueToken: grant.opaqueToken))
        defer { try? authority.fileHandle.close() }
        XCTAssertEqual(authority.prepareID, "prepare-a")
        XCTAssertEqual(authority.mime, "video/mp4")
        XCTAssertEqual(authority.size, 10)
        XCTAssertEqual(authority.revisionToken, opened.revisionToken)
        XCTAssertEqual(try read(authority: authority), Data("0123456789".utf8))

        XCTAssertTrue(registry.close(prepareID: "prepare-a", deviceID: "device-a"))
        XCTAssertNil(registry.checkout(opaqueToken: grant.opaqueToken))
        XCTAssertThrowsError(try opened.fileHandle.read(upToCount: 1))
    }

    func testPerDeviceAndGlobalCapsRejectWithoutConsumingCallerDescriptor() throws {
        let fixture = try LeaseFixture()
        let registry = fixture.makeRegistry(maximumPerDevice: 2, maximumGlobal: 3)
        _ = try registry.register(openedFile: fixture.open(), deviceID: "a", prepareID: "a1", mime: "video/mp4")
        _ = try registry.register(openedFile: fixture.open(), deviceID: "a", prepareID: "a2", mime: "video/mp4")

        let rejectedPerDevice = try fixture.open()
        XCTAssertThrowsError(try registry.register(openedFile: rejectedPerDevice,
                                                   deviceID: "a",
                                                   prepareID: "a3",
                                                   mime: "video/mp4")) { error in
            XCTAssertEqual(error as? BridgeMediaLeaseRegistryError, .capacityExceeded)
        }
        XCTAssertNoThrow(try rejectedPerDevice.fileHandle.read(upToCount: 1))
        rejectedPerDevice.close()

        _ = try registry.register(openedFile: fixture.open(), deviceID: "b", prepareID: "b1", mime: "video/mp4")
        let rejectedGlobal = try fixture.open()
        XCTAssertThrowsError(try registry.register(openedFile: rejectedGlobal,
                                                   deviceID: "c",
                                                   prepareID: "c1",
                                                   mime: "video/mp4")) { error in
            XCTAssertEqual(error as? BridgeMediaLeaseRegistryError, .capacityExceeded)
        }
        XCTAssertNoThrow(try rejectedGlobal.fileHandle.read(upToCount: 1))
        rejectedGlobal.close()
    }

    func testIdleAndAbsoluteExpiryReapAndCloseDescriptors() throws {
        let fixture = try LeaseFixture()
        let registry = fixture.makeRegistry(idleTTL: 300, absoluteTTL: 900)
        let idleOpened = try fixture.open()
        let idle = try registry.register(openedFile: idleOpened,
                                         deviceID: "a",
                                         prepareID: "idle",
                                         mime: "video/mp4")
        fixture.now = fixture.now.addingTimeInterval(300)
        XCTAssertNil(registry.checkout(opaqueToken: idle.opaqueToken))
        XCTAssertThrowsError(try idleOpened.fileHandle.read(upToCount: 1))

        fixture.now = Date(timeIntervalSince1970: 2_000)
        let absoluteOpened = try fixture.open()
        let absolute = try registry.register(openedFile: absoluteOpened,
                                             deviceID: "a",
                                             prepareID: "absolute",
                                             mime: "video/mp4")
        for interval in [250.0, 500.0, 750.0] {
            fixture.now = Date(timeIntervalSince1970: 2_000 + interval)
            let authority = try XCTUnwrap(registry.checkout(opaqueToken: absolute.opaqueToken))
            try authority.fileHandle.close()
        }
        fixture.now = Date(timeIntervalSince1970: 2_900)
        XCTAssertNil(registry.checkout(opaqueToken: absolute.opaqueToken))
        XCTAssertThrowsError(try absoluteOpened.fileHandle.read(upToCount: 1))
    }

    func testDeviceRevocationAndPrepareCloseAreIdentityScoped() throws {
        let fixture = try LeaseFixture()
        let registry = fixture.makeRegistry()
        let a1 = try registry.register(openedFile: fixture.open(), deviceID: "a", prepareID: "shared", mime: "video/mp4")
        let a2 = try registry.register(openedFile: fixture.open(), deviceID: "a", prepareID: "a2", mime: "video/mp4")
        let b1 = try registry.register(openedFile: fixture.open(), deviceID: "b", prepareID: "shared", mime: "video/mp4")

        XCTAssertFalse(registry.close(prepareID: "shared", deviceID: "c"))
        XCTAssertEqual(registry.revoke(deviceID: "a"), 2)
        XCTAssertNil(registry.checkout(opaqueToken: a1.opaqueToken))
        XCTAssertNil(registry.checkout(opaqueToken: a2.opaqueToken))
        let bAuthority = try XCTUnwrap(registry.checkout(opaqueToken: b1.opaqueToken))
        try bAuthority.fileHandle.close()
        XCTAssertTrue(registry.close(prepareID: "shared", deviceID: "b"))
    }

    func testSameInodeMutationInvalidatesLeaseBeforeCheckout() throws {
        let fixture = try LeaseFixture()
        let registry = fixture.makeRegistry()
        let opened = try fixture.open(contents: Data("before".utf8))
        let grant = try registry.register(openedFile: opened,
                                          deviceID: "a",
                                          prepareID: "p",
                                          mime: "video/mp4")

        let append = try FileHandle(forWritingTo: fixture.fileURL)
        try append.seekToEnd()
        try append.write(contentsOf: Data("-changed".utf8))
        try append.close()

        XCTAssertNil(registry.checkout(opaqueToken: grant.opaqueToken))
        XCTAssertThrowsError(try opened.fileHandle.read(upToCount: 1))
    }

    func testTokenGeneratorMustProvideAtLeast128BitsWithoutConsumingDescriptor() throws {
        let fixture = try LeaseFixture()
        let registry = BridgeMediaLeaseRegistry(nowProvider: { fixture.now },
                                                tokenGenerator: { Data(repeating: 1, count: 15) })
        let opened = try fixture.open()

        XCTAssertThrowsError(try registry.register(openedFile: opened,
                                                   deviceID: "a",
                                                   prepareID: "p",
                                                   mime: "video/mp4")) { error in
            XCTAssertEqual(error as? BridgeMediaLeaseRegistryError, .secureTokenUnavailable)
        }
        XCTAssertNoThrow(try opened.fileHandle.read(upToCount: 1))
        opened.close()
    }

    private func read(authority: BridgeMediaLeaseReadAuthority) throws -> Data {
        try authority.fileHandle.withUnsafeFileDescriptor { descriptor in
            var bytes = [UInt8](repeating: 0, count: Int(authority.size))
            let count = pread(descriptor, &bytes, bytes.count, 0)
            guard count >= 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            return Data(bytes.prefix(count))
        }
    }
}

private final class LeaseFixture {
    let rootURL: URL
    let fileURL: URL
    var now = Date(timeIntervalSince1970: 1_000)
    private var tokenByte: UInt8 = 0

    init() throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("tidey-media-lease-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        fileURL = rootURL.appendingPathComponent("fixture.mp4")
    }

    deinit {
        try? FileManager.default.removeItem(at: rootURL)
    }

    func makeRegistry(maximumPerDevice: Int = 2,
                      maximumGlobal: Int = 8,
                      idleTTL: TimeInterval = 300,
                      absoluteTTL: TimeInterval = 3_600) -> BridgeMediaLeaseRegistry {
        BridgeMediaLeaseRegistry(
            limits: BridgeMediaLeaseRegistryLimits(maximumPerDevice: maximumPerDevice,
                                                   maximumGlobal: maximumGlobal,
                                                   idleTTL: idleTTL,
                                                   absoluteTTL: absoluteTTL),
            nowProvider: { self.now },
            tokenGenerator: {
                self.tokenByte &+= 1
                return Data(repeating: self.tokenByte, count: 16)
            }
        )
    }

    func open(contents: Data = Data("video".utf8)) throws -> BridgeSafeOpenedFile {
        try contents.write(to: fileURL)
        return try BridgeSafeFileOpener.openRegularFile(at: fileURL,
                                                        notFoundMessage: "missing",
                                                        outsideScopeMessage: "outside")
    }
}
