import Foundation

/// Tracks which phone notifications were already delivered so polling does not repeat them.
/// The first `fresh` call only records a baseline (existing notifications are not replayed).
public struct NotificationDeduper: Sendable {
    private var seen: Set<String> = []
    private var primed = false
    private let maxSeen = 2000

    public init() {}

    private static func signature(_ n: PhoneNotification) -> String {
        "\(n.key)|\(n.title ?? "")|\(n.text ?? "")"
    }

    /// Returns notifications not seen before. A changed title/text under the same key counts as new.
    public mutating func fresh(_ list: [PhoneNotification]) -> [PhoneNotification] {
        var result: [PhoneNotification] = []
        for n in list where seen.insert(Self.signature(n)).inserted {
            result.append(n)
        }
        if seen.count > maxSeen { seen = Set(list.map(Self.signature)) }
        defer { primed = true }
        return primed ? result : []
    }
}
