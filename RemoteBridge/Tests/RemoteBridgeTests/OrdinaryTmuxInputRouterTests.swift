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
        private var responses: [String: [Result<String, Error>]]
        private(set) var calls = [Call]()

        init(responses: [String: String]) {
            self.responses = responses.mapValues { [.success($0)] }
        }

        init(scriptedResponses: [String: [Result<String, Error>]]) {
            self.responses = scriptedResponses
        }

        func run(socket: OrdinaryTmuxSocketSelector, arguments: [String], stdin: String?) throws -> String {
            lock.lock()
            defer { lock.unlock() }
            calls.append(Call(socket: socket, arguments: arguments, stdin: stdin))
            let key = Self.key(socket: socket, arguments: arguments, stdin: stdin)
            guard var results = responses[key],
                  results.isEmpty == false else {
                return ""
            }
            let result = results.removeFirst()
            responses[key] = results
            switch result {
            case .success(let output):
                return output
            case .failure(let error):
                throw error
            }
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
                                             arguments: ["send-keys", "-t", "%21", "Enter"],
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

    func testPaneIdentityTimeoutDoesNotAbortPasteInput() throws {
        let registry = OrdinaryTmuxPanelRegistry()
        let route = ordinaryRoute()
        registry.replaceRoutes(workspaceID: "workspace-1", routes: [route])
        let state = RunnerState(scriptedResponses: [
            RunnerState.key(socket: route.socket, arguments: listPanesArguments(windowID: route.windowID)): [
                .success("%21\t1\t1021\t/Users/timfeng/GitHub/mother_nature\tcodex\n"),
            ],
            RunnerState.key(socket: route.socket,
                            arguments: ["set-option", "-p", "-t", "%21", "@tidey_panel_id", route.panelID]): [
                .failure(tmuxTimeoutError()),
            ],
            RunnerState.key(socket: route.socket,
                            arguments: ["load-buffer", "-b", "ignored", "-"],
                            stdin: "hello"): [
                .success(""),
            ],
        ])
        let router = OrdinaryTmuxInputRouter(registry: registry,
                                             adapter: adapter(state: state))

        XCTAssertTrue(try router.sendInput("hello", toPanelID: route.panelID))

        XCTAssertEqual(state.calls.map(\.arguments.first), [
            "list-panes",
            "set-option",
            "set-option",
            "load-buffer",
            "paste-buffer",
        ])
    }

    func testPasteBufferTimeoutWithVerifiedPaneEchoKeepsInputAliveForEnter() throws {
        let registry = OrdinaryTmuxPanelRegistry()
        let route = ordinaryRoute()
        registry.replaceRoutes(workspaceID: "workspace-1", routes: [route])
        let state = RunnerState(scriptedResponses: [
            RunnerState.key(socket: route.socket, arguments: listPanesArguments(windowID: route.windowID)): [
                .success("%21\t1\t1021\t/Users/timfeng/GitHub/mother_nature\tclaude\n"),
            ],
            RunnerState.key(socket: route.socket,
                            arguments: ["load-buffer", "-b", "ignored", "-"],
                            stdin: "hello from remote"): [
                .success(""),
            ],
            RunnerState.key(socket: route.socket,
                            arguments: ["paste-buffer", "-d", "-b", "ignored", "-t", "%21"]): [
                .failure(tmuxTimeoutError()),
            ],
            RunnerState.key(socket: route.socket,
                            arguments: capturePaneArguments(paneID: "%21")): [
                .success("Claude prompt\nhello from remote"),
            ],
        ])
        let router = OrdinaryTmuxInputRouter(registry: registry,
                                             adapter: adapter(state: state))

        XCTAssertTrue(try router.sendInput("hello from remote", toPanelID: route.panelID))
        XCTAssertTrue(try router.sendInput("\r", toPanelID: route.panelID))

        XCTAssertTrue(state.calls.contains {
            $0.arguments == capturePaneArguments(paneID: "%21")
        })
        XCTAssertEqual(state.calls.last, .init(socket: route.socket,
                                               arguments: ["send-keys", "-t", "%21", "Enter"],
                                               stdin: nil))
    }

    func testPasteBufferTimeoutWithMultilineChineseFileReferenceEchoIsVerified() throws {
        let registry = OrdinaryTmuxPanelRegistry()
        let route = ordinaryRoute()
        registry.replaceRoutes(workspaceID: "workspace-1", routes: [route])
        let input = "@/Users/timfeng/Library/Application Support/Tidey Remote Bridge/uploads/20260514-223130-96f6efaa.jpg\r\n\r\n這是測試 B 項"
        let state = RunnerState(scriptedResponses: [
            RunnerState.key(socket: route.socket, arguments: listPanesArguments(windowID: route.windowID)): [
                .success("%21\t1\t1021\t/Users/timfeng/GitHub/mother_nature\tclaude\n"),
            ],
            RunnerState.key(socket: route.socket,
                            arguments: ["load-buffer", "-b", "ignored", "-"],
                            stdin: input): [
                .success(""),
            ],
            RunnerState.key(socket: route.socket,
                            arguments: ["paste-buffer", "-d", "-b", "ignored", "-t", "%21"]): [
                .failure(tmuxTimeoutError()),
            ],
            RunnerState.key(socket: route.socket,
                            arguments: capturePaneArguments(paneID: "%21")): [
                .success("@/Users/timfeng/Library/Application Support/Tidey Remote Bridge/uploads/20260514-223130-96f6efaa.jpg\n\n這是測試 B 項"),
            ],
        ])
        let router = OrdinaryTmuxInputRouter(registry: registry,
                                             adapter: adapter(state: state))

        XCTAssertTrue(try router.sendInput(input, toPanelID: route.panelID))
        XCTAssertTrue(try router.sendInput("\r", toPanelID: route.panelID))
        XCTAssertEqual(state.calls.last?.arguments, ["send-keys", "-t", "%21", "Enter"])
    }

    func testPasteBufferTimeoutWithoutPaneEchoThrowsAndDoesNotRecordEnterFallback() throws {
        let registry = OrdinaryTmuxPanelRegistry()
        let route = ordinaryRoute()
        registry.replaceRoutes(workspaceID: "workspace-1", routes: [route])
        let state = RunnerState(scriptedResponses: [
            RunnerState.key(socket: route.socket, arguments: listPanesArguments(windowID: route.windowID)): [
                .success("%21\t1\t1021\t/Users/timfeng/GitHub/mother_nature\tclaude\n"),
            ],
            RunnerState.key(socket: route.socket,
                            arguments: ["load-buffer", "-b", "ignored", "-"],
                            stdin: "hello from remote"): [
                .success(""),
            ],
            RunnerState.key(socket: route.socket,
                            arguments: ["paste-buffer", "-d", "-b", "ignored", "-t", "%21"]): [
                .failure(tmuxTimeoutError()),
            ],
            RunnerState.key(socket: route.socket,
                            arguments: capturePaneArguments(paneID: "%21")): [
                .success("Claude prompt"),
            ],
        ])
        let router = OrdinaryTmuxInputRouter(registry: registry,
                                             adapter: adapter(state: state))

        XCTAssertThrowsError(try router.sendInput("hello from remote", toPanelID: route.panelID)) { error in
            XCTAssertEqual((error as NSError).domain, "OrdinaryTmuxCLIAdapter")
            XCTAssertEqual((error as NSError).code, 124)
        }
        XCTAssertThrowsError(try router.sendInput("\r", toPanelID: route.panelID))
        XCTAssertFalse(state.calls.contains { $0.arguments.first == "send-keys" })
    }

    func testPasteBufferTimeoutWithCaptureTimeoutThrows() throws {
        let registry = OrdinaryTmuxPanelRegistry()
        let route = ordinaryRoute()
        registry.replaceRoutes(workspaceID: "workspace-1", routes: [route])
        let state = RunnerState(scriptedResponses: [
            RunnerState.key(socket: route.socket, arguments: listPanesArguments(windowID: route.windowID)): [
                .success("%21\t1\t1021\t/Users/timfeng/GitHub/mother_nature\tclaude\n"),
            ],
            RunnerState.key(socket: route.socket,
                            arguments: ["load-buffer", "-b", "ignored", "-"],
                            stdin: "hello from remote"): [
                .success(""),
            ],
            RunnerState.key(socket: route.socket,
                            arguments: ["paste-buffer", "-d", "-b", "ignored", "-t", "%21"]): [
                .failure(tmuxTimeoutError()),
            ],
            RunnerState.key(socket: route.socket,
                            arguments: capturePaneArguments(paneID: "%21")): [
                .failure(tmuxTimeoutError()),
            ],
        ])
        let router = OrdinaryTmuxInputRouter(registry: registry,
                                             adapter: adapter(state: state))

        XCTAssertThrowsError(try router.sendInput("hello from remote", toPanelID: route.panelID)) { error in
            XCTAssertEqual((error as NSError).domain, "OrdinaryTmuxCLIAdapter")
            XCTAssertEqual((error as NSError).code, 124)
        }
        XCTAssertFalse(state.calls.contains { $0.arguments.first == "send-keys" })
    }

    func testPasteBufferNonTimeoutErrorDoesNotVerify() throws {
        let registry = OrdinaryTmuxPanelRegistry()
        let route = ordinaryRoute()
        registry.replaceRoutes(workspaceID: "workspace-1", routes: [route])
        let state = RunnerState(scriptedResponses: [
            RunnerState.key(socket: route.socket, arguments: listPanesArguments(windowID: route.windowID)): [
                .success("%21\t1\t1021\t/Users/timfeng/GitHub/mother_nature\tclaude\n"),
            ],
            RunnerState.key(socket: route.socket,
                            arguments: ["load-buffer", "-b", "ignored", "-"],
                            stdin: "hello from remote"): [
                .success(""),
            ],
            RunnerState.key(socket: route.socket,
                            arguments: ["paste-buffer", "-d", "-b", "ignored", "-t", "%21"]): [
                .failure(NSError(domain: "OrdinaryTmuxCLIAdapter",
                                  code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "can't find pane: %21"])),
            ],
        ])
        let router = OrdinaryTmuxInputRouter(registry: registry,
                                             adapter: adapter(state: state))

        XCTAssertThrowsError(try router.sendInput("hello from remote", toPanelID: route.panelID)) { error in
            XCTAssertEqual((error as NSError).domain, "OrdinaryTmuxCLIAdapter")
            XCTAssertEqual((error as NSError).code, 1)
        }
        XCTAssertFalse(state.calls.contains { $0.arguments.first == "capture-pane" })
    }

    func testSuccessfulPasteBufferDoesNotVerifyPaneEcho() throws {
        let registry = OrdinaryTmuxPanelRegistry()
        let route = ordinaryRoute()
        registry.replaceRoutes(workspaceID: "workspace-1", routes: [route])
        let state = RunnerState(scriptedResponses: [
            RunnerState.key(socket: route.socket, arguments: listPanesArguments(windowID: route.windowID)): [
                .success("%21\t1\t1021\t/Users/timfeng/GitHub/mother_nature\tclaude\n"),
            ],
            RunnerState.key(socket: route.socket,
                            arguments: ["load-buffer", "-b", "ignored", "-"],
                            stdin: "hello from remote"): [
                .success(""),
            ],
            RunnerState.key(socket: route.socket,
                            arguments: ["paste-buffer", "-d", "-b", "ignored", "-t", "%21"]): [
                .success(""),
            ],
        ])
        let router = OrdinaryTmuxInputRouter(registry: registry,
                                             adapter: adapter(state: state))

        XCTAssertTrue(try router.sendInput("hello from remote", toPanelID: route.panelID))
        XCTAssertFalse(state.calls.contains { $0.arguments.first == "capture-pane" })
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

    func testEnterOnlyUsesLastPastePaneWithoutActivePaneQuery() throws {
        let registry = OrdinaryTmuxPanelRegistry()
        let route = ordinaryRoute()
        registry.replaceRoutes(workspaceID: "workspace-1", routes: [route])
        let listPanesKey = RunnerState.key(socket: route.socket, arguments: listPanesArguments(windowID: route.windowID))
        let state = RunnerState(scriptedResponses: [
            listPanesKey: [
                .success("%21\t1\t1021\t/Users/timfeng/GitHub/mother_nature\tcodex\n"),
            ],
            RunnerState.key(socket: route.socket,
                            arguments: ["load-buffer", "-b", "ignored", "-"],
                            stdin: "hello"): [
                .success(""),
            ],
        ])
        let router = OrdinaryTmuxInputRouter(registry: registry,
                                             adapter: adapter(state: state))

        XCTAssertTrue(try router.sendInput("hello", toPanelID: route.panelID))
        XCTAssertTrue(try router.sendInput("\r", toPanelID: route.panelID))

        XCTAssertEqual(state.calls.map(\.arguments.first), [
            "list-panes",
            "set-option",
            "set-option",
            "load-buffer",
            "paste-buffer",
            "send-keys",
        ])
        XCTAssertEqual(state.calls.last, .init(socket: route.socket,
                                               arguments: ["send-keys", "-t", "%21", "Enter"],
                                               stdin: nil))
    }

    func testEnterOnlyFailsWhenLastPastePaneIsGone() throws {
        let registry = OrdinaryTmuxPanelRegistry()
        let route = ordinaryRoute()
        registry.replaceRoutes(workspaceID: "workspace-1", routes: [route])
        let listPanesKey = RunnerState.key(socket: route.socket, arguments: listPanesArguments(windowID: route.windowID))
        let state = RunnerState(scriptedResponses: [
            listPanesKey: [
                .success("%21\t1\t1021\t/Users/timfeng/GitHub/mother_nature\tcodex\n"),
            ],
            RunnerState.key(socket: route.socket,
                            arguments: ["load-buffer", "-b", "ignored", "-"],
                            stdin: "hello"): [
                .success(""),
            ],
            RunnerState.key(socket: route.socket,
                            arguments: ["send-keys", "-t", "%21", "Enter"]): [
                .failure(NSError(domain: "OrdinaryTmuxCLIAdapter",
                                  code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "can't find pane: %21"])),
            ],
        ])
        let router = OrdinaryTmuxInputRouter(registry: registry,
                                             adapter: adapter(state: state))

        XCTAssertTrue(try router.sendInput("hello", toPanelID: route.panelID))
        XCTAssertThrowsError(try router.sendInput("\r", toPanelID: route.panelID)) { error in
            XCTAssertEqual((error as NSError).domain, "OrdinaryTmuxCLIAdapter")
            XCTAssertEqual((error as NSError).code, 1)
        }
        XCTAssertEqual(state.calls.last?.arguments, ["send-keys", "-t", "%21", "Enter"])
    }

    func testNonEnterInputDoesNotFallbackWhenActivePaneQueryTimesOut() throws {
        let registry = OrdinaryTmuxPanelRegistry()
        let route = ordinaryRoute()
        registry.replaceRoutes(workspaceID: "workspace-1", routes: [route])
        let state = RunnerState(scriptedResponses: [
            RunnerState.key(socket: route.socket, arguments: listPanesArguments(windowID: route.windowID)): [
                .failure(tmuxTimeoutError()),
            ],
        ])
        let router = OrdinaryTmuxInputRouter(registry: registry,
                                             adapter: adapter(state: state))

        XCTAssertThrowsError(try router.sendInput("hello", toPanelID: route.panelID)) { error in
            XCTAssertEqual((error as NSError).domain, "OrdinaryTmuxCLIAdapter")
            XCTAssertEqual((error as NSError).code, 124)
        }
        XCTAssertFalse(state.calls.contains { $0.arguments.first == "send-keys" })
    }

    func testLaterPasteOverridesEarlierFallbackPane() throws {
        let registry = OrdinaryTmuxPanelRegistry()
        let route = ordinaryRoute()
        registry.replaceRoutes(workspaceID: "workspace-1", routes: [route])
        let listPanesKey = RunnerState.key(socket: route.socket, arguments: listPanesArguments(windowID: route.windowID))
        let state = RunnerState(scriptedResponses: [
            listPanesKey: [
                .success("%21\t1\t1021\t/Users/timfeng/GitHub/mother_nature\tcodex\n"),
                .success("%22\t1\t1022\t/Users/timfeng/GitHub/mother_nature\tcodex\n"),
            ],
            RunnerState.key(socket: route.socket,
                            arguments: ["load-buffer", "-b", "ignored", "-"],
                            stdin: "first"): [
                .success(""),
            ],
            RunnerState.key(socket: route.socket,
                            arguments: ["load-buffer", "-b", "ignored", "-"],
                            stdin: "second"): [
                .success(""),
            ],
        ])
        let router = OrdinaryTmuxInputRouter(registry: registry,
                                             adapter: adapter(state: state))

        XCTAssertTrue(try router.sendInput("first", toPanelID: route.panelID))
        XCTAssertTrue(try router.sendInput("\r", toPanelID: route.panelID))
        XCTAssertTrue(try router.sendInput("second", toPanelID: route.panelID))
        XCTAssertTrue(try router.sendInput("\r", toPanelID: route.panelID))

        let sendKeyCalls = state.calls.filter { $0.arguments.first == "send-keys" }
        XCTAssertEqual(sendKeyCalls.map(\.arguments), [
            ["send-keys", "-t", "%21", "Enter"],
            ["send-keys", "-t", "%22", "Enter"],
        ])
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

    private func capturePaneArguments(paneID: String) -> [String] {
        ["capture-pane", "-p", "-J", "-S", "-20", "-t", paneID]
    }

    private func adapter(state: RunnerState) -> OrdinaryTmuxCLIAdapter {
        OrdinaryTmuxCLIAdapter { socket, arguments, stdin in
            if arguments.first == "load-buffer" {
                return try state.run(socket: socket,
                                     arguments: ["load-buffer", "-b", "ignored", "-"],
                                     stdin: stdin)
            }
            if arguments.first == "paste-buffer" {
                return try state.run(socket: socket,
                                     arguments: ["paste-buffer", "-d", "-b", "ignored", "-t", arguments.last ?? ""],
                                     stdin: stdin)
            }
            return try state.run(socket: socket, arguments: arguments, stdin: stdin)
        }
    }

    private func tmuxTimeoutError() -> NSError {
        NSError(domain: "OrdinaryTmuxCLIAdapter",
                code: 124,
                userInfo: [NSLocalizedDescriptionKey: "tmux command timed out"])
    }
}
