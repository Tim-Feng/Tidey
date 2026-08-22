import XCTest
@testable import RemoteBridge

final class OrdinaryTmuxPanelProjectorTests: XCTestCase {
    private final class BoolResultsCapture: @unchecked Sendable {
        private let lock = NSLock()
        private var values = [Bool]()

        func append(_ value: Bool) {
            lock.lock()
            values.append(value)
            lock.unlock()
        }

        var snapshot: [Bool] {
            lock.lock()
            defer { lock.unlock() }
            return values
        }
    }

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

    private struct IdentityWriteFailingAdapter: OrdinaryTmuxWindowProjecting {
        let panels: [OrdinaryTmuxProjectedPanel]

        func projectedPanels(for metadata: OrdinaryTmuxAttachMetadata) throws -> [OrdinaryTmuxProjectedPanel] {
            panels
        }

        func setPaneIdentity(route: OrdinaryTmuxPanelRoute) throws {
            throw NSError(domain: "OrdinaryTmuxPanelProjectorTests.identity", code: 1)
        }
    }

    private final class BlockingIdentityWriteFailingAdapter: OrdinaryTmuxWindowProjecting, @unchecked Sendable {
        let panels: [OrdinaryTmuxProjectedPanel]
        private let started = DispatchSemaphore(value: 0)
        private let releaseWrite = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var writeCount = 0

        init(panels: [OrdinaryTmuxProjectedPanel]) {
            self.panels = panels
        }

        func projectedPanels(for metadata: OrdinaryTmuxAttachMetadata) throws -> [OrdinaryTmuxProjectedPanel] {
            panels
        }

        func setPaneIdentity(route: OrdinaryTmuxPanelRoute) throws {
            lock.lock()
            writeCount += 1
            lock.unlock()
            started.signal()
            _ = releaseWrite.wait(timeout: .now() + 1)
            throw NSError(domain: "OrdinaryTmuxPanelProjectorTests.blocking-identity", code: 1)
        }

        func waitUntilWriteStarts() -> DispatchTimeoutResult {
            started.wait(timeout: .now() + 1)
        }

        func finishWrite() {
            releaseWrite.signal()
        }

        var writeCountSnapshot: Int {
            lock.lock()
            defer { lock.unlock() }
            return writeCount
        }
    }

    private final class MultipleIdentityWriteAdapter: OrdinaryTmuxWindowProjecting, @unchecked Sendable {
        let panels: [OrdinaryTmuxProjectedPanel]
        private let firstWriteStarted = DispatchSemaphore(value: 0)
        private let releaseFirstWrite = DispatchSemaphore(value: 0)
        private let secondWriteStarted = DispatchSemaphore(value: 0)
        private let releaseSecondWrite = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var writtenPaneIDs = [String]()

        init(panels: [OrdinaryTmuxProjectedPanel]) {
            self.panels = panels
        }

        func projectedPanels(for metadata: OrdinaryTmuxAttachMetadata) throws -> [OrdinaryTmuxProjectedPanel] {
            panels
        }

        func setPaneIdentity(route: OrdinaryTmuxPanelRoute) throws {
            lock.lock()
            writtenPaneIDs.append(route.activePaneID)
            lock.unlock()
            if route.activePaneID == "%15" {
                firstWriteStarted.signal()
                _ = releaseFirstWrite.wait(timeout: .now() + 1)
            }
            if route.activePaneID == "%16" {
                secondWriteStarted.signal()
                _ = releaseSecondWrite.wait(timeout: .now() + 1)
                throw NSError(domain: "OrdinaryTmuxPanelProjectorTests.multiple-identity", code: 2)
            }
        }

        func waitUntilFirstWriteStarts() -> DispatchTimeoutResult {
            firstWriteStarted.wait(timeout: .now() + 1)
        }

        func finishFirstWrite() {
            releaseFirstWrite.signal()
        }

        func waitUntilSecondWriteStarts() -> DispatchTimeoutResult {
            secondWriteStarted.wait(timeout: .now() + 1)
        }

        func finishSecondWrite() {
            releaseSecondWrite.signal()
        }

        var writtenPaneIDsSnapshot: [String] {
            lock.lock()
            defer { lock.unlock() }
            return writtenPaneIDs
        }
    }

    private struct PartialFailureAdapter: OrdinaryTmuxWindowProjecting {
        let successPanels: [OrdinaryTmuxProjectedPanel]

