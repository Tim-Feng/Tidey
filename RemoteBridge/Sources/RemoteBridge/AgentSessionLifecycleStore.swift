import Foundation

// The SINGLE product-semantic truth for an agent session's display state.
//
//   存在尚未解除、確實阻塞 agent 的互動要求  -> needs_input
//   沒有 blocker，但 turn 仍在執行            -> working
//   沒有執行中的 turn                          -> idle
//
// needs_input covers ONLY explicit turn-blocking interactions (permission
// requests, AskUserQuestion, Codex requestUserInput / blocking server
// requests). A question inside an ordinary final response is idle.
enum AgentSessionDisplayState: String, Sendable {
    case working
    case needsInput = "needs_input"
    case idle
}

enum AgentSessionBlockerKind: String, Sendable {
    case permission
    case userQuestion = "user_question"
    case serverRequest = "server_request"
}

struct AgentSessionLifecycleIdentity: Hashable, Sendable {
    let workspaceID: String
    let panelID: String
    let sessionID: String
}

struct AgentSessionLifecycleSnapshot: Equatable, Sendable {
    let identity: AgentSessionLifecycleIdentity
    let vendor: String
    let state: AgentSessionDisplayState
    let blockerIDs: [String]
    // Provider detail (notLoaded / systemError / ended reason…) is KEPT even
    // when the three-state UI maps it to idle — it must never be lost or
    // allowed to overwrite a still-active session's state.
    let detail: String?
    let generation: Int
    let revision: Int
    let ended: Bool
    // Panel/workspace aggregate captured ATOMICALLY with this exact
    // mutation (same lock hold as the revision bump) — a consumer reading
    // these off the snapshot can NEVER observe a later mutation's aggregate
    // for an earlier revision's delivery (which a separate async re-query
    // of the live store could, under rapid transitions).
    let panelAggregateState: AgentSessionDisplayState
    let panelAggregateRevision: Int
    let workspaceAggregateState: AgentSessionDisplayState
    let workspaceAggregateRevision: Int
}

struct AgentAggregateState: Equatable, Sendable {
    let state: AgentSessionDisplayState
    // Aggregate revisions are MONOTONIC per entity (panel/workspace) — they
    // bump on every accepted mutation touching the entity, so they never go
    // backwards when a high-revision session ends and leaves the max.
    let revision: Int
}

// Per-session three-state reducer with stale-event protection.
//
// Staleness model:
//  - `generation` identifies the provider's connection/replay world (a new
//    Codex connection, a fresh transcript live-tail epoch…). Mutations from
//    an OLDER generation are dropped; a NEWER generation resets the record
//    before applying (the replay that follows rebuilds it). Adopting a new
//    generation ALWAYS publishes — even when its first event maps to idle.
//  - Turn identity: `beginTurn` may carry a turnID; a terminal carrying a
//    turnID only ends THAT turn — turn A's late terminal cannot end turn B.
//  - Resolved blockers leave TOMBSTONES within the generation: a late
//    `open` after its `resolve` cannot resurrect the blocker.
//  - `endSession`/`retireSession` are terminal for the generation: late
//    begin/open/provider-level mutations of the same generation are
//    dropped; only a legitimately newer generation rebuilds the session.
//  - Callback delivery is SERIALIZED in revision order on a dedicated
//    queue; no callback runs inside the state lock (reentrancy-safe).
final class AgentSessionLifecycleStore: @unchecked Sendable {
    private struct Record {
        var vendor: String
        var generation: Int
        var revision: Int
        var turnActive: Bool
        var activeTurnID: String?
        var blockers: [String: AgentSessionBlockerKind]
        var resolvedBlockerTombstones: Set<String>
        var detail: String?
        var ended: Bool
        var retired: Bool

        var state: AgentSessionDisplayState {
            if ended || retired {
                return .idle
            }
            if !blockers.isEmpty {
                return .needsInput
            }
            return turnActive ? .working : .idle
        }
    }

    private let lock = NSLock()
    private var records = [AgentSessionLifecycleIdentity: Record]()
    private var revisionCounter = 0
    private var panelRevisions = [String: Int]()      // ws + panel -> revision
    private var workspaceRevisions = [String: Int]()  // ws -> revision
    private var pendingDeliveries = [AgentSessionLifecycleSnapshot]()
    private let deliveryQueue = DispatchQueue(label: "com.tidey.remote-bridge.lifecycle-delivery")
    private var observers = [UUID: (AgentSessionLifecycleSnapshot) -> Void]()
    private var singleObserver: ((AgentSessionLifecycleSnapshot) -> Void)?

