import Foundation
import UserNotifications
import DroidMirrorCore

/// Posts a macOS notification as "DroidMirror". Inside the .app bundle it uses UNUserNotificationCenter.
/// Run as a bare SwiftPM executable (no bundle) that API is unavailable, so it falls back to `osascript`
/// with arguments passed via argv (never string-interpolated), so untrusted phone text cannot inject script code.
enum Notifier {
    private static var isBundled: Bool { Bundle.main.bundlePath.hasSuffix(".app") && Bundle.main.bundleIdentifier != nil }

    /// Asks for permission once at launch, so the system prompt appears while the user is looking at the app.
    static func requestAuthorization() {
        guard isBundled else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// From the no-debug companion link. The phone supplies the app's real label.
    static func post(_ n: CompanionNotification) {
        show(title: n.title ?? n.app, body: n.text ?? "", subtitle: n.app)
    }

    /// From the adb polling fallback.
    static func post(_ n: PhoneNotification) {
        show(title: n.title ?? n.appName, body: n.text ?? "", subtitle: n.appName)
    }

    private static func show(title: String, body: String, subtitle: String) {
        guard isBundled else { return showWithScript(title: title, body: body, subtitle: subtitle) }
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional:
                let content = UNMutableNotificationContent()
                content.title = title
                content.subtitle = subtitle
                content.body = body
                content.threadIdentifier = subtitle
                center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
            case .notDetermined:
                // Not asked yet (or the prompt is still open): fall back so the alert is not lost.
                showWithScript(title: title, body: body, subtitle: subtitle)
            default:
                // The user declined DroidMirror notifications; respect that.
                break
            }
        }
    }

    private static func showWithScript(title: String, body: String, subtitle: String) {
        let script = [
            "-e", "on run argv",
            "-e", "display notification (item 2 of argv) with title (item 1 of argv) subtitle (item 3 of argv)",
            "-e", "end run",
            title, body, subtitle,
        ]
        _ = try? ProcessRunner.run("osascript", script)
    }
}
