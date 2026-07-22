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

    func testAttachForwardsAuthoritativeRegistryRootIdentity() {
        let runtime = FakeRuntimeSession()
        let syncer = CodexAppServerRegistryRuntimeSyncer(eventHub: AgentEventHub(), attachHandler: { _, _, _, _, _, _, _ in
            runtime
        })

        syncer.sync(records: [
            Self.record(sessionID: "app",
                        runtime: "codex_app_server",
                        socketPath: "/tmp/app.sock",
                        threadID: "  thread-root  "),
        ])

        XCTAssertEqual(runtime.registryRootThreadIDs, ["thread-root"])
        XCTAssertEqual(CodexAppServerRegistryRuntimeSyncer.registryRootThreadID(
            from: Self.record(sessionID: "fallback",
                              runtime: "codex_app_server",
                              socketPath: "/tmp/fallback.sock",
                              threadID: "  ",
                              resumeThreadID: "resume-root")), "resume-root")
        XCTAssertNil(CodexAppServerRegistryRuntimeSyncer.registryRootThreadID(
            from: Self.record(sessionID: "blank",
                              runtime: "codex_app_server",
                              socketPath: "/tmp/blank.sock",
                              threadID: "\n",
                              resumeThreadID: "  ")))
    }

    func testRegistryRootChangeReplacesRuntimeGeneration() {
        var runtimes = [FakeRuntimeSession]()
        let syncer = CodexAppServerRegistryRuntimeSyncer(eventHub: AgentEventHub(), attachHandler: { _, _, _, _, _, _, _ in
            let runtime = FakeRuntimeSession()
            runtimes.append(runtime)
            return runtime
        })

        syncer.sync(records: [Self.record(sessionID: "app", runtime: "codex_app_server",
                                          socketPath: "/tmp/app.sock", threadID: "thread-a")])
        syncer.sync(records: [Self.record(sessionID: "app", runtime: "codex_app_server",
                                          socketPath: "/tmp/app.sock", threadID: "thread-b")])

        XCTAssertEqual(runtimes.count, 2)
        XCTAssertTrue(runtimes[0].stopped)
        XCTAssertEqual(runtimes[0].registryRootThreadIDs, ["thread-a"])
        XCTAssertEqual(runtimes[1].registryRootThreadIDs, ["thread-b"])
    }

    func testEffectiveRegistryRootSurvivesBlankRecordRoundTrip() {
        var runtimes = [FakeRuntimeSession]()
        let syncer = CodexAppServerRegistryRuntimeSyncer(eventHub: AgentEventHub(), attachHandler: { _, _, _, _, _, _, _ in
            let runtime = FakeRuntimeSession()
            runtimes.append(runtime)
            return runtime
        })

        for threadID in ["thread-a", nil, "thread-a"] as [String?] {
            syncer.sync(records: [Self.record(sessionID: "app", runtime: "codex_app_server",
                                              socketPath: "/tmp/app.sock", threadID: threadID)])
        }
        XCTAssertEqual(runtimes.count, 1, "A -> blank -> A reuses the last-known-good generation")

        syncer.sync(records: [Self.record(sessionID: "app", runtime: "codex_app_server",
                                          socketPath: "/tmp/app.sock", threadID: nil)])
        syncer.sync(records: [Self.record(sessionID: "app", runtime: "codex_app_server",
                                          socketPath: "/tmp/app.sock", threadID: "thread-b")])
        XCTAssertEqual(runtimes.count, 2, "A -> blank -> B replaces exactly once")
        XCTAssertTrue(runtimes[0].stopped)
        XCTAssertEqual(runtimes[1].registryRootThreadIDs, ["thread-b"])
    }

    func testSyncReattachesStoppedRuntimeWithUnchangedRegistryRecord() {
        var runtimes = [FakeRuntimeSession]()
        let syncer = CodexAppServerRegistryRuntimeSyncer(eventHub: AgentEventHub(), attachHandler: { _, _, _, _, _, _, _ in
            let runtime = FakeRuntimeSession()
            runtimes.append(runtime)
            return runtime
        })
        let record = Self.record(sessionID: "app", runtime: "codex_app_server", socketPath: "/tmp/app.sock")

        syncer.sync(records: [record])
        runtimes[0].stopped = true
        syncer.sync(records: [record])

        guard runtimes.count == 2 else {
            return XCTFail("expected the stopped runtime to be replaced, got \(runtimes.count) runtime(s)")
        }
        XCTAssertFalse(runtimes[1].stopped)
    }

    func testAttachFailureDiscardsStagedCallbackSideEffects() throws {
        let hub = AgentEventHub()
        let sidebarQueue = DispatchQueue(label: "test.codex.attach-failure.sidebar")
        let sidebarLock = NSLock()
        var sidebarMessages = [String]()
        var threadIDs = [String]()
        let envelope = Self.approvalEnvelope(sessionID: "app", requestID: "approval-failed")
        let syncer = CodexAppServerRegistryRuntimeSyncer(
            eventHub: hub,
            sidebarMessageSender: { message in
                sidebarLock.lock()
                sidebarMessages.append(message)
                sidebarLock.unlock()
            },
            sidebarQueue: sidebarQueue,
            attachHandler: { _, _, _, onAgentEvent, onInteractivePrompt, onInteractivePromptResolved, onActiveThreadID in
                onAgentEvent(Self.appServerEvent(eventID: "turn-failed-attach",
                                                 seq: 1,
                                                 sessionID: "app",
                                                 type: .thinking,
                                                 text: "starting",
                                                 payloadKind: "turn_started"))
                onInteractivePrompt(envelope)
                onInteractivePromptResolved(Self.event(sessionID: "app", promptID: envelope.prompt.promptID))
                onActiveThreadID("thread-failed-attach")
                throw BridgeInternalError.invalidRequest("attach failed after callbacks")
            })
        syncer.activeThreadHandler = { _, threadID in threadIDs.append(threadID) }

        syncer.sync(records: [
            Self.record(sessionID: "app", runtime: "codex_app_server", socketPath: "/tmp/app.sock"),
        ])
        sidebarQueue.sync {}

        XCTAssertTrue(hub.fetch(workspaceID: "workspace-1", sessionID: "app", limit: 10).events.isEmpty)
        XCTAssertTrue(threadIDs.isEmpty)
        sidebarLock.lock()
        let deliveredSidebarMessages = sidebarMessages
        sidebarLock.unlock()
        XCTAssertTrue(deliveredSidebarMessages.isEmpty)
    }

    func testAttachSuccessCommitsStagedCallbacksInFIFOOrder() throws {
        let hub = AgentEventHub()
        let orderLock = NSLock()
        var deliveryOrder = [String]()
        let (subscriptionID, _) = hub.subscribe(workspaceID: "workspace-1", sessionID: "app") { envelope in
            orderLock.lock()
            deliveryOrder.append(envelope.event.eventID)
            orderLock.unlock()
        }
        defer { hub.unsubscribe(subscriptionID) }
        let first = Self.approvalEnvelope(sessionID: "app", requestID: "approval-A")
        let second = Self.approvalEnvelope(sessionID: "app", requestID: "approval-B")
        let syncer = CodexAppServerRegistryRuntimeSyncer(eventHub: hub, attachHandler: { _, _, _, _, onInteractivePrompt, _, onActiveThreadID in
            onInteractivePrompt(first)
            onActiveThreadID("thread-between")
            onInteractivePrompt(second)
            return FakeRuntimeSession()
        })
        syncer.activeThreadHandler = { _, threadID in
            orderLock.lock()
            deliveryOrder.append(threadID)
            orderLock.unlock()
        }

        syncer.sync(records: [
            Self.record(sessionID: "app", runtime: "codex_app_server", socketPath: "/tmp/app.sock"),
        ])

        orderLock.lock()
        let observed = deliveryOrder
        orderLock.unlock()
        XCTAssertEqual(observed, [first.event.eventID, "thread-between", second.event.eventID])
    }

    func testAttachStageCommitDrainPreservesFIFOForMidDrainArrival() {
        let stage = CodexAppServerAttachStage()
        let orderLock = NSLock()
        var order = [String]()
        let record: (String) -> Void = { value in
            orderLock.lock()
            order.append(value)
            orderLock.unlock()
        }
        stage.run { record("A") }
        stage.run { record("B") }
        orderLock.lock()
        let beforeCommit = order
        orderLock.unlock()
        XCTAssertTrue(beforeCommit.isEmpty, "attach callbacks must remain staged before commit")

        let firstDrainEntered = DispatchSemaphore(value: 0)
        let releaseFirstDrain = DispatchSemaphore(value: 0)
        var paused = false
        stage.commitDrainHook = {
            guard paused == false else { return }
            paused = true
            firstDrainEntered.signal()
            _ = releaseFirstDrain.wait(timeout: .now() + 5)
        }
        let commitDone = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            stage.commit()
            commitDone.signal()
        }
        XCTAssertEqual(firstDrainEntered.wait(timeout: .now() + 2), .success)

        let cSubmitted = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            stage.run { record("C") }
            cSubmitted.signal()
        }
        XCTAssertEqual(cSubmitted.wait(timeout: .now() + 2), .success)
        releaseFirstDrain.signal()
        XCTAssertEqual(commitDone.wait(timeout: .now() + 2), .success)

        orderLock.lock()
        let observed = order
        orderLock.unlock()
        XCTAssertEqual(observed, ["A", "B", "C"])
    }

    func testRetiredCallbacksAreDroppedAtExecutionTime() throws {
        let hub = AgentEventHub()
        let sidebarQueue = DispatchQueue(label: "test.codex.retired-callback.sidebar")
        let releaseSidebar = DispatchSemaphore(value: 0)
        sidebarQueue.async { releaseSidebar.wait() }
        let sidebarLock = NSLock()
        var sidebarMessages = [String]()
        var agentHandlers = [CodexAppServerHeadlessRuntime.AgentEventHandler]()
        var promptHandlers = [CodexAppServerConnection.InteractivePromptHandler]()
        var threadHandlers = [CodexAppServerHeadlessRuntime.ThreadIDHandler]()
        var forwardedThreadIDs = [String]()
        let syncer = CodexAppServerRegistryRuntimeSyncer(
            eventHub: hub,
            sidebarMessageSender: { message in
                sidebarLock.lock()
                sidebarMessages.append(message)
                sidebarLock.unlock()
            },
            sidebarQueue: sidebarQueue,
            attachHandler: { _, _, _, onAgentEvent, onInteractivePrompt, _, onActiveThreadID in
                agentHandlers.append(onAgentEvent)
                promptHandlers.append(onInteractivePrompt)
                threadHandlers.append(onActiveThreadID)
                return FakeRuntimeSession()
            })
        syncer.activeThreadHandler = { _, threadID in forwardedThreadIDs.append(threadID) }

        syncer.sync(records: [
            Self.record(sessionID: "app", runtime: "codex_app_server", socketPath: "/tmp/app-1.sock"),
        ])
        agentHandlers[0](Self.appServerEvent(eventID: "old-turn",
                                             seq: 1,
                                             sessionID: "app",
                                             type: .thinking,
                                             text: "old",
                                             payloadKind: "turn_started"))
        syncer.sync(records: [
            Self.record(sessionID: "app", runtime: "codex_app_server", socketPath: "/tmp/app-2.sock"),
        ])
        promptHandlers[0](Self.approvalEnvelope(sessionID: "app", requestID: "approval-old"))
        threadHandlers[0]("thread-old")

        releaseSidebar.signal()
        sidebarQueue.sync {}
        sidebarLock.lock()
        let deliveredSidebarMessages = sidebarMessages
        sidebarLock.unlock()
        XCTAssertTrue(deliveredSidebarMessages.isEmpty,
                      "queued work from the retired generation must be dropped")
        XCTAssertTrue(hub.fetch(workspaceID: "workspace-1", sessionID: "app", limit: 10).events.isEmpty)
        XCTAssertTrue(forwardedThreadIDs.isEmpty)

        let newEnvelope = Self.approvalEnvelope(sessionID: "app", requestID: "approval-new")
        promptHandlers[1](newEnvelope)
        threadHandlers[1]("thread-new")
        XCTAssertEqual(hub.fetch(workspaceID: "workspace-1", sessionID: "app", limit: 10).events.map(\.eventID),
                       [newEnvelope.event.eventID])
        XCTAssertEqual(forwardedThreadIDs, ["thread-new"])
    }

    func testCallbackRechecksGenerationBeforePublishing() throws {
        let hub = AgentEventHub()
        var promptHandlers = [CodexAppServerConnection.InteractivePromptHandler]()
        let syncer = CodexAppServerRegistryRuntimeSyncer(eventHub: hub, attachHandler: { _, _, _, _, onInteractivePrompt, _, _ in
            promptHandlers.append(onInteractivePrompt)
            return FakeRuntimeSession()
        })
        syncer.sync(records: [
            Self.record(sessionID: "app", runtime: "codex_app_server", socketPath: "/tmp/app-1.sock"),
        ])

        syncer.generationRecheckHook = { [weak syncer] in
            syncer?.generationRecheckHook = nil
            syncer?.sync(records: [
                Self.record(sessionID: "app", runtime: "codex_app_server", socketPath: "/tmp/app-2.sock"),
            ])
        }
        promptHandlers[0](Self.approvalEnvelope(sessionID: "app", requestID: "approval-stale"))

        XCTAssertEqual(promptHandlers.count, 2)
        XCTAssertTrue(hub.fetch(workspaceID: "workspace-1", sessionID: "app", limit: 10).events.isEmpty,
                      "a callback that loses the generation race must not publish")
    }

    func testRetiringGenerationResolvedCleanupReachesHubAndSidebar() throws {
        let hub = AgentEventHub()
        let sidebarQueue = DispatchQueue(label: "test.codex.retiring-cleanup.sidebar")
        let sidebarLock = NSLock()
        var sidebarMessages = [String]()
        let runtime = FakeRuntimeSession()
        var promptHandler: CodexAppServerConnection.InteractivePromptHandler?
        var resolvedHandler: CodexAppServerConnection.InteractivePromptResolvedHandler?
        let syncer = CodexAppServerRegistryRuntimeSyncer(
            eventHub: hub,
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
        let envelope = Self.approvalEnvelope(sessionID: "app", requestID: "approval-retiring")
        try XCTUnwrap(promptHandler)(envelope)
        sidebarQueue.sync {}
        runtime.onStop = {
            resolvedHandler?(Self.event(sessionID: "app",
                                        promptID: envelope.prompt.promptID,
                                        lifecycleToken: envelope.event.eventID))
        }

        syncer.sync(records: [])
        sidebarQueue.sync {}

        XCTAssertEqual(hub.fetch(workspaceID: "workspace-1", sessionID: "app", limit: 10).events.map(\.type),
                       [.interactivePrompt, .interactivePromptResolved])
        sidebarLock.lock()
        let deliveredSidebarMessages = sidebarMessages
        sidebarLock.unlock()
        XCTAssertEqual(deliveredSidebarMessages.last,
                       "report_shell_state running --workspace_id=workspace-1")
    }

    func testConcurrentSyncPassesKeepNewestGeneration() throws {
        let runtimeA = FakeRuntimeSession()
        let runtimeB = FakeRuntimeSession()
        let firstAttachEntered = DispatchSemaphore(value: 0)
        let releaseFirstAttach = DispatchSemaphore(value: 0)
        let secondAttachEntered = DispatchSemaphore(value: 0)
        let attachLock = NSLock()
        var attachCount = 0
        let syncer = CodexAppServerRegistryRuntimeSyncer(eventHub: AgentEventHub(), attachHandler: { _, _, _, _, _, _, _ in
            attachLock.lock()
            attachCount += 1
            let currentAttach = attachCount
            attachLock.unlock()
            if currentAttach == 1 {
                firstAttachEntered.signal()
                _ = releaseFirstAttach.wait(timeout: .now() + 5)
                return runtimeA
            }
            secondAttachEntered.signal()
            return runtimeB
        })

        let firstSyncDone = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            syncer.sync(records: [
                Self.record(sessionID: "app", runtime: "codex_app_server", socketPath: "/tmp/app-1.sock"),
            ])
            firstSyncDone.signal()
        }
        XCTAssertEqual(firstAttachEntered.wait(timeout: .now() + 2), .success)

        let secondSyncArrived = DispatchSemaphore(value: 0)
        syncer.syncArrivalHook = { records in
            if records.first?.appServerSocket == "/tmp/app-2.sock" {
                secondSyncArrived.signal()
            }
        }
        let secondSyncDone = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            syncer.sync(records: [
                Self.record(sessionID: "app", runtime: "codex_app_server", socketPath: "/tmp/app-2.sock"),
            ])
            secondSyncDone.signal()
        }
        XCTAssertEqual(secondSyncArrived.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(secondAttachEntered.wait(timeout: .now() + 0.2), .timedOut,
                       "the second sync must wait outside attach until the first pass completes")

        releaseFirstAttach.signal()
        XCTAssertEqual(firstSyncDone.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(secondSyncDone.wait(timeout: .now() + 2), .success)
        XCTAssertTrue(runtimeA.stopped)
        XCTAssertFalse(runtimeB.stopped)

        try syncer.submitMessage(sessionID: "app", text: "newest")
        XCTAssertTrue(runtimeA.submittedMessages.isEmpty)
        XCTAssertEqual(runtimeB.submittedMessages, ["newest"])
    }

    func testSubmitInsideReplacementGapWaitsAndReconciles() throws {
        let newRuntime = FakeRuntimeSession()
        let resolved = Self.event(sessionID: "app", promptID: "prompt-gap")
        newRuntime.resolvedEventsByPromptID["prompt-gap"] = resolved
        let gap = makeReplacementEntryGap(newRuntime: newRuntime)
        XCTAssertEqual(gap.attachEntered.wait(timeout: .now() + 2), .success)

        let waitEntered = DispatchSemaphore(value: 0)
        gap.syncer.transitionWaitHook = { _ in waitEntered.signal() }
        var result: AgentEvent?
        var submitError: Error?
        let submitDone = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                result = try gap.syncer.submitApproval(promptID: "prompt-gap",
                                                       targetIndex: 0,
                                                       workspaceID: "workspace-1",
                                                       panelID: "panel-1",
                                                       sessionID: "app")
            } catch {
                submitError = error
            }
            submitDone.signal()
        }
        XCTAssertEqual(waitEntered.wait(timeout: .now() + 2), .success,
                       "a submit in the entry gap must wait for the transition signal")

        gap.releaseAttach.signal()
        XCTAssertEqual(gap.syncDone.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(submitDone.wait(timeout: .now() + 2), .success)
        XCTAssertNil(submitError)
        XCTAssertEqual(result?.eventID, resolved.eventID)
        XCTAssertEqual(newRuntime.submitAttempts, ["prompt-gap"])
    }

    func testStaleSubmitSuccessReconcilesAgainstReplacementGeneration() throws {
        let oldRuntime = FakeRuntimeSession()
        let newRuntime = FakeRuntimeSession()
        let oldResolved = Self.event(sessionID: "app", promptID: "prompt-old")
        let newResolved = Self.event(sessionID: "app", promptID: "prompt-new")
        oldRuntime.resolvedEventsByPromptID["prompt-race"] = oldResolved
        newRuntime.resolvedEventsByPromptID["prompt-race"] = newResolved
        oldRuntime.submitEntered = DispatchSemaphore(value: 0)
        oldRuntime.submitBarrier = DispatchSemaphore(value: 0)
        var attachCount = 0
        let syncer = CodexAppServerRegistryRuntimeSyncer(eventHub: AgentEventHub(), attachHandler: { _, _, _, _, _, _, _ in
            defer { attachCount += 1 }
            return attachCount == 0 ? oldRuntime : newRuntime
        })
        syncer.sync(records: [
            Self.record(sessionID: "app", runtime: "codex_app_server", socketPath: "/tmp/app-1.sock"),
        ])

        var result: AgentEvent?
        var submitError: Error?
        let submitDone = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                result = try syncer.submitApproval(promptID: "prompt-race",
                                                   targetIndex: 0,
                                                   workspaceID: "workspace-1",
                                                   panelID: "panel-1",
                                                   sessionID: "app")
            } catch {
                submitError = error
            }
            submitDone.signal()
        }
        XCTAssertEqual(oldRuntime.submitEntered?.wait(timeout: .now() + 2), .success)

        syncer.sync(records: [
            Self.record(sessionID: "app", runtime: "codex_app_server", socketPath: "/tmp/app-2.sock"),
        ])
        oldRuntime.submitBarrier?.signal()
        XCTAssertEqual(submitDone.wait(timeout: .now() + 2), .success)

        XCTAssertNil(submitError)
        XCTAssertEqual(result?.eventID, newResolved.eventID,
                       "the retired generation's success must not mask the current generation")
        XCTAssertEqual(newRuntime.submitAttempts, ["prompt-race"])
    }

    func testReplacementGapTimeoutFailsClosed() throws {
        let newRuntime = FakeRuntimeSession()
        let gap = makeReplacementEntryGap(newRuntime: newRuntime, transitionWaitTimeout: 0.1)
        XCTAssertEqual(gap.attachEntered.wait(timeout: .now() + 2), .success)

        var result: AgentEvent?
        var submitError: Error?
        let submitDone = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                result = try gap.syncer.submitApproval(promptID: "prompt-timeout",
                                                       targetIndex: 0,
                                                       workspaceID: "workspace-1",
                                                       panelID: "panel-1",
                                                       sessionID: "app")
            } catch {
                submitError = error
            }
            submitDone.signal()
        }
        XCTAssertEqual(submitDone.wait(timeout: .now() + 2), .success)
        XCTAssertNil(result)
        guard case BridgeInternalError.conflict? = submitError else {
            gap.releaseAttach.signal()
            _ = gap.syncDone.wait(timeout: .now() + 2)
            return XCTFail("expected transition conflict, got \(String(describing: submitError))")
        }

        gap.releaseAttach.signal()
        XCTAssertEqual(gap.syncDone.wait(timeout: .now() + 2), .success)
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

        let event = try syncer.submitApproval(promptID: "prompt-2", targetIndex: 1)

        XCTAssertEqual(event.eventID, resolved.eventID)
        XCTAssertEqual(secondRuntime.submitAttempts, ["prompt-2"])
    }

    func testContextualSubmitReturnsAlreadyResolvedWhenMatchingSessionNoLongerHasPrompt() throws {
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

        let event = try syncer.submitApproval(promptID: "prompt-other",
                                              targetIndex: 0,
                                              workspaceID: "workspace-1",
                                              panelID: "panel-first",
                                              sessionID: "first")

        XCTAssertEqual(event.type, .interactivePromptResolved)
        XCTAssertEqual(event.sessionID, "first")
        XCTAssertEqual(event.metadata?["prompt_id"], "prompt-other")
        XCTAssertEqual(event.metadata?["reason"], "already_resolved")
        XCTAssertEqual(firstRuntime.submitAttempts, ["prompt-other"])
        XCTAssertTrue(secondRuntime.submitAttempts.isEmpty)
    }

    func testContextualSubmitDoesNotScanOtherRuntimesWhenSessionIsUnknown() throws {
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

        let event = try syncer.submitApproval(promptID: "prompt-other",
                                              targetIndex: 0,
                                              workspaceID: "workspace-1",
                                              panelID: "panel-missing",
                                              sessionID: "missing")

        XCTAssertEqual(event.sessionID, "missing")
        XCTAssertEqual(event.metadata?["reason"], "already_resolved")
        XCTAssertTrue(runtime.submitAttempts.isEmpty)
    }

    func testContextualSubmitReusesExistingResolvedEventWhenPromptWasAlreadyResolved() throws {
        let hub = AgentEventHub()
        let runtime = FakeRuntimeSession()
        let resolved = Self.event(sessionID: "first", promptID: "prompt-done")
        hub.publish(resolved)
        let syncer = CodexAppServerRegistryRuntimeSyncer(eventHub: hub, attachHandler: { _, _, _, _, _, _, _ in
            runtime
        })

        syncer.sync(records: [
            Self.record(sessionID: "first", runtime: "codex_app_server", socketPath: "/tmp/first.sock"),
        ])

        let event = try syncer.submitApproval(promptID: "prompt-done",
                                              targetIndex: 0,
                                              workspaceID: "workspace-1",
                                              panelID: "panel-first",
                                              sessionID: "first")

        XCTAssertEqual(event.eventID, resolved.eventID)
        XCTAssertEqual(runtime.submitAttempts, ["prompt-done"])
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

        try syncer.submitMessage(sessionID: "second",
                                 text: "hello from remote",
                                 clientRequestID: "client-1")

        XCTAssertTrue(firstRuntime.submittedMessages.isEmpty)
        XCTAssertEqual(secondRuntime.submittedMessages, ["hello from remote"])
        XCTAssertEqual(secondRuntime.submittedClientRequestIDs, ["client-1"])
    }

    func testSubmitMessageUnknownSessionIsUnavailableBeforeSend() {
        let syncer = CodexAppServerRegistryRuntimeSyncer(eventHub: AgentEventHub())

        XCTAssertThrowsError(try syncer.submitMessage(sessionID: "missing",
                                                      text: "not sent",
                                                      clientRequestID: "client-1")) { error in
            guard case CodexAppServerSubmitFailure.unavailableBeforeSend(let reason) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertTrue(reason.contains("Unknown Codex app-server session"))
        }
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

        let event = try syncer.submitApproval(promptID: "prompt-shared", targetIndex: 0)

        XCTAssertEqual(event.sessionID, "instance-b")
        XCTAssertTrue(firstRuntime.submitAttempts.isEmpty || firstRuntime.submitAttempts == ["prompt-shared"])
        XCTAssertEqual(secondRuntime.submitAttempts, ["prompt-shared"])
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
        let event = Self.interactivePromptEvent(sessionID: "app",
                                                promptID: prompt.promptID,
                                                lifecycleToken: "token-1")
        let envelope = CodexAppServerInteractivePromptEnvelope(request: request,
                                                              prompt: prompt,
                                                              event: event)
        let resolvedEvent = Self.event(sessionID: "app",
                                       promptID: prompt.promptID,
                                       lifecycleToken: "token-1")

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

    func testReplacementPromptLifecycleSidebarEffectsAreExactlyOnce() throws {
        let hub = AgentEventHub()
        let sidebarQueue = DispatchQueue(label: "test.sidebar.prompt-replacement")
        let sidebarLock = NSLock()
        var sidebarMessages = [String]()
        var promptHandlers = [CodexAppServerConnection.InteractivePromptHandler]()
        var resolvedHandlers = [CodexAppServerConnection.InteractivePromptResolvedHandler]()
        let oldRuntime = FakeRuntimeSession()
        let newRuntime = FakeRuntimeSession()
        var runtimeIndex = 0
        let syncer = CodexAppServerRegistryRuntimeSyncer(
            eventHub: hub,
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

        let promptA = Self.approvalEnvelope(sessionID: "app",
                                            requestID: "approval-1",
                                            lifecycleTokenOverride: "token-a")
        promptHandlers[0](promptA)
        sidebarQueue.sync {}
        oldRuntime.onStop = {
            resolvedHandlers[0](Self.event(sessionID: "app",
                                           promptID: promptA.prompt.promptID,
                                           lifecycleToken: "token-a"))
        }
        syncer.sync(records: [
            Self.record(sessionID: "app", runtime: "codex_app_server", socketPath: "/tmp/app-2.sock"),
        ])

        let promptB = Self.approvalEnvelope(sessionID: "app",
                                            requestID: "approval-1",
                                            lifecycleTokenOverride: "token-b")
        promptHandlers[1](promptB)
        resolvedHandlers[1](Self.event(sessionID: "app",
                                       promptID: promptB.prompt.promptID,
                                       lifecycleToken: "token-a"))
        promptHandlers[1](promptB)
        resolvedHandlers[1](Self.event(sessionID: "app",
                                       promptID: promptB.prompt.promptID,
                                       lifecycleToken: "token-b"))
        resolvedHandlers[1](Self.event(sessionID: "app",
                                       promptID: promptB.prompt.promptID,
                                       lifecycleToken: "token-b"))
        sidebarQueue.sync {}

        sidebarLock.lock()
        let messages = sidebarMessages
        sidebarLock.unlock()
        XCTAssertEqual(messages.filter { $0.contains("notification.create") }.count, 2,
                       "each capability-token attempt must notify once")
        XCTAssertEqual(messages.filter {
            $0 == "report_shell_state running --workspace_id=workspace-1"
        }.count, 2,
                       "the retired A lifecycle and current B lifecycle must each resolve exactly once")
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
                       ["prompt-prompt-first", "prompt-prompt-second"])
        XCTAssertEqual(syncer.pendingApprovalPromptEvents(workspaceID: "workspace-1", sessionID: "second").map(\.eventID),
                       ["prompt-prompt-second"])
        XCTAssertTrue(syncer.pendingApprovalPromptEvents(workspaceID: "workspace-1", sessionID: "stale-session").isEmpty)
        XCTAssertTrue(syncer.pendingApprovalPromptEvents(workspaceID: "other-workspace", sessionID: nil).isEmpty)
    }

    private static func record(sessionID: String,
                               runtime: String?,
                               socketPath: String?,
                               panelID: String = "panel-1",
                               workspaceID: String = "workspace-1",
                               threadID: String? = nil,
                               resumeThreadID: String? = nil) -> AgentSessionRegistryRecord {
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
                                   resumeThreadID: resumeThreadID ?? threadID)
    }

    private static func approvalEnvelope(sessionID: String,
                                         requestID: String,
                                         lifecycleTokenOverride: String? = nil) -> CodexAppServerInteractivePromptEnvelope {
        let request = CodexAppServerApprovalRequest(
            method: "item/commandExecution/requestApproval",
            requestID: .string(requestID),
            params: [
                "threadId": .string("thread-1"),
                "turnId": .string("turn-1"),
                "itemId": .string("item-1"),
                "command": .string("ls"),
            ])!
        let prompt = request.makePrompt(epoch: "test-epoch")
        let event = interactivePromptEvent(sessionID: sessionID,
                                           promptID: prompt.promptID,
                                           lifecycleToken: lifecycleTokenOverride ?? "prompt-\(prompt.promptID)")
        return CodexAppServerInteractivePromptEnvelope(
            request: request,
            prompt: prompt,
            event: event)
    }

    private func makeReplacementEntryGap(
        newRuntime: FakeRuntimeSession,
        transitionWaitTimeout: TimeInterval = 5
    ) -> (syncer: CodexAppServerRegistryRuntimeSyncer,
          attachEntered: DispatchSemaphore,
          releaseAttach: DispatchSemaphore,
          syncDone: DispatchSemaphore) {
        let attachEntered = DispatchSemaphore(value: 0)
        let releaseAttach = DispatchSemaphore(value: 0)
        var attachCount = 0
        let syncer = CodexAppServerRegistryRuntimeSyncer(
            eventHub: AgentEventHub(),
            transitionWaitTimeout: transitionWaitTimeout,
            attachHandler: { _, _, _, _, _, _, _ in
                defer { attachCount += 1 }
                if attachCount == 0 {
                    return FakeRuntimeSession()
                }
                attachEntered.signal()
                _ = releaseAttach.wait(timeout: .now() + 5)
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
        return (syncer, attachEntered, releaseAttach, syncDone)
    }

    private static func event(sessionID: String,
                              promptID: String,
                              lifecycleToken: String? = nil) -> AgentEvent {
        var metadata = [
            "panel_id": "panel-1",
            "prompt_id": promptID,
            "source": "codex_command_approval",
        ]
        if let lifecycleToken {
            metadata["lifecycle_token"] = lifecycleToken
        }
        return AgentEvent(eventID: "resolved-\(promptID)",
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
                          metadata: metadata)
    }

    private static func interactivePromptEvent(sessionID: String,
                                               promptID: String,
                                               lifecycleToken: String? = nil) -> AgentEvent {
        var metadata = [
            "panel_id": "panel-1",
            "prompt_id": promptID,
            "source": "codex_command_approval",
        ]
        if let lifecycleToken {
            metadata["lifecycle_token"] = lifecycleToken
        }
        return AgentEvent(eventID: "prompt-\(promptID)",
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
                          metadata: metadata)
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

private final class FakeRuntimeSession: CodexAppServerRuntimeSessionControlling {
    var stopped = false
    var canSubmit = true
    var ensureThreadSubscriptionCallCount = 0
    var refreshActiveThreadCallCount = 0
    var submitAttempts = [String]()
    var submittedMessages = [String]()
    var submittedClientRequestIDs = [String?]()
    var resolvedEventsByPromptID = [String: AgentEvent]()
    var pendingPromptEvents = [AgentEvent]()
    var registryRootThreadIDs = [String]()
    var onStop: (() -> Void)?
    var submitEntered: DispatchSemaphore?
    var submitBarrier: DispatchSemaphore?

    func canSubmitMessage() -> Bool {
        canSubmit
    }

    func ensureThreadSubscription() {
        ensureThreadSubscriptionCallCount += 1
    }

    func setRegistryRootThreadID(_ rawThreadID: String?) {
        guard let threadID = rawThreadID?.trimmingCharacters(in: .whitespacesAndNewlines),
              threadID.isEmpty == false else {
            return
        }
        registryRootThreadIDs.append(threadID)
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

    func submitApproval(promptID: String, targetIndex: Int) throws -> AgentEvent {
        submitAttempts.append(promptID)
        submitEntered?.signal()
        if let submitBarrier {
            _ = submitBarrier.wait(timeout: .now() + 5)
        }
        guard let event = resolvedEventsByPromptID[promptID] else {
            throw BridgeInternalError.notFound("Unknown Codex approval prompt.")
        }
        return event
    }

    func submitMessage(text: String) throws {
        try submitMessage(text: text, clientRequestID: nil)
    }

    func submitMessage(text: String, clientRequestID: String?) throws {
        submittedMessages.append(text)
        submittedClientRequestIDs.append(clientRequestID)
    }

    func stop() {
        onStop?()
        stopped = true
    }
}
