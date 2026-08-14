import Darwin
import Foundation
import XCTest

@testable import RemoteBridge

final class OrdinaryTmuxWindowSizeIntegrationTests: XCTestCase {
    func testDisposableHarnessPinsEveryServerCommandToItsIsolatedSocket() throws {
        guard let tmuxPath = TmuxStateResolver.discoverTmuxBinaryPath() else {
            throw XCTSkip("tmux is unavailable")
        }
        let version = try IsolatedTmuxHarness.version(at: tmuxPath)
        guard version == "tmux 3.6a" else {
            throw XCTSkip("isolated sizing regression requires tmux 3.6a; found \(version)")
        }

        let harness = try IsolatedTmuxHarness(tmuxPath: tmuxPath)
        defer { harness.shutdown() }

        try harness.startDetachedSession(name: "socket-proof", columns: 132, rows: 37)

        XCTAssertEqual(
            try harness.windowGeometry(sessionName: "socket-proof"),
            "socket-proof|132|37|latest"
        )
        XCTAssertTrue(harness.serverArguments.isEmpty == false)
        XCTAssertTrue(harness.serverArguments.allSatisfy {
            Array($0.prefix(2)) == ["-S", harness.socketPath]
        })

        harness.shutdown()
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.rootURL.path))
    }

    func testControlModeSizingClientReportsReadyAndDetachesWithinBoundedTime() throws {
        guard let tmuxPath = TmuxStateResolver.discoverTmuxBinaryPath() else {
            throw XCTSkip("tmux is unavailable")
        }
        let version = try IsolatedTmuxHarness.version(at: tmuxPath)
        guard version == "tmux 3.6a" else {
            throw XCTSkip("isolated sizing regression requires tmux 3.6a; found \(version)")
        }

        let harness = try IsolatedTmuxHarness(tmuxPath: tmuxPath)
        defer { harness.shutdown() }
        try harness.startDetachedSession(name: "client-proof", columns: 132, rows: 37)

        let client = try harness.attachControlModeSizingClient(
            sessionName: "client-proof",
            columns: 100,
            rows: 30
        )

        XCTAssertTrue(
            harness.waitForWindowGeometry(
                sessionName: "client-proof",
                expected: "client-proof|100|30|latest",
                timeout: 2
            )
        )
        XCTAssertEqual(try harness.clientCount(), 1)
        XCTAssertEqual(try client.detachAndWait(timeout: 2), 0)
        XCTAssertTrue(harness.waitForClientCount(0, timeout: 2))
    }

    func testTTYBackedControlClientExposesUniqueTTYForAdapterMatching() throws {
        guard let tmuxPath = TmuxStateResolver.discoverTmuxBinaryPath() else {
            throw XCTSkip("tmux is unavailable")
        }
        let version = try IsolatedTmuxHarness.version(at: tmuxPath)
        guard version == "tmux 3.6a" else {
            throw XCTSkip("isolated sizing regression requires tmux 3.6a; found \(version)")
        }
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/script") else {
            throw XCTSkip("macOS script is unavailable")
        }

        let harness = try IsolatedTmuxHarness(tmuxPath: tmuxPath)
        defer { harness.shutdown() }
        try harness.startDetachedSession(name: "tty-proof", columns: 132, rows: 37)

        let client = try harness.attachControlModeSizingClient(
            sessionName: "tty-proof",
            columns: 132,
            rows: 37,
            allocatingTTY: true
        )

        XCTAssertTrue(harness.waitForClientCount(1, timeout: 2))
        let fields = try XCTUnwrap(try harness.clientRecords().first?.split(separator: "|"))
        XCTAssertEqual(fields.count, 3)
        XCTAssertTrue(fields[0].hasPrefix("/dev/ttys"))
        XCTAssertTrue(fields[2].contains("control-mode"))
        XCTAssertFalse(fields[2].contains("ignore-size"))

        XCTAssertEqual(try client.detachAndWait(timeout: 2), 0)
        XCTAssertTrue(harness.waitForClientCount(0, timeout: 2))
    }

    func testAdapterClaimsLargestBeforeSecondSizingClientAttaches() throws {
        guard let tmuxPath = TmuxStateResolver.discoverTmuxBinaryPath() else {
            throw XCTSkip("tmux is unavailable")
        }
        let version = try IsolatedTmuxHarness.version(at: tmuxPath)
        guard version == "tmux 3.6a" else {
            throw XCTSkip("isolated sizing regression requires tmux 3.6a; found \(version)")
        }
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/script") else {
            throw XCTSkip("macOS script is unavailable")
        }

        let harness = try IsolatedTmuxHarness(tmuxPath: tmuxPath)
        defer { harness.shutdown() }
        try harness.startDetachedSession(name: "adapter-claim", columns: 132, rows: 37)
        _ = try harness.attachControlModeSizingClient(
            sessionName: "adapter-claim",
            columns: 132,
            rows: 37,
            allocatingTTY: true
        )
        XCTAssertTrue(harness.waitForClientCount(1, timeout: 2))
        let clientTTY = try XCTUnwrap(
            try harness.clientRecords().first?.split(separator: "|").first.map(String.init)
        )

        let isolatedSocket = OrdinaryTmuxSocketSelector.path(harness.socketPath)
        let liveRunner = OrdinaryTmuxCLIAdapter.processCommandRunner(
            executablePath: tmuxPath,
            timeoutSeconds: 3
        )
        let adapter = OrdinaryTmuxCLIAdapter { socket, arguments, stdin in
            guard socket == isolatedSocket else {
                throw CocoaError(.fileReadNoPermission)
            }
            return try liveRunner(socket, arguments, stdin)
        }

        let panels = try adapter.projectedPanels(
            for: OrdinaryTmuxAttachMetadata(
                clientTTY: clientTTY,
                targetSession: "adapter-claim",
                socketPath: harness.socketPath
            )
        )

        XCTAssertEqual(panels.count, 1)
        XCTAssertEqual(try harness.clientCount(), 1)
        XCTAssertEqual(
            try harness.windowSizeOwnership(sessionName: "adapter-claim"),
            "largest|latest"
        )
    }

    func testLargestPolicyKeepsMacGeometryStableAcrossSecondaryAttachResizeAndDetach() throws {
        guard let tmuxPath = TmuxStateResolver.discoverTmuxBinaryPath() else {
            throw XCTSkip("tmux is unavailable")
        }
        let version = try IsolatedTmuxHarness.version(at: tmuxPath)
        guard version == "tmux 3.6a" else {
            throw XCTSkip("isolated sizing regression requires tmux 3.6a; found \(version)")
        }
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/script") else {
            throw XCTSkip("macOS script is unavailable")
        }

        let harness = try IsolatedTmuxHarness(tmuxPath: tmuxPath)
        defer { harness.shutdown() }
        let sessionName = "largest-stable"
        try harness.startDetachedSession(name: sessionName, columns: 132, rows: 37)
        _ = try harness.attachControlModeSizingClient(
            sessionName: sessionName,
            columns: 132,
            rows: 37,
            allocatingTTY: true
        )
        XCTAssertTrue(harness.waitForClientCount(1, timeout: 2))
        let clientTTY = try XCTUnwrap(
            try harness.clientRecords().first?.split(separator: "|").first.map(String.init)
        )

        let isolatedSocket = OrdinaryTmuxSocketSelector.path(harness.socketPath)
        let liveRunner = OrdinaryTmuxCLIAdapter.processCommandRunner(
            executablePath: tmuxPath,
            timeoutSeconds: 3
        )
        let adapter = OrdinaryTmuxCLIAdapter { socket, arguments, stdin in
            guard socket == isolatedSocket else {
                throw CocoaError(.fileReadNoPermission)
            }
            return try liveRunner(socket, arguments, stdin)
        }
        _ = try adapter.projectedPanels(
            for: OrdinaryTmuxAttachMetadata(
                clientTTY: clientTTY,
                targetSession: sessionName,
                socketPath: harness.socketPath
            )
        )
        XCTAssertEqual(try harness.windowSizeOwnership(sessionName: sessionName), "largest|latest")

        try harness.splitWindowHorizontally(sessionName: sessionName, percentage: 30)
        let macGeometry = try harness.paneGeometry(sessionName: sessionName)
        XCTAssertEqual(macGeometry.count, 2)

        let phoneClient = try harness.attachControlModeSizingClient(
            sessionName: sessionName,
            columns: 60,
            rows: 20
        )
        XCTAssertTrue(harness.waitForClientCount(2, timeout: 2))
        XCTAssertTrue(
            harness.waitForWindowGeometry(
                sessionName: sessionName,
                expected: "\(sessionName)|132|37|largest",
                timeout: 2
            )
        )
        XCTAssertEqual(try harness.paneGeometry(sessionName: sessionName), macGeometry)

        for size in [(80, 25), (50, 18)] {
            try phoneClient.writeLine("refresh-client -C \(size.0),\(size.1)")
            XCTAssertTrue(
                harness.waitForWindowGeometry(
                    sessionName: sessionName,
                    expected: "\(sessionName)|132|37|largest",
                    timeout: 2
                )
            )
            XCTAssertEqual(try harness.paneGeometry(sessionName: sessionName), macGeometry)
        }

        XCTAssertEqual(try phoneClient.detachAndWait(timeout: 2), 0)
        XCTAssertTrue(harness.waitForClientCount(1, timeout: 2))
        XCTAssertEqual(try harness.paneGeometry(sessionName: sessionName), macGeometry)
    }

    func testLatestPolicyRestoresMacWindowSizeAndPaneTopologyAfterPhoneDetach() throws {
        guard let tmuxPath = TmuxStateResolver.discoverTmuxBinaryPath() else {
            throw XCTSkip("tmux is unavailable")
        }
        let version = try IsolatedTmuxHarness.version(at: tmuxPath)
        guard version == "tmux 3.6a" else {
            throw XCTSkip("isolated sizing regression requires tmux 3.6a; found \(version)")
        }
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/script") else {
            throw XCTSkip("macOS script is unavailable")
        }

        func assertHorizontalSplit(
            _ geometry: [IsolatedTmuxPaneGeometry],
            columns: Int,
            rows: Int,
            paneIDs: [String]
        ) {
            guard geometry.count == 2 else {
                XCTFail("expected exactly two horizontal panes; found \(geometry.count)")
                return
            }
            XCTAssertEqual(geometry.map(\.paneID), paneIDs)
            XCTAssertEqual(geometry.map(\.paneIndex), [0, 1])
            XCTAssertEqual(geometry.map(\.windowWidth), [columns, columns])
            XCTAssertEqual(geometry.map(\.windowHeight), [rows, rows])
            XCTAssertEqual(geometry.map(\.left), [0, geometry[0].width + 1])
            XCTAssertEqual(geometry.map(\.top), [0, 0])
            XCTAssertEqual(geometry.map(\.height), [rows, rows])
            XCTAssertTrue(
                geometry.allSatisfy { $0.width > 0 },
                "expected tmux to keep every pane structurally valid: \(geometry)"
            )
            XCTAssertEqual(geometry.reduce(1) { $0 + $1.width }, columns)
        }

        let harness = try IsolatedTmuxHarness(tmuxPath: tmuxPath)
        defer { harness.shutdown() }
        let sessionName = "latest-topology"
        try harness.startDetachedSession(name: sessionName, columns: 132, rows: 37)
        _ = try harness.attachControlModeSizingClient(
            sessionName: sessionName,
            columns: 132,
            rows: 37,
            allocatingTTY: true
        )
        XCTAssertTrue(harness.waitForClientCount(1, timeout: 2))
        XCTAssertEqual(try harness.windowSizeOwnership(sessionName: sessionName), "latest|")

        try harness.splitWindowHorizontally(sessionName: sessionName, percentage: 30)
        let macGeometry = try harness.paneGeometry(sessionName: sessionName)
        XCTAssertEqual(macGeometry.count, 2)
        let paneIDs = macGeometry.map(\.paneID)
        assertHorizontalSplit(macGeometry, columns: 132, rows: 37, paneIDs: paneIDs)

        let phoneClient = try harness.attachControlModeSizingClient(
            sessionName: sessionName,
            columns: 60,
            rows: 20
        )
        XCTAssertTrue(harness.waitForClientCount(2, timeout: 2))

        for size in [(60, 20), (80, 25), (50, 18)] {
            try phoneClient.writeLine("refresh-client -C \(size.0),\(size.1)")
            XCTAssertTrue(
                harness.waitForWindowGeometry(
                    sessionName: sessionName,
                    expected: "\(sessionName)|\(size.0)|\(size.1)|latest",
                    timeout: 2
                )
            )
            let phoneGeometry = try harness.paneGeometry(sessionName: sessionName)
            XCTAssertEqual(phoneGeometry.count, 2)
            assertHorizontalSplit(
                phoneGeometry,
                columns: size.0,
                rows: size.1,
                paneIDs: paneIDs
            )
            XCTAssertEqual(try harness.windowSizeOwnership(sessionName: sessionName), "latest|")
        }

        XCTAssertEqual(try phoneClient.detachAndWait(timeout: 2), 0)
        XCTAssertTrue(harness.waitForClientCount(1, timeout: 2))
        XCTAssertTrue(
            harness.waitForWindowGeometry(
                sessionName: sessionName,
                expected: "\(sessionName)|132|37|latest",
                timeout: 2
            )
        )
        let restoredMacGeometry = try harness.paneGeometry(sessionName: sessionName)
        XCTAssertEqual(restoredMacGeometry.count, 2)
        assertHorizontalSplit(restoredMacGeometry, columns: 132, rows: 37, paneIDs: paneIDs)
        XCTAssertEqual(try harness.windowSizeOwnership(sessionName: sessionName), "latest|")
    }
}

