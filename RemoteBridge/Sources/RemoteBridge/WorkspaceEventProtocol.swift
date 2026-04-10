import Foundation

enum WorkspaceEventKind: String, Codable, Sendable {
    case workspaceCreated = "workspace_created"
    case workspaceUpdated = "workspace_updated"
    case workspaceClosed = "workspace_closed"
    case workspaceSelected = "workspace_selected"
    case panelCreated = "panel_created"
    case panelUpdated = "panel_updated"
    case panelClosed = "panel_closed"
    case panelSelected = "panel_selected"
    case agentSessionStarted = "agent_session_started"
    case agentSessionUpdated = "agent_session_updated"
    case agentSessionEnded = "agent_session_ended"
}

struct WorkspaceEvent: Codable, Sendable {
    let eventID: String
    let seq: Int
    let timestamp: String
    let kind: WorkspaceEventKind
    let windowGUID: String?
    let workspaceID: String?
    let panelID: String?
    let workspace: [String: JSONValue]?
    let panel: [String: JSONValue]?

    enum CodingKeys: String, CodingKey {
        case eventID = "event_id"
        case seq
        case timestamp
        case kind
        case windowGUID = "window_guid"
        case workspaceID = "workspace_id"
        case panelID = "panel_id"
        case workspace
        case panel
    }
}

struct WorkspaceEventEnvelope: Codable, Sendable {
    let type: String
    let v: Int
    let replay: Bool
    let event: WorkspaceEvent

    init(replay: Bool, event: WorkspaceEvent, v: Int = bridgeProtocolVersion) {
        self.type = "workspace_event"
        self.v = v
        self.replay = replay
        self.event = event
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        guard type == "workspace_event" else {
            throw DecodingError.dataCorruptedError(forKey: .type,
                                                   in: container,
                                                   debugDescription: "Unsupported envelope type \(type)")
        }
        self.type = type
        self.v = try container.decode(Int.self, forKey: .v)
        self.replay = try container.decode(Bool.self, forKey: .replay)
        self.event = try container.decode(WorkspaceEvent.self, forKey: .event)
    }
}
