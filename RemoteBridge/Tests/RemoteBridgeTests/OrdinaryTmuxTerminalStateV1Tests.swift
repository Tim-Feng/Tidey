import Foundation
import XCTest
@testable import RemoteBridge

final class OrdinaryTmuxTerminalStateV1Tests: XCTestCase {
    func testStrictDeltaWireFieldsEncodeWithoutChangingLegacyEnvelope() throws {
        let strict = TerminalStreamDeltaEnvelope(
            type: "terminal_stream_delta",
            workspaceID: "workspace-1",
            panelID: "panel-1",
            subscriptionID: "subscription-1",
            sequence: 7,
            paneID: "%21",
            columns: 132,
            rows: 40,
            alternateOn: true,
            rebootstrapRequired: false,
            chunk: "",
            chunkBase64: "bQ==",
            cursorRow: nil,
            cursorColumn: nil
        )
        let strictObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(strict)) as? [String: Any]
        )

        XCTAssertEqual(strictObject["sequence"] as? UInt64, 7)
        XCTAssertEqual(strictObject["pane_id"] as? String, "%21")
        XCTAssertEqual(strictObject["cols"] as? Int, 132)
        XCTAssertEqual(strictObject["rows"] as? Int, 40)
        XCTAssertEqual(strictObject["alternate_on"] as? Bool, true)
        XCTAssertEqual(strictObject["rebootstrap_required"] as? Bool, false)

        let legacy = TerminalStreamDeltaEnvelope(
            type: "terminal_stream_delta",
            workspaceID: "workspace-1",
            panelID: "panel-1",
            chunk: "legacy",
            chunkBase64: "bGVnYWN5",
            cursorRow: 1,
            cursorColumn: 2
        )
        let legacyObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any]
        )
        for key in ["sequence", "pane_id", "cols", "rows", "alternate_on", "rebootstrap_required"] {
            XCTAssertNil(legacyObject[key], "legacy envelope unexpectedly encoded \(key)")
        }
    }

    func testStrictBootstrapProtocolSeamCompiles() {
        let seam: @Sendable (
            any OrdinaryTmuxTerminalStreaming,
            OrdinaryTmuxPanelRoute,
            String,
            String
        ) throws -> OrdinaryTmuxTerminalStateV1 = { streaming, route, outputPath, subscriptionID in
            try streaming.bootstrapStrictTerminalStream(
                refreshedRoute: route,
                outputFilePath: outputPath,
                subscriptionID: subscriptionID
            )
        }

        _ = seam
    }

    func testStrictTerminalStateContractCompiles() {
        let cursor = OrdinaryTmuxTerminalCursorV1(row: 7, column: 11)
        let modes = OrdinaryTmuxTerminalModesV1(
            insert: false,
            applicationCursorKeys: true,
            applicationKeypad: false,
            wrap: true,
            origin: false,
            mouseStandard: false,
            mouseButton: false,
            mouseAny: false,
            mouseUTF8: false,
            mouseSGR: true,
            paneKeyMode: "VT10x"
        )
        let state = OrdinaryTmuxTerminalStateV1(
            subscriptionID: "subscription-1",
            paneID: "%21",
            columns: 132,
            rows: 40,
            cursor: cursor,
            cursorVisible: true,
            alternateOn: true,
            alternateSavedCursor: OrdinaryTmuxTerminalCursorV1(row: 3, column: 5),
            scrollRegionUpper: 1,
            scrollRegionLower: 38,
            tabStops: [8, 16, 24],
            modes: modes,
            activeScreen: Data([0x1B, 0x5B, 0x6D]),
            backgroundScreen: Data("primary".utf8),
            pendingPrefix: Data([0x1B, 0x5B, 0x33, 0x31])
        )
        let fingerprint = OrdinaryTmuxTerminalFingerprintV1(
            paneID: "%21",
            columns: 132,
            rows: 40,
            alternateOn: true
        )
        let delta = OrdinaryTmuxTerminalDeltaV1(
            subscriptionID: "subscription-1",
            sequence: 1,
            fingerprint: fingerprint,
            rebootstrapRequired: false,
            chunk: Data([0x6D])
        )

        _ = (state, delta, OrdinaryTmuxTerminalStateV1.schemaVersion)
    }
}
