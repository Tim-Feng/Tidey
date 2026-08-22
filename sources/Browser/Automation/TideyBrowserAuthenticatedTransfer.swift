import Darwin
import Foundation
import WebKit

enum TideyBrowserTransferFailureCategory: String, Equatable {
    case authentication = "auth_or_entitlement"
    case rateLimited = "rate_limited"
    case retryable = "retryable"
    case invalidRange = "invalid_range"
    case representationMismatch = "representation_mismatch"
    case destination = "destination_failure"
    case validation = "validation_failure"
}

enum TideyBrowserTransferValidatorKind: String, Equatable {
    case strongETag = "strong_etag"
    case weakETag = "weak_etag"
    case lastModified = "last_modified"
    case unavailable
}

struct TideyBrowserTransferRepresentationBinding: Equatable {
    let exactTotalBytes: Int
    let validatorKind: TideyBrowserTransferValidatorKind
    let validatorValue: String
}

enum TideyBrowserTransferEntityTagSyntax {
    static func classify(_ value: String?) -> TideyBrowserTransferValidatorKind {
        guard let value else { return .unavailable }
        let scalars = value.unicodeScalars.map { $0.value }
        guard scalars.count <= 1_024 else { return .unavailable }

        let validatorKind: TideyBrowserTransferValidatorKind
        let openingQuoteIndex: Int
        if scalars.starts(with: [0x57, 0x2f]) {
            validatorKind = .weakETag
            openingQuoteIndex = 2
        } else {
            validatorKind = .strongETag
            openingQuoteIndex = 0
        }

        guard scalars.count >= openingQuoteIndex + 2,
              scalars[openingQuoteIndex] == 0x22,
              scalars.last == 0x22 else {
            return .unavailable
        }
        let opaqueTag = scalars[(openingQuoteIndex + 1)..<(scalars.count - 1)]
        guard opaqueTag.allSatisfy(isValidOpaqueTagScalar) else {
            return .unavailable
        }
        return validatorKind
    }

    private static func isValidOpaqueTagScalar(_ value: UInt32) -> Bool {
        value == 0x21 ||
            (0x23...0x7e).contains(value) ||
            (0x80...0xff).contains(value)
    }
}

enum TideyBrowserTransferRepresentationValidator {
    static func isValid(kind: TideyBrowserTransferValidatorKind, value: String) -> Bool {
        switch kind {
        case .strongETag:
            return TideyBrowserTransferEntityTagSyntax.classify(value) == .strongETag
        case .lastModified:
            guard !value.isEmpty,
                  value.count <= 128,
                  !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                return false
            }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss zzz"
            return formatter.date(from: value) != nil
        case .weakETag, .unavailable:
            return false
        }
    }
}

struct TideyBrowserTransferFailure: Error, Equatable {
    let category: TideyBrowserTransferFailureCategory
    let code: String
}

enum TideyBrowserTransferFailurePolicy {
    static func httpStatus(_ statusCode: Int) -> TideyBrowserTransferFailure {
        switch statusCode {
        case 401, 403:
            return TideyBrowserTransferFailure(
                category: .authentication,
                code: "http_\(statusCode)"
            )
        case 429:
            return TideyBrowserTransferFailure(category: .rateLimited, code: "http_429")
        case 500...599:
            return TideyBrowserTransferFailure(
                category: .retryable,
                code: "http_\(statusCode)"
            )
        default:
            return TideyBrowserTransferFailure(
                category: .validation,
                code: "http_\(statusCode)"
            )
        }
    }

    static func network(_ error: Error) -> TideyBrowserTransferFailure {
        _ = error
        return TideyBrowserTransferFailure(category: .retryable, code: "network_failure")
    }

    static func classify(_ error: Error) -> TideyBrowserTransferFailure {
        if let failure = error as? TideyBrowserTransferFailure {
            return failure
        }
        if let validation = error as? TideyBrowserTransferValidationError,
           validation == .invalidDestination {
            return TideyBrowserTransferFailure(
                category: .destination,
                code: "destination_validation_failed"
            )
        }
        return TideyBrowserTransferFailure(
            category: .validation,
            code: "transfer_validation_failed"
        )
    }
}

enum TideyBrowserTransferPreflightMethod: String, Equatable {
    case head = "HEAD"
    case range = "GET_RANGE"
}

struct TideyBrowserTransferPreflightMetadata: Equatable {
    let exactTotalBytes: Int
    let method: TideyBrowserTransferPreflightMethod
    let statusCode: Int
    let contentEncoding: String
    let contentType: String?
    let filename: String?
    let acceptRanges: String?
    let etag: String?
    let etagClassification: TideyBrowserTransferValidatorKind
    let lastModified: String?
    let resumeValidatorKind: TideyBrowserTransferValidatorKind
    let resumeValidatorValue: String?
    let redirectProvenance: [String]

    var dictionary: [String: Any] {
        var result: [String: Any] = [
            "exact_total_bytes": exactTotalBytes,
            "method": method.rawValue,
            "http_status": statusCode,
            "content_encoding": contentEncoding,
            "etag_classification": etagClassification.rawValue,
            "resume_validator_kind": resumeValidatorKind.rawValue,
            "redirect_provenance": redirectProvenance,
            "payload_bytes_written": 0,
        ]
        if let contentType { result["content_type"] = contentType }
        if let filename { result["filename"] = filename }
        if let acceptRanges { result["accept_ranges"] = acceptRanges }
        if let etag { result["etag"] = etag }
        if let lastModified { result["last_modified"] = lastModified }
        if let resumeValidatorValue { result["resume_validator"] = resumeValidatorValue }
        return result
    }
}

enum TideyBrowserTransferHeadPreflightDecision: Equatable {
    case accept(TideyBrowserTransferPreflightMetadata)
    case fallbackToRange
}

enum TideyBrowserTransferPreflightPolicy {
    static func evaluateHEAD(statusCode: Int,
                             headers: [String: String],
                             redirectProvenance: [String]) throws
        -> TideyBrowserTransferHeadPreflightDecision {
        guard statusCode == 200 else {
            if statusCode == 405 || statusCode == 501 {
                return .fallbackToRange
            }
            throw TideyBrowserTransferFailurePolicy.httpStatus(statusCode)
        }
        guard identityContentEncoding(in: headers) != nil,
              let exactTotalBytes = exactPositiveLength(in: headers) else {
            return .fallbackToRange
        }
        return .accept(metadata(
            exactTotalBytes: exactTotalBytes,
            method: .head,
            statusCode: statusCode,
            headers: headers,
            redirectProvenance: redirectProvenance
        ))
    }

