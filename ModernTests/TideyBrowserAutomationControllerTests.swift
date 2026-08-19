import XCTest
import WebKit
@testable import iTerm2SharedARC

@MainActor
private final class TideyBrowserAutomationHostStub: NSObject, TideyBrowserAutomationHost {
    var visibleTabs: [[String: Any]] = []
    var enginesByTabID: [String: TideyBrowserEngine] = [:]
    var presentations: [(engine: TideyBrowserEngine, tabID: String, url: URL)] = []
    var closedTabIDs: [String] = []
    var allowsPresentation = true

    func browserEngine(_ engine: TideyBrowserEngine,
                       didUpdateState state: TideyBrowserEngineState) {
    }

    func browserEngine(_ engine: TideyBrowserEngine,
                       requestPopup request: TideyBrowserPopupRequest) {
    }

    func browserAutomationVisibleTabs() -> [[String: Any]] {
        visibleTabs
    }

    func browserAutomationEngine(forTabID tabID: String) -> TideyBrowserEngine? {
        enginesByTabID[tabID]
    }

    func browserAutomationPresent(engine: TideyBrowserEngine,
                                  tabID: String,
                                  initialURL: URL) -> Bool {
        guard allowsPresentation else {
            return false
        }
        presentations.append((engine, tabID, initialURL))
        enginesByTabID[tabID] = engine
        visibleTabs.append(["tab_id": tabID, "url": initialURL.absoluteString])
        return true
    }

    func browserAutomationClose(tabID: String) -> Bool {
        guard enginesByTabID.removeValue(forKey: tabID) != nil else {
            return false
        }
        visibleTabs.removeAll { $0["tab_id"] as? String == tabID }
        closedTabIDs.append(tabID)
        return true
    }
}

