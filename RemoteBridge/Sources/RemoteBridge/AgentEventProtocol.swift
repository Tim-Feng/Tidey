import Foundation

enum AgentEventKind: String, Codable, Sendable {
    case sessionStarted = "session_started"
    case sessionEnded = "session_ended"
    case assistantMessage = "assistant_message"
    case assistantFinal = "assistant_final"
    case thinking
    case toolCall = "tool_call"
    case toolResult = "tool_result"
    case userMessage = "user_message"
    case status
}

struct AgentEvent: Encodable, Sendable {
    let eventID: String
    let seq: Int
    let vendor: String
    let workspaceID: String
    let sessionID: String
    let timestamp: String
    let type: AgentEventKind
    let role: String?
    let text: String?
    let name: String?
    let input: String?
    let output: String?
    let toolCallID: String?
    let metadata: [String: String]?

    enum CodingKeys: String, CodingKey {
        case eventID = "event_id"
        case seq
        case vendor
        case workspaceID = "workspace_id"
        case sessionID = "session_id"
        case timestamp
        case type
        case role
        case text
        case name
        case input
        case output
        case toolCallID = "tool_call_id"
        case metadata
    }
}

struct AgentEventEnvelope: Encodable, Sendable {
    let type = "agent_event"
    let v = bridgeProtocolVersion
    let replay: Bool
    let event: AgentEvent
}