    static func evaluateRange(statusCode: Int,
                              headers: [String: String],
                              redirectProvenance: [String]) throws
        -> TideyBrowserTransferPreflightMetadata {
        guard statusCode == 206 else {
            if statusCode == 200 {
                throw TideyBrowserTransferFailure(category: .invalidRange, code: "range_not_honored")
            }
            throw TideyBrowserTransferFailurePolicy.httpStatus(statusCode)
        }
        guard identityContentEncoding(in: headers) != nil else {
            throw TideyBrowserTransferFailure(category: .validation, code: "identity_encoding_required")
        }
        guard let contentRange = header("Content-Range", in: headers),
              let exactTotalBytes = exactTotalFromOneByteRange(contentRange) else {
            throw TideyBrowserTransferFailure(category: .invalidRange, code: "invalid_content_range")
        }
        if let contentLength = header("Content-Length", in: headers),
           contentLength.trimmingCharacters(in: .whitespacesAndNewlines) != "1" {
            throw TideyBrowserTransferFailure(category: .invalidRange, code: "invalid_range_length")
        }
        return metadata(
            exactTotalBytes: exactTotalBytes,
            method: .range,
            statusCode: statusCode,
            headers: headers,
            redirectProvenance: redirectProvenance
        )
    }

    private static func metadata(exactTotalBytes: Int,
                                 method: TideyBrowserTransferPreflightMethod,
                                 statusCode: Int,
                                 headers: [String: String],
                                 redirectProvenance: [String]) -> TideyBrowserTransferPreflightMetadata {
        let etag = boundedHeader("ETag", in: headers, maximumLength: 1_024)
        let etagClassification = classifyETag(etag)
        let lastModified = boundedHeader("Last-Modified", in: headers, maximumLength: 128)
        let usableLastModified = isUsableLastModified(lastModified) ? lastModified : nil
        let resumeValidatorKind: TideyBrowserTransferValidatorKind
        let resumeValidatorValue: String?
        if etagClassification == .strongETag {
            resumeValidatorKind = .strongETag
            resumeValidatorValue = etag
        } else if let usableLastModified {
            resumeValidatorKind = .lastModified
            resumeValidatorValue = usableLastModified
        } else {
            resumeValidatorKind = .unavailable
            resumeValidatorValue = nil
        }
        return TideyBrowserTransferPreflightMetadata(
            exactTotalBytes: exactTotalBytes,
            method: method,
            statusCode: statusCode,
            contentEncoding: "identity",
            contentType: boundedHeader("Content-Type", in: headers, maximumLength: 255),
            filename: safeFilename(in: headers),
            acceptRanges: boundedHeader("Accept-Ranges", in: headers, maximumLength: 64),
            etag: etagClassification == .unavailable ? nil : etag,
            etagClassification: etagClassification,
            lastModified: usableLastModified,
            resumeValidatorKind: resumeValidatorKind,
            resumeValidatorValue: resumeValidatorValue,
            redirectProvenance: safeProvenance(redirectProvenance)
        )
    }

    private static func exactPositiveLength(in headers: [String: String]) -> Int? {
        guard let raw = header("Content-Length", in: headers)?.trimmingCharacters(in: .whitespaces),
              let value = Int(raw),
              value > 0 else {
            return nil
        }
        return value
    }

    private static func exactTotalFromOneByteRange(_ raw: String) -> Int? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.hasPrefix("bytes 0-0/"),
              let total = Int(value.dropFirst("bytes 0-0/".count)),
              total > 0 else {
            return nil
        }
        return total
    }

    private static func identityContentEncoding(in headers: [String: String]) -> String? {
        guard let raw = header("Content-Encoding", in: headers) else { return "identity" }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare("identity") == .orderedSame ? "identity" : nil
    }

    private static func classifyETag(_ etag: String?) -> TideyBrowserTransferValidatorKind {
        TideyBrowserTransferEntityTagSyntax.classify(etag)
    }

    private static func isUsableLastModified(_ value: String?) -> Bool {
        guard let value else { return false }
        return TideyBrowserTransferRepresentationValidator.isValid(
            kind: .lastModified,
            value: value
        )
    }

    private static func safeFilename(in headers: [String: String]) -> String? {
        guard let disposition = boundedHeader("Content-Disposition", in: headers, maximumLength: 1_024),
              let range = disposition.range(of: "filename=", options: .caseInsensitive) else {
            return nil
        }
        var value = String(disposition[range.upperBound...])
            .split(separator: ";", maxSplits: 1)
            .first.map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2 {
            value.removeFirst()
            value.removeLast()
        }
        guard !value.isEmpty,
              value.count <= 255,
              value == URL(fileURLWithPath: value).lastPathComponent,
              !value.contains("/"),
              !value.contains("\\"),
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            return nil
        }
        return value
    }

    private static func boundedHeader(_ name: String,
                                      in headers: [String: String],
                                      maximumLength: Int) -> String? {
        guard let value = header(name, in: headers)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty,
              value.count <= maximumLength,
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            return nil
        }
        return value
    }

    private static func header(_ name: String, in headers: [String: String]) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    private static func safeProvenance(_ provenance: [String]) -> [String] {
        Array(provenance.prefix(8)).compactMap { raw in
            guard let url = URL(string: raw) else { return nil }
            return String(TideyBrowserTransferRedaction.url(url).prefix(2_048))
        }
    }
}

protocol TideyBrowserTransferPreflightExecuting {
    func execute(sourceURL: URL, cookies: [HTTPCookie]) async throws
        -> TideyBrowserTransferPreflightMetadata
}

struct TideyBrowserTransferHeaderProbeResponse: Equatable {
    let statusCode: Int
    let headers: [String: String]
    let redirectProvenance: [String]
    let cancelledBeforeBody: Bool
}

protocol TideyBrowserTransferHeaderProbing {
    func probe(_ request: URLRequest) async throws -> TideyBrowserTransferHeaderProbeResponse
}

struct TideyBrowserTransferPreflightExecutor: TideyBrowserTransferPreflightExecuting {
    private let headerProbe: any TideyBrowserTransferHeaderProbing

    init(headerProbe: any TideyBrowserTransferHeaderProbing) {
        self.headerProbe = headerProbe
    }

    func execute(sourceURL: URL, cookies: [HTTPCookie]) async throws
        -> TideyBrowserTransferPreflightMetadata {
        let headResponse = try await headerProbe.probe(request(
            sourceURL: sourceURL,
            method: "HEAD",
            cookies: cookies,
            range: nil
        ))
        try requireCancelledBeforeBody(headResponse)
        switch try TideyBrowserTransferPreflightPolicy.evaluateHEAD(
            statusCode: headResponse.statusCode,
            headers: headResponse.headers,
            redirectProvenance: headResponse.redirectProvenance
        ) {
        case .accept(let metadata):
            return metadata
        case .fallbackToRange:
            let rangeResponse = try await headerProbe.probe(request(
                sourceURL: sourceURL,
                method: "GET",
                cookies: cookies,
                range: "bytes=0-0"
            ))
            try requireCancelledBeforeBody(rangeResponse)
            return try TideyBrowserTransferPreflightPolicy.evaluateRange(
                statusCode: rangeResponse.statusCode,
                headers: rangeResponse.headers,
                redirectProvenance: rangeResponse.redirectProvenance
            )
        }
    }

