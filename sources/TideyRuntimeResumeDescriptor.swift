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

    let descriptorVersion: Int
    let revision: Int64
    let kind: TideyRuntimeResumeKind
    let restorePolicy: TideyRuntimeRestorePolicy
    let target: TideyRuntimeResumeTarget
    let topology: TideyRuntimeTmuxTopology?
    let agent: TideyRuntimeAgentResumeSpecification?

    init(
        descriptorVersion: Int,
        revision: Int64,
        kind: TideyRuntimeResumeKind,
        restorePolicy: TideyRuntimeRestorePolicy,
        target: TideyRuntimeResumeTarget,
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

final class TideyRuntimeResumeDescriptorDictionaryCodec {
    func encode(
        _ descriptor: TideyRuntimeResumeDescriptor
    ) throws -> [String: Any] {
        guard descriptor.descriptorVersion ==
                TideyRuntimeResumeDescriptor.currentDescriptorVersion else {
            throw TideyRuntimeResumeDescriptorCodecError
                .unsupportedDescriptorVersion(descriptor.descriptorVersion)
        }
        guard descriptor.revision > 0 else {
            throw TideyRuntimeResumeDescriptorCodecError
                .malformedField("revision")
        }
        guard descriptor.kind == .ordinaryTmux,
              descriptor.restorePolicy == .attachOnly,
              descriptor.topology == nil,
              descriptor.agent == nil else {
            throw TideyRuntimeResumeDescriptorCodecError
                .malformedField("ordinary_tmux")
        }

        var target: [String: Any] = [
            "tmux_session": try requiredIdentity(
                descriptor.target.tmuxSession,
                field: "tmux_session"
            )
        ]
        switch descriptor.target.socketEndpointKind {
        case .path:
            guard let socketPath = descriptor.target.socketPath,
                  descriptor.target.socketName == nil else {
                throw TideyRuntimeResumeDescriptorCodecError
                    .malformedField("socket_path")
            }
            target["socket_endpoint_kind"] = "path"
            target["socket_path"] = try requiredIdentity(
                socketPath,
                field: "socket_path"
            )
        case .name:
            guard let socketName = descriptor.target.socketName,
                  descriptor.target.socketPath == nil else {
                throw TideyRuntimeResumeDescriptorCodecError
                    .malformedField("socket_name")
            }
            target["socket_endpoint_kind"] = "name"
            target["socket_name"] = try requiredIdentity(
                socketName,
                field: "socket_name"
            )
        case .defaultSocket:
            guard descriptor.target.socketPath == nil,
                  descriptor.target.socketName == nil else {
                throw TideyRuntimeResumeDescriptorCodecError
                    .malformedField("socket_endpoint_kind")
            }
            target["socket_endpoint_kind"] = "default"
        }

        return [
            "descriptor_version": descriptor.descriptorVersion,
            "revision": descriptor.revision,
            "kind": "ordinary_tmux",
            "restore_policy": "attach_only",
            "target": target
        ]
    }

    func decode(
        _ dictionary: [String: Any]
    ) throws -> TideyRuntimeResumeDescriptor {
        guard let descriptorVersion =
                dictionary["descriptor_version"] as? Int else {
            throw TideyRuntimeResumeDescriptorCodecError
                .malformedField("descriptor_version")
        }
        guard descriptorVersion ==
                TideyRuntimeResumeDescriptor.currentDescriptorVersion else {
            throw TideyRuntimeResumeDescriptorCodecError
                .unsupportedDescriptorVersion(descriptorVersion)
        }
        guard let revision = dictionary["revision"] as? Int64,
              revision > 0 else {
            throw TideyRuntimeResumeDescriptorCodecError
                .malformedField("revision")
        }
        guard dictionary["kind"] as? String == "ordinary_tmux",
              dictionary["restore_policy"] as? String == "attach_only",
              dictionary["topology"] == nil,
              dictionary["agent"] == nil,
              let targetDictionary = dictionary["target"]
                as? [String: Any] else {
            throw TideyRuntimeResumeDescriptorCodecError
                .malformedField("ordinary_tmux")
        }

        let tmuxSession = try requiredIdentity(
            targetDictionary["tmux_session"],
            field: "tmux_session"
        )
        let target: TideyRuntimeResumeTarget
        switch targetDictionary["socket_endpoint_kind"] as? String {
        case "path":
            guard targetDictionary["socket_name"] == nil else {
                throw TideyRuntimeResumeDescriptorCodecError
                    .malformedField("socket_name")
            }
            target = TideyRuntimeResumeTarget(
                socketPath: try requiredIdentity(
                    targetDictionary["socket_path"],
                    field: "socket_path"
                ),
                tmuxSession: tmuxSession
            )
        case "name":
            guard targetDictionary["socket_path"] == nil else {
                throw TideyRuntimeResumeDescriptorCodecError
                    .malformedField("socket_path")
            }
            target = TideyRuntimeResumeTarget(
                socketName: try requiredIdentity(
                    targetDictionary["socket_name"],
                    field: "socket_name"
                ),
                tmuxSession: tmuxSession
            )
        case "default":
            guard targetDictionary["socket_path"] == nil,
                  targetDictionary["socket_name"] == nil else {
                throw TideyRuntimeResumeDescriptorCodecError
                    .malformedField("socket_endpoint_kind")
            }
            target = TideyRuntimeResumeTarget(
                defaultSocketAndTmuxSession: tmuxSession
            )
        default:
            throw TideyRuntimeResumeDescriptorCodecError
                .malformedField("socket_endpoint_kind")
        }

        return TideyRuntimeResumeDescriptor(
            descriptorVersion: descriptorVersion,
            revision: revision,
            kind: .ordinaryTmux,
            restorePolicy: .attachOnly,
            target: target,
            topology: nil,
            agent: nil
        )
    }

    private func requiredIdentity(
        _ value: Any?,
        field: String
    ) throws -> String {
        guard let identity = value as? String,
              !identity.isEmpty else {
            throw TideyRuntimeResumeDescriptorCodecError
                .malformedField(field)
        }
        return identity
    }
}
