import Darwin
import Foundation
import XCTest
@testable import RemoteBridge

final class BridgeMediaHTTPIntegrationTests: XCTestCase {
    func testRealHTTPMediaRouteServesExactSingleRangesAndHeaders() throws {
        let fixture = try MediaHTTPFixture()
        let source = Data((0..<256).map(UInt8.init))
        let grant = try fixture.register(contents: source, prepareID: "matrix")
        let handle = try fixture.server.start()
        defer { try? handle.close() }

        let full = try request(port: handle.port, method: "GET", path: grant.leasePath)
        XCTAssertEqual(full.statusCode, 200)
        XCTAssertEqual(full.body, source)
        assertSuccessHeaders(full, mime: "video/mp4", length: 256)

        let head = try request(port: handle.port,
                               method: "HEAD",
                               path: grant.leasePath,
                               headers: ["Range": "bytes=10-19"])
        XCTAssertEqual(head.statusCode, 206)
        XCTAssertTrue(head.body.isEmpty)
        XCTAssertEqual(head.headers["content-range"], "bytes 10-19/256")
        assertSuccessHeaders(head, mime: "video/mp4", length: 10)

        for (range, expectedBounds) in [
            ("bytes=10-19", 10...19),
            ("bytes=250-", 250...255),
            ("bytes=-8", 248...255),
        ] {
            let response = try request(port: handle.port,
                                       method: "GET",
                                       path: grant.leasePath,
                                       headers: ["Range": range])
            XCTAssertEqual(response.statusCode, 206, range)
            XCTAssertEqual(response.headers["content-range"],
                           "bytes \(expectedBounds.lowerBound)-\(expectedBounds.upperBound)/256",
                           range)
            XCTAssertEqual(response.body, source.subdata(in: expectedBounds.lowerBound..<(expectedBounds.upperBound + 1)), range)
            assertSuccessHeaders(response, mime: "video/mp4", length: expectedBounds.count)
        }

        let invalid = try request(port: handle.port,
                                  method: "GET",
                                  path: grant.leasePath,
                                  headers: ["Range": "bytes=0-1,4-5"])
        XCTAssertEqual(invalid.statusCode, 416)
        XCTAssertEqual(invalid.headers["content-range"], "bytes */256")
        XCTAssertTrue(invalid.body.isEmpty)

        let unknown = try request(port: handle.port, method: "GET", path: "/media/unknown")
        XCTAssertEqual(unknown.statusCode, 404)
        XCTAssertTrue(unknown.body.isEmpty)

        let wrongMethod = try request(port: handle.port, method: "POST", path: grant.leasePath)
        XCTAssertEqual(wrongMethod.statusCode, 405)
        XCTAssertEqual(wrongMethod.headers["allow"], "GET, HEAD")
        XCTAssertTrue(wrongMethod.body.isEmpty)
    }

    func testSparseLargeFileSuffixReadsOnlyRealTailRegion() throws {
        let fixture = try MediaHTTPFixture()
        let tail = Data("tail-moov-marker".utf8)
        let grant = try fixture.registerSparse(size: 64 * 1024 * 1024,
                                               tail: tail,
                                               prepareID: "sparse")
        let handle = try fixture.server.start()
        defer { try? handle.close() }

        let response = try request(port: handle.port,
                                   method: "GET",
                                   path: grant.leasePath,
                                   headers: ["Range": "bytes=-\(tail.count)"])

        XCTAssertEqual(response.statusCode, 206)
        XCTAssertEqual(response.body, tail)
        XCTAssertEqual(response.headers["content-length"], "\(tail.count)")
        XCTAssertEqual(response.headers["content-range"],
                       "bytes \(64 * 1024 * 1024 - tail.count)-\(64 * 1024 * 1024 - 1)/\(64 * 1024 * 1024)")
    }

    private func assertSuccessHeaders(_ response: RawHTTPResponse,
                                      mime: String,
                                      length: Int,
                                      file: StaticString = #filePath,
                                      line: UInt = #line) {
        XCTAssertEqual(response.headers["content-type"], mime, file: file, line: line)
        XCTAssertEqual(response.headers["content-length"], "\(length)", file: file, line: line)
        XCTAssertEqual(response.headers["accept-ranges"], "bytes", file: file, line: line)
        XCTAssertEqual(response.headers["cache-control"], "no-store", file: file, line: line)
        XCTAssertEqual(response.headers["x-content-type-options"], "nosniff", file: file, line: line)
    }

