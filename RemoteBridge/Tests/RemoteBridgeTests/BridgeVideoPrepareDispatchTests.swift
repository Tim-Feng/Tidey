import Foundation
import XCTest
@testable import RemoteBridge

final class BridgeVideoPrepareDispatchTests: XCTestCase {
    func testConnectionTrackerRevokesOwnedAndLatePrepareLeasesOnSocketLoss() throws {
        let fixture = try VideoDispatchFixture()
        let registry = BridgeMediaLeaseRegistry(tokenGenerator: { Data(repeating: 9, count: 16) })
        let tracker = BridgeVideoPreviewConnectionLeaseTracker(deviceID: "device-a",
                                                               leaseRegistry: registry)
        let firstGrant = try registry.register(
            openedFile: fixture.open(),
            deviceID: "device-a",
            prepareID: "prepare-live",
            mime: "video/mp4"
        )
        let liveResult = BridgeVideoPreviewActionResult(
            response: BridgeResponse(id: "1", ok: true, result: nil, error: nil),
            registeredPrepareID: "prepare-live",
            deviceID: "device-a"
        )
        XCTAssertTrue(tracker.accept(liveResult, connectionIsActive: true))
        tracker.retire()
        XCTAssertNil(registry.checkout(opaqueToken: firstGrant.opaqueToken))

        let lateGrant = try registry.register(openedFile: fixture.open(),
                                              deviceID: "device-a",
                                              prepareID: "prepare-late",
                                              mime: "video/mp4")
        let lateResult = BridgeVideoPreviewActionResult(
            response: BridgeResponse(id: "2", ok: true, result: nil, error: nil),
            registeredPrepareID: "prepare-late",
            deviceID: "device-a"
        )
        XCTAssertFalse(tracker.accept(lateResult, connectionIsActive: false))
        XCTAssertNil(registry.checkout(opaqueToken: lateGrant.opaqueToken))
    }

    func testDirectPrepareIssuesDescriptorLeaseAndCloseRevokesIt() async throws {
        let fixture = try VideoDispatchFixture()
        let registry = BridgeMediaLeaseRegistry(tokenGenerator: { Data(repeating: 7, count: 16) })
        let opened = try fixture.open()
        let handler = BridgeVideoPreviewActionHandler(
            leaseRegistry: registry,
            prepareIDGenerator: { "prepare-direct" },
            prepare: { _, _, _ in
                BridgeVideoPreparedSource(result: fixture.probeResult(route: .direct), openedFile: opened)
            }
        )

        let prepareResult = await handler.handle(fixture.prepareRequest,
                                                 principal: .device(id: "device-a"))
        let prepare = try XCTUnwrap(prepareResult)
        XCTAssertTrue(prepare.response.ok)
        XCTAssertEqual(prepare.response.result?["state"]?.stringValue, "ready")
        XCTAssertEqual(prepare.response.result?["route"]?.stringValue, "direct")
        XCTAssertEqual(prepare.response.result?["prepare_id"]?.stringValue, "prepare-direct")
        XCTAssertEqual(prepare.response.result?["accepts_ranges"]?.boolValue, true)
        let leasePath = try XCTUnwrap(prepare.response.result?["lease_path"]?.stringValue)
        let token = String(leasePath.dropFirst("/media/".count))
        let authority = try XCTUnwrap(registry.checkout(opaqueToken: token))
        try authority.fileHandle.close()

        let closeRequest = BridgeRequest(id: "close-1",
                                         action: BridgeVideoPreviewProtocolV1.closeAction,
                                         params: ["prepare_id": .string("prepare-direct")])
        let closeResult = await handler.handle(closeRequest,
                                               principal: .device(id: "device-a"))
        let close = try XCTUnwrap(closeResult)
        XCTAssertTrue(close.response.ok)
        XCTAssertEqual(close.response.result?["closed"]?.boolValue, true)
        XCTAssertNil(registry.checkout(opaqueToken: token))
    }

