import Darwin
import Foundation

// Interim cleanup for the Claude hook dispatcher's legacy mkdir mutex
// (`claude-hooks-<session>.jsonl.seqlock`). A hook killed inside that
// critical section leaves the directory behind, and every later hook of the
// session then skips its journal write. The dispatcher in the next Tidey.app
// release uses a kernel flock that cannot go stale; remove this reaper once
// no new `.seqlock` directories appear after that release.
//
// Safety: the critical section lasts milliseconds and hooks time out after
// at most 10 s, so a lock older than `staleAge` has no live holder. The
// directory's existence is the lock, so no writer can re-acquire it while it
// exists; `rmdir(2)` also refuses non-empty directories and never follows a
// symlink.
struct ClaudeHookSeqlockReaperResult: Equatable {
    var reclaimedSessionIDs: [String] = []
    var failedSessionIDs: [String] = []
}

final class ClaudeHookSeqlockReaper {
    static let defaultStaleAge: TimeInterval = 30
    static let defaultSweepInterval: TimeInterval = 30

    private static let lockNamePrefix = "claude-hooks-"
    private static let lockNameSuffix = ".jsonl.seqlock"

    private let directory: URL
    private let staleAge: TimeInterval
    private let sweepInterval: TimeInterval
    private let now: () -> Date
    private let queue: DispatchQueue
    private var timer: DispatchSourceTimer?

    init(directory: URL,
         staleAge: TimeInterval = ClaudeHookSeqlockReaper.defaultStaleAge,
         sweepInterval: TimeInterval = ClaudeHookSeqlockReaper.defaultSweepInterval,
         now: @escaping () -> Date = Date.init,
         queue: DispatchQueue = DispatchQueue(label: "com.tidey.remote-bridge.claude-hook-seqlock-reaper")) {
        self.directory = directory
        self.staleAge = staleAge
        self.sweepInterval = sweepInterval
        self.now = now
        self.queue = queue
    }

    func start() {
        queue.async { [weak self] in
            guard let self, self.timer == nil else {
                return
            }
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: self.sweepInterval)
            timer.setEventHandler { [weak self] in
                self?.sweep()
            }
            self.timer = timer
            timer.resume()
        }
    }

    func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
        }
    }

    @discardableResult
    func sweep() -> ClaudeHookSeqlockReaperResult {
        var result = ClaudeHookSeqlockReaperResult()
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
            return result
        }
        let cutoff = now().timeIntervalSince1970 - staleAge
        for name in entries.sorted() {
            guard let sessionID = Self.sessionID(forLockName: name) else {
                continue
            }
            let path = directory.appendingPathComponent(name, isDirectory: false).path
            var metadata = stat()
            guard lstat(path, &metadata) == 0,
                  (metadata.st_mode & S_IFMT) == S_IFDIR else {
                continue
            }
            let modifiedAt = TimeInterval(metadata.st_mtimespec.tv_sec)
                + TimeInterval(metadata.st_mtimespec.tv_nsec) / 1_000_000_000
            guard modifiedAt < cutoff else {
                continue
            }
            let age = Int(now().timeIntervalSince1970 - modifiedAt)
            if rmdir(path) == 0 {
                result.reclaimedSessionIDs.append(sessionID)
                BridgeLogger.hookJournal.notice("seqlock reclaimed session=\(sessionID, privacy: .public) age_s=\(age)")
            } else {
                let code = errno
                result.failedSessionIDs.append(sessionID)
                BridgeLogger.hookJournal.error("seqlock reclaim failed session=\(sessionID, privacy: .public) age_s=\(age) errno=\(code)")
            }
        }
        return result
    }

    /// `claude-hooks-<uuid>.jsonl.seqlock` → `<uuid>`; nil for anything else.
    static func sessionID(forLockName name: String) -> String? {
        guard name.hasPrefix(lockNamePrefix), name.hasSuffix(lockNameSuffix) else {
            return nil
        }
        let sessionID = String(name.dropFirst(lockNamePrefix.count).dropLast(lockNameSuffix.count))
        guard sessionID.count == 36, UUID(uuidString: sessionID) != nil else {
            return nil
        }
        return sessionID
    }
}