        func projectedPanels(for metadata: OrdinaryTmuxAttachMetadata) throws -> [OrdinaryTmuxProjectedPanel] {
            if metadata.targetSession == "adbrewer-cc" {
                throw NSError(domain: "OrdinaryTmuxPanelProjectorTests.partial", code: 1)
            }
            return successPanels
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

        func identityRoutesSnapshot() -> [OrdinaryTmuxPanelRoute] {
            lock.lock()
            defer { lock.unlock() }
            return identityRoutes
        }
    }

    private final class SequencedBlockingProjectionAdapter: OrdinaryTmuxWindowProjecting, @unchecked Sendable {
        private let firstPanels: [OrdinaryTmuxProjectedPanel]
        private let secondPanels: [OrdinaryTmuxProjectedPanel]
        private let firstEntered = DispatchSemaphore(value: 0)
        private let secondEntered = DispatchSemaphore(value: 0)
        private let releaseFirst = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var callCount = 0
        private var activeCallCount = 0
        private var maximumActiveCallCount = 0

        init(firstPanels: [OrdinaryTmuxProjectedPanel],
             secondPanels: [OrdinaryTmuxProjectedPanel]) {
            self.firstPanels = firstPanels
            self.secondPanels = secondPanels
        }

        func projectedPanels(for metadata: OrdinaryTmuxAttachMetadata) throws -> [OrdinaryTmuxProjectedPanel] {
            lock.lock()
            let callIndex = callCount
            callCount += 1
            activeCallCount += 1
            maximumActiveCallCount = max(maximumActiveCallCount, activeCallCount)
            lock.unlock()
            defer {
                lock.lock()
                activeCallCount -= 1
                lock.unlock()
            }

            if callIndex == 0 {
                firstEntered.signal()
                guard releaseFirst.wait(timeout: .now() + 5) == .success else {
                    throw NSError(domain: "OrdinaryTmuxPanelProjectorTests.serialization", code: 1)
                }
                return firstPanels
            }
            secondEntered.signal()
            return secondPanels
        }

        func setPaneIdentity(route: OrdinaryTmuxPanelRoute) throws {}

        func waitUntilFirstProjectionStarts() -> DispatchTimeoutResult {
            firstEntered.wait(timeout: .now() + 2)
        }

        func waitUntilSecondProjectionStarts(timeout: TimeInterval) -> DispatchTimeoutResult {
            secondEntered.wait(timeout: .now() + timeout)
        }

        func finishFirstProjection() {
            releaseFirst.signal()
        }

        var maximumConcurrentProjectionCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return maximumActiveCallCount
        }
    }

    private final class WorkspaceBlockingProjectionAdapter: OrdinaryTmuxWindowProjecting, @unchecked Sendable {
        private let blockedPanels: [OrdinaryTmuxProjectedPanel]
        private let unblockedPanels: [OrdinaryTmuxProjectedPanel]
        private let blockedEntered = DispatchSemaphore(value: 0)
        private let unblockedEntered = DispatchSemaphore(value: 0)
        private let releaseBlocked = DispatchSemaphore(value: 0)

        init(blockedPanels: [OrdinaryTmuxProjectedPanel],
             unblockedPanels: [OrdinaryTmuxProjectedPanel]) {
            self.blockedPanels = blockedPanels
            self.unblockedPanels = unblockedPanels
        }

        func projectedPanels(for metadata: OrdinaryTmuxAttachMetadata) throws -> [OrdinaryTmuxProjectedPanel] {
            if metadata.targetSession == "blocked-session" {
                blockedEntered.signal()
                guard releaseBlocked.wait(timeout: .now() + 5) == .success else {
                    throw NSError(domain: "OrdinaryTmuxPanelProjectorTests.workspace-independence", code: 1)
                }
                return blockedPanels
            }
            unblockedEntered.signal()
            return unblockedPanels
        }

        func setPaneIdentity(route: OrdinaryTmuxPanelRoute) throws {}

        func waitUntilBlockedProjectionStarts() -> DispatchTimeoutResult {
            blockedEntered.wait(timeout: .now() + 2)
        }

        func waitUntilUnblockedProjectionStarts() -> DispatchTimeoutResult {
            unblockedEntered.wait(timeout: .now() + 2)
        }

