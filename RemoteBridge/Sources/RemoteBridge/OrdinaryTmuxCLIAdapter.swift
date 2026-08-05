import CryptoKit
import Foundation

enum OrdinaryTmuxSocketSelector: Equatable, Sendable {
    case defaultSocket
    case path(String)
    case name(String)

    var cacheKey: String {
        switch self {
        case .defaultSocket:
            return "default"
        case .path(let path):
            return "path:\(path)"
        case .name(let name):
            return "name:\(name)"
        }
    }

    var logDescription: String {
        switch self {
        case .defaultSocket:
            return "default"
        case .path(let path):
            return "path:\(path)"
        case .name(let name):
            return "name:\(name)"
        }
    }
}

struct OrdinaryTmuxAttachMetadata: Equatable, Sendable {
    let clientTTY: String
    let targetSession: String?
    let socketPath: String?
    let socketName: String?

    init(clientTTY: String,
         targetSession: String? = nil,
         socketPath: String? = nil,
         socketName: String? = nil) {
        self.clientTTY = clientTTY
        self.targetSession = targetSession?.nilIfEmpty
        self.socketPath = socketPath?.nilIfEmpty
        self.socketName = socketName?.nilIfEmpty
    }

    init?(json: [String: JSONValue]) {
        guard let clientTTY = json["client_tty"]?.stringValue?.nilIfEmpty else {
            return nil
        }
        self.init(clientTTY: clientTTY,
                  targetSession: json["target_session"]?.stringValue,
                  socketPath: json["socket_path"]?.stringValue,
                  socketName: json["socket_name"]?.stringValue)
    }

    var preferredSocketSelector: OrdinaryTmuxSocketSelector {
        if let socketPath {
            return .path(socketPath)
        }
        if let socketName {
            return .name(socketName)
        }
        return .defaultSocket
    }
}

struct OrdinaryTmuxClient: Equatable, Sendable {
    let clientTTY: String
    let socketPath: String?
    let sessionID: String
    let sessionName: String
    let currentWindowID: String?
    let flags: Set<String>

    init(clientTTY: String,
         socketPath: String?,
         sessionID: String,
         sessionName: String,
         currentWindowID: String?,
         flags: Set<String> = []) {
        self.clientTTY = clientTTY
        self.socketPath = socketPath
        self.sessionID = sessionID
        self.sessionName = sessionName
        self.currentWindowID = currentWindowID
        self.flags = flags
    }

    var stableSocketComponent: String {
        socketPath?.nilIfEmpty ?? "runtime-default"
    }

    var affectsWindowSize: Bool {
        flags.contains("ignore-size") == false
    }
}

struct OrdinaryTmuxProjectedPanel: Equatable, Sendable {
    let panelID: String
    let socketPath: String?
    let sessionID: String
    let sessionName: String
    let windowID: String
    let windowIndex: Int
    let windowName: String
    let isCurrentWindow: Bool
    let activePaneID: String
    let activePanePID: Int32?
    let cwd: String?
    let currentCommand: String?
    let title: String
    let subtitle: String
}

struct OrdinaryTmuxInputDelivery: Equatable, Sendable {
    let paneID: String
    let pastedText: Bool
    let sentEnter: Bool
    let usedFallbackPane: Bool
}

protocol OrdinaryTmuxWindowProjecting: Sendable {
    func projectedPanels(for metadata: OrdinaryTmuxAttachMetadata) throws -> [OrdinaryTmuxProjectedPanel]
    func setPaneIdentity(route: OrdinaryTmuxPanelRoute) throws
}

enum OrdinaryTmuxProjectionError: Error, Equatable {
    case partialWindowProjection(windowID: String)
    case staleWindow(windowID: String)
}

final class OrdinaryTmuxCLIAdapter {
    typealias CommandRunner = @Sendable (_ socket: OrdinaryTmuxSocketSelector, _ arguments: [String], _ stdin: String?) throws -> String

    private static let fieldSeparator = "\t"
    private static let previousWindowSizeOption = "@tidey_window_size_before_multi_client"
    private static let commandTimeoutSeconds: TimeInterval = 3
    private static let liveCommandRunner: CommandRunner = processCommandRunner(
        executablePath: TmuxStateResolver.discoverTmuxBinaryPath(),
        timeoutSeconds: commandTimeoutSeconds
    )

