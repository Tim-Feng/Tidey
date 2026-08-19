import Foundation

struct TideyBrowserNavigationPermit: Hashable, Sendable {
    fileprivate let id: UUID
    let origin: String
}

struct TideyBrowserNavigationGateSnapshot: Equatable, Sendable {
    let activeCount: Int
    let activeByOrigin: [String: Int]
    let queuedCount: Int
}

actor TideyBrowserNavigationGate {
    static let shared = TideyBrowserNavigationGate()

    private struct Waiter {
        let origin: String
        let continuation: CheckedContinuation<TideyBrowserNavigationPermit, Error>
    }

    let maximumConcurrent: Int
    let maximumPerOrigin: Int
    let maximumQueued: Int

    private var activeByID: [UUID: String] = [:]
    private var activeByOrigin: [String: Int] = [:]
    private var waiters: [Waiter] = []

    init(maximumConcurrent: Int = 4,
         maximumPerOrigin: Int = 2,
         maximumQueued: Int = 32) {
        precondition(maximumConcurrent > 0)
        precondition(maximumPerOrigin > 0)
        precondition(maximumQueued >= 0)
        self.maximumConcurrent = maximumConcurrent
        self.maximumPerOrigin = maximumPerOrigin
        self.maximumQueued = maximumQueued
    }

    func acquire(origin: String) async throws -> TideyBrowserNavigationPermit {
        let canonicalOrigin = origin.isEmpty ? "unknown" : origin
        if canStart(origin: canonicalOrigin) {
            return register(origin: canonicalOrigin)
        }
        guard waiters.count < maximumQueued else {
            throw TideyBrowserAutomationProtocolError(
                code: .busy,
                message: "Browser navigation queue is full"
            )
        }
        return try await withCheckedThrowingContinuation { continuation in
            waiters.append(Waiter(origin: canonicalOrigin, continuation: continuation))
        }
    }

    func release(_ permit: TideyBrowserNavigationPermit) {
        guard let origin = activeByID.removeValue(forKey: permit.id) else {
            return
        }
        let nextCount = (activeByOrigin[origin] ?? 1) - 1
        if nextCount == 0 {
            activeByOrigin.removeValue(forKey: origin)
        } else {
            activeByOrigin[origin] = nextCount
        }
        drainQueue()
    }

    func snapshot() -> TideyBrowserNavigationGateSnapshot {
        TideyBrowserNavigationGateSnapshot(
            activeCount: activeByID.count,
            activeByOrigin: activeByOrigin,
            queuedCount: waiters.count
        )
    }

    static func origin(for url: URL?) -> String {
        guard let url,
              let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased() else {
            return "unknown"
        }
        let defaultPort = scheme == "https" ? 443 : (scheme == "http" ? 80 : nil)
        if let port = url.port, port != defaultPort {
            return "\(scheme)://\(host):\(port)"
        }
        return "\(scheme)://\(host)"
    }

    private func canStart(origin: String) -> Bool {
        activeByID.count < maximumConcurrent &&
            (activeByOrigin[origin] ?? 0) < maximumPerOrigin
    }

    private func register(origin: String) -> TideyBrowserNavigationPermit {
        let permit = TideyBrowserNavigationPermit(id: UUID(), origin: origin)
        activeByID[permit.id] = origin
        activeByOrigin[origin, default: 0] += 1
        return permit
    }

    private func drainQueue() {
        while activeByID.count < maximumConcurrent,
              let index = waiters.firstIndex(where: { canStart(origin: $0.origin) }) {
            let waiter = waiters.remove(at: index)
            waiter.continuation.resume(returning: register(origin: waiter.origin))
        }
    }
}
