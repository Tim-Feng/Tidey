import CryptoKit
import Foundation

enum RuntimeResumeDescriptorKind: String, Codable, Sendable {
    case ordinaryTmux = "ordinary_tmux"
    case agent
    case generic
}

enum RuntimeResumeRestorePolicy: String, Codable, Sendable {
    case create
    case attachOnly = "attach_only"
    case runtime
    case directResume = "direct_resume"
}

enum RuntimeResumeAgentVendor: String, Codable, Sendable {
    case claude
    case codex
}

enum RuntimeResumeTmuxSocketEndpointKind:
    String,
    Codable,
    Sendable {
    case path
    case name
    case defaultSocket = "default"
}

struct RuntimeResumeDescriptorBinding:
    Codable,
    Equatable,
    Hashable,
    Sendable {
    let workspaceID: String
    let panelID: String
    let tmuxPaneID: String?

    enum CodingKeys: String, CodingKey {
        case workspaceID = "workspace_id"
        case panelID = "panel_id"
        case tmuxPaneID = "tmux_pane_id"
    }
}

struct RuntimeResumeLaunchSpecification:
    Codable,
    Equatable,
    Sendable {
    let executable: String
    let arguments: [String]
    let workingDirectory: String?

    enum CodingKeys: String, CodingKey {
        case executable
        case arguments
        case workingDirectory = "cwd"
    }
}

struct RuntimeResumeTmuxTarget:
    Codable,
    Equatable,
    Sendable {
    let socketEndpointKind:
        RuntimeResumeTmuxSocketEndpointKind
    let socketPath: String?
    let socketName: String?
    let tmuxSession: String

    init(socketPath: String, tmuxSession: String) {
        socketEndpointKind = .path
        self.socketPath = socketPath
        socketName = nil
        self.tmuxSession = tmuxSession
    }

    init(socketName: String, tmuxSession: String) {
        socketEndpointKind = .name
        socketPath = nil
        self.socketName = socketName
        self.tmuxSession = tmuxSession
    }

    init(defaultSocketAndTmuxSession tmuxSession: String) {
        socketEndpointKind = .defaultSocket
        socketPath = nil
        socketName = nil
        self.tmuxSession = tmuxSession
    }

    enum CodingKeys: String, CodingKey {
        case socketEndpointKind = "socket_endpoint_kind"
        case socketPath = "socket_path"
        case socketName = "socket_name"
        case tmuxSession = "tmux_session"
    }
}

struct RuntimeResumeTmuxPane:
    Codable,
    Equatable,
    Sendable {
    let index: Int
    let workingDirectory: String?
    let launch: RuntimeResumeLaunchSpecification?

    enum CodingKeys: String, CodingKey {
        case index
        case workingDirectory = "cwd"
        case launch
    }
}

struct RuntimeResumeTmuxWindow:
    Codable,
    Equatable,
    Sendable {
    let index: Int
    let name: String?
    let panes: [RuntimeResumeTmuxPane]
}

struct RuntimeResumeTmuxTopology:
    Codable,
    Equatable,
    Sendable {
    let windows: [RuntimeResumeTmuxWindow]
    let activeWindowIndex: Int
    let activePaneIndex: Int

    enum CodingKeys: String, CodingKey {
        case windows
        case activeWindowIndex = "active_window_index"
        case activePaneIndex = "active_pane_index"
    }
}

struct RuntimeResumeAgentSpecification:
    Codable,
    Equatable,
    Sendable {
    let vendor: RuntimeResumeAgentVendor
    let durableResumeID: String
    let launch: RuntimeResumeLaunchSpecification

    enum CodingKeys: String, CodingKey {
        case vendor
        case durableResumeID = "durable_resume_id"
        case launch
    }
}

struct RuntimeResumeDescriptorContent:
    Codable,
    Equatable,
    Sendable {
    let descriptorVersion: Int
    let kind: RuntimeResumeDescriptorKind
    let restorePolicy: RuntimeResumeRestorePolicy
    let target: RuntimeResumeTmuxTarget?
    let topology: RuntimeResumeTmuxTopology?
    let agent: RuntimeResumeAgentSpecification?

    enum CodingKeys: String, CodingKey {
        case descriptorVersion = "descriptor_version"
        case kind
        case restorePolicy = "restore_policy"
        case target
        case topology
        case agent
    }
}

struct RuntimeResumeAgentRegistryRecord:
    Equatable,
    Sendable {
    let binding: RuntimeResumeDescriptorBinding
    let vendor: RuntimeResumeAgentVendor
    let durableResumeID: String
    let launch: RuntimeResumeLaunchSpecification
}