    private func request(sourceURL: URL,
                         method: String,
                         cookies: [HTTPCookie],
                         range: String?) -> URLRequest {
        var request = URLRequest(url: sourceURL)
        request.httpMethod = method
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if let range {
            request.setValue(range, forHTTPHeaderField: "Range")
        }
        for (name, value) in HTTPCookie.requestHeaderFields(with: cookies) {
            request.setValue(value, forHTTPHeaderField: name)
        }
        return request
    }

    private func requireCancelledBeforeBody(_ response: TideyBrowserTransferHeaderProbeResponse) throws {
        guard response.cancelledBeforeBody else {
            throw TideyBrowserTransferFailure(category: .validation, code: "probe_body_not_cancelled")
        }
    }
}

final class TideyBrowserTransferHeaderProbe: TideyBrowserTransferHeaderProbing {
    func probe(_ request: URLRequest) async throws -> TideyBrowserTransferHeaderProbeResponse {
        try await TideyBrowserTransferOneShotHeaderProbe(request: request).run()
    }
}

private final class TideyBrowserTransferOneShotHeaderProbe: NSObject,
                                                            URLSessionDataDelegate,
                                                            URLSessionTaskDelegate,
                                                            @unchecked Sendable {
    private let lock = NSLock()
    private let request: URLRequest
    private var continuation: CheckedContinuation<TideyBrowserTransferHeaderProbeResponse, Error>?
    private var session: URLSession?
    private var capturedResponse: HTTPURLResponse?
    private var receivedBody = false
    private var completed = false
    private var redirectProvenance: [String]

    init(request: URLRequest) {
        self.request = request
        self.redirectProvenance = request.url.map { [TideyBrowserTransferRedaction.url($0)] } ?? []
    }

    func run() async throws -> TideyBrowserTransferHeaderProbeResponse {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock {
                self.continuation = continuation
                let configuration = URLSessionConfiguration.ephemeral
                configuration.httpCookieAcceptPolicy = .never
                configuration.httpShouldSetCookies = false
                configuration.urlCache = nil
                configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
                let queue = OperationQueue()
                queue.maxConcurrentOperationCount = 1
                queue.qualityOfService = .utility
                let session = URLSession(
                    configuration: configuration,
                    delegate: self,
                    delegateQueue: queue
                )
                self.session = session
                session.dataTask(with: request).resume()
            }
        }
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard let redirectedURL = request.url,
              let components = URLComponents(url: redirectedURL, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              components.user == nil,
              components.password == nil else {
            completionHandler(nil)
            return
        }
        var redirected = request
        redirected.httpMethod = self.request.httpMethod
        redirected.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        redirected.setValue(self.request.value(forHTTPHeaderField: "Range"),
                            forHTTPHeaderField: "Range")
        if redirectedURL.host?.lowercased() != self.request.url?.host?.lowercased() {
            redirected.setValue(nil, forHTTPHeaderField: "Cookie")
            redirected.setValue(nil, forHTTPHeaderField: "Authorization")
        }
        lock.withLock {
            if let responseURL = response.url {
                redirectProvenance.append(TideyBrowserTransferRedaction.url(responseURL))
            }
            redirectProvenance.append(TideyBrowserTransferRedaction.url(redirectedURL))
        }
        completionHandler(redirected)
    }

    func urlSession(_ session: URLSession,
                    dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let httpResponse = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            finish(.failure(TideyBrowserTransferFailure(
                category: .validation,
                code: "invalid_preflight_response"
            )))
            return
        }
        lock.withLock {
            capturedResponse = httpResponse
        }
        completionHandler(.cancel)
    }

    func urlSession(_ session: URLSession,
                    dataTask: URLSessionDataTask,
                    didReceive data: Data) {
        lock.withLock {
            receivedBody = receivedBody || !data.isEmpty
        }
        dataTask.cancel()
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        let result: Result<TideyBrowserTransferHeaderProbeResponse, Error> = lock.withLock {
            guard let response = capturedResponse else {
                return .failure(TideyBrowserTransferFailurePolicy.network(
                    error ?? URLError(.badServerResponse)
                ))
            }
            let headers = response.allHeaderFields.reduce(into: [String: String]()) {
                partial, item in
                partial[String(describing: item.key)] = String(describing: item.value)
            }
            return .success(TideyBrowserTransferHeaderProbeResponse(
                statusCode: response.statusCode,
                headers: headers,
                redirectProvenance: Array(redirectProvenance.prefix(8)),
                cancelledBeforeBody: !receivedBody
            ))
        }
        finish(result)
    }

    private func finish(_ result: Result<TideyBrowserTransferHeaderProbeResponse, Error>) {
        let completion: CheckedContinuation<TideyBrowserTransferHeaderProbeResponse, Error>? =
            lock.withLock {
                guard !completed else { return nil }
                completed = true
                let completion = continuation
                continuation = nil
                return completion
            }
        session?.invalidateAndCancel()
        session = nil
        completion?.resume(with: result)
    }
}

struct TideyBrowserTransferDestinationRequest: Equatable {
    let archiveRoot: String
    let expectedVolumeUUID: String
    let destinationRelativePath: String
    let resumeOffset: Int
}

struct TideyBrowserTransferPreflightRequest: Equatable {
    let target: TideyBrowserAutomationElementReference
    let destination: TideyBrowserTransferDestinationRequest
}

struct TideyBrowserTransferStartRequest: Equatable {
    let target: TideyBrowserAutomationElementReference
    let archiveRoot: String
    let expectedVolumeUUID: String
    let destinationRelativePath: String
    let expectedTotalBytes: Int
    let resumeOffset: Int
    let ifRange: String?
    let pauseAfterBytes: Int?
    let representationBinding: TideyBrowserTransferRepresentationBinding?

    init(target: TideyBrowserAutomationElementReference,
         archiveRoot: String,
         expectedVolumeUUID: String,
         destinationRelativePath: String,
         expectedTotalBytes: Int,
         resumeOffset: Int,
         ifRange: String?,
         pauseAfterBytes: Int?,
         representationBinding: TideyBrowserTransferRepresentationBinding? = nil) {
        self.target = target
        self.archiveRoot = archiveRoot
        self.expectedVolumeUUID = expectedVolumeUUID
        self.destinationRelativePath = destinationRelativePath
        self.expectedTotalBytes = expectedTotalBytes
        self.resumeOffset = resumeOffset
        self.ifRange = ifRange
        self.pauseAfterBytes = pauseAfterBytes
        self.representationBinding = representationBinding
    }

