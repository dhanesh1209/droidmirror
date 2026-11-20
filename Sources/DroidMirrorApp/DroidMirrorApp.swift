import SwiftUI
import AppKit
import DroidMirrorCore

@main
struct DroidMirrorApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.openWindow) private var openWindow

    init() {
        // An app opened from Finder gets a minimal PATH, so add the usual Homebrew folders where adb and scrcpy live.
        let current = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        setenv("PATH", "/opt/homebrew/bin:/usr/local/bin:\(current)", 1)
        // Menu-bar only: no Dock icon.
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    private func notificationLabel(_ n: CompanionNotification) -> String {
        let summary = (n.title ?? n.text ?? "").replacingOccurrences(of: "\n", with: " ")
        return "\(n.app): \(summary.prefix(40))"
    }

    /// Android reports models as SM_S916B in some places and SM-S916B in others; show one form.
    private func displayName(_ raw: String) -> String { raw.replacingOccurrences(of: "_", with: "-") }

    private func show(_ id: String) {
        openWindow(id: id)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    private var automationTitle: String {
        (model.toolsMayRead || model.toolsMayAct) ? "Automation (on)" : "Automation"
    }

    var body: some Scene {
        MenuBarExtra {
            // PHONE
            Section(model.companionConnected ? "Phone: \(displayName(model.companionPhoneName ?? "Phone")) connected" : "Phone: not connected") {
                Button(model.companionConnected ? "Pair another phone…" : "Pair a phone…") { show("pair-phone") }
                if let e = model.companionError { Text(e) }
            }

            // NOTIFICATIONS
            Section("Notifications") {
                if model.recentNotifications.isEmpty {
                    Text("No recent notifications")
                } else {
                    Menu("Recent (\(model.recentNotifications.count))") {
                        ForEach(model.recentNotifications, id: \.key) { n in
                            Menu(notificationLabel(n)) {
                                if n.canReply {
                                    Button("Reply…") {
                                        model.replyTarget = n
                                        show("reply")
                                    }
                                }
                                Button("Dismiss on phone") { model.dismissOnPhone(n) }
                            }
                        }
                    }
                }
                Toggle("Show alerts on this Mac", isOn: $model.forwardNotifications)
            }

            // MIRRORING
            Section("Mirroring") {
                if !model.missingTools.isEmpty {
                    Text("Missing: \(model.missingTools.joined(separator: ", "))")
                    Text("Install with: brew install android-platform-tools scrcpy")
                }
                if model.devices.isEmpty {
                    Text("Needs USB or Wi-Fi debugging; none found")
                }
                ForEach(model.devices, id: \.serial) { device in
                    let name = displayName(device.model ?? device.serial)
                    if model.mirroringSerial == device.serial {
                        Button("Stop mirroring \(name)") { model.disconnect() }
                    } else if device.isReady {
                        Button("Mirror \(name)") { model.connect(device) }
                    } else {
                        Text("\(name): \(device.state)")
                    }
                }
                Toggle("Keep the phone’s screen off", isOn: $model.screenOff)
                Button("Set up Wi-Fi mirroring…") { show("wifi") }
                if let e = model.errorMessage { Text(e) }
            }

            Divider()
            // AUTOMATION (subsection)
            Menu(automationTitle) {
                Toggle("Let tools read notifications", isOn: $model.toolsMayRead)
                Toggle("Let tools reply and dismiss", isOn: $model.toolsMayAct)
                Divider()
                Text("Every reply still asks you first")
            }

            Divider()
            Button("Show activity log") { model.openLog() }
            Button("Quit DroidMirror") { NSApplication.shared.terminate(nil) }
        } label: {
            Image(systemName: model.companionConnected ? "iphone.gen3" : "iphone.slash")
        }
        Window("Set up Wi-Fi mirroring", id: "wifi") {
            PairView(model: model)
        }
        .windowResizability(.contentSize)
        Window("Pair your phone", id: "pair-phone") {
            CompanionPairView(model: model)
        }
        .windowResizability(.contentSize)
        Window("Reply", id: "reply") {
            ReplyView(model: model)
        }
        .windowResizability(.contentSize)
    }
}
