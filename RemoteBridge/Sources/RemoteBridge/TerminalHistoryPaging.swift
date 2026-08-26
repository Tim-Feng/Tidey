import CryptoKit
import Foundation

struct TerminalHistoryAnchorV1: Equatable, Sendable {
    let offset: Int
    let sha16: String
    let attachHistorySize: Int?

    init(
        offset: Int,
        sha16: String,
        attachHistorySize: Int? = nil
    ) {
        self.offset = offset
        self.sha16 = sha16
        self.attachHistorySize = attachHistorySize
    }
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

struct OrdinaryTmuxHistoryPage: Equatable, Sendable {
    let route: OrdinaryTmuxPanelRoute
    let evaluation: OrdinaryTmuxHistoryPageEvaluation
}

protocol OrdinaryTmuxHistoryPageServing: Sendable {
    func page(
        route: OrdinaryTmuxPanelRoute,
        offset: Int,
        pageLines: Int,
        anchor: TerminalHistoryAnchorV1?
    ) throws -> OrdinaryTmuxHistoryPage
}

enum OrdinaryTmuxHistoryPagePolicy {
    static let maximumPageLines = 500

    static func capturePlan(
        offset: Int,
        pageLines: Int,
        anchor: TerminalHistoryAnchorV1?,
        currentHistorySize: Int? = nil,
        paneID: String
    ) throws -> OrdinaryTmuxHistoryCapturePlan {
        guard offset >= 0,
              (1...maximumPageLines).contains(pageLines),
              paneID.hasPrefix("%"),
              paneID.count > 1,
              (anchor == nil ? offset == 0 : anchor?.offset == offset),
              anchor?.attachHistorySize.map({ $0 >= 0 }) ?? true else {
            throw BridgeInternalError.invalidResponse
        }

        let attachDisplacement: Int
        if let attachHistorySize = anchor?.attachHistorySize {
            guard let currentHistorySize,
                  currentHistorySize >= attachHistorySize else {
                throw BridgeInternalError.invalidResponse
            }
            attachDisplacement = currentHistorySize - attachHistorySize
        } else {
            attachDisplacement = 0
        }
        let captureOffset = offset + attachDisplacement
        let start = -(captureOffset + pageLines)
        let end = anchor == nil ? -1 : -captureOffset
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
                sha16: sha16(first),
                attachHistorySize: plan.anchor?.attachHistorySize
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

    static func invalidated(
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

    static func invalidated(offset: Int) -> OrdinaryTmuxHistoryPageEvaluation {
        OrdinaryTmuxHistoryPageEvaluation(
            rows: [],
            nextOffset: offset,
            anchor: nil,
            invalidated: true,
            oldestReached: false
        )
    }
}

struct TerminalHistoryPageActionHandler {
    private let routeResolver: OrdinaryTmuxRouteResolving
    private let tmuxPageServer: any OrdinaryTmuxHistoryPageServing

    init(
        routeResolver: OrdinaryTmuxRouteResolving,
        tmuxPageServer: any OrdinaryTmuxHistoryPageServing = OrdinaryTmuxCLIAdapter()
    ) {
        self.routeResolver = routeResolver
        self.tmuxPageServer = tmuxPageServer
    }

    func handle(_ request: BridgeRequest) throws -> BridgeResponse? {
        guard request.action == "get_terminal_history_page" else {
            return nil
        }
        guard request.params?["source"]?.stringValue == "tmux" else {
            return nil
        }
        guard let workspaceID = request.params?["workspace_id"]?.stringValue,
              workspaceID.isEmpty == false,
              let panelID = request.params?["panel_id"]?.stringValue,
              panelID.hasPrefix("\(OrdinaryTmuxLogicalPanelID.prefix):"),
              let routeGeneration = request.params?["route_generation"]?.intValue,
              routeGeneration >= 0,
              let pageLines = request.params?["page_lines"]?.intValue,
              (1...OrdinaryTmuxHistoryPagePolicy.maximumPageLines).contains(pageLines),
              let cursor = request.params?["cursor"]?.objectValue,
              let offset = cursor["offset"]?.intValue,
              offset >= 0 else {
            throw BridgeInternalError.invalidRequest(
                "tmux terminal history paging requires workspace_id, panel_id, route_generation, page_lines, and cursor"
            )
        }
        let anchor = try Self.decodeAnchor(cursor["anchor"], expectedOffset: offset)
        guard let route = try routeResolver.route(
            forPanelID: panelID,
            workspaceID: workspaceID
        ) else {
            throw BridgeInternalError.notFound(
                "ordinary tmux logical panel is not authorized"
            )
        }
        let page = try tmuxPageServer.page(
            route: route,
            offset: offset,
            pageLines: pageLines,
            anchor: anchor
        )
        let evaluation = page.evaluation
        let nextAnchor: JSONValue = evaluation.anchor.map {
            var fields: [String: JSONValue] = [
                "offset": .number(Double($0.offset)),
                "sha16": .string($0.sha16),
            ]
            if let attachHistorySize = $0.attachHistorySize {
                fields["attach_history_size"] = .number(Double(attachHistorySize))
            }
            return .object(fields)
        } ?? .null
        return BridgeResponse(
            id: request.id,
            ok: true,
            result: [
                "source": .string("tmux"),
                "workspace_id": .string(page.route.workspaceID),
                "panel_id": .string(page.route.panelID),
                "route_generation": .number(Double(routeGeneration)),
                "rows": .array(evaluation.rows.map {
                    .string($0.base64EncodedString())
                }),
                "cursor": .object([
                    "offset": .number(Double(evaluation.nextOffset)),
                    "anchor": nextAnchor,
                ]),
                "invalidated": .bool(evaluation.invalidated),
                "oldest_reached": .bool(evaluation.oldestReached),
            ],
            error: nil
        )
    }

    private static func decodeAnchor(
        _ value: JSONValue?,
        expectedOffset: Int
    ) throws -> TerminalHistoryAnchorV1? {
        guard let value, value != .null else {
            guard expectedOffset == 0 else {
                throw BridgeInternalError.invalidRequest(
                    "tmux terminal history cursor requires an anchor after the first page"
                )
            }
            return nil
        }
        guard let object = value.objectValue,
              let offset = object["offset"]?.intValue,
              offset == expectedOffset,
              let sha16 = object["sha16"]?.stringValue,
              sha16.utf8.count == 16,
              sha16.utf8.allSatisfy({ byte in
                  (48...57).contains(byte) || (97...102).contains(byte)
              }) else {
            throw BridgeInternalError.invalidRequest(
                "tmux terminal history cursor anchor is invalid"
            )
        }
        let attachHistorySize: Int?
        if let value = object["attach_history_size"] {
            guard let decoded = value.intValue,
                  decoded >= 0 else {
                throw BridgeInternalError.invalidRequest(
                    "tmux terminal history cursor attach boundary is invalid"
                )
            }
            attachHistorySize = decoded
        } else {
            attachHistorySize = nil
        }
        return TerminalHistoryAnchorV1(
            offset: offset,
            sha16: sha16,
            attachHistorySize: attachHistorySize
        )
    }
}
