import XCTest
@testable import iTerm2SharedARC

final class TideyBrowserAuthenticatedTransferTests: XCTestCase {
    func testPreflightFallsBackAndCancelsRangeProbeBeforeBody() async throws {
        let sourceURL = try XCTUnwrap(URL(
            string: "https://studio.blender.org/vault/browse/wing_it/wing_it-caches.zip"
        ))
        let probe = StubHeaderProbe(responses: [
            TideyBrowserTransferHeaderProbeResponse(
                statusCode: 405,
                headers: [:],
                redirectProvenance: [sourceURL.absoluteString],
                cancelledBeforeBody: true
            ),
            TideyBrowserTransferHeaderProbeResponse(
                statusCode: 206,
                headers: [
                    "Content-Range": "bytes 0-0/120817568",
                    "Content-Encoding": "identity",
                    "ETag": "\"representation-1\"",
                ],
                redirectProvenance: [sourceURL.absoluteString],
                cancelledBeforeBody: true
            ),
        ])
        let executor = TideyBrowserTransferPreflightExecutor(headerProbe: probe)

        let metadata = try await executor.execute(sourceURL: sourceURL, cookies: [])

        XCTAssertEqual(metadata.exactTotalBytes, 120_817_568)
        XCTAssertEqual(metadata.method, .range)
        XCTAssertEqual(metadata.statusCode, 206)
        XCTAssertEqual(probe.requests.count, 2)
        XCTAssertEqual(probe.requests[0].httpMethod, "HEAD")
        XCTAssertEqual(probe.requests[0].value(forHTTPHeaderField: "Accept-Encoding"), "identity")
        XCTAssertEqual(probe.requests[1].httpMethod, "GET")
        XCTAssertEqual(probe.requests[1].value(forHTTPHeaderField: "Range"), "bytes=0-0")
        XCTAssertEqual(probe.requests[1].value(forHTTPHeaderField: "Accept-Encoding"), "identity")

        let fullBodyProbe = StubHeaderProbe(responses: [
            TideyBrowserTransferHeaderProbeResponse(
                statusCode: 405,
                headers: [:],
                redirectProvenance: [],
                cancelledBeforeBody: true
            ),
            TideyBrowserTransferHeaderProbeResponse(
                statusCode: 200,
                headers: ["Content-Length": "120817568"],
                redirectProvenance: [],
                cancelledBeforeBody: true
            ),
        ])
        do {
            _ = try await TideyBrowserTransferPreflightExecutor(headerProbe: fullBodyProbe)
                .execute(sourceURL: sourceURL, cookies: [])
            XCTFail("Expected a Range probe that returned 200 to be rejected")
        } catch let failure as TideyBrowserTransferFailure {
            XCTAssertEqual(failure.category, .invalidRange)
            XCTAssertEqual(failure.code, "range_not_honored")
        }
        XCTAssertTrue(fullBodyProbe.responsesWereCancelledBeforeBody)

        let encodedProbe = StubHeaderProbe(responses: [
            TideyBrowserTransferHeaderProbeResponse(
                statusCode: 200,
                headers: ["Content-Length": "120817568", "Content-Encoding": "gzip"],
                redirectProvenance: [],
                cancelledBeforeBody: true
            ),
            TideyBrowserTransferHeaderProbeResponse(
                statusCode: 206,
                headers: [
                    "Content-Range": "bytes 0-0/120817568",
                    "Content-Encoding": "gzip",
                ],
                redirectProvenance: [],
                cancelledBeforeBody: true
            ),
        ])
        do {
            _ = try await TideyBrowserTransferPreflightExecutor(headerProbe: encodedProbe)
                .execute(sourceURL: sourceURL, cookies: [])
            XCTFail("Expected encoded representation refusal")
        } catch let failure as TideyBrowserTransferFailure {
            XCTAssertEqual(failure.category, .validation)
            XCTAssertEqual(failure.code, "identity_encoding_required")
        }
    }

