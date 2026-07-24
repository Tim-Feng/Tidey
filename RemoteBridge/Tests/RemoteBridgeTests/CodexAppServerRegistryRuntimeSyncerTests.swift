import XCTest
@testable import RemoteBridge

final class CodexAppServerRegistryRuntimeSyncerTests: XCTestCase {
    func testSyncAttachesOnlyCodexAppServerRecords() {
        let hub = AgentEventHub()
        let runtime = FakeRuntimeSession()
        var attachedRecords = [AgentSessionRegistryRecord]()
        let syncer = CodexAppServerRegistryRuntimeSyncer(eventHub: hub, attachHandler: { record, _, _, _, _, _, _ in
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

    // R13 root-thread fallback: attach hands the registry's authoritative
    // root identity to the runtime — threadID preferred, resumeThreadID as
    // fallback, blanks fail closed.
    func testAttachForwardsRegistryRootThreadIdentity() {
        let hub = AgentEventHub()
        let runtime = FakeRuntimeSession()
        let syncer = CodexAppServerRegistryRuntimeSyncer(eventHub: hub, attachHandler: { _, _, _, _, _, _, _ in
            runtime
        })

        syncer.sync(records: [
            Self.record(sessionID: "app", runtime: "codex_app_server", socketPath: "/tmp/app.sock",
                        threadID: "  thread-root  "),
        ])
        XCTAssertEqual(runtime.registryRootThreadIDs.last, "thread-root",
                       "the record's root thread reaches the runtime, trimmed")

        // Preference order and blank fail-closed are pure selection logic.
        XCTAssertEqual(CodexAppServerRegistryRuntimeSyncer.registryRootThreadID(
            from: AgentSessionRegistryRecord(version: 1, vendor: "codex", workspaceID: "w", sessionID: "s",
                                             panelID: nil, pid: 1, cwd: "/tmp", createdAt: "2026-06-07T00:00:00Z", transcriptPath: nil,
                                             threadID: "thread-a", resumeThreadID: "thread-b")), "thread-a")
        XCTAssertEqual(CodexAppServerRegistryRuntimeSyncer.registryRootThreadID(
            from: AgentSessionRegistryRecord(version: 1, vendor: "codex", workspaceID: "w", sessionID: "s",
                                             panelID: nil, pid: 1, cwd: "/tmp", createdAt: "2026-06-07T00:00:00Z", transcriptPath: nil,
                                             threadID: "   ", resumeThreadID: "thread-b")), "thread-b")
        XCTAssertNil(CodexAppServerRegistryRuntimeSyncer.registryRootThreadID(
            from: AgentSessionRegistryRecord(version: 1, vendor: "codex", workspaceID: "w", sessionID: "s",
                                             panelID: nil, pid: 1, cwd: "/tmp", createdAt: "2026-06-07T00:00:00Z", transcriptPath: nil,
                                             threadID: "   ", resumeThreadID: "\n")))
    }

    // Final review 1: Codex 0.144.1 thread/resume is ADDITIVE (no
    // unsubscribe) — a changed effective root must REPLACE the runtime
    // generation so the old thread's approvals cannot leak into this session.
    func testRegistryRootChangeReplacesRuntimeGeneration() {
        let hub = AgentEventHub()
        var runtimes = [FakeRuntimeSession]()
        let syncer = CodexAppServerRegistryRuntimeSyncer(eventHub: hub, attachHandler: { _, _, _, _, _, _, _ in
            let runtime = FakeRuntimeSession()
            runtimes.append(runtime)
            return runtime
        })

        syncer.sync(records: [
            Self.record(sessionID: "app", runtime: "codex_app_server", socketPath: "/tmp/app.sock",
                        threadID: "thread-A"),
        ])
        syncer.sync(records: [
            Self.record(sessionID: "app", runtime: "codex_app_server", socketPath: "/tmp/app.sock",
                        threadID: "thread-B"),
        ])

        XCTAssertEqual(runtimes.count, 2, "A -> B attaches a SECOND runtime generation")
        XCTAssertTrue(runtimes[0].stopped, "the old generation is retired/stopped")
        XCTAssertFalse(runtimes[1].stopped)
        XCTAssertEqual(runtimes[0].registryRootThreadIDs, ["thread-A"])
        XCTAssertEqual(runtimes[1].registryRootThreadIDs, ["thread-B"],
                       "the new generation only ever sees B")

        // An UNCHANGED root keeps the reuse — no rebuild.
        syncer.sync(records: [
            Self.record(sessionID: "app", runtime: "codex_app_server", socketPath: "/tmp/app.sock",
                        threadID: "thread-B"),
        ])
        XCTAssertEqual(runtimes.count, 2, "same root is reused, not reattached")
        XCTAssertFalse(runtimes[1].stopped)

        // A root that merely disappears (blank/nil) also keeps the reuse:
        // fail closed on registry hiccups.
        syncer.sync(records: [
            Self.record(sessionID: "app", runtime: "codex_app_server", socketPath: "/tmp/app.sock",
                        threadID: nil),
        ])
        XCTAssertEqual(runtimes.count, 2)
        XCTAssertFalse(runtimes[1].stopped)
    }

    // P2: replacement identity keeps the LAST-KNOWN-GOOD effective root —
    // B -> blank -> B never rebuilds (no card flicker/expiry), while
    // A -> blank -> B still must rebuild.
    func testStickyEffectiveRootAvoidsBlankRoundTripReplacement() {
        let hub = AgentEventHub()
        var runtimes = [FakeRuntimeSession]()
        let syncer = CodexAppServerRegistryRuntimeSyncer(eventHub: hub, attachHandler: { _, _, _, _, _, _, _ in
            let runtime = FakeRuntimeSession()
            runtimes.append(runtime)
            return runtime
        })

        // B -> blank -> B: reuse throughout.
        for threadID in ["thread-B", nil, "thread-B"] as [String?] {
            syncer.sync(records: [
                Self.record(sessionID: "app", runtime: "codex_app_server", socketPath: "/tmp/app.sock",
                            threadID: threadID),
            ])
        }
        XCTAssertEqual(runtimes.count, 1, "B -> blank -> B never rebuilds the runtime")
        XCTAssertFalse(runtimes[0].stopped)

        // A -> blank -> B: the sticky root is still A, so B rebuilds.
        for threadID in ["thread-A", nil, "thread-B"] as [String?] {
            syncer.sync(records: [
                Self.record(sessionID: "app-2", runtime: "codex_app_server", socketPath: "/tmp/app-2.sock",
                            threadID: threadID),
            ])
        }
        XCTAssertEqual(runtimes.count, 3, "A -> blank -> B rebuilds exactly once for the A->B change")
        XCTAssertTrue(runtimes[1].stopped, "the A generation is retired")
        XCTAssertFalse(runtimes[2].stopped)
        XCTAssertEqual(runtimes[2].registryRootThreadIDs, ["thread-B"])
    }

    func testSyncStopsStaleAndReplacedRuntimes() {
        let hub = AgentEventHub()
        var runtimes = [FakeRuntimeSession]()
        let syncer = CodexAppServerRegistryRuntimeSyncer(eventHub: hub, attachHandler: { _, _, _, _, _, _, _ in
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
        let syncer = CodexAppServerRegistryRuntimeSyncer(eventHub: hub, attachHandler: { _, _, _, _, _, _, _ in
            defer { runtimeIndex += 1 }
            return runtimeIndex == 0 ? firstRuntime : secondRuntime
        })

        syncer.sync(records: [
            Self.record(sessionID: "first", runtime: "codex_app_server", socketPath: "/tmp/first.sock"),
            Self.record(sessionID: "second", runtime: "codex_app_server", socketPath: "/tmp/second.sock"),
        ])

        guard case .alreadyResolved(let event) = try syncer.submitApproval(promptID: "prompt-2",
                                                                           targetIndex: 1,
                                                                           clientRequestID: nil,
                                                                           lifecycleToken: nil) else {
            return XCTFail("expected alreadyResolved")
        }

        XCTAssertEqual(event.eventID, resolved.eventID)
        XCTAssertEqual(secondRuntime.submitAttempts, ["prompt-2"])
    }

    func testContextualSubmitFailsWhenMatchingSessionHasNoPromptAndNoResolvedRecord() throws {
        let hub = AgentEventHub()
        let firstRuntime = FakeRuntimeSession()
        let secondRuntime = FakeRuntimeSession()
        secondRuntime.resolvedEventsByPromptID["prompt-other"] = Self.event(sessionID: "second", promptID: "prompt-other")
        var runtimeIndex = 0
        let syncer = CodexAppServerRegistryRuntimeSyncer(eventHub: hub,
                                                        timestampProvider: { "2026-06-07T00:00:00.000Z" },
                                                        attachHandler: { _, _, _, _, _, _, _ in
            defer { runtimeIndex += 1 }
            return runtimeIndex == 0 ? firstRuntime : secondRuntime
        })

        syncer.sync(records: [
            Self.record(sessionID: "first", runtime: "codex_app_server", socketPath: "/tmp/first.sock"),
            Self.record(sessionID: "second", runtime: "codex_app_server", socketPath: "/tmp/second.sock"),
        ])

        XCTAssertThrowsError(try syncer.submitApproval(promptID: "prompt-other",
                                                       targetIndex: 0,
                                                       clientRequestID: nil,
                                                       lifecycleToken: nil,
                                                       workspaceID: "workspace-1",
                                                       panelID: "panel-1",
                                                       sessionID: "first")) { error in
            guard case BridgeInternalError.notFound = error else {
                return XCTFail("expected notFound, got \(error)")
            }
        }
        XCTAssertEqual(firstRuntime.submitAttempts, ["prompt-other"])
        XCTAssertTrue(secondRuntime.submitAttempts.isEmpty)
    }

    func testContextualSubmitFailsClosedWhenSessionIsUnknown() throws {
        let hub = AgentEventHub()
        let runtime = FakeRuntimeSession()
        runtime.resolvedEventsByPromptID["prompt-other"] = Self.event(sessionID: "second", promptID: "prompt-other")
        let syncer = CodexAppServerRegistryRuntimeSyncer(eventHub: hub,
                                                        timestampProvider: { "2026-06-07T00:00:00.000Z" },
                                                        attachHandler: { _, _, _, _, _, _, _ in
            runtime
        })

        syncer.sync(records: [
            Self.record(sessionID: "second", runtime: "codex_app_server", socketPath: "/tmp/second.sock"),
        ])

        XCTAssertThrowsError(try syncer.submitApproval(promptID: "prompt-other",
                                                       targetIndex: 0,
                                                       clientRequestID: nil,
                                                       lifecycleToken: nil,
                                                       workspaceID: "workspace-1",
                                                       panelID: "panel-missing",
                                                       sessionID: "missing")) { error in
            guard case BridgeInternalError.notFound = error else {
                return XCTFail("expected notFound, got \(error)")
            }
        }
        XCTAssertTrue(runtime.submitAttempts.isEmpty)
    }

    func testContextualSubmitDoesNotRouteToRuntimeWithMismatchedPanel() throws {
        let hub = AgentEventHub()
        let runtime = FakeRuntimeSession()
        runtime.resolvedEventsByPromptID["prompt-1"] = Self.event(sessionID: "first", promptID: "prompt-1")
        let syncer = CodexAppServerRegistryRuntimeSyncer(eventHub: hub, attachHandler: { _, _, _, _, _, _, _ in
            runtime
        })

        syncer.sync(records: [
            Self.record(sessionID: "first", runtime: "codex_app_server", socketPath: "/tmp/first.sock", panelID: "panel-1"),
        ])

        XCTAssertThrowsError(try syncer.submitApproval(promptID: "prompt-1",
                                                       targetIndex: 0,
                                                       clientRequestID: nil,
                                                       lifecycleToken: nil,
                                                       workspaceID: "workspace-1",
                                                       panelID: "panel-2",
                                                       sessionID: "first")) { error in
            guard case BridgeInternalError.notFound = error else {
                return XCTFail("expected notFound, got \(error)")
            }
        }
        XCTAssertTrue(runtime.submitAttempts.isEmpty)
    }

    func testContextualSubmitReusesExistingResolvedEventWhenPromptWasAlreadyResolved() throws {
        let hub = AgentEventHub()
        let runtime = FakeRuntimeSession()
        let resolved = Self.event(sessionID: "first", promptID: "prompt-done", lifecycleToken: "token-done")
        hub.publish(resolved)
        let syncer = CodexAppServerRegistryRuntimeSyncer(eventHub: hub, attachHandler: { _, _, _, _, _, _, _ in
            runtime
        })

        syncer.sync(records: [
            Self.record(sessionID: "first", runtime: "codex_app_server", socketPath: "/tmp/first.sock"),
        ])

        guard case .alreadyResolved(let event) = try syncer.submitApproval(promptID: "prompt-done",
                                                                           targetIndex: 0,
                                                                           clientRequestID: nil,
                                                                           lifecycleToken: "token-done",
                                                                           workspaceID: "workspace-1",
                                                                           panelID: "panel-1",
                                                                           sessionID: "first") else {
            return XCTFail("expected alreadyResolved")
        }

        XCTAssertEqual(event.eventID, resolved.eventID)
        XCTAssertEqual(runtime.submitAttempts, ["prompt-done"])
    }

    func testContextualSubmitDoesNotAnswerOldTerminalWhenNewerAttemptIsActive() throws {
        let hub = AgentEventHub()
        let runtime = FakeRuntimeSession()
        // Old lifecycle attempt resolved at seq 5; the same request was then
        // re-delivered (prompt event at seq 8) and is active again.
        hub.publish(Self.event(sessionID: "first", promptID: "prompt-1", seq: 5))
        hub.publish(Self.interactivePromptEvent(sessionID: "first", promptID: "prompt-1", seq: 8, includePayload: true))
        let syncer = CodexAppServerRegistryRuntimeSyncer(eventHub: hub, attachHandler: { _, _, _, _, _, _, _ in
            runtime
        })
        syncer.sync(records: [
            Self.record(sessionID: "first", runtime: "codex_app_server", socketPath: "/tmp/first.sock"),
        ])

        // The stale terminal must not answer for the newer active attempt.
        XCTAssertThrowsError(try syncer.submitApproval(promptID: "prompt-1",
                                                       targetIndex: 0,
                                                       clientRequestID: nil,
                                                       lifecycleToken: nil,
                                                       workspaceID: "workspace-1",
                                                       panelID: "panel-1",
                                                       sessionID: "first")) { error in
            guard case BridgeInternalError.notFound = error else {
                return XCTFail("expected notFound, got \(error)")
            }
        }
    }

    func testRetiredSessionSubmitResultIsDiscardedAndReconciledAgainstNewGeneration() throws {
        let hub = AgentEventHub()
        let oldRuntime = FakeRuntimeSession()
        let newRuntime = FakeRuntimeSession()
        // The retired session would answer with a stale expired terminal.
        oldRuntime.resolvedEventsByPromptID["prompt-1"] = Self.event(sessionID: "app", promptID: "prompt-1")
        oldRuntime.submitEntered = DispatchSemaphore(value: 0)
        oldRuntime.submitBarrier = DispatchSemaphore(value: 0)
        // The replayed prompt is pending on the new generation.
        newRuntime.pendingConfirmationPromptIDs.insert("prompt-1")
        var runtimeIndex = 0
        let syncer = CodexAppServerRegistryRuntimeSyncer(eventHub: hub, attachHandler: { _, _, _, _, _, _, _ in
            defer { runtimeIndex += 1 }
            return runtimeIndex == 0 ? oldRuntime : newRuntime
        })
        syncer.sync(records: [
            Self.record(sessionID: "app", runtime: "codex_app_server", socketPath: "/tmp/app-1.sock"),
        ])

        var outcome: CodexAppServerApprovalSubmitOutcome?
        var submitError: Error?
        let submitDone = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                outcome = try syncer.submitApproval(promptID: "prompt-1",
                                                    targetIndex: 0,
                                                    clientRequestID: "client-1",
                                                    lifecycleToken: nil,
                                                    workspaceID: "workspace-1",
                                                    panelID: "panel-1",
                                                    sessionID: "app")
            } catch {
                submitError = error
            }
            submitDone.signal()
        }
        // The submit is inside the old session; replace the generation while
        // it is blocked, then release the old result.
        XCTAssertEqual(oldRuntime.submitEntered?.wait(timeout: .now() + 2.0), .success)
        syncer.sync(records: [
            Self.record(sessionID: "app", runtime: "codex_app_server", socketPath: "/tmp/app-2.sock"),
        ])
        oldRuntime.submitBarrier?.signal()
        XCTAssertEqual(submitDone.wait(timeout: .now() + 2.0), .success)

        // The retired session's stale terminal must not answer: the submit
        // reconciles against the new generation's live state.
        XCTAssertNil(submitError)
        guard case .pendingConfirmation? = outcome else {
            return XCTFail("expected reconciliation to the new generation, got \(String(describing: outcome)) \(String(describing: submitError))")
        }
        XCTAssertEqual(newRuntime.submitAttempts, ["prompt-1"])
    }

    func testAttachHandlerSynchronousThreadCallbackIsForwarded() {
        let hub = AgentEventHub()
        var forwardedThreadIDs = [String]()
        let syncer = CodexAppServerRegistryRuntimeSyncer(eventHub: hub, attachHandler: { _, _, _, _, _, _, onActiveThreadID in
            // A runtime that reports its thread synchronously DURING attach
            // (before the syncer stored the entry) is legitimate.
            onActiveThreadID("thread-early")
            return FakeRuntimeSession()
        })
        syncer.activeThreadHandler = { _, threadID in
            forwardedThreadIDs.append(threadID)
        }

        syncer.sync(records: [
            Self.record(sessionID: "app", runtime: "codex_app_server", socketPath: "/tmp/app-1.sock"),
        ])

        XCTAssertEqual(forwardedThreadIDs, ["thread-early"],
                       "the pre-install callback window must not drop the first legitimate thread binding")
    }

    func testRetiredSessionSubmitErrorTriggersReconcileAgainstNewGeneration() throws {
        let hub = AgentEventHub()
        let oldRuntime = FakeRuntimeSession()
        let newRuntime = FakeRuntimeSession()
        // The retired session dies mid-submit and throws (e.g. closed).
        oldRuntime.submitEntered = DispatchSemaphore(value: 0)
        oldRuntime.submitBarrier = DispatchSemaphore(value: 0)
        oldRuntime.submitError = CodexAppServerConnectionError.closed
        // The new generation holds the (re-delivered) prompt.
        newRuntime.pendingConfirmationPromptIDs.insert("prompt-1")
        var runtimeIndex = 0
        let syncer = CodexAppServerRegistryRuntimeSyncer(eventHub: hub, attachHandler: { _, _, _, _, _, _, _ in
            defer { runtimeIndex += 1 }
            return runtimeIndex == 0 ? oldRuntime : newRuntime
        })
        syncer.sync(records: [
            Self.record(sessionID: "app", runtime: "codex_app_server", socketPath: "/tmp/app-1.sock"),
        ])

        var outcome: CodexAppServerApprovalSubmitOutcome?
        var submitError: Error?
        let submitDone = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                outcome = try syncer.submitApproval(promptID: "prompt-1",
                                                    targetIndex: 0,
                                                    clientRequestID: "client-1",
                                                    lifecycleToken: nil,
                                                    workspaceID: "workspace-1",
                                                    panelID: "panel-1",
                                                    sessionID: "app")
            } catch {
                submitError = error
            }
            submitDone.signal()
        }
        XCTAssertEqual(oldRuntime.submitEntered?.wait(timeout: .now() + 2.0), .success)
        syncer.sync(records: [
            Self.record(sessionID: "app", runtime: "codex_app_server", socketPath: "/tmp/app-2.sock"),
        ])
        oldRuntime.submitBarrier?.signal()
        XCTAssertEqual(submitDone.wait(timeout: .now() + 2.0), .success)

        // The stale generation's error must not surface: the submit is
        // reconciled against the current generation, consistent with the
        // stale-success path.
        XCTAssertNil(submitError, "stale closed error must not be returned, got \(String(describing: submitError))")
        guard case .pendingConfirmation? = outcome else {
            return XCTFail("expected pendingConfirmation from the new generation, got \(String(describing: outcome))")
        }
        XCTAssertEqual(newRuntime.submitAttempts, ["prompt-1"])
    }

    private static func approvalEnvelope(sessionID: String,
                                         requestID: String = "approval-1",
                                         seq: Int = 1) -> CodexAppServerInteractivePromptEnvelope {
        let request = CodexAppServerApprovalRequest(
            method: "item/commandExecution/requestApproval",
            requestID: .string(requestID),
            params: [
                "threadId": .string("thread-1"),
                "turnId": .string("turn-1"),
                "itemId": .string("item-1"),
                "startedAtMs": .number(1_786_000_000_000),
                "command": .string("ls"),
            ])!
        let prompt = request.makePrompt(epoch: "e")
        let baseEvent = Self.interactivePromptEvent(sessionID: sessionID,
                                                    promptID: prompt.promptID,
                                                    seq: seq,
                                                    includePayload: true)
        // Production Codex prompt events always carry their delivery's
        // lifecycle capability.
        var metadata = baseEvent.metadata ?? [:]
        metadata["lifecycle_token"] = baseEvent.eventID
        return CodexAppServerInteractivePromptEnvelope(request: request,
                                                       prompt: prompt,
                                                       event: baseEvent.withMetadataForTesting(metadata))
    }

    func testStaleSessionStopSynchronousExpiredCallbackReachesHub() throws {
        // sync([]) removes a session: the stop()-driven expired terminal is a
        // legitimate cleanup of the retiring generation and must flow to the
        // hub — otherwise the actionable prompt is stuck there forever.
        let hub = AgentEventHub()
        let runtime = FakeRuntimeSession()
        var promptHandler: CodexAppServerConnection.InteractivePromptHandler?
        var resolvedHandler: CodexAppServerConnection.InteractivePromptResolvedHandler?
        let syncer = CodexAppServerRegistryRuntimeSyncer(eventHub: hub, attachHandler: { _, _, _, _, onInteractivePrompt, onInteractivePromptResolved, _ in
            promptHandler = onInteractivePrompt
            resolvedHandler = onInteractivePromptResolved
            return runtime
        })
        syncer.sync(records: [
            Self.record(sessionID: "app", runtime: "codex_app_server", socketPath: "/tmp/app.sock"),
        ])
        let envelope = Self.approvalEnvelope(sessionID: "app")
        try XCTUnwrap(promptHandler)(envelope)
        XCTAssertNotNil(hub.activeInteractivePrompt(workspaceID: "workspace-1",
                                                    sessionID: "app",
                                                    promptID: envelope.prompt.promptID))

        // The runtime terminalizes its pending approvals SYNCHRONOUSLY inside
        // stop(), exactly like the real close() path.
        runtime.onStop = {
            resolvedHandler?(Self.event(sessionID: "app",
                                        promptID: envelope.prompt.promptID,
                                        seq: 2,
                                        lifecycleToken: envelope.event.eventID))
        }
        syncer.sync(records: [])

        let events = hub.fetch(workspaceID: "workspace-1", sessionID: "app", limit: 10).events
        XCTAssertEqual(events.map(\.type), [.interactivePrompt, .interactivePromptResolved],
                       "the retiring generation's expired terminal must reach the hub")
        XCTAssertNil(hub.activeInteractivePrompt(workspaceID: "workspace-1",
                                                 sessionID: "app",
                                                 promptID: envelope.prompt.promptID))
    }

    func testAttachFailureDiscardsStagedCallbackSideEffects() throws {
        // attach is a transaction: callbacks fired synchronously during a
        // failing attach must leave NO trace in the hub, sidebar, or thread
        // handler.
        let hub = AgentEventHub()
        let sidebarQueue = DispatchQueue(label: "test.sidebar.attach-failure")
        let sidebarLock = NSLock()
        var sidebarMessages = [String]()
        var forwardedThreadIDs = [String]()
        let envelope = Self.approvalEnvelope(sessionID: "app")
        let syncer = CodexAppServerRegistryRuntimeSyncer(eventHub: hub,
                                                        sidebarMessageSender: { message in
                                                            sidebarLock.lock()
                                                            sidebarMessages.append(message)
                                                            sidebarLock.unlock()
                                                        },
                                                        sidebarQueue: sidebarQueue,
                                                        attachHandler: { _, _, _, onAgentEvent, onInteractivePrompt, onInteractivePromptResolved, onActiveThreadID in
            onAgentEvent(Self.appServerEvent(eventID: "turn-started",
                                             seq: 1,
                                             sessionID: "app",
                                             type: .thinking,
                                             text: "Codex turn started",
                                             payloadKind: "turn_started"))
            onInteractivePrompt(envelope)
            onInteractivePromptResolved(Self.event(sessionID: "app", promptID: envelope.prompt.promptID, seq: 2))
            onActiveThreadID("thread-staged")
            throw BridgeInternalError.invalidRequest("attach failed after synchronous callbacks")
        })
        syncer.activeThreadHandler = { _, threadID in
            forwardedThreadIDs.append(threadID)
        }

        syncer.sync(records: [
            Self.record(sessionID: "app", runtime: "codex_app_server", socketPath: "/tmp/app.sock"),
        ])
        sidebarQueue.sync {}

        XCTAssertTrue(hub.fetch(workspaceID: "workspace-1", sessionID: "app", limit: 10).events.isEmpty,
                      "a failed attach must not leak hub events")
        XCTAssertTrue(forwardedThreadIDs.isEmpty, "a failed attach must not leak thread bindings")
        sidebarLock.lock()
        let messages = sidebarMessages
        sidebarLock.unlock()
        XCTAssertTrue(messages.isEmpty, "a failed attach must not leak sidebar messages, got \(messages)")
    }

    func testAttachSuccessCommitsStagedCallbacksInOrder() throws {
        let hub = AgentEventHub()
        let sidebarQueue = DispatchQueue(label: "test.sidebar.attach-success")
        let sidebarLock = NSLock()
        var sidebarMessages = [String]()
        var forwardedThreadIDs = [String]()
        let envelope = Self.approvalEnvelope(sessionID: "app")
        let syncer = CodexAppServerRegistryRuntimeSyncer(eventHub: hub,
                                                        sidebarMessageSender: { message in
                                                            sidebarLock.lock()
                                                            sidebarMessages.append(message)
                                                            sidebarLock.unlock()
                                                        },
                                                        sidebarQueue: sidebarQueue,
                                                        attachHandler: { _, _, _, onAgentEvent, onInteractivePrompt, onInteractivePromptResolved, onActiveThreadID in
            onAgentEvent(Self.appServerEvent(eventID: "turn-started",
                                             seq: 1,
                                             sessionID: "app",
                                             type: .thinking,
                                             text: "Codex turn started",
                                             payloadKind: "turn_started"))
            onInteractivePrompt(envelope)
            onInteractivePromptResolved(Self.event(sessionID: "app", promptID: envelope.prompt.promptID, seq: 2))
            onActiveThreadID("thread-staged")
            return FakeRuntimeSession()
        })
        syncer.activeThreadHandler = { _, threadID in
            forwardedThreadIDs.append(threadID)
        }

        syncer.sync(records: [
            Self.record(sessionID: "app", runtime: "codex_app_server", socketPath: "/tmp/app.sock"),
        ])
        sidebarQueue.sync {}

        let events = hub.fetch(workspaceID: "workspace-1", sessionID: "app", limit: 10).events
        XCTAssertEqual(events.map(\.type), [.interactivePrompt, .interactivePromptResolved],
                       "a successful attach must commit staged callbacks in delivery order")
        XCTAssertEqual(forwardedThreadIDs, ["thread-staged"])
        sidebarLock.lock()
        let messages = sidebarMessages
        sidebarLock.unlock()
        XCTAssertTrue(messages.contains("report_shell_state running --workspace_id=workspace-1"),
                      "committed agent events must reach the sidebar, got \(messages)")
    }

    func testCallbackPassingGenerationCheckCannotPublishAfterReplacementCompletes() throws {
        // TOCTOU: the callback passes its initial generation check, then the
        // replacement COMPLETES (via the recheck hook barrier), then the
        // callback resumes. The stale publish must be dropped.
        let hub = AgentEventHub()
        var promptHandlers = [CodexAppServerConnection.InteractivePromptHandler]()
        var threadHandlers = [CodexAppServerHeadlessRuntime.ThreadIDHandler]()
        let syncer = CodexAppServerRegistryRuntimeSyncer(eventHub: hub, attachHandler: { _, _, _, _, onInteractivePrompt, _, onActiveThreadID in
            promptHandlers.append(onInteractivePrompt)
            threadHandlers.append(onActiveThreadID)
            return FakeRuntimeSession()
        })
        var forwardedThreadIDs = [String]()
        syncer.activeThreadHandler = { _, threadID in
            forwardedThreadIDs.append(threadID)
        }
        syncer.sync(records: [
            Self.record(sessionID: "app", runtime: "codex_app_server", socketPath: "/tmp/app-1.sock"),
        ])
        XCTAssertEqual(promptHandlers.count, 1)

        var replaced = false
        syncer.generationRecheckHook = { [weak syncer] in
            guard replaced == false else { return }
            replaced = true
            syncer?.generationRecheckHook = nil
            syncer?.sync(records: [
                Self.record(sessionID: "app", runtime: "codex_app_server", socketPath: "/tmp/app-2.sock"),
            ])
        }
        promptHandlers[0](Self.approvalEnvelope(sessionID: "app"))
        XCTAssertTrue(hub.fetch(workspaceID: "workspace-1", sessionID: "app", limit: 10).events.isEmpty,
                      "a callback that lost the generation race must not publish")

        replaced = false
        syncer.generationRecheckHook = { [weak syncer] in
            guard replaced == false else { return }
            replaced = true
            syncer?.generationRecheckHook = nil
            syncer?.sync(records: [
                Self.record(sessionID: "app", runtime: "codex_app_server", socketPath: "/tmp/app-3.sock"),
            ])
        }
        threadHandlers[1]("thread-stale")
        XCTAssertTrue(forwardedThreadIDs.isEmpty,
                      "a thread binding that lost the generation race must not be forwarded, got \(forwardedThreadIDs)")
    }

    func testBlockedSidebarQueueDropsRetiredGenerationWork() throws {
        // Sidebar work is queued with its generation and re-validated when it
        // executes: work enqueued before a replacement must be dropped.
        let hub = AgentEventHub()
        let sidebarQueue = DispatchQueue(label: "test.sidebar.retired-drop")
        let sidebarLock = NSLock()
        var sidebarMessages = [String]()
        var agentHandlers = [CodexAppServerHeadlessRuntime.AgentEventHandler]()
        var promptHandlers = [CodexAppServerConnection.InteractivePromptHandler]()
        var resolvedHandlers = [CodexAppServerConnection.InteractivePromptResolvedHandler]()
        let syncer = CodexAppServerRegistryRuntimeSyncer(eventHub: hub,
                                                        sidebarMessageSender: { message in
                                                            sidebarLock.lock()
                                                            sidebarMessages.append(message)
                                                            sidebarLock.unlock()
                                                        },
                                                        sidebarQueue: sidebarQueue,
                                                        attachHandler: { _, _, _, onAgentEvent, onInteractivePrompt, onInteractivePromptResolved, _ in
            agentHandlers.append(onAgentEvent)
            promptHandlers.append(onInteractivePrompt)
            resolvedHandlers.append(onInteractivePromptResolved)
            return FakeRuntimeSession()
        })
        syncer.sync(records: [
            Self.record(sessionID: "app", runtime: "codex_app_server", socketPath: "/tmp/app-1.sock"),
        ])

        // Block the sidebar queue, then enqueue old-generation work behind
        // the blocker.
        let release = DispatchSemaphore(value: 0)
        sidebarQueue.async { release.wait() }
        let envelope = Self.approvalEnvelope(sessionID: "app")
        agentHandlers[0](Self.appServerEvent(eventID: "turn-started",
                                             seq: 1,
                                             sessionID: "app",
                                             type: .thinking,
                                             text: "Codex turn started",
                                             payloadKind: "turn_started"))
        promptHandlers[0](envelope)
        resolvedHandlers[0](Self.event(sessionID: "app", promptID: envelope.prompt.promptID, seq: 2))

        // Replacement completes while the old work is still queued.
        syncer.sync(records: [
            Self.record(sessionID: "app", runtime: "codex_app_server", socketPath: "/tmp/app-2.sock"),
        ])
        release.signal()
        sidebarQueue.sync {}

        sidebarLock.lock()
        let messages = sidebarMessages
        sidebarLock.unlock()
        // Round 10 exactly-once contract: the prompt's sidebar work was
        // dropped with its retired generation, so NOTHING was notified — a
        // terminal with no currently-notified delivery has zero side
        // effects. (The stop()-driven cleanup case where the prompt WAS
        // notified first is covered by
        // testStopDrivenResolvedCleanupReachesSidebarAfterStaleRemoval.)
        XCTAssertTrue(messages.isEmpty,
                      "no notified delivery existed: the retired generation's queued work is all dropped, got \(messages)")
    }

    func testRetiredGenerationAgentEventCallbackIsIgnored() throws {
        let hub = AgentEventHub()
        let sidebarQueue = DispatchQueue(label: "test.sidebar.retired-agent")
        let sidebarLock = NSLock()
        var sidebarMessages = [String]()
        var agentHandlers = [CodexAppServerHeadlessRuntime.AgentEventHandler]()
        let syncer = CodexAppServerRegistryRuntimeSyncer(eventHub: hub,
                                                        sidebarMessageSender: { message in
                                                            sidebarLock.lock()
                                                            sidebarMessages.append(message)
                                                            sidebarLock.unlock()
                                                        },
                                                        sidebarQueue: sidebarQueue,
                                                        attachHandler: { _, _, _, onAgentEvent, _, _, _ in
            agentHandlers.append(onAgentEvent)
            return FakeRuntimeSession()
        })
        syncer.sync(records: [
            Self.record(sessionID: "app", runtime: "codex_app_server", socketPath: "/tmp/app-1.sock"),
        ])
        syncer.sync(records: [
            Self.record(sessionID: "app", runtime: "codex_app_server", socketPath: "/tmp/app-2.sock"),
        ])
        XCTAssertEqual(agentHandlers.count, 2)

        agentHandlers[0](Self.appServerEvent(eventID: "turn-started-stale",
                                             seq: 1,
                                             sessionID: "app",
                                             type: .thinking,
                                             text: "Codex turn started",
                                             payloadKind: "turn_started"))
        sidebarQueue.sync {}
        sidebarLock.lock()
        let staleMessages = sidebarMessages
        sidebarLock.unlock()
        XCTAssertTrue(staleMessages.isEmpty, "retired generation agent events must be ignored, got \(staleMessages)")

        agentHandlers[1](Self.appServerEvent(eventID: "turn-started-live",
                                             seq: 2,
                                             sessionID: "app",
                                             type: .thinking,
                                             text: "Codex turn started",
                                             payloadKind: "turn_started"))
        sidebarQueue.sync {}
        sidebarLock.lock()
        let liveMessages = sidebarMessages
        sidebarLock.unlock()
        XCTAssertEqual(liveMessages, ["report_shell_state running --workspace_id=workspace-1"])
    }

    func testStaleGenerationNotFoundReconcilesAgainstNewGeneration() throws {
        let hub = AgentEventHub()
        let oldRuntime = FakeRuntimeSession()
        let newRuntime = FakeRuntimeSession()
        // The retired session answers notFound (its store was retired).
        oldRuntime.submitEntered = DispatchSemaphore(value: 0)
        oldRuntime.submitBarrier = DispatchSemaphore(value: 0)
        newRuntime.pendingConfirmationPromptIDs.insert("prompt-1")
        var runtimeIndex = 0
        let syncer = CodexAppServerRegistryRuntimeSyncer(eventHub: hub, attachHandler: { _, _, _, _, _, _, _ in
            defer { runtimeIndex += 1 }
            return runtimeIndex == 0 ? oldRuntime : newRuntime
        })
        syncer.sync(records: [
            Self.record(sessionID: "app", runtime: "codex_app_server", socketPath: "/tmp/app-1.sock"),
        ])

        var outcome: CodexAppServerApprovalSubmitOutcome?
        var submitError: Error?
        let submitDone = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                outcome = try syncer.submitApproval(promptID: "prompt-1",
                                                    targetIndex: 0,
                                                    clientRequestID: "client-1",
                                                    lifecycleToken: nil,
                                                    workspaceID: "workspace-1",
                                                    panelID: "panel-1",
                                                    sessionID: "app")
            } catch {
                submitError = error
            }
            submitDone.signal()
        }
        XCTAssertEqual(oldRuntime.submitEntered?.wait(timeout: .now() + 2.0), .success)
        syncer.sync(records: [
            Self.record(sessionID: "app", runtime: "codex_app_server", socketPath: "/tmp/app-2.sock"),
        ])
        oldRuntime.submitBarrier?.signal()
        XCTAssertEqual(submitDone.wait(timeout: .now() + 2.0), .success)

