import Foundation

final class TerminalStreamDeliveryGate: @unchecked Sendable {
    private enum State {
        case pending
        case accepted
        case invalidated
    }

    private let lock = NSLock()
    private var state: State = .pending
    private var onInvalidated: (@Sendable () -> Void)?

    var allowsDelivery: Bool {
        lock.lock()
        defer { lock.unlock() }
        return state == .accepted
    }

    @discardableResult
    func accept(onInvalidated: @escaping @Sendable () -> Void) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard state == .pending else {
            return false
        }
        self.onInvalidated = onInvalidated
        state = .accepted
        return true
    }

    func invalidate() {
        let callback: (@Sendable () -> Void)?
        lock.lock()
        guard state != .invalidated else {
            lock.unlock()
            return
        }
        state = .invalidated
        callback = onInvalidated
        onInvalidated = nil
        lock.unlock()
        callback?()
    }
}

enum TerminalStreamSubscriptionOwner: Hashable, Sendable {
    case legacy
    case identified(String)
}

final class OrdinaryTmuxTerminalStreamLease: @unchecked Sendable {
    let token: UInt64
    let owner: TerminalStreamSubscriptionOwner
    let subscription: OrdinaryTmuxTerminalStreamSubscribing
    let deliveryGate: TerminalStreamDeliveryGate

    var route: OrdinaryTmuxPanelRoute {
        subscription.route
    }

    init(token: UInt64,
         owner: TerminalStreamSubscriptionOwner = .legacy,
         subscription: OrdinaryTmuxTerminalStreamSubscribing,
         deliveryGate: TerminalStreamDeliveryGate) {
        self.token = token
        self.owner = owner
        self.subscription = subscription
        self.deliveryGate = deliveryGate
    }

    func activate() {
        subscription.activate()
    }

    @discardableResult
    func stop() -> Bool {
        subscription.stop()
    }

    func stopForReplacement() throws {
        try subscription.stopForReplacement()
    }
}

struct OrdinaryTmuxTerminalStreamLaneCandidate: Sendable {
    let response: BridgeResponse
    let lease: OrdinaryTmuxTerminalStreamLease
}

struct OrdinaryTmuxTerminalStreamLaneOwnedFailure: Error, LocalizedError {
    let underlying: Error
    let lease: OrdinaryTmuxTerminalStreamLease

    var errorDescription: String? {
        underlying.localizedDescription
    }
}

final class OrdinaryTmuxTerminalStreamLane: @unchecked Sendable {
    typealias Completion = @Sendable (Result<OrdinaryTmuxTerminalStreamLaneCandidate, Error>?) -> Void

    private let queue: DispatchQueue
    private var highestSeenSequence: UInt64 = 0
    private var activeLease: OrdinaryTmuxTerminalStreamLease?

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    func submitSubscribe(sequence: UInt64,
                         claimForPhysicalMutation: @escaping @Sendable () -> Bool = { true },
                         build: @escaping @Sendable () throws -> OrdinaryTmuxTerminalStreamLaneCandidate,
                         completion: @escaping Completion) {
        queue.async {
            guard sequence > self.highestSeenSequence else {
                completion(nil)
                return
            }
            self.highestSeenSequence = sequence

            if let activeLease = self.activeLease {
                activeLease.deliveryGate.invalidate()
                do {
                    try activeLease.stopForReplacement()
                    self.activeLease = nil
                } catch {
                    completion(.failure(error))
                    return
                }
            }

            do {
                let candidate = try build()
                self.activeLease = candidate.lease
                completion(.success(candidate))
            } catch let ownedFailure as OrdinaryTmuxTerminalStreamLaneOwnedFailure {
                ownedFailure.lease.deliveryGate.invalidate()
                do {
                    try ownedFailure.lease.stopForReplacement()
                } catch {
                    self.activeLease = ownedFailure.lease
                }
                completion(.failure(ownedFailure.underlying))
            } catch {
                completion(.failure(error))
            }
        }
    }

    func releaseIfCurrent(token: UInt64) {
        queue.async {
            guard let activeLease = self.activeLease,
                  activeLease.token == token else {
                return
            }
            activeLease.deliveryGate.invalidate()
            if activeLease.stop() {
                self.activeLease = nil
            }
        }
    }
}

final class OrdinaryTmuxTerminalStreamLaneRegistry: @unchecked Sendable {
    typealias QueueFactory = @Sendable (String) -> DispatchQueue

    private let lock = NSLock()
    private var lanes = [String: OrdinaryTmuxTerminalStreamLane]()
    private let makeQueue: QueueFactory

    init(makeQueue: @escaping QueueFactory = { panelID in
        DispatchQueue(label: "com.tidey.remote-bridge.terminal-stream.\(panelID)")
    }) {
        self.makeQueue = makeQueue
    }

    func lane(for panelID: String) -> OrdinaryTmuxTerminalStreamLane {
        lock.lock()
        defer { lock.unlock() }
        if let lane = lanes[panelID] {
            return lane
        }
        let lane = OrdinaryTmuxTerminalStreamLane(queue: makeQueue(panelID))
        lanes[panelID] = lane
        return lane
    }
}
