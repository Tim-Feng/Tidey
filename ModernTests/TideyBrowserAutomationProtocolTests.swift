import XCTest
@testable import iTerm2SharedARC

final class TideyBrowserAutomationProtocolTests: XCTestCase {
    func testCommandAndErrorSeam() {
        let target = TideyBrowserAutomationElementReference(
            tabID: "tab-1",
            navigationEpoch: 7,
            elementID: "element-3"
        )
        let request = TideyBrowserAutomationRequest(
            workspaceID: "workspace-1",
            command: .click(target: target)
        )
        let response = TideyBrowserAutomationResponse(result: [
            "tab_id": .string("tab-1"),
            "navigation_epoch": .integer(7),
            "ok": .bool(true)
        ])

        XCTAssertEqual(request.command, .click(target: target))
        XCTAssertEqual(response.result["tab_id"], .string("tab-1"))
        XCTAssertEqual(
            TideyBrowserAutomationOperation.currentURL.rawValue,
            "current_url"
        )
        XCTAssertEqual(
            TideyBrowserAutomationErrorCode.staleReference.rawValue,
            "stale_reference"
        )
    }

    func testDecodesNavigationAndEpochScopedElementCommands() throws {
        let open = try TideyBrowserAutomationProtocol.decodeRequest(
            workspaceID: "workspace-1",
            operation: "open",
            parameters: ["url": "https://example.com/path"]
        )
        XCTAssertEqual(
            open.command,
            .open(url: try XCTUnwrap(URL(string: "https://example.com/path")))
        )

        let click = try TideyBrowserAutomationProtocol.decodeRequest(
            workspaceID: "workspace-1",
            operation: "click",
            parameters: [
                "tab_id": "tab-1",
                "navigation_epoch": 7,
                "element_id": "element-3"
            ]
        )
        XCTAssertEqual(
            click.command,
            .click(target: TideyBrowserAutomationElementReference(
                tabID: "tab-1",
                navigationEpoch: 7,
                elementID: "element-3"
            ))
        )

        let scroll = try TideyBrowserAutomationProtocol.decodeRequest(
            workspaceID: "workspace-1",
            operation: "scroll",
            parameters: ["tab_id": "tab-1", "delta_x": 12.5, "delta_y": 640]
        )
        XCTAssertEqual(scroll.command, .scroll(tabID: "tab-1", deltaX: 12.5, deltaY: 640))
    }

    func testDecodesScopedAuthenticatedTransferCommands() throws {
        let start = try TideyBrowserAutomationProtocol.decodeRequest(
            workspaceID: "workspace-1",
            operation: "transfer_start",
            parameters: [
                "tab_id": "tab-1",
                "navigation_epoch": 7,
                "element_id": "element-3",
                "archive_root": "/Volumes/External/Archive",
                "expected_volume_uuid": "volume-uuid",
                "destination_relative_path": "_incoming/item/attempt/file.zip.partial",
                "expected_total_bytes": 120_817_568,
                "resume_offset": 33_554_432,
                "if_range": "etag-1",
                "pause_after_bytes": 67_108_864,
            ]
        )
        XCTAssertEqual(
            start.command,
            .transferStart(TideyBrowserTransferStartRequest(
                target: TideyBrowserAutomationElementReference(
                    tabID: "tab-1",
                    navigationEpoch: 7,
                    elementID: "element-3"
                ),
                archiveRoot: "/Volumes/External/Archive",
                expectedVolumeUUID: "volume-uuid",
                destinationRelativePath: "_incoming/item/attempt/file.zip.partial",
                expectedTotalBytes: 120_817_568,
                resumeOffset: 33_554_432,
                ifRange: "etag-1",
                pauseAfterBytes: 67_108_864
            ))
        )

        XCTAssertEqual(
            try TideyBrowserAutomationProtocol.decodeRequest(
                workspaceID: "workspace-1",
                operation: "transfer_status",
                parameters: ["transfer_id": "transfer-1"]
            ).command,
            .transferStatus(transferID: "transfer-1")
        )
        XCTAssertEqual(
            try TideyBrowserAutomationProtocol.decodeRequest(
                workspaceID: "workspace-1",
                operation: "transfer_pause",
                parameters: ["transfer_id": "transfer-1"]
            ).command,
            .transferPause(transferID: "transfer-1")
        )

        var missingTotal = [
            "tab_id": "tab-1",
            "navigation_epoch": 7,
            "element_id": "element-3",
            "archive_root": "/Volumes/External/Archive",
            "expected_volume_uuid": "volume-uuid",
            "destination_relative_path": "_incoming/item/attempt/file.zip.partial",
        ] as [String: Any]
        assertProtocolError(
            code: .invalidRequest,
            operation: "transfer_start",
            parameters: missingTotal
        )
        missingTotal["expected_total_bytes"] = 0
        assertProtocolError(
            code: .invalidRequest,
            operation: "transfer_start",
            parameters: missingTotal
        )
    }

