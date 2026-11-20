import Foundation
import Darwin

/// What the QR code carries. Treat it as sensitive: anyone who sees it can pair as the phone.
public struct PairingPayload: Codable, Equatable, Sendable {
    public var v = 1
    public var host: String
    public var port: Int
    public var secret: String      // base64 of the 32-byte pairing secret
    public var name: String

    public init(host: String, port: Int, secret: Data, name: String) {
        self.host = host; self.port = port; self.secret = secret.base64EncodedString(); self.name = name
    }

    public func json() throws -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try enc.encode(self), as: UTF8.self)
    }
}

public enum LocalNetwork {
    /// The Mac's LAN IPv4 address, preferring Wi-Fi/Ethernet (`en*`) interfaces.
    public static func lanIPv4() -> String? {
        var addrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrs) == 0, let first = addrs else { return nil }
        defer { freeifaddrs(addrs) }
        var fallback: String?
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET),
                  (ifa.ifa_flags & UInt32(IFF_UP | IFF_RUNNING)) == UInt32(IFF_UP | IFF_RUNNING),
                  (ifa.ifa_flags & UInt32(IFF_LOOPBACK)) == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: host)
            if String(cString: ifa.ifa_name).hasPrefix("en") { return ip }
            fallback = fallback ?? ip
        }
        return fallback
    }
}

/// Recent phone notifications, newest first. Thread-safe.
public final class NotificationStore: @unchecked Sendable {
    private var items: [CompanionNotification] = []
    private let lock = NSLock()
    private let capacity: Int

    public init(capacity: Int = 200) { self.capacity = capacity }

    /// Adds or replaces (same key) a notification.
    public func add(_ n: CompanionNotification) {
        lock.lock(); defer { lock.unlock() }
        items.removeAll { $0.key == n.key }
        items.insert(n, at: 0)
        if items.count > capacity { items.removeLast(items.count - capacity) }
    }

    public func remove(key: String) {
        lock.lock(); defer { lock.unlock() }
        items.removeAll { $0.key == key }
    }

    public func list(limit: Int = 50) -> [CompanionNotification] {
        lock.lock(); defer { lock.unlock() }
        return Array(items.prefix(max(0, limit)))
    }

    public func find(key: String) -> CompanionNotification? {
        lock.lock(); defer { lock.unlock() }
        return items.first { $0.key == key }
    }

    public func clear() {
        lock.lock(); defer { lock.unlock() }
        items.removeAll()
    }
}
