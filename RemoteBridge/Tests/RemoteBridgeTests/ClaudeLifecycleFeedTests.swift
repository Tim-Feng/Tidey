import XCTest
@testable import RemoteBridge

// Claude three-state lifecycle: transcript live tail + typed hook journal
// feeding AgentSessionLifecycleStore — live/replay separation, filtered
// text, array-form prompts/interrupts, Ask blockers, permission blockers.
final class ClaudeLifecycleFeedTests: XCTestCase {
    private var directory: URL!
    private var transcriptURL: URL!
    private var hookJournalURL: URL!
    private var store: AgentSessionLifecycleStore!
    private var hub: AgentEventHub!
    private var session: ClaudeTranscriptSession!
    private let identity = AgentSessionLifecycleIdentity(workspaceID: "workspace",
                                                         panelID: "panel",
                                                         sessionID: "session")

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeLifecycleFeedTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        transcriptURL = directory.appendingPathComponent("session.jsonl", isDirectory: false)
        hookJournalURL = directory.appendingPathComponent("claude-hooks-session.jsonl", isDirectory: false)
        try Data().write(to: transcriptURL)
        try Data().write(to: hookJournalURL)
        store = AgentSessionLifecycleStore()
        hub = AgentEventHub()
        session = ClaudeTranscriptSession(record: makeRecord(),
                                          fileManager: .default,
                                          hub: hub)
        session.lifecycleStoreForTesting = store
        session.hookJournalURLOverrideForTesting = hookJournalURL
    }

    override func tearDown() {
        session?.stop()
        session = nil
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeRecord() -> AgentSessionRegistryRecord {
        AgentSessionRegistryRecord(version: 1,
                                   vendor: "claude",
                                   workspaceID: "workspace",
                                   sessionID: "session",
                                   panelID: "panel",
                                   pid: Int32(ProcessInfo.processInfo.processIdentifier),
                                   cwd: "/tmp",
                                   createdAt: "2026-07-18T00:00:00Z",
                                   transcriptPath: transcriptURL.path)
    }

    private func state() -> AgentSessionDisplayState? {
        store.snapshot(identity)?.state
    }

    private func waitForState(_ expected: AgentSessionDisplayState,
                              timeout: TimeInterval = 3,
                              file: StaticString = #filePath,
                              line: UInt = #line) {
        XCTAssertTrue(waitUntil(timeout: timeout) { self.state() == expected },
                      "expected \(expected), got \(String(describing: state()))",
                      file: file, line: line)
    }

    private func waitUntil(timeout: TimeInterval = 3, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return true
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return condition()
    }

    // Starts the session and proves the LIVE tail is active: an append can
    // race the tailer's bootstrap/seek window, so meta probe lines are
    // appended until one is observed (meta lines have no lifecycle effect).
    private func startSessionAndWaitForTail(file: StaticString = #filePath,
                                            line: UInt = #line) throws {
        session.start()
        for attempt in 1...10 {
            try appendTranscript([userLine(uuid: "tail-probe-\(attempt)",
                                           text: "tail probe \(attempt)",
                                           isMeta: true)])
            let observed = waitUntil(timeout: 0.5) {
                self.hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 500)
                    .events.contains { ($0.text ?? "") == "tail probe \(attempt)" }
            }
            if observed {
                return
            }
        }
        XCTFail("transcript tailer never became active", file: file, line: line)
    }

    private func appendTranscript(_ lines: [String]) throws {
        let handle = try FileHandle(forWritingTo: transcriptURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((lines.joined(separator: "\n") + "\n").utf8))
        try handle.close()
    }

    private func appendHook(event: String,
                            payload: String = "null",
                            ts: String? = nil,
                            epoch: String? = nil,
                            eventID: String? = nil,
                            seq: Int? = nil) throws {
        let handle = try FileHandle(forWritingTo: hookJournalURL)
        try handle.seekToEnd()
        let stamp = ts ?? ISO8601DateFormatter().string(from: Date())
        var fields = #""v":3,"event":"\#(event)","ts":"\#(stamp)""#
        if let epoch {
            fields += #","epoch":"\#(epoch)""#
        }
        if let eventID {
            fields += #","event_id":"\#(eventID)""#
        }
        if let seq {
            fields += #","seq":\#(seq)"#
        }
        let line = "{" + fields + #","payload":\#(payload)}"# + "\n"
        try handle.write(contentsOf: Data(line.utf8))
        try handle.close()
    }

    // MARK: - Transcript line builders (current 2.x schema shapes)

    private func parentField(_ parentUuid: String?) -> String {
        parentUuid.map { #""parentUuid":"\#($0)","# } ?? ""
    }

    private func userLine(uuid: String, text: String, isMeta: Bool = false, parentUuid: String? = nil) -> String {
        let meta = isMeta ? #""isMeta":true,"# : ""
        return #"{"type":"user","uuid":"\#(uuid)",\#(parentField(parentUuid))"sessionId":"session","version":"2.1.0",\#(meta)"message":{"role":"user","content":\#(jsonString(text))}}"#
    }

    private func userArrayLine(uuid: String, blocks: [String], parentUuid: String? = nil) -> String {
        #"{"type":"user","uuid":"\#(uuid)",\#(parentField(parentUuid))"sessionId":"session","version":"2.1.0","message":{"role":"user","content":[\#(blocks.joined(separator: ","))]}}"#
    }

    private func assistantToolUseLine(uuid: String, toolCallID: String, name: String, input: String = "{}", parentUuid: String? = nil) -> String {
        #"{"type":"assistant","uuid":"\#(uuid)",\#(parentField(parentUuid))"sessionId":"session","version":"2.1.0","message":{"role":"assistant","content":[{"type":"tool_use","id":"\#(toolCallID)","name":"\#(name)","input":\#(input)}]}}"#
    }

    private func turnDurationLine(uuid: String, parentUuid: String? = nil) -> String {
        #"{"type":"system","subtype":"turn_duration","uuid":"\#(uuid)",\#(parentField(parentUuid))"sessionId":"session","version":"2.1.0","durationMs":1200}"#
    }

    private func jsonString(_ text: String) -> String {
        let data = (try? JSONEncoder().encode([text])) ?? Data("[\"\"]".utf8)
        let encoded = String(decoding: data, as: UTF8.self)
        return String(encoded.dropFirst().dropLast())
    }

    // MARK: - D7: prompts, interrupts, filtered text

    func testGenuinePromptOpensTurnAndTurnDurationEndsIt() throws {
        try startSessionAndWaitForTail()

        // Filtered strings never open a turn.
        try appendTranscript([
            userLine(uuid: "u0", text: "<command-name>/context</command-name> <command-message>context</command-message> <command-args></command-args>"),
            userLine(uuid: "u1", text: "<system-reminder>background noise</system-reminder>"),
            userLine(uuid: "u2", text: "meta note", isMeta: true),
        ])
        XCTAssertFalse(waitUntil(timeout: 0.5) { self.state() == .working },
                       "filtered/meta text must not open Working")

        try appendTranscript([userLine(uuid: "u3", text: "please fix the bug")])
        waitForState(.working)

        try appendTranscript([turnDurationLine(uuid: "s1")])
        waitForState(.idle)
    }

    func testArrayFormPromptBeginsAndArrayInterruptEnds() throws {
        try startSessionAndWaitForTail()

        // Genuine array-form prompt (text + image attachment).
        try appendTranscript([userArrayLine(uuid: "u1", blocks: [
            #"{"type":"text","text":"look at this screenshot"}"#,
            #"{"type":"image","source":{"type":"base64","media_type":"image/png","data":"aGk="}}"#,
        ])])
        waitForState(.working)

        // Array-form interrupt terminates the turn.
        try appendTranscript([userArrayLine(uuid: "u2", blocks: [
            #"{"type":"text","text":"[Request interrupted by user]"}"#,
        ])])
        waitForState(.idle)

        // A lone array tool_result never opens a new turn.
        try appendTranscript([userArrayLine(uuid: "u3", blocks: [
            #"{"type":"tool_result","tool_use_id":"tu-x","content":"done"}"#,
        ])])
        XCTAssertFalse(waitUntil(timeout: 0.5) { self.state() == .working },
                       "array tool_result must not open a turn")
    }

    // MARK: - D8: Ask blocker + Stop-not-terminal

    func testAskUserQuestionBlocksAndToolResultResolvesEvenForMultiSelect() throws {
        try startSessionAndWaitForTail()

        try appendTranscript([userLine(uuid: "u1", text: "start the task")])
        waitForState(.working)

        // multiSelect: the CARD is unsupported, the blocker still opens.
        let askInput = #"{"questions":[{"header":"Choose","question":"which ones?","multiSelect":true,"options":[{"label":"A"},{"label":"B"}]}]}"#
        try appendTranscript([assistantToolUseLine(uuid: "a1", toolCallID: "ask-1", name: "AskUserQuestion", input: askInput)])
        waitForState(.needsInput)

        // Stop gated by an active stop hook is NOT a terminal — the blocker
        // survives it.
        try appendHook(event: "stop", payload: #"{"session_id":"session","stop_hook_active":true}"#)
        XCTAssertFalse(waitUntil(timeout: 0.5) { self.state() != .needsInput },
                       "Stop hook must not terminalize a blocked turn")

        // tool_result resolves by tool_use_id; the turn is still running.
        try appendTranscript([userArrayLine(uuid: "u2", blocks: [
            #"{"type":"tool_result","tool_use_id":"ask-1","content":"A"}"#,
        ])])
        waitForState(.working)

        try appendTranscript([turnDurationLine(uuid: "s1")])
        waitForState(.idle)
    }

    func testOverlappingRepeatedAskKeepsNewerLifecycleBlockerOpenAfterDelayedResult() throws {
        try startSessionAndWaitForTail()

        try appendTranscript([userLine(uuid: "u1", text: "start the task")])
        waitForState(.working)
        let askInput = #"{"questions":[{"header":"Q","question":"pick one","options":[{"label":"A"},{"label":"B"}]}]}"#
        try appendTranscript([
            assistantToolUseLine(uuid: "ask-a", toolCallID: "reused-ask", name: "AskUserQuestion", input: askInput),
            assistantToolUseLine(uuid: "ask-b", toolCallID: "reused-ask", name: "AskUserQuestion", input: askInput),
        ])
        XCTAssertTrue(waitUntil {
            self.hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 500)
                .events.filter { $0.type == .interactivePrompt && $0.toolCallID == "reused-ask" }
                .count == 2
        })
        waitForState(.needsInput)

        try appendTranscript([userArrayLine(uuid: "result-a", blocks: [
            #"{"type":"tool_result","tool_use_id":"reused-ask","content":"A"}"#,
        ])])
        XCTAssertFalse(waitUntil(timeout: 0.6) { self.state() != .needsInput },
                       "the delayed first result must not clear the newer Ask lifecycle")

        try appendTranscript([userArrayLine(uuid: "result-b", blocks: [
            #"{"type":"tool_result","tool_use_id":"reused-ask","content":"B"}"#,
        ])])
        waitForState(.working)
    }

    func testStopIsTurnScopedIdleEdgeWithActivityRecovery() throws {
        try startSessionAndWaitForTail()

        try appendHook(event: "prompt-submit", payload: #"{"session_id":"session"}"#)
        try appendTranscript([userLine(uuid: "turn-a", text: "task A")])
        waitForState(.working)

        // Genuine Stop: a turn-scoped idle edge for the bound turn.
        try appendHook(event: "stop", payload: #"{"session_id":"session"}"#)
        waitForState(.idle)

        // If a Stop hook prevented continuation after all, later assistant
        // activity restores Working (reconciliation) — the Stop cannot
        // permanently pin the session idle.
        try appendTranscript([assistantToolUseLine(uuid: "a1", toolCallID: "t1", name: "Bash")])
        waitForState(.working)
        try appendTranscript([turnDurationLine(uuid: "s-a")])
        waitForState(.idle)
    }

    func testLateStopForTurnACannotEndTurnB() throws {
        try startSessionAndWaitForTail()

        try appendHook(event: "prompt-submit", payload: #"{"session_id":"session"}"#)
        try appendTranscript([userLine(uuid: "turn-a", text: "task A")])
        waitForState(.working)
        // B's opener lands before A's stop: the stop token is bound to A.
        try appendTranscript([userLine(uuid: "turn-b", text: "task B")])
        waitForState(.working)

        try appendHook(event: "stop", payload: #"{"session_id":"session"}"#)
        XCTAssertFalse(waitUntil(timeout: 0.8) { self.state() != .working },
                       "turn A's late stop terminated turn B")
    }

    // MARK: - D6: typed hook permission lifecycle

    func testPermissionPromptHookOpensNeedsInputAndToolResultResolves() throws {
        try startSessionAndWaitForTail()

        try appendTranscript([userLine(uuid: "u1", text: "run the migration")])
        waitForState(.working)

        // PermissionRequest PREPARES only — no needs_input yet (it may be
        // auto-allowed by another hook).
        try appendHook(event: "permission-request",
                       payload: #"{"session_id":"session","tool_name":"Bash","tool_use_id":"tu-9"}"#)
        XCTAssertFalse(waitUntil(timeout: 0.4) { self.state() == .needsInput },
                       "PermissionRequest alone must not open needs_input")

        // The ACTUAL permission prompt opens the blocker.
        try appendHook(event: "notification-permission", payload: #"{"session_id":"session"}"#)
        waitForState(.needsInput)
        // Duplicate notification does not double-open (single blocker).
        try appendHook(event: "notification-permission", payload: #"{"session_id":"session"}"#)
        XCTAssertTrue(waitUntil { self.store.snapshot(self.identity)?.blockerIDs.count == 1 })

        // Local allow: the tool runs and its tool_result proves the decision.
        try appendTranscript([userArrayLine(uuid: "u2", blocks: [
            #"{"type":"tool_result","tool_use_id":"tu-9","content":"ok"}"#,
        ])])
        waitForState(.working)

        try appendTranscript([turnDurationLine(uuid: "s1")])
        waitForState(.idle)
    }

    func testIdlePromptNotificationClearsStalePermissionBlocker() throws {
        try startSessionAndWaitForTail()

        try appendTranscript([userLine(uuid: "u1", text: "do something")])
        waitForState(.working)
        try appendHook(event: "notification-permission", payload: #"{"session_id":"session"}"#)
        waitForState(.needsInput)

        // The prompt disappeared locally (dismissed); the idle_prompt
        // notification is the waiting-at-prompt terminal.
        try appendHook(event: "notification-idle", payload: #"{"session_id":"session"}"#)
        waitForState(.idle)
    }

    func testSessionEndHookEndsSession() throws {
        try startSessionAndWaitForTail()
        try appendTranscript([userLine(uuid: "u1", text: "work work")])
        waitForState(.working)

        try appendHook(event: "session-end", payload: #"{"session_id":"session"}"#)
        waitForState(.idle)
        XCTAssertTrue(waitUntil { self.store.snapshot(self.identity)?.ended == true })
    }

    // MARK: - Midreview 1 (round2b revision): token-correlated turn fence
    // No timestamps anywhere: correlation is prompt-submit token -> turn id.

    func testLateHookIdleForTurnACannotEndTurnBOpenedBeforeATerminal() throws {
        try startSessionAndWaitForTail()

        // Hook stream: turn A's submit token.
        try appendHook(event: "prompt-submit", payload: #"{"session_id":"session"}"#)
        try appendTranscript([userLine(uuid: "turn-a", text: "task A")])
        waitForState(.working)

        // ADVERSARIAL: turn B's opener arrives BEFORE turn A's terminal —
        // the opener adopts the NEW turn identity immediately.
        try appendTranscript([userLine(uuid: "turn-b", text: "task B")])
        waitForState(.working)

        // Turn A's late idle (its token is bound to A) must not end B —
        // even in the same wall-clock instant; no timestamps are involved.
        try appendHook(event: "notification-idle", payload: #"{"session_id":"session"}"#)
        XCTAssertFalse(waitUntil(timeout: 0.8) { self.state() != .working },
                       "turn A's late idle terminated turn B")

        // B still terminates through its own transcript terminal.
        try appendTranscript([turnDurationLine(uuid: "s-b")])
        waitForState(.idle)
    }

    func testLatePermissionPromptForTurnACannotBlockTurnB() throws {
        try startSessionAndWaitForTail()

        try appendHook(event: "prompt-submit", payload: #"{"session_id":"session"}"#)
        try appendTranscript([userLine(uuid: "turn-a", text: "task A")])
        waitForState(.working)
        try appendTranscript([turnDurationLine(uuid: "s-a")])
        waitForState(.idle)

        // Turn B: NEW submit token + opener.
        try appendHook(event: "prompt-submit", payload: #"{"session_id":"session"}"#)
        try appendTranscript([userLine(uuid: "turn-b", text: "task B")])
        waitForState(.working)
        try appendTranscript([turnDurationLine(uuid: "s-b")])
        waitForState(.idle)

        // Turn A's late permission prompt: no open hook token any more —
        // rejected outright, no needs_input.
        try appendHook(event: "notification-permission", payload: #"{"session_id":"session"}"#)
        XCTAssertFalse(waitUntil(timeout: 0.8) { self.state() == .needsInput },
                       "a closed turn's late permission prompt opened a blocker")
    }

    func testLocalCommandSubmitTokenNeverBindsAndItsIdleDoesNotDisruptTheNextRealTurn() throws {
        try startSessionAndWaitForTail()

        // A local command's own submit token is consumed (unbound: the
        // transcript envelope is intercepted before any lifecycleBeginTurn
        // call) and its own idle notification must not throw off — or
        // spuriously start — anything.
        try appendHook(event: "prompt-submit", payload: #"{"session_id":"session"}"#)
        try appendTranscript([userLine(uuid: "cmd-1", text: "<command-name>/context</command-name> <command-message>context</command-message> <command-args></command-args>")])
        try appendHook(event: "notification-idle", payload: #"{"session_id":"session"}"#)
        XCTAssertFalse(waitUntil(timeout: 0.5) { self.state() == .working },
                       "an unbound local-command token's idle spuriously started Working")

        // The NEXT real task still opens and closes normally afterward.
        try appendHook(event: "prompt-submit", payload: #"{"session_id":"session"}"#)
        try appendTranscript([userLine(uuid: "turn-a", text: "real task")])
        waitForState(.working)
        try appendHook(event: "notification-idle", payload: #"{"session_id":"session"}"#)
        waitForState(.idle)
    }

    // Explicit production-order adversarial case: submit A, A's turn opens
    // (bound + running), submit B is QUEUED while A is still active, B's
    // turn opens later (Claude Code only starts a queued turn once the
    // prior one finishes) — the late terminal/permission meant for A must
    // resolve to A specifically (FIFO: oldest open token first) and never
    // touch B.
    // Genuine parentUuid fixture: turn A opens (self-rooted). Turn B's
    // opener arrives and becomes `lifecycleActiveTurnID` (adopted). ONLY
    // THEN does A's own trailing assistant AskUserQuestion line get
    // appended (its parentUuid chains back to A's user uuid, not B's).
    // Correct behavior: the opener's SOURCE TURN is resolved via the
    // parentUuid chain to A specifically — proving the fence is now
    // MEANINGFUL. Before this fix, passing `lifecycleActiveTurnID` (read
    // fresh, i.e. "whatever is current") as the expected turn made the
    // fence a trivial no-op (current always equals itself), letting a
    // stale turn A opener wrongly attach to B and put the (unrelated,
    // still-running) B into needs_input. With true source attribution, the
    // store correctly recognizes this opener belongs to an
    // already-superseded turn (A, not the current B) and REJECTS it — B's
    // own state is left completely undisturbed.
    func testLateAskUserQuestionWithParentUuidChainCannotContaminateCurrentB() throws {
        try startSessionAndWaitForTail()

        try appendTranscript([userLine(uuid: "turn-a", text: "task A")])
        waitForState(.working)

        // B's opener adopts — lifecycleActiveTurnID is now "turn-b".
        try appendTranscript([userLine(uuid: "turn-b", text: "task B")])
        waitForState(.working)

        // A's OWN assistant AskUserQuestion line, chained via parentUuid
        // back to "turn-a" — arrives AFTER B already became current. Its
        // true source (A) is no longer the active turn, so the store's
        // turn fence correctly rejects it — B keeps running, undisturbed.
        let askInput = #"{"questions":[{"header":"Q","question":"pick","options":[{"label":"X"}]}]}"#
        try appendTranscript([assistantToolUseLine(uuid: "a-ask-for-a", toolCallID: "ask-a", name: "AskUserQuestion",
                                                   input: askInput, parentUuid: "turn-a")])
        XCTAssertFalse(waitUntil(timeout: 0.6) { self.state() == .needsInput },
                       "a stale turn A opener (misattributed as current) wrongly blocked B")
        XCTAssertEqual(state(), .working, "B must be completely undisturbed by A's stale opener")

        // B terminates normally — no orphaned A blocker was ever left
        // behind to interfere.
        try appendTranscript([turnDurationLine(uuid: "s-b", parentUuid: "turn-b")])
        waitForState(.idle)
    }

    func testQueuedSubmitBWhileAActiveThenLateTerminalForACorrelatesToA() throws {
        try startSessionAndWaitForTail()

        try appendHook(event: "prompt-submit", payload: #"{"session_id":"session"}"#)
        try appendTranscript([userLine(uuid: "turn-a", text: "task A")])
        waitForState(.working)

        // B is submitted (queued) WHILE A is still the active/bound turn.
        try appendHook(event: "prompt-submit", payload: #"{"session_id":"session"}"#)
        XCTAssertEqual(state(), .working, "queuing B must not disturb A's active state")

        // A's own late permission prompt correlates to A (the oldest open,
        // currently-bound token) via FIFO — needs_input for A's blocker.
        try appendHook(event: "notification-permission", payload: #"{"session_id":"session"}"#)
        waitForState(.needsInput)
        XCTAssertEqual(store.snapshot(identity)?.blockerIDs, ["permission:prompt"])

        // A resolves and terminates (FIFO closes A's token specifically).
        try appendTranscript([turnDurationLine(uuid: "s-a")])
        waitForState(.idle)

        // B's turn starts only now (Claude Code processed the queue) and
        // binds the SECOND (still-open) token; B runs and closes normally.
        try appendTranscript([userLine(uuid: "turn-b", text: "task B")])
        waitForState(.working)
        try appendHook(event: "notification-idle", payload: #"{"session_id":"session"}"#)
        waitForState(.idle)
    }

    func testStaleSeqEnvelopeIsDropped() throws {
        try startSessionAndWaitForTail()

        try appendHook(event: "prompt-submit", payload: #"{"session_id":"session"}"#,
                       epoch: "100-1000", eventID: "e1", seq: 1)
        try appendTranscript([userLine(uuid: "turn-a", text: "task A")])
        waitForState(.working)
        try appendHook(event: "notification-idle", payload: #"{"session_id":"session"}"#,
                       epoch: "100-1000", eventID: "e2", seq: 3)
        waitForState(.idle)

        try appendTranscript([userLine(uuid: "turn-b", text: "task B")])
        waitForState(.working)

        // Replayed envelope with a NON-ADVANCING per-epoch sequence: dropped
        // before it can touch anything.
        try appendHook(event: "notification-idle", payload: #"{"session_id":"session"}"#,
                       epoch: "100-1000", eventID: "e3", seq: 2)
        XCTAssertFalse(waitUntil(timeout: 0.8) { self.state() != .working },
                       "a stale-sequence envelope terminated the newer turn")
    }

    func testLateOldSessionStartCannotReAdoptOldEpoch() throws {
        try startSessionAndWaitForTail()

        try appendHook(event: "session-start", payload: #"{"session_id":"session"}"#, epoch: "300-3000")
        try appendTranscript([userLine(uuid: "u1", text: "task")])
        waitForState(.working)

        // A retired wrapper's LATE session-start (older start time) must
        // not re-adopt the old epoch...
        try appendHook(event: "session-start", payload: #"{"session_id":"session"}"#, epoch: "100-1000")
        XCTAssertFalse(waitUntil(timeout: 0.6) { self.state() != .working },
                       "late old session-start reset the newer epoch's state")
        // ...and the old epoch's follow-up events stay rejected.
        try appendHook(event: "notification-permission", payload: #"{"session_id":"session"}"#, epoch: "100-1000")
        XCTAssertFalse(waitUntil(timeout: 0.6) { self.state() == .needsInput })
    }

    func testSameSecondOlderHighResolutionEpochCannotRetireNewerEpoch() throws {
        try startSessionAndWaitForTail()

        // The Bridge may first observe the newer wrapper after attaching to
        // an already-running session. Both wrappers started within the same
        // wall-clock second, so the subsecond suffix is the only ordering
        // information available.
        let olderEpoch = "4100-1784720284173003000"
        let newerEpoch = "4200-1784720284173003999"
        try appendHook(event: "session-start",
                       payload: #"{"session_id":"session"}"#,
                       epoch: newerEpoch)
        try appendTranscript([userLine(uuid: "u1", text: "new wrapper task")])
        waitForState(.working)

        // A late session-start from the older wrapper must not retire the
        // newer epoch or reset its active turn.
        try appendHook(event: "session-start",
                       payload: #"{"session_id":"session"}"#,
                       epoch: olderEpoch)
        XCTAssertFalse(waitUntil(timeout: 0.6) { self.state() != .working },
                       "same-second older wrapper retired the newer epoch")

        // Once rejected, every later event from that older epoch remains
        // unable to open a blocker or terminate the newer wrapper's turn.
        try appendHook(event: "notification-permission",
                       payload: #"{"session_id":"session"}"#,
                       epoch: olderEpoch)
        XCTAssertFalse(waitUntil(timeout: 0.6) { self.state() == .needsInput },
                       "same-second older wrapper opened a blocker")
        try appendHook(event: "notification-idle",
                       payload: #"{"session_id":"session"}"#,
                       epoch: olderEpoch)
        XCTAssertFalse(waitUntil(timeout: 0.6) { self.state() != .working },
                       "same-second older wrapper terminated the newer turn")
    }

    func testSourceSwitchDoesNotResurrectRetiredHookEpochs() throws {
        try startSessionAndWaitForTail()

        // Epoch 100 retired by epoch 200.
        try appendHook(event: "session-start", payload: #"{"session_id":"session"}"#, epoch: "100-1000")
        try appendHook(event: "notification-permission",
                       payload: #"{"session_id":"session"}"#,
                       epoch: "100-1000")
        waitForState(.needsInput)
        try appendHook(event: "session-start", payload: #"{"session_id":"session"}"#, epoch: "200-2000")
        waitForState(.idle)
        try appendTranscript([userLine(uuid: "u1", text: "task")])
        waitForState(.working)

        // Transcript source switch claims a new generation...
        let newTranscriptURL = directory.appendingPathComponent("session-2.jsonl", isDirectory: false)
        try Data().write(to: newTranscriptURL)
        let dict: [String: Any] = [
            "version": 1, "vendor": "claude", "workspace_id": "workspace",
            "session_id": "session", "panel_id": "panel",
            "pid": Int(ProcessInfo.processInfo.processIdentifier),
            "cwd": "/tmp", "created_at": "2026-07-18T00:00:00Z",
            "transcript_path": newTranscriptURL.path,
        ]
        let data = try JSONSerialization.data(withJSONObject: dict)
        session.update(record: try JSONDecoder().decode(AgentSessionRegistryRecord.self, from: data))
        waitForState(.idle)

        // ...but the RETIRED hook epoch stays retired: its late events must
        // not re-enter under the fresh generation.
        try appendHook(event: "notification-permission", payload: #"{"session_id":"session"}"#, epoch: "100-1000")
        XCTAssertFalse(waitUntil(timeout: 0.8) { self.state() == .needsInput },
                       "a retired hook epoch revived under the new lifecycle generation")
    }

    // MARK: - Midreview 2: hook source epoch + duplicate rejection

    func testOldWrapperEpochLateEventsAreRejectedAfterNewEpoch() throws {
        try startSessionAndWaitForTail()

        try appendHook(event: "session-start", payload: #"{"session_id":"session"}"#, epoch: "100-1000")
        try appendTranscript([userLine(uuid: "u1", text: "task")])
        waitForState(.working)

        // New wrapper instance for the resumed session adopts a NEW epoch.
        try appendHook(event: "session-start", payload: #"{"session_id":"session"}"#, epoch: "200-2000")
        waitForState(.idle)  // session-start reconciles to idle
        try appendTranscript([userLine(uuid: "u2", text: "task again")])
        waitForState(.working)

        // Old wrapper's late permission prompt (current timestamp, but the
        // retired epoch) may not open anything.
        try appendHook(event: "notification-permission", payload: #"{"session_id":"session"}"#, epoch: "100-1000")
        XCTAssertFalse(waitUntil(timeout: 0.6) { self.state() == .needsInput },
                       "retired wrapper epoch opened a blocker")

        // Old epoch's late idle may not end the new epoch's turn either.
        try appendHook(event: "notification-idle", payload: #"{"session_id":"session"}"#, epoch: "100-1000")
        XCTAssertFalse(waitUntil(timeout: 0.6) { self.state() != .working },
                       "retired wrapper epoch terminated the newer turn")
    }

    func testDuplicateHookEnvelopeHasSingleEffect() throws {
        try startSessionAndWaitForTail()

        try appendTranscript([userLine(uuid: "u1", text: "task")])
        waitForState(.working)

        try appendHook(event: "permission-request",
                       payload: #"{"session_id":"session","tool_use_id":"tu-1"}"#,
                       eventID: "req-1")
        try appendHook(event: "notification-permission", payload: #"{"session_id":"session"}"#, eventID: "note-1")
        waitForState(.needsInput)
        XCTAssertEqual(store.snapshot(identity)?.blockerIDs, ["permission:tu-1"])

        // Redelivered identical envelopes: no second blocker, no consumed
        // prepared id resurrection.
        try appendHook(event: "permission-request",
                       payload: #"{"session_id":"session","tool_use_id":"tu-1"}"#,
                       eventID: "req-1")
        try appendHook(event: "notification-permission", payload: #"{"session_id":"session"}"#, eventID: "note-1")
        XCTAssertTrue(waitUntil { self.store.snapshot(self.identity)?.blockerIDs == ["permission:tu-1"] })
    }

    // MARK: - Midreview 5: sequential permissions consume deterministically

    func testSequentialPermissionsCorrelateToTheirOwnBlockers() throws {
        try startSessionAndWaitForTail()
        try appendTranscript([userLine(uuid: "u1", text: "task")])
        waitForState(.working)

        try appendHook(event: "permission-request", payload: #"{"session_id":"session","tool_use_id":"tu-1"}"#)
        try appendHook(event: "notification-permission", payload: #"{"session_id":"session"}"#)
        waitForState(.needsInput)
        XCTAssertEqual(store.snapshot(identity)?.blockerIDs, ["permission:tu-1"])

        // Allow tu-1 -> tool_result resolves ONLY that blocker.
        try appendTranscript([userArrayLine(uuid: "u2", blocks: [
            #"{"type":"tool_result","tool_use_id":"tu-1","content":"ok"}"#,
        ])])
        waitForState(.working)

        // The SECOND permission uses its own id — the consumed tu-1 (with
        // its resolve tombstone) is never reused, so this blocker opens.
        try appendHook(event: "permission-request", payload: #"{"session_id":"session","tool_use_id":"tu-2"}"#)
        try appendHook(event: "notification-permission", payload: #"{"session_id":"session"}"#)
        waitForState(.needsInput)
        XCTAssertEqual(store.snapshot(identity)?.blockerIDs, ["permission:tu-2"])
    }

    // MARK: - Midreview 3: source switch claims the new generation at once

    func testSourceSwitchImmediatelyResetsStaleNeedsInput() throws {
        try startSessionAndWaitForTail()

        let askInput = #"{"questions":[{"header":"Q","question":"pick","options":[{"label":"A"}]}]}"#
        try appendTranscript([
            userLine(uuid: "u1", text: "task"),
            assistantToolUseLine(uuid: "a1", toolCallID: "ask-1", name: "AskUserQuestion", input: askInput),
        ])
        waitForState(.needsInput)

        // Registry points the session at a DIFFERENT transcript: the source
        // switch claims a fresh generation IMMEDIATELY — no later mutation
        // is needed to clear the stale needs_input.
        let newTranscriptURL = directory.appendingPathComponent("session-2.jsonl", isDirectory: false)
        try Data().write(to: newTranscriptURL)
        var dict: [String: Any] = [
            "version": 1, "vendor": "claude", "workspace_id": "workspace",
            "session_id": "session", "panel_id": "panel",
            "pid": Int(ProcessInfo.processInfo.processIdentifier),
            "cwd": "/tmp", "created_at": "2026-07-18T00:00:00Z",
            "transcript_path": newTranscriptURL.path,
        ]
        let data = try JSONSerialization.data(withJSONObject: dict)
        let newRecord = try JSONDecoder().decode(AgentSessionRegistryRecord.self, from: data)
        session.update(record: newRecord)
        waitForState(.idle)
        _ = dict
    }

    // MARK: - Midreview 6: session-end survives the journal delete race

    func testSessionEndObservedThroughJournalDeleteRace() throws {
        try startSessionAndWaitForTail()

        // Prove the hook tailer is live first.
        try appendTranscript([userLine(uuid: "u1", text: "task")])
        waitForState(.working)
        try appendHook(event: "notification-permission", payload: #"{"session_id":"session"}"#)
        waitForState(.needsInput)

        // Wrapper shutdown: final session-end append immediately followed by
        // the journal's removal. The tailer drains before tearing down.
        try appendHook(event: "session-end", payload: #"{"session_id":"session"}"#)
        try FileManager.default.removeItem(at: hookJournalURL)
        XCTAssertTrue(waitUntil { self.store.snapshot(self.identity)?.ended == true },
                      "session-end appended just before the journal delete was lost")
    }

    // Round2c point 22: on registry/process removal (the only production
    // caller of `stop()`), the identity must be RETIRED — not just
    // ended-as-idle — so the panel's aggregate vanishes and it can fall
    // back to plain-terminal legacy activity, rather than an idle "ghost"
    // lingering in the aggregate forever.
    func testStopRetiresIdentitySoAggregateFallsBackToPlainTerminal() throws {
        try startSessionAndWaitForTail()
        try appendTranscript([userLine(uuid: "u1", text: "task")])
        waitForState(.working)
        XCTAssertNotNil(store.panelAggregate(workspaceID: "workspace", panelID: "panel"))

        session.stop()

        XCTAssertNil(store.panelAggregate(workspaceID: "workspace", panelID: "panel"),
                     "a retired identity must vanish from the aggregate (plain-terminal fallback)")
        XCTAssertEqual(store.snapshot(identity)?.ended, true)
    }

    // MARK: - D5: backfill never touches live lifecycle

    func testBackfillOfOldCompletedTurnsLeavesLiveStateUntouched() throws {
        // Old history: enough completed turns to page.
        var lines = [String]()
        let totalLines = transcriptBootstrapLineLimit + 20
        for index in 0..<totalLines {
            lines.append(userLine(uuid: "old-\(index)", text: "old line \(index)"))
        }
        try appendTranscript(lines)

        try startSessionAndWaitForTail()

        // Live: an unresolved Ask keeps the session needs_input.
        let askInput = #"{"questions":[{"header":"Q","question":"pick one","options":[{"label":"A"},{"label":"B"}]}]}"#
        try appendTranscript([
            userLine(uuid: "live-1", text: "current task"),
            assistantToolUseLine(uuid: "live-2", toolCallID: "ask-live", name: "AskUserQuestion", input: askInput),
        ])
        waitForState(.needsInput)
        let revisionBefore = store.snapshot(identity)?.revision

        // Page up through history (old completed turns replayed).
        let initial = hub.fetch(workspaceID: "workspace", sessionID: "session", limit: 5000)
        let oldestLoadedSeq = initial.events
            .filter { ($0.text ?? "").hasPrefix("old line") }
            .map(\.seq).min() ?? 0
        XCTAssertTrue(session.backfill(beforeSeq: oldestLoadedSeq, limit: 50))

        // Live lifecycle: same state, same revision — history changed nothing.
        XCTAssertEqual(state(), .needsInput)
        XCTAssertEqual(store.snapshot(identity)?.revision, revisionBefore)
    }
}