    var destination: TideyBrowserTransferDestinationRequest {
        TideyBrowserTransferDestinationRequest(
            archiveRoot: archiveRoot,
            expectedVolumeUUID: expectedVolumeUUID,
            destinationRelativePath: destinationRelativePath,
            resumeOffset: resumeOffset
        )
    }
}

enum TideyBrowserTransferResponseDecision: Equatable {
    case fresh(expectedTotal: Int?)
    case resumed(expectedTotal: Int?)
    case rangeNotSatisfiable(remoteTotal: Int?)
}

enum TideyBrowserTransferValidationError: Error, Equatable {
    case invalidSource
    case invalidDestination
    case invalidResponse
    case declaredTotalMismatch
    case declaredTotalExceeded
    case incompleteTransfer
}

enum TideyBrowserTransferRouteValidator {
    static func sourceURL(pageURL: URL, href: String) throws -> URL {
        guard isOfficialVaultURL(pageURL),
              let resolved = URL(string: href, relativeTo: pageURL)?.absoluteURL,
              isOfficialVaultURL(resolved),
              sameOrigin(pageURL, resolved),
              let components = URLComponents(url: resolved, resolvingAgainstBaseURL: false),
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil else {
            throw TideyBrowserTransferValidationError.invalidSource
        }
        return resolved
    }

    static func destinationComponents(_ relativePath: String) throws -> [String] {
        guard !relativePath.isEmpty,
              !relativePath.hasPrefix("/"),
              !relativePath.contains("\\"),
              !relativePath.contains("\0"),
              relativePath.hasSuffix(".partial") else {
            throw TideyBrowserTransferValidationError.invalidDestination
        }
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw TideyBrowserTransferValidationError.invalidDestination
        }
        return components
    }

    private static func isOfficialVaultURL(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              components.host?.lowercased() == "studio.blender.org",
              components.port == nil else {
            return false
        }
        let decodedPath = components.percentEncodedPath.removingPercentEncoding ?? ""
        let pathComponents = decodedPath.split(separator: "/", omittingEmptySubsequences: false)
        guard !pathComponents.contains(where: { $0 == "." || $0 == ".." }) else {
            return false
        }
        return decodedPath == "/vault/browse" || decodedPath.hasPrefix("/vault/browse/")
    }

    private static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        let left = URLComponents(url: lhs, resolvingAgainstBaseURL: false)
        let right = URLComponents(url: rhs, resolvingAgainstBaseURL: false)
        return left?.scheme?.lowercased() == right?.scheme?.lowercased() &&
            left?.host?.lowercased() == right?.host?.lowercased() &&
            left?.port == right?.port
    }
}

enum TideyBrowserTransferResponsePolicy {
    static func evaluate(statusCode: Int,
                         resumeOffset: Int,
                         expectedTotalBytes: Int,
                         headers: [String: String],
                         representationBinding: TideyBrowserTransferRepresentationBinding? = nil) throws
        -> TideyBrowserTransferResponseDecision {
        guard expectedTotalBytes > 0,
              resumeOffset >= 0,
              resumeOffset <= expectedTotalBytes else {
            throw TideyBrowserTransferFailure(
                category: .validation,
                code: "invalid_transfer_bounds"
            )
        }
        if let representationBinding {
            guard representationBinding.exactTotalBytes == expectedTotalBytes,
                  TideyBrowserTransferRepresentationValidator.isValid(
                    kind: representationBinding.validatorKind,
                    value: representationBinding.validatorValue
                  ) else {
                throw TideyBrowserTransferFailure(
                    category: .representationMismatch,
                    code: "invalid_representation_binding"
                )
            }
            try validateIdentityEncoding(headers)
        }
        let decision: TideyBrowserTransferResponseDecision
        switch statusCode {
        case 200:
            guard resumeOffset == 0 else {
                throw TideyBrowserTransferFailure(
                    category: .invalidRange,
                    code: "range_not_honored"
                )
            }
            let total = try optionalPositiveIntegerHeader("Content-Length", in: headers)
            try validateServerTotal(
                total,
                expectedTotalBytes: expectedTotalBytes,
                representationBound: representationBinding != nil
            )
            decision = .fresh(expectedTotal: total)
        case 206:
            guard let rawRange = header("Content-Range", in: headers),
                  let range = parseSatisfiedContentRange(rawRange),
                  range.start == resumeOffset,
                  range.end < expectedTotalBytes else {
                throw TideyBrowserTransferFailure(
                    category: .invalidRange,
                    code: "invalid_content_range"
                )
            }
            try validateServerTotal(
                range.total,
                expectedTotalBytes: expectedTotalBytes,
                representationBound: representationBinding != nil
            )
            decision = .resumed(expectedTotal: range.total)
        case 416:
            guard resumeOffset == expectedTotalBytes else {
                throw TideyBrowserTransferFailure(
                    category: .invalidRange,
                    code: "unsatisfied_range_before_expected_total"
                )
            }
            let total: Int?
            do {
                total = try parseOptionalUnsatisfiedContentRange(
                    header("Content-Range", in: headers)
                )
            } catch {
                throw TideyBrowserTransferFailure(
                    category: .invalidRange,
                    code: "invalid_unsatisfied_content_range"
                )
            }
            try validateServerTotal(
                total,
                expectedTotalBytes: expectedTotalBytes,
                representationBound: representationBinding != nil
            )
            decision = .rangeNotSatisfiable(remoteTotal: total)
        default:
            throw TideyBrowserTransferFailurePolicy.httpStatus(statusCode)
        }
        if let representationBinding {
            try validateRepresentation(
                decision: decision,
                headers: headers,
                binding: representationBinding
            )
        }
        return decision
    }

    private static func header(_ name: String, in headers: [String: String]) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    private static func positiveInteger(_ raw: String?) -> Int? {
        guard let raw, let value = Int(raw), value >= 0 else {
            return nil
        }
        return value
    }

    private static func optionalPositiveIntegerHeader(_ name: String,
                                                      in headers: [String: String]) throws -> Int? {
        guard let raw = header(name, in: headers) else { return nil }
        guard let value = positiveInteger(raw) else {
            throw TideyBrowserTransferValidationError.invalidResponse
        }
        return value
    }

    private static func validateServerTotal(_ total: Int?,
                                            expectedTotalBytes: Int,
                                            representationBound: Bool) throws {
        guard total == nil || total == expectedTotalBytes else {
            if representationBound {
                throw TideyBrowserTransferFailure(
                    category: .representationMismatch,
                    code: "representation_total_mismatch"
                )
            }
            throw TideyBrowserTransferFailure(
                category: .validation,
                code: "declared_total_mismatch"
            )
        }
    }

