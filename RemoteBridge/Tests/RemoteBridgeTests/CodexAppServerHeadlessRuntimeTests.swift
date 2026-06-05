import XCTest
@testable import RemoteBridge

final class CodexAppServerHeadlessRuntimeTests: XCTestCase {
    func testLaunchConfigurationUsesDirectAppServerCommandOnly() {
        let config = CodexAppServerLaunchConfiguration.direct(workingDirectory: "/tmp/tidey-codex-test",
                                                              environment: ["CODEX_HOME": "/tmp/codex-home"])

        XCTAssertEqual(config.executablePath, "codex")
        XCTAssertEqual(config.arguments, ["app-server"])
        XCTAssertEqual(config.workingDirectory, "/tmp/tidey-codex-test")
        XCTAssertEqual(config.environment["CODEX_HOME"], "/tmp/codex-home")
        XCTAssertFalse(config.executablePath.contains("/Applications/Tidey.app"))
    }

    func testStartThreadAndTurnSendCodexAppServerRequests() throws {
        let outbound = LineSink()
        let runtime = Self.runtime()
        let connection = CodexAppServerConnection(sendLine: { outbound.append($0) })

        try runtime.startThread(on: connection,
                                cwd: "/Users/timfeng/GitHub/Tidey",
                                model: "gpt-5",
                                approvalPolicy: "on-request",
                                sandbox: .object(["mode": .string("workspace-write")]))
        try runtime.startTurn(on: connection,
                              threadID: "thread-1",
                              text: "fix the bridge",
                              cwd: "/Users/timfeng/GitHub/Tidey")

        let lines = outbound.lines()
        XCTAssertEqual(lines.count, 2)

        let startThread = try Self.object(from: lines[0])
        XCTAssertEqual(startThread["id"]?.intValue, 1)
        XCTAssertEqual(startThread["method"]?.stringValue, "thread/start")
        let threadParams = try XCTUnwrap(startThread["params"]?.objectValue)
        XCTAssertEqual(threadParams["cwd"]?.stringValue, "/Users/timfeng/GitHub/Tidey")
        XCTAssertEqual(threadParams["model"]?.stringValue, "gpt-5")
        XCTAssertEqual(threadParams["approvalPolicy"]?.stringValue, "on-request")
        XCTAssertEqual(threadParams["sandbox"]?.objectValue?["mode"]?.stringValue, "workspace-write")
        XCTAssertEqual(threadParams["ephemeral"]?.boolValue, true)

        let startTurn = try Self.object(from: lines[1])
        XCTAssertEqual(startTurn["id"]?.intValue, 2)
        XCTAssertEqual(startTurn["method"]?.stringValue, "turn/start")
        let turnParams = try XCTUnwrap(startTurn["params"]?.objectValue)
        XCTAssertEqual(turnParams["threadId"]?.stringValue, "thread-1")
        XCTAssertEqual(turnParams["cwd"]?.stringValue, "/Users/timfeng/GitHub/Tidey")
        let input = try XCTUnwrap(turnParams["input"]?.arrayValue?.first?.objectValue)
        XCTAssertEqual(input["type"]?.stringValue, "text")
        XCTAssertEqual(input["text"]?.stringValue, "fix the bridge")
        XCTAssertEqual(input["text_elements"]?.arrayValue?.count, 0)
    }

    private static func runtime() -> CodexAppServerHeadlessRuntime {
        var seq = 100
        return CodexAppServerHeadlessRuntime(
            context: CodexAppServerRuntimeContext(workspaceID: "workspace-1",
                                                  panelID: "panel-1",
                                                  sessionID: "session-1"),
            nextSequence: { _ in
                seq += 1
                return seq
            },
            timestampProvider: { "2026-06-05T12:00:00.000Z" },
            onAgentEvent: { _ in })
    }

    private static func object(from line: String,
                               file: StaticString = #filePath,
                               line sourceLine: UInt = #line) throws -> [String: JSONValue] {
        let data = try XCTUnwrap(line.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
                                 file: file,
                                 line: sourceLine)
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        return try XCTUnwrap(value.objectValue, file: file, line: sourceLine)
    }
}

private final class LineSink: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func append(_ line: String) {
        lock.lock()
        storage.append(line)
        lock.unlock()
    }

    func lines() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
