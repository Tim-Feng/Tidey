import Foundation
import OSLog

struct BridgeActiveSessionStatus: Codable, Equatable {
    let vendor: String
    let workspaceID: String
    let sessionID: String
    let panelID: String?
    let bufferedEventCount: Int
    let oldestSeq: Int?
    let newestSeq: Int?
    let isActive: Bool

    enum CodingKeys: String, CodingKey {
        case vendor
        case workspaceID = "workspace_id"
        case sessionID = "session_id"
        case panelID = "panel_id"
        case bufferedEventCount = "buffered_event_count"
        case oldestSeq = "oldest_seq"
        case newestSeq = "newest_seq"
        case isActive = "is_active"
    }
}

struct BridgeFetchObservation: Codable, Equatable {
    let workspaceID: String
    let sessionID: String?
    let limit: Int
    let beforeSeq: Int?
    let afterSeq: Int?
    let returnedCount: Int
    let didBackfill: Bool
    let durationMs: Double
    let timestamp: Date

    enum CodingKeys: String, CodingKey {
        case workspaceID = "workspace_id"
        case sessionID = "session_id"
        case limit
        case beforeSeq = "before_seq"
        case afterSeq = "after_seq"
        case returnedCount = "returned_count"
        case didBackfill = "did_backfill"
        case durationMs = "duration_ms"
        case timestamp
    }
}

struct BridgeFetchStatsSnapshot: Codable, Equatable {
    let totalFetches: Int
    let fetchesWithBackfill: Int
    let averageDurationMs: Double
    let maxDurationMs: Double
    let lastFetch: BridgeFetchObservation?

    enum CodingKeys: String, CodingKey {
        case totalFetches = "total_fetches"
        case fetchesWithBackfill = "fetches_with_backfill"
        case averageDurationMs = "average_duration_ms"
        case maxDurationMs = "max_duration_ms"
        case lastFetch = "last_fetch"
    }
}

struct BridgeSlowOperationSnapshot: Codable, Equatable {
    let name: String
    let sessionID: String?
    let durationMs: Double
    let timestamp: Date
    let detail: String

    enum CodingKeys: String, CodingKey {
        case name
        case sessionID = "session_id"
        case durationMs = "duration_ms"
        case timestamp
        case detail
    }
}

struct BridgeAdminStatusSnapshot: Codable, Equatable {
    let generatedAt: Date
    let activeSessions: [BridgeActiveSessionStatus]
    let fetchStats: BridgeFetchStatsSnapshot
    let slowOperations: [BridgeSlowOperationSnapshot]

    enum CodingKeys: String, CodingKey {
        case generatedAt = "generated_at"
        case activeSessions = "active_sessions"
        case fetchStats = "fetch_stats"
        case slowOperations = "slow_operations"
    }
}

enum BridgeLogger {
    static let server = Logger(subsystem: "com.tidey.remote-bridge", category: "server")
    static let fetch = Logger(subsystem: "com.tidey.remote-bridge", category: "fetch")
    static let input = Logger(subsystem: "com.tidey.remote-bridge", category: "input")
}

final class BridgeObservabilityCenter {
    private let queue = DispatchQueue(label: "com.tidey.remote-bridge.observability")
    private let slowFetchThresholdMs: Double
    private let maxSlowOperations: Int

    private var totalFetches = 0
    private var fetchesWithBackfill = 0
    private var cumulativeFetchDurationMs: Double = 0
    private var maxFetchDurationMs: Double = 0
    private var lastFetch: BridgeFetchObservation?
    private var slowOperations = [BridgeSlowOperationSnapshot]()

    init(slowFetchThresholdMs: Double = 250,
         maxSlowOperations: Int = 20) {
        self.slowFetchThresholdMs = slowFetchThresholdMs
        self.maxSlowOperations = maxSlowOperations
    }

    func recordFetch(workspaceID: String,
                     sessionID: String?,
                     limit: Int,
                     beforeSeq: Int?,
                     afterSeq: Int?,
                     returnedCount: Int,
                     didBackfill: Bool,
                     durationMs: Double) {
        let detail = "limit=\(limit) returned=\(returnedCount) before=\(beforeSeq.map(String.init) ?? "-") after=\(afterSeq.map(String.init) ?? "-") backfill=\(didBackfill)"
        queue.sync {
            totalFetches += 1
            if didBackfill {
                fetchesWithBackfill += 1
            }
            cumulativeFetchDurationMs += durationMs
            maxFetchDurationMs = max(maxFetchDurationMs, durationMs)
            lastFetch = BridgeFetchObservation(workspaceID: workspaceID,
                                               sessionID: sessionID,
                                               limit: limit,
                                               beforeSeq: beforeSeq,
                                               afterSeq: afterSeq,
                                               returnedCount: returnedCount,
                                               didBackfill: didBackfill,
                                               durationMs: durationMs,
                                               timestamp: Date())
            guard durationMs >= slowFetchThresholdMs else {
                return
            }
            let slowOp = BridgeSlowOperationSnapshot(name: "fetch_agent_events",
                                                     sessionID: sessionID,
                                                     durationMs: durationMs,
                                                     timestamp: Date(),
                                                     detail: detail)
            slowOperations.append(slowOp)
            if slowOperations.count > maxSlowOperations {
                slowOperations.removeFirst(slowOperations.count - maxSlowOperations)
            }
            BridgeLogger.fetch.notice("slow fetch_agent_events duration_ms=\(durationMs, format: .fixed(precision: 2)) session_id=\(sessionID ?? "-", privacy: .public) detail=\(detail, privacy: .public)")
        }
    }

    func snapshot(activeSessions: [BridgeActiveSessionStatus]) -> BridgeAdminStatusSnapshot {
        queue.sync {
            let average = totalFetches > 0 ? cumulativeFetchDurationMs / Double(totalFetches) : 0
            return BridgeAdminStatusSnapshot(generatedAt: Date(),
                                             activeSessions: activeSessions.sorted { lhs, rhs in
                                                 if lhs.workspaceID == rhs.workspaceID {
                                                     return lhs.sessionID < rhs.sessionID
                                                 }
                                                 return lhs.workspaceID < rhs.workspaceID
                                             },
                                             fetchStats: BridgeFetchStatsSnapshot(totalFetches: totalFetches,
                                                                                  fetchesWithBackfill: fetchesWithBackfill,
                                                                                  averageDurationMs: average,
                                                                                  maxDurationMs: maxFetchDurationMs,
                                                                                  lastFetch: lastFetch),
                                             slowOperations: slowOperations.sorted { $0.timestamp > $1.timestamp })
        }
    }
}
