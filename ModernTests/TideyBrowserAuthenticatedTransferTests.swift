import XCTest
@testable import iTerm2SharedARC

final class TideyBrowserAuthenticatedTransferTests: XCTestCase {
    func testAcceptsOnlyOfficialSameOriginVaultLinksWithoutSecrets() throws {
        let page = try XCTUnwrap(URL(string: "https://studio.blender.org/vault/browse/wing-it/"))
        XCTAssertEqual(
            try TideyBrowserTransferRouteValidator.sourceURL(
                pageURL: page,
                href: "/vault/browse/wing-it/wing_it-caches.zip"
            ).absoluteString,
            "https://studio.blender.org/vault/browse/wing-it/wing_it-caches.zip"
        )

        for href in [
            "https://example.com/vault/browse/wing-it/file.zip",
            "https://studio.blender.org/films/wing-it/file.zip",
            "https://studio.blender.org/vault/browse/wing-it/file.zip?token=secret",
            "https://user:secret@studio.blender.org/vault/browse/wing-it/file.zip",
            "javascript:alert(1)",
        ] {
            XCTAssertThrowsError(
                try TideyBrowserTransferRouteValidator.sourceURL(pageURL: page, href: href),
                "Expected rejection for \(href)"
            )
        }
    }

    func testValidatesRootRelativePartialDestination() throws {
        XCTAssertEqual(
            try TideyBrowserTransferRouteValidator.destinationComponents(
                "_incoming/item-1/attempt-1/file.zip.partial"
            ),
            ["_incoming", "item-1", "attempt-1", "file.zip.partial"]
        )

        for path in [
            "", "/tmp/file.partial", "../file.partial", "_incoming/../file.partial",
            "_incoming//file.partial", "_incoming/file.zip", "_incoming\\file.partial",
        ] {
            XCTAssertThrowsError(
                try TideyBrowserTransferRouteValidator.destinationComponents(path),
                "Expected rejection for \(path)"
            )
        }
    }

    func testResponsePolicyHandlesFreshResumeAndUnsatisfiedRange() throws {
        XCTAssertEqual(
            try TideyBrowserTransferResponsePolicy.evaluate(
                statusCode: 200,
                resumeOffset: 0,
                headers: ["Content-Length": "120817568"]
            ),
            .fresh(expectedTotal: 120817568)
        )
        XCTAssertEqual(
            try TideyBrowserTransferResponsePolicy.evaluate(
                statusCode: 206,
                resumeOffset: 33_554_432,
                headers: ["Content-Range": "bytes 33554432-120817567/120817568"]
            ),
            .resumed(expectedTotal: 120817568)
        )
        XCTAssertEqual(
            try TideyBrowserTransferResponsePolicy.evaluate(
                statusCode: 416,
                resumeOffset: 120_817_568,
                headers: ["Content-Range": "bytes */120817568"]
            ),
            .rangeNotSatisfiable(remoteTotal: 120817568)
        )

        XCTAssertThrowsError(
            try TideyBrowserTransferResponsePolicy.evaluate(
                statusCode: 200,
                resumeOffset: 1,
                headers: ["Content-Length": "10"]
            )
        )
        XCTAssertThrowsError(
            try TideyBrowserTransferResponsePolicy.evaluate(
                statusCode: 206,
                resumeOffset: 5,
                headers: ["Content-Range": "bytes 4-9/10"]
            )
        )
        XCTAssertThrowsError(
            try TideyBrowserTransferResponsePolicy.evaluate(
                statusCode: 302,
                resumeOffset: 0,
                headers: [:]
            )
        )
    }

    func testRedactionNeverReturnsQueryCredentialsOrAuthorizationValues() throws {
        let url = try XCTUnwrap(URL(string: "https://user:password@studio.blender.org/vault/browse/a.zip?token=secret#fragment"))
        let redacted = TideyBrowserTransferRedaction.url(url)
        XCTAssertEqual(redacted, "https://studio.blender.org/vault/browse/a.zip")
        XCTAssertFalse(redacted.contains("secret"))
        XCTAssertFalse(redacted.contains("password"))

        let message = TideyBrowserTransferRedaction.message(
            "Authorization: Bearer top-secret Cookie: session=private https://example.com/a?token=secret"
        )
        XCTAssertFalse(message.lowercased().contains("bearer"))
        XCTAssertFalse(message.contains("top-secret"))
        XCTAssertFalse(message.contains("session=private"))
        XCTAssertFalse(message.contains("token=secret"))
    }
}
