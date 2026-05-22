import XCTest
@testable import RemoteBridge

final class OrdinaryTmuxPanelProjectorTests: XCTestCase {
    private struct StubAdapter: OrdinaryTmuxWindowProjecting {
        let panels: [OrdinaryTmuxProjectedPanel]

        func projectedPanels(for metadata: OrdinaryTmuxAttachMetadata) throws -> [OrdinaryTmuxProjectedPanel] {
            panels
        }

        func setPaneIdentity(route: OrdinaryTmuxPanelRoute) throws {}
    }

    private struct ThrowingAdapter: OrdinaryTmuxWindowProjecting {
        func projectedPanels(for metadata: OrdinaryTmuxAttachMetadata) throws -> [OrdinaryTmuxProjectedPanel] {
            throw NSError(domain: "OrdinaryTmuxPanelProjectorTests", code: 1)
        }

        func setPaneIdentity(route: OrdinaryTmuxPanelRoute) throws {}
    }

    private final class TimeoutAdapter: OrdinaryTmuxWindowProjecting, @unchecked Sendable {
        private let lock = NSLock()
        private(set) var callCount = 0

        func projectedPanels(for metadata: OrdinaryTmuxAttachMetadata) throws -> [OrdinaryTmuxProjectedPanel] {
            lock.lock()
            callCount += 1
            lock.unlock()
            throw NSError(domain: "OrdinaryTmuxCLIAdapter",
                          code: 124,
                          userInfo: [NSLocalizedDescriptionKey: "tmux command timed out"])
        }

        func setPaneIdentity(route: OrdinaryTmuxPanelRoute) throws {}
    }

    private final class TargetTimeoutAdapter: OrdinaryTmuxWindowProjecting, @unchecked Sendable {
        private let lock = NSLock()
        private let successPanels: [OrdinaryTmuxProjectedPanel]
        private(set) var targetSessions = [String]()

        init(successPanels: [OrdinaryTmuxProjectedPanel]) {
            self.successPanels = successPanels
        }

        func projectedPanels(for metadata: OrdinaryTmuxAttachMetadata) throws -> [OrdinaryTmuxProjectedPanel] {
            lock.lock()
            targetSessions.append(metadata.targetSession ?? "")
            lock.unlock()
            if metadata.targetSession == "adbrewer-cc" {
                throw NSError(domain: "OrdinaryTmuxCLIAdapter",
                              code: 124,
                              userInfo: [NSLocalizedDescriptionKey: "tmux command timed out"])
            }
            return successPanels
        }

        func setPaneIdentity(route: OrdinaryTmuxPanelRoute) throws {}
    }

    private final class MutableAdapter: OrdinaryTmuxWindowProjecting, @unchecked Sendable {
        private let lock = NSLock()
        private var panels: [OrdinaryTmuxProjectedPanel]
        private var shouldThrow = false
        private var errorDomain = "OrdinaryTmuxPanelProjectorTests"
        private var errorCode = 2
        private(set) var callCount = 0
        private(set) var identityRoutes = [OrdinaryTmuxPanelRoute]()

        init(panels: [OrdinaryTmuxProjectedPanel]) {
            self.panels = panels
        }

        func setPanels(_ panels: [OrdinaryTmuxProjectedPanel]) {
            lock.lock()
            self.panels = panels
            lock.unlock()
        }

        func setShouldThrow(_ shouldThrow: Bool) {
            lock.lock()
            self.shouldThrow = shouldThrow
            lock.unlock()
        }

        func setShouldThrow(_ shouldThrow: Bool, domain: String, code: Int) {
            lock.lock()
            self.shouldThrow = shouldThrow
            self.errorDomain = domain
            self.errorCode = code
            lock.unlock()
        }

        func projectedPanels(for metadata: OrdinaryTmuxAttachMetadata) throws -> [OrdinaryTmuxProjectedPanel] {
            lock.lock()
            defer { lock.unlock() }
            callCount += 1
            if shouldThrow {
                throw NSError(domain: errorDomain, code: errorCode)
            }
            return panels
        }

        func setPaneIdentity(route: OrdinaryTmuxPanelRoute) throws {
            lock.lock()
            identityRoutes.append(route)
            lock.unlock()
        }
    }

    private final class TestClock: @unchecked Sendable {
        private let lock = NSLock()
        private var date: Date

        init(_ date: Date) {
            self.date = date
        }

        func advance(_ interval: TimeInterval) {
            lock.lock()
            date = date.addingTimeInterval(interval)
            lock.unlock()
        }