    func testPreflightAcceptsExactHeadMetadata() throws {
        let decision = try TideyBrowserTransferPreflightPolicy.evaluateHEAD(
            statusCode: 200,
            headers: [
                "Content-Length": "120817568",
                "Content-Encoding": "identity",
                "Content-Type": "application/zip",
                "Content-Disposition": "attachment; filename=\"wing_it-caches.zip\"",
                "Accept-Ranges": "bytes",
                "ETag": "\"representation-1\"",
                "Last-Modified": "Fri, 21 Aug 2026 08:00:00 GMT",
            ],
            redirectProvenance: [
                "https://studio.blender.org/vault/browse/wing_it/wing_it-caches.zip",
                "https://cdn.example.test/download/wing_it-caches.zip?token=secret#fragment",
            ]
        )

        guard case .accept(let metadata) = decision else {
            return XCTFail("Expected exact HEAD metadata")
        }
        XCTAssertEqual(metadata.exactTotalBytes, 120_817_568)
        XCTAssertEqual(metadata.method, .head)
        XCTAssertEqual(metadata.statusCode, 200)
        XCTAssertEqual(metadata.contentEncoding, "identity")
        XCTAssertEqual(metadata.contentType, "application/zip")
        XCTAssertEqual(metadata.filename, "wing_it-caches.zip")
        XCTAssertEqual(metadata.acceptRanges, "bytes")
        XCTAssertEqual(metadata.etag, "\"representation-1\"")
        XCTAssertEqual(metadata.etagClassification, .strongETag)
        XCTAssertEqual(metadata.lastModified, "Fri, 21 Aug 2026 08:00:00 GMT")
        XCTAssertEqual(metadata.resumeValidatorKind, .strongETag)
        XCTAssertEqual(metadata.resumeValidatorValue, "\"representation-1\"")
        XCTAssertEqual(metadata.redirectProvenance, [
            "https://studio.blender.org/vault/browse/wing_it/wing_it-caches.zip",
            "https://cdn.example.test/download/wing_it-caches.zip",
        ])
        XCTAssertFalse(String(describing: metadata.dictionary).contains("secret"))
    }

    func testPreflightValidatorClassifications() throws {
        let weakWithDate = try acceptedHeadMetadata(headers: [
            "Content-Length": "10",
            "ETag": "W/\"weak-1\"",
            "Last-Modified": "Fri, 21 Aug 2026 08:00:00 GMT",
        ])
        XCTAssertEqual(weakWithDate.etagClassification, .weakETag)
        XCTAssertEqual(weakWithDate.resumeValidatorKind, .lastModified)
        XCTAssertEqual(weakWithDate.resumeValidatorValue, "Fri, 21 Aug 2026 08:00:00 GMT")

        let lastModifiedOnly = try acceptedHeadMetadata(headers: [
            "Content-Length": "10",
            "Last-Modified": "Fri, 21 Aug 2026 08:00:00 GMT",
        ])
        XCTAssertEqual(lastModifiedOnly.etagClassification, .unavailable)
        XCTAssertEqual(lastModifiedOnly.resumeValidatorKind, .lastModified)

        let noValidator = try acceptedHeadMetadata(headers: [
            "Content-Length": "10",
            "ETag": "not-an-http-etag",
            "Last-Modified": "not-an-http-date",
        ])
        XCTAssertNil(noValidator.etag)
        XCTAssertNil(noValidator.lastModified)
        XCTAssertEqual(noValidator.resumeValidatorKind, .unavailable)
        XCTAssertNil(noValidator.resumeValidatorValue)
    }

    func testDiskInspectionTargetsContainingVolume() {
        XCTAssertEqual(
            TideyBrowserTransferDiskInspector.inspectionTarget(
                archiveRoot: "/Volumes/My Book/BlenderStudioVaultArchive-v01",
                containingMountPoint: "/Volumes/My Book"
            ),
            "/Volumes/My Book"
        )
    }

    @MainActor
    func testDestinationOpeningExecutorLeavesMainActor() async throws {
        enum Expected: Error {
            case stopped
        }
        let executor = TideyBrowserTransferDestinationOpeningExecutor { _ in
            XCTAssertFalse(Thread.isMainThread)
            throw Expected.stopped
        }
        let manager = TideyBrowserAuthenticatedTransferManager(destinationOpener: executor)

        do {
            _ = try await manager.openDestination(makeTransferRequest())
            XCTFail("Expected the test opener to stop")
        } catch Expected.stopped {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

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
                expectedTotalBytes: 120_817_568,
                headers: ["Content-Length": "120817568"]
            ),
            .fresh(expectedTotal: 120817568)
        )
        XCTAssertEqual(
            try TideyBrowserTransferResponsePolicy.evaluate(
                statusCode: 206,
                resumeOffset: 33_554_432,
                expectedTotalBytes: 120_817_568,
                headers: ["Content-Range": "bytes 33554432-120817567/120817568"]
            ),
            .resumed(expectedTotal: 120817568)
        )
        XCTAssertEqual(
            try TideyBrowserTransferResponsePolicy.evaluate(
                statusCode: 416,
                resumeOffset: 120_817_568,
                expectedTotalBytes: 120_817_568,
                headers: ["Content-Range": "bytes */120817568"]
            ),
            .rangeNotSatisfiable(remoteTotal: 120817568)
        )

