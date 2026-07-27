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

    func testSmallSourceIsReEncodedWithDimensionsPreserved() throws {
        let fixture = try makeFixture()
        let original = Self.makeImageData(width: 64, height: 48, type: .png)
        try original.write(to: fixture.rootURL.appendingPathComponent("small.png"))

        let response = try XCTUnwrap(fixture.handler.handle(Self.request(path: "small.png")))

        XCTAssertEqual(response.result?["pixel_width"]?.intValue, 64)
        XCTAssertEqual(response.result?["pixel_height"]?.intValue, 48)
        XCTAssertEqual(response.result?["source_size"]?.intValue, original.count)
        let decoded = try Self.decodePreview(response)
        XCTAssertEqual(decoded.width, 64)
        XCTAssertEqual(decoded.height, 48)
    }

    func testJPEGSourceIsNeverPassedThroughVerbatim() throws {
        let fixture = try makeFixture()
        let original = Self.makeImageData(width: 64, height: 48, type: .jpeg)
        try original.write(to: fixture.rootURL.appendingPathComponent("photo.jpg"))

        let response = try XCTUnwrap(fixture.handler.handle(Self.request(path: "photo.jpg")))

        let base64 = try XCTUnwrap(response.result?["data_base64"]?.stringValue)
        XCTAssertNotEqual(Data(base64Encoded: base64), original,
                          "source bytes must be re-encoded, never passed through")
        _ = try Self.decodePreview(response)
    }

    func testTruncatedJPEGIsNeverPassedThrough() throws {
        let fixture = try makeFixture()
        let full = Self.makeImageData(width: 200, height: 150, type: .jpeg)
        let truncated = full.prefix(full.count * 2 / 5)
        try Data(truncated).write(to: fixture.rootURL.appendingPathComponent("cut.jpg"))

        // Either outcome is contractual: a decode failure, or a freshly
        // re-encoded single frame. The truncated source bytes must never be
        // returned verbatim.
        do {
            guard let response = try fixture.handler.handle(Self.request(path: "cut.jpg")) else {
                return XCTFail("handler must handle image_read")
            }
            let base64 = try XCTUnwrap(response.result?["data_base64"]?.stringValue)
            XCTAssertNotEqual(Data(base64Encoded: base64), Data(truncated))
            _ = try Self.decodePreview(response)
        } catch BridgeInternalError.imageDecodeFailed {
            // acceptable
        }
    }

    func testMultiFramePNGIsRejected() throws {
        let fixture = try makeFixture()
        let apngData = try XCTSkipUnlessMultiFramePNG()
        try apngData.write(to: fixture.rootURL.appendingPathComponent("animated-frames.png"))

        XCTAssertThrowsError(try fixture.handler.handle(Self.request(path: "animated-frames.png"))) { error in
            guard case BridgeInternalError.imageFormatUnsupported = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    private func XCTSkipUnlessMultiFramePNG() throws -> Data {
        let frame = Self.makeImageData(width: 16, height: 16, type: .png)
        let source = CGImageSourceCreateWithData(frame as CFData, nil)!
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data as CFMutableData,
                                                           UTType.png.identifier as CFString,
                                                           2,
                                                           nil)!
        let frameProperties = [
            kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGDelayTime: 0.1],
        ] as CFDictionary
        CGImageDestinationAddImage(destination, image, frameProperties)
        CGImageDestinationAddImage(destination, image, frameProperties)
        CGImageDestinationFinalize(destination)
        let written = data as Data
        let readBack = CGImageSourceCreateWithData(written as CFData, nil)
        // The fixture is only valid if ImageIO actually produced a
        // multi-frame PNG; a collapsed single-frame file would test nothing.
        XCTAssertEqual(readBack.map(CGImageSourceGetCount), 2,
                       "fixture must be a real multi-frame PNG")
        return written
    }

    func testAdmissionLimitRefusesConcurrentSecondRequestAndReleases() throws {
        let admission = BridgeImageReadAdmission(limit: 1)
        let entered = DispatchSemaphore(value: 0)
        let proceed = DispatchSemaphore(value: 0)
        let blockingFixture = try makeFixture(admission: admission, admittedWorkHook: {
            entered.signal()
            proceed.wait()
        })
        try Self.makeImageData(width: 16, height: 16, type: .png)
            .write(to: blockingFixture.rootURL.appendingPathComponent("held.png"))

        var firstResult: Result<BridgeResponse?, Error> = .success(nil)
        let firstDone = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            firstResult = Result { try blockingFixture.handler.handle(Self.request(path: "held.png")) }
            firstDone.signal()
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success, "first request must enter the admitted section")

        let secondFixture = try makeFixture(admission: admission)
        XCTAssertThrowsError(try secondFixture.handler.handle(Self.request(path: "held.png"))) { error in
            guard case BridgeInternalError.resourceBusy = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        proceed.signal()
        XCTAssertEqual(firstDone.wait(timeout: .now() + 5), .success)
        XCTAssertNoThrow(try firstResult.get())

        XCTAssertTrue(admission.tryAcquire(), "slot must be released after completion")
        admission.release()
    }

    func testAdmissionSlotIsReleasedWhenHandlerThrows() throws {
        let admission = BridgeImageReadAdmission(limit: 1)
        let fixture = try makeFixture(admission: admission)

        XCTAssertThrowsError(try fixture.handler.handle(Self.request(path: "missing.png")))

        XCTAssertTrue(admission.tryAcquire(), "slot must be released after an error")
        admission.release()
    }

    func testUploadsDirectoryAsSymlinkToOutsideIsRejected() throws {
        let fixture = try makeFixture(createUploadsDirectory: false)
        let externalURL = fixture.tempDirectory.appendingPathComponent("external", isDirectory: true)
        try FileManager.default.createDirectory(at: externalURL, withIntermediateDirectories: true)
        try Self.makeImageData(width: 16, height: 16, type: .png)
            .write(to: externalURL.appendingPathComponent("leak.png"))
        try FileManager.default.createDirectory(at: fixture.uploadsURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: fixture.uploadsURL, withDestinationURL: externalURL)

        XCTAssertThrowsError(try fixture.handler.handle(Self.request(path: fixture.uploadsURL.appendingPathComponent("leak.png").path))) { error in
            guard case BridgeInternalError.fileOutsideRoot = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testUploadsIntermediateSymlinkComponentIsRejected() throws {
        let fixture = try makeFixture()
        try FileManager.default.createDirectory(at: fixture.uploadsURL, withIntermediateDirectories: true)
        let externalURL = fixture.tempDirectory.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: externalURL, withIntermediateDirectories: true)
        try Self.makeImageData(width: 16, height: 16, type: .png)
            .write(to: externalURL.appendingPathComponent("leak.png"))
        let linkedSubdirectory = fixture.uploadsURL.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: linkedSubdirectory, withDestinationURL: externalURL)

        XCTAssertThrowsError(try fixture.handler.handle(Self.request(path: linkedSubdirectory.appendingPathComponent("leak.png").path))) { error in
            guard case BridgeInternalError.fileOutsideRoot = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testUploadsFinalSymlinkTargetIsRejected() throws {
        let fixture = try makeFixture()
        try FileManager.default.createDirectory(at: fixture.uploadsURL, withIntermediateDirectories: true)
        let externalFile = fixture.tempDirectory.appendingPathComponent("secret.png")
        try Self.makeImageData(width: 16, height: 16, type: .png).write(to: externalFile)
        let linkURL = fixture.uploadsURL.appendingPathComponent("alias.png")
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: externalFile)

        XCTAssertThrowsError(try fixture.handler.handle(Self.request(path: linkURL.path))) { error in
            guard case BridgeInternalError.fileOutsideRoot = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
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

    func testProductionPreviewCapIsOneMiBAndOpaqueNoisyPNGUsesJPEG() throws {
        XCTAssertEqual(BridgeImageReadLimits.production.maximumEncodedPreviewBytes, 1024 * 1024)
        let fixture = try makeFixture()
        try Self.makeOpaqueNoisyPNGData(width: 1672, height: 941)
            .write(to: fixture.rootURL.appendingPathComponent("opaque-noise.png"))

        let response = try XCTUnwrap(fixture.handler.handle(Self.request(path: "opaque-noise.png")))

        XCTAssertEqual(response.result?["preview_mime_type"]?.stringValue, "image/jpeg")
        let previewSize = try XCTUnwrap(response.result?["preview_size"]?.intValue)
        XCTAssertLessThanOrEqual(previewSize, 1024 * 1024)
        _ = try Self.decodePreview(response)
    }

    func testTransparentPNGRemainsPNGAndPreservesAlphaUnderByteCap() throws {
        let limits = BridgeImageReadLimits(maximumSourceBytes: Self.testLimits.maximumSourceBytes,
                                           maximumSourcePixels: Self.testLimits.maximumSourcePixels,
                                           minimumRequestedDimension: 64,
                                           maximumRequestedDimension: 512,
                                           defaultRequestedDimension: 512,
                                           maximumEncodedPreviewBytes: 12 * 1024)
        let fixture = try makeFixture(limits: limits)
        try Self.makeTransparentNoisyPNGData(width: 512, height: 384)
            .write(to: fixture.rootURL.appendingPathComponent("transparent-noise.png"))

        let response = try XCTUnwrap(fixture.handler.handle(Self.request(path: "transparent-noise.png")))

        XCTAssertEqual(response.result?["preview_mime_type"]?.stringValue, "image/png")
        let previewSize = try XCTUnwrap(response.result?["preview_size"]?.intValue)
        XCTAssertLessThanOrEqual(previewSize, limits.maximumEncodedPreviewBytes)
        let preview = try Self.previewImage(response)
        XCTAssertTrue(Self.containsTransparentPixel(preview), "transparent source alpha must survive preview encoding")
        XCTAssertLessThan(max(preview.width, preview.height), 512,
                          "transparent PNG must reduce dimensions rather than fall back to JPEG")
    }

    func testMatchingRevisionReturnsMetadataWithoutAdmissionOrDecode() throws {
        let admittedWorkCount = LockedCounter()
        let limits = BridgeImageReadLimits(maximumSourceBytes: 1,
                                           maximumSourcePixels: Self.testLimits.maximumSourcePixels,
                                           minimumRequestedDimension: Self.testLimits.minimumRequestedDimension,
                                           maximumRequestedDimension: Self.testLimits.maximumRequestedDimension,
                                           defaultRequestedDimension: Self.testLimits.defaultRequestedDimension,
                                           maximumEncodedPreviewBytes: Self.testLimits.maximumEncodedPreviewBytes)
        let fixture = try makeFixture(limits: limits, admittedWorkHook: {
            admittedWorkCount.increment()
        })
        let fileURL = fixture.rootURL.appendingPathComponent("unchanged.png")
        try Data(repeating: 0xFF, count: 128).write(to: fileURL)
        let opened = try BridgeSafeFileOpener.openRegularFile(at: fileURL,
                                                              notFoundMessage: "missing",
                                                              outsideScopeMessage: "outside")
        let revisionToken = opened.revisionToken
        opened.close()

        let response = try XCTUnwrap(fixture.handler.handle(Self.request(path: "unchanged.png",
                                                                         ifRevisionToken: revisionToken)))

        XCTAssertEqual(admittedWorkCount.value, 0,
                       "matching metadata must return before admission, bounded read, and decode")
        XCTAssertEqual(response.result?["not_modified"]?.boolValue, true)
        XCTAssertEqual(response.result?["normalized_path"]?.stringValue, fileURL.path)
        XCTAssertEqual(response.result?["display_name"]?.stringValue, "unchanged.png")
        XCTAssertEqual(response.result?["source_size"]?.intValue, 128)
        XCTAssertEqual(response.result?["revision_token"]?.stringValue, revisionToken)
        XCTAssertEqual(response.result?["read_only"]?.boolValue, true)
        XCTAssertNil(response.result?["data_base64"])
        XCTAssertNil(response.result?["preview_size"])
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

    // Policy-level lexical check with SYNTHETIC unresolved URLs: the shared
    // resolver happens to canonicalize casing for existing files on this
    // runtime, so these are the URLs the policy must reject on its own.
    func testPolicyRejectsLibraryCasingVariantsWithoutResolverCanonicalization() {
        let home = URL(fileURLWithPath: "/synthetic-home")
        let uploads = home.appendingPathComponent("Library/Application Support/Tidey Remote Bridge/uploads")
        let policy = BridgeImageFilePolicy(uploadsDirectoryURL: uploads)

        for variant in ["Library", "library", "LIBRARY", "LiBrArY"] {
            let url = home.appendingPathComponent("\(variant)/shot.png")
            XCTAssertFalse(policy.allowsReadOnlyHomeScope(url, homeDirectoryURL: home), variant)
        }
        XCTAssertTrue(policy.allowsReadOnlyHomeScope(home.appendingPathComponent("Pictures/shot.png"),
                                                     homeDirectoryURL: home))
        XCTAssertTrue(policy.allowsReadOnlyHomeScope(uploads.appendingPathComponent("a.png"),
                                                     homeDirectoryURL: home),
                      "the exact uploads subtree exception must survive the hardening")
    }

    func testLibraryCasingVariantsRejected() throws {
        let fixture = try makeFixture()
        let pngURL = fixture.homeURL.appendingPathComponent("Library/casing.png")
        let jpgURL = fixture.homeURL.appendingPathComponent("Library/casing.jpg")
        for url in [pngURL, jpgURL] {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try Self.makeImageData(width: 16, height: 16, type: .png).write(to: url)
        }

        // Default APFS is case-insensitive: ~/library and ~/LIBRARY open the
        // real ~/Library, so a casing variant must not slip past the block.
        for path in [fixture.homeURL.path + "/library/casing.png",
                     fixture.homeURL.path + "/LIBRARY/casing.jpg"] {
            XCTAssertThrowsError(try fixture.handler.handle(Self.request(path: path)), path) { error in
                guard case BridgeInternalError.fileOutsideRoot = error else {
                    return XCTFail("Unexpected error for \(path): \(error)")
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

    private func makeFixture(limits: BridgeImageReadLimits = BridgeImageReadHandlerTests.testLimits,
                             admission: BridgeImageReadAdmission = BridgeImageReadAdmission(limit: 1),
                             admittedWorkHook: (() -> Void)? = nil,
                             createUploadsDirectory: Bool = true) throws -> ImageHandlerFixture {
        let fileManager = FileManager.default
        let tempDirectory = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let rootURL = tempDirectory.appendingPathComponent("workspace-root", isDirectory: true)
        let homeURL = tempDirectory.appendingPathComponent("home", isDirectory: true)
        let uploadsURL = homeURL.appendingPathComponent("Library/Application Support/Tidey Remote Bridge/uploads",
                                                        isDirectory: true)
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: homeURL, withIntermediateDirectories: true)
        _ = createUploadsDirectory
        addTeardownBlock {
            try? fileManager.removeItem(at: tempDirectory)
        }
        let handler = BridgeImageReadHandler(rootResolver: StubImageRootResolver(rootPath: rootURL.path),
                                             fileManager: fileManager,
                                             homeDirectoryURL: homeURL,
                                             uploadsDirectoryURL: uploadsURL,
                                             limits: limits,
                                             admission: admission,
                                             admittedWorkHookForTesting: admittedWorkHook)
        return ImageHandlerFixture(tempDirectory: tempDirectory,
                                   rootURL: rootURL,
                                   homeURL: homeURL,
                                   uploadsURL: uploadsURL,
                                   handler: handler)
    }

    private static func request(path: String,
                                maxPixelDimension: Int? = nil,
                                ifRevisionToken: String? = nil) -> BridgeRequest {
        var params: [String: JSONValue] = [
            "workspace_id": .string("workspace-1"),
            "panel_id": .string("panel-1"),
            "path": .string(path),
        ]
        if let maxPixelDimension {
            params["max_pixel_dimension"] = .number(Double(maxPixelDimension))
        }
        if let ifRevisionToken {
            params["if_revision_token"] = .string(ifRevisionToken)
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

    private static func makeOpaqueNoisyPNGData(width: Int, height: Int) -> Data {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        var seed: UInt64 = 0x7A6D_8F39_42C1_B507
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            pixels[offset] = UInt8(truncatingIfNeeded: seed)
            pixels[offset + 1] = UInt8(truncatingIfNeeded: seed >> 8)
            pixels[offset + 2] = UInt8(truncatingIfNeeded: seed >> 16)
            pixels[offset + 3] = 0
        }
        return makePNGData(width: width,
                           height: height,
                           pixels: pixels,
                           alphaInfo: .noneSkipLast)
    }

    private static func makeTransparentNoisyPNGData(width: Int, height: Int) -> Data {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        var seed: UInt64 = 0xD134_2543_DE82_EF95
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let isTransparent = (offset / 4).isMultiple(of: 2)
            pixels[offset] = isTransparent ? 0 : UInt8(truncatingIfNeeded: seed)
            pixels[offset + 1] = isTransparent ? 0 : UInt8(truncatingIfNeeded: seed >> 8)
            pixels[offset + 2] = isTransparent ? 0 : UInt8(truncatingIfNeeded: seed >> 16)
            pixels[offset + 3] = isTransparent ? 0 : 255
        }
        return makePNGData(width: width,
                           height: height,
                           pixels: pixels,
                           alphaInfo: .premultipliedLast)
    }

    private static func makePNGData(width: Int,
                                    height: Int,
                                    pixels: [UInt8],
                                    alphaInfo: CGImageAlphaInfo) -> Data {
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        let bitmapInfo = CGBitmapInfo(rawValue: alphaInfo.rawValue)
        let image = CGImage(width: width,
                            height: height,
                            bitsPerComponent: 8,
                            bitsPerPixel: 32,
                            bytesPerRow: width * 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: bitmapInfo,
                            provider: provider,
                            decode: nil,
                            shouldInterpolate: false,
                            intent: .defaultIntent)!
        return encode(image: image, type: .png)
    }

    private static func previewImage(_ response: BridgeResponse) throws -> CGImage {
        let base64 = try XCTUnwrap(response.result?["data_base64"]?.stringValue)
        let data = try XCTUnwrap(Data(base64Encoded: base64))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    private static func containsTransparentPixel(_ image: CGImage) -> Bool {
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(data: nil,
                                      width: image.width,
                                      height: image.height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: image.width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: bitmapInfo),
              let rawData = context.data else {
            return false
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let pixels = rawData.bindMemory(to: UInt8.self, capacity: image.width * image.height * 4)
        return stride(from: 3, to: image.width * image.height * 4, by: 4).contains { pixels[$0] < 255 }
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

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.withLock { count }
    }

    func increment() {
        lock.withLock {
            count += 1
        }
    }
}

private struct StubImageRootResolver: PanelFileRootResolving {
    let rootPath: String

    func rootPath(workspaceID: String, panelID: String) throws -> String {
        rootPath
    }
}