        func now() -> Date {
            lock.lock()
            defer { lock.unlock() }
            return date
        }
    }

    func testProjectsMultiWindowCarrierIntoRemoteOnlyPanels() {
        let projector = OrdinaryTmuxPanelProjector(adapter: StubAdapter(panels: [
            projectedPanel(windowID: "@15", index: 0, name: "priest", paneID: "%15", current: true),
            projectedPanel(windowID: "@16", index: 1, name: "mother_nature", paneID: "%16", current: false),
            projectedPanel(windowID: "@17", index: 2, name: "peon_001", paneID: "%17", current: false),
        ]))

        let result = projector.projectPanelListResult(panelListResult())

        let panels = result["panels"]?.arrayValue?.compactMap(\.objectValue)
        XCTAssertEqual(panels?.map { $0["title"]?.stringValue }, ["priest", "mother_nature", "peon_001"])
        XCTAssertEqual(panels?.map { $0["panel_id"]?.stringValue }, [
            "ordinary-tmux:/tmp/tmux-501/default:$7:@15",
            "ordinary-tmux:/tmp/tmux-501/default:$7:@16",
            "ordinary-tmux:/tmp/tmux-501/default:$7:@17",
        ])
        XCTAssertEqual(result["selected_panel_id"]?.stringValue, "ordinary-tmux:/tmp/tmux-501/default:$7:@15")
        XCTAssertEqual(panels?.map { $0["panel_index"]?.intValue }, [0, 1, 2])
        XCTAssertEqual(panels?.first?["ordinary_tmux_logical"]?.objectValue?["carrier_panel_id"]?.stringValue, "carrier-panel")
        XCTAssertEqual(panels?.first?["ordinary_tmux_logical"]?.objectValue?["active_pane_id"]?.stringValue, "%15")
        XCTAssertEqual(panels?.first?["ordinary_tmux_logical"]?.objectValue?["socket_path"]?.stringValue, "/tmp/tmux-501/default")
        XCTAssertEqual(panels?.first?["effective_shell_pid"]?.intValue, 1015)
    }

    func testProjectionPreservesNonTmuxPanelsAndReindexes() {
        var result = panelListResult()
        result["panels"] = .array([
            result["panels"]!.arrayValue![0],
            .object([
                "panel_id": .string("native-panel"),
                "workspace_id": .string("workspace-1"),
                "title": .string("native shell"),
                "subtitle": .string("zsh"),
                "state": .string("idle"),
                "selected": .bool(false),
                "is_browser": .bool(false),
                "panel_index": .number(1),
                "workspace_index": .number(0),
            ]),
        ])
        let projector = OrdinaryTmuxPanelProjector(adapter: StubAdapter(panels: [
            projectedPanel(windowID: "@15", index: 0, name: "priest", paneID: "%15", current: false),
            projectedPanel(windowID: "@16", index: 1, name: "mother_nature", paneID: "%16", current: true),
        ]))

        let projected = projector.projectPanelListResult(result)

        let panels = projected["panels"]?.arrayValue?.compactMap(\.objectValue)
        XCTAssertEqual(panels?.map { $0["title"]?.stringValue }, ["priest", "mother_nature", "native shell"])
        XCTAssertEqual(panels?.map { $0["panel_index"]?.intValue }, [0, 1, 2])
        XCTAssertEqual(projected["selected_panel_id"]?.stringValue, "ordinary-tmux:/tmp/tmux-501/default:$7:@16")
    }

    func testSingleWindowCarrierKeepsCarrierIDAndCarriesActivePaneContext() throws {
        let adapter = MutableAdapter(panels: [
            projectedPanel(windowID: "@15", index: 0, name: "priest", paneID: "%15", current: true),
        ])
        let registry = OrdinaryTmuxPanelRegistry()
        let projector = OrdinaryTmuxPanelProjector(adapter: adapter, registry: registry)

        let result = projector.projectPanelListResult(panelListResult())

        let panels = result["panels"]?.arrayValue?.compactMap(\.objectValue)
        XCTAssertEqual(panels?.count, 1)
        let panel = try XCTUnwrap(panels?.first)
        XCTAssertEqual(panel["panel_id"]?.stringValue, "carrier-panel")
        XCTAssertEqual(panel["effective_shell_pid"]?.intValue, 1015)
        XCTAssertEqual(panel["cwd"]?.stringValue, "/Users/timfeng/GitHub/priest")
        XCTAssertEqual(panel["current_command"]?.stringValue, "zsh")
        let logical = try XCTUnwrap(panel["ordinary_tmux_logical"]?.objectValue)
        XCTAssertEqual(logical["carrier_panel_id"]?.stringValue, "carrier-panel")
        XCTAssertEqual(logical["active_pane_id"]?.stringValue, "%15")
        XCTAssertEqual(logical["socket_path"]?.stringValue, "/tmp/tmux-501/default")
        XCTAssertEqual(result["selected_panel_id"]?.stringValue, "carrier-panel")
        XCTAssertEqual(adapter.identityRoutes.map { "\($0.windowID):\($0.activePaneID):\($0.panelID)" }, [
            "@15:%15:carrier-panel",
        ])
        XCTAssertNotNil(registry.route(forPanelID: "carrier-panel"))
    }

