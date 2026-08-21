import Darwin
import Foundation
import WebKit

struct TideyBrowserTransferStartRequest: Equatable {
    let target: TideyBrowserAutomationElementReference
    let archiveRoot: String
    let expectedVolumeUUID: String
    let destinationRelativePath: String
    let resumeOffset: Int
    let ifRange: String?
    let pauseAfterBytes: Int?
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
                         headers: [String: String]) throws -> TideyBrowserTransferResponseDecision {
        guard resumeOffset >= 0 else {
            throw TideyBrowserTransferValidationError.invalidResponse
        }
        switch statusCode {
        case 200:
            guard resumeOffset == 0 else {
                throw TideyBrowserTransferValidationError.invalidResponse
            }
            return .fresh(expectedTotal: positiveInteger(header("Content-Length", in: headers)))
        case 206:
            guard let rawRange = header("Content-Range", in: headers),
                  let range = parseSatisfiedContentRange(rawRange),
                  range.start == resumeOffset else {
                throw TideyBrowserTransferValidationError.invalidResponse
            }
            return .resumed(expectedTotal: range.total)
        case 416:
            return .rangeNotSatisfiable(
                remoteTotal: parseUnsatisfiedContentRange(header("Content-Range", in: headers))
            )
        default:
            throw TideyBrowserTransferValidationError.invalidResponse
        }
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

    private static func parseSatisfiedContentRange(_ raw: String) -> (start: Int, total: Int?)? {
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
        return (start, total)
    }

    private static func parseUnsatisfiedContentRange(_ raw: String?) -> Int? {
        guard let raw else { return nil }
        let normalized = raw.lowercased()
        guard normalized.hasPrefix("bytes */") else { return nil }
        return positiveInteger(String(normalized.dropFirst("bytes */".count)))
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

private struct TideyBrowserTransferVolumeInfo {
    let uuid: String
    let mountPoint: String
    let isInternal: Bool
    let isWritable: Bool
}

private enum TideyBrowserTransferDiskInspector {
    static func inspect(path: String) throws -> TideyBrowserTransferVolumeInfo {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        process.arguments = ["info", "-plist", path]
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
    static func open(_ request: TideyBrowserTransferStartRequest) throws -> (URL, FileHandle) {
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
        let descriptor: Int32
        if request.resumeOffset == 0 {
            guard !exists, errno == ENOENT else {
                throw TideyBrowserTransferValidationError.invalidDestination
            }
            descriptor = Darwin.open(
                destination.path,
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                S_IRUSR | S_IWUSR
            )
        } else {
            guard exists,
                  (status.st_mode & S_IFMT) == S_IFREG,
                  Int(status.st_size) == request.resumeOffset else {
                throw TideyBrowserTransferValidationError.invalidDestination
            }
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

private enum TideyBrowserTransferState: String {
    case running
    case paused
    case completed
    case rangeNotSatisfiable = "range_not_satisfiable"
    case failed
}

private struct TideyBrowserTransferSnapshot {
    let transferID: String
    let state: TideyBrowserTransferState
    let resumeOffset: Int
    let bytesWritten: Int
    let statusCode: Int?
    let expectedTotal: Int?
    let etag: String?
    let lastModified: String?
    let errorCode: String?
    let sourceURL: String
    let destinationRelativePath: String

    var dictionary: [String: Any] {
        var result: [String: Any] = [
            "transfer_id": transferID,
            "state": state.rawValue,
            "resume_offset": resumeOffset,
            "bytes_written": bytesWritten,
            "partial_size": resumeOffset + bytesWritten,
            "source_url": sourceURL,
            "destination_relative_path": destinationRelativePath,
        ]
        if let statusCode { result["http_status"] = statusCode }
        if let expectedTotal { result["expected_total"] = expectedTotal }
        if let etag { result["etag"] = etag }
        if let lastModified { result["last_modified"] = lastModified }
        if let errorCode { result["error_code"] = errorCode }
        return result
    }
}

private final class TideyBrowserStreamingTransfer: NSObject,
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
    private let ifRange: String?
    private let pauseAfterBytes: Int?
    private var fileHandle: FileHandle?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var state: TideyBrowserTransferState = .running
    private var bytesWritten = 0
    private var statusCode: Int?
    private var expectedTotal: Int?
    private var etag: String?
    private var lastModified: String?
    private var errorCode: String?

    init(transferID: String,
         ownerSessionID: String,
         workspaceID: String,
         sourceURL: URL,
         destinationRelativePath: String,
         request: TideyBrowserTransferStartRequest,
         fileHandle: FileHandle) {
        self.transferID = transferID
        self.ownerSessionID = ownerSessionID
        self.workspaceID = workspaceID
        self.sourceURL = sourceURL
        self.destinationRelativePath = destinationRelativePath
        self.resumeOffset = request.resumeOffset
        self.ifRange = request.ifRange
        self.pauseAfterBytes = request.pauseAfterBytes
        self.fileHandle = fileHandle
    }

    func start(cookies: [HTTPCookie], ifRange: String?) {
        var request = URLRequest(url: sourceURL)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        if resumeOffset > 0 {
            request.setValue("bytes=\(resumeOffset)-", forHTTPHeaderField: "Range")
            if let ifRange { request.setValue(ifRange, forHTTPHeaderField: "If-Range") }
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
            if let ifRange {
                redirected.setValue(ifRange, forHTTPHeaderField: "If-Range")
            }
        }
        completionHandler(redirected)
    }

    func urlSession(_ session: URLSession,
                    dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse else {
            fail(code: "invalid_response")
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
                headers: headers
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
        } catch {
            fail(code: resumeOffset > 0 && response.statusCode == 200
                 ? "range_not_honored" : "invalid_response")
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession,
                    dataTask: URLSessionDataTask,
                    didReceive data: Data) {
        lock.withLock {
            guard state == .running, let fileHandle else { return }
            do {
                try fileHandle.write(contentsOf: data)
                bytesWritten += data.count
                if let pauseAfterBytes,
                   resumeOffset + bytesWritten >= pauseAfterBytes {
                    state = .paused
                    task?.cancel()
                    closeFileLocked()
                }
            } catch {
                state = .failed
                errorCode = "write_failed"
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
                    state = .completed
                } else {
                    state = .failed
                    errorCode = "network_failed"
                }
                closeFileLocked()
            }
            self.task = nil
            self.session = nil
        }
        session.invalidateAndCancel()
    }

    private func fail(code: String) {
        lock.withLock {
            guard state == .running else { return }
            state = .failed
            errorCode = code
            task?.cancel()
            closeFileLocked()
        }
    }

    private func closeFileLocked() {
        guard let fileHandle else { return }
        try? fileHandle.synchronize()
        try? fileHandle.close()
        self.fileHandle = nil
    }

    private func snapshotLocked() -> TideyBrowserTransferSnapshot {
        TideyBrowserTransferSnapshot(
            transferID: transferID,
            state: state,
            resumeOffset: resumeOffset,
            bytesWritten: bytesWritten,
            statusCode: statusCode,
            expectedTotal: expectedTotal,
            etag: etag,
            lastModified: lastModified,
            errorCode: errorCode,
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
    private var transfers: [String: TideyBrowserStreamingTransfer] = [:]
    private let destinationOpener: any TideyBrowserTransferDestinationOpening

    init(destinationOpener: any TideyBrowserTransferDestinationOpening =
         TideyBrowserTransferDestinationOpeningExecutor()) {
        self.destinationOpener = destinationOpener
    }

    func openDestination(_ request: TideyBrowserTransferStartRequest) async throws
        -> TideyBrowserTransferOpenedDestination {
        try await destinationOpener.open(request)
    }

    func start(engine: TideyBrowserEngine,
               request: TideyBrowserTransferStartRequest,
               workspaceID: String,
               ownerSessionID: String) async throws -> [String: Any] {
        let target = try await engine.automationLinkTarget(request.target)
        guard target.tag == "a",
              let pageURL = engine.url else {
            throw protocolError(.invalidRequest, "Transfer target must be a page link")
        }
        let sourceURL: URL
        do {
            sourceURL = try TideyBrowserTransferRouteValidator.sourceURL(
                pageURL: pageURL,
                href: target.href
            )
        } catch {
            throw protocolError(.invalidURL, "Transfer source is outside the official Vault")
        }
        let opened: TideyBrowserTransferOpenedDestination
        do {
            opened = try await openDestination(request)
        } catch {
            throw protocolError(.invalidRequest, "Transfer destination is unsafe or unavailable")
        }
        let cookies = await matchingCookies(for: sourceURL, engine: engine)
        let transferID = UUID().uuidString
        let transfer = TideyBrowserStreamingTransfer(
            transferID: transferID,
            ownerSessionID: ownerSessionID,
            workspaceID: workspaceID,
            sourceURL: sourceURL,
            destinationRelativePath: request.destinationRelativePath,
            request: request,
            fileHandle: opened.fileHandle
        )
        transfers[transferID] = transfer
        transfer.start(cookies: cookies, ifRange: request.ifRange)
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
