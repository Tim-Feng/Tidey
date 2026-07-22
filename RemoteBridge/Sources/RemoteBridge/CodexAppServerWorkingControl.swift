import Foundation

/// Internal Codex app-server activity that has no transcript card of its own
/// (wait/subagent collaboration items etc). This is a strict allowlist of
/// official-schema item types — every other item type (including all
/// existing normal tool/card items such as screenshot, imageView,
/// commandExecution, fileChange, MCP, dynamic tool calls, web search, and
/// image generation) is intentionally excluded and must keep flowing through
/// the existing `makeEvent`/`onAgentEvent` path unchanged.
enum CodexAppServerInternalActivityKind: String, Sendable, Equatable {
    case collabAgentToolCall
    case subAgentActivity
    case sleep

    init?(itemType: String) {
        switch itemType {
        case "collabAgentToolCall":
            self = .collabAgentToolCall
        case "subAgentActivity":
            self = .subAgentActivity
        case "sleep":
            self = .sleep
        default:
            return nil
        }
    }

    /// `collabAgentToolCall`/`sleep` (agent-side collab/wait spans and the
    /// sleep tool) are opened via `item/started`, per official app-server
    /// v0.144.x wire mapping (`EventMsg::CollabAgent*Begin`/`CollabWaitingBegin`
    /// and the sleep handler both emit `ItemStarted`). `subAgentActivity`
    /// does NOT — the server maps `EventMsg::SubAgentActivity` directly to
    /// `ItemCompleted` (see `event_mapping.rs`), so it never has a started
    /// edge and must fail closed if one is ever claimed.
    var isValidOnItemStarted: Bool {
        switch self {
        case .collabAgentToolCall, .sleep:
            return true
        case .subAgentActivity:
            return false
        }
    }

    /// `subAgentActivity` is observed as a control-only continuation pulse
    /// on `item/completed` — never a turn terminal, never clears Working.
    /// `collabAgentToolCall`/`sleep` have no `item/completed` control edge:
    /// their own completion is silent for control purposes (the open pulse
    /// from `item/started` already established Working; nothing new to
    /// signal, and — critically — `item/completed` must never become an
    /// accidental terminal for them).
    var isValidOnItemCompleted: Bool {
        switch self {
        case .subAgentActivity:
            return true
        case .collabAgentToolCall, .sleep:
            return false
        }
    }
}

/// Reason a Codex app-server owner (a live runtime attached to a session
/// record) stopped observing a thread/turn. This is distinct from a
/// semantic turn terminal — an owner can disconnect while another owner
/// (a fresh runtime for the same session/root) keeps the turn live.
enum CodexAppServerOwnerDisconnectReason: String, Sendable, Equatable {
    case transportClosed = "transport_closed"
    case processExited = "process_exited"
    case sessionRetired = "session_retired"
}

/// Identity of one app-server turn for Working-control purposes, entirely
/// independent of the transcript-vendor `currentTurnID` tracked by
/// `AgentEventHub`'s existing prompt/Working fold (which is cleared by a
/// transcript `.sessionStarted`/`.sessionEnded` — this key is not).
/// `epoch` is the STABLE identity of one underlying app-server process
/// instance across Bridge reconnects (see
/// `CodexAppServerRegistryRuntimeSyncer.appServerEpoch(record:effectiveRoot:)`,
/// the single canonical epoch helper — PID + socket + registry `createdAt`
/// + the authoritative effective root; NOT workspace/panel) — it rotates
/// only on a true process restart or a genuine root change, never on a
/// mere runtime attach/reattach for the same process/root, and never on a
/// pure workspace/panel binding move.
struct AppServerLogicalTurnKey: Hashable, Sendable {
    let sessionID: String
    let epoch: String
    let rootThreadID: String
    let turnID: String
}

/// Identity of one attached runtime's observation of a logical turn.
/// `runtimeGeneration` is the Syncer's per-attach generation identity (a
/// fresh UUID minted on every `attach(record:)` call); `ownerToken` further
/// disambiguates within a generation if ever needed (defaults to the
/// generation's own string form at call sites with one owner per
/// generation). Deliberately embeds the FULL logical turn identity — an
/// owner key alone is enough to know exactly which logical turn a late
/// disconnect belongs to, without asking the Hub "what's the current turn
/// right now" (see `AgentEventHub.retireAppServerOwner`).
struct AppServerOwnerKey: Hashable, Sendable {
    let logical: AppServerLogicalTurnKey
    let runtimeGeneration: String
    let ownerToken: String
}

