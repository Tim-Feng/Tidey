import Foundation
import AppKit
import WebKit

enum TideyBrowserAutomationScriptError: Error {
    case missingResource
}

enum TideyBrowserAutomationScript {
    static let resourceName = "tidey-browser-automation"
    static let contentWorld = WKContentWorld.world(name: "com.tidey.browser-automation")

    static func source(bundle: Bundle = .main) throws -> String {
        guard let url = bundle.url(forResource: resourceName, withExtension: "js") else {
            throw TideyBrowserAutomationScriptError.missingResource
        }
        return try String(contentsOf: url, encoding: .utf8)
    }
}

extension TideyBrowserEngine {
    var automationContentWorld: WKContentWorld {
        TideyBrowserAutomationScript.contentWorld
    }

    func automationSnapshot(tabID: String) async throws -> [String: Any] {
        var result = try await automationExecute(operation: "snapshot")
        result["tab_id"] = tabID
        result["navigation_epoch"] = automationNavigationEpoch
        return result
    }

    func automationClick(_ target: TideyBrowserAutomationElementReference) async throws {
        try validateAutomationReference(target)
        _ = try await automationExecute(
            operation: "click",
            arguments: ["element_id": target.elementID]
        )
    }

    func automationLinkTarget(_ target: TideyBrowserAutomationElementReference) async throws
        -> (tag: String, href: String) {
        try validateAutomationReference(target)
        let result = try await automationExecute(
            operation: "describe_target",
            arguments: ["element_id": target.elementID]
        )
        guard let tag = result["tag"] as? String,
              let href = result["href"] as? String else {
            throw TideyBrowserAutomationProtocolError(
                code: .invalidRequest,
                message: "Browser element is not a link"
            )
        }
        return (tag, href)
    }

    func automationFill(_ target: TideyBrowserAutomationElementReference,
                        text: String) async throws {
        try validateAutomationReference(target)
        _ = try await automationExecute(
            operation: "fill",
            arguments: ["element_id": target.elementID, "text": text]
        )
    }

    func automationType(_ target: TideyBrowserAutomationElementReference,
                        text: String) async throws {
        try validateAutomationReference(target)
        _ = try await automationExecute(
            operation: "type",
            arguments: ["element_id": target.elementID, "text": text]
        )
    }

    func automationKey(_ key: String) async throws {
        _ = try await automationExecute(operation: "key", arguments: ["key": key])
    }

    func automationScroll(deltaX: Double, deltaY: Double) async throws -> [String: Any] {
        try await automationExecute(
            operation: "scroll",
            arguments: ["delta_x": deltaX, "delta_y": deltaY]
        )
    }

    func automationWait(_ condition: TideyBrowserAutomationWaitCondition) async throws {
        switch condition {
        case .delay(let milliseconds):
            try await Task.sleep(nanoseconds: UInt64(milliseconds) * 1_000_000)
        case .load(let timeout):
            try await automationPoll(timeout: timeout) { !self.isLoading }
        case .text(let text, let timeout):
            try await automationPoll(timeout: timeout) {
                let result = try await self.automationExecute(
                    operation: "contains_text",
                    arguments: ["text": text]
                )
                return result["found"] as? Bool == true
            }
        case .url(let value, let timeout):
            try await automationPoll(timeout: timeout) {
                self.url?.absoluteString.contains(value) == true
            }
        }
    }

    func automationScreenshotPNG() async throws -> Data {
        let image: NSImage = try await withCheckedThrowingContinuation { continuation in
            webView.takeSnapshot(with: nil) { image, error in
                if let image {
                    continuation.resume(returning: image)
                } else {
                    continuation.resume(throwing: error ?? TideyBrowserAutomationProtocolError(
                        code: .internalError,
                        message: "WebKit did not return a screenshot"
                    ))
                }
            }
        }
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            throw TideyBrowserAutomationProtocolError(
                code: .internalError,
                message: "Could not encode browser screenshot"
            )
        }
        return pngData
    }

    func automationPerformPotentialNavigation(
        startupGrace: TimeInterval = 0.15,
        timeout: TimeInterval = 30,
        action: @MainActor () async throws -> Void
    ) async throws {
        let previousEpoch = automationNavigationEpoch
        var actionError: Error?
        do {
            try await action()
        } catch {
            actionError = error
        }

        let startupDeadline = Date().addingTimeInterval(startupGrace)
        var navigationStarted = isLoading || automationNavigationEpoch > previousEpoch
        while !navigationStarted && Date() < startupDeadline {
            try await Task.sleep(nanoseconds: 10_000_000)
            navigationStarted = isLoading || automationNavigationEpoch > previousEpoch
        }
        guard navigationStarted else {
            if let actionError {
                throw actionError
            }
            return
        }

        let completionDeadline = Date().addingTimeInterval(timeout)
        while Date() < completionDeadline {
            if !isLoading {
                return
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw TideyBrowserAutomationProtocolError(
            code: .timeout,
            message: "Browser navigation timed out"
        )
    }

    private func validateAutomationReference(
        _ target: TideyBrowserAutomationElementReference
    ) throws {
        guard target.navigationEpoch == automationNavigationEpoch else {
            throw TideyBrowserAutomationProtocolError(
                code: .staleReference,
                message: "Element reference belongs to an earlier navigation"
            )
        }
    }

    private func automationExecute(operation: String,
                                   arguments: [String: Any] = [:]) async throws -> [String: Any] {
        let source: String
        do {
            source = try TideyBrowserAutomationScript.source()
        } catch {
            throw TideyBrowserAutomationProtocolError(
                code: .internalError,
                message: "Browser automation resource is unavailable"
            )
        }

        let rawResult: Any?
        do {
            rawResult = try await webView.callAsyncJavaScript(
                source,
                arguments: [
                    "operation": operation,
                    "argumentsObject": arguments,
                ],
                in: nil,
                contentWorld: automationContentWorld
            )
        } catch {
            throw TideyBrowserAutomationProtocolError(
                code: .navigationFailed,
                message: "WebKit page operation failed"
            )
        }
        guard let result = rawResult as? [String: Any] else {
            throw TideyBrowserAutomationProtocolError(
                code: .internalError,
                message: "Browser page returned an invalid result"
            )
        }
        if let errorCode = result["error"] as? String {
            switch errorCode {
            case "target_gone":
                throw TideyBrowserAutomationProtocolError(
                    code: .targetGone,
                    message: "Browser element is no longer available"
                )
            case "invalid_target":
                throw TideyBrowserAutomationProtocolError(
                    code: .invalidRequest,
                    message: "Browser element does not support this operation"
                )
            default:
                throw TideyBrowserAutomationProtocolError(
                    code: .unsupportedOperation,
                    message: "Browser page operation is unsupported"
                )
            }
        }
        return result
    }

    private func automationPoll(timeout: TimeInterval,
                                condition: @escaping @MainActor () async throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try await condition() {
                return
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw TideyBrowserAutomationProtocolError(
            code: .timeout,
            message: "Browser wait timed out"
        )
    }
}
