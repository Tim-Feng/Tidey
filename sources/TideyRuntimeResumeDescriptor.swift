import Foundation

@objc(TideyRuntimeResumeKind)
enum TideyRuntimeResumeKind: Int {
    case ordinaryTmux
    case agent
    case generic
}

@objc(TideyRuntimeRestorePolicy)
enum TideyRuntimeRestorePolicy: Int {
    case create
    case attachOnly
    case runtime
    case directResume
}

@objc(TideyRuntimeAgentVendor)
enum TideyRuntimeAgentVendor: Int {
    case claude
    case codex
}

@objc(TideyRuntimeTmuxSocketEndpointKind)
enum TideyRuntimeTmuxSocketEndpointKind: Int {
    case path
    case name
    case defaultSocket
}

@objc(TideyRuntimeLaunchSpecification)
@objcMembers
final class TideyRuntimeLaunchSpecification: NSObject {
    let executable: String
    let arguments: [String]
    let workingDirectory: String?

    init(
        executable: String,
        arguments: [String],
        workingDirectory: String?
    ) {
        self.executable = executable
        self.arguments = arguments
        self.workingDirectory = workingDirectory
    }
}

@objc(TideyRuntimeTmuxPaneTopology)
@objcMembers
final class TideyRuntimeTmuxPaneTopology: NSObject {
    let index: Int
    let workingDirectory: String?
    let launch: TideyRuntimeLaunchSpecification?

    init(
        index: Int,
        workingDirectory: String?,
        launch: TideyRuntimeLaunchSpecification?
    ) {
        self.index = index
        self.workingDirectory = workingDirectory
        self.launch = launch
    }
}

@objc(TideyRuntimeTmuxWindowTopology)
@objcMembers
final class TideyRuntimeTmuxWindowTopology: NSObject {
    let index: Int
    let name: String?
    let panes: [TideyRuntimeTmuxPaneTopology]

    init(
        index: Int,
        name: String?,
        panes: [TideyRuntimeTmuxPaneTopology]
    ) {
        self.index = index
        self.name = name
        self.panes = panes
    }
}

@objc(TideyRuntimeTmuxTopology)
@objcMembers
final class TideyRuntimeTmuxTopology: NSObject {
    let windows: [TideyRuntimeTmuxWindowTopology]
    let activeWindowIndex: Int
    let activePaneIndex: Int

    init(
        windows: [TideyRuntimeTmuxWindowTopology],
        activeWindowIndex: Int,
        activePaneIndex: Int
    ) {
        self.windows = windows
        self.activeWindowIndex = activeWindowIndex
        self.activePaneIndex = activePaneIndex
    }
}

@objc(TideyRuntimeResumeTarget)
@objcMembers
final class TideyRuntimeResumeTarget: NSObject {
    let socketEndpointKind: TideyRuntimeTmuxSocketEndpointKind
    let socketPath: String?
    let socketName: String?
    let tmuxSession: String

    init(
        socketPath: String,
        tmuxSession: String
    ) {
        socketEndpointKind = .path
        self.socketPath = socketPath
        socketName = nil
        self.tmuxSession = tmuxSession
    }

    init(
        socketName: String,
        tmuxSession: String
    ) {
        socketEndpointKind = .name
        socketPath = nil
        self.socketName = socketName
        self.tmuxSession = tmuxSession
    }

    @objc(initWithDefaultSocketAndTmuxSession:)
    init(defaultSocketAndTmuxSession tmuxSession: String) {
        socketEndpointKind = .defaultSocket
        socketPath = nil
        socketName = nil
        self.tmuxSession = tmuxSession
    }
}

@objc(TideyRuntimeAgentResumeSpecification)
@objcMembers
final class TideyRuntimeAgentResumeSpecification: NSObject {
    let vendor: TideyRuntimeAgentVendor
    let durableResumeID: String
    let launch: TideyRuntimeLaunchSpecification

    init(
        vendor: TideyRuntimeAgentVendor,
        durableResumeID: String,
        launch: TideyRuntimeLaunchSpecification
    ) {
        self.vendor = vendor
        self.durableResumeID = durableResumeID
        self.launch = launch
    }
}

@objc(TideyRuntimeResumeDescriptor)
@objcMembers
final class TideyRuntimeResumeDescriptor: NSObject {
    static let currentDescriptorVersion = 1
    static let topologyOwnedAgentDescriptorVersion = 2

    let descriptorVersion: Int
    let revision: Int64
    let kind: TideyRuntimeResumeKind
    let restorePolicy: TideyRuntimeRestorePolicy
    let target: TideyRuntimeResumeTarget?
    let topology: TideyRuntimeTmuxTopology?
    let agent: TideyRuntimeAgentResumeSpecification?

