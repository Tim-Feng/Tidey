//
//  PathTests.swift
//  iTerm2
//
//  Created by George Nachman on 2/4/26.
//

import XCTest
@testable import iTerm2SharedARC

/// Tests for path methods to verify correct behavior with and without custom suite names.
/// These tests establish baseline behavior and verify no regressions when --suite is not used.
final class PathTests: XCTestCase {

    // MARK: - Application Support Directory Tests

    func testApplicationSupportDirectory_DefaultSuite() {
        // Given: No custom suite is set (default behavior)
        // Note: We can't easily reset the suite in tests since it's set once at startup

        // When
        let path = FileManager.default.applicationSupportDirectory()

        // Then
        XCTAssertNotNil(path)
        XCTAssertTrue(path!.contains("Application Support"))
        // Default should use iTerm2 as the directory name
        XCTAssertTrue(path!.hasSuffix("/iTerm2") || path!.contains("iTerm2"))
    }

    func testApplicationSupportDirectoryWithoutCreating_DefaultSuite() {
        // When
        let path = FileManager.default.applicationSupportDirectoryWithoutCreating()

        // Then
        XCTAssertNotNil(path)
        XCTAssertTrue(path!.contains("Application Support"))
        XCTAssertTrue(path!.hasSuffix("/iTerm2") || path!.contains("iTerm2"))
    }

    // MARK: - Home Directory Dot-Dir Tests

    func testHomeDirectoryDotDir_DefaultSuite() {
        // When
        let path = FileManager.default.homeDirectoryDotDir()

        // Then
        XCTAssertNotNil(path)
        // Should be ~/.config/iterm2 or ~/.iterm2 (or custom preferredBaseDir)
        let homedir = NSHomeDirectory()
        XCTAssertTrue(
            path!.hasPrefix(homedir),
            "Path should be under home directory"
        )
        // Should contain iterm2 somewhere in the path
        let lowercasePath = path!.lowercased()
        XCTAssertTrue(
            lowercasePath.contains("iterm2") || lowercasePath.contains(".iterm2"),
            "Path should contain 'iterm2'"
        )
    }

    // MARK: - Custom Suite Name Accessor Tests

    func testCustomSuiteName_ReturnsNilOrSetValue() {
        // This test documents the behavior of customSuiteName accessor
        // The actual value depends on whether --suite was passed at startup
        let suiteName = iTermUserDefaults.customSuiteName()

        // The test passes regardless of value - we're just documenting that the method exists
        // and returns either nil (no suite) or a string (custom suite)
        if let name = suiteName {
            XCTAssertFalse(name.isEmpty, "If a suite name is set, it should not be empty")
        }
        // nil is also valid - means no custom suite
    }

    // MARK: - Integration Tests

    func testScriptsPath_UsesApplicationSupportDirectory() {
        // When
        let scriptsPath = FileManager.default.scriptsPath()

        // Then
        XCTAssertNotNil(scriptsPath)
        // Scripts path should be under Application Support (unless custom folder is set)
        let appSupport = FileManager.default.applicationSupportDirectory()
        if appSupport != nil {
            // Either it's under app support or it's a custom scripts folder
            let isUnderAppSupport = scriptsPath!.hasPrefix(appSupport!)
            let isCustomFolder = iTermPreferences.bool(forKey: kPreferenceKeyUseCustomScriptsFolder)
            XCTAssertTrue(isUnderAppSupport || isCustomFolder,
                          "Scripts path should be under app support or custom folder")
        }
    }
}

final class ClaudeHookRegistryTests: XCTestCase {
    func testClaudeHookInputContextReadsSessionIDTranscriptPathAndCWD() throws {
        let stdinJSON = """
        {
          "session_id": "c211f108-d22f-4813-bde4-a72c5241034a",
          "transcript_path": "~/Library/Application Support/Claude/test.jsonl",
          "cwd": "/Users/timfeng/GitHub/Tidey",
          "hook_event_name": "SessionStart"
        }
        """

        let context = TideyCLICommandFormatter.claudeHookInputContext(stdinData: stdinJSON.data(using: .utf8))

        XCTAssertEqual(context?.sessionID, "c211f108-d22f-4813-bde4-a72c5241034a")
        XCTAssertEqual(context?.transcriptPath, "~/Library/Application Support/Claude/test.jsonl")
        XCTAssertEqual(context?.cwd, "/Users/timfeng/GitHub/Tidey")
    }

    func testClaudeHookInputContextFallsBackToTranscriptFilenameForSessionID() throws {
        let stdinJSON = """
        {
          "transcript_path": "/Users/timfeng/.claude/projects/-Users-timfeng/c211f108-d22f-4813-bde4-a72c5241034a.jsonl",
          "cwd": "/Users/timfeng"
        }
        """

        let context = TideyCLICommandFormatter.claudeHookInputContext(stdinData: stdinJSON.data(using: .utf8))

        XCTAssertEqual(context?.sessionID, "c211f108-d22f-4813-bde4-a72c5241034a")
    }

    func testWriteAndRemoveClaudeRegistryFile() throws {
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: tempRoot)
        }

        let writtenURL = try TideyCLICommandFormatter.writeClaudeRegistryFile(
            registryRoot: tempRoot,
            workspaceID: "ws-1",
            sessionID: "c211f108-d22f-4813-bde4-a72c5241034a",
            panelID: "panel-1",
            pid: 12345,
            cwd: "/Users/timfeng/GitHub/Tidey",
            createdAt: "2026-04-13T03:35:00Z",
            transcriptPath: "/Users/timfeng/.claude/projects/-Users-timfeng/c211f108-d22f-4813-bde4-a72c5241034a.jsonl"
        )

        let data = try Data(contentsOf: writtenURL)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        XCTAssertEqual(object?["version"] as? Int, 1)
        XCTAssertEqual(object?["vendor"] as? String, "claude")
        XCTAssertEqual(object?["workspace_id"] as? String, "ws-1")
        XCTAssertEqual(object?["session_id"] as? String, "c211f108-d22f-4813-bde4-a72c5241034a")
        XCTAssertEqual(object?["panel_id"] as? String, "panel-1")
        XCTAssertEqual(object?["pid"] as? Int, 12345)
        XCTAssertEqual(object?["cwd"] as? String, "/Users/timfeng/GitHub/Tidey")
        XCTAssertEqual(object?["created_at"] as? String, "2026-04-13T03:35:00Z")
        XCTAssertEqual(object?["transcript_path"] as? String, "/Users/timfeng/.claude/projects/-Users-timfeng/c211f108-d22f-4813-bde4-a72c5241034a.jsonl")

        try TideyCLICommandFormatter.removeClaudeRegistryFile(registryRoot: tempRoot,
                                                              sessionID: "c211f108-d22f-4813-bde4-a72c5241034a")
        XCTAssertFalse(FileManager.default.fileExists(atPath: writtenURL.path))
    }
}