    func testProjectionFailureFallsBackToOriginalPanel() {
        let projector = OrdinaryTmuxPanelProjector(adapter: ThrowingAdapter())

        let result = projector.projectPanelListResult(panelListResult())

        let panels = result["panels"]?.arrayValue?.compactMap(\.objectValue)
        XCTAssertEqual(panels?.count, 1)
        XCTAssertEqual(panels?.first?["panel_id"]?.stringValue, "carrier-panel")
    }

    func testProjectionUsesCacheWithinTTL() {
        let adapter = MutableAdapter(panels: [
            projectedPanel(windowID: "@15", index: 0, name: "priest", paneID: "%15", current: true),
            projectedPanel(windowID: "@16", index: 1, name: "mother_nature", paneID: "%16", current: false),
        ])
        let clock = TestClock(Date(timeIntervalSince1970: 0))
        let projector = OrdinaryTmuxPanelProjector(adapter: adapter,
                                                   cacheTTL: 10,
                                                   staleTTL: 30,
                                                   now: { clock.now() })

        _ = projector.projectPanelListResult(panelListResult())
        adapter.setPanels([
            projectedPanel(windowID: "@15", index: 0, name: "changed", paneID: "%15", current: true),
            projectedPanel(windowID: "@16", index: 1, name: "mother_nature", paneID: "%16", current: false),
        ])
        let cached = projector.projectPanelListResult(panelListResult())

        let panels = cached["panels"]?.arrayValue?.compactMap(\.objectValue)
        XCTAssertEqual(adapter.callCount, 1)
        XCTAssertEqual(panels?.first?["title"]?.stringValue, "priest")
    }

    func testProjectionRefreshesAfterTTLAndUsesStaleCacheOnRefreshFailure() {
        let adapter = MutableAdapter(panels: [
            projectedPanel(windowID: "@15", index: 0, name: "priest", paneID: "%15", current: true),
            projectedPanel(windowID: "@16", index: 1, name: "mother_nature", paneID: "%16", current: false),
        ])
        let clock = TestClock(Date(timeIntervalSince1970: 0))
        let projector = OrdinaryTmuxPanelProjector(adapter: adapter,
                                                   cacheTTL: 1,
                                                   staleTTL: 30,
                                                   now: { clock.now() })

        _ = projector.projectPanelListResult(panelListResult())
        clock.advance(2)
        adapter.setShouldThrow(true)
        let stale = projector.projectPanelListResult(panelListResult())

        let panels = stale["panels"]?.arrayValue?.compactMap(\.objectValue)
        XCTAssertEqual(adapter.callCount, 2)
        XCTAssertEqual(panels?.map { $0["title"]?.stringValue }, ["priest", "mother_nature"])
        XCTAssertEqual(adapter.identityRoutes.map(\.panelID), [
            "ordinary-tmux:/tmp/tmux-501/default:$7:@15",
            "ordinary-tmux:/tmp/tmux-501/default:$7:@16",
        ])
    }

    func testProjectionTimeoutWithoutCacheKeepsCarrierPanelAndEntersCooldown() {
        let adapter = TimeoutAdapter()
        let clock = TestClock(Date(timeIntervalSince1970: 0))
        let projector = OrdinaryTmuxPanelProjector(adapter: adapter,
                                                   cacheTTL: 1,
                                                   staleTTL: 30,
                                                   now: { clock.now() })

        let first = projector.projectPanelListResult(panelListResult())
        let second = projector.projectPanelListResult(panelListResult())

        XCTAssertEqual(adapter.callCount, 1)
        XCTAssertEqual(first["panels"]?.arrayValue?.first?.objectValue?["panel_id"]?.stringValue, "carrier-panel")
        XCTAssertEqual(second["panels"]?.arrayValue?.first?.objectValue?["panel_id"]?.stringValue, "carrier-panel")
    }

