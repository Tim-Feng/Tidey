import Darwin
import XCTest
@testable import RemoteBridge

// A second Bridge process must not reach stateful work: binding the configured listener is the
// ownership gate. Before this change start() ran the registry monitor (whose sidebar sync sends
// owner-less workspace resets) before binding. On 2026-09-25 logs showed a second Bridge process
// with sidebar send failures; whether its resets reached the native store was not traced.
final class BridgeStartupOrderingTests: XCTestCase {
    func testBindFailureStartsNoRegistrySyncAndNoPostBindServices() throws {
        let occupied = try LoopbackListener()
        let syncer = CountingRuntimeSyncer()
        var postBindStarts = 0
        let server = try Self.server(port: occupied.port, syncer: syncer)

        XCTAssertThrowsError(try server.start(afterBind: { postBindStarts += 1 }))

        XCTAssertEqual(syncer.syncCount, 0, "a process that does not own the listener must send no sidebar resets")
        XCTAssertEqual(postBindStarts, 0)
    }

    func testSuccessfulBindStartsRegistryAndServicesAfterListening() throws {
        let syncer = CountingRuntimeSyncer()
        var syncsSeenByPostBind: Int?
        let server = try Self.server(port: 0, syncer: syncer)

        let handle = try server.start(afterBind: { syncsSeenByPostBind = syncer.syncCount })
        defer { try? handle.close() }

        XCTAssertGreaterThan(handle.port, 0)
        XCTAssertGreaterThanOrEqual(syncer.syncCount, 1, "the registry monitor starts once the listener is owned")
        XCTAssertNotNil(syncsSeenByPostBind)
    }

    private static func server(port: Int, syncer: CountingRuntimeSyncer) throws -> TideyRemoteBridgeServer {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let paths = BridgePaths(supportDirectory: directory)
        let eventHub = AgentEventHub()
        let socketClient = TideySocketClient(socketPathResolver: { nil },
                                             socketConnector: { _ in throw BridgeInternalError.socketUnavailable },
                                             retryWait: { _ in })
        let credentials = BridgeDeviceCredentialStore(paths: paths)
        let registryMonitor = AgentSessionRegistryMonitor(paths: paths,
                                                           fileManager: .default,
                                                           hub: eventHub,
                                                           socketClient: socketClient,
                                                           parentPIDLookup: { _ in nil },
                                                           runtimeSyncer: syncer)
        return TideyRemoteBridgeServer(host: "127.0.0.1",
                                       port: port,
                                       token: "legacy-token",
                                       authenticator: BridgeAuthenticator(legacyPairToken: "legacy-token",
                                                                          deviceCredentialStore: credentials),
                                       pairingController: BridgePairingController(
                                           hostIdentityStore: BridgeHostIdentityStore(paths: paths),
                                           pairSessionStore: BridgePairSessionStore(),
                                           deviceCredentialStore: credentials),
                                       socketClient: socketClient,
                                       eventHub: eventHub,
                                       workspaceEventHub: WorkspaceEventHub(),
                                       registryMonitor: registryMonitor,
                                       terminalObserver: OrdinaryTmuxTerminalObserverRegistry(
                                           makeProcess: OrdinaryTmuxLiveControlModeProcess.factory(executablePath: nil)
                                       ),
                                       observability: BridgeObservabilityCenter(),
                                       startCloudflaredSupervisor: false)
    }
}

private final class CountingRuntimeSyncer: AgentSessionRuntimeSyncing {
    private let lock = NSLock()
    private var count = 0

    var syncCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func sync(records: [AgentSessionRegistryRecord]) {
        lock.lock()
        count += 1
        lock.unlock()
    }
}

/// An isolated loopback listener on an ephemeral port (never the production port).
private final class LoopbackListener {
    let fd: Int32
    let port: Int

    init() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 1) == 0 else {
            close(fd)
            throw POSIXError(.EADDRINUSE)
        }
        self.fd = fd
        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &actual) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        port = Int(UInt16(bigEndian: actual.sin_port))
    }

    deinit {
        close(fd)
    }
}