    var topologyOwnsAgentLaunches: Bool {
        descriptorVersion == Self.topologyOwnedAgentDescriptorVersion &&
            kind == .agent &&
            restorePolicy == .create
    }

    init(
        descriptorVersion: Int,
        revision: Int64,
        kind: TideyRuntimeResumeKind,
        restorePolicy: TideyRuntimeRestorePolicy,
        target: TideyRuntimeResumeTarget?,
        topology: TideyRuntimeTmuxTopology?,
        agent: TideyRuntimeAgentResumeSpecification?
    ) {
        self.descriptorVersion = descriptorVersion
        self.revision = revision
        self.kind = kind
        self.restorePolicy = restorePolicy
        self.target = target
        self.topology = topology
        self.agent = agent
    }
}

@objc(TideyRuntimeResumeDescriptorFactory)
@objcMembers
final class TideyRuntimeResumeDescriptorFactory: NSObject {
    @objc(descriptorFromOrdinaryTmuxMetadata:)
    func descriptor(
        fromOrdinaryTmuxMetadata metadata: [String: String]
    ) -> TideyRuntimeResumeDescriptor? {
        guard let tmuxSession = metadata["target_session"],
              !tmuxSession.isEmpty else {
            return nil
        }

        let hasSocketPath = metadata.keys.contains("socket_path")
        let hasSocketName = metadata.keys.contains("socket_name")
        guard !(hasSocketPath && hasSocketName) else {
            return nil
        }

        let target: TideyRuntimeResumeTarget
        if hasSocketPath {
            guard let socketPath = metadata["socket_path"],
                  !socketPath.isEmpty else {
                return nil
            }
            target = TideyRuntimeResumeTarget(
                socketPath: socketPath,
                tmuxSession: tmuxSession
            )
        } else if hasSocketName {
            guard let socketName = metadata["socket_name"],
                  !socketName.isEmpty else {
                return nil
            }
            target = TideyRuntimeResumeTarget(
                socketName: socketName,
                tmuxSession: tmuxSession
            )
        } else {
            target = TideyRuntimeResumeTarget(
                defaultSocketAndTmuxSession: tmuxSession
            )
        }

        return TideyRuntimeResumeDescriptor(
            descriptorVersion:
                TideyRuntimeResumeDescriptor.currentDescriptorVersion,
            revision: 1,
            kind: .ordinaryTmux,
            restorePolicy: .attachOnly,
            target: target,
            topology: nil,
            agent: nil
        )
    }
}

enum TideyRuntimeResumeDescriptorCodecError: Error, Equatable {
    case unsupportedDescriptorVersion(Int)
    case malformedField(String)
}

@objc(TideyManagedRestoreLaunchDisposition)
enum TideyManagedRestoreLaunchDisposition: Int {
    case preserveNativeAttachment
    case launchSavedProgram
    case deferToRuntimeRehydrator
}

@objc(TideyManagedRestoreLaunchPolicy)
@objcMembers
final class TideyManagedRestoreLaunchPolicy: NSObject {
    @objc(
        dispositionForNativeReattachOutcome:hasValidDescriptor:
    )
    func disposition(
        nativeReattachOutcome:
            TideyNativeServerReattachOutcome,
        hasValidDescriptor: Bool
    ) -> TideyManagedRestoreLaunchDisposition {
        switch nativeReattachOutcome {
        case .succeeded:
            return .preserveNativeAttachment
        case .failed where hasValidDescriptor:
            return .deferToRuntimeRehydrator
        case .notAttempted, .failed:
            return .launchSavedProgram
        @unknown default:
            return .launchSavedProgram
        }
    }
}

private struct TideyRuntimeResumeLaunchWire: Codable {
    let executable: String
    let arguments: [String]
    let workingDirectory: String?

    enum CodingKeys: String, CodingKey {
        case executable
        case arguments
        case workingDirectory = "cwd"
    }

    init(
        executable: String,
        arguments: [String],
        workingDirectory: String?
    ) {
        self.executable = executable
        self.arguments = arguments
        self.workingDirectory = workingDirectory
    }

    init(_ launch: TideyRuntimeLaunchSpecification) {
        self.init(
            executable: launch.executable,
            arguments: launch.arguments,
            workingDirectory: launch.workingDirectory
        )
    }

