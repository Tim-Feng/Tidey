import Foundation
import CryptoKit

struct TideyRemoteBridgeInstallPaths: Equatable {
    let homeDirectory: URL
    let applicationSupportDirectory: URL
    let bridgeBinaryURL: URL
    let launchAgentsDirectory: URL
    let bridgePlistURL: URL
    let cloudflaredPlistURL: URL
    let logsDirectory: URL

    static func currentUser(fileManager: FileManager = .default) -> TideyRemoteBridgeInstallPaths {
        let home = fileManager.homeDirectoryForCurrentUser
        let support = home
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Tidey Remote Bridge", isDirectory: true)
        let launchAgents = home
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("LaunchAgents", isDirectory: true)
        return TideyRemoteBridgeInstallPaths(
            homeDirectory: home,
            applicationSupportDirectory: support,
            bridgeBinaryURL: support.appendingPathComponent("tidey-remote-bridge", isDirectory: false),
            launchAgentsDirectory: launchAgents,
            bridgePlistURL: launchAgents.appendingPathComponent("com.tidey.remote-bridge.plist", isDirectory: false),
            cloudflaredPlistURL: launchAgents.appendingPathComponent("com.tidey.remote-bridge.cloudflared.plist", isDirectory: false),
            logsDirectory: home
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Logs", isDirectory: true)
                .appendingPathComponent("Tidey", isDirectory: true)
        )
    }
}

struct TideyRemoteBridgeBundledResources: Equatable {
    let bridgeBinaryURL: URL
    let bridgePlistTemplateURL: URL
    let cloudflaredPlistTemplateURL: URL

    static func inMainBundle() throws -> TideyRemoteBridgeBundledResources {
        guard let resourcesURL = Bundle.main.resourceURL else {
            throw TideyRemoteBridgeInstallerError.missingBundledResources
        }
        let bridgeDirectory = resourcesURL.appendingPathComponent("RemoteBridge", isDirectory: true)
        return TideyRemoteBridgeBundledResources(
            bridgeBinaryURL: bridgeDirectory.appendingPathComponent("tidey-remote-bridge", isDirectory: false),
            bridgePlistTemplateURL: bridgeDirectory.appendingPathComponent("com.tidey.remote-bridge.plist.template", isDirectory: false),
            cloudflaredPlistTemplateURL: bridgeDirectory.appendingPathComponent("com.tidey.remote-bridge.cloudflared.plist.template", isDirectory: false)
        )
    }
}

struct TideyRemoteBridgePlistRenderer {
    static func render(template: String, homeDirectory: URL, label: String) -> String {
        template
            .replacingOccurrences(of: "__HOME__", with: homeDirectory.path)
            .replacingOccurrences(of: "__LABEL__", with: label)
    }
}

struct TideyRemoteBridgeFileComparator {
    static func sha256Digest(of url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        return SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    static func filesDiffer(_ lhs: URL, _ rhs: URL, fileManager: FileManager = .default) throws -> Bool {
        guard fileManager.fileExists(atPath: lhs.path),
              fileManager.fileExists(atPath: rhs.path) else {
            return true
        }
        return try sha256Digest(of: lhs) != sha256Digest(of: rhs)
    }
}

enum TideyRemoteBridgeInstallClassification: Equatable {
    case missingBinary
    case staleBinary
    case missingPlist
    case notLoaded
    case running

    var needsInstall: Bool {
        switch self {
        case .missingBinary, .staleBinary, .missingPlist:
            return true
        case .notLoaded, .running:
            return false
        }
    }
}

struct TideyRemoteBridgeInstallInspector {
    static func classify(installedBinaryExists: Bool,
                         binaryDiffers: Bool,
                         bridgePlistExists: Bool,
                         cloudflaredPlistExists: Bool,
                         launchAgentLoaded: Bool) -> TideyRemoteBridgeInstallClassification {
        if !installedBinaryExists {
            return .missingBinary
        }
        if binaryDiffers {
            return .staleBinary
        }
        if !bridgePlistExists || !cloudflaredPlistExists {
            return .missingPlist
        }
        if !launchAgentLoaded {
            return .notLoaded
        }
        return .running
    }
}

enum TideyRemoteBridgeInstallerError: Error, LocalizedError {
    case missingBundledResources
    case missingBundledBinary(String)
    case missingBundledTemplate(String)
    case launchctlFailed(arguments: [String], output: String)
    case bridgeDidNotBecomeReady

