import Foundation
import XCTest
@testable import RemoteBridge

final class BridgeCloudflaredManagerTests: XCTestCase {
    func testStatusStorePersistsTunnelStatusForBridgeReaders() throws {
        let fixture = try CloudflaredStatusStoreFixture()
        let endpoint = BridgePairEndpoint(scheme: "wss",
                                          host: "stable-state.trycloudflare.com",
                                          port: nil,
                                          path: "/")
        let status = BridgeCloudflaredStatus(state: .online,
                                             endpoint: endpoint,
                                             errorMessage: nil,
                                             updatedAt: Date(timeIntervalSince1970: 1_775_000_000),
                                             processID: 12345)

        try fixture.store.writeStatus(status)

        XCTAssertEqual(try fixture.store.readStatus(), status)
    }

    func testManagerReadsTunnelStatusFromStateFileWithoutStartingProcess() throws {
        let fixture = try CloudflaredStatusStoreFixture()
        let endpoint = BridgePairEndpoint(scheme: "wss",
                                          host: "state-reader.trycloudflare.com",
                                          port: nil,
                                          path: "/")
        try fixture.store.writeStatus(BridgeCloudflaredStatus(state: .online,
                                                              endpoint: endpoint,
                                                              errorMessage: nil,
                                                              updatedAt: Date(timeIntervalSince1970: 1_775_000_100),
                                                              processID: 456))
        let runner = FakeCloudflaredRunner()
        let manager = BridgeCloudflaredManager(binaryResolver: { "/usr/local/bin/cloudflared" },
                                               processRunner: runner,
                                               statusStore: fixture.store)

        let status = manager.currentStatus()

        XCTAssertEqual(status.state, .online)
        XCTAssertEqual(status.endpoint, endpoint)
        XCTAssertEqual(runner.startedCommands, [])
    }

    func testStartAndWaitReadsTunnelStatusFromStateFileWithoutStartingProcess() throws {
        let fixture = try CloudflaredStatusStoreFixture()
        let endpoint = BridgePairEndpoint(scheme: "wss",
                                          host: "state-wait.trycloudflare.com",
                                          port: nil,
                                          path: "/")
        try fixture.store.writeStatus(BridgeCloudflaredStatus(state: .online,
                                                              endpoint: endpoint,
                                                              errorMessage: nil,
                                                              updatedAt: Date(timeIntervalSince1970: 1_775_000_200),
                                                              processID: 789))
        let runner = FakeCloudflaredRunner()
        let manager = BridgeCloudflaredManager(binaryResolver: { "/usr/local/bin/cloudflared" },
                                               processRunner: runner,
                                               statusStore: fixture.store)

        let status = manager.startAndWaitForEndpoint(timeout: 0.1)

        XCTAssertEqual(status.state, .online)
        XCTAssertEqual(status.endpoint, endpoint)
        XCTAssertEqual(runner.startedCommands, [])
    }

    func testOutputParserExtractsTryCloudflareURLFromStderrNoise() {
        let output = """
        2026-04-27T09:00:00Z INF Requesting new quick Tunnel on trycloudflare.com...
        2026-04-27T09:00:01Z INF +--------------------------------------------------------------------------------------------+
        2026-04-27T09:00:01Z INF |  Your quick Tunnel has been created! Visit it at (it may take some time to be reachable):  |
        2026-04-27T09:00:01Z INF |  https://plain-river-12.trycloudflare.com                                                   |
        2026-04-27T09:00:01Z INF +--------------------------------------------------------------------------------------------+
        """

        XCTAssertEqual(BridgeCloudflaredOutputParser.firstTunnelEndpoint(in: output),
                       BridgePairEndpoint(scheme: "wss",
                                          host: "plain-river-12.trycloudflare.com",
                                          port: nil,
                                          path: "/"))
    }

    func testManagerReportsMissingBinaryWithoutStartingProcess() {
        let runner = FakeCloudflaredRunner()
        let manager = BridgeCloudflaredManager(binaryResolver: { nil },
                                               processRunner: runner)

        let status = manager.startAndWaitForEndpoint(timeout: 0.1)

        XCTAssertEqual(status.state, .error)
        XCTAssertEqual(status.endpoint, nil)
        XCTAssertEqual(status.errorMessage, "cloudflared not found in PATH")
        XCTAssertEqual(runner.startedCommands.count, 0)
    }

    func testBinaryResolverFindsHomebrewCloudflaredWhenLaunchdPathIsNarrow() throws {
        let temporaryDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let homebrewBin = temporaryDirectory.appendingPathComponent("opt/homebrew/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: homebrewBin, withIntermediateDirectories: true)
        let cloudflared = homebrewBin.appendingPathComponent("cloudflared")
        try "#!/bin/sh\n".write(to: cloudflared, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: cloudflared.path)
        defer {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }

        let resolved = BridgeCloudflaredBinaryResolver.resolve(
            environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"],
            additionalSearchDirectories: [homebrewBin.path]
        )

        XCTAssertEqual(resolved, cloudflared.path)
    }

    func testManagerPublishesTunnelEndpointFromProcessOutput() {
        let runner = FakeCloudflaredRunner(output: "INF https://blue-bird-7.trycloudflare.com\n")
        let manager = BridgeCloudflaredManager(binaryResolver: { "/usr/local/bin/cloudflared" },
                                               processRunner: runner)

        let status = manager.startAndWaitForEndpoint(timeout: 1)

        XCTAssertEqual(status.state, .online)
        XCTAssertEqual(status.endpoint,
                       BridgePairEndpoint(scheme: "wss",
                                          host: "blue-bird-7.trycloudflare.com",
                                          port: nil,
                                          path: "/"))
        XCTAssertEqual(runner.startedCommands.first?.executablePath, "/usr/local/bin/cloudflared")
        XCTAssertEqual(runner.startedCommands.first?.arguments, [
            "tunnel",
            "--no-autoupdate",
            "--url",
            "http://localhost:4817",
        ])
    }
}

private final class FakeCloudflaredRunner: BridgeCloudflaredProcessRunning {
    var startedCommands = [BridgeCloudflaredCommand]()
    private let output: String

    init(output: String = "") {
        self.output = output
    }

    func start(command: BridgeCloudflaredCommand,
               onOutput: @escaping @Sendable (String) -> Void,
               onExit: @escaping @Sendable (Int32) -> Void) throws -> BridgeCloudflaredManagedProcess {
        startedCommands.append(command)
        if output.isEmpty == false {
            onOutput(output)
        }
        return FakeCloudflaredProcess()
    }
}

private final class FakeCloudflaredProcess: BridgeCloudflaredManagedProcess {
    private(set) var didTerminate = false

    func terminate() {
        didTerminate = true
    }
}

private final class CloudflaredStatusStoreFixture {
    let temporaryDirectory: URL
    let store: BridgeCloudflaredStatusStore

    init() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = temporaryDirectory.appendingPathComponent("cloudflared-state.json")
        store = BridgeCloudflaredStatusStore(fileURL: fileURL)
    }

    deinit {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }
}
