import Foundation

enum TmuxInteractivePTYResizeEnqueueResult: Equatable, Sendable {
    case accepted
    case notActive
    case bindingMismatch
    case invalidViewport
}

final class TmuxInteractivePTYResizePump: @unchecked Sendable {
    typealias Apply = @Sendable (TmuxInteractiveResize) throws -> Bool
    typealias Execute = @Sendable (@escaping @Sendable () -> Void) -> Void
    typealias OnStopped = @Sendable (Error?) -> Void

    private enum State {
        case inactive
        case active
        case applying
        case stopped
    }

    let binding: TmuxInteractiveSubscriptionBinding

    private let lock = NSLock()
    private let apply: Apply
    private let execute: Execute
    private let onStopped: OnStopped
    private var state = State.inactive
    private var pendingResize: TmuxInteractiveResize?

    init(
        binding: TmuxInteractiveSubscriptionBinding,
        apply: @escaping Apply,
        execute: @escaping Execute,
        onStopped: @escaping OnStopped
    ) {
        self.binding = binding
        self.apply = apply
        self.execute = execute
        self.onStopped = onStopped
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
        _ resize: TmuxInteractiveResize
    ) -> TmuxInteractivePTYResizeEnqueueResult {
        let shouldStartApply: Bool
        lock.lock()
        switch state {
        case .inactive, .stopped:
            lock.unlock()
            return .notActive
        case .active, .applying:
            break
        }
        guard resize.binding == binding else {
            lock.unlock()
            return .bindingMismatch
        }
        guard Self.isValid(resize.viewport) else {
            lock.unlock()
            return .invalidViewport
        }
        pendingResize = resize
        if state == .active {
            state = .applying
            shouldStartApply = true
        } else {
            shouldStartApply = false
        }
        lock.unlock()

        if shouldStartApply {
            requestApply()
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
            pendingResize = nil
            shouldNotify = true
        }
        lock.unlock()
        if shouldNotify {
            onStopped(nil)
        }
    }

    private func requestApply() {
        execute { [weak self] in
            self?.applyPendingResizes()
        }
    }

    private func applyPendingResizes() {
        while true {
            let resize: TmuxInteractiveResize
            lock.lock()
            guard state == .applying else {
                lock.unlock()
                return
            }
            guard let nextResize = pendingResize else {
                state = .active
                lock.unlock()
                return
            }
            resize = nextResize
            pendingResize = nil
            lock.unlock()

            do {
                _ = try apply(resize)
            } catch {
                stopAfterFailure(error)
                return
            }
        }
    }

    private func stopAfterFailure(_ error: Error) {
        let shouldNotify: Bool
        lock.lock()
        if state == .applying {
            state = .stopped
            pendingResize = nil
            shouldNotify = true
        } else {
            shouldNotify = false
        }
        lock.unlock()
        if shouldNotify {
            onStopped(error)
        }
    }

    private static func isValid(
        _ viewport: TmuxInteractiveViewport
    ) -> Bool {
        viewport.columns > 0 &&
            viewport.columns <= Int(UInt16.max) &&
            viewport.rows > 0 &&
            viewport.rows <= Int(UInt16.max)
    }
}
