import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import RemoteBridge

final class BridgeImageReadHandlerTests: XCTestCase {
    func testReadsPNGInsideRoot() throws {
        let fixture = try makeFixture()
        let fileURL = fixture.rootURL.appendingPathComponent("shot.png")
        try Self.makeImageData(width: 64, height: 48, type: .png).write(to: fileURL)

        let response = try XCTUnwrap(fixture.handler.handle(Self.request(path: "shot.png")))

        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.result?["source_mime_type"]?.stringValue, "image/png")
        XCTAssertEqual(response.result?["preview_mime_type"]?.stringValue, "image/png")
        XCTAssertEqual(response.result?["pixel_width"]?.intValue, 64)
        XCTAssertEqual(response.result?["pixel_height"]?.intValue, 48)
        XCTAssertEqual(response.result?["display_name"]?.stringValue, "shot.png")
        XCTAssertEqual(response.result?["read_only"]?.boolValue, true)
        XCTAssertNotEqual(response.result?["revision_token"]?.stringValue, "")
        let decoded = try Self.decodePreview(response)
        XCTAssertEqual(decoded.width, 64)
        XCTAssertEqual(decoded.height, 48)
    }

    func testReadsJPEGWithAbsolutePathInsideRoot() throws {
        let fixture = try makeFixture()
        let fileURL = fixture.rootURL.appendingPathComponent("photo.jpg")
        try Self.makeImageData(width: 80, height: 40, type: .jpeg).write(to: fileURL)

        let response = try XCTUnwrap(fixture.handler.handle(Self.request(path: fileURL.path)))

        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.result?["source_mime_type"]?.stringValue, "image/jpeg")
        XCTAssertEqual(response.result?["preview_mime_type"]?.stringValue, "image/jpeg")
        _ = try Self.decodePreview(response)
    }

    func testSmallSourcePassesThroughUnmodified() throws {
        let fixture = try makeFixture()
        let original = Self.makeImageData(width: 64, height: 48, type: .png)
        try original.write(to: fixture.rootURL.appendingPathComponent("small.png"))

        let response = try XCTUnwrap(fixture.handler.handle(Self.request(path: "small.png")))

        let base64 = try XCTUnwrap(response.result?["data_base64"]?.stringValue)
        XCTAssertEqual(Data(base64Encoded: base64), original)
        XCTAssertEqual(response.result?["preview_size"]?.intValue, original.count)
        XCTAssertEqual(response.result?["source_size"]?.intValue, original.count)
    }

    func testJPEGBytesNamedPNGReturnsTruthfulMime() throws {
        let fixture = try makeFixture()
        let jpegData = Self.makeImageData(width: 64, height: 48, type: .jpeg)
        try jpegData.write(to: fixture.rootURL.appendingPathComponent("mislabeled.png"))

        let response = try XCTUnwrap(fixture.handler.handle(Self.request(path: "mislabeled.png")))

        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.result?["source_mime_type"]?.stringValue, "image/jpeg")
    }

    func testRejectsAllowlistedBytesWithDisallowedExtension() throws {
        let fixture = try makeFixture()
        let jpegData = Self.makeImageData(width: 64, height: 48, type: .jpeg)
        try jpegData.write(to: fixture.rootURL.appendingPathComponent("硬塞.txt"))

        XCTAssertThrowsError(try fixture.handler.handle(Self.request(path: "硬塞.txt"))) { error in
            guard case BridgeInternalError.fileNotInAllowlist = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testRejectsGIFBytesNamedPNG() throws {
        let fixture = try makeFixture()
        let gifData = Self.makeImageData(width: 16, height: 16, type: .gif)
        try gifData.write(to: fixture.rootURL.appendingPathComponent("animated.png"))

        XCTAssertThrowsError(try fixture.handler.handle(Self.request(path: "animated.png"))) { error in
            guard case BridgeInternalError.imageFormatUnsupported = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testRejectsSVGAndPDFBytesNamedPNG() throws {
        let fixture = try makeFixture()
        let svgData = Data("<svg xmlns=\"http://www.w3.org/2000/svg\"/>".utf8)
        try svgData.write(to: fixture.rootURL.appendingPathComponent("vector.png"))
        let pdfData = Data("%PDF-1.4\n1 0 obj\n<<>>\nendobj\ntrailer\n<<>>\n%%EOF\n".utf8)
        try pdfData.write(to: fixture.rootURL.appendingPathComponent("doc.png"))

        for path in ["vector.png", "doc.png"] {
            XCTAssertThrowsError(try fixture.handler.handle(Self.request(path: path)), path) { error in
                switch error {
                case BridgeInternalError.imageFormatUnsupported, BridgeInternalError.imageDecodeFailed:
                    break
                default:
                    XCTFail("Unexpected error for \(path): \(error)")
                }
            }
        }
    }

    func testRejectsNonImageBytes() throws {
        let fixture = try makeFixture()
        try Data([0x00, 0x01, 0x02, 0x03]).write(to: fixture.rootURL.appendingPathComponent("garbage.png"))

        XCTAssertThrowsError(try fixture.handler.handle(Self.request(path: "garbage.png"))) { error in
            guard case BridgeInternalError.imageDecodeFailed = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testRejectsSourceOverByteCap() throws {
        var limits = Self.testLimits
        limits = BridgeImageReadLimits(maximumSourceBytes: 16,
                                       maximumSourcePixels: limits.maximumSourcePixels,
                                       minimumRequestedDimension: limits.minimumRequestedDimension,
                                       maximumRequestedDimension: limits.maximumRequestedDimension,
                                       defaultRequestedDimension: limits.defaultRequestedDimension,
                                       maximumEncodedPreviewBytes: limits.maximumEncodedPreviewBytes)
        let fixture = try makeFixture(limits: limits)
        try Self.makeImageData(width: 64, height: 48, type: .png)
            .write(to: fixture.rootURL.appendingPathComponent("big.png"))

        XCTAssertThrowsError(try fixture.handler.handle(Self.request(path: "big.png"))) { error in
            guard case BridgeInternalError.fileTooLarge = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testRejectsSourceOverPixelCapBeforeDecode() throws {
        let limits = BridgeImageReadLimits(maximumSourceBytes: Self.testLimits.maximumSourceBytes,
                                           maximumSourcePixels: 1_000,
                                           minimumRequestedDimension: Self.testLimits.minimumRequestedDimension,
                                           maximumRequestedDimension: Self.testLimits.maximumRequestedDimension,
                                           defaultRequestedDimension: Self.testLimits.defaultRequestedDimension,
                                           maximumEncodedPreviewBytes: Self.testLimits.maximumEncodedPreviewBytes)
        let fixture = try makeFixture(limits: limits)
        try Self.makeImageData(width: 64, height: 48, type: .png)
            .write(to: fixture.rootURL.appendingPathComponent("dense.png"))

        XCTAssertThrowsError(try fixture.handler.handle(Self.request(path: "dense.png"))) { error in
            guard case BridgeInternalError.imageDimensionsTooLarge = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testDownsamplesToRequestedDimension() throws {
        let limits = BridgeImageReadLimits(maximumSourceBytes: Self.testLimits.maximumSourceBytes,
                                           maximumSourcePixels: Self.testLimits.maximumSourcePixels,
                                           minimumRequestedDimension: 64,
                                           maximumRequestedDimension: Self.testLimits.maximumRequestedDimension,
                                           defaultRequestedDimension: Self.testLimits.defaultRequestedDimension,
                                           maximumEncodedPreviewBytes: Self.testLimits.maximumEncodedPreviewBytes)
        let fixture = try makeFixture(limits: limits)
        try Self.makeImageData(width: 800, height: 600, type: .png)
            .write(to: fixture.rootURL.appendingPathComponent("large.png"))

        let response = try XCTUnwrap(fixture.handler.handle(Self.request(path: "large.png",
                                                                         maxPixelDimension: 100)))

        let width = try XCTUnwrap(response.result?["pixel_width"]?.intValue)
        let height = try XCTUnwrap(response.result?["pixel_height"]?.intValue)
        XCTAssertLessThanOrEqual(max(width, height), 100)
        XCTAssertGreaterThan(min(width, height), 0)
        let decoded = try Self.decodePreview(response)
        XCTAssertEqual(decoded.width, width)
        XCTAssertEqual(decoded.height, height)
    }

    func testRequestBelowServerFloorIsRaisedToFloor() throws {
        let fixture = try makeFixture()
        try Self.makeImageData(width: 800, height: 600, type: .png)
            .write(to: fixture.rootURL.appendingPathComponent("large.png"))

        let response = try XCTUnwrap(fixture.handler.handle(Self.request(path: "large.png",
                                                                         maxPixelDimension: 100)))

        let width = try XCTUnwrap(response.result?["pixel_width"]?.intValue)
        XCTAssertLessThanOrEqual(width, Self.testLimits.minimumRequestedDimension)
        XCTAssertGreaterThan(width, 100, "a hint below the server floor must be raised to the floor, not honored")
    }

    func testClampsExcessiveRequestedDimensionToServerCeiling() throws {
        let limits = BridgeImageReadLimits(maximumSourceBytes: Self.testLimits.maximumSourceBytes,
                                           maximumSourcePixels: Self.testLimits.maximumSourcePixels,
                                           minimumRequestedDimension: 16,
                                           maximumRequestedDimension: 128,
                                           defaultRequestedDimension: 64,
                                           maximumEncodedPreviewBytes: Self.testLimits.maximumEncodedPreviewBytes)
        let fixture = try makeFixture(limits: limits)
        try Self.makeImageData(width: 800, height: 600, type: .png)
            .write(to: fixture.rootURL.appendingPathComponent("large.png"))

        let response = try XCTUnwrap(fixture.handler.handle(Self.request(path: "large.png",
                                                                         maxPixelDimension: 999_999)))

        let width = try XCTUnwrap(response.result?["pixel_width"]?.intValue)
        let height = try XCTUnwrap(response.result?["pixel_height"]?.intValue)
        XCTAssertLessThanOrEqual(max(width, height), 128)
    }

    func testShrinksPreviewUntilEncodedByteCapHolds() throws {
        let limits = BridgeImageReadLimits(maximumSourceBytes: Self.testLimits.maximumSourceBytes,
                                           maximumSourcePixels: Self.testLimits.maximumSourcePixels,
                                           minimumRequestedDimension: Self.testLimits.minimumRequestedDimension,
                                           maximumRequestedDimension: Self.testLimits.maximumRequestedDimension,
                                           defaultRequestedDimension: Self.testLimits.defaultRequestedDimension,
                                           maximumEncodedPreviewBytes: 6 * 1024)
        let fixture = try makeFixture(limits: limits)
        try Self.makeNoisyPNGData(width: 600, height: 400)
            .write(to: fixture.rootURL.appendingPathComponent("noisy.png"))

        let response = try XCTUnwrap(fixture.handler.handle(Self.request(path: "noisy.png",
                                                                         maxPixelDimension: 600)))

        let previewSize = try XCTUnwrap(response.result?["preview_size"]?.intValue)
        XCTAssertLessThanOrEqual(previewSize, 6 * 1024)
        _ = try Self.decodePreview(response)
    }

    func testHiddenAndLibraryHomePathsRejected() throws {
        let fixture = try makeFixture()
        let hiddenURL = fixture.homeURL.appendingPathComponent(".secrets/shot.png")
        let libraryURL = fixture.homeURL.appendingPathComponent("Library/shot.png")
        for url in [hiddenURL, libraryURL] {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try Self.makeImageData(width: 16, height: 16, type: .png).write(to: url)
        }

        for url in [hiddenURL, libraryURL] {
            XCTAssertThrowsError(try fixture.handler.handle(Self.request(path: url.path)), url.path) { error in
                guard case BridgeInternalError.fileOutsideRoot = error else {
                    return XCTFail("Unexpected error for \(url.path): \(error)")
                }
            }
        }
    }

    func testPlainHomeImageReadableOutsideRoot() throws {
        let fixture = try makeFixture()
        let fileURL = fixture.homeURL.appendingPathComponent("Pictures/shot.png")
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Self.makeImageData(width: 16, height: 16, type: .png).write(to: fileURL)

        let response = try XCTUnwrap(fixture.handler.handle(Self.request(path: fileURL.path)))

        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.result?["read_only"]?.boolValue, true)
    }

    func testUploadsDirectorySubtreeIsReadableDespiteLibraryBlock() throws {
        let fixture = try makeFixture()
        let uploadURL = fixture.uploadsURL.appendingPathComponent("20260724-abc.png")
        try FileManager.default.createDirectory(at: fixture.uploadsURL, withIntermediateDirectories: true)
        try Self.makeImageData(width: 16, height: 16, type: .png).write(to: uploadURL)

        let response = try XCTUnwrap(fixture.handler.handle(Self.request(path: uploadURL.path)))

        XCTAssertTrue(response.ok)
    }

    func testSymlinkEscapingRootRejected() throws {
        let fixture = try makeFixture()
        let outsideURL = fixture.tempDirectory.appendingPathComponent("outside.png")
        try Self.makeImageData(width: 16, height: 16, type: .png).write(to: outsideURL)
        let linkURL = fixture.rootURL.appendingPathComponent("alias.png")
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: outsideURL)

        XCTAssertThrowsError(try fixture.handler.handle(Self.request(path: "alias.png"))) { error in
            guard case BridgeInternalError.fileOutsideRoot = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testImageExtensionsStayOutOfDocumentWritePolicy() throws {
        for name in ["a.png", "b.jpg", "c.jpeg"] {
            XCTAssertFalse(BridgeDocumentFilePolicy.poc.allows(URL(fileURLWithPath: "/tmp/\(name)")),
                           "document policy must not allow \(name)")
        }
        let fixture = try makeFixture()
        XCTAssertNil(try fixture.handler.handle(BridgeRequest(id: "w",
                                                              action: "file_write",
                                                              params: nil)),
                     "image handler must never handle file_write")
    }

    func testResponseJSONStaysUnderFrameBudget() throws {
        let fixture = try makeFixture()
        try Self.makeNoisyPNGData(width: 2000, height: 1500)
            .write(to: fixture.rootURL.appendingPathComponent("frame.png"))

        let response = try XCTUnwrap(fixture.handler.handle(Self.request(path: "frame.png")))

        let encoded = try JSONEncoder().encode(response)
        XCTAssertLessThan(encoded.count, 12 * 1024 * 1024)
        let previewSize = try XCTUnwrap(response.result?["preview_size"]?.intValue)
        XCTAssertLessThanOrEqual(previewSize, Self.testLimits.maximumEncodedPreviewBytes)
    }

    func testMissingFileReportsNotFound() throws {
        let fixture = try makeFixture()

        XCTAssertThrowsError(try fixture.handler.handle(Self.request(path: "missing.png"))) { error in
            guard case BridgeInternalError.notFound = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    // MARK: - Fixture

    private static let testLimits = BridgeImageReadLimits.production

    private struct ImageHandlerFixture {
        let tempDirectory: URL
        let rootURL: URL
        let homeURL: URL
        let uploadsURL: URL
        let handler: BridgeImageReadHandler
    }

    private func makeFixture(limits: BridgeImageReadLimits = BridgeImageReadHandlerTests.testLimits) throws -> ImageHandlerFixture {
        let fileManager = FileManager.default
        let tempDirectory = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let rootURL = tempDirectory.appendingPathComponent("workspace-root", isDirectory: true)
        let homeURL = tempDirectory.appendingPathComponent("home", isDirectory: true)
        let uploadsURL = homeURL.appendingPathComponent("Library/Application Support/Tidey Remote Bridge/uploads",
                                                        isDirectory: true)
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: homeURL, withIntermediateDirectories: true)
        let handler = BridgeImageReadHandler(rootResolver: StubImageRootResolver(rootPath: rootURL.path),
                                             fileManager: fileManager,
                                             homeDirectoryURL: homeURL,
                                             uploadsDirectoryURL: uploadsURL,
                                             limits: limits)
        return ImageHandlerFixture(tempDirectory: tempDirectory,
                                   rootURL: rootURL,
                                   homeURL: homeURL,
                                   uploadsURL: uploadsURL,
                                   handler: handler)
    }

    private static func request(path: String, maxPixelDimension: Int? = nil) -> BridgeRequest {
        var params: [String: JSONValue] = [
            "workspace_id": .string("workspace-1"),
            "panel_id": .string("panel-1"),
            "path": .string(path),
        ]
        if let maxPixelDimension {
            params["max_pixel_dimension"] = .number(Double(maxPixelDimension))
        }
        return BridgeRequest(id: UUID().uuidString, action: "image_read", params: params)
    }

    private static func decodePreview(_ response: BridgeResponse) throws -> (width: Int, height: Int) {
        let base64 = try XCTUnwrap(response.result?["data_base64"]?.stringValue)
        let data = try XCTUnwrap(Data(base64Encoded: base64))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        let width = try XCTUnwrap(properties[kCGImagePropertyPixelWidth] as? Int)
        let height = try XCTUnwrap(properties[kCGImagePropertyPixelHeight] as? Int)
        return (width, height)
    }

    private static func makeImageData(width: Int, height: Int, type: UTType) -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(data: nil,
                                width: width,
                                height: height,
                                bitsPerComponent: 8,
                                bytesPerRow: 0,
                                space: colorSpace,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = context.makeImage()!
        return encode(image: image, type: type)
    }

    private static func makeNoisyPNGData(width: Int, height: Int) -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(data: nil,
                                width: width,
                                height: height,
                                bitsPerComponent: 8,
                                bytesPerRow: 0,
                                space: colorSpace,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        var seed: UInt64 = 0x2545F4914F6CDD1D
        for y in 0..<height {
            for x in stride(from: 0, to: width, by: 4) {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                let red = CGFloat(seed & 0xFF) / 255
                let green = CGFloat((seed >> 8) & 0xFF) / 255
                let blue = CGFloat((seed >> 16) & 0xFF) / 255
                context.setFillColor(CGColor(red: red, green: green, blue: blue, alpha: 1))
                context.fill(CGRect(x: x, y: y, width: 4, height: 1))
            }
        }
        let image = context.makeImage()!
        return encode(image: image, type: .png)
    }

    private static func encode(image: CGImage, type: UTType) -> Data {
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data as CFMutableData,
                                                           type.identifier as CFString,
                                                           1,
                                                           nil)!
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }
}

private struct StubImageRootResolver: PanelFileRootResolving {
    let rootPath: String

    func rootPath(workspaceID: String, panelID: String) throws -> String {
        rootPath
    }
}
