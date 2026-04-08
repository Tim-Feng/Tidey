import Foundation

final class TideySocketClient {
    private let locator: TideySocketLocator

    init(locator: TideySocketLocator) {
        self.locator = locator
    }

    func send(_ request: BridgeRequest) throws -> BridgeResponse {
        guard let socketPath = locator.resolveLiveSocketPath() else {
            throw BridgeInternalError.socketUnavailable
        }
        let fd = try Self.connectUnixSocket(path: socketPath)
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        let data = try JSONSerialization.data(withJSONObject: request.tideySocketJSONObject)
        var payload = data
        payload.append(0x0a)
        try handle.write(contentsOf: payload)

        var buffer = Data()
        while true {
            let chunk = try handle.read(upToCount: 4096) ?? Data()
            if chunk.isEmpty {
                break
            }
            buffer.append(chunk)
            if let newline = buffer.firstIndex(of: 0x0a) {
                let line = buffer.prefix(upTo: newline)
                return try JSONDecoder().decode(BridgeResponse.self, from: line)
            }
        }
        throw BridgeInternalError.invalidResponse
    }

    private static func connectUnixSocket(path: String) throws -> Int32 {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxLength = MemoryLayout.size(ofValue: addr.sun_path)
        let utf8 = Array(path.utf8)
        guard !utf8.isEmpty && utf8.count < maxLength else {
            throw BridgeInternalError.socketUnavailable
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw POSIXError(.ECONNREFUSED)
        }
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        withUnsafeMutablePointer(to: &addr.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: maxLength) { chars in
                memset(chars, 0, maxLength)
                for (index, byte) in utf8.enumerated() {
                    chars[index] = CChar(bitPattern: byte)
                }
            }
        }
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .ECONNREFUSED)
            close(fd)
            throw error
        }
        return fd
    }
}