private struct IsolatedTmuxPaneGeometry: Equatable {
    enum ParsingError: Error {
        case invalidRecord(String)
    }

    let paneID: String
    let paneIndex: Int
    let left: Int
    let top: Int
    let width: Int
    let height: Int
    let windowWidth: Int
    let windowHeight: Int

    init(record: Substring) throws {
        let fields = record.split(separator: "|", omittingEmptySubsequences: false)
        guard fields.count == 8,
              let paneIndex = Int(fields[1]),
              let left = Int(fields[2]),
              let top = Int(fields[3]),
              let width = Int(fields[4]),
              let height = Int(fields[5]),
              let windowWidth = Int(fields[6]),
              let windowHeight = Int(fields[7]) else {
            throw ParsingError.invalidRecord(String(record))
        }
        paneID = String(fields[0])
        self.paneIndex = paneIndex
        self.left = left
        self.top = top
        self.width = width
        self.height = height
        self.windowWidth = windowWidth
        self.windowHeight = windowHeight
    }
}

private final class IsolatedTmuxControlClient: @unchecked Sendable {
    enum ClientError: Error {
        case unavailable
        case exitTimedOut
        case outputDrainTimedOut
    }

    private final class DataAccumulator: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = Data()

        func append(_ data: Data) {
            lock.lock()
            if storage.count < 64 * 1024 {
                storage.append(data.prefix(64 * 1024 - storage.count))
            }
            lock.unlock()
        }
    }

    private let process = Process()
    private let inputPipe = Pipe()
    private let outputPipe = Pipe()
    private let errorPipe = Pipe()
    private let writeQueue = DispatchQueue(label: "com.tidey.tests.tmux-sizing-client-input")
    private let terminationGroup = DispatchGroup()
    private let readerGroup = DispatchGroup()
    private let output = DataAccumulator()
    private let errorOutput = DataAccumulator()

    init(executablePath: String, arguments: [String]) throws {
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["LC_CTYPE"] = "UTF-8"
        environment["LANG"] = "en_US.UTF-8"
        environment["TERM"] = "xterm-256color"
        process.environment = environment
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        terminationGroup.enter()
        process.terminationHandler = { [terminationGroup] _ in
            terminationGroup.leave()
        }
        do {
            try process.run()
        } catch {
            terminationGroup.leave()
            throw error
        }

        try? inputPipe.fileHandleForReading.close()
        try? outputPipe.fileHandleForWriting.close()
        try? errorPipe.fileHandleForWriting.close()

        readerGroup.enter()
        DispatchQueue.global(qos: .utility).async { [outputPipe, output, readerGroup] in
            output.append((try? outputPipe.fileHandleForReading.readToEnd()) ?? Data())
            readerGroup.leave()
        }
        readerGroup.enter()
        DispatchQueue.global(qos: .utility).async { [errorPipe, errorOutput, readerGroup] in
            errorOutput.append((try? errorPipe.fileHandleForReading.readToEnd()) ?? Data())
            readerGroup.leave()
        }
    }

    func writeLine(_ line: String) throws {
        try writeQueue.sync {
            guard process.isRunning else {
                throw ClientError.unavailable
            }
            try inputPipe.fileHandleForWriting.write(contentsOf: Data((line + "\n").utf8))
        }
    }

    func detachAndWait(timeout: TimeInterval) throws -> Int32 {
        try writeLine("detach-client")
        guard terminationGroup.wait(timeout: .now() + timeout) == .success else {
            throw ClientError.exitTimedOut
        }
        guard readerGroup.wait(timeout: .now() + 1) == .success else {
            throw ClientError.outputDrainTimedOut
        }
        return process.terminationStatus
    }

    func shutdown() {
        if process.isRunning {
            try? writeLine("detach-client")
        }
        if terminationGroup.wait(timeout: .now() + 0.5) != .success,
           process.isRunning {
            process.terminate()
            _ = terminationGroup.wait(timeout: .now() + 0.5)
        }
        try? inputPipe.fileHandleForWriting.close()
        _ = readerGroup.wait(timeout: .now() + 0.5)
    }
}

