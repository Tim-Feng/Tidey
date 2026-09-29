import Darwin
import Foundation

/// Read-only evidence for a historical UUID alias left by the same live wrapper.
/// No transcript history search, registry cleanup, or newest-timestamp selection.
struct ClaudeCurrentHookEvidence {
    let sessionID: String
    let cwd: String
    let epoch: String

    static func processBirthNanoseconds(_ pid: Int32) -> UInt64? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard pid > 0, proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
              info.pbi_pid == UInt32(pid), info.pbi_start_tvsec > 0 else { return nil }
        let (seconds, overflow) = info.pbi_start_tvsec.multipliedReportingOverflow(by: 1_000_000_000)
        let (value, fractionOverflow) = seconds.addingReportingOverflow(info.pbi_start_tvusec * 1_000)
        return overflow || fractionOverflow ? nil : value
    }

    static func createdDuringProcess(_ timestamp: String, birth: UInt64) -> Bool {
        let formatter = ISO8601DateFormatter()
        var date = formatter.date(from: timestamp)
        if date == nil {
            formatter.formatOptions.insert(.withFractionalSeconds)
            date = formatter.date(from: timestamp)
        }
        guard let seconds = date?.timeIntervalSince1970, seconds.isFinite, seconds > 0 else { return false }
        // created_at is second-resolution in old wrappers. Never round a process
        // birth down to make an older, potentially reused-PID record acceptable.
        return seconds >= Double(birth) / 1_000_000_000
    }

    private struct Stamp: Equatable {
        let inode: UInt64
        let size: UInt64
        let modified: Date
    }
    private static func stamp(_ url: URL) throws -> Stamp {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attrs[.type] as? FileAttributeType == .typeRegular,
              let inode = (attrs[.systemFileNumber] as? NSNumber)?.uint64Value,
              let size = (attrs[.size] as? NSNumber)?.uint64Value,
              let modified = attrs[.modificationDate] as? Date else { throw EvidenceError.invalid }
        return Stamp(inode: inode, size: size, modified: modified)
    }
    private enum EvidenceError: Error { case invalid }
    private static func smallText(_ url: URL) throws -> String {
        guard try stamp(url).size <= 256 else { throw EvidenceError.invalid }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: 257) ?? Data()
        guard data.count <= 256, let text = String(data: data, encoding: .utf8) else { throw EvidenceError.invalid }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func read(directory: URL, pid: Int32, birth: UInt64,
                     beforeFence: () -> Void = {}) -> ClaudeCurrentHookEvidence? {
        do {
            let urls = try FileManager.default.contentsOfDirectory(at: directory,
                includingPropertiesForKeys: nil)
            guard urls.count <= 4096 else { return nil }
            let markers = urls.filter { $0.lastPathComponent.hasPrefix("claude-hooks-") && $0.pathExtension == "epoch" }
            var markerContents = [URL: String]()
            var owned = [(URL, String, UInt64)]()
            for marker in markers {
                let epoch = try smallText(marker)
                markerContents[marker] = epoch
                let parts = epoch.split(separator: "-", omittingEmptySubsequences: false)
                guard parts.count == 2, let owner = Int32(parts[0]), let started = UInt64(parts[1]) else { return nil }
                if owner == pid { owned.append((marker, epoch, started)) }
            }
            guard owned.count == 1, let (marker, epoch, started) = owned.first,
                  started >= birth else { return nil }
            let journal = marker.deletingPathExtension().appendingPathExtension("jsonl")
            let counter = URL(fileURLWithPath: journal.path + ".seq")
            let files = [marker, journal, counter]
            let before = try files.map(stamp)
            let markerBefore = try smallText(marker)
            let sequenceBefore = try smallText(counter)
            guard markerBefore == epoch, let sequence = Int(sequenceBefore), sequence > 0 else { return nil }
            let file = try FileHandle(forReadingFrom: journal)
            defer { try? file.close() }
            let length = before[1].size
            guard length > 0 else { return nil }
            let offset = length > 65_536 ? length - 65_536 : 0
            try file.seek(toOffset: offset)
            guard let tail = try file.read(upToCount: 65_536), tail.last == 10 else { return nil }
            var lines = tail.split(separator: 10, omittingEmptySubsequences: false)
            lines.removeLast() // final newline; an incomplete trailing event must fail closed
            if offset > 0 { lines.removeFirst() } // may begin in the middle of a record
            guard let last = lines.last, !last.isEmpty,
                  let event = try JSONSerialization.jsonObject(with: Data(last)) as? [String: Any],
                  event["v"] as? Int == 3, event["seq"] as? Int == sequence,
                  event["epoch"] as? String == epoch,
                  let kind = event["event"] as? String,
                  ["session-start", "prompt-submit", "post-tool-use", "stop", "notification-idle", "notification-permission", "permission-request"].contains(kind),
                  let encoded = event["payload_b64"] as? String, let data = Data(base64Encoded: encoded),
                  let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = payload["session_id"] as? String, UUID(uuidString: id) != nil,
                  let cwd = payload["cwd"] as? String, cwd.hasPrefix("/") else { return nil }
            beforeFence()
            guard try files.map(stamp) == before,
                  try smallText(marker) == markerBefore, try smallText(counter) == sequenceBefore else { return nil }
            // Re-list names as well: a concurrent second journal must not be hidden
            // by reading only the originally selected marker twice.
            let afterMarkers = try FileManager.default.contentsOfDirectory(at: directory,
                includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("claude-hooks-") && $0.pathExtension == "epoch" }
            guard Set(afterMarkers) == Set(markers),
                  try afterMarkers.allSatisfy({ try smallText($0) == markerContents[$0] }) else { return nil }
            return .init(sessionID: id, cwd: cwd, epoch: epoch)
        } catch { return nil }
    }
}
