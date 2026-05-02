import XCTest
@testable import RemoteBridge

final class OrdinaryTmuxCLIAdapterTests: XCTestCase {
    private final class RunnerState: @unchecked Sendable {
        struct Call: Equatable {
            let socket: OrdinaryTmuxSocketSelector
            let arguments: [String]
            let stdin: String?
        }

        private let lock = NSLock()
        private var responses: [String: String]
        private(set) var calls = [Call]()

        init(responses: [String: String]) {
            self.responses = responses
        }

        func run(socket: OrdinaryTmuxSocketSelector, arguments: [String], stdin: String?) throws -> String {
            lock.lock()
            defer { lock.unlock() }
            calls.append(Call(socket: socket, arguments: arguments, stdin: stdin))
            let key = Self.key(socket: socket, arguments: arguments, stdin: stdin)
            return responses[key] ?? ""
        }

        static func key(socket: OrdinaryTmuxSocketSelector, arguments: [String], stdin: String? = nil) -> String {
            "\(socket.cacheKey)::\(arguments.joined(separator: " "))::\(stdin ?? "")"
        }
    }

    func testArgumentsUseDefaultSocketWhenNoSelectorIsKnown() {
        XCTAssertEqual(
            OrdinaryTmuxCLIAdapter.arguments(for: .defaultSocket, commandArguments: ["list-clients"]),
            ["list-clients"]
        )
    }

    func testArgumentsUseSocketPathWhenKnown() {
        XCTAssertEqual(
            OrdinaryTmuxCLIAdapter.arguments(for: .path("/tmp/tmux-501/default"), commandArguments: ["list-clients"]),
            ["-S", "/tmp/tmux-501/default", "list-clients"]
        )
    }

    func testArgumentsUseSocketNameWhenKnown() {
        XCTAssertEqual(
            OrdinaryTmuxCLIAdapter.arguments(for: .name("work"), commandArguments: ["list-clients"]),
            ["-L", "work", "list-clients"]
        )
    }

    func testResolvesClientByTTYAndTargetSessionFromDefaultSocket() throws {
        let state = RunnerState(responses: [
            RunnerState.key(socket: .defaultSocket, arguments: listClientsArguments):
                "/dev/ttys001\t/tmp/tmux-501/default\t$4\tother\t@1\n" +
                "/dev/ttys010\t/tmp/tmux-501/default\t$7\tgenesis-extraction\t@15\n",
        ])
        let adapter = makeAdapter(state: state)

        let client = try adapter.resolveClient(
            for: OrdinaryTmuxAttachMetadata(clientTTY: "/dev/ttys010", targetSession: "genesis-extraction")
        )

        XCTAssertEqual(client, OrdinaryTmuxClient(clientTTY: "/dev/ttys010",
                                                 socketPath: "/tmp/tmux-501/default",
                                                 sessionID: "$7",
                                                 sessionName: "genesis-extraction",
                                                 currentWindowID: "@15"))
    }

    func testTargetSessionCanMatchSessionID() throws {
        let state = RunnerState(responses: [
            RunnerState.key(socket: .defaultSocket, arguments: listClientsArguments):
                "/dev/ttys010\t/tmp/tmux-501/default\t$7\tgenesis-extraction\t@15\n",
        ])
        let adapter = makeAdapter(state: state)

        let client = try adapter.resolveClient(
            for: OrdinaryTmuxAttachMetadata(clientTTY: "/dev/ttys010", targetSession: "$7")
        )

        XCTAssertEqual(client?.sessionName, "genesis-extraction")
    }

    func testReturnsNilWhenNoClientTTYMatches() throws {
        let state = RunnerState(responses: [
            RunnerState.key(socket: .defaultSocket, arguments: listClientsArguments):
                "/dev/ttys001\t/tmp/tmux-501/default\t$7\tgenesis-extraction\t@15\n",
        ])
        let adapter = makeAdapter(state: state)

        let client = try adapter.resolveClient(
            for: OrdinaryTmuxAttachMetadata(clientTTY: "/dev/ttys010", targetSession: "genesis-extraction")
        )

        XCTAssertNil(client)
    }