    func testDecodesPreflightAndRepresentationBinding() throws {
        let parameters: [String: Any] = [
            "tab_id": "tab-1",
            "navigation_epoch": 7,
            "element_id": "element-3",
            "archive_root": "/Volumes/External/Archive",
            "expected_volume_uuid": "volume-uuid",
            "destination_relative_path": "_incoming/item/attempt/file.zip.partial",
            "resume_offset": 33_554_432,
        ]
        XCTAssertEqual(
            try TideyBrowserAutomationProtocol.decodeRequest(
                workspaceID: "workspace-1",
                operation: "transfer_preflight",
                parameters: parameters
            ).command,
            .transferPreflight(TideyBrowserTransferPreflightRequest(
                target: TideyBrowserAutomationElementReference(
                    tabID: "tab-1",
                    navigationEpoch: 7,
                    elementID: "element-3"
                ),
                destination: TideyBrowserTransferDestinationRequest(
                    archiveRoot: "/Volumes/External/Archive",
                    expectedVolumeUUID: "volume-uuid",
                    destinationRelativePath: "_incoming/item/attempt/file.zip.partial",
                    resumeOffset: 33_554_432
                )
            ))
        )

        var start = parameters
        start["expected_total_bytes"] = 120_817_568
        start["representation_validator_kind"] = "strong_etag"
        start["representation_validator"] = "\"representation-1\""
        XCTAssertEqual(
            try TideyBrowserAutomationProtocol.decodeRequest(
                workspaceID: "workspace-1",
                operation: "transfer_start",
                parameters: start
            ).command,
            .transferStart(TideyBrowserTransferStartRequest(
                target: TideyBrowserAutomationElementReference(
                    tabID: "tab-1",
                    navigationEpoch: 7,
                    elementID: "element-3"
                ),
                archiveRoot: "/Volumes/External/Archive",
                expectedVolumeUUID: "volume-uuid",
                destinationRelativePath: "_incoming/item/attempt/file.zip.partial",
                expectedTotalBytes: 120_817_568,
                resumeOffset: 33_554_432,
                ifRange: nil,
                pauseAfterBytes: nil,
                representationBinding: TideyBrowserTransferRepresentationBinding(
                    exactTotalBytes: 120_817_568,
                    validatorKind: .strongETag,
                    validatorValue: "\"representation-1\""
                )
            ))
        )

        var weak = start
        weak["representation_validator_kind"] = "weak_etag"
        assertProtocolError(
            code: .invalidRequest,
            operation: "transfer_start",
            parameters: weak
        )
        var missingValue = start
        missingValue.removeValue(forKey: "representation_validator")
        assertProtocolError(
            code: .invalidRequest,
            operation: "transfer_start",
            parameters: missingValue
        )
    }