    static func processCommandRunner(executablePath: String?,
                                     timeoutSeconds: TimeInterval) -> CommandRunner {
        { socket, arguments, stdin in
            guard let executablePath else {
                BridgeLogger.server.error("ordinary tmux adapter could not find a tmux binary in supported paths")
                throw NSError(domain: "OrdinaryTmuxCLIAdapter",
                              code: 127,
                              userInfo: [NSLocalizedDescriptionKey: "tmux not found"])
            }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: executablePath)
            process.arguments = OrdinaryTmuxCLIAdapter.arguments(for: socket, commandArguments: arguments)
            var environment = ProcessInfo.processInfo.environment
            environment["LC_CTYPE"] = "UTF-8"
            environment["LANG"] = "en_US.UTF-8"
            process.environment = environment

            let outputPipe = Pipe()
            let errorPipe = Pipe()
            let inputPipe = stdin == nil ? nil : Pipe()
            process.standardOutput = outputPipe
            process.standardError = errorPipe
            if let inputPipe {
                process.standardInput = inputPipe
            }
            let waitSemaphore = DispatchSemaphore(value: 0)
            // Foundation's waitUntilExit() runs a CFRunLoop. Calling it on an
            // unrelated global worker after launching Process can remain parked
            // even after a very short-lived tmux child has exited. Each false wait
            // consumed a worker until the adapter's timeout, eventually turning
            // otherwise instant tmux queries into deterministic 3-second failures.
            // Observe termination on Process itself instead of scheduling a
            // cross-thread waitUntilExit().
            process.terminationHandler = { _ in
                waitSemaphore.signal()
            }
            try process.run()
            if let stdin, let inputPipe {
                inputPipe.fileHandleForWriting.write(Data(stdin.utf8))
                try? inputPipe.fileHandleForWriting.close()
            }
            if waitSemaphore.wait(timeout: .now() + timeoutSeconds) == .timedOut {
                process.terminate()
                _ = waitSemaphore.wait(timeout: .now() + 1)
                BridgeLogger.server.info("ordinary tmux command timeout argv=\(process.arguments?.joined(separator: " ") ?? "-", privacy: .public) socket=\(socket.logDescription, privacy: .public) timeout_seconds=\(timeoutSeconds, privacy: .public)")
                throw NSError(domain: "OrdinaryTmuxCLIAdapter",
                              code: 124,
                              userInfo: [NSLocalizedDescriptionKey: "tmux command timed out"])
            }

            let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let stdoutText = String(data: outputData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let stderrText = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            BridgeLogger.server.debug("ordinary tmux command argv=\(process.arguments?.joined(separator: " ") ?? "-", privacy: .public) socket=\(socket.logDescription, privacy: .public) exit_code=\(process.terminationStatus, privacy: .public) stdout_bytes=\(outputData.count, privacy: .public) stderr_bytes=\(errorData.count, privacy: .public) stdout_prefix=\(String(stdoutText.prefix(500)), privacy: .public) stderr_prefix=\(String(stderrText.prefix(500)), privacy: .public)")
            guard process.terminationStatus == 0 else {
                let stderr = stderrText.isEmpty ? "tmux exited \(process.terminationStatus)" : stderrText
                throw NSError(domain: "OrdinaryTmuxCLIAdapter",
                              code: Int(process.terminationStatus),
                              userInfo: [NSLocalizedDescriptionKey: stderr])
            }
            return stdoutText
        }
    }

    private let commandRunner: CommandRunner

    init(commandRunner: @escaping CommandRunner = OrdinaryTmuxCLIAdapter.liveCommandRunner) {
        self.commandRunner = commandRunner
    }

    func resolveClient(for metadata: OrdinaryTmuxAttachMetadata) throws -> OrdinaryTmuxClient? {
        BridgeLogger.server.debug("ordinary tmux resolveClient start tty=\(metadata.clientTTY, privacy: .public) target=\(metadata.targetSession ?? "<default>", privacy: .public) socket_selector=\(metadata.preferredSocketSelector.logDescription, privacy: .public)")
        let clients = try clients(for: metadata)
        return resolveClient(for: metadata, among: clients)
    }

    private func clients(for metadata: OrdinaryTmuxAttachMetadata) throws -> [OrdinaryTmuxClient] {
        let output = try commandRunner(
            metadata.preferredSocketSelector,
            [
                "list-clients",
                "-F",
                [
                    "#{client_tty}",
                    "#{socket_path}",
                    "#{session_id}",
                    "#{session_name}",
                    "#{client_window}",
                    "#{client_flags}",
                ].joined(separator: Self.fieldSeparator),
            ],
            nil
        )
        let rawClientLines = output.split(whereSeparator: \.isNewline)
        let clients = rawClientLines
            .compactMap { Self.parseClientLine($0) }
        if rawClientLines.count != clients.count {
            BridgeLogger.server.error("ordinary tmux resolveClient parse mismatch raw_line_count=\(rawClientLines.count, privacy: .public) parsed_count=\(clients.count, privacy: .public) tty=\(metadata.clientTTY, privacy: .public) target=\(metadata.targetSession ?? "<default>", privacy: .public)")
        }
        BridgeLogger.server.debug("ordinary tmux resolveClient list-clients raw_line_count=\(rawClientLines.count, privacy: .public) parsed_count=\(clients.count, privacy: .public) tty=\(metadata.clientTTY, privacy: .public) target=\(metadata.targetSession ?? "<default>", privacy: .public)")
        for client in clients {
            BridgeLogger.server.debug("ordinary tmux resolveClient parsed_client tty=\(client.clientTTY, privacy: .public) session_id=\(client.sessionID, privacy: .public) session_name=\(client.sessionName, privacy: .public) socket_path=\(client.socketPath ?? "<default>", privacy: .public) current_window=\(client.currentWindowID ?? "<none>", privacy: .public)")
        }
        return clients
    }

    private func resolveClient(for metadata: OrdinaryTmuxAttachMetadata,
                               among clients: [OrdinaryTmuxClient]) -> OrdinaryTmuxClient? {
        let match = clients.first { client in
            guard client.clientTTY == metadata.clientTTY else {
                return false
            }
            guard let targetSession = metadata.targetSession else {
                return true
            }
            return targetSession == client.sessionName || targetSession == client.sessionID
        }
        if let match {
            BridgeLogger.server.debug("ordinary tmux resolveClient matched tty=\(metadata.clientTTY, privacy: .public) target=\(metadata.targetSession ?? "<default>", privacy: .public) session_id=\(match.sessionID, privacy: .public) session_name=\(match.sessionName, privacy: .public) current_window=\(match.currentWindowID ?? "<none>", privacy: .public)")
        } else {
            BridgeLogger.server.debug("ordinary tmux resolveClient no_match tty=\(metadata.clientTTY, privacy: .public) target=\(metadata.targetSession ?? "<default>", privacy: .public) parsed_count=\(clients.count, privacy: .public)")
        }
        return match
    }

