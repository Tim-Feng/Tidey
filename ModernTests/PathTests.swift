//
//  PathTests.swift
//  iTerm2
//
//  Created by George Nachman on 2/4/26.
//

import XCTest
@testable import iTerm2SharedARC
import Darwin

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

    func testFilenameCharacterSetStopsAtFullWidthParentheticalSuffix() {
        let source = "~/.claude/skills/skill-creator/SKILL.md（Project Conventions 改成新預設）" as NSString
        let offset = source.range(of: "SKILL.md").location + "SKILL.md".count - 1
        let extracted = source.substringIncludingOffset(Int32(offset),
                                                        from: CharacterSet.filenameCharacterSet(),
                                                        charsTakenFromPrefix: nil)

        XCTAssertEqual(extracted, "~/.claude/skills/skill-creator/SKILL.md")
    }

    func testURLCharacterSetStopsAtFullWidthParentheticalSuffix() {
        let source = "https://example.com/docs/shared-resource-patterns.md（2845 bytes，新）" as NSString
        let offset = source.range(of: "patterns.md").location + "patterns.md".count - 1
        let extracted = source.substringIncludingOffset(Int32(offset),
                                                        from: CharacterSet.urlCharacterSet(),
                                                        charsTakenFromPrefix: nil)

        XCTAssertEqual(extracted, "https://example.com/docs/shared-resource-patterns.md")
    }

    func testPathFinderIgnoresFullWidthParentheticalSuffixAfterTildePath() throws {
        let root = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library/Caches/TideyPathBoundaryTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
        }

        let fileURL = root.appendingPathComponent("shared-resource-patterns.md")
        try "test".write(to: fileURL, atomically: true, encoding: .utf8)

        let relativePath = fileURL.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        let finder = iTermPathFinder(prefix: relativePath,
                                     suffix: "（2845 bytes，新）",
                                     workingDirectory: NSHomeDirectory(),
                                     trimWhitespace: false,
                                     ignore: "",
                                     allowNetworkMounts: false)
        finder.searchSynchronously()

        XCTAssertEqual(finder.path, fileURL.path)
    }

    func testFileURLWithoutFragmentUsesSemanticHistoryRoute() {
        let helper = iTermURLActionHelper(semanticHistoryController: iTermSemanticHistoryController(prefs: [:]))
        let url = URL(fileURLWithPath: "/Users/timfeng/GitHub/life-system/TODO.md")

        XCTAssertTrue(helper.shouldOpenFileURLWithSemanticHistory(url))
    }

    func testFileURLWithFragmentUsesSemanticHistoryRoute() {
        let helper = iTermURLActionHelper(semanticHistoryController: iTermSemanticHistoryController(prefs: [:]))
        let url = URL(string: "file:///Users/timfeng/GitHub/life-system/TODO.md#12:3")!

        XCTAssertTrue(helper.shouldOpenFileURLWithSemanticHistory(url))
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

final class CodexWrapperRegistryTests: XCTestCase {
    func testCodexWrapperWritesRegistryUsingLauncherChildRollout() throws {
        let sessionID = "22222222-2222-2222-2222-222222222222"
        let environment = try makeCodexWrapperTestEnvironment(initialSessionID: sessionID)
        let process = try launchCodexWrapper(environment: environment)
        defer { terminate(process) }

        let registryURL = environment.registryRoot.appendingPathComponent("codex-\(sessionID).json")
        let object = try waitForRegistryJSON(at: registryURL)

        XCTAssertEqual(object["session_id"] as? String, sessionID)
        XCTAssertEqual(object["workspace_id"] as? String, "ws-test")
        XCTAssertEqual(object["panel_id"] as? String, "panel-test")
        XCTAssertEqual(object["rollout_path"] as? String, environment.initialRolloutPath)
        XCTAssertEqual(object["transcript_path"] as? String, environment.initialRolloutPath)
    }

    func testCodexWrapperRewritesRegistryWhenLauncherChildRolloutChanges() throws {
        let firstSessionID = "22222222-2222-2222-2222-222222222222"
        let secondSessionID = "33333333-3333-3333-3333-333333333333"
        let environment = try makeCodexWrapperTestEnvironment(initialSessionID: firstSessionID,
                                                              nextSessionID: secondSessionID)
        let process = try launchCodexWrapper(environment: environment)
        defer { terminate(process) }

        let firstRegistryURL = environment.registryRoot.appendingPathComponent("codex-\(firstSessionID).json")
        _ = try waitForRegistryJSON(at: firstRegistryURL)

        let secondRegistryURL = environment.registryRoot.appendingPathComponent("codex-\(secondSessionID).json")
        let object = try waitForRegistryJSON(at: secondRegistryURL, timeout: 5.0)

        XCTAssertEqual(object["session_id"] as? String, secondSessionID)
        XCTAssertEqual(object["rollout_path"] as? String, environment.nextRolloutPath)
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstRegistryURL.path))
    }

    private func makeCodexWrapperTestEnvironment(initialSessionID: String,
                                                 nextSessionID: String? = nil) throws -> CodexWrapperTestEnvironment {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }

        let fakeHome = root.appendingPathComponent("home", isDirectory: true)
        let fakeBin = root.appendingPathComponent("bin", isDirectory: true)
        let registryRoot = fakeHome
            .appendingPathComponent("Library/Application Support/Tidey Remote Bridge/agent-sessions/codex",
                                    isDirectory: true)
        let codexSessionsRoot = fakeHome.appendingPathComponent(".codex/sessions/2099/01/01", isDirectory: true)
        try FileManager.default.createDirectory(at: fakeBin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: registryRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codexSessionsRoot, withIntermediateDirectories: true)

        let initialRolloutPath = codexSessionsRoot
            .appendingPathComponent("rollout-test-\(initialSessionID).jsonl").path
        FileManager.default.createFile(atPath: initialRolloutPath,
                                       contents: Data("{\"event\":\"initial\"}\n".utf8))

        let nextRolloutPath: String?
        if let nextSessionID {
            let path = codexSessionsRoot
                .appendingPathComponent("rollout-test-\(nextSessionID).jsonl").path
            FileManager.default.createFile(atPath: path,
                                           contents: Data("{\"event\":\"next\"}\n".utf8))
            nextRolloutPath = path
        } else {
            nextRolloutPath = nil
        }

        let rolloutStateFile = root.appendingPathComponent("rollout-state.txt")
        try initialRolloutPath.write(to: rolloutStateFile, atomically: true, encoding: .utf8)

        try writeExecutable(at: fakeBin.appendingPathComponent("pgrep"), contents: """
        #!/usr/bin/env bash
        if [[ "${1:-}" == "-P" ]]; then
            printf '%s\\n' "${FAKE_CODEX_CHILD_PID:-99999}"
        fi
        """)

        try writeExecutable(at: fakeBin.appendingPathComponent("lsof"), contents: """
        #!/usr/bin/env bash
        pid=""
        while [[ $# -gt 0 ]]; do
            if [[ "$1" == "-p" && $# -ge 2 ]]; then
                pid="$2"
                shift 2
                continue
            fi
            shift
        done
        if [[ "$pid" == "${FAKE_CODEX_CHILD_PID:-99999}" && -f "$FAKE_ROLLOUT_STATE_FILE" ]]; then
            path="$(cat "$FAKE_ROLLOUT_STATE_FILE")"
            if [[ -n "$path" ]]; then
                printf 'n%s\\n' "$path"
            fi
        fi
        """)

        try writeExecutable(at: fakeBin.appendingPathComponent("codex"), contents: """
        #!/usr/bin/env bash
        if [[ -n "${FAKE_NEXT_ROLLOUT_PATH:-}" ]]; then
            sleep 1
            printf '%s' "$FAKE_NEXT_ROLLOUT_PATH" > "$FAKE_ROLLOUT_STATE_FILE"
            sleep 2
        else
            sleep 2
        fi
        """)

        let socketPath = root.appendingPathComponent("tidey.sock").path
        let socketHandle = try UNIXSocketFile(path: socketPath)
        addTeardownBlock {
            socketHandle.close()
        }

        return CodexWrapperTestEnvironment(root: root,
                                           fakeHome: fakeHome,
                                           fakeBin: fakeBin,
                                           registryRoot: registryRoot,
                                           rolloutStateFile: rolloutStateFile.path,
                                           initialRolloutPath: initialRolloutPath,
                                           nextRolloutPath: nextRolloutPath,
                                           socketPath: socketPath)
    }

    private func launchCodexWrapper(environment: CodexWrapperTestEnvironment) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/Users/timfeng/GitHub/Tidey/Resources/bin/codex")
        var env = ProcessInfo.processInfo.environment
        env["HOME"] = environment.fakeHome.path
        env["PATH"] = "\(environment.fakeBin.path):/usr/bin:/bin"
        env["TIDEY_SOCKET_PATH"] = environment.socketPath
        env["TIDEY_WORKSPACE_ID"] = "ws-test"
        env["TIDEY_PANEL_ID"] = "panel-test"
        env["FAKE_CODEX_CHILD_PID"] = "99999"
        env["FAKE_ROLLOUT_STATE_FILE"] = environment.rolloutStateFile
        if let nextRolloutPath = environment.nextRolloutPath {
            env["FAKE_NEXT_ROLLOUT_PATH"] = nextRolloutPath
        }
        process.environment = env
        try process.run()
        return process
    }

    private func waitForRegistryJSON(at url: URL, timeout: TimeInterval = 3.0) throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let data = try? Data(contentsOf: url),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return object
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        XCTFail("Timed out waiting for registry at \(url.path)")
        return [:]
    }

    private func terminate(_ process: Process) {
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
    }

    private func writeExecutable(at url: URL, contents: String) throws {
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
}

private struct CodexWrapperTestEnvironment {
    let root: URL
    let fakeHome: URL
    let fakeBin: URL
    let registryRoot: URL
    let rolloutStateFile: String
    let initialRolloutPath: String
    let nextRolloutPath: String?
    let socketPath: String
}

private final class UNIXSocketFile {
    private let path: String
    private var fd: Int32

    init(path: String) throws {
        self.path = path
        self.fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw POSIXError(.EIO)
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxLength = MemoryLayout.size(ofValue: addr.sun_path)
        guard path.utf8.count < maxLength else {
            Darwin.close(fd)
            throw POSIXError(.ENAMETOOLONG)
        }
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { pointer in
            path.withCString { source in
                strncpy(pointer.withMemoryRebound(to: CChar.self, capacity: maxLength) { $0 },
                        source,
                        maxLength - 1)
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            Darwin.close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        listen(fd, 1)
    }

    func close() {
        guard fd >= 0 else {
            unlink(path)
            return
        }
        Darwin.close(fd)
        fd = -1
        unlink(path)
    }

    deinit {
        close()
    }
}
