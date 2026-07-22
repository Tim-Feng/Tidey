import XCTest
@testable import RemoteBridge

final class OrdinaryTmuxPaneIdentityReconcilerTests: XCTestCase {
    private final class Capture<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var values = [Value]()

        func append(_ value: Value) {
            lock.lock()
            values.append(value)
            lock.unlock()
        }

        var snapshot: [Value] {
            lock.lock()
            defer { lock.unlock() }
            return values
        }
    }

    func testPanelUpdatePublishesAndProjectsCompletePanelListWithoutExplicitClientFetch() {
        let requests = Capture<BridgeRequest>()
        let projectedResults = Capture<[String: JSONValue]>()
        let projected = expectation(description: "complete panel list projected")
        let published = expectation(description: "workspace event published")
        let fullPanelList = panelListResult(panelIDs: ["video-process-codex", "video-process-cc"])
        let reconciler = OrdinaryTmuxPaneIdentityReconciler(
            requestSender: { request in
                requests.append(request)
                return BridgeResponse(id: request.id, ok: true, result: fullPanelList, error: nil)
            },
            projectPanelList: { result, _, completion in
                projectedResults.append(result)
                projected.fulfill()
                completion(true)
            },
            debounceInterval: 0,
            retryDelays: []
        )
        let hub = WorkspaceEventHub()
        _ = hub.subscribe(workspaceID: "workspace-video") { envelope in
            XCTAssertEqual(envelope.event.eventID, "event-1")
            published.fulfill()
        }
        let monitor = TideyWorkspaceEventMonitor(locator: TideySocketLocator(),
                                                 hub: hub,
                                                 paneIdentityReconciler: reconciler)

        monitor.process(event: panelEvent(eventID: "event-1",
                                          kind: .panelUpdated,
                                          ordinaryTmux: true))

        wait(for: [published, projected], timeout: 1)
        XCTAssertEqual(requests.snapshot.count, 1)
        XCTAssertEqual(requests.snapshot.first?.action, "list_panels")
        XCTAssertEqual(requests.snapshot.first?.params?["workspace_id"]?.stringValue, "workspace-video")
        XCTAssertEqual(projectedResults.snapshot.first?["panels"]?.arrayValue?.count, 2,
                       "reconciliation must project the authoritative complete panel list, not a synthetic one-panel result")
    }

    func testPanelCreatedWithOrdinaryTmuxMetadataSchedulesReconciliation() {
        let projected = expectation(description: "panel created projected")
        let reconciler = OrdinaryTmuxPaneIdentityReconciler(
            requestSender: { request in
                BridgeResponse(id: request.id,
                               ok: true,
                               result: self.panelListResult(panelIDs: ["video-process-cc"]),
                               error: nil)
            },
            projectPanelList: { result, _, completion in
                projected.fulfill()
                completion(true)
            },
            debounceInterval: 0,
            retryDelays: []
        )

        reconciler.observe(panelEvent(eventID: "event-created",
                                      kind: .panelCreated,
                                      ordinaryTmux: true))

        wait(for: [projected], timeout: 1)
    }

    func testPlainPanelEventPublishesWithoutSchedulingReconciliation() {
        let requested = expectation(description: "plain panel must not fetch")
        requested.isInverted = true
        let published = expectation(description: "plain event published")
        let reconciler = OrdinaryTmuxPaneIdentityReconciler(
            requestSender: { request in
                requested.fulfill()
                return BridgeResponse(id: request.id, ok: true, result: nil, error: nil)
            },
            projectPanelList: { _, _, completion in completion(true) },
            debounceInterval: 0,
            retryDelays: []
        )
        let hub = WorkspaceEventHub()
        _ = hub.subscribe(workspaceID: nil) { _ in published.fulfill() }
        let monitor = TideyWorkspaceEventMonitor(locator: TideySocketLocator(),
                                                 hub: hub,
                                                 paneIdentityReconciler: reconciler)

        monitor.process(event: panelEvent(eventID: "event-plain",
                                          kind: .panelUpdated,
                                          ordinaryTmux: false))

        wait(for: [published, requested], timeout: 0.15)
    }

    func testOrdinaryTmuxPanelCloseClearsCarrierAndTreatsMissingWorkspaceAsCompleted() {
        let requested = expectation(description: "closed ordinary carrier best-effort refreshes complete list")
        let cleaned = expectation(description: "closed carrier routes cleared immediately")
        let projected = expectation(description: "missing workspace must not project a fake empty result")
        projected.isInverted = true
        let removedCarriers = Capture<String>()
        let reconciler = OrdinaryTmuxPaneIdentityReconciler(
            requestSender: { request in
                requested.fulfill()
                return BridgeResponse(id: request.id,
                                      ok: false,
                                      result: nil,
                                      error: BridgeErrorPayload(code: "workspace_not_found",
                                                                message: "workspace was removed"))
            },
            projectPanelList: { _, _, completion in
                projected.fulfill()
                completion(true)
            },
            removeCarrierRoutes: { workspaceID, carrierPanelID in
                removedCarriers.append("\(workspaceID):\(carrierPanelID)")
                cleaned.fulfill()
            },
            debounceInterval: 0,
            retryDelays: []
        )

        reconciler.observe(panelEvent(eventID: "event-closed",
                                      kind: .panelClosed,
                                      ordinaryTmux: true))

        wait(for: [requested, cleaned, projected], timeout: 0.2)
        XCTAssertEqual(removedCarriers.snapshot, ["workspace-video:carrier-video-cc"])
    }

    func testKnownCarrierUpdateWithoutMetadataReconcilesAuthoritativeNoCarrierResult() throws {
        let registry = OrdinaryTmuxPanelRegistry()
        let logicalID = try seedRegistry(registry)
        let projected = expectation(description: "known carrier workspace reconciled")
        let allowsNoCarriers = Capture<Bool>()
        let reconciler = OrdinaryTmuxPaneIdentityReconciler(
            requestSender: { request in
                BridgeResponse(id: request.id,
                               ok: true,
                               result: self.panelListResult(panelIDs: ["plain-panel"]),
                               error: nil)
            },
            projectPanelList: { _, allowsNone, completion in
                allowsNoCarriers.append(allowsNone)
                registry.replaceRoutesAuthoritatively(workspaceID: "workspace-video", routes: [])
                projected.fulfill()
                completion(true)
            },
            hasCarrierOwnership: { workspaceID, carrierPanelID in
                registry.hasCarrierOwnership(workspaceID: workspaceID,
                                             carrierPanelID: carrierPanelID)
            },
            hasWorkspaceOwnership: { workspaceID in
                registry.hasWorkspaceOwnership(workspaceID: workspaceID)
            },
            debounceInterval: 0,
            retryDelays: []
        )

        reconciler.observe(panelEvent(eventID: "event-update-without-metadata",
                                      kind: .panelUpdated,
                                      ordinaryTmux: false))

        wait(for: [projected], timeout: 1)
        XCTAssertEqual(allowsNoCarriers.snapshot, [true])
        XCTAssertNil(registry.route(forPanelID: logicalID.rawValue))
        XCTAssertNil(registry.authorizedTarget(for: logicalID, workspaceID: "workspace-video"))
    }

    func testKnownCarrierUpdateWithoutMetadataClearsWorkspaceWhenRefreshSaysNotFound() throws {
        let registry = OrdinaryTmuxPanelRegistry()
        let logicalID = try seedRegistry(registry)
        let cleaned = expectation(description: "missing workspace ownership cleared")
        let requested = expectation(description: "known carrier workspace refreshed")
        let projected = expectation(description: "missing workspace must not project")
        projected.isInverted = true
        let reconciler = OrdinaryTmuxPaneIdentityReconciler(
            requestSender: { request in
                requested.fulfill()
                return BridgeResponse(id: request.id,
                                      ok: false,
                                      result: nil,
                                      error: BridgeErrorPayload(code: "workspace_not_found",
                                                                message: "workspace was removed"))
            },
            projectPanelList: { _, _, completion in
                projected.fulfill()
                completion(true)
            },
            hasCarrierOwnership: { workspaceID, carrierPanelID in
                registry.hasCarrierOwnership(workspaceID: workspaceID,
                                             carrierPanelID: carrierPanelID)
            },
            hasWorkspaceOwnership: { workspaceID in
                registry.hasWorkspaceOwnership(workspaceID: workspaceID)
            },
            removeWorkspaceRoutes: { workspaceID in
                registry.replaceRoutesAuthoritatively(workspaceID: workspaceID, routes: [])
                cleaned.fulfill()
            },
            debounceInterval: 0,
            retryDelays: []
        )

        reconciler.observe(panelEvent(eventID: "event-update-workspace-missing",
                                      kind: .panelUpdated,
                                      ordinaryTmux: false))

        wait(for: [requested, cleaned, projected], timeout: 0.2)
        XCTAssertNil(registry.route(forPanelID: logicalID.rawValue))
        XCTAssertNil(registry.authorizedTarget(for: logicalID, workspaceID: "workspace-video"))
    }

    func testKnownCarrierCloseWithoutMetadataClearsRoutesAndAuthorization() throws {
        let registry = OrdinaryTmuxPanelRegistry()
        let logicalID = try seedRegistry(registry)
        let cleaned = expectation(description: "known closed carrier ownership cleared")
        let requested = expectation(description: "closed carrier workspace refreshed")
        let reconciler = OrdinaryTmuxPaneIdentityReconciler(
            requestSender: { request in
                requested.fulfill()
                return BridgeResponse(id: request.id,
                                      ok: false,
                                      result: nil,
                                      error: BridgeErrorPayload(code: "workspace_not_found",
                                                                message: "workspace was removed"))
            },
            projectPanelList: { _, _, completion in completion(true) },
            hasCarrierOwnership: { workspaceID, carrierPanelID in
                registry.hasCarrierOwnership(workspaceID: workspaceID,
                                             carrierPanelID: carrierPanelID)
            },
            hasWorkspaceOwnership: { workspaceID in
                registry.hasWorkspaceOwnership(workspaceID: workspaceID)
            },
            removeCarrierRoutes: { workspaceID, carrierPanelID in
                registry.replaceRoutes(workspaceID: workspaceID,
                                       carrierPanelID: carrierPanelID,
                                       routes: [])
                cleaned.fulfill()
            },
            debounceInterval: 0,
            retryDelays: []
        )

        reconciler.observe(panelEvent(eventID: "event-close-without-metadata",
                                      kind: .panelClosed,
                                      ordinaryTmux: false))

        wait(for: [cleaned, requested], timeout: 1)
        XCTAssertNil(registry.route(forPanelID: logicalID.rawValue))
        XCTAssertNil(registry.authorizedTarget(for: logicalID, workspaceID: "workspace-video"))
    }

    func testClosedCarrierIsClearedAgainAfterProjectionCompletes() throws {
        let registry = OrdinaryTmuxPanelRegistry()
        let logicalID = try seedRegistry(registry)
        let route = try XCTUnwrap(registry.route(forPanelID: logicalID.rawValue))
        let cleaned = expectation(description: "carrier cleared before and after projection")
        cleaned.expectedFulfillmentCount = 2
        let projected = expectation(description: "stale projection completed")
        let reconciler = OrdinaryTmuxPaneIdentityReconciler(
            requestSender: { request in
                BridgeResponse(id: request.id,
                               ok: true,
                               result: self.panelListResult(panelIDs: ["carrier-video-cc"]),
                               error: nil)
            },
            projectPanelList: { _, _, completion in
                registry.replaceRoutes(workspaceID: route.workspaceID,
                                       carrierPanelID: route.carrierPanelID,
                                       routes: [route])
                projected.fulfill()
                completion(true)
            },
            hasCarrierOwnership: { workspaceID, carrierPanelID in
                registry.hasCarrierOwnership(workspaceID: workspaceID,
                                             carrierPanelID: carrierPanelID)
            },
            hasWorkspaceOwnership: { workspaceID in
                registry.hasWorkspaceOwnership(workspaceID: workspaceID)
            },
            removeCarrierRoutes: { workspaceID, carrierPanelID in
                registry.replaceRoutes(workspaceID: workspaceID,
                                       carrierPanelID: carrierPanelID,
                                       routes: [])
                cleaned.fulfill()
            },
            debounceInterval: 0,
            retryDelays: []
        )

        reconciler.observe(panelEvent(eventID: "event-close-racing-projection",
                                      kind: .panelClosed,
                                      ordinaryTmux: false))

        wait(for: [projected, cleaned], timeout: 1)
        XCTAssertNil(registry.route(forPanelID: logicalID.rawValue))
        XCTAssertNil(registry.authorizedTarget(for: logicalID, workspaceID: "workspace-video"))
    }

    func testKnownWorkspaceCloseWithoutPanelPayloadClearsWorkspaceOwnership() throws {
        let registry = OrdinaryTmuxPanelRegistry()
        let logicalID = try seedRegistry(registry)
        let cleaned = expectation(description: "known workspace ownership cleared")
        let requested = expectation(description: "closed workspace must not be fetched")
        requested.isInverted = true
        let reconciler = OrdinaryTmuxPaneIdentityReconciler(
            requestSender: { request in
                requested.fulfill()
                return BridgeResponse(id: request.id, ok: true, result: nil, error: nil)
            },
            projectPanelList: { _, _, completion in completion(true) },
            hasCarrierOwnership: { workspaceID, carrierPanelID in
                registry.hasCarrierOwnership(workspaceID: workspaceID,
                                             carrierPanelID: carrierPanelID)
            },
            hasWorkspaceOwnership: { workspaceID in
                registry.hasWorkspaceOwnership(workspaceID: workspaceID)
            },
            removeWorkspaceRoutes: { workspaceID in
                registry.replaceRoutesAuthoritatively(workspaceID: workspaceID, routes: [])
                cleaned.fulfill()
            },
            debounceInterval: 0,
            retryDelays: []
        )

        reconciler.observe(panelEvent(eventID: "event-workspace-close-without-panel",
                                      kind: .workspaceClosed,
                                      ordinaryTmux: false,
                                      includePanel: false,
                                      panelID: nil))

        wait(for: [cleaned, requested], timeout: 0.2)
        XCTAssertNil(registry.route(forPanelID: logicalID.rawValue))
        XCTAssertNil(registry.authorizedTarget(for: logicalID, workspaceID: "workspace-video"))
    }

    func testPlainMissingMetadataEventsDoNotReconcileOrClearOwnership() {
        let requested = expectation(description: "plain events must not fetch")
        requested.isInverted = true
        let cleaned = expectation(description: "plain events must not clear routes")
        cleaned.isInverted = true
        let reconciler = OrdinaryTmuxPaneIdentityReconciler(
            requestSender: { request in
                requested.fulfill()
                return BridgeResponse(id: request.id, ok: true, result: nil, error: nil)
            },
            projectPanelList: { _, _, completion in completion(true) },
            hasCarrierOwnership: { _, _ in false },
            hasWorkspaceOwnership: { _ in false },
            removeCarrierRoutes: { _, _ in cleaned.fulfill() },
            removeWorkspaceRoutes: { _ in cleaned.fulfill() },
            debounceInterval: 0,
            retryDelays: []
        )

        reconciler.observe(panelEvent(eventID: "plain-update", kind: .panelUpdated, ordinaryTmux: false))
        reconciler.observe(panelEvent(eventID: "plain-close", kind: .panelClosed, ordinaryTmux: false))
        reconciler.observe(panelEvent(eventID: "plain-workspace-close",
                                      kind: .workspaceClosed,
                                      ordinaryTmux: false,
                                      includePanel: false,
                                      panelID: nil))

        wait(for: [requested, cleaned], timeout: 0.15)
    }

    func testOrdinaryTmuxWorkspaceCloseClearsRegistryWithoutFetchingRemovedWorkspace() {
        let requested = expectation(description: "removed workspace must not be fetched")
        requested.isInverted = true
        let cleaned = expectation(description: "workspace routes cleared directly")
        let removedWorkspaces = Capture<String>()
        let reconciler = OrdinaryTmuxPaneIdentityReconciler(
            requestSender: { request in
                requested.fulfill()
                return BridgeResponse(id: request.id, ok: true, result: nil, error: nil)
            },
            projectPanelList: { _, _, completion in completion(true) },
            removeWorkspaceRoutes: { workspaceID in
                removedWorkspaces.append(workspaceID)
                cleaned.fulfill()
            },
            debounceInterval: 0,
            retryDelays: []
        )

        reconciler.observe(panelEvent(eventID: "event-workspace-closed",
                                      kind: .workspaceClosed,
                                      ordinaryTmux: true))

        wait(for: [cleaned, requested], timeout: 0.15)
        XCTAssertEqual(removedWorkspaces.snapshot, ["workspace-video"])
    }

    func testRapidEventsDebouncePerWorkspaceAndFailuresRetryFinitely() {
        let attempts = Capture<Int>()
        let projected = expectation(description: "eventual projection")
        let reconciler = OrdinaryTmuxPaneIdentityReconciler(
            requestSender: { request in
                let attempt = attempts.snapshot.count + 1
                attempts.append(attempt)
                if attempt < 3 {
                    throw NSError(domain: "OrdinaryTmuxPaneIdentityReconcilerTests", code: attempt)
                }
                return BridgeResponse(id: request.id,
                                      ok: true,
                                      result: self.panelListResult(panelIDs: ["video-process-cc"]),
                                      error: nil)
            },
            projectPanelList: { _, _, completion in
                projected.fulfill()
                completion(true)
            },
            debounceInterval: 0.03,
            retryDelays: [0, 0]
        )

        reconciler.observe(panelEvent(eventID: "event-a", kind: .panelUpdated, ordinaryTmux: true))
        reconciler.observe(panelEvent(eventID: "event-b", kind: .panelUpdated, ordinaryTmux: true))
        reconciler.observe(panelEvent(eventID: "event-c", kind: .panelUpdated, ordinaryTmux: true))

        wait(for: [projected], timeout: 1)
        XCTAssertEqual(attempts.snapshot, [1, 2, 3],
                       "rapid events should share one debounced attempt sequence and stop after the configured retries")
    }

    func testRetriesStopAfterConfiguredLimit() {
        let attempts = Capture<Int>()
        let thirdAttempt = expectation(description: "third and final attempt")
        let reconciler = OrdinaryTmuxPaneIdentityReconciler(
            requestSender: { _ in
                let attempt = attempts.snapshot.count + 1
                attempts.append(attempt)
                if attempt == 3 {
                    thirdAttempt.fulfill()
                }
                throw NSError(domain: "OrdinaryTmuxPaneIdentityReconcilerTests", code: attempt)
            },
            projectPanelList: { _, _, completion in completion(true) },
            debounceInterval: 0,
            retryDelays: [0, 0]
        )

        reconciler.observe(panelEvent(eventID: "event-failing",
                                      kind: .panelUpdated,
                                      ordinaryTmux: true))

        wait(for: [thirdAttempt], timeout: 1)
        Thread.sleep(forTimeInterval: 0.05)
        XCTAssertEqual(attempts.snapshot, [1, 2, 3])
    }

    func testProjectionFailuresUseSameFiniteRetryBudget() {
        let requests = Capture<Int>()
        let projectionAttempts = Capture<Int>()
        let thirdProjection = expectation(description: "third projection succeeds")
        let reconciler = OrdinaryTmuxPaneIdentityReconciler(
            requestSender: { request in
                let attempt = requests.snapshot.count + 1
                requests.append(attempt)
                return BridgeResponse(id: request.id,
                                      ok: true,
                                      result: self.panelListResult(panelIDs: ["video-process-cc"]),
                                      error: nil)
            },
            projectPanelList: { _, _, completion in
                let attempt = projectionAttempts.snapshot.count + 1
                projectionAttempts.append(attempt)
                let succeeded = attempt == 3
                if succeeded {
                    thirdProjection.fulfill()
                }
                completion(succeeded)
            },
            debounceInterval: 0,
            retryDelays: [0, 0]
        )

        reconciler.observe(panelEvent(eventID: "event-projection-failing",
                                      kind: .panelUpdated,
                                      ordinaryTmux: true))

        wait(for: [thirdProjection], timeout: 1)
        XCTAssertEqual(requests.snapshot, [1, 2, 3])
        XCTAssertEqual(projectionAttempts.snapshot, [1, 2, 3],
                       "projection and pane-option write failures must consume the same finite retry budget as fetch failures")
    }

    private func panelEvent(eventID: String,
                            kind: WorkspaceEventKind,
                            ordinaryTmux: Bool,
                            includePanel: Bool = true,
                            panelID: String? = "carrier-video-cc") -> WorkspaceEvent {
        var panel: [String: JSONValue]?
        if includePanel, let panelID {
            panel = [
                "panel_id": .string(panelID),
                "workspace_id": .string("workspace-video"),
            ]
            if ordinaryTmux {
                panel?["ordinary_tmux"] = .object([
                    "client_tty": .string("/dev/ttys030"),
                    "target_session": .string("video-process-cc"),
                ])
            }
        }
        return WorkspaceEvent(eventID: eventID,
                              seq: 1,
                              timestamp: "2026-07-22T02:00:00Z",
                              kind: kind,
                              windowGUID: "window-1",
                              workspaceID: "workspace-video",
                              panelID: panelID,
                              workspace: nil,
                              panel: panel)
    }

    private func seedRegistry(_ registry: OrdinaryTmuxPanelRegistry) throws -> OrdinaryTmuxLogicalPanelID {
        let socketPath = "/tmp/tmux-\(getuid())/default"
        let panelID = OrdinaryTmuxCLIAdapter.stablePanelID(socketComponent: socketPath,
                                                           sessionID: "$7",
                                                           windowID: "@16")
        let route = OrdinaryTmuxPanelRoute(workspaceID: "workspace-video",
                                           panelID: panelID,
                                           carrierPanelID: "carrier-video-cc",
                                           socket: .path(socketPath),
                                           sessionID: "$7",
                                           sessionName: "video-process-cc",
                                           windowID: "@16",
                                           windowIndex: 0,
                                           activePaneID: "%16",
                                           cwd: nil,
                                           currentCommand: "codex")
        registry.replaceRoutes(workspaceID: route.workspaceID, routes: [route])
        return try XCTUnwrap(OrdinaryTmuxLogicalPanelID(rawValue: panelID))
    }

    private func panelListResult(panelIDs: [String]) -> [String: JSONValue] {
        [
            "workspace_id": .string("workspace-video"),
            "panels": .array(panelIDs.map { panelID in
                .object([
                    "panel_id": .string(panelID),
                    "workspace_id": .string("workspace-video"),
                ])
            }),
        ]
    }
}