    func validatedModel(
        field: String
    ) throws -> TideyRuntimeLaunchSpecification {
        guard !executable.isEmpty,
              !arguments.isEmpty,
              workingDirectory?.isEmpty != true,
              arguments.allSatisfy({ !$0.isEmpty }) else {
            throw TideyRuntimeResumeDescriptorCodecError
                .malformedField(field)
        }
        return TideyRuntimeLaunchSpecification(
            executable: executable,
            arguments: arguments,
            workingDirectory: workingDirectory
        )
    }

    func validatedAgentResumeModel(
        field: String
    ) throws -> TideyRuntimeLaunchSpecification {
        let model = try validatedModel(field: field)
        let isClaudeResume =
            model.executable == "claude" &&
            model.arguments.count == 2 &&
            model.arguments[0] == "--resume"
        let isCodexResume =
            model.executable == "codex" &&
            model.arguments.count == 2 &&
            model.arguments[0] == "resume"
        guard (isClaudeResume || isCodexResume),
              !model.arguments[1].isEmpty else {
            throw TideyRuntimeResumeDescriptorCodecError
                .malformedField(field)
        }
        return model
    }
}

private struct TideyRuntimeResumePaneWire: Codable {
    let index: Int
    let workingDirectory: String?
    let launch: TideyRuntimeResumeLaunchWire?

    enum CodingKeys: String, CodingKey {
        case index
        case workingDirectory = "cwd"
        case launch
    }

    init(_ pane: TideyRuntimeTmuxPaneTopology) {
        index = pane.index
        workingDirectory = pane.workingDirectory
        launch = pane.launch.map(TideyRuntimeResumeLaunchWire.init)
    }
}

private struct TideyRuntimeResumeWindowWire: Codable {
    let index: Int
    let name: String?
    let panes: [TideyRuntimeResumePaneWire]

    init(_ window: TideyRuntimeTmuxWindowTopology) {
        index = window.index
        name = window.name
        panes = window.panes.map(TideyRuntimeResumePaneWire.init)
    }
}

private struct TideyRuntimeResumeTopologyWire: Codable {
    let windows: [TideyRuntimeResumeWindowWire]
    let activeWindowIndex: Int
    let activePaneIndex: Int

    enum CodingKeys: String, CodingKey {
        case windows
        case activeWindowIndex = "active_window_index"
        case activePaneIndex = "active_pane_index"
    }

    init(_ topology: TideyRuntimeTmuxTopology) {
        windows = topology.windows.map(
            TideyRuntimeResumeWindowWire.init
        )
        activeWindowIndex = topology.activeWindowIndex
        activePaneIndex = topology.activePaneIndex
    }

    func validatedModel() throws -> TideyRuntimeTmuxTopology {
        guard !windows.isEmpty,
              Set(windows.map(\.index)).count == windows.count,
              let activeWindow = windows.first(
                  where: { $0.index == activeWindowIndex }
              ) else {
            throw TideyRuntimeResumeDescriptorCodecError
                .malformedField("topology.windows")
        }

        var modelWindows: [TideyRuntimeTmuxWindowTopology] = []
        for window in windows {
            guard window.name?.isEmpty != true,
                  !window.panes.isEmpty,
                  Set(window.panes.map(\.index)).count ==
                    window.panes.count else {
                throw TideyRuntimeResumeDescriptorCodecError
                    .malformedField("topology.panes")
            }
            var modelPanes: [TideyRuntimeTmuxPaneTopology] = []
            for pane in window.panes {
                guard pane.index >= 0,
                      pane.workingDirectory?.isEmpty != true else {
                    throw TideyRuntimeResumeDescriptorCodecError
                        .malformedField("topology.pane")
                }
                let launch = try pane.launch?
                    .validatedAgentResumeModel(
                    field: "topology.pane.launch"
                )
                modelPanes.append(
                    TideyRuntimeTmuxPaneTopology(
                        index: pane.index,
                        workingDirectory: pane.workingDirectory,
                        launch: launch
                    )
                )
            }
            modelWindows.append(
                TideyRuntimeTmuxWindowTopology(
                    index: window.index,
                    name: window.name,
                    panes: modelPanes
                )
            )
        }
        guard activeWindow.panes.contains(
            where: { $0.index == activePaneIndex }
        ) else {
            throw TideyRuntimeResumeDescriptorCodecError
                .malformedField("topology.active_pane_index")
        }
        return TideyRuntimeTmuxTopology(
            windows: modelWindows,
            activeWindowIndex: activeWindowIndex,
            activePaneIndex: activePaneIndex
        )
    }
}

private struct TideyRuntimeResumeTargetWire: Codable {
    let socketEndpointKind: String
    let socketPath: String?
    let socketName: String?
    let tmuxSession: String