    func projectedPanels(for metadata: OrdinaryTmuxAttachMetadata) throws -> [OrdinaryTmuxProjectedPanel] {
        let clients = try clients(for: metadata)
        guard let client = resolveClient(for: metadata, among: clients) else {
            return []
        }
        let socket = client.socketPath.map(OrdinaryTmuxSocketSelector.path) ?? metadata.preferredSocketSelector
        BridgeLogger.server.debug("ordinary tmux projectedPanels matched_client session_id=\(client.sessionID, privacy: .public) session_name=\(client.sessionName, privacy: .public) socket=\(socket.logDescription, privacy: .public)")
        let windowsOutput = try commandRunner(
            socket,
            [
                "list-windows",
                "-t",
                client.sessionID,
                "-F",
                [
                    "#{window_id}",
                    "#{window_index}",
                    "#{window_name}",
                    "#{window-size}",
                    "#{@tidey_window_size_before_multi_client}",
                ].joined(separator: Self.fieldSeparator),
            ],
            nil
        )
        let rawWindowLines = windowsOutput.split(whereSeparator: \.isNewline)
        let windows = rawWindowLines
            .compactMap { Self.parseWindowLine($0) }
            .sorted { $0.index < $1.index }
        let windowIDs = windows.map { "\($0.id):\($0.index):\($0.name)" }.joined(separator: ",")
        BridgeLogger.server.debug("ordinary tmux projectedPanels list-windows raw_line_count=\(rawWindowLines.count, privacy: .public) parsed_count=\(windows.count, privacy: .public) window_ids=\(windowIDs, privacy: .public) session_id=\(client.sessionID, privacy: .public)")
        reconcileWindowSizePolicyBestEffort(client: client,
                                            clients: clients,
                                            windows: windows,
                                            socket: socket)

        return try windows.map { window in
            let pane: TmuxPane
            do {
                guard let matchedPane = try activePane(forWindowID: window.id, socket: socket) else {
                    BridgeLogger.server.debug("ordinary tmux projectedPanels activePane failed window_id=\(window.id, privacy: .public) window_index=\(window.index, privacy: .public) reason=no_pane")
                    throw OrdinaryTmuxProjectionError.partialWindowProjection(windowID: window.id)
                }
                pane = matchedPane
            } catch {
                BridgeLogger.server.debug("ordinary tmux projectedPanels activePane failed window_id=\(window.id, privacy: .public) window_index=\(window.index, privacy: .public) reason=command_error error=\(String(describing: error), privacy: .public)")
                throw error
            }
            BridgeLogger.server.debug("ordinary tmux projectedPanels activePane matched window_id=\(window.id, privacy: .public) window_index=\(window.index, privacy: .public) pane_id=\(pane.id, privacy: .public) cwd=\(pane.cwd ?? "<none>", privacy: .public) command=\(pane.currentCommand ?? "<none>", privacy: .public)")
            let title = window.name.nilIfEmpty ?? "tmux window \(window.index)"
            return OrdinaryTmuxProjectedPanel(
                panelID: OrdinaryTmuxCLIAdapter.stablePanelID(socketComponent: client.stableSocketComponent,
                                                              sessionID: client.sessionID,
                                                              windowID: window.id),
                socketPath: client.socketPath,
                sessionID: client.sessionID,
                sessionName: client.sessionName,
                windowID: window.id,
                windowIndex: window.index,
                windowName: window.name,
                isCurrentWindow: window.id == client.currentWindowID,
                activePaneID: pane.id,
                activePanePID: pane.pid,
                cwd: pane.cwd,
                currentCommand: pane.currentCommand,
                title: title,
                subtitle: pane.cwd ?? client.sessionName
            )
        }
    }

    private func reconcileWindowSizePolicyBestEffort(
        client: OrdinaryTmuxClient,
        clients: [OrdinaryTmuxClient],
        windows: [TmuxWindow],
        socket: OrdinaryTmuxSocketSelector
    ) {
        guard client.affectsWindowSize else {
            return
        }
        let sizingClientCount = clients.lazy
            .filter { $0.sessionID == client.sessionID && $0.affectsWindowSize }
            .count

        for window in windows {
            do {
                try reconcileWindowSizePolicy(window: window,
                                              sizingClientCount: sizingClientCount,
                                              socket: socket)
            } catch {
                BridgeLogger.server.error("ordinary tmux window size reconciliation failed session_id=\(client.sessionID, privacy: .public) window_id=\(window.id, privacy: .public) sizing_client_count=\(sizingClientCount, privacy: .public) error=\(String(describing: error), privacy: .public)")
            }
        }
    }

    private func reconcileWindowSizePolicy(window: TmuxWindow,
                                           sizingClientCount: Int,
                                           socket: OrdinaryTmuxSocketSelector) throws {
        guard sizingClientCount > 0 else {
            return
        }
        if let previousPolicy = window.previousSizePolicy {
            if window.sizePolicy == previousPolicy {
                try setWindowOption("window-size",
                                    value: "largest",
                                    windowID: window.id,
                                    socket: socket)
            } else if window.sizePolicy != "largest" {
                try unsetWindowOption(Self.previousWindowSizeOption,
                                      windowID: window.id,
                                      socket: socket)
            }
            return
        }
        guard let currentPolicy = window.sizePolicy,
              currentPolicy == "latest" else {
            return
        }
        try setWindowOption(Self.previousWindowSizeOption,
                            value: currentPolicy,
                            windowID: window.id,
                            socket: socket)
        try setWindowOption("window-size",
                            value: "largest",
                            windowID: window.id,
                            socket: socket)
        BridgeLogger.server.info("ordinary tmux window size policy stabilized window_id=\(window.id, privacy: .public) previous=\(currentPolicy, privacy: .public) current=largest")
    }

