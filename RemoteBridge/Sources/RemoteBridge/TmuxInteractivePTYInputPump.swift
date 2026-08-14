import Foundation

enum TmuxInteractivePTYInputEnqueueResult: Equatable, Sendable {
    case accepted
    case notActive
    case bindingMismatch
    case invalidInput
    case capacityExceeded(limit: Int)
}

enum TmuxInteractivePTYInputPumpError: Error, Equatable {
    case invalidWriteCount(Int, maximum: Int)
}

final class TmuxInteractivePTYInputPump: @unchecked Sendable {
    typealias Write = @Sendable (Data) throws -> TmuxInteractivePTYWriteResult
    typealias Execute = @Sendable (@escaping @Sendable () -> Void) -> Void
    typealias ScheduleRetry = @Sendable (@escaping @Sendable () -> Void) -> Void
    typealias OnStopped = @Sendable (Error?) -> Void

    private struct PendingInput {
        let bytes: Data
        var offset: Int
    }

    private enum State {
        case inactive
        case active
        case draining
        case retryScheduled
        case stopped
    }

    let binding: TmuxInteractiveSubscriptionBinding
    let maximumPendingBytes: Int

    private let lock = NSLock()
    private let write: Write
    private let execute: Execute
    private let scheduleRetry: ScheduleRetry
    private let onStopped: OnStopped
    private var state = State.inactive
    private var pendingInputs = [PendingInput]()
    private var storedPendingByteCount = 0

    init(
        binding: TmuxInteractiveSubscriptionBinding,
        maximumPendingBytes: Int,
        write: @escaping Write,
        execute: @escaping Execute,
        scheduleRetry: @escaping ScheduleRetry,
        onStopped: @escaping OnStopped
    ) {
        self.binding = binding
        self.maximumPendingBytes = max(1, maximumPendingBytes)
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

    func activate() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard state == .inactive else {
            return false
        }
        state = .active
        return true
    }

    func enqueue(
        _ input: TmuxInteractiveInput
    ) -> TmuxInteractivePTYInputEnqueueResult {
        let shouldStartDrain: Bool
        lock.lock()
        switch state {
        case .inactive, .stopped:
            lock.unlock()
            return .notActive
        case .active, .draining, .retryScheduled:
            break
        }
        guard input.binding == binding else {
            lock.unlock()
            return .bindingMismatch
        }
        guard input.bytes.isEmpty == false else {
            lock.unlock()
            return .invalidInput
        }
        guard input.bytes.count <= maximumPendingBytes -
                storedPendingByteCount else {
            lock.unlock()
            return .capacityExceeded(limit: maximumPendingBytes)
        }
        pendingInputs.append(PendingInput(bytes: input.bytes, offset: 0))
        storedPendingByteCount += input.bytes.count
        if state == .active {
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
            pendingInputs.removeAll(keepingCapacity: false)
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
            let bytes: Data
            lock.lock()
            guard state == .draining else {
                lock.unlock()
                return
            }
            guard let pending = pendingInputs.first else {
                state = .active
                lock.unlock()
                return
            }
            bytes = pending.bytes.subdata(
                in: pending.offset..<pending.bytes.count
            )
            lock.unlock()

            let result: TmuxInteractivePTYWriteResult
            do {
                result = try write(bytes)
            } catch {
                stopAfterFailure(error)
                return
            }

            switch result {
            case .written(let count):
                guard count > 0, count <= bytes.count else {
                    stopAfterFailure(
                        TmuxInteractivePTYInputPumpError.invalidWriteCount(
                            count,
                            maximum: bytes.count
                        )
                    )
                    return
                }
                lock.lock()
                guard state == .draining,
                      pendingInputs.isEmpty == false else {
                    lock.unlock()
                    return
                }
                pendingInputs[0].offset += count
                storedPendingByteCount -= count
                if pendingInputs[0].offset == pendingInputs[0].bytes.count {
                    pendingInputs.removeFirst()
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
        if state == .draining {
            state = .stopped
            pendingInputs.removeAll(keepingCapacity: false)
            storedPendingByteCount = 0
            shouldNotify = true
        } else {
            shouldNotify = false
        }
        lock.unlock()
        if shouldNotify {
            onStopped(error)
        }
    }
}
