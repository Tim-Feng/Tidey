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
        defer { close(fd) }
        let data = try JSONSerialization.data(withJSONObject: request.tideySocketJSONObject)
        var payload = data
        payload.append(0x0a)
        try Self.writeAll(payload, to: fd)
        let line = try Self.readLine(from: fd)
        return try JSONDecoder().decode(BridgeResponse.self, from: line)
    }

    static func connectUnixSocket(path: String) throws -> Int32 {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxLength = MemoryLayout.size(ofValue: addr.sun_path)
        let utf8 = Array(path.utf8)
        guard !utf8.isEmpty && utf8.count < maxLength else {
            throw BridgeInternalError.socketUnavailable
        }
        let addressLength = socklen_t((MemoryLayout<sockaddr_un>.offset(of: \.sun_path) ?? 0) + utf8.count + 1)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw Self.currentPOSIXError(defaultCode: .ECONNREFUSED)
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
                connect(fd, $0, addressLength)
            }
        }
        guard result == 0 else {
            let error = Self.currentPOSIXError(defaultCode: .ECONNREFUSED)
            close(fd)
            throw error
        }
        return fd
    }

    static func writeAll(_ data: Data, to fd: Int32) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else {
                return
            }
            var bytesWritten = 0
            while bytesWritten < rawBuffer.count {
                let pointer = baseAddress.advanced(by: bytesWritten)
                let result = write(fd, pointer, rawBuffer.count - bytesWritten)
                if result > 0 {
                    bytesWritten += result
                    continue
                }
                if result == -1 && errno == EINTR {
                    continue
                }
                throw currentPOSIXError(defaultCode: .EIO)
            }
        }
    }

    private static func readLine(from fd: Int32) throws -> Data {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(fd, &chunk, chunk.count)
            if count > 0 {
                buffer.append(chunk, count: count)
                if let newline = buffer.firstIndex(of: 0x0a) {
                    return buffer.prefix(upTo: newline)
                }
                continue
            }
            if count == 0 {
                break
            }
            if errno == EINTR {
                continue
            }
            throw currentPOSIXError(defaultCode: .EIO)
        }
        throw BridgeInternalError.invalidResponse
    }

    static func currentPOSIXError(defaultCode: POSIXErrorCode) -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? defaultCode)
    }
}