    private func setWindowOption(_ option: String,
                                 value: String,
                                 windowID: String,
                                 socket: OrdinaryTmuxSocketSelector) throws {
        _ = try commandRunner(
            socket,
            ["set-option", "-w", "-t", windowID, option, value],
            nil
        )
    }

    private func unsetWindowOption(_ option: String,
                                   windowID: String,
                                   socket: OrdinaryTmuxSocketSelector) throws {
        _ = try commandRunner(
            socket,
            ["set-option", "-u", "-w", "-t", windowID, option],
            nil
        )
    }

    private func activePane(forWindowID windowID: String,
                            socket: OrdinaryTmuxSocketSelector) throws -> TmuxPane? {
        let panesOutput = try commandRunner(
            socket,
            [
                "list-panes",
                "-t",
                windowID,
                "-F",
                [
                    "#{pane_id}",
                    "#{pane_active}",
                    "#{pane_pid}",
                    "#{pane_current_path}",
                    "#{pane_current_command}",
                ].joined(separator: Self.fieldSeparator),
            ],
            nil
        )
        let panes = panesOutput
            .split(whereSeparator: \.isNewline)
            .compactMap { Self.parsePaneLine($0) }
        return panes.first { $0.isActive } ?? panes.first
    }

    static func stablePanelID(socketComponent: String,
                              sessionID: String,
                              windowID: String) -> String {
        "ordinary-tmux:\(socketComponent):\(sessionID):\(windowID)"
    }

    static func arguments(for socket: OrdinaryTmuxSocketSelector,
                          commandArguments: [String]) -> [String] {
        switch socket {
        case .defaultSocket:
            return commandArguments
        case .path(let path):
            return ["-S", path] + commandArguments
        case .name(let name):
            return ["-L", name] + commandArguments
        }
    }

    func sendInput(_ input: String,
                   route: OrdinaryTmuxPanelRoute,
                   mode: OrdinaryTmuxInputMode = .rawTerminalInput,
                   fallbackEnterPaneID: String? = nil,
                   allowAmbiguousPasteTimeout: Bool = false) throws -> OrdinaryTmuxInputDelivery {
        let socket = route.socket
        // literalChatText is NEVER split: the whole message (tabs, CRLF,
        // interior CR, trailing newlines included) is one verbatim paste —
        // the vendor plan sends its own Enter step. Only rawTerminalInput
        // may turn a trailing CR/LF into send-keys Enter.
        let splitInput: (pasteText: String, sendEnter: Bool)
        switch mode {
        case .literalChatText:
            splitInput = (input, false)
        case .rawTerminalInput:
            splitInput = Self.splitInputForPasteAndEnter(input)
        }
        if splitInput.pasteText.isEmpty,
           splitInput.sendEnter,
           let fallbackEnterPaneID {
            BridgeLogger.server.info("ordinary tmux input using last paste pane for enter workspace_id=\(route.workspaceID, privacy: .public) panel_id=\(route.panelID, privacy: .public) window_id=\(route.windowID, privacy: .public) pane_id=\(fallbackEnterPaneID, privacy: .public)")
            _ = try commandRunner(socket,
                                  ["send-keys", "-t", fallbackEnterPaneID, "Enter"],
                                  nil)
            return OrdinaryTmuxInputDelivery(paneID: fallbackEnterPaneID,
                                             pastedText: false,
                                             sentEnter: true,
                                             usedFallbackPane: true)
        }
        let pane: TmuxPane
        do {
            guard let activePane = try activePane(forWindowID: route.windowID, socket: socket) else {
                throw BridgeInternalError.notFound("ordinary tmux panel route is stale")
            }
            pane = activePane
        } catch {
            if splitInput.pasteText.isEmpty,
               splitInput.sendEnter,
               let fallbackEnterPaneID,
               Self.isTmuxCommandTimeout(error) {
                BridgeLogger.server.info("ordinary tmux input using fallback pane after active pane timeout workspace_id=\(route.workspaceID, privacy: .public) panel_id=\(route.panelID, privacy: .public) window_id=\(route.windowID, privacy: .public) pane_id=\(fallbackEnterPaneID, privacy: .public)")
                _ = try commandRunner(socket,
                                      ["send-keys", "-t", fallbackEnterPaneID, "Enter"],
                                      nil)
                return OrdinaryTmuxInputDelivery(paneID: fallbackEnterPaneID,
                                                 pastedText: false,
                                                 sentEnter: true,
                                                 usedFallbackPane: true)
            }
            throw error
        }
        guard !pane.id.isEmpty else {
            throw BridgeInternalError.notFound("ordinary tmux panel route is stale")
        }
        setPaneIdentityBestEffort(route: route, paneID: pane.id)
        if !splitInput.pasteText.isEmpty {
            let bufferName = "tidey-remote-\(UUID().uuidString)"
            try loadPasteBuffer(bufferName,
                                text: splitInput.pasteText,
                                socket: socket,
                                route: route,
                                paneID: pane.id)
            // LF must survive VERBATIM: without -r tmux rewrites every LF in
            // the buffer to CR before pasting, and the Claude/Codex TUI
            // treats interior CRs as Enter — a blank-line message becomes
            // several separate submits (R26, LIVE-6/LIVE-7). -p wraps the
            // paste in bracket codes when the application requested
            // bracketed paste, so the whole text lands as ONE literal
            // paste. Raw terminal input (Esc/Tab/arrows/Ctrl-C) keeps the
            // legacy raw paste so keys still act as keys — the MODE decides,
            // never a guess from the characters.
            let pasteArguments = mode == .literalChatText
                ? ["paste-buffer", "-d", "-p", "-r", "-b", bufferName, "-t", pane.id]
                : ["paste-buffer", "-d", "-b", bufferName, "-t", pane.id]
            do {
                _ = try commandRunner(socket,
                                      pasteArguments,
                                      nil)
            } catch {
                guard Self.isTmuxCommandTimeout(error) else {
                    throw error
                }
                let didVerify = verifyPasteBufferDelivery(pasteText: splitInput.pasteText,
                                                          paneID: pane.id,
                                                          socket: socket,
                                                          route: route)
                guard didVerify || allowAmbiguousPasteTimeout else {
                    throw error
                }
                if !didVerify {
                    let diagnostic = Self.pasteDiagnostic(for: splitInput.pasteText)
                    BridgeLogger.server.info("ordinary tmux paste-buffer timeout accepted as ambiguous delivery workspace_id=\(route.workspaceID, privacy: .public) panel_id=\(route.panelID, privacy: .public) window_id=\(route.windowID, privacy: .public) pane_id=\(pane.id, privacy: .public) paste_count=\(diagnostic.count, privacy: .public) paste_hash=\(diagnostic.hash, privacy: .public)")
                }
            }
        }
        if splitInput.sendEnter {
            do {
                _ = try commandRunner(socket,
                                      ["send-keys", "-t", pane.id, "Enter"],
                                      nil)
            } catch {
                guard !splitInput.pasteText.isEmpty,
                      Self.isTmuxCommandTimeout(error) else {
                    throw error
                }
                BridgeLogger.server.info("ordinary tmux input treating enter timeout as delivered after paste workspace_id=\(route.workspaceID, privacy: .public) panel_id=\(route.panelID, privacy: .public) window_id=\(route.windowID, privacy: .public) pane_id=\(pane.id, privacy: .public)")
            }
        }
        return OrdinaryTmuxInputDelivery(paneID: pane.id,
                                         pastedText: !splitInput.pasteText.isEmpty,
                                         sentEnter: splitInput.sendEnter,
                                         usedFallbackPane: false)
    }

