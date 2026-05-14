import XCTest
@testable import iTerm2SharedARC

final class TideyRemoteBridgeInstallerTests: XCTestCase {
    func testPlistRendererReplacesHomeAndLabel() {
        let template = """
        <string>__HOME__/Library/Application Support/Tidey Remote Bridge/tidey-remote-bridge</string>
        <string>__LABEL__</string>
        """

        let rendered = TideyRemoteBridgePlistRenderer.render(
            template: template,
            homeDirectory: URL(fileURLWithPath: "/Users/tidey-test"),
            label: "com.tidey.remote-bridge.cloudflared"
        )

        XCTAssertTrue(rendered.contains("/Users/tidey-test/Library/Application Support/Tidey Remote Bridge/tidey-remote-bridge"))
        XCTAssertTrue(rendered.contains("com.tidey.remote-bridge.cloudflared"))
        XCTAssertFalse(rendered.contains("__HOME__"))
        XCTAssertFalse(rendered.contains("__LABEL__"))
    }

    func testFileComparatorDetectsSameAndDifferentFiles() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TideyRemoteBridgeInstallerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let bundled = directory.appendingPathComponent("bundled")
        let installed = directory.appendingPathComponent("installed")

        try Data("bridge-v1".utf8).write(to: bundled)
        try Data("bridge-v1".utf8).write(to: installed)
        XCTAssertFalse(try TideyRemoteBridgeFileComparator.filesDiffer(bundled, installed))

