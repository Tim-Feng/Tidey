import XCTest
@testable import RemoteBridge

final class OrdinaryTmuxInputRouterTests: XCTestCase {
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
            return responses[Self.key(socket: socket, arguments: arguments, stdin: stdin)] ?? ""
        }

        static func key(socket: OrdinaryTmuxSocketSelector, arguments: [String], stdin: String? = nil) -> String {
            "\(socket.cacheKey)::\(arguments.joined(separator: " "))::\(stdin ?? "")"
        }
    }

    func testRoutesLogicalPanelInputThroughTmuxPasteAndEnter() throws {
        let registry = OrdinaryTmuxPanelRegistry()
        let route = ordinaryRoute()
        registry.replaceRoutes(workspaceID: "workspace-1", routes: [route])
        let state = RunnerState(responses: [
            RunnerState.key(socket: route.socket, arguments: listPanesArguments(windowID: route.windowID)):
                "%20\t0\t1020\t/tmp\tzsh\n%21\t1\t1021\t/Users/timfeng/GitHub/mother_nature\tcodex\n",
            RunnerState.key(socket: route.socket,
                            arguments: ["load-buffer", "-b", "ignored", "-"],
                            stdin: "hello"):
                "",
        ])
        let adapter = OrdinaryTmuxCLIAdapter { socket, arguments, stdin in
            if arguments.first == "load-buffer" {
                return try state.run(socket: socket,
                                     arguments: ["load-buffer", "-b", "ignored", "-"],
                                     stdin: stdin)
            }
            return try state.run(socket: socket, arguments: arguments, stdin: stdin)
        }
        let router = OrdinaryTmuxInputRouter(registry: registry, adapter: adapter)

        XCTAssertTrue(try router.sendInput("hello\r", toPanelID: route.panelID))

        XCTAssertEqual(state.calls.count, 6)
        XCTAssertEqual(state.calls[0], .init(socket: route.socket,
                                             arguments: listPanesArguments(windowID: route.windowID),
                                             stdin: nil))
        XCTAssertEqual(state.calls[1], .init(socket: route.socket,
                                             arguments: ["set-option", "-p", "-t", "%21", "@tidey_workspace_id", "workspace-1"],
                                             stdin: nil))
        XCTAssertEqual(state.calls[2], .init(socket: route.socket,
                                             arguments: ["set-option", "-p", "-t", "%21", "@tidey_panel_id", route.panelID],
                                             stdin: nil))
        XCTAssertEqual(state.calls[3].arguments, ["load-buffer", "-b", "ignored", "-"])
        XCTAssertEqual(state.calls[3].stdin, "hello")
        XCTAssertEqual(state.calls[4], .init(socket: route.socket,
                                             arguments: ["paste-buffer", "-d", "-b", state.calls[4].arguments[3], "-t", "%21"],
                                             stdin: nil))
        XCTAssertEqual(state.calls[5], .init(socket: route.socket,
                                             arguments: ["send-keys", "-t", "%21", "C-m"],
                                             stdin: nil))
    }

    func testPlainInputDoesNotSendEnter() throws {
        let registry = OrdinaryTmuxPanelRegistry()
        let route = ordinaryRoute()
        registry.replaceRoutes(workspaceID: "workspace-1", routes: [route])
        let state = RunnerState(responses: [
            RunnerState.key(socket: route.socket, arguments: listPanesArguments(windowID: route.windowID)):
                "%21\t1\t1021\t/Users/timfeng/GitHub/mother_nature\tcodex\n",
            RunnerState.key(socket: route.socket,
                            arguments: ["load-buffer", "-b", "ignored", "-"],
                            stdin: "hello"):
                "",
        ])
        let adapter = OrdinaryTmuxCLIAdapter { socket, arguments, stdin in
            if arguments.first == "load-buffer" {
                return try state.run(socket: socket,
                                     arguments: ["load-buffer", "-b", "ignored", "-"],
                                     stdin: stdin)
            }
            return try state.run(socket: socket, arguments: arguments, stdin: stdin)
        }
        let router = OrdinaryTmuxInputRouter(registry: registry, adapter: adapter)

        XCTAssertTrue(try router.sendInput("hello", toPanelID: route.panelID))

        XCTAssertEqual(state.calls.map { $0.arguments.first }, ["list-panes", "set-option", "set-option", "load-buffer", "paste-buffer"])
    }

    func testUnknownPanelFallsBackToMacSocketPath() throws {
        let registry = OrdinaryTmuxPanelRegistry()
        let router = OrdinaryTmuxInputRouter(registry: registry,
                                             adapter: OrdinaryTmuxCLIAdapter { _, _, _ in "" })

        XCTAssertFalse(try router.sendInput("hello", toPanelID: "native-panel"))
    }

    func testStaleWindowRouteThrowsNotFoundInsteadOfSendingWrongPane() throws {
        let registry = OrdinaryTmuxPanelRegistry()
        let route = ordinaryRoute()
        registry.replaceRoutes(workspaceID: "workspace-1", routes: [route])
        let state = RunnerState(responses: [
            RunnerState.key(socket: route.socket, arguments: listPanesArguments(windowID: route.windowID)):
                "",
        ])
        let router = OrdinaryTmuxInputRouter(registry: registry,
                                             adapter: OrdinaryTmuxCLIAdapter { socket, arguments, stdin in
                                                 try state.run(socket: socket, arguments: arguments, stdin: stdin)
                                             })

        XCTAssertThrowsError(try router.sendInput("hello", toPanelID: route.panelID)) { error in
            guard let bridgeError = error as? BridgeInternalError else {
                return XCTFail("expected BridgeInternalError")
            }
            XCTAssertEqual(bridgeError.payload.code, "not_found")
        }
    }

    private func ordinaryRoute() -> OrdinaryTmuxPanelRoute {
        OrdinaryTmuxPanelRoute(
            workspaceID: "workspace-1",
            panelID: "ordinary-tmux:/tmp/tmux-501/default:$7:@16",
            carrierPanelID: "carrier-panel",
            socket: .path("/tmp/tmux-501/default"),
            sessionID: "$7",
            sessionName: "genesis-extraction",
            windowID: "@16",
            windowIndex: 1,
            activePaneID: "%16",
            cwd: "/Users/timfeng/GitHub/mother_nature",
            currentCommand: "codex"
        )
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
}
