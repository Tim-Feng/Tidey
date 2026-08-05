import Foundation
import OSLog

struct BridgeActiveSessionStatus: Codable, Equatable {
    let vendor: String
    let workspaceID: String
    let sessionID: String
    let restoreSessionID: String
    let panelID: String?
    let bufferedEventCount: Int
    let oldestSeq: Int?
    let newestSeq: Int?
    let isActive: Bool

    init(vendor: String,
         workspaceID: String,
         sessionID: String,
         panelID: String?,
         restoreSessionID: String? = nil,
         bufferedEventCount: Int,
         oldestSeq: Int?,
         newestSeq: Int?,
         isActive: Bool) {
        self.vendor = vendor
        self.workspaceID = workspaceID
        self.sessionID = sessionID
        self.panelID = panelID
        self.restoreSessionID = restoreSessionID ?? sessionID
        self.bufferedEventCount = bufferedEventCount
        self.oldestSeq = oldestSeq
        self.newestSeq = newestSeq
        self.isActive = isActive
    }

    enum CodingKeys: String, CodingKey {
        case vendor
        case workspaceID = "workspace_id"
        case sessionID = "session_id"
        case restoreSessionID = "restore_session_id"
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

enum BridgePayloadDirection: String, Codable, Equatable, Hashable {
    case inbound
    case outbound
}

struct BridgePayloadStatsSnapshot: Codable, Equatable {
    let direction: BridgePayloadDirection
    let messageType: String
    let count: Int
    let totalBytes: Int
    let maxBytes: Int
    let averageBytes: Double
    let averageDurationMs: Double
    let maxDurationMs: Double
    let lastBytes: Int
    let lastDurationMs: Double

    enum CodingKeys: String, CodingKey {
        case direction
        case messageType = "message_type"
        case count
        case totalBytes = "total_bytes"
        case maxBytes = "max_bytes"
        case averageBytes = "average_bytes"
        case averageDurationMs = "average_duration_ms"
        case maxDurationMs = "max_duration_ms"
        case lastBytes = "last_bytes"
        case lastDurationMs = "last_duration_ms"
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

enum BridgeConnectionEventKind: String, Codable, Equatable {
    case connected
    case peerClose = "peer_close"
    case channelError = "channel_error"
    case writeFailed = "write_failed"
    case encodeFailed = "encode_failed"
    case disconnected
}

struct BridgeConnectionEventSnapshot: Codable, Equatable {
    let timestamp: Date
    let connectionID: String
    let kind: BridgeConnectionEventKind
    let durationMs: Double?
    let closeCode: Int?
    let reasonByteCount: Int?
    let errorType: String?
    let errorDomain: String?
    let errorCode: Int?
    let messageType: String?
    let byteCount: Int?
    let terminalStreamSubscriptionCount: Int
    let agentSubscriptionCount: Int
    let workspaceSubscriptionCount: Int

    init(connectionID: String,
         kind: BridgeConnectionEventKind,
         timestamp: Date = Date(),
         durationMs: Double? = nil,
         closeCode: Int? = nil,
         reasonByteCount: Int? = nil,
         errorType: String? = nil,
         errorDomain: String? = nil,
         errorCode: Int? = nil,
         messageType: String? = nil,
         byteCount: Int? = nil,
         terminalStreamSubscriptionCount: Int = 0,
         agentSubscriptionCount: Int = 0,
         workspaceSubscriptionCount: Int = 0) {
        self.timestamp = timestamp
        self.connectionID = connectionID
        self.kind = kind
        self.durationMs = durationMs
        self.closeCode = closeCode
        self.reasonByteCount = reasonByteCount
        self.errorType = errorType
        self.errorDomain = errorDomain
        self.errorCode = errorCode
        self.messageType = messageType
        self.byteCount = byteCount
        self.terminalStreamSubscriptionCount = terminalStreamSubscriptionCount
        self.agentSubscriptionCount = agentSubscriptionCount
        self.workspaceSubscriptionCount = workspaceSubscriptionCount
    }

    enum CodingKeys: String, CodingKey {
        case timestamp
        case connectionID = "connection_id"
        case kind
        case durationMs = "duration_ms"
        case closeCode = "close_code"
        case reasonByteCount = "reason_byte_count"
        case errorType = "error_type"
        case errorDomain = "error_domain"
        case errorCode = "error_code"
        case messageType = "message_type"
        case byteCount = "byte_count"
        case terminalStreamSubscriptionCount = "terminal_stream_subscription_count"
        case agentSubscriptionCount = "agent_subscription_count"
        case workspaceSubscriptionCount = "workspace_subscription_count"
    }
}

struct BridgeAdminStatusSnapshot: Codable, Equatable {
    let generatedAt: Date
    let activeSessions: [BridgeActiveSessionStatus]
    let fetchStats: BridgeFetchStatsSnapshot
    let payloadStats: [BridgePayloadStatsSnapshot]
    let slowOperations: [BridgeSlowOperationSnapshot]
    let activeTerminalStreamSubscriptionCount: Int
    let connectionEvents: [BridgeConnectionEventSnapshot]

