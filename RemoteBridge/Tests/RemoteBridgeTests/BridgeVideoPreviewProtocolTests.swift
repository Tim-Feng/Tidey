import XCTest
@testable import RemoteBridge

final class BridgeVideoPreviewProtocolTests: XCTestCase {
    func testV1ProtocolNamesRoutesAndStatesAreExactWhileDormant() throws {
        XCTAssertEqual(BridgeVideoPreviewProtocolV1.capability, "video_preview_v1")
        XCTAssertEqual(BridgeVideoPreviewProtocolV1.prepareAction, "video_prepare")
        XCTAssertEqual(BridgeVideoPreviewProtocolV1.closeAction, "video_close")

        XCTAssertEqual(BridgeVideoPreviewRoute.allCases.map(\.rawValue), [
            "direct", "remux", "transcode", "unsupported",
        ])
        XCTAssertEqual(BridgeVideoPreviewState.allCases.map(\.rawValue), [
            "ready", "conversion_required", "unsupported", "failed",
        ])

        let ready = BridgeVideoPreviewReadyPayload(
            prepareID: "prepare-1",
            state: .ready,
            route: .direct,
            leasePath: "/media/opaque",
            mime: "video/mp4",
            size: 3_331_872,
            durationMS: 30_000,
            hasAudio: false,
            expiresAt: "2026-08-16T05:00:00Z",
            acceptsRanges: true
        )
        let data = try JSONEncoder().encode(ready)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["prepare_id"] as? String, "prepare-1")
        XCTAssertEqual(object["lease_path"] as? String, "/media/opaque")
        XCTAssertEqual(object["duration_ms"] as? Int, 30_000)
        XCTAssertEqual(object["has_audio"] as? Bool, false)
        XCTAssertEqual(object["accepts_ranges"] as? Bool, true)
    }
}
