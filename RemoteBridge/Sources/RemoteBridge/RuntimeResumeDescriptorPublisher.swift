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

struct RuntimeResumeAgentRegistrySnapshot:
    Equatable,
    Sendable {
    let sourceRecordCount: Int
    let resolvedCandidateCount: Int
    let records: [RuntimeResumeAgentRegistryRecord]

    var isComplete: Bool {
        sourceRecordCount == resolvedCandidateCount &&
            resolvedCandidateCount == records.count
    }
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
        struct Candidate {
            let route: OrdinaryTmuxPanelRoute
            let record: RuntimeResumeAgentRegistryRecord
        }

        var candidatesByCarrier = [String: [Candidate]]()
        var durableResumeKeys = Set<String>()
        for record in records {
            guard let paneID = record.binding.tmuxPaneID,
                  let route = registry.route(
                    forPanelID: record.binding.panelID
                  ) else {
                return []
            }
            let key = Self.carrierKey(for: route)
            guard route.workspaceID == record.binding.workspaceID,
                  route.activePaneID == paneID else {
                return []
            }
            let durableResumeKey = [
                record.vendor.rawValue,
                record.durableResumeID,
            ].joined(separator: "|")
            guard durableResumeKeys
                .insert(durableResumeKey).inserted else {
                return []
            }
            candidatesByCarrier[key, default: []].append(
                Candidate(route: route, record: record)
            )
        }

        var plans = [RuntimeResumeTmuxCarrierPublicationPlan]()
        for key in candidatesByCarrier.keys.sorted() {
            guard let candidates = candidatesByCarrier[key],
                  let anchor = candidates.first else {
                return []
            }
            let routes = registry.routes(
                workspaceID: anchor.route.workspaceID,
                carrierPanelID: anchor.route.carrierPanelID,
                socket: anchor.route.socket,
                sessionID: anchor.route.sessionID
            )
            guard routes.isEmpty == false,
                  routes.allSatisfy({
                      Self.carrierKey(for: $0) == key
                  }),
                  let state = try sessionReader
                    .runtimeResumeSessionState(for: anchor.route),
                  state.sessionID == anchor.route.sessionID,
                  let sessionName = Self.nonEmpty(
                    state.sessionName
                  ),
                  let plan = Self.makePlan(
                    candidates: candidates.map {
                        ($0.route, $0.record)
                    },
                    state: state,
                    sessionName: sessionName
                  ) else {
                return []
            }
            plans.append(plan)
        }
        return plans.sorted {
            let lhs = [
                $0.binding.workspaceID,
                $0.binding.panelID,
                $0.binding.tmuxPaneID ?? "",
            ]
            let rhs = [
                $1.binding.workspaceID,
                $1.binding.panelID,
                $1.binding.tmuxPaneID ?? "",
            ]
            return lhs.lexicographicallyPrecedes(rhs)
        }
    }

    private static func makePlan(
        candidates: [(
            route: OrdinaryTmuxPanelRoute,
            record: RuntimeResumeAgentRegistryRecord
        )],
        state: RuntimeResumeTmuxSessionState,
        sessionName: String
    ) -> RuntimeResumeTmuxCarrierPublicationPlan? {
        guard let anchor = candidates.first else {
            return nil
        }
        var recordsByPaneID =
            [String: RuntimeResumeAgentRegistryRecord]()
        var durableKeys = Set<String>()
        for candidate in candidates {
            guard let paneID = candidate.record.binding.tmuxPaneID,
                  recordsByPaneID[paneID] == nil else {
                return nil
            }
            let durableKey = [
                candidate.record.vendor.rawValue,
                candidate.record.durableResumeID,
            ].joined(separator: "|")
            guard durableKeys.insert(durableKey).inserted else {
                return nil
            }
            recordsByPaneID[paneID] = candidate.record
        }

        let sortedWindows = state.windows.sorted {
            if $0.index != $1.index {
                return $0.index < $1.index
            }
            return $0.windowID < $1.windowID
        }
        let activeWindows = sortedWindows.filter(\.isActive)
        guard sortedWindows.isEmpty == false,
              Set(sortedWindows.map(\.windowID)).count ==
                sortedWindows.count,
              Set(sortedWindows.map(\.index)).count ==
                sortedWindows.count,
              activeWindows.count == 1,
              let activeWindow = activeWindows.first else {
            return nil
        }

        var seenPaneIDs = Set<String>()
        var topologyWindows = [RuntimeResumeTmuxWindow]()
        var activePaneID: String?
        var activePaneIndex: Int?
        for window in sortedWindows {
            let sortedPanes = window.panes.sorted {
                if $0.index != $1.index {
                    return $0.index < $1.index
                }
                return $0.paneID < $1.paneID
            }
            guard sortedPanes.isEmpty == false,
                  Set(sortedPanes.map(\.index)).count ==
                    sortedPanes.count,
                  sortedPanes.allSatisfy({
                      seenPaneIDs.insert($0.paneID).inserted
                  }) else {
                return nil
            }
            if window.windowID == activeWindow.windowID {
                let activePanes = sortedPanes.filter(\.isActive)
                guard activePanes.count == 1,
                      let pane = activePanes.first else {
                    return nil
                }
                activePaneID = pane.paneID
                activePaneIndex = pane.index
            }
            topologyWindows.append(
                RuntimeResumeTmuxWindow(
                    index: window.index,
                    name: window.name,
                    panes: sortedPanes.map {
                        RuntimeResumeTmuxPane(
                            index: $0.index,
                            workingDirectory:
                                $0.workingDirectory,
                            launch:
                                recordsByPaneID[$0.paneID]?.launch
                        )
                    }
                )
            )
        }
        guard recordsByPaneID.keys.allSatisfy(
                seenPaneIDs.contains
              ),
              let activePaneID,
              let activePaneIndex else {
            return nil
        }

        let target: RuntimeResumeTmuxTarget
        switch anchor.route.socket {
        case .defaultSocket:
            target = RuntimeResumeTmuxTarget(
                defaultSocketAndTmuxSession: sessionName
            )
        case .path(let path):
            target = RuntimeResumeTmuxTarget(
                socketPath: path,
                tmuxSession: sessionName
            )
        case .name(let name):
            target = RuntimeResumeTmuxTarget(
                socketName: name,
                tmuxSession: sessionName
            )
        }
        return RuntimeResumeTmuxCarrierPublicationPlan(
            binding: RuntimeResumeDescriptorBinding(
                workspaceID: anchor.route.workspaceID,
                panelID: anchor.route.carrierPanelID,
                tmuxPaneID: activePaneID
            ),
            target: target,
            topology: RuntimeResumeTmuxTopology(
                windows: topologyWindows,
                activeWindowIndex: activeWindow.index,
                activePaneIndex: activePaneIndex
            )
        )
    }

    private static func carrierKey(
        for route: OrdinaryTmuxPanelRoute
    ) -> String {
        [
            route.workspaceID,
            route.carrierPanelID,
            route.socket.cacheKey,
            route.sessionID,
        ].joined(separator: "|")
    }

    private static func nonEmpty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        return trimmed.isEmpty ? nil : trimmed
    }
}