private final class IsolatedTmuxHarness {
    enum HarnessError: Error, CustomStringConvertible {
        case commandFailed(arguments: [String], status: Int32, stderr: String)
        case commandTimedOut(arguments: [String])

        var description: String {
            switch self {
            case .commandFailed(let arguments, let status, let stderr):
                return "tmux command failed (\(status)): \(arguments.joined(separator: " ")): \(stderr)"
            case .commandTimedOut(let arguments):
                return "tmux command timed out: \(arguments.joined(separator: " "))"
            }
        }
    }

    let rootURL: URL
    let socketPath: String

    private let tmuxPath: String
    private let lock = NSLock()
    private var recordedServerArguments = [[String]]()
    private var controlClients = [IsolatedTmuxControlClient]()
    private var hasStartedServer = false
    private var isShutDown = false

    init(tmuxPath: String) throws {
        self.tmuxPath = tmuxPath
        let shortTemporaryRoot = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .standardizedFileURL
        rootURL = shortTemporaryRoot
            .appendingPathComponent("tidey-tmux-size-\(UUID().uuidString.prefix(12))", isDirectory: true)
            .standardizedFileURL
        guard rootURL.path.hasPrefix(shortTemporaryRoot.path + "/"),
              rootURL.appendingPathComponent("socket", isDirectory: false).path.utf8.count < 100 else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        try FileManager.default.createDirectory(at: rootURL,
                                                withIntermediateDirectories: false)
        socketPath = rootURL.appendingPathComponent("socket", isDirectory: false).path
    }

