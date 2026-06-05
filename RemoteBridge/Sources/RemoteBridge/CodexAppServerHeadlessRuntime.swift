import Foundation

struct CodexAppServerLaunchConfiguration: Equatable, Sendable {
    let executablePath: String
    let arguments: [String]
    let workingDirectory: String
    let environment: [String: String]

    static func direct(codexExecutablePath: String = "codex",
                       workingDirectory: String,
                       environment: [String: String] = [:]) -> CodexAppServerLaunchConfiguration {
        CodexAppServerLaunchConfiguration(executablePath: codexExecutablePath,
                                          arguments: ["app-server"],
                                          workingDirectory: workingDirectory,
                                          environment: environment)
    }
}

struct CodexAppServerRuntimeContext: Equatable, Sendable {
    let workspaceID: String
    let panelID: String
    let sessionID: String
}

final class CodexAppServerHeadlessRuntime {
    typealias SequenceProvider = (String) -> Int
    typealias TimestampProvider = () -> String
    typealias AgentEventHandler = (AgentEvent) -> Void

    private let context: CodexAppServerRuntimeContext
    private let nextSequence: SequenceProvider
    private let timestampProvider: TimestampProvider
    private let onAgentEvent: AgentEventHandler

    init(context: CodexAppServerRuntimeContext,
         nextSequence: @escaping SequenceProvider,
         timestampProvider: @escaping TimestampProvider,
         onAgentEvent: @escaping AgentEventHandler) {
        self.context = context
        self.nextSequence = nextSequence
        self.timestampProvider = timestampProvider
        self.onAgentEvent = onAgentEvent
    }

    @discardableResult
    func startThread(on connection: CodexAppServerConnection,
                     cwd: String?,
                     model: String? = nil,
                     approvalPolicy: String? = nil,
                     sandbox: JSONValue? = nil,
                     ephemeral: Bool = true,
                     onResponse: @escaping CodexAppServerConnection.ClientResponseHandler = { _ in }) throws -> Int {
        var params: [String: JSONValue] = [
            "ephemeral": .bool(ephemeral),
        ]
        if let cwd {
            params["cwd"] = .string(cwd)
        }
        if let model {
            params["model"] = .string(model)
        }
        if let approvalPolicy {
            params["approvalPolicy"] = .string(approvalPolicy)
        }
        if let sandbox {
            params["sandbox"] = sandbox
        }
        return try connection.sendClientRequest(method: "thread/start",
                                                params: params,
                                                onResponse: onResponse)
    }

    @discardableResult
    func startTurn(on connection: CodexAppServerConnection,
                   threadID: String,
                   text: String,
                   cwd: String? = nil,
                   approvalPolicy: String? = nil,
                   sandboxPolicy: JSONValue? = nil,
                   onResponse: @escaping CodexAppServerConnection.ClientResponseHandler = { _ in }) throws -> Int {
        var params: [String: JSONValue] = [
            "threadId": .string(threadID),
            "input": .array([
                .object([
                    "type": .string("text"),
                    "text": .string(text),
                    "text_elements": .array([]),
                ]),
            ]),
        ]
        if let cwd {
            params["cwd"] = .string(cwd)
        }
        if let approvalPolicy {
            params["approvalPolicy"] = .string(approvalPolicy)
        }
        if let sandboxPolicy {
            params["sandboxPolicy"] = sandboxPolicy
        }
        return try connection.sendClientRequest(method: "turn/start",
                                                params: params,
                                                onResponse: onResponse)
    }
}
