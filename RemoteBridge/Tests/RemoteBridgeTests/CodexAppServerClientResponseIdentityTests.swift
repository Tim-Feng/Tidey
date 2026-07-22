import Foundation
import XCTest
@testable import RemoteBridge

final class CodexAppServerClientResponseIdentityTests: XCTestCase {
    func testStringResponseIDCannotConsumeIntegerClientRequest() throws {
        let responses = ClientResponseSink()
        let connection = CodexAppServerConnection(sendLine: { _ in })
        let requestID = try connection.sendClientRequest(method: "thread/list") {
            responses.append($0)
        }
        XCTAssertEqual(requestID, 1)

        connection.receiveLine(#"{"id":"1","result":{"source":"string"}}"#)
        XCTAssertTrue(responses.values().isEmpty)

        connection.receiveLine(#"{"id":1,"result":{"source":"integer"}}"#)
        let response = try Self.successValue(from: XCTUnwrap(responses.values().first))
        XCTAssertEqual(response.objectValue?["source"]?.stringValue, "integer")
        XCTAssertEqual(responses.values().count, 1)
    }

    func testUnknownAndInvalidResponseIDsLeavePendingRequestIntact() throws {
        let responses = ClientResponseSink()
        let connection = CodexAppServerConnection(sendLine: { _ in })
        _ = try connection.sendClientRequest(method: "thread/list") {
            responses.append($0)
        }

        connection.receiveLine(#"{"id":2,"result":{"source":"unknown"}}"#)
        connection.receiveLine(#"{"id":1.5,"result":{"source":"fractional"}}"#)
        connection.receiveLine(#"{"id":true,"result":{"source":"boolean"}}"#)
        connection.receiveLine(#"{"id":null,"result":{"source":"null"}}"#)
        XCTAssertTrue(responses.values().isEmpty)

        connection.receiveLine(#"{"id":1,"result":{"source":"expected"}}"#)
        let response = try Self.successValue(from: XCTUnwrap(responses.values().first))
        XCTAssertEqual(response.objectValue?["source"]?.stringValue, "expected")
        XCTAssertEqual(responses.values().count, 1)
    }

    func testDuplicateResponseCompletesClientRequestOnlyOnce() throws {
        let responses = ClientResponseSink()
        let connection = CodexAppServerConnection(sendLine: { _ in })
        _ = try connection.sendClientRequest(method: "thread/list") {
            responses.append($0)
        }

        connection.receiveLine(#"{"id":1,"result":{"delivery":1}}"#)
        connection.receiveLine(#"{"id":1,"result":{"delivery":2}}"#)

        XCTAssertEqual(responses.values().count, 1)
        let response = try Self.successValue(from: XCTUnwrap(responses.values().first))
        XCTAssertEqual(response.objectValue?["delivery"]?.intValue, 1)
    }

    private static func successValue(
        from result: Result<JSONValue, CodexAppServerConnectionError>
    ) throws -> JSONValue {
        switch result {
        case .success(let value):
            return value
        case .failure(let error):
            throw error
        }
    }
}

private final class ClientResponseSink: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Result<JSONValue, CodexAppServerConnectionError>] = []

    func append(_ value: Result<JSONValue, CodexAppServerConnectionError>) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }

    func values() -> [Result<JSONValue, CodexAppServerConnectionError>] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
