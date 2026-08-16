import Foundation

enum BridgeVideoPreviewProtocolV1 {
    static let capability = "video_preview_v1"
    static let prepareAction = "video_prepare"
    static let closeAction = "video_close"
}

enum BridgeVideoPreviewRoute: String, Codable, CaseIterable, Sendable {
    case direct
    case remux
    case transcode
    case unsupported
}

enum BridgeVideoPreviewState: String, Codable, CaseIterable, Sendable {
    case ready
    case conversionRequired = "conversion_required"
    case unsupported
    case failed
}

struct BridgeVideoPreviewReadyPayload: Codable, Equatable, Sendable {
    let prepareID: String
    let state: BridgeVideoPreviewState
    let route: BridgeVideoPreviewRoute
    let leasePath: String
    let mime: String
    let size: UInt64
    let durationMS: UInt64
    let hasAudio: Bool
    let expiresAt: String
    let acceptsRanges: Bool

    enum CodingKeys: String, CodingKey {
        case prepareID = "prepare_id"
        case state
        case route
        case leasePath = "lease_path"
        case mime
        case size
        case durationMS = "duration_ms"
        case hasAudio = "has_audio"
        case expiresAt = "expires_at"
        case acceptsRanges = "accepts_ranges"
    }
}
