import Foundation
import XCTest

@testable import RemoteBridge

final class TmuxInteractivePTYResizePumpTests: XCTestCase {
    private struct ApplyFailure: Error {}

    private final class ManualWorkQueue: @unchecked Sendable {
        private let lock = NSLock()
        private var work = [@Sendable () -> Void]()

        func submit(_ item: @escaping @Sendable () -> Void) {
            lock.lock()
            work.append(item)
            lock.unlock()
        }

        func runNext() {
            lock.lock()
            let item = work.removeFirst()
            lock.unlock()
            item()
        }

        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return work.count
        }
    }

    private final class ApplyProbe: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var resizes = [TmuxInteractiveResize]()
        var onApply: (@Sendable (TmuxInteractiveResize) -> Void)?

        func apply(_ resize: TmuxInteractiveResize) throws -> Bool {
            lock.lock()
            resizes.append(resize)
            let callback = onApply
            lock.unlock()
            callback?(resize)
            return true
        }
    }

    private final class PumpBox: @unchecked Sendable {
        var pump: TmuxInteractivePTYResizePump?
    }

    private final class StopProbe: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var callCount = 0
        private(set) var errorCount = 0

        func stopped(error: Error?) {
            lock.lock()
            callCount += 1
            if error != nil {
                errorCount += 1
            }
            lock.unlock()
        }
    }

    func testResizePumpCoalescesBurstToLatestViewportWithoutReordering() {
        let binding = TmuxInteractiveSubscriptionBinding(
            subscriptionID: "interactive-1",
            generation: 9
        )
        let staleBinding = TmuxInteractiveSubscriptionBinding(
            subscriptionID: binding.subscriptionID,
            generation: binding.generation - 1
        )
        let first = resize(binding: binding, columns: 70, rows: 20)
        let second = resize(binding: binding, columns: 80, rows: 22)
        let third = resize(binding: binding, columns: 90, rows: 24)
        let fourth = resize(binding: binding, columns: 100, rows: 26)
        let fifth = resize(binding: binding, columns: 110, rows: 28)
        let sixth = resize(binding: binding, columns: 120, rows: 30)
        let executor = ManualWorkQueue()
        let applyProbe = ApplyProbe()
        let stop = StopProbe()
        let box = PumpBox()
        let pump = TmuxInteractivePTYResizePump(
            binding: binding,
            apply: { try applyProbe.apply($0) },
            execute: { executor.submit($0) },
            onStopped: { stop.stopped(error: $0) }
        )
        box.pump = pump

        XCTAssertEqual(pump.enqueue(first), .notActive)
        XCTAssertTrue(pump.activate())
        XCTAssertEqual(
            pump.enqueue(
                resize(binding: staleBinding, columns: 60, rows: 18)
            ),
            .bindingMismatch
        )
        XCTAssertEqual(
            pump.enqueue(resize(binding: binding, columns: 0, rows: 24)),
            .invalidViewport
        )

        XCTAssertEqual(pump.enqueue(first), .accepted)
        XCTAssertEqual(pump.enqueue(second), .accepted)
        XCTAssertEqual(pump.enqueue(third), .accepted)
        XCTAssertEqual(executor.count, 1)
        executor.runNext()
        XCTAssertEqual(applyProbe.resizes, [third])
        XCTAssertEqual(stop.callCount, 0)

        applyProbe.onApply = { resize in
            guard resize == fourth, let pump = box.pump else { return }
            XCTAssertEqual(pump.enqueue(fifth), .accepted)
            XCTAssertEqual(pump.enqueue(sixth), .accepted)
        }
        XCTAssertEqual(pump.enqueue(fourth), .accepted)
        XCTAssertEqual(executor.count, 1)
        executor.runNext()
        XCTAssertEqual(applyProbe.resizes, [third, fourth, sixth])
        XCTAssertEqual(executor.count, 0)

        XCTAssertEqual(
            pump.enqueue(resize(binding: binding, columns: 130, rows: 32)),
            .accepted
        )
        XCTAssertEqual(executor.count, 1)
        pump.stop()
        pump.stop()
        XCTAssertEqual(stop.callCount, 1)
        XCTAssertEqual(stop.errorCount, 0)
        executor.runNext()
        XCTAssertEqual(applyProbe.resizes, [third, fourth, sixth])
        XCTAssertEqual(pump.enqueue(first), .notActive)

        let failingExecutor = ManualWorkQueue()
        let failingStop = StopProbe()
        let failingPump = TmuxInteractivePTYResizePump(
            binding: binding,
            apply: { _ in throw ApplyFailure() },
            execute: { failingExecutor.submit($0) },
            onStopped: { failingStop.stopped(error: $0) }
        )
        XCTAssertTrue(failingPump.activate())
        XCTAssertEqual(failingPump.enqueue(first), .accepted)
        failingExecutor.runNext()
        XCTAssertEqual(failingStop.callCount, 1)
        XCTAssertEqual(failingStop.errorCount, 1)
        XCTAssertEqual(failingPump.enqueue(first), .notActive)
    }

    private func resize(
        binding: TmuxInteractiveSubscriptionBinding,
        columns: Int,
        rows: Int
    ) -> TmuxInteractiveResize {
        TmuxInteractiveResize(
            binding: binding,
            viewport: TmuxInteractiveViewport(columns: columns, rows: rows)
        )
    }
}
