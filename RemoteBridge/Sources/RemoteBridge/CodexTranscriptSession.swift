import Foundation

private let codexTranscriptMajorVersion = "0."
private let codexSidebarLogURL = URL(fileURLWithPath: "/tmp/tidey-bridge-codex.log")

typealias CodexTranscriptProcessRunner = (_ executablePath: String,
                                          _ arguments: [String],
                                          _ timeout: TimeInterval) -> BoundedProcessResult?

final class CodexTranscriptSession: AgentTranscriptSession {
    private static let processLookupTimeout: TimeInterval = 1
    private static let rolloutLookupTimeout: TimeInterval = 2

    private let queue: DispatchQueue
    private let fileManager: FileManager
    private let hub: AgentEventHub
    private let socketClient: TideyCommandSending?
    private let chatSubmitEchoRegistry: ChatSubmitEchoRegistry
    private let processRunner: CodexTranscriptProcessRunner

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
    private var historicalRawLines: [(offset: Int, line: String)] = []
    private var historicalReplayProducts: [AgentEvent] = []
    private var isCollectingBackfillPage = false
    private var collectedBackfillPage: [(offset: Int, line: String)] = []
    private let historicalReplayWindowCapacity: Int
    private var bootstrappedShellState: CodexSidebarShellState = .prompt
    private var currentShellState: CodexSidebarShellState = .prompt
    private var didPublishSidebarSessionActivation = false
    private var lastStartedTurnID: String?
    private var lastCompletedTurnID: String?
    private var lastAbortedTurnID: String?

    private struct LiveParserStateSnapshot {
        let unsupportedVersions: Set<String>
        let resolvedToolCallIDs: Set<String>
        let publishedAssistantTextKeys: Set<String>
        let didSeeInteractiveEvent: Bool
        let lastStartedTurnID: String?
        let lastCompletedTurnID: String?
        let lastAbortedTurnID: String?
        let currentShellState: CodexSidebarShellState
        let bootstrappedShellState: CodexSidebarShellState
    }

    private var lastRequestedBackfillAnchorSeq: Int?

    // MARK: After-cursor replay seams (S9; wired by B17)

    // Request-local after-cursor replay collection: exists only for the
    // lifetime of one afterCursorStep; while present, replay products are
    // routed here and never into the legacy shared replay state.
    private struct AfterCursorReplayCollector {
        var products = [AgentEvent]()
        var positionsByEventID = [String: TranscriptEventPosition]()
    }
    private var afterCursorReplayCollector: AfterCursorReplayCollector?
    // Advances on every source reset; stale tailer invalidation callbacks
    // compare against it so one active source resets exactly once.
    private var activeSourceGeneration = 0
    // Deterministic injection point: fires after a step's raw read has
    // completed (page collected) and before any final validation/return.
    var afterCursorStepAfterRawReadForTesting: (() -> Void)?
    // Forwarded to the active tailer: fires after the backfill's initial
    // source fence and before the reader opens the file (realistic
    // path-read I/O fault point).
    var tailerBackfillBeforeReadForTesting: (() -> Void)? {
        get { queue.sync { tailer?.backfillBeforeReadForTesting } }
        set { queue.sync { tailer?.backfillBeforeReadForTesting = newValue } }
    }
    // Fires inside validateHistoryEpoch before the source validation.
    var validateHistoryEpochBeforeSourceValidationForTesting: (() -> Void)?
    // Fires inside afterCursorPlan before the source validation.
    var afterCursorPlanBeforeSourceValidationForTesting: (() -> Void)?
    // Semantic trust over the CURRENT source (S10 state; enforced by the
    // closure-B row): poisoned by invalid UTF-8 / malformed JSON /
    // unsupported schema, re-established only when a replacement source
    // attaches.
    private var sourceSemanticTrust = true
    // The raw floor of the CURRENT source's initial bootstrap/live
    // publication window (S10 state; enforced by the closure-C row).
    // Request-owned steps and legacy scans must NEVER lower it — it is the
    // retained-coverage eligibility floor, distinct from the tailer's scan
    // floor.
    private var livePublishedRawFloor: Int?
    // Exact public seq → raw position (populated by the typed walk); the
    // eventID → accepted/rebased public sequence mapping is B18's row and
    // stays empty until then.
    private var exactTranscriptPositionByPublicSequence = [Int: TranscriptEventPosition]()
    private var publicTranscriptSequenceByEventID = [String: Int]()

    // Exact-map hit wins; otherwise the existing base arithmetic fallback.
    private func transcriptEventPositionInCurrentSource(for seq: Int) -> TranscriptEventPosition? {
        if let exactPosition = exactTranscriptPositionByPublicSequence[seq] {
            return exactPosition
        }
        guard seq > transcriptSequenceBase else {
            return nil
        }
        return transcriptEventPosition(for: seq - transcriptSequenceBase)
    }

