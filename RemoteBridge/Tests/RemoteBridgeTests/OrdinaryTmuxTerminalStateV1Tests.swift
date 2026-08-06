import Foundation
import XCTest
@testable import RemoteBridge

final class OrdinaryTmuxTerminalStateV1Tests: XCTestCase {
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