    private func loadPasteBuffer(_ bufferName: String,
                                 text: String,
                                 socket: OrdinaryTmuxSocketSelector,
                                 route: OrdinaryTmuxPanelRoute,
                                 paneID: String) throws {
        do {
            _ = try commandRunner(socket,
                                  ["load-buffer", "-b", bufferName, "-"],
                                  text)
        } catch {
            guard Self.isTmuxCommandTimeout(error) else {
                throw error
            }
            let diagnostic = Self.pasteDiagnostic(for: text)
            BridgeLogger.server.info("ordinary tmux load-buffer timeout retrying workspace_id=\(route.workspaceID, privacy: .public) panel_id=\(route.panelID, privacy: .public) window_id=\(route.windowID, privacy: .public) pane_id=\(paneID, privacy: .public) paste_count=\(diagnostic.count, privacy: .public) paste_hash=\(diagnostic.hash, privacy: .public)")
            _ = try commandRunner(socket,
                                  ["load-buffer", "-b", bufferName, "-"],
                                  text)
        }
    }

    func refreshedRoute(_ route: OrdinaryTmuxPanelRoute) throws -> OrdinaryTmuxPanelRoute {
        guard windowExists(route.windowID, inSessionID: route.sessionID, socket: route.socket),
              let pane = try activePane(forWindowID: route.windowID, socket: route.socket) else {
            throw BridgeInternalError.notFound("ordinary tmux panel route is stale")
        }
        return OrdinaryTmuxPanelRoute(workspaceID: route.workspaceID,
                                      panelID: route.panelID,
                                      carrierPanelID: route.carrierPanelID,
                                      socket: route.socket,
                                      sessionID: route.sessionID,
                                      sessionName: route.sessionName,
                                      windowID: route.windowID,
                                      windowIndex: route.windowIndex,
                                      activePaneID: pane.id,
                                      cwd: pane.cwd,
                                      currentCommand: pane.currentCommand)
    }

    func route(for logicalID: OrdinaryTmuxLogicalPanelID,
               authorizedTarget: OrdinaryTmuxAuthorizedTarget) throws -> OrdinaryTmuxPanelRoute {
        guard windowExists(logicalID.windowID, inSessionID: authorizedTarget.sessionID, socket: authorizedTarget.socket),
              let pane = try activePane(forWindowID: logicalID.windowID, socket: authorizedTarget.socket) else {
            throw BridgeInternalError.notFound("ordinary tmux logical panel route is stale")
        }
        return OrdinaryTmuxPanelRoute(workspaceID: authorizedTarget.workspaceID,
                                      panelID: logicalID.rawValue,
                                      carrierPanelID: authorizedTarget.carrierPanelID,
                                      socket: authorizedTarget.socket,
                                      sessionID: authorizedTarget.sessionID,
                                      sessionName: authorizedTarget.sessionName,
                                      windowID: logicalID.windowID,
                                      windowIndex: 0,
                                      activePaneID: pane.id,
                                      cwd: pane.cwd,
                                      currentCommand: pane.currentCommand)
    }

