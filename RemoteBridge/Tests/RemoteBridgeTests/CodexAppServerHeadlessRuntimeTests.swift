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
        XCTAssertEqual(config.transport, .stdio)
        XCTAssertFalse(config.executablePath.contains("/Applications/Tidey.app"))
    }

    func testLaunchConfigurationCanUseUnixSocketSidecar() {
        let config = CodexAppServerLaunchConfiguration.unixSocket(codexExecutablePath: "/tmp/codex bin",
                                                                  socketPath: "/tmp/tidey codex/app.sock",
                                                                  workingDirectory: "/tmp/tidey work",
                                                                  environment: ["CODEX_HOME": "/tmp/codex home"])

        XCTAssertEqual(config.executablePath, "/tmp/codex bin")
        XCTAssertEqual(config.arguments, ["app-server", "--listen", "unix:///tmp/tidey codex/app.sock"])
        XCTAssertEqual(config.workingDirectory, "/tmp/tidey work")
        XCTAssertEqual(config.environment["CODEX_HOME"], "/tmp/codex home")
        XCTAssertEqual(config.transport, .unixSocket(path: "/tmp/tidey codex/app.sock"))
    }

    func testStartThreadAndTurnSendCodexAppServerRequests() throws {
        let outbound = LineSink()
        let runtime = Self.runtime()
        let connection = CodexAppServerConnection(sendLine: { outbound.append($0) })

        try runtime.startThread(on: connection,
                                cwd: "/Users/timfeng/GitHub/Tidey",
                                model: "gpt-5",
                                approvalPolicy: "on-request",
                                sandbox: .string("workspace-write"))
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
        XCTAssertEqual(threadParams["sandbox"]?.stringValue, "workspace-write")
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

    func testServerNotificationsBecomeAgentEvents() throws {
        let events = EventSink()
        let runtime = Self.runtime(events: events)
        let connection = CodexAppServerConnection(sendLine: { _ in },
                                                  onNotification: runtime.handleNotification)

        connection.receiveLine("""
        {"method":"thread/started","params":{"thread":{"id":"thread-1","preview":"Build app-server runtime","name":null}}}
        """)
        connection.receiveLine("""
        {"method":"turn/started","params":{"threadId":"thread-1","turn":{"id":"turn-1","items":[],"itemsView":{"type":"all"},"status":"running","error":null,"startedAt":1,"completedAt":null,"durationMs":null}}}
        """)
        connection.receiveLine("""
        {"method":"item/agentMessage/delta","params":{"threadId":"thread-1","turnId":"turn-1","itemId":"msg-1","delta":"hello"}}
        """)
        connection.receiveLine("""
        {"method":"item/completed","params":{"threadId":"thread-1","turnId":"turn-1","item":{"type":"agentMessage","id":"msg-1","text":"hello"}}}
        """)
        connection.receiveLine("""
        {"method":"item/commandExecution/outputDelta","params":{"threadId":"thread-1","turnId":"turn-1","itemId":"cmd-1","delta":"stdout line\\n"}}
        """)
        connection.receiveLine("""
        {"method":"item/commandExecution/terminalInteraction","params":{"threadId":"thread-1","turnId":"turn-1","itemId":"cmd-1","processId":"proc-1","stdin":"y\\n"}}
        """)
        connection.receiveLine("""
        {"method":"item/fileChange/patchUpdated","params":{"threadId":"thread-1","turnId":"turn-1","itemId":"patch-1","changes":[]}}
        """)
        connection.receiveLine("""
        {"method":"turn/completed","params":{"threadId":"thread-1","turn":{"id":"turn-1","items":[],"itemsView":{"type":"all"},"status":"completed","error":null,"startedAt":1,"completedAt":2,"durationMs":1000}}}
        """)

        let emitted = events.events()
        XCTAssertEqual(emitted.map(\.type), [
            .sessionStarted,
            .thinking,
            .assistantMessage,
            .toolResult,
            .toolCall,
            .toolResult,
            .assistantFinal,
        ])
        XCTAssertEqual(emitted[0].text, "Build app-server runtime")
        XCTAssertEqual(emitted[0].metadata?["thread_id"], "thread-1")
        XCTAssertEqual(emitted[2].text, "hello")
        XCTAssertEqual(emitted[2].toolCallID, "msg-1")
        XCTAssertEqual(emitted[3].name, "terminal_stream")
        XCTAssertEqual(emitted[3].output, "stdout line\n")
        XCTAssertEqual(emitted[3].payload?.objectValue?["kind"]?.stringValue, "terminal_stream")
        XCTAssertEqual(emitted[4].name, "terminal_interaction")
        XCTAssertEqual(emitted[4].input, "y\n")
        XCTAssertEqual(emitted[4].metadata?["process_id"], "proc-1")
        XCTAssertEqual(emitted[5].name, "file_change_patch")
        XCTAssertEqual(emitted[6].type, .assistantFinal)
    }

    func testAgentMessageDeltasAreNotPublishedAsChatBubbles() throws {
        let events = EventSink()
        let runtime = Self.runtime(events: events)
        let connection = CodexAppServerConnection(sendLine: { _ in },
                                                  onNotification: runtime.handleNotification)

        connection.receiveLine("""
        {"method":"item/agentMessage/delta","params":{"threadId":"thread-1","turnId":"turn-1","itemId":"msg-1","delta":"partial"}}
        """)

        XCTAssertTrue(events.events().isEmpty)
    }

    func testServerWarningsAndFinalErrorsBecomeVisibleMessages() throws {
        let events = EventSink()
        let runtime = Self.runtime(events: events)
        let connection = CodexAppServerConnection(sendLine: { _ in },
                                                  onNotification: runtime.handleNotification)

        connection.receiveLine("""
        {"method":"warning","params":{"threadId":"thread-1","message":"Falling back from WebSockets to HTTPS transport."}}
        """)
        connection.receiveLine("""
        {"method":"error","params":{"error":{"message":"Reconnecting... 2/5","additionalDetails":"temporary network issue"},"willRetry":true,"threadId":"thread-1","turnId":"turn-1"}}
        """)
        connection.receiveLine("""
        {"method":"error","params":{"error":{"message":"unexpected status 401 Unauthorized","additionalDetails":"Missing bearer authentication"},"willRetry":false,"threadId":"thread-1","turnId":"turn-1"}}
        """)
        connection.receiveLine("""
        {"method":"turn/completed","params":{"threadId":"thread-1","turn":{"id":"turn-1","items":[],"itemsView":"notLoaded","status":"failed","error":{"message":"turn failed","additionalDetails":"request id: req-1"},"startedAt":1,"completedAt":2,"durationMs":1000}}}
        """)

        let emitted = events.events()
        XCTAssertEqual(emitted.map(\.type), [.assistantMessage, .assistantMessage, .assistantMessage])
        XCTAssertEqual(emitted.map { $0.payload?.objectValue?["kind"]?.stringValue }, ["warning", "error", "turn_failed"])
        XCTAssertEqual(emitted[0].text, "Falling back from WebSockets to HTTPS transport.")
        XCTAssertEqual(emitted[1].text, "unexpected status 401 Unauthorized\nMissing bearer authentication")
        XCTAssertEqual(emitted[2].text, "turn failed\nrequest id: req-1")
    }

    func testItemLifecycleNotificationsBecomeConversationAndToolEvents() throws {
        let events = EventSink()
        let runtime = Self.runtime(events: events)
        let connection = CodexAppServerConnection(sendLine: { _ in },
                                                  onNotification: runtime.handleNotification)

        connection.receiveLine("""
        {"method":"item/started","params":{"threadId":"thread-1","turnId":"turn-1","item":{"type":"userMessage","id":"user-1","content":[{"type":"text","text":"run tests","text_elements":[]}]}}}
        """)
        connection.receiveLine("""
        {"method":"item/started","params":{"threadId":"thread-1","turnId":"turn-1","item":{"type":"commandExecution","id":"cmd-1","command":"swift test","cwd":"/Users/timfeng/GitHub/Tidey","processId":"proc-1","source":"agent","status":"running","commandActions":[],"aggregatedOutput":null,"exitCode":null,"durationMs":null}}}
        """)
        connection.receiveLine("""
        {"method":"item/completed","params":{"threadId":"thread-1","turnId":"turn-1","item":{"type":"commandExecution","id":"cmd-1","command":"swift test","cwd":"/Users/timfeng/GitHub/Tidey","processId":"proc-1","source":"agent","status":"completed","commandActions":[],"aggregatedOutput":"ok","exitCode":0,"durationMs":42}}}
        """)

        let emitted = events.events()
        XCTAssertEqual(emitted.map(\.type), [.userMessage, .toolCall, .toolResult])
        XCTAssertEqual(emitted[0].text, "run tests")
        XCTAssertEqual(emitted[1].name, "command_execution")
        XCTAssertEqual(emitted[1].input, "swift test")
        XCTAssertEqual(emitted[1].toolCallID, "cmd-1")
        XCTAssertEqual(emitted[2].output, "ok")
        XCTAssertEqual(emitted[2].metadata?["process_id"], "proc-1")
    }

    // MARK: - Working control seam (independent of onAgentEvent)

    func testTurnStartedEmitsControlWithoutChangingOrdinaryMapping() throws {
        let events = EventSink()
        let control = ControlSink()
        let runtime = Self.runtime(events: events, control: control)
        let connection = CodexAppServerConnection(sendLine: { _ in },
                                                  onNotification: runtime.handleNotification)

        connection.receiveLine("""
        {"method":"turn/started","params":{"threadId":"thread-1","turn":{"id":"turn-1","items":[],"itemsView":{"type":"all"},"status":"running","error":null,"startedAt":1,"completedAt":null,"durationMs":null}}}
        """)

        XCTAssertEqual(events.events().map(\.type), [.thinking])
        guard case let .turnStarted(threadID, turnID, _)? = control.events().first else {
            return XCTFail("expected turnStarted control")
        }
        XCTAssertEqual(threadID, "thread-1")
        XCTAssertEqual(turnID, "turn-1")
        XCTAssertEqual(control.events().count, 1)
    }

    // Explicit callback-trace lock (not just timestamps): both accepted
    // turn/started and accepted turn/completed must invoke ordinary
    // onAgentEvent BEFORE typed onWorkingControl, in that exact order, with
    // the ordinary event's own timestamp strictly earlier than the
    // control's. A blank/malformed status must fire the ordinary callback
    // only, with zero control callbacks.
    func testAcceptedControlCallbacksFireAfterOrdinaryCallbackInExactOrder() throws {
        enum Trace: Equatable { case ordinary(AgentEventKind, String); case control(String) }
        var trace: [Trace] = []
        var tick = 0
        let timestampProvider: () -> String = {
            tick += 1
            return "ts-\(tick)"
        }
        var seq = 100
        let runtime = CodexAppServerHeadlessRuntime(
            context: CodexAppServerRuntimeContext(workspaceID: "workspace-1",
                                                  panelID: "panel-1",
                                                  sessionID: "session-1"),
            nextSequence: { _ in
                seq += 1
                return seq
            },
            timestampProvider: timestampProvider,
            onAgentEvent: { trace.append(.ordinary($0.type, $0.timestamp)) },
            onWorkingControl: { control in
                let time: String
                switch control {
                case let .turnStarted(_, _, t): time = t
                case let .turnTerminal(_, _, _, t): time = t
                default: time = "unexpected"
                }
                trace.append(.control(time))
            })
        let connection = CodexAppServerConnection(sendLine: { _ in },
                                                  onNotification: runtime.handleNotification)

        connection.receiveLine("""
        {"method":"turn/started","params":{"threadId":"thread-1","turn":{"id":"turn-1"}}}
        """)
        XCTAssertEqual(trace, [.ordinary(.thinking, "ts-1"), .control("ts-2")])

        trace.removeAll()
        connection.receiveLine("""
        {"method":"turn/completed","params":{"threadId":"thread-1","turn":{"id":"turn-1","status":"completed"}}}
        """)
        XCTAssertEqual(trace, [.ordinary(.assistantFinal, "ts-3"), .control("ts-4")])

        // Blank status: ordinary-only, zero control callbacks.
        trace.removeAll()
        connection.receiveLine("""
        {"method":"turn/completed","params":{"threadId":"thread-1","turn":{"id":"turn-1","status":""}}}
        """)
        XCTAssertEqual(trace, [.ordinary(.assistantFinal, "ts-5")])
    }

    // item/started fixtures below carry the outer startedAtMs plus each
    // item type's own official-schema required fields (collabAgentToolCall:
    // tool/status/senderThreadId/receiverThreadIds/agentsStates, with tool
    // one of wait/spawnAgent/sendInput/resumeAgent/closeAgent, status
    // inProgress, agentsStates an object; sleep: durationMs), per the
    // locally generated Codex 0.144.6 app-server JSON schema.
    func testItemStartedOpenAllowlistEmitsControlAndNoToolCard() throws {
        let fixtures: [(itemType: String, item: String, kind: CodexAppServerInternalActivityKind)] = [
            ("collabAgentToolCall",
             #"{"type":"collabAgentToolCall","id":"item-1","tool":"wait","status":"inProgress","senderThreadId":"thread-1","receiverThreadIds":["thread-2"],"agentsStates":{}}"#,
             .collabAgentToolCall),
            ("sleep",
             #"{"type":"sleep","id":"item-1","durationMs":5000}"#,
             .sleep),
        ]
        for fixture in fixtures {
            let events = EventSink()
            let control = ControlSink()
            let runtime = Self.runtime(events: events, control: control)
            let connection = CodexAppServerConnection(sendLine: { _ in },
                                                      onNotification: runtime.handleNotification)

            connection.receiveLine("""
            {"method":"item/started","params":{"threadId":"thread-1","turnId":"turn-1","startedAtMs":1,"item":\(fixture.item)}}
            """)

            XCTAssertTrue(events.events().isEmpty, "\(fixture.itemType) must not create a tool card")
            guard case let .internalActivityStarted(threadID, turnID, itemID, emittedKind, _)? = control.events().first else {
                XCTFail("expected internalActivityStarted control for \(fixture.itemType)")
                continue
            }
            XCTAssertEqual(threadID, "thread-1")
            XCTAssertEqual(turnID, "turn-1")
            XCTAssertEqual(itemID, "item-1")
            XCTAssertEqual(emittedKind, fixture.kind)
            XCTAssertEqual(control.events().count, 1)
        }
    }

    // Mutation killer: subAgentActivity has no started edge on the real
    // wire (EventMsg::SubAgentActivity maps directly to ItemCompleted). A
    // forged item/started + subAgentActivity must fail closed, never
    // synthesize a control open.
    func testForgedSubAgentActivityItemStartedFailsClosed() throws {
        let control = ControlSink()
        let runtime = Self.runtime(events: EventSink(), control: control)
        let connection = CodexAppServerConnection(sendLine: { _ in },
                                                  onNotification: runtime.handleNotification)

        connection.receiveLine("""
        {"method":"item/started","params":{"threadId":"thread-1","turnId":"turn-1","startedAtMs":1,"item":{"type":"subAgentActivity","id":"item-1","kind":"started","agentThreadId":"thread-2","agentPath":"root/child"}}}
        """)

        XCTAssertTrue(control.events().isEmpty)
    }

    // Mutation killer: subAgentActivity is observed ONLY on item/completed,
    // as a continuation pulse — never a turn terminal, never clears Working.
    func testSubAgentActivityItemCompletedEmitsContinuationPulseNotTerminal() throws {
        let events = EventSink()
        let control = ControlSink()
        let runtime = Self.runtime(events: events, control: control)
        let connection = CodexAppServerConnection(sendLine: { _ in },
                                                  onNotification: runtime.handleNotification)

        connection.receiveLine("""
        {"method":"item/completed","params":{"threadId":"thread-1","turnId":"turn-1","completedAtMs":2,"item":{"type":"subAgentActivity","id":"item-1","kind":"interacted","agentThreadId":"thread-2","agentPath":"root/child"}}}
        """)

        XCTAssertTrue(events.events().isEmpty, "subAgentActivity completion must not create a tool card")
        guard case let .internalActivityObserved(threadID, turnID, itemID, kind, _)? = control.events().first else {
            return XCTFail("expected internalActivityObserved control")
        }
        XCTAssertEqual(threadID, "thread-1")
        XCTAssertEqual(turnID, "turn-1")
        XCTAssertEqual(itemID, "item-1")
        XCTAssertEqual(kind, .subAgentActivity)
        XCTAssertEqual(control.events().count, 1)
        // Never a terminal, regardless of what a reader might assume from
        // "completed" in the method name.
        for event in control.events() {
            if case .turnTerminal = event {
                XCTFail("item/completed must never produce a turnTerminal control")
            }
        }
    }

    // Mutation killer: collabAgentToolCall/sleep completing must not add a
    // continuation control — their open pulse already established Working;
    // item/completed is not their control edge at all.
    func testCollabAndSleepItemCompletedNeverAddsControlContinuation() throws {
        let fixtures = [
            #"{"type":"collabAgentToolCall","id":"item-1","tool":"wait","status":"completed","senderThreadId":"thread-1","receiverThreadIds":["thread-2"],"agentsStates":{}}"#,
            #"{"type":"sleep","id":"item-1","durationMs":5000}"#,
        ]
        for item in fixtures {
            let control = ControlSink()
            let runtime = Self.runtime(events: EventSink(), control: control)
            let connection = CodexAppServerConnection(sendLine: { _ in },
                                                      onNotification: runtime.handleNotification)

            connection.receiveLine("""
            {"method":"item/completed","params":{"threadId":"thread-1","turnId":"turn-1","completedAtMs":2,"item":\(item)}}
            """)

            XCTAssertTrue(control.events().isEmpty, "\(item) item/completed must never emit control")
        }
    }

    // "screenshot" is NOT an official 0.144.6 ThreadItem tag — this only
    // proves an unrecognized tag fails closed, not that the real
    // screenshot-capable tool-call path is unaffected (see the schema-valid
    // fixtures below for that).
    func testUnknownItemTagIsANegativeCaseOnly() throws {
        for itemType in ["screenshot", "someFutureInternalKindNotYetAllowlisted"] {
            let events = EventSink()
            let control = ControlSink()
            let runtime = Self.runtime(events: events, control: control)
            let connection = CodexAppServerConnection(sendLine: { _ in },
                                                      onNotification: runtime.handleNotification)

            connection.receiveLine("""
            {"method":"item/started","params":{"threadId":"thread-1","turnId":"turn-1","startedAtMs":1,"item":{"type":"\(itemType)","id":"item-1"}}}
            """)

            XCTAssertTrue(control.events().isEmpty, "\(itemType) must never emit control")
            XCTAssertTrue(events.events().isEmpty, "\(itemType) ordinary mapping must remain identical (nil)")
        }
    }

    // Schema-valid non-target item types (per the locally generated 0.144.6
    // ItemStartedNotification schema, with each type's own required fields
    // and deployed status enum values). dynamicToolCall/mcpToolCall are how
    // a real screenshot tool call actually appears on the wire.
    //
    // This test proves control=0 for these types at the Headless-runtime
    // seam ONLY. It does NOT prove "exactly one ordinary card" end-to-end —
    // makeItemStartedEvent has no special case for any of these five types
    // either, so their ordinary mapping here is nil; the real screenshot
    // non-regression claim ("exactly one card") belongs to the existing
    // transcript `function_call.name=screenshot` E2E path, a different
    // producer entirely, not asserted by this Headless-only test.
    func testKnownNonTargetItemTypesEmitNoControlAtHeadlessSeam() throws {
        let fixtures = [
            #"{"type":"dynamicToolCall","id":"item-1","tool":"screenshot","arguments":"{}","status":"inProgress"}"#,
            #"{"type":"mcpToolCall","id":"item-1","server":"screenshot-server","tool":"screenshot","arguments":"{}","status":"inProgress"}"#,
            #"{"type":"imageView","id":"item-1","path":"/tmp/screenshot.png"}"#,
            #"{"type":"webSearch","id":"item-1","query":"test"}"#,
            #"{"type":"imageGeneration","id":"item-1","result":"pending","status":"inProgress"}"#,
        ]
        for item in fixtures {
            let events = EventSink()
            let control = ControlSink()
            let runtime = Self.runtime(events: events, control: control)
            let connection = CodexAppServerConnection(sendLine: { _ in },
                                                      onNotification: runtime.handleNotification)

            connection.receiveLine("""
            {"method":"item/started","params":{"threadId":"thread-1","turnId":"turn-1","startedAtMs":1,"item":\(item)}}
            """)

            XCTAssertTrue(control.events().isEmpty, "\(item) must never emit control")
            XCTAssertTrue(events.events().isEmpty, "\(item) ordinary mapping must remain identical (nil)")
        }

        // Existing normal card-bearing item types must keep their ordinary
        // mapping identical and must never emit control.
        let events = EventSink()
        let control = ControlSink()
        let runtime = Self.runtime(events: events, control: control)
        let connection = CodexAppServerConnection(sendLine: { _ in },
                                                  onNotification: runtime.handleNotification)
        connection.receiveLine("""
        {"method":"item/started","params":{"threadId":"thread-1","turnId":"turn-1","startedAtMs":1,"item":{"type":"commandExecution","id":"cmd-1","command":"swift test","cwd":"/tmp","processId":"proc-1","source":"agent","status":"inProgress","commandActions":[],"aggregatedOutput":null,"exitCode":null,"durationMs":null}}}
        """)
        XCTAssertTrue(control.events().isEmpty)
        XCTAssertEqual(events.events().map(\.type), [.toolCall])
        XCTAssertEqual(events.events().first?.name, "command_execution")
    }

    // commandExecution/fileChange completions (ordinary card-bearing types)
    // must never emit control either — item/completed's only control edge
    // is subAgentActivity (covered separately).
    func testOrdinaryItemCompletionsNeverEmitControl() throws {
        let control = ControlSink()
        let runtime = Self.runtime(events: EventSink(), control: control)
        let connection = CodexAppServerConnection(sendLine: { _ in },
                                                  onNotification: runtime.handleNotification)

        let fixtures = [
            #"{"type":"commandExecution","id":"item-1","command":"swift test","cwd":"/tmp","status":"completed","commandActions":[]}"#,
            #"{"type":"fileChange","id":"item-1","status":"completed","changes":[]}"#,
        ]
        for item in fixtures {
            connection.receiveLine("""
            {"method":"item/completed","params":{"threadId":"thread-1","turnId":"turn-1","completedAtMs":2,"item":\(item)}}
            """)
        }

        XCTAssertTrue(control.events().isEmpty)
    }

    // Real deployed 0.144.6 TurnStatus values are completed/interrupted/
    // failed/inProgress (the core "aborted" event wire-maps to interrupted
    // — it is not itself a status string on the wire). All three genuine
    // terminals are covered here; a separate case locks the
    // forward-compatible "any unknown nonblank status is still a terminal,
    // method-authoritative" contract without treating aborted/cancelled as
    // deployed schema fixtures.
    func testEveryTurnCompletedStatusEmitsTerminalControlAndFailedErrorStillExists() throws {
        for status in ["completed", "failed", "interrupted", "someFutureTerminalStatusNotYetKnown"] {
            let events = EventSink()
            let control = ControlSink()
            let runtime = Self.runtime(events: events, control: control)
            let connection = CodexAppServerConnection(sendLine: { _ in },
                                                      onNotification: runtime.handleNotification)

            connection.receiveLine("""
            {"method":"turn/completed","params":{"threadId":"thread-1","turn":{"id":"turn-1","items":[],"itemsView":{"type":"all"},"status":"\(status)","error":null,"startedAt":1,"completedAt":2,"durationMs":1000}}}
            """)

            guard case let .turnTerminal(threadID, turnID, rawStatus, _)? = control.events().first else {
                return XCTFail("expected turnTerminal control for status \(status)")
            }
            XCTAssertEqual(threadID, "thread-1")
            XCTAssertEqual(turnID, "turn-1")
            XCTAssertEqual(rawStatus, status)

            if status == "failed" {
                XCTAssertEqual(events.events().map(\.type), [.assistantMessage])
                XCTAssertEqual(events.events().first?.payload?.objectValue?["kind"]?.stringValue, "turn_failed")
            } else {
                XCTAssertEqual(events.events().map(\.type), [.assistantFinal])
            }
        }
    }

    // Mutation killer: a missing or blank status must fail closed, never
    // silently default to "completed".
    func testTurnCompletedWithMissingOrBlankStatusFailsClosed() throws {
        let control = ControlSink()
        let runtime = Self.runtime(events: EventSink(), control: control)
        let connection = CodexAppServerConnection(sendLine: { _ in },
                                                  onNotification: runtime.handleNotification)

        connection.receiveLine("""
        {"method":"turn/completed","params":{"threadId":"thread-1","turn":{"id":"turn-1"}}}
        """)
        connection.receiveLine("""
        {"method":"turn/completed","params":{"threadId":"thread-1","turn":{"id":"turn-1","status":"   "}}}
        """)

        XCTAssertTrue(control.events().isEmpty)
    }

    func testBlankIDsFailClosedForControl() throws {
        let control = ControlSink()
        let runtime = Self.runtime(events: EventSink(), control: control)
        let connection = CodexAppServerConnection(sendLine: { _ in },
                                                  onNotification: runtime.handleNotification)

        connection.receiveLine("""
        {"method":"turn/started","params":{"threadId":"","turn":{"id":"turn-1"}}}
        """)
        connection.receiveLine("""
        {"method":"turn/started","params":{"threadId":"thread-1","turn":{"id":""}}}
        """)
        connection.receiveLine("""
        {"method":"item/started","params":{"threadId":"thread-1","turnId":"turn-1","startedAtMs":1,"item":{"type":"sleep","id":"","durationMs":5000}}}
        """)
        connection.receiveLine("""
        {"method":"turn/completed","params":{"threadId":"","turn":{"id":"turn-1","status":"completed"}}}
        """)

        XCTAssertTrue(control.events().isEmpty)
    }

    func testControlEmissionNeverConsumesTheOrdinarySequenceCounter() throws {
        var sequenceCallCount = 0
        let control = ControlSink()
        let runtime = CodexAppServerHeadlessRuntime(
            context: CodexAppServerRuntimeContext(workspaceID: "workspace-1",
                                                  panelID: "panel-1",
                                                  sessionID: "session-1"),
            nextSequence: { _ in
                sequenceCallCount += 1
                return sequenceCallCount
            },
            timestampProvider: { "2026-06-05T12:00:00.000Z" },
            onAgentEvent: { _ in XCTFail("sleep item must not produce an AgentEvent") },
            onWorkingControl: { control.append($0) })
        let connection = CodexAppServerConnection(sendLine: { _ in },
                                                  onNotification: runtime.handleNotification)

        connection.receiveLine("""
        {"method":"item/started","params":{"threadId":"thread-1","turnId":"turn-1","startedAtMs":1,"item":{"type":"sleep","id":"item-1","durationMs":5000}}}
        """)

        XCTAssertEqual(control.events().count, 1)
        XCTAssertEqual(sequenceCallCount, 0)
    }

    // Mutation killer: `emitWorkingControl` must never consume a timestamp
    // tick for a rejected/non-allowlisted/malformed observation, and must
    // never shift the ordinary makeEvent/onAgentEvent path's timestamp —
    // this is what an eagerly-evaluated `time: timestampProvider()`
    // argument (evaluated even when the callee's internal guard fails)
    // would silently break.
    func testRejectedControlObservationsNeverConsumeATimestampTickOrShiftOrdinaryMapping() throws {
        var timestampCallCount = 0
        let timestampProvider: () -> String = {
            timestampCallCount += 1
            return "ts-\(timestampCallCount)"
        }
        let events = EventSink()
        let control = ControlSink()
        var seq = 100
        let runtime = CodexAppServerHeadlessRuntime(
            context: CodexAppServerRuntimeContext(workspaceID: "workspace-1",
                                                  panelID: "panel-1",
                                                  sessionID: "session-1"),
            nextSequence: { _ in
                seq += 1
                return seq
            },
            timestampProvider: timestampProvider,
            onAgentEvent: { events.append($0) },
            onWorkingControl: { control.append($0) })
        let connection = CodexAppServerConnection(sendLine: { _ in },
                                                  onNotification: runtime.handleNotification)

        // Schema-valid non-target item/started types: reach the control
        // seam's guard, fail the allowlist check, and must not touch the
        // timestamp provider at all.
        for item in [
            #"{"type":"dynamicToolCall","id":"item-1","tool":"screenshot","arguments":"{}","status":"inProgress"}"#,
            #"{"type":"mcpToolCall","id":"item-1","server":"s","tool":"screenshot","arguments":"{}","status":"inProgress"}"#,
            #"{"type":"imageView","id":"item-1","path":"/tmp/screenshot.png"}"#,
        ] {
            connection.receiveLine("""
            {"method":"item/started","params":{"threadId":"thread-1","turnId":"turn-1","startedAtMs":1,"item":\(item)}}
            """)
        }
        XCTAssertEqual(timestampCallCount, 0)
        XCTAssertTrue(control.events().isEmpty)

        // Ordinary commandExecution/fileChange item/started+item/completed
        // both reach the control guard (fail allowlist) AND the ordinary
        // makeEvent path (succeeds) — the ordinary path's timestamp must be
        // exactly the Nth tick as if the control seam didn't exist at all.
        connection.receiveLine("""
        {"method":"item/started","params":{"threadId":"thread-1","turnId":"turn-1","startedAtMs":1,"item":{"type":"commandExecution","id":"cmd-1","command":"swift test","cwd":"/tmp","processId":"proc-1","source":"agent","status":"inProgress","commandActions":[],"aggregatedOutput":null,"exitCode":null,"durationMs":null}}}
        """)
        connection.receiveLine("""
        {"method":"item/completed","params":{"threadId":"thread-1","turnId":"turn-1","completedAtMs":2,"item":{"type":"fileChange","id":"patch-1","status":"completed","changes":[]}}}
        """)
        XCTAssertTrue(control.events().isEmpty)
        XCTAssertEqual(events.events().map(\.type), [.toolCall, .toolResult])
        XCTAssertEqual(timestampCallCount, 2)
        XCTAssertEqual(events.events()[0].timestamp, "ts-1")
        XCTAssertEqual(events.events()[1].timestamp, "ts-2")

        // turn/started: the ordinary makeEvent/onAgentEvent path runs FIRST
        // at its original position and consumes the next tick exactly as it
        // would with no control seam at all; the typed control observation
        // only runs AFTER onAgentEvent and consumes the tick following it —
        // never the reverse, never a shared tick.
        connection.receiveLine("""
        {"method":"turn/started","params":{"threadId":"thread-1","turn":{"id":"turn-1"}}}
        """)
        XCTAssertEqual(control.events().count, 1)
        XCTAssertEqual(timestampCallCount, 4)
        XCTAssertEqual(events.events()[2].timestamp, "ts-3")
        guard case let .turnStarted(_, _, controlTime)? = control.events().first else {
            return XCTFail("expected turnStarted control")
        }
        XCTAssertEqual(controlTime, "ts-4")

        // Malformed turn/completed (blank status): the control seam fails
        // closed and must not consume a tick for itself, but the ORDINARY
        // path is untouched by this control-only fix — it has never gated
        // on status and still fires exactly as it did before this seam
        // existed, consuming its own next tick.
        connection.receiveLine("""
        {"method":"turn/completed","params":{"threadId":"thread-1","turn":{"id":"turn-1","status":""}}}
        """)
        XCTAssertEqual(timestampCallCount, 5)
        XCTAssertEqual(events.events()[3].timestamp, "ts-5")
        XCTAssertEqual(control.events().count, 1, "control must still be exactly the one turnStarted from earlier")
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

    private static func runtime(events: EventSink) -> CodexAppServerHeadlessRuntime {
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
            onAgentEvent: { events.append($0) })
    }

    private static func runtime(events: EventSink, control: ControlSink) -> CodexAppServerHeadlessRuntime {
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
            onAgentEvent: { events.append($0) },
            onWorkingControl: { control.append($0) })
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

private final class EventSink: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [AgentEvent] = []

    func append(_ event: AgentEvent) {
        lock.lock()
        storage.append(event)
        lock.unlock()
    }

    func events() -> [AgentEvent] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private final class ControlSink: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [CodexAppServerWorkingControlEvent] = []

    func append(_ event: CodexAppServerWorkingControlEvent) {
        lock.lock()
        storage.append(event)
        lock.unlock()
    }

    func events() -> [CodexAppServerWorkingControlEvent] {
        lock.lock()
        defer { lock.unlock() }
        return storage
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
