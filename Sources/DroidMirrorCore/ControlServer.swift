import Foundation
import Darwin

public enum ControlServerError: Error { case pathTooLong, socket(String) }

/// A local Unix socket that lets tools on this Mac (such as the MCP bridge) ask about phone notifications.
/// Only the current user can connect (file mode 0600 in a 0700 folder, plus a peer-uid check).
/// Protocol: one JSON object per line.
///   request:  {"id": 1, "method": "list_notifications", "params": {"limit": 10}}
///   response: {"id": 1, "ok": true, "result": ...}  or  {"id": 1, "ok": false, "error": "..."}
public final class ControlServer: @unchecked Sendable {
    public let path: String
    private let api: NotificationAPI
    private var listenFD: Int32 = -1
    private var running = false
    private let lock = NSLock()
    private let clients = DispatchQueue(label: "droidmirror.control.clients", attributes: .concurrent)
    private static let maxRequestBytes = 64 * 1024

    public static var defaultPath: String {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DroidMirror/api.sock").path
    }

    public init(path: String = ControlServer.defaultPath, api: NotificationAPI) {
        self.path = path
        self.api = api
    }

    public func start() throws {
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        unlink(path)                                              // a stale socket from a previous run

        var addr = sockaddr_un()
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard path.utf8.count < capacity else { throw ControlServerError.pathTooLong }
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: capacity) { _ = strncpy($0, path, capacity - 1) }
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ControlServerError.socket("socket: \(String(cString: strerror(errno)))") }
        let oldMask = umask(0o177)                                // create the socket file as 0600
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        umask(oldMask)
        guard bound == 0 else { close(fd); throw ControlServerError.socket("bind: \(String(cString: strerror(errno)))") }
        chmod(path, 0o600)
        guard listen(fd, 8) == 0 else { close(fd); throw ControlServerError.socket("listen: \(String(cString: strerror(errno)))") }

        lock.lock(); listenFD = fd; running = true; lock.unlock()
        let thread = Thread { [weak self] in self?.acceptLoop(fd) }
        thread.name = "droidmirror.control.accept"
        thread.start()
    }

    public func stop() {
        lock.lock()
        let fd = listenFD
        running = false
        listenFD = -1
        lock.unlock()
        if fd >= 0 { shutdown(fd, SHUT_RDWR); close(fd) }
        unlink(path)
    }

    private var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }

    private func acceptLoop(_ fd: Int32) {
        while isRunning {
            let client = accept(fd, nil, nil)
            if client < 0 { if isRunning { continue } else { break } }
            var one: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            clients.async { [weak self] in self?.serve(client) }
        }
    }

    private func serve(_ fd: Int32) {
        defer { close(fd) }
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == geteuid() else { return }   // same user only

        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = recv(fd, &chunk, chunk.count, 0)
            if n <= 0 { return }
            buffer.append(contentsOf: chunk[0..<n])
            if buffer.count > Self.maxRequestBytes && !buffer.contains(0x0a) { return }   // no newline in 64 KB: drop
            while let newline = buffer.firstIndex(of: 0x0a) {
                let line = buffer[buffer.startIndex..<newline]
                buffer = Data(buffer[buffer.index(after: newline)...])
                let reply = respond(to: Data(line))
                guard write(fd, reply) else { return }
            }
        }
    }

    private func respond(to line: Data) -> Data {
        var response: [String: Any] = ["ok": false, "error": "Invalid request."]
        if let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any], let method = object["method"] as? String {
            if let id = object["id"] { response["id"] = id }
            switch api.handle(method: method, params: (object["params"] as? [String: Any]) ?? [:]) {
            case .ok(let result): response["ok"] = true; response["result"] = result; response.removeValue(forKey: "error")
            case .failure(let message): response["error"] = message
            }
        }
        var data = (try? JSONSerialization.data(withJSONObject: response)) ?? Data(#"{"ok":false,"error":"Internal error."}"#.utf8)
        data.append(0x0a)
        return data
    }

    private func write(_ fd: Int32, _ data: Data) -> Bool {
        var sent = 0
        let bytes = [UInt8](data)
        while sent < bytes.count {
            let n = bytes.withUnsafeBufferPointer { Darwin.send(fd, $0.baseAddress! + sent, bytes.count - sent, 0) }
            if n <= 0 { return false }
            sent += n
        }
        return true
    }
}
