import Foundation

// Publishes the authoritative three-state lifecycle as LIVE workspace
// events. Every accepted lifecycle change emits ONE `panel_state_changed`
// patch carrying the panel aggregate and the workspace aggregate, each with
// its monotonic revision — the same numbers the list_panels /
// list_workspaces snapshots carry, so snapshot and live are one source.
final class AgentLifecycleEventPublisher: @unchecked Sendable {
    private let store: AgentSessionLifecycleStore
    private let hub: WorkspaceEventHub
    private let lock = NSLock()
    private var sequence = 0

    init(store: AgentSessionLifecycleStore, hub: WorkspaceEventHub) {
        self.store = store
        self.hub = hub
    }

    func attach() {
        store.addObserver { [weak self] snapshot in
            self?.publish(for: snapshot)
        }
    }

    private func publish(for snapshot: AgentSessionLifecycleSnapshot) {
        let workspaceID = snapshot.identity.workspaceID
        let panelID = snapshot.identity.panelID
        guard !workspaceID.isEmpty, !panelID.isEmpty else {
            return
        }
        // Aggregates come DIRECTLY from the snapshot: they were captured
        // atomically (same lock hold) with this exact mutation inside the
        // store. Re-querying the live store here — asynchronously, after
        // the fact — would let a LATER mutation's aggregate leak into an
        // EARLIER revision's delivery under rapid transitions (a
        // working -> needs_input -> … burst racing this callback).
        lock.lock()
        sequence += 1
        let seq = sequence
        lock.unlock()

        var panelPatch: [String: JSONValue] = [
            "panel_id": .string(panelID),
            "state": .string(snapshot.panelAggregateState.rawValue),
        ]
        panelPatch["state_revision"] = .number(Double(snapshot.panelAggregateRevision))
        var workspacePatch: [String: JSONValue] = [
            "workspace_id": .string(workspaceID),
            "state": .string(snapshot.workspaceAggregateState.rawValue),
        ]
        workspacePatch["state_revision"] = .number(Double(snapshot.workspaceAggregateRevision))

        let event = WorkspaceEvent(eventID: "lifecycle:\(workspaceID):\(panelID):\(snapshot.revision)",
                                   seq: seq,
                                   timestamp: ISO8601DateFormatter().string(from: Date()),
                                   kind: .panelStateChanged,
                                   windowGUID: nil,
                                   workspaceID: workspaceID,
                                   panelID: panelID,
                                   workspace: workspacePatch,
                                   panel: panelPatch)
        hub.publish(event)
    }
}

// Per-connection Codex lifecycle feed: claims ONE generation atomically at
// attach, gates every status on the AUTHORITATIVE root thread (child/stale
// threads can never modify the root session), and applies the
// thread/resume / thread/read response snapshot without waiting for a
// later notification. Retirement tombstones the identity.
final class CodexLifecycleFeed: @unchecked Sendable {
    let identity: AgentSessionLifecycleIdentity
    let generation: Int
    private let rootThreadID: () -> String?
    private let store: AgentSessionLifecycleStore
    private let lock = NSLock()
    // Count of ACCEPTED root status notifications: the order fence for
    // resume/read snapshots. A snapshot response older than a notification
    // that arrived after its request was sent must never regress state.
    private var acceptedStatusCount = 0
    private var retired = false
    // promptID -> currently open blocker ID. A re-delivered prompt gets a
    // new attempt (fresh blocker ID, so resolve tombstones from the prior
    // lifecycle cannot swallow it); opening a new attempt closes the stale
    // one so a superseded delivery can never leak a needs_input blocker.
    private var promptBlockerIDs: [String: String] = [:]

    init(identity: AgentSessionLifecycleIdentity,
         rootThreadID: @escaping () -> String?,
         store: AgentSessionLifecycleStore = AgentSessionLifecycle.store) {
        self.identity = identity
        self.rootThreadID = rootThreadID
        self.store = store
        self.generation = AgentSessionLifecycle.nextGeneration()
        // Claim the generation IMMEDIATELY: without this, a reconnect's
        // stale (older-generation) needs_input/working record stays fully
        // visible in every snapshot/aggregate/list read until the first
        // status/resume/prompt event happens to arrive — an unbounded gap
        // whenever that first event is delayed. `endTurn` on the just-
        // claimed generation forces the store's generation-adoption path,
        // which ALWAYS publishes a reconciled (idle) snapshot even though
        // there is nothing else to change.
        store.claimGeneration(identity, vendor: "codex", generation: generation)
    }

    func applyStatus(threadID: String, statusType: String, activeFlags: [String]?) {
        applyStatusCore(threadID: threadID, statusType: statusType, activeFlags: activeFlags, barrierRequirement: nil)
    }

    // Root-gated turn identity: without this, `record.activeTurnID` stays
    // nil for every Codex session (only `applyProviderLevel` ever touched
    // the record, and it never sets a turn id), which makes ANY
    // `expectedTurnID` fence passed to `store.openBlocker` a complete
    // no-op (the guard short-circuits whenever `record.activeTurnID` is
    // nil). turn/started and turn/completed carry `threadId` directly (no
    // full thread object) — the root gate alone is sufficient to exclude
    // a subagent's turns, since a child's threadId can never equal the
    // authoritative root.
    func applyTurnStarted(threadID: String, turnID: String) {
        guard let root = rootThreadID(), threadID == root else {
            return
        }
        // Same ordering domain as status/snapshot/prompt: without this, a
        // stale resume snapshot captured BEFORE this turn edge could still
        // apply AFTER it (barrier unchanged) and override a real turn
        // start/stop with stale provider-level data.
        lock.lock()
        defer { lock.unlock() }
        acceptedStatusCount += 1
        store.beginTurn(identity, vendor: "codex", generation: generation, turnID: turnID)
    }

