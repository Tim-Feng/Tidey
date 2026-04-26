import CryptoKit
import Foundation
import XCTest
@testable import RemoteBridge

final class BridgeImageUploadHandlerTests: XCTestCase {
    func testImageUploadWritesJPEGAndReturnsMetadata() throws {
        let fixture = try makeImageUploadFixture()
        let bytes = Data([0xff, 0xd8, 0xff, 0xdb, 0x00, 0x43])
        let response = try XCTUnwrap(fixture.handler.handle(BridgeRequest(id: "request-1",
                                                                          action: "image_upload",
                                                                          params: [
                                                                            "workspace_id": .string("workspace-1"),
                                                                            "panel_id": .string("panel-1"),
                                                                            "mime_type": .string("image/jpeg"),
                                                                            "data_base64": .string(bytes.base64EncodedString()),
                                                                          ])))

        XCTAssertTrue(response.ok)
        let result = try XCTUnwrap(response.result)
        let path = try XCTUnwrap(result["path"]?.stringValue)
        XCTAssertEqual(path, fixture.uploadDirectory.appendingPathComponent("20260426-120000-abcdef.jpg").path)
        XCTAssertEqual(result["bytes"]?.intValue, bytes.count)
        XCTAssertEqual(result["mime_type"]?.stringValue, "image/jpeg")
        XCTAssertEqual(result["sha256"]?.stringValue, sha256(bytes))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), bytes)
    }

    func testImageUploadCreatesDestinationDirectory() throws {
        let fixture = try makeImageUploadFixture(createDirectory: false)
        let bytes = Data([1, 2, 3])

        _ = try XCTUnwrap(fixture.handler.handle(BridgeRequest(id: "request-1",
                                                               action: "image_upload",
                                                               params: [
                                                                "workspace_id": .string("workspace-1"),
                                                                "panel_id": .string("panel-1"),
                                                                "mime_type": .string("image/jpeg"),
                                                                "data_base64": .string(bytes.base64EncodedString()),
                                                               ])))

        var isDirectory: ObjCBool = false
        XCTAssertTrue(fixture.fileManager.fileExists(atPath: fixture.uploadDirectory.path,
                                                     isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
    }

    func testImageUploadRejectsDecodedPayloadOverHardLimit() throws {
        let fixture = try makeImageUploadFixture()
        let bytes = Data(repeating: 1, count: 10 * 1024 * 1024 + 1)

        XCTAssertThrowsError(try fixture.handler.handle(BridgeRequest(id: "request-1",
                                                                      action: "image_upload",
                                                                      params: [
                                                                        "workspace_id": .string("workspace-1"),
                                                                        "panel_id": .string("panel-1"),
                                                                        "mime_type": .string("image/jpeg"),
                                                                        "data_base64": .string(bytes.base64EncodedString()),
                                                                      ]))) { error in
            guard case BridgeInternalError.fileTooLarge(let message) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(message.contains("10MB"))
        }
    }

    func testImageUploadRejectsNonJPEGMimeType() throws {
        let fixture = try makeImageUploadFixture()

        XCTAssertThrowsError(try fixture.handler.handle(BridgeRequest(id: "request-1",
                                                                      action: "image_upload",
                                                                      params: [
                                                                        "workspace_id": .string("workspace-1"),
                                                                        "panel_id": .string("panel-1"),
                                                                        "mime_type": .string("image/png"),
                                                                        "data_base64": .string(Data([1, 2, 3]).base64EncodedString()),
                                                                      ]))) { error in
            guard case BridgeInternalError.invalidRequest(let message) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(message.contains("image/jpeg"))
        }
    }

    func testImageUploadRejectsInvalidBase64() throws {
        let fixture = try makeImageUploadFixture()

        XCTAssertThrowsError(try fixture.handler.handle(BridgeRequest(id: "request-1",
                                                                      action: "image_upload",
                                                                      params: [
                                                                        "workspace_id": .string("workspace-1"),
                                                                        "panel_id": .string("panel-1"),
                                                                        "mime_type": .string("image/jpeg"),
                                                                        "data_base64": .string("not base64"),
                                                                      ]))) { error in
            guard case BridgeInternalError.invalidRequest(let message) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(message.contains("base64"))
        }
    }
}

private struct ImageUploadFixture {
    let tempDirectory: URL
    let uploadDirectory: URL
    let fileManager: FileManager
    let handler: BridgeImageUploadHandler
}

private func makeImageUploadFixture(createDirectory: Bool = true) throws -> ImageUploadFixture {
    let fileManager = FileManager.default
    let tempDirectory = fileManager.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let uploadDirectory = tempDirectory.appendingPathComponent("Tidey-Remote", isDirectory: true)
    if createDirectory {
        try fileManager.createDirectory(at: uploadDirectory, withIntermediateDirectories: true)
    } else {
        try fileManager.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }
    let handler = BridgeImageUploadHandler(destinationResolver: FixedImageUploadDestinationResolver(uploadDirectory: uploadDirectory),
                                           filenameGenerator: FixedImageUploadFilenameGenerator(filename: "20260426-120000-abcdef.jpg"),
                                           fileManager: fileManager)
    return ImageUploadFixture(tempDirectory: tempDirectory,
                              uploadDirectory: uploadDirectory,
                              fileManager: fileManager,
                              handler: handler)
}

private struct FixedImageUploadDestinationResolver: BridgeImageUploadDestinationResolving {
    let uploadDirectory: URL

    func uploadDirectory() throws -> URL {
        uploadDirectory
    }
}

private struct FixedImageUploadFilenameGenerator: BridgeImageUploadFilenameGenerating {
    let filename: String

    func nextFilename() -> String {
        filename
    }
}

private func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
