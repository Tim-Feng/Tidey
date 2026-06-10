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

    func testSubmitMessageRoutesToMatchingRuntimeSession() throws {
        let hub = AgentEventHub()
        let firstRuntime = FakeRuntimeSession()
        let secondRuntime = FakeRuntimeSession()
        var runtimeIndex = 0
        let syncer = CodexAppServerRegistryRuntimeSyncer(eventHub: hub, attachHandler: { _, _, _, _, _, _ in
            defer { runtimeIndex += 1 }
            return runtimeIndex == 0 ? firstRuntime : secondRuntime
        })

        syncer.sync(records: [
            Self.record(sessionID: "first", runtime: "codex_app_server", socketPath: "/tmp/first.sock"),
            Self.record(sessionID: "second", runtime: "codex_app_server", socketPath: "/tmp/second.sock"),
        ])

        try syncer.submitMessage(sessionID: "second", text: "hello from remote")

        XCTAssertTrue(firstRuntime.submittedMessages.isEmpty)
        XCTAssertEqual(secondRuntime.submittedMessages, ["hello from remote"])
    }

    func testSyncTreatsSameThreadRecordsAsSeparateRuntimeInstances() {
        let hub = AgentEventHub()
        var attachedRecords = [AgentSessionRegistryRecord]()
        let syncer = CodexAppServerRegistryRuntimeSyncer(eventHub: hub, attachHandler: { record, _, _, _, _, _ in
            attachedRecords.append(record)
            return FakeRuntimeSession()
        })

        syncer.sync(records: [
            Self.record(sessionID: "instance-a",
                        runtime: "codex_app_server",
                        socketPath: "/tmp/instance-a.sock",
                        panelID: "panel-a",
                        threadID: "thread-shared"),
            Self.record(sessionID: "instance-b",
                        runtime: "codex_app_server",
                        socketPath: "/tmp/instance-b.sock",
                        panelID: "panel-b",
                        threadID: "thread-shared"),
        ])

        XCTAssertEqual(attachedRecords.map(\.sessionID), ["instance-a", "instance-b"])
        XCTAssertEqual(attachedRecords.map(\.threadID), ["thread-shared", "thread-shared"])
    }

    func testSubmitApprovalWithSameThreadRecordsRoutesToOwningRuntimeInstance() throws {
        let hub = AgentEventHub()
        let firstRuntime = FakeRuntimeSession()
        let secondRuntime = FakeRuntimeSession()
        let resolved = Self.event(sessionID: "instance-b", promptID: "prompt-shared")
        secondRuntime.resolvedEventsByPromptID["prompt-shared"] = resolved
        var runtimeIndex = 0
        let syncer = CodexAppServerRegistryRuntimeSyncer(eventHub: hub, attachHandler: { _, _, _, _, _, _ in
            defer { runtimeIndex += 1 }
            return runtimeIndex == 0 ? firstRuntime : secondRuntime
        })

        syncer.sync(records: [
            Self.record(sessionID: "instance-a",
                        runtime: "codex_app_server",
                        socketPath: "/tmp/instance-a.sock",
                        panelID: "panel-a",
                        threadID: "thread-shared"),
            Self.record(sessionID: "instance-b",
                        runtime: "codex_app_server",
                        socketPath: "/tmp/instance-b.sock",
                        panelID: "panel-b",
                        threadID: "thread-shared"),
        ])

        let event = try syncer.submitApproval(promptID: "prompt-shared", targetIndex: 0)

        XCTAssertEqual(event.sessionID, "instance-b")
        XCTAssertTrue(firstRuntime.submitAttempts.isEmpty || firstRuntime.submitAttempts == ["prompt-shared"])
        XCTAssertEqual(secondRuntime.submitAttempts, ["prompt-shared"])
    }

    func testSyncEnsuresThreadSubscriptionForReusedRuntime() {
        let hub = AgentEventHub()
        let runtime = FakeRuntimeSession()
        let syncer = CodexAppServerRegistryRuntimeSyncer(eventHub: hub, attachHandler: { _, _, _, _, _, _ in
            runtime
        })
        let record = Self.record(sessionID: "app", runtime: "codex_app_server", socketPath: "/tmp/app.sock")

        syncer.sync(records: [record])
        syncer.sync(records: [record])

        XCTAssertEqual(runtime.ensureThreadSubscriptionCallCount, 1)
        XCTAssertFalse(runtime.stopped)
    }

    func testAttachedRuntimeDoesNotPublishConversationEventsToHub() throws {
        let hub = AgentEventHub()
        var capturedAgentEventHandler: CodexAppServerHeadlessRuntime.AgentEventHandler?
        let sidebarLock = NSLock()
        var sidebarMessages = [String]()
        let syncer = CodexAppServerRegistryRuntimeSyncer(eventHub: hub,
                                                        sidebarMessageSender: { message in
                                                            sidebarLock.lock()
                                                            sidebarMessages.append(message)
                                                            sidebarLock.unlock()
                                                        },
                                                        attachHandler: { _, _, _, onAgentEvent, _, _ in
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
        onAgentEvent(Self.appServerEvent(eventID: "turn-started",
                                         seq: 2,
                                         sessionID: "app",
                                         type: .thinking,
                                         text: "Codex turn started",
                                         payloadKind: "turn_started"))
        onAgentEvent(Self.conversationEvent(eventID: "assistant-1",
                                            seq: 3,
                                            sessionID: "app",
                                            type: .assistantMessage,
                                            text: "received"))
        onAgentEvent(Self.appServerEvent(eventID: "assistant-text",
                                         seq: 4,
                                         sessionID: "app",
                                         type: .assistantMessage,
                                         text: "received",
                                         payloadKind: "assistant_message"))
        onAgentEvent(Self.appServerEvent(eventID: "turn-completed",
                                         seq: 5,
                                         sessionID: "app",
                                         type: .assistantFinal,
                                         text: nil,
                                         payloadKind: "turn_completed"))

        let result = hub.fetch(workspaceID: "workspace-1",
                               sessionID: "app",
                               limit: 10)

        XCTAssertTrue(result.events.isEmpty)
        XCTAssertTrue(Self.waitUntil {
            sidebarLock.lock()
            defer { sidebarLock.unlock() }
            return sidebarMessages.count == 3
        })
        sidebarLock.lock()
        let messages = sidebarMessages
        sidebarLock.unlock()
        XCTAssertEqual(messages[0], "report_shell_state running --workspace_id=workspace-1")
        XCTAssertTrue(messages[1].contains(#""action":"notification.create""#))
        XCTAssertTrue(messages[1].contains(#""body":"received""#))
        XCTAssertEqual(messages[2], "report_shell_state prompt --workspace_id=workspace-1")
    }

    func testAttachedRuntimeStillPublishesApprovalPromptEventsToHub() throws {
        let hub = AgentEventHub()
        var capturedPromptHandler: CodexAppServerConnection.InteractivePromptHandler?
        let syncer = CodexAppServerRegistryRuntimeSyncer(eventHub: hub, attachHandler: { _, _, _, _, onInteractivePrompt, _ in
            capturedPromptHandler = onInteractivePrompt
            return FakeRuntimeSession()
        })

        syncer.sync(records: [
            Self.record(sessionID: "app", runtime: "codex_app_server", socketPath: "/tmp/app.sock"),
        ])
        let onInteractivePrompt = try XCTUnwrap(capturedPromptHandler)
        let request = try XCTUnwrap(CodexAppServerApprovalRequest(
            method: "item/commandExecution/requestApproval",
            requestID: .string("approval-1"),
            params: [
                "threadId": .string("thread-1"),
                "turnId": .string("turn-1"),
                "itemId": .string("item-1"),
                "command": .string("python3 -c 'print(1)'"),
                "cwd": .string("/tmp"),
            ]))
        let prompt = InteractivePrompt(promptID: "prompt-approval",
                                       vendor: "codex",
                                       source: "codex_command_approval",
                                       title: "Approve Codex command?",
                                       body: "Command: python3 -c 'print(1)'",
                                       options: [
                                        InteractivePromptOption(index: 0, label: "Yes, proceed", inputSequence: "\r"),
                                        InteractivePromptOption(index: 1, label: "No", inputSequence: "\u{1b}[B\r"),
                                       ],
                                       selectedIndex: 0)
        let event = Self.interactivePromptEvent(sessionID: "app", promptID: prompt.promptID)

        onInteractivePrompt(CodexAppServerInteractivePromptEnvelope(request: request,
                                                                    prompt: prompt,
                                                                    event: event))

        let result = hub.fetch(workspaceID: "workspace-1",
                               sessionID: "app",
                               limit: 10)

        XCTAssertEqual(result.events.map(\.eventID), [event.eventID])
        XCTAssertEqual(result.events.map(\.type), [.interactivePrompt])
    }

    func testPendingApprovalPromptEventsAreScopedToWorkspaceAndSession() {
        let hub = AgentEventHub()
        let firstRuntime = FakeRuntimeSession()
        let secondRuntime = FakeRuntimeSession()
        firstRuntime.pendingPromptEvents = [
            Self.interactivePromptEvent(sessionID: "first", promptID: "prompt-first"),
        ]
        secondRuntime.pendingPromptEvents = [
            Self.interactivePromptEvent(sessionID: "second", promptID: "prompt-second"),
        ]
        var runtimeIndex = 0
        let syncer = CodexAppServerRegistryRuntimeSyncer(eventHub: hub, attachHandler: { _, _, _, _, _, _ in
            defer { runtimeIndex += 1 }
            return runtimeIndex == 0 ? firstRuntime : secondRuntime
        })

        syncer.sync(records: [
            Self.record(sessionID: "first",
                        runtime: "codex_app_server",
                        socketPath: "/tmp/first.sock",
                        panelID: "panel-first"),
            Self.record(sessionID: "second",
                        runtime: "codex_app_server",
                        socketPath: "/tmp/second.sock",
                        panelID: "panel-second"),
        ])

        XCTAssertEqual(syncer.pendingApprovalPromptEvents(workspaceID: "workspace-1", sessionID: nil).map(\.eventID),
                       ["prompt-prompt-first", "prompt-prompt-second"])
        XCTAssertEqual(syncer.pendingApprovalPromptEvents(workspaceID: "workspace-1", sessionID: "second").map(\.eventID),
                       ["prompt-prompt-second"])
        XCTAssertEqual(syncer.pendingApprovalPromptEvents(workspaceID: "workspace-1", sessionID: "stale-session").map(\.eventID),
                       ["prompt-prompt-first", "prompt-prompt-second"])
        XCTAssertTrue(syncer.pendingApprovalPromptEvents(workspaceID: "other-workspace", sessionID: nil).isEmpty)
    }

    private static func record(sessionID: String,
                               runtime: String?,
                               socketPath: String?,
                               panelID: String = "panel-1",
                               threadID: String? = nil) -> AgentSessionRegistryRecord {
        AgentSessionRegistryRecord(version: 1,
                                   vendor: "codex",
                                   workspaceID: "workspace-1",
                                   sessionID: sessionID,
                                   panelID: panelID,
                                   pid: Int32(getpid()),
                                   cwd: "/tmp",
                                   createdAt: "2026-06-07T00:00:00Z",
                                   transcriptPath: nil,
                                   runtime: runtime,
                                   appServerSocket: socketPath,
                                   appServerPID: Int32(getpid()),
                                   threadID: threadID,
                                   resumeThreadID: threadID)
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

    private static func interactivePromptEvent(sessionID: String, promptID: String) -> AgentEvent {
        AgentEvent(eventID: "prompt-\(promptID)",
                   seq: 1,
                   vendor: "codex",
                   workspaceID: "workspace-1",
                   sessionID: sessionID,
                   timestamp: "2026-06-07T00:00:00.000Z",
                   type: .interactivePrompt,
                   role: nil,
                   text: "Approve Codex command?",
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

    private static func appServerEvent(eventID: String,
                                       seq: Int,
                                       sessionID: String,
                                       type: AgentEventKind,
                                       text: String?,
                                       payloadKind: String) -> AgentEvent {
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
                   ],
                   payload: .object([
                    "kind": .string(payloadKind),
                    "source": .string("codex_app_server"),
                   ]))
    }

    private static func waitUntil(timeout: TimeInterval = 2,
                                  condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        return condition()
    }

}

private final class FakeRuntimeSession: CodexAppServerRuntimeSessionControlling {
    var stopped = false
    var canSubmit = true
    var ensureThreadSubscriptionCallCount = 0
    var submitAttempts = [String]()
    var submittedMessages = [String]()
    var resolvedEventsByPromptID = [String: AgentEvent]()
    var pendingPromptEvents = [AgentEvent]()

    func canSubmitMessage() -> Bool {
        canSubmit
    }

    func ensureThreadSubscription() {
        ensureThreadSubscriptionCallCount += 1
    }

    func pendingApprovalPromptEvents() -> [AgentEvent] {
        pendingPromptEvents
    }

    func submitApproval(promptID: String, targetIndex: Int) throws -> AgentEvent {
        submitAttempts.append(promptID)
        guard let event = resolvedEventsByPromptID[promptID] else {
            throw BridgeInternalError.notFound("Unknown Codex approval prompt.")
        }
        return event
    }

    func submitMessage(text: String) throws {
        submittedMessages.append(text)
    }

    func stop() {
        stopped = true
    }
}
