import Darwin
import XCTest
@testable import RemoteBridge

final class ClaudeHookSeqlockReaperTests: XCTestCase {
    private var directory: URL!
    private var now: Date!
    private let sessionID = "28fa5a1e-1696-4784-b2aa-dcf26342389f"

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeHookSeqlockReaperTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        now = Date()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeReaper() -> ClaudeHookSeqlockReaper {
        ClaudeHookSeqlockReaper(directory: directory, now: { [unowned self] in self.now })
    }

    @discardableResult
    private func makeLock(named name: String, age: TimeInterval) throws -> URL {
        let url = directory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        try setModified(url, age: age)
        return url
    }

    private func setModified(_ url: URL, age: TimeInterval) throws {
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-age)],
                                              ofItemAtPath: url.path)
    }

    private func lockName(_ session: String) -> String {
        "claude-hooks-\(session).jsonl.seqlock"
    }

    func testReclaimsAnEmptyLockOlderThanThirtySeconds() throws {
        let lock = try makeLock(named: lockName(sessionID), age: 31)
        let result = makeReaper().sweep()
        XCTAssertEqual(result.reclaimedSessionIDs, [sessionID])
        XCTAssertFalse(FileManager.default.fileExists(atPath: lock.path))
    }

    func testKeepsARecentLock() throws {
        let lock = try makeLock(named: lockName(sessionID), age: 10)
        let result = makeReaper().sweep()
        XCTAssertEqual(result, ClaudeHookSeqlockReaperResult())
        XCTAssertTrue(FileManager.default.fileExists(atPath: lock.path))
    }

    func testDoesNotRemoveANonEmptyDirectory() throws {
        let lock = try makeLock(named: lockName(sessionID), age: 60)
        try "x".write(to: lock.appendingPathComponent("owner"), atomically: true, encoding: .utf8)
        try setModified(lock, age: 60)
        let result = makeReaper().sweep()
        XCTAssertEqual(result.reclaimedSessionIDs, [])
        XCTAssertEqual(result.failedSessionIDs, [sessionID])
        XCTAssertTrue(FileManager.default.fileExists(atPath: lock.appendingPathComponent("owner").path))
    }

    func testIgnoresNamesThatAreNotClaudeHookJournalLocks() throws {
        let others = [
            "claude-hooks-not-a-uuid.jsonl.seqlock",
            "codex-hooks-\(sessionID).jsonl.seqlock",
            "claude-hooks-\(sessionID).jsonl.lock",
            ".claude-hook-epoch.lock",
        ]
        for name in others {
            try makeLock(named: name, age: 600)
        }
        XCTAssertEqual(makeReaper().sweep(), ClaudeHookSeqlockReaperResult())
        for name in others {
            XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path))
        }
    }

    func testIgnoresSymlinksAndRegularFilesWithALockName() throws {
        let target = try makeLock(named: "elsewhere", age: 600)
        let symlink = directory.appendingPathComponent(lockName(sessionID))
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: target)
        let otherSession = "6657e680-2cb6-4b28-8144-fee8b08ec361"
        let file = directory.appendingPathComponent(lockName(otherSession))
        try "".write(to: file, atomically: true, encoding: .utf8)
        try setModified(file, age: 600)

        XCTAssertEqual(makeReaper().sweep(), ClaudeHookSeqlockReaperResult())
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
        XCTAssertNotNil(try? FileManager.default.destinationOfSymbolicLink(atPath: symlink.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    /// The mkdir-lock write loop shipped in the current Tidey.app
    /// (`append_journal_line` before the flock change), verbatim: a stale
    /// `.seqlock` makes it skip the journal write; after one reaper sweep the
    /// same loop writes again.
    private static let shippedMkdirLockAppend = #"""
    journal="$1"; line='{"seq":__SEQ__}'
    seq_file="$journal.seq"; lock_dir="$journal.seqlock"
    for attempt in $(seq 1 60); do
        if mkdir "$lock_dir" 2>/dev/null; then
            seq="$(cat "$seq_file" 2>/dev/null || echo 0)"
            case "$seq" in (*[!0-9]*|'') seq=0 ;; esac
            seq=$((seq + 1))
            printf '%s\n' "${line/__SEQ__/$seq}" >> "$journal" 2>/dev/null || true
            printf '%s' "$seq" > "$seq_file" 2>/dev/null || true
            rmdir "$lock_dir" 2>/dev/null || true
            exit 0
        fi
        sleep 0.005
    done
    exit 1
    """#

    func testShippedMkdirLockWriterWritesAgainAfterASweep() throws {
        let journal = directory.appendingPathComponent("claude-hooks-\(sessionID).jsonl")
        func append() throws -> Int32 {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = ["-c", Self.shippedMkdirLockAppend, "append", journal.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        }
        func lineCount() -> Int {
            ((try? String(contentsOf: journal, encoding: .utf8)) ?? "").split(separator: "\n").count
        }

        try makeLock(named: lockName(sessionID), age: 45)
        XCTAssertEqual(try append(), 1)
        XCTAssertEqual(lineCount(), 0, "control: a stale lock blocks the shipped writer")

        XCTAssertEqual(makeReaper().sweep().reclaimedSessionIDs, [sessionID])
        XCTAssertEqual(try append(), 0)
        XCTAssertEqual(lineCount(), 1)
    }
}
