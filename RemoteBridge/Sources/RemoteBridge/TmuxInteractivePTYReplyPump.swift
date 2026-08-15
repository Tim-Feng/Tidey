import Foundation

enum TmuxInteractivePTYReplyEnqueueResult: Equatable, Sendable {
    case accepted
    case notActive
    case bindingMismatch
    case invalidReply
    case pendingCapacityExceeded(limit: Int)
    case startupCapacityExceeded(limit: Int)
}

enum TmuxInteractivePTYReplyPumpError: Error, Equatable {
    case invalidWriteCount(Int, maximum: Int)
}

final class TmuxInteractivePTYReplyPump: @unchecked Sendable {
    typealias Write = @Sendable (
        TmuxInteractiveTerminalReply
    ) throws -> TmuxInteractivePTYWriteResult
    typealias Execute = @Sendable (@escaping @Sendable () -> Void) -> Void
    typealias ScheduleRetry = @Sendable (@escaping @Sendable () -> Void) -> Void
    typealias OnStopped = @Sendable (Error?) -> Void

    private struct PendingReply {
        let reply: TmuxInteractiveTerminalReply
        var offset: Int
    }

    private enum State {
        case inactive
        case idle
        case draining
        case retryScheduled
        case stopped
    }

    let binding: TmuxInteractiveSubscriptionBinding
    let maximumPendingBytes: Int
    let maximumStartupBytes: Int

    private let lock = NSLock()
    private let write: Write
    private let execute: Execute
    private let scheduleRetry: ScheduleRetry
    private let onStopped: OnStopped
    private var state = State.inactive
    private var isLive = false
    private var pendingReplies = [PendingReply]()
    private var storedPendingByteCount = 0
    private var storedStartupAcceptedByteCount = 0

    init(
        binding: TmuxInteractiveSubscriptionBinding,
        maximumPendingBytes: Int,
        maximumStartupBytes: Int,
        write: @escaping Write,
        execute: @escaping Execute,
        scheduleRetry: @escaping ScheduleRetry,
        onStopped: @escaping OnStopped
    ) {
        self.binding = binding
        self.maximumPendingBytes = max(1, maximumPendingBytes)
        self.maximumStartupBytes = max(1, maximumStartupBytes)
        self.write = write
        self.execute = execute
        self.scheduleRetry = scheduleRetry
        self.onStopped = onStopped
    }

    var pendingByteCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedPendingByteCount
    }

    var startupAcceptedByteCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedStartupAcceptedByteCount
    }

    func activateSettling() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard state == .inactive else {
            return false
        }
        state = .idle
        return true
    }

    func markLive() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        switch state {
        case .idle, .draining, .retryScheduled:
            isLive = true
            return true
        case .inactive, .stopped:
            return false
        }
    }

    func enqueue(
        _ reply: TmuxInteractiveTerminalReply
    ) -> TmuxInteractivePTYReplyEnqueueResult {
        let shouldStartDrain: Bool
        lock.lock()
        switch state {
        case .inactive, .stopped:
            lock.unlock()
            return .notActive
        case .idle, .draining, .retryScheduled:
            break
        }
        guard reply.binding == binding else {
            lock.unlock()
            return .bindingMismatch
        }
        guard reply.bytes.isEmpty == false else {
            lock.unlock()
            return .invalidReply
        }
        if isLive == false,
           reply.bytes.count > maximumStartupBytes -
                storedStartupAcceptedByteCount {
            lock.unlock()
            return .startupCapacityExceeded(limit: maximumStartupBytes)
        }
        guard reply.bytes.count <= maximumPendingBytes -
                storedPendingByteCount else {
            lock.unlock()
            return .pendingCapacityExceeded(limit: maximumPendingBytes)
        }

        pendingReplies.append(PendingReply(reply: reply, offset: 0))
        storedPendingByteCount += reply.bytes.count
        if isLive == false {
            storedStartupAcceptedByteCount += reply.bytes.count
        }
        if state == .idle {
            state = .draining
            shouldStartDrain = true
        } else {
            shouldStartDrain = false
        }
        lock.unlock()

        if shouldStartDrain {
            requestDrain()
        }
        return .accepted
    }

    func stop() {
        let shouldNotify: Bool
        lock.lock()
        if state == .stopped {
            shouldNotify = false
        } else {
            state = .stopped
            pendingReplies.removeAll(keepingCapacity: false)
            storedPendingByteCount = 0
            shouldNotify = true
        }
        lock.unlock()
        if shouldNotify {
            onStopped(nil)
        }
    }

    private func requestDrain() {
        execute { [weak self] in
            self?.drainUntilBackpressuredOrEmpty()
        }
    }

    private func drainUntilBackpressuredOrEmpty() {
        while true {
            let reply: TmuxInteractiveTerminalReply
            lock.lock()
            guard state == .draining else {
                lock.unlock()
                return
            }
            guard let pending = pendingReplies.first else {
                state = .idle
                lock.unlock()
                return
            }
            reply = TmuxInteractiveTerminalReply(
                binding: pending.reply.binding,
                bytes: pending.reply.bytes.subdata(
                    in: pending.offset..<pending.reply.bytes.count
                )
            )
            lock.unlock()

            let result: TmuxInteractivePTYWriteResult
            do {
                result = try write(reply)
            } catch {
                stopAfterFailure(error)
                return
            }

            switch result {
            case .written(let count):
                guard count > 0, count <= reply.bytes.count else {
                    stopAfterFailure(
                        TmuxInteractivePTYReplyPumpError.invalidWriteCount(
                            count,
                            maximum: reply.bytes.count
                        )
                    )
                    return
                }
                lock.lock()
                guard state == .draining,
                      pendingReplies.isEmpty == false else {
                    lock.unlock()
                    return
                }
                pendingReplies[0].offset += count
                storedPendingByteCount -= count
                if pendingReplies[0].offset ==
                    pendingReplies[0].reply.bytes.count {
                    pendingReplies.removeFirst()
                }
                lock.unlock()
            case .wouldBlock:
                lock.lock()
                guard state == .draining else {
                    lock.unlock()
                    return
                }
                state = .retryScheduled
                lock.unlock()
                scheduleRetry { [weak self] in
                    self?.retry()
                }
                return
            }
        }
    }

    private func retry() {
        lock.lock()
        guard state == .retryScheduled else {
            lock.unlock()
            return
        }
        state = .draining
        lock.unlock()
        requestDrain()
    }

    private func stopAfterFailure(_ error: Error) {
        let shouldNotify: Bool
        lock.lock()
        switch state {
        case .draining:
            state = .stopped
            pendingReplies.removeAll(keepingCapacity: false)
            storedPendingByteCount = 0
            shouldNotify = true
        case .inactive, .idle, .retryScheduled, .stopped:
            shouldNotify = false
        }
        lock.unlock()
        if shouldNotify {
            onStopped(error)
        }
    }
}