    enum CodingKeys: String, CodingKey {
        case socketEndpointKind = "socket_endpoint_kind"
        case socketPath = "socket_path"
        case socketName = "socket_name"
        case tmuxSession = "tmux_session"
    }

    init(_ target: TideyRuntimeResumeTarget) {
        switch target.socketEndpointKind {
        case .path:
            socketEndpointKind = "path"
        case .name:
            socketEndpointKind = "name"
        case .defaultSocket:
            socketEndpointKind = "default"
        }
        socketPath = target.socketPath
        socketName = target.socketName
        tmuxSession = target.tmuxSession
    }

    func validatedModel() throws -> TideyRuntimeResumeTarget {
        guard !tmuxSession.isEmpty else {
            throw TideyRuntimeResumeDescriptorCodecError
                .malformedField("target.tmux_session")
        }
        switch socketEndpointKind {
        case "path":
            guard let socketPath,
                  !socketPath.isEmpty,
                  socketName == nil else {
                throw TideyRuntimeResumeDescriptorCodecError
                    .malformedField("target.socket_path")
            }
            return TideyRuntimeResumeTarget(
                socketPath: socketPath,
                tmuxSession: tmuxSession
            )
        case "name":
            guard let socketName,
                  !socketName.isEmpty,
                  socketPath == nil else {
                throw TideyRuntimeResumeDescriptorCodecError
                    .malformedField("target.socket_name")
            }
            return TideyRuntimeResumeTarget(
                socketName: socketName,
                tmuxSession: tmuxSession
            )
        case "default":
            guard socketPath == nil,
                  socketName == nil else {
                throw TideyRuntimeResumeDescriptorCodecError
                    .malformedField(
                        "target.socket_endpoint_kind"
                    )
            }
            return TideyRuntimeResumeTarget(
                defaultSocketAndTmuxSession: tmuxSession
            )
        default:
            throw TideyRuntimeResumeDescriptorCodecError
                .malformedField("target.socket_endpoint_kind")
        }
    }
}

private struct TideyRuntimeResumeAgentWire: Codable {
    let vendor: String
    let durableResumeID: String
    let launch: TideyRuntimeResumeLaunchWire

    enum CodingKeys: String, CodingKey {
        case vendor
        case durableResumeID = "durable_resume_id"
        case launch
    }

    init(_ agent: TideyRuntimeAgentResumeSpecification) {
        switch agent.vendor {
        case .claude:
            vendor = "claude"
        case .codex:
            vendor = "codex"
        }
        durableResumeID = agent.durableResumeID
        launch = TideyRuntimeResumeLaunchWire(agent.launch)
    }

    func validatedModel()
        throws -> TideyRuntimeAgentResumeSpecification {
        guard !durableResumeID.isEmpty else {
            throw TideyRuntimeResumeDescriptorCodecError
                .malformedField("agent.durable_resume_id")
        }
        let vendorModel: TideyRuntimeAgentVendor
        let expectedExecutable: String
        let expectedArguments: [String]
        switch vendor {
        case "claude":
            vendorModel = .claude
            expectedExecutable = "claude"
            expectedArguments = ["--resume", durableResumeID]
        case "codex":
            vendorModel = .codex
            expectedExecutable = "codex"
            expectedArguments = ["resume", durableResumeID]
        default:
            throw TideyRuntimeResumeDescriptorCodecError
                .malformedField("agent.vendor")
        }
        let launchModel = try launch.validatedAgentResumeModel(
            field: "agent.launch"
        )
        guard launchModel.executable == expectedExecutable,
              launchModel.arguments == expectedArguments else {
            throw TideyRuntimeResumeDescriptorCodecError
                .malformedField("agent.launch")
        }
        return TideyRuntimeAgentResumeSpecification(
            vendor: vendorModel,
            durableResumeID: durableResumeID,
            launch: launchModel
        )
    }
}

private struct TideyRuntimeResumeDescriptorContentWire: Codable {
    let descriptorVersion: Int
    let kind: String
    let restorePolicy: String
    let target: TideyRuntimeResumeTargetWire?
    let topology: TideyRuntimeResumeTopologyWire?
    let agent: TideyRuntimeResumeAgentWire?

    enum CodingKeys: String, CodingKey {
        case descriptorVersion = "descriptor_version"
        case kind
        case restorePolicy = "restore_policy"
        case target
        case topology
        case agent
    }

    init(
        descriptorVersion: Int,
        kind: String,
        restorePolicy: String,
        target: TideyRuntimeResumeTargetWire?,
        topology: TideyRuntimeResumeTopologyWire?,
        agent: TideyRuntimeResumeAgentWire?
    ) {
        self.descriptorVersion = descriptorVersion
        self.kind = kind
        self.restorePolicy = restorePolicy
        self.target = target
        self.topology = topology
        self.agent = agent
    }

