import Foundation

struct OrdinaryTmuxPanelRoute: Equatable, Sendable {
    let workspaceID: String
    let panelID: String
    let carrierPanelID: String
    let socket: OrdinaryTmuxSocketSelector
    let restorationSocket: OrdinaryTmuxSocketSelector
    let sessionID: String
    let sessionName: String
    let windowID: String
    let windowIndex: Int
    let activePaneID: String
    let cwd: String?
    let currentCommand: String?

    init(workspaceID: String,
         panelID: String,
         carrierPanelID: String,
         socket: OrdinaryTmuxSocketSelector,
         restorationSocket: OrdinaryTmuxSocketSelector? = nil,
         sessionID: String,
         sessionName: String,
         windowID: String,
         windowIndex: Int,
         activePaneID: String,
         cwd: String?,
         currentCommand: String?) {
        self.workspaceID = workspaceID
        self.panelID = panelID
        self.carrierPanelID = carrierPanelID
        self.socket = socket
        self.restorationSocket = restorationSocket ?? socket
        self.sessionID = sessionID
        self.sessionName = sessionName
        self.windowID = windowID
        self.windowIndex = windowIndex
        self.activePaneID = activePaneID
        self.cwd = cwd
        self.currentCommand = currentCommand
    }
}

struct OrdinaryTmuxLogicalPanelID: Equatable, Sendable {
    static let prefix = "ordinary-tmux"

    let rawValue: String
    let socketComponent: String
    let sessionID: String
    let windowID: String

    init?(rawValue: String) {
        let parts = rawValue.split(separator: ":", maxSplits: 3, omittingEmptySubsequences: false)
        guard parts.count == 4,
              parts[0] == Self.prefix else {
            return nil
        }
        let socketComponent = String(parts[1])
        let sessionID = String(parts[2])
        let windowID = String(parts[3])
        guard Self.isSafeSocketComponent(socketComponent),
              Self.isValidSessionID(sessionID),
              Self.isValidWindowID(windowID) else {
            return nil
        }
        self.rawValue = rawValue
        self.socketComponent = socketComponent
        self.sessionID = sessionID
        self.windowID = windowID
    }

    private static func isValidSessionID(_ value: String) -> Bool {
        value.first == "$" && value.dropFirst().allSatisfy(\.isNumber)
    }

    private static func isValidWindowID(_ value: String) -> Bool {
        value.first == "@" && value.dropFirst().allSatisfy(\.isNumber)
    }

    private static func isSafeSocketComponent(_ value: String) -> Bool {
        guard value.isEmpty == false,
              value.contains("..") == false else {
            return false
        }
        if value == "runtime-default" {
            return true
        }
        guard value.hasPrefix("/") else {
            return false
        }
        let uid = getuid()
        return value.hasPrefix("/tmp/tmux-\(uid)/") ||
            value.hasPrefix("/private/tmp/tmux-\(uid)/")
    }
}

struct OrdinaryTmuxAuthorizedTarget: Equatable, Sendable {
    let workspaceID: String
    let carrierPanelID: String
    let socket: OrdinaryTmuxSocketSelector
    let restorationSocket: OrdinaryTmuxSocketSelector
    let sessionID: String
    let sessionName: String
    let authorizedAt: Date

    init(workspaceID: String,
         carrierPanelID: String,
         socket: OrdinaryTmuxSocketSelector,
         restorationSocket: OrdinaryTmuxSocketSelector? = nil,
         sessionID: String,
         sessionName: String,
         authorizedAt: Date) {
        self.workspaceID = workspaceID
        self.carrierPanelID = carrierPanelID
        self.socket = socket
        self.restorationSocket = restorationSocket ?? socket
        self.sessionID = sessionID
        self.sessionName = sessionName
        self.authorizedAt = authorizedAt
    }

    var socketComponent: String {
        socket.stablePanelIDComponent
    }
}

struct OrdinaryTmuxProjectionSnapshot: Equatable, Sendable {
    let panels: [OrdinaryTmuxProjectedPanel]
    let observedAt: Date
}