    func captureOutput(route: OrdinaryTmuxPanelRoute, maxLines: Int) throws -> OrdinaryTmuxCapturedOutput {
        let refreshed = try refreshedRoute(route)
        return try captureOutput(refreshedRoute: refreshed,
                                 maxLines: maxLines,
                                 includeEscapeSequences: false)
    }

    func captureANSIOutput(route: OrdinaryTmuxPanelRoute, maxLines: Int) throws -> OrdinaryTmuxCapturedOutput {
        let refreshed = try refreshedRoute(route)
        return try captureOutput(refreshedRoute: refreshed,
                                 maxLines: maxLines,
                                 includeEscapeSequences: true)
    }

    private func captureOutput(refreshedRoute: OrdinaryTmuxPanelRoute,
                               maxLines: Int,
                               includeEscapeSequences: Bool) throws -> OrdinaryTmuxCapturedOutput {
        let markerRoot = "TIDEY_CAPTURE_\(UUID().uuidString)"
        let beginMarker = "\(markerRoot)_BEGIN"
        let endMarker = "\(markerRoot)_END"
        var captureArguments = ["capture-pane"]
        if includeEscapeSequences {
            captureArguments.append("-e")
        }
        captureArguments.append("-p")
        if maxLines > 0 {
            captureArguments += ["-S", "-\(maxLines)"]
        }
        captureArguments += ["-t", refreshedRoute.activePaneID]
        let arguments = [
            "display-message", "-p", "-t", refreshedRoute.activePaneID, beginMarker,
            ";",
        ] + captureArguments + [
            ";",
            "display-message", "-p", "-t", refreshedRoute.activePaneID,
            "\(endMarker) #{cursor_x} #{cursor_y} #{cursor_flag} #{pane_height}",
        ]
        let combinedOutput = try commandRunner(refreshedRoute.socket, arguments, nil)
        return try Self.parseAtomicCaptureOutput(combinedOutput,
                                                 beginMarker: beginMarker,
                                                 endMarker: endMarker)
    }

    private static func parseAtomicCaptureOutput(_ combinedOutput: String,
                                                 beginMarker: String,
                                                 endMarker: String) throws -> OrdinaryTmuxCapturedOutput {
        let beginBoundary = "\(beginMarker)\n"
        let endBoundary = "\n\(endMarker) "
        guard let beginRange = combinedOutput.range(of: beginBoundary),
              beginRange.lowerBound == combinedOutput.startIndex,
              let endRange = combinedOutput.range(of: endBoundary,
                                                  options: .backwards,
                                                  range: beginRange.upperBound..<combinedOutput.endIndex) else {
            throw BridgeInternalError.invalidResponse
        }

        let output = String(combinedOutput[beginRange.upperBound..<endRange.lowerBound])
        let metadataLine = combinedOutput[endRange.upperBound...]
        guard metadataLine.contains("\n") == false else {
            throw BridgeInternalError.invalidResponse
        }
        let metadata = metadataLine.split(whereSeparator: \.isWhitespace)
        guard metadata.count == 4,
              let cursorColumn = Int(metadata[0]),
              let cursorY = Int(metadata[1]),
              let visibilityFlag = Int(metadata[2]),
              let paneHeight = Int(metadata[3]),
              cursorColumn >= 0,
              cursorY >= 0,
              paneHeight > 0,
              cursorY < paneHeight,
              visibilityFlag == 0 || visibilityFlag == 1 else {
            return OrdinaryTmuxCapturedOutput(output: output,
                                              cursorRow: nil,
                                              cursorColumn: nil,
                                              cursorVisible: nil)
        }

        let capturedRowCount = output.reduce(into: 1) { count, character in
            if character == "\n" {
                count += 1
            }
        }
        let cursorRow = capturedRowCount - paneHeight + cursorY
        guard capturedRowCount >= paneHeight,
              cursorRow >= 0,
              cursorRow < capturedRowCount else {
            return OrdinaryTmuxCapturedOutput(output: output,
                                              cursorRow: nil,
                                              cursorColumn: nil,
                                              cursorVisible: nil)
        }
        return OrdinaryTmuxCapturedOutput(output: output,
                                          cursorRow: cursorRow,
                                          cursorColumn: cursorColumn,
                                          cursorVisible: visibilityFlag != 0)
    }

    func bootstrapTerminalStream(refreshedRoute: OrdinaryTmuxPanelRoute,
                                 outputFilePath: String,
                                 maxLines: Int) throws -> OrdinaryTmuxTerminalStreamBootstrap {
        let initialOutput = try captureOutput(refreshedRoute: refreshedRoute,
                                              maxLines: maxLines,
                                              includeEscapeSequences: true)
        let streamRoute = try startPipePane(route: refreshedRoute,
                                            outputFilePath: outputFilePath)
        return OrdinaryTmuxTerminalStreamBootstrap(route: streamRoute,
                                                   initialOutput: initialOutput)
    }

    func startPipePane(route: OrdinaryTmuxPanelRoute, outputFilePath: String) throws -> OrdinaryTmuxPanelRoute {
        let refreshed = try refreshedRoute(route)
        let command = "cat >> \(Self.singleQuotedShellArgument(outputFilePath))"
        _ = try commandRunner(refreshed.socket,
                              ["pipe-pane", "-o", "-t", refreshed.activePaneID, command],
                              nil)
        return refreshed
    }

