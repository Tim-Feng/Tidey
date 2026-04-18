//
//  PathTests.swift
//  iTerm2
//
//  Created by George Nachman on 2/4/26.
//

import XCTest
@testable import iTerm2SharedARC
import Darwin
import ObjectiveC.runtime

/// Tests for path methods to verify correct behavior with and without custom suite names.
/// These tests establish baseline behavior and verify no regressions when --suite is not used.
final class PathTests: XCTestCase {

    private func objectiveCCharacterSet(named selectorName: String) -> CharacterSet {
        let selector = NSSelectorFromString(selectorName)
        guard let method = class_getClassMethod(NSCharacterSet.self, selector) else {
            XCTFail("Missing NSCharacterSet.\(selectorName)")
            return CharacterSet()
        }
        typealias Function = @convention(c) (AnyClass, Selector) -> AnyObject
        let implementation = method_getImplementation(method)
        let function = unsafeBitCast(implementation, to: Function.self)
        return function(NSCharacterSet.self, selector) as? CharacterSet ?? CharacterSet()
    }

    private func semanticHistoryRouteShouldOpen(_ url: URL) -> Bool {
        let controller = iTermSemanticHistoryController()
        controller.prefs = [:]
        let allocSelector = NSSelectorFromString("alloc")
        guard let allocMethod = class_getClassMethod(iTermURLActionHelper.self, allocSelector) else {
            XCTFail("Missing iTermURLActionHelper alloc")
            return false
        }
        typealias AllocFunction = @convention(c) (AnyClass, Selector) -> AnyObject
        let allocImplementation = method_getImplementation(allocMethod)
        let allocate = unsafeBitCast(allocImplementation, to: AllocFunction.self)
        let uninitializedHelper = allocate(iTermURLActionHelper.self, allocSelector)

        let selector = NSSelectorFromString("initWithSemanticHistoryController:")
        guard let method = class_getInstanceMethod(iTermURLActionHelper.self, selector) else {
            XCTFail("Missing iTermURLActionHelper initializer")
            return false
        }
        typealias InitFunction = @convention(c) (AnyObject, Selector, iTermSemanticHistoryController) -> AnyObject
        let implementation = method_getImplementation(method)
        let function = unsafeBitCast(implementation, to: InitFunction.self)
        let helper = function(uninitializedHelper, selector, controller)

        let shouldOpenSelector = NSSelectorFromString("shouldOpenFileURLWithSemanticHistory:")
        guard let shouldOpenMethod = class_getInstanceMethod(iTermURLActionHelper.self, shouldOpenSelector) else {
            XCTFail("Missing semantic history routing helper")
            return false
        }
        typealias ShouldOpenFunction = @convention(c) (AnyObject, Selector, NSURL) -> ObjCBool
        let shouldOpenImplementation = method_getImplementation(shouldOpenMethod)
        let shouldOpen = unsafeBitCast(shouldOpenImplementation, to: ShouldOpenFunction.self)
        return shouldOpen(helper, shouldOpenSelector, url as NSURL).boolValue
    }

    private func resolvedPath(prefix: String,
                              suffix: String,
                              workingDirectory: String,
                              trimWhitespace: Bool = false,
                              ignore: String = "",
                              allowNetworkMounts: Bool = false) -> String? {
        guard let pathFinderClass = NSClassFromString("iTermPathFinder") as? NSObject.Type else {
            XCTFail("Missing iTermPathFinder")
            return nil
        }
        let allocSelector = NSSelectorFromString("alloc")
        guard let allocMethod = class_getClassMethod(pathFinderClass, allocSelector) else {
            XCTFail("Missing iTermPathFinder alloc")
            return nil
        }
        typealias AllocFunction = @convention(c) (AnyClass, Selector) -> AnyObject
        let allocImplementation = method_getImplementation(allocMethod)
        let allocate = unsafeBitCast(allocImplementation, to: AllocFunction.self)
        let uninitializedFinder = allocate(pathFinderClass, allocSelector)

        let initSelector = NSSelectorFromString("initWithPrefix:suffix:workingDirectory:trimWhitespace:ignore:allowNetworkMounts:")
        guard let initMethod = class_getInstanceMethod(pathFinderClass, initSelector) else {
            XCTFail("Missing iTermPathFinder initializer")
            return nil
        }
        typealias InitFunction = @convention(c) (AnyObject, Selector, NSString, NSString, NSString, Bool, NSString, Bool) -> AnyObject
        let initImplementation = method_getImplementation(initMethod)
        let initialize = unsafeBitCast(initImplementation, to: InitFunction.self)
        let finder = initialize(uninitializedFinder,
                                initSelector,
                                prefix as NSString,
                                suffix as NSString,
                                workingDirectory as NSString,
                                trimWhitespace,
                                ignore as NSString,
                                allowNetworkMounts)

        let searchSelector = NSSelectorFromString("searchSynchronously")
        guard let searchMethod = class_getInstanceMethod(pathFinderClass, searchSelector) else {
            XCTFail("Missing iTermPathFinder search")
            return nil
        }
        typealias SearchFunction = @convention(c) (AnyObject, Selector) -> Void
        let searchImplementation = method_getImplementation(searchMethod)
        let search = unsafeBitCast(searchImplementation, to: SearchFunction.self)
        search(finder, searchSelector)

        return finder.value(forKey: "path") as? String
    }

