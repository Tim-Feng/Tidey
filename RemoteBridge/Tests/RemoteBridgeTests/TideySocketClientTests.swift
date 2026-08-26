import Darwin
import XCTest
@testable import RemoteBridge

final class TideySocketClientTests: XCTestCase {
    func testInjectedTransportSendsCommand() throws {
        let sockets = try Self.makeSocketPair()
        defer { close(sockets.peer) }
        let client = TideySocketClient(socketPathResolver: { "/test/tidey.sock" },
                                       socketConnector: { path in
                                           XCTAssertEqual(path, "/test/tidey.sock")
                                           return sockets.client
                                       },
                                       retryWait: { _ in })

        try client.send(command: "report_shell_state prompt")

        var buffer = [UInt8](repeating: 0, count: 128)
        let count = read(sockets.peer, &buffer, buffer.count)
        XCTAssertGreaterThan(count, 0)
        XCTAssertEqual(String(decoding: buffer.prefix(max(0, count)), as: UTF8.self),
                       "report_shell_state prompt\n")
    }

    func testConcurrentCommandSendsAreSerialized() {
        let connector = ConcurrentSocketConnector()
        defer { connector.closePeers() }
        let client = TideySocketClient(socketPathResolver: { "/test/tidey.sock" },
                                       socketConnector: connector.connect,
                                       retryWait: { _ in })
        let group = DispatchGroup()
        let failures = FailureRecorder()

        for index in 0..<2 {
            group.enter()
            DispatchQueue.global().async {
                defer { group.leave() }
                do {
                    try client.send(command: "command-\(index)")
                } catch {
                    failures.record(error)
                }
            }
        }

        XCTAssertEqual(group.wait(timeout: .now() + 2), .success)
        XCTAssertTrue(failures.errors.isEmpty, "unexpected send errors: \(failures.errors)")
        XCTAssertEqual(connector.maximumConcurrentCalls, 1)
    }

    func testCommandSendRetriesTransientConnectionRefusal() {
        let connector = RefusingSocketConnector(refusalCount: 2)
        defer { connector.closePeer() }
        let waits = WaitRecorder()
        let client = TideySocketClient(socketPathResolver: { "/test/tidey.sock" },
                                       socketConnector: connector.connect,
                                       retryWait: waits.record)

        XCTAssertNoThrow(try client.send(command: "report_shell_state prompt"))
        XCTAssertEqual(connector.attemptCount, 3)
        XCTAssertEqual(waits.delays, [0.01, 0.025])
    }

    func testCommandSendStopsAfterBoundedConnectionRefusalRetries() {
        let connector = RefusingSocketConnector(refusalCount: 3)
        let waits = WaitRecorder()
        let client = TideySocketClient(socketPathResolver: { "/test/tidey.sock" },
                                       socketConnector: connector.connect,
                                       retryWait: waits.record)

        XCTAssertThrowsError(try client.send(command: "report_shell_state prompt")) { error in
            XCTAssertEqual((error as? POSIXError)?.code, .ECONNREFUSED)
        }
        XCTAssertEqual(connector.attemptCount, 3)
        XCTAssertEqual(waits.delays, [0.01, 0.025])
    }

    func testCommandSendDoesNotRetryOtherSocketErrors() {
        var attemptCount = 0
        let waits = WaitRecorder()
        let client = TideySocketClient(socketPathResolver: { "/test/tidey.sock" },
                                       socketConnector: { _ in
                                           attemptCount += 1
                                           throw POSIXError(.EACCES)
                                       },
                                       retryWait: waits.record)

        XCTAssertThrowsError(try client.send(command: "report_shell_state prompt")) { error in
            XCTAssertEqual((error as? POSIXError)?.code, .EACCES)
        }
        XCTAssertEqual(attemptCount, 1)
        XCTAssertTrue(waits.delays.isEmpty)
    }

    private static func makeSocketPair() throws -> (client: Int32, peer: Int32) {
        var descriptors = [Int32](repeating: -1, count: 2)
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return (descriptors[0], descriptors[1])
    }
}

private final class RefusingSocketConnector {
    private let lock = NSLock()
    private let refusalCount: Int
    private var attempts = 0
    private var peerDescriptor: Int32 = -1

    init(refusalCount: Int) {
        self.refusalCount = refusalCount
    }

    var attemptCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return attempts
    }

    func connect(path: String) throws -> Int32 {
        lock.lock()
        attempts += 1
        let attempt = attempts
        lock.unlock()
        if attempt <= refusalCount {
            throw POSIXError(.ECONNREFUSED)
        }

        var descriptors = [Int32](repeating: -1, count: 2)
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        lock.lock()
        peerDescriptor = descriptors[1]
        lock.unlock()
        return descriptors[0]
    }

    func closePeer() {
        lock.lock()
        let descriptor = peerDescriptor
        peerDescriptor = -1
        lock.unlock()
        if descriptor >= 0 {
            close(descriptor)
        }
    }
}

private final class WaitRecorder {
    private let lock = NSLock()
    private var recordedDelays = [TimeInterval]()

    var delays: [TimeInterval] {
        lock.lock()
        defer { lock.unlock() }
        return recordedDelays
    }

    func record(_ delay: TimeInterval) {
        lock.lock()
        recordedDelays.append(delay)
        lock.unlock()
    }
}

private final class ConcurrentSocketConnector {
    private let lock = NSLock()
    private let overlapGate = DispatchSemaphore(value: 0)
    private var activeCalls = 0
    private var peakActiveCalls = 0
    private var peerDescriptors = [Int32]()

    var maximumConcurrentCalls: Int {
        lock.lock()
        defer { lock.unlock() }
        return peakActiveCalls
    }

    func connect(path: String) throws -> Int32 {
        lock.lock()
        activeCalls += 1
        peakActiveCalls = max(peakActiveCalls, activeCalls)
        let shouldWaitForOverlap = activeCalls == 1
        lock.unlock()

        if shouldWaitForOverlap {
            _ = overlapGate.wait(timeout: .now() + 0.1)
        } else {
            overlapGate.signal()
        }

        var descriptors = [Int32](repeating: -1, count: 2)
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
            lock.lock()
            activeCalls -= 1
            lock.unlock()
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        lock.lock()
        activeCalls -= 1
        peerDescriptors.append(descriptors[1])
        lock.unlock()
        return descriptors[0]
    }

    func closePeers() {
        lock.lock()
        let descriptors = peerDescriptors
        peerDescriptors.removeAll()
        lock.unlock()
        descriptors.forEach { close($0) }
    }
}

private final class FailureRecorder {
    private let lock = NSLock()
    private var recordedErrors = [Error]()

    var errors: [Error] {
        lock.lock()
        defer { lock.unlock() }
        return recordedErrors
    }

    func record(_ error: Error) {
        lock.lock()
        recordedErrors.append(error)
        lock.unlock()
    }
}
