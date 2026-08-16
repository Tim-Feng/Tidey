import Foundation
import XCTest
@testable import RemoteBridge

final class BridgeVideoPrepareHandlerTests: XCTestCase {
    private static let samples = [
        "/Users/timfeng/GitHub/adbrewer/projects/embryo-074/production-design/experiments/directors-layout-full-codex-v01/renders/codex-director-layout-v04.mp4",
        "/Users/timfeng/GitHub/adbrewer/projects/embryo-074/production-design/experiments/directors-layout-full-cc-v01/renders/directors-layout-full-cc-v01.mp4",
    ]

    func testCanonicalTailMoovSamplesProbeAsDirectWithoutLayoutRouting() async throws {
        for path in Self.samples {
            try XCTSkipUnless(FileManager.default.fileExists(atPath: path), "canonical local sample is unavailable")
            let handler = BridgeVideoPrepareHandler(
                rootResolver: StubVideoRootResolver(rootPath: "/Users/timfeng/GitHub/adbrewer")
            )

            let result = try await handler.probe(path: path,
                                                 workspaceID: "workspace-1",
                                                 panelID: "panel-1")

            XCTAssertEqual(result.route, .direct, path)
            XCTAssertEqual(result.mime, "video/mp4", path)
            XCTAssertEqual(result.durationMS, 30_000, accuracy: 100, path)
            XCTAssertFalse(result.hasAudio, path)
            XCTAssertGreaterThan(result.size, 3_000_000, path)
            XCTAssertFalse(result.revisionToken.isEmpty, path)
        }
    }

    func testReadableButUnplayableMetadataRoutesToTranscodeAndNeverRemux() async throws {
        let fixture = try makeFixture(fileExtension: "mov")
        let metadata = BridgeVideoProbeMetadata(isReadable: true,
                                                isPlayable: false,
                                                hasVideo: true,
                                                hasAudio: true,
                                                enabledTracksAreSelfContained: true,
                                                durationMS: 4_200,
                                                mime: "video/quicktime")
        let handler = BridgeVideoPrepareHandler(rootResolver: StubVideoRootResolver(rootPath: fixture.root.path),
                                                metadataProbe: { _ in metadata })

        let result = try await handler.probe(path: fixture.file.lastPathComponent,
                                             workspaceID: "workspace-1",
                                             panelID: "panel-1")

        XCTAssertEqual(result.route, .transcode)
        XCTAssertNotEqual(result.route, .remux)
    }

    func testUnreadableContainerAndExternalTrackFailClosedAsUnsupported() async throws {
        for metadata in [
            BridgeVideoProbeMetadata(isReadable: false,
                                     isPlayable: false,
                                     hasVideo: false,
                                     hasAudio: false,
                                     enabledTracksAreSelfContained: true,
                                     durationMS: 0,
                                     mime: "video/x-matroska"),
            BridgeVideoProbeMetadata(isReadable: true,
                                     isPlayable: true,
                                     hasVideo: true,
                                     hasAudio: false,
                                     enabledTracksAreSelfContained: false,
                                     durationMS: 1_000,
                                     mime: "video/quicktime"),
        ] {
            let fixture = try makeFixture(fileExtension: "mkv")
            let handler = BridgeVideoPrepareHandler(rootResolver: StubVideoRootResolver(rootPath: fixture.root.path),
                                                    metadataProbe: { _ in metadata })

            let result = try await handler.probe(path: fixture.file.lastPathComponent,
                                                 workspaceID: "workspace-1",
                                                 panelID: "panel-1")
            XCTAssertEqual(result.route, .unsupported)
        }
    }

    func testIdentityChangeDuringProbeFailsClosed() async throws {
        let fixture = try makeFixture(fileExtension: "mp4")
        let replacement = Data(repeating: 0x42, count: 64)
        let handler = BridgeVideoPrepareHandler(
            rootResolver: StubVideoRootResolver(rootPath: fixture.root.path),
            metadataProbe: { url in
                try replacement.write(to: url, options: .atomic)
                return BridgeVideoProbeMetadata(isReadable: true,
                                                isPlayable: true,
                                                hasVideo: true,
                                                hasAudio: false,
                                                enabledTracksAreSelfContained: true,
                                                durationMS: 1_000,
                                                mime: "video/mp4")
            }
        )

        do {
            _ = try await handler.probe(path: fixture.file.lastPathComponent,
                                        workspaceID: "workspace-1",
                                        panelID: "panel-1")
            XCTFail("Expected identity replacement to fail closed")
        } catch {
            guard case BridgeInternalError.forbidden = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    private func makeFixture(fileExtension: String) throws -> (root: URL, file: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tidey-video-probe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("fixture.\(fileExtension)")
        try Data(repeating: 0x11, count: 32).write(to: file)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return (root, file)
    }
}

private struct StubVideoRootResolver: PanelFileRootResolving {
    let rootPath: String

    func rootPath(workspaceID: String, panelID: String) throws -> String {
        rootPath
    }
}
