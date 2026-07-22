import Foundation

private let codexTranscriptMajorVersion = "0."
private let codexSidebarLogURL = URL(fileURLWithPath: "/tmp/tidey-bridge-codex.log")

final class CodexTranscriptSession: AgentTranscriptSession {
    private let queue: DispatchQueue
    private let fileManager: FileManager
    private let hub: AgentEventHub
    private let socketClient: TideyCommandSending?
    private let chatSubmitEchoRegistry: ChatSubmitEchoRegistry

    private var record: AgentSessionRegistryRecord
    private var resolverTimer: DispatchSourceTimer?
    private var tailer: JSONLFileTailer?
    private var transcriptURL: URL?
    private var transcriptSequenceBase = 0
    private var maxObservedSeq = transcriptSessionStartedSequence
    private var didPublishStart = false
    private var didPublishEnd = false
    private var didSeeInteractiveEvent = false
    private var unsupportedVersions = Set<String>()
    private var resolvedToolCallIDs = Set<String>()
    private var publishedAssistantTextKeys = Set<String>()
    private var isBackfillingHistory = false
    private var isBootstrappingSidebarState = false
    // Historical replay transaction (see ClaudeTranscriptSession): raw
    // historical lines are re-parsed offset-ascending with a FRESH parser
    // state on every page; live parser state is untouched.
    private var historicalRawLines: [(offset: Int, line: String)] = []
    private var historicalReplayProducts: [AgentEvent] = []
    private var isCollectingBackfillPage = false
    private var collectedBackfillPage: [(offset: Int, line: String)] = []
    private let historicalReplayWindowCapacity: Int
    private var bootstrappedShellState: CodexSidebarShellState = .prompt
    private var currentShellState: CodexSidebarShellState = .prompt
    private var didPublishSidebarSessionActivation = false
    // Set for the duration of a prepareUpdate()...finishUpdate() workspace
    // migration transaction (see AgentSessionRegistryMonitor): while held,
    // publishSidebar does not send — it BUFFERS each call's message batch,
    // in order, into heldSidebarMessageBatches (see below). finishUpdate()
    // releases the hold and flushes every buffered batch, in the SAME
    // order they were produced — never coalesced/dropped to just a single
    // synthetic activation, since a task_complete's "completed" notification
    // or any other lifecycle-specific message arriving in this window would
    // otherwise be silently lost. This guarantees nothing this session could
    // ever say about its NEW workspace is observable before the caller's
    // own last-owner cleanup for the OLD workspace, while still eventually
    // saying ALL of it, in the right order, once released.
    private var isSidebarPublicationHeld = false
    private var heldSidebarMessageBatches: [[String]] = []
    // TEST-ONLY: fires synchronously, ON this session's own queue, inside
    // stopOldTailerBeforeSourceSwitchIfNeeded — after a genuine switch is
    // confirmed but BEFORE tailer.stop() actually runs. Since this runs on
    // the SAME serial queue as every file-event dispatch, a test appending
    // content from inside this hook is guaranteed no other callback can
    // have already consumed it: the append can only be picked up by the
    // subsequent stop()'s own synchronous drain, never by a pre-existing
    // async dispatch racing ahead of it. No production caller.
    var beforeOldTailerStopForTesting: (() -> Void)?
    // TEST-ONLY: fires synchronously, immediately after a boundary/start seq
    // is RESERVED (hub.nextSyntheticSeq) but before it is PUBLISHED — the
    // exact window the Round 7G TOCTOU fix closes. A test can use this to
    // deterministically publish a competing higher-seq event to the SAME
    // Hub/session from inside the hook, forcing publish()'s own
    // rebase-on-collision to fire on ITS NEXT call — proving this session's
    // local base is seeded from publish's return value, never the earlier
    // reservation, without any race/sleep/thread-timing dependency. No
    // production caller.
    // Both hooks below are fired from MORE THAN ONE execution context —
    // `start()` deliberately runs synchronously on the CALLER's thread,
    // while `beginNewSourceEpoch()`/`resolveTranscriptIfPossible()` run on
    // this session's own serial `queue`. `TestHookBox` is lock-protected
    // unconditionally, so every read and every write is race-free
    // regardless of which thread/queue either side runs on.
    // TEST-ONLY: fires synchronously, immediately after a boundary/start seq
    // is RESERVED (hub.nextSyntheticSeq) but before it is PUBLISHED — the
    // exact window the Round 7G TOCTOU fix closes. A test can use this to
    // deterministically publish a competing higher-seq event to the SAME
    // Hub/session from inside the hook, forcing publish()'s own
    // rebase-on-collision to fire on ITS NEXT call — proving this session's
    // local base is seeded from publish's return value, never the earlier
    // reservation, without any race/sleep/thread-timing dependency. No
    // production caller.
    private let afterBoundaryReservationBeforePublishHook = TestHookBox()
    func setAfterBoundaryReservationBeforePublishHookForTesting(_ hook: (() -> Void)?) {
        afterBoundaryReservationBeforePublishHook.set(hook)
    }
    // TEST-ONLY: fires synchronously at the END of every
    // resolveTranscriptIfPossible() attempt — including the resolver
    // timer's own periodic (1s) retries — whether or not it attached
    // anything. Lets a test deterministically wait for N genuine resolve
    // attempts (e.g. via XCTestExpectation) instead of a blind
    // fixed-duration sleep, while still exercising the REAL production
    // timer/queue mechanism (not a synthetic stand-in for it). No
    // production caller.
    private let afterResolveAttemptHook = TestHookBox()
    func setAfterResolveAttemptHookForTesting(_ hook: (() -> Void)?) {
        afterResolveAttemptHook.set(hook)
    }
    // Test observability: the CURRENT local sequence base — see
    // ClaudeTranscriptSession's equivalent accessor for why this direct
    // exposure is necessary (a wrong local base is NOT reliably observable
    // through externally-published seqs alone, since the Hub's own
    // rebase-on-collision silently launders it into a still-monotonic
    // sequence for anything that flows back through `hub.publish`).
    var transcriptSequenceBaseForTesting: Int {
        queue.sync { transcriptSequenceBase }
    }
    private var lastStartedTurnID: String?
    private var lastCompletedTurnID: String?
    private var lastAbortedTurnID: String?
    // Every DISTINCT terminal (task_complete/turn_aborted) turn_id observed
    // during the initial bootstrap-tail replay (isBootstrappingSidebarState),
    // not just the last one of each kind — lastCompletedTurnID/
    // lastAbortedTurnID are single-slot "most recent" trackers, so if the
    // window contains a matching terminal for the true opener FOLLOWED by a
    // later, unrelated stale terminal, the single slot would only remember
    // the stale one and lose the genuine match. Seeds the deep reverse
    // scan's own matched-terminal set so a terminal split across the window
    // boundary (opener before the window, its terminal inside it) is never
    // lost regardless of what else the window also saw.
    private var bootstrapWindowTerminalTurnIDs: Set<String> = []
    // The turn currently considered "active" for Working-indicator purposes
    // (distinct from the sidebar's currentShellState): set by a live
    // task_started, cleared only by a task_complete/turn_aborted whose
    // turn_id matches it — a stale terminal for a DIFFERENT turn_id leaves
    // it untouched.
    private var activeWorkingTurnID: String?

    private struct LiveParserStateSnapshot {
        let unsupportedVersions: Set<String>
        let resolvedToolCallIDs: Set<String>
        let publishedAssistantTextKeys: Set<String>
        let didSeeInteractiveEvent: Bool
        let lastStartedTurnID: String?
        let lastCompletedTurnID: String?
        let lastAbortedTurnID: String?
        let activeWorkingTurnID: String?
        let currentShellState: CodexSidebarShellState
        let bootstrappedShellState: CodexSidebarShellState
    }

    private func captureLiveParserState() -> LiveParserStateSnapshot {
        LiveParserStateSnapshot(unsupportedVersions: unsupportedVersions,
                                resolvedToolCallIDs: resolvedToolCallIDs,
                                publishedAssistantTextKeys: publishedAssistantTextKeys,
                                didSeeInteractiveEvent: didSeeInteractiveEvent,
                                lastStartedTurnID: lastStartedTurnID,
                                lastCompletedTurnID: lastCompletedTurnID,
                                lastAbortedTurnID: lastAbortedTurnID,
                                activeWorkingTurnID: activeWorkingTurnID,
                                currentShellState: currentShellState,
                                bootstrappedShellState: bootstrappedShellState)
    }

    private func resetParserStateForHistoricalReplay() {
        unsupportedVersions = []
        resolvedToolCallIDs = []
        publishedAssistantTextKeys = []
        didSeeInteractiveEvent = false
        lastStartedTurnID = nil
        lastCompletedTurnID = nil
        lastAbortedTurnID = nil
        activeWorkingTurnID = nil
        currentShellState = .prompt
        bootstrappedShellState = .prompt
    }

    private func restoreLiveParserState(_ snapshot: LiveParserStateSnapshot) {
        unsupportedVersions = snapshot.unsupportedVersions
        resolvedToolCallIDs = snapshot.resolvedToolCallIDs
        publishedAssistantTextKeys = snapshot.publishedAssistantTextKeys
        didSeeInteractiveEvent = snapshot.didSeeInteractiveEvent
        lastStartedTurnID = snapshot.lastStartedTurnID
        lastCompletedTurnID = snapshot.lastCompletedTurnID
        lastAbortedTurnID = snapshot.lastAbortedTurnID
        activeWorkingTurnID = snapshot.activeWorkingTurnID
        currentShellState = snapshot.currentShellState
        bootstrappedShellState = snapshot.bootstrappedShellState
    }

    private var lastBackfillPageOffsets: ClosedRange<Int>?
    private var lastRequestedBackfillAnchorSeq: Int?