    func applyTurnCompleted(threadID: String, turnID: String) {
        guard let root = rootThreadID(), threadID == root else {
            return
        }
        lock.lock()
        defer { lock.unlock() }
        acceptedStatusCount += 1
        store.endTurn(identity, vendor: "codex", generation: generation, turnID: turnID)
    }

    // Captured BEFORE sending a thread/resume / thread/read request; the
    // response snapshot applies only while no newer root status notification
    // has been accepted since.
    func snapshotBarrier() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return acceptedStatusCount
    }

    // thread/resume / thread/read RESPONSE snapshot (`result.thread.status`):
    // authoritative reconnect state — applied directly, not dependent on a
    // follow-up notification.
    func applySnapshotResult(_ result: JSONValue, threadID: String, barrier: Int? = nil) {
        guard let status = result.objectValue?["thread"]?.objectValue?["status"]?.objectValue,
              let statusType = status["type"]?.stringValue else {
            return
        }
        let activeFlags: [String]? = status["activeFlags"]?.arrayValue
            .map { $0.compactMap(\.stringValue) }
        applyStatusCore(threadID: threadID, statusType: statusType, activeFlags: activeFlags, barrierRequirement: barrier)
    }

    // The barrier check, the counter increment, AND the store mutation all
    // happen under ONE lock hold: a live notification racing a resume/read
    // snapshot response cannot interleave between "barrier looked valid"
    // and "the store was actually mutated" — the previous two-lock version
    // (check under one lock(), apply under a separate later acquisition)
    // left exactly that TOCTOU window open. `store` has its own internal
    // lock and never calls back into `self.lock`, so nesting is safe.
    private func applyStatusCore(threadID: String,
                                 statusType: String,
                                 activeFlags: [String]?,
                                 barrierRequirement: Int?) {
        guard let root = rootThreadID(), threadID == root else {
            return  // child or unknown thread: never binds the root session
        }
        guard let level = CodexThreadStatusLifecycle.providerLevel(statusType: statusType,
                                                                   activeFlags: activeFlags) else {
            return  // malformed/unknown status: never clears a known blocker
        }
        lock.lock()
        defer { lock.unlock() }
        if let barrierRequirement, acceptedStatusCount != barrierRequirement {
            return  // a live notification outran this snapshot
        }
        acceptedStatusCount += 1
        store.applyProviderLevel(identity,
                                 vendor: "codex",
                                 generation: generation,
                                 turnActive: level.turnActive,
                                 blockedBy: level.blockers,
                                 blockerNamespace: CodexThreadStatusLifecycle.blockerNamespace,
                                 detail: level.detail)
    }

    // Explicit blocking prompt lifecycle (approval / requestUserInput) —
    // independent of status notifications. `attempt` is the delivery attempt
    // from the connection's approval store: each re-delivery is a fresh
    // blocker identity.
    // Explicit prompt open/resolve share the EXACT SAME ordering fence as
    // status/snapshot application (`acceptedStatusCount`) and are fully
    // serialized under the SAME lock as `applyStatusCore` — never a
    // separate operation. Without this, a resume/read snapshot captured
    // BEFORE a requestUserInput opened could still pass its barrier check
    // AFTER the open (since opening a prompt didn't count as an accepted
    // event), apply a stale "idle" turnActive=false to the record, and
    // surface as idle the instant the card is later resolved — even though
    // the live status never actually went idle. The same hazard applies in
    // reverse: a stale WAITING status snapshot arriving after resolve must
    // not resurrect the blocker.
    // `turnID`, when the caller (the request envelope) has one, fences the
    // opener EXACTLY like Claude's turn-scoped openers: it is the
    // SOURCE-captured owning turn — never a "whatever is current" read —
    // so a request belonging to an already-superseded turn cannot attach
    // to a newer one.
    func openPrompt(promptID: String, attempt: Int, kind: AgentSessionBlockerKind, turnID: String? = nil) {
        let blockerID = Self.blockerID(promptID: promptID, attempt: attempt)
        lock.lock()
        defer { lock.unlock() }
        let staleBlockerID = promptBlockerIDs[promptID]
        promptBlockerIDs[promptID] = blockerID
        acceptedStatusCount += 1
        if let staleBlockerID, staleBlockerID != blockerID {
            store.resolveBlocker(identity, vendor: "codex", generation: generation,
                                 blockerID: staleBlockerID)
        }
        store.openBlocker(identity, vendor: "codex", generation: generation,
                          blockerID: blockerID, kind: kind, expectedTurnID: turnID)
    }

    func resolvePrompt(promptID: String, attempt: Int) {
        let blockerID = Self.blockerID(promptID: promptID, attempt: attempt)
        lock.lock()
        defer { lock.unlock() }
        if promptBlockerIDs[promptID] == blockerID {
            promptBlockerIDs.removeValue(forKey: promptID)
        }
        acceptedStatusCount += 1
        store.resolveBlocker(identity, vendor: "codex", generation: generation,
                             blockerID: blockerID)
    }

    func retire() {
        lock.lock()
        let alreadyRetired = retired
        retired = true
        lock.unlock()
        guard alreadyRetired == false else {
            return
        }
        // Generation-fenced: an OLD connection tearing down after a newer
        // one repopulated the identity must not retire the newer record.
        store.retireSession(identity, generation: generation)
    }

    private static func blockerID(promptID: String, attempt: Int) -> String {
        "codex-prompt:\(promptID)#a\(attempt)"
    }
}
