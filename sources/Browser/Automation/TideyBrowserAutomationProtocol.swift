import Foundation

enum TideyBrowserAutomationOperation: String, CaseIterable, Equatable {
    case tabs
    case open
    case claim
    case release
    case reclaim
    case mark
    case close
    case present
    case navigate
    case back
    case forward
    case reload
    case currentURL = "current_url"
    case snapshot
    case click
    case fill
    case type
    case key
    case scroll
    case wait
    case screenshot
}

struct TideyBrowserAutomationElementReference: Equatable {
    let tabID: String
    let navigationEpoch: Int
    let elementID: String
}

enum TideyBrowserAutomationWaitCondition: Equatable {
    case load(timeout: TimeInterval)
    case delay(milliseconds: Int)
    case text(String, timeout: TimeInterval)
    case url(String, timeout: TimeInterval)
}

enum TideyBrowserAutomationCommand: Equatable {
    case tabs
    case open(url: URL)
    case claim(tabID: String)
    case release(tabID: String)
    case reclaim(tabID: String)
    case mark(tabID: String, mark: TideyBrowserAutomationTabMark)
    case close(tabID: String)
    case present(tabID: String)
    case navigate(tabID: String, url: URL)
    case back(tabID: String)
    case forward(tabID: String)
    case reload(tabID: String)
    case currentURL(tabID: String)
    case snapshot(tabID: String)
    case click(target: TideyBrowserAutomationElementReference)
    case fill(target: TideyBrowserAutomationElementReference, text: String)
    case type(target: TideyBrowserAutomationElementReference, text: String)
    case key(tabID: String, key: String)
    case scroll(tabID: String, deltaX: Double, deltaY: Double)
    case wait(tabID: String, condition: TideyBrowserAutomationWaitCondition)
    case screenshot(tabID: String)
}

struct TideyBrowserAutomationRequest: Equatable {
    let workspaceID: String
    let command: TideyBrowserAutomationCommand
}

enum TideyBrowserAutomationErrorCode: String, Equatable {
    case invalidRequest = "invalid_request"
    case invalidURL = "invalid_url"
    case unsupportedScheme = "unsupported_scheme"
    case unsupportedOperation = "unsupported_operation"
    case targetGone = "target_gone"
    case ownershipConflict = "ownership_conflict"
    case workspaceMismatch = "workspace_mismatch"
    case staleReference = "stale_reference"
    case tabLimitReached = "tab_limit_reached"
    case busy
    case timeout
    case navigationFailed = "navigation_failed"
    case internalError = "internal_error"
}

struct TideyBrowserAutomationProtocolError: Error, Equatable {
    let code: TideyBrowserAutomationErrorCode
    let message: String
}

struct TideyBrowserAutomationResponse: Equatable {
    let result: [String: TideyBrowserAutomationValue]
}

indirect enum TideyBrowserAutomationValue: Equatable {
    case null
    case bool(Bool)
    case integer(Int)
    case number(Double)
    case string(String)
    case array([TideyBrowserAutomationValue])
    case object([String: TideyBrowserAutomationValue])
}
