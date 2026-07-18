import Foundation

let chatSubmitEnterDelayNanoseconds: UInt64 = 130_000_000

// EXPLICIT step semantics: the vendor plan declares what each step IS —
// downstream transports must never guess message-vs-Enter from the payload
// characters (a message that happens to be "\r" is still a message).
enum ChatSubmitStepRole: Equatable, Sendable {
    case messageText
    case submitEnter
}

struct ChatSubmitStep: Equatable {
    let input: String
    let role: ChatSubmitStepRole
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
                               socketClient: TideySocketClient?,
                               chatSubmitEchoRegistry: ChatSubmitEchoRegistry) -> AgentTranscriptSession
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
            ChatSubmitStep(input: text, role: .messageText, delayNanoseconds: 0),
            ChatSubmitStep(input: "\r", role: .submitEnter, delayNanoseconds: chatSubmitEnterDelayNanoseconds),
        ]
    }

    func cancelRequestPlan() -> [ChatSubmitStep]? {
        nil
    }

    func makeTranscriptSession(record: AgentSessionRegistryRecord,
                               fileManager: FileManager,
                               hub: AgentEventHub,
                               socketClient: TideySocketClient?,
                               chatSubmitEchoRegistry: ChatSubmitEchoRegistry) -> AgentTranscriptSession {
        ClaudeTranscriptSession(record: record,
                                fileManager: fileManager,
                                hub: hub,
                                socketClient: socketClient,
                                chatSubmitEchoRegistry: chatSubmitEchoRegistry)
    }
}

private struct CodexAgentVendor: AgentVendor {
    let id = "codex"
    let registryDirectoryName = "codex"

    func submitMessagePlan(text: String) -> [ChatSubmitStep] {
        [
            ChatSubmitStep(input: text, role: .messageText, delayNanoseconds: 0),
            ChatSubmitStep(input: "\r", role: .submitEnter, delayNanoseconds: chatSubmitEnterDelayNanoseconds),
        ]
    }

    func cancelRequestPlan() -> [ChatSubmitStep]? {
        nil
    }

    func makeTranscriptSession(record: AgentSessionRegistryRecord,
                               fileManager: FileManager,
                               hub: AgentEventHub,
                               socketClient: TideySocketClient?,
                               chatSubmitEchoRegistry: ChatSubmitEchoRegistry) -> AgentTranscriptSession {
        CodexTranscriptSession(record: record,
                               fileManager: fileManager,
                               hub: hub,
                               socketClient: socketClient,
                               chatSubmitEchoRegistry: chatSubmitEchoRegistry)
    }
}
