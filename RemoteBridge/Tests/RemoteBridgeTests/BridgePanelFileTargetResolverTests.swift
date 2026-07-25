import Foundation
import XCTest
@testable import RemoteBridge

final class BridgePanelFileTargetResolverTests: XCTestCase {
    func testResolvesRelativePathAgainstPanelRoot() throws {
        let fixture = try makeFixture()
        let fileURL = fixture.rootURL.appendingPathComponent("notes.md")
        try "hello".write(to: fileURL, atomically: true, encoding: .utf8)

        let resolved = try fixture.resolver.resolve(path: "notes.md",
                                                    workspaceID: "workspace-1",
                                                    panelID: "panel-1",
                                                    policy: BridgeDocumentFilePolicy.poc,
                                                    allowsReadOnlyHomeScope: true)

        XCTAssertEqual(resolved.targetURL.path, fileURL.resolvingSymlinksInPath().path)
        XCTAssertFalse(resolved.isReadOnlyOutsideRoot)
    }

    func testResolvesAbsolutePathInsideRoot() throws {
        let fixture = try makeFixture()
        let fileURL = fixture.rootURL.appendingPathComponent("notes.md")
        try "hello".write(to: fileURL, atomically: true, encoding: .utf8)

        let resolved = try fixture.resolver.resolve(path: fileURL.path,
                                                    workspaceID: "workspace-1",
                                                    panelID: "panel-1",
                                                    policy: BridgeDocumentFilePolicy.poc,
                                                    allowsReadOnlyHomeScope: true)

        XCTAssertFalse(resolved.isReadOnlyOutsideRoot)
    }

    func testExpandsTildeAgainstInjectedHome() throws {
        let fixture = try makeFixture()
        let fileURL = fixture.homeURL.appendingPathComponent("Documents/notes.md")
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try "hello".write(to: fileURL, atomically: true, encoding: .utf8)

        let resolved = try fixture.resolver.resolve(path: "~/Documents/notes.md",
                                                    workspaceID: "workspace-1",
                                                    panelID: "panel-1",
                                                    policy: BridgeDocumentFilePolicy.poc,
                                                    allowsReadOnlyHomeScope: true)

        XCTAssertTrue(resolved.isReadOnlyOutsideRoot)
    }

    func testRejectsDisallowedExtensionWithPolicyMessage() throws {
        let fixture = try makeFixture()
        let fileURL = fixture.rootURL.appendingPathComponent("binary.dat")
        try Data([0x00]).write(to: fileURL)

        XCTAssertThrowsError(try fixture.resolver.resolve(path: "binary.dat",
                                                          workspaceID: "workspace-1",
                                                          panelID: "panel-1",
                                                          policy: BridgeDocumentFilePolicy.poc,
                                                          allowsReadOnlyHomeScope: true)) { error in
            guard case BridgeInternalError.fileNotInAllowlist(let message) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(message, BridgeDocumentFilePolicy.poc.notInAllowlistMessage)
        }
    }

