import Foundation

// Typed after-cursor history contract (agreed G1b design).
//
// Guarantee split: transcript-backed DURABLE history is the only no-gap,
// no-epoch-mix guarantee; Hub-retained transients are bounded replay whose
// request-window portion a request-local live lease preserves. The epoch is
// a HUB-ISSUED token — sessions carry and compare it but never mint a
// parallel generation authority.
struct AgentHistoryEpoch: Hashable, Sendable {
    let sessionID: String
    let generation: UInt64
}

// A raw transcript position bound to the epoch it was observed under. A
// position is meaningless across epochs; consumers must drop anchors whose
// epoch no longer matches.
struct AgentHistoryAnchor: Equatable, Sendable {
    let epoch: AgentHistoryEpoch
    let position: TranscriptEventPosition
}

enum AgentAfterCursorPlanMode: Equatable {
    // The cursor lies inside the contiguously validated raw interval.
    // `replayFrom` is REQUIRED: when Hub evidence shows a live eviction
    // above the cursor, the flow re-scans from this fixed frontier — a
    // bare "covered" flag could not express that fallback.
    case rawCovered(replayFrom: AgentHistoryAnchor)
    // Durable coverage must be established by a request-owned raw walk
    // starting at this anchor.
    case scan(from: AgentHistoryAnchor)
    // No transcript backing — the bounded Hub window is all there is.
    case hubOnly
    // Durable coverage cannot be proven right now; the flow fails closed.
    case unavailable
}

struct AgentAfterCursorPlan: Equatable {
    let epoch: AgentHistoryEpoch
    let mode: AgentAfterCursorPlanMode
}

// One request-owned raw walk step. `events` belong to the request that
// issued the step — they are return values, never read back from a shared
// mutable cache.
struct AgentAfterCursorStep {
    enum Outcome: Equatable {
        case advanced(AgentHistoryAnchor)
        case complete
        case sourceChanged
        case unavailable
    }

    let epoch: AgentHistoryEpoch
    let outcome: Outcome
    let events: [AgentEvent]
}

// Session seam: the session is the sole authority for public sequence ↔
// raw transcript position mapping. Sessions without typed after-cursor
// support inherit legacy-neutral defaults (hubOnly plan, unavailable step,
// epoch always valid) that preserve current fetch behavior exactly.
extension AgentTranscriptSession {
    func afterCursorPlan(afterSeq: Int,
                         expectedEpoch: AgentHistoryEpoch) -> AgentAfterCursorPlan {
        AgentAfterCursorPlan(epoch: expectedEpoch, mode: .hubOnly)
    }

    func afterCursorStep(from anchor: AgentHistoryAnchor,
                         afterSeq: Int,
                         limit: Int) -> AgentAfterCursorStep {
        AgentAfterCursorStep(epoch: anchor.epoch, outcome: .unavailable, events: [])
    }

    func validateHistoryEpoch(_ epoch: AgentHistoryEpoch) -> Bool {
        true
    }
}
