import Foundation

final class BridgeAgentEventReplayGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var buffered = [AgentEventEnvelope]()
    // Deliveries already injected into the replay stream. The set must also
    // suppress the SAME eventID arriving live AFTER open (the ordered drain
    // may still be flushing it); each suppressed ID fires at most once and
    // the set is bounded for the subscription's replay window.
    private var suppressedEventIDs = Set<String>()

    func receive(_ envelope: AgentEventEnvelope) -> AgentEventEnvelope? {
        lock.lock()
        defer { lock.unlock() }
        if isOpen {
            if suppressedEventIDs.remove(envelope.event.eventID) != nil {
                return nil
            }
            return envelope
        }
        buffered.append(envelope)
        return nil
    }

    func open(suppressing replayedEventIDs: Set<String> = []) -> [AgentEventEnvelope] {
        lock.lock()
        defer { lock.unlock() }
        guard !isOpen else {
            return []
        }
        isOpen = true
        // Merge the replay/live race by event identity: a delivery that was
        // already injected into the replay stream (with its newest snapshot
        // metadata) must not arrive a second time — neither from the live
        // buffer nor as a late live envelope after open. IDs that were
        // already consumed from the buffer need no post-open suppression.
        var remaining = replayedEventIDs
        let envelopes = buffered.filter { envelope in
            if remaining.remove(envelope.event.eventID) != nil {
                return false
            }
            return true
        }
        suppressedEventIDs = remaining
        buffered.removeAll()
        return envelopes
    }
}
