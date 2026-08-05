import Foundation

final class BridgeRequestSequencer: @unchecked Sendable {
    private let lock = NSLock()
    private var currentValue: UInt64

    init(initialValue: UInt64 = 0) {
        currentValue = initialValue
    }

    func next() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        currentValue &+= 1
        return currentValue
    }
}