final class OrdinaryTmuxPanelRegistry: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.tidey.remote-bridge.ordinary-tmux-panel-registry")
    private var routesByPanelID = [String: OrdinaryTmuxPanelRoute]()
    private var authorizedTargets = [String: OrdinaryTmuxAuthorizedTarget]()
    private var projectionSnapshotsByKey = [String: OrdinaryTmuxProjectionSnapshot]()
    private let authorizationTTL: TimeInterval

    init(authorizationTTL: TimeInterval = 600) {
        self.authorizationTTL = authorizationTTL
    }

    func replaceRoutes(workspaceID: String, routes: [OrdinaryTmuxPanelRoute], observedAt: Date = Date()) {
        queue.sync {
            routesByPanelID = routesByPanelID.filter { $0.value.workspaceID != workspaceID }
            for route in routes {
                routesByPanelID[route.panelID] = route
                let target = OrdinaryTmuxAuthorizedTarget(workspaceID: route.workspaceID,
                                                          carrierPanelID: route.carrierPanelID,
                                                          socket: route.socket,
                                                          restorationSocket: route.restorationSocket,
                                                          sessionID: route.sessionID,
                                                          sessionName: route.sessionName,
                                                          authorizedAt: observedAt)
                authorizedTargets[Self.authorizedTargetKey(workspaceID: route.workspaceID,
                                                           socketComponent: route.socket.stablePanelIDComponent,
                                                           sessionID: route.sessionID)] = target
            }
        }
    }

    func replaceRoutesAuthoritatively(workspaceID: String,
                                      routes: [OrdinaryTmuxPanelRoute],
                                      observedAt: Date = Date()) {
        queue.sync {
            routesByPanelID = routesByPanelID.filter { $0.value.workspaceID != workspaceID }
            authorizedTargets = authorizedTargets.filter { $0.value.workspaceID != workspaceID }
            for route in routes {
                routesByPanelID[route.panelID] = route
                let target = OrdinaryTmuxAuthorizedTarget(workspaceID: route.workspaceID,
                                                          carrierPanelID: route.carrierPanelID,
                                                          socket: route.socket,
                                                          restorationSocket: route.restorationSocket,
                                                          sessionID: route.sessionID,
                                                          sessionName: route.sessionName,
                                                          authorizedAt: observedAt)
                authorizedTargets[Self.authorizedTargetKey(workspaceID: route.workspaceID,
                                                           socketComponent: route.socket.stablePanelIDComponent,
                                                           sessionID: route.sessionID)] = target
            }
        }
    }

    func replaceRoutes(workspaceID: String,
                       carrierPanelID: String,
                       routes: [OrdinaryTmuxPanelRoute],
                       observedAt: Date = Date()) {
        queue.sync {
            routesByPanelID = routesByPanelID.filter {
                $0.value.workspaceID != workspaceID || $0.value.carrierPanelID != carrierPanelID
            }
            authorizedTargets = authorizedTargets.filter {
                $0.value.workspaceID != workspaceID || $0.value.carrierPanelID != carrierPanelID
            }
            for route in routes {
                routesByPanelID[route.panelID] = route
                let target = OrdinaryTmuxAuthorizedTarget(workspaceID: route.workspaceID,
                                                          carrierPanelID: route.carrierPanelID,
                                                          socket: route.socket,
                                                          restorationSocket: route.restorationSocket,
                                                          sessionID: route.sessionID,
                                                          sessionName: route.sessionName,
                                                          authorizedAt: observedAt)
                authorizedTargets[Self.authorizedTargetKey(workspaceID: route.workspaceID,
                                                           socketComponent: route.socket.stablePanelIDComponent,
                                                           sessionID: route.sessionID)] = target
            }
        }
    }

    func storeRoute(_ route: OrdinaryTmuxPanelRoute, observedAt: Date = Date()) {
        queue.sync {
            routesByPanelID[route.panelID] = route
            let target = OrdinaryTmuxAuthorizedTarget(workspaceID: route.workspaceID,
                                                      carrierPanelID: route.carrierPanelID,
                                                      socket: route.socket,
                                                      restorationSocket: route.restorationSocket,
                                                      sessionID: route.sessionID,
                                                      sessionName: route.sessionName,
                                                      authorizedAt: observedAt)
            authorizedTargets[Self.authorizedTargetKey(workspaceID: route.workspaceID,
                                                       socketComponent: route.socket.stablePanelIDComponent,
                                                       sessionID: route.sessionID)] = target
        }
    }

    func route(forPanelID panelID: String) -> OrdinaryTmuxPanelRoute? {
        queue.sync {
            routesByPanelID[panelID]
        }
    }

    func routes(
        workspaceID: String,
        socket: OrdinaryTmuxSocketSelector,
        sessionID: String
    ) -> [OrdinaryTmuxPanelRoute] {
        queue.sync {
            routesByPanelID.values
                .filter {
                    $0.workspaceID == workspaceID &&
                        $0.socket == socket &&
                        $0.sessionID == sessionID
                }
                .sorted {
                    if $0.windowIndex != $1.windowIndex {
                        return $0.windowIndex < $1.windowIndex
                    }
                    return $0.windowID < $1.windowID
                }
        }
    }

    func routes(
        workspaceID: String,
        carrierPanelID: String,
        socket: OrdinaryTmuxSocketSelector,
        sessionID: String
    ) -> [OrdinaryTmuxPanelRoute] {
        queue.sync {
            routesByPanelID.values
                .filter {
                    $0.workspaceID == workspaceID &&
                        $0.carrierPanelID == carrierPanelID &&
                        $0.socket == socket &&
                        $0.sessionID == sessionID
                }
                .sorted {
                    if $0.windowIndex != $1.windowIndex {
                        return $0.windowIndex < $1.windowIndex
                    }
                    return $0.windowID < $1.windowID
                }
        }
    }

    func hasCarrierOwnership(workspaceID: String, carrierPanelID: String) -> Bool {
        queue.sync {
            routesByPanelID.values.contains {
                $0.workspaceID == workspaceID && $0.carrierPanelID == carrierPanelID
            } || authorizedTargets.values.contains {
                $0.workspaceID == workspaceID && $0.carrierPanelID == carrierPanelID
            }
        }
    }

    func hasWorkspaceOwnership(workspaceID: String) -> Bool {
        queue.sync {
            routesByPanelID.values.contains { $0.workspaceID == workspaceID }
                || authorizedTargets.values.contains { $0.workspaceID == workspaceID }
        }
    }

    func authorizedTarget(for logicalID: OrdinaryTmuxLogicalPanelID,
                          workspaceID: String?,
                          now: Date = Date()) -> OrdinaryTmuxAuthorizedTarget? {
        queue.sync {
            let candidates = authorizedTargets.values.filter { target in
                guard target.socketComponent == logicalID.socketComponent,
                      target.sessionID == logicalID.sessionID,
                      now.timeIntervalSince(target.authorizedAt) <= authorizationTTL else {
                    return false
                }
                if let workspaceID {
                    return target.workspaceID == workspaceID
                }
                return true
            }
            return candidates.sorted { $0.authorizedAt > $1.authorizedAt }.first
        }
    }

    func storeProjectionSnapshot(key: String,
                                 panels: [OrdinaryTmuxProjectedPanel],
                                 observedAt: Date = Date()) {
        queue.sync {
            if panels.isEmpty {
                projectionSnapshotsByKey.removeValue(forKey: key)
            } else {
                projectionSnapshotsByKey[key] = OrdinaryTmuxProjectionSnapshot(panels: panels,
                                                                               observedAt: observedAt)
            }
        }
    }

    func projectionSnapshot(key: String,
                            maxAge: TimeInterval,
                            now: Date = Date()) -> OrdinaryTmuxProjectionSnapshot? {
        queue.sync {
            guard let snapshot = projectionSnapshotsByKey[key],
                  now.timeIntervalSince(snapshot.observedAt) <= maxAge else {
                return nil
            }
            return snapshot
        }
    }

    private static func authorizedTargetKey(workspaceID: String,
                                            socketComponent: String,
                                            sessionID: String) -> String {
        [workspaceID, socketComponent, sessionID].joined(separator: "|")
    }
}

