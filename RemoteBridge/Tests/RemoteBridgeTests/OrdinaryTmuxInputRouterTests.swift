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

        // Opt-in strictness: commands listed here MUST have a scripted
        // response — a key miss throws instead of silently succeeding, so
        // an argv drift can never produce a false green.
        var failOnUnscripted: Set<String> = []

        func run(socket: OrdinaryTmuxSocketSelector, arguments: [String], stdin: String?) throws -> String {
            lock.lock()
            defer { lock.unlock() }
            calls.append(Call(socket: socket, arguments: arguments, stdin: stdin))
            let key = Self.key(socket: socket, arguments: arguments, stdin: stdin)
            guard var results = responses[key],
                  results.isEmpty == false else {
                if let command = arguments.first, failOnUnscripted.contains(command) {
                    throw NSError(domain: "RunnerState",
                                  code: 999,
                                  userInfo: [NSLocalizedDescriptionKey: "unscripted strict command: \(key)"])
                }
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

    func testInputSubmissionStoreReservesOneOwnerPerRoute() {
        let store = OrdinaryTmuxInputSubmissionStore()

        XCTAssertTrue(store.reserve(submissionID: "submission-a", routeKey: "route-1"))
        XCTAssertTrue(store.isCurrent(submissionID: "submission-a", routeKey: "route-1"))
        XCTAssertFalse(store.reserve(submissionID: "submission-b", routeKey: "route-1"))
        XCTAssertTrue(store.reserve(submissionID: "submission-b", routeKey: "route-2"))

        store.release(submissionID: "submission-a", routeKey: "route-1")

        XCTAssertFalse(store.isCurrent(submissionID: "submission-a", routeKey: "route-1"))
        XCTAssertTrue(store.reserve(submissionID: "submission-b", routeKey: "route-1"))
    }

    func testSharedSubmissionStoreRejectsSecondRouterBeforeItPastesToTheSameRoute() throws {
        let registry = OrdinaryTmuxPanelRegistry()
        let route = ordinaryRoute()
        registry.replaceRoutes(workspaceID: route.workspaceID, routes: [route])
        let paneInventory = "%21\t1\t1021\t/Users/timfeng/GitHub/mother_nature\tclaude\n"
        let state = RunnerState(scriptedResponses: [
            RunnerState.key(
                socket: route.socket,
                arguments: listPanesArguments(windowID: route.windowID)
            ): [.success(paneInventory), .success(paneInventory)],
            RunnerState.key(
                socket: route.socket,
                arguments: ["load-buffer", "-b", "ignored", "-"],
                stdin: "/model"
            ): [.success(""), .success("")],
            RunnerState.key(
                socket: route.socket,
                arguments: ["paste-buffer", "-d", "-p", "-r", "-b", "ignored", "-t", "%21"]
            ): [.success(""), .success("")],
            RunnerState.key(
                socket: route.socket,
                arguments: ["send-keys", "-t", "%21", "Enter"]
            ): [.success("")],
        ])
        state.failOnUnscripted = ["load-buffer", "paste-buffer", "send-keys"]
        let sharedStore = OrdinaryTmuxInputSubmissionStore()
        let sharedAdapter = adapter(state: state)
        let firstRouter = OrdinaryTmuxInputRouter(
            registry: registry,
            adapter: sharedAdapter,
            inputSubmissionStore: sharedStore
        )
        let secondRouter = OrdinaryTmuxInputRouter(
            registry: registry,
            adapter: sharedAdapter,
            inputSubmissionStore: sharedStore
        )

        XCTAssertTrue(
            try firstRouter.sendInput(
                "/model",
                toPanelID: route.panelID,
                mode: .literalChatText,
                allowAmbiguousPasteTimeout: true,
                submissionID: "submission-a"
            )
        )
        XCTAssertThrowsError(
            try secondRouter.sendInput(
                "/model",
                toPanelID: route.panelID,
                mode: .literalChatText,
                allowAmbiguousPasteTimeout: true,
                submissionID: "submission-b"
            )
        ) { error in
            guard case BridgeInternalError.conflict = error else {
                return XCTFail("expected conflict, got \(error)")
            }
        }
        XCTAssertThrowsError(
            try secondRouter.sendInput(
                "\u{1b}",
                toPanelID: route.panelID,
                mode: .rawTerminalInput,
                allowAmbiguousPasteTimeout: false
            )
        ) { error in
            guard case BridgeInternalError.conflict = error else {
                return XCTFail("expected tokenless input conflict, got \(error)")
            }
        }

        XCTAssertEqual(state.calls.filter { $0.arguments.first == "load-buffer" }.count, 1)
        XCTAssertEqual(state.calls.filter { $0.arguments.first == "paste-buffer" }.count, 1)
        XCTAssertTrue(
            try firstRouter.sendInput(
                "\r",
                toPanelID: route.panelID,
                mode: .rawTerminalInput,
                allowAmbiguousPasteTimeout: true,
                submissionID: "submission-a"
            )
        )
        XCTAssertEqual(state.calls.filter { $0.arguments.first == "send-keys" }.count, 1)
    }

    func testPastePresentationDecisionRequiresExpectedTextOnCurrentCursorRow() {
        XCTAssertFalse(
            OrdinaryTmuxPastePresentationDecision.isReady(
                capture: OrdinaryTmuxCapturedOutput(
                    output: "❯ /model\n  Kept model as Fable 5\n❯ ",
                    cursorRow: 2,
                    cursorColumn: 2,
                    cursorVisible: true
                ),
                expectedText: "/model"
            ),
            "an old visible /model row must not authorize Enter"
        )
        XCTAssertTrue(
            OrdinaryTmuxPastePresentationDecision.isReady(
                capture: OrdinaryTmuxCapturedOutput(
                    output: "❯ old command\n\n❯ /model",
                    cursorRow: 2,
                    cursorColumn: 8,
                    cursorVisible: true
                ),
                expectedText: "/model"
            )
        )
        XCTAssertFalse(
            OrdinaryTmuxPastePresentationDecision.isReady(
                capture: OrdinaryTmuxCapturedOutput(
                    output: "❯ /help",
                    cursorRow: 0,
                    cursorColumn: 7,
                    cursorVisible: true
                ),
                expectedText: "/model"
            )
        )

        var probeResults = [false, true]
        var waitCount = 0
        let gate = OrdinaryTmuxPastePresentationGate(
            maximumAttempts: 3,
            waitBetweenAttempts: { waitCount += 1 }
        )
        XCTAssertTrue(
            gate.waitUntilReady {
                probeResults.removeFirst()
            }
        )
        XCTAssertEqual(waitCount, 1)
    }

    func testSetPaneIdentityAlsoProjectsSessionRuntimeIntoPaneOptions() throws {
        let route = ordinaryRoute()
        let state = RunnerState(responses: [:])
        let adapter = OrdinaryTmuxCLIAdapter { socket, arguments, stdin in
            try state.run(socket: socket, arguments: arguments, stdin: stdin)
        }

        try adapter.setPaneIdentity(route: route)

        XCTAssertEqual(state.calls, [
            .init(socket: route.socket,
                  arguments: ["set-option", "-p", "-t", route.activePaneID,
                              "@tidey_workspace_id", route.workspaceID],
                  stdin: nil),
            .init(socket: route.socket,
                  arguments: ["set-option", "-p", "-t", route.activePaneID,
                              "@tidey_panel_id", route.panelID],
                  stdin: nil),
            .init(socket: route.socket,
                  arguments: ["set-option", "-p", "-F", "-t", route.activePaneID,
                              "@tidey_socket_path", "#{E:TIDEY_SOCKET_PATH}"],
                  stdin: nil),
            .init(socket: route.socket,
                  arguments: ["set-option", "-p", "-F", "-t", route.activePaneID,
                              "@tidey_bin_dir", "#{E:TIDEY_BIN_DIR}"],
                  stdin: nil),
        ])
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

        XCTAssertTrue(try router.sendInput("hello", toPanelID: route.panelID, mode: .literalChatText))
        XCTAssertTrue(try router.sendInput("\r", toPanelID: route.panelID))

        XCTAssertEqual(state.calls.count, 8)
        XCTAssertEqual(state.calls[0], .init(socket: route.socket,
                                             arguments: listPanesArguments(windowID: route.windowID),
                                             stdin: nil))
        XCTAssertEqual(state.calls[1], .init(socket: route.socket,
                                             arguments: ["set-option", "-p", "-t", "%21", "@tidey_workspace_id", "workspace-1"],
                                             stdin: nil))
        XCTAssertEqual(state.calls[2], .init(socket: route.socket,
                                             arguments: ["set-option", "-p", "-t", "%21", "@tidey_panel_id", route.panelID],
                                             stdin: nil))
        XCTAssertEqual(state.calls[3].arguments,
                       ["set-option", "-p", "-F", "-t", "%21", "@tidey_socket_path", "#{E:TIDEY_SOCKET_PATH}"])
        XCTAssertEqual(state.calls[4].arguments,
                       ["set-option", "-p", "-F", "-t", "%21", "@tidey_bin_dir", "#{E:TIDEY_BIN_DIR}"])
        XCTAssertEqual(state.calls[5].arguments, ["load-buffer", "-b", "ignored", "-"])
        XCTAssertEqual(state.calls[5].stdin, "hello")
        XCTAssertEqual(state.calls[6], .init(socket: route.socket,
                                             arguments: ["paste-buffer", "-d", "-p", "-r", "-b", state.calls[6].arguments[5], "-t", "%21"],
                                             stdin: nil))
        XCTAssertEqual(state.calls[7], .init(socket: route.socket,
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

        XCTAssertEqual(state.calls.map { $0.arguments.first }, [
            "list-panes",
            "set-option",
            "set-option",
            "set-option",
            "set-option",
            "load-buffer",
            "paste-buffer",
        ])
    }

    func testLoadBufferTimeoutRetriesBeforePasteAndEnter() throws {
        let registry = OrdinaryTmuxPanelRegistry()
        let route = ordinaryRoute()
        registry.replaceRoutes(workspaceID: "workspace-1", routes: [route])
        let state = RunnerState(scriptedResponses: [
            RunnerState.key(socket: route.socket, arguments: listPanesArguments(windowID: route.windowID)): [
                .success("%21\t1\t1021\t/Users/timfeng/GitHub/mother_nature\tcodex\n"),
            ],
            RunnerState.key(socket: route.socket,
                            arguments: ["load-buffer", "-b", "ignored", "-"],
                            stdin: "hello"): [
                .failure(tmuxTimeoutError()),
                .success(""),
            ],
        ])
        let router = OrdinaryTmuxInputRouter(registry: registry,
                                             adapter: adapter(state: state))

        XCTAssertTrue(try router.sendInput("hello\r", toPanelID: route.panelID))

        let commandNames = state.calls.map { $0.arguments.first }
        XCTAssertEqual(commandNames, [
            "list-panes",
            "set-option",
            "set-option",
            "set-option",
            "set-option",
            "load-buffer",
            "load-buffer",
            "paste-buffer",
            "send-keys",
        ])
        let loadCalls = state.calls.filter { $0.arguments.first == "load-buffer" }
        XCTAssertEqual(loadCalls.count, 2)
        XCTAssertEqual(loadCalls.map(\.stdin), ["hello", "hello"])
        XCTAssertEqual(state.calls.last?.arguments, ["send-keys", "-t", "%21", "Enter"])
    }

    func testLoadBufferNonTimeoutErrorStillAbortsInput() throws {
        let registry = OrdinaryTmuxPanelRegistry()
        let route = ordinaryRoute()
        registry.replaceRoutes(workspaceID: "workspace-1", routes: [route])
        let nonTimeoutError = NSError(domain: "OrdinaryTmuxCLIAdapter",
                                      code: 2,
                                      userInfo: [NSLocalizedDescriptionKey: "tmux failed"])
        let state = RunnerState(scriptedResponses: [
            RunnerState.key(socket: route.socket, arguments: listPanesArguments(windowID: route.windowID)): [
                .success("%21\t1\t1021\t/Users/timfeng/GitHub/mother_nature\tcodex\n"),
            ],
            RunnerState.key(socket: route.socket,
                            arguments: ["load-buffer", "-b", "ignored", "-"],
                            stdin: "hello"): [
                .failure(nonTimeoutError),
            ],
        ])
        let router = OrdinaryTmuxInputRouter(registry: registry,
                                             adapter: adapter(state: state))

        XCTAssertThrowsError(try router.sendInput("hello\r", toPanelID: route.panelID)) { error in
            XCTAssertEqual((error as NSError).code, 2)
        }
        XCTAssertFalse(state.calls.contains { $0.arguments.first == "paste-buffer" })
        XCTAssertFalse(state.calls.contains { $0.arguments.first == "send-keys" })
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
                            arguments: ["paste-buffer", "-d", "-p", "-r", "-b", "ignored", "-t", "%21"]): [
                .failure(tmuxTimeoutError()),
            ],
            RunnerState.key(socket: route.socket,
                            arguments: capturePaneArguments(paneID: "%21")): [
                .success("Claude prompt\nhello from remote"),
            ],
        ])
        let router = OrdinaryTmuxInputRouter(registry: registry,
                                             adapter: adapter(state: state))

        XCTAssertTrue(try router.sendInput("hello from remote", toPanelID: route.panelID, mode: .literalChatText))
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
                            arguments: ["paste-buffer", "-d", "-p", "-r", "-b", "ignored", "-t", "%21"]): [
                .failure(tmuxTimeoutError()),
            ],
            RunnerState.key(socket: route.socket,
                            arguments: capturePaneArguments(paneID: "%21")): [
                .success("@/Users/timfeng/Library/Application Support/Tidey Remote Bridge/uploads/20260514-223130-96f6efaa.jpg\n\n這是測試 B 項"),
            ],
        ])
        let router = OrdinaryTmuxInputRouter(registry: registry,
                                             adapter: adapter(state: state))

        XCTAssertTrue(try router.sendInput(input, toPanelID: route.panelID, mode: .literalChatText))
        XCTAssertTrue(try router.sendInput("\r", toPanelID: route.panelID))
        XCTAssertEqual(state.calls.last?.arguments, ["send-keys", "-t", "%21", "Enter"])
        XCTAssertEqual(state.calls.filter { $0.arguments.first == "paste-buffer" }.map(\.arguments),
                       [["paste-buffer", "-d", "-p", "-r", "-b", "ignored", "-t", "%21"]],
                       "the CRLF message went through the REAL bracketed paste argv")
        XCTAssertEqual(state.calls.filter { $0.arguments.first == "capture-pane" }.map(\.arguments),
                       [capturePaneArguments(paneID: "%21")],
                       "the timeout verification actually captured the pane")
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
                            arguments: ["paste-buffer", "-d", "-p", "-r", "-b", "ignored", "-t", "%21"]): [
                .failure(tmuxTimeoutError()),
            ],
            RunnerState.key(socket: route.socket,
                            arguments: capturePaneArguments(paneID: "%21")): [
                .success("Claude prompt"),
            ],
        ])
        let router = OrdinaryTmuxInputRouter(registry: registry,
                                             adapter: adapter(state: state))

        XCTAssertThrowsError(try router.sendInput("hello from remote", toPanelID: route.panelID, mode: .literalChatText)) { error in
            XCTAssertEqual((error as NSError).domain, "OrdinaryTmuxCLIAdapter")
            XCTAssertEqual((error as NSError).code, 124)
        }
        XCTAssertThrowsError(try router.sendInput("\r", toPanelID: route.panelID))
        XCTAssertFalse(state.calls.contains { $0.arguments.first == "send-keys" })
    }

    func testPasteBufferTimeoutWithoutPaneEchoCanBeAcceptedForAmbiguousChatSubmitDelivery() throws {
        let route = ordinaryRoute()
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
                            arguments: ["paste-buffer", "-d", "-p", "-r", "-b", "ignored", "-t", "%21"]): [
                .failure(tmuxTimeoutError()),
            ],
            RunnerState.key(socket: route.socket,
                            arguments: capturePaneArguments(paneID: "%21")): [
                .success("Claude prompt"),
            ],
        ])

        let delivery = try adapter(state: state).sendInput("hello from remote",
                                                           route: route,
                                                           mode: .literalChatText,
                                                           allowAmbiguousPasteTimeout: true)

        XCTAssertEqual(delivery.paneID, "%21")
        XCTAssertTrue(delivery.pastedText)
        XCTAssertFalse(delivery.sentEnter)
        XCTAssertFalse(state.calls.contains { $0.arguments.first == "send-keys" })
        // Evidence, not defaults: the REAL bracketed paste argv was issued
        // and the echo verification actually queried the pane.
        XCTAssertEqual(state.calls.filter { $0.arguments.first == "paste-buffer" }.map(\.arguments),
                       [["paste-buffer", "-d", "-p", "-r", "-b", "ignored", "-t", "%21"]])
        XCTAssertEqual(state.calls.filter { $0.arguments.first == "capture-pane" }.map(\.arguments),
                       [capturePaneArguments(paneID: "%21")],
                       "the ambiguous acceptance is grounded in a REAL capture-pane call")
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
                            arguments: ["paste-buffer", "-d", "-p", "-r", "-b", "ignored", "-t", "%21"]): [
                .failure(tmuxTimeoutError()),
            ],
            RunnerState.key(socket: route.socket,
                            arguments: capturePaneArguments(paneID: "%21")): [
                .failure(tmuxTimeoutError()),
            ],
        ])
        let router = OrdinaryTmuxInputRouter(registry: registry,
                                             adapter: adapter(state: state))

        XCTAssertThrowsError(try router.sendInput("hello from remote", toPanelID: route.panelID, mode: .literalChatText)) { error in
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
                            arguments: ["paste-buffer", "-d", "-p", "-r", "-b", "ignored", "-t", "%21"]): [
                .failure(NSError(domain: "OrdinaryTmuxCLIAdapter",
                                  code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "can't find pane: %21"])),
            ],
        ])
        let router = OrdinaryTmuxInputRouter(registry: registry,
                                             adapter: adapter(state: state))

        XCTAssertThrowsError(try router.sendInput("hello from remote", toPanelID: route.panelID, mode: .literalChatText)) { error in
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
                            arguments: ["paste-buffer", "-d", "-p", "-r", "-b", "ignored", "-t", "%21"]): [
                .success(""),
            ],
        ])
        let router = OrdinaryTmuxInputRouter(registry: registry,
                                             adapter: adapter(state: state))

        XCTAssertTrue(try router.sendInput("hello from remote", toPanelID: route.panelID, mode: .literalChatText))
        XCTAssertFalse(state.calls.contains { $0.arguments.first == "capture-pane" })
    }

    func testPasteAndEnterTreatsEnterTimeoutAsDeliveredAfterPaste() throws {
        let registry = OrdinaryTmuxPanelRegistry()
        let route = ordinaryRoute()
        registry.replaceRoutes(workspaceID: "workspace-1", routes: [route])
        let state = RunnerState(scriptedResponses: [
            RunnerState.key(socket: route.socket, arguments: listPanesArguments(windowID: route.windowID)): [
                .success("%21\t1\t1021\t/Users/timfeng/GitHub/mother_nature\tcodex\n"),
            ],
            RunnerState.key(socket: route.socket,
                            arguments: ["load-buffer", "-b", "ignored", "-"],
                            stdin: "/status"): [
                .success(""),
            ],
            RunnerState.key(socket: route.socket,
                            arguments: ["paste-buffer", "-d", "-b", "ignored", "-t", "%21"]): [
                .success(""),
            ],
            RunnerState.key(socket: route.socket,
                            arguments: ["send-keys", "-t", "%21", "Enter"]): [
                .failure(tmuxTimeoutError()),
            ],
        ])
        let router = OrdinaryTmuxInputRouter(registry: registry,
                                             adapter: adapter(state: state))

        XCTAssertTrue(try router.sendInput("/status\r", toPanelID: route.panelID))
        XCTAssertEqual(state.calls.last?.arguments, ["send-keys", "-t", "%21", "Enter"])
    }

    func testEnterOnlyTimeoutStillThrowsWithoutPreviousPaste() throws {
        let registry = OrdinaryTmuxPanelRegistry()
        let route = ordinaryRoute()
        registry.replaceRoutes(workspaceID: "workspace-1", routes: [route])
        let state = RunnerState(scriptedResponses: [
            RunnerState.key(socket: route.socket, arguments: listPanesArguments(windowID: route.windowID)): [
                .success("%21\t1\t1021\t/Users/timfeng/GitHub/mother_nature\tcodex\n"),
            ],
            RunnerState.key(socket: route.socket,
                            arguments: ["send-keys", "-t", "%21", "Enter"]): [
                .failure(tmuxTimeoutError()),
            ],
        ])
        let router = OrdinaryTmuxInputRouter(registry: registry,
                                             adapter: adapter(state: state))

        XCTAssertThrowsError(try router.sendInput("\r", toPanelID: route.panelID)) { error in
            XCTAssertEqual((error as NSError).domain, "OrdinaryTmuxCLIAdapter")
            XCTAssertEqual((error as NSError).code, 124)
        }
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

    // R26: a message CONTAINING BLANK LINES must be ONE literal bracketed
    // paste (LF preserved — tmux without -r rewrites every LF in the buffer
    // to CR, and the TUI treats interior CRs as Enter, splitting the
    // message into several submits) followed by EXACTLY ONE Enter.
    func testBlankLineMessageIsSingleBracketedPasteWithSingleEnter() throws {
        let (router, state, route) = makeRouterForPaste(text: "LIVE-6\n\nLIVE-7")

        XCTAssertTrue(try router.sendInput("LIVE-6\n\nLIVE-7", toPanelID: route.panelID, mode: .literalChatText))
        XCTAssertTrue(try router.sendInput("\r", toPanelID: route.panelID))

        let loadCalls = state.calls.filter { $0.arguments.first == "load-buffer" }
        XCTAssertEqual(loadCalls.count, 1, "one load-buffer for the whole message")
        XCTAssertEqual(loadCalls[0].stdin, "LIVE-6\n\nLIVE-7", "the text reaches tmux verbatim")
        assertSingleBracketedPaste(state: state)
        let enterCalls = state.calls.filter { $0.arguments.first == "send-keys" }
        XCTAssertEqual(enterCalls.map(\.arguments), [["send-keys", "-t", "%21", "Enter"]],
                       "exactly ONE submit Enter")
        // ORDER is part of the contract: load -> paste -> Enter.
        let sequence = state.calls.map(\.arguments.first).compactMap { $0 }.filter {
            ["load-buffer", "paste-buffer", "send-keys"].contains($0)
        }
        XCTAssertEqual(sequence, ["load-buffer", "paste-buffer", "send-keys"],
                       "the paste lands before the submit Enter")
    }

    // R26: several blank-line-separated segments stay verbatim in one paste.
    func testMultipleBlankSegmentsPreservedVerbatimInOnePaste() throws {
        let text = "第一段\n\n第二段\n\n第三段"
        let (router, state, route) = makeRouterForPaste(text: text)

        XCTAssertTrue(try router.sendInput(text, toPanelID: route.panelID, mode: .literalChatText))
        XCTAssertTrue(try router.sendInput("\r", toPanelID: route.panelID))

        let loadCalls = state.calls.filter { $0.arguments.first == "load-buffer" }
        XCTAssertEqual(loadCalls.count, 1)
        XCTAssertEqual(loadCalls[0].stdin, text)
        assertSingleBracketedPaste(state: state)
        XCTAssertEqual(state.calls.filter { $0.arguments.first == "send-keys" }.count, 1)
    }

    // R26: attachment path + blank line + unicode caption stays verbatim.
    func testAttachmentPathWithBlankLinePreservedVerbatim() throws {
        let text = "@/tmp/a.jpg\n\n說明文字"
        let (router, state, route) = makeRouterForPaste(text: text)

        XCTAssertTrue(try router.sendInput(text, toPanelID: route.panelID, mode: .literalChatText))
        XCTAssertTrue(try router.sendInput("\r", toPanelID: route.panelID))

        let loadCalls = state.calls.filter { $0.arguments.first == "load-buffer" }
        XCTAssertEqual(loadCalls.count, 1)
        XCTAssertEqual(loadCalls[0].stdin, text)
        assertSingleBracketedPaste(state: state)
        XCTAssertEqual(state.calls.filter { $0.arguments.first == "send-keys" }.count, 1)
    }

    // R26 regression guard: a plain single-line submit is still one paste
    // (now bracketed) + one Enter.
    func testPlainSingleLineSubmitStillSinglePasteAndEnter() throws {
        let (router, state, route) = makeRouterForPaste(text: "hello")

        XCTAssertTrue(try router.sendInput("hello", toPanelID: route.panelID, mode: .literalChatText))
        XCTAssertTrue(try router.sendInput("\r", toPanelID: route.panelID))

        let loadCalls = state.calls.filter { $0.arguments.first == "load-buffer" }
        XCTAssertEqual(loadCalls.count, 1)
        XCTAssertEqual(loadCalls[0].stdin, "hello")
        assertSingleBracketedPaste(state: state)
        XCTAssertEqual(state.calls.filter { $0.arguments.first == "send-keys" }.count, 1)
    }

    // R26 edge: multi-line code containing a TAB is still ONE literal
    // bracketed paste — the mode (not the characters) decides.
    func testTabbedMultilineCodeIsSingleLiteralPaste() throws {
        let text = "A\tB\n\nC"
        let (router, state, route) = makeRouterForPaste(text: text)

        XCTAssertTrue(try router.sendInput(text, toPanelID: route.panelID, mode: .literalChatText))
        XCTAssertTrue(try router.sendInput("\r", toPanelID: route.panelID))

        let loadCalls = state.calls.filter { $0.arguments.first == "load-buffer" }
        XCTAssertEqual(loadCalls.count, 1)
        XCTAssertEqual(loadCalls[0].stdin, text, "the tab and the blank line stay verbatim")
        assertSingleBracketedPaste(state: state)
        XCTAssertEqual(state.calls.filter { $0.arguments.first == "send-keys" }.count, 1)
    }

    // R26 edge: CRLF blank lines from an attachment caption stay VERBATIM —
    // literal mode never splits, and the paste argv is asserted directly
    // from the recorded calls (no scripted-key default can fake it).
    func testCRLFAttachmentCaptionIsSingleLiteralPaste() throws {
        let text = "@/tmp/a.jpg\r\n\r\n說明"
        let (router, state, route) = makeRouterForPaste(text: text)

        XCTAssertTrue(try router.sendInput(text, toPanelID: route.panelID, mode: .literalChatText))
        XCTAssertTrue(try router.sendInput("\r", toPanelID: route.panelID))

        let loadCalls = state.calls.filter { $0.arguments.first == "load-buffer" }
        XCTAssertEqual(loadCalls.count, 1, "literal mode never splits on the trailing CRLF")
        XCTAssertEqual(loadCalls[0].stdin, text, "the CRLF blank line reaches tmux verbatim")
        assertSingleBracketedPaste(state: state)
        let enterCalls = state.calls.filter { $0.arguments.first == "send-keys" }
        XCTAssertEqual(enterCalls.map(\.arguments), [["send-keys", "-t", "%21", "Enter"]])
    }

    // R26 final: literal chat text with a TRAILING NEWLINE or embedded ANSI
    // stays verbatim — exact stdin, exact bracketed argv, and still exactly
    // the vendor's ONE submit Enter. The runner is STRICT: any argv drift
    // throws instead of defaulting to success.
    func testLiteralTrailingNewlineAndANSIPayloadStayVerbatim() throws {
        for text in ["hello world\n", "prefix \u{1b}[31mred\u{1b}[0m\n\nsuffix"] {
            let registry = OrdinaryTmuxPanelRegistry()
            let route = ordinaryRoute()
            registry.replaceRoutes(workspaceID: "workspace-1", routes: [route])
            let state = RunnerState(responses: [
                RunnerState.key(socket: route.socket, arguments: listPanesArguments(windowID: route.windowID)):
                    "%21\t1\t1021\t/Users/timfeng/GitHub/mother_nature\tclaude\n",
                RunnerState.key(socket: route.socket,
                                arguments: ["load-buffer", "-b", "ignored", "-"],
                                stdin: text):
                    "",
                RunnerState.key(socket: route.socket,
                                arguments: ["paste-buffer", "-d", "-p", "-r", "-b", "ignored", "-t", "%21"]):
                    "",
                RunnerState.key(socket: route.socket,
                                arguments: ["send-keys", "-t", "%21", "Enter"]):
                    "",
            ])
            state.failOnUnscripted = ["load-buffer", "paste-buffer", "send-keys"]
            let router = OrdinaryTmuxInputRouter(registry: registry, adapter: adapter(state: state))

            XCTAssertTrue(try router.sendInput(text, toPanelID: route.panelID, mode: .literalChatText))
            XCTAssertTrue(try router.sendInput("\r", toPanelID: route.panelID))

            let loadCalls = state.calls.filter { $0.arguments.first == "load-buffer" }
            XCTAssertEqual(loadCalls.map(\.stdin), [text],
                           "trailing newline / ANSI payload reaches tmux verbatim, unsplit")
            XCTAssertEqual(state.calls.filter { $0.arguments.first == "paste-buffer" }.map(\.arguments),
                           [["paste-buffer", "-d", "-p", "-r", "-b", "ignored", "-t", "%21"]])
            XCTAssertEqual(state.calls.filter { $0.arguments.first == "send-keys" }.map(\.arguments),
                           [["send-keys", "-t", "%21", "Enter"]],
                           "still exactly the vendor's ONE submit Enter")
            let sequence = state.calls.map(\.arguments.first).compactMap { $0 }.filter {
                ["load-buffer", "paste-buffer", "send-keys"].contains($0)
            }
            XCTAssertEqual(sequence, ["load-buffer", "paste-buffer", "send-keys"])
        }
    }

    // R26 regression guard: raw terminal_input control payloads (Esc, Tab,
    // Up/Down/Left/Right, Ctrl-C) must KEEP the legacy raw paste — bracketed
    // paste would turn them into literal text instead of keys.
    func testRawControlInputKeepsLegacyRawPaste() throws {
        for control in ["\u{1b}", "\t", "\u{1b}[A", "\u{1b}[B", "\u{1b}[D", "\u{1b}[C", "\u{03}"] {
            let registry = OrdinaryTmuxPanelRegistry()
            let route = ordinaryRoute()
            registry.replaceRoutes(workspaceID: "workspace-1", routes: [route])
            let state = RunnerState(responses: [
                RunnerState.key(socket: route.socket, arguments: listPanesArguments(windowID: route.windowID)):
                    "%21\t1\t1021\t/Users/timfeng/GitHub/mother_nature\tclaude\n",
                RunnerState.key(socket: route.socket,
                                arguments: ["load-buffer", "-b", "ignored", "-"],
                                stdin: control):
                    "",
                RunnerState.key(socket: route.socket,
                                arguments: ["paste-buffer", "-d", "-b", "ignored", "-t", "%21"]):
                    "",
            ])
            // STRICT: an unexpected bracketed argv or a stray Enter throws.
            state.failOnUnscripted = ["load-buffer", "paste-buffer", "send-keys"]
            let router = OrdinaryTmuxInputRouter(registry: registry, adapter: adapter(state: state))

            XCTAssertTrue(try router.sendInput(control, toPanelID: route.panelID))

            let loadCalls = state.calls.filter { $0.arguments.first == "load-buffer" }
            XCTAssertEqual(loadCalls.map(\.stdin), [control],
                           "the control payload reaches tmux exactly as sent")
            XCTAssertEqual(state.calls.filter { $0.arguments.first == "paste-buffer" }.map(\.arguments),
                           [["paste-buffer", "-d", "-b", "ignored", "-t", "%21"]],
                           "control payloads keep the FULL raw paste argv — no -p/-r")
            XCTAssertEqual(state.calls.filter { $0.arguments.first == "send-keys" }.count, 0)
            let sequence = state.calls.map(\.arguments.first).compactMap { $0 }.filter {
                ["load-buffer", "paste-buffer"].contains($0)
            }
            XCTAssertEqual(sequence, ["load-buffer", "paste-buffer"])
        }
    }

    private func makeRouterForPaste(text: String) -> (OrdinaryTmuxInputRouter, RunnerState, OrdinaryTmuxPanelRoute) {
        let registry = OrdinaryTmuxPanelRegistry()
        let route = ordinaryRoute()
        registry.replaceRoutes(workspaceID: "workspace-1", routes: [route])
        let state = RunnerState(responses: [
            RunnerState.key(socket: route.socket, arguments: listPanesArguments(windowID: route.windowID)):
                "%21\t1\t1021\t/Users/timfeng/GitHub/mother_nature\tclaude\n",
            RunnerState.key(socket: route.socket,
                            arguments: ["load-buffer", "-b", "ignored", "-"],
                            stdin: text):
                "",
        ])
        return (OrdinaryTmuxInputRouter(registry: registry, adapter: adapter(state: state)), state, route)
    }

    private func assertSingleBracketedPaste(state: RunnerState,
                                            file: StaticString = #filePath,
                                            line: UInt = #line) {
        let pasteCalls = state.calls.filter { $0.arguments.first == "paste-buffer" }
        XCTAssertEqual(pasteCalls.count, 1, "exactly one paste-buffer", file: file, line: line)
        guard let paste = pasteCalls.first else { return }
        XCTAssertEqual(paste.arguments, ["paste-buffer", "-d", "-p", "-r", "-b", "ignored", "-t", "%21"],
                       "the paste must be bracketed (-p) and keep LFs verbatim (-r)",
                       file: file, line: line)
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
                // Preserve the REAL argv (flags included) — only the random
                // buffer name is normalized, so a missing/extra flag can
                // never be masked by the fake.
                var normalized = arguments
                if let bIndex = normalized.firstIndex(of: "-b"), bIndex + 1 < normalized.count {
                    normalized[bIndex + 1] = "ignored"
                }
                return try state.run(socket: socket, arguments: normalized, stdin: stdin)
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