        try Data("bridge-v2".utf8).write(to: installed)
        XCTAssertTrue(try TideyRemoteBridgeFileComparator.filesDiffer(bundled, installed))
    }

    func testInstallInspectorClassifiesMissingBinaryAsInstallRequired() {
        let classification = TideyRemoteBridgeInstallInspector.classify(
            installedBinaryExists: false,
            binaryDiffers: false,
            bridgePlistExists: true,
            cloudflaredPlistExists: true,
            launchAgentLoaded: true
        )

        XCTAssertEqual(classification, .missingBinary)
        XCTAssertTrue(classification.needsInstall)
    }

    func testInstallInspectorClassifiesStaleBinaryAsInstallRequired() {
        let classification = TideyRemoteBridgeInstallInspector.classify(
            installedBinaryExists: true,
            binaryDiffers: true,
            bridgePlistExists: true,
            cloudflaredPlistExists: true,
            launchAgentLoaded: true
        )

        XCTAssertEqual(classification, .staleBinary)
        XCTAssertTrue(classification.needsInstall)
    }

    func testInstallInspectorPreservesExistingCredentialsWhenOnlyLaunchAgentMissing() {
        let classification = TideyRemoteBridgeInstallInspector.classify(
            installedBinaryExists: true,
            binaryDiffers: false,
            bridgePlistExists: true,
            cloudflaredPlistExists: true,
            launchAgentLoaded: false
        )

        XCTAssertEqual(classification, .notLoaded)
        XCTAssertFalse(classification.needsInstall)
    }

    func testInstallInspectorRequiresInstallWhenPlistMissing() {
        let classification = TideyRemoteBridgeInstallInspector.classify(
            installedBinaryExists: true,
            binaryDiffers: false,
            bridgePlistExists: false,
            cloudflaredPlistExists: true,
            launchAgentLoaded: true
        )

        XCTAssertEqual(classification, .missingPlist)
        XCTAssertTrue(classification.needsInstall)
    }

    func testLaunchctlFailureMessageIsUserFacing() {
        let error = TideyRemoteBridgeInstallerError.launchctlFailed(
            arguments: ["bootstrap", "gui/501", "/Users/tidey-test/Library/LaunchAgents/com.tidey.remote-bridge.plist"],
            output: "Bootstrap failed: 5"
        )

        XCTAssertTrue(error.localizedDescription.contains("launchctl bootstrap gui/501"))
        XCTAssertTrue(error.localizedDescription.contains("Bootstrap failed: 5"))
    }

    func testReadinessCheckerSendsBearerTokenAndRequiresHTTP200() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        try writePairToken("fresh-token", to: fixture.paths.pairTokenFileURL)
        let httpClient = FakeHTTPClient(statusCode: 200)
        let checker = TideyRemoteBridgeStatusReadinessChecker(httpClient: httpClient)

        let result = checker.check(paths: fixture.paths)

        XCTAssertEqual(result, .ready(statusCode: 200))
        XCTAssertEqual(httpClient.lastAuthorizationHeader, "Bearer fresh-token")
    }

    func testReadinessCheckerTreatsHTTP401AsPortConflict() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        try writePairToken("fresh-token", to: fixture.paths.pairTokenFileURL)
        let checker = TideyRemoteBridgeStatusReadinessChecker(httpClient: FakeHTTPClient(statusCode: 401))

        let result = checker.check(paths: fixture.paths)

        XCTAssertEqual(result, .authMismatch(statusCode: 401))
        XCTAssertEqual(result.logResult, "conflict")
        XCTAssertTrue(result.userFacingDetail.contains("Another Bridge is using port 4817"))
    }

    func testReadinessCheckerClassifiesOtherHTTPFailuresAndNetworkFailures() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        try writePairToken("fresh-token", to: fixture.paths.pairTokenFileURL)

        XCTAssertEqual(
            TideyRemoteBridgeStatusReadinessChecker(httpClient: FakeHTTPClient(statusCode: 503)).check(paths: fixture.paths),
            .httpFailure(statusCode: 503)
        )

        let networkResult = TideyRemoteBridgeStatusReadinessChecker(
            httpClient: FakeHTTPClient(error: URLError(.cannotConnectToHost))
        ).check(paths: fixture.paths)
        if case .networkFailure = networkResult {
            // Expected.
        } else {
            XCTFail("Expected network failure, got \(networkResult)")
        }
    }

    func testPerformInstallCopiesResourcesWritesPlistsBootstrapsAndChecksAuthenticatedStatus() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let httpClient = FakeHTTPClient(statusCode: 200)
        let runner = FakeCommandRunner { _, arguments in
            if arguments == ["kickstart", "-k", "gui/\(getuid())/com.tidey.remote-bridge"] {
                try self.writePairToken("generated-token", to: fixture.paths.pairTokenFileURL)
            }
            return TideyRemoteBridgeCommandResult(exitCode: 0, output: "")
        }
        let installer = makeInstaller(fixture: fixture, runner: runner, httpClient: httpClient)

        let result = installer.performInstallForTesting(force: false)

        XCTAssertEqual(result.state, "running")
        XCTAssertTrue(result.bridgeReady)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.paths.bridgeBinaryURL.path))
        XCTAssertEqual(try Data(contentsOf: fixture.paths.bridgeBinaryURL), try Data(contentsOf: fixture.resources.bridgeBinaryURL))
        XCTAssertTrue(try String(contentsOf: fixture.paths.bridgePlistURL, encoding: .utf8).contains(fixture.paths.homeDirectory.path))
        XCTAssertTrue(try String(contentsOf: fixture.paths.cloudflaredPlistURL, encoding: .utf8).contains("com.tidey.remote-bridge.cloudflared"))
        XCTAssertEqual(httpClient.lastAuthorizationHeader, "Bearer generated-token")
        XCTAssertTrue(runner.calls.contains { $0.arguments.prefix(2) == ["bootstrap", "gui/\(getuid())"] })
        XCTAssertTrue(runner.calls.contains { $0.arguments == ["kickstart", "-k", "gui/\(getuid())/com.tidey.remote-bridge"] })
    }

    func testPerformInstallSurfacesHTTP401PortConflictInsteadOfFalseReady() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let httpClient = FakeHTTPClient(statusCode: 401)
        let runner = FakeCommandRunner { _, arguments in
            if arguments == ["kickstart", "-k", "gui/\(getuid())/com.tidey.remote-bridge"] {
                try self.writePairToken("generated-token", to: fixture.paths.pairTokenFileURL)
            }
            return TideyRemoteBridgeCommandResult(exitCode: 0, output: "")
        }
        let installer = makeInstaller(fixture: fixture, runner: runner, httpClient: httpClient)

        let result = installer.performInstallForTesting(force: false)

        XCTAssertEqual(result.state, "failed")
        XCTAssertFalse(result.bridgeReady)
        XCTAssertTrue(result.detailMessage?.contains("Another Bridge is using port 4817") == true)
        XCTAssertEqual(httpClient.lastAuthorizationHeader, "Bearer generated-token")
    }

    func testPerformInstallSurfacesLaunchctlBootstrapFailure() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let runner = FakeCommandRunner { _, arguments in
            if arguments.first == "bootstrap" {
                return TideyRemoteBridgeCommandResult(exitCode: 5, output: "Bootstrap failed: 5")
            }
            return TideyRemoteBridgeCommandResult(exitCode: 0, output: "")
        }
        let installer = makeInstaller(fixture: fixture, runner: runner, httpClient: FakeHTTPClient(statusCode: 200))

        let result = installer.performInstallForTesting(force: false)

        XCTAssertEqual(result.state, "failed")
        XCTAssertFalse(result.bridgeReady)
        XCTAssertTrue(result.detailMessage?.contains("launchctl bootstrap") == true)
        XCTAssertTrue(result.detailMessage?.contains("Bootstrap failed: 5") == true)
    }

    func testPerformInstallSurfacesFileSystemSetupFailure() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        try FileManager.default.createDirectory(
            at: fixture.paths.launchAgentsDirectory.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("not a directory".utf8).write(to: fixture.paths.launchAgentsDirectory)
        let installer = makeInstaller(
            fixture: fixture,
            runner: FakeCommandRunner { _, _ in TideyRemoteBridgeCommandResult(exitCode: 0, output: "") },
            httpClient: FakeHTTPClient(statusCode: 200)
        )

        let result = installer.performInstallForTesting(force: false)

        XCTAssertEqual(result.state, "failed")
        XCTAssertFalse(result.bridgeReady)
        XCTAssertTrue(result.detailMessage?.contains("LaunchAgents") == true)
    }

    private struct Fixture {
        let root: URL
        let resources: TideyRemoteBridgeBundledResources
        let paths: TideyRemoteBridgeInstallPaths

        func cleanup() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TideyRemoteBridgeInstallerTests-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let resourcesDirectory = root.appendingPathComponent("resources", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: resourcesDirectory, withIntermediateDirectories: true)

        let bundledBinary = resourcesDirectory.appendingPathComponent("tidey-remote-bridge", isDirectory: false)
        try Data("bundled bridge".utf8).write(to: bundledBinary)
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: Int16(0o755))],
                                              ofItemAtPath: bundledBinary.path)

        let bridgeTemplate = resourcesDirectory.appendingPathComponent("com.tidey.remote-bridge.plist.template", isDirectory: false)
        let cloudflaredTemplate = resourcesDirectory.appendingPathComponent("com.tidey.remote-bridge.cloudflared.plist.template", isDirectory: false)
        try launchAgentTemplate().write(to: bridgeTemplate, atomically: true, encoding: .utf8)
        try launchAgentTemplate().write(to: cloudflaredTemplate, atomically: true, encoding: .utf8)

        let support = home
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Tidey Remote Bridge", isDirectory: true)
        let launchAgents = home
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("LaunchAgents", isDirectory: true)
        let logs = home
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("Tidey", isDirectory: true)
        let paths = TideyRemoteBridgeInstallPaths(
            homeDirectory: home,
            applicationSupportDirectory: support,
            bridgeBinaryURL: support.appendingPathComponent("tidey-remote-bridge", isDirectory: false),
            pairTokenFileURL: support.appendingPathComponent("pair-token.json", isDirectory: false),
            launchAgentsDirectory: launchAgents,
            bridgePlistURL: launchAgents.appendingPathComponent("com.tidey.remote-bridge.plist", isDirectory: false),
            cloudflaredPlistURL: launchAgents.appendingPathComponent("com.tidey.remote-bridge.cloudflared.plist", isDirectory: false),
            logsDirectory: logs
        )
        let resources = TideyRemoteBridgeBundledResources(
            bridgeBinaryURL: bundledBinary,
            bridgePlistTemplateURL: bridgeTemplate,
            cloudflaredPlistTemplateURL: cloudflaredTemplate
        )
        return Fixture(root: root, resources: resources, paths: paths)
    }

    private func makeInstaller(fixture: Fixture,
                               runner: FakeCommandRunner,
                               httpClient: FakeHTTPClient) -> TideyRemoteBridgeInstaller {
        TideyRemoteBridgeInstaller(
            fileManager: .default,
            commandRunner: runner,
            resourcesProvider: { fixture.resources },
            pathsProvider: { fixture.paths },
            readinessChecker: TideyRemoteBridgeStatusReadinessChecker(httpClient: httpClient),
            sleep: { _ in }
        )
    }

    private func launchAgentTemplate() -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>__LABEL__</string>
            <key>ProgramArguments</key>
            <array>
                <string>__HOME__/Library/Application Support/Tidey Remote Bridge/tidey-remote-bridge</string>
            </array>
        </dict>
        </plist>
        """
    }

    private func writePairToken(_ token: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let json = #"{"token":"\#(token)","createdAt":"2026-05-13T00:00:00Z"}"#
        try json.write(to: url, atomically: true, encoding: .utf8)
    }
}

private final class FakeHTTPClient: TideyRemoteBridgeHTTPClient {
    private let result: Result<Int, Error>
    private(set) var lastAuthorizationHeader: String?

    init(statusCode: Int) {
        self.result = .success(statusCode)
    }

    init(error: Error) {
        self.result = .failure(error)
    }

    func statusCode(for request: URLRequest) throws -> Int {
        lastAuthorizationHeader = request.value(forHTTPHeaderField: "Authorization")
        return try result.get()
    }
}

private final class FakeCommandRunner: TideyRemoteBridgeCommandRunning {
    private let handler: (String, [String]) throws -> TideyRemoteBridgeCommandResult
    private(set) var calls: [(executable: String, arguments: [String])] = []

    init(handler: @escaping (String, [String]) throws -> TideyRemoteBridgeCommandResult) {
        self.handler = handler
    }

    func run(_ executable: String, arguments: [String]) throws -> TideyRemoteBridgeCommandResult {
        calls.append((executable: executable, arguments: arguments))
        return try handler(executable, arguments)
    }
}
