import XCTest
import Darwin
@testable import DroidMirrorCore

private final class Box<T>: @unchecked Sendable {
    private var v: T
    private let l = NSLock()
    init(_ v: T) { self.v = v }
    func mutate(_ f: (inout T) -> Void) { l.lock(); f(&v); l.unlock() }
    var value: T { l.lock(); defer { l.unlock() }; return v }
}

/// A fake phone that talks to the server over a real localhost TCP socket (blocking, 5 s timeouts).
private final class TestPhone {
    private var fd: Int32 = -1
    private var channel: CompanionChannel!

    init(port: UInt16, secret: Data) throws {
        fd = socket(AF_INET, SOCK_STREAM, 0)
        var tv = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard rc == 0 else { throw POSIXError(.ECONNREFUSED) }
        let macSalt = try readExactly(16)
        let phoneSalt = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        try writeAll(phoneSalt)
        channel = try CompanionChannel(secret: secret, macSalt: macSalt, phoneSalt: phoneSalt, role: .phone)
    }

    deinit { if fd >= 0 { close(fd) } }

    private func readExactly(_ n: Int) throws -> Data {
        var out = Data()
        while out.count < n {
            var buf = [UInt8](repeating: 0, count: n - out.count)
            let r = recv(fd, &buf, buf.count, 0)
            if r <= 0 { throw POSIXError(.ECONNRESET) }
            out.append(contentsOf: buf[0..<r])
        }
        return out
    }

    private func writeAll(_ data: Data) throws {
        var sent = 0
        let bytes = [UInt8](data)
        while sent < bytes.count {
            let r = bytes.withUnsafeBufferPointer { Darwin.send(fd, $0.baseAddress! + sent, bytes.count - sent, 0) }
            if r <= 0 { throw POSIXError(.EPIPE) }
            sent += r
        }
    }

    func send(_ m: PhoneToMac) throws { try writeAll(try channel.seal(try m.encode())) }

    func receive() throws -> MacToPhone {
        let header = try readExactly(4)
        let len = Int(header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
        let body = try readExactly(len)
        return try MacToPhone.decode(try channel.open(body: body))
    }

    /// True if the server closed the connection (EOF or reset) within the timeout.
    func serverClosed() -> Bool {
        var b = [UInt8](repeating: 0, count: 256)
        while true {                                   // drain any pings still in flight, then see EOF or reset
            let r = recv(fd, &b, b.count, 0)
            if r > 0 { continue }
            if r == 0 { return true }
            return errno != EAGAIN && errno != EWOULDBLOCK
        }
    }
}

final class CompanionServerTests: XCTestCase {
    private let sample = CompanionNotification(key: "k1", pkg: "com.example", app: "Example", title: "Hi", text: "There", postedAt: 1_700_000_000, canReply: true)

    func testHelloNotificationAndActionRoundTrip() throws {
        let secret = PairingSecret.generate()
        let server = CompanionServer(secret: secret)
        let events = Box<[PhoneToMac]>([])
        let connected = Box<[Bool]>([])
        let hello = expectation(description: "hello"), notif = expectation(description: "notification")
        server.onEvent = { e in
            events.mutate { $0.append(e) }
            if case .hello = e { hello.fulfill() }
            if case .notification = e { notif.fulfill() }
        }
        server.onConnectionChange = { c in connected.mutate { $0.append(c) } }
        let port = try server.start()
        defer { server.stop() }

        let phone = try TestPhone(port: port, secret: secret)
        try phone.send(.hello(name: "Test Phone", version: 1))
        wait(for: [hello], timeout: 5)
        try phone.send(.notification(sample))
        wait(for: [notif], timeout: 5)

        XCTAssertEqual(events.value, [.hello(name: "Test Phone", version: 1), .notification(sample)])
        XCTAssertEqual(connected.value, [true])

        server.send(.action(key: "k1", kind: .reply, text: "on my way"))
        XCTAssertEqual(try phone.receive(), .action(key: "k1", kind: .reply, text: "on my way"))
        server.send(.clipboard("copied"))
        XCTAssertEqual(try phone.receive(), .clipboard("copied"))
    }

    func testWrongSecretIsClosedAndNeverDelivered() throws {
        let server = CompanionServer(secret: PairingSecret.generate())
        let events = Box<[PhoneToMac]>([])
        let connected = Box<[Bool]>([])
        server.onEvent = { e in events.mutate { $0.append(e) } }
        server.onConnectionChange = { c in connected.mutate { $0.append(c) } }
        let port = try server.start()
        defer { server.stop() }

        let stranger = try TestPhone(port: port, secret: PairingSecret.generate())   // different secret
        try stranger.send(.hello(name: "Stranger", version: 1))
        XCTAssertTrue(stranger.serverClosed(), "server must close a connection that fails authentication")
        XCTAssertTrue(events.value.isEmpty)
        XCTAssertTrue(connected.value.isEmpty)
    }