    init(_ descriptor: TideyRuntimeResumeDescriptor) {
        descriptorVersion = descriptor.descriptorVersion
        switch descriptor.kind {
        case .ordinaryTmux:
            kind = "ordinary_tmux"
        case .agent:
            kind = "agent"
        case .generic:
            kind = "generic"
        }
        switch descriptor.restorePolicy {
        case .create:
            restorePolicy = "create"
        case .attachOnly:
            restorePolicy = "attach_only"
        case .runtime:
            restorePolicy = "runtime"
        case .directResume:
            restorePolicy = "direct_resume"
        }
        target = descriptor.target.map(
            TideyRuntimeResumeTargetWire.init
        )
        topology = descriptor.topology.map(
            TideyRuntimeResumeTopologyWire.init
        )
        agent = descriptor.agent.map(TideyRuntimeResumeAgentWire.init)
    }

    func validatedModel(
        revision: Int64
    ) throws -> TideyRuntimeResumeDescriptor {
        guard descriptorVersion ==
                TideyRuntimeResumeDescriptor
                    .currentDescriptorVersion ||
                descriptorVersion ==
                TideyRuntimeResumeDescriptor
                    .topologyOwnedAgentDescriptorVersion else {
            throw TideyRuntimeResumeDescriptorCodecError
                .unsupportedDescriptorVersion(descriptorVersion)
        }
        guard revision > 0 else {
            throw TideyRuntimeResumeDescriptorCodecError
                .malformedField("revision")
        }
        let kindModel: TideyRuntimeResumeKind
        switch kind {
        case "ordinary_tmux":
            kindModel = .ordinaryTmux
        case "agent":
            kindModel = .agent
        case "generic":
            kindModel = .generic
        default:
            throw TideyRuntimeResumeDescriptorCodecError
                .malformedField("kind")
        }
        let policyModel: TideyRuntimeRestorePolicy
        switch restorePolicy {
        case "create":
            policyModel = .create
        case "attach_only":
            policyModel = .attachOnly
        case "runtime":
            policyModel = .runtime
        case "direct_resume":
            policyModel = .directResume
        default:
            throw TideyRuntimeResumeDescriptorCodecError
                .malformedField("restore_policy")
        }
        let targetModel = try target?.validatedModel()
        let topologyModel = try topology?.validatedModel()
        let agentModel = try agent?.validatedModel()

        if descriptorVersion == TideyRuntimeResumeDescriptor
            .topologyOwnedAgentDescriptorVersion {
            guard kindModel == .agent,
                  policyModel == .create,
                  targetModel != nil,
                  let topologyModel,
                  agentModel == nil else {
                throw TideyRuntimeResumeDescriptorCodecError
                    .malformedField("agent")
            }
            let launches = topologyModel.windows
                .flatMap(\.panes)
                .compactMap(\.launch)
            var durableResumeKeys = Set<String>()
            guard topologyModel.windows.allSatisfy({ window in
                      window.index >= 0 &&
                          window.panes.sorted(by: {
                              $0.index < $1.index
                          }).map(\.index) ==
                          Array(0 ..< window.panes.count)
                  }),
                  launches.isEmpty == false,
                  launches.allSatisfy({ launch in
                      let vendor = launch.executable
                      let durableResumeID = launch.arguments[1]
                      return durableResumeKeys.insert(
                          "\(vendor)|\(durableResumeID)"
                      ).inserted
                  }) else {
                throw TideyRuntimeResumeDescriptorCodecError
                    .malformedField("topology.pane.launch")
            }
            return TideyRuntimeResumeDescriptor(
                descriptorVersion: descriptorVersion,
                revision: revision,
                kind: kindModel,
                restorePolicy: policyModel,
                target: targetModel,
                topology: topologyModel,
                agent: nil
            )
        }

        switch kindModel {
        case .ordinaryTmux:
            guard policyModel == .attachOnly,
                  target != nil,
                  topology == nil,
                  agent == nil else {
                throw TideyRuntimeResumeDescriptorCodecError
                    .malformedField("ordinary_tmux")
            }
        case .agent:
            let isTmuxCreate =
                policyModel == .create &&
                target != nil &&
                agent != nil
            let isDirectResume =
                policyModel == .directResume &&
                target == nil &&
                topology == nil &&
                agent != nil
            guard isTmuxCreate || isDirectResume else {
                throw TideyRuntimeResumeDescriptorCodecError
                    .malformedField("agent")
            }
        case .generic:
            guard policyModel != .create,
                  policyModel != .directResume,
                  target != nil,
                  agent == nil else {
                throw TideyRuntimeResumeDescriptorCodecError
                    .malformedField("generic")
            }
        }
        return TideyRuntimeResumeDescriptor(
            descriptorVersion: descriptorVersion,
            revision: revision,
            kind: kindModel,
            restorePolicy: policyModel,
            target: targetModel,
            topology: topologyModel,
            agent: agentModel
        )
    }
}