    enum CodingKeys: String, CodingKey {
        case generatedAt = "generated_at"
        case activeSessions = "active_sessions"
        case fetchStats = "fetch_stats"
        case payloadStats = "payload_stats"
        case slowOperations = "slow_operations"
        case activeTerminalStreamSubscriptionCount = "active_terminal_stream_subscription_count"
        case connectionEvents = "connection_events"
    }
}

enum BridgeLogger {
    static let server = Logger(subsystem: "com.tidey.remote-bridge", category: "server")
    static let fetch = Logger(subsystem: "com.tidey.remote-bridge", category: "fetch")
    static let input = Logger(subsystem: "com.tidey.remote-bridge", category: "input")
    static let payload = Logger(subsystem: "com.tidey.remote-bridge", category: "payload")
    static let connection = Logger(subsystem: "com.tidey.remote-bridge", category: "connection")
}

private struct BridgePayloadStatsAccumulator {
    let direction: BridgePayloadDirection
    let messageType: String
    var count = 0
    var totalBytes = 0
    var maxBytes = 0
    var totalDurationMs: Double = 0
    var maxDurationMs: Double = 0
    var lastBytes = 0
    var lastDurationMs: Double = 0

    mutating func record(byteCount: Int, durationMs: Double) {
        count += 1
        totalBytes += byteCount
        maxBytes = max(maxBytes, byteCount)
        totalDurationMs += durationMs
        maxDurationMs = max(maxDurationMs, durationMs)
        lastBytes = byteCount
        lastDurationMs = durationMs
    }

    var snapshot: BridgePayloadStatsSnapshot {
        BridgePayloadStatsSnapshot(direction: direction,
                                   messageType: messageType,
                                   count: count,
                                   totalBytes: totalBytes,
                                   maxBytes: maxBytes,
                                   averageBytes: count > 0 ? Double(totalBytes) / Double(count) : 0,
                                   averageDurationMs: count > 0 ? totalDurationMs / Double(count) : 0,
                                   maxDurationMs: maxDurationMs,
                                   lastBytes: lastBytes,
                                   lastDurationMs: lastDurationMs)
    }
}

final class BridgeObservabilityCenter {
    private let queue = DispatchQueue(label: "com.tidey.remote-bridge.observability")
    private let slowFetchThresholdMs: Double
    private let maxSlowOperations: Int
    private let maxConnectionEvents: Int

    private var totalFetches = 0
    private var fetchesWithBackfill = 0
    private var cumulativeFetchDurationMs: Double = 0
    private var maxFetchDurationMs: Double = 0
    private var lastFetch: BridgeFetchObservation?
    private var slowOperations = [BridgeSlowOperationSnapshot]()
    private var payloadStats = [String: BridgePayloadStatsAccumulator]()
    private var connectionEvents = [BridgeConnectionEventSnapshot]()
    private var activeTerminalStreamSubscriptionCounts = [String: Int]()

    init(slowFetchThresholdMs: Double = 250,
         maxSlowOperations: Int = 20,
         maxConnectionEvents: Int = 20) {
        self.slowFetchThresholdMs = slowFetchThresholdMs
        self.maxSlowOperations = maxSlowOperations
        self.maxConnectionEvents = max(0, maxConnectionEvents)
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

    func recordPayload(direction: BridgePayloadDirection,
                       messageType: String,
                       byteCount: Int,
                       durationMs: Double) {
        queue.sync {
            let key = "\(direction.rawValue):\(messageType)"
            if payloadStats[key] == nil {
                payloadStats[key] = BridgePayloadStatsAccumulator(direction: direction,
                                                                  messageType: messageType)
            }
            payloadStats[key]?.record(byteCount: byteCount, durationMs: durationMs)
            BridgeLogger.payload.debug("payload direction=\(direction.rawValue, privacy: .public) type=\(messageType, privacy: .public) bytes=\(byteCount) duration_ms=\(durationMs, format: .fixed(precision: 2))")
        }
    }

    func recordConnectionEvent(_ event: BridgeConnectionEventSnapshot) {
        queue.sync {
            connectionEvents.append(event)
            if connectionEvents.count > maxConnectionEvents {
                connectionEvents.removeFirst(connectionEvents.count - maxConnectionEvents)
            }
            BridgeLogger.connection.notice("connection event kind=\(event.kind.rawValue, privacy: .public) connection_id=\(event.connectionID, privacy: .public)")
        }
    }

    func setActiveTerminalStreamSubscriptionCount(_ count: Int, forConnectionID connectionID: String) {
        queue.sync {
            if count > 0 {
                activeTerminalStreamSubscriptionCounts[connectionID] = count
            } else {
                activeTerminalStreamSubscriptionCounts.removeValue(forKey: connectionID)
            }
        }
    }

    func clearActiveTerminalStreamSubscriptionCount(forConnectionID connectionID: String) {
        queue.sync {
            _ = activeTerminalStreamSubscriptionCounts.removeValue(forKey: connectionID)
        }
    }

    func snapshot(activeSessions: [BridgeActiveSessionStatus]) -> BridgeAdminStatusSnapshot {
        queue.sync {
            let average = totalFetches > 0 ? cumulativeFetchDurationMs / Double(totalFetches) : 0
            let payloadSnapshots = payloadStats.values
                .map(\.snapshot)
                .sorted { lhs, rhs in
                    if lhs.direction == rhs.direction {
                        return lhs.messageType < rhs.messageType
                    }
                    return lhs.direction.rawValue < rhs.direction.rawValue
                }
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
                                             payloadStats: payloadSnapshots,
                                             slowOperations: slowOperations.sorted { $0.timestamp > $1.timestamp },
                                             activeTerminalStreamSubscriptionCount: activeTerminalStreamSubscriptionCounts.values.reduce(0, +),
                                             connectionEvents: connectionEvents)
        }
    }
}