    // Back-compat single-observer seam (tests); registration is lock-guarded.
    var onChange: ((AgentSessionLifecycleSnapshot) -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return singleObserver
        }
        set {
            lock.lock()
            singleObserver = newValue
            lock.unlock()
        }
    }

    @discardableResult
    func addObserver(_ observer: @escaping (AgentSessionLifecycleSnapshot) -> Void) -> UUID {
        let token = UUID()
        lock.lock()
        observers[token] = observer
        lock.unlock()
        return token
    }

    func removeObserver(_ token: UUID) {
        lock.lock()
        observers.removeValue(forKey: token)
        lock.unlock()
    }

    // MARK: - Mutations

    // Explicit generation claim: ALWAYS publishes, even for a brand-new
    // identity whose default (idle, no blockers) record would otherwise
    // look unchanged to `mutate` and be inserted SILENTLY (no revision
    // bump, no delivered snapshot). Without this, an already-subscribed
    // client never learns a new agent session attached — it would keep
    // showing stale carrier/legacy state until the first REAL provider
    // event happened to arrive.
    func claimGeneration(_ identity: AgentSessionLifecycleIdentity,
                        vendor: String,
                        generation: Int) {
        mutate(identity, vendor: vendor, generation: generation) { _ in
            true
        }
    }

    func beginTurn(_ identity: AgentSessionLifecycleIdentity,
                   vendor: String,
                   generation: Int,
                   turnID: String? = nil) {
        mutate(identity, vendor: vendor, generation: generation) { record in
            guard !record.ended, !record.retired else {
                return false  // a dead generation cannot be revived in place
            }
            let changed = !record.turnActive || (turnID != nil && record.activeTurnID != turnID)
            // Starting a NEWER turn retires whatever blocked the PRIOR turn:
            // a blocker belongs to the turn that opened it, and a late
            // `endTurn(oldTurnID)` is already correctly rejected (turnID
            // fence) — without this, the new turn would be stuck
            // needs_input forever over a card nobody can ever resolve.
            if let turnID, let previousTurnID = record.activeTurnID, previousTurnID != turnID,
               !record.blockers.isEmpty {
                for id in record.blockers.keys {
                    record.resolvedBlockerTombstones.insert(id)
                }
                record.blockers.removeAll()
            }
            record.turnActive = true
            if let turnID {
                record.activeTurnID = turnID
            }
            return changed
        }
    }

    func endTurn(_ identity: AgentSessionLifecycleIdentity,
                 vendor: String,
                 generation: Int,
                 turnID: String? = nil) {
        mutate(identity, vendor: vendor, generation: generation) { record in
            guard !record.ended, !record.retired else {
                return false
            }
            // A terminal that names a turn only ends THAT turn: turn A's
            // late terminal must not end turn B.
            if let turnID, let active = record.activeTurnID, turnID != active {
                return false
            }
            let changed = record.turnActive || !record.blockers.isEmpty
            record.turnActive = false
            record.activeTurnID = nil
            // The turn terminal resolves whatever was still blocking it —
            // a dismissed permission dialog or an interrupted question must
            // not leave the session stuck in needs_input.
            for id in record.blockers.keys {
                record.resolvedBlockerTombstones.insert(id)
            }
            record.blockers.removeAll()
            return changed
        }
    }

    // `expectedTurnID`, when the caller has one, fences the opener the
    // SAME way begin/endTurn already do: a turn A blocker opener that is
    // merely LATE (arrives after turn B has already started) must not
    // attach itself to B — an orphaned/late opener for a turn that is no
    // longer active is simply dropped, not silently re-homed onto whatever
    // turn happens to be current.
    func openBlocker(_ identity: AgentSessionLifecycleIdentity,
                     vendor: String,
                     generation: Int,
                     blockerID: String,
                     kind: AgentSessionBlockerKind,
                     expectedTurnID: String? = nil) {
        mutate(identity, vendor: vendor, generation: generation) { record in
            guard !record.ended, !record.retired else {
                return false
            }
            if let expectedTurnID, let active = record.activeTurnID, expectedTurnID != active {
                return false  // stale opener for a turn that is no longer current
            }
            guard !record.resolvedBlockerTombstones.contains(blockerID) else {
                return false  // resolve-then-late-open cannot resurrect
            }
            guard record.blockers[blockerID] == nil else {
                return false  // duplicate opener: one card, one blocker
            }
            record.blockers[blockerID] = kind
            // An explicit interactive request implies the turn is alive.
            record.turnActive = true
            return true
        }
    }

    func resolveBlocker(_ identity: AgentSessionLifecycleIdentity,
                        vendor: String,
                        generation: Int,
                        blockerID: String) {
        mutate(identity, vendor: vendor, generation: generation) { record in
            guard !record.retired else {
                return false
            }
            record.resolvedBlockerTombstones.insert(blockerID)
            return record.blockers.removeValue(forKey: blockerID) != nil
        }
    }

    // Provider-authoritative level set (Codex thread/status/changed and the
    // resume/read snapshot): the caller maps activeFlags to a full state.
    // Only provider-namespace blockers are replaced; explicit prompt-store
    // blockers live in their own namespace.
    func applyProviderLevel(_ identity: AgentSessionLifecycleIdentity,
                            vendor: String,
                            generation: Int,
                            turnActive: Bool,
                            blockedBy providerBlockers: [(id: String, kind: AgentSessionBlockerKind)],
                            blockerNamespace: String,
                            detail: String? = nil) {
        mutate(identity, vendor: vendor, generation: generation) { record in
            guard !record.ended, !record.retired else {
                return false
            }
            var changed = false
            if record.turnActive != turnActive {
                record.turnActive = turnActive
                changed = true
            }
            let keep = Set(providerBlockers.map(\.id))
            for key in record.blockers.keys where key.hasPrefix(blockerNamespace) && !keep.contains(key) {
                record.blockers.removeValue(forKey: key)
                record.resolvedBlockerTombstones.insert(key)
                changed = true
            }
            for blocker in providerBlockers where record.blockers[blocker.id] == nil {
                record.blockers[blocker.id] = blocker.kind
                changed = true
            }
            // NOTE: provider-idle clearing of ITS OWN namespace's blockers
            // already happened in the per-namespace loop above (an empty
            // `keep` set removes every blockerNamespace-prefixed key). There
            // must be NO additional removeAll() here — an explicit blocker
            // from a DIFFERENT namespace (e.g. "codex-prompt:" pending
            // requestUserInput/approval cards) belongs to its own lifecycle
            // and is resolved ONLY by its authoritative terminal
            // (serverRequest/resolved, turn terminal, expiry) — a provider
            // status level (even "fully idle") must never clear it.
            // Detail tracks the CURRENT provider status verbatim: a
            // healthy status (active/idle, detail == nil) must CLEAR a
            // stale notLoaded/systemError reason from a previous
            // application — not just skip updating when the new value
            // happens to be nil.
            if record.detail != detail {
                record.detail = detail
                changed = true
            }
            return changed
        }
    }

    func setDetail(_ identity: AgentSessionLifecycleIdentity,
                   vendor: String,
                   generation: Int,
                   detail: String?) {
        mutate(identity, vendor: vendor, generation: generation) { record in
            guard record.detail != detail else {
                return false
            }
            record.detail = detail
            return true
        }
    }

    func endSession(_ identity: AgentSessionLifecycleIdentity,
                    vendor: String,
                    generation: Int,
                    detail: String? = nil) {
        mutate(identity, vendor: vendor, generation: generation) { record in
            guard !record.ended else {
                return false  // duplicate endSession publishes nothing
            }
            record.ended = true
            record.turnActive = false
            record.activeTurnID = nil
            record.blockers.removeAll()
            if let detail {
                record.detail = detail
            }
            return true
        }
    }

    // Retirement (registry remove / transport close / migration source):
    // keeps a generation TOMBSTONE so the same generation's late events
    // cannot rebuild the identity, and publishes an aggregate invalidation.
    // A GENERATION-FENCED retire (the only production form): an old
    // connection tearing down after a newer one repopulated the identity
    // must not retire the newer record.
    func retireSession(_ identity: AgentSessionLifecycleIdentity, generation: Int? = nil) {
        lock.lock()
        guard var record = records[identity], !record.retired else {
            lock.unlock()
            return
        }
        if let generation, record.generation > generation {
            lock.unlock()
            return
        }
        record.retired = true
        record.turnActive = false
        record.activeTurnID = nil
        record.blockers.removeAll()
        revisionCounter += 1
        record.revision = revisionCounter
        records[identity] = record
        bumpAggregates(identity)
        pendingDeliveries.append(makeSnapshot(identity: identity, record: record))
        lock.unlock()
        drainDeliveries()
    }

    // Migration: the session moved (carrier single-window -> multi-window
    // logical ID, panel/workspace move…). The old identity is retired
    // (tombstoned) and the live state moves to the new identity under the
    // SAME generation.
    // `expectedGeneration`, when supplied, fences the SOURCE read: a caller
    // holding a stale in-memory copy of `old`'s identity must not move
    // whatever CURRENTLY owns that identity if it has since moved on to a
    // different (newer) generation than the caller last observed.
    func migrateSession(from old: AgentSessionLifecycleIdentity,
                        to new: AgentSessionLifecycleIdentity,
                        expectedGeneration: Int? = nil) {
        guard old != new else {
            return  // true no-op: nothing may be retired/regenerated
        }
        lock.lock()
        guard var record = records[old], !record.retired else {
            lock.unlock()
            return
        }
        if let expectedGeneration, record.generation != expectedGeneration {
            lock.unlock()
            return  // stale caller assumption: a newer world already owns `old`
        }

        // Destination guard: a STRICTLY newer world (generation is a
        // globally unique, monotonically-issued counter, so EQUAL
        // generation always means the SAME live world) must never be
        // regressed or overwritten — but a legitimate same-generation
        // round trip (A -> B -> A) IS the same world reclaiming its own
        // prior spot, and a retired tombstone at the SAME generation is
        // exactly that; it must be allowed to resurrect.
        let destinationIsStrictlyNewer = records[new].map { $0.generation > record.generation } ?? false

        var moved = record
        record.retired = true
        record.turnActive = false
        record.blockers.removeAll()
        revisionCounter += 1
        record.revision = revisionCounter
        records[old] = record
        bumpAggregates(old)

        guard !destinationIsStrictlyNewer else {
            // The caller's intent to leave `old` is real regardless of
            // whether the destination write is allowed: `old` is retired
            // as a GHOST of an abandoned older generation so its panel/
            // workspace aggregate does not linger showing stale state —
            // but a strictly-newer destination is never touched/overwritten.
            pendingDeliveries.append(makeSnapshot(identity: old, record: record))
            lock.unlock()
            drainDeliveries()
            return
        }

        moved.retired = false
        revisionCounter += 1
        moved.revision = revisionCounter
        records[new] = moved

        // BOTH mutations are installed before either snapshot is computed:
        // an aggregate read (panel/workspace) taken between "source
        // retired" and "destination installed" would see the session as
        // vanished for a moment — publishing a false idle transition for a
        // still-fully-active session (visible when old/new share a
        // workspace). Only now do we bump aggregates and build snapshots.
        bumpAggregates(new)
        pendingDeliveries.append(makeSnapshot(identity: old, record: record))
        pendingDeliveries.append(makeSnapshot(identity: new, record: moved))
        lock.unlock()
        drainDeliveries()
    }

    // Test barrier: flush the serialized delivery queue.
    func waitForDeliveriesForTesting() {
        deliveryQueue.sync {}
    }

    // MARK: - Queries

    func snapshot(_ identity: AgentSessionLifecycleIdentity) -> AgentSessionLifecycleSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        guard let record = records[identity] else {
            return nil
        }
        return makeSnapshot(identity: identity, record: record)
    }

    // Panel/workspace state: the strongest state across LIVE sessions of
    // the entity (needs_input > working > idle) with a per-entity MONOTONIC
    // revision. Returns nil when no live agent session is known — callers
    // decide the legacy fallback (plain terminals only).
    func panelAggregate(workspaceID: String, panelID: String) -> AgentAggregateState? {
        lock.lock()
        defer { lock.unlock() }
        // ENDED sessions still count (as idle) — they existed and their
        // detail may matter; only RETIRED ghosts (migrated/removed) vanish.
        let live = records.filter {
            $0.key.workspaceID == workspaceID && $0.key.panelID == panelID
                && !$0.value.retired
        }
        guard let state = Self.aggregate(live.map { $0.value.state }) else {
            return nil
        }
        return AgentAggregateState(state: state,
                                   revision: panelRevisions[Self.panelKey(workspaceID, panelID)] ?? 0)
    }

    func workspaceAggregate(workspaceID: String) -> AgentAggregateState? {
        lock.lock()
        defer { lock.unlock() }
        let live = records.filter {
            $0.key.workspaceID == workspaceID && !$0.value.retired
        }
        guard let state = Self.aggregate(live.map { $0.value.state }) else {
            return nil
        }
        return AgentAggregateState(state: state,
                                   revision: workspaceRevisions[workspaceID] ?? 0)
    }

    // Entity-local MONOTONIC revisions, valid even when every session of
    // the entity retired (the aggregate is nil): a retire/invalidation
    // patch must carry THIS number — never a session's global revision —
    // or the next session's smaller entity revision would be rejected
    // forever by revision-fenced consumers.
    func panelEntityRevision(workspaceID: String, panelID: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return panelRevisions[Self.panelKey(workspaceID, panelID)] ?? 0
    }

    func workspaceEntityRevision(workspaceID: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return workspaceRevisions[workspaceID] ?? 0
    }

    // Back-compat conveniences.
    func panelState(workspaceID: String, panelID: String) -> AgentSessionDisplayState? {
        panelAggregate(workspaceID: workspaceID, panelID: panelID)?.state
    }

    func workspaceState(workspaceID: String) -> AgentSessionDisplayState? {
        workspaceAggregate(workspaceID: workspaceID)?.state
    }

    static func aggregate(_ states: [AgentSessionDisplayState]) -> AgentSessionDisplayState? {
        guard !states.isEmpty else {
            return nil
        }
        if states.contains(.needsInput) {
            return .needsInput
        }
        if states.contains(.working) {
            return .working
        }
        return .idle
    }

    // MARK: - Internals

    private static func panelKey(_ workspaceID: String, _ panelID: String) -> String {
        workspaceID + "\u{1F}" + panelID
    }

    private func bumpAggregates(_ identity: AgentSessionLifecycleIdentity) {
        // Called under the lock: aggregate revisions are monotonic per
        // entity and independent of any single session's revision.
        panelRevisions[Self.panelKey(identity.workspaceID, identity.panelID), default: 0] += 1
        workspaceRevisions[identity.workspaceID, default: 0] += 1
    }

    private func mutate(_ identity: AgentSessionLifecycleIdentity,
                        vendor: String,
                        generation: Int,
                        _ body: (inout Record) -> Bool) {
        lock.lock()
        var record = records[identity] ?? Record(vendor: vendor,
                                                 generation: generation,
                                                 revision: 0,
                                                 turnActive: false,
                                                 activeTurnID: nil,
                                                 blockers: [:],
                                                 resolvedBlockerTombstones: [],
                                                 detail: nil,
                                                 ended: false,
                                                 retired: false)
        let isNew = records[identity] == nil
        // STALE-WORLD guard: an old connection/replay generation may never
        // regress the state a newer generation owns.
        if generation < record.generation {
            lock.unlock()
            return
        }
        var adoptedNewGeneration = false
        if generation > record.generation {
            // A new provider world REPLACES the record; the replay that
            // follows rebuilds it. Adoption itself is a published change —
            // even when the first event of the new world maps to idle.
            record = Record(vendor: vendor,
                            generation: generation,
                            revision: record.revision,
                            turnActive: false,
                            activeTurnID: nil,
                            blockers: [:],
                            resolvedBlockerTombstones: [],
                            detail: record.detail,
                            ended: false,
                            retired: false)
            adoptedNewGeneration = true
        }
        record.vendor = vendor
        let changed = body(&record) || adoptedNewGeneration
        guard changed else {
            if isNew {
                records[identity] = record
            }
            lock.unlock()
            return
        }
        revisionCounter += 1
        record.revision = revisionCounter
        records[identity] = record
        bumpAggregates(identity)
        pendingDeliveries.append(makeSnapshot(identity: identity, record: record))
        lock.unlock()
        drainDeliveries()
    }

    // Deliveries are appended in revision order UNDER the lock and drained
    // FIFO on a serial queue: consumers observe monotonic revisions and no
    // callback ever runs inside the state lock.
    private func drainDeliveries() {
        deliveryQueue.async { [weak self] in
            guard let self else { return }
            while true {
                self.lock.lock()
                guard !self.pendingDeliveries.isEmpty else {
                    self.lock.unlock()
                    return
                }
                let snapshot = self.pendingDeliveries.removeFirst()
                let single = self.singleObserver
                let observerList = Array(self.observers.values)
                self.lock.unlock()
                single?(snapshot)
                for observer in observerList {
                    observer(snapshot)
                }
            }
        }
    }

    // Assumes the caller already holds `lock` (mutate/retireSession/
    // migrateSession all call this between lock() and unlock()) — reads
    // `records`/`panelRevisions`/`workspaceRevisions` directly, no re-lock.
    private func panelAggregateLocked(workspaceID: String, panelID: String) -> AgentAggregateState {
        let live = records.filter {
            $0.key.workspaceID == workspaceID && $0.key.panelID == panelID && !$0.value.retired
        }
        let state = Self.aggregate(live.map { $0.value.state }) ?? .idle
        return AgentAggregateState(state: state,
                                   revision: panelRevisions[Self.panelKey(workspaceID, panelID)] ?? 0)
    }

    private func workspaceAggregateLocked(workspaceID: String) -> AgentAggregateState {
        let live = records.filter { $0.key.workspaceID == workspaceID && !$0.value.retired }
        let state = Self.aggregate(live.map { $0.value.state }) ?? .idle
        return AgentAggregateState(state: state, revision: workspaceRevisions[workspaceID] ?? 0)
    }

    private func makeSnapshot(identity: AgentSessionLifecycleIdentity,
                              record: Record) -> AgentSessionLifecycleSnapshot {
        // Computed HERE, under the same lock hold as the revision bump that
        // produced `record` — this is the one atomic point where the
        // per-session mutation and its entity aggregate can never diverge.
        let panel = panelAggregateLocked(workspaceID: identity.workspaceID, panelID: identity.panelID)
        let workspace = workspaceAggregateLocked(workspaceID: identity.workspaceID)
        return AgentSessionLifecycleSnapshot(identity: identity,
                                             vendor: record.vendor,
                                             state: record.state,
                                             blockerIDs: record.blockers.keys.sorted(),
                                             detail: record.detail,
                                             generation: record.generation,
                                             revision: record.revision,
                                             ended: record.ended || record.retired,
                                             panelAggregateState: panel.state,
                                             panelAggregateRevision: panel.revision,
                                             workspaceAggregateState: workspace.state,
                                             workspaceAggregateRevision: workspace.revision)
    }
}

