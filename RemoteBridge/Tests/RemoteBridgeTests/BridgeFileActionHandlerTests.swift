import Foundation
import XCTest
@testable import RemoteBridge

final class BridgeFileActionHandlerTests: XCTestCase {
    func testFileReadReturnsUTF8ContentAndRevisionToken() throws {
        let fixture = try makeFixture()
        let fileURL = fixture.rootURL.appendingPathComponent("README.md")
        try "hello".write(to: fileURL, atomically: true, encoding: .utf8)

        let handler = BridgeFileActionHandler(rootResolver: fixture.rootResolver,
                                              fileManager: fixture.fileManager)
        let response = try XCTUnwrap(handler.handle(BridgeRequest(id: "request-1",
                                                                  action: "file_read",
                                                                  params: [
                                                                    "workspace_id": .string("workspace-1"),
                                                                    "panel_id": .string("panel-1"),
                                                                    "path": .string("README.md"),
                                                                  ])))

        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.result?["content"]?.stringValue, "hello")
        XCTAssertEqual(response.result?["normalized_path"]?.stringValue, fileURL.path)
        XCTAssertEqual(response.result?["encoding"]?.stringValue, "utf-8")
        XCTAssertNotNil(response.result?["revision_token"]?.stringValue)
    }

    func testFileWriteUpdatesContentWhenRevisionTokenMatches() throws {
        let fixture = try makeFixture()
        let fileURL = fixture.rootURL.appendingPathComponent("README.md")
        try "before".write(to: fileURL, atomically: true, encoding: .utf8)

        let handler = BridgeFileActionHandler(rootResolver: fixture.rootResolver,
                                              fileManager: fixture.fileManager)
        let readResponse = try XCTUnwrap(handler.handle(BridgeRequest(id: "request-1",
                                                                      action: "file_read",
                                                                      params: [
                                                                        "workspace_id": .string("workspace-1"),
                                                                        "panel_id": .string("panel-1"),
                                                                        "path": .string("README.md"),
                                                                      ])))
        let revisionToken = try XCTUnwrap(readResponse.result?["revision_token"]?.stringValue)

        let writeResponse = try XCTUnwrap(handler.handle(BridgeRequest(id: "request-2",
                                                                       action: "file_write",
                                                                       params: [
                                                                        "workspace_id": .string("workspace-1"),
                                                                        "panel_id": .string("panel-1"),
                                                                        "path": .string("README.md"),
                                                                        "content": .string("after"),
                                                                        "expected_revision_token": .string(revisionToken),
                                                                       ])))

        XCTAssertTrue(writeResponse.ok)
        XCTAssertEqual(try String(contentsOf: fileURL), "after")
        XCTAssertEqual(writeResponse.result?["did_write"]?.boolValue, true)
        XCTAssertNotEqual(writeResponse.result?["revision_token"]?.stringValue, revisionToken)
    }

    func testFileWriteRejectsMismatchedRevisionToken() throws {
        let fixture = try makeFixture()
        let fileURL = fixture.rootURL.appendingPathComponent("README.md")
        try "before".write(to: fileURL, atomically: true, encoding: .utf8)

        let handler = BridgeFileActionHandler(rootResolver: fixture.rootResolver,
                                              fileManager: fixture.fileManager)

        XCTAssertThrowsError(try handler.handle(BridgeRequest(id: "request-1",
                                                              action: "file_write",
                                                              params: [
                                                                "workspace_id": .string("workspace-1"),
                                                                "panel_id": .string("panel-1"),
                                                                "path": .string("README.md"),
                                                                "content": .string("after"),
                                                                "expected_revision_token": .string("stale-token"),
                                                              ]))) { error in
            guard case BridgeInternalError.conflict(let message) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(message.contains("expected_revision_token"))
        }
    }

    func testFileReadRejectsPathOutsideRoot() throws {
        let fixture = try makeFixture()
        let outsideURL = fixture.tempDirectory.appendingPathComponent("outside.md")
        try "outside".write(to: outsideURL, atomically: true, encoding: .utf8)

        let handler = BridgeFileActionHandler(rootResolver: fixture.rootResolver,
                                              fileManager: fixture.fileManager)

        XCTAssertThrowsError(try handler.handle(BridgeRequest(id: "request-1",
                                                              action: "file_read",
                                                              params: [
                                                                "workspace_id": .string("workspace-1"),
                                                                "panel_id": .string("panel-1"),
                                                                "path": .string(outsideURL.path),
                                                              ]))) { error in
            guard case BridgeInternalError.forbidden(let message) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(message.contains("panel root"))
        }
    }

    func testFileReadRejectsNonAllowlistedExtension() throws {
        let fixture = try makeFixture()
        let fileURL = fixture.rootURL.appendingPathComponent("script.swift")
        try "print(1)".write(to: fileURL, atomically: true, encoding: .utf8)

        let handler = BridgeFileActionHandler(rootResolver: fixture.rootResolver,
                                              fileManager: fixture.fileManager)

        XCTAssertThrowsError(try handler.handle(BridgeRequest(id: "request-1",
                                                              action: "file_read",
                                                              params: [
                                                                "workspace_id": .string("workspace-1"),
                                                                "panel_id": .string("panel-1"),
                                                                "path": .string("script.swift"),
                                                              ]))) { error in
            guard case BridgeInternalError.forbidden(let message) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(message.contains("allowlist"))
        }
    }
}

private struct FileHandlerFixture {
    let tempDirectory: URL
    let rootURL: URL
    let fileManager: FileManager
    let rootResolver: MockPanelFileRootResolver
}

private func makeFixture() throws -> FileHandlerFixture {
    let fileManager = FileManager.default
    let tempDirectory = fileManager.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let rootURL = tempDirectory.appendingPathComponent("workspace-root", isDirectory: true)
    try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
    return FileHandlerFixture(tempDirectory: tempDirectory,
                              rootURL: rootURL,
                              fileManager: fileManager,
                              rootResolver: MockPanelFileRootResolver(rootPath: rootURL.path))
}

private final class MockPanelFileRootResolver: PanelFileRootResolving {
    private let rootPathValue: String

    init(rootPath: String) {
        self.rootPathValue = rootPath
    }

    func rootPath(workspaceID: String, panelID: String) throws -> String {
        rootPathValue
    }
}
