import Darwin
import Foundation
import HeadlessCodexTerminalSupport

@main
enum HeadlessCodexTerminalMain {
    static func main() {
        setbuf(stdout, nil)
        do {
            let configuration = try Configuration(arguments: Array(CommandLine.arguments.dropFirst()),
                                                  environment: ProcessInfo.processInfo.environment)
            let client = HeadlessCodexTerminalClient(configuration: configuration)
            try client.run()
        } catch {
            fputs("tidey-headless-codex-terminal: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}

private struct Configuration {
    let url: URL
    let token: String
    let workspaceID: String
    let panelID: String
    let sessionID: String

    init(arguments: [String], environment: [String: String]) throws {
        var values = [String: String]()
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            guard argument.hasPrefix("--") else {
                throw TerminalError.invalidArguments("Unexpected argument: \(argument)")
            }
            let key = String(argument.dropFirst(2))
            guard index + 1 < arguments.count else {
                throw TerminalError.invalidArguments("Missing value for \(argument)")
            }
            values[key] = arguments[index + 1]
            index += 2
        }

        let rawURL = values["url"] ?? environment["TIDEY_HEADLESS_CODEX_BRIDGE_URL"] ?? "ws://127.0.0.1:4817/ws"
        guard let url = URL(string: rawURL),
              url.scheme == "ws",
              url.host != nil else {
            throw TerminalError.invalidArguments("Invalid Bridge URL: \(rawURL)")
        }
        self.url = url
        if let token = values["token"] ?? environment["TIDEY_REMOTE_BRIDGE_TOKEN"] {
            self.token = token
        } else {
            self.token = try Self.loadPairToken()
        }
        self.workspaceID = values["workspace-id"] ?? environment["TIDEY_HEADLESS_CODEX_WORKSPACE_ID"] ?? "headless-codex-cutover"
        self.panelID = values["panel-id"] ?? environment["TIDEY_HEADLESS_CODEX_PANEL_ID"] ?? "headless-codex-cutover-panel"
        self.sessionID = values["session-id"] ?? environment["TIDEY_HEADLESS_CODEX_SESSION_ID"] ?? "headless-codex-cutover-session-live"
    }

    private static func loadPairToken(fileManager: FileManager = .default) throws -> String {
        let url = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent("Tidey Remote Bridge", isDirectory: true)
            .appendingPathComponent("pair-token.json", isDirectory: false)
        let data = try Data(contentsOf: url)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let token = object?["token"] as? String,
              token.isEmpty == false else {
            throw TerminalError.invalidArguments("Could not read Bridge token from \(url.path)")
        }
        return token
    }
}

private final class HeadlessCodexTerminalClient {
    private let configuration: Configuration
    private let renderer = HeadlessCodexTerminalRenderer()
    private let decoder = JSONDecoder()
    private var requestCounter = 0
    private var socket: BlockingWebSocket?

    init(configuration: Configuration) {
        self.configuration = configuration
    }

    func run() throws {
        let socket = try BlockingWebSocket.connect(url: configuration.url, bearerToken: configuration.token)
        self.socket = socket

        let receiveQueue = DispatchQueue(label: "tidey.headless-codex-terminal.receive")
        receiveQueue.async { [weak self] in
            self?.receiveLoop(socket: socket)
        }

        try send(action: "subscribe_agent_events",
                 params: [
                    "workspace_id": configuration.workspaceID,
                    "session_id": configuration.sessionID,
                 ])
        print("Connected to Headless Codex. Type a message and press Return.")

        while let line = readLine(strippingNewline: true) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.isEmpty == false else {
                continue
            }
            do {
                try send(action: "chat_submit",
                         params: [
                            "workspace_id": configuration.workspaceID,
                            "panel_id": configuration.panelID,
                            "session_id": configuration.sessionID,
                            "vendor": "codex",
                            "message": line,
                            "client_request_id": UUID().uuidString,
                         ])
            } catch {
                fputs("send failed: \(error.localizedDescription)\n", stderr)
            }
        }
        socket.close()
    }

    private func receiveLoop(socket: BlockingWebSocket) {
        while true {
            do {
                guard let text = try socket.readText() else {
                    return
                }
                handleWebSocketText(text)
            } catch {
                fputs("receive failed: \(error.localizedDescription)\n", stderr)
                return
            }
        }
    }

    private func handleWebSocketText(_ text: String) {
        guard let data = text.data(using: .utf8) else {
            return
        }
        if let envelope = try? decoder.decode(HeadlessCodexTerminalEventEnvelope.self, from: data),
           envelope.type == "agent_event" {
            for chunk in renderer.render(envelope: envelope) {
                write(chunk)
            }
            return
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["ok"] as? Bool == false else {
            return
        }
        if let error = object["error"] as? [String: Any],
           let message = error["message"] as? String {
            fputs("Bridge error: \(message)\n", stderr)
        }
    }

    private func write(_ chunk: HeadlessCodexTerminalRenderChunk) {
        switch chunk {
        case .line(let text):
            print(text)
        case .raw(let text):
            FileHandle.standardOutput.write(Data(text.utf8))
        }
    }

    private func send(action: String, params: [String: Any]) throws {
        guard let socket else {
            throw TerminalError.notConnected
        }
        requestCounter += 1
        let object: [String: Any] = [
            "id": "terminal-\(requestCounter)",
            "action": action,
            "params": params,
        ]
        let data = try JSONSerialization.data(withJSONObject: object)
        guard let text = String(data: data, encoding: .utf8) else {
            throw TerminalError.invalidRequest
        }
        try socket.sendText(text)
    }
}

private final class BlockingWebSocket {
    private let fd: Int32
    private let writeLock = NSLock()

    private init(fd: Int32) {
        self.fd = fd
    }

    static func connect(url: URL, bearerToken: String) throws -> BlockingWebSocket {
        guard let host = url.host else {
            throw TerminalError.invalidArguments("Bridge URL is missing host.")
        }
        let port = url.port ?? 4817
        let fd = try connectTCP(host: host, port: port)
        let path = url.path.isEmpty ? "/" : url.path
        let key = try randomBytes(count: 16).base64EncodedString()
        let request = """
        GET \(path) HTTP/1.1\r
        Host: \(host):\(port)\r
        Upgrade: websocket\r
        Connection: Upgrade\r
        Sec-WebSocket-Key: \(key)\r
        Sec-WebSocket-Version: 13\r
        Authorization: Bearer \(bearerToken)\r
        \r

        """
        try writeAll(Data(request.utf8), to: fd)
        let response = try readHTTPHeader(from: fd)
        guard response.hasPrefix("HTTP/1.1 101") else {
            Darwin.close(fd)
            throw TerminalError.invalidArguments("Bridge rejected WebSocket handshake: \(response.components(separatedBy: "\r\n").first ?? response)")
        }
        return BlockingWebSocket(fd: fd)
    }

    func sendText(_ text: String) throws {
        try sendFrame(opcode: 0x1, payload: Data(text.utf8))
    }

    func readText() throws -> String? {
        while true {
            let frame = try readFrame()
            switch frame.opcode {
            case 0x1:
                return String(data: frame.payload, encoding: .utf8)
            case 0x8:
                return nil
            case 0x9:
                try sendFrame(opcode: 0xA, payload: frame.payload)
            default:
                continue
            }
        }
    }

    func close() {
        Darwin.close(fd)
    }

    private func sendFrame(opcode: UInt8, payload: Data) throws {
        writeLock.lock()
        defer { writeLock.unlock() }

        var frame = Data()
        frame.append(0x80 | opcode)
        if payload.count < 126 {
            frame.append(0x80 | UInt8(payload.count))
        } else if payload.count <= UInt16.max {
            frame.append(0x80 | 126)
            frame.append(UInt8((payload.count >> 8) & 0xff))
            frame.append(UInt8(payload.count & 0xff))
        } else {
            frame.append(0x80 | 127)
            let length = UInt64(payload.count)
            for shift in stride(from: 56, through: 0, by: -8) {
                frame.append(UInt8((length >> UInt64(shift)) & 0xff))
            }
        }
        let mask = try Self.randomBytes(count: 4)
        frame.append(mask)
        for (index, byte) in payload.enumerated() {
            frame.append(byte ^ mask[index % 4])
        }
        try Self.writeAll(frame, to: fd)
    }

    private func readFrame() throws -> (opcode: UInt8, payload: Data) {
        let header = try Self.readExact(count: 2, from: fd)
        let opcode = header[0] & 0x0f
        let isMasked = (header[1] & 0x80) != 0
        var length = UInt64(header[1] & 0x7f)
        if length == 126 {
            let bytes = try Self.readExact(count: 2, from: fd)
            length = UInt64(bytes[0]) << 8 | UInt64(bytes[1])
        } else if length == 127 {
            let bytes = try Self.readExact(count: 8, from: fd)
            length = bytes.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        }
        let mask = isMasked ? try Self.readExact(count: 4, from: fd) : Data()
        var payload = try Self.readExact(count: Int(length), from: fd)
        if isMasked {
            for index in payload.indices {
                payload[index] = payload[index] ^ mask[index % 4]
            }
        }
        return (opcode, payload)
    }

    private static func connectTCP(host: String, port: Int) throws -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else {
            Darwin.close(fd)
            throw TerminalError.invalidArguments("Only IPv4 Bridge URLs are supported by the terminal viewer: \(host)")
        }
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else {
            let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .ECONNREFUSED)
            Darwin.close(fd)
            throw error
        }
        return fd
    }

    private static func readHTTPHeader(from fd: Int32) throws -> String {
        var data = Data()
        while data.count < 16 * 1024 {
            let byte = try readExact(count: 1, from: fd)
            data.append(byte)
            if data.suffix(4) == Data([13, 10, 13, 10]) {
                return String(data: data, encoding: .utf8) ?? ""
            }
        }
        throw TerminalError.invalidArguments("Bridge WebSocket handshake response was too large.")
    }

    private static func readExact(count: Int, from fd: Int32) throws -> Data {
        var data = Data(count: count)
        try data.withUnsafeMutableBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else {
                return
            }
            var offset = 0
            while offset < count {
                let result = read(fd, base.advanced(by: offset), count - offset)
                if result > 0 {
                    offset += result
                    continue
                }
                if result == 0 {
                    throw TerminalError.notConnected
                }
                if errno == EINTR {
                    continue
                }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
        return data
    }

    private static func writeAll(_ data: Data, to fd: Int32) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else {
                return
            }
            var offset = 0
            while offset < rawBuffer.count {
                let result = write(fd, base.advanced(by: offset), rawBuffer.count - offset)
                if result > 0 {
                    offset += result
                    continue
                }
                if result == -1 && errno == EINTR {
                    continue
                }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
    }

    private static func randomBytes(count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        guard SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess else {
            throw TerminalError.invalidArguments("Could not generate WebSocket mask bytes.")
        }
        return Data(bytes)
    }
}

private enum TerminalError: LocalizedError {
    case invalidArguments(String)
    case invalidRequest
    case notConnected

    var errorDescription: String? {
        switch self {
        case .invalidArguments(let message):
            return message
        case .invalidRequest:
            return "Could not encode Bridge request."
        case .notConnected:
            return "WebSocket is not connected."
        }
    }
}
