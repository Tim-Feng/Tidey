import XCTest
@testable import RemoteBridge

final class TmuxStateResolverTests: XCTestCase {
    private final class LockedState: @unchecked Sendable {
        private let lock = NSLock()
        private var runnerCalls = 0
        private var paneOutputs: [String]

        init(paneOutputs: [String]) {
            self.paneOutputs = paneOutputs
        }

        func nextPanesOutput() -> String {
            lock.lock()
            defer { lock.unlock() }
            if paneOutputs.isEmpty {
                return ""
            }
            return paneOutputs.removeFirst()
        }

        func setPanesOutput(_ output: String) {
            lock.lock()
            paneOutputs = [output]
            lock.unlock()
        }

        func incrementRunnerCalls() {
            lock.lock()
            runnerCalls += 1
            lock.unlock()
        }

        var callCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return runnerCalls
        }
    }

    func testResolvesPaneToClientPIDsAcrossSharedSession() {
        let resolver = makeResolver(
            panesOutput: "%1\tdev\n%2\tprod\n",
            clientsOutput: "111\tdev\n222\tdev\n333\tprod\n"
        )

        XCTAssertEqual(resolver.clientPIDs(forPaneID: "%1", socketPath: "/tmp/tmux.sock"), [111, 222])
        XCTAssertEqual(resolver.clientPIDs(forPaneID: "%2", socketPath: "/tmp/tmux.sock"), [333])
    }

    func testMissForcesRefreshBeforeTtlExpires() {
        let state = LockedState(paneOutputs: ["%1\tdev\n", "%1\tdev\n%2\tprod\n"])
        let resolver = TmuxStateResolver(ttl: 60) { _, arguments in
            state.incrementRunnerCalls()
            if arguments.first == "list-panes" {
                return state.nextPanesOutput()
            }
            return "111\tdev\n333\tprod\n"
        }

        XCTAssertEqual(resolver.clientPIDs(forPaneID: "%1", socketPath: "/tmp/tmux.sock"), [111])
        XCTAssertEqual(resolver.clientPIDs(forPaneID: "%2", socketPath: "/tmp/tmux.sock"), [333])
        XCTAssertEqual(state.callCount, 4)
    }

    func testCachedSnapshotPreventsRepeatedTmuxQueriesWithinTtl() {
        let state = LockedState(paneOutputs: ["%1\tdev\n"])
        let resolver = TmuxStateResolver(ttl: 60) { _, arguments in
            state.incrementRunnerCalls()
            if arguments.first == "list-panes" {
                return "%1\tdev\n"
            }
            return "111\tdev\n"
        }

        XCTAssertEqual(resolver.clientPIDs(forPaneID: "%1", socketPath: "/tmp/tmux.sock"), [111])
        XCTAssertEqual(resolver.clientPIDs(forPaneID: "%1", socketPath: "/tmp/tmux.sock"), [111])
        XCTAssertEqual(state.callCount, 2)
    }

    func testInvalidateClearsSocketSpecificCache() {
        let state = LockedState(paneOutputs: ["%1\tdev\n"])
        let resolver = TmuxStateResolver(ttl: 60) { _, arguments in
            if arguments.first == "list-panes" {
                state.incrementRunnerCalls()
                return state.nextPanesOutput()
            }
            state.incrementRunnerCalls()
            return "111\tdev\n"
        }

        XCTAssertEqual(resolver.clientPIDs(forPaneID: "%1", socketPath: "/tmp/tmux.sock"), [111])
        state.setPanesOutput("%2\tdev\n")
        resolver.invalidate(socketPath: "/tmp/tmux.sock")
        XCTAssertNil(resolver.clientPIDs(forPaneID: "%1", socketPath: "/tmp/tmux.sock"))
    }

    private func makeResolver(panesOutput: String,
                              clientsOutput: String) -> TmuxStateResolver {
        TmuxStateResolver(ttl: 60) { _, arguments in
            if arguments.first == "list-panes" {
                return panesOutput
            }
            return clientsOutput
        }
    }
}
