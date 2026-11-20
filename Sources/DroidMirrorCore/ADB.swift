import Foundation

public struct AndroidDevice: Equatable, Sendable {
    public let serial: String
    public let state: String          // device, unauthorized, offline, ...
    public let model: String?
    public let isWireless: Bool

    public var isReady: Bool { state == "device" }
}

public enum ADB {
    /// Parses the output of `adb devices -l`.
    public static func parseDevices(_ output: String) -> [AndroidDevice] {
        output.split(whereSeparator: \.isNewline).compactMap { rawLine in
            let line = String(rawLine)
            if line.hasPrefix("List of devices") || line.hasPrefix("*") { return nil }
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard parts.count >= 2 else { return nil }
            let props = Dictionary(parts.dropFirst(2).compactMap { token -> (String, String)? in
                guard let i = token.firstIndex(of: ":") else { return nil }
                return (String(token[..<i]), String(token[token.index(after: i)...]))
            }, uniquingKeysWith: { first, _ in first })
            let serial = parts[0]
            return AndroidDevice(
                serial: serial,
                state: parts[1],
                model: props["model"],
                isWireless: serial.contains(":") || serial.contains("._adb-tls-connect")
            )
        }
    }

    /// Reads the phone's current notifications via `dumpsys` (best effort; format varies by Android version).
    public static func fetchNotifications(serial: String, adbPath: String = "adb") throws -> [PhoneNotification] {
        let out = try ProcessRunner.run(adbPath, ["-s", serial, "shell", "dumpsys", "notification", "--noredact"])
        return NotificationParser.parse(out)
    }

    public static func listDevices(adbPath: String = "adb") throws -> [AndroidDevice] {
        let out = try ProcessRunner.run(adbPath, ["devices", "-l"])
        return parseDevices(out)
    }
}
