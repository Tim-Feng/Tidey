import Foundation
import XCTest
@testable import RemoteBridge

final class OrdinaryTmuxTerminalObserverInvalidationGateTests: XCTestCase {
    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = [OrdinaryTmuxTerminalFingerprintV1?]()

        func append(_ value: OrdinaryTmuxTerminalFingerprintV1?) {
            lock.lock()
            storage.append(value)
            lock.unlock()
        }

        var values: [OrdinaryTmuxTerminalFingerprintV1?] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }

    func testBuffersOneInvalidationUntilActivation() {
        let fingerprint = OrdinaryTmuxTerminalFingerprintV1(
            paneID: "%21",
            columns: 120,
            rows: 40,
            alternateOn: false
        )
        let box = Box()
        let gate = OrdinaryTmuxTerminalObserverInvalidationGate(
            onInvalidation: { box.append($0) }
        )

        gate.requireRebootstrap(fingerprint)
        gate.requireRebootstrap(nil)
        XCTAssertEqual(box.values.count, 0)

        gate.activate()
        gate.requireRebootstrap(nil)
        XCTAssertEqual(box.values, [fingerprint])
    }

    func testStopDiscardsPendingAndFutureInvalidations() {
        let box = Box()
        let gate = OrdinaryTmuxTerminalObserverInvalidationGate(
            onInvalidation: { box.append($0) }
        )

        gate.requireRebootstrap(nil)
        gate.stop()
        gate.activate()
        gate.requireRebootstrap(nil)

        XCTAssertEqual(box.values.count, 0)
    }
}
