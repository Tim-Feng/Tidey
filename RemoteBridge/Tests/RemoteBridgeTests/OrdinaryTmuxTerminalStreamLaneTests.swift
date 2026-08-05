import Foundation
import XCTest
@testable import RemoteBridge

final class OrdinaryTmuxTerminalStreamLaneTests: XCTestCase {
    private enum StubError: Error {
        case replacementStopFailed
    }

    private final class EventLog: @unchecked Sendable {
        private let lock = NSLock()
        private var storedEvents = [String]()

        func append(_ event: String) {
            lock.lock()
            storedEvents.append(event)
            lock.unlock()
        }

        var events: [String] {
            lock.lock()
            defer { lock.unlock() }
            return storedEvents
        }
    }

    private final class CompletionBox: @unchecked Sendable {
        private let lock = NSLock()
        private var storedResult: Result<OrdinaryTmuxTerminalStreamLaneCandidate, Error>??

        func store(_ result: Result<OrdinaryTmuxTerminalStreamLaneCandidate, Error>?) {
            lock.lock()
            storedResult = .some(result)
            lock.unlock()
        }

        var result: Result<OrdinaryTmuxTerminalStreamLaneCandidate, Error>?? {
            lock.lock()
            defer { lock.unlock() }
            return storedResult
        }
    }

    private final class RecordingSubscription: OrdinaryTmuxTerminalStreamSubscribing, @unchecked Sendable {
        let route: OrdinaryTmuxPanelRoute
        private let label: String
        private let eventLog: EventLog
        private let lock = NSLock()
        private var remainingReleaseFailures: Int
        private var remainingReplacementFailures: Int

        init(route: OrdinaryTmuxPanelRoute,
             label: String,
             eventLog: EventLog,
             releaseFailures: Int = 0,
             replacementFailures: Int = 0) {
            self.route = route
            self.label = label
            self.eventLog = eventLog
            remainingReleaseFailures = releaseFailures
            remainingReplacementFailures = replacementFailures
        }

        @discardableResult
        func stop() -> Bool {
            eventLog.append("stop-\(label)")
            lock.lock()
            let shouldFail = remainingReleaseFailures > 0
            if shouldFail {
                remainingReleaseFailures -= 1
            }
            lock.unlock()
            return shouldFail == false
        }

        func stopForReplacement() throws {
            eventLog.append("stopForReplacement-\(label)")
            lock.lock()
            let shouldFail = remainingReplacementFailures > 0
            if shouldFail {
                remainingReplacementFailures -= 1
            }
            lock.unlock()
            if shouldFail {
                throw StubError.replacementStopFailed
            }
        }
    }

    func testReplacementInvalidatesAndStopsOldLeaseBeforeBuildingNewLease() throws {
        let queue = DispatchQueue(label: "OrdinaryTmuxTerminalStreamLaneTests.replacement")
        let lane = OrdinaryTmuxTerminalStreamLane(queue: queue)
        let eventLog = EventLog()
        let first = makeCandidate(token: 1, label: "1", eventLog: eventLog)
        let second = makeCandidate(token: 2, label: "2", eventLog: eventLog)

        _ = try XCTUnwrap(submit(lane: lane, sequence: 1) {
            eventLog.append("build-1")
            return first
        }).get()
        XCTAssertTrue(first.lease.deliveryGate.accept {
            eventLog.append("invalidate-1")
        })

        _ = try XCTUnwrap(submit(lane: lane, sequence: 2) {
            eventLog.append("build-2")
            return second
        }).get()

        XCTAssertEqual(eventLog.events, [
            "build-1",
            "invalidate-1",
            "stopForReplacement-1",
            "build-2",
        ])
    }

