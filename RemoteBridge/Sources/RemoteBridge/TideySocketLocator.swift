import Foundation

final class TideySocketLocator {
    private let fileManager = FileManager.default
    private let socketDirectory: URL

    init() {
        socketDirectory = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent("Tidey", isDirectory: true)
    }

    func resolveLiveSocketPath() -> String? {
        let primary = socketDirectory.appendingPathComponent("tidey.sock").path
        if Self.pathHasLiveListener(primary) {
            return primary
        }
        let development = socketDirectory.appendingPathComponent("tidey-dev.sock").path
        if Self.pathHasLiveListener(development) {
            return development
        }
        guard let entries = try? fileManager.contentsOfDirectory(atPath: socketDirectory.path) else {
            return nil
        }
        let candidates = entries
            .filter { entry in
                guard entry.hasSuffix(".sock") else { return false }
                return entry != "tidey.sock" && entry != "tidey-dev.sock"
            }
            .sorted()
        for candidate in candidates {
            let path = socketDirectory.appendingPathComponent(candidate).path
            if Self.pathHasLiveListener(path) {
                return path
            }
        }
        return nil
    }

    private static func pathHasLiveListener(_ path: String) -> Bool {
        guard !path.isEmpty else { return false }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxLength = MemoryLayout.size(ofValue: addr.sun_path)
        let utf8 = Array(path.utf8)
        guard !utf8.isEmpty && utf8.count < maxLength else {
            return false
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
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
        return result == 0
    }
}
