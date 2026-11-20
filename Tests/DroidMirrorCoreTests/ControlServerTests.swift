import XCTest
import Darwin
@testable import DroidMirrorCore

/// Test settings the hooks read, plus a record of what was sent to the phone.
private final class Fixture: @unchecked Sendable {
    let store = NotificationStore()
    private let lock = NSLock()
    private var _canRead = false, _canAct = false, _connected = true, _confirm = true
    private var _sent: [MacToPhone] = []
    private var _confirmedTexts: [String] = []

    var canRead: Bool { get { lock.lock(); defer { lock.unlock() }; return _canRead } set { lock.lock(); _canRead = newValue; lock.unlock() } }
    var canAct: Bool { get { lock.lock(); defer { lock.unlock() }; return _canAct } set { lock.lock(); _canAct = newValue; lock.unlock() } }
    var connected: Bool { get { lock.lock(); defer { lock.unlock() }; return _connected } set { lock.lock(); _connected = newValue; lock.unlock() } }
    var confirm: Bool { get { lock.lock(); defer { lock.unlock() }; return _confirm } set { lock.lock(); _confirm = newValue; lock.unlock() } }
    var sent: [MacToPhone] { lock.lock(); defer { lock.unlock() }; return _sent }
    var confirmedTexts: [String] { lock.lock(); defer { lock.unlock() }; return _confirmedTexts }

    func api() -> NotificationAPI {
        NotificationAPI(store: store, hooks: .init(
            canRead: { [self] in self.canRead },
            canAct: { [self] in self.canAct },
            isConnected: { [self] in self.connected },
            phoneName: { "Test Phone" },
            send: { [self] m in self.lock.lock(); self._sent.append(m); self.lock.unlock() },
            confirmReply: { [self] _, text in
                self.lock.lock(); self._confirmedTexts.append(text); self.lock.unlock()
                return self.confirm
            }
        ))
    }
}

/// A line-based client for the control socket (blocking, 10 s timeout).
private final class SocketClient {
    private var fd: Int32 = -1
    private var buffer = Data()

    init(path: String) throws {
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var tv = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        withUnsafeMutablePointer(to: &addr.sun_path) { p in p.withMemoryRebound(to: CChar.self, capacity: capacity) { _ = strncpy($0, path, capacity - 1) } }
        let rc = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard rc == 0 else { throw POSIXError(.ECONNREFUSED) }
    }
    deinit { if fd >= 0 { close(fd) } }

    func sendRaw(_ line: String) throws {
        let bytes = [UInt8]((line + "\n").utf8)
        guard Darwin.send(fd, bytes, bytes.count, 0) == bytes.count else { throw POSIXError(.EPIPE) }
    }

    func readLine() throws -> [String: Any] {
        while buffer.firstIndex(of: 0x0a) == nil {
            var chunk = [UInt8](repeating: 0, count: 4096)
            let n = recv(fd, &chunk, chunk.count, 0)
            if n <= 0 { throw POSIXError(.ECONNRESET) }
            buffer.append(contentsOf: chunk[0..<n])
        }
        let newline = buffer.firstIndex(of: 0x0a)!
        let line = Data(buffer[buffer.startIndex..<newline])
        buffer = Data(buffer[buffer.index(after: newline)...])
        return try JSONSerialization.jsonObject(with: line) as! [String: Any]
    }

    func call(_ method: String, _ params: [String: Any] = [:], id: Int = 1) throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: ["id": id, "method": method, "params": params])
        try sendRaw(String(decoding: data, as: UTF8.self))
        return try readLine()
    }
}

final class ControlServerTests: XCTestCase {
    private var path = ""
    private var server: ControlServer?

    override func setUp() { path = "/tmp/dm-ctl-\(UUID().uuidString.prefix(8)).sock" }
    override func tearDown() { server?.stop(); server = nil; unlink(path) }

    private func start(_ fx: Fixture) throws -> SocketClient {
        let s = ControlServer(path: path, api: fx.api())
        try s.start()
        server = s
        return try SocketClient(path: path)
    }

    private func add(_ fx: Fixture, key: String, canReply: Bool = true, text: String = "hello") {
        fx.store.add(CompanionNotification(key: key, pkg: "com.example", app: "Example", title: "Title \(key)", text: text, postedAt: 1_700_000_000, canReply: canReply))
    }

