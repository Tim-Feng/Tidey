import Foundation

let codexChatSubmitDelayNanoseconds: UInt64 = 130_000_000

struct ChatSubmitStep: Equatable {
    let input: String
    let delayNanoseconds: UInt64
}

protocol AgentVendor {
    var id: String { get }
    var registryDirectoryName: String { get }

    func submitMessagePlan(text: String) -> [ChatSubmitStep]
    func cancelRequestPlan() -> [ChatSubmitStep]?
    func makeTranscriptSession(record: AgentSessionRegistryRecord,
                               fileManager: FileManager,
                               hub: AgentEventHub,
                               socketClient: TideySocketClient?) -> AgentTranscriptSession
}

enum AgentVendorRegistry {
    private static let vendors: [any AgentVendor] = [
        ClaudeAgentVendor(),
        CodexAgentVendor(),
    ]

    static var all: [any AgentVendor] {
        vendors
    }

    static func resolve(id: String) -> (any AgentVendor)? {
        vendors.first { $0.id.caseInsensitiveCompare(id) == .orderedSame }
    }
}

private struct ClaudeAgentVendor: AgentVendor {
    let id = "claude"
    let registryDirectoryName = "claude"

    func submitMessagePlan(text: String) -> [ChatSubmitStep] {
        [
            ChatSubmitStep(input: text + "\r", delayNanoseconds: 0),
        ]
    }

    func cancelRequestPlan() -> [ChatSubmitStep]? {
        nil
    }

    func makeTranscriptSession(record: AgentSessionRegistryRecord,
                               fileManager: FileManager,
                               hub: AgentEventHub,
                               socketClient: TideySocketClient?) -> AgentTranscriptSession {
        ClaudeTranscriptSession(record: record,
                                fileManager: fileManager,
                                hub: hub)
    }
}

private struct CodexAgentVendor: AgentVendor {
    let id = "codex"
    let registryDirectoryName = "codex"

    func submitMessagePlan(text: String) -> [ChatSubmitStep] {
        [
            ChatSubmitStep(input: text, delayNanoseconds: 0),
            ChatSubmitStep(input: "\r", delayNanoseconds: codexChatSubmitDelayNanoseconds),
        ]
    }

    func cancelRequestPlan() -> [ChatSubmitStep]? {
        nil
    }

    func makeTranscriptSession(record: AgentSessionRegistryRecord,
                               fileManager: FileManager,
                               hub: AgentEventHub,
                               socketClient: TideySocketClient?) -> AgentTranscriptSession {
        CodexTranscriptSession(record: record,
                               fileManager: fileManager,
                               hub: hub,
                               socketClient: socketClient)
    }
}