    private func mergeHistoricalPage(_ page: [(offset: Int, line: String)]) {
        guard let pageMin = page.map(\.offset).min(),
              let pageMax = page.map(\.offset).max() else {
            return
        }
        lastBackfillPageOffsets = pageMin...pageMax
        var merged = page + historicalRawLines
        merged.sort { $0.offset < $1.offset }
        var seenOffsets = Set<Int>()
        merged = merged.filter { seenOffsets.insert($0.offset).inserted }
        // Direction-aware eviction: the JUST-REQUESTED page always stays; the
        // window sheds whichever end is farther from it, so deep old-paging
        // sheds the newest end while a fresh newer-range request sheds the
        // oldest end. The Hub's historical replacement scope follows the
        // window exactly.
        while merged.count > historicalReplayWindowCapacity {
            let distanceToOldEnd = pageMin - (merged.first?.offset ?? pageMin)
            let distanceToNewEnd = (merged.last?.offset ?? pageMax) - pageMax
            if distanceToNewEnd >= distanceToOldEnd {
                merged.removeLast()
            } else {
                merged.removeFirst()
            }
        }
        historicalRawLines = merged
    }

    @discardableResult
    private func replayHistoricalWindow() -> [AgentEvent] {
        let liveSnapshot = captureLiveParserState()
        resetParserStateForHistoricalReplay()
        historicalReplayProducts = []
        isBackfillingHistory = true
        for entry in historicalRawLines {
            consume(line: entry.line, lineOffset: entry.offset)
        }
        isBackfillingHistory = false
        restoreLiveParserState(liveSnapshot)
        // Atomic replacement: the Hub's historical state becomes EXACTLY the
        // window's derived set — retracting derivations (newer duplicates,
        // cross-page statuses) that this replay proved wrong. The anchor
        // marks the just-requested page so capacity trims never drop it.
        // The trim anchor is the REQUESTED before-seq: when the Hub bound is
        // smaller than the window, the retained interval stays adjacent to
        // the caller's anchor so its next cursor advances without a gap.
        let anchorSeq = lastRequestedBackfillAnchorSeq
        let products = historicalReplayProducts
        hub.replaceHistoricalEvents(sessionID: record.sessionID,
                                    events: products,
                                    anchorSeq: anchorSeq)
        historicalReplayProducts = []
        return products
    }

    // TEST-ONLY: overrides the directory-enumeration fallback's search root
    // (production default is ~/.codex/sessions). Lets tests exercise the
    // enumeration fallback (and its threadID gating) against an isolated
    // temp directory instead of the user's real session history.
    private let sessionsDirectoryOverride: URL?

    init(record: AgentSessionRegistryRecord,
         fileManager: FileManager = .default,
         hub: AgentEventHub,
         socketClient: TideyCommandSending? = nil,
         chatSubmitEchoRegistry: ChatSubmitEchoRegistry? = nil,
         historicalReplayWindowCapacity: Int = 4000,
         sessionsDirectoryOverrideForTesting: URL? = nil) {
        self.historicalReplayWindowCapacity = max(1, historicalReplayWindowCapacity)
        self.record = record
        self.fileManager = fileManager
        self.hub = hub
        self.socketClient = socketClient
        self.chatSubmitEchoRegistry = chatSubmitEchoRegistry ?? ChatSubmitEchoRegistry()
        self.sessionsDirectoryOverride = sessionsDirectoryOverrideForTesting
        self.queue = DispatchQueue(label: "com.tidey.remote-bridge.codex-session.\(record.sessionID)")
    }

    func start() {
        guard !didPublishStart else {
            return
        }
        didPublishStart = true
        // New-generation ownership handoff: this session object IS a new
        // source incarnation for its sessionID — whether genuinely
        // first-ever, or a registry monitor stop+recreate reusing the same
        // sessionID (a same-sessionID generation swap: Tim's `/clear` or a
        // PID change). Reset Hub-side seen/live state and workspace
        // bindings SYNCHRONOUSLY, BEFORE returning to the caller (the
        // registry monitor) — a safe no-op for a genuinely fresh sessionID
        // with no prior Hub state. The monitor's runtime-reconcile transaction
        // retires/fences the OLD app-server runtime generation FIRST, then
        // this transcript start (and its epoch reset) runs inside that same
        // callback, and only THEN does any NEW/surviving runtime generation
        // attach — so completing this synchronously here guarantees it can
        // never race behind a runtime syncer's own live events for the new
        // generation, and a reused eventID/offset/call_id from the new
        // generation is never suppressed by the OLD generation's seen set.
        //
        // The boundary's seq is minted from the Hub's OWN cross-generation
        // reservation (nextSyntheticSeq), NOT the fixed sentinel
        // transcriptSessionStartedSequence — this only seeds a readable/
        // unique eventID and a claimed seq to publish; it is NEVER trusted
        // as the final stored seq (see the Round 7G TOCTOU contract below).
        // Round 7G P0 (TOCTOU fix, corrected contract): `maxObservedSeq`/
        // `transcriptSequenceBase` are set from `publish`'s RETURN VALUE
        // (the TRUE stored seq, post-rebase), never the pre-publish
        // reservation — the reservation only seeds the eventID/claimed seq.
        // `publish` returns `nil` when the event was NOT genuinely stored
        // (duplicate eventID / suppressed); that is not proof of any seq,
        // so this fails closed: it does NOT advance the base from the
        // unstored reservation, leaving it at its prior (pre-start) value.
        hub.beginNewSourceEpoch(sessionID: record.sessionID)
        let reservedSeq = hub.nextSyntheticSeq(sessionID: record.sessionID)
        afterBoundaryReservationBeforePublishHook.fire()
        let publishedStartSeq = hub.publish(AgentEvent(eventID: "session-start:\(record.sessionID)",
                               seq: reservedSeq,
                               vendor: "codex",
                               workspaceID: record.workspaceID,
                               sessionID: record.sessionID,
                               timestamp: record.createdAt,
                               type: .sessionStarted,
                               role: nil,
                               text: nil,
                               name: nil,
                               input: nil,
                               output: nil,
                               toolCallID: nil,
                               metadata: baseMetadata(["cwd": record.cwd])))
        if let publishedStartSeq {
            maxObservedSeq = max(maxObservedSeq, publishedStartSeq)
        } else {
            BridgeLogger.server.error("codex session-start boundary marker was not stored; sequence base not advanced from unstored reservation session_id=\(self.record.sessionID, privacy: .public) reserved_seq=\(reservedSeq, privacy: .public)")
        }
        transcriptSequenceBase = maxObservedSeq
        // The resolver's FIRST attach attempt must ALSO complete before
        // start() returns to the caller — a fresh object has nothing else
        // scheduled on `queue` yet, so this is deadlock-safe. If it merely
        // dispatched async here, there would be a real window between the
        // boundary becoming visible (above) and the tailer's file-system
        // watcher actually being installed: a write landing in that gap
        // (JSONLFileReader.readTail followed by lseek(EOF) + watcher
        // install) would set nextReadOffset past it with no watcher yet
        // armed to catch the append — a genuine lost-line race, not just a
        // Working-indicator ordering nicety. For a path that doesn't
        // resolve yet, resolveTranscriptIfPossible's failure is quick and
        // startResolver just arms its 1s retry timer — this still returns
        // promptly, it does not block waiting for the file to appear.
        queue.sync {
            startResolver()
            if tailer == nil {
                publishSidebarSessionActivation(force: false)
            }
        }
    }

    func update(record: AgentSessionRegistryRecord) {
        queue.async {
            let sourceSwitchAlreadyDetected = self.detectsSourceSwitch(for: record)
            self.stopOldTailerBeforeSourceSwitchIfNeeded(alreadyDetected: sourceSwitchAlreadyDetected)
            self.performUpdate(record: record, sourceSwitchAlreadyDetected: sourceSwitchAlreadyDetected)
        }
    }

    // A genuine source-identity switch must stop/drain the OLD tailer under
    // the OLD record/workspace, and BEFORE anything else — record/Hub
    // binding switch, epoch reset, or (for the migration transaction) the
    // sidebar publication hold — changes. JSONLFileTailer.stop() drains any
    // bytes already written to the fd but not yet delivered (see its own
    // doc comment); if that drain runs AFTER self.record has already
    // flipped to B and the hold is already active, a legitimate final A
    // line (e.g. a task_complete) gets attributed to B and buried in B's
    // held batches — instead of being sent immediately, normally, for A.
    // Stopping the tailer here first makes beginNewSourceEpoch's own
    // `tailer?.stop()` (which runs later, under the new record) a safe
    // no-op: the tailer is already nil.
    private func stopOldTailerBeforeSourceSwitchIfNeeded(alreadyDetected: Bool) {
        guard alreadyDetected else {
            return
        }
        beforeOldTailerStopForTesting?()
        tailer?.stop()
        tailer = nil
        resolverTimer?.cancel()
        resolverTimer = nil
    }

