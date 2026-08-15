import Foundation
import XCTest

@testable import RemoteBridge

final class TmuxInteractivePTYReplyPumpTests: XCTestCase {
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
        private(set) var replies = [TmuxInteractiveTerminalReply]()

        init(results: [TmuxInteractivePTYWriteResult]) {
            self.results = results
        }

        func write(
            _ reply: TmuxInteractiveTerminalReply
        ) throws -> TmuxInteractivePTYWriteResult {
            lock.lock()
            defer { lock.unlock() }
            replies.append(reply)
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

    func testReplyPumpGatesProofPhaseBoundsStartupAndPreservesPartialWritesIntoLive() {
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
                .written(1),
                .written(4),
            ]
        )
        let stop = StopProbe()
        let pump = TmuxInteractivePTYReplyPump(
            binding: binding,
            maximumPendingBytes: 4,
            maximumStartupBytes: 4,
            write: { try writer.write($0) },
            execute: { executor.submit($0) },
            scheduleRetry: { retryScheduler.submit($0) },
            onStopped: { stop.stopped(error: $0) }
        )
        let first = TmuxInteractiveTerminalReply(
            binding: binding,
            bytes: Data("abc".utf8)
        )

        XCTAssertEqual(pump.enqueue(first), .notActive)
        XCTAssertFalse(pump.markLive())
        XCTAssertTrue(pump.activateSettling())
        XCTAssertEqual(
            pump.enqueue(
                TmuxInteractiveTerminalReply(
                    binding: staleBinding,
                    bytes: Data("x".utf8)
                )
            ),
            .bindingMismatch
        )
        XCTAssertEqual(
            pump.enqueue(
                TmuxInteractiveTerminalReply(binding: binding, bytes: Data())
            ),
            .invalidReply
        )
        XCTAssertEqual(pump.enqueue(first), .accepted)
        XCTAssertEqual(pump.startupAcceptedByteCount, 3)
        XCTAssertEqual(
            pump.enqueue(
                TmuxInteractiveTerminalReply(
                    binding: binding,
                    bytes: Data("de".utf8)
                )
            ),
            .startupCapacityExceeded(limit: 4)
        )
        XCTAssertEqual(executor.count, 1)

        executor.runNext()
        XCTAssertEqual(
            writer.replies.map(\.bytes),
            [Data("abc".utf8), Data("bc".utf8)]
        )
        XCTAssertEqual(pump.pendingByteCount, 2)
        XCTAssertEqual(retryScheduler.count, 1)
        XCTAssertEqual(
            pump.enqueue(
                TmuxInteractiveTerminalReply(
                    binding: binding,
                    bytes: Data("d".utf8)
                )
            ),
            .accepted
        )
        XCTAssertEqual(pump.startupAcceptedByteCount, 4)
        XCTAssertEqual(
            pump.enqueue(
                TmuxInteractiveTerminalReply(
                    binding: binding,
                    bytes: Data("x".utf8)
                )
            ),
            .startupCapacityExceeded(limit: 4)
        )

        retryScheduler.runNext()
        executor.runNext()
        XCTAssertEqual(pump.pendingByteCount, 0)
        XCTAssertEqual(
            writer.replies.map(\.bytes),
            [
                Data("abc".utf8),
                Data("bc".utf8),
                Data("bc".utf8),
                Data("d".utf8),
            ]
        )

        XCTAssertTrue(pump.markLive())
        let liveReply = TmuxInteractiveTerminalReply(
            binding: binding,
            bytes: Data("efgh".utf8)
        )
        XCTAssertEqual(pump.enqueue(liveReply), .accepted)
        XCTAssertEqual(pump.startupAcceptedByteCount, 4)
        executor.runNext()
        XCTAssertEqual(pump.pendingByteCount, 0)
        XCTAssertEqual(writer.replies.last, liveReply)

        pump.stop()
        pump.stop()
        XCTAssertEqual(stop.callCount, 1)
        XCTAssertEqual(stop.errorCount, 0)
        XCTAssertEqual(pump.enqueue(first), .notActive)
    }
}
