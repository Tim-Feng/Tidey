import Foundation

final class TideyWorkspaceEventMonitor {
    private let locator: TideySocketLocator
    private let hub: WorkspaceEventHub
    private let queue = DispatchQueue(label: "com.tidey.remote-bridge.workspace-event-monitor")
    private var shouldRun = false

    init(locator: TideySocketLocator, hub: WorkspaceEventHub) {
        self.locator = locator
        self.hub = hub
    }

    func start() {
        queue.async {
            guard !self.shouldRun else {
                return
            }
            self.shouldRun = true
            self.runLoop()
        }
    }

    private func runLoop() {
        while shouldRun {
            do {
                try subscribeAndPump()
            } catch {
                Thread.sleep(forTimeInterval: 1.0)
            }
        }
    }

    private func subscribeAndPump() throws {
        guard let socketPath = locator.resolveLiveSocketPath() else {
            throw BridgeInternalError.socketUnavailable
        }

        let fd = try TideySocketClient.connectUnixSocket(path: socketPath)
        defer { close(fd) }

        let request = BridgeRequest(id: UUID().uuidString,
                                    action: "subscribe_workspace_events",
                                    params: nil)
        let data = try JSONSerialization.data(withJSONObject: request.tideySocketJSONObject)
        var payload = data
        payload.append(0x0a)
        try TideySocketClient.writeAll(payload, to: fd)

        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        try awaitSubscriptionResponse(buffer: &buffer, chunk: &chunk, fd: fd)
        try drain(buffer: &buffer)

        while shouldRun {
            if let preferredPath = locator.resolveLiveSocketPath(),
               preferredPath != socketPath {
                break
            }

            var pollFD = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = withUnsafeMutablePointer(to: &pollFD) {
                poll($0, 1, 1000)
            }
            if ready == 0 {
                continue
            }
            if ready < 0 {
                if errno == EINTR {
                    continue
                }
                throw TideySocketClient.currentPOSIXError(defaultCode: .EIO)
            }

            let count = read(fd, &chunk, chunk.count)
            if count > 0 {
                buffer.append(chunk, count: count)
                try drain(buffer: &buffer)
                continue
            }
            if count == 0 {
                break
            }
            if errno == EINTR {
                continue
            }
            throw TideySocketClient.currentPOSIXError(defaultCode: .EIO)
        }
    }

    private func awaitSubscriptionResponse(buffer: inout Data,
                                           chunk: inout [UInt8],
                                           fd: Int32) throws {
        while shouldRun {
            if let newline = buffer.firstIndex(of: 0x0a) {
                let line = Data(buffer.prefix(upTo: newline))
                buffer.removeSubrange(...newline)
                if line.isEmpty {
                    continue
                }
                if let response = try? JSONDecoder().decode(BridgeResponse.self, from: line) {
                    if response.ok {
                        return
                    }
                    throw BridgeInternalError.invalidResponse
                }
                if let envelope = try? JSONDecoder().decode(WorkspaceEventEnvelope.self, from: line),
                   envelope.type == "workspace_event",
                   envelope.v == bridgeProtocolVersion {
                    hub.publish(envelope.event)
                    continue
                }
                throw BridgeInternalError.invalidResponse
            }

            let count = read(fd, &chunk, chunk.count)
            if count > 0 {
                buffer.append(chunk, count: count)
                continue
            }
            if count == 0 {
                break
            }
            if errno == EINTR {
                continue
            }
            throw TideySocketClient.currentPOSIXError(defaultCode: .EIO)
        }

        throw BridgeInternalError.invalidResponse
    }

    private func drain(buffer: inout Data) throws {
        while let newline = buffer.firstIndex(of: 0x0a) {
            let line = buffer.prefix(upTo: newline)
            buffer.removeSubrange(...newline)
            if line.isEmpty {
                continue
            }
            try handle(line: Data(line))
        }
    }

    private func handle(line: Data) throws {
        if let envelope = try? JSONDecoder().decode(WorkspaceEventEnvelope.self, from: line),
           envelope.type == "workspace_event",
           envelope.v == bridgeProtocolVersion {
            hub.publish(envelope.event)
        }
    }
}