private struct TideyRuntimeResumeDescriptorWire: Codable {
    let descriptorVersion: Int
    let revision: Int64
    let kind: String
    let restorePolicy: String
    let target: TideyRuntimeResumeTargetWire?
    let topology: TideyRuntimeResumeTopologyWire?
    let agent: TideyRuntimeResumeAgentWire?

    enum CodingKeys: String, CodingKey {
        case descriptorVersion = "descriptor_version"
        case revision
        case kind
        case restorePolicy = "restore_policy"
        case target
        case topology
        case agent
    }

    init(_ descriptor: TideyRuntimeResumeDescriptor) {
        let content =
            TideyRuntimeResumeDescriptorContentWire(descriptor)
        descriptorVersion = content.descriptorVersion
        revision = descriptor.revision
        kind = content.kind
        restorePolicy = content.restorePolicy
        target = content.target
        topology = content.topology
        agent = content.agent
    }

    var content: TideyRuntimeResumeDescriptorContentWire {
        TideyRuntimeResumeDescriptorContentWire(
            descriptorVersion: descriptorVersion,
            kind: kind,
            restorePolicy: restorePolicy,
            target: target,
            topology: topology,
            agent: agent
        )
    }
}

final class TideyRuntimeResumeDescriptorDictionaryCodec {
    func encode(
        _ descriptor: TideyRuntimeResumeDescriptor
    ) throws -> [String: Any] {
        let wire = TideyRuntimeResumeDescriptorWire(descriptor)
        _ = try wire.content.validatedModel(
            revision: descriptor.revision
        )
        return try Self.dictionary(from: wire)
    }

    func decode(
        _ dictionary: [String: Any]
    ) throws -> TideyRuntimeResumeDescriptor {
        let wire: TideyRuntimeResumeDescriptorWire =
            try Self.decode(
                TideyRuntimeResumeDescriptorWire.self,
                from: dictionary
            )
        return try wire.content.validatedModel(
            revision: wire.revision
        )
    }

    fileprivate static func dictionary<T: Encodable>(
        from value: T
    ) throws -> [String: Any] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        guard let dictionary = try JSONSerialization.jsonObject(
            with: data
        ) as? [String: Any] else {
            throw TideyRuntimeResumeDescriptorCodecError
                .malformedField("dictionary")
        }
        return dictionary
    }

    fileprivate static func decode<T: Decodable>(
        _ type: T.Type,
        from dictionary: [String: Any]
    ) throws -> T {
        guard JSONSerialization.isValidJSONObject(dictionary) else {
            throw TideyRuntimeResumeDescriptorCodecError
                .malformedField("json")
        }
        let data = try JSONSerialization.data(
            withJSONObject: dictionary,
            options: [.sortedKeys]
        )
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw TideyRuntimeResumeDescriptorCodecError
                .malformedField("json")
        }
    }
}

private struct TideyRuntimeResumeDescriptorBindingWire: Codable {
    let workspaceID: String
    let panelID: String
    let tmuxPaneID: String?

    enum CodingKeys: String, CodingKey {
        case workspaceID = "workspace_id"
        case panelID = "panel_id"
        case tmuxPaneID = "tmux_pane_id"
    }
}

private struct TideyRuntimeResumeDescriptorUpdateWire: Codable {
    let binding: TideyRuntimeResumeDescriptorBindingWire
    let descriptor: TideyRuntimeResumeDescriptorContentWire
}

private struct TideyRuntimeResumeDescriptorRemovalWire: Codable {
    let binding: TideyRuntimeResumeDescriptorBindingWire
    let expectedRevision: Int64
    let expectedDescriptor: TideyRuntimeResumeDescriptorContentWire

    enum CodingKeys: String, CodingKey {
        case binding
        case expectedRevision = "expected_revision"
        case expectedDescriptor = "expected_descriptor"
    }
}

@objc(TideyRuntimeResumeDescriptorUpdateResult)
@objcMembers
final class TideyRuntimeResumeDescriptorUpdateResult: NSObject {
    let accepted: Bool
    let changed: Bool
    let descriptor: TideyRuntimeResumeDescriptor?
    let errorCode: String?