    func testProjectsEachTmuxWindowAsStableRemotePanel() throws {
        let state = RunnerState(responses: [
            RunnerState.key(socket: .defaultSocket, arguments: listClientsArguments):
                "/dev/ttys010\t/tmp/tmux-501/default\t$7\tgenesis-extraction\t@15\n",
            RunnerState.key(socket: .path("/tmp/tmux-501/default"), arguments: listWindowsArguments):
                "@15\t0\tpriest\n@16\t1\tmother_nature\n@17\t2\tpeon_001\n",
            RunnerState.key(socket: .path("/tmp/tmux-501/default"), arguments: listPanesArguments(windowID: "@15")):
                "%15\t1\t/Users/timfeng/GitHub/priest\tclaude\n",
            RunnerState.key(socket: .path("/tmp/tmux-501/default"), arguments: listPanesArguments(windowID: "@16")):
                "%16\t1\t/Users/timfeng/GitHub/mother_nature\tcodex\n",
            RunnerState.key(socket: .path("/tmp/tmux-501/default"), arguments: listPanesArguments(windowID: "@17")):
                "%17\t1\t/Users/timfeng/GitHub/peon_001\tzsh\n",
        ])
        let adapter = makeAdapter(state: state)

        let panels = try adapter.projectedPanels(
            for: OrdinaryTmuxAttachMetadata(clientTTY: "/dev/ttys010", targetSession: "genesis-extraction")
        )

        XCTAssertEqual(panels.map(\.title), ["priest", "mother_nature", "peon_001"])
        XCTAssertEqual(panels.map(\.windowIndex), [0, 1, 2])
        XCTAssertEqual(panels.map(\.activePaneID), ["%15", "%16", "%17"])
        XCTAssertEqual(
            panels.map(\.panelID),
            [
                "ordinary-tmux:/tmp/tmux-501/default:$7:@15",
                "ordinary-tmux:/tmp/tmux-501/default:$7:@16",
                "ordinary-tmux:/tmp/tmux-501/default:$7:@17",
            ]
        )
    }

    func testChoosesActivePaneWhenWindowHasSplits() throws {
        let state = RunnerState(responses: [
            RunnerState.key(socket: .defaultSocket, arguments: listClientsArguments):
                "/dev/ttys010\t/tmp/tmux-501/default\t$7\tgenesis-extraction\t@15\n",
            RunnerState.key(socket: .path("/tmp/tmux-501/default"), arguments: listWindowsArguments):
                "@16\t1\tmother_nature\n",
            RunnerState.key(socket: .path("/tmp/tmux-501/default"), arguments: listPanesArguments(windowID: "@16")):
                "%20\t0\t/tmp\tzsh\n%21\t1\t/Users/timfeng/GitHub/mother_nature\tcodex\n",
        ])
        let adapter = makeAdapter(state: state)

        let panels = try adapter.projectedPanels(
            for: OrdinaryTmuxAttachMetadata(clientTTY: "/dev/ttys010", targetSession: "genesis-extraction")
        )

        XCTAssertEqual(panels.first?.activePaneID, "%21")
        XCTAssertEqual(panels.first?.cwd, "/Users/timfeng/GitHub/mother_nature")
    }

    func testProjectionThrowsWhenAnyWindowPaneLookupFails() throws {
        let state = RunnerState(responses: [
            RunnerState.key(socket: .defaultSocket, arguments: listClientsArguments):
                "/dev/ttys010\t/tmp/tmux-501/default\t$7\tgenesis-extraction\t@15\n",
            RunnerState.key(socket: .path("/tmp/tmux-501/default"), arguments: listWindowsArguments):
                "@15\t0\tpriest\n@16\t1\tmother_nature\n",
            RunnerState.key(socket: .path("/tmp/tmux-501/default"), arguments: listPanesArguments(windowID: "@15")):
                "%15\t1\t/Users/timfeng/GitHub/priest\tclaude\n",
        ])
        let adapter = makeAdapter(state: state)

        XCTAssertThrowsError(try adapter.projectedPanels(
            for: OrdinaryTmuxAttachMetadata(clientTTY: "/dev/ttys010", targetSession: "genesis-extraction")
        )) { error in
            XCTAssertEqual(error as? OrdinaryTmuxProjectionError,
                           .partialWindowProjection(windowID: "@16"))
        }
    }

    private var listClientsArguments: [String] {
        [
            "list-clients",
            "-F",
            "#{client_tty}\t#{socket_path}\t#{session_id}\t#{session_name}\t#{client_window}",
        ]
    }

    private var listWindowsArguments: [String] {
        [
            "list-windows",
            "-t",
            "$7",
            "-F",
            "#{window_id}\t#{window_index}\t#{window_name}",
        ]
    }

    private func listPanesArguments(windowID: String) -> [String] {
        [
            "list-panes",
            "-t",
            windowID,
            "-F",
            "#{pane_id}\t#{pane_active}\t#{pane_current_path}\t#{pane_current_command}",
        ]
    }

    private func makeAdapter(state: RunnerState) -> OrdinaryTmuxCLIAdapter {
        OrdinaryTmuxCLIAdapter { socket, arguments, stdin in
            try state.run(socket: socket, arguments: arguments, stdin: stdin)
        }
    }
}
