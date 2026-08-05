import XCTest
@testable import RemoteBridge

final class OrdinaryTmuxCLIAdapterTests: XCTestCase {
    private final class ConcurrentRunnerOutcome: @unchecked Sendable {
        private let lock = NSLock()
        private var failures = [String]()

        func recordFailure(_ failure: String) {
            lock.lock()
            failures.append(failure)
            lock.unlock()
        }

        var recordedFailures: [String] {
            lock.lock()
            defer { lock.unlock() }
            return failures
        }
    }

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

    func testProcessRunnerCompletesConcurrentShortLivedCommandsWithoutFalseTimeouts() {
        let runner = OrdinaryTmuxCLIAdapter.processCommandRunner(executablePath: "/bin/echo",
                                                                 timeoutSeconds: 1)
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "OrdinaryTmuxCLIAdapterTests.concurrent-processes",
                                  attributes: .concurrent)
        let outcome = ConcurrentRunnerOutcome()

        for index in 0..<32 {
            group.enter()
            queue.async {
                defer { group.leave() }
                do {
                    let output = try runner(.defaultSocket, ["probe-\(index)"], nil)
                    if output != "probe-\(index)" {
                        outcome.recordFailure("unexpected output for \(index): \(output)")
                    }
                } catch {
                    outcome.recordFailure("command \(index) failed: \(error)")
                }
            }
        }

        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(outcome.recordedFailures, [])
    }

    func testProcessRunnerPreservesStdinAndTimeoutSemantics() throws {
        let catRunner = OrdinaryTmuxCLIAdapter.processCommandRunner(executablePath: "/bin/cat",
                                                                    timeoutSeconds: 1)
        XCTAssertEqual(try catRunner(.defaultSocket, [], "hello from stdin\n"), "hello from stdin")

        let sleepRunner = OrdinaryTmuxCLIAdapter.processCommandRunner(executablePath: "/bin/sleep",
                                                                      timeoutSeconds: 0.05)
        XCTAssertThrowsError(try sleepRunner(.defaultSocket, ["2"], nil)) { error in
            let nsError = error as NSError
            XCTAssertEqual(nsError.domain, "OrdinaryTmuxCLIAdapter")
            XCTAssertEqual(nsError.code, 124)
        }
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

    func testResolvesClientWhenTmuxOmitsTrailingCurrentWindowField() throws {
        let state = RunnerState(responses: [
            RunnerState.key(socket: .defaultSocket, arguments: listClientsArguments):
                "/dev/ttys000\t/private/tmp/tmux-501/default\t$6\ttidey-cc\t\n" +
                "/dev/ttys005\t/private/tmp/tmux-501/default\t$24\tgenesis-extraction\n",
        ])
        let adapter = makeAdapter(state: state)

        let client = try adapter.resolveClient(
            for: OrdinaryTmuxAttachMetadata(clientTTY: "/dev/ttys005", targetSession: "genesis-extraction")
        )

        XCTAssertEqual(client, OrdinaryTmuxClient(clientTTY: "/dev/ttys005",
                                                 socketPath: "/private/tmp/tmux-501/default",
                                                 sessionID: "$24",
                                                 sessionName: "genesis-extraction",
                                                 currentWindowID: nil))
    }

    func testResolvesClientWhenCurrentWindowFieldIsPresent() throws {
        let state = RunnerState(responses: [
            RunnerState.key(socket: .defaultSocket, arguments: listClientsArguments):
                "/dev/ttys005\t/private/tmp/tmux-501/default\t$24\tgenesis-extraction\t@36\n",
        ])
        let adapter = makeAdapter(state: state)

        let client = try adapter.resolveClient(
            for: OrdinaryTmuxAttachMetadata(clientTTY: "/dev/ttys005", targetSession: "genesis-extraction")
        )

        XCTAssertEqual(client?.currentWindowID, "@36")
        XCTAssertEqual(client?.sessionName, "genesis-extraction")
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
                "%15\t1\t1015\t/Users/timfeng/GitHub/priest\tclaude\n",
            RunnerState.key(socket: .path("/tmp/tmux-501/default"), arguments: listPanesArguments(windowID: "@16")):
                "%16\t1\t1016\t/Users/timfeng/GitHub/mother_nature\tcodex\n",
            RunnerState.key(socket: .path("/tmp/tmux-501/default"), arguments: listPanesArguments(windowID: "@17")):
                "%17\t1\t1017\t/Users/timfeng/GitHub/peon_001\tzsh\n",
        ])
        let adapter = makeAdapter(state: state)

        let panels = try adapter.projectedPanels(
            for: OrdinaryTmuxAttachMetadata(clientTTY: "/dev/ttys010", targetSession: "genesis-extraction")
        )

        XCTAssertEqual(panels.map(\.title), ["priest", "mother_nature", "peon_001"])
        XCTAssertEqual(panels.map(\.windowIndex), [0, 1, 2])
        XCTAssertEqual(panels.map(\.activePaneID), ["%15", "%16", "%17"])
        XCTAssertEqual(panels.map(\.activePanePID), [1015, 1016, 1017])
        XCTAssertEqual(
            panels.map(\.panelID),
            [
                "ordinary-tmux:/tmp/tmux-501/default:$7:@15",
                "ordinary-tmux:/tmp/tmux-501/default:$7:@16",
                "ordinary-tmux:/tmp/tmux-501/default:$7:@17",
            ]
        )
    }

    func testProjectsWindowsWhenClientLineOmitsTrailingCurrentWindowField() throws {
        let state = RunnerState(responses: [
            RunnerState.key(socket: .defaultSocket, arguments: listClientsArguments):
                "/dev/ttys005\t/private/tmp/tmux-501/default\t$24\tgenesis-extraction\n",
            RunnerState.key(socket: .path("/private/tmp/tmux-501/default"), arguments: listWindowsArguments(sessionID: "$24")):
                "@36\t0\tpriest\n@37\t1\tmother_nature\n@38\t2\tpeon_001\n",
            RunnerState.key(socket: .path("/private/tmp/tmux-501/default"), arguments: listPanesArguments(windowID: "@36")):
                "%36\t1\t2036\t/Users/timfeng/GitHub/priest\tclaude\n",
            RunnerState.key(socket: .path("/private/tmp/tmux-501/default"), arguments: listPanesArguments(windowID: "@37")):
                "%37\t1\t2037\t/Users/timfeng/GitHub/mother_nature\tcodex\n",
            RunnerState.key(socket: .path("/private/tmp/tmux-501/default"), arguments: listPanesArguments(windowID: "@38")):
                "%38\t1\t2038\t/Users/timfeng/GitHub/peon_001\tzsh\n",
        ])
        let adapter = makeAdapter(state: state)

        let panels = try adapter.projectedPanels(
            for: OrdinaryTmuxAttachMetadata(clientTTY: "/dev/ttys005", targetSession: "genesis-extraction")
        )

        XCTAssertEqual(panels.map(\.title), ["priest", "mother_nature", "peon_001"])
        XCTAssertEqual(panels.map(\.panelID), [
            "ordinary-tmux:/private/tmp/tmux-501/default:$24:@36",
            "ordinary-tmux:/private/tmp/tmux-501/default:$24:@37",
            "ordinary-tmux:/private/tmp/tmux-501/default:$24:@38",
        ])
    }

    func testProjectionUsesLargestWindowPolicyWhileAnotherSizingClientIsAttached() throws {
        let socket = OrdinaryTmuxSocketSelector.path("/tmp/tmux-501/default")
        let state = RunnerState(responses: [
            RunnerState.key(socket: .defaultSocket, arguments: listClientsArguments):
                "/dev/ttys010\t/tmp/tmux-501/default\t$7\tgenesis-extraction\t@15\tattached,focused,UTF-8\n" +
                "/dev/ttys099\t/tmp/tmux-501/default\t$7\tgenesis-extraction\t@15\tattached,UTF-8\n",
            RunnerState.key(socket: socket, arguments: listWindowsArguments):
                "@15\t0\tpriest\tlatest\t\n",
            RunnerState.key(socket: socket, arguments: listPanesArguments(windowID: "@15")):
                "%15\t1\t1015\t/Users/timfeng/GitHub/priest\tclaude\n",
        ])
        let adapter = makeAdapter(state: state)

        _ = try adapter.projectedPanels(
            for: OrdinaryTmuxAttachMetadata(clientTTY: "/dev/ttys010", targetSession: "genesis-extraction")
        )

        XCTAssertEqual(
            state.calls.filter { $0.arguments.first == "set-option" },
            [
                .init(socket: socket,
                      arguments: setWindowOptionArguments(windowID: "@15",
                                                          option: "@tidey_window_size_before_multi_client",
                                                          value: "latest"),
                      stdin: nil),
                .init(socket: socket,
                      arguments: setWindowOptionArguments(windowID: "@15",
                                                          option: "window-size",
                                                          value: "largest"),
                      stdin: nil),
            ]
        )
    }

    func testProjectionClaimsLargestWindowPolicyBeforeAnotherClientAttaches() throws {
        let socket = OrdinaryTmuxSocketSelector.path("/tmp/tmux-501/default")
        let state = RunnerState(responses: [
            RunnerState.key(socket: .defaultSocket, arguments: listClientsArguments):
                "/dev/ttys010\t/tmp/tmux-501/default\t$7\tgenesis-extraction\t@15\tattached,focused,UTF-8\n",
            RunnerState.key(socket: socket, arguments: listWindowsArguments):
                "@15\t0\tpriest\tlatest\n",
            RunnerState.key(socket: socket, arguments: listPanesArguments(windowID: "@15")):
                "%15\t1\t1015\t/Users/timfeng/GitHub/priest\tclaude\n",
        ])
        let adapter = makeAdapter(state: state)

        _ = try adapter.projectedPanels(
            for: OrdinaryTmuxAttachMetadata(clientTTY: "/dev/ttys010", targetSession: "genesis-extraction")
        )

        XCTAssertEqual(
            state.calls.filter { $0.arguments.first == "set-option" },
            [
                .init(socket: socket,
                      arguments: setWindowOptionArguments(windowID: "@15",
                                                          option: "@tidey_window_size_before_multi_client",
                                                          value: "latest"),
                      stdin: nil),
                .init(socket: socket,
                      arguments: setWindowOptionArguments(windowID: "@15",
                                                          option: "window-size",
                                                          value: "largest"),
                      stdin: nil),
            ]
        )
    }

    func testProjectionKeepsOwnedWindowPolicyAfterOtherSizingClientsDetach() throws {
        let socket = OrdinaryTmuxSocketSelector.path("/tmp/tmux-501/default")
        let state = RunnerState(responses: [
            RunnerState.key(socket: .defaultSocket, arguments: listClientsArguments):
                "/dev/ttys010\t/tmp/tmux-501/default\t$7\tgenesis-extraction\t@15\tattached,focused,UTF-8\n",
            RunnerState.key(socket: socket, arguments: listWindowsArguments):
                "@15\t0\tpriest\tlargest\tlatest\n",
            RunnerState.key(socket: socket, arguments: listPanesArguments(windowID: "@15")):
                "%15\t1\t1015\t/Users/timfeng/GitHub/priest\tclaude\n",
        ])
        let adapter = makeAdapter(state: state)

        _ = try adapter.projectedPanels(
            for: OrdinaryTmuxAttachMetadata(clientTTY: "/dev/ttys010", targetSession: "genesis-extraction")
        )

        XCTAssertFalse(state.calls.contains { $0.arguments.first == "set-option" })
    }

    func testProjectionClaimsWindowPolicyEvenWhenOtherClientsIgnoreSize() throws {
        let socket = OrdinaryTmuxSocketSelector.path("/tmp/tmux-501/default")
        let state = RunnerState(responses: [
            RunnerState.key(socket: .defaultSocket, arguments: listClientsArguments):
                "/dev/ttys010\t/tmp/tmux-501/default\t$7\tgenesis-extraction\t@15\tattached,focused,UTF-8\n" +
                "/dev/ttys099\t/tmp/tmux-501/default\t$7\tgenesis-extraction\t@15\tattached,ignore-size,UTF-8\n",
            RunnerState.key(socket: socket, arguments: listWindowsArguments):
                "@15\t0\tpriest\tlatest\t\n",
            RunnerState.key(socket: socket, arguments: listPanesArguments(windowID: "@15")):
                "%15\t1\t1015\t/Users/timfeng/GitHub/priest\tclaude\n",
        ])
        let adapter = makeAdapter(state: state)

        _ = try adapter.projectedPanels(
            for: OrdinaryTmuxAttachMetadata(clientTTY: "/dev/ttys010", targetSession: "genesis-extraction")
        )

        XCTAssertEqual(
            state.calls.filter { $0.arguments.first == "set-option" },
            [
                .init(socket: socket,
                      arguments: setWindowOptionArguments(windowID: "@15",
                                                          option: "@tidey_window_size_before_multi_client",
                                                          value: "latest"),
                      stdin: nil),
                .init(socket: socket,
                      arguments: setWindowOptionArguments(windowID: "@15",
                                                          option: "window-size",
                                                          value: "largest"),
                      stdin: nil),
            ]
        )
    }

    func testProjectionDoesNotClaimPolicyWhenCarrierClientIgnoresSize() throws {
        let socket = OrdinaryTmuxSocketSelector.path("/tmp/tmux-501/default")
        let state = RunnerState(responses: [
            RunnerState.key(socket: .defaultSocket, arguments: listClientsArguments):
                "/dev/ttys010\t/tmp/tmux-501/default\t$7\tgenesis-extraction\t@15\tattached,focused,ignore-size,UTF-8\n" +
                "/dev/ttys099\t/tmp/tmux-501/default\t$8\tother-session\t@20\tattached,UTF-8\n",
            RunnerState.key(socket: socket, arguments: listWindowsArguments):
                "@15\t0\tpriest\tlatest\t\n",
            RunnerState.key(socket: socket, arguments: listPanesArguments(windowID: "@15")):
                "%15\t1\t1015\t/Users/timfeng/GitHub/priest\tclaude\n",
        ])
        let adapter = makeAdapter(state: state)

        _ = try adapter.projectedPanels(
            for: OrdinaryTmuxAttachMetadata(clientTTY: "/dev/ttys010", targetSession: "genesis-extraction")
        )

        XCTAssertFalse(state.calls.contains { $0.arguments.first == "set-option" })
    }

    func testProjectionPreservesExplicitWindowPolicy() throws {
        let socket = OrdinaryTmuxSocketSelector.path("/tmp/tmux-501/default")
        let state = RunnerState(responses: [
            RunnerState.key(socket: .defaultSocket, arguments: listClientsArguments):
                "/dev/ttys010\t/tmp/tmux-501/default\t$7\tgenesis-extraction\t@15\tattached,focused,UTF-8\n" +
                "/dev/ttys099\t/tmp/tmux-501/default\t$7\tgenesis-extraction\t@15\tattached,UTF-8\n",
            RunnerState.key(socket: socket, arguments: listWindowsArguments):
                "@15\t0\tpriest\tmanual\tlatest\n",
            RunnerState.key(socket: socket, arguments: listPanesArguments(windowID: "@15")):
                "%15\t1\t1015\t/Users/timfeng/GitHub/priest\tclaude\n",
        ])
        let adapter = makeAdapter(state: state)

        _ = try adapter.projectedPanels(
            for: OrdinaryTmuxAttachMetadata(clientTTY: "/dev/ttys010", targetSession: "genesis-extraction")
        )

        XCTAssertEqual(
            state.calls.filter { $0.arguments.first == "set-option" },
            [
                .init(socket: socket,
                      arguments: unsetWindowOptionArguments(windowID: "@15",
                                                            option: "@tidey_window_size_before_multi_client"),
                      stdin: nil),
            ]
        )
    }

    func testProjectionCompletesInterruptedPolicyTransition() throws {
        let socket = OrdinaryTmuxSocketSelector.path("/tmp/tmux-501/default")
        let state = RunnerState(responses: [
            RunnerState.key(socket: .defaultSocket, arguments: listClientsArguments):
                "/dev/ttys010\t/tmp/tmux-501/default\t$7\tgenesis-extraction\t@15\tattached,focused,UTF-8\n" +
                "/dev/ttys099\t/tmp/tmux-501/default\t$7\tgenesis-extraction\t@15\tattached,UTF-8\n",
            RunnerState.key(socket: socket, arguments: listWindowsArguments):
                "@15\t0\tpriest\tlatest\tlatest\n",
            RunnerState.key(socket: socket, arguments: listPanesArguments(windowID: "@15")):
                "%15\t1\t1015\t/Users/timfeng/GitHub/priest\tclaude\n",
        ])
        let adapter = makeAdapter(state: state)

        _ = try adapter.projectedPanels(
            for: OrdinaryTmuxAttachMetadata(clientTTY: "/dev/ttys010", targetSession: "genesis-extraction")
        )

        XCTAssertEqual(
            state.calls.filter { $0.arguments.first == "set-option" },
            [
                .init(socket: socket,
                      arguments: setWindowOptionArguments(windowID: "@15",
                                                          option: "window-size",
                                                          value: "largest"),
                      stdin: nil),
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
                "%20\t0\t1020\t/tmp\tzsh\n%21\t1\t1021\t/Users/timfeng/GitHub/mother_nature\tcodex\n",
        ])
        let adapter = makeAdapter(state: state)

        let panels = try adapter.projectedPanels(
            for: OrdinaryTmuxAttachMetadata(clientTTY: "/dev/ttys010", targetSession: "genesis-extraction")
        )

        XCTAssertEqual(panels.first?.activePaneID, "%21")
        XCTAssertEqual(panels.first?.activePanePID, 1021)
        XCTAssertEqual(panels.first?.cwd, "/Users/timfeng/GitHub/mother_nature")
    }

    func testProjectionThrowsWhenAnyWindowPaneLookupFails() throws {
        let state = RunnerState(responses: [
            RunnerState.key(socket: .defaultSocket, arguments: listClientsArguments):
                "/dev/ttys010\t/tmp/tmux-501/default\t$7\tgenesis-extraction\t@15\n",
            RunnerState.key(socket: .path("/tmp/tmux-501/default"), arguments: listWindowsArguments):
                "@15\t0\tpriest\n@16\t1\tmother_nature\n",
            RunnerState.key(socket: .path("/tmp/tmux-501/default"), arguments: listPanesArguments(windowID: "@15")):
                "%15\t1\t1015\t/Users/timfeng/GitHub/priest\tclaude\n",
        ])
        let adapter = makeAdapter(state: state)

        XCTAssertThrowsError(try adapter.projectedPanels(
            for: OrdinaryTmuxAttachMetadata(clientTTY: "/dev/ttys010", targetSession: "genesis-extraction")
        )) { error in
            XCTAssertEqual(error as? OrdinaryTmuxProjectionError,
                           .partialWindowProjection(windowID: "@16"))
        }
    }

    func testStartPipePaneUsesActivePaneAndShellQuotesOutputPath() throws {
        let socket = OrdinaryTmuxSocketSelector.path("/tmp/tmux-501/default")
        let route = makeRoute(socket: socket)
        let state = RunnerState(responses: [
            RunnerState.key(socket: socket, arguments: windowExistsArguments):
                "@15\n",
            RunnerState.key(socket: socket, arguments: listPanesArguments(windowID: "@15")):
                "%20\t0\t1020\t/tmp\tzsh\n%21\t1\t1021\t/Users/timfeng/GitHub/work\tcodex\n",
            RunnerState.key(socket: socket,
                            arguments: ["pipe-pane", "-o", "-t", "%21", "cat >> '/tmp/tidey stream/it'\\''s.bytes'"]):
                "",
        ])
        let adapter = makeAdapter(state: state)

        let refreshed = try adapter.startPipePane(route: route, outputFilePath: "/tmp/tidey stream/it's.bytes")

        XCTAssertEqual(refreshed.activePaneID, "%21")
        XCTAssertEqual(state.calls.map(\.arguments), [
            windowExistsArguments,
            listPanesArguments(windowID: "@15"),
            ["pipe-pane", "-o", "-t", "%21", "cat >> '/tmp/tidey stream/it'\\''s.bytes'"],
        ])
    }

    func testStopPipePaneUsesActivePane() throws {
        let socket = OrdinaryTmuxSocketSelector.path("/tmp/tmux-501/default")
        let route = makeRoute(socket: socket)
        let state = RunnerState(responses: [
            RunnerState.key(socket: socket, arguments: windowExistsArguments):
                "@15\n",
            RunnerState.key(socket: socket, arguments: listPanesArguments(windowID: "@15")):
                "%21\t1\t1021\t/Users/timfeng/GitHub/work\tcodex\n",
            RunnerState.key(socket: socket, arguments: ["pipe-pane", "-t", "%21"]):
                "",
        ])
        let adapter = makeAdapter(state: state)

        try adapter.stopPipePane(route: route)

        XCTAssertEqual(state.calls.map(\.arguments), [
            windowExistsArguments,
            listPanesArguments(windowID: "@15"),
            ["pipe-pane", "-t", "%21"],
        ])
    }

    func testQueryCursorPositionParsesColumnRowAndVisibility() throws {
        let socket = OrdinaryTmuxSocketSelector.path("/tmp/tmux-501/default")
        let route = makeRoute(socket: socket)
        let state = RunnerState(responses: [
            RunnerState.key(socket: socket, arguments: windowExistsArguments):
                "@15\n",
            RunnerState.key(socket: socket, arguments: listPanesArguments(windowID: "@15")):
                "%21\t1\t1021\t/Users/timfeng/GitHub/work\tcodex\n",
            RunnerState.key(socket: socket,
                            arguments: ["display-message", "-p", "-t", "%21", "#{cursor_x} #{cursor_y} #{cursor_flag}"]):
                "42 7 0",
        ])
        let adapter = makeAdapter(state: state)

        let position = try adapter.queryCursorPosition(route: route)

        XCTAssertEqual(position, OrdinaryTmuxCursorPosition(row: 7, column: 42, cursorVisible: false))
    }

    func testCaptureOutputIncludesCursorState() throws {
        let socket = OrdinaryTmuxSocketSelector.path("/tmp/tmux-501/default")
        let route = makeRoute(socket: socket)
        let state = RunnerState(responses: [
            RunnerState.key(socket: socket, arguments: windowExistsArguments):
                "@15\n",
            RunnerState.key(socket: socket, arguments: listPanesArguments(windowID: "@15")):
                "%21\t1\t1021\t/Users/timfeng/GitHub/work\tcodex\n",
            RunnerState.key(socket: socket,
                            arguments: ["capture-pane", "-p", "-J", "-S", "-50", "-t", "%21"]):
                "hello\nworld",
            RunnerState.key(socket: socket,
                            arguments: ["display-message", "-p", "-t", "%21", "#{cursor_x} #{cursor_y} #{cursor_flag}"]):
                "11 4 1",
        ])
        let adapter = makeAdapter(state: state)

        let captured = try adapter.captureOutput(route: route, maxLines: 50)

        XCTAssertEqual(captured,
                       OrdinaryTmuxCapturedOutput(output: "hello\nworld",
                                                  cursorRow: 4,
                                                  cursorColumn: 11,
                                                  cursorVisible: true))
    }

    func testCaptureOutputKeepsOutputWhenCursorQueryFails() throws {
        let socket = OrdinaryTmuxSocketSelector.path("/tmp/tmux-501/default")
        let route = makeRoute(socket: socket)
        let state = RunnerState(responses: [
            RunnerState.key(socket: socket, arguments: windowExistsArguments):
                "@15\n",
            RunnerState.key(socket: socket, arguments: listPanesArguments(windowID: "@15")):
                "%21\t1\t1021\t/Users/timfeng/GitHub/work\tcodex\n",
            RunnerState.key(socket: socket,
                            arguments: ["capture-pane", "-p", "-J", "-S", "-50", "-t", "%21"]):
                "still available",
        ])
        let adapter = OrdinaryTmuxCLIAdapter { socket, arguments, stdin in
            if arguments.first == "display-message" {
                throw NSError(domain: "test-cursor-query", code: 1)
            }
            return try state.run(socket: socket, arguments: arguments, stdin: stdin)
        }

        let captured = try adapter.captureOutput(route: route, maxLines: 50)

        XCTAssertEqual(captured,
                       OrdinaryTmuxCapturedOutput(output: "still available",
                                                  cursorRow: nil,
                                                  cursorColumn: nil,
                                                  cursorVisible: nil))
    }

    private var listClientsArguments: [String] {
        [
            "list-clients",
            "-F",
            "#{client_tty}\t#{socket_path}\t#{session_id}\t#{session_name}\t#{client_window}\t#{client_flags}",
        ]
    }

    private var listWindowsArguments: [String] {
        listWindowsArguments(sessionID: "$7")
    }

    private var windowExistsArguments: [String] {
        [
            "list-windows",
            "-t",
            "$7",
            "-F",
            "#{window_id}",
        ]
    }

    private func listWindowsArguments(sessionID: String) -> [String] {
        [
            "list-windows",
            "-t",
            sessionID,
            "-F",
            "#{window_id}\t#{window_index}\t#{window_name}\t#{window-size}\t#{@tidey_window_size_before_multi_client}",
        ]
    }

    private func setWindowOptionArguments(windowID: String,
                                          option: String,
                                          value: String) -> [String] {
        ["set-option", "-w", "-t", windowID, option, value]
    }

    private func unsetWindowOptionArguments(windowID: String,
                                            option: String) -> [String] {
        ["set-option", "-u", "-w", "-t", windowID, option]
    }

    private func listPanesArguments(windowID: String) -> [String] {
        [
            "list-panes",
            "-t",
            windowID,
            "-F",
            "#{pane_id}\t#{pane_active}\t#{pane_pid}\t#{pane_current_path}\t#{pane_current_command}",
        ]
    }

    private func makeAdapter(state: RunnerState) -> OrdinaryTmuxCLIAdapter {
        OrdinaryTmuxCLIAdapter { socket, arguments, stdin in
            try state.run(socket: socket, arguments: arguments, stdin: stdin)
        }
    }

    private func makeRoute(socket: OrdinaryTmuxSocketSelector) -> OrdinaryTmuxPanelRoute {
        OrdinaryTmuxPanelRoute(workspaceID: "workspace-1",
                               panelID: "ordinary-tmux:/tmp/tmux-501/default:$7:@15",
                               carrierPanelID: "carrier-1",
                               socket: socket,
                               sessionID: "$7",
                               sessionName: "work",
                               windowID: "@15",
                               windowIndex: 0,
                               activePaneID: "%old",
                               cwd: "/Users/timfeng/GitHub/work",
                               currentCommand: "codex")
    }
}