        XCTAssertThrowsError(
            try TideyBrowserTransferResponsePolicy.evaluate(
                statusCode: 200,
                resumeOffset: 1,
                expectedTotalBytes: 10,
                headers: ["Content-Length": "10"]
            )
        )
        XCTAssertThrowsError(
            try TideyBrowserTransferResponsePolicy.evaluate(
                statusCode: 206,
                resumeOffset: 5,
                expectedTotalBytes: 10,
                headers: ["Content-Range": "bytes 4-9/10"]
            )
        )
        XCTAssertThrowsError(
            try TideyBrowserTransferResponsePolicy.evaluate(
                statusCode: 302,
                resumeOffset: 0,
                expectedTotalBytes: 10,
                headers: [:]
            )
        )
    }

    func testResponsePolicyRejectsServerTotalMismatch() throws {
        XCTAssertThrowsError(
            try TideyBrowserTransferResponsePolicy.evaluate(
                statusCode: 200,
                resumeOffset: 0,
                expectedTotalBytes: 10,
                headers: ["Content-Length": "11"]
            )
        )
        XCTAssertThrowsError(
            try TideyBrowserTransferResponsePolicy.evaluate(
                statusCode: 206,
                resumeOffset: 4,
                expectedTotalBytes: 10,
                headers: ["Content-Range": "bytes 4-10/11"]
            )
        )
        XCTAssertThrowsError(
            try TideyBrowserTransferResponsePolicy.evaluate(
                statusCode: 416,
                resumeOffset: 10,
                expectedTotalBytes: 10,
                headers: ["Content-Range": "bytes */11"]
            )
        )
    }

    func testResponsePolicyBindsTotalEncodingAndValidator() throws {
        let binding = TideyBrowserTransferRepresentationBinding(
            exactTotalBytes: 10,
            validatorKind: .strongETag,
            validatorValue: "\"representation-1\""
        )
        XCTAssertEqual(
            try TideyBrowserTransferResponsePolicy.evaluate(
                statusCode: 200,
                resumeOffset: 0,
                expectedTotalBytes: 10,
                headers: [
                    "Content-Length": "10",
                    "Content-Encoding": "identity",
                    "ETag": "\"representation-1\"",
                ],
                representationBinding: binding
            ),
            .fresh(expectedTotal: 10)
        )
        XCTAssertEqual(
            try TideyBrowserTransferResponsePolicy.evaluate(
                statusCode: 206,
                resumeOffset: 4,
                expectedTotalBytes: 10,
                headers: [
                    "Content-Range": "bytes 4-9/10",
                    "ETag": "\"representation-1\"",
                ],
                representationBinding: binding
            ),
            .resumed(expectedTotal: 10)
        )
        XCTAssertEqual(
            try TideyBrowserTransferResponsePolicy.evaluate(
                statusCode: 416,
                resumeOffset: 10,
                expectedTotalBytes: 10,
                headers: [
                    "Content-Range": "bytes */10",
                    "ETag": "\"representation-1\"",
                ],
                representationBinding: binding
            ),
            .rangeNotSatisfiable(remoteTotal: 10)
        )
        XCTAssertThrowsError(try TideyBrowserTransferResponsePolicy.evaluate(
            statusCode: 416,
            resumeOffset: 4,
            expectedTotalBytes: 10,
            headers: [
                "Content-Range": "bytes */10",
                "ETag": "\"representation-1\"",
            ],
            representationBinding: binding
        )) { error in
            XCTAssertEqual((error as? TideyBrowserTransferFailure)?.category, .invalidRange)
        }

        for headers in [
            ["Content-Length": "11", "ETag": "\"representation-1\""],
            ["Content-Length": "10", "ETag": "\"representation-2\""],
            ["Content-Length": "10", "Content-Encoding": "gzip", "ETag": "\"representation-1\""],
        ] {
            XCTAssertThrowsError(
                try TideyBrowserTransferResponsePolicy.evaluate(
                    statusCode: 200,
                    resumeOffset: 0,
                    expectedTotalBytes: 10,
                    headers: headers,
                    representationBinding: binding
                )
            ) { error in
                XCTAssertEqual(
                    (error as? TideyBrowserTransferFailure)?.category,
                    .representationMismatch
                )
            }
        }

        let lastModifiedBinding = TideyBrowserTransferRepresentationBinding(
            exactTotalBytes: 10,
            validatorKind: .lastModified,
            validatorValue: "Fri, 21 Aug 2026 08:00:00 GMT"
        )
        XCTAssertNoThrow(try TideyBrowserTransferResponsePolicy.evaluate(
            statusCode: 206,
            resumeOffset: 4,
            expectedTotalBytes: 10,
            headers: [
                "Content-Range": "bytes 4-9/10",
                "Last-Modified": "Fri, 21 Aug 2026 08:00:00 GMT",
            ],
            representationBinding: lastModifiedBinding
        ))

        let malformedValidator = TideyBrowserTransferRepresentationBinding(
            exactTotalBytes: 10,
            validatorKind: .strongETag,
            validatorValue: "not-a-strong-etag"
        )
        XCTAssertThrowsError(try TideyBrowserTransferResponsePolicy.evaluate(
            statusCode: 200,
            resumeOffset: 0,
            expectedTotalBytes: 10,
            headers: ["Content-Length": "10", "ETag": "not-a-strong-etag"],
            representationBinding: malformedValidator
        )) { error in
            XCTAssertEqual(
                (error as? TideyBrowserTransferFailure)?.category,
                .representationMismatch
            )
        }
    }

    func testResponsePolicyClassifiesTransferFailures() throws {
        for status in [401, 403] {
            XCTAssertEqual(
                TideyBrowserTransferFailurePolicy.httpStatus(status).category,
                .authentication
            )
        }
        XCTAssertEqual(TideyBrowserTransferFailurePolicy.httpStatus(429).category, .rateLimited)
        XCTAssertEqual(TideyBrowserTransferFailurePolicy.httpStatus(503).category, .retryable)
        XCTAssertEqual(
            TideyBrowserTransferFailurePolicy.network(URLError(.networkConnectionLost)).category,
            .retryable
        )
        XCTAssertEqual(
            TideyBrowserTransferFailurePolicy.classify(
                TideyBrowserTransferValidationError.invalidDestination
            ).category,
            .destination
        )

        do {
            _ = try TideyBrowserTransferResponsePolicy.evaluate(
                statusCode: 206,
                resumeOffset: 4,
                expectedTotalBytes: 10,
                headers: ["Content-Range": "bytes malformed"]
            )
            XCTFail("Expected malformed Content-Range rejection")
        } catch let failure as TideyBrowserTransferFailure {
            XCTAssertEqual(failure.category, .invalidRange)
        }

        do {
            _ = try TideyBrowserTransferResponsePolicy.evaluate(
                statusCode: 503,
                resumeOffset: 0,
                expectedTotalBytes: 10,
                headers: [:]
            )
            XCTFail("Expected retryable HTTP failure")
        } catch let failure as TideyBrowserTransferFailure {
            XCTAssertEqual(failure.category, .retryable)
        }
    }

    func testPauseAndDisconnectReportQuiescenceOnlyAfterClose() throws {
        let explicitQuiescer = RecordingFileQuiescer()
        let explicit = try makeStreamingTransfer(fileQuiescer: explicitQuiescer)
        let paused = explicit.pause()

        XCTAssertEqual(explicitQuiescer.events, ["synchronize", "close"])
        XCTAssertEqual(paused.state, .paused)
        XCTAssertTrue(paused.quiescent)
        XCTAssertEqual(paused.dictionary["quiescent"] as? Bool, true)

        // Session disconnect cleanup invokes the same synchronous pause handoff.
        let disconnectQuiescer = RecordingFileQuiescer()
        let disconnect = try makeStreamingTransfer(fileQuiescer: disconnectQuiescer)
        let disconnected = disconnect.pause()
        XCTAssertEqual(disconnectQuiescer.events, ["synchronize", "close"])
        XCTAssertTrue(disconnected.quiescent)

        let failingQuiescer = RecordingFileQuiescer(failsBeforeClose: true)
        let unsafe = try makeStreamingTransfer(fileQuiescer: failingQuiescer).pause()
        XCTAssertEqual(failingQuiescer.events, ["synchronize"])
        XCTAssertEqual(unsafe.state, .failed)
        XCTAssertFalse(unsafe.quiescent)
        XCTAssertEqual(unsafe.failureCategory, .destination)
        XCTAssertEqual(unsafe.errorCode, "quiescence_failed")
    }

    func testByteBudgetStopsHeaderlessOverflowBeforeAcceptingBytes() throws {
        XCTAssertEqual(
            try TideyBrowserTransferResponsePolicy.evaluate(
                statusCode: 200,
                resumeOffset: 0,
                expectedTotalBytes: 10,
                headers: [:]
            ),
            .fresh(expectedTotal: nil)
        )
        var budget = TideyBrowserTransferByteBudget(expectedTotalBytes: 10, resumeOffset: 4)
        XCTAssertThrowsError(try budget.accept(chunkByteCount: 7))
        XCTAssertEqual(budget.partialSize, 4)
    }

    func testByteBudgetRequiresExactCompletion() throws {
        var exact = TideyBrowserTransferByteBudget(expectedTotalBytes: 10, resumeOffset: 4)
        try exact.accept(chunkByteCount: 6)
        XCTAssertEqual(exact.partialSize, 10)
        XCTAssertNoThrow(try exact.validateCompletion())

        var short = TideyBrowserTransferByteBudget(expectedTotalBytes: 10, resumeOffset: 4)
        try short.accept(chunkByteCount: 5)
        XCTAssertThrowsError(try short.validateCompletion())
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

    private func makeTransferRequest() -> TideyBrowserTransferStartRequest {
        TideyBrowserTransferStartRequest(
            target: TideyBrowserAutomationElementReference(
                tabID: "tab-1",
                navigationEpoch: 1,
                elementID: "element-1"
            ),
            archiveRoot: "/Volumes/External/Archive",
            expectedVolumeUUID: "volume-uuid",
            destinationRelativePath: "_incoming/item/attempt/file.zip.partial",
            expectedTotalBytes: 120_817_568,
            resumeOffset: 0,
            ifRange: nil,
            pauseAfterBytes: nil
        )
    }

    private func acceptedHeadMetadata(headers: [String: String]) throws
        -> TideyBrowserTransferPreflightMetadata {
        let decision = try TideyBrowserTransferPreflightPolicy.evaluateHEAD(
            statusCode: 200,
            headers: headers,
            redirectProvenance: []
        )
        guard case .accept(let metadata) = decision else {
            throw TideyBrowserTransferFailure(category: .validation, code: "unexpected_head_fallback")
        }
        return metadata
    }

    private func makeStreamingTransfer(fileQuiescer: any TideyBrowserTransferFileQuiescing) throws
        -> TideyBrowserStreamingTransfer {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let destination = directory.appendingPathComponent("payload.zip.partial")
        XCTAssertTrue(FileManager.default.createFile(atPath: destination.path, contents: Data()))
        let fileHandle = try FileHandle(forWritingTo: destination)
        let request = TideyBrowserTransferStartRequest(
            target: TideyBrowserAutomationElementReference(
                tabID: "tab-1",
                navigationEpoch: 1,
                elementID: "element-1"
            ),
            archiveRoot: directory.path,
            expectedVolumeUUID: "test-volume",
            destinationRelativePath: "payload.zip.partial",
            expectedTotalBytes: 10,
            resumeOffset: 0,
            ifRange: nil,
            pauseAfterBytes: nil
        )
        return TideyBrowserStreamingTransfer(
            transferID: UUID().uuidString,
            ownerSessionID: "owner-1",
            workspaceID: "workspace-1",
            sourceURL: try XCTUnwrap(URL(
                string: "https://studio.blender.org/vault/browse/project/payload.zip"
            )),
            destinationRelativePath: request.destinationRelativePath,
            request: request,
            fileHandle: fileHandle,
            fileQuiescer: fileQuiescer
        )
    }
}

private final class StubHeaderProbe: TideyBrowserTransferHeaderProbing {
    private var responses: [TideyBrowserTransferHeaderProbeResponse]
    private(set) var requests: [URLRequest] = []
    private(set) var responsesWereCancelledBeforeBody = true

    init(responses: [TideyBrowserTransferHeaderProbeResponse]) {
        self.responses = responses
    }

    func probe(_ request: URLRequest) async throws -> TideyBrowserTransferHeaderProbeResponse {
        requests.append(request)
        let response = responses.removeFirst()
        responsesWereCancelledBeforeBody = responsesWereCancelledBeforeBody && response.cancelledBeforeBody
        return response
    }
}

private final class RecordingFileQuiescer: TideyBrowserTransferFileQuiescing {
    enum Expected: Error {
        case failedBeforeClose
    }

    private let failsBeforeClose: Bool
    private(set) var events: [String] = []

    init(failsBeforeClose: Bool = false) {
        self.failsBeforeClose = failsBeforeClose
    }

    func synchronizeAndClose(_ fileHandle: FileHandle) throws {
        events.append("synchronize")
        if failsBeforeClose {
            throw Expected.failedBeforeClose
        }
        try fileHandle.synchronize()
        events.append("close")
        try fileHandle.close()
    }
}
