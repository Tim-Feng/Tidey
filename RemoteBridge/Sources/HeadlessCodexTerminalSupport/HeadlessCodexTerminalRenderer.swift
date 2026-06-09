import Foundation

public struct HeadlessCodexTerminalEventEnvelope: Decodable {
    public let type: String
    public let replay: Bool?
    public let event: HeadlessCodexTerminalAgentEvent?
}

public struct HeadlessCodexTerminalAgentEvent: Decodable {
    public let eventID: String
    public let seq: Int
    public let vendor: String
    public let workspaceID: String
    public let sessionID: String
    public let type: String
    public let role: String?
    public let text: String?
    public let name: String?
    public let input: String?
    public let output: String?
    public let toolCallID: String?
    public let metadata: [String: String]?

    enum CodingKeys: String, CodingKey {
        case eventID = "event_id"
        case seq
        case vendor
        case workspaceID = "workspace_id"
        case sessionID = "session_id"
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

public enum HeadlessCodexTerminalRenderChunk: Equatable {
    case line(String)
    case raw(String)
}

public final class HeadlessCodexTerminalRenderer {
    private var renderedEventIDs = Set<String>()

    public init() {}

    public func render(envelope: HeadlessCodexTerminalEventEnvelope) -> [HeadlessCodexTerminalRenderChunk] {
        guard envelope.type == "agent_event",
              let event = envelope.event,
              renderedEventIDs.insert(event.eventID).inserted else {
            return []
        }
        return render(event: event, replay: envelope.replay ?? false)
    }

    public func render(event: HeadlessCodexTerminalAgentEvent,
                       replay: Bool = false) -> [HeadlessCodexTerminalRenderChunk] {
        switch event.type {
        case "session_started":
            return [.line("Codex session: \(nonEmpty(event.text) ?? event.sessionID)")]
        case "status":
            guard let text = nonEmpty(event.text) else { return [] }
            return [.line("[status] \(text)")]
        case "thinking":
            return replay ? [] : [.line("[thinking]")]
        case "user_message":
            guard let text = nonEmpty(event.text) else { return [] }
            return [.line("> \(text)")]
        case "assistant_message", "assistant_final":
            guard let text = nonEmpty(event.text) else { return [] }
            return [.line(text)]
        case "interactive_prompt":
            return renderPrompt(event)
        case "interactive_prompt_resolved":
            let decision = event.metadata?["decision"] ?? event.metadata?["reason"] ?? "resolved"
            return [.line("[approval \(decision)]")]
        case "tool_call":
            return renderToolCall(event)
        case "tool_result":
            return renderToolResult(event)
        default:
            return []
        }
    }

    private func renderPrompt(_ event: HeadlessCodexTerminalAgentEvent) -> [HeadlessCodexTerminalRenderChunk] {
        var lines = [HeadlessCodexTerminalRenderChunk]()
        lines.append(.line("[approval requested]"))
        if let text = nonEmpty(event.text) {
            lines.append(.line(text))
        }
        return lines
    }

    private func renderToolCall(_ event: HeadlessCodexTerminalAgentEvent) -> [HeadlessCodexTerminalRenderChunk] {
        switch event.name {
        case "terminal_input":
            guard let input = nonEmpty(event.input) else { return [] }
            return [.line("[terminal input]\n\(input)")]
        case "command_execution_started":
            let command = nonEmpty(event.input) ?? nonEmpty(event.text) ?? "command"
            return [.line("[command] \(command)")]
        default:
            guard let name = event.name else { return [] }
            let body = nonEmpty(event.input) ?? nonEmpty(event.text)
            return [.line("[tool] \(name)\(body.map { "\n\($0)" } ?? "")")]
        }
    }

    private func renderToolResult(_ event: HeadlessCodexTerminalAgentEvent) -> [HeadlessCodexTerminalRenderChunk] {
        switch event.name {
        case "terminal_stream":
            guard let output = event.output, output.isEmpty == false else { return [] }
            return [.raw(output)]
        case "command_execution_completed":
            var lines = [HeadlessCodexTerminalRenderChunk]()
            if let output = nonEmpty(event.output) {
                lines.append(.line("[command output]\n\(output)"))
            }
            if let text = nonEmpty(event.text) {
                lines.append(.line(text))
            }
            return lines
        case "file_change_patch":
            guard let output = nonEmpty(event.output) else { return [] }
            return [.line("[patch]\n\(output)")]
        default:
            let body = nonEmpty(event.output) ?? nonEmpty(event.text)
            guard let body else { return [] }
            return [.line(body)]
        }
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : value
    }
}