// Process-wide shared instance: transcript sessions and provider runtimes
// feed it; summaries/projections read it. Tests build their own instances.
enum AgentSessionLifecycle {
    static let store = AgentSessionLifecycleStore()

    private static let generationLock = NSLock()
    private static var generationCounter = 0

    // Each provider connection world claims a fresh generation so a stale
    // connection's replay can never regress the state a newer one owns.
    static func nextGeneration() -> Int {
        generationLock.lock()
        defer { generationLock.unlock() }
        generationCounter += 1
        return generationCounter
    }
}

// Codex 0.144.1 `thread/status/changed` -> provider level mapping.
//   active + activeFlags []                       -> working
//   activeFlags contains waitingOnApproval        -> needs_input (permission)
//   activeFlags contains waitingOnUserInput       -> needs_input (user question)
//   idle                                          -> idle
//   notLoaded / systemError                       -> idle (detail preserved)
// Unknown status types change NOTHING (never guess). A malformed `active`
// with a MISSING activeFlags field is rejected (nil) — it must not clear
// existing blockers as if it were an empty flag set.
enum CodexThreadStatusLifecycle {
    static let blockerNamespace = "codex-status:"

    static func providerLevel(statusType: String,
                              activeFlags: [String]?)
        -> (turnActive: Bool, blockers: [(id: String, kind: AgentSessionBlockerKind)], detail: String?)? {
        switch statusType {
        case "active":
            guard let activeFlags else {
                return nil  // malformed: missing required activeFlags
            }
            var blockers = [(id: String, kind: AgentSessionBlockerKind)]()
            if activeFlags.contains("waitingOnApproval") {
                blockers.append((id: blockerNamespace + "waitingOnApproval", kind: .permission))
            }
            if activeFlags.contains("waitingOnUserInput") {
                blockers.append((id: blockerNamespace + "waitingOnUserInput", kind: .userQuestion))
            }
            return (turnActive: true, blockers: blockers, detail: nil)
        case "idle":
            return (turnActive: false, blockers: [], detail: nil)
        case "notLoaded", "systemError":
            return (turnActive: false, blockers: [], detail: statusType)
        default:
            return nil
        }
    }
}
