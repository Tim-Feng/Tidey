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

    func testSafeOpenerReadsRegularFile() throws {
        let fixture = try makeFixture()
        let fileURL = fixture.rootURL.appendingPathComponent("data.bin")
        try Data([0x01, 0x02, 0x03]).write(to: fileURL)

        let opened = try BridgeSafeFileOpener.openRegularFile(at: fileURL,
                                                              notFoundMessage: "missing",
                                                              outsideScopeMessage: "outside")
        defer { opened.close() }

        XCTAssertEqual(opened.size, 3)
        XCTAssertGreaterThan(opened.modificationTimeNanoseconds, 0)
        XCTAssertEqual(try opened.fileHandle.readToEnd(), Data([0x01, 0x02, 0x03]))
    }

    func testSafeOpenerRejectsSymlinkFinalComponent() throws {
        let fixture = try makeFixture()
        let targetURL = fixture.rootURL.appendingPathComponent("target.bin")
        try Data([0x01]).write(to: targetURL)
        let linkURL = fixture.rootURL.appendingPathComponent("swapped.bin")
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: targetURL)

        XCTAssertThrowsError(try BridgeSafeFileOpener.openRegularFile(at: linkURL,
                                                                      notFoundMessage: "missing",
                                                                      outsideScopeMessage: "outside")) { error in
            guard case BridgeInternalError.fileOutsideRoot(let message) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(message, "outside")
        }
    }

    func testSafeOpenerRejectsDirectory() throws {
        let fixture = try makeFixture()

        XCTAssertThrowsError(try BridgeSafeFileOpener.openRegularFile(at: fixture.rootURL,
                                                                      notFoundMessage: "missing",
                                                                      outsideScopeMessage: "outside")) { error in
            guard case BridgeInternalError.fileOutsideRoot = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testSafeOpenerRejectsMissingFile() throws {
        let fixture = try makeFixture()
        let missingURL = fixture.rootURL.appendingPathComponent("missing.bin")

        XCTAssertThrowsError(try BridgeSafeFileOpener.openRegularFile(at: missingURL,
                                                                      notFoundMessage: "missing",
                                                                      outsideScopeMessage: "outside")) { error in
            guard case BridgeInternalError.notFound(let message) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(message, "missing")
        }
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