    private func tideyPanelOrderState(visibleTabs: [NSObject],
                                      workspacePanels: [NSObject],
                                      currentTab: NSObject?,
                                      fallbackSelection: Int) -> [String: Any] {
        let selector = NSSelectorFromString("tideyPanelOrderStateByApplyingVisibleTabOrder:toWorkspacePanels:currentTab:fallbackSelection:")
        guard let method = class_getClassMethod(PseudoTerminal.self, selector) else {
            XCTFail("Missing PseudoTerminal reorder helper")
            return [:]
        }
        typealias Function = @convention(c) (AnyClass, Selector, NSArray, NSArray, AnyObject?, NSNumber) -> NSDictionary
        let implementation = method_getImplementation(method)
        let function = unsafeBitCast(implementation, to: Function.self)
        return function(PseudoTerminal.self,
                        selector,
                        visibleTabs as NSArray,
                        workspacePanels as NSArray,
                        currentTab,
                        NSNumber(value: fallbackSelection)) as? [String: Any] ?? [:]
    }

    private func tideyShouldInsertPanelIntoVisibleTabView(selectedWorkspaceIndex: Int,
                                                          targetWorkspaceIndex: Int,
                                                          createWorkspace: Bool,
                                                          showingSidebar: Bool,
                                                          switchingWorkspace: Bool) -> Bool {
        let selector = NSSelectorFromString("tideyShouldInsertPanelIntoVisibleTabViewForSelectedWorkspaceIndex:targetWorkspaceIndex:createWorkspace:showingSidebar:switchingWorkspace:")
        guard let method = class_getClassMethod(PseudoTerminal.self, selector) else {
            XCTFail("Missing PseudoTerminal visible insertion helper")
            return true
        }
        typealias Function = @convention(c) (AnyClass, Selector, Int, Int, ObjCBool, ObjCBool, ObjCBool) -> ObjCBool
        let implementation = method_getImplementation(method)
        let function = unsafeBitCast(implementation, to: Function.self)
        return function(PseudoTerminal.self,
                        selector,
                        selectedWorkspaceIndex,
                        targetWorkspaceIndex,
                        ObjCBool(createWorkspace),
                        ObjCBool(showingSidebar),
                        ObjCBool(switchingWorkspace)).boolValue
    }

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
        let extracted = source.substring(includingOffset: Int32(offset),
                                         from: objectiveCCharacterSet(named: "filenameCharacterSet"),
                                         charsTakenFromPrefix: nil)

