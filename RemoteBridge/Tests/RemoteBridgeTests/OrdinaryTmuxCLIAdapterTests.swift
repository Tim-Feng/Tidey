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

    private final class RawRunnerState: @unchecked Sendable {
        struct Call: Equatable {
            let socket: OrdinaryTmuxSocketSelector
            let arguments: [String]
            let stdin: String?
        }

        typealias ResponseBuilder = @Sendable ([String]) throws -> Data

        private let lock = NSLock()
        private let responseBuilder: ResponseBuilder
        private var calls = [Call]()

        init(responseBuilder: @escaping ResponseBuilder) {
            self.responseBuilder = responseBuilder
        }

        func run(socket: OrdinaryTmuxSocketSelector,
                 arguments: [String],
                 stdin: String?) throws -> Data {
            lock.lock()
            calls.append(Call(socket: socket, arguments: arguments, stdin: stdin))
            lock.unlock()
            return try responseBuilder(arguments)
        }

        var recordedCalls: [Call] {
            lock.lock()
            defer { lock.unlock() }
            return calls
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

    func testStrictRawRunnerInjectionCompileSeam() {
        let adapter = OrdinaryTmuxCLIAdapter(
            commandRunner: { _, _, _ in "legacy" },
            rawCommandRunner: { _, _, _ in Data([0x00, 0x0A, 0xFF]) }
        )

        _ = adapter
    }

    func testRuntimeResumeSessionStateUsesCanonicalSessionNameFromServerWidePaneOutput()
        throws {
        let socket = OrdinaryTmuxSocketSelector.name(
            "tidey-agents"
        )
        let state = RunnerState(responses: [
            RunnerState.key(
                socket: socket,
                arguments: runtimeResumeListPanesArguments(
                    sessionID: "$7"
                )
            ):
                "$7\t storage \t@15\t0\tmain\t1\t%7\t0\t1\t/tmp/storage\n",
        ])
        let adapter = makeAdapter(state: state)
        let route = OrdinaryTmuxPanelRoute(
            workspaceID: "workspace-1",
            panelID: "panel-storage",
            carrierPanelID: "carrier-storage",
            socket: socket,
            sessionID: "$7",
            sessionName: "s",
            windowID: "@15",
            windowIndex: 0,
            activePaneID: "%7",
            cwd: "/tmp/storage",
            currentCommand: "codex"
        )

        let snapshot = try XCTUnwrap(
            adapter.runtimeResumeSessionState(for: route)
        )

        XCTAssertEqual(snapshot.sessionID, "$7")
        XCTAssertEqual(snapshot.sessionName, " storage ")
        XCTAssertEqual(snapshot.windows.count, 1)
        XCTAssertEqual(snapshot.windows.first?.windowID, "@15")
        XCTAssertEqual(snapshot.windows.first?.panes.first?.paneID, "%7")
        XCTAssertEqual(
            state.calls,
            [
                RunnerState.Call(
                    socket: socket,
                    arguments: runtimeResumeListPanesArguments(
                        sessionID: "$7"
                    ),
                    stdin: nil
                ),
            ]
        )
    }

    func testRawProcessRunnerPreservesBoundaryWhitespaceAndNonUTF8Bytes() throws {
        let runner = OrdinaryTmuxCLIAdapter.processRawCommandRunner(
            executablePath: "/usr/bin/printf",
            timeoutSeconds: 1
        )

        let output = try runner(.defaultSocket, ["\\000\\377  \n"], nil)

        XCTAssertEqual(output, Data([0x00, 0xFF, 0x20, 0x20, 0x0A]))
    }

    func testRawProcessRunnerDrainsLargeOutputWhileProcessIsRunning() throws {
        let byteCount = 512 * 1_024
        let runner = OrdinaryTmuxCLIAdapter.processRawCommandRunner(
            executablePath: "/usr/bin/head",
            timeoutSeconds: 2
        )

        let output = try runner(.defaultSocket, ["-c", "\(byteCount)", "/dev/zero"], nil)

        XCTAssertEqual(output, Data(repeating: 0, count: byteCount))
    }

    func testStrictBootstrapUsesOneRawExactPaneCommandAndAttachesPipeLast() throws {
        let socket = OrdinaryTmuxSocketSelector.path("/tmp/tmux-501/default")
        let route = makeRoute(socket: socket)
        let activeScreen = Data([
            0x20, 0x20, 0x0A,
            0xFF, 0x20, 0x0A,
            0x20, 0x20,
        ])
        let backgroundScreen = Data("primary  \nline-2\n   ".utf8)
        let metadata = [
            "%old", "132", "3", "11", "1", "1", "1", "3", "1", "0", "2",
            "8,16,24", "0", "1", "0", "1", "0", "0", "0", "0", "0", "1", "VT10x",
        ].joined(separator: "\t")
        let rawState = RawRunnerState { arguments in
            try Self.makeStrictBootstrapOutput(
                arguments: arguments,
                pendingCapture: Data("\\033[31".utf8),
                activeScreen: activeScreen,
                backgroundScreen: backgroundScreen,
                metadata: metadata
            )
        }
        let adapter = OrdinaryTmuxCLIAdapter(
            commandRunner: { _, _, _ in
                throw BridgeInternalError.invalidResponse
            },
            rawCommandRunner: { socket, arguments, stdin in
                try rawState.run(socket: socket, arguments: arguments, stdin: stdin)
            }
        )

        let state = try adapter.bootstrapStrictTerminalStream(
            refreshedRoute: route,
            outputFilePath: "/tmp/tidey stream/it\'s.bytes",
            subscriptionID: "subscription-1"
        )

        XCTAssertEqual(
            state,
            OrdinaryTmuxTerminalStateV1(
                subscriptionID: "subscription-1",
                paneID: "%old",
                columns: 132,
                rows: 3,
                cursor: OrdinaryTmuxTerminalCursorV1(row: 1, column: 11),
                cursorVisible: true,
                alternateOn: true,
                alternateSavedCursor: OrdinaryTmuxTerminalCursorV1(row: 1, column: 3),
                scrollRegionUpper: 0,
                scrollRegionLower: 2,
                tabStops: [8, 16, 24],
                modes: OrdinaryTmuxTerminalModesV1(
                    insert: false,
                    applicationCursorKeys: true,
                    applicationKeypad: false,
                    wrap: true,
                    origin: false,
                    mouseStandard: false,
                    mouseButton: false,
                    mouseAny: false,
                    mouseUTF8: false,
                    mouseSGR: true,
                    paneKeyMode: "VT10x"
                ),
                activeScreen: activeScreen,
                backgroundScreen: backgroundScreen,
                pendingPrefix: Data([0x1B, 0x5B, 0x33, 0x31])
            )
        )

        XCTAssertEqual(rawState.recordedCalls.count, 1)
        let call = try XCTUnwrap(rawState.recordedCalls.first)
        XCTAssertEqual(call.socket, socket)
        XCTAssertNil(call.stdin)
        let commands = Self.splitTmuxCommandQueue(call.arguments)
        XCTAssertEqual(commands.count, 8)
        guard commands.count == 8 else {
            return
        }
        XCTAssertEqual(commands[1], ["capture-pane", "-P", "-C", "-p", "-t", "%old"])
        XCTAssertEqual(commands[3], ["capture-pane", "-e", "-p", "-N", "-t", "%old"])
        XCTAssertEqual(commands[5], ["capture-pane", "-e", "-p", "-N", "-a", "-q", "-t", "%old"])
        XCTAssertEqual(
            commands[7],
            ["pipe-pane", "-o", "-t", "%old", "cat >> '/tmp/tidey stream/it'\\''s.bytes'"]
        )
    }

    func testStrictBootstrapRejectsDuplicateMarkersEvenWhenPayloadShapesRemainPlausible() {
        let socket = OrdinaryTmuxSocketSelector.path("/tmp/tmux-501/default")
        let route = makeRoute(socket: socket)
        let metadata = Self.strictMetadataFields().joined(separator: "\t")
        let rawState = RawRunnerState { arguments in
            let commands = Self.splitTmuxCommandQueue(arguments)
            guard commands.count == 8,
                  let duplicateMarker = commands[2].last else {
                throw BridgeInternalError.invalidResponse
            }
            return try Self.makeStrictBootstrapOutput(
                arguments: arguments,
                pendingCapture: Data(),
                activeScreen: Data("visible \(duplicateMarker)".utf8),
                backgroundScreen: Data(),
                metadata: metadata
            )
        }
        let adapter = OrdinaryTmuxCLIAdapter(
            commandRunner: { _, _, _ in throw BridgeInternalError.invalidResponse },
            rawCommandRunner: { socket, arguments, stdin in
                try rawState.run(socket: socket, arguments: arguments, stdin: stdin)
            }
        )

        XCTAssertThrowsError(
            try adapter.bootstrapStrictTerminalStream(
                refreshedRoute: route,
                outputFilePath: "/tmp/strict.bytes",
                subscriptionID: "subscription-1"
            )
        )
    }

    func testStrictBootstrapRejectsMalformedPendingCapture() {
        assertStrictBootstrapThrows(pendingCapture: Data("\\03".utf8))
        assertStrictBootstrapThrows(pendingCapture: Data("raw\\slash".utf8))
        assertStrictBootstrapThrows(pendingCapture: Data([0x1B]))
    }

    func testStrictBootstrapRejectsInvalidMetadataAndScreenShapes() {
        var fields = Self.strictMetadataFields()
        fields[0] = "%other"
        assertStrictBootstrapThrows(metadataFields: fields)

        fields = Self.strictMetadataFields()
        fields[5] = "2"
        assertStrictBootstrapThrows(metadataFields: fields)

        fields = Self.strictMetadataFields()
        fields[3] = "40"
        assertStrictBootstrapThrows(metadataFields: fields)

        fields = Self.strictMetadataFields()
        fields[7] = "4294967295"
        fields[8] = "0"
        assertStrictBootstrapThrows(metadataFields: fields)

        fields = Self.strictMetadataFields()
        fields[11] = "8,8"
        assertStrictBootstrapThrows(metadataFields: fields)

        assertStrictBootstrapThrows(activeScreen: Data("row-1\nrow-2".utf8))

        fields = Self.strictMetadataFields()
        fields[6] = "1"
        fields[7] = "0"
        fields[8] = "0"
        fields[2] = "2"
        fields[10] = "1"
        assertStrictBootstrapThrows(
            activeScreen: Data("visible\nrow-2".utf8),
            metadataFields: fields,
            backgroundScreen: Data()
        )

        assertStrictBootstrapThrows(backgroundScreen: Data("unexpected".utf8))
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

    func testStopPipePaneTargetsOwningPaneWithoutRefreshingActivePane() throws {
        let socket = OrdinaryTmuxSocketSelector.path("/tmp/tmux-501/default")
        let route = makeRoute(socket: socket)
        let state = RunnerState(responses: [
            RunnerState.key(socket: socket, arguments: ["pipe-pane", "-t", "%old"]):
                "",
        ])
        let adapter = makeAdapter(state: state)

        try adapter.stopPipePane(exactRoute: route)

        XCTAssertEqual(state.calls.map(\.arguments), [
            ["pipe-pane", "-t", "%old"],
        ])
    }

    func testStopPipePaneTreatsProvablyMissingOwningPaneAsClosed() {
        let route = makeRoute(socket: .path("/tmp/tmux-501/default"))
        let adapter = OrdinaryTmuxCLIAdapter { _, _, _ in
            throw NSError(domain: "tmux",
                          code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "can't find pane: %old"])
        }

        XCTAssertNoThrow(try adapter.stopPipePane(exactRoute: route))
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

    func testQueryCursorPositionTargetsOwningPaneWithoutRefreshingActivePane() throws {
        let socket = OrdinaryTmuxSocketSelector.path("/tmp/tmux-501/default")
        let route = makeRoute(socket: socket)
        let arguments = [
            "display-message", "-p", "-t", "%old",
            "#{cursor_x} #{cursor_y} #{cursor_flag}",
        ]
        let state = RunnerState(responses: [
            RunnerState.key(socket: socket, arguments: arguments): "42 7 0",
        ])
        let adapter = makeAdapter(state: state)

        let position = try adapter.queryCursorPosition(exactRoute: route)

        XCTAssertEqual(position,
                       OrdinaryTmuxCursorPosition(row: 7,
                                                  column: 42,
                                                  cursorVisible: false))
        XCTAssertEqual(state.calls.map(\.arguments), [arguments])
    }

    func testStrictFingerprintQueryTargetsExactPaneAndParsesState() throws {
        let socket = OrdinaryTmuxSocketSelector.path("/tmp/tmux-501/default")
        let route = makeRoute(socket: socket)
        let arguments = [
            "display-message", "-p", "-t", "%old",
            "#{pane_id}\t#{pane_width}\t#{pane_height}\t#{alternate_on}",
        ]
        let state = RunnerState(responses: [
            RunnerState.key(socket: socket, arguments: arguments): "%old\t132\t40\t1",
        ])
        let adapter = makeAdapter(state: state)

        let fingerprint = try adapter.queryStrictTerminalFingerprint(exactRoute: route)

        XCTAssertEqual(
            fingerprint,
            OrdinaryTmuxTerminalFingerprintV1(
                paneID: "%old",
                columns: 132,
                rows: 40,
                alternateOn: true
            )
        )
        XCTAssertEqual(state.calls.map(\.arguments), [arguments])
    }

    func testStrictFingerprintQueryRejectsMalformedOrMismatchedPaneState() throws {
        let route = makeRoute(socket: .path("/tmp/tmux-501/default"))
        for response in ["%other\t132\t40\t1", "%old\t0\t40\t1", "%old\t132\t40\t2", "malformed"] {
            let adapter = OrdinaryTmuxCLIAdapter { _, _, _ in response }
            XCTAssertNil(try adapter.queryStrictTerminalFingerprint(exactRoute: route), "response=\(response)")
        }
    }

    func testCombinedBootstrapUsesOneExactPaneCommand() throws {
        let socket = OrdinaryTmuxSocketSelector.path("/tmp/tmux-501/default")
        let route = makeRoute(socket: socket)
        let state = RunnerState(responses: [
            RunnerState.key(socket: socket, arguments: windowExistsArguments):
                "@15\n",
            RunnerState.key(socket: socket, arguments: listPanesArguments(windowID: "@15")):
                "%21\t1\t1021\t/Users/timfeng/GitHub/work\tcodex\n",
            RunnerState.key(socket: socket,
                            arguments: ["pipe-pane", "-o", "-t", "%21", "cat >> '/tmp/stream.bytes'"]):
                "",
        ])
        let adapter = makeAtomicCaptureAdapter(state: state,
                                               body: "line-0\nline-1",
                                               metadata: "4 1 1 2")

        let bootstrap = try adapter.bootstrapTerminalStream(refreshedRoute: route,
                                                            outputFilePath: "/tmp/stream.bytes",
                                                            maxLines: 200)

        XCTAssertEqual(bootstrap.route.activePaneID, "%old")
        XCTAssertEqual(bootstrap.initialOutput,
                       OrdinaryTmuxCapturedOutput(output: "line-0\nline-1",
                                                  cursorRow: 1,
                                                  cursorColumn: 4,
                                                  cursorVisible: true))
        XCTAssertEqual(state.calls.count, 1,
                       "capture and pipe attach must share one tmux command invocation")
        let arguments = try XCTUnwrap(state.calls.first?.arguments)
        let separators = arguments.indices.filter { arguments[$0] == ";" }
        XCTAssertEqual(separators.count, 3)
        guard separators.count == 3 else {
            return
        }
        XCTAssertEqual(Array(arguments[(separators[0] + 1)..<separators[1]]),
                       ["capture-pane", "-e", "-p", "-S", "-200", "-t", "%old"])
        XCTAssertEqual(Array(arguments[(separators[2] + 1)...]),
                       ["pipe-pane", "-o", "-t", "%old", "cat >> '/tmp/stream.bytes'"])
    }

    func testCombinedBootstrapParsesSnapshotCursorAndDegradesMalformedMetadata() throws {
        let socket = OrdinaryTmuxSocketSelector.path("/tmp/tmux-501/default")
        let route = makeRoute(socket: socket)
        let validState = RunnerState(responses: [:])
        let validAdapter = makeAtomicCaptureAdapter(state: validState,
                                                    body: "line-0\nline-1",
                                                    metadata: "4 1 1 2")

        let valid = try validAdapter.bootstrapTerminalStream(refreshedRoute: route,
                                                             outputFilePath: "/tmp/valid.bytes",
                                                             maxLines: 200)

        XCTAssertEqual(valid.initialOutput,
                       OrdinaryTmuxCapturedOutput(output: "line-0\nline-1",
                                                  cursorRow: 1,
                                                  cursorColumn: 4,
                                                  cursorVisible: true))

        let malformedState = RunnerState(responses: [:])
        let malformedAdapter = makeAtomicCaptureAdapter(state: malformedState,
                                                        body: "untrusted-snapshot",
                                                        metadata: "malformed metadata")

        let degraded = try malformedAdapter.bootstrapTerminalStream(refreshedRoute: route,
                                                                    outputFilePath: "/tmp/malformed.bytes",
                                                                    maxLines: 200)

        XCTAssertEqual(degraded.route, route)
        XCTAssertEqual(degraded.initialOutput,
                       OrdinaryTmuxCapturedOutput(output: "",
                                                  cursorRow: nil,
                                                  cursorColumn: nil,
                                                  cursorVisible: nil))
        XCTAssertTrue(malformedState.calls.first?.arguments.contains("pipe-pane") == true,
                      "successful combined command still owns the exact pane when parsing degrades")
    }

    func testCaptureOutputAtomicallyMapsPaneCursorIntoPhysicalRows() throws {
        let socket = OrdinaryTmuxSocketSelector.path("/tmp/tmux-501/default")
        let route = makeRoute(socket: socket)
        let state = RunnerState(responses: [
            RunnerState.key(socket: socket, arguments: windowExistsArguments):
                "@15\n",
            RunnerState.key(socket: socket, arguments: listPanesArguments(windowID: "@15")):
                "%21\t1\t1021\t/Users/timfeng/GitHub/work\tcodex\n",
        ])
        let adapter = makeAtomicCaptureAdapter(state: state,
                                               body: "history-0\nhistory-1\nvisible-0\nvisible-1\nvisible-2",
                                               metadata: "11 1 1 3")

        let captured = try adapter.captureOutput(route: route, maxLines: 50)

        XCTAssertEqual(captured,
                       OrdinaryTmuxCapturedOutput(output: "history-0\nhistory-1\nvisible-0\nvisible-1\nvisible-2",
                                                  cursorRow: 3,
                                                  cursorColumn: 11,
                                                  cursorVisible: true))
        let captureArguments = try XCTUnwrap(state.calls.map(\.arguments).first { $0.contains(";") })
        XCTAssertEqual(state.calls.count, 3, "refresh uses two calls and capture must use exactly one")
        let firstSeparator = try XCTUnwrap(captureArguments.firstIndex(of: ";"))
        let secondSeparator = try XCTUnwrap(captureArguments[(firstSeparator + 1)...].firstIndex(of: ";"))
        XCTAssertEqual(Array(captureArguments[(firstSeparator + 1)..<secondSeparator]),
                       ["capture-pane", "-p", "-S", "-50", "-t", "%21"])
    }

    func testCaptureOutputPreservesBoundaryBlankRows() throws {
        let socket = OrdinaryTmuxSocketSelector.path("/tmp/tmux-501/default")
        let route = makeRoute(socket: socket)
        let state = RunnerState(responses: [
            RunnerState.key(socket: socket, arguments: windowExistsArguments):
                "@15\n",
            RunnerState.key(socket: socket, arguments: listPanesArguments(windowID: "@15")):
                "%21\t1\t1021\t/Users/timfeng/GitHub/work\tcodex\n",
        ])
        let adapter = makeAtomicCaptureAdapter(state: state,
                                               body: "\nvisible-0\n",
                                               metadata: "4 0 1 2")

        let captured = try adapter.captureOutput(route: route, maxLines: 50)

        XCTAssertEqual(captured,
                       OrdinaryTmuxCapturedOutput(output: "\nvisible-0\n",
                                                  cursorRow: 1,
                                                  cursorColumn: 4,
                                                  cursorVisible: true))
    }

    func testCaptureOutputUsesUniqueSentinelsPerInvocation() throws {
        let socket = OrdinaryTmuxSocketSelector.path("/tmp/tmux-501/default")
        let route = makeRoute(socket: socket)
        let state = RunnerState(responses: [
            RunnerState.key(socket: socket, arguments: windowExistsArguments):
                "@15\n",
            RunnerState.key(socket: socket, arguments: listPanesArguments(windowID: "@15")):
                "%21\t1\t1021\t/Users/timfeng/GitHub/work\tcodex\n",
        ])
        let adapter = makeAtomicCaptureAdapter(state: state,
                                               body: "BEGIN\nEND",
                                               metadata: "0 1 1 2")

        let first = try adapter.captureOutput(route: route, maxLines: 50)
        let second = try adapter.captureOutput(route: route, maxLines: 50)

        XCTAssertEqual(first.output, "BEGIN\nEND")
        XCTAssertEqual(second.output, "BEGIN\nEND")
        let markerArguments = state.calls.map(\.arguments).filter { $0.contains(";") }
        guard markerArguments.count == 2 else {
            return XCTFail("expected two atomic capture invocations, got \(markerArguments.count)")
        }
        let firstSeparator = try XCTUnwrap(markerArguments[0].firstIndex(of: ";"))
        let secondSeparator = try XCTUnwrap(markerArguments[1].firstIndex(of: ";"))
        XCTAssertNotEqual(markerArguments[0][firstSeparator - 1],
                          markerArguments[1][secondSeparator - 1])
    }

    func testCaptureOutputDropsCursorMetadataWhenCaptureIsShorterThanPane() throws {
        let socket = OrdinaryTmuxSocketSelector.path("/tmp/tmux-501/default")
        let route = makeRoute(socket: socket)
        let state = RunnerState(responses: [
            RunnerState.key(socket: socket, arguments: windowExistsArguments):
                "@15\n",
            RunnerState.key(socket: socket, arguments: listPanesArguments(windowID: "@15")):
                "%21\t1\t1021\t/Users/timfeng/GitHub/work\tcodex\n",
        ])
        let adapter = makeAtomicCaptureAdapter(state: state,
                                               body: "short-0\nshort-1",
                                               metadata: "2 1 1 3")

        let captured = try adapter.captureOutput(route: route, maxLines: 2)

        XCTAssertEqual(captured,
                       OrdinaryTmuxCapturedOutput(output: "short-0\nshort-1",
                                                  cursorRow: nil,
                                                  cursorColumn: nil,
                                                  cursorVisible: nil))
    }

    func testCaptureANSIOutputUsesAtomicEscapePreservingCommandWithoutHistoryLimit() throws {
        let socket = OrdinaryTmuxSocketSelector.path("/tmp/tmux-501/default")
        let route = makeRoute(socket: socket)
        let state = RunnerState(responses: [
            RunnerState.key(socket: socket, arguments: windowExistsArguments):
                "@15\n",
            RunnerState.key(socket: socket, arguments: listPanesArguments(windowID: "@15")):
                "%21\t1\t1021\t/Users/timfeng/GitHub/work\tcodex\n",
        ])
        let adapter = makeAtomicCaptureAdapter(state: state,
                                               body: "\u{001B}[31mchoice\u{001B}[0m",
                                               metadata: "6 0 1 1")

        let captured = try adapter.captureANSIOutput(route: route, maxLines: 0)

        XCTAssertEqual(captured.output, "\u{001B}[31mchoice\u{001B}[0m")
        XCTAssertEqual(captured.cursorRow, 0)
        let captureArguments = try XCTUnwrap(state.calls.map(\.arguments).first { $0.contains(";") })
        let firstSeparator = try XCTUnwrap(captureArguments.firstIndex(of: ";"))
        let secondSeparator = try XCTUnwrap(captureArguments[(firstSeparator + 1)...].firstIndex(of: ";"))
        XCTAssertEqual(Array(captureArguments[(firstSeparator + 1)..<secondSeparator]),
                       ["capture-pane", "-e", "-p", "-t", "%21"])
    }

    func testCaptureOutputKeepsBodyWhenCursorMetadataIsMalformed() throws {
        let socket = OrdinaryTmuxSocketSelector.path("/tmp/tmux-501/default")
        let route = makeRoute(socket: socket)
        let state = RunnerState(responses: [
            RunnerState.key(socket: socket, arguments: windowExistsArguments):
                "@15\n",
            RunnerState.key(socket: socket, arguments: listPanesArguments(windowID: "@15")):
                "%21\t1\t1021\t/Users/timfeng/GitHub/work\tcodex\n",
        ])
        let adapter = makeAtomicCaptureAdapter(state: state,
                                               body: "still available",
                                               metadata: "malformed")

        let captured = try adapter.captureOutput(route: route, maxLines: 50)

        XCTAssertEqual(captured,
                       OrdinaryTmuxCapturedOutput(output: "still available",
                                                  cursorRow: nil,
                                                  cursorColumn: nil,
                                                  cursorVisible: nil))
    }

    func testCaptureOutputTreatsEmptyBodyAsOnePhysicalRow() throws {
        let socket = OrdinaryTmuxSocketSelector.path("/tmp/tmux-501/default")
        let route = makeRoute(socket: socket)
        let state = RunnerState(responses: [
            RunnerState.key(socket: socket, arguments: windowExistsArguments): "@15\n",
            RunnerState.key(socket: socket, arguments: listPanesArguments(windowID: "@15")):
                "%21\t1\t1021\t/Users/timfeng/GitHub/work\tcodex\n",
        ])
        let adapter = makeAtomicCaptureAdapter(state: state,
                                               body: "",
                                               metadata: "0 0 1 1")

        let captured = try adapter.captureOutput(route: route, maxLines: 1)

        XCTAssertEqual(captured,
                       OrdinaryTmuxCapturedOutput(output: "",
                                                  cursorRow: 0,
                                                  cursorColumn: 0,
                                                  cursorVisible: true))
    }

    func testCaptureOutputRejectsTrailingContentAfterEndMetadata() throws {
        let socket = OrdinaryTmuxSocketSelector.path("/tmp/tmux-501/default")
        let route = makeRoute(socket: socket)
        let state = RunnerState(responses: [
            RunnerState.key(socket: socket, arguments: windowExistsArguments): "@15\n",
            RunnerState.key(socket: socket, arguments: listPanesArguments(windowID: "@15")):
                "%21\t1\t1021\t/Users/timfeng/GitHub/work\tcodex\n",
        ])
        let adapter = makeAtomicCaptureAdapter(state: state,
                                               body: "choice",
                                               metadata: "0 0 1 1",
                                               trailingOutput: "\nunexpected")

        XCTAssertThrowsError(try adapter.captureOutput(route: route, maxLines: 1))
    }

    func testCaptureOutputDropsCursorWhenMetadataShapeOrFlagIsInvalid() throws {
        let socket = OrdinaryTmuxSocketSelector.path("/tmp/tmux-501/default")
        let route = makeRoute(socket: socket)
        for metadata in ["0 0 2 1", "0 0 1 1 extra"] {
            let state = RunnerState(responses: [
                RunnerState.key(socket: socket, arguments: windowExistsArguments): "@15\n",
                RunnerState.key(socket: socket, arguments: listPanesArguments(windowID: "@15")):
                    "%21\t1\t1021\t/Users/timfeng/GitHub/work\tcodex\n",
            ])
            let adapter = makeAtomicCaptureAdapter(state: state,
                                                   body: "choice",
                                                   metadata: metadata)

            let captured = try adapter.captureOutput(route: route, maxLines: 1)

            XCTAssertEqual(captured,
                           OrdinaryTmuxCapturedOutput(output: "choice",
                                                      cursorRow: nil,
                                                      cursorColumn: nil,
                                                      cursorVisible: nil),
                           "metadata=\(metadata)")
        }
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

    private func runtimeResumeListPanesArguments(
        sessionID: String
    ) -> [String] {
        [
            "list-panes",
            "-s",
            "-t",
            sessionID,
            "-F",
            [
                "#{session_id}",
                "#{session_name}",
                "#{window_id}",
                "#{window_index}",
                "#{window_name}",
                "#{window_active}",
                "#{pane_id}",
                "#{pane_index}",
                "#{pane_active}",
                "#{pane_current_path}",
            ].joined(separator: "\t"),
        ]
    }

    private func makeAdapter(state: RunnerState) -> OrdinaryTmuxCLIAdapter {
        OrdinaryTmuxCLIAdapter { socket, arguments, stdin in
            try state.run(socket: socket, arguments: arguments, stdin: stdin)
        }
    }

    private func makeAtomicCaptureAdapter(state: RunnerState,
                                          body: String,
                                          metadata: String,
                                          trailingOutput: String = "") -> OrdinaryTmuxCLIAdapter {
        OrdinaryTmuxCLIAdapter { socket, arguments, stdin in
            let fallback = try state.run(socket: socket, arguments: arguments, stdin: stdin)
            guard let firstSeparator = arguments.firstIndex(of: ";"),
                  firstSeparator > 0,
                  let secondSeparator = arguments[(firstSeparator + 1)...].firstIndex(of: ";"),
                  secondSeparator + 1 < arguments.count else {
                return fallback
            }
            let beginMarker = arguments[firstSeparator - 1]
            let thirdSeparator = arguments[(secondSeparator + 1)...].firstIndex(of: ";")
            let endCommandEnd = thirdSeparator ?? arguments.endIndex
            let endFormat = arguments[(secondSeparator + 1)..<endCommandEnd].last ?? ""
            let endMarker = endFormat.split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
            return "\(beginMarker)\n\(body)\n\(endMarker) \(metadata)\(trailingOutput)"
        }
    }

    private static func makeStrictBootstrapOutput(arguments: [String],
                                                  pendingCapture: Data,
                                                  activeScreen: Data,
                                                  backgroundScreen: Data,
                                                  metadata: String) throws -> Data {
        let commands = splitTmuxCommandQueue(arguments)
        guard commands.count == 8,
              let beginMarker = commands[0].last,
              let pendingEndMarker = commands[2].last,
              let activeEndMarker = commands[4].last,
              let metadataFormat = commands[6].last,
              let metadataMarker = metadataFormat.split(separator: "\t", maxSplits: 1).first else {
            throw BridgeInternalError.invalidResponse
        }

        var output = Data()
        output.append(Data(beginMarker.utf8))
        output.append(0x0A)
        output.append(pendingCapture)
        output.append(0x0A)
        output.append(Data(pendingEndMarker.utf8))
        output.append(0x0A)
        output.append(activeScreen)
        output.append(0x0A)
        output.append(Data(activeEndMarker.utf8))
        output.append(0x0A)
        output.append(backgroundScreen)
        output.append(0x0A)
        output.append(Data(metadataMarker.utf8))
        output.append(0x09)
        output.append(Data(metadata.utf8))
        output.append(0x0A)
        return output
    }

    private static func splitTmuxCommandQueue(_ arguments: [String]) -> [[String]] {
        var commands = [[String]]()
        var command = [String]()
        for argument in arguments {
            if argument == ";" {
                commands.append(command)
                command.removeAll(keepingCapacity: true)
            } else {
                command.append(argument)
            }
        }
        commands.append(command)
        return commands
    }

    private static func strictMetadataFields() -> [String] {
        [
            "%old", "40", "1", "0", "0", "1", "0",
            "4294967295", "4294967295", "0", "0", "8,16,24",
            "0", "0", "0", "1", "0", "0", "0", "0", "0", "0", "VT10x",
        ]
    }

    private func assertStrictBootstrapThrows(
        pendingCapture: Data = Data(),
        activeScreen: Data = Data("visible".utf8),
        metadataFields: [String] = OrdinaryTmuxCLIAdapterTests.strictMetadataFields(),
        backgroundScreen: Data = Data(),
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let route = makeRoute(socket: .path("/tmp/tmux-501/default"))
        let metadata = metadataFields.joined(separator: "\t")
        let rawState = RawRunnerState { arguments in
            try Self.makeStrictBootstrapOutput(
                arguments: arguments,
                pendingCapture: pendingCapture,
                activeScreen: activeScreen,
                backgroundScreen: backgroundScreen,
                metadata: metadata
            )
        }
        let adapter = OrdinaryTmuxCLIAdapter(
            commandRunner: { _, _, _ in throw BridgeInternalError.invalidResponse },
            rawCommandRunner: { socket, arguments, stdin in
                try rawState.run(socket: socket, arguments: arguments, stdin: stdin)
            }
        )

        XCTAssertThrowsError(
            try adapter.bootstrapStrictTerminalStream(
                refreshedRoute: route,
                outputFilePath: "/tmp/strict.bytes",
                subscriptionID: "subscription-1"
            ),
            file: file,
            line: line
        )
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
