import Foundation

struct OrdinaryTmuxTerminalCursorV1: Equatable, Sendable {
    let row: Int
    let column: Int
}

struct OrdinaryTmuxTerminalModesV1: Equatable, Sendable {
    let insert: Bool
    let applicationCursorKeys: Bool
    let applicationKeypad: Bool
    let wrap: Bool
    let origin: Bool
    let mouseStandard: Bool
    let mouseButton: Bool
    let mouseAny: Bool
    let mouseUTF8: Bool
    let mouseSGR: Bool
    let paneKeyMode: String
}

struct OrdinaryTmuxTerminalStateV1: Equatable, Sendable {
    static let schemaVersion = 1

    let subscriptionID: String
    let paneID: String
    let columns: Int
    let rows: Int
    let cursor: OrdinaryTmuxTerminalCursorV1
    let cursorVisible: Bool
    let alternateOn: Bool
    let alternateSavedCursor: OrdinaryTmuxTerminalCursorV1?
    let scrollRegionUpper: Int
    let scrollRegionLower: Int
    let tabStops: [Int]
    let modes: OrdinaryTmuxTerminalModesV1
    let activeScreen: Data
    let backgroundScreen: Data
    let pendingPrefix: Data
}

struct OrdinaryTmuxTerminalFingerprintV1: Equatable, Sendable {
    let paneID: String
    let columns: Int
    let rows: Int
    let alternateOn: Bool
}

struct OrdinaryTmuxTerminalDeltaV1: Equatable, Sendable {
    let subscriptionID: String
    let sequence: UInt64
    let fingerprint: OrdinaryTmuxTerminalFingerprintV1
    let rebootstrapRequired: Bool
    let chunk: Data
}