protocol RuntimeResumeAgentRegistryReading: Sendable {
    func readAgentRegistrySnapshot()
        throws -> RuntimeResumeAgentRegistrySnapshot
}

extension RuntimeResumeAgentRegistryReading {
    func readAgentRegistryRecords()
        throws -> [RuntimeResumeAgentRegistryRecord] {
        try readAgentRegistrySnapshot().records
    }
}

final class AgentSessionRegistryRuntimeResumeReader:
    RuntimeResumeAgentRegistryReading,
    @unchecked Sendable {
    private let monitor: AgentSessionRegistryMonitor

    init(monitor: AgentSessionRegistryMonitor) {
        self.monitor = monitor
    }

    func readAgentRegistrySnapshot()
        throws -> RuntimeResumeAgentRegistrySnapshot {
        monitor.currentRuntimeResumeAgentSnapshot()
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

enum RuntimeResumeDescriptorPublisherError:
    Error,
    Equatable,
    Sendable {
    case incompleteRegistrySnapshot(
        sourceRecordCount: Int,
        resolvedCandidateCount: Int,
        publishedRecordCount: Int
    )
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

struct RuntimeResumeDescriptorSlot:
    Equatable,
    Hashable,
    Sendable {
    let workspaceID: String
    let panelID: String

    init(workspaceID: String, panelID: String) {
        self.workspaceID = workspaceID
        self.panelID = panelID
    }

    init(binding: RuntimeResumeDescriptorBinding) {
        workspaceID = binding.workspaceID
        panelID = binding.panelID
    }
}

struct RuntimeResumeStoredDescriptor:
    Equatable,
    Sendable {
    let slot: RuntimeResumeDescriptorSlot
    let revision: Int64
    let content: RuntimeResumeDescriptorContent
}

struct RuntimeResumeDescriptorSocketRemoval:
    Equatable,
    Sendable {
    let slot: RuntimeResumeDescriptorSlot
    let expectedRevision: Int64
    let expectedContent: RuntimeResumeDescriptorContent
}

protocol RuntimeResumeDescriptorSocketSending: Sendable {
    func send(
        _ update: RuntimeResumeDescriptorSocketUpdate
    ) throws
}

protocol RuntimeResumeDescriptorInventoryReconciling: Sendable {
    func currentAgentDescriptors()
        throws -> [RuntimeResumeStoredDescriptor]
    func remove(
        _ removal: RuntimeResumeDescriptorSocketRemoval
    ) throws -> Bool
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
    private let carrierPlanner:
        RuntimeResumeTmuxCarrierPlanning?
    private let canonicalizer:
        RuntimeResumeDescriptorCanonicalizer
    private let inventoryReconciler:
        RuntimeResumeDescriptorInventoryReconciling?
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
        carrierPlanner:
            RuntimeResumeTmuxCarrierPlanning? = nil,
        canonicalizer:
            RuntimeResumeDescriptorCanonicalizer =
                RuntimeResumeDescriptorCanonicalizer(),
        inventoryReconciler:
            RuntimeResumeDescriptorInventoryReconciling? = nil,
        socketSender:
            RuntimeResumeDescriptorSocketSending,
        queue: DispatchQueue = DispatchQueue(
            label:
                "com.tidey.remote-bridge.runtime-resume-publisher"
        )
    ) {
        self.registryReader = registryReader
        self.topologyReader = topologyReader
        self.carrierPlanner = carrierPlanner
        self.canonicalizer = canonicalizer
        self.inventoryReconciler = inventoryReconciler
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
        let snapshot =
            try registryReader.readAgentRegistrySnapshot()
        guard snapshot.isComplete else {
            throw RuntimeResumeDescriptorPublisherError
                .incompleteRegistrySnapshot(
                    sourceRecordCount:
                        snapshot.sourceRecordCount,
                    resolvedCandidateCount:
                        snapshot.resolvedCandidateCount,
                    publishedRecordCount:
                        snapshot.records.count
                )
        }
        let records = snapshot.records.sorted(
            by: Self.recordPrecedes(_:_:)
        )
        for record in records where record.binding.tmuxPaneID == nil {
            let agent = RuntimeResumeAgentSpecification(
                vendor: record.vendor,
                durableResumeID: record.durableResumeID,
                launch: record.launch
            )
            let content = RuntimeResumeDescriptorContent(
                descriptorVersion: 1,
                kind: .agent,
                restorePolicy: .directResume,
                target: nil,
                topology: nil,
                agent: agent
            )
            try publish(content: content, binding: record.binding)
        }

        let tmuxRecords = records.filter {
            $0.binding.tmuxPaneID != nil
        }
        if let carrierPlanner {
            for plan in try carrierPlanner.publicationPlans(
                for: tmuxRecords
            ) {
                try publish(
                    content: RuntimeResumeDescriptorContent(
                        descriptorVersion: 2,
                        kind: .agent,
                        restorePolicy: .create,
                        target: plan.target,
                        topology: plan.topology,
                        agent: nil
                    ),
                    binding: plan.binding
                )
            }
        } else {
            for record in tmuxRecords {
                let agent = RuntimeResumeAgentSpecification(
                    vendor: record.vendor,
                    durableResumeID: record.durableResumeID,
                    launch: record.launch
                )
                guard let snapshot =
                        try topologyReader.topologySnapshot(
                            for: record.binding
                        ),
                      snapshot.binding == record.binding else {
                    continue
                }
                try publish(
                    content: RuntimeResumeDescriptorContent(
                        descriptorVersion: 1,
                        kind: .agent,
                        restorePolicy: .create,
                        target: snapshot.target,
                        topology: snapshot.topology,
                        agent: agent
                    ),
                    binding: record.binding
                )
            }
        }
    }

    private func publish(
        content: RuntimeResumeDescriptorContent,
        binding: RuntimeResumeDescriptorBinding
    ) throws {
        let canonicalContent =
            try canonicalizer.canonicalize(content)
        guard reducer.decision(
            binding: binding,
            canonicalContent: canonicalContent
        ) == .publish else {
            return
        }
        try socketSender.send(
            RuntimeResumeDescriptorSocketUpdate(
                binding: binding,
                content: canonicalContent.content
            )
        )
        reducer.acknowledgePublished(
            binding: binding,
            canonicalContent: canonicalContent
        )
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
