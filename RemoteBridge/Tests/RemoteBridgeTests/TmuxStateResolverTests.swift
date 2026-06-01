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

    private final class CommandLog: @unchecked Sendable {
        private let lock = NSLock()
        private var calls = [[String]]()

        func append(_ arguments: [String]) {
            lock.lock()
            calls.append(arguments)
            lock.unlock()
        }

        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return calls.count
        }
    }

    func testResolvesPaneToClientPIDsAcrossSharedSession() {
        let resolver = makeResolver(
            panesOutput: "%1|dev\n%2|prod\n",
            clientsOutput: "111|dev\n222|dev\n333|prod\n"
        )

        XCTAssertEqual(resolver.clientPIDs(forPaneID: "%1", socketPath: "/tmp/tmux.sock"), [111, 222])
        XCTAssertEqual(resolver.clientPIDs(forPaneID: "%2", socketPath: "/tmp/tmux.sock"), [333])
    }

    func testMissForcesRefreshBeforeTtlExpires() {
        let state = LockedState(paneOutputs: ["%1|dev\n", "%1|dev\n%2|prod\n"])
        let resolver = TmuxStateResolver(ttl: 60) { _, arguments in
            state.incrementRunnerCalls()
            if arguments.first == "list-panes" {
                return state.nextPanesOutput()
            }
            return "111|dev\n333|prod\n"
        }

        XCTAssertEqual(resolver.clientPIDs(forPaneID: "%1", socketPath: "/tmp/tmux.sock"), [111])
        XCTAssertEqual(resolver.clientPIDs(forPaneID: "%2", socketPath: "/tmp/tmux.sock"), [333])
        XCTAssertEqual(state.callCount, 4)
    }

    func testCachedSnapshotPreventsRepeatedTmuxQueriesWithinTtl() {
        let state = LockedState(paneOutputs: ["%1|dev\n"])
        let resolver = TmuxStateResolver(ttl: 60) { _, arguments in
            state.incrementRunnerCalls()
            if arguments.first == "list-panes" {
                return "%1|dev\n"
            }
            return "111|dev\n"
        }

        XCTAssertEqual(resolver.clientPIDs(forPaneID: "%1", socketPath: "/tmp/tmux.sock"), [111])
        XCTAssertEqual(resolver.clientPIDs(forPaneID: "%1", socketPath: "/tmp/tmux.sock"), [111])
        XCTAssertEqual(state.callCount, 2)
    }

    func testInvalidateClearsSocketSpecificCache() {
        let state = LockedState(paneOutputs: ["%1|dev\n"])
        let resolver = TmuxStateResolver(ttl: 60) { _, arguments in
            if arguments.first == "list-panes" {
                state.incrementRunnerCalls()
                return state.nextPanesOutput()
            }
            state.incrementRunnerCalls()
            return "111|dev\n"
        }

        XCTAssertEqual(resolver.clientPIDs(forPaneID: "%1", socketPath: "/tmp/tmux.sock"), [111])
        state.setPanesOutput("%2|dev\n")
        resolver.invalidate(socketPath: "/tmp/tmux.sock")
        XCTAssertNil(resolver.clientPIDs(forPaneID: "%1", socketPath: "/tmp/tmux.sock"))
    }

    func testPipeSeparatedSessionNamePreservesAdditionalPipes() {
        let resolver = makeResolver(
            panesOutput: "%1|dev|feature\n",
            clientsOutput: "111|dev|feature\n"
        )

        XCTAssertEqual(resolver.clientPIDs(forPaneID: "%1", socketPath: "/tmp/tmux.sock"), [111])
    }

    func testUnderscoreSanitizedSeparatorDoesNotMisparse() {
        let resolver = makeResolver(
            panesOutput: "%1_dev\n",
            clientsOutput: "111_dev\n"
        )

        XCTAssertNil(resolver.clientPIDs(forPaneID: "%1", socketPath: "/tmp/tmux.sock"))
    }

    func testPaneIdentityReadsWorkspaceAndPanelOptions() {
        let calls = CommandLog()
        let resolver = TmuxStateResolver(ttl: 60) { socketPath, arguments in
            calls.append(arguments)
            XCTAssertEqual(socketPath, "/tmp/tmux.sock")
            XCTAssertEqual(arguments, ["list-panes", "-a", "-F", "#{pane_id}|#{@tidey_workspace_id}|#{@tidey_panel_id}"])
            return "%1|workspace-1|panel-1\n%2||\n"
        }

        XCTAssertEqual(resolver.paneIdentity(forPaneID: "%1", socketPath: "/tmp/tmux.sock"),
                       TmuxPaneIdentity(workspaceID: "workspace-1", panelID: "panel-1"))
        XCTAssertEqual(calls.count, 1)
    }

    func testPaneIdentityReturnsNilWhenOptionsAreMissing() {
        let calls = CommandLog()
        let resolver = TmuxStateResolver(ttl: 60) { _, arguments in
            calls.append(arguments)
            XCTAssertEqual(arguments, ["list-panes", "-a", "-F", "#{pane_id}|#{@tidey_workspace_id}|#{@tidey_panel_id}"])
            return "%1|workspace-1|\n%2||panel-2\n"
        }

        XCTAssertNil(resolver.paneIdentity(forPaneID: "%1", socketPath: "/tmp/tmux.sock"))
        XCTAssertNil(resolver.paneIdentity(forPaneID: "%2", socketPath: "/tmp/tmux.sock"))
        XCTAssertEqual(calls.count, 1)
    }

    func testPaneIdentityCachesMissingPaneWithinTTL() {
        let calls = CommandLog()
        let resolver = TmuxStateResolver(ttl: 60) { _, arguments in
            calls.append(arguments)
            XCTAssertEqual(arguments, ["list-panes", "-a", "-F", "#{pane_id}|#{@tidey_workspace_id}|#{@tidey_panel_id}"])
            return "%1|workspace-1|panel-1\n%2||\n"
        }

        XCTAssertNil(resolver.paneIdentity(forPaneID: "%2", socketPath: "/tmp/tmux.sock"))
        XCTAssertNil(resolver.paneIdentity(forPaneID: "%2", socketPath: "/tmp/tmux.sock"))
        XCTAssertEqual(calls.count, 1)
    }

    func testDiscoverTmuxBinaryPathPrefersFirstExecutableCandidate() throws {
        let fileManager = FileManager.default
        let tempDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("tmux-discovery-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempDirectory) }

        let first = tempDirectory.appendingPathComponent("tmux-first")
        let second = tempDirectory.appendingPathComponent("tmux-second")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: second)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: second.path)

        XCTAssertEqual(TmuxStateResolver.discoverTmuxBinaryPath(candidates: [first.path, second.path]), second.path)

        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: first)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: first.path)

        XCTAssertEqual(TmuxStateResolver.discoverTmuxBinaryPath(candidates: [first.path, second.path]), first.path)
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
