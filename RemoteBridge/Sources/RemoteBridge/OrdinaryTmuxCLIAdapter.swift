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

    var stableSocketComponent: String {
        socketPath?.nilIfEmpty ?? "runtime-default"
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
    private static let commandTimeoutSeconds: TimeInterval = 3
    private static let liveCommandRunner: CommandRunner = { socket, arguments, stdin in
        guard let tmuxBinaryPath = TmuxStateResolver.discoverTmuxBinaryPath() else {
            BridgeLogger.server.error("ordinary tmux adapter could not find a tmux binary in supported paths")
            throw NSError(domain: "OrdinaryTmuxCLIAdapter",
                          code: 127,
                          userInfo: [NSLocalizedDescriptionKey: "tmux not found"])
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: tmuxBinaryPath)
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
        try process.run()
        if let stdin, let inputPipe {
            inputPipe.fileHandleForWriting.write(Data(stdin.utf8))
            try? inputPipe.fileHandleForWriting.close()
        }
        let waitSemaphore = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            process.waitUntilExit()
            waitSemaphore.signal()
        }
        if waitSemaphore.wait(timeout: .now() + OrdinaryTmuxCLIAdapter.commandTimeoutSeconds) == .timedOut {
            process.terminate()
            _ = waitSemaphore.wait(timeout: .now() + 1)
            BridgeLogger.server.info("ordinary tmux command timeout argv=\(process.arguments?.joined(separator: " ") ?? "-", privacy: .public) socket=\(socket.logDescription, privacy: .public) timeout_seconds=\(OrdinaryTmuxCLIAdapter.commandTimeoutSeconds, privacy: .public)")
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

    private let commandRunner: CommandRunner

    init(commandRunner: @escaping CommandRunner = OrdinaryTmuxCLIAdapter.liveCommandRunner) {
        self.commandRunner = commandRunner
    }

    func resolveClient(for metadata: OrdinaryTmuxAttachMetadata) throws -> OrdinaryTmuxClient? {
        BridgeLogger.server.debug("ordinary tmux resolveClient start tty=\(metadata.clientTTY, privacy: .public) target=\(metadata.targetSession ?? "<default>", privacy: .public) socket_selector=\(metadata.preferredSocketSelector.logDescription, privacy: .public)")
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
        guard let client = try resolveClient(for: metadata) else {
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
                   fallbackEnterPaneID: String? = nil) throws -> OrdinaryTmuxInputDelivery {
        let socket = route.socket
        let splitInput = Self.splitInputForPasteAndEnter(input)
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
            _ = try commandRunner(socket,
                                  ["load-buffer", "-b", bufferName, "-"],
                                  splitInput.pasteText)
            do {
                _ = try commandRunner(socket,
                                      ["paste-buffer", "-d", "-b", bufferName, "-t", pane.id],
                                      nil)
            } catch {
                guard Self.isTmuxCommandTimeout(error),
                      verifyPasteBufferDelivery(pasteText: splitInput.pasteText,
                                                paneID: pane.id,
                                                socket: socket,
                                                route: route) else {
                    throw error
                }
            }
        }
        if splitInput.sendEnter {
            _ = try commandRunner(socket,
                                  ["send-keys", "-t", pane.id, "Enter"],
                                  nil)
        }
        return OrdinaryTmuxInputDelivery(paneID: pane.id,
                                         pastedText: !splitInput.pasteText.isEmpty,
                                         sentEnter: splitInput.sendEnter,
                                         usedFallbackPane: false)
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
        var arguments = ["capture-pane", "-p", "-J"]
        if maxLines > 0 {
            arguments += ["-S", "-\(maxLines)"]
        }
        arguments += ["-t", refreshed.activePaneID]
        let output = try commandRunner(refreshed.socket, arguments, nil)
        return OrdinaryTmuxCapturedOutput(output: output,
                                          cursorRow: nil,
                                          cursorColumn: nil)
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
        let parts = split(line, maxSplits: 4)
        guard parts.count == 4 || parts.count == 5 else {
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
                                  currentWindowID: parts.count == 5 ? parts[4].nilIfEmpty : nil)
    }

    private static func parseWindowLine(_ line: Substring) -> (id: String, index: Int, name: String)? {
        let parts = split(line, maxSplits: 2)
        guard parts.count == 3,
              let index = Int(parts[1]) else {
            return nil
        }
        let id = parts[0].nilIfEmpty
        guard let id else {
            return nil
        }
        return (id, index, parts[2])
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
}

extension OrdinaryTmuxCLIAdapter: OrdinaryTmuxWindowProjecting {}
extension OrdinaryTmuxCLIAdapter: OrdinaryTmuxRouteRefreshing {}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