    func testProjectionTimeoutForOneCarrierDoesNotCooldownOtherCarrier() throws {
        let adapter = TargetTimeoutAdapter(successPanels: [
            projectedPanel(windowID: "@15", index: 0, name: "codex", paneID: "%15", current: true),
        ])
        let clock = TestClock(Date(timeIntervalSince1970: 0))
        let projector = OrdinaryTmuxPanelProjector(adapter: adapter,
                                                   cacheTTL: 1,
                                                   staleTTL: 30,
                                                   now: { clock.now() })

        let result = projector.projectPanelListResult(twoCarrierPanelListResult())

        let panels = result["panels"]?.arrayValue?.compactMap(\.objectValue)
        XCTAssertEqual(adapter.targetSessions, ["adbrewer-cc", "adbrewer-codex"])
        XCTAssertEqual(panels?.map { $0["panel_id"]?.stringValue }, ["carrier-cc", "carrier-codex"])
        XCTAssertNil(panels?.first?["ordinary_tmux_logical"])
        XCTAssertEqual(panels?.last?["effective_shell_pid"]?.intValue, 1015)
        let logical = try XCTUnwrap(panels?.last?["ordinary_tmux_logical"]?.objectValue)
        XCTAssertEqual(logical["active_pane_id"]?.stringValue, "%15")
        XCTAssertEqual(logical["socket_path"]?.stringValue, "/tmp/tmux-501/default")
    }

    func testProjectionTimeoutUsesStaleCacheAndCooldownSkipsNextAdapterCall() {
        let adapter = MutableAdapter(panels: [
            projectedPanel(windowID: "@15", index: 0, name: "priest", paneID: "%15", current: true),
            projectedPanel(windowID: "@16", index: 1, name: "mother_nature", paneID: "%16", current: false),
        ])
        let clock = TestClock(Date(timeIntervalSince1970: 0))
        let projector = OrdinaryTmuxPanelProjector(adapter: adapter,
                                                   cacheTTL: 1,
                                                   staleTTL: 30,
                                                   now: { clock.now() })

        _ = projector.projectPanelListResult(panelListResult())
        clock.advance(2)
        adapter.setShouldThrow(true, domain: "OrdinaryTmuxCLIAdapter", code: 124)
        let stale = projector.projectPanelListResult(panelListResult())
        let cooldown = projector.projectPanelListResult(panelListResult())

        let stalePanels = stale["panels"]?.arrayValue?.compactMap(\.objectValue)
        let cooldownPanels = cooldown["panels"]?.arrayValue?.compactMap(\.objectValue)
        XCTAssertEqual(adapter.callCount, 2)
        XCTAssertEqual(stalePanels?.map { $0["title"]?.stringValue }, ["priest", "mother_nature"])
        XCTAssertEqual(cooldownPanels?.map { $0["title"]?.stringValue }, ["priest", "mother_nature"])
    }

    func testProjectionResumesAfterCooldownExpiry() {
        let adapter = MutableAdapter(panels: [
            projectedPanel(windowID: "@15", index: 0, name: "priest", paneID: "%15", current: true),
            projectedPanel(windowID: "@16", index: 1, name: "mother_nature", paneID: "%16", current: false),
        ])
        let clock = TestClock(Date(timeIntervalSince1970: 0))
        let projector = OrdinaryTmuxPanelProjector(adapter: adapter,
                                                   cacheTTL: 1,
                                                   staleTTL: 30,
                                                   now: { clock.now() })

        _ = projector.projectPanelListResult(panelListResult())
        clock.advance(2)
        adapter.setShouldThrow(true, domain: "OrdinaryTmuxCLIAdapter", code: 124)
        _ = projector.projectPanelListResult(panelListResult())
        adapter.setShouldThrow(false)
        adapter.setPanels([
            projectedPanel(windowID: "@18", index: 0, name: "restored_priest", paneID: "%18", current: true),
            projectedPanel(windowID: "@19", index: 1, name: "restored_mother_nature", paneID: "%19", current: false),
        ])
        clock.advance(11)

        let recovered = projector.projectPanelListResult(panelListResult())

        let panels = recovered["panels"]?.arrayValue?.compactMap(\.objectValue)
        XCTAssertEqual(adapter.callCount, 3)
        XCTAssertEqual(panels?.map { $0["title"]?.stringValue }, ["restored_priest", "restored_mother_nature"])
    }