        XCTAssertEqual(extracted, "~/.claude/skills/skill-creator/SKILL.md")
    }

    func testURLCharacterSetStopsAtFullWidthParentheticalSuffix() {
        let source = "https://example.com/docs/shared-resource-patterns.md（2845 bytes，新）" as NSString
        let offset = source.range(of: "patterns.md").location + "patterns.md".count - 1
        let extracted = source.substring(includingOffset: Int32(offset),
                                         from: objectiveCCharacterSet(named: "urlCharacterSet"),
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
        XCTAssertEqual(resolvedPath(prefix: relativePath,
                                    suffix: "（2845 bytes，新）",
                                    workingDirectory: NSHomeDirectory()),
                       fileURL.path)
    }

    func testFileURLWithoutFragmentUsesSemanticHistoryRoute() {
        let url = URL(fileURLWithPath: "/Users/timfeng/GitHub/life-system/TODO.md")

        XCTAssertTrue(semanticHistoryRouteShouldOpen(url))
    }

    func testFileURLWithFragmentUsesSemanticHistoryRoute() {
        let url = URL(string: "file:///Users/timfeng/GitHub/life-system/TODO.md#12:3")!

        XCTAssertTrue(semanticHistoryRouteShouldOpen(url))
    }

    func testNonFileURLsDoNotUseSemanticHistoryRoute() {
        XCTAssertFalse(semanticHistoryRouteShouldOpen(URL(string: "https://example.com/path")!))
        XCTAssertFalse(semanticHistoryRouteShouldOpen(URL(string: "iterm2://open?foo=bar")!))
    }

    func testFileURLsWithoutPathsDoNotUseSemanticHistoryRoute() {
        XCTAssertFalse(semanticHistoryRouteShouldOpen(URL(string: "file://")!))
        XCTAssertFalse(semanticHistoryRouteShouldOpen(URL(string: "file:///")!))
    }

    func testWorkspacePanelsFollowVisibleTabOrderAfterReorder() {
        let panelA = NSObject()
        let panelB = NSObject()
        let panelC = NSObject()

        let state = tideyPanelOrderState(visibleTabs: [panelB, panelA, panelC],
                                         workspacePanels: [panelA, panelB, panelC],
                                         currentTab: panelB,
                                         fallbackSelection: 1)

        let orderedPanels = state["panels"] as? [NSObject]
        let selectedPanelIndex = state["selectedPanelIndex"] as? NSNumber
        XCTAssertEqual(orderedPanels ?? [], [panelB, panelA, panelC])
        XCTAssertEqual(selectedPanelIndex?.intValue, 0)
    }

    func testWorkspacePanelSelectionFollowsCurrentTabAfterReorder() {
        let panelA = NSObject()
        let panelB = NSObject()
        let panelC = NSObject()

        let state = tideyPanelOrderState(visibleTabs: [panelB, panelA, panelC],
                                         workspacePanels: [panelA, panelB, panelC],
                                         currentTab: panelA,
                                         fallbackSelection: 0)

        let selectedPanelIndex = state["selectedPanelIndex"] as? NSNumber
        XCTAssertEqual(selectedPanelIndex?.intValue, 1)
    }

    func testWorkspacePanelOrderRemainsStableAcrossMultipleReorders() {
        let panelA = NSObject()
        let panelB = NSObject()
        let panelC = NSObject()

        let firstState = tideyPanelOrderState(visibleTabs: [panelB, panelA, panelC],
                                              workspacePanels: [panelA, panelB, panelC],
                                              currentTab: panelB,
                                              fallbackSelection: 1)
        let secondState = tideyPanelOrderState(visibleTabs: [panelC, panelB, panelA],
                                               workspacePanels: firstState["panels"] as? [NSObject] ?? [],
                                               currentTab: panelC,
                                               fallbackSelection: (firstState["selectedPanelIndex"] as? NSNumber)?.intValue ?? 0)

        let orderedPanels = secondState["panels"] as? [NSObject]
        let selectedPanelIndex = secondState["selectedPanelIndex"] as? NSNumber
        XCTAssertEqual(orderedPanels ?? [], [panelC, panelB, panelA])
        XCTAssertEqual(selectedPanelIndex?.intValue, 0)
    }

    func testBackgroundWorkspacePanelInsertionDoesNotUseVisibleTabView() {
        XCTAssertFalse(tideyShouldInsertPanelIntoVisibleTabView(selectedWorkspaceIndex: 1,
                                                                targetWorkspaceIndex: 0,
                                                                createWorkspace: false,
                                                                showingSidebar: true,
                                                                switchingWorkspace: false))
    }

    func testCurrentWorkspacePanelInsertionUsesVisibleTabView() {
        XCTAssertTrue(tideyShouldInsertPanelIntoVisibleTabView(selectedWorkspaceIndex: 1,
                                                               targetWorkspaceIndex: 1,
                                                               createWorkspace: false,
                                                               showingSidebar: true,
                                                               switchingWorkspace: false))
    }

    func testNewWorkspacePanelInsertionDoesNotUseVisibleTabView() {
        XCTAssertFalse(tideyShouldInsertPanelIntoVisibleTabView(selectedWorkspaceIndex: 1,
                                                                targetWorkspaceIndex: 2,
                                                                createWorkspace: true,
                                                                showingSidebar: true,
                                                                switchingWorkspace: false))
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