        func finishBlockedProjection() {
            releaseBlocked.signal()
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

    func testProjectionContextOwnsRequestedWindowSizePolicyMode() {
        let context = OrdinaryTmuxProjectionContext(
            windowSizePolicyReconciliationMode: .preserveForInteractiveSizing
        )

        XCTAssertEqual(
            context.windowSizePolicyReconciliationMode,
            .preserveForInteractiveSizing
        )
    }

    func testProjectsMultiWindowCarrierIntoRemoteOnlyPanels() {
        let registry = OrdinaryTmuxPanelRegistry()
        let projector = OrdinaryTmuxPanelProjector(
            adapter: StubAdapter(panels: [
                projectedPanel(windowID: "@15", index: 0, name: "priest", paneID: "%15", current: true),
                projectedPanel(windowID: "@16", index: 1, name: "mother_nature", paneID: "%16", current: false),
                projectedPanel(windowID: "@17", index: 2, name: "peon_001", paneID: "%17", current: false),
            ]),
            registry: registry
        )

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
        XCTAssertEqual(
            registry.route(
                forPanelID:
                    "ordinary-tmux:/tmp/tmux-501/default:$7:@15"
            )?.socket,
            .path("/tmp/tmux-501/default")
        )
        XCTAssertEqual(
            registry.route(
                forPanelID:
                    "ordinary-tmux:/tmp/tmux-501/default:$7:@15"
            )?.restorationSocket,
            .defaultSocket
        )
    }

    func testDuplicateNativeSessionCarriersProjectEachPhysicalWindowOnceUsingFirstCarrier() {
        let registry = OrdinaryTmuxPanelRegistry()
        let projector = OrdinaryTmuxPanelProjector(
            adapter: StubAdapter(panels: [
                projectedPanel(windowID: "@15", index: 0, name: "Claude", paneID: "%15", current: true),
                projectedPanel(windowID: "@16", index: 1, name: "Codex", paneID: "%16", current: false),
            ]),
            registry: registry
        )

        let result = projector.projectPanelListResult(duplicateNativeSessionCarrierPanelListResult())
        let panels = result["panels"]?.arrayValue?.compactMap(\.objectValue)

        XCTAssertEqual(panels?.map { $0["panel_id"]?.stringValue }, [
            "ordinary-tmux:/tmp/tmux-501/default:$7:@15",
            "ordinary-tmux:/tmp/tmux-501/default:$7:@16",
        ])
        XCTAssertEqual(panels?.map { $0["logical_kind"]?.stringValue }, [
            "ordinary_tmux_window",
            "ordinary_tmux_window",
        ])
        XCTAssertEqual(
            registry.route(forPanelID: "ordinary-tmux:/tmp/tmux-501/default:$7:@15")?.carrierPanelID,
            "native-session:carrier-1:leaf-1"
        )
        XCTAssertEqual(
            registry.route(forPanelID: "ordinary-tmux:/tmp/tmux-501/default:$7:@15")?.nativeCarrierPanelID,
            "carrier-1"
        )
    }

    func testProjectedLogicalPanelUsesItsOwnLifecycleAggregate() throws {
        let workspaceID = "workspace-lifecycle-\(UUID().uuidString)"
        let projected = projectedPanel(windowID: "@15",
                                       index: 0,
                                       name: "agent",
                                       paneID: "%15",
                                       current: true)
        let identity = AgentSessionLifecycleIdentity(workspaceID: workspaceID,
                                                     panelID: projected.panelID,
                                                     sessionID: "agent-session")
        AgentSessionLifecycle.store.openBlocker(identity,
                                                vendor: "codex",
                                                generation: 1,
                                                blockerID: "approval",
                                                kind: .permission)
        defer {
            AgentSessionLifecycle.store.retireSession(identity, generation: 1)
        }
        let projector = OrdinaryTmuxPanelProjector(adapter: StubAdapter(panels: [
            projected,
            projectedPanel(windowID: "@16",
                           index: 1,
                           name: "plain",
                           paneID: "%16",
                           current: false),
        ]))

        let result = projector.projectPanelListResult(panelListResult(workspaceID: workspaceID))
        let panel = try XCTUnwrap(result["panels"]?.arrayValue?
            .compactMap(\.objectValue)
            .first { $0["panel_id"]?.stringValue == projected.panelID })
        let aggregate = try XCTUnwrap(AgentSessionLifecycle.store.panelAggregate(workspaceID: workspaceID,
                                                                                 panelID: projected.panelID))

        XCTAssertEqual(panel["state"]?.stringValue, "needs_input")
        XCTAssertEqual(panel["state_revision"]?.intValue, aggregate.revision)
    }

    func testProjectedPlainLogicalPanelsUseTheirOwnForegroundCommands() throws {
        let workspaceID = "workspace-plain-\(UUID().uuidString)"
        var input = panelListResult(workspaceID: workspaceID)
        var carrier = try XCTUnwrap(input["panels"]?.arrayValue?.first?.objectValue)
        carrier["state"] = .string("needs_input")
        input["panels"] = .array([.object(carrier)])
        let projector = OrdinaryTmuxPanelProjector(adapter: StubAdapter(panels: [
            projectedPanel(windowID: "@15",
                           index: 0,
                           name: "shell",
                           paneID: "%15",
                           current: true,
                           currentCommand: "zsh"),
            projectedPanel(windowID: "@16",
                           index: 1,
                           name: "editor",
                           paneID: "%16",
                           current: false,
                           currentCommand: "vim"),
        ]))

        let result = projector.projectPanelListResult(input)
        let panels = try XCTUnwrap(result["panels"]?.arrayValue?.compactMap(\.objectValue))

        XCTAssertEqual(panels.map { $0["state"]?.stringValue }, ["idle", "running"])
        XCTAssertTrue(panels.allSatisfy { $0["state_revision"] == nil })
    }

    func testConcurrentProjectionsForSameWorkspaceSerializeAndKeepNewestRegistryRoute() {
        let adapter = SequencedBlockingProjectionAdapter(
            firstPanels: [projectedPanel(windowID: "@15", index: 0, name: "old", paneID: "%15", current: true)],
            secondPanels: [projectedPanel(windowID: "@16", index: 0, name: "new", paneID: "%16", current: true)])
        let registry = OrdinaryTmuxPanelRegistry()
        let projector = OrdinaryTmuxPanelProjector(adapter: adapter,
                                                   registry: registry,
                                                   cacheTTL: 0)
        let firstInput = panelListResult()
        let secondInput = panelListResult()
        let firstDone = DispatchSemaphore(value: 0)
        let secondRequestStarted = DispatchSemaphore(value: 0)
        let secondDone = DispatchSemaphore(value: 0)

        DispatchQueue.global(qos: .userInitiated).async {
            _ = projector.projectPanelListResult(firstInput)
            firstDone.signal()
        }
        XCTAssertEqual(adapter.waitUntilFirstProjectionStarts(), .success)

        DispatchQueue.global(qos: .userInitiated).async {
            secondRequestStarted.signal()
            _ = projector.projectPanelListResult(secondInput)
            secondDone.signal()
        }
        XCTAssertEqual(secondRequestStarted.wait(timeout: .now() + 2), .success)
        let secondEnteredBeforeRelease = adapter.waitUntilSecondProjectionStarts(timeout: 0.5)

        adapter.finishFirstProjection()
        XCTAssertEqual(firstDone.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(secondDone.wait(timeout: .now() + 2), .success)

        XCTAssertEqual(secondEnteredBeforeRelease, .timedOut,
                       "a second projection for the same workspace must wait before entering the adapter")
        XCTAssertEqual(adapter.maximumConcurrentProjectionCount, 1)
        XCTAssertEqual(registry.route(forPanelID: "carrier-panel")?.windowID, "@16",
                       "the later serialized projection must own the final registry route")
    }

    func testBlockedWorkspaceProjectionDoesNotBlockDifferentWorkspace() {
        let adapter = WorkspaceBlockingProjectionAdapter(
            blockedPanels: [projectedPanel(windowID: "@15", index: 0, name: "blocked", paneID: "%15", current: true)],
            unblockedPanels: [projectedPanel(windowID: "@16", index: 0, name: "free", paneID: "%16", current: true)])
        let projector = OrdinaryTmuxPanelProjector(adapter: adapter, cacheTTL: 0)
        let blockedInput = panelListResult(workspaceID: "workspace-blocked",
                                           targetSession: "blocked-session")
        let unblockedInput = panelListResult(workspaceID: "workspace-free",
                                             targetSession: "free-session")
        let blockedDone = DispatchSemaphore(value: 0)
        let unblockedDone = DispatchSemaphore(value: 0)

        DispatchQueue.global(qos: .userInitiated).async {
            _ = projector.projectPanelListResult(blockedInput)
            blockedDone.signal()
        }
        XCTAssertEqual(adapter.waitUntilBlockedProjectionStarts(), .success)

        DispatchQueue.global(qos: .userInitiated).async {
            _ = projector.projectPanelListResult(unblockedInput)
            unblockedDone.signal()
        }
        XCTAssertEqual(adapter.waitUntilUnblockedProjectionStarts(), .success)
        XCTAssertEqual(unblockedDone.wait(timeout: .now() + 2), .success,
                       "a different workspace must finish while the first workspace remains blocked")

        adapter.finishBlockedProjection()
        XCTAssertEqual(blockedDone.wait(timeout: .now() + 2), .success)
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
        let identityRoutes = waitForIdentityRoutes(adapter, count: 1)
        XCTAssertEqual(identityRoutes.map { "\($0.windowID):\($0.activePaneID):\($0.panelID)" }, [
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
        XCTAssertEqual(panels?.first?["ordinary_tmux_projection"]?.objectValue?["status"]?.stringValue, "unavailable")
        XCTAssertEqual(panels?.first?["ordinary_tmux_projection"]?.objectValue?["reason"]?.stringValue, "error_no_cache")
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
        let identityRoutes = waitForIdentityRoutes(adapter, count: 2)
        XCTAssertEqual(identityRoutes.map(\.panelID), [
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

    func testProjectionTimeoutWithoutCacheMarksCarrierUnavailable() {
        let adapter = TimeoutAdapter()
        let clock = TestClock(Date(timeIntervalSince1970: 0))
        let projector = OrdinaryTmuxPanelProjector(adapter: adapter,
                                                   registry: OrdinaryTmuxPanelRegistry(),
                                                   cacheTTL: 1,
                                                   staleTTL: 30,
                                                   now: { clock.now() })

        let result = projector.projectPanelListResult(panelListResult())

        let panel = result["panels"]?.arrayValue?.first?.objectValue
        let projection = panel?["ordinary_tmux_projection"]?.objectValue
        XCTAssertEqual(panel?["panel_id"]?.stringValue, "carrier-panel")
        XCTAssertEqual(projection?["status"]?.stringValue, "unavailable")
        XCTAssertEqual(projection?["reason"]?.stringValue, "timeout_no_cache")
    }

    func testProjectionTimeoutUsesRegistryLastKnownGoodWhenProjectorCacheIsCold() {
        let registry = OrdinaryTmuxPanelRegistry()
        let clock = TestClock(Date(timeIntervalSince1970: 0))
        let firstProjector = OrdinaryTmuxPanelProjector(adapter: StubAdapter(panels: [
            projectedPanel(windowID: "@15", index: 0, name: "priest", paneID: "%15", current: true),
            projectedPanel(windowID: "@16", index: 1, name: "mother_nature", paneID: "%16", current: false),
            projectedPanel(windowID: "@17", index: 2, name: "peon_001", paneID: "%17", current: false),
        ]),
                                                   registry: registry,
                                                   cacheTTL: 1,
                                                   staleTTL: 30,
                                                   now: { clock.now() })

        _ = firstProjector.projectPanelListResult(panelListResult())
        clock.advance(120)
        let timeoutProjector = OrdinaryTmuxPanelProjector(adapter: TimeoutAdapter(),
                                                          registry: registry,
                                                          cacheTTL: 1,
                                                          staleTTL: 30,
                                                          now: { clock.now() })

        let result = timeoutProjector.projectPanelListResult(panelListResult())

        let panels = result["panels"]?.arrayValue?.compactMap(\.objectValue)
        XCTAssertEqual(panels?.map { $0["title"]?.stringValue }, ["priest", "mother_nature", "peon_001"])
        XCTAssertEqual(panels?.map { $0["ordinary_tmux_projection"]?.objectValue?["status"]?.stringValue }, [
            "stale",
            "stale",
            "stale",
        ])
        XCTAssertEqual(panels?.map { $0["ordinary_tmux_projection"]?.objectValue?["reason"]?.stringValue }, [
            "timeout",
            "timeout",
            "timeout",
        ])
    }

    func testRegistryStaleProjectionDoesNotReplaceInputRoutes() {
        let registry = OrdinaryTmuxPanelRegistry()
        let clock = TestClock(Date(timeIntervalSince1970: 0))
        let stalePanels = [
            projectedPanel(windowID: "@99", index: 0, name: "stale_priest", paneID: "%99", current: true),
            projectedPanel(windowID: "@100", index: 1, name: "stale_mother", paneID: "%100", current: false),
        ]
        registry.storeProjectionSnapshot(key: projectionCacheKey(),
                                         panels: stalePanels,
                                         observedAt: clock.now())
        clock.advance(120)
        let projector = OrdinaryTmuxPanelProjector(adapter: TimeoutAdapter(),
                                                   registry: registry,
                                                   cacheTTL: 1,
                                                   staleTTL: 30,
                                                   now: { clock.now() })

        let result = projector.projectPanelListResult(panelListResult())

        let panels = result["panels"]?.arrayValue?.compactMap(\.objectValue)
        XCTAssertEqual(panels?.map { $0["title"]?.stringValue }, ["stale_priest", "stale_mother"])
        XCTAssertNil(registry.route(forPanelID: stalePanels[0].panelID))
        XCTAssertNil(registry.route(forPanelID: stalePanels[1].panelID))
    }

    func testProjectionTimeoutSkipsRemainingSameSocketCarrierDuringRequest() {
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
        XCTAssertEqual(adapter.targetSessions, ["adbrewer-cc"])
        XCTAssertEqual(panels?.map { $0["panel_id"]?.stringValue }, ["carrier-cc", "carrier-codex"])
        XCTAssertNil(panels?.first?["ordinary_tmux_logical"])
        XCTAssertNil(panels?.last?["ordinary_tmux_logical"])
        XCTAssertNil(panels?.last?["effective_shell_pid"])
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

        let identityRoutes = waitForIdentityRoutes(adapter, count: 2)
        XCTAssertEqual(identityRoutes.map { "\($0.windowID):\($0.activePaneID):\($0.panelID)" }, [
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

        XCTAssertEqual(waitForIdentityRoutes(adapter, count: 2).count, 2)
    }

    func testReconciliationReportsPaneIdentityWriteFailure() {
        let projector = OrdinaryTmuxPanelProjector(adapter: IdentityWriteFailingAdapter(panels: [
            projectedPanel(windowID: "@15", index: 0, name: "priest", paneID: "%15", current: true),
        ]))
        let completed = expectation(description: "pane identity reconciliation completes")
        let results = BoolResultsCapture()

        _ = projector.reconcilePaneIdentities(inPanelListResult: panelListResult()) { result in
            results.append(result)
            completed.fulfill()
        }

        wait(for: [completed], timeout: 1)
        XCTAssertEqual(results.snapshot, [false],
                       "an async setPaneIdentity failure must remain observable so the reconciler can retry")
    }

    func testReconciliationJoinsPendingIdentityWriteAndObservesItsFailure() {
        let adapter = BlockingIdentityWriteFailingAdapter(panels: [
            projectedPanel(windowID: "@15", index: 0, name: "priest", paneID: "%15", current: true),
        ])
        let projector = OrdinaryTmuxPanelProjector(adapter: adapter)
        let completed = expectation(description: "joined pending identity write completes")
        let results = BoolResultsCapture()

        _ = projector.projectPanelListResult(panelListResult())
        XCTAssertEqual(adapter.waitUntilWriteStarts(), .success)

        _ = projector.reconcilePaneIdentities(inPanelListResult: panelListResult()) { result in
            results.append(result)
            completed.fulfill()
        }
        adapter.finishWrite()

        wait(for: [completed], timeout: 1)
        XCTAssertEqual(results.snapshot, [false],
                       "a reconciliation must join an already pending write instead of treating it as committed")
        XCTAssertEqual(adapter.writeCountSnapshot, 1,
                       "joining the in-flight write should not enqueue a duplicate tmux mutation")
    }

    func testReconciliationRewritesCommittedIdentityForReusedTmuxPaneID() {
        let adapter = MutableAdapter(panels: [
            projectedPanel(windowID: "@15", index: 0, name: "priest", paneID: "%15", current: true),
        ])
        let projector = OrdinaryTmuxPanelProjector(adapter: adapter)
        let completed = expectation(description: "committed identity is revalidated")

        _ = projector.projectPanelListResult(panelListResult())
        XCTAssertEqual(waitForIdentityRoutes(adapter, count: 1).count, 1)

        _ = projector.reconcilePaneIdentities(inPanelListResult: panelListResult()) { succeeded in
            XCTAssertTrue(succeeded)
            completed.fulfill()
        }

        wait(for: [completed], timeout: 1)
        XCTAssertEqual(waitForIdentityRoutes(adapter, count: 2).count, 2,
                       "event reconciliation must rewrite options even when tmux reuses the same $/@/% identifiers after kill-server")
    }

    func testReconciliationWithoutCarriersFailsByDefault() {
        let projector = OrdinaryTmuxPanelProjector(adapter: StubAdapter(panels: []))
        let completed = expectation(description: "no-carrier reconciliation completes")
        let results = BoolResultsCapture()

        _ = projector.reconcilePaneIdentities(inPanelListResult: emptyPanelListResult()) { result in
            results.append(result)
            completed.fulfill()
        }

        wait(for: [completed], timeout: 1)
        XCTAssertEqual(results.snapshot, [false])
    }

    func testReconciliationAllowsAuthoritativeNoCarrierResultWhenRequested() {
        let projector = OrdinaryTmuxPanelProjector(adapter: StubAdapter(panels: []))
        let completed = expectation(description: "allowed no-carrier reconciliation completes")
        let results = BoolResultsCapture()

        _ = projector.reconcilePaneIdentities(inPanelListResult: emptyPanelListResult(),
                                              allowsNoCarriers: true) { result in
            results.append(result)
            completed.fulfill()
        }

        wait(for: [completed], timeout: 1)
        XCTAssertEqual(results.snapshot, [true])
    }

    func testReconciliationJoinedToMultipleWritesCompletesExactlyOnceAfterAllCallbacks() {
        let adapter = MultipleIdentityWriteAdapter(panels: [
            projectedPanel(windowID: "@15", index: 0, name: "priest", paneID: "%15", current: true),
            projectedPanel(windowID: "@16", index: 1, name: "mother_nature", paneID: "%16", current: false),
        ])
        let projector = OrdinaryTmuxPanelProjector(adapter: adapter)
        let completed = expectation(description: "joined multi-write reconciliation completes")
        completed.assertForOverFulfill = true
        let results = BoolResultsCapture()

        _ = projector.projectPanelListResult(panelListResult())
        XCTAssertEqual(adapter.waitUntilFirstWriteStarts(), .success)

        _ = projector.reconcilePaneIdentities(inPanelListResult: panelListResult()) { result in
            results.append(result)
            completed.fulfill()
        }
        adapter.finishFirstWrite()
        XCTAssertEqual(adapter.waitUntilSecondWriteStarts(), .success)
        XCTAssertTrue(results.snapshot.isEmpty,
                      "the first callback may not resolve a batch that is still waiting for another identity write")
        adapter.finishSecondWrite()

        wait(for: [completed], timeout: 1)
        XCTAssertEqual(adapter.writtenPaneIDsSnapshot, ["%15", "%16"])
        XCTAssertEqual(results.snapshot, [false],
                       "the joined batch must aggregate the later failure and resolve exactly once")
    }

    func testPartialCarrierFailureDoesNotReplaceWorkspaceRegistry() throws {
        let registry = OrdinaryTmuxPanelRegistry()
        let oldRoute = route(panelID: "old-cc-route",
                             carrierPanelID: "carrier-cc",
                             windowID: "@90",
                             paneID: "%90")
        registry.replaceRoutes(workspaceID: "workspace-1", routes: [oldRoute])
        let projector = OrdinaryTmuxPanelProjector(adapter: PartialFailureAdapter(successPanels: [
            projectedPanel(windowID: "@15", index: 0, name: "codex", paneID: "%15", current: true),
        ]), registry: registry)

        let result = projector.projectPanelListResult(twoCarrierPanelListResult())

        XCTAssertEqual(registry.route(forPanelID: oldRoute.panelID), oldRoute,
                       "one fresh carrier must not atomically replace routes while another carrier projection failed")
        let projectedPanelID = try XCTUnwrap(result["panels"]?.arrayValue?.compactMap(\.objectValue)
            .first { $0["panel_id"]?.stringValue == "carrier-codex" }?["panel_id"]?.stringValue)
        XCTAssertNotNil(registry.route(forPanelID: projectedPanelID),
                        "every newly exposed projected panel must be routable even when another carrier failed")
    }

    func testAuthoritativeZeroCarrierListClearsRoutesAndAuthorization() throws {
        let registry = OrdinaryTmuxPanelRegistry()
        let oldRoute = route(panelID: OrdinaryTmuxCLIAdapter.stablePanelID(socketComponent: "/tmp/tmux-501/default",
                                                                           sessionID: "$7",
                                                                           windowID: "@90"),
                             carrierPanelID: "carrier-cc",
                             windowID: "@90",
                             paneID: "%90")
        registry.replaceRoutes(workspaceID: "workspace-1", routes: [oldRoute])
        let logicalID = try XCTUnwrap(OrdinaryTmuxLogicalPanelID(rawValue: oldRoute.panelID))
        XCTAssertNotNil(registry.authorizedTarget(for: logicalID, workspaceID: "workspace-1"))
        let projector = OrdinaryTmuxPanelProjector(adapter: StubAdapter(panels: []), registry: registry)

        _ = projector.projectPanelListResult([
            "workspace_id": .string("workspace-1"),
            "panels": .array([]),
        ])

        XCTAssertNil(registry.route(forPanelID: oldRoute.panelID))
        XCTAssertNil(registry.authorizedTarget(for: logicalID, workspaceID: "workspace-1"),
                     "an authoritative empty workspace must not retain logical-ID fallback authorization")
    }

    private func waitForIdentityRoutes(_ adapter: MutableAdapter,
                                       count: Int,
                                       timeout: TimeInterval = 1,
                                       file: StaticString = #filePath,
                                       line: UInt = #line) -> [OrdinaryTmuxPanelRoute] {
        let deadline = Date().addingTimeInterval(timeout)
        var routes = adapter.identityRoutesSnapshot()
        while routes.count < count && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
            routes = adapter.identityRoutesSnapshot()
        }
        XCTAssertGreaterThanOrEqual(routes.count, count, file: file, line: line)
        return routes
    }

    private func route(panelID: String,
                       carrierPanelID: String,
                       windowID: String,
                       paneID: String) -> OrdinaryTmuxPanelRoute {
        OrdinaryTmuxPanelRoute(workspaceID: "workspace-1",
                               panelID: panelID,
                               carrierPanelID: carrierPanelID,
                               socket: .path("/tmp/tmux-501/default"),
                               sessionID: "$7",
                               sessionName: "genesis-extraction",
                               windowID: windowID,
                               windowIndex: 0,
                               activePaneID: paneID,
                               cwd: "/Users/timfeng/GitHub/test",
                               currentCommand: "zsh")
    }

    private func panelListResult(workspaceID: String = "workspace-1",
                                 targetSession: String = "genesis-extraction") -> [String: JSONValue] {
        [
            "workspace_id": .string(workspaceID),
            "selected_panel_id": .string("carrier-panel"),
            "panels": .array([
                .object([
                    "panel_id": .string("carrier-panel"),
                    "workspace_id": .string(workspaceID),
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
                        "target_session": .string(targetSession),
                    ]),
                ]),
            ]),
        ]
    }

    private func emptyPanelListResult() -> [String: JSONValue] {
        [
            "workspace_id": .string("workspace-1"),
            "panels": .array([]),
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

    private func duplicateNativeSessionCarrierPanelListResult() -> [String: JSONValue] {
        let ordinaryTmux: JSONValue = .object([
            "client_tty": .string("/dev/ttys010"),
            "target_session": .string("genesis-extraction"),
        ])
        return [
            "workspace_id": .string("workspace-1"),
            "selected_panel_id": .string("native-session:carrier-1:leaf-1"),
            "panels": .array([
                .object([
                    "panel_id": .string("native-session:carrier-1:leaf-1"),
                    "carrier_panel_id": .string("carrier-1"),
                    "native_session_id": .string("leaf-1"),
                    "logical_kind": .string("native_session"),
                    "workspace_id": .string("workspace-1"),
                    "selected": .bool(true),
                    "panel_index": .number(0),
                    "workspace_index": .number(0),
                    "ordinary_tmux": ordinaryTmux,
                ]),
                .object([
                    "panel_id": .string("native-session:carrier-1:leaf-2"),
                    "carrier_panel_id": .string("carrier-1"),
                    "native_session_id": .string("leaf-2"),
                    "logical_kind": .string("native_session"),
                    "workspace_id": .string("workspace-1"),
                    "selected": .bool(false),
                    "panel_index": .number(1),
                    "workspace_index": .number(0),
                    "ordinary_tmux": ordinaryTmux,
                ]),
            ]),
        ]
    }

    private func projectedPanel(windowID: String,
                                index: Int,
                                name: String,
                                paneID: String,
                                current: Bool,
                                currentCommand: String = "zsh") -> OrdinaryTmuxProjectedPanel {
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
            currentCommand: currentCommand,
            title: name,
            subtitle: "/Users/timfeng/GitHub/\(name)"
        )
    }

    private func projectionCacheKey() -> String {
        [
            "workspace-1",
            "carrier-panel",
            "default",
            "/dev/ttys010",
            "genesis-extraction",
        ].joined(separator: "|")
    }
}