struct RuntimeResumeTmuxTopologySnapshot:
    Equatable,
    Sendable {
    let binding: RuntimeResumeDescriptorBinding
    let target: RuntimeResumeTmuxTarget
    let topology: RuntimeResumeTmuxTopology
}

struct RuntimeResumeTmuxPaneState:
    Equatable,
    Sendable {
    let paneID: String
    let index: Int
    let workingDirectory: String?
    let isActive: Bool
}

struct RuntimeResumeTmuxWindowState:
    Equatable,
    Sendable {
    let windowID: String
    let index: Int
    let name: String?
    let isActive: Bool
    let panes: [RuntimeResumeTmuxPaneState]
}

struct RuntimeResumeTmuxSessionState:
    Equatable,
    Sendable {
    let sessionID: String
    let sessionName: String
    let windows: [RuntimeResumeTmuxWindowState]
}

protocol RuntimeResumeTmuxSessionReading: Sendable {
    func runtimeResumeSessionState(
        for route: OrdinaryTmuxPanelRoute
    ) throws -> RuntimeResumeTmuxSessionState?
}

struct RuntimeResumeTmuxCarrierPublicationPlan:
    Equatable,
    Sendable {
    let binding: RuntimeResumeDescriptorBinding
    let target: RuntimeResumeTmuxTarget
    let topology: RuntimeResumeTmuxTopology
}

protocol RuntimeResumeTmuxCarrierPlanning: Sendable {
    func publicationPlans(
        for records: [RuntimeResumeAgentRegistryRecord]
    ) throws -> [RuntimeResumeTmuxCarrierPublicationPlan]
}

final class OrdinaryTmuxRuntimeResumeCarrierPlanner:
    RuntimeResumeTmuxCarrierPlanning,
    @unchecked Sendable {
    private let registry: OrdinaryTmuxPanelRegistry
    private let sessionReader: RuntimeResumeTmuxSessionReading

    init(
        registry: OrdinaryTmuxPanelRegistry,
        sessionReader: RuntimeResumeTmuxSessionReading
    ) {
        self.registry = registry
        self.sessionReader = sessionReader
    }

    func publicationPlans(
        for records: [RuntimeResumeAgentRegistryRecord]
    ) throws -> [RuntimeResumeTmuxCarrierPublicationPlan] {
        _ = registry
        _ = sessionReader
        _ = records
        return []
    }
}

protocol RuntimeResumeAgentRegistryReading: Sendable {
    func readAgentRegistryRecords()
        throws -> [RuntimeResumeAgentRegistryRecord]
}

final class AgentSessionRegistryRuntimeResumeReader:
    RuntimeResumeAgentRegistryReading,
    @unchecked Sendable {
    private let monitor: AgentSessionRegistryMonitor

    init(monitor: AgentSessionRegistryMonitor) {
        self.monitor = monitor
    }

    func readAgentRegistryRecords()
        throws -> [RuntimeResumeAgentRegistryRecord] {
        monitor.currentRuntimeResumeAgentRecords()
    }
}

protocol RuntimeResumeTmuxTopologyReading: Sendable {
    func topologySnapshot(
        for binding: RuntimeResumeDescriptorBinding
    ) throws -> RuntimeResumeTmuxTopologySnapshot?
}

final class OrdinaryTmuxRuntimeResumeTopologyReader:
    RuntimeResumeTmuxTopologyReading,
    @unchecked Sendable {
    private let registry: OrdinaryTmuxPanelRegistry

    init(registry: OrdinaryTmuxPanelRegistry) {
        self.registry = registry
    }

    func topologySnapshot(
        for binding: RuntimeResumeDescriptorBinding
    ) throws -> RuntimeResumeTmuxTopologySnapshot? {
        guard let tmuxPaneID = binding.tmuxPaneID,
              let activeRoute =
                registry.route(forPanelID: binding.panelID),
              activeRoute.workspaceID == binding.workspaceID,
              activeRoute.activePaneID == tmuxPaneID else {
            return nil
        }
        let routes = registry.routes(
            workspaceID: binding.workspaceID,
            socket: activeRoute.socket,
            sessionID: activeRoute.sessionID
        )
        guard routes.isEmpty == false else {
            return nil
        }
        let routesByWindowIndex =
            Dictionary(grouping: routes, by: \.windowIndex)
        let sortedPaneRoutesByWindowIndex =
            routesByWindowIndex.mapValues {
                $0.sorted {
                    if $0.activePaneID != $1.activePaneID {
                        return $0.activePaneID < $1.activePaneID
                    }
                    return $0.panelID < $1.panelID
                }
            }
        let windows = routesByWindowIndex.keys.sorted().map {
            windowIndex in
            let paneRoutes =
                sortedPaneRoutesByWindowIndex[windowIndex] ?? []
            return RuntimeResumeTmuxWindow(
                index: windowIndex,
                name: nil,
                panes: paneRoutes.enumerated().map {
                    paneIndex, route in
                    RuntimeResumeTmuxPane(
                        index: paneIndex,
                        workingDirectory: route.cwd,
                        launch: nil
                    )
                }
            )
        }
        guard let activePaneIndex =
                sortedPaneRoutesByWindowIndex[
                    activeRoute.windowIndex
                ]?.firstIndex(where: {
                    $0.activePaneID == tmuxPaneID
                }) else {
            return nil
        }
        let target: RuntimeResumeTmuxTarget
        let trimmedSessionName =
            activeRoute.sessionName.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
        let tmuxSession = trimmedSessionName.isEmpty
            ? activeRoute.sessionID
            : trimmedSessionName
        switch activeRoute.socket {
        case .defaultSocket:
            target = RuntimeResumeTmuxTarget(
                defaultSocketAndTmuxSession: tmuxSession
            )
        case .path(let path):
            target = RuntimeResumeTmuxTarget(
                socketPath: path,
                tmuxSession: tmuxSession
            )
        case .name(let name):
            target = RuntimeResumeTmuxTarget(
                socketName: name,
                tmuxSession: tmuxSession
            )
        }
        return RuntimeResumeTmuxTopologySnapshot(
            binding: binding,
            target: target,
            topology: RuntimeResumeTmuxTopology(
                windows: windows,
                activeWindowIndex: activeRoute.windowIndex,
                activePaneIndex: activePaneIndex
            )
        )
    }
}

