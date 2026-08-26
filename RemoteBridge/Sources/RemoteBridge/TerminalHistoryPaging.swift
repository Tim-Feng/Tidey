import CryptoKit
import Foundation

struct TerminalHistoryAnchorV1: Equatable, Sendable {
    let offset: Int
    let sha16: String
}

struct OrdinaryTmuxHistoryCapturePlan: Equatable, Sendable {
    let offset: Int
    let pageLines: Int
    let anchor: TerminalHistoryAnchorV1?
    let arguments: [String]
}

struct OrdinaryTmuxHistoryPageEvaluation: Equatable, Sendable {
    let rows: [Data]
    let nextOffset: Int
    let anchor: TerminalHistoryAnchorV1?
    let invalidated: Bool
    let oldestReached: Bool
}

enum OrdinaryTmuxHistoryPagePolicy {
    static let maximumPageLines = 500

    static func capturePlan(
        offset: Int,
        pageLines: Int,
        anchor: TerminalHistoryAnchorV1?,
        paneID: String
    ) throws -> OrdinaryTmuxHistoryCapturePlan {
        guard offset >= 0,
              (1...maximumPageLines).contains(pageLines),
              paneID.hasPrefix("%"),
              paneID.count > 1,
              (anchor == nil ? offset == 0 : anchor?.offset == offset) else {
            throw BridgeInternalError.invalidResponse
        }

        let start = -(offset + pageLines)
        let end = anchor == nil ? -1 : -offset
        return OrdinaryTmuxHistoryCapturePlan(
            offset: offset,
            pageLines: pageLines,
            anchor: anchor,
            arguments: [
                "capture-pane", "-e", "-p",
                "-S", String(start),
                "-E", String(end),
                "-t", paneID,
            ]
        )
    }

    static func evaluate(
        rows capturedRows: [Data],
        plan: OrdinaryTmuxHistoryCapturePlan
    ) -> OrdinaryTmuxHistoryPageEvaluation {
        let maximumCapturedRows = plan.pageLines + (plan.anchor == nil ? 0 : 1)
        guard capturedRows.count <= maximumCapturedRows else {
            return invalidated(plan)
        }

        var pageRows = capturedRows
        if let expectedAnchor = plan.anchor {
            guard let overlap = pageRows.last,
                  sha16(overlap) == expectedAnchor.sha16 else {
                return invalidated(plan)
            }
            pageRows.removeLast()
        }

        let nextOffset = plan.offset + pageRows.count
        let nextAnchor: TerminalHistoryAnchorV1?
        if let first = pageRows.first {
            nextAnchor = TerminalHistoryAnchorV1(
                offset: nextOffset,
                sha16: sha16(first)
            )
        } else {
            nextAnchor = plan.anchor
        }
        return OrdinaryTmuxHistoryPageEvaluation(
            rows: pageRows,
            nextOffset: nextOffset,
            anchor: nextAnchor,
            invalidated: false,
            oldestReached: pageRows.count < plan.pageLines
        )
    }

    static func sha16(_ row: Data) -> String {
        SHA256.hash(data: row)
            .prefix(8)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func invalidated(
        _ plan: OrdinaryTmuxHistoryCapturePlan
    ) -> OrdinaryTmuxHistoryPageEvaluation {
        OrdinaryTmuxHistoryPageEvaluation(
            rows: [],
            nextOffset: plan.offset,
            anchor: nil,
            invalidated: true,
            oldestReached: false
        )
    }
}