/// The app-server control incarnation a session's control state currently
/// belongs to. Reattaching with the SAME incarnation (a runtime generation
/// replacement for the same underlying process/root) must preserve all
/// existing control state; only a genuinely different epoch or root is a
/// true incarnation rotation.
struct AppServerControlIncarnation: Hashable, Sendable {
    let epoch: String
    let rootThreadID: String
}

/// What a caller (the Syncer) must do to ITS OWN attach-scoped owner→logical
/// mapping in response to one admission — deliberately typed rather than
/// left for the caller to infer from a bare `accepted` bool, since
/// "accepted" does NOT uniformly mean "set the mapping active":
///
/// - `.setOwner(key)`: accepted start/activity/resume (idempotent add-owner,
///   fresh open, or exact-suspended reopen) — bind this exact owner to this
///   exact logical turn.
/// - `.clearIfMatching(logical)`: accepted semantic-terminal tombstone
///   admission — clear the caller's mapping ONLY IF it currently points at
///   this exact logical key; a no-op otherwise (e.g. a late terminal for an
///   old turn A while the attach has already moved on to B must leave B's
///   mapping untouched). Terminal admission NEVER sets a mapping active.
/// - `.none`: rejection — the caller must not touch its mapping at all.
enum AppServerOwnerContextEffect: Equatable, Sendable {
    case setOwner(AppServerOwnerKey)
    case clearIfMatching(AppServerLogicalTurnKey)
    case none
}

/// Result of `AgentEventHub.admitAppServerWorkingControl`. `accepted`,
/// `events`, and `ownerContextEffect` are each independently meaningful — a
/// caller (the Syncer) must branch on `ownerContextEffect` (not
/// `events.isEmpty`, and not `accepted` alone) to decide what to do to its
/// own attach-scoped owner mapping:
///
/// - `accepted == true` covers every case where the typed state machine
///   validly processed this observation, REGARDLESS of whether it produced
///   a wire event: idempotent same-trajectory add-owner, a prompt-hidden
///   open/continue, an exact-duplicate edge retry, and a semantic-terminal
///   tombstone admission (even terminal-before-start, which never matches
///   a current/suspended trajectory and so never emits a wire event
///   either).
/// - `accepted == false` covers every rejection: identity mismatch,
///   incarnation mismatch, semantic tombstone, wrong/different active
///   trajectory, or a retired owner. Zero state, sequence, or owner-context
///   mutation happened — `ownerContextEffect` is always `.none` here.
struct AppServerWorkingControlAdmission: Sendable {
    let accepted: Bool
    let events: [AgentEvent]
    let ownerContextEffect: AppServerOwnerContextEffect
}

/// A typed, control-only observation of Codex app-server turn/internal-item
/// lifecycle, independent from `AgentEvent`. Producing one of these never
/// implies an `AgentEvent` was or will be constructed, and never reserves an
/// event sequence — sequence numbers are minted only after Hub admission
/// succeeds (see `AgentEventHub`'s typed pre-admission API). Blank
/// thread/turn/item IDs must fail closed at the observation seam itself: no
/// case below can be constructed with an empty `threadID`, `turnID`, or
/// `itemID`.
enum CodexAppServerWorkingControlEvent: Sendable, Equatable {
    case turnStarted(threadID: String, turnID: String, time: String)
    /// An `item/started` open/continuation pulse. Only ever constructed for
    /// `collabAgentToolCall`/`sleep` — see
    /// `CodexAppServerInternalActivityKind.isValidOnItemStarted`.
    case internalActivityStarted(threadID: String,
                                  turnID: String,
                                  itemID: String,
                                  kind: CodexAppServerInternalActivityKind,
                                  time: String)
    /// An `item/completed` continuation pulse. Only ever constructed for
    /// `subAgentActivity` — see
    /// `CodexAppServerInternalActivityKind.isValidOnItemCompleted`. This is
    /// NEVER a turn terminal and must never clear Working.
    case internalActivityObserved(threadID: String,
                                   turnID: String,
                                   itemID: String,
                                   kind: CodexAppServerInternalActivityKind,
                                   time: String)
    /// `rawStatus` is the verbatim `turn/completed` status string (e.g.
    /// "completed", "failed", "interrupted", "aborted", or any future
    /// supported equivalent). `item/completed` never produces this case —
    /// only an actual `turn/completed` notification is a turn terminal.
    case turnTerminal(threadID: String, turnID: String, rawStatus: String, time: String)
    case resumeSnapshot(threadID: String, turnID: String, time: String)
    case ownerDisconnected(reason: CodexAppServerOwnerDisconnectReason, time: String)
}

