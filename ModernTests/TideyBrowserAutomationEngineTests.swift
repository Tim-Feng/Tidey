import XCTest
import WebKit
@testable import iTerm2SharedARC

@MainActor
final class TideyBrowserAutomationEngineTests: XCTestCase {
    func testDownloadPolicyRecognizesAttachmentsAndNonDisplayableContent() throws {
        let url = try XCTUnwrap(URL(string: "https://fixture.invalid/file"))
        let attachment = try XCTUnwrap(HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: nil,
            headerFields: [
                "Content-Disposition": "attachment; filename=fixture.html",
                "Content-Type": "text/html",
            ]
        ))
        let archive = try XCTUnwrap(HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/zip"]
        ))
        let document = try XCTUnwrap(HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "text/html; charset=utf-8"]
        ))

        XCTAssertTrue(TideyBrowserDownloadPolicy.shouldDownload(attachment))
        XCTAssertTrue(TideyBrowserDownloadPolicy.shouldDownload(archive))
        XCTAssertFalse(TideyBrowserDownloadPolicy.shouldDownload(document))
    }

    func testNavigationEpochAndSnapshotSeam() throws {
        let engine = TideyBrowserEngine(configuration: WKWebViewConfiguration())

        XCTAssertEqual(engine.automationNavigationEpoch, 0)
        XCTAssertEqual(
            TideyBrowserAutomationScript.contentWorld.name,
            "com.tidey.browser-automation"
        )
        let source = try TideyBrowserAutomationScript.source()
        XCTAssertTrue(source.contains("tideyBrowserAutomation"))
        XCTAssertTrue(source.contains("snapshot"))
    }

    func testSnapshotAndElementActionsUseEpochScopedReferences() async throws {
        let engine = TideyBrowserEngine(configuration: WKWebViewConfiguration())
        engine.webView.setFrameSize(NSSize(width: 800, height: 600))
        try await load(
            """
            <!doctype html><title>Fixture</title>
            <button id="button" onclick="document.querySelector('#result').textContent='clicked'">Run</button>
            <input id="name" aria-label="Name">
            <div id="result">idle</div>
            """,
            into: engine
        )

        let snapshot = try await engine.automationSnapshot(tabID: "tab-1")
        XCTAssertEqual(snapshot["title"] as? String, "Fixture")
        XCTAssertTrue((snapshot["text"] as? String)?.contains("idle") == true)
        let elements = try XCTUnwrap(snapshot["elements"] as? [[String: Any]])
        let button = try XCTUnwrap(elements.first { $0["text"] as? String == "Run" })
        let input = try XCTUnwrap(elements.first { $0["name"] as? String == "Name" })
        let epoch = try XCTUnwrap(snapshot["navigation_epoch"] as? Int)

        try await engine.automationClick(
            TideyBrowserAutomationElementReference(
                tabID: "tab-1",
                navigationEpoch: epoch,
                elementID: try XCTUnwrap(button["element_id"] as? String)
            )
        )
        try await engine.automationFill(
            TideyBrowserAutomationElementReference(
                tabID: "tab-1",
                navigationEpoch: epoch,
                elementID: try XCTUnwrap(input["element_id"] as? String)
            ),
            text: "Tim"
        )
        try await engine.automationType(
            TideyBrowserAutomationElementReference(
                tabID: "tab-1",
                navigationEpoch: epoch,
                elementID: try XCTUnwrap(input["element_id"] as? String)
            ),
            text: " Feng"
        )

        let changed = try await engine.automationSnapshot(tabID: "tab-1")
        XCTAssertTrue((changed["text"] as? String)?.contains("clicked") == true)
        let changedElements = try XCTUnwrap(changed["elements"] as? [[String: Any]])
        XCTAssertEqual(changedElements.first { $0["name"] as? String == "Name" }?["value"] as? String,
                       "Tim Feng")
    }

    func testElementReferenceExpiresAfterNavigationCommit() async throws {
        let engine = TideyBrowserEngine(configuration: WKWebViewConfiguration())
        try await load("<button>Old</button>", into: engine)
        let snapshot = try await engine.automationSnapshot(tabID: "tab-1")
        let oldEpoch = try XCTUnwrap(snapshot["navigation_epoch"] as? Int)
        let elements = try XCTUnwrap(snapshot["elements"] as? [[String: Any]])
        let elementID = try XCTUnwrap(elements.first?["element_id"] as? String)

        try await load("<button>New</button>", into: engine)
        XCTAssertNotEqual(engine.automationNavigationEpoch, oldEpoch)

        do {
            try await engine.automationClick(
                TideyBrowserAutomationElementReference(
                    tabID: "tab-1",
                    navigationEpoch: oldEpoch,
                    elementID: elementID
                )
            )
            XCTFail("Expected stale reference")
        } catch let error as TideyBrowserAutomationProtocolError {
            XCTAssertEqual(error.code, .staleReference)
        }
    }

    func testWaitAndScreenshotAreBoundedEngineOperations() async throws {
        let engine = TideyBrowserEngine(configuration: WKWebViewConfiguration())
        engine.webView.setFrameSize(NSSize(width: 320, height: 240))
        try await load("<div>Ready</div>", into: engine)

        try await engine.automationWait(.text("Ready", timeout: 1))
        try await engine.automationWait(.load(timeout: 1))
        try await engine.automationWait(.delay(milliseconds: 1))

        let png = try await engine.automationScreenshotPNG()
        XCTAssertEqual(Array(png.prefix(8)), [137, 80, 78, 71, 13, 10, 26, 10])

        do {
            try await engine.automationWait(.text("Missing", timeout: 0.05))
            XCTFail("Expected timeout")
        } catch let error as TideyBrowserAutomationProtocolError {
            XCTAssertEqual(error.code, .timeout)
        }
    }

    private func load(_ html: String,
                      into engine: TideyBrowserEngine,
                      timeout: TimeInterval = 3) async throws {
        let previousEpoch = engine.automationNavigationEpoch
        engine.webView.loadHTMLString(html, baseURL: URL(string: "https://fixture.invalid/"))
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if engine.automationNavigationEpoch > previousEpoch && !engine.isLoading {
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("WebKit fixture did not finish loading")
    }
}