    func testRejectsTraversalOutsideRootAndHomeScope() throws {
        let fixture = try makeFixture()
        let outsideURL = fixture.tempDirectory.appendingPathComponent("escape.md")
        try "outside".write(to: outsideURL, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try fixture.resolver.resolve(path: "../escape.md",
                                                          workspaceID: "workspace-1",
                                                          panelID: "panel-1",
                                                          policy: BridgeDocumentFilePolicy.poc,
                                                          allowsReadOnlyHomeScope: true)) { error in
            guard case BridgeInternalError.fileOutsideRoot = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testRejectsHomeScopeWhenDisallowedByCaller() throws {
        let fixture = try makeFixture()
        let fileURL = fixture.homeURL.appendingPathComponent("notes.md")
        try "hello".write(to: fileURL, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try fixture.resolver.resolve(path: fileURL.path,
                                                          workspaceID: "workspace-1",
                                                          panelID: "panel-1",
                                                          policy: BridgeDocumentFilePolicy.poc,
                                                          allowsReadOnlyHomeScope: false)) { error in
            guard case BridgeInternalError.fileOutsideRoot = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testRejectsSymlinkEscapingRoot() throws {
        let fixture = try makeFixture()
        let outsideURL = fixture.tempDirectory.appendingPathComponent("secret.md")
        try "secret".write(to: outsideURL, atomically: true, encoding: .utf8)
        let linkURL = fixture.rootURL.appendingPathComponent("alias.md")
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: outsideURL)

        XCTAssertThrowsError(try fixture.resolver.resolve(path: "alias.md",
                                                          workspaceID: "workspace-1",
                                                          panelID: "panel-1",
                                                          policy: BridgeDocumentFilePolicy.poc,
                                                          allowsReadOnlyHomeScope: true)) { error in
            guard case BridgeInternalError.fileOutsideRoot = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    // MARK: - Safe opener

    // Direct opener calls use canonical paths, mirroring production order:
    // the resolver canonicalizes before the opener runs, and O_NOFOLLOW_ANY
    // rejects the /var -> /private/var symlink in raw temp paths.
    private func canonical(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    func testSafeOpenerReadsRegularFile() throws {
        let fixture = try makeFixture()
        let fileURL = fixture.rootURL.appendingPathComponent("data.bin")
        try Data([0x01, 0x02, 0x03]).write(to: fileURL)

        let opened = try BridgeSafeFileOpener.openRegularFile(at: canonical(fileURL),
                                                              notFoundMessage: "missing",
                                                              outsideScopeMessage: "outside")
        defer { opened.close() }

        XCTAssertEqual(opened.size, 3)
        XCTAssertEqual(opened.revisionToken.split(separator: ":").count, 3)
        XCTAssertEqual(try opened.fileHandle.readToEnd(), Data([0x01, 0x02, 0x03]))
    }

    func testSafeOpenerRejectsSymlinkFinalComponent() throws {
        let fixture = try makeFixture()
        let targetURL = fixture.rootURL.appendingPathComponent("target.bin")
        try Data([0x01]).write(to: targetURL)
        let linkURL = fixture.rootURL.appendingPathComponent("swapped.bin")
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: targetURL)

        XCTAssertThrowsError(try BridgeSafeFileOpener.openRegularFile(at: canonical(fixture.rootURL).appendingPathComponent("swapped.bin"),
                                                                      notFoundMessage: "missing",
                                                                      outsideScopeMessage: "outside")) { error in
            guard case BridgeInternalError.fileOutsideRoot(let message) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(message, "outside")
        }
    }

    func testSafeOpenerRejectsSymlinkedAncestorDirectory() throws {
        let fixture = try makeFixture()
        let realDirectory = fixture.rootURL.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: realDirectory, withIntermediateDirectories: true)
        let fileURL = realDirectory.appendingPathComponent("data.bin")
        try Data([0x01]).write(to: fileURL)
        let linkedDirectory = fixture.rootURL.appendingPathComponent("linked", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: linkedDirectory, withDestinationURL: realDirectory)

        // Simulates an ancestor directory swapped for a symlink after the
        // resolver's canonicalization: the open itself must refuse it.
        let swappedPath = canonical(fixture.rootURL)
            .appendingPathComponent("linked", isDirectory: true)
            .appendingPathComponent("data.bin")
        XCTAssertThrowsError(try BridgeSafeFileOpener.openRegularFile(at: swappedPath,
                                                                      notFoundMessage: "missing",
                                                                      outsideScopeMessage: "outside")) { error in
            guard case BridgeInternalError.fileOutsideRoot(let message) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(message, "outside")
        }
    }

    func testSafeOpenerRejectsFIFOWithoutBlocking() throws {
        let fixture = try makeFixture()
        let fifoURL = canonical(fixture.rootURL).appendingPathComponent("image.png")
        XCTAssertEqual(mkfifo(fifoURL.path, 0o644), 0)

        let startedAt = Date()
        XCTAssertThrowsError(try BridgeSafeFileOpener.openRegularFile(at: fifoURL,
                                                                      notFoundMessage: "missing",
                                                                      outsideScopeMessage: "outside")) { error in
            guard case BridgeInternalError.fileOutsideRoot = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 2.0,
                          "opening a FIFO with no writer must not block")
    }

    func testSafeOpenerFarFutureMtimeDoesNotCrash() throws {
        let fixture = try makeFixture()
        let fileURL = fixture.rootURL.appendingPathComponent("future.bin")
        try Data([0x01]).write(to: fileURL)
        // Year ~2262, near the APFS nanosecond range limit; combining
        // sec * 1e9 + nsec here is what used to be able to overflow.
        try? FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 9_223_372_036)],
                                               ofItemAtPath: fileURL.path)

        let opened = try BridgeSafeFileOpener.openRegularFile(at: canonical(fileURL),
                                                              notFoundMessage: "missing",
                                                              outsideScopeMessage: "outside")
        defer { opened.close() }

        XCTAssertEqual(opened.revisionToken.split(separator: ":").count, 3)
    }

    func testSafeOpenerRejectsDirectory() throws {
        let fixture = try makeFixture()

        XCTAssertThrowsError(try BridgeSafeFileOpener.openRegularFile(at: canonical(fixture.rootURL),
                                                                      notFoundMessage: "missing",
                                                                      outsideScopeMessage: "outside")) { error in
            guard case BridgeInternalError.fileOutsideRoot = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testSafeOpenerRejectsMissingFile() throws {
        let fixture = try makeFixture()
        let missingURL = canonical(fixture.rootURL).appendingPathComponent("missing.bin")

        XCTAssertThrowsError(try BridgeSafeFileOpener.openRegularFile(at: missingURL,
                                                                      notFoundMessage: "missing",
                                                                      outsideScopeMessage: "outside")) { error in
            guard case BridgeInternalError.notFound(let message) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(message, "missing")
        }
    }

    func testBoundedReadStopsOneByteOverCap() throws {
        let fixture = try makeFixture()
        let fileURL = fixture.rootURL.appendingPathComponent("grown.bin")
        try Data(repeating: 0xAB, count: 4096).write(to: fileURL)

        let opened = try BridgeSafeFileOpener.openRegularFile(at: canonical(fileURL),
                                                              notFoundMessage: "missing",
                                                              outsideScopeMessage: "outside")
        defer { opened.close() }

        // A cap below the on-disk size stands in for a file that grew after
        // fstat: the reader must stop at cap + 1, never buffer it all.
        let data = try BridgeSafeFileOpener.readBounded(from: opened.fileHandle, maximumBytes: 1000)
        XCTAssertEqual(data.count, 1001)

        let reopened = try BridgeSafeFileOpener.openRegularFile(at: canonical(fileURL),
                                                                notFoundMessage: "missing",
                                                                outsideScopeMessage: "outside")
        defer { reopened.close() }
        let full = try BridgeSafeFileOpener.readBounded(from: reopened.fileHandle, maximumBytes: 4096)
        XCTAssertEqual(full.count, 4096)
    }

    // MARK: - Fixture

    private struct ResolverFixture {
        let tempDirectory: URL
        let rootURL: URL
        let homeURL: URL
        let resolver: BridgePanelFileTargetResolver
    }

    private func makeFixture() throws -> ResolverFixture {
        let fileManager = FileManager.default
        let tempDirectory = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let rootURL = tempDirectory.appendingPathComponent("workspace-root", isDirectory: true)
        let homeURL = tempDirectory.appendingPathComponent("home", isDirectory: true)
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: homeURL, withIntermediateDirectories: true)
        addTeardownBlock {
            try? fileManager.removeItem(at: tempDirectory)
        }
        let resolver = BridgePanelFileTargetResolver(rootResolver: StubRootResolver(rootPath: rootURL.path),
                                                     fileManager: fileManager,
                                                     homeDirectoryURL: homeURL)
        return ResolverFixture(tempDirectory: tempDirectory,
                               rootURL: rootURL,
                               homeURL: homeURL,
                               resolver: resolver)
    }
}

private struct StubRootResolver: PanelFileRootResolving {
    let rootPath: String

    func rootPath(workspaceID: String, panelID: String) throws -> String {
        rootPath
    }
}
