import Foundation

enum TmuxInteractivePTYEvent: Equatable, Sendable {
    case start(TmuxInteractiveAuthoritativeStart)
    case attached(TmuxInteractiveAttached)
    case output(TmuxInteractiveOutputChunk)
    case ready(TmuxInteractiveReady)
    case terminal(TmuxInteractiveStateChange)
}

final class TmuxInteractivePTYEventPump: @unchecked Sendable {
    typealias Poll = @Sendable () throws -> TmuxInteractivePTYConnectionSessionPollResult
    typealias Execute = @Sendable (@escaping @Sendable () -> Void) -> Void
    typealias ScheduleRetry = @Sendable (@escaping @Sendable () -> Void) -> Void
    typealias DeliveryCompletion = @Sendable (Result<Void, Error>) -> Void
    typealias Deliver = @Sendable (
        TmuxInteractivePTYEvent,
        @escaping DeliveryCompletion
    ) -> Void
    typealias OnStopped = @Sendable (Error?) -> Void

    private enum State {
        case idle
        case running
        case polling
        case retryScheduled
        case delivering
        case stopped
    }

    private let lock = NSLock()
    private let poll: Poll
    private let execute: Execute
    private let scheduleRetry: ScheduleRetry
    private let deliver: Deliver
    private let onStopped: OnStopped
    private var state = State.idle

    init(
        poll: @escaping Poll,
        execute: @escaping Execute,
        scheduleRetry: @escaping ScheduleRetry,
        deliver: @escaping Deliver,
        onStopped: @escaping OnStopped
    ) {
        self.poll = poll
        self.execute = execute
        self.scheduleRetry = scheduleRetry
        self.deliver = deliver
        self.onStopped = onStopped
    }

    func start() {
        lock.lock()
        guard state == .idle else {
            lock.unlock()
            return
        }
        state = .running
        lock.unlock()
        requestPoll()
    }

    func stop() {
        let shouldNotify: Bool
        lock.lock()
        if state == .stopped {
            shouldNotify = false
        } else {
            state = .stopped
            shouldNotify = true
        }
        lock.unlock()
        if shouldNotify {
            onStopped(nil)
        }
    }

    private func requestPoll() {
        lock.lock()
        guard state == .running else {
            lock.unlock()
            return
        }
        state = .polling
        lock.unlock()
        execute { [weak self] in
            self?.performPoll()
        }
    }

    private func performPoll() {
        do {
            let result = try poll()
            handlePollResult(result)
        } catch {
            stopAfterFailure(error, expectedState: .polling)
        }
    }

    private func handlePollResult(
        _ result: TmuxInteractivePTYConnectionSessionPollResult
    ) {
        switch result {
        case .wouldBlock:
            lock.lock()
            guard state == .polling else {
                lock.unlock()
                return
            }
            state = .retryScheduled
            lock.unlock()
            scheduleRetry { [weak self] in
                self?.retry()
            }
        case .start(let start):
            beginDelivery(.start(start), isTerminal: false)
        case .attached(let attached):
            beginDelivery(.attached(attached), isTerminal: false)
        case .output(let output):
            beginDelivery(.output(output), isTerminal: false)
        case .ready(let ready):
            beginDelivery(.ready(ready), isTerminal: false)
        case .terminal(let terminal):
            beginDelivery(.terminal(terminal), isTerminal: true)
        case .finished:
            finishWithoutFailure(expectedState: .polling)
        }
    }

    private func retry() {
        lock.lock()
        guard state == .retryScheduled else {
            lock.unlock()
            return
        }
        state = .running
        lock.unlock()
        requestPoll()
    }

    private func beginDelivery(
        _ event: TmuxInteractivePTYEvent,
        isTerminal: Bool
    ) {
        lock.lock()
        guard state == .polling else {
            lock.unlock()
            return
        }
        state = .delivering
        lock.unlock()
        deliver(event) { [weak self] result in
            self?.completeDelivery(result, isTerminal: isTerminal)
        }
    }

    private func completeDelivery(
        _ result: Result<Void, Error>,
        isTerminal: Bool
    ) {
        switch result {
        case .success:
            if isTerminal {
                finishWithoutFailure(expectedState: .delivering)
            } else {
                lock.lock()
                guard state == .delivering else {
                    lock.unlock()
                    return
                }
                state = .running
                lock.unlock()
                requestPoll()
            }
        case .failure(let error):
            stopAfterFailure(error, expectedState: .delivering)
        }
    }

    private func finishWithoutFailure(expectedState: State) {
        let shouldNotify: Bool
        lock.lock()
        if state == expectedState {
            state = .stopped
            shouldNotify = true
        } else {
            shouldNotify = false
        }
        lock.unlock()
        if shouldNotify {
            onStopped(nil)
        }
    }

    private func stopAfterFailure(_ error: Error, expectedState: State) {
        let shouldNotify: Bool
        lock.lock()
        if state == expectedState {
            state = .stopped
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