    fileprivate init(
        accepted: Bool,
        changed: Bool,
        descriptor: TideyRuntimeResumeDescriptor?,
        errorCode: String?
    ) {
        self.accepted = accepted
        self.changed = changed
        self.descriptor = descriptor
        self.errorCode = errorCode
    }
}

@objc(TideyRuntimeResumeDescriptorUpdateGate)
@objcMembers
final class TideyRuntimeResumeDescriptorUpdateGate: NSObject {
    private struct Entry {
        let descriptor: TideyRuntimeResumeDescriptor
        let canonicalContent: Data
    }

    private let lock = NSLock()
    private var entriesByPanelID: [String: Entry] = [:]
    private var revisionHighWaterByPanelID: [String: Int64] = [:]

    @objc(initWithInitialDescriptorsByPanelID:)
    init(
        initialDescriptorsByPanelID:
            [String: TideyRuntimeResumeDescriptor]
    ) {
        super.init()
        replaceDescriptorsByPanelID(initialDescriptorsByPanelID)
    }

    override convenience init() {
        self.init(initialDescriptorsByPanelID: [:])
    }

    @objc(
        acceptUpdatePayload:currentWorkspaceID:currentPanelID:
    )
    func acceptUpdatePayload(
        _ payload: [String: Any],
        currentWorkspaceID: String,
        currentPanelID: String
    ) -> TideyRuntimeResumeDescriptorUpdateResult {
        lock.lock()
        defer { lock.unlock() }

        let update: TideyRuntimeResumeDescriptorUpdateWire
        do {
            update = try TideyRuntimeResumeDescriptorDictionaryCodec
                .decode(
                    TideyRuntimeResumeDescriptorUpdateWire.self,
                    from: payload
                )
        } catch {
            return rejected(errorCode: "invalid_descriptor")
        }
        let isDirectResume =
            update.descriptor.restorePolicy == "direct_resume"
        let hasTmuxPane =
            update.binding.tmuxPaneID?.isEmpty == false
        guard !update.binding.workspaceID.isEmpty,
              !update.binding.panelID.isEmpty,
              (isDirectResume ? !hasTmuxPane : hasTmuxPane),
              update.binding.workspaceID == currentWorkspaceID,
              update.binding.panelID == currentPanelID else {
            return rejected(errorCode: "stale_binding")
        }

        let canonicalContent: Data
        do {
            _ = try update.descriptor.validatedModel(revision: 1)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            canonicalContent = try encoder.encode(update.descriptor)
        } catch {
            return rejected(errorCode: "invalid_descriptor")
        }

        let existing = entriesByPanelID[currentPanelID]
        if existing?.canonicalContent == canonicalContent {
            return TideyRuntimeResumeDescriptorUpdateResult(
                accepted: true,
                changed: false,
                descriptor: existing?.descriptor,
                errorCode: nil
            )
        }
        let currentRevision = max(
            existing?.descriptor.revision ?? 0,
            revisionHighWaterByPanelID[currentPanelID] ?? 0
        )
        guard currentRevision < Int64.max else {
            return rejected(errorCode: "revision_overflow")
        }
        do {
            let descriptor = try update.descriptor.validatedModel(
                revision: currentRevision + 1
            )
            entriesByPanelID[currentPanelID] = Entry(
                descriptor: descriptor,
                canonicalContent: canonicalContent
            )
            revisionHighWaterByPanelID[currentPanelID] =
                descriptor.revision
            return TideyRuntimeResumeDescriptorUpdateResult(
                accepted: true,
                changed: true,
                descriptor: descriptor,
                errorCode: nil
            )
        } catch {
            return rejected(errorCode: "invalid_descriptor")
        }
    }

    @objc(descriptorForPanelID:)
    func descriptor(
        forPanelID panelID: String
    ) -> TideyRuntimeResumeDescriptor? {
        lock.lock()
        defer { lock.unlock() }
        return entriesByPanelID[panelID]?.descriptor
    }

    @objc(
        runtimeAgentDescriptorSnapshotsWithCurrentWorkspaceIDByPanelID:
    )
    func runtimeAgentDescriptorSnapshots(
        currentWorkspaceIDByPanelID: [String: String]
    ) -> [[String: Any]] {
        lock.lock()
        defer { lock.unlock() }
        return entriesByPanelID.keys.sorted().compactMap {
            panelID in
            guard let entry = entriesByPanelID[panelID],
                  entry.descriptor.kind == .agent,
                  let workspaceID =
                    currentWorkspaceIDByPanelID[panelID],
                  let descriptor = try?
                    TideyRuntimeResumeDescriptorDictionaryCodec
                        .dictionary(
                            from:
                                TideyRuntimeResumeDescriptorContentWire(
                                    entry.descriptor
                                )
                        ) else {
                return nil
            }
            return [
                "binding": [
                    "workspace_id": workspaceID,
                    "panel_id": panelID,
                ],
                "revision": entry.descriptor.revision,
                "descriptor": descriptor,
            ]
        }
    }

