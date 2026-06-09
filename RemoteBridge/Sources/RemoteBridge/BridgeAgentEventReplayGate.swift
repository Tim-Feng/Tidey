import Foundation

final class BridgeAgentEventReplayGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var buffered = [AgentEventEnvelope]()

    func receive(_ envelope: AgentEventEnvelope) -> AgentEventEnvelope? {
        lock.lock()
        defer { lock.unlock() }
        if isOpen {
            return envelope
        }
        buffered.append(envelope)
        return nil
    }

    func open() -> [AgentEventEnvelope] {
        lock.lock()
        defer { lock.unlock() }
        guard !isOpen else {
            return []
        }
        isOpen = true
        let envelopes = buffered
        buffered.removeAll()
        return envelopes
    }
}
