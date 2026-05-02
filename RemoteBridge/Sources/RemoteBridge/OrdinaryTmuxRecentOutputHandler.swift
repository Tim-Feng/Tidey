import Foundation

struct OrdinaryTmuxRecentOutputHandler {
    private let routeResolver: OrdinaryTmuxRouteResolving
    private let adapter: OrdinaryTmuxRouteRefreshing

    init(routeResolver: OrdinaryTmuxRouteResolving,
         adapter: OrdinaryTmuxRouteRefreshing = OrdinaryTmuxCLIAdapter()) {
        self.routeResolver = routeResolver
        self.adapter = adapter
    }

    func handle(_ request: BridgeRequest) throws -> BridgeResponse? {
        guard request.action == "get_recent_output",
              let panelID = request.params?["panel_id"]?.stringValue,
              panelID.hasPrefix("\(OrdinaryTmuxLogicalPanelID.prefix):") else {
            return nil
        }

        guard let route = try routeResolver.route(forPanelID: panelID, workspaceID: nil) else {
            throw BridgeInternalError.notFound("ordinary tmux logical panel is not authorized")
        }

        let maxLines = max(0, request.params?["max_lines"]?.intValue ?? 200)
        let captured = try adapter.captureOutput(route: route, maxLines: maxLines)
        return BridgeResponse(id: request.id,
                              ok: true,
                              result: [
                                "output": .string(captured.output),
                                "cursor_row": captured.cursorRow.map { .number(Double($0)) } ?? .null,
                                "cursor_col": captured.cursorColumn.map { .number(Double($0)) } ?? .null,
                                "panel_id": .string(route.panelID),
                                "workspace_id": .string(route.workspaceID),
                              ],
                              error: nil)
    }
}