    private static func validateIdentityEncoding(_ headers: [String: String]) throws {
        guard let raw = header("Content-Encoding", in: headers) else { return }
        guard raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare("identity") == .orderedSame else {
            throw TideyBrowserTransferFailure(
                category: .representationMismatch,
                code: "representation_encoding_mismatch"
            )
        }
    }

    private static func validateRepresentation(
        decision: TideyBrowserTransferResponseDecision,
        headers: [String: String],
        binding: TideyBrowserTransferRepresentationBinding
    ) throws {
        let total: Int?
        switch decision {
        case .fresh(let value), .resumed(let value), .rangeNotSatisfiable(let value):
            total = value
        }
        guard total == binding.exactTotalBytes else {
            throw TideyBrowserTransferFailure(
                category: .representationMismatch,
                code: "representation_total_unproven"
            )
        }
        let actual: String?
        switch binding.validatorKind {
        case .strongETag:
            actual = header("ETag", in: headers)
        case .lastModified:
            actual = header("Last-Modified", in: headers)
        case .weakETag, .unavailable:
            actual = nil
        }
        guard actual == binding.validatorValue else {
            throw TideyBrowserTransferFailure(
                category: .representationMismatch,
                code: "representation_validator_mismatch"
            )
        }
    }

    private static func parseSatisfiedContentRange(_ raw: String)
        -> (start: Int, end: Int, total: Int?)? {
        let parts = raw.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2, parts[0].lowercased() == "bytes" else {
            return nil
        }
        let rangeAndTotal = parts[1].split(separator: "/", maxSplits: 1).map(String.init)
        let bounds = rangeAndTotal.first?.split(separator: "-", maxSplits: 1).map(String.init) ?? []
        guard rangeAndTotal.count == 2,
              bounds.count == 2,
              let start = Int(bounds[0]),
              let end = Int(bounds[1]),
              start >= 0,
              end >= start else {
            return nil
        }
        let total = rangeAndTotal[1] == "*" ? nil : positiveInteger(rangeAndTotal[1])
        guard rangeAndTotal[1] == "*" || total != nil else {
            return nil
        }
        return (start, end, total)
    }

    private static func parseOptionalUnsatisfiedContentRange(_ raw: String?) throws -> Int? {
        guard let raw else { return nil }
        let normalized = raw.lowercased()
        guard normalized.hasPrefix("bytes */"),
              let value = positiveInteger(String(normalized.dropFirst("bytes */".count))) else {
            throw TideyBrowserTransferValidationError.invalidResponse
        }
        return value
    }
}

struct TideyBrowserTransferByteBudget {
    let expectedTotalBytes: Int
    let resumeOffset: Int
    private(set) var bytesWritten = 0

    var partialSize: Int {
        resumeOffset + bytesWritten
    }

    mutating func accept(chunkByteCount: Int) throws {
        try validate(chunkByteCount: chunkByteCount)
        recordAccepted(chunkByteCount: chunkByteCount)
    }

    func validate(chunkByteCount: Int) throws {
        guard expectedTotalBytes > 0,
              resumeOffset >= 0,
              resumeOffset <= expectedTotalBytes,
              chunkByteCount >= 0,
              chunkByteCount <= expectedTotalBytes - partialSize else {
            throw TideyBrowserTransferValidationError.declaredTotalExceeded
        }
    }

    mutating func recordAccepted(chunkByteCount: Int) {
        bytesWritten += chunkByteCount
    }

    func validateCompletion() throws {
        guard partialSize == expectedTotalBytes else {
            throw TideyBrowserTransferValidationError.incompleteTransfer
        }
    }
}

enum TideyBrowserTransferRedaction {
    static func url(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return "redacted-url"
        }
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        return components.string ?? "redacted-url"
    }

    static func message(_ message: String) -> String {
        let lowercased = message.lowercased()
        let sensitiveMarkers = ["authorization", "bearer ", "cookie", "token=", "signature=", "x-amz-"]
        guard !sensitiveMarkers.contains(where: lowercased.contains) else {
            return "Transfer failed"
        }
        return String(message
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .prefix(240))
    }
}

struct TideyBrowserTransferVolumeInfo {
    let uuid: String
    let mountPoint: String
    let isInternal: Bool
    let isWritable: Bool
}

enum TideyBrowserTransferDiskInspector {
    static func inspectionTarget(archiveRoot: String,
                                 containingMountPoint: String?) -> String {
        containingMountPoint ?? archiveRoot
    }

    static func inspect(path: String) throws -> TideyBrowserTransferVolumeInfo {
        let archiveRoot = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        let resourceValues = try archiveRoot.resourceValues(forKeys: [.volumeURLKey])
        guard let containingMountPoint = resourceValues.volume?.standardizedFileURL.path,
              !containingMountPoint.isEmpty else {
            throw TideyBrowserTransferValidationError.invalidDestination
        }
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        process.arguments = [
            "info",
            "-plist",
            inspectionTarget(
                archiveRoot: archiveRoot.path,
                containingMountPoint: containingMountPoint
            ),
        ]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let plist = try PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
              ) as? [String: Any],
              let uuid = plist["VolumeUUID"] as? String,
              let mountPoint = plist["MountPoint"] as? String,
              let isInternal = plist["Internal"] as? Bool,
              let isWritable = plist["Writable"] as? Bool else {
            throw TideyBrowserTransferValidationError.invalidDestination
        }
        return TideyBrowserTransferVolumeInfo(
            uuid: uuid,
            mountPoint: mountPoint,
            isInternal: isInternal,
            isWritable: isWritable
        )
    }
}

