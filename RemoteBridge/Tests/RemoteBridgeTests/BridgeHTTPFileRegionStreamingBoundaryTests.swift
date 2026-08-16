import Foundation
import NIOCore
import NIOEmbedded
import NIOHTTP1
import XCTest
@testable import RemoteBridge

final class BridgeHTTPFileRegionStreamingBoundaryTests: XCTestCase {
    func testWriterEmitsFileRegionWithoutMaterializingDataAndClosesResponseHandle() throws {
        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("tidey-file-region-\(UUID().uuidString)")
        try Data((0..<64).map(UInt8.init)).write(to: fixture)
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture) }

        let fileHandle = try NIOFileHandle(_deprecatedPath: fixture.path)
        let channel = EmbeddedChannel()
        defer { XCTAssertNoThrow(try channel.finish()) }

        var headers = HTTPHeaders()
        headers.add(name: "content-length", value: "12")
        let response = BridgeHTTPFileRegionResponse(
            head: HTTPResponseHead(version: .http1_1, status: .partialContent, headers: headers),
            fileHandle: fileHandle,
            readerIndex: 40,
            endIndex: 52
        )

        try BridgeHTTPFileRegionResponseWriter().write(response, to: channel).wait()

        let head = try XCTUnwrap(channel.readOutbound(as: HTTPServerResponsePart.self))
        guard case .head(let responseHead) = head else {
            return XCTFail("Expected response head")
        }
        XCTAssertEqual(responseHead.status, .partialContent)

        let body = try XCTUnwrap(channel.readOutbound(as: HTTPServerResponsePart.self))
        guard case .body(.fileRegion(let region)) = body else {
            return XCTFail("Expected FileRegion body")
        }
        XCTAssertEqual(region.readerIndex, 40)
        XCTAssertEqual(region.endIndex, 52)
        XCTAssertEqual(region.readableBytes, 12)

        let end = try XCTUnwrap(channel.readOutbound(as: HTTPServerResponsePart.self))
        guard case .end = end else {
            return XCTFail("Expected response end")
        }
        XCTAssertNil(try channel.readOutbound(as: HTTPServerResponsePart.self))
        XCTAssertThrowsError(try fileHandle.withUnsafeFileDescriptor { _ in })
    }
}
