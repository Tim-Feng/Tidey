import Foundation
import XCTest

@testable import RemoteBridge

final class TmuxInteractivePTYInputPumpTests: XCTestCase {
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

    private final class WriterProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var results: [TmuxInteractivePTYWriteResult]
        private(set) var writes = [Data]()

        init(results: [TmuxInteractivePTYWriteResult]) {
            self.results = results
        }

        func write(_ bytes: Data) throws -> TmuxInteractivePTYWriteResult {
            lock.lock()
            defer { lock.unlock() }
            writes.append(bytes)
            return results.removeFirst()
        }
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

    func testInputPumpPreservesBytesAcrossPartialWritesBackpressureAndStop() {
        let binding = TmuxInteractiveSubscriptionBinding(
            subscriptionID: "interactive-1",
            generation: 9
        )
        let staleBinding = TmuxInteractiveSubscriptionBinding(
            subscriptionID: binding.subscriptionID,
            generation: binding.generation - 1
        )
        let executor = ManualWorkQueue()
        let retryScheduler = ManualWorkQueue()
        let writer = WriterProbe(
            results: [
                .written(1),
                .wouldBlock,
                .written(2),
                .written(2),
                .written(1),
            ]
        )
        let stop = StopProbe()
        let pump = TmuxInteractivePTYInputPump(
            binding: binding,
            maximumPendingBytes: 6,
            write: { try writer.write($0) },
            execute: { executor.submit($0) },
            scheduleRetry: { retryScheduler.submit($0) },
            onStopped: { stop.stopped(error: $0) }
        )
        let first = TmuxInteractiveInput(
            binding: binding,
            bytes: Data("abc".utf8)
        )
        let second = TmuxInteractiveInput(
            binding: binding,
            bytes: Data("def".utf8)
        )

        XCTAssertEqual(pump.enqueue(first), .notActive)
        XCTAssertTrue(pump.activate())
        XCTAssertEqual(
            pump.enqueue(
                TmuxInteractiveInput(
                    binding: staleBinding,
                    bytes: Data("x".utf8)
                )
            ),
            .bindingMismatch
        )
        XCTAssertEqual(pump.enqueue(first), .accepted)
        XCTAssertEqual(pump.enqueue(second), .accepted)
        XCTAssertEqual(pump.pendingByteCount, 6)
        XCTAssertEqual(executor.count, 1)
        XCTAssertEqual(
            pump.enqueue(
                TmuxInteractiveInput(
                    binding: binding,
                    bytes: Data("x".utf8)
                )
            ),
            .capacityExceeded(limit: 6)
        )

        executor.runNext()

        XCTAssertEqual(writer.writes, [Data("abc".utf8), Data("bc".utf8)])
        XCTAssertEqual(pump.pendingByteCount, 5)
        XCTAssertEqual(retryScheduler.count, 1)
        XCTAssertEqual(executor.count, 0)

        retryScheduler.runNext()
        XCTAssertEqual(executor.count, 1)
        executor.runNext()

        XCTAssertEqual(
            writer.writes,
            [
                Data("abc".utf8),
                Data("bc".utf8),
                Data("bc".utf8),
                Data("def".utf8),
                Data("f".utf8),
            ]
        )
        XCTAssertEqual(pump.pendingByteCount, 0)
        XCTAssertEqual(stop.callCount, 0)

        XCTAssertEqual(
            pump.enqueue(
                TmuxInteractiveInput(
                    binding: binding,
                    bytes: Data("gh".utf8)
                )
            ),
            .accepted
        )
        XCTAssertEqual(executor.count, 1)
        pump.stop()
        pump.stop()
        XCTAssertEqual(pump.pendingByteCount, 0)
        XCTAssertEqual(stop.callCount, 1)
        XCTAssertEqual(stop.errorCount, 0)
        executor.runNext()
        XCTAssertEqual(writer.writes.count, 5)
        XCTAssertEqual(pump.enqueue(first), .notActive)

        let invalidExecutor = ManualWorkQueue()
        let invalidStop = StopProbe()
        let invalidPump = TmuxInteractivePTYInputPump(
            binding: binding,
            maximumPendingBytes: 6,
            write: { _ in .written(0) },
            execute: { invalidExecutor.submit($0) },
            scheduleRetry: { _ in XCTFail("Invalid write must not retry") },
            onStopped: { invalidStop.stopped(error: $0) }
        )
        XCTAssertTrue(invalidPump.activate())
        XCTAssertEqual(invalidPump.enqueue(first), .accepted)
        invalidExecutor.runNext()
        XCTAssertEqual(invalidStop.callCount, 1)
        XCTAssertEqual(invalidStop.errorCount, 1)
        XCTAssertEqual(invalidPump.pendingByteCount, 0)
        XCTAssertEqual(invalidPump.enqueue(first), .notActive)
    }
}