protocol OrdinaryTmuxRouteRefreshing: Sendable {
    func refreshedRoute(_ route: OrdinaryTmuxPanelRoute) throws -> OrdinaryTmuxPanelRoute
    func route(for logicalID: OrdinaryTmuxLogicalPanelID,
               authorizedTarget: OrdinaryTmuxAuthorizedTarget) throws -> OrdinaryTmuxPanelRoute
    func captureOutput(route: OrdinaryTmuxPanelRoute, maxLines: Int) throws -> OrdinaryTmuxCapturedOutput
    func captureANSIOutput(route: OrdinaryTmuxPanelRoute, maxLines: Int) throws -> OrdinaryTmuxCapturedOutput
}

protocol OrdinaryTmuxTerminalStreaming: Sendable {
    func bootstrapStrictTerminalStream(refreshedRoute: OrdinaryTmuxPanelRoute,
                                       outputFilePath: String,
                                       subscriptionID: String) throws -> OrdinaryTmuxTerminalStateV1
    func bootstrapTerminalStream(refreshedRoute: OrdinaryTmuxPanelRoute,
                                 outputFilePath: String,
                                 maxLines: Int) throws -> OrdinaryTmuxTerminalStreamBootstrap
    func startPipePane(route: OrdinaryTmuxPanelRoute, outputFilePath: String) throws -> OrdinaryTmuxPanelRoute
    func stopPipePane(route: OrdinaryTmuxPanelRoute) throws
    func stopPipePane(exactRoute: OrdinaryTmuxPanelRoute) throws
    func queryCursorPosition(route: OrdinaryTmuxPanelRoute) throws -> OrdinaryTmuxCursorPosition?
    func queryCursorPosition(exactRoute: OrdinaryTmuxPanelRoute) throws -> OrdinaryTmuxCursorPosition?
    func queryStrictTerminalFingerprint(exactRoute: OrdinaryTmuxPanelRoute) throws -> OrdinaryTmuxTerminalFingerprintV1?
}

