import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import RemoteBridge

final class BridgeOriginalImageUploadTests: XCTestCase {
    func testChunkedOriginalPreservesExactBytesAndExtension() throws {
        for type in [UTType.jpeg, .png, .heic] {
            let f = try fixture()
            let data = try photo(type)
            let result = try upload(data, mime: type.preferredMIMEType!, handler: f.handler)
            let path = try XCTUnwrap(result["path"]?.stringValue)
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), data)
            XCTAssertEqual(result["sha256"]?.stringValue, digest(data))
            XCTAssertEqual(result["bytes"]?.intValue, data.count)
            XCTAssertTrue(path.contains("/originals/"))
            XCTAssertEqual(URL(fileURLWithPath: path).pathExtension, type == .jpeg ? "jpg" : type.preferredFilenameExtension!)
            let agentPath = try XCTUnwrap(result["agent_path"]?.stringValue)
            if type == .heic {
                XCTAssertNotEqual(agentPath, path)
                let source = try XCTUnwrap(CGImageSourceCreateWithURL(URL(fileURLWithPath: agentPath) as CFURL, nil))
                XCTAssertEqual(CGImageSourceGetType(source) as String?, UTType.jpeg.identifier)
                let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
                XCTAssertEqual(props[kCGImagePropertyPixelWidth] as? Int, 80)
                XCTAssertEqual(props[kCGImagePropertyPixelHeight] as? Int, 120)
            } else { XCTAssertEqual(agentPath, path) }
        }
    }

    func testRejectsWrongDigestMimeMissingOrOutOfOrderChunksWithoutPublishing() throws {
        for scenario in ["digest", "mime", "missing", "order", "duplicate", "oversize", "scope"] {
            let f = try fixture()
            let data = try photo(.png)
            let id = try begin(data, mime: scenario == "mime" ? "image/jpeg" : "image/png", hash: scenario == "digest" ? String(repeating: "a", count: 64) : nil, handler: f.handler)
            XCTAssertThrowsError(try {
                if scenario == "missing" { _ = try call("commit", id: id, f.handler) }
                else if scenario == "order" { _ = try chunk(data, offset: 1, id: id, handler: f.handler) }
                else if scenario == "oversize" { _ = try chunk(Data(repeating: 0, count: 1024 * 1024 + 1), offset: 0, id: id, handler: f.handler) }
                else if scenario == "scope" {
                    _ = try call("chunk", id: id, f.handler, extra: ["panel_id": .string("other"), "offset": .number(0), "data_base64": .string(data.base64EncodedString())])
                } else {
                    _ = try chunk(data, offset: 0, id: id, handler: f.handler)
                    if scenario == "duplicate" { _ = try chunk(data, offset: 0, id: id, handler: f.handler) }
                    else { _ = try call("commit", id: id, f.handler) }
                }
            }(), scenario)
            XCTAssertEqual(try publishedFiles(f.directory).count, 0, scenario)
        }
    }

    func testCancelAndConnectionOwnership() throws {
        let f = try fixture(), other = try fixture()
        let data = try photo(.jpeg)
        let id = try begin(data, mime: "image/jpeg", handler: f.handler)
        XCTAssertThrowsError(try chunk(data, offset: 0, id: id, handler: other.handler))
        _ = try chunk(data, offset: 0, id: id, handler: f.handler)
        _ = try call("cancel", id: id, f.handler)
        XCTAssertThrowsError(try call("commit", id: id, f.handler))
        XCTAssertEqual(try publishedFiles(f.directory).count, 0)
    }

    func testDisconnectDuringDecodeReturnsPromptlyAndNeverPublishes() throws {
        let decoding = expectation(description: "entered decode")
        let closed = expectation(description: "close returned")
        let committed = expectation(description: "commit returned")
        let release = DispatchSemaphore(value: 0)
        let f = try fixture(beforeValidation: {
            decoding.fulfill()
            _ = release.wait(timeout: .now() + 3)
        })
        let data = try photo(.heic)
        let id = try begin(data, mime: "image/heic", handler: f.handler)
        _ = try chunk(data, offset: 0, id: id, handler: f.handler)
        DispatchQueue.global().async {
            do { _ = try self.call("commit", id: id, f.handler); XCTFail("closed commit published") } catch {}
            committed.fulfill()
        }
        wait(for: [decoding], timeout: 2)
        DispatchQueue.global().async { f.handler.close(); closed.fulfill() }
        wait(for: [closed], timeout: 0.3)
        release.signal()
        wait(for: [committed], timeout: 2)
        XCTAssertEqual(try publishedFiles(f.directory).count, 0)
    }

    func testCancelDuringDecodeReturnsPromptlyAndNeverPublishes() throws {
        let decoding = expectation(description: "entered decode")
        let cancelled = expectation(description: "cancel returned")
        let committed = expectation(description: "commit returned")
        let release = DispatchSemaphore(value: 0)
        let f = try fixture(beforeValidation: {
            decoding.fulfill()
            _ = release.wait(timeout: .now() + 3)
        })
        let data = try photo(.heic)
        let id = try begin(data, mime: "image/heic", handler: f.handler)
        _ = try chunk(data, offset: 0, id: id, handler: f.handler)
        DispatchQueue.global().async {
            do { _ = try self.call("commit", id: id, f.handler); XCTFail("cancelled commit published") } catch {}
            committed.fulfill()
        }
        wait(for: [decoding], timeout: 2)
        DispatchQueue.global().async {
            do { _ = try self.call("cancel", id: id, f.handler) } catch { XCTFail("cancel failed: \(error)") }
            cancelled.fulfill()
        }
        wait(for: [cancelled], timeout: 0.3)
        release.signal()
        wait(for: [committed], timeout: 2)
        XCTAssertEqual(try publishedFiles(f.directory).count, 0)
    }

    func testConnectionCloseRemovesPartialFilesAndRejectsFurtherWrites() throws {
        let f = try fixture()
        let data = try photo(.png)
        let id = try begin(data, mime: "image/png", handler: f.handler)
        _ = try chunk(data.prefix(8), offset: 0, id: id, handler: f.handler)
        f.handler.close()
        XCTAssertThrowsError(try chunk(data.suffix(data.count - 8), offset: 8, id: id, handler: f.handler))
        let files = try FileManager.default.contentsOfDirectory(at: f.directory.appendingPathComponent("originals"), includingPropertiesForKeys: nil)
        XCTAssertTrue(files.isEmpty)
    }

    func testDeclaredSizeAndContentMustBeBoundedImages() throws {
        let f = try fixture()
        XCTAssertThrowsError(try call("begin", f.handler, extra: ["bytes": .number(Double(20 * 1024 * 1024 + 1)), "mime_type": .string("image/jpeg"), "sha256": .string(String(repeating: "a", count: 64))]))
        XCTAssertThrowsError(try upload(Data("not an image".utf8), mime: "image/jpeg", handler: f.handler))
        XCTAssertEqual(try publishedFiles(f.directory).count, 0)
    }

    private func fixture(beforeValidation: @escaping () -> Void = {}) throws -> (handler: BridgeImageUploadHandler, directory: URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return (BridgeImageUploadHandler(destinationResolver: OriginalTestDestination(directory: directory), filenameGenerator: TimestampedImageUploadFilenameGenerator(), originalValidationHook: beforeValidation), directory)
    }

    private func photo(_ type: UTType) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: 120, height: 80, bitsPerComponent: 8, bytesPerRow: 480, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 120, height: 80))
        let output = NSMutableData()
        let dest = try XCTUnwrap(CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, try XCTUnwrap(context.makeImage()), [kCGImagePropertyOrientation: 6] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return output as Data
    }
    private func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func begin(_ data: Data, mime: String, hash: String? = nil, handler: BridgeImageUploadHandler) throws -> String {
        try XCTUnwrap(call("begin", handler, extra: ["bytes": .number(Double(data.count)), "mime_type": .string(mime), "sha256": .string(hash ?? digest(data))])["upload_id"]?.stringValue)
    }
    private func chunk(_ data: Data, offset: Int, id: String, handler: BridgeImageUploadHandler) throws -> [String: JSONValue] {
        try call("chunk", id: id, handler, extra: ["offset": .number(Double(offset)), "data_base64": .string(data.base64EncodedString())])
    }
    private func upload(_ data: Data, mime: String, handler: BridgeImageUploadHandler) throws -> [String: JSONValue] {
        let id = try begin(data, mime: mime, handler: handler)
        let split = data.count / 2
        _ = try chunk(data.prefix(split), offset: 0, id: id, handler: handler)
        _ = try chunk(data.suffix(data.count - split), offset: split, id: id, handler: handler)
        return try call("commit", id: id, handler)
    }
    private func call(_ phase: String, id: String? = nil, _ handler: BridgeImageUploadHandler, extra: [String: JSONValue] = [:]) throws -> [String: JSONValue] {
        var params: [String: JSONValue] = ["workspace_id": .string("w"), "panel_id": .string("p")]
        if let id { params["upload_id"] = .string(id) }; params.merge(extra) { _, new in new }
        let handled = try handler.handle(BridgeRequest(id: UUID().uuidString, action: "image_original_\(phase)", params: params))
        let response = try XCTUnwrap(handled)
        XCTAssertTrue(response.ok)
        return try XCTUnwrap(response.result)
    }
    private func publishedFiles(_ directory: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { return [] }
        return enumerator.compactMap { $0 as? URL }.filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
    }
}
private struct OriginalTestDestination: BridgeImageUploadDestinationResolving {
    let directory: URL
    func uploadDirectory() throws -> URL { directory }
}