    func testConversionAndUnsupportedStatesNeverIssueLease() async throws {
        for (route, state) in [
            (BridgeVideoPreviewRoute.transcode, "conversion_required"),
            (.unsupported, "unsupported"),
        ] {
            let fixture = try VideoDispatchFixture()
            let registry = BridgeMediaLeaseRegistry()
            let handler = BridgeVideoPreviewActionHandler(
                leaseRegistry: registry,
                prepareIDGenerator: { "prepare-\(state)" },
                prepare: { _, _, _ in
                    BridgeVideoPreparedSource(result: fixture.probeResult(route: route), openedFile: nil)
                }
            )

            let optionalResult = await handler.handle(fixture.prepareRequest,
                                                      principal: .device(id: "device-a"))
            let result = try XCTUnwrap(optionalResult)
            XCTAssertTrue(result.response.ok)
            XCTAssertEqual(result.response.result?["state"]?.stringValue, state)
            XCTAssertEqual(result.response.result?["route"]?.stringValue, route.rawValue)
            XCTAssertNil(result.response.result?["lease_path"])
        }
    }

    func testLegacyOrMissingPrincipalCannotCreateDeviceLease() async throws {
        let fixture = try VideoDispatchFixture()
        var prepareCalls = 0
        let handler = BridgeVideoPreviewActionHandler(
            leaseRegistry: BridgeMediaLeaseRegistry(),
            prepareIDGenerator: { "unused" },
            prepare: { _, _, _ in
                prepareCalls += 1
                return BridgeVideoPreparedSource(result: fixture.probeResult(route: .direct),
                                                 openedFile: try fixture.open())
            }
        )

        for principal in [BridgeAuthenticatedPrincipal?.some(.legacy), nil] {
            let optionalResult = await handler.handle(fixture.prepareRequest, principal: principal)
            let result = try XCTUnwrap(optionalResult)
            XCTAssertFalse(result.response.ok)
            XCTAssertEqual(result.response.error?.code, "unauthorized")
        }
        XCTAssertEqual(prepareCalls, 0)
    }

    func testOperationalProbeFailureReturnsTypedFailedStateWithoutPathOrLease() async throws {
        let fixture = try VideoDispatchFixture()
        let handler = BridgeVideoPreviewActionHandler(
            leaseRegistry: BridgeMediaLeaseRegistry(),
            prepareIDGenerator: { "prepare-failed" },
            prepare: { _, _, _ in
                throw BridgeInternalError.fileOutsideRoot("這個檔案不在允許預覽的範圍內。")
            }
        )

        let optionalResult = await handler.handle(fixture.prepareRequest,
                                                  principal: .device(id: "device-a"))
        let result = try XCTUnwrap(optionalResult)

        XCTAssertTrue(result.response.ok)
        XCTAssertEqual(result.response.result?["prepare_id"]?.stringValue, "prepare-failed")
        XCTAssertEqual(result.response.result?["state"]?.stringValue, "failed")
        XCTAssertEqual(result.response.result?["code"]?.stringValue, "file_outside_root")
        XCTAssertNil(result.response.result?["lease_path"])
        XCTAssertFalse(String(describing: result.response.result).contains(fixture.fileURL.path))
    }
}

private final class VideoDispatchFixture {
    let rootURL: URL
    let fileURL: URL

    init() throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("tidey-video-dispatch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        fileURL = rootURL.appendingPathComponent("fixture.mp4")
        try Data("video".utf8).write(to: fileURL)
    }

    deinit { try? FileManager.default.removeItem(at: rootURL) }

    var prepareRequest: BridgeRequest {
        BridgeRequest(id: "prepare-1",
                      action: BridgeVideoPreviewProtocolV1.prepareAction,
                      params: [
                        "workspace_id": .string("workspace-1"),
                        "panel_id": .string("panel-1"),
                        "path": .string(fileURL.path),
                      ])
    }

    func open() throws -> BridgeSafeOpenedFile {
        try BridgeSafeFileOpener.openRegularFile(at: fileURL,
                                                notFoundMessage: "missing",
                                                outsideScopeMessage: "outside")
    }

    func probeResult(route: BridgeVideoPreviewRoute) -> BridgeVideoProbeResult {
        BridgeVideoProbeResult(normalizedPath: fileURL.path,
                               displayName: fileURL.lastPathComponent,
                               route: route,
                               mime: "video/mp4",
                               size: 5,
                               durationMS: 30_000,
                               hasAudio: false,
                               revisionToken: "revision")
    }
}