private enum TideyBrowserTransferDestination {
    static func validate(_ request: TideyBrowserTransferDestinationRequest) throws -> URL {
        let components = try TideyBrowserTransferRouteValidator.destinationComponents(
            request.destinationRelativePath
        )
        let root = URL(fileURLWithPath: request.archiveRoot, isDirectory: true).standardizedFileURL
        guard root.path == root.resolvingSymlinksInPath().path,
              isDirectoryWithoutSymlink(root.path) else {
            throw TideyBrowserTransferValidationError.invalidDestination
        }

        let volume = try TideyBrowserTransferDiskInspector.inspect(path: root.path)
        let mountPoint = URL(fileURLWithPath: volume.mountPoint, isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath().path
        let rootPath = root.path
        guard volume.uuid.caseInsensitiveCompare(request.expectedVolumeUUID) == .orderedSame,
              !volume.isInternal,
              volume.isWritable,
              rootPath == mountPoint || rootPath.hasPrefix(mountPoint + "/") else {
            throw TideyBrowserTransferValidationError.invalidDestination
        }

        var parent = root
        for component in components.dropLast() {
            parent.appendPathComponent(component, isDirectory: true)
            guard parent.path == parent.resolvingSymlinksInPath().path,
                  isDirectoryWithoutSymlink(parent.path) else {
                throw TideyBrowserTransferValidationError.invalidDestination
            }
        }

        let destination = parent.appendingPathComponent(components.last!, isDirectory: false)
        guard destination.deletingLastPathComponent().path == parent.path else {
            throw TideyBrowserTransferValidationError.invalidDestination
        }

        var status = stat()
        let exists = lstat(destination.path, &status) == 0
        if request.resumeOffset == 0 {
            guard !exists, errno == ENOENT else {
                throw TideyBrowserTransferValidationError.invalidDestination
            }
        } else {
            guard exists,
                  (status.st_mode & S_IFMT) == S_IFREG,
                  Int(status.st_size) == request.resumeOffset else {
                throw TideyBrowserTransferValidationError.invalidDestination
            }
        }
        return destination
    }

    static func open(_ request: TideyBrowserTransferStartRequest) throws -> (URL, FileHandle) {
        let destination = try validate(request.destination)
        let descriptor: Int32
        if request.resumeOffset == 0 {
            descriptor = Darwin.open(
                destination.path,
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                S_IRUSR | S_IWUSR
            )
        } else {
            descriptor = Darwin.open(
                destination.path,
                O_WRONLY | O_APPEND | O_CLOEXEC | O_NOFOLLOW
            )
        }
        guard descriptor >= 0 else {
            throw TideyBrowserTransferValidationError.invalidDestination
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            if request.resumeOffset > 0 {
                let end = try handle.seekToEnd()
                guard end == UInt64(request.resumeOffset) else {
                    try handle.close()
                    throw TideyBrowserTransferValidationError.invalidDestination
                }
            }
            return (destination, handle)
        } catch {
            try? handle.close()
            throw error
        }
    }

    private static func isDirectoryWithoutSymlink(_ path: String) -> Bool {
        var status = stat()
        guard lstat(path, &status) == 0 else { return false }
        return (status.st_mode & S_IFMT) == S_IFDIR
    }
}

struct TideyBrowserTransferOpenedDestination: @unchecked Sendable {
    let url: URL
    let fileHandle: FileHandle
}

protocol TideyBrowserTransferDestinationValidating {
    func validate(_ request: TideyBrowserTransferDestinationRequest) async throws -> URL
}

struct TideyBrowserTransferDestinationValidationExecutor: TideyBrowserTransferDestinationValidating {
    typealias Operation = @Sendable (TideyBrowserTransferDestinationRequest) throws -> URL

    private let operation: Operation

    init(operation: @escaping Operation = { request in
        try TideyBrowserTransferDestination.validate(request)
    }) {
        self.operation = operation
    }

    func validate(_ request: TideyBrowserTransferDestinationRequest) async throws -> URL {
        try await Task.detached(priority: .utility) {
            try operation(request)
        }.value
    }
}

protocol TideyBrowserTransferDestinationOpening {
    func open(_ request: TideyBrowserTransferStartRequest) async throws
        -> TideyBrowserTransferOpenedDestination
}

struct TideyBrowserTransferDestinationOpeningExecutor: TideyBrowserTransferDestinationOpening {
    typealias Operation = @Sendable (TideyBrowserTransferStartRequest) throws
        -> TideyBrowserTransferOpenedDestination

    private let operation: Operation

    init(operation: @escaping Operation = { request in
        let opened = try TideyBrowserTransferDestination.open(request)
        return TideyBrowserTransferOpenedDestination(url: opened.0, fileHandle: opened.1)
    }) {
        self.operation = operation
    }

    func open(_ request: TideyBrowserTransferStartRequest) async throws
        -> TideyBrowserTransferOpenedDestination {
        try await Task.detached(priority: .utility) {
            try operation(request)
        }.value
    }
}

protocol TideyBrowserTransferFileQuiescing {
    func synchronizeAndClose(_ fileHandle: FileHandle) throws
}

struct TideyBrowserTransferFileQuiescer: TideyBrowserTransferFileQuiescing {
    func synchronizeAndClose(_ fileHandle: FileHandle) throws {
        try fileHandle.synchronize()
        try fileHandle.close()
    }
}

enum TideyBrowserTransferState: String {
    case running
    case paused
    case completed
    case rangeNotSatisfiable = "range_not_satisfiable"
    case failed
}

struct TideyBrowserTransferSnapshot {
    let transferID: String
    let state: TideyBrowserTransferState
    let resumeOffset: Int
    let bytesWritten: Int
    let statusCode: Int?
    let expectedTotal: Int?
    let etag: String?
    let lastModified: String?
    let errorCode: String?
    let failureCategory: TideyBrowserTransferFailureCategory?
    let quiescent: Bool
    let sourceURL: String
    let destinationRelativePath: String

