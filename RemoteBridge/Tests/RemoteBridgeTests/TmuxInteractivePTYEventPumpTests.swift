import Foundation
import XCTest

@testable import RemoteBridge

final class TmuxInteractivePTYEventPumpTests: XCTestCase {
    private struct WriteFailure: Error {}
    private struct PollFailure: Error {}

    private final class PollProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var results: [Result<TmuxInteractivePTYConnectionSessionPollResult, Error>]
        private(set) var callCount = 0

        init(_ results: [Result<TmuxInteractivePTYConnectionSessionPollResult, Error>]) {
            self.results = results
        }

        func poll() throws -> TmuxInteractivePTYConnectionSessionPollResult {
            lock.lock()
            defer { lock.unlock() }
            callCount += 1
            return try results.removeFirst().get()
        }
    }

    private final class RetrySchedulerProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var work = [@Sendable () -> Void]()

        func schedule(_ next: @escaping @Sendable () -> Void) {
            lock.lock()
            work.append(next)
            lock.unlock()
        }

        func runNext() {
            lock.lock()
            let next = work.removeFirst()
            lock.unlock()
            next()
        }

        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return work.count
        }
    }

    private final class DeliveryProbe: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var events = [TmuxInteractivePTYEvent]()
        private var completions = [@Sendable (Result<Void, Error>) -> Void]()

        func deliver(
            _ event: TmuxInteractivePTYEvent,
            completion: @escaping @Sendable (Result<Void, Error>) -> Void
        ) {
            lock.lock()
            events.append(event)
            completions.append(completion)
            lock.unlock()
        }

        func complete(_ index: Int, with result: Result<Void, Error>) {
            lock.lock()
            let completion = completions[index]
            lock.unlock()
            completion(result)
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

    func testPumpWaitsForEachWriteCompletionAndStopsOnTerminalOrFailure() {
        let binding = TmuxInteractiveSubscriptionBinding(
            subscriptionID: "interactive-1",
            generation: 9
        )
        let start = TmuxInteractiveAuthoritativeStart(
            binding: binding,
            attachProof: TmuxInteractiveAttachProof(
                workspaceID: "workspace-1",
                panelID: "panel-1",
                sessionID: "$1",
                windowID: "@2",
                paneID: "%3"
            ),
            viewport: TmuxInteractiveViewport(columns: 80, rows: 24),
            initialBytes: Data([0x1b, 0x5b, 0x48])
        )
        let output = TmuxInteractiveOutputChunk(
            binding: binding,
            sequence: 1,
            bytes: Data([0x61])
        )
        let terminal = TmuxInteractiveStateChange(
            binding: binding,
            state: .detached,
            message: nil
        )
        let poll = PollProbe([
            .success(.wouldBlock),
            .success(.start(start)),
            .success(.output(output)),
            .success(.terminal(terminal)),
        ])
        let scheduler = RetrySchedulerProbe()
        let delivery = DeliveryProbe()
        let stop = StopProbe()
        let pump = TmuxInteractivePTYEventPump(
            poll: poll.poll,
            execute: { work in work() },
            scheduleRetry: scheduler.schedule,
            deliver: delivery.deliver,
            onStopped: stop.stopped
        )

        pump.start()
        XCTAssertEqual(poll.callCount, 1)
        XCTAssertEqual(scheduler.count, 1)
        XCTAssertTrue(delivery.events.isEmpty)

        scheduler.runNext()
        XCTAssertEqual(poll.callCount, 2)
        XCTAssertEqual(delivery.events, [.start(start)])
        XCTAssertEqual(scheduler.count, 0)

        delivery.complete(0, with: .success(()))
        XCTAssertEqual(poll.callCount, 3)
        XCTAssertEqual(delivery.events, [.start(start), .output(output)])

        delivery.complete(1, with: .success(()))
        XCTAssertEqual(poll.callCount, 4)
        XCTAssertEqual(
            delivery.events,
            [.start(start), .output(output), .terminal(terminal)]
        )
        XCTAssertEqual(stop.callCount, 0)

        delivery.complete(2, with: .success(()))
        XCTAssertEqual(stop.callCount, 1)
        XCTAssertEqual(stop.errorCount, 0)
        XCTAssertEqual(poll.callCount, 4)

        let failedDelivery = DeliveryProbe()
        let writeStop = StopProbe()
        let writeFailurePoll = PollProbe([.success(.output(output))])
        let writeFailurePump = TmuxInteractivePTYEventPump(
            poll: writeFailurePoll.poll,
            execute: { work in work() },
            scheduleRetry: { _ in XCTFail("Output should not schedule retry") },
            deliver: failedDelivery.deliver,
            onStopped: writeStop.stopped
        )
        writeFailurePump.start()
        failedDelivery.complete(0, with: .failure(WriteFailure()))
        XCTAssertEqual(writeFailurePoll.callCount, 1)
        XCTAssertEqual(writeStop.callCount, 1)
        XCTAssertEqual(writeStop.errorCount, 1)

        let pollStop = StopProbe()
        let pollFailurePump = TmuxInteractivePTYEventPump(
            poll: PollProbe([.failure(PollFailure())]).poll,
            execute: { work in work() },
            scheduleRetry: { _ in XCTFail("Failure should not schedule retry") },
            deliver: { _, _ in XCTFail("Failure should not deliver") },
            onStopped: pollStop.stopped
        )
        pollFailurePump.start()
        XCTAssertEqual(pollStop.callCount, 1)
        XCTAssertEqual(pollStop.errorCount, 1)
    }

    func testPumpSerializesStreamingStartupThroughDeliveryCompletion() {
        let binding = TmuxInteractiveSubscriptionBinding(
            subscriptionID: "interactive-1",
            generation: 9
        )
        let attached = TmuxInteractiveAttached(
            binding: binding,
            attachProof: TmuxInteractiveAttachProof(
                workspaceID: "workspace-1",
                panelID: "panel-1",
                sessionID: "$1",
                windowID: "@2",
                paneID: "%3"
            ),
            viewport: TmuxInteractiveViewport(columns: 80, rows: 24),
            initialBytes: Data([0x1b, 0x5b, 0x3e, 0x63]),
            sequence: 1
        )
        let output = TmuxInteractiveOutputChunk(
            binding: binding,
            sequence: 2,
            bytes: Data([0x1b, 0x5b, 0x32, 0x4a])
        )
        let ready = TmuxInteractiveReady(binding: binding, sequence: 3)
        let terminal = TmuxInteractiveStateChange(
            binding: binding,
            state: .detached,
            message: nil
        )
        let poll = PollProbe([
            .success(.attached(attached)),
            .success(.output(output)),
            .success(.ready(ready)),
            .success(.terminal(terminal)),
        ])
        let delivery = DeliveryProbe()
        let stop = StopProbe()
        let pump = TmuxInteractivePTYEventPump(
            poll: poll.poll,
            execute: { work in work() },
            scheduleRetry: { _ in XCTFail("Streaming events should not retry") },
            deliver: delivery.deliver,
            onStopped: stop.stopped
        )

        pump.start()
        XCTAssertEqual(poll.callCount, 1)
        XCTAssertEqual(delivery.events, [.attached(attached)])

        delivery.complete(0, with: .success(()))
        XCTAssertEqual(poll.callCount, 2)
        XCTAssertEqual(delivery.events, [.attached(attached), .output(output)])

        delivery.complete(1, with: .success(()))
        XCTAssertEqual(poll.callCount, 3)
        XCTAssertEqual(
            delivery.events,
            [.attached(attached), .output(output), .ready(ready)]
        )

        delivery.complete(2, with: .success(()))
        XCTAssertEqual(poll.callCount, 4)
        XCTAssertEqual(
            delivery.events,
            [.attached(attached), .output(output), .ready(ready), .terminal(terminal)]
        )
        XCTAssertEqual(stop.callCount, 0)

        delivery.complete(3, with: .success(()))
        XCTAssertEqual(stop.callCount, 1)
        XCTAssertEqual(stop.errorCount, 0)
        XCTAssertEqual(poll.callCount, 4)
    }
}
