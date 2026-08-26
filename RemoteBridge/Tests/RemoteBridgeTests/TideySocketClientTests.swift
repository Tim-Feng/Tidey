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

    private static func makeSocketPair() throws -> (client: Int32, peer: Int32) {
        var descriptors = [Int32](repeating: -1, count: 2)
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return (descriptors[0], descriptors[1])
    }
}