    @objc(
        removeRuntimeAgentDescriptorPayload:currentWorkspaceID:currentPanelID:
    )
    func removeRuntimeAgentDescriptorPayload(
        _ payload: [String: Any],
        currentWorkspaceID: String,
        currentPanelID: String
    ) -> TideyRuntimeResumeDescriptorUpdateResult {
        lock.lock()
        defer { lock.unlock() }

        let removal: TideyRuntimeResumeDescriptorRemovalWire
        do {
            removal = try TideyRuntimeResumeDescriptorDictionaryCodec
                .decode(
                    TideyRuntimeResumeDescriptorRemovalWire.self,
                    from: payload
                )
        } catch {
            return rejected(errorCode: "invalid_descriptor")
        }
        guard !removal.binding.workspaceID.isEmpty,
              !removal.binding.panelID.isEmpty,
              removal.binding.workspaceID == currentWorkspaceID,
              removal.binding.panelID == currentPanelID else {
            return rejected(errorCode: "stale_binding")
        }

        let expectedCanonicalContent: Data
        do {
            let expectedDescriptor = try removal
                .expectedDescriptor.validatedModel(
                    revision: removal.expectedRevision
                )
            guard expectedDescriptor.kind == .agent else {
                return rejected(
                    errorCode: "not_agent_descriptor"
                )
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            expectedCanonicalContent = try encoder.encode(
                removal.expectedDescriptor
            )
        } catch {
            return rejected(errorCode: "invalid_descriptor")
        }

        guard let existing = entriesByPanelID[currentPanelID] else {
            return TideyRuntimeResumeDescriptorUpdateResult(
                accepted: true,
                changed: false,
                descriptor: nil,
                errorCode: nil
            )
        }
        guard existing.descriptor.kind == .agent else {
            return rejected(errorCode: "not_agent_descriptor")
        }
        guard existing.descriptor.revision ==
                removal.expectedRevision,
              existing.canonicalContent ==
                expectedCanonicalContent else {
            return rejected(errorCode: "descriptor_changed")
        }
        entriesByPanelID[currentPanelID] = nil
        return TideyRuntimeResumeDescriptorUpdateResult(
            accepted: true,
            changed: true,
            descriptor: nil,
            errorCode: nil
        )
    }

    @objc(replaceDescriptorsByPanelID:)
    func replaceDescriptorsByPanelID(
        _ descriptorsByPanelID:
            [String: TideyRuntimeResumeDescriptor]
    ) {
        let replacements = validatedEntries(
            for: descriptorsByPanelID
        )
        lock.lock()
        installEntriesLocked(replacements)
        lock.unlock()
    }

    @objc(restoreDescriptorsByPanelIDAwaitingRuntimeEvidence:)
    func restoreDescriptorsByPanelIDAwaitingRuntimeEvidence(
        _ descriptorsByPanelID:
            [String: TideyRuntimeResumeDescriptor]
    ) {
        replaceDescriptorsByPanelID(descriptorsByPanelID)
    }

    private func validatedEntries(
        for descriptorsByPanelID:
            [String: TideyRuntimeResumeDescriptor]
    ) -> [String: Entry] {
        var replacements: [String: Entry] = [:]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        for (panelID, descriptor) in descriptorsByPanelID {
            guard !panelID.isEmpty else {
                continue
            }
            let content =
                TideyRuntimeResumeDescriptorContentWire(descriptor)
            guard (try? content.validatedModel(
                revision: descriptor.revision
            )) != nil,
                  let data = try? encoder.encode(content) else {
                continue
            }
            replacements[panelID] = Entry(
                descriptor: descriptor,
                canonicalContent: data
            )
        }
        return replacements
    }

    private func installEntriesLocked(
        _ replacements: [String: Entry]
    ) {
        entriesByPanelID = replacements
        for (panelID, entry) in replacements {
            revisionHighWaterByPanelID[panelID] = max(
                revisionHighWaterByPanelID[panelID] ?? 0,
                entry.descriptor.revision
            )
        }
    }

    private func rejected(
        errorCode: String
    ) -> TideyRuntimeResumeDescriptorUpdateResult {
        TideyRuntimeResumeDescriptorUpdateResult(
            accepted: false,
            changed: false,
            descriptor: nil,
            errorCode: errorCode
        )
    }
}