    private func request(port: Int,
                         method: String,
                         path: String,
                         headers: [String: String] = [:]) throws -> RawHTTPResponse {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.ENOTSOCK) }
        defer { Darwin.close(descriptor) }

        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        inet_pton(AF_INET, "127.0.0.1", &address.sin_addr)
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { throw POSIXError(.ECONNREFUSED) }

        var lines = ["\(method) \(path) HTTP/1.1", "Host: 127.0.0.1:\(port)", "Connection: close"]
        lines.append(contentsOf: headers.map { "\($0.key): \($0.value)" })
        let requestData = Data((lines + ["", ""]).joined(separator: "\r\n").utf8)
        try writeAll(requestData, descriptor: descriptor)

        var received = Data()
        let separator = Data("\r\n\r\n".utf8)
        var expectedTotal: Int?
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while expectedTotal == nil || received.count < expectedTotal! {
            let count = read(descriptor, &buffer, buffer.count)
            if count > 0 {
                received.append(buffer, count: count)
                if expectedTotal == nil,
                   let headerRange = received.range(of: separator),
                   let headerText = String(data: received[..<headerRange.lowerBound], encoding: .utf8) {
                    let contentLength = Self.headerDictionary(headerText)["content-length"].flatMap(Int.init) ?? 0
                    expectedTotal = headerRange.upperBound + (method == "HEAD" ? 0 : contentLength)
                }
                continue
            }
            if count == 0 { break }
            if errno == EINTR { continue }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        guard let headerRange = received.range(of: separator),
              let headerText = String(data: received[..<headerRange.lowerBound], encoding: .utf8),
              let statusLine = headerText.components(separatedBy: "\r\n").first,
              let statusCode = Int(statusLine.split(separator: " ")[safe: 1] ?? "") else {
            throw POSIXError(.EBADMSG)
        }
        return RawHTTPResponse(statusCode: statusCode,
                               headers: Self.headerDictionary(headerText),
                               body: Data(received[headerRange.upperBound...]))
    }

    private static func headerDictionary(_ text: String) -> [String: String] {
        Dictionary(uniqueKeysWithValues: text.components(separatedBy: "\r\n").dropFirst().compactMap { line in
            guard let colon = line.firstIndex(of: ":") else { return nil }
            return (String(line[..<colon]).lowercased(),
                    String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces))
        })
    }

    private func writeAll(_ data: Data, descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, base.advanced(by: offset), bytes.count - offset)
                if count > 0 { offset += count; continue }
                if count == -1 && errno == EINTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
    }
}

private struct RawHTTPResponse {
    let statusCode: Int
    let headers: [String: String]
    let body: Data
}

private final class MediaHTTPFixture {
    let rootURL: URL
    let registry = BridgeMediaLeaseRegistry()
    let server: TideyRemoteBridgeServer

    init() throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("tidey-media-http-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let paths = BridgePaths(supportDirectory: rootURL.appendingPathComponent("support", isDirectory: true))
        let credentialStore = BridgeDeviceCredentialStore(paths: paths)
        let authenticator = BridgeAuthenticator(legacyPairToken: "legacy", deviceCredentialStore: credentialStore)
        let pairing = BridgePairingController(
            hostIdentityStore: BridgeHostIdentityStore(paths: paths),
            pairSessionStore: BridgePairSessionStore(),
            deviceCredentialStore: credentialStore
        )
        let eventHub = AgentEventHub()
        let socketClient = TideySocketClient(locator: TideySocketLocator())
        let monitor = AgentSessionRegistryMonitor(paths: paths,
                                                  fileManager: .default,
                                                  hub: eventHub,
                                                  socketClient: socketClient,
                                                  parentPIDLookup: { _ in nil })
        server = TideyRemoteBridgeServer(
            host: "127.0.0.1",
            port: 0,
            token: "legacy",
            authenticator: authenticator,
            pairingController: pairing,
            socketClient: socketClient,
            eventHub: eventHub,
            workspaceEventHub: WorkspaceEventHub(),
            registryMonitor: monitor,
            terminalObserver: OrdinaryTmuxTerminalObserverRegistry(
                makeProcess: OrdinaryTmuxLiveControlModeProcess.factory(executablePath: nil)
            ),
            observability: BridgeObservabilityCenter(),
            uploadGarbageCollector: BridgeUploadGarbageCollector(uploadDirectory: rootURL.appendingPathComponent("uploads")),
            startRegistryMonitor: false,
            startCloudflaredSupervisor: false,
            mediaLeaseRegistry: registry
        )
    }

    deinit { try? FileManager.default.removeItem(at: rootURL) }

    func register(contents: Data, prepareID: String) throws -> BridgeMediaLeaseGrant {
        let url = rootURL.appendingPathComponent("fixture-\(prepareID).mp4")
        try contents.write(to: url)
        return try registry.register(openedFile: open(url),
                                     deviceID: "device",
                                     prepareID: prepareID,
                                     mime: "video/mp4")
    }

    func registerSparse(size: Int, tail: Data, prepareID: String) throws -> BridgeMediaLeaseGrant {
        let url = rootURL.appendingPathComponent("fixture-\(prepareID).mp4")
        let descriptor = Darwin.open(url.path, O_CREAT | O_RDWR | O_TRUNC | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        defer { Darwin.close(descriptor) }
        guard ftruncate(descriptor, off_t(size)) == 0 else { throw POSIXError(.EIO) }
        let written = tail.withUnsafeBytes { bytes in
            pwrite(descriptor, bytes.baseAddress, bytes.count, off_t(size - tail.count))
        }
        guard written == tail.count else { throw POSIXError(.EIO) }
        return try registry.register(openedFile: open(url),
                                     deviceID: "device",
                                     prepareID: prepareID,
                                     mime: "video/mp4")
    }

    private func open(_ url: URL) throws -> BridgeSafeOpenedFile {
        try BridgeSafeFileOpener.openRegularFile(at: url,
                                                notFoundMessage: "missing",
                                                outsideScopeMessage: "outside")
    }
}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