    func testReadingIsOffByDefaultButStatusStillWorks() throws {
        let fx = Fixture()
        add(fx, key: "k1")
        let c = try start(fx)
        let status = try c.call("status")
        XCTAssertEqual(status["ok"] as? Bool, true)
        let result = status["result"] as! [String: Any]
        XCTAssertEqual(result["connected"] as? Bool, true)
        XCTAssertEqual(result["canRead"] as? Bool, false)
        XCTAssertEqual(result["count"] as? Int, 1)
        XCTAssertEqual(result["phone"] as? String, "Test Phone")

        let list = try c.call("list_notifications")
        XCTAssertEqual(list["ok"] as? Bool, false)
        XCTAssertTrue((list["error"] as! String).contains("switched off"))
        XCTAssertNil(list["result"])                                  // nothing private leaks while it is off
    }

    func testListReturnsNotificationsWhenAllowed() throws {
        let fx = Fixture()
        fx.canRead = true
        add(fx, key: "k1", text: "first")
        add(fx, key: "k2", canReply: false, text: "second")
        let c = try start(fx)
        let all = (try c.call("list_notifications"))["result"] as! [[String: Any]]
        XCTAssertEqual(all.map { $0["key"] as? String }, ["k2", "k1"])                 // newest first
        XCTAssertEqual(all[0]["text"] as? String, "second")
        XCTAssertEqual(all[0]["canReply"] as? Bool, false)
        let one = (try c.call("list_notifications", ["limit": 1]))["result"] as! [[String: Any]]
        XCTAssertEqual(one.count, 1)
    }

    func testDismissNeedsPermissionAndAConnectedPhone() throws {
        let fx = Fixture()
        add(fx, key: "k1")
        let c = try start(fx)
        XCTAssertTrue(((try c.call("dismiss", ["key": "k1"]))["error"] as! String).contains("switched off"))
        fx.canAct = true
        fx.connected = false
        XCTAssertTrue(((try c.call("dismiss", ["key": "k1"]))["error"] as! String).contains("not connected"))
        fx.connected = true
        XCTAssertTrue(((try c.call("dismiss", ["key": "nope"]))["error"] as! String).contains("No notification"))
        XCTAssertTrue(fx.sent.isEmpty)                                                 // nothing was sent so far

        let ok = try c.call("dismiss", ["key": "k1"])
        XCTAssertEqual(ok["ok"] as? Bool, true)
        XCTAssertEqual(fx.sent, [.action(key: "k1", kind: .dismiss, text: nil)])
        XCTAssertNil(fx.store.find(key: "k1"))                                         // gone from the Mac list too
    }

    func testReplyAlwaysAsksAndOnlySendsWhenConfirmed() throws {
        let fx = Fixture()
        fx.canAct = true
        add(fx, key: "k1")
        add(fx, key: "k2", canReply: false)
        let c = try start(fx)

        fx.confirm = false
        let declined = try c.call("reply", ["key": "k1", "text": "hi"])
        XCTAssertTrue((declined["error"] as! String).contains("declined"))
        XCTAssertTrue(fx.sent.isEmpty)
        XCTAssertEqual(fx.confirmedTexts, ["hi"])                                      // the Mac was asked, with the real text

        fx.confirm = true
        XCTAssertEqual((try c.call("reply", ["key": "k1", "text": "  on my way  "]))["ok"] as? Bool, true)
        XCTAssertEqual(fx.sent, [.action(key: "k1", kind: .reply, text: "on my way")])  // trimmed

        XCTAssertTrue(((try c.call("reply", ["key": "k2", "text": "x"]))["error"] as! String).contains("does not allow replies"))
        XCTAssertTrue(((try c.call("reply", ["key": "k1", "text": "   "]))["error"] as! String).contains("empty"))
        XCTAssertTrue(((try c.call("reply", ["key": "k1", "text": String(repeating: "a", count: 2001)]))["error"] as! String).contains("longer"))
        XCTAssertEqual(fx.sent.count, 1)                                               // none of the rejected ones went out
    }

    func testSocketIsPrivateAndBadInputIsHandled() throws {
        let c = try start(Fixture())
        let mode = (try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int) ?? 0
        XCTAssertEqual(mode, 0o600)                                                    // only the owner can connect

        try c.sendRaw("this is not json")
        XCTAssertEqual(try c.readLine()["ok"] as? Bool, false)
        XCTAssertTrue(((try c.call("no_such_method"))["error"] as! String).contains("Unknown method"))
        XCTAssertEqual((try c.call("status", id: 7))["id"] as? Int, 7)                 // same connection still works, id is echoed
    }

    func testStartReplacesAStaleSocketFile() throws {
        FileManager.default.createFile(atPath: path, contents: Data("stale".utf8))
        let c = try start(Fixture())
        XCTAssertEqual((try c.call("status"))["ok"] as? Bool, true)
    }
}