        // notFound from a retired generation is stale evidence, exactly like
        // a stale terminal or a stale hard error: retry the new generation.
        XCTAssertNil(submitError, "stale notFound must not surface, got \(String(describing: submitError))")
        guard case .pendingConfirmation? = outcome else {
            return XCTFail("expected pendingConfirmation from the new generation, got \(String(describing: outcome))")
        }
        XCTAssertEqual(newRuntime.submitAttempts, ["prompt-1"])
    }

    func testSubmitDuringReplacementEntryGapWaitsForNewGeneration() throws {
        // Window: replacement removed the old entry but the new attach has
        // not committed yet. A stale notFound arriving in that gap must not
        // be answered as "no runtime" — the submit reconciles against the
        // new generation once the transition commits.
        let hub = AgentEventHub()
        let oldRuntime = FakeRuntimeSession()
        let newRuntime = FakeRuntimeSession()
        oldRuntime.submitEntered = DispatchSemaphore(value: 0)
        oldRuntime.submitBarrier = DispatchSemaphore(value: 0)
        // Old runtime answers notFound (its store was retired mid-transition).
        newRuntime.pendingConfirmationPromptIDs.insert("prompt-1")
        let stopEntered = DispatchSemaphore(value: 0)
        let stopRelease = DispatchSemaphore(value: 0)
        oldRuntime.onStop = {
            stopEntered.signal()
            _ = stopRelease.wait(timeout: .now() + 5.0)
        }
        var runtimeIndex = 0
        let syncer = CodexAppServerRegistryRuntimeSyncer(eventHub: hub, attachHandler: { _, _, _, _, _, _, _ in
            defer { runtimeIndex += 1 }
            return runtimeIndex == 0 ? oldRuntime : newRuntime
        })
        syncer.sync(records: [
            Self.record(sessionID: "app", runtime: "codex_app_server", socketPath: "/tmp/app-1.sock"),
        ])

        var outcome: CodexAppServerApprovalSubmitOutcome?
        var submitError: Error?
        let submitDone = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                outcome = try syncer.submitApproval(promptID: "prompt-1",
                                                    targetIndex: 0,
                                                    clientRequestID: "client-1",
                                                    lifecycleToken: nil,
                                                    workspaceID: "workspace-1",
                                                    panelID: "panel-1",
                                                    sessionID: "app")
            } catch {
                submitError = error
            }
            submitDone.signal()
        }
        XCTAssertEqual(oldRuntime.submitEntered?.wait(timeout: .now() + 2.0), .success)

        // Replacement forms the entry gap: old entry removed, sync blocked
        // inside old stop(), new attach NOT yet committed.
        let syncDone = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            syncer.sync(records: [
                Self.record(sessionID: "app", runtime: "codex_app_server", socketPath: "/tmp/app-2.sock"),
            ])
            syncDone.signal()
        }
        XCTAssertEqual(stopEntered.wait(timeout: .now() + 2.0), .success, "the entry gap must have formed")

        // The stale notFound lands inside the gap; the submit must ARRIVE at
        // the transition-wait point (latch) while the gap is still open.
        let transitionWaitEntered = DispatchSemaphore(value: 0)
        syncer.transitionWaitHook = { _ in transitionWaitEntered.signal() }
        oldRuntime.submitBarrier?.signal()
        XCTAssertEqual(transitionWaitEntered.wait(timeout: .now() + 2.0), .success,
                       "the submit must wait for the in-progress transition instead of answering from the gap")

        // Only now may the replacement commit.
        stopRelease.signal()
        XCTAssertEqual(syncDone.wait(timeout: .now() + 5.0), .success)
        XCTAssertEqual(submitDone.wait(timeout: .now() + 5.0), .success)

        XCTAssertNil(submitError, "the transition gap must not surface as notFound, got \(String(describing: submitError))")
        guard case .pendingConfirmation? = outcome else {
            return XCTFail("expected pendingConfirmation from the new generation, got \(String(describing: outcome))")
        }
        XCTAssertEqual(newRuntime.submitAttempts, ["prompt-1"])
    }

    func testStaleSuccessDuringReplacementEntryGapReconcilesAfterCommit() throws {
        // Common path: the stale evidence is a terminal SUCCESS instead of
        // notFound; the same transition-await applies.
        let hub = AgentEventHub()
        let oldRuntime = FakeRuntimeSession()
        let newRuntime = FakeRuntimeSession()
        oldRuntime.submitEntered = DispatchSemaphore(value: 0)
        oldRuntime.submitBarrier = DispatchSemaphore(value: 0)
        oldRuntime.resolvedEventsByPromptID["prompt-1"] = Self.event(sessionID: "app", promptID: "prompt-1")
        newRuntime.pendingConfirmationPromptIDs.insert("prompt-1")
        let stopEntered = DispatchSemaphore(value: 0)
        let stopRelease = DispatchSemaphore(value: 0)
        oldRuntime.onStop = {
            stopEntered.signal()
            _ = stopRelease.wait(timeout: .now() + 5.0)
        }
        var runtimeIndex = 0
        let syncer = CodexAppServerRegistryRuntimeSyncer(eventHub: hub, attachHandler: { _, _, _, _, _, _, _ in
            defer { runtimeIndex += 1 }
            return runtimeIndex == 0 ? oldRuntime : newRuntime
        })
        syncer.sync(records: [
            Self.record(sessionID: "app", runtime: "codex_app_server", socketPath: "/tmp/app-1.sock"),
        ])

        var outcome: CodexAppServerApprovalSubmitOutcome?
        var submitError: Error?
        let submitDone = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                outcome = try syncer.submitApproval(promptID: "prompt-1",
                                                    targetIndex: 0,
                                                    clientRequestID: "client-1",
                                                    lifecycleToken: nil,
                                                    workspaceID: "workspace-1",
                                                    panelID: "panel-1",
                                                    sessionID: "app")
            } catch {
                submitError = error
            }
            submitDone.signal()
        }
        XCTAssertEqual(oldRuntime.submitEntered?.wait(timeout: .now() + 2.0), .success)
        let syncDone = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            syncer.sync(records: [
                Self.record(sessionID: "app", runtime: "codex_app_server", socketPath: "/tmp/app-2.sock"),
            ])
            syncDone.signal()
        }
        XCTAssertEqual(stopEntered.wait(timeout: .now() + 2.0), .success)
        let transitionWaitEntered = DispatchSemaphore(value: 0)
        syncer.transitionWaitHook = { _ in transitionWaitEntered.signal() }
        oldRuntime.submitBarrier?.signal()
        XCTAssertEqual(transitionWaitEntered.wait(timeout: .now() + 2.0), .success,
                       "the stale-success reconcile must also wait for the in-progress transition")
        stopRelease.signal()
        XCTAssertEqual(syncDone.wait(timeout: .now() + 5.0), .success)
        XCTAssertEqual(submitDone.wait(timeout: .now() + 5.0), .success)

        XCTAssertNil(submitError)
        guard case .pendingConfirmation? = outcome else {
            return XCTFail("stale terminal from the gap must not answer, got \(String(describing: outcome))")
        }
        XCTAssertEqual(newRuntime.submitAttempts, ["prompt-1"])
    }

    func testStopDrivenResolvedCleanupReachesSidebarAfterStaleRemoval() throws {
        // The prompt notified the sidebar; the session then disappears and
        // stop() terminalizes the prompt synchronously. The sidebar cleanup
        // (running-state restore) must still be delivered — the retiring
        // generation's terminal work has a completable ordering.
        let hub = AgentEventHub()
        let sidebarQueue = DispatchQueue(label: "test.sidebar.retiring-cleanup")
        let sidebarLock = NSLock()
        var sidebarMessages = [String]()
        let runtime = FakeRuntimeSession()
        var promptHandler: CodexAppServerConnection.InteractivePromptHandler?
        var resolvedHandler: CodexAppServerConnection.InteractivePromptResolvedHandler?
        let syncer = CodexAppServerRegistryRuntimeSyncer(eventHub: hub,
                                                        sidebarMessageSender: { message in
                                                            sidebarLock.lock()
                                                            sidebarMessages.append(message)
                                                            sidebarLock.unlock()
                                                        },
                                                        sidebarQueue: sidebarQueue,
                                                        attachHandler: { _, _, _, _, onInteractivePrompt, onInteractivePromptResolved, _ in
            promptHandler = onInteractivePrompt
            resolvedHandler = onInteractivePromptResolved
            return runtime
        })
        syncer.sync(records: [
            Self.record(sessionID: "app", runtime: "codex_app_server", socketPath: "/tmp/app.sock"),
        ])
        let envelope = Self.approvalEnvelope(sessionID: "app")
        try XCTUnwrap(promptHandler)(envelope)
        sidebarQueue.sync {}
        sidebarLock.lock()
        let promptMessages = sidebarMessages
        sidebarLock.unlock()
        XCTAssertTrue(promptMessages.contains("report_shell_state needs_input --workspace_id=workspace-1"))

        runtime.onStop = {
            resolvedHandler?(Self.event(sessionID: "app",
                                        promptID: envelope.prompt.promptID,
                                        seq: 2,
                                        lifecycleToken: envelope.event.eventID))
        }
        syncer.sync(records: [])
        sidebarQueue.sync {}

        XCTAssertNil(hub.activeInteractivePrompt(workspaceID: "workspace-1",
                                                 sessionID: "app",
                                                 promptID: envelope.prompt.promptID))
        sidebarLock.lock()
        let allMessages = sidebarMessages
        sidebarLock.unlock()
        XCTAssertEqual(allMessages.last, "report_shell_state running --workspace_id=workspace-1",
                       "the retiring generation's terminal sidebar cleanup must be delivered, got \(allMessages)")
    }

    func testSidebarWorkPastInitialRecheckIsDroppedWhenReplacementCompletesFirst() throws {
        // TOCTOU on the queue side: the dequeued work passed its initial
        // generation check, then the replacement COMPLETES (via the recheck
        // hook barrier); the locked recheck must drop the stale send.
        let hub = AgentEventHub()
        let sidebarQueue = DispatchQueue(label: "test.sidebar.dequeue-toctou")
        let sidebarLock = NSLock()
        var sidebarMessages = [String]()
        var agentHandlers = [CodexAppServerHeadlessRuntime.AgentEventHandler]()
        let syncer = CodexAppServerRegistryRuntimeSyncer(eventHub: hub,
                                                        sidebarMessageSender: { message in
                                                            sidebarLock.lock()
                                                            sidebarMessages.append(message)
                                                            sidebarLock.unlock()
                                                        },
                                                        sidebarQueue: sidebarQueue,
                                                        attachHandler: { _, _, _, onAgentEvent, _, _, _ in
            agentHandlers.append(onAgentEvent)
            return FakeRuntimeSession()
        })
        syncer.sync(records: [
            Self.record(sessionID: "app", runtime: "codex_app_server", socketPath: "/tmp/app-1.sock"),
        ])

        var replaced = false
        syncer.sidebarDequeueRecheckHook = { [weak syncer] in
            guard replaced == false else { return }
            replaced = true
            syncer?.sidebarDequeueRecheckHook = nil
            syncer?.sync(records: [
                Self.record(sessionID: "app", runtime: "codex_app_server", socketPath: "/tmp/app-2.sock"),
            ])
        }
        agentHandlers[0](Self.appServerEvent(eventID: "turn-started",
                                             seq: 1,
                                             sessionID: "app",
                                             type: .thinking,
                                             text: "Codex turn started",
                                             payloadKind: "turn_started"))
        sidebarQueue.sync {}

        sidebarLock.lock()
        let messages = sidebarMessages
        sidebarLock.unlock()
        XCTAssertTrue(messages.isEmpty,
                      "sidebar work that lost the generation race at dequeue must be dropped, got \(messages)")
    }

    func testRetiringTerminalDoesNotClearNewGenerationNotifiedState() {
        // The old lifecycle's terminal must only clear ITS lifecycle: after
        // the new generation notified for token B, a late resolved carrying
        // token A must not re-open the notification gate.
        let deduper = AgentInteractivePromptNotificationDeduper()
        let promptA = Self.interactivePromptEvent(sessionID: "app", promptID: "prompt-1", seq: 1)
        var metadataA = promptA.metadata ?? [:]
        metadataA["lifecycle_token"] = "token-A"
        let notifiedA = promptA.withMetadataForTesting(metadataA)
        XCTAssertTrue(deduper.shouldNotify(notifiedA, sessionID: "app"))

        var resolvedMetadataA = Self.event(sessionID: "app", promptID: "prompt-1", seq: 2).metadata ?? [:]
        resolvedMetadataA["lifecycle_token"] = "token-A"
        let resolvedA = Self.event(sessionID: "app", promptID: "prompt-1", seq: 2).withMetadataForTesting(resolvedMetadataA)
        deduper.markResolved(resolvedA, sessionID: "app")

        var metadataB = promptA.metadata ?? [:]
        metadataB["lifecycle_token"] = "token-B"
        let notifiedB = Self.interactivePromptEvent(sessionID: "app", promptID: "prompt-1", seq: 3).withMetadataForTesting(metadataB)
        XCTAssertTrue(deduper.shouldNotify(notifiedB, sessionID: "app"), "a fresh lifecycle may notify again")

        // The LATE duplicate of the old terminal (token A) arrives after B.
        deduper.markResolved(resolvedA, sessionID: "app")
        XCTAssertFalse(deduper.shouldNotify(notifiedB, sessionID: "app"),
                       "a stale terminal for lifecycle A must not clear lifecycle B's notified state")
    }

    func testAttachStageCommitDrainPreservesArrivalOrderAgainstConcurrentRun() {
        // Window: commit() started draining staged A/B; a post-return
        // callback C arrives mid-drain. FIFO must hold: C executes after B,
        // never interleaved ahead of undrained staged work.
        let stage = CodexAppServerAttachStage()
        let orderLock = NSLock()
        var order = [String]()
        let record: (String) -> Void = { name in
            orderLock.lock()
            order.append(name)
            orderLock.unlock()
        }
        let aEntered = DispatchSemaphore(value: 0)
        let releaseA = DispatchSemaphore(value: 0)
        stage.run {
            record("A")
            aEntered.signal()
            _ = releaseA.wait(timeout: .now() + 5.0)
        }
        stage.run { record("B") }

        let commitDone = expectation(description: "commit done")
        DispatchQueue.global(qos: .userInitiated).async {
            stage.commit()
            commitDone.fulfill()
        }
        XCTAssertEqual(aEntered.wait(timeout: .now() + 2.0), .success)

        // C arrives while the drain is mid-flight (A executing, B undrained).
        let cSubmitted = expectation(description: "C submitted")
        DispatchQueue.global(qos: .userInitiated).async {
            stage.run { record("C") }
            cSubmitted.fulfill()
        }
        wait(for: [cSubmitted], timeout: 2.0)

        releaseA.signal()
        wait(for: [commitDone], timeout: 2.0)
        orderLock.lock()
        let observed = order
        orderLock.unlock()
        XCTAssertEqual(observed, ["A", "B", "C"],
                       "post-commit callbacks must queue behind undrained staged work, got \(observed)")
    }

    func testConcurrentSyncWaitsAndNewerGenerationWins() throws {
        // Two-sync barrier: sync A is stuck inside its attach; sync B (same
        // session, new socket) arrives while A is blocked. B must wait for A
        // and then REPLACE it — never the other way around.
        let hub = AgentEventHub()
        let runtimeA = FakeRuntimeSession()
        let runtimeB = FakeRuntimeSession()
        let aAttachEntered = DispatchSemaphore(value: 0)
        let releaseAAttach = DispatchSemaphore(value: 0)
        let attachedLock = NSLock()
        var attachedSockets = [String]()
        var capturedPromptHandlers = [CodexAppServerConnection.InteractivePromptHandler]()
        let syncer = CodexAppServerRegistryRuntimeSyncer(eventHub: hub, attachHandler: { record, _, _, _, onInteractivePrompt, _, _ in
            attachedLock.lock()
            attachedSockets.append(record.appServerSocket ?? "-")
            capturedPromptHandlers.append(onInteractivePrompt)
            let isFirst = attachedSockets.count == 1
            attachedLock.unlock()
            if isFirst {
                aAttachEntered.signal()
                _ = releaseAAttach.wait(timeout: .now() + 5.0)
                return runtimeA
            }
            return runtimeB
        })

        let syncADone = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            syncer.sync(records: [
                Self.record(sessionID: "app", runtime: "codex_app_server", socketPath: "/tmp/app-1.sock"),
            ])
            syncADone.signal()
        }
        XCTAssertEqual(aAttachEntered.wait(timeout: .now() + 2.0), .success)

        // B arrives while A is still inside its attach.
        let bArrived = DispatchSemaphore(value: 0)
        syncer.syncArrivalHook = { records in
            if records.first?.appServerSocket == "/tmp/app-2.sock" {
                bArrived.signal()
            }
        }
        let syncBDone = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            syncer.sync(records: [
                Self.record(sessionID: "app", runtime: "codex_app_server", socketPath: "/tmp/app-2.sock"),
            ])
            syncBDone.signal()
        }
        XCTAssertEqual(bArrived.wait(timeout: .now() + 2.0), .success,
                       "sync B must have arrived while sync A was blocked in attach")

        releaseAAttach.signal()
        XCTAssertEqual(syncADone.wait(timeout: .now() + 5.0), .success)
        XCTAssertEqual(syncBDone.wait(timeout: .now() + 5.0), .success)

        attachedLock.lock()
        let observedSockets = attachedSockets
        attachedLock.unlock()
        XCTAssertEqual(observedSockets, ["/tmp/app-1.sock", "/tmp/app-2.sock"],
                       "B must wait for A's attach to finish before attaching")
        XCTAssertTrue(runtimeA.stopped, "the replaced generation A must be stopped")
        XCTAssertFalse(runtimeB.stopped)
        try syncer.submitMessage(sessionID: "app", text: "route check", clientRequestID: nil)
        XCTAssertEqual(runtimeB.submittedMessages, ["route check"], "submits must route to generation B")
        XCTAssertTrue(runtimeA.submittedMessages.isEmpty)

        // Callback admission follows current=B: A's captured callback is
        // dropped, B's is accepted.
        let staleEnvelope = Self.approvalEnvelope(sessionID: "app", requestID: "approval-stale", seq: 5)
        capturedPromptHandlers[0](staleEnvelope)
        XCTAssertTrue(hub.fetch(workspaceID: "workspace-1", sessionID: "app", limit: 10).events.isEmpty,
                      "generation A's late callback must be dropped")
        let liveEnvelope = Self.approvalEnvelope(sessionID: "app", requestID: "approval-live", seq: 6)
        capturedPromptHandlers[1](liveEnvelope)
        XCTAssertEqual(hub.fetch(workspaceID: "workspace-1", sessionID: "app", limit: 10).events.map(\.eventID),
                       [liveEnvelope.event.eventID],
                       "generation B's callback must be accepted")
    }

    // Shared harness: forms a REAL candidates-empty gap (old entry removed,
    // replacement blocked inside the NEW attach), then starts the submit.
    private func makeEntryGap(hub: AgentEventHub,
                              newRuntime: FakeRuntimeSession,
                              transitionWaitTimeout: TimeInterval = 5.0)
        -> (syncer: CodexAppServerRegistryRuntimeSyncer,
            attachEntered: DispatchSemaphore,
            releaseAttach: DispatchSemaphore,
            syncDone: DispatchSemaphore,
            attachShouldThrow: () -> Void) {
        let oldRuntime = FakeRuntimeSession()
        let attachEntered = DispatchSemaphore(value: 0)
        let releaseAttach = DispatchSemaphore(value: 0)
        let throwFlag = LockedBox(false)
        var runtimeIndex = 0
        let syncer = CodexAppServerRegistryRuntimeSyncer(eventHub: hub,
                                                        transitionWaitTimeout: transitionWaitTimeout,
                                                        attachHandler: { _, _, _, _, _, _, _ in
            defer { runtimeIndex += 1 }
            if runtimeIndex == 0 {
                return oldRuntime
            }
            attachEntered.signal()
            _ = releaseAttach.wait(timeout: .now() + 10.0)
            if throwFlag.value() {
                throw BridgeInternalError.invalidRequest("attach failed for test")
            }
            return newRuntime
        })
        syncer.sync(records: [
            Self.record(sessionID: "app", runtime: "codex_app_server", socketPath: "/tmp/app-1.sock"),
        ])
        let syncDone = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            syncer.sync(records: [
                Self.record(sessionID: "app", runtime: "codex_app_server", socketPath: "/tmp/app-2.sock"),
            ])
            syncDone.signal()
        }
        return (syncer, attachEntered, releaseAttach, syncDone, { throwFlag.set(true) })
    }

    func testSubmitStartedInsideEntryGapHitsEmptyCandidatesWaitThenReconciles() throws {
        // The submit STARTS inside the gap (old entry gone, new attach
        // blocked): it must hit the candidates-empty wait branch, then
        // reconcile against the committed generation B.
        let hub = AgentEventHub()
        let newRuntime = FakeRuntimeSession()
        newRuntime.pendingConfirmationPromptIDs.insert("prompt-1")
        let gap = makeEntryGap(hub: hub, newRuntime: newRuntime)
        XCTAssertEqual(gap.attachEntered.wait(timeout: .now() + 2.0), .success,
                       "the entry gap must have formed (old removed, attach blocked)")

        let waitEntered = DispatchSemaphore(value: 0)
        gap.syncer.transitionWaitHook = { _ in waitEntered.signal() }
        var outcome: CodexAppServerApprovalSubmitOutcome?
        var submitError: Error?
        let submitDone = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                outcome = try gap.syncer.submitApproval(promptID: "prompt-1",
                                                        targetIndex: 0,
                                                        clientRequestID: "client-1",
                                                        lifecycleToken: nil,
                                                        workspaceID: "workspace-1",
                                                        panelID: "panel-1",
                                                        sessionID: "app")
            } catch {
                submitError = error
            }
            submitDone.signal()
        }
        XCTAssertEqual(waitEntered.wait(timeout: .now() + 2.0), .success,
                       "the submit must hit the candidates-empty transition wait")

        gap.releaseAttach.signal()
        XCTAssertEqual(gap.syncDone.wait(timeout: .now() + 5.0), .success)
        XCTAssertEqual(submitDone.wait(timeout: .now() + 5.0), .success)
        XCTAssertNil(submitError)
        guard case .pendingConfirmation? = outcome else {
            return XCTFail("expected pendingConfirmation from generation B, got \(String(describing: outcome))")
        }
        XCTAssertEqual(newRuntime.submitAttempts, ["prompt-1"])
    }

    func testTransitionWaitTimeoutFailsClosedInsteadOfAnsweringFromOldState() throws {
        // The transition never commits within the (injectable, short)
        // timeout. The submit must fail with an explicit transition conflict
        // — never the old Hub terminal, never a plain notFound.
        let hub = AgentEventHub()
        // A stale legacy terminal sits in the Hub: the broken path would
        // answer alreadyResolved from it.
        hub.publish(Self.event(sessionID: "app", promptID: "prompt-1", seq: 3))
        let newRuntime = FakeRuntimeSession()
        let gap = makeEntryGap(hub: hub, newRuntime: newRuntime, transitionWaitTimeout: 0.2)
        XCTAssertEqual(gap.attachEntered.wait(timeout: .now() + 2.0), .success)

        var outcome: CodexAppServerApprovalSubmitOutcome?
        var submitError: Error?
        let submitDone = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                outcome = try gap.syncer.submitApproval(promptID: "prompt-1",
                                                        targetIndex: 0,
                                                        clientRequestID: "client-1",
                                                        lifecycleToken: nil,
                                                        workspaceID: "workspace-1",
                                                        panelID: "panel-1",
                                                        sessionID: "app")
            } catch {
                submitError = error
            }
            submitDone.signal()
        }
        XCTAssertEqual(submitDone.wait(timeout: .now() + 5.0), .success)
        XCTAssertNil(outcome, "a timed-out transition must not answer from old state, got \(String(describing: outcome))")
        guard case BridgeInternalError.conflict? = submitError else {
            return XCTFail("expected an explicit transition conflict, got \(String(describing: submitError))")
        }

        // Cleanup only after the assertion: release the blocked attach.
        gap.releaseAttach.signal()
        XCTAssertEqual(gap.syncDone.wait(timeout: .now() + 5.0), .success)
    }

    func testAttachFailureWakesTransitionWaiterForAuthoritativeReconcile() throws {
        // The transition FAILS (attach throws). The waiter must be woken by
        // the group leave — not hang to its (long) timeout — and reconcile
        // authoritatively (notFound here: no runtime, no terminal).
        let hub = AgentEventHub()
        let newRuntime = FakeRuntimeSession()
        let gap = makeEntryGap(hub: hub, newRuntime: newRuntime, transitionWaitTimeout: 30.0)
        XCTAssertEqual(gap.attachEntered.wait(timeout: .now() + 2.0), .success)

        let waitEntered = DispatchSemaphore(value: 0)
        gap.syncer.transitionWaitHook = { _ in waitEntered.signal() }
        var submitError: Error?
        let submitDone = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                _ = try gap.syncer.submitApproval(promptID: "prompt-1",
                                                  targetIndex: 0,
                                                  clientRequestID: "client-1",
                                                  lifecycleToken: nil,
                                                  workspaceID: "workspace-1",
                                                  panelID: "panel-1",
                                                  sessionID: "app")
            } catch {
                submitError = error
            }
            submitDone.signal()
        }
        XCTAssertEqual(waitEntered.wait(timeout: .now() + 2.0), .success)

        gap.attachShouldThrow()
        gap.releaseAttach.signal()
        XCTAssertEqual(gap.syncDone.wait(timeout: .now() + 5.0), .success)
        // Well under the 30s timeout: the leave woke the waiter.
        XCTAssertEqual(submitDone.wait(timeout: .now() + 3.0), .success,
                       "the waiter must wake on the failed transition's group leave, not its timeout")
        guard case BridgeInternalError.notFound? = submitError else {
            return XCTFail("expected authoritative notFound after the failed transition, got \(String(describing: submitError))")
        }
    }

    func testAttachStagedCallbacksReachLiveSubscribersInArrivalOrderAgainstPostCommitCallback() throws {
        // Interior barrier on the stage itself: the commit drain has DEQUEUED
        // A (mode .committing) while B is still undrained; C arrives from
        // another thread in exactly that window. The live Hub subscriber
        // must observe A, B, C.
        let hub = AgentEventHub()
        let orderLock = NSLock()
        var liveOrder = [String]()
        let (subscriptionID, _) = hub.subscribe(workspaceID: "workspace-1", sessionID: "app") { envelope in
            orderLock.lock()
            liveOrder.append(envelope.event.eventID)
            orderLock.unlock()
        }
        defer { hub.unsubscribe(subscriptionID) }

        var capturedPromptHandler: CodexAppServerConnection.InteractivePromptHandler?
        let drainEnteredA = DispatchSemaphore(value: 0)
        let releaseDrain = DispatchSemaphore(value: 0)
        let syncer = CodexAppServerRegistryRuntimeSyncer(eventHub: hub, attachHandler: { _, _, _, _, onInteractivePrompt, _, _ in
            capturedPromptHandler = onInteractivePrompt
            onInteractivePrompt(Self.approvalEnvelope(sessionID: "app", requestID: "approval-A", seq: 1))
            onInteractivePrompt(Self.approvalEnvelope(sessionID: "app", requestID: "approval-B", seq: 2))
            return FakeRuntimeSession()
        })
        var pausedFirstDrain = false
        syncer.attachStageHook = { stage in
            stage.commitDrainHook = {
                guard pausedFirstDrain == false else { return }
                pausedFirstDrain = true
                drainEnteredA.signal()
                _ = releaseDrain.wait(timeout: .now() + 5.0)
            }
        }
        let syncDone = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            syncer.sync(records: [
                Self.record(sessionID: "app", runtime: "codex_app_server", socketPath: "/tmp/app.sock"),
            ])
            syncDone.signal()
        }
        // The drain HAS taken A (committing) and B is still queued.
        XCTAssertEqual(drainEnteredA.wait(timeout: .now() + 2.0), .success)

        // C arrives mid-drain from the test thread.
        let cReturned = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            try? XCTUnwrap(capturedPromptHandler)(Self.approvalEnvelope(sessionID: "app", requestID: "approval-C", seq: 3))
            cReturned.signal()
        }
        XCTAssertEqual(cReturned.wait(timeout: .now() + 2.0), .success,
                       "C must be BUFFERED during .committing (its run() returns immediately)")

        releaseDrain.signal()
        XCTAssertEqual(syncDone.wait(timeout: .now() + 5.0), .success)
        hub.drainDeliveriesForTesting()
        orderLock.lock()
        let observed = liveOrder
        orderLock.unlock()
        XCTAssertEqual(observed.count, 3)
        XCTAssertTrue(observed[0].contains(Self.approvalEnvelope(sessionID: "app", requestID: "approval-A").prompt.promptID))
        XCTAssertTrue(observed[1].contains(Self.approvalEnvelope(sessionID: "app", requestID: "approval-B").prompt.promptID))
        XCTAssertTrue(observed[2].contains(Self.approvalEnvelope(sessionID: "app", requestID: "approval-C").prompt.promptID))
    }

    func testReplacementInterleaveKeepsNewGenerationNotifiedStateAndDedupesDuplicate() throws {
        // SAME promptID across the replacement, DIFFERENT lifecycle tokens —
        // the dangerous shape: late token-A cleanup must not clear token-B's
        // notification gate nor send running; B duplicate must not re-notify;
        // only B's terminal completes.
        let hub = AgentEventHub()
        let sidebarQueue = DispatchQueue(label: "test.sidebar.replacement-interleave")
        let sidebarLock = NSLock()
        var sidebarMessages = [String]()
        var promptHandlers = [CodexAppServerConnection.InteractivePromptHandler]()
        var resolvedHandlers = [CodexAppServerConnection.InteractivePromptResolvedHandler]()
        let oldRuntime = FakeRuntimeSession()
        let newRuntime = FakeRuntimeSession()
        var runtimeIndex = 0
        let syncer = CodexAppServerRegistryRuntimeSyncer(eventHub: hub,
                                                        sidebarMessageSender: { message in
                                                            sidebarLock.lock()
                                                            sidebarMessages.append(message)
                                                            sidebarLock.unlock()
                                                        },
                                                        sidebarQueue: sidebarQueue,
                                                        attachHandler: { _, _, _, _, onInteractivePrompt, onInteractivePromptResolved, _ in
            promptHandlers.append(onInteractivePrompt)
            resolvedHandlers.append(onInteractivePromptResolved)
            defer { runtimeIndex += 1 }
            return runtimeIndex == 0 ? oldRuntime : newRuntime
        })
        syncer.sync(records: [
            Self.record(sessionID: "app", runtime: "codex_app_server", socketPath: "/tmp/app-1.sock"),
        ])
        // Old generation: prompt delivery A (token A) notifies.
        let envelopeA = Self.approvalEnvelope(sessionID: "app", requestID: "approval-1", seq: 1)
        let promptID = envelopeA.prompt.promptID
        promptHandlers[0](envelopeA)
        sidebarQueue.sync {}
        sidebarLock.lock()
        var messages = sidebarMessages
        sidebarLock.unlock()
        XCTAssertEqual(messages.filter { $0.contains("notification.create") }.count, 1)

        // Replacement: stop() terminalizes A's lifecycle SYNCHRONOUSLY with
        // A's token; then the new generation attaches.
        oldRuntime.onStop = {
            resolvedHandlers[0](Self.event(sessionID: "app",
                                           promptID: promptID,
                                           seq: 2,
                                           lifecycleToken: envelopeA.event.eventID))
        }
        syncer.sync(records: [
            Self.record(sessionID: "app", runtime: "codex_app_server", socketPath: "/tmp/app-2.sock"),
        ])
        sidebarQueue.sync {}

        // New generation redelivers the SAME promptID as delivery B (token B).
        let envelopeB = Self.approvalEnvelope(sessionID: "app", requestID: "approval-1", seq: 5)
        XCTAssertEqual(envelopeB.prompt.promptID, promptID)
        XCTAssertNotEqual(envelopeB.event.eventID, envelopeA.event.eventID)
        promptHandlers[1](envelopeB)
        sidebarQueue.sync {}
        sidebarLock.lock()
        messages = sidebarMessages
        sidebarLock.unlock()
        XCTAssertEqual(messages.filter { $0.contains("notification.create") }.count, 2,
                       "B (a fresh lifecycle of the same promptID) notifies once")
        let runningAfterB = messages.filter { $0 == "report_shell_state running --workspace_id=workspace-1" }.count

        // LATE duplicate of A's terminal (token A): must not clear B's gate
        // nor send running.
        resolvedHandlers[1](Self.event(sessionID: "app",
                                       promptID: promptID,
                                       seq: 6,
                                       lifecycleToken: envelopeA.event.eventID))
        sidebarQueue.sync {}
        sidebarLock.lock()
        messages = sidebarMessages
        sidebarLock.unlock()
        XCTAssertEqual(messages.filter { $0 == "report_shell_state running --workspace_id=workspace-1" }.count,
                       runningAfterB,
                       "a late token-A terminal must not send running while B is active")

        // B duplicate must not re-notify (the gate survived the stale terminal).
        promptHandlers[1](envelopeB)
        sidebarQueue.sync {}
        sidebarLock.lock()
        messages = sidebarMessages
        sidebarLock.unlock()
        XCTAssertEqual(messages.filter { $0.contains("notification.create") }.count, 2)

        // Only B's own terminal completes and restores running.
        resolvedHandlers[1](Self.event(sessionID: "app",
                                       promptID: promptID,
                                       seq: 7,
                                       lifecycleToken: envelopeB.event.eventID))
        sidebarQueue.sync {}
        sidebarLock.lock()
        messages = sidebarMessages
        sidebarLock.unlock()
        XCTAssertEqual(messages.filter { $0 == "report_shell_state running --workspace_id=workspace-1" }.count,
                       runningAfterB + 1)
    }

    func testDeduperLegacySequenceUnknownAndDuplicateTerminalsAreZeroSideEffect() {
        // Legacy contract on the shared deduper: identity is
        // session+promptID (eventID changes are duplicates); only
        // .clearedNotified may produce a running side effect.
        let deduper = AgentInteractivePromptNotificationDeduper()
        func legacyPrompt(eventID: String) -> AgentEvent {
            AgentEvent(eventID: eventID, seq: 1, vendor: "claude",
                       workspaceID: "workspace-1", sessionID: "app",
                       timestamp: "2026-06-07T00:00:00.000Z", type: .interactivePrompt,
                       role: nil, text: nil, name: nil, input: nil, output: nil, toolCallID: nil,
                       metadata: ["prompt_id": "legacy-1", "panel_id": "panel-1"])
        }
        func legacyTerminal(eventID: String, promptID: String = "legacy-1") -> AgentEvent {
            AgentEvent(eventID: eventID, seq: 2, vendor: "claude",
                       workspaceID: "workspace-1", sessionID: "app",
                       timestamp: "2026-06-07T00:00:01.000Z", type: .interactivePromptResolved,
                       role: nil, text: nil, name: nil, input: nil, output: nil, toolCallID: nil,
                       metadata: ["prompt_id": promptID, "panel_id": "panel-1", "reason": "tool_result"])
        }

        XCTAssertTrue(deduper.shouldNotify(legacyPrompt(eventID: "e1"), sessionID: "app"))
        XCTAssertFalse(deduper.shouldNotify(legacyPrompt(eventID: "e2"), sessionID: "app"),
                       "legacy identity is session+promptID: a new eventID before the terminal is a duplicate")
        // Unknown terminal (a promptID that never notified): zero side effect.
        XCTAssertEqual(deduper.markResolved(legacyTerminal(eventID: "t-unknown", promptID: "legacy-OTHER"), sessionID: "app"),
                       .noneNotified)
        // Matching terminal: exactly once.
        XCTAssertEqual(deduper.markResolved(legacyTerminal(eventID: "t1"), sessionID: "app"), .clearedNotified)
        // Duplicate terminal: zero side effect.
        XCTAssertEqual(deduper.markResolved(legacyTerminal(eventID: "t2"), sessionID: "app"), .noneNotified)
        // Re-delivery after the terminal: a new lifecycle.
        XCTAssertTrue(deduper.shouldNotify(legacyPrompt(eventID: "e3"), sessionID: "app"))
    }

    func testSameProchmptIDTokenRotationIsExactlyOnceAcrossStaleAndDuplicateTerminals() throws {
        // Full production callback sequence WITHOUT terminalizing A first:
        // A prompt -> B prompt (same promptID, token B) -> late A terminal ->
        // duplicate B prompt -> B terminal -> duplicate B terminal.
        let hub = AgentEventHub()
        let sidebarQueue = DispatchQueue(label: "test.sidebar.exactly-once")
        let sidebarLock = NSLock()
        var sidebarMessages = [String]()
        var promptHandler: CodexAppServerConnection.InteractivePromptHandler?
        var resolvedHandler: CodexAppServerConnection.InteractivePromptResolvedHandler?
        let syncer = CodexAppServerRegistryRuntimeSyncer(eventHub: hub,
                                                        sidebarMessageSender: { message in
                                                            sidebarLock.lock()
                                                            sidebarMessages.append(message)
                                                            sidebarLock.unlock()
                                                        },
                                                        sidebarQueue: sidebarQueue,
                                                        attachHandler: { _, _, _, _, onInteractivePrompt, onInteractivePromptResolved, _ in
            promptHandler = onInteractivePrompt
            resolvedHandler = onInteractivePromptResolved
            return FakeRuntimeSession()
        })
        syncer.sync(records: [
            Self.record(sessionID: "app", runtime: "codex_app_server", socketPath: "/tmp/app.sock"),
        ])
        func snapshotMessages() -> [String] {
            sidebarQueue.sync {}
            sidebarLock.lock()
            defer { sidebarLock.unlock() }
            return sidebarMessages
        }
        func running(_ messages: [String]) -> Int {
            messages.filter { $0 == "report_shell_state running --workspace_id=workspace-1" }.count
        }
        func notifications(_ messages: [String]) -> Int {
            messages.filter { $0.contains("notification.create") }.count
        }
        let request = CodexAppServerApprovalRequest(
            method: "item/commandExecution/requestApproval",
            requestID: .string("approval-1"),
            params: [
                "threadId": .string("thread-1"),
                "turnId": .string("turn-1"),
                "itemId": .string("item-1"),
                "startedAtMs": .number(1_786_000_000_000),
                "command": .string("ls"),
            ])!
        let prompt = request.makePrompt(epoch: "e")
        func tokenizedPrompt(seq: Int, token: String) -> CodexAppServerInteractivePromptEnvelope {
            var metadata = Self.interactivePromptEvent(sessionID: "app", promptID: prompt.promptID, seq: seq, includePayload: true).metadata ?? [:]
            metadata["lifecycle_token"] = token
            return CodexAppServerInteractivePromptEnvelope(request: request,
                                                           prompt: prompt,
                                                           event: Self.interactivePromptEvent(sessionID: "app", promptID: prompt.promptID, seq: seq, includePayload: true).withMetadataForTesting(metadata))
        }

        // A prompt (token A) notifies.
        try XCTUnwrap(promptHandler)(tokenizedPrompt(seq: 1, token: "token-A"))
        XCTAssertEqual(notifications(snapshotMessages()), 1)

        // B prompt (same promptID, token B, NO terminal for A in between):
        // B must BECOME the current notified lifecycle and notify.
        try XCTUnwrap(promptHandler)(tokenizedPrompt(seq: 2, token: "token-B"))
        var messages = snapshotMessages()
        XCTAssertEqual(notifications(messages), 2,
                       "token B is a NEW lifecycle of the same promptID: it must notify, got \(messages)")

        // Late A terminal: B is current — zero side effects, gate intact.
        try XCTUnwrap(resolvedHandler)(Self.event(sessionID: "app", promptID: prompt.promptID, seq: 3, lifecycleToken: "token-A"))
        messages = snapshotMessages()
        XCTAssertEqual(running(messages), 0,
                       "a late token-A terminal must not send running while B is current, got \(messages)")

        // Duplicate B prompt: exact same delivery — deduped.
        try XCTUnwrap(promptHandler)(tokenizedPrompt(seq: 2, token: "token-B"))
        messages = snapshotMessages()
        XCTAssertEqual(notifications(messages), 2, "duplicate B must not notify again")

        // B terminal: running exactly once.
        try XCTUnwrap(resolvedHandler)(Self.event(sessionID: "app", promptID: prompt.promptID, seq: 4, lifecycleToken: "token-B"))
        messages = snapshotMessages()
        XCTAssertEqual(running(messages), 1)

        // Duplicate B terminal: still exactly once.
        try XCTUnwrap(resolvedHandler)(Self.event(sessionID: "app", promptID: prompt.promptID, seq: 5, lifecycleToken: "token-B"))
        messages = snapshotMessages()
        XCTAssertEqual(running(messages), 1,
                       "a duplicate terminal must produce zero further side effects, got \(messages)")
    }

    func testLateTokenATerminalDoesNotSendRunningWhileTokenBPromptActive() throws {
        // Same promptID, different lifecycle tokens (a real replacement).
        // B's prompt sidebar state was sent; a LATE token-A terminal must
        // NOT restore running nor clear B's notification gate; only B's own
        // terminal sends running (exactly once).
        let hub = AgentEventHub()
        let sidebarQueue = DispatchQueue(label: "test.sidebar.token-exact-running")
        let sidebarLock = NSLock()
        var sidebarMessages = [String]()
        var promptHandler: CodexAppServerConnection.InteractivePromptHandler?
        var resolvedHandler: CodexAppServerConnection.InteractivePromptResolvedHandler?
        let syncer = CodexAppServerRegistryRuntimeSyncer(eventHub: hub,
                                                        sidebarMessageSender: { message in
                                                            sidebarLock.lock()
                                                            sidebarMessages.append(message)
                                                            sidebarLock.unlock()
                                                        },
                                                        sidebarQueue: sidebarQueue,
                                                        attachHandler: { _, _, _, _, onInteractivePrompt, onInteractivePromptResolved, _ in
            promptHandler = onInteractivePrompt
            resolvedHandler = onInteractivePromptResolved
            return FakeRuntimeSession()
        })
        syncer.sync(records: [
            Self.record(sessionID: "app", runtime: "codex_app_server", socketPath: "/tmp/app.sock"),
        ])

        func tokenizedPrompt(seq: Int, token: String) -> AgentEvent {
            var metadata = Self.interactivePromptEvent(sessionID: "app", promptID: "prompt-1", seq: seq, includePayload: true).metadata ?? [:]
            metadata["lifecycle_token"] = token
            return Self.interactivePromptEvent(sessionID: "app", promptID: "prompt-1", seq: seq, includePayload: true).withMetadataForTesting(metadata)
        }
        func tokenizedResolved(seq: Int, token: String) -> AgentEvent {
            var metadata = Self.event(sessionID: "app", promptID: "prompt-1", seq: seq).metadata ?? [:]
            metadata["lifecycle_token"] = token
            return Self.event(sessionID: "app", promptID: "prompt-1", seq: seq).withMetadataForTesting(metadata)
        }
        let request = CodexAppServerApprovalRequest(
            method: "item/commandExecution/requestApproval",
            requestID: .string("approval-1"),
            params: [
                "threadId": .string("thread-1"),
                "turnId": .string("turn-1"),
                "itemId": .string("item-1"),
                "startedAtMs": .number(1_786_000_000_000),
                "command": .string("ls"),
            ])!
        let prompt = request.makePrompt(epoch: "e")

        // B delivery (token-B) notifies and sets sidebar prompt state.
        try XCTUnwrap(promptHandler)(CodexAppServerInteractivePromptEnvelope(request: request,
                                                                             prompt: prompt,
                                                                             event: tokenizedPrompt(seq: 3, token: "token-B")))
        sidebarQueue.sync {}
        sidebarLock.lock()
        var messages = sidebarMessages
        sidebarLock.unlock()
        XCTAssertEqual(messages.filter { $0.contains("notification.create") }.count, 1)
        XCTAssertEqual(messages.last, "report_shell_state needs_input --workspace_id=workspace-1")

        // LATE token-A terminal for the same promptID.
        try XCTUnwrap(resolvedHandler)(tokenizedResolved(seq: 4, token: "token-A"))
        sidebarQueue.sync {}
        sidebarLock.lock()
        messages = sidebarMessages
        sidebarLock.unlock()
        XCTAssertFalse(messages.contains("report_shell_state running --workspace_id=workspace-1"),
                       "a stale token-A terminal must not restore running while token-B is active, got \(messages)")

        // B duplicate must still be deduped (the gate was not cleared).
        try XCTUnwrap(promptHandler)(CodexAppServerInteractivePromptEnvelope(request: request,
                                                                             prompt: prompt,
                                                                             event: tokenizedPrompt(seq: 3, token: "token-B")))
        sidebarQueue.sync {}
        sidebarLock.lock()
        messages = sidebarMessages
        sidebarLock.unlock()
        XCTAssertEqual(messages.filter { $0.contains("notification.create") }.count, 1,
                       "the stale terminal must not have cleared B's notification gate")

        // B's own terminal sends running exactly once.
        try XCTUnwrap(resolvedHandler)(tokenizedResolved(seq: 5, token: "token-B"))
        sidebarQueue.sync {}
        sidebarLock.lock()
        messages = sidebarMessages
        sidebarLock.unlock()
        XCTAssertEqual(messages.filter { $0 == "report_shell_state running --workspace_id=workspace-1" }.count, 1)
    }

    func testStaleCandidateTimeoutIsNotSwallowedIntoSecondWaitOrHubFallback() throws {
        // Window: candidate A answered (stale success), the generation is
        // already retiring, and the FIRST transition wait times out. The
        // timeout must fail closed immediately: exactly one wait, no second
        // window, no Hub fallback answer — even when a legacy terminal sits
        // in the Hub and the second window would complete.
        let hub = AgentEventHub()
        // A legacy (non-capability) terminal the broken Hub fallback would
        // happily answer with.
        hub.publish(AgentEvent(eventID: "legacy-resolved-1",
                               seq: 3,
                               vendor: "claude",
                               workspaceID: "workspace-1",
                               sessionID: "app",
                               timestamp: "2026-06-07T00:00:00.000Z",
                               type: .interactivePromptResolved,
                               role: nil,
                               text: nil,
                               name: nil,
                               input: nil,
                               output: nil,
                               toolCallID: nil,
                               metadata: ["panel_id": "panel-1", "prompt_id": "prompt-1", "source": "workflow_confirm"]))

        let oldRuntime = FakeRuntimeSession()
        oldRuntime.submitEntered = DispatchSemaphore(value: 0)
        oldRuntime.submitBarrier = DispatchSemaphore(value: 0)
        oldRuntime.resolvedEventsByPromptID["prompt-1"] = Self.event(sessionID: "app", promptID: "prompt-1")
        let newRuntime = FakeRuntimeSession()
        let stopEntered = DispatchSemaphore(value: 0)
        let stopRelease = DispatchSemaphore(value: 0)
        oldRuntime.onStop = {
            stopEntered.signal()
            _ = stopRelease.wait(timeout: .now() + 10.0)
        }
        var runtimeIndex = 0
        let syncer = CodexAppServerRegistryRuntimeSyncer(eventHub: hub,
                                                        transitionWaitTimeout: 0.2,
                                                        attachHandler: { _, _, _, _, _, _, _ in
            defer { runtimeIndex += 1 }
            return runtimeIndex == 0 ? oldRuntime : newRuntime
        })
        syncer.sync(records: [
            Self.record(sessionID: "app", runtime: "codex_app_server", socketPath: "/tmp/app-1.sock"),
        ])

        let hookLock = NSLock()
        var hookCount = 0
        syncer.transitionWaitHook = { _ in
            hookLock.lock()
            hookCount += 1
            let count = hookCount
            hookLock.unlock()
            if count == 2 {
                // Broken path only: complete the SECOND window so the flow
                // could reach the Hub fallback.
                stopRelease.signal()
            }
        }

        var outcome: CodexAppServerApprovalSubmitOutcome?
        var submitError: Error?
        let submitDone = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                outcome = try syncer.submitApproval(promptID: "prompt-1",
                                                    targetIndex: 0,
                                                    clientRequestID: "client-1",
                                                    lifecycleToken: nil,
                                                    workspaceID: "workspace-1",
                                                    panelID: "panel-1",
                                                    sessionID: "app")
            } catch {
                submitError = error
            }
            submitDone.signal()
        }
        XCTAssertEqual(oldRuntime.submitEntered?.wait(timeout: .now() + 2.0), .success)

        let syncDone = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            syncer.sync(records: [
                Self.record(sessionID: "app", runtime: "codex_app_server", socketPath: "/tmp/app-2.sock"),
            ])
            syncDone.signal()
        }
        XCTAssertEqual(stopEntered.wait(timeout: .now() + 2.0), .success,
                       "the transition must be in progress before the stale success returns")

        // The stale success returns; the first wait must time out (0.2s) and
        // fail closed.
        oldRuntime.submitBarrier?.signal()
        XCTAssertEqual(submitDone.wait(timeout: .now() + 5.0), .success)

        hookLock.lock()
        let observedHookCount = hookCount
        hookLock.unlock()
        XCTAssertNil(outcome, "a timed-out transition must never answer from the Hub fallback, got \(String(describing: outcome))")
        guard case BridgeInternalError.conflict? = submitError else {
            return XCTFail("expected the FIRST timeout conflict, got \(String(describing: submitError))")
        }
        XCTAssertEqual(observedHookCount, 1, "exactly one transition wait — no second window")

        // Cleanup only after the assertions.
        stopRelease.signal()
        XCTAssertEqual(syncDone.wait(timeout: .now() + 5.0), .success)
    }

    func testRetiredGenerationPromptResolvedAndAgentCallbacksAreIgnored() {
        let hub = AgentEventHub()
        var promptHandlers = [CodexAppServerConnection.InteractivePromptHandler]()
        var resolvedHandlers = [CodexAppServerConnection.InteractivePromptResolvedHandler]()
        var agentHandlers = [CodexAppServerHeadlessRuntime.AgentEventHandler]()
        let syncer = CodexAppServerRegistryRuntimeSyncer(eventHub: hub, attachHandler: { _, _, _, _, onInteractivePrompt, onInteractivePromptResolved, _ in
            promptHandlers.append(onInteractivePrompt)
            resolvedHandlers.append(onInteractivePromptResolved)
            return FakeRuntimeSession()
        })
        _ = agentHandlers

        syncer.sync(records: [
            Self.record(sessionID: "app", runtime: "codex_app_server", socketPath: "/tmp/app-1.sock"),
        ])
        // Replace the generation.
        syncer.sync(records: [
            Self.record(sessionID: "app", runtime: "codex_app_server", socketPath: "/tmp/app-2.sock"),
        ])
        XCTAssertEqual(promptHandlers.count, 2)

        // Late prompt/resolved callbacks from the retired generation must not
        // reach the hub.
        let request = CodexAppServerApprovalRequest(
            method: "item/commandExecution/requestApproval",
            requestID: .string("approval-1"),
            params: [
                "threadId": .string("thread-1"),
                "turnId": .string("turn-1"),
                "itemId": .string("item-1"),
                "startedAtMs": .number(1_786_000_000_000),
                "command": .string("ls"),
            ])!
        let prompt = request.makePrompt(epoch: "e")
        let staleEnvelope = CodexAppServerInteractivePromptEnvelope(request: request,
                                                                   prompt: prompt,
                                                                   event: Self.interactivePromptEvent(sessionID: "app",
                                                                                                      promptID: prompt.promptID,
                                                                                                      includePayload: true))
        promptHandlers[0](staleEnvelope)
        resolvedHandlers[0](Self.event(sessionID: "app", promptID: prompt.promptID))
        XCTAssertTrue(hub.fetch(workspaceID: "workspace-1", sessionID: "app", limit: 10).events.isEmpty,
                      "retired generation callbacks must not publish to the hub")

        // The current generation publishes normally.
        promptHandlers[1](staleEnvelope)
        XCTAssertEqual(hub.fetch(workspaceID: "workspace-1", sessionID: "app", limit: 10).events.count, 1)
    }

    func testRetiredLoadedThreadCallbackIsIgnoredAfterReplacement() {
        let hub = AgentEventHub()
        var capturedThreadHandlers = [CodexAppServerHeadlessRuntime.ThreadIDHandler]()
        let syncer = CodexAppServerRegistryRuntimeSyncer(eventHub: hub, attachHandler: { _, _, _, _, _, _, onActiveThreadID in
            capturedThreadHandlers.append(onActiveThreadID)
            return FakeRuntimeSession()
        })
        var forwardedThreadIDs = [String]()
        syncer.activeThreadHandler = { _, threadID in
            forwardedThreadIDs.append(threadID)
        }

        syncer.sync(records: [
            Self.record(sessionID: "app", runtime: "codex_app_server", socketPath: "/tmp/app-1.sock"),
        ])
        XCTAssertEqual(capturedThreadHandlers.count, 1)
        capturedThreadHandlers[0]("thread-current")
        XCTAssertEqual(forwardedThreadIDs, ["thread-current"])

        // Replace the generation; a queued callback from the retired session
        // must be ignored and must not overwrite the current binding.
        syncer.sync(records: [
            Self.record(sessionID: "app", runtime: "codex_app_server", socketPath: "/tmp/app-2.sock"),
        ])
        XCTAssertEqual(capturedThreadHandlers.count, 2)
        capturedThreadHandlers[0]("thread-stale")
        XCTAssertEqual(forwardedThreadIDs, ["thread-current"])
        capturedThreadHandlers[1]("thread-new")
        XCTAssertEqual(forwardedThreadIDs, ["thread-current", "thread-new"])
    }

    func testSubmitMessageRoutesToMatchingRuntimeSession() throws {
        let hub = AgentEventHub()
        let firstRuntime = FakeRuntimeSession()
        let secondRuntime = FakeRuntimeSession()
        var runtimeIndex = 0
        let syncer = CodexAppServerRegistryRuntimeSyncer(eventHub: hub, attachHandler: { _, _, _, _, _, _, _ in
            defer { runtimeIndex += 1 }
            return runtimeIndex == 0 ? firstRuntime : secondRuntime
        })

        syncer.sync(records: [
            Self.record(sessionID: "first", runtime: "codex_app_server", socketPath: "/tmp/first.sock"),
            Self.record(sessionID: "second", runtime: "codex_app_server", socketPath: "/tmp/second.sock"),
        ])

        try syncer.submitMessage(sessionID: "second", text: "hello from remote", clientRequestID: nil)

        XCTAssertTrue(firstRuntime.submittedMessages.isEmpty)
        XCTAssertEqual(secondRuntime.submittedMessages, ["hello from remote"])
    }

    func testSyncTreatsSameThreadRecordsAsSeparateRuntimeInstances() {
        let hub = AgentEventHub()
        var attachedRecords = [AgentSessionRegistryRecord]()
        let syncer = CodexAppServerRegistryRuntimeSyncer(eventHub: hub, attachHandler: { record, _, _, _, _, _, _ in
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
        let syncer = CodexAppServerRegistryRuntimeSyncer(eventHub: hub, attachHandler: { _, _, _, _, _, _, _ in
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

        guard case .alreadyResolved(let event) = try syncer.submitApproval(promptID: "prompt-shared",
                                                                           targetIndex: 0,
                                                                           clientRequestID: nil,
                                                                           lifecycleToken: nil) else {
            return XCTFail("expected alreadyResolved")
        }

        XCTAssertEqual(event.sessionID, "instance-b")
        XCTAssertTrue(firstRuntime.submitAttempts.isEmpty || firstRuntime.submitAttempts == ["prompt-shared"])
        XCTAssertEqual(secondRuntime.submitAttempts, ["prompt-shared"])
    }

    func testSyncReattachesWhenExistingSessionTransportDied() {
        let hub = AgentEventHub()
        var runtimes = [FakeRuntimeSession]()
        let syncer = CodexAppServerRegistryRuntimeSyncer(eventHub: hub, attachHandler: { _, _, _, _, _, _, _ in
            let runtime = FakeRuntimeSession()
            runtimes.append(runtime)
            return runtime
        })
        let record = Self.record(sessionID: "app", runtime: "codex_app_server", socketPath: "/tmp/app.sock")

        syncer.sync(records: [record])
        XCTAssertEqual(runtimes.count, 1)

        // The registry record is unchanged (same app-server process/epoch)
        // but the session's transport died: the next scan must re-attach
        // instead of reusing the dead session forever.
        runtimes[0].stopped = true
        syncer.sync(records: [record])

        XCTAssertEqual(runtimes.count, 2)
        XCTAssertFalse(runtimes[1].stopped)
    }

    func testSyncEnsuresThreadSubscriptionForReusedRuntime() {
        let hub = AgentEventHub()
        let runtime = FakeRuntimeSession()
        let syncer = CodexAppServerRegistryRuntimeSyncer(eventHub: hub, attachHandler: { _, _, _, _, _, _, _ in
            runtime
        })
        let record = Self.record(sessionID: "app", runtime: "codex_app_server", socketPath: "/tmp/app.sock")

        syncer.sync(records: [record])
        syncer.sync(records: [record])

        XCTAssertEqual(runtime.ensureThreadSubscriptionCallCount, 1)
        XCTAssertFalse(runtime.stopped)
    }

    func testSyncRefreshesReusedRuntimeActiveThreadWithThrottle() {
        let hub = AgentEventHub()
        let runtime = FakeRuntimeSession()
        var now = Date(timeIntervalSince1970: 100)
        let syncer = CodexAppServerRegistryRuntimeSyncer(eventHub: hub,
                                                        dateProvider: { now },
                                                        activeThreadRefreshInterval: 2,
                                                        attachHandler: { _, _, _, _, _, _, _ in
            runtime
        })
        let record = Self.record(sessionID: "app", runtime: "codex_app_server", socketPath: "/tmp/app.sock")

        syncer.sync(records: [record])
        XCTAssertEqual(runtime.ensureThreadSubscriptionCallCount, 0)
        XCTAssertEqual(runtime.refreshActiveThreadCallCount, 0)

        syncer.sync(records: [record])
        XCTAssertEqual(runtime.ensureThreadSubscriptionCallCount, 1)
        XCTAssertEqual(runtime.refreshActiveThreadCallCount, 0)

        now = now.addingTimeInterval(2.1)
        syncer.sync(records: [record])
        XCTAssertEqual(runtime.ensureThreadSubscriptionCallCount, 2)
        XCTAssertEqual(runtime.refreshActiveThreadCallCount, 1)

        syncer.sync(records: [record])
        XCTAssertEqual(runtime.ensureThreadSubscriptionCallCount, 3)
        XCTAssertEqual(runtime.refreshActiveThreadCallCount, 1)
    }

    func testActiveThreadHandlerReportsOwningRuntimeSession() {
        let hub = AgentEventHub()
        var capturedActiveThreadHandler: CodexAppServerHeadlessRuntime.ThreadIDHandler?
        var reported: [(sessionID: String, threadID: String)] = []
        let syncer = CodexAppServerRegistryRuntimeSyncer(eventHub: hub, attachHandler: { _, _, _, _, _, _, onActiveThreadID in
            capturedActiveThreadHandler = onActiveThreadID
            return FakeRuntimeSession()
        })
        syncer.activeThreadHandler = { sessionID, threadID in
            reported.append((sessionID, threadID))
        }

        syncer.sync(records: [
            Self.record(sessionID: "instance-session",
                        runtime: "codex_app_server",
                        socketPath: "/tmp/app.sock",
                        threadID: "thread-old"),
        ])
        capturedActiveThreadHandler?("thread-current")

        XCTAssertEqual(reported.map(\.sessionID), ["instance-session"])
        XCTAssertEqual(reported.map(\.threadID), ["thread-current"])
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
                                                        attachHandler: { _, _, _, onAgentEvent, _, _, _ in
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
        let syncer = CodexAppServerRegistryRuntimeSyncer(eventHub: hub, attachHandler: { _, _, _, _, onInteractivePrompt, _, _ in
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
                "startedAtMs": .number(1_786_000_000_000),
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

    func testAttachedRuntimeSendsSidebarNotificationForApprovalPromptAndDedupesReplay() throws {
        let hub = AgentEventHub()
        var capturedPromptHandler: CodexAppServerConnection.InteractivePromptHandler?
        let sidebarLock = NSLock()
        var sidebarMessages = [String]()
        let syncer = CodexAppServerRegistryRuntimeSyncer(eventHub: hub,
                                                        sidebarMessageSender: { message in
                                                            sidebarLock.lock()
                                                            sidebarMessages.append(message)
                                                            sidebarLock.unlock()
                                                        },
                                                        attachHandler: { _, _, _, _, onInteractivePrompt, _, _ in
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
                "startedAtMs": .number(1_786_000_000_000),
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
                                       selectedIndex: 0,
                                       submitChannel: InteractivePromptSubmitChannel.codexAppServer)
        let event = Self.interactivePromptEvent(sessionID: "app", promptID: prompt.promptID)
        let envelope = CodexAppServerInteractivePromptEnvelope(request: request,
                                                              prompt: prompt,
                                                              event: event)

        onInteractivePrompt(envelope)
        onInteractivePrompt(envelope)

        XCTAssertTrue(Self.waitUntil {
            sidebarLock.lock()
            defer { sidebarLock.unlock() }
            return sidebarMessages.count == 2
        })
        sidebarLock.lock()
        let messages = sidebarMessages
        sidebarLock.unlock()
        XCTAssertTrue(messages[0].contains(#""action":"notification.create""#))
        XCTAssertTrue(messages[0].contains(#""title":"Codex""#))
        XCTAssertTrue(messages[0].contains(#""body":"Approve Codex command?""#))
        XCTAssertEqual(messages[1], "report_shell_state needs_input --workspace_id=workspace-1")
    }

    func testApprovalPromptResolvedClearsSidebarPromptStateAndAllowsFutureNotification() throws {
        let hub = AgentEventHub()
        var capturedPromptHandler: CodexAppServerConnection.InteractivePromptHandler?
        var capturedResolvedHandler: CodexAppServerConnection.InteractivePromptResolvedHandler?
        let sidebarLock = NSLock()
        var sidebarMessages = [String]()
        let syncer = CodexAppServerRegistryRuntimeSyncer(eventHub: hub,
                                                        sidebarMessageSender: { message in
                                                            sidebarLock.lock()
                                                            sidebarMessages.append(message)
                                                            sidebarLock.unlock()
                                                        },
                                                        attachHandler: { _, _, _, _, onInteractivePrompt, onInteractivePromptResolved, _ in
            capturedPromptHandler = onInteractivePrompt
            capturedResolvedHandler = onInteractivePromptResolved
            return FakeRuntimeSession()
        })

        syncer.sync(records: [
            Self.record(sessionID: "app", runtime: "codex_app_server", socketPath: "/tmp/app.sock"),
        ])
        let onInteractivePrompt = try XCTUnwrap(capturedPromptHandler)
        let onInteractivePromptResolved = try XCTUnwrap(capturedResolvedHandler)
        let request = try XCTUnwrap(CodexAppServerApprovalRequest(
            method: "item/commandExecution/requestApproval",
            requestID: .string("approval-1"),
            params: [
                "threadId": .string("thread-1"),
                "turnId": .string("turn-1"),
                "itemId": .string("item-1"),
                "startedAtMs": .number(1_786_000_000_000),
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
                                       ],
                                       selectedIndex: 0,
                                       submitChannel: InteractivePromptSubmitChannel.codexAppServer)
        var promptMetadata = Self.interactivePromptEvent(sessionID: "app", promptID: prompt.promptID).metadata ?? [:]
        promptMetadata["lifecycle_token"] = "token-1"
        let event = Self.interactivePromptEvent(sessionID: "app", promptID: prompt.promptID).withMetadataForTesting(promptMetadata)
        let envelope = CodexAppServerInteractivePromptEnvelope(request: request,
                                                              prompt: prompt,
                                                              event: event)
        var resolvedMetadata = Self.event(sessionID: "app", promptID: prompt.promptID).metadata ?? [:]
        resolvedMetadata["lifecycle_token"] = "token-1"
        let resolvedEvent = Self.event(sessionID: "app", promptID: prompt.promptID).withMetadataForTesting(resolvedMetadata)

        onInteractivePrompt(envelope)
        onInteractivePromptResolved(resolvedEvent)
        onInteractivePrompt(envelope)

        XCTAssertTrue(Self.waitUntil {
            sidebarLock.lock()
            defer { sidebarLock.unlock() }
            return sidebarMessages.count == 5
        })
        sidebarLock.lock()
        let messages = sidebarMessages
        sidebarLock.unlock()
        XCTAssertTrue(messages[0].contains(#""action":"notification.create""#))
        XCTAssertEqual(messages[1], "report_shell_state needs_input --workspace_id=workspace-1")
        XCTAssertEqual(messages[2], "report_shell_state running --workspace_id=workspace-1")
        XCTAssertTrue(messages[3].contains(#""action":"notification.create""#))
        XCTAssertEqual(messages[4], "report_shell_state needs_input --workspace_id=workspace-1")
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
        let syncer = CodexAppServerRegistryRuntimeSyncer(eventHub: hub, attachHandler: { _, _, _, _, _, _, _ in
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
                       ["prompt-prompt-first-1", "prompt-prompt-second-1"])
        XCTAssertEqual(syncer.pendingApprovalPromptEvents(workspaceID: "workspace-1", sessionID: "second").map(\.eventID),
                       ["prompt-prompt-second-1"])
        XCTAssertTrue(syncer.pendingApprovalPromptEvents(workspaceID: "workspace-1", sessionID: "stale-session").isEmpty)
        XCTAssertTrue(syncer.pendingApprovalPromptEvents(workspaceID: "other-workspace", sessionID: nil).isEmpty)
    }

    private static func record(sessionID: String,
                               runtime: String?,
                               socketPath: String?,
                               panelID: String = "panel-1",
                               workspaceID: String = "workspace-1",
                               threadID: String? = nil) -> AgentSessionRegistryRecord {
        AgentSessionRegistryRecord(version: 1,
                                   vendor: "codex",
                                   workspaceID: workspaceID,
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

    private static func event(sessionID: String,
                              promptID: String,
                              seq: Int = 1,
                              lifecycleToken: String? = nil) -> AgentEvent {
        var metadata = [
            "panel_id": "panel-1",
            "prompt_id": promptID,
            "source": "codex_command_approval",
        ]
        if let lifecycleToken {
            metadata["lifecycle_token"] = lifecycleToken
        }
        return AgentEvent(eventID: "resolved-\(promptID)-\(seq)",
                          seq: seq,
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
                          metadata: metadata)
    }

    private static func interactivePromptEvent(sessionID: String,
                                               promptID: String,
                                               seq: Int = 1,
                                               includePayload: Bool = false) -> AgentEvent {
        AgentEvent(eventID: "prompt-\(promptID)-\(seq)",
                   seq: seq,
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
                   ],
                   payload: includePayload ? .object([
                    "prompt_id": .string(promptID),
                    "vendor": .string("codex"),
                    "source": .string("codex_command_approval"),
                    "title": .string("Approve Codex command?"),
                    "body": .string("Command: ls"),
                    "options": .array([
                        .object([
                            "index": .number(0),
                            "label": .string("Yes, proceed (y)"),
                            "input_sequence": .string("accept"),
                        ]),
                    ]),
                    "selected_index": .number(0),
                    "submit_channel": .string("codex_app_server"),
                   ]) : nil)
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
                                       payloadKind: String,
                                       workspaceID: String = "workspace-1") -> AgentEvent {
        AgentEvent(eventID: eventID,
                   seq: seq,
                   vendor: "codex",
                   workspaceID: workspaceID,
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

private final class LockedBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Bool
    init(_ value: Bool) { stored = value }
    func set(_ value: Bool) { lock.lock(); stored = value; lock.unlock() }
    func value() -> Bool { lock.lock(); defer { lock.unlock() }; return stored }
}

private extension AgentEvent {
    func withMetadataForTesting(_ metadata: [String: String]) -> AgentEvent {
        AgentEvent(eventID: eventID,
                   seq: seq,
                   vendor: vendor,
                   workspaceID: workspaceID,
                   sessionID: sessionID,
                   timestamp: timestamp,
                   type: type,
                   role: role,
                   text: text,
                   name: name,
                   input: input,
                   output: output,
                   toolCallID: toolCallID,
                   metadata: metadata,
                   payload: payload)
    }
}

private final class FakeRuntimeSession: CodexAppServerRuntimeSessionControlling {
    var stopped = false
    var canSubmit = true
    var ensureThreadSubscriptionCallCount = 0
    var refreshActiveThreadCallCount = 0
    var submitAttempts = [String]()
    var submittedMessages = [String]()
    var resolvedEventsByPromptID = [String: AgentEvent]()
    var pendingConfirmationPromptIDs = Set<String>()
    var pendingPromptEvents = [AgentEvent]()

    func canSubmitMessage() -> Bool {
        canSubmit
    }

    func ensureThreadSubscription() {
        ensureThreadSubscriptionCallCount += 1
    }

    var registryRootThreadIDs = [String?]()

    func setRegistryRootThreadID(_ rawThreadID: String?) {
        registryRootThreadIDs.append(rawThreadID)
    }

    func isStopped() -> Bool {
        stopped
    }

    func refreshActiveThread() {
        refreshActiveThreadCallCount += 1
    }

    func pendingApprovalPromptEvents() -> [AgentEvent] {
        pendingPromptEvents
    }

    var submitEntered: DispatchSemaphore?
    var submitBarrier: DispatchSemaphore?
    var submitError: Error?

    var submittedLifecycleTokens = [String?]()

    func submitApproval(promptID: String,
                        targetIndex: Int,
                        clientRequestID: String?,
                        lifecycleToken: String?) throws -> CodexAppServerApprovalSubmitOutcome {
        submitAttempts.append(promptID)
        submittedLifecycleTokens.append(lifecycleToken)
        submitEntered?.signal()
        _ = submitBarrier?.wait(timeout: .now() + 2.0)
        if let submitError {
            throw submitError
        }
        if pendingConfirmationPromptIDs.contains(promptID) {
            return .pendingConfirmation(promptID: promptID)
        }
        guard let event = resolvedEventsByPromptID[promptID] else {
            throw BridgeInternalError.notFound("Unknown Codex approval prompt.")
        }
        return .alreadyResolved(event)
    }

    func submitMessage(text: String, clientRequestID: String?) throws {
        submittedMessages.append(text)
    }

    var onStop: (() -> Void)?

    func stop() {
        stopped = true
        onStop?()
    }
}