    func testRejectsMalformedUnsupportedAndUnsafeRequests() {
        assertProtocolError(
            code: .unsupportedOperation,
            operation: "execute_javascript",
            parameters: [:]
        )
        assertProtocolError(
            code: .unsupportedScheme,
            operation: "open",
            parameters: ["url": "file:///etc/passwd"]
        )
        assertProtocolError(
            code: .invalidURL,
            operation: "navigate",
            parameters: ["tab_id": "tab-1", "url": "https://"]
        )
        assertProtocolError(
            code: .invalidRequest,
            operation: "click",
            parameters: [
                "tab_id": "tab-1",
                "navigation_epoch": -1,
                "element_id": "element-3"
            ]
        )
        assertProtocolError(
            code: .invalidRequest,
            operation: "mark",
            parameters: ["tab_id": "tab-1", "mark": "forever"]
        )
        assertProtocolError(
            code: .invalidRequest,
            operation: "key",
            parameters: ["tab_id": "tab-1", "key": "F99"]
        )
        assertProtocolError(
            code: .invalidRequest,
            workspaceID: "",
            operation: "tabs",
            parameters: [:]
        )
    }

    func testDecodesBoundedWaitConditions() throws {
        let load = try TideyBrowserAutomationProtocol.decodeRequest(
            workspaceID: "workspace-1",
            operation: "wait",
            parameters: ["tab_id": "tab-1", "condition": "load", "timeout_ms": 2_500]
        )
        XCTAssertEqual(load.command, .wait(tabID: "tab-1", condition: .load(timeout: 2.5)))

        let delay = try TideyBrowserAutomationProtocol.decodeRequest(
            workspaceID: "workspace-1",
            operation: "wait",
            parameters: ["tab_id": "tab-1", "condition": "delay", "milliseconds": 250]
        )
        XCTAssertEqual(delay.command, .wait(tabID: "tab-1", condition: .delay(milliseconds: 250)))

        let text = try TideyBrowserAutomationProtocol.decodeRequest(
            workspaceID: "workspace-1",
            operation: "wait",
            parameters: ["tab_id": "tab-1", "condition": "text", "value": "Ready"]
        )
        XCTAssertEqual(text.command, .wait(tabID: "tab-1", condition: .text("Ready", timeout: 10)))

        assertProtocolError(
            code: .invalidRequest,
            operation: "wait",
            parameters: ["tab_id": "tab-1", "condition": "delay", "milliseconds": 30_001]
        )
    }

    func testEncodesResponsesAndMapsOwnershipErrors() {
        let response = TideyBrowserAutomationResponse(result: [
            "ok": .bool(true),
            "tabs": .array([
                .object(["tab_id": .string("tab-1")])
            ])
        ])
        let dictionary = response.dictionary
        XCTAssertEqual(dictionary["ok"] as? Bool, true)
        XCTAssertEqual(
            ((dictionary["tabs"] as? [[String: Any]])?.first)?["tab_id"] as? String,
            "tab-1"
        )

        XCTAssertEqual(
            TideyBrowserAutomationProtocolError(stateError: .ownershipConflict).code,
            .ownershipConflict
        )
        XCTAssertEqual(
            TideyBrowserAutomationProtocolError(stateError: .workspaceMismatch).code,
            .workspaceMismatch
        )
        XCTAssertEqual(
            TideyBrowserAutomationProtocolError(stateError: .tabLimitReached).dictionary["code"] as? String,
            "tab_limit_reached"
        )
    }

    private func assertProtocolError(
        code: TideyBrowserAutomationErrorCode,
        workspaceID: String = "workspace-1",
        operation: String,
        parameters: [String: Any]
    ) {
        XCTAssertThrowsError(
            try TideyBrowserAutomationProtocol.decodeRequest(
                workspaceID: workspaceID,
                operation: operation,
                parameters: parameters
            )
        ) { error in
            XCTAssertEqual((error as? TideyBrowserAutomationProtocolError)?.code, code)
        }
    }
}
