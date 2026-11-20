import Foundation

/// A phone notification sent to the Mac. The phone already drops ongoing, group-summary and
/// DroidMirror's own notifications, so everything received here is worth showing.
public struct CompanionNotification: Codable, Equatable, Sendable {
    public var key: String
    public var pkg: String
    public var app: String
    public var title: String?
    public var text: String?
    public var postedAt: Double      // seconds since 1970
    public var canReply: Bool

    public init(key: String, pkg: String, app: String, title: String?, text: String?, postedAt: Double, canReply: Bool) {
        self.key = key; self.pkg = pkg; self.app = app; self.title = title; self.text = text
        self.postedAt = postedAt; self.canReply = canReply
    }
}

public enum ActionKind: String, Codable, Sendable { case reply, dismiss, click }

public enum CompanionMessageError: Error { case malformed }

/// One flat JSON envelope used in both directions; unused fields are omitted.
struct Wire: Codable {
    var type: String
    var name: String?
    var v: Int?
    var n: CompanionNotification?
    var key: String?
    var kind: String?
    var text: String?
}

public enum PhoneToMac: Equatable, Sendable {
    case hello(name: String, version: Int)
    case notification(CompanionNotification)
    case dismissed(key: String)
    case pong
    case unknown(String)

    public static func decode(_ data: Data) throws -> PhoneToMac {
        let w = try JSONDecoder().decode(Wire.self, from: data)
        switch w.type {
        case "hello": return .hello(name: w.name ?? "phone", version: w.v ?? 1)
        case "notification":
            guard let n = w.n else { throw CompanionMessageError.malformed }
            return .notification(n)
        case "dismissed":
            guard let k = w.key else { throw CompanionMessageError.malformed }
            return .dismissed(key: k)
        case "pong": return .pong
        default: return .unknown(w.type)
        }
    }

    /// Used by tests to play the phone's role.
    public func encode() throws -> Data {
        let w: Wire
        switch self {
        case .hello(let name, let v): w = Wire(type: "hello", name: name, v: v)
        case .notification(let n): w = Wire(type: "notification", n: n)
        case .dismissed(let key): w = Wire(type: "dismissed", key: key)
        case .pong: w = Wire(type: "pong")
        case .unknown(let t): w = Wire(type: t)
        }
        return try JSONEncoder().encode(w)
    }
}

public enum MacToPhone: Equatable, Sendable {
    case ping
    case action(key: String, kind: ActionKind, text: String?)
    case clipboard(String)
    case unknown(String)

    public func encode() throws -> Data {
        let w: Wire
        switch self {
        case .ping: w = Wire(type: "ping")
        case .action(let key, let kind, let text): w = Wire(type: "action", key: key, kind: kind.rawValue, text: text)
        case .clipboard(let text): w = Wire(type: "clipboard", text: text)
        case .unknown(let t): w = Wire(type: t)
        }
        return try JSONEncoder().encode(w)
    }

    /// Used by tests to play the phone's role.
    public static func decode(_ data: Data) throws -> MacToPhone {
        let w = try JSONDecoder().decode(Wire.self, from: data)
        switch w.type {
        case "ping": return .ping
        case "action":
            guard let key = w.key, let k = w.kind, let kind = ActionKind(rawValue: k) else { throw CompanionMessageError.malformed }
            return .action(key: key, kind: kind, text: w.text)
        case "clipboard":
            guard let t = w.text else { throw CompanionMessageError.malformed }
            return .clipboard(t)
        default: return .unknown(w.type)
        }
    }
}
