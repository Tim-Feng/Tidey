import XCTest

// Executes the REAL argv-classification functions
// (Resources/bin/claude-hook-argv-session-id), the same file the `claude`
// wrapper sources, so these assertions are production-path proof — not a
// reimplementation that could silently drift from the wrapper's behavior.
final class ClaudeHookArgvSessionIDTests: XCTestCase {
    private var scriptURL: URL!

    override func setUpWithError() throws {
        scriptURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // RemoteBridgeTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // RemoteBridge
            .deletingLastPathComponent()  // repo root
            .appendingPathComponent("Resources/bin/claude-hook-argv-session-id", isDirectory: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: scriptURL.path))
    }

    private func shellQuote(_ string: String) -> String {
        "'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    @discardableResult
    private func runFunction(
        _ name: String,
        args: [String],
        nounset: Bool = false
    ) throws -> (status: Int32, stdout: String) {
        let quotedArgs = args.map(shellQuote).joined(separator: " ")
        let command = "source \(shellQuote(scriptURL.path)); \(name) \(quotedArgs)"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = nounset ? ["-u", "-c", command] : ["-c", command]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    private func explicitSessionID(_ args: [String]) throws -> String? {
        let result = try runFunction("claude_hook_find_explicit_session_id", args: args)
        return result.status == 0 ? result.stdout : nil
    }

    private func isImplicitResume(_ args: [String]) throws -> Bool {
        try runFunction("claude_hook_has_implicit_resume_flag", args: args).status == 0
    }

    // `-c` / `--continue` is BOOLEAN: the following token is a prompt, never
    // a session id — the concrete production bug this fixes.
    func testContinueNeverConsumesFollowingTokenAsSessionID() throws {
        XCTAssertNil(try explicitSessionID(["-c", "fix the bug please"]))
        XCTAssertTrue(try isImplicitResume(["-c", "fix the bug please"]))
        XCTAssertNil(try explicitSessionID(["--continue", "write more tests"]))
        XCTAssertTrue(try isImplicitResume(["--continue", "write more tests"]))
    }

    // `-r`/`--resume` with a NON-UUID value is a picker search term, not a
    // trustworthy id.
    func testResumeWithNonUUIDValueIsTreatedAsSearchTermNotID() throws {
        XCTAssertNil(try explicitSessionID(["-r", "yesterday's refactor"]))
        XCTAssertTrue(try isImplicitResume(["-r", "yesterday's refactor"]))
        XCTAssertNil(try explicitSessionID(["--resume", "auth-fix"]))
        XCTAssertTrue(try isImplicitResume(["--resume", "auth-fix"]))
    }

    // `-r`/`--resume` with an ACTUAL UUID is trustworthy.
    func testResumeWithUUIDValueIsTrustedAsExplicitID() throws {
        let uuid = "1E4D1F2A-9B3C-4E5D-8F6A-7C8B9D0E1F2A"
        XCTAssertEqual(try explicitSessionID(["-r", uuid]), uuid)
        XCTAssertFalse(try isImplicitResume(["-r", uuid]))
        XCTAssertEqual(try explicitSessionID(["--resume=\(uuid)"]), uuid)
    }

    // Bare `--resume` (no value) and `--resume` followed by a flag: the
    // interactive picker — implicit, no trusted id.
    func testBareResumeIsInteractivePicker() throws {
        XCTAssertNil(try explicitSessionID(["--resume"]))
        XCTAssertTrue(try isImplicitResume(["--resume"]))
        XCTAssertNil(try explicitSessionID(["--resume", "--verbose"]))
        XCTAssertTrue(try isImplicitResume(["--resume", "--verbose"]))
    }

    // `--session-id` with an explicit UUID is always trusted directly.
    func testSessionIDFlagWithUUIDIsTrusted() throws {
        let uuid = "2E4D1F2A-9B3C-4E5D-8F6A-7C8B9D0E1F2B"
        XCTAssertEqual(try explicitSessionID(["--session-id", uuid, "do the thing"]), uuid)
        XCTAssertFalse(try isImplicitResume(["--session-id", uuid]))
    }

    // `--fork-session` always mints a NEW id unknowable ahead of time,
    // regardless of any --resume/--session-id also present.
    func testForkSessionIsAlwaysImplicitEvenWithExplicitResumeID() throws {
        let uuid = "3E4D1F2A-9B3C-4E5D-8F6A-7C8B9D0E1F2C"
        XCTAssertNil(try explicitSessionID(["--resume", uuid, "--fork-session"]))
        XCTAssertTrue(try isImplicitResume(["--resume", uuid, "--fork-session"]))
    }

    // No resume-related flags at all: neither explicit nor implicit — the
    // wrapper synthesizes a fresh session id itself.
    func testPlainInvocationIsNeitherExplicitNorImplicit() throws {
        XCTAssertNil(try explicitSessionID(["fix the bug"]))
        XCTAssertFalse(try isImplicitResume(["fix the bug"]))
    }

    func testZeroArgumentsIsSafeUnderNounset() throws {
        let explicit = try runFunction(
            "claude_hook_find_explicit_session_id",
            args: [],
            nounset: true
        )
        XCTAssertEqual(explicit.status, 1)
        XCTAssertEqual(explicit.stdout, "")

        let implicit = try runFunction(
            "claude_hook_has_implicit_resume_flag",
            args: [],
            nounset: true
        )
        XCTAssertEqual(implicit.status, 1)
        XCTAssertEqual(implicit.stdout, "")
    }
}
