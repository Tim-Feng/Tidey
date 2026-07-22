import Foundation

// Suppression identity is (sessionID, eventID, seq) — NOT eventID alone. Some
// file-backed eventIDs are derived from raw call_ids rather than seq, and a
// same-path transcript delete+recreate (a genuine new source epoch) can
// reuse a call_id verbatim. Since a source-epoch reset always rebases the
// new source's seqs strictly ABOVE the old source's high-water (see
// AgentEventHub.nextSyntheticSeq / CodexTranscriptSession.beginNewSourceEpoch),
// a reused eventID from the NEW source always carries a HIGHER seq than the
// one already captured in a replay set — so keying suppression on the pair
// naturally distinguishes the two source incarnations without needing every
// eventID in the codebase to carry an explicit epoch token, while a truly
// identical (eventID, seq) — the same stored event arriving via both the
// replay snapshot and a racing live delivery — still dedupes correctly.
struct BridgeAgentEventSuppressionKey: Hashable {
    let sessionID: String
    let eventID: String
    let seq: Int

    init(sessionID: String, eventID: String, seq: Int) {
        self.sessionID = sessionID
        self.eventID = eventID
        self.seq = seq
    }

    init(event: AgentEvent) {
        self.init(sessionID: event.sessionID, eventID: event.eventID, seq: event.seq)
    }
}

final class BridgeAgentEventReplayGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var buffered = [AgentEventEnvelope]()
    // Deliveries already injected into the replay stream. The set must also
    // suppress the SAME (session, eventID, seq) arriving live AFTER open (the
    // ordered drain may still be flushing it); each suppressed key fires at
    // most once and the set is bounded for the subscription's replay window.
    private var suppressedKeys = Set<BridgeAgentEventSuppressionKey>()

    func receive(_ envelope: AgentEventEnvelope) -> AgentEventEnvelope? {
        lock.lock()
        defer { lock.unlock() }
        if isOpen {
            if suppressedKeys.remove(BridgeAgentEventSuppressionKey(event: envelope.event)) != nil {
                return nil
            }
            return envelope
        }
        buffered.append(envelope)
        return nil
    }

    func open(suppressing replayedKeys: Set<BridgeAgentEventSuppressionKey> = []) -> [AgentEventEnvelope] {
        lock.lock()
        defer { lock.unlock() }
        guard !isOpen else {
            return []
        }
        isOpen = true
        // Merge the replay/live race by (session, eventID, seq): a delivery
        // that was already injected into the replay stream (with its newest
        // snapshot metadata) must not arrive a second time — neither from
        // the live buffer nor as a late live envelope after open. Keys that
        // were already consumed from the buffer need no post-open suppression.
        var remaining = replayedKeys
        let envelopes = buffered.filter { envelope in
            if remaining.remove(BridgeAgentEventSuppressionKey(event: envelope.event)) != nil {
                return false
            }
            return true
        }
        suppressedKeys = remaining
        buffered.removeAll()
        return envelopes
    }
}