extension OrdinaryTmuxTerminalStreaming {
    func bootstrapStrictTerminalStream(refreshedRoute: OrdinaryTmuxPanelRoute,
                                       outputFilePath: String,
                                       subscriptionID: String) throws -> OrdinaryTmuxTerminalStateV1 {
        throw BridgeInternalError.invalidResponse
    }

    func queryStrictTerminalFingerprint(exactRoute: OrdinaryTmuxPanelRoute) throws -> OrdinaryTmuxTerminalFingerprintV1? {
        nil
    }
}

struct OrdinaryTmuxTerminalStreamBootstrap: Equatable, Sendable {
    let route: OrdinaryTmuxPanelRoute
    let initialOutput: OrdinaryTmuxCapturedOutput
}

struct OrdinaryTmuxCapturedOutput: Equatable, Sendable {
    let output: String
    let cursorRow: Int?
    let cursorColumn: Int?
    let cursorVisible: Bool?

    init(output: String,
         cursorRow: Int?,
         cursorColumn: Int?,
         cursorVisible: Bool? = nil) {
        self.output = output
        self.cursorRow = cursorRow
        self.cursorColumn = cursorColumn
        self.cursorVisible = cursorVisible
    }
}

enum OrdinaryTmuxPastePresentationDecision {
    static func isReady(
        capture: OrdinaryTmuxCapturedOutput,
        expectedText: String
    ) -> Bool {
        let expectedKey = ChatSubmitEchoRegistry.normalizedKey(expectedText)
        guard expectedKey.isEmpty == false,
              capture.cursorVisible == true,
              let cursorRow = capture.cursorRow,
              let cursorColumn = capture.cursorColumn,
              cursorColumn >= expectedText.count else {
            return false
        }
        let lines = capture.output.split(
            separator: "\n",
            omittingEmptySubsequences: false
        )
        guard lines.indices.contains(cursorRow) else {
            return false
        }
        let cursorLineKey = ChatSubmitEchoRegistry.normalizedKey(
            String(lines[cursorRow])
        )
        return cursorLineKey.hasSuffix(expectedKey)
    }
}

