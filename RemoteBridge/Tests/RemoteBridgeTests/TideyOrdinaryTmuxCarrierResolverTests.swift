import XCTest
@testable import RemoteBridge

final class TideyOrdinaryTmuxCarrierResolverTests: XCTestCase {
    func testResolvesCarrierWhenTmuxCanonicalizesUniqueTargetPrefix() throws {
        let tmuxResolver = makeTmuxResolver(sessionInventory: [
            TmuxSessionIdentity(sessionID: "$8", sessionName: "storage"),
        ])
        let resolver = TideyOrdinaryTmuxCarrierResolver(
            requestSender: makeRequestSender(targetSession: "s"),
            tmuxResolver: tmuxResolver
        )

        let identity = resolver.carrierIdentity(for: makeRecord())

        XCTAssertEqual(
            identity,
            TideyOrdinaryTmuxCarrierIdentity(
                workspaceID: "storage-workspace",
                panelID: "storage-panel",
                socketPath: "/tmp/tmux-501/default",
                targetSession: "storage"
            )
        )
    }

    func testRejectsCarrierWhenTargetSessionPrefixIsAmbiguous() throws {
        let tmuxResolver = makeTmuxResolver(sessionInventory: [
            TmuxSessionIdentity(sessionID: "$8", sessionName: "storage"),
            TmuxSessionIdentity(sessionID: "$9", sessionName: "sandbox"),
        ])
        let resolver = TideyOrdinaryTmuxCarrierResolver(
            requestSender: makeRequestSender(targetSession: "s"),
            tmuxResolver: tmuxResolver
        )

        XCTAssertNil(resolver.carrierIdentity(for: makeRecord()))
    }

    private func makeTmuxResolver(sessionInventory: [TmuxSessionIdentity]) -> TmuxStateResolver {
        TmuxStateResolver(ttl: 60) { socketPath, arguments in
            XCTAssertEqual(socketPath, "/tmp/tmux-501/default")
            if arguments == ["list-panes", "-a", "-F", "#{pane_id}|#{session_name}"] {
                return "%8|storage\n"
            }
            if arguments == ["list-clients", "-F", "#{client_pid}|#{session_name}"] {
                return "123|storage\n"
            }
            if arguments == ["list-sessions", "-F", "#{session_id}|#{session_name}"] {
                return sessionInventory
                    .map { "\($0.sessionID)|\($0.sessionName)" }
                    .joined(separator: "\n")
            }
            XCTFail("Unexpected tmux arguments: \(arguments)")
            return ""
        }
    }

    private func makeRequestSender(targetSession: String) -> TideyOrdinaryTmuxCarrierResolver.RequestSender {
        { request in
            if request.action == "list_workspaces" {
                return BridgeResponse(
                    id: request.id,
                    ok: true,
                    result: [
                        "workspaces": .array([
                            .object([
                                "workspace_id": .string("storage-workspace"),
                                "ordinary_tmux": .object([
                                    "target_session": .string(targetSession),
                                ]),
                            ]),
                        ]),
                    ],
                    error: nil
                )
            }
            if request.action == "list_panels" {
                XCTAssertEqual(request.params?["workspace_id"]?.stringValue, "storage-workspace")
                return BridgeResponse(
                    id: request.id,
                    ok: true,
                    result: [
                        "workspace_id": .string("storage-workspace"),
                        "panels": .array([
                            .object([
                                "panel_id": .string("storage-panel"),
                                "workspace_id": .string("storage-workspace"),
                                "ordinary_tmux": .object([
                                    "target_session": .string(targetSession),
                                ]),
                            ]),
                        ]),
                    ],
                    error: nil
                )
            }
            XCTFail("Unexpected Tidey socket action: \(request.action)")
            return BridgeResponse(id: request.id, ok: false, result: nil, error: nil)
        }
    }

    private func makeRecord() -> AgentSessionRegistryRecord {
        AgentSessionRegistryRecord(
            version: 1,
            vendor: "codex",
            workspaceID: "stale-workspace",
            sessionID: "registry-session",
            panelID: "stale-panel",
            pid: getpid(),
            cwd: "/Users/timfeng",
            createdAt: "2026-08-07T00:00:00Z",
            transcriptPath: nil,
            tmuxPaneID: "%8",
            tmuxSocketPath: "/private/tmp/tmux-501/default",
            runtime: "codex_app_server",
            threadID: "019f87e1-d79a-7f53-8bcd-9ba06bdd381f",
            resumeThreadID: "019f87e1-d79a-7f53-8bcd-9ba06bdd381f"
        )
    }
}