    private func captureLiveParserState() -> LiveParserStateSnapshot {
        LiveParserStateSnapshot(unsupportedVersions: unsupportedVersions,
                                resolvedToolCallIDs: resolvedToolCallIDs,
                                publishedAssistantTextKeys: publishedAssistantTextKeys,
                                didSeeInteractiveEvent: didSeeInteractiveEvent,
                                lastStartedTurnID: lastStartedTurnID,
                                lastCompletedTurnID: lastCompletedTurnID,
                                lastAbortedTurnID: lastAbortedTurnID,
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
        currentShellState = snapshot.currentShellState
        bootstrappedShellState = snapshot.bootstrappedShellState
    }

    private func mergeHistoricalPage(_ page: [(offset: Int, line: String)]) {
        guard let pageMin = page.map(\.offset).min(),
              let pageMax = page.map(\.offset).max() else {
            return
        }
        var merged = page + historicalRawLines
        merged.sort { $0.offset < $1.offset }
        var seenOffsets = Set<Int>()
        merged = merged.filter { seenOffsets.insert($0.offset).inserted }
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

        let products = historicalReplayProducts
        hub.replaceHistoricalEvents(sessionID: record.sessionID,
                                    events: products,
                                    anchorSeq: lastRequestedBackfillAnchorSeq)
        historicalReplayProducts = []
        return products
    }

    init(record: AgentSessionRegistryRecord,
         fileManager: FileManager = .default,
         hub: AgentEventHub,
         socketClient: TideyCommandSending? = nil,
         chatSubmitEchoRegistry: ChatSubmitEchoRegistry? = nil,
         historicalReplayWindowCapacity: Int = 4000,
         processRunner: CodexTranscriptProcessRunner? = nil) {
        self.historicalReplayWindowCapacity = max(1, historicalReplayWindowCapacity)
        self.record = record
        self.fileManager = fileManager
        self.hub = hub
        self.socketClient = socketClient
        self.chatSubmitEchoRegistry = chatSubmitEchoRegistry ?? ChatSubmitEchoRegistry()
        self.processRunner = processRunner ?? Self.liveProcessRunner
        self.queue = DispatchQueue(label: "com.tidey.remote-bridge.codex-session.\(record.sessionID)")
    }

    func start() {
        queue.async {
            guard !self.didPublishStart else {
                return
            }
            self.didPublishStart = true
            self.publishSynthetic(kind: .sessionStarted,
                                  seq: transcriptSessionStartedSequence,
                                  eventID: "session-start:\(self.record.sessionID)",
                                  timestamp: self.record.createdAt,
                                  role: nil,
                                  text: nil,
                                  name: nil,
                                  input: nil,
                                  output: nil,
                                  toolCallID: nil,
                                  metadata: self.baseMetadata(["cwd": self.record.cwd]))
            self.startResolver()
            if self.tailer == nil {
                self.publishSidebarSessionActivation(force: false)
            }
        }
    }

    func update(record: AgentSessionRegistryRecord) {
        queue.async {
            let previousRecord = self.record
            let didMigrateWorkspace = previousRecord.workspaceID != record.workspaceID
            let didMigratePanel = previousRecord.panelID != record.panelID
            let didChangeTranscriptIdentity = self.isTranscriptIdentityChange(
                from: previousRecord, to: record)
            if didMigrateWorkspace || didMigratePanel {
                self.hub.migrateSession(sessionID: previousRecord.sessionID,
                                        toWorkspaceID: record.workspaceID,
                                        panelID: record.panelID)
            }
            self.record = record
            if didChangeTranscriptIdentity {
                self.switchTranscriptIdentity()
            }
            if didMigrateWorkspace || didMigratePanel {
                let seq = self.nextSyntheticSequence()
                self.publishSynthetic(kind: .sessionStarted,
                                      seq: seq,
                                      eventID: "session-start:\(record.sessionID):migrated:\(seq)",
                                      timestamp: ISO8601DateFormatter().string(from: Date()),
                                      role: nil,
                                      text: nil,
                                      name: nil,
                                      input: nil,
                                      output: nil,
                                      toolCallID: nil,
                                      metadata: self.baseMetadata(["cwd": record.cwd]))
                self.publishSidebarSessionActivation(force: true)
            }
            if self.transcriptURL == nil {
                self.resolveTranscriptIfPossible()
            }
        }
    }

    // Typed after-cursor plan: the Hub-issued epoch is the sole authority;
    // classification uses the tailer's contiguous raw coverage plus the
    // exact seq→position map, and every successful anchor is the FIXED
    // validated replay ceiling.
    func afterCursorPlan(afterSeq: Int,
                         expectedEpoch: AgentHistoryEpoch) -> AgentAfterCursorPlan {
        queue.sync {
            func unavailableNow() -> AgentAfterCursorPlan {
                AgentAfterCursorPlan(epoch: hub.currentHistoryEpoch(sessionID: record.sessionID),
                                     mode: .unavailable)
            }
            let capturedEpoch = hub.currentHistoryEpoch(sessionID: record.sessionID)
            guard didPublishStart, didPublishEnd == false,
                  expectedEpoch == capturedEpoch else {
                return unavailableNow()
            }
            if tailer == nil {
                resolveTranscriptIfPossible()
            }
            guard let tailer else {
                return unavailableNow()
            }
            afterCursorPlanBeforeSourceValidationForTesting?()
            // Fence BEFORE the semantic-trust gate: a poisoned source that
            // has since been replaced on disk must surface as epoch movement,
            // not sit terminal behind a stale trust=false verdict.
            do {
                try tailer.validateCurrentSource()
            } catch JSONLFileTailerError.sourceInvalidated {
                resetTranscriptSource(startResolverNow: true)
                return unavailableNow()
            } catch {
                // A transient I/O error is not a source invalidation.
                return unavailableNow()
            }
            guard sourceSemanticTrust else {
                return unavailableNow()
            }
            guard let coverage = tailer.contiguousRawCoverage else {
                return unavailableNow()
            }
            let currentEpoch = hub.currentHistoryEpoch(sessionID: record.sessionID)
            guard currentEpoch == capturedEpoch else {
                return unavailableNow()
            }
            let ceilingAnchor = AgentHistoryAnchor(
                epoch: currentEpoch,
                position: TranscriptEventPosition(lineOffset: coverage.replayUpperBoundOffset,
                                                  ordinal: 0))
            // Retained eligibility uses the LIVE-PUBLISHED floor, never the
            // tailer's current scan floor: a request-owned walk lowers the
            // scan floor but its products live only in that request's
            // response — treating them as retained coverage would let a
            // repeated fetch skip the depth entirely.
            guard let retainedFloor = livePublishedRawFloor else {
                return unavailableNow()
            }
            let rawCovered: Bool
            if retainedFloor == 0 {
                rawCovered = true
            } else if let position = exactTranscriptPositionByPublicSequence[afterSeq],
                      position.lineOffset >= retainedFloor,
                      position.lineOffset < coverage.replayUpperBoundOffset {
                rawCovered = true
            } else if afterSeq >= maxObservedSeq {
                rawCovered = true
            } else {
                rawCovered = false
            }
            return AgentAfterCursorPlan(epoch: currentEpoch,
                                        mode: rawCovered
                                            ? .rawCovered(replayFrom: ceilingAnchor)
                                            : .scan(from: ceilingAnchor))
        }
    }

    // One request-owned raw walk step: reads exactly one raw page below the
    // anchor, replays it through the parser into the request-local
    // collector, and RETURNS the products — the shared historical cache is
    // never populated from here.
    func afterCursorStep(from anchor: AgentHistoryAnchor,
                         afterSeq: Int,
                         limit: Int) -> AgentAfterCursorStep {
        queue.sync {
            var currentEpoch = hub.currentHistoryEpoch(sessionID: record.sessionID)
            func out(_ outcome: AgentAfterCursorStep.Outcome,
                     _ events: [AgentEvent] = []) -> AgentAfterCursorStep {
                AgentAfterCursorStep(epoch: currentEpoch, outcome: outcome, events: events)
            }
            guard didPublishStart, didPublishEnd == false, limit > 0 else {
                return out(.unavailable)
            }
            guard anchor.epoch == currentEpoch else {
                return out(.sourceChanged)
            }
            let anchorPosition = anchor.position
            guard anchorPosition.lineOffset > 0 || anchorPosition.ordinal > 0 else {
                return out(.complete)
            }
            if tailer == nil {
                resolveTranscriptIfPossible()
            }
            guard let tailer else {
                return out(.unavailable)
            }
            // Fence before the semantic-trust gate (same order as plan).
            do {
                try tailer.validateCurrentSource()
            } catch JSONLFileTailerError.sourceInvalidated {
                // Pre-replay: no replay state is active — resolve now.
                resetTranscriptSource(startResolverNow: true)
                currentEpoch = hub.currentHistoryEpoch(sessionID: record.sessionID)
                return out(.sourceChanged)
            } catch {
                return out(.unavailable)
            }
            guard sourceSemanticTrust else {
                return out(.unavailable)
            }

            let liveSnapshot = captureLiveParserState()
            resetParserStateForHistoricalReplay()
            afterCursorReplayCollector = AfterCursorReplayCollector()
            isBackfillingHistory = true
            var sourceWasInvalidated = false
            var shouldStartResolverAfterCleanup = false
            defer {
                // Cleanup order: replay flags/collector first, live parser
                // snapshot only for a still-valid source, and ONLY THEN the
                // resolver — a synchronous replacement bootstrap must never
                // land in the discarded collector.
                isCollectingBackfillPage = false
                collectedBackfillPage = []
                afterCursorReplayCollector = nil
                isBackfillingHistory = false
                if sourceWasInvalidated == false {
                    restoreLiveParserState(liveSnapshot)
                }
                if shouldStartResolverAfterCleanup {
                    startResolver()
                }
            }

            isCollectingBackfillPage = true
            collectedBackfillPage = []
            let readResult: JSONLBackfillResult
            do {
                readResult = try tailer.backfill(beforeOffset: anchorPosition.lineOffset,
                                                 limit: limit,
                                                 includeAnchorLine: anchorPosition.ordinal > 0)
            } catch JSONLFileTailerError.sourceInvalidated {
                sourceWasInvalidated = true
                shouldStartResolverAfterCleanup = true
                resetTranscriptSource(startResolverNow: false)
                currentEpoch = hub.currentHistoryEpoch(sessionID: record.sessionID)
                return out(.sourceChanged)
            } catch {
                // A transient read error must not revoke a valid source.
                return out(.unavailable)
            }
            isCollectingBackfillPage = false
            let rawPage = collectedBackfillPage
            collectedBackfillPage = []
            afterCursorStepAfterRawReadForTesting?()
            guard let frontier = readResult.rawFrontier else {
                return out(.unavailable)
            }
            guard frontier.containsInvalidRecord == false else {
                return out(.unavailable)
            }
            for entry in rawPage {
                consume(line: entry.line, lineOffset: entry.offset)
            }
            do {
                try tailer.validateCurrentSource()
            } catch JSONLFileTailerError.sourceInvalidated {
                sourceWasInvalidated = true
                shouldStartResolverAfterCleanup = true
                resetTranscriptSource(startResolverNow: false)
                currentEpoch = hub.currentHistoryEpoch(sessionID: record.sessionID)
                return out(.sourceChanged)
            } catch {
                return out(.unavailable)
            }
            // A record that poisoned semantic trust DURING the replay
            // discards the whole step — no partial page may be served.
            guard sourceSemanticTrust else {
                return out(.unavailable)
            }
            // Final Hub epoch fence: any movement discards the whole page.
            let epochAfterRead = hub.currentHistoryEpoch(sessionID: record.sessionID)
            guard epochAfterRead == currentEpoch else {
                currentEpoch = epochAfterRead
                return out(.sourceChanged)
            }

            let pageFloorOffset = frontier.minimumRawOffset ?? anchorPosition.lineOffset
            let pageFloor = TranscriptEventPosition(lineOffset: pageFloorOffset, ordinal: 0)
            let collector = afterCursorReplayCollector ?? AfterCursorReplayCollector()
            var seenEventIDs = Set<String>()
            let events = collector.products
                .filter { event in
                    guard let position = collector.positionsByEventID[event.eventID] else {
                        return false
                    }
                    return position >= pageFloor && position < anchorPosition
                }
                .filter { $0.seq > afterSeq }
                .filter { seenEventIDs.insert($0.eventID).inserted }
                .sorted { $0.seq < $1.seq }

            if frontier.reachedSourceStart {
                return out(.complete, events)
            }
            if let cursorPosition = exactTranscriptPositionByPublicSequence[afterSeq],
               cursorPosition >= pageFloor,
               cursorPosition < anchorPosition {
                return out(.complete, events)
            }
            let nextPosition = TranscriptEventPosition(lineOffset: pageFloorOffset, ordinal: 0)
            guard nextPosition < anchorPosition else {
                return out(.unavailable)
            }
            return out(.advanced(AgentHistoryAnchor(epoch: currentEpoch, position: nextPosition)),
                       events)
        }
    }

    func validateHistoryEpoch(_ epoch: AgentHistoryEpoch) -> Bool {
        queue.sync {
            guard didPublishStart, didPublishEnd == false, let tailer else {
                return false
            }
            validateHistoryEpochBeforeSourceValidationForTesting?()
            // Fence BEFORE the semantic-trust gate: a poisoned source that
            // was replaced on disk must revoke and move the epoch, never sit
            // terminal behind a stale trust=false verdict.
            do {
                try tailer.validateCurrentSource()
            } catch JSONLFileTailerError.sourceInvalidated {
                // Revoke SYNCHRONOUSLY before returning false: the flow's
                // finalization reads the Hub epoch right after validation
                // and must observe the movement (a retryable signal), never
                // an unchanged-epoch terminal false.
                resetTranscriptSource(startResolverNow: true)
                return false
            } catch {
                return false
            }
            guard sourceSemanticTrust else {
                return false
            }
            return epoch == hub.currentHistoryEpoch(sessionID: record.sessionID)
        }
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
            let effectiveLimit = min(limit, historicalReplayWindowCapacity)
            lastRequestedBackfillAnchorSeq = beforeSeq
            var pageAnchorOffset = beforeOffset
            var loadedAny = false
            while true {
                isCollectingBackfillPage = true
                collectedBackfillPage = []
                let loaded = (try? tailer.backfill(beforeOffset: pageAnchorOffset,
                                                   limit: effectiveLimit))?.didRead ?? false
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
        guard tailer == nil else {
            return
        }
        guard let transcriptURL = resolveTranscriptURL() else {
            return
        }

        let generation = activeSourceGeneration
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
                                     invalidUTF8Handler: { [weak self] _ in
                                         // Invalid raw bytes anywhere in the
                                         // source poison semantic trust.
                                         self?.sourceSemanticTrust = false
                                     },
                                     invalidationHandler: { [weak self] in
                                         self?.handleTailerInvalidation(generation: generation)
                                     })
        do {
            isBootstrappingSidebarState = true
            bootstrappedShellState = .prompt
            // The replacement source starts as a trusted candidate; its own
            // records may poison it during bootstrap.
            sourceSemanticTrust = true
            try tailer.start()
            isBootstrappingSidebarState = false
            self.tailer = tailer
            self.transcriptURL = transcriptURL
            // Retained-coverage eligibility floor: fixed at attach from the
            // initial bootstrap/live publication window. Request-owned
            // steps and legacy scans lower the tailer's SCAN floor but must
            // never lower this one.
            livePublishedRawFloor = tailer.contiguousRawCoverage?.minimumRawOffset
            resolverTimer?.cancel()
            resolverTimer = nil
            log("tailer.start bootstrap end shellState=\(currentShellState) startedTurn=\(lastStartedTurnID ?? "<nil>") completedTurn=\(lastCompletedTurnID ?? "<nil>")")
            publishSidebarSessionActivation(force: false)
        } catch {
            isBootstrappingSidebarState = false
            self.transcriptURL = nil
            log("tailer.start failed transcript=\(transcriptURL.path) error=\(error)")
        }
    }

    private func handleTailerInvalidation(generation: Int) {
        // Stale callbacks from an already-retired tailer must not reset (or
        // bump the Hub epoch) a second time.
        guard generation == activeSourceGeneration else {
            return
        }
        resetTranscriptSource(startResolverNow: true)
    }

    private func switchTranscriptIdentity() {
        resetTranscriptSource(startResolverNow: true)
    }

    // The SINGLE source-reset path shared by live vnode invalidation,
    // transcript identity switches, and after-cursor step source-fence
    // failures: stop/drop the old tailer, clear every raw/parser/request/
    // history state, advance the Hub epoch, and clear the transcript URL.
    // The generation guard makes one active source reset exactly once.
    private func resetTranscriptSource(startResolverNow: Bool) {
        activeSourceGeneration &+= 1
        tailer?.stop()
        tailer = nil
        resolverTimer?.cancel()
        resolverTimer = nil
        transcriptURL = nil
        historicalRawLines = []
        collectedBackfillPage = []
        isCollectingBackfillPage = false
        historicalReplayProducts = []
        lastRequestedBackfillAnchorSeq = nil
        afterCursorReplayCollector = nil
        exactTranscriptPositionByPublicSequence = [:]
        publicTranscriptSequenceByEventID = [:]
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
        transcriptSequenceBase = maxObservedSeq
        // No source is attached now: untrusted until a replacement attaches
        // and independently re-establishes trust.
        sourceSemanticTrust = false
        livePublishedRawFloor = nil
        hub.replaceHistoricalEvents(sessionID: record.sessionID, events: [], anchorSeq: nil)
        hub.beginNewSourceEpoch(sessionID: record.sessionID)
        if startResolverNow {
            startResolver()
        }
    }

    private func resolveTranscriptURL() -> URL? {
        if let transcriptPath = record.transcriptPath,
           !transcriptPath.isEmpty {
            let url = URL(fileURLWithPath: NSString(string: transcriptPath).expandingTildeInPath)
            if fileManager.fileExists(atPath: url.path) {
                return url
            }
        }

        if let processTreeResolved = resolveTranscriptURLFromProcessTree() {
            return processTreeResolved
        }

        let sessionsDirectory = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions", isDirectory: true)

        guard let enumerator = fileManager.enumerator(at: sessionsDirectory,
                                                      includingPropertiesForKeys: [.isRegularFileKey],
                                                      options: [.skipsHiddenFiles]) else {
            return nil
        }
        for case let url as URL in enumerator {
            guard url.lastPathComponent.hasPrefix("rollout-"),
                  url.pathExtension == "jsonl",
                  transcriptSessionIDs.contains(where: { url.lastPathComponent.contains($0) }) else {
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
            guard let path = rolloutPathForPIDTree(rootPID: rootPID),
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
            // A structurally malformed record poisons the whole source's
            // semantic trust — raw scan coverage over bytes we cannot
            // understand is never history coverage. (Well-formed records of
            // unknown TYPES fall through the switch below and stay legal.)
            sourceSemanticTrust = false
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
        case _ where Self.knownIgnoredTopLevelTypes.contains(type):
            // Explicitly catalogued legal record kinds that Tidey ignores:
            // eventless raw progress, never a trust judgment.
            break
        default:
            // An ARBITRARY unknown top-level type is future/unsupported
            // schema — silent acceptance would fake complete coverage.
            sourceSemanticTrust = false
        }
    }

    // Legal rollout record kinds Tidey deliberately ignores (from real
    // rollouts). `default` is NEVER an allowlist: anything outside the
    // producing set and these catalogs poisons semantic trust.
    private static let knownIgnoredTopLevelTypes: Set<String> = [
        "turn_context",
        "compacted",
        "world_state",
        "inter_agent_communication_metadata",
    ]
    // Union of the current real catalog (~/.codex/sessions inventory,
    // 2026-07-26) and legacy entries already supported by parser history.
    private static let knownIgnoredResponseItemTypes: Set<String> = [
        "reasoning",
        "web_search_call",
        "local_shell_call",
        "custom_tool_call",
        "custom_tool_call_output",
        "ghost_commit",
        "agent_message",
        "image_generation_call",
        "tool_search_call",
        "tool_search_output",
    ]
    private static let knownIgnoredEventMessageTypes: Set<String> = [
        "token_count",
        "agent_reasoning",
        "agent_reasoning_delta",
        "agent_message_delta",
        "agent_reasoning_section_break",
        "exec_command_begin",
        "exec_command_output_delta",
        "patch_apply_begin",
        "mcp_tool_call_begin",
        "mcp_tool_call_end",
        "web_search_begin",
        "web_search_end",
        "turn_diff",
        "background_event",
        "stream_error",
        "plan_update",
        "session_configured",
        "user_message",
        "collab_agent_spawn_end",
        "collab_close_end",
        "collab_waiting_end",
        "context_compacted",
        "image_generation_end",
        "sub_agent_activity",
        "thread_name_updated",
        "thread_settings_applied",
        "view_image_tool_call",
    ]

    private func consumeSessionMeta(payload: [String: Any], timestamp: String, lineOffset: Int) {
        guard let sessionID = payload["id"] as? String,
              transcriptSessionIDs.contains(sessionID) else {
            // session_meta whose id is missing, non-string, or belongs to a
            // different session/thread identity contradicts this source.
            sourceSemanticTrust = false
            return
        }
        if payload["cli_version"] != nil, !(payload["cli_version"] is String) {
            // An explicit non-string cli_version is malformed; only an
            // absent field keeps legacy compatibility.
            sourceSemanticTrust = false
            return
        }
        if let cliVersion = payload["cli_version"] as? String,
           !cliVersion.hasPrefix(codexTranscriptMajorVersion),
           !unsupportedVersions.contains(cliVersion) {
            unsupportedVersions.insert(cliVersion)
            // An unsupported transcript schema poisons semantic trust.
            sourceSemanticTrust = false
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
            // A response_item without a string payload type is malformed.
            sourceSemanticTrust = false
            return
        }

        switch payloadType {
        case "message":
            consumeMessageItem(payload: payload, timestamp: timestamp, lineOffset: lineOffset)
        case "function_call":
            consumeFunctionCall(payload: payload, timestamp: timestamp, lineOffset: lineOffset)
        case "function_call_output":
            consumeFunctionCallOutput(payload: payload, timestamp: timestamp, lineOffset: lineOffset)
        case _ where Self.knownIgnoredResponseItemTypes.contains(payloadType):
            break
        default:
            sourceSemanticTrust = false
        }
    }

    private func consumeMessageItem(payload: [String: Any], timestamp: String, lineOffset: Int) {
        // Schema validation first, product policy second: a producing
        // record with missing/mistyped required fields is
        // un-understandable data, never a legal eventless record.
        // The official Message.role is a plain required String, NOT a wire
        // enum — the non-empty {assistant, user, developer} allowlist is
        // Tidey's semantic-trust policy backed by the full local corpus.
        guard let role = payload["role"] as? String, !role.isEmpty else {
            sourceSemanticTrust = false
            return
        }
        // phase is Option<MessagePhase> (models.rs @ rust-v0.145.0):
        // absent and JSON null are legal-absent (inventory v2 over all
        // 1,164 local files: 27,677 absent, 0 explicit null), and only the
        // two official enum values are legal Strings — an unknown String
        // is not a member of the enum.
        if let phaseValue = payload["phase"], !(phaseValue is NSNull) {
            guard let phaseString = phaseValue as? String,
                  phaseString == "commentary" || phaseString == "final_answer" else {
                sourceSemanticTrust = false
                return
            }
        }
        let phase = payload["phase"] as? String
        guard let contentValue = payload["content"] else {
            sourceSemanticTrust = false
            return
        }
        let text: String
        switch Self.parseContentValue(contentValue, context: .message) {
        case .malformed:
            sourceSemanticTrust = false
            return
        case .noText:
            text = ""
        case .text(let value):
            text = value
        }

        switch role {
        case "assistant":
            guard !text.isEmpty else {
                return
            }
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
            guard !text.isEmpty, shouldPublishUserMessage(text) else {
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

        case "developer":
            // Legal role with no history product (product policy).
            break

        default:
            // An unknown future role must fail closed, not skip silently.
            sourceSemanticTrust = false
        }
    }

    private func consumeFunctionCall(payload: [String: Any], timestamp: String, lineOffset: Int) {
        guard let callID = payload["call_id"] as? String, !callID.isEmpty else {
            sourceSemanticTrust = false
            return
        }
        guard let name = payload["name"] as? String, !name.isEmpty else {
            sourceSemanticTrust = false
            return
        }
        // An empty arguments String is legal; a missing or non-string
        // value is not.
        guard let arguments = payload["arguments"] as? String else {
            sourceSemanticTrust = false
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
                          name: name,
                          input: Self.compactString(arguments),
                          output: nil,
                          toolCallID: callID,
                          metadata: nil)
    }

    private func consumeFunctionCallOutput(payload: [String: Any], timestamp: String, lineOffset: Int) {
        guard let callID = payload["call_id"] as? String, !callID.isEmpty else {
            sourceSemanticTrust = false
            return
        }
        guard let outputValue = payload["output"] else {
            sourceSemanticTrust = false
            return
        }
        let parsed = Self.parseContentValue(outputValue, context: .functionOutput)
        if case .malformed = parsed {
            // Schema validation BEFORE the resolved-ID dedupe: a malformed
            // duplicate must never hide behind an already-resolved call.
            sourceSemanticTrust = false
            return
        }
        guard !resolvedToolCallIDs.contains(callID) else {
            return
        }
        guard case .text(let output) = parsed else {
            // Legal no-text output (empty / image-only): no product, no
            // poison, and the call stays unresolved for a later text output.
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

    private func consumeEventMessage(payload: [String: Any], timestamp: String, lineOffset: Int) {
        guard let payloadType = payload["type"] as? String else {
            // An event_msg without a string payload type is malformed.
            sourceSemanticTrust = false
            return
        }

        switch payloadType {
        case "agent_message":
            consumeAgentMessage(payload: payload, timestamp: timestamp, lineOffset: lineOffset)
        case "task_started":
            consumeTaskStarted(payload: payload)
        case "task_complete":
            consumeTaskComplete(payload: payload)
        case "turn_aborted":
            consumeTurnAborted(payload: payload)
        case "exec_command_end":
            consumeExecCommandEnd(payload: payload, timestamp: timestamp, lineOffset: lineOffset)
        case "patch_apply_end":
            consumePatchApplyEnd(payload: payload, timestamp: timestamp, lineOffset: lineOffset)
        case _ where Self.knownIgnoredEventMessageTypes.contains(payloadType):
            break
        default:
            sourceSemanticTrust = false
        }
    }

    private func consumeTaskStarted(payload: [String: Any]) {
        guard let turnID = payload["turn_id"] as? String,
              !turnID.isEmpty,
              turnID != lastStartedTurnID else {
            return
        }
        lastStartedTurnID = turnID

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

    private func consumeTaskComplete(payload: [String: Any]) {
        guard let turnID = payload["turn_id"] as? String,
              !turnID.isEmpty,
              turnID != lastCompletedTurnID else {
            return
        }
        lastCompletedTurnID = turnID
        let body = Self.compactString(payload["last_agent_message"] as? String)

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

    private func consumeTurnAborted(payload: [String: Any]) {
        guard let turnID = payload["turn_id"] as? String,
              !turnID.isEmpty,
              turnID != lastAbortedTurnID else {
            return
        }
        lastAbortedTurnID = turnID

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
        // Schema validation first: message and phase are required. An
        // empty message String is legal (170 observed real records) but a
        // missing/mistyped field or an unknown phase fails closed.
        guard let message = payload["message"] as? String else {
            sourceSemanticTrust = false
            return
        }
        guard let phase = payload["phase"] as? String,
              phase == "commentary" || phase == "final_answer" else {
            sourceSemanticTrust = false
            return
        }
        let text = Self.compactString(message)
        guard !text.isEmpty else {
            return
        }

        didSeeInteractiveEvent = true
        if phase == "final_answer" {
            publishAssistantText(kind: .assistantFinal,
                                 eventNamespace: "final",
                                 phase: "final_answer",
                                 timestamp: timestamp,
                                 text: text,
                                 lineOffset: lineOffset,
                                 ordinal: 0)
        } else {
            publishAssistantText(kind: .assistantMessage,
                                 eventNamespace: "commentary",
                                 phase: "commentary",
                                 timestamp: timestamp,
                                 text: text,
                                 lineOffset: lineOffset,
                                 ordinal: 0)
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
    }

    private func consumeExecCommandEnd(payload: [String: Any], timestamp: String, lineOffset: Int) {
        guard let callID = payload["call_id"] as? String, !callID.isEmpty else {
            sourceSemanticTrust = false
            return
        }
        // Metadata schema is producer contract too (inventory: exit_code
        // always a JSON Number, status always a String). Optional for
        // legacy, but an explicit wrong-typed value poisons — BEFORE
        // candidate selection, dedupe, or the empty-product policy.
        if let exitCode = payload["exit_code"] {
            guard exitCode is NSNumber, !Self.isJSONBoolean(exitCode) else {
                sourceSemanticTrust = false
                return
            }
        }
        if let status = payload["status"] {
            guard status is String else {
                sourceSemanticTrust = false
                return
            }
        }
        // Validate EVERY present output candidate before selection, dedupe,
        // or the empty-product policy: a non-string candidate must never be
        // hidden by another field or an already-resolved call.
        guard let candidate = validatedOutputCandidate(
            payload: payload,
            keys: ["aggregated_output", "formatted_output", "stdout", "stderr"]) else {
            return
        }
        guard !resolvedToolCallIDs.contains(callID) else {
            return
        }
        let output = Self.compactString(candidate)
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
        guard let callID = payload["call_id"] as? String, !callID.isEmpty else {
            sourceSemanticTrust = false
            return
        }
        // Metadata schema (inventory: success always a Boolean, status
        // always a String) — optional for legacy, poisons when mistyped,
        // BEFORE candidate selection, dedupe, or the empty-product policy.
        if let success = payload["success"] {
            guard Self.isJSONBoolean(success) else {
                sourceSemanticTrust = false
                return
            }
        }
        if let status = payload["status"] {
            guard status is String else {
                sourceSemanticTrust = false
                return
            }
        }
        guard let candidate = validatedOutputCandidate(payload: payload,
                                                       keys: ["stdout", "stderr"]) else {
            return
        }
        guard !resolvedToolCallIDs.contains(callID) else {
            return
        }
        let output = Self.compactString(candidate)
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

    // JSONSerialization bridges JSON true/false to CFBoolean (an NSNumber
    // subclass), so `is NSNumber` alone cannot tell a Bool from a Number —
    // the type ID check can.
    private static func isJSONBoolean(_ value: Any) -> Bool {
        CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID()
    }

    // Validates every PRESENT candidate key, then selects the first present
    // value in priority order ("" when none is present, so the caller's
    // empty-product policy applies). Returns nil ONLY after poisoning on a
    // non-string candidate.
    private func validatedOutputCandidate(payload: [String: Any], keys: [String]) -> String? {
        var selected: String?
        for key in keys {
            guard let value = payload[key] else { continue }
            guard let string = value as? String else {
                sourceSemanticTrust = false
                return nil
            }
            if selected == nil {
                selected = string
            }
        }
        return selected ?? ""
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
        // Minimal B17 exact-position recording (unrebased seq only — the
        // accepted/rebased mapping is B18's row): every file-backed product
        // remembers its raw position for typed plan/step classification.
        let position = TranscriptEventPosition(lineOffset: lineOffset, ordinal: ordinal)
        exactTranscriptPositionByPublicSequence[seq] = position
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
            // Request-local after-cursor collection wins over the legacy
            // shared replay state while a step collector exists.
            if afterCursorReplayCollector != nil {
                afterCursorReplayCollector?.products.append(event)
                afterCursorReplayCollector?.positionsByEventID[event.eventID] = position
                return
            }
            historicalReplayProducts.append(event)
            return
        }
        hub.publish(event)
    }

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
                                  metadata: [String: String]?) {
        maxObservedSeq = max(maxObservedSeq, seq)
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
            // Synthetics carry no raw position: they join the collector's
            // products (and are excluded from interval slicing) rather than
            // the legacy shared replay state while a step is active.
            if afterCursorReplayCollector != nil {
                afterCursorReplayCollector?.products.append(event)
                return
            }
            historicalReplayProducts.append(event)
            return
        }
        hub.publish(event)
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
        guard isBackfillingHistory == false else {
            return
        }
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

    private func fileBackedSequence(lineOffset: Int, ordinal: Int) -> Int {
        transcriptSequenceBase + transcriptEventSequence(lineOffset: lineOffset, ordinal: ordinal)
    }

    private static func transcriptIdentity(for record: AgentSessionRegistryRecord) -> [String] {
        [
            record.transcriptPath ?? "",
            record.threadID ?? "",
            record.resumeThreadID ?? "",
        ]
    }

    private static func canonicalTranscriptPath(_ path: String) -> String {
        URL(fileURLWithPath: NSString(string: path).expandingTildeInPath).standardizedFileURL.path
    }

    // A source switch is a LOGICAL identity change (thread/resume) or a new
    // path that resolves to a DIFFERENT file than the currently attached
    // source. Equivalent spellings of the same file, and a nil path being
    // enriched to the already-resolved file, are registry metadata updates
    // — never a reset.
    private func isTranscriptIdentityChange(from previousRecord: AgentSessionRegistryRecord,
                                            to record: AgentSessionRegistryRecord) -> Bool {
        if previousRecord.threadID != record.threadID
            || previousRecord.resumeThreadID != record.resumeThreadID {
            return true
        }
        guard let newPath = record.transcriptPath, !newPath.isEmpty else {
            // Path removed/absent: keep the current source.
            return false
        }
        let canonicalNew = Self.canonicalTranscriptPath(newPath)
        if let currentURL = transcriptURL {
            return canonicalNew != currentURL.standardizedFileURL.path
        }
        if let oldPath = previousRecord.transcriptPath, !oldPath.isEmpty {
            return canonicalNew != Self.canonicalTranscriptPath(oldPath)
        }
        // nil → path with no attached source yet: the resolver simply picks
        // it up; nothing to reset.
        return false
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

    // Tri-state content parse: "" must never stand in for BOTH legal empty
    // content and malformed content — the two have opposite trust meanings.
    enum CodexContentParse {
        case text(String)   // valid, non-empty compacted text
        case noText         // valid, but no text product (empty / media-only)
        case malformed      // schema violation
    }

    // The two content contexts have DIFFERENT official schemas (codex-rs
    // models.rs @ rust-v0.145.0, 25af12f7) — one shared allowlist would
    // either over-accept or over-reject:
    //   .message        — Array only; text blocks input_text/output_text;
    //                     no-text blocks input_image/input_audio. The
    //                     "\n\n" flatten is Tidey's display normalization,
    //                     not an official conversion.
    //   .functionOutput — String or Array; text block input_text only;
    //                     no-text blocks input_image/input_audio/
    //                     encrypted_content; the official human-readable
    //                     conversion keeps nonblank input_text joined "\n".
    // The ContentItem enums have no serde(other) and no
    // deny_unknown_fields: an unknown BLOCK type is schema-invalid, while
    // extra keys on a legal block are ignored. text / summary_text / a
    // message top-level String are in neither schema and have zero
    // evidence across all local rollout files (inventory v2, 2026-07-25)
    // — no legacy catalog, fail closed.
    enum CodexContentContext {
        case message
        case functionOutput
    }

    private static let legalImageDetails: Set<String> = ["auto", "low", "high", "original"]

    static func parseContentValue(_ value: Any, context: CodexContentContext) -> CodexContentParse {
        if let string = value as? String {
            guard context == .functionOutput else {
                return .malformed
            }
            let compacted = compactString(string)
            return compacted.isEmpty ? .noText : .text(compacted)
        }
        guard let blocks = value as? [Any] else {
            return .malformed
        }
        var parts: [String] = []
        for rawBlock in blocks {
            guard let block = rawBlock as? [String: Any],
                  let type = block["type"] as? String else {
                return .malformed
            }
            switch (context, type) {
            case (.message, "input_text"), (.message, "output_text"), (.functionOutput, "input_text"):
                guard let text = block["text"] as? String else {
                    return .malformed
                }
                parts.append(text)
            case (_, "input_image"):
                guard block["image_url"] is String else {
                    return .malformed
                }
                // detail is Option<ImageDetail>: absent and explicit JSON
                // null are both legal; only a present non-null value must
                // be one of the enum Strings.
                if let detail = block["detail"], !(detail is NSNull) {
                    guard let detailString = detail as? String,
                          Self.legalImageDetails.contains(detailString) else {
                        return .malformed
                    }
                }
            case (_, "input_audio"):
                guard block["audio_url"] is String else {
                    return .malformed
                }
            case (.functionOutput, "encrypted_content"):
                guard block["encrypted_content"] is String else {
                    return .malformed
                }
            default:
                return .malformed
            }
        }
        let joined: String
        switch context {
        case .functionOutput:
            joined = parts.filter { !compactString($0).isEmpty }.joined(separator: "\n")
        case .message:
            joined = parts.joined(separator: "\n\n")
        }
        let compacted = compactString(joined)
        return compacted.isEmpty ? .noText : .text(compacted)
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

    private func rolloutPathForPIDTree(rootPID: Int32) -> String? {
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

    private func rolloutPathForPID(_ pid: Int32) -> String? {
        guard pid > 0 else {
            return nil
        }
        guard let result = processRunner("/usr/sbin/lsof",
                                         ["-Fn", "-p", String(pid)],
                                         Self.rolloutLookupTimeout),
              result.terminationStatus == 0,
              let output = String(data: result.standardOutput,
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

    private func childPIDs(for pid: Int32) -> [Int32] {
        guard pid > 0 else {
            return []
        }
        guard let result = processRunner("/usr/bin/pgrep",
                                         ["-P", String(pid)],
                                         Self.processLookupTimeout),
              let output = String(data: result.standardOutput,
                                  encoding: .utf8) else {
            return []
        }
        return output
            .split(whereSeparator: \.isNewline)
            .compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
    }

    private static let liveProcessRunner: CodexTranscriptProcessRunner = { executablePath, arguments, timeout in
        BoundedProcessRunner.run(executablePath: executablePath,
                                 arguments: arguments,
                                 timeout: timeout)
    }
}
