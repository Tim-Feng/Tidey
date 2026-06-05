import XCTest
@testable import RemoteBridge

final class CodexAppServerConnectionTests: XCTestCase {
    func testSendsClientRequestAndResolvesResponse() throws {
        let outbound = LineSink()
        var response: JSONValue?
        let connection = CodexAppServerConnection(sendLine: { outbound.append($0) })

        let id = try connection.sendClientRequest(method: "initialize",
                                                  params: ["client": .string("tidey")]) { result in
            if case .success(let value) = result {
                response = value
            }
        }

        XCTAssertEqual(id, 1)
        let request = try Self.object(from: outbound.lines()[0])
        XCTAssertEqual(request["id"]?.intValue, 1)
        XCTAssertEqual(request["method"]?.stringValue, "initialize")
        XCTAssertEqual(request["params"]?.objectValue?["client"]?.stringValue, "tidey")

        connection.receiveLine(#"{"id":1,"result":{"ok":true}}"#)
        XCTAssertEqual(response?.objectValue?["ok"]?.boolValue, true)
    }

    func testReceivesServerNotification() {
        var received: CodexAppServerNotification?
        let connection = CodexAppServerConnection(sendLine: { _ in },
                                                  onNotification: { received = $0 })

        connection.receiveLine(#"{"method":"thread/status/changed","params":{"threadId":"thread-1"}}"#)

        XCTAssertEqual(received?.method, "thread/status/changed")
        XCTAssertEqual(received?.params["threadId"]?.stringValue, "thread-1")
    }

    func testUnsupportedServerRequestSendsJsonRPCError() throws {
        let outbound = LineSink()
        let connection = CodexAppServerConnection(sendLine: { outbound.append($0) })

        connection.receiveLine(#"{"id":"server-1","method":"item/tool/requestUserInput","params":{}}"#)

        let response = try Self.object(from: outbound.lines()[0])
        XCTAssertEqual(response["id"]?.stringValue, "server-1")
        let error = response["error"]?.objectValue
        XCTAssertEqual(error?["code"]?.intValue, -32601)
        XCTAssertEqual(error?["message"]?.stringValue, "Unsupported server request: item/tool/requestUserInput")
    }

    func testClosesPendingRequestsWhenJSONLineIsInvalid() throws {
        var failure: CodexAppServerConnectionError?
        let connection = CodexAppServerConnection(sendLine: { _ in })
        try connection.sendClientRequest(method: "initialize") { result in
            if case .failure(let error) = result {
                failure = error
            }
        }

        connection.receiveLine("{not-json")

        guard case .invalidJSONLine = failure else {
            return XCTFail("expected invalidJSONLine failure")
        }
    }

    private static func object(from line: String,
                               file: StaticString = #filePath,
                               line sourceLine: UInt = #line) throws -> [String: JSONValue] {
        let data = try XCTUnwrap(line.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
                                 file: file,
                                 line: sourceLine)
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        return try XCTUnwrap(value.objectValue, file: file, line: sourceLine)
    }
}

private final class LineSink: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func append(_ line: String) {
        lock.lock()
        storage.append(line)
        lock.unlock()
    }

    func lines() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
