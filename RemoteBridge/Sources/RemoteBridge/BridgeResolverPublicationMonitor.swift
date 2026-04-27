import Foundation

protocol BridgeCloudflaredStatusReading {
    func readStatus() throws -> BridgeCloudflaredStatus
}

extension BridgeCloudflaredStatusStore: BridgeCloudflaredStatusReading {}

protocol BridgeTunnelEndpointPublishing {
    func publishTunnelEndpoint(_ endpoint: BridgePairEndpoint) throws
}

extension BridgeResolverPublisher: BridgeTunnelEndpointPublishing {}

final class BridgeResolverPublicationMonitor {
    static let defaultPollingInterval: TimeInterval = 10
    static let defaultHeartbeatInterval: TimeInterval = 3 * 60

    private let statusReader: BridgeCloudflaredStatusReading
    private let publisher: BridgeTunnelEndpointPublishing
    private let pollingInterval: TimeInterval
    private let heartbeatInterval: TimeInterval
    private let nowProvider: () -> Date
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    private var lastPublishedEndpoint: BridgePairEndpoint?
    private var lastPublishedAt: Date?

    init(statusReader: BridgeCloudflaredStatusReading,
         publisher: BridgeTunnelEndpointPublishing,
         pollingInterval: TimeInterval = BridgeResolverPublicationMonitor.defaultPollingInterval,
         heartbeatInterval: TimeInterval = BridgeResolverPublicationMonitor.defaultHeartbeatInterval,
         nowProvider: @escaping () -> Date = Date.init,
         queue: DispatchQueue = DispatchQueue(label: "com.tidey.remote-bridge.resolver-publication")) {
        self.statusReader = statusReader
        self.publisher = publisher
        self.pollingInterval = pollingInterval
        self.heartbeatInterval = heartbeatInterval
        self.nowProvider = nowProvider
        self.queue = queue
    }

    deinit {
        stop()
    }

    func start() {
        lock.lock()
        guard timer == nil else {
            lock.unlock()
            return
        }

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: pollingInterval)
        timer.setEventHandler { [weak self] in
            self?.pollOnce()
        }
        self.timer = timer
        lock.unlock()
        timer.resume()
    }

    func stop() {
        lock.lock()
        let timer = self.timer
        self.timer = nil
        lock.unlock()
        timer?.cancel()
    }

    func pollOnce() {
        let status: BridgeCloudflaredStatus
        do {
            status = try statusReader.readStatus()
        } catch {
            BridgeLogger.server.error("resolver publish skipped cloudflared_state_read_error=\(error.localizedDescription, privacy: .public)")
            return
        }

        guard status.state == .online,
              let endpoint = status.endpoint else {
            return
        }

        let now = nowProvider()
        guard shouldPublish(endpoint: endpoint, now: now) else {
            return
        }

        do {
            try publisher.publishTunnelEndpoint(endpoint)
            markPublished(endpoint: endpoint, at: now)
            BridgeLogger.server.info("resolver published tunnel endpoint host=\(endpoint.host, privacy: .public)")
        } catch {
            BridgeLogger.server.error("resolver publish failed host=\(endpoint.host, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
        }
    }

    private func shouldPublish(endpoint: BridgePairEndpoint, now: Date) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let lastPublishedEndpoint,
              let lastPublishedAt else {
            return true
        }
        if endpoint != lastPublishedEndpoint {
            return true
        }
        return now.timeIntervalSince(lastPublishedAt) >= heartbeatInterval
    }

    private func markPublished(endpoint: BridgePairEndpoint, at date: Date) {
        lock.lock()
        lastPublishedEndpoint = endpoint
        lastPublishedAt = date
        lock.unlock()
    }
}