struct OrdinaryTmuxPastePresentationGate {
    let maximumAttempts: Int
    let waitBetweenAttempts: () -> Void

    static let live = OrdinaryTmuxPastePresentationGate(
        maximumAttempts: 20,
        waitBetweenAttempts: { usleep(25_000) }
    )

    func waitUntilReady(_ probe: () throws -> Bool) rethrows -> Bool {
        guard maximumAttempts > 0 else { return false }
        for attempt in 0..<maximumAttempts {
            if try probe() {
                return true
            }
            if attempt + 1 < maximumAttempts {
                waitBetweenAttempts()
            }
        }
        return false
    }
}

final class OrdinaryTmuxInputSubmissionStore: @unchecked Sendable {
    private let queue = DispatchQueue(
        label: "com.tidey.remote-bridge.ordinary-tmux-input-submission-store"
    )
    private var submissionIDByRouteKey = [String: String]()

    func reserve(submissionID: String, routeKey: String) -> Bool {
        queue.sync {
            guard let currentSubmissionID = submissionIDByRouteKey[routeKey] else {
                submissionIDByRouteKey[routeKey] = submissionID
                return true
            }
            return currentSubmissionID == submissionID
        }
    }

    func isCurrent(submissionID: String, routeKey: String) -> Bool {
        queue.sync {
            submissionIDByRouteKey[routeKey] == submissionID
        }
    }

    func release(submissionID: String, routeKey: String) {
        queue.sync {
            guard submissionIDByRouteKey[routeKey] == submissionID else { return }
            submissionIDByRouteKey.removeValue(forKey: routeKey)
        }
    }
}

struct OrdinaryTmuxCursorPosition: Equatable, Sendable {
    let row: Int
    let column: Int
    let cursorVisible: Bool

    init(row: Int, column: Int, cursorVisible: Bool = true) {
        self.row = row
        self.column = column
        self.cursorVisible = cursorVisible
    }
}

protocol OrdinaryTmuxRouteResolving: Sendable {
    func route(forPanelID panelID: String, workspaceID: String?) throws -> OrdinaryTmuxPanelRoute?
}

final class OrdinaryTmuxRouteResolver: OrdinaryTmuxRouteResolving, @unchecked Sendable {
    private let registry: OrdinaryTmuxPanelRegistry
    private let adapter: OrdinaryTmuxRouteRefreshing
    private let now: @Sendable () -> Date

    init(registry: OrdinaryTmuxPanelRegistry,
         adapter: OrdinaryTmuxRouteRefreshing = OrdinaryTmuxCLIAdapter(),
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.registry = registry
        self.adapter = adapter
        self.now = now
    }

    func route(forPanelID panelID: String, workspaceID: String? = nil) throws -> OrdinaryTmuxPanelRoute? {
        if let route = registry.route(forPanelID: panelID) {
            guard workspaceID == nil || workspaceID == route.workspaceID else {
                return nil
            }
            return route
        }

        guard let logicalID = OrdinaryTmuxLogicalPanelID(rawValue: panelID),
              let target = registry.authorizedTarget(for: logicalID, workspaceID: workspaceID, now: now()) else {
            return nil
        }

        let route = try adapter.route(for: logicalID, authorizedTarget: target)
        registry.storeRoute(route, observedAt: now())
        return route
    }
}

