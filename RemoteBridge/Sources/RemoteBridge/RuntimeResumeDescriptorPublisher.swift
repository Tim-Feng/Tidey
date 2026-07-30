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
    let tmuxPaneID: String

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
    let target: RuntimeResumeTmuxTarget
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

protocol RuntimeResumeAgentRegistryReading: Sendable {
    func readAgentRegistryRecords()
        throws -> [RuntimeResumeAgentRegistryRecord]
}

protocol RuntimeResumeTmuxTopologyReading: Sendable {
    func topologySnapshot(
        for binding: RuntimeResumeDescriptorBinding
    ) throws -> RuntimeResumeTmuxTopologySnapshot?
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
    let contentFingerprint:
        RuntimeResumeDescriptorContentFingerprint
}

protocol RuntimeResumeDescriptorSocketSending: Sendable {
    func send(
        _ update: RuntimeResumeDescriptorSocketUpdate
    ) throws
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
}