    // A conservative, EXPLICIT-FIELD-ONLY pre-check — deliberately NOT the
    // full resolveTranscriptURL() fallback chain (process tree / directory
    // enumeration): those depend on self.record already reflecting the
    // CANDIDATE record, AND can themselves wrongly re-resolve back to the
    // OLD file (matching stale registry fields, an unrelated process-tree
    // hit, or resumeThreadID still naming A) — which is exactly what must
    // NOT be allowed to suppress a switch this pre-check already knows is
    // real. This only needs to answer "is the OLD tailer definitely about
    // to become stale," using facts already known before any state
    // changes: an explicit new transcriptPath that differs from the
    // currently-tailed file, OR (checked independently, not as an
    // else-branch — a record can carry a STALE unchanged path alongside an
    // already-updated authoritative thread id) a new threadID (falling
    // back to resumeThreadID only when threadID itself is absent) that the
    // currently-tailed file's own name does not carry. This covers the
    // delayed-rollout case: B's authoritative identity is already known
    // even though B's file does not exist yet.
    // SHARED between detectsSourceSwitch, resolveTranscriptURL, and
    // performUpdate's own identity check — every explicit-path decision
    // must treat "what counts as a real path" identically, or two of them
    // can drift: one says "not explicit" (e.g. skips the drain/switch)
    // while another still treats it as authoritative (e.g. resolves and
    // reattaches on it), reproducing the exact wrong-order/wrong-identity
    // bugs these checks exist to close. A nil OR whitespace-only path is
    // never explicit — canonicalizing an empty/whitespace string resolves
    // it against the CURRENT WORKING DIRECTORY, which is never a
    // meaningful transcript identity and must never be compared as one.
    private static func explicitTranscriptPath(from record: AgentSessionRegistryRecord) -> String? {
        guard let path = record.transcriptPath else {
            return nil
        }
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : path
    }

    private func detectsSourceSwitch(for candidateRecord: AgentSessionRegistryRecord) -> Bool {
        guard let currentURL = transcriptURL else {
            return false
        }
        if let newPath = Self.explicitTranscriptPath(from: candidateRecord) {
            // An EXPLICIT path is authoritative on its own: unchanged means
            // no switch (a plain codex CLI rollout's filename carries no
            // thread identity at all, so a threadID added as pure metadata
            // alongside an unchanged explicit path must never be
            // second-guessed into a false switch).
            return Self.canonicalTranscriptPath(newPath) != Self.canonicalTranscriptPath(currentURL.path)
        }
        // No explicit path was given — this is the delayed-rollout shape
        // (an app-server active-thread change whose new rollout does not
        // exist yet, so transcriptPath comes back nil). Fall back to
        // authoritative thread identity against the CURRENTLY-tailed
        // file's own name.
        if let threadID = candidateRecord.threadID, !threadID.isEmpty {
            return currentURL.lastPathComponent.contains(threadID) == false
        }
        if let resumeThreadID = candidateRecord.resumeThreadID, !resumeThreadID.isEmpty {
            return currentURL.lastPathComponent.contains(resumeThreadID) == false
        }
        return false
    }

    // Phase 1 of the two-phase, race-free workspace-migration transaction
    // (see AgentSessionRegistryMonitor for the full protocol this
    // participates in). Runs synchronously on this session's own serial
    // queue: any work ALREADY enqueued/executing there finishes first
    // (plain FIFO ordering), THEN this call holds all sidebar publication
    // (isSidebarPublicationHeld) and switches this session's record AND
    // Hub workspace binding to `record` — all before returning. Once this
    // returns, the session's internal state (and anything a NEW event
    // processes from here on) already reflects the NEW workspace, but
    // NOTHING has been said on the sidebar about it yet: that only happens
    // in finishUpdate(), once the caller has finished sending the OLD
    // workspace's cleanup. This is what actually closes the gap a bare
    // "drain, then separately call async update()" sequence could not:
    // draining only flushes what was ALREADY queued, it does not prevent
    // something NEW from being queued (and its sidebar effect published)
    // ahead of a later, separate async update() call — holding sidebar
    // publication for the whole prepare-to-finish window does.
    func prepareUpdate(record: AgentSessionRegistryRecord) {
        queue.sync {
            // Stop/drain the OLD tailer under the OLD record — BEFORE the
            // hold is enabled — so a legitimate final A line lands as a
            // normal, immediate A-workspace send, never a B-attributed
            // batch buried behind the hold. See
            // stopOldTailerBeforeSourceSwitchIfNeeded.
            let sourceSwitchAlreadyDetected = self.detectsSourceSwitch(for: record)
            self.stopOldTailerBeforeSourceSwitchIfNeeded(alreadyDetected: sourceSwitchAlreadyDetected)
            self.isSidebarPublicationHeld = true
            self.heldSidebarMessageBatches = []
            self.performUpdate(record: record, sourceSwitchAlreadyDetected: sourceSwitchAlreadyDetected)
        }
    }

    // Phase 2: releases the hold and flushes EVERY buffered message batch,
    // in the SAME order they were produced (never coalesced/dropped to a
    // single synthetic activation — a task_complete's "completed"
    // notification or any other lifecycle-specific message produced during
    // the held window must still be said, in full, just delayed until now).
    func finishUpdate() {
        queue.sync {
            self.isSidebarPublicationHeld = false
            let batches = self.heldSidebarMessageBatches
            self.heldSidebarMessageBatches = []
            for batch in batches {
                self.sendSidebarMessagesNow(batch)
            }
        }
    }

    // Runs ON `queue` — shared core for both the ordinary async update()
    // above and the prepareUpdate()/finishUpdate() migration transaction.
    // `sourceSwitchAlreadyDetected` is computed by the caller BEFORE this
    // record is applied (see detectsSourceSwitch) and BEFORE the old
    // tailer was stopped/drained.
    private func performUpdate(record: AgentSessionRegistryRecord, sourceSwitchAlreadyDetected: Bool) {
        let previousRecord = self.record
        let didMigrateWorkspace = previousRecord.workspaceID != record.workspaceID
        let didMigratePanel = previousRecord.panelID != record.panelID
        if didMigrateWorkspace || didMigratePanel {
            self.hub.migrateSession(sessionID: previousRecord.sessionID,
                                    toWorkspaceID: record.workspaceID,
                                    panelID: record.panelID)
        }
        self.record = record
        // Identity is the STANDARDIZED, ACTUALLY-RESOLVED transcript
        // path — never raw registry fields. A nil/unresolvable path, an
        // equivalent ~/./ spelling, or a pure thread-metadata addition
        // that still resolves to the SAME file must never reset the
        // source epoch (see canonicalTranscriptPath).
        //
        // If the caller's pre-check already detected a genuine switch
        // (explicit path change, or a new authoritative threadID the OLD
        // file didn't carry), the switch happens UNCONDITIONALLY here —
        // never re-litigated against resolveTranscriptURL()'s fallback
        // chain (process tree / directory enumeration / resumeThreadID),
        // which can wrongly re-resolve back to the OLD file (a delayed B
        // rollout that doesn't exist yet, or a stale registry field) and
        // would otherwise silently suppress a switch already known to be
        // real, leaving the session tailing A forever.
        var didSwitchSource = false
        if sourceSwitchAlreadyDetected {
            didSwitchSource = true
            self.switchTranscriptIdentity()
        } else if let currentURL = self.transcriptURL,
           let resolvedNewURL = self.resolveTranscriptURL(),
           Self.canonicalTranscriptPath(resolvedNewURL.path) != Self.canonicalTranscriptPath(currentURL.path) {
            didSwitchSource = true
            self.switchTranscriptIdentity()
        }
        if (didMigrateWorkspace || didMigratePanel), !didSwitchSource {
            // A pure SAME-source workspace/panel migration is a re-tag,
            // not a source-epoch reset: hub.migrateSession above already
            // moved every stored event (buffered AND historical) to the
            // new workspace/panel in place, preserving Working/pending
            // state — no lifecycle-reset signal (a second sessionStarted)
            // may be layered on top of it. When a source switch ALSO
            // happened, its own source-epoch boundary (published inside
            // switchTranscriptIdentity, AFTER self.record was already
            // updated above) already carries the new workspace/panel —
            // a second sessionStarted here would just re-clear Working
            // that B's own bootstrap may have already re-established.
            self.publishSidebarSessionActivation(force: true)
        }
        if self.transcriptURL == nil {
            self.resolveTranscriptIfPossible()
        }
    }

    private static func canonicalTranscriptPath(_ path: String) -> String {
        URL(fileURLWithPath: NSString(string: path).expandingTildeInPath).standardizedFileURL.path
    }

    func backfill(beforeSeq: Int, limit: Int) -> Bool {
        queue.sync {
            if tailer == nil {
                resolveTranscriptIfPossible()
            }
            guard let tailer else {
                return false
            }
            guard beforeSeq > transcriptSequenceBase else {
                return false
            }
            let beforeOffset = transcriptLineOffset(for: beforeSeq - transcriptSequenceBase)
            guard beforeOffset > 0 else {
                return false
            }
            // The requested anchor is honored exactly; when the page derives
            // no event visible below the anchor (so the client's oldest_seq
            // cursor could never advance), keep reading deeper within this
            // same transaction until progress is visible or the file starts.
            // A read never exceeds the raw window capacity: reading more and
            // then evicting would skip lines before their FIRST parse. The
            // caller pages onward from the returned oldest_seq instead.
            let effectiveLimit = min(limit, historicalReplayWindowCapacity)
            lastRequestedBackfillAnchorSeq = beforeSeq
            var pageAnchorOffset = beforeOffset
            var loadedAny = false
            while true {
                isCollectingBackfillPage = true
                collectedBackfillPage = []
                let loaded = (try? tailer.backfill(beforeOffset: pageAnchorOffset, limit: effectiveLimit)) ?? false
                isCollectingBackfillPage = false
                guard loaded, collectedBackfillPage.isEmpty == false else {
                    return loadedAny
                }
                loadedAny = true
                let pageMinOffset = collectedBackfillPage.map(\.offset).min() ?? pageAnchorOffset
                mergeHistoricalPage(collectedBackfillPage)
                collectedBackfillPage = []
                let products = replayHistoricalWindow()
                if products.contains(where: { $0.seq < beforeSeq }) || pageMinOffset <= 0 {
                    return true
                }
                pageAnchorOffset = pageMinOffset
            }
        }
    }

