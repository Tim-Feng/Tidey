import Foundation

// TEST-ONLY: a lock-protected holder for a nullary test hook closure.
//
// `ClaudeTranscriptSession`/`CodexTranscriptSession` expose several hooks
// (e.g. `afterBoundaryReservationBeforePublishForTesting`,
// `afterResolveAttemptForTesting`) that are FIRED from more than one
// execution context: some call sites run on the session's own serial
// `queue`, but `start()` deliberately runs synchronously on the CALLER's
// thread (by design — it must complete before returning to the registry
// monitor). A plain `var (() -> Void)?` read from one context while a test
// assigns it from another is a genuine data race regardless of which
// specific threads are involved. Routing every read AND every write
// through the SAME lock, unconditionally, removes the race without caring
// which thread/queue either side runs on.
final class TestHookBox {
    private let lock = NSLock()
    private var hook: (() -> Void)?

    func set(_ hook: (() -> Void)?) {
        lock.lock()
        self.hook = hook
        lock.unlock()
    }

    func fire() {
        lock.lock()
        let hook = self.hook
        lock.unlock()
        hook?()
    }
}