    func testStrangerCannotKickAuthenticatedPhone() throws {
        let secret = PairingSecret.generate()
        let server = CompanionServer(secret: secret)
        let hello = expectation(description: "hello")
        server.onEvent = { if case .hello = $0 { hello.fulfill() } }
        let port = try server.start()
        defer { server.stop() }

        let real = try TestPhone(port: port, secret: secret)
        try real.send(.hello(name: "Real", version: 1))
        wait(for: [hello], timeout: 5)

        let stranger = try TestPhone(port: port, secret: PairingSecret.generate())
        try stranger.send(.hello(name: "Stranger", version: 1))
        XCTAssertTrue(stranger.serverClosed())

        server.send(.ping)
        XCTAssertEqual(try real.receive(), .ping)    // real phone is still connected
    }

    func testSilentPhoneIsPingedThenDropped() throws {
        let secret = PairingSecret.generate()
        let server = CompanionServer(secret: secret, heartbeatInterval: 0.2, idleTimeout: 0.7)
        let hello = expectation(description: "hello")
        let connected = Box<[Bool]>([])
        server.onEvent = { if case .hello = $0 { hello.fulfill() } }
        server.onConnectionChange = { c in connected.mutate { $0.append(c) } }
        let port = try server.start()
        defer { server.stop() }

        let phone = try TestPhone(port: port, secret: secret)
        try phone.send(.hello(name: "Silent", version: 1))
        wait(for: [hello], timeout: 5)
        XCTAssertEqual(try phone.receive(), .ping)                 // the Mac pings an idle link
        XCTAssertTrue(phone.serverClosed(), "an unresponsive phone must be dropped after the idle timeout")
        XCTAssertEqual(connected.value, [true, false])             // the Mac noticed and reported the loss
    }

    func testPhoneThatAnswersPingsStaysConnected() throws {
        let secret = PairingSecret.generate()
        let server = CompanionServer(secret: secret, heartbeatInterval: 0.2, idleTimeout: 0.7)
        let hello = expectation(description: "hello")
        server.onEvent = { if case .hello = $0 { hello.fulfill() } }
        let port = try server.start()
        defer { server.stop() }

        let phone = try TestPhone(port: port, secret: secret)
        try phone.send(.hello(name: "Alive", version: 1))
        wait(for: [hello], timeout: 5)

        let until = Date().addingTimeInterval(1.6)                 // well past the 0.7 s idle timeout
        while Date() < until {
            if try phone.receive() == .ping { try phone.send(.pong) }
        }
        server.send(.clipboard("still here"))
        while true {                                               // skip any pings that arrive first
            let m = try phone.receive()
            if m == .clipboard("still here") { break }
            if m == .ping { try phone.send(.pong) }
        }
    }

    func testNotificationStore() {
        let store = NotificationStore(capacity: 3)
        for i in 1...4 {
            store.add(CompanionNotification(key: "k\(i)", pkg: "p", app: "A", title: "t\(i)", text: nil, postedAt: Double(i), canReply: false))
        }
        XCTAssertEqual(store.list().map(\.key), ["k4", "k3", "k2"])       // newest first, capacity 3
        store.add(CompanionNotification(key: "k2", pkg: "p", app: "A", title: "updated", text: nil, postedAt: 9, canReply: false))
        XCTAssertEqual(store.list().map(\.key), ["k2", "k4", "k3"])       // same key replaces and moves to front
        XCTAssertEqual(store.find(key: "k2")?.title, "updated")
        store.remove(key: "k4")
        XCTAssertEqual(store.list().map(\.key), ["k2", "k3"])
        XCTAssertEqual(store.list(limit: 1).count, 1)
    }

    func testPairingPayloadAndSecretStore() throws {
        let secret = PairingSecret.generate()
        let json = try PairingPayload(host: "192.168.1.5", port: 47891, secret: secret, name: "My Mac").json()
        let obj = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        XCTAssertEqual(obj["v"] as? Int, 1)
        XCTAssertEqual(obj["host"] as? String, "192.168.1.5")
        XCTAssertEqual(obj["port"] as? Int, 47891)
        XCTAssertEqual(Data(base64Encoded: obj["secret"] as! String), secret)

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dm-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FileSecretStore(url: dir.appendingPathComponent("pairing.key"))
        XCTAssertNil(store.load())
        let first = try PairingSecret.loadOrCreate(in: store)
        XCTAssertEqual(first.count, 32)
        XCTAssertEqual(try PairingSecret.loadOrCreate(in: store), first)  // stable across calls
        let perms = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("pairing.key").path)[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o600)
    }

    func testMessageEncodeDecode() throws {
        for m in [PhoneToMac.hello(name: "x", version: 1), .notification(sample), .dismissed(key: "k"), .pong] {
            XCTAssertEqual(try PhoneToMac.decode(try m.encode()), m)
        }
        for m in [MacToPhone.ping, .action(key: "k", kind: .dismiss, text: nil), .clipboard("c")] {
            XCTAssertEqual(try MacToPhone.decode(try m.encode()), m)
        }
        XCTAssertThrowsError(try PhoneToMac.decode(Data(#"{"type":"notification"}"#.utf8)))
    }

    func testLanAddressLooksLikeIPv4() {
        if let ip = LocalNetwork.lanIPv4() { XCTAssertEqual(ip.split(separator: ".").count, 4) }
    }
}