// EXPLICIT input semantics — the caller (BridgeInputActionHandler) knows
// whether a payload is a chat MESSAGE or raw terminal keys; the transport
// must never guess from the characters.
enum OrdinaryTmuxInputMode: Sendable, Equatable {
    // The whole payload is ONE verbatim chat text: load + bracketed paste
    // (-p -r), never split — the vendor plan submits with a separate Enter
    // step. Tabs, CRLF, interior CR, ANSI or trailing newlines all stay
    // literal.
    case literalChatText
    // Legacy raw semantics for terminal_input / prompt controls / the chat
    // Enter step: a trailing CR/LF becomes send-keys Enter, and the paste
    // is raw so Esc/Tab/arrows/Ctrl-C still act as keys.
    case rawTerminalInput
}

protocol OrdinaryTmuxInputRouting: Sendable {
    func sendInput(_ input: String,
                   toPanelID panelID: String,
                   mode: OrdinaryTmuxInputMode,
                   allowAmbiguousPasteTimeout: Bool) throws -> Bool
    func waitForLastPastePresentation(toPanelID panelID: String) throws -> Bool
    func sendInput(_ input: String,
                   toPanelID panelID: String,
                   mode: OrdinaryTmuxInputMode,
                   allowAmbiguousPasteTimeout: Bool,
                   submissionID: String?) throws -> Bool
    func waitForLastPastePresentation(toPanelID panelID: String,
                                      submissionID: String) throws -> Bool
    func cancelInputSubmission(toPanelID panelID: String,
                               submissionID: String)
}

extension OrdinaryTmuxInputRouting {
    func waitForLastPastePresentation(toPanelID panelID: String) throws -> Bool {
        false
    }

    func sendInput(_ input: String,
                   toPanelID panelID: String,
                   mode: OrdinaryTmuxInputMode,
                   allowAmbiguousPasteTimeout: Bool,
                   submissionID: String?) throws -> Bool {
        try sendInput(
            input,
            toPanelID: panelID,
            mode: mode,
            allowAmbiguousPasteTimeout: allowAmbiguousPasteTimeout
        )
    }

    func waitForLastPastePresentation(toPanelID panelID: String,
                                      submissionID: String) throws -> Bool {
        try waitForLastPastePresentation(toPanelID: panelID)
    }

    func cancelInputSubmission(toPanelID panelID: String,
                               submissionID: String) {}

    func sendInput(_ input: String, toPanelID panelID: String) throws -> Bool {
        try sendInput(input,
                      toPanelID: panelID,
                      mode: .rawTerminalInput,
                      allowAmbiguousPasteTimeout: false)
    }

    func sendInput(_ input: String,
                   toPanelID panelID: String,
                   mode: OrdinaryTmuxInputMode) throws -> Bool {
        try sendInput(input,
                      toPanelID: panelID,
                      mode: mode,
                      allowAmbiguousPasteTimeout: false)
    }

    func sendInput(_ input: String,
                   toPanelID panelID: String,
                   allowAmbiguousPasteTimeout: Bool) throws -> Bool {
        try sendInput(input,
                      toPanelID: panelID,
                      mode: .rawTerminalInput,
                      allowAmbiguousPasteTimeout: allowAmbiguousPasteTimeout)
    }
}

final class OrdinaryTmuxInputRouter: OrdinaryTmuxInputRouting {
    private let routeResolver: OrdinaryTmuxRouteResolving
    private let adapter: OrdinaryTmuxCLIAdapter
    private let pastePresentationGate: OrdinaryTmuxPastePresentationGate
    private let inputSubmissionStore: OrdinaryTmuxInputSubmissionStore
    private let lastPastePaneStore = OrdinaryTmuxLastPastePaneStore()

    init(registry: OrdinaryTmuxPanelRegistry,
         adapter: OrdinaryTmuxCLIAdapter = OrdinaryTmuxCLIAdapter(),
         pastePresentationGate: OrdinaryTmuxPastePresentationGate = .live,
         inputSubmissionStore: OrdinaryTmuxInputSubmissionStore = OrdinaryTmuxInputSubmissionStore()) {
        self.routeResolver = OrdinaryTmuxRouteResolver(registry: registry, adapter: adapter)
        self.adapter = adapter
        self.pastePresentationGate = pastePresentationGate
        self.inputSubmissionStore = inputSubmissionStore
    }