struct RuntimeResumeDescriptorContentFingerprint:
    Equatable,
    Hashable,
    Sendable {
    let rawValue: String
}

struct RuntimeResumeDescriptorCanonicalContent:
    Equatable,
    Sendable {
    let content: RuntimeResumeDescriptorContent
    let data: Data
    let fingerprint:
        RuntimeResumeDescriptorContentFingerprint
}

struct RuntimeResumeDescriptorCanonicalizer: Sendable {
    func canonicalize(
        _ content: RuntimeResumeDescriptorContent
    ) throws -> RuntimeResumeDescriptorCanonicalContent {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(content)
        let digest = SHA256.hash(data: data)
        let fingerprint =
            digest.map { String(format: "%02x", $0) }.joined()
        return RuntimeResumeDescriptorCanonicalContent(
            content: content,
            data: data,
            fingerprint:
                RuntimeResumeDescriptorContentFingerprint(
                    rawValue: fingerprint
                )
        )
    }
}

enum RuntimeResumeDescriptorPublicationDecision:
    Equatable,
    Sendable {
    case publish
    case unchanged
}

struct RuntimeResumeDescriptorPublicationReducer: Sendable {
    private var publishedFingerprintByBinding =
        [RuntimeResumeDescriptorBinding:
            RuntimeResumeDescriptorContentFingerprint]()

    func decision(
        binding: RuntimeResumeDescriptorBinding,
        canonicalContent:
            RuntimeResumeDescriptorCanonicalContent
    ) -> RuntimeResumeDescriptorPublicationDecision {
        if publishedFingerprintByBinding[binding] ==
                canonicalContent.fingerprint {
            return .unchanged
        }
        return .publish
    }

    mutating func acknowledgePublished(
        binding: RuntimeResumeDescriptorBinding,
        canonicalContent:
            RuntimeResumeDescriptorCanonicalContent
    ) {
        publishedFingerprintByBinding[binding] =
            canonicalContent.fingerprint
    }
}

struct RuntimeResumeDescriptorSocketUpdate:
    Equatable,
    Sendable {
    let binding: RuntimeResumeDescriptorBinding
    let content: RuntimeResumeDescriptorContent
}

protocol RuntimeResumeDescriptorSocketSending: Sendable {
    func send(
        _ update: RuntimeResumeDescriptorSocketUpdate
    ) throws
}

private struct RuntimeResumeDescriptorSocketPayload:
    Encodable {
    let binding: RuntimeResumeDescriptorBinding
    let descriptor: RuntimeResumeDescriptorContent
}

final class TideyRuntimeResumeDescriptorSocketSender:
    RuntimeResumeDescriptorSocketSending,
    @unchecked Sendable {
    private let requestSender: TideyRequestSending

    init(requestSender: TideyRequestSending) {
        self.requestSender = requestSender
    }

    func send(
        _ update: RuntimeResumeDescriptorSocketUpdate
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(
            RuntimeResumeDescriptorSocketPayload(
                binding: update.binding,
                descriptor: update.content
            )
        )
        let params = try JSONDecoder().decode(
            [String: JSONValue].self,
            from: data
        )
        let request = BridgeRequest(
            id: UUID().uuidString,
            action: "update_runtime_resume_descriptor",
            params: params
        )
        let response = try requestSender.send(request)
        guard response.ok else {
            throw BridgeInternalError.invalidResponse
        }
    }
}