    func stop() {
        queue.sync {
            resolverTimer?.cancel()
            resolverTimer = nil
            tailer?.stop()
            tailer = nil
            if !didPublishEnd {
                didPublishEnd = true
                let seq = nextSyntheticSequence()
                publishSynthetic(kind: .sessionEnded,
                                 seq: seq,
                                 eventID: "session-end:\(record.sessionID)",
                                 timestamp: ISO8601DateFormatter().string(from: Date()),
                                 role: nil,
                                 text: nil,
                                 name: nil,
                                 input: nil,
                                 output: nil,
                                 toolCallID: nil,
                                 metadata: baseMetadata(nil))
            }
        }
    }

    private func startResolver() {
        resolveTranscriptIfPossible()
        if tailer != nil {
            log("startResolver resolved transcript=\(transcriptURL?.path ?? "<nil>")")
            return
        }

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .seconds(1), repeating: .seconds(1))
        timer.setEventHandler { [weak self] in
            self?.resolveTranscriptIfPossible()
        }
        timer.resume()
        resolverTimer = timer
    }

    private func resolveTranscriptIfPossible() {
        defer { afterResolveAttemptHook.fire() }
        guard tailer == nil else {
            return
        }
        guard let transcriptURL = resolveTranscriptURL() else {
            return
        }

        let tailer = JSONLFileTailer(fileURL: transcriptURL,
                                     queue: queue,
                                     lineHandler: { [weak self] offset, line in
                                         guard let self else { return }
                                         if self.isCollectingBackfillPage {
                                             self.collectedBackfillPage.append((offset: offset, line: line))
                                             return
                                         }
                                         self.consume(line: line, lineOffset: offset)
                                     },
                                     invalidationHandler: { [weak self] in
                                         self?.handleTailerInvalidation()
                                     })
        do {
            isBootstrappingSidebarState = true
            bootstrappedShellState = .prompt
            bootstrapWindowTerminalTurnIDs = []
            try tailer.start()
            isBootstrappingSidebarState = false
            self.tailer = tailer
            self.transcriptURL = transcriptURL
            resolverTimer?.cancel()
            resolverTimer = nil
            // The bootstrap tail only reads the last transcriptBootstrapLineLimit
            // (500) lines. If an active turn's task_started falls OUTSIDE that
            // window (an attach/deploy landing mid-turn on an already-long
            // transcript), the bootstrap replay never saw ITS task_started —
            // recover it by scanning further back, lifecycle-only. The trigger
            // is lastStartedTurnID == nil alone, NOT also requiring no terminal
            // in-window: a terminal seen in-window (lastCompletedTurnID/
            // lastAbortedTurnID) is only trustworthy evidence of idle if it
            // actually MATCHES the true most-recent task_started — and with no
            // task_started in-window at all, the window has no way to know
            // whether that terminal matches (it could be a late/stale terminal
            // for an EARLIER turn than the real active one, which started
            // before the window and never appears in it). Turn IDs are
            // opaque identities (no ordering assumed) — matching is by
            // equality only. If lastStartedTurnID IS set, the window did see
            // SOME task_started, and any terminal in the window was already
            // correctly matched-or-ignored against it by the ordinary live
            // consumeTaskComplete/consumeTurnAborted logic as it streamed in,
            // so no recovery is needed.
            if lastStartedTurnID == nil {
                recoverActiveLifecycleBeyondBootstrapWindow(tailer: tailer, transcriptURL: transcriptURL)
            }
            log("tailer.start bootstrap end shellState=\(currentShellState) startedTurn=\(lastStartedTurnID ?? "<nil>") completedTurn=\(lastCompletedTurnID ?? "<nil>") activeWorkingTurnID=\(activeWorkingTurnID ?? "<nil>")")
            publishSidebarSessionActivation(force: false)
        } catch {
            isBootstrappingSidebarState = false
            self.transcriptURL = nil
            log("tailer.start failed transcript=\(transcriptURL.path) error=\(error)")
        }
    }

    // Deep, lifecycle-ONLY reverse scan for the nearest task_started line
    // older than everything the bootstrap tail already read, using the SAME
    // turn-identity matching semantics as the live path's consumeTaskComplete/
    // consumeTurnAborted (activeWorkingTurnID must equal a terminal's turn_id
    // for that terminal to count as closing it — see the fields' doc comment
    // above). Pages backward via JSONLFileReader.readBefore directly (NEVER
    // through consume()/the tailer's normal line handler — old chat/tool/
    // history lines here must NEVER be published as live).
    //
    // A terminal (task_complete/turn_aborted) encountered while scanning is
    // NOT itself a stopping condition: it only records "this turn_id is
    // closed" (by opaque equality — turn IDs are UUIDs with no ordering
    // significance) and the scan continues further back looking for the
    // actual most-recent task_started — because a terminal here could belong
    // to an EARLIER, unrelated turn that completed late (arrived in the
    // transcript after a later turn had already started), which must never
    // be mistaken for evidence that the true active turn ended.
    // `matchedTerminalTurnIDs` is seeded from EVERY distinct terminal turn_id
    // the bootstrap window itself already saw (`bootstrapWindowTerminalTurnIDs`
    // — the FULL set, not just the last completed/aborted turn_id of each
    // kind) before scanning starts: a window can contain a genuine match for
    // the true opener followed by a later, unrelated stale terminal, and a
    // single "most recent" slot would remember only the stale one and lose
    // the real match. This also honors a terminal split across the window
    // boundary (task_started before the window, its matching terminal
    // inside it).
    //
    // The scan stops at the first (i.e. most recent) task_started found, or
    // when the file start is reached. If that task_started's turn_id is NOT
    // in matchedTerminalTurnIDs, it is still open — seeds activeWorkingTurnID
    // + the running shell state and emits ONE synthetic cursor-safe live
    // `.thinking` anchor so an already-open or first-fetch client immediately
    // sees Working — later, genuinely live commentary/tool/terminal lines
    // continue and eventually close it exactly like any other turn. If its
    // turn_id IS already matched, idle/off is correct and nothing is seeded.
    private func recoverActiveLifecycleBeyondBootstrapWindow(tailer: JSONLFileTailer, transcriptURL: URL) {
        guard let bootstrapFloor = tailer.earliestLoadedOffset, bootstrapFloor > 0 else {
            return
        }
        var matchedTerminalTurnIDs = bootstrapWindowTerminalTurnIDs
        var pageAnchorOffset = bootstrapFloor
        let pageSize = 200
        while pageAnchorOffset > 0 {
            guard let page = try? JSONLFileReader.readBefore(fileURL: transcriptURL,
                                                             beforeOffset: pageAnchorOffset,
                                                             limit: pageSize),
                  !page.isEmpty else {
                return
            }
            // Newest-to-oldest within the page: the file is offset-ascending,
            // so the LAST entry is the most recent line in this page.
            for (_, line) in page.reversed() {
                guard let envelope = Self.parseLifecycleEnvelope(line: line) else {
                    continue
                }
                guard envelope.type == "task_started" else {
                    matchedTerminalTurnIDs.insert(envelope.turnID)
                    continue
                }
                guard !matchedTerminalTurnIDs.contains(envelope.turnID) else {
                    // The most recent task_started already has a matching
                    // terminal (in-window or found while scanning): idle/off
                    // is correct, nothing to seed.
                    log("recoverActiveLifecycleBeyondBootstrapWindow found matched-terminal task_started turnID=\(envelope.turnID), idle is correct")
                    return
                }
                lastStartedTurnID = envelope.turnID
                activeWorkingTurnID = envelope.turnID
                bootstrappedShellState = .running
                currentShellState = .running
                let seq = nextSyntheticSequence()
                publishSynthetic(kind: .thinking,
                                 seq: seq,
                                 eventID: "thinking-bootstrap-recovery:\(record.sessionID):\(seq)",
                                 timestamp: ISO8601DateFormatter().string(from: Date()),
                                 role: nil,
                                 text: nil,
                                 name: nil,
                                 input: nil,
                                 output: nil,
                                 toolCallID: nil,
                                 metadata: ["turn_id": envelope.turnID, "reason": "bootstrap_recovered_task_started"])
                log("recoverActiveLifecycleBeyondBootstrapWindow seeded running turnID=\(envelope.turnID)")
                return
            }
            let pageMin = page.map(\.offset).min() ?? 0
            if pageMin <= 0 {
                return
            }
            pageAnchorOffset = pageMin
        }
    }

    private static func parseLifecycleEnvelope(line: String) -> (type: String, turnID: String)? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["type"] as? String == "event_msg",
              let payload = object["payload"] as? [String: Any],
              let payloadType = payload["type"] as? String,
              ["task_started", "task_complete", "turn_aborted"].contains(payloadType),
              let turnID = payload["turn_id"] as? String,
              !turnID.isEmpty else {
            return nil
        }
        return (payloadType, turnID)
    }

    private func handleTailerInvalidation() {
        // The transcript source is gone: a delete-and-recreate at the SAME
        // path is a new source identity exactly like a registry path change —
        // the FULL epoch reset applies (history, Hub live/seen, parser
        // correlation, activeWorkingTurnID, sidebar/turn state), not a bare
        // resolver restart.
        beginNewSourceEpoch()
        if resolverTimer == nil {
            startResolver()
        }
    }

    // Everything that could let the OLD source suppress or leak into the NEW
    // one is revoked: the old tailer (no late injection), the historical
    // window/retention, the Hub's stored LIVE + historical products AND
    // idempotency sets (a reused eventID/offset — same-path delete+recreate —
    // must be re-acceptable, not dropped as a duplicate), and every
    // parser/turn/sidebar correlation state, INCLUDING activeWorkingTurnID —
    // a blank/idle new source must never inherit the old source's Working.
    // Seq high-water survives so subscriber cursors stay monotonic across
    // the switch. Shared by both a registry identity switch (switchTranscriptIdentity)
    // and a same-path tailer invalidation (handleTailerInvalidation) — see
    // ClaudeTranscriptSession.beginNewSourceEpoch for the analogous contract.
    private func beginNewSourceEpoch() {
        tailer?.stop()
        tailer = nil
        resolverTimer?.cancel()
        resolverTimer = nil
        transcriptURL = nil
        historicalRawLines = []
        collectedBackfillPage = []
        historicalReplayProducts = []
        lastBackfillPageOffsets = nil
        lastRequestedBackfillAnchorSeq = nil
        isBackfillingHistory = false
        isBootstrappingSidebarState = false
        didSeeInteractiveEvent = false
        unsupportedVersions.removeAll()
        resolvedToolCallIDs.removeAll()
        publishedAssistantTextKeys.removeAll()
        bootstrappedShellState = .prompt
        currentShellState = .prompt
        lastStartedTurnID = nil
        lastCompletedTurnID = nil
        lastAbortedTurnID = nil
        bootstrapWindowTerminalTurnIDs = []
        activeWorkingTurnID = nil
        // The sidebar activation latch is per-SOURCE ownership, not
        // per-session: without resetting it, the NEW source's own bootstrap
        // completion (resolveTranscriptIfPossible's `force: false` call)
        // would silently no-op forever, permanently freezing the sidebar on
        // the OLD source's last-known running/prompt state. Resetting it
        // here (rather than requiring a `force: true` caller) means the new
        // source's bootstrap sends its OWN derived shellState exactly once,
        // whenever its file actually resolves — including an indefinite
        // delay if the new path doesn't exist yet.
        didPublishSidebarSessionActivation = false
        hub.beginNewSourceEpoch(sessionID: record.sessionID)
        hub.replaceHistoricalEvents(sessionID: record.sessionID, events: [], anchorSeq: nil)
        // A store-only reset does not, by itself, notify an ALREADY-SUBSCRIBED
        // client that was mid-turn on the OLD source — its local reducer
        // keeps showing Working until some new clearing event arrives. Both
        // iOS ChatTranscriptReducer and ChatResponseState treat a live
        // `.sessionStarted` as an unconditional Working/expecting-response
        // reset for the current session, so it is LIVE-DELIVERED here as the
        // new source's boundary marker — not merely stored history. The seq
        // is minted from the Hub's OWN cross-producer reservation
        // (nextSyntheticSeq), not this session's local high-water: local
        // `maxObservedSeq` has no visibility into any Hub-side rebase, and a
        // boundary minted from stale local state could collide with the new
        // source's own offset-0/ordinal-0 event.
        let reservedBoundarySeq = hub.nextSyntheticSeq(sessionID: record.sessionID)
        afterBoundaryReservationBeforePublishHook.fire()
        let publishedBoundarySeq = publishSynthetic(kind: .sessionStarted,
                         seq: reservedBoundarySeq,
                         eventID: "source-epoch:\(record.sessionID):\(reservedBoundarySeq)",
                         timestamp: ISO8601DateFormatter().string(from: Date()),
                         role: nil,
                         text: nil,
                         name: nil,
                         input: nil,
                         output: nil,
                         toolCallID: nil,
                         metadata: baseMetadata(["cwd": record.cwd]))
        if publishedBoundarySeq == nil {
            BridgeLogger.server.error("codex source epoch boundary marker was not stored; epoch base not advanced from unstored reservation session_id=\(self.record.sessionID, privacy: .public) reserved_seq=\(reservedBoundarySeq, privacy: .public)")
        }
        // The new source's own offset-0/ordinal-0 event must land STRICTLY
        // above the boundary (publishSynthetic already folded the TRUE
        // stored seq into maxObservedSeq above, or left maxObservedSeq
        // unchanged if the marker failed to store).
        transcriptSequenceBase = maxObservedSeq
    }

    private func switchTranscriptIdentity() {
        // A new transcript identity REVOKES the previous identity's history
        // AND live state immediately — the ownership boundary must not wait
        // for a future (possibly never-happening) successful backfill of the
        // new file, and a blank/idle new source must never keep showing the
        // old source's Working indicator.
        beginNewSourceEpoch()
        startResolver()
    }

    // Priority order:
    // 1. An EXPLICIT record.transcriptPath is EXCLUSIVE, exactly like
    //    ClaudeTranscriptSession.resolveTranscriptURL: when the record
    //    names a specific file, that file is the ONLY authority — if it
    //    exists, it is accepted unconditionally (no filename/threadID
    //    check at all: a plain codex CLI rollout's filename never embeds a
    //    thread id, so requiring one here would reject a perfectly valid,
    //    already-known file the moment thread metadata is added alongside
    //    it — see testThreadMetadataOnlyAdditionDoesNotResetSource). If it
    //    does NOT yet exist, this returns nil and NEVER falls through to
    //    the process-tree/directory scan below — that fallback can
    //    re-match the OLD (already-switched-away-from) source's file via a
    //    stale resumeThreadID/sessionID membership check (a plain CLI
    //    record has no authoritative threadID at all), silently
    //    reattaching revoked source A instead of waiting for explicit B to
    //    actually appear on disk. `startResolver`'s periodic retry keeps
    //    calling this until B's own file exists.
    // 2. Only when the record carries NO usable explicit path at all does
    //    the fallback chain run: record.threadID is a known AUTHORITATIVE
    //    value ⇒ every fallback candidate (process-tree, directory
    //    enumeration) MUST match that thread identity — keeps a delayed
    //    rollout from being satisfied by re-matching an unrelated file.
    // 3. threadID is ALSO absent: fall back to resumeThreadID/sessionID as
    //    the fallback identity set (the ordinary "no authoritative thread
    //    known yet" case).
    private func resolveTranscriptURL() -> URL? {
        if let transcriptPath = Self.explicitTranscriptPath(from: record) {
            let url = URL(fileURLWithPath: NSString(string: transcriptPath).expandingTildeInPath)
            return fileManager.fileExists(atPath: url.path) ? url : nil
        }

        let authoritativeThreadID = record.threadID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasAuthoritativeThreadID = authoritativeThreadID?.isEmpty == false

        func matchesAuthoritativeThreadIfKnown(_ url: URL) -> Bool {
            guard hasAuthoritativeThreadID, let authoritativeThreadID else {
                return true
            }
            return url.lastPathComponent.contains(authoritativeThreadID)
        }

        if let processTreeResolved = resolveTranscriptURLFromProcessTree(),
           matchesAuthoritativeThreadIfKnown(processTreeResolved) {
            return processTreeResolved
        }

        let sessionsDirectory = sessionsDirectoryOverride ?? fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions", isDirectory: true)

        guard let enumerator = fileManager.enumerator(at: sessionsDirectory,
                                                      includingPropertiesForKeys: [.isRegularFileKey],
                                                      options: [.skipsHiddenFiles]) else {
            return nil
        }
        let enumerationIdentities = hasAuthoritativeThreadID ? [authoritativeThreadID!] : transcriptSessionIDs
        for case let url as URL in enumerator {
            guard url.lastPathComponent.hasPrefix("rollout-"),
                  url.pathExtension == "jsonl",
                  enumerationIdentities.contains(where: { url.lastPathComponent.contains($0) }) else {
                continue
            }
            return url
        }
        return nil
    }

    private var transcriptSessionIDs: [String] {
        var values = [String]()
        for value in [record.sessionID, record.threadID, record.resumeThreadID] {
            guard let value,
                  !value.isEmpty,
                  !values.contains(value) else {
                continue
            }
            values.append(value)
        }
        return values
    }

    private func resolveTranscriptURLFromProcessTree() -> URL? {
        for rootPID in transcriptResolutionRootPIDs() {
            guard let path = Self.rolloutPathForPIDTree(rootPID: rootPID),
                  !path.isEmpty else {
                continue
            }
            let expanded = NSString(string: path).expandingTildeInPath
            let url = URL(fileURLWithPath: expanded)
            guard fileManager.fileExists(atPath: url.path) else {
                continue
            }
            return url
        }
        return nil
    }

    private func transcriptResolutionRootPIDs() -> [Int32] {
        let candidates = [record.appServerPID, record.remoteTUIPID, record.pid].compactMap { $0 }
        var seen = Set<Int32>()
        return candidates.filter { pid in
            guard pid > 0 else {
                return false
            }
            return seen.insert(pid).inserted
        }
    }

    private func consume(line: String, lineOffset: Int) {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String,
              let payload = object["payload"] as? [String: Any] else {
            return
        }

        let timestamp = (object["timestamp"] as? String) ?? ISO8601DateFormatter().string(from: Date())

        switch type {
        case "session_meta":
            consumeSessionMeta(payload: payload, timestamp: timestamp, lineOffset: lineOffset)
        case "response_item":
            consumeResponseItem(payload: payload, timestamp: timestamp, lineOffset: lineOffset)
        case "event_msg":
            consumeEventMessage(payload: payload, timestamp: timestamp, lineOffset: lineOffset)
        default:
            break
        }
    }

    private func consumeSessionMeta(payload: [String: Any], timestamp: String, lineOffset: Int) {
        guard let sessionID = payload["id"] as? String,
              transcriptSessionIDs.contains(sessionID) else {
            return
        }
        if let cliVersion = payload["cli_version"] as? String,
           !cliVersion.hasPrefix(codexTranscriptMajorVersion),
           !unsupportedVersions.contains(cliVersion) {
            unsupportedVersions.insert(cliVersion)
            publishFileBacked(kind: .status,
                              lineOffset: lineOffset,
                              ordinal: 0,
                              eventID: "status:\(record.sessionID):\(fileBackedSequence(lineOffset: lineOffset, ordinal: 0)):unsupported-version:\(cliVersion)",
                              timestamp: timestamp,
                              role: nil,
                              text: "Unsupported Codex transcript version \(cliVersion)",
                              name: nil,
                              input: nil,
                              output: nil,
                              toolCallID: nil,
                              metadata: baseMetadata(["reason": "unsupported_version"]))
        }
    }

    private func consumeResponseItem(payload: [String: Any], timestamp: String, lineOffset: Int) {
        guard let payloadType = payload["type"] as? String else {
            return
        }

        switch payloadType {
        case "message":
            consumeMessageItem(payload: payload, timestamp: timestamp, lineOffset: lineOffset)
        case "function_call":
            consumeFunctionCall(payload: payload, timestamp: timestamp, lineOffset: lineOffset)
        case "function_call_output":
            consumeFunctionCallOutput(payload: payload, timestamp: timestamp, lineOffset: lineOffset)
        case "custom_tool_call":
            consumeCustomToolCall(payload: payload, timestamp: timestamp, lineOffset: lineOffset)
        case "custom_tool_call_output":
            consumeCustomToolCallOutput(payload: payload, timestamp: timestamp, lineOffset: lineOffset)
        case "reasoning":
            break
        default:
            break
        }
    }

    private func consumeMessageItem(payload: [String: Any], timestamp: String, lineOffset: Int) {
        guard let role = payload["role"] as? String else {
            return
        }

        let phase = payload["phase"] as? String
        let text = Self.compactString(Self.extractMessageText(from: payload["content"]))
        guard !text.isEmpty else {
            return
        }

        switch role {
        case "assistant":
            if phase == "commentary" || phase == "final_answer" {
                return
            }
            didSeeInteractiveEvent = true
            publishAssistantText(kind: .assistantMessage,
                                 eventNamespace: "assistant",
                                 phase: phase ?? "message",
                                 timestamp: timestamp,
                                 text: text,
                                 lineOffset: lineOffset,
                                 ordinal: 0)

        case "user":
            guard shouldPublishUserMessage(text) else {
                return
            }
            publishFileBacked(kind: .userMessage,
                              lineOffset: lineOffset,
                              ordinal: 0,
                              eventID: "user:\(record.sessionID):\(fileBackedSequence(lineOffset: lineOffset, ordinal: 0))",
                              timestamp: timestamp,
                              role: role,
                              text: text,
                              name: nil,
                              input: nil,
                              output: nil,
                              toolCallID: nil,
                              metadata: nil)

        default:
            break
        }
    }

    private func consumeFunctionCall(payload: [String: Any], timestamp: String, lineOffset: Int) {
        guard let callID = payload["call_id"] as? String else {
            return
        }

        didSeeInteractiveEvent = true
        publishFileBacked(kind: .toolCall,
                          lineOffset: lineOffset,
                          ordinal: 0,
                          eventID: callID,
                          timestamp: timestamp,
                          role: "assistant",
                          text: nil,
                          name: (payload["name"] as? String) ?? "tool",
                          input: Self.compactString(payload["arguments"] as? String),
                          output: nil,
                          toolCallID: callID,
                          metadata: nil)
        publishWorkingContinuation(reason: "tool_call", timestamp: timestamp, lineOffset: lineOffset, ordinal: 1)
    }

    private func consumeFunctionCallOutput(payload: [String: Any], timestamp: String, lineOffset: Int) {
        guard let callID = payload["call_id"] as? String,
              !resolvedToolCallIDs.contains(callID) else {
            return
        }
        let output = Self.compactString(Self.extractMessageText(from: payload["output"]))
        guard !output.isEmpty else {
            return
        }

        didSeeInteractiveEvent = true
        resolvedToolCallIDs.insert(callID)
        publishFileBacked(kind: .toolResult,
                          lineOffset: lineOffset,
                          ordinal: 0,
                          eventID: "\(callID):function-output",
                          timestamp: timestamp,
                          role: "tool",
                          text: nil,
                          name: nil,
                          input: nil,
                          output: output,
                          toolCallID: callID,
                          metadata: ["source": "function_call_output"])
    }

    private func consumeCustomToolCall(payload: [String: Any], timestamp: String, lineOffset: Int) {
        guard let callID = payload["call_id"] as? String else {
            return
        }

        didSeeInteractiveEvent = true
        publishFileBacked(kind: .toolCall,
                          lineOffset: lineOffset,
                          ordinal: 0,
                          eventID: callID,
                          timestamp: timestamp,
                          role: "assistant",
                          text: nil,
                          name: (payload["name"] as? String) ?? "tool",
                          input: Self.stringifyToolPayload(payload["input"]),
                          output: nil,
                          toolCallID: callID,
                          metadata: nil)
        publishWorkingContinuation(reason: "tool_call", timestamp: timestamp, lineOffset: lineOffset, ordinal: 1)
    }

    private func consumeCustomToolCallOutput(payload: [String: Any], timestamp: String, lineOffset: Int) {
        guard let callID = payload["call_id"] as? String,
              !resolvedToolCallIDs.contains(callID) else {
            return
        }
        let output = Self.compactString(Self.extractMessageText(from: payload["output"]))
        guard !output.isEmpty else {
            return
        }

        didSeeInteractiveEvent = true
        resolvedToolCallIDs.insert(callID)
        publishFileBacked(kind: .toolResult,
                          lineOffset: lineOffset,
                          ordinal: 0,
                          eventID: "\(callID):custom-tool-output",
                          timestamp: timestamp,
                          role: "tool",
                          text: nil,
                          name: nil,
                          input: nil,
                          output: output,
                          toolCallID: callID,
                          metadata: ["source": "custom_tool_call_output"])
    }

    private func consumeEventMessage(payload: [String: Any], timestamp: String, lineOffset: Int) {
        guard let payloadType = payload["type"] as? String else {
            return
        }

        switch payloadType {
        case "agent_message":
            consumeAgentMessage(payload: payload, timestamp: timestamp, lineOffset: lineOffset)
        case "task_started":
            consumeTaskStarted(payload: payload, timestamp: timestamp, lineOffset: lineOffset)
        case "task_complete":
            consumeTaskComplete(payload: payload, timestamp: timestamp, lineOffset: lineOffset)
        case "turn_aborted":
            consumeTurnAborted(payload: payload, timestamp: timestamp, lineOffset: lineOffset)
        case "exec_command_end":
            consumeExecCommandEnd(payload: payload, timestamp: timestamp, lineOffset: lineOffset)
        case "patch_apply_end":
            consumePatchApplyEnd(payload: payload, timestamp: timestamp, lineOffset: lineOffset)
        default:
            break
        }
    }

    private func consumeTaskStarted(payload: [String: Any], timestamp: String, lineOffset: Int) {
        // During a historical replay this mutates the ISOLATED historical
        // parser state (dedupe by turn id still applies); the sidebar
        // publication below is gated separately and the live state is
        // restored after the replay.
        guard let turnID = payload["turn_id"] as? String,
              !turnID.isEmpty,
              turnID != lastStartedTurnID else {
            return
        }
        lastStartedTurnID = turnID
        activeWorkingTurnID = turnID
        publishWorkingAnchor(turnID: turnID, timestamp: timestamp, lineOffset: lineOffset)

        if isBootstrappingSidebarState {
            bootstrappedShellState = .running
            currentShellState = .running
            return
        }

        guard currentShellState != .running else { return }
        currentShellState = .running
        log("consumeTaskStarted publish running turnID=\(turnID)")
        publishSidebar(messages: CodexSidebarMessages.running(workspaceID: record.workspaceID))
    }

    private func consumeTaskComplete(payload: [String: Any], timestamp: String, lineOffset: Int) {
        // During a historical replay this mutates the ISOLATED historical
        // parser state (dedupe by turn id still applies); the sidebar
        // publication below is gated separately and the live state is
        // restored after the replay.
        guard let turnID = payload["turn_id"] as? String,
              !turnID.isEmpty,
              turnID != lastCompletedTurnID else {
            return
        }
        lastCompletedTurnID = turnID
        if isBootstrappingSidebarState {
            bootstrapWindowTerminalTurnIDs.insert(turnID)
        }
        let body = Self.compactString(payload["last_agent_message"] as? String)
        // Captured BEFORE publishWorkingTerminal (which clears activeWorkingTurnID
        // on a genuine match) — a terminal for a DIFFERENT turn than the one
        // currently tracked as active is stale for BOTH the chat Working
        // indicator AND the sidebar shell-state transition: it must not end
        // whatever turn actually IS active, or tell the sidebar we went idle.
        let isStaleForActiveTurn = activeWorkingTurnID != nil && activeWorkingTurnID != turnID
        publishWorkingTerminal(turnID: turnID, timestamp: timestamp, lineOffset: lineOffset)

        // The stale-active-turn fence gates ANY shell-state mutation — live
        // OR bootstrap — before either branch below: a late/stale terminal
        // for a turn that is not the one currently tracked as active must
        // not flip bootstrappedShellState/currentShellState to prompt
        // either, even while still deriving the initial bootstrap snapshot.
        guard !isStaleForActiveTurn else {
            log("consumeTaskComplete ignoring stale terminal turnID=\(turnID) activeWorkingTurnID=\(activeWorkingTurnID ?? "<nil>")")
            return
        }

        if isBootstrappingSidebarState {
            bootstrappedShellState = .prompt
            currentShellState = .prompt
            return
        }

        currentShellState = .prompt
        if body.isEmpty {
            log("consumeTaskComplete publish prompt turnID=\(turnID)")
            publishSidebar(messages: CodexSidebarMessages.prompt(workspaceID: record.workspaceID))
            return
        }
        log("consumeTaskComplete publish completed turnID=\(turnID) bodyLength=\(body.count)")
        publishSidebar(messages: CodexSidebarMessages.completed(workspaceID: record.workspaceID,
                                                               body: body))
    }

    private func consumeTurnAborted(payload: [String: Any], timestamp: String, lineOffset: Int) {
        // During a historical replay this mutates the ISOLATED historical
        // parser state (dedupe by turn id still applies); the sidebar
        // publication below is gated separately and the live state is
        // restored after the replay.
        guard let turnID = payload["turn_id"] as? String,
              !turnID.isEmpty,
              turnID != lastAbortedTurnID else {
            return
        }
        lastAbortedTurnID = turnID
        if isBootstrappingSidebarState {
            bootstrapWindowTerminalTurnIDs.insert(turnID)
        }
        let isStaleForActiveTurn = activeWorkingTurnID != nil && activeWorkingTurnID != turnID
        publishWorkingTerminal(turnID: turnID, timestamp: timestamp, lineOffset: lineOffset)

        guard !isStaleForActiveTurn else {
            log("consumeTurnAborted ignoring stale terminal turnID=\(turnID) activeWorkingTurnID=\(activeWorkingTurnID ?? "<nil>")")
            return
        }

        if isBootstrappingSidebarState {
            bootstrappedShellState = .prompt
            currentShellState = .prompt
            return
        }

        guard currentShellState != .prompt else { return }
        currentShellState = .prompt
        log("consumeTurnAborted publish prompt turnID=\(turnID)")
        publishSidebar(messages: CodexSidebarMessages.prompt(workspaceID: record.workspaceID))
    }

    private func consumeAgentMessage(payload: [String: Any], timestamp: String, lineOffset: Int) {
        let text = Self.compactString(payload["message"] as? String)
        guard !text.isEmpty else {
            return
        }

        didSeeInteractiveEvent = true
        let phase = payload["phase"] as? String
        switch phase {
        case "final_answer":
            publishAssistantText(kind: .assistantFinal,
                                 eventNamespace: "final",
                                 phase: "final_answer",
                                 timestamp: timestamp,
                                 text: text,
                                 lineOffset: lineOffset,
                                 ordinal: 0)
        case "commentary":
            publishAssistantText(kind: .assistantMessage,
                                 eventNamespace: "commentary",
                                 phase: "commentary",
                                 timestamp: timestamp,
                                 text: text,
                                 lineOffset: lineOffset,
                                 ordinal: 0)
        default:
            break
        }
    }

    private func publishAssistantText(kind: AgentEventKind,
                                      eventNamespace: String,
                                      phase: String,
                                      timestamp: String,
                                      text: String,
                                      lineOffset: Int,
                                      ordinal: Int) {
        let dedupeKey = "\(kind.rawValue)|\(phase)|\(timestamp)|\(text)"
        guard !publishedAssistantTextKeys.contains(dedupeKey) else {
            return
        }
        publishedAssistantTextKeys.insert(dedupeKey)
        let seq = fileBackedSequence(lineOffset: lineOffset, ordinal: ordinal)
        publishFileBacked(kind: kind,
                          lineOffset: lineOffset,
                          ordinal: ordinal,
                          eventID: "\(eventNamespace):\(record.sessionID):\(seq)",
                          timestamp: timestamp,
                          role: "assistant",
                          text: text,
                          name: nil,
                          input: nil,
                          output: nil,
                          toolCallID: nil,
                          metadata: ["phase": phase])
        // Both commentary/ordinary assistant messages AND the final answer
        // clear the client's Working indicator (see publishWorkingContinuation) —
        // but the turn is only authoritatively done at task_complete/turn_aborted.
        publishWorkingContinuation(reason: eventNamespace, timestamp: timestamp, lineOffset: lineOffset, ordinal: ordinal + 1)
    }

    private func consumeExecCommandEnd(payload: [String: Any], timestamp: String, lineOffset: Int) {
        guard let callID = payload["call_id"] as? String,
              !resolvedToolCallIDs.contains(callID) else {
            return
        }
        let output = Self.compactString(
            (payload["aggregated_output"] as? String) ??
            (payload["formatted_output"] as? String) ??
            (payload["stdout"] as? String) ??
            (payload["stderr"] as? String)
        )
        guard !output.isEmpty else {
            return
        }

        didSeeInteractiveEvent = true
        resolvedToolCallIDs.insert(callID)
        publishFileBacked(kind: .toolResult,
                          lineOffset: lineOffset,
                          ordinal: 0,
                          eventID: "\(callID):exec-end",
                          timestamp: timestamp,
                          role: "tool",
                          text: nil,
                          name: nil,
                          input: nil,
                          output: output,
                          toolCallID: callID,
                          metadata: Self.metadata(
                              source: "exec_command_end",
                              values: [
                                  "exit_code": Self.stringValue(payload["exit_code"]),
                                  "status": payload["status"] as? String,
                              ]
                          ))
    }

    private func consumePatchApplyEnd(payload: [String: Any], timestamp: String, lineOffset: Int) {
        guard let callID = payload["call_id"] as? String,
              !resolvedToolCallIDs.contains(callID) else {
            return
        }
        let output = Self.compactString(
            (payload["stdout"] as? String) ??
            (payload["stderr"] as? String)
        )
        guard !output.isEmpty else {
            return
        }

        didSeeInteractiveEvent = true
        resolvedToolCallIDs.insert(callID)
        publishFileBacked(kind: .toolResult,
                          lineOffset: lineOffset,
                          ordinal: 0,
                          eventID: "\(callID):patch-end",
                          timestamp: timestamp,
                          role: "tool",
                          text: nil,
                          name: nil,
                          input: nil,
                          output: output,
                          toolCallID: callID,
                          metadata: Self.metadata(
                              source: "patch_apply_end",
                              values: [
                                  "success": Self.boolString(payload["success"]),
                                  "status": payload["status"] as? String,
                              ]
                          ))
    }

    private func shouldPublishUserMessage(_ text: String) -> Bool {
        guard !text.isEmpty else {
            return false
        }
        if Self.isBootstrapUserMessage(text) {
            return false
        }
        if didSeeInteractiveEvent {
            return true
        }
        return true
    }

    private func publishFileBacked(kind: AgentEventKind,
                                   lineOffset: Int,
                                   ordinal: Int,
                                   eventID: String,
                                   timestamp: String,
                                   role: String?,
                                   text: String?,
                                   name: String?,
                                   input: String?,
                                   output: String?,
                                   toolCallID: String?,
                                   metadata: [String: String]?) {
        let seq = fileBackedSequence(lineOffset: lineOffset, ordinal: ordinal)
        maxObservedSeq = max(maxObservedSeq, seq)
        let resolvedMetadata = metadataWithClientRequestID(kind: kind, text: text, metadata: metadata)
        let event = AgentEvent(eventID: eventID,
                               seq: seq,
                               vendor: "codex",
                               workspaceID: record.workspaceID,
                               sessionID: record.sessionID,
                               timestamp: timestamp,
                               type: kind,
                               role: role,
                               text: text,
                               name: name,
                               input: input,
                               output: output,
                               toolCallID: toolCallID,
                               metadata: baseMetadata(resolvedMetadata))
        if isBackfillingHistory {
            // Historical replay is a transaction: products are collected and
            // applied to the Hub as one atomic replacement afterwards.
            historicalReplayProducts.append(event)
            return
        }
        hub.publish(event)
    }

    // MARK: - Working-indicator lifecycle translation
    //
    // The client's Working row is derived from the raw AgentEvent stream: a
    // `.thinking` event anchors it, and `.assistantMessage`/`.toolCall`/
    // `.assistantFinal` clear it (with a separate, fragile "expecting a
    // response" fallback that a `.toolResult` restores). A real Codex turn
    // legitimately produces several of those clearing events (commentary,
    // tool calls, a final answer) *before* task_complete/turn_aborted
    // authoritatively ends the turn — so each clearing event must be
    // followed by a continuation `.thinking` for the SAME turn, and only the
    // turn's authoritative terminal may end Working. These three helpers are
    // deliberately NEVER invoked during historical replay (isBackfillingHistory):
    // an old/incomplete historical turn must never leave a stray `.thinking`
    // in the Hub's historical store with no visible terminal counterpart.

    private func publishWorkingAnchor(turnID: String, timestamp: String, lineOffset: Int) {
        guard !isBackfillingHistory else {
            return
        }
        let seq = fileBackedSequence(lineOffset: lineOffset, ordinal: 0)
        publishFileBacked(kind: .thinking,
                          lineOffset: lineOffset,
                          ordinal: 0,
                          eventID: "thinking:\(record.sessionID):\(seq)",
                          timestamp: timestamp,
                          role: nil,
                          text: nil,
                          name: nil,
                          input: nil,
                          output: nil,
                          toolCallID: nil,
                          metadata: ["turn_id": turnID, "reason": "task_started"])
    }

    private func publishWorkingContinuation(reason: String, timestamp: String, lineOffset: Int, ordinal: Int) {
        guard !isBackfillingHistory, let turnID = activeWorkingTurnID else {
            return
        }
        let seq = fileBackedSequence(lineOffset: lineOffset, ordinal: ordinal)
        // "is_continuation" marks this `.thinking` as Working-indicator
        // MAINTENANCE for an already-open turn (as opposed to its opening
        // anchor, publishWorkingAnchor) — the Hub uses this exact marker to
        // decide whether an active interactive prompt (a second, independent
        // Hub producer — the app-server approval-prompt path) may suppress
        // it rather than let it wrongly flip Working back on over an active
        // needs-input/approval card. See AgentEventHub.isSuppressibleContinuation.
        publishFileBacked(kind: .thinking,
                          lineOffset: lineOffset,
                          ordinal: ordinal,
                          eventID: "thinking:\(record.sessionID):\(seq)",
                          timestamp: timestamp,
                          role: nil,
                          text: nil,
                          name: nil,
                          input: nil,
                          output: nil,
                          toolCallID: nil,
                          metadata: ["turn_id": turnID, "reason": reason, "is_continuation": "true"])
    }

    private func publishWorkingTerminal(turnID: String, timestamp: String, lineOffset: Int) {
        // A stale terminal for a turn that is not the currently tracked
        // active turn (e.g. a duplicate/out-of-order task_complete for an
        // older turn) must not end the CURRENT active turn's Working state.
        guard !isBackfillingHistory, activeWorkingTurnID == turnID else {
            return
        }
        activeWorkingTurnID = nil
        let seq = fileBackedSequence(lineOffset: lineOffset, ordinal: 0)
        publishFileBacked(kind: .assistantFinal,
                          lineOffset: lineOffset,
                          ordinal: 0,
                          eventID: "turn-terminal:\(record.sessionID):\(seq)",
                          timestamp: timestamp,
                          role: nil,
                          text: nil,
                          name: nil,
                          input: nil,
                          output: nil,
                          toolCallID: nil,
                          metadata: ["turn_id": turnID, "reason": "turn_terminal"])
    }

    // Round 7G P0 (TOCTOU fix, corrected contract): returns the ACTUAL
    // stored seq (or `nil` if not genuinely stored) exactly like
    // `AgentEventHub.publish`, and folds `maxObservedSeq` from THAT return
    // value, not the caller's claimed `seq` param. `publishSynthetic`'s
    // `seq` is sometimes a Hub cross-producer reservation
    // (`hub.nextSyntheticSeq`, e.g. beginNewSourceEpoch's boundary marker)
    // which is only a reservation, not a storage guarantee — a caller that
    // needs to seed its OWN local sequence base from this call MUST use the
    // return value, never the `seq` it passed in, and must fail closed
    // (not advance its base) on `nil`. During historical replay no Hub
    // publish happens at all (products are collected for one atomic
    // replacement later) — there the claimed `seq` IS authoritative, since
    // it never goes through the Hub's live rebase-on-collision path.
    @discardableResult
    private func publishSynthetic(kind: AgentEventKind,
                                  seq: Int,
                                  eventID: String,
                                  timestamp: String,
                                  role: String?,
                                  text: String?,
                                  name: String?,
                                  input: String?,
                                  output: String?,
                                  toolCallID: String?,
                                  metadata: [String: String]?) -> Int? {
        let event = AgentEvent(eventID: eventID,
                               seq: seq,
                               vendor: "codex",
                               workspaceID: record.workspaceID,
                               sessionID: record.sessionID,
                               timestamp: timestamp,
                               type: kind,
                               role: role,
                               text: text,
                               name: name,
                               input: input,
                               output: output,
                               toolCallID: toolCallID,
                               metadata: metadata)
        if isBackfillingHistory {
            // Historical replay is a transaction: products are collected and
            // applied to the Hub as one atomic replacement afterwards.
            historicalReplayProducts.append(event)
            maxObservedSeq = max(maxObservedSeq, seq)
            return seq
        }
        let publishedSeq = hub.publish(event)
        if let publishedSeq {
            maxObservedSeq = max(maxObservedSeq, publishedSeq)
        }
        return publishedSeq
    }

    private func publishSidebarSessionActivation(force: Bool) {
        guard force || !didPublishSidebarSessionActivation else {
            return
        }
        didPublishSidebarSessionActivation = true
        let shellState = isBootstrappingSidebarState ? bootstrappedShellState : currentShellState
        currentShellState = shellState
        log("publishSidebarSessionActivation force=\(force) shellState=\(shellState) workspace=\(record.workspaceID)")
        publishSidebar(messages: CodexSidebarMessages.sessionActive(workspaceID: record.workspaceID,
                                                                   shellState: shellState))
    }

    private func publishSidebar(messages: [String]) {
        // Historical replay never reaches the sidebar.
        guard isBackfillingHistory == false else {
            return
        }
        // Held during a prepared workspace-migration transaction — BUFFER
        // this exact batch, in order; finishUpdate() flushes every buffered
        // batch once released. See isSidebarPublicationHeld.
        guard isSidebarPublicationHeld == false else {
            heldSidebarMessageBatches.append(messages)
            log("publishSidebar buffered during workspace migration transaction messages=\(messages)")
            return
        }
        sendSidebarMessagesNow(messages)
    }

    private func sendSidebarMessagesNow(_ messages: [String]) {
        guard let socketClient else {
            log("publishSidebar skipped socketClient=nil messages=\(messages)")
            return
        }
        for message in messages {
            do {
                try socketClient.send(command: message)
                log("publishSidebar sent message=\(message)")
            } catch {
                log("publishSidebar failed message=\(message) error=\(error)")
            }
        }
    }

    private func log(_ message: String) {
        // Historical replay's only side effect is historical storage.
        guard isBackfillingHistory == false else {
            return
        }
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "\(timestamp) [\(record.workspaceID)] [\(record.sessionID)] \(message)\n"
        guard let data = line.data(using: .utf8) else {
            return
        }
        if fileManager.fileExists(atPath: codexSidebarLogURL.path),
           let handle = try? FileHandle(forWritingTo: codexSidebarLogURL) {
            defer { try? handle.close() }
            do {
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } catch {
                try? data.write(to: codexSidebarLogURL, options: .atomic)
            }
            return
        }
        try? data.write(to: codexSidebarLogURL, options: .atomic)
    }

    private func nextSyntheticSequence() -> Int {
        maxObservedSeq += 1
        return maxObservedSeq
    }

    private func transcriptEventSequenceAnchor(forLineOffset lineOffset: Int) -> Int {
        transcriptSequenceBase + transcriptEventSequence(lineOffset: lineOffset, ordinal: 0)
    }

    private func fileBackedSequence(lineOffset: Int, ordinal: Int) -> Int {
        transcriptSequenceBase + transcriptEventSequence(lineOffset: lineOffset, ordinal: ordinal)
    }


    private func baseMetadata(_ metadata: [String: String]?) -> [String: String]? {
        var merged = metadata ?? [:]
        if let panelID = record.panelID, !panelID.isEmpty {
            merged["panel_id"] = panelID
        }
        return merged.isEmpty ? nil : merged
    }

    private func metadataWithClientRequestID(kind: AgentEventKind,
                                             text: String?,
                                             metadata: [String: String]?) -> [String: String]? {
        // Backfill is storage-only: history must NOT consume the live submit
        // echo registry — the true live echo still needs its correlation.
        guard isBackfillingHistory == false,
              kind == .userMessage,
              let text,
              let clientRequestID = chatSubmitEchoRegistry.consumeClientRequestID(workspaceID: record.workspaceID,
                                                                                  panelID: record.panelID,
                                                                                  sessionID: record.sessionID,
                                                                                  vendor: "codex",
                                                                                  text: text) else {
            return metadata
        }
        var merged = metadata ?? [:]
        merged["client_request_id"] = clientRequestID
        return merged
    }

    private static func extractMessageText(from value: Any?) -> String {
        if let string = value as? String {
            return string
        }
        guard let blocks = value as? [[String: Any]] else {
            return ""
        }

        let parts = blocks.compactMap { block -> String? in
            guard let type = block["type"] as? String else {
                return nil
            }
            switch type {
            case "input_text", "output_text", "text", "summary_text":
                return block["text"] as? String
            default:
                return nil
            }
        }
        return parts.joined(separator: "\n\n")
    }

    private static func stringifyToolPayload(_ value: Any?) -> String? {
        if let string = value as? String {
            return string.isEmpty ? nil : string
        }
        guard let value,
              JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private static func isBootstrapUserMessage(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixes = [
            "# AGENTS.md instructions",
            "<environment_context>",
            "<permissions instructions>",
            "<app-context>",
        ]
        return prefixes.contains { trimmed.hasPrefix($0) }
    }

    private static func compactString(_ value: String?) -> String {
        guard let value else {
            return ""
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stringValue(_ value: Any?) -> String? {
        if let string = value as? String {
            return string
        }
        if let number = value as? NSNumber {
            return number.stringValue
        }
        return nil
    }

    private static func boolString(_ value: Any?) -> String? {
        guard let bool = value as? Bool else {
            return nil
        }
        return bool ? "true" : "false"
    }

    private static func metadata(source: String, values: [String: String?]) -> [String: String] {
        var metadata = ["source": source]
        for (key, value) in values {
            if let value, !value.isEmpty {
                metadata[key] = value
            }
        }
        return metadata
    }

    private static func rolloutPathForPIDTree(rootPID: Int32) -> String? {
        guard rootPID > 0 else {
            return nil
        }

        var queue = [rootPID]
        var visited = Set<Int32>([rootPID])

        while !queue.isEmpty {
            let pid = queue.removeFirst()
            if let path = rolloutPathForPID(pid), !path.isEmpty {
                return path
            }
            for child in childPIDs(for: pid) where !visited.contains(child) {
                visited.insert(child)
                queue.append(child)
            }
        }

        return nil
    }

    private static func rolloutPathForPID(_ pid: Int32) -> String? {
        guard pid > 0 else {
            return nil
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-Fn", "-p", String(pid)]
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        guard process.terminationStatus == 0,
              let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(),
                                  encoding: .utf8) else {
            return nil
        }

        return output.split(separator: "\n")
            .compactMap { line -> String? in
                guard line.hasPrefix("n") else {
                    return nil
                }
                let path = String(line.dropFirst())
                guard path.contains("/.codex/sessions/"),
                      path.contains("/rollout-"),
                      path.hasSuffix(".jsonl") else {
                    return nil
                }
                return path
            }
            .sorted()
            .last
    }

    private static func childPIDs(for pid: Int32) -> [Int32] {
        guard pid > 0 else {
            return []
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-P", String(pid)]
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return []
        }

        guard let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(),
                                  encoding: .utf8) else {
            return []
        }

        return output
            .split(whereSeparator: \.isNewline)
            .compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
    }
}
