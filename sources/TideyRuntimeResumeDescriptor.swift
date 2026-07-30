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
    let tmuxSocket: String?
    let tmuxSession: String

    init(
        tmuxSocket: String?,
        tmuxSession: String
    ) {
        self.tmuxSocket = tmuxSocket
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
