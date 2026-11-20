import Foundation

public struct PhoneNotification: Equatable, Sendable {
    public let key: String
    public let package: String
    public let title: String?
    public let text: String?
    /// Notification flags from the dump header, e.g. ["GROUP_SUMMARY", "ONGOING_EVENT"].
    public var flags: Set<String> = []

    public var isOngoing: Bool { !flags.isDisjoint(with: ["ONGOING_EVENT", "FOREGROUND_SERVICE"]) }
    public var isGroupSummary: Bool { flags.contains("GROUP_SUMMARY") }
    public var appName: String { AppNames.display(for: package) }
}

/// Best-effort fallback that reads `adb shell dumpsys notification --noredact`.
/// The dumpsys format varies by Android version/OEM; the companion app (a
/// NotificationListenerService) is the intended primary source.
/// Verified shape: Samsung SM-S916B, Android 16 (SDK 36).
public enum NotificationParser {
    public static func parse(_ dump: String) -> [PhoneNotification] {
        dump.components(separatedBy: "NotificationRecord(").dropFirst().compactMap { chunk in
            let lines = chunk.split(separator: "\n", omittingEmptySubsequences: false)
            let header = String(lines.first ?? "")
            guard let pkg = capture(#"pkg=(\S+)"#, in: header) else { return nil }
            let key = capture(#"key=(\S+?):"#, in: header) ?? capture(#"key=(\S+)"#, in: header) ?? pkg
            let flags = Set((capture(#"flags=(\S+)"#, in: header) ?? "").split(separator: "|").map(String.init))
            let title = extra("android.title", in: lines)
            let text = extra("android.bigText", in: lines) ?? extra("android.text", in: lines)
            guard title != nil || text != nil else { return nil }
            return PhoneNotification(key: key, package: pkg, title: title, text: text, flags: flags)
        }
    }

    /// Reads one extras value, which may span several lines until the next `name=Type (` line or the closing brace.
    private static func extra(_ name: String, in lines: [Substring]) -> String? {
        guard let i = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix(name + "=") }) else { return nil }
        let first = lines[i].trimmingCharacters(in: .whitespaces)
        guard let open = first.firstIndex(of: "(") else { return nil }
        var value = String(first[first.index(after: open)...])
        var j = i + 1
        while j < lines.count, !isExtraKeyLine(lines[j]), !lines[j].trimmingCharacters(in: .whitespaces).hasPrefix("}") {
            value += "\n" + lines[j]
            j += 1
        }
        if value.hasSuffix(")") { value.removeLast() }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static let extraKeyLine = try! NSRegularExpression(pattern: #"^\s*[A-Za-z0-9_.]+=[A-Za-z0-9_.$]+ \("#)

    private static func isExtraKeyLine(_ line: Substring) -> Bool {
        let s = String(line)
        return extraKeyLine.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    private static func capture(_ pattern: String, in s: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: s) else { return nil }
        return String(s[r])
    }
}

/// Decides which phone notifications are worth showing on the Mac.
public struct NotificationFilter: Sendable {
    public var ignoredPackages: Set<String> = ["android", "com.android.systemui"]
    public var hideOngoing = true
    public var hideGroupSummaries = true

    public init() {}

    public func shouldForward(_ n: PhoneNotification) -> Bool {
        if ignoredPackages.contains(n.package) { return false }
        if hideOngoing && n.isOngoing { return false }
        if hideGroupSummaries && n.isGroupSummary { return false }
        return true
    }
}

/// Human-readable app names. Falls back to a prettified package name.
public enum AppNames {
    static let known: [String: String] = [
        "com.whatsapp": "WhatsApp",
        "com.google.android.gm": "Gmail",
        "com.google.android.gms": "Google Play services",
        "com.google.android.apps.messaging": "Messages",
        "com.samsung.android.messaging": "Messages",
        "com.google.android.dialer": "Phone",
        "com.samsung.android.incallui": "Phone",
        "com.samsung.android.calendar": "Calendar",
        "com.samsung.android.app.reminder": "Reminder",
        "com.samsung.android.app.sharelive": "Quick Share",
        "com.osp.app.signin": "Samsung account",
        "com.wssyncmldm": "Software update",
        "com.android.vending": "Google Play Store",
        "com.android.shell": "Android Shell",
        "com.instagram.android": "Instagram",
        "com.facebook.katana": "Facebook",
        "com.twitter.android": "X",
        "org.telegram.messenger": "Telegram",
        "com.slack": "Slack",
        "com.discord": "Discord",
        "com.spotify.music": "Spotify",
        "com.google.android.youtube": "YouTube",
        "com.linkedin.android": "LinkedIn",
        "com.microsoft.teams": "Teams",
    ]

    public static func display(for package: String) -> String {
        if let name = known[package] { return name }
        let parts = package.split(separator: ".").map(String.init)
        var word = parts.last ?? package
        let generic: Set<String> = ["android", "app", "apps", "mobile", "client", "main"]
        if generic.contains(word.lowercased()), parts.count >= 2 { word = parts[parts.count - 2] }
        return word.prefix(1).uppercased() + word.dropFirst()
    }
}
