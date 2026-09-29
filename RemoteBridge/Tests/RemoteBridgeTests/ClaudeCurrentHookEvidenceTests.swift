import XCTest
@testable import RemoteBridge

final class ClaudeCurrentHookEvidenceTests: XCTestCase {
    let pid: Int32 = 12345
    let birth: UInt64 = 1_700_000_000_000_000_000
    let currentID = "0f06b852-713f-4669-8435-3f65f43d7777"

    private func fixture(_ body: (URL, URL, URL, String) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("claude-hooks-46efe6fd-837f-48b6-b292-35bffed9db66.epoch")
        let journal = marker.deletingPathExtension().appendingPathExtension("jsonl")
        let epoch = "\(pid)-\(birth + 25_000_000_000)"
        try Data(epoch.utf8).write(to: marker)
        try Data("171".utf8).write(to: URL(fileURLWithPath: journal.path + ".seq"))
        try event(epoch: epoch).write(to: journal)
        try body(directory, marker, journal, epoch)
    }

    private func event(epoch: String, kind: String = "session-start", newline: Bool = true) throws -> Data {
        let payload = try JSONSerialization.data(withJSONObject: ["session_id": currentID, "cwd": "/tmp"])
        let data = try JSONSerialization.data(withJSONObject: ["v": 3, "epoch": epoch, "seq": 171,
            "event": kind, "payload_b64": payload.base64EncodedString()])
        return data + (newline ? Data("\n".utf8) : Data())
    }

    func testPIDReuseAndDuplicateMarkerNeverSelectNewest() throws {
        try fixture { directory, marker, _, epoch in
            XCTAssertNotNil(ClaudeCurrentHookEvidence.read(directory: directory, pid: pid, birth: birth))
            XCTAssertNil(ClaudeCurrentHookEvidence.read(directory: directory, pid: pid, birth: birth + 26_000_000_000))
            let other = directory.appendingPathComponent("claude-hooks-other.epoch")
            try Data(epoch.utf8).write(to: other)
            XCTAssertNil(ClaudeCurrentHookEvidence.read(directory: directory, pid: pid, birth: birth))
            try Data("999-1700000000000000000".utf8).write(to: marker)
            XCTAssertNil(ClaudeCurrentHookEvidence.read(directory: directory, pid: pid, birth: birth))
        }
    }

    func testIncompleteTailSequenceMismatchAndEndedSessionFailClosed() throws {
        try fixture { directory, _, journal, epoch in
            for bad in [try event(epoch: epoch, newline: false), try event(epoch: epoch, kind: "session-end"), Data("malformed\n".utf8)] {
                try bad.write(to: journal)
                XCTAssertNil(ClaudeCurrentHookEvidence.read(directory: directory, pid: pid, birth: birth))
            }
            try event(epoch: epoch).write(to: journal)
            try Data("172".utf8).write(to: URL(fileURLWithPath: journal.path + ".seq"))
            XCTAssertNil(ClaudeCurrentHookEvidence.read(directory: directory, pid: pid, birth: birth))
        }
    }

    func testMarkerJournalAndCounterMutationDuringReadFailClosed() throws {
        for field in ["marker", "journal", "counter", "second-owner"] {
            try fixture { directory, marker, journal, epoch in
                let other = directory.appendingPathComponent("claude-hooks-other.epoch")
                try Data("999-1700000000000000000".utf8).write(to: other)
                let value = ClaudeCurrentHookEvidence.read(directory: directory, pid: pid, birth: birth) {
                    switch field {
                    case "marker": try! Data("999-1700000000000000000".utf8).write(to: marker)
                    case "journal": try! Data("{}\n".utf8).write(to: journal)
                    case "counter": try! Data("172".utf8).write(to: URL(fileURLWithPath: journal.path + ".seq"))
                    default: try! Data(epoch.utf8).write(to: other)
                    }
                }
                XCTAssertNil(value, field)
            }
        }
    }

    func testRecordCreatedBeforeCurrentProcessIsNotItsAlias() {
        XCTAssertFalse(ClaudeCurrentHookEvidence.createdDuringProcess("2023-11-14T22:13:19Z", birth: birth))
        XCTAssertTrue(ClaudeCurrentHookEvidence.createdDuringProcess("2023-11-14T22:13:21Z", birth: birth))
        XCTAssertFalse(ClaudeCurrentHookEvidence.createdDuringProcess("unknown", birth: birth))
        XCTAssertNil(ClaudeCurrentHookEvidence.processBirthNanoseconds(0))
    }
}