final class TideyBrowserAutomationControllerTests: XCTestCase {
    @MainActor
    func testOpenWaitsForNavigationCapacityBeforeCreatingPrivateEngine() async throws {
        let host = TideyBrowserAutomationHostStub()
        let gate = TideyBrowserNavigationGate(
            maximumConcurrent: 1,
            maximumPerOrigin: 1,
            maximumQueued: 1
        )
        let blockingPermit = try await gate.acquire(origin: "https://blocking.example")
        let controller = TideyBrowserAutomationController(
            host: host,
            tabIDGenerator: { "private-tab-1" },
            engineFactory: { TideyBrowserEngine(configuration: $0) },
            navigationGate: gate
        )

        let openTask = Task { @MainActor in
            try await controller.handle(
                request: TideyBrowserAutomationRequest(
                    workspaceID: "workspace-1",
                    command: .open(url: try XCTUnwrap(URL(string: "http://127.0.0.1:1/private")))
                ),
                ownerSessionID: "session-1"
            )
        }
        let deadline = Date().addingTimeInterval(1)
        while Date() < deadline {
            if await gate.snapshot().queuedCount > 0 {
                break
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let queuedSnapshot = await gate.snapshot()
        XCTAssertEqual(queuedSnapshot.queuedCount, 1)
        XCTAssertTrue(controller.privateEnginesByID.isEmpty)

        await gate.release(blockingPermit)
        _ = try await openTask.value
        XCTAssertNotNil(controller.privateEnginesByID["private-tab-1"])
    }

    @MainActor
    func testControllerOwnershipSeam() {
        let host = TideyBrowserAutomationHostStub()
        let controller = TideyBrowserAutomationController(
            host: host,
            maxPrivateTabs: 8,
            handoffTTL: 1_800
        )

        XCTAssertTrue(controller.host === host)
        XCTAssertEqual(controller.state.maxPrivateTabs, 8)
        XCTAssertEqual(controller.state.handoffTTL, 1_800)
        XCTAssertTrue(controller.privateEnginesByID.isEmpty)
    }

    @MainActor
    func testPrivateOpenStaysHiddenUntilExplicitPresentation() throws {
        let host = TideyBrowserAutomationHostStub()
        var generatedIDs = ["private-tab-1"]
        let controller = TideyBrowserAutomationController(
            host: host,
            tabIDGenerator: { generatedIDs.removeFirst() },
            engineFactory: { configuration in
                TideyBrowserEngine(configuration: configuration)
            }
        )
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:1/private"))

        let tabID = try controller.openPrivate(
            url: url,
            workspaceID: "workspace-1",
            ownerSessionID: "session-1"
        )

        XCTAssertEqual(tabID, "private-tab-1")
        XCTAssertTrue(host.visibleTabs.isEmpty)
        XCTAssertTrue(host.presentations.isEmpty)
        let privateEngine = try XCTUnwrap(controller.privateEnginesByID[tabID])

        try controller.presentPrivate(
            tabID: tabID,
            workspaceID: "workspace-1",
            ownerSessionID: "session-1"
        )

        XCTAssertEqual(host.presentations.count, 1)
        XCTAssertTrue(host.presentations[0].engine === privateEngine)
        XCTAssertEqual(host.presentations[0].tabID, tabID)
        XCTAssertNil(controller.privateEnginesByID[tabID])
        XCTAssertNil(controller.state.privateTabsByID[tabID])
    }

    @MainActor
    func testFailedPresentationKeepsPrivateIdentityOwned() throws {
        let host = TideyBrowserAutomationHostStub()
        host.allowsPresentation = false
        let controller = TideyBrowserAutomationController(
            host: host,
            tabIDGenerator: { "private-tab-1" },
            engineFactory: { TideyBrowserEngine(configuration: $0) }
        )
        let tabID = try controller.openPrivate(
            url: try XCTUnwrap(URL(string: "http://127.0.0.1:1/private")),
            workspaceID: "workspace-1",
            ownerSessionID: "session-1"
        )
        let engine = controller.privateEnginesByID[tabID]

        XCTAssertThrowsError(
            try controller.presentPrivate(
                tabID: tabID,
                workspaceID: "workspace-1",
                ownerSessionID: "session-1"
            )
        ) { error in
            XCTAssertEqual((error as? TideyBrowserAutomationProtocolError)?.code, .targetGone)
        }
        XCTAssertTrue(controller.privateEnginesByID[tabID] === engine)
        XCTAssertEqual(controller.state.privateTabsByID[tabID]?.ownerSessionID, "session-1")
    }

    @MainActor
    func testPopupFromPrivateEngineCreatesAnotherHiddenOwnedTab() throws {
        let host = TideyBrowserAutomationHostStub()
        var generatedIDs = ["parent-tab", "popup-tab"]
        let controller = TideyBrowserAutomationController(
            host: host,
            tabIDGenerator: { generatedIDs.removeFirst() },
            engineFactory: { TideyBrowserEngine(configuration: $0) }
        )
        let parentID = try controller.openPrivate(
            url: try XCTUnwrap(URL(string: "http://127.0.0.1:1/parent")),
            workspaceID: "workspace-1",
            ownerSessionID: "session-1"
        )
        let parentEngine = try XCTUnwrap(controller.privateEnginesByID[parentID])

        controller.browserEngine(
            parentEngine,
            requestPopup: TideyBrowserPopupRequest(
                url: try XCTUnwrap(URL(string: "http://127.0.0.1:1/popup")),
                configuration: WKWebViewConfiguration(),
                opensInNewBrowsingContext: true
            )
        )

        XCTAssertEqual(Set(controller.privateEnginesByID.keys), ["parent-tab", "popup-tab"])
        XCTAssertEqual(controller.state.privateTabsByID["popup-tab"]?.workspaceID, "workspace-1")
        XCTAssertEqual(controller.state.privateTabsByID["popup-tab"]?.ownerSessionID, "session-1")
        XCTAssertTrue(host.visibleTabs.isEmpty)
        XCTAssertTrue(host.presentations.isEmpty)
    }

    @MainActor
    func testCommandRoutingRequiresAtomicClaimForVisibleTab() async throws {
        let host = TideyBrowserAutomationHostStub()
        let engine = TideyBrowserEngine(configuration: WKWebViewConfiguration())
        host.enginesByTabID["visible-1"] = engine
        host.visibleTabs = [["tab_id": "visible-1", "url": "https://example.com/"]]
        let controller = TideyBrowserAutomationController(host: host)

        _ = try await controller.handle(
            request: TideyBrowserAutomationRequest(
                workspaceID: "workspace-1",
                command: .claim(tabID: "visible-1")
            ),
            ownerSessionID: "session-1"
        )

        do {
            _ = try await controller.handle(
                request: TideyBrowserAutomationRequest(
                    workspaceID: "workspace-1",
                    command: .claim(tabID: "visible-1")
                ),
                ownerSessionID: "session-2"
            )
            XCTFail("Expected ownership conflict")
        } catch let error as TideyBrowserAutomationProtocolError {
            XCTAssertEqual(error.code, .ownershipConflict)
        }

        _ = try await controller.handle(
            request: TideyBrowserAutomationRequest(
                workspaceID: "workspace-1",
                command: .release(tabID: "visible-1")
            ),
            ownerSessionID: "session-1"
        )
        _ = try await controller.handle(
            request: TideyBrowserAutomationRequest(
                workspaceID: "workspace-1",
                command: .claim(tabID: "visible-1")
            ),
            ownerSessionID: "session-2"
        )
        XCTAssertEqual(controller.state.userClaimsByTabID["visible-1"]?.ownerSessionID,
                       "session-2")
    }

    @MainActor
    func testDisconnectClosesUnmarkedAdoptsDeliverableAndRetainsHandoff() async throws {
        let host = TideyBrowserAutomationHostStub()
        var generatedIDs = ["discard", "deliver", "handoff"]
        let controller = TideyBrowserAutomationController(
            host: host,
            handoffTTL: 60,
            tabIDGenerator: { generatedIDs.removeFirst() },
            engineFactory: { TideyBrowserEngine(configuration: $0) }
        )
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:1/private"))
        for _ in 0..<3 {
            _ = try controller.openPrivate(
                url: url,
                workspaceID: "workspace-1",
                ownerSessionID: "session-1"
            )
        }
        _ = try await controller.handle(
            request: TideyBrowserAutomationRequest(
                workspaceID: "workspace-1",
                command: .mark(tabID: "deliver", mark: .deliverable)
            ),
            ownerSessionID: "session-1"
        )
        _ = try await controller.handle(
            request: TideyBrowserAutomationRequest(
                workspaceID: "workspace-1",
                command: .mark(tabID: "handoff", mark: .handoff)
            ),
            ownerSessionID: "session-1"
        )

        controller.cleanupSession(ownerSessionID: "session-1", now: Date(timeIntervalSince1970: 100))

        XCTAssertNil(controller.privateEnginesByID["discard"])
        XCTAssertNil(controller.privateEnginesByID["deliver"])
        XCTAssertNotNil(controller.privateEnginesByID["handoff"])
        XCTAssertEqual(host.presentations.map(\.tabID), ["deliver"])
        XCTAssertNil(controller.state.privateTabsByID["handoff"]?.ownerSessionID)
        XCTAssertEqual(
            controller.state.privateTabsByID["handoff"]?.handoffExpiresAt,
            Date(timeIntervalSince1970: 160)
        )
    }
}