    func testReleaseStopsOnlyTheExactCurrentToken() throws {
        let queue = DispatchQueue(label: "OrdinaryTmuxTerminalStreamLaneTests.release")
        let lane = OrdinaryTmuxTerminalStreamLane(queue: queue)
        let eventLog = EventLog()
        let first = makeCandidate(token: 1, label: "1", eventLog: eventLog)
        let second = makeCandidate(token: 2, label: "2", eventLog: eventLog)

        _ = try XCTUnwrap(submit(lane: lane, sequence: 1) {
            eventLog.append("build-1")
            return first
        }).get()
        XCTAssertTrue(first.lease.deliveryGate.accept {})
        _ = try XCTUnwrap(submit(lane: lane, sequence: 2) {
            eventLog.append("build-2")
            return second
        }).get()
        XCTAssertTrue(second.lease.deliveryGate.accept {
            eventLog.append("invalidate-2")
        })

        lane.releaseIfCurrent(token: 1)
        drain(queue)
        XCTAssertFalse(eventLog.events.contains("stop-2"))

        lane.releaseIfCurrent(token: 2)
        drain(queue)
        XCTAssertEqual(Array(eventLog.events.suffix(2)), ["invalidate-2", "stop-2"])
    }

    func testReplacementStopFailureSkipsBuildAndTheNextRequestRetriesOldLease() throws {
        let queue = DispatchQueue(label: "OrdinaryTmuxTerminalStreamLaneTests.retry")
        let lane = OrdinaryTmuxTerminalStreamLane(queue: queue)
        let eventLog = EventLog()
        let first = makeCandidate(token: 1,
                                  label: "1",
                                  eventLog: eventLog,
                                  replacementFailures: 1)
        let second = makeCandidate(token: 2, label: "2", eventLog: eventLog)
        let third = makeCandidate(token: 3, label: "3", eventLog: eventLog)

        _ = try XCTUnwrap(submit(lane: lane, sequence: 1) {
            eventLog.append("build-1")
            return first
        }).get()
        XCTAssertTrue(first.lease.deliveryGate.accept {
            eventLog.append("invalidate-1")
        })

        let failed = try XCTUnwrap(submit(lane: lane, sequence: 2) {
            eventLog.append("build-2")
            return second
        })
        XCTAssertThrowsError(try failed.get())
        XCTAssertEqual(eventLog.events, [
            "build-1",
            "invalidate-1",
            "stopForReplacement-1",
        ])

        _ = try XCTUnwrap(submit(lane: lane, sequence: 3) {
            eventLog.append("build-3")
            return third
        }).get()
        XCTAssertEqual(eventLog.events, [
            "build-1",
            "invalidate-1",
            "stopForReplacement-1",
            "stopForReplacement-1",
            "build-3",
        ])
    }

    func testReleaseStopFailureKeepsLeaseForReplacementRetries() throws {
        let queue = DispatchQueue(label: "OrdinaryTmuxTerminalStreamLaneTests.releaseRetry")
        let lane = OrdinaryTmuxTerminalStreamLane(queue: queue)
        let eventLog = EventLog()
        let first = makeCandidate(token: 1,
                                  label: "1",
                                  eventLog: eventLog,
                                  releaseFailures: 1,
                                  replacementFailures: 1)
        let second = makeCandidate(token: 2, label: "2", eventLog: eventLog)
        let third = makeCandidate(token: 3, label: "3", eventLog: eventLog)

        _ = try XCTUnwrap(submit(lane: lane, sequence: 1) {
            eventLog.append("build-1")
            return first
        }).get()
        XCTAssertTrue(first.lease.deliveryGate.accept {
            eventLog.append("invalidate-1")
        })

        lane.releaseIfCurrent(token: 1)
        drain(queue)
        let failed = try XCTUnwrap(submit(lane: lane, sequence: 2) {
            eventLog.append("build-2")
            return second
        })
        XCTAssertThrowsError(try failed.get())
        XCTAssertEqual(eventLog.events, [
            "build-1",
            "invalidate-1",
            "stop-1",
            "stopForReplacement-1",
        ])

        _ = try XCTUnwrap(submit(lane: lane, sequence: 3) {
            eventLog.append("build-3")
            return third
        }).get()
        XCTAssertEqual(eventLog.events, [
            "build-1",
            "invalidate-1",
            "stop-1",
            "stopForReplacement-1",
            "stopForReplacement-1",
            "build-3",
        ])
    }

