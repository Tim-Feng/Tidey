import Foundation

enum OrdinaryTmuxControlModeEvent: Equatable, Sendable {
    case layoutChanged(windowID: String)
    case subscriptionChanged(
        name: String,
        sessionID: String,
        windowID: String,
        paneID: String,
        value: String
    )
    case windowPaneChanged(windowID: String, paneID: String)
    case observerExited
    case observerUnhealthy
}

final class OrdinaryTmuxControlModeEventParser {
    private static let maximumLineBytes = 64 * 1024

    private var buffer = Data()
    private var commandBlockIdentity: [String]?
    private var isFailed = false

    func feed(_ data: Data) -> [OrdinaryTmuxControlModeEvent] {
        guard isFailed == false else {
            return []
        }
        buffer.append(data)
        var events = [OrdinaryTmuxControlModeEvent]()

        while let newline = buffer.firstIndex(of: 0x0A) {
            var lineData = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)
            if lineData.last == 0x0D {
                lineData.removeLast()
            }
            guard lineData.count <= Self.maximumLineBytes,
                  let line = String(data: lineData, encoding: .utf8) else {
                fail(into: &events)
                break
            }
            if let event = parseLine(line) {
                events.append(event)
                if event == .observerUnhealthy {
                    isFailed = true
                    buffer.removeAll(keepingCapacity: false)
                    break
                }
            }
        }

        if buffer.count > Self.maximumLineBytes {
            fail(into: &events)
        }
        return events
    }

    private func parseLine(_ line: String) -> OrdinaryTmuxControlModeEvent? {
        let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard let kind = fields.first else {
            return nil
        }

        switch kind {
        case "%begin":
            guard fields.count == 4, commandBlockIdentity == nil else {
                return .observerUnhealthy
            }
            commandBlockIdentity = Array(fields.dropFirst())
            return nil
        case "%end":
            guard fields.count == 4,
                  commandBlockIdentity == Array(fields.dropFirst()) else {
                return .observerUnhealthy
            }
            commandBlockIdentity = nil
            return nil
        case "%error":
            commandBlockIdentity = nil
            return .observerUnhealthy
        default:
            break
        }

        guard commandBlockIdentity == nil else {
            return nil
        }

        switch kind {
        case "%layout-change":
            guard fields.count >= 2, Self.isWindowID(fields[1]) else {
                return .observerUnhealthy
            }
            return .layoutChanged(windowID: fields[1])
        case "%window-pane-changed":
            guard fields.count >= 3,
                  Self.isWindowID(fields[1]),
                  Self.isPaneID(fields[2]) else {
                return .observerUnhealthy
            }
            return .windowPaneChanged(windowID: fields[1], paneID: fields[2])
        case "%subscription-changed":
            guard fields.count >= 8,
                  Self.isSafeName(fields[1]),
                  Self.isSessionID(fields[2]),
                  Self.isWindowID(fields[3]),
                  Int(fields[4]) != nil,
                  Self.isPaneID(fields[5]),
                  let separator = fields.firstIndex(of: ":"),
                  separator >= 6,
                  separator + 1 < fields.count else {
                return .observerUnhealthy
            }
            return .subscriptionChanged(
                name: fields[1],
                sessionID: fields[2],
                windowID: fields[3],
                paneID: fields[5],
                value: fields[(separator + 1)...].joined(separator: " ")
            )
        case "%exit":
            return .observerExited
        default:
            return nil
        }
    }

    private func fail(into events: inout [OrdinaryTmuxControlModeEvent]) {
        guard isFailed == false else {
            return
        }
        isFailed = true
        commandBlockIdentity = nil
        buffer.removeAll(keepingCapacity: false)
        events.append(.observerUnhealthy)
    }

    private static func isSafeName(_ value: String) -> Bool {
        value.isEmpty == false && value.utf8.allSatisfy { byte in
            (byte >= 48 && byte <= 57) ||
                (byte >= 65 && byte <= 90) ||
                (byte >= 97 && byte <= 122) ||
                byte == 45 || byte == 95
        }
    }

    private static func isSessionID(_ value: String) -> Bool {
        isNumericID(value, prefix: "$")
    }

    private static func isWindowID(_ value: String) -> Bool {
        isNumericID(value, prefix: "@")
    }

    private static func isPaneID(_ value: String) -> Bool {
        isNumericID(value, prefix: "%")
    }

    private static func isNumericID(_ value: String, prefix: Character) -> Bool {
        value.first == prefix &&
            value.dropFirst().isEmpty == false &&
            value.dropFirst().allSatisfy(\.isNumber)
    }
}

