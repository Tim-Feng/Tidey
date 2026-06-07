import XCTest
@testable import RemoteBridge

final class CodexAppServerRegistryRuntimeSyncerTests: XCTestCase {
    func testSyncAttachesOnlyCodexAppServerRecords() {
        let hub = AgentEventHub()
        let runtime = FakeRuntimeSession()
        var attachedRecords = [AgentSessionRegistryRecord]()
        let syncer = CodexAppServerRegistryRuntimeSyncer(eventHub: hub, attachHandler: { record, _, _, _, _, _ in
            attachedRecords.append(record)
            return runtime
        })

        syncer.sync(records: [
            Self.record(sessionID: "ordinary", runtime: nil, socketPath: nil),
            Self.record(sessionID: "app", runtime: "codex_app_server", socketPath: "/tmp/app.sock"),
        ])

        XCTAssertEqual(attachedRecords.map(\.sessionID), ["app"])
        XCTAssertFalse(runtime.stopped)
    }

    func testSyncStopsStaleAndReplacedRuntimes() {
        let hub = AgentEventHub()
        var runtimes = [FakeRuntimeSession]()
        let syncer = CodexAppServerRegistryRuntimeSyncer(eventHub: hub, attachHandler: { _, _, _, _, _, _ in
            let runtime = FakeRuntimeSession()
            runtimes.append(runtime)
            return runtime
        })

        syncer.sync(records: [
            Self.record(sessionID: "app", runtime: "codex_app_server", socketPath: "/tmp/app-1.sock"),
        ])
        syncer.sync(records: [
            Self.record(sessionID: "app", runtime: "codex_app_server", socketPath: "/tmp/app-2.sock"),
        ])
        syncer.sync(records: [])

        XCTAssertEqual(runtimes.count, 2)
        XCTAssertTrue(runtimes[0].stopped)
        XCTAssertTrue(runtimes[1].stopped)
    }

    func testSubmitApprovalRoutesToRuntimeHoldingPrompt() throws {
        let hub = AgentEventHub()
        let firstRuntime = FakeRuntimeSession()
        let secondRuntime = FakeRuntimeSession()
        let resolved = Self.event(sessionID: "second", promptID: "prompt-2")
        secondRuntime.resolvedEventsByPromptID["prompt-2"] = resolved
        var runtimeIndex = 0
        let syncer = CodexAppServerRegistryRuntimeSyncer(eventHub: hub, attachHandler: { _, _, _, _, _, _ in
            defer { runtimeIndex += 1 }
            return runtimeIndex == 0 ? firstRuntime : secondRuntime
        })

        syncer.sync(records: [
            Self.record(sessionID: "first", runtime: "codex_app_server", socketPath: "/tmp/first.sock"),
            Self.record(sessionID: "second", runtime: "codex_app_server", socketPath: "/tmp/second.sock"),
        ])

        let event = try syncer.submitApproval(promptID: "prompt-2", targetIndex: 1)

        XCTAssertEqual(event.eventID, resolved.eventID)
        XCTAssertEqual(secondRuntime.submitAttempts, ["prompt-2"])
    }

    func testAttachedRuntimePublishesConversationEventsToHub() throws {
        let hub = AgentEventHub()
        var capturedAgentEventHandler: CodexAppServerHeadlessRuntime.AgentEventHandler?
        let syncer = CodexAppServerRegistryRuntimeSyncer(eventHub: hub, attachHandler: { _, _, _, onAgentEvent, _, _ in
            capturedAgentEventHandler = onAgentEvent
            return FakeRuntimeSession()
        })

        syncer.sync(records: [
            Self.record(sessionID: "app", runtime: "codex_app_server", socketPath: "/tmp/app.sock"),
        ])
        let onAgentEvent = try XCTUnwrap(capturedAgentEventHandler)

        onAgentEvent(Self.conversationEvent(eventID: "user-1",
                                            seq: 1,
                                            sessionID: "app",
                                            type: .userMessage,
                                            text: "test from Mac"))
        onAgentEvent(Self.conversationEvent(eventID: "assistant-1",
                                            seq: 2,
                                            sessionID: "app",
                                            type: .assistantMessage,
                                            text: "received"))

        let result = hub.fetch(workspaceID: "workspace-1",
                               sessionID: "app",
                               limit: 10)

        XCTAssertEqual(result.events.map(\.type), [.userMessage, .assistantMessage])
        XCTAssertEqual(result.events.map(\.text), ["test from Mac", "received"])
    }

    private static func record(sessionID: String,
                               runtime: String?,
                               socketPath: String?) -> AgentSessionRegistryRecord {
        AgentSessionRegistryRecord(version: 1,
                                   vendor: "codex",
                                   workspaceID: "workspace-1",
                                   sessionID: sessionID,
                                   panelID: "panel-1",
                                   pid: Int32(getpid()),
                                   cwd: "/tmp",
                                   createdAt: "2026-06-07T00:00:00Z",
                                   transcriptPath: nil,
                                   runtime: runtime,
                                   appServerSocket: socketPath,
                                   appServerPID: Int32(getpid()))
    }

    private static func event(sessionID: String, promptID: String) -> AgentEvent {
        AgentEvent(eventID: "resolved-\(promptID)",
                   seq: 1,
                   vendor: "codex",
                   workspaceID: "workspace-1",
                   sessionID: sessionID,
                   timestamp: "2026-06-07T00:00:00.000Z",
                   type: .interactivePromptResolved,
                   role: nil,
                   text: nil,
                   name: nil,
                   input: nil,
                   output: nil,
                   toolCallID: nil,
                   metadata: [
                    "panel_id": "panel-1",
                    "prompt_id": promptID,
                    "source": "codex_command_approval",
                   ])
    }

    private static func conversationEvent(eventID: String,
                                          seq: Int,
                                          sessionID: String,
                                          type: AgentEventKind,
                                          text: String) -> AgentEvent {
        AgentEvent(eventID: eventID,
                   seq: seq,
                   vendor: "codex",
                   workspaceID: "workspace-1",
                   sessionID: sessionID,
                   timestamp: "2026-06-07T00:00:00.000Z",
                   type: type,
                   role: nil,
                   text: text,
                   name: nil,
                   input: nil,
                   output: nil,
                   toolCallID: nil,
                   metadata: [
                    "panel_id": "panel-1",
                    "source": "codex_app_server",
                   ])
    }
}

private final class FakeRuntimeSession: CodexAppServerRuntimeSessionControlling {
    var stopped = false
    var submitAttempts = [String]()
    var resolvedEventsByPromptID = [String: AgentEvent]()

    func submitApproval(promptID: String, targetIndex: Int) throws -> AgentEvent {
        submitAttempts.append(promptID)
        guard let event = resolvedEventsByPromptID[promptID] else {
            throw BridgeInternalError.notFound("Unknown Codex approval prompt.")
        }
        return event
    }

    func stop() {
        stopped = true
    }
}