final class RuntimeResumeDescriptorPublisher:
    @unchecked Sendable {
    private let registryReader:
        RuntimeResumeAgentRegistryReading
    private let topologyReader:
        RuntimeResumeTmuxTopologyReading
    private let canonicalizer:
        RuntimeResumeDescriptorCanonicalizer
    private let socketSender:
        RuntimeResumeDescriptorSocketSending
    private let queue: DispatchQueue
    private var reducer =
        RuntimeResumeDescriptorPublicationReducer()
    private var timer: DispatchSourceTimer?

    init(
        registryReader:
            RuntimeResumeAgentRegistryReading,
        topologyReader:
            RuntimeResumeTmuxTopologyReading,
        canonicalizer:
            RuntimeResumeDescriptorCanonicalizer =
                RuntimeResumeDescriptorCanonicalizer(),
        socketSender:
            RuntimeResumeDescriptorSocketSending,
        queue: DispatchQueue = DispatchQueue(
            label:
                "com.tidey.remote-bridge.runtime-resume-publisher"
        )
    ) {
        self.registryReader = registryReader
        self.topologyReader = topologyReader
        self.canonicalizer = canonicalizer
        self.socketSender = socketSender
        self.queue = queue
    }

    func publishCurrentDescriptors() throws {
        try queue.sync {
            try publishCurrentDescriptorsOnQueue()
        }
    }

    func start(repeatingInterval: TimeInterval = 5) {
        let interval = max(repeatingInterval, 1)
        queue.async { [weak self] in
            guard let self, timer == nil else {
                return
            }
            let timer = DispatchSource.makeTimerSource(
                queue: queue
            )
            timer.schedule(
                deadline: .now() + interval,
                repeating: interval
            )
            timer.setEventHandler { [weak self] in
                guard let self else {
                    return
                }
                do {
                    try publishCurrentDescriptorsOnQueue()
                } catch {
                    BridgeLogger.server.debug(
                        "runtime resume descriptor publish deferred error=\(String(describing: error), privacy: .public)"
                    )
                }
            }
            self.timer = timer
            timer.resume()
        }
    }

    deinit {
        timer?.cancel()
    }

    private func publishCurrentDescriptorsOnQueue()
        throws {
        let records =
            try registryReader.readAgentRegistryRecords()
                .sorted(by: Self.recordPrecedes(_:_:))
        for record in records {
            let agent = RuntimeResumeAgentSpecification(
                vendor: record.vendor,
                durableResumeID: record.durableResumeID,
                launch: record.launch
            )
            let content: RuntimeResumeDescriptorContent
            if record.binding.tmuxPaneID == nil {
                content = RuntimeResumeDescriptorContent(
                    descriptorVersion: 1,
                    kind: .agent,
                    restorePolicy: .directResume,
                    target: nil,
                    topology: nil,
                    agent: agent
                )
            } else {
                guard let snapshot =
                        try topologyReader.topologySnapshot(
                            for: record.binding
                        ),
                      snapshot.binding == record.binding else {
                    continue
                }
                content = RuntimeResumeDescriptorContent(
                    descriptorVersion: 1,
                    kind: .agent,
                    restorePolicy: .create,
                    target: snapshot.target,
                    topology: snapshot.topology,
                    agent: agent
                )
            }
            let canonicalContent =
                try canonicalizer.canonicalize(content)
            guard reducer.decision(
                binding: record.binding,
                canonicalContent: canonicalContent
            ) == .publish else {
                continue
            }
            try socketSender.send(
                RuntimeResumeDescriptorSocketUpdate(
                    binding: record.binding,
                    content: canonicalContent.content
                )
            )
            reducer.acknowledgePublished(
                binding: record.binding,
                canonicalContent: canonicalContent
            )
        }
    }

    private static func recordPrecedes(
        _ lhs: RuntimeResumeAgentRegistryRecord,
        _ rhs: RuntimeResumeAgentRegistryRecord
    ) -> Bool {
        let lhsKey = [
            lhs.binding.workspaceID,
            lhs.binding.panelID,
            lhs.binding.tmuxPaneID ?? "",
            lhs.vendor.rawValue,
            lhs.durableResumeID,
        ]
        let rhsKey = [
            rhs.binding.workspaceID,
            rhs.binding.panelID,
            rhs.binding.tmuxPaneID ?? "",
            rhs.vendor.rawValue,
            rhs.durableResumeID,
        ]
        return lhsKey.lexicographicallyPrecedes(rhsKey)
    }
}
