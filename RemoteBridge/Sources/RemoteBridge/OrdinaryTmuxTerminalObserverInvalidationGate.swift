import Foundation

final class OrdinaryTmuxTerminalObserverInvalidationGate: @unchecked Sendable {
    typealias InvalidationHandler = @Sendable (
        OrdinaryTmuxTerminalFingerprintV1?
    ) -> Void

    private enum State {
        case pending
        case active
        case delivered
        case stopped
    }

    private struct PendingInvalidation {
        let fingerprint: OrdinaryTmuxTerminalFingerprintV1?
    }

    private let lock = NSLock()
    private let onInvalidation: InvalidationHandler
    private var state: State = .pending
    private var pendingInvalidation: PendingInvalidation?

    init(onInvalidation: @escaping InvalidationHandler) {
        self.onInvalidation = onInvalidation
    }

    func requireRebootstrap(
        _ fingerprint: OrdinaryTmuxTerminalFingerprintV1?
    ) {
        var delivery: PendingInvalidation?
        lock.lock()
        switch state {
        case .pending:
            if pendingInvalidation == nil {
                pendingInvalidation = PendingInvalidation(fingerprint: fingerprint)
            }
        case .active:
            state = .delivered
            delivery = PendingInvalidation(fingerprint: fingerprint)
        case .delivered, .stopped:
            break
        }
        lock.unlock()
        if let delivery {
            onInvalidation(delivery.fingerprint)
        }
    }

    func activate() {
        var delivery: PendingInvalidation?
        lock.lock()
        guard state == .pending else {
            lock.unlock()
            return
        }
        if let pendingInvalidation {
            delivery = pendingInvalidation
            self.pendingInvalidation = nil
            state = .delivered
        } else {
            state = .active
        }
        lock.unlock()
        if let delivery {
            onInvalidation(delivery.fingerprint)
        }
    }

    func stop() {
        lock.lock()
        state = .stopped
        pendingInvalidation = nil
        lock.unlock()
    }
}