    func testProjectionSetsPaneIdentityForProjectedRoutes() {
        let adapter = MutableAdapter(panels: [
            projectedPanel(windowID: "@15", index: 0, name: "priest", paneID: "%15", current: true),
            projectedPanel(windowID: "@16", index: 1, name: "mother_nature", paneID: "%16", current: false),
        ])
        let projector = OrdinaryTmuxPanelProjector(adapter: adapter)

        _ = projector.projectPanelListResult(panelListResult())

        XCTAssertEqual(adapter.identityRoutes.map { "\($0.windowID):\($0.activePaneID):\($0.panelID)" }, [
            "@15:%15:ordinary-tmux:/tmp/tmux-501/default:$7:@15",
            "@16:%16:ordinary-tmux:/tmp/tmux-501/default:$7:@16",
        ])
    }

    func testProjectionSkipsDuplicatePaneIdentityWritesForSameActivePane() {
        let adapter = MutableAdapter(panels: [
            projectedPanel(windowID: "@15", index: 0, name: "priest", paneID: "%15", current: true),
            projectedPanel(windowID: "@16", index: 1, name: "mother_nature", paneID: "%16", current: false),
        ])
        let projector = OrdinaryTmuxPanelProjector(adapter: adapter)

        _ = projector.projectPanelListResult(panelListResult())
        _ = projector.projectPanelListResult(panelListResult())

        XCTAssertEqual(adapter.identityRoutes.count, 2)
    }

    private func panelListResult() -> [String: JSONValue] {
        [
            "workspace_id": .string("workspace-1"),
            "selected_panel_id": .string("carrier-panel"),
            "panels": .array([
                .object([
                    "panel_id": .string("carrier-panel"),
                    "workspace_id": .string("workspace-1"),
                    "window_guid": .string("window-guid"),
                    "title": .string("tmux"),
                    "subtitle": .string("genesis-extraction"),
                    "state": .string("idle"),
                    "selected": .bool(true),
                    "is_browser": .bool(false),
                    "panel_index": .number(0),
                    "workspace_index": .number(0),
                    "ordinary_tmux": .object([
                        "client_tty": .string("/dev/ttys010"),
                        "target_session": .string("genesis-extraction"),
                    ]),
                ]),
            ]),
        ]
    }

    private func twoCarrierPanelListResult() -> [String: JSONValue] {
        [
            "workspace_id": .string("workspace-1"),
            "selected_panel_id": .string("carrier-codex"),
            "panels": .array([
                .object([
                    "panel_id": .string("carrier-cc"),
                    "workspace_id": .string("workspace-1"),
                    "window_guid": .string("window-guid"),
                    "title": .string("tmux"),
                    "subtitle": .string("adbrewer-cc"),
                    "state": .string("idle"),
                    "selected": .bool(false),
                    "is_browser": .bool(false),
                    "panel_index": .number(0),
                    "workspace_index": .number(0),
                    "ordinary_tmux": .object([
                        "client_tty": .string("/dev/ttys003"),
                        "target_session": .string("adbrewer-cc"),
                    ]),
                ]),
                .object([
                    "panel_id": .string("carrier-codex"),
                    "workspace_id": .string("workspace-1"),
                    "window_guid": .string("window-guid"),
                    "title": .string("tmux"),
                    "subtitle": .string("adbrewer-codex"),
                    "state": .string("idle"),
                    "selected": .bool(true),
                    "is_browser": .bool(false),
                    "panel_index": .number(1),
                    "workspace_index": .number(0),
                    "ordinary_tmux": .object([
                        "client_tty": .string("/dev/ttys004"),
                        "target_session": .string("adbrewer-codex"),
                    ]),
                ]),
            ]),
        ]
    }

    private func projectedPanel(windowID: String,
                                index: Int,
                                name: String,
                                paneID: String,
                                current: Bool) -> OrdinaryTmuxProjectedPanel {
        OrdinaryTmuxProjectedPanel(
            panelID: OrdinaryTmuxCLIAdapter.stablePanelID(socketComponent: "/tmp/tmux-501/default",
                                                          sessionID: "$7",
                                                          windowID: windowID),
            socketPath: "/tmp/tmux-501/default",
            sessionID: "$7",
            sessionName: "genesis-extraction",
            windowID: windowID,
            windowIndex: index,
            windowName: name,
            isCurrentWindow: current,
            activePaneID: paneID,
            activePanePID: Int32(1000 + index + 15),
            cwd: "/Users/timfeng/GitHub/\(name)",
            currentCommand: "zsh",
            title: name,
            subtitle: "/Users/timfeng/GitHub/\(name)"
        )
    }
}