    static func version(at tmuxPath: String) throws -> String {
        let arguments = ["-V"]
        guard let result = BoundedProcessRunner.run(executablePath: tmuxPath,
                                                    arguments: arguments,
                                                    timeout: 2,
                                                    circuitBreakerCooldown: 0) else {
            throw HarnessError.commandTimedOut(arguments: arguments)
        }
        guard result.terminationStatus == 0 else {
            throw HarnessError.commandFailed(
                arguments: arguments,
                status: result.terminationStatus,
                stderr: String(decoding: result.standardError, as: UTF8.self)
            )
        }
        return String(decoding: result.standardOutput, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var serverArguments: [[String]] {
        lock.lock()
        defer { lock.unlock() }
        return recordedServerArguments
    }

    func startDetachedSession(name: String, columns: Int, rows: Int) throws {
        _ = try runServerCommand([
            "-f", "/dev/null",
            "new-session", "-d",
            "-s", name,
            "-x", String(columns),
            "-y", String(rows),
        ])
        lock.lock()
        hasStartedServer = true
        lock.unlock()
    }

    func windowGeometry(sessionName: String) throws -> String {
        try runServerCommand([
            "list-windows",
            "-t", "=\(sessionName)",
            "-F", "#{session_name}|#{window_width}|#{window_height}|#{window-size}",
        ])
    }

    func windowSizeOwnership(sessionName: String) throws -> String {
        try runServerCommand([
            "list-windows",
            "-t", "=\(sessionName)",
            "-F", "#{window-size}|#{@tidey_window_size_before_multi_client}",
        ])
    }

    func splitWindowHorizontally(sessionName: String, percentage: Int) throws {
        _ = try runServerCommand([
            "split-window",
            "-h",
            "-p", String(percentage),
            "-t", "=\(sessionName):0",
        ])
    }

    func paneGeometry(sessionName: String) throws -> [IsolatedTmuxPaneGeometry] {
        let output = try runServerCommand([
            "list-panes",
            "-t", "=\(sessionName):0",
            "-F", "#{pane_id}|#{pane_index}|#{pane_left}|#{pane_top}|#{pane_width}|#{pane_height}|#{window_width}|#{window_height}",
        ])
        return try output.split(whereSeparator: \.isNewline).map {
            try IsolatedTmuxPaneGeometry(record: $0)
        }
    }

    func attachControlModeSizingClient(
        sessionName: String,
        columns: Int,
        rows: Int,
        allocatingTTY: Bool = false
    ) throws -> IsolatedTmuxControlClient {
        let tmuxArguments = [
            "-S", socketPath,
            "-f", "/dev/null",
            "-C", "attach-session",
            "-t", "=\(sessionName)",
        ]
        let executablePath: String
        let arguments: [String]
        if allocatingTTY {
            executablePath = "/usr/bin/script"
            arguments = ["-q", "/dev/null", tmuxPath] + tmuxArguments
        } else {
            executablePath = tmuxPath
            arguments = tmuxArguments
        }
        let client = try IsolatedTmuxControlClient(
            executablePath: executablePath,
            arguments: arguments
        )
        lock.lock()
        controlClients.append(client)
        lock.unlock()
        try client.writeLine("refresh-client -C \(columns),\(rows)")
        return client
    }

    func clientCount() throws -> Int {
        try clientRecords().count
    }

    func clientRecords() throws -> [Substring] {
        let output = try runServerCommand([
            "list-clients",
            "-F", "#{client_tty}|#{client_pid}|#{client_flags}",
        ])
        return output.split(whereSeparator: \.isNewline)
    }

    func waitForWindowGeometry(
        sessionName: String,
        expected: String,
        timeout: TimeInterval
    ) -> Bool {
        waitUntil(timeout: timeout) {
            (try? self.windowGeometry(sessionName: sessionName)) == expected
        }
    }

    func waitForClientCount(_ expected: Int, timeout: TimeInterval) -> Bool {
        waitUntil(timeout: timeout) {
            (try? self.clientCount()) == expected
        }
    }

    func shutdown() {
        lock.lock()
        guard isShutDown == false else {
            lock.unlock()
            return
        }
        isShutDown = true
        let shouldKillServer = hasStartedServer
        let clients = controlClients
        controlClients.removeAll()
        lock.unlock()

        clients.forEach { $0.shutdown() }
        if shouldKillServer {
            _ = try? runServerCommand(["kill-server"])
        }
        try? FileManager.default.removeItem(at: rootURL)
    }

    @discardableResult
    private func runServerCommand(_ commandArguments: [String]) throws -> String {
        let arguments = ["-S", socketPath] + commandArguments
        lock.lock()
        recordedServerArguments.append(arguments)
        lock.unlock()

        guard let result = BoundedProcessRunner.run(executablePath: tmuxPath,
                                                    arguments: arguments,
                                                    timeout: 3,
                                                    circuitBreakerCooldown: 0) else {
            throw HarnessError.commandTimedOut(arguments: arguments)
        }
        guard result.terminationStatus == 0 else {
            throw HarnessError.commandFailed(
                arguments: arguments,
                status: result.terminationStatus,
                stderr: String(decoding: result.standardError, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return String(decoding: result.standardOutput, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func waitUntil(
        timeout: TimeInterval,
        predicate: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if predicate() {
                return true
            }
            usleep(20_000)
        } while Date() < deadline
        return predicate()
    }
}