    func stopPipePane(route: OrdinaryTmuxPanelRoute) throws {
        let refreshed = try refreshedRoute(route)
        _ = try commandRunner(refreshed.socket,
                              ["pipe-pane", "-t", refreshed.activePaneID],
                              nil)
    }

    func stopPipePane(exactRoute: OrdinaryTmuxPanelRoute) throws {
        do {
            _ = try commandRunner(exactRoute.socket,
                                  ["pipe-pane", "-t", exactRoute.activePaneID],
                                  nil)
        } catch {
            guard Self.isMissingTmuxPane(error) else {
                throw error
            }
        }
    }

    func queryCursorPosition(route: OrdinaryTmuxPanelRoute) throws -> OrdinaryTmuxCursorPosition? {
        let refreshed = try refreshedRoute(route)
        return try queryCursorPosition(refreshedRoute: refreshed)
    }

    func queryCursorPosition(exactRoute: OrdinaryTmuxPanelRoute) throws -> OrdinaryTmuxCursorPosition? {
        try queryCursorPosition(refreshedRoute: exactRoute)
    }

    private func queryCursorPosition(refreshedRoute: OrdinaryTmuxPanelRoute) throws -> OrdinaryTmuxCursorPosition? {
        let output = try commandRunner(refreshedRoute.socket,
                                       ["display-message", "-p", "-t", refreshedRoute.activePaneID, "#{cursor_x} #{cursor_y} #{cursor_flag}"],
                                       nil)
        let parts = output.split(whereSeparator: \.isWhitespace)
        guard parts.count >= 3,
              let column = Int(parts[0]),
              let row = Int(parts[1]),
              let visibilityFlag = Int(parts[2]) else {
            return nil
        }
        return OrdinaryTmuxCursorPosition(row: row,
                                          column: column,
                                          cursorVisible: visibilityFlag != 0)
    }

    private func verifyPasteBufferDelivery(pasteText: String,
                                           paneID: String,
                                           socket: OrdinaryTmuxSocketSelector,
                                           route: OrdinaryTmuxPanelRoute) -> Bool {
        let diagnostic = Self.pasteDiagnostic(for: pasteText)
        do {
            let output = try commandRunner(socket,
                                           ["capture-pane", "-p", "-J", "-S", "-20", "-t", paneID],
                                           nil)
            let didVerify = Self.captureOutput(output, containsPasteText: pasteText)
            if didVerify {
                BridgeLogger.server.info("ordinary tmux paste-buffer timeout verified workspace_id=\(route.workspaceID, privacy: .public) panel_id=\(route.panelID, privacy: .public) window_id=\(route.windowID, privacy: .public) pane_id=\(paneID, privacy: .public) paste_count=\(diagnostic.count, privacy: .public) paste_hash=\(diagnostic.hash, privacy: .public)")
            } else {
                BridgeLogger.server.info("ordinary tmux paste-buffer timeout unverified workspace_id=\(route.workspaceID, privacy: .public) panel_id=\(route.panelID, privacy: .public) window_id=\(route.windowID, privacy: .public) pane_id=\(paneID, privacy: .public) reason=no_match paste_count=\(diagnostic.count, privacy: .public) paste_hash=\(diagnostic.hash, privacy: .public)")
            }
            return didVerify
        } catch {
            BridgeLogger.server.info("ordinary tmux paste-buffer timeout unverified workspace_id=\(route.workspaceID, privacy: .public) panel_id=\(route.panelID, privacy: .public) window_id=\(route.windowID, privacy: .public) pane_id=\(paneID, privacy: .public) reason=capture_error paste_count=\(diagnostic.count, privacy: .public) paste_hash=\(diagnostic.hash, privacy: .public) error=\(String(describing: error), privacy: .public)")
            return false
        }
    }

    func setPaneIdentity(route: OrdinaryTmuxPanelRoute) throws {
        try setPaneIdentity(route: route, paneID: route.activePaneID)
    }

    private func setPaneIdentityBestEffort(route: OrdinaryTmuxPanelRoute, paneID: String) {
        do {
            try setPaneIdentity(route: route, paneID: paneID)
        } catch {
            BridgeLogger.server.error("ordinary tmux input pane identity sync skipped workspace_id=\(route.workspaceID, privacy: .public) panel_id=\(route.panelID, privacy: .public) window_id=\(route.windowID, privacy: .public) pane_id=\(paneID, privacy: .public) error=\(String(describing: error), privacy: .public)")
        }
    }

    private func setPaneIdentity(route: OrdinaryTmuxPanelRoute, paneID: String) throws {
        _ = try commandRunner(route.socket,
                              ["set-option", "-p", "-t", paneID, "@tidey_workspace_id", route.workspaceID],
                              nil)
        _ = try commandRunner(route.socket,
                              ["set-option", "-p", "-t", paneID, "@tidey_panel_id", route.panelID],
                              nil)
        // `tmux attach` updates the session environment, but cannot mutate an
        // already-running pane shell created earlier by SSH/Termius. Project
        // the current Tidey runtime into pane-scoped options so shell hooks and
        // wrappers can hydrate it without cross-pane/prod-dev last-writer bugs.
        _ = try commandRunner(route.socket,
                              ["set-option", "-p", "-F", "-t", paneID,
                               "@tidey_socket_path", "#{E:TIDEY_SOCKET_PATH}"],
                              nil)
        _ = try commandRunner(route.socket,
                              ["set-option", "-p", "-F", "-t", paneID,
                               "@tidey_bin_dir", "#{E:TIDEY_BIN_DIR}"],
                              nil)
    }

