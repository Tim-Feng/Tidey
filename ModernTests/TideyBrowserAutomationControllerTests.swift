import XCTest
import WebKit
@testable import iTerm2SharedARC

@MainActor
private final class TideyBrowserAutomationHostStub: NSObject, TideyBrowserAutomationHost {
    var visibleTabs: [[String: Any]] = []
    var enginesByTabID: [String: TideyBrowserEngine] = [:]
    var presentations: [(engine: TideyBrowserEngine, tabID: String, url: URL)] = []
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
}

final class TideyBrowserAutomationControllerTests: XCTestCase {
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
}