    func testStaleSequenceDoesNotBuildOrReplaceTheCurrentLease() throws {
        let queue = DispatchQueue(label: "OrdinaryTmuxTerminalStreamLaneTests.stale")
        let lane = OrdinaryTmuxTerminalStreamLane(queue: queue)
        let eventLog = EventLog()
        let current = makeCandidate(token: 5, label: "5", eventLog: eventLog)
        let stale = makeCandidate(token: 4, label: "4", eventLog: eventLog)

        _ = try XCTUnwrap(submit(lane: lane, sequence: 5) {
            eventLog.append("build-5")
            return current
        }).get()
        XCTAssertTrue(current.lease.deliveryGate.accept {})
        let staleResult = submit(lane: lane, sequence: 4) {
            eventLog.append("build-4")
            return stale
        }

        XCTAssertNil(staleResult)
        XCTAssertEqual(eventLog.events, ["build-5"])
    }

    func testDeliveryGateRejectsAcceptanceAfterInvalidation() {
        let gate = TerminalStreamDeliveryGate()
        let eventLog = EventLog()

        gate.invalidate()

        XCTAssertFalse(gate.accept {
            eventLog.append("invalidated")
        })
        XCTAssertFalse(gate.allowsDelivery)
        XCTAssertEqual(eventLog.events, [])
    }

    func testDeliveryGateCallsAcceptedInvalidationExactlyOnce() {
        let gate = TerminalStreamDeliveryGate()
        let eventLog = EventLog()
        XCTAssertTrue(gate.accept {
            eventLog.append("invalidated")
        })

        gate.invalidate()
        gate.invalidate()

        XCTAssertFalse(gate.allowsDelivery)
        XCTAssertEqual(eventLog.events, ["invalidated"])
    }

    private func submit(lane: OrdinaryTmuxTerminalStreamLane,
                        sequence: UInt64,
                        build: @escaping @Sendable () throws -> OrdinaryTmuxTerminalStreamLaneCandidate,
                        file: StaticString = #filePath,
                        line: UInt = #line) -> Result<OrdinaryTmuxTerminalStreamLaneCandidate, Error>? {
        let completion = expectation(description: "lane completion for sequence \(sequence)")
        let box = CompletionBox()
        lane.submitSubscribe(sequence: sequence, build: build) { result in
            box.store(result)
            completion.fulfill()
        }
        wait(for: [completion], timeout: 1)
        guard let completed = box.result else {
            XCTFail("Lane did not record its completion", file: file, line: line)
            return nil
        }
        return completed
    }

    private func makeCandidate(token: UInt64,
                               label: String,
                               eventLog: EventLog,
                               releaseFailures: Int = 0,
                               replacementFailures: Int = 0) -> OrdinaryTmuxTerminalStreamLaneCandidate {
        let subscription = RecordingSubscription(route: route(),
                                                 label: label,
                                                 eventLog: eventLog,
                                                 releaseFailures: releaseFailures,
                                                 replacementFailures: replacementFailures)
        return OrdinaryTmuxTerminalStreamLaneCandidate(
            response: BridgeResponse(id: "subscribe-\(label)", ok: true, result: nil, error: nil),
            lease: OrdinaryTmuxTerminalStreamLease(token: token,
                                                   subscription: subscription,
                                                   deliveryGate: TerminalStreamDeliveryGate())
        )
    }

    private func drain(_ queue: DispatchQueue) {
        let drained = expectation(description: "lane queue drained")
        queue.async {
            drained.fulfill()
        }
        wait(for: [drained], timeout: 1)
    }

    private func route() -> OrdinaryTmuxPanelRoute {
        OrdinaryTmuxPanelRoute(workspaceID: "workspace-1",
                               panelID: "ordinary-tmux:/tmp/tmux-501/default:$7:@16",
                               carrierPanelID: "carrier-panel",
                               socket: .path("/tmp/tmux-501/default"),
                               sessionID: "$7",
                               sessionName: "tidey-codex",
                               windowID: "@16",
                               windowIndex: 1,
                               activePaneID: "%16",
                               cwd: "/Users/timfeng/GitHub/Tidey",
                               currentCommand: "codex")
    }
}
