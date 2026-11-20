import Foundation

/// What local tools (the MCP bridge) may do with phone notifications. The menu-bar app supplies the hooks,
/// and it is the menu-bar app, not the tool, that decides what is allowed.
public final class NotificationAPI: @unchecked Sendable {
    public struct Hooks: @unchecked Sendable {
        /// "Allow local tools to read phone notifications" (off by default).
        public var canRead: @Sendable () -> Bool
        /// "Allow local tools to reply and dismiss" (off by default).
        public var canAct: @Sendable () -> Bool
        public var isConnected: @Sendable () -> Bool
        public var phoneName: @Sendable () -> String?
        public var send: @Sendable (MacToPhone) -> Void
        /// Always asked before a reply is sent, because a reply is a message sent as the user.
        public var confirmReply: @Sendable (CompanionNotification, String) -> Bool
        /// Something changed (for example a dismissal), so the menu should refresh.
        public var didChange: @Sendable () -> Void
        /// Privacy-safe event log (never message text).
        public var log: @Sendable (String) -> Void

        public init(canRead: @escaping @Sendable () -> Bool, canAct: @escaping @Sendable () -> Bool,
                    isConnected: @escaping @Sendable () -> Bool, phoneName: @escaping @Sendable () -> String?,
                    send: @escaping @Sendable (MacToPhone) -> Void,
                    confirmReply: @escaping @Sendable (CompanionNotification, String) -> Bool,
                    didChange: @escaping @Sendable () -> Void = {}, log: @escaping @Sendable (String) -> Void = { _ in }) {
            self.canRead = canRead; self.canAct = canAct; self.isConnected = isConnected; self.phoneName = phoneName
            self.send = send; self.confirmReply = confirmReply; self.didChange = didChange; self.log = log
        }
    }

    public enum Outcome {
        case ok(Any)
        case failure(String)
    }

    public static let maxReplyLength = 2000
    private let store: NotificationStore
    private let hooks: Hooks

    public init(store: NotificationStore, hooks: Hooks) {
        self.store = store
        self.hooks = hooks
    }

    public func handle(method: String, params: [String: Any]) -> Outcome {
        switch method {
        case "status":
            var status: [String: Any] = [
                "connected": hooks.isConnected(),
                "canRead": hooks.canRead(),
                "canAct": hooks.canAct(),
                "count": store.list(limit: 1000).count,
            ]
            if let name = hooks.phoneName() { status["phone"] = name }
            return .ok(status)

        case "list_notifications":
            guard hooks.canRead() else { return .failure(Self.readOff) }
            let limit = min(max((params["limit"] as? Int) ?? 20, 1), 100)
            let items = store.list(limit: limit).map(Self.json)
            hooks.log("tool listed \(items.count) notifications")
            return .ok(items)

        case "dismiss":
            guard hooks.canAct() else { return .failure(Self.actOff) }
            guard hooks.isConnected() else { return .failure(Self.notConnected) }
            guard let key = params["key"] as? String, let n = store.find(key: key) else { return .failure(Self.unknownKey) }
            hooks.send(.action(key: n.key, kind: .dismiss, text: nil))
            store.remove(key: n.key)
            hooks.didChange()
            hooks.log("tool dismissed a notification from \(n.app)")
            return .ok(["dismissed": true])

        case "reply":
            guard hooks.canAct() else { return .failure(Self.actOff) }
            guard hooks.isConnected() else { return .failure(Self.notConnected) }
            guard let key = params["key"] as? String, let n = store.find(key: key) else { return .failure(Self.unknownKey) }
            guard n.canReply else { return .failure("That notification does not allow replies.") }
            let text = ((params["text"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return .failure("The reply text is empty.") }
            guard text.count <= Self.maxReplyLength else { return .failure("The reply is longer than \(Self.maxReplyLength) characters.") }
            guard hooks.confirmReply(n, text) else {
                hooks.log("tool reply to \(n.app) was declined on the Mac")
                return .failure("The reply was declined on the Mac.")
            }
            hooks.send(.action(key: n.key, kind: .reply, text: text))
            hooks.log("tool reply sent to \(n.app): text_len=\(text.count)")
            return .ok(["sent": true])

        default:
            return .failure("Unknown method \(method).")
        }
    }

    static let readOff = "Reading phone notifications is switched off. Turn on “Allow local tools to read phone notifications” in the DroidMirror menu."
    static let actOff = "Replying and dismissing is switched off. Turn on “Allow local tools to reply and dismiss” in the DroidMirror menu."
    static let notConnected = "The phone is not connected to the Mac right now."
    static let unknownKey = "No notification with that key. List notifications again; it may have been dismissed."

    static func json(_ n: CompanionNotification) -> [String: Any] {
        var d: [String: Any] = ["key": n.key, "app": n.app, "pkg": n.pkg, "postedAt": n.postedAt, "canReply": n.canReply]
        if let t = n.title { d["title"] = t }
        if let t = n.text { d["text"] = t }
        return d
    }
}