    init(routeResolver: OrdinaryTmuxRouteResolving,
         adapter: OrdinaryTmuxCLIAdapter = OrdinaryTmuxCLIAdapter(),
         pastePresentationGate: OrdinaryTmuxPastePresentationGate = .live,
         inputSubmissionStore: OrdinaryTmuxInputSubmissionStore = OrdinaryTmuxInputSubmissionStore()) {
        self.routeResolver = routeResolver
        self.adapter = adapter
        self.pastePresentationGate = pastePresentationGate
        self.inputSubmissionStore = inputSubmissionStore
    }

    func sendInput(_ input: String,
                   toPanelID panelID: String,
                   mode: OrdinaryTmuxInputMode = .rawTerminalInput,
                   allowAmbiguousPasteTimeout: Bool = false) throws -> Bool {
        guard let route = try routeResolver.route(forPanelID: panelID, workspaceID: nil) else {
            return false
        }
        let routeKey = Self.lastPastePaneKey(for: route)
        let fallbackEnterPaneID = lastPastePaneStore.paneID(for: routeKey)
        let delivery = try adapter.sendInput(input,
                                             route: route,
                                             mode: mode,
                                             fallbackEnterPaneID: fallbackEnterPaneID,
                                             allowAmbiguousPasteTimeout: allowAmbiguousPasteTimeout)
        lastPastePaneStore.record(
            delivery: delivery,
            route: route,
            routeKey: routeKey,
            pastedText: input
        )
        return true
    }

    func waitForLastPastePresentation(toPanelID panelID: String) throws -> Bool {
        guard let route = try routeResolver.route(forPanelID: panelID, workspaceID: nil),
              let pending = lastPastePaneStore.pending(
                for: Self.lastPastePaneKey(for: route)
              ) else {
            return false
        }
        return try pastePresentationGate.waitUntilReady {
            try adapter.isPastedTextPresented(
                pending.text,
                exactRoute: pending.route,
                paneID: pending.paneID
            )
        }
    }

    private static func lastPastePaneKey(for route: OrdinaryTmuxPanelRoute) -> String {
        [
            route.panelID,
            route.socket.cacheKey,
            route.sessionID,
            route.windowID,
        ].joined(separator: "|")
    }
}

private final class OrdinaryTmuxLastPastePaneStore: @unchecked Sendable {
    struct PendingPaste {
        let paneID: String
        let route: OrdinaryTmuxPanelRoute
        let text: String
    }

    private let queue = DispatchQueue(label: "com.tidey.remote-bridge.ordinary-tmux-input-router.last-paste-pane")
    private var pendingByRouteKey = [String: PendingPaste]()

    func paneID(for routeKey: String) -> String? {
        queue.sync {
            pendingByRouteKey[routeKey]?.paneID
        }
    }

    func pending(for routeKey: String) -> PendingPaste? {
        queue.sync {
            pendingByRouteKey[routeKey]
        }
    }

    func record(delivery: OrdinaryTmuxInputDelivery,
                route: OrdinaryTmuxPanelRoute,
                routeKey: String,
                pastedText: String) {
        queue.sync {
            if delivery.pastedText && !delivery.sentEnter {
                pendingByRouteKey[routeKey] = PendingPaste(
                    paneID: delivery.paneID,
                    route: route,
                    text: pastedText
                )
            } else if delivery.sentEnter {
                pendingByRouteKey.removeValue(forKey: routeKey)
            }
        }
    }
}

private extension OrdinaryTmuxSocketSelector {
    var stablePanelIDComponent: String {
        switch self {
        case .defaultSocket:
            return "runtime-default"
        case .path(let path):
            return path
        case .name(let name):
            return "name:\(name)"
        }
    }
}