    var dictionary: [String: Any] {
        var result: [String: Any] = [
            "transfer_id": transferID,
            "state": state.rawValue,
            "resume_offset": resumeOffset,
            "bytes_written": bytesWritten,
            "partial_size": resumeOffset + bytesWritten,
            "quiescent": quiescent,
            "source_url": sourceURL,
            "destination_relative_path": destinationRelativePath,
        ]
        if let statusCode { result["http_status"] = statusCode }
        if let expectedTotal { result["expected_total"] = expectedTotal }
        if let etag { result["etag"] = etag }
        if let lastModified { result["last_modified"] = lastModified }
        if let errorCode { result["error_code"] = errorCode }
        if let failureCategory { result["failure_category"] = failureCategory.rawValue }
        return result
    }
}

final class TideyBrowserStreamingTransfer: NSObject,
                                                    URLSessionDataDelegate,
                                                    URLSessionTaskDelegate,
                                                    @unchecked Sendable {
    let transferID: String
    let ownerSessionID: String
    let workspaceID: String

    private let lock = NSLock()
    private let sourceURL: URL
    private let destinationRelativePath: String
    private let resumeOffset: Int
    private let expectedTotalBytes: Int
    private let ifRange: String?
    private let pauseAfterBytes: Int?
    private let representationBinding: TideyBrowserTransferRepresentationBinding?
    private let fileQuiescer: any TideyBrowserTransferFileQuiescing
    private var fileHandle: FileHandle?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var state: TideyBrowserTransferState = .running
    private var byteBudget: TideyBrowserTransferByteBudget
    private var statusCode: Int?
    private var expectedTotal: Int?
    private var etag: String?
    private var lastModified: String?
    private var errorCode: String?
    private var failureCategory: TideyBrowserTransferFailureCategory?
    private var fileIsQuiescent = false

    init(transferID: String,
         ownerSessionID: String,
         workspaceID: String,
         sourceURL: URL,
         destinationRelativePath: String,
         request: TideyBrowserTransferStartRequest,
         fileHandle: FileHandle,
         fileQuiescer: any TideyBrowserTransferFileQuiescing = TideyBrowserTransferFileQuiescer()) {
        self.transferID = transferID
        self.ownerSessionID = ownerSessionID
        self.workspaceID = workspaceID
        self.sourceURL = sourceURL
        self.destinationRelativePath = destinationRelativePath
        self.resumeOffset = request.resumeOffset
        self.expectedTotalBytes = request.expectedTotalBytes
        self.ifRange = request.ifRange
        self.pauseAfterBytes = request.pauseAfterBytes
        self.representationBinding = request.representationBinding
        self.fileQuiescer = fileQuiescer
        self.byteBudget = TideyBrowserTransferByteBudget(
            expectedTotalBytes: request.expectedTotalBytes,
            resumeOffset: request.resumeOffset
        )
        self.fileHandle = fileHandle
    }

    func start(cookies: [HTTPCookie], ifRange: String?) {
        var request = URLRequest(url: sourceURL)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if resumeOffset > 0 {
            request.setValue("bytes=\(resumeOffset)-", forHTTPHeaderField: "Range")
            if let validator = representationBinding?.validatorValue ?? ifRange {
                request.setValue(validator, forHTTPHeaderField: "If-Range")
            }
        }
        if let cookie = HTTPCookie.requestHeaderFields(with: cookies)["Cookie"] {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        let task = session.dataTask(with: request)
        lock.withLock {
            self.session = session
            self.task = task
        }
        task.resume()
    }

    func pause() -> TideyBrowserTransferSnapshot {
        lock.withLock {
            guard state == .running else { return snapshotLocked() }
            state = .paused
            task?.cancel()
            closeFileLocked()
            return snapshotLocked()
        }
    }

    func snapshot() -> TideyBrowserTransferSnapshot {
        lock.withLock { snapshotLocked() }
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard let redirectedURL = request.url,
              let components = URLComponents(url: redirectedURL, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              components.user == nil,
              components.password == nil else {
            completionHandler(nil)
            return
        }
        var redirected = request
        if redirectedURL.host?.lowercased() != sourceURL.host?.lowercased() {
            redirected.setValue(nil, forHTTPHeaderField: "Cookie")
            redirected.setValue(nil, forHTTPHeaderField: "Authorization")
        }
        if resumeOffset > 0 {
            redirected.setValue("bytes=\(resumeOffset)-", forHTTPHeaderField: "Range")
            if let validator = representationBinding?.validatorValue ?? ifRange {
                redirected.setValue(validator, forHTTPHeaderField: "If-Range")
            }
        }
        redirected.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        completionHandler(redirected)
    }

    func urlSession(_ session: URLSession,
                    dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse else {
            fail(TideyBrowserTransferFailure(category: .validation, code: "invalid_response"))
            completionHandler(.cancel)
            return
        }
        let headers = response.allHeaderFields.reduce(into: [String: String]()) { partial, item in
            partial[String(describing: item.key)] = String(describing: item.value)
        }
        do {
            let decision = try TideyBrowserTransferResponsePolicy.evaluate(
                statusCode: response.statusCode,
                resumeOffset: resumeOffset,
                expectedTotalBytes: expectedTotalBytes,
                headers: headers,
                representationBinding: representationBinding
            )
            lock.withLock {
                statusCode = response.statusCode
                etag = header("ETag", in: headers)
                lastModified = header("Last-Modified", in: headers)
                switch decision {
                case .fresh(let total), .resumed(let total):
                    expectedTotal = total
                case .rangeNotSatisfiable(let total):
                    expectedTotal = total
                    state = .rangeNotSatisfiable
                    closeFileLocked()
                }
            }
            if case .rangeNotSatisfiable = decision {
                completionHandler(.cancel)
            } else {
                completionHandler(.allow)
            }
        } catch let failure as TideyBrowserTransferFailure {
            fail(failure)
            completionHandler(.cancel)
        } catch {
            fail(TideyBrowserTransferFailurePolicy.classify(error))
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession,
                    dataTask: URLSessionDataTask,
                    didReceive data: Data) {
        lock.withLock {
            guard state == .running, let fileHandle else { return }
            do {
                try byteBudget.validate(chunkByteCount: data.count)
                try fileHandle.write(contentsOf: data)
                byteBudget.recordAccepted(chunkByteCount: data.count)
                if let pauseAfterBytes,
                   byteBudget.partialSize >= pauseAfterBytes {
                    state = .paused
                    task?.cancel()
                    closeFileLocked()
                }
            } catch TideyBrowserTransferValidationError.declaredTotalExceeded {
                state = .failed
                errorCode = "declared_total_exceeded"
                failureCategory = .validation
                task?.cancel()
                closeFileLocked()
            } catch {
                state = .failed
                errorCode = "write_failed"
                failureCategory = .destination
                task?.cancel()
                closeFileLocked()
            }
        }
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        lock.withLock {
            if state == .running {
                if error == nil {
                    do {
                        try byteBudget.validateCompletion()
                        state = .completed
                    } catch {
                        state = .failed
                        errorCode = "incomplete_transfer"
                        failureCategory = .validation
                    }
                } else {
                    state = .failed
                    errorCode = "network_failed"
                    failureCategory = .retryable
                }
                closeFileLocked()
            }
            self.task = nil
            self.session = nil
        }
        session.invalidateAndCancel()
    }

    private func fail(_ failure: TideyBrowserTransferFailure) {
        lock.withLock {
            guard state == .running else { return }
            state = .failed
            errorCode = failure.code
            failureCategory = failure.category
            task?.cancel()
            closeFileLocked()
        }
    }

    private func closeFileLocked() {
        guard let fileHandle else {
            fileIsQuiescent = true
            return
        }
        do {
            try fileQuiescer.synchronizeAndClose(fileHandle)
            self.fileHandle = nil
            fileIsQuiescent = true
        } catch {
            state = .failed
            errorCode = "quiescence_failed"
            failureCategory = .destination
            fileIsQuiescent = false
        }
    }

    private func snapshotLocked() -> TideyBrowserTransferSnapshot {
        TideyBrowserTransferSnapshot(
            transferID: transferID,
            state: state,
            resumeOffset: resumeOffset,
            bytesWritten: byteBudget.bytesWritten,
            statusCode: statusCode,
            expectedTotal: expectedTotal,
            etag: etag,
            lastModified: lastModified,
            errorCode: errorCode,
            failureCategory: failureCategory,
            quiescent: fileIsQuiescent,
            sourceURL: TideyBrowserTransferRedaction.url(sourceURL),
            destinationRelativePath: destinationRelativePath
        )
    }

    private func header(_ name: String, in headers: [String: String]) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

@MainActor
final class TideyBrowserAuthenticatedTransferManager {
    typealias TransferStarter = (
        TideyBrowserStreamingTransfer,
        [HTTPCookie],
        String?
    ) -> Void

    private var transfers: [String: TideyBrowserStreamingTransfer] = [:]
    private let destinationOpener: any TideyBrowserTransferDestinationOpening
    private let destinationValidator: any TideyBrowserTransferDestinationValidating
    private let preflightExecutor: any TideyBrowserTransferPreflightExecuting
    private let fileQuiescer: any TideyBrowserTransferFileQuiescing
    private let transferStarter: TransferStarter

    init(destinationOpener: any TideyBrowserTransferDestinationOpening =
         TideyBrowserTransferDestinationOpeningExecutor(),
         destinationValidator: any TideyBrowserTransferDestinationValidating =
         TideyBrowserTransferDestinationValidationExecutor(),
         preflightExecutor: any TideyBrowserTransferPreflightExecuting =
         TideyBrowserTransferPreflightExecutor(headerProbe: TideyBrowserTransferHeaderProbe()),
         fileQuiescer: any TideyBrowserTransferFileQuiescing = TideyBrowserTransferFileQuiescer(),
         transferStarter: @escaping TransferStarter = { transfer, cookies, ifRange in
             transfer.start(cookies: cookies, ifRange: ifRange)
         }) {
        self.destinationOpener = destinationOpener
        self.destinationValidator = destinationValidator
        self.preflightExecutor = preflightExecutor
        self.fileQuiescer = fileQuiescer
        self.transferStarter = transferStarter
    }

    func openDestination(_ request: TideyBrowserTransferStartRequest) async throws
        -> TideyBrowserTransferOpenedDestination {
        try await destinationOpener.open(request)
    }

    func preflight(engine: TideyBrowserEngine,
                   request: TideyBrowserTransferPreflightRequest) async throws -> [String: Any] {
        let sourceURL = try await validatedSourceURL(engine: engine, target: request.target)
        do {
            _ = try await destinationValidator.validate(request.destination)
        } catch {
            throw TideyBrowserAutomationProtocolError(
                transferFailure: TideyBrowserTransferFailurePolicy.classify(error)
            )
        }
        let cookies = await matchingCookies(for: sourceURL, engine: engine)
        do {
            return try await preflightExecutor.execute(sourceURL: sourceURL, cookies: cookies)
                .dictionary
        } catch {
            throw TideyBrowserAutomationProtocolError(
                transferFailure: TideyBrowserTransferFailurePolicy.classify(error)
            )
        }
    }

    func start(engine: TideyBrowserEngine,
               request: TideyBrowserTransferStartRequest,
               workspaceID: String,
               ownerSessionID: String) async throws -> [String: Any] {
        let sourceURL = try await validatedSourceURL(engine: engine, target: request.target)
        let opened: TideyBrowserTransferOpenedDestination
        do {
            opened = try await openDestination(request)
        } catch {
            throw TideyBrowserAutomationProtocolError(
                transferFailure: TideyBrowserTransferFailure(
                    category: .destination,
                    code: "destination_validation_failed"
                )
            )
        }
        let cookies = await matchingCookies(for: sourceURL, engine: engine)
        return try admitOpenedDestination(
            opened,
            sourceURL: sourceURL,
            request: request,
            workspaceID: workspaceID,
            ownerSessionID: ownerSessionID,
            cookies: cookies
        )
    }

    func admitOpenedDestination(_ opened: TideyBrowserTransferOpenedDestination,
                                sourceURL: URL,
                                request: TideyBrowserTransferStartRequest,
                                workspaceID: String,
                                ownerSessionID: String,
                                cookies: [HTTPCookie]) throws -> [String: Any] {
        let transferID = UUID().uuidString
        let transfer = TideyBrowserStreamingTransfer(
            transferID: transferID,
            ownerSessionID: ownerSessionID,
            workspaceID: workspaceID,
            sourceURL: sourceURL,
            destinationRelativePath: request.destinationRelativePath,
            request: request,
            fileHandle: opened.fileHandle,
            fileQuiescer: fileQuiescer
        )
        transfers[transferID] = transfer
        transferStarter(transfer, cookies, request.ifRange)
        return transfer.snapshot().dictionary
    }

    func status(transferID: String,
                workspaceID: String,
                ownerSessionID: String) throws -> [String: Any] {
        try ownedTransfer(transferID, workspaceID: workspaceID, ownerSessionID: ownerSessionID)
            .snapshot().dictionary
    }

    func pause(transferID: String,
               workspaceID: String,
               ownerSessionID: String) throws -> [String: Any] {
        try ownedTransfer(transferID, workspaceID: workspaceID, ownerSessionID: ownerSessionID)
            .pause().dictionary
    }

    func cleanupSession(ownerSessionID: String) {
        for transfer in transfers.values where transfer.ownerSessionID == ownerSessionID {
            _ = transfer.pause()
        }
    }

    private func ownedTransfer(_ transferID: String,
                               workspaceID: String,
                               ownerSessionID: String) throws -> TideyBrowserStreamingTransfer {
        guard let transfer = transfers[transferID] else {
            throw protocolError(.targetGone, "Transfer is no longer available")
        }
        guard transfer.workspaceID == workspaceID else {
            throw protocolError(.workspaceMismatch, "Transfer belongs to another workspace")
        }
        guard transfer.ownerSessionID == ownerSessionID else {
            throw protocolError(.ownershipConflict, "Transfer is owned by another session")
        }
        return transfer
    }

    private func validatedSourceURL(engine: TideyBrowserEngine,
                                    target targetReference: TideyBrowserAutomationElementReference)
        async throws -> URL {
        let target = try await engine.automationLinkTarget(targetReference)
        guard target.tag == "a",
              let pageURL = engine.url else {
            throw protocolError(.invalidRequest, "Transfer target must be a page link")
        }
        do {
            return try TideyBrowserTransferRouteValidator.sourceURL(
                pageURL: pageURL,
                href: target.href
            )
        } catch {
            throw protocolError(.invalidURL, "Transfer source is outside the official Vault")
        }
    }

    private func matchingCookies(for url: URL, engine: TideyBrowserEngine) async -> [HTTPCookie] {
        let cookies = await withCheckedContinuation { continuation in
            engine.webView.configuration.websiteDataStore.httpCookieStore.getAllCookies {
                continuation.resume(returning: $0)
            }
        }
        guard let host = url.host?.lowercased() else { return [] }
        let path = url.path.isEmpty ? "/" : url.path
        return cookies.filter { cookie in
            let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            let domainMatches = host == domain || host.hasSuffix("." + domain)
            return domainMatches && path.hasPrefix(cookie.path) && (!cookie.isSecure || url.scheme == "https")
        }
    }

    private func protocolError(_ code: TideyBrowserAutomationErrorCode,
                               _ message: String) -> TideyBrowserAutomationProtocolError {
        TideyBrowserAutomationProtocolError(code: code, message: message)
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
