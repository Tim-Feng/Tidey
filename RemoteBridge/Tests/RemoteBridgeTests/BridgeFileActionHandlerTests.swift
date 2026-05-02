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

    func testFileWriteAllowsForcedOverwriteWithStaleRevisionToken() throws {
        let fixture = try makeFixture()
        let fileURL = fixture.rootURL.appendingPathComponent("README.md")
        try "before".write(to: fileURL, atomically: true, encoding: .utf8)

        let handler = BridgeFileActionHandler(rootResolver: fixture.rootResolver,
                                              fileManager: fixture.fileManager)

        let response = try XCTUnwrap(handler.handle(BridgeRequest(id: "request-1",
                                                                  action: "file_write",
                                                                  params: [
                                                                    "workspace_id": .string("workspace-1"),
                                                                    "panel_id": .string("panel-1"),
                                                                    "path": .string("README.md"),
                                                                    "content": .string("after"),
                                                                    "expected_revision_token": .string("stale-token"),
                                                                    "force": .bool(true),
                                                                  ])))

        XCTAssertTrue(response.ok)
        XCTAssertEqual(try String(contentsOf: fileURL), "after")
        XCTAssertEqual(response.result?["did_write"]?.boolValue, true)
    }

    func testFileReadRejectsPathOutsideRoot() throws {
        let fixture = try makeFixture()
        let outsideURL = fixture.tempDirectory.appendingPathComponent("outside.md")
        try "outside".write(to: outsideURL, atomically: true, encoding: .utf8)

        let handler = BridgeFileActionHandler(rootResolver: fixture.rootResolver,
                                              fileManager: fixture.fileManager,
                                              homeDirectoryURL: fixture.homeURL)

        XCTAssertThrowsError(try handler.handle(BridgeRequest(id: "request-1",
                                                              action: "file_read",
                                                              params: [
                                                                "workspace_id": .string("workspace-1"),
                                                                "panel_id": .string("panel-1"),
                                                                "path": .string(outsideURL.path),
                                                              ]))) { error in
            guard case BridgeInternalError.fileOutsideRoot(let message) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(message.contains("允許編輯"))
        }
    }

    func testFileReadExpandsTildeAndAllowsReadOnlyEditableDocumentUnderHome() throws {
        let fixture = try makeFixture()
        let fileURL = fixture.homeURL
            .appendingPathComponent("GitHub/thought-seeds/thoughts/raw", isDirectory: true)
            .appendingPathComponent("Andrej Karpathy - From Vibe Coding to Agentic Engineering.md")
        try fixture.fileManager.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try "notes".write(to: fileURL, atomically: true, encoding: .utf8)

        let handler = BridgeFileActionHandler(rootResolver: fixture.rootResolver,
                                              fileManager: fixture.fileManager,
                                              homeDirectoryURL: fixture.homeURL)
        let response = try XCTUnwrap(handler.handle(BridgeRequest(id: "request-1",
                                                                  action: "file_read",
                                                                  params: [
                                                                    "workspace_id": .string("workspace-1"),
                                                                    "panel_id": .string("panel-1"),
                                                                    "path": .string("~/GitHub/thought-seeds/thoughts/raw/Andrej Karpathy - From Vibe Coding to Agentic Engineering.md"),
                                                                  ])))

        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.result?["content"]?.stringValue, "notes")
        XCTAssertEqual(response.result?["normalized_path"]?.stringValue, fileURL.path)
        XCTAssertEqual(response.result?["read_only"]?.boolValue, true)
        XCTAssertEqual(response.result?["reason"]?.stringValue, "outside_workspace")
    }

    func testFileReadUsesOrdinaryTmuxRouteCWDForLogicalPanelRoot() throws {
        let fixture = try makeFixture()
        let tmuxRoot = fixture.tempDirectory.appendingPathComponent("tmux-window", isDirectory: true)
        try fixture.fileManager.createDirectory(at: tmuxRoot, withIntermediateDirectories: true)
        let fileURL = tmuxRoot.appendingPathComponent("README.md")
        try "tmux window file".write(to: fileURL, atomically: true, encoding: .utf8)
        let route = OrdinaryTmuxPanelRoute(workspaceID: "workspace-1",
                                           panelID: "ordinary-tmux:/tmp/tmux-\(getuid())/default:$7:@16",
                                           carrierPanelID: "carrier-panel",
                                           socket: .path("/tmp/tmux-\(getuid())/default"),
                                           sessionID: "$7",
                                           sessionName: "genesis-extraction",
                                           windowID: "@16",
                                           windowIndex: 1,
                                           activePaneID: "%16",
                                           cwd: tmuxRoot.path,
                                           currentCommand: "zsh")
        let rootResolver = TideyPanelFileRootResolver(socketSender: FailingTideyRequestSender(),
                                                      ordinaryTmuxRouteResolver: StubOrdinaryRouteResolver(route: route))
        let handler = BridgeFileActionHandler(rootResolver: rootResolver,
                                              fileManager: fixture.fileManager,
                                              homeDirectoryURL: fixture.homeURL)

        let response = try XCTUnwrap(handler.handle(BridgeRequest(id: "request-1",
                                                                  action: "file_read",
                                                                  params: [
                                                                    "workspace_id": .string("workspace-1"),
                                                                    "panel_id": .string(route.panelID),
                                                                    "path": .string("README.md"),
                                                                  ])))

        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.result?["content"]?.stringValue, "tmux window file")
        XCTAssertEqual(response.result?["normalized_path"]?.stringValue, fileURL.path)
    }

    func testFileReadRejectsHiddenHomePathOutsideRoot() throws {
        let fixture = try makeFixture()
        let fileURL = fixture.homeURL.appendingPathComponent(".ssh/notes.md")
        try fixture.fileManager.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try "secret".write(to: fileURL, atomically: true, encoding: .utf8)

        let handler = BridgeFileActionHandler(rootResolver: fixture.rootResolver,
                                              fileManager: fixture.fileManager,
                                              homeDirectoryURL: fixture.homeURL)

        XCTAssertThrowsError(try handler.handle(BridgeRequest(id: "request-1",
                                                              action: "file_read",
                                                              params: [
                                                                "workspace_id": .string("workspace-1"),
                                                                "panel_id": .string("panel-1"),
                                                                "path": .string("~/.ssh/notes.md"),
                                                              ]))) { error in
            guard case BridgeInternalError.fileOutsideRoot(let message) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(message.contains("允許編輯"))
        }
    }

    func testFileReadRejectsSensitiveHomePathOutsideRoot() throws {
        let fixture = try makeFixture()
        let fileURL = fixture.homeURL.appendingPathComponent("Library/Keychains/notes.md")
        try fixture.fileManager.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try "secret".write(to: fileURL, atomically: true, encoding: .utf8)

        let handler = BridgeFileActionHandler(rootResolver: fixture.rootResolver,
                                              fileManager: fixture.fileManager,
                                              homeDirectoryURL: fixture.homeURL)

        XCTAssertThrowsError(try handler.handle(BridgeRequest(id: "request-1",
                                                              action: "file_read",
                                                              params: [
                                                                "workspace_id": .string("workspace-1"),
                                                                "panel_id": .string("panel-1"),
                                                                "path": .string("~/Library/Keychains/notes.md"),
                                                              ]))) { error in
            guard case BridgeInternalError.fileOutsideRoot(let message) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(message.contains("允許編輯"))
        }
    }

    func testFileWriteRejectsEditableDocumentOutsideRootUnderHome() throws {
        let fixture = try makeFixture()
        let fileURL = fixture.homeURL.appendingPathComponent("GitHub/notes/outside.md")
        try fixture.fileManager.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try "before".write(to: fileURL, atomically: true, encoding: .utf8)

        let handler = BridgeFileActionHandler(rootResolver: fixture.rootResolver,
                                              fileManager: fixture.fileManager,
                                              homeDirectoryURL: fixture.homeURL)

        XCTAssertThrowsError(try handler.handle(BridgeRequest(id: "request-1",
                                                              action: "file_write",
                                                              params: [
                                                                "workspace_id": .string("workspace-1"),
                                                                "panel_id": .string("panel-1"),
                                                                "path": .string("~/GitHub/notes/outside.md"),
                                                                "content": .string("after"),
                                                                "expected_revision_token": .string("token"),
                                                              ]))) { error in
            guard case BridgeInternalError.fileOutsideRoot(let message) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(message.contains("允許編輯"))
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
            guard case BridgeInternalError.fileNotInAllowlist(let message) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(message.contains("不支援"))
        }
    }

    func testFileReadRejectsNonUTF8ContentWithSpecificCode() throws {
        let fixture = try makeFixture()
        let fileURL = fixture.rootURL.appendingPathComponent("README.md")
        let invalidUTF8 = Data([0xff, 0xfe, 0xfd])
        try invalidUTF8.write(to: fileURL)

        let handler = BridgeFileActionHandler(rootResolver: fixture.rootResolver,
                                              fileManager: fixture.fileManager)

        XCTAssertThrowsError(try handler.handle(BridgeRequest(id: "request-1",
                                                              action: "file_read",
                                                              params: [
                                                                "workspace_id": .string("workspace-1"),
                                                                "panel_id": .string("panel-1"),
                                                                "path": .string("README.md"),
                                                              ]))) { error in
            guard case BridgeInternalError.fileEncodingUnsupported(let message) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(message.contains("UTF-8"))
        }
    }

    func testFileWriteRejectsNonWritableTargetWithSpecificCode() throws {
        let fixture = try makeFixture()
        let fileURL = fixture.rootURL.appendingPathComponent("README.md")
        try "before".write(to: fileURL, atomically: true, encoding: .utf8)
        try fixture.fileManager.setAttributes([.posixPermissions: 0o444], ofItemAtPath: fileURL.path)

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
            guard case BridgeInternalError.fileNotWritable(let message) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(message.contains("寫入權限"))
        }
    }

    func testFileReadRequestsConfirmationForFilesLargerThanWarningThreshold() throws {
        let fixture = try makeFixture()
        let fileURL = fixture.rootURL.appendingPathComponent("README.md")
        try String(repeating: "a", count: 600 * 1024).write(to: fileURL, atomically: true, encoding: .utf8)

        let handler = BridgeFileActionHandler(rootResolver: fixture.rootResolver,
                                              fileManager: fixture.fileManager)

        XCTAssertThrowsError(try handler.handle(BridgeRequest(id: "request-1",
                                                              action: "file_read",
                                                              params: [
                                                                "workspace_id": .string("workspace-1"),
                                                                "panel_id": .string("panel-1"),
                                                                "path": .string("README.md"),
                                                              ]))) { error in
            guard case BridgeInternalError.fileNeedsConfirmation(let message) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(message.contains("512KB"))
        }
    }

    func testFileReadAllowsLargeFilesAfterConfirmation() throws {
        let fixture = try makeFixture()
        let fileURL = fixture.rootURL.appendingPathComponent("README.md")
        try String(repeating: "a", count: 600 * 1024).write(to: fileURL, atomically: true, encoding: .utf8)

        let handler = BridgeFileActionHandler(rootResolver: fixture.rootResolver,
                                              fileManager: fixture.fileManager)
        let response = try XCTUnwrap(handler.handle(BridgeRequest(id: "request-1",
                                                                  action: "file_read",
                                                                  params: [
                                                                    "workspace_id": .string("workspace-1"),
                                                                    "panel_id": .string("panel-1"),
                                                                    "path": .string("README.md"),
                                                                    "allow_large_read": .bool(true),
                                                                  ])))

        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.result?["size"]?.intValue, 600 * 1024)
    }

    func testFileReadRejectsFilesLargerThanMaximumSize() throws {
        let fixture = try makeFixture()
        let fileURL = fixture.rootURL.appendingPathComponent("README.md")
        try String(repeating: "a", count: 1100 * 1024).write(to: fileURL, atomically: true, encoding: .utf8)

        let handler = BridgeFileActionHandler(rootResolver: fixture.rootResolver,
                                              fileManager: fixture.fileManager)

        XCTAssertThrowsError(try handler.handle(BridgeRequest(id: "request-1",
                                                              action: "file_read",
                                                              params: [
                                                                "workspace_id": .string("workspace-1"),
                                                                "panel_id": .string("panel-1"),
                                                                "path": .string("README.md"),
                                                                "allow_large_read": .bool(true),
                                                              ]))) { error in
            guard case BridgeInternalError.fileTooLarge(let message) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(message.contains("1MB"))
        }
    }
}

private struct FileHandlerFixture {
    let tempDirectory: URL
    let rootURL: URL
    let homeURL: URL
    let fileManager: FileManager
    let rootResolver: MockPanelFileRootResolver
}

private func makeFixture() throws -> FileHandlerFixture {
    let fileManager = FileManager.default
    let tempDirectory = fileManager.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let rootURL = tempDirectory.appendingPathComponent("workspace-root", isDirectory: true)
    let homeURL = tempDirectory.appendingPathComponent("home", isDirectory: true)
    try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: homeURL, withIntermediateDirectories: true)
    return FileHandlerFixture(tempDirectory: tempDirectory,
                              rootURL: rootURL,
                              homeURL: homeURL,
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

private struct StubOrdinaryRouteResolver: OrdinaryTmuxRouteResolving {
    let route: OrdinaryTmuxPanelRoute?

    func route(forPanelID panelID: String, workspaceID: String?) throws -> OrdinaryTmuxPanelRoute? {
        route
    }
}

private struct FailingTideyRequestSender: TideyRequestSending {
    func send(_ request: BridgeRequest) throws -> BridgeResponse {
        throw BridgeInternalError.invalidRequest("unexpected Tidey socket request")
    }
}