enum CodexAppServerWorkingControlFactory {
    /// Builds a `turnStarted` control observation from an exact-root
    /// `turn/started` notification, or `nil` if any required ID is blank.
    static func turnStarted(threadID: String, turnID: String, time: @autoclosure () -> String) -> CodexAppServerWorkingControlEvent? {
        guard isNonBlank(threadID), isNonBlank(turnID) else {
            return nil
        }
        return .turnStarted(threadID: threadID, turnID: turnID, time: time())
    }

    /// Builds an `internalActivityStarted` control observation from an
    /// `item/started` notification, or `nil` if the item type is not
    /// allowlisted on this exact lifecycle edge, any required ID is blank,
    /// or the type is `subAgentActivity` (which never has a started edge on
    /// the real wire — fails closed rather than trusting a claimed one).
    static func internalActivityStarted(threadID: String,
                                        turnID: String,
                                        itemID: String,
                                        itemType: String,
                                        time: @autoclosure () -> String) -> CodexAppServerWorkingControlEvent? {
        guard isNonBlank(threadID), isNonBlank(turnID), isNonBlank(itemID),
              let kind = CodexAppServerInternalActivityKind(itemType: itemType),
              kind.isValidOnItemStarted else {
            return nil
        }
        return .internalActivityStarted(threadID: threadID, turnID: turnID, itemID: itemID, kind: kind, time: time())
    }

    /// Builds an `internalActivityObserved` control observation from an
    /// `item/completed` notification, or `nil` unless the item type is
    /// exactly `subAgentActivity` (the only internal type observed on this
    /// edge) or any required ID is blank. `collabAgentToolCall`/`sleep`
    /// completions never produce a control observation here.
    static func internalActivityObserved(threadID: String,
                                         turnID: String,
                                         itemID: String,
                                         itemType: String,
                                         time: @autoclosure () -> String) -> CodexAppServerWorkingControlEvent? {
        guard isNonBlank(threadID), isNonBlank(turnID), isNonBlank(itemID),
              let kind = CodexAppServerInternalActivityKind(itemType: itemType),
              kind.isValidOnItemCompleted else {
            return nil
        }
        return .internalActivityObserved(threadID: threadID, turnID: turnID, itemID: itemID, kind: kind, time: time())
    }

    /// Builds a `turnTerminal` control observation from a `turn/completed`
    /// notification. Every `turn/completed` with a nonblank status is a
    /// terminal for control purposes regardless of the specific status
    /// string carried (forward-compatible, method-authoritative) — only
    /// `item/completed` (a different method) is excluded from ever reaching
    /// this factory. The factory itself (not just its caller) enforces
    /// `rawStatus` is trim-nonblank — this type must never be constructible
    /// in a malformed state regardless of what a future caller passes.
    static func turnTerminal(threadID: String, turnID: String, rawStatus: String, time: @autoclosure () -> String) -> CodexAppServerWorkingControlEvent? {
        guard isNonBlank(threadID), isNonBlank(turnID), isNonBlank(rawStatus) else {
            return nil
        }
        return .turnTerminal(threadID: threadID, turnID: turnID, rawStatus: rawStatus, time: time())
    }

    static func resumeSnapshot(threadID: String, turnID: String, time: @autoclosure () -> String) -> CodexAppServerWorkingControlEvent? {
        guard isNonBlank(threadID), isNonBlank(turnID) else {
            return nil
        }
        return .resumeSnapshot(threadID: threadID, turnID: turnID, time: time())
    }

    static func ownerDisconnected(reason: CodexAppServerOwnerDisconnectReason, time: String) -> CodexAppServerWorkingControlEvent {
        .ownerDisconnected(reason: reason, time: time)
    }

    private static func isNonBlank(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
