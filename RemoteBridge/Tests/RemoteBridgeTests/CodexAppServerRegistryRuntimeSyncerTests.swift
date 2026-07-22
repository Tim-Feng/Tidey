import XCTest
@testable import RemoteBridge

final class CodexAppServerRegistryRuntimeSyncerTests: XCTestCase {
    func testSyncAttachesOnlyCodexAppServerRecords() {
        let hub = AgentEventHub()
        let runtime = FakeRuntimeSession()
        var attachedRecords = [AgentSessionRegistryRecord]()
        let syncer = CodexAppServerRegistryRuntimeSyncer(eventHub: hub, attachHandler: { record, _, _, _, _, _, _, _, _ in
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
        let syncer = CodexAppServerRegistryRuntimeSyncer(eventHub: hub, attachHandler: { _, _, _, _, _, _, _, _, _ in
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
        let syncer = CodexAppServerRegistryRuntimeSyncer(eventHub: hub, attachHandler: { _, _, _, _, _, _, _, _, _ in
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
        let syncer = CodexAppServerRegistryRuntimeSyncer(eventHub: hub, attachHandler: { _, _, _, _, _, _, _, _, _ in
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

    // P0: the last-known-good root fallback is scoped to a SAME physical
    // process (PID + socket + createdAt unchanged) reattaching after a
    // transport hiccup. A TRUE process replacement (createdAt changes) whose
    // new record's root is still blank must NOT inherit the prior process's
    // root — that root identified a different process instance. The new
    // generation's epoch must reflect an unknown ("-") root until the
    // registry supplies this new process's own nonblank authoritative root.
    func testProcessReplacementWithBlankRootDoesNotInheritPriorProcessRoot() {
        let hub = AgentEventHub()
        var runtimes = [FakeRuntimeSession]()
        var epochs = [String]()
        let syncer = CodexAppServerRegistryRuntimeSyncer(eventHub: hub, attachHandler: { _, epoch, _, _, _, _, _, _, _ in
            epochs.append(epoch)
            let runtime = FakeRuntimeSession()
            runtimes.append(runtime)
            return runtime
        })

        // A: root-a, process instance "created-1".
        syncer.sync(records: [
            Self.record(sessionID: "app", runtime: "codex_app_server", socketPath: "/tmp/app.sock",
                        threadID: "thread-a", createdAt: "2026-01-01T00:00:00Z"),
        ])
        XCTAssertEqual(runtimes.count, 1)

        // B: a TRUE process replacement (createdAt changed) whose own root is
        // still blank. Old owner (A) must be torn down; the new generation
        // must still attach (createdAt changing always replaces), but its
        // epoch must NOT carry A's root forward.
        syncer.sync(records: [
            Self.record(sessionID: "app", runtime: "codex_app_server", socketPath: "/tmp/app.sock",
                        threadID: nil, createdAt: "2026-01-02T00:00:00Z"),
        ])
        XCTAssertEqual(runtimes.count, 2, "createdAt changing always replaces the generation")
        XCTAssertTrue(runtimes[0].stopped, "the old process instance is retired")
        XCTAssertFalse(runtimes[1].stopped)
        XCTAssertEqual(epochs.count, 2)
        XCTAssertFalse(epochs[1].contains("thread-a"),
                        "a true process replacement must never attribute the old process's root to the new one")
        XCTAssertTrue(epochs[1].hasSuffix("|root:-"),
                       "the new process instance's root is unknown until the registry supplies its own")
        XCTAssertNotEqual(epochs[0], epochs[1])

        // B later reports its OWN nonblank root, same process instance
        // (createdAt unchanged from the prior sync). Only now may a fresh
        // epoch/root be minted for this process instance.
        syncer.sync(records: [
            Self.record(sessionID: "app", runtime: "codex_app_server", socketPath: "/tmp/app.sock",
                        threadID: "thread-b", createdAt: "2026-01-02T00:00:00Z"),
        ])
        XCTAssertEqual(runtimes.count, 3)
        XCTAssertTrue(runtimes[1].stopped, "the root becoming known replaces the placeholder generation")
        XCTAssertFalse(runtimes[2].stopped)
        XCTAssertEqual(epochs.count, 3)
        XCTAssertTrue(epochs[2].hasSuffix("|root:thread-b"))
        XCTAssertFalse(epochs[2].contains("thread-a"))
        XCTAssertNotEqual(epochs[1], epochs[2])
    }

    // P0: direct epoch + runtime-setter matrix, capturing exactly what
    // `attachHandler` receives (`epoch`) and what each `FakeRuntimeSession`
    // records via `setRegistryRootThreadID` — not just the epoch STRING's
    // suffix, but the actual value threaded through to the runtime.
    func testEpochAndRegistryRootSetterMatrixAcrossReattachReplacementAndBindingChange() throws {
        let hub = AgentEventHub()
        var epochs = [String]()
        var runtimes = [FakeRuntimeSession]()
        let syncer = CodexAppServerRegistryRuntimeSyncer(eventHub: hub, attachHandler: { _, epoch, _, _, _, _, _, _, _ in
            epochs.append(epoch)
            let runtime = FakeRuntimeSession()
            runtimes.append(runtime)
            return runtime
        })

        // Row A: PID/socket/createdAt/root all identical, but the runtime's
        // transport died (isStopped()) — a NEW generation attaches, but the
        // epoch must be the SAME (same process instance).
        syncer.sync(records: [
            Self.record(sessionID: "app", runtime: "codex_app_server", socketPath: "/tmp/app.sock",
                        threadID: "thread-a", createdAt: "2026-01-01T00:00:00Z"),
        ])
        guard runtimes.count == 1, epochs.count == 1 else {
            return XCTFail("the first sync must attach exactly one generation")
        }
        runtimes[0].stopped = true
        syncer.sync(records: [
            Self.record(sessionID: "app", runtime: "codex_app_server", socketPath: "/tmp/app.sock",
                        threadID: "thread-a", createdAt: "2026-01-01T00:00:00Z"),
        ])
        guard runtimes.count == 2, epochs.count == 2 else {
            return XCTFail("row A must attach a second generation")
        }
        XCTAssertEqual(epochs[1], epochs[0], "row A: identical PID/socket/createdAt/root must keep the SAME epoch across a died-transport reattach")
        XCTAssertEqual(runtimes[1].registryRootThreadIDs, ["thread-a"])

        // Row B: only createdAt changes -> a TRUE replacement, DIFFERENT epoch.
        syncer.sync(records: [
            Self.record(sessionID: "app", runtime: "codex_app_server", socketPath: "/tmp/app.sock",
                        threadID: "thread-a", createdAt: "2026-01-02T00:00:00Z"),
        ])
        guard runtimes.count == 3, epochs.count == 3 else {
            return XCTFail("row B must attach a third generation")
        }
        XCTAssertNotEqual(epochs[2], epochs[1], "row B: createdAt changing alone must change the epoch")
        XCTAssertEqual(runtimes[2].registryRootThreadIDs, ["thread-a"])

        // Row C: only the workspace/panel BINDING changes (createdAt/socket/
        // PID/root all held from row B) -> the binding change still forces
        // a replacement (a pure binding move must never masquerade as a
        // process rotation at the ATTACH level), but the epoch itself must
        // be the SAME — workspace/panel are deliberately excluded from it.
        syncer.sync(records: [
            Self.record(sessionID: "app", runtime: "codex_app_server", socketPath: "/tmp/app.sock",
                        panelID: "panel-2", workspaceID: "workspace-2",
                        threadID: "thread-a", createdAt: "2026-01-02T00:00:00Z"),
        ])
        guard runtimes.count == 4, epochs.count == 4 else {
            return XCTFail("row C must attach a fourth generation")
        }
        XCTAssertEqual(epochs[3], epochs[2], "row C: a pure workspace/panel binding move must NOT change the epoch")
        XCTAssertEqual(runtimes[3].registryRootThreadIDs, ["thread-a"])

        // Row D: SAME process instance (createdAt held from row C), the
        // runtime's transport died again, and the registry's OWN root is
        // now momentarily blank -> the new runtime's setter must receive
        // the prior generation's LAST-KNOWN-GOOD root (not nil), and the
        // epoch must stay the same.
        runtimes[3].stopped = true
        syncer.sync(records: [
            Self.record(sessionID: "app", runtime: "codex_app_server", socketPath: "/tmp/app.sock",
                        panelID: "panel-2", workspaceID: "workspace-2",
                        threadID: nil, createdAt: "2026-01-02T00:00:00Z"),
        ])
        guard runtimes.count == 5, epochs.count == 5 else {
            return XCTFail("row D must attach a fifth generation")
        }
        XCTAssertEqual(epochs[4], epochs[3], "row D: a same-process reattach with a momentarily blank registry root must keep the LKG epoch")
        XCTAssertEqual(runtimes[4].registryRootThreadIDs, ["thread-a"],
                       "row D: the new runtime must receive the prior generation's LAST-KNOWN-GOOD root, not nil")

        // Row E: a TRUE createdAt replacement whose root is ALSO blank ->
        // the new runtime's setter must receive nil (no root to inherit —
        // this is a genuinely different process instance), and the epoch
        // must differ, ending in the unknown-root marker.
        syncer.sync(records: [
            Self.record(sessionID: "app", runtime: "codex_app_server", socketPath: "/tmp/app.sock",
                        panelID: "panel-2", workspaceID: "workspace-2",
                        threadID: nil, createdAt: "2026-01-03T00:00:00Z"),
        ])
        guard runtimes.count == 6, epochs.count == 6 else {
            return XCTFail("row E must attach a sixth generation")
        }
        XCTAssertNotEqual(epochs[5], epochs[4], "row E: a true createdAt replacement must change the epoch even with a blank root")
        XCTAssertTrue(epochs[5].hasSuffix("|root:-"))
        XCTAssertEqual(runtimes[5].registryRootThreadIDs, [nil],
                       "row E: a true process replacement must never attribute the old process's root to the new one")

        // Direct Hub probe using row E's EXACT epoch and the literal "-"
        // unknown-root marker: mutation-kill for "a blank-root generation
        // wrongly begins a root:- incarnation anyway". No begin was ever
        // staged for this epoch (unknown root skips staging entirely — see
        // the blank-root production matrix test), so an admission attempt
        // against it must be flatly rejected with zero side effects.
        let seqBeforeProbe = hub.fetch(workspaceID: "workspace-2", sessionID: "app", limit: 10).newestSeq
        let probeLogical = AppServerLogicalTurnKey(sessionID: "app", epoch: epochs[5], rootThreadID: "-", turnID: "turn-probe")
        let probeOwnerKey = AppServerOwnerKey(logical: probeLogical, runtimeGeneration: UUID().uuidString, ownerToken: "probe")
        let probe = hub.admitAppServerWorkingControl(logical: probeLogical,
                                                      ownerKey: probeOwnerKey,
                                                      workspaceID: "workspace-2",
                                                      observation: .turnStarted(threadID: "-", turnID: "turn-probe", time: "probe"))
        XCTAssertFalse(probe.accepted, "no incarnation was ever begun for the unknown-root epoch — a probe admission must be rejected")
        XCTAssertTrue(probe.events.isEmpty)
        XCTAssertEqual(probe.ownerContextEffect, .none)
        XCTAssertEqual(hub.fetch(workspaceID: "workspace-2", sessionID: "app", limit: 10).newestSeq, seqBeforeProbe,
                       "the rejected probe must not have reserved a cursor slot")
    }

    func testSyncStopsStaleAndReplacedRuntimes() {
        let hub = AgentEventHub()
        var runtimes = [FakeRuntimeSession]()
        let syncer = CodexAppServerRegistryRuntimeSyncer(eventHub: hub, attachHandler: { _, _, _, _, _, _, _, _, _ in
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
        let syncer = CodexAppServerRegistryRuntimeSyncer(eventHub: hub, attachHandler: { _, _, _, _, _, _, _, _, _ in
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
                                                        attachHandler: { _, _, _, _, _, _, _, _, _ in
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
                                                        attachHandler: { _, _, _, _, _, _, _, _, _ in
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
        let syncer = CodexAppServerRegistryRuntimeSyncer(eventHub: hub, attachHandler: { _, _, _, _, _, _, _, _, _ in
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
        let syncer = CodexAppServerRegistryRuntimeSyncer(eventHub: hub, attachHandler: { _, _, _, _, _, _, _, _, _ in
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
        let syncer = CodexAppServerRegistryRuntimeSyncer(eventHub: hub, attachHandler: { _, _, _, _, _, _, _, _, _ in
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
        let syncer = CodexAppServerRegistryRuntimeSyncer(eventHub: hub, attachHandler: { _, _, _, _, _, _, _, _, _ in
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
        let syncer = CodexAppServerRegistryRuntimeSyncer(eventHub: hub, attachHandler: { _, _, _, _, _, _, _, onActiveThreadID, _ in
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
        let syncer = CodexAppServerRegistryRuntimeSyncer(eventHub: hub, attachHandler: { _, _, _, _, _, _, _, _, _ in
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
        let syncer = CodexAppServerRegistryRuntimeSyncer(eventHub: hub, attachHandler: { _, _, _, _, _, onInteractivePrompt, onInteractivePromptResolved, _, _ in
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
        // handler — including the staged `beginAppServerControlIncarnation`
        // itself. A nonblank root is required for that staging to happen
        // at all (a blank-root attach never stages `begin` in the first
        // place — see the blank-root production matrix test elsewhere —
        // so it wouldn't exercise this discard path).
        let hub = AgentEventHub()
        let sidebarQueue = DispatchQueue(label: "test.sidebar.attach-failure")
        let sidebarLock = NSLock()
        var sidebarMessages = [String]()
        var forwardedThreadIDs = [String]()
        let envelope = Self.approvalEnvelope(sessionID: "app")
        let record = Self.record(sessionID: "app", runtime: "codex_app_server", socketPath: "/tmp/app.sock",
                                 threadID: "thread-a", createdAt: "2026-01-01T00:00:00Z")
        let syncer = CodexAppServerRegistryRuntimeSyncer(eventHub: hub,
                                                        sidebarMessageSender: { message in
                                                            sidebarLock.lock()
                                                            sidebarMessages.append(message)
                                                            sidebarLock.unlock()
                                                        },
                                                        sidebarQueue: sidebarQueue,
                                                        attachHandler: { _, _, _, _, onAgentEvent, onInteractivePrompt, onInteractivePromptResolved, onActiveThreadID, onWorkingControl in
            onAgentEvent(Self.appServerEvent(eventID: "turn-started",
                                             seq: 1,
                                             sessionID: "app",
                                             type: .thinking,
                                             text: "Codex turn started",
                                             payloadKind: "turn_started"))
            onInteractivePrompt(envelope)
            onInteractivePromptResolved(Self.event(sessionID: "app", promptID: envelope.prompt.promptID, seq: 2))
            onActiveThreadID("thread-staged")
            // Synchronously staged during a failing attach — must be
            // discarded along with everything else, INCLUDING the
            // incarnation `begin` that was staged even earlier (before
            // this closure was ever invoked).
            onWorkingControl(.turnStarted(threadID: "thread-a", turnID: "turn-1", time: "t1"))
            throw BridgeInternalError.invalidRequest("attach failed after synchronous callbacks")
        })
        syncer.activeThreadHandler = { _, threadID in
            forwardedThreadIDs.append(threadID)
        }

        let seqBeforeSync = hub.fetch(workspaceID: "workspace-1", sessionID: "app", limit: 10).newestSeq

        syncer.sync(records: [record])
        sidebarQueue.sync {}

        XCTAssertTrue(hub.fetch(workspaceID: "workspace-1", sessionID: "app", limit: 10).events.isEmpty,
                      "a failed attach must not leak hub events")
        XCTAssertTrue(forwardedThreadIDs.isEmpty, "a failed attach must not leak thread bindings")
        sidebarLock.lock()
        let messages = sidebarMessages
        sidebarLock.unlock()
        XCTAssertTrue(messages.isEmpty, "a failed attach must not leak sidebar messages, got \(messages)")
        let snapshot = hub.appServerControlDebugSnapshotForTesting(sessionID: "app")
        XCTAssertNil(snapshot.currentLogicalTurn)
        XCTAssertTrue(snapshot.activeOwners.isEmpty)
        XCTAssertNil(snapshot.latestSnapshot)
        let seqAfterFailedAttach = hub.fetch(workspaceID: "workspace-1", sessionID: "app", limit: 10).newestSeq
        XCTAssertEqual(seqAfterFailedAttach, seqBeforeSync,
                       "a discarded begin/control must not have reserved any cursor either — 0 store means 0 seq consumption, not merely 0 stored events")

        // Direct probe: even if the discarded stage's own turnStarted
        // callback simply never ran (the FIFO was cleared before commit),
        // an INDEPENDENT admission attempt using the EXACT canonical
        // epoch/root this attach would have begun must still be rejected
        // — proving the staged `beginAppServerControlIncarnation` itself
        // was genuinely discarded (no Hub incarnation ever exists for this
        // epoch/root), not merely that this one callback happened to be
        // dropped while some other path still established it.
        let canonicalEpoch = CodexAppServerRegistryRuntimeSyncer.appServerEpoch(record: record, effectiveRoot: "thread-a")
        let logical = AppServerLogicalTurnKey(sessionID: "app", epoch: canonicalEpoch, rootThreadID: "thread-a", turnID: "turn-1")
        let ownerKey = AppServerOwnerKey(logical: logical, runtimeGeneration: UUID().uuidString, ownerToken: "probe")
        let probe = hub.admitAppServerWorkingControl(logical: logical,
                                                      ownerKey: ownerKey,
                                                      workspaceID: "workspace-1",
                                                      observation: .turnStarted(threadID: "thread-a", turnID: "turn-1", time: "probe"))
        XCTAssertFalse(probe.accepted, "no Hub incarnation was ever begun for this exact epoch/root — a probe admission must be rejected")
        XCTAssertTrue(probe.events.isEmpty)
        XCTAssertEqual(probe.ownerContextEffect, .none)
        XCTAssertEqual(hub.fetch(workspaceID: "workspace-1", sessionID: "app", limit: 10).newestSeq, seqBeforeSync,
                       "the rejected probe itself must not have reserved a cursor slot either")
    }

    func testAttachSuccessCommitsStagedCallbacksInOrder() throws {
        let hub = AgentEventHub()
        let sidebarQueue = DispatchQueue(label: "test.sidebar.attach-success")
        let sidebarLock = NSLock()
        var sidebarMessages = [String]()
        var forwardedThreadIDs = [String]()
        let envelope = Self.approvalEnvelope(sessionID: "app")
        let record = Self.record(sessionID: "app", runtime: "codex_app_server", socketPath: "/tmp/app.sock",
                                 threadID: "thread-a", createdAt: "2026-01-01T00:00:00Z")
        let syncer = CodexAppServerRegistryRuntimeSyncer(eventHub: hub,
                                                        sidebarMessageSender: { message in
                                                            sidebarLock.lock()
                                                            sidebarMessages.append(message)
                                                            sidebarLock.unlock()
                                                        },
                                                        sidebarQueue: sidebarQueue,
                                                        attachHandler: { _, _, _, _, onAgentEvent, onInteractivePrompt, onInteractivePromptResolved, onActiveThreadID, onWorkingControl in
            onAgentEvent(Self.appServerEvent(eventID: "turn-started",
                                             seq: 1,
                                             sessionID: "app",
                                             type: .thinking,
                                             text: "Codex turn started",
                                             payloadKind: "turn_started"))
            // Staged BEFORE the interactive prompt: a control "open" is
            // hidden (admitted but never wire-published) while ANY
            // interactive prompt is active in this session — staging it
            // first keeps this test isolated to what it's actually
            // proving (begin committed before this admission), rather
            // than accidentally exercising the separate
            // prompt-hides-control rule too. The incarnation `begin`
            // itself was staged even earlier — before this closure ever
            // ran — so this admission succeeding at all is the proof
            // begin committed before it.
            onWorkingControl(.turnStarted(threadID: "thread-a", turnID: "turn-1", time: "t1"))
            onInteractivePrompt(envelope)
            onInteractivePromptResolved(Self.event(sessionID: "app", promptID: envelope.prompt.promptID, seq: 2))
            onActiveThreadID("thread-staged")
            return FakeRuntimeSession()
        })
        syncer.activeThreadHandler = { _, threadID in
            forwardedThreadIDs.append(threadID)
        }

        syncer.sync(records: [record])
        sidebarQueue.sync {}

        let events = hub.fetch(workspaceID: "workspace-1", sessionID: "app", limit: 10).events
        XCTAssertEqual(events.map(\.type), [.thinking, .interactivePrompt, .interactivePromptResolved],
                       "a successful attach must commit staged callbacks in FIFO delivery order, including the typed control open")
        let controlEvents = events.filter { $0.metadata?["source"] == "codex_app_server_working_control" }
        guard controlEvents.count == 1 else {
            return XCTFail("exactly one staged control open — proving the incarnation begin committed before it, not zero (fail-closed) and not more than one — got \(controlEvents.count)")
        }
        XCTAssertEqual(controlEvents[0].metadata?["working_phase"], "open")
        XCTAssertEqual(controlEvents[0].metadata?["turn_id"], "turn-1")
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
        let syncer = CodexAppServerRegistryRuntimeSyncer(eventHub: hub, attachHandler: { _, _, _, _, _, onInteractivePrompt, _, onActiveThreadID, _ in
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
                                                        attachHandler: { _, _, _, _, onAgentEvent, onInteractivePrompt, onInteractivePromptResolved, _, _ in
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
                                                        attachHandler: { _, _, _, _, onAgentEvent, _, _, _, _ in
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
        let syncer = CodexAppServerRegistryRuntimeSyncer(eventHub: hub, attachHandler: { _, _, _, _, _, _, _, _, _ in
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
        let syncer = CodexAppServerRegistryRuntimeSyncer(eventHub: hub, attachHandler: { _, _, _, _, _, _, _, _, _ in
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
        let syncer = CodexAppServerRegistryRuntimeSyncer(eventHub: hub, attachHandler: { _, _, _, _, _, _, _, _, _ in
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
                                                        attachHandler: { _, _, _, _, _, onInteractivePrompt, onInteractivePromptResolved, _, _ in
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
        XCTAssertTrue(promptMessages.contains("report_shell_state prompt --workspace_id=workspace-1"))

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

    // Round 4: reconcile()'s barrier must make a stop()-driven terminal's
    // sidebar side effect (enqueued asynchronously on sidebarQueue from
    // inside the SYNCHRONOUS stop() call) visible to the caller's cleanup
    // callback — never after it. Without the `sidebarQueue.sync {}` barrier
    // between "stop old generations" and "invoke callback", the callback can
    // run before the async-enqueued terminal cleanup has actually sent,
    // which is exactly the late-old-workspace-output race this closes.
    func testReconcileBarrierEnsuresStopDrivenTerminalSidebarPrecedesCleanupCallback() throws {
        let hub = AgentEventHub()
        let sidebarQueue = DispatchQueue(label: "test.sidebar.reconcile-barrier")
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
                                                        attachHandler: { _, _, _, _, _, onInteractivePrompt, onInteractivePromptResolved, _, _ in
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

        // stop()-driven terminal cleanup fires SYNCHRONOUSLY from inside
        // stop() (called from reconcile's retirement phase), but its
        // "running" sidebar restore is only enqueued (not sent) onto
        // sidebarQueue at that point.
        runtime.onStop = {
            resolvedHandler?(Self.event(sessionID: "app",
                                        promptID: envelope.prompt.promptID,
                                        seq: 2,
                                        lifecycleToken: envelope.event.eventID))
        }

        var cleanupSawMessages: [String] = []
        syncer.reconcile(records: []) {
            sidebarLock.lock()
            cleanupSawMessages = sidebarMessages
            sidebarLock.unlock()
        }

        sidebarLock.lock()
        let allMessages = sidebarMessages
        sidebarLock.unlock()

        XCTAssertTrue(cleanupSawMessages.contains("report_shell_state running --workspace_id=workspace-1"),
                     "the barrier must ensure the stop-driven terminal's sidebar restore is already delivered before the cleanup callback runs, got \(cleanupSawMessages)")
        XCTAssertEqual(allMessages, cleanupSawMessages,
                      "no sidebar work may be enqueued between the retiring generation's stop and the cleanup callback")
    }

    // The reconcile() callback gates new/surviving producer activation: a
    // fresh attach for workspace B must never happen before the callback
    // (the caller's departed-workspace cleanup) returns.
    func testReconcileNewAttachOnlyHappensAfterCleanupCallbackReturns() throws {
        let hub = AgentEventHub()
        let sidebarQueue = DispatchQueue(label: "test.sidebar.reconcile-attach-order")
        var attachedSessionIDs = [String]()
        let attachLock = NSLock()
        let syncer = CodexAppServerRegistryRuntimeSyncer(eventHub: hub,
                                                        sidebarQueue: sidebarQueue,
                                                        attachHandler: { record, _, _, _, _, _, _, _, _ in
            attachLock.lock()
            attachedSessionIDs.append(record.sessionID)
            attachLock.unlock()
            return FakeRuntimeSession()
        })

        var callbackSawAttachedSessionIDs: [String] = []
        syncer.reconcile(records: [
            Self.record(sessionID: "app-b", runtime: "codex_app_server", socketPath: "/tmp/app-b.sock"),
        ]) {
            attachLock.lock()
            callbackSawAttachedSessionIDs = attachedSessionIDs
            attachLock.unlock()
        }

        XCTAssertEqual(callbackSawAttachedSessionIDs, [],
                      "the new session must not be attached before the cleanup callback runs")
        attachLock.lock()
        let finalAttached = attachedSessionIDs
        attachLock.unlock()
        XCTAssertEqual(finalAttached, ["app-b"],
                      "the new session must be attached once the callback has returned")
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
                                                        attachHandler: { _, _, _, _, onAgentEvent, _, _, _, _ in
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
        let syncer = CodexAppServerRegistryRuntimeSyncer(eventHub: hub, attachHandler: { record, _, _, _, _, onInteractivePrompt, _, _, _ in
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
                                                        attachHandler: { _, _, _, _, _, _, _, _, _ in
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
        let syncer = CodexAppServerRegistryRuntimeSyncer(eventHub: hub, attachHandler: { _, _, _, _, _, onInteractivePrompt, _, _, _ in
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
                                                        attachHandler: { _, _, _, _, _, onInteractivePrompt, onInteractivePromptResolved, _, _ in
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
                                                        attachHandler: { _, _, _, _, _, onInteractivePrompt, onInteractivePromptResolved, _, _ in
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
                                                        attachHandler: { _, _, _, _, _, onInteractivePrompt, onInteractivePromptResolved, _, _ in
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
        XCTAssertEqual(messages.last, "report_shell_state prompt --workspace_id=workspace-1")

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
                                                        attachHandler: { _, _, _, _, _, _, _, _, _ in
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
        let syncer = CodexAppServerRegistryRuntimeSyncer(eventHub: hub, attachHandler: { _, _, _, _, _, onInteractivePrompt, onInteractivePromptResolved, _, _ in
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
        let syncer = CodexAppServerRegistryRuntimeSyncer(eventHub: hub, attachHandler: { _, _, _, _, _, _, _, onActiveThreadID, _ in
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
        let syncer = CodexAppServerRegistryRuntimeSyncer(eventHub: hub, attachHandler: { _, _, _, _, _, _, _, _, _ in
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
        let syncer = CodexAppServerRegistryRuntimeSyncer(eventHub: hub, attachHandler: { record, _, _, _, _, _, _, _, _ in
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
        let syncer = CodexAppServerRegistryRuntimeSyncer(eventHub: hub, attachHandler: { _, _, _, _, _, _, _, _, _ in
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
        let syncer = CodexAppServerRegistryRuntimeSyncer(eventHub: hub, attachHandler: { _, _, _, _, _, _, _, _, _ in
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
        let syncer = CodexAppServerRegistryRuntimeSyncer(eventHub: hub, attachHandler: { _, _, _, _, _, _, _, _, _ in
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
                                                        attachHandler: { _, _, _, _, _, _, _, _, _ in
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
        let syncer = CodexAppServerRegistryRuntimeSyncer(eventHub: hub, attachHandler: { _, _, _, _, _, _, _, onActiveThreadID, _ in
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
                                                        attachHandler: { _, _, _, _, onAgentEvent, _, _, _, _ in
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
        let syncer = CodexAppServerRegistryRuntimeSyncer(eventHub: hub, attachHandler: { _, _, _, _, _, onInteractivePrompt, _, _, _ in
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
                                                        attachHandler: { _, _, _, _, _, onInteractivePrompt, _, _, _ in
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
        XCTAssertEqual(messages[1], "report_shell_state prompt --workspace_id=workspace-1")
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
                                                        attachHandler: { _, _, _, _, _, onInteractivePrompt, onInteractivePromptResolved, _, _ in
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
        XCTAssertEqual(messages[1], "report_shell_state prompt --workspace_id=workspace-1")
        XCTAssertEqual(messages[2], "report_shell_state running --workspace_id=workspace-1")
        XCTAssertTrue(messages[3].contains(#""action":"notification.create""#))
        XCTAssertEqual(messages[4], "report_shell_state prompt --workspace_id=workspace-1")
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
        let syncer = CodexAppServerRegistryRuntimeSyncer(eventHub: hub, attachHandler: { _, _, _, _, _, _, _, _, _ in
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

    // MARK: - Working-control production wiring (Section 1/3 P0 fixes)

    // P0: `admitAppServerWorkingControl`/`retireAppServerOwner` already
    // store + schedule delivery + fire the postStore hook for every event
    // they return — the Syncer must NOT publish those events a second time.
    func testWorkingControlLiveObservationDeliversExactlyOnceNoDoublePublish() {
        let hub = AgentEventHub()
        var control: CodexAppServerHeadlessRuntime.WorkingControlHandler?
        let syncer = CodexAppServerRegistryRuntimeSyncer(eventHub: hub, attachHandler: { _, _, _, _, _, _, _, _, onWorkingControl in
            control = onWorkingControl
            return FakeRuntimeSession()
        })
        syncer.sync(records: [
            Self.record(sessionID: "app", runtime: "codex_app_server", socketPath: "/tmp/app.sock", threadID: "thread-a"),
        ])
        guard let control else {
            return XCTFail("attach never captured onWorkingControl")
        }

        var deliveryCount = 0
        hub.postStoreDeliveryHook = { _ in deliveryCount += 1 }
        // A dedupe guard inside `publish` would silently swallow a wrongly
        // re-published event with the SAME eventID as the one admission
        // just stored, leaving `postStoreDeliveryHook`/`fetch` looking
        // identical whether the Syncer re-published or not — a false green
        // that would NOT be mutation-killed by re-adding the old
        // `eventHub.publish(event)` calls. `publishAttemptHook` fires
        // before that dedupe guard, so it is the only seam that actually
        // distinguishes "0 publish() calls" from "1 publish() call that
        // happened to be deduped".
        var publishAttempts = 0
        hub.publishAttemptHook = { _ in publishAttempts += 1 }
        control(.turnStarted(threadID: "thread-a", turnID: "turn-1", time: "t1"))

        XCTAssertEqual(publishAttempts, 0,
                       "the Syncer's Working-control path must never call eventHub.publish() at all — admission already stores")
        XCTAssertEqual(deliveryCount, 1, "the Hub's own postStore delivery must fire exactly once")
        let fetched = hub.fetch(workspaceID: "workspace-1", sessionID: "app", limit: 10)
        XCTAssertEqual(fetched.events.count, 1)
        XCTAssertEqual(fetched.events.first?.metadata?["source"], "codex_app_server_working_control")
    }

    // P0: an owner disconnect must reject late start/activity/resume for the
    // SAME (still-current) generation — proved via 0 Hub ADMISSION ATTEMPTS
    // (not merely 0 stored events, which the Hub's own retired-owner
    // tombstone could equally explain) — but a semantic terminal for the
    // already-open turn must still be admitted (tombstone-first), and reach
    // the Hub exactly once.
    func testOwnerDisconnectRejectsLateStartActivityResumeButAdmitsCurrentTerminal() {
        let hub = AgentEventHub()
        var control: CodexAppServerHeadlessRuntime.WorkingControlHandler?
        let syncer = CodexAppServerRegistryRuntimeSyncer(eventHub: hub, attachHandler: { _, _, _, _, _, _, _, _, onWorkingControl in
            control = onWorkingControl
            return FakeRuntimeSession()
        })
        syncer.sync(records: [
            Self.record(sessionID: "app", runtime: "codex_app_server", socketPath: "/tmp/app.sock", threadID: "thread-a"),
        ])
        guard let control else {
            return XCTFail("attach never captured onWorkingControl")
        }

        control(.turnStarted(threadID: "thread-a", turnID: "turn-1", time: "t1"))
        XCTAssertEqual(hub.fetch(workspaceID: "workspace-1", sessionID: "app", limit: 10).events.count, 1)

        // Same mutation-kill requirement as the live-observation path: a
        // wrongly re-published owner-terminal event would be silently
        // absorbed by the dedupe guard, leaving postStore/fetch unchanged.
        // `publishAttemptHook` catches the call itself, before dedupe.
        var publishAttempts = 0
        hub.publishAttemptHook = { _ in publishAttempts += 1 }
        var deliveryCount = 0
        hub.postStoreDeliveryHook = { _ in deliveryCount += 1 }
        control(.ownerDisconnected(reason: .transportClosed, time: "t2"))
        XCTAssertEqual(publishAttempts, 0,
                       "the Syncer's ownerDisconnected path must never call eventHub.publish() — retireAppServerOwner already stores")
        XCTAssertEqual(deliveryCount, 1, "exactly one Hub-owned post-store delivery for the owner-scoped terminal")
        XCTAssertTrue(hub.appServerControlDebugSnapshotForTesting(sessionID: "app").activeOwners.isEmpty,
                      "the disconnect must retire the owner mapping")
        let ownerTerminalCount = hub.fetch(workspaceID: "workspace-1", sessionID: "app", limit: 10).events.count
        XCTAssertEqual(ownerTerminalCount, 2, "exactly one owner terminal is stored alongside the original open")

        var admissionAttempts = 0
        hub.admissionAttemptHook = { _, _ in admissionAttempts += 1 }
        let afterDisconnectCount = hub.fetch(workspaceID: "workspace-1", sessionID: "app", limit: 10).events.count

        // Late start/activity/resume after disconnect must never even reach
        // Hub admission — this is the Syncer's OWN `retired` gate, not the
        // Hub's retired-owner tombstone (which would ALSO reject these,
        // making a plain 0-events assertion alone ambiguous about which
        // fence actually fired).
        control(.turnStarted(threadID: "thread-a", turnID: "turn-2", time: "t3"))
        control(.internalActivityStarted(threadID: "thread-a", turnID: "turn-1", itemID: "item-1", kind: .collabAgentToolCall, time: "t4"))
        control(.resumeSnapshot(threadID: "thread-a", turnID: "turn-1", time: "t5"))
        XCTAssertEqual(admissionAttempts, 0,
                       "start/activity/resume must be rejected by the Syncer's OWN retired gate before ever reaching Hub admission")
        XCTAssertEqual(hub.fetch(workspaceID: "workspace-1", sessionID: "app", limit: 10).events.count, afterDisconnectCount,
                       "start/activity/resume must be 0 after the owner disconnected")

        // But the CURRENT generation's own semantic terminal for the turn
        // that was actually open must still reach Hub admission exactly
        // once and be admitted.
        control(.turnTerminal(threadID: "thread-a", turnID: "turn-1", rawStatus: "completed", time: "t6"))
        XCTAssertEqual(admissionAttempts, 1, "the semantic terminal, unlike start/activity/resume, must reach Hub admission")
        let afterTerminal = hub.fetch(workspaceID: "workspace-1", sessionID: "app", limit: 10)
        XCTAssertEqual(afterTerminal.events.count, afterDisconnectCount + 1,
                       "a semantic terminal must still be admitted (tombstone-first) after the owner disconnected")
        let terminalEvent = afterTerminal.events.last
        XCTAssertEqual(terminalEvent?.metadata?["working_phase"], "terminal")
        XCTAssertEqual(terminalEvent?.metadata?["terminal_scope"], "semantic_turn")
        XCTAssertEqual(terminalEvent?.metadata?["reason"], "turn_completed")
        XCTAssertEqual(terminalEvent?.metadata?["turn_id"], "turn-1")

        let snapshotAfterTerminal = hub.appServerControlDebugSnapshotForTesting(sessionID: "app")
        XCTAssertEqual(snapshotAfterTerminal.currentLogicalTurn, nil)
        XCTAssertEqual(snapshotAfterTerminal.suspendedLogicalTurn, nil)
        guard let tombstonedKey = snapshotAfterTerminal.semanticTombstones.first(where: { $0.turnID == "turn-1" }) else {
            return XCTFail("the exact logical key for turn-1 must be tombstoned after the terminal admission")
        }
        XCTAssertEqual(tombstonedKey.sessionID, "app")
        XCTAssertEqual(tombstonedKey.rootThreadID, "thread-a")

        // The same logical turn (turn-1) can never reopen after its own
        // terminal — start/activity/resume against it stay 0 forever, not
        // just in the disconnect-only window checked above.
        control(.turnStarted(threadID: "thread-a", turnID: "turn-1", time: "t7"))
        control(.resumeSnapshot(threadID: "thread-a", turnID: "turn-1", time: "t8"))
        XCTAssertEqual(hub.fetch(workspaceID: "workspace-1", sessionID: "app", limit: 10).events.count, afterDisconnectCount + 1,
                       "turn-1 is tombstoned — a later start/resume against the SAME logical turn must stay 0")
    }

    // P0: after a REPLACEMENT, the old generation's own late semantic
    // terminal must be generation-fenced to zero — even though a terminal
    // would otherwise bypass the `retired` gate. Deliberately a
    // SAME-INCARNATION reattach (identical socket/PID/createdAt/root,
    // only `session.isStopped()` differs) rather than a true rotation: a
    // true rotation's DIFFERENT epoch would make the Hub's OWN incarnation
    // fence reject A's callback too, so that alone wouldn't prove the
    // Syncer's generation recheck is what's actually doing the work. Here
    // the Hub incarnation is UNCHANGED and would happily accept A's
    // terminal (same epoch/root, current turn still open in Hub state) —
    // only the Syncer's own generation fence can be blocking it.
    func testReplacementFencesOldGenerationLateSemanticTerminal() {
        let hub = AgentEventHub()
        var controls = [CodexAppServerHeadlessRuntime.WorkingControlHandler]()
        var runtimes = [FakeRuntimeSession]()
        let syncer = CodexAppServerRegistryRuntimeSyncer(eventHub: hub, attachHandler: { _, _, _, _, _, _, _, _, onWorkingControl in
            controls.append(onWorkingControl)
            let runtime = FakeRuntimeSession()
            runtimes.append(runtime)
            return runtime
        })
        let sameRecord = Self.record(sessionID: "app", runtime: "codex_app_server", socketPath: "/tmp/app.sock",
                                     threadID: "thread-a", createdAt: "2026-01-01T00:00:00Z")
        syncer.sync(records: [sameRecord])
        guard let controlA = controls.first else {
            return XCTFail("generation A never captured onWorkingControl")
        }
        controlA(.turnStarted(threadID: "thread-a", turnID: "turn-1", time: "t1"))
        XCTAssertEqual(hub.fetch(workspaceID: "workspace-1", sessionID: "app", limit: 10).events.count, 1)

        // Same-incarnation reattach: transport died, everything else
        // (socket/PID/createdAt/root) identical.
        runtimes[0].stopped = true
        syncer.sync(records: [sameRecord])
        XCTAssertEqual(controls.count, 2, "the reattach must install a NEW Syncer generation")

        var admissionAttempts = 0
        hub.admissionAttemptHook = { _, _ in admissionAttempts += 1 }
        controlA(.turnTerminal(threadID: "thread-a", turnID: "turn-1", rawStatus: "completed", time: "t2"))
        XCTAssertEqual(admissionAttempts, 0,
                       "generation A's late terminal must not even reach Hub admission — the Hub's OWN incarnation is unchanged and would otherwise accept it")
        XCTAssertEqual(hub.fetch(workspaceID: "workspace-1", sessionID: "app", limit: 10).events.count, 1,
                       "generation A's late terminal must be 0 after replacement — even though a terminal bypasses the retired gate")
    }

    // P0: `ownerDisconnected` must still be current-or-retiring generation
    // fenced — a fully-retired generation's stray late disconnect (after
    // the sidebar queue's retiringGenerations cleanup has already run) must
    // have zero effect, leaving the (now orphaned but never falsely
    // retired) Hub owner mapping untouched.
    func testFullyRetiredGenerationLateDisconnectIsZeroEffect() {
        let hub = AgentEventHub()
        var control: CodexAppServerHeadlessRuntime.WorkingControlHandler?
        let syncer = CodexAppServerRegistryRuntimeSyncer(eventHub: hub, attachHandler: { _, _, _, _, _, _, _, _, onWorkingControl in
            control = onWorkingControl
            return FakeRuntimeSession()
        })
        syncer.sync(records: [
            Self.record(sessionID: "app", runtime: "codex_app_server", socketPath: "/tmp/app.sock", threadID: "thread-a"),
        ])
        guard let control else {
            return XCTFail("attach never captured onWorkingControl")
        }
        control(.turnStarted(threadID: "thread-a", turnID: "turn-1", time: "t1"))
        XCTAssertFalse(hub.appServerControlDebugSnapshotForTesting(sessionID: "app").activeOwners.isEmpty)

        // Drive the session away and run the reconciliation barrier
        // synchronously so retiringGenerations is fully drained — the
        // generation is no longer "current" NOR "retiring".
        syncer.reconcile(records: [], betweenRetirementAndActivation: {})

        control(.ownerDisconnected(reason: .processExited, time: "t2"))
        XCTAssertFalse(hub.appServerControlDebugSnapshotForTesting(sessionID: "app").activeOwners.isEmpty,
                       "a fully-retired generation's late disconnect must be 0 — the owner mapping must be untouched")
    }

    // P0 defense-in-depth: the Headless factory already refuses to
    // construct a blank-ID observation, but the Syncer's own boundary must
    // independently re-validate every field it depends on (per observation
    // kind) rather than trust that upstream guarantee alone. The rejected
    // observations must never reach Hub admission AND must not consume any
    // cursor — the legitimate turnStarted admitted afterward must land at
    // the exact seq the blank ones would have stolen had they leaked
    // through.
    func testBlankItemIDAndRawStatusConstructedObservationsHaveZeroEffect() {
        let hub = AgentEventHub()
        var control: CodexAppServerHeadlessRuntime.WorkingControlHandler?
        let syncer = CodexAppServerRegistryRuntimeSyncer(eventHub: hub, attachHandler: { _, _, _, _, _, _, _, _, onWorkingControl in
            control = onWorkingControl
            return FakeRuntimeSession()
        })
        syncer.sync(records: [
            Self.record(sessionID: "app", runtime: "codex_app_server", socketPath: "/tmp/app.sock", threadID: "thread-a"),
        ])
        guard let control else {
            return XCTFail("attach never captured onWorkingControl")
        }

        var admissionAttempts = 0
        hub.admissionAttemptHook = { _, _ in admissionAttempts += 1 }

        // Directly-constructed enum values bypass CodexAppServerWorkingControlFactory's
        // own blank guards — the Syncer must not trust that upstream check alone.
        control(.internalActivityStarted(threadID: "thread-a", turnID: "turn-1", itemID: "   ", kind: .collabAgentToolCall, time: "t1"))
        control(.turnTerminal(threadID: "thread-a", turnID: "turn-1", rawStatus: "  \n", time: "t2"))
        XCTAssertEqual(admissionAttempts, 0, "blank itemID/rawStatus observations must never reach Hub admission at all")

        control(.turnStarted(threadID: "thread-a", turnID: "turn-1", time: "t3"))
        XCTAssertEqual(admissionAttempts, 1)
        let fetched = hub.fetch(workspaceID: "workspace-1", sessionID: "app", limit: 10)
        XCTAssertEqual(fetched.events.count, 1,
                       "only the legitimate turnStarted admits; the blank-itemID activity and blank-rawStatus terminal are 0")
        XCTAssertEqual(fetched.events.first?.seq, 1,
                       "the blank observations must not have stolen any cursor — the legitimate event lands at the same seq it would have with no prior rejected attempts")
    }

    // P0: the locked authoritative recheck (not merely an earlier,
    // stale-by-construction check) is what rejects a stale callback — a
    // replacement completing INSIDE the hook window, immediately before
    // `forwardLock` is acquired, must still be caught. Same-incarnation
    // reattach (see `testReplacementFencesOldGenerationLateSemanticTerminal`
    // for why a true rotation would not isolate the Syncer's own fence).
    func testLockedRecheckRejectsLiveObservationAfterReplacementCompletesInHookWindow() {
        let hub = AgentEventHub()
        var controls = [CodexAppServerHeadlessRuntime.WorkingControlHandler]()
        var runtimes = [FakeRuntimeSession]()
        let syncer = CodexAppServerRegistryRuntimeSyncer(eventHub: hub, attachHandler: { _, _, _, _, _, _, _, _, onWorkingControl in
            controls.append(onWorkingControl)
            let runtime = FakeRuntimeSession()
            runtimes.append(runtime)
            return runtime
        })
        let sameRecord = Self.record(sessionID: "app", runtime: "codex_app_server", socketPath: "/tmp/app.sock",
                                     threadID: "thread-a", createdAt: "2026-01-01T00:00:00Z")
        syncer.sync(records: [sameRecord])
        guard let controlA = controls.first else {
            return XCTFail("generation A never captured onWorkingControl")
        }
        controlA(.turnStarted(threadID: "thread-a", turnID: "turn-1", time: "t1"))
        XCTAssertEqual(hub.fetch(workspaceID: "workspace-1", sessionID: "app", limit: 10).events.count, 1)

        var replaced = false
        syncer.workingControlObservationHook = { [weak syncer] in
            guard replaced == false else {
                return
            }
            replaced = true
            runtimes[0].stopped = true
            syncer?.sync(records: [sameRecord])
        }
        var admissionAttempts = 0
        hub.admissionAttemptHook = { _, _ in admissionAttempts += 1 }
        controlA(.turnTerminal(threadID: "thread-a", turnID: "turn-1", rawStatus: "completed", time: "t2"))

        XCTAssertTrue(replaced, "the hook must have run and completed the replacement")
        XCTAssertEqual(controls.count, 2)
        XCTAssertEqual(admissionAttempts, 0,
                       "the same-incarnation reattach completing inside the hook window must still be visible to the locked recheck — the Hub incarnation is unchanged and would otherwise accept this")
        XCTAssertEqual(hub.fetch(workspaceID: "workspace-1", sessionID: "app", limit: 10).events.count, 1)
    }

    // P0: a TRUE process replacement (createdAt changed) whose new record's
    // root is still blank must produce a fully inert generation — 0 Hub
    // admission attempts, 0 publish attempts, 0 cursor movement, 0
    // snapshot — for EVERY control kind, until a later sync supplies this
    // same process instance's own nonblank authoritative root. Crucially,
    // the OLD owner must be torn down (its own owner-scoped terminal
    // reaching the Hub) as part of that same replacement — this is what
    // stops the mobile client from being stuck on a stale Working: if A's
    // owner were never retired, its `currentLogicalTurn`/`activeOwners`
    // would sit in the Hub forever since B never admits anything.
    func testCreatedAtChangeWithBlankRootProductionMatrix() {
        let hub = AgentEventHub()
        var controls = [CodexAppServerHeadlessRuntime.WorkingControlHandler]()
        var runtimes = [FakeRuntimeSession]()
        let syncer = CodexAppServerRegistryRuntimeSyncer(eventHub: hub, attachHandler: { _, _, _, _, _, _, _, _, onWorkingControl in
            controls.append(onWorkingControl)
            let runtime = FakeRuntimeSession()
            runtimes.append(runtime)
            // Stand-in for the eventual RuntimeSession finish-winner
            // barrier (Section 5, not yet implemented): stop() fires
            // exactly one ownerDisconnected for THIS generation
            // SYNCHRONOUSLY, mirroring the real production ordering the
            // Syncer depends on (old owner terminal reaches the Hub before
            // any new generation's begin/open). This locks only the
            // SYNCER's own ordering guarantees — a genuine RuntimeSession
            // race test still belongs alongside the real finish barrier.
            runtime.onStop = {
                onWorkingControl(.ownerDisconnected(reason: .sessionRetired, time: "teardown"))
            }
            return runtime
        })

        // 1. A: root-a, process instance "created-1" — real Working.
        syncer.sync(records: [
            Self.record(sessionID: "app", runtime: "codex_app_server", socketPath: "/tmp/app.sock",
                        threadID: "thread-a", createdAt: "2026-01-01T00:00:00Z"),
        ])
        guard let controlA = controls.first else {
            return XCTFail("generation A never captured onWorkingControl")
        }
        controlA(.turnStarted(threadID: "thread-a", turnID: "turn-1", time: "t1"))

        let afterAOpen = hub.fetch(workspaceID: "workspace-1", sessionID: "app", limit: 10)
        XCTAssertEqual(afterAOpen.events.count, 1)
        XCTAssertEqual(afterAOpen.events.first?.metadata?["working_phase"], "open")
        XCTAssertEqual(afterAOpen.events.first?.metadata?["turn_id"], "turn-1")
        guard let aOpenSeq = afterAOpen.events.first?.seq else {
            return XCTFail("missing A open seq")
        }
        let snapshotAOpen = hub.appServerControlDebugSnapshotForTesting(sessionID: "app")
        XCTAssertEqual(snapshotAOpen.currentLogicalTurn?.turnID, "turn-1")
        XCTAssertNil(snapshotAOpen.suspendedLogicalTurn)
        XCTAssertFalse(snapshotAOpen.activeOwners.isEmpty)
        XCTAssertEqual(snapshotAOpen.latestSnapshot?.eventID, afterAOpen.events.first?.eventID)

        // 2. B: a TRUE process replacement (createdAt changed), still blank
        // root. `sync()` calls `entry.session.stop()` on the retired A
        // BEFORE attaching B — this test's `onStop` wiring makes A's
        // ownerDisconnected fire synchronously inside that same call.
        syncer.sync(records: [
            Self.record(sessionID: "app", runtime: "codex_app_server", socketPath: "/tmp/app.sock",
                        threadID: nil, createdAt: "2026-01-02T00:00:00Z"),
        ])
        XCTAssertEqual(controls.count, 2, "createdAt changing always replaces the generation")
        XCTAssertTrue(runtimes[0].stopped, "generation A's session must be torn down")

        let afterATeardown = hub.fetch(workspaceID: "workspace-1", sessionID: "app", limit: 10)
        XCTAssertEqual(afterATeardown.events.count, 2, "A's own owner-scoped terminal must already be in the Hub")
        let terminalEvent = afterATeardown.events.last
        XCTAssertEqual(terminalEvent?.metadata?["working_phase"], "terminal")
        XCTAssertEqual(terminalEvent?.metadata?["terminal_scope"], "owner")
        XCTAssertEqual(terminalEvent?.metadata?["reason"], "session_retired")
        XCTAssertEqual(terminalEvent?.metadata?["turn_id"], "turn-1")
        guard let aTerminalSeq = terminalEvent?.seq else {
            return XCTFail("missing A owner-terminal seq")
        }
        XCTAssertGreaterThan(aTerminalSeq, aOpenSeq)

        let snapshotAfterATeardown = hub.appServerControlDebugSnapshotForTesting(sessionID: "app")
        XCTAssertNil(snapshotAfterATeardown.currentLogicalTurn)
        // The Hub SUSPENDS (not tombstones) the last owner's turn on an
        // owner-scoped terminal — a resume could still legitimately reopen
        // it — but B never gets that far since its root is unknown.
        XCTAssertEqual(snapshotAfterATeardown.suspendedLogicalTurn?.turnID, "turn-1")
        XCTAssertTrue(snapshotAfterATeardown.activeOwners.isEmpty)
        XCTAssertNil(snapshotAfterATeardown.latestSnapshot)

        guard let controlB = controls.last else {
            return XCTFail("generation B never captured onWorkingControl")
        }

        var admissionAttempts = 0
        hub.admissionAttemptHook = { _, _ in admissionAttempts += 1 }
        var publishAttempts = 0
        hub.publishAttemptHook = { _ in publishAttempts += 1 }

        // B's blank-root generation: every control kind must be completely
        // unrouted — 0 Hub admission attempts, not merely 0 stored events.
        controlB(.turnStarted(threadID: "thread-a", turnID: "turn-b1", time: "t2"))
        controlB(.internalActivityStarted(threadID: "thread-a", turnID: "turn-b1", itemID: "item-1", kind: .collabAgentToolCall, time: "t3"))
        controlB(.resumeSnapshot(threadID: "thread-a", turnID: "turn-b1", time: "t4"))
        controlB(.turnTerminal(threadID: "thread-a", turnID: "turn-b1", rawStatus: "completed", time: "t5"))
        XCTAssertEqual(admissionAttempts, 0, "an unknown-root generation must never even reach Hub admission")
        XCTAssertEqual(publishAttempts, 0)
        let afterB = hub.fetch(workspaceID: "workspace-1", sessionID: "app", limit: 10)
        XCTAssertEqual(afterB.events.count, 2, "B's blank-root generation must produce 0 cursor movement for any control kind")
        let snapshotAfterB = hub.appServerControlDebugSnapshotForTesting(sessionID: "app")
        XCTAssertNil(snapshotAfterB.currentLogicalTurn)
        XCTAssertEqual(snapshotAfterB.suspendedLogicalTurn?.turnID, "turn-1",
                       "B produces no NEW state — A's suspended trajectory (left by its own teardown) is untouched")
        XCTAssertNil(snapshotAfterB.latestSnapshot)

        // 3. A's stale callback after replacement: still 0, never reaching Hub.
        controlA(.turnStarted(threadID: "thread-a", turnID: "turn-1", time: "t6"))
        XCTAssertEqual(admissionAttempts, 0, "generation A's own stale callback must not reach Hub admission either")
        XCTAssertEqual(hub.fetch(workspaceID: "workspace-1", sessionID: "app", limit: 10).events.count, 2)

        // 4. B/C: B later learns its OWN nonblank root (same process
        // instance, createdAt unchanged) — only now may a fresh incarnation
        // begin.
        syncer.sync(records: [
            Self.record(sessionID: "app", runtime: "codex_app_server", socketPath: "/tmp/app.sock",
                        threadID: "thread-b", createdAt: "2026-01-02T00:00:00Z"),
        ])
        XCTAssertEqual(controls.count, 3)
        guard let controlC = controls.last else {
            return XCTFail("generation C never captured onWorkingControl")
        }
        controlC(.turnStarted(threadID: "thread-b", turnID: "turn-c1", time: "t7"))

        // C's root/epoch differ from A's original (root-a, created-1) —
        // beginning C's incarnation is a TRUE rotation: it purges every
        // control-sourced buffered event (A's open AND A's owner terminal),
        // leaving exactly C's own fresh open.
        let afterC = hub.fetch(workspaceID: "workspace-1", sessionID: "app", limit: 10)
        XCTAssertEqual(afterC.events.count, 1,
                       "the true rotation purges A's leftover open+terminal; only C's own open remains")
        let cEvent = afterC.events.first
        XCTAssertEqual(cEvent?.metadata?["working_phase"], "open")
        XCTAssertEqual(cEvent?.metadata?["turn_id"], "turn-c1")
        guard let cSeq = cEvent?.seq else {
            return XCTFail("missing C seq")
        }
        XCTAssertGreaterThan(cSeq, aTerminalSeq,
                             "C's seq must be strictly greater than A's owner-terminal seq — storedSeqHighWater is never rolled back by a purge")

        let snapshotC = hub.appServerControlDebugSnapshotForTesting(sessionID: "app")
        XCTAssertEqual(snapshotC.currentLogicalTurn?.turnID, "turn-c1")
        XCTAssertNil(snapshotC.suspendedLogicalTurn)
        XCTAssertFalse(snapshotC.activeOwners.isEmpty)
        XCTAssertEqual(snapshotC.latestSnapshot?.eventID, cEvent?.eventID)

        // 5. A/C stale isolation.
        controlA(.turnStarted(threadID: "thread-a", turnID: "turn-1", time: "t8"))
        XCTAssertEqual(hub.fetch(workspaceID: "workspace-1", sessionID: "app", limit: 10).events.count, 1)
    }

    // P0: raw-wire proof through the REAL default AttachHandler — NOT a
    // custom injected Syncer `AttachHandler` that directly hands back a
    // captured `onWorkingControl`. That shortcut would false-green if
    // `factory.attach`, `CodexAppServerConnection`, or
    // `CodexAppServerHeadlessRuntime`'s own onWorkingControl wiring were
    // ever broken or removed — this test exercises every one of those
    // layers by feeding raw notification JSON through the fake transport,
    // exactly as a real app-server socket would.
    func testRawWireLiveNotificationsReachHubAsControlEventsThroughRealAttachFactory() throws {
        let hub = AgentEventHub()
        let runner = FakeCodexAppServerProcessRunner()
        let connector = FakeCodexAppServerTransportConnector()
        let factory = CodexAppServerRuntimeSessionFactory(processRunner: runner, transportConnector: connector)
        let sidebarLock = NSLock()
        var sidebarMessages = [String]()
        // A custom SERIAL sidebar queue, injected explicitly, so this test
        // can `sync {}` a genuine drain afterward instead of polling —
        // `waitUntil { count >= 3 }` alone would false-green if a mutant
        // queued a 4th sidebar send that just hadn't executed yet by the
        // time the count first reached 3.
        let sidebarQueue = DispatchQueue(label: "test.sidebar.raw-wire")
        // No custom `attachHandler:` — the REAL default, which calls
        // `factory.attach(...)`.
        let syncer = CodexAppServerRegistryRuntimeSyncer(eventHub: hub,
                                                        factory: factory,
                                                        sidebarMessageSender: { message in
                                                            sidebarLock.lock()
                                                            sidebarMessages.append(message)
                                                            sidebarLock.unlock()
                                                        },
                                                        sidebarQueue: sidebarQueue)

        syncer.sync(records: [
            Self.record(sessionID: "app", runtime: "codex_app_server", socketPath: "/tmp/app.sock", threadID: "thread-1"),
        ])

        let transport = try XCTUnwrap(connector.transport)
        let initialize = try Self.rawObject(from: try XCTUnwrap(transport.sentLines().first))
        XCTAssertEqual(initialize["method"]?.stringValue, "initialize")
        transport.emitLine(try Self.rawResponseText(id: try XCTUnwrap(initialize["id"]),
                                                     result: .object([
                                                        "serverInfo": .object(["name": .string("codex"), "version": .string("test")]),
                                                        "capabilities": .object([:]),
                                                     ])))

        // Root turn/started — must reach the Hub as a control "open", with
        // NO card payload fields populated.
        transport.emitLine(#"""
        {"method":"turn/started","params":{"threadId":"thread-1","turn":{"id":"turn-1"}}}
        """#)
        // Allowlisted internal activity (collabAgentToolCall) — control
        // continuation, no card.
        transport.emitLine(#"""
        {"method":"item/started","params":{"threadId":"thread-1","turnId":"turn-1","startedAtMs":1,"item":{"type":"collabAgentToolCall","id":"item-1","tool":"wait","status":"inProgress","senderThreadId":"thread-1","receiverThreadIds":["thread-2"],"agentsStates":{}}}}
        """#)
        // An ORDINARY item — must NOT produce any control event, and (per
        // `testAttachedRuntimeDoesNotPublishConversationEventsToHub`)
        // ordinary app-server conversation events never reach the Hub via
        // publish at all — proving this new control seam did not divert
        // the normal path.
        transport.emitLine(#"""
        {"method":"item/completed","params":{"threadId":"thread-1","turnId":"turn-1","item":{"type":"commandExecution","id":"cmd-1","command":"swift test","cwd":"/tmp","processId":"proc-1","source":"agent","status":"completed","commandActions":[],"aggregatedOutput":"ok","exitCode":0,"durationMs":42}}}
        """#)
        // Terminal.
        transport.emitLine(#"""
        {"method":"turn/completed","params":{"threadId":"thread-1","turn":{"id":"turn-1","status":"completed"}}}
        """#)

        let fetched = hub.fetch(workspaceID: "workspace-1", sessionID: "app", limit: 10)
        let controlEvents = fetched.events.filter { $0.metadata?["source"] == "codex_app_server_working_control" }
        XCTAssertEqual(fetched.events.count, controlEvents.count, "no non-control event (e.g. the ordinary commandExecution card) ever reaches the Hub for an app-server session")

        for event in controlEvents {
            XCTAssertNil(event.text)
            XCTAssertNil(event.name)
            XCTAssertNil(event.input)
            XCTAssertNil(event.output)
            XCTAssertNil(event.toolCallID)
            XCTAssertNil(event.role)
            XCTAssertNil(event.payload, "a typed control event must never carry a card payload — mutation-killer for accidentally routing it through the ordinary card constructor")
        }

        guard controlEvents.count == 3 else {
            return XCTFail("expected exactly [open, continue, terminal] — the turnStarted open, the collabAgentToolCall activity continuation, and the terminal — got \(controlEvents.count)")
        }
        let openEvent = controlEvents[0]
        let continueEvent = controlEvents[1]
        let terminalEvent = controlEvents[2]

        XCTAssertEqual(openEvent.metadata?["working_phase"], "open")
        XCTAssertEqual(openEvent.metadata?["turn_id"], "turn-1")

        XCTAssertEqual(continueEvent.metadata?["working_phase"], "continue")
        XCTAssertEqual(continueEvent.metadata?["turn_id"], "turn-1")
        XCTAssertEqual(continueEvent.metadata?["reason"], "internal_activity")
        XCTAssertEqual(continueEvent.metadata?["activity_id"], "item-1")
        XCTAssertEqual(continueEvent.metadata?["kind"], "collabAgentToolCall")

        XCTAssertEqual(terminalEvent.metadata?["working_phase"], "terminal")
        XCTAssertEqual(terminalEvent.metadata?["turn_id"], "turn-1")

        // Sequence-cursor mutation-killer: `nextSyntheticSeq` is the SAME
        // shared cursor the ordinary Headless `makeEvent`/`onAgentEvent`
        // path reserves from on every notification it processes — even for
        // an item type with no card (collabAgentToolCall never calls
        // `makeEvent`, so open->continue must be strictly adjacent), and
        // even though the resulting ordinary event is never itself
        // published to the Hub (app-server conversation events aren't).
        // The commandExecution item/completed AND turn/completed's own
        // ordinary event each still reserve a seq before the typed
        // terminal is stored, so continue->terminal must skip more than
        // one. If Headless's ordinary `makeEvent`/`onAgentEvent` call were
        // ever deleted while leaving the typed control seam intact, both
        // gaps below would collapse to a uniform +1 and this would fail.
        XCTAssertEqual(continueEvent.seq, openEvent.seq + 1,
                       "collabAgentToolCall's item/started has no ordinary card — open and continue must be exactly adjacent")
        XCTAssertGreaterThan(terminalEvent.seq - continueEvent.seq, 1,
                             "the ordinary commandExecution card AND turn/completed's own ordinary event must each have reserved a seq between continue and terminal")

        // Ordinary path proof: app-server conversation events never enter
        // the Hub (confirmed above via `fetched.events.count ==
        // controlEvents.count`), but they DO still reach the sidebar —
        // proving Headless's ordinary `onAgentEvent` -> `handleSidebarEvent`
        // path actually ran, unaffected by the new control seam. Only
        // `turn/started` (-> "running") and `turn/completed` (->
        // notification + "prompt") map to sidebar sends;
        // `commandExecution`'s `item/completed` matches none of
        // `handleSidebarEventOnQueue`'s cases and sends nothing — the
        // ordinary path for THAT item is proven by the seq gap above, not
        // by a sidebar message.
        // A genuine drain — not a poll-until-count — of the injected
        // serial sidebar queue: every `handleSidebarEvent` dispatch already
        // queued by the raw lines above is guaranteed to have fully run by
        // the time this returns, so the snapshot below is not vulnerable
        // to a mutant that queues an extra (4th) send that just hadn't
        // executed yet at the moment an earlier poll first observed 3.
        sidebarQueue.sync {}
        sidebarLock.lock()
        let finalSidebarMessages = sidebarMessages
        sidebarLock.unlock()
        guard finalSidebarMessages.count == 3 else {
            return XCTFail("expected exactly 3 sidebar messages (running, notification.create, prompt), got \(finalSidebarMessages)")
        }
        XCTAssertEqual(finalSidebarMessages[0], "report_shell_state running --workspace_id=workspace-1")
        XCTAssertTrue(finalSidebarMessages[1].contains(#""action":"notification.create""#))
        XCTAssertTrue(finalSidebarMessages[1].contains(#""title":"Codex""#))
        XCTAssertTrue(finalSidebarMessages[1].contains(#""body":"Task completed""#))
        XCTAssertEqual(finalSidebarMessages[2], "report_shell_state prompt --workspace_id=workspace-1")
    }

    // MARK: - Runtime E: real Syncer + real RuntimeSession replacement teardown

    // P0: the REAL `CodexAppServerRegistryRuntimeSyncer`, the REAL
    // `CodexAppServerRuntimeSessionFactory.attach`, and the REAL
    // `CodexAppServerRuntimeSession.finish` barrier, wired together over raw
    // fake transports — proving that while an INTERNAL finish winner (A's
    // transport closing) has not yet fully delivered A's owner terminal AND
    // expired A's pending prompt, a CONCURRENT replacement's public `stop()`
    // loser genuinely BLOCKS, and generation B is never attached (never
    // begins/resumes/opens) until that teardown is complete.
    //
    // The pause points are the REAL Syncer-supplied `onWorkingControl`/
    // `onInteractivePromptResolved` callbacks themselves (wrapped so the
    // wrapper pauses only AFTER forwarding to the genuine callback and
    // letting it fully RETURN) — not `finishTeardownPauseHook` and not any
    // Hub/Syncer-internal hook. Pausing before those real callbacks return
    // would only prove `forwardLock` contention, not that the loser reached
    // `session.stop()` itself.
    func testRealSyncerRealRuntimeReplacementWaitsForInternalWinnerTeardownBeforeBAttaches() throws {
        let hub = AgentEventHub()
        let runner = FakeCodexAppServerProcessRunner()
        let connector = FakeCodexAppServerTransportConnector()
        let factory = CodexAppServerRuntimeSessionFactory(processRunner: runner, transportConnector: connector)

        let log = OrderedTestEventLog()
        let attachCountLock = NSLock()
        var attachCount = 0
        // Every read of `attachCount` — including the two one-off checks
        // right after each `sync()` call — goes through this single
        // lock-protected snapshot, not a bare read, even where a `sync()`
        // call or `DispatchGroup` wait already establishes a happens-before
        // relationship: one lock-protected access pattern for the whole
        // test, no case-by-case reasoning about which reads are "safe".
        func currentAttachCount() -> Int {
            attachCountLock.lock()
            defer { attachCountLock.unlock() }
            return attachCount
        }
        let transportsLock = NSLock()
        var capturedTransports: [FakeCodexAppServerConnectionTransport] = []

        let ownerForwarded = DispatchSemaphore(value: 0)
        let ownerPause = DispatchSemaphore(value: 0)
        let promptForwarded = DispatchSemaphore(value: 0)
        let promptPause = DispatchSemaphore(value: 0)
        let stopEntered = DispatchSemaphore(value: 0)
        let stopReturned = DispatchSemaphore(value: 0)
        let bAttachEntered = DispatchSemaphore(value: 0)
        // `DispatchGroup`, not a single-use `DispatchSemaphore`: both the
        // early-return safety net below AND the normal path's own
        // completion check must be able to wait for the SAME background
        // task without either side consuming a signal the other still
        // needs. `wait(timeout:)` is safely repeatable (including after the
        // group has already reached zero), unlike a semaphore signal.
        let winnerCompletion = DispatchGroup()
        let replacementCompletion = DispatchGroup()

        // Safety net: release BOTH pause points even on an early assertion
        // failure (so any paused background callback can proceed), THEN
        // bounded-wait for the winner and replacement background tasks to
        // actually finish — an early `return XCTFail(...)` above must never
        // leave either background thread still running past this test
        // function's return, where it would pollute a subsequent test.
        defer {
            ownerPause.signal()
            promptPause.signal()
            _ = winnerCompletion.wait(timeout: .now() + 5)
            _ = replacementCompletion.wait(timeout: .now() + 5)
        }

        let attachHandler: CodexAppServerRegistryRuntimeSyncer.AttachHandler = { record, epoch, nextSequence, timestampProvider, onAgentEvent, onInteractivePrompt, onInteractivePromptResolved, onActiveThreadID, onWorkingControl in
            attachCountLock.lock()
            attachCount += 1
            let isFirstAttach = (attachCount == 1)
            attachCountLock.unlock()

            if isFirstAttach == false {
                log.record("B-attach-entered")
                bAttachEntered.signal()
            }

            let wrappedOnWorkingControl: CodexAppServerHeadlessRuntime.WorkingControlHandler = { control in
                guard isFirstAttach, case .ownerDisconnected = control else {
                    onWorkingControl(control)
                    return
                }
                // Forward to the REAL Syncer-supplied handler and let it run
                // to completion (any `forwardLock` it takes internally is
                // released by the time this call returns) BEFORE pausing.
                onWorkingControl(control)
                log.record("A-owner-forwarded")
                ownerForwarded.signal()
                ownerPause.wait()
            }
            let wrappedOnInteractivePromptResolved: CodexAppServerConnection.InteractivePromptResolvedHandler = { event in
                guard isFirstAttach else {
                    onInteractivePromptResolved(event)
                    return
                }
                onInteractivePromptResolved(event)
                log.record("A-prompt-resolved-forwarded")
                promptForwarded.signal()
                promptPause.wait()
            }

            guard let socketPath = record.appServerSocket, let panelID = record.panelID else {
                throw BridgeInternalError.invalidRequest("Codex app-server registry record is missing socket or panel identity.")
            }
            let rawSession = try factory.attach(socketPath: socketPath,
                                                processID: record.appServerPID,
                                                context: CodexAppServerRuntimeContext(workspaceID: record.workspaceID,
                                                                                     panelID: panelID,
                                                                                     sessionID: record.sessionID),
                                                epoch: epoch,
                                                nextSequence: nextSequence,
                                                timestampProvider: timestampProvider,
                                                onAgentEvent: onAgentEvent,
                                                onInteractivePrompt: onInteractivePrompt,
                                                onInteractivePromptResolved: wrappedOnInteractivePromptResolved,
                                                onActiveThreadID: onActiveThreadID,
                                                onWorkingControl: wrappedOnWorkingControl)
            transportsLock.lock()
            if let transport = connector.transport {
                capturedTransports.append(transport)
            }
            transportsLock.unlock()

            guard isFirstAttach else {
                return rawSession
            }
            return StopInstrumentedRuntimeSessionDecorator(wrapping: rawSession,
                                                            onStopEntered: {
                                                                log.record("A-public-stop-entered")
                                                                stopEntered.signal()
                                                            },
                                                            onStopReturned: {
                                                                log.record("A-public-stop-returned")
                                                                stopReturned.signal()
                                                            })
        }

        let syncer = CodexAppServerRegistryRuntimeSyncer(eventHub: hub, attachHandler: attachHandler)

        // 1. Attach A.
        let record = Self.record(sessionID: "app", runtime: "codex_app_server", socketPath: "/tmp/app.sock", threadID: "thread-a")
        syncer.sync(records: [record])
        XCTAssertEqual(currentAttachCount(), 1)

        transportsLock.lock()
        let transportA = capturedTransports.first
        transportsLock.unlock()
        guard let transportA else {
            return XCTFail("attach A never captured its transport")
        }

        // 2. Raw initialize A; complete attach subscription (loaded/list ->
        // thread/resume with ZERO in-progress turns — the turn/started
        // notification below is what actually opens the control turn, not
        // an auto-seeded resume snapshot) so no client request is left
        // unprocessed before the precondition steps.
        let initializeA = try Self.rawObject(from: try XCTUnwrap(transportA.sentLines().first))
        XCTAssertEqual(initializeA["method"]?.stringValue, "initialize")
        transportA.emitLine(try Self.rawResponseText(id: try XCTUnwrap(initializeA["id"]), result: .object([
            "serverInfo": .object(["name": .string("codex"), "version": .string("test")]),
            "capabilities": .object([:]),
        ])))
        XCTAssertTrue(Self.waitUntil { transportA.sentLines().count >= 3 })
        let listLoadedA = try Self.rawObject(from: try XCTUnwrap(transportA.sentLines().dropFirst(2).first))
        XCTAssertEqual(listLoadedA["method"]?.stringValue, "thread/loaded/list")
        transportA.emitLine(try Self.rawResponseText(id: try XCTUnwrap(listLoadedA["id"]), result: .object([
            "threads": .array([
                .object(["id": .string("thread-a"), "preview": .string("p"), "updatedAt": .string("2026-06-07T00:00:00.000Z")]),
            ]),
        ])))
        XCTAssertTrue(Self.waitUntil { transportA.sentLines().count >= 4 })
        let resumeA = try Self.rawObject(from: try XCTUnwrap(transportA.sentLines().dropFirst(3).first))
        XCTAssertEqual(resumeA["method"]?.stringValue, "thread/resume")
        transportA.emitLine(try Self.rawResponseText(id: try XCTUnwrap(resumeA["id"]), result: .object([
            "thread": .object([
                "id": .string("thread-a"),
                "status": .object(["type": .string("idle")]),
                "turns": .array([]),
            ]),
        ])))

        // 3. Root turn/started for thread-a/turn-A — must reach the Hub as a
        // control "open". Then a legitimate pending approval request —
        // exactly 1 pending prompt at both the RuntimeSession and Hub level.
        transportA.emitLine(#"""
        {"method":"turn/started","params":{"threadId":"thread-a","turn":{"id":"turn-A"}}}
        """#)
        let afterAOpen = hub.fetch(workspaceID: "workspace-1", sessionID: "app", limit: 20)
        let controlEventsAfterAOpen = afterAOpen.events.filter { $0.metadata?["source"] == "codex_app_server_working_control" }
        guard controlEventsAfterAOpen.count == 1 else {
            return XCTFail("expected exactly 1 control open for turn-A, got \(controlEventsAfterAOpen.count)")
        }
        XCTAssertEqual(controlEventsAfterAOpen[0].metadata?["working_phase"], "open")
        XCTAssertEqual(controlEventsAfterAOpen[0].metadata?["turn_id"], "turn-A")

        transportA.emitLine(#"""
        {"id":"approval-1","method":"item/commandExecution/requestApproval","params":{"threadId":"thread-a","turnId":"turn-A","itemId":"item-1","startedAtMs":1786000000000,"command":"ls","cwd":"/tmp"}}
        """#)
        XCTAssertEqual(syncer.pendingApprovalPromptEvents(workspaceID: "workspace-1", sessionID: "app").count, 1,
                       "precondition: exactly 1 pending prompt at the Syncer/RuntimeSession level")
        let promptOpenersAfterRequest = hub.fetch(workspaceID: "workspace-1", sessionID: "app", limit: 20).events.filter { $0.type == .interactivePrompt }
        guard promptOpenersAfterRequest.count == 1, let openerPromptID = promptOpenersAfterRequest[0].metadata?["prompt_id"] else {
            return XCTFail("precondition: exactly 1 prompt opener with a prompt_id must reach the Hub, got \(promptOpenersAfterRequest.count)")
        }

        // 4. WINNER: a real internal trigger (transport close), on a
        // background thread. Wait for it to reach the pause point: A's
        // owner terminal has been FULLY forwarded through the real Syncer
        // callback and delivered to the Hub, but `connection.close()` (and
        // thus `controlTeardownComplete`) has not run yet.
        winnerCompletion.enter()
        DispatchQueue.global().async {
            transportA.emitClose(nil)
            winnerCompletion.leave()
        }
        XCTAssertEqual(ownerForwarded.wait(timeout: .now() + 5), .success,
                       "the winner must reach the pause point: A's owner terminal fully forwarded and delivered")

        // 5. Concurrent replacement, on a DIFFERENT background thread. Wait
        // until the decorator observes `stop()` genuinely ENTERED — proving
        // the replacement already passed `forwardLock`, removed the old
        // entry, and reached the real public-stop loser call.
        replacementCompletion.enter()
        DispatchQueue.global().async {
            syncer.sync(records: [record])
            replacementCompletion.leave()
        }
        XCTAssertEqual(stopEntered.wait(timeout: .now() + 5), .success,
                       "the replacement must reach session.stop() (the loser call) before this test proceeds")

        // 6. During the owner-terminal pause window: the loser must NOT
        // have returned yet, and B must not have attached.
        XCTAssertEqual(stopReturned.wait(timeout: .now() + 0.3), .timedOut,
                       "the public stop() loser must still be blocked while the winner's owner terminal is paused mid-teardown")
        XCTAssertEqual(currentAttachCount(), 1, "B must not have attached while A's teardown is still paused")
        XCTAssertEqual(bAttachEntered.wait(timeout: .now() + 0.3), .timedOut, "B's attach entrance must not have signaled yet")

        // 7. Release the owner pause. The winner proceeds into
        // `connection.close()`, which synchronously expires A's pending
        // prompt — wait for that resolution to be FULLY forwarded through
        // the real Syncer callback and delivered to the Hub.
        ownerPause.signal()
        XCTAssertEqual(promptForwarded.wait(timeout: .now() + 5), .success,
                       "the winner must reach the second pause point: A's prompt-resolved fully forwarded and delivered")

        // 8. During the prompt-resolved pause window: still blocked, still
        // no B attach — and the Hub must show A's owner terminal BEFORE A's
        // prompt resolved, each exactly once.
        XCTAssertEqual(stopReturned.wait(timeout: .now() + 0.3), .timedOut,
                       "the public stop() loser must still be blocked while the winner's prompt-resolved is paused mid-teardown")
        XCTAssertEqual(currentAttachCount(), 1, "B must still not have attached while A's teardown is still paused")
        XCTAssertEqual(bAttachEntered.wait(timeout: .now() + 0.3), .timedOut, "B's attach entrance must still not have signaled")

        let duringPromptPauseFetch = hub.fetch(workspaceID: "workspace-1", sessionID: "app", limit: 20)
        let ownerTerminalsDuringPromptPause = duringPromptPauseFetch.events.filter { $0.metadata?["terminal_scope"] == "owner" }
        let promptResolvedDuringPromptPause = duringPromptPauseFetch.events.filter { $0.type == .interactivePromptResolved }
        guard ownerTerminalsDuringPromptPause.count == 1, promptResolvedDuringPromptPause.count == 1 else {
            return XCTFail("expected exactly 1 owner terminal and 1 prompt resolved by this point, got \(ownerTerminalsDuringPromptPause.count) / \(promptResolvedDuringPromptPause.count)")
        }
        XCTAssertLessThan(ownerTerminalsDuringPromptPause[0].seq, promptResolvedDuringPromptPause[0].seq,
                          "A's owner terminal must be delivered strictly before A's prompt resolved, matching finish()'s own ordering")
        // Locks the integration itself to the INTERNAL transport-close
        // winner and the correct logical turn — not merely relying on a
        // separate unit test elsewhere to have proven the reason mapping.
        XCTAssertEqual(ownerTerminalsDuringPromptPause[0].metadata?["reason"], "transport_closed",
                       "A's owner terminal must be attributed to the internal transport-close winner, not e.g. a session_retired stop()")
        XCTAssertEqual(ownerTerminalsDuringPromptPause[0].metadata?["turn_id"], "turn-A")
        // Proves the second pause is genuinely `connection.close()` expiring
        // A's still-pending prompt — not some other resolved-terminal path.
        XCTAssertEqual(promptResolvedDuringPromptPause[0].metadata?["reason"], "expired",
                       "the prompt-resolved event during the second pause must be the connection.close()-driven expiry")
        // The SAME pending lifecycle opened in step 3, not some unrelated
        // resolved event.
        XCTAssertEqual(promptResolvedDuringPromptPause[0].metadata?["prompt_id"], openerPromptID,
                       "the expired resolution must be for the exact same prompt_id the opener established")
        // 9. Release the prompt pause. From here the deterministic order
        // must be: winner teardown completes -> public stop() loser returns
        // -> B's attach entrance -> the replacement sync() call returns.
        promptPause.signal()
        XCTAssertEqual(winnerCompletion.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(stopReturned.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(bAttachEntered.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(replacementCompletion.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(currentAttachCount(), 2)

        // "A-public-stop-entered" lands between owner-forwarded and
        // prompt-resolved-forwarded because step 5 explicitly waited for it
        // (via `stopEntered`) before this test proceeded to release the
        // owner pause — a stronger, still fully deterministic ordering than
        // the minimal 4-marker chain, since it also pins exactly when the
        // loser reached `session.stop()` relative to the two forwarded
        // callbacks.
        XCTAssertEqual(log.snapshot(), [
            "A-owner-forwarded",
            "A-public-stop-entered",
            "A-prompt-resolved-forwarded",
            "A-public-stop-returned",
            "B-attach-entered",
        ])

        let beforeBResumeCount = hub.fetch(workspaceID: "workspace-1", sessionID: "app", limit: 20).events.count

        // 10. Raw initialize B; loaded/list returns the SAME root
        // (same-incarnation reattach); thread/resume returns EXACTLY ONE
        // in-progress turn — turn-A, NOT a fresh turn-B, since this is the
        // same suspended trajectory A's own teardown left behind (the Hub
        // rejects a `.resumeSnapshot` for a different turn ID once a
        // trajectory is suspended).
        transportsLock.lock()
        let transportB = capturedTransports.count > 1 ? capturedTransports[1] : nil
        transportsLock.unlock()
        guard let transportB else {
            return XCTFail("attach B never captured its transport")
        }
        let initializeB = try Self.rawObject(from: try XCTUnwrap(transportB.sentLines().first))
        XCTAssertEqual(initializeB["method"]?.stringValue, "initialize")
        transportB.emitLine(try Self.rawResponseText(id: try XCTUnwrap(initializeB["id"]), result: .object([
            "serverInfo": .object(["name": .string("codex"), "version": .string("test")]),
            "capabilities": .object([:]),
        ])))
        XCTAssertTrue(Self.waitUntil { transportB.sentLines().count >= 3 })
        let listLoadedB = try Self.rawObject(from: try XCTUnwrap(transportB.sentLines().dropFirst(2).first))
        XCTAssertEqual(listLoadedB["method"]?.stringValue, "thread/loaded/list")
        transportB.emitLine(try Self.rawResponseText(id: try XCTUnwrap(listLoadedB["id"]), result: .object([
            "threads": .array([
                .object(["id": .string("thread-a"), "preview": .string("p"), "updatedAt": .string("2026-06-07T00:00:00.000Z")]),
            ]),
        ])))
        XCTAssertTrue(Self.waitUntil { transportB.sentLines().count >= 4 })
        let resumeB = try Self.rawObject(from: try XCTUnwrap(transportB.sentLines().dropFirst(3).first))
        XCTAssertEqual(resumeB["method"]?.stringValue, "thread/resume")

        XCTAssertEqual(hub.fetch(workspaceID: "workspace-1", sessionID: "app", limit: 20).events.count, beforeBResumeCount,
                       "no B control may reach the Hub before B's own resume response arrives")

        transportB.emitLine(try Self.rawResponseText(id: try XCTUnwrap(resumeB["id"]), result: .object([
            "thread": .object([
                "id": .string("thread-a"),
                "status": .object(["type": .string("active"), "activeFlags": .array([.string("turn")])]),
                "turns": .array([.object(["id": .string("turn-A"), "status": .string("inProgress")])]),
            ]),
        ])))

        let finalFetch = hub.fetch(workspaceID: "workspace-1", sessionID: "app", limit: 20)
        guard finalFetch.events.count == beforeBResumeCount + 1 else {
            return XCTFail("B's exact resume of the suspended turn must add exactly one control open, got \(finalFetch.events.count - beforeBResumeCount)")
        }
        let bOpenEvent = finalFetch.events.last!
        XCTAssertEqual(bOpenEvent.metadata?["working_phase"], "open")
        XCTAssertEqual(bOpenEvent.metadata?["reason"], "resume_snapshot")
        XCTAssertEqual(bOpenEvent.metadata?["turn_id"], "turn-A")
        XCTAssertGreaterThan(bOpenEvent.seq, ownerTerminalsDuringPromptPause[0].seq)
        XCTAssertGreaterThan(bOpenEvent.seq, promptResolvedDuringPromptPause[0].seq)

        // A's owner terminal and prompt resolved remain exactly one each —
        // no duplicate cleanup from either the winner's own completion or
        // the replacement's loser return.
        let ownerTerminalsFinal = finalFetch.events.filter { $0.metadata?["terminal_scope"] == "owner" }
        let promptResolvedFinal = finalFetch.events.filter { $0.type == .interactivePromptResolved }
        guard ownerTerminalsFinal.count == 1, promptResolvedFinal.count == 1 else {
            return XCTFail("expected exactly 1 owner terminal and 1 prompt resolved in the final snapshot, got \(ownerTerminalsFinal.count) / \(promptResolvedFinal.count)")
        }
        XCTAssertEqual(ownerTerminalsFinal[0].metadata?["reason"], "transport_closed")
        XCTAssertEqual(ownerTerminalsFinal[0].metadata?["turn_id"], "turn-A")
        XCTAssertEqual(promptResolvedFinal[0].metadata?["reason"], "expired")
    }

    // P0: a fresh owner B's FIRST-EVER observation is an EXACT DUPLICATE
    // activity edge A already admitted (same root/turn/item/kind — only
    // `time` differs). The Hub dedupes the edge itself (same `eventID`
    // regardless of which owner observed it) and returns accepted + ZERO
    // events, but its `ownerContextEffect` is still `.setOwner(B)` — the
    // Syncer must record that mapping even though `admission.events.isEmpty`.
    // Proven via A/B disconnect ORDERING, not by reading Hub `activeOwners`
    // alone: `activeOwners` is populated straight from the Hub's own
    // admission bookkeeping and would show B as active even if the SYNCER's
    // own `ownerContext.currentLogicalTurn` mapping were never updated — only
    // B's own later disconnect finding (or failing to find) a mapping to
    // retire actually distinguishes the two.
    func testAcceptedZeroWireDuplicateActivityEdgeFromFreshOwnerStillSetsOwnerMapping() throws {
        let hub = AgentEventHub()
        var controls = [CodexAppServerHeadlessRuntime.WorkingControlHandler]()
        var runtimes = [FakeRuntimeSession]()
        let sameRecord = Self.record(sessionID: "app", runtime: "codex_app_server", socketPath: "/tmp/app.sock",
                                     threadID: "thread-a", createdAt: "2026-01-01T00:00:00Z")
        // Same race-closing device as `testSameIncarnationTwoOwnersAcceptedZeroWireStillRecordsMappingAndOnlyLastDisconnectTerminals`:
        // A's generation must remain in `retiringGenerations` until this test
        // explicitly releases the blocked sidebar queue, so A's own
        // disconnect below is not rejected as stale before this test can
        // observe its (correctly) 0-terminal outcome.
        let sidebarQueue = DispatchQueue(label: "test.sidebar.duplicate-activity-owner-mapping")
        let cleanupBlocker = DispatchSemaphore(value: 0)
        // Safety net: an early `return` from any guard below must not leave
        // the blocked sidebarQueue worker permanently parked. A duplicate
        // signal alongside the explicit release further down is harmless.
        defer { cleanupBlocker.signal() }
        sidebarQueue.async { cleanupBlocker.wait() }
        let syncer = CodexAppServerRegistryRuntimeSyncer(eventHub: hub,
                                                        sidebarQueue: sidebarQueue,
                                                        attachHandler: { _, _, _, _, _, _, _, _, onWorkingControl in
            controls.append(onWorkingControl)
            let runtime = FakeRuntimeSession()
            runtimes.append(runtime)
            // `onStop` deliberately left nil: A's `stop()` (driven by the
            // same-incarnation reattach below) must NOT itself synthesize an
            // ownerDisconnected — this test drives A's disconnect explicitly,
            // on its own schedule, to observe the non-last-owner outcome.
            return runtime
        })

        // 2. A: turnStarted + internalActivityStarted on the same root/turn.
        syncer.sync(records: [sameRecord])
        guard controls.count == 1, runtimes.count == 1, let controlA = controls.first else {
            return XCTFail("generation A never captured onWorkingControl")
        }
        controlA(.turnStarted(threadID: "thread-a", turnID: "turn-1", time: "t1"))
        controlA(.internalActivityStarted(threadID: "thread-a", turnID: "turn-1", itemID: "item-1", kind: .collabAgentToolCall, time: "t2"))
        let afterAActivity = hub.fetch(workspaceID: "workspace-1", sessionID: "app", limit: 10)
        guard afterAActivity.events.count == 2 else {
            return XCTFail("expected exactly 2 control edges (open + activity) for A, got \(afterAActivity.events.count)")
        }
        XCTAssertEqual(afterAActivity.events[0].metadata?["working_phase"], "open")
        XCTAssertEqual(afterAActivity.events[1].metadata?["working_phase"], "continue")
        XCTAssertEqual(afterAActivity.events[1].metadata?["reason"], "internal_activity")
        let countAfterAActivity = afterAActivity.events.count
        let newestSeqAfterAActivity = afterAActivity.events[1].seq
        // A's own owner key, captured while A is still the ONLY owner — the
        // exact set to diff against once B joins, so "the owner remaining
        // after A disconnects" can be asserted precisely rather than merely
        // by count.
        let ownerKeysWithOnlyA = hub.appServerControlDebugSnapshotForTesting(sessionID: "app").activeOwners
        guard ownerKeysWithOnlyA.count == 1 else {
            return XCTFail("expected exactly 1 active owner (A) before B attaches, got \(ownerKeysWithOnlyA.count)")
        }

        // 3. Same-incarnation reattach: transport died, everything else
        // identical — Hub incarnation is preserved, so the current logical
        // turn is still turn-1 when B attaches. A's generation becomes
        // "retiring" but its sidebarQueue-async cleanup is blocked until
        // this test releases it.
        runtimes[0].stopped = true
        syncer.sync(records: [sameRecord])
        guard controls.count == 2, runtimes.count == 2, let controlB = controls.last else {
            return XCTFail("generation B never captured onWorkingControl")
        }

        // 4. B's FIRST-EVER control observation is the EXACT SAME activity
        // edge A already admitted (same root/turn/item/kind; only `time`
        // differs) — must be accepted, ZERO new events, and ZERO cursor
        // movement.
        controlB(.internalActivityStarted(threadID: "thread-a", turnID: "turn-1", itemID: "item-1", kind: .collabAgentToolCall, time: "t3"))
        let afterBDuplicate = hub.fetch(workspaceID: "workspace-1", sessionID: "app", limit: 10)
        XCTAssertEqual(afterBDuplicate.events.count, countAfterAActivity,
                       "B's exact-duplicate activity edge must be 0 wire (the Hub dedupes on the SAME eventID regardless of which owner observed it)")
        XCTAssertEqual(afterBDuplicate.events.last?.seq, newestSeqAfterAActivity,
                       "B's exact-duplicate activity edge must move 0 cursor")
        // The `fetch` contract's own cursor field, not just the last
        // element's seq — `newestSeq` is what a real client cursors on.
        XCTAssertEqual(afterBDuplicate.newestSeq, afterAActivity.newestSeq,
                       "B's exact-duplicate activity edge must move 0 cursor on the fetch contract's own newestSeq field")

        // Precondition only — NOT the mapping proof. `activeOwners` reflects
        // the Hub's OWN admission bookkeeping (`state.appServerActiveOwners.insert(ownerKey)`
        // happens unconditionally on acceptance, before the caller even sees
        // `ownerContextEffect`) — it would show B as active even if the
        // Syncer's own mapping update were the thing that was broken.
        let afterBObservation = hub.appServerControlDebugSnapshotForTesting(sessionID: "app")
        XCTAssertEqual(afterBObservation.activeOwners.count, 2, "precondition: both A and B recorded as active owners")
        let ownerKeyForB = afterBObservation.activeOwners.subtracting(ownerKeysWithOnlyA)
        guard ownerKeyForB.count == 1 else {
            return XCTFail("expected exactly 1 owner key added by B's observation, got \(ownerKeyForB.count)")
        }

        // 5. A disconnects — still "retiring" (cleanup still blocked), so
        // the Syncer's current-or-retiring fence still admits it. NOT the
        // last owner (B remains) — 0 terminal.
        controlA(.ownerDisconnected(reason: .transportClosed, time: "t4"))
        XCTAssertEqual(hub.fetch(workspaceID: "workspace-1", sessionID: "app", limit: 10).events.count, countAfterAActivity,
                       "A's disconnect must produce 0 terminal while B (the other owner) remains")
        // A genuinely retired, and specifically ONLY B remains — not merely
        // "some owner still present".
        let afterADisconnectSnapshot = hub.appServerControlDebugSnapshotForTesting(sessionID: "app")
        XCTAssertEqual(afterADisconnectSnapshot.activeOwners.count, 1, "only B's owner must remain after A's disconnect")
        XCTAssertEqual(afterADisconnectSnapshot.activeOwners, ownerKeyForB,
                       "the remaining owner after A's disconnect must be exactly B's owner key, not merely count 1")

        // Only now release the blocked cleanup and drain it — A's disconnect
        // has already synchronously completed above, so this ordering can no
        // longer affect it either way.
        cleanupBlocker.signal()
        sidebarQueue.sync {}

        // 6. B disconnects: now the LAST owner — exactly one terminal. This
        // ONLY happens if the Syncer genuinely recorded B's `.setOwner`
        // mapping from its zero-wire duplicate-activity admission in step 4
        // — otherwise `ownerContext.currentLogicalTurn` is still nil for B,
        // `handleWorkingControlOwnerDisconnected` finds nothing to retire,
        // and this assertion goes red (mutation-kill for a Syncer that
        // wrongly gates the mapping update on `admission.events.isEmpty`).
        controlB(.ownerDisconnected(reason: .transportClosed, time: "t5"))
        let afterBDisconnect = hub.fetch(workspaceID: "workspace-1", sessionID: "app", limit: 10)
        XCTAssertEqual(afterBDisconnect.events.count, countAfterAActivity + 1,
                       "B's disconnect, as the last owner, must produce exactly one owner terminal")
        let ownerTerminals = afterBDisconnect.events.filter { $0.metadata?["terminal_scope"] == "owner" }
        guard ownerTerminals.count == 1 else {
            return XCTFail("expected exactly 1 owner terminal, appearing only after B's disconnect, got \(ownerTerminals.count)")
        }
        // Exact turn/root/reason — not merely "a terminal happened".
        XCTAssertEqual(ownerTerminals[0].metadata?["turn_id"], "turn-1")
        XCTAssertEqual(ownerTerminals[0].metadata?["root_thread_id"], "thread-a")
        XCTAssertEqual(ownerTerminals[0].metadata?["reason"], "transport_closed")
        XCTAssertEqual(afterBDisconnect.events.last?.eventID, ownerTerminals[0].eventID,
                       "the owner terminal must be the newest event — it did not exist before B's disconnect")
        // No legitimate reservation exists anywhere in this fixture between
        // A's activity and B's terminal — the cursor must have advanced by
        // EXACTLY one. A hypothetical bug that reserves a seq without
        // leaving a retrievable event (an "unretained cursor advance") would
        // still pass a bare `events.last?.seq` check but fail this exact
        // arithmetic.
        XCTAssertEqual(ownerTerminals[0].seq, newestSeqAfterAActivity + 1,
                       "B's owner terminal must be the very next seq after A's activity continuation, with no unretained cursor advance in between")
        let finalSnapshot = hub.appServerControlDebugSnapshotForTesting(sessionID: "app")
        XCTAssertTrue(finalSnapshot.activeOwners.isEmpty)
        XCTAssertNil(finalSnapshot.currentLogicalTurn)
    }

    // MARK: - Syncer ownerContextEffect matrix

    // P0: a start admitted while a prompt is active is HIDDEN (accepted,
    // 0 wire) — but the Syncer's own attach-scoped mapping must still be
    // set via `.setOwner`. Proof: a later disconnect (still while the
    // prompt is active) must still produce a real owner-scoped terminal —
    // impossible unless the hidden open's mapping was genuinely recorded.
    func testPromptHiddenAcceptedStartStillSetsOwnerMappingAndDisconnectProducesOwnerTerminal() throws {
        let hub = AgentEventHub()
        var control: CodexAppServerHeadlessRuntime.WorkingControlHandler?
        let envelope = Self.approvalEnvelope(sessionID: "app")
        let syncer = CodexAppServerRegistryRuntimeSyncer(eventHub: hub, attachHandler: { _, _, _, _, _, onInteractivePrompt, _, _, onWorkingControl in
            control = onWorkingControl
            // Staged (and thus committed) BEFORE any control observation —
            // the prompt is already active when the turnStarted below runs.
            onInteractivePrompt(envelope)
            return FakeRuntimeSession()
        })
        syncer.sync(records: [
            Self.record(sessionID: "app", runtime: "codex_app_server", socketPath: "/tmp/app.sock", threadID: "thread-a"),
        ])
        guard let control else {
            return XCTFail("attach never captured onWorkingControl")
        }

        control(.turnStarted(threadID: "thread-a", turnID: "turn-1", time: "t1"))
        let afterOpen = hub.fetch(workspaceID: "workspace-1", sessionID: "app", limit: 10)
        XCTAssertTrue(afterOpen.events.filter { $0.metadata?["source"] == "codex_app_server_working_control" }.isEmpty,
                      "the open must be hidden (accepted, 0 wire) while the prompt is active")

        control(.ownerDisconnected(reason: .transportClosed, time: "t2"))
        let afterDisconnect = hub.fetch(workspaceID: "workspace-1", sessionID: "app", limit: 10)
        let ownerTerminals = afterDisconnect.events.filter { $0.metadata?["terminal_scope"] == "owner" }
        XCTAssertEqual(ownerTerminals.count, 1,
                       "the disconnect must still retire the mapping the hidden open established — impossible unless .setOwner was genuinely recorded despite 0 wire")
        XCTAssertEqual(ownerTerminals.first?.metadata?["turn_id"], "turn-1")
    }

    // P0: an authoritative start B supersedes A (tombstoning A). A late
    // terminal for A must `.clearIfMatching(A)` — a no-op against B's
    // mapping, since the Syncer only clears its OWN mapping if it still
    // points at the EXACT logical key being terminated. The subsequent
    // disconnect must retire B, not A.
    func testLateTerminalAClearIfMatchingDoesNotClearMappingBAndDisconnectRetiresB() throws {
        let hub = AgentEventHub()
        var control: CodexAppServerHeadlessRuntime.WorkingControlHandler?
        let syncer = CodexAppServerRegistryRuntimeSyncer(eventHub: hub, attachHandler: { _, _, _, _, _, _, _, _, onWorkingControl in
            control = onWorkingControl
            return FakeRuntimeSession()
        })
        syncer.sync(records: [
            Self.record(sessionID: "app", runtime: "codex_app_server", socketPath: "/tmp/app.sock", threadID: "thread-a"),
        ])
        guard let control else {
            return XCTFail("attach never captured onWorkingControl")
        }

        control(.turnStarted(threadID: "thread-a", turnID: "turn-A", time: "t1"))
        control(.turnStarted(threadID: "thread-a", turnID: "turn-B", time: "t2"))
        XCTAssertEqual(hub.appServerControlDebugSnapshotForTesting(sessionID: "app").currentLogicalTurn?.turnID, "turn-B")

        // A late terminal for the now-superseded A.
        control(.turnTerminal(threadID: "thread-a", turnID: "turn-A", rawStatus: "completed", time: "t3"))
        XCTAssertEqual(hub.appServerControlDebugSnapshotForTesting(sessionID: "app").currentLogicalTurn?.turnID, "turn-B",
                       "a late terminal for A must not clear B's mapping")

        control(.ownerDisconnected(reason: .transportClosed, time: "t4"))
        let ownerTerminal = hub.fetch(workspaceID: "workspace-1", sessionID: "app", limit: 10).events.last {
            $0.metadata?["terminal_scope"] == "owner"
        }
        XCTAssertEqual(ownerTerminal?.metadata?["turn_id"], "turn-B", "the disconnect must retire B, not A")
    }

    // P0: after B supersedes A (tombstoning A), a LATE RETRY of A's own
    // start must be rejected outright (`.none`) — never touching B's
    // mapping. The subsequent disconnect must still retire B.
    func testTombstonedLateStartARejectedNoneDoesNotChangeMappingBAndDisconnectRetiresB() throws {
        let hub = AgentEventHub()
        var control: CodexAppServerHeadlessRuntime.WorkingControlHandler?
        let syncer = CodexAppServerRegistryRuntimeSyncer(eventHub: hub, attachHandler: { _, _, _, _, _, _, _, _, onWorkingControl in
            control = onWorkingControl
            return FakeRuntimeSession()
        })
        syncer.sync(records: [
            Self.record(sessionID: "app", runtime: "codex_app_server", socketPath: "/tmp/app.sock", threadID: "thread-a"),
        ])
        guard let control else {
            return XCTFail("attach never captured onWorkingControl")
        }

        control(.turnStarted(threadID: "thread-a", turnID: "turn-A", time: "t1"))
        control(.turnStarted(threadID: "thread-a", turnID: "turn-B", time: "t2"))
        XCTAssertEqual(hub.appServerControlDebugSnapshotForTesting(sessionID: "app").currentLogicalTurn?.turnID, "turn-B")
        let countBeforeRetry = hub.fetch(workspaceID: "workspace-1", sessionID: "app", limit: 10).events.count

        // A late RETRY of A's own start — A is tombstoned, must be rejected
        // outright.
        control(.turnStarted(threadID: "thread-a", turnID: "turn-A", time: "t3"))
        XCTAssertEqual(hub.appServerControlDebugSnapshotForTesting(sessionID: "app").currentLogicalTurn?.turnID, "turn-B",
                       "a tombstoned late start retry for A must be rejected and never touch B's mapping")
        XCTAssertEqual(hub.fetch(workspaceID: "workspace-1", sessionID: "app", limit: 10).events.count, countBeforeRetry,
                       "the rejected retry must produce 0 wire")

        control(.ownerDisconnected(reason: .transportClosed, time: "t4"))
        let ownerTerminal = hub.fetch(workspaceID: "workspace-1", sessionID: "app", limit: 10).events.last {
            $0.metadata?["terminal_scope"] == "owner"
        }
        XCTAssertEqual(ownerTerminal?.metadata?["turn_id"], "turn-B", "the disconnect must retire B, not A")
    }

    // P0: a SAME-INCARNATION reattach (transport died, identical
    // socket/PID/createdAt/root — Hub incarnation preserved, no purge)
    // where the NEW generation B independently reports the SAME logical
    // turn A already opened is the multi-owner idempotent-add-owner path:
    // B's admission is accepted with ZERO wire, but the Syncer must still
    // record `.setOwner` for B. Proof: A's disconnect (non-last owner)
    // must produce 0 terminal; only B's disconnect (the last owner) must
    // produce exactly one.
    func testSameIncarnationTwoOwnersAcceptedZeroWireStillRecordsMappingAndOnlyLastDisconnectTerminals() throws {
        let hub = AgentEventHub()
        var controls = [CodexAppServerHeadlessRuntime.WorkingControlHandler]()
        var runtimes = [FakeRuntimeSession]()
        let sameRecord = Self.record(sessionID: "app", runtime: "codex_app_server", socketPath: "/tmp/app.sock",
                                     threadID: "thread-a", createdAt: "2026-01-01T00:00:00Z")
        // `sync()`'s replacement path removes a retired generation from
        // `retiringGenerations` ASYNCHRONOUSLY on the sidebar queue. Left
        // unblocked, that cleanup can race ahead of this test's own
        // subsequent `controlA(.ownerDisconnected(...))` call: once A's
        // generation is no longer even "retiring", the Syncer's
        // current-or-retiring fence correctly rejects A's disconnect as
        // stale — which would silently leave A's owner stuck in the Hub's
        // `activeOwners` set and make B's own later disconnect ALSO see a
        // (bogus) remaining owner, never producing a terminal. A custom
        // serial queue blocked by a semaphore removes that race entirely:
        // the cleanup cannot run until this test explicitly releases it.
        let sidebarQueue = DispatchQueue(label: "test.sidebar.two-owner")
        let cleanupBlocker = DispatchSemaphore(value: 0)
        // Safety net: an early `return` from any guard below (before the
        // explicit `signal()` further down) must not leave the blocked
        // sidebarQueue worker permanently parked. A duplicate signal from
        // BOTH this defer and the explicit call later is harmless — the
        // semaphore has exactly one waiter, so the surplus count is simply
        // never consumed.
        defer { cleanupBlocker.signal() }
        sidebarQueue.async { cleanupBlocker.wait() }
        let syncer = CodexAppServerRegistryRuntimeSyncer(eventHub: hub,
                                                        sidebarQueue: sidebarQueue,
                                                        attachHandler: { _, _, _, _, _, _, _, _, onWorkingControl in
            controls.append(onWorkingControl)
            let runtime = FakeRuntimeSession()
            runtimes.append(runtime)
            return runtime
        })

        syncer.sync(records: [sameRecord])
        guard controls.count == 1, runtimes.count == 1, let controlA = controls.first else {
            return XCTFail("generation A never captured onWorkingControl")
        }
        controlA(.turnStarted(threadID: "thread-a", turnID: "turn-1", time: "t1"))
        let countAfterAOpen = hub.fetch(workspaceID: "workspace-1", sessionID: "app", limit: 10).events.count
        XCTAssertEqual(countAfterAOpen, 1)

        // Same-incarnation reattach: transport died, everything else
        // identical — Hub incarnation is preserved (no purge), so its
        // `currentLogicalTurn` is still turn-1 when B attaches. A's
        // generation becomes "retiring" but its sidebarQueue-async cleanup
        // is blocked (see above) until this test releases it.
        runtimes[0].stopped = true
        syncer.sync(records: [sameRecord])
        guard controls.count == 2, runtimes.count == 2, let controlB = controls.last else {
            return XCTFail("generation B never captured onWorkingControl")
        }

        // B independently observes the SAME logical turn — idempotent
        // add-owner: accepted, ZERO wire (no second open event), but the
        // Hub must now show TWO distinct owners (different
        // generation/ownerToken) for the same logical turn.
        controlB(.turnStarted(threadID: "thread-a", turnID: "turn-1", time: "t2"))
        XCTAssertEqual(hub.fetch(workspaceID: "workspace-1", sessionID: "app", limit: 10).events.count, countAfterAOpen,
                       "B's idempotent add-owner admission must be 0 wire")
        let afterBOpen = hub.appServerControlDebugSnapshotForTesting(sessionID: "app")
        XCTAssertEqual(afterBOpen.activeOwners.count, 2, "both A and B must be recorded as distinct active owners of the SAME logical turn")
        XCTAssertEqual(Set(afterBOpen.activeOwners.map(\.runtimeGeneration)).count, 2)
        XCTAssertEqual(Set(afterBOpen.activeOwners.map(\.ownerToken)).count, 2)

        // A disconnects — still "retiring" (cleanup still blocked), so the
        // Syncer's current-or-retiring fence still admits it. NOT the last
        // owner (B remains) — 0 terminal.
        controlA(.ownerDisconnected(reason: .transportClosed, time: "t3"))
        XCTAssertEqual(hub.fetch(workspaceID: "workspace-1", sessionID: "app", limit: 10).events.count, countAfterAOpen,
                       "A's disconnect must produce 0 terminal while B (the other owner) remains")
        let afterADisconnect = hub.appServerControlDebugSnapshotForTesting(sessionID: "app")
        XCTAssertEqual(afterADisconnect.activeOwners.count, 1, "only B's owner must remain after A's disconnect")

        // Only now release the blocked cleanup and drain it — A's
        // disconnect has already synchronously completed above, so this
        // ordering can no longer affect it either way.
        cleanupBlocker.signal()
        sidebarQueue.sync {}

        // B disconnects: now the LAST owner — exactly one terminal. This
        // only happens if the Syncer genuinely recorded B's `.setOwner`
        // mapping from its zero-wire admission above — otherwise B's
        // disconnect would find no mapping and also be a no-op.
        controlB(.ownerDisconnected(reason: .transportClosed, time: "t4"))
        let afterBDisconnect = hub.fetch(workspaceID: "workspace-1", sessionID: "app", limit: 10)
        XCTAssertEqual(afterBDisconnect.events.count, countAfterAOpen + 1,
                       "B's disconnect, as the last owner, must produce exactly one owner terminal")
        XCTAssertEqual(afterBDisconnect.events.last?.metadata?["terminal_scope"], "owner")
        XCTAssertEqual(afterBDisconnect.events.last?.metadata?["turn_id"], "turn-1")
        let finalSnapshot = hub.appServerControlDebugSnapshotForTesting(sessionID: "app")
        XCTAssertTrue(finalSnapshot.activeOwners.isEmpty)
        XCTAssertNil(finalSnapshot.currentLogicalTurn)
        // The last-owner terminal SUSPENDS (not tombstones) turn-1 — see
        // `retireAppServerOwner`'s doc comment — so it remains eligible for
        // an exact revision-fenced resume.
        XCTAssertEqual(finalSnapshot.suspendedLogicalTurn?.turnID, "turn-1")

        // A further same-incarnation reattach (C), whose resume response
        // reopens the EXACT suspended turn — locks §6.5's "suspended exact
        // resume" path specifically, not just the terminal above. Must add
        // exactly one NEW control open (`reason: resume_snapshot`) and
        // leave exactly one owner (C).
        runtimes[1].stopped = true
        syncer.sync(records: [sameRecord])
        guard controls.count == 3, runtimes.count == 3, let controlC = controls.last else {
            return XCTFail("generation C never captured onWorkingControl")
        }
        let countBeforeResume = hub.fetch(workspaceID: "workspace-1", sessionID: "app", limit: 10).events.count
        controlC(.resumeSnapshot(threadID: "thread-a", turnID: "turn-1", time: "t5"))
        let afterResume = hub.fetch(workspaceID: "workspace-1", sessionID: "app", limit: 10)
        XCTAssertEqual(afterResume.events.count, countBeforeResume + 1, "C's exact resume of the suspended turn must add exactly one control open")
        XCTAssertEqual(afterResume.events.last?.metadata?["working_phase"], "open")
        XCTAssertEqual(afterResume.events.last?.metadata?["reason"], "resume_snapshot")
        XCTAssertEqual(afterResume.events.last?.metadata?["turn_id"], "turn-1")
        let afterResumeSnapshot = hub.appServerControlDebugSnapshotForTesting(sessionID: "app")
        XCTAssertEqual(afterResumeSnapshot.activeOwners.count, 1, "only C must be the active owner after its exact resume reopen")
        XCTAssertEqual(afterResumeSnapshot.currentLogicalTurn?.turnID, "turn-1")
        XCTAssertNil(afterResumeSnapshot.suspendedLogicalTurn)
    }

    private static func rawObject(from line: String) throws -> [String: JSONValue] {
        let data = try XCTUnwrap(line.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8))
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        return try XCTUnwrap(value.objectValue)
    }

    private static func rawResponseText(id: JSONValue, result: JSONValue) throws -> String {
        let idData = try JSONEncoder().encode(id)
        let idText = String(decoding: idData, as: UTF8.self)
        let resultData = try JSONEncoder().encode(result)
        let resultText = String(decoding: resultData, as: UTF8.self)
        return #"{"id":\#(idText),"result":\#(resultText)}"#
    }

    private static func record(sessionID: String,
                               runtime: String?,
                               socketPath: String?,
                               panelID: String = "panel-1",
                               workspaceID: String = "workspace-1",
                               threadID: String? = nil,
                               createdAt: String = "2026-06-07T00:00:00Z") -> AgentSessionRegistryRecord {
        AgentSessionRegistryRecord(version: 1,
                                   vendor: "codex",
                                   workspaceID: workspaceID,
                                   sessionID: sessionID,
                                   panelID: panelID,
                                   pid: Int32(getpid()),
                                   cwd: "/tmp",
                                   createdAt: createdAt,
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

// TEST-ONLY: a lock-protected ordered log of string markers, appended from
// more than one thread (the winner's background teardown, the replacement's
// background sync call) — a plain `[String]` mutated without a lock would be
// a genuine data race regardless of which specific threads are involved.
private final class OrderedTestEventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []

    func record(_ event: String) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }

    func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }
}

// TEST-ONLY: wraps a REAL `CodexAppServerRuntimeSessionControlling` and
// delegates every method unchanged, except `stop()` — which signals entry
// and return around the real call, so a test can prove a concurrent
// replacement's public-stop loser genuinely reached and blocked inside
// `session.stop()` (not merely `forwardLock`), and observe exactly when it
// returns.
private final class StopInstrumentedRuntimeSessionDecorator: CodexAppServerRuntimeSessionControlling {
    private let wrapped: CodexAppServerRuntimeSessionControlling
    private let onStopEntered: () -> Void
    private let onStopReturned: () -> Void

    init(wrapping wrapped: CodexAppServerRuntimeSessionControlling,
         onStopEntered: @escaping () -> Void,
         onStopReturned: @escaping () -> Void) {
        self.wrapped = wrapped
        self.onStopEntered = onStopEntered
        self.onStopReturned = onStopReturned
    }

    func ensureThreadSubscription() {
        wrapped.ensureThreadSubscription()
    }

    func setRegistryRootThreadID(_ rawThreadID: String?) {
        wrapped.setRegistryRootThreadID(rawThreadID)
    }

    func isStopped() -> Bool {
        wrapped.isStopped()
    }

    func pendingApprovalPromptEvents() -> [AgentEvent] {
        wrapped.pendingApprovalPromptEvents()
    }

    func refreshActiveThread() {
        wrapped.refreshActiveThread()
    }

    func submitApproval(promptID: String,
                        targetIndex: Int,
                        clientRequestID: String?,
                        lifecycleToken: String?) throws -> CodexAppServerApprovalSubmitOutcome {
        try wrapped.submitApproval(promptID: promptID,
                                   targetIndex: targetIndex,
                                   clientRequestID: clientRequestID,
                                   lifecycleToken: lifecycleToken)
    }

    func submitMessage(text: String, clientRequestID: String?) throws {
        try wrapped.submitMessage(text: text, clientRequestID: clientRequestID)
    }

    func stop() {
        onStopEntered()
        wrapped.stop()
        onStopReturned()
    }
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
    var ensureThreadSubscriptionCallCount = 0
    var refreshActiveThreadCallCount = 0
    var submitAttempts = [String]()
    var submittedMessages = [String]()
    var resolvedEventsByPromptID = [String: AgentEvent]()
    var pendingConfirmationPromptIDs = Set<String>()
    var pendingPromptEvents = [AgentEvent]()

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