    var errorDescription: String? {
        switch self {
        case .missingBundledResources:
            return "Tidey Remote Bridge resources are missing from this app build."
        case .missingBundledBinary(let path):
            return "The bundled Tidey Remote Bridge binary is missing at \(path)."
        case .missingBundledTemplate(let path):
            return "The bundled Tidey Remote Bridge LaunchAgent template is missing at \(path)."
        case .launchctlFailed(let arguments, let output):
            let command = (["launchctl"] + arguments).joined(separator: " ")
            return "\(command) failed: \(output)"
        case .bridgeDidNotBecomeReady:
            return "Tidey Remote Bridge did not respond on localhost after installation."
        }
    }
}

struct TideyRemoteBridgeCommandResult {
    let exitCode: Int32
    let output: String
}

protocol TideyRemoteBridgeCommandRunning {
    func run(_ executable: String, arguments: [String]) throws -> TideyRemoteBridgeCommandResult
}

struct TideyRemoteBridgeProcessRunner: TideyRemoteBridgeCommandRunning {
    func run(_ executable: String, arguments: [String]) throws -> TideyRemoteBridgeCommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        return TideyRemoteBridgeCommandResult(exitCode: process.terminationStatus, output: output)
    }
}

struct TideyRemoteBridgeCloudflaredResolver {
    static func executableURL(environment: [String: String] = ProcessInfo.processInfo.environment,
                              fileManager: FileManager = .default) -> URL? {
        var directories = [String]()
        if let path = environment["PATH"] {
            directories.append(contentsOf: path.split(separator: ":").map(String.init))
        }
        directories.append(contentsOf: ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"])

        var seen = Set<String>()
        for directory in directories where !directory.isEmpty {
            guard seen.insert(directory).inserted else {
                continue
            }
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent("cloudflared")
            if fileManager.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }
}

@objcMembers
@objc(TideyRemoteBridgeInstallResult)
public final class TideyRemoteBridgeInstallResult: NSObject {
    public let state: String
    public let userMessage: String
    public let detailMessage: String?
    public let bridgeReady: Bool
    public let cloudflaredAvailable: Bool

    public init(state: String,
                userMessage: String,
                detailMessage: String?,
                bridgeReady: Bool,
                cloudflaredAvailable: Bool) {
        self.state = state
        self.userMessage = userMessage
        self.detailMessage = detailMessage
        self.bridgeReady = bridgeReady
        self.cloudflaredAvailable = cloudflaredAvailable
    }
}

@objcMembers
@objc(TideyRemoteBridgeInstaller)
public final class TideyRemoteBridgeInstaller: NSObject {
    public static let shared = TideyRemoteBridgeInstaller()

    private let queue = DispatchQueue(label: "com.tidey.remote-bridge-installer", qos: .utility)
    private let fileManager: FileManager
    private let commandRunner: TideyRemoteBridgeCommandRunning

    override convenience init() {
        self.init(fileManager: .default, commandRunner: TideyRemoteBridgeProcessRunner())
    }

    init(fileManager: FileManager, commandRunner: TideyRemoteBridgeCommandRunning) {
        self.fileManager = fileManager
        self.commandRunner = commandRunner
        super.init()
    }

    @objc(ensureInstalledWithCompletion:)
    public func ensureInstalled(completion: @escaping (TideyRemoteBridgeInstallResult) -> Void) {
        queue.async {
            let result = self.performInstall(force: false)
            DispatchQueue.main.async {
                completion(result)
            }
        }
    }

    @objc(reinstallWithCompletion:)
    public func reinstall(completion: @escaping (TideyRemoteBridgeInstallResult) -> Void) {
        queue.async {
            let result = self.performInstall(force: true)
            DispatchQueue.main.async {
                completion(result)
            }
        }
    }

    public func cloudflaredAvailabilityMessage() -> String? {
        if TideyRemoteBridgeCloudflaredResolver.executableURL(fileManager: fileManager) != nil {
            return nil
        }
        return "LAN pairing is available. Internet access requires cloudflared. Install with Homebrew: brew install cloudflared"
    }

    private func performInstall(force: Bool) -> TideyRemoteBridgeInstallResult {
        do {
            let resources = try TideyRemoteBridgeBundledResources.inMainBundle()
            let paths = TideyRemoteBridgeInstallPaths.currentUser(fileManager: fileManager)
            try validateBundledResources(resources)
            try installIfNeeded(resources: resources, paths: paths, force: force)
            try reloadLaunchAgents(paths: paths)
            try pollBridgeReady()

            let cloudflaredAvailable = TideyRemoteBridgeCloudflaredResolver.executableURL(fileManager: fileManager) != nil
            let detail = cloudflaredAvailable ? nil : cloudflaredAvailabilityMessage()
            return TideyRemoteBridgeInstallResult(state: "running",
                                                  userMessage: "Tidey Remote Bridge is running.",
                                                  detailMessage: detail,
                                                  bridgeReady: true,
                                                  cloudflaredAvailable: cloudflaredAvailable)
        } catch {
            return TideyRemoteBridgeInstallResult(state: "failed",
                                                  userMessage: "Tidey Remote Bridge setup failed.",
                                                  detailMessage: error.localizedDescription,
                                                  bridgeReady: false,
                                                  cloudflaredAvailable: TideyRemoteBridgeCloudflaredResolver.executableURL(fileManager: fileManager) != nil)
        }
    }

    private func validateBundledResources(_ resources: TideyRemoteBridgeBundledResources) throws {
        guard fileManager.isExecutableFile(atPath: resources.bridgeBinaryURL.path) else {
            throw TideyRemoteBridgeInstallerError.missingBundledBinary(resources.bridgeBinaryURL.path)
        }
        guard fileManager.fileExists(atPath: resources.bridgePlistTemplateURL.path) else {
            throw TideyRemoteBridgeInstallerError.missingBundledTemplate(resources.bridgePlistTemplateURL.path)
        }
        guard fileManager.fileExists(atPath: resources.cloudflaredPlistTemplateURL.path) else {
            throw TideyRemoteBridgeInstallerError.missingBundledTemplate(resources.cloudflaredPlistTemplateURL.path)
        }
    }

    private func installIfNeeded(resources: TideyRemoteBridgeBundledResources,
                                 paths: TideyRemoteBridgeInstallPaths,
                                 force: Bool) throws {
        try fileManager.createDirectory(at: paths.applicationSupportDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: paths.launchAgentsDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: paths.logsDirectory, withIntermediateDirectories: true)

        let binaryDiffers: Bool
        if force {
            binaryDiffers = true
        } else {
            binaryDiffers = try TideyRemoteBridgeFileComparator.filesDiffer(resources.bridgeBinaryURL,
                                                                            paths.bridgeBinaryURL,
                                                                            fileManager: fileManager)
        }
        if binaryDiffers {
            if fileManager.fileExists(atPath: paths.bridgeBinaryURL.path) {
                try fileManager.removeItem(at: paths.bridgeBinaryURL)
            }
            try fileManager.copyItem(at: resources.bridgeBinaryURL, to: paths.bridgeBinaryURL)
            try fileManager.setAttributes([.posixPermissions: NSNumber(value: Int16(0o755))],
                                          ofItemAtPath: paths.bridgeBinaryURL.path)
        }

        try writePlist(templateURL: resources.bridgePlistTemplateURL,
                       outputURL: paths.bridgePlistURL,
                       label: "com.tidey.remote-bridge",
                       homeDirectory: paths.homeDirectory)
        try writePlist(templateURL: resources.cloudflaredPlistTemplateURL,
                       outputURL: paths.cloudflaredPlistURL,
                       label: "com.tidey.remote-bridge.cloudflared",
                       homeDirectory: paths.homeDirectory)
    }

    private func writePlist(templateURL: URL, outputURL: URL, label: String, homeDirectory: URL) throws {
        let template = try String(contentsOf: templateURL, encoding: .utf8)
        let rendered = TideyRemoteBridgePlistRenderer.render(template: template,
                                                             homeDirectory: homeDirectory,
                                                             label: label)
        try rendered.write(to: outputURL, atomically: true, encoding: .utf8)
    }

    private func reloadLaunchAgents(paths: TideyRemoteBridgeInstallPaths) throws {
        let uid = getuid()
        try reloadLaunchAgent(label: "com.tidey.remote-bridge", plistURL: paths.bridgePlistURL, uid: uid)
        try reloadLaunchAgent(label: "com.tidey.remote-bridge.cloudflared", plistURL: paths.cloudflaredPlistURL, uid: uid)
    }

    private func reloadLaunchAgent(label: String, plistURL: URL, uid: uid_t) throws {
        let domain = "gui/\(uid)"
        let service = "\(domain)/\(label)"
        if (try? commandRunner.run("/bin/launchctl", arguments: ["print", service]))?.exitCode == 0 {
            _ = try? commandRunner.run("/bin/launchctl", arguments: ["bootout", service])
        }

        let bootstrap = try commandRunner.run("/bin/launchctl", arguments: ["bootstrap", domain, plistURL.path])
        guard bootstrap.exitCode == 0 else {
            throw TideyRemoteBridgeInstallerError.launchctlFailed(arguments: ["bootstrap", domain, plistURL.path],
                                                                  output: bootstrap.output)
        }

        let kickstart = try commandRunner.run("/bin/launchctl", arguments: ["kickstart", "-k", service])
        guard kickstart.exitCode == 0 else {
            throw TideyRemoteBridgeInstallerError.launchctlFailed(arguments: ["kickstart", "-k", service],
                                                                  output: kickstart.output)
        }
    }

    private func pollBridgeReady(timeout: TimeInterval = 20, interval: TimeInterval = 0.5) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if bridgeStatusResponds() {
                return
            }
            Thread.sleep(forTimeInterval: interval)
        }
        throw TideyRemoteBridgeInstallerError.bridgeDidNotBecomeReady
    }

    private func bridgeStatusResponds() -> Bool {
        guard let url = URL(string: "http://127.0.0.1:4817/admin/status") else {
            return false
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 1

        let semaphore = DispatchSemaphore(value: 0)
        var success = false
        let task = URLSession.shared.dataTask(with: request) { _, response, _ in
            if let httpResponse = response as? HTTPURLResponse {
                success = (200..<500).contains(httpResponse.statusCode)
            }
            semaphore.signal()
        }
        task.resume()
        _ = semaphore.wait(timeout: .now() + 1.5)
        return success
    }
}