    private func windowExists(_ windowID: String,
                              inSessionID sessionID: String,
                              socket: OrdinaryTmuxSocketSelector) -> Bool {
        do {
            let output = try commandRunner(
                socket,
                [
                    "list-windows",
                    "-t",
                    sessionID,
                    "-F",
                    "#{window_id}",
                ],
                nil
            )
            return output.split(whereSeparator: \.isNewline).contains { String($0) == windowID }
        } catch {
            return false
        }
    }

    static func splitInputForPasteAndEnter(_ input: String) -> (pasteText: String, sendEnter: Bool) {
        if input.hasSuffix("\r\n") {
            return (String(input.dropLast(2)), true)
        }
        if input.hasSuffix("\r") || input.hasSuffix("\n") {
            return (String(input.dropLast()), true)
        }
        return (input, false)
    }

    private static func isTmuxCommandTimeout(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == "OrdinaryTmuxCLIAdapter" && nsError.code == 124
    }

    private static func isMissingTmuxPane(_ error: Error) -> Bool {
        (error as NSError).localizedDescription
            .lowercased()
            .contains("can't find pane")
    }

    private static func captureOutput(_ output: String, containsPasteText pasteText: String) -> Bool {
        let pasteKey = ChatSubmitEchoRegistry.normalizedKey(pasteText)
        guard !pasteKey.isEmpty else {
            return true
        }
        let captureKey = ChatSubmitEchoRegistry.normalizedKey(output)
        if captureKey.contains(pasteKey) {
            return true
        }
        let pasteBlankLineInsensitive = pasteKey.replacingOccurrences(of: "\n{2,}",
                                                                      with: "\n",
                                                                      options: .regularExpression)
        let captureBlankLineInsensitive = captureKey.replacingOccurrences(of: "\n{2,}",
                                                                          with: "\n",
                                                                          options: .regularExpression)
        if captureBlankLineInsensitive.contains(pasteBlankLineInsensitive) {
            return true
        }
        guard pasteBlankLineInsensitive.count > 80 else {
            return false
        }
        let tailToken = String(pasteBlankLineInsensitive.suffix(80))
        return captureBlankLineInsensitive.contains(tailToken)
    }

    private static func pasteDiagnostic(for pasteText: String) -> (count: Int, hash: String) {
        let normalized = ChatSubmitEchoRegistry.normalizedKey(pasteText)
        let digest = SHA256.hash(data: Data(normalized.utf8))
        let hash = digest.prefix(4).map { String(format: "%02x", $0) }.joined()
        return (normalized.count, hash)
    }

    private static func parseClientLine(_ line: Substring) -> OrdinaryTmuxClient? {
        let parts = split(line, maxSplits: 5)
        guard (4...6).contains(parts.count) else {
            return nil
        }
        let clientTTY = parts[0].nilIfEmpty
        let sessionID = parts[2].nilIfEmpty
        let sessionName = parts[3].nilIfEmpty
        guard let clientTTY, let sessionID, let sessionName else {
            return nil
        }
        return OrdinaryTmuxClient(clientTTY: clientTTY,
                                  socketPath: parts[1].nilIfEmpty,
                                  sessionID: sessionID,
                                  sessionName: sessionName,
                                  currentWindowID: parts.count >= 5 ? parts[4].nilIfEmpty : nil,
                                  flags: parts.count == 6 ? Set(parts[5].split(separator: ",").map(String.init)) : [])
    }

    private struct TmuxWindow {
        let id: String
        let index: Int
        let name: String
        let sizePolicy: String?
        let previousSizePolicy: String?
    }

    private static func parseWindowLine(_ line: Substring) -> TmuxWindow? {
        let parts = split(line, maxSplits: 4)
        guard (3...5).contains(parts.count),
              let index = Int(parts[1]) else {
            return nil
        }
        let id = parts[0].nilIfEmpty
        guard let id else {
            return nil
        }
        return TmuxWindow(id: id,
                          index: index,
                          name: parts[2],
                          sizePolicy: parts.count >= 4 ? parts[3].nilIfEmpty : nil,
                          previousSizePolicy: parts.count == 5 ? parts[4].nilIfEmpty : nil)
    }

    private struct TmuxPane {
        let id: String
        let isActive: Bool
        let pid: Int32?
        let cwd: String?
        let currentCommand: String?
    }

    private static func parsePaneLine(_ line: Substring) -> TmuxPane? {
        let parts = split(line, maxSplits: 4)
        guard parts.count == 5 else {
            return nil
        }
        let id = parts[0].nilIfEmpty
        guard let id else {
            return nil
        }
        return TmuxPane(id: id,
                        isActive: parts[1] == "1",
                        pid: Int32(parts[2]),
                        cwd: parts[3].nilIfEmpty,
                        currentCommand: parts[4].nilIfEmpty)
    }

    private static func split(_ line: Substring, maxSplits: Int) -> [String] {
        line.split(separator: Character(fieldSeparator),
                   maxSplits: maxSplits,
                   omittingEmptySubsequences: false)
            .map(String.init)
    }

    private static func singleQuotedShellArgument(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

extension OrdinaryTmuxCLIAdapter: OrdinaryTmuxWindowProjecting {}
extension OrdinaryTmuxCLIAdapter: OrdinaryTmuxRouteRefreshing {}
extension OrdinaryTmuxCLIAdapter: OrdinaryTmuxTerminalStreaming {}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
